import SwiftUI

@main
struct FivePDAApp: App {
    @StateObject private var client = PDAClient.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { NewsListView() }
                    .tabItem { Label("Новости", systemImage: "newspaper") }
                NavigationStack { ForumsView() }
                    .tabItem { Label("Форум", systemImage: "bubble.left.and.bubble.right") }
                NavigationStack { AccountView() }
                    .tabItem { Label("Аккаунт", systemImage: "person.crop.circle") }
            }
            .environmentObject(client)
        }
    }
}
