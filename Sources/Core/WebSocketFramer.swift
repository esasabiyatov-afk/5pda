import Foundation
import Compression

/// Кадры WebSocket в варианте сервера 4PDA:
/// - клиент шлёт кадры без маски;
/// - флаг RSV1 (0x40) означает сжатие: 4 байта LE — исходная длина, далее raw DEFLATE.
enum WSOpcode: UInt8 {
    case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
}

struct WSFrame {
    var fin: Bool
    var opcode: UInt8
    var compressed: Bool
    var payload: Data
}

enum WebSocketFramer {
    static func encode(opcode: WSOpcode, payload: Data, compress: Bool, fin: Bool = true) -> Data {
        var body = payload
        var useCompression = false
        if compress, !payload.isEmpty, let deflated = Deflate.compress(payload) {
            let n = UInt32(payload.count)
            body = Data([UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]) + deflated
            useCompression = true
        }

        var header = Data()
        header.append(opcode.rawValue | (fin ? 0x80 : 0) | (useCompression ? 0x40 : 0))
        let len = body.count
        if len <= 125 {
            header.append(UInt8(len))
        } else if len <= 0xFFFF {
            header.append(126)
            header.append(UInt8((len >> 8) & 0xFF))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((len >> shift) & 0xFF))
            }
        }
        return header + body
    }

    /// Пытается вынуть один кадр из буфера. Возвращает nil, если данных пока не хватает.
    static func decode(from buffer: inout Data) throws -> WSFrame? {
        let b = [UInt8](buffer.prefix(14))
        guard b.count >= 2 else { return nil }
        let fin = b[0] & 0x80 != 0
        let compressed = b[0] & 0x40 != 0
        let opcode = b[0] & 0x0F
        let masked = b[1] & 0x80 != 0
        var len = Int(b[1] & 0x7F)
        var offset = 2
        if len == 126 {
            guard b.count >= 4 else { return nil }
            len = Int(b[2]) << 8 | Int(b[3])
            offset = 4
        } else if len == 127 {
            guard b.count >= 10 else { return nil }
            len = 0
            for i in 2..<10 { len = len << 8 | Int(b[i]) }
            offset = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard b.count >= offset + 4 else { return nil }
            mask = Array(b[offset..<offset + 4])
            offset += 4
        }
        guard buffer.count >= offset + len else { return nil }

        let start = buffer.startIndex
        var payload = Data(buffer[(start + offset)..<(start + offset + len)])
        buffer = Data(buffer[(start + offset + len)...])

        if masked {
            var bytes = [UInt8](payload)
            for i in 0..<bytes.count { bytes[i] ^= mask[i % 4] }
            payload = Data(bytes)
        }
        return WSFrame(fin: fin, opcode: opcode, compressed: compressed, payload: payload)
    }
}

/// Raw DEFLATE (RFC 1951) через Compression.framework — COMPRESSION_ZLIB в Apple означает именно raw DEFLATE.
enum Deflate {
    enum Error: Swift.Error { case corrupted }

    static func compress(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        let capacity = data.count + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            compression_encode_buffer(&out, capacity,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
        return written > 0 ? Data(out.prefix(written)) : nil
    }

    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        guard !data.isEmpty else { throw Error.corrupted }
        let capacity = max(expectedSize, 1)
        var out = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            compression_decode_buffer(&out, capacity,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw Error.corrupted }
        return Data(out.prefix(written))
    }
}

/// Потоковый распаковщик raw DEFLATE с общим контекстом на всё соединение.
/// Сервер сжимает все ответы одним потоком (как permessage-deflate с context takeover):
/// кадр = 4 байта LE (исходная длина) + сжатые данные без маркера 00 00 FF FF.
final class StreamInflater {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var ready = false

    init() {
        ready = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
    }

    deinit {
        if ready { compression_stream_destroy(&stream) }
    }

    func inflate(_ frame: Data) throws -> Data {
        guard ready, frame.count >= 4 else { throw Deflate.Error.corrupted }
        let p = [UInt8](frame.prefix(4))
        let expected = Int(p[0]) | Int(p[1]) << 8 | Int(p[2]) << 16 | Int(p[3]) << 24
        var input = [UInt8](frame.dropFirst(4))
        input += [0x00, 0x00, 0xFF, 0xFF]

        var output = Data()
        output.reserveCapacity(expected)
        let chunk = 65536
        var buffer = [UInt8](repeating: 0, count: chunk)
        try input.withUnsafeBufferPointer { src in
            stream.src_ptr = src.baseAddress!
            stream.src_size = src.count
            // Декодер Apple может отдавать результат порциями и держать остаток
            // у себя даже после того, как прочитал весь вход, поэтому вызываем
            // его, пока не получим ожидаемый размер или он перестанет выдавать данные.
            var idle = 0
            while output.count < expected {
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { dst in
                    stream.dst_ptr = dst.baseAddress!
                    stream.dst_size = dst.count
                    return compression_stream_process(&stream, 0)
                }
                let produced = chunk - stream.dst_size
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]); idle = 0 } else { idle += 1 }
                if status == COMPRESSION_STATUS_ERROR { throw Deflate.Error.corrupted }
                if status == COMPRESSION_STATUS_END { break }
                if idle >= 2 { break }
            }
            // Дочитываем вход (хвост 00 00 FF FF), чтобы состояние потока было согласовано.
            while stream.src_size > 0 {
                let before = stream.src_size
                _ = buffer.withUnsafeMutableBufferPointer { dst -> compression_status in
                    stream.dst_ptr = dst.baseAddress!
                    stream.dst_size = dst.count
                    return compression_stream_process(&stream, 0)
                }
                let produced = chunk - stream.dst_size
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                if stream.src_size == before && produced == 0 { break }
            }
        }
        if output.count > expected { output = output.prefix(expected) }
        return output
    }
}
