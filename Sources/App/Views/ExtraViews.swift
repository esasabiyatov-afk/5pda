import SwiftUI

/// Строка результата поиска (общая для поиска и «постов/тем пользователя»).
struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        switch result {
        case .topic(let t):
            TopicRow(topic: t)
        case .post(let tid, let title, let p):
            NavigationLink(value: TopicRoute(id: tid, title: title, jump: .post(p.id))) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(PDATheme.brand).lineLimit(2)
                    HStack(spacing: 4) {
                        Text(p.authorName).foregroundStyle(PDATheme.groupColor(p.authorGroup))
                        Text("· \(p.date.pdaFormatted)").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Text(BBParser.plainText(p.bodyBB)).font(.footnote).lineLimit(5)
                }
            }
        case .article(let id, let title):
            NavigationLink(value: ArticleRoute(id: id)) { Text(title) }
        }
    }
}

/// Темы или сообщения пользователя (из профиля).
struct UserContentView: View {
    let userId: Int
    let nick: String
    let topics: Bool
    @State private var items: [SearchResult] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let e = error { Text(e).foregroundStyle(.red) }
            if loaded, items.isEmpty, error == nil { Text("Ничего нет").foregroundStyle(.secondary) }
            ForEach(items) { r in
                SearchResultRow(result: r)
                    .onAppear { if r.id == items.last?.id { Task { await load(more: true) } } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.plain)
        .navigationTitle(topics ? "Темы \(nick)" : "Посты \(nick)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(more: false) }
        .task { if !loaded { await load(more: false) } }
    }

    private func load(more: Bool) async {
        guard !loading, !more || items.count < total else { return }
        loading = true
        defer { loading = false; loaded = true }
        do {
            let r = try await PDAAPI.searchByAuthor(userId, topics: topics, offset: more ? items.count : 0)
            items = more ? items + r.items : r.items
            total = r.total
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// История репутации.
struct ReputationHistorySheet: View {
    let userId: Int
    let nick: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: Router
    @State private var given = false
    @State private var items: [PDAAPI.ReputationEntry] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Picker("", selection: $given) {
                    Text("Полученная").tag(false)
                    Text("Выставленная").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let e = error { Text(e).foregroundStyle(.red) }
                if !loading, items.isEmpty, error == nil { Text("Пусто").foregroundStyle(.secondary) }
                ForEach(items) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: r.positive ? "plus.circle.fill" : "minus.circle.fill")
                                .foregroundStyle(r.positive ? .green : .red)
                            Text(r.fromNick).bold()
                            Spacer()
                            Text(r.date.pdaFormatted).font(.caption).foregroundStyle(.secondary)
                        }
                        if !r.whereTitle.isEmpty {
                            Text(r.whereTitle).font(.caption).foregroundStyle(PDATheme.brand).lineLimit(2)
                        }
                        BBContentView(r.reasonBB)
                        if r.cancelled { Text("Отменено").font(.caption).foregroundStyle(.red) }
                    }
                    .opacity(r.cancelled ? 0.55 : 1)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Репутация \(nick)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task(id: given) { await load() }
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do { items = try await PDAAPI.reputationHistory(userId: userId, given: given) } catch {
            items = []
            self.error = error.localizedDescription
        }
    }
}

/// Настройки — по списку из Android-клиента (то, что имеет смысл на iOS).
struct SettingsView: View {
    @AppStorage("font_scale") private var fontScale = 1.0
    @AppStorage("load_images") private var loadImages = true
    @AppStorage("show_signatures") private var showSignatures = true
    @AppStorage("collapse_header") private var collapseHeader = false
    @AppStorage("collapse_polls") private var collapsePolls = false
    @AppStorage("topic_open_mode") private var openMode = 0
    @AppStorage("confirm_actions") private var confirmActions = true
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("tags_below") private var tagsBelow = false

    var body: some View {
        Form {
            Section("Внешний вид") {
                Picker("Тема", selection: $appearance) {
                    Text("Как в системе").tag(0)
                    Text("Светлая").tag(1)
                    Text("Тёмная").tag(2)
                }
                VStack(alignment: .leading) {
                    Text("Размер шрифта: \(Int(fontScale * 100))%")
                    Slider(value: $fontScale, in: 0.8...1.5, step: 0.05)
                }
                Toggle("Отображать подписи", isOn: $showSignatures)
                Toggle("Сворачивать шапки тем", isOn: $collapseHeader)
                Toggle("Сворачивать опросы", isOn: $collapsePolls)
                Toggle("Панель тегов под текстом", isOn: $tagsBelow)
            }
            Section("Управление") {
                Picker("Переход в тему", selection: $openMode) {
                    Text("В начало").tag(0)
                    Text("К непрочитанному").tag(1)
                    Text("В конец").tag(2)
                }
                Toggle("Подтверждение действий", isOn: $confirmActions)
            }
            Section {
                Toggle("Загружать изображения", isOn: $loadImages)
                Button("Очистить кэш изображений") { ImageLoader.shared.clear() }
            } header: { Text("Изображения") } footer: {
                Text("Когда загрузка отключена, картинку можно открыть нажатием на неё.")
            }
        }
        .navigationTitle("Настройки")
    }
}
