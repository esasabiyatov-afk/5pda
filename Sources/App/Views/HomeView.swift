import SwiftUI
import UIKit

/// Счётчики непрочитанного (QMS, избранное, упоминания) — обновляются, пока приложение открыто.
@MainActor
final class UnreadStore: ObservableObject {
    static let shared = UnreadStore()
    @Published var counters = PDAAPI.UnreadCounters()
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func refresh() async {
        guard PDAClient.shared.isLoggedIn else { counters = .init(); return }
        if let c = try? await PDAAPI.unreadCounters() { counters = c }
    }
}

/// Выбранная вкладка — чтобы кнопки главной могли переключать вкладки.
@MainActor
final class TabSelection: ObservableObject {
    enum Tab: Hashable { case home, site, forum, favorites, qms }
    @Published var tab: Tab = .home
}

/// «Домашняя» как в Android: шесть кнопок со счётчиками и закладки.
struct HomeView: View {
    @EnvironmentObject private var client: PDAClient
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var tabs: TabSelection
    @EnvironmentObject private var unread: UnreadStore
    @State private var bookmarks: [PDAAPI.Bookmark] = []
    @State private var loadedBookmarks = false
    @State private var openFolders: Set<Int> = []

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    homeButton("САЙТ", count: 0) { tabs.tab = .site }
                    homeButton("QMS", count: unread.counters.qms) { tabs.tab = .qms }
                    homeButton("ФОРУМ", count: 0) { tabs.tab = .forum }
                    homeButton("ИЗБРАННОЕ", count: unread.counters.favorites) { tabs.tab = .favorites }
                    homeButton("ИСТОРИЯ", count: 0) { router.push(MoreRoute.history) }
                    homeButton("УПОМИНАНИЯ", count: unread.counters.mentions) { router.push(MoreRoute.mentions) }
                }
                .padding(12)
                .listRowInsets(EdgeInsets())
                .listRowBackground(PDATheme.brand)
            }
            Section("Закладки") {
                if !client.isLoggedIn {
                    Text("Войдите, чтобы видеть закладки").foregroundStyle(.secondary)
                } else if !loadedBookmarks {
                    ProgressView().frame(maxWidth: .infinity)
                } else if bookmarks.isEmpty {
                    Text("Закладок нет").foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.bookmark.id) { row in
                        bookmarkRow(row.bookmark, depth: row.depth)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("4PDA")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                NavigationLink(value: MoreRoute.more) {
                    Image(systemName: client.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(value: MoreRoute.search) { Image(systemName: "magnifyingglass") }
            }
        }
        .refreshable { await load() }
        .task { if !loadedBookmarks { await load() } }
        .task { ScreenshotRoute.apply(router: router, tabs: tabs) }
        .onChange(of: client.memberId) { _ in Task { await load() } }
    }

    private struct Row { let bookmark: PDAAPI.Bookmark; let depth: Int }

    /// Плоский список с учётом раскрытых папок.
    private var rows: [Row] {
        var out: [Row] = []
        func add(parent: Int, depth: Int) {
            for b in bookmarks where b.parent == parent && b.id != parent {
                out.append(Row(bookmark: b, depth: depth))
                if b.isFolder, openFolders.contains(b.id), depth < 5 { add(parent: b.id, depth: depth + 1) }
            }
        }
        add(parent: 0, depth: 0)
        if out.isEmpty { out = bookmarks.map { Row(bookmark: $0, depth: 0) } }
        return out
    }

    @ViewBuilder
    private func bookmarkRow(_ b: PDAAPI.Bookmark, depth: Int) -> some View {
        Button {
            if b.isFolder {
                if openFolders.contains(b.id) { openFolders.remove(b.id) } else { openFolders.insert(b.id) }
            } else {
                open(b)
            }
        } label: {
            HStack(spacing: 8) {
                if b.isFolder {
                    Image(systemName: openFolders.contains(b.id) ? "folder.fill" : "folder").foregroundStyle(PDATheme.brand)
                }
                Text(b.title).lineLimit(1).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { try? await PDAAPI.deleteBookmark(b); await load() }
            } label: { Label("Удалить закладку", systemImage: "trash") }
            if !b.url.isEmpty {
                Button { UIPasteboard.general.string = absolute(b.url)?.absoluteString } label: {
                    Label("Копировать ссылку", systemImage: "link")
                }
                Button { if let u = absolute(b.url) { UIApplication.shared.open(u) } } label: {
                    Label("Открыть в браузере", systemImage: "safari")
                }
            }
        }
    }

    private func absolute(_ s: String) -> URL? { PDAAPI.absoluteURL(s) }

    private func open(_ b: PDAAPI.Bookmark) {
        guard let url = absolute(b.url) else { return }
        if let go = Router.route(for: url) { go(router) } else { UIApplication.shared.open(url) }
    }

    private func homeButton(_ title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .trailing) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(PDATheme.brand)
                    .frame(maxWidth: .infinity, minHeight: 50)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(PDATheme.unreadDot, in: Capsule())
                        .padding(.trailing, 10)
                }
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        await unread.refresh()
        guard client.isLoggedIn else { bookmarks = []; loadedBookmarks = true; return }
        bookmarks = (try? await PDAAPI.bookmarks()) ?? []
        loadedBookmarks = true
    }
}

/// Открытие экрана по аргументу запуска `-screenshotRoute` — для автоматических
/// скриншотов в симуляторе (topic:ID, forum:ID, article:ID, profile:ID, tab:site …).
enum ScreenshotRoute {
    @MainActor static func apply(router: Router, tabs: TabSelection) {
        guard let raw = UserDefaults.standard.string(forKey: "screenshotRoute"), !raw.isEmpty else { return }
        // Для отладки в симуляторе: журнал соединения пишется в Documents/log.txt.
        Task { @MainActor in
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("log.txt")
            while true {
                let text = PDAClient.shared.log.map { ($0.outgoing ? "→ " : "← ") + String($0.text.prefix(3000)) }.joined(separator: "\n")
                try? text.write(to: url, atomically: true, encoding: .utf8)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let id = Int(arg) ?? 0
        switch parts[0] {
        case "tab":
            switch arg {
            case "site": tabs.tab = .site
            case "forum": tabs.tab = .forum
            case "favorites": tabs.tab = .favorites
            case "qms": tabs.tab = .qms
            default: tabs.tab = .home
            }
        case "topic": router.push(TopicRoute(id: id, title: "Тема"))
        case "forum": router.push(ForumRoute(id: id, name: "Форум"))
        case "article": router.push(ArticleRoute(id: id))
        case "profile": router.push(ProfileRoute(id: id, nick: "Профиль"))
        case "settings": router.push(MoreRoute.settings)
        case "menu": router.push(MoreRoute.more)
        case "search": router.push(MoreRoute.search)
        default: break
        }
    }
}
