import Foundation

/// Значение протокола 4PDA: целое число, строка или массив.
/// Сообщения выглядят как JSON, состоящий только из массивов: `[1,"текст",[2,3]]`.
/// Строки передаются в кодировке Windows-1251.
enum PDAValue: Equatable, CustomStringConvertible {
    case int(Int)
    case string(String)
    case array([PDAValue])

    // MARK: - Доступ к элементам

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let v): return String(v)
        default: return nil
        }
    }

    var arrayValue: [PDAValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var count: Int { arrayValue?.count ?? 0 }

    subscript(_ index: Int) -> PDAValue? {
        guard let a = arrayValue, index >= 0, index < a.count else { return nil }
        return a[index]
    }

    func int(_ index: Int) -> Int { self[index]?.intValue ?? 0 }
    func string(_ index: Int) -> String { self[index]?.stringValue ?? "" }
    func array(_ index: Int) -> [PDAValue] { self[index]?.arrayValue ?? [] }

    var description: String {
        switch self {
        case .int(let v): return String(v)
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[" + a.map { $0.description }.joined(separator: ",") + "]"
        }
    }

    /// Многострочный вывод с индексами — удобно для отладки ответов сервера.
    func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .array(let a):
            if a.isEmpty { return "[]" }
            var out = "[\n"
            for (i, v) in a.enumerated() {
                out += pad + "  " + "\(i): " + v.pretty(indent: indent + 1) + "\n"
            }
            return out + pad + "]"
        default:
            return description
        }
    }
}

extension PDAValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: PDAValue...) { self = .array(elements) }
}

// MARK: - Кодирование

enum PDACodec {
    enum DecodeError: Error { case unexpected(Int), truncated }

    static func encode(_ value: PDAValue) -> Data {
        var out = Data()
        write(value, to: &out)
        return out
    }

    private static func write(_ value: PDAValue, to out: inout Data) {
        switch value {
        case .int(let v):
            out.append(contentsOf: Array(String(v).utf8))
        case .string(let s):
            out.append(0x22)
            writeString(s, to: &out)
            out.append(0x22)
        case .array(let items):
            out.append(0x5B)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x2C) }
                write(item, to: &out)
            }
            out.append(0x5D)
        }
    }

    private static func writeString(_ s: String, to out: inout Data) {
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out.append(contentsOf: [0x5C, 0x5C])
            case "\"": out.append(contentsOf: [0x5C, 0x22])
            case "\n": out.append(contentsOf: [0x5C, 0x6E])
            case "\r": out.append(contentsOf: [0x5C, 0x72])
            case "\t": out.append(contentsOf: [0x5C, 0x74])
            default:
                if scalar.value >= 0x20 && scalar.value < 0x80 {
                    out.append(UInt8(scalar.value))
                } else if scalar.value >= 0x80,
                          let d = String(Character(scalar)).data(using: .windowsCP1251, allowLossyConversion: false),
                          d.count == 1 {
                    out.append(d)
                } else {
                    // Символ вне Windows-1251 (эмодзи и т.п.) — HTML-сущность, как в оригинальном клиенте.
                    out.append(contentsOf: Array("&#\(scalar.value);".utf8))
                }
            }
        }
    }

    // MARK: - Разбор

    static func decode(_ data: Data) throws -> PDAValue {
        let bytes = [UInt8](data)
        var pos = 0
        skipSpaces(bytes, &pos)
        return try parseValue(bytes, &pos)
    }

    private static func skipSpaces(_ b: [UInt8], _ pos: inout Int) {
        while pos < b.count, b[pos] == 0x20 || b[pos] == 0x0A || b[pos] == 0x0D || b[pos] == 0x09 { pos += 1 }
    }

    private static func parseValue(_ b: [UInt8], _ pos: inout Int) throws -> PDAValue {
        guard pos < b.count else { throw DecodeError.truncated }
        switch b[pos] {
        case 0x5B: return try parseArray(b, &pos)
        case 0x22: return .string(try parseString(b, &pos))
        case 0x2D, 0x30...0x39: return .int(parseInt(b, &pos))
        default: throw DecodeError.unexpected(pos)
        }
    }

    private static func parseArray(_ b: [UInt8], _ pos: inout Int) throws -> PDAValue {
        pos += 1 // [
        var items: [PDAValue] = []
        skipSpaces(b, &pos)
        if pos < b.count, b[pos] == 0x5D { pos += 1; return .array(items) }
        while true {
            skipSpaces(b, &pos)
            items.append(try parseValue(b, &pos))
            skipSpaces(b, &pos)
            guard pos < b.count else { throw DecodeError.truncated }
            if b[pos] == 0x2C { pos += 1; continue }
            if b[pos] == 0x5D { pos += 1; return .array(items) }
            throw DecodeError.unexpected(pos)
        }
    }

    private static func parseInt(_ b: [UInt8], _ pos: inout Int) -> Int {
        var sign = 1
        if b[pos] == 0x2D { sign = -1; pos += 1 }
        var v = 0
        while pos < b.count, b[pos] >= 0x30, b[pos] <= 0x39 {
            v = v &* 10 &+ Int(b[pos] - 0x30)
            pos += 1
        }
        return v * sign
    }

    private static func parseString(_ b: [UInt8], _ pos: inout Int) throws -> String {
        pos += 1 // "
        var result = ""
        var chunk: [UInt8] = []
        func flush() {
            if chunk.isEmpty { return }
            result += String(data: Data(chunk), encoding: .windowsCP1251) ?? String(decoding: chunk, as: UTF8.self)
            chunk.removeAll(keepingCapacity: true)
        }
        while pos < b.count {
            let c = b[pos]
            pos += 1
            if c == 0x22 { flush(); return result }
            if c != 0x5C { chunk.append(c); continue }
            guard pos < b.count else { throw DecodeError.truncated }
            let e = b[pos]
            pos += 1
            switch e {
            case 0x6E: chunk.append(0x0A)
            case 0x72: chunk.append(0x0D)
            case 0x74: chunk.append(0x09)
            case 0x66: chunk.append(0x0C)
            case 0x62: chunk.append(0x08)
            case 0x75:
                guard pos + 4 <= b.count,
                      let code = UInt32(String(decoding: b[pos..<pos + 4], as: UTF8.self), radix: 16) else {
                    throw DecodeError.unexpected(pos)
                }
                pos += 4
                flush()
                if let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
            default: chunk.append(e)
            }
        }
        throw DecodeError.truncated
    }
}
