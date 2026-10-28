# v1 contract: the Modern Forms Fan driver

Status: contract, 2026-10-27 (#12). Written before any driver code, from
the owner's decisions of 2026-10-27
([#6](https://github.com/corytron/c4-modernforms-driver/issues/6): every
recommended default, 1.0 codename "Arrakis"), the five research notes of #2
and the read-only M0 checks of the house fan
([#11](https://github.com/corytron/c4-modernforms-driver/issues/11), VM
side, 2026-10-27). It is the specification the M3 build agents build
against. Where it is silent, the research decides: the fan's interface
[`modernforms-api-research.md`](modernforms-api-research.md) (MFR), the
fan proxy and links [`fan-proxy-research.md`](fan-proxy-research.md) (FPR),
the light and the structure
[`light-structure-research.md`](light-structure-research.md) (LSR), the
lifecycle policy [`edge-cases-modernforms.md`](edge-cases-modernforms.md)
(ECM) and [`edge-cases-control4.md`](edge-cases-control4.md) (ECC). Where
they disagree with this file, this file wins. The cutover from the stock
WAC driver is [`migration-design.md`](migration-design.md#3-phases)'s, and
so is the Migration Report ([its section 4](migration-design.md#4-the-migration-report)).

**Status key**, as in [`design.md`](design.md) ("Method"): **VERIFIED**
names its primary source (an SDK file, the house, M0, or `aiomodernforms` /
Home Assistant code as MFR cites it); **ASSUMED** names the check of
[section 11](#11-hardware-checks-before-the-first-install) that settles it.
SDK files are paraphrased, never quoted; WAC's documents are never copied
(V15). Placeholders only ([`scaffold-design.md`](scaffold-design.md),
section 2): fan `10.0.2.151` (a second fan `10.0.2.152`), MAC
`00:00:5e:00:53:01`, client id `MF_00005E005301`, "Example Room".

| Key | Where (below `~/c4-tools/reference/`, each `source/includes/`) |
| --- | --- |
| API | `docs-driverworks-api` |
| FUND | `docs-driverworks-fundamentals` |
| XML | `docs-driverworks-xml` |
| FAN | `docs-driverworks-proxyprotocol-fan` |
| LV2 | `docs-driverworks-proxyprotocol-lightv2` (notifications under `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/`, written `35/` below) |
| KP | `docs-driverworks-proxyprotocol-keypad` |
| PP | `docs-driverworks-proxyprotocol` |
| HUE | the owner's Hue project (`~/projects/c4-hue-driver`, read-only): measurements on this house, OS 3.4.2 / 3.4.3 |
| M0 | the VM's read-only checks of the house fan, 2026-10-27, in #11: Gen 3 (ESP32, ESP-IDF 4.0.4), firmware 02.00.0052, six speeds, a dimmable light kit; answers in 0.25 to 0.39 s (one TCP connect of 1.36 s); `HTTP/1.1 200` with only `Content-Type: application/json` and `Content-Length`, keep-alive honoured; the light's level kept while it is off; the fan announces itself over mDNS |

**Items M0 or M1 may still change are marked M0? or M1?** at the place
they apply and listed in [section 16](#16-what-m0-and-m1-may-still-change).
M0's VM half has arrived and is folded in; the Windows half (the stock
driver's `driver.xml`, its Composer presentation, the keypad inventory)
is pending.

## 1. Decisions

| # | Decision | Basis | Mark |
| --- | --- | --- | --- |
| V1 | **One driver** `src/modernforms_fan/` → `modernforms_fan.c4z`, Composer name "Modern Forms Fan", with two proxies: the fan proxy on binding 5001 (primary) and a `light_v2` proxy on 5002. One Lua instance is the only thing that talks to the fan. | #6 decision 1; LSR §2.2; FUND `8_proxies_and_proxy_types/_1-SINGLEANDMULTIPROXIES.md`, `11_connections/_5-PROXYBINDINGMULTIPLE.md`; XML `15_common_xml/_32-proxy.md` | VERIFIED-doc: several proxies, one binding each, the binding in every command. ASSUMED (K2, K4): how Composer shows the two items. M0?: the fan proxy's XML name `fan` and class `FAN` (K1). If K4 fails: [section 2.8](#28-if-the-two-proxy-probe-fails). |
| V2 | **The driver's own Button Links**: light Top/Bottom/Toggle on 200–202, fan Off 300, Speed 1–6 on 301–306, Toggle 307, Cycle 308. Each takes `DO_PUSH`/`DO_CLICK`/`DO_RELEASE` and sends `MATCH_LED_STATE`. `proxy_fan_speed_connections` is **not** declared; K5 records how it behaves for a later version. Ids 203–209 and 309–319 stay free for later links (connections can only ever be added). | #6 decision 2; FPR §3, §6, §7; KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`; FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` | VERIFIED-house: the mechanism on the Hue Light (HUE `docs/keypad-design.md`, "Hardware findings"). ASSUMED (K6): the same on a fan-proxy driver. M1?: `proxybindingid` on the links (K4). |
| V3 | **Minimum OS 3.3.0** in `driver.xml`, and a run-time check of `C4:GetVersionInfo()`: on an older controller the Status says so and the driver runs on. | #6 decision 3; LSR §3; LV2 `3_whats_new/_12-WHATSNEWIN330.md` (the brightness target); KP `3_whats_new/_20-WhatwasNewinOS3.md` (Button Linking); API `35_url/_10-Post.md` (3.0.0); FUND `14_updating_released_drivers/_1-UPDATINGRELEASEDDRIVERS.md` (the tag is documented as an auto-update gate only); API `5_director_command/_2-GetVersionInfo.md` | VERIFIED-doc. ASSUMED (K9): whether Composer refuses an install below the minimum. |
| V4 | **Gen 1–3 fans with six speeds** (`POST /mf`). A Gen 4 fan (HTTP 404 on `/mf`, then `fan_g4` from `/device`) is refused with a Status and never sent a command. | #6 decision 4; MFR §1, §4; ECM H2, H7 | VERIFIED: AIO's generation detection (MFR §1); M0: the house fan is Gen 3 with six speeds. |
| V5 | **Adding a fan**: the owner types `Fan Address`; the driver pins the fan's identity (client id and station MAC) at first contact; a different fan at that address gets nothing until **Use Selected Fan** accepts it; a new address of the pinned fan is followed when the owner types it or picks it, never on its own; no subnet scan, ever. **Find Fans** (an mDNS query) is in v1 only if K10 shows a documented call path working on the house; otherwise it waits for a later version (V5a). | #6 decision 5; M0 (mDNS); ECM N1–N10, Q3; ECC D18–D20 | VERIFIED: `clientId` in every answer (M0; MFR §2.4). See V5a. |
| V5a | **mDNS from a driver, verified in part.** Documented: a dynamic network binding (`C4:CreateNetworkConnection`, API `32_serial_network_device/_1-CreateNetworkConnection.md`, from 1.6.0, needing no XML connection), `C4:NetConnect` with the IP type `UDP` or `MULTICAST` (`_23-NetConnect.md`), `C4:NetPortOptions` with `MIRROR_UDP_PORT` (`_25-NetPortOptions.md`), `C4:SendToNetwork` (`_20-SendToNetwork.md`) and `ReceivedFromNetwork` (`_15-ReceivedFromNetwork.md`; its sender parameter only from 4.0.0). Not documented: which group a `MULTICAST` connection joins, which local port it binds, and whether a datagram from another address (the fan's answer) reaches `ReceivedFromNetwork`. A UDP server (`33_server_sockets/_2-CreateServer.md`) receives from any sender, but its send to an address is documented only from 4.0.0 (`_6-ServerSend.md`); `C4:SendBroadcast` (`_18-SendBroadcast.md`) broadcasts, which is not mDNS. Hence K10. Adding Find Fans later costs only Lua, a property and an action: no connection, no capability, no reboot. | M0; API as named | VERIFIED: the calls exist. ASSUMED (K10): that they carry an mDNS query and its answers on OS 3.4.3. |
| V6 | **Transport**: `C4:url():Post()` to `http://<address>/mf`, one request in flight per device, commands before reads, 250 ms between the end of one request and the start of the next. Every body is built from an allow-list; a received shadow is never sent back. | #6 decision 6; MFR §2.3, §10, §11; API `35_url/*`; [section 3](#3-transport) | VERIFIED-doc for the API; M0 for the answers; the gap ASSUMED (K13). |
| V7 | **Polling**: every `Poll Interval (s)` while idle (10 to 120, default 15), every 2 s for 20 s after any change, backing off 10, 20, 40, then 60 s on failures; offline after 3 failures in a row. | #6 decision 6; ECM P1, Q4; MFR §8 (Home Assistant moved from 5 s to 15 s because fans froze) | VERIFIED: HA's 15 s (MFR §5). The rest is policy. |
| V8 | **State model**: per field a confirmed value, an in-flight value and a wanted ("dirty") value; the shown state is wanted over in flight over confirmed. Sequence numbers and an epoch on every request; the command's own answer is the authority; a read that contradicts a just-commanded value is believed only when the next read agrees (2.5 s settle); bursts coalesce, latest wins; Control4's commands are always sent, even when they equal the confirmed state. | #6 decision 6; MFR §6; ECC R2, R3, R5; ECM S7, S8, S11 | Policy; the fan-side causes of disagreement ASSUMED (K16). |
| V9 | **Report rules R1–R9** of ECC §5.1, unchanged: one notification per real change, never older after newer, confirmed values only, no `ON`/`OFF` notifications to the fan proxy. | #6 decision 6; [ECC §5.1](edge-cases-control4.md#51-the-report-contract); FAN `42_fan_protocol_notifications/_1-CURRENTSPEED.md`, `_4-ON.md`; LV2 `35/_10.2-LIGHTBRIGHTNESSCHANGED.md` | VERIFIED-doc for the messages; ASSUMED (K8): what the fan proxy does with `ON`. |
| V10 | **Keypad LEDs show the pressed target at once** (`MATCH_LED_STATE` fires no programming) and are corrected when the fan answers otherwise or the request fails. | #6 decision 7; ECC C13, R4 | VERIFIED-house: `MATCH_LED_STATE` on driver links (HUE `docs/keypad-design.md`, "Keypad LEDs"; `docs/design.md`, "Keypad and scene dimmer: verified on hardware"). |
| V11 | **ON and Toggle turn the fan on at the preset speed**: 3, changed with Designate Preset and persisted. ON on a running fan changes nothing. The proxy's `CYCLE_SPEED_UP`/`DOWN` step from the shown speed and stop at 6 and at 1, never off; the **Fan Cycle** link steps up and wraps 6 → 1. | #6 decision 8; FAN `41_fan_proxy_commands/_1-ON.md`, `_3-TOGGLE.md`, `_4-DESIGNATEPRESET.md`, `_6-CYCLESPEEDUP.md`, `_7-CYCLESPEEDDOWN.md`; FAN `43_fan_capabilities/_4-presetspeed.md`; ECC Q4 | VERIFIED-doc: wrapping and stopping are the driver's choice. The wrap of the link is this contract's choice (a single "Cycle" button must not get stuck at 6); Lua only, so cheap to change. |
| V12 | **Double taps stay keypad programming** on the button's own events; a fan link acts on every push. No per-button tap, double-tap or colour machine in v1. A button whose double tap sets another speed still lights at that speed: V26. | #6 decision 9; KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md` (multi-press over links is newer; older drivers ignore it); ECC C10 | ASSUMED (K6): what a double tap sends over a link. |
| V13 | **Fan offline** (power cut at the wall, Wi-Fi gone, a stuck module): keep the last state marked not current, the `Online` variable 0, **Fan Offline** once; when it answers again, report what the fan says, **Fan Online** once, and re-send nothing. A command while offline is tried once and dropped. | #6 decision 10; ECM P1–P3, P8, Q1, Q2; ECC R7, R8, U3; LV2 `35/_15-ONLINECHANGED.md` | VERIFIED-doc for the light's `ONLINE_CHANGED`; the fan proxy has no online notion (FPR §1.4). |
| V14 | **The light turns on at Default On Brightness** (top tap, Toggle from off, `ON`, a Navigator's on). No fades: every target is one level sent at once; a hold steps the level at most every 500 ms. "On at a new level" is the level first, then `lightOn`, never one body. | #6 decision 11; LSR §1.2–§1.6, Q1; MFR §2.3, §9; ECM S3, S4; M0 (the level is kept while off) | VERIFIED: AIO's level-then-on order (MFR §2.3); M0. ASSUMED (K12): a level sent while off does not switch the light on. |
| V15 | **WAC's API License Agreement is not entered.** Every field the driver reads or writes is verified by `aiomodernforms` / Home Assistant code (as MFR cites it) or by M0; WAC's documents are at most corroboration and nothing of them is copied. | #6 decision 12; MFR "Licensing and provenance" | — |
| V16 | **Migration**: the driver carries the **Migration Report** action and the **Migration** and **Stock Device** properties (§2.5); their behaviour is [`migration-design.md`](migration-design.md#4-the-migration-report)'s. `<replaces>` is never declared. | #6 decision 13; ECC §2.1, D24; XML `15_common_xml/_33.5-replaces.md` | VERIFIED-doc: `<replaces>` deletes the named driver's devices without warning. |
| V17 | **1.0 codename "Arrakis"** (in `.github/codenames.json`); every 1.0 build and beta keeps it. | #6 decision 14 | — |
| V18 | **Direction**: `can_reverse` True and `SET_DIRECTION`/`TOGGLE_DIRECTION` written as `fanDirection`, **if** K11 shows the house fan stays on Wi-Fi after a direction write; otherwise `can_reverse` False and the direction is shown only. Settled before the first install (a static capability). | MFR §8 (a field report of a model dropping off Wi-Fi on every direction write), §9; ECM S5; FAN `43_fan_capabilities/_1-canreverse.md` | M1?: K11. |
| V19 | **Light capabilities**: as the Hue Light, minus colour, with `click_rates` False (taps are immediate, as V14 needs) and `reduced_als_support` True (the light may join Advanced Lighting Scenes; a static choice that is free to keep and costs a reboot to add later). | LSR §1.2; LV2 `5_light_v2_capabilities/_11-CLICKRATES.md`, `22-REDUCEDALSSUPPORT.md`; LV2 `45_Light_V2_advanced_lighting_scene/_1.3-REDUCEDALSSUPPORT.md` | VERIFIED-house: the Hue Light's set. |
| V20 | **Private fields** (`owner`, `federatedIdentity`, `deviceName`, `SSID`, `BSSID`, `timezone`, the `schedule` blob) are dropped on receipt: never stored, shown or logged. The client id and MAC are stored, shown in Composer rows only, and appear in log lines only as their last four hex digits. | ECM rule 8, V6; MFR §2.4; M0 (the private list) | — |
| V21 | **Persistence**: the identity, the fan's model and firmware, the last online flag and the preset speed with `C4:PersistSetValue`; the fan's state is not persisted. The `Fan ID` row doubles as the identity's copy in the project file. | FUND `24_persisting_driver_data/_1-PERSISTINGDRIVERDATA.md`; API `26.5_persistence/_3-PersistGetValue.md`, `_4-PersistSetValue.md`; ECC D9, D10; HUE `docs/design.md` "Storage" | VERIFIED-house: values survive an update and a reboot. ASSUMED (parked to the first restore): a driver-written read-only row is in a project backup. |
| V22 | **The fan's own automations are shown, not fought**: `Fan Automations` lists a schedule, away mode, adaptive learning and running sleep timers; `Last Change By` names who changed the fan when it was not Control4 (Gen 3 `userData`); **Turn Off Away Mode** and **Turn Off Adaptive Learning** are offered as clicks. Schedules and timers are not cleared in v1. | ECM A1–A7, §9; MFR §2.3 (the allow-list), §11 row 11; `CLAUDE.md` (Control4 is the source of truth) | VERIFIED: the fields (AIO, MFR §2.2; M0 shows all of them on the house fan). ASSUMED (K16): what `userData` says for the remote. |
| V23 | **Reboot Fan** action (`{"reboot":true}`), a click only, never automatic; up to 2 minutes of silence afterwards counts as rebooting, not offline. Not a programming command (every command is forever once released). | MFR §2.3, §11 row 10; ECM P4, P6; ECC §5.2 | VERIFIED: AIO `reboot()` (MFR §2.3); the fan's behaviour after it ASSUMED (K18). |
| V24 | **No custom icons in v1**: the two proxies show Control4's own fan and light icons, which a device keeps for good from its creation. An owner who wants custom icons says so before the first install. | HUE `docs/design.md` "Composer Pro 3.4.2 UI" (builds 125 and 135); ECC D25 | VERIFIED-house: the icon rule. |
| V25 | **Programming surface**: events 1 Fan Offline and 2 Fan Online (3 reserved for a later "Changed Outside Control4"); one variable, `Online`; one conditional, `BOOL_ONLINE`; no programming commands of the driver's own. | ECC §5.2, F2, F24; API `36_variable/_1-AddVariable.md`, `7_event/_4-FireEventByID.md`; FUND `10_conditionals/_4-USINGTHETESTCONDITIONFUNCTION.md`, `_8-XMLINABOOLEANTYPECONDITIONAL.md` | VERIFIED-doc. |
| V26 | **A speed link can light at one more speed.** Each of the six speed links has a setting, `Speed N Link Also Lit At` ("No other speed" by default, or one of the six speeds): the link's LED is then lit while the fan runs at its own speed *or* at that one. This closes the gap [`migration-design.md`](migration-design.md#8-open-items) item 11 found: today the house's Low button is lit (blue) at speed 1, its double tap, and the High button (orange) at speed 6; with one Follow Connection link per button and V12 they would be dark there. It is an LED rule, not a tap machine: the double tap stays the keypad's programming. In the keypad's own on colour, one colour per button (V27 for more). | #6 decisions 2, 7, 9; the coordinator's question of 2026-10-27 | VERIFIED: which state a link's `MATCH_LED_STATE` carries is the driver's to choose (KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`: the notification says only whether the on or the off colour is active); the message works on this house's keypads (HUE `docs/design.md`, "Keypad and scene dimmer: verified on hardware": a switch's LEDs follow a scene device). |
| V27 | **A colour per speed only if the keypad takes colours over the link and the owner wants them.** The link protocol has the driver's `BUTTON_COLORS` notification (on and off colour, 6-digit hex) and the keypad's `REQUEST_BUTTON_COLORS` asking for it (KP `62/_1`, VERIFIED-doc), and `common/device.lua` already sends it on the light links. Not documented, and never seen on the house: that a keypad applies colours received this way, and again each time they change while the button is bound. If K6 shows both, and the owner says yes (FPR §7 item 8: per-link colours "only if T6 shows the keypad adopts them and the owner wants them"), the build carries `Speed LED Colors` and a colour per speed (§2.5): a speed link lit at speed s is first sent the on colour of s, reproducing today's blue for 1 and orange for 6. Otherwise v1 sends no colours on the fan links and each linked fan button shows the colours set on the keypad itself: an **open item for the owner** ([section 17](#17-open-items-for-the-owner)). Adding the rows later costs no capability, connection or reboot. | #6 decision 9; FPR §5, §7 item 8; KP `62/_1`; `src/common/device.lua` (`send_button_colors`, after Snap One's `c4hook_light_v2.lua`) | ASSUMED (K6): adoption at run time. |

## 2. Structure and `driver.xml`

The coordinator writes `src/modernforms_fan/driver.xml` from this section.
Everything static here (proxies, capabilities, connection definitions) is
fixed by the first install on the house: a later change to a capability
costs the owner a controller reboot, and a proxy or connection can never be
removed or redefined (FUND
`14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`; ECC F1,
F2, F26).

### 2.1 Header

- Kept from the scaffold: `copyright`, `creator`, `manufacturer` "Modern
  Forms", `name` "Modern Forms Fan", `model` "Modern Forms Fan (local
  API)", `control` `lua_gen`, `controlmethod` IP, `driver` DriverWorks,
  `<script jit="1" file="driver.lua"/>` (never changed: ECC D6),
  `<documentation file="www/documentation.html"/>`.
- `<combo>true</combo>` and the scaffold's self-proxy go: the driver now
  has real proxies.
- `<minimum_os_version>3.3.0</minimum_os_version>` (V3), with a comment
  naming the reason (the brightness target API) and that the tag is
  documented only as an auto-update gate.
- No `<small>`/`<large>` and no image attributes on the proxies (V24).
- No `<replaces>`, no `<auto_update>`, no `SINGLETON_ID` (ECC D16, D23, D24).

### 2.2 Proxies

```xml
<proxies>
	<proxy proxybindingid="5001" name="Modern Forms Fan" primary="True">fan</proxy>
	<proxy proxybindingid="5002" name="Modern Forms Fan Light">light_v2</proxy>
</proxies>
```

The `name` attributes are the default device names (FUND
`8_proxies_and_proxy_types/_2-MODIFYINGTHEDEFAULTNAMINGOFPROXIES.md`).
M0?: the proxy type `fan` (K1; every public fan driver uses it, FPR §1.1).

### 2.3 Capabilities

One `<capabilities>` block carries both proxies' names; no name occurs in
both lists (VERIFIED-doc: FAN `43_fan_capabilities/` against LV2
`5_light_v2_capabilities/`; that each proxy ignores the other's names is
ASSUMED, K1 shows how the stock driver does it). `True`/`False` spelt as in
the Hue Light's `driver.xml`.

| Capability | Value | Proxy | Kind | Source |
| --- | --- | --- | --- | --- |
| `discrete_levels` | 6 | fan | static (FPR §1.2) | FAN `43_fan_capabilities/_3-discretelevels.md`; M0 |
| `speed_names` | `1,2,3,4,5,6` (M0?: the stock driver's names if K1 shows them, for the family's Navigators) | fan | static | FAN `_5-speednames.md`; comma list as in `41_fan_proxy_commands/_12-GETSETUP.md` |
| `preset_speed` | 3 | fan | static; the run-time preset is the driver's (V11) | FAN `_4-presetspeed.md` |
| `can_set_preset` | True | fan | static | FAN `_2-cansetpreset.md` |
| `can_reverse` | True, or False if K11 fails (V18) | fan | static | FAN `_1-canreverse.md` |
| `proxy_fan_speed_connections` | not declared (V2) | fan | — | FAN `_4.5-proxyfanspeedconnections.md` |
| `dimmer`, `set_level`, `ramp_level`, `on_off` | True | light | `dimmer`, `set_level` dynamic; the others deprecated | LV2 `_5-DIMMER.md`, `_2-SETLEVEL.md` |
| `min_max` | False | light | deprecated | HUE `src/hue_light/driver.xml` |
| `click_rates` | False | light | static (V19) | LV2 `_11-CLICKRATES.md` |
| `hold_rates` | True | light | static | LV2 `_14-HOLDRATES.md` |
| `hold_rate_min` | 1000 | light | static | LV2 `_15-HOLDRATEMIN.md`; HUE |
| `supports_default_on` | True | light | static, deprecated; the path verified on the house (HUE #59) | LV2 `_32-SUPPORTSDEFAULTON.md` |
| `cold_start` | False | light | dynamic from 3.4.2 | LV2 `_8-COLDSTART.md` |
| `has_leds` | True | light | static | LV2 `_28-HASLEDS.md` |
| `has_button_events` | False | light | static | LV2 `_26-HASBUTTONEVENTS.md` |
| `supports_target` | True | light | dynamic | LV2 `_4-SUPPORTSTARGET.md` |
| `supports_brightness_stop` | True | light | dynamic | LV2 `_29-SUPPORTSBRIGHTNESSSTOP.md` |
| `supports_color`, `supports_color_correlated_temperature` | False | light | dynamic (Gen 1–3 have no colour, MFR §9) | LV2 `_30-SUPPORTSCOLOR.md`, `_31-SUPPORTSCOLORCORRELATEDTEMPERATURE.md` |
| `supports_broadcast_scenes`, `supports_multichannel_scenes`, `advanced_scene_support`, `load_group_support` | False | light | static | HUE |
| `reduced_als_support` | True (V19) | light | static | LV2 `22-REDUCEDALSSUPPORT.md` |
| `hide_proxy_properties`, `hide_proxy_events` | False | light | static on 3.x | LV2 `_38-HIDEPROXYPROPERTIES.md`; HUE #59 |
| `buttons_are_virtual` | True | light | deprecated | HUE |

Not declared: `click_rate_min`/`_max`, `supports_color_stop`, any
`brightness_on_mode_*` (never together with `supports_default_on`, LV2
`_32`), the nesting capabilities, `multi_click`, `disable_flash`.

### 2.4 Connections

| Id | `connectionname` | Type | Consumer | Class | `linelevel` | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 5001 | `FAN` | 2 (proxy) | False | `FAN` (M0?: K1) | False | |
| 5002 | `LIGHT` | 2 (proxy) | False | `LIGHT_V2` | False | as the Hue Light |
| 200 | Light Top Button Link | 1 | False | `BUTTON_LINK` | True | `common/device.lua`'s ids |
| 201 | Light Bottom Button Link | 1 | False | `BUTTON_LINK` | True | |
| 202 | Light Toggle Button Link | 1 | False | `BUTTON_LINK` | True | |
| 300 | Fan Off Button Link | 1 | False | `BUTTON_LINK` | True | |
| 301–306 | Fan Speed 1 Button Link … Fan Speed 6 Button Link | 1 | False | `BUTTON_LINK` | True | one per speed |
| 307 | Fan Toggle Button Link | 1 | False | `BUTTON_LINK` | True | |
| 308 | Fan Cycle Button Link | 1 | False | `BUTTON_LINK` | True | |

Each link is the Hue Light's pattern (`facing` 6, `audiosource` and
`videosource` False; HUE `src/hue_light/driver.xml`): a provider control
binding in the control range 1–999 (XML `50_connections_xml/_15-id.md`,
`_30-type.md`). **M1?**: whether the light links carry
`proxybindingid="5002"` and the fan links `proxybindingid="5001"` (FUND
`11_connections/_1-OVERVIEW.md` documents the attribute); the default is
**without** it, the pattern verified on the house, unless K4 shows that a
link with the attribute is shown under its proxy's item and still delivers
its presses to the driver. Reserved, never declared in v1: 203–209 (light),
309 "Fan Cycle Down Button Link", 310 "Fan Direction Button Link", 311–319
(fan), 6001 (Find Fans' dynamic network binding, V5a; no XML).

### 2.5 Properties, in this order

| # | Name | Type | Default | Read-only | What it shows ([section 7](#7-texts)) |
| --- | --- | --- | --- | --- | --- |
| 1 | Driver Version | STRING | "" | yes | as the scaffold |
| 2 | Status | STRING | "" | yes | one line, §7.1 |
| 3 | Last Action | STRING | "" | yes | §7.2 |
| 4 | Fan Address | STRING | "" | no | the fan's IPv4 address (V5; the manual asks for a DHCP reservation) |
| 5 | Found Fans | DYNAMIC_LIST | "" | no | only in a build with Find Fans (V5a); the pick waits for Use Selected Fan |
| 6 | Fan ID | STRING | "" | yes | §7.3 |
| 7 | Fan Model | STRING | "" | yes | §7.3 |
| 8 | Firmware | STRING | "" | yes | §7.3 |
| 9 | Last Seen | STRING | "" | yes | §7.3 |
| 10 | Last Change By | STRING | "" | yes | §7.3 |
| 11 | Fan Automations | STRING | "" | yes | §7.3 |
| 12 | Poll Interval (s) | RANGED_INTEGER, 10–120 | 15 | no | V7 |
| 13 | Keypad Links | DYNAMIC_LIST | "" | no (a pick snaps back to the first row) | §7.3 |
| 14–19 | Speed 1 Link Also Lit At … Speed 6 Link Also Lit At | LIST: `No other speed`, `Speed 1` … `Speed 6` | No other speed | no | V26; picking the link's own speed is the same as `No other speed` |
| 20 | Speed LED Colors | LIST: `Keypad's own`, `Per speed` | Keypad's own | no | only in a build with V27 |
| 21–26 | Speed 1 LED Color … Speed 6 LED Color | COLOR_SELECTOR | `0,0,255` | no | only with V27: the on colour a speed link shows while the fan runs at that speed |
| 27 | Speed LED Off Color | COLOR_SELECTOR | `0,0,0` | no | only with V27: the off colour sent with them |
| 28 | Migration | DYNAMIC_LIST | "" | — | [`migration-design.md`](migration-design.md#4-the-migration-report) (its verdict and rows) |
| 29 | Stock Device | DEVICE_SELECTOR, `<items>`: the stock driver's file names exactly as M0 reads them **[M0]** (today `wac_mf_fan_and_light_controller(v4).c4z`; another version of WAC's file has its name added by a later build, a property change with no reboot), `<multiselect>false</multiselect>` | "" | no | the fallback that names this fan's stock device when the Migration Report cannot tell (that document's §4.2) |
| 30 | Debug Mode | LIST Off, On | Off | no | as the scaffold |
| dev | Dev Server | STRING | "" | no | DEV-ONLY block, as the scaffold |
| dev | Dev State | STRING | "" | yes | DEV-ONLY block, [section 12](#12-dev-loop-actions-and-toolsregresssh) |

Types: XML `20_properties/_20-type.md`; DYNAMIC_LIST FUND
`15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md`;
RANGED_INTEGER with `<minimum>`/`<maximum>` (XML `20_properties/_40-minimum.md`,
`_45-maximum.md`); COLOR_SELECTOR, a comma-separated RGB value (FUND
`_5-COLORSELECTOR.md`), sent as 6-digit hex; DEVICE_SELECTOR, whose items
the documentation gives as `.c4i` names of proxies or protocols and whose
value is the chosen device ids, comma-separated (FUND
`_3.1-DEVICESELECTOR.md`; that a `.c4z` file name works as an item is
ASSUMED, seen when the Windows session first opens the Select dialog).
`Stock Device` shows Composer's own selection and no driver text; the texts
that name it are [migration-design.md](migration-design.md#4-the-migration-report)'s
verdicts (its §4.5): `Stock Device changed: click Migration Report again`,
`3 stock WAC devices: pick this fan's in Stock Device` and `Report failed:
Stock Device 1204 is not a stock WAC device`. Every text the driver writes
stays under about 70 characters (Composer clips near 75; ECC F29). A
DYNAMIC_LIST item never contains a comma (the list is one comma-separated
string, `C4:UpdatePropertyList`): a comma in a device name is written as
`‚` (U+201A), as the Hue drivers and `migration-design.md` do. A `Fan
Address` edit reaches the driver only through the row's Set button (ECC
F29). Every property handler also runs in the late-init replay, so the
settings of rows 12 and 14–27 apply from the start.

After every install the Windows session reads back `Driver Version`,
`Debug Mode` (Off), `Poll Interval (s)` and `Status` (starting "Online:"):
the house keys of [`scaffold-design.md`](scaffold-design.md) section 5.

### 2.6 Actions

| `sort_order` | Name (= command) | Behaviour |
| --- | --- | --- |
| 1 | Find Fans | only with V5a: one mDNS query, 3 s of answers, the list into `Found Fans` |
| 2 | Use Selected Fan | [section 3.5](#35-first-contact-identity-and-address-changes) |
| 3 | Reboot Fan | V23, [section 6.4](#64-reboot-fan) |
| 4 | Turn Off Away Mode | V22: `{"awayModeEnabled":false}` |
| 5 | Turn Off Adaptive Learning | V22: `{"adaptiveLearning":false}` |
| 6 | Migration Report | [`migration-design.md`](migration-design.md#4-the-migration-report) |

`sort_order` on every action (XML `30_actions/_45-sortorder.md`; without it
Composer lists them in reverse, ECC F29). The numbers stay even without
Find Fans. Each action ends in `Last Action` (§7.2).

### 2.7 Events, variables, conditional

Events (XML `40_events_xml/_15-id.md`, `_30-sortorder.md`; ids fixed
forever, ECC F24):

| Id | Name | Description | `sort_order` | Fires |
| --- | --- | --- | --- | --- |
| 1 | Fan Offline | When NAME stops answering on the network | 1 | once per transition to offline, foreign, Gen 4 or not-a-fan ([section 6](#6-offline-online-rebooting-and-the-wrong-fan)) |
| 2 | Fan Online | When NAME answers on the network again | 2 | once per transition back to online |

Id 3 is reserved for "Changed Outside Control4". `C4:FireEventByID`, never
before late init (API `7_event/_4-FireEventByID.md`). The fan's speed, on,
off and direction events and the light's events are the proxies' own (FAN
`45_fan_events/_1-FANEVENTS.md`; LV2 `25_light_v2_events/_0-HEADER.md`).

Variables, added in `OnDriverInit` in this order and never reordered,
renamed or removed (API `36_variable/_1-AddVariable.md`; ECC F23, F24):

| Order | Name | Type | Read-only | Hidden | Initial value |
| --- | --- | --- | --- | --- | --- |
| 1 | Online | BOOL ("1"/"0") | yes | no | the persisted `mf_online` (`C4:PersistGetValue` may run before late init, API `26.5_persistence/_3-PersistGetValue.md`), else "0" |

Conditional (FUND `10_conditionals/_8-XMLINABOOLEANTYPECONDITIONAL.md`):

```xml
<conditionals>
	<conditional>
		<id>0</id>
		<name>BOOL_ONLINE</name>
		<type>BOOL</type>
		<condition_statement>Fan is online</condition_statement>
		<description>NAME fan is online is STRING</description>
		<true_text>True</true_text>
		<false_text>False</false_text>
	</conditional>
</conditionals>
```

`TestCondition("BOOL_ONLINE", params)` (FUND
`10_conditionals/_4-USINGTHETESTCONDITIONFUNCTION.md`): with `params.VALUE`
"True" or "False" (the text picked) the answer is `online == (VALUE ==
"True")`, inverted for `LOGIC` `NOT_EQUAL`; with no `VALUE` it is `online`
itself. ASSUMED (checked at M4 with one If line): FUND `10/_4` lists an empty
table for BOOL, while the Hue motion driver also reads `VALUE`. Any other
name answers false. No `<commands>` (V25).

### 2.8 If the two-proxy probe fails

If K4 shows that the light item gets no settings page, that its links can
only appear under the fan, or that a press on a light link never arrives,
v1 takes LSR's option (b) instead: a second package `src/modernforms_light/`
(a `light_v2` device with links 200–202 and the Hue Light's bridge-binding
machinery, which the port into `common/device.lua` stripped and which comes
back from the Hue repo), created by the fan driver on a click and bound to
it on a control binding. Unchanged: the transport, the model, the fan proxy,
the fan links, every text. Changed: `fan/light.lua` moves into the light
driver and talks to the fan driver by `C4:SendToDevice` messages; this
contract gains a message table. Decided before the first install, since a
device's proxies are fixed at its creation.

## 3. Transport

### 3.1 Requests

Every request is `POST http://<Fan Address>/mf` (the Gen 4 probe alone posts
to `/device`) with the header `Content-Type: application/json` and nothing
else: Director adds `Host`, `Accept`, `Accept-Encoding` and `Connection:
close` by default and asks drivers not to overwrite them (VERIFIED-doc: API
`37_web_service/_13-urlSetTimeout.md`, usage notes). M0 shows the fan also
honours keep-alive; closing frees its socket at once, which is the research's
choice for a small TCP stack (MFR §8, §10; ASSUMED harmless, K13 times it).
Bodies are built with `string.format`, keys in the order shown, no spaces,
integers with `%d`, literal `true`/`false` (MFR §10; HUE: `C4:JsonEncode`
writes arrays as objects).

| Kind | Body | When | Source |
| --- | --- | --- | --- |
| state | `{"queryDynamicShadowData":1}` | every poll | VERIFIED: M0; AIO (MFR §2.1) |
| info | `{"queryStaticShadowData":1}` | first contact, back online, after a reboot, a new address, every 6 h | VERIFIED: M0 |
| fan on at N | `{"fanOn":true,"fanSpeed":N}`, N 1–6 | `SET_SPEED` N, ON, Toggle, Cycle, a speed link | VERIFIED: HA `fan.py` via AIO `fan()` (MFR §2.3) |
| fan off | `{"fanOn":false}` | `SET_SPEED 0`, OFF, Toggle, the Off link | VERIFIED: AIO |
| direction | `{"fanDirection":"forward"}` or `"reverse"` | V18 only; never in another body | VERIFIED: the field (MFR §2.2); ASSUMED safe (K11) |
| light level | `{"lightBrightness":N}`, N 1–100 | the first step of "on at N", or a new level while on | VERIFIED: AIO `light()` |
| light on | `{"lightOn":true}` | the second step of "on at N" | VERIFIED: AIO |
| light off | `{"lightOn":false}` | a target of 0 | VERIFIED: AIO |
| away mode off | `{"awayModeEnabled":false}` | Turn Off Away Mode only | VERIFIED: AIO `away()` |
| adaptive learning off | `{"adaptiveLearning":false}` | Turn Off Adaptive Learning only | VERIFIED: AIO `adaptive_learning()` |
| reboot | `{"reboot":true}` | Reboot Fan only; no answer expected | VERIFIED: AIO `reboot()` |
| Gen 4 probe | `{"query":true}` to `/device` | once after an HTTP 404 on `/mf` | VERIFIED: AIO `_probe_gen4()` (MFR §1) |

A body never carries `lightOn:true` together with a changed
`lightBrightness` (the flash, MFR §2.3), nor fan and light fields together,
nor any key outside this table (`factoryReset`, `decommission`,
`resetRfPairList`, `rfPairModeActive`, `firmwareUrl`, `schedule`, timers,
`wind` are never written).

### 3.2 The call

```lua
C4:url()
	:SetOptions({ timeout = 5, connect_timeout = 3, fail_on_error = false })
	:OnDone(function(transfer, responses, err_code, err_msg) ... end)
	:Post("http://" .. address .. path, body, { ["Content-Type"] = "application/json" })
```

VERIFIED-doc: `C4:url` and `Post` (API `35_url/_0-Header.md`, `_10-Post.md`,
from 3.0.0), the options in seconds and `fail_on_error` false to read an
error's body (`_12-SetOption.md`, `_13-SetOptions.md`), `OnDone` once per
transfer with 0 on success and the responses in order (`_8-OnDone.md`), the
response's `code` (`_9-OnHeaders.md`). The reboot uses `timeout` 3. Never
before `OnDriverLateInit` (FUND `28_api_specific_info/_2-DRIVERINIT.md`),
never from inside `OnHeaders` or `OnBodyChunk` (HUE: fails with curl error
2), so every next request starts from a timer. `Cancel()` is never relied on
(HUE: it does not end an active transfer on 3.4.2). `max_host_connections`
stays at its default of 1 (API `37_web_service/_11-urlSetOption.md`).
Timeouts: ASSUMED from M0 (0.25 to 0.39 s; one 1.36 s connect) and AIO's 5 s.

### 3.3 Answers and errors

| Outcome | Classified as | Effect |
| --- | --- | --- |
| `err_code` 0, `code` 200, the body a JSON object | ok | applied ([section 4](#4-state-model-and-report-rules)) |
| `err_code` ≠ 0, message mentioning a timeout | `timeout` | a failure |
| `err_code` ≠ 0, anything else | `connect` | a failure |
| `code` 404 on `/mf` | `http` 404 | the Gen 4 probe, once per contact (§3.6) |
| any other `code` | `http` | a failure |
| an empty body | `empty` | a failure ("no usable data") |
| not JSON, not an object, or no `clientId` | `json` | a failure ("no usable data") |

`C4:JsonDecode` runs inside `pcall`, and both of its documented failure
forms (a raise, or `nil` and a message) count as `json` (API
`12_json/_3-JsonDecode.md` documents both). Unknown keys are ignored and a
missing key is unknown, never a default (ECM F2, F3; MFR §2.2). Values
outside their range: a `fanSpeed` outside 1–6 is logged once per contact
and clamped; `fanSpeed` 0 with `fanOn` false means "off, speed unknown"; a
`lightBrightness` of 0 while on is reported as 1 (never 0 while on, LV2
`35/_10.2`), logged once.

### 3.4 Polling, backoff and offline

| Constant | Value | Basis |
| --- | --- | --- |
| `POLL_DEFAULT_S` | 15 (`Poll Interval (s)`, 10 to 120) | #6 decision 6; HA (MFR §5); never below 10 (MFR §11 row 7) |
| `FAST_POLL_MS`, `FAST_WINDOW_MS` | 2000 for 20000 | #6 decision 6 |
| `GAP_MS` | 250 | MFR §11 row 3; ASSUMED (K13) |
| `SETTLE_MS` | 2500 | MFR §6 item 3; ASSUMED (K16) |
| `BACKOFF_S` | 10, 20, 40, then 60 | ECM P1 |
| `OFFLINE_AFTER` | 3 failures in a row | #6 decision 10; ECM P1 |
| `IDENTITY_POLL_S` | 60 while foreign, Gen 4 or not a fan | ECM N3 |
| `REBOOT_WINDOW_S`, `REBOOT_POLL_S` | 120, 10 | ECM P6 |
| `INFO_REFRESH_S` | 21600 | ECM F1 (a firmware update between polls) |
| `RAMP_STEP_MS` | 500 | ECM S4 |

The poll is one one-shot timer, re-armed after every answer or failure, so
polls never overlap (Director skips a busy repeating timer, API
`34_timer/_1-SetTimer.md`; MFR §10):

- after a success: in 2 s while inside the fast window, else in `Poll
  Interval (s)`; a command's answer counts as a poll;
- the fast window (20 s) opens after a command's answer, after a read that
  saw a change Control4 did not make, and on coming back online;
- after the k-th failure in a row: in `BACKOFF_S[k]`; the third makes the
  fan offline ([section 6](#6-offline-online-rebooting-and-the-wrong-fan));
  the first success ends the streak;
- while foreign, Gen 4 or not a fan: every 60 s, the identity read again;
- while rebooting: every 10 s for at most 120 s.

### 3.5 First contact, identity and address changes

The identity is the station MAC as 12 uppercase hex digits plus the client
id as the fan sends it (`MF_` or `WAC_` and 12 hex digits); the dynamic
shadow is checked by its `clientId`, the static shadow by both (ECM N9;
VERIFIED: `clientId` in both answers, M0). A **contact** is an info read
followed by a state read; it runs at start, after an address change, when
the fan answers after a failure streak, and after a reboot. Commands
wanted meanwhile wait for the contact's identity check, and are dropped
(logged) if it fails.

| Situation at the contact | Result |
| --- | --- |
| no identity pinned yet | the fan is learned and pinned (#6 decision 5); `Last Action` L1 |
| the pinned fan, at the address it answered at before | normal |
| the pinned fan at an address the owner typed or picked | followed; the identity's address updated; L2 |
| another Modern Forms fan | **foreign**: nothing sent, every command refused, the last state kept, Status S11; read again every 60 s, since the right fan may come back (ECM N3) |
| HTTP 404, then `fan_g4` from `/device` | **Gen 4**: S12, nothing sent (V4) |
| HTTP 404, then anything else; or an answer that is not a fan's, repeatedly | **not a fan**: S13 |
| no answer | the failure streak of §3.4 |

**`Fan Address` edited** (after late init): trimmed; empty stops every
request (phase unset, S1, the pin kept, so typing the old address back
resumes); not a dotted IPv4 address: S3 and nothing sent; otherwise a new
epoch and a contact at the new address. Hostnames are not accepted in v1.
On a new device, typing `Fan Address` is all it takes: the first contact
pins the fan (L1), with no further click; a pick in `Found Fans` takes Use
Selected Fan ([`migration-design.md`](migration-design.md#3-phases), Phase
1, uses both routes).

**Use Selected Fan** (a click): the target is the `Found Fans` pick when
there is one, else `Fan Address`. One info read at the target, nothing else
sent:

| The target answers | Result |
| --- | --- |
| as the pinned fan at the current address | L4 |
| as the pinned fan elsewhere | `Fan Address` set to the target, followed, L2 |
| as another Gen 1–3 fan, or no fan was pinned | **re-pointed**: the new identity pinned, model and firmware replaced, `Fan Address` set, a contact, its state reported as changes; the device, its links and programming stay (ECM H1, ECC D18); L3 |
| not at all | L5, nothing changes |
| as Gen 4 or not as a fan | L6, nothing changes |
| (no pick and no address) | L7 |
| (a pick, and the fan answering there has another MAC than the pick's) | L21, nothing changes |

The pick is cleared after any outcome. Matching by name, model or address,
adopting by itself and scanning the subnet are forbidden (ECM N1, N3; ECC
D18).

### 3.6 Gen 4 and not a fan

After an HTTP 404 on `/mf`, one `POST /device` `{"query":true}` (read-only)
per contact: a JSON object whose `systemType` contains `fan_g4` is a Gen 4
fan, anything else is not a fan (VERIFIED: AIO `const.py`, `gen4.py`, MFR
§1; HA's tests mock the 404). Afterwards `/mf` is read every 60 s and the
verdict kept without probing again. Nothing else is ever sent there.

### 3.7 Logging and private data

- Never stored, shown or logged: `owner`, `federatedIdentity`, `deviceName`,
  `SSID`, `BSSID`, `timezone`, `certificateId`, the `schedule` blob, a raw
  answer. The parser copies only the fields of §4.1 and the info fields of
  §9.3 (`wire.info`) and drops the rest on receipt (V20; ECM rule 8, V6).
- The client id and MAC are written to `Fan ID`, `Status` and `Last Action`
  (the owner's own Composer) and to the log only as `...5301`, their last
  four hex digits. The address may be logged (it is needed to diagnose; the
  GitHub tooling and gitleaks refuse it on the way out).
- With `Debug Mode` On: one line per request and per answer, normalized:
  `-> fan #41 command {"fanOn":true,"fanSpeed":3}`,
  `<- fan #41 200 in 0.31 s: fan on/3 forward, light off/100`,
  `<- fan #42 info: Gen 3, firmware 02.00.0052, light kit yes, id ...5301`,
  `-> fan proxy CURRENT_SPEED 3`, `-> link 303 MATCH_LED_STATE true`.
- Without it: warnings and errors only, among them `fan #43 failed:
  timeout after 5.0 s (1 in a row)`, `Fan offline: 3 failures since 14:02`,
  `Fan online again after 3 min`, `Another fan (...5302) answers at
  10.0.2.151`, `The fan did not take speed 3 (reports 2)`, `Fan not
  answering: speed 3 not sent` (ECM P8, S9).
- A dev build installs a log redactor (`devloop.set_redactor`, owned by
  `fan/devcmds.lua`) that withholds any line containing one of the private
  key names in quotes and replaces the pinned client id and MAC by
  `<client-id>` and `<mac>`. The dev loop's property reports carry
  `Fan Address` and `Fan ID` to the VM; nothing of them goes to GitHub
  unreplaced ([`dev-loop.md`](dev-loop.md)).

## 4. State model and report rules

### 4.1 Fields, groups, the four values

| Field | From the fan | Group | Proxy value |
| --- | --- | --- | --- |
| `fan_on` | `fanOn` | fan | `CURRENT_SPEED` = `speed` when on, 0 when off |
| `speed` | `fanSpeed` 1–6 | fan | |
| `direction` | `fanDirection` "forward"/"reverse" | direction | `DIRECTION` FORWARD/REVERSE |
| `light_on` | `lightOn` | light | `LIGHT_BRIGHTNESS_CHANGED` = `level` when on, 0 when off |
| `level` | `lightBrightness` 1–100 (kept while off, M0) | light | |
| read only | `wind`, `windSpeed`, `awayModeEnabled`, `adaptiveLearning`, `schedule` (as set/empty), `fanTimer`/`lightTimer` (Gen 3, seconds left), `fanSleepTimer`/`lightSleepTimer` (Gen 1/2), `userData` (Gen 3), `clientId` | — | rows only (V22) |

Per field the model keeps: **confirmed** (the last value the fan reported,
nil while unknown), **in flight** (the value in the request now on the
wire), **wanted** (dirty: asked for, not yet sent) and **told** (per
group, the value last reported to the proxies). **Shown** = wanted, else in
flight, else confirmed: what LEDs and Toggle/Cycle work from. A group is
**busy** while one of its fields is wanted or in flight.

Generation: `fanTimer` or `lightTimer` in the dynamic shadow → "3";
`fanSleepTimer` or `lightSleepTimer` → "1/2"; else unknown (VERIFIED: AIO
`_infer_generation()`, MFR §1). Breeze: the `wind` key exists. Light kit:
`lightType` not empty (VERIFIED: HA `light.py`, MFR §2.4); without one the
light fields are ignored and the light is "not present" (ECM H4).

### 4.2 Sequence numbers and epochs

Every request gets `seq` (one counter for the device's life) and the current
`epoch` (bumped by an address change, Use Selected Fan, `Fan Address`
cleared, and `OnDriverDestroyed`). An answer whose epoch is not current, or
whose seq is not the one in flight, is dropped unread: the late answer of an
abandoned request never becomes state (ECM P9; ECC R2). With one request in
flight, answers cannot cross; the numbers make that checkable and survive an
address change in mid-flight.

### 4.3 What goes next

When the transport is idle (after the gap), the model sends, in this order:

1. the contact's info read, then its state read, while a contact is due;
2. a command, one group per request, groups in the order fan, direction,
   light, each from its wanted fields:
   - fan: wanted on at N → `{"fanOn":true,"fanSpeed":N}`; wanted off →
     `{"fanOn":false}`;
   - direction: `{"fanDirection":...}`;
   - light: wanted off → `{"lightOn":false}`. Wanted on at N: if the
     light shows on, `{"lightBrightness":N}`; if it shows off,
     `{"lightBrightness":N}` first, unless N is already its kept level or a
     level of this turn-on has already been answered, and then
     `{"lightOn":true}` (V14). A light target is done when an answer shows
     it, or once its `{"lightOn":true}` has been answered: at most two
     requests, also when the confirmed state was stale or a hold keeps
     changing the wanted level (a newer level then follows as a plain level
     change);
3. the due read: info when `INFO_REFRESH_S` has passed, else state;
4. nothing.

Every wanted field is sent even when it equals the confirmed value (a
confirmed state can be up to one poll old). A wanted field equal to the
value its in-flight request carries is cleared when that answer confirms it
(a repeated press costs nothing). A target is done once its request (for
the light, its requests) has been answered, whatever the answer shows: a
difference left is logged once and never retried (ECM S9), so no loop can
form.

### 4.4 Applying an answer

- **A command's answer** is the full new shadow (VERIFIED: AIO `request()`
  takes every answer as the new state, MFR §3; M0 sent no command, so the
  house fan's echo is first seen in K11 and K12): every field becomes
  confirmed; the fields it set start
  a 2.5 s settle window holding the answer's values. A sent field the answer
  does not show is logged once and the answer wins (ECM S9).
- **A read's answer**: each field becomes confirmed, except a field inside
  its settle window whose value contradicts the command's answer: that value
  is **held**, and believed only when the next read agrees (the fast window
  brings it 2 s later); if the next read agrees with the command instead,
  the held value is dropped, logged at debug. After the window, one read is
  enough (MFR §6 item 3; ECC R3).
- **A failure** drops what was in flight; wanted fields stay for the next
  turn (each Control4 command is tried once, ECM P8). The shown state falls
  back, so LEDs revert at once (V10, ECC C13).

### 4.5 Settled reports (R1–R9)

After each answer or failure the model compares, per group that is not
busy, confirmed with told; on a difference it calls `settled(group, why)`
and told becomes confirmed. `why` is "start" (the first contact after late
init: every group once, R6), "command" (the group was in this request),
"outside" (it was not, and no command was wanted: someone else changed the
fan; `outside(...)` also fires) or "online" (the contact after offline, R8).
Separately, a group going from busy to not busy calls `idle(group)`,
whether or not its value changed (the light closes its `CHANGING` there).

| Rule | Where it is kept |
| --- | --- |
| R1 one notification per real change | `settled` only on a difference; `fanproxy` and `light` compare with what they last sent too |
| R2 never older after newer | seq and epoch (§4.2) |
| R3 settle after a command | §4.4 |
| R4 confirmed only | proxies hear `settled`; LEDs hear `shown` |
| R5 bursts coalesce, steps from the target | wanted fields replaced (§4.3); Cycle and Toggle read the shown state; a group is reported only once idle, so a burst's intermediate answers fire nothing |
| R6 start | nothing of the fan's state to the proxies before the first contact; then every group once and the light's `ONLINE_CHANGED` true (`PRESET_SPEED`, the driver's own setting, goes at late init) |
| R7 offline | [section 6](#6-offline-online-rebooting-and-the-wrong-fan); never `CURRENT_SPEED 0` for offline |
| R8 back online | the contact's differences reported with why "online" |
| R9 no `ON`/`OFF` notifications | `fanproxy` sends `CURRENT_SPEED` only (the proxy would assume the preset on `ON`, FAN `42/_4-ON.md`) |

### 4.6 The fan: commands and intents

`fan/fanproxy.lua` handles the fan proxy's commands on 5001 (FAN
`41_fan_proxy_commands/`) and offers the same intents to the links:

| Input | Effect (from the shown state) |
| --- | --- |
| `ON` | off → on at the preset; on → nothing |
| `OFF` | off |
| `TOGGLE` | on → off; off → on at the preset |
| `SET_SPEED {SPEED}` | 0 → off; 1–6 → on at that speed; anything else refused and logged |
| `CYCLE_SPEED_UP` | off → 1; N → N+1; 6 stays 6 (V11) |
| `CYCLE_SPEED_DOWN` | off → nothing; N → N−1; 1 stays 1, never off (V11) |
| `DESIGNATE_PRESET {PRESET}` | 1–6 stored (`mf_preset_speed`), answered with `PRESET_SPEED {SPEED}` (whether the proxy needs it is K8; it is sent anyway); else refused |
| `SET_DIRECTION {DIRECTION}` | FORWARD/REVERSE → `fanDirection` (V18; ignored, logged, when `can_reverse` is False). A parameter of another name holding FORWARD or REVERSE is accepted too (FAN `41/_8` leaves it unnamed; the name `DIRECTION` is Snap One's template's, FPR §1.3) |
| `TOGGLE_DIRECTION` | the other direction (V18) |
| `GET_CURRENT_STATE` | once the state is known: `CURRENT_SPEED`, `DIRECTION` (with `can_reverse`), `PRESET_SPEED`; before that nothing |
| `settled(fan)` | `CURRENT_SPEED {SPEED}` as a number (FAN `42/_1`), NOTIFY on 5001 (API `25_proxy/_6-SendToProxy.md`) |
| `settled(direction)` | `DIRECTION {DIRECTION = "FORWARD"/"REVERSE"}` (with `can_reverse`) |
| late init | `PRESET_SPEED {SPEED}` with the persisted preset, else 3 |

Writes of the proxy's read/write variables (Is On, Current Selected Speed;
FAN `46_fan_variables/_1-FANVARIABLES.md`) are expected to arrive as these
commands (ASSUMED, ECC P5).

### 4.7 The light

`fan/light.lua` runs the `light_v2` side on 5002 on top of
`common/device.lua` (the press machine, keypad settings, LED colours).

- **Targets.** `SET_BRIGHTNESS_TARGET {LIGHT_BRIGHTNESS_TARGET, RATE}`
  (LV2 `10_light_v2_commands/_1.5-SETBRIGHTNESSTARGET.md`), `SET_LEVEL` and
  `RAMP_TO_LEVEL {LEVEL, TIME}`, `ON` (Default On Brightness), `OFF` (0),
  `TOGGLE` (shown on → 0, off → Default On Brightness) and the taps all end
  in one target: whole percent, 0 means off. The rate is not honoured: the
  light has no fade (MFR §9; ECM S4) and the target is sent at once.
- **The protocol.** At a target: `LIGHT_BRIGHTNESS_CHANGING {LIGHT_BRIGHTNESS_CURRENT
  = told level (0 when off), LIGHT_BRIGHTNESS_TARGET = target, RATE = 0}`
  and the target wanted; a `CHANGING` is then open. `idle(light)` closes it
  with `LIGHT_BRIGHTNESS_CHANGED {LIGHT_BRIGHTNESS_CURRENT = confirmed}`.
  `settled(light)` while nothing is open sends `CHANGED` (a change made
  elsewhere). A target the model refuses closes at once with the told
  level. Never `LIGHT_LEVEL`, never a `CHANGED` per step (LV2
  `35/_12-LIGHTLEVEL.md`, `35/_10.3-LIGHTBRIGHTNESSCHANGING.md`). That
  `CHANGING` fires no programming is ASSUMED (the light's events follow
  `CHANGED`).
- **Default On Brightness** is device.lua's `preset` setting (default 100),
  set from Composer as `SET_PRESET_LEVEL {LEVEL}` because of
  `supports_default_on` (LV2 `10_light_v2_commands/_6-SET_PRESET_LEVEL.md`;
  VERIFIED-house, HUE #59) and answered with `PRESET_LEVEL` as device.lua
  does. Unlike the Hue Light, whose `ON` goes to 100 %, `ON` here goes to
  Default On Brightness (#6 decision 11).
- **Holds** (device.lua's machine; LSR §1.5): top, or Toggle while off,
  ramps up toward 100; bottom, or Toggle while on, down toward 1; bottom
  while off does nothing; from off the light turns on at 1 % and the ramp
  starts 600 ms later (`dev.dim_after_on`). The ramp sends `CHANGING
  {current, target = 100 or 1, RATE = hold rate × distance / 100}`, then
  every 500 ms wants the linear estimate (one request in flight, latest
  wins); the release freezes it, wants the estimate, and `idle` closes it.
  Hold rates are device.lua's `hold_up`/`hold_down` (default 5000 ms for the
  whole range, VERIFIED-doc LV2 `10/_10-SET_HOLD_RATE_UP.md`).
- **Advanced Lighting Scenes** (`reduced_als_support`, LV2
  `45_Light_V2_advanced_lighting_scene/_1.3-REDUCEDALSSUPPORT.md`): targets
  as above; `RAMP_SCENE_UP`/`RAMP_SCENE_DOWN {SCENE_ID}` start a ramp as a
  hold does, toward 100 or 1 at the hold rate; `SET_BRIGHTNESS_STOP`,
  `STOP_SCENE_RAMP` and `STOP_RAMP_SCENE` (the docs spell it both ways,
  `_4.2-STOPRAMPSCENE.md`) freeze a running ramp, else do nothing but close
  an open `CHANGING`. That the ramps are delivered is ASSUMED (the Hue Light
  never saw them; LSR §1.3).
- **`SYNCHRONIZE`**: `ONLINE_CHANGED {STATE}` and, once known, `CHANGED`
  (as the Hue Light; ASSUMED undocumented).
- **No light kit**: the light's `ONLINE_CHANGED` false for good, its
  commands refused and logged, `dev.is_on()` nil (its LEDs untouched).

## 5. Links and keypad LEDs

### 5.1 Fan links (300–308)

Each link keeps the time of its last `DO_PUSH`. `DO_PUSH` acts at once (the
SDK advises acting on the press when hold and click mean the same, KP
`62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`). `DO_CLICK`
acts only when no `DO_PUSH` arrived on that link in the last 10 s (a keypad
that sends clicks alone; FPR §7 item 5); `DO_RELEASE` does nothing. There is
no hold and no repeat. A double tap is two pushes and acts twice (V12).
Several keypads on one link share it (ECC C6).

| Link | Fan off | Fan on at N | Offline | Foreign, Gen 4, not a fan, unset, rebooting | LED lit while (shown) |
| --- | --- | --- | --- | --- | --- |
| 300 Fan Off | off (sent, V8) | off | tried once | refused; LED unchanged | fan off |
| 301–306 Fan Speed M | on at M | on at M | tried once | refused | fan on at speed M, or at the speed `Speed M Link Also Lit At` names (V26) |
| 307 Fan Toggle | on at the preset | off | tried once | refused | fan on |
| 308 Fan Cycle | on at 1 | N+1, 6 → 1 (V11) | tried once, from the shown speed | refused | fan on |

"Tried once" is ECM P8: sent as the reachability check, dropped if it
fails, never replayed.

**LEDs.** On every `shown` change, `MATCH_LED_STATE {STATE = true|false}` as
a COMMAND (the default below 1000, API `25_proxy/_6-SendToProxy.md`) goes to
each fan link whose lit state changed; all nine after the first contact, on
`REQUEST_BUTTON_COLORS` (that link only) and when a keypad is bound to a
link (that link). While the fan state is unknown nothing is sent, except
`STATE` false to a link just bound (ECC C14). While offline the LEDs keep
the last state (ECC Q5). A change of a `Speed M Link Also Lit At` row
re-sends that link's LED.

**Colours.** With `Speed LED Colors` absent or `Keypad's own` (the default,
and all of v1 unless V27 ships), the fan links send no `BUTTON_COLORS`:
the button shows the on and off colours set on the keypad itself, one pair
per button, so a linked fan button takes its colours from the keypad's own
LED colour settings ([`migration-design.md`](migration-design.md#3-phases),
Phase 5). With V27 and `Per speed`: whenever a speed link becomes lit at
speed s, or is asked with `REQUEST_BUTTON_COLORS` while lit at s,
`BUTTON_COLORS {ON_COLOR = Speed s LED Color, OFF_COLOR = Speed LED Off
Color, CURRENT_COLOR = the colour now meant}` (6-digit hex, the form
`common/device.lua` sends after Snap One's template) goes on that link just
before its `MATCH_LED_STATE`; a dark link and the Off, Toggle and Cycle
links get none. Whether a keypad takes them is K6. A `SET_BUTTON_COLOR`
arriving on a fan link (KP `62/_1` documents the command without saying who
sends it or what its `BUTTON ID` means there) is logged at debug and
ignored.

### 5.2 Light links (200–202)

`common/device.lua` unchanged in behaviour (LSR §1.6): taps (top → Default
On Brightness, bottom → off, toggle by the shown state), the 400 ms hold,
the 600 ms dim after the turn-on, the 1 s click guard after a hold, the LED
rule (top and toggle lit while on, bottom lit while off through its
inverted default colours), `BUTTON_COLORS`, `BUTTON_INFO` and the colours
from `SET_BUTTON_COLOR` (`has_leds`). `dev.is_on()` returns the light's
shown on state, so its LEDs, too, show the target at once (V10). Offline,
foreign and the rest: as the fan links' columns. A linked light button shows
the colours of the light's settings page if K6 finds that keypads take
`BUTTON_COLORS` over a link, else the keypad's own; the migration's Phase 5
sets them by K6's answer. In the second case device.lua's bottom link, which
counts on its inverted default colours to be lit while the light is off,
would be lit while it is on: device.lua then sends the bottom link the
inverted state instead (Lua only, the common agent's, if K6 says so).

### 5.3 Bindings and Keypad Links

`OnBindingChanged(id, class, bound, other_device, other_binding)` (API
`9_helper/_12-OnBindingChanged.md`; it arrives for control bindings such as
these) is wrapped by `dev.binding_changed`, so calls before late init wait
for it (as the Hue drivers). For 200–202 it calls `dev.update_leds(true)`,
for 300–308 the link's LED; for all twelve the `Keypad Links` bookkeeping.
At late init each link is read with `C4:GetBoundConsumerDevices(C4:GetDeviceID(),
id)` (API `32_serial_network_device/_3-GetBoundConsumerDevices.md`); a link
answering nil is read once more 5 s later (one nil is "unknown", ECC C15).
Names come from `C4:GetDeviceDisplayName` (API `32/_6`). Binding a link
turns the button's LED Behavior to Follow Connection by itself and
disconnecting does not turn it back (VERIFIED-house, HUE
`docs/composer-remote.md` "Learned 2026-10-27"); the driver never touches
a keypad's settings (ECC C4).

## 6. Offline, online, rebooting and the wrong fan

### 6.1 Phases

| Phase | Entered | Online variable | Light `ONLINE_CHANGED` | Events | Commands |
| --- | --- | --- | --- | --- | --- |
| unset | `Fan Address` empty or not IPv4 | "0" | false | none | refused |
| waiting | start, a new address | persisted value | nothing sent (the proxy starts online, LV2 `35/_15`) | none | held until the contact's identity check |
| online | a contact succeeds | "1" | true | Fan Online, if the last phase was offline-like or the persisted flag was "0" (ECC D9) | sent |
| offline | the 3rd failure in a row | "0" | false | Fan Offline, if it was online or the persisted flag was "1" | tried once each |
| rebooting | Reboot Fan sent | unchanged | unchanged | none | refused |
| foreign, Gen 4, not a fan | §3.5, §3.6 | "0" | false | Fan Offline, as for offline | refused |

"Offline-like" is offline, foreign, Gen 4 and not a fan. `mf_online` is
written on every change of the Online variable.

### 6.2 Offline (#6 decision 10)

The proxies keep their last values; nothing is sent to the fan proxy (it
has no online notion, FPR §1.4); the light's controls go grey through
`ONLINE_CHANGED` false; LEDs keep the last state; Status S7, S8 or S9 names
the time it went quiet. The driver cannot tell a power cut from a stuck
Wi-Fi module while the blades turn (ECM P3, P4), which is why the state is
kept, not turned off.

### 6.3 Back online

The first success after a streak starts a contact: identity and firmware
(a new firmware is recorded with its date, ECM F1; a changed light kit
changes `Fan Model` and the light, ECM H3), then the state; differences are
reported with why "online", Fan Online fires once, the fast window opens.
Nothing is re-sent, whatever Control4 last commanded (ECM P2; a fan stopped
with the wall control's pull tab stays stopped).

### 6.4 Reboot Fan

Only while online: `{"reboot":true}` with a 3 s timeout, its outcome
ignored; phase rebooting; reads every 10 s; the first answer starts a
contact. After 120 s without one the phase is offline (with its event).
While offline: not sent (L12; the module cannot hear it, and power at the
wall is the remedy, ECM P4). Unset, foreign, Gen 4 or not a fan: L13; while
rebooting: L20.

## 7. Texts

Exact texts; `10.0.2.151` stands for the address, `MF_00005E005301` for a
client id, `...5302` for the last four hex digits of another fan's MAC,
`14:02` for a time (`HH:MM`, or `MM-DD HH:MM` once older than 24 h), `3`,
`40` and such for values. ASCII only, except where the Hue drivers already
showed a character on this house. `fan/texts.lua` holds every string; its
spec asserts them verbatim.

### 7.1 Status

| Id | When | Text |
| --- | --- | --- |
| S1 | unset (no Find Fans in the build) | `Not set up: enter the fan's address in Fan Address` |
| S2 | unset (with Find Fans) | `Not set up: Find Fans, or enter the fan's address in Fan Address` |
| S3 | `Fan Address` not IPv4 (the typed text cut to 24 characters) | `Fan Address "fan.local" is not an IPv4 address` |
| S4 | waiting | `Waiting for the fan at 10.0.2.151` |
| S5 | online | `Online: fan speed 3, light 40 %`; the grammar: `Online: fan ` + (`off` or `speed N`, then ` reverse` when reversed, ` Breeze` when `wind` is on) + `, ` + (`light off`, `light N %` or `no light kit`). For example `Online: fan off, light off`, `Online: fan speed 6 reverse Breeze, light 100 %` |
| S6 | online, a needed field missing (ECM F3) | `Online, but the fan reports no fanSpeed; speed control paused` (the key: `fanOn`, `fanSpeed` → speed; `fanDirection` → direction; `lightOn`, `lightBrightness` → light) |
| S7 | offline after timeouts or refusals, a state known | `Not answering at 10.0.2.151 since 14:02; showing last state` |
| S8 | the same, no state known in this run | `Not answering at 10.0.2.151 since 14:02; state unknown` |
| S9 | offline after unusable answers | `No usable answer from 10.0.2.151 since 14:02; showing last state` (or `; state unknown`) |
| S10 | rebooting | `Rebooting the fan's Wi-Fi module (sent 14:02)` |
| S11 | foreign | `Another fan (...5302) answers at 10.0.2.151; nothing is sent` |
| S12 | Gen 4 | `10.0.2.151 is a Gen 4 fan; this driver controls Gen 1 to 3 only` |
| S13 | not a fan | `10.0.2.151 answers, but not as a Modern Forms fan; nothing is sent` |
| S14 | controller older than 3.3.0, in place of S4 or S5 | `Controller OS 3.2.1 is older than 3.3.0; the light may misbehave` |

Priority when several apply: S3/S1/S2, then S11–S13, then S10, then S7–S9,
then S14, then S4–S6. The Status row is written only when its text changes.
The longest, S9 with a 15-character address and a date, stays under 75.

### 7.2 Last Action

| Id | After | Text |
| --- | --- | --- |
| L1 | first contact pinned a fan | `Learned fan MF_00005E005301 (Gen 3) at 10.0.2.151` |
| L2 | the pinned fan at a typed or picked new address | `Same fan MF_00005E005301, now at 10.0.2.152` |
| L3 | Use Selected Fan re-pointed | `Now using fan MF_00005E005302 (was MF_00005E005301)`; with no fan pinned before, `Now using fan MF_00005E005302 at 10.0.2.151` |
| L4 | Use Selected Fan, already this fan here | `Already using fan MF_00005E005301 at 10.0.2.151` |
| L5 | Use Selected Fan, no answer | `No fan answers at 10.0.2.151; nothing changed` |
| L6 | Use Selected Fan, Gen 4 or not a fan | `10.0.2.151 is not a Gen 1 to 3 Modern Forms fan; nothing changed` |
| L7 | Use Selected Fan with nothing to use | `Nothing to use: enter the fan's address in Fan Address`; with Find Fans, `Nothing to use: pick a fan in Found Fans, or enter Fan Address` |
| L8 | Find Fans found some | `Found 2 fans: pick one in Found Fans, then Use Selected Fan` (`Found 1 fan: pick it in Found Fans, then Use Selected Fan`) |
| L9 | Find Fans found none | `No Modern Forms fan answered on this network` |
| L10 | Find Fans could not send | `Find Fans could not send its query on this controller` |
| L11 | Reboot Fan sent | `Reboot sent to the fan's Wi-Fi module at 14:02` |
| L12 | Reboot Fan while offline | `Reboot not sent: the fan is not answering (power it off for 10 s)` |
| L13 | Reboot Fan, unset, foreign, Gen 4 or not a fan | `Reboot not sent: no fan of this device answers at 10.0.2.151` |
| L20 | Reboot Fan while rebooting | `Reboot already sent at 14:02; waiting for the fan` |
| L21 | Use Selected Fan, the picked fan not at its address any more | `The fan at 10.0.2.151 is not the one picked; Find Fans again` |
| L14 | Turn Off Away Mode done | `Away mode turned off (the Modern Forms app can turn it on again)` |
| L15 | it was off already | `Away mode is already off` |
| L16 | Turn Off Adaptive Learning done | `Adaptive learning turned off (the Modern Forms app can turn it on)` |
| L17 | it was off already | `Adaptive learning is already off` |
| L18 | either, not online | `Not changed: the fan is not answering` |
| L19 | either, the answer still shows it on | `The fan did not take it; it still reports away mode on` (`... adaptive learning on`) |
| — | Migration Report | [`migration-design.md`](migration-design.md#4-the-migration-report) |

Every Last Action is also logged with `log.always` (as `dev.result` does).

### 7.3 The other rows

| Row | Text |
| --- | --- |
| Fan ID | `MF_00005E005301 (MAC 00:00:5e:00:53:01)`; empty before the first contact |
| Fan Model | `Gen 3, fan 1811-5-54, light kit F4IN-120V-R1-30, Breeze` (M0's values); `Gen 3, fan 1811-5-54, no light kit`; `Gen 1/2, ...`; `Gen ?, ...` |
| Firmware | `02.00.0052 (motor 03.00.0000) since 2026-10-27`; after a change `02.00.0060 (motor 03.00.0000) since 2026-11-02, was 02.00.0052` |
| Last Seen | `2026-10-27 18:02:10, answered in 0.31 s`, written at most every 10 s |
| Last Change By | `<who> at 14:05`, written on each change Control4 did not make. `<who>` from `userData`: `ble` → `Remote or wall control`; `local_wifi` → `Modern Forms app or another local client`; `cloud` → `Modern Forms cloud (app away, voice assistant)`; `sleep_timer` → `The fan's sleep timer`; `away_mode` → `The fan's away mode`; `schedule` → `A schedule in the Modern Forms app`; anything else, `none` or absent (Gen 1/2) → `Outside Control4 (source not reported)` (VERIFIED values: AIO `const.py`, MFR §2.2; what an RF remote reports is K16) |
| Fan Automations | `None`, or `Active: ` and the items joined by `, `: `schedule`, `away mode`, `adaptive learning`, `fan timer 25 min`, `light timer 10 min` (Gen 3, minutes rounded up), `fan timer set`, `light timer set` (Gen 1/2). Written when the text changes. `schedule` counts when the field is a non-empty string (ASSUMED: empty means none; M0? the house fan's value with no schedule in the app) |
| Keypad Links | items: `5 of 12 links bound`, then one per bound keypad, `Fan Speed 3: Example Keypad (456)` (link name without "Button Link", the keypad's display name, its device id) |
| Found Fans | items: `MF_Fan_005301 at 10.0.2.151`, with ` (this device's fan)` when its MAC is the pinned one; at most 16 |
| Speed N Link Also Lit At | the dealer's choice among `No other speed`, `Speed 1` … `Speed 6`; no driver text |
| Speed LED Colors (V27) | the dealer's choice among `Keypad's own`, `Per speed`; no driver text |
| Stock Device | Composer's selection; the texts naming it are the Migration Report's (§2.5) |

## 8. Persistence and restore

| Key (`C4:PersistSetValue`) | Value | Written | Read |
| --- | --- | --- | --- |
| `mf_identity` | `{ client_id = "MF_00005E005301", mac = "00005E005301", generation = "3", address = "10.0.2.151", learned = <epoch s> }` | first contact, Use Selected Fan, a followed address | late init |
| `mf_info` | `{ fan_type, light_type, motor_type, firmware, mcu_firmware, firmware_since = "2026-10-27", firmware_was }` | when it changes | late init |
| `mf_online` | `true`/`false` | when the Online variable changes | `OnDriverInit`, D9's comparison |
| `mf_preset_speed` | 1–6 | `DESIGNATE_PRESET` | late init |
| device.lua's `preset_level`, `hold_rate_up`, `hold_rate_down`, `button_<n>_<on/off>_color` | as device.lua | as device.lua | as device.lua |
| the migration's keys | [`migration-design.md`](migration-design.md#4-the-migration-report) | | |

Read with `(C4:PersistGetValue(key))` (a never-written key returns no value
at all on the house: HUE #298). Not persisted: the fan's state (FUND
`24_persisting_driver_data/_1-PERSISTINGDRIVERDATA.md` names a light's on
state as data that does not belong there), anything private.

| Event | What survives | Basis |
| --- | --- | --- |
| update in place, Director restart, reboot | everything above and every property | VERIFIED-house (HUE `docs/design.md` "Storage"); FUND `24/_1` |
| project restore onto the same controller | properties from the backup; the store as it is | FUND `24/_1` [silent on the store] |
| project restore onto a new controller | properties (`Fan Address`, `Poll Interval (s)`, the `Fan ID` row); the store maybe empty: then the identity is parsed back from `Fan ID` and checked at the first contact (ECC D10); the light's keypad settings and colours fall back to defaults (a known limit, LSR Q6) | ASSUMED, parked to the first restore |
| delete and re-add | nothing: a new device id, empty store, links and programming gone | VERIFIED-house; the manual says never to do it (ECC D8) |

## 9. Modules and interfaces

### 9.1 Layout and routing

```
src/modernforms_fan/
  driver.lua          coordinator: wiring, lifecycle, properties, actions, events, variable, TestCondition
  driver.xml          coordinator: section 2
  fan/wire.lua        pure: bodies, answers, identity helpers
  fan/transport.lua   the one-request-in-flight HTTP slot over C4:url
  fan/model.lua       the state model, the scheduler, phases (sections 3.4-3.6, 4, 6)
  fan/texts.lua       every owner-visible string (section 7)
  fan/fanproxy.lua    the fan proxy (5001): commands, notifications, preset, intents
  fan/links.lua       the fan links (300-308), their LEDs, the Keypad Links bookkeeping
  fan/light.lua       the light_v2 side (5002) on common/device.lua
  fan/devcmds.lua     dev builds only: signed development commands, Dev State, the redactor
  fan/discovery.lua   only with V5a: the mDNS query and its parser
src/common/           dispatch.lua (per-binding routing), device.lua (proxy binding option), log.lua, devloop.lua
```

`require("fan.x")` resolves inside the package and in the specs (`.busted`
puts `src/modernforms_fan/` on the path; `tests/helpers/fake_c4.lua`
already forgets `fan.*` between loads). Modules take what touches Director
as arguments (`on`, `send`, `timer`, `now`, `store`), so each spec runs
without the others and without new fake-runtime calls.

| Entry point | Binding | Goes to |
| --- | --- | --- |
| `ReceivedFromProxy` | 5001 | `fan/fanproxy.lua` |
| `ReceivedFromProxy` | 5002 | `fan/light.lua` and device.lua's `BUTTON_ACTION`, `SET_BUTTON_COLOR`, `SET_PRESET_LEVEL`, `SET_HOLD_RATE_UP`/`DOWN` |
| `ReceivedFromProxy` | 200–202 | device.lua's `DO_PUSH`, `DO_CLICK`, `DO_RELEASE`, `REQUEST_BUTTON_COLORS` |
| `ReceivedFromProxy` | 300–308 | `fan/links.lua` |
| `ReceivedFromProxy` | any other | dropped, one debug line |
| `OnBindingChanged` | 200–202, 300–308 | §5.3 |
| `ExecuteCommand` (LUA_ACTION) | — | `dispatch.commands` (the actions) |
| `OnPropertyChanged` | — | `dispatch.properties` |
| `TestCondition` | — | `driver.lua` (§2.7) |
| `ReceivedFromNetwork` | 6001 | `fan/discovery.lua` (V5a only) |

### 9.2 `common/dispatch.lua` and `common/device.lua` (changes)

LSR §2.3 and §5.1 found that both proxies send `ON`, `OFF` and `TOGGLE`, so
proxy handlers are chosen by binding first (API `25_proxy/_5-ReceivedFromProxy.md`
passes the binding).

- `dispatch.binding(id)` returns the handler table of that binding
  (`tonumber(id)`), created on first use; handlers keep the signature
  `fn(binding, params)`.
- `dispatch.received_from_proxy(binding, command, params)`: when a table
  exists for the binding, only its handler is called (none: a debug line);
  when none exists, `dispatch.proxy[command]` as today, so a one-proxy
  driver is unchanged. Errors are contained as today.
- `device.new(opts)` gains `opts.proxy_binding` (default 5001, kept as
  `device.PROXY_BINDING`), used by `notify`, `BUTTON_INFO`, the settings'
  answers and `proxy_id()`; and registers through `dispatch.binding`: on
  the proxy binding `BUTTON_ACTION`, `SET_BUTTON_COLOR` (the light's
  settings page, LV2 `10_light_v2_commands/_12-SET_BUTTON_COLOR.md`) and
  each setting's command, on 200, 201 and 202 `DO_PUSH`, `DO_RELEASE`,
  `DO_CLICK` and `REQUEST_BUTTON_COLORS` (a `SET_BUTTON_COLOR` on a link,
  which today's command-only table would also take, is logged and ignored,
  as on the fan links). It no longer writes `dispatch.proxy`. Nothing
  else changes; `tests/spec/device_spec.lua` keeps pinning the behaviour.
- The fan driver creates it as `device.new({ prefix = "Modern Forms Fan",
  noun = "light", settings = { "preset", "hold_up", "hold_down" },
  proxy_binding = 5002 })`.

### 9.3 `fan/wire.lua` (pure)

```lua
wire.PATH, wire.G4_PATH = "/mf", "/device"
wire.HEADERS = { ["Content-Type"] = "application/json" }
wire.QUERY_STATE, wire.QUERY_INFO = '{"queryDynamicShadowData":1}', '{"queryStaticShadowData":1}'
wire.QUERY_G4, wire.REBOOT = '{"query":true}', '{"reboot":true}'
wire.body(fields) -> string | nil, why
  -- fields: exactly one group's: { fan_on = bool, speed = 1..6 } | { direction = "forward"|"reverse" }
  --   | { level = 1..100 } | { light_on = bool } | { away = false } | { learning = false }
  -- the bodies of section 3.1, keys in that order; refuses mixes, ranges and anything else
wire.decode(text) -> table | nil, "empty"|"json"   -- C4:JsonDecode in pcall; an object only
wire.state(obj) -> st | nil, "json"                 -- nil without clientId
  -- st = { client_id, fan_on, speed, direction, light_on, level, wind, wind_speed, away, learning,
  --        schedule_set, fan_timer, light_timer, fan_sleep_timer, light_sleep_timer, user_data,
  --        generation = "3"|"1/2"|nil, unknown = { "key", ... } }   -- missing = nil, private keys dropped
wire.info(obj) -> info | nil, "json"
  -- info = { client_id, mac (12 uppercase hex), fan_type, light_type, has_light, motor_type,
  --          firmware, mcu_firmware, brand }                       -- nothing else is copied
wire.is_g4(obj) -> bool                -- systemType contains "fan_g4"
wire.mac12(text) -> "00005E005301" | nil
wire.same_fan(pin, client_id) -> bool  -- case-insensitive
wire.ipv4(text) -> "10.0.2.151" | nil  -- trimmed dotted quad, each part 0..255
```

### 9.4 `fan/transport.lua`

```lua
local t = transport.new({ now = fn_ms, timer = fn(ms, cb) -> obj with :Cancel(),
                          url = fn() -> C4:url(), on_idle = fn(), log = log })
t:set_address(addr)          -- nil/"" or an IPv4 string; bumps t.epoch, also when addr is unchanged
t:send(req, cb) -> seq | nil, "busy"|"no address"|"stopped"
  -- req = { kind = "state"|"info"|"command"|"g4"|"reboot", path = wire.PATH|wire.G4_PATH,
  --         body = string, timeout = seconds (default 5) }
  -- cb(result) runs from OnDone, once; never for a stale epoch or after stop()
  -- result = { seq, epoch, kind, ok, code, json, err = nil|"timeout"|"connect"|"http"|"empty"|"json",
  --            detail, ms }
t:busy() -> bool             -- a request in flight, or the gap after it not over
t:stop()                     -- OnDriverDestroyed, Fan Address cleared
-- after each result's cb returns: GAP_MS later, on_idle()
```

`json` is the decoded object (`wire.decode`); the transport classifies per
§3.3 and knows nothing of fields.

### 9.5 `fan/model.lua`

```lua
local m = model.new({ transport = t, wire = wire, now = fn_ms, clock = fn_s (os.time),
                      timer = fn(ms, cb), store = { get = fn(k), set = fn(k, v) }, log = log,
                      listener = { ... } })
m:start(address, pin_from_row)   -- late init: loads mf_identity (else pin_from_row), mf_info, mf_online; a contact if an address is set
m:stop()
m:set_address(text) -> nil | "invalid"
m:set_poll_interval(seconds)     -- clamped to 10..120
m:want(fields) -> true | false, why
  -- fields: { fan_on, speed } | { direction } | { light_on, level } (any of the three groups at once)
  -- why: "unset"|"invalid address"|"foreign"|"gen4"|"notfan"|"rebooting"|"no light kit"|"no <key>"|"range"
m:use_fan(address, mac12_or_nil, cb)   -- Use Selected Fan; cb(result_key, args) for texts.result
m:reboot(cb)                     -- cb(result_key, args)
m:turn_off(which, cb)            -- which "away"|"learning"; cb(result_key, args)
m:phase() -> phase, detail       -- detail = { since, address, other_client_id, failure = "timeout"|"data", sent }
m:confirmed() -> st | nil        -- the fields of section 4.1
m:shown() -> { fan_on, speed, direction, light_on, level }   -- per field wanted > in flight > confirmed
m:busy(group) -> bool            -- "fan"|"direction"|"light"
m:identity() -> pin | nil        -- { client_id, mac, generation, address }
m:info() -> info | nil           -- mf_info plus has_light, has_wind
m:status_view() -> v             -- the table texts.status takes (section 9.6)
m:debug() -> table               -- seq, phase, told per group, busy groups, last ms (Dev State)

-- listener (each optional), all called after the model's own state is consistent:
listener.settled(group, st, why)      -- why "start"|"command"|"outside"|"online" (section 4.5)
listener.idle(group, st)              -- the group went from busy to not busy
listener.shown(shown)                 -- the shown state changed
listener.phase(phase, detail, old)    -- section 6.1
listener.info(pin, info)              -- identity, model or firmware learned or changed
listener.seen(at_s, ms)               -- an answer arrived
listener.outside(groups, user_data, at_s)   -- a change Control4 did not make
listener.automations(st)              -- away, learning, schedule or a timer changed
listener.result(key, args)            -- an automatic Last Action: L1, L2
```

### 9.6 `fan/texts.lua` (pure)

```lua
texts.status(v) -> string           -- v = { phase, address, typed, since, now, failure, known, other,
                                    --       sent, st, has_light, has_wind, missing, os, find_fans }; section 7.1
texts.result(key, args) -> string   -- keys "learned" L1, "moved" L2, "now_using" L3, "already" L4,
                                    -- "no_answer" L5, "not_a_fan" L6, "nothing_to_use" L7, "found" L8,
                                    -- "found_none" L9, "find_failed" L10, "reboot_sent" L11,
                                    -- "reboot_offline" L12, "reboot_refused" L13, "reboot_pending" L20, "away_off" L14,
                                    -- "away_already" L15, "learning_off" L16, "learning_already" L17,
                                    -- "not_answering" L18, "not_taken" L19, "not_picked" L21
texts.fan_id(pin) ; texts.fan_model(pin, info, has_wind) ; texts.firmware(info)
texts.last_seen(at_s, ms) ; texts.change_by(user_data, at_s, now_s) ; texts.automations(st, generation)
texts.keypad_links(rows) -> { "5 of 12 links bound", ... }   -- rows: { link_name, keypad_name, device_id }
texts.found_fans(list, pin) -> { ... }
texts.suffix(id) -> "...5302" ; texts.mac(mac12) -> "00:00:5e:00:53:01" ; texts.clock(at_s, now_s) -> "14:02"
```

### 9.7 `fan/fanproxy.lua`

```lua
local fp = fanproxy.new({ model = m, on = fn(binding, command, handler), send = fn(command, params),
                          store = store, can_reverse = bool, log = log })
-- registers on 5001: ON OFF TOGGLE SET_SPEED CYCLE_SPEED_UP CYCLE_SPEED_DOWN DESIGNATE_PRESET
--                    SET_DIRECTION TOGGLE_DIRECTION GET_CURRENT_STATE
fp:late_init()                     -- PRESET_SPEED
fp:settled(group, st, why)         -- CURRENT_SPEED / DIRECTION when different from what it last sent (or why "start")
fp:preset() -> 1..6
fp:speed(n) ; fp:on() ; fp:off() ; fp:toggle() ; fp:cycle(step, wrap) ; fp:direction("forward"|"reverse"|"toggle")
  -- each -> true | false, why (m:want's); the links call these
fp:debug() -> { told_fan, told_dir, notify_fan, notify_dir, preset }
```

`send` is `C4:SendToProxy(5001, command, params, "NOTIFY")`.

### 9.8 `fan/links.lua`

```lua
links.LINKS = { [300] = "Fan Off", [301] = "Fan Speed 1", ..., [306] = "Fan Speed 6", [307] = "Fan Toggle",
                [308] = "Fan Cycle" }
links.LIGHT_LINKS = { [200] = "Light Top", [201] = "Light Bottom", [202] = "Light Toggle" }   -- bookkeeping only
local lk = links.new({ model = m, fan = fp, on = fn, send = fn(binding, command, params), now = fn_ms,
                       timer = fn, bound = fn(link) -> C4:GetBoundConsumerDevices table|nil,
                       display = fn(device_id) -> name, list = fn(items), log = log })
-- registers on 300..308: DO_PUSH DO_CLICK DO_RELEASE REQUEST_BUTTON_COLORS
lk:shown(shown)                    -- MATCH_LED_STATE on the fan links whose lit state changed
lk:refresh()                       -- all nine (after the first contact)
lk:set_also(speed, also)           -- V26: speed 1..6, also 1..6 or nil (from "Speed N Link Also Lit At")
lk:set_colors(mode, colors, off)   -- V27 only: mode "keypad"|"per_speed", colors[1..6] and off as "rrggbb"
lk:binding_changed(id, bound, other_device, other_binding)   -- any of the twelve link ids
lk:late_init()                     -- the GetBoundConsumerDevices reads and the 5 s second look
lk:stop()
lk:debug() -> { leds = { [300] = false, ... }, bound = n }
```

`send(binding, command, params)` is `C4:SendToProxy(binding, command, params,
kind)` with kind COMMAND for `MATCH_LED_STATE` and NOTIFY for
`BUTTON_COLORS` (as device.lua); `list` writes `Keypad Links`
(`C4:UpdatePropertyList(name, items joined by ",", items[1])`). The
coordinator's property handlers parse rows 14–27 (`Speed 2` → 2, `0,0,255` →
`0000ff`) and call `set_also` and `set_colors`.

### 9.9 `fan/light.lua`

```lua
local lt = light.new({ model = m, dev = dev, on = fn, now = fn_ms, timer = fn, log = log })
-- registers on 5002: ON OFF TOGGLE SET_LEVEL RAMP_TO_LEVEL SET_BRIGHTNESS_TARGET SET_BRIGHTNESS_STOP
--                    STOP_SCENE_RAMP STOP_RAMP_SCENE RAMP_SCENE_UP RAMP_SCENE_DOWN SYNCHRONIZE
-- sets dev.is_on, dev.on_click, dev.on_hold, dev.on_finish
lt:settled(st, why) ; lt:idle(st) ; lt:shown(shown) ; lt:phase(phase, detail, has_light) ; lt:stop()
lt:debug() -> { told_level, changing_open, notify_light, ramping }
```

The `dev` it uses: `dev.notify(command, params)` (to 5002), `dev.setting(name)`,
`dev.update_leds(force)`, `dev.dim_after_on(h, fn)`, `dev.holding(h)`; its
spec may stub exactly these.

### 9.10 `fan/devcmds.lua` and `fan/discovery.lua`

`devcmds.new({ model, fan, links, light, prop, inject = fn(binding, command, params), log })`
returns the table for `devloop.set_signed_commands` ([section 12](#12-dev-loop-actions-and-toolsregresssh));
`devcmds.redactor(get_pin)` returns the function for `devloop.set_redactor`
(§3.7). `tools/build.sh` adds `fan/devcmds.lua` to its `DEV_ONLY_FILES`.

Only with V5a: `discovery.query()` → the bytes of one DNS question for
`_easylink._tcp.local` type PTR, class IN with the unicast-response bit;
`discovery.parse(datagram)` → `{ { instance = "MF_Fan_005301", address =
"10.0.2.151", port = 80, mac = "00005E005301", firmware = "02.00.0052" }, ... }`
from the answer and additional records (PTR, SRV, TXT, A; name compression
followed at most 16 hops), keeping only TXT `Protocol=com.modernforms.fan`
(M0), never raising on a malformed datagram; `discovery.new({ open, send,
close, timer, log })` with `:find(cb)` (the query, sent twice 1 s apart,
answers collected for 3 s, the binding closed, `cb(list)`) and
`:received(binding, port, data, from)`. The calls behind `open`/`send`/`close`
are the combination K10 found working.

### 9.11 Message flows

A tap on a keypad button linked to **Fan Speed 3** while the fan runs at 1:

1. `ReceivedFromProxy(303, "DO_PUSH")` → `links` → `fp:speed(3)` →
   `m:want({ fan_on = true, speed = 3 })`; `shown` → `MATCH_LED_STATE` false
   on 301, true on 303; the transport is idle → `{"fanOn":true,"fanSpeed":3}`,
   seq 41.
2. `DO_CLICK` on 303, 0.2 s after the push: nothing.
3. 0.3 s later the answer (on at 3): confirmed; the fan group idle and
   different from told → `settled("fan", st, "command")` →
   `CURRENT_SPEED {SPEED = 3}`; the proxy fires `speed_changed`; settle
   window and fast window open.
4. Reads at +2, +4 … +20 s agree; nothing more is sent.

The remote sets speed 5 while idle: the next read (≤ 15 s) → `settled(...,
"outside")` → `CURRENT_SPEED 5`, LEDs 303 off and 305 on, `Last Change By`
`Remote or wall control at 14:05`, the fast window opens.

The wall switch cuts the power: a read times out (5 s), the next one 10 s
later too, and the third 20 s after that, about 45 s in all → offline:
`Online` "0", **Fan Offline**, the light's `ONLINE_CHANGED` false, S7; reads
every 60 s. Power back: a read answers → contact → differences reported with
why "online", **Fan Online**, `ONLINE_CHANGED` true; nothing re-sent.

A light slider from 40 to 70: `SET_BRIGHTNESS_TARGET {70, RATE 0}` →
`CHANGING {40 → 70, RATE 0}` → `{"lightBrightness":70}` → answer on at 70 →
`idle("light")` → `CHANGED {70}`.

A top tap with the light off, its kept level 100, Default On Brightness 50:
`CHANGING {0 → 50}`, LEDs on at once → `{"lightBrightness":50}` → answer
(off, 50) → `{"lightOn":true}` → answer (on, 50) → `CHANGED {50}`.

## 10. Tests: fixtures and the fake runtime

### 10.1 Fixtures (`tests/fixtures/`, loaded as `require("fixtures.mf_gen3")`)

`tests/fixtures/mf_gen3.lua` returns JSON strings built from the M0
answers, which the coordinator hands the transport agent with every private
value already replaced; keys in the order the fan sent them, value types as
it sent them:

- `STATE_KEYS` (M0): `clientId`, `cloudPort`, `lightOn`, `fanOn`,
  `lightBrightness`, `fanSpeed`, `fanDirection`, `wind`, `windSpeed`,
  `rfPairModeActive`, `resetRfPairList`, `factoryReset`, `awayModeEnabled`,
  `fanTimer`, `lightTimer`, `decommission`, `schedule`, `adaptiveLearning`,
  `userData`, `timezone`, `FrCodes`, `cdebug`, `feedbackToneMute`;
  `state(overrides)` returns M0's state (fan on at 1, forward, light off at
  100, Breeze off, `cloudPort` 8883) with values replaced.
- `INFO` (M0's key order): `clientId` `MF_00005E005301`, `mac`
  `00:00:5e:00:53:01`, `lightType` `F4IN-120V-R1-30`, `fanType` `1811-5-54`,
  `fanMotorType` `DC125X20`, `brand` 1, `dateCode` `2021-12-02`, `owner`
  `owner@example.com`, `federatedIdentity`
  `us-east-1:00000000-0000-0000-0000-000000000000`, `deviceName` `Example
  Fan`, `firmwareVersion` `02.00.0052`, `esp-idf-version` `4.0.4`,
  `mainMcuFirmwareVersion` `03.00.0000`, `firmwareUrl` "", `wifiSignal`
  `-68`, `SSID` `example-ssid`, `BSSID` `00:00:5e:00:53:ff`, `isUvcFan`
  false, `built` `realHardware`, `dimTableId` 416020, `elecFreq` 60.
- `INFO_OTHER`: the same for `MF_00005E005302` / `00:00:5e:00:53:02`;
  `INFO_NO_KIT`: `lightType` "".
- Synthesized from the public code (marked so in the file): `GEN12_STATE`
  (M0's state without `wind`, `windSpeed`, `userData`, `fanTimer`,
  `lightTimer`, with `fanSleepTimer` and `lightSleepTimer` 0; MFR §2.2),
  `G4_DEVICE` (`systemType` `fan_g4`, `iotmVer` `01.00.0082`, `staMac`
  `00:00:5e:00:53:01`, `deviceName` `Example Fan`; MFR §4), `HTML` (a short
  page), `EMPTY` "", `NO_CLIENT` `{"fanOn":true}`.

No real address, MAC, client id, e-mail, identity, name or SSID, ever; the
`secrets` check (gitleaks) refuses them.

### 10.2 Specs

| Spec | Pins |
| --- | --- |
| `wire_spec` | every body of §3.1 byte for byte; refusals; `state`/`info` against the fixtures, private keys absent from the results; generation; IPv4 parsing |
| `transport_spec` | one in flight; the gap; options and headers on the transfer; every row of §3.3 (the fake's `t:respond(...)` and `t:done(err, msg)`); stale epochs dropped; `stop()` |
| `model_spec` | §3.4–§3.6, §4, §6 row by row, ECM/ECC case ids in the test names (N3, P1, P8, S7, S9, R1–R9, D9 …) |
| `texts_spec` | every text of §7 verbatim, lengths under 72 |
| `fanproxy_spec`, `links_spec` | §4.6, §5.1, the LED rule, the 10 s click rule, the Keypad Links rows |
| `light_spec` | §4.7: CHANGING/CHANGED pairing, default-on, the two-step on, holds and ramps, ALS stops, no light kit |
| `dispatch_spec`, `device_spec` | §9.2, the old behaviour unchanged |
| `devcmds_spec` | the Dev State line, the injection commands, the redactor |
| `v1_roundtrip_spec` (coordinator) | the whole driver on the fake: a press to a request to an answer to the notifications and LEDs; offline and back; a foreign fan |

### 10.3 Fake runtime additions (`tests/helpers/fake_c4.lua`, additions only)

1. Several proxies per driver: every `<proxy proxybindingid="N">` gets its
   own proxy device; `GetBoundConsumerDevices(device, N)` and
   `GetBoundProviderDevice(proxy, N)` answer each; `fake.proxy_id(env, N)`.
2. `SendToProxy` records its fourth argument (COMMAND/NOTIFY);
   `c4.proxy_messages(binding)` lists `{ command, params, kind }` in order.
3. `c4.advance(ms)`: moves `c4.now_ms` and fires the timers that fall due,
   in due order, including ones armed during the advance; repeating timers
   re-arm. `fire_timers()` stays as it is.
4. `t:fail(code, msg)` on a transfer (`OnDone` with that error and no
   response), `t.finished`, `c4.open_transfers()`.
5. `c4.json_decode_raises = true` makes `JsonDecode` raise on invalid JSON
   (the documented raise; the default stays nil and a message).
6. `fake.link_keypad(env, link, keypad_id, keypad_binding)` and
   `fake.unlink_keypad(...)`: a binding with the driver as provider and
   `OnBindingChanged` to the driver alone.
7. `C4:CreateNetworkConnection`, `C4:NetPortOptions`, `C4:NetConnect`,
   `C4:NetDisconnect`, `C4:SendToNetwork` recorded, and
   `fake.network_receive(env, binding, port, data, from)` calling
   `ReceivedFromNetwork` (for V5a; harmless otherwise).

## 11. Hardware checks before the first install

Each takes under a minute of anyone's time ("No long test waits"). The
standing approval covers all of it; every brief to the Windows session says
so and names what is hard to undo (installs, bindings, deletes). The
**probe** (M1) is a throwaway package with its own file and driver name
(never `modernforms_fan`, ECC D27), built outside `src/` so no release can
carry it: the two proxies and the capabilities of §2.3 plus
`proxy_fan_speed_connections` True, links 200 (with `proxybindingid="5002"`)
and 300 (without), the Lua command window (`C4:AllowExecute`, API
`22_miscellaneous/_2-AllowExecute.md`), a log line for every
`ReceivedFromProxy`, `ExecuteCommand`, `OnBindingChanged` and
`ReceivedFromNetwork`, and an action that runs K10. It is deleted after M1.

| # | Check | Who | Settles | Research | When |
| --- | --- | --- | --- | --- | --- |
| K1 | Read the stock package's `driver.xml` (names and ids only, nothing copied): proxies (type, name, binding, `primary`), capabilities (fan and light, their spelling), connections (ids, classes, `proxybindingid`), `minimum_os_version`, `jit` | Windows session, read-only | V1's `fan`/`FAN`; `speed_names`; the links' `proxybindingid` default; whether the stock driver used the proxy's speed links | FPR T1; LSR H3; ECC H1 | M0 (pending the go-ahead) |
| K2 | The stock device in Composer: tree items, which item has Properties, Actions, Documentation and Lua, the light's settings page, where its 13 links show | Windows session, read-only | V1's presentation | LSR H1, H2 | M0 (pending) |
| K3 | The stock device's properties and Documentation tab: how it polls, local or cloud | Windows session, read-only | the migration's overlap | MFR Q9; ECC §2.3 | M0 (pending) |
| K4 | The probe beside the stock device, in a test room: its items and tabs, the light's settings page, where links 200 and 300 show, that a press arrives on each | Windows session; one press by the owner unless K7 works | V1 (else §2.8); the links' `proxybindingid` | ECC H2; LSR H1, H2 | M1 |
| K5 | `proxy_fan_speed_connections` on the probe: which links appear, their names and ids; a press → `SET_SPEED` on 5001, `DO_*` elsewhere, or nothing; an LED following `CURRENT_SPEED` alone | Windows session; a press and a glance by the owner unless K7 works | nothing in v1; facts for a later version | FPR T2–T4; ECC H1 | M1 |
| K6 | A spare keypad button bound to the probe's 300: tap, hold, double tap and what arrives; `MATCH_LED_STATE` true and false; then, from the Lua window, `BUTTON_COLORS {ON_COLOR = "ff0000", OFF_COLOR = "000000", CURRENT_COLOR = "ff0000"}` and `MATCH_LED_STATE` true (red?), and while it is lit `BUTTON_COLORS` with `0000ff` and `MATCH_LED_STATE` true again (blue?); `MATCH_LED_STATE` false; an unbind and rebind (does `REQUEST_BUTTON_COLORS` arrive, and which colour does the button show afterwards?) | Windows session binds, sends and unbinds; the owner taps and glances (about 40 s) | V12, §5.1's click rule; V27 (colours taken over the link, and again while bound); §5.2's bottom link | FPR T5, T6; ECC H4, H7 | M1 |
| K7 | `KEYPAD_BUTTON_ACTION {BUTTON_ID, ACTION}` from the probe's Lua window drives a bound link like a press (KP `60_keypad_proxy_commands/_4-KEYPADBUTTONACTION.md`) | Windows session | whether K4–K6 and M4 need the owner's hands | ECC H5; FPR T3 | M1 (first) |
| K8 | Fan proxy notifications from the probe's Lua window: `CURRENT_SPEED` alone, then `ON`; `DESIGNATE_PRESET` from the app with and without the `PRESET_SPEED` answer; `GET_CURRENT_STATE` at the add | Windows session; three taps in the Control4 app by the owner | R9 (confirms never sending `ON`), the preset answer | FPR T7, T8; ECC H3 | M1 |
| K9 | A copy of the probe declaring minimum OS 9.0.0: refused or not; deleted | Windows session | how much V3's run-time check carries | LSR H7 | M1 |
| K10 | The probe's mDNS action: a PTR query for `_easylink._tcp.local` to 224.0.0.251:5353 through `MULTICAST`, then through `UDP` with `MIRROR_UDP_PORT` off; everything `ReceivedFromNetwork` gets in 3 s, logged | Windows session reads the Lua tab | V5a: Find Fans in v1 or not | M0 (mDNS) | M1 |
| K11 | Direction: with the fan running, `{"fanDirection":"reverse"}`, a read 3 times over 10 s, `{"fanDirection":"forward"}`, a read; the fan must keep answering | VM; the owner told first; his hands only if the fan drops off Wi-Fi (10 s off at the wall) | V18, `can_reverse` | MFR §8, §12; ECM check 7 | M1, before the first install |
| K12 | Light: off, `{"lightBrightness":30}`, a read (still off?), `{"lightOn":true}`, a read (on at 30?), off, a read (level 30 kept?) | VM | V14's two steps | LSR H4; ECM check 7 | M1 |
| K13 | Bursts: 10 speed commands and 20 level commands back to back, one in flight; latency, errors, the final state | VM; the owner told the fan will run through its speeds for about 20 s | `GAP_MS`, `RAMP_STEP_MS` (Lua constants) | LSR H6; MFR §12 | M1 or M4 |
| K14 | A Programmed LED command on a Follow Connection button: does it still act? | Windows session | the migration's order | ECC H6 | M1 |
| K15 | The light stepped 1 → 100 in 12 requests over 3 s, then down: a dim or a staircase? | VM; the owner's eyes, 30 s | whether a hold looks acceptable | LSR H5 | M1 (optional) |
| K16 | One remote press and one app change; `userData` and how soon each shows; Breeze on from the remote: does `fanSpeed` move? Reads every 0.5 s for 3 s after a command: does the state bounce? | the owner's hands; VM reads | §7.3's `Last Change By`, the Breeze note, `SETTLE_MS` | ECM checks 4–6, 8; MFR Q8 | M4 (not blocking) |
| K17 | Power cut of 10 s at the wall: time until it answers, the state it comes back in | the owner's hands | the manual's text (decision 10 is fixed) | ECM check 3 | M4 (not blocking) |
| K18 | Reboot Fan: do motor and light change; time until it answers | dev loop | the manual's text | ECM check 10 | M4 |

Before the first install of the real driver (M4) these must be settled,
because they are static: K1 (proxy name and class, `speed_names`), K4 (the
structure and the links' `proxybindingid`), K11 (`can_reverse`). The rest
changes Lua at most. At M4 the first dev install also shows that a new
device takes its capabilities with no reboot (LSR H8) and that a fan request
keeps its time while the Hue drivers hold their transfers (ECC H13). Parked:
links and bindings across a reboot (FPR T9), what the proxies hold after a
restart (ECC H12), a backup restore (§8).

## 12. Dev-loop actions and `tools/regress.sh`

`fan/devcmds.lua` gives the dev loop these signed commands (`tools/devctl.py
run "<name>" KEY=value`; only a signed `execute` reaches them,
[`dev-loop.md`](dev-loop.md#development-commands)):

| Command | Params | Does |
| --- | --- | --- |
| Dev Fan State | — | writes the DEV-ONLY row `Dev State` (below), which comes back in the `command_done` report |
| Dev Press | `LINK` (200–202, 300–308), `ACTION` `tap`, `push`, `click` or `release`, `COUNT` (default 1), `EVERY` (ms, default 300) | `ReceivedFromProxy(LINK, "DO_PUSH"/"DO_CLICK"/"DO_RELEASE")` as a keypad would (`tap` = push, then click 100 ms later), `COUNT` times, `EVERY` ms apart, timed on the controller |
| Dev Proxy | `BINDING` (5001, 5002), `COMMAND`, any other params | `ReceivedFromProxy(BINDING, COMMAND, params)` as the proxy would |
| Dev Request | `BODY` | one request through the model's queue, only a body `wire.body` accepts or one of the two queries; the answer logged normalized |

`Dev State`, one line of `key=value` separated by spaces, in this order:
`phase=online seq=231 fan=on/3 dir=forward light=on/40 shown.fan=on/3
shown.light=on/40 busy=- told.fan=3 told.dir=forward told.light=40
notify.fan=12 notify.dir=1 notify.light=8 changing=0
leds=300:0,301:0,302:0,303:1,304:0,305:0,306:0,307:1,308:1,200:1,201:0,202:1
ms=310` (`?` for unknown, `-` for none; `busy` lists groups by name;
`notify.*` count the notifications sent since late init).

`tools/regress.sh --fan` (opt-in, since it moves the fan; the generic checks
stay as they are and run first), each step waiting at most 5 s for `busy=-`,
the whole under a minute:

| Step | Action | Pass |
| --- | --- | --- |
| F1 | Dev Fan State | `phase=online`; the state is kept for F8 |
| F2 | Dev Proxy 5001 `SET_SPEED` 1 … 6 | `fan=on/N`, `told.fan=N`, `notify.fan` up by one per step |
| F3 | Dev Proxy 5001 `SET_SPEED` 0 | `fan=off`, `told.fan=0`, `leds` 300:1 and 301–308 at 0 |
| F4 | Dev Press 307 `tap` | `fan=on/<preset>`, `leds` 307:1, 308:1 and only that speed's link at 1 |
| F5 | Dev Press 308 `tap` `COUNT=3` `EVERY=150` | the preset plus 3, wrapping past 6; `notify.fan` up by one (the burst coalesced) |
| F6 | Dev Proxy 5002 `SET_BRIGHTNESS_TARGET` 30, 70, then 0 | `light=on/30`, `on/70`, `off`; `changing=0` after each; `told.light` follows |
| F7 | Dev Press 200 `tap` | `light=on/<Default On Brightness>` |
| F8 | Dev Proxy commands back to F1's state | F1's `fan=` and `light=` again |
| F9 | the shipped log, last 400 lines | no `[ERROR]`, traceback, refusal |

Release checklist section 1 maps onto F1–F9 and the log lines of §3.7.

## 13. M3 build split

Every agent runs at `effort: "max"`, starts cold from this file and the
sources it names, writes only the files of its row (others are editing the
rest of the checkout at the same time), runs no `git`, and is done when
`luacheck src tests tools` and `busted tests` pass for its files. Lua 5.1,
tabs, `.luacheckrc`, busted style as in `tests/spec/device_spec.lua`.

| Agent | Files (create or edit) |
| --- | --- |
| **wire** | `src/modernforms_fan/fan/wire.lua`, `src/modernforms_fan/fan/transport.lua`, `tests/fixtures/mf_gen3.lua`, `tests/spec/wire_spec.lua`, `tests/spec/transport_spec.lua` |
| **model** | `src/modernforms_fan/fan/model.lua`, `src/modernforms_fan/fan/texts.lua`, `tests/spec/model_spec.lua`, `tests/spec/texts_spec.lua` |
| **fan** | `src/modernforms_fan/fan/fanproxy.lua`, `src/modernforms_fan/fan/links.lua`, `tests/spec/fanproxy_spec.lua`, `tests/spec/links_spec.lua` |
| **light** | `src/modernforms_fan/fan/light.lua`, `tests/spec/light_spec.lua` |
| **common** | `src/common/dispatch.lua`, `src/common/device.lua`, `tests/spec/dispatch_spec.lua`, `tests/spec/device_spec.lua`, `tests/helpers/fake_c4.lua` (additions only), `tests/spec/fake_harness_spec.lua` (additions only) |
| **devtools** | `src/modernforms_fan/fan/devcmds.lua`, `tests/spec/devcmds_spec.lua`, `tools/regress.sh`, `docs/dev-loop.md` (its "Regression pass" and "Development commands" sections only) |
| **manual** | `src/modernforms_fan/www/documentation.html` (keeping its `<!-- CHANGELOG -->` line and the non-affiliation lines), `docs/composer-checklist.md` |
| **discovery**, only if K10 passed | `src/modernforms_fan/fan/discovery.lua`, `tests/fixtures/mdns.lua`, `tests/spec/discovery_spec.lua` |
| coordinator | `src/modernforms_fan/driver.lua`, `src/modernforms_fan/driver.xml`, `tools/build.sh` (`fan/devcmds.lua` in `DEV_ONLY_FILES`), `CLAUDE.md`, `.luacheckrc` (`TestCondition`, `ReceivedFromNetwork`), `tests/spec/fan_driver_spec.lua`, `tests/spec/drivers_spec.lua`, `tests/spec/v1_roundtrip_spec.lua`, `CHANGELOG.md`, `README.md`, `docs/README.md`, `docs/status.md`, `docs/design.md`, `docs/release-checklist.md`, `deploy/house.yaml` |

The migration's module, if `migration-design.md` asks for one, has its
owner named there. While agents work the dev loop stays pinned (`CLAUDE.md`,
Commands).

## 14. The manual (Documentation tab)

`src/modernforms_fan/www/documentation.html`, for owners and dealers, every
text as section 7 has it:

1. What it is: one driver for a Modern Forms Gen 1–3 fan and its light, over
   the fan's local interface, without the vendor's cloud; the trademark and
   non-affiliation lines.
2. Before you start: a DHCP reservation for the MAC shown in `Fan ID`; the
   fan and the controller on one network; set up in the Modern Forms app
   first; one Control4 device per fan, one controller per fan, no other
   driver polling it.
3. Adding the fan: add the driver to the room, type `Fan Address` (or Find
   Fans when present), what Status shows (S1–S13).
4. The fan from Control4: Navigators, ON and Toggle at the preset (Designate
   Preset), Cycle's rules, direction (or that it is the remote's), the
   proxy's events and variables, `Online`, Fan Offline and Fan Online, the
   conditional.
5. Keypad buttons: the twelve links, binding one in Connections (Follow
   Connection follows by itself and is not undone by a disconnect), LEDs
   lit at once and corrected, keypad colours for the fan links (or, with
   V27, a colour per speed), double taps as programming on the keypad's own
   events, and `Speed N Link Also Lit At` for a button whose double tap sets
   another speed (worked example: a button on Fan Speed 3 that double-taps to
   speed 1, set to `Speed 1`).
6. The light: Default On Brightness, no fades (a target is reached at once),
   holds stepping twice a second, Advanced Lighting Scenes, the settings page.
7. When the fan is offline: what Control4 shows, what happens when power
   returns (nothing is re-sent).
8. A new address, a replaced or reset fan: `Fan Address`, Use Selected Fan;
   never delete and re-add the device.
9. The fan's own automations: `Fan Automations`, `Last Change By`, the two
   Turn Off actions; schedules and timers are cleared in the app.
10. Properties and actions, row by row.
11. Moving from the stock WAC driver: a summary pointing to
    `migration-design.md` on GitHub.
12. Troubleshooting: a stuck Wi-Fi module (Reboot Fan, else 10 s off at the
    wall), `Poll Interval (s)`, the vendor app open on a phone.
13. Privacy: what the driver reads and drops.
14. The changelog (rendered by `tools/build.sh` at the marker).

## 15. Not in v1

- Gen 4 fans (`/device`, `/fixture`, two lights with colour temperature):
  refused (V4). Fans with fewer than six speeds: a package per speed count
  (`discrete_levels` is static).
- `proxy_fan_speed_connections`; Cycle Down and Direction links (309, 310
  reserved); a tap/double-tap/colour machine per link; more than one extra
  lit speed per link; fan LED colours from the driver, unless K6 and the
  owner bring V27 in.
- Find Fans, unless K10 passed; following a new address by itself, ever; a
  subnet scan, ever.
- Breeze on and off; UV-C; setting or clearing schedules and sleep timers;
  turning away mode or adaptive learning on; any destructive command (ECM §9).
- Fades and ramp rates on targets (the light has none); colour temperature.
- A "Changed Outside Control4" event (id 3 reserved); programming commands of
  the driver's own; History entries (ECC U11); detecting a second device on
  the same fan (ECC D17); several fans managed together.
- Restoring the light's keypad settings after a restore onto a new
  controller; `OnBindingValidate`.

## 16. What M0 and M1 may still change

| Item | Default in this file | Changed by |
| --- | --- | --- |
| Fan proxy XML name and class | `fan` / `FAN` | K1 (M0, stock `driver.xml`) |
| `speed_names` | `1,2,3,4,5,6` | K1: the stock driver's names, if it declares any |
| Capability spelling (`True`/`true`) | `True` | K1 |
| `proxybindingid` on the links | none | K4 (with K1 as a hint) |
| Structure | one driver, two proxies | K2, K4 → §2.8 |
| `can_reverse` | True | K11 |
| Find Fans, `Found Fans`, `discovery.lua` | out until K10 passes | K10 |
| `GAP_MS`, `RAMP_STEP_MS`, `SETTLE_MS` | 250, 500, 2500 ms | K13, K16 (Lua only) |
| `Fan Automations`' schedule test | a non-empty string | M0's value of `schedule` on the house fan |
| `Speed LED Colors` and the per-speed colour rows (V27) | not in the build | K6, then the owner ([section 17](#17-open-items-for-the-owner)) |
| device.lua's bottom light link | lit through inverted colours | K6: the inverted state instead, if keypads ignore `BUTTON_COLORS` |
| `Stock Device`'s items | `wac_mf_fan_and_light_controller(v4).c4z` | K1 (the exact file names Director reports) |
| Which speed links need `Also Lit At`, and with which speed | — | M0's keypad inventory ([`migration-design.md`](migration-design.md#1-what-the-migration-replaces), §1.4); set in the cutover, not in this file |
| The stock driver's links, programming and polling | — | K1–K3; [`migration-design.md`](migration-design.md#4-the-migration-report)'s, not this file's |

Folded in from M0 (VM): Gen 3 (V4), firmware 02.00.0052 and the ESP32
module (§7.3), every field of the house fan's two answers (§4.1, §10.1),
the light's level kept while off (V14), latency and timeouts (§3.2), the
response headers and keep-alive (§3.1), the private list (V20), mDNS (V5,
V5a, K10).

## 17. Open items for the owner

Each goes into an issue labelled `question` (the coordinator's); the
default holds until the owner answers, and none blocks the M3 build.

1. **A colour per speed on the keypad (V27).** With V26 alone, a button
   whose double tap sets speed 1 is lit at speed 1 too, but in the colour
   it shows at its single-tap speed: a button on Follow Connection has one
   on colour, the keypad's own. Today the Low button shows blue at speed 1
   and the High button orange at 6. A colour per speed needs the driver to
   send `BUTTON_COLORS` over the link: the link protocol documents the
   message, but no keypad has been seen to apply it (K6), and #6 decision 9
   with FPR §7 item 8 keeps it out of v1 unless K6 shows that it works and
   the owner wants it. Default: the keypad's own colours. If K6 shows that
   keypads take the colours: yes or no to the `Speed LED Colors` rows (no
   capability, connection or reboot either way). If K6 shows they do not, no
   documented way is left for the driver; what remains is one colour per
   button, or keypad programming on the fan's `speed_changed` event with
   the keypad's "Set LED On" command, if K14 shows that it still acts on a
   Follow Connection button: LED programming of the kind the project set
   out to remove.
2. **The Fan Cycle link wraps** from 6 to 1 (V11), while the proxy's
   `CYCLE_SPEED_UP` stops at 6 as ECC Q4 recommended: a single Cycle button
   that stopped at 6 would need a second button to go down. Default: wrap.
   Lua only, so cheap to change at any time.
3. **Custom icons (V24).** The house's device keeps the icons of the build
   that creates it. Default: Control4's own fan and light icons; a yes
   before the first install adds the driver's own.
