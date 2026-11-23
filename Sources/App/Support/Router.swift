import SwiftUI
import UIKit

/// Навигация вкладки. Все переходы идут через один NavigationPath — смешение
/// NavigationLink(destination:) и NavigationLink(value:) в iOS 16 оставляет
/// старый экран поверх нового.
@MainActor
final class Router: ObservableObject {
    @Published var path = NavigationPath()

    func push<T: Hashable>(_ route: T) { path.append(route) }
    func popToRoot() { path = NavigationPath() }

    /// Ссылки 4PDA открываются внутри приложения, остальные — в браузере.
    func open(_ url: URL) -> OpenURLAction.Result {
        if let route = Self.route(for: url) {
            route(self)
            return .handled
        }
        return .systemAction
    }

    static func route(for url: URL) -> (@MainActor (Router) -> Void)? {
        guard let host = url.host?.lowercased(),
              host.hasSuffix("4pda.to") || host.hasSuffix("4pda.ru") || host.hasSuffix("4pda.ws") else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name.lowercased()] = item.value ?? "" }
        // Короткие ссылки вида index.php?showtopic=1&view=findpost&p=2
        if let t = q["showtopic"].flatMap(Int.init) {
            if let p = q["p"].flatMap(Int.init) {
                return { $0.push(TopicRoute(id: t, title: "Тема", jump: .post(p))) }
            }
            switch q["view"] {
            case "getnewpost": return { $0.push(TopicRoute(id: t, title: "Тема", jump: .unread)) }
            case "getlastpost": return { $0.push(TopicRoute(id: t, title: "Тема", jump: .last)) }
            default: break
            }
            let st = q["st"].flatMap(Int.init) ?? 0
            return { $0.push(TopicRoute(id: t, title: "Тема", jump: st > 0 ? .offset(st) : .start)) }
        }
        if q["act"] == "findpost", let p = q["pid"].flatMap(Int.init) {
            return { $0.push(TopicRoute(id: 0, title: "Тема", jump: .post(p))) }
        }
        if let f = q["showforum"].flatMap(Int.init) {
            return { $0.push(ForumRoute(id: f, name: "Форум")) }
        }
        if let u = q["showuser"].flatMap(Int.init) {
            return { $0.push(ProfileRoute(id: u, nick: "Профиль")) }
        }
        // Статьи: /2024/05/12/123456/slug/ или ?p=123456
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 4, parts[0].count == 4, Int(parts[0]) != nil, let id = Int(parts[3]) {
            return { $0.push(ArticleRoute(id: id)) }
        }
        if url.path == "/" || url.path.isEmpty, let p = q["p"].flatMap(Int.init) {
            return { $0.push(ArticleRoute(id: p)) }
        }
        return nil
    }
}

/// Пункты «Ещё», тоже через NavigationPath.
enum MoreRoute: Hashable {
    case account, mentions, history, search, log, diagnostics
}

/// NavigationStack вкладки со своим роутером.
struct RoutedStack<Root: View>: View {
    @StateObject private var router = Router()
    let root: () -> Root

    init(@ViewBuilder root: @escaping () -> Root) {
        self.root = root
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            root().pdaDestinations()
        }
        .environmentObject(router)
        .environment(\.openURL, OpenURLAction { router.open($0) })
    }
}

/// Ссылка, которая всегда открывается в Safari (минуя внутреннюю навигацию).
struct BrowserLink<Label: View>: View {
    let destination: URL
    @ViewBuilder let label: () -> Label

    init(destination: URL, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    var body: some View {
        Button { UIApplication.shared.open(destination) } label: { label() }
    }
}

extension BrowserLink where Label == Text {
    init(_ title: String, destination: URL) {
        self.init(destination: destination) { Text(title) }
    }
}
