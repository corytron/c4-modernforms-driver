# Status of the Modern Forms fan driver (2026-11-07)

The single page that says what is built, what runs on the house, and what is
open. Contracts and design notes keep their history; where they and this
page disagree about the present, this page and the code win.

**1.1 "Jamis" is the latest release and runs on the house; the stock
driver is gone.** Build 97 of v1.1 was released on 2026-11-05 and
installed in place on 2026-11-07 (deploy issue #98, the round in Discussion
#100, the announcement in Discussion #99): Keypad Links keeps a keypad on a
link while another of its buttons is still bound there (#92). Before it,
v1.1 (build 87) was released and installed in place on
2026-11-05 (deploy issue #84, the round in Discussion #86, the announcement
in Discussion #85): the Fan Cycle link stops at Level 6 (#77) and the
driver's own icons (#78), the owner's answers to the last v1 questions
(#14). Before it, v1.0 (build 67) was released and installed in place on 2026-11-05
(deploy issue #67, the round in Discussion #70, the announcement in
Discussion #68): beta.3 plus Breeze in Fan Model after a restart (#59) and
linear trims (#49), released by the owner without a hardware test of those
two fixes. The same day build 73 of 1.0 replaced it (deploy issue #74, the
round in Discussion #75): Breeze stored, so Fan Model shows it before the
fan's first answer (#69). Before it, v1.0-beta.1 (build 25) was installed on 2026-11-04 beside the stock
WAC device; the same evening the bedroom keypad was cut over to its Button
Links and the stock device was removed (deploy issue #30, the round in
Discussion #34). On 2026-11-05 v1.0-beta.3 (build 51) replaced it in
place (deploy issue #53, the round in Discussion #54): the colour per speed
(#31), the fan's product name (#37), following the fan to a new address by
itself (#39), and no Migration Report or Migration and Stock Device rows
(#45: one-off tooling for the cutover; the owner's rule since 2026-11-04
keeps such tooling out of the driver). v1.0-beta.2 (build 29) was published
but never installed. The owner tested beta.3 on 2026-11-05 and every test
passed, the follow to a new address included (#58).

## What runs on the house

- **v1.1, build 97**, one device: `deploy/house.yaml` and the environment
  `house` agree (deployment success, 2026-11-07; Keypad Links reads `7 of 12
  links bound` with all seven rows). Debug Mode Off; `Follow
  Address Changes` On; Fan Model reads `Gen 3, Aviator 5 (1811-5-54),
  light kit F4IN-120V-R1-30, Breeze`, and the update did not rewrite it
  (Breeze stored since build 73, #69). The device was re-created from 1.1
  on 2026-11-05 (#91, Discussion #93), so its items show the driver's own
  icons (#78): Composer stamps a proxy's icon when the device is created,
  and the first device, from beta.1, had kept Control4's.
- **Controller:** OS 3.4.3, managed with Composer Pro 3.4.2 on the Windows
  machine.
- **The fan:** one Modern Forms fan with its light (a Gen 3), on this
  driver: two items, the fan (the parent, with every property, action and
  the Documentation tab) and its light, "Aviator 5" and "Aviator 5 Light".
  The first device (2026-11-04, beta.1) carried the stock items' names
  "Fan" and "Fan Light" until the owner clicked Name Items After Fan on
  2026-11-05. The same evening it was replaced by a device added from 1.1
  for the icons (#91): Find Fans, then Use Selected Fan, which named the
  fresh items itself. Every setting was copied, the seven bindings and both
  Double Tap lines were moved, and the old device was deleted. The owner's
  keypad check afterwards passed. Status online, Preset Level 3, Default
  On Brightness 100, as on the stock device; the stock device's parent was
  its light. In the room's Navigator list the new items took the first
  places.
- **The bedroom keypad** is bound to the driver's links: Low to Fan Speed 2
  (`Speed 2 Link Also Lit At` Speed 1), Medium to Fan Speed 3, Med-High to
  Fan Speed 4, High to Fan Speed 5 (`Speed 5 Link Also Lit At` Speed 6), Off
  to Fan Off, Up to Light Top and Down to Light Bottom; the fan buttons on
  Follow Connection in their own colours (`#8000FF`, Off `#800000`, off
  `#000000`). Programming left: Low's Double Tap sets Level 1 and High's
  Level 6 on the new fan. The LED scripts, the stock fan's Fan Speed Changed
  script and the Fan LED Settle timer's script are deleted, and the empty
  timer itself went on 2026-11-05 at the owner's yes (only Composer's
  default "Every 5 minutes" timer is left). `Speed LED Colors` is `Per speed` since
  beta.3: Speed 1 `0,0,255`, Speeds 2 to 5 `128,0,255` (the keypad's own
  `#8000FF`), Speed 6 `255,96,0`, off `0,0,0`, so Low is blue at speed 1
  and High orange at speed 6 again, as before the cutover.
- **The way back:** the project backup and every script's Copy All from
  before the cutover are on the Windows VM (they hold private data); re-add
  the stock driver and paste the scripts back, or load the backup.
- **Seen on the house (2026-11-05, #58):** the owner's own test on the
  bedroom keypad: presses, the LEDs following the fan in their per-speed
  colours, the double taps on Low and High, and the light's Up and Down
  buttons, all passed. The follow to a new address (#39, checklist step
  45) passed through a stand-in address on the VM: `Fan Offline` 46
  seconds after the fan stopped answering there, `Followed fan …` 9
  seconds later, `Fan Address` written back by the driver; a typed address
  where nothing answers was kept, with no follow (Discussion #60).

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

Every open item is an issue (`gh issue list --state open`). On 2026-11-07
none is open. The list below is what was open on 2026-10-27 and how each
ended; all of them are closed.

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
  controller's (K9). K8's three taps in the Control4 app (the owner's phone)
  were never run. The probe device and its test room were deleted on
  2026-11-04, and its package left Composer's driver library on 2026-11-05
  with the owner's yes; nothing of the probe is left on the Windows machine
  or in the project. #17 is closed.
- **#26** M3, the build: the driver is written and unit-tested (the transport,
  the state model, the fan proxy and links, the light, Find Fans, the
  Migration Report (removed again by #45), the manual and the Composer checklist; `driver.xml` from
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
  not deleted; the stock device and the LED workaround removed later (done
  on 2026-11-04; the Migration Report that checked it is removed by #45).
- The 1.0 codename is "Arrakis"; 1.1 is "Jamis" (approved 2026-11-05, #81).
- Control4 is the source of truth: automations live in Control4
  programming, not in the Modern Forms app (`CLAUDE.md`).
