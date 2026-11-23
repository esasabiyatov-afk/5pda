import SwiftUI

/// Проверка обновлений по source.json из последнего релиза на GitHub.
/// Новую версию можно скачать и через «Поделиться» отправить в LiveContainer, SideStore и т.п.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let build: Int
        let notes: String
        let downloadURL: URL
    }

    enum DownloadState: Equatable {
        case idle
        case downloading
        case ready(URL)
        case failed(String)
    }

    static let sourceURL = URL(string: "https://github.com/esasabiyatov-afk/5pda/releases/latest/download/source.json")!

    @Published private(set) var available: Release?
    @Published private(set) var download: DownloadState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var checking = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        lastError = nil
        do {
            var request = URLRequest(url: Self.sourceURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apps = json["apps"] as? [[String: Any]],
                  let app = apps.first(where: { ($0["bundleIdentifier"] as? String) == Bundle.main.bundleIdentifier }) ?? apps.first,
                  let latest = (app["versions"] as? [[String: Any]])?.first,
                  let version = latest["version"] as? String,
                  let urlString = latest["downloadURL"] as? String,
                  let url = URL(string: urlString) else {
                lastError = "Не удалось прочитать source.json"
                return
            }
            let build = Int(latest["buildVersion"] as? String ?? "") ?? 0
            let release = Release(version: version, build: build,
                                  notes: latest["localizedDescription"] as? String ?? "", downloadURL: url)
            available = build > currentBuild ? release : nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func downloadUpdate() async {
        guard let release = available else { return }
        download = .downloading
        do {
            let (tmp, response) = try await URLSession.shared.download(from: release.downloadURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                download = .failed("HTTP \(http.statusCode)")
                return
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("update", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("5PDA_\(release.version).ipa")
            try FileManager.default.moveItem(at: tmp, to: target)
            download = .ready(target)
        } catch {
            download = .failed(error.localizedDescription)
        }
    }
}

/// Блок обновления для экрана «Аккаунт».
struct UpdateSection: View {
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        Section {
            LabeledContent("Версия", value: "\(updater.currentVersion) (\(updater.currentBuild))")
            if let release = updater.available {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Доступна версия \(release.version)").font(.headline)
                    if !release.notes.isEmpty {
                        Text(release.notes).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                switch updater.download {
                case .idle, .failed:
                    Button("Скачать обновление") { Task { await updater.downloadUpdate() } }
                    if case .failed(let message) = updater.download {
                        Text("Ошибка загрузки: \(message)").font(.footnote).foregroundStyle(.red)
                    }
                case .downloading:
                    HStack { ProgressView(); Text("Загрузка…") }
                case .ready(let file):
                    ShareLink(item: file) {
                        Label("Установить (Поделиться → LiveContainer)", systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                Button {
                    Task { await updater.check() }
                } label: {
                    if updater.checking { ProgressView() } else { Text("Проверить обновления") }
                }
                if let error = updater.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Обновления")
        } footer: {
            Text("После загрузки нажмите «Установить» и выберите LiveContainer в меню «Поделиться».")
        }
    }
}
