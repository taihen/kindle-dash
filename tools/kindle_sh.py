#!/usr/bin/env python3
"""kindle_sh.py - run a shell command on the Kindle over the USBNetwork telnetd.

Bootstrap only: telnet in non-WiFi usbnet mode has no password, so this gets a
root shell without touching key auth.

    python3 kindle_sh.py "id; uname -a"
"""
from __future__ import annotations
import socket, sys, time

HOST = "192.168.15.244"
PORT = 23
IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240


def strip_and_answer(data: bytes) -> tuple[bytes, bytes]:
    """Strip telnet IAC sequences, return (clean_text, replies_to_send)."""
    out = bytearray()
    reply = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b == IAC and i + 2 < len(data):
            cmd, opt = data[i + 1], data[i + 2]
            if cmd in (WILL, WONT):
                reply += bytes((IAC, DONT, opt))
            elif cmd in (DO, DONT):
                reply += bytes((IAC, WONT, opt))
            elif cmd == SB:
                while i < len(data) - 1 and not (data[i] == IAC and data[i + 1] == SE):
                    i += 1
                i += 1
            i += 3
            continue
        out.append(b)
        i += 1
    return bytes(out), bytes(reply)


def read_until_quiet(s: socket.socket, idle: float = 2.0, total: float = 90.0) -> str:
    """Read until the stream has been silent for `idle` seconds.

    Stopping at the first '#' is wrong: the shell prompt arrives before the
    command output, so an empty read looked like a successful empty result.
    """
    buf = b""
    last = time.time()
    start = last
    s.settimeout(0.5)
    while time.time() - start < total:
        try:
            chunk = s.recv(65536)
            if not chunk:
                break
            clean, reply = strip_and_answer(chunk)
            if reply:
                try:
                    s.sendall(reply)
                except OSError:
                    pass
            if clean:
                buf += clean
                last = time.time()
        except socket.timeout:
            if buf and (time.time() - last) >= idle:
                break
        except OSError:
            break
    return buf.decode("utf-8", "replace")


def run(command: str) -> str:
    s = socket.create_connection((HOST, PORT), timeout=10)
    read_until_quiet(s, idle=0.8, total=15)     # banner + prompt
    s.sendall(command.encode() + b"\n")
    text = read_until_quiet(s, idle=2.0, total=110)
    try:
        s.close()
    except OSError:
        pass
    return text


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    print(run(" ".join(argv[1:])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
