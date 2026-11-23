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
        if compressed {
            guard payload.count >= 4 else { throw Deflate.Error.corrupted }
            let p = [UInt8](payload.prefix(4))
            let rawLen = Int(p[0]) | Int(p[1]) << 8 | Int(p[2]) << 16 | Int(p[3]) << 24
            payload = try Deflate.decompress(Data(payload.dropFirst(4)), expectedSize: rawLen)
        }
        return WSFrame(fin: fin, opcode: opcode, payload: payload)
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
