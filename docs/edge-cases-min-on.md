# Min On for the fan's light: the edge cases

> **Status (2026-11-13, #213).** Built in 1.8 (#195) by
> [`min-on-design.md`](min-on-design.md) (MO-D1 to MO-D15): M is the fan
> item's property `Light Min On (%)`, 0 to 99, default 0 (a driver
> property, not the proxy's Range Levels), mapped in `fan/light.lua` with
> this note's formulas, RO1's memory and the eight checks of section 1.4;
> MQ3 was answered with CM2, and MQ5 with the Status row of RP1. LC1's hint
> is one log line, not a Last Action line, and LC2's is left to the manual
> (MO-D13). The owner had it shipped without running MQ1 to MQ4, so the
> house's first lit level was not measured; the house fan's
> `Light Min On (%)` is 10 ([`status.md`](status.md)). The code line
> numbers are those of 2026-11-12.

> **Research (2026-11-12) for [issue #195](https://github.com/corytron/c4-modernforms-driver/issues/195)**,
> desk research only: nothing was sent to the fan, the controller, the dev
> server or any other device while writing it. The planned feature gives the
> fan's light (the light_v2 proxy) a **Min On** level M, 0 to 99, default 0.
> Control4's 1 to 100 % is spread over the fan's light levels M to 100, so
> 1 % in Control4 is the first level at which the LEDs light, and a fade, a
> hold or a tap from off starts where the light can be seen. The owner sees
> the light "start late" when it fades up from off. This note is the
> **lifecycle and behaviour side**: every corner case on both sides, with a
> decision for each. **Where M is set** (the proxy's Range Levels through
> `min_max`, `SET_MIN_ON_LEVEL` and `MIN_ON`, or a driver property) is the
> sibling note `docs/min-on-sdk-research.md`, written at the same time.
> Where it settles a Control4 fact this note marks ASSUMED, it wins. Every
> decision below holds whichever way M is set, unless the row says otherwise.

**The decisions in short.**

1. **One mapping, at the light's edges.** The model, the wire and the
   transport keep speaking the fan's levels. `fan/light.lua` converts a
   Control4 level to a fan level when it wants one, and a fan level to a
   Control4 level when it reports one. Off is always off, on both sides.
   M of 0 or 1 changes nothing (section 1).
2. **Control4 hears back what it asked for.** A fan level that is exactly
   the one the light last asked for is reported as the Control4 level that
   asked for it. Without that rule, with M = 20 a slider set to 4 % would
   read 3 % a moment later (section 1.3).
3. **A level set outside Control4 below M shows as 1 %**, on, never 0. The
   driver never raises it to M and never writes anything back (LF-D15).
4. **Times are measured over Control4's range.** A 3 s click rate takes 3 s
   whatever M is, and the Navigator's animation matches the light. A fade
   from off starts at a visible level, and a fade to off ends at M instead
   of spending its last part dark.
5. **The fade engine compares fan levels.** Several of its checks compare
   levels that are the same number today. With M above 1 they are not, and
   one of them could end a fade by itself (section 1.4).
6. **A change of M never touches the fan by itself**, with one exception
   the owner decides (MQ3): with the light on at a level Control4 set, the
   recommended answer keeps the Control4 level and moves the light, once,
   as a Control4 dimmer's trim would. A running fade keeps the M it started
   with.
7. **M belongs to the Control4 device.** It survives updates, restarts,
   reboots and a fan or light kit replaced through Use Selected Fan. It is
   never reset or guessed by the driver. When the fan or its light kit
   changes and M is above 0, the driver says once that M should be checked.
8. **A lost M falls back to 0**, which is today's behaviour. That is the
   safe direction, because the light then never comes on brighter than
   asked.
9. **Bad values are refused and the old value kept**, as the light's other
   settings are. 100 is refused too, since the mapping would divide by 0.
10. **The Status row shows the Control4 level**, with the fan's level beside
    it while M is above 0 ("light 40 % (fan 52)").

**Before building, check that a dead zone is the cause (MQ1, MQ2).** A 3 s
tap from off already writes 13 % to the fan while dark before it turns on
(INFERRED, section 0, MT12). A dead zone below 13 levels therefore cannot
make a 3 s tap fade start late. A hold from off, a Navigator ON to a low
preset, or a slow turn-on of the fan itself could.

**Decisions:** **Automatic** (the driver does it by itself), **Offered** (a
setting, the manual, a click, or a line telling the owner), **Forbidden**
(not without a click, or not at all where the row says so).

**Markers:**
- **VERIFIED-code** names a file and line in this repository, as read on
  2026-11-12. Paths are under `src/modernforms_fan/` unless named
  otherwise. Other agents are editing the checkout, so lines may move a
  little.
- **VERIFIED-doc** names an SDK file or a Control4 help page. Snap One's
  documents are paraphrased, never quoted.
- **MEASURED** is a measurement on the house, quoted from the note that
  recorded it.
- **INFERRED** is reasoning from the code, the documents or the arithmetic.
  The script behind section 1.2 was a throwaway; its results are in the
  table.
- **ASSUMED** has no source yet.
- **UNKNOWN** needs a check on the hardware.

Placeholders only: fan 10.0.2.151, controller 10.0.2.10, MAC
00:00:5e:00:53:01.

| Key | Source |
| --- | --- |
| LF | [`light-fades-design.md`](light-fades-design.md): the fade engine, LF-D1 to LF-D24 and the review fixes of section 11 |
| ECF | [`edge-cases-light-fades.md`](edge-cases-light-fades.md): the fan's facts FT1 to FT12, the cases FC, FF and FL, the probes FP0 to FP7 |
| V1D | [`v1-design.md`](v1-design.md): the state model (§4), the light ([§4.7](v1-design.md#47-the-light)), persistence ([§8](v1-design.md#8-persistence-and-restore)) |
| ECM | [`edge-cases-modernforms.md`](edge-cases-modernforms.md): rule 7 (Control4 is the source of truth), A1 to A12 (changes from outside), H1 to H5 (hardware replaced), S3, S10 |
| HUE-LG | The Hue project's lighting checklist, [`docs/c4-lighting-guidelines.md`](https://github.com/corytron/c4-hue-driver/blob/main/docs/c4-lighting-guidelines.md), rows L1 to L89 |
| BP, EX | `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md` and `_51-LIGHTV2EXTRAS.md` |
| LV2 | `~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/`: **cmds** `10_light_v2_commands/`, **notif** `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/`, **vars** `30_Light_v2_variables/` |
| FUND | `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/` |
| C4-DIM | Composer help, device settings for dimmers: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerhe_userguide/device_settings_for_dimmers.htm> (read 2026-11-12) |
| C4-DIMPROPS | Composer Pro help, dimmable light properties: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/set_dimmable_light_properties.htm> (read 2026-11-12) |

## 0. Facts the decisions rest on

| # | Fact | Status |
| --- | --- | --- |
| MT1 | The fan's light is `lightOn` plus `lightBrightness` 1 to 100. There is no level 0, and the level is kept while the light is off. A level written while off stays dark, and `lightOn` then lights the light at it. | VERIFIED: ECF FT1; MEASURED: ECF FT2 (K12) |
| MT2 | "On at N" from off is two requests: the level first, unless the fan keeps it already, then `{"lightOn":true}`. Both fields in one body would flash the old level. | VERIFIED-code: `fan/model.lua:964`, `fan/wire.lua:126-143` |
| MT3 | Today the light's levels are the fan's: `level_of` turns a fan state into the Control4 level unchanged (0 when off, 1 to 100 when on). | VERIFIED-code: `fan/light.lua:173-185` |
| MT4 | Only `fan/wire.lua`, `fan/model.lua`, `fan/texts.lua`, `fan/light.lua` and the dev-only `fan/devcmds.lua` read the light's level. Breeze, the links, the LED hub and the follower never do. | VERIFIED-code: a search of `src/modernforms_fan/` for `light_on`, `level` and `lightBrightness` |
| MT5 | The light's keypad LEDs follow on and off only, never the level. | VERIFIED-code: `src/common/device.lua:483-492`, `fan/light.lua:990-1003` |
| MT6 | Control4's Min On is a remap: 1 % becomes the level at which the light is on, and the 0 to 100 % range stays as it is. The usable minimum of an LED lamp varies with the lamp and its age. The value is 0 to 99. | VERIFIED-doc: LV2 notif `_14-MINON.md` |
| MT7 | The documents disagree on the range and the meaning. `SET_MIN_ON_LEVEL` takes 0 to 100, while `MIN_ON` says 0 to 99. The Min Brightness variable (1008) describes levels skipped between Min and off rather than a remap. The SDK note settles which applies. | VERIFIED-doc: LV2 cmds `_5-SET_MIN_ON_LEVEL.md`, notif `_14-MINON.md`, vars `_0-HEADER.md` |
| MT8 | A Control4 dimmer's Min On defaults to 0. The help page's example is a lamp that shows nothing until about 20 %, set a little above that for a clean turn-on. Its Hold Up time is the time from off to Max On. Range Levels smooth the dimming curve between the minimum and the maximum. | VERIFIED-doc: C4-DIM "Range Levels", "Hold Ramp Rates"; C4-DIMPROPS "Range Levels" |
| MT9 | The light's settings (preset, click and hold rates, Default Brightness Rate) are persisted per device and loaded at late init, before the model starts and before any property handler runs. A persisted value out of range is dropped with one warning. A refused edit keeps the old value and tells the proxy that value again. | VERIFIED-code: `src/common/device.lua:516-563`; `driver.lua:1286`, `:1292`, `:1298` |
| MT10 | Persisted data lives in the project file. Ramp rates are given as an example of data that belongs there, and a light's on state as data that does not. Drivers should not write it often. | VERIFIED-doc: FUND `24_persisting_driver_data/_1-PERSISTINGDRIVERDATA.md` |
| MT11 | After a restore onto a new controller the store may be empty. The light's keypad settings then fall back to their defaults, while properties come back from the backup. | ASSUMED, as V1D §8 records it ("a known limit, LSR Q6") |
| MT12 | A tap from off fades over click up × preset / 100. LF-D9's first, dark level is preset × 400 / that time, which is 13 % for every preset of 34 % or more at the 3 s default. A preset under 34 % makes the fade shorter than 1 s, so it is one request straight to the preset. A hold from off turns on at 1 % and ramps after 600 ms. A Navigator ON at the house's 3 s Default Brightness Rate starts at 13 % of the preset. | INFERRED from `fan/light.lua:546`, `:620-631`, `:918`, LF-D4, LF-D5, LF-D9; the 3 s rate from [`status.md`](status.md) |
| MT13 | Two of three turn-ons from the VM were answered only after 1.4 to 1.8 s. Whether the light fades in by itself is unknown (U4). | MEASURED: ECF FT4; UNKNOWN: ECF U4 |
| MT14 | Nothing of the fades has been seen on the hardware yet: 1.5 shipped without its probes. | VERIFIED: [`status.md`](status.md) |

## 1. The mapping, and where it lives

### 1.1 The formulas

With `lo = max(1, M)`:

- **Control4 to fan** (a level the light wants): 0 stays off. A level s
  from 1 to 100 becomes `round(lo + (s − 1) × (100 − lo) / 99)`.
- **Fan to Control4** (a level the light reports): off stays 0. A fan
  level f from lo to 100 becomes `round(1 + (f − lo) × 99 / (100 − lo))`.
  A fan level below lo, with the light on, becomes 1.

`round` is the driver's usual half-up rounding (`math.floor(x + 0.5)`).
M = 0 and M = 1 both give today's levels unchanged. Both lines are straight,
so a straight fade in Control4's levels is a straight fade in the fan's
(INFERRED). This is the same shape as the warm-dim line Snap One describes,
which also runs from 1 % to 100 % (VERIFIED-doc: BP "Warm Dim").

### 1.2 What the rounding does (checked for every M from 0 to 99)

| M | Fan levels used | Control4 1 % and 50 % on the fan | Control4 levels that do not come back unchanged | Worst error |
| --- | --- | --- | --- | --- |
| 0 or 1 | 100 | 1, 50 | 0 | 0 |
| 5 | 96 | 5, 52 | 4 | 1 point |
| 10 | 91 | 10, 55 | 9 | 1 point |
| 20 | 81 | 20, 60 | 19 | 1 point |
| 30 | 71 | 30, 65 | 29 | 1 point |
| 50 | 51 | 50, 75 | 49 | 1 point |
| 80 | 21 | 80, 90 | 79 | 2 points |
| 99 | 2 | 99, 99 | 98 | 49 points |

- **Fan → Control4 → fan always comes back unchanged**, for every M and
  every fan level from lo to 100. Different fan levels also always give
  different Control4 levels. So a level set in the Modern Forms app,
  reported to Control4 and sent back by a scene or a slider, lands on the
  same fan level (INFERRED, checked exhaustively).
- **Control4 → fan → Control4 does not.** With M = 20, 19 of the 100
  Control4 levels share a fan level with a neighbour. Their reverse mapping
  then gives the neighbour, one point off: 4 % becomes fan 22, which maps
  back to 3 %. The error is 1 point for every M up to 67, and 2 points from
  68. Section 1.3 fixes this.
- **Neighbouring Control4 levels share a fan level** (19 pairs at M = 20).
  A fade that wants every Control4 level would then want the same fan level
  twice. Because the model sends a wanted level even when it equals the
  confirmed one (V1D §4.3), that wastes a request. Section 1.4 fixes this.

### 1.3 Round trips: Control4 hears back what it asked for

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| RO1 | **A slider or programming sets 4 %** with M = 20: the fan gets 22, which maps back to 3 %. With M = 50, 2 % becomes fan 51, which maps back to 3 %. | No mapping, so no error | The light keeps the last Control4 level it wanted and the fan level that went with it. A confirmed fan level equal to that one is reported as that Control4 level. Any other fan level is mapped back. The memory is cleared when M changes. | Automatic |
| RO2 | **A Navigator slider** let go at a level | Sticks at the level chosen (HUE-LG L55) | Sticks, by RO1. Without RO1 the slider would jump a point after the CHANGED | Automatic |
| RO3 | **Scene tracking** (Advanced Lighting scenes compare the light's level with the scene's) | Exact | Exact while RO1's memory holds. That the agent compares exact levels is ASSUMED | Automatic |
| RO4 | **After a restart** RO1's memory is gone. The first contact reports the mapped-back level, at most 1 point from the one Control4 set while M ≤ 67, and 2 points above | — | Accept the one correction at the first contact (R6). Do not persist the pair: it would be a write on every change, which FUND 24 advises against (MT10), and nothing about a light's changes is stored today (LF-D21) | Automatic; Forbidden: persisting the level (MQ6) |
| RO5 | **A level from outside, sent back by Control4** (a scene captured from the current level, a programmed "set to the current level") | Same level | Same fan level, by section 1.2's first finding | Automatic |

An option for the contract, not needed: where two Control4 levels share a
fan level, the reverse mapping could prefer a multiple of 5. Then the levels
people program (10, 25, 50, 75) would also come back unchanged after a
restart.

### 1.4 Where the conversion goes, and the checks that mix the two units

The model's comparisons are all about the fan. They cover the settle
window, "the fan keeps that level already", "the fan did not take light
level" and the LF-D10 write-back skip (`fan/model.lua:964`, `:2247`).
Moving the mapping into the model would round twice. So the model, the
wire, the transport and `Dev Light Steps` stay in fan levels. The light
converts at its two edges: what it wants, and what it reports. `fan/texts.lua`
gets M for the Status row.

Today both units are the same number, which hides the checks in
`fan/light.lua` that compare them. With M above 1, each one needs the
right unit:

| Line | What it compares today | It must compare | Why |
| --- | --- | --- | --- |
| `:527` | The distance of a fade, against `FADE_MIN_LEVELS` | Fan levels | 3 Control4 levels may be 1 fan level; a fade that cannot show is one request (LF-D5) |
| `:546` | The first, dark level of a fade from off | Control4 levels, then mapped | Keeps the light in step with the Navigator's animation |
| `:626` | "At the preset, within 1 point" | The fan's level against the preset's fan level | After a restart (RO4) the shown level may be off by 2 at M = 80, and a tap would send a useless request |
| `:730` | "Want the line's level only when it changed" | Fan levels | Otherwise the same fan level is wanted twice (section 1.2) |
| `:748` | "The last step already was the target" | Fan levels | As `:730` |
| `:785` | The LF-D10 write-back against the level the fan keeps | Fan levels, with the raw starting level kept (TO4) | `restore` holds a Control4 level (`:539`) and `st.level` a fan level |
| `:1072` | "This answer shows the level the fade set" | Fan levels | **Otherwise a fade can end by itself.** A read that shows the fade's own step maps back to a neighbour of the level wanted, and the fade takes it for a change from outside (LF-D15) |
| `:1084` | The level against the one the proxy last heard | Control4 levels | That is what the proxy heard; it stops a second CHANGED for the same Control4 level (OX6) |

## 2. Levels set from outside

The Modern Forms app, the remote, the wall control, the fan's own timers,
Away mode and the cloud integrations all change the fan's level without
Control4 (ECM A1 to A11). Control4 is the source of truth: nothing set
elsewhere is ever corrected (ECM rule 7, LF-D15).

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| OX1 | **The light is on at a fan level below M** | Reported as that level | Reported as 1 %, on. Never 0 while the light is on: the proxy's Light State means "not at the Off preset" (VERIFIED-doc: LV2 vars `_0-HEADER.md`; HUE-LG L9), and Navigators, programming conditions and scene tracking would take an on light for off | Automatic; Forbidden: raising it to M, reporting 0, writing anything |
| OX2 | **At exactly M** | As that level | 1 % | Automatic |
| OX3 | **Above M** | As that level | Mapped back (section 1.1); distinct fan levels give distinct Control4 levels | Automatic |
| OX4 | **Off** | 0 | 0; M plays no part | Automatic |
| OX5 | **Turned on from outside at a kept level below M** (the remote's or the app's own on, ECM A9; or the LF-D10 write-back of a level the app had set) | Lights at the kept level | Lights at the kept level, shown as 1 %. The driver does not lift it | Automatic; Forbidden: lifting it to M |
| OX6 | **A held remote steps through several levels below M** | One CHANGED per answer that shows a new level | Every one of them is 1 %, so the proxy hears 1 % once and programming fires once (`fan/light.lua:1084`) | Automatic |
| OX7 | **The fan's light timer, sleep timer or Away mode** | Reported (ECM A5, A7) | Off is off. An on by Away mode is OX5 | Automatic |
| OX8 | **A change from outside during a fade** | LF-D15 ends the fade | Unchanged, provided `:1072` compares fan levels (section 1.4) | Automatic |
| OX9 | **The level in the Modern Forms app no longer matches Control4's** once M is above 0. For example, Control4 shows 40 % while the app shows 52 | Same number | Expected. The manual says Control4's levels are spread over the fan's from Min On up | Offered (the manual) |

## 3. Changing M

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| CM1 | **M changed while the light is off** | — | Nothing is sent. The next turn-on from Control4 uses the new M. The dark level the fan keeps is left alone | Automatic |
| CM2 | **M changed while the light is on at a level Control4 set** (RO1's memory matches the fan) | — | Recommended (MQ3): the Control4 level stays and the light moves to its new fan level, as one request with no fade and no CHANGED. A Control4 dimmer's trim acts in its own hardware, so its output would change while its percent stays (INFERRED from MT6). The owner then sees the new 1 % at once while tuning. The alternative is CM3's rule | Automatic on the owner's edit, the edit being the click (MQ3) |
| CM3 | **M changed while the light is on at a level from outside** | — | The fan is not touched. The proxy hears the new Control4 level for the fan's level, in one CHANGED, so a level-changed event fires once | Automatic; Forbidden: moving a level set from outside |
| CM4 | **M raised above the light's level** | — | From outside: CM3, shown as 1 %. Set by Control4: CM2, the light goes up | As CM2, CM3 |
| CM5 | **M set back to 0** | — | Today's levels again. CM2 or CM3 applies, with the levels unchanged from then on | As CM2, CM3 |
| CM6 | **M changed during a fade, a hold or a scene ramp** | — | The fade keeps the M it started with, so its line never jumps half way, as LF-D22 does for a rate. When it ends, CM2 or CM3 applies once | Automatic |
| CM7 | **The value arrives at load**: late init, the replay of the properties, a project load or a restore, or the proxy repeating its stored value | — | Taken without sending anything to the fan. The first contact reports with it (MT9: it is known before the model starts). It counts as a change only when it differs from the value in use | Automatic; Forbidden: a write at start (ECM S10) |
| CM8 | **Several changes in a row** (a slider or the Windows session typing) | — | Each one is CM1 to CM3. The model keeps only the newest wanted level, so a burst costs at most one request in flight and one more (V1D §4.3) | Automatic |
| CM9 | **M changed while the fan is offline, rebooting or foreign** | — | Taken and kept. Nothing is sent. The contact that brings the fan back reports with the new M | Automatic |

## 4. Turning on and off

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| TO1 | **A fade from off, with a kept level below M** | LF-D9 writes the first level dark, then `lightOn` | Unchanged. The dark level is now at or above M, so the light comes on visible. It never lights at the kept level first, because the level goes before `lightOn` (MT2) | Automatic |
| TO2 | **A turn-on too short to fade** (the 750 ms default rate, a rate of 0, a preset under 34 % from a tap) | One request to the target | The same, at the target's fan level, which is at least M | Automatic |
| TO3 | **A fade to off** | Steps down to 1, then off. Below the first lit level the last part of the fade is dark, so the light "ends early" (INFERRED) | Steps down to 1 %, which is fan level M, then off. The light is visible until the off | Automatic |
| TO4 | **LF-D10's write-back** after a fade to off | Writes back the starting level, a Control4 level that is also the fan's | Writes back the **raw fan level** the fade started from, not a mapped one. That restores a level the app set below M exactly, and the skip test of `:785` compares like with like | Automatic |
| TO5 | **A hold from off** | On at 1 %, then the ramp after 600 ms (`DIM_AFTER_ON_MS`) | On at 1 %, which is M and visible at once, then the ramp | Automatic |
| TO6 | **A hold down, or a scene ramp down** | Toward 1 | Toward 1 %, so it stops at M and never goes below, as a Control4 dimmer stops at its Min On (ASSUMED) | Automatic |
| TO7 | **A top tap from off** | Fades to the preset, its first dark level 13 % (MT12) | The first dark level is 13 % mapped (fan 30 at M = 20). The first visible step is then above M | Automatic |
| TO8 | **Toggle, the command or a tap** | By the fade's target or the shown state (LF-D18) | Unchanged: on and off do not depend on M | Automatic |
| TO9 | **A stop during a fade** (a tap, a release, a stop command) | CHANGED with the level the fan confirmed (LF-D13) | The same, mapped back. RO1's memory holds the last step wanted, so a stop between steps may show a level one point from that step's. Nobody can see that | Automatic |
| TO10 | **A fade up from a level below M** (set from outside) | Starts from that level | Starts from M. Its first step leaves the dead zone at once, as the Control4 level it starts from is 1 % | Automatic |

## 5. Presets and other levels

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| PL1 | **Default On Brightness** (the preset, 1 to 100) | Sent as the fan level | It is a Control4 level and is mapped like any other. A change of M never rescales it | Automatic; Forbidden: rescaling the preset when M changes |
| PL2 | **Brightness On Mode Previous** | Not declared: `supports_default_on` and no `brightness_on_mode_*` (VERIFIED-code: `driver.xml:480`); ON goes to the preset (`fan/light.lua:942`) | Not applicable. If it is added later, "previous" should be the raw fan level, as TO4 | — |
| PL3 | **Scenes** (Advanced Lighting, `reduced_als_support`) store Control4 levels | Sent as fan levels | Mapped. After a change of M the same scene gives another fan level, as on a Control4 dimmer whose trim was changed (INFERRED from MT6). Tracking: RO3 | Automatic; Forbidden: rewriting stored scene levels |
| PL4 | **`SET_BRIGHTNESS_TARGET` with a rate, `RAMP_TO_LEVEL` with a time** | A fade over that time (LF-D2) | The same time; the levels are mapped | Automatic |
| PL5 | **The Navigator slider** (rate 0) | One request | One request to the mapped level; RO2 | Automatic |
| PL6 | **Programming: Set Level 1 %** | Fan level 1 | Fan level M, the first lit level. This is the point of the feature | Automatic |
| PL7 | **Level 0** | Off | Off, never M | Automatic |
| PL8 | **A level that is a decimal** (0.4 %) | 1 %, never off (`fan/light.lua:162-164`) | 1 %, so M | Automatic |
| PL9 | **A top tap at the preset** | Nothing sent (`:626`) | The same test, in fan levels (section 1.4) | Automatic |
| PL10 | **`SYNCHRONIZE`** | Reports the confirmed level (`:967-980`) | Reports it mapped back, with RO1 | Automatic |

## 6. Rates

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| RT1 | **Is a fade's time measured over Control4's range or the fan's?** | One range | **Control4's range.** Click and hold rates are speeds over 1 to 100 %, so a full hold takes 5 s and a 3 s tap from off takes 3 s whatever M is. `RATE` and `TIME` stay durations (LF-D2). Control4 keeps its 0 to 100 % with Min On set (MT6), and its Hold Up runs from off to the top of the range (MT8). The `CHANGING` the Navigator animates carries the same time, so the tile and the light stay in step | Automatic |
| RT2 | **The speed on the fan.** At M = 50 the light moves half as many fan levels a second as at M = 0 | — | Expected: the same time now covers fewer, all visible, levels. The manual says so | Offered (the manual) |
| RT3 | **Fewer requests at a high M** | — | One request per fan level at most (`:730` in fan levels). A fade at M = 80 has only 21 levels to show | Automatic |
| RT4 | **`FADE_MIN_LEVELS` and `FADE_MIN_MS`** | Control4 levels, which are the fan's | Counted in fan levels (section 1.4). The time limit is unchanged | Automatic |
| RT5 | **`FIRST_STEP_MS`** (LF-D9) | 400 ms of the line, dark | Unchanged. With M set, a fade from off could start at 1 % instead, since 1 % is now visible. That is a later tuning for the probes, not part of this feature | Automatic (unchanged) |
| RT6 | **The fade gap and the budget** (LF-D7, LF-D8) | — | Unchanged | Automatic |

## 7. Keypad LEDs and Breeze

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| LB1 | **The light's links 200 to 202** | Follow on and off (MT5) | Unchanged. A light on below M is on (OX1), so its LEDs show on | Automatic |
| LB2 | **Breeze and its gusts** | Move the fan's speed only, never the light (ECF FF14, BZ8 of [`breeze-design.md`](breeze-design.md)) | Nothing | — |
| LB3 | **`Breeze LED Night Brightness (%)`** | Dims keypad LEDs, not the fan's light (`driver.lua:846`) | No relation to Min On. The manual should not let the two be confused | — |
| LB4 | **The speed LEDs, the chase, the Breeze fan device** | No light involved (`fan/speedleds.lua`, `fan/breezeleds.lua`; `modernforms_breeze_fan.c4z` has no light proxy) | Nothing | — |

## 8. Device life cycle

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| LC1 | **The fan replaced by another fan** (Use Selected Fan, ECM H1) | The light's settings stay: the only persisted values the driver deletes are `mf_migration` and settings out of range (VERIFIED-code: `driver.lua:1291`, `src/common/device.lua:538`) | M stays. It belongs to the Control4 device, as the preset and the rates do. When M is above 0, Use Selected Fan's Last Action, or one log line, says "Min On is 20; check it for this light" | Automatic: kept; Offered: the line; Forbidden: resetting or guessing M |
| LC2 | **Another light kit** (`lightType` changes, ECM H3, H5) | A warning names the change (`fan/model.lua:747-755`) and Fan Model shows the kit | M stays. While M is above 0, the same warning adds that Min On should be checked | Automatic: kept; Offered: the hint |
| LC3 | **A firmware update** (ECM F1). The `dimTableId` of the device information may name a dimming curve (ECF FT11) | Firmware row updated | M stays. The manual says to check it after an update | Offered (the manual) |
| LC4 | **The driver updated in place** | Settings and properties survive (V1D §8) | M survives. The first build with the feature starts at M = 0, so the install changes nothing until the owner sets M. If the SDK note puts M in the proxy's Range Levels through a static capability, that install needs the owner's controller reboot (`CLAUDE.md`) | Automatic |
| LC5 | **A rollback to a build without Min On** | — | M is ignored and kept. A later update brings it back | Automatic |
| LC6 | **A project restore** onto the same controller, or onto a new one | Properties from the backup; on a new controller the light's settings may fall back to defaults (MT11) | M comes back from the backup, or falls back to 0, today's behaviour, which never makes the light brighter than asked. If M lives with the proxy, the driver must not overwrite a value the proxy brought back with its own default. The SDK note says how | Automatic; Forbidden: a guessed M |
| LC7 | **A controller reboot, a Director restart** | Settings loaded before the first contact (MT9) | The same for M, so the first CHANGED already uses it (RO4) | Automatic |
| LC8 | **A restart during a fade** | Nothing of a fade is stored (LF-D21) | Unchanged | Forbidden: resuming the fade |
| LC9 | **A Gen 1/2 fan against a Gen 3** | The same light fields (ECF FT1); everything measured is on the house's Gen 3 | The same mapping. Whether Gen 1/2 kits have a dead zone is unknown; the default of 0 leaves them as they are | Automatic |
| LC10 | **A fan without a light kit** (`has_light` false) | Light commands refused, light offline (`fan/light.lua:409-415`) | M is kept and does nothing. The manual says it applies to the light only | Automatic |
| LC11 | **A second fan device in the project** | Each device persists its own settings (MT10) | Each has its own M | Automatic |
| LC12 | **The fan's address followed, or typed** | — | M unaffected: the follower touches no setting | Automatic |
| LC13 | **The device deleted and re-added** | Everything is lost (V1D §8) | M too; the manual already says never to do it | — |

## 9. Reporting

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| RP1 | **The Status row** shows the fan's level as "light 40 %" (`fan/texts.lua:612-624`, `:666`) | Fan level = Control4 level | The Control4 level, which every Navigator shows, then the fan's while M is above 0: "light 40 % (fan 52)", and below M "light 1 % (fan 5, below Min On)". The longest such row is 71 characters | Automatic (MQ5) |
| RP2 | **Last Action** | The light's settings write none | A change of M writes none either. LC1 and LC2 may write their hint | Offered (LC1, LC2) |
| RP3 | **The log** | Rate commands at debug (LF-D20) | One always-on line per change of M: "Min On 20: Control4's 1 % is the fan's level 20". Every light debug line that names a level says which: "40 %" for Control4, "fan level 52" for the fan. The model's lines are in fan levels already | Automatic |
| RP4 | **The Documentation tab** | — | In the driver's own words, using Control4's name "Min On": what it is, how to find it (MQ1's method, at Min On 0, then a little above the first lit level, as C4-DIM suggests), that 0 is off and 1 % is Min On, that times are over Control4's range (RT2), that outside levels below Min On show as 1 % (OX1), and to check it after a new fan, light kit or firmware (LC1 to LC3) | Offered (the manual) |
| RP5 | **Programming events** | One per real change | One per real change of the Control4 level. CM3 is one | Automatic |

## 10. Bad values

| # | Case | Proposal | Decision |
| --- | --- | --- | --- |
| BV1 | **Not a number** (empty, text, `nan`, `inf`) | Refused, the old value kept and shown again, one warning (MT9's rule) | Automatic |
| BV2 | **Negative** | Refused, as BV1 | Automatic |
| BV3 | **100 or more** | Refused: at 100 the mapping divides by 0. Control4's own `MIN_ON` stops at 99 (MT7) | Automatic |
| BV4 | **A decimal** (20.5) | Rounded half up to a whole level (21), then range-checked, then kept and shown as kept | Automatic |
| BV5 | **A persisted value out of range or not a number** | Dropped at load with one warning; M is 0 (MT9's rule) | Automatic |
| BV6 | **M above the preset**, or near 99 | Not an error: the preset is a Control4 level and maps above M. Near 99 the light has only two levels left (section 1.2); the manual warns | Offered (the manual) |

## 11. Control4 guidelines this touches

The rows are HUE-LG's; the contract's own "Control4 guidelines" section
should cite them.

| Row | How Min On meets it |
| --- | --- |
| L26 Min On trims | Emulated by the mapping. Hue cannot do it; this fan can |
| L9 A light that is on never reads as off | OX1: on below M is 1 % |
| L14, L15 Rates over the whole range | RT1 |
| L17 The top tap goes to the preset whatever the level | PL1, PL9 |
| L43 A hold from off ramps up from the bottom | TO5, visible from the first moment |
| L53 LEDs show the real state, changes from outside included | LB1, OX1 |
| L55 Slider moves stick | RO2 |
| L62 Advanced Lighting scenes drive the light with targets | PL3, RO3 |
| L83 Settings persist and survive updates; a bad one is dropped | LC4, LC7, BV5 |

## 12. For the contract

- The two formulas of section 1.1, RO1's memory, and M of 0 or 1 as no
  change.
- Conversion in `fan/light.lua` only, plus M for `fan/texts.lua`. The model,
  wire, transport and dev commands stay in fan levels.
- The eight comparisons of section 1.4, each with a spec that fails today's
  code at M = 20. The `:1072` one first, since it could end a fade by
  itself.
- The fade record keeps fan levels and the M it started with (CM6). Its
  LF-D10 restore is the raw fan level (TO4). A start below M is lifted to M
  (TO10).
- A `light:set_min_on(M, why)` entry point that does CM1 to CM9, with
  nothing sent at load (CM7).
- The refusals and rounding of section 10, and the persistence of MT9.
- The texts of RP1, RP3 and RP4, and the hints of LC1 and LC2.

## 13. Open questions (recommended answer first)

| # | Question | Recommended | Cheap way to answer |
| --- | --- | --- | --- |
| MQ1 | **Is a dead zone the cause, and where does it end?** A 3 s tap from off already starts at 13 % (MT12), so a dead zone of under 13 levels cannot explain a late tap fade. On the house, taps kept their old rates until the controller reboot that 1.5 asked for ([`status.md`](status.md)) | Find the first lit level before building. If it is under 13, find out which input the owner used | With the dev loop (`--dev` build, [`dev-loop.md`](dev-loop.md)) and the owner watching: `Dev Light Steps FROM=1 TO=20 STEP=1 BACK=yes`, ECF FP2's low range, about 15 s. It speaks fan levels, so M plays no part. The owner names the first level that lights and says whether the late start was a tap, a hold or a Navigator ON |
| MQ2 | **Does the fan's own turn-on lag or fade in** (MT13, U4)? Min On does not help with that | Check it with MQ1 | Part of ECF FP4, with no fade in the way: from off, `Dev Proxy BINDING=5002 COMMAND=SET_BRIGHTNESS_TARGET LIGHT_BRIGHTNESS_TARGET=80 RATE=0`, then the same with `LIGHT_BRIGHTNESS_TARGET=0`, twice, the owner watching, about 20 s. The log's answer times show a slow `lightOn` |
| MQ3 | **When M changes with the light on at a level Control4 set**, should the light move so the Control4 level stays (CM2), or stay so the Control4 level changes (CM3's rule for everything)? | Move, once, with no fade | The Windows session sets a Control4 dimmer on the house (`status.md` mentions an outlet dimmer) to 1 %, changes its Min On in Composer, and reads the Navigator's level while the owner watches the lamp. Then it puts both back. Under a minute |
| MQ4 | **Does a Control4 dimmer keep its click and hold times over its percent range** with Min On set (RT1)? | Yes, Control4's range | On the same dimmer: Min On at 50, a hold from off, timed against its Hold Ramp Up rate. Then Min On back |
| MQ5 | **The Status row with both levels** while M is above 0 (RP1)? | Yes | The owner's word |
| MQ6 | **A one-point correction of the shown level after a restart** (RO4), rather than persisting the last level? | Accept it | The owner's word |
| MQ7 | **Allow M up to 99**, as Control4 does, or cap it lower? | 99, with the manual's warning (BV6) | The owner's word |
