"""Unit tests for tools/unittest_parallel.py: on a set of test modules with every kind of outcome, its
output and exit status are those of `python3 -m unittest`, whatever the options (#183).

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(TOOLS, "unittest_parallel.py")
sys.path.insert(0, TOOLS)

import unittest_parallel  # noqa: E402

FIXTURES = {
    "test_outcomes.py": '''
        import os
        import sys
        import unittest


        class Outcomes(unittest.TestCase):
            def test_ok(self):
                print("stdout from a passing test")

            def test_failure(self):
                """The first line of its docstring."""
                sys.stderr.write("stderr from a failing test\\n")
                self.assertEqual(1, 2)

            def test_error(self):
                raise RuntimeError("boom")

            @unittest.skip("not today")
            def test_skipped(self):
                pass

            @unittest.expectedFailure
            def test_expected_failure(self):
                self.fail("as expected")

            @unittest.expectedFailure
            def test_unexpected_success(self):
                pass

            def test_subtests(self):
                for i in range(3):
                    with self.subTest(i=i):
                        self.assertNotEqual(i, 1)
                        if i == 2:
                            raise ValueError("an error in a subtest")

            def test_a_child_process_writes(self):
                os.system("echo from a child process")


        class ClassFixtureFails(unittest.TestCase):
            @classmethod
            def setUpClass(cls):
                raise RuntimeError("setUpClass failed")

            def test_never_runs(self):
                pass


        class Later(unittest.TestCase):
            def test_ok(self):
                pass
    ''',
    "test_module_fixture.py": """
        import unittest


        def setUpModule():
            print("module set up")


        class First(unittest.TestCase):
            def test_one(self):
                pass

            def test_two(self):
                self.assertTrue(False, "two")


        class Second(unittest.TestCase):
            def test_three(self):
                pass
    """,
    "test_import_error.py": """
        import a_module_that_does_not_exist  # noqa: F401
    """,
}

ELAPSED = re.compile(r"^(Ran \d+ tests? in )[0-9.]+s$", re.MULTILINE)


def write_fixtures(directory, fixtures):
    for name, text in fixtures.items():
        with open(os.path.join(directory, name), "w", encoding="utf-8") as f:
            f.write(textwrap.dedent(text).lstrip())


class Fixtures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        write_fixtures(self.tmp.name, FIXTURES)

    def run_both(self, *args, jobs="4"):
        """(exit status, output) of python3 -m unittest, then of unittest_parallel.py, in the fixtures."""
        env = dict(os.environ, JOBS=jobs, PYTHONDONTWRITEBYTECODE="1")
        env.pop("PYTHON_COLORS", None)
        outcomes = []
        for command in ([sys.executable, "-B", "-m", "unittest"], [sys.executable, "-B", SCRIPT]):
            done = subprocess.run(
                [*command, *args],
                cwd=self.tmp.name,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            outcomes.append((done.returncode, ELAPSED.sub(r"\1Xs", done.stdout)))
        return outcomes

    def assert_same(self, *variants):
        for args in variants:
            with self.subTest(args=args):
                serial, parallel = self.run_both(*args)
                self.assertEqual(parallel, serial)
                self.assertEqual(serial[0], 1)


# One class per group of runs: the parallel runner runs classes at the same time.
class DotsAndVerbose(Fixtures):
    def test_every_outcome_reads_the_same(self):
        self.assert_same((), ("-v",), ("-q",))


class BufferAndFailfast(Fixtures):
    def test_every_outcome_reads_the_same(self):
        self.assert_same(("-b",), ("-v", "-b"), ("-f",))


class Selection(Fixtures):
    def test_every_outcome_reads_the_same(self):
        self.assert_same(("-k", "subtests"), ("test_module_fixture",))


class Edges(Fixtures):
    def test_jobs_1_is_the_serial_run(self):
        serial, parallel = self.run_both("-v", jobs="1")
        self.assertEqual(parallel, serial)

    def test_a_passing_run(self):
        os.remove(os.path.join(self.tmp.name, "test_outcomes.py"))
        os.remove(os.path.join(self.tmp.name, "test_import_error.py"))
        serial, parallel = self.run_both("discover", "-p", "test_module_fixture.py", "-k", "one")
        self.assertEqual(parallel, serial)
        self.assertEqual(serial[0], 0)

    def test_a_process_that_ends_mid_test(self):
        write_fixtures(
            self.tmp.name,
            {
                "test_exits.py": """
                    import os
                    import unittest


                    class Exits(unittest.TestCase):
                        def test_before(self):
                            pass

                        def test_exits(self):
                            os._exit(3)
                """
            },
        )
        done = subprocess.run(
            [sys.executable, "-B", SCRIPT, "test_exits"],
            cwd=self.tmp.name,
            env=dict(os.environ, JOBS="2"),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(done.returncode, 1)
        self.assertIn("ERROR: test_exits (test_exits.Exits.test_exits)", done.stderr)
        self.assertIn("the process running this exited with status 3", done.stderr)

    def test_a_bad_jobs_value(self):
        done = subprocess.run(
            [sys.executable, "-B", SCRIPT, "test_module_fixture"],
            cwd=self.tmp.name,
            env=dict(os.environ, JOBS="many"),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(done.returncode, 1)
        self.assertIn("JOBS must be a positive integer", done.stderr)


class UnitsTest(unittest.TestCase):
    def test_a_class_runs_whole_and_a_module_with_fixtures_too(self):
        class A(unittest.TestCase):
            def test_1(self):
                pass

            def test_2(self):
                pass

        class B(unittest.TestCase):
            def test_3(self):
                pass

        tests = [A("test_1"), A("test_2"), B("test_3"), A("test_1")]
        self.assertEqual(unittest_parallel.units(tests), [[0, 1], [2], [3]])
        module = sys.modules[__name__]
        module.setUpModule = lambda: None
        self.addCleanup(delattr, module, "setUpModule")
        self.assertEqual(unittest_parallel.units(tests), [[0, 1, 2, 3]])


if __name__ == "__main__":
    unittest.main()
