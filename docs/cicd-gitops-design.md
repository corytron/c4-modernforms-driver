# CI/CD and GitOps (contract)

How a change reaches `main`, how a release is cut and how the house is
brought to the release it should run. The scaffold contract
([`scaffold-design.md`](scaffold-design.md)) names the pieces; this document
says how they work together. Where it and the code disagree, fix one of them
in a pull request that says which. The section numbers are cited by the
workflows and tools, so they stay.

## 1. What the words mean here

- **CI**: every pull request and every push to `main` runs the checks a
  developer runs on the VM, for every file type in the repository, and
  `main` takes no change those checks refuse.
- **CD**: a release is an immutable, attested set of files on the Releases
  page, cut by a workflow from `main`; nothing is built by hand for an
  install.
- **GitOps**: the state the house is meant to be in is a file in git,
  [`deploy/house.yaml`](../deploy/house.yaml) (the desired state); the state
  it is observed to be in is the GitHub Deployments of the environment
  `house` (the observed state); a workflow compares the two and keeps one
  issue open while they differ. The actuator is the Windows Composer session
  ([`composer-remote.md`](composer-remote.md)): the controller has no
  install API, so the Composer click is **never automatic**. An install is
  approval-gated (the owner's standing approval), recorded and reconciled,
  not autonomous.

## 2. Files and conventions

| Path | Role |
| --- | --- |
| [`deploy/house.yaml`](../deploy/house.yaml) | the desired state (section 6) |
| [`tools/deploy.py`](../tools/deploy.py), its tests | validates the desired state, verifies a release, writes the install brief, records installs, reconciles (section 7) |
| [`tools/changelog.py`](../tools/changelog.py), its tests | the changelog's checks and renderings ([`changelog-design.md`](changelog-design.md)) |
| `tools/check.sh`, `tools/setup-checks.sh`, `tools/requirements-checks.txt` | every check, on the VM and in CI, and the pinned tools they need (section 3) |
| [`tools/build.sh`](../tools/build.sh) | the packages and `build/manifest.json` (section 5.2) |
| [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | the four required jobs (section 4) |
| [`.github/workflows/release.yml`](../.github/workflows/release.yml) | releases and prereleases (section 5) |
| [`.github/workflows/drift.yml`](../.github/workflows/drift.yml) | desired against observed (section 7.1) |
| `.github/workflows/scorecard.yml`, `.github/workflows/code-scanning-triage.yml` | supply-chain score and the code scanning issue (sections 4.5 and 4.6) |
| `.github/workflows/labels.yml`, `.github/workflows/dependabot-auto-merge.yml`, `.github/dependabot.yml` | labels and pinned-action updates (section 8) |
| `ruff.toml`, `.gitleaks.toml`, `.github/actionlint.yaml` (if needed) | Python lint settings, the private-data scan, linter settings |

Conventions: Python 3.12, standard library only (`tools/` has no
dependencies; `deploy/house.yaml` is the flat `key: value` subset of section
6, parsed with a few lines, no YAML library), `ruff` clean under `ruff.toml`
(line length 120, rules E F W I B), unit tests with `unittest` under
`tools/tests/`; shell scripts bash with `set -euo pipefail` and shellcheck
clean; workflows actionlint and zizmor clean, every action pinned to a full
commit SHA with its version in a trailing comment, every job with
`timeout-minutes` and the least `permissions:` it needs. Dates and build
numbers in documents are absolute. Nothing names a package by hand: the
packages are the directories `src/<name>/` that hold a `driver.xml` (one
today, `modernforms_fan`), and every tool and workflow takes the list from
there or from the manifest.

## 3. One script runs the checks: `tools/check.sh`

`tools/check.sh [--strict] [--only <name>...]` runs, in this order, printing
one line per check (`ok`, `FAIL`, `skip (<tool> not installed)`), and exits
1 if any failed; `--strict` turns every skip into a failure (CI uses it, so
nothing is silently skipped on the runner).

| Name | What it runs |
| --- | --- |
| `lua-lint` | `luacheck src tests tools` |
| `lua-test` | `busted tests` |
| `shell` | `shellcheck -S style` over `tools/*.sh` |
| `python-lint` | `ruff check tools` and `ruff format --check tools` |
| `python-test` | `python3 -B -m unittest discover -s tools/tests` (`-B`: no `__pycache__`, whose folded test vectors the secrets scan would flag) |
| `xml` | every `src/*/driver.xml` is well-formed (`xml.etree`) |
| `powershell` | PSScriptAnalyzer over `tools/composer`; skipped where there is no `pwsh` (the VM) |
| `workflows` | `actionlint`, then `zizmor --min-severity medium .github/workflows` |
| `secrets` | `gitleaks` with `.gitleaks.toml` over the tree, then over the history: of every local ref on the VM, of `HEAD` in GitHub Actions |
| `house` | `python3 tools/deploy.py validate` (section 6, offline) |
| `changelog` | `python3 -I tools/changelog.py check --file CHANGELOG.md` |
| `links` | `python3 -I tools/check_links.py`: every link of every tracked Markdown file and Documentation tab resolves, heading anchors included |

`tools/setup-checks.sh` installs what the VM lacks into `~/.local/bin`
without `sudo`: `ruff`, `zizmor` and `shellcheck-py` from
`tools/requirements-checks.txt`, pinned by version and by the sha256 of
every file PyPI has for them (`pip install --require-hashes --no-deps
--only-binary=:all:`), and `actionlint` and `gitleaks` as release binaries
whose sha256 the script carries. CI runs the same script.

## 4. CI: `.github/workflows/ci.yml`

Triggers: `pull_request`, `push` to `main`, `workflow_dispatch`, and a
weekly `schedule` (Monday 06:00 UTC) so that a broken tool install shows up
without a pull request. Four jobs; **their names are the required status
checks on `main`** and do not change without changing branch protection:

1. `Lint and test (Lua 5.1)`: Lua 5.1 and the pinned rocks (section 5.5),
   then `tools/check.sh --strict --only lua-lint lua-test`.
2. `Build the .c4z packages`: full-depth checkout (the build number is the
   commit count), the packager at its pinned commit, `tools/build.sh`, the
   packages checked against the manifest and the `src/*/driver.xml`
   directories, LICENSE and NOTICE in each; uploaded as the artifact
   `mf-drivers-build-<run>`.
3. `Tooling checks (shell, Python, XML, workflows)`:
   `tools/setup-checks.sh`, then `tools/check.sh --strict --only shell
   python-lint python-test xml powershell workflows house changelog links`.
4. `Secrets and private data`: full-depth checkout, `tools/setup-checks.sh`,
   `tools/check.sh --strict --only secrets`.

`permissions: contents: read` everywhere.

### 4.5 Scorecard and CodeQL

`.github/workflows/scorecard.yml` scores the repository's supply-chain
practices on every push to `main`, on a branch protection change and weekly,
publishes the result (the README's badge) and uploads it to code scanning.
CodeQL's default setup (Python and Actions) is enabled through the API, not
by a workflow file.

### 4.6 The code scanning issue

`.github/workflows/code-scanning-triage.yml` (push to `main`, daily, on
request) waits for the scans of the new commit and keeps exactly one open
issue labelled `security`, "Code scanning: N open alert(s) on main": opened
when alerts exist, updated when they change, closed when none remain. It
never dismisses an alert, never touches a closed issue and never opens a
second one. Its token cannot read secret scanning alerts; the coordinator
checks those with `gh api`.

## 5. Releases: `.github/workflows/release.yml`

### 5.1 Triggers and the rule

- A pushed tag `v*`, or `workflow_dispatch` with a version (`1.0`, or
  `1.0-beta.1` for a prerelease; `^[0-9]+\.[0-9]+(-beta\.[1-9][0-9]*)?$`).
  The dispatch path builds `main`'s head and, once the packages are built,
  checked and attested, tags it `v<version>` and pushes the tag in the same
  run (a tag pushed with the workflow's own token starts no second run). A
  run that fails before that leaves the tags where they were.
- A release is built only from `main`: a pushed tag must point at a commit
  on `main`, and a dispatch must run from `main`.
- A release tag `vX.Y` moves with every new build of X.Y, whose files then
  replace the release's; a prerelease tag never moves (section 5.6).
- The version's X.Y must have a codename in `.github/codenames.json`, which
  starts empty: the first step refuses a version it does not name, before
  anything is built ([`changelog-design.md`](changelog-design.md),
  section 1).

### 5.2 `build/manifest.json`

[`tools/build.sh`](../tools/build.sh) writes it next to the packages, and
`tools/deploy.py` reads it from the release (schema 1):

```json
{
  "schema": 1,
  "tag": "v1.0",
  "version": "1.0",
  "build": 42,
  "commit": "<40-hex sha>",
  "built_at": "2026-11-02T03:12:45Z",
  "dev": false,
  "packages": {
    "modernforms_fan.c4z": {"sha256": "<64 hex>", "bytes": 123456}
  }
}
```

`tag` and `version` are null for a local build without a tag; `build` is
`git rev-list --count HEAD`, the `<version>` of every `driver.xml` and the
Driver Version Composer shows; `dev` is true for `tools/build.sh --dev`,
which is never released or installed as the production driver. `packages`
names one package per `src/<name>/driver.xml`.

The release carries every package of the manifest, `SHA256SUMS.txt`,
`manifest.json`, the provenance bundle `attestations.sigstore.json` and its
in-toto statement, and its title and notes come from `CHANGELOG.md` on every
run ([`changelog-design.md`](changelog-design.md), section 3).

### 5.3 Tag protection

A repository ruleset on the tags `v*` blocks their deletion and lets GitHub
Actions create and update them (the dispatch path moves a release tag).

### 5.4 Two jobs

No third-party code runs where the write token or the signing identity is:

- **build** (`Lint, test and build the packages`; `contents: read`, no
  `id-token`, no `GH_TOKEN`): checkout, the tag and codename check of
  section 5.1, the pinned rocks, lint and test, the pinned packager, the
  build, the package and manifest checks, `SHA256SUMS.txt` and the notes,
  handed over as a workflow artifact.
- **publish** (`Attest the packages and publish the release`; `contents:
  write`, `id-token: write`, `attestations: write`): only `actions/*` pinned
  by SHA, `git`, `gh` and short `python3` steps of its own. It checks what
  the build job handed over against this run's commit, signs the
  build-provenance attestation, pushes the tag (dispatch only) and creates
  or updates the release with its files, title and notes. `GH_TOKEN` is set
  only on the steps that push the tag or call `gh`.

A compromised tool in the build job can still put its own code into the
packages, which the attestation then truthfully describes as built by
`release.yml` from this commit; it cannot push or move tags, replace a
release's files or sign provenance for files of its choosing.

### 5.5 Pinned build inputs

Everything CI and the Release workflow run is pinned, so that a new upstream
version reaches a build only through a reviewed change: actions by full
commit SHA (Dependabot proposes updates weekly, no sooner than seven days
after their release); Snap One's packager at the reviewed commit
`16eef8beb70303606f066524cda516b2aa7ce38d`, fetched by SHA; every luarocks
rock at an exact version, installed with `--deps-mode=none`; the Python
check tools by hash (section 3). The packager and the rocks are no
Dependabot ecosystem: they move by hand, in both workflows in one pull
request, after reading their changes.

### 5.6 Prereleases

The contract is [`prerelease-design.md`](prerelease-design.md). A
prerelease `X.Y-beta.N` is built from `main` by the same two jobs, with the
same checks, attestations and assets, and carries its X.Y's codename. Its
tag never moves: a dispatch for a prerelease tag that exists fails before
anything is built. Its notes come from `.github/prerelease-notes.md` and the
same `## Unreleased` entry, and it is published with `--prerelease
--latest=false`, so `releases/latest` keeps serving the stable release.
`CHANGELOG.md` is never stamped for a prerelease. A prerelease may come
before the first release (a 1.0 beta): its notes then use the template's
lines for no stable release ([`changelog-design.md`](changelog-design.md),
section 4).

## 6. Desired state: `deploy/house.yaml`

Flat `key: value` lines, `#` comments, no nesting, no lists; a value may be
quoted (`"Off"` is `Off`), a trailing comment is dropped:

```yaml
environment: house
release: none            # no build of these drivers is installed yet (the house runs the stock WAC driver)
build: none
drivers: modernforms_fan
debug_mode: Off
```

`python3 tools/deploy.py validate` (exit 0 or 1; CI's `house` check) holds
the file to these rules:

- `environment` is `house`.
- `release` is a release tag `vX.Y` or a prerelease tag `vX.Y-beta.N`, or
  `none`, the start state: no release of these drivers is meant to be
  installed yet. `build` is the release's build number, a positive integer,
  and `none` exactly when `release` is `none`.
- `drivers` names driver directories (`modernforms_fan`, not
  `modernforms_fan.c4z`), separated by spaces, each once. Offline only their
  form is checked, since the file may name an older release than the tree
  builds; `validate --online`, `drift` and `start` hold them to exactly the
  release manifest's packages.
- `debug_mode` is `Off`: a release never ships with debugging on. It is the
  setting the Windows session reads back on every device after an install,
  with `Driver Version`; every `driver.xml` declares both (a unit test reads
  them there). Settings the v1 contract adds become keys here the same way.
- `--online` also fetches the release's `manifest.json` and fails when its
  build or packages differ from the file's; with `release: none` there is
  nothing to fetch.

Changing the desired state is a pull request. The release exists first, so
the order is: merge the code, cut the release, a pull request that sets
`release`, `build` and `drivers` (and stamps `CHANGELOG.md` for a release),
merge, the drift workflow opens the deploy issue, `deploy.py start`, the
Windows session installs, `deploy.py done`.

## 7. Observed state and the deploy tool: `tools/deploy.py`

Standard library only; GitHub through `gh` (`gh api`, `gh release
download`, `gh issue`, and for provenance `gh attestation verify`, which
needs gh 2.102.0 or newer); the repository from `gh repo view` or `--repo`.
Exit codes: 0 success or in sync, 1 error, 3 drift, 2 usage.

- `validate [--online]`: section 6.
- `start [--tag TAG] [--supersede] [--note TEXT] [--no-attestation]`:
  refuses while `deploy/house.yaml` says `release: none` (the desired state
  leads). Downloads `manifest.json` and `SHA256SUMS.txt` of the release
  (default: the file's `release`), then every package the manifest names,
  into a fresh `build/release/<tag>/`, after checking that the file's
  `drivers` are exactly those packages; verifies every sha256 against both
  files, that the manifest's build is the file's `build`, its commit the
  tag's and `dev` not true; checks that each package's provenance
  attestation exists and names its digest, then that it verifies and was
  signed by this repository's Release workflow (`gh attestation verify
  <file> --repo <o>/<r> --signer-workflow
  <o>/<r>/.github/workflows/release.yml --format json`, and the signer
  checked again from gh's answer). It refuses a gh older than 2.102.0 (2.51
  to 2.101 match only the start of the workflow path, GHSA-wjmr-j3rp-mh2g),
  a failed or empty verification, and a deployment of `house` still
  `in_progress`, `pending` or `queued` unless `--supersede` marks it
  `inactive`. `--no-attestation` accepts a package that has no attestation
  at all (a release the workflow did not cut), never one whose attestation
  fails. Then it creates the GitHub Deployment (`ref` the tag, environment
  `house`, `auto_merge: false`, `required_contexts: []`,
  `production_environment: true`, payload `tag`, `build`, `commit`,
  `packages` {name: sha256} and `note`), writes `deployment.json` before
  anything else can fail, sets the status `in_progress`, and writes
  `BRIEF.md` for the Windows session: the download URLs of the release, the
  PowerShell that fetches them into `C:\c4-mf\drivers\<tag>\` and checks
  each sha256 with `Get-FileHash`, the Composer steps (Driver ▸ "Add or
  Update Driver or Agent…", every package at once, every device updated in
  place, never deleted and re-added), the owner's standing approval, the
  reboot from System Manager that a `<capabilities>` change needs, what to
  read back (every device's `Driver Version` and `Debug Mode`) and the
  provenance. `--note` is quoted in the brief, for example "changes
  `<capabilities>`: the owner reboots the controller from System Manager
  after the install".
- `done [--devices N] [--note TEXT] [--deployment ID] [--tag TAG]`:
  re-reads the release's manifest and refuses when its build or packages
  changed since `start`; sets the status `success` ("Driver Version N on N
  devices, settings as deploy/house.yaml") and runs the drift logic, which
  closes the deploy issue.
- `failed --note TEXT [--deployment ID] [--tag TAG]`: status `failure` with
  the note (what the session saw, which build the house still runs); the
  open deploy issue gets the note as a comment and stays open.
- `record [--tag TAG] --build N --at TIME --note TEXT [--no-manifest]
  [--commit SHA]`: a success deployment for an install made without
  `start` (a `--dev` build for the dev loop, a feature-branch build for a
  hardware test, any out-of-band install), `payload.recorded: true` and the
  install time in `payload.installed_at`. It refuses a build the release's
  manifest does not carry unless `--no-manifest`. A build that no release
  carries, before the first release say, takes `--no-manifest` and
  `--commit SHA` without `--tag`: the deployment then names that commit,
  which GitHub must have.
- `status`: desired (the file) against observed (the newest deployment of
  `house` whose latest status is `success`); exit 0 when tag and build
  agree, or when the file says `release: none` and nothing is recorded ("in
  sync: no release installed yet"), 3 on drift.
- `drift [--issue]`: `status` plus the online manifest check; `--issue`
  keeps the deploy issue (section 7.1). `.github/workflows/drift.yml` runs
  `python3 tools/deploy.py drift --issue`.

Private data never leaves the VM: every `--note`, and every brief before it
is written, is refused when it holds an address in the house subnet, any
other IPv4 address that is neither a placeholder nor a textbook example
(192.168.x.x included), a MAC address or a Modern Forms client id outside
the documentation range, an e-mail address outside the documentation
domains, or a cloud identity id. The rules are those of
`tools/gh-discussion.py` (a unit test compares them), which beyond them lets
GitHub's and the commit trailers' noreply senders through; the placeholders
are those of [`scaffold-design.md`](scaffold-design.md), section 2. A
refusal names the kind of data and its line, never the data.

### 7.1 Drift logic

Desired: `release` and `build` of the file on `main`. Observed: the newest
`success` deployment's payload (`tag`, `build`); none recorded is a state of
its own. With `--issue` the tool keeps at most one open issue labelled
`deploy`, recognised by its title alone: `Deploy vX.Y (build N) to the
house` or `Deploy vX.Y-beta.N (build N) to the house`. Another issue that
merely carries the label is never edited or closed.

| Desired | Observed | Exit | The deploy issue |
| --- | --- | --- | --- |
| a release | the same tag and build | 0 | every open one closed with "Build N (tag) recorded as deployed: <deployment>" |
| a release | none, or another tag or build | 3 | opened when none is open; when one with another title is open, retitled with a comment "desired state changed"; left alone when current. A second open one is reported, never touched |
| `none` | none | 0 ("no release installed yet") | none opened; an open one (from a desired release never installed) closed with "nothing to deploy" |
| `none` | an install | 3 | none opened: the issue names a release to install, and there is none. A warning says to set the desired state to the release the house runs |

The issue's body says what is desired and observed, links the release and
the environment, gives the commands, and reminds that the Composer click is
the Windows session's and that a `<capabilities>` change needs the
controller rebooted from System Manager. Closed issues are never reopened,
edited or deleted. Adding the issue to the project board needs a user token,
so the coordinator does it (`gh project item-add 2 --owner corytron --url
<issue>`).

`.github/workflows/drift.yml` runs on a push to `main` that changes
`deploy/house.yaml`, on `deployment_status` (the statuses `deploy.py`
posts), weekly (Monday 06:30 UTC) and on request, with `contents: read`,
`issues: write` and `deployments: read`, always on `main`'s copy of the
file. Exit 3 is the report the run exists to make, not a failure; exit 1 (an
invalid file, GitHub unreachable, a release without a manifest, drivers that
are not the release's) fails the run.

## 8. Repository policy

Set by the coordinator through the API:

- Branch protection on `main`: the four job names of section 4 required,
  the branch up to date before merging, administrators included, no force
  pushes, no deletion. Default workflow token read-only; workflows cannot
  approve pull requests. Dependabot security updates and CodeQL's default
  setup on; the tag ruleset of section 5.3.
- Labels: `.github/labels.json`, applied by `.github/workflows/labels.yml`
  (`tools/labels_sync.py`) on a push that changes it and on request: labels
  created and updated, never deleted (a deleted label loses its history on
  every issue). `deploy` is the drift issue's label.
- `.github/dependabot.yml`: the pinned actions and the hash-pinned Python
  check tools, weekly, with a seven-day cooldown, labelled `dependencies`.
  `.github/workflows/dependabot-auto-merge.yml` enables auto-merge on
  Dependabot's action-pin updates only, so they merge once the required
  checks pass; nothing else is ever auto-merged.

## 9. Automation decisions

| Automation | Decision | Why |
| --- | --- | --- |
| CI checks on every pull request and push | automatic | read-only, reproducible |
| Merging a pull request | by the coordinator after green checks; auto-merge only for Dependabot's action pins | review stays human |
| Building and publishing a release | automatic on a tag push or a dispatch, from `main` only | a release is a decision, the build is not |
| Moving a release tag | an explicit dispatch or tag push, never on merge; prerelease tags never move | |
| Installing on the house | **never automatic**: `start` records the intent and prepares, the Windows session installs, `done` or `failed` records the result | no install API; a wrong install needs hands to undo |
| The deploy issue | automatic open, update and close of one issue; never reopened, deleted or edited once closed | a record, not an actor |
| Labels | automatic create and update; never delete | |
| Scorecard, CodeQL, the code scanning issue | automatic reports; an alert is never dismissed automatically | a dismissal is a decision with a reason |

Corner cases decided:

- A release tag moves while a deployment is `in_progress`: `start` of the
  new build refuses until `done`, `failed` or `--supersede`.
- The release's files are replaced after `start`: `done` re-reads the
  manifest and refuses a changed build or package.
- `deploy/house.yaml` names a build or drivers the release does not carry:
  `validate --online`, `drift` and `start` fail (CI's offline check cannot
  know).
- The Windows session cannot install: `failed`; the deploy issue stays
  open with the note.
- A GitHub error after the deployment is created: `deployment.json` is
  written first, and `done --deployment ID` or `failed --deployment ID`
  finishes it.
- A package signed by another workflow, or a gh too old to tell: `start`
  refuses before the deployment exists, `--no-attestation` or not.
- `deploy/house.yaml` says `release: none`: `start` refuses; `done` and
  `failed` need `--tag` or `--deployment`; `record` records what was
  installed, which is then drift without an issue (section 7.1).
- A build installed before any release exists (the dev loop on the house):
  `record --no-manifest --commit SHA` without a tag; the house then shows
  as off its desired state until a release is installed.
- `deploy/house.yaml` set back to `none` after an install: drift without an
  issue, reported by `status` and the drift run's log. Removing the drivers
  from the house has no record in this tool; it is a Composer change for the
  Windows session, decided by the owner.

## 10. From `release: none` to the first install

1. The v1 driver is merged; the owner approves the codename of 1.0, and a
   pull request adds it to `.github/codenames.json`.
2. Prereleases (`1.0-beta.N`) may go to the house and a tester first; each
   install on the house is a desired-state pull request and
   `start`/`done`, as for a release.
3. The Release workflow cuts `v1.0` ([`release-checklist.md`](release-checklist.md)).
4. A pull request sets `deploy/house.yaml` to `release: v1.0`, `build:` its
   build, `drivers:` its packages, and stamps `CHANGELOG.md`; on its merge
   the drift workflow opens `Deploy v1.0 (build N) to the house`.
5. `deploy.py start`, the brief to the Windows session, which installs and
   reads back; `deploy.py done --devices N` closes the issue, the
   environment page lists the deployment, and `deploy.py status` exits 0.
   [`status.md`](status.md) then says what runs on the house.
