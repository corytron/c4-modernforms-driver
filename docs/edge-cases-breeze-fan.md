# Breeze as a fan device: lifecycle edge cases

> **Research (2026-11-07) for [issue #121](https://github.com/corytron/c4-modernforms-driver/issues/121)**,
> read-only: nothing here was tried on the house. Release 1.2 (build 115)
> gave the fan's Breeze a companion device, `modernforms_breeze.c4z`, with
> an on/off `light_v2` proxy ([`breeze-design.md`](breeze-design.md),
> [`edge-cases-breeze.md`](edge-cases-breeze.md), BC1 to BC36). The owner
> then saw it on his phone as a light bulb, at the other end of the room's
> list from the fan, and asked for a **3-speed fan device right under the
> fan**: tap Breeze 1, 2 or 3, and when that device is off, Breeze is off.
> The plan: the companion's proxy becomes a `fan` proxy (3 discrete speeds
> "Breeze 1,Breeze 2,Breeze 3", `can_reverse` False); speed N means Breeze
> at strength N (the fan's `windSpeed`), starting the fan at its preset
> first when it is off; Off ends Breeze and the fan keeps turning; the tile
> shows the strength while Breeze blows, 0 otherwise; the fan sends
> `STRENGTH` in `MF_BREEZE_STATE` and accepts it in `MF_BREEZE_SET`. The
> house's light_v2 companion is deleted, the release installed, Add Breeze
> Switch clicked again, Navigators refreshed. This note lists the corner
> cases (BF1 to BF66), decides each, and says where it would do something
> other than that plan.

**The short answer.**

1. **Snap One forbids exactly this update.** Director creates a device's
   proxies, and the internal bindings to them, only when the device is
   added; an update that adds, removes or changes the type of a proxy leaves
   the installed device without the proxy its driver now declares, which the
   SDK calls project corruption, and it says such a change needs a new
   driver (FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`).
   The connection 5001 would also change class (`LIGHT_V2` to `FAN`), and
   connections may only be added. Keeping the file name
   `modernforms_breeze.c4z` makes every install that meets an existing
   switch produce that state: on the house if the order slips, on any
   public user's project, after restoring an older project backup, and on a
   rollback. It also changes every capability, so Composer asks "Restart
   Director?" and the controller needs a reboot from System Manager.
   **Recommended: a new file name** for the fan-proxy package (BF1 to BF7).
   The owner's Hue project made the same call for the same reason (Hue
   `docs/scenes-design.md`, `docs/motion-control4-research.md` 5.1). If the
   name stays, the delete must come first, and the stale-device check of
   BF8 to BF11 is the safety net.
2. **A fan tile cannot show offline.** The fan proxy has no online
   notification (FAN `42_fan_protocol_notifications/`, ECC F8), so the
   Breeze device cannot grey out as the light_v2 switch did; BF26 sets what
   it shows instead.
3. **The proxy type alone does not put it under the fan.** No SDK call
   orders a Navigator list, and on this house a re-created device's items
   took the first places in the room's list
   ([`status.md`](status.md)). The install brief has to place it (BF22).
4. **Protocol gaps:** the fan re-sends the state only when BLOWS,
   AVAILABLE or HAS_BREEZE change, so a strength change would never reach
   the tile (BF43); Toggle should always be decided by the fan (BF28); a
   refused tap needs a reply that puts the tile back (BF35).
5. **Programming belongs on the fan item** (its Breeze commands, events,
   variable and condition), because everything written against the Breeze
   device is lost whenever that device is deleted and added again, as now
   (BF55, BF58).

**Decisions:** **Automatic** (the driver does it by itself), **Offered**
(a click, a Status or Last Action line telling the dealer or owner what to
do, or a step in the Windows session's brief), **Forbidden** (not without a
click, or not at all where the row says so). **Sources:** a path names the
SDK page the claim rests on (paraphrased, never quoted); "house" names a
measurement recorded in this repository or the Hue project; **assumed**
says the claim has no primary source. Placeholders only: fan `10.0.2.151`,
room "Example Room", fan item "Aviator 5", Breeze device "Aviator 5 Breeze".

| Key | Source |
| --- | --- |
| FAN | `~/c4-tools/reference/docs-driverworks-proxyprotocol-fan/source/includes/` (pages through OS 3.4.2 all say the fan proxy did not change; there is no 3.4.3 page and no OS 4 page) |
| LV2 | `~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/` |
| API, FUND, XML | `~/c4-tools/reference/docs-driverworks-api/`, `-fundamentals/`, `-xml/`, each `source/includes/` |
| K1 to K19 | the hardware checks of [`v1-design.md`](v1-design.md) section 11 (K5, K8: what the fan proxy does on this house) |
| ECB, ECC | [`edge-cases-breeze.md`](edge-cases-breeze.md) (BE, BC rows), [`edge-cases-control4.md`](edge-cases-control4.md) (F facts, R1 to R9 report rules, U rows) |
| BZ, BRR | [`breeze-design.md`](breeze-design.md) decisions BZ1 to BZ12; [`breeze-research.md`](breeze-research.md) (M0: the house fan keeps `windSpeed` while Breeze is off) |
| CR | [`composer-remote.md`](composer-remote.md) rule 20 (a deleted device loses its connections and every programming line naming it); Hue `docs/composer-remote.md` rule 10 (a capability change needs a controller reboot) |
| code | `src/modernforms_breeze/driver.xml` and `driver.lua`, `src/modernforms_fan/fan/breeze.lua` and `fanproxy.lua`, `src/modernforms_fan/driver.xml`, as of build 115 |

## 1. The proxy change, the update and the file name

| ID | Case | What happens | Decision | Source |
| --- | --- | --- | --- | --- |
| BF1 | An installed light_v2 companion is updated in place to a package of the same file name whose `<proxy>` is `fan` | The device keeps the light_v2 proxy device and internal binding it was created with; the driver now declares a fan proxy it does not have: "project corruption" in the SDK's words. Connection 5001's class changes from `LIGHT_V2` to `FAN`, a change the SDK forbids. What the corruption looks like is not documented: probably it stays a light bulb on the Navigators, light_v2 commands keep arriving on 5001 and the driver's fan notifications go to a light proxy | **Forbidden**: never let an update reach a light_v2 companion. Recommended: a new file name, so it cannot. If the name stays: delete first (BF12), detect (BF8) | FUND `14_…/_2-DRIVERUPDATECONSIDERATIONS.md` (proxies made only at the add; proxy type change, connections add-only); XML `15_common_xml/_31-proxies.md`, `_32-proxy.md`, `50_connections_xml/_30-type.md`; what the device then does: assumed |
| BF2 | The same update changes every capability (light_v2 block to fan block) | Composer asks "Restart Director?"; Yes does not restart it; the device keeps its old capabilities and code until the owner reboots the controller from System Manager | **Forbidden** by BF1's rule; if it happens anyway, **Offered**: the owner's reboot, then BF10 | house: CR (Hue rule 10); ECB BE2 |
| BF3 | After a wrong-order install (BF1, BF2) and before the reboot, Add Breeze Switch is clicked | Director's copy of the driver is stale until the reboot (Hue rule 10: even an overwrite does not help), so the new device may be created from the old light_v2 definition | **Forbidden** to rely on: the brief checks the new item is a fan (its proxy page shows Preset Level; Programming lists "Set speed Breeze 1") before Refresh Navigators. A new file name removes the case | assumed, from house: CR (Hue rule 10) |
| BF4 | Same file name, correct order: the old switch deleted, then the release installed | No device uses the package, so no "Restart Director?" is expected and the next Add uses the new file | **Automatic** in the brief, with BF3's check | assumed (whether Director keeps an unused driver's old definition is not documented) |
| BF5 | A project backup from before the change is restored (the owner keeps one on the Windows VM) | Same file name: the restored light_v2 device meets the new code, which is BF1's state. New file name: the switch comes back on its own package, still working | **Offered**: BF10's Status, then delete and add again | FUND `14_…/_2`; that a restore brings the old device back with its file name: assumed |
| BF6 | A rollback to 1.2 after the change | Same file name: the fan-proxy device gets light_v2 code, the reverse corruption and another reboot. New file name: 1.2 does not carry the new package, the Breeze device keeps its code, the 1.2 fan ignores `STRENGTH` (BF52) | **Forbidden** with the same name unless the Breeze device is deleted first; the release notes say so | FUND `14_…/_2` |
| BF7 | Other projects (the repository is public): a dealer with a 1.2 switch installs the next release the usual way, which updates every device of each package in place | BF1 on his project, guarded only by the release notes | **Forbidden** by design: a new file name. Otherwise the release notes say "delete the Breeze switch before installing", and BF8 catches the rest | house: `CLAUDE.md` Deploy (install updates every existing device in place); FUND `14_…/_2` |

## 2. Detecting a stale light_v2 companion (only if the file name stays)

| ID | Case | What happens | Decision | Source |
| --- | --- | --- | --- | --- |
| BF8 | Which documented call tells the companion its own proxy is a light_v2 | `C4:GetProxyDevices()` gives this driver's proxy id; `C4:GetProxyDevicesById(own id)` gives the proxy ids as several return values, but **not their type**; `C4:GetDevicesByC4iName("light_v2.c4i")` gives the ids of every light_v2 proxy in the project (membership test; the page's example prints keys and values, so check both); `C4:GetDevices({DeviceIds = own id})` returns the device with a `proxies` sub-table naming each proxy's file (`light_v2.c4i`), the one call that names the type. All exist since 1.6.0 or 2.10.0 (fine for 3.3.0); none may run in `OnDriverInit` (the safe-usage table marks the first three "no"; `GetDevices` is not listed, so treat it alike). `C4:GetCapability` and `C4:GetDriverConfigInfo` read the driver file, which says `fan` even on a stale device: useless here. `GetBoundConsumerDevices` is about bindings, not the own proxy. OS 4.0 adds `GetProtocolDeviceById` and `GetCapabilityById`, not on the house's 3.4.3. The pages disagree on spellings (`C4iNames` and `c4iNames`; `light_v2.c4i` and `.c4z` in the prose) | **Automatic** at `OnDriverLateInit`: `GetDevices` first, `GetDevicesByC4iName` as the cross-check; a failed or empty answer counts as "not stale" and is logged, so a lookup quirk never disables a healthy device | API `25_proxy/_1-GetProxyDevices.md`, `_2-GetProxyDevicesById.md`, `_4-GetDevicesByC4iName.md`; `22_miscellaneous/_9-GetDevices.md`, `_25.2-SafeUsageTable.md`, `_7-GetCapability.md`, `_13-GetDriverConfigInfo.md`; `9_helper/_5.6-GETCAPABILITYBYID.md`, `_8.5-GETPROTOCOLDEVICEBYID.md`; `32_serial_network_device/_3-GetBoundConsumerDevices.md` |
| BF9 | A second, passive signal | A light_v2-only command on 5001 (`SET_BRIGHTNESS_TARGET`, `SET_LEVEL`, `RAMP_TO_LEVEL`, `SYNCHRONIZE`, `BUTTON_ACTION`, `SET_PRESET_LEVEL`, `SET_HOLD_RATE_UP`/`_DOWN`, `SET_BUTTON_COLOR`; K8 saw the light proxy send several at the add) proves a light_v2 proxy; a fan-only one (`SET_SPEED`, `CYCLE_SPEED_UP`/`_DOWN`, `DESIGNATE_PRESET`, `GET_CURRENT_STATE`) proves a fan. `ON`, `OFF`, `TOGGLE` belong to both and prove nothing | **Automatic**: either signal sets the stale state | LV2 `10_light_v2_commands/`; FAN `41_fan_proxy_commands/`; house: K8 |
| BF10 | What a stale companion does | Status `Old Breeze switch: delete it, then Add Breeze Switch on Aviator 5` (65 characters, the name cut to fit); `ONLINE_CHANGED` false to the light_v2 proxy it really has, which greys the tile on the phone; every tap refused locally and logged (nothing sent to the fan); no fan notifications; a hello that says it is stale (BF11) | **Offered** (the Status line). **Forbidden**: repairing itself, unbinding, adding a device (`AddDevice` is for user-initiated use only; no API deletes a device) | LV2 `35_…/_15-ONLINECHANGED.md`; API `9_helper/_0.1-AddDevice.md` |
| BF11 | The fan with a stale (or any old) companion bound on 400 | Add Breeze Switch refuses with L37 naming it, as today | **Offered**: when the bound device said it is stale or old, a sharper L37: `Delete the old Breeze switch first: Aviator 5 Breeze` | code (`breeze.lua` `add_switch`) |

## 3. The update on the house, and what a delete loses

| ID | Case | What happens | Decision | Source |
| --- | --- | --- | --- | --- |
| BF12 | The order | (1) read the old switch's programming and agents; (2) delete it; (3) install the release; (4) Add Breeze Switch; (5) check the new item is a fan (BF3); (6) File ▸ Refresh Navigators; (7) place it after the fan in the room's Navigator order (BF22). Same file name: (2) before (3) is mandatory. Installing first and then reading the old switch for BF10's Status does not work: until a controller reboot it keeps its old code (BF2), so no such Status appears, and an Add before the reboot may build another light_v2 (BF3). New file name: the order is free, but BF16 still wants the old one gone before (4) | **Offered**: all seven steps in the Windows session's brief, the delete under the owner's standing approval, said so in the brief | house: CR rule 20; FUND `14_…/_2` |
| BF13 | What deleting the old switch loses | Its binding to the fan's 400 (the fan hears it and forgets it, BC29); every programming line naming it (its events, commands to it, conditions on it); its place in the room's Navigator order and any favourite; voice assistants' discovery and routines naming it; lighting scenes or agents that include it. It has no keypad bindings (it declares no Button Links). Nothing on the fan item changes | **Offered**: step (1) lists what names it; lines worth keeping are rebuilt on the fan item's Breeze commands and events, not on the new device (BF55) | house: CR rule 20; code (`modernforms_breeze/driver.xml`: connections 5001 and 1 only); favourites, voice and agents: assumed (ECC U7) |
| BF14 | Composer's delete confirmation | The Windows session opens the prompt (`Request-ComposerDeviceDelete` never confirms) and confirms it; the prompt's text is read back | **Offered** (standing approval in the brief) | house: [`composer-remote.md`](composer-remote.md) helper table; the prompt's wording: assumed |
| BF15 | Add clicked while the old switch is still bound (not deleted yet, or the delete not yet seen) | L37 naming it; nothing added | **Automatic** refusal | code (`breeze.lua` `add_switch`) |
| BF16 | New file name: Add while an old switch is still bound | Two "Aviator 5 Breeze" items would sit in the room, confusing programming, Navigators and voice | **Automatic** refusal with BF11's text: one Breeze device per fan; the old one is deleted first | assumed (Composer allowing duplicate names) |
| BF17 | A second click after success; a click while Composer has not answered the first | The second: L37 naming the new device. The busy click today only logs, so the dealer sees nothing | **Automatic**; add a Last Action line for the busy click | code (`breeze.lua`: `"busy"` writes no result) |
| BF18 | The package is not installed when Add is clicked | The `AddDevice` callback gets 0; L40 | **Offered**: L40 names the package to install (the new file name, if renamed) | API `9_helper/_0.1-AddDevice.md` (0 on failure) |
| BF19 | The name | `<fan item> Breeze`, cut to 30 characters, given once, never renamed by either driver (BZ11): "Aviator 5 Breeze", as the deleted switch was | **Automatic** once | BZ11; FUND `8_proxies_and_proxy_types/_2-MODIFYINGTHEDEFAULTNAMINGOFPROXIES.md` (the proxy's `name` is the default when none is given) |
| BF20 | The room | The fan item's room at the click; a fan item moved later does not move the Breeze device | **Automatic** once; **Forbidden**: moving it later | API `9_helper/_0.1-AddDevice.md` (room id parameter); BC32 |

## 4. The fan proxy on the Navigators

| ID | Case | What happens | Decision | Source |
| --- | --- | --- | --- | --- |
| BF21 | Where it is listed | As a fan, beside the room's fans, with the fan proxy's own picture (the tile picture follows the proxy type, not the driver) | **Automatic** by construction | owner's report 2026-11-07 (the app groups by device type); picture: assumed (ECB BE3, Hue `docs/icons-research.md`) |
| BF22 | Right under the fan | Not guaranteed: no SDK call orders a Navigator list; whether the app sorts by name or by Composer's room order is not documented, and the re-created fan device's items took the first places in the room's list on this house | **Offered**: the brief reads the room's Navigator order in Composer and moves "Aviator 5 Breeze" directly after "Aviator 5"; the owner glances at the phone | ECB BE3 (no Navigator API); house: [`status.md`](status.md) (first places); sort rule: assumed |
| BF23 | Speeds, names, direction | `discrete_levels` 3, `speed_names` `Breeze 1,Breeze 2,Breeze 3` (the house's fan shows names of the same form, "Level 1"), `can_reverse` False (no direction controls). All static: a later change costs a controller reboot | **Automatic**, fixed in the first build | FAN `43_fan_capabilities/_1-canreverse.md`, `_3-discretelevels.md`, `_5-speednames.md`; `41_…/_8-SETDIRECTION.md`, `_12-GETSETUP.md`; house: K1, ECB BE2 |
| BF24 | `proxy_fan_speed_connections` | From OS 3.4.2 the proxy would add its own links (Off, Breeze 1 to 3, Toggle Preset, Cycle Up and Down) and light keypad LEDs itself (seen on the house, K5); above the 3.3.0 minimum, and static | **Forbidden** now (not declared); a later release may add it at the cost of a reboot | FAN `43_…/_4.5-proxyfanspeedconnections.md`; house: K5 |
| BF25 | The tile while the fan answers | `CURRENT_SPEED` = strength while Breeze blows, 0 otherwise; nothing before the first state (R6); only on a change (R1); never `ON` or `OFF` notifications (`ON` jumps the proxy to its preset, K8) | **Automatic** | FAN `42_…/_1-CURRENTSPEED.md`, `_4-ON.md`; house: K8; ECC R1, R6, R9 |
| BF26 | No offline state | Unbound, fan offline and no Breeze cannot grey the tile. Fan offline: keep the last value (never 0 for offline, as R7). No Breeze: 0. Unbound: 0 (it controls nothing). Status says which | **Automatic** | FAN `42_fan_protocol_notifications/` (no online notification); ECC F8, R7 |
| BF27 | `ON` (tile, voice, programming) and `TOGGLE` from off | Plan: Breeze at the companion's preset. The proxy page also allows "back to the most recent speed", and the house fan keeps `windSpeed` while Breeze is off, so the fan's own strength (what the remote resumes) is available. `ON` while Breeze blows changes nothing | **Automatic**; recommended: the fan's remembered strength, `can_set_preset` False (one strength, not two that drift); the preset only when the strength is unknown | FAN `41_…/_1-ON.md`, `_3-TOGGLE.md`; BRR M0; V11 |
| BF28 | `TOGGLE` | Today the companion sends SET from the *confirmed* state, so two quick taps both say "on"; the fan's own toggle (link 311) works from the *shown* state | **Automatic**: always send `MF_BREEZE_TOGGLE`, and the fan decides from the shown state, as BC11 and BC12 | code (`modernforms_breeze/driver.lua` `toggle`; `breeze.lua` `toggle`); V8 |
| BF29 | `SET_SPEED` | 1 to 3: Breeze at that strength (the fan first if off); 0: Breeze off; anything else refused, logged, the tile re-sent. Parameters arrive as strings | **Automatic** | FAN `41_…/_5-SETSPEED.md`; house: K5, K8 |
| BF30 | `CYCLE_SPEED_UP`/`_DOWN` | As the fan's tile: from 0 up goes to Breeze 1 (starting the fan if off), down does nothing; at 3 and 1 it stays (never wraps, never off by cycling); counted from the fan's shown strength, so a burst counts from its target | **Automatic**; the step travels to the fan (for example `MF_BREEZE_SET {STEP}`), which owns the shown state | FAN `41_…/_6-CYCLESPEEDUP.md`, `_7-CYCLESPEEDDOWN.md` (wrap is the driver's choice); V11; ECC R5 |
| BF31 | `DESIGNATE_PRESET` | With `can_set_preset` True: 1 to 3 stored and answered with `PRESET_SPEED`, anything else answered with the kept value; `PRESET_SPEED` at late init (the proxy's variable started at 1 while its page said 3, K8). An unasked `DESIGNATE_PRESET {PRESET="3"}` reached a fan proxy on this house (K8) and would reset it. With BF27's recommendation: ignored and logged | **Automatic** | FAN `41_…/_4-DESIGNATEPRESET.md`, `42_…/_3-PRESETSPEED.md`, `43_…/_2-cansetpreset.md`, `_4-presetspeed.md`; house: K8 |
| BF32 | The item in Composer | The fan proxy's Preset Level page shows on it (`hide_proxy_properties` is a light_v2 capability) | **Automatic**; the manual says what it means | house: K2, K4; LV2 `5_light_v2_capabilities/` |
| BF33 | Groups and voice | As a fan it leaves the lights: "all lights off", lighting scenes and light counts no longer touch Breeze (ECB BC33 goes away). A voice assistant sees a fan "Aviator 5 Breeze"; "turn on all fans" would start Breeze, and the fan | **Automatic**; the manual warns | assumed (ECC U7) |
| BF34 | Rapid taps Breeze 1, 2, 3 | Each tap a message; the fan coalesces, latest wins, one request in flight; the tile shows confirmed values and may jump 1 to 3 | **Automatic** | BC12; ECC R5 |
| BF35 | A refused or failed tap (offline, no Breeze, foreign) | The fan writes Last Action (L33, L35). Whether a Navigator keeps showing the tapped speed until told otherwise is not documented | **Automatic**: the fan answers every companion request with a state message once it settles or is refused, and the companion re-sends `CURRENT_SPEED` with the current value | assumed; FAN `45_fan_events/_1-FANEVENTS.md` (speed_changed fires on a change, so a repeat should fire nothing: assumed) |
| BF36 | The new device does not show | Navigators cache the project | **Offered**: File ▸ Refresh Navigators in the brief; reopening the app if needed (assumed) | BC34; ECC U7 |

## 5. State cases

| ID | Case | What happens | Decision | Source |
| --- | --- | --- | --- | --- |
| BF37 | Breeze blows at strength 2 (`wind` and `fanOn` true) | Tile "Breeze 2"; the fan's `Breeze` variable 1 | **Automatic** | BZ1 |
| BF38 | Fan off with `wind` still set | Tile 0 (BZ1); fan Status ` Breeze set`. The next start of the fan may resume Breeze (assumed BZ5 c): the tile moves to the strength and the device's turned_on fires though nobody touched it | **Automatic** report; **Offered**: the manual says Off on the Breeze device clears it (BF40) | BZ1, BZ5 |
| BF39 | Off on the Breeze device while the fan runs | `{"wind":false}` only; the fan keeps turning; its tile is told the base speed again | **Automatic** | BZ7, BZ8 |
| BF40 | Off on the Breeze device while its tile already shows 0 | Sent anyway, which clears a stored `wind`, so "Breeze device off" really means Breeze off, also for the next start | **Automatic** | V8; BC10 |
| BF41 | The main fan turned off (tile, keypad, remote, app) | Breeze device 0; its turned_off and speed_changed fire; the fan's Breeze Stopped fires | **Automatic** | BZ1; FAN `45_…/_1-FANEVENTS.md` |
| BF42 | Breeze N tapped with the fan off | The fan on at the fan proxy's preset (the house: Level 3), then `{"wind":true,"windSpeed":N}`: two requests, the fan first, 250 ms apart; the tile shows N after the second answer | **Automatic** | BZ6 |
| BF43 | Strength changed in the Modern Forms app or remote while blowing | The tile moves to the new strength; the device's speed_changed is the only strength event (the fan item has none, BC4). Today `refresh()` re-sends only when BLOWS, AVAILABLE or HAS_BREEZE change, so `STRENGTH` must join that comparison | **Automatic** | code (`breeze.lua` `refresh`, `broadcast`); BC4 |
| BF44 | Strength changed while not blowing | Tile stays 0; the strength is what the next `ON` resumes (BF27) | **Automatic** | BRR M0 |
| BF45 | Gusts move `fanSpeed` | The tile follows `windSpeed`, not the speed: no flicker | **Automatic** | BZ8 |
| BF46 | Blowing, but the answer carries no `windSpeed` | The last known strength, else the preset; logged once | **Automatic** | assumed (every answer seen carries it, BRR) |
| BF47 | The fan item's Set Breeze Strength while Breeze is off | `{"windSpeed":N}` alone; tile stays 0 unless the fan starts Breeze | **Automatic** | BC14 |
| BF48 | A fan without Breeze | HAS_BREEZE 0: tile 0, Status `Aviator 5 has no Breeze`, taps refused by the fan (L33), Add refused (L38) | **Automatic** | BZ10 |
| BF49 | Fan offline, foreign, Gen 4, unset; rebooting | AVAILABLE 0 except while rebooting; the tile keeps what the fan item reports (it keeps the last value offline); Status `Waiting for Aviator 5`; a tap is tried once or refused, then BF35 | **Automatic** | BC19, BC20 |
| BF50 | Director restart, controller reboot | Late init: the binding (0 means none on 3.4.2), hello, state, the 60 s re-check; `GET_CURRENT_STATE` answered once the state is known; `PRESET_SPEED` sent. The fan's variable is seeded from `mf_breeze`, so a restart fires nothing | **Automatic** | code; house: K8 (`GET_CURRENT_STATE` at the add); BC22 |
| BF51 | Added while the fan is silent (Add needs only the pin and the stored Breeze flag) | The hello is answered with AVAILABLE 0 and the persisted value; Status `Waiting for Aviator 5` | **Automatic** | code (`add_switch`); BC17 |
| BF52 | Version skew (one package updated, the other not; a rollback of the fan alone) | An old switch ignores `STRENGTH`; its `MF_BREEZE_SET {ON}` without `STRENGTH` keeps the strength. A 1.2 fan ignores `STRENGTH` and sends none. An empty-string parameter is not sent unless allowed, so `STRENGTH` goes only when known and its absence means unknown | **Automatic** on both sides | API `32_serial_network_device/_19-SendToDevice.md` (allowEmptyValues) |
| BF53 | Unbound, or the fan device deleted | Status `Not connected to a Modern Forms Fan`; tile 0; taps refused locally | **Offered**: bind it in Connections | BC30 |
| BF54 | Two Breeze devices on one fan (one bound by hand) | Both told, both work | **Automatic** | BC31 |

## 6. Programming

| ID | Case | What happens | Decision | Source |
| --- | --- | --- | --- | --- |
| BF55 | Two places to program Breeze | The Breeze device's proxy events (turned_on, turned_off, speed_changed, also on on and off), conditionals (Is On, Is Off, Current Speed equal or not) and variables, beside the fan item's Breeze Started, Breeze Stopped, `Breeze` and "Breeze is on". Both move from the same confirmed state; speed_changed also fires on a strength change | **Offered**: the manual sends programming to the fan item's surface, which survives a re-created Breeze device (BF13) | FAN `44_fan_conditionals/`, `45_…/_1-FANEVENTS.md`, `46_fan_variables/_1-FANVARIABLES.md`; BZ3 |
| BF56 | Programming writes the device's read/write variables (Is On, Current Selected Speed) | Whether the proxy turns a write into a command to the driver is not documented; the driver handles whatever command arrives | **Offered**: the manual says use the commands | FAN `46_…/_1-FANVARIABLES.md`; the effect: assumed |
| BF57 | A loop between the device's events and its commands | Runs at the fan's pace, one request in flight | **Automatic**; the manual warns, as BC24 | BC24; ECC P4 |
| BF58 | Programming that named the old light switch (Light On 5100, Light Off 5101, its on and off commands, Is On) | Deleted with it, never converted | **Offered**: BF12 step (1); rebuilt on the fan item | LV2 `25_light_v2_events/_0-HEADER.md`, `20_…/_0-HEADER.md`; house: CR rule 20 |
| BF59 | Composer's wording | "Set speed Breeze 2" on the device; Designate Preset only with `can_set_preset` True | **Automatic** | house: v1-design `speed_names` row ("Set speed Level 2"); the rest assumed |

## 7. Keypads and the fan item

| ID | Case | What happens | Decision | Source |
| --- | --- | --- | --- | --- |
| BF60 | Link 311, its LED, the four Breeze commands, events 4 and 5, `BOOL_BREEZE`, the `Breeze` variable | Unchanged in name, id and behaviour | **Forbidden** to change | BZ3, BZ4; FUND `14_…/_2` |
| BF61 | Binding 400 and its class | Kept (connections are never removed); `MF_BREEZE_SET` gains an optional `STRENGTH` (and `STEP`, BF30) | **Automatic** | FUND `14_…/_2` |
| BF62 | Keypad buttons for Breeze 1, 2, 3 | None of their own (BF24); a dealer can program a button with the device's Set speed or the fan's Set Breeze Strength | **Offered** | BF24 |

## 8. What would make a later fix harder

| ID | Case | What happens | Decision | Source |
| --- | --- | --- | --- | --- |
| BF63 | The capabilities of the first fan-proxy build | Static: changing names, count, preset or `can_set_preset` later costs a controller reboot | **Forbidden** to treat casually: settle them in the contract | ECB BE2; house: CR (Hue rule 10) |
| BF64 | The proxy type is a one-way door again | Any future change of proxy needs yet another file name; a name that says what the package is (for example `modernforms_breezefan.c4z`) leaves room | **Offered** to the contract | FUND `14_…/_2` |
| BF65 | Two packages in Composer's driver list | With a new file name the old one stays in the list; a distinct `<name>` (for example "Modern Forms Breeze Fan") keeps them apart; the old package either leaves the release (its devices keep build 115, which still works) or ships once more Lua-only with BF10's Status as "replaced" (no capability change, no reboot) | **Offered** to the contract | FUND `14_…/_2`; XML `15_common_xml/_20.1-name.md` |
| BF66 | Release tooling and words | The package list, `deploy/house.yaml`, the brief's device count and read-backs, the Documentation tabs, the release notes and `CHANGELOG.md` all change; the notes must say whether the Breeze switch has to be deleted before installing | **Offered** to the coordinator | `CLAUDE.md` (Deploy); [`changelog-design.md`](changelog-design.md) |

## 9. Recommendations for the contract

1. **Give the fan-proxy companion a new file name** and a distinct
   `<name>` (BF1 to BF7, BF64, BF65). It is what the SDK requires for a
   change of proxy type, the owner's Hue project did the same, and it makes
   the house's update order, other users' installs, backup restores and
   rollbacks harmless. Keep binding 400 and its class; Add refuses while
   any companion is bound, with a sharper line for an old one (BF11, BF16).
   If the name stays, the release notes and the brief must put the delete
   before the install, and the companion carries BF8 to BF10.
2. **Stale check, if needed:** `C4:GetDevices({DeviceIds = …})` at late
   init, `GetDevicesByC4iName("light_v2.c4i")` as cross-check, plus the
   passive command signal; never in `OnDriverInit`; a failed lookup is not
   "stale"; Status plus `ONLINE_CHANGED` false; nothing self-repairs.
3. **Protocol:** `STRENGTH` in every state message when known (also while
   Breeze is off), and in the fan's change test (BF43); `MF_BREEZE_SET`
   with optional `STRENGTH` (exact strength) and `STEP` (cycle);
   `MF_BREEZE_TOGGLE` always for Toggle (BF28); a state message after
   every companion request, settled or refused (BF35); absence of
   `STRENGTH` means unknown (BF52).
4. **ON** resumes the fan's own strength with `can_set_preset` False
   (BF27, BF31); if the preset is kept, persist it and answer every
   `DESIGNATE_PRESET` with `PRESET_SPEED`.
5. **Tile rules for a proxy that cannot go offline** (BF25, BF26): last
   value while the fan is offline, 0 without Breeze or unbound, Status says
   why; no `ON`/`OFF` notifications; no `proxy_fan_speed_connections`.
6. **The brief** (BF12): read what names the old switch, delete it,
   install, Add, check it is a fan, Refresh Navigators, move it right after
   the fan in the room's Navigator order, owner glances once (under a
   minute).
7. **The manual**: program Breeze on the fan item; Off on the Breeze device
   ends Breeze (also a stored one) while the fan keeps turning; a tap on a
   stopped fan starts it; "all fans on" starts Breeze.
