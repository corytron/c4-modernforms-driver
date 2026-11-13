# The docs folder

What each file here is for, in five groups: where to start, the pages of the
present, the feature contracts, the research and edge cases behind them, and
the process and tooling. Every Markdown file of this folder is listed once.

Two kinds of document live here. **The pages of the present**
([`status.md`](status.md), [`design.md`](design.md) and the two checklists)
are kept true for today's code and today's house. **Contracts, research and
edge-case notes** record what was decided when, and are not rewritten: where
a later release changed a decision, a short "Since 1.N (#NNN)" note (in
older notes a dated "Superseded" or "Current" line) says so beside the old
text. Where any note and `status.md` disagree about the present, `status.md`
and the code win ([`doc-coherence-design.md`](doc-coherence-design.md)).

## Start here

- **The owner's manual** is not in this folder but in the drivers, as each
  device's Documentation tab in Composer: the fan's
  [`src/modernforms_fan/www/documentation.html`](../src/modernforms_fan/www/documentation.html)
  and the Breeze fan's
  [`src/modernforms_breeze_fan/www/documentation.html`](../src/modernforms_breeze_fan/www/documentation.html)
  (since 1.3, #121; the 1.2 Breeze switch's tab is on the v1.2 release
  only).
- **What each release changed** is in [`CHANGELOG.md`](../CHANGELOG.md),
  newest first.
- **The working rules** of the AI sessions that build the drivers are in
  [`CLAUDE.md`](../CLAUDE.md).
- Then read [`status.md`](status.md) for what runs on the house and what is
  open, and [`design.md`](design.md) for how the drivers are built.

## The pages of the present

- [`status.md`](status.md): what runs on the author's house (the release,
  the devices, every setting, the keypad), what is open, the history of
  every release with its issues and Discussions, and the decisions that
  stand.
- [`design.md`](design.md): the engineering notebook: the targets (OS
  versions, Lua 5.1), the method (every claim marked verified, measured or
  assumed, with its source), the two packages and the fan driver's modules,
  the transport, the state model, the fan proxy and its links, the light,
  the keypad LEDs and their animations, Breeze, finding and following the
  fan, and the minimum OS, each with what later releases changed.
- [`composer-checklist.md`](composer-checklist.md): every step only
  Composer, a Navigator, a keypad or the Modern Forms app can show, as the
  owner runs them, section by section from the first test build to 1.9, with
  a "Done" line per step saying when it ran and what it showed.
- [`release-checklist.md`](release-checklist.md): what a build must pass on
  the development machine, on the dev loop, at the install and with the
  owner before it is called good, and how a release is named (one codename
  per X.Y), cut (the Release workflow), brought to the house
  (`tools/deploy.py`) and put in a tester's hands (prereleases).

## Feature contracts

Written before the code, against the research below; they are the
specification, and `status.md` says what of them is live. In release order:

- [`v1-design.md`](v1-design.md): the Modern Forms Fan driver (#6, #26,
  1.0): one driver with a fan proxy and a `light_v2` proxy, the driver's own
  Button Links for every speed, Off, Toggle and Cycle and the light's Top,
  Bottom and Toggle with keypad LEDs, the transport to the fan and the report
  rules, the properties, actions, events and texts, persistence, the module
  interfaces, the hardware checks and the build split; since #111 (V31) also
  Breeze and the companion package, and since #121 (V32) fan mode and Breeze
  mode and the Breeze fan.
- [`migration-design.md`](migration-design.md): the house's cutover from the
  stock WAC driver (1.0-beta.1, 2026-11-04): the new device beside the old
  one, the keypad moved button by button with a way back from every phase,
  and the removal of the stock device and the keypad's LED workaround.
  Retired by #45 and kept as the record; the Migration Report it specified is
  gone from the driver.
- [`fan-name-design.md`](fan-name-design.md): the fan's product name from
  its model number, shown in Fan Model, and when the driver names its two
  items after it (#37, 1.0): Use Selected Fan, guarded, and the action Name
  Items After Fan.
- [`address-follow-design.md`](address-follow-design.md): following the
  pinned fan to a new address by itself (#39, 1.0): when it looks (multicast
  DNS for the pinned MAC, on a backing-off schedule), what it reads before it
  moves, the owner's typed address winning, and the switch.
- [`auto-discovery-design.md`](auto-discovery-design.md): finding fans by
  itself (#102, 1.2): the multicast DNS question asked at every load and,
  while the device has no fan, on a backing-off schedule; `Found Fans` kept
  current with a summary as its first item; a pick that takes the fan at
  once; the Find Fans action removed; the checks on the house.
- [`breeze-design.md`](breeze-design.md): Breeze in Control4 (#111, 1.2):
  what "Breeze is on" means, the programming commands, variable, events and
  condition, the Fan Breeze link (311), the 1.2 companion switch
  `modernforms_breeze.c4z` and the messages between the two drivers; its
  section 11 (#121, 1.3) is fan mode and Breeze mode, never both, the Breeze
  fan (`modernforms_breeze_fan.c4z`, Breeze 1 to 3) replacing the switch,
  the action Add Breeze Fan, the request order and the house's update steps.
- [`breeze-leds-design.md`](breeze-leds-design.md): Breeze on the keypad
  LEDs (#137, 1.4): gusts in white, ice, teal and sky on the bound speed
  links while Breeze blows, a wipe in and a wipe out, only under Per speed,
  colours only so the keypad's ambient dimming applies, the night
  brightness; the properties, the module interfaces, the tests and the
  checks on the house.
- [`light-fades-design.md`](light-fades-design.md): simulated fades for the
  fan's light (#141, 1.5): the decisions LF-D1 to LF-D24, the rule for every
  tap, hold and command, the Click Rates and their reboot, the interfaces of
  each module and the checks on the house.
- [`speed-leds-design.md`](speed-leds-design.md): the chase on the keypad
  LEDs at a fixed speed (#159, 1.6; #177, 1.7): a dot in the speed's colour
  across the bound speed buttons in the airflow direction, a constant rest
  in which the selected speed's LED is lit, the properties, the second
  engine and its arbiter, the tests and the checks on the house.
- [`keypad-leds-visibility-design.md`](keypad-leds-visibility-design.md):
  the keypad LED rows only while a button is bound to a fan speed link
  (#178, 1.7): which rows, when they show and hide, the instructions in
  Composer, the module, the tests and the checks.
- [`min-on-design.md`](min-on-design.md): `Light Min On (%)` for the fan's
  light (#195, 1.8): the mapping between Control4's levels and the fan's,
  what a change of the value does, the Control4 guidelines it follows, and
  who owns which file.
- [`ambient-pause-design.md`](ambient-pause-design.md): pausing the speed
  chase and the Breeze animation while the keypad's LEDs are dark (#207,
  1.9): what the house probe measured on the keypad's Ambient Light Level
  (Source) output, the dark and lit rules, the pause and resume in both
  engines, and who owns which file.

## Research and edge cases

Read-only notes written before a contract; every claim is marked verified
(with the SDK file, the primary source or the house measurement) or
assumed, and the edge-case notes decide per case what is automatic, offered
or forbidden without a click. By feature:

**The v1 driver (#2):**

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
  replacements, resets, firmware, the app's schedules and automations.
- [`edge-cases-control4.md`](edge-cases-control4.md): the Control4 side:
  replacing the stock WAC driver step by step with a way back, updates,
  backups and restores, connections, programming events and the report
  rules that replace the keypad's settle timer.

**Names (#37), addresses (#39) and discovery (#102):**

- [`fan-names-research.md`](fan-names-research.md): how `fanType` is built
  and the table of Modern Forms fan families and their product names, from
  public sources.
- [`edge-cases-rename.md`](edge-cases-rename.md): the lifecycle cases of the
  driver renaming its own items in Composer, and the guard that keeps a name
  someone typed.
- [`edge-cases-address.md`](edge-cases-address.md): the fan's and
  Control4's cases around a fan whose address changes, the evidence from the
  house, and the recommendation the contract of #39 rests on.
- [`edge-cases-discovery.md`](edge-cases-discovery.md): the lifecycle cases
  of a driver that looks for fans by itself, on the fan's and Control4's
  side.
- [`auto-discovery-research.md`](auto-discovery-research.md): what the Hue
  driver's bridge detection did and learned on this house, what exists here,
  and the proposed mechanism: the schedule, sharing the network binding with
  the follower, the list, the pick and removing Find Fans.

**Breeze (#111, #121):**

- [`breeze-research.md`](breeze-research.md): the fan's side of Breeze: the
  fields `wind` and `windSpeed`, what the fan is known to do and report, how
  other integrations expose it, the bodies to send, the risks for the settle
  window and the poll, and the checks only the house fan can answer.
- [`edge-cases-breeze.md`](edge-cases-breeze.md): the Control4 side of
  Breeze: every way it can reach a Navigator, ranked (the fan proxy has no
  place for it), the programming, keypad and Composer surfaces, the
  recommended companion switch, and the cases BC1 to BC36.
- [`edge-cases-breeze-fan.md`](edge-cases-breeze-fan.md): Breeze as a fan
  device (#121): why the fan-proxy companion needs a new file name, what
  deleting the 1.2 switch loses, the fan tile that cannot show offline, the
  house's update order, and the two-device model of one motor, cases BF1 to
  BF106.

**The keypad LED animations (#137, #159, #178, #198, #207):**

- [`breeze-leds-sdk-research.md`](breeze-leds-sdk-research.md): a keypad
  LED animation while Breeze blows, from the SDK's side: every documented way
  to change a keypad button's LED, which source wins under each LED
  Behavior, driver timers, and what programming alone can reach.
- [`breeze-leds-field-research.md`](breeze-leds-field-research.md): the
  same animation from outside the SDK: the keypad's LEDs, Composer's Delay
  and Timer agent, field reports and drivers that animate keypads, Zigbee
  message rates, and how few LEDs can still look like motion.
- [`edge-cases-breeze-leds.md`](edge-cases-breeze-leds.md): the lifecycle
  cases of that animation, done by programming or by the driver.
- [`edge-cases-speed-leds.md`](edge-cases-speed-leds.md): the lifecycle
  cases of the speed chase on both sides.
- [`speed-leds-c4-guidelines.md`](speed-leds-c4-guidelines.md): Control4's
  guidance on keypad LEDs applied to the chase: the messages, their cost,
  the budget and the default timings.
- [`speed-leds-engine-options.md`](speed-leds-engine-options.md): where the
  chase engine lives beside the Breeze one, the hand-over between the two,
  the frames and the proposed interface (an options note, not a contract).
- [`keypad-leds-visibility-sdk-research.md`](keypad-leds-visibility-sdk-research.md):
  hiding a driver's own rows on OS 3.x and 4.x, knowing a keypad is bound,
  and why a colour keypad cannot be told from other consumers (#178).
- [`edge-cases-keypad-leds-visibility.md`](edge-cases-keypad-leds-visibility.md):
  the lifecycle cases of showing the keypad LED rows only with a keypad
  (#178).
- [`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md):
  the keypad's ambient LED dimming against the speed chase and the Breeze
  animation (#198), from Control4's side: Ambient Light Profiles, what a
  driver can read of them (nothing documented), and why the keypad's own
  Status LED minimum decides whether the animations show at night.
- [`edge-cases-led-dimming.md`](edge-cases-led-dimming.md): the same from
  both sides (#198): 81 cases of the dark state starting and ending during a
  chase or a gust, neighbouring sensors, presses, restarts and message cost;
  its variant (a) became the pause of #207.

**The light (#141, #195):**

- [`light-fades-sdk-research.md`](light-fades-sdk-research.md): simulated
  fades from Control4's side: every way a light is asked to change level and
  which carry a rate, click rates and their reboot, what Control4's own
  dimmers do, what Navigators see during a fade, and what carries over from
  the Hue tap-stop design.
- [`edge-cases-light-fades.md`](edge-cases-light-fades.md): the same fades
  from the fan's side: what one level step costs (measured), the step rate a
  fade can have, the corner cases on both sides and a hardware probe plan.
- [`min-on-sdk-research.md`](min-on-sdk-research.md): a Min On for the
  fan's light from Control4's side: light_v2's deprecated Range Levels
  against a driver property, what Control4 expects a Min On to do, and the
  mapping between Control4's levels and the fan's.
- [`edge-cases-min-on.md`](edge-cases-min-on.md): the same Min On from both
  sides: levels set from the fan's app or remote, changing the value,
  turn-ons, fades, presets, the device's life cycle and rounding.

## Process and tooling

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
- [`codename-meanings-design.md`](codename-meanings-design.md): every
  release's notes open with what its codename means in the Dune films and
  how it ties to the release (#192): the file, the text rules, the checks.
- [`prerelease-design.md`](prerelease-design.md): prereleases for testers:
  versions `X.Y-beta.N` with tags that never move, built from `main` like
  every release, and their notes.
- [`dev-loop.md`](dev-loop.md): the development loop: a `--dev` build of the
  driver fetches its Lua from `tools/devserver.py`, reloads itself, runs
  actions queued with `tools/devctl.py` and ships its log back, every bundle
  and command signed with the developer's dev key; `tools/regress.sh`.
- [`composer-remote.md`](composer-remote.md): driving Composer Pro from the
  development machine through a Claude Code session on the Windows machine
  (UI Automation from PowerShell, `tools/composer/Composer.psm1` and
  `Shots.ps1`), the rules every brief carries, and what was learned about
  Connections and Programming by synthetic drag.
- [`fan-probe.md`](fan-probe.md): `tools/mf_probe.py`, the VM's tool for
  the fan-side checks (K11 direction, K12 the light's level while off, K13
  bursts, K15 the dim staircase, K16 for Min On) and for read-only reads and
  fixtures: what each check writes to the fan and for how long, and its
  safety rails.
- [`../probes/README.md`](../probes/README.md) (outside this folder): the M1
  probe (#17), a throwaway Composer package built outside `src/` so no
  release carries it, and the Windows session's brief for each check K4–K10
  and K14 of
  [`v1-design.md`](v1-design.md#11-hardware-checks-before-the-first-install);
  deleted from the house after M1.
- [`doc-coherence-design.md`](doc-coherence-design.md): the rules of the
  documentation review of #213: what is true (the code first), what may
  change in which kind of document, the style and placeholders, and who
  reviews which files.
