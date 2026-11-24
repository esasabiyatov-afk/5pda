import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

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
    @StateObject private var editor = BBEditorController()
    @StateObject private var attach = AttachmentUploader()
    @AppStorage("tags_below") private var tagsBelow = false

    init(state: ComposerState, onFinish: @escaping (PDAAPI.SentPost?) -> Void) {
        self.state = state
        self.onFinish = onFinish
        _text = State(initialValue: state.text)
        _reason = State(initialValue: state.editReason)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !tagsBelow { BBToolbar(controller: editor); Divider() }
                if preview {
                    ScrollView { BBContentView(text).padding() }
                } else {
                    BBTextView(text: $text, controller: editor)
                }
                if tagsBelow { Divider(); BBToolbar(controller: editor) }
                AttachmentBar(uploader: attach, editor: editor)
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
                    // Как в Android: «глаз» — предпросмотр, без широкого переключателя,
                    // который на узких экранах налезал на кнопки.
                    Button { preview.toggle() } label: {
                        Image(systemName: preview ? "pencil" : "eye")
                    }
                    .accessibilityLabel(preview ? "Редактировать" : "Предпросмотр")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button { Task { await send(flags: 0) } } label: { Image(systemName: "paperplane.fill") }
                            .accessibilityLabel("Отправить")
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .confirmationDialog("Прикрепить этот пост к предыдущему?", isPresented: $askMerge, titleVisibility: .visible) {
                Button("Да") { Task { await send(flags: 1) } }
                Button("Нет, отдельным постом") { Task { await send(flags: 3) } }
            }
        }
        .interactiveDismissDisabled(!text.isEmpty && text != state.text)
    }

    private func send(flags: Int) async {
        sending = true
        defer { sending = false }
        error = nil
        do {
            let sent = try await PDAAPI.sendPost(topicId: state.topicId, postId: state.postId, text: text,
                                                 attachments: attach.items.compactMap(\.id),
                                                 editReason: state.postId != 0 ? reason : nil, flags: flags)
            onFinish(sent)
        } catch is PDAAPI.MergeQuestion {
            askMerge = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Поле ввода с подсветкой BB-разметки и вставкой тегов у курсора (как в Android-клиенте).
final class BBEditorController: ObservableObject {
    weak var textView: UITextView?

    /// Оборачивает выделение тегами; без выделения ставит курсор между ними.
    func wrap(_ open: String, _ close: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        let ns = tv.text as NSString
        let selected = ns.substring(with: range)
        let insert = open + selected + close
        tv.textStorage.replaceCharacters(in: range, with: insert)
        let cursor = selected.isEmpty ? range.location + (open as NSString).length : range.location + (insert as NSString).length
        tv.selectedRange = NSRange(location: cursor, length: 0)
        tv.delegate?.textViewDidChange?(tv)
    }

    func insert(_ text: String) { wrap(text, "") }

    /// Убирает теги из выделения (или из всего текста).
    func clearTags() {
        guard let tv = textView else { return }
        var range = tv.selectedRange
        if range.length == 0 { range = NSRange(location: 0, length: (tv.text as NSString).length) }
        let ns = tv.text as NSString
        let cleaned = ns.substring(with: range).replacingOccurrences(of: #"\[/?[a-zA-Z*]+(=[^\]]*)?\]"#, with: "", options: .regularExpression)
        tv.textStorage.replaceCharacters(in: range, with: cleaned)
        tv.selectedRange = NSRange(location: range.location, length: (cleaned as NSString).length)
        tv.delegate?.textViewDidChange?(tv)
    }
}

struct BBTextView: UIViewRepresentable {
    @Binding var text: String
    let controller: BBEditorController
    var autoFocus = true

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = .preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        tv.text = text
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        controller.textView = tv
        Self.highlight(tv)
        if autoFocus { DispatchQueue.main.async { tv.becomeFirstResponder() } }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text {
            tv.text = text
            Self.highlight(tv)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: BBTextView
        init(_ p: BBTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            BBTextView.highlight(tv)
        }
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"\[/?[a-zA-Z*]+(=[^\]\n]*)?\]"#)

    /// Подсветка разметки — теги синим, как в Android-клиенте.
    static func highlight(_ tv: UITextView) {
        let storage = tv.textStorage
        let full = NSRange(location: 0, length: storage.length)
        let selected = tv.selectedRange
        storage.beginEditing()
        storage.setAttributes([.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label], range: full)
        for m in tagRegex.matches(in: storage.string, range: full) {
            storage.addAttribute(.foregroundColor, value: UIColor.systemIndigo, range: m.range)
        }
        storage.endEditing()
        tv.selectedRange = selected
    }
}

/// Панель тегов в порядке Android-клиента.
struct BBToolbar: View {
    @ObservedObject var controller: BBEditorController
    @State private var askLink = false
    @State private var linkURL = ""
    @State private var askSpoiler = false
    @State private var spoilerTitle = ""
    @State private var showSmiles = false

    private struct Tag: Identifiable { let id: String; let icon: String; let open: String; let close: String }
    private let simple: [Tag] = [
        Tag(id: "B", icon: "bold", open: "[B]", close: "[/B]"),
        Tag(id: "I", icon: "italic", open: "[I]", close: "[/I]"),
        Tag(id: "U", icon: "underline", open: "[U]", close: "[/U]"),
        Tag(id: "S", icon: "strikethrough", open: "[S]", close: "[/S]"),
    ]
    private let colors = ["red", "orange", "green", "blue", "purple", "gray", "royalblue", "darkred"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                button("face.smiling") { showSmiles = true }
                ForEach(simple) { t in button(t.icon) { controller.wrap(t.open, t.close) } }
                Menu {
                    ForEach(1...7, id: \.self) { n in Button("Размер \(n)") { controller.wrap("[SIZE=\(n)]", "[/SIZE]") } }
                } label: { icon("textformat.size") }
                Menu {
                    ForEach(colors, id: \.self) { c in Button(c) { controller.wrap("[COLOR=\(c)]", "[/COLOR]") } }
                } label: { icon("paintbrush.pointed") }
                button("link") { linkURL = ""; askLink = true }
                button("list.bullet") { controller.wrap("[LIST]\n[*]", "\n[/LIST]") }
                button("list.number") { controller.wrap("[LIST=1]\n[*]", "\n[/LIST]") }
                button("quote.opening") { controller.wrap("[QUOTE]", "[/QUOTE]") }
                button("eye.slash") { controller.wrap("[SPOILER]", "[/SPOILER]") }
                button("text.badge.star") { spoilerTitle = ""; askSpoiler = true }
                button("chevron.left.forwardslash.chevron.right") { controller.wrap("[CODE]", "[/CODE]") }
                button("text.alignleft") { controller.wrap("[LEFT]", "[/LEFT]") }
                button("text.aligncenter") { controller.wrap("[CENTER]", "[/CENTER]") }
                button("text.alignright") { controller.wrap("[RIGHT]", "[/RIGHT]") }
                button("textformat.subscript") { controller.wrap("[SUB]", "[/SUB]") }
                button("textformat.superscript") { controller.wrap("[SUP]", "[/SUP]") }
                button("bubble.left") { controller.wrap("[OFFTOP]", "[/OFFTOP]") }
                button("lock") { controller.wrap("[HIDE]", "[/HIDE]") }
                button("photo") { controller.wrap("[IMG]", "[/IMG]") }
                button("eraser") { controller.clearTags() }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 44)
        .sheet(isPresented: $showSmiles) {
            SmilePicker { code in
                controller.insert(" \(code) ")
                showSmiles = false
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Ссылка", isPresented: $askLink) {
            TextField("https://", text: $linkURL).textInputAutocapitalization(.never).keyboardType(.URL)
            Button("Вставить") { controller.wrap("[URL=\(linkURL)]", "[/URL]") }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Спойлер с заголовком", isPresented: $askSpoiler) {
            TextField("Заголовок", text: $spoilerTitle)
            Button("Вставить") { controller.wrap("[SPOILER=\(spoilerTitle)]", "[/SPOILER]") }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17)).frame(width: 40, height: 40)
    }

    private func button(_ name: String, action: @escaping () -> Void) -> some View {
        // borderless: внутри Form/List иначе одно нажатие срабатывает на все кнопки строки.
        Button(action: action) { icon(name) }.buttonStyle(.borderless).foregroundStyle(.primary)
    }
}

/// Выбор смайла.
struct SmilePicker: View {
    let onPick: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 10) {
                ForEach(Smilies.picker, id: \.img) { s in
                    Button { onPick(s.code) } label: {
                        VStack(spacing: 2) {
                            if let img = Smilies.image(s.img) {
                                Image(uiImage: img).interpolation(.none)
                                    .resizable().scaledToFit()
                                    .frame(width: min(CGFloat(s.w) * 1.4, 52), height: min(CGFloat(s.h) * 1.4, 40))
                            }
                            Text(s.code).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

/// Загрузка вложений для поста/сообщения.
@MainActor
final class AttachmentUploader: ObservableObject {
    struct Item: Identifiable {
        let localId = UUID()
        var id: Int?
        let name: String
        var failed: String?
        var identity: UUID { localId }
    }
    @Published var items: [Item] = []

    /// false — только загрузить (поле формы), не вставлять тег в текст.
    var insertsTag = true

    func upload(name: String, data: Data, editor: BBEditorController) {
        let item = Item(id: nil, name: name)
        items.append(item)
        Task {
            do {
                let id = try await PDAAPI.uploadAttachment(name: name, data: data)
                if let i = items.firstIndex(where: { $0.localId == item.localId }) { items[i].id = id }
                if insertsTag { editor.insert("[attachment=\"\(id):\(name)\"]") }
            } catch {
                if let i = items.firstIndex(where: { $0.localId == item.localId }) { items[i].failed = error.localizedDescription }
            }
        }
    }
}

struct AttachmentBar: View {
    @ObservedObject var uploader: AttachmentUploader
    let editor: BBEditorController
    @State private var photo: PhotosPickerItem?
    @State private var importing = false

    var body: some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $photo, matching: .images) {
                Image(systemName: "photo.badge.plus").font(.title3)
            }
            Button { importing = true } label: { Image(systemName: "paperclip").font(.title3) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(uploader.items, id: \.localId) { item in
                        HStack(spacing: 4) {
                            if item.id == nil && item.failed == nil { ProgressView().scaleEffect(0.7) }
                            if item.failed != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.red) }
                            Text(item.name).font(.caption).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .help(item.failed ?? "")
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .onChange(of: photo) { item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) ?? data
                    let name = "IMG_\(Int(Date().timeIntervalSince1970)).jpg"
                    uploader.upload(name: name, data: jpeg, editor: editor)
                }
                photo = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                uploader.upload(name: url.lastPathComponent, data: data, editor: editor)
            }
        }
    }
}
