#!/usr/bin/env python3
"""Probe a Modern Forms fan's local interface from the VM (issue #17; docs/fan-probe.md).

  mf_probe.py read --fan ADDR [--static] [--count N] [--interval S] [--raw-dir DIR]
  mf_probe.py check K11|K12|K13|K15 --fan ADDR --expect-id LAST4 --yes-owner-told [--raw-dir DIR]
  mf_probe.py fixture --from RAWFILE --out tests/fixtures/NAME.json [--force]

read     POST /mf {"queryDynamicShadowData":1}, or {"queryStaticShadowData":1} with --static, --count
         times (at most 60), one every --interval seconds (at least 0.5, default 3), all within 60 s.
         Writes nothing to the fan.
check    The VM's write checks of docs/v1-design.md section 11, run only with --yes-owner-told and only
         on the fan whose client id ends in --expect-id (read before any write):
           K11  direction: the opposite of what the fan runs (reverse, usually), 3 reads over 10 s, the
                direction it had (forward), a read; the fan runs for it, at its own speed if it was off
           K12  the light's level while off: off, level 30 (60 if it is at 30), a read, on, a read,
                off, a read
           K13  bursts: 10 speed commands, then 20 level commands, back to back, one in flight; each
                burst ends on the value the fan had; latency, errors and the final state
           K15  the light stepped 1 -> 100 in 12 requests over 3 s, held 1 s, then 100 -> 1 the same way
         Each check reads the state first and puts back what it found (fan on or off, speed,
         direction, light on or off, level), also after an error or Ctrl-C, and reads again to
         verify. If the fan stops answering (two failed requests in a row), nothing more is sent and
         the report says the owner should switch it off at the wall for 10 s.
fixture  A raw answer saved with --raw-dir, as a test fixture: every private value replaced by the
         placeholders of docs/scaffold-design.md section 2 (MF_00005E005301, 00:00:5e:00:53:01,
         owner@example.com, ...); nothing is written if a private pattern survives.

The report (stdout, JSON) and the progress lines (stderr) can go into an issue or a Discussion as they
are: the fan's address is written <fan>; the client id and the MAC as <private>...5301 (their last
four hex digits); owner, federatedIdentity, deviceName, SSID, BSSID, timezone, location, schedule,
firmwareUrl, certificates and other ids as <private>; and anything matching the rules of
tools/gh-discussion.py and tools/deploy.py (imported from deploy.py) is masked. A report that would
still hold such data is not printed.

Safety rails: --fan takes a dotted private IPv4 address only (a loopback one only with
--allow-loopback, for the unit tests' fake fan); one request in flight and at least 0.25 s between
requests (none inside K13's bursts, 1 s after a failure); connect 3 s, total 5 s; one mf_probe.py at a
time (a lock in build/); every body built from the allow-list of docs/v1-design.md section 3.1, and a
body naming factoryReset, decommission, resetRfPairList, rfPairModeActive or reboot is refused before
anything is sent; during a check every answer must carry the pinned client id, and another fan
answering stops it; raw answers are written only with --raw-dir, under build/ (gitignored).

Standard library only. Exit codes: 0 done (a check: done and the state put back and verified),
1 error (the fan did not answer, the state was not put back, ...), 2 refused or usage (nothing was
written to the fan), 130 interrupted (after the state was put back).
"""

import argparse
import collections
import contextlib
import dataclasses
import datetime
import fcntl
import ipaddress
import json
import os
import re
import signal
import socket
import statistics
import sys
import threading
import time
import traceback

TOOLS = os.path.dirname(os.path.abspath(__file__))
if TOOLS not in sys.path:  # python3 -I leaves the script's own folder off sys.path
    sys.path.insert(0, TOOLS)

import deploy  # noqa: E402  (the private-data rules tools/gh-discussion.py applies as well)

ROOT = os.path.dirname(TOOLS)
EXIT_OK, EXIT_ERROR, EXIT_REFUSED, EXIT_INTERRUPTED = 0, 1, 2, 130

# Transport (docs/v1-design.md sections 3.1 to 3.4).
PATH = "/mf"
DEFAULT_PORT = 80
CONNECT_TIMEOUT_S = 3.0
TOTAL_TIMEOUT_S = 5.0
GAP_S = 0.25  # GAP_MS: from the end of one request to the start of the next
RETRY_GAP_S = 1.0  # after a failed request, inside a burst as well
FAILURES_TO_STOP = 2  # failed requests in a row after which the fan counts as not answering
MAX_HEAD_BYTES = 16 * 1024
MAX_BODY_BYTES = 64 * 1024  # the fan's answers are about 500 bytes (M0)

# read
READ_DEFAULT_INTERVAL_S = 3.0
READ_MIN_INTERVAL_S = 0.5
READ_MAX_COUNT = 60
READ_MAX_SPAN_S = 60.0

# The checks (docs/v1-design.md section 11).
SETTLE_S = 1.0  # from a write's answer to the read that checks it (K12, the restore's verify read)
K11_READS = 3
K11_READ_SPAN_S = 10.0
K11_AFTER_S = 2.0
K13_SPEEDS = (1, 2, 3, 4, 5, 6, 5, 4, 3)  # then the speed the fan had: 10 commands
K13_LEVELS = (1, 12, 23, 34, 45, 56, 67, 78, 89, 100, 89, 78, 67, 56, 45, 34, 23, 12, 1)  # then its level: 20
K13_FINAL_READ_S = 2.0
K15_STEPS = tuple(1 + 9 * step for step in range(12))  # 1, 10, 19, ..., 100
K15_STEP_S = 0.25  # 12 requests over 3 s, start to start
K15_HOLD_S = 1.0
K11_SPIN_UP_S = 3.0  # a fan K11 starts runs this long before the direction write ("with the fan running")
RESTORE_MAX_STEPS = 12
RESTORE_SAME_BODY = 2  # a body the fan does not take is sent at most twice

STATE_QUERY = {"queryDynamicShadowData": 1}
INFO_QUERY = {"queryStaticShadowData": 1}
# Never sent: a body naming one of them anywhere, in any case, is refused (docs/v1-design.md 3.1).
FORBIDDEN_KEYS = ("factoryReset", "decommission", "resetRfPairList", "rfPairModeActive", "reboot")
STATE_FIELDS = ("fanOn", "fanSpeed", "fanDirection", "lightOn", "lightBrightness")
FIELD_OF = dict(zip(STATE_FIELDS, ("fan_on", "speed", "direction", "light_on", "level"), strict=True))  # State's
DIRECTIONS = ("forward", "reverse")

# ---------------------------------------------------------------------------
# Private data
# ---------------------------------------------------------------------------

FAN_MARK = "<fan>"
PRIVATE = "<private>"
# Keys whose value is private (docs/v1-design.md section 3.7 and V20; docs/edge-cases-modernforms.md
# rule 8), and the parts of a key name that make it private too; any other key ending in "id" is
# private as well, but for the product ids of PRODUCT_IDS.
PRIVATE_KEYS = frozenset(
    (
        "owner",
        "federatedidentity",
        "devicename",
        "ssid",
        "bssid",
        "timezone",
        "location",
        "certificateid",
        "schedule",
        "firmwareurl",
    )
)
PRIVATE_KEY_PARTS = ("cert", "ssid", "owner", "identity", "location", "name", "email", "token", "passw", "secret")
PRODUCT_IDS = frozenset(("dimtableid",))
# The fan's own hardware ids (and any key ending in "mac"): masked but for their last four hex digits.
HARDWARE_ID_KEYS = frozenset(("clientid", "mac"))

# The placeholders of docs/scaffold-design.md section 2, for fixtures.
PLACEHOLDER_HEX = "00005e005301"  # MAC 00:00:5e:00:53:01, client id MF_00005E005301
BSSID_HEX = "00005e0053ff"
PLACEHOLDER_ADDRESS = "10.0.2.151"
PLACEHOLDER_EMAIL = "owner@example.com"
PLACEHOLDER_IDENTITY = "us-east-1:00000000-0000-0000-0000-000000000000"
FIXTURE_TEXT = {
    "owner": PLACEHOLDER_EMAIL,
    "federatedidentity": PLACEHOLDER_IDENTITY,
    "devicename": "Example Fan",
    "ssid": "example-ssid",
    "timezone": "UTC0",
}
# The keys of the house fan's two answers (M0, docs/v1-design.md section 10.1) and the Gen 1/2 ones of
# docs/modernforms-api-research.md section 2: a fixture names any other key for review.
KNOWN_KEYS = frozenset(
    (
        "clientId cloudPort lightOn fanOn lightBrightness fanSpeed fanDirection wind windSpeed rfPairModeActive "
        "resetRfPairList factoryReset awayModeEnabled fanTimer lightTimer decommission schedule adaptiveLearning "
        "userData timezone FrCodes cdebug feedbackToneMute mac lightType fanType fanMotorType brand dateCode owner "
        "federatedIdentity deviceName firmwareVersion esp-idf-version mainMcuFirmwareVersion firmwareUrl wifiSignal "
        "SSID BSSID isUvcFan built dimTableId elecFreq fanSleepTimer lightSleepTimer productionLotNumber productSku"
    ).split()
)

# A WAC-brand client id, WAC_ and the MAC's twelve hex digits: masked like an MF_ one.
WAC_CLIENT_ID_RE = re.compile(r"(?<![A-Za-z0-9])WAC_[0-9A-F]{12,}", re.IGNORECASE)
MAC_SHAPE_RE = re.compile(r"[0-9A-Fa-f]{2}([:-]?)(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}")
CLIENT_ID_PREFIX_RE = re.compile(r"[A-Za-z]+_")


def wac_client_id_passes(match):
    return deploy.PASSING_HARDWARE.fullmatch(match.group(0)[4:].lower()) is not None


def address_passes(match):
    """deploy.ipv4_passes, except that an address in the house subnet is replaced too (deploy leaves it to
    its own rule, which only names it)."""
    octets = tuple(int(number) for number in match.groups())
    return deploy.ipv4_passes(match) and octets[:3] != (10, 0, 1)


def private_findings(text):
    """What the rules of tools/deploy.py and tools/gh-discussion.py find in text, and a WAC client id:
    one reason per kind, naming its first line, never the data."""
    found = deploy.private_findings(text)
    for match in WAC_CLIENT_ID_RE.finditer(text):
        if not wac_client_id_passes(match):
            found.append("a WAC client id of a real fan (line %d)" % (text.count("\n", 0, match.start()) + 1))
            break
    return found


def last4(value):
    """The last four hex digits of an id or MAC, upper case; "" when it has fewer."""
    digits = re.sub(r"[^0-9A-Fa-f]", "", value) if isinstance(value, str) else ""
    return digits[-4:].upper() if len(digits) >= 4 else ""


def masked_id(value):
    tail = last4(value)
    return PRIVATE + "..." + tail if tail else PRIVATE


def shaped_mac(original, digits):
    """The twelve hex digits written as original writes a MAC: its separator and its case."""
    match = MAC_SHAPE_RE.fullmatch(original) if isinstance(original, str) else None
    separator = match.group(1) if match else ":"
    if match and re.search(r"[A-F]", original) and not re.search(r"[a-f]", original):
        digits = digits.upper()
    else:
        digits = digits.lower()
    return separator.join(digits[index : index + 2] for index in range(0, 12, 2))


def placeholder_client_id(original):
    prefix = CLIENT_ID_PREFIX_RE.match(original) if isinstance(original, str) else None
    return (prefix.group(0) if prefix else "MF_") + PLACEHOLDER_HEX.upper()


def key_kind(key):
    """'id' for the fan's hardware ids, 'private' for a private value, None for everything else."""
    if not isinstance(key, str):
        return None
    name = key.lower()
    if name in HARDWARE_ID_KEYS or name.endswith("mac"):
        return "id"
    if name in PRIVATE_KEYS or any(part in name for part in PRIVATE_KEY_PARTS):
        return "private"
    if name.endswith("id") and name not in PRODUCT_IDS:
        return "private"
    return None


class Scrubber:
    """Masks what the fan answers: by key (the private keys and the hardware ids), by the private
    patterns, the fan's address (as <fan>), and any private value it saw that turns up under another
    key. fixture=True writes the placeholders instead of the masks and raises Refused for a value it
    cannot clean."""

    def __init__(self, host=None, fixture=False):
        self.host_re = re.compile(r"(?<![0-9.])%s(?::[0-9]{1,5})?(?![0-9])" % re.escape(host)) if host else None
        self.fixture = fixture
        self.replacements = {}  # private string seen -> what it was replaced with
        if fixture:
            self.substitutions = (
                (deploy.IPV4_RE, address_passes, lambda match: PLACEHOLDER_ADDRESS),
                (deploy.MAC_RE, deploy.mac_passes, lambda match: shaped_mac(match.group(0), PLACEHOLDER_HEX)),
                (deploy.CLIENT_ID_RE, deploy.client_id_passes, lambda match: placeholder_client_id(match.group(0))),
                (WAC_CLIENT_ID_RE, wac_client_id_passes, lambda match: placeholder_client_id(match.group(0))),
                (deploy.EMAIL_RE, deploy.email_passes, lambda match: PLACEHOLDER_EMAIL),
                (deploy.IDENTITY_RE, deploy.identity_passes, lambda match: PLACEHOLDER_IDENTITY),
            )
        else:
            self.substitutions = (
                (deploy.IPV4_RE, address_passes, lambda match: PRIVATE),
                (deploy.MAC_RE, deploy.mac_passes, lambda match: masked_id(match.group(0))),
                (deploy.CLIENT_ID_RE, deploy.client_id_passes, lambda match: masked_id(match.group(0))),
                (WAC_CLIENT_ID_RE, wac_client_id_passes, lambda match: masked_id(match.group(0))),
                (deploy.EMAIL_RE, deploy.email_passes, lambda match: PRIVATE),
                (deploy.IDENTITY_RE, deploy.identity_passes, lambda match: PRIVATE),
            )

    def answer(self, data):
        """data with every private value masked (or replaced by its placeholder)."""
        self.learn(None, data)
        return self.value(None, data)

    def learn(self, key, value):
        """Note the private strings in value first, so that one turning up under another key is caught."""
        if isinstance(value, dict):
            for name, item in value.items():
                self.learn(name, item)
        elif isinstance(value, list):
            for item in value:
                self.learn(key, item)
        elif isinstance(value, str) and value and key_kind(key):
            self.replacements.setdefault(value, self.private(key, value))

    def value(self, key, value):
        if key_kind(key) and value not in ("", None):
            return self.private(key, value)
        if isinstance(value, dict):
            return {name: self.value(name, item) for name, item in value.items()}
        if isinstance(value, list):
            return [self.value(key, item) for item in value]
        if isinstance(value, str):
            return self.text(value, key)
        return value

    def private(self, key, value):
        """The mask or the placeholder for the value of a private key or a hardware id."""
        name = key.lower()
        if key_kind(key) == "id":
            if not isinstance(value, str):
                return PRIVATE
            if not self.fixture:
                return masked_id(value)
            if name == "clientid":
                return placeholder_client_id(value)
            return shaped_mac(value, PLACEHOLDER_HEX) if MAC_SHAPE_RE.fullmatch(value) else PRIVATE
        if self.fixture and isinstance(value, str):
            if name in FIXTURE_TEXT:
                return FIXTURE_TEXT[name]
            if name == "bssid" and MAC_SHAPE_RE.fullmatch(value):
                return shaped_mac(value, BSSID_HEX)
        return PRIVATE

    def text(self, value, key=None):
        """A free text with the fan's address, the private values seen and the private patterns replaced;
        one that would still hold private data becomes <private> (a fixture refuses it)."""
        if self.host_re:
            value = self.host_re.sub(FAN_MARK, value)
        for original in sorted(self.replacements, key=len, reverse=True):
            if len(original) >= 4 and original in value:
                value = value.replace(original, self.replacements[original])
        for pattern, passes, replace in self.substitutions:
            value = pattern.sub(
                lambda match, ok=passes, new=replace: match.group(0) if ok(match) else new(match), value
            )
        problems = private_findings(value)
        if problems:
            if self.fixture:
                where = "the value of %s" % key if key else "a value"
                raise Refused("%s still holds %s after the placeholders" % (where, problems[0].rpartition(" (")[0]))
            return PRIVATE
        return value

    def leaks(self, text):
        """Why text may not leave the VM: the private patterns, the fan's address, a private value seen."""
        found = private_findings(text)
        if self.host_re and self.host_re.search(text):
            found.append("the fan's address")
        for original, replacement in self.replacements.items():
            if len(original) >= 4 and original not in replacement and original in text:
                found.append("a private value of the fan's answer")
                break
        return found


# ---------------------------------------------------------------------------
# Request bodies
# ---------------------------------------------------------------------------


class ProbeError(Exception):
    """A user-facing error: exit 1."""


class Refused(ProbeError):
    """A safety rail refused the run or a request: exit 2, and nothing was written to the fan."""


class ForbiddenBody(Refused):
    """A body this tool never sends; nothing was sent."""


class ForeignFan(ProbeError):
    """Another fan answered at the address during a check: nothing more is sent."""


class FanStuck(ProbeError):
    """FAILURES_TO_STOP requests in a row failed: the fan counts as not answering."""


def _whole(value, low, high):
    return type(value) is int and low <= value <= high


def allowed_shape(body):
    """Whether body is one of the two queries or one of the five writes of docs/v1-design.md section 3.1
    that this tool sends: fan on at a speed, fan off, a direction, a light level, light on or off."""
    keys = tuple(body)
    if keys in (("queryDynamicShadowData",), ("queryStaticShadowData",)):
        return type(body[keys[0]]) is int and body[keys[0]] == 1
    if keys == ("fanOn", "fanSpeed"):
        return body["fanOn"] is True and _whole(body["fanSpeed"], 1, 6)
    if keys == ("fanOn",):
        return body["fanOn"] is False
    if keys == ("fanDirection",):
        return body["fanDirection"] in DIRECTIONS
    if keys == ("lightBrightness",):
        return _whole(body["lightBrightness"], 1, 100)
    if keys == ("lightOn",):
        return type(body["lightOn"]) is bool
    return False


def body_text(body):
    """The JSON text of a request body, written as the driver writes it (keys in order, no spaces), or
    ForbiddenBody: a body naming factoryReset, decommission, resetRfPairList, rfPairModeActive or
    reboot anywhere, in any case, and any body outside allowed_shape()."""
    try:
        text = json.dumps(body, separators=(",", ":"))
    except (TypeError, ValueError):
        raise ForbiddenBody("not a JSON body; nothing was sent") from None
    lowered = text.lower()
    for name in FORBIDDEN_KEYS:
        if name.lower() in lowered:
            raise ForbiddenBody("the body names %s, which this tool never sends; nothing was sent" % name)
    if not isinstance(body, dict) or not allowed_shape(body):
        raise ForbiddenBody("%s is not a body of the allow-list (docs/v1-design.md 3.1); nothing was sent" % text)
    return text


# ---------------------------------------------------------------------------
# HTTP: one POST on its own connection, with a connect and a total deadline
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class Answer:
    """One request's outcome, classified as docs/v1-design.md section 3.3 does: ok, timeout, connect,
    http, empty or json."""

    kind: str
    ms: int
    status: int | None = None
    raw: bytes = b""
    data: dict | None = None
    error: str = ""

    @property
    def ok(self):
        return self.kind == "ok"


class ResponseError(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


def receive(sock, deadline):
    """Status, headers and body of one HTTP answer on sock, all of it before deadline (TimeoutError)."""

    def more():
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError
        sock.settimeout(left)
        return sock.recv(16384)

    data = b""
    while b"\r\n\r\n" not in data:
        chunk = more()
        if not chunk:
            raise ResponseError("connect", "the fan closed the connection %s" % ("early" if data else "unanswered"))
        data += chunk
        if len(data) > MAX_HEAD_BYTES + MAX_BODY_BYTES:
            raise ResponseError("http", "an answer of more than %d bytes" % (MAX_HEAD_BYTES + MAX_BODY_BYTES))
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.decode("iso-8859-1").split("\r\n")
    status = re.match(r"HTTP/1\.[01] ([0-9]{3})(?: |$)", lines[0])
    if not status:
        raise ResponseError("http", "not an HTTP answer")
    headers = {}
    for line in lines[1:]:
        name, separator, value = line.partition(":")
        if separator:
            headers[name.strip().lower()] = value.strip()
    if "transfer-encoding" in headers:
        raise ResponseError("http", "a Transfer-Encoding answer, which a Modern Forms fan does not send")
    length = headers.get("content-length")
    if length is None:  # the answer ends where the fan closes the connection (we sent Connection: close)
        while True:
            chunk = more()
            if not chunk:
                return int(status.group(1)), headers, body
            body += chunk
            if len(body) > MAX_BODY_BYTES:
                raise ResponseError("http", "an answer of more than %d bytes" % MAX_BODY_BYTES)
    if not re.fullmatch(r"[0-9]{1,9}", length) or int(length) > MAX_BODY_BYTES:
        raise ResponseError("http", "a Content-Length of %r" % length[:20])
    wanted = int(length)
    while len(body) < wanted:
        chunk = more()
        if not chunk:
            raise ResponseError("connect", "the fan closed the connection %d bytes short" % (wanted - len(body)))
        body += chunk
    return int(status.group(1)), headers, body[:wanted]


def post(host, port, text):
    """POST text to http://host:port/mf on a connection of its own, closed afterwards: at most
    CONNECT_TIMEOUT_S to connect and TOTAL_TIMEOUT_S in all. Never raises for the fan's sake."""
    start = time.monotonic()
    deadline = start + TOTAL_TIMEOUT_S
    payload = text.encode("utf-8")
    host_header = host if port == DEFAULT_PORT else "%s:%d" % (host, port)
    request = (
        "POST %s HTTP/1.1\r\nHost: %s\r\nAccept: */*\r\nContent-Type: application/json\r\n"
        "Content-Length: %d\r\nConnection: close\r\n\r\n" % (PATH, host_header, len(payload))
    ).encode("ascii") + payload

    def took():
        return int(round((time.monotonic() - start) * 1000))

    connect = min(CONNECT_TIMEOUT_S, TOTAL_TIMEOUT_S)
    try:
        sock = socket.create_connection((host, port), timeout=connect)
    except TimeoutError:
        return Answer("timeout", took(), error="no connection within %.1f s" % connect)
    except OSError as err:
        return Answer("connect", took(), error=err.strerror or type(err).__name__)
    try:
        with sock:
            sock.settimeout(max(0.001, deadline - time.monotonic()))
            sock.sendall(request)
            status, _headers, body = receive(sock, deadline)
    except TimeoutError:
        return Answer("timeout", took(), error="no complete answer within %.1f s" % TOTAL_TIMEOUT_S)
    except ResponseError as err:
        return Answer(err.kind, took(), error=str(err))
    except OSError as err:
        return Answer("connect", took(), error=err.strerror or type(err).__name__)
    ms = took()
    if status != 200:
        return Answer("http", ms, status=status, raw=body, error="HTTP %d" % status)
    if not body.strip():
        return Answer("empty", ms, status=status, raw=body, error="an empty answer")
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return Answer("json", ms, status=status, raw=body, error="not JSON")
    if not isinstance(data, dict):
        return Answer("json", ms, status=status, raw=body, error="not a JSON object")
    if not isinstance(data.get("clientId"), str) or not data["clientId"]:
        return Answer("json", ms, status=status, raw=body, data=data, error="no clientId")
    return Answer("ok", ms, status=status, raw=body, data=data)


# ---------------------------------------------------------------------------
# The fan's state
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class State:
    """The five fields a check changes and puts back."""

    fan_on: bool
    speed: int
    direction: str
    light_on: bool
    level: int

    def text(self):
        return "fan %s/%d %s, light %s/%d" % (
            "on" if self.fan_on else "off",
            self.speed,
            self.direction,
            "on" if self.light_on else "off",
            self.level,
        )


def fan_state(data):
    """The State of a dynamic shadow, or None when one of its five fields is missing or of the wrong type."""
    if not isinstance(data, dict) or not all(key in data for key in STATE_FIELDS):
        return None
    fan_on, speed, direction, light_on, level = (data[key] for key in STATE_FIELDS)
    if type(fan_on) is not bool or type(light_on) is not bool or type(speed) is not int or type(level) is not int:
        return None
    if direction not in DIRECTIONS:
        return None
    return State(fan_on, speed, direction, light_on, level)


def restore_body(current, before):
    """The next body that brings the fan from current back to before, or None when nothing is left.
    The direction first, while the fan still runs; then the fan (a fan that is off is never started
    just to correct the speed it keeps); then the light: the level first and on last when it was on,
    off first and the level last when it was off, so it never flashes at a level it did not have."""
    if current.direction != before.direction:
        return {"fanDirection": before.direction}
    speed_known = 1 <= before.speed <= 6
    if before.fan_on:
        if speed_known and (not current.fan_on or current.speed != before.speed):
            return {"fanOn": True, "fanSpeed": before.speed}
    elif current.fan_on:
        if speed_known and current.speed != before.speed:
            return {"fanOn": True, "fanSpeed": before.speed}  # its speed while it still runs; off next
        return {"fanOn": False}
    level_known = 1 <= before.level <= 100
    if before.light_on:
        if level_known and current.level != before.level:
            return {"lightBrightness": before.level}
        if not current.light_on:
            return {"lightOn": True}
    else:
        if current.light_on:
            return {"lightOn": False}
        if level_known and current.level != before.level:
            return {"lightBrightness": before.level}
    return None


def differences(after, before):
    """What after still has that before did not, as texts; empty when the fan is back."""
    found = []
    for field in dataclasses.fields(State):
        was, now = getattr(before, field.name), getattr(after, field.name)
        if was == now:
            continue
        if field.name == "speed" and not 1 <= was <= 6:
            continue  # "off, speed unknown" (docs/v1-design.md 3.3): nothing to put back
        if field.name == "level" and not 1 <= was <= 100:
            continue
        found.append("%s is %s, was %s" % (field.name.replace("_", " "), json.dumps(now), json.dumps(was)))
    return found


def ending_with(walk, final, low, high):
    """walk and then final; the walk's last value is moved off final, so that the last command is a change."""
    values = list(walk)
    if values[-1] == final:
        values[-1] = final - 1 if final > low else final + 1
    return values + [final]


def spread(values):
    if not values:
        return None
    return {"min": min(values), "median": int(statistics.median(values)), "max": max(values)}


# ---------------------------------------------------------------------------
# The fan: every request goes through Fan.request
# ---------------------------------------------------------------------------


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def say(text):
    print(text, file=sys.stderr, flush=True)


class RawWriter:
    """Saves raw answers under build/ (gitignored) and nowhere else; files readable by their owner only."""

    def __init__(self, directory, root=None):
        self.build = os.path.realpath(os.path.join(root or ROOT, "build"))
        self.directory = os.path.realpath(directory)
        if os.path.commonpath([self.directory, self.build]) != self.build:
            raise Refused("--raw-dir must lie under build/ (gitignored), so that raw answers stay off GitHub")
        self.stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.count = 0

    def save(self, step, raw, is_json):
        """The saved file's path as build/..., or why it was not saved (never raises: a restore goes on)."""
        self.count += 1
        slug = re.sub(r"[^a-z0-9]+", "-", step.lower()).strip("-")[:40] or "answer"
        name = "mf-%s-%02d-%s.%s" % (self.stamp, self.count, slug, "json" if is_json else "txt")
        path = os.path.join(self.directory, name)
        try:
            os.makedirs(self.directory, mode=0o700, exist_ok=True)
            handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(handle, "wb") as out:
                out.write(raw)
        except OSError as err:
            return "not saved: %s" % (err.strerror or type(err).__name__)
        return os.path.join("build", os.path.relpath(path, self.build))


class Fan:
    """The one way to the fan: one request in flight, the gap between requests, every body checked
    before anything is sent, every answer checked against the pinned client id, and a log entry per
    request (masked) for the report."""

    def __init__(self, host, port, sleep=time.sleep, clock=time.monotonic, raw=None):
        self.host = host
        self.port = port
        self.sleep = sleep
        self.clock = clock
        self.raw = raw
        self.scrubber = Scrubber(host=host)
        self.entries = []
        self.answers = []
        self.pinned = None  # the client id every answer must carry, once set
        self.foreign = None  # the masked id of another fan that answered: nothing more is sent
        self.state = None  # the State of the latest answer that had one
        self.in_flight = False
        self.last_end = None
        self.failures = 0  # in a row

    def request(self, body, step, gap=GAP_S):
        text = body_text(body)  # raises ForbiddenBody before anything happens
        if self.foreign:
            raise ForeignFan("another fan (%s) answers at the address: nothing more is sent" % self.foreign)
        if self.in_flight:
            raise RuntimeError("a second request while one is in flight")
        if self.last_end is not None:
            wait = max(gap, RETRY_GAP_S if self.failures else 0) - (self.clock() - self.last_end)
            if wait > 0:
                self.sleep(wait)
        at = utc_now()
        started = time.monotonic()
        self.in_flight = True
        try:
            answer = post(self.host, self.port, text)
        except KeyboardInterrupt:  # logged too: the fan may have taken it
            took = int(round((time.monotonic() - started) * 1000))
            cut = Answer("interrupted", took, error="Ctrl-C while it was in flight")
            self.answers.append(cut)
            self.record(step, body, text, at, cut)
            raise
        finally:
            self.in_flight = False
            self.last_end = self.clock()
        self.answers.append(answer)
        self.record(step, body, text, at, answer)
        if answer.ok:
            self.failures = 0
            if self.pinned is not None and answer.data.get("clientId") != self.pinned:
                self.foreign = masked_id(answer.data.get("clientId"))
                raise ForeignFan(
                    "another fan (%s) answered instead of %s: nothing more was sent"
                    % (self.foreign, masked_id(self.pinned))
                )
            self.state = fan_state(answer.data) or self.state
        else:
            self.failures += 1
            if self.failures >= FAILURES_TO_STOP:
                raise FanStuck("%d requests in a row failed" % self.failures)
        return answer

    def record(self, step, body, text, at, answer):
        entry = {"n": len(self.entries) + 1, "at": at, "step": step, "body": body, "result": answer.kind}
        if answer.status is not None:
            entry["status"] = answer.status
        entry["ms"] = answer.ms
        if answer.error:
            entry["error"] = self.scrubber.text(answer.error)
        state = fan_state(answer.data) if answer.data is not None else None
        if state is not None:
            entry["state"] = state.text()
        if answer.data is not None:
            entry["answer"] = self.scrubber.answer(answer.data)
        elif answer.raw:
            entry["bytes"] = len(answer.raw)
            entry["text"] = self.scrubber.text(answer.raw[:120].decode("utf-8", "replace"))
        if self.raw is not None and answer.raw:
            entry["raw"] = self.raw.save(step, answer.raw, answer.data is not None)
        self.entries.append(entry)
        outcome = "%s in %.2f s" % (
            answer.kind if answer.status in (None, 200) else "HTTP %d" % answer.status,
            answer.ms / 1000,
        )
        if state is not None:
            outcome += ": " + state.text()
        elif answer.error:
            outcome += ": " + entry["error"]
        say("#%d %s %s: %s" % (entry["n"], step, text, outcome))


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------

POWER_CYCLE = (
    "The fan stopped answering: nothing more was sent. Ask the owner to switch it off at the wall for "
    "10 s and on again. It was: %s."
)


@contextlib.contextmanager
def deferred_interrupts():
    """Ctrl-C waits until the block is done (the restore: a few requests of at most 5 s each); the list
    it yields says whether one came."""
    caught = []
    if threading.current_thread() is not threading.main_thread():
        yield caught
        return

    def hold(signum, frame):
        caught.append(signum)
        say("Ctrl-C: the fan's state is being put back first (a few seconds)")

    previous = signal.signal(signal.SIGINT, hold)
    try:
        yield caught
    finally:
        signal.signal(signal.SIGINT, previous)


class Session:
    """One check on one fan: the identity pinned, the state found, the steps, the restore."""

    def __init__(self, fan, sleep, clock):
        self.fan = fan
        self.sleep = sleep
        self.clock = clock
        self.light_kit = None
        self.findings = {}
        self.verdict = None
        self.notes = []

    def note(self, text):
        self.notes.append(text)
        say("note: " + text)

    def read(self, step):
        return self.fan.request(STATE_QUERY, step)

    def write(self, body, step, gap=GAP_S):
        return self.fan.request(body, step, gap=gap)

    def pin(self, expect_id):
        """Read the identity and the state; refuse unless the client id ends in expect_id."""
        info = self.fan.request(INFO_QUERY, "identity")
        if info.status == 404:
            raise Refused("/mf answers HTTP 404: not a Gen 1-3 fan (a Gen 4 one is out of v1); nothing was written")
        if not info.ok:
            raise ProbeError("the fan did not answer the identity read (%s): nothing was written" % info.kind)
        found = last4(info.data["clientId"])
        if found != expect_id.upper():
            raise Refused(
                "the fan answering there has a client id ending in %s, not %s: nothing was written"
                % (found or "?", expect_id.upper())
            )
        self.fan.pinned = info.data["clientId"]
        self.light_kit = bool(info.data.get("lightType"))
        answer = self.read("state before")
        before = fan_state(answer.data) if answer.ok else None
        if before is None:
            raise ProbeError(
                "the state read %s: nothing to put back afterwards, so nothing was written"
                % ("lacks one of " + ", ".join(STATE_FIELDS) if answer.ok else "failed (%s)" % answer.kind)
            )
        return before

    def burst(self, bodies, name, field):
        """bodies back to back, one in flight; what came back."""
        start = self.clock()
        answers = []
        for number, body in enumerate(bodies, 1):
            answers.append(self.write(body, "%s burst %d of %d" % (name, number, len(bodies)), gap=0))
        return self.tally(answers, start, [(field, body[field]) for body in bodies])

    def ramp(self, levels, name):
        """The light's levels, one every K15_STEP_S start to start (or right after the previous answer)."""
        start = self.clock()
        answers = []
        for number, level in enumerate(levels):
            wait = start + number * K15_STEP_S - self.clock()
            if wait > 0:
                self.sleep(wait)
            step = "%s %d of %d" % (name, number + 1, len(levels))
            answers.append(self.write({"lightBrightness": level}, step, gap=0))
        return self.tally(answers, start, [("lightBrightness", level) for level in levels])

    def tally(self, answers, start, sent):
        took = [answer.ms for answer in answers if answer.ok]
        echoed = sum(
            1
            for answer, (field, value) in zip(answers, sent, strict=True)
            if answer.ok and answer.data.get(field) == value
        )
        return {
            "sent": len(answers),
            "answered": len(took),
            "errors": dict(collections.Counter(answer.kind for answer in answers if not answer.ok)),
            "echo_matched": echoed,
            "ms": spread(took),
            "span_s": round(self.clock() - start, 2),
        }

    def restore(self, before):
        """Put back what the check found, then read to verify. Interrupts wait; returns what happened."""
        result = {"restored": False}
        with deferred_interrupts() as interrupts:
            try:
                result.update(self._restore(before))
            except ForeignFan as err:
                result["error"] = str(err)
            except FanStuck:
                result["stuck"] = True
                result["error"] = "the fan did not answer"
        if interrupts:
            result["interrupted"] = True
        return result

    def _restore(self, before):
        answer = self.read("restore: read")
        current = fan_state(answer.data) if answer.ok else None
        if current is None:
            answer = self.read("restore: read again")
            current = fan_state(answer.data) if answer.ok else None
            if current is None:
                return {"error": "no state to start from (%s)" % answer.kind}
        sent = collections.Counter()
        for _ in range(RESTORE_MAX_STEPS):
            body = restore_body(current, before)
            if body is None:
                break
            text = body_text(body)
            if sent[text] >= RESTORE_SAME_BODY:
                # The fan does not take it: carry on with the other fields; the verify read reports this one.
                current = dataclasses.replace(current, **{FIELD_OF[key]: value for key, value in body.items()})
                continue
            sent[text] += 1
            answer = self.write(body, "restore")
            if answer.ok:
                current = fan_state(answer.data) or current
        self.sleep(SETTLE_S)
        answer = self.read("restore: verify")
        after = fan_state(answer.data) if answer.ok else None
        if after is None:
            return {"error": "the verify read failed (%s)" % answer.kind}
        left = differences(after, before)
        result = {"restored": not left, "after": after.text()}
        if left:
            result["not_restored"] = left
        return result


def check_k11(session, before):
    """Direction (V18, can_reverse): does the fan keep answering after a direction write?"""
    opposite = DIRECTIONS[1] if before.direction == DIRECTIONS[0] else DIRECTIONS[0]
    if not before.fan_on:
        speed = before.speed if 1 <= before.speed <= 6 else 1
        session.note("the fan was off: it runs at speed %d for the check and stops again at the end" % speed)
        session.write({"fanOn": True, "fanSpeed": speed}, "fan on for K11")
        session.sleep(K11_SPIN_UP_S)
    session.findings = {"sent": opposite}
    first = session.write({"fanDirection": opposite}, "direction " + opposite)
    reads = []
    for number in range(1, K11_READS + 1):
        session.sleep(K11_READ_SPAN_S / K11_READS)
        reads.append(session.read("read %d of %d" % (number, K11_READS)))
    back = session.write({"fanDirection": before.direction}, "direction %s again" % before.direction)
    session.sleep(K11_AFTER_S)
    last = session.read("read after")

    def direction(answer):
        return answer.data.get("fanDirection") if answer.ok else answer.kind

    answers = [first, *reads, back, last]
    missed = sum(1 for answer in answers if not answer.ok)
    seen = [direction(answer) for answer in reads]
    session.findings.update(
        echo=direction(first),
        reads=seen,
        back=before.direction,
        back_echo=direction(back),
        read_after=direction(last),
        missed=missed,
    )
    if missed:
        session.verdict = (
            "K11 failed: the fan missed %d of %d requests around the direction writes (can_reverse False)"
            % (missed, len(answers))
        )
    elif direction(first) == opposite and seen == [opposite] * K11_READS and direction(last) == before.direction:
        session.verdict = (
            "K11 passed: the fan answered every request around both direction writes and reported "
            "each direction it was sent (can_reverse True)"
        )
    else:
        session.verdict = "K11: the fan kept answering but did not report the direction it was sent (see reads)"


def check_k12(session, before):
    """The light's level while off (V14's two steps): kept off, stored, used by the next on, kept."""
    level = 30 if before.level != 30 else 60
    if before.light_on:
        session.write({"lightOn": False}, "light off")
        session.sleep(SETTLE_S)
    session.write({"lightBrightness": level}, "level %d while off" % level)
    session.sleep(SETTLE_S)
    first = session.read("read: still off?")
    session.write({"lightOn": True}, "light on")
    session.sleep(SETTLE_S)
    second = session.read("read: on at %d?" % level)
    session.write({"lightOn": False}, "light off")
    session.sleep(SETTLE_S)
    third = session.read("read: level %d kept?" % level)

    def light(answer):
        state = fan_state(answer.data) if answer.ok else None
        return {"on": state.light_on, "level": state.level} if state else answer.kind

    seen = [light(answer) for answer in (first, second, third)]
    checks = {
        "level_while_off_keeps_the_light_off": isinstance(seen[0], dict) and not seen[0]["on"],
        "level_while_off_is_stored": isinstance(seen[0], dict) and seen[0]["level"] == level,
        "on_comes_at_that_level": seen[1] == {"on": True, "level": level},
        "level_kept_while_off": seen[2] == {"on": False, "level": level},
    }
    session.findings = {"level_sent": level, "after_level": seen[0], "after_on": seen[1], "after_off": seen[2]}
    session.findings.update(checks)
    failed = [name for name, passed in checks.items() if not passed]
    if not all(isinstance(item, dict) for item in seen):
        session.verdict = "K12 incomplete: a read failed (see findings); run it again"
    elif failed:
        session.verdict = "K12: not as V14 assumes: " + ", ".join(
            name.replace("_", " ") + " is false" for name in failed
        )
    else:
        session.verdict = (
            "K12 passed: a level sent while the light is off keeps it off and is stored, on comes at that "
            "level, and the level is kept while off (V14's two steps hold)"
        )


def check_k13(session, before):
    """Bursts (GAP_MS, RAMP_STEP_MS): 10 speed commands, then 20 level commands, back to back."""
    speed = before.speed if 1 <= before.speed <= 6 else 1
    speeds = ending_with(K13_SPEEDS, speed, 1, 6)
    session.findings = {
        "speed_burst": session.burst([{"fanOn": True, "fanSpeed": value} for value in speeds], "speed", "fanSpeed")
    }
    expected = State(True, speed, before.direction, before.light_on, before.level)
    if session.light_kit:
        level = before.level if 1 <= before.level <= 100 else 50
        current = session.fan.state
        if current is None or not current.light_on:
            session.write({"lightOn": True}, "light on for the level burst")
        levels = ending_with(K13_LEVELS, level, 1, 100)
        bodies = [{"lightBrightness": value} for value in levels]
        session.findings["level_burst"] = session.burst(bodies, "level", "lightBrightness")
        expected = dataclasses.replace(expected, light_on=True, level=level)
    else:
        session.note("no light kit (lightType is empty): the level burst is skipped")
    session.sleep(K13_FINAL_READ_S)
    final = session.read("final state")
    state = fan_state(final.data) if final.ok else None
    matches = state is not None and dataclasses.replace(state, direction=expected.direction) == expected
    session.findings["final"] = {
        "state": state.text() if state else final.kind,
        "expected": expected.text(),
        "matches": matches,
    }
    bursts = [session.findings[name] for name in ("speed_burst", "level_burst") if name in session.findings]
    errors = sum(sum(burst["errors"].values()) for burst in bursts)
    if state is None:
        final_text = "could not be read"
    else:
        final_text = "%s the last commands" % ("matches" if matches else "does NOT match")
    session.verdict = "K13: %d of %d burst commands answered, %d errors; the final state %s" % (
        sum(burst["answered"] for burst in bursts),
        sum(burst["sent"] for burst in bursts),
        errors,
        final_text,
    )


def check_k15(session, before):
    """The light stepped 1 -> 100 in 12 requests over 3 s, then down: a dim or a staircase?"""
    if not before.light_on:
        session.write({"lightBrightness": K15_STEPS[0]}, "level %d while off" % K15_STEPS[0])
        current = session.fan.state
        if current is None or not current.light_on:
            session.write({"lightOn": True}, "light on at %d" % K15_STEPS[0])
        session.sleep(K15_HOLD_S)
    up = session.ramp(K15_STEPS, "up")
    session.findings = {"up": up}
    session.sleep(K15_HOLD_S)
    session.findings["down"] = session.ramp(tuple(reversed(K15_STEPS)), "down")
    session.findings["ask_the_owner"] = "a smooth dim, or a staircase of 12 steps?"
    session.verdict = "K15: the steps went out (%d of %d answered); the owner's eyes decide: dim or staircase" % (
        up["answered"] + session.findings["down"]["answered"],
        up["sent"] + session.findings["down"]["sent"],
    )


# name: (function, needs a light kit)
CHECKS = {
    "K11": (check_k11, False),
    "K12": (check_k12, True),
    "K13": (check_k13, False),
    "K15": (check_k15, True),
}


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


# The report's keys in the order a reader wants them: what ran, the verdict, then the detail.
REPORT_ORDER = (
    "tool",
    "command",
    "check",
    "query",
    "count",
    "interval_s",
    "fan",
    "started",
    "finished",
    "id",
    "before",
    "verdict",
    "attention",
    "refused",
    "error",
    "interrupted",
    "stuck",
    "notes",
    "summary",
    "findings",
    "restore",
    "requests",
)


def new_report(command, **fields):
    report = {"tool": "tools/mf_probe.py", "command": command}
    report.update(fields)
    report.update(fan=FAN_MARK, started=utc_now())
    return report


def emit(report, scrubber):
    """Print the report, unless it would still hold private data (then say why, never what)."""
    report = {key: report[key] for key in REPORT_ORDER if key in report} | {
        key: value for key, value in report.items() if key not in REPORT_ORDER
    }
    text = json.dumps(report, indent=2) + "\n"
    problems = scrubber.leaks(text)
    if problems:
        say("mf_probe: the report is not printed: it would still hold " + "; ".join(problems))
        return False
    sys.stdout.write(text)
    sys.stdout.flush()
    return True


def run_read(fan, query, count, interval, sleep, clock):
    report = new_report("read", query="info" if query == INFO_QUERY else "state", count=count)
    if count > 1:
        report["interval_s"] = interval
    code = EXIT_OK
    start = None
    try:
        for number in range(count):
            if start is None:
                start = clock()
            else:
                wait = start + number * interval - clock()
                if wait > 0:
                    sleep(wait)
            fan.request(query, "read %d of %d" % (number + 1, count))
    except FanStuck:
        code = EXIT_ERROR
        report["attention"] = (
            "The fan stopped answering: nothing more was sent. If it does not answer the app either, ask the "
            "owner to switch it off at the wall for 10 s and on again."
        )
    except KeyboardInterrupt:
        code = EXIT_INTERRUPTED
        report["interrupted"] = True
    answered = [answer for answer in fan.answers if answer.ok]
    ids = []
    for answer in answered:
        if masked_id(answer.data["clientId"]) not in ids:
            ids.append(masked_id(answer.data["clientId"]))
    report["summary"] = {
        "sent": len(fan.answers),
        "answered": len(answered),
        "errors": dict(collections.Counter(answer.kind for answer in fan.answers if not answer.ok)),
        "ms": spread([answer.ms for answer in answered]),
        "ids": ids,
    }
    if len(ids) > 1:
        report["summary"]["note"] = "more than one fan answered at this address"
    report["finished"] = utc_now()
    report["requests"] = fan.entries
    if not answered and code == EXIT_OK:
        code = EXIT_ERROR
    if not emit(report, fan.scrubber):
        code = max(code, EXIT_ERROR)
    return code


def run_check(name, fan, expect_id, sleep, clock):
    run, needs_light = CHECKS[name]
    session = Session(fan, sleep, clock)
    report = new_report("check", check=name)
    code = EXIT_OK
    before = None
    say("%s on %s (the fan whose client id ends in %s)" % (name, FAN_MARK, expect_id.upper()))
    try:
        before = session.pin(expect_id)
        report["id"] = masked_id(fan.pinned)
        report["before"] = before.text()
        if needs_light and not session.light_kit:
            raise Refused(
                "%s needs a light kit, and this fan reports none (lightType is empty): nothing was written" % name
            )
        try:
            run(session, before)
        finally:
            report["restore"] = session.restore(before)
    except KeyboardInterrupt:
        code = EXIT_INTERRUPTED
        report["interrupted"] = True
    except Refused as err:
        code = EXIT_REFUSED
        report["refused"] = str(err)
        say("mf_probe: refused: %s" % err)
    except FanStuck:
        code = EXIT_ERROR
        report["stuck"] = True
    except ProbeError as err:
        code = EXIT_ERROR
        report["error"] = str(err)
        say("mf_probe: error: %s" % err)
    except Exception as err:  # a bug: the state was put back above; keep the report and the traceback
        code = EXIT_ERROR
        report["error"] = "%s: %s" % (type(err).__name__, fan.scrubber.text(str(err)))
        traceback.print_exc()
    restore = report.get("restore") or {}
    if restore.get("interrupted") and code == EXIT_OK:
        code = EXIT_INTERRUPTED
        report["interrupted"] = True
    if restore and not restore.get("restored") and code in (EXIT_OK, EXIT_REFUSED):
        code = EXIT_ERROR
    if before is not None and (report.get("stuck") or restore.get("stuck")):
        report["attention"] = POWER_CYCLE % before.text()
        say(report["attention"])
    if session.notes:
        report["notes"] = session.notes
    report["findings"] = session.findings
    if session.verdict:
        report["verdict"] = session.verdict
    if name == "K11" and "sent" in session.findings and (report.get("stuck") or restore.get("stuck")):
        report["verdict"] = "K11 failed: the fan stopped answering after a direction write (can_reverse False)"
    report["finished"] = utc_now()
    report["requests"] = fan.entries
    if report.get("verdict"):
        say(report["verdict"])
    if not emit(report, fan.scrubber):
        code = max(code, EXIT_ERROR)
    return code


def make_fixture(source, out, force):
    if not out.endswith(".json"):
        raise Refused("--out must name a .json file")
    if os.path.lexists(out) and not force:
        raise Refused("%s exists (--force replaces it)" % out)
    with open(source, "rb") as handle:
        raw = handle.read()
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ProbeError("%s is not a JSON answer" % source) from None
    if not isinstance(data, dict):
        raise ProbeError("%s is not a JSON object" % source)
    scrubber = Scrubber(fixture=True)
    text = json.dumps(scrubber.answer(data), indent=2) + "\n"
    problems = scrubber.leaks(text)
    if problems:
        raise Refused("nothing written: the fixture would still hold " + "; ".join(problems))
    new = [key for key in data if key not in KNOWN_KEYS]
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(text)
    say("wrote %s (%d keys, the private values replaced by the placeholders)" % (out, len(data)))
    if new:
        say("review before committing: keys the M0 answers did not have, kept as sent: " + ", ".join(new))
    return EXIT_OK


@contextlib.contextmanager
def probe_lock(root=None):
    """One mf_probe.py at a time, whichever fan: a lock file in build/."""
    path = os.path.join(root or ROOT, "build", ".mf_probe.lock")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    handle = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused("another mf_probe.py is talking to a fan: one at a time") from None
        yield
    finally:
        os.close(handle)


def parse_fan(text, allow_loopback=False):
    """(host, port) of --fan: a dotted IPv4 address on a private network, optionally :PORT (80)."""
    host, separator, port = text.partition(":")
    try:
        address = ipaddress.IPv4Address(host)
    except ValueError:
        raise Refused("--fan wants the fan's dotted IPv4 address (no names, no IPv6), optionally :PORT") from None
    if address.is_loopback:
        if not allow_loopback:
            raise Refused("--fan is a loopback address, where only the unit tests' fake fan lives (--allow-loopback)")
    elif address.is_unspecified or address.is_multicast or address.is_reserved or not address.is_private:
        raise Refused("--fan must be a fan on the home network: a private IPv4 address")
    if not separator:
        return str(address), DEFAULT_PORT
    if not re.fullmatch(r"[0-9]{1,5}", port) or not 1 <= int(port) <= 65535:
        raise Refused("--fan has a port that is not 1 to 65535")
    return str(address), int(port)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="mf_probe.py",
        description="Read a Modern Forms fan, run the write checks K11, K12, K13 and K15 of docs/v1-design.md "
        "section 11 on it, or turn a raw answer into a fixture.",
        epilog=__doc__.split("\n\n", 1)[1],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", metavar="command", required=True)

    def fan_options(p):
        p.add_argument("--fan", required=True, metavar="ADDR", help="the fan's IPv4 address, e.g. 10.0.2.151")
        p.add_argument("--raw-dir", metavar="DIR", help="also save every raw answer here; must lie under build/")
        p.add_argument("--allow-loopback", action="store_true", help="let a 127.x address through (the unit tests)")

    p = sub.add_parser("read", help="read the state (or --static: the device information); writes nothing")
    fan_options(p)
    p.add_argument("--static", action="store_true", help="queryStaticShadowData instead of queryDynamicShadowData")
    p.add_argument("--count", type=int, default=1, help="reads, 1 to %d (default 1)" % READ_MAX_COUNT)
    p.add_argument("--interval", type=float, help="seconds from one read's start to the next (default 3, min 0.5)")
    p = sub.add_parser("check", help="a write check: K11, K12, K13 or K15")
    p.add_argument("check", choices=sorted(CHECKS), help="the check of docs/v1-design.md section 11")
    fan_options(p)
    p.add_argument("--expect-id", metavar="LAST4", help="the last four hex digits of the fan's client id")
    p.add_argument("--yes-owner-told", action="store_true", help="the owner was told what the fan will do")
    p = sub.add_parser("fixture", help="a raw answer as a fixture with the placeholders")
    p.add_argument("--from", dest="source", required=True, metavar="RAWFILE", help="a raw answer (--raw-dir)")
    p.add_argument("--out", required=True, metavar="PATH", help="the fixture to write, e.g. tests/fixtures/NAME.json")
    p.add_argument("--force", action="store_true", help="replace --out if it exists")
    args = parser.parse_args(argv)
    if args.command == "read":
        if not 1 <= args.count <= READ_MAX_COUNT:
            parser.error("--count must be 1 to %d" % READ_MAX_COUNT)
        if args.interval is None:
            args.interval = READ_DEFAULT_INTERVAL_S
        elif args.count == 1:
            parser.error("--interval goes with --count")
        if not READ_MIN_INTERVAL_S <= args.interval <= READ_MAX_SPAN_S:
            parser.error("--interval must be %g to %g s" % (READ_MIN_INTERVAL_S, READ_MAX_SPAN_S))
        if (args.count - 1) * args.interval > READ_MAX_SPAN_S:
            parser.error("--count and --interval span more than %g s: never hammer the fan" % READ_MAX_SPAN_S)
    return args


def main(argv=None, sleep=time.sleep, clock=time.monotonic):
    args = parse_args(argv)
    try:
        if args.command == "fixture":
            return make_fixture(args.source, args.out, args.force)
        if args.command == "check":
            if not args.yes_owner_told:
                raise Refused(
                    "%s writes to the fan: tell the owner what it will do (docs/fan-probe.md), then add "
                    "--yes-owner-told" % args.check
                )
            if not args.expect_id or not re.fullmatch(r"[0-9A-Fa-f]{4}", args.expect_id):
                raise Refused("--expect-id wants the last four hex digits of the fan's client id (Fan ID)")
        host, port = parse_fan(args.fan, args.allow_loopback)
        raw = RawWriter(args.raw_dir) if args.raw_dir else None
        with probe_lock():
            fan = Fan(host, port, sleep=sleep, clock=clock, raw=raw)
            if args.command == "read":
                query = INFO_QUERY if args.static else STATE_QUERY
                return run_read(fan, query, args.count, args.interval, sleep, clock)
            return run_check(args.check, fan, args.expect_id, sleep, clock)
    except Refused as err:
        say("mf_probe: refused: %s" % err)
        return EXIT_REFUSED
    except (ProbeError, OSError) as err:
        say("mf_probe: error: %s" % err)
        return EXIT_ERROR
    except KeyboardInterrupt:
        say("mf_probe: interrupted")
        return EXIT_INTERRUPTED


if __name__ == "__main__":
    sys.exit(main())
