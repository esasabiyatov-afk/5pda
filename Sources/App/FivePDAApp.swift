import SwiftUI

@main
struct FivePDAApp: App {
    @StateObject private var client = PDAClient.shared
    @StateObject private var updater = UpdateChecker.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { NewsListView() }
                    .tabItem { Label("Новости", systemImage: "newspaper") }
                NavigationStack { ForumsView() }
                    .tabItem { Label("Форум", systemImage: "bubble.left.and.bubble.right") }
                NavigationStack { AccountView() }
                    .tabItem { Label("Аккаунт", systemImage: "person.crop.circle") }
                    .badge(updater.available == nil ? 0 : 1)
            }
            .environmentObject(client)
            .task { await updater.check() }
        }
    }
}
