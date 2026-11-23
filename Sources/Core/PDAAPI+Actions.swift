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
    let raw: PDAValue
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
        let attachments = (p[11]?.arrayValue ?? []).map { a -> Attachment in
            let isImage = a.int(1) > 0
            return Attachment(id: a.int(0), isImage: isImage,
                              name: isImage ? a.string(4) : a.string(2),
                              url: a.string(2),
                              width: isImage ? a.int(5) : 0, height: isImage ? a.int(6) : 0)
        }
        return Post(id: p.int(0), flags: p.int(1), authorId: p.int(2),
                    authorName: HTMLEntities.decode(p.string(3)), authorGroup: p.int(4),
                    date: Date(timeIntervalSince1970: TimeInterval(p.int(7))), bodyBB: p.string(8), avatar: p.string(9),
                    attachments: attachments, editReason: p.string(15),
                    rating: p.int(12))
    }

    static func topicSummary(_ t: PDAValue) -> TopicSummary {
        TopicSummary(id: t.int(0), title: HTMLEntities.decode(t.string(1)), flags: t.int(3),
                     lastPostDate: Date(timeIntervalSince1970: TimeInterval(t.int(5))),
                     lastPoster: HTMLEntities.decode(t.string(7)))
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
        let position = data.int(1)
        return (data.int(0), (position / postsPerPage) * postsPerPage, data.int(2))
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

    /// Поиск по сообщениям QMS (`ql`): [0, 0, запрос].
    static func qmsSearch(_ query: String) async throws -> [QMSContact] {
        qmsContacts(try await PDAClient.shared.call("ql", [0, 0, .string(query)]))
    }

    /// Диалог (`qt`): [id диалога, с какого сообщения, количество; -60 — последние 60].
    static func qmsDialog(id: Int, from: Int = 0, count: Int = -60) async throws -> QMSDialog {
        let data = try await PDAClient.shared.call("qt", [.int(id), .int(from), .int(count)])
        let messages: [QMSMessage] = data.array(13).compactMap { m in
            guard m[3]?.stringValue != nil else { return nil }
            let attachments = (m[4]?.arrayValue ?? []).map { a -> Attachment in
                let isImage = a.int(1) > 0
                return Attachment(id: a.int(0), isImage: isImage, name: isImage ? a.string(4) : a.string(2),
                                  url: a.string(2), width: a.int(5), height: a.int(6))
            }
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
                             devices: devices.map { (name: $0.0, link: $0.1, main: $0.2) }, raw: d)
    }

    enum SearchScope: Int { case all = 3, titles = 2, posts = 1 }

    /// Поиск по форуму (`rc`): [флаги, [форумы], [темы], [авторы], запрос, смещение, 20].
    static func search(_ query: String, scope: SearchScope = .all, topicId: Int? = nil, offset: Int = 0) async throws -> (total: Int, items: [SearchResult]) {
        let flags = 131072 | scope.rawValue | (topicId != nil ? 1 : 0)
        let topics: PDAValue = topicId.map { .array([.int($0)]) } ?? .array([0])
        let data = try await PDAClient.shared.call("rc", [.int(flags), .array([0]), topics, .array([0]),
                                                          .string(query), .int(offset), .int(postsPerPage)])
        let items: [SearchResult] = data.array(1).compactMap { item in
            let type = item.int(0)
            let rest = Array((item.arrayValue ?? []).dropFirst())
            let v = PDAValue.array(rest)
            if type & 1 != 0 {
                let postPart = PDAValue.array(Array(rest.dropFirst(3)))
                guard let p = post(from: postPart) else { return nil }
                return .post(topicId: v.int(1), topicTitle: HTMLEntities.decode(v.string(2)), post: p)
            }
            if type & 2 != 0 { return .topic(topicSummary(v)) }
            if type & 4 != 0 { return .article(id: v.int(0), title: HTMLEntities.decode(v.string(1))) }
            return nil
        }
        return (data.int(0), items)
    }
}
