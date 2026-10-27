# Light side and driver structure: research (#2)

Research for issue #2, 2026-10-27. It covers how the fan's integrated light
becomes a Control4 light, how the driver is laid out (one driver or two), the
minimum OS to declare, and the Lua sandbox facts the v1 contract needs. This
is a research note, not a contract: the v1 contract decides. Two other #2
notes are written alongside it: one on the fan proxy and its speed links
(`docs/fan-proxy-research.md`) and one on the fan's local HTTP API
(`docs/modernforms-api-research.md`). Where this note depends on a fan or
API fact, it says so and marks the fact ASSUMED.

## Markers and sources

| Marker | Meaning |
|---|---|
| **VERIFIED-doc** | Stated in Snap One's DriverWorks reference under `~/c4-tools/reference/`. Paraphrased here, with the file named. |
| **VERIFIED-house** | Measured on this house's controller (OS 3.4.2 / 3.4.3, Composer Pro 3.4.2) by the Hue project and recorded in its repository (`~/projects/c4-hue-driver`, public at https://github.com/corytron/c4-hue-driver), with the file and section named. |
| **ASSUMED** | Neither of the above. The test that settles it is in §5.3. |

Doc paths are written `<set> <folder number>/<file>`, where the folder number
is the numeric prefix of the folder under `source/includes/`. For example,
`LV2 5/_5-DIMMER.md` is
`docs-driverworks-proxyprotocol-lightv2/source/includes/5_light_v2_capabilities/_5-DIMMER.md`.

| Set | Directory under `~/c4-tools/reference/` |
|---|---|
| LV2 | `docs-driverworks-proxyprotocol-lightv2` (light_v2 proxy) |
| FAN | `docs-driverworks-proxyprotocol-fan` |
| PP | `docs-driverworks-proxyprotocol` (all proxies; it has the newest "What's New") |
| KP | `docs-driverworks-proxyprotocol-keypad` |
| API | `docs-driverworks-api` |
| FUND | `docs-driverworks-fundamentals` |
| XML | `docs-driverworks-xml` |
| HUE | `~/projects/c4-hue-driver` (paths relative to it) |

## The answers in short

1. **The light** becomes a light_v2 dimmer with no colour. It uses the Brightness Target API, has click and hold rates, keypad LEDs and reduced ALS, and shows the proxy's settings page. The colour flags are off but dynamic, so CCT can be switched on at run time, with no reboot, if the API research finds it.
2. **From the Hue drivers,** the keypad machine carries over as it is: press, click and release, the 400 ms hold, the 1 s click guard, the LEDs, the button colours and the keypad settings. The hold does not carry over. The fan has no relative dim of its own, so the driver ramps the level itself, with one request in flight and the latest value winning, and tells the proxy only where a ramp starts and where it ends.
3. **Structure:** option (a), one driver with a fan proxy and a light_v2 proxy, which is how the stock driver is built. It is documented, and the stock driver, one driver exposing the fan and its light, already runs on the house. It gives one address, one HTTP speaker, one ordered queue, and a one-for-one swap for the stock device. It needs proxy commands dispatched by proxy binding, because the fan and light proxies both send ON, OFF and TOGGLE.
4. **Fallback:** option (b), a fan driver that creates a light child device, which is the Hue bridge-and-light pattern. Take it if the read-only Composer checks of the stock device (H1–H3) show that a two-proxy device presents the light's links or settings badly.
5. **Minimum OS:** the light side needs **3.3.0**; 3.3.3 also avoids a 3.3.2 defect in the Brightness Stop link. The fan side decides whether to go higher: 3.4.2 only if the v1 contract relies on `proxy_fan_speed_connections` alone, which the fan research recommends against (`docs/fan-proxy-research.md` §6). The value is documented only as an auto-update gate, so the driver also checks the OS version at run time.
6. **Lua:** LuaJIT with Lua 5.1 semantics. On the house, `_VERSION` reads "Lua 5.1" and the LuaJIT version is 2.1.
7. **APIs:** `C4:url():Post()` for the JSON POSTs to the fan, rather than the legacy `C4:urlPost` or raw sockets. `C4:SetTimer` for timers. `C4:PersistSetValue` for the driver's own state; dealer settings belong to the proxy.
8. **Order of work:** the static capabilities and the connection definitions cannot be changed later without cost. So the read-only looks at the stock device (H1–H3) and the fan's request rate (H6) come before the first install.
9. **Tests:** there are ten, each under a minute. Only one needs the owner's hands (H10), and one needs his eyes for under 30 s (H5).

## 1. The light as a light_v2 device

### 1.1 Starting point (from the API research)

This note assumes the API research will confirm the following; every item is
ASSUMED until it does:

- The light has on/off and a brightness level.
- It has no colour and no controllable colour temperature.
- The API has no transition time and no relative or "step" dim.
- State comes back in the reply to each request, and by polling.

Where a different answer would change a decision below, the row says so.

### 1.2 Capabilities

Static capabilities are read when a device is created. If a later build
changes one, Composer asks "Restart Director?". Answering Yes does not load
the change; only the owner's controller reboot from System Manager does
(VERIFIED-house: HUE `docs/keypad-design.md` "Install findings").

A new driver's first install needs no reboot, as far as the record shows.
`hue_scene.c4z` was added to the house as a new driver ("successfully
added"), and its devices worked the same day with no reboot recorded
(VERIFIED-house: HUE `docs/design.md` "Composer Pro 3.4.2 UI" and "Scenes
build: verified on hardware"). That nothing at all is needed is ASSUMED;
H8 sees it on the first install.

So every static row below must be right before the first install. Dynamic
rows can change at run time with `DYNAMIC_CAPABILITIES_CHANGED` (LV2
35/_8-DYNAMICCAPABILITIESCHANGED.md).

| Capability | Value | Kind | Why | Status |
|---|---|---|---|---|
| `dimmer`, `set_level` | True | dynamic | The light dims. A model that only switches can drop `dimmer` at run time. | VERIFIED-doc `LV2 5/_5-DIMMER.md`, `5/_2-SETLEVEL.md` |
| `supports_target` | True | dynamic | The Brightness Target API (`SET_BRIGHTNESS_TARGET` in, CHANGING/CHANGED out). The best-practice page asks every new light_v2 driver to use it, and certification has required it since 3.3.0. | VERIFIED-doc `LV2 5/_4-SUPPORTSTARGET.md`, `PP 62.2/_0-HEADER.md` ("Brightness Target API"); VERIFIED-house (the Hue light) |
| `ramp_level`, `on_off` True; `min_max` False | as listed | deprecated in 3.3.2 | These are the Hue light's values. The proxy still reads `ramp_level` when `dimmer` changes. | VERIFIED-doc `LV2 3/_10-WHATSNEWIN332.md`, `35/_8-…`; VERIFIED-house (HUE `src/hue_light/driver.xml`) |
| `click_rates` | True if the driver ramps taps (§1.5), else False | static | True shows the click rate settings and the Fast On/Off presets. False makes taps immediate, as on the Hue Scene device. | VERIFIED-doc `LV2 5/_11-CLICKRATES.md`; VERIFIED-house (HUE `docs/status.md`, Hue Scene: "taps are immediate") |
| `click_rate_min`, `click_rate_max` | 0, 86400000 | static | Declare the maximum explicitly. Its own page gives a default of 1 ms, but the proxy's capability variable shows 86400000, and the house delivered a 750 ms click rate. | VERIFIED-doc `LV2 5/_12-CLICKRATEMIN.md`, `5/_13-CLICKRATEMAX.md`, `30/_0-HEADER.md` (variable 6661); VERIFIED-house (HUE `docs/design.md` "Hardware pass of 2026-10-25 night") |
| `hold_rates`; `hold_rate_min`, `hold_rate_max` | True; 1000, 86400000 | static | The hold rate settings, at the documented defaults. | VERIFIED-doc `LV2 5/_14`, `_15`, `_16` |
| `supports_default_on` | True | static, deprecated | The On preset reaches the driver as `SET_PRESET_LEVEL` and is used by a top tap; this path is verified on the house. Never declare it together with `brightness_on_mode_*` (3.3.2+), which the docs warn against. The alternative is §6 Q1. | VERIFIED-doc `LV2 5/_32-SUPPORTSDEFAULTON.md`, `5/_6`, `5/_7`; VERIFIED-house (HUE `docs/keypad-design.md`, #59) |
| `has_leds` | True | static | Shows the LED colour settings, which arrive as `SET_BUTTON_COLOR`. | VERIFIED-doc `LV2 5/_28-HASLEDS.md`; VERIFIED-house |
| `reduced_als_support`; `supports_brightness_stop` | True; True | static; dynamic | Advanced Lighting Scenes drive the light with `SET_BRIGHTNESS_TARGET` and end a held scene ramp with `SET_BRIGHTNESS_STOP`. A reduced-ALS driver should declare the stop, and a ramp the driver runs itself can really stop. | VERIFIED-doc `LV2 5/22-REDUCEDALSSUPPORT.md`, `5/_29`, `45/_1.3-REDUCEDALSSUPPORT.md` |
| `supports_color`, `supports_color_correlated_temperature` | False | dynamic | No colour. If CCT is found, one `DYNAMIC_CAPABILITIES_CHANGED` carrying both flags and the Kelvin range switches it on at run time, followed at once by the current colour. | VERIFIED-doc `LV2 5/_30`, `5/_31`, `35/_8`; VERIFIED-house (the Hue light switches colour on this way) |
| `hide_proxy_properties` | False | static on 3.x (dynamic from 4.2.1) | Shows the proxy's settings page on the light: Default On Brightness, click and hold rates, LED colours. | VERIFIED-doc `LV2 5/_38`, `3/_6-WhatsNewin421.md`; VERIFIED-house (HUE #59, `docs/design.md` "Hardware pass of 2026-10-25 night") |
| `has_button_events` | False | static | The fan's own remote and wall control never reach Control4 as button presses. | VERIFIED-doc `LV2 5/_26-HASBUTTONEVENTS.md`; that the presses never arrive is ASSUMED (API research) |
| `cold_start` | False | dynamic since 3.4.2 | Not used. | VERIFIED-doc `LV2 5/_8-COLDSTART.md` |
| `advanced_scene_support`, `load_group_support`, `supports_broadcast_scenes`, `supports_multichannel_scenes` | False | static | Not used. | VERIFIED-house (HUE `src/hue_light/driver.xml`) |
| `buttons_are_virtual` | True | deprecated in 3.3.2 | The Hue light's value. | VERIFIED-house (HUE `src/hue_light/driver.xml`) |

Left out:

- `supports_color_stop` (colour only).
- `brightness_rate_min`/`max` (3.3.2+, meant for drivers without buttons).
- `multi_click` and `disable_flash`.
- The nesting capabilities (§2).

In option (a) the fan proxy's capabilities share the same `<capabilities>`
block. No name occurs in both lists (VERIFIED-doc: `FAN 43/` against `LV2
5/`). That each proxy ignores the other's names is ASSUMED; the stock driver
must do the same, and H3 shows how.

### 1.3 Commands the driver handles (light proxy and links)

| Arrives as | Parameters | What the driver does | Status |
|---|---|---|---|
| `SET_BRIGHTNESS_TARGET` | `LIGHT_BRIGHTNESS_TARGET`, `RATE` (ms) | Sends CHANGING at once, then runs the ramp of §1.5 (RATE 0 is one request). Sends CHANGED when the fan confirms, or after RATE + 1 s. | VERIFIED-doc `LV2 10/_1.5-SETBRIGHTNESSTARGET.md`; VERIFIED-house (a Navigator slider move arrives with RATE 0; HUE `docs/design.md` "Lights: verified on hardware") |
| `ON`, `OFF`, `TOGGLE`, `SET_LEVEL` / `RAMP_TO_LEVEL` {`LEVEL`, `TIME`} | as listed | Same path. ON means 100 %; TOGGLE goes by the state shown, as on the Hue light. | VERIFIED-doc `LV2 10/_7-TOGGLE.md`; VERIFIED-house (these arrive through `SendToDevice` into the proxy) |
| `SET_BRIGHTNESS_STOP`, `STOP_SCENE_RAMP` | none / `SCENE_ID` | Freezes the ramp where it is, sends that level to the fan, then CHANGED. | VERIFIED-doc `LV2 10/_21.5`, `45/_1.3`; that `STOP_SCENE_RAMP` reaches a reduced-ALS driver is ASSUMED |
| `RAMP_SCENE_UP`, `RAMP_SCENE_DOWN` | `SCENE_ID` | A ramp toward 100 % or 1 % at the hold rate. | VERIFIED-doc that reduced ALS requires them (`LV2 45/_1.3`, `45/_4.1`); that they are delivered is ASSUMED (the Hue light handles neither and never saw them) |
| `BUTTON_ACTION` | `BUTTON_ID` 0 top, 1 bottom, 2 toggle; `ACTION` 1 press, 2 release as click, 0 release after hold | Echoes it back first, then feeds the press machine. | VERIFIED-doc `LV2 10/_1-BUTTONACTION.md`; VERIFIED-house (HUE `src/common/device.lua`) |
| `DO_PUSH`, `DO_CLICK`, `DO_RELEASE` on binding 200, 201 or 202 | the binding id names the button | Feeds the press machine. | VERIFIED-doc `PP 62/_1-KEYPADBUTTONLINKBINDINGS.md`; VERIFIED-house (HUE `docs/keypad-design.md` "Hardware findings") |
| `REQUEST_BUTTON_COLORS` on a link | none | Sends `BUTTON_COLORS` and `MATCH_LED_STATE` on that link. | VERIFIED-doc `PP 62/_1`; VERIFIED-house |
| `SET_BUTTON_COLOR` | `BUTTON_ID`, `ON_COLOR`, `OFF_COLOR` (the docs print them with spaces; accept both spellings) | Stores and persists the colour, then sends `BUTTON_COLORS` and `BUTTON_INFO`. | VERIFIED-doc `LV2 10/_12-SET_BUTTON_COLOR.md`; VERIFIED-house |
| `SET_PRESET_LEVEL` {`LEVEL`}; `SET_CLICK_RATE_UP`/`DOWN`, `SET_HOLD_RATE_UP`/`DOWN` {`RATE`} | as listed | Checks the range, persists the value, and answers with `PRESET_LEVEL` / `CLICK_RATE_*` / `HOLD_RATE_*`. | VERIFIED-doc `LV2 10/_6`, `_8`, `_9`, `_10`, `_11`, `_22` (the driver must answer); VERIFIED-house (HUE #59) |
| `DYNAMIC_ON`, `DYNAMIC_OFF` | none | Not handled. A driver without on-mode support gets the On preset as a `SET_BRIGHTNESS_TARGET` instead. | VERIFIED-doc `LV2 10/_1.2`, `_1.3`; VERIFIED-house (the Hue light handles neither, and Navigator slider moves, off included, arrive as `SET_BRIGHTNESS_TARGET`; HUE `docs/design.md` "Lights: verified on hardware") |
| `SYNCHRONIZE` | none | Reports online state and level. | ASSUMED (the Hue light handles it; this doc set does not document it) |

**Routing.** In option (a) the fan proxy also sends `ON`, `OFF` and `TOGGLE`
(`FAN 41/_1-ON.md`, `_2-OFF.md`, `_3-TOGGLE.md`). So the driver must pick
every handler by proxy binding first and by command name second (§2.3).

### 1.4 Notifications the driver sends

| To | Notification | When | Status |
|---|---|---|---|
| light proxy | `LIGHT_BRIGHTNESS_CHANGING` {`LIGHT_BRIGHTNESS_CURRENT`, `LIGHT_BRIGHTNESS_TARGET`, `RATE`} | Once at the start of every target, ramp or hold. For a hold, the target is the end of the range. | VERIFIED-doc `LV2 35/_10.3-LIGHTBRIGHTNESSCHANGING.md`, `PP 62.2` |
| light proxy | `LIGHT_BRIGHTNESS_CHANGED` {`LIGHT_BRIGHTNESS_CURRENT`} | Once at the end of each change; also at start-up and whenever the fan comes back online. Always a whole percent, never 0 while on. | VERIFIED-doc `LV2 35/_10.2`; VERIFIED-house (a decimal level showed as 0 %/off on OS 3.4.2; HUE `docs/design.md` "Lights: verified on hardware") |
| light proxy | `ONLINE_CHANGED` {`STATE`} | When the fan becomes reachable or unreachable. The proxy starts as online and disables its controls while offline. | VERIFIED-doc `LV2 35/_15-ONLINECHANGED.md` |
| light proxy | `BUTTON_ACTION` echo; `BUTTON_INFO` {`BUTTON_ID`, `ON_COLOR`, `OFF_COLOR`, `CURRENT_COLOR`} | The echo after each action; `BUTTON_INFO` on each on/off change. | VERIFIED-doc `LV2 10/_1`, `35/_2-BUTTONINFO.md`; VERIFIED-house |
| light proxy | `PRESET_LEVEL`, `CLICK_RATE_UP`/`DOWN`, `HOLD_RATE_UP`/`DOWN`, each as the bare value | At late init and after every `SET_*`. | VERIFIED-house: the proxy reads the documented table form as 0 (HUE `src/common/device.lua`, `SETTINGS` comment); documented form in `LV2 35/_16`, `_5`, `_10` |
| links 200–202 | `MATCH_LED_STATE` {`STATE`} as a COMMAND; `BUTTON_COLORS` as a NOTIFY | On each on/off change, at late init, and when a keypad is bound to a link (`OnBindingChanged`). | VERIFIED-doc `PP 62/_1`, `API 25/_6-SendToProxy.md` (bindings below 1000 default to COMMAND); VERIFIED-house |

Never send `LIGHT_LEVEL`, and never send a CHANGED for each step of a ramp.
Step-by-step level notifications slow the whole system down (`LV2
35/_12-LIGHTLEVEL.md`; `PP 62.2`).

### 1.5 Rates, ramps and holds without a native dim

The Hue lights ramped on the device itself (VERIFIED-house: HUE
`docs/keypad-design.md` "Light parity", `docs/design.md` "Keypad and scene
dimmer: verified on hardware"):

- A click rate or a slider's `RATE` became Hue's own transition time.
- A hold became Hue's relative dim: `dimming_delta` up or down over the hold rate, then `stop` on release.

The fan's light is assumed to have neither (ASSUMED, API research). So:

- **The driver runs the ramp.** It has two parts:
  - A generator moves a wanted level from the current level to the target at the requested rate. This is the Hue light's 100 ms estimate tick (`start_ramp` in HUE `src/hue_light/driver.lua`).
  - A sender keeps at most one request in flight to the fan, shared with the fan's own commands. When the previous request has answered and a minimum gap has passed, it sends the latest wanted level. The latest value wins, so nothing piles up.

  A RATE of 0 is a single request.
- **The proxy hears only the start and the end:** CHANGING with the target and the rate, then CHANGED with the level the light ended at (`LV2 35/_12`, `PP 62.2`).
- **Holds** follow the Hue machine's rules:
  - Top, or toggle while the light is off, ramps toward 100 % at the hold rate.
  - Bottom, or toggle while on, ramps toward 1 %.
  - Bottom while off does nothing.
  - From off, the light turns on at 1 %, and the ramp up starts 600 ms later.
  - On release, the ramp freezes, the reached level is sent, and CHANGED follows.

  `SET_BRIGHTNESS_STOP` and `STOP_SCENE_RAMP` stop a ramp the same way. This is a real stop, which Hue could not do.
- **Reports that arrive during a ramp are not passed on.** The Hue light's pending-target rule decides when CHANGED goes out: on the matching report, or after rate + 1 s (`arm`/`settle` in HUE `src/hue_light/driver.lua`). This rule also keeps late or out-of-order reports, the stock driver's fault, away from the tile and the LEDs.
- **Still unknown** (tests H5 and H6):
  - how fast the fan accepts requests;
  - whether the fixture fades between steps;
  - whether frequent writes cost the fan anything, such as flash wear (ASSUMED harmless).

  Start with a 250 ms gap (ASSUMED).
- **H6 decides `click_rates`.** If the fan cleanly takes about four requests a second, declare `click_rates` True and ramp taps too. If not, declare it False, so taps are immediate, and let holds step as fast as the fan allows. The capability is static, so decide before the first install.

### 1.6 What carries over from the Hue drivers

| Hue piece (HUE file) | For the fan's light |
|---|---|
| The press/click/release machine: a press still down at 400 ms is a hold; a hold from off dims up 600 ms after the turn-on at 1 %; a click within 1 s of a hold's release is ignored (`src/common/device.lua`, `button_action`) | as it is |
| The two routes into that machine: `BUTTON_ACTION`, echoed back, and `DO_PUSH`/`DO_CLICK`/`DO_RELEASE` on links 200–202 | as they are, with the proxy binding as a parameter (5002 in option a) |
| Keypad settings: the `SET_*` commands, range checks, persistence and bare-value answers (`SETTINGS`) | as they are |
| LEDs: `MATCH_LED_STATE` on 200–202, `BUTTON_INFO`, `BUTTON_COLORS`, persisted colours, and the defaults (top and toggle lit while on, bottom lit while off) | as they are; "on" means the fan's light is on |
| LED refresh when a keypad is bound to a link (`OnBindingChanged` in `src/hue_light/driver.lua`) | as it is |
| The target path: CHANGING at once, CHANGED on confirmation or after rate + 1 s (`set_brightness`, `arm`, `settle`) | as it is; the confirmation is the fan's report |
| Whole-percent levels (`src/hue_light/light/state.lua`) | as they are |
| The legacy ON/OFF/TOGGLE/SET_LEVEL/RAMP_TO_LEVEL commands and the ALS stops | as they are, routed by binding; the stops now really stop |
| The hold as Hue's `HUE_DIM` relative dim, with its stop and fallback level | **replaced** by the driver's own ramp (§1.5); the estimate tick and the messages to the proxy stay |
| A click or slider `RATE` as Hue's transition time | **replaced** by the driver's ramp, or ignored when `click_rates` is False |
| Colour: `SET_COLOR_TARGET` and the xy/CCT mapping | not in v1, unless CCT is found |
| The bridge binding, hello/configure, the binding re-check and the goodbye | only in options (b) and (c) |
| The `Raise Level By` / `Restore Saved Level` programming commands (`docs/relative-level-design.md`) | optional later; they are Lua and XML only, with no capability change |

### 1.7 House facts that carry over (all VERIFIED-house)

1. **The light's links are declared by the driver.** Top, Bottom and Toggle are connections the driver declares: ids 200–202, class BUTTON_LINK, on the provider side, listed under the device's Control Outputs. The proxy adds only the Brightness Stop and Color Stop links, although the proxy reference says it creates all three (`LV2 10/_1`). Existing devices pick up added connections with an ordinary update (HUE `docs/keypad-design.md` "Hardware findings").
2. **Keypad bindings.** Binding a keypad button's link switches that button's LED Behavior to Follow Connection, and disconnecting does not switch it back. The Windows session can make the binding by a synthetic drag from the keypad's own row (HUE `docs/composer-remote.md`, "Learned 2026-10-27").
3. **Declared links can do nothing.** A driver can declare links it does not implement: the stock fan driver's links bound normally and did nothing (same section).
4. **What changes need what.** A capability change needs the owner's controller reboot; Lua and connection changes take effect at once. Whether a device shows the driver's icon depends on whether the build that created it declared one, so icons belong in the first build (HUE `docs/keypad-design.md` "Install findings"; `docs/design.md` "Composer Pro 3.4.2 UI", build 135).
5. **Settings answers carry the bare value**, not a table (HUE `src/common/device.lua`).
6. **Levels go to the proxy as whole percents** (HUE `docs/design.md` "Lights: verified on hardware").
7. **A test path through the proxy.** `SendToDevice` into a light_v2 proxy acts on ON, OFF, SET_LEVEL and RAMP_TO_LEVEL, but `SET_BRIGHTNESS_TARGET` sent that way does nothing. This gives the dev loop a way to drive the light (same section).
8. **The settings page.** With `hide_proxy_properties` False, the proxy's settings page is shown, and a changed value arrives at once, for example `SET_HOLD_RATE_DOWN RATE=2000` (HUE `docs/design.md` "Hardware pass of 2026-10-25 night").

## 2. Driver structure

### 2.1 The four options compared

| | (a) one driver, fan + light_v2 proxies | (b) fan driver + a light child it creates | (c) two drivers, bound by hand | (d) two independent drivers |
|---|---|---|---|---|
| Documented | Yes. A driver may declare several proxies, each with its own binding (FUND `8/_1-SINGLEANDMULTIPROXIES.md`, `11/_5-PROXYBINDINGMULTIPLE.md`; XML `15/_31-proxies.md`, `15/_32-proxy.md`; FAN and LV2 `2/_1-INTRODUCTION.md`). VERIFIED-doc | Yes. `C4:AddDevice` (3.2.0+, documented for user-initiated use only), `C4:Bind`, `C4:SendToDevice` (API `9/_0.1`, `9/_1`, `32/_19`). VERIFIED-doc | Yes. Control bindings (FUND `11/_3`; API `9/_1`). VERIFIED-doc | Yes, as any IP driver. VERIFIED-doc |
| OS 3.x | The stock driver exposes the fan and its light from one driver and runs on the house on 3.4.3. VERIFIED-house (owner's test of 2026-10-27; `README.md` "Why a new driver"). That its light is a light_v2 proxy is ASSUMED (H3). | The Hue bridge-and-light pattern ran 47 lights on 3.4.2. VERIFIED-house (HUE `docs/design.md` "Lights: verified on hardware") | The Hue bridge binding, made with `C4:Bind`. VERIFIED-house (HUE `docs/design.md` "Project APIs"). That the Windows session can make such a binding by synthetic drag is ASSUMED; it is verified only for a keypad's Button Link. | ASSUMED |
| OS 4.x | No "What's New" entry touches proxies, bindings or AddDevice (API `3/_5`–`_7`; FUND `3/_5`, `_6`; LV2 `3/_6`; the fan reference has no 4.x entry at all). ASSUMED unchanged | The same. 4.0 adds helpers (`GetBoundPartner`, `GetProtocolDeviceById`; API `9/_5.8`, `9/_8.5`) | The same | The same |
| What Composer shows | The fundamentals say an instance is loaded for each proxy when the device is added, each named from its proxy's `name` attribute (FUND `11/_5`, `8/_2`). VERIFIED-doc. A proxy is a child of its protocol device, which sits in a room (VERIFIED-house: `OnItemAdded` parents, HUE `docs/design.md` "Composer Pro 3.4.2 UI"). ASSUMED (H1): one item per proxy; which item carries the driver's Properties, Actions, Lua and Documentation tabs; whether one item can be moved to another room. | Two devices, each with its own tabs, the light in the room `AddDevice` names. VERIFIED-house (Hue). From 3.4.2 the light can be nested under the fan with `nesting_driver_is_parent` / `nested_driver_is_child`, which PP `3/_7` says work for any proxy. VERIFIED-doc, never tried here | Two devices, as in (b) | Two devices, each with its own address |
| Links | The light's Top/Bottom/Toggle are the driver's own connections. The `proxybindingid` attribute ties a connection to a proxy (FUND `11/_1`; its examples are AV connections only). Where the links then appear is ASSUMED (H2). The fan's speed links come from the fan proxy (fan research). | The light's links sit on the light device, exactly as on the Hue light (VERIFIED-house), plus the light-to-fan binding in Connections | As in (b) | Each driver has its own |
| Owner and dealers | Matches the stock driver: add one driver, set one address, get a fan and a light | One more file and an "Add Light" click; familiar from bridges and hubs | One manual binding per fan | Two addresses to keep in step |
| Talking to the fan | One driver, one request queue, one poll | The fan driver alone talks to the fan (one queue, one poll); the light goes through `SendToDevice` | As in (b) | Two pollers and two command streams to one small device, with no shared order (the stock driver's class of fault) |
| Code | One Lua instance; dispatch by proxy binding, because both proxies send ON, OFF and TOGGLE | Two drivers, a message protocol, the binding re-check after a restart (a bound device can read as unbound at late init; HUE `docs/keypad-design.md`), and the delete, rebind and restore cases | As in (b), without AddDevice | Duplicated state, two IP settings, double the traffic |
| Later changes | A device's proxies are fixed when it is created; adding or removing one needs a new driver (FUND `14/_2-DRIVERUPDATECONSIDERATIONS.md`). VERIFIED-doc. A fan without a light kit still has a light item. | A second light is just another child of the same driver | As in (b) | As in (b) |
| Replacing the stock driver | One device for one | Two devices for one | Two for one, plus a binding | Two for one |

### 2.2 Recommendation: option (a)

1. **One light per fan.** A fan has at most one light. The create, bind, hello, re-check and tombstone machinery of option (b) was built in the Hue project for one bridge with 47 lights. For a single light it adds ways to fail and no benefit.
2. **One owner of the connection.** Fan and light requests share one queue and one poll, and their answers come back in the order they were sent (§1.5). That ordering is exactly what the stock driver lacks.
3. **Expected shape.** It is what the owner runs today and what a dealer adding a fan driver expects: one driver, one address, a fan and a light.
4. **Known to work.** It is documented, and the house already runs a single driver for a fan and its light on OS 3.4.3.
5. **Reuse.** The Hue light's verified pieces carry over with a few parameters changed (§2.3).

**Condition and fallback.** Before the v1 contract, the read-only checks H1–H3 on the stock device must show that the light item gets its own links and its own proxy settings page. If the light's links can only appear under the fan, or the light item has no settings page, take option (b) instead. Every piece of (b) has a verified precedent on this house.

**Costs accepted with (a):**

- A fan without a light kit still gets a light item. The driver reports it offline and says why in Status.
- The proxies can never change through an update, so the light proxy is in the driver from its first build.

### 2.3 What option (a) changes in the shared modules (`src/common/`, from the Hue repo)

- **`dispatch.lua`.**
  - Today it picks proxy handlers by command name only (HUE `src/common/dispatch.lua`, `received_from_proxy`).
  - In (a) the fan proxy (5001) and the light proxy (5002) both send ON, OFF and TOGGLE, so handlers must be keyed by binding first, then by command.
  - The light's links (200–202) and the fan's link bindings are routed the same way.
  - Every command carries the binding it came on (VERIFIED-doc: FUND `8/_1`; API `25/_5-ReceivedFromProxy.md`).
- **`device.lua`.**
  - It hard-codes proxy binding 5001 and bridge binding 1. The light's proxy binding becomes an option.
  - The bridge parts (bound bridge, hello, re-check, goodbye) become optional.
  - Its warning for an unknown link binding should instead hand that binding to the fan side.
- **`driver.xml`.**
  - Two `<proxy>` entries: the fan on 5001 with `primary="True"`, and light_v2 on 5002. Each has a `name` and icons, since the icon is fixed when the device is created (XML `15/_32`; §1.7 item 4).
  - One `<capabilities>` block holding both proxies' capabilities.
  - Light links on 200–202. Reserve those ids for the light (the Hue ids) and let the fan side pick others.
  - Whether the light links carry `proxybindingid="5002"` follows what H2 and H3 show. A connection's definition must not change after release (FUND `14/_2`), so settle it before the first install.
- **One Properties page.** The fan and the light share the driver's Properties page; which item shows it is ASSUMED (H1). Name the light's rows so they read correctly there, and keep texts under about 75 characters, because Composer clips longer values (VERIFIED-house: HUE `docs/design.md` "Composer Pro 3.4.2 UI").

### 2.4 Replacing the stock driver (any option)

- **No conversion.** Composer cannot turn a device of one driver into a device of another. An update only replaces a driver with a newer version of the same file, and it updates every device of that file (VERIFIED-house: HUE `docs/design.md` "Composer Pro 3.4.2 UI").
- **The order:**
  1. Add the new device beside the stock one.
  2. Move the keypad links (the Windows session can drag them).
  3. Rebuild the programming. Most of the house's keypad scripts and the settle timer simply go.
  4. Delete the stock device last. Deleting it removes its connections and the programming that names it (ASSUMED).
- **Forbidden: `<replaces>` naming the stock file.** Director would remove the replaced driver from the project and from Composer's driver database without warning (XML `15/_33.5-replaces.md`). That is a destructive automation with no click.
- **Forbidden: reusing the stock driver's file name or identity** to "update" it in place. Its proxies and connections would have to match exactly (FUND `14/_2`), and it would impersonate WAC's driver.
- **During the overlap,** two drivers poll the same fan, so keep the overlap short. That the extra load does the fan no harm is ASSUMED.
- **On OS 4.0+,** `GetBoundPartner`, `GetCapabilityById` and `GetProtocolDeviceById` are documented as helpers for moving configuration from an old device to a new one (API `3/_7-WhatsNewin400.md`). Nothing on OS 3.4 does this.

## 3. Minimum OS

### 3.1 Candidates

| Version | What it adds that the driver could use | Excludes | Source (VERIFIED-doc) |
|---|---|---|---|
| 3.0.0 | LuaJIT (`jit="1"`), the OS 3 light_v2, keypad Button Linking (`DO_PUSH`…), `C4LuaUrl:Post` | OS 2.x | FUND `7/_1-OS3LUAJIT.md`; LV2 `3/_20`; KP `3/_20-WhatwasNewinOS3.md`; API `35/_10-Post.md` |
| 3.2.0 | `C4:AddDevice` (option b only); the init reason passed to `OnDriverInit`/`LateInit` | 3.1.x and older | API `3/_17-WhatsNewin320.md`, `9/_0.1` |
| 3.3.0 | The Brightness Target API (`SET_BRIGHTNESS_TARGET`, CHANGING/CHANGED, `supports_target`); strict enforcement of min/max capabilities; `sort_order` for actions and events. The Hue drivers' declared minimum. | 3.2.x and older | LV2 `3/_12-WHATSNEWIN330.md`; PP `62.2`; FUND `15/_6-ACTIONS.md`, `12.5/_10`; HUE `src/hue_light/driver.xml` |
| 3.3.2 / 3.3.3 | On-mode capabilities, `supports_brightness_stop`, `DYNAMIC_ON`. 3.3.2 has a defect: keypad buttons bound to the Brightness Stop link do not work; fixed in 3.3.3. | 3.3.1 and older (3.3.3 excludes 3.3.2 too) | LV2 `3/_10`, `5/_29` |
| 3.4.2 | `proxy_fan_speed_connections` (fan); nesting for any proxy; `multi_click`; `disable_flash`; `cold_start` dynamic | 3.4.1 and older | PP `3/_7-WHATSNEWIN342.md`; FAN `43/_4.5-proxyfanspeedconnections.md` |

### 3.2 What `<minimum_os_version>` actually does

- **What is documented.** The tag is documented only for the Driver Update Agent, as the OS an automatic update requires (FUND `14/_1-UPDATINGRELEASEDDRIVERS.md`), and as a Jumpstart setting that defaults to 3.0.0 (FUND `26.5/_3-Configuration.md`).
- **Install-time refusal is unknown.** Whether Composer refuses to add a driver to an older controller is ASSUMED; H7 settles it.
- **So the driver also checks at run time.** It reads `C4:GetVersionInfo().version` (API `5/_2-GetVersionInfo.md`; safe before late init per FUND `28/_2-DRIVERINIT.md`), and its Status says what an older OS lacks.

### 3.3 OS 4.x differences documented

- **LV2 4.2.1:** `hide_proxy_properties`, `hide_proxy_events`, `hide_proxy_commands`, `hide_proxy_conditionals_loops` and `advanced_scene_support` become dynamic (LV2 `3/_6-WhatsNewin421.md`).
- **API 4.0.0** (API `3/_7-WhatsNewin400.md`):
  - new helpers: `GetBoundPartner`, `GetCapabilityById`, `GetProtocolDeviceById`;
  - `C4:Encrypt` loses its low-level ciphers;
  - `GetText` is deprecated;
  - an MQTT client is added;
  - `GetTime` gains units;
  - UDP changes, part of retiring LuaSocket.
- **API 4.1.0:** `GetCommands` (dynamic commands), `GetRoomID`, `GetNonBindingConsumerDevices`. The fundamentals add dynamic commands and conditionals, and Jumpstart (API `3/_6-WhatsNewin410.md`; FUND `3/_5-WhatsNewin400.md`, which despite its name covers 4.1.0).
- **API 4.2.0:** `GetDriverConfigInfoById` (API `3/_5-WhatsNewin420.md`).
- **What has no 4.x entry:** the fan reference has none, and the general proxy guide's newest entry is 3.4.2 (FAN `3/`, PP `3/`).
- **Effect on this driver:** none of these changes touches the light side or the structure. The date-versioned Composer Pro releases are not covered by this doc set.

### 3.4 Recommendation: 3.3.0 from the light side; the fan side may raise it

- **The light side needs 3.3.0**, for the Brightness Target API. That is also the Hue drivers' value, and it covers the house (3.4.3). Prefer 3.3.3 if dealers are expected to bind the light's Brightness Stop link, because of the 3.3.2 defect (§3.1).
- **Raise it to 3.4.2 only if** the v1 contract relies on the fan proxy's `proxy_fan_speed_connections` alone for the per-speed links. The fan research recommends against that; it would have the fan not raise the floor (`docs/fan-proxy-research.md` §6).
  - Trade-off: 3.4.2 excludes every controller on 3.4.1 or older. Those can keep the stock driver.
- **No dual path for the same links.** Per-speed links declared statically in `driver.xml` would also exist on 3.4.2+ beside any links the proxy creates. Connections can only ever be added, never removed (FUND `14/_2`). So for the per-speed links it is one mechanism or the other, decided before the first release.
- **Whatever the value,** the run-time check (§3.2) says in Status what the running OS lacks; for example, that the proxy's speed links need 3.4.2.

## 4. Lua sandbox and APIs

### 4.1 Lua

- **LuaJIT with Lua 5.1 semantics.** `<script file="driver.lua" jit="1"/>` loads the driver under LuaJIT, which follows the Lua 5.1 standard (VERIFIED-doc: FUND `7/_1`; XML `15/_71-script.md`).
- **Measured on the house** (VERIFIED-house: the Hue dev loop's startup reports, builds 30 to 309, kept on the VM in `~/projects/c4-hue-driver/build/dev/reports.jsonl`, not in the public repo):
  - `_VERSION` is "Lua 5.1";
  - `jit.version` is "LuaJIT 2.1.1700206165";
  - `bit`, `setfenv`, `loadstring` and `package.loaders` are present.
- **The fallback.** FUND `7/_1` says a driver that fails LuaJIT's syntax check is retried with PUC Lua, which it calls 5.0-compatible. The same page also says a driver first loaded with LuaJIT gets no fallback (§7). Either way, the rule is the same:
  - Write code that loads under `lua5.1`, the local test interpreter.
  - Use nothing from Lua 5.2 or later: no `goto`, no `//`, no `utf8`, no 5.2 table functions.
  - Do not depend on `bit`.
- **`require` works for modules packed in the `.c4z`.** Every Hue driver requires its `common.*` modules (VERIFIED-house).
- **`io.popen` is gone since 3.3.0** (VERIFIED-doc: API `3/_13-WhatsNewin330.md`).
- **`C4` cannot be patched.** `C4` is userdata, so code typed into the Lua window cannot replace its methods (VERIFIED-house: HUE `docs/design.md` "Hardware pass of 2026-10-25 night").

### 4.2 HTTP to the fan: which API

| | `C4:url()` | `C4:urlPost` (legacy) | Network binding / TCP client |
|---|---|---|---|
| Status in the docs | Current. It replaces `urlGet`, `urlPost`, `urlPut`, `urlDelete` and `urlCustom` (API `35/_0-Header.md`). `C4:url` is 2.10.5+, and `:Post(url, body, headers)` is 3.0.0+ (`35/_10`). VERIFIED-doc | Superseded by `C4:url`. Its result arrives in the global `ReceivedAsync(ticket, data, code, headers, err)` (`37/_2-ReceivedAsync.md`). Its own page is missing from this doc set. VERIFIED-doc | `CreateNetworkConnection` + `NetConnect` + `SendToNetwork` + `ReceivedFromNetwork` (`32/_1`, `_23`, `_20`, `_15`), or `C4:CreateTCPClient` (`14/_1-Overview.md`). VERIFIED-doc |
| Fit for JSON POSTs | Callbacks, status codes and options per request: `timeout` (default 300 s), `connect_timeout` (default 5 s), and `fail_on_error` (default true; set it to false to read error bodies) (`35/_12-SetOption.md`) | One global callback for every request, matched by ticket | A raw socket, so HTTP framing has to be written in Lua; the Hue raw-stream design estimated about 400 lines. It only pays for a long-lived connection, which the fan is assumed not to offer (ASSUMED, API research). |
| On the house | The Hue drivers' transport, including plain-HTTP POSTs with JSON bodies: the Hue dev loop's `/log` and `/report` to the VM. VERIFIED-house (HUE `docs/dev-loop.md`) | Not used | Not used |

**Use `C4:url()`.** It has these behaviours (VERIFIED-house unless marked;
HUE `docs/design.md` "`C4:url` transfer scheduling on OS 3.4.2" and
"Concurrent transfers"):

- **One transfer per host at a time.** Transfers to a host are queued one after another, keyed by the host text. The docs have `C4:urlSetOption("max_host_connections", n)`, with a default of 1 and a range of 1 to 5 (VERIFIED-doc: API `37/_11-urlSetOption.md`). That default is probably the cause (ASSUMED). Leave it at 1: one request in flight is what the fan needs anyway.
- **At most four `C4:url` transfers** run at once across the controller.
- **Never start a transfer inside `OnHeaders` or `OnBodyChunk`:** it fails at once with curl error 2. Start it from a timer or from `OnDone`.
- **`Cancel()` does not end a streaming transfer** that is already running.
- **The default headers include `Connection: close`,** so every request opens a fresh connection (VERIFIED-doc: API `37/_10`, `37/_13`). Bodies are written with `C4:JsonEncode`.
- **Not before late init:** `C4:url` must not be called before `OnDriverLateInit` (VERIFIED-doc: FUND `28/_2`).

### 4.3 Timers

- `C4:SetTimer(ms, fn, repeat)` is available from 2.7.0. It returns an object with `Cancel()` (VERIFIED-doc: API `34/_1-SetTimer.md`).
- When Director falls behind, a repeating timer's callback gets the number of firings it skipped (same file).
- It must not be called in `OnDriverInit` (VERIFIED-doc: API `34/_1`; FUND `28/_2`).
- The Hue keypad machine's timers, from 100 ms to 1 s, run on the house (VERIFIED-house).

### 4.4 Persistence and JSON

- **`C4:PersistSetValue(name, value, encrypted)`**, with `PersistGetValue` and `PersistDeleteValue`, is available from 2.10.0 (VERIFIED-doc: API `26.5/_3`, `_4`):
  - Values can be numbers, strings, booleans or tables.
  - Writes go through a writer thread that starts just before late init, so a read right after a write can miss it.
  - Writing an empty value does not delete the key.
- **Lifetime on the house.** Persisted values survive an update in place and a reboot, and are lost when a device is deleted and re-added (VERIFIED-house: HUE `docs/design.md` "Storage").
- **What to persist this way:** the fan's identity, and the light's keypad settings and LED colours, as the Hue drivers do.
- **The `PersistData` table** (VERIFIED-doc: FUND `24/_1-PERSISTINGDRIVERDATA.md`; API `22/_5-PersistData_Table.md`):
  - Director saves it in a round-robin pass.
  - It is kept through a project save or backup, a Director restart and a driver update.
  - The fundamentals name light ramp rates and keypad LED colours as exactly the kind of data that belongs in the project file.
- **Backups are unknown.** Whether `PersistSetValue` data travels with a project backup is not documented (§6 Q6).
- **What not to persist:** runtime state such as the light's on/off (FUND `24/_1`).
- **Properties live in the project file**, including the fan's address.
- **JSON** (`C4:JsonEncode`, `C4:JsonDecode`):
  - JSON null decodes to an empty table unless asked otherwise (VERIFIED-doc: API `12/_3-JsonDecode.md`; VERIFIED-house: HUE `docs/design.md`).
  - `JsonEncode` writes Lua arrays as objects (VERIFIED-house).
  - The fan's request bodies are assumed to be flat objects (ASSUMED, API research).

## 5. Recommended design and the tests that settle it

### 5.1 The design (option a)

**One package.** `modernforms_fan.c4z` with two proxies: fan on 5001
(primary) and light_v2 on 5002, each with its own name and icons from the
first build. The minimum OS is as in §3.4: 3.3.0, unless the fan relies on
the proxy's speed links alone. The driver also checks the version at run
time.

| Element | Design | Status |
|---|---|---|
| Light proxy | `light_v2` on 5002 | VERIFIED-doc (multi-proxy); the Composer presentation is ASSUMED (H1) |
| Light capabilities | As in §1.2. `click_rates` and the on mode are decided by H6 and Q1 before the first install. | VERIFIED-doc; values VERIFIED-house through the Hue light, except `click_rates`, which is open |
| Light links | 200, 201, 202 as BUTTON_LINK provider connections, as in the Hue `driver.xml`; the `proxybindingid` question settled by H2/H3 | VERIFIED-house for the links themselves; their placement under a two-proxy device is ASSUMED |
| Commands and notifications | §1.3 and §1.4, dispatched by binding (§2.3) | VERIFIED-doc / VERIFIED-house as marked there |
| Keypad machine, settings, LEDs | Hue's `src/common/device.lua`, with the proxy binding as a parameter and the bridge parts optional | VERIFIED-house (taps on a light's links; holds and LEDs on a Hue scene device from a real keypad; the shared machine driven on a zone light through its Lua window) |
| Ramps | The driver's own ramp (§1.5) is the one path for targets, holds and ALS ramps. One request in flight per fan, shared with the fan proxy. The latest value wins per field (light on/level, fan speed, direction). The gap between requests comes from H6. | Design; the fan's tolerance is ASSUMED (H5, H6) |
| State in | Each request's reply plus the poll, applied in the order sent. The pending-target rule (Hue's `arm`/`settle`, with a 1 s fallback) decides when CHANGED goes out. CHANGED is also sent at start-up and on reconnect. `ONLINE_CHANGED` follows the fan's reachability for both proxies. | VERIFIED-house for the rule (Hue); the reply contents are ASSUMED (API research) |
| Persisted | Keypad settings and LED colours (as on Hue) and the fan's identity; not the light's level | VERIFIED-doc / VERIFIED-house (§4.4) |
| Transport | `C4:url():Post()`, JSON bodies, `timeout` of a few seconds, `fail_on_error` false | VERIFIED-doc; plain-HTTP POSTs from this controller are VERIFIED-house (the Hue dev loop); the fan's answers are ASSUMED (API research) |

### 5.2 Order of work

1. **Before the v1 contract** (structure): H1, H2, H3 and H7.
2. **Before the first install** (static capabilities and connection definitions): H4, H5 and H6. These decide `click_rates`, the on mode and the request gap.
3. **On the first dev build:** H8 and H9, then H10 with the owner, combined with the fan speed link test.

### 5.3 Hardware tests (each under a minute)

The standing approval covers everything below. Each brief to the Windows
session says so.

| # | Who | What | Settles |
|---|---|---|---|
| H1 | Windows session, read-only | In System Design, look at the stock fan device: how many items, their names, icons and order. Select each item and note which tabs it has (Properties, Actions, Documentation, Lua). Note whether the light item has the light_v2 settings page (Default On Brightness, click and hold rates, LED colours). Note whether the light item's menu offers a room change; read it, don't use it. | How Composer presents a two-proxy fan + light driver (option a) |
| H2 | Windows session, read-only | In Connections, select each stock item and list its Control Inputs/Outputs: under which item the 13 Button Links appear, and how the lower "BUTTON_LINK Output Devices" list names them. | Where driver-declared links appear in a two-proxy driver, and whether `proxybindingid` matters |
| H3 | Windows session, read-only | From the Windows VM's copy of the stock `.c4z` (a zip), read `driver.xml` and report facts only: the `<proxies>` (type, binding id, `primary`, `name`); whether one `<capabilities>` block mixes fan and light names; the 13 connections' ids, classes and any `proxybindingid`; `<minimum_os_version>`; and the `jit` attribute. Copy nothing into the repository; it is WAC's file. This is the same look as the fan research's T1 (`docs/fan-proxy-research.md` §8), so one read answers both. | How a working fan + light driver declares itself on this OS; whether its light really is light_v2 |
| H4 | VM (curl), within the API research's tests | Light only: on, off, levels 1, 50 and 100, and "on" without a level; record each reply body. | Whether "on" restores the previous level (Q1); whether a reply is the full state, i.e. the confirmation path |
| H5 | Owner's eyes, 30 s | The VM steps the light from 1 % to 100 % in 12 requests over 3 s, then back down. Does it look like a dim or a staircase? | Whether the driver's ramp is acceptable; whether the fixture fades between steps |
| H6 | VM | 20 level requests back to back, one in flight at a time: latency per request, errors or lost values, and the final state. | The request gap; `click_rates` True or False |
| H7 | Windows session | Add a throwaway copy of the scaffold driver, with its own `<name>` and file name, declaring a minimum OS of 9.0.0, and see whether Composer refuses or warns. Then delete it. Keep it separate from the fan research's probe package: a refused install would block that probe's tests. | Whether `<minimum_os_version>` is enforced at install, or only documents the requirement |
| H8 | Dev loop, first dev install | `C4:GetDeviceVariables(<light proxy id>)` (API `22/_12`), then read variable 6661, "Light Dynamic Capabilities" (LV2 `30/_0`). | That the first install loaded the capabilities without a reboot; the click and hold limits and dynamic flags the proxy actually uses; the `click_rate_max` question of §7 |
| H9 | Dev loop + the device's Lua window | Inject `DO_PUSH`/`DO_RELEASE`/`DO_CLICK` on 200–202 and `BUTTON_ACTION` on 5002 (tap, hold up, hold down, hold from off, click right after a hold). Send `ON`/`OFF`/`SET_LEVEL` into the light proxy and `ON`/`OFF` into the fan proxy with `SendToDevice`. Read the driver's requests and proxy messages in the log. | The press machine with the driver's own ramp; routing by binding |
| H10 | Owner's hands, under 1 min | The Windows session binds a keypad button to the light's Top Button Link. The owner taps it, holds it, taps the bottom button, and watches the LED. | The whole chain on real hardware |

## 6. Open questions (for the owner or the v1 contract)

- **Q1. On mode.** When the top button is tapped or a Navigator turns the light on, should it go to:
  - Default On Brightness? This is Control4's usual behaviour and what the Hue light does, on a path verified here, although `supports_default_on` is deprecated.
  - or its previous level? That is `brightness_on_mode_previous`, 3.3.2+, never tried on the house, and it needs the `UPDATE_BRIGHTNESS_ON_MODE`/`PRESET` handling (LV2 `5/_7`, `10/_20.1`).

  Recommended for v1: Default On Brightness.
- **Q2. `click_rates` True or False:** H6 decides, before the first install.
- **Q3. Structure (a) or (b):** H1–H3 decide, before the contract.
- **Q4. A fan without a light kit** (other users of the public driver): in (a), the light item stays and reports offline. Is that acceptable, or is it a reason for (b)?
- **Q5. Names.** The default item names (the proxies' `name`, for example "Modern Forms Fan" and "Modern Forms Fan Light"), and the fan as the primary proxy.
- **Q6. Keypad settings after a project restore.** The driver reports its persisted settings to the proxy at late init (Hue #59). A restore onto a controller without the driver's store would therefore overwrite the proxy's restored values with defaults. Options: also mirror them in `PersistData`, which is documented as saved with the project, or adopt the proxy's values. This is a case for the edge-cases document.
- **Q7. CCT:** only if the API research finds a controllable colour temperature (§1.2).

## 7. Where the docs disagree with each other or with the house

1. **Who creates the light's links.** `LV2 10/_1` says the proxy creates the Top, Bottom and Toggle links. On the house, the driver declares them (HUE `docs/keypad-design.md` "Hardware findings").
2. **The `click_rate_max` default.** `LV2 5/_13` gives 1 ms as the default. The capability variable example in `LV2 30/_0` shows 86400000, and the house delivered a 750 ms click rate. Declare the value.
3. **Are click and hold rates dynamic?** Their own pages say they are not (`LV2 5/_11`–`_16`). `LV2 35/_8` nonetheless tells drivers to resend click and hold rate capabilities, and variable 6661 lists them. Treat them as static.
4. **Is `hide_proxy_properties` dynamic?** `LV2 5/_38` says static; `LV2 5/_9.5` says dynamic; `LV2 3/_6` says dynamic from 4.2.1. On OS 3.4.2 the house needed a reboot to change it (HUE #59).
5. **What changed in 3.4.2.** The fan and light_v2 references (`FAN 3/_7`, `LV2 3/_7`) list no 3.4.2 changes. The general guide (`PP 3/_7`) lists `proxy_fan_speed_connections`, nesting for any proxy, `multi_click`, `disable_flash` and a dynamic `cold_start`.
6. **The settings notifications' form.** They are documented with a table parameter (`LV2 35/_16`, `_5`, `_10`). The proxy reads a table as 0 and stores the bare value (HUE `src/common/device.lua`).
7. **LuaJIT fallback.** `FUND 7/_1` says both that a failed LuaJIT load is retried with PUC Lua and that a driver first loaded with LuaJIT gets no fallback.
8. **Smaller slips:**
   - `API 14/_1` dates `CreateTCPClient` to 1.6.0, which looks wrong; the driver doesn't use it.
   - `disable_flash` is spelled `disbale_flash` in its own signature (`LV2 5/_8.9`).
   - The `supports_brightness_stop` page's example shows `supports_color` (`LV2 5/_29`).
9. **What `minimum_os_version` does.** It is documented only as an auto-update gate (`FUND 14/_1`), not as an install check (§3.2).
