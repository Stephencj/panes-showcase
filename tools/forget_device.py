#!/usr/bin/env python3
"""Tidy up after a manual test: end the panes- sessions a test device had open
on a machine, and take the device off that machine's list.

    python3 tools/forget_device.py <host> "<device name>" [port]
"""
import json
import socket
import struct
import sys
import time


def call(host, port, msgs, want=None):
    s = socket.create_connection((host, port), timeout=8)

    def send(m):
        b = json.dumps(m).encode()
        s.sendall(bytes([1]) + struct.pack(">I", len(b)) + b)
    send({"op": "hello", "version": 1})
    for m in msgs:
        send(m)
    buf, out = b"", None
    while want and out is None:
        buf += s.recv(65536)
        while len(buf) >= 5:
            t, n = buf[0], struct.unpack(">I", buf[1:5])[0]
            if len(buf) < 5 + n:
                break
            p, buf = buf[5:5 + n], buf[5 + n:]
            if t == 1 and json.loads(p).get("op") == want:
                out = json.loads(p)
    if not want:
        time.sleep(0.5)   # let the agent read it before the socket closes
    s.close()
    return out


host, name = sys.argv[1], sys.argv[2]
port = int(sys.argv[3]) if len(sys.argv) > 3 else 7890
for d in call(host, port, [{"op": "devices"}], "devices")["devices"]:
    if d["name"] != name:
        continue
    for t in d["tabs"]:
        if (t.get("session") or "").startswith("panes-"):
            call(host, port, [{"op": "end", "name": t["session"]}])
            print("ended", t["kind"], t["session"])
    call(host, port, [{"op": "forget", "device": {"id": d["id"]}}])
    print("forgot", d["id"])
print("left:", [d["name"] for d in call(host, port, [{"op": "devices"}], "devices")["devices"]])
