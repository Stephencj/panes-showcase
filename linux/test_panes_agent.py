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


if __name__ == "__main__":
    unittest.main()
