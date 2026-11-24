import SwiftUI

@main
struct FivePDAApp: App {
    @StateObject private var client = PDAClient.shared
    @StateObject private var updater = UpdateChecker.shared
    @StateObject private var unread = UnreadStore.shared
    @StateObject private var tabs = TabSelection()
    @AppStorage("appearance") private var appearance = 0
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Notifier.registerBackground()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tabs.tab) {
                RoutedStack { HomeView() }
                    .tabItem { Label("Главная", systemImage: "house") }
                    .badge(updater.available == nil ? 0 : 1)
                    .tag(TabSelection.Tab.home)
                RoutedStack { NewsListView() }
                    .tabItem { Label("Сайт", systemImage: "newspaper") }
                    .tag(TabSelection.Tab.site)
                RoutedStack { ForumsView() }
                    .tabItem { Label("Форум", systemImage: "bubble.left.and.bubble.right") }
                    .tag(TabSelection.Tab.forum)
                RoutedStack { FavoritesView() }
                    .tabItem { Label("Избранное", systemImage: "star") }
                    .badge(unread.counters.favorites)
                    .tag(TabSelection.Tab.favorites)
                RoutedStack { QMSListView() }
                    .tabItem { Label("QMS", systemImage: "envelope") }
                    .badge(unread.counters.qms)
                    .tag(TabSelection.Tab.qms)
            }
            .tint(PDATheme.brand)
            .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
            .environmentObject(client)
            .environmentObject(unread)
            .environmentObject(tabs)
            .onChange(of: scenePhase) { phase in
                if phase == .background { Notifier.scheduleBackground() }
                if phase == .active { Task { await unread.refresh() } }
            }
            .task {
                if client.isLoggedIn { Notifier.requestPermission() }
                unread.start()
                await updater.check()
            }
            .modifier(ShakeToReport())
        }
    }
}
