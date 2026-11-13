#!/usr/bin/env python3
"""Dev-loop server for the dev builds of this project's drivers. The contract is docs/dev-loop.md.

One plain-HTTP listener (--port, default 8081; the Hue project's server keeps 8080, so both can run
at once) on one address (--bind; by default this VM's LAN address, never every address unless
--bind 0.0.0.0 says so):
  the driver's side     /manifest /bundle /file /commands /log /report
  the developer's side  /status /admin/enqueue /admin/pin /admin/unpin (tools/devctl.py)

Served trees: one per src/<driver>/driver.xml found at startup, named after its directory (today
modernforms_fan and modernforms_breeze_fan), each exactly the Lua and XML that tools/build.sh stages
for that driver, with src/common mounted as common/. /manifest, /bundle and /file take ?tree=<name>;
a request that names no tree gets the only tree while there is exactly one, and a 400 otherwise:
  <name>: src/<name>/**/*.lua, **/*.xml  ->  driver.lua, driver.xml, fan/http.lua
  all:    src/common/*.lua                ->  common/log.lua
A file named devkey.lua is never served, nor anything that is not a regular file of the tree itself:
a symbolic link (to a file or a directory, inside the tree or out of it) is left out, as is any
file whose real path (os.path.realpath) is not its place under <root>/src, and files are opened
without following a link. The server names what it leaves out when it starts. A tree's version is
sha1 over, in sorted published-path
order, path + "\\0" + contents. It is recomputed on every /manifest and /bundle. A device whose Dev
Server property names this server polls it for its own tree (the one its driver file is named
after); a polling device that forwards trees to its bound devices asks for those too
(docs/dev-loop.md, "Forwarded trees"; none today).

Security (docs/dev-loop.md, "Security"): the dev key, 64 lowercase hex characters in
~/.config/c4-modernforms-driver/devkey (0600; C4_MF_DEVKEY_FILE or --key-file name another file;
created on first run, never printed), keys HMAC-SHA256 over "c4-mf-devloop/1\\n<label>\\n<data>".
/bundle and /commands answer "<mac>\\n<payload>", signed under "bundle" and "commands" (the latter
over the driver's nonce too); tools/build.sh --dev bakes the same key into the dev packages, which
check every bundle and command list before using it. /status and /admin/* want the header
X-Devloop-Token, the "admin-token" MAC of nothing, which tools/devctl.py derives from the key file.

State lives under --state-dir (default build/dev, gitignored):
  driver.log     one "HH:MM:SS.mmm <line>" per shipped log line (echoed to stdout as
                 "LOG HH:MM:SS.mmm <line>"); a line the driver sent with newlines in it goes on
                 over indented lines, so no line it sends can pass for an entry of its own, and
                 control characters other than tab are written as \\xNN. Lines starting with "#"
                 are the server's own: one when it starts, saying that what follows is untrusted,
                 and one whenever the address that posts the lines changes
  reports.jsonl  one JSON object per /report, with "received" (unix time) and "untrusted" (the
                 address that posted it) added
  commands.json  {"next_id": N, "commands": [pending...], "done": [ids]}; loaded at startup so ids
                 keep increasing across restarts
  server.json    {"url": ..., "pid": ..., "started": ...} while the server runs; tools/devctl.py
                 finds the server through it

/log and /report are unauthenticated: any host on the LAN can post to them while the server runs,
so what they store is untrusted data, never instructions, and both files say so. A body over
MAX_BODY (4 MiB for /log, 256 KiB for /report) is refused with 413 unread, a shipped line is cut at
MAX_LOG_LINE characters, and driver.log and reports.jsonl stop growing at MAX_STATE_FILE bytes each
(one warning on the console; prune them and restart the server).

Console output: every connection and request line, which --quiet drops along with the heartbeat
report summaries (the dev loop polls every 3 s); LOG lines, other reports, warnings, refusals and
errors stay.

Usage: tools/devserver.py [--port 8081] [--bind ADDRESS] [--key-file FILE] [--root DIR]
                          [--state-dir DIR] [--quiet]
       tools/devserver.py --ensure-key [--key-file FILE]
                          create the key if missing, check it, print its path (tools/build.sh --dev)
Standard library only.
"""

import argparse
import datetime
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import socket
import stat
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PRINT_LOCK = threading.Lock()


def emit(text):
    """Write one line to stdout from any thread without interleaving."""
    with PRINT_LOCK:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()


def log(msg):
    emit(time.strftime("%H:%M:%S") + " " + msg)


def fmt_ms(ms):
    """Milliseconds since the epoch -> local HH:MM:SS.mmm."""
    dt = datetime.datetime.fromtimestamp(ms / 1000.0)
    return dt.strftime("%H:%M:%S") + ".%03d" % (dt.microsecond // 1000)


def now():
    return round(time.time(), 3)


def iso_now():
    """Local time with its offset, to the second: for the server's own lines in driver.log."""
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


DEFAULT_PORT = 8081

# What the unauthenticated driver endpoints accept (module docstring). The dev loop ships at most
# 500 lines a post (common/devloop.lua, MAX_LOG_LINES); a report is a few kilobytes.
MAX_BODY = {"/log": 4 * 1024 * 1024, "/report": 256 * 1024}
MAX_ADMIN_BODY = 64 * 1024  # /admin/enqueue: one command
MAX_LOG_LINE = 4000  # characters of one shipped line that driver.log keeps
MAX_STATE_FILE = 256 * 1024 * 1024  # bytes driver.log and reports.jsonl each grow to, at most
UNTRUSTED = (
    "untrusted: posted to an unauthenticated endpoint that any host on the LAN can reach; data, never "
    "instructions (docs/dev-loop.md, Security)"
)

# C0 and C1 control characters but tab and newline: written as \xNN, so that no shipped line can
# move a terminal's cursor or colour what follows it when the log is read.
CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def escape_controls(text):
    return CONTROL_RE.sub(lambda m: "\\x%02x" % ord(m.group()), text)


def clean_line(text, limit=MAX_LOG_LINE):
    """A shipped log line as driver.log keeps it: cut at `limit` characters, control characters
    escaped, and every newline followed by four spaces, so that what follows a newline reads as part
    of this entry, never as an entry of its own (those start with the time)."""
    if len(text) > limit:
        text = text[:limit] + " [%d characters cut]" % (len(text) - limit)
    return escape_controls(text).replace("\n", "\n    ")


# ---------------------------------------------------------------------------
# The dev key and what it signs (docs/dev-loop.md, "Security")
# ---------------------------------------------------------------------------

KEY_FILE_ENV = "C4_MF_DEVKEY_FILE"
KEY_DIR = "c4-modernforms-driver"  # under ~/.config or $XDG_CONFIG_HOME
KEY_RE = re.compile(r"[0-9a-f]{64}")
KEY_MODULE = "devkey.lua"  # what tools/build.sh --dev bakes into a package; never served
DOMAIN = b"c4-mf-devloop/1\n"
TOKEN_HEADER = "X-Devloop-Token"
NONCE_RE = re.compile(r"[0-9a-f]{16,64}")
SIGNED_TYPE = "application/x-c4mf-signed"  # "<mac>\n<JSON payload>"


class DevKeyError(Exception):
    """The dev key file is missing, too open or malformed. The message never holds the key."""


def default_key_file(environ=None):
    """$C4_MF_DEVKEY_FILE, else $XDG_CONFIG_HOME/c4-modernforms-driver/devkey, else
    ~/.config/c4-modernforms-driver/devkey: outside the repository."""
    environ = os.environ if environ is None else environ
    explicit = environ.get(KEY_FILE_ENV)
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    config = environ.get("XDG_CONFIG_HOME")
    if not config or not os.path.isabs(config):
        config = os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(config, KEY_DIR, "devkey")


def load_key(path):
    """The key as bytes: its 64 hex characters, which are what keys the HMAC
    (on the controller too, as ASCII). Refuses a file group or others can
    read, and anything but 64 lowercase hex characters."""
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    except FileNotFoundError:
        raise DevKeyError(
            "no dev key at %s: start tools/devserver.py once, or run tools/devserver.py --ensure-key" % path
        ) from None
    if mode & 0o077:
        raise DevKeyError(
            "%s can be read by others (mode %03o): chmod 600 it, or delete it for a new key" % (path, mode)
        )
    with open(path, "r", encoding="ascii", errors="replace") as f:
        text = f.read().strip()
    if not KEY_RE.fullmatch(text):
        raise DevKeyError("%s does not hold 64 lowercase hex characters: delete it for a new key" % path)
    return text.encode("ascii")


def ensure_key(path):
    """Create the key file if it is missing: 32 random bytes as hex, 0600, in
    a 0700 directory. Returns (key, created)."""
    created = False
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass  # created by another process meanwhile
        else:
            with os.fdopen(fd, "w", encoding="ascii") as f:
                f.write(secrets.token_hex(32) + "\n")
            created = True
    return load_key(path), created


def mac(key, label, data):
    """HMAC-SHA256 with the key over DOMAIN + label + "\\n" + data, lowercase hex."""
    return hmac.new(key, DOMAIN + label.encode("ascii") + b"\n" + data, hashlib.sha256).hexdigest()


def fingerprint(key):
    """16 hex characters that name a key without revealing it."""
    return mac(key, "fingerprint", b"")[:16]


def admin_token(key):
    """What /status and /admin/* want in X-Devloop-Token."""
    return mac(key, "admin-token", b"")


def envelope(key, label, payload_obj):
    """A signed answer: "<mac>\\n<payload>", the MAC over the payload's exact
    bytes (compact JSON, ASCII only)."""
    payload = json.dumps(payload_obj, separators=(",", ":")).encode("ascii")
    return mac(key, label, payload).encode("ascii") + b"\n" + payload


# ---------------------------------------------------------------------------
# The address to listen on
# ---------------------------------------------------------------------------

# TEST-NET-2 (RFC 5737). Connecting a UDP socket sends nothing: the kernel
# only picks the route, and so the source address, it would use.
ROUTE_PROBE = ("198.51.100.1", 9)


def lan_address(probe=ROUTE_PROBE):
    """This VM's LAN address: the source address of its default route. None
    when there is none (no route, or only loopback)."""
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
    """The address the listener binds: --bind when given (0.0.0.0 only then),
    else the LAN address (`detect`, default lan_address, looked up when
    called); None when that cannot be found."""
    if requested:
        return requested
    return (detect or lan_address)()


def url_host(bind):
    """Where a client on this VM reaches a listener bound to `bind`."""
    return "127.0.0.1" if bind in ("0.0.0.0", "") else bind


# ---------------------------------------------------------------------------
# The served trees
# ---------------------------------------------------------------------------

# What a tree may be called: what common/devloop.lua reads off a driver file
# name (Lua's %w and "_"), so a device can ask for its own tree.
TREE_RE = re.compile(r"[A-Za-z0-9_]+")


def is_own_file(path, expected):
    """Whether `path` is a regular file reached through no symbolic link: not a link itself, and its
    real path is `expected`, the place it has under the real path of the repository."""
    return not os.path.islink(path) and os.path.isfile(path) and os.path.realpath(path) == expected


def read_own_file(path):
    """A served file's bytes, opened without following a link (O_NOFOLLOW) and only when it is a
    regular file; OSError otherwise."""
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise OSError("%s is not a regular file" % path)
        return f.read()


class Tree:
    """The source files of one driver, src/<name> with src/common mounted as
    common/. Listed afresh on every call: a few dozen small files, so there is
    nothing worth caching (and nothing to go stale)."""

    def __init__(self, root, name):
        self.name = name
        self.root = root
        self.driver = os.path.join(root, "src", name)
        self.common = os.path.join(root, "src", "common")
        self.pinned = None  # (version, contents) served instead of the live tree while pinned
        self.refused = []  # what the last files() left out for being a link or outside the tree

    def files(self):
        """Return {published_path: absolute_path}. Published paths are relative
        with forward slashes, e.g. "driver.lua", "fan/http.lua", "common/log.lua":
        the .lua and .xml files of the driver's directory, and src/common/*.lua.
        Hidden files and directories and any devkey.lua are never among them, nor
        a symbolic link or a file whose real path lies elsewhere than its place
        under <root>/src (a linked src/, driver directory or subdirectory): those
        are listed in self.refused, a linked directory with a trailing "/"."""
        out, refused = {}, []
        real_src = os.path.join(os.path.realpath(self.root), "src")
        for dirpath, dirnames, filenames in os.walk(self.driver):
            rel_dir = os.path.relpath(dirpath, self.driver)
            for name in sorted(dirnames):
                if not name.startswith(".") and os.path.islink(os.path.join(dirpath, name)):
                    refused.append((name if rel_dir == "." else os.path.join(rel_dir, name)).replace(os.sep, "/") + "/")
            dirnames[:] = sorted(
                d for d in dirnames if not d.startswith(".") and not os.path.islink(os.path.join(dirpath, d))
            )
            for name in filenames:
                if name.startswith(".") or name == KEY_MODULE:
                    continue
                if not (name.endswith(".lua") or name.endswith(".xml")):
                    continue
                rel = name if rel_dir == "." else os.path.join(rel_dir, name)
                full = os.path.join(dirpath, name)
                if is_own_file(full, os.path.join(real_src, self.name, rel)):
                    out[rel.replace(os.sep, "/")] = full
                else:
                    refused.append(rel.replace(os.sep, "/"))
        if os.path.isdir(self.common):
            for name in os.listdir(self.common):
                full = os.path.join(self.common, name)
                if not name.endswith(".lua") or name.startswith(".") or name == KEY_MODULE:
                    continue
                if is_own_file(full, os.path.join(real_src, "common", name)):
                    out["common/" + name] = full
                elif os.path.islink(full) or os.path.isfile(full):
                    refused.append("common/" + name)
        self.refused = sorted(refused)
        return out

    def snapshot(self):
        """What is served right now: the pinned snapshot while pinned, else
        the live tree. Returns (version, {published_path: bytes})."""
        if self.pinned is not None:
            return self.pinned
        return self.read()

    def pin(self):
        """Serve the tree as it is at this moment until unpin(); pinning again
        re-reads it. For stretches when several agents edit src/ at once and
        the controller must only see states the coordinator has checked."""
        self.pinned = self.read()
        return self.pinned[0]

    def unpin(self):
        self.pinned = None

    def read(self):
        """Read every served file from disk. Returns (version, {published_path: bytes})."""
        files = self.files()
        contents = {}
        digest = hashlib.sha1()
        for path in sorted(files):
            data = read_own_file(files[path])
            contents[path] = data
            digest.update(path.encode("utf-8"))
            digest.update(b"\0")
            digest.update(data)
        return digest.hexdigest(), contents


def discover_trees(root):
    """The trees under <root>/src: every directory with a driver.xml, as tools/build.sh packs them,
    named after the directory. Returns ({name: Tree} in name order, [names skipped because a device
    could not ask for them])."""
    src = os.path.join(root, "src")
    trees, skipped = {}, []
    try:
        names = sorted(os.listdir(src))
    except OSError:
        return trees, skipped
    for name in names:
        if name.startswith(".") or not os.path.isfile(os.path.join(src, name, "driver.xml")):
            continue
        if TREE_RE.fullmatch(name):
            trees[name] = Tree(root, name)
        else:
            skipped.append(name)
    return trees, skipped


# ---------------------------------------------------------------------------
# Server state: the command queue and what the drivers last told us
# ---------------------------------------------------------------------------

# Two devices reporting within this long of each other both poll this server.
DEVICE_WINDOW_S = 60


def as_device_id(value):
    """A device id from a report (a JSON number, possibly written as 15.0), or None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


class State:
    """Everything remembered between requests, guarded by one lock.

    A command sits in the pending queue until a driver reports command_done
    for it, then moves to the done list. A driver that comes up fresh (asking
    after=0) therefore re-receives only commands nobody has acknowledged, not
    the whole history."""

    DONE_KEEP = 200  # finished ids kept for /status and `devctl wait`

    def __init__(self, state_dir):
        self.lock = threading.Lock()
        os.makedirs(state_dir, exist_ok=True)
        self.log_path = os.path.join(state_dir, "driver.log")
        self.reports_path = os.path.join(state_dir, "reports.jsonl")
        self.commands_path = os.path.join(state_dir, "commands.json")
        self.next_id = 1
        self.commands = []  # pending commands, in id order
        self.done = []  # ids a driver reported command_done for, oldest first
        self.running = {}  # tree -> the version the devices polling for it last reported running
        self.forwarded = {}  # tree -> the version a polling device last reported forwarding
        self.devices = {}  # device id -> {"tree": ..., "last_seen": ...}, from the reports
        self.device_id = None  # the device of the latest report
        self.warned_devices = set()  # devices a second-poller warning was given for
        self.last_seen = None
        self.last_event = None
        self.last_error = None  # text of the most recent report that carried "error"
        self.properties = {}
        self.driver_key_fingerprint = None  # what the last report named
        self.reported_key = False  # whether any report has said which key the driver has
        self.warned_fingerprint = None  # the driver fingerprint last warned about
        self.log_sender = None  # the address that posted the last lines written to driver.log
        self.full = set()  # the state files that reached MAX_STATE_FILE (warned about once)
        self._load_commands()
        self._append(
            self.log_path,
            ["# %s devserver started; every line below that does not start with '#' is %s" % (iso_now(), UNTRUSTED)],
        )

    def _append(self, path, lines):
        """Append lines to driver.log or reports.jsonl unless the file has reached MAX_STATE_FILE;
        returns whether they were written. Caller holds the lock, or the state is not shared yet."""
        try:
            size = os.path.getsize(path)
        except OSError:
            size = 0
        if size >= MAX_STATE_FILE:
            if path not in self.full:
                self.full.add(path)
                log(
                    "WARNING %s has reached %d bytes: nothing more is written to it; prune it and restart the server"
                    % (path, MAX_STATE_FILE)
                )
            return False
        with open(path, "a", encoding="utf-8") as f:
            for line in lines:
                f.write(line + "\n")
        return True

    def _load_commands(self):
        if not os.path.exists(self.commands_path):
            return
        try:
            with open(self.commands_path, "r", encoding="utf-8") as f:
                saved = json.load(f)
            commands = [c for c in saved.get("commands", []) if isinstance(c.get("id"), int)]
            done = [i for i in saved.get("done", []) if isinstance(i, int)]
            next_id = int(saved.get("next_id", 1))
        except (OSError, ValueError, AttributeError, TypeError) as exc:
            log("warning: ignoring unreadable %s (%s)" % (self.commands_path, exc))
            return
        self.commands = sorted(commands, key=lambda c: c["id"])
        self.done = done[-self.DONE_KEEP :]
        highest = max([c["id"] for c in self.commands] + self.done + [0])
        self.next_id = max(next_id, highest + 1)

    def _save_commands(self):
        """Caller holds the lock. Written atomically so a crash mid-write cannot
        leave a truncated file that would reset the ids."""
        tmp = self.commands_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"next_id": self.next_id, "commands": self.commands, "done": self.done}, f, indent=1)
        os.replace(tmp, self.commands_path)

    def touch(self, tree=None, version=None, forwarded=None):
        """A driver talked to us; a report or a log post also says which tree it runs at which
        version, and a report which versions it forwarded."""
        with self.lock:
            self.last_seen = now()
            if isinstance(tree, str) and tree and isinstance(version, str) and version:
                self.running[tree] = version
            if isinstance(forwarded, dict):
                for name, value in forwarded.items():
                    if isinstance(name, str) and name and isinstance(value, str) and value:
                        self.forwarded[name] = value

    def note_fingerprint(self, reported, ours):
        """Record the key fingerprint a report carried (None: the driver has no
        key). Returns a warning line the first time it differs from ours."""
        with self.lock:
            self.reported_key = True
            self.driver_key_fingerprint = reported if isinstance(reported, str) else None
            if self.driver_key_fingerprint == ours or self.driver_key_fingerprint == self.warned_fingerprint:
                return None
            self.warned_fingerprint = self.driver_key_fingerprint
        if self.driver_key_fingerprint is None:
            return (
                "WARNING the driver reports no dev key (a build without one): it can use no bundle or command "
                "from this server; install a dev build made from this commit"
            )
        return (
            "WARNING the driver's dev key (fingerprint %s) is not this server's (%s): it refuses every bundle "
            "and command; install a dev build made with this key, or start the server with that build's key"
            % (self.driver_key_fingerprint, ours)
        )

    def note_device(self, device_id, tree):
        """Record which device a report came from. Returns a warning line the first time a device
        reports while another one reported within DEVICE_WINDOW_S: both poll this server, and each
        runs every queued command."""
        device_id = as_device_id(device_id)
        if device_id is None:
            return None
        with self.lock:
            t = now()
            others = sorted(
                d for d, seen in self.devices.items() if d != device_id and t - seen["last_seen"] < DEVICE_WINDOW_S
            )
            self.devices[device_id] = {"tree": tree if isinstance(tree, str) else None, "last_seen": t}
            self.device_id = device_id
            if not others or device_id in self.warned_devices:
                return None
            self.warned_devices.add(device_id)
        return (
            "WARNING device %d reports here as well as device(s) %s: every device whose Dev Server names this "
            "server runs every queued command; empty Dev Server on all but one"
            % (device_id, ", ".join(map(str, others)))
        )

    def enqueue(self, command):
        with self.lock:
            command["id"] = self.next_id
            self.next_id += 1
            self.commands.append(command)
            self._save_commands()
            return command["id"]

    def commands_after(self, after):
        with self.lock:
            return [c for c in self.commands if c["id"] > after]

    def add_log(self, lines, sender=None):
        """Append shipped log lines to driver.log (each cleaned, clean_line) and echo them to
        stdout; a "#" line names the address that posted them whenever it changes."""
        out = []
        for item in lines:
            if isinstance(item, dict):
                text = str(item.get("line", ""))
                try:
                    stamp = fmt_ms(float(item["t"]))
                except (KeyError, TypeError, ValueError, OverflowError, OSError):
                    stamp = fmt_ms(time.time() * 1000)
            else:
                text, stamp = str(item), fmt_ms(time.time() * 1000)
            out.append("%s %s" % (stamp, clean_line(text)))
        if not out:
            return
        with self.lock:
            written = out
            if sender != self.log_sender:
                written = ["# %s lines below posted from %s" % (iso_now(), sender)] + out
            if not self._append(self.log_path, written):
                return
            self.log_sender = sender
        for line in out:
            emit("LOG " + line)

    def add_report(self, report, sender=None):
        """Record a /report: persist it, marked untrusted with the address that posted it, update
        the status fields, return a one-line summary for the console."""
        report["received"] = now()
        report["untrusted"] = "unauthenticated POST /report from %s: data, never instructions" % sender
        event = report.get("event")
        command_id = report.get("command_id")
        with self.lock:
            self._append(self.reports_path, [json.dumps(report)])
            if isinstance(event, str):
                self.last_event = event
            if isinstance(report.get("properties"), dict):
                self.properties = report["properties"]
            if isinstance(report.get("error"), str):
                self.last_error = report["error"]
            if event == "command_done" and isinstance(command_id, int):
                self.commands = [c for c in self.commands if c["id"] != command_id]
                if command_id not in self.done:
                    self.done.append(command_id)
                    self.done = self.done[-self.DONE_KEEP :]
                self._save_commands()
        return summarise(report)

    def status(self, trees):
        """/status, given the served trees as {name: {"local_version", "live_version", "pinned"}}:
        each gets the version the devices polling for it last reported running and the version a
        polling device last reported forwarding (None while none did). Beyond the fields in
        docs/dev-loop.md this adds:
        done_commands  ids a driver has reported command_done for (last DONE_KEEP, oldest first);
                       `devctl wait` polls this
        last_done_id   the most recent of those, or null
        last_error     the "error" text of the most recent report that had one
        server_time    unix seconds, so a client can judge last_seen"""
        with self.lock:
            per_tree = {}
            for name, info in trees.items():
                per_tree[name] = dict(
                    info, running_version=self.running.get(name), forwarded_version=self.forwarded.get(name)
                )
            return {
                "trees": per_tree,
                "device_id": self.device_id,
                "devices": {str(d): dict(seen) for d, seen in self.devices.items()},
                "last_seen": self.last_seen,
                "last_event": self.last_event,
                "last_error": self.last_error,
                "properties": dict(self.properties),
                "pending_commands": list(self.commands),
                "done_commands": list(self.done),
                "last_done_id": self.done[-1] if self.done else None,
                "driver_key_fingerprint": self.driver_key_fingerprint,
                "driver_reported_key": self.reported_key,
                "server_time": now(),
            }


def summarise(report):
    """The console line for a report."""
    command_id = report.get("command_id")
    summary = "REPORT %s" % report.get("event")
    if isinstance(command_id, int):
        summary += " cmd=%d" % command_id
    device_id = as_device_id(report.get("device_id"))
    if device_id is not None:
        summary += " dev=%d" % device_id
    if isinstance(report.get("tree"), str):
        summary += " tree=%s" % report["tree"]
    if isinstance(report.get("version"), str):
        summary += " v=%s" % report["version"][:12]
    forwarded = report.get("forwarded")
    if isinstance(forwarded, dict) and forwarded:
        summary += " fwd=%s" % ",".join("%s:%s" % (k, str(forwarded[k])[:12]) for k in sorted(forwarded))
    if isinstance(report.get("refused_tree"), str):
        summary += " refused=%s@%s" % (report["refused_tree"], str(report.get("refused_version"))[:12])
    if isinstance(report.get("elapsed_ms"), (int, float)):
        summary += " %dms" % report["elapsed_ms"]
    if isinstance(report.get("properties"), dict):
        summary += " props=%d" % len(report["properties"])
    if report.get("sandbox") is not None:
        summary += " sandbox=%s" % json.dumps(report["sandbox"], separators=(",", ":"))
    if isinstance(report.get("error"), str):
        summary += " error=%s" % report["error"].replace("\n", " ")[:300]
    return escape_controls(summary.replace("\n", " "))


# ---------------------------------------------------------------------------
# HTTP handling
# ---------------------------------------------------------------------------


def as_list(value):
    """Accept a JSON list, or the object Director's C4:JsonEncode produces for
    a Lua array ({"1": ..., "2": ...}, string keys, unordered): return a list
    in key order. Anything else is returned unchanged for the caller to reject."""
    if isinstance(value, list):
        return value
    if isinstance(value, dict) and value and all(k.isdigit() for k in value):
        return [value[k] for k in sorted(value, key=int)]
    return value


def validate_command(body):
    """Check a /admin/enqueue body; return (command, None) or (None, error)."""
    if not isinstance(body, dict):
        return None, "body must be a JSON object"
    kind = body.get("type")
    if kind == "execute":
        if not isinstance(body.get("command"), str) or not body["command"]:
            return None, 'execute needs a non-empty "command" string'
        params = body.get("params", {})
        if not isinstance(params, dict):
            return None, '"params" must be an object'
        return {
            "type": "execute",
            "command": body["command"],
            "params": {str(k): str(v) for k, v in params.items()},
        }, None
    if kind == "set_property":
        if not isinstance(body.get("name"), str) or not body["name"]:
            return None, 'set_property needs a non-empty "name" string'
        if "value" not in body or body["value"] is None:
            return None, 'set_property needs a "value"'
        return {"type": "set_property", "name": body["name"], "value": str(body["value"])}, None
    if kind == "reload":
        return {"type": "reload"}, None
    return None, "unknown type %r (execute, set_property or reload)" % (kind,)


def developer_path(path):
    """The endpoints only the developer calls: they want the admin token."""
    return path == "/status" or path.startswith("/admin/")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive; every reply carries Content-Length
    timeout = 120  # idle keep-alive connections are dropped after this
    server_version = "c4-mf-devserver/1"
    sys_version = ""
    _answered = False  # whether this request was answered before its handler's own reply

    GET_ROUTES = {
        "/manifest": "get_manifest",
        "/bundle": "get_bundle",
        "/file": "get_file",
        "/commands": "get_commands",
        "/status": "get_status",
    }
    POST_ROUTES = {
        "/log": "post_log",
        "/report": "post_report",
        "/admin/enqueue": "post_enqueue",
        "/admin/pin": "post_pin",
        "/admin/unpin": "post_unpin",
    }

    # -- connection logging ------------------------------------------------

    @property
    def chatty(self):
        """Whether connection and request lines go to the console."""
        return not self.server.quiet

    def log_conn(self, msg):
        log("HTTP  %s:%d  %s" % (self.client_address[0], self.client_address[1], msg))

    def setup(self):
        super().setup()
        if self.chatty:
            self.log_conn("OPEN")

    def finish(self):
        super().finish()
        if self.chatty:
            self.log_conn("CLOSE")

    def log_message(self, fmt, *args):
        """Quiet the default access log; requests are logged in dispatch()."""

    # -- dispatch -----------------------------------------------------------

    def do_GET(self):
        self.dispatch("GET", self.GET_ROUTES, self.POST_ROUTES)

    def do_POST(self):
        self.dispatch("POST", self.POST_ROUTES, self.GET_ROUTES)

    def dispatch(self, method, routes, other_routes):
        self._answered = False  # whether a reply went out before the handler's own
        url = urlsplit(self.path)
        if self.chatty:
            self.log_conn("%-4s  %s" % (method, self.path))
        name = routes.get(url.path)
        if name is None:
            if url.path in other_routes:
                self.send_text(405, "method not allowed\n", allow="POST" if method == "GET" else "GET")
            else:
                self.send_text(404, "not found\n")
            return
        if developer_path(url.path) and not self.authorised(method, url.path):
            return
        getattr(self, name)(parse_qs(url.query))

    def authorised(self, method, path):
        """Whether the request carries the admin token; if not, a 401 has been
        sent and one DENY line logged (without the value presented)."""
        given = self.headers.get(TOKEN_HEADER)
        if given is not None and hmac.compare_digest(
            given.encode("utf-8", "replace"), self.server.admin_token.encode("ascii")
        ):
            return True
        self.close_connection = True  # the body was not read
        log(
            "DENY  %s:%d  %s %s: %s"
            % (
                self.client_address[0],
                self.client_address[1],
                method,
                path,
                "no admin token" if given is None else "wrong admin token",
            )
        )
        self.send_json(
            {"error": "admin token missing or wrong; tools/devctl.py sends it (docs/dev-loop.md, Security)"}, 401
        )
        return False

    # -- replies ------------------------------------------------------------

    def send_body(self, status, body, ctype, allow=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if allow:
            self.send_header("Allow", allow)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def send_json(self, obj, status=200):
        self.send_body(status, json.dumps(obj).encode("utf-8"), "application/json")

    def send_text(self, status, text, allow=None):
        self.send_body(status, text.encode("utf-8"), "text/plain; charset=utf-8", allow)

    def send_signed(self, label, payload_obj):
        self.send_body(200, envelope(self.server.key, label, payload_obj), SIGNED_TYPE)

    def send_no_content(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_bad_request(self, message):
        if self._answered:
            return  # a 413 went out already
        self.close_connection = True  # the body may not have been consumed
        raw = getattr(self, "_raw_body", b"")
        snippet = raw[:300].decode("utf-8", "replace")
        log(
            "BAD   %s:%d  %s %s: %s body=%r"
            % (self.client_address[0], self.client_address[1], self.command, self.path, message, snippet)
        )
        self.send_json({"error": message}, 400)

    def send_too_large(self, limit):
        """413 for a body over `limit` bytes, which is left unread (the connection closes)."""
        self.close_connection = True
        log(
            "BIG   %s:%d  %s %s: Content-Length %s over %d bytes, refused unread"
            % (
                self.client_address[0],
                self.client_address[1],
                self.command,
                self.path,
                escape_controls(str(self.headers.get("Content-Length")))[:20],
                limit,
            )
        )
        self.send_json({"error": "body larger than %d bytes" % limit}, 413)
        self._answered = True

    def read_json_body(self, limit=MAX_ADMIN_BODY):
        """Parse the JSON request body of at most `limit` bytes. Returns (obj, None) or
        (None, error_text); for a larger body the 413 has been sent already (send_bad_request then
        sends nothing more)."""
        length = self.headers.get("Content-Length")
        if length is None:
            return None, "Content-Length required"
        try:
            n = int(length)
        except ValueError:
            return None, "bad Content-Length"
        if n > limit:
            self.send_too_large(limit)
            return None, "body larger than %d bytes" % limit
        raw = self.rfile.read(n) if n > 0 else b""
        self._raw_body = raw  # kept so a rejection can be logged with context
        if not raw:
            return None, "empty body"
        try:
            return json.loads(raw.decode("utf-8")), None
        except (UnicodeDecodeError, ValueError) as exc:
            return None, "invalid JSON: %s" % exc

    # -- dev-loop endpoints -------------------------------------------------

    def tree_from(self, query):
        """The tree a request names (?tree=<name>), or the only one when it names none and there
        is exactly one; None after a 400 has been sent."""
        trees = self.server.trees
        names = " or ".join(sorted(trees)) or "none"
        name = query.get("tree", [None])[0]
        if name is None:
            if len(trees) == 1:
                return next(iter(trees.values()))
            self.send_bad_request("name a tree with ?tree= (%s)" % names)
            return None
        tree = trees.get(name)
        if tree is None:
            self.send_bad_request("unknown tree %r (%s)" % (name, names))
        return tree

    def get_manifest(self, query):
        tree = self.tree_from(query)
        if tree is None:
            return
        version, contents = tree.snapshot()
        self.server.state.touch()
        self.send_json({"version": version, "tree": tree.name, "files": sorted(contents), "server_time": now()})

    def get_bundle(self, query):
        """The tree's files, signed (label "bundle"): the driver checks the MAC
        before it decodes anything."""
        tree = self.tree_from(query)
        if tree is None:
            return
        version, contents = tree.snapshot()
        self.server.state.touch()
        files = {path: data.decode("utf-8", "replace") for path, data in contents.items()}
        self.send_signed("bundle", {"version": version, "tree": tree.name, "files": files})

    def get_file(self, query):
        tree = self.tree_from(query)
        if tree is None:
            return
        path = query.get("path", [""])[0]
        files = tree.files()
        # Only published paths are served, so "../x", "/etc/passwd", a symbolic
        # link and the like simply are not in the table and get a 404.
        if not path or path.startswith("/") or ".." in path.split("/") or path not in files:
            self.send_text(404, "no such file\n")
            return
        try:
            data = read_own_file(files[path])
        except OSError:
            # Became a link, or went, since it was listed.
            self.send_text(404, "no such file\n")
            return
        self.server.state.touch()
        self.send_body(200, data, "text/plain; charset=utf-8")

    def get_commands(self, query):
        """The pending commands after `after`, signed (label "commands")
        together with the nonce the driver sent, so an answer recorded once
        cannot be replayed to it."""
        raw = query.get("after", ["0"])[0]
        try:
            after = int(raw)
        except ValueError:
            self.send_bad_request("after must be an integer")
            return
        nonce = query.get("nonce", [""])[0]
        if not NONCE_RE.fullmatch(nonce):
            self.send_bad_request(
                "nonce must be 16 to 64 lowercase hex characters "
                "(a dev build of another loop? install one made from this commit)"
            )
            return
        self.server.state.touch()
        self.send_signed("commands", {"nonce": nonce, "commands": self.server.state.commands_after(after)})

    def get_status(self, query):
        # While pinned, local_version is the served (pinned) version; live_version says what the
        # working tree has become in the meantime.
        trees = {
            name: {
                "local_version": tree.snapshot()[0],
                "live_version": tree.read()[0],
                "pinned": tree.pinned[0] if tree.pinned else None,
            }
            for name, tree in self.server.trees.items()
        }
        status = self.server.state.status(trees)
        status["key_fingerprint"] = self.server.key_fingerprint
        self.send_json(status)

    def post_log(self, query):
        body, err = self.read_json_body(MAX_BODY["/log"])
        if err is None and isinstance(body, dict):
            body["lines"] = as_list(body.get("lines"))
        if err is None and not (isinstance(body, dict) and isinstance(body.get("lines"), list)):
            err = 'expected {"version": ..., "tree": ..., "lines": [...]}'
        if err:
            self.send_bad_request(err)
            return
        self.server.state.touch(body.get("tree"), body.get("version"))
        self.server.state.add_log(body["lines"], self.client_address[0])
        self.send_no_content()

    def post_report(self, query):
        body, err = self.read_json_body(MAX_BODY["/report"])
        if err is None and not (isinstance(body, dict) and isinstance(body.get("event"), str)):
            err = 'expected {"version": ..., "event": ..., ...}'
        if err:
            self.send_bad_request(err)
            return
        state = self.server.state
        state.touch(body.get("tree"), body.get("version"), body.get("forwarded"))
        for warning in (
            state.note_fingerprint(body.get("key_fingerprint"), self.server.key_fingerprint),
            state.note_device(body.get("device_id"), body.get("tree")),
        ):
            if warning:
                log(warning)
        summary = state.add_report(body, self.client_address[0])
        if body["event"] != "heartbeat" or not self.server.quiet:
            log(summary)
        self.send_no_content()

    def post_enqueue(self, query):
        body, err = self.read_json_body()
        if err is None:
            command, err = validate_command(body)
        if err:
            self.send_bad_request(err)
            return
        command_id = self.server.state.enqueue(command)
        log("QUEUE #%d %s" % (command_id, json.dumps(command, separators=(",", ":"))))
        self.send_json({"id": command_id})

    def pinned_versions(self):
        return {name: (tree.pinned[0] if tree.pinned else None) for name, tree in self.server.trees.items()}

    def named_trees(self, query):
        """The trees ?tree= names (every tree when it names none), or None after a 400."""
        names = query.get("tree") or list(self.server.trees)
        unknown = [name for name in names if name not in self.server.trees]
        if unknown:
            self.send_bad_request("unknown tree %r (%s)" % (unknown[0], " or ".join(sorted(self.server.trees))))
            return None
        return [self.server.trees[name] for name in names]

    def post_pin(self, query):
        """Pin every tree (or ?tree=<name>) to its content right now; the
        controller keeps that version until unpin or the next pin."""
        trees = self.named_trees(query)
        if trees is None:
            return
        for tree in trees:
            log("PIN %s tree at %s" % (tree.name, tree.pin()[:12]))
        self.send_json({"pinned": self.pinned_versions()})

    def post_unpin(self, query):
        trees = self.named_trees(query)
        if trees is None:
            return
        for tree in trees:
            tree.unpin()
            log("UNPIN %s tree" % tree.name)
        self.send_json({"pinned": self.pinned_versions()})


class DevServer(ThreadingHTTPServer):
    """The listener. The handler reaches the shared trees, state and key via self.server."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, trees, state, key, quiet=False):
        super().__init__(address, Handler)
        self.trees = trees  # {name: Tree}
        self.state = state
        self.key = key  # the dev key's 64 hex characters, as bytes
        self.admin_token = admin_token(key)
        self.key_fingerprint = fingerprint(key)
        self.quiet = quiet

    def handle_error(self, request, client_address):
        """Disconnects and resets are one console line, not a traceback."""
        exc = sys.exc_info()[1]
        where = "%s:%d" % client_address
        if isinstance(exc, OSError):
            log("ERROR %s  %s: %s" % (where, exc.__class__.__name__, exc))
        else:
            log("ERROR %s  unexpected exception:\n%s" % (where, traceback.format_exc()))


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------


def write_server_file(state_dir, url):
    """build/dev/server.json: where tools/devctl.py finds this server."""
    path = os.path.join(state_dir, "server.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"url": url, "pid": os.getpid(), "started": now()}, f)
    os.replace(tmp, path)
    return path


def remove_server_file(path):
    """Remove server.json if it is still this process's."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            ours = json.load(f).get("pid") == os.getpid()
        if ours:
            os.remove(path)
    except (OSError, ValueError, AttributeError):
        pass


def build_parser(default_root):
    parser = argparse.ArgumentParser(description="Dev-loop server for this project's dev builds (docs/dev-loop.md).")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="plain HTTP port (default %d)" % DEFAULT_PORT)
    parser.add_argument(
        "--bind",
        default=None,
        help="address the listener binds (default: this VM's LAN address; 0.0.0.0 only when given here)",
    )
    parser.add_argument(
        "--key-file",
        default=None,
        help="the dev key (default $%s, else ~/.config/%s/devkey; created on first run)" % (KEY_FILE_ENV, KEY_DIR),
    )
    parser.add_argument(
        "--ensure-key",
        action="store_true",
        help="only create the key file if missing, check it and print its path (tools/build.sh --dev)",
    )
    parser.add_argument(
        "--root", default=default_root, help="repo root, the directory containing tools/ (default: detected)"
    )
    parser.add_argument(
        "--state-dir", default=None, help="where driver.log etc. are written (default <root>/build/dev)"
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="no connection and request lines, no heartbeat summaries",
    )
    return parser


def ensure_key_main(key_file):
    """--ensure-key: the path on stdout (for tools/build.sh), the rest on stderr."""
    try:
        key, created = ensure_key(key_file)
    except (DevKeyError, OSError) as exc:
        sys.exit("devserver: %s" % exc)
    sys.stderr.write("dev key %s%s, fingerprint %s\n" % (key_file, " (created)" if created else "", fingerprint(key)))
    print(key_file)


def main(argv=None):
    default_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    args = build_parser(default_root).parse_args(argv)
    key_file = os.path.abspath(os.path.expanduser(args.key_file)) if args.key_file else default_key_file()
    if args.ensure_key:
        ensure_key_main(key_file)
        return

    root = os.path.abspath(args.root)
    trees, skipped = discover_trees(root)
    if not trees:
        sys.exit("devserver: no src/*/driver.xml under %s (use --root)" % root)
    state_dir = args.state_dir or os.path.join(root, "build", "dev")

    try:
        key, created = ensure_key(key_file)
    except (DevKeyError, OSError) as exc:
        sys.exit("devserver: %s" % exc)
    bind = choose_bind(args.bind)
    if not bind:
        sys.exit("devserver: could not find this VM's LAN address (no default route?); pass --bind <address>")

    state = State(state_dir)
    server = DevServer((bind, args.port), trees, state, key, quiet=args.quiet)
    url = "http://%s:%d" % (url_host(bind), server.server_address[1])

    log("dev key %s%s, fingerprint %s" % (key_file, " (created)" if created else "", fingerprint(key)))
    if os.path.exists(os.path.join(root, "src", "common", KEY_MODULE)):
        log("WARNING src/common/%s exists: it is never served; delete it (tools/build.sh refuses to run)" % KEY_MODULE)
    for name in skipped:
        log("WARNING src/%s is not served: a tree's name is letters, digits and _ (common/devloop.lua)" % name)
    for name, tree in trees.items():
        version, contents = tree.snapshot()
        log("serving %s tree: %d files from %s, version %s" % (name, len(contents), tree.driver, version))
        for path in tree.refused:
            log("WARNING %s tree: %s is a symbolic link or lies outside the tree; it is never served" % (name, path))
    log("state in %s: %d pending command(s), next id %d" % (state_dir, len(state.commands), state.next_id))
    if bind == "0.0.0.0":
        log("WARNING listening on every address (--bind 0.0.0.0)")
    log("listening on %s (Dev Server = %s:%d)" % (url, url_host(bind), server.server_address[1]))
    server_file = write_server_file(state_dir, url)

    # SIGTERM (pkill) ends the server like Ctrl-C, so server.json goes too.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        remove_server_file(server_file)
        server.server_close()


if __name__ == "__main__":
    main()
