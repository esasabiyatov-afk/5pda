# 5PDA MCP — форум 4PDA в Claude

MCP-сервер, через который Claude читает форум и сайт 4PDA, ищет, пишет посты, комментарии и сообщения QMS от вашего аккаунта. Работает по тому же протоколу, что официальный клиент и приложение 5PDA.

## Подключение

Нужен [uv](https://docs.astral.sh/uv/): на macOS `brew install uv`, на Windows `winget install astral-sh.uv`.

**Claude Code:**

```
claude mcp add 5pda -- uvx --from "git+https://github.com/esasabiyatov-afk/5pda@claude/elegant-dijkstra-0b1z3x#subdirectory=mcp" 5pda-mcp
```

**Claude Desktop:** откройте «Настройки → Разработчик → Изменить конфигурацию» и добавьте в `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "5pda": {
      "command": "uvx",
      "args": ["--from", "git+https://github.com/esasabiyatov-afk/5pda@claude/elegant-dijkstra-0b1z3x#subdirectory=mcp", "5pda-mcp"]
    }
  }
}
```

Перезапустите Claude.

## Вход

Скажите Claude: «войди на 4PDA». Он спросит логин и пароль. Если не хотите писать их в чат, добавьте в конфигурацию сервера `"env": {"PDA_LOGIN": "…", "PDA_PASSWORD": "…"}`.

Если сервер попросит капчу, Claude увидит картинку с числом прописью и введёт ответ сам. Вход сохраняется в `~/.config/5pda-mcp/session.json`, повторно входить не нужно.

## Что умеет

| Инструмент | Что делает |
|---|---|
| `pda_news`, `pda_article`, `pda_comment` | Лента новостей, статья с комментариями, комментарий |
| `pda_forums`, `pda_forum` | Разделы, темы раздела |
| `pda_topic` | Посты темы: по страницам, к непрочитанному, в конец, к посту; `raw_bb` — исходный BB для цитат |
| `pda_search` | Поиск по форуму, теме, автору, сайту |
| `pda_post`, `pda_edit_post` | Новый пост, правка своего поста |
| `pda_upload` | Загрузка файла или картинки, отдаёт BB-код вложения |
| `pda_create_topic_form`, `pda_create_topic` | Создание темы по форме раздела |
| `pda_rate_post` | Оценка поста |
| `pda_favorites`, `pda_mentions`, `pda_history`, `pda_whoami` | Избранное, упоминания, история, счётчики |
| `pda_profile` | Профиль пользователя |
| `pda_qms_contacts`, `pda_qms_dialog`, `pda_qms_send`, `pda_qms_new` | QMS |

Перед отправкой поста или сообщения Claude показывает текст и ждёт вашего согласия.

## Примеры

- «Что нового в теме Fon? Ответь тем, кто спрашивал про установку»
- «Найди на 4PDA обсуждение прошивок для Redmi 6A»
- «Покажи мои упоминания и предложи ответы»
- «Прочитай последние сообщения в QMS от ГагаринЮра»
