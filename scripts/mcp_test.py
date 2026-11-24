#!/usr/bin/env python3
"""Проверка MCP-сервера на настоящем 4PDA: запускает сервер по stdio как MCP-клиент
и вызывает инструменты чтения (ничего не отправляет на форум)."""
import asyncio, base64, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

OUT = open(sys.argv[1], "w", encoding="utf-8")

def log(s):
    # В публичный журнал — только заголовок (данные аккаунта уходят в зашифрованный файл).
    print(s.strip().splitlines()[0][:120] if s.strip() else "", flush=True)
    OUT.write(s + "\n"); OUT.flush()

async def main():
    params = StdioServerParameters(command=sys.executable, args=["-m", "pda_mcp.server"],
                                   cwd=os.path.join(os.path.dirname(__file__), "..", "mcp"),
                                   env={**os.environ, "PDA_MCP_HOME": os.environ.get("RUNNER_TEMP", "/tmp") + "/mcp"})
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = await s.list_tools()
            log(f"tools: {[t.name for t in tools.tools]}")

            async def call(name, **args):
                res = await s.call_tool(name, args)
                texts = [c.text for c in res.content if getattr(c, "type", "") == "text"]
                imgs = [c for c in res.content if getattr(c, "type", "") == "image"]
                log(f"\n===== {name} {args} =====\n" + "\n".join(texts)[:6000])
                return texts, imgs

            await call("pda_news")
            await call("pda_article", article_id=463599, with_comments=True)
            await call("pda_forums")
            await call("pda_forum", forum_id=140)
            await call("pda_topic", topic_id=1129821)
            await call("pda_topic", topic_id=117396, page=3)
            await call("pda_topic", topic_id=117396, go_to="last")
            await call("pda_search", query="iphone", where="titles")
            await call("pda_search", query="", author_id=7288972)
            await call("pda_profile", user_id=7288972)
            await call("pda_create_topic_form", forum_id=140)

            if os.environ.get("PDA_LOGIN"):
                texts, imgs = await call("pda_login")
                attempt = 0
                while imgs and attempt < 3:
                    data = base64.b64decode(imgs[0].data)
                    open("captcha.png", "wb").write(data)
                    num = wait_captcha_file(attempt)
                    if num is None:
                        break
                    texts, imgs = await call("pda_login", captcha=num)
                    attempt += 1
                await call("pda_whoami")
                await call("pda_favorites")
                await call("pda_mentions")
                await call("pda_history")
                await call("pda_qms_contacts")

def wait_captcha_file(attempt):
    """Картинка уже сохранена; публикуем её и ждём ответ, как в probe.py."""
    import subprocess, time
    run_id = os.environ.get("GITHUB_RUN_ID", "local")
    tag = f"{run_id}-{attempt}"
    subprocess.run(["gh", "release", "upload", "probe", "captcha.png", "--clobber"], check=True)
    open("captcha.txt", "w").write(tag + "\n")
    subprocess.run(["gh", "release", "upload", "probe", "captcha.txt", "--clobber"], check=True)
    log(f"капча опубликована {tag}")
    branch = os.environ.get("GITHUB_REF_NAME", "")
    deadline = time.time() + 25 * 60
    while time.time() < deadline:
        time.sleep(10)
        if subprocess.run(["git", "fetch", "-q", "origin", branch]).returncode != 0:
            continue
        r = subprocess.run(["git", "show", "FETCH_HEAD:captcha/answer.txt"], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            p = line.split()
            if len(p) == 2 and p[0] == tag and p[1].isdigit():
                return int(p[1])
    return None

asyncio.run(main())
