"""Unit tests for tools/devctl.py without a server: `wait` (when a queued command counts as done, and
what a wait that times out says) and the rows of `status`.

devctl.call answers from a scripted dev server whose driver polls it, and the clock is a fake one,
so a minute of waiting takes no time. tools/tests/test_devserver.py runs devctl against a live
server.

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import argparse
import contextlib
import io
import os
import sys
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import devctl  # noqa: E402

EPOCH = 1_761_350_400.0  # the server's clock when a test begins (unix seconds)
STOP = {"id": 12, "type": "set_property", "name": "Dev Server", "value": ""}
DEBUG = {"id": 14, "type": "set_property", "name": "Debug Mode", "value": "Off"}


class Clock:
    """time.monotonic, time.sleep and time.time for devctl; only sleep moves it."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def time(self):
        return EPOCH + self.now


class Server:
    """The dev server's /status while a driver's loop polls it every POLL_S seconds.

    The loop polls at first_poll, first_poll + 3, ... up to polls_until (None: for ever), and
    last_contact (seconds on the test clock, None: never) is its latest request before the test.
    reports_at is when it reports the command done (None: never); queued says whether the command
    is in the queue at all."""

    def __init__(
        self, clock, command, last_contact=-2.0, first_poll=1.0, polls_until=None, reports_at=None, queued=True
    ):
        self.clock, self.command = clock, command
        self.last_contact, self.first_poll, self.polls_until = last_contact, first_poll, polls_until
        self.reports_at, self.queued = reports_at, queued

    def last_seen(self, now):
        seen = self.last_contact
        poll = self.first_poll
        while poll <= now and (self.polls_until is None or poll <= self.polls_until):
            seen = poll
            poll += devctl.POLL_S
        return None if seen is None else EPOCH + seen

    def status(self, args, method, path, body=None):
        if (method, path) != ("GET", "/status"):
            raise AssertionError("wait asked for %s %s" % (method, path))
        now = self.clock.now
        done = self.reports_at is not None and now >= self.reports_at
        pending = [] if done or not self.queued else [dict(self.command)]
        return {
            "last_seen": self.last_seen(now),
            "server_time": EPOCH + now,
            "pending_commands": pending,
            "done_commands": [self.command["id"]] if done else [],
            "last_done_id": self.command["id"] if done else None,
            "properties": {"Debug Mode": "Off", "Driver Version": "12"},
        }


class WaitTest(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()

    def wait(self, server, timeout=60):
        args = argparse.Namespace(id=server.command["id"], timeout=timeout, server="http://192.0.2.7:8081", token="t")
        out, err = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(devctl, "call", server.status),
            mock.patch.object(devctl, "time", self.clock),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            code = devctl.cmd_wait(args)
        return code, out.getvalue(), err.getvalue()

    def test_a_reported_command_ends_the_wait_with_the_properties(self):
        code, out, err = self.wait(Server(self.clock, DEBUG, reports_at=4.0))
        self.assertEqual(devctl.EXIT_OK, code)
        self.assertEqual("properties:\n  Debug Mode     = Off\n  Driver Version = 12\n", out)
        self.assertEqual("", err)
        self.assertEqual(4.0, self.clock.now)

    def test_a_dev_server_change_is_done_when_reported_like_any_other(self):
        # The loop reports the command before it stops (or moves), so the wait ends as for any other.
        code, out, err = self.wait(Server(self.clock, STOP, polls_until=1.0, reports_at=1.0))
        self.assertEqual(devctl.EXIT_OK, code)
        self.assertIn("Debug Mode", out)
        self.assertEqual("", err)

    def test_a_command_still_pending_times_out(self):
        code, out, err = self.wait(Server(self.clock, DEBUG))
        self.assertEqual(devctl.EXIT_TIMEOUT, code)
        self.assertEqual("", out)
        self.assertEqual("timed out after 60s waiting for command 14 (still pending)\n", err)
        self.assertEqual(60.0, self.clock.now)

    def test_a_command_never_queued_says_so(self):
        code, _, err = self.wait(Server(self.clock, DEBUG, queued=False), timeout=5)
        self.assertEqual(devctl.EXIT_TIMEOUT, code)
        self.assertIn("(not pending and not done; was it ever queued?)", err)

    def test_a_silent_loop_is_named_when_the_wait_times_out(self):
        code, _, err = self.wait(Server(self.clock, DEBUG, last_contact=-30.0, polls_until=-1.0))
        self.assertEqual(devctl.EXIT_TIMEOUT, code)
        self.assertIn("still pending; no driver has been in touch for 90s: does a device's Dev Server name this", err)

    def test_a_loop_never_seen_is_named_when_the_wait_times_out(self):
        code, _, err = self.wait(Server(self.clock, DEBUG, last_contact=None, first_poll=1e9), timeout=30)
        self.assertEqual(devctl.EXIT_TIMEOUT, code)
        self.assertIn("no driver has been in touch since the server started", err)

    def test_a_pending_dev_server_change_says_what_a_lost_report_means(self):
        code, _, err = self.wait(Server(self.clock, STOP, polls_until=1.0))
        self.assertEqual(devctl.EXIT_TIMEOUT, code)
        self.assertIn("still pending; no driver has been in touch for 59s", err)
        self.assertIn("a lost report leaves it queued here, where a loop that starts fresh runs it again", err)
        self.clock = Clock()
        code, _, err = self.wait(Server(self.clock, DEBUG, polls_until=1.0))
        self.assertEqual(devctl.EXIT_TIMEOUT, code)
        self.assertNotIn("lost report", err, "only for a Dev Server change")

    def test_which_commands_change_dev_server(self):
        for name in ("Dev Server", "Dev  Server", "Dev\tServer"):
            with self.subTest(name=name):
                self.assertTrue(devctl.changes_dev_server(dict(STOP, name=name)))
        for command in (
            dict(STOP, name="Dev Servers"),
            dict(STOP, name="dev server"),
            DEBUG,
            {"id": 1, "type": "execute", "command": "Dev Server"},
            {"id": 2, "type": "reload"},
            None,
        ):
            with self.subTest(command=command):
                self.assertFalse(devctl.changes_dev_server(command))


class StatusRowsTest(unittest.TestCase):
    """The rows `status` prints for a /status reply."""

    def status(self, st):
        args = argparse.Namespace(server="http://192.0.2.7:8081", token="t")
        out = io.StringIO()
        with mock.patch.object(devctl, "call", lambda *_: st), contextlib.redirect_stdout(out):
            self.assertEqual(devctl.EXIT_OK, devctl.cmd_status(args))
        return out.getvalue()

    def base(self, **extra):
        st = {
            "trees": {
                "modernforms_fan": {
                    "local_version": "a" * 40,
                    "live_version": "a" * 40,
                    "pinned": None,
                    "running_version": "a" * 40,
                    "forwarded_version": None,
                }
            },
            "key_fingerprint": "65e6f64bca3f7c66",
            "driver_key_fingerprint": "65e6f64bca3f7c66",
            "driver_reported_key": True,
            "device_id": 15,
            "devices": {"15": {"tree": "modernforms_fan", "last_seen": EPOCH - 2}},
            "last_seen": EPOCH - 2,
            "server_time": EPOCH,
            "last_event": "heartbeat",
            "last_error": None,
            "pending_commands": [],
            "properties": {"Debug Mode": "Off"},
        }
        st.update(extra)
        return st

    def test_a_running_tree_the_key_and_the_device(self):
        self.assertEqual(
            "tree modernforms_fan\n"
            "  running              aaaaaaaaaaaa  (matches local)\n"
            "  local                aaaaaaaaaaaa\n"
            "dev_key                matches the server's (fingerprint 65e6f64bca3f7c66)\n"
            "device                 15 (modernforms_fan)\n"
            "last_seen              2s ago\n"
            "last_event             heartbeat\n"
            "pending                0 command(s)\n"
            "properties:\n"
            "  Debug Mode = Off\n",
            self.status(self.base()),
        )

    def test_a_pinned_tree_a_forwarded_one_and_the_pending_commands(self):
        st = self.base(
            pending_commands=[
                {"id": 3, "type": "execute", "command": "Fan Off", "params": {"B": "2", "A": "1"}},
                {"id": 4, "type": "set_property", "name": "Debug Mode", "value": "On"},
                {"id": 5, "type": "reload"},
            ],
            last_error="boom",
        )
        st["trees"]["modernforms_fan"].update(pinned="a" * 40, live_version="b" * 40, running_version="c" * 40)
        st["trees"]["mf_light"] = {
            "local_version": "d" * 40,
            "live_version": "d" * 40,
            "pinned": None,
            "running_version": None,
            "forwarded_version": "d" * 40,
        }
        out = self.status(st)
        self.assertIn(
            "tree mf_light\n"
            "  forwarded            dddddddddddd  (matches local)\n"
            "  local                dddddddddddd\n",
            out,
        )
        self.assertIn("  running              cccccccccccc  (DIFFERS from local; a reload is due)\n", out)
        self.assertIn("  pinned               aaaaaaaaaaaa  (live tree: bbbbbbbbbbbb)\n", out)
        self.assertIn("last_error             boom\n", out)
        self.assertIn(
            "pending                3 command(s)\n"
            "  #3 execute 'Fan Off' A=1 B=2\n"
            "  #4 set 'Debug Mode' = 'On'\n"
            "  #5 reload\n",
            out,
        )
        self.assertLess(out.index("tree mf_light"), out.index("tree modernforms_fan"), "trees in name order")

    def test_two_polling_devices_are_called_out(self):
        st = self.base()
        st["devices"]["16"] = {"tree": "modernforms_fan", "last_seen": EPOCH - 1}
        out = self.status(st)
        self.assertIn(
            "device                 16 (modernforms_fan), 15 (modernforms_fan): MORE THAN ONE device polls this "
            "server; each runs every queued command (empty Dev Server on all but one)\n",
            out,
        )

    def test_a_device_gone_quiet_says_when_it_last_reported(self):
        st = self.base(last_seen=EPOCH - 300)
        st["devices"]["15"]["last_seen"] = EPOCH - 300
        st["devices"]["16"] = {"tree": "modernforms_fan", "last_seen": EPOCH - 400}
        out = self.status(st)
        self.assertIn("device                 15 (modernforms_fan), last report 300s ago\n", out)
        self.assertIn("last_seen              300s ago\n", out)

    def test_nothing_reported_yet(self):
        st = self.base(
            device_id=None,
            devices={},
            last_seen=None,
            last_event=None,
            properties={},
            driver_reported_key=False,
            driver_key_fingerprint=None,
        )
        st["trees"]["modernforms_fan"]["running_version"] = None
        out = self.status(st)
        self.assertIn("  running              -  (no device has reported this tree yet)\n", out)
        self.assertIn("dev_key                fingerprint 65e6f64bca3f7c66; driver has not reported yet\n", out)
        self.assertIn("device                 none has reported yet\n", out)
        self.assertIn("last_seen              never\n", out)
        self.assertIn("last_event             -\n", out)
        self.assertIn("properties             (none reported)\n", out)


if __name__ == "__main__":
    unittest.main()
