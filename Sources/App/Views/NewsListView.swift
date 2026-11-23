import SwiftUI

struct NewsListView: View {
    @State private var items: [NewsItem] = []
    @State private var error: String?
    @State private var loading = false
    @State private var reachedEnd = false

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
                            .onAppear {
                                if item.id == items.last?.id { Task { await loadMore() } }
                            }
                    }
                    if loading && !items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .listStyle(.plain)
                .refreshable { await reload() }
            }
        }
        .navigationTitle("Новости")
        .task { if items.isEmpty { await reload() } }
    }

    private func reload() async {
        error = nil
        reachedEnd = false
        do {
            items = try await PDAAPI.news()
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
            let more = try await PDAAPI.news(offset: items.count)
            let known = Set(items.map(\.id))
            items += more.filter { !known.contains($0.id) }
            reachedEnd = more.count < 30
        } catch {
            reachedEnd = true
        }
    }
}

struct NewsRow: View {
    let item: NewsItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: item.imageURL, contentMode: .fill) {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 96, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(3)
                HStack(spacing: 8) {
                    Text(item.date.pdaFormatted)
                    Label("\(item.commentsCount)", systemImage: "bubble.right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct NewsDetailView: View {
    let item: NewsItem
    @EnvironmentObject private var client: PDAClient
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
                    BBContentView(article.bodyBB)
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
                                HStack {
                                    Text(c.authorName).font(.subheadline.bold())
                                    Text(c.date.pdaFormatted).font(.caption).foregroundStyle(.secondary)
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
                                NavigationLink(value: ProfileRoute(id: c.authorId, nick: c.authorName)) {
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
