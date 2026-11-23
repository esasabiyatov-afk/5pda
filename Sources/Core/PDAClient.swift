import Foundation

/// Ошибка, которую вернул сервер (ненулевой код в ответе).
struct PDAServerError: LocalizedError {
    let command: String
    let code: Int
    var errorDescription: String? { "Сервер вернул ошибку \(code) на команду «\(command)»" }
}

struct PDATimeoutError: LocalizedError {
    var errorDescription: String? { "Сервер не ответил вовремя" }
}

/// Клиент протокола приложения 4PDA.
///
/// Запрос: `[...параметры, "<код команды из 2 букв>", <id запроса>]`.
/// Ответ:  `[<id запроса>, <код ошибки, 0 — успех>, ...данные]`.
/// Сообщения с id 0 — события от сервера (уведомления и т.п.).
@MainActor
final class PDAClient: ObservableObject {
    static let shared = PDAClient()

    enum Status: Equatable {
        case disconnected, connecting, connected
        case failed(String)
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var memberId: Int = 0
    @Published private(set) var memberName: String = ""
    @Published private(set) var log: [LogEntry] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let outgoing: Bool
        let text: String
    }

    /// Версия протокола, которой представляется клиент при приветствии.
    static let protocolVersion = "1.9.43"
    static let clientName = "5pda-ios"

    private(set) var siteURL = URL(string: "https://4pda.to/")!
    private var socketHost = "app.4pda.to"
    private var socketPort: UInt16 = 993
    private var hostHeader = "app.4pda.ru"  // хост запасного подключения (TLS + WebSocket, порт 443)

    private var connection: PDAConnection?
    private var nextRequestId = 1
    private var pending: [Int: (command: String, continuation: CheckedContinuation<PDAValue, Error>)] = [:]
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var provisioned = false

    private let defaults = UserDefaults.standard

    private init() {
        memberId = defaults.integer(forKey: "member_id")
        memberName = defaults.string(forKey: "member_name") ?? ""
    }

    var isLoggedIn: Bool { memberId > 0 }

    // MARK: - Публичное API

    /// Отправляет команду и ждёт ответ. Возвращает массив данных (без id и кода ошибки).
    func call(_ command: String, _ params: [PDAValue] = [], timeout: TimeInterval = 20) async throws -> PDAValue {
        precondition(command.utf8.count == 2, "Код команды — ровно 2 символа")
        try await ensureConnected()
        let id = nextRequestId
        nextRequestId = nextRequestId >= 0x0FFFFFFF ? 1 : nextRequestId + 1

        let message = PDAValue.array(params + [.string(command), .int(id)])
        appendLog(outgoing: true, message.description)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PDAValue, Error>) in
            pending[id] = (command, cont)
            connection?.send(PDACodec.encode(message))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.fail(requestId: id, with: PDATimeoutError())
            }
        }
    }

    /// Вход по логину и паролю (команда `ml`).
    func login(username: String, password: String) async throws {
        let data = try await call("ml", [.string(username), .string(password), 1, 0])
        let id = data.int(0)
        let key = data.string(1)
        guard id > 0, !key.isEmpty else { throw PDAServerError(command: "ml", code: -1) }
        memberId = id
        memberName = username
        defaults.set(id, forKey: "member_id")
        defaults.set(username, forKey: "member_name")
        KeychainStore.set(key, for: "login_key")
    }

    func logout() {
        memberId = 0
        memberName = ""
        defaults.removeObject(forKey: "member_id")
        defaults.removeObject(forKey: "member_name")
        KeychainStore.remove("login_key")
        reconnect()
    }

    func reconnect() {
        connection?.disconnect()
        connection = nil
        status = .disconnected
    }

    func clearLog() { log.removeAll() }

    // MARK: - Подключение

    private func ensureConnected() async throws {
        if status == .connected, connection != nil { return }
        if status == .connecting {
            try await withCheckedThrowingContinuation { connectWaiters.append($0) }
            return
        }
        status = .connecting
        do {
            if !provisioned { await loadProvision() }
            try await openSocket()
            status = .connected
            try await greet()
            let waiters = connectWaiters
            connectWaiters.removeAll()
            waiters.forEach { $0.resume() }
        } catch {
            appendLog(outgoing: false, "Ошибка подключения: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
            connection?.disconnect()
            connection = nil
            let waiters = connectWaiters
            connectWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    /// Настройки серверов, которые использует официальный клиент.
    private func loadProvision() async {
        let sources = [
            "https://gist.githubusercontent.com/aigilea/152b043823de7cfeacd06f348b78ec25/raw/provision.json",
            "https://provision.app.devapps.ru/",
        ]
        for source in sources {
            guard let url = URL(string: source) else { continue }
            let json: [String: String]
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    appendLog(outgoing: false, "provision \(url.host ?? ""): неожиданный формат")
                    continue
                }
                json = parsed
            } catch {
                appendLog(outgoing: false, "provision \(url.host ?? ""): \(error.localizedDescription)")
                continue
            }
            if let b = json["b"], let u = URL(string: b) { siteURL = u; PDAConfig.siteURL = u }
            if let d = json["d"] {
                let parts = d.split(separator: ":")
                if let h = parts.first { socketHost = String(h) }
                if parts.count > 1, let p = UInt16(parts[1]) { socketPort = p }
            }
            if let w = json["w"], !w.isEmpty { hostHeader = w }
            provisioned = true
            appendLog(outgoing: false, "provision: \(json)")
            return
        }
    }

    /// Основной путь — «сырой» TCP на app.4pda.to:993; если не вышло — TLS + WebSocket на порт 443.
    private func openSocket() async throws {
        do {
            try await openSocket(host: socketHost, port: socketPort, webSocketHost: nil)
        } catch {
            appendLog(outgoing: false, "Основное подключение не удалось: \(error.localizedDescription). Пробую запасное.")
            try await openSocket(host: hostHeader, port: 443, webSocketHost: hostHeader)
        }
    }

    private func openSocket(host: String, port: UInt16, webSocketHost: String?) async throws {
        let conn = PDAConnection()
        conn.onMessage = { [weak self] data in
            Task { @MainActor in self?.handle(data) }
        }
        conn.onClose = { [weak self, weak conn] error in
            Task { @MainActor in
                guard let self = self, self.connection === conn else { return }
                self.handleClose(error)
            }
        }
        connection = conn
        appendLog(outgoing: true, "connect \(host):\(port)" + (webSocketHost.map { " TLS+WebSocket (Host: \($0))" } ?? " TCP"))
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.connect(host: host, port: port, webSocketHost: webSocketHost) { result in
                    cont.resume(with: result)
                }
            }
            appendLog(outgoing: false, "Подключено к \(host):\(port)")
        } catch {
            connection = nil
            conn.onClose = nil
            conn.disconnect()
            throw error
        }
    }

    /// Приветствие (`ah`) и вход по сохранённому ключу (`ma`).
    private func greet() async throws {
        let hello: [PDAValue] = [.string(Self.protocolVersion), "", .string(Self.clientName), 1, .int(memberId)]
        _ = try await sendRaw("ah", hello)
        if memberId > 0, let key = KeychainStore.get("login_key") {
            do {
                _ = try await sendRaw("ma", [.int(memberId), .string(key)])
            } catch let error as PDAServerError {
                appendLog(outgoing: false, "Сохранённый вход не принят (\(error.code)), нужен повторный вход")
                memberId = 0
                defaults.removeObject(forKey: "member_id")
                KeychainStore.remove("login_key")
            }
        }
    }

    /// Запрос в обход ensureConnected — используется во время подключения.
    private func sendRaw(_ command: String, _ params: [PDAValue]) async throws -> PDAValue {
        let id = nextRequestId
        nextRequestId += 1
        let message = PDAValue.array(params + [.string(command), .int(id)])
        appendLog(outgoing: true, message.description)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PDAValue, Error>) in
            pending[id] = (command, cont)
            connection?.send(PDACodec.encode(message))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.fail(requestId: id, with: PDATimeoutError())
            }
        }
    }

    // MARK: - Входящие

    private func handle(_ data: Data) {
        let value: PDAValue
        do {
            value = try PDACodec.decode(data)
        } catch {
            appendLog(outgoing: false, "Не удалось разобрать сообщение (\(data.count) байт): \(error)")
            return
        }
        guard case .array(var items) = value, items.count >= 2 else {
            appendLog(outgoing: false, "Неожиданное сообщение: \(value.description.prefix(300))")
            return
        }
        let requestId = (items[0].intValue ?? 0) & 0x0FFFFFFF
        let code = items[1].intValue ?? -1
        items.removeFirst(2)
        let payload = PDAValue.array(items)
        appendLog(outgoing: false, "#\(requestId) код \(code): \(payload.description.prefix(2000))")

        guard requestId != 0, let entry = pending.removeValue(forKey: requestId) else { return }
        if code == 0 {
            entry.continuation.resume(returning: payload)
        } else {
            entry.continuation.resume(throwing: PDAServerError(command: entry.command, code: code))
        }
    }

    private func handleClose(_ error: Error?) {
        appendLog(outgoing: false, "Соединение закрыто" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        connection = nil
        if status == .connected { status = .disconnected }
        let all = pending
        pending.removeAll()
        all.values.forEach { $0.continuation.resume(throwing: error ?? PDAConnection.ConnError.closed) }
    }

    private func fail(requestId: Int, with error: Error) {
        guard let entry = pending.removeValue(forKey: requestId) else { return }
        entry.continuation.resume(throwing: error)
    }

    private func appendLog(outgoing: Bool, _ text: String) {
        log.append(LogEntry(outgoing: outgoing, text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}
