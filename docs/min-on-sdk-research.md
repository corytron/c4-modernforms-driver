# Min On for the fan light: what the SDK says

> **Status (2026-11-13, #213).** Built in 1.8 (#195) by
> [`min-on-design.md`](min-on-design.md) on route B, as recommended: the
> fan item's `Light Min On (%)`, 0 to 99, default 0, with this note's
> mapping and the Status row of decision 2 ("light 40 % (fan 52)", MO-D11).
> Probe P1 was not needed and did not run, and `min_max` stays False. The
> owner had it shipped without hardware question 1, so the house's first
> glow was not measured; its fan has `Light Min On (%)` 10
> ([`status.md`](status.md)). The `click_rates` reboot this note calls
> pending had in fact happened: on 2026-11-12 the Windows session found the
> light's Click Rates keeping 3 s. The code line numbers of section 6 are
> those of 2026-11-12.

Research for [issue #195](https://github.com/corytron/c4-modernforms-driver/issues/195),
written 2026-11-12 by a read-only research agent. The owner's finding: the
fan's light fades, but it starts late, because its first few levels do not
light the LEDs. A stock Control4 dimmer load in the house does the same with
LED lamps. Control4's answer for its own dimmers is Range Levels (Min On and
Max On) in Composer. This note settles, from the SDK documents and the
Control4 help pages, how the fan light should offer a Min On and how it must
behave. Nothing here was sent to any device.

The owner's rule (Hue #422) applies throughout: lighting behaves like
Control4's own dimmers and keypads and follows Control4's published guidance;
a departure is allowed only where the hardware, or here the SDK, cannot do
what Control4 expects, and is written down with its reason.

## Contents

- [Summary](#summary)
- [Open hardware questions](#open-hardware-questions)
- [Decisions for the owner](#decisions-for-the-owner)
- [Sources and markers](#sources-and-markers)
- [1. light_v2's own Min On and Max On](#1-light_v2s-own-min-on-and-max-on)
- [2. A driver property instead](#2-a-driver-property-instead)
- [3. What Control4 expects with a Min On](#3-what-control4-expects-with-a-min-on)
- [4. The mapping](#4-the-mapping)
- [5. The Hue driver's decision](#5-the-hue-drivers-decision)
- [6. Where a level crosses between Control4 and the fan](#6-where-a-level-crosses-between-control4-and-the-fan)
- [7. Where the documents disagree or say nothing](#7-where-the-documents-disagree-or-say-nothing)

## Summary

1. **Offer it as a driver property: `Light Min On (%)`.** A
   `RANGED_INTEGER` from 0 to 99, default 0, on the fan item's Properties
   page (the light item shows only the proxy's settings page, K4). It uses
   only current, documented APIs, needs no capability change and so no
   controller reboot, and works the same on OS 3.x and 4.x. Snap One's own
   advice for the sibling setting, Cold Start, is a device-specific property
   rather than the proxy's notify (section 2). The departure: the value is not
   under Range Levels on the light's settings page, as on a Control4 dimmer.
   The reason: the proxy capability that would put it there, `min_max`, is
   deprecated since OS 3.3.2, and the SDK names no replacement for drivers
   (section 1).
2. **Control4's own Range Levels only after a check.** Whether Composer Pro
   3.4.2 still shows Range Levels for a driver that declares `min_max` True,
   and sends it `SET_MIN_ON_LEVEL`, is not in the documents. Probe P1
   (section 1.5) answers it on a new throwaway device, with no reboot, in
   about five minutes. If it passes and the owner wants Control4's place, the
   same feature takes its Min On from Range Levels instead. Max On's row then
   comes along and must work too. The fan device then needs one reboot, which
   it can share with the reboot for `click_rates` that is still pending
   (#195). OS 4.x stays unchecked on that route.
3. **The driver remaps; the proxy stays 0 to 100.** Control4 keeps its
   0 to 100 % scale with Min On; 1 % becomes the lowest level at which the
   light is on (LV2 notif `_14-MINON.md`). The remap is the hardware's job,
   so here the driver's. Everything toward Control4 (CHANGED, CHANGING, the
   preset, rates, scenes, the slider) stays in Control4 levels. Only what goes
   to the fan, and what comes back from it, is converted.
4. **The mapping**, with M the Min On and m = max(1, M):
   - to the fan: off stays off; Control4 level s from 1 to 100 goes to fan
     level m + round((s − 1) × (100 − m) / 99), rounded half up;
   - from the fan: off is 0; a fan level below m is shown as **1** (the light
     is on); a fan level f from m to 100 is shown as
     1 + round((f − m) × 99 / (100 − m)), **except** that when f is exactly
     what the level Control4 last asked for maps to, that asked level is
     shown. The exception keeps a round trip stable: 37 asked stays 37 shown,
     so scene tracking and `IS_BRIGHTNESS` work;
   - M = 0 and M = 1 are both "no remap": every level is today's, exactly.
     M = 99 leaves two fan levels: Control4's 1 to 50 is fan 99, 51 to 100 is
     fan 100. Checked for every M and every level (section 4).
5. **Defaults.** 0, which changes nothing for any install (Control4's own
   default for Min On is 0, C4-DIM). The house's value comes from H1: the
   first fan level that visibly lights, plus a few points (Control4's own
   example: a lamp dark until 20 % gets Min On 25 %).
6. **Scope.** Min On only. Max On stays out on the property route: nothing
   is wrong at the top, and adding it later is the same formula with 100
   replaced by Max On. Cold Start stays out: the light kit is LED, as the Hue
   project found (section 5).
7. **Behaviour in a few rules.** Every change runs in Control4 levels, and
   its time is the same as without Min On (the rates cover Control4's whole
   range). A turn-on from off is lit at once: a tap, a hold, a fade, the
   slider at 1 % all start at fan level m or above. A hold down stops at
   1 %, which is fan m, never dark. A level below m set by the Modern Forms
   app, the remote or the wall control is shown as 1 % and is never
   corrected. A changed Min On applies to the next change and never moves the
   light by itself.

## Open hardware questions

1. **Where does the fan's light first glow?** This sets the house's Min On.
   Cheap answer: the VM-side probe the issue plans (`tools/mf_probe.py`, a
   write check, the owner told first and the light restored after), with the
   owner watching. Two passes of about a minute each: up from off, one level
   every 2 s from 1 to 30 (a dark level write, then `lightOn`, as LF-D9
   turns on); then down from 30 to 1. Many LED drivers light later from off
   than they go dark when dimming down; if the two passes differ, the higher
   number is the one that matters (a turn-on must be lit).
2. **Route A only: does `min_max` still work for a driver on Composer Pro
   3.4.2?** Probe P1 (section 1.5): a throwaway light_v2 package added as a
   new device in a test room. No reboot, about five minutes of the Windows
   session, deleted afterwards. It shows whether Range Levels appears,
   whether `SET_MIN_ON_LEVEL` reaches the driver, whether the value sticks,
   and whether the proxy passes targets through unchanged. Not needed for the
   property route.
3. **What does a Control4 dimmer show and do with Min On?** The issue
   already plans that the Windows session reads and sets the Range Levels of
   the house's stock Control4 dimmer. While it does: (a) set the dimmer to
   1 % from Composer or a Navigator and read its Brightness Percent; it should
   read 1, not Min On, if Control4 remaps (section 3); (b) with the dimmer on
   at a mid level, change Min On and read the level again, and ask the owner
   whether the light moved. That tells whether an edit moves a lit Control4
   dimmer (section 4.5). Reads plus a setting already planned; reversible.
4. **After the release, on the fan light:** a tap, a hold and a fade from
   off, the slider at 1 %, and a scene that sets the light low all start lit
   at once; the Navigator reads the level asked, not a neighbour; the Status
   row reads as decided (Decision 2). Taps fade only after the pending
   `click_rates` reboot, so this rides the 1.5 checks H1 to H7 after that
   reboot. A few minutes, the owner watching.
5. **OS 4.x.** Neither route can be checked on the house, which runs OS 3.4.
   The property route uses nothing version-dependent (properties since
   OS 1.6, API `24_properties/`). Route A's deprecated flag may be gone there.
   Parked for the next major release, per the no-long-waits rule.

## Decisions for the owner

1. **Route:** the driver property (recommended), or Control4's Range Levels
   after P1 passes (one reboot, shared with the pending one; Max On comes
   along).
2. **The Status row** with a Min On: "light 13 % (fan 34)" when the two
   differ (recommended: the Control4 level first, as Navigators show it), or
   the Control4 level alone. Today it shows the fan's level (`texts.lua`,
   `light_part`).
3. **The house's value**, once H1 is answered: the first glow plus 3 to 5
   points (recommended, after Control4's example).

## Sources and markers

The Snap One reference is cited by path under `~/c4-tools/reference/`. It is
paraphrased here, never copied.

| Short name | Path or URL |
| --- | --- |
| LV2 | `docs-driverworks-proxyprotocol-lightv2/source/includes/`: **caps** `5_light_v2_capabilities/`, **cmds** `10_light_v2_commands/`, **notif** `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/`, **vars** `30_Light_v2_variables/`, **events** `25_light_v2_events/`, **cond** `20_light_V2_conditionals.5_light_V2_conditionals/`, **als** `45_Light_V2_advanced_lighting_scene/`, **new** `3_whats_new/` |
| PP | `docs-driverworks-proxyprotocol/source/includes/` (the same light_v2 pages in the general guide; they match LV2 apart from wording) |
| BP | `docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md` |
| EX | `docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_51-LIGHTV2EXTRAS.md` |
| FUND | `docs-driverworks-fundamentals/source/includes/` |
| API | `docs-driverworks-api/source/includes/` |
| XML | `docs-driverworks-xml/source/includes/` |
| C4-DIM | Composer help, device settings for dimmers: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerhe_userguide/device_settings_for_dimmers.htm> (read 2026-11-12) |
| C4-DIMPROPS | Composer Pro help, dimmable light properties: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/set_dimmable_light_properties.htm> (read 2026-11-12) |
| HUE | The author's Hue driver, <https://github.com/corytron/c4-hue-driver>: `docs/c4-lighting-guidelines.md` (rows L26, L85; departures D5, D13), `docs/turn-on-design.md` (D22), `src/hue_light/driver.xml` |

House records: this project's probe ([`v1-design.md`
§11.1](v1-design.md#111-what-the-probe-has-shown-so-far-17), K4), the 1.5
install rounds (Discussion #160) and issue #195.

**Markers.**

- **VERIFIED-doc**: an SDK file or Control4 help page says so (cited).
- **VERIFIED-code**: this repository's code, or the Hue repository's, does so
  (file and function cited).
- **VERIFIED-house**: seen on the house controller (the record is cited).
- **ASSUMED**: not shown by any of those. Where it is an inference, the
  reasoning is given.
- **SILENT**: no document says anything.

## 1. light_v2's own Min On and Max On

### 1.1 What the reference has

| Item | What the reference says (paraphrased) | Marker and source |
| --- | --- | --- |
| `min_max` capability | No page in the current capability list. Listed among the capabilities deprecated in 3.3.2, with `on_off`, `ramp_level`, `num_buttons`, `buttons_are_virtual` and the fixed ramp rate pair. Not among the capabilities `DYNAMIC_CAPABILITIES_CHANGED` can change. Appears once more, as True, in the Jumpstart tool's default Light capabilities, beside other flags deprecated at the same time | VERIFIED-doc: LV2 new `_10-WHATSNEWIN332.md`; the file list of LV2 caps; LV2 notif `_8-DYNAMICCAPABILITIESCHANGED.md`; FUND `26.5_jumpstart/_3-Configuration.md` |
| `SET_MIN_ON_LEVEL` {`LEVEL` 0 to 100} | The command that sets the device's minimum on level | VERIFIED-doc: LV2 cmds `_5-SET_MIN_ON_LEVEL.md` |
| `SET_MAX_ON_LEVEL` {`LEVEL` 0 to 100} | The same for the maximum. Its page prints `SET_MIN_ON_LEVEL` as its name, a copy slip | VERIFIED-doc: LV2 cmds `_4-SET_MAX_ON_LEVEL.md` |
| `MIN_ON` notify | Tells the proxy that the hardware's Min On changed. Meant for hardware that remaps where 1 % lies, naming Control4's Gen3 lighting. The proxy's 0 to 100 % range does not change. One parameter, 0 to 99, oddly named `int`. It also notes that an LED lamp's usable minimum depends on the lamp and its age | VERIFIED-doc: LV2 notif `_14-MINON.md` |
| `MAX_ON` notify | The same for the top: where 100 % lies, `BRIGHTNESS` 1 to 100; the range stays 0 to 100 % | VERIFIED-doc: LV2 notif `_13-MAXON.md` |
| `GET_SETUP` | The sample answer carries `MIN_ON_LEVEL` 1 and `MAX_ON_LEVEL` 100 | VERIFIED-doc: LV2 cmds `_16.5-GETSETUP.md` |
| Variables | Max Brightness (1007): how high a click takes the light; a hold goes past it, up to 100. Min Brightness (1008): how low the light goes before the values down to off are skipped. Brightness Percent (1001): 0 to 100 | VERIFIED-doc: LV2 vars `_0-HEADER.md` |
| Conditionals, events | Nothing about Min On; `IS_BRIGHTNESS` and `IS_BRIGHTNESS_TARGET` are percent checks | VERIFIED-doc: LV2 cond `_0-HEADER.md`, events `_0-HEADER.md` |
| What's new | 3.3.2 deprecates `min_max`; no later page (3.3.x, 3.4.x, 4.2.1) mentions Min On. The OS 3 page says minimum and maximum levels, cold start and the target level live in the proxy's new "Bulb Library" | VERIFIED-doc: LV2 new `_6` to `_20` |
| `COLD_START_LEVEL` notify | To be deprecated; Control4 recommends device-specific properties for the value instead. Its parameter text reuses the Min On wording | VERIFIED-doc: LV2 notif `_6-COLDSTARTLEVEL.md` |
| Best practice, extras | Nothing on Min On or Max On | VERIFIED-doc, by absence: BP, EX |
| Control4 help, dimmers | Range Levels: Min On is the lowest on level, default 0. Incandescent, fluorescent, CFL and LED loads differ; CFL and LED often give no light below 10 to 40 %. Set Min On a little above the first light for a clean turn-on (a lamp dark until 20 % gets 25 %). Max On is an absolute cap, unlike the preset. The page covers the Keypad Dimmer, Forward Phase, Adaptive Phase and 0-10V dimmers and does not mention third-party drivers | VERIFIED-doc: C4-DIM |
| Control4 help, dimmable lights | Range Levels smooths the dimming curve between Min On and Max On, which helps LEDs (examples 10 % and 80 %). Hold Up is the time to 100 % | VERIFIED-doc: C4-DIMPROPS |

### 1.2 Deprecated: the flag, not the command

- The 3.3.2 page deprecates the **capability** `min_max`. Its lists of
  deprecated commands (`GET_LIGHT_LEVEL`, `GET_CONNECTED_STATE`,
  `GET_PROPERTIES`) and variables (`PRESET_LEVEL`) do not include
  `SET_MIN_ON_LEVEL`, `SET_MAX_ON_LEVEL`, `MIN_ON` or `MAX_ON`, which keep
  their pages (VERIFIED-doc: LV2 new `_10`; cmds `_4`, `_5`; notif `_13`,
  `_14`).
- What replaced the flag is SILENT. For `fixed_ramp_rate` the same page names
  a replacement; for `min_max` it names none.
- This driver declares `min_max` False today, with the other deprecated flags
  kept by #141's Q8 (VERIFIED-code: `src/modernforms_fan/driver.xml`,
  `<capabilities>`; [`light-fades-design.md` LF-D3](light-fades-design.md#2-decisions)).
  The Hue project removed `min_max` in its 1.5 (VERIFIED-code: HUE
  `src/hue_light/driver.xml`; HUE `docs/turn-on-design.md` D22, checklist
  row L85).

### 1.3 Would Composer show Range Levels for this driver?

The documents do not say. The evidence:

| For | Against |
| --- | --- |
| At the 1.5 install, Composer showed the fan light's Click Rates rows from the new `click_rates` flag at once, before any reboot (VERIFIED-house: Discussion #160). So Composer lays out the light's page from the package's capabilities | `min_max` is deprecated since 3.3.2 (VERIFIED-doc: LV2 new `_10`) |
| The flag's name pairs with Range Levels' two rows, as `click_rates` and `hold_rates` pair with theirs (ASSUMED, from the names) | `MIN_ON` and `MAX_ON` describe hardware that remaps, naming Control4's Gen3 lighting (VERIFIED-doc: LV2 notif `_13`, `_14`) |
| Range Levels exists in today's Composer for Control4 dimmers (VERIFIED-doc: C4-DIM) | The help page lists only Control4 dimmer products (VERIFIED-doc: C4-DIM) |
| | The only place `min_max` True appears is Jumpstart's default Light set, which also carries other 3.3.2-deprecated flags and flags of Control4 load hardware (`has_load`, power figures); it reads as a pre-3.3.2 template, not guidance (ASSUMED) |

On the house, the light's page has no Range Levels with `min_max` False
(VERIFIED-house: K4, [`v1-design.md` §11.1](v1-design.md#111-what-the-probe-has-shown-so-far-17)).
That fits both readings.

**Who remaps.** `MIN_ON` says the hardware does, and the proxy keeps 0 to
100 (VERIFIED-doc: LV2 notif `_14`). Whether the OS 3 proxy also clamps or
scales targets once it knows a Min On is SILENT: the Bulb Library note and
variable 1008's "skipping" wording hint at something in the proxy (LV2 new
`_20-WhatwasNewinOS3.md`; vars 1008). A proxy that scaled while the driver
also remapped would remap twice. P1's step 4 settles it.

**The reboot.** `min_max` is not in the dynamic list, so on the installed fan
device it is static (ASSUMED: its own page, which would say, is gone). The
1.5 install showed what that means: Composer sent `SET_CLICK_RATE_UP` and
`_DOWN` with 3000, but the rows and the proxy's `GET_SETUP` stayed at 250
and 750 until the reboot (VERIFIED-house: Discussion #160, round 2). So a
Range Levels row could appear on the installed device at once and still not
work until the owner reboots the controller from System Manager. That reboot
is pending already for `click_rates` (#195).

**OS 4.x.** Nothing is documented; a deprecated flag may be gone there
(ASSUMED). It cannot be checked on the house.

### 1.4 Variables and level reporting

- **The scale stays 0 to 100** with Min On and Max On (VERIFIED-doc: LV2
  notif `_13`, `_14`), and Brightness Percent (1001) holds 0 to 100
  (VERIFIED-doc: LV2 vars). So the driver reports Control4 levels, never fan
  levels, on either route.
- **Min Brightness (1008) and Max Brightness (1007)** presumably hold what
  `MIN_ON` and `MAX_ON` last said (ASSUMED, from the names). On the property
  route the driver sends neither notify, so they keep their defaults.
  Sending `MIN_ON` without `min_max` is not recommended: if the proxy acted
  on it (the "skipping" of 1008), levels would be changed twice (ASSUMED
  risk, nothing documents a benefit).
- **`GET_SETUP`** would carry the value as `MIN_ON_LEVEL` (VERIFIED-doc:
  cmds `_16.5`, sample). Composer's log shows `GET_SETUP` answers
  (VERIFIED-house: Discussion #160), which P1 uses.

### 1.5 The check: probe P1

Only needed if the owner wants route A. A throwaway package, never the
driver, built beside the old probe (`probes/`, as `probes/build_probe.sh`
does):

- **Package:** one light_v2 proxy; `dimmer`, `set_level` and
  `supports_target` True, `min_max` True. Its Lua logs every proxy command
  with its parameters; answers `SET_MIN_ON_LEVEL` with `MIN_ON` and
  `SET_MAX_ON_LEVEL` with `MAX_ON`, each as the bare value (the form the
  proxy keeps for the other settings, VERIFIED-code: `src/common/device.lua`,
  `report_setting`; for these two ASSUMED); and answers every target with
  `LIGHT_BRIGHTNESS_CHANGED` at the level received. No contact with the fan.
- **Why no reboot:** a new device's capabilities are read when it is created.
  The first probe's add asked no "Restart Director?", and its light page
  showed no Click Rates, as its `click_rates` False called for
  (VERIFIED-house: K4).

| Step | The Windows session does | Pass |
| --- | --- | --- |
| 1 | Adds the package to a test room; screenshots the light's settings page | A Range Levels section with Min On (and Max On) |
| 2 | Sets Min On to 20 | Composer's log shows `SET_MIN_ON_LEVEL` {`LEVEL` 20}; the probe's log shows it arrive |
| 3 | Selects another device, then the probe again | The row still reads 20; `GET_SETUP` answers `MIN_ON_LEVEL` 20 |
| 4 | Sets the probe light to 1 % and to 50 % (Composer's Set Level, or the probe's Lua window into its proxy) | The probe's log shows targets 1 and 50: the proxy passes Control4 levels through. Any other number means the proxy scales or clamps itself |
| 5 | Deletes the probe device | Gone; nothing else touched |

Cost: one probe build, about five minutes of the Windows session, no reboot,
no change to the fan device, undone by step 5 (the standing approval covers
the add and the delete). It says nothing about OS 4.x.

If P1 passes and route A is chosen, `min_max` True goes into the fan
driver's next build before the owner's pending reboot, so one reboot covers
both. If P1 fails, the property route stands and nothing on the house has
changed.

## 2. A driver property instead

### 2.1 What the property documents allow

| Need | Documented | Source |
| --- | --- | --- |
| A whole number in a range | `RANGED_INTEGER` with `<minimum>`, `<maximum>` and `<default>`; Composer accepts only values in the range | VERIFIED-doc: XML `20_properties/_20-type.md`, `_35-default.md`, `_40-minimum.md`, `_45-maximum.md`; FUND `15_composerpro_interface_into_the_sdk/_1-PROPERTIES.md` |
| A hover text | `<tooltip>` | VERIFIED-doc: XML `20_properties/_30-tooltip.md` |
| Knowing an edit | `OnPropertyChanged(name)` runs when a user changes the row, not when the driver calls `UpdateProperty`; the value is `Properties[name]` | VERIFIED-doc: API `24_properties/_3-OnPropertyChanged.md`, `_1-Properties_table.md` |
| Surviving updates | Properties are generally safe across a driver update; adding is fine, retyping is not | VERIFIED-doc: FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` |
| No reboot | A property is not a capability. This project has added rows in releases that needed no reboot (1.6) | VERIFIED-house: [`status.md`](status.md) (1.6, "No controller reboot was needed") |

This driver already has rows of the same kind, for example `Poll Interval
(s)` (10 to 120, default 15) and `Breeze LED Night Brightness (%)`, wired
through `dispatch.properties` (VERIFIED-code: `src/modernforms_fan/driver.xml`,
`src/modernforms_fan/driver.lua`). The row's place follows the order rule of
[`v1-design.md` §2.5](v1-design.md#25-properties-in-this-order); the
coordinator decides it.

### 2.2 Where it shows, and how it fits the guidance

- **Where:** on the fan item, which carries the driver's properties; the
  light item shows only the light_v2 settings page and no Advanced Properties
  (VERIFIED-house: K4). The name says whose it is: `Light Min On (%)`.
- **Best practice:** says nothing about Min On (VERIFIED-doc, by absence:
  BP). Two documented precedents favour a property: Snap One recommends
  device-specific properties for the Cold Start value, Min On's sibling
  (VERIFIED-doc: LV2 notif `_6-COLDSTARTLEVEL.md`), and its own warm-dim
  example puts the light's Kelvin ends on the driver's Advanced Properties
  (VERIFIED-doc: BP "Warm Dim").
- **This project's rules:** LF-D24 refused a new property for fades because
  Control4 has fields for them (Click Rates). For Min On, Control4's field is
  the deprecated route, so a property is the documented fallback. It passes
  the "no one-off tooling" test: any install with a light kit that is dark at
  the bottom would use it.

### 2.3 The two routes side by side

| | A. Range Levels (`min_max` True) | B. `Light Min On (%)` property |
| --- | --- | --- |
| Where the dealer sets it | The light's settings page, as on a Control4 dimmer | The fan item's Properties page |
| Documents | A deprecated capability; command and notify current | Current APIs only |
| Proven to work for a driver | No (P1) | Yes: the same mechanism as the driver's other rows |
| Reboot | One (static capability), shareable with the pending one | None |
| OS 4.x | Unknown | Same as OS 3.x |
| Max On | Its row comes with Min On and must work or snap back to 100 | Not offered |
| Proxy told | `MIN_ON` (and `MAX_ON`) as answers, bare values | Nothing |
| Code | `device.lua` settings `min_on` (and `max_on`); same remap | One property handler; same remap |
| Control4 guideline | Meets the UI placement | Departure in placement, reason written down |

## 3. What Control4 expects with a Min On

M is the Min On, m = max(1, M). "Shown" is Control4's 0 to 100 level; "fan"
is the fan's `lightBrightness`.

| Thing | What Control4 sends or shows | What the fan gets | Source |
| --- | --- | --- | --- |
| The scale | Stays 0 to 100; 1 is the lowest lit level | m to 100 while on | VERIFIED-doc: LV2 notif `_14`, `_13`; C4-DIMPROPS (the curve is smoothed between Min On and Max On) |
| `LIGHT_BRIGHTNESS_CHANGED` | Shown level, the one the light confirmed (section 4.2 for which shown level) | — | VERIFIED-doc: LV2 notif `_10.2`; the shown scale from notif `_14` |
| `LIGHT_BRIGHTNESS_CHANGING` | Current and target as shown levels; `RATE` the planned time, unchanged | — | VERIFIED-doc: LV2 notif `_10.3` |
| Default On Brightness (the preset) | Kept and reported as a shown level, 1 to 100 | Its image: preset 100 is fan 100, preset 50 is fan round(m + 49 × (100 − m) / 99) | VERIFIED-doc: LV2 cmds `_6-SET_PRESET_LEVEL.md` (0 to 100 scale); that it is read on the shown scale ASSUMED (the proxy has only one scale) |
| Click and hold rates | Whole-range times on the shown scale: a change of d shown levels takes rate × d / 100, as without Min On. A Control4 dimmer's Hold Up is the time from off to its top | Steps closer together in fan levels; the same time | VERIFIED-doc: C4-DIM (Hold Up), LV2 notif `_4`, `_5`, `_9`, `_10` (via [`light-fades-sdk-research.md` §1.2](light-fades-sdk-research.md#12-two-kinds-of-rate)); that the time stays the same with Min On ASSUMED (the rates are defined on the shown scale, which Min On keeps) |
| `SET_BRIGHTNESS_TARGET`, `RAMP_TO_LEVEL`, `SET_LEVEL` | A shown target; `RATE` or `TIME` unchanged | The target's image; the fade's steps converted one by one | VERIFIED-doc: LV2 cmds `_1.5`; the rest follows from the scale |
| Advanced Lighting scenes (`reduced_als_support`) | Per-light shown levels as targets. Scene tracking reads the reported levels, so the report must equal the scene's level | The image of each | VERIFIED-doc: LV2 als `_1.3-REDUCEDALSSUPPORT.md`; BP "Brightness Target API" (wrong tracking from wrong reports); that tracking compares the level exactly ASSUMED |
| Navigator slider | A shown target with rate 0; 1 % is lit | Fan m at 1 % | VERIFIED-house: the slider sends rate 0 (via [`light-structure-research.md` §1.3](light-structure-research.md#13-commands-the-driver-handles-light-proxy-and-links)); the rest follows from the scale |
| A turn-on from off (tap, hold, fade) | Starts at 0 and rises | Off, then straight to m or above: lit at once. This is the fix for "starts late" | ASSUMED for Control4 dimmers (the remap puts 1 % at Min On); for this driver, section 4.6 |
| A hold down | Stops at 1 % | Fan m, never dark. Control4's own help has a held dimmer dim down to Min On | VERIFIED-doc: C4-DIM (the Cold Start example) |
| 0 | Off. `Light State` false, `IS_OFF` true | `lightOn` false; never remapped | VERIFIED-doc: LV2 vars (1000), cond |
| Keypad LEDs | On or off only | — | VERIFIED-doc: [`light-fades-sdk-research.md` §4](light-fades-sdk-research.md#4-what-navigators-and-programming-see-during-a-fade) (a link carries a state, no level) |
| Max On | Out of scope on the property route. Its own meaning is a cap below 100 for lamp life or to match a room (C4-DIM), not this problem. Later it is the same formula with 100 replaced by Max On | — | VERIFIED-doc: C4-DIM; the formula section 4 |
| Cold Start | Out: `cold_start` stays False; LED lamps do not need it | — | VERIFIED-code: `driver.xml`; HUE D13 |

## 4. The mapping

### 4.1 The two functions

With m = max(1, M) and M from 0 to 99, in whole numbers only (Lua 5.1 has no
integer division, so `math.floor` of exact quotients):

- **Shown to fan**, `fan_of(s)`: s = 0 is off. For s from 1 to 100:
  `m + floor(((s − 1) × (100 − m) × 2 + 99) / 198)`, which is
  m + (s − 1) × (100 − m) / 99 rounded half up.
- **Fan to shown**, `shown_of(f, hint)`: off is 0. With a hint h (below):
  when h ≥ 1 and `fan_of(h)` equals f, the answer is h. Otherwise a fan
  level below m is 1, and f from m to 100 is
  `1 + floor(((f − m) × 99 × 2 + (100 − m)) / (2 × (100 − m)))`, which is
  1 + (f − m) × 99 / (100 − m) rounded half up.
- **The hint** is the shown level of the change the light is making (a fade's
  or a jump's target), else the level the proxy was last told.

All values stay far below 2^53, so the products and the floor of the
quotient are exact in Lua's doubles.

### 4.2 Why the round trip is stable

- **Fan to shown and back is exact.** For every M and every fan level f from
  m to 100, `fan_of(shown_of(f))` is f. The reason: the forward slope
  (100 − m) / 99 is at most 1, so the inverse's rounding error of at most half
  a shown level moves the fan value by less than half a fan level.
- **Shown to fan and back cannot always be exact.** With M above 1 there are
  fewer fan levels than shown ones (76 for M = 25), so some neighbouring shown
  levels share a fan level. Without the hint, a scene at 37 % could come back
  as 36 %, so the scene would read as not active and the slider would twitch.
  With the hint, the level Control4 asked for is the level it hears, as long
  as the fan holds that level's image.
- **Checked** in Lua 5.1 for every M from 0 to 99 and every level: both ends
  (`fan_of(1)` = m, `fan_of(100)` = 100), both functions never decreasing,
  the exact fan round trip, the hint keeping every asked level, and the
  identity at M = 0 and 1. No failures.

### 4.3 A fan level below Min On

The Modern Forms app, the remote, the wall control or the fan's own timer can
set any level from 1 to 100. A level from 1 to m − 1 is shown as **1 %**:

- the light is on (`lightOn` true), and a light that is on never reads 0
  (VERIFIED-doc: LV2 vars, Light State is "not at the Off preset"; this
  driver's rule, [`v1-design.md` §4.5](v1-design.md#45-settled-reports-r1r9);
  HUE L9);
- 1 % is the nearest level Control4 has;
- the driver never moves the fan up to m by itself. Control4 is the source of
  truth for commands, but correcting a change made at the fan would fight the
  remote and the app (LF-D15's rule). A Control4 command at 1 % then sends m,
  which is a real change, so it goes out.

After a Control4 fade to off, the level written back while dark (LF-D10) is
the image of the starting level, at least m, so a later turn-on from the
remote or the app is lit too.

### 4.4 M = 0, M = 1, M = 99, and sample values

- **M = 0** is Control4's default (C4-DIM) and this feature's: no remap.
- **M = 1** is the `GET_SETUP` sample's value (LV2 cmds `_16.5`) and means
  the same: the formulas are the identity at m = 1. Treating 0 as 1 is what
  makes 0 safe (with 0 in the formula, 1 % would map to off).
- **M = 99** is the top of `MIN_ON`'s range (LV2 notif `_14`). Only fan 99
  and 100 remain: shown 1 to 50 is fan 99, shown 51 to 100 is fan 100. Fades
  become single steps. It works, but the Documentation tab should say that
  large values leave few steps.

| M | Fan levels used | fan_of(1) | fan_of(2) | fan_of(10) | fan_of(50) | fan_of(99) | shown_of(m) | shown_of(50) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 or 1 | 100 | 1 | 2 | 10 | 50 | 99 | 1 | 50 |
| 10 | 91 | 10 | 11 | 18 | 55 | 99 | 1 | 45 |
| 20 | 81 | 20 | 21 | 27 | 60 | 99 | 1 | 38 |
| 25 | 76 | 25 | 26 | 32 | 62 | 99 | 1 | 34 |
| 40 | 61 | 40 | 41 | 45 | 70 | 99 | 1 | 18 |
| 99 | 2 | 99 | 99 | 99 | 99 | 100 | 1 | 1 |

### 4.5 When Min On changes

- **The light does not move.** An edit is a setting, not a command. The next
  report shows the fan's level through the new M: the hint no longer matches,
  so the shown level is re-derived, and one CHANGED goes out at once if it
  differs from what the proxy was told (no request to the fan). What a lit
  Control4 dimmer does on such an edit is SILENT; hardware question 3 reads
  it, and the rule follows it if it differs.
- **A running fade keeps the M it started with**, as a rate changed mid-fade
  applies to the next fade (LF-D22). The fade record keeps its M.
- **Nothing new is stored** by the light: the property is the value (route
  B), or `device.lua` persists it like the other settings (route A).

### 4.6 Where the fade engine converts

The engine keeps running in shown levels, so everything that faces Control4
stays as it is. The conversion sits at the two crossings:

- **Every want** converts its level with `fan_of` (a jump, a fade's first
  level, each step, the target, the replay after a failure, the write-back).
- **Every read of the fan's state** converts with `shown_of` (where a change
  starts, what is reported, what `settled` and `idle` compare).
- **A step is wanted only when its fan level changed.** Today a step is
  skipped when its shown level equals the last; with M above 1, two shown
  levels can share a fan level, so the comparison moves to fan levels.
- **A fade from off is lit from its first request:** LF-D9's first level is
  a shown level of at least 1, whose image is at least m.
- `FADE_MIN_LEVELS` (3) and the times stay in shown levels: Control4's view of
  a change. With a large M a short fade may cover only one or two fan levels;
  the engine already handles a line whose steps barely move.

## 5. The Hue driver's decision

The Hue checklist marks Min On, Max On and Cold Start "Hue cannot" (HUE
L26) and gives the reason as departure D13: CLIP v2 has no trim or warm-up
setting, and the lamps are LED. The row adds that emulating Max On by
scaling is possible but not planned. Departure D5 says level 1 is the bulb's
lowest level (Hue's minimum dim level is fixed per bulb). The Hue light
dropped `min_max` from its capabilities in its 1.5 (HUE L85, turn-on D22).

| Hue's reason | Applies to the fan light? |
| --- | --- |
| No trim in the bridge's API | **The fact is the same** (the fan takes `lightBrightness` 1 to 100 and nothing else, VERIFIED-code: `src/modernforms_fan/fan/wire.lua`, `light_body`), **but it does not stop a driver remap**, which is exactly the "scaling" the Hue row calls possible |
| Hue's 1 % is already the bulb's lowest visible level | **No.** That is why Hue needs no remap: the bulb's own firmware puts 1 % where it lights. The owner's finding is that the fan's first levels are dark, so here 1 % is not lit |
| The lamps are LED | **Applies to Cold Start only**, which stays out. For Min On it argues the other way: Control4 names LED lamps as the reason Min On exists (C4-DIM) |
| `min_max` is deprecated | **Applies**, and is why route B is recommended |

## 6. Where a level crosses between Control4 and the fan

Line numbers are as of 2026-11-12 (VERIFIED-code). "Shown" and "fan" as in
section 3.

| File | Function or place | Crossing | With Min On |
| --- | --- | --- | --- |
| `src/modernforms_fan/fan/light.lua` | `percent` (L156), `level_command` (L568): `SET_LEVEL`, `RAMP_TO_LEVEL`, `SET_BRIGHTNESS_TARGET` | Control4 level in | Unchanged: stays shown |
| `light.lua` | `preset` (L399), `tap` (L600), `toggle` (L583), the `ON` and `OFF` handlers (L942, L943) | Control4 levels (preset, 0) | Unchanged |
| `light.lua` | `start_ramp` (L890, toward 100 or 1), `begin_ramp` (L904, `jump(1)` from off) | Control4 levels | Unchanged here; the 1 becomes m at the want |
| `light.lua` | `level_of` (L173, local) and every caller: `ramp_start` (L188), `confirmed_level` (L313), `start_level` (L319), `fade` (the start level, L526), `tap` (L612), `begin_ramp` (L908), `finish` (L772), `settled` (L1066), `idle` (L1110), `SYNCHRONIZE` (L976) | Fan state in, shown out | `shown_of(level, hint)`; needs M and the hint |
| `light.lua` | `jump` (L505) | Want out | `fan_of` |
| `light.lua` | `fade` (L546 to L549, LF-D9's first level), `restore = from` (L539) | Want out | `fan_of(first)`; `restore` stays shown and is converted at its want |
| `light.lua` | `tick` (L729 to L732) | Each step out | `fan_of`; skip a step whose fan level equals the last wanted one |
| `light.lua` | `target_fields` (L204), used by `finish_line` (L759) and `fade_failed` (L849); `finish_line`'s `f.last == f.to` (L748) | Target out | `fan_of(f.to)`; compare fan levels |
| `light.lua` | `restore_level` (L780 to L789): the want and `tonumber(st.level) == level` | Write-back out, and a fan compare | Both in fan levels |
| `light.lua` | `settled`: `level == f.last` (L1072), the own-step check; `level ~= self.told_level` (L1084) | Fan answer against what was wanted or told | Compare fan levels for the step; shown (via the hint) for the told level |
| `light.lua` | `report` (L431), `open_changing` (L443) | CHANGED and CHANGING out | Unchanged: callers pass shown levels |
| `light.lua` | `light.new` (L234), `debug` (L1206) | — | New: the M (set by the driver at late init and on an edit; a fade keeps its own); Dev State shows M and the fan level |
| `light.lua` or a new pure module | — | — | Proposed: `fan_of` and `shown_of` as a small pure module (for example `src/modernforms_fan/fan/levelmap.lua`) with its own spec, so the math is tested apart from the engine |
| `src/modernforms_fan/fan/model.lua` | `want` (L2162 to L2185, checks 1 to 100), the dark write and its skip (L910 to L967, L2247) | Fan levels throughout | Unchanged |
| `model.lua` | `status_view` (L642) | Fan level to the Status row | Feeds Decision 2 |
| `src/modernforms_fan/fan/wire.lua` | `light_body` (L128), `level_of` (L315, a 0 while on reads 1), `wire.state` (L404) | The fan's JSON, both ways | Unchanged |
| `src/modernforms_fan/fan/texts.lua` | `light_part` (L612 to L623), "light N %" | Status row | Decision 2: the shown level, with the fan level in brackets when they differ |
| `src/common/device.lua` | `SETTINGS` (L178), `report_setting` (L507), `save_setting` (L549) | Proxy settings in and out | Route A only: a `min_on` setting (`SET_MIN_ON_LEVEL` {`LEVEL`}, notify `MIN_ON`, 0 to 99, default 0), and `max_on` with it. Route B: unchanged. The file is shared with the Hue repo, so a change there is the coordinator's call |
| `src/modernforms_fan/driver.lua` | `device.new` settings list (L123); `light_mod.new` (L548); `refresh_status` (L202); `dispatch.properties` | Wiring | Route B: a handler for `Light_Min_On_(%)` and a read of `Properties["Light Min On (%)"]` at late init, both handing M to the light. Route A: `"min_on"` in the settings list |
| `src/modernforms_fan/driver.xml` | `<properties>`; `<capabilities>`, `min_max` (L469) | — | Route B: one `RANGED_INTEGER` row, 0 to 99, default 0. Route A: `min_max` True (static: a reboot) |
| `src/modernforms_fan/www/documentation.html`, `CHANGELOG.md`, `docs/composer-checklist.md` | — | — | The row, what it does, the high-value warning (section 4.4); the hardware checks of the open questions |
| `tests/spec/light_spec.lua`, `texts_spec.lua`, `fan_driver_spec.lua`, `drivers_spec.lua` (and `device_spec.lua` on route A) | — | — | Every crossing above at M = 0 (today's results unchanged), 1, 25 and 99 |

Not touched: `links.lua` (the light's links show on or off only),
`fanproxy.lua`, the Breeze modules, and `devcmds.lua` (its `Dev Proxy`
command enters through the proxy handlers, already shown levels).

## 7. Where the documents disagree or say nothing

- **The default Min On:** 0 in Control4's help (C4-DIM), 1 in the
  `GET_SETUP` sample (LV2 cmds `_16.5`). Both mean no remap (section 4.4).
- **Remap or skip:** `MIN_ON` and the Composer Pro help describe a remap
  where 1 % moves to Min On and the curve is spread out (LV2 notif `_14`;
  C4-DIMPROPS). Variable 1008 describes levels between Min and off being
  skipped (LV2 vars). This note follows the remap, which the two lighting
  pages agree on; a skip would leave a dead zone at the bottom of the slider.
- **Max On:** a click's ceiling that a hold can pass, in variable 1007 (LV2
  vars); an absolute cap that, unlike the preset, cannot be passed, in
  C4-DIM.
- **Ranges:** `SET_MIN_ON_LEVEL` takes 0 to 100 (LV2 cmds `_5`); `MIN_ON`
  carries 0 to 99 (notif `_14`). This note uses 0 to 99: at 100 the light
  would be on or off only and the inverse would divide by zero.
- **Page slips:** `SET_MAX_ON_LEVEL`'s page names `SET_MIN_ON_LEVEL`;
  `MIN_ON`'s parameter is called `int`; `COLD_START_LEVEL`'s parameter text
  is Min On's (LV2 cmds `_4`; notif `_14`, `_6`).
- **Raw brightness scales:** the target and CHANGING pages mention "Min and
  Max brightness capabilities" that let a driver use another scale (0 to 10,
  0 to 255); no such capability has a page (LV2 cmds `_1.5`, notif `_10.3`).
  Not used: a decimal level already showed as off on OS 3.4.2 (VERIFIED-house:
  HUE, via [`light-structure-research.md` §1.4](light-structure-research.md#14-notifications-the-driver-sends)).
- **SILENT:** what replaced `min_max`; whether Composer shows Range Levels for
  a third-party driver; whether the OS 3 proxy changes targets once it knows
  a Min On; what a lit Control4 dimmer does when Min On is edited; anything
  about Min On on OS 4.x.
