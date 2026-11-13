# Status of the Modern Forms fan driver (2026-11-13)

The single page that says what runs on the house, what is open and what
each release brought. Contracts and design notes keep their history; where
they and this page disagree about the present, this page and the code win.
The page has four parts: [what runs on the house](#what-runs-on-the-house),
[what is open](#open), the [release history](#release-history), newest
first, and the [decisions that stand](#decided-not-open).

## What runs on the house

### The release

**1.10 "Shield Wall", build 236** is installed in place (2026-11-13; deploy issue #226; verified: the rebind 31 s after the restart and readings flowing when the owner covered the sensor, Discussion #229) (#223: the root cause of the stuck dark pause, measured on 2026-11-13: after the driver starts, the keypad sends it no readings until its binding is made again, so the driver now makes it again 30 s after every start; every keypad reading logged; a 12 h safety net; the last reading in `Keypad Links`). Before it, **build 226**, both packages (`modernforms_fan.c4z`
and `modernforms_breeze_fan.c4z`), installed in place on 2026-11-13 (the
hardening from the security review, #214; deploy issue #219, closed;
deployment 7758179904, success, "Driver Version 226 on 2 devices"; the
round in Discussion #220). `deploy/house.yaml` and the environment `house`
agree. The Lua command window of both devices now reads "Encrypted Driver
or Execute Not Allowed" and runs nothing; Debug Mode output still shows. No
controller reboot was needed. What 1.10
brings is the first entry of the
[release history](#110-shield-wall-build-226-2026-11-13).

### Controller, devices and names

- **Controller:** OS 3.4.3, managed with Composer Pro 3.4.2 on the Windows
  machine.
- **The fan:** one Modern Forms fan with its light (a Gen 3). One device of
  the fan driver gives two items, the fan (the parent, with every property,
  action and the Documentation tab) and its light: **Aviator 5** and
  **Aviator 5 Light**. `Fan Model` reads `Gen 3, Aviator 5 (1811-5-54),
  light kit F4IN-120V-R1-30, Breeze`. Status online, Preset Level 3,
  Default On Brightness 100, as on the stock device. This device was added
  from 1.1 on 2026-11-05 for the driver's own icons (#91, Discussion #93):
  Find Fans, then Use Selected Fan, which named the fresh items itself.
  Every setting was copied, the seven bindings and both Double Tap lines
  were moved, the old device was deleted, and the owner's keypad check
  afterwards passed. Composer stamps a proxy's icon when the device is
  created, which is why the first device, from beta.1, had kept Control4's
  (#78). That first device (2026-11-04) carried the stock items' names
  "Fan" and "Fan Light" until the owner clicked Name Items After Fan on
  2026-11-05. The stock device's parent was its light. In the room's
  Navigator list the new items took the first places.
- **The Breeze fan:** **Aviator 5 Breeze** (driver Modern Forms Breeze Fan,
  proxy `fan.c4i`, speeds Breeze 1 to 3), added by Add Breeze Fan in the
  fan's room on 2026-11-08 after the 1.2 Breeze switch was deleted (#121).
  Its input is bound to the fan's `Breeze Switch` output, it reads `Breeze
  off on Aviator 5` while Breeze is off, and it sits right after the fan in
  the room's Navigator list.

### Settings

| Where | Row | Value |
| --- | --- | --- |
| Fan item | `Follow Address Changes` | On |
| | `Poll Interval (s)` | 15 |
| | `Light Min On (%)` | 10 (since 1.8, #195; a first setting, the first glow was not measured) |
| | `Keypad Links` | `7 of 13 links bound; LED settings shown` (`; LED animations paused: the keypad is dark` while the bound keypad reads dark) |
| | `Speed 2 Link Also Lit At` | Speed 1 |
| | `Speed 5 Link Also Lit At` | Speed 6 (every other `Speed N Link Also Lit At`: No other speed) |
| | `Speed LED Colors` | Per speed (since beta.3) |
| | `Speed 1 LED Color` to `Speed 6 LED Color`, `Speed LED Off Color` | Speed 1 `0,0,255`; Speeds 2 to 5 `128,0,255` (the keypad's own `#8000FF`); Speed 6 `255,96,0`; off `0,0,0` |
| | `Breeze LED Animation` | Gusts |
| | `Breeze LED Bottom` | Highest speed (High is the lowest speed button, checklist step 64) |
| | `Breeze LED Step (ms)` | 120 |
| | `Breeze LED Night Brightness (%)` | 50 |
| | `Speed LED Animation` | Speeds 2 to 5 |
| | `Speed LED Rest (s)` | 5 (the owner's choice, and the default since 1.7) |
| | `Pause LED Animations Below` | 10 |
| | `Debug Mode` | Off on both devices (`deploy/house.yaml`) |
| | Preset Level (the fan's settings page) | Level 3 |
| Light item | Default On Brightness | 100 |
| | Default Brightness Rate | 3 s (since 2026-11-09, Discussion #160) |
| | Click Rates Ramp Up and Ramp Down | 3 s each, live since a controller reboot between 2026-11-09 and 2026-11-12 (Discussion #199) |
| | Hold Ramp Rates | 5 s each (unchanged) |

All 21 keypad LED rows are shown, since the keypad is bound to Fan Speed 2
to 5 (#178).

### The keypad and its neighbours

- **The bedroom keypad** (a Control4 keypad dimmer) is bound to the
  driver's links: Low to Fan Speed 2, Medium to Fan Speed 3, Med-High to
  Fan Speed 4, High to Fan Speed 5, Off to Fan Off, Up to Light Top and
  Down to Light Bottom. Top to bottom it reads Low, Medium, Med-High, High,
  then Off, then Up and Down. The fan buttons are on Follow Connection in
  their own colours (`#8000FF`, Off `#800000`, off `#000000`), so with the
  per-speed colours Low is blue at speed 1 and High orange at speed 6, as
  before the cutover. No button is bound to Fan Breeze: while Breeze blows
  no fan LED shows a steady state (Off is dark, and the speed buttons play
  the gusts).
- **Its ambient reading** goes to the fan: since the 1.9 install its
  Ambient Light Level (Source) is bound to the fan's Ambient Light Level
  (Follower), and its Sensing reads "Source" with its LED curve unchanged
  (#207).
- **Its LED dimming** (#198, Discussions #199 and #205): the keypad dimmer
  and the two Control4 switches beside it share one Status LED curve with a
  night floor of 0 (Min 0, Max 255, Dark Room below 10, Bright Room above
  50; the backlight unchanged at Min 0, Max 180), at the owner's word "all
  dark". Below Dark Room every status LED on all three is dark, the speed
  chase and the Breeze gusts included, and they come back together as the
  room brightens. The two switches still read their own sensors
  ("Independent").
- **A Control4 keypad dimmer beside the fan**, whose lamp was slow to
  start, has Min On 10 (it was 1) since 2026-11-12 (Discussion #199).
- **Programming left:** Low's Double Tap sets Level 1 and High's Level 6 on
  the fan. The keypad's LED scripts, the stock fan's Fan Speed Changed
  script and the Fan LED Settle timer's script are deleted, and the empty
  timer itself went on 2026-11-05 at the owner's yes; only Composer's
  default "Every 5 minutes" timer is left.

### The way back

The project backup and every script's Copy All from before the cutover are
on the Windows VM (they hold private data): re-add the stock driver and
paste the scripts back, or load the backup.

## Open

Every open piece of work is an issue (`gh issue list --state open`). The
documentation review (#213, PR #215, the rules in
[`doc-coherence-design.md`](doc-coherence-design.md)) and the security
review (#214, PR #217, the summary in
[`SECURITY.md`](../SECURITY.md#security-review-2026-11-13-214)) are done.

Checks on the house that were never run or are still being read. None
blocks a build or a release; each belongs to its closed issue, where its
result goes as a comment:

- **#207, the pause in the dark.** Not yet seen on the house. Measured on
  2026-11-12 (Discussion #208 and the issue): the keypad sends its reading
  only when it changes, and with its LEDs dark at night the bedroom's
  reading stayed at 1, so nothing arrived after the bind; the readings that
  flickered during the probe came every 5 s, the chase's rest, and were
  probably the chase's own light on the sensor. The pause starts at the
  next change of the room's light (lights going off).
- **#195, Light Min On.** The fan light's first glow was not measured; 10 is
  a first setting. The contract's checks (a hold from off and a Navigator ON
  lit from the first moment, the slider at 1 % glowing) wait for a
  convenient moment.
- **#141, the light fades.** The tap fades and the second-tap stop are live
  since the controller reboot, but the probes FP0 to FP7 and H1 to H5 (H4
  sets `light.LEDS_FOLLOW`) of
  [`light-fades-design.md`](light-fades-design.md#7-on-the-house), and
  checklist section K, have not run; they run one at a time with the owner
  watching. H6 and H7, the Click Rates in Composer, were answered by
  Discussions #160 and #199 (the rows show without a reboot; a value set in
  them sticks only after one).
- **#159, the speed chase.** Check 4, a Breeze press between chases, was not
  watched (the driver spec covers it).
- **#137, Breeze on the keypad LEDs.** Checklist steps 66 to 71 (HB3 to HB7
  and the night brightness on a release build) are open; the design rounds
  covered the look at night.
- **#17, M1.** K8's three taps in the Control4 app (the owner's phone) were
  never run.
- **#39, the address follow.** The router form of checklist step 45 (a) was
  not run; step 46 (a firmware change) waits for the fan's next firmware.

## Release history

Newest first; one paragraph per release, with its issues and Discussions.
Release dates are those of `CHANGELOG.md` and GitHub (UTC); the house
rounds of the evening of 2026-11-12, local time, fall on 2026-11-13 there.
What every release changed, in full, is in [`CHANGELOG.md`](../CHANGELOG.md).

### 1.10 "Shield Wall", build 226 (2026-11-13)

Hardening from the security review (#214, PR #217; what was reviewed and
changed: [`SECURITY.md`](../SECURITY.md#security-review-2026-11-13-214)).
No redirect is followed, oversized, compressed or deeply nested answers are
refused, fan text is cleaned and capped, searches have budgets and keep
places for the pinned fan, a waiting pick lapses after 10 minutes, the
automatic follow stays in the fan's /24, Composer actions run only as
Composer sends them, every command waits for late init, Add Breeze Fan
never adds duplicates, light times are capped at 24 h, and both drivers lock
Composer's Lua command window in release builds (build 220's was open,
checked on the house on 2026-11-12). The tooling verifies the attestation's
ref, commit and runner, checks every package against its source, and serves
dev and test packages only from random one-file paths. The VM's old dev
package holding the dev key was deleted and the key rotated the same day.
No hardware round before the release, at the owner's word.

### 1.9 "Sandwalk", build 220 (2026-11-13)

The speed chase and the Breeze animation pause while the keypad's LEDs are
dark (#207, the contract [`ambient-pause-design.md`](ambient-pause-design.md),
the probe in Discussion #208, the announcement in Discussion #212). The
keypad dimmer bound to the fan's speed links pushes its ambient light
reading to the fan's new Ambient Light Level (Follower) input; while it
reads below `Pause LED Animations Below` (10), the chase and the gusts send
nothing, and a new run starts after 10 s of light. The install (deploy
issue #211, deployment 7757289093, the night of 2026-11-12): build 220 on
both devices, `Pause LED Animations Below` 10, the keypad dimmer's Ambient
Light Level (Source) bound to the fan's Ambient Light Level (Follower), its
Sensing "Source"; no controller reboot. Whether the pause shows is still
being read ([Open](#open)).

### 1.8 "Carryall", build 207 (2026-11-13)

`Light Min On (%)` for a light kit that stays dark at its lowest levels
(#195, the contract [`min-on-design.md`](min-on-design.md), the research in
Discussion #197, the announcement in Discussion #204): Control4's 1 % becomes
that fan level, as Min On trims a Control4 dimmer, so fades, holds, taps
and the slider light from their first step. The owner said to ship it
without hardware rounds. Installed in place the night of 2026-11-12 (deploy
issue #203, deployment 7756142607, "Driver Version 207 on 2 devices"), with
no controller reboot; `Light Min On (%)` was then set to 10. In the same
Windows round (Discussion #199) the session found that the fan light's
Click Rates now keep 3 s (on 2026-11-09 they had snapped back to 0.250 and
0.750), so the controller had been rebooted since and 1.5's tap fades and
second-tap stop are live; it also set the Min On of a keypad dimmer beside
the fan from 1 to 10.

**Beside 1.8, without a release: the keypads' ambient LED dimming (#198,
2026-11-12).** The speed chase and the Breeze gusts are scaled by the
keypad's own Ambient Light Profile, like its other LEDs, so they follow its
dimming policy with no driver change (the research:
[`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md),
[`edge-cases-led-dimming.md`](edge-cases-led-dimming.md), Discussion #200).
The keypad dimmer bound to the fan's speed links and the two switches beside
it had night floors of 13 and 17 out of 255, so a lit LED never went dark.
At night the switches looked dark only because their lights were off and
they showed black and a half red, which vanish at that level, while the
chase's purple, with a full blue channel, stayed visible (the owner saw the
keypad's own half-red LED dark too). A first change set only the keypad
dimmer's floor to 0, then all three to the switches' 17; at the owner's
word ("all dark") all three now share the curve with a floor of 0
(Discussion #205; the settings are under
[The keypad and its neighbours](#the-keypad-and-its-neighbours)). Since 1.9
the animations also stop sending while the keypad is dark.

### 1.7 "Stillsuit", builds 188 and 193 (2026-11-10)

The speed chase's first chase comes 2.5 s after a speed is selected from
any source, then one every rest, whose default is now 5 s (#177, build
188). The keypad LED rows (20 then, 21 since 1.9) show only while a button
is bound to a fan speed link (#178), and an unbound keypad leaves `Keypad
Links` (#185), both build 193. Deploy issues #181 (build 188, deployment
7674769871) and #187 (build 193, deployment 7675073354, both closed); the
announcement and the install rounds are Discussion #184. Build 193 was
installed in place with "Update Succeeded" only, no "Restart Director?":
Driver Version 193 and Debug Mode Off on both devices, `Speed LED
Animation` Speeds 2 to 5, `Speed LED Rest (s)` 5, `Speed LED Colors` Per
speed, `Keypad Links` `7 of 13 links bound; LED settings shown`, all 35
rows (37 since 1.9) present, no error or warning. On a scratch fan device
with nothing bound the 20 rows hid by themselves about 15 s after the add,
and the house fan, with its keypad on Fan Speed 2 to 5, kept every row. The
owner watched the 2.5 s first chase at the keypad: it comes 2.5 s after a
speed is selected (PR #191).

### 1.6 "Crysknife", builds 176 and 182 (2026-11-09 and 2026-11-10)

A chase on the keypad's speed LEDs at a fixed speed (#159, PR #165, the
contract [`speed-leds-design.md`](speed-leds-design.md), the research in
Discussions #161 to #163, the agents' hand-backs in Discussion #166): a
dot in the speed's colour runs across the bound speed buttons in the
direction the fan blows, faster at higher speeds, with a constant rest
between chases in which the selected speed's LED is lit. It also fixes #164
(the Breeze engine's preload flag). Deploy issues #169 (build 176,
deployment 7673708993) and #175 (build 182, deployment 7674344885), the
announcement in Discussion #168, the install rounds in Discussion #170.
Both builds installed in place with one "Update Succeeded" and no "Restart
Director?", no device deleted or re-added, Driver Version and Debug Mode Off
read back on both devices, no error or warning in the log. Build 176 added
`Speed LED Animation` (then set to Speeds 2 to 5) and `Speed LED Rest (s)`
(10 at the install; the owner chose 5). The owner checked it at the keypad
on 2026-11-10: the chase at speed 3, the pace at speeds 2 and 5, and the
reversed direction look right; the selected button blinked twice at the
edge speeds in build 176, which build 182 fixed (#172, rechecked). The
Breeze press between chases (check 4) was not watched.

### 1.5 "Shadout Mapes", build 165 (2026-11-09)

Simulated fades for the fan's light (#141, the contract
[`light-fades-design.md`](light-fades-design.md), the decisions in #146, the
research and review rounds in Discussions #148, #151 and #152, the
announcement in Discussion #155). The owner said to ship without the probes.
Installed in place (deploy issue #154, deployment 7668744012): Composer asked
"Restart Director?" once, for the fan driver (answered Yes: the build adds
`click_rates`, a capability), then "Update Succeeded"; no device deleted or
re-added; Driver Version 165 and Debug Mode Off on both, the fan `Online:
fan off, light 100 %`, the Breeze fan `Breeze off on Aviator 5`, no error or
warning. The Click Rates rows showed at once with Composer's defaults (0.250
and 0.750 s), but 3.000 typed into them snapped back until the controller
was rebooted from System Manager. The Windows session set the light's
Default Brightness Rate to 3 s on 2026-11-09, and a room's outlet dimmer's
rates to 3 s (Discussion #160). Since the reboot the Click Rates keep 3 s
(2026-11-12, Discussion #199): the tap fades and second-tap stop are live,
and the probes are still to run ([Open](#open)).

### 1.4 "Sietch Tabr", build 152 (2026-11-09)

Breeze on the keypad LEDs (#137, the contract
[`breeze-leds-design.md`](breeze-leds-design.md), the rounds in Discussion
#138, the announcement in Discussion #144): the speed buttons go dark when
Breeze starts; gusts with a twinkling tail run the way the fan blows; an
ending wipe runs the other way when Breeze ends; the animation is half as
bright between sunset and sunrise at the project's location (`fan/sun.lua`).
It was designed on the house keypad with the owner watching, through the
dev loop; the night brightness and the direction shipped at the owner's
word, without a further hardware round. Installed in place (deploy issue
#142, deployment 7649366122, the round in Discussion #150): one "Update
Succeeded", no "Restart Director?"; Driver Version 152 and Debug Mode Off on
both; the fan `Online: fan speed 2, light off`, the Breeze fan `Breeze off on
Aviator 5`; `Breeze LED Animation` Gusts, `Breeze LED Bottom` Highest speed,
`Breeze LED Step (ms)` 120, `Breeze LED Night Brightness (%)` 50 (new);
`Keypad Links` `7 of 13 links bound`; the Dev Server and Dev State rows
gone; no error or warning. The release install ended the dev loop, and the
dev server on the VM is stopped.

### 1.3 "Ornithopter", build 124 (2026-11-08)

Fan mode and Breeze mode exclude each other (the owner's finding on their
fan), so the fan shows fan mode only, a fan speed ends Breeze and an off
stops the fan; Breeze is a second fan device, the Breeze fan
(`modernforms_breeze_fan.c4z`, Breeze 1 to 3, #121,
[`breeze-design.md`](breeze-design.md#11-13-ornithopter-fan-mode-breeze-mode-and-the-breeze-fan-121)).
Installed in place (deploy issue #126, the round in Discussion #132, the
announcement in Discussion #127): the 1.2 Breeze switch was deleted (nothing
named it) and Add Breeze Fan added the Breeze fan, which the room's Navigator
list already showed right after the fan; the Navigators were refreshed.
Read back: `Keypad Links` `7 of 13 links bound` with all seven rows, Found
Fans `This device's fan answered; no other fan found`, six actions with Add
Breeze Fan last, Debug Mode Off on both, `Follow Address Changes` On, and
`Fan Model` not rewritten by the update (Breeze stored since build 73, #69).
On their phone the owner confirmed Breeze 1, 2, 3 and off, with the main
fan showing off while Breeze runs (#121).

### 1.2 "Thumper", build 115 (2026-11-07)

Two packages, `modernforms_fan.c4z` and the Breeze switch,
`modernforms_breeze.c4z` (deploy issue #117, the round in Discussion #119,
the announcement in Discussion #118). Found Fans fills by itself and the
Find Fans action is gone (#102,
[`auto-discovery-design.md`](auto-discovery-design.md)); Breeze in Control4
(#111, [`breeze-design.md`](breeze-design.md)): the commands, the `Breeze`
variable, the events, the condition, keypad link 311, and the Breeze switch
for the Navigators, which Add Breeze Switch added to the fan's room and
bound to the fan. The fan's Breeze behaviour was not measured on the house:
the owner chose to assume the results (BZ5).

### 1.1 "Jamis", builds 87 and 97 (2026-11-05)

Build 87 (deploy issue #84, the round in Discussion #86, the announcement in
Discussion #85), installed in place on 2026-11-05: the Fan Cycle link stops
at Level 6 (#77) and the driver's own icons (#78), the owner's answers to
the last v1 questions (#14); the codename was approved that day (#81). Build
97 (deploy issue #98, the round in Discussion #100, the announcement in
Discussion #99), released on 2026-11-05 and installed in place on
2026-11-07: Keypad Links keeps a keypad on a link while another of its
buttons is still bound there (#92).

### 1.0 "Arrakis", builds 67 and 73 (2026-11-05)

Build 67 (deploy issue #67, the round in Discussion #70, the announcement in
Discussion #68) was beta.3 plus Breeze in Fan Model after a restart (#59) and
linear trims (#49), released by the owner without a hardware test of those
two fixes. The same day build 73 replaced it (deploy issue #74, the round in
Discussion #75): Breeze stored, so Fan Model shows it before the fan's first
answer (#69). Both were installed in place.

### The prereleases and the cutover (2026-11-04 and 2026-11-05)

v1.0-beta.1 (build 25) was installed on 2026-11-04 beside the stock WAC
device; the same evening the bedroom keypad was cut over to its Button
Links and the stock device was removed (deploy issue #30, the round in
Discussion #34; [`migration-design.md`](migration-design.md)). v1.0-beta.2
(build 29) was published but never installed. On 2026-11-05 v1.0-beta.3
(build 51) replaced beta.1 in place (deploy issue #53, the round in
Discussion #54): the colour per speed (#31), the fan's product name (#37),
following the fan to a new address by itself (#39), and no Migration Report
or Migration and Stock Device rows (#45: one-off tooling for the cutover;
the owner's rule since 2026-11-04 keeps such tooling out of the driver).

**Seen on the house (2026-11-05, #58):** the owner tested beta.3 on the
bedroom keypad and every test passed: presses, the LEDs following the fan
in their per-speed colours, the double taps on Low and High, and the
light's Up and Down buttons. The follow to a new address (#39, checklist
step 45) passed through a stand-in address on the VM: `Fan Offline` 46
seconds after the fan stopped answering there, `Followed fan …` 9 seconds
later, `Fan Address` written back by the driver; a typed address where
nothing answers was kept, with no follow (Discussion #60).

### Before the first build (2026-10-27 to 2026-11-04)

The scaffold (#1, PR #3), the v1 research (#2, PR #5) and the v1 plan with
the owner's decisions (#6) are closed; the scaffold, the research and the
plan are posted in Discussions #7, #8 and #9. What was open on 2026-10-27,
and how each ended (all closed):

- **#17** M1, the probes of
  [`v1-design.md`](v1-design.md#11-hardware-checks-before-the-first-install)
  (a throwaway package beside the stock device): all but one check done.
  The fan-side checks K11, K12, K13 and K15 ran on 2026-10-27
  (`tools/mf_probe.py`, [`fan-probe.md`](fan-probe.md)). The Windows
  session installed the Composer probe package (`probes/`,
  `build/probe/mf_probe.c4z`) in a test room and ran K4, K5, K6, K7, K8's
  Lua part, K9, K10, K14 and K19 in two rounds (2026-10-27 and 2026-11-04,
  the second with the owner at the keypad and the restore check after each
  borrowed button), all in
  [`v1-design.md`](v1-design.md#111-what-the-probe-has-shown-so-far-17).
  Results: **K10 passed, Find Fans went into v1** (replaced by the automatic
  search in 1.2); keypads take `BUTTON_COLORS` over a link (V27 shipped from
  beta.2, #31); Up and Down have Button Link rows; Composer refuses a
  package whose minimum OS is above the controller's (K9). K8's three taps
  in the Control4 app were never run. The probe device and its test room
  were deleted on 2026-11-04, and its package left Composer's driver library
  on 2026-11-05 with the owner's yes; nothing of the probe is left on the
  Windows machine or in the project.
- **#26** M3, the build split of
  [`v1-design.md`](v1-design.md#13-m3-build-split): the driver written and
  unit-tested (the transport, the state model, the fan proxy and links, the
  light, Find Fans, the Migration Report (removed again by #45), the manual
  and the Composer checklist; `driver.xml` from section 2 of
  [`v1-design.md`](v1-design.md)), as
  [`v1-design.md`](v1-design.md#912-as-built-m3-26) says it was built. The
  owner decided (2026-11-04) to test once, with the complete driver, so the
  first install was a prerelease through the
  [Composer checklist](composer-checklist.md).
- **#14** Owner questions from the v1 contract: the Cycle link wrapping and
  custom icons, each with a default (answered by 1.1, #77 and #78; the
  colour per speed was answered yes, #31, 2026-11-04).
- **#31** A colour per speed on the keypad links (V27): `Speed LED Colors`
  and its seven colour rows, a property-only change from v1.0-beta.2, so the
  bedroom keypad keeps blue at speed 1 and `#ff6000` at 6 after the cutover.

Work without a driver release since: every core of the VM in checks, tests
and builds (#183, Discussion #190), and release notes that open with what
the codename means (#192, Discussion #194).

## Decided, not open

From 2026-10-27 (#6; the specification is [`v1-design.md`](v1-design.md),
the cutover [`migration-design.md`](migration-design.md)), with what later
releases added:

- Two packages: the **Modern Forms Fan** driver (`src/modernforms_fan/`,
  `modernforms_fan.c4z`), one device per fan with a fan proxy and a
  `light_v2` proxy and its own Button Links for every speed, Off, Toggle,
  Cycle and (since 1.2) Breeze and the light's Top, Bottom and Toggle, with
  keypad LEDs; and since 1.3 the **Modern Forms Breeze Fan** driver
  (`src/modernforms_breeze_fan/`, `modernforms_breeze_fan.c4z`), added by
  the fan's action Add Breeze Fan.
- Minimum OS 3.3.0, checked at run time too; Gen 1–3 fans with six speeds
  (Level 1 to Level 6); the Breeze fan has three (Breeze 1 to 3).
- WAC's API License Agreement: the project stays off it and builds on the
  public open-source clients and its own read-only measurements
  ([`design.md`](design.md#method), "Method").
- The migration: one cutover sitting with the stock programming disabled,
  not deleted; the stock device and the LED workaround removed later (done
  on 2026-11-04; the Migration Report that checked it is removed by #45).
- Every X.Y has a codename in `.github/codenames.json`, from 1.0 "Arrakis"
  (approved 2026-10-27, #6) and 1.1 "Jamis" (approved 2026-11-05, #81) to
  1.9 "Sandwalk", and every release's notes open with what it means (#192).
- Control4 is the source of truth: automations live in Control4
  programming, not in the Modern Forms app (`CLAUDE.md`).

## The repository on GitHub (read 2026-10-27)

- The labels of [`.github/labels.json`](../.github/labels.json) exist,
  `mf-api` and `hardware` among them; the project board is user project 2,
  "Modern Forms driver" (still not public on 2026-11-13).
- Discussions are on, with GitHub's default categories (releases in
  Announcements, reports in Show and tell or General, decisions in Ideas).
- The environment `house` exists. Secret scanning, push protection,
  Dependabot security updates and private vulnerability reporting are on.
- `main` is protected: pull requests only, the four required checks, the
  branch current, conversations resolved, admins included; release tags
  `v*` cannot be deleted except by an admin. CodeQL's default setup (Python,
  Actions) and the Scorecard workflow scan every push to `main`; the code
  scanning issue the triage workflow keeps (#4) is closed, and no alert was
  open on 2026-11-13.
