#!/usr/bin/env python3
"""Вход в аккаунт (PDA_LOGIN/PDA_PASSWORD) с капчей через релиз probe;
печатает «id:ключ» в файл, переданный аргументом. Нужен для скриншотов
экранов после входа в симуляторе."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
import probe

out = sys.argv[1]
log = open(os.devnull, "w")
cl = probe.Client(log)
captcha = 0
for attempt in range(4):
    r = cl.call("ml", [os.environ["PDA_LOGIN"], os.environ["PDA_PASSWORD"], 1, captcha])
    code = r[1] if len(r) > 1 else -1
    if code == 0:
        open(out, "w").write(f"{r[2]}:{r[3]}")
        print("login ok")
        break
    if code != 4:
        print("login failed", code); sys.exit(1)
    url = r[2] if len(r) > 2 else ""
    if url.startswith("//"): url = "https:" + url
    captcha = probe.wait_captcha(cl, url, attempt)
    if captcha is None:
        print("no captcha answer"); sys.exit(1)
