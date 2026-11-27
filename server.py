#!/usr/bin/env python3
"""Serve the dashboard PNG, rendering on demand and never more than once per
refresh window. The Kindle side only ever does GET /dash.png.

  /dash.png          full panel size (600x800, what eips wants)
  /dash.png?h=740    shorter variant that fits under the stock browser toolbar
  /                  HTML wrapper with a meta refresh, for stock firmware
  /health            ok
"""
from __future__ import annotations

import io
import mimetypes
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import render

ROOT = Path(__file__).resolve().parent
_lock = threading.Lock()

CFG = render.load_config()
SERVER = CFG["server"]
PNG = ROOT / SERVER.get("png", "out/dash.png")
REFRESH = int(SERVER.get("refresh_seconds", 300))
BROWSER_H = int(SERVER.get("browser_height", 0))
PANEL_W, PANEL_H = CFG["display"]["width"], CFG["display"]["height"]
FILES = (ROOT / SERVER.get("files_dir", "files")).resolve()

INDEX = """<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="{refresh};url=/">
<title>kindle-dash</title>
<style>
  html,body{{margin:0;padding:0;background:#fff;overflow:hidden}}
  img{{display:block;width:100%;max-width:{width}px;margin:0 auto}}
</style></head>
<body><img src="/dash.png?h={height}&amp;t={stamp}" alt="dashboard"></body></html>
"""


def variant(height: int | None) -> Path:
    if not height or height == PANEL_H:
        return PNG
    return PNG.with_name(f"{PNG.stem}-{height}{PNG.suffix}")


def current_png(height: int | None = None, force: bool = False) -> Path:
    """Return the PNG for this height, re-rendering if stale or forced."""
    path = variant(height)
    with _lock:
        fresh = path.exists() and (time.time() - path.stat().st_mtime) < REFRESH
        if force or not fresh:
            render.render(CFG, path, None if path == PNG else height)
        return path


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet, one line, with the caller's address
        sys.stderr.write(f"kindle-dash: {self.client_address[0]} " + fmt % args + "\n")

    def _send(self, body: bytes, ctype: str, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)

        def argi(name, default=0):
            try:
                return int(query[name][0])
            except (KeyError, ValueError, IndexError):
                return default

        height = argi("h", 0) or None
        try:
            if url.path in ("/dash.png", "/dash", "/dashboard.png"):
                dx, dy = argi("dx"), argi("dy")
                invert = query.get("invert", ["0"])[0] not in ("0", "", "false")
                if dx or dy or invert:
                    # burn-in variants are ad hoc: never cached, rendered on demand
                    img = render.render(CFG, None, height, dx, dy, invert)
                    buf = io.BytesIO()
                    img.save(buf, format="PNG", optimize=True)
                    self._send(buf.getvalue(), "image/png")
                else:
                    png = current_png(height, force="force" in query)
                    self._send(png.read_bytes(), "image/png")
            elif url.path in ("/", "/index.html"):
                self._send(INDEX.format(refresh=REFRESH, width=PANEL_W,
                                        height=height or BROWSER_H or PANEL_H,
                                        stamp=int(time.time())).encode(),
                           "text/html; charset=utf-8")
            elif url.path == "/health":
                self._send(b"ok\n", "text/plain")
            elif url.path.startswith("/files/"):
                name = urllib.parse.unquote(url.path[len("/files/"):])
                if not name:
                    names = sorted(p for p in FILES.iterdir()) if FILES.is_dir() else []
                    rows = "".join(
                        f'<li><a href="/files/{p.name}">{p.name}</a> &middot; '
                        f'{p.stat().st_size} bytes</li>' for p in names if p.is_file())
                    self._send(f"<!doctype html><meta charset=utf-8><ul>{rows}</ul>".encode(),
                               "text/html; charset=utf-8")
                else:
                    target = (FILES / name).resolve()
                    # whitelisted directory only, no traversal, no subdirectories
                    if target.parent == FILES and target.is_file():
                        ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
                        self._send(target.read_bytes(), ctype)
                    else:
                        self._send(b"not found\n", "text/plain", 404)
            else:
                self._send(b"not found\n", "text/plain", 404)
        except Exception as exc:  # keep serving even if HA is down
            self.log_message("error rendering: %s", exc)
            last = variant(height)
            if last.exists():
                self._send(last.read_bytes(), "image/png")   # last good frame
            else:
                self._send(f"render failed: {exc}\n".encode(), "text/plain", 500)


def main() -> int:
    current_png(force=True)   # fail fast on config/HA problems before binding
    httpd = ThreadingHTTPServer((SERVER.get("bind", "0.0.0.0"), int(SERVER["port"])), Handler)
    print(f"kindle-dash on http://{SERVER.get('bind')}:{SERVER['port']}/dash.png "
          f"(refresh {REFRESH}s, browser variant {BROWSER_H or PANEL_H}px)", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
