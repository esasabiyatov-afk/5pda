# 5PDA

Неофициальный клиент 4PDA для iOS (SwiftUI, iOS 16+).

Работает по тому же протоколу, что и официальное Android-приложение: TLS + WebSocket к `app.4pda.to:993`,
сообщения в виде массивов в кодировке Windows-1251. Описание протокола — в [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Что уже есть
- Лента новостей и просмотр новости
- Дерево форумов, разделы, темы с постраничным просмотром постов
- Отображение BB-кода: картинки, вложения, цитаты, спойлеры, код, ссылки
- Вход по логину и паролю (ключ хранится в Keychain)
- Журнал соединения и ручная отправка команд протокола (Аккаунт → Журнал соединения)

## Сборка
GitHub Actions (`.github/workflows/build.yml`) собирает неподписанный `.ipa` на каждый push.
Готовый файл — в артефакте `5PDA-unsigned-ipa` на странице запуска. Установить его можно через Sideloadly, AltStore или TrollStore.

Локально (нужен macOS с Xcode):
```sh
brew install xcodegen
xcodegen generate
open FivePDA.xcodeproj
```

## Структура
- `Sources/Core` — протокол: кодек сообщений, WebSocket-кадры с DEFLATE, соединение, клиент, API, разбор BB-кода
- `Sources/App` — интерфейс на SwiftUI
