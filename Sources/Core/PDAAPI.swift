import Foundation

/// Адрес сайта (обновляется из provision). Доступен из любого потока.
enum PDAConfig {
    static var siteURL = URL(string: "https://4pda.to/")!
}

// MARK: - Модели

struct NewsItem: Identifiable, Hashable {
    let id: Int
    let date: Date
    let title: String
    let descriptionBB: String
    let imageURL: URL?
    let authorId: Int
    let authorName: String
    let commentsCount: Int
}

struct NewsComment: Identifiable, Hashable {
    let id: Int
    let date: Date
    let isDeleted: Bool
    let authorId: Int
    let authorName: String
    let parentId: Int
    let text: String
    var depth: Int = 0
}

struct NewsArticle {
    let item: NewsItem
    let bodyBB: String
    let comments: [NewsComment]
}

struct ForumEntry: Identifiable, Hashable {
    let id: Int
    let name: String
    let flags: Int
    let link: String
    var isCategory: Bool { flags & 16 != 0 }
    var hasUnread: Bool { flags & 32 != 0 }
}

struct TopicSummary: Identifiable, Hashable {
    let id: Int
    let title: String
    let flags: Int
    let lastPostDate: Date
    let lastPoster: String
    var isPinned: Bool { flags & 1 != 0 }
    var isHighlighted: Bool { flags & 2 != 0 }
    var isClosed: Bool { flags & 4 != 0 }
    var isMoved: Bool { flags & 16 != 0 }
    var hasUnread: Bool { flags & 32 != 0 }
}

struct ForumPage {
    let name: String
    let flags: Int
    let subforums: [ForumEntry]
    let announcements: [ForumEntry]
    let topics: [TopicSummary]
    let totalTopics: Int
}

struct Attachment: Hashable {
    let id: Int
    let isImage: Bool
    let name: String
    let url: String
    let width: Int
    let height: Int
}

struct Post: Identifiable, Hashable {
    let id: Int
    let flags: Int
    let authorId: Int
    let authorName: String
    let authorGroup: Int
    let date: Date
    let bodyBB: String
    let avatar: String
    let attachments: [Attachment]
    var editReason: String = ""
    /// Поле 12: бит 1 — можно оценить, 2 — уже оценён (4 — плюс), остальное >> 3 — рейтинг.
    var rating: Int = 0

    var canEdit: Bool { flags & 128 != 0 }
    var canDelete: Bool { flags & 256 != 0 }
    var canRate: Bool { rating & 1 != 0 && rating & 2 == 0 }
    var ratingValue: Int { rating >> 3 }
    var showsRating: Bool { rating & 1 != 0 }
}

struct TopicPage {
    let id: Int
    let title: String
    let description: String
    let totalPosts: Int
    let flags: Int
    let authorId: Int
    let posts: [Post]
    let poll: Poll?

    /// Флаги темы (поле 4): 8 — в избранном, 16 — закрыта, 64 — можно отвечать, 128 — можно править, 4 — закрыта для голосования.
    var isSubscribed: Bool { flags & 8 != 0 }
    var canReply: Bool { flags & 64 != 0 && flags & 16 == 0 }
}

// MARK: - Команды

/// Обёртки над командами протокола. Индексы полей взяты из разбора официального клиента.
@MainActor
enum PDAAPI {
    static let topicsPerPage = 30
    static let postsPerPage = 20

    private static func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    nonisolated static func absoluteURL(_ s: String) -> URL? {
        if s.isEmpty { return nil }
        if s.hasPrefix("//") { return URL(string: "https:" + s) }
        if s.hasPrefix("http") { return URL(string: s) }
        return URL(string: s, relativeTo: PDAConfig.siteURL)?.absoluteURL
    }

    /// Лента новостей (`sl`): [смещение, количество, -1, категория].
    static func news(offset: Int = 0, category: Int = 0) async throws -> [NewsItem] {
        let data = try await PDAClient.shared.call("sl", [.int(offset), 30, -1, .int(category)])
        return data.array(1).compactMap { item in
            item.count > 10 ? newsItem(item) : nil
        }
    }

    private static func newsItem(_ item: PDAValue) -> NewsItem {
        NewsItem(
            id: item.int(0),
            date: date(item.int(1)),
            title: HTMLEntities.decode(item.string(9)),
            descriptionBB: item.string(10),
            imageURL: absoluteURL(item.string(8)),
            authorId: item.int(5),
            authorName: HTMLEntities.decode(item.string(6)),
            commentsCount: item.int(7)
        )
    }

    /// Статья целиком (`sa`): [id]. Данные — как элемент ленты; в поле 13 — комментарии
    /// [id, дата, флаги (2 — удалён), id автора, ник, id родителя, текст, ...].
    static func article(id: Int) async throws -> NewsArticle {
        let data = try await PDAClient.shared.call("sa", [.int(id)])
        let flat = data.array(13).map { c in
            NewsComment(id: c.int(0), date: date(c.int(1)), isDeleted: c.int(2) & 2 != 0,
                        authorId: c.int(3), authorName: HTMLEntities.decode(c.string(4)),
                        parentId: c.int(5), text: HTMLEntities.decode(c.string(6)))
        }
        // Дерево ответов: ответ идёт после родителя с отступом.
        var ordered: [NewsComment] = []
        func add(parent: Int, depth: Int) {
            for var c in flat where c.parentId == parent && c.id != parent {
                c.depth = depth
                ordered.append(c)
                add(parent: c.id, depth: min(depth + 1, 6))
            }
        }
        add(parent: 0, depth: 0)
        let known = Set(ordered.map(\.id))
        ordered += flat.filter { !known.contains($0.id) }
        return NewsArticle(item: newsItem(data), bodyBB: data.string(10), comments: ordered)
    }

    /// Дерево форумов (`fi`): плоский список, категории помечены флагом 16.
    static func forums() async throws -> [ForumEntry] {
        let data = try await PDAClient.shared.call("fi")
        return data.array(0).map { f in
            ForumEntry(id: f.int(0), name: HTMLEntities.decode(f.string(1)), flags: f.int(2), link: f.string(3))
        }
    }

    /// Раздел форума (`fs`): [id форума, смещение, тем на страницу].
    static func forum(id: Int, offset: Int = 0) async throws -> ForumPage {
        let data = try await PDAClient.shared.call("fs", [.int(id), .int(offset), .int(topicsPerPage)])
        let sub = data.array(6).map { f in
            ForumEntry(id: f.int(0), name: HTMLEntities.decode(f.string(1)), flags: f.int(2), link: "")
        }
        let ann = data.array(5).map { f in
            ForumEntry(id: f.int(0), name: HTMLEntities.decode(f.string(1)), flags: 0, link: "")
        }
        let topics = data.array(8).map { t in
            TopicSummary(id: t.int(0), title: HTMLEntities.decode(t.string(1)), flags: t.int(3),
                         lastPostDate: date(t.int(5)), lastPoster: HTMLEntities.decode(t.string(7)))
        }
        return ForumPage(name: HTMLEntities.decode(data.string(2)), flags: data.int(3),
                         subforums: sub, announcements: ann, topics: topics, totalTopics: data.int(7))
    }

    /// Тема (`fr`): [id темы, смещение, постов на страницу, 0].
    static func topic(id: Int, offset: Int = 0, mode: Int = 0) async throws -> TopicPage {
        let data = try await PDAClient.shared.call("fr", [.int(id), .int(offset), .int(postsPerPage), .int(mode)])
        let posts: [Post] = data.array(12).compactMap { post(from: $0) }
        var poll: Poll?
        if let p = data[10], p.count > 3 {
            let questions = p.array(3).map { q in
                PollQuestion(text: HTMLEntities.decode(q.string(0)), multiple: q.int(1) != 0,
                             options: q.array(2).map { HTMLEntities.decode($0.stringValue ?? "") },
                             votes: q.array(3).map { $0.intValue ?? 0 })
            }
            poll = Poll(title: HTMLEntities.decode(p.string(0)), totalVotes: p.int(1), voted: p.int(2) != 0,
                        questions: questions)
        }
        return TopicPage(id: id, title: HTMLEntities.decode(data.string(2)),
                         description: HTMLEntities.decode(data.string(3)),
                         totalPosts: data.int(11), flags: data.int(4), authorId: data.int(8),
                         posts: posts, poll: poll)
    }
}

enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "laquo": "«", "raquo": "»", "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©",
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let name = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X"), let code = UInt32(name.dropFirst(2), radix: 16),
                   let sc = Unicode.Scalar(code) {
                    replacement = String(Character(sc))
                } else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()), let sc = Unicode.Scalar(code) {
                    replacement = String(Character(sc))
                } else {
                    replacement = named[name]
                }
                if let r = replacement {
                    out += r
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
