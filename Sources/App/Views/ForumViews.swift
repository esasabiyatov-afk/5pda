import SwiftUI

struct ForumRoute: Hashable { let id: Int; let name: String }
struct TopicRoute: Hashable { let id: Int; let title: String }

/// Дерево форумов: категории и разделы.
struct ForumsView: View {
    @State private var state: LoadState<[ForumEntry]> = .loading

    var body: some View {
        content
            .navigationTitle("Форум")
            .navigationDestination(for: ForumRoute.self) { ForumView(route: $0) }
            .navigationDestination(for: TopicRoute.self) { TopicView(route: $0) }
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
    @State private var page: ForumPage?
    @State private var topics: [TopicSummary] = []
    @State private var error: String?
    @State private var loadingMore = false

    var body: some View {
        Group {
            if let error = error, page == nil {
                ErrorView(message: error) { Task { await reload() } }
            } else if let page = page {
                List {
                    if !page.subforums.isEmpty {
                        Section("Подфорумы") {
                            ForEach(page.subforums) { f in
                                NavigationLink(f.name, value: ForumRoute(id: f.id, name: f.name))
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
                                .onAppear { if t.id == topics.last?.id { Task { await loadMore() } } }
                        }
                        if loadingMore { ProgressView().frame(maxWidth: .infinity) }
                    }
                }
                .refreshable { await reload() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(page?.name.isEmpty == false ? page!.name : route.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == nil { await reload() } }
    }

    private func reload() async {
        error = nil
        do {
            let p = try await PDAAPI.forum(id: route.id)
            page = p
            topics = p.topics
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let page = page, !loadingMore, topics.count < page.totalTopics else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let more = try? await PDAAPI.forum(id: route.id, offset: topics.count) {
            let known = Set(topics.map(\.id))
            topics += more.topics.filter { !known.contains($0.id) }
        }
    }
}

struct TopicRow: View {
    let topic: TopicSummary

    var body: some View {
        NavigationLink(value: TopicRoute(id: topic.id, title: topic.title)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if topic.hasUnread {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    }
                    Text((topic.isMoved ? "Перемещено: " : "") + topic.title)
                        .font(.subheadline.weight(topic.hasUnread ? .semibold : .regular))
                        .foregroundStyle(topic.isClosed ? .secondary : .primary)
                }
                Text("\(topic.lastPoster) · \(topic.lastPostDate.pdaFormatted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Тема: посты постранично.
struct TopicView: View {
    let route: TopicRoute
    @State private var page: TopicPage?
    @State private var offset = 0
    @State private var error: String?
    @State private var loading = false

    private var pageCount: Int {
        guard let total = page?.totalPosts, total > 0 else { return 1 }
        return (total + PDAAPI.postsPerPage - 1) / PDAAPI.postsPerPage
    }
    private var currentPage: Int { offset / PDAAPI.postsPerPage + 1 }

    var body: some View {
        Group {
            if let error = error, page == nil {
                ErrorView(message: error) { Task { await load(offset) } }
            } else if let page = page {
                ScrollViewReader { proxy in
                    List {
                        ForEach(page.posts) { post in
                            PostView(post: post).id(post.id)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: offset) { _ in
                        if let first = page.posts.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
                .overlay { if loading { ProgressView() } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(page?.title ?? route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { Task { await load(0) } } label: { Image(systemName: "chevron.backward.2") }
                    .disabled(currentPage <= 1)
                Button { Task { await load(offset - PDAAPI.postsPerPage) } } label: { Image(systemName: "chevron.backward") }
                    .disabled(currentPage <= 1)
                Spacer()
                Text("\(currentPage) / \(pageCount)").font(.footnote).monospacedDigit()
                Spacer()
                Button { Task { await load(offset + PDAAPI.postsPerPage) } } label: { Image(systemName: "chevron.forward") }
                    .disabled(currentPage >= pageCount)
                Button { Task { await load((pageCount - 1) * PDAAPI.postsPerPage) } } label: { Image(systemName: "chevron.forward.2") }
                    .disabled(currentPage >= pageCount)
            }
        }
        .task { if page == nil { await load(0) } }
    }

    private func load(_ newOffset: Int) async {
        loading = true
        defer { loading = false }
        error = nil
        do {
            let p = try await PDAAPI.topic(id: route.id, offset: max(0, newOffset))
            page = p
            offset = max(0, newOffset)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PostView: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AsyncImage(url: PDAAPI.absoluteURL(post.avatar)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                VStack(alignment: .leading) {
                    Text(post.authorName).font(.subheadline.bold())
                    Text(post.date.pdaFormatted).font(.caption).foregroundStyle(.secondary)
                }
            }
            BBContentView(post.bodyBB, attachments: post.attachments)
        }
        .padding(.vertical, 6)
    }
}
