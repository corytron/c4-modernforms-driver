#!/usr/bin/env python3
"""`python3 -m unittest`, with the tests run in parallel processes (#183).

    python3 -B tools/unittest_parallel.py discover -s tools/tests [-v] [-f] [-b] [--durations N] ...

Takes every argument `python3 -m unittest` takes, and unittest itself parses them, finds the tests
and decides the exit status. The tests run in up to JOBS processes at a time (default: every core,
as `nproc` counts them), each a fork of this one after discovery: every test class runs whole in
one process, its tests in their usual order and its class fixtures once, as unittest runs them
(a module with module fixtures runs whole in one process). What each test did (its outcome, its
formatted traceback, its duration, and what it printed on stdout or stderr) comes back here and is
replayed, in discovery order, into unittest's own result and runner, so the output and the exit
status are those of the serial run. Only "Ran N tests in X s" differs: X is the parallel run's.
JOBS=1 runs the tests here, serially, exactly as `python3 -m unittest` does.

A test class therefore runs in a copy of the process as discovery left it, not after the classes
before it: a class that relied on another class having run first would show it.
"""

import json
import os
import sys
import tempfile
import unittest
import unittest.case
import unittest.suite


def job_count():
    """JOBS when set (a positive integer), else the cores this process may use."""
    value = os.environ.get("JOBS", "").strip()
    if value:
        if not value.isdigit() or int(value) < 1:
            sys.exit("unittest_parallel.py: JOBS must be a positive integer, not %r" % value)
        return int(value)
    counter = getattr(os, "process_cpu_count", None) or os.cpu_count
    return counter() or 1


def flatten(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from flatten(test)
        else:
            yield test


def has_module_fixtures(test):
    module = sys.modules.get(type(test).__module__)
    return any(hasattr(module, name) for name in ("setUpModule", "tearDownModule"))


def units(tests):
    """The tests, in order, cut into the runs of one class (or of one module with module fixtures),
    as lists of indexes."""
    groups, key = [], None
    for index, test in enumerate(tests):
        cls = type(test)
        new_key = ("module", cls.__module__) if has_module_fixtures(test) else ("class", cls)
        if not groups or new_key != key:
            groups.append([])
            key = new_key
        groups[-1].append(index)
    return groups


class Formatted(tuple):
    """What a child sends for an exception: its formatted text, and whether it was a failure (the
    test's failureException) or an error; err[0] is all unittest reads of it here."""

    def __new__(cls, exc_class, text):
        self = super().__new__(cls, (exc_class, None, None))
        self.text = text
        return self


class ReplayedSubTest(unittest.case._SubTest):
    """A subtest as the child described it."""

    def __init__(self, test_case, text, short, ident):
        super().__init__(test_case, None, {})
        self._text, self._short, self._ident = text, short, ident

    def __str__(self):
        return self._text

    def shortDescription(self):
        return self._short

    def id(self):
        return self._ident


# --- the child: run one unit, write its events as JSON lines ---------------------------------------


class Recorder(unittest.TestResult):
    """Writes every event of the run to `sink` as it happens, with whatever the tests wrote since the
    event before (see run_child)."""

    def __init__(self, index_of, sink, captures):
        super().__init__()
        self.index_of = index_of
        self.sink = sink
        self.captures = captures

    def _ref(self, test):
        index = self.index_of.get(id(test))
        return {"index": index} if index is not None else {"holder": str(test)}

    def _emit(self, kind, test=None, **fields):
        for stream, reader, writer in self.captures:
            if writer is not None:
                writer.flush()
            data = reader.read()
            if data:
                # Text as the stream encoded it; bytes from a descriptor survive as surrogates.
                if writer is not None:
                    text = data.decode(writer.encoding, "replace")
                else:
                    text = data.decode("utf-8", "surrogateescape")
                self.sink.write(json.dumps({"kind": "output", "stream": stream, "data": text}) + "\n")
        if kind is not None:
            event = {"kind": kind, **fields}
            if test is not None:
                event.update(self._ref(test))
            self.sink.write(json.dumps(event) + "\n")
        self.sink.flush()

    def _text(self, err, test):
        return self._exc_info_to_string(err, test)

    def startTest(self, test):
        self._emit("start", test)
        super().startTest(test)

    def stopTest(self, test):
        super().stopTest(test)
        self._emit("stop", test)

    def addSuccess(self, test):
        super().addSuccess(test)
        self._emit("success", test)

    def addError(self, test, err):
        self._emit("error", test, text=self._text(err, test))
        super().addError(test, err)

    def addFailure(self, test, err):
        self._emit("failure", test, text=self._text(err, test))
        super().addFailure(test, err)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self._emit("skip", test, reason=reason)

    def addExpectedFailure(self, test, err):
        self._emit("expected_failure", test, text=self._text(err, test))
        super().addExpectedFailure(test, err)

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self._emit("unexpected_success", test)

    def addSubTest(self, test, subtest, err):
        fields = {"sub": str(subtest), "short": subtest.shortDescription(), "sub_id": subtest.id()}
        if err is not None:
            fields["failure"] = issubclass(err[0], test.failureException)
            fields["text"] = self._text(err, test)
        self._emit("subtest", test, **fields)
        super().addSubTest(test, subtest, err)

    def addDuration(self, test, elapsed):
        super().addDuration(test, elapsed)
        self._emit("duration", test, elapsed=elapsed)


def run_child(tests, unit, path, options):
    """In the forked child: run one unit, events to `path`, stdin from /dev/null. What the tests
    write is read back after every event from four files: sys.stdout and sys.stderr (replaced, so
    the parent can write it through its own, buffered, streams as the serial run would have) and
    file descriptors 1 and 2 (written straight through, as child processes' output would have)."""
    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)
    # Tracebacks are colored when the parent's result stream is a terminal (Python 3.14 asks
    # can_colorize(file=result.stream)): a copy of that descriptor answers the same question.
    stream = options["stream"]
    try:
        stream = open(os.dup(stream.fileno()), "w", closefd=True)
    except (AttributeError, OSError, ValueError):
        pass
    directory = os.path.dirname(path)
    captures = []
    for fd, name in ((1, "stdout"), (2, "stderr")):
        original = getattr(sys, name)
        handle, py_path = tempfile.mkstemp(dir=directory)
        replacement = open(handle, "w", encoding=original.encoding, errors=original.errors, newline="")
        setattr(sys, name, replacement)
        captures.append((name, open(py_path, "rb"), replacement))
        handle, raw_path = tempfile.mkstemp(dir=directory)
        os.dup2(handle, fd)
        os.close(handle)
        # A reader of its own: fd and its dup share one file offset, a new open() does not.
        captures.append(("fd" + str(fd), open(raw_path, "rb"), None))
    with open(path, "w", encoding="utf-8") as sink:
        recorder = Recorder({id(tests[i]): i for i in unit}, sink, captures)
        recorder.stream = stream
        recorder.buffer = options["buffer"]
        recorder.failfast = options["failfast"]
        recorder.tb_locals = options["tb_locals"]
        unittest.TestSuite([tests[i] for i in unit])(recorder)
        recorder._emit(None)


# --- the parent: fork the units, then replay their events -----------------------------------------


def run_units(tests, groups, jobs, work, options):
    """Fork up to `jobs` children at a time, one per unit; returns {unit number: exit status}."""
    sys.stdout.flush()
    sys.stderr.flush()
    # The biggest units first, as a guess at the slowest.
    waiting = sorted(range(len(groups)), key=lambda number: (-len(groups[number]), number))
    running, statuses = {}, {}
    try:
        while waiting or running:
            while waiting and len(running) < jobs:
                number = waiting.pop(0)
                pid = os.fork()
                if pid == 0:
                    status = 1
                    try:
                        run_child(tests, groups[number], os.path.join(work, "%d.jsonl" % number), options)
                        status = 0
                    finally:
                        os._exit(status)
                running[pid] = number
            pid, status = os.wait()
            if pid in running:
                statuses[running.pop(pid)] = os.waitstatus_to_exitcode(status)
    except BaseException:
        for pid in running:
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        raise
    return statuses


def read_events(path):
    events = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    break
    except OSError:
        pass
    return events


class Replay:
    """The 'test' TextTestRunner.run runs: the parallel run, then its events into `result`."""

    def __init__(self, runner, tests, jobs):
        self.runner, self.tests, self.jobs = runner, tests, jobs

    def __call__(self, result):
        # The children buffered (-b) already: their tracebacks carry what was buffered.
        options = {
            "buffer": result.buffer,
            "failfast": result.failfast,
            "tb_locals": result.tb_locals,
            "stream": getattr(result, "stream", None),
        }
        result.buffer = False
        groups = units(self.tests)
        with tempfile.TemporaryDirectory(prefix="unittest-parallel-") as work:
            statuses = run_units(self.tests, groups, self.jobs, work, options)
            for number, unit in enumerate(groups):
                events = read_events(os.path.join(work, "%d.jsonl" % number))
                if not self.replay(result, events, unit, statuses.get(number)):
                    break
        return result

    def test_of(self, event):
        if "index" in event:
            return self.tests[event["index"]]
        return unittest.suite._ErrorHolder(event["holder"])

    def replay(self, result, events, unit, status):
        """Feeds one unit's events to result; False once the run should stop (failfast)."""
        started = None
        for event in events:
            kind = event["kind"]
            if kind == "output":
                stream = event["stream"]
                if stream in ("stdout", "stderr"):
                    getattr(sys, stream).write(event["data"])
                else:
                    os.write(1 if stream == "fd1" else 2, event["data"].encode("utf-8", "surrogateescape"))
                continue
            test = self.test_of(event)
            if kind == "start":
                if result.shouldStop:
                    return False
                started = test
                result.startTest(test)
            elif kind == "stop":
                result.stopTest(test)
                started = None
            elif kind == "success":
                result.addSuccess(test)
            elif kind == "error":
                result.addError(test, Formatted(Exception, event["text"]))
            elif kind == "failure":
                result.addFailure(test, Formatted(test.failureException, event["text"]))
            elif kind == "skip":
                result.addSkip(test, event["reason"])
            elif kind == "expected_failure":
                result.addExpectedFailure(test, Formatted(test.failureException, event["text"]))
            elif kind == "unexpected_success":
                result.addUnexpectedSuccess(test)
            elif kind == "subtest":
                subtest = ReplayedSubTest(test, event["sub"], event["short"], event["sub_id"])
                err = None
                if "text" in event:
                    err = Formatted(test.failureException if event["failure"] else Exception, event["text"])
                result.addSubTest(test, subtest, err)
            elif kind == "duration" and hasattr(result, "addDuration"):
                result.addDuration(test, event["elapsed"])
        if status != 0:
            # The child ended before its unit was done (a test that ended the process, say): an error
            # for the test it was in, or for the unit.
            message = "unittest_parallel.py: the process running this exited with status %s\n" % status
            if started is not None:
                result.addError(started, Formatted(Exception, message))
                result.stopTest(started)
            else:
                holder = unittest.suite._ErrorHolder("unittest_parallel.py (%s)" % self.tests[unit[0]].id())
                result.addError(holder, Formatted(Exception, message))
        return not result.shouldStop


def replaying(resultclass):
    """resultclass, taking a Formatted exception as its text."""

    class ReplayResult(resultclass):
        def _exc_info_to_string(self, err, test):
            if isinstance(err, Formatted):
                return err.text
            return super()._exc_info_to_string(err, test)

    ReplayResult.__name__ = resultclass.__name__
    ReplayResult.__qualname__ = resultclass.__qualname__
    return ReplayResult


class ParallelTextTestRunner(unittest.TextTestRunner):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.jobs = job_count()
        if self.jobs > 1:
            self.resultclass = replaying(self.resultclass)

    def run(self, test):
        if self.jobs == 1:
            return super().run(test)
        tests = list(flatten(test))
        return super().run(Replay(self, tests, self.jobs))


def main():
    # As under `python3 -m unittest`, the working directory is first on the path, not tools/.
    here = os.path.dirname(os.path.abspath(__file__))
    if not sys.flags.safe_path and sys.path and os.path.abspath(sys.path[0]) == here:
        sys.path[0] = os.getcwd()
    unittest.main(module=None, argv=["python3 -m unittest", *sys.argv[1:]], testRunner=ParallelTextTestRunner)


if __name__ == "__main__":
    main()
