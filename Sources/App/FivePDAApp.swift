import SwiftUI

@main
struct FivePDAApp: App {
    @StateObject private var client = PDAClient.shared
    @StateObject private var updater = UpdateChecker.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { NewsListView().pdaDestinations() }
                    .tabItem { Label("Новости", systemImage: "newspaper") }
                NavigationStack { ForumsView().pdaDestinations() }
                    .tabItem { Label("Форум", systemImage: "bubble.left.and.bubble.right") }
                NavigationStack { FavoritesView().pdaDestinations() }
                    .tabItem { Label("Избранное", systemImage: "star") }
                NavigationStack { QMSListView().pdaDestinations() }
                    .tabItem { Label("QMS", systemImage: "envelope") }
                NavigationStack { MoreView().pdaDestinations() }
                    .tabItem { Label("Ещё", systemImage: "ellipsis.circle") }
                    .badge(updater.available == nil ? 0 : 1)
            }
            .environmentObject(client)
            .task { await updater.check() }
        }
    }
}
