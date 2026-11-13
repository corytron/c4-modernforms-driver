# Breeze: the fan side

> **Status (2026-11-13, #213).** The house checks BR0 to BR8 never ran: the
> owner chose to take best guesses instead (BZ5 in
> [`breeze-design.md`](breeze-design.md)), and 1.2 (#111) was built on
> them. The fields, the bodies and the field reports here stand. In 1.3
> (#121) the owner reported what his fan does: it runs **either in fan mode
> or in Breeze mode, never both**, and Breeze's three strengths are
> unrelated to the six fan speeds (as the field reports of section 2
> said). So a fan-mode command ends Breeze, the driver's Off stops the fan
> and clears a stored Breeze, and Breeze from a stopped fan sets `wind`
> before the fan starts ([`breeze-design.md`](breeze-design.md) section 11,
> BF-D1 to BF-D6). The file and line citations of this repository's code
> are those of the `feat/breeze-111` branch on 2026-11-07; the code has
> moved since.

Research for [issue #111](https://github.com/corytron/c4-modernforms-driver/issues/111),
written 2026-11-07: what a Modern Forms fan's Breeze mode is, which fields
carry it, what the fan does and reports, how other integrations expose it,
which body the driver would send, and what only the house fan can tell.
Desk research: public code, public issues, the vendor's remote and wall
control sheets, and the house facts already in the repository (M0). Nothing
was sent to any fan. The Control4 side (proxy, programming, keypads,
Navigators) is the other research note of #111, `docs/edge-cases-breeze.md`.
The fan's interface in general is
[`modernforms-api-research.md`](modernforms-api-research.md) (MFR), the
driver's contract [`v1-design.md`](v1-design.md).

**Status key.** **VERIFIED** names its source: a file and line at the commit
in [Sources](#sources), a URL, or the house's M0 facts. **ASSUMED** names
why; as in MFR, a fact known only from one user's report about their own
fan (a *field report*) counts as ASSUMED, with the report named. WAC's
documents are cited and paraphrased, never copied. Placeholders only: fan
`10.0.2.151`, MAC `00:00:5e:00:53:01`, client id `MF_00005E005301`.

## Summary

1. **Two fields, both in every state answer of a fan that has Breeze:**
   `wind` (boolean, Breeze on or off) and `windSpeed` (integer 1 to 3, its
   strength). Gen 3 only; the `wind` key's presence is the capability, as
   the driver already treats it (`has_wind`, `mf_wind`). The house fan has
   both: `wind` false, `windSpeed` 2 (VERIFIED: M0).
2. **What it does:** the fan holds a base speed and adds randomly timed
   gusts. `windSpeed` sets the strength of both. Every source treats that
   strength as its own 1 to 3 scale, apart from `fanSpeed` 1 to 6, so
   "breeze at any set speed" may not be what the fan does (ASSUMED; BR1,
   BR5 below).
3. **Writing it is simple and reported to work:** `{"wind":true}`,
   `{"wind":false}`, `{"windSpeed":N}`, `{"wind":true,"windSpeed":N}`, with
   integers. The answer is the full state, showing the new values (field
   report on a real Gen 3 fan, AIO-ISS #272). The vendor app adds
   `"fanOn":true` and sends `windSpeed` as a string (field report,
   AIO-ISS #88); the driver should send an integer.
4. **Not known, and decisive for the design:** whether `{"wind":true}` alone
   starts a fan that is off; whether `fanSpeed` moves with the gusts (MFR's
   H6); whether a speed command ends Breeze; whether `fanDirection` reads
   forward during Breeze (the remote sheets say Breeze always turns the fan
   forward); whether turning the fan off clears `wind` (Home Assistant says
   no, unmeasured).
5. **How others expose it:** Home Assistant as a fan preset `normal` /
   `breeze` plus a separate "Breeze intensity" number 1 to 3; openHAB as a
   switch plus a 1 to 3 level; Homey as an on/off capability with flow
   cards and no strength; the Homebridge plugins not at all.
6. **The driver's path can carry it** as a fourth command group, `breeze`
   (`wind`, `wind_speed`), after fan and direction. Today `wire.body`
   refuses it, and so do the dev loop's `Dev Request` and
   `tools/mf_probe.py`.
7. **Risk for the settle window and the poll:** if `fanSpeed` follows the
   gusts, every poll during Breeze is an "outside" change that re-opens the
   20 s fast window, so the driver would poll every 2 s for as long as
   Breeze runs, and keypad LEDs and the proxy's speed events would follow
   each gust. A breeze command whose answer moves `fanOn`, `fanSpeed` or
   `fanDirection` would also be reported as made outside Control4.
8. **House checks BR0 to BR7**, each under a minute, need a VM-side breeze
   check in `tools/mf_probe.py` (or the feature's own dev build); nothing
   goes into the shipped driver.

## Sources

| Key | What | Where, version |
| --- | --- | --- |
| AIO | `aiomodernforms` (MIT): `aiomodernforms/const.py`, `models.py`, `modernforms.py`, `gen4.py`, `diagnose.py`, `mock_fan/state.py` | https://github.com/wonderslug/aiomodernforms at e572e78d986f552a27da29989c237187585af834 (the commit MFR read; still `master` on 2026-11-07) |
| AIO-ISS | aiomodernforms issues [#88](https://github.com/wonderslug/aiomodernforms/issues/88) (Breeze, 2021 to 2024: a capture of the vendor app, a read, a curl test) and [#272](https://github.com/wonderslug/aiomodernforms/issues/272) (2026-07-28: `diagnose.py --active` on a Gen 3 fan with Breeze, `fanType` 2006-52, firmware 02.00.0043) | comments named by author and date |
| HA | Home Assistant core, `homeassistant/components/modern_forms/` (`fan.py`, `number.py`, `const.py`) and `tests/components/modern_forms/` | https://github.com/home-assistant/core at e8bf6e0a8abb8c3612f2e45dd9de1180ec444a53 (`dev`, 2026-11-07) |
| HA-PR | home-assistant/core [#177507](https://github.com/home-assistant/core/pull/177507), "Add breeze mode support to Modern Forms", merged 2026-08-25 (its description) | |
| HA-DOC | the integration's page, `source/_integrations/modern_forms.markdown` on branch `current`, read 2026-11-07; added by home-assistant.io [#47111](https://github.com/home-assistant/home-assistant.io/pull/47111), merged 2026-08-26 | https://www.home-assistant.io/integrations/modern_forms/ |
| HAF | Home Assistant community, "Modern Forms Smart Fans – Integration", posts 116 (2024-08-26) and 120 (2025-03-14) | https://community.home-assistant.io/t/modern-forms-smart-fans-integration/109318/116 |
| HAB | Home Assistant community, "Modern Forms: add additional modes (Breeze mode)", posts 2 to 10 (2021 to 2023) | https://community.home-assistant.io/t/modern-forms-add-additional-modes-breeze-mode/343140 |
| OH | openHAB `mffan` binding: `FanRestApi.java`, `MfFanHandler.java`, `OH-INF/thing/mffan.xml`, README | https://github.com/openhab/openhab-addons, `bundles/org.openhab.binding.mffan/` at f9aa8f3b38dbff3a5bc0d9d26e9f0c52af4923ff |
| HOMEY | miguelcastro67/homey-modernforms: `src/clients/ModernFormsClient.ts`, `drivers/fan/device.ts`, `app.json` | https://github.com/miguelcastro67/homey-modernforms at 8824c1120dc61850f0c7022b2c19b7a108d606f9 |
| MQTT | timothyh/mf-mqtt: `mf-mqtt.js`, `mf-fan-client.js` | https://github.com/timothyh/mf-mqtt at bb127d67c61a8d17a6c69d70c1ebd67044bec158 |
| PROBE | icemarkom/mffprober: `mffprober.go` | https://github.com/icemarkom/mffprober at ff3d2f426286587a3f25877bcb30368b9e73bb8c |
| Others | HB-MRF martin-robert-fink/homebridge-modern-forms 58ff530, HB-NB nickbreaton/homebridge-modern-forms 4527497, HUB-ST staines/modern-forms-for-hubitat-and-homekit ff026ee, HUB-BH bhamiltoncx/hubitat-modern-forms-fan aa86b5b, JP jimpastos/ha-modernforms 22dd2cf, QB quielb/pypi-modernforms 0762797 | https://github.com/ and the repository name; the commits MFR lists, still the heads on 2026-11-07 |
| WAC-MF | WAC's Gen 1–3 API reference (MFR's WAC-MF), pages 17 and 20; corroboration only (MFR, "Licensing and provenance") | a copy is in AIO's `docs/` |
| MF-RCBT | Modern Forms F-RCBT-WT Bluetooth remote, instruction sheet, page 1, section "Breeze Mode" | https://www.modernforms.com/images/products/INST_SHEET/F-RCBT_INSSHT.pdf |
| MF-RCUV | F-RCUV-WT Bluetooth remote (UV fans), instruction guide, section 4 | https://cdn.shopify.com/s/files/1/0503/4239/6071/files/modern-forms-uv-bluetooth-remote-instruction-guide.pdf |
| MF-WCBT | F-WCBT-WT Bluetooth wall control, instruction sheet, section 3 | https://www.modernforms.com/images/products/INST_SHEET/F-WCBT_INSSHT.pdf |
| MF-rc, MF-wc, MF-wci | the RF remote F-RC-WT and the RF wall controls, as [`edge-cases-modernforms.md`](edge-cases-modernforms.md#status-markers-and-sources) lists them | |
| MF-store | the Modern Forms app's App Store page and version history, read 2026-11-07 | https://apps.apple.com/us/app/modern-forms/id1425046298 |
| M0 | the house fan's read-only answers of 2026-10-27 (#11): Gen 3, firmware 02.00.0052, `fanType` 1811-5-54, motor `DC125X20`; its state as [`tests/fixtures/mf_gen3.lua`](../tests/fixtures/mf_gen3.lua) L88–98 keeps it, value types as the fan sent them ([`v1-design.md` §10.1](v1-design.md#101-fixtures-testsfixtures-loaded-as-requirefixturesmf_gen3)) | this repository |
| DRV | this repository's driver on `feat/breeze-111`: [`wire.lua`](../src/modernforms_fan/fan/wire.lua), [`model.lua`](../src/modernforms_fan/fan/model.lua), [`texts.lua`](../src/modernforms_fan/fan/texts.lua), [`devcmds_spec.lua`](../tests/spec/devcmds_spec.lua) | this repository |

## 1. The fields

| Key | Type the fan reports | What it accepts | Default | Fans | Source |
| --- | --- | --- | --- | --- | --- |
| `wind` | boolean | `true`, `false` | not known; `false` on the house (M0) | Gen 3 with Breeze; never Gen 1/2; Gen 4 in its fan fixture | AIO `const.py` L19, L48–49, L60; WAC-MF p17, p20 (Gen 3 and later); M0; AIO-ISS #272 |
| `windSpeed` | integer 1–3 | integers 1–3 (AIO, OH, field reports); a string `"2"` from the vendor app (field report) | 2 (see below) | as `wind` | AIO `const.py` L20, L43–46, L61; WAC-MF p17, p20; M0 |

- **Types reported.** Every answer seen carries `windSpeed` as a JSON
  integer: the house (VERIFIED: M0, fixture L98), AIO-ISS #272's raw state
  (`windSpeed` 1) and its echo (the check compares with the integer 2 and
  passed), AIO-ISS #88's read (`windSpeed` 1) [ASSUMED for other firmware:
  field reports on 02.00.0026 and 02.00.0043].
- **Types accepted.** Integers: AIO validates an `int` 1–3 and a `bool`
  (`modernforms.py` L735–751); openHAB writes `%d` (OH `FanRestApi.java`
  L79–86); a curl with `"windSpeed": 1` worked (AIO-ISS #88, kylepet,
  2024-05-09) [VERIFIED: the code; ASSUMED: the field reports]. The vendor
  app sent `"windSpeed":"2"`, a string, together with `"wind":true` and
  `"fanOn":true` [ASSUMED: field report AIO-ISS #88, garrett3333,
  2021-11-05; the read taken hours later shows `windSpeed` 1, so whether the
  string was taken is not shown]. MFR §2.1 says the same; it is confirmed as
  a field report and stays one. **The driver sends integers.**
- **Capability.** A state answer with a `wind` key means Breeze. AIO's
  `has_wind()` is `state.wind is not None` (`models.py` L339–341), Home
  Assistant registers its preset and number only then (`fan.py` L62–66,
  `number.py` L23–28), and the driver stores it (`model.lua` L1222–1226,
  `mf_wind`) [VERIFIED: code]. That a Gen 3 fan without Breeze hardware
  leaves the key out is [ASSUMED: AIO's and HA's design rests on it; no
  report of such a fan was found]. Every Breeze report names a DC motor
  (house `DC125X20`, AIO-ISS #88 `DC125X30`, #272 `DC156X08`), and #88's
  opener calls Breeze a feature of the DC fans [ASSUMED: field reports].
- **Gen 1/2** have neither key [VERIFIED: WAC-MF p20 marks both Gen 3 and
  later; AIO's maintainer has a Gen 1/2 fan without Breeze, AIO-ISS #272,
  2026-07-28; HAB post 3]. **Gen 4** carries `wind` and `windSpeed` in the
  fan fixture's state, written through `/fixture` action 4 (AIO `gen4.py`
  L155–156, L195–208, L228–245); the driver refuses Gen 4 (V4), so it is out
  of scope.
- **Default.** AIO's `DEFAULT_WIND_SPEED` 2 (`const.py` L46) is the
  library's value for a missing key (`models.py` L221), not a fan's; WAC's
  examples show 2 (WAC-MF p20), the house reads 2 (M0) and AIO's mock fan
  starts at 2 (`mock_fan/state.py` L99–101). The factory value is [ASSUMED:
  2].
- **Memory.** `windSpeed` keeps a value while `wind` is false: 2 on the house
  (VERIFIED: M0), 1 on two other fans [field reports AIO-ISS #88, #272].
  Whether `wind` and `windSpeed` survive a power cut is [ASSUMED: unknown;
  BR8].
- **The driver today** reads both (`wire.lua` L360–361: `wind` as a
  boolean, `windSpeed` as any number, no range check, a string would read as
  unknown), keeps them as read-only rows (`model.lua` L79–82, v1-design
  §4.1), shows ` Breeze` in Status when `wind` is true, also while the fan is
  off (`texts.lua` L561–577), and never writes them: `wire.body` refuses any
  key outside its groups (`wire.lua` L76–84, L158–184), v1-design §3.1 lists
  `wind` among the keys never written and §15 puts Breeze outside v1.

## 2. What Breeze does, and how the fan reports it

| Question | What is known | Status | Settled by |
| --- | --- | --- | --- |
| What does it do? | A base speed plus gusts at random intervals, then back to the base; `windSpeed` sets the strength of both. HA-DOC calls `windSpeed` how much the speed fluctuates. The remote sheets: it varies the fan speed like natural wind. | VERIFIED: WAC-MF p17 (paraphrased); HA-DOC L19, L46; MF-RCBT | — |
| Does `fanSpeed` set the base? | Two owners say Breeze has its own three levels apart from the six speeds, and that toggling Breeze switches between the two scales. Nothing says `fanSpeed` matters while Breeze runs. The owner's "for any given set speed" is therefore not confirmed. | ASSUMED: field reports HAB post 4 (2021-10-02), AIO-ISS #88 (kylepet, 2024-05-09) | BR1, BR5 |
| Must the fan be on? | `{"windSpeed":2,"wind":true}` was taken after `fan(on=False)` had switched the fan off (two sleep-timer steps came between), and the answer showed `wind` true and `windSpeed` 2; what `fanOn` then read, and whether the motor started, was not reported. The vendor app adds `"fanOn":true`; HA's preset sends `wind` alone, its turn-on sends `fanOn` and `wind` together. | ASSUMED: field report AIO-ISS #272 with `diagnose.py` L379–384, L421–438 (the order of the checks); #88 for the app; HA `fan.py` L117–119, L132–148 | BR2 |
| Does turning the fan off clear `wind`? | HA says no: Breeze stays set and resumes at the next turn-on. One read showed `fanOn` false with `wind` true. HA-PR's author, AIO's maintainer, has only a fan without Breeze (AIO-ISS #272, 2026-07-28), so the claim is not a measurement. | ASSUMED: HA-PR #177507 description, HA-DOC L19; field report AIO-ISS #88 (garrett3333, 2021-11-06) | BR3 |
| Does `fanSpeed` move with the gusts (MFR H6)? | No source shows reads taken during Breeze. WAC's wording (a base speed the gusts return to) and the remote sheets (on exit the fan returns to the speed it had) fit a shadow that keeps the set speed while the motor varies. | ASSUMED: unknown | BR1, K16 |
| Does a speed command end Breeze? | Nothing says. The remote sheets name only the two-button press to leave Breeze. | ASSUMED: unknown | BR4 |
| Does direction matter? | Breeze always turns the fan forward (summer, counter-clockwise); on leaving Breeze the fan returns to the direction and speed it had before. Whether the shadow's `fanDirection` reads `forward` during Breeze on a reversed fan is not known. | VERIFIED: MF-RCBT, MF-RCUV, MF-WCBT; the shadow: ASSUMED | BR6 |
| A Breeze button on the remote or the wall control? | Bluetooth remotes and the Bluetooth wall control: hold the fan button and the reverse button together for 4 s to start, the same to leave; the LED blinks green and the fan beeps. The RF remote's and RF wall controls' sheets do not mention Breeze. #88's opener entered Breeze by holding reverse on his remote; HAB post 2 saw it settable only from certain RF controls. | VERIFIED: MF-RCBT (both icons read from its page 1), MF-RCUV, MF-WCBT; RF: absence in MF-rc, MF-wc, MF-wci; the rest ASSUMED (field reports) | the house's remote model (a hardware fact to collect); BR7, K16 |
| How does a remote press show? | `userData` names the last control path; `ble` is the remote or wall control. Whether a Breeze press reports it is not known. | VERIFIED: the values (AIO `const.py`, MFR §2.2); the Breeze press: ASSUMED | BR7, K16 |
| Does the fan remember `windSpeed`? | Yes, while Breeze is off (section 1). Across a power cut: unknown. | VERIFIED: M0; ASSUMED: power | BR8 (parked) |
| The vendor app | Shows Breeze and a strength of 1 to 3 and follows changes made over the local API; its capture shows the bodies in section 4. Its App Store history mentions no Breeze. | ASSUMED: field reports AIO-ISS #88; MF-store (absence) | — |

## 3. How others expose it

| Integration | Breeze appears as | Strength | Bodies it sends | Source |
| --- | --- | --- | --- | --- |
| `aiomodernforms` | `fan(wind=..., wind_speed=...)` keyword arguments; `has_breeze_mode()`; constants `WIND_ON`, `WIND_OFF`, `WIND_SPEED_LOW_VALUE` 1, `WIND_SPEED_HIGH_VALUE` 3, `DEFAULT_WIND_SPEED` 2 | 1–3, an `int`, else an error | one body for all arguments, keys in the order `fanSpeed`, `fanOn`, `fanDirection`, `windSpeed`, `wind`; `wind` and `wind_speed` are dropped silently when the fan has no `wind` key | `modernforms.py` L397–404, L677–751; `const.py` L19–20, L43–49 |
| `aiomodernforms` `diagnose.py --active` | a check: Breeze on with a new strength, then off; the restore sends fan on, speed, direction, `wind` and `windSpeed` in one body | the other of 1 and 2 | `{"windSpeed":2,"wind":true}`, `{"wind":false}`, and the restore's mixed body | `diagnose.py` L421–438, L477–485; passed on a real Gen 3 fan, "Fully restored" (AIO-ISS #272) |
| Home Assistant (since 2026-08-25) | the fan entity's preset modes `normal` and `breeze`, only when `has_wind()`; the speed percentage still shows `fanSpeed` | a separate `number` entity "Breeze intensity", 1–3, step 1, a configuration entity | preset: `{"wind":true}` or `{"wind":false}` alone; turn-on with a preset: `fanOn`, `wind` (and `fanSpeed` with a percentage) in one body; intensity: `{"windSpeed":N}` alone | `fan.py` L22–23, L62–77, L99–107, L117–119, L132–148; `number.py` L23–59; tests `test_fan.py` L299–355, `test_number.py` L70–90; HA-PR #177507 |
| openHAB `mffan` | a switch channel `wind-on` and a channel `wind-level` with the options 1, 2, 3 | 1–3 | `{"wind" : true}`, `{"wind" : false}`, `{"windSpeed" : N}`, each alone | `mffan.xml` L81–105; `FanRestApi.java` L79–86; `MfFanHandler.java` L119–126, L151–153 |
| Homey | a `breeze_mode` capability (enabled, disabled), added to every fan; flow trigger "Breeze mode changed", condition "Breeze mode is", action "Set breeze mode" | none (read into the state only) | `{"wind":true}` or `{"wind":false}` alone | `ModernFormsClient.ts` L68–72; `device.ts` L59–60, L85–86, L217–218, L392–395; `app.json` (ids `breeze_mode_changed`, `breeze_mode_is`, `set_breeze_mode`) |
| MQTT gateway | attributes `wind` and `wind_speed` | as sent | one key per body | `mf-mqtt.js` L67–74; `mf-fan-client.js` L77–88 |
| mffprober | read only: `wind` and `windSpeed` (an integer) in its one-line report | — | — | `mffprober.go` L66–67, L77 |
| HB-MRF, HB-NB, HUB-BH, JP, QB | nothing | — | — | no `wind` in their code; HUB-ST lists it as a to-do (groovy L79–80) |
| The vendor app | a Breeze switch with a 1–3 strength | 1–3 | `{"wind":true,"windSpeed":"2","fanOn":true}`, `{"wind":false}` | field report AIO-ISS #88 |
| Owners with curl | Breeze on and off | 1 | `{"wind":true}`, `{"wind":false}`, `{"wind": true, "windSpeed": 1}` | field reports HAF 116, 120; HAB post 10; AIO-ISS #88 |

The pattern: Breeze is an on/off mode beside the speed, never a seventh
speed, and its strength is a separate 1 to 3 setting that Home Assistant
and openHAB expose and Homey leaves out. Only the vendor app and Home
Assistant's turn-on send `fanOn` with `wind`.

## 4. The body to send

| Purpose | Body | Rests on | Status |
| --- | --- | --- | --- |
| Breeze on, fan running | `{"wind":true}` | HA, OH, HOMEY; HAF 116, 120; the echo in AIO-ISS #272 | VERIFIED: code; ASSUMED on the house until BR1 |
| Breeze off | `{"wind":false}` | the vendor app (#88), HA, OH, HOMEY, HAF 116; #272's echo | as above |
| Strength | `{"windSpeed":N}`, N 1–3 | HA's number, OH, MQTT | VERIFIED: code; whether it starts Breeze or touches the motor while Breeze is off: BR5 |
| On at a strength | `{"wind":true,"windSpeed":N}` | AIO `fan()`, its `diagnose.py` on #272; #88 (kylepet) | ASSUMED: field reports |
| On from off, one body | `{"fanOn":true,"wind":true}` (the vendor app's, with an integer, and `windSpeed` only if a strength is wanted) | #88's capture; HA's turn-on (`fan.py` L139–148) | ASSUMED; the first body to mix the fan group with another |
| On from off, two bodies | `{"fanOn":true,"fanSpeed":N}`, then `{"wind":true}` | each body as above | ASSUMED; BR2 says whether the first is needed |

- **The answer** is the full dynamic shadow with the new values [VERIFIED:
  WAC-MF p20; AIO `request()` L345–351 takes every answer as the new
  state]. For Breeze it shows `wind` and `windSpeed` as sent [ASSUMED:
  field report AIO-ISS #272]. What `fanOn`, `fanSpeed` and `fanDirection`
  show in that answer is BR1, BR2 and BR6.
- **Never sent:** a string `windSpeed`; `wind` or `windSpeed` to a fan whose
  answers have no `wind` key (AIO drops them; what a fan without Breeze does
  with them is [ASSUMED: ignored, MFR §3]); a value outside 1–3.
- **Key order** does not matter to the fan [ASSUMED: AIO sends `windSpeed`
  before `wind`, the app `wind` before `windSpeed`, and both worked]. The
  driver keeps its own fixed order (v1-design §3.1).

### 4.1 Fit with the driver's command path

- **`wire.body`** (`wire.lua` L76–184) builds one group's body from an
  allow-list and answers "unknown" for `wind`; the dev loop's `Dev Request`
  goes through it, and its spec asserts that `{"wind":true}` is refused
  (`devcmds_spec.lua` L906). A fourth group `breeze` with the fields `wind`
  (boolean) and `wind_speed` (integer 1–3) fits the existing shape: the
  builder writes `{"wind":true}`, `{"wind":false}`, `{"windSpeed":%d}` and
  `{"wind":true,"windSpeed":%d}` with `string.format`, as the other groups
  do. The one-group rule then gives the two-body "on from off"; the
  one-body form would be the first exception to that rule.
- **`wire.state`** (L360–361) would gain the same range handling for
  `windSpeed` the speed and level have (1–3, an out-of-range value logged
  and clamped or unknown).
- **The model** (`model.lua` L71–82) keeps three groups and lists `wind`
  and `wind_speed` as read-only. As a group: `GROUPS`, `GROUP_FIELDS`,
  `FIELDS` and `FIELD_NAME` would gain it; `validate` (L1679–1748) would
  refuse it while `has_wind` is not true and when the key is missing (as
  "no <key>"); `plan_group` and `command_request` (L780–841) walk the groups in
  order, so `fan` goes before `breeze` and a wanted "fan on" plus "Breeze
  on" become the two bodies in the right order with the 250 ms gap between.
  The settle window and held values (L1155–1211, v1-design §4.4) work per
  field and need nothing new for `wind` and `windSpeed`, which change only
  by a command, the remote or the app [ASSUMED].
- **Not a fit as it stands:** the side effects in section 5, items 2 to 4.

## 5. Risks for the settle window and the poll

1. **Gusts in `fanSpeed` (H6).** If reads show the momentary speed, each
   poll during Breeze sees a speed nobody commanded. `reconcile`
   (`model.lua` L1292–1313) reports it as "outside": the proxy hears a new
   `CURRENT_SPEED`, so the fan proxy's speed events fire and every keypad
   LED on Follow Connection moves; Last Change By is rewritten; and
   `open_fast_window` (L735–737, called at L1308) extends the fast window to
   20 s from that moment, so the next poll is 2 s away (L727–733). With a
   speed that keeps moving, the driver polls every 2 s for as long as
   Breeze runs, about 1800 requests an hour, against a Wi-Fi module known
   to freeze under frequent polling (MFR §8). The settle window does not
   help: a read that contradicts a command is held only until the next read
   or 2.5 s (L1158–1186), and gust readings never agree with the command,
   so after 2.5 s they are believed.
   **Recommendation:** whatever BR1 shows (45 s of reads cannot prove that
   randomly timed gusts never show), while the confirmed `wind` is true a
   read's change of `fanSpeed` alone is not an outside change: it is logged
   at debug, not told, and opens no fast window; the speed is told again
   when `wind` goes false.
2. **A Breeze command's side effects.** If the answer to `{"wind":true}`
   also changes `fanOn` (from off), `fanDirection` (reverse to forward, as
   the remote sheets suggest) or `fanSpeed`, those groups were not the
   command's, so `reconcile` calls them "outside" (`why` comes from
   `ctx.cmd`, one group, L1325–1331): Last Change By would name the app or
   another local client (`userData` `local_wifi`), and the fast window
   opens. **Recommendation:** an answer counts as "command" for every group
   it changed, not only the group that was sent.
3. **Leaving Breeze** may restore the direction and speed the fan had
   before (the remote sheets), so `{"wind":false}` can move the fan and
   direction groups too: the same as item 2.
4. **A fan command during Breeze** (a keypad speed link) may end Breeze
   (BR4). As long as `wind` is a read-only row that only changes a row and
   the Status text; once it is a group, the change in a fan command's
   answer is item 2 again.
5. **Off keeps Breeze** (if HA is right, BR3): a later "fan on at N" from
   a keypad would start Breeze, not steady speed N, while the speed LEDs
   show N. Whether the driver's Off or a speed command also clears `wind`
   is a choice for the contract; Home Assistant does not clear it.
6. **No new poll cost:** `wind` and `windSpeed` are in every state answer
   already; reading them costs nothing.

## 6. Checks on the house

**Where they run.** Today nothing can write `wind` to the house fan: the
VM's [`tools/mf_probe.py`](../tools/mf_probe.py) builds every body from
v1-design §3.1's allow-list ([`fan-probe.md`](fan-probe.md#safety-rails)),
and a dev build's `Dev Request` refuses it (section 4.1). Two ways:

- **A VM-side check** (recommended, before the contract freezes, since
  BR1 to BR6 shape it): a `check BREEZE` in `tools/mf_probe.py` whose
  allow-list adds only the four breeze bodies of section 4, with the
  probe's rails (`--yes-owner-told`, `--expect-id`, one request in flight,
  reads at least 0.5 s apart and at most 60 a run, the state it found put
  back and read again: fan on or off, speed, direction, `wind`,
  `windSpeed`). It is VM tooling, so the owner's rule against one-off
  tooling in the shipped driver holds.
- **After the build**, a `--dev` build's `Dev Request` carries the breeze
  bodies once `wire.body` accepts them ([`dev-loop.md`](dev-loop.md#development-commands)).

The driver keeps polling during a VM check and will show the changes as
made outside Control4 (Status, Last Change By, keypad LEDs follow); nothing
to fix. The owner is told first what the fan will do, one line per check.

| # | Start | Sends, reads | Answers | Time | Who |
| --- | --- | --- | --- | --- | --- |
| BR0 | any | `read --fan 10.0.2.151` once | `wind` and `windSpeed` present, their types and values now (M0: false, 2) | seconds | VM, read-only |
| BR1 | fan on at 3, forward (started at its own speed if off) | `{"wind":true}`; a read every 1 s for 40 s; `{"wind":false}`; a read 2 s later | H6: does `fanSpeed` stay or move, how often; `fanOn`, `fanDirection`, `windSpeed` during Breeze; the speed after leaving; the owner's ear: did the motor vary | about 45 s | VM; the owner listens |
| BR2 | fan off | `{"wind":true}`; reads at 1 s and 3 s; `{"wind":false}`; a read; `{"fanOn":false}` if it started | does `wind` alone start the fan (one body or two, section 4); is it taken while off | about 10 s | VM |
| BR3 | Breeze on, fan running | `{"fanOn":false}`, a read; `{"fanOn":true,"fanSpeed":3}`, a read 2 s later; `{"wind":false}` | does off clear `wind`; does on resume Breeze | about 15 s | VM |
| BR4 | Breeze on at speed 3 | `{"fanOn":true,"fanSpeed":5}`, a read at 1 s | does a speed command end Breeze; is the speed taken | about 10 s | VM |
| BR5 | Breeze off | `{"windSpeed":3}`, a read; `{"wind":true,"windSpeed":1}`, a read; `{"windSpeed":3}`, a read; `windSpeed` and `wind` put back | does a strength alone start Breeze or change the motor; the combined body; strength while Breeze runs | about 15 s | VM |
| BR6 | fan on, reverse (direction writes are safe on the house fan, K11) | `{"wind":true}`, a read; `{"wind":false}`, a read; direction put back | does `fanDirection` read `forward` during Breeze, and `reverse` again after | about 15 s | VM |
| BR7 | only if the house remote or wall control is a Bluetooth model with the Breeze press | `read --count 30 --interval 2` while the owner holds the fan and reverse buttons for 4 s, waits about 20 s, holds them again | `userData` of a Breeze press (`ble`?), `wind`, `fanSpeed`, `fanDirection` by the remote's path; overlaps K16 | 60 s | the owner's hands; VM reads |
| BR8 | parked | whether `wind` and `windSpeed` survive a power cut, read with K17 when it runs | the state after power returns | with K17 | not blocking |

Parked under "no long test waits": how often gusts come over minutes. A
passive way costs nothing: the driver's Debug Mode log during an evening of
Breeze shows its normal reads.

One line each for the owner: BR1 "The fan goes into Breeze for about 40 s
and back to speed 3; listen whether its speed varies." BR2 "With the fan
off, Breeze is switched on and off within 10 s; the fan may start briefly."
BR3 "Breeze on, the fan off and on again, Breeze off, about 15 s." BR4 "In
Breeze, the fan is set to speed 5 for a moment, then put back." BR5 "Breeze
strength is changed and Breeze runs briefly, about 15 s." BR6 "With the fan
in reverse, Breeze runs for a few seconds, which may turn it forward; then
it goes back to reverse."

## 7. Open points for the contract

These are inputs, not decisions; the Control4 side is the other note's.

- Breeze on from off: one body or two (BR2).
- Whether the driver's Off, or a speed command, also clears `wind` (BR3,
  BR4; Home Assistant does not).
- The H6 guard of section 5, item 1, and the "command" attribution of
  items 2 to 4.
- Whether the strength is offered (Home Assistant and openHAB do; Homey does
  not), and its default when the fan reports none (2).
- Breeze is offered only while `has_wind` is true: never on Gen 1/2, never
  on a fan whose answers lack `wind`; Gen 4 is refused anyway (V4).
