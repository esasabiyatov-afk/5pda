import SwiftUI
import UIKit

/// Состояние загрузки экрана.
enum LoadState<T> {
    case loading
    case loaded(T)
    case failed(String)
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Повторить", action: retry)
                .buttonStyle(.borderedProminent)
            NavigationLink("Журнал соединения", value: MoreRoute.log)
                .font(.footnote)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Отображение BB-разметки.
struct BBContentView: View {
    let blocks: [BBBlock]

    init(_ source: String, attachments: [Attachment] = []) {
        self.blocks = BBParseCache.blocks(source, attachments: attachments)
    }

    init(blocks: [BBBlock]) {
        self.blocks = blocks
    }

    @AppStorage("font_scale") private var fontScale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BBBlockView(block: block)
            }
        }
        .dynamicTypeSize(Self.typeSize(fontScale))
    }

    /// Размер шрифта из настроек → ступень Dynamic Type.
    static func typeSize(_ scale: Double) -> DynamicTypeSize {
        switch scale {
        case ..<0.85: return .xSmall
        case ..<0.95: return .small
        case ..<1.05: return .large
        case ..<1.15: return .xLarge
        case ..<1.25: return .xxLarge
        case ..<1.35: return .xxxLarge
        default: return .accessibility1
        }
    }
}

struct BBBlockView: View {
    let block: BBBlock
    @State private var expanded = false
    @Environment(\.multilineTextAlignment) private var textAlignment

    private var frameAlignment: Alignment {
        switch textAlignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    /// Заголовок спойлера может содержать разметку (иконки, цвет).
    static func titleText(_ bb: String) -> Text {
        guard bb.contains("[") else { return Text(bb).font(.body) }
        let parts = BBParser().parse(bb).compactMap { b -> AttributedString? in
            if case .text(let t) = b { return t } else { return nil }
        }
        return parts.isEmpty ? Text(BBParser.plainText(bb)) : render(parts.reduce(AttributedString(), +))
    }

    /// Текст со смайлами: куски с ссылкой pdasmile:// заменяются картинками.
    static func render(_ text: AttributedString) -> Text {
        guard text.runs.contains(where: { $0.link?.scheme == "pdasmile" }) else { return Text(text) }
        var result = Text("")
        for run in text.runs {
            if let link = run.link, link.scheme == "pdasmile", let name = link.host, let img = Smilies.image(name) {
                result = result + Text(Image(uiImage: img)).baselineOffset(-3)
            } else {
                result = result + Text(AttributedString(text[run.range]))
            }
        }
        return result
    }

    var body: some View {
        switch block {
        case .text(let text):
            Self.render(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
        case .image(let url):
            PostImage(url: url)
        case .aligned(let a, let inner):
            VStack(alignment: a == 1 ? .center : .trailing, spacing: 8) {
                ForEach(Array(inner.enumerated()), id: \.offset) { _, b in
                    BBBlockView(block: b)
                        .multilineTextAlignment(a == 1 ? .center : .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: a == 1 ? .center : .trailing)
        case .video(let id):
            Button {
                if let u = URL(string: "https://www.youtube.com/watch?v=\(id)") { UIApplication.shared.open(u) }
            } label: {
                ZStack {
                    RemoteImage(url: URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg"), contentMode: .fill) {
                        Color.black
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                    Image(systemName: "play.circle.fill").font(.system(size: 54))
                        .foregroundStyle(.white, .red)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        case .quote(let title, let blocks):
            HStack(spacing: 0) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                    BBContentView(blocks: blocks)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.secondary.opacity(0.08))
        case .spoiler(let title, let blocks):
            // Как в Android: рамка с синей полосой слева, «Спойлер: заголовок».
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 0) {
                        Rectangle().fill(PDATheme.spoilerBar).frame(width: 5)
                        (Text(title == "Оффтоп" ? "" : "Спойлер: ").font(.footnote).foregroundColor(.secondary)
                         + Self.titleText(title))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 8).padding(.vertical, 9)
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary).padding(.trailing, 8)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    BBContentView(blocks: blocks).padding(10)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(PDATheme.spoilerBar.opacity(0.6), lineWidth: 1))
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension Date {
    /// Как в Android-клиенте: «Сегодня, 19:15», «Вчера, 8:02», «19.11.26, 10:24».
    var pdaFormatted: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Сегодня, " + Self.timeFormatter.string(from: self) }
        if cal.isDateInYesterday(self) { return "Вчера, " + Self.timeFormatter.string(from: self) }
        return Self.fullFormatter.string(from: self)
    }

    /// Только время для сегодняшних, иначе дата — для списков новостей.
    var pdaShort: String {
        Calendar.current.isDateInToday(self) ? Self.timeFormatter.string(from: self) : Self.fullFormatter.string(from: self)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "H:mm"; return f
    }()
    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d.MM.yy, H:mm"; return f
    }()
}

/// Кэш разобранной BB-разметки: при прокрутке SwiftUI пересоздаёт представления,
/// и без кэша текст постов разбирался заново каждый раз.
enum BBParseCache {
    private static var cache: [String: [BBBlock]] = [:]
    private static var order: [String] = []
    private static let lock = NSLock()

    static func blocks(_ source: String, attachments: [Attachment]) -> [BBBlock] {
        let key = source + "\u{1}" + attachments.map { "\($0.id)" }.joined(separator: ",")
        lock.lock()
        if let b = cache[key] { lock.unlock(); return b }
        lock.unlock()
        let b = BBParser(attachments: attachments).parse(source)
        lock.lock()
        cache[key] = b
        order.append(key)
        if order.count > 400 { cache[order.removeFirst()] = nil }
        lock.unlock()
        return b
    }
}
