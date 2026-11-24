"""Протокол 4PDA (как в официальном Android-клиенте и 5PDA): TCP app.4pda.to:993 с кадрами
WebSocket, сжатие raw DEFLATE, сообщения — массивы в Windows-1251. Подробно — docs/PROTOCOL.md."""
from __future__ import annotations

import hashlib
import json
import os
import random
import socket
import ssl
import struct
import threading
import time
import urllib.request
import zlib
from pathlib import Path

PROTO_VERSION = "1.9.43"
CLIENT = "5pda-mcp"
PROVISION = ("https://gist.githubusercontent.com/aigilea/152b043823de7cfeacd06f348b78ec25/raw/provision.json",
             "https://provision.app.devapps.ru/")


# ---------- кодек ----------

def enc(v) -> bytes:
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
                    out += f"&#{ord(ch)};".encode()   # эмодзи и т.п. — HTML-сущностью, как в клиенте
        return bytes(out + b'"')
    if isinstance(v, (list, tuple)):
        return b"[" + b",".join(enc(x) for x in v) + b"]"
    raise TypeError(type(v))


def dec(b: bytes):
    pos = 0

    def ws():
        nonlocal pos
        while pos < len(b) and b[pos] in b" \r\n\t":
            pos += 1

    def val():
        nonlocal pos
        ws()
        c = b[pos]
        if c == 0x5B:
            pos += 1
            items = []
            ws()
            if b[pos] == 0x5D:
                pos += 1
                return items
            while True:
                items.append(val())
                ws()
                if b[pos] == 0x2C:
                    pos += 1
                    continue
                if b[pos] == 0x5D:
                    pos += 1
                    return items
                raise ValueError(f"bad array at {pos}")
        if c == 0x22:
            pos += 1
            chunk = bytearray()
            res = ""
            while True:
                c = b[pos]
                pos += 1
                if c == 0x22:
                    return res + chunk.decode("cp1251", "replace")
                if c != 0x5C:
                    chunk.append(c)
                    continue
                e = b[pos]
                pos += 1
                m = {0x6E: 10, 0x72: 13, 0x74: 9, 0x66: 12, 0x62: 8}
                if e in m:
                    chunk.append(m[e])
                elif e == 0x75:
                    res += chunk.decode("cp1251", "replace")
                    chunk = bytearray()
                    res += chr(int(b[pos:pos + 4], 16))
                    pos += 4
                else:
                    chunk.append(e)
        start = pos
        if c == 0x2D:
            pos += 1
        while pos < len(b) and 0x30 <= b[pos] <= 0x39:
            pos += 1
        return int(b[start:pos])

    return val()


# ---------- транспорт ----------

class Conn:
    def __init__(self, host: str, port: int, ws_host: str | None = None):
        raw = socket.create_connection((host, port), timeout=20)
        self.buf = b""
        if ws_host:
            raw = ssl.create_default_context().wrap_socket(raw, server_hostname=ws_host)
            raw.sendall((f"GET /ws/ HTTP/1.1\r\nHost: {ws_host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
                         "Sec-WebSocket-Protocol: app\r\n\r\n").encode())
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = raw.recv(4096)
                if not chunk:
                    raise IOError("closed during handshake")
                head += chunk
            hdr, _, self.buf = head.partition(b"\r\n\r\n")
            if b" 101" not in hdr.split(b"\r\n")[0]:
                raise IOError("handshake failed")
        self.s = raw
        self.inflater = zlib.decompressobj(-15)

    @staticmethod
    def _frame(opcode: int, payload: bytes, fin: bool) -> bytes:
        comp = zlib.compressobj(6, zlib.DEFLATED, -15)
        body = comp.compress(payload) + comp.flush(zlib.Z_SYNC_FLUSH)
        if body.endswith(b"\x00\x00\xff\xff"):
            body = body[:-4]
        body = struct.pack("<I", len(payload)) + body
        hdr = bytes([(0x80 if fin else 0) | 0x40 | opcode])
        n = len(body)
        if n <= 125:
            hdr += bytes([n])
        elif n <= 0xFFFF:
            hdr += bytes([126]) + struct.pack(">H", n)
        else:
            hdr += bytes([127]) + struct.pack(">Q", n)
        return hdr + body

    def send_msg(self, payload: bytes, binary: bytes | None = None):
        """Сообщение; с двоичным хвостом — текстовый кадр без FIN и кадры-продолжения."""
        if not binary:
            self.s.sendall(self._frame(1, payload, True))
            return
        self.s.sendall(self._frame(1, payload, False))
        size = min(131072, max(4096, len(binary) // 4))
        chunks = [binary[i:i + size] for i in range(0, len(binary), size)]
        for i, c in enumerate(chunks):
            self.s.sendall(self._frame(0, c, i == len(chunks) - 1))

    def _read(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise IOError("connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv_msg(self) -> bytes:
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
            op = b0 & 0x0F
            if op == 9:   # ping → pong
                self.s.sendall(bytes([0x8A, len(data)]) + data)
                continue
            if op == 8:
                raise IOError("server closed")
            if b0 & 0x40:
                size = struct.unpack("<I", data[:4])[0]
                data = self.inflater.decompress(data[4:] + b"\x00\x00\xff\xff")[:size]
            return data

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


class ServerError(Exception):
    def __init__(self, cmd: str, code: int, payload):
        super().__init__(f"{cmd}: код {code}")
        self.cmd, self.code, self.payload = cmd, code, payload


class CaptchaRequired(Exception):
    def __init__(self, url: str):
        super().__init__("нужна капча")
        self.url = url


def session_path() -> Path:
    base = Path(os.environ.get("PDA_MCP_HOME") or Path.home() / ".config" / "5pda-mcp")
    base.mkdir(parents=True, exist_ok=True)
    return base / "session.json"


class Client:
    """Клиент с переподключением и сохранённым входом (id + ключ, как в приложении)."""

    def __init__(self):
        self.lock = threading.RLock()
        self.conn: Conn | None = None
        self.next_id = 1
        self.member_id = 0
        self.key = ""
        self.nick = ""
        self.site = "https://4pda.to/"
        self._load_session()

    # --- сессия ---
    def _load_session(self):
        try:
            d = json.loads(session_path().read_text())
            self.member_id, self.key, self.nick = int(d["id"]), d["key"], d.get("nick", "")
        except Exception:
            pass

    def _save_session(self):
        p = session_path()
        p.write_text(json.dumps({"id": self.member_id, "key": self.key, "nick": self.nick}))
        try:
            os.chmod(p, 0o600)
        except OSError:
            pass

    def logout(self):
        with self.lock:
            self.member_id, self.key, self.nick = 0, "", ""
            try:
                session_path().unlink()
            except FileNotFoundError:
                pass
            self._drop()

    # --- соединение ---
    def _drop(self):
        if self.conn:
            self.conn.close()
        self.conn = None

    def _connect(self):
        prov = None
        for url in PROVISION:
            try:
                prov = json.loads(urllib.request.urlopen(url, timeout=15).read())
                break
            except Exception:
                continue
        prov = prov or {"d": "app.4pda.to:993", "w": "appbk.4pda.to", "b": "https://4pda.to/"}
        self.site = prov.get("b", self.site)
        host, port = prov["d"].rsplit(":", 1)
        try:
            self.conn = Conn(host, int(port))
        except OSError:
            self.conn = Conn(prov["w"], 443, prov["w"])
        r = self._raw("ah", [PROTO_VERSION, "", CLIENT, 1, self.member_id])
        if r[1] == 3:
            raise ServerError("ah", 3, "клиент устарел")
        if self.member_id and self.key:
            r = self._raw("ma", [self.member_id, self.key])
            if r[1] != 0:   # ключ больше не действует
                self.member_id, self.key = 0, ""
                try:
                    session_path().unlink()
                except FileNotFoundError:
                    pass

    def _raw(self, cmd: str, params: list, binary: bytes | None = None, timeout: float = 30):
        rid = self.next_id
        self.next_id = 1 if self.next_id >= 0x0FFFFFF else self.next_id + 1
        self.conn.send_msg(enc([rid, cmd] + list(params)), binary)
        deadline = time.time() + timeout
        self.conn.s.settimeout(timeout)
        while time.time() < deadline:
            msg = dec(self.conn.recv_msg())
            if isinstance(msg, list) and msg and isinstance(msg[0], int):
                if (msg[0] & 0x0FFFFFFF) == rid:
                    return msg
                if msg[0] == 0 and len(msg) > 1 and msg[1] != 0:
                    return msg
        raise TimeoutError(cmd)

    def call(self, cmd: str, params: list | tuple = (), binary: bytes | None = None, timeout: float = 30) -> list:
        """Выполняет команду; возвращает данные ответа (без id и кода). Ошибка сервера — ServerError."""
        with self.lock:
            for attempt in range(2):
                try:
                    if self.conn is None:
                        self._connect()
                    r = self._raw(cmd, list(params), binary, timeout)
                    break
                except (OSError, IOError, TimeoutError, ValueError, IndexError):
                    self._drop()
                    if attempt == 1:
                        raise
            code = r[1] if len(r) > 1 else -1
            data = r[2:]
            if code != 0:
                raise ServerError(cmd, code, data)
            return data

    # --- вход ---
    def login(self, login: str, password: str, captcha: int = 0, hidden: bool = False):
        with self.lock:
            try:
                d = self.call("ml", [login, password, 1 if hidden else 0, captcha])
            except ServerError as e:
                if e.code == 4:
                    url = e.payload[0] if e.payload else ""
                    raise CaptchaRequired("https:" + url if url.startswith("//") else url)
                raise
            self.member_id, self.key, self.nick = int(d[0]), str(d[1]), login
            self._save_session()

    @property
    def logged_in(self) -> bool:
        return self.member_id > 0 and bool(self.key)

    # --- загрузка файла ---
    def upload(self, name: str, data: bytes) -> int:
        md5 = hashlib.md5(data).hexdigest().upper()
        meta = [name, len(data), md5]
        try:
            return int(self.call("fu", meta)[0])
        except ServerError as e:
            if e.code != 4:
                raise
        key = f"att-{self.member_id}-{random.randint(100000, 999999999)}"
        done = int(self.call("su", [key])[0])
        for _ in range(5):
            if done >= len(data):
                break
            done = int(self.call("su", [key], binary=data[done:], timeout=300)[0])
        return int(self.call("su", [key, "fu"] + meta)[0])
