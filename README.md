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

> **Not ready for use: there is no release yet, so do not install anything
> from this repository.** The project was set up on 2026-10-27. The research
> that decides how the driver talks to the fan and to Control4
> ([issue #2](https://github.com/corytron/c4-modernforms-driver/issues/2)) is
> under way, and no build of this driver has run on a controller. This page
> says what the driver is meant to do; [`docs/status.md`](docs/status.md) says
> where it stands.

An independent Control4 DriverWorks driver for Modern Forms smart ceiling
fans with an integrated light, working over the fan's own local network
interface. One `.c4z` driver, **Modern Forms Fan**, is meant to make the fan
and its light ordinary Control4 devices: a fan with its speeds and a
dimmable light that you switch, dim, program in Composer Pro and bind to
keypads like any other fan and light.

A personal project for one Control4 home. It is not affiliated with,
endorsed by or supported by Modern Forms, WAC Lighting or Snap One
(Control4); see
[License, trademarks and provenance](#license-trademarks-and-provenance).

## Why a new driver

The fan in the author's house runs on the stock driver,
`wac_mf_fan_and_light_controller(v4).c4z`. That driver declares 13 Button
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

## What it is meant to do (v1)

The details, and every name below, are settled by the v1 research and the
v1 contract; until then this is the plan, not the description of a driver.

- **The fan.** A Control4 fan (the fan proxy) with its discrete speeds (1
  to 6; fewer where a model has fewer), off, and the direction where the
  fan supports it.
- **Fan speed links that work.** A Button Link per speed (the fan proxy's
  per-speed connections) plus Off, Toggle and Cycle. A keypad button bound
  to a speed sets that speed when pressed, and with the button's LED
  Behavior on *Follow Connection* its LED is lit while the fan runs at that
  speed and dark otherwise, without any programming.
- **The light.** The fan's light as a Control4 light (the `light_v2`
  proxy) with on/off and dimming, and Top, Bottom and Toggle Button Links
  whose keypad LEDs follow the light, the way the author's
  [Hue driver](https://github.com/corytron/c4-hue-driver) does them.
- **Live state.** Changes made in the Modern Forms app, with the remote or
  at the wall control show up in Control4 in order and as promptly as the
  fan allows, and Control4 programming reacts to them.
- **Local only.** The driver talks to the fan over your own network, never
  through a cloud service, so Control4 keeps working while the vendor's
  cloud is down.
- **Lifecycle.** A fan that goes offline (a wall switch that cuts its
  power), changes its address or gets new firmware is reported in readable
  Composer properties and picked up again. The driver knows a fan by its
  own identity, not only by its address, so a new address is the same fan,
  not a new one.
- **Moving from the stock driver.** A written procedure: which connections
  and programming to redo, in which order, and how to remove the keypad
  workaround afterwards.

Control4 stays the source of truth: schedules and automations belong in
Control4 programming, not in the Modern Forms app; the driver reports what
the fan does.

## What you will need (expected)

- A Control4 controller on OS 3.x or 4.x, and Composer Pro. The driver will
  declare a minimum OS version, chosen by the v1 research; the fan proxy's
  per-speed connections are documented from OS 3.4.2. The author's
  controller runs OS 3.4.3 and is managed with Composer Pro 3.4.2.
- A Modern Forms fan with Wi-Fi, set up in the Modern Forms app, on the same
  network as the controller and with a fixed IPv4 address (a DHCP
  reservation in your router). Which models and firmware versions work is
  settled by the research and by testing; only the author's fan will have
  been tried.
- Nothing in the cloud: the driver is meant to need neither internet access
  nor a Modern Forms account (to be confirmed by the research).

## Get it

There is nothing to download yet. Once there is, the releases will be on
the [Releases page](https://github.com/corytron/c4-modernforms-driver/releases),
numbered `X.Y` and tagged `vX.Y`. Each X.Y carries its own codename from
Denis Villeneuve's *Dune* films, a major name for an X.0 and a lesser one for
a point release; the first is chosen before the first build. Prereleases for
testers (`X.Y-beta.N`) will be marked **Pre-release** and never **Latest**.
What each release changed will be in [`CHANGELOG.md`](CHANGELOG.md), which
each release's notes and the end of the driver's Documentation tab repeat.

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

Not yet: there is no release. When there is, the driver's
**Documentation** tab in Composer
([`src/modernforms_fan/www/documentation.html`](src/modernforms_fan/www/documentation.html),
which today says that the driver is not ready) will be the owner's manual. A few rules already hold, as they do for the author's Hue driver:

- Install and update through **Driver > Add or Update Driver or Agent...**.
  An update goes **in place** onto every existing device; never delete and
  re-add the device, since its connections, its state and every programming
  line that names it go with it.
- If Composer asks **Restart Director?**, the new build changes the driver's
  capabilities. Answer Yes, then **reboot the controller from System
  Manager** (Tools > System Manager): the new code loads only with the
  reboot. Builds that change only Lua or connections take effect at once.
- Moving a house from the stock driver will follow the migration contract;
  until it exists, leave the stock driver and its programming as they are.

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
3. [`deploy/house.yaml`](deploy/house.yaml) says which release and build the
   house should run; today it says `release: none`, since the house still
   runs the stock driver. Changing it is a pull request of its own.
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
src/modernforms_fan/ the driver: driver.lua, driver.xml, www/ (its Documentation tab); a skeleton
                     that proves the build until the v1 contract
tests/               busted specs (spec/), the fake DriverWorks runtime (helpers/), and the fan
                     API fixtures (fixtures/) once the research has recorded them
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
house runs (today the stock driver and its keypad workaround), what this
repository has built, and what is open. Every open item is an
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
License Agreement, which treats that documentation as confidential; whether
this project accepts that agreement is an open decision
([`docs/status.md`](docs/status.md)). Until it is made, what the driver
relies on comes from public open-source clients of the interface and from
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
