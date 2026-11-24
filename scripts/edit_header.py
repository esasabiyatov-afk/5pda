#!/usr/bin/env python3
"""Правка шапки темы 5PDA: убрать мусорную строку, добавить спойлер со скриншотами.
Останавливается без изменений, если текст не совпал с ожидаемым."""
import os, re, socket, subprocess, sys, time, urllib.request
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "mcp"))
from pda_mcp.protocol import Client, CaptchaRequired, ServerError

TOPIC, POST = 1130215, 146171895
SHOTS = ["1-news.jpg", "2-article.jpg", "3-forum.jpg", "4-topic.jpg", "5-device.jpg"]
os.environ.setdefault("PDA_MCP_HOME", os.environ.get("RUNNER_TEMP", "/tmp") + "/mcp")


def pump(cl, seconds):
    """Держим соединение живым (отвечаем на ping), пока ждём ответ на капчу."""
    end = time.time() + seconds
    while time.time() < end:
        cl.conn.s.settimeout(max(0.5, end - time.time()))
        try:
            cl.conn.recv_msg()
        except (socket.timeout, TimeoutError):
            break
    cl.conn.s.settimeout(30)


def wait_captcha(cl, url, attempt):
    tag = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{attempt}"
    img = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"}), timeout=20).read()
    open("captcha.png", "wb").write(img)
    subprocess.run(["gh", "release", "upload", "probe", "captcha.png", "--clobber"], check=True)
    open("captcha.txt", "w").write(tag + "\n")
    subprocess.run(["gh", "release", "upload", "probe", "captcha.txt", "--clobber"], check=True)
    print("капча опубликована", tag, flush=True)
    branch = os.environ.get("GITHUB_REF_NAME", "")
    deadline = time.time() + 25 * 60
    while time.time() < deadline:
        pump(cl, 12)
        if subprocess.run(["git", "fetch", "-q", "origin", branch]).returncode != 0:
            continue
        r = subprocess.run(["git", "show", "FETCH_HEAD:captcha/answer.txt"], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            p = line.split()
            if len(p) == 2 and p[0] == tag and p[1].isdigit():
                return int(p[1])
    return None


cl = Client()
captcha = 0
for attempt in range(3):
    try:
        cl.login(os.environ["PDA_LOGIN"], os.environ["PDA_PASSWORD"], captcha)
        break
    except CaptchaRequired as c:
        captcha = wait_captcha(cl, c.url, attempt)
        if captcha is None:
            sys.exit("нет ответа на капчу")
print("вход выполнен", flush=True)

d = cl.call("fr", [TOPIC, 0, 20, 0])
post = d[12][0]
if post[0] != POST or post[2] != cl.member_id:
    sys.exit("шапка не та или автор не вы — ничего не меняю")
bb = post[8]
old_ids = [a[0] for a in (post[11] or [])]

if os.environ.get("MODE") == "icon":
    # Иконка приложения по центру в начале шапки.
    if "5pda-icon.png" in bb:
        sys.exit("иконка уже есть — ничего не меняю")
    shots_dir = os.path.join(os.path.dirname(__file__), "..", "docs", "screenshots")
    aid = cl.upload("5pda-icon.png", open(os.path.join(shots_dir, "0-icon.png"), "rb").read())
    new = f'[center][attachment="{aid}:5pda-icon.png"][/center]\n' + bb
    try:
        cl.call("fp", [TOPIC, POST, 0, new, old_ids + [aid], "Иконка приложения"])
    except ServerError as e:
        sys.exit(f"ошибка правки: {e} {e.payload}")
    check = cl.call("fr", [TOPIC, 0, 20, 0])[12][0]
    print("готово, иконка:", "5pda-icon.png" in check[8], "вложений:", len(check[11] or []), flush=True)
    sys.exit(0)

junk = re.compile(r"\[spoiler\]\[spoiler\]\[spoiler\]\[code\].*?\[/code\]\[/spoiler\]\[/spoiler\]\[/spoiler\]\n?", re.S)
found = junk.findall(bb)
if len(found) != 1 or "&#91;CODE&#93;" not in found[0]:
    sys.exit(f"мусорная строка найдена {len(found)} раз — ничего не меняю")
new = junk.sub("", bb)

ids = []
names = []
shots_dir = os.path.join(os.path.dirname(__file__), "..", "docs", "screenshots")
for name in SHOTS:
    data = open(os.path.join(shots_dir, name), "rb").read()
    aid = cl.upload("5pda-" + name, data)
    ids.append(aid)
    names.append("5pda-" + name)
    print("загружено", name, aid, flush=True)

shots = "[spoiler=Скриншоты]" + " ".join(f'[attachment="{i}:{n}"]' for i, n in zip(ids, names)) + "[/spoiler]\n"
marker = "[b]Поддержка:[/b]"
if new.count(marker) != 1:
    sys.exit("не найдено место для скриншотов — ничего не меняю")
new = new.replace(marker, shots + marker)

try:
    cl.call("fp", [TOPIC, POST, 0, new, old_ids + ids, "Скриншоты, убран лишний блок"])
except ServerError as e:
    sys.exit(f"ошибка правки: {e} {e.payload}")
check = cl.call("fr", [TOPIC, 0, 20, 0])[12][0][8]
print("готово, мусор удалён:", "&#91;CODE&#93;" not in check, "скриншоты:", "Скриншоты" in check, flush=True)
