#!/usr/bin/env python3
"""Run busted over the spec files in parallel, one busted process per file, and print what one serial
`busted` run prints (#183).

    tools/busted_parallel.py [-o plainTerminal|utfTerminal] [-v] [ROOT...]

ROOT is what `busted ROOT...` takes (default: the ROOT of .busted). busted itself finds the spec
files (tools/busted_parallel.lua, mode discover: its roots, .busted pattern and sort), then runs
each file in its own process, at most JOBS at a time (default: every core, as `nproc` counts them),
the longest files first. The output is busted's own: the status characters of every file in busted's
file order, with whatever the tests print, then the summary that busted's handler prints from the
counts, pendings, failures and errors of all of them, and the wall time of the parallel run. The
exit status is busted's: 0 when every test passed, 1 otherwise.

Each spec file runs in a fresh busted process instead of an insulated block of one process, so a
file cannot see what an earlier one left behind. A file that uses expose() exists to hand state to
the files after it, so its presence (or any other argument, or JOBS=1) runs plain busted instead,
serially, with the same arguments.
"""

import os
import re
import selectors
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

HANDLER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "busted_parallel.lua")
TERMINAL_HANDLERS = ("plainTerminal", "utfTerminal")
EXPOSE = re.compile(rb"\bexpose\s*[(\"'\[]")


def job_count():
    """JOBS when set (a positive integer), else the cores this process may use."""
    value = os.environ.get("JOBS", "").strip()
    if value:
        if not value.isdigit() or int(value) < 1:
            sys.exit("busted_parallel.py: JOBS must be a positive integer, not %r" % value)
        return int(value)
    counter = getattr(os, "process_cpu_count", None) or os.cpu_count
    return counter() or 1


def parse(argv):
    """(output handler or None, verbose, roots), or None when an argument is not one this runner
    knows how to split across processes."""
    output, verbose, roots = None, False, []
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--":
            roots.extend(args)
            break
        if arg in ("-o", "--output"):
            if not args:
                return None
            output = args.pop(0)
        elif arg.startswith("--output="):
            output = arg.split("=", 1)[1]
        elif arg in ("-v", "--verbose"):
            verbose = True
        elif arg.startswith("-"):
            return None
        else:
            roots.append(arg)
    if output is not None and output not in TERMINAL_HANDLERS:
        return None
    return output, verbose, roots


class Serial(Exception):
    """Run plain busted instead, for the reason given (empty: none worth printing)."""


def serial(argv, why):
    if why:
        print("busted_parallel.py: %s; running busted serially" % why, file=sys.stderr, flush=True)
    sys.stdout.flush()
    os.execvp("busted", ["busted", *argv])


def read_both(process):
    """What the process wrote, as (sys.stdout or sys.stderr, bytes) in the order it arrived, so that
    each piece goes to the stream it was written to and a terminal or log that shows both shows
    them in the same order."""
    chunks = []
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ, sys.stdout)
        selector.register(process.stderr, selectors.EVENT_READ, sys.stderr)
        while selector.get_map():
            for key, _ in selector.select():
                data = os.read(key.fileobj.fileno(), 65536)
                if data:
                    chunks.append((key.data, data))
                else:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
    return chunks


def environment(mode, inner, dump=None):
    env = dict(os.environ)
    env["BUSTED_PARALLEL_MODE"] = mode
    env["BUSTED_PARALLEL_OUTPUT"] = inner
    env.pop("BUSTED_PARALLEL_DUMP", None)
    if dump is not None:
        env["BUSTED_PARALLEL_DUMP"] = dump
    return env


def main(argv):
    parsed = parse(argv)
    jobs = job_count()
    if parsed is None or jobs == 1:
        serial(argv, "")
    try:
        return parallel(jobs, *parsed)
    except Serial as why:
        serial(argv, str(why))


def parallel(jobs, output, verbose, roots):
    # What busted would pick (busted/runner.lua): utfTerminal on a terminal, else plainTerminal. The
    # processes below write to pipes, so a terminal's colors are asked for by name.
    tty = sys.stdout.isatty()
    inner = output or ("utfTerminal" if tty else "plainTerminal")
    options = ["-o", HANDLER]
    if verbose:
        options.append("-v")
    if inner == "utfTerminal" and tty:
        options.append("-Xoutput=--color")

    with tempfile.TemporaryDirectory(prefix="busted-parallel-") as work:
        listing = os.path.join(work, "files.txt")
        subprocess.run(
            ["busted", *options, *roots],
            env=environment("discover", inner, listing),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if not os.path.exists(listing):
            raise Serial("busted did not list the spec files")
        # Files that do not compile come first: busted reports them while it loads every file, before
        # any test runs.
        broken, files = [], []
        with open(listing, encoding="utf-8", errors="surrogateescape") as f:
            for line in f.read().splitlines():
                kind, _, name = line.partition("\t")
                if kind == "problem":
                    raise Serial("busted reported: " + name)
                if kind in ("error", "file") and name:
                    (broken if kind == "error" else files).append(name)
        order = broken + files
        if not order:
            raise Serial("busted found no spec file")
        for name in files:
            try:
                with open(name, "rb") as f:
                    if EXPOSE.search(f.read()):
                        raise Serial(name + " uses expose(), which hands state to the files after it")
            except OSError:
                pass

        # The summary is printed by one more busted run, started now so that its start-up overlaps the
        # shards; it waits on stdin for their dumps.
        empty = os.path.join(work, "render_spec.lua")
        with open(empty, "w", encoding="utf-8") as f:
            f.write("-- tools/busted_parallel.py: the summary's run has no test of its own\n")
        render = subprocess.Popen(
            ["busted", *options, empty],
            env=environment("render", inner),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

        def run(index):
            dump = os.path.join(work, "%d.dump" % index)
            process = subprocess.Popen(
                ["busted", *options, order[index]],
                env=environment("shard", inner, dump),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            chunks = read_both(process)
            return process.wait(), chunks, dump

        def size(index):
            try:
                return os.path.getsize(order[index])
            except OSError:
                return 0

        # Longest first, as a guess at the slowest: the last file to start should be a short one.
        by_size = sorted(range(len(order)), key=lambda i: (-size(i), i))
        started = time.monotonic()
        with ThreadPoolExecutor(max_workers=min(jobs, len(order))) as pool:
            futures = {index: pool.submit(run, index) for index in by_size}
            results = [futures[index].result() for index in range(len(order))]
        elapsed = time.monotonic() - started

        failed = False
        dumps = []
        out = sys.stdout.buffer
        for name, (code, chunks, dump) in zip(order, results, strict=True):
            for stream, data in chunks:
                stream.buffer.write(data)
                stream.buffer.flush()
            if code != 0:
                failed = True
            if os.path.exists(dump):
                dumps.append(dump)
            else:
                failed = True
                note = "\nbusted_parallel.py: busted exited with status %d on %s without a report\n" % (code, name)
                out.write(note.encode("utf-8", "surrogateescape"))
                out.flush()
        out.flush()
        summary, _ = render.communicate(("%r\n" % elapsed + "".join(d + "\n" for d in dumps)).encode())
        out.write(summary)
        out.flush()
        if render.returncode != 0:
            print("busted_parallel.py: the summary's busted run exited with status %d" % render.returncode)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
