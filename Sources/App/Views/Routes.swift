import SwiftUI

struct ForumRoute: Hashable { let id: Int; let name: String }

struct TopicRoute: Hashable {
    enum Jump: Hashable { case start, unread, last, post(Int), offset(Int) }
    let id: Int
    let title: String
    var jump: Jump = .start
}

struct ProfileRoute: Hashable { let id: Int; let nick: String }
struct QMSDialogRoute: Hashable { let id: Int; let title: String }
struct ArticleRoute: Hashable { let id: Int }

extension View {
    /// Общие переходы для всех вкладок.
    func pdaDestinations() -> some View {
        self
            .navigationDestination(for: ForumRoute.self) { ForumView(route: $0) }
            .navigationDestination(for: TopicRoute.self) { TopicView(route: $0) }
            .navigationDestination(for: ProfileRoute.self) { ProfileView(route: $0) }
            .navigationDestination(for: QMSDialogRoute.self) { QMSDialogView(route: $0) }
            .navigationDestination(for: NewsItem.self) { NewsDetailView(item: $0) }
            .navigationDestination(for: ArticleRoute.self) { ArticleLoaderView(id: $0.id) }
            .navigationDestination(for: MoreRoute.self) { route in
                switch route {
                case .account: AccountView()
                case .mentions: MentionsView()
                case .history: HistoryView()
                case .search: SearchView()
                case .log: DebugConsoleView()
                }
            }
    }
}

/// Открытие статьи по id (из упоминаний и поиска).
struct ArticleLoaderView: View {
    let id: Int
    @State private var article: NewsArticle?
    @State private var error: String?

    var body: some View {
        Group {
            if let a = article {
                NewsDetailView(item: a.item)
            } else if let e = error {
                ErrorView(message: e) { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .task { if article == nil { await load() } }
    }

    private func load() async {
        do { article = try await PDAAPI.article(id: id) } catch { self.error = error.localizedDescription }
    }
}

/// Простой показ ошибок действий.
struct ActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
