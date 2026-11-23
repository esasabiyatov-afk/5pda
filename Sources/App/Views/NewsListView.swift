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
        .navigationDestination(for: NewsItem.self) { NewsDetailView(item: $0) }
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
            AsyncImage(url: item.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let url = item.imageURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.secondary.opacity(0.15).frame(height: 200)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(item.title).font(.title2.bold())
                Text("\(item.authorName) · \(item.date.pdaFormatted)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                BBContentView(item.descriptionBB)
                if let url = URL(string: "\(PDAClient.shared.siteURL.absoluteString)index.php?p=\(item.id)") {
                    Link("Открыть статью на сайте", destination: url)
                        .padding(.top, 8)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
