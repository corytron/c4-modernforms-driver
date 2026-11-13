# Speed LED chase: what Control4's guidance says, and what it costs (#159)

Research for [issue #159](https://github.com/corytron/c4-modernforms-driver/issues/159),
written 2026-11-09, read-only: nothing was sent to any device. The
owner wants a second keypad-LED animation, at the fixed speeds 2, 3, 4 and 5:
a chase over the buttons bound to the speed links, one pixel after the
other, in the direction the fan blows, at even intervals. Between chases the
LED of the selected speed is lit; while a chase plays it is not. The chase
runs faster at a faster speed, the pause between chases is always the same,
and the chase colour is the colour set for that speed in the driver.

A fixed speed is the fan's normal running state, so this animation can run
for many hours every day, unlike Breeze, which is an occasional mode. That
is the main difference from [`breeze-leds-design.md`](breeze-leds-design.md)
and the reason this note counts messages per hour and per day.

This note is the input for the contract's "Control4 guidelines" section. It
does not decide anything; section 8 gives recommendations.

> **What was decided** (2026-11-13, #213): the contract,
> [`speed-leds-design.md`](speed-leds-design.md), took most of section 8
> with these differences: the property is `Speed LED Animation` (`Off`,
> `Speeds 2 to 5`, `Speeds 1 to 6`) beside `Speed LED Rest (s)`; the chase
> preloads the chase colour into every dark pixel on every chase, 13
> messages for four buttons (11 at the edge speeds), instead of keeping it
> loaded (SL-D12, SL-D18); the rest's default is 5 s since 1.7, not the 10 s
> of section 8.3 (#177); and since 1.9 the chase pauses while the keypad is
> dark ([`ambient-pause-design.md`](ambient-pause-design.md), #207). The
> numbers below are this note's, for its 2N + 2 scheme.

**Sources and status key.** SDK files are cited by path under
`~/c4-tools/reference/`; the Snap One text is paraphrased, never copied.

| Short name | Path |
| --- | --- |
| KP | `docs-driverworks-proxyprotocol-keypad/source/includes/` (the button link page is the same file under `docs-driverworks-proxyprotocol/source/includes/`) |
| LV2 | `docs-driverworks-proxyprotocol-lightv2/source/includes/` |
| FUND | `docs-driverworks-fundamentals/source/includes/` |
| API | `docs-driverworks-api/source/includes/` |
| BLD, BLS, BLF, BLE | this repository's `docs/breeze-leds-design.md`, `breeze-leds-sdk-research.md`, `breeze-leds-field-research.md`, `edge-cases-breeze-leds.md` |
| HUE | the author's Hue driver, its `docs/c4-lighting-guidelines.md` (rows L7, L49, L53, L54; it cites Control4's dealer documentation, which this session did not re-read) |

**VERIFIED** names its source. **ASSUMED** says why. **SILENT** means the SDK
documentation says nothing about it; **not found** means a search of the
local sources found nothing. This repository has no `docs/c4-lighting-guidelines.md`
of its own yet; the Hue project's file is the checklist the project's rule
points to, and [`light-fades-design.md`](light-fades-design.md) section 9
is the format model (a table of guideline against how the design meets it,
then the departures with their reasons). The Breeze contract has no
section of that name; its decisions BL-D1 to BL-D30 and the edge cases
BL61 to BL70 play the same part.

## Summary

1. **Control4's guidance on keypad LEDs is thin and mostly indirect.** For
   a driver bound to a keypad button the SDK documents one thing: the
   button's LED is the bound driver's report of its state, over two
   messages, colours and lit state (KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`).
   Everything else that applies is the light_v2 warning against periodic
   updates that flood Zigbee and leave keypad LEDs wrong
   (FUND `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`), and the
   dealer-level behaviour of Follow Connection buttons, which the Hue
   project's checklist records (HUE L49, L53).
2. **A chase bends exactly one expectation: that the LED shows the state
   of the bound device at every moment.** For the length of each chase the
   selected speed's LED is dark although the fan runs at that speed. Every
   other expectation can be met or inherited from Breeze: truthful at rest,
   only links the driver owns, only with `Per speed`, off by default, one
   property to turn it off, newest state wins, nothing sent to buttons the
   driver does not own.
3. **Cost.** Each pixel is lit once and darkened once per chase, plus the
   selected pixel's dark-first and relight: **2N + 2 messages per chase**
   (10 for four pixels, 14 for six) when every speed has the same colour.
   With a rest of 10 s that is about 3,100 to 3,400 messages an hour for four
   pixels (under 1 a second) and about 4,100 to 4,700 for six. A burst never
   exceeds 2 messages per step, 16.7 a second at the fastest step, far under
   the 30 a second budget and the 40 a second measured clean for four buttons.
4. **Different colours per speed cost more.** The chase uses the selected
   speed's colour on every pixel, so the other N - 1 pixels must be
   preloaded with it when the speed changes, and put back when the chase
   ends for good (not after every chase): N - 1 extra messages at each end,
   nothing extra per chase.
5. **What cannot be known from local sources** is in section 9: above all,
   how the keypad and the mesh behave when the same four buttons change every
   few seconds for 10 to 24 hours a day, which no measurement in this
   repository covers.

## 1. What Control4's guidance says about keypad button LEDs

Each row paraphrases one item and says where it comes from. "Applies" says
whether it bears on an animation.

| # | The guidance, in other words | Source | Bears on the chase |
| --- | --- | --- | --- |
| SG1 | A keypad button bound to another driver shows that driver's state: the other driver reports the on and off colours and which of the two is active. A button asking (`REQUEST_BUTTON_COLORS`) gets both messages back. | KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md` (`REQUEST_BUTTON_COLORS`, `BUTTON_COLORS`, `MATCH_LED_STATE`) | Yes: the core expectation the chase bends |
| SG2 | On a Control4 dimmer or keypad the LED follows the bound device or the load, so a change made elsewhere (an app, a wall control) shows on the LED. The Hue project records this from the dealer pages "Follow Bound Device" and "LEDs Follow Load". | HUE L49, L53 (the dealer pages themselves not re-read here); BLS section 2 (binding a link sets the button to Follow Connection, VERIFIED on the house, ECC F16) | Yes: start and stop the chase from the shown state, from every source |
| SG3 | Do not send periodic notifies at short intervals. As of OS 3.3.0 the SDK lists 20 ms, 500 ms and 1000 ms as examples of intervals drivers should no longer use for light-level updates. The costs it names: slow proxies, Director and Navigators, wrong Advanced Lighting Scene tracking, **excessive Zigbee traffic and often incorrect keypad button LED status**, and spurious programming. | FUND `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md` (the bullet list under "Brightness Target API"); LV2 `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/_12-LIGHTLEVEL.md` (usage note) | Yes: a chase every few seconds is a periodic update. The text is about light-level notifies, not LED messages; that LED messages share the Zigbee cost is ASSUMED |
| SG4 | Where something takes time, send one message at the start and one at the end and let the receiver animate (the CHANGING notify). Emulating motion with many small updates is what the SDK moved away from. | FUND `_50-LIGHTV2BESTPRACTICE.md` ("Brightness Target API", "Brightness and Color Changing API") | Yes, as a contrast: the button link has **no** transition or effect message (KP `62/_1` lists only `BUTTON_COLORS` and `MATCH_LED_STATE`, plus the unspecified `SET_BUTTON_COLOR`), so a chase can only be emulated, one message per change. A departure forced by the protocol |
| SG5 | Commands that arrive back to back must all take effect; where the device cannot take them back to back, debounce or queue them into one change. | FUND `_50-LIGHTV2BESTPRACTICE.md` ("Handling Consecutive Brightness and Color commands"); HUE L13 | Yes, by analogy: a speed change in mid-chase is a new state; coalesce, newest wins, never queue a backlog |
| SG6 | The button link assumes every keypad has the same button and LED functionality, so drivers sometimes fake it; there is no API to ask hardware what it supports, and no limit on what can be sent over a link. | KP `62/_1` (introduction) | Yes: the driver cannot know whether a bound button has an LED, nor that a keypad is Zigbee; messages to a button without an LED are wasted. Hence an easy off |
| SG7 | A link message goes to the consumers bound to that link, and a receiver tells buttons apart by binding id; a driver acts on the push, without waiting for click or release. | KP `62/_1` (commands, `DO_PUSH`); API `25_proxy/_6-SendToProxy.md`, `32_serial_network_device/_3-GetBoundConsumerDevices.md` (BLS section 3) | Yes: the chase touches only its own links; a press ends or changes the chase at once |
| SG8 | The keypad proxy's own commands (`KEYPAD_BUTTON_COLOR`, `KEYPAD_BUTTON_INFO`, `KEYPAD_ALL_BUTTON_COLOR`) reach any button of a keypad and can change its stored settings. | KP `60_keypad_proxy_commands/_5-KEYPADBUTTONCOLOR.md`, `_6-KEYPADBUTTONINFO.md`, `_3-KEYPADALLBUTTONCOLOR.md` | Yes, as a limit: the chase never uses them (BL-D1) |
| SG9 | Colours are 6-digit hex strings, an on colour and an off colour per button. | KP `62/_1`; LV2 `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/_2-BUTTONINFO.md` | Yes: the colour format; the chase colour is one such string |
| SG10 | Keypad brightness, ambient-light dimming and backlight are the keypad's and the dealer's, not the driver's; the Hue checklist marks them "the keypad's own driver handles these". The SDK has no message that sets or reads an LED brightness. | HUE L54; BLS section 8 (a full-text search of KP, LV2, API, FUND and XML finds no ambient or brightness message: SILENT); BLE LF18, LF19 | Yes: send full colours and lit or dark states, never a dimmed colour (BL-D5, BL63) |
| SG11 | A keypad button's LED has a behaviour the dealer chooses (follow the connection, follow the load, push and release, programmed). The SDK carries the behaviour as a number and names none of them; it says nothing about which source wins. | KP `60_keypad_proxy_commands/_6-KEYPADBUTTONINFO.md`, `61_keypad_protocol_notifications/_8-LED_BEHAVIOR_NAME.md` (BLS section 2: SILENT on precedence) | Yes: a programmed LED command still acts on a Follow Connection button (K14, VERIFIED on the house); the chase can overwrite it, and it can overwrite the chase. ASSUMED: last message wins |
| SG12 | A keypad proxy capability can clear colours set programmatically (OS 3.4.2 and later, only for protocols that declare it). | KP `61.1_keypad_capabilities/_1-clearledcurrentcolorsupport.md` | No: it belongs to a keypad's own protocol driver, not to a bound driver |
| SG13 | The light_v2 "extras" page is about driver-defined controls on a Navigator, not LEDs. | FUND `27_proxy_specific_info/_51-LIGHTV2EXTRAS.md` | No: nothing on LEDs. A Navigator extras screen could host a switch for the animation; not needed (a property row is enough) |
| SG14 | Timers: `C4:SetTimer` takes milliseconds above 0 and is skipped, not queued, when Director is busy; the SDK documents no minimum interval. | API `34_timer/_1-SetTimer.md` | Yes: late ticks must not burst (BL-D13) |

The Control4 dealer and homeowner pages the Hue project cites (HUE section 2)
were not read in this session: the web is out of scope for a local-sources
note, so SG2 and SG10 rest on the Hue checklist's reading of them (dated
2026-11-08). The SDK files above were read in full.

## 2. Item by item: how the chase can meet it, and where it must bend

| Item | How the chase meets it | Where it departs |
| --- | --- | --- |
| SG1, SG2: the LED shows the device's state | At rest every link shows its real state, exactly as `links:shown` sends it today (selected speed lit, the rest dark, Off and the others untouched). The chase starts and stops from the same shown state (`mode`, `listener.shown`) from every source: keypad, app, remote, wall control, programming, the Modern Forms app (as BL-D9). `REQUEST_BUTTON_COLORS` and a new binding during a chase are answered with what the pixel shows at that moment (BL-D15, BL40). | **Bent, by design:** for the length of each chase the selected speed's LED is dark and the others flash, while the fan runs at that speed. The duty is the chase length over the period: 1.6 s in 6.6 s (24 %) at the slowest chase with a 5 s rest, 0.48 s in 5.5 s (9 %) at the fastest, 5 to 14 % with a 10 s rest and 1.6 to 5 % with 30 s (section 5). The owner asked for this ("lit, but not while the animation is playing"). A softer variant, left to the owner: the selected pixel stays lit and only the others chase. |
| SG1: the other buttons | Only speed links 301 to 306 with a bound button, and only with `Speed LED Colors` = `Per speed`, where the driver owns the resting colours (BL-D2, BL-D3). Off, Toggle, Cycle, Breeze and the light's links never animate. | None; inherited. |
| SG3: periodic updates and Zigbee | A chase is a burst of at most 2 messages a step with a long rest (5 s or more), not a steady stream. Average under 1 a second at a 10 s rest for four pixels (section 5). Nothing is sent while resting. A pixel is sent only when what it shows changes (BL-D13, BL-D14). | **Partly bent:** the SDK's list names 500 ms and 1000 ms periodic updates as the wrong pattern for level notifies. The chase repeats every 5.5 to 32 s, all day. What the SDK warns of (proxies, Director, Navigators, Advanced Lighting Scenes, programming) a link LED message does not touch (the message goes to the keypad link, ASSUMED); the Zigbee cost is real and not measured over hours. Mitigation: the rest floor and the budget of section 7. |
| SG4: emulation versus a transition message | None exists on the link. | **Forced by the protocol:** no effect or transition message; every step is one message. |
| SG5: back-to-back changes | A new shown state (a press, the app) ends the chase at once and settles; a late timer tick evaluates the chase where it should be now and never replays missed steps (BL-D13, BL-D10). | None. |
| SG6: unknown hardware | Off by default (a list of `Off` and `Chase`, default `Off`, as BL-D18); a keypad whose bound button has no LED simply shows nothing; a dealer turns it off with one property. | The messages still go out (the driver cannot ask hardware what it has). On the house this costs nothing: the fan buttons have LEDs. |
| SG7, SG8: scope | Link messages only (`BUTTON_COLORS`, `MATCH_LED_STATE`) on the driver's own links; never `SendToDevice`, never a keypad setting, never the Ambient Light Level input (BL-D1, BL70). A press acts at once; the chase timer is separate and a press cancels it. | None. |
| SG9, SG10: colour and brightness | The chase colour is the selected speed's own colour: a full 6-digit value the owner picked, sent as the on colour, the off colour left as `Speed LED Off Color`. A dark pixel is dark (off colour at the keypad's inactive brightness); a lit one is lit (on colour at the active brightness). No brightness is computed. Because the chase colour is the colour the resting LED already shows, the chase is exactly as visible as the resting LED at every hour, and Breeze's night scaling (BL-D28) does not apply. | None. A caution from Breeze's own probe: pure blue `0000ff` vanishes under the keypad's night dimming (BL-D20), and the driver's per-speed default is `0,0,255`; the resting LED has the same weakness. |
| SG11: programmed LED commands | The chase holds its pixels while it plays (BL-D15) and puts every pixel back at its end. | **Unavoidable:** programming that paints those buttons during a chase can corrupt a frame, and a chase can overwrite a programmed LED until the next state change. The manual says the animation needs the fan buttons' LED behaviour on Follow Connection. |

**What the Breeze contract already does, which this one should inherit**
(each is a decision of [`breeze-leds-design.md`](breeze-leds-design.md)):

- BL-D1: only link messages on the driver's own links.
- BL-D2, BL-D3: pixels are the bound speed links, under `Per speed` only; Off, Toggle, Cycle, Breeze never animate.
- BL-D4, BL-D30: order by speed number, `Breeze LED Bottom` says which end is the bottom (a chase may reuse the property or get its own), direction from the fan's airflow with an unknown direction treated as reverse.
- BL-D5: colours only, full values, lit state only; no baked brightness.
- BL-D9: start and stop follow the shown state, from every source; a refused request restores.
- BL-D10, BL-D11: the newest state wins; any stop other than a normal end settles at once (offline, property off, `Speed LED Colors` left `Per speed`, no pixel).
- BL-D13: one one-shot timer at a time; a late tick never bursts.
- BL-D14, BL-D23: the cheapest message for each change; a colour for a dark pixel preloaded silently.
- BL-D15, BL-D16: held pixels, `REQUEST_BUTTON_COLORS` answered with what shows, bindings mid-animation.
- BL-D17: restart and update: no state persisted; the first contact puts every link back.
- BL-D18: **off by default**, no capability change, so no controller reboot and an update animates nobody's keypad.
- BL-D24: a sliding message budget with must-send and droppable messages.
- L42-style text in Last Action when the property needs `Per speed` and does not have it.

**New for the chase** (not covered by Breeze):

- The chase runs for hours, so a lost message must heal by itself: the end-of-chase relight of the selected pixel is a must-send, and the next chase re-sends it anyway, so a wrong LED lasts at most one period. SDK is SILENT on delivery confirmation (section 6).
- Ending a chase with `links:settle` on every pixel costs 2 messages a pixel (colours then state) every period (8 for four pixels). The cheaper return path is `links:light(link, true)` (1 message) on the selected pixel, plus a colour preload only for a pixel whose resting colour differs; the links' `led` and `led_speed` tables must then be set back to the truth so later `shown` calls do not re-send (a new, small links function; `paint` and `light` clear them today).

## 3. The exact messages and their cost

From `src/modernforms_fan/fan/links.lua` and `breezeleds.lua` (read in full for these functions):

| Call | Messages sent over the link | What the keypad does (measured on the house, #137, 2026-11-09, BLD section 1a) |
| --- | --- | --- |
| `links:light(link, lit)` | 1: `MATCH_LED_STATE` `{STATE = lit}` as a COMMAND (`send_led`) | Lights or darkens the button in the colours it already holds |
| `links:paint(link, colour, false, true)` (preload) | 1: `BUTTON_COLORS` `{ON_COLOR, OFF_COLOR = Speed LED Off Color}` as a NOTIFY, **no** `CURRENT_COLOR` | A dark button stays dark; the colour is stored; a following `MATCH_LED_STATE` true shows it |
| `links:paint(link, colour, false, false)` | 1: `BUTTON_COLORS` with `CURRENT_COLOR = colour` (`send_colors`) | Repaints a **lit** button at once (`RECOLOUR_NEEDS_STATE` is false); on a dark button it would not light it |
| `links:paint(link, colour, true, false)` | 2: `BUTTON_COLORS` with `CURRENT_COLOR`, then `MATCH_LED_STATE` true | Used when a pixel's state is unknown |
| `links:settle(link)` (`Per speed`) | 2: `BUTTON_COLORS` (the colour of the speed it is lit at, or its own speed's colour while dark), then `MATCH_LED_STATE`; 1 when no colour is set for the speed | Gives the pixel its real state back |
| `links:push_led(link, shown, force)` | 1 (state) or 2 (colours then state, when a colour applies) | The 1.3 path every `shown` change takes |

Each `send_*` is one `C4:SendToProxy` call (API `25_proxy/_6-SendToProxy.md`),
one Director message. What it becomes on the radio is **SILENT**; the
working assumption, carried since BLS section 1, is one Zigbee packet to each
bound Zigbee keypad, in order (ASSUMED).

**The budget code** (`breezeleds.lua`): `stamp(count)` prunes the messages
older than `WINDOW_MS` (1000) and records `count` messages at the engine's
time; `room(count)` is true when the window, a reserve for what the gust must
still send, and `count` fit within `BUDGET_PER_S` (30). `apply(link, lit,
colour, must, spare)` picks the cheapest message: dark is 1 (`light(false)`);
lit and showing another colour is 1 (`BUTTON_COLORS` with `CURRENT_COLOR`);
dark and the colour already loaded is 1 (`light(true)`); dark and the colour
not loaded is 2 (preload, then light); state unknown is 2. A `must` message
is never dropped; the others are dropped when the window has no room. The
engine ticks every `TICK_MS` (50) while a gust runs.

**What was measured on the house keypad** (BLD section 1a, the probes of
issue #137):

- One button flickers distinctly at **20 changes a second**.
- Four buttons at **10 changes a second each** (about **40 messages a
  second**) stayed even and in step.
- The design budget is **30 messages a second**, "headroom for the rest of the
  Zigbee mesh" (BL-D24).
- Pure blue vanished at the keypad's night dimming.

The duration of those probes is not recorded in the repository (not found). The
planning figures from the field research, from the Zigbee side and not
measured on this keypad: peaks of about 10 LED messages a second, 3 to 5 a
second sustained, never a backlog (BLF Q5, assembled from chip-vendor latency
tests and Signify's published guidance for lights; the keypad's own limit is
not public). The dealer reports it cites of lagging LEDs (a few seconds on
a busy mesh, minutes on an unhealthy one) are forum snippets, the weakest
evidence there (BLF Q1, Q3, S15, S22).

Nothing was measured over hours. BLE BL38 raised "hours of Breeze" as a question and
the shipped Breeze plays continuously, but no hardware note in the
repository records a night of it.

## 4. The cheapest sequence for a chase

**Setting.** N pixels in travel order p1 to pN; the selected pixel `s` (the
link of the speed the fan runs at) is one of them. Pixels are dark except `s`,
which is lit. A step is `st` ms; the chase length is D = N x st; a rest is R.

**Same colour on every pixel** (all speeds purple; every pixel already holds
the chase colour as its on colour, so no preload is needed, not even once):

| Time | Messages | Count |
| --- | --- | --- |
| t0 | `light(s, false)`; `light(p1, true)` | 2 |
| t1 .. t(N-1) | `light(p(k+1), true)`; `light(pk, false)` | 2 each |
| tN | `light(pN, false)`; `light(s, true)` | 2 |
| Total | | **2N + 2** |

If the selected pixel is p1 (first in travel order) it is already lit: skip
its dark-first and its first lighting; if it is pN the chase can end on it,
lit, and skip the last dark and the relight. Either saves 2 messages and
changes the look (the selected pixel does not blink off at that end), so the
design figure is 2N + 2 and the saving is optional.

Every pixel is lit once and darkened once whatever the shape of the chase:
a single dot, a two-pixel comet or a growing fill all cost 2N + 2, because the
link has no way to change several buttons in one message (whether one link
message reaches every button on it is ASSUMED, BLS section 3(b), and gives no
help here: the pixels need different states at the same time).

**Different colours per speed.** The chase colour is the selected speed's
colour. `s` already holds it (its own speed's colour, whether lit or dark, as
`settle` sends it). The other N - 1 pixels hold their own speed's colour and
need the chase colour:

| Scheme | Extra messages | When | Cost per chase in steady state |
| --- | --- | --- | --- |
| **Keep loaded between chases** (recommended): preload each other pixel once with the chase colour when the chase starts or the speed changes (`paint(link, colour, false, true)`, 1 each); put every pixel's own colour back when the chase ends for good (1 each, `paint` preload for the dark ones) | N - 1 at start or at each speed change, N - 1 at the end | speed change, stop | 2N + 2 (10 or 14) |
| Preload before and put back after **every** chase | 2(N - 1) | every chase | 4N (16 or 24) |

The first scheme leaves the pixels, while dark between chases, holding a colour
that is not their own speed's. Nothing shows (they are dark), but a programmed
LED command (SG11) or a `REQUEST_BUTTON_COLORS` answered from the driver's
tables could show the wrong colour for the length of the run. Breeze has the
same exposure for the length of Breeze (BL-D15). With all speeds the same
colour there is no exposure at all, which is the owner's case. When the speed
changes while a chase runs, the new selected pixel is settled to its colour
and the other N - 1 are preloaded with the new chase colour (N - 1 messages
plus the settle's 2).

Dark first is `light(s, false)`, not a recolour: a recolour of a lit pixel
shows at once (BL-D23), and the selected pixel is lit at rest.

## 5. The arithmetic

Per chase: M = 2N + 2 (same colour, or different colours kept loaded).
D = N x st; period T = D + R; chases an hour = 3600 / T; messages an hour =
chases x M; average a second = M / T; a day is 24 hours, so a fan that runs
10 hours a day uses 10/24 of it.

Steps follow the owner's pairing of speed to step time: 400, 300, 200, 120 ms
at speeds 2, 3, 4, 5. Each cell: chases an hour, messages an hour, average
messages a second, messages in 24 hours.

**Four pixels (the house), M = 10**

| Speed | Step | Chase | Rest 5 s | Rest 10 s | Rest 30 s |
| --- | --- | --- | --- | --- | --- |
| 2 | 400 ms | 1.60 s | 545; 5,455; 1.52; 131 k | 310; 3,103; 0.86; 74 k | 114; 1,139; 0.32; 27 k |
| 3 | 300 ms | 1.20 s | 581; 5,806; 1.61; 139 k | 321; 3,214; 0.89; 77 k | 115; 1,154; 0.32; 28 k |
| 4 | 200 ms | 0.80 s | 621; 6,207; 1.72; 149 k | 333; 3,333; 0.93; 80 k | 117; 1,169; 0.32; 28 k |
| 5 | 120 ms | 0.48 s | 657; 6,569; 1.82; 158 k | 344; 3,435; 0.95; 82 k | 118; 1,181; 0.33; 28 k |

**Six pixels, M = 14**

| Speed | Step | Chase | Rest 5 s | Rest 10 s | Rest 30 s |
| --- | --- | --- | --- | --- | --- |
| 2 | 400 ms | 2.40 s | 486; 6,811; 1.89; 163 k | 290; 4,065; 1.13; 98 k | 111; 1,556; 0.43; 37 k |
| 3 | 300 ms | 1.80 s | 529; 7,412; 2.06; 178 k | 305; 4,271; 1.19; 103 k | 113; 1,585; 0.44; 38 k |
| 4 | 200 ms | 1.20 s | 581; 8,129; 2.26; 195 k | 321; 4,500; 1.25; 108 k | 115; 1,615; 0.45; 39 k |
| 5 | 120 ms | 0.72 s | 629; 8,811; 2.45; 211 k | 336; 4,701; 1.31; 113 k | 117; 1,641; 0.46; 39 k |

**What the speed does to the load.** The step changes only how short the
burst is; the rest sets the load, so the slowest and fastest chase cost about
the same an hour (the fast one a little more because its period is shorter).

**Peak, against the budget.** Every step boundary sends 2 messages, and a
chase has N + 1 boundaries, so no window holds more than min(2(N + 1),
2 x ceil(1000 / st)) messages: for four pixels 10 at any step, for six pixels
14 at any step of 166 ms or less (7 boundaries fit in a second), against a budget of 30.
The fastest burst rate is 2 / 0.12 = 16.7 messages a second at 120 ms, against
the 40 a second measured clean for four buttons. A single button changes at
most once per step, 8.3 changes a second at 120 ms, against the 20 a second at
which one button flickered (so a step floor of 100 ms leaves a button at
10 changes a second).

**Different colours, per chase** (the second scheme, for comparison only): 16
messages a chase for four pixels, so 10,500 an hour (2.9 a second) at speed 5
with a 5 s rest, 5,500 (1.5 a second) with 10 s, 1,900 (0.5 a second) with
30 s; 24 messages for six pixels, 15,100 an hour (4.2 a second) at the same
speed with 5 s, 8,100 (2.2) with 10 s, 2,800 (0.8) with 30 s. The 5 s rest for
six pixels there is inside the field research's 3 to 5 a second sustained
planning range, at its upper half, which is a reason not to preload and
restore on every chase.

**Dark time of the selected pixel** (the departure from SG1), chase length
over the period: four pixels, 24 % (speed 2, rest 5 s), 14 % (10 s), 5 % (30 s);
speed 5: 9 %, 5 %, 1.6 %. Six pixels: 32 %, 19 %, 7 % at speed 2 and 13 %,
7 %, 2.3 % at speed 5.

## 6. What the SDK says about rates, Zigbee keypads and repeated link messages

- **Sending rates for keypad LEDs: SILENT.** No SDK file gives a rate, a
  limit or a queue length for `BUTTON_COLORS` or `MATCH_LED_STATE`. The two
  numbers near it are for other things: periodic light-level notifies (20,
  500, 1000 ms as examples to stop, FUND `_50-LIGHTV2BESTPRACTICE.md`, LV2
  `_12-LIGHTLEVEL.md`) and Navigator volume commands (every 750 ms by default,
  a driver may lower it but under 200 ms is not recommended, PP
  `116_proxy_and_protocol_best_practices/_4-OS3NAVIGATORUIANDVOLUMECONTROL.md`,
  as read by BLS section 4).
- **Zigbee keypads: SILENT** except as a cost named in the best practice
  ("excessive zigbee traffic and often incorrect keypad button LED status").
  The keypad proxy overview says the proxy arrived in OS 2.5.0 with the Gen3
  lighting drivers (KP `60_keypad_proxy_commands/_1-OVERVIEW.md`); it does
  not say which keypads are Zigbee or how a link message reaches one.
- **Repeated `BUTTON_COLORS` or `MATCH_LED_STATE`: SILENT.** Nothing says
  whether the proxy or the keypad ignores a message that changes nothing,
  coalesces a burst, keeps order, confirms delivery or retries. The driver
  therefore sends only real changes (BL-D13) and must treat every send as
  fire-and-forget.
- **What the SDK does say:** `REQUEST_BUTTON_COLORS` is answered with both
  messages, colours then state (KP `62/_1`), which makes the pair the normal
  unit; `SendToProxy` takes any binding the driver owns (API `25_proxy/_6-SendToProxy.md`);
  timers are skipped, not queued, when Director is busy (API `34_timer/_1-SetTimer.md`).
- **Whether a link LED change fires Composer programming events: not found.**
  The best practice says excessive level updates fire programming too often;
  no SDK page says whether keypad LED state changes are events.
- **OS differences:** `SendToProxy`, `BUTTON_COLORS`, `MATCH_LED_STATE` (OS 3.0
  and later), `SetTimer` (2.7.0) and `GetTime` in milliseconds (3.2.3) all lie
  inside the driver's 3.3.0 minimum; nothing here is OS 4 only (BLS section 7).
  Behaviour on an OS 4.x controller is untested (parked, BLE).

## 7. What other drivers do

- **The SDK's helper libraries** (`~/c4-tools/drivers-common-public/`): a search for
  `BUTTON_COLORS`, `MATCH_LED_STATE`, `SET_BUTTON_COLOR` and
  `KEYPAD_BUTTON_COLOR`, and for `blink`, `flash` and `animat`, finds no
  keypad-LED code; the only `flash` hit is the reflash-lock callbacks of
  `global/handlers.lua`, unrelated. Nothing to cite or learn from there.
- **Third-party drivers and dealer practice** are in BLF Q3 and Q4 (read
  from vendor pages and forum snippets; reliability marked there). In short:
  nobody has published a keypad-LED chase or effect; dealers blink an LED
  with a delay and a second colour change every 100 ms to 2 s; two vendors
  tell users to slow down and wait when changing colours, and a third
  advertises "ordered, staggered dispatch" for LED updates (BLF Q4, S24,
  S25, S28, snippet-level evidence for the last). Zigbee switches that do
  have LED effects run them in their own firmware (BLF Q3, S34). None says
  how often a status LED may change for hours. The only vendor figure close to
  a budget is Signify's own, for lights, about 10 commands a second (BLF Q5, S33).

## 8. Checklist, recommendation

### 8.1 Checklist for the contract's "Control4 guidelines" section

| Guideline | Source | How the chase meets it, or the departure and its reason |
| --- | --- | --- |
| SG1/SG2: the LED follows the bound device, from every source | KP `62/_1`; HUE L49, L53 | Met at rest (real state, as 1.3); start and stop from the shown state. **Departs during each chase** (selected LED dark, others flash): the owner's design; mitigated by short chases, a rest floor, off by default |
| SG1: only the buttons the driver owns | KP `62/_1`; BL-D2, BL-D3 | Met: bound speed links under `Per speed` only; nothing else is painted |
| SG3: no periodic updates that flood Zigbee | FUND `_50-LIGHTV2BESTPRACTICE.md`; LV2 `_12-LIGHTLEVEL.md` | **Departs in kind** (a chase every 5 to 60 s, all day) and met in rate: at most 2 messages a step, rest 5 s or more, under 2.5 messages a second average at the worst case studied, 30 a second budget as the ceiling; the Zigbee load over hours is unmeasured |
| SG4: transition messages instead of emulation | FUND `_50-LIGHTV2BESTPRACTICE.md` | **Departs, forced:** the link has no effect or transition message |
| SG5: back-to-back changes coalesce | FUND `_50-LIGHTV2BESTPRACTICE.md`; HUE L13 | Met: newest state wins, late ticks never burst, no queue (BL-D10, BL-D13) |
| SG6: hardware may lack LEDs | KP `62/_1` | Met as far as possible: off by default, one property; cost wasted on LED-less buttons |
| SG7: link messages to bound consumers only; act on the push | KP `62/_1`; API `25_proxy/_6-SendToProxy.md` | Met: own links only; a press cancels the chase and acts at once |
| SG8: keypad proxy commands change settings | KP `60_keypad_proxy_commands` | Met by never using them (BL-D1) |
| SG9: 6-hex colours, on and off | KP `62/_1` | Met: the chase colour is the speed's colour; the off colour is `Speed LED Off Color` |
| SG10: keypad dimming is the keypad's | HUE L54; BLS section 8 | Met: full colours, lit or dark, no brightness baked in; the chase colour equals the resting LED's, so no night scaling is needed. The default per-speed colour `0,0,255` vanishes at night, as the resting LED does |
| SG11: LED behaviour and programmed LED commands | KP `60/_6`; BLS section 2 | **Departs, unavoidable:** programming on the fan buttons can clash with a chase; the manual says Follow Connection is required |
| Off by default; a stock install behaves like a stock keypad | BL-D18, BL44 | Met: `Off` default, a property row only, no capability, no reboot |
| Truthful when the animation stops for any reason | BL-D8, BL-D11 | Met: offline, property off, speed 1 or 6, Off, Breeze, `Speed LED Colors` left `Per speed`, last pixel unbound: every pixel put back at once, no chase |
| A lost message must not leave a wrong LED for hours | SG3's "incorrect keypad button LED status" | The chase's end relights the selected pixel as a must-send; the next chase repeats it; the worst case is one period. No delivery confirmation exists (SILENT) |

### 8.2 Recommended message budget

- **Reuse BL-D24's window as it is:** `BUDGET_PER_S` 30 over `WINDOW_MS` 1000. The chase and Breeze never run together (fan mode and Breeze mode exclude each other), so the constants are shared safely.
- **Per chase:** at most 2N + 2 messages, plus N - 1 preloads at a start or a speed change when colours differ, plus N - 1 puts-back when the chase stops for good. No per-chase preload and restore.
- **Classify every chase message as must-send** (dark-first, every darkening, the relight): never dropped, because a dropped dark or relight is a wrong LED. If the window lacks room, **stretch the step** (delay the next boundary), do not drop. With the numbers below this never fires on its own (peak 10 to 14 against 30); it matters only after a press or a settle lands in the same window (a settle is 2 a pixel, 8 for four pixels).
- **Step floor 100 ms**, so one button never changes faster than 10 times a second and a burst never exceeds 20 messages a second; the peak per window stays at 10 (four pixels) or 14 (six).
- **Average ceiling about 2.5 messages a second**, enforced by a **rest floor of 5 s**. The worst case studied (six pixels, speed 5, 5 s) is 2.45 a second, inside the 3 to 5 a second sustained planning figure, with the margin the mesh needs.
- **Do not use `settle` at the end of every chase**; use `light` on the selected pixel (1 message) and a small links function that restores the `led` tables.

### 8.3 Recommended default timings

| Property | Default | Range | Why |
| --- | --- | --- | --- |
| Animation | `Off` | `Off`, `Chase` | BL-D18: an update animates nobody's keypad |
| Step at speed 2, 3, 4, 5 | 400, 300, 200, 120 ms | 100 to 600 ms, derived from speed, not four properties | The owner's pairing: slower fan, slower chase; a chase length of 0.5 to 1.6 s at four pixels |
| Rest between chases | **10 s** | 5 to 60 s, one value for all speeds | "Always the same" (owner). At 10 s: four pixels 3,100 to 3,400 messages an hour (0.86 to 0.95 a second), 74 to 82 k a day; six pixels 4,100 to 4,700 an hour (1.1 to 1.3 a second), 98 to 113 k a day. 5 s is the floor; 30 s is the calm choice (27 to 28 k a day for four pixels) |
| Direction | The fan's airflow; unknown counts as reverse (BL-D30) | | Owner: "the direction the fan is blowing" |
| Colour | The selected speed's colour (`Speed N LED Color`) | | Owner; the same as the resting LED, so no new palette |

The arithmetic is section 5; a rest of 10 s is the smallest at which the
average stays at or under 1 message a second for four pixels at every speed
(0.95 a second at speed 5).

## 9. What could not be verified from local sources

- **Control4's dealer and homeowner pages** (keypad LED behaviour, dimmer
  settings, ambient-light profiles): not re-read in this session; SG2 and SG10
  rest on the Hue project's checklist of 2026-11-08.
- **Hours of repeated LED changes:** no measurement in this repository covers
  more than a short probe, and the probe's length is not recorded. Effects on
  the keypad (heat, LED wear, flash writes), on the Zigbee mesh and on other
  traffic over 10 to 24 hours a day are unknown. A hardware check is
  possible but is a long-horizon test (the project parks those).
- **What a link message becomes on the radio:** one packet a message, per
  keypad (assumed); whether a keypad merges, drops or delays them: not
  documented. Message-to-LED latency: not measured (BLF H6).
- **Whether the proxy or keypad ignores a repeated identical message,
  keeps order, confirms or retries:** SILENT.
- **Whether one link message reaches every button on a link and every keypad:**
  ASSUMED (BLS 3(b), BLE LF14); the house has one keypad.
- **Whether `BUTTON_COLORS` over a link changes the colours the dealer set in
  Composer** (BLS H7): no recorded answer found. It matters for the
  different-colours case, which leaves a dark pixel holding the chase colour.
- **Which source wins among link, programmed LED commands and Echo LED on
  press:** SILENT; last message wins is ASSUMED.
- **Whether a link LED change raises any Composer event:** not found.
- **Whether a chase causes visible pumping or brightening through the keypad's
  ambient sensor** (a lit bottom pixel next to the sensor bar): inferred, not
  measured (BLF H5); a single moving dot is lighter than Breeze's white head.
- **OS 4.x behaviour and several keypads on one link:** parked, untested.
- **Third-party practice for animated LEDs:** only forum snippets and vendor
  pages (BLF Q3, Q4); nothing from Control4 and no code in
  `~/c4-tools/drivers-common-public/`.
