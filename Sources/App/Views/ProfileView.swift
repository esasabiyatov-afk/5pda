import SwiftUI

struct ProfileView: View {
    let route: ProfileRoute
    @EnvironmentObject private var client: PDAClient
    @EnvironmentObject private var router: Router
    @State private var profile: MemberProfile?
    @State private var error: String?
    @State private var newDialog = false
    @State private var reputation = false
    @State private var reputationList = false

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "dd.MM.yy"; return f
    }()

    private func userTime(_ offset: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: offset)
        return f.string(from: Date())
    }

    var body: some View {
        Group {
            if let p = profile {
                List {
                    Section {
                        HStack(alignment: .top, spacing: 14) {
                            AvatarView(url: p.avatar, size: 72)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    if p.isOnline { Circle().fill(PDATheme.online).frame(width: 8, height: 8) }
                                    Text(p.nick).font(.title2.bold())
                                }
                                Text(PDAAPI.groups[p.group] ?? "Группа \(p.group)").font(.subheadline)
                                    .foregroundStyle(PDATheme.groupColor(p.group))
                                if !p.title.isEmpty { Text(p.title).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        LabeledContent("Регистрация", value: Self.day.string(from: p.registered))
                        if p.warnLevel >= 0 { LabeledContent("Предупреждения", value: "\(p.warnLevel)%") }
                        if p.lastVisit.timeIntervalSince1970 > 0 {
                            LabeledContent("Последнее посещение", value: p.lastVisit.pdaFormatted)
                        }
                    }
                    if p.gender > 0 || !p.birthday.isEmpty || p.timezone != 0 {
                        Section("Личные данные") {
                            if p.gender > 0 { Text(p.gender == 1 ? "Мужчина" : "Женщина").bold() }
                            if !p.birthday.isEmpty { LabeledContent("Дата рождения", value: p.birthday) }
                            LabeledContent("Время у юзера", value: userTime(p.timezone))
                        }
                    }
                    Section("Сайт") {
                        LabeledContent("Карма", value: String(format: "%.2f", Double(p.siteKarma) / 100))
                        LabeledContent("Постов", value: String(p.sitePosts))
                        LabeledContent("Комментов", value: String(p.comments))
                    }
                    Section("Форум") {
                        Button { reputationList = true } label: {
                            LabeledContent("Репутация") { Text("\(p.reputation)").bold() }
                        }
                        Button { router.push(MoreRoute.userTopics(p.id, p.nick)) } label: {
                            LabeledContent("Тем") { Text("\(p.topics)").bold() }
                        }
                        Button { router.push(MoreRoute.userPosts(p.id, p.nick)) } label: {
                            LabeledContent("Постов") { Text("\(p.posts)").bold() }
                        }
                    }
                    .foregroundStyle(.primary)
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
        .sheet(isPresented: $reputationList) {
            ReputationHistorySheet(userId: route.id, nick: profile?.nick ?? route.nick)
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
                NavigationLink(value: MoreRoute.settings) { Label("Настройки", systemImage: "gearshape") }
                NavigationLink(value: MoreRoute.diagnostics) { Label("Диагностика", systemImage: "stethoscope") }
                NavigationLink(value: MoreRoute.log) { Label("Журнал соединения", systemImage: "terminal") }
            }
        }
        .navigationTitle("Меню")
        .safeAreaInset(edge: .bottom) {
            Text("Нашли ошибку? Встряхните телефон на нужном экране.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
        }
    }
}
