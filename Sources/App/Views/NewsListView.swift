import SwiftUI

struct NewsListView: View {
    @State private var items: [NewsItem] = []
    @State private var error: String?
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var categories: [PDAAPI.SiteCategory] = []
    @State private var category: PDAAPI.SiteCategory?

    var body: some View {
        Group {
            if let error = error, items.isEmpty {
                ErrorView(message: error) { Task { await reload() } }
            } else if items.isEmpty {
                ProgressView("Загрузка новостей…")
            } else {
                List {
                    ForEach(items) { item in
                        NavigationLink(value: item) { NewsRow(item: item) }
                            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color(uiColor: .systemBackground))
                            .padding(.bottom, 2)
                            .onAppear {
                                if let i = items.firstIndex(of: item), i >= items.count - 8 { Task { await loadMore() } }
                            }
                    }
                    if loading && !items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .refreshable { await reload() }
            }
        }
        .navigationTitle(category?.title.capitalized ?? "Новости")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Button { select(nil) } label: { Label("Главная", systemImage: category == nil ? "checkmark" : "") }
                    ForEach(categories) { c in
                        Button { select(c) } label: { Label(c.title, systemImage: category == c ? "checkmark" : "") }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(category?.title.capitalized ?? "Новости").font(.headline)
                        Image(systemName: "chevron.down").font(.caption.bold())
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .task {
            if items.isEmpty { await reload() }
            if categories.isEmpty {
                categories = ((try? await PDAAPI.siteMenu()) ?? []).filter { $0.parent == 0 }
            }
        }
    }

    private func select(_ c: PDAAPI.SiteCategory?) {
        category = c
        items = []
        Task { await reload() }
    }

    private func reload() async {
        error = nil
        reachedEnd = false
        do {
            let list = try await PDAAPI.news(category: category?.tid ?? 0)
            await ImageLoader.shared.prefetch(list.prefix(8).compactMap(\.imageURL), timeout: 2)
            items = list
            reachedEnd = items.count < 30
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        do {
            let more = try await PDAAPI.news(offset: items.count, category: category?.tid ?? 0)
            await ImageLoader.shared.prefetch(more.compactMap(\.imageURL), timeout: 3)
            let known = Set(items.map(\.id))
            items += more.filter { !known.contains($0.id) }
            reachedEnd = more.count < 30
        } catch {
            reachedEnd = true
        }
    }
}

/// Карточка новости как в Android: картинка слева, жирный заголовок, время и комментарии.
struct NewsRow: View {
    let item: NewsItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: item.imageURL, contentMode: .fill) {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 136, height: 102)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(.headline, design: .default).weight(.heavy))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                Spacer(minLength: 2)
                HStack {
                    Text(item.date.pdaShort)
                    Spacer()
                    Label("\(item.commentsCount)", systemImage: "bubble.left.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(minHeight: 102)
        }
    }
}

struct NewsDetailView: View {
    let item: NewsItem
    @EnvironmentObject private var client: PDAClient
    @EnvironmentObject private var router: Router
    @State private var article: NewsArticle?
    @State private var error: String?
    @State private var replyTo: NewsComment?
    @State private var writing = false
    @State private var commentText = ""
    @State private var sending = false
    @State private var alert: ActionAlert?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let url = item.imageURL {
                    RemoteImage(url: url) {
                        Color.secondary.opacity(0.15).frame(height: 200)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(item.title).font(.title2.bold())
                Text("\(item.authorName) · \(item.date.pdaFormatted)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let article = article {
                    BBContentView(article.bodyBB, attachments: article.images)
                    if !article.comments.isEmpty {
                        Divider().padding(.vertical, 8)
                        HStack {
                            Text("Комментарии (\(article.comments.count))").font(.headline)
                            Spacer()
                            if client.isLoggedIn {
                                Button("Написать") { replyTo = nil; writing = true }
                            }
                        }
                        ForEach(article.comments) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    RemoteImage(avatar: PDAAPI.absoluteURL(c.avatar))
                                        .frame(width: 28, height: 28).clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(c.authorName).font(.subheadline.bold()).foregroundStyle(Color.accentColor)
                                        Text(c.date.pdaFormatted).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if c.karma != 0 {
                                        Label("\(c.karma)", systemImage: "heart.fill")
                                            .font(.caption).foregroundStyle(c.karma > 0 ? .pink : .secondary)
                                    }
                                }
                                if c.isDeleted {
                                    Text("Комментарий удалён").font(.footnote).foregroundStyle(.secondary)
                                } else {
                                    BBContentView(c.text)
                                }
                            }
                            .padding(.leading, CGFloat(c.depth) * 14)
                            .padding(.vertical, 4)
                            .contextMenu {
                                if client.isLoggedIn, !c.isDeleted {
                                    Button { replyTo = c; writing = true } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
                                    Button { Task { await rate(c, up: true) } } label: { Label("Нравится", systemImage: "hand.thumbsup") }
                                    Button { Task { await rate(c, up: false) } } label: { Label("Не нравится", systemImage: "hand.thumbsdown") }
                                }
                                Button { router.push(ProfileRoute(id: c.authorId, nick: c.authorName)) } label: {
                                    Label("Профиль \(c.authorName)", systemImage: "person")
                                }
                            }
                        }
                    }
                } else {
                    BBContentView(item.descriptionBB)
                    if let error = error {
                        Text("Не удалось загрузить статью: \(error)").font(.footnote).foregroundStyle(.red)
                        Button("Повторить") { Task { await load() } }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }

                if let url = URL(string: "\(PDAConfig.siteURL.absoluteString)index.php?p=\(item.id)") {
                    BrowserLink("Открыть статью на сайте", destination: url)
                        .padding(.top, 8)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if article == nil { await load() } }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .sheet(isPresented: $writing) {
            NavigationStack {
                VStack(spacing: 0) {
                    if let r = replyTo {
                        Text("Ответ \(r.authorName)").font(.footnote).foregroundStyle(.secondary).padding(8)
                    }
                    TextEditor(text: $commentText).padding(.horizontal, 8)
                }
                .navigationTitle("Комментарий")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { writing = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Отправить") { Task { await sendComment() } }
                            .disabled(sending || commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func sendComment() async {
        sending = true
        defer { sending = false }
        do {
            try await PDAAPI.sendComment(articleId: item.id, parentId: replyTo?.id ?? 0, text: commentText)
            commentText = ""
            writing = false
            await load()
        } catch {
            writing = false
            alert = ActionAlert(title: "Комментарий", message: error.localizedDescription)
        }
    }

    private func rate(_ c: NewsComment, up: Bool) async {
        do {
            try await PDAAPI.rateComment(articleId: item.id, commentId: c.id, up: up)
        } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }

    private func load() async {
        error = nil
        do {
            article = try await PDAAPI.article(id: item.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
