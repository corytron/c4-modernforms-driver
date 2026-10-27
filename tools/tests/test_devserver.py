"""Unit tests for tools/devserver.py and tools/devctl.py: the dev key, the signed answers, the admin
token, the address to listen on, the served trees and what the server makes of the reports
(docs/dev-loop.md). The server runs on 127.0.0.1, port 0, against a scratch tree; nothing else is
contacted.

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import contextlib
import hashlib
import hmac
import io
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import devctl  # noqa: E402
import devserver  # noqa: E402

TEST_KEY = ("0123456789abcdef" * 4).encode("ascii")
OTHER_KEY = ("fedcba9876543210" * 4).encode("ascii")
# The values tests/spec/devloop_spec.lua pins for the Lua side: both
# implementations must agree on them.
TEST_FINGERPRINT = "65e6f64bca3f7c66"
OTHER_FINGERPRINT = "1902c408de6160f9"
SHARED_PAYLOAD = b'{"files":{"driver.lua":"return 1"},"tree":"modernforms_fan","version":"v1"}'
SHARED_BUNDLE_MAC = "2875a8b6811c6a3d87faeee51472f3778ac89442057e0ee38f69d1a27828f625"
DOMAIN = b"c4-mf-devloop/1\n"
# The admin token derived as docs/dev-loop.md documents it (the "admin-token"
# MAC of nothing), independently of devserver.admin_token.
ADMIN_TOKEN = hmac.new(TEST_KEY, DOMAIN + b"admin-token\n", hashlib.sha256).hexdigest()
NONCE = "0123456789abcdef0123456789abcdef"
OWN = "modernforms_fan"


def check(key, label, body):
    """Split a signed answer and verify it as the controller does. Returns the payload."""
    mac, sep, payload = body.partition(b"\n")
    if not sep or len(mac) != 64:
        raise AssertionError("not an envelope: %r" % body[:80])
    expected = hmac.new(key, DOMAIN + label.encode() + b"\n" + payload, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(mac.decode("ascii"), expected):
        raise AssertionError("signature mismatch")
    return payload


def write_key(path, key=TEST_KEY, mode=0o600):
    with open(path, "wb") as f:
        f.write(key + b"\n")
    os.chmod(path, mode)


def make_root(root, second_tree=False):
    """A scratch repository: the fan driver's tree, src/common, files that must never be served (a
    devkey.lua in either place, a hidden file, the manual) and a directory that is no driver; with
    `second_tree`, a second driver, mf_light."""
    files = {
        "src/modernforms_fan/driver.lua": "-- fan ‚\n",
        "src/modernforms_fan/driver.xml": "<devicedata/>\n",
        "src/modernforms_fan/fan/http.lua": "return {}\n",
        "src/modernforms_fan/fan/devkey.lua": "return 'nested key file'\n",
        "src/modernforms_fan/.scratch.lua": "return 'hidden'\n",
        "src/modernforms_fan/www/documentation.html": "<p>manual</p>\n",
        "src/common/log.lua": "return {}\n",
        "src/common/devkey.lua": "return '%s'\n" % OTHER_KEY.decode(),
        "src/notes/readme.lua": "-- no driver.xml: no tree\n",
    }
    if second_tree:
        files["src/mf_light/driver.lua"] = "-- light\n"
        files["src/mf_light/driver.xml"] = "<devicedata/>\n"
    for rel, text in files.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)


class SigningTest(unittest.TestCase):
    def test_agrees_with_the_lua_side_on_the_shared_vectors(self):
        self.assertEqual(SHARED_BUNDLE_MAC, devserver.mac(TEST_KEY, "bundle", SHARED_PAYLOAD))
        self.assertEqual(TEST_FINGERPRINT, devserver.fingerprint(TEST_KEY))
        self.assertEqual(OTHER_FINGERPRINT, devserver.fingerprint(OTHER_KEY))
        self.assertEqual(ADMIN_TOKEN, devserver.admin_token(TEST_KEY))

    def test_the_domain_is_this_projects_own(self):
        self.assertEqual(DOMAIN, devserver.DOMAIN)
        hue = hmac.new(TEST_KEY, b"c4-hue-devloop/1\nbundle\n" + SHARED_PAYLOAD, hashlib.sha256).hexdigest()
        self.assertNotEqual(hue, devserver.mac(TEST_KEY, "bundle", SHARED_PAYLOAD))

    def test_an_envelope_is_the_mac_a_newline_and_the_payload_it_covers(self):
        body = devserver.envelope(TEST_KEY, "bundle", {"tree": OWN, "files": {"driver.lua": "x"}})
        payload = check(TEST_KEY, "bundle", body)
        self.assertEqual({"tree": OWN, "files": {"driver.lua": "x"}}, json.loads(payload))
        with self.assertRaises(AssertionError):
            check(OTHER_KEY, "bundle", body)
        with self.assertRaises(AssertionError):
            check(TEST_KEY, "commands", body)  # a MAC for one label is no good for another
        mac, _, payload = body.partition(b"\n")
        with self.assertRaises(AssertionError):
            check(TEST_KEY, "bundle", mac + b"\n" + payload.replace(b"x", b"y"))

    def test_the_payload_is_ascii_whatever_the_sources_hold(self):
        body = devserver.envelope(TEST_KEY, "bundle", {"files": {"a.lua": "commas ‚ here"}})
        body.decode("ascii")
        self.assertEqual("commas ‚ here", json.loads(check(TEST_KEY, "bundle", body))["files"]["a.lua"])


class KeyFileTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        for dirpath, dirnames, filenames in os.walk(self.dir, topdown=False):
            for name in filenames:
                os.remove(os.path.join(dirpath, name))
            for name in dirnames:
                os.rmdir(os.path.join(dirpath, name))
        os.rmdir(self.dir)

    def test_default_path_is_outside_the_repository(self):
        self.assertEqual("/k/devkey", devserver.default_key_file({"C4_MF_DEVKEY_FILE": "/k/devkey", "HOME": "/h"}))
        self.assertEqual("/x/c4-modernforms-driver/devkey", devserver.default_key_file({"XDG_CONFIG_HOME": "/x"}))
        home = os.path.expanduser("~")
        self.assertEqual(
            os.path.join(home, ".config", "c4-modernforms-driver", "devkey"),
            devserver.default_key_file({"XDG_CONFIG_HOME": "relative/ignored"}),
        )
        self.assertEqual(
            os.path.join(home, ".config", "c4-modernforms-driver", "devkey"), devserver.default_key_file({})
        )
        # The Hue project's variable names the Hue key: it is no override here.
        self.assertEqual(
            os.path.join(home, ".config", "c4-modernforms-driver", "devkey"),
            devserver.default_key_file({"C4_HUE_DEVKEY_FILE": "/hue/devkey"}),
        )

    def test_first_use_creates_a_0600_key_in_a_0700_directory(self):
        path = os.path.join(self.dir, "c4-modernforms-driver", "devkey")
        key, created = devserver.ensure_key(path)
        self.assertTrue(created)
        self.assertRegex(key.decode("ascii"), r"^[0-9a-f]{64}$")
        self.assertEqual(0o600, stat.S_IMODE(os.stat(path).st_mode))
        self.assertEqual(0o700, stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode))
        again, created = devserver.ensure_key(path)
        self.assertEqual(key, again)
        self.assertFalse(created)
        self.assertNotEqual(key, devserver.ensure_key(os.path.join(self.dir, "other", "devkey"))[0], "random keys")

    def test_refuses_a_file_others_can_read_without_saying_the_key(self):
        path = os.path.join(self.dir, "devkey")
        write_key(path, mode=0o640)
        with self.assertRaises(devserver.DevKeyError) as caught:
            devserver.load_key(path)
        self.assertIn("chmod 600", str(caught.exception))
        self.assertNotIn(TEST_KEY.decode(), str(caught.exception))

    def test_refuses_anything_but_64_lowercase_hex_characters(self):
        path = os.path.join(self.dir, "devkey")
        for content in (b"secret-but-not-a-key", TEST_KEY.upper(), TEST_KEY[:63], TEST_KEY + b"0"):
            write_key(path, content)
            with self.assertRaises(devserver.DevKeyError) as caught:
                devserver.load_key(path)
            self.assertNotIn(content.decode(), str(caught.exception))
        write_key(path)
        self.assertEqual(TEST_KEY, devserver.load_key(path))

    def test_a_missing_key_says_how_to_get_one(self):
        with self.assertRaises(devserver.DevKeyError) as caught:
            devserver.load_key(os.path.join(self.dir, "nothing"))
        self.assertIn("--ensure-key", str(caught.exception))

    def test_ensure_key_prints_the_path_and_the_fingerprint_never_the_key(self):
        path = os.path.join(self.dir, "devkey")
        write_key(path)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            devserver.main(["--ensure-key", "--key-file", path])
        self.assertEqual(path + "\n", out.getvalue())
        self.assertIn(TEST_FINGERPRINT, err.getvalue())
        self.assertNotIn(TEST_KEY.decode(), out.getvalue() + err.getvalue())

    def test_ensure_key_takes_the_environment_and_creates_the_key(self):
        path = os.path.join(self.dir, "from-env", "devkey")
        out, err = io.StringIO(), io.StringIO()
        with (
            mock.patch.dict(os.environ, {"C4_MF_DEVKEY_FILE": path}),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            devserver.main(["--ensure-key"])
        self.assertEqual(path + "\n", out.getvalue())
        self.assertIn("(created)", err.getvalue())
        key = devserver.load_key(path)
        self.assertNotIn(key.decode(), out.getvalue() + err.getvalue())

    def test_ensure_key_fails_on_a_bad_key_file(self):
        path = os.path.join(self.dir, "devkey")
        write_key(path, mode=0o644)
        with self.assertRaises(SystemExit) as caught:
            devserver.main(["--ensure-key", "--key-file", path])
        self.assertIn("chmod 600", str(caught.exception.code))


class BindTest(unittest.TestCase):
    def test_an_explicit_bind_wins_and_is_the_only_way_to_every_address(self):
        def never():
            raise AssertionError("no detection when --bind is given")

        self.assertEqual("203.0.113.9", devserver.choose_bind("203.0.113.9", detect=never))
        self.assertEqual("0.0.0.0", devserver.choose_bind("0.0.0.0", detect=never))
        self.assertIsNone(devserver.build_parser("/repo").parse_args([]).bind, "no 0.0.0.0 default")

    def test_the_default_port_leaves_the_hue_projects_8080_alone(self):
        self.assertEqual(8081, devserver.build_parser("/repo").parse_args([]).port)

    def test_the_default_is_the_lan_address(self):
        self.assertEqual("192.0.2.7", devserver.choose_bind(None, detect=lambda: "192.0.2.7"))
        self.assertIsNone(devserver.choose_bind(None, detect=lambda: None))

    def test_lan_address_asks_the_routing_table_and_never_answers_loopback_or_any(self):
        for answer, expected in (("192.0.2.7", "192.0.2.7"), ("127.0.0.1", None), ("0.0.0.0", None)):
            with mock.patch.object(devserver.socket, "socket") as factory:
                sock = factory.return_value.__enter__.return_value
                sock.getsockname.return_value = (answer, 40000)
                self.assertEqual(expected, devserver.lan_address())
                sock.connect.assert_called_once_with(devserver.ROUTE_PROBE)
                sock.sendto.assert_not_called()
                sock.send.assert_not_called()
                factory.assert_called_once_with(devserver.socket.AF_INET, devserver.socket.SOCK_DGRAM)
        with mock.patch.object(devserver.socket, "socket") as factory:
            factory.return_value.__enter__.return_value.connect.side_effect = OSError("Network is unreachable")
            self.assertIsNone(devserver.lan_address())

    def test_the_server_refuses_to_start_without_a_lan_address(self):
        def no_listener(*args, **kwargs):
            raise AssertionError("no listener may be created without an address")

        with tempfile.TemporaryDirectory() as root:
            make_root(root)
            key_file = os.path.join(root, "devkey")
            write_key(key_file)
            with (
                mock.patch.object(devserver, "lan_address", return_value=None),
                mock.patch.object(devserver, "DevServer", no_listener),
            ):
                with self.assertRaises(SystemExit) as caught:
                    devserver.main(["--root", root, "--key-file", key_file, "--state-dir", os.path.join(root, "s")])
            self.assertFalse(os.path.exists(os.path.join(root, "s", "server.json")))
        self.assertIn("--bind", str(caught.exception.code))

    def test_the_server_refuses_to_start_without_a_driver(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "src", "common"))
            key_file = os.path.join(root, "devkey")
            write_key(key_file)
            with self.assertRaises(SystemExit) as caught:
                devserver.main(["--root", root, "--key-file", key_file, "--bind", "127.0.0.1"])
        self.assertIn("no src/*/driver.xml", str(caught.exception.code))

    def test_where_a_local_client_finds_a_listener(self):
        self.assertEqual("127.0.0.1", devserver.url_host("0.0.0.0"))
        self.assertEqual("192.0.2.7", devserver.url_host("192.0.2.7"))


class TreeTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.root = self.dir.name

    def test_a_tree_per_driver_directory_named_after_it(self):
        make_root(self.root, second_tree=True)
        os.makedirs(os.path.join(self.root, "src", "bad-name"))
        with open(os.path.join(self.root, "src", "bad-name", "driver.xml"), "w", encoding="utf-8") as f:
            f.write("<devicedata/>\n")
        trees, skipped = devserver.discover_trees(self.root)
        self.assertEqual(["mf_light", OWN], list(trees), "in name order; common and notes have no driver.xml")
        self.assertEqual(["bad-name"], skipped, "a name no driver file can ask for")
        self.assertEqual(({}, []), devserver.discover_trees(os.path.join(self.root, "nowhere")))

    def test_serves_the_drivers_lua_and_xml_with_common_and_nothing_else(self):
        make_root(self.root)
        tree = devserver.discover_trees(self.root)[0][OWN]
        self.assertEqual(
            ["common/log.lua", "driver.lua", "driver.xml", "fan/http.lua"],
            sorted(tree.files()),
            "no devkey.lua anywhere, no hidden file, no manual",
        )

    def test_the_version_follows_the_content_and_a_pin_holds_it(self):
        make_root(self.root)
        tree = devserver.Tree(self.root, OWN)
        first = tree.read()[0]
        self.assertEqual(first, tree.snapshot()[0])
        self.assertEqual(first, tree.pin())
        with open(os.path.join(self.root, "src", "common", "log.lua"), "w", encoding="utf-8") as f:
            f.write("return { changed = true }\n")
        self.assertEqual(first, tree.snapshot()[0], "pinned: the old content is served")
        live = tree.read()[0]
        self.assertNotEqual(first, live)
        tree.unpin()
        self.assertEqual(live, tree.snapshot()[0])


class LiveServer:
    """A DevServer on 127.0.0.1, port 0, over a scratch tree, in a thread."""

    def __init__(self, key=TEST_KEY, second_tree=False):
        self.dir = tempfile.TemporaryDirectory()
        self.root = self.dir.name
        make_root(self.root, second_tree)
        self.state_dir = os.path.join(self.root, "build", "dev")
        self.lines = []
        self.patch = mock.patch.object(devserver, "emit", self.lines.append)
        self.patch.start()
        trees, _ = devserver.discover_trees(self.root)
        self.state = devserver.State(self.state_dir)
        self.server = devserver.DevServer(("127.0.0.1", 0), trees, self.state, key, quiet=True)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        self.patch.stop()
        self.dir.cleanup()

    def request(self, method, path, body=None, token=None):
        """(status, content type, body bytes)."""
        headers = {}
        if token is not None:
            headers["X-Devloop-Token"] = token
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, resp.headers.get("Content-Type"), resp.read()
        except urllib.error.HTTPError as exc:
            with exc:
                return exc.code, exc.headers.get("Content-Type"), exc.read()

    def status(self):
        status, _, body = self.request("GET", "/status", token=ADMIN_TOKEN)
        assert status == 200, status
        return json.loads(body)

    def warnings(self):
        return [line for line in self.lines if "WARNING" in line]


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.live = LiveServer()
        self.addCleanup(self.live.close)

    def test_admin_calls_need_the_token(self):
        command = {"type": "execute", "command": "Probe Call", "params": {"Fn": "GetDeviceID"}}
        status, _, body = self.live.request("POST", "/admin/enqueue", command)
        self.assertEqual(401, status)
        self.assertIn("admin token", json.loads(body)["error"])
        wrong = "f" * 64
        status, _, _ = self.live.request("POST", "/admin/enqueue", command, token=wrong)
        self.assertEqual(401, status)
        self.assertEqual([], self.live.state.commands, "nothing queued without the token")
        denies = [line for line in self.live.lines if " DENY " in line]
        self.assertEqual(2, len(denies))
        self.assertIn("no admin token", denies[0])
        self.assertIn("wrong admin token", denies[1])
        self.assertFalse(any(wrong in line for line in self.live.lines), "the value presented is not logged")

        status, _, body = self.live.request("POST", "/admin/enqueue", command, token=ADMIN_TOKEN)
        self.assertEqual(200, status)
        self.assertEqual({"id": 1}, json.loads(body))
        for path in ("/admin/pin", "/admin/unpin"):
            self.assertEqual(401, self.live.request("POST", path)[0], path)
            self.assertEqual(200, self.live.request("POST", path, token=ADMIN_TOKEN)[0], path)

    def test_status_needs_the_token_and_names_the_key(self):
        self.assertEqual(401, self.live.request("GET", "/status")[0])
        status, _, body = self.live.request("GET", "/status", token=ADMIN_TOKEN)
        self.assertEqual(200, status)
        st = json.loads(body)
        self.assertEqual(TEST_FINGERPRINT, st["key_fingerprint"])
        self.assertIsNone(st["driver_key_fingerprint"])
        self.assertFalse(st["driver_reported_key"])
        self.assertNotIn(TEST_KEY.decode(), body.decode())
        self.assertNotIn(ADMIN_TOKEN, body.decode())

    def test_the_driver_endpoints_need_no_token(self):
        self.assertEqual(200, self.live.request("GET", "/manifest?tree=" + OWN)[0])
        self.assertEqual(200, self.live.request("GET", "/bundle?tree=" + OWN)[0])
        self.assertEqual(200, self.live.request("GET", "/commands?after=0&nonce=" + NONCE)[0])
        self.assertEqual(204, self.live.request("POST", "/log", {"version": "v", "lines": []})[0])
        self.assertEqual(204, self.live.request("POST", "/report", {"event": "heartbeat"})[0])

    def test_unknown_paths_and_methods(self):
        self.assertEqual(404, self.live.request("GET", "/nothing")[0])
        self.assertEqual(405, self.live.request("POST", "/manifest", {"x": 1})[0])
        self.assertEqual(405, self.live.request("GET", "/report")[0])
        self.assertEqual(404, self.live.request("GET", "/stream")[0], "no connection experiment here")

    def test_bundles_are_signed_over_the_payload_and_name_their_tree(self):
        _, _, manifest = self.live.request("GET", "/manifest?tree=" + OWN)
        status, ctype, body = self.live.request("GET", "/bundle?tree=" + OWN)
        self.assertEqual(200, status)
        self.assertEqual(devserver.SIGNED_TYPE, ctype)
        payload = json.loads(check(TEST_KEY, "bundle", body))
        manifest = json.loads(manifest)
        self.assertEqual(manifest["version"], payload["version"])
        self.assertEqual(OWN, manifest["tree"])
        self.assertEqual(OWN, payload["tree"])
        self.assertEqual(
            {
                "driver.lua": "-- fan ‚\n",
                "driver.xml": "<devicedata/>\n",
                "fan/http.lua": "return {}\n",
                "common/log.lua": "return {}\n",
            },
            payload["files"],
        )
        self.assertEqual(sorted(payload["files"]), manifest["files"])
        body.decode("ascii")
        self.assertNotIn(OTHER_KEY.decode(), json.dumps(payload))

    def test_a_request_naming_no_tree_gets_the_only_one(self):
        _, _, named = self.live.request("GET", "/manifest?tree=" + OWN)
        status, _, unnamed = self.live.request("GET", "/manifest")
        self.assertEqual(200, status)
        self.assertEqual(json.loads(named)["version"], json.loads(unnamed)["version"])
        self.assertEqual(OWN, json.loads(unnamed)["tree"])
        self.assertEqual(OWN, json.loads(check(TEST_KEY, "bundle", self.live.request("GET", "/bundle")[2]))["tree"])

    def test_an_unknown_tree_is_a_400(self):
        for path in ("/manifest?tree=hue_bridge", "/bundle?tree=common", "/file?tree=notes&path=readme.lua"):
            status, _, body = self.live.request("GET", path)
            self.assertEqual(400, status, path)
            self.assertIn("unknown tree", json.loads(body)["error"])
        self.assertEqual(400, self.live.request("POST", "/admin/pin?tree=nothing", token=ADMIN_TOKEN)[0])

    def test_a_key_file_is_in_no_manifest_and_no_file_answer(self):
        _, _, manifest = self.live.request("GET", "/manifest?tree=" + OWN)
        self.assertFalse([f for f in json.loads(manifest)["files"] if f.endswith("devkey.lua")])
        for path in ("common/devkey.lua", "fan/devkey.lua", "../common/devkey.lua", "/etc/passwd", ".scratch.lua"):
            self.assertEqual(404, self.live.request("GET", "/file?path=" + path)[0], path)
        status, _, body = self.live.request("GET", "/file?path=common/log.lua")
        self.assertEqual((200, b"return {}\n"), (status, body))

    def test_commands_are_signed_together_with_the_nonce_asked_for(self):
        command = {"type": "set_property", "name": "Dev Server", "value": ""}
        self.live.request("POST", "/admin/enqueue", command, token=ADMIN_TOKEN)
        status, ctype, body = self.live.request("GET", "/commands?after=0&nonce=" + NONCE)
        self.assertEqual(200, status)
        self.assertEqual(devserver.SIGNED_TYPE, ctype)
        payload = json.loads(check(TEST_KEY, "commands", body))
        self.assertEqual(NONCE, payload["nonce"])
        self.assertEqual([dict(command, id=1)], payload["commands"])
        with self.assertRaises(AssertionError):
            check(TEST_KEY, "bundle", body)
        payload = json.loads(
            check(TEST_KEY, "commands", self.live.request("GET", "/commands?after=1&nonce=" + NONCE)[2])
        )
        self.assertEqual([], payload["commands"], "only the commands after the id asked for")

    def test_a_command_request_without_a_proper_nonce_or_after_is_a_400(self):
        for query in (
            "",
            "&nonce=",
            "&nonce=" + NONCE.upper(),
            "&nonce=abc",
            "&nonce=" + "g" * 32,
            "&nonce=" + "a" * 65,
        ):
            status, _, body = self.live.request("GET", "/commands?after=0" + query)
            self.assertEqual(400, status, query)
            self.assertIn("nonce", json.loads(body)["error"])
        status, _, body = self.live.request("GET", "/commands?after=x&nonce=" + NONCE)
        self.assertEqual(400, status)
        self.assertIn("after", json.loads(body)["error"])

    def test_a_command_stays_pending_until_a_driver_reports_it_done(self):
        for command in (
            {"type": "execute", "command": "Fan Off"},
            {"type": "set_property", "name": "Debug Mode", "value": "On"},
            {"type": "reload"},
        ):
            self.assertEqual(200, self.live.request("POST", "/admin/enqueue", command, token=ADMIN_TOKEN)[0])
        self.assertEqual([1, 2, 3], [c["id"] for c in self.live.status()["pending_commands"]])
        self.live.request("POST", "/report", {"event": "command_done", "command_id": 2, "properties": {"A": "1"}})
        st = self.live.status()
        self.assertEqual([1, 3], [c["id"] for c in st["pending_commands"]])
        self.assertEqual([2], st["done_commands"])
        self.assertEqual(2, st["last_done_id"])
        self.assertEqual({"A": "1"}, st["properties"])
        with open(os.path.join(self.live.state_dir, "commands.json"), encoding="utf-8") as f:
            saved = json.load(f)
        self.assertEqual((4, [2]), (saved["next_id"], saved["done"]))
        again = devserver.State(self.live.state_dir)
        self.assertEqual(4, again.next_id, "ids keep increasing across restarts")

    def test_a_malformed_command_is_a_400_and_queues_nothing(self):
        for body in (
            {"type": "execute"},
            {"type": "execute", "command": "A", "params": ["x"]},
            {"type": "set_property", "name": "Debug Mode"},
            {"type": "probe"},
            ["not", "an", "object"],
        ):
            status, _, _ = self.live.request("POST", "/admin/enqueue", body, token=ADMIN_TOKEN)
            self.assertEqual(400, status, body)
        self.assertEqual([], self.live.state.commands)

    def test_signed_with_its_own_key_only(self):
        other = LiveServer(OTHER_KEY)
        self.addCleanup(other.close)
        _, _, body = other.request("GET", "/bundle?tree=" + OWN)
        with self.assertRaises(AssertionError):
            check(TEST_KEY, "bundle", body)
        check(OTHER_KEY, "bundle", body)
        self.assertEqual(401, other.request("GET", "/status", token=ADMIN_TOKEN)[0], "a token is per key")

    def test_a_driver_with_another_key_is_warned_about_once(self):
        report = {"event": "startup", "key_fingerprint": OTHER_FINGERPRINT}
        self.live.request("POST", "/report", report)
        self.live.request("POST", "/report", dict(report, event="heartbeat"))
        warnings = self.live.warnings()
        self.assertEqual(1, len(warnings))
        self.assertIn(OTHER_FINGERPRINT, warnings[0])
        self.assertIn(TEST_FINGERPRINT, warnings[0])
        self.assertEqual(OTHER_FINGERPRINT, self.live.status()["driver_key_fingerprint"])

        self.live.request("POST", "/report", dict(report, key_fingerprint=TEST_FINGERPRINT))
        self.assertEqual(1, len(self.live.warnings()), "a match is not warned")

        self.live.request("POST", "/report", {"event": "startup"})
        self.assertIn("no dev key", self.live.warnings()[-1])

    def test_reports_and_log_posts_say_which_version_each_tree_runs(self):
        st = self.live.status()
        self.assertEqual([OWN], list(st["trees"]))
        tree = st["trees"][OWN]
        self.assertEqual(tree["local_version"], tree["live_version"])
        self.assertIsNone(tree["running_version"])
        self.assertIsNone(tree["forwarded_version"])
        self.assertIsNone(tree["pinned"])

        self.live.request("POST", "/report", {"event": "reload", "tree": OWN, "version": "v1"})
        self.assertEqual("v1", self.live.status()["trees"][OWN]["running_version"])
        self.live.request("POST", "/log", {"version": "v2", "tree": OWN, "lines": []})
        self.assertEqual("v2", self.live.status()["trees"][OWN]["running_version"])
        # A tree some report names that the server does not serve is not listed.
        self.live.request("POST", "/report", {"event": "heartbeat", "tree": "other", "version": "x"})
        self.assertEqual([OWN], list(self.live.status()["trees"]))

    def test_a_forwarded_tree_is_reported_as_forwarded(self):
        other = LiveServer(second_tree=True)
        self.addCleanup(other.close)
        other.request(
            "POST", "/report", {"event": "heartbeat", "tree": OWN, "version": "v1", "forwarded": {"mf_light": "L1"}}
        )
        trees = other.status()["trees"]
        self.assertEqual(["mf_light", OWN], sorted(trees))
        self.assertEqual("v1", trees[OWN]["running_version"])
        self.assertEqual("L1", trees["mf_light"]["forwarded_version"])
        self.assertIsNone(trees["mf_light"]["running_version"])

    def test_with_several_trees_a_request_must_name_one(self):
        other = LiveServer(second_tree=True)
        self.addCleanup(other.close)
        for path in ("/manifest", "/bundle", "/file?path=driver.lua"):
            status, _, body = other.request("GET", path)
            self.assertEqual(400, status, path)
            self.assertIn("mf_light or modernforms_fan", json.loads(body)["error"])
        _, _, body = other.request("GET", "/bundle?tree=mf_light")
        payload = json.loads(check(TEST_KEY, "bundle", body))
        self.assertEqual("mf_light", payload["tree"])
        self.assertEqual(
            {"driver.lua": "-- light\n", "driver.xml": "<devicedata/>\n", "common/log.lua": "return {}\n"},
            payload["files"],
        )
        reply = json.loads(other.request("POST", "/admin/pin?tree=mf_light", token=ADMIN_TOKEN)[2])
        self.assertIsNone(reply["pinned"][OWN])
        self.assertEqual(
            json.loads(other.request("GET", "/manifest?tree=mf_light")[2])["version"], reply["pinned"]["mf_light"]
        )

    def test_a_second_polling_device_is_warned_about_once(self):
        self.live.request("POST", "/report", {"event": "startup", "tree": OWN, "device_id": 15})
        self.live.request("POST", "/report", {"event": "heartbeat", "tree": OWN, "device_id": 15.0})
        self.assertEqual([], self.live.warnings(), "one device, its id written either way")
        self.live.request("POST", "/report", {"event": "startup", "tree": OWN, "device_id": 16})
        self.live.request("POST", "/report", {"event": "heartbeat", "tree": OWN, "device_id": 16})
        warnings = self.live.warnings()
        self.assertEqual(1, len(warnings))
        self.assertIn("device 16 reports here as well as device(s) 15", warnings[0])
        st = self.live.status()
        self.assertEqual(16, st["device_id"])
        self.assertEqual(["15", "16"], sorted(st["devices"]))
        self.assertEqual(OWN, st["devices"]["16"]["tree"])

    def test_a_device_seen_long_ago_is_no_second_poller(self):
        self.live.state.devices[15] = {"tree": OWN, "last_seen": devserver.now() - devserver.DEVICE_WINDOW_S - 1}
        self.live.request("POST", "/report", {"event": "startup", "tree": OWN, "device_id": 16})
        self.assertEqual([], self.live.warnings())

    def test_log_lines_are_written_and_echoed_in_order(self):
        lines = {"2": {"t": 1761572096000, "line": "second"}, "1": {"t": 1761572095000, "line": "first"}}
        self.assertEqual(204, self.live.request("POST", "/log", {"version": "v", "tree": OWN, "lines": lines})[0])
        with open(os.path.join(self.live.state_dir, "driver.log"), encoding="utf-8") as f:
            written = f.read().splitlines()
        self.assertEqual(["first", "second"], [line.split(" ", 1)[1] for line in written], "Director's object form")
        self.assertEqual(2, len([line for line in self.live.lines if line.startswith("LOG ")]))
        status, _, _ = self.live.request("POST", "/log", {"version": "v", "lines": "not a list"})
        self.assertEqual(400, status)

    def test_reports_are_kept_and_summarised(self):
        report = {
            "event": "refused",
            "tree": OWN,
            "device_id": 15,
            "refused_tree": OWN,
            "refused_version": "0123456789abcdef",
            "error": "signature mismatch",
            "forwarded": {"mf_light": "fedcba9876543210"},
        }
        self.live.request("POST", "/report", report)
        with open(os.path.join(self.live.state_dir, "reports.jsonl"), encoding="utf-8") as f:
            kept = [json.loads(line) for line in f]
        self.assertEqual("refused", kept[0]["event"])
        self.assertIn("received", kept[0])
        summary = [line for line in self.live.lines if "REPORT refused" in line][0]
        for part in (
            "dev=15",
            "tree=modernforms_fan",
            "refused=modernforms_fan@0123456789ab",
            "fwd=mf_light:fedcba987654",
        ):
            self.assertIn(part, summary)
        self.assertIn("error=signature mismatch", summary)
        self.assertEqual("signature mismatch", self.live.status()["last_error"])

    def test_server_json_says_where_the_server_is_and_goes_with_it(self):
        path = devserver.write_server_file(self.live.state_dir, self.live.url)
        with open(path, encoding="utf-8") as f:
            saved = json.load(f)
        self.assertEqual(self.live.url, saved["url"])
        self.assertNotIn(ADMIN_TOKEN, json.dumps(saved))
        with open(path, "w", encoding="utf-8") as f:
            json.dump(dict(saved, pid=saved["pid"] + 1), f)
        devserver.remove_server_file(path)
        self.assertTrue(os.path.exists(path), "another server's file is left alone")
        devserver.write_server_file(self.live.state_dir, self.live.url)
        devserver.remove_server_file(path)
        self.assertFalse(os.path.exists(path))


class DevctlTest(unittest.TestCase):
    def setUp(self):
        self.live = LiveServer()
        self.addCleanup(self.live.close)
        self.key_file = os.path.join(self.live.root, "devkey")
        write_key(self.key_file)
        devserver.write_server_file(self.live.state_dir, self.live.url)

    def devctl(self, *argv, key_file=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = devctl.main(
                ["--state-dir", self.live.state_dir, "--key-file", key_file or self.key_file] + list(argv)
            )
        return code, out.getvalue(), err.getvalue()

    def test_sends_the_token_and_finds_the_server_through_server_json(self):
        code, out, err = self.devctl("run", "Fan Request", "Method=POST", "Body={}")
        self.assertEqual((0, "1\n", ""), (code, out, err))
        self.assertEqual("Fan Request", self.live.state.commands[0]["command"])
        self.assertEqual({"Method": "POST", "Body": "{}"}, self.live.state.commands[0]["params"])
        self.assertEqual((0, "2\n", ""), self.devctl("set", "Debug Mode", "On"))
        self.assertEqual((0, "3\n", ""), self.devctl("reload"))
        code, out, _ = self.devctl("pin")
        self.assertEqual(0, code)
        self.assertRegex(out, r"^pinned modernforms_fan +[0-9a-f]{12}\n$")
        self.assertEqual((0, "serving the live tree\n", ""), self.devctl("unpin"))
        code, _, err = self.devctl("pin", "--tree", "nothing")
        self.assertEqual(1, code)
        self.assertIn("unknown tree", err)

    def test_a_parameter_must_be_key_value(self):
        code, out, err = self.devctl("run", "A", "no-equals")
        self.assertEqual((1, ""), (code, out))
        self.assertIn("is not Key=Value", err)
        self.assertEqual([], self.live.state.commands)

    def test_status_says_whether_the_driver_has_the_servers_key(self):
        self.assertIn("driver has not reported yet", self.devctl("status")[1])
        self.live.request("POST", "/report", {"event": "startup", "key_fingerprint": TEST_FINGERPRINT})
        code, out, _ = self.devctl("status")
        self.assertEqual(0, code)
        self.assertIn("dev_key                matches the server's (fingerprint %s)" % TEST_FINGERPRINT, out)
        self.live.request("POST", "/report", {"event": "heartbeat", "key_fingerprint": OTHER_FINGERPRINT})
        self.assertIn("DIFFERS: driver %s, server %s" % (OTHER_FINGERPRINT, TEST_FINGERPRINT), self.devctl("status")[1])
        self.live.request("POST", "/report", {"event": "heartbeat"})
        self.assertIn("DRIVER HAS NONE", self.devctl("status")[1])

    def test_status_shows_every_tree_and_the_polling_device(self):
        out = self.devctl("status")[1]
        self.assertIn("tree modernforms_fan\n  running              -  (no device has reported this tree yet)\n", out)
        self.assertIn("device                 none has reported yet\n", out)
        local = self.live.status()["trees"][OWN]["local_version"]
        self.live.request(
            "POST",
            "/report",
            {"event": "reload", "tree": OWN, "version": local, "device_id": 15, "properties": {"Debug Mode": "Off"}},
        )
        out = self.devctl("status")[1]
        self.assertIn("  running              %s  (matches local)\n" % local[:12], out)
        self.assertIn("  local                %s\n" % local[:12], out)
        self.assertIn("device                 15 (modernforms_fan)\n", out)
        self.assertIn("last_event             reload\n", out)
        self.assertIn("  Debug Mode = Off\n", out)
        self.live.request("POST", "/report", {"event": "heartbeat", "tree": OWN, "version": "0" * 40, "device_id": 16})
        out = self.devctl("status")[1]
        self.assertIn("  running              000000000000  (DIFFERS from local; a reload is due)\n", out)
        self.assertIn("MORE THAN ONE device polls this server", out)

    def test_wait_ends_with_the_properties_of_the_done_report(self):
        command_id = int(self.devctl("set", "Debug Mode", "Off")[1])
        self.live.request(
            "POST", "/report", {"event": "command_done", "command_id": command_id, "properties": {"Debug Mode": "Off"}}
        )
        code, out, err = self.devctl("wait", str(command_id), "--timeout", "5")
        self.assertEqual((0, ""), (code, err))
        self.assertEqual("properties:\n  Debug Mode = Off\n", out)

    def test_another_key_is_refused_with_a_hint(self):
        other = os.path.join(self.live.root, "other-key")
        write_key(other, OTHER_KEY)
        code, out, err = self.devctl("run", "Probe Call", key_file=other)
        self.assertEqual(1, code)
        self.assertEqual("", out)
        self.assertIn("refused the admin token", err)
        self.assertEqual([], self.live.state.commands)

    def test_without_a_key_file_nothing_is_sent(self):
        code, _, err = self.devctl("status", key_file=os.path.join(self.live.root, "missing"))
        self.assertEqual(1, code)
        self.assertIn("no dev key at", err)

    def test_without_server_json_it_says_so(self):
        os.remove(os.path.join(self.live.state_dir, "server.json"))
        code, _, err = self.devctl("status")
        self.assertEqual(1, code)
        self.assertIn("is tools/devserver.py running?", err)
        out, err2 = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err2):
            code = devctl.main(
                ["--server", self.live.url, "--state-dir", self.live.state_dir, "--key-file", self.key_file, "status"]
            )
        self.assertEqual(0, code, err2.getvalue())

    def test_log_reads_the_file_and_needs_no_key(self):
        path = os.path.join(self.live.state_dir, "driver.log")
        with open(path, "w", encoding="utf-8") as f:
            f.write("12:00:00.000 devloop: started\n12:00:03.000 devloop: reload complete: version abc\n")
        out, err = io.TextIOWrapper(io.BytesIO(), encoding="utf-8"), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = devctl.main(
                [
                    "--state-dir",
                    self.live.state_dir,
                    "--key-file",
                    os.path.join(self.live.root, "none"),
                    "log",
                    "-n",
                    "1",
                ]
            )
        out.flush()
        self.assertEqual(0, code, err.getvalue())
        self.assertEqual(b"12:00:03.000 devloop: reload complete: version abc\n", out.buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
