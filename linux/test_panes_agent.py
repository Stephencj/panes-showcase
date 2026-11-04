"""Unit tests for the Linux agent: python3 -m unittest linux/test_panes_agent.py"""
import asyncio
import json
import os
import secrets
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import panes_agent as pa  # noqa: E402


class WireTests(unittest.TestCase):
    def test_frame_layout_matches_the_swift_side(self):
        f = pa.frame(pa.TERMINAL, b"ls\r")
        self.assertEqual(f[0], 4)
        self.assertEqual(struct.unpack(">I", f[1:5])[0], 3)
        self.assertEqual(f[5:], b"ls\r")

    def test_session_names_are_sanitized_like_wire_sessionName(self):
        self.assertEqual(pa.session_name("panes-1A_b"), "panes-1A_b")
        self.assertEqual(pa.session_name("x; rm -rf ~"), "xrm-rf")
        self.assertEqual(pa.session_name("$(reboot)"), "reboot")
        self.assertEqual(pa.session_name(None), "panes")
        self.assertEqual(pa.session_name("é'\""), "panes")


class PeerTests(unittest.TestCase):
    def test_only_loopback_and_tailnet_are_candidates(self):
        self.assertTrue(pa.is_loopback("127.0.0.1"))
        self.assertTrue(pa.is_loopback("::ffff:127.0.0.1"))
        self.assertTrue(pa.is_tailnet("100.64.0.30"))
        self.assertTrue(pa.is_tailnet("fd7a:115c:a1e0::1%tailscale0"))
        self.assertFalse(pa.is_tailnet("100.128.0.1"))
        self.assertFalse(pa.is_tailnet("192.168.1.20"))
        self.assertFalse(pa.Peers().allowed("192.168.1.20"))
        self.assertTrue(pa.Peers().allowed("127.0.0.1"))


class AppTests(unittest.TestCase):
    def test_field_codes_are_stripped(self):
        self.assertEqual(pa.strip_field_codes("gedit %U"), "gedit")
        self.assertEqual(pa.strip_field_codes("env A=1 app --x %f --y"), "env A=1 app --x --y")
        self.assertEqual(pa.strip_field_codes("printf 100%%"), "printf 100%")

    def test_desktop_files_are_filtered(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            def write(name, body):
                with open(os.path.join(d, name), "w") as f:
                    f.write("[Desktop Entry]\n" + body)
            write("gedit.desktop", "Type=Application\nName=Text Editor\nExec=gedit %U\n")
            write("hidden.desktop", "Type=Application\nName=Hidden\nExec=x\nNoDisplay=true\n")
            write("term.desktop", "Type=Application\nName=Htop\nExec=htop\nTerminal=true\n")
            write("link.desktop", "Type=Link\nName=Site\nURL=http://x\n")
            write("broken.desktop", "not a desktop file")
            apps = pa.desktop_apps([d])
        self.assertEqual(apps, [{"id": "gedit", "name": "Text Editor", "command": "gedit"}])

    def test_url_is_relative_through_the_proxy_and_carries_the_password(self):
        url = pa.Xpra.url({"name": "panes-abc123", "host": "127.0.0.1", "port": 14500, "password": "pw"})
        self.assertTrue(url.startswith("/xpra/panes-abc123/index.html?password=pw&submit=true&"))
        self.assertIn("sound=false", url)
        self.assertIn("sound=true", pa.Xpra.url({"name": "panes-x", "port": 1, "password": "p"}, sound=True))
        self.assertEqual(pa.Xpra.HOST, "127.0.0.1")


class EndTests(unittest.TestCase):
    def test_only_panes_sessions_can_be_ended(self):
        self.assertTrue(pa.is_panes_session("panes-1a2b3c"))
        self.assertFalse(pa.is_panes_session("work"))
        self.assertFalse(pa.is_panes_session("panes-"))
        self.assertFalse(pa.is_panes_session("mypanes-x"))

    def test_ending_an_unknown_session_is_harmless(self):
        pa.Xpra().end("nope")
        pa.kill_tmux_session("panes-does-not-exist")

# ---- Panes Web -------------------------------------------------------------

OWNER = "alice@example.com"
STATUS = {"Self": {"UserID": 7, "DNSName": "box.tailnet-example.ts.net."}, "MagicDNSSuffix": "tailnet-example.ts.net",
          "User": {"7": {"LoginName": OWNER}}}


class FakeWriter:
    def __init__(self):
        self.data, self.closed = bytearray(), False

    def write(self, b):
        self.data += b

    def is_closing(self):
        return self.closed

    def close(self):
        self.closed = True

    async def drain(self):
        pass


def reader_with(data):
    r = asyncio.StreamReader()
    r.feed_data(data)
    r.feed_eof()
    return r


def frames_in(data):
    """Parses unmasked server frames out of bytes: [(fin, opcode, payload)]."""
    async def go():
        r, out = reader_with(bytes(data)), []
        while True:
            try:
                out.append(await pa.ws_read_frame(r, 1 << 30, masked=False))
            except asyncio.IncompleteReadError:
                return out
    return asyncio.run(go())


class WebSocketFramingTests(unittest.TestCase):
    def test_accept_key_matches_rfc_6455_example(self):
        self.assertEqual(pa.ws_accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

    def test_server_frames_are_unmasked_with_all_three_length_forms(self):
        for n, header_len in ((5, 2), (200, 4), (70000, 10)):
            payload = os.urandom(n)
            f = pa.ws_frame(pa.WS_BINARY, payload)
            self.assertEqual(f[0], 0x82)
            self.assertEqual(f[1] & 0x80, 0)
            self.assertEqual(len(f), header_len + n)
            self.assertEqual(frames_in(f), [(True, pa.WS_BINARY, payload)])

    def test_masking_round_trips_and_client_frames_must_be_masked(self):
        key, payload = b"\x37\xfa\x21\x3d", b"Hello"
        # RFC 6455 section 5.7 example.
        self.assertEqual(pa.ws_frame(pa.WS_TEXT, payload, mask=key), bytes.fromhex("818537fa213d7f9f4d5158"))
        self.assertEqual(pa.ws_mask(pa.ws_mask(payload, key), key), payload)

        async def go():
            ok = await pa.ws_read_frame(reader_with(pa.ws_frame(pa.WS_BINARY, b"abc", mask=key)), 100)
            self.assertEqual(ok, (True, pa.WS_BINARY, b"abc"))
            with self.assertRaises(pa.WsError) as e:
                await pa.ws_read_frame(reader_with(pa.ws_frame(pa.WS_BINARY, b"abc")), 100)
            self.assertEqual(e.exception.code, 1002)
        asyncio.run(go())

    def test_fragments_are_joined_and_pings_answered_in_between(self):
        m = lambda: os.urandom(4)
        data = (pa.ws_frame(pa.WS_BINARY, b"one ", fin=False, mask=m())
                + pa.ws_frame(pa.WS_PING, b"p", mask=m())
                + pa.ws_frame(pa.WS_CONT, b"two ", fin=False, mask=m())
                + pa.ws_frame(pa.WS_CONT, b"three", mask=m())
                + pa.ws_frame(pa.WS_TEXT, b"next", mask=m()))
        w = FakeWriter()

        async def go():
            ws = pa.WebSocket(reader_with(data), w)
            self.assertEqual(await ws.recv(), (pa.WS_BINARY, b"one two three"))
            self.assertEqual(await ws.recv(), (pa.WS_TEXT, b"next"))
            self.assertIsNone(await ws.recv())   # EOF
        asyncio.run(go())
        self.assertEqual(frames_in(w.data)[0], (True, pa.WS_PONG, b"p"))

    def test_close_is_answered(self):
        w = FakeWriter()

        async def go():
            ws = pa.WebSocket(reader_with(pa.ws_frame(pa.WS_CLOSE, struct.pack(">H", 1000), mask=b"abcd")), w)
            self.assertIsNone(await ws.recv())
        asyncio.run(go())
        self.assertEqual(frames_in(w.data), [(True, pa.WS_CLOSE, struct.pack(">H", 1000))])
        self.assertTrue(w.closed)

    def test_oversized_messages_close_with_1009(self):
        for data in (pa.ws_frame(pa.WS_BINARY, b"x" * 101, mask=b"abcd"),
                     pa.ws_frame(pa.WS_BINARY, b"x" * 60, fin=False, mask=b"abcd")
                     + pa.ws_frame(pa.WS_CONT, b"x" * 60, mask=b"abcd")):
            w = FakeWriter()

            async def go():
                self.assertIsNone(await pa.WebSocket(reader_with(data), w, max_size=100).recv())
            asyncio.run(go())
            self.assertEqual(frames_in(w.data), [(True, pa.WS_CLOSE, struct.pack(">H", 1009))])

    def test_continuation_without_a_start_is_a_protocol_error(self):
        w = FakeWriter()

        async def go():
            self.assertIsNone(await pa.WebSocket(reader_with(pa.ws_frame(pa.WS_CONT, b"x", mask=b"abcd")), w).recv())
        asyncio.run(go())
        self.assertEqual(frames_in(w.data), [(True, pa.WS_CLOSE, struct.pack(">H", 1002))])

    def test_ws_transport_takes_one_wire_frame_per_binary_message_and_skips_text(self):
        data = (pa.ws_frame(pa.WS_TEXT, b"ignored", mask=b"abcd")
                + pa.ws_frame(pa.WS_BINARY, pa.frame(pa.TERMINAL, b"ls\r"), mask=b"abcd")
                + pa.ws_frame(pa.WS_BINARY, pa.frame(pa.TERMINAL, b"ls")[:-1], mask=b"abcd"))

        async def go():
            t = pa.WsTransport(pa.WebSocket(reader_with(data), FakeWriter()))
            self.assertEqual(await t.recv(), (pa.TERMINAL, b"ls\r"))
            self.assertIsNone(await t.recv())   # length doesn't match the message
        asyncio.run(go())


class WebAccessTests(unittest.TestCase):
    def test_tailscale_header_must_be_the_owner(self):
        self.assertTrue(pa.web_request_allowed({"tailscale-user-login": OWNER, "host": "x"}, OWNER, 7891))
        self.assertFalse(pa.web_request_allowed({"tailscale-user-login": "bob@x.com"}, OWNER, 7891))
        self.assertFalse(pa.web_request_allowed({"tailscale-user-login": OWNER}, None, 7891))
        self.assertFalse(pa.web_request_allowed({"tailscale-user-login": "", "host": "127.0.0.1:7891"}, OWNER, 7891))

    def test_without_the_header_host_must_be_loopback_on_our_port(self):
        self.assertTrue(pa.web_request_allowed({"host": "127.0.0.1:7891"}, None, 7891))
        self.assertTrue(pa.web_request_allowed({"host": "LocalHost:7891"}, None, 7891))
        self.assertTrue(pa.web_request_allowed({"host": "localhost:5555"}, None, 5555))
        self.assertFalse(pa.web_request_allowed({"host": "localhost:7891"}, None, 5555))
        self.assertFalse(pa.web_request_allowed({"host": "box.tailnet-example.ts.net:7443"}, OWNER, 7891))
        self.assertFalse(pa.web_request_allowed({"host": "127.0.0.1"}, None, 7891))
        self.assertFalse(pa.web_request_allowed({}, None, 7891))

    def test_origin_rules(self):
        ok = lambda o: pa.web_origin_allowed(o, "tailnet-example.ts.net", 7891)
        self.assertTrue(ok("https://linux-box.tailnet-example.ts.net:7443"))
        self.assertTrue(ok("https://my-mac-mini.tailnet-example.ts.net:7443"))
        self.assertTrue(ok("http://127.0.0.1:7891"))
        self.assertTrue(ok("http://localhost:7891"))
        for bad in (None, "", "null", "https://tailnet-example.ts.net:7443", "https://.tailnet-example.ts.net:7443",
                    "https://evil.com:7443", "https://x.tailnet-example.ts.net.evil.com:7443",
                    "https://x.eviltailnet-example.ts.net:7443", "http://x.tailnet-example.ts.net:7443",
                    "https://x.tailnet-example.ts.net", "https://x.tailnet-example.ts.net:443",
                    "https://u@x.tailnet-example.ts.net:7443", "http://127.0.0.1:7890", "https://127.0.0.1:7891",
                    "http://localhost:7891/x", "https://x.tailnet-example.ts.net:notaport"):
            self.assertFalse(ok(bad), bad)
        self.assertFalse(pa.web_origin_allowed("https://x.tailnet-example.ts.net:7443", "", 7891))

    def test_repeated_identity_headers_are_refused(self):
        with self.assertRaises(ValueError):
            pa.parse_request_head(b"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")
        with self.assertRaises(ValueError):
            pa.parse_request_head(b"GET http://x/ HTTP/1.1\r\n\r\n")
        method, target, headers, _ = pa.parse_request_head(b"GET /a?b HTTP/1.1\r\nHOST: h:1\r\n\r\n")
        self.assertEqual((method, target, headers), ("GET", "/a?b", {"host": "h:1"}))

    def test_peers_reads_owner_suffix_and_web_address_from_status(self):
        peers = pa.Peers(status=STATUS)
        self.assertEqual(peers.owner_login(), OWNER)
        self.assertEqual(peers.magic_dns_suffix(), "tailnet-example.ts.net")
        self.assertEqual(peers.web_address(), "https://box.tailnet-example.ts.net:7443")
        self.assertIsNone(pa.Peers(status={}).web_address())


class StaticTests(unittest.TestCase):
    def test_static_paths_stay_inside_the_web_folder(self):
        with tempfile.TemporaryDirectory() as d:
            root = os.path.join(d, "web")
            os.makedirs(os.path.join(root, "vendor"))
            for name in ("index.html", "vendor/x.js", "machines.json"):
                with open(os.path.join(root, name), "w") as f:
                    f.write(name)
            with open(os.path.join(d, "secret"), "w") as f:
                f.write("secret")
            os.symlink(os.path.join(d, "secret"), os.path.join(root, "link"))
            real = os.path.realpath(root)
            self.assertEqual(pa.static_path(root, "/"), os.path.join(real, "index.html"))
            self.assertEqual(pa.static_path(root, "/vendor/x.js"), os.path.join(real, "vendor/x.js"))
            self.assertEqual(pa.static_path(root, "/machines.json"), os.path.join(real, "machines.json"))
            for bad in ("/../secret", "/%2e%2e/secret", "/vendor/../../secret", "//../secret", "/link",
                        "/vendor", "/missing", "/index.html%00", "/%2fetc%2fpasswd"):
                self.assertIsNone(pa.static_path(root, bad), bad)


# ---- end to end over real sockets ------------------------------------------

async def http(port, request):
    """Sends one raw request, returns (status, headers, body) once the server hangs up."""
    r, w = await asyncio.open_connection("127.0.0.1", port)
    w.write(request.encode())
    data = await asyncio.wait_for(r.read(), 10)
    w.close()
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    headers = {k.lower(): v.strip() for k, _, v in (h.partition(":") for h in lines[1:])}
    return int(lines[0].split(" ")[1]), headers, body


async def ws_connect(port, path="/ws", extra=None):
    """A minimal WebSocket client; returns (status, WebSocket or None)."""
    key = pa.base64.b64encode(os.urandom(16)).decode()
    headers = extra if extra is not None else {"Host": f"127.0.0.1:{port}", "Origin": f"http://127.0.0.1:{port}"}
    r, w = await asyncio.open_connection("127.0.0.1", port)
    lines = [f"GET {path} HTTP/1.1", "Upgrade: websocket", "Connection: Upgrade",
             f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"] + [f"{k}: {v}" for k, v in headers.items()]
    w.write(("\r\n".join(lines) + "\r\n\r\n").encode())
    head = (await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 10)).decode("latin-1")
    status = int(head.split(" ")[1])
    if status != 101:
        w.close()
        return status, None
    assert f"Sec-WebSocket-Accept: {pa.ws_accept_key(key)}" in head, head
    return status, pa.WebSocket(r, w, client=True)


class DeviceBookTests(unittest.TestCase):
    TAB = {"machine": "Mac mini", "kind": "window", "app": "Xcode", "windowID": 7}

    def test_report_list_send_and_pick_up(self):
        clock = [1000.0]
        book = pa.DeviceBook(None, now=lambda: clock[0])
        self.assertEqual(book.report({"id": "phone-1", "name": "iPhone", "kind": "phone", "tabs": [self.TAB]}), [])
        clock[0] += 5
        book.report({"id": "web-1", "name": "Chrome on Linux", "kind": "browser", "tabs": []})
        self.assertEqual([d["id"] for d in book.list()], ["web-1", "phone-1"])
        self.assertEqual([d["id"] for d in book.list("web-1")], ["phone-1"])
        self.assertEqual(book.list("web-1")[0]["tabs"], [self.TAB])
        self.assertTrue(book.send(self.TAB, "web-1", "iPhone", "s1"))
        self.assertTrue(book.send(self.TAB, "web-1", "iPhone", "s1"))
        self.assertFalse(book.send(self.TAB, "nobody", "iPhone", "s2"))
        self.assertFalse(book.send({"kind": "window"}, "web-1", "iPhone", "s3"))
        got = book.report({"id": "web-1", "name": "Chrome on Linux", "kind": "browser", "tabs": []})
        self.assertEqual([(g["from"], g["tab"]) for g in got], [("iPhone", self.TAB)])
        self.assertEqual(book.report({"id": "web-1", "name": "x", "kind": "browser", "tabs": []}), [])

    def test_ageing_odd_input_caps_and_forget(self):
        clock = [0.0]
        book = pa.DeviceBook(None, now=lambda: clock[0])
        self.assertEqual(book.report({"id": "../etc", "tabs": []}), [])
        self.assertEqual(book.report("nope"), [])
        self.assertEqual(book.list(), [])
        book.report({"id": "a", "name": "A", "kind": "phone", "tabs": []})
        book.report({"id": "b", "name": "n" * 500, "kind": "weird",
                     "tabs": [dict(self.TAB, app=f"T{i}") for i in range(100)] + [{"evil": True}]})
        b = [d for d in book.list() if d["id"] == "b"][0]
        self.assertEqual((len(b["tabs"]), len(b["name"]), b["kind"]), (pa.DeviceBook.MAX_TABS, 60, "browser"))
        for i in range(30):
            book.send(self.TAB, "b", "A", f"s{i}")
        clock[0] = pa.DeviceBook.SENT_TTL + 1
        book.report({"id": "a", "name": "A", "kind": "phone", "tabs": []})
        self.assertEqual(book.report({"id": "b", "name": "B", "kind": "browser", "tabs": []}), [])
        book.forget("b")
        self.assertEqual([d["id"] for d in book.list()], ["a"])
        clock[0] += pa.DeviceBook.DEVICE_TTL + 1
        self.assertEqual(book.list(), [])

    def test_survives_a_restart_with_a_private_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "state", "devices.json")
            one = pa.DeviceBook(path)
            one.report({"id": "p", "name": "iPhone", "kind": "phone", "tabs": [self.TAB]})
            one.send(dict(self.TAB, app="Logic Pro"), "p", "Chrome", "s")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            two = pa.DeviceBook(path)
            self.assertEqual(two.list()[0]["tabs"], [self.TAB])
            self.assertEqual(two.report({"id": "p", "name": "iPhone", "kind": "phone", "tabs": []})[0]["tab"]["app"], "Logic Pro")

    def test_the_swift_agents_file_reads_here(self):
        # Same JSON on disk as Agent/Devices.swift writes.
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "devices.json")
            with open(path, "w") as f:
                json.dump({"devices": [{"id": "x", "name": "X", "kind": "phone", "tabs": [], "seen": 10.0}],
                           "inbox": {"x": [{"id": "s", "from": "Y", "tab": self.TAB, "at": 10.0}]}}, f)
            book = pa.DeviceBook(path, now=lambda: 20.0)
            self.assertEqual(book.report({"id": "x", "name": "X", "kind": "phone", "tabs": []})[0]["tab"], self.TAB)


class LoopbackOwnerTests(unittest.TestCase):
    # /proc/net/tcp: sl local_address rem_address st tx:rx tr:when retrnsmt uid ...
    TABLE = (
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
        "   0: 0100007F:1ED2 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 1\n"
        "   1: 0100007F:A1B2 0100007F:1ED2 01 00000000:00000000 00:00000000 00000000  1001        0 2 1\n"
        "   2: 0100007F:C3D4 0100007F:1ED2 01 00000000:00000000 00:00000000 00000000  1000        0 3 1\n"
        "   3: 0100007F:E5F6 0100007F:1ED3 01 00000000:00000000 00:00000000 00000000     0        0 4 1\n"
    )

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.tcp = os.path.join(self.dir.name, "tcp")
        with open(self.tcp, "w") as f:
            f.write(self.TABLE)
        self.tables = (self.tcp, os.path.join(self.dir.name, "missing"))

    def tearDown(self):
        self.dir.cleanup()

    def test_owner_is_found_by_the_port_pair(self):
        self.assertEqual(pa.socket_owner_uid(0xA1B2, 7890, self.tables), 1001)
        self.assertEqual(pa.socket_owner_uid(0xC3D4, 7890, self.tables), 1000)
        self.assertIsNone(pa.socket_owner_uid(0xA1B2, 7891, self.tables))

    def test_only_our_account_or_tailscaled_gets_in(self):
        ok = lambda p, l, extra=(): pa.loopback_caller_allowed(p, l, extra, self.tables, my_uid=1000)
        self.assertTrue(ok(0xC3D4, 7890))            # us
        self.assertFalse(ok(0xA1B2, 7890))           # another account (solbot)
        self.assertFalse(ok(0xE5F6, 7891))           # root, but tailscaled isn't root here
        self.assertTrue(ok(0xE5F6, 7891, {0}))       # tailscaled publishing Panes Web
        self.assertFalse(ok(0x9999, 7890))           # not in /proc: can't be shown to be us

    def test_without_proc_loopback_is_trusted(self):
        missing = (os.path.join(self.dir.name, "missing"),)
        self.assertTrue(pa.loopback_caller_allowed(0x9999, 7890, (), missing, my_uid=1000))

    def test_process_uids_reads_comm(self):
        proc = os.path.join(self.dir.name, "proc")
        for pid, name in ((10, "tailscaled"), (11, "bash")):
            os.makedirs(os.path.join(proc, str(pid)))
            with open(os.path.join(proc, str(pid), "comm"), "w") as f:
                f.write(name + "\n")
        self.assertEqual(pa.process_uids("tailscaled", proc), {os.getuid()})
        self.assertEqual(pa.process_uids("nope", proc), set())


class WebEndToEndTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.dir = tempfile.TemporaryDirectory()
        with open(os.path.join(self.dir.name, "index.html"), "w") as f:
            f.write("<!doctype html><title>Panes</title>")
        with open(os.path.join(self.dir.name, "machines.json"), "w") as f:
            f.write("[]")
        with open(os.path.join(self.dir.name, "manifest.webmanifest"), "w") as f:
            f.write('{"name":"Panes"}')
        self.xpra = pa.Xpra()
        self.server = await pa.start_web(0, pa.Peers(status=STATUS), self.xpra, self.dir.name)
        self.port = self.server.sockets[0].getsockname()[1]

    async def asyncTearDown(self):
        self.server.close()
        await self.server.wait_closed()
        self.dir.cleanup()

    async def test_static_files_and_who_may_fetch_them(self):
        p = self.port
        status, headers, body = await http(p, f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n")
        self.assertEqual((status, headers["content-type"], body),
                         (200, "text/html; charset=utf-8", b"<!doctype html><title>Panes</title>"))
        status, headers, body = await http(p, f"GET /machines.json HTTP/1.1\r\nHost: localhost:{p}\r\n\r\n")
        self.assertEqual((status, headers["content-type"], body), (200, "application/json", b"[]"))
        # The install manifest needs its own type, or browsers won't offer to install the web app.
        status, headers, body = await http(p, f"GET /manifest.webmanifest HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n")
        self.assertEqual((status, headers["content-type"], body), (200, "application/manifest+json", b'{"name":"Panes"}'))
        tailnet = "Host: box.tailnet-example.ts.net:7443\r\nTailscale-User-Login: "
        self.assertEqual((await http(p, f"GET / HTTP/1.1\r\n{tailnet}{OWNER}\r\n\r\n"))[0], 200)
        self.assertEqual((await http(p, f"GET / HTTP/1.1\r\n{tailnet}bob@x.com\r\n\r\n"))[0], 403)
        self.assertEqual((await http(p, "GET / HTTP/1.1\r\nHost: box.tailnet-example.ts.net:7443\r\n\r\n"))[0], 403)
        self.assertEqual((await http(p, f"GET /../../etc/passwd HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n"))[0], 404)
        self.assertEqual((await http(p, f"GET /nope.js HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n"))[0], 404)
        self.assertEqual((await http(p, f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n"))[0], 426)

    async def test_websocket_upgrades_check_identity_and_origin(self):
        p = self.port
        self.assertEqual((await ws_connect(p, extra={"Host": f"127.0.0.1:{p}"}))[0], 403)
        self.assertEqual((await ws_connect(p, extra={"Host": f"127.0.0.1:{p}", "Origin": "https://evil.com"}))[0], 403)
        self.assertEqual((await ws_connect(p, extra={"Host": "evil.com", "Origin": f"http://127.0.0.1:{p}"}))[0], 403)
        tailnet = {"Host": "box.tailnet-example.ts.net:7443", "Origin": "https://linux-box.tailnet-example.ts.net:7443"}
        self.assertEqual((await ws_connect(p, extra={**tailnet, "Tailscale-User-Login": "bob@x.com"}))[0], 403)
        status, ws = await ws_connect(p, extra={**tailnet, "Tailscale-User-Login": OWNER})
        self.assertEqual(status, 101)
        ws.close()

    async def test_terminal_over_websocket(self):
        status, ws = await ws_connect(self.port)
        self.assertEqual(status, 101)

        async def next_control():
            while True:
                opcode, data = await asyncio.wait_for(ws.recv(), 10)
                if data[0] == pa.CONTROL:
                    return json.loads(data[5:])

        ws.send(pa.WS_TEXT, b"text messages are ignored")
        ws.send(pa.WS_BINARY, pa.control({"op": "hello", "version": pa.VERSION}))
        hello = await next_control()
        self.assertEqual(hello["op"], "hello")
        self.assertIn("terminal", hello["features"])
        self.assertEqual(hello["web"], "https://box.tailnet-example.ts.net:7443")

        name = "panes-t" + secrets.token_hex(3)
        ws.send(pa.WS_BINARY, pa.control({"op": "terminal", "name": name, "cols": 80, "rows": 24}))
        self.assertEqual(await next_control(), {"op": "terminalOpened", "name": name})
        ws.send(pa.WS_BINARY, pa.frame(pa.TERMINAL, b"echo PANES_$((6*7))\r"))
        out = b""
        try:
            while b"PANES_42" not in out:
                opcode, data = await asyncio.wait_for(ws.recv(), 20)
                if data[0] == pa.TERMINAL:
                    out += data[5:]
        finally:
            ws.send(pa.WS_BINARY, pa.control({"op": "end", "name": name}))
            await asyncio.sleep(0.3)
            ws.close()
        self.assertIn(b"PANES_42", out)


class XpraProxyTests(unittest.IsolatedAsyncioTestCase):
    """A stand-in Xpra: plain HTTP that reports the path it got, and a
    WebSocket echo."""

    async def asyncSetUp(self):
        self.seen = []

        async def fake_xpra(reader, writer):
            head = await reader.readuntil(b"\r\n\r\n")
            method, target, headers, _ = pa.parse_request_head(head)
            self.seen.append((method, target, headers))
            if headers.get("upgrade") == "websocket":
                writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                              f"Sec-WebSocket-Accept: {pa.ws_accept_key(headers['sec-websocket-key'])}\r\n\r\n")
                             .encode())
                ws = pa.WebSocket(reader, writer)
                while (msg := await ws.recv()) is not None:
                    ws.send(*msg)
                return
            body = f"{method} {target}".encode()
            # Keep-alive style reply: the proxy must still end it with Connection: close.
            writer.write(f"HTTP/1.1 200 OK\r\nContent-Length: {len(body)}\r\nConnection: keep-alive\r\n\r\n"
                         .encode() + body)
            await writer.drain()
            writer.close()

        self.upstream = await asyncio.start_server(fake_xpra, host="127.0.0.1", port=0)
        xpra = pa.Xpra()
        xpra.sessions["panes-fake"] = {"port": self.upstream.sockets[0].getsockname()[1]}
        self.dir = tempfile.TemporaryDirectory()
        self.server = await pa.start_web(0, pa.Peers(status=STATUS), xpra, self.dir.name)
        self.port = self.server.sockets[0].getsockname()[1]

    async def asyncTearDown(self):
        for s in (self.server, self.upstream):
            s.close()
            await s.wait_closed()
        self.dir.cleanup()

    async def test_http_goes_to_the_session_minus_the_prefix(self):
        p = self.port
        status, headers, body = await http(
            p, f"GET /xpra/panes-fake/js/Client.js?v=1 HTTP/1.1\r\nHost: box.tailnet-example.ts.net:7443\r\n"
               f"Tailscale-User-Login: {OWNER}\r\nConnection: keep-alive\r\n\r\n")
        self.assertEqual((status, body), (200, b"GET /js/Client.js?v=1"))
        self.assertEqual(headers["connection"], "close")
        method, target, sent = self.seen[-1]
        self.assertEqual(sent["host"], f"127.0.0.1:{self.upstream.sockets[0].getsockname()[1]}")
        self.assertEqual(sent["connection"], "close")
        self.assertNotIn("tailscale-user-login", sent)
        status, _, body = await http(
            p, f"GET /xpra/panes-fake/index.html?password=pw HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n")
        self.assertEqual((status, body), (200, b"GET /index.html?password=pw"))

    async def test_unknown_sessions_and_bad_names_404_and_access_rules_apply(self):
        p = self.port
        for path in ("/xpra/panes-nope/", "/xpra/", "/xpra", "/xpra/panes%2dfake/", "/xpra/../panes-fake/"):
            self.assertEqual((await http(p, f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n"))[0], 404, path)
        status, headers, _ = await http(p, f"GET /xpra/panes-fake?x=1 HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n")
        self.assertEqual((status, headers["location"]), (308, "/xpra/panes-fake/?x=1"))
        self.assertEqual((await http(p, "GET /xpra/panes-fake/ HTTP/1.1\r\nHost: evil.com\r\n\r\n"))[0], 403)
        self.assertEqual(self.seen, [])

    async def test_websocket_is_piped_to_the_session_root(self):
        p = self.port
        evil = {"Host": f"127.0.0.1:{p}", "Origin": "https://evil.com"}
        self.assertEqual((await ws_connect(p, "/xpra/panes-fake/", evil))[0], 403)
        status, ws = await ws_connect(p, "/xpra/panes-fake/", {"Host": "box.tailnet-example.ts.net:7443",
                                                               "Origin": "https://box.tailnet-example.ts.net:7443",
                                                               "Tailscale-User-Login": OWNER})
        self.assertEqual(status, 101)
        ws.send(pa.WS_BINARY, b"\x00xpra bytes")
        self.assertEqual(await asyncio.wait_for(ws.recv(), 10), (pa.WS_BINARY, b"\x00xpra bytes"))
        ws.send(pa.WS_BINARY, b"x" * 100000)
        self.assertEqual(await asyncio.wait_for(ws.recv(), 10), (pa.WS_BINARY, b"x" * 100000))
        ws.close()
        method, target, sent = self.seen[-1]
        self.assertEqual((method, target, sent["upgrade"]), ("GET", "/", "websocket"))


if __name__ == "__main__":
    unittest.main()
