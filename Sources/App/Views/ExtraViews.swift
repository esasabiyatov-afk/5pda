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

/// «О форуме» как в Android-клиенте.
struct ForumInfoSheet: View {
    let forumId: Int
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: Router
    @State private var info: PDAAPI.ForumInfo?
    @State private var error: String?

    private var link: URL { URL(string: PDAConfig.siteURL.absoluteString + "forum/index.php?showforum=\(forumId)")! }

    var body: some View {
        NavigationStack {
            Group {
                if let i = info {
                    List {
                        Section {
                            if !i.description.isEmpty { Text(i.description) }
                            LabeledContent("Подфорумов") { Text("\(i.subforums)").bold() }
                            LabeledContent("Топиков") { Text("\(i.topics)").bold() }
                            LabeledContent("Постов") { Text("\(i.posts)").bold() }
                        }
                        if !i.moderators.isEmpty {
                            Section("Модераторы") {
                                ForEach(Array(i.moderators.enumerated()), id: \.offset) { _, m in
                                    Button {
                                        dismiss()
                                        if m.id > 0 { router.push(ProfileRoute(id: m.id, nick: m.nick)) }
                                    } label: {
                                        Text(m.nick).foregroundStyle(PDATheme.groupColor(m.group))
                                    }
                                }
                            }
                        }
                        Section {
                            ShareLink(item: link) { Label(link.absoluteString, systemImage: "square.and.arrow.up").font(.footnote) }
                        }
                    }
                    .navigationTitle(i.name)
                } else if let e = error {
                    Text(e).foregroundStyle(.red).padding()
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task {
                do { info = try await PDAAPI.forumInfo(forumId) } catch { self.error = error.localizedDescription }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// «О теме»: по данным открытой темы.
struct TopicInfoSheet: View {
    let page: TopicPage
    let created: Date?
    let authorNick: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: Router

    private var link: URL { URL(string: PDAConfig.siteURL.absoluteString + "forum/index.php?showtopic=\(page.id)")! }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !page.description.isEmpty { Text(page.description) }
                    if page.authorId > 0 {
                        Button {
                            dismiss()
                            router.push(ProfileRoute(id: page.authorId, nick: authorNick))
                        } label: {
                            LabeledContent("Автор") { Text(authorNick.isEmpty ? "#\(page.authorId)" : authorNick) }
                        }
                    }
                    if let c = created { LabeledContent("Создана", value: c.pdaFormatted) }
                    LabeledContent("Постов") { Text("\(page.totalPosts)").bold() }
                    if page.flags & 16 != 0 { Label("Тема закрыта", systemImage: "lock.fill") }
                }
                Section {
                    ShareLink(item: link) { Label(link.absoluteString, systemImage: "square.and.arrow.up").font(.footnote) }
                }
            }
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Объявление раздела или правила форума.
struct AnnouncementView: View {
    let id: Int
    let title: String
    @State private var body_: String?
    @State private var loadedTitle = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let b = body_ {
                BBContentView(b).padding()
            } else if let e = error {
                ErrorView(message: e) { Task { await load() } }
            } else {
                ProgressView().padding(.top, 40)
            }
        }
        .navigationTitle(loadedTitle.isEmpty ? title : loadedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { if body_ == nil { await load() } }
    }

    private func load() async {
        error = nil
        do {
            let a = try await PDAAPI.announcement(id)
            loadedTitle = a.title
            body_ = a.bodyBB
        } catch { self.error = error.localizedDescription }
    }
}

/// Создание темы по форме раздела (как Form_Wizard в Android-клиенте).
struct CreateTopicView: View {
    let forumId: Int
    let forumName: String
    let onCreated: (Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [PDAAPI.FormField] = []
    @State private var loading = true
    @State private var sending = false
    @State private var error: String?
    @State private var fieldErrors: [Int: String] = [:]
    @StateObject private var editor = BBEditorController()
    @StateObject private var uploader = AttachmentUploader()

    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let e = error { Text(e).foregroundStyle(.red) }
                ForEach($fields) { $f in
                    Section {
                        switch f.type {
                        case "text":
                            TextField(f.title, text: $f.text)
                        case "editor":
                            BBToolbar(controller: editor)
                            BBTextView(text: $f.text, controller: editor, autoFocus: false)
                                .frame(minHeight: 220)
                        case "dropdown":
                            Picker(f.title, selection: $f.selected) {
                                ForEach(Array(f.options.enumerated()), id: \.offset) { i, o in Text(o).tag(i) }
                            }
                        case "checkbox_list":
                            ForEach(Array(f.options.enumerated()), id: \.offset) { i, o in
                                Toggle(o, isOn: Binding(get: { f.checked.contains(i) },
                                                        set: { on in if on { f.checked.insert(i) } else { f.checked.remove(i) } }))
                            }
                        case "upload_box":
                            AttachmentBar(uploader: uploader, editor: editor)
                        default:
                            if !f.text.isEmpty { BBContentView(f.text) }
                        }
                    } header: {
                        Text(f.title + (f.required ? " *" : ""))
                    } footer: {
                        VStack(alignment: .leading) {
                            if !f.description.isEmpty { Text(f.description) }
                            if let m = fieldErrors[f.id] { Text(m).foregroundStyle(.red) }
                        }
                    }
                }
            }
            .navigationTitle("Новая тема")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else {
                        Button("Создать") { Task { await submit() } }.disabled(fields.isEmpty)
                    }
                }
            }
            .task { await load() }
        }
        .interactiveDismissDisabled(fields.contains { $0.type == "editor" && !$0.text.isEmpty })
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { fields = try await PDAAPI.topicForm(forumId: forumId) } catch { self.error = error.localizedDescription }
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        error = nil
        fieldErrors = [:]
        var send = fields
        for i in send.indices where send[i].type == "upload_box" { send[i].attachments = uploader.items.compactMap(\.id) }
        do {
            let id = try await PDAAPI.submitTopic(forumId: forumId, fields: send)
            let title = send.first(where: { $0.type == "text" })?.text ?? forumName
            dismiss()
            onCreated(id, title)
        } catch let e as PDAAPI.FormErrors {
            fieldErrors = e.messages
            error = e.general
        } catch {
            self.error = error.localizedDescription
        }
    }
}
