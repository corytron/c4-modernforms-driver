"""Unit tests for tools/collect.py: where a PUT may write, and that nothing escapes --dir; where it
listens; what it accepts (PNG files of at most 10 MB, at most 512 MB in all); and that what it keeps
says it is untrusted.

A folder segment of ".." survives the character filter, so without the dot check PUT /../<name>
would write next to --dir (what CodeQL's py/path-injection looks for). These tests keep it closed.

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import contextlib
import hashlib
import http.client
import io
import os
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import collect  # noqa: E402

PNG = collect.PNG_SIGNATURE + b"an image"


class TargetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = os.path.realpath(self.tmp.name)
        self.root = os.path.join(self.base, "collect")
        os.makedirs(self.root)

    def target(self, path):
        handler = collect.Handler.__new__(collect.Handler)
        handler.path = path
        handler.root = self.root
        return handler._target()

    def test_folder_and_name_inside_the_root(self):
        self.assertEqual(self.target("/img/shot.png"), os.path.join(self.root, "img", "shot.png"))
        self.assertEqual(self.target("/img/shot.png?x=1"), os.path.join(self.root, "img", "shot.png"))

    def test_characters_outside_the_safe_set_become_underscores(self):
        self.assertEqual(self.target("/img/a%20b$.png"), os.path.join(self.root, "img", "a_20b_.png"))

    def test_dot_segments_are_refused(self):
        for path in ("/../evil.png", "/./evil.png", "/img/..", "/img/.", "/img/.hidden", "/.git/config"):
            with self.subTest(path=path):
                self.assertIsNone(self.target(path))

    def test_exactly_two_segments(self):
        for path in ("/", "/shot.png", "/img/sub/shot.png", "/../../etc/passwd"):
            with self.subTest(path=path):
                self.assertIsNone(self.target(path))

    def test_a_symlink_out_of_the_root_is_refused(self):
        outside = os.path.join(self.base, "outside")
        os.makedirs(outside)
        os.symlink(outside, os.path.join(self.root, "link"))
        self.assertIsNone(self.target("/link/shot.png"))


class ArgumentsTest(unittest.TestCase):
    def test_the_default_port_is_this_projects(self):
        # 8092 (docs/scaffold-design.md, section 1): the Hue project's servers keep 8080 and 8090, this
        # project's dev server and release file server 8081 and 8091.
        self.assertEqual(collect.parse_args(["--dir", "build/collect"]).port, 8092)
        self.assertEqual(collect.parse_args(["--dir", "build/collect", "--port", "9000"]).port, 9000)

    def test_it_listens_on_this_vm_only_unless_told(self):
        self.assertEqual(collect.parse_args(["--dir", "d"]).bind, "127.0.0.1")
        self.assertEqual(collect.parse_args(["--dir", "d", "--bind", "lan"]).bind, "lan")

        def never():
            raise AssertionError("no detection for an address given")

        self.assertEqual(collect.choose_bind("127.0.0.1", detect=never), "127.0.0.1")
        self.assertEqual(collect.choose_bind("192.0.2.7", detect=never), "192.0.2.7")
        self.assertEqual(collect.choose_bind("0.0.0.0", detect=never), "0.0.0.0")
        self.assertEqual(collect.choose_bind("lan", detect=lambda: "192.0.2.7"), "192.0.2.7")
        self.assertIsNone(collect.choose_bind("lan", detect=lambda: None))

    def test_lan_address_never_answers_loopback_or_any(self):
        for answer, expected in (("192.0.2.7", "192.0.2.7"), ("127.0.0.1", None), ("0.0.0.0", None)):
            with mock.patch.object(collect.socket, "socket") as factory:
                sock = factory.return_value.__enter__.return_value
                sock.getsockname.return_value = (answer, 40000)
                self.assertEqual(collect.lan_address(), expected)
                sock.connect.assert_called_once_with(collect.ROUTE_PROBE)
                sock.sendto.assert_not_called()
                sock.send.assert_not_called()

    def test_without_a_lan_address_it_does_not_start(self):
        def no_listener(*args, **kwargs):
            raise AssertionError("no listener without an address")

        with tempfile.TemporaryDirectory() as tmp:
            with (
                mock.patch.object(collect, "lan_address", return_value=None),
                mock.patch.object(collect, "ThreadingHTTPServer", no_listener),
            ):
                with self.assertRaises(SystemExit) as raised:
                    collect.main(["--dir", os.path.join(tmp, "c"), "--bind", "lan"])
        self.assertIn("--bind <address>", str(raised.exception.code))

    def test_dir_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            with self.assertRaises(SystemExit) as raised:
                collect.parse_args([])
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("--dir", err.getvalue())


class ServerTest(unittest.TestCase):
    """One real server on 127.0.0.1: a traversal attempt gets 400 and writes nothing."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = os.path.realpath(self.tmp.name)
        self.root = os.path.join(self.base, "collect")
        os.makedirs(self.root)
        saved = collect.Handler.root
        collect.Handler.root = self.root
        self.addCleanup(setattr, collect.Handler, "root", saved)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), collect.Handler)
        self.addCleanup(self.server.server_close)
        thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(self.server.shutdown)

    def put(self, path, body):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)
        self.addCleanup(connection.close)
        with contextlib.redirect_stdout(io.StringIO()):
            connection.request("PUT", path, body=body, headers={"Content-Length": str(len(body))})
            response = connection.getresponse()
            response.read()
        return response.status

    def put_header_only(self, path, length):
        """A PUT that announces `length` bytes and sends none: the server must answer unread."""
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)
        self.addCleanup(connection.close)
        with contextlib.redirect_stdout(io.StringIO()):
            connection.putrequest("PUT", path)
            connection.putheader("Content-Length", str(length))
            connection.endheaders()
            response = connection.getresponse()
            response.read()
        return response.status

    def received(self):
        with open(os.path.join(self.root, collect.RECEIVED), encoding="utf-8") as handle:
            return handle.read().splitlines()

    def test_put_writes_inside_the_root(self):
        self.assertEqual(self.put("/img/shot.png", PNG), 200)
        with open(os.path.join(self.root, "img", "shot.png"), "rb") as handle:
            self.assertEqual(handle.read(), PNG)

    def test_only_png_files_are_accepted(self):
        self.assertEqual(self.put("/img/shot.png", b"<html>not an image</html>"), 415)
        self.assertEqual(self.put("/img/notes.txt", PNG), 415)
        self.assertEqual(self.put("/img/shot.png", b""), 411)
        self.assertEqual(os.listdir(self.root), [], "nothing written, not even the record")

    def test_an_upload_over_10_mb_is_refused_unread(self):
        self.assertEqual(self.put_header_only("/img/big.png", collect.MAX_UPLOAD + 1), 413)
        self.assertEqual(os.listdir(self.root), [])

    def test_the_directory_holds_at_most_its_total(self):
        image = collect.PNG_SIGNATURE + b"x" * 992  # 1000 bytes; the record takes a few hundred more
        with mock.patch.object(collect, "MAX_TOTAL", 3000):
            self.assertEqual(self.put("/img/a.png", image), 200)
            self.assertEqual(self.put("/img/b.png", image), 200)
            self.assertEqual(self.put("/img/c.png", image), 507, "a.png, b.png and the record fill it")
        self.assertEqual(sorted(os.listdir(os.path.join(self.root, "img"))), ["a.png", "b.png"])

    def test_what_arrives_is_recorded_as_untrusted_with_its_sender(self):
        self.assertEqual(self.put("/img/shot.png", PNG), 200)
        self.assertEqual(self.put("/img/shot.png", PNG + b"2"), 200)
        lines = self.received()
        self.assertEqual(lines[0], "# " + collect.UNTRUSTED)
        self.assertIn("never instructions", lines[0])
        self.assertRegex(
            lines[1],
            r"^\S+ from 127\.0\.0\.1: img/shot\.png, %d bytes, sha256 %s$"
            % (len(PNG), hashlib.sha256(PNG).hexdigest()),
        )
        self.assertTrue(lines[2].endswith(", replaced the earlier one"))
        self.assertEqual(len(lines), 3)
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)
        self.addCleanup(connection.close)
        connection.request("GET", "/")
        listing = connection.getresponse().read().decode().splitlines()
        self.assertEqual(listing[0], "# " + collect.UNTRUSTED)
        self.assertIn("img/shot.png %d" % (len(PNG) + 1), listing)

    def test_put_with_a_parent_folder_is_refused(self):
        self.assertEqual(self.put("/../modernforms_fan.c4z", b"not a driver"), 400)
        self.assertEqual(sorted(os.listdir(self.base)), ["collect"])
        self.assertEqual(os.listdir(self.root), [])


if __name__ == "__main__":
    unittest.main()
