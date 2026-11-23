import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var client: PDAClient
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Соединение") {
                HStack {
                    Text("Статус")
                    Spacer()
                    Text(statusText).foregroundStyle(.secondary)
                }
                NavigationLink("Журнал соединения") { DebugConsoleView() }
            }

            if client.isLoggedIn {
                Section("Аккаунт") {
                    LabeledContent("Ник", value: client.memberName)
                    LabeledContent("ID", value: String(client.memberId))
                    Button("Выйти", role: .destructive) { client.logout() }
                }
            } else {
                Section {
                    TextField("Логин или e-mail", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Пароль", text: $password)
                        .textContentType(.password)
                    Button {
                        Task { await login() }
                    } label: {
                        if busy { ProgressView() } else { Text("Войти") }
                    }
                    .disabled(busy || username.isEmpty || password.isEmpty)
                } header: {
                    Text("Вход на 4PDA")
                } footer: {
                    if let error = error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Link("Регистрация на сайте", destination: client.siteURL.appendingPathComponent("forum/index.php").appending(queryItems: [URLQueryItem(name: "act", value: "auth"), URLQueryItem(name: "action", value: "registration")]))
                }
            }

            Section {
                Text("Неофициальный клиент 4PDA для iOS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Аккаунт")
    }

    private var statusText: String {
        switch client.status {
        case .disconnected: return "не подключено"
        case .connecting: return "подключение…"
        case .connected: return "подключено"
        case .failed(let m): return "ошибка: \(m)"
        }
    }

    private func login() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await client.login(username: username, password: password)
            password = ""
        } catch let e as PDAServerError {
            error = "Не удалось войти (код \(e.code)). Проверьте логин и пароль; если сервер просит капчу, войдите один раз на сайте."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Журнал обмена с сервером и ручная отправка команд — для отладки протокола.
struct DebugConsoleView: View {
    @EnvironmentObject private var client: PDAClient
    @State private var command = "fi"
    @State private var params = ""
    @State private var result = ""

    var body: some View {
        List {
            Section("Отправить команду") {
                TextField("Команда (2 буквы)", text: $command)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Параметры, например [0,30,-1,0]", text: $params)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button("Отправить") { Task { await send() } }
                    .disabled(command.count != 2)
                if !result.isEmpty {
                    ScrollView(.horizontal) {
                        Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    .frame(maxHeight: 300)
                    ShareLink(item: result)
                }
            }
            Section {
                ForEach(client.log.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((entry.outgoing ? "→ " : "← ") + entry.date.formatted(date: .omitted, time: .standard))
                            .font(.caption2).foregroundStyle(entry.outgoing ? .blue : .green)
                        Text(entry.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            } header: {
                HStack {
                    Text("Журнал")
                    Spacer()
                    ShareLink(item: client.log.map { ($0.outgoing ? "→ " : "← ") + $0.text }.joined(separator: "\n"))
                    Button("Очистить") { client.clearLog() }
                }
            }
        }
        .navigationTitle("Журнал")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() async {
        var list: [PDAValue] = []
        let trimmed = params.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let source = trimmed.hasPrefix("[") ? trimmed : "[\(trimmed)]"
            guard let data = source.data(using: .windowsCP1251), let parsed = try? PDACodec.decode(data),
                  let arr = parsed.arrayValue else {
                result = "Не удалось разобрать параметры"
                return
            }
            list = arr
        }
        do {
            let value = try await client.call(command, list)
            result = value.pretty()
        } catch {
            result = "Ошибка: \(error.localizedDescription)"
        }
    }
}
