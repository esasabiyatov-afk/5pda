import SwiftUI
import UIKit

/// Список собеседников и диалогов QMS.
struct QMSListView: View {
    @EnvironmentObject private var router: Router
    @State private var contacts: [QMSContact] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var query = ""
    @State private var alert: ActionAlert?
    @State private var newDialog = false

    var body: some View {
        LoginRequired {
            Group {
                if let e = error, contacts.isEmpty {
                    ErrorView(message: e) { Task { await reload() } }
                } else if !loaded {
                    ProgressView().task { await reload() }
                } else {
                    List {
                        if contacts.isEmpty {
                            Text("Диалогов нет").foregroundStyle(.secondary)
                        }
                        ForEach(contacts) { c in
                            Section {
                                ForEach(c.dialogs) { d in
                                    NavigationLink(value: QMSDialogRoute(id: d.id, title: "\(c.nick): \(d.title)")) {
                                        HStack {
                                            if d.unread > 0 { Circle().fill(PDATheme.unreadDot).frame(width: 9, height: 9) }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(d.title).font(.subheadline.weight(d.unread > 0 ? .semibold : .regular))
                                                Text("\(d.date.pdaFormatted) · сообщений: \(d.messageCount)")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .swipeActions {
                                        Button(role: .destructive) { Task { await delete(dialog: d) } } label: {
                                            Label("Удалить", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                NavigationLink(value: ProfileRoute(id: c.id, nick: c.nick)) {
                                    HStack(spacing: 10) {
                                        AvatarView(url: c.avatar, size: 40)
                                        VStack(alignment: .leading, spacing: 1) {
                                            HStack(spacing: 4) {
                                                if Date().timeIntervalSince(c.lastSeen) < 900 {
                                                    Circle().fill(PDATheme.online).frame(width: 7, height: 7)
                                                }
                                                Text(c.nick).font(.headline).foregroundStyle(.primary)
                                            }
                                            Text(PDAAPI.groups[c.group] ?? "").font(.caption)
                                                .foregroundStyle(PDATheme.groupColor(c.group))
                                        }
                                        Spacer()
                                        if c.unread > 0 {
                                            Text("\(c.unread)").font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                                                .background(PDATheme.unreadDot, in: Capsule()).foregroundStyle(.white)
                                        }
                                    }
                                    .textCase(nil)
                                }
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "Поиск по сообщениям")
                    .onSubmit(of: .search) { Task { await search() } }
                    .onChange(of: query) { q in if q.isEmpty { Task { await reload() } } }
                    .refreshable { await reload() }
                    .toolbar {
                        Button { newDialog = true } label: { Image(systemName: "square.and.pencil") }
                    }
                }
            }
        }
        .navigationTitle("QMS")
        .sheet(isPresented: $newDialog) {
            NewQMSDialogSheet(userId: nil, nick: nil, onDone: { newDialog = false }, onCreated: { router.push($0) })
        }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
    }

    private func reload() async {
        error = nil
        do { contacts = try await PDAAPI.qmsContacts() } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func search() async {
        guard !query.isEmpty else { return }
        do { contacts = try await PDAAPI.qmsSearch(query) } catch { alert = ActionAlert(title: "Ошибка", message: error.localizedDescription) }
    }

    private func delete(dialog: QMSDialogSummary) async {
        do { try await PDAAPI.qmsDelete(dialogId: dialog.id); await reload() } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }
}

/// Переписка в диалоге.
struct QMSDialogView: View {
    let route: QMSDialogRoute
    @EnvironmentObject private var client: PDAClient
    @State private var dialog: QMSDialog?
    @State private var error: String?
    @State private var text = ""
    @State private var sending = false
    @State private var alert: ActionAlert?
    @State private var loadingOlder = false
    @State private var reachedStart = false

    var body: some View {
        VStack(spacing: 0) {
            if let d = dialog {
                ScrollViewReader { proxy in
                    List {
                        if !reachedStart {
                            Button(loadingOlder ? "Загрузка…" : "Загрузить ранние") { Task { await loadOlder() } }
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(d.messages) { m in
                            let mine = m.authorId != d.partnerId
                            HStack {
                                if mine { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 4) {
                                    BBContentView(m.textBB, attachments: m.attachments)
                                    Text(m.date.pdaFormatted).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(mine ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 14))
                                if !mine { Spacer(minLength: 40) }
                            }
                            .listRowSeparator(.hidden)
                            .id(m.id)
                            .contextMenu {
                                Button { UIPasteboard.general.string = BBParser.plainText(m.textBB) } label: {
                                    Label("Копировать", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onAppear { if let last = d.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: d.messages.last?.id) { id in if let id = id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                Divider()
                HStack(alignment: .bottom) {
                    TextField("Сообщение", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView() } else { Image(systemName: "paperplane.fill") }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(8)
            } else if let e = error {
                ErrorView(message: e) { Task { await load() } }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(dialog?.title ?? route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let d = dialog {
                Menu {
                    NavigationLink(value: ProfileRoute(id: d.partnerId, nick: d.partnerNick)) {
                        Label("Профиль собеседника", systemImage: "person")
                    }
                    Button { Task { await load() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    Button {
                        UIPasteboard.general.string = d.messages.map { BBParser.plainText($0.textBB) }.joined(separator: "\n\n")
                    } label: { Label("Скопировать сообщения", systemImage: "doc.on.doc") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .task { if dialog == nil { await load() } }
    }

    private func load() async {
        error = nil
        do {
            let d = try await PDAAPI.qmsDialog(id: route.id)
            dialog = d
            reachedStart = d.messages.count < 60
        } catch { self.error = error.localizedDescription }
    }

    private func loadOlder() async {
        guard let d = dialog, let first = d.messages.first else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let older = try await PDAAPI.qmsDialog(id: route.id, from: first.id, count: -60)
            let known = Set(d.messages.map(\.id))
            let add = older.messages.filter { !known.contains($0.id) }
            reachedStart = add.isEmpty
            dialog = QMSDialog(title: d.title, partnerId: d.partnerId, partnerNick: d.partnerNick,
                               messages: (add + d.messages).sorted { $0.id < $1.id })
        } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await PDAAPI.qmsSend(dialogId: route.id, text: text)
            text = ""
            await load()
        } catch {
            alert = ActionAlert(title: "Ошибка", message: error.localizedDescription)
        }
    }
}

/// Создание нового диалога.
struct NewQMSDialogSheet: View {
    let userId: Int?
    let nick: String?
    let onDone: () -> Void
    var onCreated: (QMSDialogRoute) -> Void = { _ in }
    @State private var userIdText = ""
    @State private var title = ""
    @State private var message = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let nick = nick {
                    LabeledContent("Кому", value: nick)
                } else {
                    TextField("ID пользователя", text: $userIdText).keyboardType(.numberPad)
                }
                TextField("Тема диалога", text: $title)
                TextField("Сообщение", text: $message, axis: .vertical).lineLimit(4...10)
                if let e = error { Text(e).foregroundStyle(.red) }
            }
            .navigationTitle("Новый диалог")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") { Task { await create() } }
                        .disabled(sending || title.isEmpty || message.isEmpty || (userId == nil && Int(userIdText) == nil))
                }
            }
        }
    }

    private func create() async {
        guard let uid = userId ?? Int(userIdText) else { return }
        sending = true
        defer { sending = false }
        do {
            let id = try await PDAAPI.qmsCreate(userId: uid, title: title, text: message)
            onDone()
            onCreated(QMSDialogRoute(id: id, title: title))
        } catch {
            self.error = "Ошибка при создании диалога"
        }
    }
}
