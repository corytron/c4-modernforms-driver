# Status of the Modern Forms fan driver (2026-11-13)

The single page that says what is built, what runs on the house, and what is
open. Contracts and design notes keep their history; where they and this
page disagree about the present, this page and the code win.

**1.8 "Carryall" is released: build 207, 2026-11-13 (#195, the contract
[`min-on-design.md`](min-on-design.md), the rounds in Discussions #197 and
#199).** It adds `Light Min On (%)` for a light kit that stays dark at its
lowest levels: Control4's 1 % becomes that fan level, as Min On trims a
Control4 dimmer, so fades, holds, taps and the slider light from their
first step. The owner said to ship it without hardware rounds; the house's
first glow was not measured. No controller reboot is needed. On
2026-11-12 the Windows session found the fan light's Click Rates now keep
3 s (they snapped back to 0.250 / 0.750 on 2026-11-09), so the controller
has been rebooted since and 1.5's tap fades and second-tap stop are live;
it also set the Min On of the keypad dimmer beside the fan, whose lamp was
slow to start, from 1 to 10 (Discussion #199). Before it:

**The keypads' ambient LED dimming (#198, 2026-11-12).** The speed chase
and the Breeze gusts are scaled by the keypad's own Ambient Light Profile,
like its other LEDs; the keypad dimmer bound to the fan's speed links had
a Status LED minimum of 13, so a lit LED, the chase included, stayed dimly
lit in a dark room. The Windows session set that minimum to 0 (Discussion
#204): below the Dark Room threshold every LED on that keypad goes dark,
the chase and the gusts included, and they come back along its curve as
the room brightens. No driver change (the research:
[`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md),
[`edge-cases-led-dimming.md`](edge-cases-led-dimming.md), Discussion #200).
The chase keeps sending its messages while unseen; a driver pause at night
is offered, not built.

**1.7 "Stillsuit" is installed on the house: build 193, released and
installed in place on 2026-11-10 (#177, #178, #185; deploy issues #181 and
#187; the announcement and install rounds in Discussion #184).** The speed
chase's first chase now comes 2.5 s after a speed is selected from any
source, then one every rest, whose default is now 5 s (#177). The 20 keypad
LED rows show only while a button is bound to a fan speed link (#178): on a
scratch fan device with nothing bound they hid by themselves about 15 s
after the add, and the house fan, with its keypad on Fan Speed 2 to 5, kept
every row. An unbound keypad now leaves `Keypad Links` (#185). The owner
watched the 2.5 s first chase on the keypad: it comes 2.5 s after a speed is
selected.

Before it, **1.6 "Crysknife"** ran on the house: build 182, released and
installed in place on 2026-11-10 (#159 and #172, deploy issues #169 and
#175, the announcement in Discussion #168, the install rounds in Discussion
#170).** It adds a chase
on the keypad's speed LEDs at a fixed speed
([`speed-leds-design.md`](speed-leds-design.md)): a dot in the speed's
colour runs across the bound speed buttons in the direction the fan blows,
faster at higher speeds, with a constant rest between chases in which the
selected speed's LED is lit. It also fixes #164 (the Breeze engine's preload
flag). The house has `Speed LED Animation` set to `Speeds 2 to 5` and
`Speed LED Rest (s)` at 5 (the owner's choice). The owner checked it at the
keypad on 2026-11-10: the chase at speed 3, the pace at speeds 2 and 5, and
the reversed direction look right; the selected button blinked twice at the
edge speeds in build 176, which build 182 fixed (#172, rechecked). The
Breeze press between chases (check 4) was not watched. No controller reboot
was needed for 1.6.

Before it, 1.5 "Shadout Mapes" ran on the house: build 165, released and
installed in place on 2026-11-09 (#141, deploy issue #154, the announcement
in Discussion #155). It adds simulated fades for the fan's light
([`light-fades-design.md`](light-fades-design.md), the research and review
rounds in Discussions #148, #151 and #152). **Nothing of it has run on the
hardware:** the owner said to ship without the probes. It needs one
controller reboot from System Manager before the new Click Rates rows load;
until then taps keep the old rates. The Windows session set the light's
Default Brightness Rate to 3 s on 2026-11-09 (and a room's outlet dimmer's
rates to 3 s); typing 3.000 into the light's Click Rates rows sent the
commands, but the rows read 0.250 and 0.750 again, which fits the capability
not being live before the reboot (Discussion #160). After the reboot the
probes H1 to H7 (including H4, which sets `light.LEDS_FOLLOW`) and FP0 to
FP7 run one at a time with the owner watching.

Before it, 1.4 "Sietch Tabr" ran on the house: build 152, released and
installed in place on 2026-11-09 (deploy issue #142, the announcement in Discussion
#144). It adds the
Breeze animation on the keypad LEDs (#137,
[`breeze-leds-design.md`](breeze-leds-design.md), the rounds in Discussion
#138):
- the speed buttons go dark when Breeze starts;
- gusts with a twinkling tail run the way the fan blows;
- an ending wipe runs the other way when Breeze ends;
- the animation is half as bright between sunset and sunrise at the
  project's location (`fan/sun.lua`).

It was designed on the house keypad with the owner watching, through the
dev loop. The night brightness and the direction shipped at the owner's
word, without a further hardware round. The release install ended the dev
loop.

Before it, 1.3 "Ornithopter" ran on the house; the stock
driver is gone. Build 124 of v1.3 was released and installed on
2026-11-08 (deploy issue #126, the round in Discussion #132, the
announcement in Discussion #127): fan mode and Breeze mode exclude each
other (the owner's finding on their fan), so the fan shows fan mode only, a
fan speed ends Breeze and an off stops the fan; Breeze is a second fan
device, the Breeze fan (`modernforms_breeze_fan.c4z`, Breeze 1 to 3, #121,
[`breeze-design.md`](breeze-design.md#11-13-ornithopter-fan-mode-breeze-mode-and-the-breeze-fan-121)).
The 1.2 Breeze switch was deleted (nothing named it) and Add Breeze Fan
added the Breeze fan, which the room's Navigator list already shows right
after the fan. On their phone the owner confirmed Breeze 1, 2, 3 and off,
with the main fan showing off while Breeze runs (#121).

Before it, build 115 of v1.2 "Thumper" was released and installed in place on
2026-11-07 (deploy issue #117, the round in Discussion #119, the
announcement in Discussion #118), with two packages:
`modernforms_fan.c4z` and the Breeze switch, `modernforms_breeze.c4z`.
Found Fans fills by itself and the Find Fans action is gone (#102,
[`auto-discovery-design.md`](auto-discovery-design.md)); Breeze in Control4
(#111, [`breeze-design.md`](breeze-design.md)): the commands, the `Breeze`
variable, the events, the condition, keypad link 311, and the Breeze switch
for the Navigators, which Add Breeze Switch added to the fan's room and
bound to the fan. The fan's Breeze behaviour was not measured on the house:
the owner chose to assume the results (BZ5).

Before it, build 97 of v1.1 "Jamis" was released on 2026-11-05 and
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

- **v1.7, build 193** (since 2026-11-10), the fan and its Breeze fan:
  deployment 7675073354, success; deploy issue #187 closed (build 188 before
  it the same day, deploy issue #181). Installed in place: "Update
  Succeeded" only, no "Restart Director?". Driver Version 193 and Debug
  Mode Off on both; `Speed LED Animation` Speeds 2 to 5, `Speed LED Rest
  (s)` 5, `Speed LED Colors` Per speed; `Keypad Links` "7 of 13 links
  bound; LED settings shown"; every row present. No error or warning.
- **v1.6, build 182** (2026-11-10 until 1.7), the fan and its Breeze fan:
  deployment 7674344885, success; deploy issue #175 closed. Installed in
  place: "Update Succeeded" only, no "Restart Director?". Driver Version
  182 and Debug Mode Off on both; `Speed LED Animation` Speeds 2 to 5,
  `Speed LED Rest (s)` 5; every other row as under build 176. No error or
  warning in the log.
- **v1.6, build 176** (2026-11-09 until build 182), the fan and its Breeze fan:
  `deploy/house.yaml` and the environment `house` agree (deployment
  7673708993, success; deploy issue #169 closed). The Windows session
  installed both packages in place: one "Update Succeeded" dialog, no
  "Restart Director?", no device deleted or re-added. Read back: Driver
  Version 176 and Debug Mode Off on both; the new rows `Speed LED Animation`
  (set to `Speeds 2 to 5` after the install) and `Speed LED Rest (s)` 10;
  `Speed LED Colors` Per speed; the fan `Online: fan speed 3, light off`;
  Keypad Links `7 of 13 links bound`; every other row as under 1.5. The log
  from the install onward has no error or warning.
- **v1.5, build 165** (2026-11-09 until the 1.6 install), the fan and its Breeze fan:
  `deploy/house.yaml` and the environment `house` agree (deployment
  7668744012, success; deploy issue #154 closed). The Windows session
  installed both packages in place: Composer asked "Restart Director?" once,
  for the fan driver (answered Yes: the build adds Click Rates, which loads
  only after the owner reboots the controller from System Manager), then
  "Update Succeeded"; no device deleted or re-added. Read back: Driver
  Version 165 and Debug Mode Off on both; the fan `Online: fan off, light
  100 %`, the Breeze fan `Breeze off on Aviator 5`; every other row as under
  1.4. The log from the install onward has no error or warning.
- **v1.4, build 152** (2026-11-09 until the 1.5 install), the fan and its Breeze fan:
  `deploy/house.yaml` and the environment `house` agree (deployment
  7649366122, success; deploy issue #142 closed). The Windows session
  installed both packages in place through Driver ▸ "Add or Update Driver or
  Agent…": one "Update Succeeded" dialog, no "Restart Director?", and no
  device deleted or re-added. Read back: Driver Version 152 and Debug Mode
  Off on both; the fan `Online: fan speed 2, light off`, the Breeze fan
  `Breeze off on Aviator 5`; `Breeze LED Animation` Gusts, `Breeze LED
  Bottom` Highest speed, `Breeze LED Step (ms)` 120, `Breeze LED Night
  Brightness (%)` 50 (new); Keypad Links `7 of 13 links bound`; the Dev
  Server and Dev State rows gone. The log from the install onward has no
  error or warning. The dev server on the VM is stopped.
- **v1.3, build 124** (2026-11-08 until the dev build of #137), two devices, the fan and its Breeze fan:
  `deploy/house.yaml` and the environment `house` agree (deployment
  success, 2026-11-08; Keypad Links reads `7 of 13 links bound` with all
  seven rows; Found Fans `This device's fan answered; no other fan found`;
  six actions, Add Breeze Fan last). The Breeze fan, "Aviator 5 Breeze"
  (proxy `fan.c4i`, speeds Breeze 1 to 3), was added by Add Breeze Fan in
  the fan's room after the 1.2 light-type switch was deleted, is bound to
  the fan's Breeze Switch output, read `Breeze off on Aviator 5`, and sits
  right after the fan in the room's Navigator list; the Navigators were
  refreshed. Debug Mode Off on both; on the fan `Follow
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

Every open item is an issue (`gh issue list --state open`). On 2026-11-09:
#183 (every core of the VM in checks, tests and builds) is open. #177,
#178 and #185 shipped as 1.7. #159 (the speed chase on the keypad LEDs, PR #165, the
research in Discussions #161 to #163, the agents' hand-backs in #166) and
#164 shipped as 1.6; its keypad checks wait for the owner. #141 (simulated light fades) shipped as 1.5 and its hardware
checks wait for the controller reboot and the owner at the keypad (see the
top of this page). The list below is what was open on
2026-10-27 and how each ended; all of them are closed.

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
