import SwiftUI

/// Требует входа: показывает подсказку, если пользователь не вошёл.
struct LoginRequired<Content: View>: View {
    @EnvironmentObject private var client: PDAClient
    let content: () -> Content

    var body: some View {
        if client.isLoggedIn {
            content()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.largeTitle).foregroundStyle(.secondary)
                Text("Нужно войти в аккаунт").foregroundStyle(.secondary)
                NavigationLink("Войти", value: MoreRoute.account)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Избранное

struct FavoritesView: View {
    @EnvironmentObject private var router: Router
    @State private var items: [FavoriteItem] = []
    @State private var total = 0
    @State private var error: String?
    @State private var loaded = false
    @State private var alert: ActionAlert?

    var body: some View {
        LoginRequired {
            content
        }
        .navigationTitle("Избранное")
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
    }

    @ViewBuilder private var content: some View {
        if let e = error, items.isEmpty {
            ErrorView(message: e) { Task { await reload() } }
        } else if !loaded {
            ProgressView().task { await reload() }
        } else if items.isEmpty {
            Text("В избранном пусто").foregroundStyle(.secondary)
        } else {
            List {
                let important = items.filter(\.isImportant)
                if !important.isEmpty {
                    Section("Важные") { ForEach(important, id: \.uid) { row($0) } }
                }
                Section("Темы / Форумы") {
                    ForEach(items.filter { !$0.isImportant }, id: \.uid) { item in
                        row(item).onAppear { if item.uid == items.last?.uid { Task { await loadMore() } } }
                    }
                }
            }
            .refreshable { await reload() }
            .toolbar {
                Menu {
                    Button("Отметить всё прочитанным") { Task { await markAllRead() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: FavoriteItem) -> some View {
        Group {
            if item.isForum {
                NavigationLink(value: ForumRoute(id: item.id, name: item.title)) { rowLabel(item) }
            } else {
                NavigationLink(value: TopicRoute(id: item.id, title: item.title, jump: item.hasUnread ? .unread : .start)) {
                    rowLabel(item)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) { Task { await remove(item) } } label: { Label("Отписаться", systemImage: "star.slash") }
            Button { Task { await setImportant(item, !item.isImportant) } } label: {
                Label(item.isImportant ? "Не важно" : "Важное", systemImage: "flag")
            }.tint(.orange)
        }
        .contextMenu {
            if !item.isForum {
                Button { router.push(TopicRoute(id: item.id, title: item.title, jump: .last)) } label: { Label("Перейти в конец", systemImage: "arrow.down.to.line") }
                Button { router.push(TopicRoute(id: item.id, title: item.title, jump: .start)) } label: { Label("Перейти в начало", systemImage: "arrow.up.to.line") }
            }
            Button { Task { await setImportant(item, !item.isImportant) } } label: {
                Label(item.isImportant ? "Убрать из важных" : "Добавить в важные", systemImage: "flag")
            }
            Menu("Оповещения") {
                Button("Оповещать всегда") { Task { await setNotify(item, 0) } }
                Button("Оповещать один раз") { Task { await setNotify(item, 1) } }
                Button("Не оповещать") { Task { await setNotify(item, 2) } }
            }
            Button { Task { await markRead(item) } } label: { Label("Отметить прочитанным", systemImage: "eye") }
            Button(role: .destructive) { Task { await remove(item) } } label: { Label("Удалить из избранного", systemImage: "star.slash") }
        }
    }

    private func rowLabel(_ item: FavoriteItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if item.hasUnread { Circle().fill(PDATheme.unreadDot).frame(width: 9, height: 9) }
                if item.isForum { Image(systemName: "folder").foregroundStyle(.secondary) }
                Text(item.title)
                    .font(.subheadline.weight(item.hasUnread ? .semibold : .regular))
                    .foregroundStyle(item.isClosed ? .secondary : .primary)
            }
            if !item.isForum {
                Text("\(item.lastPoster) · \(item.lastDate.pdaFormatted)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        error = nil
        do {
            let r = try await PDAAPI.favorites()
            items = r.items
            total = r.total
        } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func loadMore() async {
        guard items.count < total else { return }
        if let r = try? await PDAAPI.favorites(offset: items.count) {
            let known = Set(items.map(\.uid))
            items += r.items.filter { !known.contains($0.uid) }
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        do { try await work(); await reload() } catch { alert = ActionAlert(title: "Ошибка", message: error.localizedDescription) }
    }

    private func remove(_ item: FavoriteItem) async {
        await perform { try await PDAAPI.objectAction(type: item.isForum ? 21 : 11, ids: [item.id], mask: 8, value: 0) }
    }
    private func setImportant(_ item: FavoriteItem, _ on: Bool) async {
        await perform { try await PDAAPI.objectAction(type: item.isForum ? 21 : 11, ids: [item.id], mask: 1, value: (on ? 1 : 0) | 8) }
    }
    private func markRead(_ item: FavoriteItem) async {
        await perform { try await PDAAPI.objectAction(type: item.isForum ? 21 : 11, ids: [item.id], mask: 32, value: 0) }
    }
    /// Режим оповещений (`fm` тип 15): 0 — всегда, 1 — один раз, 2 — не оповещать; бит 4 сохраняется.
    private func setNotify(_ item: FavoriteItem, _ mode: Int) async {
        let value = (item.notifyMode & 4) | mode
        await perform { try await PDAAPI.objectAction(type: 15, ids: [item.id], mask: value, value: 0) }
    }
    private func markAllRead() async {
        await perform { try await PDAAPI.objectAction(type: 21, ids: [-1], mask: 32, value: 8) }
    }
}

// MARK: - История

struct HistoryView: View {
    @State private var items: [TopicSummary] = []
    @State private var total = 0
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        LoginRequired {
            Group {
                if let e = error, items.isEmpty {
                    ErrorView(message: e) { Task { await reload() } }
                } else if !loaded {
                    ProgressView().task { await reload() }
                } else if items.isEmpty {
                    Text("История пуста").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(items) { t in
                            TopicRow(topic: t).onAppear { if t.id == items.last?.id { Task { await loadMore() } } }
                        }
                    }
                    .refreshable { await reload() }
                }
            }
        }
        .navigationTitle("История")
    }

    private func reload() async {
        error = nil
        do { let r = try await PDAAPI.history(); items = r.items; total = r.total } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func loadMore() async {
        guard items.count < total, let r = try? await PDAAPI.history(offset: items.count) else { return }
        let known = Set(items.map(\.id))
        items += r.items.filter { !known.contains($0.id) }
    }
}

// MARK: - Упоминания

struct MentionsView: View {
    @State private var items: [MentionItem] = []
    @State private var total = 0
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        LoginRequired {
            Group {
                if let e = error, items.isEmpty {
                    ErrorView(message: e) { Task { await reload() } }
                } else if !loaded {
                    ProgressView().task { await reload() }
                } else if items.isEmpty {
                    Text("Упоминаний нет").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(items) { m in
                            Group {
                                if m.isSite {
                                    NavigationLink(value: ArticleRoute(id: m.targetId)) { mentionLabel(m) }
                                } else {
                                    NavigationLink(value: TopicRoute(id: m.targetId, title: m.title,
                                                                     jump: m.post.map { TopicRoute.Jump.post($0.id) } ?? TopicRoute.Jump.start)) { mentionLabel(m) }
                                }
                            }
                            .onAppear { if m.id == items.last?.id { Task { await loadMore() } } }
                        }
                    }
                    .refreshable { await reload() }
                }
            }
        }
        .navigationTitle("Упоминания")
    }

    private func mentionLabel(_ m: MentionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if m.unread { Circle().fill(PDATheme.unreadDot).frame(width: 9, height: 9) }
                Image(systemName: m.isSite ? "newspaper" : "bubble.left").foregroundStyle(.secondary)
                Text(m.title).font(.subheadline.bold()).lineLimit(2)
            }
            if let p = m.post {
                Text("\(p.authorName) · \(p.date.pdaFormatted)").font(.caption).foregroundStyle(.secondary)
                Text(BBParser.previewText(p.bodyBB)).font(.footnote).lineLimit(4)
            }
        }
    }

    private func reload() async {
        error = nil
        do { let r = try await PDAAPI.mentions(); items = r.items; total = r.total } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func loadMore() async {
        guard items.count < total, let r = try? await PDAAPI.mentions(offset: items.count) else { return }
        let known = Set(items.map(\.id))
        items += r.items.filter { !known.contains($0.id) }
    }
}

// MARK: - Поиск

struct SearchView: View {
    var topicId: Int? = nil
    var topicTitle: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope: PDAAPI.SearchScope = .all
    @State private var results: [SearchResult] = []
    @State private var total = 0
    @State private var searching = false
    @State private var error: String?
    @State private var searched = false

    var body: some View {
        List {
            Section {
                TextField(topicId == nil ? "Поиск по форуму" : "Поиск в теме", text: $query)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                if topicId == nil {
                    Picker("Где искать", selection: $scope) {
                        Text("Везде").tag(PDAAPI.SearchScope.all)
                        Text("В заголовках").tag(PDAAPI.SearchScope.titles)
                        Text("В сообщениях").tag(PDAAPI.SearchScope.posts)
                    }
                }
                Button("Найти") { Task { await search() } }.disabled(query.isEmpty || searching)
            } footer: {
                if let e = error { Text(e).foregroundStyle(.red) }
                else if searched { Text("Найдено: \(total)") }
            }
            ForEach(results) { r in SearchResultRow(result: r) }
            if results.count < total, !results.isEmpty {
                Button("Ещё") { Task { await search(more: true) } }
            }
        }
        .overlay { if searching { ProgressView() } }
        .navigationTitle(topicTitle.map { "Поиск: \($0)" } ?? "Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if topicId != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
        }
    }

    private func search(more: Bool = false) async {
        searching = true
        defer { searching = false }
        error = nil
        do {
            let r = try await PDAAPI.search(query, scope: topicId != nil ? .posts : scope, topicId: topicId,
                                            offset: more ? results.count : 0)
            results = more ? results + r.items : r.items
            total = r.total
            searched = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
