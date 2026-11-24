import CryptoKit
import Foundation

// MARK: - Модели

struct PollQuestion: Hashable {
    let text: String
    let multiple: Bool
    let options: [String]
    let votes: [Int]
}

struct Poll: Hashable {
    let title: String
    let totalVotes: Int
    let voted: Bool
    let questions: [PollQuestion]
}

struct FavoriteItem: Identifiable, Hashable {
    let isForum: Bool
    let id: Int
    let title: String
    let flags: Int
    let lastPoster: String
    let lastDate: Date
    let notifyMode: Int
    var uid: String { (isForum ? "f" : "t") + String(id) }
    var hasUnread: Bool { flags & 32 != 0 }
    var isImportant: Bool { flags & 1 != 0 }
    var isClosed: Bool { flags & 4 != 0 }
}

struct MentionItem: Identifiable, Hashable {
    let isSite: Bool
    let unread: Bool
    let targetId: Int
    let title: String
    let post: Post?
    var id: String { "\(targetId)-\(post?.id ?? 0)" }
}

struct QMSDialogSummary: Identifiable, Hashable {
    let id: Int
    let date: Date
    let title: String
    let messageCount: Int
    let unread: Int
}

struct QMSContact: Identifiable, Hashable {
    let id: Int
    let nick: String
    let group: Int
    let avatar: String
    let lastSeen: Date
    let unread: Int
    let dialogs: [QMSDialogSummary]
}

struct QMSMessage: Identifiable, Hashable {
    let id: Int
    let authorId: Int
    let date: Date
    let textBB: String
    let attachments: [Attachment]
}

struct QMSDialog {
    let title: String
    let partnerId: Int
    let partnerNick: String
    let messages: [QMSMessage]
}

struct MemberProfile {
    let id: Int
    let nick: String
    let avatar: String
    let group: Int
    let title: String
    let signatureBB: String
    let registered: Date
    let lastVisit: Date
    let reputation: Int
    let topics: Int
    let posts: Int
    let sitePosts: Int
    let comments: Int
    let devices: [(name: String, link: String, main: Bool)]
    var birthday: String = ""
    var gender: Int = 0
    var timezone: Int = 0
    var siteKarma: Int = 0
    var warnLevel: Int = 0
    let raw: PDAValue
    var isOnline: Bool { lastVisit.timeIntervalSince1970 > 0 && Date().timeIntervalSince(lastVisit) < 900 }
}

enum SearchResult: Identifiable {
    case post(topicId: Int, topicTitle: String, post: Post)
    case topic(TopicSummary)
    case article(id: Int, title: String)

    var id: String {
        switch self {
        case .post(_, _, let p): return "p\(p.id)"
        case .topic(let t): return "t\(t.id)"
        case .article(let id, _): return "a\(id)"
        }
    }
}

/// Ошибка отправки с понятным текстом.
struct PDAMessageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Команды

extension PDAAPI {
    /// Группы пользователей (из оригинального клиента).
    static let groups: [Int: String] = [
        1: "Неактивированные", 2: "Гости", 3: "Пользователи", 4: "Админы", 5: "Забанен",
        7: "Активные пользователи", 8: "Друзья 4PDA", 9: "Модераторы", 10: "Супермодераторы",
        11: "Помощник модератора", 12: "FAQMakers", 13: "Почетные форумчане", 15: "Разработчики",
        16: "Роутеры", 17: "Бизнесмены", 18: "Участник спецпроекта", 19: "Школа Модераторов", 20: "Кураторы",
    ]

    static func post(from p: PDAValue) -> Post? {
        guard p[8]?.stringValue != nil else { return nil }
        let attachments = (p[11]?.arrayValue ?? []).map { attachment(from: $0) }
        return Post(id: p.int(0), flags: p.int(1), authorId: p.int(2),
                    authorName: HTMLEntities.decode(p.string(3)), authorGroup: p.int(4),
                    date: Date(timeIntervalSince1970: TimeInterval(p.int(7))), bodyBB: p.string(8), avatar: p.string(9),
                    attachments: attachments, editReason: HTMLEntities.decode(p.string(15)),
                    rating: p.int(12), reputation: p.int(6),
                    lastVisit: p.int(5) > 0 ? Date(timeIntervalSince1970: TimeInterval(p.int(5))) : nil,
                    signatureBB: p.string(10), editedBy: HTMLEntities.decode(p.string(14)),
                    editDate: p.int(13) > 0 ? Date(timeIntervalSince1970: TimeInterval(p.int(13))) : nil)
    }

    static func attachment(from a: PDAValue) -> Attachment {
            // [id, 1 — картинка / 0 — файл, имя, размер, адрес, ширина, высота]
            let isImage = a.int(1) > 0
            let url = a.string(4).isEmpty ? a.string(2) : a.string(4)
            return Attachment(id: a.int(0), isImage: isImage, name: a.string(2), url: url,
                              width: a.int(5), height: a.int(6), size: a.int(3))
    }

    /// Тема в списке: [id, название, описание, флаги, постов, дата последнего, id последнего, ник последнего].
    static func topicSummary(_ t: PDAValue) -> TopicSummary {
        TopicSummary(id: t.int(0), title: HTMLEntities.decode(BBParser.plainText(t.string(1))), flags: t.int(3),
                     lastPostDate: Date(timeIntervalSince1970: TimeInterval(t.int(5))),
                     lastPoster: HTMLEntities.decode(t.string(7)),
                     description: HTMLEntities.decode(BBParser.plainText(t.string(2))), postCount: t.int(4))
    }

    /// Смещение страницы для позиции поста. Позиция 0 — шапка темы, она приходит
    /// с каждой страницей; страница со смещением N содержит посты N+1…N+20.
    static func offset(forPosition position: Int) -> Int {
        position <= 0 ? 0 : ((position - 1) / postsPerPage) * postsPerPage
    }

    /// Универсальное действие (`fm`): [тип объекта, [id], маска, значение, причина].
    /// Типы: 11 — тема (8 подписка, 4 закрыть, 2 скрыть, 1 закрепить, 32 прочитано),
    /// 21 — форум (8 подписка, 32 прочитано), 15 — режим оповещений, 1 — флаги поста,
    /// 4 — удалить посты, 5 — восстановить, 14 — удалить тему.
    @discardableResult
    static func objectAction(type: Int, ids: [Int], mask: Int, value: Int, reason: String = "") async throws -> PDAValue {
        try await PDAClient.shared.call("fm", [.int(type), .array(ids.map { .int($0) }), .int(mask), .int(value), .string(reason)])
    }

    static func setTopicSubscribed(_ topicId: Int, _ on: Bool) async throws {
        try await objectAction(type: 11, ids: [topicId], mask: 8, value: on ? 8 : 0)
    }

    static func setForumSubscribed(_ forumId: Int, _ on: Bool) async throws {
        try await objectAction(type: 21, ids: [forumId], mask: 8, value: on ? 8 : 0)
    }

    static func markRead(topic: Int? = nil, forum: Int? = nil) async throws {
        if let t = topic { try await objectAction(type: 11, ids: [t], mask: 32, value: 0) }
        if let f = forum { try await objectAction(type: 21, ids: [f], mask: 32, value: 0) }
    }

    // MARK: Посты

    struct SentPost { let topicId: Int; let index: Int; let postId: Int }

    /// Отправка/правка поста (`fp`): [тема, id поста (0 — новый), флаги, текст, [вложения], причина правки].
    /// Флаги: 1 — ответ на вопрос «склеить с предыдущим» (1 — да, 3 — нет).
    /// Коды: 4 — премодерация, 5 — слишком длинно, 6 — дубль, 7 — предложение склеить, 8 — недопустимо.
    static func sendPost(topicId: Int, postId: Int = 0, text: String, attachments: [Int] = [],
                         editReason: String? = nil, flags: Int = 0) async throws -> SentPost {
        var params: [PDAValue] = [.int(topicId), .int(postId), .int(flags), .string(text),
                                  .array(attachments.map { .int($0) })]
        if postId != 0, let reason = editReason { params.append(.string(reason)) }
        do {
            let data = try await PDAClient.shared.call("fp", params, timeout: 40)
            return SentPost(topicId: data.int(0), index: data.int(1), postId: data.int(2))
        } catch let error as PDAServerError {
            let payload = PDAClient.shared.lastErrorPayload
            switch error.code {
            case 4:
                let msg = payload?.string(3) ?? ""
                throw PDAMessageError(message: msg.isEmpty ? "Пост отправлен на премодерацию" : msg)
            case 5: throw PDAMessageError(message: "Слишком много букв")
            case 6: throw PDAMessageError(message: "Этот пост уже был отправлен")
            case 7: throw MergeQuestion()
            case 8:
                let msg = payload?.string(0) ?? ""
                throw PDAMessageError(message: msg.isEmpty ? "Ошибка: недопустимое содержание" : msg)
            default: throw PDAMessageError(message: "Ошибка отправки поста (код \(error.code))")
            }
        }
    }

    /// Сервер спрашивает: «Прикрепить этот пост к предыдущему?»
    struct MergeQuestion: Error {}

    /// Оценка поста (`fk`): [id поста, +1/-1].
    static func ratePost(_ postId: Int, up: Bool) async throws {
        do {
            _ = try await PDAClient.shared.call("fk", [.int(postId), .int(up ? 1 : -1)])
        } catch is PDAServerError {
            throw PDAMessageError(message: "Ошибка изменения репутации поста")
        }
    }

    /// Изменение репутации (`mr`): [id пользователя, 1 — плюс / 0 — минус, id поста (минус — комментарий на сайте), причина].
    static func changeReputation(userId: Int, up: Bool, postId: Int, reason: String) async throws {
        do {
            _ = try await PDAClient.shared.call("mr", [.int(userId), .int(up ? 1 : 0), .int(postId), .string(reason)])
        } catch let error as PDAServerError {
            let texts = ["Изменение репутации заблокировано", "Вы не можете менять репутацию самому себе",
                         "У вас недостаточно постов, чтобы менять репутацию", "У вас слишком низкая репутация",
                         "Вы больше не можете менять репутацию сегодня",
                         "Вы больше не можете менять репутацию этому человеку сегодня",
                         "Вы больше не можете менять репутацию за этот пост",
                         "В данный момент вы не можете изменить репутацию этому человеку",
                         "Изменение отклонено, т.к. вы недавно ставили минус этому человеку",
                         "Изменение отклонено, т.к. пользователь недавно поставил вам минус"]
            if (4...13).contains(error.code) { throw PDAMessageError(message: texts[error.code - 4]) }
            if error.code == 14, let m = PDAClient.shared.lastErrorPayload?.string(0), !m.isEmpty {
                throw PDAMessageError(message: m)
            }
            throw PDAMessageError(message: "Ошибка изменения репутации")
        }
    }

    /// Голосование (`fv`): [id темы, [[выбранные варианты по каждому вопросу]]].
    static func vote(topicId: Int, answers: [[Int]]) async throws {
        _ = try await PDAClient.shared.call("fv", [.int(topicId), .array(answers.map { .array($0.map { .int($0) }) })])
    }

    /// Переход к посту (`fj`): режим 1 — первый непрочитанный, 2 — последний, 3 — конкретный пост.
    /// Ответ: [id темы, позиция поста, id поста, ...].
    static func findPost(mode: Int, id: Int) async throws -> (topicId: Int, offset: Int, postId: Int) {
        let data = try await PDAClient.shared.call("fj", [.int(mode), .int(id), -1, 0])
        return (data.int(0), offset(forPosition: data.int(1)), data.int(2))
    }

    // MARK: Избранное, история, упоминания

    /// Избранное (`mf`): [смещение, 30, сортировка] → [всего, [элементы]].
    static func favorites(offset: Int = 0) async throws -> (total: Int, items: [FavoriteItem]) {
        let data = try await PDAClient.shared.call("mf", [.int(offset), .int(topicsPerPage), 0])
        let items = data.array(1).map { f in
            FavoriteItem(isForum: f.int(0) != 1, id: f.int(1), title: HTMLEntities.decode(f.string(2)),
                         flags: f.int(4), lastPoster: HTMLEntities.decode(f.string(8)),
                         lastDate: Date(timeIntervalSince1970: TimeInterval(f.int(9))), notifyMode: f.int(11))
        }
        return (data.int(0), items)
    }

    /// История просмотра (`mh`): [смещение, 30] → [всего, [темы]].
    static func history(offset: Int = 0) async throws -> (total: Int, items: [TopicSummary]) {
        let data = try await PDAClient.shared.call("mh", [.int(offset), .int(topicsPerPage)])
        return (data.int(0), data.array(1).map(topicSummary))
    }

    /// Упоминания (`mm`): [0, 0, показывать посты, смещение, 20] → [[элементы], всего].
    static func mentions(offset: Int = 0) async throws -> (total: Int, items: [MentionItem]) {
        let data = try await PDAClient.shared.call("mm", [0, 0, 1, .int(offset), .int(postsPerPage)])
        let items = data.array(0).map { m -> MentionItem in
            let postPart = PDAValue.array(Array((m.arrayValue ?? []).dropFirst(6)))
            return MentionItem(isSite: m.int(0) > 0, unread: m.int(1) != 0, targetId: m.int(4),
                               title: HTMLEntities.decode(m.string(5)), post: post(from: postPart))
        }
        return (data.int(1), items)
    }

    // MARK: QMS

    private static func qmsContacts(_ data: PDAValue) -> [QMSContact] {
        data.array(0).map { c in
            QMSContact(id: c.int(0), nick: HTMLEntities.decode(c.string(1)), group: c.int(2), avatar: c.string(3),
                       lastSeen: Date(timeIntervalSince1970: TimeInterval(c.int(4))), unread: c.int(6),
                       dialogs: c.array(7).map { d in
                           QMSDialogSummary(id: d.int(0), date: Date(timeIntervalSince1970: TimeInterval(d.int(2))),
                                            title: HTMLEntities.decode(d.string(3)), messageCount: d.int(4), unread: d.int(5))
                       })
        }
    }

    /// Контакты и диалоги QMS (`ql`).
    static func qmsContacts() async throws -> [QMSContact] {
        qmsContacts(try await PDAClient.shared.call("ql"))
    }

    /// Диалоги одного собеседника (`ql`): [id собеседника] → [[собеседник с диалогами]].
    static func qmsDialogs(contactId: Int) async throws -> [QMSDialogSummary] {
        qmsContacts(try await PDAClient.shared.call("ql", [.int(contactId)])).first?.dialogs ?? []
    }

    /// Поиск по сообщениям QMS (`ql`): [0, 0, запрос].
    static func qmsSearch(_ query: String) async throws -> [QMSContact] {
        qmsContacts(try await PDAClient.shared.call("ql", [0, 0, .string(query)]))
    }

    /// Диалог (`qt`): [id диалога, с какого сообщения, количество; -60 — последние 60].
    static func qmsDialog(id: Int, from: Int = 0, count: Int = -60) async throws -> QMSDialog {
        let data = try await PDAClient.shared.call("qt", [.int(id), .int(from), .int(count)])
        let messages: [QMSMessage] = data.array(13).compactMap { m in
            guard m[3]?.stringValue != nil else { return nil }
            let attachments = (m[4]?.arrayValue ?? []).map { attachment(from: $0) }
            return QMSMessage(id: m.int(0), authorId: m.int(1), date: Date(timeIntervalSince1970: TimeInterval(m.int(2))),
                              textBB: m.string(3), attachments: attachments)
        }.sorted { $0.id < $1.id }
        return QMSDialog(title: HTMLEntities.decode(data.string(3)), partnerId: data.int(4),
                         partnerNick: HTMLEntities.decode(data.string(5)), messages: messages)
    }

    /// Отправка сообщения (`qp`): [id диалога, текст, [вложения]].
    static func qmsSend(dialogId: Int, text: String, attachments: [Int] = []) async throws {
        do {
            _ = try await PDAClient.shared.call("qp", [.int(dialogId), .string(text), .array(attachments.map { .int($0) })])
        } catch let error as PDAServerError {
            let m = (error.code == 4 || error.code == 5) ? PDAClient.shared.lastErrorPayload?.string(0) ?? "" : ""
            throw PDAMessageError(message: m.isEmpty ? "Ошибка при отправке сообщения" : m)
        }
    }

    /// Новый диалог (`qp`): [0, текст, [вложения], id пользователя, тема] → [id диалога].
    static func qmsCreate(userId: Int, title: String, text: String) async throws -> Int {
        let data = try await PDAClient.shared.call("qp", [0, .string(text), .array([]), .int(userId), .string(title)])
        return data.int(0)
    }

    /// Удаление (`qd`): [id диалога, id пользователя, флаг].
    static func qmsDelete(dialogId: Int, userId: Int = 0) async throws {
        _ = try await PDAClient.shared.call("qd", [.int(dialogId), .int(userId), 0])
    }

    /// Чёрный список (`qb`): [id] — добавить, [-id] — убрать, [0] — получить список.
    static func qmsBlacklist(userId: Int, add: Bool) async throws {
        _ = try await PDAClient.shared.call("qb", [.int(add ? userId : -userId)])
    }

    // MARK: Профиль, поиск

    /// Профиль (`mi`): [id пользователя].
    static func profile(id: Int) async throws -> MemberProfile {
        let d = try await PDAClient.shared.call("mi", [.int(id)])
        let devices = d.array(13).map { dev -> (String, String, Bool) in
            var link = dev.string(0)
            if !link.isEmpty, !link.hasPrefix("http") { link = link.contains("/") ? "" : PDAConfig.siteURL.absoluteString + "devdb/" + link }
            return (dev.string(1), link, dev.int(2) == 1)
        }
        func date(_ i: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d.int(i))) }
        return MemberProfile(id: d.int(0), nick: HTMLEntities.decode(d.string(1)), avatar: d.string(2), group: d.int(3),
                             title: HTMLEntities.decode(d.string(4)), signatureBB: d.string(5),
                             registered: date(7), lastVisit: date(8), reputation: d.int(17), topics: d.int(18),
                             posts: d.int(19), sitePosts: d.int(15), comments: d.int(16),
                             devices: devices.map { (name: $0.0, link: $0.1, main: $0.2) },
                             birthday: d.string(9), gender: d.int(10), timezone: d.int(11),
                             siteKarma: d.int(14), warnLevel: d.int(26), raw: d)
    }

    enum SearchScope: Int { case all = 3, titles = 2, posts = 1 }

    static func parseSearchItems(_ data: PDAValue) -> [SearchResult] {
        data.array(1).compactMap { item -> SearchResult? in
            let type = item.int(0)
            let rest = Array((item.arrayValue ?? []).dropFirst())
            let v = PDAValue.array(rest)
            if type & 1 != 0 {
                let postPart = PDAValue.array(Array(rest.dropFirst(3)))
                guard let p = post(from: postPart) else { return nil }
                return .post(topicId: v.int(1), topicTitle: HTMLEntities.decode(BBParser.plainText(v.string(2))), post: p)
            }
            if type & 2 != 0 { return .topic(topicSummary(v)) }
            // Статья: поля как у новости, сдвинутые на 1 (заголовок — 9).
            if type & 4 != 0 { return .article(id: v.int(0), title: HTMLEntities.decode(BBParser.plainText(v.string(9)))) }
            return nil
        }
    }

    /// Поиск по форуму (`rc`): [флаги, [форумы], [темы], [авторы], запрос, смещение, 20].
    static func search(_ query: String, scope: SearchScope = .all, topicId: Int? = nil, offset: Int = 0) async throws -> (total: Int, items: [SearchResult]) {
        let flags = 131072 | scope.rawValue | (topicId != nil ? 1 : 0)
        let topics: PDAValue = topicId.map { .array([.int($0)]) } ?? .array([])
        let data = try await PDAClient.shared.call("rc", [.int(flags), .array([]), topics, .array([]),
                                                          .string(query), .int(offset), .int(postsPerPage)])
        let items = parseSearchItems(data)
        return (data.int(0), items)
    }

    // MARK: Комментарии к новостям

    /// Комментарий (`sc`): [id статьи, id родительского комментария (0 — новый), текст].
    static func sendComment(articleId: Int, parentId: Int, text: String) async throws {
        do {
            _ = try await PDAClient.shared.call("sc", [.int(articleId), .int(parentId), .string(text)])
        } catch let error as PDAServerError {
            let texts: [Int: String] = [
                4: "Вам запрещено комментировать", 5: "Нет текста комментария",
                6: "Комментирование этого поста окончено",
                7: "Вы не можете ответить на свернутый вами комментарий",
                8: "Вы достигли кармического лимита комментирования", 9: "Повторный комментарий",
                10: "Вы достигли часового лимита комментирования", 11: "Вы достигли дневного лимита комментирования",
                12: "Комментарий отправлен на премодерацию",
            ]
            if let t = texts[error.code] { throw PDAMessageError(message: t) }
            if error.code == 13 || error.code == 14 {
                let m = PDAClient.shared.lastErrorPayload?.string(0) ?? ""
                throw PDAMessageError(message: m.isEmpty ? "Недопустимое содержание" : m)
            }
            throw PDAMessageError(message: "Ошибка при добавлении комментария")
        }
    }

    /// Оценка комментария (`sk`): [id статьи, id комментария, +1/-1].
    static func rateComment(articleId: Int, commentId: Int, up: Bool) async throws {
        _ = try await PDAClient.shared.call("sk", [.int(articleId), .int(commentId), .int(up ? 1 : -1)])
    }

    // MARK: Меню сайта, закладки, счётчики

    struct SiteCategory: Identifiable, Hashable { let id: Int; let tid: Int; let title: String; let parent: Int }

    /// Меню сайта (`sm`): [версия] → [версия, [[id, tid, адрес, название, скрыт, родитель]]].
    static func siteMenu() async throws -> [SiteCategory] {
        let data = try await PDAClient.shared.call("sm", [0])
        return data.array(1).compactMap { c in
            c.int(4) != 0 ? nil : SiteCategory(id: c.int(0), tid: c.int(1), title: HTMLEntities.decode(c.string(3)), parent: c.int(5))
        }
    }

    struct Bookmark: Identifiable, Hashable {
        let id: Int
        let isFolder: Bool
        let parent: Int
        let order: Int
        let title: String
        let url: String
    }

    /// Закладки (`mb`): [время синхронизации, [изменения]] →
    /// [время, [[id, новый id]], [[id, изменено, удалено, флаги, папка, порядок, название, адрес]]].
    static func bookmarks() async throws -> [Bookmark] {
        try await syncBookmarks(changes: [])
    }

    /// Добавляет закладку (адрес относительно сайта, как в Android: forum/index.php?showtopic=…).
    static func addBookmark(title: String, url: String) async throws {
        let existing = (try? await bookmarks()) ?? []
        let order = (existing.map(\.order).max() ?? 0) + 1
        let now = Int(Date().timeIntervalSince1970)
        _ = try await syncBookmarks(changes: [[.int(-Int.random(in: 1...1_000_000)), .int(now), 0, 0, 0, .int(order), .string(title), .string(url)]])
    }

    static func deleteBookmark(_ b: Bookmark) async throws {
        let now = Int(Date().timeIntervalSince1970)
        _ = try await syncBookmarks(changes: [[.int(b.id), .int(now), 1, .int(b.isFolder ? 1 : 0), .int(b.parent), .int(b.order),
                                               .string(b.title), .string(b.url)]])
    }

    private static func syncBookmarks(changes: [PDAValue]) async throws -> [Bookmark] {
        let data = try await PDAClient.shared.call("mb", [0, .array(changes)])
        return data.array(2).compactMap { b in
            b.int(2) != 0 ? nil : Bookmark(id: b.int(0), isFolder: b.int(3) & 1 != 0, parent: b.int(4), order: b.int(5),
                                           title: HTMLEntities.decode(b.string(6)), url: b.string(7))
        }.sorted { $0.order < $1.order }
    }

    struct UnreadCounters: Equatable { var qms = 0, favorites = 0, mentions = 0 }

    /// Счётчики непрочитанного (`mn`): [с какого времени, 0, 0] → [время, QMS, избранное, упоминания, [события]].
    static func unreadCounters() async throws -> UnreadCounters {
        let data = try await PDAClient.shared.call("mn", [0, 0, 0])
        return UnreadCounters(qms: data.int(1), favorites: data.int(2), mentions: data.int(3))
    }

    struct ReputationEntry: Identifiable {
        let id: Int
        let date: Date
        let positive: Bool
        let fromId: Int
        let fromNick: String
        let whereTitle: String
        let reasonBB: String
        let cancelled: Bool
    }

    /// История репутации (`mr`): [id пользователя, режим (2 — полученная, 3 — выставленная), 0, 200].
    static func reputationHistory(userId: Int, given: Bool = false) async throws -> [ReputationEntry] {
        let data = try await PDAClient.shared.call("mr", [.int(userId), .int(given ? 3 : 2), 0, 200])
        return data.array(1).map { r in
            ReputationEntry(id: r.int(0), date: Date(timeIntervalSince1970: TimeInterval(r.int(1))),
                            positive: r.int(2) > 0, fromId: r.int(3), fromNick: HTMLEntities.decode(r.string(4)),
                            whereTitle: HTMLEntities.decode(BBParser.plainText(r.string(5))), reasonBB: r.string(10),
                            cancelled: r.int(6) & 2 != 0)
        }
    }

    /// Поиск сообщений или тем пользователя (`rc` с фильтром по автору).
    static func searchByAuthor(_ userId: Int, topics: Bool, offset: Int = 0) async throws -> (total: Int, items: [SearchResult]) {
        let flags = 131072 | (topics ? SearchScope.titles.rawValue : SearchScope.posts.rawValue)
        let data = try await PDAClient.shared.call("rc", [.int(flags), .array([]), .array([]), .array([.int(userId)]),
                                                          "", .int(offset), .int(postsPerPage)])
        return (data.int(0), parseSearchItems(data))
    }

    enum ComplaintTarget: Int { case post = 0, siteComment = 1, reputation = 2 }

    /// Жалоба (`ta`): [тип (0 — пост, 1 — комментарий на сайте, 2 — репутация), id, текст].
    static func complain(_ target: ComplaintTarget, id: Int, text: String) async throws {
        do {
            _ = try await PDAClient.shared.call("ta", [.int(target.rawValue), .int(id), .string(text)])
        } catch let e as PDAServerError where e.code == 4 {
            throw PDAMessageError(message: "Слишком короткая жалоба")
        }
    }

    struct ForumInfo {
        let name: String
        let description: String
        let subforums: Int
        let topics: Int
        let posts: Int
        let moderators: [(id: Int, nick: String, group: Int)]
    }

    /// О форуме (`fd`): [id] → [.., .., название, описание, .., .., подфорумов, тем, постов, [[id, ник, группа]]].
    static func forumInfo(_ id: Int) async throws -> ForumInfo {
        let d = try await PDAClient.shared.call("fd", [.int(id)])
        return ForumInfo(name: HTMLEntities.decode(d.string(2)), description: HTMLEntities.decode(d.string(3)),
                         subforums: d.int(6), topics: d.int(7), posts: d.int(8),
                         moderators: d.array(9).map { (id: $0.int(0), nick: HTMLEntities.decode($0.string(1)), group: $0.int(2)) })
    }

    struct UploadError: LocalizedError {
        let code: Int
        var errorDescription: String? {
            switch code {
            case 5: return "Файл слишком большой"
            case 6: return "Такой тип файла нельзя загрузить"
            default: return "Ошибка загрузки файла (код \(code))"
            }
        }
    }

    /// Загрузка вложения. Сначала `fu` [имя, размер, MD5] — если файл уже есть на
    /// сервере, сразу приходит id. Иначе (код 4) — `su` с ключом: узнаём смещение,
    /// отправляем данные двоичным хвостом и завершаем `su` [ключ, "fu", имя, размер, MD5].
    static func uploadAttachment(name: String, data: Data) async throws -> Int {
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
        let meta: [PDAValue] = [.string(name), .int(data.count), .string(md5)]
        do {
            return try await PDAClient.shared.call("fu", meta).int(0)
        } catch let e as PDAServerError where e.code == 4 {
            // нужно загрузить
        } catch let e as PDAServerError {
            throw UploadError(code: e.code)
        }
        let key = "att-\(PDAClient.shared.memberId)-\(Int.random(in: 100000...999999999))"
        var uploaded = try await PDAClient.shared.call("su", [.string(key)]).int(0)
        var attempts = 0
        while uploaded < data.count, attempts < 5 {
            attempts += 1
            let rest = data.subdata(in: max(0, uploaded)..<data.count)
            uploaded = try await PDAClient.shared.call("su", [.string(key)], binary: rest).int(0)
        }
        do {
            return try await PDAClient.shared.call("su", [.string(key), "fu"] + meta).int(0)
        } catch let e as PDAServerError {
            throw UploadError(code: e.code)
        }
    }

    /// Объявление (`fn`): [id] (0 — правила форума) → [название, текст BB].
    static func announcement(_ id: Int) async throws -> (title: String, bodyBB: String) {
        let d = try await PDAClient.shared.call("fn", [.int(id)])
        return (HTMLEntities.decode(d.string(0)), d.string(1))
    }

    /// Поле формы создания темы (`fw`).
    struct FormField: Identifiable {
        let id: Int
        let type: String        // text, editor, dropdown, checkbox_list, upload_box, …
        let title: String
        let description: String
        let required: Bool
        var text: String
        var options: [String] = []
        var selected = 0        // dropdown
        var checked: Set<Int> = []  // checkbox_list
        var attachments: [Int] = [] // upload_box
    }

    /// Форма создания темы: `fw` [форум, 0, 0] → [[[тип, название, описание, подсказка, флаги, значение, …]]].
    static func topicForm(forumId: Int) async throws -> [FormField] {
        let data = try await PDAClient.shared.call("fw", [.int(forumId), 0, 0])
        return data.array(0).enumerated().map { i, f in
            let type = f.string(0).lowercased()
            var field = FormField(id: i, type: type, title: HTMLEntities.decode(f.string(1)),
                                  description: HTMLEntities.decode(BBParser.plainText(f.string(2))),
                                  required: f.int(4) & 1 != 0, text: f.string(5))
            if type == "dropdown" || type == "checkbox_list" {
                field.options = f.array(6).map { HTMLEntities.decode($0.stringValue ?? "") }
            }
            return field
        }
    }

    private static func formValues(_ fields: [FormField]) -> PDAValue {
        .array(fields.map { f -> PDAValue in
            switch f.type {
            case "text", "editor": return .string(f.text)
            case "dropdown": return .int(f.selected + 1)
            case "checkbox_list": return .array(f.checked.sorted().map { .int($0 + 1) })
            case "upload_box": return .array(f.attachments.map { .int($0) })
            default: return 0
            }
        })
    }

    struct FormErrors: LocalizedError {
        let messages: [Int: String]
        let general: String
        var errorDescription: String? { general }
    }

    /// Отправка формы: `fw` [форум, 0, 2, [значения]] → [id новой темы].
    static func submitTopic(forumId: Int, fields: [FormField]) async throws -> Int {
        do {
            return try await PDAClient.shared.call("fw", [.int(forumId), 0, 2, formValues(fields)]).int(0)
        } catch let e as PDAServerError {
            let payload = PDAClient.shared.lastErrorPayload
            switch e.code {
            case 3: throw PDAMessageError(message: "Сервер отказал в создании темы (неверный параметр)")
            case 4: throw PDAMessageError(message: "Тема отправлена на премодерацию")
            case 5:
                var map: [Int: String] = [:]
                var general = "При заполнении формы допущены ошибки"
                for (i, v) in (payload?.array(0) ?? []).enumerated() {
                    if let m = v.stringValue, !m.isEmpty {
                        if i < fields.count { map[i] = m } else { general = m }
                    }
                }
                throw FormErrors(messages: map, general: general)
            default: throw e
            }
        }
    }

    // MARK: Каталог устройств (DevDB)

    struct DeviceType: Identifiable, Hashable { let id: String; let title: String }
    static let deviceTypes: [DeviceType] = [
        DeviceType(id: "phones", title: "Телефоны"), DeviceType(id: "pad", title: "Планшеты"),
        DeviceType(id: "ebook", title: "Эл. книги"), DeviceType(id: "smartwatch", title: "Смарт-часы"),
    ]
    struct DeviceVariant: Identifiable, Hashable { let id: String; let name: String }

    struct DeviceVendor: Identifiable, Hashable { let id: String; let name: String; let count: Int }

    /// Производители (`dt`): [тип] → [тип, название, [[id, название, устройств, …]]].
    static func deviceVendors(type: String) async throws -> (title: String, vendors: [DeviceVendor]) {
        let d = try await PDAClient.shared.call("dt", [.string(type)])
        return (HTMLEntities.decode(d.string(1)),
                d.array(2).map { DeviceVendor(id: $0.string(0), name: HTMLEntities.decode($0.string(1)), count: $0.int(2)) })
    }

    struct DeviceSpec: Hashable { let isSection: Bool; let key: String; let label: String; let value: String }
    struct DeviceSummary: Identifiable, Hashable {
        let id: String
        let name: String
        let image: String
        let specs: [DeviceSpec]
    }

    private static func spec(_ v: PDAValue) -> DeviceSpec {
        DeviceSpec(isSection: v.int(0) == 0, key: v.string(1), label: HTMLEntities.decode(v.string(2)),
                   value: HTMLEntities.decode(BBParser.plainText(v.string(4))))
    }

    /// Устройства производителя (`dv`): [тип, производитель] →
    /// [тип, название, производитель, название, [[id, модель, картинка, ?, [характеристики]]]].
    static func vendorDevices(type: String, vendor: String) async throws -> (title: String, devices: [DeviceSummary]) {
        let d = try await PDAClient.shared.call("dv", [.string(type), .string(vendor)])
        return (HTMLEntities.decode(d.string(3)),
                d.array(4).map { DeviceSummary(id: $0.string(0), name: HTMLEntities.decode($0.string(1)),
                                               image: $0.string(2), specs: $0.array(4).map(spec)) })
    }

    struct DeviceInfo {
        let type: String, typeName: String, vendor: String, vendorName: String
        let model: String, subtitle: String
        let variants: [DeviceVariant]
        let images: [(thumb: String, full: String)]
        let specs: [DeviceSpec]
    }

    /// Устройство (`de`): ["модель" или "модель:вариант"] → [тип, название типа, производитель,
    /// название, модель, подзаголовок, [[вариант, название]], [[главная, превью, полное]], [характеристики], моё].
    static func device(_ slug: String) async throws -> DeviceInfo {
        let d = try await PDAClient.shared.call("de", [.string(slug)])
        return DeviceInfo(type: d.string(0), typeName: HTMLEntities.decode(d.string(1)), vendor: d.string(2),
                          vendorName: HTMLEntities.decode(d.string(3)), model: HTMLEntities.decode(d.string(4)),
                          subtitle: HTMLEntities.decode(d.string(5)),
                          variants: d.array(6).map { DeviceVariant(id: $0.string(0), name: HTMLEntities.decode($0.string(1))) },
                          images: d.array(7).map { (thumb: $0.string(1), full: $0.string(2)) },
                          specs: d.array(8).map(spec))
    }

    // MARK: Модерация (доступно модераторам и кураторам)

    struct NoAccess: LocalizedError {
        var errorDescription: String? { "Нет доступа: раздел доступен только модераторам и кураторам" }
    }

    /// Тикеты (`tl`): [смещение, на странице, флаги, [форум или тема]]. Обычным пользователям — код 3.
    static func tickets(offset: Int = 0, forumOrTopic: Int = 0) async throws -> PDAValue {
        do { return try await PDAClient.shared.call("tl", [.int(offset), 20, 0, .array([.int(forumOrTopic)])]) }
        catch let e as PDAServerError where e.code == 3 { throw NoAccess() }
    }

    /// История темы/поста (`fh`): [0 — тема / 1 — пост, id].
    static func moderationLog(post: Bool, id: Int) async throws -> PDAValue {
        do { return try await PDAClient.shared.call("fh", [.int(post ? 1 : 0), .int(id)]) }
        catch let e as PDAServerError where e.code == 3 { throw NoAccess() }
    }
}
