# Modern Forms fan: the local API, and how the driver should use it

Research for [issue #2](https://github.com/corytron/c4-modernforms-driver/issues/2),
written 2026-10-27. Desk research only: no fan, controller or other device on
the house network was contacted. It answers the "Transport" questions of
[`design.md`](design.md) and feeds its "State model" section; the decisions
themselves belong to the v1 contract.

**Status key**, as in [`design.md`](design.md) ("Method"):
**[verified: source]** is checked in a primary source named at the claim (for
the fan: the `aiomodernforms` or Home Assistant source at the commit listed
below; for Control4: the SDK reference path). **[verified: WAC-MF only]** rests
on WAC's own published reference alone, a source the method did not yet count
(see "Licensing and provenance" at the end). **[assumed: reason]** is not
confirmed; that includes everything known only from a user's report about
their own fan, called a *field report*. Recommendations are marked as such.
Addresses, MACs and ids are the placeholders of
[`scaffold-design.md`](scaffold-design.md), section 2: fan `10.0.2.151`, MAC
`00:00:5e:00:53:01`, client id `MF_00005E005301`.

## Summary

1. **The assumption holds for every fan sold before 2026:** plain HTTP
   `POST http://10.0.2.151/mf`, port 80, a small JSON body, no
   authentication. `{"queryDynamicShadowData":1}` reads the state; a body
   naming only the fields to change commands the fan; **every command's answer
   is the complete new state** [verified]. WAC publishes this interface itself.
2. **Fans launched in 2026 ("Gen 4", e.g. Radiant) speak another protocol**
   (`/device`, `/fixture`) and answer `/mf` with HTTP 404 [verified]. The house
   fan's generation is open question Q1.
3. **The fan pushes nothing**; every integration polls [verified]. Home
   Assistant polls every 15 s and raised that from 5 s in July 2026 because
   fans' Wi-Fi modules froze until power-cycled [verified].
4. **The Wi-Fi side is fragile**: a tiny TCP stack, freezes under frequent
   polling (worse while the vendor app polls too), and one model reportedly
   drops off Wi-Fi whenever it is sent a direction [field reports]. One
   request at a time, gentle polling, reboot only on a click.
5. **Fan**: `fanOn` plus `fanSpeed` 1–6 plus `fanDirection`
   `"forward"`/`"reverse"`. **Light**: `lightOn` plus `lightBrightness` 1–100,
   no colour temperature and no fade time before Gen 4 [verified].
6. **Turning the light on at a new level in one body flashes the old level**;
   send the level first, then on [verified: aiomodernforms does so].
7. **Late and out-of-order reports can be designed out**: one transfer in
   flight per fan, the command's echo as authority, stale polls dropped, a
   short settle window, "on at speed N" in one body (section 6).
8. **Control4 side**: `C4:url():Post()` with `timeout`, `connect_timeout` and
   `fail_on_error` set, answers in `OnDone` [verified: SDK]. On OS 3.4.2
   Director serializes transfers per host and runs at most four at once
   [verified: Hue driver], so an unanswering fan must never hold more than one.
9. **Discovery is mDNS `_easylink._tcp`**, for which DriverWorks has no API.
   v1 takes an address and pins the fan's `clientId`, which every answer
   carries [verified].
10. **Licensing**: WAC's API License Agreement treats its API documentation as
    confidential, and the Gen 4 reference is marked CONFIDENTIAL. This document
    builds on the public open-source code and cites WAC's documents only as
    corroboration. A decision for the owner.

## Sources

| ID | What | Where, version |
| --- | --- | --- |
| WAC-MF | WAC, "WAC and Modern Forms Smart Fans IP API Definition for 3rd Party Integrations" (Gen 1–3), PDF of 2022-04-14, 21 pages | Linked from https://modernforms.com/developer/ (link text "MF API License Agreement"), hosted at https://waclighting-images.s3.amazonaws.com/developer/WAC_Modern_Forms_3rd_Party_API_Reference.pdf; a copy is in AIO's `docs/`. Page numbers are the PDF's. |
| WAC-IoT | WAC, "WAC IoT Unified REST Interface for 3rd party", v1.91 of 2026-06-24, 79 pages, every page marked CONFIDENTIAL; covers the "Gen4 Fan" | AIO's `docs/`; WAC sent it to AIO's maintainer, who said so in HA-ISS #169247 (comment of 2026-07-30). Page numbers are the printed footers. |
| WAC-LIC | WAC API License Agreement of 2021-10-21 | https://waclighting-images.s3.amazonaws.com/developer/WAC_API_License_Agreement_21.10.2021.pdf, linked from https://www.waclighting.com/developer |
| AIO | `aiomodernforms` 0.3.1 (MIT), the library Home Assistant uses; files under `aiomodernforms/` unless named | https://github.com/wonderslug/aiomodernforms, `master` at e572e78 (2026-09-17); line numbers at that commit |
| HA | Home Assistant core: `homeassistant/components/modern_forms/` and `tests/components/modern_forms/` | https://github.com/home-assistant/core, `dev` at 5ed01ad (2026-10-27), pinning aiomodernforms 0.3.1 |
| HA-DOC | The integration's documentation page | https://www.home-assistant.io/integrations/modern_forms/ (source `source/_integrations/modern_forms.markdown`, branch `current`) |
| HA-PR, HA-ISS | home-assistant/core pull request #177508 (poll interval 5 s to 15 s, merged 2026-07-29); issues #149019 (stuck fans) and #169247 (Gen 4 Radiant) | https://github.com/home-assistant/core |
| AIO-ISS | wonderslug/aiomodernforms issues #88 (breeze, vendor-app traffic), #99 (light flash), #272 (a Gen 3 diagnostic report), #287 (Gen 4 hardware reports) | https://github.com/wonderslug/aiomodernforms/issues |
| CAP | `modernformasfan.pcapng` in AIO's root: a Gen 1/2 fan (firmware 01.03.0025) on 2021-03-15, one mDNS announcement and the start of a vendor-app request | AIO at e572e78 |
| HAF | Home Assistant community thread "Modern Forms Smart Fans – Integration" (2019–2022), posts by number | https://community.home-assistant.io/t/modern-forms-smart-fans-integration/109318 |
| Others | Integrations read at the commit named: **HB-MRF** martin-robert-fink/homebridge-modern-forms 58ff530 (`src/modern-forms-client.ts`); **HB-NB** nickbreaton/homebridge-modern-forms 4527497 (`src/utils/client.ts`); **HUB-ST** staines/modern-forms-for-hubitat-and-homekit ff026ee (`modern-forms-for-hubitat-and-homekit.groovy`, README); **HUB-BH** bhamiltoncx/hubitat-modern-forms-fan aa86b5b; **JP** jimpastos/ha-modernforms 22dd2cf (`custom_components/modernforms/__init__.py`); **HOMEY** miguelcastro67/homey-modernforms 8824c11; **MQTT** timothyh/mf-mqtt bb127d6 (`mf-mqtt.js`); **PROBE** icemarkom/mffprober ff3d2f4; **QB** quielb/pypi-modernforms 0762797 | https://github.com/ followed by the repository name |
| SDK | Snap One's DriverWorks API reference; paths below `~/c4-tools/reference/`, paraphrased, never quoted | local clone |
| HUE | The author's Hue driver, `docs/design.md`, sections "`C4:url` transfer scheduling on OS 3.4.2" and "Concurrent transfers (verified 2026-10-25)", measured on the house on OS 3.4.2 | https://github.com/corytron/c4-hue-driver/blob/main/docs/design.md |

Not reviewed: C4Forums (the site refused automated access), the Modern Forms
app, and the stock Control4 driver's code.

## 1. Generations, and how to tell them apart

| | Gen 1/2 | Gen 3 | Gen 4 (sold from 2026) |
| --- | --- | --- | --- |
| Interface | `POST /mf` | `POST /mf` | `POST /device`, `POST /fixture`; `/mf` answers 404 |
| Firmware (`firmwareVersion`) | 01.03.00xx | 02.00.00xx | `iotmVer` 01.00.00xx |
| Sleep timers | `fanSleepTimer`, `lightSleepTimer`: epoch time | `fanTimer`, `lightTimer`: seconds left | none |
| Breeze | no | `wind`, `windSpeed`, on fans with the hardware | on the fan fixture |
| Last control path | no | `userData` | not known |
| Light | one: on/off and level | one: on/off and level | one per fixture (downlight, uplight): level and colour temperature |
| mDNS instance name | `WAC Windermier Fan#XXXXXX` | `MF_Fan_XXXXXX` (`WAC_Fan_XXXXXX` for WAC-brand fans) | not known |

Sources, row by row. Interface [verified: WAC-MF p6, p12, p19; AIO
`modernforms.py` `update()` L135–165, `_probe_gen4()` L181–204; HA
`tests/components/modern_forms/__init__.py` L151, which mocks a Gen 4 fan's
404 on `/mf`]. Firmware [verified: WAC-MF p7, p9 for Gen 1–3; assumed for
Gen 4: field reports HA-ISS #169247 (01.00.0082), AIO-ISS #287 (01.00.0080)].
Timers [verified: WAC-MF p13–14, p18; AIO `models.py` `_infer_generation()`
L286–304, `modernforms.py` `_sleep_command()` L442–475, Gen 4 none:
`models.py` `has_sleep_timer()` L351–353]. Breeze [verified: WAC-MF p17, p20
(marked Gen 3 and later); AIO `models.py` `has_wind()` L339–341; HA `fan.py`
L62–66]. Last control path [verified: WAC-MF only, p19]. Light [verified:
WAC-MF p20 (no colour field); AIO `light_fixture()` L652–655 (colour
temperature sent on Gen 4 only), `gen4.py` `_light_from_fixture()` L95–116;
HA `light.py` L69–96]. mDNS names [verified: WAC-MF p2; CAP for Gen 1/2].

**Detection with read-only calls**, in AIO's order [verified: AIO `update()`
L135–165]: `POST /mf {"queryDynamicShadowData":1}`; an HTTP error there means
"try Gen 4": `POST /device {"query":true}`, whose `systemType` contains
`fan_g4` [verified: AIO `const.py` L129–134, `gen4.py`
`is_gen4_system_type()` L70–73]. A shadow holding `fanTimer` or `lightTimer`
is Gen 3, otherwise Gen 1/2 [verified: AIO `_infer_generation()`]; a `wind`
key means breeze support [verified: AIO `has_wind()`].

The Wi-Fi modules [assumed: read from the evidence]: Gen 1/2 announce a
"MICO OS Rev" in mDNS [CAP], MXCHIP's MiCO system, whose provisioning
protocol is called EasyLink (hence the service name); Gen 3 and Gen 4 report
an `esp-idf-version`, ESP32 firmware [field reports AIO-ISS #272, #287].

## 2. The Gen 1–3 interface: `/mf`

### 2.1 Request

- `POST http://10.0.2.151/mf`, HTTP on port 80, a JSON body [verified: WAC-MF
  p6, p12, p19; AIO `const.py` L3–5 (port 80, endpoint `mf`, 5 s timeout),
  `_request()` L279–343]. WAC's examples send `Content-Type:
  application/json` [verified: WAC-MF p6]. The vendor's iOS app sends the same
  JSON as `application/x-www-form-urlencoded` with `Connection: keep-alive`
  [verified: CAP], and one plugin states the fan ignores the content type
  [assumed: HB-MRF `post()`, comment at L329–332].
- **No authentication, no TLS, no session or token** [verified: WAC-MF (no
  credential in any example); AIO sends none by default, `_request()`
  L291–293].
- **Read**: `{"queryDynamicShadowData":1}` for the state,
  `{"queryStaticShadowData":1}` for identity and model [verified: WAC-MF p6,
  p12]. AIO sends `true` instead of `1` [verified: AIO `_update_legacy()`
  L169, `_request()` L305–306].
- **Write**: a body with only the fields to change; several fields in one body
  are applied together [verified: WAC-MF p19–20; AIO `fan()` L677–785 builds
  one body]. A command and the read key may share a body [verified: AIO
  `away()` L801–803].
- **Types**: booleans `true`/`false`, integers [verified: WAC-MF p20]. Seen
  tolerated in the field: `1`/`0` for booleans [assumed: JP `__init__.py`
  L104, L114] and a string `"2"` for `windSpeed`, as the vendor app sends it
  [assumed: field report AIO-ISS #88]. The driver sends exactly the
  documented types.

### 2.2 State: the dynamic shadow

Every key and type is [verified] in AIO as cited; the meanings come from
WAC-MF, which is the only source for what `userData`, `awayModeEnabled` and
`adaptiveLearning` mean.

| Key | Type, range | Gen | Meaning | Use in the driver | Source |
| --- | --- | --- | --- | --- | --- |
| `clientId` | string: `MF_` or `WAC_` and 12 hex digits | 1–3 | the fan's id, also in the static shadow | identity check on every answer | WAC-MF p12–13, p16; HA fixtures `device_status*.json` |
| `fanOn` | bool | 1–3 | fan running | read, write | WAC-MF p13, p20; AIO `const.py` L9, L51 |
| `fanSpeed` | int 1–6 | 1–3 | speed | read, write | WAC-MF p13, p20; AIO `const.py` L40–41 |
| `fanDirection` | `"forward"` (summer) or `"reverse"` (winter) | 1–3 | rotation | read; write only after a test (section 8) | WAC-MF p13, p20; AIO `const.py` L28–29 |
| `lightOn` | bool | 1–3 | light on | read, write | WAC-MF p13, p20; AIO `const.py` L10 |
| `lightBrightness` | int 1–100 | 1–3 | level | read, write | WAC-MF p13, p20; AIO `const.py` L37–38 |
| `wind` | bool | 3, breeze hardware only | breeze: a base speed with random gusts | later | WAC-MF p17, p20; AIO `const.py` L19, L60 |
| `windSpeed` | int 1–3 | 3 | breeze strength | later | WAC-MF p17, p20; AIO `const.py` L43–46 |
| `fanSleepTimer`, `lightSleepTimer` | int: epoch seconds, 0 = none | 1/2 | switch-off time | report only | WAC-MF p13–14; AIO `const.py` L57–58, `_sleep_command()` L442–475 |
| `fanTimer`, `lightTimer` | int: seconds left, 0 = none | 3 | switch-off countdown | report only | WAC-MF p18; AIO `const.py` L90–91, `_sleep_command()` |
| `awayModeEnabled` | bool | 1–3 | the fan simulates presence on its own | report; off on a click only | WAC-MF p13–14; AIO `const.py` L56, `away()` |
| `adaptiveLearning` | bool | 1–3 | the fan learns habits and acts on them | report; off on a click only | WAC-MF p15, p19; AIO `const.py` L59, `adaptive_learning()` |
| `schedule` | string, base64 | 1–3 | the fan's own schedule | report "has a schedule" | WAC-MF p15, p18; AIO `const.py` L84, `set_schedule()` L884–893 |
| `userData` | string: `none`, `local_wifi`, `cloud`, `ble`, `sleep_timer`, `away_mode`, `schedule` | 3 | how the last change was made | debug log | WAC-MF p19, p21; AIO `const.py` L85 reads it |
| `rfPairModeActive`, `resetRfPairList`, `factoryReset`, `decommission` | bool | 1–3 | remote pairing, clear the remotes, factory reset, leave the cloud | never write | WAC-MF p13–14, p17–18; AIO `const.py` L80–83, L105–108 |

Real fans add keys the reference does not list, among them `cloudPort`,
`feedbackToneMute`, `timezone`, `FrCodes` and `cdebug` [assumed: field
reports AIO-ISS #88, #272]. The driver ignores unknown keys and copes with
missing ones, as AIO does with a default for every key [verified: AIO
`models.py` `State.from_dict()` L207–252].

### 2.3 Commands

**Recommendation.** Writable keys for v1: `fanOn`, `fanSpeed`, `lightOn`,
`lightBrightness`, and `fanDirection` once tested on the house fan (section
8); later `wind` and `windSpeed`; `awayModeEnabled` and `adaptiveLearning`
only to switch them off, on a click. Every body is built from this allow-list;
**the driver never sends back a shadow it received**, since a shadow carries
`factoryReset`, `decommission` and `resetRfPairList`.

Combinations that working integrations use:

- **Fan on at speed N**: one body, `{"fanOn":true,"fanSpeed":N}` [verified:
  HA `fan.py` `async_turn_on()` L130–148 passes both to AIO `fan()`, which
  builds one body; JP `set_fan_speed()` L109–114].
- **Fan off**: `{"fanOn":false}`; the fan keeps its speed [assumed: HUB-ST
  README L17].
- **Light on at a new level**: two POSTs, `{"lightBrightness":N}` and then
  `{"lightOn":true}` [verified: AIO `light()` L561–571]. A combined body
  briefly lights at the old level [assumed: field report AIO-ISS #99, by AIO's
  maintainer on his own fan].
- **Light off**: `{"lightOn":false}`; the level is kept [assumed: the level's
  range has no 0 (WAC-MF p13), and HB-MRF README L43 says it holds].
- Whether a speed or a level sent alone switches an off fan or light on:
  [assumed: no; AIO's light split relies on it, and HUB-ST offers "turn on
  when setting a speed or level" as options].

**Reboot**: `{"reboot":true}` restarts the Wi-Fi module [verified: AIO
`const.py` L18, `reboot()` L895–911; HA `button.py` L39–43]. It is not in
WAC-MF [verified: absence; AIO's own API-parity spec notes it]. The fan
answers nothing and the request times out [verified: AIO `reboot()`
swallows the timeout; PROBE `cmd/reboot.go` L45]. It is back within seconds
and keeps its on/off state [assumed: field reports HAF #62, #68].

### 2.4 Identity: the static shadow and `/config-read`

- **Static shadow keys**: `clientId`, `mac`, `lightType`, `fanType`,
  `fanMotorType`, `productionLotNumber`, `productSku`, `owner`,
  `federatedIdentity`, `deviceName`, `firmwareVersion`,
  `mainMcuFirmwareVersion`, `firmwareUrl`; Gen 3 adds `brand` (0–2) and
  `dateCode` [verified: WAC-MF p6–11; AIO `const.py` L64–76, L87–88]. Real
  fans add `wifiSignal`, `SSID`, `BSSID`, `isUvcFan`, `dimTableId`,
  `elecFreq` and `esp-idf-version` [assumed: field reports AIO-ISS #88, #272].
- **Private data**: `owner` (the account's e-mail address),
  `federatedIdentity` (its cloud identity), `deviceName` (the name given in the
  app, often a room), `SSID` and `BSSID` (a BSSID can be geolocated), the MAC
  and `clientId`. **Recommendation:** never logged above debug, never in a
  report; the repository's `.gitleaks.toml` already refuses these patterns.
- **`clientId`** is `MF_` (WAC brand: `WAC_`) followed by the station MAC's
  twelve hex digits, so the placeholder fan is `MF_00005E005301` [verified:
  WAC-MF p7 (range column) and its example pairs]. Gen 3 modules use another
  MAC in access-point mode; the station MAC is the identity [verified: WAC-MF
  only, p2].
- **`clientId` is in every dynamic shadow** [verified: WAC-MF p12–13, p16,
  p21], so every poll and every command answer says which fan answered, at no
  extra cost.
- **Model**: `fanType` is the model number and blade span [verified: WAC-MF
  p8]. `lightType` names the light kit and is empty without one [verified:
  WAC-MF p8; HA `light.py` L39–41 creates the light only when it is non-empty];
  [assumed: not fully reliable, HAF #92 saw light entities on fans without
  one]. **No key gives the number of speeds**; every source says 1–6
  [verified: WAC-MF p13; AIO `const.py` L40–41; HA `fan.py` L43]; [assumed:
  every model uses all six, as retailer listings for several models say].
- **`/config-read`** (read-only): Gen 1/2 accept any method and answer with
  short keys (`N`, `PO`, `HD`, `FW`, `RF`, Wi-Fi as a percentage); Gen 3 wants
  POST and answers with long keys (`Name`, `Protocol`, `Firmware Rev`, `RF
  Rev`, Wi-Fi in dBm) [verified: WAC-MF p4–5; AIO `const.py` L111–125,
  `models.py` `ConfigInfo` L113–157]. Real firmware names the Wi-Fi value
  `WiFi` or `wifiSignal` instead [verified: AIO `tests/test_aiomodernforms.py`
  L204–235]. Use: a Wi-Fi signal property for diagnosis; not needed for v1.

## 3. Answers and errors

- **Every command's answer is the full dynamic shadow with the new values**
  [verified: WAC-MF p20; AIO `request()` L345–351 takes each answer as the new
  state; QB `modernforms/modernforms_fan.py` L206]. Home Assistant polls
  nothing extra after a command [verified: HA `__init__.py` L74–76].
- What the echo means: the Wi-Fi module's state after it accepted the command.
  Whether the motor and the light can then differ: [assumed: they can, rarely;
  HA-DOC's troubleshooting section says a fan may report a state that does not
  match reality, such as off while running, and advises a restart].
- `reboot`, `factoryReset` and `decommission` get no answer [verified: AIO
  `factory_reset()`, `decommission()`, `reboot()`, L842–911, swallow the
  timeout].
- A Gen 4 fan answers `/mf` with HTTP 404 and a short text body [verified: HA
  tests `__init__.py` L151; AIO `update()` L155–163 falls back on that error;
  the field traceback in HA-ISS #169247].
- Errors on Gen 1–3: none documented [verified: WAC-MF only (absence, p19–21)].
  Unknown keys, wrong types, values out of range: [assumed: ignored or clamped;
  the driver never sends them]. AIO tries an empty answer up to three times
  [verified: AIO `update()` L132–134], but that code dates from AIO's first
  commit and is [assumed] not evidence of fan behaviour.
- Malformed JSON: `C4:JsonDecode` raises an error on invalid input [verified:
  SDK `docs-driverworks-api/source/includes/12_json/_3-JsonDecode.md`], so the
  driver decodes inside `pcall` and treats a failure like a failed request.
- The answers' content type: [assumed: `application/json`; AIO reads them with
  aiohttp's `json()`, which refuses other types by default, and works on real
  fans]. `C4:url` does not depend on it.

## 4. Gen 4 in brief

Not v1 unless the house fan is one. **Recommendation:** the driver detects it
and says so in a property. Taken from AIO's public code; the Gen 4 reference
itself is marked confidential (last section).

- `POST /device {"query":true}` reads device information (`systemType`
  containing `fan_g4`, `deviceName`, `iotmVer`, `staMac`, `awayModeEnabled`)
  and accepts `reboot` [verified: AIO `const.py` L129–175, `away()` L792–799,
  `reboot()` L901–904].
- `POST /fixture {"action":3}` lists the fixtures; real fans return their
  identities only, so each fixture is then read by its address [verified: AIO
  `_fill_gen4_fixture_state()` L242–274; field report AIO-ISS #287]. Fixture
  type 13 is the fan; 0, 1, 2, 14 and 15 are lights [verified: AIO `const.py`
  L139–140].
- Control: `{"action":4,"addr":…,"state":{…}}`; the answer holds that fixture's
  new state only [verified: AIO `fan()` L760–783, `gen4.py`
  `parse_fan_control_response()` L228–245]. Fan state: `status`, `fanSpeed`
  1–6, `fanDirection` as a boolean (true = reverse), `wind`, `windSpeed`. Light
  state: `status`, `level` in hundredths of a percent (10000 = 100 %),
  `mixColorTemp` in kelvin within the fixture's `minColorTemp` and
  `maxColorTemp` [verified: AIO `gen4.py` L95–116, L192–225, `const.py`
  L142–144].
- No sleep timers, adaptive learning, RF pairing or schedules [verified: AIO
  `models.py` L347–353, `modernforms.py` L820–893].
- Plain HTTP on port 80 works on real units, and the local API works on a fan
  never linked to the cloud; `deviceModel` can name the wrong model [assumed:
  field reports AIO-ISS #287, HA-ISS #169247].
- The Gen 4 reference also documents a request that makes the device send a
  Control4 SDDP identify notification [verified: WAC-IoT p42], so Gen 4 fans
  may be found by SDDP [assumed].

## 5. Push or polling

- **No push.** WAC-MF describes no subscription, callback, websocket, UDP
  status message or long poll [verified: WAC-MF only (absence)]; every
  integration polls, and Home Assistant declares `local_polling` [verified: HA
  `manifest.json` L8].
- The fan keeps a connection open to the vendor's cloud on port 8883, the port
  of MQTT over TLS [verified: CAP shows the connection; field report AIO-ISS
  #272 shows `cloudPort: 8883`]. That is the cloud's channel, not reachable
  locally.
- Its mDNS announcements carry identity and firmware, not state [verified: CAP].
- Gen 4 documents a UDP multicast channel for commands, not for state
  [verified: WAC-IoT p3].

What the integrations do:

| Integration | Poll | Timeout | Writes | Source |
| --- | --- | --- | --- | --- |
| Home Assistant via AIO | 15 s; each poll is two POSTs (static and dynamic) | 5 s, up to 3 tries | one body per call, the light split; no poll after a command | HA `coordinator.py` L18; AIO `_update_legacy()` L167–179, `const.py` L3, `_request()` L276–278 |
| Home Assistant until 2026-07-29 | 5 s | 5 s | as above | HA-PR (diff) |
| HB-MRF (2026) | 20 s | 5 s | 120 ms debounce into one body; polls ignored for 3 s after a write | `modern-forms-client.ts` L59–61, L161–187, L229–285 |
| HUB-ST (2026) | 300 s by default, "to prevent web-server exhaustion" | 5 s | 250 ms pause after each POST | groovy L36, L447, L596 |
| HUB-BH | 30 s | the hub's default (10 s, per its comment); 1 s for reboot | one POST per action | README; groovy L42, L158–164 |
| HOMEY (2026) | 7 s | none set | one POST per action | `src/constants/AssetsConstants.ts` L2, `src/core/HttpClient.ts` |
| JP (2019) | 10 s; owners raised it to 20–30 s | none set | session renewed every 100 requests | `__init__.py` L15, L138–152; HAF #41, #70 |
| MQTT gateway | 5 s | none set | no overlapping polls | `mf-mqtt.js` L29–30, L203–211; `mf-fan-client.js` L43 |
| HB-NB | none: read on demand, cached 16 ms | none set | 16 ms batch into one body | `src/utils/client.ts` L15–62 |

## 6. Late and out-of-order speed reports

On the house, the stock driver's speed reports arrive late and out of order;
a one-second timer, restarted on every "Fan Speed Changed" event, lets them
settle before the keypad LEDs are set ([`status.md`](status.md), "What runs on
the house"). The stock driver's code was not read, so each cause below is
[assumed]:

| # | Cause | Mechanism | Evidence |
| --- | --- | --- | --- |
| H1 | A poll crosses a command | a read issued just before a command comes back with the old state after the echo was shown, or between two echoes | HB-MRF ignores polls for 3 s after a write for this reason (L165–172) |
| H2 | "On" and "speed" in separate requests | each POST echoes the full shadow, so `fanOn` alone first reports the remembered speed, then the new speed arrives | the echo [verified: WAC-MF p20] |
| H3 | The fan applies "on" before "speed" | one combined body may pass through the remembered speed, visible to a poll in between | by analogy with the light's flash (AIO-ISS #99) |
| H4 | Requests in parallel | overlapping requests on separate connections are answered in any order | Director serializes `C4:url` per host on OS 3.4.2 (HUE); a driver on raw sockets would not be, and whether that queue spans two drivers is unknown |
| H5 | The cloud path | if the stock driver reads the cloud's copy of the state, its updates lag and can reorder | whether it uses the cloud is unknown |
| H6 | Breeze | while `wind` is on the fan changes speed by itself | WAC-MF p17 describes the gusts; whether `fanSpeed` shows them is unknown |
| H7 | A stale shadow | the module reports a state that is not the motor's | HA-DOC, troubleshooting |

**Recommendations for the state model:**

1. One transfer in flight per fan; every request carries a sequence number.
2. A command's echo is the authority for the fields it set; a poll issued
   before the latest command was sent is dropped when it returns.
3. A settle window after each command (about 2.5 s): a poll that contradicts a
   just-commanded value is not reported until a second poll agrees or the
   window ends [assumed: HB-MRF uses 3 s].
4. "Fan on at speed N" goes as one body; a light turned on at a new level goes
   level first, then on; the proxy hears only the end state.
5. Cycle, up and down presses count from the driver's desired state, not from
   the last report, so fast presses add up.
6. The proxy, and so every keypad LED, is told a value only when the fan's
   queue is idle and the value differs from what it was last told.
7. On Gen 3, `userData` separates changes made over the local network (the
   driver's, but the vendor app's too) from the remote's and from the fan's own
   automations [verified: WAC-MF only, p19]; logged at debug.

Open question Q8 tells H1–H5 from H6–H7 on the house fan.

## 7. Discovery, authentication, cloud

- **mDNS**: service `_easylink._tcp` on port 80; TXT keys include
  `Protocol` (`com.modernforms.fan`), `MAC`, `Firmware Rev`, `Model` and
  `Manufacturer`, and on Gen 1/2 `Hardware Rev` and `MICO OS Rev` [verified:
  WAC-MF p2–3; CAP; HOMEY `src/discovery/DiscoverySession.ts` L16, L92–104; HA
  `manifest.json` L11–16]. Fans announce themselves inconsistently [assumed:
  HOMEY `docs/ENGINEERING_JOURNAL.md` L164, L188]. Gen 1–3 offer no SSDP or
  SDDP [verified: WAC-MF only (absence)].
- **DriverWorks has no mDNS API**, but `C4:NetConnect` accepts a `MULTICAST`
  type, so a later version could send its own query [verified: no mDNS in the
  API, Fundamentals or XML references;
  `docs-driverworks-api/source/includes/32_serial_network_device/_23-NetConnect.md`;
  HUE's "Discovery" section found the same]. **Recommendation for v1:** the
  owner enters the address (with a DHCP reservation); the driver pins
  `clientId` and `mac`, and reports a different fan at that address instead of
  adopting it.
- **Authentication: none. Encryption: none**, plain HTTP on port 80 for Gen 1–3
  [verified: WAC-MF p3, p19; AIO `const.py` L4]. Anyone on the LAN can control
  the fan with or without the driver, so the threat model `SECURITY.md`
  assumes today stands as written.
- **No cloud is needed** for the local API: full local control with the house's
  internet cut off, and a Gen 4 fan never linked to the cloud [assumed: field
  reports HAF #101, AIO-ISS #287]. The fan's sleep timers need it to reach an
  NTP server [verified: HA-DOC, NTP section].
- **No setting that turns local control on or off is known** [verified: WAC-MF
  only (absence); no integration mentions one]. In 2020 one owner reported that
  WAC-brand fans used the same API but kept it "locked behind an in-app
  purchase" [assumed: field report HAF #34].
- **Firmware** updates over the air from the app (`firmwareUrl`) [verified:
  WAC-MF p8]; versions by generation in section 1. New firmware adds keys
  (section 2.2). **Recommendation:** re-read the static shadow at start, after
  a reconnect and after a reboot, and show `firmwareVersion`.

## 8. Limits and fragility

- **No limit is documented** on rate or connections [verified: WAC-MF only
  (absence)]. WAC's license reserves the right to limit usage and rates in
  general (WAC-LIC §6.3).
- **Frequent requests hang the Wi-Fi module:**
  - Home Assistant raised its interval from 5 to 15 s because fans' Wi-Fi
    modules froze and needed a power cycle, more so while the vendor app polls
    too [verified: HA-PR body and diff]. The issue behind it describes lossy,
    slow Wi-Fi, failed or slow polls repeating into a frozen module, owners
    rebooting fans a few times a day, and longer intervals reducing but not
    ending the freezes [assumed: field reports HA-ISS #149019].
  - In 2020: the TCP/IP stack failing after frequent queries, a hung fan
    answering neither ping nor its wall control, and a theory, never tested,
    that the fan allows one TCP connection [assumed: HAF #60–#64].
  - A Gen 1/2 fan's TCP handshake offers a 3456-byte window and a 1152-byte
    segment size [verified: CAP]: a very small network stack.
  - One Hubitat driver now polls every 300 s, pauses 250 ms after each POST,
    and removed direction control because writing `fanDirection` drops a
    Mykonos 5 off Wi-Fi every time [assumed: field report HUB-ST L17, L36,
    L315–322].
- **Fast repeated commands**: nobody has measured a burst [assumed]. The
  integrations that coalesce do it on their side (HB-MRF, HB-NB).
- **Timeouts**: the integrations use 5 s in total [verified: AIO `const.py`
  L3; HB-MRF L59; HUB-ST L447]; one owner saw on/off answered within a second
  [assumed: HAF #101]. The house fan's latency is open question Q5.
- **Recovery**: the reboot command (section 2.3), else a power cycle at the
  wall or breaker [verified: HA-DOC, troubleshooting].
- **Other pollers**: the vendor app polls while it is open [verified: CAP
  shows its request; HA-PR]; the stock driver probably does too [assumed]. The
  migration removes the stock driver rather than running both.

## 9. Fan and light behaviour

- **Speed** 1–6, with `fanOn` separate [verified: section 2.2]. Off keeps the
  speed [assumed: HUB-ST README L17], but some firmware reportedly says 0 while
  off [assumed: HB-MRF L129–130]; **recommendation:** treat 0 as "off, speed
  unknown".
- **Direction** `"forward"` or `"reverse"` [verified]. Writing it is risky
  (section 8); **recommendation:** v1 reads it, and writing waits for a test on
  the house fan with the owner present.
- **Light**: `lightOn` and `lightBrightness` are separate; the level is 1–100
  and never 0, "off" being `lightOn:false` [verified: WAC-MF p13; HB-MRF README
  L43]. The level survives off [assumed: as in section 2.3], though one plugin
  reports firmware that lowers it while off [assumed: HB-MRF L175–182].
- **No colour temperature and no fade time** on Gen 1–3 [verified: WAC-MF p20
  (no such field); AIO `light_fixture()` L652–655]. **Recommendation:** the
  `light_v2` ramp rate cannot be honoured; the driver sets the target at once
  rather than stepping the fan through levels.
- **Gen 4 lights**: one or two fixtures (downlight, uplight), each with level
  and colour temperature [verified: AIO `gen4.py`; HA `light.py` L69–96; field
  report AIO-ISS #287].
- **Mapping for `light_v2`** (recommendation): level 0 is `lightOn:false`;
  1–100 is `lightBrightness` equal to the level, followed by `lightOn:true` when
  the light is off.

## 10. Calling it from Control4

From the SDK reference unless marked:

- `C4:url()` returns a transfer object; `SetOptions` and `OnDone`, then
  `Post(url, data, headers)` starts it [verified:
  `docs-driverworks-api/source/includes/35_url/_0-Header.md`, `_10-Post.md`,
  `_13-SetOptions.md`, `_8-OnDone.md`]. `C4:url` exists from OS 2.10.5 and
  `Post` from 3.0.0 [verified: same files], so the transport needs nothing above
  3.0.0; the fan proxy's 3.4.2 sets the floor.
- **Options**: `timeout` covers the whole transfer and defaults to 300 s;
  `connect_timeout` defaults to 5 s; `fail_on_error` defaults to true, and false
  lets the driver read a 4xx body, as Gen 4 detection needs [verified:
  `35_url/_12-SetOption.md`]. The driver always sets all three.
- **`OnDone(transfer, responses, errCode, errMsg)`**: 0 on success, the last
  response holding the status and body; -1 when a callback aborted; a transfer
  object serves once [verified: `35_url/_8-OnDone.md`]. `Cancel()` exists
  [verified: `35_url/_2-Cancel.md`] but does not end an active transfer on OS
  3.4.2 [verified: HUE].
- **Keep-alive**: no option controls it or connection reuse [verified:
  `35_url/_12-SetOption.md`, `_13-SetOptions.md` (absence)]; whether Director
  reuses connections between transfers is unknown [assumed: HUE, "Networking"].
  **Recommendation:** send `Connection: close`, so the fan frees its socket at
  once [assumed: harmless, and passed through by curl; to be checked on the
  house].
- **Director's scheduling on OS 3.4.2**: one active transfer per host text at a
  time, strictly in order; at most four transfers at once across all hosts and
  drivers; a transfer started inside `OnHeaders` or `OnBodyChunk` fails, one
  started from `OnDone` or a timer works [verified: HUE]. So an unanswering fan
  holds a slot for the whole `timeout`, and with the Hue driver's event stream
  holding one or two of the four, a fan driver that queued several transfers to
  a dead fan could stall the Hue driver's commands. Hence one transfer per fan
  and short timeouts. The house now runs OS 3.4.3, and OS 4.x may schedule
  differently [assumed: unknown; one at a time is safe either way].
- **Bodies** (recommendation): build the few flat bodies with `string.format`
  (`%d` for integers, literal `true` and `false`), not `C4:JsonEncode`, whose
  array output surprised the Hue project [verified: HUE]; decode answers with
  `C4:JsonDecode` inside `pcall` (section 3).
- **Timers**: `C4:SetTimer(ms, fn, repeat)`, not during `OnDriverInit`;
  Director skips repeating timers when busy [verified:
  `34_timer/_1-SetTimer.md`]. **Recommendation:** one-shot timers re-armed after
  each answer, so polls never overlap; start in `OnDriverLateInit`.
- **Fallback transport**, only if `C4:url` misbehaves on the house:
  `C4:CreateTCPClient`, whose documented example writes a raw HTTP request
  [verified: `14_lua_tcp_client/_0-Header.md`], or a network binding through
  `C4:CreateNetworkConnection` and `C4:NetConnect` [verified:
  `32_serial_network_device/_1-CreateNetworkConnection.md`, `_23-NetConnect.md`].
  Either gives full control of the connection and presumably avoids curl's
  per-host queue [assumed], at the cost of an HTTP client in Lua.

## 11. Recommended transport for v1

| # | Rule | Rests on |
| --- | --- | --- |
| 1 | `POST http://<address>/mf`; headers `Content-Type: application/json` and `Connection: close`; `connect_timeout` 3 s, `timeout` 5 s, `fail_on_error` false | API [verified]; values [assumed: AIO and HB-MRF use 5 s] |
| 2 | One transfer in flight per fan, from a Lua queue; commands go before polls; a command's echo counts as a poll and re-arms the poll timer | HUE limits [verified]; the echo [verified] |
| 3 | Coalescing: one pending desired state per field (fan on, speed, direction, light on, level), the latest value wins; flush 100 ms after the last change; at least 250 ms between the end of one POST and the next. A dimmer slide: send the current target, and when it answers send the newest one if it changed | [assumed: HB-MRF 120 ms, the Hue lights 80 ms, HUB-ST 250 ms] |
| 4 | Bodies from the allow-list only (section 2.3); "fan on at N" in one body; "light on at N" as level then on; never a received shadow | AIO, HA [verified] |
| 5 | Every answer: `clientId` checked (a different fan stops the driver and says so); the echo applied as authority for the fields just set and compared with what was asked; a mismatch triggers one confirming poll 1.5 s later | [assumed] |
| 6 | Sequence numbers; a poll issued before the latest command is dropped; a settle window of 2.5 s (section 6) | [assumed: HB-MRF 3 s] |
| 7 | Poll every 10 s while the fan answers (a property, never below 10 s): one POST per poll, fewer requests than Home Assistant's two every 15 s; one confirming poll about 2 s after the last command; on failure back off to 20 s, then 60 s; Offline after three failures in a row, with the reason in a status property | HA's rate [verified]; that 10 s is safe [assumed] |
| 8 | Static shadow at start, after a reconnect and after a reboot; `clientId`, `mac`, `fanType`, `lightType`, `firmwareVersion` stored and shown | identity [verified] |
| 9 | Generation from the first answers (section 1); a Gen 4 fan gets a status "Gen 4 fan: not supported by this version" | detection [verified] |
| 10 | A "Reboot Fan" action, never automatic; it expects no answer (3 s timeout), then polls until the fan is back | the reboot [verified]; click only, per `CLAUDE.md`'s edge-cases rule |
| 11 | `adaptiveLearning`, `awayModeEnabled`, a non-empty `schedule` and running sleep timers shown in a property; switching them off offered, never automatic | Control4 is the source of truth (`status.md`, "Decided") |

The owner should know the cost of rule 7: a change made at the wall, with the
remote or in the app reaches Control4 within one poll interval, 10 s by
default, since the fan pushes nothing.

## 12. Open questions for the house fan

**Read-only, from the VM**: no command changes state. Raw answers stay out of
the repository; what is written down is reduced to the placeholders, with
`owner`, `federatedIdentity`, `deviceName`, `mac`, `clientId`,
`certificateId`, `SSID`, `BSSID` and every address removed.

| # | Question | Read-only command | What it decides |
| --- | --- | --- | --- |
| Q1 | Generation and fields | `curl -sS -m 5 -H 'Content-Type: application/json' -d '{"queryDynamicShadowData":1}' http://10.0.2.151/mf` | Gen 1/2 or 3 (timer keys), breeze (`wind`), `userData`, extra keys; a 404 leads to Q6 |
| Q2 | Model, firmware, light kit | the same with `{"queryStaticShadowData":1}` | `fanType`, `lightType`, `firmwareVersion`, `mainMcuFirmwareVersion`, `brand`; that `clientId` is `MF_` and the MAC |
| Q3 | Diagnostics | `curl -sS -m 5 -X POST http://10.0.2.151/config-read` | the Wi-Fi signal key, firmware and RF strings |
| Q4 | HTTP behaviour | Q1's command with `-v` and the URL given twice | HTTP version, `Content-Type`, `Content-Length`, `Connection`, and whether curl could reuse the connection |
| Q5 | Latency | Q1's command ten times, 3 s apart, with `-o /dev/null -w '%{time_connect} %{time_total}\n'` | the timeouts of section 11 |
| Q6 | Gen 4, only if Q1 got a 404 | `curl -sS -m 5 -d '{"query":true}' http://10.0.2.151/device` | `systemType`, firmware; whether v1 covers the house |
| Q7 | mDNS | `avahi-browse -rpt _easylink._tcp`, if installed | instance name (generation), TXT keys, port |
| Q8 | What the fan itself reports around a press | Q1's command every 2 s for 30 s while one stock-driver speed button is pressed | whether the fan's own reports pass through other speeds (H2, H3, H6, H7) or only the stock driver reorders them (H1, H4, H5) |
| Q9 | What the stock driver is | the Windows session reads its Documentation tab and properties in Composer (read-only) | local or cloud (H5), and how often it polls the fan |

Q8 needs the owner at a keypad (or a command on the stock driver in Composer)
and polls faster than the driver will; it stays at 30 s, since a frozen module
would need a power cycle at the wall.

**Not answerable read-only**: write tests through the dev loop, after Q1–Q5,
with the owner aware:

- whether `fanSpeed` or `lightBrightness` sent alone switches an off fan or
  light on;
- whether the house fan flashes the old level on a combined light-on body;
- whether writing `fanDirection` keeps the house fan on Wi-Fi (the HUB-ST
  report);
- how the fan copes with a burst (presses 250 ms apart) and with
  `Connection: close`;
- whether the echo matches what the motor and light do.

## Licensing and provenance

- **WAC publishes the Gen 1–3 reference** and links it from its developer page,
  which says use of the APIs is governed by WAC's API License Agreement
  [verified: https://modernforms.com/developer/; WAC-MF p1].
  [`design.md`](design.md)'s method says WAC publishes no documentation of the
  local interface "that we know of"; that is now known to be wrong.
- **The agreement** (WAC-LIC, read in full; paraphrased here, not legal advice)
  binds whoever uses WAC's APIs or their documentation (§1.1, §2.1); grants a
  non-exclusive license to use them in one's own software, commercial or not
  (§6.1); asks that users be told which services come from WAC (§6.2); lets WAC
  limit usage and rates (§6.3); forbids copying, modifying or reverse
  engineering the services (§6.4); and treats the APIs and their documentation
  as WAC's confidential information, except what is generally available to the
  public or developed without WAC's material (§8.1), with a duty not to disclose
  their specifications to anyone outside the implementation (§8.2).
- **The Gen 4 reference is marked CONFIDENTIAL** on every page; WAC sent it to
  AIO's maintainer, who published it with his library (HA-ISS #169247, comment
  of 2026-07-30).
- **What this document did**: it rests the fields and behaviours on the public
  open-source code of AIO (MIT), Home Assistant (Apache 2.0) and the other
  integrations wherever that code covers them, cites WAC's documents as
  corroboration by page number, copies no passage, and takes from the Gen 4
  reference only two facts with no public source (a UDP command channel, an
  SDDP identify request), named without their details. The claims marked
  "WAC-MF only", and the meanings noted in section 2.2, fall back to [assumed]
  if WAC's documents are set aside.
- **For the owner** (an issue labelled `question`): whether the project keeps to
  the public code and its own measurements, citing WAC's documents only as here,
  or accepts WAC's agreement, whose §8.2 may restrict what this public
  repository can say; and whether [`design.md`](design.md)'s method should name
  WAC-MF as a source. Neither PDF goes into the repository either way.
