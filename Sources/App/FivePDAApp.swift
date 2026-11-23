import SwiftUI

@main
struct FivePDAApp: App {
    @StateObject private var client = PDAClient.shared
    @StateObject private var updater = UpdateChecker.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                RoutedStack { NewsListView() }
                    .tabItem { Label("Новости", systemImage: "newspaper") }
                RoutedStack { ForumsView() }
                    .tabItem { Label("Форум", systemImage: "bubble.left.and.bubble.right") }
                RoutedStack { FavoritesView() }
                    .tabItem { Label("Избранное", systemImage: "star") }
                RoutedStack { QMSListView() }
                    .tabItem { Label("QMS", systemImage: "envelope") }
                RoutedStack { MoreView() }
                    .tabItem { Label("Ещё", systemImage: "ellipsis.circle") }
                    .badge(updater.available == nil ? 0 : 1)
            }
            .environmentObject(client)
            .task { await updater.check() }
            .modifier(ShakeToReport())
        }
    }
}
