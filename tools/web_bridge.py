#!/usr/bin/env python3
"""DEV ONLY, NOT FOR PRODUCTION: a stand-in for an agent's web server, for
testing Panes Web against a real agent before the agent serves it itself.

It serves web/ on http://127.0.0.1:<port> (localhost is a secure context, so
WebCodecs works) and bridges /ws WebSocket messages to the agent's plain TCP
protocol (default 127.0.0.1:7890): each binary WebSocket message is one whole
Wire frame, both ways, as docs/WEB.md describes.

machines.json is replaced by a single machine whose `web` is this bridge, so
the page connects back here. There is no Tailscale identity check: it only
listens on 127.0.0.1 and only takes WebSocket upgrades from its own origin.

    python3 tools/web_bridge.py [--port 7899] [--agent 127.0.0.1:7890]

Another machine's agent can be bridged too (e.g. --agent linux-box:7890 --name
linux-box), but /xpra/ isn't proxied, so its app tabs won't load their page.
"""

import argparse
import base64
import hashlib
import json
import mimetypes
import os
import socket
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(ROOT, "web")
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_PAYLOAD = 32 * 1024 * 1024


def read_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return bytes(buf)


def ws_send(sock, lock, opcode, payload):
    """Server frames are never masked."""
    head = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head.append(n)
    elif n < 1 << 16:
        head.append(126)
        head += struct.pack(">H", n)
    else:
        head.append(127)
        head += struct.pack(">Q", n)
    with lock:
        sock.sendall(bytes(head) + payload)


def ws_messages(sock):
    """Yields (opcode, payload) for each whole message, joining fragments.
    Control frames (ping, pong, close) come through as they arrive."""
    parts, first_op = [], None
    while True:
        b0, b1 = read_exact(sock, 2)
        fin, opcode = b0 & 0x80, b0 & 0x0F
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", read_exact(sock, 2))[0]
        elif n == 127:
            n = struct.unpack(">Q", read_exact(sock, 8))[0]
        if n > MAX_PAYLOAD + 5:
            raise ConnectionError("message too large")
        mask = read_exact(sock, 4) if b1 & 0x80 else None
        data = read_exact(sock, n)
        if mask:
            data = unmask(data, mask)
        if opcode >= 0x8:
            yield opcode, data
            continue
        if opcode != 0:
            first_op, parts = opcode, []
        parts.append(data)
        if fin:
            yield first_op, b"".join(parts)
            parts = []


def unmask(data, mask):
    # XOR a whole frame at once via big integers: fast enough for video-sized messages.
    n = len(data)
    key = (mask * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big")


class Handler(BaseHTTPRequestHandler):
    server_version = "panes-web-bridge"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if self.server.verbose:
            sys.stderr.write("bridge: " + fmt % args + "\n")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/ws":
            return self.websocket()
        if path == "/machines.json":
            return self.reply(200, "application/json", json.dumps(self.server.machines).encode())
        if path == "/":
            path = "/index.html"
        full = os.path.realpath(os.path.join(WEB, path.lstrip("/")))
        if not full.startswith(os.path.realpath(WEB) + os.sep) or not os.path.isfile(full):
            return self.reply(404, "text/plain", b"not found")
        kind = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if full.endswith(".js"):
            kind = "text/javascript"
        with open(full, "rb") as f:
            self.reply(200, kind, f.read())

    def reply(self, code, kind, body):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def websocket(self):
        # Only the bridge's own page may drive the agent, as the real server requires.
        if self.headers.get("Origin") not in self.server.origins:
            return self.reply(403, "text/plain", b"bad origin")
        key = self.headers.get("Sec-WebSocket-Key")
        if self.headers.get("Upgrade", "").lower() != "websocket" or not key:
            return self.reply(400, "text/plain", b"websocket only")
        try:
            agent = socket.create_connection(self.server.agent, timeout=5)
        except OSError as e:
            self.log_message("agent unreachable: %s", e)
            return self.reply(502, "text/plain", b"agent unreachable")
        agent.settimeout(None)
        agent.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True

        client = self.connection
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        lock = threading.Lock()
        done = threading.Event()

        def agent_to_browser():
            # One whole Wire frame per WebSocket message.
            try:
                while not done.is_set():
                    head = read_exact(agent, 5)
                    n = struct.unpack(">I", head[1:])[0]
                    if n > MAX_PAYLOAD:
                        break
                    ws_send(client, lock, 0x2, head + read_exact(agent, n))
            except (OSError, ConnectionError):
                pass
            finally:
                done.set()
                try:
                    ws_send(client, lock, 0x8, struct.pack(">H", 1000))
                except OSError:
                    pass
                shut(client)

        t = threading.Thread(target=agent_to_browser, daemon=True)
        t.start()
        try:
            for opcode, data in ws_messages(client):
                if opcode == 0x2:
                    agent.sendall(data)
                elif opcode == 0x9:
                    ws_send(client, lock, 0xA, data)
                elif opcode == 0x8:
                    break
                # Text messages are ignored, as on the real server.
        except (OSError, ConnectionError):
            pass
        finally:
            done.set()
            shut(agent)
            t.join(timeout=2)


def shut(sock):
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(description="DEV ONLY: serve web/ and bridge /ws to an agent's TCP port.")
    ap.add_argument("--port", type=int, default=7899)
    ap.add_argument("--agent", default="127.0.0.1:7890", help="host:port of the agent's TCP protocol")
    ap.add_argument("--name", default="This Mac", help="machine name shown in the picker")
    ap.add_argument("--allow-origin", action="append", default=[],
                    help="another page origin allowed to open /ws (a second bridge in tests)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    host, _, port = args.agent.rpartition(":")
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.verbose = args.verbose
    server.agent = (host or "127.0.0.1", int(port))
    me = f"http://127.0.0.1:{args.port}"
    server.origins = {me, f"http://localhost:{args.port}", *args.allow_origin}
    server.machines = [{"name": args.name, "hosts": ["127.0.0.1"], "web": me}]
    print(f"panes web bridge (dev only): {me}  ->  agent {args.agent}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
