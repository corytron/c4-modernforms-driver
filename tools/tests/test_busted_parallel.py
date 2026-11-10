"""Unit tests for tools/busted_parallel.py and tools/busted_parallel.lua: on spec files with every kind
of outcome, the parallel run prints what one serial `busted` run prints and exits the same (#183).
Skipped where busted is not installed (CI's tooling job; the Lua job runs the runner itself).

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(TOOLS, "busted_parallel.py")
sys.path.insert(0, TOOLS)

import busted_parallel  # noqa: E402

SPECS = {
    "a_spec.lua": """
        describe("a", function()
          it("passes", function() assert.is_true(true) end)
          it("fails", function() assert.are.equal(1, 2) end)
          it("errors", function() error("boom") end)
          pending("later")
          it("prints", function() print("printed by a test") end)
        end)
    """,
    "b_spec.lua": """
        describe("b", function()
          it("passes", function() assert.is_true(true) end)
          describe("nested", function()
            before_each(function() end)
            it("writes to both streams", function()
              io.stderr:write("to stderr\\n")
              io.write("to stdout\\n")
            end)
          end)
        end)
        describe("b describe that errors", function()
          error("describe blew up")
        end)
    """,
    "c_spec.lua": """
        describe("c", function()
          it("raises a table", function() error({ code = 7, why = "x" }) end)
          it("compares tables", function() assert.same({ a = 1 }, { a = 1 }) end)
        end)
    """,
    # Does not compile: busted reports it before any test runs.
    "d_spec.lua": """
        describe("d", function()
          it("x", function() end
        end)
    """,
    "helper.lua": "return {}\n",
}

SECONDS = re.compile(r": [0-9.]+ seconds$", re.MULTILINE)


@unittest.skipUnless(shutil.which("busted"), "busted is not installed")
class Specs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.makedirs(os.path.join(self.tmp.name, "spec"))
        self.write(SPECS)

    def write(self, specs):
        for name, text in specs.items():
            with open(os.path.join(self.tmp.name, "spec", name), "w", encoding="utf-8") as f:
                f.write(textwrap.dedent(text).lstrip())

    def run_command(self, command, jobs="3"):
        done = subprocess.run(
            command,
            cwd=self.tmp.name,
            env=dict(os.environ, JOBS=jobs),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        return done.returncode, SECONDS.sub(": T seconds", done.stdout.decode("utf-8", "replace")), done.stderr

    def assert_same(self, *args, jobs="3"):
        serial = self.run_command(["busted", *args])
        parallel = self.run_command([sys.executable, "-I", SCRIPT, *args], jobs=jobs)
        self.assertEqual(parallel[:2], serial[:2])
        return parallel


# One class per group of runs: the parallel runner runs classes at the same time.
class Outcomes(Specs):
    def test_every_outcome_reads_the_same(self):
        code, out, _ = self.assert_same("spec")
        self.assertEqual(code, 1)
        self.assertIn("5 successes / 1 failure / 4 errors / 1 pending : T seconds", out)


class Options(Specs):
    def test_verbose_and_plain_handler(self):
        self.assert_same("-v", "spec")
        self.assert_same("-o", "plainTerminal", "spec")


class Roots(Specs):
    def test_a_passing_run_and_a_single_file(self):
        code, _, _ = self.assert_same("spec/c_spec.lua")
        self.assertEqual(code, 1)
        self.write({"a_spec.lua": 'it("ok", function() end)\n', "b_spec.lua": "", "c_spec.lua": "", "d_spec.lua": ""})
        code, out, _ = self.assert_same("spec")
        self.assertEqual(code, 0)
        self.assertIn("1 success / 0 failures / 0 errors / 0 pending", out)

    def test_more_files_than_jobs(self):
        self.assert_same("spec", jobs="2")


class Fallback(Specs):
    def test_what_it_does_not_split_runs_busted(self):
        # An option it does not know, a root that does not exist, a file that exposes state: busted.
        for args in (("--filter=passes", "spec"), ("missing",)):
            with self.subTest(args=args):
                self.assert_same(*args)
        self.write({"e_spec.lua": 'expose("shared", function() end)\n'})
        _, _, err = self.assert_same("spec")
        self.assertIn(b"uses expose()", err)


class ParseTest(unittest.TestCase):
    def test_what_it_splits(self):
        self.assertEqual(busted_parallel.parse(["tests"]), (None, False, ["tests"]))
        self.assertEqual(
            busted_parallel.parse(["-v", "-o", "utfTerminal", "a", "b"]), ("utfTerminal", True, ["a", "b"])
        )
        self.assertEqual(
            busted_parallel.parse(["--output=plainTerminal", "--", "-x"]), ("plainTerminal", False, ["-x"])
        )

    def test_what_it_leaves_to_busted(self):
        for args in (["--shuffle"], ["-o", "TAP"], ["-o"], ["--filter=x", "tests"]):
            with self.subTest(args=args):
                self.assertIsNone(busted_parallel.parse(args))


if __name__ == "__main__":
    unittest.main()
