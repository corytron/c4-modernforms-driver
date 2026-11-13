"""Unit tests for tools/build.sh, and for the secret scan's rules for the dev key.

build.sh runs for real in a scratch repository: this checkout's tools/build.sh, tools/changelog.py
and tools/devserver.py, a changelog with no release yet, a small invented driver, a fake git on
PATH (build.sh asks it for the commit count and the commit; no repository is needed) and a fake
packager that zips the stage the way dp3 does, which a test can tell to slip a file into the package
or to append lines to driver.lua. What is checked: a release package holds exactly its stage and
nothing development-only, by name (devloop*, devkey*, devcmds*), by DEV-ONLY marker or by a call that
opens the Lua command window, while the call that locks it passes; no symbolic link reaches a
package; and a dev build leaves each package alone under a random path in build/serve/.

The dev-key rules of .gitleaks.toml are tested against fake keys made at run time, never the real
key: no test vector here is a literal of the form the rules look for.

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import tempfile
import tomllib
import unittest
import zipfile

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TOOLS)
DRIVER = "mf_test"

FAKE_GIT = """#!/bin/sh
# Stands in for git: the answers tools/build.sh asks for.
case " $* " in
  *" rev-list --count HEAD "*) echo 7 ;;
  *" status --porcelain "*) ;;
  *" describe "*) exit 128 ;;
  *" rev-parse HEAD "*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  *) echo "fake git: unexpected: $*" >&2; exit 1 ;;
esac
"""

# Called as dp3 is: --driver-version N --update-modified [--allowexecute] <stage> <out> <proj>.
# FAKE_DP3_PLANT names a file to add to the package; FAKE_DP3_APPEND, text to append to driver.lua.
FAKE_DP3 = r"""
import os, sys, zipfile
args = sys.argv[1:]
version = args[args.index("--driver-version") + 1]
stage, out, _proj = [a for a in args if not a.startswith("--") and a != version]
driver = os.path.basename(stage)
append = os.environ.get("FAKE_DP3_APPEND", "")
if "--allowexecute" in args:
    append += "\nC4:AllowExecute(true)\n\ngIsDevelopmentVersionOfDriver = true\n"
with zipfile.ZipFile(os.path.join(out, driver + ".c4z"), "w", zipfile.ZIP_DEFLATED) as z:
    for folder, dirs, files in os.walk(stage):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(folder, name)
            arc = os.path.relpath(path, stage).replace(os.sep, "/")
            if arc.endswith(".c4zproj"):
                continue
            with open(path, "rb") as f:
                data = f.read()
            if arc == "driver.xml":
                data = data.replace(b"<version>1</version>", b"<version>" + version.encode() + b"</version>")
                data = data.replace(b"01/01/2026 12:00 PM</modified>", b"11/13/2026 01:00 AM</modified>")
            if arc == "driver.lua":
                data += append.encode()
            z.writestr(arc, data)
    if os.environ.get("FAKE_DP3_PLANT"):
        z.writestr(os.environ["FAKE_DP3_PLANT"], b"-- slipped in\n")
"""

DRIVER_XML = """<?xml version="1.0" encoding="UTF-8"?>
<devicedata>
\t<version>1</version>
\t<modified>01/01/2026 12:00 PM</modified>
\t<config>
\t\t<properties>
\t\t\t<property><name>Debug Mode</name><default></default></property>
\t\t\t<!-- DEV-ONLY BEGIN: tools/build.sh strips this block from release builds -->
\t\t\t<property><name>Dev Server</name></property>
\t\t\t<!-- DEV-ONLY END -->
\t\t</properties>
\t</config>
</devicedata>
"""

# The driver's own call that locks the Lua command window: a release carries it.
LOCK = "if not devloop then pcall(C4.AllowExecute, C4, false) end\n"

SOURCES = {
    "src/%s/driver.xml" % DRIVER: DRIVER_XML,
    "src/%s/driver.lua" % DRIVER: "-- driver\n" + LOCK,
    "src/%s/fan/http.lua" % DRIVER: "return {}\n",
    "src/%s/fan/devcmds.lua" % DRIVER: "-- development commands\n",
    "src/%s/www/documentation.html" % DRIVER: "<html><body>\n<p>manual</p>\n<!-- CHANGELOG -->\n</body></html>\n",
    "src/%s/www/images/devices_sm/%s_16.png" % (DRIVER, DRIVER): "\x89PNG\r\n\x1a\nicon",
    "src/common/device.lua": "return {}\n",
    "src/common/log.lua": "return {}\n",
    "src/common/devloop.lua": "-- the dev loop\n",
    "LICENSE": "Apache License 2.0\n",
    "NOTICE": "notice\n",
    # Not this checkout's: another change to it must not decide these tests.
    "CHANGELOG.md": "# Changelog\n\nEvery release, newest first.\n\n## Unreleased\n",
    ".github/codenames.json": "{}\n",
    ".github/codename-meanings.json": "{}\n",
}
COPIED = ("tools/build.sh", "tools/changelog.py", "tools/devserver.py")
RELEASE_FILES = [
    "LICENSE",
    "NOTICE",
    "common/build_version.lua",
    "common/device.lua",
    "common/log.lua",
    "driver.lua",
    "driver.xml",
    "fan/http.lua",
    "www/documentation.html",
    "www/images/devices_sm/%s_16.png" % DRIVER,
]


class BuildCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = os.path.realpath(self.tmp.name)
        self.root = os.path.join(self.base, "repo")
        for rel in COPIED:
            os.makedirs(os.path.dirname(os.path.join(self.root, rel)), exist_ok=True)
            shutil.copyfile(os.path.join(ROOT, rel), os.path.join(self.root, rel))
        for rel, text in SOURCES.items():
            self.write(rel, text)
        bin_dir = os.path.join(self.base, "bin")
        os.makedirs(bin_dir)
        git = os.path.join(bin_dir, "git")
        with open(git, "w", encoding="utf-8") as f:
            f.write(FAKE_GIT)
        os.chmod(git, 0o755)
        self.dp3 = os.path.join(self.base, "dp3.py")
        with open(self.dp3, "w", encoding="utf-8") as f:
            f.write(FAKE_DP3)
        self.key_file = os.path.join(self.base, "keydir", "devkey")
        self.env = dict(
            os.environ,
            PATH=bin_dir + os.pathsep + os.environ.get("PATH", ""),
            DP3=self.dp3,
            JOBS="2",
            C4_MF_DEVKEY_FILE=self.key_file,
            C4_MF_RELEASE_TAG="",
        )
        for name in ("FAKE_DP3_PLANT", "FAKE_DP3_APPEND"):
            self.env.pop(name, None)

    def write(self, rel, text):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)

    def build(self, *args, **env):
        proc = subprocess.run(
            ["bash", os.path.join(self.root, "tools", "build.sh"), *args],
            capture_output=True,
            text=True,
            env=dict(self.env, **env),
            timeout=120,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def package(self):
        return os.path.join(self.root, "build", DRIVER + ".c4z")

    def names(self):
        with zipfile.ZipFile(self.package()) as z:
            return sorted(z.namelist())

    def read(self, name):
        with zipfile.ZipFile(self.package()) as z:
            return z.read(name)


class ReleaseBuildTest(BuildCase):
    def test_a_release_package_is_its_stage_without_development_files(self):
        code, out, err = self.build()
        self.assertEqual(code, 0, err)
        self.assertIn("built build/%s.c4z (version 7)" % DRIVER, out)
        self.assertEqual(self.names(), RELEASE_FILES, "device.lua and devices_sm stay; devloop and devcmds go")
        xml = self.read("driver.xml").decode()
        self.assertNotIn("Dev Server", xml)
        self.assertNotIn("DEV-ONLY", xml)
        self.assertIn("<version>7</version>", xml)
        self.assertEqual(self.read("driver.lua").decode(), "-- driver\n" + LOCK, "the lock passes")
        self.assertEqual(self.read("common/build_version.lua"), b'return "7"\n')
        self.assertFalse(os.path.exists(os.path.join(self.root, "build", "serve")), "nothing to serve")
        with open(os.path.join(self.root, "build", "manifest.json"), encoding="utf-8") as f:
            self.assertIs(json.load(f)["dev"], False)

    def test_a_new_development_module_named_by_the_rule_never_ships(self):
        self.write("src/%s/fan/devcmds_extra.lua" % DRIVER, "-- more development commands\n")
        self.write("src/%s/fan/DevLoop_helper.lua" % DRIVER, "-- any case\n")
        self.write("src/common/devcmds/tool.lua", "-- a directory of them\n")
        code, out, err = self.build()
        self.assertEqual(code, 0, err)
        self.assertEqual(self.names(), RELEASE_FILES)

    def test_a_dev_only_marker_left_in_lua_fails_the_build(self):
        self.write("src/%s/fan/http.lua" % DRIVER, "-- <!-- DEV-ONLY BEGIN\nreturn {}\n")
        code, out, err = self.build()
        self.assertEqual(code, 1)
        self.assertIn("release build still carries development items in %s (a DEV-ONLY marker in" % DRIVER, err)
        self.assertFalse(os.path.exists(self.package()))

    def test_the_lock_passes_and_every_call_that_opens_the_window_fails(self):
        passes = (
            "pcall(C4.AllowExecute, C4, false)\n",
            "C4:AllowExecute(false)\n",
            "-- see 22_miscellaneous/_2-AllowExecute.md\n",
        )
        fails = (
            "C4:AllowExecute(true)\n",
            "C4:AllowExecute( true )\n",
            "C4.AllowExecute(C4, true)\n",
            "pcall(C4.AllowExecute, C4, true)\n",
            "gIsDevelopmentVersionOfDriver = true\n",
        )
        for line in passes + fails:
            with self.subTest(line=line):
                self.write("src/%s/fan/http.lua" % DRIVER, "return {}\n" + line)
                code, out, err = self.build()
                if line in passes:
                    self.assertEqual(code, 0, err)
                else:
                    self.assertEqual(code, 1, out)
                    self.assertIn("fan/http.lua opens the Lua command window", err)

    def test_what_the_packager_slips_in_fails_the_build(self):
        for plant, reason in (
            ("common/devloop.lua", "common/devloop.lua is a development-only file"),
            ("fan/devcmds.lua", "fan/devcmds.lua is a development-only file"),
            ("extra.lua", "extra.lua is in the package but not in the stage"),
        ):
            with self.subTest(plant=plant):
                code, out, err = self.build(FAKE_DP3_PLANT=plant)
                self.assertEqual(code, 1, out)
                self.assertIn(reason, err)
        code, out, err = self.build(FAKE_DP3_APPEND="\nC4:AllowExecute(true)\n")
        self.assertEqual(code, 1, out)
        self.assertIn("driver.lua differs from the stage", err)
        self.assertIn("driver.lua opens the Lua command window", err)

    def test_a_symbolic_link_under_src_is_refused_before_anything_is_built(self):
        secret = os.path.join(self.base, "hosts.yml")
        with open(secret, "w", encoding="utf-8") as f:
            f.write("not for a package\n")
        os.symlink(secret, os.path.join(self.root, "src", DRIVER, "www", "images", "x.png"))
        os.symlink(os.path.join(self.root, "src", "common"), os.path.join(self.root, "src", DRIVER, "linked"))
        code, out, err = self.build()
        self.assertEqual(code, 1)
        self.assertIn("these are symbolic links: src/%s/linked src/%s/www/images/x.png" % (DRIVER, DRIVER), err)
        self.assertNotIn("not for a package", out + err)
        self.assertFalse(os.path.exists(os.path.join(self.root, "build")), "refused before anything")

    def test_a_linked_input_is_refused(self):
        os.rename(os.path.join(self.root, "LICENSE"), os.path.join(self.base, "LICENSE"))
        os.symlink(os.path.join(self.base, "LICENSE"), os.path.join(self.root, "LICENSE"))
        code, out, err = self.build()
        self.assertEqual(code, 1)
        self.assertIn("these are symbolic links: LICENSE", err)

    def test_a_key_file_in_src_is_refused(self):
        self.write("src/%s/fan/DevKey.lua.bak" % DRIVER, "-- a copy\n")
        code, out, err = self.build()
        self.assertEqual(code, 1)
        self.assertIn("src/%s/fan/DevKey.lua.bak must not exist" % DRIVER, err)


class DevBuildTest(BuildCase):
    def test_a_dev_build_serves_each_package_alone_under_a_random_path(self):
        code, out, err = self.build("--dev")
        self.assertEqual(code, 0, err)
        with open(self.key_file, encoding="ascii") as f:
            key = f.read().strip()  # this test's own key, made by devserver.py --ensure-key
        self.assertNotIn(key, out + err)
        names = self.names()
        for name in ("common/devkey.lua", "common/devloop.lua", "fan/devcmds.lua"):
            self.assertIn(name, names)
        self.assertIn(b"Dev Server", self.read("driver.xml"))
        self.assertTrue(self.read("driver.lua").endswith(b"gIsDevelopmentVersionOfDriver = true\n"))
        self.assertEqual(stat.S_IMODE(os.stat(self.package()).st_mode), 0o600)

        serve = os.path.join(self.root, "build", "serve")
        listing = sorted(os.listdir(serve))
        self.assertEqual(len(listing), 2)
        self.assertIn("index.html", listing)
        self.assertEqual(os.path.getsize(os.path.join(serve, "index.html")), 0, "no directory listing")
        token = [name for name in listing if name != "index.html"][0]
        self.assertRegex(token, r"^[0-9a-f]{32}$")
        self.assertEqual(os.listdir(os.path.join(serve, token)), [DRIVER + ".c4z"], "that one file")
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(serve, token)).st_mode), 0o700)
        served = os.path.join(serve, token, DRIVER + ".c4z")
        self.assertEqual(stat.S_IMODE(os.stat(served).st_mode), 0o600)
        with open(served, "rb") as a, open(self.package(), "rb") as b:
            self.assertEqual(a.read(), b.read())
        self.assertIn("at the URL path /%s/%s.c4z" % (token, DRIVER), out)
        self.assertIn("--directory build/serve", out)
        self.assertFalse(
            os.path.exists(os.path.join(self.root, "build", "stage", DRIVER, "common", "devkey.lua")),
            "no key left in the stage",
        )

        # The next build, a release, leaves nothing to serve; another dev build, a new path.
        code, out, err = self.build()
        self.assertEqual(code, 0, err)
        self.assertFalse(os.path.exists(serve))
        self.build("--dev")
        self.assertNotIn(token, os.listdir(serve))

    def test_serve_works_for_a_release_build_too(self):
        code, out, err = self.build("--serve")
        self.assertEqual(code, 0, err)
        self.assertRegex(out, r"at the URL path /[0-9a-f]{32}/%s\.c4z\n" % DRIVER)
        self.assertNotIn("common/devloop.lua", self.names())


class DevKeyScanTest(unittest.TestCase):
    """.gitleaks.toml's rules for the dev key, against fake keys in the form tools/build.sh --dev writes."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(ROOT, ".gitleaks.toml"), "rb") as f:
            rules = {rule["id"]: rule for rule in tomllib.load(f)["rules"]}
        cls.content = rules["dev-key"]
        cls.path = rules["dev-key-file"]

    def key_file_text(self):
        """What build.sh writes into common/devkey.lua, around a fake key made here."""
        return 'return "%s"\n' % secrets.token_hex(32)

    def test_the_content_rule_matches_the_key_files_form(self):
        pattern = re.compile(self.content["regex"])
        self.assertTrue(pattern.search(self.key_file_text()))
        for text in ("return '%s'" % secrets.token_hex(32), 'return("%s")' % secrets.token_hex(32)):
            self.assertTrue(pattern.search(text), text)
        for text in (
            'local mac = "%s"' % secrets.token_hex(32),  # a test vector, not a key file
            'return "%s"' % secrets.token_hex(31),
            "return devloop",
        ):
            self.assertFalse(pattern.search(text), text)
        self.assertIn("return", self.content["keywords"])

    def test_the_path_rule_matches_files_named_after_the_key(self):
        pattern = re.compile(self.path["path"])
        for path in ("src/common/devkey.lua", "tests/devkey.lua", "docs/DevKey.lua.bak", "devkey"):
            self.assertTrue(pattern.search(path), path)
        for path in ("src/common/device.lua", "src/x/www/images/devices_sm/x.png", "docs/devkey-notes/a.md"):
            self.assertFalse(pattern.search(path), path)

    @unittest.skipUnless(shutil.which("gitleaks"), "gitleaks is not installed (tools/setup-checks.sh)")
    def test_gitleaks_finds_a_fake_key_and_nothing_in_clean_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            caught = os.path.join(tmp, "caught")
            for rel, text in (
                ("src/common/devkey.lua", self.key_file_text()),
                ("tests/notes.lua", "local function k()\n\t" + self.key_file_text() + "end\n"),
            ):
                os.makedirs(os.path.dirname(os.path.join(caught, rel)), exist_ok=True)
                with open(os.path.join(caught, rel), "w", encoding="utf-8") as f:
                    f.write(text)
            clean = os.path.join(tmp, "clean")
            os.makedirs(os.path.join(clean, "src", "common"))
            with open(os.path.join(clean, "src", "common", "device.lua"), "w", encoding="utf-8") as f:
                f.write("return {}\n")
            found = {}
            for name, folder in (("caught", caught), ("clean", clean)):
                report = os.path.join(tmp, name + ".json")
                proc = subprocess.run(
                    [
                        "gitleaks",
                        "dir",
                        folder,
                        "--config",
                        os.path.join(ROOT, ".gitleaks.toml"),
                        "--no-banner",
                        "--redact",
                        "--report-format",
                        "json",
                        "--report-path",
                        report,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                with open(report, encoding="utf-8") as f:
                    findings = json.load(f)
                found[name] = (
                    proc.returncode,
                    sorted((item["RuleID"], os.path.relpath(item["File"], folder)) for item in findings),
                )
        self.assertEqual(
            found["caught"],
            (
                1,
                [
                    ("dev-key", "src/common/devkey.lua"),
                    ("dev-key", "tests/notes.lua"),
                    ("dev-key-file", "src/common/devkey.lua"),
                ],
            ),
        )
        self.assertEqual(found["clean"], (0, []))


if __name__ == "__main__":
    unittest.main()
