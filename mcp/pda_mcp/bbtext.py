"""BB-разметка 4PDA → читаемый текст для модели."""
import html
import re

_TAG = re.compile(r"\[(/?)([a-zA-Z*]+)(?:=([^\]]*))?\]")


def to_text(bb: str, attachments: list | None = None, site: str = "https://4pda.to/") -> str:
    if not bb:
        return ""
    att = {}
    for a in attachments or []:
        # [id, 1 — картинка / 0 — файл, имя, размер, адрес, ширина, высота]
        if isinstance(a, list) and len(a) > 4:
            att[str(a[0])] = (a[2], a[4] or a[2])
    s = bb.replace("\u0002", "").replace("\u0003", "")

    def abs_url(u: str) -> str:
        u = u.strip().strip('"')
        if u.startswith("//"):
            return "https:" + u
        if u.startswith("http"):
            return u
        return site + u.lstrip("/")

    s = re.sub(r"\[snapback\](\d+)\[/snapback\]", r"↩(пост \1) ", s, flags=re.I)
    s = re.sub(r'\[attachment="?(\d+):([^"\]]*)"?\]',
               lambda m: f"[вложение: {att.get(m.group(1), (m.group(2), ''))[0]} {abs_url(att[m.group(1)][1]) if m.group(1) in att else ''}]".replace(" ]", "]"),
               s, flags=re.I)
    s = re.sub(r"\[img[^\]]*\](.*?)\[/img\]", lambda m: f"[картинка: {abs_url(m.group(1))}]", s, flags=re.I | re.S)
    s = re.sub(r"\[url=([^\]]+)\](.*?)\[/url\]",
               lambda m: m.group(2) if abs_url(m.group(1)) == m.group(2) else f"{m.group(2)} ({abs_url(m.group(1))})",
               s, flags=re.I | re.S)

    def quote(m):
        arg = m.group(1) or ""
        name = re.search(r'name="([^"]*)"', arg)
        body = m.group(2).strip()
        head = f"Цитата {name.group(1)}:" if name else "Цитата:"
        return "\n" + head + "\n" + "\n".join("> " + l for l in body.splitlines()) + "\n"

    for _ in range(5):   # вложенные цитаты
        s2 = re.sub(r"\[quote([^\]]*)\]((?:(?!\[quote).)*?)\[/quote\]", quote, s, flags=re.I | re.S)
        if s2 == s:
            break
        s = s2
    s = re.sub(r"\[spoiler(?:=((?:\[[^\]]*\]|[^\]])*))?\]", lambda m: f"\n▼ Спойлер{': ' + _TAG.sub('', m.group(1)) if m.group(1) else ''}\n",
               s, flags=re.I)
    s = re.sub(r"\[/spoiler\]", "\n▲\n", s, flags=re.I)
    s = re.sub(r"\[\*\]", "\n• ", s)
    s = _TAG.sub("", s)
    s = html.unescape(s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()
