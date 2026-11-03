#!/usr/bin/env python3
"""Panes agent for Linux: serves terminal tabs (and, with Xpra, app windows)
to the Panes app on the phone. Standard library only.

Same wire format as the Mac agent (Shared/Wire.swift): TCP, one connection
per tab, frames of [type u8][length u32 big-endian][payload].

    python3 panes_agent.py            # port 7890, or PANES_PORT
"""
import asyncio
import fcntl
import json
import os
import pty
import pwd
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import termios
import time

CONTROL, VIDEO_FORMAT, VIDEO_FRAME, TERMINAL = 1, 2, 3, 4
VERSION = 1
MAX_PAYLOAD = 32 * 1024 * 1024


def frame(kind, payload):
    return struct.pack(">BI", kind, len(payload)) + payload


def control(msg):
    return frame(CONTROL, json.dumps(msg, separators=(",", ":")).encode())


def session_name(raw):
    """Same rule as Wire.sessionName: ASCII letters, digits, - and _, max 40."""
    cleaned = re.sub(r"[^A-Za-z0-9_-]", "", raw or "")[:40]
    return cleaned or "panes"


# ---- who may connect -------------------------------------------------------

def clean_ip(ip):
    ip = ip.split("%", 1)[0]
    return ip[7:] if ip.startswith("::ffff:") else ip


def is_loopback(ip):
    ip = clean_ip(ip)
    return ip == "::1" or ip.startswith("127.")


def is_tailnet(ip):
    ip = clean_ip(ip)
    if ip.lower().startswith("fd7a:115c:a1e0:"):
        return True
    parts = ip.split(".")
    if len(parts) != 4 or not all(p.isdigit() for p in parts):
        return False
    return int(parts[0]) == 100 and 64 <= int(parts[1]) <= 127


class Peers:
    """This machine, or tailnet devices owned by the same Tailscale user."""

    def __init__(self):
        self.tailscale = shutil.which("tailscale") or "/usr/bin/tailscale"
        self.cache = {}
        self.owner = None

    def _json(self, *args):
        try:
            out = subprocess.run([self.tailscale, *args], capture_output=True, timeout=5, check=True)
            return json.loads(out.stdout)
        except Exception:
            return None

    def owner_login(self):
        if self.owner is None:
            st = self._json("status", "--json") or {}
            uid = str((st.get("Self") or {}).get("UserID", ""))
            self.owner = ((st.get("User") or {}).get(uid) or {}).get("LoginName")
        return self.owner

    def allowed(self, ip):
        if is_loopback(ip):
            return True
        if not is_tailnet(ip):
            return False
        ip = clean_ip(ip)
        hit = self.cache.get(ip)
        if hit and time.time() - hit[1] < 600:
            return hit[0]
        who = ((self._json("whois", "--json", ip) or {}).get("UserProfile") or {}).get("LoginName")
        me = self.owner_login()
        ok = me is not None and who == me
        if not ok:
            print(f"refused {ip}: owner {who} is not {me}", flush=True)
        self.cache[ip] = (ok, time.time())
        return ok


# ---- terminal --------------------------------------------------------------

class Terminal:
    """A login shell on a pty, inside a named tmux session when tmux exists,
    so programs keep running while the phone is away."""

    def __init__(self, name, cols, rows, on_output, on_exit):
        user = pwd.getpwuid(os.getuid())
        shell = user.pw_shell or "/bin/bash"
        script = (f"if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s {session_name(name)}; "
                  f"else exec {shell} -l; fi")
        env = {k: v for k, v in os.environ.items() if k in ("LANG", "LC_ALL", "PATH", "XDG_RUNTIME_DIR",
                                                           "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "WAYLAND_DISPLAY")}
        env.update(TERM="xterm-256color", COLORTERM="truecolor", HOME=user.pw_dir, USER=user.pw_name,
                   LOGNAME=user.pw_name, SHELL=shell)
        env.setdefault("LANG", "C.UTF-8")
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(user.pw_dir)
                os.execvpe(shell, [shell, "-l", "-c", script], env)
            finally:
                os._exit(127)
        self.resize(cols, rows)
        os.set_blocking(self.fd, False)
        self.on_output, self.on_exit = on_output, on_exit
        self.closed = False
        asyncio.get_running_loop().add_reader(self.fd, self._readable)

    def _readable(self):
        try:
            data = os.read(self.fd, 65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if data:
            self.on_output(data)
        else:
            self._finish()

    def _finish(self):
        if self.closed:
            return
        self.closed = True
        asyncio.get_running_loop().remove_reader(self.fd)
        os.close(self.fd)
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        self.on_exit()

    def write(self, data):
        if self.closed:
            return
        view = memoryview(data)
        while view:
            try:
                n = os.write(self.fd, view)
                view = view[n:]
            except BlockingIOError:
                time.sleep(0.001)
            except OSError:
                return

    def resize(self, cols, rows):
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        except OSError:
            pass

    def close(self):
        """Hang up: tmux detaches and keeps the session; a plain shell exits."""
        if self.closed:
            return
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        self.closed = True
        asyncio.get_running_loop().remove_reader(self.fd)
        os.close(self.fd)
        try:
            os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            pass


# ---- connection ------------------------------------------------------------

class Session:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.terminal = None

    def send(self, data):
        if not self.writer.is_closing():
            self.writer.write(data)

    async def run(self):
        try:
            while True:
                head = await self.reader.readexactly(5)
                kind, length = struct.unpack(">BI", head)
                if kind not in (CONTROL, VIDEO_FORMAT, VIDEO_FRAME, TERMINAL) or length > MAX_PAYLOAD:
                    break
                payload = await self.reader.readexactly(length)
                if kind == CONTROL:
                    try:
                        self.handle(json.loads(payload))
                    except (ValueError, TypeError):
                        pass
                elif kind == TERMINAL and self.terminal:
                    self.terminal.write(payload)
                await self.writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            if self.terminal:
                self.terminal.close()
            self.writer.close()

    def handle(self, msg):
        op = msg.get("op")
        if op == "hello":
            self.send(control({"op": "hello", "version": VERSION, "machine": socket.gethostname(),
                               "features": ["terminal"]}))
        elif op == "list":
            self.send(control({"op": "windows", "windows": []}))
        elif op == "terminal":
            if self.terminal:
                self.terminal.close()
            name = session_name(msg.get("name"))

            def exited():
                self.terminal = None
                self.send(control({"op": "exited"}))
            try:
                self.terminal = Terminal(name, int(msg.get("cols") or 80), int(msg.get("rows") or 24),
                                         lambda d: self.send(frame(TERMINAL, d)), exited)
                self.send(control({"op": "terminalOpened", "name": name}))
            except OSError as e:
                self.send(control({"op": "error", "error": f"Couldn't start a shell: {e}"}))
        elif op == "resize" and self.terminal:
            self.terminal.resize(int(msg.get("cols") or 80), int(msg.get("rows") or 24))


async def main():
    port = int(os.environ.get("PANES_PORT", "7890"))
    peers = Peers()

    async def accept(reader, writer):
        ip = (writer.get_extra_info("peername") or ("",))[0]
        allowed = await asyncio.get_running_loop().run_in_executor(None, peers.allowed, ip)
        if not allowed:
            writer.close()
            return
        sock = writer.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        await Session(reader, writer).run()

    server = await asyncio.start_server(accept, host=None, port=port)
    print(f"Panes agent listening on {port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
