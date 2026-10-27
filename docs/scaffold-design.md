# Scaffold contract (#1)

The shared text every agent of the scaffold builds against (2026-10-27). The
project copies the process of [corytron/c4-hue-driver](https://github.com/corytron/c4-hue-driver)
(the "Hue repo", checked out read-only at `~/projects/c4-hue-driver`), adapted
to one Modern Forms fan driver. Adapt, never copy blindly: every Hue-specific
name, feature, number and history line goes; every rule, check and safeguard
stays unless this contract says otherwise.

## 1. Names

| What | Value |
|---|---|
| GitHub repository | `corytron/c4-modernforms-driver`, public, Apache-2.0 |
| Local checkout | `~/projects/c4-modernforms-driver` |
| Project board | user project 2, "Modern Forms driver" (`gh project item-add 2 --owner corytron --url …`) |
| Scaffold issue / branch | #1, `feature/scaffold-1` |
| Research issue | #2 |
| Driver directory | `src/modernforms_fan/` → package `build/modernforms_fan.c4z` |
| Driver name in Composer | "Modern Forms Fan" (fan and its light in one driver unless the v1 research decides otherwise; a second driver would be another `src/<name>/driver.xml` and every tool must already handle N packages, as the Hue tools do) |
| Shared Lua modules | `src/common/` (`log.lua`, `dispatch.lua`, `device.lua`, `devloop.lua`), staged into each package as `common/` |
| Codenames | Dune, Denis Villeneuve's films (2021, 2024): an X.0 gets a widely recognised character, place or object, a point release a decidedly less important one; every build and beta of X.Y keeps it. `.github/codenames.json` starts as `{}`: the 1.0 name is proposed to the owner before the first build, and the release tooling must refuse a release whose X.Y has no name |
| Dev key | `~/.config/c4-modernforms-driver/devkey`, env override `C4_MF_DEVKEY_FILE` |
| Ports (so both projects' servers can run at once) | dev server 8081 (Hue uses 8080); release file server 8091 (Hue uses 8090); collect server 8092 |
| GitHub environment | `house` (exists) |

## 2. Placeholders (the repository is public)

Never a real LAN address, MAC, fan client id, room or project name, key or
certificate. Use only:

| What | Placeholder |
|---|---|
| Fan IP | `10.0.2.151` (a second fan `10.0.2.152`) |
| Controller IP | `10.0.2.10` |
| VM IP | `192.0.2.7` |
| Windows VM IP | `192.0.2.8` |
| Fan MAC | `00:00:5e:00:53:01` (RFC 7042 documentation range) |
| Fan client id / device id | `MF_00005E005301` |
| Room names | "Example Room", "Second Room" |
| Project name | "Example Project" |

`.gitleaks.toml` keeps the Hue repo's `lan-address` rule (placeholders and
textbook ranges allowed, as there) and its `house-subnet` rule unchanged
(that subnet is already public in the Hue repo); drops the Hue key, bridge id
and bridge OUI rules; adds a rule for a MAC address that is not in the
00:00:5e:00:53 range, and one for a Modern Forms client id that is not the
placeholder. `tools/gh-discussion.py` and `tools/deploy.py` refuse the same
patterns in anything they post.

## 3. Checks and CI

`tools/check.sh` keeps the Hue check list and order: `lua-lint lua-test shell
python-lint python-test xml powershell workflows secrets house changelog
links`, `--strict`, `--only`. The four CI jobs of `.github/workflows/ci.yml`
are the required status checks on `main` and are named exactly:

1. `Lint and test (Lua 5.1)`
2. `Build the .c4z packages`
3. `Tooling checks (shell, Python, XML, workflows)`
4. `Secrets and private data`

Pins (actions SHAs, the luarocks list, the packager commit
`16eef8beb70303606f066524cda516b2aa7ce38d`, the hash-pinned
`tools/requirements-checks.txt`) are copied from the Hue repo as they are
today. The upload artifact is named `mf-drivers-build-<run>`.

## 4. Build, manifest, release

`tools/build.sh [--dev]` builds one package per `src/*/driver.xml` with the
packager in `~/c4-tools/drivers-driverpackager/` (or `$DP3`), stamps
`<version>` with `git rev-list --count HEAD`, copies `src/common` in as
`common/`, puts LICENSE and NOTICE in every package, renders `CHANGELOG.md`
at the bottom of every driver's `www/documentation.html`, and writes
`build/manifest.json` with the Hue schema 1 (`schema`, `build`, `commit`,
`tag`, `dev`, `packages{name: {sha256, bytes}}`). The Release workflow
(`release.yml`): releases `vX.Y` (final; every 1.x moves the `v1.0` tag as
in the Hue repo) and prereleases `vX.Y-beta.N` that never move, built from
`main` only, with `SHA256SUMS.txt`, `manifest.json` and build-provenance
attestations, the title and notes written from `CHANGELOG.md`'s `##
Unreleased`, the codename from `.github/codenames.json`.

## 5. Desired and observed state

`deploy/house.yaml`, flat `key: value` lines:

```
environment: house
release: none            # no build of these drivers is installed yet (the house runs the stock WAC driver)
build: none
drivers: modernforms_fan
debug_mode: Off
```

`release: none` / `build: none` is a valid state: `deploy.py validate`
accepts it, and the drift workflow opens no issue while there is no
Deployment and the desired release is `none`. Once a release is installed,
the house keys that the Windows session reads back after an install are
`Driver Version` of every device and the driver properties named in the v1
contract (the scaffold knows only `Debug Mode`). `deploy.py` keeps `start`,
`done --devices N`, `failed --note`, `record --no-manifest`, `status`,
`validate`, and writes `build/release/<tag>/BRIEF.md` for the Windows
session (install through Driver ▸ "Add or Update Driver or Agent…", update
in place, never delete and re-add).

## 6. GitHub conventions

Labels: `.github/labels.json` as in the Hue repo with `hue-api` replaced by
`mf-api` ("Modern Forms fan local HTTP API, fan models and firmware") and
`hardware` reading "Needs the controller, a fan, a keypad or a phone to
close" (already created on GitHub). Discussions categories are GitHub's
defaults: releases in Announcements, reports in Show and tell or General,
decisions in Ideas. The code-scanning triage issue is "Code scanning: N open
alert(s) on main", labelled `security`. Every link in the docs to the repo
uses `https://github.com/corytron/c4-modernforms-driver`.

## 7. The scaffold driver

Until the v1 contract exists, `src/modernforms_fan/` is a skeleton that
proves the pipeline: a well-formed `driver.xml` using only documented
elements (minimum OS set to the value the v1 research picks; the scaffold
declares 3.3.0 as a stand-in and says so in a comment), `Driver Version`
and `Debug Mode` properties, a `driver.lua` wired through `common/dispatch`
and `common/log` the way the Hue drivers are, a `www/documentation.html`
that says the driver is not ready for use, and specs. It is never installed
on the house.

## 8. What the scaffold does not include

Hue-only tooling with no fan counterpart yet: `gen_ca_bundle.sh`, the
certificate bundle, `smart_scene_probe.py`, `make_icons.py` (until the
driver has icons), the Hue reviews folder and every Hue feature contract.
