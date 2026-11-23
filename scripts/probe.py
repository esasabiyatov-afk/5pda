#!/usr/bin/env python3
"""Проверка протокола 4PDA на настоящем сервере: подключается так же, как
приложение, выполняет набор команд и сохраняет сырые ответы с индексами полей.

Использование: probe.py OUT_DIR   (логин/пароль — в PDA_LOGIN / PDA_PASSWORD, необязательно)
"""
import json, os, socket, ssl, struct, sys, time, urllib.request, zlib

PROTO_VERSION = "1.9.43"
CLIENT = "5pda-ios"

# ---------- кодек ----------

def enc(v):
    if isinstance(v, bool):
        v = int(v)
    if isinstance(v, int):
        return str(v).encode()
    if isinstance(v, str):
        out = bytearray(b'"')
        for ch in v:
            if ch == "\\": out += b"\\\\"
            elif ch == '"': out += b'\\"'
            elif ch == "\n": out += b"\\n"
            elif ch == "\r": out += b"\\r"
            elif ch == "\t": out += b"\\t"
            else:
                try:
                    out += ch.encode("cp1251")
                except UnicodeEncodeError:
                    out += f"&#{ord(ch)};".encode()
        return bytes(out + b'"')
    if isinstance(v, list):
        return b"[" + b",".join(enc(x) for x in v) + b"]"
    raise TypeError(v)

def dec(b):
    pos = 0
    def ws():
        nonlocal pos
        while pos < len(b) and b[pos] in b" \r\n\t": pos += 1
    def val():
        nonlocal pos
        ws()
        c = b[pos]
        if c == 0x5B:
            pos += 1; items = []; ws()
            if b[pos] == 0x5D: pos += 1; return items
            while True:
                items.append(val()); ws()
                if b[pos] == 0x2C: pos += 1; continue
                if b[pos] == 0x5D: pos += 1; return items
                raise ValueError(f"bad array at {pos}")
        if c == 0x22:
            pos += 1; chunk = bytearray(); res = ""
            while True:
                c = b[pos]; pos += 1
                if c == 0x22:
                    return res + chunk.decode("cp1251", "replace")
                if c != 0x5C: chunk.append(c); continue
                e = b[pos]; pos += 1
                m = {0x6E: 10, 0x72: 13, 0x74: 9, 0x66: 12, 0x62: 8}
                if e in m: chunk.append(m[e])
                elif e == 0x75:
                    res += chunk.decode("cp1251", "replace"); chunk = bytearray()
                    res += chr(int(b[pos:pos+4], 16)); pos += 4
                else: chunk.append(e)
        start = pos
        if c == 0x2D: pos += 1
        while pos < len(b) and 0x30 <= b[pos] <= 0x39: pos += 1
        return int(b[start:pos])
    return val()

def pretty(v, ind=0):
    pad = "  " * ind
    if isinstance(v, list):
        if not v: return "[]"
        s = "[\n"
        for i, x in enumerate(v):
            s += f"{pad}  {i}: {pretty(x, ind+1)}\n"
        return s + pad + "]"
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    return str(v)

# ---------- транспорт ----------

class Conn:
    def __init__(self, host, port, ws_host=None):
        raw = socket.create_connection((host, port), timeout=20)
        if ws_host:
            ctx = ssl.create_default_context()
            raw = ctx.wrap_socket(raw, server_hostname=ws_host)
            req = (f"GET /ws/ HTTP/1.1\r\nHost: {ws_host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
                   "Sec-WebSocket-Protocol: app\r\n\r\n")
            raw.sendall(req.encode())
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = raw.recv(4096)
                if not chunk: raise IOError("closed during handshake")
                head += chunk
            hdr, _, rest = head.partition(b"\r\n\r\n")
            if b" 101" not in hdr.split(b"\r\n")[0]:
                raise IOError("handshake: " + hdr.decode(errors="replace"))
            self.buf = rest
        else:
            self.buf = b""
        self.s = raw
        self.inflater = zlib.decompressobj(-15)

    def send_msg(self, payload):
        comp = zlib.compressobj(6, zlib.DEFLATED, -15)
        body = comp.compress(payload) + comp.flush(zlib.Z_SYNC_FLUSH)
        if body.endswith(b"\x00\x00\xff\xff"): body = body[:-4]
        body = struct.pack("<I", len(payload)) + body
        hdr = bytes([0x80 | 0x40 | 1])
        n = len(body)
        if n <= 125: hdr += bytes([n])
        elif n <= 0xFFFF: hdr += bytes([126]) + struct.pack(">H", n)
        else: hdr += bytes([127]) + struct.pack(">Q", n)
        self.s.sendall(hdr + body)

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk: raise IOError("connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            self.s.settimeout(max(0.5, end - time.time()))
            try:
                self.recv_msg()
            except (socket.timeout, TimeoutError):
                break
            except ssl.SSLError:
                break
        self.s.settimeout(20)

    def recv_msg(self):
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126: n = struct.unpack(">H", self._read(2))[0]
            elif n == 127: n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            data = self._read(n)
            if mask: data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
            op = b0 & 0x0F
            if op == 9:
                self.s.sendall(bytes([0x8A, len(data)]) + data); continue
            if op == 8: raise IOError("server closed")
            if b0 & 0x40:
                size = struct.unpack("<I", data[:4])[0]
                data = self.inflater.decompress(data[4:] + b"\x00\x00\xff\xff")[:size]
            return data

class Client:
    def __init__(self, out):
        self.out = out
        self.next_id = 1
        prov = None
        for url in ("https://gist.githubusercontent.com/aigilea/152b043823de7cfeacd06f348b78ec25/raw/provision.json",
                    "https://provision.app.devapps.ru/"):
            try:
                prov = json.loads(urllib.request.urlopen(url, timeout=15).read())
                break
            except Exception as e:
                self.log(f"provision {url}: {e}")
        prov = prov or {"d": "app.4pda.to:993", "w": "app.4pda.ru"}
        self.log(f"provision: {prov}")
        host, port = prov["d"].rsplit(":", 1)
        try:
            self.c = Conn(host, int(port))
            self.log(f"TCP {host}:{port} подключено")
            self.hello()
        except Exception as e:
            self.log(f"TCP не удалось ({e}), пробую WSS {prov['w']}:443")
            self.c = Conn(prov["w"], 443, prov["w"])
            self.hello()

    def log(self, s):
        print(s, flush=True)
        self.out.write(s + "\n"); self.out.flush()

    def hello(self):
        r = self.call("ah", [PROTO_VERSION, "", CLIENT, 1, 0])
        self.log(f"ah → {r}")

    def call(self, cmd, params):
        rid = self.next_id; self.next_id += 1
        self.c.send_msg(enc([rid, cmd] + params))
        deadline = time.time() + 30
        while time.time() < deadline:
            msg = dec(self.c.recv_msg())
            if isinstance(msg, list) and msg and (msg[0] & 0x0FFFFFFF) == rid:
                return msg
            if isinstance(msg, list) and msg and msg[0] == 0 and len(msg) > 1 and msg[1] != 0:
                return msg
            self.log(f"(посторонний ответ: {str(msg)[:200]})")
        raise TimeoutError(cmd)

def wait_captcha(cl, url, attempt):
    """Публикует картинку капчи и ждёт ответ в файле captcha/answer.txt ветки
    (строка «<run_id>-<попытка> <число>»). Соединение всё это время открыто."""
    import subprocess
    run_id = os.environ.get("GITHUB_RUN_ID", "local")
    tag = f"{run_id}-{attempt}"
    try:
        img = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"}), timeout=20).read()
        open("captcha.png", "wb").write(img)
        subprocess.run(["gh", "release", "upload", "probe", "captcha.png", "--clobber"], check=True)
        open("captcha.txt", "w").write(tag + "\n")
        subprocess.run(["gh", "release", "upload", "probe", "captcha.txt", "--clobber"], check=True)
        cl.log(f"капча опубликована, жду ответ {tag}")
    except Exception as e:
        cl.log(f"не удалось опубликовать капчу: {e}")
        return None
    branch = os.environ.get("GITHUB_REF_NAME", "")
    deadline = time.time() + 25 * 60
    while time.time() < deadline:
        cl.c.pump(15)  # отвечаем на ping сервера, чтобы соединение не закрылось
        r = subprocess.run(["git", "fetch", "-q", "origin", branch], capture_output=True)
        if r.returncode != 0: continue
        r = subprocess.run(["git", "show", "FETCH_HEAD:captcha/answer.txt"], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == tag and parts[1].isdigit():
                cl.log(f"получен ответ на капчу")
                return int(parts[1])
    return None

def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "probe"
    os.makedirs(out_dir, exist_ok=True)
    summary = open(os.path.join(out_dir, "00-summary.txt"), "w", encoding="utf-8")
    cl = Client(summary)
    results = {}
    n = [0]

    def run(name, cmd, params):
        n[0] += 1
        try:
            r = cl.call(cmd, params)
        except Exception as e:
            cl.log(f"{cmd} {params}: ОШИБКА {e}")
            return None
        code = r[1] if len(r) > 1 else None
        data = r[2:]
        cl.log(f"{cmd} {enc(params).decode('cp1251')}: код {code}, полей {len(data)}")
        fn = os.path.join(out_dir, f"{n[0]:02d}-{cmd}-{name}.txt")
        with open(fn, "w", encoding="utf-8") as f:
            f.write(f"{cmd} {enc(params).decode('cp1251')}\nкод {code}\n\n{pretty(data)}\n")
        results[name] = data
        return data if code == 0 else None

    login, pw = os.environ.get("PDA_LOGIN"), os.environ.get("PDA_PASSWORD")
    me = 0
    if login and pw:
        captcha = 0
        for attempt in range(4):
            r = cl.call("ml", [login, pw, 1, captcha])
            code = r[1] if len(r) > 1 else -1
            if code == 0:
                me = r[2]; cl.log(f"вход выполнен, id {me}"); break
            if code != 4:
                cl.log(f"вход не удался, код {code}"); break
            url = r[2] if len(r) > 2 else ""
            if url.startswith("//"): url = "https:" + url
            cl.log(f"нужна капча: {url}")
            captcha = wait_captcha(cl, url, attempt)
            if captcha is None:
                cl.log("ответ на капчу не получен"); break

    news = run("news", "sl", [0, 30, -1, 0])
    for cat in (1, 2, 3, 4):
        run(f"news-cat{cat}", "sl", [0, 5, -1, cat])
    if news and news[1]:
        run("article", "sa", [news[1][0][0]])
        # статья с наибольшим числом комментариев
        best = max(news[1], key=lambda x: x[7] if len(x) > 7 and isinstance(x[7], int) else 0)
        run("article-comments", "sa", [best[0]])
    forums = run("forums", "fi", [])
    forum_ids = []
    if forums:
        forum_ids = [f[0] for f in forums[0] if isinstance(f, list) and not (f[2] & 16)]
    topic_ids = []
    for fid in forum_ids[:3]:
        d = run(f"forum-{fid}", "fs", [fid, 0, 30])
        if d and len(d) > 8:
            topic_ids += [t[0] for t in d[8] if isinstance(t, list)][:3]
    # большой раздел с подразделами — «Apple iPhone» и т.п.: берём раздел с наибольшим числом тем
    for tid in topic_ids[:4]:
        d = run(f"topic-{tid}", "fr", [tid, 0, 20, 0])
        if d and len(d) > 11 and d[11] > 40:
            run(f"topic-{tid}-p2", "fr", [tid, 20, 20, 0])
    if topic_ids:
        run("findpost-last", "fj", [2, topic_ids[0], -1, 0])
    run("search-all", "rc", [131072 | 3, [], [], [], "iphone", 0, 20])
    run("search-site", "rc", [(3 ^ 3) | 4, [], [], [], "iphone", 0, 20])
    run("profile-1", "mi", [1])
    run("sitemenu", "sm", [0])
    if me:
        run("profile-me", "mi", [me])
        run("favorites", "mf", [0, 30, 0])
        run("history", "mh", [0, 30])
        run("mentions", "mm", [0, 0, 1, 0, 20])
        run("unread", "mn", [0, 0, 0])
        run("bookmarks", "mb", [0, []])
        run("reputation", "mr", [me, 0, 0, 200])
        run("user-posts", "rc", [131072 | 1, [], [], [me], "", 0, 20])
    cl.log("готово")

if __name__ == "__main__":
    main()
