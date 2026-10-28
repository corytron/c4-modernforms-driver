"""Unit tests for tools/mf_probe.py, against a fake fan on 127.0.0.1: never a real fan or a LAN device.

The fake answers POST /mf as the house fan does (M0's keys in M0's order, docs/v1-design.md section
10.1), applies the five writes the tool sends, records every request, and counts the requests in
flight. Time is fake (Clock): the checks' pauses return at once and land in the same timeline as the
requests, so the order of pauses and requests can be checked.

Run: python3 -B -m unittest tools/tests/test_mf_probe.py
"""

import contextlib
import fcntl
import importlib.util
import io
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import mf_probe  # noqa: E402

# An invented fan's private data. The vectors are assembled at run time so that the repository's own
# scan (gitleaks, .gitleaks.toml) does not see them as literals; python3 -B keeps them out of
# __pycache__ as well.
REAL_MAC = "a4:cf:12" + ":34:56:78"
REAL_CLIENT_ID = "MF_A4CF12" + "345678"
OTHER_CLIENT_ID = "MF_A4CF12" + "349999"
REAL_WAC_ID = "WAC_A4CF12" + "345678"
REAL_EMAIL = "someone" + "@" + "isp-mail.net"
REAL_IDENTITY = "us-east-1:" + "1234abcd-12ab-34cd-56ef-1234567890ab"
REAL_BSSID = "a4:cf:12" + ":9a:bc:de"
HOUSE_ADDRESS = "10.0." + "1.20"
HOUSE_SHORT_FORM = "10.0." + "276"
LAN_ADDRESS = "172.16" + ".5.4"
REAL_NAME = "Primary Bedroom Fan"
REAL_SSID = "Smith Family WiFi"
REAL_TZ = "EST5EDT,M3.2.0,M11.1.0"
REAL_SCHEDULE = "c2NoZWR1bGUgb2YgdGhlIGhvdXNl"
SECRETS = (REAL_MAC, REAL_CLIENT_ID, REAL_EMAIL, REAL_IDENTITY, REAL_BSSID, REAL_NAME, REAL_SSID, REAL_TZ)
EXPECT = "5678"  # the last four hex digits of REAL_CLIENT_ID

STATE_Q = '{"queryDynamicShadowData":1}'
INFO_Q = '{"queryStaticShadowData":1}'
LIGHT_ON = '{"lightOn":true}'
LIGHT_OFF = '{"lightOn":false}'
FAN_OFF = '{"fanOn":false}'


def speed(number):
    return '{"fanOn":true,"fanSpeed":%d}' % number


def level(number):
    return '{"lightBrightness":%d}' % number


def direction(name):
    return '{"fanDirection":"%s"}' % name


def m0_state(**overrides):
    """The house fan's dynamic shadow as M0 saw it (fan on at 1, forward, light off at 100)."""
    state = {
        "clientId": REAL_CLIENT_ID,
        "cloudPort": 8883,
        "lightOn": False,
        "fanOn": True,
        "lightBrightness": 100,
        "fanSpeed": 1,
        "fanDirection": "forward",
        "wind": False,
        "windSpeed": 1,
        "rfPairModeActive": False,
        "resetRfPairList": False,
        "factoryReset": False,
        "awayModeEnabled": False,
        "fanTimer": 0,
        "lightTimer": 0,
        "decommission": False,
        "schedule": "",
        "adaptiveLearning": False,
        "userData": "local_wifi",
        "timezone": REAL_TZ,
        "FrCodes": 0,
        "cdebug": 0,
        "feedbackToneMute": False,
    }
    state.update(overrides)
    return state


def m0_info(**overrides):
    """The house fan's static shadow as M0 saw it, with invented private values."""
    info = {
        "clientId": REAL_CLIENT_ID,
        "mac": REAL_MAC,
        "lightType": "F4IN-120V-R1-30",
        "fanType": "1811-5-54",
        "fanMotorType": "DC125X20",
        "brand": 1,
        "dateCode": "2021-12-02",
        "owner": REAL_EMAIL,
        "federatedIdentity": REAL_IDENTITY,
        "deviceName": REAL_NAME,
        "firmwareVersion": "02.00.0052",
        "esp-idf-version": "4.0.4",
        "mainMcuFirmwareVersion": "03.00.0000",
        "firmwareUrl": "",
        "wifiSignal": "-68",
        "SSID": REAL_SSID,
        "BSSID": REAL_BSSID,
        "isUvcFan": False,
        "built": "realHardware",
        "dimTableId": 416020,
        "elecFreq": 60,
    }
    info.update(overrides)
    return info


# docs/v1-design.md section 10.1's INFO, the placeholders in place.
FIXTURE_INFO = {
    "clientId": "MF_00005E005301",
    "mac": "00:00:5e:00:53:01",
    "lightType": "F4IN-120V-R1-30",
    "fanType": "1811-5-54",
    "fanMotorType": "DC125X20",
    "brand": 1,
    "dateCode": "2021-12-02",
    "owner": "owner@example.com",
    "federatedIdentity": "us-east-1:00000000-0000-0000-0000-000000000000",
    "deviceName": "Example Fan",
    "firmwareVersion": "02.00.0052",
    "esp-idf-version": "4.0.4",
    "mainMcuFirmwareVersion": "03.00.0000",
    "firmwareUrl": "",
    "wifiSignal": "-68",
    "SSID": "example-ssid",
    "BSSID": "00:00:5e:00:53:ff",
    "isUvcFan": False,
    "built": "realHardware",
    "dimTableId": 416020,
    "elecFreq": 60,
}

WRITE_KEYS = ("fanOn", "fanSpeed", "fanDirection", "lightOn", "lightBrightness")
DRIBBLE_S = 1.0


class FakeFan:
    """A Modern Forms fan on 127.0.0.1: POST /mf with the two queries and the five writes. plan maps a
    request's number (from 1) to what goes wrong with it: close (no answer), dribble (the headers at
    once, the body after DRIBBLE_S), 404, 500 or garbage; every request after dead_after is closed
    unanswered; every answer after foreign_after carries another fan's client id."""

    def __init__(self, timeline, state=None, info=None):
        self.state = m0_state() if state is None else state
        self.info = m0_info() if info is None else info
        self.initial = dict(self.state)
        self.timeline = timeline
        self.bodies = []
        self.requests = []  # (method, path, headers) per request
        self.lock = threading.Lock()
        self.in_flight = 0
        self.max_in_flight = 0
        self.plan = {}
        self.dead_after = None
        self.foreign_after = None
        self.level_turns_light_on = False
        self.ignore = set()  # write keys this fan does not take
        self.delay = 0.002
        fan = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_POST(self):
                with fan.lock:
                    fan.in_flight += 1
                    fan.max_in_flight = max(fan.max_in_flight, fan.in_flight)
                try:
                    fan.answer(self)
                finally:
                    with fan.lock:
                        fan.in_flight -= 1

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server.handle_error = lambda request, client_address: None
        self.thread = threading.Thread(target=self.server.serve_forever, args=(0.01,), daemon=True)
        self.thread.start()

    @property
    def address(self):
        return "127.0.0.1:%d" % self.server.server_address[1]

    @property
    def port(self):
        return self.server.server_address[1]

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def send(self, handler, status, payload, content_type="application/json"):
        handler.send_response(status)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(payload)))
        handler.end_headers()
        handler.wfile.write(payload)

    def answer(self, handler):
        length = int(handler.headers.get("Content-Length") or 0)
        text = handler.rfile.read(length).decode("utf-8")
        with self.lock:
            self.bodies.append(text)
            self.requests.append((handler.command, handler.path, dict(handler.headers)))
            self.timeline.append(("request", text))
            number = len(self.bodies)
        time.sleep(self.delay)
        mode = self.plan.get(number)
        if self.dead_after is not None and number > self.dead_after:
            mode = "close"
        if mode == "close":
            handler.close_connection = True
            return
        if mode == "404" or handler.path != "/mf":
            return self.send(handler, 404, b"Not Found", "text/plain")
        if mode == "500":
            return self.send(handler, 500, b"oops", "text/plain")
        if mode == "garbage":
            return self.send(handler, 200, b"<html>not json</html>", "text/html")
        body = json.loads(text)
        with self.lock:
            if "queryStaticShadowData" in body:
                answer = dict(self.info)
            else:
                for key, value in body.items():
                    if key in WRITE_KEYS and key not in self.ignore:
                        if key == "lightBrightness" and self.level_turns_light_on:
                            self.state["lightOn"] = True
                        self.state[key] = value
                answer = dict(self.state)
            if self.foreign_after is not None and number > self.foreign_after:
                answer["clientId"] = OTHER_CLIENT_ID
        payload = json.dumps(answer).encode("utf-8")
        if mode == "dribble":
            handler.send_response(200)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(payload)))
            handler.end_headers()
            time.sleep(DRIBBLE_S)
            with contextlib.suppress(OSError):
                handler.wfile.write(payload)
            return
        self.send(handler, 200, payload)


class Clock:
    """Fake time: sleep() returns at once, moves the clock and lands in the timeline. raise_at makes the
    sleep with that number (from 1) raise raise_with instead, as a Ctrl-C or a bug would."""

    def __init__(self, timeline):
        self.now = 1000.0
        self.timeline = timeline
        self.sleeps = []
        self.raise_at = None
        self.raise_with = KeyboardInterrupt

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(round(seconds, 3))
        self.timeline.append(("sleep", round(seconds, 3)))
        if self.raise_at == len(self.sleeps):
            raise self.raise_with()
        self.now += seconds


def load_gh_discussion():
    path = os.path.join(TOOLS, "gh-discussion.py")
    spec = importlib.util.spec_from_file_location("gh_discussion", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProbeCase(unittest.TestCase):
    """A fake fan, fake time, and mf_probe's ROOT (its build/ for the lock and raw answers) in a
    temporary folder; short timeouts, so a failure costs no real seconds."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.realpath(self.tmp.name)
        os.makedirs(os.path.join(self.root, "build"))
        for name, value in (("ROOT", self.root), ("CONNECT_TIMEOUT_S", 0.5), ("TOTAL_TIMEOUT_S", 0.5)):
            patcher = mock.patch.object(mf_probe, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.timeline = []
        self.clock = Clock(self.timeline)
        self.fan = FakeFan(self.timeline)
        self.addCleanup(self.fan.close)
        self.out = self.err = ""

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = mf_probe.main(list(argv), sleep=self.clock.sleep, clock=self.clock)
        self.out, self.err = out.getvalue(), err.getvalue()
        return code

    def run_check(self, name, *extra, expect=EXPECT):
        return self.run_main(
            "check",
            name,
            "--fan",
            self.fan.address,
            "--expect-id",
            expect,
            "--yes-owner-told",
            "--allow-loopback",
            *extra,
        )

    def report(self):
        return json.loads(self.out)

    def fan_back_as_found(self):
        self.assertEqual(
            {key: self.fan.state[key] for key in WRITE_KEYS}, {key: self.fan.initial[key] for key in WRITE_KEYS}
        )

    def new_fan(self, **state):
        """Replace the fake fan by one whose state has these overrides."""
        self.fan.close()
        self.fan = FakeFan(self.timeline, state=m0_state(**state))
        self.addCleanup(self.fan.close)

    @contextlib.contextmanager
    def quiet(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            yield err


# ---------------------------------------------------------------------------
# Masking
# ---------------------------------------------------------------------------


class MaskingTest(unittest.TestCase):
    def test_the_private_fields_of_the_device_information(self):
        masked = mf_probe.Scrubber(host="127.0.0.1").answer(m0_info())
        self.assertEqual(masked["clientId"], "<private>...5678")
        self.assertEqual(masked["mac"], "<private>...5678")
        for key in ("owner", "federatedIdentity", "deviceName", "SSID", "BSSID"):
            with self.subTest(key=key):
                self.assertEqual(masked[key], "<private>")
        for key in ("lightType", "fanType", "fanMotorType", "brand", "dateCode", "firmwareVersion", "dimTableId"):
            with self.subTest(key=key):
                self.assertEqual(masked[key], m0_info()[key])
        self.assertEqual(masked["firmwareUrl"], "")  # empty says "not set", which is not private
        self.assertEqual(list(masked), list(m0_info()))

    def test_the_private_fields_of_the_state(self):
        masked = mf_probe.Scrubber().answer(m0_state(schedule=REAL_SCHEDULE))
        self.assertEqual(masked["clientId"], "<private>...5678")
        self.assertEqual(masked["timezone"], "<private>")
        self.assertEqual(masked["schedule"], "<private>")
        self.assertEqual(mf_probe.Scrubber().answer(m0_state())["schedule"], "")
        for key in ("fanOn", "fanSpeed", "fanDirection", "lightOn", "lightBrightness", "userData", "cloudPort"):
            with self.subTest(key=key):
                self.assertEqual(masked[key], m0_state()[key])

    def test_location_certificates_and_other_ids(self):
        masked = mf_probe.Scrubber().answer(
            {
                "clientId": REAL_CLIENT_ID,
                "location": {"lat": 40.1, "lon": -75.2},
                "certificateId": "abc123def456",
                "cert": "-----BEGIN CERTIFICATE-----",
                "homeId": 7,
                "staMac": REAL_MAC.upper(),
                "productSku": "F-1811",
            }
        )
        self.assertEqual(masked["location"], "<private>")
        self.assertEqual(masked["certificateId"], "<private>")
        self.assertEqual(masked["cert"], "<private>")
        self.assertEqual(masked["homeId"], "<private>")
        self.assertEqual(masked["staMac"], "<private>...5678")
        self.assertEqual(masked["productSku"], "F-1811")

    def test_private_patterns_under_any_key(self):
        scrubber = mf_probe.Scrubber(host="127.0.0.1")
        masked = scrubber.answer(
            {
                "clientId": REAL_CLIENT_ID,
                "peer": "seen " + REAL_MAC,
                "router": "via " + LAN_ADDRESS,
                "house": "at " + HOUSE_ADDRESS,
                "short": "at " + HOUSE_SHORT_FORM,
                "account": REAL_EMAIL,
                "who": REAL_IDENTITY,
                "wac": REAL_WAC_ID,
                "other": OTHER_CLIENT_ID,
                "self": "me at 127.0.0.1:8080",
                "nested": [{"deep": REAL_MAC}],
                "placeholders": "10.0.2.151 00:00:5e:00:53:01 MF_00005E005301 owner@example.com",
            }
        )
        self.assertEqual(masked["peer"], "seen <private>...5678")
        self.assertEqual(masked["router"], "via <private>")
        self.assertEqual(masked["house"], "at <private>")
        self.assertEqual(masked["short"], "<private>")  # the house subnet's short form: the whole value
        self.assertEqual(masked["account"], "<private>")
        self.assertEqual(masked["who"], "<private>")
        self.assertEqual(masked["wac"], "<private>...5678")
        self.assertEqual(masked["other"], "<private>...9999")
        self.assertEqual(masked["self"], "me at <fan>")
        self.assertEqual(masked["nested"], [{"deep": "<private>...5678"}])
        self.assertEqual(masked["placeholders"], "10.0.2.151 00:00:5e:00:53:01 MF_00005E005301 owner@example.com")
        self.assertEqual(scrubber.leaks(json.dumps(masked)), [])

    def test_a_private_value_turning_up_under_another_key(self):
        masked = mf_probe.Scrubber().answer({"label": "the " + REAL_NAME, "deviceName": REAL_NAME})
        self.assertEqual(masked, {"label": "the <private>", "deviceName": "<private>"})

    def test_leaks_names_the_kind_never_the_data(self):
        scrubber = mf_probe.Scrubber(host="127.0.0.1")
        scrubber.answer(m0_info())
        found = scrubber.leaks('{"a": "%s", "b": "127.0.0.1", "c": "%s"}' % (REAL_MAC, REAL_NAME))
        self.assertIn("the fan's address", found)
        self.assertIn("a private value of the fan's answer", found)
        self.assertTrue(any(reason.startswith("a MAC address") for reason in found), found)
        for secret in (REAL_MAC, REAL_NAME, "127.0.0.1"):
            self.assertNotIn(secret, " ".join(found))

    def test_the_rules_are_deploys_and_gh_discussions_plus_wac_ids(self):
        # Imported, not copied: tools/deploy.py's rules, which test_deploy.py holds equal to gh-discussion's.
        self.assertIs(mf_probe.deploy, importlib.import_module("deploy"))
        self.assertEqual(mf_probe.deploy.__file__, os.path.join(TOOLS, "deploy.py"))
        gh_discussion = load_gh_discussion()
        for sample in (HOUSE_ADDRESS, LAN_ADDRESS, REAL_MAC, REAL_CLIENT_ID, REAL_EMAIL, REAL_IDENTITY):
            with self.subTest(sample=sample):
                self.assertEqual(
                    [reason.rpartition(" (")[0] for reason in mf_probe.private_findings(sample)],
                    [
                        reason.split(" holds ", 1)[1].rpartition(" (")[0]
                        for reason in gh_discussion.refusals(sample, "x")
                    ],
                )
        self.assertEqual(mf_probe.private_findings("id " + REAL_WAC_ID), ["a WAC client id of a real fan (line 1)"])
        self.assertEqual(mf_probe.private_findings("id WAC_00005E005301, fan 10.0.2.151"), [])


# ---------------------------------------------------------------------------
# Request bodies
# ---------------------------------------------------------------------------


class BodyTest(ProbeCase):
    def test_the_bodies_are_written_as_the_driver_writes_them(self):
        # docs/v1-design.md section 3.1: keys in order, no spaces, literal true/false.
        for body, text in (
            (mf_probe.STATE_QUERY, STATE_Q),
            (mf_probe.INFO_QUERY, INFO_Q),
            ({"fanOn": True, "fanSpeed": 3}, speed(3)),
            ({"fanOn": False}, FAN_OFF),
            ({"fanDirection": "reverse"}, direction("reverse")),
            ({"lightBrightness": 30}, level(30)),
            ({"lightOn": True}, LIGHT_ON),
            ({"lightOn": False}, LIGHT_OFF),
        ):
            with self.subTest(text=text):
                self.assertEqual(mf_probe.body_text(body), text)

    def test_the_destructive_keys_are_refused_before_anything_is_sent(self):
        fan = mf_probe.Fan("127.0.0.1", self.fan.port, sleep=self.clock.sleep, clock=self.clock)
        for name in ("factoryReset", "decommission", "resetRfPairList", "rfPairModeActive", "reboot"):
            for body in (
                {name: True},
                {name: 1},
                {"fanOn": False, name: True},
                {"lightOn": True, "nested": {name: True}},
                {name.lower(): True},
                {name.upper(): True},
                {"note": "please " + name},
                [name],
            ):
                with self.subTest(body=body):
                    with self.assertRaises(mf_probe.ForbiddenBody) as raised:
                        mf_probe.body_text(body)
                    self.assertIn(name, str(raised.exception))
                    with self.quiet(), self.assertRaises(mf_probe.ForbiddenBody):
                        fan.request(body, "forbidden")
        self.assertEqual(self.fan.bodies, [])
        self.assertEqual(self.clock.sleeps, [])

    def test_bodies_outside_the_allow_list_are_refused(self):
        fan = mf_probe.Fan("127.0.0.1", self.fan.port, sleep=self.clock.sleep, clock=self.clock)
        for body in (
            {"fanSpeed": 3},  # a speed alone: whether it starts an off fan is unknown (ECM check 7)
            {"fanOn": True},
            {"fanOn": True, "fanSpeed": 0},
            {"fanOn": True, "fanSpeed": 7},
            {"fanOn": True, "fanSpeed": True},
            {"fanOn": True, "fanSpeed": 3.0},
            {"fanSpeed": 3, "fanOn": True},
            {"fanOn": False, "fanSpeed": 3},
            {"lightOn": True, "lightBrightness": 30},  # the flash (docs/modernforms-api-research.md 2.3)
            {"lightBrightness": 0},
            {"lightBrightness": 101},
            {"lightOn": 1},
            {"fanDirection": "up"},
            {"fanDirection": "reverse", "fanOn": True},
            {"fanOn": True, "fanSpeed": 2, "lightOn": True},
            {"schedule": ""},
            {"firmwareUrl": ""},
            {"wind": True},
            {"awayModeEnabled": False},
            {"queryDynamicShadowData": True},
            {"queryDynamicShadowData": 1, "fanOn": False},
            {},
            [],
            "fanOn",
            {"fanOn": object()},
        ):
            with self.subTest(body=body):
                with self.assertRaises(mf_probe.ForbiddenBody):
                    mf_probe.body_text(body)
                with self.quiet(), self.assertRaises(mf_probe.ForbiddenBody):
                    fan.request(body, "outside the allow-list")
        self.assertEqual(self.fan.bodies, [])

    def test_every_check_sends_only_allowed_bodies(self):
        for name in ("K11", "K12", "K13", "K15"):
            with self.subTest(check=name):
                self.new_fan()
                self.assertEqual(self.run_check(name), 0, self.err)
                for text in self.fan.bodies:
                    self.assertTrue(mf_probe.allowed_shape(json.loads(text)), text)
                    for forbidden in mf_probe.FORBIDDEN_KEYS:
                        self.assertNotIn(forbidden.lower(), text.lower())


# ---------------------------------------------------------------------------
# The transport
# ---------------------------------------------------------------------------


class TransportTest(ProbeCase):
    def test_the_request_on_the_wire(self):
        answer = mf_probe.post("127.0.0.1", self.fan.port, STATE_Q)
        self.assertTrue(answer.ok, answer)
        self.assertEqual(answer.data, self.fan.state)
        self.assertEqual(answer.status, 200)
        method, path, headers = self.fan.requests[0]
        self.assertEqual((method, path), ("POST", "/mf"))
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(headers["Connection"], "close")
        self.assertEqual(self.fan.bodies, [STATE_Q])

    def test_answers_are_classified_as_the_driver_does(self):
        # docs/v1-design.md section 3.3.
        for mode, kind, status in (("close", "connect", None), ("404", "http", 404), ("500", "http", 500)):
            with self.subTest(mode=mode):
                self.fan.plan = {len(self.fan.bodies) + 1: mode}
                answer = mf_probe.post("127.0.0.1", self.fan.port, STATE_Q)
                self.assertEqual((answer.kind, answer.status), (kind, status))
        self.fan.plan = {len(self.fan.bodies) + 1: "garbage"}
        self.assertEqual(mf_probe.post("127.0.0.1", self.fan.port, STATE_Q).kind, "json")
        self.fan.info = {"fanOn": True}  # no clientId
        self.assertEqual(mf_probe.post("127.0.0.1", self.fan.port, INFO_Q).kind, "json")

    def test_the_total_deadline_holds_however_the_answer_trickles(self):
        self.fan.plan = {1: "dribble"}
        started = time.monotonic()
        with mock.patch.object(mf_probe, "TOTAL_TIMEOUT_S", 0.3):
            answer = mf_probe.post("127.0.0.1", self.fan.port, STATE_Q)
        self.assertEqual(answer.kind, "timeout")
        self.assertLess(time.monotonic() - started, DRIBBLE_S - 0.2)

    def test_connect_errors_and_timeouts(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.close()  # nothing listens there now
        self.assertEqual(mf_probe.post("127.0.0.1", port, STATE_Q).kind, "connect")
        with mock.patch.object(mf_probe.socket, "create_connection", side_effect=TimeoutError):
            answer = mf_probe.post("127.0.0.1", port, STATE_Q)
        self.assertEqual(answer.kind, "timeout")
        self.assertIn("no connection within 0.5 s", answer.error)


# ---------------------------------------------------------------------------
# One request in flight
# ---------------------------------------------------------------------------


class OneInFlightTest(ProbeCase):
    def test_the_gap_between_requests(self):
        fan = mf_probe.Fan("127.0.0.1", self.fan.port, sleep=self.clock.sleep, clock=self.clock)
        self.fan.plan = {3: "500"}
        with self.quiet():
            fan.request(mf_probe.STATE_QUERY, "first")  # nothing before the first
            fan.request(mf_probe.STATE_QUERY, "second")  # GAP_S after the first
            fan.request({"lightOn": True}, "a burst", gap=0)  # fails: no gap before it
            fan.request({"lightOn": True}, "after a failure", gap=0)  # RETRY_GAP_S, even in a burst
            fan.request({"lightOn": False}, "back to back", gap=0)
        self.assertEqual(self.clock.sleeps, [mf_probe.GAP_S, mf_probe.RETRY_GAP_S])
        self.assertEqual(self.fan.max_in_flight, 1)

    def test_a_second_request_while_one_is_in_flight_is_refused(self):
        fan = mf_probe.Fan("127.0.0.1", self.fan.port, sleep=self.clock.sleep, clock=self.clock)
        fan.in_flight = True
        with self.assertRaises(RuntimeError):
            fan.request(mf_probe.STATE_QUERY, "reentrant")
        self.assertEqual(self.fan.bodies, [])

    def test_bursts_go_back_to_back_but_never_overlap(self):
        self.fan.delay = 0.01  # a wider window for an overlap, were there one
        self.assertEqual(self.run_check("K13"), 0, self.err)
        self.assertEqual(self.fan.max_in_flight, 1)
        burst = [i for i, (kind, text) in enumerate(self.timeline) if kind == "request" and "fanSpeed" in text]
        burst += [i for i, (kind, text) in enumerate(self.timeline) if kind == "request" and "lightBrightness" in text]
        self.assertEqual(len(burst), 30)
        for first, second in ((burst[0], burst[9]), (burst[10], burst[29])):
            self.assertEqual(
                [kind for kind, _ in self.timeline[first : second + 1]], ["request"] * (second - first + 1)
            )

    def test_reads_keep_their_interval(self):
        code = self.run_main("read", "--fan", self.fan.address, "--allow-loopback", "--count", "4", "--interval", "0.5")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(self.fan.bodies, [STATE_Q] * 4)
        self.assertEqual(self.clock.sleeps, [0.5, 0.5, 0.5])
        self.assertEqual(self.fan.max_in_flight, 1)

    def test_one_probe_at_a_time(self):
        handle = os.open(os.path.join(self.root, "build", ".mf_probe.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, handle)
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(self.run_main("read", "--fan", self.fan.address, "--allow-loopback"), 2)
        self.assertIn("another mf_probe.py is talking to a fan", self.err)
        self.assertEqual(self.fan.bodies, [])


# ---------------------------------------------------------------------------
# read and its report
# ---------------------------------------------------------------------------


class ReadTest(ProbeCase):
    def test_the_report_can_go_to_github_as_it_is(self):
        self.assertEqual(self.run_main("read", "--fan", self.fan.address, "--allow-loopback", "--static"), 0)
        self.assertEqual(self.fan.bodies, [INFO_Q])
        report = self.report()
        self.assertEqual(report["fan"], "<fan>")
        self.assertEqual(report["query"], "info")
        entry = report["requests"][0]
        self.assertEqual(entry["result"], "ok")
        self.assertIsInstance(entry["ms"], int)
        self.assertEqual(entry["answer"]["clientId"], "<private>...5678")
        self.assertEqual(entry["answer"]["deviceName"], "<private>")
        self.assertEqual(report["summary"]["ids"], ["<private>...5678"])
        for text in (self.out, self.err):
            self.assertNotIn("127.0.0.1", text)
            self.assertNotIn(":%d" % self.fan.port, text)
            for secret in SECRETS:
                self.assertNotIn(secret, text)
            self.assertEqual(mf_probe.private_findings(text), [])
            self.assertEqual(load_gh_discussion().check_text(text, "2026-10-27 — fan read"), [])

    def test_the_state_and_its_latency(self):
        self.assertEqual(self.run_main("read", "--fan", self.fan.address, "--allow-loopback"), 0)
        report = self.report()
        self.assertEqual(report["query"], "state")
        self.assertEqual(report["requests"][0]["state"], "fan on/1 forward, light off/100")
        self.assertEqual(report["requests"][0]["answer"]["timezone"], "<private>")
        self.assertEqual(report["summary"]["answered"], 1)
        self.assertEqual(set(report["summary"]["ms"]), {"min", "median", "max"})

    def test_a_fan_that_stops_answering_is_left_alone(self):
        self.fan.dead_after = 1
        code = self.run_main("read", "--fan", self.fan.address, "--allow-loopback", "--count", "10", "--interval", "1")
        self.assertEqual(code, 1)
        self.assertEqual(len(self.fan.bodies), 3)  # one answered, two failed in a row, then nothing
        self.assertIn("switch it off at the wall", self.report()["attention"])

    def test_the_limits_never_hammer_the_fan(self):
        for argv in (
            ["--count", "0"],
            ["--count", "61"],
            ["--count", "2", "--interval", "0.4"],
            ["--count", "30", "--interval", "3"],  # 87 s
            ["--interval", "2"],  # an interval without --count
        ):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    mf_probe.parse_args(["read", "--fan", "10.0.2.151", *argv])
                self.assertEqual(raised.exception.code, 2)
        args = mf_probe.parse_args(["read", "--fan", "10.0.2.151", "--count", "7", "--interval", "0.5"])
        self.assertEqual((args.count, args.interval), (7, 0.5))
        self.assertEqual(mf_probe.parse_args(["read", "--fan", "10.0.2.151"]).interval, 3.0)


class AddressTest(unittest.TestCase):
    def test_a_private_ipv4_address_with_an_optional_port(self):
        self.assertEqual(mf_probe.parse_fan("10.0.2.151"), ("10.0.2.151", 80))
        self.assertEqual(mf_probe.parse_fan("192.0.2.7:8080"), ("192.0.2.7", 8080))
        self.assertEqual(mf_probe.parse_fan("127.0.0.1:5", allow_loopback=True), ("127.0.0.1", 5))

    def test_everything_else_is_refused(self):
        for text in (
            "127.0.0.1",  # loopback without --allow-loopback
            "fan.local",
            "::1",
            "1.2.3.4",  # not a home network
            "224.0.0.251",
            "0.0.0.0",
            "255.255.255.255",
            "010.000.002.151",
            "10.0.2.151:0",
            "10.0.2.151:65536",
            "10.0.2.151:http",
            "",
        ):
            with self.subTest(text=text), self.assertRaises(mf_probe.Refused):
                mf_probe.parse_fan(text)


# ---------------------------------------------------------------------------
# --raw-dir
# ---------------------------------------------------------------------------


class RawDirTest(ProbeCase):
    def read_into(self, directory):
        return self.run_main("read", "--fan", self.fan.address, "--allow-loopback", "--raw-dir", directory)

    def test_only_under_build(self):
        outside = os.path.join(self.root, "outside")
        os.makedirs(outside)
        os.symlink(outside, os.path.join(self.root, "build", "link"))
        for directory in (
            outside,
            os.path.join(self.root, "build", "..", "docs"),
            os.path.join(self.root, "buildx"),
            os.path.join(self.root, "build", "link", "raw"),
            self.root,
            os.path.join(tempfile.gettempdir(), "mf-raw"),
        ):
            with self.subTest(directory=directory):
                self.assertEqual(self.read_into(directory), 2)
                self.assertIn("--raw-dir must lie under build/", self.err)
        self.assertEqual(self.fan.bodies, [])  # refused before anything was sent
        self.assertEqual(os.listdir(outside), [])

    def test_the_raw_answer_as_it_came(self):
        directory = os.path.join(self.root, "build", "raw")
        self.assertEqual(self.read_into(directory), 0, self.err)
        names = os.listdir(directory)
        self.assertEqual(len(names), 1)
        path = os.path.join(directory, names[0])
        with open(path, "rb") as handle:
            self.assertEqual(json.loads(handle.read()), self.fan.state)  # private values and all
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(self.report()["requests"][0]["raw"], "build/raw/" + names[0])

    def test_nothing_is_saved_without_it(self):
        self.assertEqual(self.run_main("read", "--fan", self.fan.address, "--allow-loopback"), 0)
        self.assertEqual(os.listdir(os.path.join(self.root, "build")), [".mf_probe.lock"])
        self.assertNotIn("raw", self.report()["requests"][0])


# ---------------------------------------------------------------------------
# The checks: identity, each sequence, restore
# ---------------------------------------------------------------------------


class IdentityTest(ProbeCase):
    def test_refused_without_the_owner_told(self):
        code = self.run_main("check", "K11", "--fan", self.fan.address, "--expect-id", EXPECT, "--allow-loopback")
        self.assertEqual(code, 2)
        self.assertIn("--yes-owner-told", self.err)
        self.assertEqual(self.fan.bodies, [])
        self.assertEqual(self.out, "")

    def test_refused_without_a_well_formed_expect_id(self):
        for extra in ([], ["--expect-id", "567"], ["--expect-id", "56789"], ["--expect-id", "56g8"]):
            with self.subTest(extra=extra):
                argv = ["check", "K12", "--fan", self.fan.address, "--yes-owner-told", "--allow-loopback", *extra]
                self.assertEqual(self.run_main(*argv), 2)
                self.assertIn("--expect-id", self.err)
        self.assertEqual(self.fan.bodies, [])

    def test_another_fan_at_the_address_gets_nothing_written(self):
        self.assertEqual(self.run_check("K11", expect="5301"), 2)
        self.assertEqual(self.fan.bodies, [INFO_Q])
        self.assertIn("client id ending in 5678, not 5301: nothing was written", self.err)
        self.assertIn("nothing was written", self.report()["refused"])
        self.fan_back_as_found()

    def test_a_fan_answering_404_on_mf_is_not_written_to(self):
        self.fan.plan = {1: "404"}  # as a Gen 4 fan answers (docs/v1-design.md 3.6)
        self.assertEqual(self.run_check("K11"), 2)
        self.assertEqual(self.fan.bodies, [INFO_Q])
        self.assertIn("HTTP 404: not a Gen 1-3 fan", self.err)

    def test_the_expect_id_is_case_blind(self):
        self.fan.info["clientId"] = self.fan.state["clientId"] = "MF_A4CF12" + "34ABCD"
        self.assertEqual(self.run_check("K12", expect="abcd"), 0, self.err)

    def test_a_change_of_fan_between_the_two_reads(self):
        self.fan.foreign_after = 1
        self.assertEqual(self.run_check("K11"), 1)
        self.assertEqual(self.fan.bodies, [INFO_Q, STATE_Q])
        self.assertIn("another fan (<private>...9999) answered", self.report()["error"])

    def test_another_fan_answering_mid_check_stops_everything(self):
        self.fan.foreign_after = 2  # the direction write (request 3) is answered by another fan
        self.assertEqual(self.run_check("K11"), 1)
        self.assertEqual(self.fan.bodies, [INFO_Q, STATE_Q, direction("reverse")])
        report = self.report()
        self.assertIn("another fan", report["error"])
        self.assertFalse(report["restore"]["restored"])
        self.assertIn("nothing more is sent", report["restore"]["error"])


class SequenceTest(ProbeCase):
    def assert_sequence(self, name, expected, **state):
        self.new_fan(**state)
        self.assertEqual(self.run_check(name), 0, self.err)
        self.assertEqual(self.fan.bodies, expected)
        self.fan_back_as_found()
        report = self.report()
        self.assertTrue(report["restore"]["restored"], report["restore"])
        self.assertEqual(report["restore"]["after"], report["before"])
        self.assertEqual(len(report["requests"]), len(expected))
        self.assertNotIn("127.0.0.1", self.out)
        self.assertEqual(load_gh_discussion().check_text(self.out, "2026-10-27 — %s" % name), [])
        return report

    def test_k11_with_the_fan_running_forward(self):
        report = self.assert_sequence(
            "K11",
            [INFO_Q, STATE_Q, direction("reverse"), STATE_Q, STATE_Q, STATE_Q, direction("forward"), STATE_Q]
            + [STATE_Q, STATE_Q],  # the restore: a read, nothing to put back, the verify read
        )
        third = round(mf_probe.K11_READ_SPAN_S / 3, 3)
        self.assertEqual(self.clock.sleeps.count(third), 3)
        self.assertIn(mf_probe.K11_AFTER_S, self.clock.sleeps)
        self.assertEqual(report["findings"]["reads"], ["reverse"] * 3)
        self.assertEqual(report["findings"]["read_after"], "forward")
        self.assertTrue(report["verdict"].startswith("K11 passed"), report["verdict"])

    def test_k11_with_the_fan_off_in_reverse(self):
        report = self.assert_sequence(
            "K11",
            [INFO_Q, STATE_Q, speed(3), direction("forward"), STATE_Q, STATE_Q, STATE_Q, direction("reverse"), STATE_Q]
            + [STATE_Q, FAN_OFF, STATE_Q],
            fanOn=False,
            fanSpeed=3,
            fanDirection="reverse",
        )
        self.assertIn("the fan was off: it runs at speed 3", report["notes"][0])
        # It runs before the direction write ("with the fan running"), which follows the spin-up pause.
        self.assertEqual(self.timeline[self.timeline.index(("request", speed(3))) + 1], ("sleep", 3.0))

    def test_k12_with_the_light_off(self):
        report = self.assert_sequence(
            "K12",
            [INFO_Q, STATE_Q, level(30), STATE_Q, LIGHT_ON, STATE_Q, LIGHT_OFF, STATE_Q]
            + [STATE_Q, level(100), STATE_Q],
        )
        self.assertEqual(report["findings"]["after_level"], {"on": False, "level": 30})
        self.assertEqual(report["findings"]["after_on"], {"on": True, "level": 30})
        self.assertEqual(report["findings"]["after_off"], {"on": False, "level": 30})
        self.assertTrue(report["verdict"].startswith("K12 passed"), report["verdict"])

    def test_k12_with_a_read_that_fails(self):
        self.fan.plan = {4: "500"}  # the read after the level sent while off
        self.assertEqual(self.run_check("K12"), 0, self.err)
        report = self.report()
        self.assertEqual(report["findings"]["after_level"], "http")
        self.assertEqual(report["verdict"], "K12 incomplete: a read failed (see findings); run it again")
        self.assertTrue(report["restore"]["restored"])

    def test_k12_with_the_light_on_at_30(self):
        self.assert_sequence(
            "K12",
            [INFO_Q, STATE_Q, LIGHT_OFF, level(60), STATE_Q, LIGHT_ON, STATE_Q, LIGHT_OFF, STATE_Q]
            + [STATE_Q, level(30), LIGHT_ON, STATE_Q],  # the level first, on last: no flash at 60
            lightOn=True,
            lightBrightness=30,
        )

    def test_k12_on_a_fan_whose_level_switches_the_light_on(self):
        self.fan.level_turns_light_on = True
        self.assertEqual(self.run_check("K12"), 0, self.err)
        self.assertEqual(
            self.fan.bodies,
            [INFO_Q, STATE_Q, level(30), STATE_Q, LIGHT_ON, STATE_Q, LIGHT_OFF, STATE_Q]
            + [STATE_Q, level(100), LIGHT_OFF, STATE_Q],
        )
        self.fan_back_as_found()
        report = self.report()
        self.assertFalse(report["findings"]["level_while_off_keeps_the_light_off"])
        self.assertIn("level while off keeps the light off is false", report["verdict"])

    def test_k13_with_fan_and_light_on(self):
        levels = [level(n) for n in mf_probe.K13_LEVELS + (40,)]
        report = self.assert_sequence(
            "K13",
            [INFO_Q, STATE_Q]
            + [speed(n) for n in (1, 2, 3, 4, 5, 6, 5, 4, 3, 2)]
            + levels
            + [STATE_Q]
            # the bursts ended on the speed and the level the fan had: nothing to put back
            + [STATE_Q, STATE_Q],
            fanSpeed=2,
            lightOn=True,
            lightBrightness=40,
        )
        self.assertEqual(len(levels), 20)
        findings = report["findings"]
        self.assertEqual((findings["speed_burst"]["sent"], findings["speed_burst"]["answered"]), (10, 10))
        self.assertEqual((findings["level_burst"]["sent"], findings["level_burst"]["echo_matched"]), (20, 20))
        self.assertTrue(findings["final"]["matches"])
        self.assertIn("30 of 30 burst commands answered, 0 errors", report["verdict"])

    def test_k13_with_fan_and_light_off(self):
        self.assert_sequence(
            "K13",
            [INFO_Q, STATE_Q]
            + [speed(n) for n in (1, 2, 3, 4, 5, 6, 5, 4, 2, 3)]  # the walk's last value moved off 3
            + [LIGHT_ON]
            + [level(n) for n in mf_probe.K13_LEVELS + (100,)]
            + [STATE_Q, STATE_Q, FAN_OFF, LIGHT_OFF, STATE_Q],
            fanOn=False,
            fanSpeed=3,
        )

    def test_k15_with_the_light_on(self):
        report = self.assert_sequence(
            "K15",
            [INFO_Q, STATE_Q]
            + [level(n) for n in (1, 10, 19, 28, 37, 46, 55, 64, 73, 82, 91, 100)]
            + [level(n) for n in (100, 91, 82, 73, 64, 55, 46, 37, 28, 19, 10, 1)]
            + [STATE_Q, level(50), STATE_Q],
            lightOn=True,
            lightBrightness=50,
        )
        # 12 starts a quarter of a second apart, up and then down; no other pause inside a ramp.
        ramp = [i for i, (kind, text) in enumerate(self.timeline) if kind == "request" and "lightBrightness" in text]
        for first, last in ((ramp[0], ramp[11]), (ramp[12], ramp[23])):
            pauses = [entry for entry in self.timeline[first : last + 1] if entry[0] == "sleep"]
            self.assertEqual(pauses, [("sleep", mf_probe.K15_STEP_S)] * 11)
        self.assertEqual(report["findings"]["up"]["span_s"], 2.75)  # fake time: the first start to the last
        self.assertIn("dim or staircase", report["verdict"])

    def test_k15_with_the_light_off(self):
        self.assert_sequence(
            "K15",
            [INFO_Q, STATE_Q, level(1), LIGHT_ON]
            + [level(n) for n in mf_probe.K15_STEPS]
            + [level(n) for n in reversed(mf_probe.K15_STEPS)]
            + [STATE_Q, LIGHT_OFF, level(50), STATE_Q],  # off first, the level last: no flash at 50
            lightBrightness=50,
        )

    def test_light_checks_need_a_light_kit(self):
        self.fan.info["lightType"] = ""
        for name in ("K12", "K15"):
            with self.subTest(check=name):
                self.fan.bodies.clear()
                self.assertEqual(self.run_check(name), 2)
                self.assertEqual(self.fan.bodies, [INFO_Q, STATE_Q])
                self.assertIn("needs a light kit", self.err)
        self.fan.bodies.clear()
        self.assertEqual(self.run_check("K13"), 0, self.err)
        self.assertFalse(any("lightBrightness" in text or "lightOn" in text for text in self.fan.bodies))


class RestoreTest(ProbeCase):
    def test_restored_after_an_error(self):
        self.clock.raise_at = 4  # the second of K11's three pauses, the direction reversed
        self.clock.raise_with = RuntimeError
        self.assertEqual(self.run_check("K11"), 1)
        self.assertEqual(
            self.fan.bodies, [INFO_Q, STATE_Q, direction("reverse"), STATE_Q, STATE_Q, direction("forward"), STATE_Q]
        )
        self.fan_back_as_found()
        report = self.report()
        self.assertTrue(report["restore"]["restored"])
        self.assertIn("RuntimeError", report["error"])
        self.assertIn("Traceback", self.err)

    def test_restored_after_ctrl_c(self):
        self.new_fan(fanOn=False, lightBrightness=70)
        self.clock.raise_at = 2  # the gap before K13 turns the light on: the fan runs from the speed burst
        self.assertEqual(self.run_check("K13"), 130)
        self.assertEqual(
            self.fan.bodies,
            [INFO_Q, STATE_Q] + [speed(n) for n in (1, 2, 3, 4, 5, 6, 5, 4, 3, 1)] + [STATE_Q, FAN_OFF, STATE_Q],
        )
        self.fan_back_as_found()
        report = self.report()
        self.assertTrue(report["interrupted"])
        self.assertTrue(report["restore"]["restored"], report["restore"])

    def test_ctrl_c_during_the_restore_waits(self):
        self.new_fan(lightOn=True, lightBrightness=30)
        real_restore = mf_probe.Session._restore

        def interrupted_restore(session, before):
            os.kill(os.getpid(), mf_probe.signal.SIGINT)  # held until the restore is done
            return real_restore(session, before)

        with mock.patch.object(mf_probe.Session, "_restore", interrupted_restore):
            self.assertEqual(self.run_check("K12"), 130)
        self.fan_back_as_found()
        self.assertTrue(self.report()["restore"]["interrupted"])
        self.assertIn("put back first", self.err)

    def test_a_fan_that_stops_answering(self):
        self.fan.dead_after = 3  # the direction write is answered, then nothing
        self.assertEqual(self.run_check("K11"), 1)
        # Two reads fail in a row: stop; the restore tries one read, which fails: nothing more.
        self.assertEqual(self.fan.bodies, [INFO_Q, STATE_Q, direction("reverse"), STATE_Q, STATE_Q, STATE_Q])
        report = self.report()
        self.assertIn("switch it off at the wall for 10 s", report["attention"])
        self.assertIn("It was: fan on/1 forward, light off/100", report["attention"])
        self.assertTrue(report["restore"]["stuck"])
        self.assertTrue(report["verdict"].startswith("K11 failed"))
        self.assertIn("switch it off at the wall", self.err)

    def test_one_failed_request_is_not_the_end(self):
        self.fan.plan = {4: "500"}  # K11's first read
        self.assertEqual(self.run_check("K11"), 0, self.err)
        report = self.report()
        self.assertEqual(report["findings"]["missed"], 1)
        self.assertTrue(report["verdict"].startswith("K11 failed: the fan missed 1 of 6"), report["verdict"])
        self.assertTrue(report["restore"]["restored"])

    def test_a_field_the_fan_does_not_take_does_not_stop_the_restore(self):
        self.fan.ignore = {"fanDirection"}
        self.fan.state.update(fanDirection="reverse", lightOn=True, lightBrightness=40)
        found = mf_probe.State(True, 1, "forward", False, 100)
        fan = mf_probe.Fan("127.0.0.1", self.fan.port, sleep=self.clock.sleep, clock=self.clock)
        with self.quiet():
            result = mf_probe.Session(fan, self.clock.sleep, self.clock).restore(found)
        # The direction twice, then the light all the same; the verify read says what is left.
        self.assertEqual(
            self.fan.bodies, [STATE_Q, direction("forward"), direction("forward"), LIGHT_OFF, level(100), STATE_Q]
        )
        self.assertEqual(result["not_restored"], ['direction is "reverse", was "forward"'])
        self.assertFalse(result["restored"])

    def test_a_request_cut_by_ctrl_c_is_logged(self):
        real_post = mf_probe.post
        calls = []

        def post(host, port, text):
            calls.append(text)
            if len(calls) == 3:  # the direction write: the fan may have taken it
                real_post(host, port, text)
                raise KeyboardInterrupt
            return real_post(host, port, text)

        with mock.patch.object(mf_probe, "post", post):
            self.assertEqual(self.run_check("K11"), 130)
        entries = self.report()["requests"]
        self.assertEqual((entries[2]["body"], entries[2]["result"]), ({"fanDirection": "reverse"}, "interrupted"))
        self.assertEqual(
            self.fan.bodies, [INFO_Q, STATE_Q, direction("reverse"), STATE_Q, direction("forward"), STATE_Q]
        )
        self.fan_back_as_found()

    def test_restore_body_order(self):
        state = mf_probe.State
        found = state(False, 3, "forward", False, 100)
        steps = []
        current = state(True, 5, "reverse", True, 40)
        for _ in range(8):
            body = mf_probe.restore_body(current, found)
            if body is None:
                break
            steps.append(body)
            values = {
                "fan_on": body.get("fanOn", current.fan_on),
                "speed": body.get("fanSpeed", current.speed),
                "direction": body.get("fanDirection", current.direction),
                "light_on": body.get("lightOn", current.light_on),
                "level": body.get("lightBrightness", current.level),
            }
            current = state(**values)
        self.assertEqual(
            steps,
            [
                {"fanDirection": "forward"},  # while the fan still runs
                {"fanOn": True, "fanSpeed": 3},  # its speed, then off
                {"fanOn": False},
                {"lightOn": False},  # off first, then the level: no flash
                {"lightBrightness": 100},
            ],
        )
        self.assertEqual(current, found)
        # A fan found off is never started to correct the speed it keeps; "off, speed 0" has none.
        self.assertIsNone(mf_probe.restore_body(state(False, 2, "forward", False, 100), found))
        self.assertEqual(mf_probe.differences(state(False, 2, "forward", False, 100), found), ["speed is 2, was 3"])
        self.assertEqual(
            mf_probe.differences(state(False, 1, "forward", False, 100), state(False, 0, "forward", False, 100)), []
        )


# ---------------------------------------------------------------------------
# fixture
# ---------------------------------------------------------------------------


class FixtureTest(ProbeCase):
    def write_raw(self, data, name="raw.json"):
        path = os.path.join(self.root, "build", name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(data if isinstance(data, str) else json.dumps(data))
        return path

    def fixture(self, data, *extra, name="out.json"):
        out = os.path.join(self.root, "tests", "fixtures", name)
        code = self.run_main("fixture", "--from", self.write_raw(data), "--out", out, *extra)
        return code, out

    def test_the_device_information_with_the_placeholders(self):
        code, out = self.fixture(m0_info())
        self.assertEqual(code, 0, self.err)
        with open(out, encoding="utf-8") as handle:
            text = handle.read()
        self.assertEqual(json.loads(text), FIXTURE_INFO)
        self.assertEqual(list(json.loads(text)), list(FIXTURE_INFO))  # the fan's key order
        self.assertEqual(mf_probe.private_findings(text), [])
        for secret in SECRETS:
            self.assertNotIn(secret, text)
        self.assertNotIn("review before committing", self.err)

    def test_the_state_with_the_placeholders(self):
        code, out = self.fixture(m0_state(schedule=REAL_SCHEDULE))
        self.assertEqual(code, 0, self.err)
        with open(out, encoding="utf-8") as handle:
            fixture = json.load(handle)
        self.assertEqual(fixture["clientId"], "MF_00005E005301")
        self.assertEqual(fixture["timezone"], "UTC0")
        self.assertEqual(fixture["schedule"], "<private>")  # a schedule is set, its content is not shown
        self.assertEqual({key: fixture[key] for key in WRITE_KEYS}, {key: m0_state()[key] for key in WRITE_KEYS})

    def test_the_shapes_of_mac_and_client_id_are_kept(self):
        code, out = self.fixture(
            {
                "clientId": REAL_WAC_ID,
                "mac": REAL_MAC.replace(":", "").upper(),
                "staMac": REAL_MAC.replace(":", "-").upper(),
                "BSSID": REAL_BSSID.upper(),
                "peer": "seen at " + HOUSE_ADDRESS + " by " + REAL_EMAIL,
            }
        )
        self.assertEqual(code, 0, self.err)
        with open(out, encoding="utf-8") as handle:
            fixture = json.load(handle)
        self.assertEqual(
            fixture,
            {
                "clientId": "WAC_00005E005301",
                "mac": "00005E005301",
                "staMac": "00-00-5E-00-53-01",
                "BSSID": "00:00:5E:00:53:FF",
                "peer": "seen at 10.0.2.151 by owner@example.com",
            },
        )
        self.assertIn("review before committing", self.err)  # staMac and peer are new keys
        self.assertIn("peer", self.err)

    def test_refused_when_a_private_pattern_survives(self):
        for data in (
            {"clientId": "MF_00005E005301", "note": "at " + HOUSE_SHORT_FORM},  # no placeholder for this form
            {"clientId": "MF_00005E005301", "peers": {REAL_MAC: 1}},  # private data in a key name
        ):
            with self.subTest(data=data):
                code, out = self.fixture(data)
                self.assertEqual(code, 2)
                self.assertFalse(os.path.exists(out))
                self.assertIn("refused", self.err)
                for secret in (REAL_MAC, HOUSE_SHORT_FORM):
                    self.assertNotIn(secret, self.err)

    def test_the_output_rules(self):
        code, _ = self.fixture(m0_info(), name="out.txt")
        self.assertEqual(code, 2)
        self.assertIn(".json", self.err)
        code, out = self.fixture(m0_info())
        self.assertEqual(code, 0)
        code, _ = self.fixture(m0_state())
        self.assertEqual(code, 2)
        self.assertIn("--force", self.err)
        code, _ = self.fixture(m0_state(), "--force")
        self.assertEqual(code, 0)
        with open(out, encoding="utf-8") as handle:
            self.assertIn("timezone", json.load(handle))
        self.assertEqual(self.fixture("not json", "--force")[0], 1)
        self.assertEqual(self.fixture([1, 2], "--force")[0], 1)
        self.assertEqual(self.fan.bodies, [])  # no fan involved


if __name__ == "__main__":
    unittest.main()
