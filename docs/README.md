# The docs folder

What each file here is for. One rule runs through all of them: `status.md` is
the single page of the present; every other note keeps its history as
written, with dated "Superseded" or "Current" lines where behaviour changed
later, and where a note and `status.md` disagree about the present,
`status.md` and the code win. The owner's manual itself is not here but in
the driver: [`src/modernforms_fan/www/documentation.html`](../src/modernforms_fan/www/documentation.html)
(the driver's Documentation tab in Composer; until the v1 contract it says
that the driver is not ready), and since #121 the Breeze fan's own tab,
`src/modernforms_breeze_fan/www/documentation.html` (from #111 to #121 the
Breeze switch's, `src/modernforms_breeze/www/documentation.html`, which the
1.2 release still carries). What each release changed is in
[`CHANGELOG.md`](../CHANGELOG.md); the working rules of the AI sessions that
build the driver are in [`CLAUDE.md`](../CLAUDE.md).

On 2026-10-27 the folder holds the scaffold's documents (the process,
copied from the author's [Hue driver](https://github.com/corytron/c4-hue-driver)
and adapted), the v1 research with its edge-case notes
([issue #2](https://github.com/corytron/c4-modernforms-driver/issues/2)) and
the v1 contract written from it and the owner's decisions
([issue #6](https://github.com/corytron/c4-modernforms-driver/issues/6)).

## Feature contracts

Written before the code, against the research below; they are the
specification, and `status.md` says what of them is live.

- [`v1-design.md`](v1-design.md): the Modern Forms Fan driver: one driver
  with a fan proxy and a `light_v2` proxy, the driver's own Button Links for
  every speed, Off, Toggle and Cycle and the light's Top, Bottom and Toggle
  with keypad LEDs, the transport to the fan and the report rules, the
  properties, actions, events and texts, the module interfaces and the
  build split; since #111 (V31) also Breeze and the companion package,
  and since #121 (V32) fan mode and Breeze mode and the Breeze fan.
- [`migration-design.md`](migration-design.md): retired by #45, kept as
  the record of the house's cutover from the stock WAC driver: the new
  device beside the old one, the keypad moved button by button with a way
  back from every phase, and the removal of the stock device and the
  keypad's LED workaround. The Migration Report it specified is gone from
  the driver.
- [`fan-name-design.md`](fan-name-design.md): the fan's product name from
  its model number, shown in Fan Model, and when the driver names its two
  items after it (#37): Use Selected Fan, guarded, and the action Name Items
  After Fan.
- [`address-follow-design.md`](address-follow-design.md): following the
  pinned fan to a new address by itself (#39): when it looks (multicast DNS
  for the pinned MAC, on a backing-off schedule), what it reads before it
  moves, the owner's typed address winning, and the switch.
- [`auto-discovery-design.md`](auto-discovery-design.md): finding fans by
  itself (#102): the multicast DNS question asked at every load and, while
  the device has no fan, on a backing-off schedule; `Found Fans` kept
  current with a summary as its first item; a pick that takes the fan at
  once (another fan on a device that has its fan waits for Use Selected
  Fan); the Find Fans action removed; the checks on the house.
- [`breeze-design.md`](breeze-design.md): Breeze in Control4 (#111): what
  "Breeze is on" means (the fan runs with Breeze), the programming
  commands, variable, events and condition, the Fan Breeze link (311), the
  companion package `modernforms_breeze.c4z` with its on/off switch for
  the Navigators, added by the action Add Breeze Switch, the messages
  between the two drivers, the texts, and the checks on the house; its
  section 11 (#121, 1.3) is fan mode and Breeze mode, never both: the fan
  item showing fan mode only, the Breeze fan (`modernforms_breeze_fan.c4z`,
  three speeds Breeze 1 to 3) replacing the switch, the action renamed Add
  Breeze Fan, what Off and the Breeze commands do now, the request order
  and the house's update steps.
- [`../probes/README.md`](../probes/README.md): the M1 probe (#17), a
  throwaway Composer package built outside `src/` so no release carries it,
  and the Windows session's brief for each check K4–K10 and K14 of
  [`v1-design.md`](v1-design.md#11-hardware-checks-before-the-first-install);
  deleted after M1.
- [`fan-probe.md`](fan-probe.md): `tools/mf_probe.py`, the VM's tool for
  the fan-side checks (K11 direction, K12 the light's level while off, K13
  bursts, K15 the dim staircase) and for read-only reads and fixtures: what
  each check writes to the fan and for how long, and its safety rails.

## Research and edge cases (v1, #2)

Read-only research written before the v1 contract; every claim is marked
verified (with the SDK file, the primary source or the Hue measurement) or
assumed, and each note ends with the hardware checks that settle its
assumptions and the questions for the owner.

- [`modernforms-api-research.md`](modernforms-api-research.md): the fan's
  local HTTP API (`POST /mf`, JSON, no authentication, no push), its fields
  and ranges by fan generation, its fragility under polling, the causes of
  late or out-of-order reports and the transport `C4:url` should give it.
- [`fan-proxy-research.md`](fan-proxy-research.md): the fan proxy's
  commands, notifications and capabilities, what `proxy_fan_speed_connections`
  does and does not document, and driver-declared Button Links with keypad
  LEDs for every speed, Off, Toggle and Cycle.
- [`light-structure-research.md`](light-structure-research.md): the fan's
  light as a `light_v2` dimmer with Top, Bottom and Toggle links, one driver
  with two proxies versus a light child device, the minimum OS and the Lua
  sandbox.
- [`edge-cases-modernforms.md`](edge-cases-modernforms.md): the fan's life
  seen from Modern Forms: addresses and identity, power cuts at the wall,
  replacements, resets, firmware, the app's schedules and automations, and
  what is automatic, offered or forbidden without a click.
- [`edge-cases-control4.md`](edge-cases-control4.md): the Control4 side:
  replacing the stock WAC driver step by step with a way back, updates,
  backups and restores, connections, programming events and the report
  rules that replace the keypad's settle timer.

## Research for later features

Read-only research written before a feature's contract, in the same style.

- [`fan-names-research.md`](fan-names-research.md): how `fanType` is built
  and the table of Modern Forms fan families and their product names, from
  public sources (#37).
- [`edge-cases-rename.md`](edge-cases-rename.md): the lifecycle cases of the
  driver renaming its own items in Composer, and the guard that keeps a name
  someone typed (#37).
- [`edge-cases-address.md`](edge-cases-address.md): the fan's and
  Control4's cases around a fan whose address changes, the evidence from the
  house, and the recommendation the contract of #39 rests on.
- [`edge-cases-discovery.md`](edge-cases-discovery.md): the lifecycle cases
  of a driver that looks for fans by itself, on the fan's and Control4's
  side, and what is automatic, offered or forbidden without a click (#102).
- [`auto-discovery-research.md`](auto-discovery-research.md): what the Hue
  driver's bridge detection did and learned on this house, what exists here,
  and the proposed mechanism: the schedule, sharing the network binding with
  the follower, the list, the pick and removing Find Fans (#102).
- [`breeze-research.md`](breeze-research.md): the fan's side of Breeze
  (#111): the fields `wind` and `windSpeed`, what the fan is known to do and
  report, how other integrations expose it, the bodies to send, the risks
  for the settle window and the poll, and the checks only the house fan can
  answer.
- [`edge-cases-breeze.md`](edge-cases-breeze.md): the Control4 side of
  Breeze (#111): every way it can reach a Navigator, ranked (the fan proxy
  has no place for it), the programming, keypad and Composer surfaces, the
  recommended companion switch, and the lifecycle cases BC1 to BC36 with
  what is automatic, offered or forbidden without a click.
- [`edge-cases-breeze-fan.md`](edge-cases-breeze-fan.md): Breeze as a fan
  device (#121): why the fan-proxy companion needs a new file name (an
  installed device cannot change its proxy type), what deleting the 1.2
  switch loses, the fan tile that cannot show offline, the house's update
  order, and the two-device model of one motor (fan mode or Breeze mode,
  the request order, the keypad LEDs, groups and loops), cases BF1 to
  BF106.

## Start here

- [`status.md`](status.md): what runs on the author's house, what this
  repository has built, and what is open.
- [`design.md`](design.md): the engineering notebook. The targets (OS
  versions, Lua 5.1), the method (every claim marked verified or assumed,
  with its source), what was measured of the stock driver, and the headings
  the v1 research fills: transport, driver structure, the fan proxy and its
  speed links, the light, keypad LEDs, the state model and the minimum OS.
- [`release-checklist.md`](release-checklist.md): what a build must pass on
  the development machine, on the dev loop, in Composer and with the owner's
  phone, keypads and fan before it is called good (the hardware passes are a
  skeleton until the v1 contract); how a release is named (one codename
  per X.Y), cut (the Release workflow) and brought to the house
  (`tools/deploy.py`).

## Process

- [`scaffold-design.md`](scaffold-design.md): the contract of the scaffold
  (2026-10-27, #1): the names, the placeholders, the checks and CI jobs, the
  build and manifest, the desired and observed state of the house, the
  GitHub conventions, the skeleton driver, and what of the Hue project's
  tooling was left out.
- [`cicd-gitops-design.md`](cicd-gitops-design.md): the CI/CD and GitOps
  contract: one check script for the development machine and CI
  (`tools/check.sh`), the four required jobs, the code scanning issue,
  attested releases from `main`, `deploy/house.yaml` as the desired state of
  the house, the GitHub Deployment as the observed state, the drift issue
  and `tools/deploy.py`.
- [`changelog-design.md`](changelog-design.md): the contract of the
  changelog: `CHANGELOG.md`'s format, `tools/changelog.py` (the check, the
  release notes, the Documentation tab's changelog, the stamp) and the
  release codenames.
- [`prerelease-design.md`](prerelease-design.md): prereleases for testers:
  versions `X.Y-beta.N` with tags that never move, built from `main` like
  every release, and their notes.
- [`dev-loop.md`](dev-loop.md): the development loop: a `--dev` build of the
  driver fetches its Lua from `tools/devserver.py`, reloads itself, runs
  actions queued with `tools/devctl.py` and ships its log back, every bundle
  and command signed with the developer's dev key.
- [`composer-remote.md`](composer-remote.md): driving Composer Pro from the
  development machine through a Claude Code session on the Windows machine
  (UI Automation from PowerShell, `tools/composer/Composer.psm1` and
  `Shots.ps1`), the rules every brief carries, and what was learned about
  Connections and Programming by synthetic drag.
- [`composer-checklist.md`](composer-checklist.md): the steps only
  Composer, a Navigator, a keypad or the Modern Forms app can show, as the
  owner runs them, with a "Done" line per step, for the first full-featured
  test build of the driver.
