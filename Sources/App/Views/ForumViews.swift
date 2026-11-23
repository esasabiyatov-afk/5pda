import SwiftUI
import UIKit


/// Дерево форумов: категории и разделы.
struct ForumsView: View {
    @State private var state: LoadState<[ForumEntry]> = .loading

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
                    Section(section.0.name) {
                        ForEach(section.1) { forum in
                            NavigationLink(value: ForumRoute(id: forum.id, name: forum.name)) {
                                HStack {
                                    Text(forum.name)
                                    if forum.hasUnread {
                                        Spacer()
                                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                                    }
                                }
                            }
                        }
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

    var body: some View {
        Group {
            if let error = error, page == nil {
                ErrorView(message: error) { Task { await reload() } }
            } else if let page = page {
                List {
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
                                            if f.hasUnread { Spacer(); Circle().fill(Color.accentColor).frame(width: 8, height: 8) }
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
                    BrowserLink(destination: URL(string: PDAConfig.siteURL.absoluteString + "forum/index.php?showforum=\(route.id)")!) {
                        Label("Открыть в браузере", systemImage: "safari")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { if page == nil { await reload() } }
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

struct TopicRow: View {
    let topic: TopicSummary

    var body: some View {
        NavigationLink(value: TopicRoute(id: topic.id, title: topic.title, jump: topic.hasUnread ? .unread : .start)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if topic.hasUnread {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    }
                    Text((topic.isMoved ? "Перемещено: " : "") + topic.title)
                        .font(.subheadline.weight(topic.hasUnread ? .semibold : .regular))
                        .foregroundStyle(topic.isClosed ? .secondary : .primary)
                }
                if !topic.description.isEmpty {
                    Text(topic.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 4) {
                    if topic.isPinned { Image(systemName: "pin.fill") }
                    if topic.isClosed { Image(systemName: "lock.fill") }
                    Text("\(topic.lastPoster) · \(topic.lastPostDate.pdaFormatted)")
                    if topic.postCount > 0 {
                        Spacer()
                        Label("\(topic.postCount)", systemImage: "text.bubble")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

