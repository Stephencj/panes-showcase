"""Unit tests for the Linux agent: python3 -m unittest linux/test_panes_agent.py"""
import os
import struct
import sys
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

    def test_url_carries_the_password_and_brackets_ipv6(self):
        url = pa.Xpra.url({"host": "100.64.0.20", "port": 14500, "password": "pw"})
        self.assertTrue(url.startswith("http://100.64.0.20:14500/index.html?password=pw&"))
        self.assertIn("[fd7a::1]", pa.Xpra.url({"host": "fd7a::1", "port": 1, "password": "p"}))


class EndTests(unittest.TestCase):
    def test_ending_an_unknown_session_is_harmless(self):
        pa.Xpra().end("nope")
        pa.kill_tmux_session("panes-does-not-exist")


if __name__ == "__main__":
    unittest.main()
