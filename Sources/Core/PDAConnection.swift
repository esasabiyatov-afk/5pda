import Foundation
import Network

/// TLS + WebSocket соединение с сервером приложения 4PDA (app.4pda.to:993).
final class PDAConnection {
    enum State { case idle, connecting, ready, failed(Error) }

    enum ConnError: LocalizedError {
        case handshake(String), closed
        var errorDescription: String? {
            switch self {
            case .handshake(let s): return "Ошибка рукопожатия WebSocket: \(s)"
            case .closed: return "Соединение закрыто"
            }
        }
    }

    var onMessage: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "pda.connection")
    private var connection: NWConnection?
    private var buffer = Data()
    private var fragments = Data()
    private var handshakeDone = false
    private var pingTimer: DispatchSourceTimer?

    /// - Parameter webSocketHost: nil — «сырое» TCP-соединение (основной режим, порт 993),
    ///   иначе TLS + HTTP-рукопожатие WebSocket с этим Host (запасной режим, порт 443).
    func connect(host: String, port: UInt16, webSocketHost: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 10
        let params: NWParameters
        if webSocketHost != nil {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn
        buffer.removeAll()
        fragments.removeAll()
        handshakeDone = false

        var finished = false
        let finish: (Result<Void, Error>) -> Void = { result in
            if finished { return }
            finished = true
            completion(result)
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let wsHost = webSocketHost {
                    self.sendHandshake(hostHeader: wsHost, completion: finish)
                } else {
                    self.handshakeDone = true
                    self.startPing()
                    finish(.success(()))
                    self.receive()
                }
            case .failed(let error):
                finish(.failure(error))
                self.handleClose(error)
            case .waiting(let error):
                finish(.failure(error))
                self.handleClose(error)
                conn.cancel()
            case .cancelled:
                finish(.failure(ConnError.closed))
                self.handleClose(nil)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        queue.async {
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    func send(_ payload: Data) {
        let frame = WebSocketFramer.encode(opcode: .text, payload: payload, compress: true)
        queue.async {
            self.connection?.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error = error { self?.handleClose(error) }
            })
        }
    }

    // MARK: - Внутреннее

    private func sendHandshake(hostHeader: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
        let key = Data(keyBytes).base64EncodedString()
        let request = "GET /ws/ HTTP/1.1\r\n" +
            "Host: \(hostHeader)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\n" +
            "Sec-WebSocket-Protocol: app\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { error in
            if let error = error { completion(.failure(error)) }
        })
        receive(handshakeCompletion: completion)
    }

    private func receive(handshakeCompletion: ((Result<Void, Error>) -> Void)? = nil) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty { self.buffer.append(data) }

            var handshakeCB = handshakeCompletion
            if !self.handshakeDone {
                if let range = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: self.buffer[self.buffer.startIndex..<range.lowerBound], as: UTF8.self)
                    self.buffer = Data(self.buffer[range.upperBound...])
                    let status = head.components(separatedBy: "\r\n").first ?? ""
                    if status.contains(" 101") || head.contains("101 Switching Protocols") {
                        self.handshakeDone = true
                        self.startPing()
                        handshakeCB?(.success(()))
                    } else {
                        handshakeCB?(.failure(ConnError.handshake(status)))
                        self.connection?.cancel()
                        return
                    }
                    handshakeCB = nil
                }
            }
            if self.handshakeDone { self.drainFrames() }

            if let error = error {
                handshakeCB?(.failure(error))
                self.handleClose(error)
                return
            }
            if isComplete {
                handshakeCB?(.failure(ConnError.closed))
                self.handleClose(nil)
                return
            }
            self.receive(handshakeCompletion: handshakeCB)
        }
    }

    private func drainFrames() {
        do {
            while let frame = try WebSocketFramer.decode(from: &buffer) {
                switch frame.opcode {
                case WSOpcode.ping.rawValue:
                    let pong = WebSocketFramer.encode(opcode: .pong, payload: frame.payload, compress: false)
                    connection?.send(content: pong, completion: .idempotent)
                case WSOpcode.pong.rawValue:
                    break
                case WSOpcode.close.rawValue:
                    connection?.cancel()
                    return
                default:
                    fragments.append(frame.payload)
                    if frame.fin {
                        let message = fragments
                        fragments = Data()
                        onMessage?(message)
                    }
                }
            }
        } catch {
            handleClose(error)
            connection?.cancel()
        }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            let ping = WebSocketFramer.encode(opcode: .ping, payload: Data(), compress: false)
            self?.connection?.send(content: ping, completion: .idempotent)
        }
        timer.resume()
        pingTimer = timer
    }

    private func handleClose(_ error: Error?) {
        pingTimer?.cancel()
        pingTimer = nil
        guard connection != nil else { return }
        connection = nil
        onClose?(error)
    }
}
