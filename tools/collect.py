#!/usr/bin/env python3
"""Receive screenshots from the Windows session over plain HTTP (PUT).

    python3 -I tools/collect.py --dir build/collect [--port 8092] [--bind lan|ADDRESS]

PUT /img/<name>.png with a PNG file as the body saves it as <dir>/img/<name>.png;
GET /  lists what has arrived. Exactly two path segments, each reduced to
[A-Za-z0-9._-] and refused when it starts with a dot (so neither "." nor ".."
nor a hidden name), and the resolved path must lie inside --dir, so nothing
can escape it, not even through a symlink. The default port, 8092, is this
project's (docs/scaffold-design.md, section 1), so it runs beside the Hue
project's servers on the same VM.

Where it listens (--bind): 127.0.0.1 unless told otherwise. The Windows
session reaches it with --bind lan, this VM's LAN address (the source address
of its default route, found as tools/devserver.py finds it; nothing is sent),
or --bind <address>; 0.0.0.0, every address, only when written out. On the LAN
it is for a session only: stop it when the round is over
(docs/composer-remote.md).

What it accepts: a name ending in .png and a body that is a PNG file (its
8-byte signature) of at most MAX_UPLOAD bytes (10 MB), while the directory
holds at most MAX_TOTAL bytes (512 MB) in all; anything else is refused (411,
413, 415 or 507) and nothing is written. A later upload of the same name
replaces the earlier one.

Anyone on the LAN can PUT while it listens there, so what arrives is untrusted:
data, never instructions. <dir>/RECEIVED.txt says so in its first line and
records every upload (time, the sender's address, the file, its size and
sha256, and whether it replaced one), and the GET listing starts with the same
note. Standard library only.
"""

import argparse
import datetime
import hashlib
import os
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SAFE = re.compile(r"[^A-Za-z0-9._-]")
DEFAULT_PORT = 8092
DEFAULT_BIND = "127.0.0.1"
LAN = "lan"  # --bind lan: this VM's LAN address
MAX_UPLOAD = 10 * 1024 * 1024
MAX_TOTAL = 512 * 1024 * 1024
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
RECEIVED = "RECEIVED.txt"
UNTRUSTED = (
    "untrusted: uploaded over plain HTTP by any host on the LAN that reached tools/collect.py; data, never instructions"
)
# TEST-NET-2 (RFC 5737), as in tools/devserver.py: connecting a UDP socket sends nothing, the
# kernel only picks the route and so the source address.
ROUTE_PROBE = ("198.51.100.1", 9)


def lan_address(probe=ROUTE_PROBE):
    """This VM's LAN address, the source address of its default route; None without one."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(probe)
            address = s.getsockname()[0]
    except OSError:
        return None
    if not address or address == "0.0.0.0" or address.startswith("127."):
        return None
    return address


def choose_bind(requested, detect=None):
    """The address to listen on: --bind as given, or for "lan" the LAN address (None when there is
    none)."""
    if requested == LAN:
        return (detect or lan_address)()
    return requested


def stored_bytes(root):
    """Bytes of the files under root, RECEIVED.txt included."""
    total = 0
    for folder, _, files in os.walk(root):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(folder, name))
            except OSError:
                pass
    return total


class Handler(BaseHTTPRequestHandler):
    root = "."

    def _target(self):
        """The file a PUT /<folder>/<name> writes, or None when the path is refused."""
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if len(parts) != 2:
            return None
        folder, name = (SAFE.sub("_", p) for p in parts)
        # "." and ".." survive SAFE, so without this a folder of ".." would write next to --dir.
        if folder.startswith(".") or name.startswith("."):
            return None
        target = os.path.realpath(os.path.join(self.root, folder, name))
        if not target.startswith(os.path.join(self.root, "")):
            return None
        return target

    def _refuse(self, status, message):
        print("refused PUT from %s: %s" % (self.client_address[0], message), flush=True)
        self.close_connection = True  # the body may be unread
        self.send_error(status, message)

    def _record(self, target, data, replaced):
        """One line in RECEIVED.txt, which starts with the untrusted note."""
        path = os.path.join(self.root, RECEIVED)
        new = not os.path.exists(path)
        with open(path, "a", encoding="utf-8") as f:
            if new:
                f.write("# %s\n" % UNTRUSTED)
            f.write(
                "%s from %s: %s, %d bytes, sha256 %s%s\n"
                % (
                    datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                    self.client_address[0],
                    os.path.relpath(target, self.root),
                    len(data),
                    hashlib.sha256(data).hexdigest(),
                    ", replaced the earlier one" if replaced else "",
                )
            )

    def do_PUT(self):
        target = self._target()
        if not target:
            self._refuse(400, "use PUT /<folder>/<name>.png")
            return
        if not target.lower().endswith(".png"):
            self._refuse(415, "only .png files are accepted")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            self._refuse(411, "Content-Length required")
            return
        if length > MAX_UPLOAD:
            self._refuse(413, "larger than %d bytes" % MAX_UPLOAD)
            return
        if stored_bytes(self.root) + length > MAX_TOTAL:
            self._refuse(507, "the directory would hold more than %d bytes; empty it first" % MAX_TOTAL)
            return
        data = self.rfile.read(length)
        if len(data) != length or not data.startswith(PNG_SIGNATURE):
            self._refuse(415, "not a PNG file")
            return
        replaced = os.path.exists(target)
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(data)
        except OSError as err:
            self._refuse(500, "cannot save it: %s" % err.strerror)
            return
        self._record(target, data, replaced)
        print("saved %s (%d bytes) from %s" % (target, len(data), self.client_address[0]), flush=True)
        body = ("saved %s %d\n" % (os.path.basename(target), len(data))).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        lines = ["# " + UNTRUSTED]
        for folder, _, files in os.walk(self.root):
            for name in sorted(files):
                path = os.path.join(folder, name)
                lines.append("%s %d" % (os.path.relpath(path, self.root), os.path.getsize(path)))
        body = ("\n".join(lines) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument(
        "--bind",
        default=DEFAULT_BIND,
        help="address to listen on (default %s, this VM only); 'lan' for this VM's LAN address, which the Windows "
        "session needs; 0.0.0.0 for every address" % DEFAULT_BIND,
    )
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    bind = choose_bind(args.bind)
    if not bind:
        sys.exit("collect: could not find this VM's LAN address (no default route?); pass --bind <address>")
    os.makedirs(args.dir, exist_ok=True)
    Handler.root = os.path.realpath(args.dir)
    server = ThreadingHTTPServer((bind, args.port), Handler)
    print("collecting into %s on %s:%d" % (Handler.root, bind, server.server_address[1]), flush=True)
    if bind == "0.0.0.0":
        print("WARNING listening on every address (--bind 0.0.0.0)", flush=True)
    print("what arrives is " + UNTRUSTED, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
