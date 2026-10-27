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

- **#6** The v1 plan and its decisions, with a recommended default each:
  structure, speed links, minimum OS, which fans, adding a fan, polling and
  report rules, keypad LEDs, ON and Toggle, double taps, the fan offline,
  the light's turn-on level, WAC's documents, the migration pace and the 1.0
  codename. The research it rests on is indexed in
  [`README.md`](README.md#research-and-edge-cases-v1-2).
- **WAC's API License Agreement**, a decision for the owner (in #6): the research found that WAC publishes a reference of
  the fan's local interface under an agreement that treats that
  documentation as confidential. Either the project accepts the agreement
  and counts the reference as a source, or it keeps to the public
  open-source clients and its own measurements, citing WAC's documents at
  most as corroboration, which is the rule until the decision
  ([`design.md`](design.md), "Method").
- **The v1 contract**, written from the research before any driver code,
  with the migration from the stock driver as its own part.
- **The 1.0 codename** (Dune, Denis Villeneuve's films): proposed to the
  owner before the first build; `.github/codenames.json` is `{}` until then,
  and the release tooling refuses a release whose X.Y has no name.

Decided, not open:

- One driver, **Modern Forms Fan** (`src/modernforms_fan/`, package
  `modernforms_fan.c4z`), for the fan and its light, unless the v1 research
  decides otherwise (`scaffold-design.md`, section 1).
- Control4 is the source of truth: automations live in Control4
  programming, not in the Modern Forms app (`CLAUDE.md`).
- The scaffold's `driver.xml` declares minimum OS 3.3.0 as a stand-in; the
  v1 research picks the real value (`scaffold-design.md`, section 7).
