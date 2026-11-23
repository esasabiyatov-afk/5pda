import SwiftUI
import UIKit


/// Дерево форумов: категории и разделы.
struct ForumsView: View {
    @State private var state: LoadState<[ForumEntry]> = .loading
    @AppStorage("collapsed_categories") private var collapsedRaw = ""
    private var collapsed: Set<Int> { Set(collapsedRaw.split(separator: ",").compactMap { Int($0) }) }
    private func toggle(_ id: Int) {
        var c = collapsed
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        collapsedRaw = c.map(String.init).joined(separator: ",")
    }

    var body: some View {
        content
            .navigationTitle("Форум")
            .task { if case .loading = state { await load() } }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            ProgressView("Загрузка форумов…")
        case .failed(let message):
            ErrorView(message: message) { Task { await load() } }
        case .loaded(let entries):
            List {
                ForEach(Array(sections(entries).enumerated()), id: \.offset) { _, section in
                    Section {
                        if !collapsed.contains(section.0.id) {
                        ForEach(section.1) { forum in
                            NavigationLink(value: ForumRoute(id: forum.id, name: forum.name)) {
                                HStack {
                                    Text(forum.name)
                                    if forum.hasUnread {
                                        Spacer()
                                        Circle().fill(PDATheme.unreadDot).frame(width: 9, height: 9)
                                    }
                                }
                            }
                        }
                        }
                    } header: {
                        Button { withAnimation { toggle(section.0.id) } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: collapsed.contains(section.0.id) ? "chevron.right" : "chevron.down")
                                    .font(.caption.bold())
                                Text(section.0.name).font(.title3).textCase(nil)
                                Spacer()
                            }
                            .foregroundStyle(.primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .refreshable { await load() }
        }
    }

    private func sections(_ entries: [ForumEntry]) -> [(ForumEntry, [ForumEntry])] {
        var result: [(ForumEntry, [ForumEntry])] = []
        for e in entries {
            if e.isCategory || result.isEmpty {
                result.append((e.isCategory ? e : ForumEntry(id: -1, name: "Форумы", flags: 16, link: ""), []))
                if e.isCategory { continue }
            }
            result[result.count - 1].1.append(e)
        }
        return result
    }

    private func load() async {
        do {
            state = .loaded(try await PDAAPI.forums())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Раздел форума: подфорумы и темы.
struct ForumView: View {
    let route: ForumRoute
    @EnvironmentObject private var client: PDAClient
    @EnvironmentObject private var router: Router
    @State private var page: ForumPage?
    @State private var topics: [TopicSummary] = []
    @State private var error: String?
    @State private var loadingMore = false
    @State private var exhausted = false
    @AppStorage("dismissed_forum_message") private var dismissedMessage = ""
    @State private var showInfo = false

    var body: some View {
        Group {
            if let error = error, page == nil {
                ErrorView(message: error) { Task { await reload() } }
            } else if let page = page {
                List {
                    if !page.message.isEmpty, dismissedMessage != page.message {
                        HStack(alignment: .top) {
                            BBContentView(page.message)
                            Button { dismissedMessage = page.message } label: {
                                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if !page.announcements.isEmpty {
                        Section("Объявления") {
                            ForEach(page.announcements) { a in
                                Label(a.name, systemImage: "megaphone").font(.subheadline)
                            }
                        }
                    }
                    if !page.subforums.isEmpty {
                        Section("Подфорумы") {
                            ForEach(page.subforums) { f in
                                if !f.link.isEmpty, let url = URL(string: f.link) {
                                    // Раздел-редирект: ведёт на другой форум или сайт.
                                    Button {
                                        if let go = Router.route(for: url) { go(router) } else { UIApplication.shared.open(url) }
                                    } label: {
                                        Label(f.name, systemImage: "arrow.turn.up.right").foregroundStyle(.primary)
                                    }
                                } else {
                                    NavigationLink(value: ForumRoute(id: f.id, name: f.name)) {
                                        HStack {
                                            Text(f.name)
                                            if f.hasUnread { Spacer(); Circle().fill(PDATheme.unreadDot).frame(width: 9, height: 9) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    let pinned = topics.filter(\.isPinned)
                    if !pinned.isEmpty {
                        Section("Закреплённые") {
                            ForEach(pinned) { TopicRow(topic: $0) }
                        }
                    }
                    Section("Темы") {
                        ForEach(topics.filter { !$0.isPinned }) { t in
                            TopicRow(topic: t)
                        }
                        if topics.count < page.totalTopics, !exhausted {
                            HStack {
                                Spacer()
                                if loadingMore { ProgressView() } else {
                                    Button("Загрузить ещё") { Task { await loadMore() } }
                                }
                                Spacer()
                            }
                            .onAppear { Task { await loadMore() } }
                        }
                    }
                }
                .refreshable { await reload() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(page?.name.isEmpty == false ? page!.name : route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let page = page, client.isLoggedIn {
                Menu {
                    Button {
                        Task { try? await PDAAPI.setForumSubscribed(route.id, page.flags & 8 == 0); await reload() }
                    } label: {
                        Label(page.flags & 8 == 0 ? "В избранное" : "Убрать из избранного",
                              systemImage: page.flags & 8 == 0 ? "star" : "star.slash")
                    }
                    Button {
                        Task { try? await PDAAPI.markRead(forum: route.id); await reload() }
                    } label: { Label("Отметить прочитанным", systemImage: "eye") }
                    Button { showInfo = true } label: { Label("О форуме", systemImage: "info.circle") }
                    Button {
                        UIPasteboard.general.string = PDAConfig.siteURL.absoluteString + "forum/index.php?showforum=\(route.id)"
                    } label: { Label("Копировать ссылку", systemImage: "link") }
                    BrowserLink(destination: URL(string: PDAConfig.siteURL.absoluteString + "forum/index.php?showforum=\(route.id)")!) {
                        Label("Открыть в браузере", systemImage: "safari")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { if page == nil { await reload() } }
        .sheet(isPresented: $showInfo) { ForumInfoSheet(forumId: route.id).environmentObject(router) }
    }

    private func reload() async {
        error = nil
        do {
            let p = try await PDAAPI.forum(id: route.id)
            page = p
            topics = p.topics
            exhausted = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let page = page, !loadingMore, !exhausted, topics.count < page.totalTopics else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let more = try? await PDAAPI.forum(id: route.id, offset: topics.count) {
            let known = Set(topics.map(\.id))
            let add = more.topics.filter { !known.contains($0.id) }
            if add.isEmpty {
                // Сервер больше ничего не отдаёт — не зацикливаемся.
                exhausted = true
            } else {
                topics += add
            }
        }
    }
}

/// Строка темы как в Android: название, дата и автор последнего поста; зелёная точка
/// справа — есть новое, нажатие на неё ведёт к непрочитанному.
struct TopicRow: View {
    let topic: TopicSummary
    @EnvironmentObject private var router: Router
    @AppStorage("topic_open_mode") private var openMode = 0  // 0 — в начало, 1 — к непрочитанному, 2 — в конец

    private var defaultJump: TopicRoute.Jump {
        switch openMode {
        case 1: return topic.hasUnread ? .unread : .start
        case 2: return .last
        default: return .start
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { router.push(TopicRoute(id: topic.id, title: topic.title, jump: defaultJump)) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if topic.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        if topic.isClosed { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                        Text((topic.isMoved ? "Перемещено: " : "") + topic.title)
                            .font(.body.weight(topic.isHighlighted ? .semibold : .regular))
                            .foregroundStyle(topic.isClosed ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                    }
                    if !topic.description.isEmpty {
                        Text(topic.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 4) {
                        Text(topic.lastPostDate.pdaFormatted)
                        Image(systemName: "person.fill").font(.system(size: 9))
                        Text(topic.lastPoster)
                        if topic.postCount > 0 {
                            Text("· \(topic.postCount)")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if topic.hasUnread {
                Button { router.push(TopicRoute(id: topic.id, title: topic.title, jump: .unread)) } label: {
                    Circle().fill(PDATheme.unreadDot).frame(width: 11, height: 11).padding(10)
                }
                .buttonStyle(.borderless)
            }
        }
        .contextMenu {
            Button { router.push(TopicRoute(id: topic.id, title: topic.title, jump: .last)) } label: {
                Label("Перейти в конец", systemImage: "arrow.down.to.line")
            }
            Button { router.push(TopicRoute(id: topic.id, title: topic.title, jump: .unread)) } label: {
                Label("К непрочитанному", systemImage: "eye")
            }
            Button { Task { try? await PDAAPI.setTopicSubscribed(topic.id, true) } } label: {
                Label("В избранное", systemImage: "star")
            }
            Button {
                UIPasteboard.general.string = PDAConfig.siteURL.absoluteString + "forum/index.php?showtopic=\(topic.id)"
            } label: { Label("Копировать ссылку", systemImage: "link") }
        }
    }
}
