import SwiftUI

/// Что редактируем: новый пост или правку.
struct ComposerState: Identifiable {
    let id = UUID()
    let topicId: Int
    var postId: Int = 0
    let title: String
    var text: String = ""
    var editReason: String = ""
}

/// Редактор поста с панелью BB-кодов.
struct PostComposer: View {
    let state: ComposerState
    /// nil — отменено/нужно просто обновить.
    let onFinish: (PDAAPI.SentPost?) -> Void

    @State private var text: String
    @State private var reason: String
    @State private var sending = false
    @State private var error: String?
    @State private var askMerge = false
    @State private var preview = false
    @FocusState private var focused: Bool

    init(state: ComposerState, onFinish: @escaping (PDAAPI.SentPost?) -> Void) {
        self.state = state
        self.onFinish = onFinish
        _text = State(initialValue: state.text)
        _reason = State(initialValue: state.editReason)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BBToolbar(text: $text)
                Divider()
                if preview {
                    ScrollView { BBContentView(text).padding() }
                } else {
                    TextEditor(text: $text)
                        .focused($focused)
                        .padding(.horizontal, 8)
                }
                if state.postId != 0 {
                    Divider()
                    TextField("Причина редактирования", text: $reason)
                        .padding()
                }
                if let e = error {
                    Text(e).font(.footnote).foregroundStyle(.red).padding(8)
                }
            }
            .navigationTitle(state.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { onFinish(nil) }
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $preview) {
                        Text("Текст").tag(false)
                        Text("Просмотр").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Отправить") { Task { await send(flags: 0) } }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .confirmationDialog("Прикрепить этот пост к предыдущему?", isPresented: $askMerge, titleVisibility: .visible) {
                Button("Да") { Task { await send(flags: 1) } }
                Button("Нет, отдельным постом") { Task { await send(flags: 3) } }
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(!text.isEmpty && text != state.text)
    }

    private func send(flags: Int) async {
        sending = true
        defer { sending = false }
        error = nil
        do {
            let sent = try await PDAAPI.sendPost(topicId: state.topicId, postId: state.postId, text: text,
                                                 editReason: state.postId != 0 ? reason : nil, flags: flags)
            onFinish(sent)
        } catch is PDAAPI.MergeQuestion {
            askMerge = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Панель быстрой вставки BB-кодов.
struct BBToolbar: View {
    @Binding var text: String

    private let tags: [(label: String, open: String, close: String)] = [
        ("B", "[B]", "[/B]"), ("I", "[I]", "[/I]"), ("U", "[U]", "[/U]"), ("S", "[S]", "[/S]"),
        ("Цитата", "[QUOTE]", "[/QUOTE]"), ("Спойлер", "[SPOILER]", "[/SPOILER]"),
        ("Код", "[CODE]", "[/CODE]"), ("Ссылка", "[URL=]", "[/URL]"), ("Картинка", "[IMG]", "[/IMG]"),
        ("Оффтоп", "[OFFTOP]", "[/OFFTOP]"), ("Список", "[LIST]\n[*]", "\n[/LIST]"),
        ("Центр", "[CENTER]", "[/CENTER]"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.label) { tag in
                    Button(tag.label) { text += tag.open + tag.close }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}
