import SwiftUI
import UIKit

/// Тема: посты постранично, ответы, цитаты, правка, оценки, опрос.
struct TopicView: View {
    let route: TopicRoute
    @EnvironmentObject private var client: PDAClient
    @State private var page: TopicPage?
    @State private var offset = 0
    @State private var highlightPost: Int?
    @State private var error: String?
    @State private var loading = false
    @State private var composer: ComposerState?
    @State private var alert: ActionAlert?
    @State private var reputationTarget: Post?
    @State private var showSearch = false

    private var pageCount: Int {
        guard let total = page?.totalPosts, total > 0 else { return 1 }
        return (total + PDAAPI.postsPerPage - 1) / PDAAPI.postsPerPage
    }
    private var currentPage: Int { offset / PDAAPI.postsPerPage + 1 }

    var body: some View {
        Group {
            if let error = error, page == nil {
                ErrorView(message: error) { Task { await initialLoad() } }
            } else if let page = page {
                ScrollViewReader { proxy in
                    List {
                        if currentPage == 1, !page.description.isEmpty {
                            Text(page.description).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let poll = page.poll, currentPage == 1 {
                            PollView(poll: poll, topicId: page.id, canVote: page.flags & 4 == 0) {
                                Task { await load(offset) }
                            }
                        }
                        ForEach(page.posts) { post in
                            PostView(post: post, highlighted: post.id == highlightPost)
                                .id(post.id)
                                .contextMenu { postMenu(post, page: page) }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await load(offset) }
                    .onChange(of: page.posts.first?.id) { _ in
                        if let target = highlightPost, page.posts.contains(where: { $0.id == target }) {
                            proxy.scrollTo(target, anchor: .top)
                        } else if let first = page.posts.first {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                    .onAppear {
                        if let target = highlightPost { proxy.scrollTo(target, anchor: .top) }
                    }
                }
                .overlay { if loading { ProgressView() } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(page?.title ?? route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { topicMenu }
            ToolbarItemGroup(placement: .bottomBar) { pager }
        }
        .sheet(item: $composer) { state in
            PostComposer(state: state) { sent in
                composer = nil
                Task { await afterSend(sent) }
            }
        }
        .sheet(item: $reputationTarget) { post in
            ReputationSheet(userId: post.authorId, nick: post.authorName, postId: post.id) { reputationTarget = nil }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack { SearchView(topicId: route.id, topicTitle: page?.title ?? route.title).pdaDestinations() }
        }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .task { if page == nil { await initialLoad() } }
    }

    // MARK: - Меню

    private var topicMenu: some View {
        Menu {
            if let page = page {
                if page.canReply, client.isLoggedIn {
                    Button { composer = ComposerState(topicId: page.id, title: "Ответ: \(page.title)") } label: {
                        Label("Написать пост", systemImage: "square.and.pencil")
                    }
                }
                Button { Task { await load(offset) } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                if client.isLoggedIn {
                    Button { Task { await jump(.unread) } } label: { Label("К непрочитанному", systemImage: "eye") }
                    Button {
                        Task { await toggleSubscription(page) }
                    } label: {
                        Label(page.isSubscribed ? "Убрать из избранного" : "В избранное",
                              systemImage: page.isSubscribed ? "star.slash" : "star")
                    }
                }
                Button { showSearch = true } label: { Label("Поиск в теме", systemImage: "magnifyingglass") }
                Button {
                    UIPasteboard.general.string = topicURL.absoluteString
                } label: { Label("Копировать ссылку", systemImage: "link") }
                Link(destination: topicURL) { Label("Открыть в браузере", systemImage: "safari") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var pager: some View {
        Button { Task { await load(0) } } label: { Image(systemName: "chevron.backward.2") }
            .disabled(currentPage <= 1)
        Button { Task { await load(offset - PDAAPI.postsPerPage) } } label: { Image(systemName: "chevron.backward") }
            .disabled(currentPage <= 1)
        Spacer()
        Menu("\(currentPage) / \(pageCount)") {
            ForEach(pageChoices, id: \.self) { p in
                Button("Страница \(p)") { Task { await load((p - 1) * PDAAPI.postsPerPage) } }
            }
        }
        .font(.footnote.monospacedDigit())
        Spacer()
        if page?.canReply == true, client.isLoggedIn {
            Button { if let p = page { composer = ComposerState(topicId: p.id, title: "Ответ: \(p.title)") } } label: {
                Image(systemName: "square.and.pencil")
            }
        }
        Button { Task { await load(offset + PDAAPI.postsPerPage) } } label: { Image(systemName: "chevron.forward") }
            .disabled(currentPage >= pageCount)
        Button { Task { await load((pageCount - 1) * PDAAPI.postsPerPage) } } label: { Image(systemName: "chevron.forward.2") }
            .disabled(currentPage >= pageCount)
    }

    private var pageChoices: [Int] {
        let n = pageCount
        if n <= 30 { return Array(1...n) }
        var set = Set([1, n])
        for p in max(1, currentPage - 5)...min(n, currentPage + 5) { set.insert(p) }
        for p in stride(from: 10, to: n, by: max(10, n / 20)) { set.insert(p) }
        return set.sorted()
    }

    @ViewBuilder
    private func postMenu(_ post: Post, page: TopicPage) -> some View {
        if page.canReply, client.isLoggedIn {
            Button {
                composer = ComposerState(topicId: page.id, title: "Ответ: \(page.title)",
                                         text: "[SNAPBACK]\(post.id)[/SNAPBACK] [B]\(post.authorName)[/B], ")
            } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
            Button {
                let date = Self.quoteDate.string(from: post.date)
                composer = ComposerState(topicId: page.id, title: "Ответ: \(page.title)",
                                         text: "[QUOTE name=\"\(post.authorName)\" date=\"\(date)\" post=\(post.id)]\(post.bodyBB)[/QUOTE]\n")
            } label: { Label("Цитировать", systemImage: "quote.bubble") }
        }
        if post.canEdit {
            Button {
                composer = ComposerState(topicId: page.id, postId: post.id, title: "Редактирование поста",
                                         text: post.bodyBB, editReason: post.editReason)
            } label: { Label("Редактировать", systemImage: "pencil") }
        }
        if post.canRate, client.isLoggedIn, post.authorId != client.memberId {
            Button { Task { await rate(post, up: true) } } label: { Label("Хороший пост", systemImage: "hand.thumbsup") }
            Button { Task { await rate(post, up: false) } } label: { Label("Плохой пост", systemImage: "hand.thumbsdown") }
        }
        if client.isLoggedIn, post.authorId != client.memberId {
            Button { reputationTarget = post } label: { Label("Репутация автора", systemImage: "plusminus") }
        }
        NavigationLink(value: ProfileRoute(id: post.authorId, nick: post.authorName)) {
            Label("Профиль \(post.authorName)", systemImage: "person")
        }
        Button {
            UIPasteboard.general.string = PDAConfig.siteURL.absoluteString + "forum/index.php?showtopic=\(page.id)&view=findpost&p=\(post.id)"
        } label: { Label("Копировать ссылку", systemImage: "link") }
        Button {
            UIPasteboard.general.string = BBParser.plainText(post.bodyBB)
        } label: { Label("Копировать текст", systemImage: "doc.on.doc") }
    }

    private static let quoteDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f
    }()

    private var topicURL: URL {
        URL(string: PDAConfig.siteURL.absoluteString + "forum/index.php?showtopic=\(route.id)&st=\(offset)")!
    }

    // MARK: - Загрузка

    private func initialLoad() async {
        await jump(route.jump)
    }

    private func jump(_ jump: TopicRoute.Jump) async {
        switch jump {
        case .start:
            await load(0)
        case .offset(let o):
            await load(o)
        case .unread, .last, .post:
            loading = true
            defer { loading = false }
            do {
                let mode: Int, id: Int
                switch jump {
                case .unread: (mode, id) = (1, route.id)
                case .last: (mode, id) = (2, route.id)
                case .post(let p): (mode, id) = (3, p)
                default: (mode, id) = (1, route.id)
                }
                let target = try await PDAAPI.findPost(mode: mode, id: id)
                highlightPost = target.postId
                await load(target.offset, keepLoading: true)
            } catch {
                await load(0, keepLoading: true)
            }
        }
    }

    private func load(_ newOffset: Int, keepLoading: Bool = false) async {
        if !keepLoading { loading = true }
        defer { if !keepLoading { loading = false } }
        error = nil
        do {
            let p = try await PDAAPI.topic(id: route.id, offset: max(0, newOffset))
            page = p
            offset = max(0, newOffset)
        } catch {
            self.error = error.localizedDescription
            if page != nil { alert = ActionAlert(title: "Ошибка", message: error.localizedDescription) }
        }
    }

    private func afterSend(_ sent: PDAAPI.SentPost?) async {
        guard let sent = sent else { await load(offset); return }
        highlightPost = sent.postId
        await load((sent.index / PDAAPI.postsPerPage) * PDAAPI.postsPerPage)
    }

    private func rate(_ post: Post, up: Bool) async {
        do {
            try await PDAAPI.ratePost(post.id, up: up)
            alert = ActionAlert(title: "Готово", message: "Голос засчитан")
            await load(offset)
        } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }

    private func toggleSubscription(_ page: TopicPage) async {
        do {
            try await PDAAPI.setTopicSubscribed(page.id, !page.isSubscribed)
            await load(offset)
        } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }
}

// MARK: - Пост

struct PostView: View {
    let post: Post
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AsyncImage(url: PDAAPI.absoluteURL(post.avatar)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                VStack(alignment: .leading) {
                    Text(post.authorName).font(.subheadline.bold())
                    Text(post.date.pdaFormatted).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if post.showsRating {
                    Text(post.ratingValue > 0 ? "+\(post.ratingValue)" : "\(post.ratingValue)")
                        .font(.caption.bold())
                        .foregroundStyle(post.ratingValue >= 0 ? .green : .red)
                }
            }
            BBContentView(post.bodyBB, attachments: post.attachments)
            if !post.editReason.isEmpty {
                Text("Причина правки: \(post.editReason)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(highlighted ? Color.accentColor.opacity(0.08) : nil)
    }
}

// MARK: - Опрос

struct PollView: View {
    let poll: Poll
    let topicId: Int
    let canVote: Bool
    let onVoted: () -> Void
    @State private var selection: [Int: Set<Int>] = [:]
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(poll.title).font(.headline)
            ForEach(Array(poll.questions.enumerated()), id: \.offset) { qi, q in
                VStack(alignment: .leading, spacing: 6) {
                    if !q.text.isEmpty { Text(q.text).font(.subheadline.bold()) }
                    ForEach(Array(q.options.enumerated()), id: \.offset) { oi, option in
                        if poll.voted || !canVote {
                            let votes = oi < q.votes.count ? q.votes[oi] : 0
                            let total = max(1, q.votes.reduce(0, +))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(option).font(.footnote)
                                    Spacer()
                                    Text("\(votes)").font(.footnote.monospacedDigit())
                                }
                                ProgressView(value: Double(votes), total: Double(total))
                            }
                        } else {
                            Button {
                                toggle(qi, oi, multiple: q.multiple)
                            } label: {
                                HStack {
                                    Image(systemName: isSelected(qi, oi)
                                          ? (q.multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                                          : (q.multiple ? "square" : "circle"))
                                    Text(option).font(.footnote).multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !poll.voted && canVote {
                Button(sending ? "Отправка…" : "Голосовать") { Task { await vote() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || selection.values.allSatisfy { $0.isEmpty })
            }
            Text("Всего голосов: \(poll.totalVotes)").font(.caption).foregroundStyle(.secondary)
            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 6)
    }

    private func isSelected(_ q: Int, _ o: Int) -> Bool { selection[q]?.contains(o) ?? false }

    private func toggle(_ q: Int, _ o: Int, multiple: Bool) {
        var set = selection[q] ?? []
        if multiple {
            if set.contains(o) { set.remove(o) } else { set.insert(o) }
        } else {
            set = [o]
        }
        selection[q] = set
    }

    private func vote() async {
        sending = true
        defer { sending = false }
        let answers = poll.questions.indices.map { Array(selection[$0] ?? []).sorted() }
        do {
            try await PDAAPI.vote(topicId: topicId, answers: answers)
            onVoted()
        } catch {
            self.error = "Ошибка голосования"
        }
    }
}

// MARK: - Репутация

struct ReputationSheet: View {
    let userId: Int
    let nick: String
    let postId: Int
    let onDone: () -> Void
    @State private var reason = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Причина") {
                    TextField("Обязательно укажите причину", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    HStack {
                        Button { Task { await send(up: false) } } label: {
                            Label("Минус", systemImage: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button { Task { await send(up: true) } } label: {
                            Label("Плюс", systemImage: "plus.circle.fill").foregroundStyle(.green)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(sending || reason.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    if let e = error { Text(e).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Репутация \(nick)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть", action: onDone) } }
        }
        .presentationDetents([.medium])
    }

    private func send(up: Bool) async {
        sending = true
        defer { sending = false }
        do {
            try await PDAAPI.changeReputation(userId: userId, up: up, postId: postId, reason: reason)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
