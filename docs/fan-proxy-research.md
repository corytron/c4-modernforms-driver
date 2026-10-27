# Fan proxy and keypad links: research (#2)

Research for the v1 contract (2026-10-27, read-only). The question: what the
driver needs so that a keypad button linked to the fan's "Fan Speed N" link
(and to Off, Toggle and Cycle links) works, and with the button's LED
Behavior on **Follow Connection** lights only while the fan runs at speed N.
The stock driver declares such links and implements none of them (tested on
the house 2026-10-27, [CLAUDE.md](../CLAUDE.md), "The goal").

**Status key.** **VERIFIED** = stated by a Snap One source (the SDK docs, or
Snap One's public template code) or seen on hardware (the Hue project on this
house, OS 3.4.2 and 3.4.3), with the path. **ASSUMED** = not stated by any of
them; the test in [section 8](#8-hardware-tests) that settles it is named
(T1 to T9). Snap One's docs and code are paraphrased, never quoted (their
license); command, capability and parameter names are given as they are.

| Key | Source (paths in the text are relative to it) |
|---|---|
| `FAN` | `~/c4-tools/reference/docs-driverworks-proxyprotocol-fan/source/includes/` (clone last updated 2025-02-06) |
| `PP` | `~/c4-tools/reference/docs-driverworks-proxyprotocol/source/includes/` (the combined proxy guide) |
| `KP` | `~/c4-tools/reference/docs-driverworks-proxyprotocol-keypad/source/includes/` |
| `LV2` | `~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/` |
| `UIB` | `~/c4-tools/reference/docs-driverworks-proxyprotocol-uibutton/source/includes/` |
| `XML`, `API`, `FUND` | `~/c4-tools/reference/docs-driverworks-xml/`, `-api/`, `-fundamentals/`, each `source/includes/` |
| `TPL` | Snap One's public template code, `snap-one/drivers-template-code-public` on GitHub, `proxies/fan_proxy/` (files dated 2023), read 2026-10-27 |
| `HUE` | the owner's Hue project, [corytron/c4-hue-driver](https://github.com/corytron/c4-hue-driver) (`~/projects/c4-hue-driver`), main as of 2026-10-27 |
| `C4HELP` | Control4's public Composer Pro dealer help, `docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/` |
| community | third-party fan drivers on GitHub, evidence only (never VERIFIED on their own): `finitelabs/control4-esphome` (`drivers/esphome_fan/`), `michelo76/control4-smartbuildos` (`drivers/bond-fan/`), `bphillips09/Control4-HA-Fan`, and `DirectorLink/DirectorLink` (`docs/RESEARCH.md`) |

## Summary

1. **Fan proxy:** proxy `fan` on binding 5001 with commands `ON`, `OFF`, `TOGGLE`, `SET_SPEED`, `CYCLE_SPEED_UP/DOWN`, `DESIGNATE_PRESET`, `SET_DIRECTION`, `TOGGLE_DIRECTION`, `GET_CURRENT_STATE`; notifications `CURRENT_SPEED`, `DIRECTION`, `PRESET_SPEED`, `ON`, `OFF`; capabilities `discrete_levels`, `speed_names`, `preset_speed`, `can_set_preset`, `can_reverse`. All VERIFIED and unchanged on every OS 3.x. The proxy's XML name `fan` and class `FAN` are not in the docs: ASSUMED from public drivers (T1).
2. **`proxy_fan_speed_connections`** (OS 3.4.2) is one short paragraph: True switches on BUTTON_LINK connections made dynamically for the fan speeds, relying on `discrete_levels` and `speed_names` (VERIFIED). That the proxy makes them, their names and ids, what a press does, who lights the LEDs and whether there is an Off link are not said (all ASSUMED). No public driver uses it, Snap One's fan template has no code for it, and the light_v2 guide's similar promise of proxy-made Top/Bottom/Toggle links proved false on this house.
3. **Off, Toggle, Cycle (and Direction)** are not part of that capability: the driver declares them (VERIFIED by omission; every public fan driver does so).
4. **Driver-declared links** are VERIFIED end to end on this house (Hue): BUTTON_LINK provider connections, `DO_PUSH`/`DO_RELEASE`/`DO_CLICK` arriving in `ReceivedFromProxy` on the link's id, `MATCH_LED_STATE {STATE}` sent back on that id; available since OS 3.0.
5. **Composer:** the keypad's Button Link row is dragged onto the fan's link; that sets Follow Connection by itself. Added connections reach installed devices at once; capability changes need the owner's controller reboot; connections may never be removed and proxies never added by an update.
6. **Minimum OS:** the fan side needs 3.0.0 with driver links and 3.4.2 only for the proxy's speed links; recommendation: do not let the fan raise the floor (the light side decides, 3.3.0 as in the Hue drivers).
7. **Design:** driver links for Off/Toggle/Cycle always; per-speed links from the proxy only if T2 to T4 show the proxy handles presses and LEDs itself, otherwise driver links 301 to 306 too. Decide before the first install on the house: capabilities are static.

## 1. The fan proxy

### 1.1 Declaration

| What | Value | Status |
|---|---|---|
| Proxy element | `<proxy proxybindingid="5001" name="Modern Forms Fan">fan</proxy>` | Element and attributes VERIFIED (`XML 15_common_xml/_32-proxy.md`). The name `fan`: ASSUMED (T1). No fan page prints the proxy's XML name or connection class; every public fan driver read declares `fan` with class `FAN` (community), and DirectorLink saw the proxy as `fan.c4i` on a live Director (community). |
| Proxy connection | id 5001, type 2, consumer False, class `FAN` | Proxy ids 5000 to 5999 and type 2 VERIFIED (`XML 50_connections_xml/_15-id.md`, `_30-type.md`); the class ASSUMED as above (T1) |
| The light beside it | light_v2 on 5002 in the same driver | A driver may carry several proxies, each on its own binding id, and that id comes with every command: VERIFIED (`FUND 8_proxies_and_proxy_types/_1-SINGLEANDMULTIPROXIES.md`, `FUND 11_connections/_5-PROXYBINDINGMULTIPLE.md`) |
| Fixed at first release | Adding, removing or retyping a proxy in a driver update corrupts installed devices; it takes a new driver | VERIFIED (`FUND 14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`). v1 must ship the fan and the light proxies together. |

Routing: `ON`, `OFF` and `TOGGLE` come from both proxies (`FAN 41_fan_proxy_commands/_1-ON.md`, `_2-OFF.md`, `_3-TOGGLE.md`; `LV2 10_light_v2_commands/_7-TOGGLE.md`, and ON/OFF seen on hardware, `HUE docs/design.md` "Lights: verified on hardware"). `ReceivedFromProxy(idBinding, strCommand, tParams)` carries the binding (`API 25_proxy/_5-ReceivedFromProxy.md`), so the dispatcher must route on binding and command. `HUE src/common/dispatch.lua` keys on the command alone and needs that change when copied (VERIFIED, code).

Not the UI Button proxy: it puts a shortcut on Navigator menus and has a `SELECT` command, no keypad links (`UIB 103_ui_button_proxy_overview/_1-UIBUTTONPROXYOVERVIEW.md`, `UIB 107_ui_button_proxy_commands/_1-SELECT.md`).

### 1.2 Capabilities

| Capability | For Modern Forms | Meaning | Status |
|---|---|---|---|
| `discrete_levels` | 6 | number of speeds; 0 = continuous; default 1 | VERIFIED `FAN 43_fan_capabilities/_3-discretelevels.md`; 6 ASSUMED (the stock driver's links name speeds 1 to 6; for the fan API research to confirm) |
| `speed_names` | e.g. `1,2,3,4,5,6` or the owner's names | the speed names the UIs show; defaults depend on the count, above five speeds "Level 1" to "Level N" | Defaults VERIFIED `FAN 43_fan_capabilities/_5-speednames.md`. Comma-separated format VERIFIED by the GET_SETUP example (`FAN 41_fan_proxy_commands/_12-GETSETUP.md`); the capability page's own example shows a bare number, a doc slip |
| `preset_speed` | owner's choice | where `ON` and `TOGGLE` go; default the highest speed | VERIFIED `FAN 43_fan_capabilities/_4-presetspeed.md` |
| `can_set_preset` | True | the UI and programming may designate the preset; default False | VERIFIED `FAN 43_fan_capabilities/_2-cansetpreset.md` (its example's closing tag is misspelt) |
| `can_reverse` | True if the fan API reverses | enables `SET_DIRECTION`, `TOGGLE_DIRECTION`, Is Reversed and `direction_changed`; default False | VERIFIED `FAN 43_fan_capabilities/_1-canreverse.md`, `41_fan_proxy_commands/_8-SETDIRECTION.md`, `44_fan_conditionals/_4-IsReversed.md`, `45_fan_events/_1-FANEVENTS.md` |
| `proxy_fan_speed_connections` | decided by T2 to T4 | [section 2](#2-proxy_fan_speed_connections) | VERIFIED to exist, OS 3.4.2 |

**Static.** The fan proxy documents no dynamic-capability notification (its five notifications are in `FAN 42_fan_protocol_notifications/`), and its capability pages have no "Dynamic Capability" field, unlike light_v2's (for example `LV2 5_light_v2_capabilities/_29-SUPPORTSBRIGHTNESSSTOP.md`). So the speed count is fixed per package: ASSUMED static. Consequences: CLAUDE.md's "fewer where a model has fewer" needs one package per speed count (one public fan driver ships a variant per speed count, community) unless every Modern Forms fan has six speeds; and changing any capability on an installed driver costs the owner's controller reboot (VERIFIED hardware, `HUE docs/composer-remote.md` rule 10). A driver reads its own values with `C4:GetCapability` (`API 22_miscellaneous/_7-GetCapability.md`), as Snap One's template does for these four (`TPL fan_device_class.lua`).

### 1.3 Commands, proxy to driver

All arrive in `ReceivedFromProxy` on 5001.

| Command | Parameters | The driver | Status |
|---|---|---|---|
| `ON` | none | on at the preset, or at the last speed (the driver's choice) | VERIFIED `FAN 41_fan_proxy_commands/_1-ON.md` |
| `OFF` | none | speed 0 | VERIFIED `FAN 41_fan_proxy_commands/_2-OFF.md` |
| `TOGGLE` | none | on: off; off: as `ON` | VERIFIED `FAN 41_fan_proxy_commands/_3-TOGGLE.md` |
| `SET_SPEED` | `SPEED` 0 to N, 0 = off | set the speed | VERIFIED `FAN 41_fan_proxy_commands/_5-SETSPEED.md`; name also in `TPL fan_device_class.lua` |
| `CYCLE_SPEED_UP`, `CYCLE_SPEED_DOWN` | none | one speed up or down; wrapping or stopping at the ends is the driver's choice | VERIFIED `FAN 41_fan_proxy_commands/_6-CYCLESPEEDUP.md`, `_7-CYCLESPEEDDOWN.md` |
| `DESIGNATE_PRESET` | `PRESET` 1 to N | store the preset, answer `PRESET_SPEED` | Parameter VERIFIED `FAN 41_fan_proxy_commands/_4-DESIGNATEPRESET.md`; that the proxy needs the answer ASSUMED (it did for light_v2's settings, `HUE src/common/device.lua` SETTINGS; T7) |
| `SET_DIRECTION` | `DIRECTION` = `FORWARD` or `REVERSE` | set the direction | Values VERIFIED `FAN 41_fan_proxy_commands/_8-SETDIRECTION.md` (which leaves the parameter unnamed); the name `DIRECTION` VERIFIED `TPL fan_device_class.lua` |
| `TOGGLE_DIRECTION` | none | flip it | VERIFIED `FAN 41_fan_proxy_commands/_9-TOGGLEDIRECTION.md` |
| `GET_CURRENT_STATE` | none | report everything: the proxy asks for its initial state | VERIFIED `FAN 41_fan_proxy_commands/_10-GETCURRENTSTATE.md` (the template has no handler; answering is cheap) |
| `GET_STATE`, `GET_SETUP` | none | nothing: the proxy itself answers UIs with XML built from the capabilities and the last reported state | VERIFIED `FAN 41_fan_proxy_commands/_11-GETSTATE.md`, `_12-GETSETUP.md` |

### 1.4 Notifications, driver to proxy

Sent with `C4:SendToProxy(5001, name, params, "NOTIFY")`; the default would be NOTIFY anyway for an id of 1000 or more (`API 25_proxy/_6-SendToProxy.md`).

| Notification | Parameters | When | Status |
|---|---|---|---|
| `CURRENT_SPEED` | `SPEED`, a whole number 0 to N | every change, 0 when off | VERIFIED `FAN 42_fan_protocol_notifications/_1-CURRENTSPEED.md` (typed INT), `TPL fan_proxy_notifies.lua` |
| `DIRECTION` | `DIRECTION` = `FORWARD` or `REVERSE` | on change | Values VERIFIED `FAN 42_fan_protocol_notifications/_2-DIRECTION.md`, the name `TPL fan_proxy_notifies.lua` |
| `PRESET_SPEED` | `SPEED` 1 to N | when the preset changes | VERIFIED `FAN 42_fan_protocol_notifications/_3-PRESETSPEED.md`, `TPL fan_device_class.lua` |
| `ON`, `OFF` | none | power transitions | VERIFIED as optional for a multi-speed fan, and `ON` makes the proxy assume the preset speed (`FAN 42_fan_protocol_notifications/_4-ON.md`, `_5-OFF.md`). The template sends them on every power change, before `CURRENT_SPEED` (`TPL fan_device_class.lua`). Whether to send them: ASSUMED (T8) |
| `ONLINE_CHANGED` | | | Not documented for the fan proxy (it is for keypad and light_v2: `KP 61_keypad_protocol_notifications/_10-ONLINECHANGED.md`, `LV2 35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/_15-ONLINECHANGED.md`); one community driver sends it anyway. ASSUMED unsupported: "fan offline" is a driver property and event |

### 1.5 What the proxy provides by itself

- Events `turned_on`, `turned_off`, `speed_changed` (also on on and off) and `direction_changed` (with `can_reverse`): VERIFIED `FAN 45_fan_events/_1-FANEVENTS.md`. The driver declares none of them.
- Variables Is On, Current Selected Speed, Is Reversed, Current Preset: VERIFIED `FAN 46_fan_variables/_1-FANVARIABLES.md` (read on a live Director as `IS_ON` 1000, `CURRENT_SPEED` 1001, `PRESET_SPEED` 1003, community).
- Conditionals Is On, Is Off, Current Speed equal or not, Is Reversed: VERIFIED `FAN 44_fan_conditionals/`.

**What the stock UIs need.** Touch screens and the app ask the proxy for `GET_SETUP` (speed count and names, `can_reverse`, `can_set_preset`, preset) and `GET_STATE` (current speed, reversed), and the proxy answers from the capabilities and the last notifications (VERIFIED `FAN 41_fan_proxy_commands/_11-GETSTATE.md`, `_12-GETSETUP.md`). So the UIs need correct capabilities, a `CURRENT_SPEED` on every change including 0, `DIRECTION` and `PRESET_SPEED` where declared, and an answer to `GET_CURRENT_STATE`. How each UI draws it is not documented (ASSUMED).

### 1.6 OS versions

- Everything above except `proxy_fan_speed_connections`: the fan guide records no change in any release from 3.0.0 to 3.4.1 (`FAN 3_whats_new/`, one page per release): VERIFIED on every OS 3.x.
- `proxy_fan_speed_connections`: from 3.4.2 (`FAN 43_fan_capabilities/_4.5-proxyfanspeedconnections.md`, `PP 3_whats_new/_7-WHATSNEWIN342.md`): VERIFIED, although the fan guide's own 3.4.2 page says the fan proxy did not change in 3.4.2 (`FAN 3_whats_new/_7-WhatsNewin342.md`); two pages of three say 3.4.2.
- OS 4.x: the fan guide has no page after 3.4.2. ASSUMED unchanged.

## 2. proxy_fan_speed_connections

### 2.1 What the docs say

`FAN 43_fan_capabilities/_4.5-proxyfanspeedconnections.md` and `PP 3_whats_new/_7-WHATSNEWIN342.md`, in substance: a boolean capability, from OS 3.4.2, meant for newer fan drivers; True switches on BUTTON_LINK connections made dynamically, tied to the fan speeds, in the fan proxy; it depends on `discrete_levels` and `speed_names` (both misspelt on the page). VERIFIED. That is all of it.

### 2.2 What they do not say

| Question | Best reading | Test |
|---|---|---|
| Who creates the connections? | The proxy: the page places them in the fan proxy, sizes them from capabilities and ties them to an OS release, while a driver could always add bindings itself (`C4:AddDynamicBinding`, since 1.6.0, `API 22_miscellaneous/_1-AddDynamicBinding.md`). ASSUMED | T2 |
| One per speed, and one for Off (speed 0)? | One per speed, no Off. ASSUMED | T2 |
| Their names in Composer | From `speed_names`. ASSUMED | T2 |
| Their binding ids | Not said; on the proxy device, so the driver's own link ids should not collide. ASSUMED | T2, with `C4:GetBindingsByDevice` on the proxy id (`API 32_serial_network_device/_2.5-GetBindingsByDevice.md`) and the ids in the probe's log |
| What a press does | **Model A:** the proxy consumes `DO_PUSH`/`DO_CLICK`/`DO_RELEASE` and sends the driver `SET_SPEED {SPEED=N}` on 5001. **Model B:** the proxy forwards the `DO_*` to the driver on the link's id. **Model C:** nothing happens. ASSUMED | T3 |
| Who lights the LEDs | Model A: the proxy, from the `CURRENT_SPEED` it is told, sending `MATCH_LED_STATE` on each speed link. Model B: the driver must, on ids it learns. ASSUMED | T4 |
| LED colours | The fan proxy has nothing like light_v2's `has_leds`; the keypad's own colours apply. ASSUMED | T6 |
| On OS below 3.4.2 | The unknown capability is ignored and no links appear (capabilities are read by the proxy, `FUND 12_capabilities/_1-CAPABILITIES.md`). ASSUMED | not testable on the house (OS 3.4.3); parked |
| Turned on by updating an installed driver | A capability change: the owner's reboot (`HUE docs/composer-remote.md` rule 10); whether the proxy then adds links to existing devices is not said. ASSUMED | parked to the first such update |
| Survive a reboot with their keypad bindings | A driver's dynamic bindings vanish unless it re-creates them at every start (`API 22_miscellaneous/_1-AddDynamicBinding.md`); whether the proxy does that for its own is not said. ASSUMED yes | T9, parked |

### 2.3 Evidence from the light_v2 proxy

- **Proxies do own Button Links.** The light_v2 proxy has a BUTTON_LINK binding of its own for Brightness Stop that keypad buttons bind to (a 3.3.2 defect broke it): VERIFIED `LV2 5_light_v2_capabilities/_29-SUPPORTSBRIGHTNESSSTOP.md`, `LV2 3_whats_new/_10-WHATSNEWIN332.md`. On this house it created exactly the Brightness Stop and Color Stop links from the capabilities: VERIFIED hardware (`HUE docs/keypad-design.md` "Hardware findings").
- **Proxy-managed links with LED colours.** light_v2's `GET_SETUP` lists each brightness and colour preset with a button-link binding id and active and inactive colours (VERIFIED `LV2 10_light_v2_commands/_16.5-GETSETUP.md`). That reads as a proxy that knows which preset is active and lights the linked buttons itself, which is model A (ASSUMED).
- **And the warning.** The light_v2 guide says the proxy creates and maintains Top, Bottom and Toggle links and forwards their presses as `BUTTON_ACTION` (`LV2 10_light_v2_commands/_1-BUTTONACTION.md`). On this house it did not: the driver had to declare ids 200 to 202 itself and received `DO_PUSH`/`DO_RELEASE`/`DO_CLICK` on them (VERIFIED hardware, `HUE docs/keypad-design.md` "Hardware findings"). The proxy guides describe intent, not always behaviour.
- **Nobody public uses it.** A GitHub code search on 2026-10-27 for `proxy_fan_speed_connections` finds only Snap One's doc page; Snap One's fan template has no code for it (`TPL`, dated 2023); every public fan driver read declares its own links instead (community).

Conclusion: plausible (model A matches how the light_v2 proxy appears to treat its own links) but unproven; it must be seen working (T2 to T4) before the design relies on it.

## 3. Driver-declared Button Links

What the Hue drivers do on this house, transferable as is.

| Piece | Detail | Status |
|---|---|---|
| Connection | id in the control range 1 to 999, type 1, consumer False (the device provides the link, shown under its Control Outputs; the keypad's "\<button> Button Link" is the consumer), class `BUTTON_LINK`; the Hue Light uses 200 Top, 201 Bottom, 202 Toggle, with linelevel True | VERIFIED `XML 50_connections_xml/_15-id.md`, `HUE src/hue_light/driver.xml`; hardware `HUE docs/keypad-design.md` "Hardware findings" |
| Available since | OS 3.0.0: Button Linking was added to the keypad proxy then | VERIFIED `KP 3_whats_new/_20-WhatwasNewinOS3.md` |
| A press | `ReceivedFromProxy(<link id>, "DO_PUSH" / "DO_RELEASE" / "DO_CLICK", {})` | VERIFIED `KP 62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`; hardware `HUE docs/keypad-design.md`. The exact order and timing for a tap, a hold and a double tap: ASSUMED (T5) |
| When to act | the SDK advises acting on the press when hold versus click does not matter | VERIFIED `KP 62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md` |
| The LED | `C4:SendToProxy(<link id>, "MATCH_LED_STATE", { STATE = true or false }, "COMMAND")` on every change, at late init, when a keypad binds and after `REQUEST_BUTTON_COLORS` | Message VERIFIED `KP 62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`; COMMAND is the default below id 1000 (`API 25_proxy/_6-SendToProxy.md`); hardware: a keypad's LEDs follow a Hue scene (`HUE docs/design.md` "Keypad and scene dimmer: verified on hardware"); code `HUE src/common/device.lua` (`send_leds`, `update_leds`) |
| Colours | the keypad sends `REQUEST_BUTTON_COLORS` on the link; the driver answers `BUTTON_COLORS` (on and off colour) and then `MATCH_LED_STATE`; `SET_BUTTON_COLOR` sets one | VERIFIED `KP 62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`, `HUE src/common/device.lua`. That the keypad adopts colours sent this way: ASSUMED (T6) |
| Bind and unbind | `OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)`, called for control bindings such as these | VERIFIED `API 9_helper/_12-OnBindingChanged.md`; `HUE src/hue_light/driver.lua` re-sends the LEDs on a bind |
| Installing | connections added by a build reach installed devices at once through "Add or Update Driver or Agent…", no reboot | VERIFIED hardware (`HUE docs/keypad-design.md` "Hardware findings", build 146) |
| Changing later | only add connections in an update; never remove or retype one | VERIFIED `FUND 14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` |

How `HUE src/common/device.lua` does it: a table maps link id to button (200 top, 201 bottom, 202 toggle); the `DO_PUSH`, `DO_RELEASE` and `DO_CLICK` handlers look the id up and feed one press, click and release machine (400 ms makes a hold; a click within 1 s of a hold's release is dropped); `update_leds(force)` sends `MATCH_LED_STATE` on every link (and `BUTTON_INFO` to the light_v2 proxy) when the on state changes, `force` after a bind; `REQUEST_BUTTON_COLORS` is answered on the asking link; colours persist per button. The module is the owner's own code, shared with this project; the fan's links need a simpler machine (no holds, [section 7](#7-recommended-design-fan-side)). Public fan drivers declare their fan links the same way, ids from 200 or 300, class `BUTTON_LINK` (community).

## 4. Off, Toggle, Cycle and Preset links

None of these is part of `proxy_fan_speed_connections`, which covers the speeds only (VERIFIED `FAN 43_fan_capabilities/_4.5-proxyfanspeedconnections.md`); whether the proxy adds an Off link is T2. The actions and LED rules are design proposals for the owner.

| Link | From | Press | LED lit while |
|---|---|---|---|
| Speed 1 to 6 | the proxy, if T2 to T4 show model A; else the driver | speed N | speed is N |
| Off | the driver (unless T2 finds one) | speed 0 | off |
| Toggle | the driver | as `TOGGLE`: on goes off, off goes to the preset | on |
| Cycle (up; down optional) | the driver | as `CYCLE_SPEED_UP`; the wrap rule is ours | on |
| Direction (optional) | the driver | as `TOGGLE_DIRECTION` | reversed |
| Preset | not a link in v1 | `DESIGNATE_PRESET` stays a UI and programming command; a "go to preset" link would equal `ON` | |

## 5. Composer side

- **Linking.** Select the keypad; in Connections its "\<button> Button Link" rows are Control Inputs in the upper pane; drag one onto the fan's link in the lower list ("BUTTON_LINK Output Devices"). VERIFIED (`C4HELP configuring_a_2_button_keypad.htm`; hardware, including the Windows session's synthesized drag, `HUE docs/composer-remote.md` "Learned 2026-10-27").
- **Follow Connection.** Making a link switches that button's LED Behavior to Follow Connection; disconnecting does not switch it back. The choices are Follow Connection, Follow Load, Push/Release and Programmed. VERIFIED hardware (`HUE docs/composer-remote.md` "Learned 2026-10-27"). It means the LED shows the on or off colour the linked device asks for with `MATCH_LED_STATE`, which the keypad applies only while the LED tracks a bound device (VERIFIED `KP 60_keypad_proxy_commands/_6-KEYPADBUTTONINFO.md`; `C4HELP keypad_properties.htm` lists an LED behavior "Follow Bound Device" that reflects the bound device's state, presumably the same option under an older name). The state is binary: one button has one "on" colour, so blue for speed 1 and orange for speed 6 on the same button (today's programming) is only possible if the driver may change the button's colours over the link (ASSUMED, T6).
- **What a change costs.**

| A driver update that changes | Installed devices | Status |
|---|---|---|
| Lua only | take it at once | VERIFIED hardware (`HUE docs/composer-remote.md` rule 10) |
| `<connections>`, added | take it at once, no reboot | VERIFIED hardware (`HUE docs/keypad-design.md`, build 146) |
| `<connections>`, removed or retyped | the project's bindings for that driver break | VERIFIED `FUND 14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` (never do it) |
| `<capabilities>`, any (this capability, `discrete_levels`, `speed_names`) | Composer asks "Restart Director?"; Yes does not load them; the owner reboots the controller from System Manager | VERIFIED hardware (`HUE docs/composer-remote.md` rule 10, `HUE docs/keypad-design.md` "Install findings") |
| `<proxies>` | project corruption; a new driver is required | VERIFIED `FUND 14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` |

- **The stock driver is a different driver.** The new fan is a new device: links and programming that name the stock device stay with it, and the migration contract decides how they move.

## 6. Minimum OS

| Option | The fan needs | Gains | Costs |
|---|---|---|---|
| A. Proxy speed links, driver Off/Toggle/Cycle, floor 3.4.2 | 3.4.2 | standard links; least code (model A) | excludes 3.0 to 3.4.1; rests on undocumented behaviour; two mechanisms |
| B. Driver links for everything | 3.0.0 | one mechanism, verified on this house; every OS 3.x and 4.x; LED rules, colours and multi-click are ours | more code; link names are ours |
| C. Capability on, plus driver Off/Toggle/Cycle; floor set by the light | 3.4.2 for the speed links only | A's gains on 3.4.2 and later, still installs below | only valid under model A; below 3.4.2 no per-speed links (a documented limitation, untested) |

`<minimum_os_version>` is documented only as an auto-update gate (`FUND 14_updating_released_drivers/_1-UPDATINGRELEASEDDRIVERS.md`); whether Composer refuses a manual install on an older OS is not documented (ASSUMED). A driver can check at run time with `C4:GetVersionInfo()` (`API 5_director_command/_2-GetVersionInfo.md`), for example to say in Status that speed links need 3.4.2.

**Recommendation:** the fan does not set the floor. v1 takes the light side's minimum (the Hue Light declares 3.3.0 for light_v2's colour and target APIs, `HUE docs/design.md` "Targets"; the scaffold's stand-in is 3.3.0). Choose B, or C if T2 to T4 show model A working completely. A buys nothing over C. C stays reversible at a price: if T9 (parked) later shows the proxy's links or their keypad bindings lost on a reboot, a later release adds links 301 to 306 at once and turns the capability off with one owner reboot, and the dealer rebinds those buttons.

## 7. Recommended design (fan side)

Each item says what it rests on; the rest is a proposal for the v1 contract.

1. One driver, two proxies: fan on 5001, light_v2 on 5002; the dispatcher routes on binding and command ([section 1.1](#11-declaration)). Structure VERIFIED; the fan proxy's name and class ASSUMED until T1.
2. Capabilities `discrete_levels` 6, `speed_names` as the owner names them, `preset_speed`, `can_set_preset` True, `can_reverse` per the fan API research, and `proxy_fan_speed_connections` per T2 to T4. VERIFIED names and meanings; static (ASSUMED, [section 1.2](#12-capabilities)), so fix them before the first install on the house.
3. The commands and notifications of sections 1.3 and 1.4; `CURRENT_SPEED` on every change and in answer to `GET_CURRENT_STATE`; `ON`/`OFF` per T8; `PRESET_SPEED` after `DESIGNATE_PRESET` and at late init. VERIFIED messages; the answers to `DESIGNATE_PRESET` and the use of `ON`/`OFF` ASSUMED (T7, T8).
4. Links (ids proposed; 200 to 202 stay the light's, so the Hue keypad module's map carries over). The mechanism is VERIFIED ([section 3](#3-driver-declared-button-links)); the set, names and LED rules are proposals:

| Id | Name in Composer | Press | LED lit while |
|---|---|---|---|
| 200, 201, 202 | Light Top / Bottom / Toggle Button Link | light_v2 keypad machine of `HUE src/common/device.lua` | as the Hue Light |
| 300 | Fan Off Button Link | speed 0 | off |
| 301 to 306 | Fan Speed N Button Link (option B only) | speed N | speed is N |
| 307 | Fan Toggle Button Link | on goes off, off goes to the preset | on |
| 308 | Fan Cycle Button Link | one speed up; the end rule is the owner's | on |
| 309, 310 | Cycle Down, Direction (optional) | as `CYCLE_SPEED_DOWN`, `TOGGLE_DIRECTION` | on, reversed |

5. Presses: act on `DO_PUSH` (the SDK's advice, VERIFIED, [section 3](#3-driver-declared-button-links)); a `DO_CLICK` with no push before it on that link acts too (a guard: that pushes always come first is ASSUMED, T5); `DO_RELEASE` is ignored; fan links have no holds. Double taps are ignored in v1 (T5 shows what they send).
6. LEDs: from the driver's own state; on a change only the links whose state changed get `MATCH_LED_STATE`; all of them at late init, on a bind (`OnBindingChanged`) and on `REQUEST_BUTTON_COLORS`. Mechanism VERIFIED (section 3). Under model A the proxy lights the speed links and the driver still lights 300 and 307 to 310 (ASSUMED, T4).
7. Timing: on a command the driver reports the new speed and LEDs at once and then follows the fan's confirmed state; a report older than the last command must not move the state back. The stock driver's late, out-of-order reports are what the house's 1 s settle timer absorbs today ([CLAUDE.md](../CLAUDE.md), "Environment"); the mechanics belong to the fan API contract. A proposal; nothing in the SDK forbids an early `CURRENT_SPEED`.
8. Colours: the driver sends no `BUTTON_COLORS` in v1, so the keypad's own colours stay (ASSUMED, T6); per-link colour properties only if T6 shows the keypad adopts them and the owner wants them.

## 8. Hardware tests

Each takes under a minute of anyone's time after the install. A throwaway **probe** package (its own file name and driver name, never the real driver's, because Director keeps a driver's capabilities until a reboot) declares the fan proxy, the capabilities of [section 7](#7-recommended-design-fan-side) with `proxy_fan_speed_connections` True, one link of its own (300), logs every `ReceivedFromProxy`, `ExecuteCommand` and `OnBindingChanged`, and opens its Lua window (`C4:AllowExecute`, `FUND 6_Understanding .c4z Drivers/_3-C4ALLOWEXECUTE.md`). The Lua output pane shows only live lines, so the probe's Lua tab is open before each press (`HUE docs/composer-remote.md` rule 13). The owner's standing approval covers the install, the bindings and the delete; the brief names them (rules 2 and 8 there).

| Test | Settles | How | Reading |
|---|---|---|---|
| T1 | the proxy's XML name and class; whether the stock driver declares its 13 links or uses the capability; a working capability set for these fans | Windows session: copy the stock `.c4z` from Composer's driver store, open it as a zip, read `driver.xml` (`<proxies>`, `<capabilities>`, `<connections>`); report names and ids only, commit nothing of it. No install needed. | If the stock driver sets the capability and its `<connections>` lack the speed links, its dead links were the proxy's. The stock driver does take speed commands and reports speeds (the house's keypad scripts and its "Fan Speed Changed" timer use both), so model A is then refuted on OS 3.4.3, leaving B or C |
| T2 | the proxy makes speed links on OS 3.4.3; their names; an Off link; their ids | Windows session installs the probe, adds one device, reads its Connections rows; the Lua window prints `C4:GetBindingsByDevice(C4:GetProxyDevices())` (`API 25_proxy/_1-GetProxyDevices.md`; its output for control bindings is undocumented) | links listed or not |
| T3 | model A, B or C | bind a spare keypad button (no programming, no link) to the "speed 2" link by the drag; one press, then a second press. The press: `C4:SendToDevice(<keypad proxy id>, "KEYPAD_BUTTON_ACTION", {BUTTON_ID = n, ACTION = 1})` then `ACTION = 2` from the Lua window (the command exists, `KP 60_keypad_proxy_commands/_4-KEYPADBUTTONACTION.md`; that it travels the link is ASSUMED), else the owner presses once | `SET_SPEED {SPEED=2}` on 5001 = A (the second press shows whether it toggles); `DO_*` on another id = B; nothing = C |
| T4 | the proxy lights the LEDs | the button on Follow Connection; the Lua window sends `CURRENT_SPEED` 2, then 3, then 0, five seconds apart; the owner glances at the LED | lit, dark, dark = A |
| T5 | driver links work on a fan-proxy driver; what a hold and a double tap send | rebind the button to the probe's 300; tap, hold, double tap; then `MATCH_LED_STATE` true and false from the Lua window | `DO_PUSH`, `DO_RELEASE`, `DO_CLICK` on 300 in some order; the LED follows; the double tap's messages |
| T6 | the keypad adopts colours sent over the link | `BUTTON_COLORS` on 300 with an on colour of red, then `MATCH_LED_STATE` true | red or not |
| T7 | the UIs' parameter names; `GET_CURRENT_STATE`; whether `DESIGNATE_PRESET` needs the `PRESET_SPEED` answer | the owner taps speed 4, Off, reverse and the preset on the probe in the Control4 app; the probe does not answer the preset until the Lua window reads the proxy's variables (`C4:GetDeviceVariables`) and then sends `PRESET_SPEED` | `SET_SPEED {SPEED}`, `SET_DIRECTION {DIRECTION}`, `DESIGNATE_PRESET {PRESET}` as in [section 1.3](#13-commands-proxy-to-driver); `GET_CURRENT_STATE` at the add; Current Preset unchanged before the answer means the answer is needed |
| T8 | whether `ON`/`OFF` notifications are needed | from 0, the Lua window sends `CURRENT_SPEED 2` alone and reads `C4:GetDeviceVariables(<proxy id>)` (`API 22_miscellaneous/_12-GetDeviceVariables.md`); then `ON` alone | Is On true after `CURRENT_SPEED` alone: `ON`/`OFF` not needed. `ON` moving the speed to the preset: never send it after `CURRENT_SPEED` |
| T9 | links and bindings survive a reboot | parked to the owner's next reboot | |
| cleanup | | the Windows session unbinds the button, sets its LED Behavior back (a disconnect does not), deletes the probe device | |

## 9. Open questions

1. **Model A, B or C** (T2 to T4) decides options B or C of section 6 and whether links 301 to 306 exist.
2. **An Off link from the proxy?** (T2.)
3. **Speed counts.** Do all Modern Forms fans have six speeds (the fan API research)? If not, one package per count, because `discrete_levels` is static.
4. **The house keypad's layout.** Today it reaches speeds 1 and 6 by double taps, with a colour per speed. Follow Connection is on/off, and double taps over a link are undocumented (T5, T6). The owner decides the button-to-link layout for the migration (a `question` issue).
5. **CLAUDE.md's scope line** has the proxy's per-speed links handle `DO_PUSH`/`DO_CLICK`/`DO_RELEASE` and send `MATCH_LED_STATE`; nothing in the SDK says the driver sees proxy-made links at all (under model A it does not). Reword it in the v1 contract after T3 and T4.
6. **Cycle and LED rules** (wrap to 1 or through Off; what Off, Toggle and Cycle light): the owner's call.
7. **A newer stock driver?** A web search on 2026-10-27 showed WAC's support page "Where can I find the Control4 Direct IP Drivers" listing `wac_mf_fan_and_light_controller` at version 6 (the house runs v4); the page refused a direct fetch (HTTP 403), so this is unverified. Worth one look from the Windows session's browser before building.
8. **Fan offline.** The fan proxy has no documented `ONLINE_CHANGED`; the driver reports it through its own property and event.
