"""Unit tests for tools/collect.py: where a PUT may write, and that nothing escapes --dir.

A folder segment of ".." survives the character filter, so without the dot check PUT /../<name>
would write next to --dir (what CodeQL's py/path-injection looks for). These tests keep it closed.

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import contextlib
import http.client
import io
import os
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import collect  # noqa: E402


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
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
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

    def test_put_writes_inside_the_root(self):
        self.assertEqual(self.put("/img/shot.png", b"png"), 200)
        with open(os.path.join(self.root, "img", "shot.png"), "rb") as handle:
            self.assertEqual(handle.read(), b"png")

    def test_put_with_a_parent_folder_is_refused(self):
        self.assertEqual(self.put("/../modernforms_fan.c4z", b"not a driver"), 400)
        self.assertEqual(sorted(os.listdir(self.base)), ["collect"])
        self.assertEqual(os.listdir(self.root), [])


if __name__ == "__main__":
    unittest.main()
