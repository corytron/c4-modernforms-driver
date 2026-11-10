"""Unit tests for tools/luacheck_jobs.lua: `luacheck -j N` through it prints byte for byte what serial
luacheck prints, with the same exit status, warnings, syntax errors and unreadable files included
(#183). Skipped where luacheck is not installed (CI's tooling job; the Lua job runs it itself).

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INIT = "@" + os.path.join(TOOLS, "luacheck_jobs.lua")

FILES = {
    "warnings.lua": """
        local unused = 1
        global_value = 2
        print(undefined_value)
    """,
    "syntax.lua": """
        local function broken(
    """,
    "clean.lua": """
        return 1
    """,
    # The third line is longer than luacheck's 120 columns.
    "inline.lua": "local a = 1 -- luacheck: ignore 211\nlocal b = 2\nlocal long = '%s'\n" % ("x" * 130),
    "sub/more.lua": """
        local x = 1
        return function() return x end
    """,
}


@unittest.skipUnless(shutil.which("luacheck"), "luacheck is not installed")
class SameAsLuacheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        for name, text in FILES.items():
            path = os.path.join(self.tmp.name, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(textwrap.dedent(text).lstrip())

    def luacheck(self, args, init=None):
        env = dict(os.environ)
        env.pop("LUA_INIT", None)
        if init:
            env["LUA_INIT"] = init
        done = subprocess.run(["luacheck", *args], cwd=self.tmp.name, env=env, capture_output=True, check=False)
        return done.returncode, done.stdout, done.stderr

    def assert_same(self, args, jobs):
        serial = self.luacheck(args)
        parallel = self.luacheck(["-j", jobs, *args], init=INIT)
        self.assertEqual(parallel, serial)
        return serial

    def test_the_same_report(self):
        for args, jobs in (
            ([".", "missing.lua"], "2"),
            ([".", "missing.lua"], "16"),
            (["--codes", "--ranges", "."], "3"),
            (["--formatter=plain", "-q", "."], "3"),
        ):
            with self.subTest(args=args, jobs=jobs):
                self.assertNotEqual(self.assert_same(args, jobs)[0], 0)

    def test_a_clean_run(self):
        self.assertEqual(self.assert_same(["clean.lua", "sub"], "4")[0], 0)

    def test_no_temporary_files_left(self):
        before = set(os.listdir(tempfile.gettempdir()))
        self.luacheck(["-j", "4", "."], init=INIT)
        leftovers = [n for n in set(os.listdir(tempfile.gettempdir())) - before if n.startswith("lua_")]
        self.assertEqual(leftovers, [])


if __name__ == "__main__":
    unittest.main()
