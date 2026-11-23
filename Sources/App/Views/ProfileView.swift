import SwiftUI

struct ProfileView: View {
    let route: ProfileRoute
    @EnvironmentObject private var client: PDAClient
    @EnvironmentObject private var router: Router
    @State private var profile: MemberProfile?
    @State private var error: String?
    @State private var newDialog = false
    @State private var reputation = false

    var body: some View {
        Group {
            if let p = profile {
                List {
                    Section {
                        HStack(spacing: 14) {
                            RemoteImage(avatar: PDAAPI.absoluteURL(p.avatar))
                            .frame(width: 72, height: 72).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.nick).font(.title3.bold())
                                Text(PDAAPI.groups[p.group] ?? "Группа \(p.group)").font(.subheadline).foregroundStyle(.secondary)
                                if !p.title.isEmpty { Text(p.title).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Section("Статистика") {
                        LabeledContent("Репутация", value: String(p.reputation))
                        LabeledContent("Темы", value: String(p.topics))
                        LabeledContent("Посты на форуме", value: String(p.posts))
                        LabeledContent("Статьи на сайте", value: String(p.sitePosts))
                        LabeledContent("Комментарии", value: String(p.comments))
                        LabeledContent("Регистрация", value: p.registered.pdaFormatted)
                        if p.lastVisit.timeIntervalSince1970 > 0 {
                            LabeledContent("Последнее посещение", value: p.lastVisit.pdaFormatted)
                        }
                        if !p.birthday.isEmpty { LabeledContent("День рождения", value: p.birthday) }
                        if p.gender > 0 { LabeledContent("Пол", value: p.gender == 1 ? "Мужской" : "Женский") }
                    }
                    if !p.devices.isEmpty {
                        Section("Устройства") {
                            ForEach(Array(p.devices.enumerated()), id: \.offset) { _, d in
                                if let url = URL(string: d.link), !d.link.isEmpty {
                                    BrowserLink(destination: url) { Text(d.name).fontWeight(d.main ? .bold : .regular) }
                                } else {
                                    Text(d.name).fontWeight(d.main ? .bold : .regular)
                                }
                            }
                        }
                    }
                    if !p.signatureBB.isEmpty {
                        Section("Подпись") { BBContentView(p.signatureBB) }
                    }
                    if client.isLoggedIn, p.id != client.memberId {
                        Section {
                            Button { newDialog = true } label: { Label("Написать в QMS", systemImage: "envelope") }
                            Button { reputation = true } label: { Label("Изменить репутацию", systemImage: "plusminus") }
                        }
                    }
                    Section {
                        BrowserLink(destination: URL(string: PDAConfig.siteURL.absoluteString + "forum/index.php?showuser=\(p.id)")!) {
                            Label("Открыть на сайте", systemImage: "safari")
                        }
                    }
                }
            } else if let e = error {
                ErrorView(message: e) { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(profile?.nick ?? route.nick)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $newDialog) {
            NewQMSDialogSheet(userId: route.id, nick: profile?.nick ?? route.nick,
                              onDone: { newDialog = false }, onCreated: { router.push($0) })
        }
        .sheet(isPresented: $reputation) {
            ReputationSheet(userId: route.id, nick: profile?.nick ?? route.nick, postId: 0) {
                reputation = false
                Task { await load() }
            }
        }
        .task { if profile == nil { await load() } }
    }

    private func load() async {
        error = nil
        do { profile = try await PDAAPI.profile(id: route.id) } catch { self.error = error.localizedDescription }
    }
}

/// Экран «Ещё»: аккаунт, история, упоминания, поиск, журнал.
struct MoreView: View {
    @EnvironmentObject private var client: PDAClient

    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreRoute.account) {
                    Label(client.isLoggedIn ? client.memberName : "Войти", systemImage: "person.crop.circle")
                }
                if client.isLoggedIn {
                    NavigationLink(value: ProfileRoute(id: client.memberId, nick: client.memberName)) {
                        Label("Мой профиль", systemImage: "person.text.rectangle")
                    }
                }
            }
            Section {
                NavigationLink(value: MoreRoute.mentions) { Label("Упоминания", systemImage: "at") }
                NavigationLink(value: MoreRoute.history) { Label("История", systemImage: "clock") }
                NavigationLink(value: MoreRoute.search) { Label("Поиск", systemImage: "magnifyingglass") }
            }
            Section {
                NavigationLink(value: MoreRoute.diagnostics) { Label("Диагностика", systemImage: "stethoscope") }
                NavigationLink(value: MoreRoute.log) { Label("Журнал соединения", systemImage: "terminal") }
            }
        }
        .navigationTitle("Ещё")
        .safeAreaInset(edge: .bottom) {
            Text("Нашли ошибку? Встряхните телефон на нужном экране.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
        }
    }
}
