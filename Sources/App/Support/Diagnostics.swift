import SwiftUI
import UIKit

/// Прогоняет все основные команды и сохраняет сырые ответы сервера в файл —
/// по нему видно, какие поля разобраны неправильно.
@MainActor
final class Diagnostics: ObservableObject {
    @Published var running = false
    @Published var progress = ""
    @Published var fileURL: URL?

    private var out = ""

    func run(includeQMS: Bool) async {
        running = true
        fileURL = nil
        out = ""
        defer { running = false }
        let client = PDAClient.shared
        let info = Bundle.main.infoDictionary
        line("5PDA \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))")
        line("iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
        line("Дата: \(Date())")
        line("Вход: \(client.isLoggedIn ? "да, id \(client.memberId)" : "нет")")
        line("")

        let news = await step("Новости", "sl", [0, 30, -1, 0])
        let articleId = news?.array(1).first?.int(0) ?? 0
        if articleId > 0 { _ = await step("Статья", "sa", [.int(articleId)]) }

        let forums = await step("Список форумов", "fi", [])
        // Первый настоящий раздел (не категория).
        let forumId = forums?.array(0).first(where: { $0.int(2) & 16 == 0 })?.int(0) ?? 0
        var topicId = 0
        if forumId > 0 {
            let forum = await step("Раздел \(forumId)", "fs", [.int(forumId), 0, 30])
            topicId = forum?.array(8).first(where: { $0.int(3) & 16 == 0 })?.int(0) ?? 0
        }
        if topicId > 0 {
            _ = await step("Тема \(topicId)", "fr", [.int(topicId), 0, 20, 0])
            _ = await step("Переход к непрочитанному", "fj", [1, .int(topicId), -1, 0])
        }
        _ = await step("Поиск «iphone»", "rc", [.int(131072 | 3), [], [], [], "iphone", 0, 20])

        if client.isLoggedIn {
            _ = await step("Избранное", "mf", [0, 30, 0])
            _ = await step("История", "mh", [0, 30])
            _ = await step("Упоминания", "mm", [0, 0, 1, 0, 20])
            _ = await step("Мой профиль", "mi", [.int(client.memberId)])
            if includeQMS {
                let qms = await step("QMS: контакты", "ql", [])
                if let dialog = qms?.array(0).first?.array(7).first?.int(0), dialog > 0 {
                    _ = await step("QMS: диалог", "qt", [.int(dialog), 0, 60])
                }
            }
        } else {
            line("(Вход не выполнен — избранное, история, упоминания и QMS пропущены)")
        }

        line("")
        line("===== Журнал соединения =====")
        for e in client.log { line((e.outgoing ? "→ " : "← ") + e.text) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("5pda-diagnostics.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        fileURL = url
        progress = "Готово"
    }

    private func step(_ title: String, _ cmd: String, _ params: [PDAValue]) async -> PDAValue? {
        progress = title
        line("===== \(title): \(cmd) \(PDAValue.array(params).description) =====")
        do {
            let v = try await PDAClient.shared.call(cmd, params, timeout: 25)
            var text = v.pretty()
            if text.count > 80_000 { text = String(text.prefix(80_000)) + "\n…(обрезано)" }
            line(text)
            line("")
            return v
        } catch {
            line("ОШИБКА: \(error.localizedDescription)")
            if let p = PDAClient.shared.lastErrorPayload { line("Данные ошибки: \(p.description)") }
            line("")
            return nil
        }
    }

    private func line(_ s: String) { out += s + "\n" }
}

struct DiagnosticsView: View {
    @StateObject private var diag = Diagnostics()
    @State private var includeQMS = false

    var body: some View {
        List {
            Section {
                Text("Приложение по очереди откроет новости, форум, тему, поиск, избранное, историю, упоминания и профиль и сохранит ответы сервера в файл. Отправьте файл разработчику — по нему видно, что отображается неправильно.")
                    .font(.footnote)
                Toggle("Включить QMS (ваши личные сообщения)", isOn: $includeQMS)
            }
            Section {
                Button {
                    Task { await diag.run(includeQMS: includeQMS) }
                } label: {
                    HStack {
                        Label("Запустить диагностику", systemImage: "stethoscope")
                        if diag.running { Spacer(); ProgressView() }
                    }
                }
                .disabled(diag.running)
                if !diag.progress.isEmpty {
                    Text(diag.running ? "Проверяю: \(diag.progress)…" : diag.progress)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let url = diag.fileURL, !diag.running {
                    ShareLink(item: url) { Label("Отправить файл", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Отчёт об ошибке по встряхиванию

extension Notification.Name {
    static let deviceShaken = Notification.Name("5pda.deviceShaken")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceShaken, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

enum ScreenCapture {
    @MainActor static func keyWindowImage() -> UIImage? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let w = window else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: w.bounds)
        return renderer.image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: false) }
    }
}

struct BugReport: Identifiable {
    let id = UUID()
    let screenshot: UIImage?
}

struct BugReportSheet: View {
    let report: BugReport
    let onDone: () -> Void
    @State private var comment = ""
    @State private var files: [URL] = []

    var body: some View {
        NavigationStack {
            Form {
                if let img = report.screenshot {
                    Section("Снимок экрана") {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 260)
                            .frame(maxWidth: .infinity)
                    }
                }
                Section("Что не так? (необязательно)") {
                    TextField("Например: не грузится, пусто, криво", text: $comment, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    if files.isEmpty {
                        Button("Подготовить отчёт") { prepare() }
                    } else {
                        ShareLink(items: files) { Label("Отправить отчёт", systemImage: "square.and.arrow.up") }
                    }
                } footer: {
                    Text("В отчёт попадут снимок экрана и последние ответы сервера.")
                }
            }
            .navigationTitle("Сообщить об ошибке")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть", action: onDone) } }
            .onChange(of: comment) { _ in files = [] }
        }
    }

    private func prepare() {
        let dir = FileManager.default.temporaryDirectory
        var result: [URL] = []
        let stamp = Int(Date().timeIntervalSince1970)
        if let img = report.screenshot, let data = img.pngData() {
            let u = dir.appendingPathComponent("5pda-screen-\(stamp).png")
            try? data.write(to: u); result.append(u)
        }
        let info = Bundle.main.infoDictionary
        var text = "5PDA \(info?["CFBundleShortVersionString"] ?? "?"), iOS \(UIDevice.current.systemVersion)\n"
        text += "Комментарий: \(comment)\n\n===== Журнал =====\n"
        for e in PDAClient.shared.log { text += (e.outgoing ? "→ " : "← ") + e.text + "\n" }
        let t = dir.appendingPathComponent("5pda-log-\(stamp).txt")
        try? text.write(to: t, atomically: true, encoding: .utf8)
        result.append(t)
        files = result
    }
}

/// Подключает отчёт по встряхиванию к корневому экрану.
struct ShakeToReport: ViewModifier {
    @State private var report: BugReport?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deviceShaken)) { _ in
                guard report == nil else { return }
                report = BugReport(screenshot: ScreenCapture.keyWindowImage())
            }
            .sheet(item: $report) { r in BugReportSheet(report: r) { report = nil } }
    }
}
