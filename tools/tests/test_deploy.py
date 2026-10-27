"""Unit tests for tools/deploy.py: no network, gh replaced by FakeGh.

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import base64
import contextlib
import glob
import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import deploy  # noqa: E402

REPO = "octo/fan"
COMMIT = "a" * 40
OTHER_COMMIT = "c" * 40
AT = "2026-11-02T21:04:00-05:00"
APPROVAL = "The owner's standing approval covers this install: act without asking again."
REBOOT = "the devices run the new code only after the owner reboots the controller from System Manager"
FAN = "modernforms_fan.c4z"
# A second driver, invented for the tests: nothing in deploy.py counts the packages.
LIGHT = "modernforms_light.c4z"
# Release v1.0, build 42: the one driver of today.
BUILD = 42
PACKAGE_BYTES = {FAN: b"fan package bytes"}
PACKAGES = sorted(PACKAGE_BYTES)
# v1.0 with two drivers (DeployCase.use_two_packages), for what one package cannot show: one of
# several tampered with, unattested or verified.
TWO_PACKAGE_BYTES = {FAN: b"fan package bytes of a two-driver release", LIGHT: b"light package bytes"}
TWO_DRIVERS = "modernforms_fan modernforms_light"
# A prerelease that adds the second driver: the package list is the manifest's.
BETA_TAG = "v1.1-beta.1"
BETA_BUILD = 57
BETA_COMMIT = "b" * 40
BETA_PACKAGE_BYTES = {FAN: b"beta fan package bytes", LIGHT: b"beta light package bytes"}
BETA_DRIVERS = TWO_DRIVERS
# Release and prerelease tags (docs/prerelease-design.md).
GOOD_TAGS = ("v1.0", "v1.1", "v0.9", "v12.34", "v1.1-beta.1", "v1.1-beta.9", "v1.1-beta.10", "v2.0-beta.123")
BAD_TAGS = (
    "1.0",
    "v1",
    "v1.0.1",
    "v1.0-rc1",
    "v1.1-rc.1",
    "v1.1-alpha.1",
    "v1.1-beta",
    "v1.1-beta.",
    "v1.1-beta.0",
    "v1.1-beta.01",
    "v1.1-Beta.1",
    "v1.1-beta.1.1",
    "v1.1beta1",
    "v1.1-beta-1",
    "V1.0",
    "vv1.0",
    "v1.0+build.5",
    "v\u0661.\u0660",
    "none",
    "None",
)

# Private data (docs/scaffold-design.md, section 2). The vectors are assembled at run time so that
# the repository's own scan (gitleaks, .gitleaks.toml) does not see them as literals; python3 -B
# keeps them out of __pycache__ as well.
HOUSE_ADDRESS = "10.0." + "1.20"
LAN_ADDRESS = "172.16" + ".5.4"
NEAR_PLACEHOLDER = "10.0.2" + ".99"
REAL_MAC = "a4:cf:12" + ":34:56:78"
REAL_MAC_DASHES = "A4-CF-12" + "-34-56-78"
REAL_CLIENT_ID = "MF_A4CF12" + "345678"
REAL_EMAIL = "someone" + "@" + "isp-mail.net"
REAL_IDENTITY = "us-east-1:" + "1234abcd-12ab-34cd-56ef-1234567890ab"
# The noreply senders deploy.py lets through beyond what .gitleaks.toml allows (so no literals here).
NOREPLY_GITHUB = "noreply" + "@" + "github.com"
NOREPLY_ANTHROPIC = "noreply" + "@" + "anthropic.com"
# The documented placeholders and what else names no device or person: nothing here is refused.
ALLOWED = (
    "fans 10.0.2.151 and 10.0.2.152, controller 10.0.2.10, VMs 192.0.2.7 and 192.0.2.8, padded 010.000.002.151\n"
    "MAC 00:00:5e:00:53:01, 00-00-5E-00-53-FF, 00:00:00:00:00:00, ff:ff:ff:ff:ff:ff\n"
    "client ids MF_00005E005301, mf_00005e0053ff, MF_000000000000, MF_FFFFFFFFFFFF\n"
    "examples 198.51.100.4, 203.0.113.9, 127.0.0.1, 0.0.0.0, 0.10.0.1, 224.0.0.251, 255.255.255.0, 1.2.3.4\n"
    "mail someone@example.com, a@lab.example.org, b@host.test, 12345+octo@users.noreply.github.com, git@github.com\n"
    "noreply " + NOREPLY_GITHUB + " and " + NOREPLY_ANTHROPIC + "\n"
    "identity us-east-1:00000000-0000-0000-0000-000000000000\n"
    # No address to deploy.py, but dotted quads to gitleaks: assembled, as above.
    "five parts " + "3.4.2" + ".597.1, no address " + "300.1" + ".2.3\n"
    "versions OS 3.4.3, Composer Pro 3.4.2, gh 2.103.2; sha256 " + "a" * 64 + ", commit " + "b" * 40 + "\n"
)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tag_object(tag):
    return sha(("tag:" + tag).encode())[:40]


def manifest_for(build=BUILD, tag="v1.0", commit=COMMIT, dev=False, packages=None):
    packages = packages or PACKAGE_BYTES
    return {
        "schema": 1,
        "tag": tag,
        "version": tag[1:] if tag else None,
        "build": build,
        "commit": commit,
        "built_at": "2026-11-02T03:12:45Z",
        "dev": dev,
        "packages": {name: {"sha256": sha(data), "bytes": len(data)} for name, data in packages.items()},
    }


def sums_for(packages=None):
    packages = packages or PACKAGE_BYTES
    return "".join("%s  %s\n" % (sha(data), name) for name, data in packages.items())


def release_assets(manifest=None, with_manifest=True, packages=None):
    packages = packages or PACKAGE_BYTES
    assets = dict(packages)
    assets["SHA256SUMS.txt"] = sums_for(packages).encode()
    if with_manifest:
        assets["manifest.json"] = json.dumps(manifest or manifest_for(packages=packages)).encode()
    return assets


def house_text(**overrides):
    values = {
        "environment": "house",
        "release": "v1.0",
        "build": str(BUILD),
        "drivers": "modernforms_fan",
        "debug_mode": "Off",
    }
    for key, value in overrides.items():
        if value is None:
            values.pop(key, None)
        else:
            values[key] = value
    return "# desired state\n" + "".join("%s: %s\n" % item for item in values.items())


def attestation_for(digest, name=FAN, predicate="https://slsa.dev/provenance/v1"):
    statement = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": name, "digest": {"sha256": digest}}],
        "predicateType": predicate,
        "predicate": {},
    }
    payload = base64.b64encode(json.dumps(statement).encode()).decode()
    envelope = {"payload": payload, "payloadType": "application/vnd.in-toto+json", "signatures": [{"sig": "x"}]}
    return {"attestations": [{"bundle": {"dsseEnvelope": envelope}, "repository_id": 1}]}


def verified_result(repo=REPO, workflow=".github/workflows/release.yml", ref="refs/heads/main"):
    """One entry of what `gh attestation verify --format json` prints (the fields deploy.py reads)."""
    san = "https://github.com/%s/%s@%s" % (repo, workflow, ref)
    return {
        "attestation": {"bundle": {"mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json"}},
        "verificationResult": {
            "mediaType": "application/vnd.dev.sigstore.verificationresult+json;version=0.1",
            "signature": {"certificate": {"subjectAlternativeName": san, "sourceRepositoryRef": ref}},
        },
    }


class FakeGh:
    """Stands in for deploy.run_gh: canned GitHub state, every call recorded.

    Rules it enforces as assertions: only open deploy issues are listed; a closed issue is never
    edited, commented on or closed again; `gh issue reopen` and `gh issue delete` do not exist.
    """

    def __init__(self):
        self.calls = []
        self.repo = REPO
        self.deployments = {}
        self.statuses = {}
        self.assets = {}
        self.tags = {}
        self.commits = {COMMIT, OTHER_COMMIT, BETA_COMMIT}  # the commits GitHub has
        self.annotated = True
        self.attestations = {}
        self.issues = {}
        self.next_id = 500
        self.next_issue = 10
        self.clock = 0
        self.fail_once = None  # (method, path fragment): the next matching api call fails
        self.version = "2.103.2"  # what `gh --version` names
        self.verify_failures = {}  # digest -> gh's stderr when `gh attestation verify` refuses that package
        self.verify_output = {}  # digest -> what `gh attestation verify` prints instead of one good result

    # -- plumbing ---------------------------------------------------------

    def __call__(self, args, input=None):
        args = list(args)
        self.calls.append((args, input))
        if args[0] == "repo":
            return json.dumps({"nameWithOwner": self.repo})
        if args[0] == "--version":
            return "gh version %s (2026-10-23)\nhttps://github.com/cli/cli/releases/tag/v%s\n" % ((self.version,) * 2)
        if args[0] == "attestation":
            return self.attestation_verify(args)
        if args[0] == "api":
            return self.api(args, input)
        if args[0] == "release":
            return self.release_download(args)
        if args[0] == "issue":
            return self.issue(args, input)
        raise AssertionError("unexpected gh call %r" % (args,))

    def calls_matching(self, *prefix):
        return [(a, i) for a, i in self.calls if a[: len(prefix)] == list(prefix)]

    def api_calls(self, method, fragment):
        found = []
        for args, input in self.calls:
            if args[0] != "api":
                continue
            m = args[args.index("-X") + 1] if "-X" in args else "GET"
            path = [a for a in args[1:] if not a.startswith("-") and a not in ("-",)]
            path = [p for p in path if p != m][-1]
            if m == method and fragment in path:
                found.append((path, json.loads(input) if input else None))
        return found

    def _not_found(self, args):
        raise deploy.GhError(args, 1, '{"message":"Not Found","status":"404"}', "gh: Not Found (HTTP 404)")

    def _stamp(self):
        self.clock += 1
        return "2026-11-02T%02d:%02d:00Z" % divmod(self.clock, 60)

    def add_deployment(self, tag, build, states, recorded=False):
        """A deployment with the given status states in order (the last is the latest)."""
        self.next_id += 1
        dep = {
            "id": self.next_id,
            "url": "https://api.github.com/repos/%s/deployments/%d" % (self.repo, self.next_id),
            "ref": tag,
            "environment": "house",
            "description": "Build %d (%s) to the house" % (build, tag),
            "payload": {"tag": tag, "build": build, "commit": COMMIT, "packages": {}, "note": "", "recorded": recorded},
            "created_at": self._stamp(),
        }
        self.deployments[dep["id"]] = dep
        self.statuses[dep["id"]] = []
        for state in states:
            self.statuses[dep["id"]].append(
                {
                    "id": len(self.statuses[dep["id"]]) + 1,
                    "state": state,
                    "description": state,
                    "created_at": self._stamp(),
                }
            )
        return dep

    def add_issue(self, title, state="open"):
        self.next_issue += 1
        issue = {
            "number": self.next_issue,
            "title": title,
            "body": "",
            "state": state,
            "comments": [],
            "url": "https://github.com/%s/issues/%d" % (self.repo, self.next_issue),
        }
        self.issues[issue["number"]] = issue
        return issue

    # -- gh api -------------------------------------------------------------

    def api(self, args, input):
        method, path = "GET", None
        rest = args[1:]
        i = 0
        while i < len(rest):
            if rest[i] == "-X":
                method = rest[i + 1]
                i += 2
            elif rest[i] == "--input":
                i += 2
            else:
                path = rest[i]
                i += 1
        body = json.loads(input) if input is not None else None
        if self.fail_once and self.fail_once[0] == method and self.fail_once[1] in path:
            self.fail_once = None
            raise deploy.GhError(args, 1, "", "gh: Validation Failed (HTTP 422)")
        base, _, query = path.partition("?")
        parts = base.split("/")
        assert parts[0] == "repos" and "/".join(parts[1:3]) == self.repo, path
        tail = parts[3:]
        if tail == ["deployments"] and method == "GET":
            assert "environment=house" in query, query
            return json.dumps(sorted(self.deployments.values(), key=lambda d: d["id"], reverse=True))
        if tail == ["deployments"] and method == "POST":
            ref = body["ref"]
            if ref not in self.tags and ref not in self.commits:
                raise deploy.GhError(args, 1, "", "gh: No ref found for: %s (HTTP 422)" % ref)
            self.next_id += 1
            dep = {
                "id": self.next_id,
                "url": "https://api.github.com/repos/%s/deployments/%d" % (self.repo, self.next_id),
                "ref": ref,
                "environment": body["environment"],
                "description": body["description"],
                "payload": body.get("payload"),
                "created_at": self._stamp(),
            }
            self.deployments[dep["id"]] = dep
            self.statuses[dep["id"]] = []
            return json.dumps(dep)
        if len(tail) == 2 and tail[0] == "deployments" and method == "GET":
            dep = self.deployments.get(int(tail[1]))
            if dep is None:
                self._not_found(args)
            return json.dumps(dep)
        if len(tail) == 3 and tail[0] == "deployments" and tail[2] == "statuses":
            dep_id = int(tail[1])
            if dep_id not in self.deployments:
                self._not_found(args)
            if method == "GET":
                return json.dumps(sorted(self.statuses[dep_id], key=lambda s: s["id"], reverse=True))
            assert method == "POST"
            assert len(body["description"]) <= 140, body["description"]
            status = {
                "id": len(self.statuses[dep_id]) + 1,
                "state": body["state"],
                "description": body["description"],
                "created_at": self._stamp(),
            }
            self.statuses[dep_id].append(status)
            return json.dumps(status)
        if tail[:3] == ["git", "ref", "tags"]:
            tag = tail[3]
            if tag not in self.tags:
                self._not_found(args)
            if self.annotated:
                return json.dumps({"ref": "refs/tags/" + tag, "object": {"type": "tag", "sha": tag_object(tag)}})
            return json.dumps({"ref": "refs/tags/" + tag, "object": {"type": "commit", "sha": self.tags[tag]}})
        if tail[:2] == ["git", "tags"]:
            for tag, commit in self.tags.items():
                if tag_object(tag) == tail[2]:
                    return json.dumps({"tag": tag, "sha": tail[2], "object": {"type": "commit", "sha": commit}})
            self._not_found(args)
        if len(tail) == 2 and tail[0] == "commits" and method == "GET":
            if tail[1] not in self.commits:
                # What GitHub answers for a well-formed sha it does not have.
                raise deploy.GhError(args, 1, "", "gh: No commit found for SHA: %s (HTTP 422)" % tail[1])
            return json.dumps({"sha": tail[1]})
        if tail[0] == "attestations":
            digest = tail[1].split(":", 1)[1]
            if digest not in self.attestations:
                self._not_found(args)
            return json.dumps(self.attestations[digest])
        self._not_found(args)

    # -- gh attestation verify ----------------------------------------------

    def attestation_verify(self, args):
        """gh attestation verify FILE --repo R --signer-workflow R/.github/workflows/release.yml --format json:
        the file's digest decides the answer, as on GitHub."""
        assert args[1] == "verify", args
        assert args[args.index("--repo") + 1] == self.repo, args
        assert args[args.index("--signer-workflow") + 1] == self.repo + "/.github/workflows/release.yml", args
        assert args[args.index("--format") + 1] == "json", args
        with open(args[2], "rb") as handle:
            digest = sha(handle.read())
        if digest in self.verify_failures:
            raise deploy.GhError(args, 1, "", self.verify_failures[digest])
        if digest not in self.attestations:
            raise deploy.GhError(args, 1, "", "✗ No attestations found for subject sha256:%s" % digest)
        if digest in self.verify_output:
            return self.verify_output[digest]
        return json.dumps([verified_result(self.repo)]) + "\n"

    # -- gh release download ----------------------------------------------

    def release_download(self, args):
        tag = args[2]
        directory = args[args.index("--dir") + 1]
        patterns = [args[i + 1] for i, a in enumerate(args) if a == "--pattern"]
        assert "--clobber" in args and args[args.index("--repo") + 1] == self.repo
        if tag not in self.assets:
            raise deploy.GhError(args, 1, "", "release not found")
        matched = [p for p in patterns if p in self.assets[tag]]
        if not matched:
            raise deploy.GhError(args, 1, "", "no assets match the file pattern")
        for name in matched:
            with open(os.path.join(directory, name), "wb") as handle:
                handle.write(self.assets[tag][name])
        return ""

    # -- gh issue -----------------------------------------------------------

    def issue(self, args, input):
        verb = args[1]
        if verb == "list":
            assert args[args.index("--state") + 1] == "open", "only open issues may be listed: %r" % (args,)
            assert args[args.index("--label") + 1] == "deploy"
            listed = [
                {"number": n, "title": i["title"], "url": i["url"]}
                for n, i in sorted(self.issues.items())
                if i["state"] == "open"
            ]
            return json.dumps(listed)
        if verb == "create":
            assert args[args.index("--label") + 1] == "deploy"
            issue = self.add_issue(args[args.index("--title") + 1])
            issue["body"] = input
            return issue["url"] + "\n"
        number = int(args[2])
        issue = self.issues[number]
        assert issue["state"] == "open", "a closed issue was touched: %r" % (args,)
        if verb == "edit":
            issue["title"] = args[args.index("--title") + 1]
            issue["body"] = input
            return ""
        if verb == "comment":
            issue["comments"].append(input)
            return ""
        if verb == "close":
            issue["state"] = "closed"
            issue["comments"].append(args[args.index("--comment") + 1])
            return ""
        raise AssertionError("gh issue %s is never used" % verb)


class DeployCase(unittest.TestCase):
    """A fake repository with release v1.0 (build 42, one package, attested) and a valid house file
    for build 42."""

    def setUp(self):
        self.gh = FakeGh()
        self.gh.tags["v1.0"] = COMMIT
        self.gh.assets["v1.0"] = release_assets()
        for name, data in PACKAGE_BYTES.items():
            self.gh.attestations[sha(data)] = attestation_for(sha(data), name=name)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.house = os.path.join(self.tmp.name, "house.yaml")
        self.write_house()
        self._saved = (deploy.run_gh, deploy.RELEASE_DIR, deploy.render_brief)
        deploy.run_gh = self.gh
        deploy.RELEASE_DIR = os.path.join(self.tmp.name, "release")
        self.addCleanup(self.restore)

    def restore(self):
        deploy.run_gh, deploy.RELEASE_DIR, deploy.render_brief = self._saved

    def write_house(self, **overrides):
        with open(self.house, "w", encoding="utf-8") as handle:
            handle.write(house_text(**overrides))

    def write_no_release(self):
        """deploy/house.yaml in the start state: release: none, build: none."""
        self.write_house(release="none", build="none")

    def use_two_packages(self):
        """Release v1.0 carries two drivers (still build 42), and deploy/house.yaml names both."""
        self.gh.assets["v1.0"] = release_assets(packages=TWO_PACKAGE_BYTES)
        for name, data in TWO_PACKAGE_BYTES.items():
            self.gh.attestations[sha(data)] = attestation_for(sha(data), name=name)
        self.write_house(drivers=TWO_DRIVERS)

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = deploy.main(list(argv) + ["--file", self.house])
        return code, out.getvalue(), err.getvalue()

    def release_file(self, name):
        return os.path.join(deploy.RELEASE_DIR, "v1.0", name)

    def read_brief(self):
        with open(self.release_file("BRIEF.md"), encoding="utf-8") as handle:
            return handle.read()


# ---------------------------------------------------------------------------
# deploy/house.yaml
# ---------------------------------------------------------------------------


class ParseHouseTest(unittest.TestCase):
    def test_contract_sample(self):
        """docs/scaffold-design.md, section 5: the start state."""
        text = (
            "environment: house\n"
            "release: none            # no build of these drivers is installed yet (the house runs the stock WAC "
            "driver)\n"
            "build: none\n"
            "drivers: modernforms_fan\n"
            "debug_mode: Off\n"
        )
        self.assertEqual(
            deploy.parse_house(text),
            {
                "environment": "house",
                "release": "none",
                "build": "none",
                "drivers": "modernforms_fan",
                "debug_mode": "Off",
            },
        )
        self.assertEqual(deploy.validate_house(deploy.parse_house(text)), [])

    def test_a_release_sample(self):
        text = (
            "# Desired state of the house installation.\n"
            "environment: house\n"
            "release: v1.0        # the GitHub release whose assets are installed\n"
            "build: 42           # the build number its packages carry\n"
            "drivers: modernforms_fan\n"
            "\n"
            'debug_mode: "Off"\n'
        )
        values = deploy.parse_house(text)
        self.assertEqual((values["release"], values["build"], values["debug_mode"]), ("v1.0", "42", "Off"))
        self.assertEqual(deploy.validate_house(values), [])

    def test_quotes_and_url_values(self):
        values = deploy.parse_house("a: 'x y'\nb: http://example.test/path#frag\nc: v # note\n")
        self.assertEqual(values, {"a": "x y", "b": "http://example.test/path#frag", "c": "v"})

    def test_line_without_colon(self):
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.parse_house("environment: house\nbuild 42\n")
        self.assertIn("line 2", str(ctx.exception))

    def test_repeated_key(self):
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.parse_house("build: 1\nbuild: 2\n")
        self.assertIn("repeats", str(ctx.exception))

    def test_committed_house_file_is_valid(self):
        house = deploy.load_house(deploy.HOUSE_FILE)
        self.assertEqual(house["environment"], "house")
        # A stable tag, a prerelease (docs/prerelease-design.md) or none, the start state.
        if house["release"] == "none":
            self.assertEqual(house["build"], "none")
        else:
            self.assertRegex(house["release"], deploy.TAG_RE)
            self.assertGreater(int(house["build"]), 0)


class ValidateHouseTest(unittest.TestCase):
    def problems(self, **overrides):
        return deploy.validate_house(deploy.parse_house(house_text(**overrides)))

    def test_valid(self):
        self.assertEqual(self.problems(), [])

    def test_none_is_the_start_state(self):
        self.assertEqual(self.problems(release="none", build="none"), [])
        self.assertEqual(self.problems(release="none", build="none", drivers=TWO_DRIVERS), [])

    def test_none_goes_with_none(self):
        self.assertEqual(
            self.problems(release="none"),
            ["build must be none while release is none (no release, so no build), not '42'"],
        )
        self.assertEqual(
            self.problems(build="none"),
            [
                "build must be a positive integer, the release's build number, not 'none': "
                "none goes with release: none only"
            ],
        )
        for release, build in (("None", "none"), ("NONE", "none"), ("none", "None"), ("none", "")):
            with self.subTest(release=release, build=build):
                self.assertTrue(self.problems(release=release, build=build))

    def test_every_failure_names_its_key(self):
        cases = {
            "environment": ["prod", "House"],
            "release": ["1.0", "v1", "v1.0.1", "v1.0-rc1", "v1.1-beta.0", "v1.1-beta", "v1.1-rc.1", "None", "NONE", ""],
            "build": ["0", "-3", "abc", "42.0", "", "none", "None", "\u0664\u0662"],
            # Which drivers is the release's question (validate --online, start); offline only
            # their form: driver names, each once.
            "drivers": [
                "",
                "modernforms_fan modernforms_fan",
                "modernforms_fan.c4z",
                "modernforms_fan ../modernforms_light",
                "-modernforms_fan",
            ],
            "debug_mode": ["On", "off", ""],
        }
        for key, values in cases.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    found = self.problems(**{key: value})
                    self.assertTrue(found, "%s=%r should fail" % (key, value))
                    self.assertTrue(any(key in p for p in found), found)

    def test_missing_and_unknown_keys(self):
        self.assertIn("missing key build", self.problems(build=None))
        self.assertIn("missing key debug_mode", self.problems(debug_mode=None))
        self.assertIn("unknown key colour", self.problems(colour="blue"))
        # The Hue project's bridge settings are not this file's.
        self.assertIn("unknown key stream_timeout_s", self.problems(stream_timeout_s="3600"))

    def test_load_house_reports_every_problem(self):
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as handle:
            handle.write(house_text(build="x", debug_mode="On"))
        self.addCleanup(os.unlink, handle.name)
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.load_house(handle.name)
        self.assertIn("build", str(ctx.exception))
        self.assertIn("debug_mode", str(ctx.exception))

    def test_read_back_properties_are_driver_xml_properties(self):
        """The brief asks for Driver Version and Debug Mode on every device, and validate takes
        debug_mode Off only: every driver declares both, Debug Mode as a LIST with the item Off."""
        paths = sorted(glob.glob(os.path.join(deploy.ROOT, "src", "*", "driver.xml")))
        if not paths:
            self.skipTest("no src/*/driver.xml in this checkout")
        for path in paths:
            with self.subTest(driver=os.path.basename(os.path.dirname(path))):
                declared = {}
                for prop in ET.parse(path).iter("property"):
                    declared[(prop.findtext("name") or "").strip()] = prop
                self.assertIn(deploy.VERSION_PROPERTY, declared)
                self.assertIn(deploy.DEBUG_PROPERTY, declared)
                debug = declared[deploy.DEBUG_PROPERTY]
                self.assertEqual("LIST", (debug.findtext("type") or "").strip())
                self.assertIn("Off", [(item.text or "").strip() for item in debug.iter("item")])


# ---------------------------------------------------------------------------
# Package and manifest verification
# ---------------------------------------------------------------------------


class VerificationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name

    def write_release(self, packages=None, sums=None, manifest=None):
        packages = packages or PACKAGE_BYTES
        for name, data in packages.items():
            with open(os.path.join(self.dir, name), "wb") as handle:
                handle.write(data)
        with open(os.path.join(self.dir, "SHA256SUMS.txt"), "w") as handle:
            handle.write(sums if sums is not None else sums_for(packages))
        manifest = manifest or manifest_for(packages=packages)
        with open(os.path.join(self.dir, "manifest.json"), "w") as handle:
            json.dump(manifest, handle)
        return manifest

    def test_all_good(self):
        manifest = self.write_release()
        hashes = deploy.verify_packages(self.dir, deploy.read_manifest(os.path.join(self.dir, "manifest.json")))
        self.assertEqual(hashes, {name: sha(data) for name, data in PACKAGE_BYTES.items()})
        deploy.check_manifest(manifest, "v1.0", BUILD, COMMIT)

    def test_tampered_package(self):
        manifest = self.write_release(packages=TWO_PACKAGE_BYTES)
        with open(os.path.join(self.dir, LIGHT), "wb") as handle:
            handle.write(b"something else")
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.verify_packages(self.dir, manifest)
        text = str(ctx.exception)
        self.assertIn(LIGHT, text)
        self.assertIn("SHA256SUMS.txt", text)
        self.assertIn("manifest.json", text)
        self.assertNotIn(FAN, text)

    def test_missing_package(self):
        manifest = self.write_release()
        os.unlink(os.path.join(self.dir, FAN))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.verify_packages(self.dir, manifest)
        self.assertIn("%s is missing" % FAN, str(ctx.exception))

    def test_sums_file_lacks_a_package(self):
        packages = TWO_PACKAGE_BYTES
        manifest = self.write_release(packages=packages, sums="%s  %s\n" % (sha(packages[FAN]), FAN))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.verify_packages(self.dir, manifest)
        self.assertIn("does not list %s" % LIGHT, str(ctx.exception))

    def test_manifest_bytes_differ(self):
        manifest = manifest_for()
        manifest["packages"][FAN]["bytes"] += 1
        self.write_release(manifest=manifest)
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.verify_packages(self.dir, manifest)
        self.assertIn("bytes", str(ctx.exception))

    def test_parse_sums_accepts_binary_marker(self):
        with open(os.path.join(self.dir, "SHA256SUMS.txt"), "w") as handle:
            handle.write("%s *%s\n%s  %s\n" % ("A" * 64, FAN, "b" * 64, LIGHT))
        self.assertEqual(
            deploy.parse_sums(os.path.join(self.dir, "SHA256SUMS.txt")),
            {FAN: "a" * 64, LIGHT: "b" * 64},
        )

    def test_check_manifest_failures(self):
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_manifest(manifest_for(build=BUILD), "v1.0", 40, COMMIT)
        self.assertIn("carries build 42", str(ctx.exception))
        self.assertIn("deploy/house.yaml says build 40", str(ctx.exception))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_manifest(manifest_for(), "v1.0", BUILD, OTHER_COMMIT)
        self.assertIn("commit", str(ctx.exception))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_manifest(manifest_for(dev=True), "v1.0", BUILD, COMMIT)
        self.assertIn("dev", str(ctx.exception))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_manifest(manifest_for(tag="v1.1"), "v1.0", BUILD, COMMIT)
        self.assertIn("tag", str(ctx.exception))
        deploy.check_manifest(manifest_for(tag=None), "v1.0", BUILD, COMMIT)  # a local build names no tag

    def test_read_manifest_shape(self):
        for broken in (
            {"schema": 2},
            ["not", "an", "object"],
            {"schema": 1, "build": "42", "commit": COMMIT, "packages": {}},
            {"schema": 1, "build": 42, "commit": "short", "packages": {}},
            {"schema": 1, "build": 42, "commit": COMMIT, "packages": {FAN: {"sha256": "zz"}}},
        ):
            with self.subTest(broken=broken):
                path = os.path.join(self.dir, "manifest.json")
                with open(path, "w") as handle:
                    json.dump(broken, handle)
                with self.assertRaises(deploy.DeployError):
                    deploy.read_manifest(path)

    def test_read_manifest_refuses_names_that_are_not_packages(self):
        good = {"sha256": "a" * 64, "bytes": 1}
        path = os.path.join(self.dir, "manifest.json")
        for packages in (
            {},
            {"../modernforms_fan.c4z": good},
            {"sub/modernforms_fan.c4z": good},
            {"modernforms_fan.zip": good},
            {".c4z": good},
            {"-modernforms_fan.c4z": good},
            {"modernforms fan.c4z": good},
        ):
            with self.subTest(packages=packages):
                with open(path, "w") as handle:
                    json.dump({"schema": 1, "build": BUILD, "commit": COMMIT, "packages": packages}, handle)
                with self.assertRaises(deploy.DeployError) as ctx:
                    deploy.read_manifest(path)
                self.assertIn("manifest.json: ", str(ctx.exception))

    def test_the_package_list_is_the_manifests(self):
        """One package as well as two (docs/prerelease-design.md): nothing counts them."""
        for packages in (PACKAGE_BYTES, TWO_PACKAGE_BYTES):
            with self.subTest(count=len(packages)):
                self.write_release(packages=packages)
                manifest = deploy.read_manifest(os.path.join(self.dir, "manifest.json"))
                self.assertEqual(deploy.manifest_packages(manifest), sorted(packages))
                hashes = deploy.verify_packages(self.dir, manifest)
                self.assertEqual(hashes, {name: sha(data) for name, data in packages.items()})

    def test_sums_file_lists_a_package_the_manifest_does_not(self):
        manifest = self.write_release(sums=sums_for() + "%s  modernforms_extra.c4z\n" % ("e" * 64))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.verify_packages(self.dir, manifest)
        self.assertIn("SHA256SUMS.txt lists modernforms_extra.c4z, which manifest.json does not", str(ctx.exception))

    def test_check_drivers(self):
        house = deploy.parse_house(house_text(drivers="modernforms_light modernforms_fan"))
        deploy.check_drivers(house, manifest_for(packages=TWO_PACKAGE_BYTES), "v1.0")  # the order does not matter
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_drivers(deploy.parse_house(house_text()), manifest_for(packages=BETA_PACKAGE_BYTES), BETA_TAG)
        self.assertEqual(
            str(ctx.exception),
            "deploy/house.yaml names the drivers modernforms_fan, but the release v1.1-beta.1 carries "
            "modernforms_fan.c4z, modernforms_light.c4z (manifest.json): drivers: must name exactly the release's "
            "packages",
        )


# ---------------------------------------------------------------------------
# Attestations, tags and private data
# ---------------------------------------------------------------------------


class GitHubReadsTest(DeployCase):
    def test_attestation_subject_matches(self):
        digest = sha(PACKAGE_BYTES[FAN])
        found = deploy.attestation_check(REPO, FAN, digest)
        self.assertEqual(found, {"count": 1, "predicate_types": ["https://slsa.dev/provenance/v1"]})

    def test_attestation_subject_mismatch(self):
        digest = sha(PACKAGE_BYTES[FAN])
        self.gh.attestations[digest] = attestation_for("f" * 64)
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.attestation_check(REPO, FAN, digest)
        self.assertIn("none names its digest", str(ctx.exception))

    def test_attestation_absent(self):
        self.assertIsNone(deploy.attestation_check(REPO, "x.c4z", "0" * 64))  # 404
        self.gh.attestations["1" * 64] = {"attestations": []}
        self.assertIsNone(deploy.attestation_check(REPO, "x.c4z", "1" * 64))

    def test_attestation_without_payload(self):
        self.gh.attestations["2" * 64] = {"attestations": [{"bundle": {"dsseEnvelope": {}}}]}
        with self.assertRaises(deploy.DeployError):
            deploy.attestation_check(REPO, "x.c4z", "2" * 64)

    def test_gh_version(self):
        self.assertEqual(deploy.gh_version(), (2, 103, 2))
        self.gh.version = "2.46.0"
        self.assertEqual(deploy.gh_version(), (2, 46, 0))
        deploy.run_gh = lambda args, input=None: "gh version DEV\n"
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.gh_version()
        self.assertIn("cannot read gh's version", str(ctx.exception))

    def test_tag_commit_annotated_and_lightweight(self):
        self.assertEqual(deploy.tag_commit(REPO, "v1.0"), COMMIT)
        self.assertTrue(self.gh.api_calls("GET", "git/tags/" + tag_object("v1.0")))
        self.gh.annotated = False
        self.assertEqual(deploy.tag_commit(REPO, "v1.0"), COMMIT)
        with self.assertRaises(deploy.DeployError):
            deploy.tag_commit(REPO, "v9.9")

    def test_check_commit(self):
        deploy.check_commit(REPO, OTHER_COMMIT)
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_commit(REPO, "d" * 40)
        self.assertIn("no commit %s in octo/fan" % ("d" * 40), str(ctx.exception))

    def test_fetch_manifest(self):
        self.assertEqual(deploy.fetch_manifest(REPO, "v1.0")["build"], BUILD)
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        self.assertIsNone(deploy.fetch_manifest(REPO, "v1.0"))
        with self.assertRaises(deploy.GhError):
            deploy.fetch_manifest(REPO, "v9.9")

    def test_clip(self):
        self.assertEqual(deploy.clip("a  b\nc"), "a b c")
        self.assertEqual(len(deploy.clip("x" * 500)), 140)
        self.assertTrue(deploy.clip("x" * 500).endswith("…"))

    def test_ref_name(self):
        self.assertEqual(deploy.ref_name("v1.0"), "v1.0")
        self.assertEqual(deploy.ref_name(OTHER_COMMIT), "commit ccccccc")


class PrivateDataTest(unittest.TestCase):
    """The rules tools/gh-discussion.py applies (docs/scaffold-design.md, section 2), on notes and briefs."""

    IPV4 = "an IPv4 address that is neither a documented placeholder nor a textbook example"
    MAC = "a MAC address outside the documentation range 00:00:5e:00:53:xx"
    CLIENT_ID = "a Modern Forms client id of a real fan (the placeholder is MF_00005E005301)"

    def test_placeholders_and_what_names_no_device_or_person_pass(self):
        self.assertEqual(deploy.private_findings(ALLOWED), [])

    def test_each_rule_refuses_its_kind(self):
        for text, meaning in (
            ("the fan at " + HOUSE_ADDRESS, "an address in the house subnet 10.0.1.x"),
            ("the house subnet 10.0." + "1.x", "an address in the house subnet 10.0.1.x"),
            ("padded 010.000." + "001.020", "an address in the house subnet 10.0.1.x"),
            ("short form 10.0." + "276", "an address in the house subnet 10.0.1.x"),
            ("a fan at " + LAN_ADDRESS, self.IPV4),
            ("a fan at " + NEAR_PLACEHOLDER + ".", self.IPV4),
            # .gitleaks.toml lets the manual's examples through; a note or a brief never needs them.
            ("a fan at 192.168.1.20", self.IPV4),
            ("a fan at 10.10.10.10", self.IPV4),
            ("MAC " + REAL_MAC, self.MAC),
            ("MAC " + REAL_MAC_DASHES, self.MAC),
            ("client id " + REAL_CLIENT_ID, self.CLIENT_ID),
            ("client id " + REAL_CLIENT_ID.lower(), self.CLIENT_ID),
            ("client id " + REAL_CLIENT_ID + "X", self.CLIENT_ID),
            ("client id MF_00005E0053" + "01AB", self.CLIENT_ID),  # the placeholder's digits and two more
            ("account " + REAL_EMAIL, "an e-mail address outside the documentation domains"),
            ("identity " + REAL_IDENTITY, "a cloud identity id (region:UUID) of a real account"),
        ):
            with self.subTest(text=text):
                self.assertEqual(deploy.private_findings("a first line\n" + text), [meaning + " (line 2)"])
                with self.assertRaises(deploy.DeployError) as ctx:
                    deploy.refuse_private(ALLOWED + text, "--note")
                self.assertIn("--note holds private data: " + meaning, str(ctx.exception))

    def test_one_reason_per_rule_and_never_the_data(self):
        text = "\n".join(
            ("fans at " + LAN_ADDRESS + " and " + NEAR_PLACEHOLDER, "MAC " + REAL_MAC, "id " + REAL_CLIENT_ID)
        )
        found = deploy.private_findings(text)
        self.assertEqual(found, [self.IPV4 + " (line 1)", self.MAC + " (line 2)", self.CLIENT_ID + " (line 3)"])
        for secret in (LAN_ADDRESS, NEAR_PLACEHOLDER, REAL_MAC, REAL_CLIENT_ID):
            self.assertNotIn(secret, " ".join(found))
        # An address in the house subnet is named once, by its own rule.
        self.assertEqual(deploy.private_findings(HOUSE_ADDRESS), ["an address in the house subnet 10.0.1.x (line 1)"])

    def test_the_same_rules_as_gh_discussion(self):
        """tools/gh-discussion.py and deploy.py refuse the same text (docs/scaffold-design.md,
        section 2), except the two noreply senders deploy.py lets through as well."""
        path = os.path.join(TOOLS, "gh-discussion.py")
        if not os.path.isfile(path):
            self.skipTest("tools/gh-discussion.py is not in this checkout")
        spec = importlib.util.spec_from_file_location("gh_discussion", path)
        gh_discussion = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gh_discussion)
        self.assertEqual(
            [(pattern.pattern, pattern.flags, meaning) for pattern, meaning, _ in deploy.PRIVATE_PATTERNS],
            [(pattern.pattern, pattern.flags, meaning) for pattern, meaning, _ in gh_discussion.PRIVATE_PATTERNS],
        )
        samples = ALLOWED.replace(NOREPLY_GITHUB, "").replace(NOREPLY_ANTHROPIC, "").splitlines()
        samples += [HOUSE_ADDRESS, LAN_ADDRESS, NEAR_PLACEHOLDER, "192.168.1.20", "10.10.10.10", REAL_MAC]
        samples += [REAL_MAC_DASHES, REAL_CLIENT_ID, "MF_00005E0053" + "01AB", REAL_EMAIL, REAL_IDENTITY]
        rules = zip(deploy.PRIVATE_PATTERNS, gh_discussion.PRIVATE_PATTERNS, strict=True)
        for (pattern, meaning, ours), (_pattern, _meaning, theirs) in rules:
            for sample in samples:
                for match in pattern.finditer(sample):
                    with self.subTest(rule=meaning, found=match.group(0)):
                        self.assertEqual(ours(match), theirs(match))
        for sender in (NOREPLY_GITHUB, NOREPLY_ANTHROPIC):
            self.assertEqual(deploy.private_findings(sender), [])


# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------


class StartTest(DeployCase):
    def test_start_creates_deployment_brief_and_record(self):
        code, out, err = self.run_main("start", "--note", "changes <capabilities>: reboot the controller afterwards")
        self.assertEqual(code, 0, err)
        posts = self.gh.api_calls("POST", "deployments")
        self.assertEqual(len(posts), 2, posts)  # the deployment, then its in_progress status
        path, body = posts[0]
        self.assertEqual(path, "repos/octo/fan/deployments")
        self.assertEqual(body["ref"], "v1.0")
        self.assertEqual(body["environment"], "house")
        self.assertIs(body["auto_merge"], False)
        self.assertEqual(body["required_contexts"], [])
        self.assertIs(body["production_environment"], True)
        self.assertEqual(body["description"], "Build 42 (v1.0) to the house")
        self.assertEqual(body["payload"]["tag"], "v1.0")
        self.assertEqual(body["payload"]["build"], BUILD)
        self.assertEqual(body["payload"]["commit"], COMMIT)
        self.assertEqual(body["payload"]["packages"], {n: sha(d) for n, d in PACKAGE_BYTES.items()})
        self.assertIn("reboot", body["payload"]["note"])
        self.assertEqual(
            posts[1][1], {"state": "in_progress", "description": "Packages verified; install through Composer pending"}
        )

        with open(self.release_file("deployment.json")) as handle:
            record = json.load(handle)
        self.assertEqual((record["id"], record["tag"], record["build"], record["commit"]), (501, "v1.0", BUILD, COMMIT))
        self.assertTrue(record["url"].endswith("/deployments/501"))
        self.assertTrue(record["created"])
        for name in PACKAGES:
            self.assertTrue(os.path.isfile(self.release_file(name)))
        self.assertIn("downloaded 3 files", out)

        lines = out.strip().splitlines()
        self.assertEqual(lines[-2], self.release_file("BRIEF.md"))
        self.assertEqual(lines[-1], record["url"])

        brief = self.read_brief()
        self.assertTrue(brief.startswith("# Install build 42 (v1.0) on the house\n"), brief[:80])
        self.assertIn("https://github.com/octo/fan/releases/download/v1.0/%s" % FAN, brief)
        self.assertIn(sha(PACKAGE_BYTES[FAN]), brief)
        self.assertEqual(brief.count("Invoke-WebRequest"), 1)
        self.assertIn("Get-FileHash", brief)
        self.assertIn(
            "Fetch the release's package (modernforms_fan.c4z) into `C:\\c4-mf\\drivers\\v1.0\\` and check its sha256:",
            brief,
        )
        self.assertIn(
            '1. Driver ▸ "Add or Update Driver or Agent…"; pick `modernforms_fan.c4z` in `C:\\c4-mf\\drivers\\v1.0\\`. '
            "Composer updates every existing device of this driver in place.",
            brief,
        )
        self.assertIn(
            "- Every device's `Driver Version` = 42 (every device of the driver modernforms_fan); name any device "
            "that shows another value.",
            brief,
        )
        self.assertIn("- Every device's `Debug Mode` = Off (deploy/house.yaml); report a device that differs", brief)
        self.assertIn(APPROVAL, brief)
        self.assertIn('If Composer asks "Restart Director?"', brief)
        self.assertIn(REBOOT, brief)
        self.assertIn("Never delete and re-add a device", brief)
        self.assertIn('Note from the coordinator: "changes <capabilities>: reboot the controller afterwards"', brief)
        self.assertIn("--signer-workflow octo/fan/.github/workflows/release.yml", brief)
        self.assertIn("no LAN address, no MAC address and no fan client id", brief)
        self.assertIn("screenshots under C:\\c4-mf\\shots\\", brief)
        for leftover in ("c4-hue", "bridge", "Bridge", "Stream", "hue_"):
            self.assertNotIn(leftover, brief)
        self.assertEqual(deploy.private_findings(brief), [])

    def test_start_refuses_while_house_names_no_release(self):
        self.write_no_release()
        for argv in (("start",), ("start", "--tag", "v1.0"), ("start", "--supersede", "--note", "first install")):
            with self.subTest(argv=argv):
                code, out, err = self.run_main(*argv)
                self.assertEqual(code, 1)
                self.assertIn("deploy/house.yaml names no release (release: none)", err)
                self.assertIn("the desired state leads", err)
        self.assertEqual(self.gh.calls, [])

    def test_start_refuses_while_in_progress(self):
        self.gh.add_deployment("v1.0", 40, ["in_progress"])
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("still in_progress", err)
        self.assertIn("--supersede", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        self.assertEqual(self.gh.calls_matching("release"), [])

    def test_start_refuses_while_a_deployment_has_no_status(self):
        self.gh.add_deployment("v1.0", 40, [])
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("pending", err)

    def test_start_supersedes(self):
        old = self.gh.add_deployment("v1.0", 40, ["in_progress"])
        code, out, err = self.run_main("start", "--supersede")
        self.assertEqual(code, 0, err)
        latest = self.gh.statuses[old["id"]][-1]
        self.assertEqual(latest["state"], "inactive")
        self.assertIn("Superseded", latest["description"])
        self.assertIn("superseded deployment %d" % old["id"], out)
        new_id = max(self.gh.deployments)
        self.assertNotEqual(new_id, old["id"])
        self.assertEqual(self.gh.statuses[new_id][-1]["state"], "in_progress")

    def test_start_fails_without_attestation_unless_flagged(self):
        self.use_two_packages()
        del self.gh.attestations[sha(TWO_PACKAGE_BYTES[LIGHT])]
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("no provenance attestation for %s" % LIGHT, err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        code, out, err = self.run_main("start", "--no-attestation")
        self.assertEqual(code, 0, err)
        self.assertIn("no provenance attestation", err)
        brief = self.read_brief()
        self.assertIn("%s: NO provenance attestation" % LIGHT, brief)
        self.assertIn("%s: provenance verified, signed by" % FAN, brief)
        # The attested package was still verified; the other has nothing to verify.
        verified = [args[2] for args, _ in self.gh.calls_matching("attestation", "verify")]
        self.assertEqual(verified, [self.release_file(FAN)])

    def test_start_verifies_each_package_against_the_release_workflow(self):
        self.use_two_packages()
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)
        names = sorted(TWO_PACKAGE_BYTES)
        calls = self.gh.calls_matching("attestation", "verify")
        self.assertEqual([args[2] for args, _ in calls], [self.release_file(name) for name in names])
        policy = ["--repo", "octo/fan", "--signer-workflow", "octo/fan/.github/workflows/release.yml"]
        for args, _ in calls:
            self.assertEqual(args[3:], policy + ["--format", "json"])
        signer = "https://github.com/octo/fan/.github/workflows/release.yml@refs/heads/main"
        self.assertIn("attestation %s: verified (gh 2.103.2), signed by %s" % (LIGHT, signer), out)
        brief = self.read_brief()
        for name in names:
            self.assertIn("- %s: provenance verified, signed by %s" % (name, signer), brief)
        self.assertIn(
            "Verified on the VM with gh 2.103.2: `gh attestation verify <file> --repo octo/fan --signer-workflow "
            "octo/fan/.github/workflows/release.yml` for each package",
            brief,
        )
        # Two packages: both named, both fetched, both picked at once.
        self.assertIn(
            "Fetch the 2 packages of the release (modernforms_fan.c4z and modernforms_light.c4z) into "
            "`C:\\c4-mf\\drivers\\v1.0\\` and check every sha256:",
            brief,
        )
        self.assertIn("pick both files from `C:\\c4-mf\\drivers\\v1.0\\` at once", brief)
        self.assertIn("(every device of the drivers modernforms_fan and modernforms_light)", brief)
        self.assertEqual(brief.count("Invoke-WebRequest"), 2)

    def test_start_refuses_an_attestation_another_workflow_signed(self):
        digest = sha(PACKAGE_BYTES[FAN])
        self.gh.verify_failures[digest] = (
            "Loaded digest sha256:%s for file://modernforms_fan.c4z\n✗ Verification failed\n"
            'Error: verifying with issuer "sigstore.dev": certificate SAN '
            "https://github.com/octo/fan/.github/workflows/scorecard.yml@refs/heads/main does not match" % digest
        )
        for extra in ((), ("--no-attestation",)):
            with self.subTest(extra=extra):
                code, out, err = self.run_main("start", *extra)
                self.assertEqual(code, 1)
                self.assertIn("%s: gh attestation verify refused it" % FAN, err)
                self.assertIn("the signer must be octo/fan/.github/workflows/release.yml", err)
                self.assertIn("scorecard.yml", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        self.assertFalse(os.path.isfile(self.release_file("BRIEF.md")))

    def test_start_refuses_a_gh_that_cannot_pin_the_signer(self):
        for version in ("2.46.0", "2.101.0"):
            with self.subTest(version=version):
                self.gh.version = version
                code, out, err = self.run_main("start", "--no-attestation")
                self.assertEqual(code, 1)
                self.assertIn("gh %s cannot check who signed the attestations" % version, err)
                self.assertIn("needs gh 2.102.0 or newer", err)
        self.assertEqual(self.gh.calls_matching("attestation"), [])
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        self.gh.version = "2.102.0"
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)

    def test_start_without_any_attestation_verifies_nothing(self):
        self.gh.attestations.clear()
        self.gh.version = "2.46.0"  # too old to verify, and there is nothing to verify
        code, out, err = self.run_main("start", "--no-attestation")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.calls_matching("--version"), [])
        self.assertEqual(self.gh.calls_matching("attestation"), [])
        brief = self.read_brief()
        self.assertEqual(brief.count("NO provenance attestation"), 1)
        self.assertIn("No package carries an attestation, so nothing was verified (--no-attestation).", brief)

    def test_start_refuses_when_gh_verifies_nothing(self):
        digest = sha(PACKAGE_BYTES[FAN])
        for printed, reason in (
            ("[]\n", "reported no verified attestation"),
            ('{"verified": true}', "reported no verified attestation"),
            ("✓ Verification succeeded!", "not JSON"),
        ):
            with self.subTest(printed=printed):
                self.gh.verify_output[digest] = printed
                code, out, err = self.run_main("start")
                self.assertEqual(code, 1)
                self.assertIn("%s: gh attestation verify" % FAN, err)
                self.assertIn(reason, err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_start_checks_the_signer_gh_reports(self):
        """A gh that matched loosely (as 2.51 to 2.101 did) still cannot pass a lookalike signer."""
        digest = sha(PACKAGE_BYTES[FAN])
        for result in (
            verified_result(workflow=".github/workflows/release.yml.bak.yml"),
            verified_result(workflow=".github/workflows/Release.yml"),
            verified_result(workflow=".github/workflows/scorecard.yml"),
            verified_result(repo="octo/fan-fork"),
            {"verificationResult": {"signature": {}}},
            "not an object",
        ):
            with self.subTest(result=result):
                self.gh.verify_output[digest] = json.dumps([verified_result(), result])
                code, out, err = self.run_main("start")
                self.assertEqual(code, 1)
                self.assertIn("%s: a verified attestation names the signer" % FAN, err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        # A release cut from a pushed tag, and the owner's name in another case, are the same signer.
        self.gh.verify_output[digest] = json.dumps(
            [verified_result(ref="refs/tags/v1.0"), verified_result(repo="Octo/Fan")]
        )
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)
        self.assertIn(
            "%s: provenance verified, signed by "
            "https://github.com/Octo/Fan/.github/workflows/release.yml@refs/heads/main, "
            "https://github.com/octo/fan/.github/workflows/release.yml@refs/tags/v1.0" % FAN,
            self.read_brief(),
        )

    def test_start_fails_on_attestation_subject_mismatch(self):
        digest = sha(PACKAGE_BYTES[FAN])
        self.gh.attestations[digest] = attestation_for("f" * 64, name=FAN)
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("none names its digest", err)

    def test_start_needs_the_manifest(self):
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("lacks manifest.json", err)
        self.assertIn("the Release workflow attaches it", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_start_refuses_a_build_that_differs_from_house(self):
        self.write_house(build="40")
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("carries build 42", err)
        self.assertIn("deploy/house.yaml says build 40", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_start_refuses_a_commit_that_is_not_the_tags(self):
        self.gh.tags["v1.0"] = OTHER_COMMIT
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("commit", err)

    def test_start_refuses_a_tampered_package(self):
        self.gh.assets["v1.0"][FAN] = b"not the package"
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn(FAN, err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_start_refuses_a_private_note_before_doing_anything(self):
        for note in (
            "the fan at " + HOUSE_ADDRESS + " answered",
            "Composer shows MAC " + REAL_MAC,
            "the fan " + REAL_CLIENT_ID + " was renamed",
            "the account " + REAL_EMAIL,
        ):
            with self.subTest(note=note):
                code, out, err = self.run_main("start", "--note", note)
                self.assertEqual(code, 1)
                self.assertIn("--note holds private data", err)
        self.assertEqual(self.gh.calls, [])

    def test_start_refuses_a_brief_with_private_data(self):
        deploy.render_brief = lambda *args, **kwargs: "# A brief\n\nThe fan's MAC is %s.\n" % REAL_MAC
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("the brief holds private data: a MAC address outside the documentation range", err)
        self.assertFalse(os.path.isfile(self.release_file("BRIEF.md")))

    def test_start_writes_the_record_before_the_status_can_fail(self):
        self.gh.fail_once = ("POST", "statuses")
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertTrue(os.path.isfile(self.release_file("deployment.json")))
        self.assertFalse(os.path.isfile(self.release_file("BRIEF.md")))
        self.assertEqual(len(self.gh.deployments), 1)

    def test_start_with_bad_tag(self):
        code, out, err = self.run_main("start", "--tag", "1.0")
        self.assertEqual(code, 1)
        self.assertIn("--tag", err)


# ---------------------------------------------------------------------------
# done, failed
# ---------------------------------------------------------------------------


class DoneTest(DeployCase):
    def start(self):
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)
        return max(self.gh.deployments)

    def test_done_records_success_and_closes_the_issue(self):
        issue = self.gh.add_issue("Deploy v1.0 (build 42) to the house")
        dep_id = self.start()
        code, out, err = self.run_main("done", "--devices", "1", "--note", "no Restart Director prompt")
        self.assertEqual(code, 0, err)
        latest = self.gh.statuses[dep_id][-1]
        self.assertEqual(latest["state"], "success")
        self.assertEqual(
            latest["description"],
            "Driver Version 42 on 1 devices, settings as deploy/house.yaml; no Restart Director prompt",
        )
        self.assertEqual(self.gh.issues[issue["number"]]["state"], "closed")
        self.assertEqual(
            self.gh.issues[issue["number"]]["comments"][-1],
            "Build 42 (v1.0) recorded as deployed: https://api.github.com/repos/octo/fan/deployments/%d" % dep_id,
        )
        self.assertIn("in sync: build 42 (v1.0)", out)
        with open(self.release_file("deployment.json")) as handle:
            self.assertEqual(json.load(handle)["result"], "success")

    def test_done_without_devices(self):
        dep_id = self.start()
        code, out, err = self.run_main("done")
        self.assertEqual(code, 0, err)
        self.assertEqual(
            self.gh.statuses[dep_id][-1]["description"],
            "Driver Version 42 on every device, settings as deploy/house.yaml",
        )

    def test_done_refuses_when_the_assets_changed(self):
        dep_id = self.start()
        self.gh.assets["v1.0"]["manifest.json"] = json.dumps(manifest_for(build=43)).encode()
        code, out, err = self.run_main("done", "--devices", "1")
        self.assertEqual(code, 1)
        self.assertIn("now carries build 43", err)
        self.assertEqual(self.gh.statuses[dep_id][-1]["state"], "in_progress")
        other = {n: b"replaced " + d for n, d in PACKAGE_BYTES.items()}
        self.gh.assets["v1.0"]["manifest.json"] = json.dumps(manifest_for(packages=other)).encode()
        code, out, err = self.run_main("done", "--devices", "1")
        self.assertEqual(code, 1)
        self.assertIn("replaced", err)

    def test_done_by_deployment_id(self):
        dep = self.gh.add_deployment("v1.0", BUILD, ["in_progress"])
        code, out, err = self.run_main("done", "--deployment", str(dep["id"]), "--devices", "1")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.statuses[dep["id"]][-1]["state"], "success")

    def test_done_without_a_record(self):
        code, out, err = self.run_main("done")
        self.assertEqual(code, 1)
        self.assertIn("deployment.json", err)
        self.assertIn("--deployment", err)

    def test_done_and_failed_refuse_a_bad_tag(self):
        for argv in (("done", "--tag", "../v1.0"), ("failed", "--tag", "1.0", "--note", "x")):
            with self.subTest(argv=argv):
                code, out, err = self.run_main(*argv)
                self.assertEqual(code, 1)
                self.assertIn("--tag must look like", err)
        self.assertEqual(self.gh.calls, [])

    def test_done_and_failed_while_house_names_no_release(self):
        dep_id = self.start()
        self.write_no_release()
        for argv in (("done",), ("failed", "--note", "Composer refused the file")):
            with self.subTest(argv=argv):
                code, out, err = self.run_main(*argv)
                self.assertEqual(code, 1)
                self.assertIn("deploy/house.yaml names no release (release: none)", err)
                self.assertIn("--deployment ID", err)
        self.assertEqual(self.gh.statuses[dep_id][-1]["state"], "in_progress")
        # With the tag named it records the install: drift, since the desired state names none,
        # and no issue for it.
        code, out, err = self.run_main("done", "--tag", "v1.0", "--devices", "1")
        self.assertEqual(code, 3, err)
        self.assertEqual(self.gh.statuses[dep_id][-1]["state"], "success")
        self.assertIn("drift: deploy/house.yaml names no release, but build 42 (v1.0) is recorded as installed", out)
        self.assertIn("no deploy issue is opened", err)
        self.assertEqual(self.gh.calls_matching("issue"), [])

    def test_failed_records_failure_and_comments(self):
        issue = self.gh.add_issue("Deploy v1.0 (build 42) to the house")
        dep_id = self.start()
        code, out, err = self.run_main("failed", "--note", "Composer refused the file; the house still runs build 40")
        self.assertEqual(code, 0, err)
        latest = self.gh.statuses[dep_id][-1]
        self.assertEqual(latest["state"], "failure")
        self.assertIn("still runs build 40", latest["description"])
        self.assertEqual(self.gh.issues[issue["number"]]["state"], "open")
        self.assertIn("still runs build 40", self.gh.issues[issue["number"]]["comments"][-1])
        code, out, err = self.run_main("status")
        self.assertEqual(code, 3)

    def test_failed_and_done_refuse_a_private_note(self):
        dep_id = self.start()
        before = len(self.gh.calls)
        for argv in (
            ("failed", "--note", "the fan at " + HOUSE_ADDRESS + " did not answer"),
            ("done", "--note", "client id " + REAL_CLIENT_ID),
        ):
            with self.subTest(argv=argv):
                code, out, err = self.run_main(*argv)
                self.assertEqual(code, 1)
                self.assertIn("--note holds private data", err)
        self.assertEqual(len(self.gh.calls), before)
        self.assertEqual(self.gh.statuses[dep_id][-1]["state"], "in_progress")


# ---------------------------------------------------------------------------
# record
# ---------------------------------------------------------------------------


class RecordTest(DeployCase):
    def test_record_with_matching_manifest(self):
        issue = self.gh.add_issue("Deploy v1.0 (build 42) to the house")
        code, out, err = self.run_main(
            "record", "--tag", "v1.0", "--build", "42", "--at", AT, "--note", "installed by hand"
        )
        self.assertEqual(code, 0, err)
        dep = self.gh.deployments[max(self.gh.deployments)]
        self.assertEqual(dep["ref"], "v1.0")
        self.assertIs(dep["payload"]["recorded"], True)
        self.assertEqual(dep["payload"]["installed_at"], AT)
        self.assertEqual(dep["payload"]["build"], BUILD)
        self.assertEqual(dep["payload"]["commit"], COMMIT)
        self.assertEqual(dep["payload"]["packages"], {n: sha(d) for n, d in PACKAGE_BYTES.items()})
        status = self.gh.statuses[dep["id"]][-1]
        self.assertEqual(status["state"], "success")
        self.assertIn("Driver Version 42 installed " + AT, status["description"])
        self.assertEqual(self.gh.issues[issue["number"]]["state"], "closed")

    def test_record_refuses_another_build_than_the_manifest(self):
        code, out, err = self.run_main(
            "record", "--tag", "v1.0", "--build", "40", "--at", AT, "--note", "built on the VM"
        )
        self.assertEqual(code, 1)
        self.assertIn("--no-manifest", err)
        self.assertEqual(self.gh.deployments, {})

    def test_record_with_no_manifest_flag(self):
        self.write_house(build="40")
        code, out, err = self.run_main(
            "record",
            "--tag",
            "v1.0",
            "--build",
            "40",
            "--at",
            AT,
            "--note",
            "built on the VM",
            "--no-manifest",
            "--commit",
            OTHER_COMMIT,
        )
        self.assertEqual(code, 0, err)
        dep = self.gh.deployments[max(self.gh.deployments)]
        self.assertEqual(dep["payload"]["build"], 40)
        self.assertEqual(dep["payload"]["packages"], {})
        self.assertEqual(dep["payload"]["commit"], OTHER_COMMIT)
        self.assertIs(dep["payload"]["recorded"], True)
        self.assertIn("unverified", err)

    def test_record_without_a_manifest_in_the_release(self):
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        code, out, err = self.run_main("record", "--tag", "v1.0", "--build", "40", "--at", AT, "--note", "x")
        self.assertEqual(code, 1)
        self.assertIn("--no-manifest", err)
        code, out, err = self.run_main(
            "record", "--tag", "v1.0", "--build", "40", "--at", AT, "--note", "x", "--no-manifest"
        )
        self.assertEqual(code, 3)  # recorded, but the house file wants 42: drift
        self.assertIsNone(self.gh.deployments[max(self.gh.deployments)]["payload"]["commit"])

    def test_record_a_build_that_no_release_carries(self):
        """Before the first release there is no tag: the deployment names the commit."""
        code, out, err = self.run_main(
            "record",
            *("--build", "17", "--at", AT, "--note", "a --dev build for the dev loop"),
            *("--no-manifest", "--commit", OTHER_COMMIT),
        )
        self.assertEqual(code, 3, err)  # the house file wants v1.0, build 42
        dep = self.gh.deployments[max(self.gh.deployments)]
        self.assertEqual(dep["ref"], OTHER_COMMIT)
        self.assertEqual(dep["description"], "Build 17 (commit ccccccc) to the house")
        self.assertIsNone(dep["payload"]["tag"])
        self.assertEqual((dep["payload"]["build"], dep["payload"]["commit"]), (17, OTHER_COMMIT))
        self.assertEqual(dep["payload"]["packages"], {})
        self.assertIs(dep["payload"]["recorded"], True)
        self.assertEqual(self.gh.statuses[dep["id"]][-1]["state"], "success")
        self.assertIn("recording build 17 of commit ccccccc, which no release carries, unverified", err)
        self.assertIn("observed  commit ccccccc build 17", out)
        self.assertIn("drift: desired build 42 (v1.0), observed build 17 (commit ccccccc)", out)
        self.assertEqual(self.gh.calls_matching("release"), [])
        [issue] = [i for i in self.gh.issues.values() if i["state"] == "open"]
        self.assertEqual(issue["title"], "Deploy v1.0 (build 42) to the house")
        self.assertIn("build **17** (commit ccccccc)", issue["body"])

    def test_record_without_a_tag_needs_no_manifest_and_a_commit(self):
        for extra in ((), ("--no-manifest",), ("--commit", OTHER_COMMIT)):
            with self.subTest(extra=extra):
                code, out, err = self.run_main("record", "--build", "17", "--at", AT, "--note", "x", *extra)
                self.assertEqual(code, 1)
                self.assertIn("record needs --tag", err)
                self.assertIn("--no-manifest and --commit SHA", err)
        self.assertEqual(self.gh.calls, [])

    def test_record_a_commit_github_does_not_have(self):
        code, out, err = self.run_main(
            "record", "--build", "17", "--at", AT, "--note", "x", "--no-manifest", "--commit", "d" * 40
        )
        self.assertEqual(code, 1)
        self.assertIn("no commit %s in octo/fan" % ("d" * 40), err)
        self.assertEqual(self.gh.deployments, {})

    def test_record_while_house_names_no_release(self):
        self.write_no_release()
        code, out, err = self.run_main("record", "--tag", "v1.0", "--build", "42", "--at", AT, "--note", "by hand")
        self.assertEqual(code, 3, err)
        self.assertEqual(self.gh.statuses[max(self.gh.deployments)][-1]["state"], "success")
        self.assertIn("desired   none: no release (deploy/house.yaml, release: none)", out)
        self.assertIn("no deploy issue is opened for this drift", err)
        self.assertEqual(self.gh.calls_matching("issue"), [])

    def test_record_rejects_bad_time_and_unknown_tag(self):
        code, out, err = self.run_main("record", "--tag", "v1.0", "--build", "42", "--at", "yesterday", "--note", "x")
        self.assertEqual(code, 1)
        self.assertIn("--at", err)
        code, out, err = self.run_main(
            "record", "--tag", "v1.0", "--build", "42", "--at", "2026-11-02T21:04:00", "--note", "x"
        )
        self.assertEqual(code, 1)
        self.assertIn("offset", err)
        code, out, err = self.run_main("record", "--tag", "v9.9", "--build", "42", "--at", AT, "--note", "x")
        self.assertEqual(code, 1)
        self.assertIn("no tag v9.9", err)
        self.assertEqual(self.gh.deployments, {})

    def test_record_refuses_a_private_note(self):
        code, out, err = self.run_main(
            "record", "--tag", "v1.0", "--build", "42", "--at", AT, "--note", "installed at " + LAN_ADDRESS
        )
        self.assertEqual(code, 1)
        self.assertIn("--note holds private data: an IPv4 address that is neither a documented placeholder", err)
        self.assertEqual(self.gh.calls, [])


# ---------------------------------------------------------------------------
# status and drift
# ---------------------------------------------------------------------------


class StatusTest(DeployCase):
    def test_no_deployment_is_drift(self):
        code, out, err = self.run_main("status")
        self.assertEqual(code, 3)
        self.assertIn("observed  none: no release installed yet", out)
        self.assertIn("drift:", out)
        self.assertEqual(self.gh.calls_matching("issue"), [])

    def test_agreement(self):
        self.gh.add_deployment("v1.0", BUILD, ["in_progress", "success"])
        code, out, err = self.run_main("status")
        self.assertEqual(code, 0, err)
        self.assertIn("in sync: build 42 (v1.0)", out)

    def test_build_or_tag_differs(self):
        self.gh.add_deployment("v1.0", 40, ["success"])
        self.assertEqual(self.run_main("status")[0], 3)
        self.gh.add_deployment("v1.1", BUILD, ["success"])
        self.assertEqual(self.run_main("status")[0], 3)

    def test_latest_status_counts(self):
        self.gh.add_deployment("v1.0", BUILD, ["success"])
        self.gh.add_deployment("v1.0", 43, ["in_progress", "failure"])
        code, out, err = self.run_main("status")
        self.assertEqual(code, 0, err)
        self.assertIn("v1.0 build 42", out)
        self.gh.add_deployment("v1.0", 43, ["success", "inactive"])
        self.assertEqual(self.run_main("status")[0], 0)

    def test_payload_as_string(self):
        dep = self.gh.add_deployment("v1.0", BUILD, ["success"])
        dep["payload"] = json.dumps(dep["payload"])
        self.assertEqual(self.run_main("status")[0], 0)

    def test_no_release_and_nothing_recorded_is_in_sync(self):
        self.write_no_release()
        code, out, err = self.run_main("status")
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out.splitlines(),
            [
                "desired   none: no release (deploy/house.yaml, release: none)",
                "observed  none: no release installed yet (no deployment of environment house is recorded as success)",
                "in sync: no release installed yet",
            ],
        )
        self.assertEqual(self.gh.calls_matching("issue"), [])

    def test_no_release_with_a_recorded_install_is_drift(self):
        self.write_no_release()
        self.gh.add_deployment("v1.0", BUILD, ["success"])
        code, out, err = self.run_main("status")
        self.assertEqual(code, 3)
        self.assertIn("drift: deploy/house.yaml names no release, but build 42 (v1.0) is recorded as installed", out)
        self.assertEqual(err, "")  # the warning about the issue belongs to drift --issue

    def test_drift_without_issue_only_prints(self):
        code, out, err = self.run_main("drift")
        self.assertEqual(code, 3)
        self.assertEqual(self.gh.calls_matching("issue"), [])

    def test_drift_online_check(self):
        self.write_house(build="40")
        code, out, err = self.run_main("drift")
        self.assertEqual(code, 1)
        self.assertIn("carries build 42", err)
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        code, out, err = self.run_main("drift")
        self.assertEqual(code, 3)
        self.assertIn("warning: release v1.0 carries no manifest.json", err)

    def test_drift_without_a_release_downloads_nothing(self):
        self.write_no_release()
        code, out, err = self.run_main("drift")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.calls_matching("release"), [])
        self.assertIn("in sync: no release installed yet", out)

    def test_validate_online(self):
        code, out, err = self.run_main("validate", "--online")
        self.assertEqual(code, 0, err)
        self.assertIn("valid (v1.0 build 42; drivers modernforms_fan, debug_mode Off)", out)
        self.assertIn("manifest.json build 42 matches", out)
        self.write_house(build="40")
        code, out, err = self.run_main("validate", "--online")
        self.assertEqual(code, 1)
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        code, out, err = self.run_main("validate", "--online")
        self.assertEqual(code, 1)
        self.assertIn("no manifest.json", err)
        self.assertEqual(self.run_main("validate")[0], 0)

    def test_validate_without_a_release(self):
        self.write_no_release()
        code, out, err = self.run_main("validate")
        self.assertEqual(code, 0, err)
        self.assertIn("valid (release none: no release installed yet; drivers modernforms_fan, debug_mode Off)", out)
        code, out, err = self.run_main("validate", "--online")
        self.assertEqual(code, 0, err)
        self.assertIn("release none: no release named, nothing to check online", out)
        self.assertEqual(self.gh.calls, [])

    def test_validate_refuses_an_invalid_file(self):
        self.write_house(release="none")  # build 42 with release none
        code, out, err = self.run_main("validate")
        self.assertEqual(code, 1)
        self.assertIn("is not valid:", err)
        self.assertIn("build must be none while release is none", err)


class DriftIssueTest(DeployCase):
    TITLE = "Deploy v1.0 (build 42) to the house"

    def open_issues(self):
        return [i for i in self.gh.issues.values() if i["state"] == "open"]

    def test_drift_without_issue_opens_one(self):
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(len(self.open_issues()), 1)
        issue = self.open_issues()[0]
        self.assertEqual(issue["title"], self.TITLE)
        self.assertIn("**42**", issue["body"])
        self.assertIn("no deployment of environment `house`", issue["body"])
        self.assertIn("python3 tools/deploy.py start", issue["body"])
        self.assertIn("System Manager", issue["body"])
        self.assertIn("https://github.com/octo/fan/releases/tag/v1.0", issue["body"])
        self.assertIn("opened deploy issue " + issue["url"], out)

    def test_second_run_creates_no_second_issue(self):
        self.run_main("drift", "--issue")
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(len(self.open_issues()), 1)
        self.assertIn("is current", out)
        self.assertEqual(len(self.gh.calls_matching("issue", "create")), 1)
        self.assertEqual(self.gh.calls_matching("issue", "edit"), [])
        self.assertEqual(self.gh.calls_matching("issue", "comment"), [])

    def test_desired_state_change_retitles_the_open_issue(self):
        old = self.gh.add_issue("Deploy v1.0 (build 40) to the house")
        self.gh.add_deployment("v1.0", 38, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(self.gh.issues[old["number"]]["title"], self.TITLE)
        self.assertIn("build **38**", self.gh.issues[old["number"]]["body"])
        self.assertEqual(len(self.gh.issues[old["number"]]["comments"]), 1)
        self.assertIn("desired state changed", self.gh.issues[old["number"]]["comments"][0])
        self.assertEqual(self.gh.calls_matching("issue", "create"), [])
        self.assertEqual(len(self.open_issues()), 1)

    def test_no_drift_closes_every_open_issue_and_leaves_closed_ones(self):
        self.gh.add_issue(self.TITLE, state="closed")
        a = self.gh.add_issue("Deploy v1.0 (build 40) to the house")
        b = self.gh.add_issue(self.TITLE)
        dep = self.gh.add_deployment("v1.0", BUILD, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 0, err)
        for number in (a["number"], b["number"]):
            self.assertEqual(self.gh.issues[number]["state"], "closed")
            self.assertEqual(
                self.gh.issues[number]["comments"], ["Build 42 (v1.0) recorded as deployed: %s" % dep["url"]]
            )
        self.assertEqual(len(self.gh.calls_matching("issue", "close")), 2)
        self.assertEqual(self.gh.calls_matching("issue", "create"), [])

    def test_no_drift_and_nothing_open_touches_nothing(self):
        self.gh.add_issue(self.TITLE, state="closed")
        self.gh.add_deployment("v1.0", BUILD, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.calls_matching("issue"), self.gh.calls_matching("issue", "list"))

    def test_two_open_issues_edit_the_oldest_only(self):
        first = self.gh.add_issue("Deploy v1.0 (build 30) to the house")
        second = self.gh.add_issue("Deploy v1.0 (build 31) to the house")
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(self.gh.issues[first["number"]]["title"], self.TITLE)
        self.assertEqual(self.gh.issues[second["number"]]["title"], "Deploy v1.0 (build 31) to the house")
        self.assertIn("second open deploy issue", err)

    def test_other_issues_with_the_label_are_never_touched(self):
        other = self.gh.add_issue("deploy.py refuses a note it should take")
        drift = self.gh.add_issue(self.TITLE)
        self.gh.add_deployment("v1.0", BUILD, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.issues[drift["number"]]["state"], "closed")
        self.assertEqual(self.gh.issues[other["number"]]["state"], "open")
        self.assertEqual(self.gh.issues[other["number"]]["comments"], [])

    def test_drift_with_only_another_labelled_issue_opens_its_own(self):
        other = self.gh.add_issue("Some other deploy-labelled issue")
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(self.gh.issues[other["number"]]["title"], "Some other deploy-labelled issue")
        self.assertEqual(len(self.gh.calls_matching("issue", "create")), 1)

    def test_no_release_opens_no_issue(self):
        """docs/scaffold-design.md, section 5: no issue while there is no deployment and the desired
        release is none."""
        self.write_no_release()
        for _run in range(2):
            code, out, err = self.run_main("drift", "--issue")
            self.assertEqual(code, 0, err)
            self.assertIn("in sync: no release installed yet", out)
        self.assertEqual(self.gh.issues, {})
        self.assertEqual(self.gh.calls_matching("issue"), self.gh.calls_matching("issue", "list"))

    def test_no_release_closes_an_open_drift_issue(self):
        drift = self.gh.add_issue(self.TITLE)  # from a desired release that was never installed
        other = self.gh.add_issue("Some other deploy-labelled issue")
        self.write_no_release()
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.issues[drift["number"]]["state"], "closed")
        self.assertEqual(
            self.gh.issues[drift["number"]]["comments"],
            ["deploy/house.yaml names no release (release: none) and no install is recorded: nothing to deploy."],
        )
        self.assertEqual(self.gh.issues[other["number"]]["state"], "open")
        self.assertEqual(self.gh.issues[other["number"]]["comments"], [])
        self.assertIn("closed deploy issue #%d" % drift["number"], out)

    def test_no_release_with_a_recorded_install_opens_no_issue(self):
        self.write_no_release()
        self.gh.add_deployment("v1.0", BUILD, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertIn("drift: deploy/house.yaml names no release, but build 42 (v1.0) is recorded as installed", out)
        self.assertIn("warning: no deploy issue is opened for this drift", err)
        self.assertIn("set release and build to the release the house should run", err)
        self.assertEqual(self.gh.calls_matching("issue"), [])


# ---------------------------------------------------------------------------
# Prereleases (docs/prerelease-design.md)
# ---------------------------------------------------------------------------


class TagPatternTest(DeployCase):
    """v1.0 and v1.1-beta.1, and nothing else, wherever a tag is taken."""

    def test_is_tag(self):
        for tag in GOOD_TAGS:
            self.assertTrue(deploy.is_tag(tag), tag)
        for tag in BAD_TAGS + ("", " v1.0", "v1.0 ", "v1.0\n", "v1.1-beta.1\n", None):
            self.assertFalse(deploy.is_tag(tag), repr(tag))

    def test_is_prerelease(self):
        self.assertEqual([tag for tag in GOOD_TAGS if deploy.is_prerelease(tag)], [t for t in GOOD_TAGS if "-" in t])

    def test_house_release(self):
        for tag in GOOD_TAGS:
            with self.subTest(tag=tag):
                self.assertEqual(deploy.validate_house(deploy.parse_house(house_text(release=tag))), [])
        for tag in BAD_TAGS:
            if tag == "none":
                continue  # the start state, with build: none (ValidateHouseTest)
            with self.subTest(tag=tag):
                self.assertEqual(
                    deploy.validate_house(deploy.parse_house(house_text(release=tag))),
                    [
                        "release must look like v1.0 (a release) or v1.1-beta.1 (a prerelease), or be none (no "
                        "release installed yet), not %r" % tag
                    ],
                )

    def test_start_and_record_refuse_a_bad_tag_before_any_call(self):
        for tag in ("v1.1-beta.0", "v1.0-rc1", "1.1-beta.1", "v1.1-beta.1\n", "none"):
            for argv in (
                ("start", "--tag", tag),
                ("record", "--tag", tag, "--build", "42", "--at", AT, "--note", "x"),
            ):
                with self.subTest(argv=argv):
                    code, out, err = self.run_main(*argv)
                    self.assertEqual(code, 1)
                    self.assertIn("--tag must look like v1.0 (a release) or v1.1-beta.1 (a prerelease)", err)
        self.assertEqual(self.gh.calls, [])


class DeployIssueTitleTest(unittest.TestCase):
    """The drift issue's title: "Deploy <tag> (build N) to the house" for a release or a
    prerelease tag, and nothing else, so that no other issue with the deploy label is touched."""

    def test_both_forms(self):
        for tag, build in (("v1.0", 42), ("v1.1-beta.1", 57), ("v12.34-beta.10", 1)):
            title = deploy.issue_title(tag, build)
            self.assertEqual(title, "Deploy %s (build %d) to the house" % (tag, build))
            self.assertTrue(deploy.DEPLOY_ISSUE_TITLE.fullmatch(title), title)

    def test_nothing_else(self):
        for title in (
            "Deploy v1.0 (build 42) to the house!",
            "Deploy v1.0 (build 42) to the house\n",
            "deploy v1.0 (build 42) to the house",
            "Re: Deploy v1.0 (build 42) to the house",
            "Deploy v1.1-beta.1 (build 57) to the house, again",
            "Deploy v1.0 (build) to the house",
            "Deploy v1.0 (build 4a) to the house",
            "Deploy v1.0 (build \u0664\u0662) to the house",
            "Deploy v1.0 build 42 to the house",
            "Deploy none (build 42) to the house",
        ):
            self.assertIsNone(deploy.DEPLOY_ISSUE_TITLE.fullmatch(title), repr(title))
        for tag in BAD_TAGS:
            self.assertIsNone(deploy.DEPLOY_ISSUE_TITLE.fullmatch("Deploy %s (build 1) to the house" % tag), tag)


class PrereleaseTest(DeployCase):
    """deploy/house.yaml names the prerelease v1.1-beta.1 (build 57), whose manifest lists two packages."""

    TITLE = "Deploy v1.1-beta.1 (build 57) to the house"

    def setUp(self):
        super().setUp()
        self.gh.tags[BETA_TAG] = BETA_COMMIT
        manifest = manifest_for(build=BETA_BUILD, tag=BETA_TAG, commit=BETA_COMMIT, packages=BETA_PACKAGE_BYTES)
        self.gh.assets[BETA_TAG] = release_assets(manifest, packages=BETA_PACKAGE_BYTES)
        for name, data in BETA_PACKAGE_BYTES.items():
            self.gh.attestations[sha(data)] = attestation_for(sha(data), name=name)
        self.write_house(release=BETA_TAG, build=str(BETA_BUILD), drivers=BETA_DRIVERS)

    def beta_file(self, name):
        return os.path.join(deploy.RELEASE_DIR, BETA_TAG, name)

    def open_issues(self):
        return [issue for issue in self.gh.issues.values() if issue["state"] == "open"]

    def test_validate_offline_and_online(self):
        code, out, err = self.run_main("validate")
        self.assertEqual(code, 0, err)
        self.assertIn("valid (v1.1-beta.1 build 57;", out)
        code, out, err = self.run_main("validate", "--online")
        self.assertEqual(code, 0, err)
        self.assertIn("release v1.1-beta.1: manifest.json build 57 matches", out)
        self.assertIn("modernforms_fan.c4z, modernforms_light.c4z", out)

    def test_start_install_and_done(self):
        issue = self.gh.add_issue(self.TITLE)
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)
        names = sorted(BETA_PACKAGE_BYTES)
        self.assertIn("downloaded 4 files", out)
        # The manifest first, then exactly the packages it names.
        downloads = [args for args, _ in self.gh.calls_matching("release", "download")]
        patterns = [[args[i + 1] for i, arg in enumerate(args) if arg == "--pattern"] for args in downloads]
        self.assertEqual(patterns, [["manifest.json", "SHA256SUMS.txt"], names])
        body = self.gh.api_calls("POST", "deployments")[0][1]
        self.assertEqual((body["ref"], body["description"]), (BETA_TAG, "Build 57 (v1.1-beta.1) to the house"))
        self.assertEqual(body["payload"]["packages"], {name: sha(data) for name, data in BETA_PACKAGE_BYTES.items()})
        verified = [args[2] for args, _ in self.gh.calls_matching("attestation", "verify")]
        self.assertEqual(verified, [self.beta_file(name) for name in names])

        with open(self.beta_file("BRIEF.md"), encoding="utf-8") as handle:
            brief = handle.read()
        self.assertTrue(brief.startswith("# Install build 57 (v1.1-beta.1, a prerelease) on the house\n"), brief[:80])
        self.assertIn("v1.1-beta.1 is a prerelease: a build for testing, marked Pre-release on GitHub", brief)
        self.assertEqual(brief.count("Invoke-WebRequest"), 2)
        for name, data in BETA_PACKAGE_BYTES.items():
            self.assertIn("https://github.com/octo/fan/releases/download/v1.1-beta.1/%s" % name, brief)
            self.assertIn("    '%s' = '%s'" % (name, sha(data)), brief)
            self.assertIn("- %s: provenance verified, signed by" % name, brief)
        self.assertIn(
            "Fetch the 2 packages of the release (modernforms_fan.c4z and modernforms_light.c4z)",
            brief,
        )
        self.assertIn("pick both files from `C:\\c4-mf\\drivers\\v1.1-beta.1\\` at once", brief)
        self.assertIn(
            "`Driver Version` = 57 (every device of the drivers modernforms_fan and modernforms_light)",
            brief,
        )
        self.assertIn(APPROVAL, brief)
        self.assertEqual(deploy.private_findings(brief), [])

        code, out, err = self.run_main("done", "--devices", "2")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.issues[issue["number"]]["state"], "closed")
        self.assertIn("in sync: build 57 (v1.1-beta.1)", out)
        self.assertEqual(self.run_main("status")[0], 0)

    def test_three_packages_are_all_picked(self):
        more = dict(BETA_PACKAGE_BYTES, **{"modernforms_extra.c4z": b"extra package bytes"})
        manifest = manifest_for(build=BETA_BUILD, tag=BETA_TAG, commit=BETA_COMMIT, packages=more)
        self.gh.assets[BETA_TAG] = release_assets(manifest, packages=more)
        for name, data in more.items():
            self.gh.attestations[sha(data)] = attestation_for(sha(data), name=name)
        self.write_house(release=BETA_TAG, build=str(BETA_BUILD), drivers=BETA_DRIVERS + " modernforms_extra")
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)
        with open(self.beta_file("BRIEF.md"), encoding="utf-8") as handle:
            brief = handle.read()
        self.assertIn(
            "Fetch the 3 packages of the release (modernforms_extra.c4z, modernforms_fan.c4z and "
            "modernforms_light.c4z)",
            brief,
        )
        self.assertIn("pick all 3 files from `C:\\c4-mf\\drivers\\v1.1-beta.1\\` at once", brief)

    def test_start_refuses_drivers_that_are_not_the_releases(self):
        for drivers in (
            "modernforms_fan",
            "modernforms_fan modernforms_light modernforms_extra",
            "modernforms_fan modernforms_lamp",
        ):
            with self.subTest(drivers=drivers):
                self.write_house(release=BETA_TAG, build=str(BETA_BUILD), drivers=drivers)
                before = len(self.gh.calls)
                code, out, err = self.run_main("start")
                self.assertEqual(code, 1)
                self.assertIn("deploy/house.yaml names the drivers %s, but" % " ".join(sorted(drivers.split())), err)
                self.assertIn("v1.1-beta.1 carries modernforms_fan.c4z, modernforms_light.c4z", err)
                downloads = [args for args, _ in self.gh.calls[before:] if args[:2] == ["release", "download"]]
                self.assertEqual(len(downloads), 1, "only manifest.json and SHA256SUMS.txt are downloaded")
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_online_checks_refuse_drivers_that_are_not_the_releases(self):
        self.write_house(release=BETA_TAG, build=str(BETA_BUILD), drivers="modernforms_fan")
        self.assertEqual(self.run_main("validate")[0], 0)  # offline only the form is checked
        for argv in (("validate", "--online"), ("drift",), ("drift", "--issue")):
            with self.subTest(argv=argv):
                code, out, err = self.run_main(*argv)
                self.assertEqual(code, 1)
                self.assertIn("names the drivers modernforms_fan, but the release v1.1-beta.1", err)
        self.assertEqual(self.gh.calls_matching("issue"), [])

    def test_drift_issue_names_the_prerelease(self):
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        [issue] = self.open_issues()
        self.assertEqual(issue["title"], self.TITLE)
        self.assertIn("v1.1-beta.1 is a prerelease, a build for testing", issue["body"])
        self.assertIn("https://github.com/octo/fan/releases/tag/v1.1-beta.1", issue["body"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertIn("is current", out)
        self.assertEqual(len(self.gh.calls_matching("issue", "create")), 1)

    def test_going_back_to_the_release_retitles_the_issue(self):
        issue = self.gh.add_issue(self.TITLE)
        self.gh.add_deployment(BETA_TAG, BETA_BUILD, ["success"])
        self.write_house()  # back to v1.0, build 42, one driver: an ordinary desired-state change
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        updated = self.gh.issues[issue["number"]]
        self.assertEqual(updated["title"], "Deploy v1.0 (build 42) to the house")
        self.assertNotIn("is a prerelease", updated["body"])
        self.assertEqual(
            updated["comments"],
            ['desired state changed: now v1.0 (build 42); this issue was "%s".' % self.TITLE],
        )

    def test_only_the_two_title_forms_are_drift_issues(self):
        lookalikes = [
            self.gh.add_issue(title)
            for title in (
                "Deploy v1.1-beta.0 (build 57) to the house",
                "Deploy v1.1-rc.1 (build 57) to the house",
                "Deploy v1.1-beta.1 (build 57) to the house, again",
            )
        ]
        drift_issue = self.gh.add_issue(self.TITLE)
        self.gh.add_deployment(BETA_TAG, BETA_BUILD, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.issues[drift_issue["number"]]["state"], "closed")
        for issue in lookalikes:
            self.assertEqual(self.gh.issues[issue["number"]]["state"], "open")
            self.assertEqual(self.gh.issues[issue["number"]]["comments"], [])

    def test_record_a_prerelease(self):
        code, out, err = self.run_main(
            "record", "--tag", BETA_TAG, "--build", str(BETA_BUILD), "--at", AT, "--note", "installed by hand"
        )
        self.assertEqual(code, 0, err)
        deployment = self.gh.deployments[max(self.gh.deployments)]
        self.assertEqual(deployment["ref"], BETA_TAG)
        self.assertEqual(deployment["payload"]["commit"], BETA_COMMIT)
        self.assertEqual(
            deployment["payload"]["packages"], {name: sha(data) for name, data in BETA_PACKAGE_BYTES.items()}
        )
        self.assertIn("in sync: build 57 (v1.1-beta.1)", out)

    def test_done_refuses_when_the_release_gained_a_package(self):
        self.assertEqual(self.run_main("start")[0], 0)
        more = dict(BETA_PACKAGE_BYTES, **{"modernforms_extra.c4z": b"extra package bytes"})
        manifest = manifest_for(build=BETA_BUILD, tag=BETA_TAG, commit=BETA_COMMIT, packages=more)
        self.gh.assets[BETA_TAG]["manifest.json"] = json.dumps(manifest).encode()
        code, out, err = self.run_main("done")
        self.assertEqual(code, 1)
        self.assertIn("the release v1.1-beta.1 replaced modernforms_extra.c4z after start", err)


if __name__ == "__main__":
    unittest.main()
