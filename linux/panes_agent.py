#!/usr/bin/env python3
"""Panes agent for Linux: serves terminal tabs (and, with Xpra, app windows)
to the Panes app on the phone. Standard library only.

Same wire format as the Mac agent (Shared/Wire.swift): TCP, one connection
per tab, frames of [type u8][length u32 big-endian][payload].

    python3 panes_agent.py            # port 7890, or PANES_PORT
"""
import asyncio
import configparser
import fcntl
import glob
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

CONTROL, VIDEO_FORMAT, VIDEO_FRAME, TERMINAL = 1, 2, 3, 4
VERSION = 1
MAX_PAYLOAD = 32 * 1024 * 1024


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
    listens only on the address the phone reached this box on, behind a random
    password that only that phone tab is told."""

    PORTS = range(14500, 14600)
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

    def _free_port(self, host):
        used = {s["port"] for s in self.sessions.values()}
        for port in self.PORTS:
            if port in used:
                continue
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                if probe.connect_ex((host, port)) != 0:
                    return port
        raise OSError("no free port for an app session")

    def launch(self, name, app, host):
        live = self.sessions.get(name)
        if live and live["proc"].poll() is None and live["app"] == app["id"]:
            return live
        if live:
            self.end(name)
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
               f"--html={self.html_dir}", "--mdns=no", "--notifications=no", "--speaker=off", "--microphone=off",
               "--webcam=no", "--printing=no", "--file-transfer=no", "--dpi=144"]
        log = open(os.path.expanduser(f"~/.local/share/panes/xpra-{name}.log"), "ab")
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        session = {"port": port, "password": password, "proc": proc, "app": app["id"], "host": host,
                   "pw_file": pw_file}
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
    def url(session):
        host = session["host"]
        if ":" in host:
            host = f"[{host}]"
        # Xpra's own web client, told to connect straight away with its password.
        return (f"http://{host}:{session['port']}/index.html?password={session['password']}"
                "&submit=true&sound=false&floating_menu=false&clipboard=true&swap_keys=false")


XPRA = Xpra()


def kill_tmux_session(name):
    if is_panes_session(name) and shutil.which("tmux"):
        subprocess.run(["tmux", "kill-session", "-t", f"={session_name(name)}"], capture_output=True)


# ---- connection ------------------------------------------------------------

class Session:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.terminal = None

    def send(self, data):
        if not self.writer.is_closing():
            self.writer.write(data)

    async def launch(self, msg):
        app = next((a for a in desktop_apps() if a["id"] == msg.get("app")), None)
        if not XPRA.available or app is None:
            self.send(control({"op": "error", "error": "That app isn't available here."}))
            return
        # Serve the app on the address the phone reached us on (the tailnet address).
        host = self.writer.get_extra_info("sockname")[0]
        if host.startswith("::ffff:"):
            host = host[7:]
        loop = asyncio.get_running_loop()
        try:
            session = XPRA.launch(session_name(msg.get("name")), app, host)
        except OSError as e:
            self.send(control({"op": "error", "error": f"Couldn't start {app['name']}: {e}"}))
            return
        if not await loop.run_in_executor(None, XPRA.ready, session):
            self.send(control({"op": "error", "error": f"{app['name']} didn't start (see xpra log on the box)."}))
            return
        self.send(control({"op": "launched", "app": app["name"], "url": Xpra.url(session)}))

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
            features = ["terminal"] + (["apps"] if XPRA.available else [])
            self.send(control({"op": "hello", "version": VERSION, "machine": socket.gethostname(),
                               "features": features}))
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
