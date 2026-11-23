import SwiftUI
import UIKit

/// Тема: посты с бесконечной прокруткой, переход по страницам, ответы, цитаты,
/// правка, оценки, опрос.
struct TopicView: View {
    let route: TopicRoute
    @EnvironmentObject private var client: PDAClient
    @EnvironmentObject private var router: Router
    @State private var topicId: Int
    @State private var page: TopicPage?
    /// Загруженные посты: с позиции `startOffset` до `endOffset` (не включая).
    @State private var posts: [Post] = []
    @State private var startOffset = 0
    @State private var endOffset = 0
    @State private var visibleIndex = 0
    @State private var highlightPost: Int?
    @State private var scrollTarget: Int?
    @State private var error: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var loadingPrev = false
    @State private var composer: ComposerState?
    @State private var alert: ActionAlert?
    @State private var reputationTarget: Post?
    @State private var showSearch = false
    @AppStorage("collapse_polls") private var collapsePolls = false
    @State private var complaintPost: Post?
    @State private var complaintText = ""

    init(route: TopicRoute) {
        self.route = route
        _topicId = State(initialValue: route.id)
    }

    private var perPage: Int { PDAAPI.postsPerPage }
    /// Постов без шапки (шапка — позиция 0 — приходит с каждой страницей).
    private var total: Int { max((page?.totalPosts ?? 0) - 1, endOffset) }
    private var pageCount: Int { max(1, (total + perPage - 1) / perPage) }
    /// visibleIndex — номер поста в теме, считая шапку первым.
    private var currentPage: Int { min(pageCount, visibleIndex <= 1 ? 1 : (visibleIndex - 2) / perPage + 1) }

    /// Номер поста в теме по индексу в загруженном списке.
    private func number(at index: Int) -> Int {
        startOffset == 0 ? index + 1 : startOffset + index + 2
    }

    var body: some View {
        Group {
            if let error = error, page == nil {
                ErrorView(message: error) { Task { await initialLoad() } }
            } else if let page = page {
                ScrollViewReader { proxy in
                    List {
                        if startOffset > 0 {
                            Button {
                                Task { await loadPrevious(proxy: proxy) }
                            } label: {
                                HStack {
                                    Spacer()
                                    if loadingPrev { ProgressView() } else {
                                        Label("Предыдущие посты", systemImage: "arrow.up")
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(loadingPrev)
                        } else {
                            if !page.description.isEmpty {
                                Text(page.description).font(.footnote).foregroundStyle(.secondary)
                            }
                            if let poll = page.poll {
                                if collapsePolls {
                                    DisclosureGroup("Опрос: \(poll.title)") {
                                        PollView(poll: poll, topicId: topicId, canVote: page.flags & 4 == 0) {
                                            Task { await load(startOffset) }
                                        }
                                    }
                                } else {
                                    PollView(poll: poll, topicId: topicId, canVote: page.flags & 4 == 0) {
                                        Task { await load(startOffset) }
                                    }
                                }
                            }
                        }
                        ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                            PostView(post: post, number: number(at: index), highlighted: post.id == highlightPost)
                                .id(post.id)
                                .contextMenu { postMenu(post, page: page) }
                                .onAppear {
                                    visibleIndex = number(at: index)
                                    if index >= posts.count - 3 { Task { await loadMore() } }
                                }
                        }
                        if endOffset < total {
                            HStack {
                                Spacer()
                                if loadingMore { ProgressView() } else {
                                    Button("Загрузить ещё") { Task { await loadMore() } }
                                }
                                Spacer()
                            }
                            .onAppear { Task { await loadMore() } }
                        } else if !posts.isEmpty {
                            Text("Конец темы").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await refresh() }
                    .onChange(of: scrollTarget) { target in
                        guard let target = target else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(target, anchor: .top)
                            scrollTarget = nil
                        }
                    }
                    .onAppear {
                        if let target = highlightPost { proxy.scrollTo(target, anchor: .top) }
                    }
                }
                .overlay { if loading { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
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
            RoutedStack { SearchView(topicId: topicId, topicTitle: page?.title ?? route.title) }
                .environmentObject(client)
        }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .alert("Жалоба на пост", isPresented: Binding(get: { complaintPost != nil }, set: { if !$0 { complaintPost = nil } })) {
            TextField("Опишите нарушение", text: $complaintText)
            Button("Отправить") {
                if let p = complaintPost {
                    let text = complaintText
                    Task {
                        do {
                            try await PDAAPI.complain(.post, id: p.id, text: text)
                            alert = ActionAlert(title: "Готово", message: "Жалоба отправлена")
                        } catch { alert = ActionAlert(title: "Ошибка", message: error.localizedDescription) }
                    }
                }
                complaintText = ""
            }
            Button("Отмена", role: .cancel) { complaintText = "" }
        }
        .task { if page == nil { await initialLoad() } }
    }

    // MARK: - Меню

    private var topicMenu: some View {
        Menu {
            if let page = page {
                if page.canReply, client.isLoggedIn {
                    Button { composer = ComposerState(topicId: topicId, title: "Ответ: \(page.title)") } label: {
                        Label("Написать пост", systemImage: "square.and.pencil")
                    }
                }
                Button { Task { await refresh() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
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
                BrowserLink(destination: topicURL) { Label("Открыть в браузере", systemImage: "safari") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var pager: some View {
        Button { Task { await load(0) } } label: { Image(systemName: "chevron.backward.2") }
            .disabled(currentPage <= 1)
        Button { Task { await load((currentPage - 2) * perPage) } } label: { Image(systemName: "chevron.backward") }
            .disabled(currentPage <= 1)
        Spacer()
        Menu("\(currentPage) / \(pageCount)") {
            ForEach(pageChoices, id: \.self) { p in
                Button("Страница \(p)") { Task { await load((p - 1) * perPage) } }
            }
        }
        .font(.footnote.monospacedDigit())
        Spacer()
        if page?.canReply == true, client.isLoggedIn {
            Button { if let p = page { composer = ComposerState(topicId: topicId, title: "Ответ: \(p.title)") } } label: {
                Image(systemName: "square.and.pencil")
            }
        }
        Button { Task { await load(currentPage * perPage) } } label: { Image(systemName: "chevron.forward") }
            .disabled(currentPage >= pageCount)
        Button { Task { await load((pageCount - 1) * perPage) } } label: { Image(systemName: "chevron.forward.2") }
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
                composer = ComposerState(topicId: topicId, title: "Ответ: \(page.title)",
                                         text: "[SNAPBACK]\(post.id)[/SNAPBACK] [B]\(post.authorName)[/B], ")
            } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
            Button {
                let date = Self.quoteDate.string(from: post.date)
                composer = ComposerState(topicId: topicId, title: "Ответ: \(page.title)",
                                         text: "[QUOTE name=\"\(post.authorName)\" date=\"\(date)\" post=\(post.id)]\(post.bodyBB)[/QUOTE]\n")
            } label: { Label("Цитировать", systemImage: "quote.bubble") }
        }
        if post.canEdit {
            Button {
                composer = ComposerState(topicId: topicId, postId: post.id, title: "Редактирование поста",
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
        Button { router.push(ProfileRoute(id: post.authorId, nick: post.authorName)) } label: {
            Label("Профиль \(post.authorName)", systemImage: "person")
        }
        Button { router.push(MoreRoute.userPosts(post.authorId, post.authorName)) } label: {
            Label("Поиск постов \(post.authorName)", systemImage: "magnifyingglass")
        }
        if client.isLoggedIn {
            Button { complaintPost = post } label: { Label("Жалоба", systemImage: "exclamationmark.bubble") }
        }
        Button {
            UIPasteboard.general.string = PDAConfig.siteURL.absoluteString + "forum/index.php?showtopic=\(topicId)&view=findpost&p=\(post.id)"
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
        URL(string: PDAConfig.siteURL.absoluteString + "forum/index.php?showtopic=\(topicId)&st=\((currentPage - 1) * perPage)")!
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
                case .unread: (mode, id) = (1, topicId)
                case .last: (mode, id) = (2, topicId)
                case .post(let p): (mode, id) = (3, p)
                default: (mode, id) = (1, topicId)
                }
                let target = try await PDAAPI.findPost(mode: mode, id: id)
                if target.topicId > 0 { topicId = target.topicId }
                highlightPost = target.postId
                await load(target.offset, keepLoading: true)
            } catch {
                await load(0, keepLoading: true)
            }
        }
    }

    /// Загружает страницу с позиции `newOffset`, заменяя показанные посты.
    private func load(_ newOffset: Int, keepLoading: Bool = false) async {
        if !keepLoading { loading = true }
        defer { if !keepLoading { loading = false } }
        error = nil
        let start = max(0, (newOffset / perPage) * perPage)
        do {
            let p = try await PDAAPI.topic(id: topicId, offset: start)
            page = p
            posts = p.posts
            startOffset = start
            endOffset = start + (start == 0 ? max(0, p.posts.count - 1) : p.posts.count)
            visibleIndex = start == 0 ? 1 : start + 2
            let target = highlightPost.flatMap { h in p.posts.contains { $0.id == h } ? h : nil } ?? p.posts.first?.id
            scrollTarget = target
        } catch {
            self.error = error.localizedDescription
            if page != nil { alert = ActionAlert(title: "Ошибка", message: error.localizedDescription) }
        }
    }

    /// Подгружает следующую страницу в конец списка.
    private func loadMore() async {
        guard !loadingMore, !loading, page != nil, endOffset < total else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let p = try await PDAAPI.topic(id: topicId, offset: endOffset)
            let known = Set(posts.map(\.id))
            let add = p.posts.filter { !known.contains($0.id) }
            page = p
            if add.isEmpty {
                endOffset = max(endOffset, p.totalPosts)
            } else {
                posts += add
                endOffset += p.posts.count
            }
        } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }

    /// Подгружает предыдущую страницу в начало списка, сохраняя позицию.
    private func loadPrevious(proxy: ScrollViewProxy) async {
        guard !loadingPrev, startOffset > 0 else { return }
        loadingPrev = true
        defer { loadingPrev = false }
        let start = max(0, startOffset - perPage)
        do {
            let p = try await PDAAPI.topic(id: topicId, offset: start)
            let known = Set(posts.map(\.id))
            let add = p.posts.filter { !known.contains($0.id) }
            let anchor = posts.first?.id
            page = p
            posts = add + posts
            startOffset = start
            if let anchor = anchor { scrollTarget = anchor }
        } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }

    /// Обновляет текущую страницу.
    private func refresh() async {
        await load((currentPage - 1) * perPage)
    }

    private func afterSend(_ sent: PDAAPI.SentPost?) async {
        guard let sent = sent else { await refresh(); return }
        highlightPost = sent.postId
        await load(PDAAPI.offset(forPosition: sent.index))
    }

    private func rate(_ post: Post, up: Bool) async {
        do {
            try await PDAAPI.ratePost(post.id, up: up)
            alert = ActionAlert(title: "Готово", message: "Голос засчитан")
            await refresh()
        } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }

    private func toggleSubscription(_ page: TopicPage) async {
        do {
            try await PDAAPI.setTopicSubscribed(topicId, !page.isSubscribed)
            self.page = try await PDAAPI.topic(id: topicId, offset: startOffset)
        } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }
}

// MARK: - Пост

struct PostView: View {
    let post: Post
    var number: Int = 0
    var highlighted = false
    @EnvironmentObject private var router: Router
    @AppStorage("show_signatures") private var showSignatures = true
    @AppStorage("collapse_header") private var collapseHeader = false
    @State private var headerOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Шапка поста как в Android-клиенте: аватар, точка «в сети», ник, репутация
            // верхним индексом, группа своим цветом, дата справа.
            HStack(alignment: .top, spacing: 10) {
                Button { router.push(ProfileRoute(id: post.authorId, nick: post.authorName)) } label: {
                    AvatarView(url: post.avatar, size: 46)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if post.isOnline {
                            Circle().fill(PDATheme.online).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        }
                        Text(post.authorName).font(.headline).lineLimit(1)
                        Text("\(post.reputation)").font(.caption2).foregroundStyle(.secondary).baselineOffset(7)
                    }
                    Text(PDAAPI.groups[post.authorGroup] ?? "")
                        .font(.subheadline).foregroundStyle(PDATheme.groupColor(post.authorGroup))
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    if number > 0 {
                        Text("#\(number)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if post.showsRating {
                        Text(post.ratingValue > 0 ? "+\(post.ratingValue)" : "\(post.ratingValue)")
                            .font(.subheadline.bold())
                            .foregroundStyle(post.ratingValue > 0 ? .green : post.ratingValue < 0 ? .red : .secondary)
                    }
                    Spacer(minLength: 0)
                    Text(post.date.pdaFormatted).font(.caption).foregroundStyle(.secondary)
                }
            }
            if number == 1, collapseHeader, !headerOpen {
                Button { headerOpen = true } label: {
                    Label("Шапка темы свёрнута — показать", systemImage: "chevron.down").font(.footnote)
                }
                .buttonStyle(.borderless)
            } else {
                BBContentView(post.bodyBB, attachments: post.attachments)
            }
            let unused = post.attachments.filter { a in !post.bodyBB.contains("\(a.id)") }
            if !unused.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(unused, id: \.id) { a in
                        if a.isImage, let u = PDAAPI.absoluteURL(a.url) {
                            PostImage(url: u)
                        } else if let u = PDAAPI.absoluteURL(a.url) {
                            BrowserLink(destination: u) {
                                Label(a.name + (a.size > 0 ? " · " + ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file) : ""),
                                      systemImage: "paperclip").font(.footnote)
                            }
                        }
                    }
                }
            }
            if post.editDate != nil || !post.editReason.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    if let d = post.editDate {
                        Text("Отредактировал \(post.editedBy.isEmpty ? "" : post.editedBy + " - ")\(d.pdaFormatted)")
                    }
                    if !post.editReason.isEmpty { Text("Причина: \(post.editReason)") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if showSignatures, !post.signatureBB.isEmpty {
                Divider()
                BBContentView(post.signatureBB)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
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
