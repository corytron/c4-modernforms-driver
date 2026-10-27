# Contributing

This is a personal project for one Control4 home, offered as is: there is no
roadmap and no support obligation, and on 2026-10-27 there is no release
yet. Bug reports and pull requests are welcome all the same. This page says
what a contribution has to respect; the [README](README.md) says what the
driver is meant to do and how it is built and tested.

## License of contributions

Contributions are accepted under the Apache License 2.0 (License §5, inbound
= outbound): by submitting a pull request you agree that your contribution is
licensed under the same terms as the project, without any additional terms or
conditions. No contributor agreement is needed. Signing off your commits
(`git commit -s`, the Developer Certificate of Origin) is welcome but
optional.

## What never goes into the repository

- **Code or text from Snap One.** Nothing from `drivers-common-public`,
  `drivers-template-code-public`, `drivers-driverpackager` or the DriverWorks
  documentation (API, Fundamentals, XML, the proxy references): their license
  keeps them confidential and assigns derivative works to Snap One. Cite a
  documentation file by its path when you rely on it; do not quote it, and
  re-implement rather than vendor. The packager is cloned separately by
  whoever builds.
- **The fan maker's material.** No text, pictures, firmware or app content
  of Modern Forms or WAC Lighting, and nothing of WAC's API reference
  documents, which WAC's API License Agreement treats as confidential (the
  documents themselves never go into the repository). Facts about the fan's
  local interface (an endpoint, a field name, a range) are fine in your own
  words, with the source they come from: a public open-source client of the
  interface at a named version, or a read-only query of your own fan with
  its answer reduced to placeholders.
- **Private data.** Never a real LAN address, MAC address, fan client id or
  device id, e-mail address or cloud identity (a fan's device information
  names its owner's account), room or project name, key, token or
  certificate, and no screenshot of a real project. Use only these
  placeholders, in code, tests and documents, the manual and the README
  included:

  | What | Placeholder |
  | --- | --- |
  | Fan IP address | `10.0.2.151` (a second fan `10.0.2.152`) |
  | Controller IP address | `10.0.2.10` |
  | Development machine (the VM) | `192.0.2.7` |
  | Windows machine (Composer) | `192.0.2.8` |
  | Fan MAC address | `00:00:5e:00:53:01` (the RFC 7042 documentation range) |
  | Fan client id / device id | `MF_00005E005301` |
  | Room names | "Example Room", "Second Room" |
  | Project name | "Example Project" |

  Any other example address comes from the RFC 5737 ranges (`192.0.2.0/24`,
  `198.51.100.0/24`, `203.0.113.0/24`), any example e-mail address from the
  documentation domains (`example.com`, `example.net`, `example.org`).
  Screenshots show no house: invented names, or the house's own texts
  painted over (`tools/composer/Shots.ps1`). These rules are enforced: the
  `secrets` check runs `gitleaks` with the repository's rules
  (`.gitleaks.toml`) over the working tree and the git history (in CI, the
  history of the commit under test, on every pull request and push to
  `main`; locally in `tools/check.sh`, the history of every branch and tag
  you have). The rules let the placeholders and a few textbook examples
  through (`.gitleaks.toml` lists them); other addresses, a MAC address or
  a Modern Forms client id outside the documentation range, a real e-mail
  address or cloud identity, and anything that looks like a key, a token or
  a private key fail the check. The tools
  that post to GitHub (`tools/gh-discussion.py`, `tools/deploy.py`) refuse
  the same kinds of data, and GitHub's secret scanning with push protection
  is on as well.
- **Logos, badges or trade dress** of Snap One, WAC Lighting or Modern
  Forms, and any wording that suggests affiliation, certification or
  endorsement. "For Modern Forms fans" and "works with Modern Forms fans"
  describe compatibility and are the phrasings to use.

## Conventions

- **Lua 5.1.** The controller runs the driver under LuaJIT, which follows
  the Lua 5.1 language standard (`<script jit="1">`; DriverWorks
  Fundamentals, `7_driverworks_and_luajit/_1-OS3LUAJIT.md`): no 5.2+
  features, no C modules, no `require` of anything that is not packaged in
  the driver. Only documented DriverWorks APIs; when a call's behaviour is
  uncertain, say in the PR what you verified on a controller and what you
  assumed, naming the documentation file.
- **The fan's interface.** Only fields and commands with a source: a public
  open-source client of the interface (file and version) or a read-only
  query of a fan (date, model, firmware). The design notes
  (`docs/design.md`) mark each claim verified or assumed; never invent a
  field.
- **Style.** Tabs for indentation, lines of at most 120 characters,
  `luacheck src tests tools` clean (the rules are in `.luacheckrc`,
  including the list of DriverWorks entry points the driver defines).
- **Tests.** `busted` specs in `tests/spec/*_spec.lua`, in the style of the
  existing ones, run the driver against the fake DriverWorks runtime in
  `tests/helpers/fake_c4.lua` (add a method there when the driver starts
  using a new documented API, mirroring the real colon-call signature) and,
  once the research has recorded them, the fan's answers with every
  identifier replaced by a placeholder under `tests/fixtures/`. Every change
  of behaviour comes with a spec; `busted tests` stays green.
- **One build for every package.** `tools/build.sh` builds one package per
  `src/*/driver.xml` (one today, `modernforms_fan.c4z`), stages
  `src/common/` into each as `common/` (release builds without the
  development modules) and stamps every package with the same build number
  (the commit count), so a change to a shared module is a change to every
  package.
- **Texts users read.** Property texts and the driver's results are part of
  the contract: the manual (`src/modernforms_fan/www/documentation.html`)
  quotes them. A change to one changes the manual too, and
  `docs/status.md` records what now runs.
- **Automation needs a contract first.** Anything that acts on its own over
  the life of the system (finding a fan, following its address, syncing
  names or rooms, creating or removing devices, moving a house from the
  stock driver) starts with the lifecycle corner cases on both sides,
  written up under `docs/` with a decision per case: automatic, offered, or
  forbidden without a click. Automation that makes a later manual fix
  harder is wrong.
- **Control4 is the source of truth.** Automations live in Control4
  programming, not in the Modern Forms app; the driver reports what the fan
  does, and any remedy for a vendor-side automation is offered, reversible
  and needs a click.
- **Tooling.** Python under `tools/` is 3.12 or newer, standard library
  only, `ruff` clean under `ruff.toml` (`ruff check tools` and `ruff format
  --check tools`), with `unittest` tests under `tools/tests/`. Shell scripts
  are bash with `set -euo pipefail` and `shellcheck -S style` clean. The
  Windows session's PowerShell under `tools/composer/` passes
  PSScriptAnalyzer at severity Error and stays ASCII only (Windows
  PowerShell 5.1 reads a file without a byte order mark as ANSI).
  Workflows pass `actionlint` and `zizmor`: every action pinned to a full
  commit SHA with the version in a trailing comment, every job with
  `timeout-minutes` and the least `permissions:` it needs.
- **Commits.** Small, working steps with clear messages; one branch and one
  pull request per feature, linked to its issue (`Closes #N` in the pull
  request) when there is one.

## Checks

One script runs every check, the same way on your machine and in CI:

```sh
tools/setup-checks.sh   # once: ruff, zizmor, shellcheck, actionlint and gitleaks into ~/.local/bin, without sudo
tools/check.sh          # before a pull request
```

`tools/setup-checks.sh` takes no options. It needs `python3 -m pip` and
`curl`, installs shellcheck only when none is on `PATH`, and downloads
actionlint and gitleaks for Linux x86_64 only. The other tools come from
elsewhere: `luacheck`, `busted` and `dkjson` from luarocks for Lua 5.1 (the
versions CI pins are in `.github/workflows/ci.yml`), and `pwsh` with
PSScriptAnalyzer for the `powershell` check.

| Check | What it runs | What it covers |
| --- | --- | --- |
| `lua-lint` | `luacheck src tests tools` | the driver and the specs |
| `lua-test` | `busted tests` | the specs, against the fake DriverWorks runtime |
| `shell` | `shellcheck -S style tools/*.sh` | the shell scripts |
| `python-lint` | `ruff check tools`, `ruff format --check tools` | the Python tooling |
| `python-test` | `python3 -B -m unittest discover -s tools/tests` | the tooling's unit tests |
| `xml` | an `xml.etree` parse | every `src/*/driver.xml` is well-formed |
| `powershell` | `Invoke-ScriptAnalyzer -Path tools/composer -Recurse -Severity Error` in `pwsh` | `tools/composer/`; skipped without `pwsh` |
| `workflows` | `actionlint`, `zizmor --min-severity medium .github/workflows` | `.github/workflows/` |
| `secrets` | `gitleaks dir`, `gitleaks git` with `.gitleaks.toml` | the working tree, then the history: of every local branch and tag on your machine, of the commit under test in CI |
| `house` | `python3 tools/deploy.py validate` | `deploy/house.yaml`, the house's desired state |
| `changelog` | `python3 tools/changelog.py check` | `CHANGELOG.md`'s format |
| `links` | `python3 tools/check_links.py` | every link in every Markdown file and Documentation tab resolves |

`tools/check.sh --only <name>...` runs a selection, `--help` lists the
names. A check whose tool is not installed is reported as `skip` and does
not fail the run; CI runs the same script with `--strict`, where a skip is a
failure, in four jobs whose names are the required checks on `main`:
*Lint and test (Lua 5.1)* (`lua-lint`, `lua-test`), *Build the .c4z
packages* (after the Lua job: `tools/build.sh`, then a check that every
package carries `LICENSE` and `NOTICE` and that `build/manifest.json`
describes them), *Tooling checks (shell, Python, XML, workflows)*
(`shell`, `python-lint`, `python-test`, `xml`, `powershell`, `workflows`,
`house`, `changelog`, `links`) and *Secrets and private data* (`secrets`).
Without `pwsh`, run `--strict` with `--only` and every other name. The tool
versions are pinned with their sha256: actionlint and gitleaks in
`tools/setup-checks.sh`, which verifies what it downloads, and ruff, zizmor
and shellcheck-py in `tools/requirements-checks.txt`, which pip enforces
(`--require-hashes`).

## Pull request checklist

- For anything bigger than a typo, an issue comes first; the pull request
  says `Closes #N`.
- `tools/check.sh` passes (CI runs the same checks with `--strict`) and
  `tools/build.sh` builds the package.
- A change that changes what the driver does or what its documentation says
  adds a line under `## Unreleased` in `CHANGELOG.md`, written for owners
  and dealers, with the issue number.
- The manual and `docs/status.md` are updated if behaviour or a text
  changed.
- A new document: if visitors of the project page would find it useful, the
  README links it; a design note, contract or research note goes in
  `docs/README.md`.
- A change to a `driver.xml` `<capabilities>` block is called out in the PR
  description: installing it makes Composer ask "Restart Director?", and
  users must reboot their controller from System Manager before it loads.
- No private data: the `secrets` check runs gitleaks, but grep for your own
  addresses, MACs and ids before pushing all the same; the rules are above.
- Say whether you ran it on a controller, and with which Control4 OS and
  which fan model and firmware; an untested change is fine if it says so.

## Labels and merging

Issues and pull requests carry the labels in `.github/labels.json`, which a
workflow keeps in sync (it creates and updates labels and never deletes
one): among them `mf-api` for the fan's local interface, its models and
firmware, `composer` for what Composer and Director do, and `hardware` for
what needs the controller, a fan, a keypad or a phone to close. The issue
forms set `bug`, `enhancement` or `beta-feedback`; the maintainer adds the
rest. Release notes generated by hand group merged pull requests by label
(`.github/release.yml`): `bug` under Fixed, `enhancement` under New and
changed, `security` under Security, `documentation` under Documentation,
`ci` and `release` under Tooling and CI; the Release workflow itself writes
every release's notes from `CHANGELOG.md`. Three labels belong to
automation: `deploy` marks the one issue the drift workflow keeps open
while `deploy/house.yaml` and the recorded deployment differ, `security`
also marks the one code scanning issue the triage workflow keeps
(SECURITY.md), and `dependencies` marks Dependabot's pull requests.

A pull request is merged by the maintainer once the four checks are green,
the branch is up to date with `main` and the review is done; branch
protection holds the maintainer to the same rules. The one exception is
Dependabot's weekly update of the pinned actions, proposed no sooner than
seven days after an upstream release (security updates come at once),
which merges on its own when the checks pass. Its weekly update of the
Python check tools in `tools/requirements-checks.txt` is reviewed like any
other pull request, and nothing else is auto-merged.

## Reporting a problem

Open a GitHub issue with the Driver Version, the Control4 OS version, the
fan's model and firmware version, the texts of the driver's properties and
the relevant lines of its Lua output (the device's Lua tab in Composer;
**Debug Mode** On if asked, and Off again afterwards), with your addresses,
MAC addresses and fan ids replaced by the placeholders above. Questions go
to [Discussions](https://github.com/corytron/c4-modernforms-driver/discussions).
For something security-sensitive, use GitHub's private vulnerability
reporting on this repository ([SECURITY.md](SECURITY.md)) instead of
opening a public issue. Everyone taking part follows the
[code of conduct](CODE_OF_CONDUCT.md).
