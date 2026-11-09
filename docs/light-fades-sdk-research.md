# Simulated light fades: what Control4 expects

Research for [issue #141](https://github.com/corytron/c4-modernforms-driver/issues/141),
written 2026-11-09 by a read-only research agent. The fan's light has no
fade of its own: its local API has no transition time, and its level runs
from 1 to 100 ([`modernforms-api-research.md`](modernforms-api-research.md#9-fan-and-light-behaviour)).
The owner wants the driver to fake a fade by stepping the fan through many
fine levels, so that a change of level looks like a Control4 dimmer's fade.
Today only a hold or a scene ramp steps (one level every 500 ms,
`RAMP_STEP_MS` in `src/modernforms_fan/fan/light.lua`); every other
change is sent at once
([`v1-design.md` §4.7](v1-design.md#47-the-light)).

This note covers the Control4 side: every way Control4 asks the light to
change, which of them carry a rate, what the proxy expects to hear during
and after a fade, what `click_rates` costs, and what Control4's own dimmers
do. A companion note, `edge-cases-light-fades.md`, written at the same time
by another agent, covers the fan's side (how fast it takes requests, the
step size, polls, the remote and app mid-fade, offline) and the lifecycle
corner cases. Nothing here was sent to any device.

The owner's rule (2026-11-08, Hue #422) applies throughout: lighting
behaves like Control4's own dimmers and keypads and follows Control4's
published guidance, and a departure is allowed only where the hardware
cannot do what Control4 expects, written down with its reason.

## Contents

- [Sources and markers](#sources-and-markers)
- [Summary](#summary)
- [1. Every way the light is asked to change](#1-every-way-the-light-is-asked-to-change)
- [2. Click rates and the other rate capabilities](#2-click-rates-and-the-other-rate-capabilities)
- [3. What Control4's own dimmers do](#3-what-control4s-own-dimmers-do)
- [4. What Navigators and programming see during a fade](#4-what-navigators-and-programming-see-during-a-fade)
- [5. Recommendation](#5-recommendation)
- [6. Questions for the owner](#6-questions-for-the-owner)
- [7. Checks on the house](#7-checks-on-the-house)
- [8. Where the documents disagree or say nothing](#8-where-the-documents-disagree-or-say-nothing)

## Sources and markers

The Snap One SDK reference is cited by path under `~/c4-tools/reference/`.
It is summarised in this note, never copied.

| Short name | Path or URL |
| --- | --- |
| BP | `docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md` (cited with its section title) |
| EX | `docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_51-LIGHTV2EXTRAS.md` |
| LV2 | `docs-driverworks-proxyprotocol-lightv2/source/includes/`, with the sub-folders **caps** `5_light_v2_capabilities/`, **cmds** `10_light_v2_commands/`, **notif** `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/`, **vars** `30_Light_v2_variables/`, **events** `25_light_v2_events/`, **cond** `20_light_V2_conditionals.5_light_V2_conditionals/`, **als** `45_Light_V2_advanced_lighting_scene/`, **new** `3_whats_new/` |
| KPD | `docs-driverworks-proxyprotocol-keypad/source/includes/` |
| UIB | `docs-driverworks-proxyprotocol-uibutton/source/includes/` |
| API | `docs-driverworks-api/source/includes/` |
| FUND | `docs-driverworks-fundamentals/source/includes/` |
| C4-USER-SW | Control4 user guide, switches and keypads: <https://docs.control4.com/help/c4/user/userguide/content/topics/lighting/switches-keypads.htm> |
| C4-DIM | Composer help, device settings for dimmers: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerhe_userguide/device_settings_for_dimmers.htm> |
| C4-DIMPROPS | Composer Pro help, dimmable light properties: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/set_dimmable_light_properties.htm> |
| C4-LIGHTING | Composer Pro help, configuring lighting: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/configuring_lighting.htm> |
| C4-ALS | Composer Pro help, the Advanced Lighting agent: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/example_use_the_advanced_lighting.htm> |
| HUE | The author's Hue driver, <https://github.com/corytron/c4-hue-driver>: its lighting checklist `docs/c4-lighting-guidelines.md` (rows L1 to L89) and the tap-stop feature of Hue #421 (`docs/tap-stop-design.md`, `docs/tap-stop-research-c4.md`, `docs/tap-stop-research-hue.md`) |

The Control4 help pages were read on 2026-11-09. The c4forums.com threads
that searches turn up refuse automated reads (the Hue research found the
same on 2026-11-08), so nothing here rests on them.

House facts come from this project's probe ([`v1-design.md`
§11.1](v1-design.md#111-what-the-probe-has-shown-so-far-17): K4, K6, K7,
K8; K13 and K15 in issue #17) and from the Hue driver's records on the same
controller (OS 3.4.2).

**Markers.**

- **VERIFIED-doc**: an SDK file or Control4 help page says so (cited).
- **VERIFIED-house**: seen on the house controller (the record is cited).
- **INFERRED**: follows from the documents, but no document says it in so
  many words; the reasoning is given.
- **ASSUMED**: neither the documents nor the house show it yet.
- **FOLKLORE**: dealer or forum talk, not checked.
- **SILENT**: no document says anything.

## Summary

1. **A fade is reported once, never step by step.** The proxy hears
   `LIGHT_BRIGHTNESS_CHANGING` once at the start (where the light is, where
   it is going, and how many milliseconds it will take), then
   `LIGHT_BRIGHTNESS_CHANGED` once with where it ended. The steps go to the
   fan only. Snap One names step-by-step level reports as the cause of slow
   Navigators, wrong scene tracking, wrong keypad LEDs and programming
   that fires too often (VERIFIED-doc: BP "Brightness Target API"; LV2 notif
   `_12-LIGHTLEVEL.md`, `_10.3-LIGHTBRIGHTNESSCHANGING.md`).
2. **Navigators animate the fade themselves.** A tile's slider moves from
   the CHANGING notify's current level to its target over its rate, so one
   notify gives a smooth slider whatever the fan does (VERIFIED-doc: BP
   "Brightness Target API"). Today the driver sends that notify with a rate
   of 0, so every tile jumps.
3. **Two kinds of rate reach the driver.** Click and hold rates are speeds:
   the time for the whole range, off to full or full to off (VERIFIED-doc:
   LV2 notif `_4`, `_5`, `_9`, `_10`). `RATE` in `SET_BRIGHTNESS_TARGET`,
   `TIME` in `RAMP_TO_LEVEL` and the Default Brightness Rate are durations:
   the time this one change should take (VERIFIED-doc: LV2 cmds
   `_1.5-SETBRIGHTNESSTARGET.md`, `_20.2-UPDATEBRIGHTNESSRATEDEFAULT.md`; API
   `32_serial_network_device/_19-SendToDevice.md`).
4. **Keypad taps carry no rate.** A tap's speed is the light's own Click
   Rate, and the Click Rate rows exist in Composer only with `click_rates`
   True (VERIFIED-doc: LV2 caps `_11-CLICKRATES.md`). This driver declares
   it False, and the probe's light showed no Click Rates section
   (VERIFIED-house: K4).
5. **`click_rates` is static**, so turning it on costs the owner one
   controller reboot from System Manager (VERIFIED-doc: LV2 caps
   `_11-CLICKRATES.md`, "not dynamic"; VERIFIED-house: HUE, a static
   capability change loads only after a reboot, never after "Restart
   Director?"). Everything else a fade needs is Lua, or dynamic
   capabilities.
6. **Commands with no rate have a documented default.** The proxy keeps a
   Default Brightness Rate for generic on and off, Navigators and
   customer-made scenes, and tells the driver its value with
   `UPDATE_BRIGHTNESS_RATE_DEFAULT` (VERIFIED-doc: LV2 cmds `_20.2`,
   `_21.3`). The light's settings page already shows that row
   (VERIFIED-house: K4). The driver handles neither command today.
7. **Control4's own dimmer:** a tap ramps up to full or down to off, and a
   tap while it ramps stops it there (VERIFIED-doc: C4-USER-SW). No
   Control4 page publishes the default click or hold rates (VERIFIED-doc,
   by their absence from C4-DIM and C4-DIMPROPS).
8. **The Hue driver's tap-stop design carries over almost whole on the
   Control4 side:** the double-tap window, the stop on the press, click
   rates as whole-range times at 3000 ms by default, any timed ramp
   stoppable, CHANGING at the start and CHANGED at the end. What does not
   carry over is Hue's fade engine, its stop primitive and its reporting
   quirks: here the driver is the fade engine, a stop is simply the last
   step, and the fan's own answer gives the end level (section 3.5).
9. **A stop is a documented command.** `SET_BRIGHTNESS_STOP` stops a ramp
   in progress; Advanced Lighting scenes, the Daylight Agent and the
   proxy's Brightness Stop link use it (VERIFIED-doc: LV2 cmds
   `_21.5-SET_BRIGHTNESS_STOP.md`, caps `_29-SUPPORTSBRIGHTNESSSTOP.md`).
   Once every timed change is a driver-run fade, that stop really stops
   the light.
10. **Not documented:** what a dimmer does with a new target in the middle
    of a fade (INFERRED: it goes from where it is to the new target), when
    the proxy's Light On and Light Off events fire during a fade, and when a
    Control4 dimmer's keypad LED changes during a slow fade. Section 7 lists
    the one-minute checks that settle them.

## 1. Every way the light is asked to change

### 1.1 The inputs

"Today" is `src/modernforms_fan/fan/light.lua` and `src/common/device.lua`
as of 2026-11-09.

| # | Input | Arrives at the driver as | Rate or time carried | Source | Today |
| --- | --- | --- | --- | --- | --- |
| I1 | Keypad tap on a button bound to the light's Top, Bottom or Toggle link (200 to 202) | `DO_PUSH`, then `DO_CLICK` about 0.15 to 0.25 s later, on the link's binding | None. The light's own Click Rate Up or Down applies, and exists only with `click_rates` True | VERIFIED-doc: KPD `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`; LV2 caps `_11-CLICKRATES.md`. VERIFIED-house: K6, K7 (push then click 0.15 to 0.25 s apart) | Instant: top to Default On Brightness, bottom to off, toggle by the shown state |
| I2 | The same tap through the proxy | `BUTTON_ACTION` {`BUTTON_ID` 0, 1 or 2, `ACTION` 1 press, then 2 release as a click}, which the driver must echo | None, as I1 | VERIFIED-doc: LV2 cmds `_1-BUTTONACTION.md`, notif `_1-BUTTONACTION.md` | As I1 |
| I3 | Double or triple tap | Two or three push and click pairs; nothing of its own on a link. The keypad's own double-tap event fires when the taps come within about half a second, and Press and Release fire as well | None | VERIFIED-doc: C4-LIGHTING; KPD `61_keypad_protocol_notifications/_2-CLICKCOUNT.md`. VERIFIED-house: K6 (two pairs, no other message) | Each tap acts: a double tap on Toggle turns the light on and off again |
| I4 | Hold and release | `DO_PUSH` ... `DO_RELEASE`, or `BUTTON_ACTION` 1 then 0 | None. The light's Hold Ramp Rate Up or Down applies: the time for the whole range | VERIFIED-doc: LV2 cmds `_10-SET_HOLD_RATE_UP.md`, `_11-SET_HOLD_RATE_DOWN.md`; notif `_9-HOLDRATEDOWN.md`, `_10-HOLDRATEUP.md` | Steps every 500 ms at hold rate × distance / 100 |
| I5 | `SET_BRIGHTNESS_TARGET` | {`LIGHT_BRIGHTNESS_TARGET`, `RATE`} with `supports_target` True | `RATE`: milliseconds for this change, kept by the proxy between the driver's minimum and maximum rates | VERIFIED-doc: LV2 cmds `_1.5-SETBRIGHTNESSTARGET.md`. VERIFIED-house (HUE): the underscore spelling arrives | Instant; the rate is ignored |
| I6 | Navigator slider | `SET_BRIGHTNESS_TARGET` with `RATE` 0 | 0 | VERIFIED-house (HUE `docs/design.md`, "Lights: verified on hardware") | Instant |
| I7 | Navigator on or off tap | A target command that, on the Hue house, carried 750 ms | The proxy's rate. That 750 ms is the proxy's Default Brightness Rate, or the On preset's rate, is INFERRED | VERIFIED-house (HUE `docs/design.md`, "Scenes build: verified on hardware": a tile's ON on a light_v2 device, then declared as a switch, arrived with 750 ms; that driver's own ON handler used 0, so the 750 came from the proxy). Since OS 3.3.2 Navigators send `DYNAMIC_ON` and `DYNAMIC_OFF`, and a driver without dynamic on gets the On preset instead (VERIFIED-doc: LV2 cmds `_1.3-DYNAMICON.md`, `_1.2-DYNAMICOFF.md`) | Instant |
| I8 | `RAMP_TO_LEVEL` | {`LEVEL`, `TIME`} | `TIME`: milliseconds for the change | VERIFIED-doc: API `32_serial_network_device/_19-SendToDevice.md` (its example ramps a light to 60 % over 3 s); LV2 cmds `_1.5` gives the same pair as the target command's older form. VERIFIED-house (HUE): sent into a light_v2 proxy with `SendToDevice`, it reached the driver with its time | Instant; `TIME` is ignored |
| I9 | `SET_LEVEL` | {`LEVEL`} | None | VERIFIED-doc: FUND `9_commands/_1-COMMANDS.md` (Composer shows Set Level in programming for a dimmer) | Instant |
| I10 | `ON`, `OFF`, `TOGGLE` | No parameters | None. The Default Brightness Rate is the documented rate for generic on and off commands | VERIFIED-doc: LV2 cmds `_7-TOGGLE.md`, `_20.2`, `_21.3` | Instant: ON and TOGGLE from off to Default On Brightness |
| I11 | Advanced Lighting scene activated (`reduced_als_support`) | `SET_BRIGHTNESS_TARGET` per light | The scene's rate for this light, which the dealer sets per load in milliseconds, seconds or minutes | VERIFIED-doc: LV2 caps `22-REDUCEDALSSUPPORT.md`, als `_1.3-REDUCEDALSSUPPORT.md`; C4-ALS. That `RATE` carries the per-load rate is INFERRED | As I5 |
| I12 | Advanced Lighting scene ramped (a held scene button) | `RAMP_SCENE_UP` or `RAMP_SCENE_DOWN` {`SCENE_ID`}, ended by `STOP_SCENE_RAMP` (`STOP_RAMP_SCENE` in one file); on OS 3.3.2 and later possibly targets and `SET_BRIGHTNESS_STOP` instead | No rate in the ramp commands. Composer gives each scene its own hold rates, which work like a dimmer's hold rates, but nothing carries them to a reduced-ALS driver | VERIFIED-doc: LV2 als `_1.3`, `_4.1-RAMPSCENEUP.md`, `_4.2-RAMPSCENEDOWN.md`, `_4.2-STOPRAMPSCENE.md`; caps `22-REDUCEDALSSUPPORT.md` (3.3.2 wording); C4-ALS. Which route the house uses is ASSUMED | Steps at the light's hold rate |
| I13 | Stop | `SET_BRIGHTNESS_STOP`, no parameters: from scenes, the Daylight Agent and the proxy's Brightness Stop link | None | VERIFIED-doc: LV2 cmds `_21.5`; caps `_29`. VERIFIED-house: the probe's light showed the Brightness Stop link (K4). That the link sends this command is ASSUMED | Freezes a hold or scene ramp, else closes an open CHANGING |
| I14 | Composer programming | On, Off, Toggle, Set Level, a ramp to a level over a time, and the stop | A time for the ramp commands, between `click_rate_min` and `hold_rate_max`, enforced since OS 3.3.0 | VERIFIED-doc: LV2 caps `_12-CLICKRATEMIN.md`, `_16-HOLDRATEMAX.md`; BP "Enforcing min/max Capabilities". Which command name a programmed ramp arrives as (I5 or I8) is ASSUMED | As I5, I8, I9, I10 |
| I15 | Voice control and customer-made scenes | INFERRED: targets | The brightness rate, bounded by `brightness_rate_min` and `_max` | VERIFIED-doc: LV2 caps `_1-BRIGHTNESSRATEMAX.md`, `_1.5-BRIGHTNESSRATEMIN.md` | As I5 |
| I16 | Another driver's Lua | `C4:SendToDevice` into the light's proxy: ON, OFF, SET_LEVEL and RAMP_TO_LEVEL act; SET_BRIGHTNESS_TARGET sent that way does nothing | As I8 to I10 | VERIFIED-house (HUE `docs/design.md`, "Lights: verified on hardware") | As I8 to I10 |
| I17 | Load groups (`GROUP_RAMP_TO_LEVEL`, `GROUP_START_RAMP` with a rate) | Only with `load_group_support` True | A time or rate | VERIFIED-doc: LV2 cmds `_14` to `_20` | Not declared (False): never arrives |

The settings commands are not level changes, but they set the rates the
driver uses: `SET_CLICK_RATE_UP` and `_DOWN` (only with `click_rates`),
`SET_HOLD_RATE_UP` and `_DOWN`, `SET_PRESET_LEVEL`, and
`UPDATE_BRIGHTNESS_RATE_DEFAULT` (VERIFIED-doc: LV2 cmds `_8`, `_9`,
`_10`, `_11`, `_22`, `_23`, `_6`, `_20.2`). The driver must answer a click
rate with `CLICK_RATE_UP` or `_DOWN` carrying the value it took
(VERIFIED-doc: LV2 cmds `_22-SETCLICKRATEUP.md`, `_23-SETCLICKRATEDOWN.md`),
as the bare value (VERIFIED-house: HUE #59; this driver's `device.lua`
already does so for the hold rates).

### 1.2 Two kinds of rate

| Kind | Inputs | Meaning | Source |
| --- | --- | --- | --- |
| Speed | Click rates (taps), hold rates (holds, scene ramps) | The time for the whole range, off to full or full to off. A shorter distance takes proportionally less: rate × distance / 100 | VERIFIED-doc: LV2 notif `_4-CLICKRATEDOWN.md`, `_5-CLICKRATEUP.md`, `_9`, `_10` |
| Duration | `RATE`, `TIME`, the Default Brightness Rate, a scene's per-load rate | The time this one change should take, whatever the distance | VERIFIED-doc: LV2 cmds `_1.5`, `_20.2`; notif `_10.3` (CHANGING's rate is the time to reach the target) |

Composer's help pages word the click rate differently: one calls Ramp Up
the time to reach the preset On level (C4-DIM), the other the rate from off
to on (C4-DIMPROPS). The protocol files are the exact ones, and the Hue
driver chose the whole-range meaning in #421 (HUE `docs/tap-stop-design.md`
D3). With Default On Brightness at 100, a tap from off takes exactly the
click rate under both readings.

### 1.3 What the driver reports during and after a fade

| Moment | Notify | Source |
| --- | --- | --- |
| The fade starts | `LIGHT_BRIGHTNESS_CHANGING` {`LIGHT_BRIGHTNESS_CURRENT` where it is, `LIGHT_BRIGHTNESS_TARGET` where it goes, `RATE` the milliseconds to get there} | VERIFIED-doc: LV2 notif `_10.3` |
| A hold or scene ramp starts | The same, with the end of the range as the target (100, or the bottom) and the time to reach it | VERIFIED-doc: LV2 notif `_10.3`; BP "Brightness Target API" |
| While it fades | Nothing to the proxy. No `LIGHT_LEVEL`, no CHANGED per step. Snap One lists 20 ms, 500 ms and 1 s step reports by name as the wrong way | VERIFIED-doc: LV2 notif `_12-LIGHTLEVEL.md` (usage note); BP "Brightness Target API" |
| It ends, or is stopped | `LIGHT_BRIGHTNESS_CHANGED` {`LIGHT_BRIGHTNESS_CURRENT`} once, with where it stopped. Snap One's own example is a hold released at 30 % | VERIFIED-doc: LV2 notif `_10.2`; BP "Brightness Target API" |
| A new command replaces the fade | A new CHANGING from the level it has reached, with the new target and time; no CHANGED in between is needed | INFERRED: CHANGED never requires a CHANGING before it (LV2 notif `_10.2`), and nothing says a second CHANGING needs a CHANGED first. The driver already sends a new CHANGING for every target without closing the last (`light.lua`, `target`), and so does the Hue Light |
| The driver starts, or the fan comes back | CHANGED with the real level | VERIFIED-doc: LV2 notif `_10.2` |

Rules that carry over unchanged:

- The level is a whole percent and never 0 while the light is on
  (VERIFIED-house: HUE, a decimal level showed as off on OS 3.4.2;
  [`v1-design.md` §4.5](v1-design.md#45-settled-reports-r1r9), R1 to R9).
- Every CHANGING is closed by a CHANGED, even when a command fails,
  or a tile keeps animating (HUE L4; this driver's watchdog and
  `recover`).
- The optional preset ids in CHANGING and CHANGED serve the Daylight Agent
  (VERIFIED-doc: LV2 notif `_10.2`, `_10.3`). They are not part of #141.

One more reason not to report steps: with the "Previous" On Mode, the proxy
remembers the last non-zero level it heard before a CHANGED of 0
(VERIFIED-doc: LV2 caps `_7-brightnessonmodeprevious.md`). A fade to off
that reported its steps would leave "Previous" at 1 %. This driver does not
declare that mode, but the rule keeps the door open.

### 1.4 A new command while a fade runs

| Arrives mid-fade | What Control4 documents | Status |
| --- | --- | --- |
| A keypad tap | The dimmer stops where it is | VERIFIED-doc: C4-USER-SW |
| `SET_BRIGHTNESS_STOP`, a scene ramp's stop | The ramp stops where it is | VERIFIED-doc: LV2 cmds `_21.5`; caps `_29` |
| A new target (slider, programming, a scene) | The light goes from where it is to the new target over the new time | INFERRED from LV2 cmds `_1.5` (the target names where the light is now asked to go); SILENT otherwise |
| `ON`, `OFF`, `TOGGLE` | As a new target. Snap One warns that `TOGGLE` depends on reported state and should not be used where the end level matters | VERIFIED-doc: LV2 cmds `_7-TOGGLE.md` for the warning; the rest INFERRED |
| A hold | SILENT. HUE #421: stop, then hold from the stopped level | HUE `docs/tap-stop-design.md` section 3 |
| A colour command | Brightness and colour commands must not cancel each other | VERIFIED-doc: BP "Handling Consecutive Brightness and Color commands". Not applicable: this light has no colour |

## 2. Click rates and the other rate capabilities

### 2.1 What `click_rates` changes

- **Composer rows.** With `click_rates` True the light's settings page
  shows the click rates; without it, it does not (VERIFIED-doc: LV2 caps
  `_11-CLICKRATES.md`). The probe's light, which declared False, showed
  Default On Brightness, Brightness Presets, the Default Brightness Rate,
  the Hold Ramp Rates and the LED colours, and no Click Rates section
  (VERIFIED-house: K4).
- **Presets.** It also adds the proxy's "Fast On" and "Fast Off"
  brightness presets (VERIFIED-doc: LV2 caps `_11`). The click rates are
  the rates of the On and Off presets (VERIFIED-doc: LV2 vars, Click Rate Up
  1002 and Click Rate Down 1003; notif `_4`, `_5`). The hold rates belong to
  "Slow On" and "Slow Off" (VERIFIED-doc: LV2 notif `_9`, `_10`). So a
  preset run from programming or a scene probably arrives as a target with
  the preset's rate (INFERRED).
- **Not dynamic.** It cannot be switched at run time (VERIFIED-doc: LV2
  caps `_11`).

### 2.2 The click rate fields

- **Where the dealer sets them:** the light's settings page in Composer,
  as Click Rates Ramp Up and Ramp Down (VERIFIED-doc: C4-DIM, C4-DIMPROPS,
  which give no unit or default for them; the hold rates are given in
  seconds).
- **How they reach the driver:** an edit sends `SET_CLICK_RATE_UP` or
  `_DOWN` {`RATE` in ms}, and the driver must answer with the value it took
  (VERIFIED-doc: LV2 cmds `_22`, `_23`). The answer is the bare value
  (VERIFIED-house: HUE #59).
- **The default:** the driver's own. At late init it reports the value in
  use, which Composer then shows (VERIFIED-house: HUE L24, #59; this
  driver's `device.lua` does the same for its preset and hold rates). This
  driver's `device.lua` already defines `click_up` and `click_down` at
  250 ms, unused because the light's settings list leaves them out
  (`src/modernforms_fan/driver.lua`, `settings = { "preset", "hold_up",
  "hold_down" }`). The Hue drivers moved their default to 3000 ms in #421.
- **A stored value wins.** A device stores a rate only when someone edits
  the row; a new default never overwrites a stored value (HUE
  `docs/tap-stop-research-c4.md` §5.2, from the shared `device.lua`).

### 2.3 The related capabilities

| Capability | What it does | Dynamic | This driver | Source |
| --- | --- | --- | --- | --- |
| `click_rate_min`, `click_rate_max` | The range a dealer may set. `click_rate_min` is also the shortest ramp time programming offers. Enforced in Composer, scenes, programming and UIs since OS 3.3.0 | No | Not declared. The documented default maximum is 1 ms, while the proxy's samples show 86 400 000 ms; the Hue house has accepted 250, 750 and 3000 ms | VERIFIED-doc: LV2 caps `_12`, `_13`; vars (6661 sample); cmds `_16.5-GETSETUP.md` (sample); BP "Enforcing min/max Capabilities". VERIFIED-house: HUE `docs/status.md` |
| `hold_rates`, `hold_rate_min`, `hold_rate_max` | The hold rate rows and their range; `hold_rate_max` is also the longest ramp time programming offers (default 86 400 000 ms, a day) | No | True, minimum 1000, maximum not declared | VERIFIED-doc: LV2 caps `_14`, `_15`, `_16` |
| `brightness_rate_min`, `brightness_rate_max` | The range of the brightness rate used by voice, Navigators and customer-made scenes; added in OS 3.3.2 for drivers without buttons | Yes | Not declared | VERIFIED-doc: LV2 caps `_1`, `_1.5`; new `_10-WHATSNEWIN332.md` |
| `supports_target` | The target API: `SET_BRIGHTNESS_TARGET` in, CHANGING and CHANGED out | Yes | True | VERIFIED-doc: LV2 caps `_4-SUPPORTSTARGET.md` |
| `supports_brightness_stop` | A ramp can be stopped, by `SET_BRIGHTNESS_STOP`; reduced-ALS drivers should declare it | Yes | True | VERIFIED-doc: LV2 caps `_29` |
| `has_fixed_ramp_rate`, `fixed_ramp_rate` | For hardware whose ramp cannot be changed; deprecated in 3.3.2 for the click rate range | Yes | Not declared; not applicable, since the driver can fade at any rate | VERIFIED-doc: LV2 caps `_9`, `_10`; new `_10` |
| `brightness_on_mode_preset`, `_previous` | Control4's On Modes, replacing `supports_default_on` | No | Not declared (`supports_default_on` True) | VERIFIED-doc: LV2 caps `_6`, `_7`, `_32` |
| `has_button_events`, `multi_click` | The light's own button events in programming | No | Not declared | VERIFIED-doc: LV2 caps `_26`, `_28.5` |

The Default Brightness Rate is a proxy setting, not a capability: the
proxy shows it without any declaration (VERIFIED-house: K4) and tells the
driver its value with `UPDATE_BRIGHTNESS_RATE_DEFAULT` when it changes
(VERIFIED-doc: LV2 cmds `_21.3`, `_20.2`, both new in 3.3.2). Whether the
proxy also sends it at start is ASSUMED: the probe's list of what the light
proxy sends at the add does not include it (K8).

### 2.4 What a capability change costs

- **Static capabilities** (`click_rates`, `click_rate_min`,
  `click_rate_max`, `hold_rate_*`, the On Modes) are read when the device is
  created. On the house, a build that changes one makes Composer ask
  "Restart Director?", and answering Yes does not load it: only the owner's
  reboot of the controller from System Manager does (VERIFIED-house: HUE
  `docs/keypad-design.md` "Install findings", HUE L82;
  [`light-structure-research.md` §1.2](light-structure-research.md#12-capabilities);
  the comment above `<capabilities>` in `src/modernforms_fan/driver.xml`).
  That a changed `click_rates` in particular shows its rows after that
  reboot is ASSUMED.
- **Dynamic capabilities** (`brightness_rate_min` and `_max`,
  `supports_brightness_stop`) can be sent at run time with
  `DYNAMIC_CAPABILITIES_CHANGED` and need no reboot (VERIFIED-doc: LV2
  notif `_8-DYNAMICCAPABILITIESCHANGED.md`).
- **Lua, properties and connections** take effect with the update
  (VERIFIED-house: HUE and this project's releases).
- **A hint the documents do not back.** The dynamic-capabilities page says
  that turning `dimmer` on re-reads the click and hold rates from the
  driver file and asks drivers that set those rates dynamically to send them
  again. The proxy's dynamic-capabilities variable also lists the click and
  hold rate ranges (VERIFIED-doc: LV2 notif `_8`; vars 6661). That suggests
  the ranges might be dynamic, but the capability pages say No, and nothing
  says `click_rates` itself can be. Not to be relied on; check H7 tries it.
- **What else could share the reboot:** an explicit `click_rate_min` (0)
  and `click_rate_max`, so Composer's range does not hang on a documented
  default of 1 ms; and dropping the capabilities deprecated in 3.3.2
  (`ramp_level`, `on_off`, `min_max`, `buttons_are_virtual`, VERIFIED-doc:
  LV2 new `_10`), which the Hue checklist calls harmless and plans to drop
  with its own On Mode reboot (HUE L85, #429). See Q8.

### 2.5 Three ways to give taps a fade

| Route | What the dealer sees | Reboot | Fits Control4's guidance |
| --- | --- | --- | --- |
| A. Taps use the light's Default Brightness Rate | The existing Default Brightness Rate row also sets the tap's fade | No | Partly. The documents give that rate to commands that arrive without one, and a tap does; but Control4's dimmers set tap speed with Click Rates, and the default rate is a duration, not a whole-range speed. It also depends on the proxy telling the driver the value (H1) |
| B. A driver property, such as "Tap Fade (s)", on the fan item | A row Control4's own dimmers do not have, on the parent item rather than the light | No | No: a departure the hardware does not force |
| C. `click_rates` True | Click Rates Ramp Up and Ramp Down on the light's settings page, like a Control4 dimmer and the Hue Light; the Fast On and Fast Off presets | Yes, once | Yes |

Recommendation: **C**, released with the rest of #141 so the owner reboots
once. A is a fallback if the reboot must wait.

## 3. What Control4's own dimmers do

### 3.1 Documented

| Behaviour | Source |
| --- | --- |
| A tap on the top ramps the light up to full; a tap on the bottom ramps it down until off | VERIFIED-doc: C4-USER-SW |
| A tap while the light is dimming stops it at that point, at any time | VERIFIED-doc: C4-USER-SW |
| Holding the top brightens slowly, holding the bottom dims slowly | VERIFIED-doc: C4-USER-SW |
| The installer can change the dimming rates | VERIFIED-doc: C4-USER-SW |
| Ramp Up and Ramp Down (the click rates) are how long a click takes to reach the On preset or off; the Hold Ramp Rates are the time to full or to off while held, in seconds | VERIFIED-doc: C4-DIM, C4-DIMPROPS |
| The On preset (Default On Brightness) is where a top tap goes, whatever the current level, even from higher | VERIFIED-doc: LV2 vars, Default On Preset Brightness (1006); cmds `_6-SET_PRESET_LEVEL.md` |
| Double and triple taps are their own events for taps within about half a second; Press and Release still fire | VERIFIED-doc: C4-LIGHTING |
| With "LEDs Follow Load", a dimmer's LEDs show whether its load is on | VERIFIED-doc: C4-DIM |
| A scene sets a rate per load, in ms, seconds or minutes, and its own hold rates for ramping | VERIFIED-doc: C4-ALS |

### 3.2 Not documented

- **Default click and hold rates.** Neither C4-DIM nor C4-DIMPROPS gives
  one, nor does C4-ALS for scenes (VERIFIED-doc, by absence). The only
  defaults those pages state are for other settings (Min On, Cold Start).
- **The second tap on the other button,** and on Toggle: stop or reverse?
  The user guide says any tap stops (C4-USER-SW); the Hue design read it as
  stop (HUE `docs/tap-stop-design.md` D5). Reversing is SILENT.
- **A tap while brightening:** the guide's example is a dimming light, but
  its "at any time" covers both (INFERRED).
- **When the LED of a dimmer, or of a keypad following it, changes during
  a slow fade:** at the press, at the first light, or when the fade ends?
  SILENT; check H4.
- **What a dimmer does with a rate of 0:** SILENT.

### 3.3 Folklore

- One c4forums post, seen only as a search result, reports a keypad
  dimmer set to a 2 s click rate and 5 s hold rates. That is one dealer's
  setting, not a default (FOLKLORE).
- A Reddit thread says newer keypad dimmers offer no programmable click
  ramp, and a reply points to Advanced Lighting scenes for custom rates
  (FOLKLORE).

### 3.4 House evidence

- A Navigator tap on a light_v2 device arrived with a 750 ms rate
  (VERIFIED-house: HUE `docs/design.md`, "Scenes build: verified on
  hardware"). That this is the proxy's out-of-the-box Default Brightness
  Rate is ASSUMED.
- The Hue Light devices' click rates were 0.25 and 0.75 s until the owner
  set them to 3 s on 2026-11-09, after #421 (VERIFIED-house: HUE
  `docs/status.md`).
- A keypad double tap reaches a bound link as two push and click pairs and
  nothing else (VERIFIED-house: K6).
- The fan took 3 to 4 level requests a second in K13, with a rare outlier
  of about 1.5 s (VERIFIED-house: issue #17). The step plan is the
  companion note's.

### 3.5 The Hue tap-stop design: what carries over

The Hue driver solved the same Control4 question for bulbs that fade
natively (HUE `docs/tap-stop-design.md`, built and released in v1.4).

| Hue #421 piece | For the fan's light |
| --- | --- |
| Click rates as whole-range times, 3000 ms up and down by default; hold rates 5000 ms (D3) | **Carries over.** Needs `click_rates` True here (section 2), which the Hue Light had from the start, so Hue needed no reboot |
| The top tap goes to the On preset, ramping down when above it; the bottom tap to off; toggle by the on state; nothing at the preset (D2, section 3) | **Carries over** |
| Double-tap window: a press within 600 ms of the last press on the same button starts and stops nothing, and the first tap acts at once (D4) | **Carries over.** It lives in the Hue repo's `src/common/device.lua` (`DOUBLE_TAP_MS`); this repo's copy predates it |
| The stop on the press of any later tap outside the window, the click that follows swallowed, a press held into a hold from the stopped level (D5) | **Carries over**, through the same two hooks (`dev.ramp_active`, `dev.on_ramp_stop`) |
| Any timed brightness change can be stopped by a tap, not only a tap's own (D6) | **Carries over**: every fade is the driver's own here |
| `SET_BRIGHTNESS_STOP` and the scene stops stop for real (D7) | **Carries over, more simply**: the driver stops stepping |
| Any brightness command replaces a running ramp (D11) | **Carries over** |
| A stop near off stays at 1 % | **Carries over** |
| CHANGING at the start, CHANGED once at the stop or end (D10) | **Carries over** |
| Hue's fade engine (`dynamics.duration`), the `dimming_delta` stop and the "glide" stop (D8, D9, section 10) | **Does not apply**: the driver steps the fan itself; the stop is the last step it sends |
| Holding back the bridge's early report of the target (D10, Hue L1) | **Does not apply** to the driver's own fade. A poll's answer during a fade is the companion note's question |
| The estimate as CHANGED at a stop, corrected by Hue about 10 s later | **Better here**: the end level is what the fan answered for the last step, so CHANGED can carry the confirmed level (this driver's rule R4) |
| Urgent sends past the request queue (D12, D13) | **Different**: one request in flight with the latest wanted level winning ([`v1-design.md` §4.3](v1-design.md#43-what-goes-next)) already means a stop replaces any unsent step |
| Groups, scenes and smart scenes (D14, S-D1 to S-D6) | **Not applicable** |
| Stored click rates on existing devices set by the Windows session at install (D15) | **Carries over in a simpler form**: this light has never had click rates, so no device has a stored one; after the reboot, a read-back of the rows checks the default arrived (H6) |

## 4. What Navigators and programming see during a fade

An example: a top tap with the light off, Default On Brightness 100, Click
Rate Up 3000 ms.

| When | The driver | What the system shows | Source |
| --- | --- | --- | --- |
| The tap | CHANGING {0, 100, 3000} | The tile's slider starts moving from 0 toward 100 over 3 s by itself | VERIFIED-doc: BP "Brightness Target API" |
| The tap | | Programming's "Brightness begins to ramp" (Light Brightness Changing, event 4000) fires once; `IS_BRIGHTNESS_TARGET` 100 is true | VERIFIED-doc: BP "Brightness and Color Changing API"; LV2 events `_0-HEADER.md`, cond `_0-HEADER.md` |
| During | Steps to the fan only | For UIs that ask mid-ramp, the proxy keeps the ramp's rate and the time left (variables 1120 and 1121), refreshed each second | VERIFIED-doc: LV2 vars `_0-HEADER.md`. That the proxy fills them from CHANGING is INFERRED |
| During | | The Brightness Percent variable (1001) and `IS_BRIGHTNESS`: whether they hold the last reported level or follow the animation | SILENT; ASSUMED the last reported level |
| About 3 s, the last step answered | CHANGED {100} | The slider settles at 100; Light Brightness Changed (4001) fires once, and so does the older Light Level Changed (5000), which marks the final level | VERIFIED-doc: LV2 events `_0-HEADER.md`, notif `_10.2` |
| ? | | Light On (5100) and Light Off (5101): at the CHANGING that leaves or heads for 0, or only at the CHANGED | SILENT; check H5 |
| Throughout | `MATCH_LED_STATE` on the bound links | The keypad LED is on or off, nothing between: a link carries a state and two colours, no level | VERIFIED-doc: KPD `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md` |

More that follows from the same rules:

- **A slider dragged during a fade** sends a stream of targets with rate 0
  (I6); each one replaces the fade, and the tile follows the finger.
- **Scene tracking** (an Advanced Lighting scene lit while "At Scene Final
  Level") reads the reported levels. One CHANGED at the end keeps it from
  flickering on and off through the fade (VERIFIED-doc: BP "Brightness
  Target API" names wrong scene tracking as a cost of step reports).
- **The keypad's own events** (double tap and the rest) belong to the
  keypad; the light hears taps (VERIFIED-doc: KPD
  `61_keypad_protocol_notifications/_2-CLICKCOUNT.md`,
  `_4-KEYPAD_BUTTON_ACTION.md`).
- **The UI Button proxy and the light's Extras tab** do not touch levels
  or LEDs: a UI Button only takes `SELECT` (VERIFIED-doc: UIB
  `107_ui_button_proxy_commands/_1-SELECT.md`), and Extras is for features
  the proxy does not know (VERIFIED-doc: EX). A fade switch on the Extras
  tab would depart from how Control4 dimmers are set up; not recommended.
- **Timers.** `C4:SetTimer` takes milliseconds and skips beats when
  Director is busy, and `C4:GetTime` gives the clock in milliseconds from
  OS 3.2.3 (VERIFIED-doc: API `34_timer/_1-SetTimer.md`, `_2-GetTime.md`).
  A fade that works out its level from the elapsed time, as `light.lua`'s
  `estimate` already does, keeps its length when a beat is skipped.
- **OS versions.** The target API is from OS 3.3.0, the driver's minimum.
  `SET_BRIGHTNESS_STOP`, `brightness_rate_*` and the Default Brightness
  Rate commands are from 3.3.2, and the Brightness Stop link worked from
  3.3.3 (VERIFIED-doc: LV2 new `_10-WHATSNEWIN332.md`; caps `_29`). On
  3.3.0 and 3.3.1 a fade still works; it simply never hears those commands.
  The house runs 3.4.2.

## 5. Recommendation

One rule for every input: **the driver fades every change that comes with
a time above 0 and reports it once at each end**: CHANGING with the time
at the start, and CHANGED with the level the fan confirmed when the fade
ends or stops. A change with no time, or a time of 0, is one request, as
today. The fade's step size and pace are the companion note's.

| Input | Fade | Duration, and where it comes from | Reported | Owner |
| --- | --- | --- | --- | --- |
| Top tap, off or below the preset | Yes | Click Rate Up × distance / 100: the light's own row (Composer), default **3000 ms** | CHANGING {now, preset, duration} at the tap; CHANGED at the end | Q1, Q2 |
| Top tap above the preset | Yes, down | Click Rate Down × distance / 100 | As above | Q2 |
| Top tap at the preset | No | — | CHANGED with the level | |
| Bottom tap, on | Yes, to off | Click Rate Down × level / 100, default 3000 ms | CHANGING {now, 0, duration}; CHANGED 0 once off is confirmed | Q2 |
| Bottom tap, off | No | — | Nothing | |
| Toggle tap | As top from off, as bottom from on | As those | As those | |
| A press outside the 600 ms window while a fade or ramp runs, on any button | Stops it | — | CHANGED with the confirmed level of the last step; the click is swallowed; held, it becomes a hold from there | Q7 |
| A press within 600 ms of the last on the same button | Nothing; a running fade goes on | — | Nothing (the proxy route's echo still goes out) | Q7 |
| Hold | Yes, as today | Hold Ramp Rate × distance / 100: the light's own rows, default 5000 ms | CHANGING toward 100 or the bottom; CHANGED at the release | |
| `SET_BRIGHTNESS_TARGET`, `RATE` above 0 | Yes | `RATE`, as the proxy sent it | CHANGING {now, target, `RATE`}; CHANGED at the end | |
| `SET_BRIGHTNESS_TARGET`, `RATE` 0 (the slider) | No | — | CHANGING with rate 0, then CHANGED, as today | Q4 |
| `RAMP_TO_LEVEL` | Yes when `TIME` is above 0 | `TIME` | As `SET_BRIGHTNESS_TARGET` | |
| `ON`, `OFF`, `TOGGLE`, `SET_LEVEL` (no time) | Recommended yes | The Default Brightness Rate the proxy last sent with `UPDATE_BRIGHTNESS_RATE_DEFAULT`, persisted; until one arrives, a built-in default | CHANGING with that duration; CHANGED at the end | Q3, H1 |
| Navigator on or off tap | Yes | Whatever rate the proxy sends (750 ms seen on the house) | As `SET_BRIGHTNESS_TARGET` | Q5, H2 |
| Advanced Lighting scene | Yes | The scene's per-load rate, as `RATE` | As `SET_BRIGHTNESS_TARGET` | |
| Scene ramp (`RAMP_SCENE_UP`, `_DOWN`) | Yes, as today | The light's hold rates (the command carries none) | As a hold; stopped by the scene's stop | H3 |
| `SET_BRIGHTNESS_STOP`, `STOP_SCENE_RAMP`, `STOP_RAMP_SCENE` | Stops any fade, hold or ramp | — | CHANGED with the confirmed level | |
| Any level command during a fade | Replaces it, from where it is | The new command's | A new CHANGING from the reached level | |
| `TOGGLE` during a fade | Goes by where the fade is heading (a fade to off counts as off), as `TOGGLE` reads the shown state today | The Default Brightness Rate (Q3) | As above | |
| Keypad LEDs | — | — | Follow the light: lit from the first step of a fade up from off, dark when a fade down reaches off | Q6, H4 |

Capabilities, in one build and one reboot: `click_rates` True, with an
explicit `click_rate_min` 0 and `click_rate_max` (86 400 000, the value the
proxy's samples show). Optionally `brightness_rate_min` and `_max`, which
are dynamic and can be sent at run time with no reboot; nothing in #141
needs them.

Lua, with no reboot: the Hue repo's #421 changes to `common/device.lua`
(the window and the stop hooks), the click rate settings on the light's
list with defaults of 3000 ms, a handler for
`UPDATE_BRIGHTNESS_RATE_DEFAULT`, and `fan/light.lua`'s fade.

## 6. Questions for the owner

1. **Taps fade through Click Rates (one controller reboot), or through the
   Default Brightness Rate (no reboot)?** Recommended: Click Rates
   (section 2.5, route C), as on Control4's dimmers and the Hue Light.
2. **Click Rate Up and Down 3000 ms for the whole range**, as the Hue
   Light since #421 (so a tap from off to 100 takes 3 s, and from 50 to 100
   takes 1.5 s)? Recommended: yes. The alternative is "every tap takes
   3 s whatever the distance", which departs from the protocol's meaning.
3. **Programming's On, Off, Toggle and Set Level, which carry no time:
   instant as today, or the light's Default Brightness Rate**, which the
   documents give them? Recommended: the Default Brightness Rate. The Hue
   Light sends them instantly today (HUE L23, partial), so the two drivers
   would differ until Hue's #429 adopts the same.
4. **The Navigator slider sends rate 0: jump, or a short fade anyway?**
   Recommended: jump, as asked; the tile jumps too, so light and tile
   agree.
5. **Navigator on and off taps** fade at whatever the proxy sends (750 ms
   seen on the house). Should the house's Default Brightness Rate on this
   light be set to 3 s, to match the keypad taps? That is a Composer
   setting, not code; the Windows session can set it at install.
6. **Keypad LEDs during a fade:** follow the light (recommended; a
   bottom-tap fade keeps the LED as "on" until the light is off), or change
   at the press, as every change does today? H4 shows what a Control4
   dimmer does; the recommendation follows it if it differs.
7. **Take over the Hue #421 tap machine whole:** the 600 ms double-tap
   window, the stop on the press of any button, and any timed change
   stoppable by a tap? Recommended: yes.
8. **In the same reboot, drop the deprecated capabilities** (`ramp_level`,
   `on_off`, `min_max`, `buttons_are_virtual`)? Recommended: no, keep them
   as the Hue Light does until its #429 reboot decides; nothing in #141
   needs the change.

## 7. Checks on the house

Each takes under a minute. The driver's debug log names every proxy
command but not its parameters (`src/common/dispatch.lua`), so the feature
build should log the parameters of the rate commands at debug.

| # | Check | Settles |
| --- | --- | --- |
| H1 | With Debug Mode on: restart the driver and look for `UPDATE_BRIGHTNESS_RATE_DEFAULT`; then change the light's Default Brightness Rate in Composer and look again. Read the value the row shows | Whether the driver hears the default at start or only on an edit, and the house's value (Q3, Q5) |
| H2 | Tap the light's tile on and off in the Control4 app, before and after the reboot. Read the command and its rate | I7: which command and which rate (the default rate or the click rate) |
| H3 | Hold a button bound to an Advanced Lighting scene that contains the light, then release. Read the commands | I12: `RAMP_SCENE_*` or targets with a stop |
| H4 | On a Control4 dimmer in the house, set Click Rate Down to 5 s, tap bottom, and watch its LED and a keypad LED following it; set it back | When a Control4 LED changes during a fade (Q6) |
| H5 | A Composer script on the light's Light On event (for example a keypad LED) during a 5 s fade up from off | Whether Light On fires at the start or the end of a fade |
| H6 | After the release and the reboot: the light's settings page shows Click Rates Ramp Up and Down at 3.000 s, and Composer accepts 3000 ms | The capability loaded; `click_rate_max` is right |
| H7 | Optional, before the release, through the dev loop: send `DYNAMIC_CAPABILITIES_CHANGED` {`click_rates` = true} to the light proxy and see whether the rows appear | Whether the reboot can be avoided (section 2.4; ASSUMED not) |

## 8. Where the documents disagree or say nothing

- **`RAMP_TO_LEVEL` has no page** in the light_v2 reference. It appears in
  the `SendToDevice` example and as the older form of the target command
  (API `32_serial_network_device/_19-SendToDevice.md`; LV2 cmds `_1.5`). The
  house shows it works.
- **`click_rate_max` defaults to 1 ms** on its page, while the samples of
  `GET_SETUP` and the dynamic-capabilities variable show 86 400 000 ms; the
  same `GET_SETUP` sample shows `CLICK_RATE_MIN` 250 against a documented
  default of 0 (LV2 caps `_12`, `_13`; cmds `_16.5`; vars 6661).
- **`brightness_rate_max`** is described as a colour rate and defaults to
  a 16-bit maximum (about 65 s) on its page, while the dynamic-capabilities
  page gives the brightness rate range as a signed 16-bit one; long
  customer-scene fades may need it raised (LV2 caps `_1`, notif `_8`).
- **The click rate's meaning**: whole range in the protocol, "time to the
  preset" or "from off to on" on Composer's pages (section 1.2).
- **The Fast On preset:** `click_rates` adds "Fast On" and "Fast Off"
  (LV2 caps `_11`), while the click rate notifies and variables tie the
  click rates to the "On" and "Off" presets (LV2 notif `_4`, `_5`; vars
  1002, 1003).
- **Variables 1120 and 1121** name the capability as
  `supports_brightness_target`; the capability is `supports_target` (LV2
  vars `_0-HEADER.md`, caps `_4`).
- **Reduced ALS** is described twice: one page lists the scene ramp
  commands as required, the 3.3.2 page says scenes send targets and stops
  instead (LV2 als `_1.3`, caps `22-REDUCEDALSSUPPORT.md`). The driver
  handles both.
- **The Top, Bottom and Toggle links** are said to be created by the
  proxy; on the house the driver declares them and the proxy adds only the
  Brightness Stop link (LV2 cmds `_1-BUTTONACTION.md`; VERIFIED-house: K4).
- **SILENT:** a new target mid-fade, Light On and Off timing, the
  Brightness Percent variable during a fade, a dimmer's LED during a fade,
  a rate of 0 on a dimmer, and Control4's default click and hold rates.
