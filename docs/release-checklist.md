# Release checklist: what a build must pass before it is called good

The owner's rule: after any code change that is more than a text, test for
functional regressions on the dev loop **and** on the real system before the
code is called good. The passes, in this order: section 0 on the VM,
section 1 on the dev loop when the change is tried on the house before its
release, section 2 when the release is installed, section 3 with the owner,
and section 4 once after each controller OS upgrade. Every line is a check
with its expected result. Results go into the build's issue (hardware
findings as comments), and [`status.md`](status.md) sums them up. The
exact property names, actions and texts are in
[`composer-checklist.md`](composer-checklist.md), section by section; this
page says which of them a release needs.

The page was written on 2026-10-27 with the scaffold (#1), from the Hue
project's release checklist
([corytron/c4-hue-driver](https://github.com/corytron/c4-hue-driver),
`docs/release-checklist.md`), and has followed every release since. The
house's own record is short: 1.0 was released on 2026-11-05 after the
owner's own test of beta.3 on the house (#58), and the owner released the
two fixes that followed (#59, #49) untested on the hardware. Since then
several features shipped at the owner's word before their hardware checks
ran (1.2's Breeze, 1.4's night brightness, 1.5's fades, 1.8's Min On);
what is still unchecked is listed under "Open" in [`status.md`](status.md#open).

The page then covers the release itself: how it is named ("Naming"), cut
("How a release is cut"), brought to the house ("Deploy to the house") and
put in a tester's hands first ("Prerelease").

## 0. On this VM

- `tools/check.sh --strict --only lua-lint lua-test shell python-lint
  python-test xml workflows secrets house changelog links` passes (every
  check but `powershell`, which needs `pwsh`; CI runs that one): `luacheck
  src tests tools` clean, `busted tests` green, the shell and Python tooling
  clean, every `driver.xml` well-formed, the workflows clean under
  actionlint and zizmor, gitleaks clean over the tree and the history of
  every local ref (branches, tags, stashes, remote-tracking refs: on the VM
  the check reads `git log --all`, so a stale ref holding old history fails
  it until it is removed), `deploy/house.yaml` valid, `CHANGELOG.md` valid
  (with a meaning for every codename) and every link resolving.
  `tools/setup-checks.sh` first if a tool is missing.
- `tools/build.sh` (release) and `tools/build.sh --dev`: no release package
  holds `common/devloop.lua`, `common/devkey.lua` or `fan/devcmds.lua`, and
  no release `driver.xml` a `DEV-ONLY` block (`tools/build.sh` refuses to
  package a release stage that still has one). Each dev package has the dev
  loop, carries the dev key as `common/devkey.lua` and is written 0600.
- Every build makes two packages, one per `src/*/driver.xml`:
  `modernforms_fan.c4z` and `modernforms_breeze_fan.c4z` (1.2 made
  `modernforms_breeze.c4z` in the second's place, 1.0 and 1.1 the first
  alone). `build/manifest.json` names the build, the commit, `"dev": false`
  or `true`, and each package's checksum and size.
- The fan package shows six actions (`unzip -p build/modernforms_fan.c4z
  driver.xml | grep -c '<action>'` is 6, `Add Breeze Fan` last; 1.2's sixth
  was `Add Breeze Switch`); the Breeze fan's package has none.
- `unzip -l build/<driver>.c4z` lists `LICENSE` and `NOTICE` in every package
  (Apache 2.0 §4), and `unzip -p build/<driver>.c4z www/documentation.html |
  grep -c '<!-- CHANGELOG -->'` is 0: the Documentation tab ends with the
  changelog rendered in place of its marker line.
- No LAN address, MAC address, fan client id, account e-mail, room or
  project name, key or certificate in `src/`, `docs/`, `tools/`, `tests/`:
  the `secrets` check (gitleaks with `.gitleaks.toml`) covers the tree and
  the history; the placeholders of [`scaffold-design.md`](scaffold-design.md),
  section 2 (fan 10.0.2.151, controller 10.0.2.10, MAC 00:00:5e:00:53:01,
  client id MF_00005E005301), RFC 7042's documentation range of MACs, and
  e-mail addresses at example.com, example.net or example.org are the only
  ones allowed (`.gitleaks.toml` names every exception and why).

## 1. Dev loop on the house (a dev build)

When a change is tried on the house before its release (most features
since 1.4 were: Breeze on the LEDs, the fades, the speed chase), build the
`--dev` packages with `tools/build.sh --dev` from the commit under test and
install them through the Windows session the way `CLAUDE.md` (Deploy)
describes for a dev build: `tools/build.sh --dev` puts each package alone
under a random path in `build/serve/`, served on port 8091 (`python3 -I -m
http.server 8091 --bind <VM LAN address> --directory build/serve`; never
`build/release/`, #214), briefed with the URL path and their sha256, recorded afterwards with `python3 tools/deploy.py
record ... --no-manifest` ("Deploy to the house" below), and the HTTP server
stopped once the install is done. `tools/devserver.py` running (port 8081),
the fan item's `Dev Server` row set to the `host:port` it prints, and
`tools/devctl.py status` showing the driver polling
([`dev-loop.md`](dev-loop.md)). Then:

1. `tools/regress.sh`: the dev loop itself (the server answers, one device
   polls with the right key and runs the local tree), a property read-back
   through a signed command, and no error, traceback, refusal or failed
   reload in the last 400 lines of the shipped log.
2. `tools/regress.sh --fan` moves the fan and its light, so it is opt-in:
   the fan's own pass F1 to F9 of
   [`v1-design.md`](v1-design.md#12-dev-loop-actions-and-toolsregresssh)
   (section 12), through the signed development commands: every speed,
   off, the toggle and cycle links, the light's targets and its top button,
   then the fan and the light as F1 found them. Each request reaches the fan
   once and its answer reaches the proxies.
3. A change made with the Modern Forms app, the remote or the wall control
   reaches Control4 within the poll interval (15 s, 2 s for 20 s after a
   change), never as a late or out-of-order report.
4. The fan without power (its wall switch off): the driver reports it
   offline after about 45 s and recovers on its own when the power returns;
   a new address of the same fan is followed, not taken for a new fan
   ([`composer-checklist.md`](composer-checklist.md), steps 39 to 45).
5. The feature's own hardware checks, from its contract and its section of
   the Composer checklist.
6. No error line in the log through the whole session.

A release install ends the dev loop. Longer runs (an hour idle, a night) are
not part of this checklist: nothing that needs more than about a minute of
waiting blocks a build, and questions only time answers are parked for the
next major release (`CLAUDE.md`, "No long test waits").

## 2. Release build on the house (Windows session, Composer)

Install the release files from the GitHub release through `tools/deploy.py
start` and the brief it writes ("Deploy to the house" below); no "Restart
Director?" unless a capability changed (then the owner reboots the
controller from System Manager). The first install of the driver in a
project is not an update: the new device goes beside the stock WAC device,
which is then replaced by hand, as the manual's chapter "Moving from the
stock WAC driver" says
([chapter 4](../src/modernforms_fan/www/documentation.html#stock)) (`CLAUDE.md`, Scope); the house's own cutover of 2026-11-04 is recorded
in [`migration-design.md`](migration-design.md). Every later install is an
update in place ([`composer-checklist.md`](composer-checklist.md), step 2).
Read:

1. `Driver Version` on every Modern Forms Fan device and every Modern
   Forms Breeze Fan device = the build; `Debug Mode` reads Off on every
   device (a dev-loop session often leaves it On, and Director keeps the
   value through the release install). (A 1.2 Breeze switch, while one
   still existed, kept build 115, the last that made its package.)
2. The Properties page: no development-only rows (those between the
   `DEV-ONLY` markers of `driver.xml`: `Dev Server`, `Dev State`). On the
   fan item 37 rows while a button is bound to a Fan Speed link, 16 without
   one (the 21 keypad LED rows hidden); on the Breeze fan 3 rows
   ([`composer-checklist.md`](composer-checklist.md), steps 8 and 88). A
   row new in the release reads its default, except where the brief sets it.
3. The Actions tab: the six actions section 0 counts; none on the Breeze
   fan.
4. The Documentation tab opens, shows the manual and ends with the
   changelog.
5. The Lua tab of each device during the install: no `[ERROR]` line.
6. Connections, after the update in place: the fan's own Button Links (the
   speed, Off, Toggle, Cycle and Fan Breeze links) and the light's links
   with every keypad binding; each Breeze fan still bound to its fan's
   `Breeze Switch` output (the output kept its 1.2 name); and since 1.9 a
   keypad's Ambient Light Level (Source) still bound to the fan's Ambient
   Light Level (Follower) where it was bound
   ([`composer-checklist.md`](composer-checklist.md), sections D to F and O).
7. **The first install of 1.3 or later on a fan with Breeze and no Breeze
   fan yet** (#121): the programming items read back, **Add Breeze Fan**
   clicked once on each fan that has Breeze, the new item placed after its
   fan in the room's order, and File ▸ Refresh Navigators
   ([`composer-checklist.md`](composer-checklist.md), steps 50 and 60 to
   62). No controller reboot: no capability of the fan device changes.
8. **A project still on 1.2, with its Breeze switch** (#121; the house did
   this on 2026-11-08,
   [`breeze-design.md`](breeze-design.md#11-13-ornithopter-fan-mode-breeze-mode-and-the-breeze-fan-121)
   BF-D12; [`composer-checklist.md`](composer-checklist.md) steps 57 to
   63), in this order, every step in the Windows session's brief and the
   delete under the owner's standing approval (said so in the brief):
   (a) list what programming, scenes and agents name the old Breeze switch
   (on the house "Aviator 5 Breeze", driver Modern Forms Breeze), the
   fan item's own programming on its turned-off and speed-changed events,
   which now also runs when Breeze starts (add "Breeze is on" False where
   it should not), and every line that sends Breeze Off or Toggle Breeze,
   which now stop the fan while Breeze blows (the way back to fan mode is
   a speed on the fan item); (b) install both packages at
   once, `modernforms_fan.c4z` in place and `modernforms_breeze_fan.c4z`
   into the library: no "Restart Director?", since no fan capability
   changes and no device uses the new package yet; (c) delete the old
   switch, confirming Composer's prompt; (d) click **Add Breeze Fan** once
   and read `Last Action` (`Breeze fan added: Aviator 5 Breeze`); (e) read
   back the new device: its proxy is a fan (`fan.c4i`; the item shows the
   fan's Preset Level page), `Driver Version` the build, `Status`
   (`Breeze off on Aviator 5` or `Breeze <n> on Aviator 5`), `Debug Mode`
   Off and the binding on the fan's `Breeze Switch` output; (f) move
   "Aviator 5 Breeze" right after the fan in the room's Navigator order
   where Composer allows it; (g) File ▸ Refresh Navigators. No controller
   reboot. The brief also tells the owner that a keypad with no button on
   Fan Breeze shows no steady fan LED while Breeze blows (BF93; lighting one
   means binding a button to Fan Breeze, his choice). `deploy.py done
   --devices` counts the fan and the Breeze fan. The old switch's package
   stays on the v1.2 release. Going back to 1.2 is not designed for: 1.2
   does not carry the Breeze fan's package, and its fan driver sends the
   Breeze fan no strength and ignores the strengths and steps it sends
   (edge-cases-breeze-fan BF6, BF52), so the Breeze fan would be deleted
   and 1.2's switch added again.
9. **A release that brings a new setting the house uses** sets it in the
   brief and reads it back (1.6 set `Speed LED Animation`, 1.8 `Light Min
   On (%)`, 1.9 bound the keypad's ambient output); the values the house
   keeps are under "Settings" in [`status.md`](status.md#settings).

## 3. The owner, on the phone, the keypads and the fan

Each under a minute, when the release changes what they cover
([`composer-checklist.md`](composer-checklist.md) has the steps):

1. Fan: each speed and off from a Navigator tile, from the keypad buttons
   linked to them, and from the Modern Forms app, the remote and the wall
   control; Control4 shows the fan's state at once, whichever was used.
2. Keypad LEDs: with "Follow Connection", only the LED of the active speed is
   lit, and it follows a change made with the app, the remote or the wall
   control (section F).
3. Light: on, off and dimming from the tile and the keypad; a change made
   with the app reaches the tile. Since 1.5 a tap fades over the Click
   Rates and a second tap stops it (section K); since 1.8 the light is lit
   from its first step at Control4's 1 % (section N).
4. Keypad taps and holds on every bound button: a press acts once at the
   push, a hold is one action, a double tap acts twice and still fires the
   keypad's own Double Tap event (sections D and E).
5. Breeze (#111; since #121 the Breeze fan): on the phone, the Breeze fan is
   listed by the fan; Breeze 1, 2, 3 and off each work; the main fan shows
   off while Breeze blows; a fan speed on the main fan ends Breeze
   ([`composer-checklist.md`](composer-checklist.md), step 62; step 53 for
   the switch of 1.2).
6. The LED animations, where the release touches them: the Breeze gusts
   (section J.3), the speed chase (section L), and since 1.9 their pause
   while the bound keypad is dark (section O).

## 4. After a controller OS upgrade

Once per new controller OS version, before a build is called good on it:
sections 1 to 3 on the new OS, with the keypad lines of section 3 in full.
Check in particular what rests on measurement rather than on the SDK
documents: the keypad's push, click and release timings the links are
built on (K6, K7), the keypad LED rows hiding in Composer (#178), the Click
Rates loading only after a reboot (#141), and since 1.9 the keypad's
Ambient Light Level (Source) reaching the fan's Ambient Light Level
(Follower), whose class and command are in no SDK document (#207). The
minimum OS stays 3.3.0 whatever the house runs. Note the OS version and the
result in the build's issue and in [`status.md`](status.md).

A build passes when every line reads as expected; anything else becomes an
issue naming the build number ([`status.md`](status.md) "Open" points at
it), and the release waits.

## Naming

A release is a version X.Y, tagged `vX.Y`, with its own codename (owner,
2026-10-27), kept by every build and beta of that X.Y. How names are chosen
is kept out of the repository and out of every public text (owner,
2026-11-08, #128, #130): a title carries the name, nothing more. Before the
first build of a new X.Y its name goes into [`.github/codenames.json`](../.github/codenames.json) (an
object such as `{"1.0": "<name>"}`), which
[`tools/changelog.py`](../tools/changelog.py) and the Release workflow read.
The Release workflow refuses every version whose X.Y the file does not
name, in its first step. The file started empty, `{}`, so nothing was
released before the owner had approved the 1.0 name (approved 2026-10-27,
#6: 1.0 is "Arrakis"); on 2026-11-13 it names 1.0 to 1.9 "Sandwalk".
Every release's and prerelease's notes open with the meaning of its
codename (owner, 2026-11-10, #192): what the name is in its story and, where
it fits, how that ties to what the version changed, one paragraph of at most
450 characters that contains the name, in `.github/codename-meanings.json`
(an object such as `{"1.0": "**<name>** is ..."}`;
[`changelog-design.md`](changelog-design.md#codename-meanings-githubcodename-meaningsjson)).
**Before the first build of a new X.Y, its first prerelease included, the
meaning is written with the codename, in the same pull request**: `tools/check.sh`
(the `changelog` check) fails while an X.Y of `.github/codenames.json` has no
meaning, and the Release workflow refuses such an X.Y in its first step. The
meaning says what the name means and nothing about how it was chosen. The driver files carry the build number,
the commit count, as `Driver Version` (Control4 needs an integer there); it is
named in the release's `manifest.json`, in the release notes (step 4 below)
and in `deploy/house.yaml` (`build:`); the README names no build and links to
the Releases and Environments pages, and [`status.md`](status.md) names the
build it describes. Later builds of the same version move its tag and replace
the attached files (every build of 1.0 moves `v1.0`); when a new version
number starts is the owner's decision.

**How a release is cut** ([`.github/workflows/release.yml`](../.github/workflows/release.yml);
contract [`cicd-gitops-design.md`](cicd-gitops-design.md), section 5):

1. Merge the code into `main`. Nothing is edited for the release itself.
2. Start the Release workflow: on the repository's Actions page, **Release ▸
   Run workflow**, enter the version (`1.0`, `1.1`, ...). The workflow first
   refuses a version whose X.Y has no codename or whose codename has no
   meaning, then builds `main`'s head
   and, once the packages are built and attested, tags it `v<version>`
   itself, force-moving an existing tag, in the same run (a run that fails
   earlier leaves the tag where it was). Pushing the tag by hand (`git tag -f
   -a vX.Y -m "X.Y" <commit on main>`, `git push --force origin vX.Y`) starts
   the same build; a tag that is not on `main` is refused.
3. The workflow's build job lints, tests and builds with read-only access
   and pinned tools; its publish job, which runs no third-party code, checks
   what the build job handed over, signs the provenance and attaches to the
   release of the tag, creating it when missing, with the title and notes
   written from `CHANGELOG.md` (step 4): every package of `manifest.json`
   (`modernforms_fan.c4z` and, since #121, `modernforms_breeze_fan.c4z`;
   1.2 carries `modernforms_breeze.c4z` in its place, 1.0 and 1.1 the first
   alone), `SHA256SUMS.txt`, `manifest.json` (tag,
   version, build, commit, build time, each package's sha256 and size),
   `attestations.sigstore.json`, the signed build provenance, and
   `mf-drivers.intoto.jsonl`, the same provenance as in-toto JSON lines. A
   run for a moved tag replaces every file.
4. The release's title and notes come from [`CHANGELOG.md`](../CHANGELOG.md)
   on every run ([`changelog-design.md`](changelog-design.md)): before
   dispatching, make sure its `## Unreleased` entry lists what this build
   changes (a run with an empty entry fails), and for the first build of a
   new X.Y that the owner has approved its codename and it is in
   `.github/codenames.json`, with its meaning in
   `.github/codename-meanings.json`. When a release changes what the drivers
   are or need, read the "What you get" and "Requirements" of
   [`.github/release-notes.md`](../.github/release-notes.md) against them
   (first done before 1.0, when the scaffold's text was replaced) and keep
   the OS and Composer versions section 2 passed on. Check
   the release page: the assets (six with the two packages since #111, five
   with one before), the title
   `<version> "<codename>"`, the notes' first heading with this build and,
   right below it, the meaning of the codename as their first paragraph. After
   the release, the desired-state PR also runs `python3 tools/changelog.py
   stamp --version X.Y --build N --date YYYY-MM-DD`, so `CHANGELOG.md` names
   the build that was published, and each driver's Documentation tab ends
   with the same list.
5. Nothing is built on the VM for an install: the house gets these same
   files, downloaded from the release by `tools/deploy.py start` (next
   section).

## Deploy to the house

The house installation is run from the repository (contract
[`cicd-gitops-design.md`](cicd-gitops-design.md), sections 6 and 7):
[`deploy/house.yaml`](../deploy/house.yaml) is the desired state, a GitHub
Deployment on the environment `house` is the observed state, and the
Composer click stays with the Windows session and is never automatic, since
the controller has no install API. Until the first install the file said
`release: none` and `build: none` (the house ran the stock WAC driver), and
with no Deployment recorded that was no drift: the drift workflow opened no
issue. Since the first install (v1.0-beta.1, 2026-11-04, deploy issue #30)
it names the release the house should run; on 2026-11-13 that is v1.9,
build 220. For every release:

1. **Say what the house should run.** A pull request edits
   `deploy/house.yaml`: `release:` to the tag, `build:` to the release's
   build number (from its `manifest.json`), `drivers:` to exactly the
   packages of that manifest, `debug_mode: Off`. CI's `house` check
   validates the file offline (`python3 tools/deploy.py validate`;
   `validate --online` also compares `build:` and `drivers:` with the
   release's `manifest.json`); merge the pull request.
2. **The drift issue appears.** On the merge the drift workflow
   ([`.github/workflows/drift.yml`](../.github/workflows/drift.yml)) compares
   the file with the newest successful deployment and opens one issue
   labelled `deploy`, `Deploy vX.Y (build N) to the house`, or updates the
   one already open; it never opens a second. Add it to the project board by
   hand (`gh project item-add 2 --owner corytron --url <issue url>`); the
   workflow's token cannot.
3. **Prepare and record the intent.** On the VM, `python3 tools/deploy.py
   start`, with `--note "changes <capabilities>: the owner reboots the
   controller from System Manager after the install"` when the build changes
   a `driver.xml` `<capabilities>` block, and `--supersede` when an earlier
   deployment is still in progress. It downloads `manifest.json`,
   `SHA256SUMS.txt` and every package the manifest names from the release
   into `build/release/<tag>/`, verifies every sha256 against both files,
   that the manifest's build is the file's and its commit the tag's, and
   that each package's provenance attestation verifies with `gh attestation
   verify <file> --repo corytron/c4-modernforms-driver --signer-workflow
   corytron/c4-modernforms-driver/.github/workflows/release.yml --format
   json`, so the Release workflow and nothing else signed it; it then
   creates the Deployment with status `in_progress` and writes
   `build/release/<tag>/BRIEF.md` (which names the signer and the gh that
   checked it) and `deployment.json`. A build the release does not carry, a
   manifest that says `dev: true`, a package whose attestation fails, and a
   deployment of `house` still in progress (without `--supersede`) are
   refused. The check needs gh 2.102.0 or newer (2.51.0 to 2.101.0 match
   only the start of the workflow path, GHSA-wjmr-j3rp-mh2g), and `start`
   refuses an older one; the VM has gh 2.103.2 (2026-10-27).
4. **Send the brief.** `BRIEF.md` goes to the Windows Composer session as it
   is ([`composer-remote.md`](composer-remote.md)): the GitHub download URL
   and sha256 of every file, the PowerShell that fetches them into
   `C:\c4-mf\drivers\<tag>\` and checks them with `Get-FileHash`, the
   Composer steps (Driver ▸ Add or Update Driver or Agent…, every package at
   once, in place, never delete and re-add a device), what to read back, the
   note, and the standing-approval sentence. It carries no LAN address, MAC
   address or client id.
5. **What the Windows session reads back.** Every device's `Driver Version`
   equals the build (the Breeze fans included, since #121, as the Breeze
   switches were from #111); `Debug Mode` and the other properties the v1 contract
   names match `deploy/house.yaml`; no `[ERROR]` line in a device's Lua tab
   during the install; and whether Composer asked "Restart Director?". If it
   did, the build changed capabilities: answering Yes loads nothing, the
   owner **reboots the controller from System Manager** (it runs elevated;
   the Windows session cannot operate it), and the session reads `Driver
   Version` again afterwards.
6. **Record the result.** `python3 tools/deploy.py done --devices <count>`
   (every device read back, a Breeze fan counting as one; with `--note`
   for anything worth keeping) re-reads the release's
   manifest, refuses when its assets changed since `start`, sets the
   deployment to `success` and closes the deploy issue with a comment
   naming the deployment; `python3 tools/deploy.py failed --note "<what the
   session saw; which build the house still runs>"` sets it to `failure`
   and adds the note to the deploy issue, which stays open. Both read
   `build/release/<tag>/deployment.json`; `--deployment ID` names the
   deployment instead.
7. **Check.** `python3 tools/deploy.py status` exits 0 when desired and
   observed agree (3 on drift, 1 on an error), and the `house` environment
   on the
   [Environments page](https://github.com/corytron/c4-modernforms-driver/deployments/house)
   lists every install, newest first. [`status.md`](status.md) and the
   README point there rather than naming the build.

An install made any other way is recorded after the fact with `python3
tools/deploy.py record --tag vX.Y --build N --at <ISO 8601 time with
offset, such as 2026-11-02T21:04:00-05:00> --note "..."`, so that the
observed state stays true. A build the release does not carry (a `--dev`
build for the dev loop, a feature-branch build for a hardware test) also
takes `--no-manifest`, and `--commit <sha>` names its commit; the drift
issue then shows the house off its desired state until a release is
installed again (`CLAUDE.md`, Deploy).

## Prerelease

A prerelease puts a build in a tester's hands before the release that
carries it (contract [`prerelease-design.md`](prerelease-design.md)). It is
built, checked, attested and published as a release is ("How a release is
cut" above), from `main` only. What differs:

1. **Version and tag.** `X.Y-beta.N`: `X.Y` is the version still to come,
   later than every version in `CHANGELOG.md`, and `N` counts from 1, a new
   number for every build a tester gets. Start the Release workflow with that
   version (Release ▸ Run workflow ▸ `1.1-beta.1`): it tags `main`'s head
   `v1.1-beta.1`. The tag never moves, so a version whose tag exists fails
   before anything is built; take the next `N`. A prerelease carries its
   X.Y's codename from `.github/codenames.json`, and its notes open with the
   meaning from `.github/codename-meanings.json`; a new X.Y needs both there
   first, or the workflow refuses it. A prerelease may come before the
   first release, as `1.0-beta.N` (1.0's name approved first): its notes then
   follow no release, and they send a tester back to the stock WAC driver
   rather than to release files
   ([`prerelease-design.md`](prerelease-design.md#7-a-prerelease-before-the-first-release)).
2. **Changelog.** Nothing changes in `CHANGELOG.md`: the notes come from the
   same `## Unreleased` entry, which holds everything since the last release,
   and a prerelease is never stamped (`changelog.py stamp` refuses one); the
   release lists it all later. An empty `Unreleased` fails the run, as for a
   release.
3. **What GitHub shows.** The release is marked Pre-release and never Latest,
   so `releases/latest` and the README's download links keep serving the
   release (before 1.0 they have none to serve). Check the title, `1.1 beta
   1 "<codename>" (build N)`, the Pre-release mark, and the assets: every
   package, `SHA256SUMS.txt`, `manifest.json` and the two provenance files.
   The notes come from
   [`.github/prerelease-notes.md`](../.github/prerelease-notes.md): the
   meaning of the codename, what it is, the release it follows (or that there
   is none yet), the changes, how
   to install, how to go back, where to report, how to verify, the license.
4. **Feedback.** The tester gets the release page's link. Reports come
   through the "Beta feedback" issue form
   ([`.github/ISSUE_TEMPLATE/beta-feedback.yml`](../.github/ISSUE_TEMPLATE/beta-feedback.yml),
   label `beta-feedback`); feedback that arrives another way is filed with
   the same form, with "Reported another way" filled in. A fix is an
   ordinary pull request, then the next beta number.
5. **The house**, when it runs the prerelease too: a desired-state pull
   request sets `deploy/house.yaml` to it (`release: v1.1-beta.1`, its
   build, and `drivers:` exactly the packages of its `manifest.json`), then
   "Deploy to the house" above runs as for a release: the drift issue reads
   `Deploy v1.1-beta.1 (build N) to the house`, and the brief says it is a
   prerelease. Going back to the release is another desired-state pull
   request; before 1.0 the way back is the migration's rollback to the stock
   WAC device ([`migration-design.md`](migration-design.md#6-going-back)), which the Windows
   session does.
6. **The release.** When testing is done, cut `X.Y` itself ("How a release
   is cut"): its notes carry the same `Unreleased` entry, and its
   desired-state pull request stamps `CHANGELOG.md`.
