#!/usr/bin/env python3
"""CLI for the dev loop (docs/dev-loop.md). Talks to tools/devserver.py over HTTP, found through
build/dev/server.json (--server overrides); `log` reads build/dev/driver.log directly, so run it on
the VM the server runs on. Every server call carries the admin token, derived from the dev key file
the server uses (~/.config/c4-modernforms-driver/devkey, or $C4_MF_DEVKEY_FILE, or --key-file); the
key itself never leaves this machine.

  devctl.py status                        every tree's versions (running or forwarded vs local), the
                                          dev key, the polling device, last contact, properties
  devctl.py run "Some Action" Key=Value   queue a signed command (devloop.execute): a development
                                          command of the driver, else its ExecuteCommand
  devctl.py set "Debug Mode" On           queue a property change
  devctl.py reload                        queue a reload of the current code
  devctl.py wait <id> [--timeout 60]      block until the driver reports the command done, then
                                          show the properties of that report
  devctl.py pin / unpin [--tree T]        serve src/ as it is now / live again
  devctl.py log [-n 50] [-f]              show / follow the shipped driver log

`run`, `set` and `reload` print only the queued command's id, so
`devctl.py wait $(devctl.py set "Debug Mode" Off)` works.

Exit codes: 0 success, 1 error (server unreachable, bad arguments, no key), 2 timeout.
Standard library only.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)  # also under python3 -I, which leaves the script's directory out

import devserver  # noqa: E402

EXIT_OK, EXIT_ERROR, EXIT_TIMEOUT = 0, 1, 2
DEFAULT_STATE = os.path.join(os.path.dirname(TOOLS), "build", "dev")

# A running loop asks the server something every POLL_S seconds (devloop.INTERVAL_MS); SILENT_S of
# silence means no loop is polling (a hint when a wait times out).
POLL_S = 3
SILENT_S = 10
# Lua's %s, the white space common/dispatch.lua turns into "_" when it names a property handler.
LUA_SPACE = re.compile(r"[ \t\n\v\f\r]+")


class DevctlError(Exception):
    """A user-facing error: printed to stderr, exit 1."""


# ---------------------------------------------------------------------------
# Talking to the server
# ---------------------------------------------------------------------------


def server_url(state_dir):
    """The URL devserver.py wrote to <state_dir>/server.json when it started."""
    path = os.path.join(state_dir, "server.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            url = json.load(f).get("url")
    except FileNotFoundError:
        raise DevctlError("no %s: is tools/devserver.py running? (or pass --server URL)" % path) from None
    except (OSError, ValueError, AttributeError) as exc:
        raise DevctlError("unreadable %s (%s); pass --server URL" % (path, exc)) from exc
    if not isinstance(url, str) or not url.startswith("http://"):
        raise DevctlError("%s holds no http:// url; pass --server URL" % path)
    return url


def token_for(key_file):
    """The admin token for the key in `key_file` (never the key itself)."""
    try:
        return devserver.admin_token(devserver.load_key(key_file))
    except devserver.DevKeyError as exc:
        raise DevctlError(str(exc)) from exc
    except OSError as exc:
        raise DevctlError("cannot read the dev key file %s (%s)" % (key_file, exc.strerror or exc)) from exc


def api(server, method, path, body=None, token=None):
    """One request to the server. Returns the decoded JSON reply (None for 204)."""
    data = None
    headers = {}
    if token:
        headers[devserver.TOKEN_HEADER] = token
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(server + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace").strip()
        if exc.code == 401:
            raise DevctlError(
                "%s %s -> HTTP 401: the server refused the admin token; does it use the same dev key file "
                "(compare the fingerprint it printed at start with `tools/devserver.py --ensure-key`)?" % (method, path)
            ) from exc
        raise DevctlError("%s %s -> HTTP %d %s" % (method, path, exc.code, detail)) from exc
    except (urllib.error.URLError, OSError) as exc:
        raise DevctlError(
            "devserver not reachable at %s (%s)" % (server, exc.reason if hasattr(exc, "reason") else exc)
        ) from exc
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError as exc:
        raise DevctlError("%s %s returned something that is not JSON (%s)" % (method, path, exc)) from exc


def call(args, method, path, body=None):
    return api(args.server, method, path, body, args.token)


def enqueue(args, command):
    reply = call(args, "POST", "/admin/enqueue", command)
    if not isinstance(reply, dict) or not isinstance(reply.get("id"), int):
        raise DevctlError("unexpected reply from /admin/enqueue: %r" % (reply,))
    return reply["id"]


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------


def short(version):
    return version[:12] if isinstance(version, str) and version else "-"


def is_time(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def ago(unix_time, server_time=None):
    if not is_time(unix_time):
        return "never"
    reference = server_time if is_time(server_time) else time.time()
    return "%ds ago" % max(0, int(round(reference - unix_time)))


def describe(command):
    kind = command.get("type")
    if kind == "execute":
        params = command.get("params") or {}
        extra = " " + " ".join("%s=%s" % kv for kv in sorted(params.items())) if params else ""
        return "#%s execute %r%s" % (command.get("id"), command.get("command"), extra)
    if kind == "set_property":
        return "#%s set %r = %r" % (command.get("id"), command.get("name"), command.get("value"))
    return "#%s %s" % (command.get("id"), kind)


LABEL_WIDTH = 22


def row(label, value):
    print("%-*s %s" % (LABEL_WIDTH, label, value))


def version_note(reported, local, action):
    """How a reported version relates to the local tree, for `status`."""
    if reported == local:
        return "matches local"
    return "DIFFERS from local; a %s is due" % action


def key_note(st):
    """The `dev_key` row: whether the driver's dev key is the server's."""
    ours = st.get("key_fingerprint")
    if not ours:
        return "server does not say"
    if not st.get("driver_reported_key"):
        return "fingerprint %s; driver has not reported yet" % ours
    theirs = st.get("driver_key_fingerprint")
    if theirs == ours:
        return "matches the server's (fingerprint %s)" % ours
    if not theirs:
        return "DRIVER HAS NONE: it refuses every bundle and command (server's fingerprint %s)" % ours
    return "DIFFERS: driver %s, server %s; install a dev build made with this key" % (theirs, ours)


def tree_rows(name, info):
    """The rows of one served tree: what the devices run (or a polling device forwarded), the local
    version, and the pin."""
    print("tree %s" % name)
    local = info.get("local_version")
    running, forwarded = info.get("running_version"), info.get("forwarded_version")
    if running:
        row("  running", "%s  (%s)" % (short(running), version_note(running, local, "reload")))
    if forwarded:
        row("  forwarded", "%s  (%s)" % (short(forwarded), version_note(forwarded, local, "forward")))
    if not running and not forwarded:
        row("  running", "-  (no device has reported this tree yet)")
    row("  local", short(local))
    if info.get("pinned"):
        row("  pinned", "%s  (live tree: %s)" % (short(info["pinned"]), short(info.get("live_version"))))


def recent_devices(st):
    """The devices that reported within devserver.DEVICE_WINDOW_S of the server's clock, as
    [(id, info)], the latest first."""
    reference = st.get("server_time") if is_time(st.get("server_time")) else time.time()
    out = []
    for key, info in (st.get("devices") or {}).items():
        if isinstance(info, dict) and is_time(info.get("last_seen")):
            if reference - info["last_seen"] < devserver.DEVICE_WINDOW_S:
                out.append((key, info))
    out.sort(key=lambda item: -item[1]["last_seen"])
    return out


def device_note(st):
    """The `device` row: which device reports, and a warning when more than one does."""
    recent = recent_devices(st)
    if len(recent) > 1:
        ids = ", ".join("%s (%s)" % (key, info.get("tree") or "?") for key, info in recent)
        return (
            "%s: MORE THAN ONE device polls this server; each runs every queued command "
            "(empty Dev Server on all but one)" % ids
        )
    device_id = st.get("device_id")
    if device_id is None:
        return "none has reported yet"
    info = (st.get("devices") or {}).get(str(device_id)) or {}
    note = "%s (%s)" % (device_id, info.get("tree") or "?")
    if not recent:
        note += ", last report %s" % ago(info.get("last_seen"), st.get("server_time"))
    return note


def print_properties(properties):
    if not properties:
        row("properties", "(none reported)")
        return
    print("properties:")
    width = max(len(str(name)) for name in properties)
    for name in sorted(properties, key=str):
        print("  %-*s = %s" % (width, name, properties[name]))


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_status(args):
    st = call(args, "GET", "/status")
    trees = st.get("trees") or {}
    for name in sorted(trees):
        tree_rows(name, trees[name] or {})
    row("dev_key", key_note(st))
    row("device", device_note(st))
    row("last_seen", ago(st.get("last_seen"), st.get("server_time")))
    row("last_event", st.get("last_event") or "-")
    if st.get("last_error"):
        row("last_error", st["last_error"])
    pending = st.get("pending_commands") or []
    row("pending", "%d command(s)" % len(pending))
    for command in pending:
        print("  %s" % describe(command))
    print_properties(st.get("properties") or {})
    return EXIT_OK


def parse_params(pairs):
    params = {}
    for pair in pairs:
        key, sep, value = pair.partition("=")
        if not sep or not key:
            raise DevctlError("parameter %r is not Key=Value" % pair)
        params[key] = value
    return params


def cmd_run(args):
    command = {"type": "execute", "command": args.command, "params": parse_params(args.params)}
    print(enqueue(args, command))
    return EXIT_OK


def cmd_set(args):
    print(enqueue(args, {"type": "set_property", "name": args.name, "value": args.value}))
    return EXIT_OK


def cmd_reload(args):
    print(enqueue(args, {"type": "reload"}))
    return EXIT_OK


def cmd_pin(args):
    """Serve src/ as it is right now until `unpin` or the next `pin`; the
    controller reloads to this snapshot and ignores later edits. For stretches
    when several agents edit src/ at once."""
    query = "?tree=%s" % args.tree if args.tree else ""
    reply = call(args, "POST", "/admin/pin" + query)
    for name in sorted(reply.get("pinned", {})):
        row("pinned " + name, short(reply["pinned"][name]))
    return EXIT_OK


def cmd_unpin(args):
    query = "?tree=%s" % args.tree if args.tree else ""
    reply = call(args, "POST", "/admin/unpin" + query)
    if not any((reply.get("pinned") or {}).values()):
        print("serving the live tree")
    else:
        for name in sorted(reply["pinned"]):
            row("pinned " + name, short(reply["pinned"][name]))
    return EXIT_OK


def changes_dev_server(command):
    """Whether a queued command sets the driver's Dev Server property, which stops the dev loop (an
    empty value) or moves it to another server once its command_done report has left."""
    return (
        isinstance(command, dict)
        and command.get("type") == "set_property"
        and LUA_SPACE.sub("_", str(command.get("name") or "")) == "Dev_Server"
    )


def silent_for(st):
    """Seconds since a driver last asked the server anything, by the server's clock; None if never."""
    if not is_time(st.get("last_seen")):
        return None
    reference = st.get("server_time") if is_time(st.get("server_time")) else time.time()
    return max(0.0, reference - st["last_seen"])


def timeout_note(st, command_id):
    """What a wait that timed out knows about the command and the loop."""
    pending = {c.get("id"): c for c in st.get("pending_commands") or [] if isinstance(c, dict)}
    command = pending.get(command_id)
    note = "still pending" if command is not None else "not pending and not done; was it ever queued?"
    silent = silent_for(st)
    if silent is None:
        note += "; no driver has been in touch since the server started"
    elif silent >= SILENT_S:
        note += "; no driver has been in touch for %ds: does a device's Dev Server name this server?" % silent
    if changes_dev_server(command):
        note += (
            "; the loop reports a Dev Server change before it stops or moves, so a lost report leaves it "
            "queued here, where a loop that starts fresh runs it again (docs/dev-loop.md, Gotchas)"
        )
    return note


def cmd_wait(args):
    """Poll /status until a driver reports command `id` done: exit 0 with the properties of that
    report on stdout, or exit 2 after --timeout seconds with what is known on stderr."""
    deadline = time.monotonic() + args.timeout
    while True:
        st = call(args, "GET", "/status")
        done = st.get("done_commands")
        if isinstance(done, list) and args.id in done:
            print_properties(st.get("properties") or {})
            return EXIT_OK
        if time.monotonic() >= deadline:
            sys.stderr.write(
                "timed out after %gs waiting for command %d (%s)\n" % (args.timeout, args.id, timeout_note(st, args.id))
            )
            return EXIT_TIMEOUT
        time.sleep(1)


def tail_lines(path, count):
    """Return the last `count` lines of the file and the offset of its end."""
    with open(path, "rb") as f:
        data = f.read()
    lines = data.splitlines(keepends=True)
    return lines[-count:] if count > 0 else [], len(data)


def cmd_log(args):
    path = args.file or os.path.join(args.state_dir, "driver.log")
    if not os.path.exists(path):
        if not args.follow:
            raise DevctlError("no log yet at %s" % path)
        sys.stderr.write("waiting for %s to appear...\n" % path)
        while not os.path.exists(path):
            time.sleep(0.5)
    lines, offset = tail_lines(path, args.lines)
    sys.stdout.buffer.write(b"".join(lines))
    sys.stdout.flush()
    if not args.follow:
        return EXIT_OK
    # Follow by polling the file size; a shrink means it was truncated or
    # replaced, so start again from the top.
    try:
        while True:
            time.sleep(0.5)
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            if size < offset:
                offset = 0
            if size == offset:
                continue
            with open(path, "rb") as f:
                f.seek(offset)
                chunk = f.read()
            offset += len(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.flush()
    except KeyboardInterrupt:
        return EXIT_OK


# ---------------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(description="Control the dev loop (docs/dev-loop.md).")
    parser.add_argument(
        "--server", default=None, help="devserver base URL (default: the url in <state-dir>/server.json)"
    )
    parser.add_argument(
        "--state-dir", default=DEFAULT_STATE, help="the server's state directory (default %s)" % DEFAULT_STATE
    )
    parser.add_argument(
        "--key-file",
        default=None,
        help="the dev key the server uses (default $%s, else ~/.config/%s/devkey)"
        % (devserver.KEY_FILE_ENV, devserver.KEY_DIR),
    )
    sub = parser.add_subparsers(dest="cmd", metavar="command")
    sub.required = True

    sub.add_parser(
        "status", help="show versions, the dev key, the polling device, last contact, properties"
    ).set_defaults(func=cmd_status)

    p = sub.add_parser("run", help="queue a signed command: a development command or a driver action")
    p.add_argument("command", help='command or action name, e.g. "Debug Off"')
    p.add_argument("params", nargs="*", help="parameters as Key=Value")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("set", help="queue a property change")
    p.add_argument("name", help="property name")
    p.add_argument("value", help="new value (sent as a string)")
    p.set_defaults(func=cmd_set)

    sub.add_parser("reload", help="queue a reload of the running code").set_defaults(func=cmd_reload)

    p = sub.add_parser(
        "pin", help="serve src/ as it is now until unpin or the next pin (controller ignores later edits)"
    )
    p.add_argument("--tree", help="pin one tree only (a src/ directory name; default all)")
    p.set_defaults(func=cmd_pin)
    p = sub.add_parser("unpin", help="serve the live tree again")
    p.add_argument("--tree", help="unpin one tree only (default all)")
    p.set_defaults(func=cmd_unpin)

    p = sub.add_parser("wait", help="wait for a queued command to finish")
    p.add_argument("id", type=int, help="command id as printed by run/set/reload")
    p.add_argument("--timeout", type=float, default=60, help="seconds to wait (default 60)")
    p.set_defaults(func=cmd_wait)

    p = sub.add_parser("log", help="show the shipped driver log")
    p.add_argument("-n", "--lines", type=int, default=50, help="how many trailing lines (default 50)")
    p.add_argument("-f", "--follow", action="store_true", help="keep printing as lines arrive")
    p.add_argument("--file", default=None, help="log file (default <state-dir>/driver.log)")
    p.set_defaults(func=cmd_log)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.func is not cmd_log:
            key_file = (
                os.path.abspath(os.path.expanduser(args.key_file)) if args.key_file else devserver.default_key_file()
            )
            args.token = token_for(key_file)
            args.server = (args.server or server_url(args.state_dir)).rstrip("/")
        return args.func(args)
    except DevctlError as exc:
        sys.stderr.write("devctl: %s\n" % exc)
        return EXIT_ERROR
    except KeyboardInterrupt:
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
