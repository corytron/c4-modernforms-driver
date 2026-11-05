# Status of the Modern Forms fan driver (2026-10-27)

The single page that says what is built, what runs on the house, and what is
open. Contracts and design notes keep their history; where they and this
page disagree about the present, this page and the code win.

**Scaffolded on 2026-10-27; nothing to install yet.** The repository
`corytron/c4-modernforms-driver` (public, Apache-2.0) was created on
2026-10-27 and is being set up with the process and tooling of the author's
Hue driver (issue #1, contract [`scaffold-design.md`](scaffold-design.md)):
one check script for this machine and CI, the four required CI jobs,
attested releases from `main`, the house's desired state in
[`deploy/house.yaml`](../deploy/house.yaml), the changelog, the link check,
the dev loop and the Windows session's Composer automation. The driver in
`src/modernforms_fan/` is a skeleton that proves that pipeline (Driver
Version and Debug Mode properties, a Documentation tab that says the driver
is not ready); it is never installed on the house. There is no release, and
no build of this driver has run on a controller.

## What runs on the house

- **Nothing of this project.** `deploy/house.yaml` reads `release: none` and
  `build: none`, and the environment `house` has no deployment.
- **Controller:** OS 3.4.3, managed with Composer Pro 3.4.2 on the Windows
  machine.
- **The fan:** one Modern Forms fan with its light, on the stock driver
  `wac_mf_fan_and_light_controller(v4).c4z`. The driver declares 13
  BUTTON_LINK connections: Fan Off, Fan Speed 1 to 6, Toggle Preset and
  Cycle Speed for the fan, and Top, Bottom and Light Toggle for the light.
  A hands-on test on 2026-10-27 showed that they do nothing in either
  direction: they bind normally, but a bound keypad button's press reaches
  neither the fan nor the light, and the driver sends no LED state back (no
  `MATCH_LED_STATE`), so a button on Follow Connection never shows their
  state.
- **The workaround on the house's keypad**, all of it Control4
  programming: scripts on the keypad's button events set the fan's speeds;
  LED scripts show the current speed on the buttons (their LED Behavior on
  Programmed, the commands "Use the on color for \<button>" and "Use the
  off color for \<button>"); and a one-second one-shot Timer agent,
  restarted on every "Fan Speed Changed" event, lets the stock driver's late
  and out-of-order speed reports settle before the LEDs are set. It stays as
  it is until the migration contract says how to replace it; nothing in
  this repository touches it.

## On GitHub (read 2026-10-27)

- Issues #1 (the scaffold, PR #3) and #2 (the v1 research, PR #5) are
  closed; #6 holds the v1 plan and the owner's decisions; #4 is the code
  scanning issue. The labels of [`.github/labels.json`](../.github/labels.json)
  exist, `mf-api` and `hardware` among them; the project board is user
  project 2, "Modern Forms driver" (not public yet).
- Discussions are on, with GitHub's default categories (releases in
  Announcements, reports in Show and tell or General, decisions in Ideas);
  the scaffold, the research and the plan are posted there (#7, #8, #9).
- The environment `house` exists. Secret scanning, push protection,
  Dependabot security updates and private vulnerability reporting are on.
- `main` is protected: pull requests only, the four required checks, the
  branch current, conversations resolved, admins included; release tags
  `v*` cannot be deleted except by an admin. CodeQL's default setup (Python,
  Actions) and the Scorecard workflow scan every push to `main`.

## Open

Every open item is an issue (`gh issue list --state open`); this list says
where each stands on 2026-10-27.

- **#17** M1, the probes: all but one check done. The fan-side checks K11,
  K12, K13 and K15 ran on 2026-10-27 (`tools/mf_probe.py`,
  [`fan-probe.md`](fan-probe.md)). The Windows session installed the
  Composer probe package (`probes/`, `build/probe/mf_probe.c4z`) in a test
  room and ran K4, K5, K6, K7, K8's Lua part, K9, K10, K14 and K19 in two
  rounds (2026-10-27 and 2026-11-04, the second with the owner at the keypad
  and the restore check after each borrowed button), all in
  [`v1-design.md`](v1-design.md#111-what-the-probe-has-shown-so-far-17).
  Results: **K10 passed, Find Fans is in v1**; keypads take `BUTTON_COLORS`
  over a link (V27 ships from beta.2, #31); Up and Down have
  Button Link rows; Composer refuses a package whose minimum OS is above the
  controller's (K9). Open: K8's three taps in the Control4 app (the owner's
  phone); the probe and its test room stay installed until the owner decides
  whether to run them.
- **#26** M3, the build: the driver is written and unit-tested (the transport,
  the state model, the fan proxy and links, the light, Find Fans, the
  Migration Report, the manual and the Composer checklist; `driver.xml` from
  section 2 of [`v1-design.md`](v1-design.md)), as
  [`v1-design.md`](v1-design.md#912-as-built-m3-26) says it was built. Nothing of
  it has run on the house: the owner decided (2026-11-04) to test once, with
  the complete driver, so the first install is a prerelease through the
  [`docs/composer-checklist.md`](composer-checklist.md).
- **#14** Owner questions from the v1 contract: the Cycle link wrapping and
  custom icons, each with a default (the colour per speed was answered yes,
  #31, 2026-11-04).
- **#31** A colour per speed on the keypad links (V27): `Speed LED Colors`
  and its seven colour rows, a property-only change for v1.0-beta.2, so the
  bedroom keypad keeps blue at speed 1 and `#ff6000` at 6 after the cutover.
- **M1**, the probes of [`v1-design.md`](v1-design.md#11-hardware-checks-before-the-first-install)
  (a throwaway package beside the stock device), then **M3**, the build
  split of [`v1-design.md`](v1-design.md#13-m3-build-split).

Decided, not open (2026-10-27, #6; the specification is
[`v1-design.md`](v1-design.md), the cutover
[`migration-design.md`](migration-design.md)):

- One driver, **Modern Forms Fan** (`src/modernforms_fan/`, package
  `modernforms_fan.c4z`), with a fan proxy and a `light_v2` proxy, and its
  own Button Links for every speed, Off, Toggle and Cycle and the light's
  Top, Bottom and Toggle, with keypad LEDs.
- Minimum OS 3.3.0, checked at run time too; Gen 1–3 fans with six speeds.
- WAC's API License Agreement: the project stays off it and builds on the
  public open-source clients and its own read-only measurements
  ([`design.md`](design.md), "Method").
- The migration: one cutover sitting with the stock programming disabled,
  not deleted; the stock device and the LED workaround removed later, once
  the driver's Migration Report reads safe to remove.
- The 1.0 codename is "Arrakis".
- Control4 is the source of truth: automations live in Control4
  programming, not in the Modern Forms app (`CLAUDE.md`).
