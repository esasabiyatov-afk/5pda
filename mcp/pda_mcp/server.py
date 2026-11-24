"""MCP-сервер 5PDA: форум 4PDA для Claude — чтение тем и новостей, поиск, QMS,
написание постов и сообщений от имени вашего аккаунта."""
from __future__ import annotations

import base64
import datetime as dt
import mimetypes
import os
import urllib.request

from mcp.server.fastmcp import FastMCP, Image

from .bbtext import to_text
from .protocol import CaptchaRequired, Client, ServerError

PER_PAGE = 20
GROUPS = {1: "Неактивированные", 2: "Гости", 3: "Пользователи", 4: "Админы", 5: "Забанен",
          7: "Активные пользователи", 8: "Друзья 4PDA", 9: "Модераторы", 10: "Супермодераторы",
          11: "Помощник модератора", 12: "FAQMakers", 13: "Почетные форумчане", 15: "Разработчики",
          16: "Роутеры", 17: "Бизнесмены", 18: "Участник спецпроекта", 19: "Школа Модераторов", 20: "Кураторы"}

mcp = FastMCP("5pda", instructions=(
    "Форум 4PDA (4pda.to) через протокол официального клиента. Тексты постов — в BB-коде 4PDA: "
    "[b], [i], [u], [s], [quote name=\"ник\" post=id]…[/quote], [spoiler=заголовок]…[/spoiler], "
    "[code], [url=…]…[/url], [img]…[/img], [list][*]…[/list], [snapback]id поста[/snapback] [b]ник[/b], — ответ. "
    "Перед отправкой поста или сообщения покажите пользователю итоговый текст и получите согласие. "
    "Соблюдайте правила форума."))
client = Client()


# ---------- вспомогательное ----------

def _date(ts: int) -> str:
    return dt.datetime.fromtimestamp(ts).strftime("%d.%m.%Y %H:%M") if ts else "—"


def _int(v, default=0) -> int:
    return v if isinstance(v, int) else default


def _s(v) -> str:
    return v if isinstance(v, str) else ""


def _err(e: Exception, messages: dict | None = None) -> str:
    if isinstance(e, ServerError):
        if messages and e.code in messages:
            return messages[e.code]
        if e.code == 3:
            return "Нет доступа (нужно войти — pda_login — или недостаточно прав)."
        if e.payload and isinstance(e.payload[0], str) and e.payload[0]:
            return f"Ошибка {e.cmd} (код {e.code}): {e.payload[0]}"
        return f"Ошибка {e.cmd}: код {e.code}"
    return f"Ошибка: {e}"


def _need_login() -> str | None:
    return None if client.logged_in else "Нужно войти: вызовите pda_login."


def _post_text(p: list, number: int | None = None, raw: bool = False) -> str:
    # [id, флаги, id автора, ник, группа, визит, репутация, дата, BB, аватар, подпись, [вложения], рейтинг, правка…]
    head = f"#{number} " if number else ""
    head += f"[пост {p[0]}] {p[3]} ({GROUPS.get(_int(p[4]), _int(p[4]))}, реп. {_int(p[6])}) — {_date(_int(p[7]))}"
    body = _s(p[8]) if raw else to_text(_s(p[8]), p[11] if len(p) > 11 else [], client.site)
    if len(p) > 15 and _s(p[15]):
        body += f"\n(изменено: {_s(p[14])}, причина: {_s(p[15])})"
    return head + "\n" + body


# ---------- вход ----------

@mcp.tool(structured_output=False)
def pda_login(login: str = "", password: str = "", captcha: int = 0, hidden: bool = False):
    """Вход в аккаунт 4PDA. Логин и пароль можно не передавать, если заданы переменные окружения
    PDA_LOGIN и PDA_PASSWORD. Если сервер просит капчу, вернётся картинка с числом, записанным
    прописью («шесть тысяч триста...») — переведите в цифры и вызовите снова с captcha=число
    (в том же сеансе). Вход сохраняется между запусками."""
    login = login or os.environ.get("PDA_LOGIN", "")
    password = password or os.environ.get("PDA_PASSWORD", "")
    if not login or not password:
        return "Нужны логин и пароль (параметры или переменные окружения PDA_LOGIN / PDA_PASSWORD)."
    try:
        client.login(login, password, captcha, hidden)
        return f"Вход выполнен: {client.nick} (id {client.member_id})."
    except CaptchaRequired as c:
        try:
            data = urllib.request.urlopen(urllib.request.Request(c.url, headers={"User-Agent": "Mozilla/5.0"}),
                                          timeout=20).read()
            return ["Нужна капча: на картинке число прописью. Вызовите pda_login ещё раз с captcha=<число цифрами>.",
                    Image(data=data, format="gif")]
        except Exception:
            return f"Нужна капча, картинка: {c.url}. Вызовите pda_login ещё раз с captcha=<число>."
    except Exception as e:
        return _err(e, {3: "Неверный логин или пароль."})


@mcp.tool()
def pda_logout() -> str:
    """Выход из аккаунта (удаляет сохранённый вход)."""
    client.logout()
    return "Выход выполнен."


@mcp.tool()
def pda_whoami() -> str:
    """Текущий пользователь и счётчики непрочитанного (QMS, избранное, упоминания)."""
    if not client.logged_in:
        return "Вход не выполнен."
    try:
        n = client.call("mn", [0, 0, 0])
        return (f"{client.nick or 'id'} (id {client.member_id}). Непрочитано: QMS {n[1]}, "
                f"избранное {n[2]}, упоминания {n[3]}.")
    except Exception as e:
        return _err(e)


# ---------- сайт ----------

@mcp.tool()
def pda_news(offset: int = 0, category_tid: int = 0) -> str:
    """Лента новостей 4PDA (по 30). category_tid: 0 — все, 6780 — обзоры, 23094 — игры."""
    try:
        d = client.call("sl", [offset, 30, -1, category_tid])
        lines = [f"[статья {n[0]}] {_date(_int(n[1]))} · {_s(n[9])} · комментариев: {_int(n[7])}" for n in d[1]]
        return "\n".join(lines) or "Пусто."
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_article(article_id: int, with_comments: bool = True) -> str:
    """Статья сайта с текстом и (по желанию) комментариями."""
    try:
        d = client.call("sa", [article_id])
        imgs = [[i[0], 1, _s(i[4]), 0, _s(i[5]) or _s(i[1])] for i in (d[11] or [])]
        out = [f"{_s(d[9])}\n{_s(d[6])}, {_date(_int(d[1]))}\n", to_text(_s(d[10]), imgs, client.site)]
        if with_comments and len(d) > 13:
            out.append(f"\nКомментарии ({len(d[13])}):")
            for c in d[13]:
                if _int(c[2]) & 2:
                    continue
                parent = f" (ответ на {c[5]})" if _int(c[5]) else ""
                out.append(f"[комм. {c[0]}]{parent} {c[4]} {_date(_int(c[1]))}: {to_text(_s(c[6]))}")
        return "\n".join(out)
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_comment(article_id: int, text: str, reply_to_comment_id: int = 0) -> str:
    """Пишет комментарий к статье сайта (от вашего имени). Перед вызовом согласуйте текст с пользователем."""
    if (m := _need_login()):
        return m
    try:
        client.call("sc", [article_id, reply_to_comment_id, text])
        return "Комментарий отправлен."
    except Exception as e:
        return _err(e, {4: "Вам запрещено комментировать.", 6: "Комментирование этой статьи окончено.",
                        8: "Достигнут кармический лимит.", 9: "Повторный комментарий.",
                        10: "Часовой лимит комментариев.", 11: "Дневной лимит комментариев.",
                        12: "Комментарий отправлен на премодерацию."})


# ---------- форум ----------

@mcp.tool()
def pda_forums() -> str:
    """Список разделов форума (категории и форумы с id)."""
    try:
        d = client.call("fi")
        out = []
        for f in d[0]:
            out.append(f"\n## {f[1]}" if _int(f[2]) & 16 else f"[форум {f[0]}] {f[1]}")
        return "\n".join(out).strip()
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_forum(forum_id: int, offset: int = 0) -> str:
    """Раздел форума: подфорумы и темы (по 30, offset — смещение)."""
    try:
        d = client.call("fs", [forum_id, offset, 30])
        out = [f"{d[2]} (тем: {d[7]})"]
        if d[6]:
            out.append("Подфорумы: " + "; ".join(f"[форум {s[0]}] {s[1]}" for s in d[6]))
        for t in d[8]:
            flags = _int(t[3])
            mark = ("📌" if flags & 1 else "") + ("🔒" if flags & 4 else "") + ("•" if flags & 32 else "")
            out.append(f"[тема {t[0]}] {mark}{t[1]}{' — ' + t[2] if _s(t[2]) else ''} · постов {t[4]} · "
                       f"последний: {t[7]} {_date(_int(t[5]))}")
        return "\n".join(out)
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_topic(topic_id: int, page: int = 0, go_to: str = "", post_id: int = 0, raw_bb: bool = False) -> str:
    """Посты темы (20 на страницу + шапка темы на первой).
    page: номер страницы с 1 (0 — первая). go_to: "unread" — к непрочитанному, "last" — в конец.
    post_id: открыть страницу с этим постом. raw_bb: вернуть тексты в исходном BB-коде (для цитирования)."""
    try:
        offset = max(0, (page - 1) * PER_PAGE) if page else 0
        if go_to or post_id:
            mode, ref = (3, post_id) if post_id else ((1 if go_to == "unread" else 2), topic_id)
            j = client.call("fj", [mode, ref, -1, 0])
            topic_id = _int(j[0]) or topic_id
            pos = _int(j[1])
            offset = 0 if pos <= 0 else ((pos - 1) // PER_PAGE) * PER_PAGE
        d = client.call("fr", [topic_id, offset, PER_PAGE, 0])
        posts = d[12]
        total = _int(d[11])
        if offset > 0 and posts and posts[0][2] == d[6] and posts[0][7] == d[5]:
            posts = posts[1:]   # шапка приходит с каждой страницей
        pages = max(1, (max(total - 1, 0) + PER_PAGE - 1) // PER_PAGE)
        flags = _int(d[4])
        out = [f"Тема {topic_id}: {d[2]}" + (f" — {d[3]}" if _s(d[3]) else ""),
               f"Страница {offset // PER_PAGE + 1} из {pages}, постов {total}"
               + ("; можно отвечать" if flags & 64 and not flags & 16 else "; ответ недоступен")]
        start = 1 if offset == 0 else offset + 2
        for i, p in enumerate(posts):
            out.append("\n" + _post_text(p, start + i, raw_bb))
        return "\n".join(out)
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_search(query: str, where: str = "all", topic_id: int = 0, author_id: int = 0, offset: int = 0) -> str:
    """Поиск по форуму. where: "all" — везде, "titles" — в названиях тем, "posts" — в сообщениях,
    "site" — по статьям сайта. topic_id — искать в теме, author_id — сообщения автора."""
    try:
        if where == "site":
            flags = 4
        else:
            flags = 131072 | {"titles": 2, "posts": 1}.get(where, 3)
            if topic_id or author_id:
                flags = 131072 | 1
        d = client.call("rc", [flags, [], [topic_id] if topic_id else [], [author_id] if author_id else [],
                               query, offset, PER_PAGE])
        out = [f"Найдено: {d[0]}"]
        for it in d[1]:
            t, rest = it[0], it[1:]
            if t & 1:
                out.append(f"\n[тема {rest[1]}] {to_text(_s(rest[2]))}\n" + _post_text(rest[3:]))
            elif t & 2:
                out.append(f"[тема {rest[0]}] {to_text(_s(rest[1]))} · постов {rest[4]}")
            elif t & 4:
                out.append(f"[статья {rest[0]}] {to_text(_s(rest[9]))}")
        return "\n".join(out)
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_upload(file_path: str) -> str:
    """Загружает файл или картинку на 4PDA. Возвращает id вложения и BB-код для вставки в пост
    ([attachment="id:имя"]); id передайте в attachment_ids при отправке поста/сообщения."""
    if (m := _need_login()):
        return m
    try:
        with open(os.path.expanduser(file_path), "rb") as f:
            data = f.read()
        name = os.path.basename(file_path)
        aid = client.upload(name, data)
        return f"Загружено: id {aid}. Вставка: [attachment=\"{aid}:{name}\"]"
    except Exception as e:
        return _err(e, {5: "Файл слишком большой.", 6: "Такой тип файла нельзя загрузить."})


@mcp.tool()
def pda_post(topic_id: int, text: str, attachment_ids: list[int] | None = None, merge_with_previous: bool = False) -> str:
    """Отправляет пост в тему от вашего имени. text — BB-код 4PDA.
    ВАЖНО: перед вызовом покажите пользователю итоговый текст и получите явное согласие.
    merge_with_previous: если ваш предыдущий пост последний в теме, сервер предлагает склеить — склеивать ли."""
    if (m := _need_login()):
        return m
    flags = 0
    for _ in range(2):
        try:
            d = client.call("fp", [topic_id, 0, flags, text, attachment_ids or []])
            pos = _int(d[1])
            return f"Пост отправлен: id {d[2]}, страница {(max(pos - 1, 0)) // PER_PAGE + 1}."
        except ServerError as e:
            if e.code == 7 and flags == 0:
                flags = 1 if merge_with_previous else 3
                continue
            return _err(e, {4: "Пост отправлен на премодерацию.", 5: "Слишком длинный пост.",
                            6: "Такой пост уже отправлен."})
        except Exception as e:
            return _err(e)
    return "Не удалось отправить."


@mcp.tool()
def pda_edit_post(topic_id: int, post_id: int, text: str, reason: str = "", attachment_ids: list[int] | None = None) -> str:
    """Редактирует ваш пост. Получите исходный текст через pda_topic(post_id=..., raw_bb=True).
    Перед вызовом согласуйте новый текст с пользователем."""
    if (m := _need_login()):
        return m
    try:
        client.call("fp", [topic_id, post_id, 0, text, attachment_ids or [], reason])
        return "Пост изменён."
    except Exception as e:
        return _err(e, {5: "Слишком длинный пост."})


@mcp.tool()
def pda_create_topic_form(forum_id: int) -> str:
    """Форма создания темы в разделе: какие поля нужно заполнить (для pda_create_topic)."""
    try:
        d = client.call("fw", [forum_id, 0, 0])
        out = []
        for i, f in enumerate(d[0]):
            opts = f"; варианты: {', '.join(f'{k+1}={o}' for k, o in enumerate(f[6]))}" \
                if _s(f[0]).lower() in ("dropdown", "checkbox_list") and len(f) > 6 else ""
            req = " (обязательно)" if _int(f[4]) & 1 else ""
            out.append(f"{i}: [{f[0]}] {f[1]}{req} — {to_text(_s(f[2]))}{opts}")
        return "\n".join(out)
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_create_topic(forum_id: int, values: list) -> str:
    """Создаёт тему. values — значения полей формы по порядку из pda_create_topic_form:
    текст для text/editor, номер варианта (с 1) для dropdown, список номеров для checkbox_list,
    список id вложений для upload_box, 0 для прочих. Перед вызовом согласуйте с пользователем."""
    if (m := _need_login()):
        return m
    try:
        d = client.call("fw", [forum_id, 0, 2, values])
        return f"Тема создана: id {d[0]}."
    except ServerError as e:
        if e.code == 5 and e.payload:
            msgs = [f"поле {i}: {m}" for i, m in enumerate(e.payload[0]) if isinstance(m, str) and m]
            return "Ошибки в форме: " + "; ".join(msgs)
        return _err(e, {3: "Сервер отказал (неверный параметр).", 4: "Тема отправлена на премодерацию."})
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_rate_post(post_id: int, positive: bool = True) -> str:
    """Оценка поста (+1 «хороший пост» или −1)."""
    if (m := _need_login()):
        return m
    try:
        client.call("fk", [post_id, 1 if positive else -1])
        return "Оценка учтена."
    except Exception as e:
        return _err(e)


# ---------- аккаунт ----------

@mcp.tool()
def pda_favorites() -> str:
    """Избранные темы и форумы (• — есть новое)."""
    if (m := _need_login()):
        return m
    try:
        d = client.call("mf", [0, 100, 0])
        out = [f"Всего: {d[0]}"]
        for f in d[1]:
            kind = "тема" if _int(f[0]) == 1 else "форум"
            mark = "• " if _int(f[4]) & 32 else ""
            last = f" · {f[8]} {_date(_int(f[9]))}" if len(f) > 9 else ""
            out.append(f"[{kind} {f[1]}] {mark}{f[2]}{last}")
        return "\n".join(out)
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_mentions(offset: int = 0) -> str:
    """Упоминания вас на форуме и сайте (ответы на ваши посты и т.п.)."""
    if (m := _need_login()):
        return m
    try:
        d = client.call("mm", [0, 0, 1, offset, PER_PAGE])
        out = [f"Всего: {d[1]}"]
        for it in d[0]:
            new = "• " if _int(it[1]) else ""
            where = f"[{'статья' if _int(it[0]) else 'тема'} {it[4]}] {it[5]}"
            out.append(f"\n{new}{where}\n" + _post_text(it[6:]))
        return "\n".join(out)
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_history() -> str:
    """Недавно посещённые темы."""
    if (m := _need_login()):
        return m
    try:
        d = client.call("mh", [0, 30])
        return "\n".join(f"[тема {t[0]}] {'• ' if _int(t[3]) & 32 else ''}{t[1]} · {t[7]} {_date(_int(t[5]))}" for t in d[1])
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_profile(user_id: int = 0) -> str:
    """Профиль пользователя (без id — ваш)."""
    uid = user_id or client.member_id
    if not uid:
        return "Укажите user_id или войдите."
    try:
        d = client.call("mi", [uid])
        return (f"{d[1]} (id {d[0]}), {GROUPS.get(_int(d[3]), d[3])}\nРегистрация: {_date(_int(d[7]))}\n"
                f"Репутация {d[17]}, тем {d[18]}, постов {d[19]}, комментариев {d[16]}\n"
                + (f"Подпись: {to_text(_s(d[5]))}\n" if _s(d[5]) else "")
                + ("Устройства: " + ", ".join(_s(x[1]) for x in d[13]) if d[13] else ""))
    except Exception as e:
        return _err(e)


# ---------- QMS ----------

@mcp.tool()
def pda_qms_contacts() -> str:
    """Собеседники QMS и их диалоги (id диалога — для pda_qms_dialog)."""
    if (m := _need_login()):
        return m
    try:
        d = client.call("ql")
        out = []
        for c in d[0]:
            out.append(f"\n{c[1]} (id {c[0]}){' — непрочитано ' + str(c[6]) if _int(c[6]) else ''}")
            for g in c[7] if len(c) > 7 else []:
                out.append(f"  [диалог {g[0]}] {g[3]} · {_date(_int(g[2]))} · сообщений {g[4]}"
                           + (" • новое" if _int(g[5]) else ""))
        return "\n".join(out).strip() or "Диалогов нет."
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_qms_dialog(dialog_id: int, count: int = 30) -> str:
    """Последние сообщения диалога QMS."""
    if (m := _need_login()):
        return m
    try:
        d = client.call("qt", [dialog_id, 0, -abs(count)])
        partner, nick = _int(d[4]), _s(d[5])
        out = [f"Диалог «{d[3]}» с {nick}"]
        for msg in sorted(d[13], key=lambda x: x[0]):
            who = nick if _int(msg[1]) == partner else "Вы"
            out.append(f"{who} {_date(_int(msg[2]))}: {to_text(_s(msg[3]), msg[4] if len(msg) > 4 else [], client.site)}")
        return "\n".join(out)
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_qms_send(dialog_id: int, text: str, attachment_ids: list[int] | None = None) -> str:
    """Отправляет сообщение в диалог QMS от вашего имени. Перед вызовом согласуйте текст с пользователем."""
    if (m := _need_login()):
        return m
    try:
        client.call("qp", [dialog_id, text, attachment_ids or []])
        return "Сообщение отправлено."
    except Exception as e:
        return _err(e)


@mcp.tool()
def pda_qms_new(user_id: int, title: str, text: str) -> str:
    """Начинает новый диалог QMS с пользователем. Перед вызовом согласуйте текст с пользователем."""
    if (m := _need_login()):
        return m
    try:
        d = client.call("qp", [0, text, [], user_id, title])
        return f"Диалог создан: id {d[0]}."
    except Exception as e:
        return _err(e)


def main():
    mcp.run()


if __name__ == "__main__":
    main()
