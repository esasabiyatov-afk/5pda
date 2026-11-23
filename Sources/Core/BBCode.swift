import Foundation
import SwiftUI

/// Блок разметки поста/новости после разбора BB-кода.
indirect enum BBBlock: Identifiable {
    case text(AttributedString)
    case image(URL)
    case quote(title: String, blocks: [BBBlock])
    case spoiler(title: String, blocks: [BBBlock])
    case code(String)

    var id: String {
        switch self {
        case .text(let t): return "t\(t.hashValue)"
        case .image(let u): return "i\(u.absoluteString)"
        case .quote(let t, let b): return "q\(t)\(b.count)\(b.first?.id ?? "")"
        case .spoiler(let t, let b): return "s\(t)\(b.count)\(b.first?.id ?? "")"
        case .code(let c): return "c\(c.hashValue)"
        }
    }
}

/// Упрощённый разбор BB-кода 4PDA. Поддерживает теги, которые встречаются чаще всего:
/// b, i, u, s, url, img, color, size, quote, spoiler, code, list, attachment, center/left/right.
struct BBParser {
    private struct Token {
        enum Kind { case text(String), open(String, String), close(String) }
        let kind: Kind
    }

    private static let known: Set<String> = [
        "attachment", "background", "b", "center", "code", "color", "cur", "ex", "font", "hide", "img", "i",
        "left", "list", "mergetime", "mod", "offtop", "quote", "right", "size", "snapback", "spoiler",
        "sub", "sup", "s", "url", "u", "*", "break", "na", "seporator",
    ]

    var attachments: [Attachment] = []

    /// Текст без разметки (для копирования).
    static func plainText(_ source: String) -> String {
        var out = ""
        for t in tokenize(source) {
            switch t.kind {
            case .text(let s): out += HTMLEntities.decode(s)
            case .open(let n, _): if n == "*" { out += "\n• " } else if n == "break" { out += "\n" }
            case .close: break
            }
        }
        return out
    }

    func parse(_ source: String) -> [BBBlock] {
        var tokens = Self.tokenize(source)
        tokens.reverse()
        return parseBlocks(&tokens, until: nil)
    }

    private struct Style {
        var bold = false, italic = false, underline = false, strike = false
        var link: URL?
        var color: Color?
        var small = false
    }

    private func parseBlocks(_ tokens: inout [Token], until closing: String?) -> [BBBlock] {
        var blocks: [BBBlock] = []
        var current = AttributedString()
        var styles: [(String, Style)] = [("", Style())]

        func flushText() {
            let trimmed = String(current.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(.text(current)) }
            current = AttributedString()
        }
        func append(_ s: String) {
            var a = AttributedString(HTMLEntities.decode(s))
            let st = styles.last!.1
            var font = Font.body
            if st.small { font = .footnote }
            if st.bold { font = font.bold() }
            if st.italic { font = font.italic() }
            a.font = font
            if st.underline { a.underlineStyle = .single }
            if st.strike { a.strikethroughStyle = .single }
            if let c = st.color { a.foregroundColor = c }
            if let l = st.link { a.link = l; a.foregroundColor = .accentColor }
            current += a
        }

        while let token = tokens.popLast() {
            switch token.kind {
            case .text(let s):
                append(s)
            case .close(let name):
                if name == closing { flushText(); return blocks }
                if let idx = styles.lastIndex(where: { $0.0 == name }), idx > 0 {
                    styles.removeSubrange(idx...)
                }
            case .open(let name, let arg):
                var st = styles.last!.1
                switch name {
                case "b": st.bold = true
                case "i": st.italic = true
                case "u": st.underline = true
                case "s": st.strike = true
                case "size": st.small = (Int(arg) ?? 2) <= 1
                case "sub", "sup": st.small = true
                case "color":
                    st.color = Self.color(arg)
                case "url":
                    let target = arg.isEmpty ? Self.peekText(tokens) : arg
                    st.link = PDAAPI.absoluteURL(Self.unquote(target))
                case "break":
                    append("\n"); continue
                case "*":
                    append("\n• "); continue
                case "snapback":
                    _ = Self.collectText(&tokens, until: "snapback")
                    append("↩ ")
                    continue
                case "na", "seporator", "mergetime", "anchor", "cur":
                    if name == "mergetime" { append("\n") }
                    // служебные теги без закрывающей пары — пропускаем содержимое до закрытия, если оно есть
                    continue
                case "img":
                    let url = arg.isEmpty ? Self.collectText(&tokens, until: "img") : Self.unquote(arg)
                    if let u = PDAAPI.absoluteURL(url.trimmingCharacters(in: .whitespaces)) {
                        flushText(); blocks.append(.image(u))
                    }
                    continue
                case "attachment":
                    if let block = attachmentBlock(arg) {
                        flushText(); blocks.append(block)
                    }
                    continue
                case "code":
                    flushText()
                    blocks.append(.code(HTMLEntities.decode(Self.collectText(&tokens, until: "code"))))
                    continue
                case "quote":
                    flushText()
                    let inner = parseBlocks(&tokens, until: "quote")
                    blocks.append(.quote(title: Self.quoteTitle(arg), blocks: inner))
                    continue
                case "spoiler", "hide", "offtop":
                    flushText()
                    let inner = parseBlocks(&tokens, until: name)
                    let title = arg.isEmpty ? (name == "offtop" ? "Оффтоп" : "Спойлер") : HTMLEntities.decode(Self.unquote(arg))
                    blocks.append(.spoiler(title: title, blocks: inner))
                    continue
                default:
                    break
                }
                styles.append((name, st))
            }
        }
        flushText()
        return blocks
    }

    private func attachmentBlock(_ arg: String) -> BBBlock? {
        // [attachment="12345:имя_файла.jpg"]
        let value = Self.unquote(arg)
        let idPart = value.split(separator: ":").first.map(String.init) ?? value
        let id = Int(idPart) ?? 0
        if let a = attachments.first(where: { $0.id == id }) {
            if a.isImage, let u = PDAAPI.absoluteURL(a.url) { return .image(u) }
            var text = AttributedString("📎 " + a.name)
            text.link = PDAAPI.absoluteURL(a.url)
            text.foregroundColor = .accentColor
            return .text(text)
        }
        let name = value.split(separator: ":").dropFirst().joined(separator: ":")
        return name.isEmpty ? nil : .text(AttributedString("📎 " + name))
    }

    // MARK: - Токенизация

    private static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "[", let end = s[i...].firstIndex(of: "]") {
                let inner = String(s[s.index(after: i)..<end])
                if !inner.contains("["), let tok = tagToken(inner) {
                    if !text.isEmpty { tokens.append(Token(kind: .text(text))); text = "" }
                    tokens.append(tok)
                    i = s.index(after: end)
                    continue
                }
            }
            text.append(s[i])
            i = s.index(after: i)
        }
        if !text.isEmpty { tokens.append(Token(kind: .text(text))) }
        return tokens
    }

    private static func tagToken(_ inner: String) -> Token? {
        if inner.hasPrefix("/") {
            let name = inner.dropFirst().lowercased()
            return known.contains(name) ? Token(kind: .close(name)) : nil
        }
        var name = inner
        var arg = ""
        if let eq = inner.firstIndex(where: { $0 == "=" || $0 == " " }) {
            name = String(inner[..<eq])
            arg = String(inner[inner.index(after: eq)...])
        }
        name = name.lowercased()
        guard known.contains(name) else { return nil }
        return Token(kind: .open(name, arg))
    }

    private static func collectText(_ tokens: inout [Token], until closing: String) -> String {
        var out = ""
        while let t = tokens.popLast() {
            switch t.kind {
            case .text(let s): out += s
            case .close(let n) where n == closing: return out
            case .close(let n): out += "[/\(n)]"
            case .open(let n, let a): out += a.isEmpty ? "[\(n)]" : "[\(n)=\(a)]"
            }
        }
        return out
    }

    private static func peekText(_ tokens: [Token]) -> String {
        if let t = tokens.last, case .text(let s) = t.kind { return s }
        return ""
    }

    private static func unquote(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        return v
    }

    private static func quoteTitle(_ arg: String) -> String {
        // [quote name="Ник" date="..." post=123]
        guard let r = arg.range(of: "name=\"") else { return "Цитата" }
        let rest = arg[r.upperBound...]
        let name = rest.prefix { $0 != "\"" }
        return name.isEmpty ? "Цитата" : HTMLEntities.decode(String(name))
    }

    private static func color(_ arg: String) -> Color? {
        let v = unquote(arg).lowercased()
        switch v {
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "orange": return .orange
        case "purple": return .purple
        case "gray", "grey", "label_text", "border_line": return .secondary
        default:
            let hex = v.hasPrefix("#") ? String(v.dropFirst()) : v
            guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
            return Color(red: Double((n >> 16) & 0xFF) / 255, green: Double((n >> 8) & 0xFF) / 255,
                         blue: Double(n & 0xFF) / 255)
        }
    }
}
