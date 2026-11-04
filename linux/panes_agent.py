#!/usr/bin/env python3
"""Panes agent for Linux: serves terminal tabs (and, with Xpra, app windows)
to the Panes app on the phone, and to Panes Web in a browser. Standard library only.

Same wire format as the Mac agent (Shared/Wire.swift): TCP, one connection
per tab, frames of [type u8][length u32 big-endian][payload]. Panes Web
(docs/WEB.md) carries the same frames over a WebSocket, one per message, on
a loopback HTTP server that `tailscale serve` publishes as HTTPS on 7443.

    python3 panes_agent.py            # port 7890, or PANES_PORT
                                      # web on 127.0.0.1:7891, or PANES_WEB_PORT
"""
import asyncio
import base64
import configparser
import fcntl
import glob
import hashlib
import secrets
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
import urllib.parse

CONTROL, VIDEO_FORMAT, VIDEO_FRAME, TERMINAL = 1, 2, 3, 4
VERSION = 1
MAX_PAYLOAD = 32 * 1024 * 1024
WEB_PORT = 7891          # loopback HTTP; tailscale serve publishes it as HTTPS on WEB_TLS_PORT
WEB_TLS_PORT = 7443


def frame(kind, payload):
    return struct.pack(">BI", kind, len(payload)) + payload


def control(msg):
    return frame(CONTROL, json.dumps(msg, separators=(",", ":")).encode())


def is_panes_session(name):
    """Same rule as Wire.isPanesSession: only panes-… sessions may be ended."""
    return name.startswith("panes-") and len(name) > 6


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


PROC_TCP = ("/proc/net/tcp", "/proc/net/tcp6")


def socket_owner_uid(peer_port, local_port, tables=PROC_TCP):
    """The uid owning the far end of a loopback TCP connection to us: the socket
    whose local port is the peer's and whose remote port is ours, in
    /proc/net/tcp. None when /proc has no answer (not Linux, or it's gone)."""
    for table in tables:
        try:
            with open(table) as f:
                lines = f.readlines()[1:]
        except OSError:
            continue
        for line in lines:
            parts = line.split()
            if len(parts) < 8:
                continue
            try:
                lport = int(parts[1].rsplit(":", 1)[1], 16)
                rport = int(parts[2].rsplit(":", 1)[1], 16)
                uid = int(parts[7])
            except (IndexError, ValueError):
                continue
            if lport == peer_port and rport == local_port:
                return uid
    return None


def process_uids(name, proc="/proc"):
    """uids of running processes called `name` (tailscaled, which proxies Panes Web)."""
    uids = set()
    for comm in glob.glob(os.path.join(proc, "[0-9]*", "comm")):
        try:
            with open(comm) as f:
                if f.read().strip() != name:
                    continue
            uids.add(os.stat(os.path.dirname(comm)).st_uid)
        except OSError:
            continue
    return uids


def loopback_caller_allowed(peer_port, local_port, extra_uids=(), tables=PROC_TCP, my_uid=None):
    """Another account on this machine mustn't use our tabs: a loopback caller
    has to be us (or, for Panes Web, tailscaled). A caller /proc doesn't list
    is refused: it can't be shown to be us. Only with no /proc at all (not
    Linux) is loopback trusted, as before."""
    uid = socket_owner_uid(peer_port, local_port, tables)
    if uid is None:
        return not any(os.path.exists(t) for t in tables)
    return uid == (os.getuid() if my_uid is None else my_uid) or uid in extra_uids


class Peers:
    """This machine, or tailnet devices owned by the same Tailscale user."""

    def __init__(self, status=None):
        self.tailscale = shutil.which("tailscale") or "/usr/bin/tailscale"
        self.cache = {}
        self.owner = None
        # `tailscale status --json`; tests pass one in instead.
        self._status, self._status_at = status, 0.0

    def _json(self, *args):
        try:
            out = subprocess.run([self.tailscale, *args], capture_output=True, timeout=5, check=True)
            return json.loads(out.stdout)
        except Exception:
            return None

    def status(self):
        """Kept once read; while tailscale is down, asked again at most every 30 s."""
        if self._status is None and time.time() - self._status_at > 30:
            self._status_at = time.time()
            self._status = self._json("status", "--json")
        return self._status or {}

    def owner_login(self):
        if self.owner is None:
            st = self.status()
            uid = str((st.get("Self") or {}).get("UserID", ""))
            self.owner = ((st.get("User") or {}).get(uid) or {}).get("LoginName")
        return self.owner

    def magic_dns_suffix(self):
        return (self.status().get("MagicDNSSuffix") or "").strip(".").lower()

    def web_address(self):
        """This machine's Panes Web address, as published by tailscale serve."""
        dns = ((self.status().get("Self") or {}).get("DNSName") or "").rstrip(".")
        return f"https://{dns}:{WEB_TLS_PORT}" if dns else None

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


# ---- app windows (Xpra) ----------------------------------------------------

def desktop_apps(dirs=None):
    """Launchable apps from .desktop files: id, name, command."""
    dirs = dirs or ["/usr/share/applications", "/usr/local/share/applications",
                    os.path.expanduser("~/.local/share/applications"),
                    "/var/lib/flatpak/exports/share/applications",
                    os.path.expanduser("~/.local/share/flatpak/exports/share/applications")]
    apps = {}
    for d in dirs:
        for path in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            cp = configparser.ConfigParser(interpolation=None, strict=False)
            try:
                cp.read(path, encoding="utf-8")
                e = cp["Desktop Entry"]
            except (configparser.Error, KeyError, UnicodeDecodeError):
                continue
            if e.get("Type") != "Application" or e.get("NoDisplay", "").lower() == "true" \
                    or e.get("Hidden", "").lower() == "true" or e.get("Terminal", "").lower() == "true":
                continue
            command = strip_field_codes(e.get("Exec", ""))
            if not command or not e.get("Name"):
                continue
            app_id = os.path.basename(path)[:-len(".desktop")]
            apps[app_id] = {"id": app_id, "name": e.get("Name"), "command": command}
    return sorted(apps.values(), key=lambda a: a["name"].lower())


def strip_field_codes(command):
    """Drops %f, %U and friends from a desktop Exec line (no file is being opened)."""
    return re.sub(r"\s*%[a-zA-Z]", "", command).replace("%%", "%").strip()


class Xpra:
    """One Xpra session per app tab, kept running between connections like a
    tmux session: the phone reattaches to the same running app. Each session
    listens on 127.0.0.1 only, behind a random password that only that tab is
    told; clients reach it through the web server's /xpra/<session>/ proxy."""

    PORTS = range(14500, 14600)
    HOST = "127.0.0.1"
    SECRETS = os.path.expanduser("~/.local/share/panes/sessions")

    # Xpra's browser client: the distro's copy, or the release Panes installs
    # next to the agent (Fedora doesn't package it).
    HTML_DIRS = ["/usr/share/xpra/www", os.path.expanduser("~/.local/share/panes/xpra-html5")]

    def __init__(self):
        self.binary = shutil.which("xpra")
        self.sessions = {}   # name -> dict(port, password, proc, app)

    @property
    def html_dir(self):
        return next((d for d in self.HTML_DIRS if os.path.isfile(os.path.join(d, "index.html"))), None)

    @property
    def available(self):
        return self.binary is not None and self.html_dir is not None

    @property
    def sound(self):
        """App sound needs a PulseAudio server for Xpra to start per session
        (PipeWire's pulse layer counts)."""
        return shutil.which("pulseaudio") is not None or shutil.which("pipewire-pulse") is not None

    def _free_port(self, host):
        used = {s["port"] for s in self.sessions.values()}
        for port in self.PORTS:
            if port in used:
                continue
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                if probe.connect_ex((host, port)) != 0:
                    return port
        raise OSError("no free port for an app session")

    def launch(self, name, app):
        live = self.sessions.get(name)
        if live and live["proc"].poll() is None and live["app"] == app["id"]:
            return live
        if live:
            self.end(name)
        host = self.HOST
        port = self._free_port(host)
        password = secrets.token_urlsafe(18)
        # The password goes in a file only this user can read, not on the
        # command line where any local account could see it in ps.
        os.makedirs(self.SECRETS, mode=0o700, exist_ok=True)
        pw_file = os.path.join(self.SECRETS, f"{name}.pw")
        fd = os.open(pw_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(password)
        display = f":{100 + port - self.PORTS.start}"
        cmd = [self.binary, "start", display, "--daemon=no",
               f"--start-child={app['command']}", "--exit-with-children=yes",
               f"--bind-tcp={host}:{port}", f"--tcp-auth=file:filename={pw_file}",
               f"--html={self.html_dir}", "--mdns=no", "--notifications=no",
               f"--speaker={'on' if self.sound else 'off'}", "--microphone=off",
               "--webcam=no", "--printing=no", "--file-transfer=no", "--dpi=144"]
        log = open(os.path.expanduser(f"~/.local/share/panes/xpra-{name}.log"), "ab")
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        session = {"name": name, "port": port, "password": password, "proc": proc, "app": app["id"],
                   "host": host, "pw_file": pw_file}
        self.sessions[name] = session
        return session

    def end(self, name):
        """Stops an app session (the phone closed its tab)."""
        session = self.sessions.pop(name, None)
        if not session:
            return
        if session["proc"].poll() is None:
            try:
                os.killpg(session["proc"].pid, signal.SIGTERM)
                session["proc"].wait(timeout=10)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(session["proc"].pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        try:
            os.remove(session["pw_file"])
        except OSError:
            pass

    def ready(self, session, timeout=20.0):
        """Waits until the session's web client answers."""
        end = time.time() + timeout
        while time.time() < end:
            if session["proc"].poll() is not None:
                return False
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.settimeout(0.5)
                if probe.connect_ex((session["host"], session["port"])) == 0:
                    return True
            time.sleep(0.25)
        return False

    @staticmethod
    def url(session, sound=False):
        # Xpra's own web client, told to connect straight away with its password.
        # Relative: clients resolve it against the machine's web address (hello's "web").
        return (f"/xpra/{session['name']}/index.html?password={session['password']}"
                f"&submit=true&sound={'true' if sound else 'false'}&floating_menu=false&clipboard=true&swap_keys=false")


XPRA = Xpra()


def kill_tmux_session(name):
    if is_panes_session(name) and shutil.which("tmux"):
        subprocess.run(["tmux", "kill-session", "-t", f"={session_name(name)}"], capture_output=True)


# ---- WebSocket (RFC 6455) --------------------------------------------------

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_CONT, WS_TEXT, WS_BINARY, WS_CLOSE, WS_PING, WS_PONG = 0, 1, 2, 8, 9, 10


# ---- Tabs on other devices (docs/UI.md) --------------------------------------

DEVICE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
TAB_FIELDS = {"machine": str, "kind": str, "app": str, "title": str, "windowID": int, "session": str, "appID": str}


def clean_tab(tab):
    """Only the fields a TabRef has, of the right types; None if it isn't one."""
    if not isinstance(tab, dict):
        return None
    out = {k: tab[k] for k, t in TAB_FIELDS.items()
           if k in tab and isinstance(tab[k], t) and not isinstance(tab[k], bool)}
    for k in ("machine", "kind", "app", "title", "session", "appID"):
        if k in out:
            out[k] = out[k][:200]
    return out if all(k in out for k in ("machine", "kind", "app")) else None


class DeviceBook:
    """Phones and browsers using this agent, their open tabs, and tabs sent
    between them. Same rules as Agent/Devices.swift."""
    MAX_DEVICES, MAX_TABS, MAX_INBOX = 20, 60, 20
    DEVICE_TTL = 30 * 24 * 3600
    SENT_TTL = 7 * 24 * 3600

    def __init__(self, path, now=time.time):
        self.path = path
        self.now = now
        self.devices = []
        self.inbox = {}
        try:
            with open(path) as f:
                saved = json.load(f)
            self.devices = [d for d in saved.get("devices", []) if isinstance(d, dict) and "id" in d]
            self.inbox = {k: v for k, v in saved.get("inbox", {}).items() if isinstance(v, list)}
        except (OSError, TypeError, ValueError, AttributeError):
            pass

    def report(self, device):
        if not isinstance(device, dict) or not DEVICE_ID.match(str(device.get("id", ""))):
            return []
        did = device["id"]
        tabs = [t for t in (clean_tab(t) for t in (device.get("tabs") or [])[:self.MAX_TABS]) if t]
        d = {"id": did, "name": str(device.get("name") or "")[:60],
             "kind": "phone" if device.get("kind") == "phone" else "browser",
             "tabs": tabs, "seen": self.now()}
        self.devices = [x for x in self.devices if x["id"] != did] + [d]
        self._prune()
        waiting = self.inbox.pop(did, [])
        self._save()
        return waiting

    def list(self, except_id=None):
        self._prune()
        return sorted((d for d in self.devices if d["id"] != except_id), key=lambda d: -d.get("seen", 0))

    def send(self, tab, to, sender, sid):
        tab = clean_tab(tab)
        if not tab or not DEVICE_ID.match(str(to or "")) or not any(d["id"] == to for d in self.devices):
            return False
        box = self.inbox.get(to, [])
        if not any(x["id"] == sid for x in box):
            box.append({"id": str(sid)[:64], "from": str(sender or "")[:60], "tab": tab, "at": self.now()})
        self.inbox[to] = box[-self.MAX_INBOX:]
        self._save()
        return True

    def forget(self, did):
        self.devices = [d for d in self.devices if d["id"] != did]
        self.inbox.pop(did, None)
        self._save()

    def _prune(self):
        t = self.now()
        self.devices = [d for d in self.devices if t - d.get("seen", 0) <= self.DEVICE_TTL]
        if len(self.devices) > self.MAX_DEVICES:
            self.devices = sorted(self.devices, key=lambda d: -d.get("seen", 0))[:self.MAX_DEVICES]
        known = {d["id"] for d in self.devices}
        self.inbox = {k: [x for x in v if t - x.get("at", 0) <= self.SENT_TTL]
                      for k, v in self.inbox.items() if k in known}
        self.inbox = {k: v for k, v in self.inbox.items() if v}

    def _save(self):
        if not self.path:
            return
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"devices": self.devices, "inbox": self.inbox}, f)
        os.replace(tmp, self.path)


DEVICES = DeviceBook(os.path.join(os.environ.get("PANES_STATE_DIR") or os.path.expanduser("~/.local/share/panes"),
                                  "devices.json"))


def ws_accept_key(key):
    """Sec-WebSocket-Accept for a client's Sec-WebSocket-Key."""
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def ws_mask(data, key):
    """XORs data with the 4-byte masking key (masking and unmasking are the same)."""
    n = len(data)
    if not n:
        return b""
    pad = (key * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(pad, "big")).to_bytes(n, "big")


def ws_frame(opcode, payload, fin=True, mask=None):
    """One frame. Servers send unmasked; clients pass a 4-byte mask."""
    head = bytes([(0x80 if fin else 0) | opcode])
    bit = 0x80 if mask else 0
    n = len(payload)
    if n < 126:
        head += bytes([bit | n])
    elif n < 65536:
        head += bytes([bit | 126]) + struct.pack(">H", n)
    else:
        head += bytes([bit | 127]) + struct.pack(">Q", n)
    if mask:
        return head + mask + ws_mask(payload, mask)
    return head + payload


class WsError(Exception):
    """Breaks the protocol; the connection closes with this status code."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


async def ws_read_frame(reader, max_size, masked=True):
    """(fin, opcode, payload) of the next frame. Frames from a client must be
    masked, frames from a server must not be."""
    b0, b1 = await reader.readexactly(2)
    fin, opcode = bool(b0 & 0x80), b0 & 0x0F
    if b0 & 0x70 or opcode not in (WS_CONT, WS_TEXT, WS_BINARY, WS_CLOSE, WS_PING, WS_PONG):
        raise WsError(1002)   # no extensions were negotiated
    if bool(b1 & 0x80) != masked:
        raise WsError(1002)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", await reader.readexactly(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", await reader.readexactly(8))[0]
    if opcode >= WS_CLOSE and (n > 125 or not fin):
        raise WsError(1002)
    if n > max_size:
        raise WsError(1009)
    key = await reader.readexactly(4) if masked else None
    data = await reader.readexactly(n)
    return fin, opcode, (ws_mask(data, key) if key else data)


class WebSocket:
    """One WebSocket connection after the handshake: whole messages in, frames
    out. Answers pings and closes itself. client=True is the other end (masks
    what it sends), used by the tests."""

    def __init__(self, reader, writer, max_size=MAX_PAYLOAD + 5, client=False):
        self.reader, self.writer = reader, writer
        self.max_size, self.client = max_size, client
        self.closed = False

    def send(self, opcode, payload, fin=True):
        if not self.closed and not self.writer.is_closing():
            self.writer.write(ws_frame(opcode, payload, fin, os.urandom(4) if self.client else None))

    async def recv(self):
        """The next whole message as (opcode, bytes), or None once closed."""
        parts, kind, size = [], None, 0
        while True:
            try:
                fin, opcode, data = await ws_read_frame(self.reader, self.max_size, masked=not self.client)
                if opcode == WS_PING:
                    self.send(WS_PONG, data)
                    continue
                if opcode == WS_PONG:
                    continue
                if opcode == WS_CLOSE:
                    code = struct.unpack(">H", data[:2])[0] if len(data) >= 2 else 1000
                    self.close(code if code in (1000, 1001) else 1000)
                    return None
                if (opcode == WS_CONT) != (kind is not None):
                    raise WsError(1002)   # continuation without a start, or a new start mid-message
                kind = kind if opcode == WS_CONT else opcode
                size += len(data)
                if size > self.max_size:
                    raise WsError(1009)
                parts.append(data)
                if fin:
                    return kind, b"".join(parts)
            except WsError as e:
                self.close(e.code)
                return None
            except (asyncio.IncompleteReadError, ConnectionError, ValueError):
                self.close()
                return None

    def close(self, code=1000):
        if not self.closed:
            self.send(WS_CLOSE, struct.pack(">H", code))
            self.closed = True
        self.writer.close()


# ---- connection ------------------------------------------------------------

class TcpTransport:
    """Wire frames straight on a TCP stream (the phone app, port 7890)."""

    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer

    async def recv(self):
        """The next (type, payload), or None when the stream isn't speaking Wire."""
        kind, length = struct.unpack(">BI", await self.reader.readexactly(5))
        if kind not in (CONTROL, VIDEO_FORMAT, VIDEO_FRAME, TERMINAL) or length > MAX_PAYLOAD:
            return None
        return kind, await self.reader.readexactly(length)

    def send(self, data):
        if not self.writer.is_closing():
            self.writer.write(data)

    async def drain(self):
        await self.writer.drain()

    def close(self):
        self.writer.close()


class WsTransport:
    """Wire frames over a WebSocket (Panes Web): each binary message is one
    whole frame. Text messages are ignored."""

    def __init__(self, ws):
        self.ws = ws

    async def recv(self):
        while True:
            msg = await self.ws.recv()
            if msg is None:
                return None
            opcode, data = msg
            if opcode != WS_BINARY:
                continue
            if len(data) < 5:
                return None
            kind, length = struct.unpack(">BI", data[:5])
            if kind not in (CONTROL, VIDEO_FORMAT, VIDEO_FRAME, TERMINAL) or length != len(data) - 5:
                return None
            return kind, data[5:]

    def send(self, data):
        self.ws.send(WS_BINARY, data)

    async def drain(self):
        await self.ws.writer.drain()

    def close(self):
        self.ws.close()


class Session:
    """One tab's connection, whichever transport carries it."""

    def __init__(self, transport, peers):
        self.transport, self.peers = transport, peers
        self.terminal = None

    def send(self, data):
        self.transport.send(data)

    async def launch(self, msg):
        app = next((a for a in desktop_apps() if a["id"] == msg.get("app")), None)
        if not XPRA.available or app is None:
            self.send(control({"op": "error", "error": "That app isn't available here."}))
            return
        loop = asyncio.get_running_loop()
        try:
            session = XPRA.launch(session_name(msg.get("name")), app)
        except OSError as e:
            self.send(control({"op": "error", "error": f"Couldn't start {app['name']}: {e}"}))
            return
        if not await loop.run_in_executor(None, XPRA.ready, session):
            self.send(control({"op": "error", "error": f"{app['name']} didn't start (see xpra log on the box)."}))
            return
        self.send(control({"op": "launched", "app": app["name"], "url": Xpra.url(session, XPRA.sound)}))

    async def run(self):
        try:
            while True:
                got = await self.transport.recv()
                if got is None:
                    break
                kind, payload = got
                if kind == CONTROL:
                    try:
                        self.handle(json.loads(payload))
                    except (ValueError, TypeError):
                        pass
                elif kind == TERMINAL and self.terminal:
                    self.terminal.write(payload)
                await self.transport.drain()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            if self.terminal:
                self.terminal.close()
            self.transport.close()

    def handle(self, msg):
        op = msg.get("op")
        if op == "hello":
            features = ["terminal", "devices"] + (["apps"] if XPRA.available else [])
            reply = {"op": "hello", "version": VERSION, "machine": socket.gethostname(), "features": features}
            web = self.peers.web_address()
            if web:
                reply["web"] = web
            self.send(control(reply))
        elif op == "list":
            self.send(control({"op": "windows", "windows": []}))
        elif op == "apps":
            apps = desktop_apps() if XPRA.available else []
            self.send(control({"op": "apps", "apps": [{"id": a["id"], "name": a["name"]} for a in apps]}))
        elif op == "launch":
            asyncio.ensure_future(self.launch(msg))
        elif op == "end":
            # The phone closed the tab on purpose: stop what it was attached to.
            name = session_name(msg.get("name"))
            if not is_panes_session(name):
                return
            if self.terminal:
                self.terminal.close()
                self.terminal = None
            kill_tmux_session(name)
            XPRA.end(name)
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
        elif op == "device":
            self.send(control({"op": "inbox", "sent": DEVICES.report(msg.get("device"))}))
        elif op == "devices":
            me = (msg.get("device") or {}).get("id") if isinstance(msg.get("device"), dict) else None
            self.send(control({"op": "devices", "devices": DEVICES.list(me)}))
        elif op == "send":
            if not DEVICES.send(msg.get("tab"), msg.get("to"), msg.get("name") or "Another device", secrets.token_hex(8)):
                self.send(control({"op": "error", "error": "That device hasn't checked in with this machine."}))
        elif op == "forget":
            d = msg.get("device")
            if isinstance(d, dict) and DEVICE_ID.match(str(d.get("id", ""))):
                DEVICES.forget(d["id"])
        elif op == "resize" and self.terminal:
            self.terminal.resize(int(msg.get("cols") or 80), int(msg.get("rows") or 24))


# ---- Panes Web (docs/WEB.md) -----------------------------------------------

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
    ".json": "application/json", ".webmanifest": "application/manifest+json", ".map": "application/json", ".wasm": "application/wasm",
    ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".gif": "image/gif", ".webp": "image/webp", ".ico": "image/x-icon", ".txt": "text/plain; charset=utf-8",
    ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf",
}

# Headers that decide who's asking: a repeat of any of them is refused, not guessed at.
SINGLE_HEADERS = ("host", "origin", "tailscale-user-login", "upgrade", "sec-websocket-key")


def parse_request_head(head):
    """(method, target, headers by lowercase name, raw header pairs) of an
    HTTP/1.x request head. ValueError when it isn't one."""
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) != 3 or not parts[2].startswith("HTTP/1.") or not parts[1].startswith("/"):
        raise ValueError("bad request line")
    headers, raw = {}, []
    for line in lines[1:]:
        if not line:
            continue
        name, sep, value = line.partition(":")
        if not sep or not name or name != name.strip():
            raise ValueError("bad header")
        key, value = name.lower(), value.strip()
        if key in headers and key in SINGLE_HEADERS:
            raise ValueError(f"repeated {name}")
        headers[key] = value
        raw.append((name, value))
    return parts[0], parts[1], headers, raw


def web_request_allowed(headers, owner, port):
    """Through tailscale serve: only the machine's owner. Straight from a
    local process (no Tailscale header): only when addressed to loopback."""
    login = headers.get("tailscale-user-login")
    if login is not None:
        return owner is not None and login == owner
    return headers.get("host", "").lower() in (f"127.0.0.1:{port}", f"localhost:{port}")


def web_origin_allowed(origin, suffix, port):
    """For WebSocket upgrades: only our own pages, so other sites open in the
    browser can't drive this machine."""
    if not origin:
        return False
    if origin in (f"http://127.0.0.1:{port}", f"http://localhost:{port}"):
        return True
    try:
        u = urllib.parse.urlsplit(origin)
        host, tls_port = u.hostname or "", u.port
    except ValueError:
        return False
    if u.scheme != "https" or tls_port != WEB_TLS_PORT or u.username or u.password or u.path or u.query:
        return False
    return bool(suffix) and host.endswith("." + suffix) and len(host) > len(suffix) + 1


def static_path(root, path):
    """The file under root that a URL path names, or None (missing, or outside root)."""
    path = urllib.parse.unquote(path)
    if "\0" in path:
        return None
    if path == "/":
        path = "/index.html"
    root = os.path.realpath(root)
    full = os.path.realpath(os.path.join(root, path.lstrip("/")))
    if os.path.commonpath([root, full]) != root or not os.path.isfile(full):
        return None
    return full


def response(status, reason, body=b"", ctype="text/plain; charset=utf-8", extra=()):
    head = [f"HTTP/1.1 {status} {reason}", f"Content-Type: {ctype}", f"Content-Length: {len(body)}",
            "Connection: close", *extra]
    return ("\r\n".join(head) + "\r\n\r\n").encode("latin-1") + body


async def pipe(reader, writer):
    """Copies until EOF, then passes the EOF on."""
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            if writer.can_write_eof() and not writer.is_closing():
                writer.write_eof()
            else:
                writer.close()
        except (OSError, RuntimeError):
            writer.close()


class WebServer:
    """HTTP on loopback: the web client's files, /ws for tabs, /xpra/<session>/
    for app tabs. One request per connection."""

    def __init__(self, port, peers, xpra, root):
        self.port, self.peers, self.xpra, self.root = port, peers, xpra, root

    async def handle(self, reader, writer):
        try:
            try:
                head = await reader.readuntil(b"\r\n\r\n")
                method, target, headers, raw = parse_request_head(head)
            except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
                return
            except ValueError:
                writer.write(response(400, "Bad Request", b"Bad request\n"))
                return
            loop = asyncio.get_running_loop()
            # Only this account (or tailscaled, which publishes Panes Web) may call in.
            peer = writer.get_extra_info("peername") or ("", 0)
            here = writer.get_extra_info("sockname") or ("", 0)
            if not loopback_caller_allowed(peer[1], here[1], extra_uids=process_uids("tailscaled")):
                print(f"web refused a caller on port {peer[1]}: another account", flush=True)
                writer.write(response(403, "Forbidden", b"Forbidden\n"))
                return
            owner = None
            if "tailscale-user-login" in headers:
                owner = await loop.run_in_executor(None, self.peers.owner_login)
            if not web_request_allowed(headers, owner, self.port):
                print(f"web refused {headers.get('tailscale-user-login') or headers.get('host')}", flush=True)
                writer.write(response(403, "Forbidden", b"Forbidden\n"))
                return
            upgrade = headers.get("upgrade", "").lower() == "websocket"
            if upgrade:
                suffix = await loop.run_in_executor(None, self.peers.magic_dns_suffix)
                if not web_origin_allowed(headers.get("origin"), suffix, self.port):
                    print(f"web refused origin {headers.get('origin')}", flush=True)
                    writer.write(response(403, "Forbidden", b"Forbidden\n"))
                    return
            path, _, query = target.partition("?")
            if path == "/ws":
                if not upgrade:
                    writer.write(response(426, "Upgrade Required", b"WebSocket only\n", extra=["Upgrade: websocket"]))
                    return
                await self.websocket(reader, writer, method, headers)
            elif path == "/xpra" or path.startswith("/xpra/"):
                await self.proxy(reader, writer, method, path, query, raw, upgrade)
            else:
                self.static(writer, method, path)
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                if not writer.is_closing():
                    await writer.drain()
            except (ConnectionError, OSError):
                pass
            writer.close()

    def static(self, writer, method, path):
        if method not in ("GET", "HEAD"):
            writer.write(response(405, "Method Not Allowed", b"Method not allowed\n", extra=["Allow: GET, HEAD"]))
            return
        full = static_path(self.root, path)
        if full is None:
            writer.write(response(404, "Not Found", b"Not found\n"))
            return
        with open(full, "rb") as f:
            body = f.read()
        ctype = CONTENT_TYPES.get(os.path.splitext(full)[1].lower(), "application/octet-stream")
        data = response(200, "OK", body, ctype, ["Cache-Control: no-cache", "X-Content-Type-Options: nosniff"])
        writer.write(data[:len(data) - len(body)] if method == "HEAD" else data)

    async def websocket(self, reader, writer, method, headers):
        key = headers.get("sec-websocket-key", "")
        try:
            key_ok = len(base64.b64decode(key, validate=True)) == 16
        except ValueError:
            key_ok = False
        if method != "GET" or headers.get("sec-websocket-version") != "13" or not key_ok \
                or "upgrade" not in [t.strip().lower() for t in headers.get("connection", "").split(",")]:
            writer.write(response(400, "Bad Request", b"Bad WebSocket handshake\n"))
            return
        writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Accept: {ws_accept_key(key)}\r\n\r\n").encode())
        sock = writer.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        await Session(WsTransport(WebSocket(reader, writer)), self.peers).run()

    async def proxy(self, reader, writer, method, path, query, raw, upgrade):
        """Forwards to a registered Xpra session's loopback port, minus the
        /xpra/<session> prefix (Xpra's client uses its page path, /xpra/<session>/,
        as its WebSocket path, which lands on / here). Nothing else is reachable."""
        name, slash, sub = path[len("/xpra/"):].partition("/")
        session = self.xpra.sessions.get(name) if name and session_name(name) == name else None
        if session is None:
            writer.write(response(404, "Not Found", b"No such app session\n"))
            return
        if not slash:
            location = f"/xpra/{name}/" + (f"?{query}" if query else "")
            writer.write(response(308, "Permanent Redirect", extra=[f"Location: {location}"]))
            return
        port = session["port"]
        try:
            up_reader, up_writer = await asyncio.open_connection("127.0.0.1", port)
        except OSError:
            writer.write(response(502, "Bad Gateway", b"App session isn't answering\n"))
            return
        try:
            target = "/" + sub + (f"?{query}" if query else "")
            hop = ("host", "connection", "keep-alive", "proxy-connection", "upgrade", "te", "trailer")
            lines = [f"{method} {target} HTTP/1.1", f"Host: 127.0.0.1:{port}"]
            lines += [f"{n}: {v}" for n, v in raw if n.lower() not in hop and not n.lower().startswith("tailscale-")]
            lines += ["Connection: Upgrade", "Upgrade: websocket"] if upgrade else ["Connection: close"]
            up_writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
            # The request body (if any) and, after a 101, WebSocket bytes flow
            # this way until the browser hangs up.
            outbound = asyncio.ensure_future(pipe(reader, up_writer))
            try:
                reply = await up_reader.readuntil(b"\r\n\r\n")
            except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
                outbound.cancel()
                writer.write(response(502, "Bad Gateway", b"Bad reply from the app session\n"))
                return
            status_line, *rest = reply.decode("latin-1").split("\r\n")
            if status_line.split(" ")[1:2] != ["101"]:
                # One response per connection: make sure the browser knows.
                rest = [h for h in rest if h and h.split(":", 1)[0].strip().lower() not in ("connection", "keep-alive")]
                reply = ("\r\n".join([status_line, *rest, "Connection: close"]) + "\r\n\r\n").encode("latin-1")
            writer.write(reply)
            await pipe(up_reader, writer)
            outbound.cancel()
        finally:
            up_writer.close()


async def start_web(port, peers, xpra, root, host="127.0.0.1"):
    """Starts the web server; port 0 picks one (tests). Returns the asyncio server."""
    web = WebServer(port, peers, xpra, root)
    server = await asyncio.start_server(web.handle, host=host, port=port)
    web.port = server.sockets[0].getsockname()[1]
    return server


async def main():
    port = int(os.environ.get("PANES_PORT", "7890"))
    web_port = int(os.environ.get("PANES_WEB_PORT", str(WEB_PORT)))
    web_dir = os.environ.get("PANES_WEB_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
    peers = Peers()
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, peers.status)   # so hello doesn't wait on tailscale

    async def accept(reader, writer):
        peer = writer.get_extra_info("peername") or ("", 0)
        ip = peer[0]
        allowed = await loop.run_in_executor(None, peers.allowed, ip)
        if allowed and is_loopback(ip):
            here = writer.get_extra_info("sockname") or ("", 0)
            allowed = loopback_caller_allowed(peer[1], here[1])
            if not allowed:
                print(f"refused a loopback caller on port {peer[1]}: another account", flush=True)
        if not allowed:
            writer.close()
            return
        sock = writer.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        await Session(TcpTransport(reader, writer), peers).run()

    server = await asyncio.start_server(accept, host=None, port=port)
    # Loopback only: tailscale serve publishes it to the tailnet as HTTPS.
    web = await start_web(web_port, peers, XPRA, web_dir)
    print(f"Panes agent listening on {port}, web on 127.0.0.1:{web_port} ({web_dir})", flush=True)
    async with server, web:
        await asyncio.gather(server.serve_forever(), web.serve_forever())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
