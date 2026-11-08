# Modern Forms Fan driver for Control4

[![CI](https://github.com/corytron/c4-modernforms-driver/actions/workflows/ci.yml/badge.svg)](https://github.com/corytron/c4-modernforms-driver/actions/workflows/ci.yml)
[![Release](https://github.com/corytron/c4-modernforms-driver/actions/workflows/release.yml/badge.svg)](https://github.com/corytron/c4-modernforms-driver/actions/workflows/release.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/corytron/c4-modernforms-driver/badge)](https://securityscorecards.dev/viewer/?uri=github.com/corytron/c4-modernforms-driver)
[![Changelog](https://img.shields.io/badge/changelog-CHANGELOG.md-blue)](CHANGELOG.md)
[![License](https://img.shields.io/github/license/corytron/c4-modernforms-driver)](LICENSE)

**Documents:** [Changelog](CHANGELOG.md) · [Current state](docs/status.md) ·
[Design notes](docs/README.md) · [Contributing](CONTRIBUTING.md) ·
[Security policy](SECURITY.md) · [Code of conduct](CODE_OF_CONDUCT.md) ·
[License](LICENSE) and [notice](NOTICE)

> **1.1 "Jamis" is the latest release:**
> [get the latest release](https://github.com/corytron/c4-modernforms-driver/releases/latest).
> It is a personal project, tried on one fan (a Gen 3) and one controller;
> [`docs/status.md`](docs/status.md) says what runs there and what is open.

An independent Control4 DriverWorks driver for Modern Forms smart ceiling
fans with an integrated light, working over the fan's own local network
interface. One `.c4z` driver, **Modern Forms Fan**, makes the fan and its
light ordinary Control4 devices: a fan with its speeds and a dimmable light
that you switch, dim, program in Composer Pro and bind to keypads like any
other fan and light.

A personal project for one Control4 home. It is not affiliated with,
endorsed by or supported by Modern Forms, WAC Lighting or Snap One
(Control4); see
[License, trademarks and provenance](#license-trademarks-and-provenance).

## Why a new driver

The fan in the author's house runs on the stock driver,
`wac_mf_fan_and_light_controller(v4).c4z`. That driver declares 12 Button
Link connections (Fan Off, Fan Speed 1 to 6, Toggle Preset, Cycle Speed, and
the light's Top, Bottom and Light Toggle), and in a hands-on test on
2026-10-27 (controller on OS 3.4.3, Composer Pro 3.4.2) none of them did
anything in either direction: a keypad button bound to one changed nothing
when pressed, and its LED never showed the fan's or the light's state. The
house gets by with keypad programming instead: button scripts that set the
speeds, LED scripts, and a one-second Timer agent that lets the driver's
late and out-of-order speed reports settle before the LEDs are set. This project is
the replacement: Button Links that work in both directions, and state that
arrives in order.

## What it does

The driver's **Documentation** tab in Composer is the full manual (see
[Install in Composer Pro](#install-in-composer-pro)); this is the short
version.

- **The fan.** A Control4 fan with six speeds, named **Level 1** to
  **Level 6** as the stock driver names them, off, and forward and
  reverse. On and Toggle turn it on at the **Preset Level** (Level 3 until
  you change it). It works from the Navigators, programming and keypads.
- **The light.** The fan's light is a Control4 light (the `light_v2`
  proxy) with on, off and dimming from 1 to 100 %. It turns on at the
  **Default On Brightness**. It cannot fade and has no colour.
- **Button Links that work.** Twelve Button Links of the driver's own:
  **Fan Off**, **Fan Speed 1** to **Fan Speed 6**, **Fan Toggle** and
  **Fan Cycle**, and the light's **Light Top**, **Light Bottom** and
  **Light Toggle**. A bound keypad button acts when pressed, and its LED
  follows the fan or the light: it shows the target at once and is
  corrected if the fan does something else. A hold on a light link
  brightens or dims the light, and a keypad's Up and Down buttons can be
  bound to **Light Top** and **Light Bottom**.
- **Double taps.** A double tap stays keypad programming. For a button
  whose double tap sets another speed, **Speed 1 Link Also Lit At** to
  **Speed 6 Link Also Lit At** keep its LED lit at that speed too.
- **A colour per speed.** Set **Speed LED Colors** to `Per speed`, and a
  speed link shows **Speed 1 LED Color** to **Speed 6 LED Color** while
  the fan runs at that speed and **Speed LED Off Color** when it is dark:
  for example blue at Level 1 and orange at Level 6. By default
  (`Keypad's own`) the keypad's own colours stay.
- **Finding the fan.** The driver looks for Modern Forms fans on the
  controller's own network by itself, a few seconds after it starts and,
  while the device has no fan yet, on a schedule, and lists them in
  **Found Fans**. Pick the fan there and click **Set**, or type its IPv4
  address in **Fan Address**. The driver never takes a fan by itself. It
  learns the fan's identity at the first contact and sends nothing to a
  different fan that answers at that address until **Use Selected Fan**
  accepts it. **Status** and **Last Action** say what the driver sees.
- **The fan's name.** **Fan Model** shows the product name, for example
  Aviator 5, looked up from the model number the fan reports, and whether
  the fan has Breeze. **Use Selected Fan** (and a pick in **Found Fans**
  that takes a fan) names the fan and light items after it while they
  still have their original names; the action **Name Items After Fan**
  names them whatever they are called. Nothing else renames them.
- **A new address.** When the router gives the fan a new address, the
  driver finds it again by itself, usually within a minute or two: it
  checks that the fan answering there is the one it learned, rewrites
  **Fan Address** and says so in **Last Action**. This works on the
  controller's own network segment. **Follow Address Changes** (On by
  default) turns it off.
- **Live state.** Changes made with the Modern Forms app, the remote or
  the wall control show up in Control4, in order: on the Navigators, in
  programming events and on the keypad LEDs. The fan reports nothing by
  itself, so the driver asks it every 15 seconds (**Poll Interval (s)**),
  and every 2 seconds for 20 seconds after any change. **Last Change By**
  says who changed the fan when it was not Control4.
- **Offline and back.** When the fan stops answering, **Status** says so,
  the last state is kept and the event **Fan Offline** fires; **Fan
  Online** fires when the fan answers again. Nothing old is re-sent to
  the fan. Programming also gets the variable **Online** and the condition
  **Fan is online**.
- **Local only.** The driver talks only to the fan on your own network,
  never to the vendor's cloud, so Control4 keeps working when that cloud
  is down. The private details the fan hands out, such as the owner's
  e-mail address and the Wi-Fi name, are dropped the moment they arrive.
- **Moving from the stock driver** is done by hand in Composer, as the
  Documentation tab describes
  ([Install in Composer Pro](#install-in-composer-pro)); no action of the
  driver does it.

Control4 stays the source of truth: the driver reports what the fan does
and never fights it. It does not set or clear the fan's own schedules,
timers, Away mode or adaptive learning; it shows them in **Fan
Automations** and offers two clicks, **Turn Off Away Mode** and **Turn Off
Adaptive Learning**. It never adds, moves or deletes a Control4 device and
never changes keypad programming. Automations belong in Control4
programming.

## What you need

- **A controller on OS 3.3.0 or newer**, and Composer Pro. The driver
  declares that minimum, and Composer Pro refuses to add it to an older
  controller. It has been tried on OS 3.4.x only; OS 4.x has not been
  tried.
- **A Modern Forms fan of generation 1, 2 or 3 with six speeds**, set up
  on your Wi-Fi with the Modern Forms app. A fan without the light kit
  works as a fan only. A generation 4 fan is refused, and fans with fewer
  than six speeds are not supported.
- **A network that joins them.** The controller must reach the fan (it
  answers on port 80). The search that fills **Found Fans** and following
  a new address use multicast DNS, which stays on the controller's own
  network segment; a typed address works wherever the controller can reach
  the fan.
- **A fixed address is recommended, not required.** A DHCP reservation in
  your router keeps the fan's address from moving; without one, the driver
  follows the fan to its new address. The **Fan ID** row shows the MAC
  address to reserve.
- **One device per fan, and nothing else asking it all day:** not the
  stock WAC driver once you have moved, another controller, an integration
  or the Modern Forms app left open on a phone. These fans are reported to
  slow down or freeze when several clients ask at once.

**What it was tried on.** One Gen 3 fan, an Aviator 5, with its light, on
one controller running OS 3.4.3 and managed with Composer Pro 3.4.2. The
prereleases have run the author's house since 2026-11-04, and the owner's
tests there passed: keypad presses, the LEDs following the fan in their
per-speed colours, the double taps, the light's Up and Down buttons, and
following the fan to a new address. No Gen 1 or Gen 2 fan has been tried,
and following a new address relies on an answer seen from Gen 3 fans
only.

## Get it

Releases are on the
[Releases page](https://github.com/corytron/c4-modernforms-driver/releases),
numbered `X.Y` and tagged `vX.Y`. The newest is always at
[releases/latest](https://github.com/corytron/c4-modernforms-driver/releases/latest),
and its driver downloads directly from
[`releases/latest/download/modernforms_fan.c4z`](https://github.com/corytron/c4-modernforms-driver/releases/latest/download/modernforms_fan.c4z).
Each X.Y carries its own codename from Denis Villeneuve's *Dune* films, a
major name for an X.0 and a lesser one for a point release: 1.0 is
"Arrakis", 1.1 is "Jamis". Prereleases for testers (`X.Y-beta.N`) are marked
**Pre-release** and never **Latest**, so the links above skip them. What
each release changed is in [`CHANGELOG.md`](CHANGELOG.md), which each
release's notes and the end of the driver's Documentation tab repeat.

Every release is built and attached by the repository's Release workflow
([`release.yml`](.github/workflows/release.yml)) from `main`, never by hand,
and carries the driver `modernforms_fan.c4z`, `SHA256SUMS.txt` (its
checksum), `manifest.json` (what was built: the tag, the build number that
Composer shows as **Driver Version**, the commit, and each package's
`sha256` and size) and the build-provenance attestations. To check a
download:

```sh
sha256sum -c SHA256SUMS.txt
gh attestation verify modernforms_fan.c4z --repo corytron/c4-modernforms-driver \
  --signer-workflow corytron/c4-modernforms-driver/.github/workflows/release.yml   # GitHub CLI 2.102.0 or newer
```

The second command confirms that the file was built and signed by this
repository's Release workflow, and fails otherwise.

## Build from source

[`tools/build.sh`](tools/build.sh) packages the driver with Snap One's
public driver packager, which you clone yourself (nothing of Snap One's is
vendored here):

```sh
git clone https://github.com/snap-one/drivers-driverpackager ~/c4-tools/drivers-driverpackager
tools/build.sh          # -> build/modernforms_fan.c4z, build/manifest.json
tools/build.sh --dev    # development build: dev loop, Lua command window, the dev key; never install or share it as production
```

It needs bash, a full clone of this repository (the build number is the
commit count, so a shallow clone stamps the wrong one), Python 3 and `lxml`,
which the packager imports (`python3-lxml` on Debian and Ubuntu); set
`DP3=/path/to/dp3/driverpackager.py` if the packager lives elsewhere. CI and
the Release workflow fetch the packager at commit
`16eef8beb70303606f066524cda516b2aa7ce38d`. Every package carries the
`LICENSE` and `NOTICE` files. A release build leaves out the development
modules and the `DEV-ONLY` parts of `driver.xml`, and `tools/build.sh`
refuses to package one that still has them. Lint and tests run on Lua 5.1
with `luacheck`, `busted` and `dkjson` from luarocks (the versions CI pins
are in [`.github/workflows/ci.yml`](.github/workflows/ci.yml)); the specs run
the driver against a fake DriverWorks runtime (`tests/helpers/fake_c4.lua`):

```sh
luacheck src tests tools
busted tests
```

[`tools/check.sh`](tools/check.sh) runs these two and every other check CI
runs (shell, Python, XML, PowerShell, workflows, secrets, the house's desired
state, the changelog and the links), and `tools/setup-checks.sh` installs
the tools it needs (ruff, zizmor, shellcheck, actionlint, gitleaks) into
`~/.local/bin` without sudo; [CONTRIBUTING.md](CONTRIBUTING.md) lists the
checks.

## Install in Composer Pro

The driver's **Documentation** tab in Composer
([`src/modernforms_fan/www/documentation.html`](src/modernforms_fan/www/documentation.html))
is the owner's and dealer's manual; its chapter 3 covers adding the fan.
In short:

1. Choose **Driver > Add or Update Driver or Agent...** and open
   `modernforms_fan.c4z`.
2. Add **Modern Forms Fan** (manufacturer Modern Forms) to the fan's room.
   Two items appear: the fan, **Modern Forms Fan**, and under it its
   light, **Modern Forms Fan Light**. Add one device per fan.
3. Point it at the fan: on the fan item's **Properties** tab, pick the fan
   in **Found Fans** (the driver fills the list by itself within about half
   a minute) and click the row's **Set**; or type the fan's IPv4 address in
   **Fan Address** and click the row's **Set**. Within a few seconds
   **Status** reads `Online: ...`.
4. Choose **File > Refresh Navigators**, then bind keypad buttons to the
   driver's links in **Connections** (chapter 5 of the manual).

The rules that hold from then on:

- Update through **Driver > Add or Update Driver or Agent...** as well. An
  update goes **in place** onto every existing device; never delete and
  re-add the device, since its connections, its state and every
  programming line that names it go with it.
- If Composer asks **Restart Director?**, the new build changes the driver's
  capabilities. Answer Yes, then **reboot the controller from System
  Manager** (Tools > System Manager): the new code loads only with the
  reboot. Builds that change only Lua or connections take effect at once.
- Moving a house from the stock WAC driver is done by hand, as
  [chapter 11](src/modernforms_fan/www/documentation.html#ch11) of the
  manual describes: back up the project, add this driver's device beside
  the stock one, move the keypad bindings and the programming over, check
  them, and only then delete the stock device. Until that last step, every
  step can be undone.

## How a change reaches the house

The author's house is the one installation, and it is run from the
repository ([`docs/cicd-gitops-design.md`](docs/cicd-gitops-design.md)):

1. A change is a pull request. Four checks must pass before it can merge:
   *Lint and test (Lua 5.1)*, *Build the .c4z packages*, *Tooling checks
   (shell, Python, XML, workflows)* and *Secrets and private data*; the
   branch must be up to date with `main`.
2. A release is cut from `main` by the Release workflow (Actions ▸ Release ▸
   Run workflow ▸ version, or a pushed `vX.Y` tag on a commit of `main`): it
   lints, tests, builds, and attaches the package, the checksums, the
   manifest and the attestations described above.
3. [`deploy/house.yaml`](deploy/house.yaml) names the release and build the
   house should run. Changing it is a pull request of its own.
4. The `house` environment on the repository's
   [Environments page](https://github.com/corytron/c4-modernforms-driver/deployments/house)
   records what was actually installed. A workflow compares the two and
   keeps one issue labelled `deploy` open while they differ.
5. `python3 tools/deploy.py start` downloads the release, verifies the
   checksums, the manifest and the attestations, records the deployment and
   writes a brief; the author's Windows Composer session
   ([`docs/composer-remote.md`](docs/composer-remote.md)) installs the
   package from the GitHub release URL through *Add or Update Driver or
   Agent...* (the controller has no install API, so this click is never
   automatic); `python3 tools/deploy.py done` records the result, which
   closes the issue.

## Repository layout

```
src/common/          the author's shared Lua modules (log, dispatch, device, devloop), staged into
                     each package as common/
src/modernforms_fan/ the driver: driver.lua, driver.xml, www/ (its Documentation tab) and fan/ (the
                     wire, the state model, the proxies, the links, finding fans, the item names)
tests/               busted specs (spec/), the fake DriverWorks runtime (helpers/), and the fan's
                     answers and multicast DNS announcements, with placeholders (fixtures/)
tools/               build.sh; check.sh (every check, as CI runs it) and setup-checks.sh (its
                     tools); deploy.py (the house: release download and verification, the
                     deployment record, the brief); changelog.py; check_links.py; the dev loop;
                     the GitHub tooling; the unit tests of the Python tools in tests/; the
                     Windows session's Composer automation (composer/Composer.psm1, Shots.ps1)
deploy/              house.yaml: the desired state of the author's house
docs/                status, design notes, contracts, checklists (see docs/README.md)
.github/             the workflows (CI, Release, drift, labels, Scorecard, code scanning triage,
                     Dependabot auto-merge), the labels, the release codenames, Dependabot's
                     settings, the release-note categories, the issue and pull request
                     templates, CODEOWNERS
```

At the top level: [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE),
[`CHANGELOG.md`](CHANGELOG.md), [`CONTRIBUTING.md`](CONTRIBUTING.md),
[`SECURITY.md`](SECURITY.md), [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) and
[`CLAUDE.md`](CLAUDE.md) (the working rules of the AI sessions that build
and test the driver).

## Status

[`docs/status.md`](docs/status.md) is the one-page current state: what the
house runs, what this repository has built, and what is open. Every open
item is an
[issue](https://github.com/corytron/c4-modernforms-driver/issues); questions
are welcome in
[Discussions](https://github.com/corytron/c4-modernforms-driver/discussions).

## License, trademarks and provenance

Licensed under the **Apache License, Version 2.0**; see [`LICENSE`](LICENSE)
and [`NOTICE`](NOTICE). The software is provided "AS IS", without warranties
or conditions of any kind. It is meant to drive a ceiling fan and its light
through a Control4 controller; try it on a test system first, keep a
Composer backup, and understand that your dealer may not support third-party
drivers.

Modern Forms and WAC Lighting are trademarks of their respective owners.
Control4, Composer and DriverWorks are trademarks of Snap One, LLC. This
project is not affiliated with, endorsed by or supported by Modern Forms,
WAC Lighting or Snap One; "for Modern Forms fans" describes compatibility
and nothing more, and no logo of any of them is used.

WAC publishes a reference of the fan's local interface under its own API
License Agreement, which treats that documentation as confidential. This
project stays off that agreement (decided 2026-10-27,
[`docs/status.md`](docs/status.md)): what the driver relies on comes from public open-source clients of the interface and from
read-only queries of the author's own fan, each cited in the design notes;
WAC's documents are at most cited as corroboration, and nothing of the
maker's (documents, apps, firmware, manuals) is included here. Composer Pro and DriverWorks are
licensed by Snap One to Control4 dealers; the driver is written against
Snap One's DriverWorks documentation as published on GitHub, and nothing
from Snap One's SDK repositories (code, libraries or documentation text) is
included here. The shared modules in `src/common/` are the author's own,
shared with his Hue driver under the same license.

Written by Cory Fair with AI pair-programming (Anthropic's Claude, through
Claude Code; see the `Co-Authored-By` trailers in the history). The
copyright is Cory Fair's.
