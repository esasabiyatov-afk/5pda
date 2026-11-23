import SwiftUI

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
        self.blocks = BBParser(attachments: attachments).parse(source)
    }

    init(blocks: [BBBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BBBlockView(block: block)
            }
        }
    }
}

struct BBBlockView: View {
    let block: BBBlock
    @State private var expanded = false

    var body: some View {
        switch block {
        case .text(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let url):
            PostImage(url: url)
        case .quote(let title, let blocks):
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                BBContentView(blocks: blocks)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .spoiler(let title, let blocks):
            DisclosureGroup(isExpanded: $expanded) {
                BBContentView(blocks: blocks).padding(.top, 4)
            } label: {
                Text(title).font(.subheadline.bold())
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
    var pdaFormatted: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: self)
    }
}
