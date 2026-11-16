"""Rendezvous only. Chat messages and file contents have no endpoint here."""
import collections
import hmac
import json
import os
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ID = re.compile(r"^[A-Za-z0-9_-]{20,80}$")
MAX_BODY = 64_000


class Room:
    def __init__(self, access):
        self.access = access
        self.peers = {}
        self.events = collections.deque()
        self.sequence = 0
        self.buffer_bytes = 0
        self.changed = threading.Condition()
        self.touched = time.monotonic()
        self.budget = {}

    def emit(self, kind, sender, recipient="", box=""):
        self.sequence += 1
        self.events.append(dict(sequence=self.sequence, kind=kind, sender=sender, recipient=recipient, box=box))
        self.buffer_bytes += len(box) + 160
        while len(self.events) > 512 or self.buffer_bytes > 2_000_000:
            old = self.events.popleft(); self.buffer_bytes -= len(old["box"]) + 160
        self.touched = time.monotonic()
        self.changed.notify_all()

    def prune(self):
        for peer, last in list(self.peers.items()):
            if time.monotonic() - last > 90:
                del self.peers[peer]
                self.budget.pop(peer, None)
                self.emit("leave", peer)


class Rendezvous:
    def __init__(self, create_token=None):
        self.create_token = create_token
        self.rooms = {}
        self.lock = threading.Lock()
        self.creates = {}

    def create(self, address):
        with self.lock:
            now = time.monotonic()
            self.rooms = {key: room for key, room in self.rooms.items() if now - room.touched < 3600}
            self.creates = {key: value for key, value in self.creates.items() if now - value[0] < 3600}
            started, count = self.creates.get(address, (now, 0))
            if count >= 10 or len(self.rooms) >= 32:
                raise RequestError(429)
            self.creates[address] = (started, count + 1)
            room_id, access = secrets.token_urlsafe(24), secrets.token_urlsafe(32)
            self.rooms[room_id] = Room(access)
            return dict(room=room_id, access=access)


class RequestError(Exception):
    def __init__(self, code):
        self.code = code


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def setup(self):
            super().setup()
            self.connection.settimeout(30)

        def log_message(self, *args):
            pass

        def reply(self, code, value):
            data = json.dumps(value, separators=(",", ":")).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            self.wfile.write(data)

        def handle_request(self, method):
            try:
                body = {}
                if method == "POST":
                    if self.headers.get("Transfer-Encoding"):
                        raise RequestError(400)
                    try:
                        length = int(self.headers.get("Content-Length", "0"))
                    except ValueError:
                        raise RequestError(400)
                    if not 0 < length <= MAX_BODY:
                        raise RequestError(413)
                    body = json.loads(self.rfile.read(length))
                    if not isinstance(body, dict):
                        raise RequestError(400)
                url = urlsplit(self.path)
                if url.path == "/join" and method == "GET":
                    page = r"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Комната Пульта</title><style>body{font:18px system-ui;background:#181a1e;color:#eee;max-width:600px;margin:15vh auto;padding:24px}a{display:block;background:#65bdb3;color:#122422;padding:16px;border-radius:12px;text-align:center;text-decoration:none}p{line-height:1.5;color:#bbb}</style><h1>Заходи в общий проект</h1><p>Открой приглашение в Пульте 2.1 или новее. Чат работает напрямую между ПК; ключ комнаты серверу не передаётся.</p><a id=open>Открыть в Пульте</a><p id=hint></p><script>const key=location.hash.slice(1);if(key&&/^[A-Za-z0-9+\/=]+$/.test(key)){document.getElementById('open').href='pult://room#'+key}else{document.getElementById('hint').textContent='Попроси кента прислать полную ссылку приглашения.'}</script>""".encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(page)))
                    self.send_header("Referrer-Policy", "no-referrer")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
                    self.send_header("Connection", "close")
                    self.end_headers(); self.close_connection = True; self.wfile.write(page)
                    return
                if url.path == "/health" and method == "GET":
                    return self.reply(200, {"ok": True, "mode": "signaling-only"})
                if url.path == "/v1/rooms" and method == "POST":
                    if state.create_token and not hmac.compare_digest(state.create_token, self.headers.get("X-Pult-Create-Token", "")):
                        raise RequestError(403)
                    if body:
                        raise RequestError(400)
                    return self.reply(201, state.create(self.client_address[0]))
                parts = url.path.strip("/").split("/")
                if len(parts) != 4 or parts[:2] != ["v1", "rooms"]:
                    raise RequestError(404)
                room_id, action = parts[2:]
                if not ID.fullmatch(room_id):
                    raise RequestError(404)
                with state.lock:
                    room = state.rooms.get(room_id)
                access = self.headers.get("Authorization", "").removeprefix("Bearer ")
                if not room or not hmac.compare_digest(room.access, access):
                    raise RequestError(403)
                peer = self.headers.get("X-Pult-Peer", "")
                if not ID.fullmatch(peer):
                    raise RequestError(400)
                with room.changed:
                    room.prune()
                    if method == "POST" and action == "join":
                        if body or len(room.peers) >= 8 and peer not in room.peers:
                            raise RequestError(409)
                        peers = [item for item in room.peers if item != peer]
                        if peer not in room.peers:
                            room.emit("join", peer)
                        room.peers[peer] = time.monotonic()
                        result = dict(peers=peers, cursor=room.sequence)
                    elif peer not in room.peers:
                        raise RequestError(410)
                    elif method == "POST" and action == "leave":
                        del room.peers[peer]
                        room.emit("leave", peer)
                        result = {"ok": True}
                    elif method == "POST" and action == "signal":
                        # Only encrypted ICE/SDP negotiation. No arbitrary data relay route.
                        if set(body) != {"recipient", "box"} or body["recipient"] not in room.peers:
                            raise RequestError(400)
                        box = body["box"]
                        if not isinstance(box, str) or not 1 <= len(box) <= 48_000 or re.fullmatch(r"[A-Za-z0-9+/=]+", box) is None:
                            raise RequestError(400)
                        now = time.monotonic()
                        started, count = room.budget.get(peer, (now, 0))
                        if now - started >= 60:
                            started, count = now, 0
                        if count >= 180:
                            raise RequestError(429)
                        room.budget[peer] = (started, count + 1)
                        room.emit("signal", peer, body["recipient"], box)
                        result = {"ok": True}
                    elif method == "GET" and action == "events":
                        after = int(parse_qs(url.query).get("after", ["0"])[0])
                        deadline = time.monotonic() + 20
                        while True:
                            if peer not in room.peers:
                                raise RequestError(410)
                            room.peers[peer] = time.monotonic()
                            room.touched = time.monotonic()
                            events = [event for event in room.events if event["sequence"] > after
                                      and event["sender"] != peer
                                      and (not event["recipient"] or event["recipient"] == peer)]
                            if peer not in room.peers:
                                raise RequestError(410)
                            if room.events and after < room.events[0]["sequence"] - 1:
                                raise RequestError(409)
                            if events or time.monotonic() >= deadline:
                                break
                            room.changed.wait(timeout=max(0, deadline - time.monotonic()))
                        result = dict(events=events, cursor=room.sequence)
                    else:
                        raise RequestError(404)
                self.reply(200, result)
            except RequestError as error:
                self.reply(error.code, {"error": error.code})
            except (ValueError, TypeError, KeyError):
                self.reply(400, {"error": 400})
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass

        def do_GET(self):
            self.handle_request("GET")

        def do_POST(self):
            self.handle_request("POST")

    return Handler


class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    slots = threading.BoundedSemaphore(64)

    def verify_request(self, request, client_address):
        return self.slots.acquire(blocking=False)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def create_server(host="127.0.0.1", port=8787, create_token=None):
    server = BoundedServer((host, port), make_handler(Rendezvous(create_token)))
    server.daemon_threads = True
    return server


if __name__ == "__main__":
    create_server(os.environ.get("PULT_SIGNAL_HOST", "127.0.0.1"), int(os.environ.get("PULT_SIGNAL_PORT", "8787")), os.environ.get("PULT_SIGNAL_CREATE_TOKEN")).serve_forever()
