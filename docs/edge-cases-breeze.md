# Breeze in Control4: Navigators, programming and edge cases

> **Research (2026-11-07) for [issue #111](https://github.com/corytron/c4-modernforms-driver/issues/111)**,
> read-only: nothing here was tried on the house fan or the controller. The
> owner asked that the fan's Breeze mode (the fan speeds up and slows down by
> itself, like a breeze) be switchable from Control4, and later the same day
> set the priority: **Breeze must show on the Navigators** (the Control4 app
> on the phone, touchscreens, on-screen Navigators), which matters more than
> Composer. Today (v1.1, build 97) the driver reads the fan's `wind` key and
> names Breeze only in the Composer rows `Status` and `Fan Model`; nothing
> can switch it. This note is the Control4 side: every way Breeze can reach a
> Navigator, ranked by what an owner sees; the programming, keypad and
> Composer surfaces; one recommended design; and the lifecycle edge cases on
> both sides. The fan side (the fields `wind` and `windSpeed`, what the fan
> does and reports, checks BR0 to BR8) is the sibling note
> [`breeze-research.md`](breeze-research.md); where the two overlap, that
> note says what the fan does and this one decides what Control4 does.

**The short answer.** The fan proxy cannot show Breeze: it has no mode,
preset mode, extras, custom button or state icon of any kind, on any
documented OS (3.0.0 to 3.4.2; nothing documents a change since, BE1). Every Navigator path therefore goes through another proxy. A proxy
cannot be added to the installed fan device (BE4), so the recommended
Navigator surface is a **companion device**: a small new driver, **Modern
Forms Breeze**, with a `light_v2` on/off proxy, added from the fan item with
one click (as the Hue bridge adds its light and scene devices on this
house). It is a tile named after the fan, for example "Aviator 5 Breeze",
lit while the fan blows a breeze and switched by a tap, on the phone and on
touchscreens. Beside it the fan driver gains programming commands, a
`Breeze` variable, two events, a condition and a keypad link with an LED.
Nothing needs a controller reboot or a re-created device.

**Decisions:** **A** automatic, **O** only offered (a click, a command or a
programming line the dealer writes), **F** forbidden without a click (or
forbidden outright where the row says so). **Markers:** **VERIFIED** names a
primary source (an SDK file, a measurement on this house, code in this
repository); **ASSUMED** says why and names the check that settles it.
Snap One's documents are paraphrased, never quoted. Placeholders only: fan
`10.0.2.151`, MAC `00:00:5E:00:53:01`, client id `MF_00005E005301`, room
"Example Room", keypad "Example Keypad", device ids `456`.

| Key | Source |
| --- | --- |
| FAN | `~/c4-tools/reference/docs-driverworks-proxyprotocol-fan/source/includes/` (all 51 pages; identical to Snap One's repository head, whose last content change is 2024-06, read with `gh api` on 2026-11-07) |
| PP | `~/c4-tools/reference/docs-driverworks-proxyprotocol/source/includes/` (the combined proxy guide; light_v2 extras in `66.6_Light_v2_extras/`, `63_light_v2_capabilities/`) |
| LV2, UIB, KP | `docs-driverworks-proxyprotocol-lightv2/`, `-uibutton/`, `-keypad/`, each `source/includes/` |
| API, FUND, XML | `docs-driverworks-api/`, `docs-driverworks-fundamentals/`, `docs-driverworks-xml/`, each `source/includes/` |
| HUE | the owner's Hue project (`~/projects/c4-hue-driver`, [public](https://github.com/corytron/c4-hue-driver)), measured on this house: `docs/design.md` (sections "Lights: verified on hardware", "Scene dimmer, build 160"), `docs/composer-remote.md` rule 10, `docs/keypad-design.md` (build 146), `docs/relative-level-design.md` (programming commands added in an update, #297) |
| V1D | [`v1-design.md`](v1-design.md): events and variables [2.7](v1-design.md#27-events-variables-conditional), connections [2.4](v1-design.md#24-connections), fan links [5.1](v1-design.md#51-fan-links-300308), texts [7.1](v1-design.md#71-status) and [7.2](v1-design.md#72-last-action), not in v1 [15](v1-design.md#15-not-in-v1) |
| ECC, ECM | [`edge-cases-control4.md`](edge-cases-control4.md#0-the-facts-everything-below-rests-on) (F1 to F29, rules R1 to R9 in [5.1](edge-cases-control4.md#51-the-report-contract), cases C, P, U); [`edge-cases-modernforms.md`](edge-cases-modernforms.md#9-not-offered-in-v1-so-that-nothing-automates-them) (A8, section 9) |
| BRR | [`breeze-research.md`](breeze-research.md): the fields, the bodies, the risks of its section 5, checks BR0 to BR8 |
| code | `src/modernforms_fan/driver.xml`, `driver.lua`, `fan/{fanproxy,links,model,texts,wire}.lua`, `www/documentation.html`, as on `feat/breeze-111` (build 97 plus #102) |
| COMM | community evidence, not Snap One's: the WLED driver's manual ([finitelabs/control4-wled](https://github.com/finitelabs/control4-wled), README, "The Extras menu"); Snap One's public template code (`snap-one/drivers-template-code-public`, `proxies/light_proxy/light_proxy_notifies.lua`, found with `gh search code`); the Big Ass Fans driver's manual ([drivercentral](https://drivercentral.io/images/CinSiteIcons/BAS/baf_documentation_ui.pdf), its Whoosh mode is a Composer property) |

## 0. Evidence the decisions rest on

| # | Fact | Status |
| --- | --- | --- |
| BE1 | **The fan proxy has no place for Breeze.** Its commands are ON, OFF, TOGGLE, DESIGNATE_PRESET, SET_SPEED, CYCLE_SPEED_UP and _DOWN, SET_DIRECTION, TOGGLE_DIRECTION, GET_CURRENT_STATE, GET_STATE, GET_SETUP; its notifications CURRENT_SPEED, DIRECTION, PRESET_SPEED, ON, OFF; its capabilities `can_reverse`, `can_set_preset`, `discrete_levels`, `preset_speed`, `speed_names`, `proxy_fan_speed_connections`; four events, four variables, four conditionals. No mode, preset mode, extras, icon state or custom control. What a Navigator asks it for (`GET_SETUP`: speed count and names, reverse, preset; `GET_STATE`: current speed, reversed) has no field for one. Every release page from 3.0.0 to 3.4.2 says the fan proxy did not change; there is no OS 4 page. | VERIFIED: FAN, every file (`41_` to `46_`, `3_whats_new/`); PP `41_` to `46_` identical. OS 4.x: ASSUMED unchanged (no page) |
| BE2 | No fan capability is documented as dynamic; any change of `<capabilities>` on an installed device makes Composer ask "Restart Director?", Yes does not load it, and the owner must reboot the controller from System Manager. | VERIFIED: FAN `43_fan_capabilities/` (no "Dynamic Capability" field, unlike LV2); house: HUE `composer-remote.md` rule 10, ECC F26 |
| BE3 | Navigators show a fixed icon per proxy; per-state icons are documented only for the UI Button proxy. Nothing in API, FUND or XML documents a Navigator view of a driver's variables or properties. `C4:SendDataToUI` reaches only Navigators subscribed to the device, that is, ones drawing its proxy's own page. | VERIFIED: FUND `19_driver_icon_management/_1-DRIVERICONMANAGEMENT.md`; UIB `104_ui_button_proxy_capabilities/_1-UIBUTTONCAPABILITIES.md`; API `22_miscellaneous/_35-SendDataToUI.md`; a search of API, FUND and XML for "navigator" (scheduler, history, refresh and data-to-UI pages only) |
| BE4 | **A proxy cannot be added to an installed device.** Proxies are created only when a device is added; an update that adds, removes or retypes a proxy corrupts the project, so a different proxy set needs a new driver file. On this house a device was re-created once for less (icons, #91, 2026-11-05): every setting copied, seven keypad bindings and two Double Tap lines moved, the old device deleted. | VERIFIED: FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`; ECC F1; [`status.md`](status.md) |
| BE5 | **light_v2 Extras.** Since OS 3.3.0 a light_v2 driver can describe controls (switch, button, checkbox, list, slider, number, text) that Navigators show on an "Extras" page of that light; `has_extras` is a dynamic capability, so it can be switched on at run time with `DYNAMIC_CAPABILITIES_CHANGED` and no reboot. The driver sends `EXTRAS_SETUP_CHANGED` and `EXTRAS_STATE_CHANGED` (one XML string each); a change on a Navigator arrives as the object's command, and the Navigator puts the control back unless the driver answers with a state within 10 s. The setup XML's elements are not printed in Snap One's docs (only a state fragment is); community drivers and Snap One's template code use them. How a user reaches the page: press and hold the light, in the Control4 app or on a touchscreen. | VERIFIED: PP `66.6_Light_v2_extras/_0-HEADER.md`, `_1-EXTRAS.md`, `_10-EXTRASSWITCH.md`; PP `63_light_v2_capabilities/_13.6-HASEXTRAS.md`; LV2 `5_light_v2_capabilities/_13.6-HASEXTRAS.md`; FUND `27_proxy_specific_info/_51-LIGHTV2EXTRAS.md`; PP `3_whats_new/_12-WHATSNEWIN330.md`. The press and hold, and the app showing it: COMM (WLED manual), ASSUMED on this house |
| BE6 | **A light_v2 device for something that is not a lamp, added by another driver, works on this house's Navigators.** The Hue bridge adds light and scene devices with `C4:AddDevice` on a Composer action, binds them with `C4:Bind`, and the two drivers talk with `C4:SendToDevice` both ways; a Navigator tap ON and OFF on a scene device reached its driver; after File ▸ Refresh Navigators the scene's tile in the Control4 app on the owner's iPhone showed its state and slider. `C4:AddDevice` exists from 3.2.0 and is for user-initiated use only. | VERIFIED: house (HUE `design.md`, "Lights: verified on hardware", "Scene dimmer, build 160", the first scene device); API `9_helper/_0.1-AddDevice.md`, `9_helper/_1-bind.md`, `32_serial_network_device/_19-SendToDevice.md` |
| BE7 | **light_v2 basics for such a device:** `dimmer` False makes an on/off switch and is dynamic; `ONLINE_CHANGED` false greys its controls; `reduced_als_support` is static and keeps a load out of Advanced Lighting Scenes when False. | VERIFIED: LV2 `5_light_v2_capabilities/_5-DIMMER.md`, `22-REDUCEDALSSUPPORT.md`; LV2 `35_…/_15-ONLINECHANGED.md`; ECC F10, F12 |
| BE8 | **UI Button proxy** (OS 2.9.0): a configurable button the dealer places on a room's experience menus (Comfort, Listen, Watch, Security…) through Composer's room Navigator settings; a tap sends `SELECT` and fires its Selected event; `navigator_display_option` declares state icons and `ICON_CHANGED` picks one, with a text used by the list Navigator. Snap One's demo asks to check the icon state on touchscreens and on mobile devices. No keypad links. | VERIFIED: UIB `103_ui_button_proxy_overview/_1-UIBUTTONPROXYOVERVIEW.md`, `104_…/_1-UIBUTTONCAPABILITIES.md`, `106_…/_1-ICONCHANGED.md`, `107_…/_1-SELECT.md`. That a plain button shows its state on the phone: ASSUMED (the demo's wording also concerns its web view) |
| BE9 | **Programming surface.** A driver's `<commands>` are its device-specific commands in Programming, beside the proxy's; params of type LIST, RANGED_INTEGER and others; the name reaches `ExecuteCommand`. Events have fixed ids; variables are numbered in `AddVariable` order, belong in `OnDriverInit`, and may be read-only; BOOL conditionals answer through `TestCondition`. In an update: commands and events must never be removed, variables never removed, renamed, retyped or renumbered; adding any of them is safe. | VERIFIED: XML `35_commands_xml/` (all pages); FUND `9_commands/_1-COMMANDS.md`, `15_composerpro_interface_into_the_sdk/_7-PROGRAMMING.md`, `10_conditionals/_8-XMLINABOOLEANTYPECONDITIONAL.md`, `_4-USINGTHETESTCONDITIONFUNCTION.md`; API `36_variable/_1-AddVariable.md`, `7_event/_4-FireEventByID.md`; FUND `14_…/_2-DRIVERUPDATECONSIDERATIONS.md`; ECC F2, F24 |
| BE10 | **On this driver today:** events 1 Fan Offline and 2 Fan Online (3 reserved for "Changed Outside Control4"), shown under the fan item and run by a script on the house; one variable `Online`, added first and seeded from the persisted `mf_online` so a restart fires nothing; one conditional `BOOL_ONLINE` (id 0); no `<commands>`; five actions with `sort_order` 2 to 6. Actions are Composer-time configuration; programming cannot call them. | VERIFIED: code (`driver.xml`, `driver.lua` `OnDriverInit`, `TestCondition`); house: [`status.md`](status.md) (Fan Offline 46 s after the fan stopped answering, #58); FUND `15_…/_6-ACTIONS.md`; HUE `simplify-research-compat.md` section 1 (programming cannot refer to an action) |
| BE11 | A build that added `<commands>` to an installed driver went onto this house in place: the Hue Light's two commands (#297) in v1.1-beta.3, build 394, whose checklist expected no reboot because no capability changed. Connections added in an update reach existing devices at once, no reboot (Hue build 146). | VERIFIED: house (HUE `docs/composer-checklist.md` section K, the desired-state commit of beta.3; HUE `keypad-design.md`); that the new lines show at once under the fan item of a two-proxy device: ASSUMED, check BN1 |
| BE12 | **Button Links:** a link is a provider control binding of class `BUTTON_LINK` (ids 1 to 999); a keypad sends `DO_PUSH`, then `DO_CLICK` or `DO_RELEASE`; the driver lights a bound button with `MATCH_LED_STATE` (on or off colour, nothing else), which fires no programming. This driver's links are 200 to 202 and 300 to 308; 203 to 209 and 309 to 319 are reserved, 309 for Cycle Down and 310 for Direction, so **311 is the first free fan id**. The house keypad's seven buttons are all bound. | VERIFIED: KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`; house K6, K7 (V1D 11.1); V1D 2.4, 5.4; code `links.lua` |
| BE13 | **The fan's side** (BRR): `wind` (bool) and `windSpeed` (1 to 3) exist only on Gen 3 fans with the hardware, and the `wind` key's presence is the capability (the house fan has both, M0). Not known until BR1 to BR6: whether `fanSpeed` moves with the gusts; whether `{"wind":true}` starts a fan that is off; whether off clears `wind` (Home Assistant says no); whether a speed command ends Breeze; whether Breeze forces the direction forward and restores it after; whether Breeze uses its own 1 to 3 scale rather than "any set speed". | VERIFIED and ASSUMED as BRR marks them, sections 1 and 2 |
| BE14 | **How others show it:** Home Assistant as a fan preset `breeze` plus a separate 1 to 3 number; openHAB a switch plus a level; Homey an on/off capability with flow cards; a commercial Control4 fan driver (Big Ass Fans, Whoosh mode) as a Composer property (and, its listing says, a programming command and an event). No Control4 fan driver found shows a fan mode on the fan's own Navigator tile. | VERIFIED: BRR section 3; COMM (the BAF manual, pages 1 and 2). The last sentence: ASSUMED (absence in what was found) |
| BE15 | `C4:RecordHistory` (3.4.0) writes an entry the Control4 app shows in History and can deep-link to a device; it needs the History Agent. | VERIFIED: API `15_lua_tcp_server/_15-RecordHistory.md`; ECC U11 (History not in v1) |

## 1. Navigators: every way Breeze can appear, ranked

**The fan proxy cannot show it** (BE1, BE2): there is no Breeze, mode,
preset-mode, extras or icon field on the fan's tile or page, and no
capability that could be switched on later. Every row below uses another
proxy, or something that is not a Navigator control at all. Ranked by what
an owner actually sees on the phone and the touchscreens.

| Rank | Surface | What the owner sees | Control too? | OS 3 / OS 4 | Cost on the house | Cost in code | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **1** | **Companion switch:** a new driver `modernforms_breeze.c4z` with one `light_v2` proxy, on/off only, added from the fan item by a click ("Add Breeze Switch"), bound to the fan device | A tile "Aviator 5 Breeze" in the room's lights, lit while the fan blows a breeze, at a glance, like any switch; greyed while the fan is offline or has no Breeze | Yes: one tap toggles; programming, scenes and voice see an ordinary switch | 3.3.0 and later (AddDevice 3.2.0); OS 4: ASSUMED (light_v2 is the most basic Navigator object) | One more package installed with the release; one click; File ▸ Refresh Navigators; no reboot, no re-created device | A second small driver on `common/device.lua`; a binding and a few messages between the two; the Hue bridge's pattern | Mechanism VERIFIED on this house (BE6); this device: ASSUMED until BN3 |
| 2 | **Companion Experience button:** the same companion with a `uibutton` proxy instead | A button "Aviator 5 Breeze" on the room's Comfort menu (where the dealer makes it visible), its icon showing on or off | Yes: a tap toggles | 2.9.0 and later; OS 4: ASSUMED | As rank 1, plus setting its visibility per room in Composer | As rank 1, plus drawn state icons | VERIFIED-doc (BE8); never used on this house; the state on the phone ASSUMED |
| 3 | **Extras on the fan's own light item:** a "Breeze" switch (and a 1 to 3 list) on the light's Extras page, `has_extras` switched on at run time | Nothing on the tile; press and hold the fan's light, then a Breeze switch | Yes, inside that page | 3.3.0 and later; OS 4: ASSUMED | None: Lua only, no new device, no reboot | The Extras XML (not printed by Snap One, BE5) and its 10 s answer rule | VERIFIED-doc for the mechanism; the press and hold COMM; on this house ASSUMED. Useless on a fan without a light kit (the light is offline for good, V1D 4.7) |
| 4 | Keypad LED on a new **Fan Breeze** link (311) | A physical button lit while Breeze blows; not a Navigator | Yes, a press toggles | 3.0.0 and later | Lua and a connection, no reboot (BE11); the house keypad has no free button | Small (links.lua) | VERIFIED pattern (BE12) |
| 5 | History entries "Breeze on/off" (`C4:RecordHistory`) | A line in the app's History, a moment after the fact; not the current state | No | 3.4.0 and later only, with the History Agent | Lua only | Small, version-guarded | VERIFIED-doc (BE15); deferred like U11 |
| 6 | Push notification written by the dealer on the new events | A banner on the phone when Breeze starts or stops | No | as the dealer's agents allow | None in the driver; a programming line | None beyond the events | Composer agents, outside the SDK: ASSUMED |
| F1 | A seventh "speed" named Breeze (`discrete_levels` 7, `speed_names` "…,Breeze") | Breeze on the fan tile | — | — | A reboot (BE2); every Speed link, the house's Double Tap lines and "Set speed Level N" programming change meaning; Breeze would hide the base speed | — | **F**: Breeze is a mode beside the speed (BE14), and the change cannot be undone without another reboot |
| F2 | A third proxy (uibutton or light_v2) in `modernforms_fan.c4z` | As rank 1 or 2, on the same device | — | — | A new driver file and a re-created device on every installation (BE4) | — | **F** |
| F3 | Renaming the fan item while Breeze blows ("Aviator 5 (Breeze)") | The name on every tile | — | — | Refresh Navigators on every change; breaks voice names; the owner's names are his (V28, ECC rule 1) | — | **F** |
| F4 | Sending `has_extras` or `EXTRAS_SETUP_CHANGED` to the fan proxy (5001) | Maybe an Extras page on the fan | — | — | — | — | **F** to ship: undocumented for the fan (BE1), "Do not invent DriverWorks API calls" (CLAUDE.md); and hidden behind a press and hold even if it worked |

**Why rank 1 over 2 and 3.** The owner asked for an *indication* on the
phone and the touchscreens. Only a device of its own puts the state on a
tile that is seen without opening anything; of the two proxies that can do
that, light_v2 is the one this house has already seen working end to end
from another driver, on the owner's iPhone (BE6), it reuses
`common/device.lua`, and its tile is a native switch on every Navigator.
The UI Button needs drawn icons, a visibility setting per room and per
menu, and its state on the phone is not shown anywhere yet (BE8). Extras
cost nothing on the house but show nothing until the light is pressed and
held (BE5), and fail without a light kit.

**The cost of rank 1, said plainly.** A second device per fan: the
switch counts among the room's lights (a "lights on" summary may count it,
ASSUMED), lighting scenes, "all lights off" groups and voice assistants may
include it unless the dealer leaves it out, and Composer shows one more item.
Switching it off only ends Breeze (the fan keeps turning); switching it on
starts the fan (BC9), so the manual says to keep it out of "all lights on"
groups. It joins no Advanced Lighting Scene (`reduced_als_support` False,
BE7).

**Rank 2 and 3 stay possible later** without touching the fan device:
rank 2 is the same companion with another proxy (a separate package), rank
3 is Lua in the fan driver. Neither is built now (section 3.3).

## 2. Programming, keypads and Composer: the options

| Surface | What it gives | What it costs | Status |
| --- | --- | --- | --- |
| **Programming commands** `Breeze On`, `Breeze Off`, `Toggle Breeze`, `Set Breeze Strength` (param `Strength`, LIST `1`, `2`, `3`) | Every dealer and every surface (keypad double taps, schedules, scenes, voice routines, the companion) has one path; the companion and a later Extras page call the same code | `<commands>` in `driver.xml`; forever once released (never removed or renamed); no reboot | VERIFIED: BE9, BE11 |
| **Variable** `Breeze` (BOOL, read-only, added second, after `Online`) | "If" tests, variable watches, and another driver can listen to it (`C4:RegisterVariableListener`, API `36_variable/_10-RegisterVariableListener.md`) | Added in `OnDriverInit` on every device, with or without Breeze, so its number is the same everywhere; never reordered | VERIFIED: BE9, BE10 |
| **Events** `Breeze Started` (id 4), `Breeze Stopped` (id 5); 3 stays reserved | "When" lines, notifications (rank 6) | Ids fixed forever; no reboot | VERIFIED: BE9 |
| **Condition** `BOOL_BREEZE` (id 1): "Breeze is on", True/False | If and While lines | As `BOOL_ONLINE`; that BOOL passes the picked text in `VALUE` is the same ASSUMED as V1D 2.7 | VERIFIED-doc |
| **Button Link** 311 "Fan Breeze Button Link": a push toggles Breeze, its LED lit while Breeze blows | A keypad button with an LED that follows Breeze from any source | One connection (add-only, no reboot, BE11); `Keypad Links` counts 13 | VERIFIED pattern (BE12) |
| A Composer **action** "Toggle Breeze" | A test click in Composer | Actions are for setting up, not for using the fan (BE10); the owner said Navigators matter more than Composer | not built |
| A Composer **property** `Breeze Strength` | A strength picker in Composer | A row that writes the fan's live state would be rewritten by the app's changes, unlike every other row; the command does it | not built |
| **Status** and **Fan Model** texts | Already there: ` Breeze` in Status when `wind` is true, `, Breeze` in Fan Model when the fan has it | Lua only | Kept; Status gains the strength (` Breeze 2`) and, while the fan is off with `wind` true, ` Breeze set` (only if BR3 shows the fan keeps it) |
| An **action** "Add Breeze Switch" (sort order 7) | Adds the companion (rank 1) | An action, as the Hue bridge's Add Light (a setup step any dealer uses, so not one-off tooling) | VERIFIED pattern (BE6) |

## 3. Recommended design

"Breeze blows" below means: the fan reports `wind` true **and** `fanOn`
true. That one value drives the variable, the events, the condition, the
link's LED and the companion's tile. While the fan is off with `wind` still
true (BR3), Breeze does not blow, so all of them say off; `Status` says
` Breeze set`. Reason: a tile or LED lit over a fan that is standing still
misleads, and the fan proves it when it starts (BC8).

### 3.1 The fan driver (`modernforms_fan.c4z`): update in place, no reboot

| Piece | What | On the house |
| --- | --- | --- |
| State | A fourth command group `breeze` (`wind`, `wind_speed`) after fan and direction, as BRR 4.1 lays out; the one-group-per-request rule gives "fan on at the preset, then `{"wind":true}`" for Breeze from off (BC9); `wire.body` accepts only `{"wind":bool}`, `{"windSpeed":1-3}` and both; refused while `has_wind` is not true | Lua |
| Gusts | BRR section 5 item 1: while the confirmed `wind` is true, a read's change of `fanSpeed` alone is not told, opens no fast window and is not "outside" (BC23) | Lua |
| Attribution | BRR section 5 items 2 and 3: a command's answer is "command" for every group it changed (a Breeze command that moves the direction or starts the fan) | Lua |
| Commands | `Breeze On`, `Breeze Off`, `Toggle Breeze`, `Set Breeze Strength` (section 2); a refusal writes Last Action (section 4, texts) | XML and Lua; programming sees them after the update (BN1) |
| Variable, events, condition | `Breeze` (second), `Breeze Started` 4, `Breeze Stopped` 5, `BOOL_BREEZE` 1; the variable seeded at `OnDriverInit` from a new persisted `mf_breeze`, as `Online` is from `mf_online` | XML and Lua |
| Link | 311 "Fan Breeze Button Link", handled like 307 (push acts; click only without a push in 10 s; release nothing); LED from the shown value (wanted over in flight over confirmed, V10) | A new connection, no reboot; nothing bound (no free button) |
| Companion side | A provider control binding for the companion (proposal: id 400, class `MODERNFORMS_BREEZE`); the action **Add Breeze Switch** (sort order 7); messages to and from the companion with `C4:SendToDevice` | A new connection and action, no reboot |
| Texts | Status ` Breeze 2` / ` Breeze set`; Last Action lines of section 4; `Keypad Links` "of 13 links bound" | Lua |
| Manual | Chapters 4 (Breeze), 5 (the link), 10 (commands, variable, events, condition, the action), 13 (limits), and a new short chapter on the Breeze switch | — |

### 3.2 The companion (`modernforms_breeze.c4z`): a new package

| Piece | What |
| --- | --- |
| Proxy | One `light_v2`, named "Modern Forms Breeze" by default; `dimmer` False, `on_off` True, `reduced_als_support` False, `has_leds` False, no Button Links of its own (keypads use 311 on the fan); its own icons (V24: decided at creation) |
| Binding | A consumer control binding (id 1, class `MODERNFORMS_BREEZE`) to the fan device's 400, made by Add Breeze Switch with `C4:Bind`, or by hand in Connections |
| Tile | ON, TOGGLE from off, or any level above 0 → the fan's Breeze On; OFF → Breeze Off; it reports `LIGHT_BRIGHTNESS_CHANGED` 100 while Breeze blows, 0 otherwise, only on a change the fan confirmed (R1, R4); `ONLINE_CHANGED` false while unbound, while the fan device is not online, or while the fan has no Breeze |
| Rows | `Driver Version`, `Status` ("Breeze on Aviator 5", "Not connected to a Modern Forms Fan", …), `Debug Mode`; no actions |
| Name | Given once by Add Breeze Switch: the fan item's name plus " Breeze" (cut to fit); never renamed by either driver afterwards (as V28) |
| Later, free | `dimmer` is dynamic (BE7): a strength slider (1 to 3 as 33, 67, 100 %) can come later as Lua, if the owner wants strength on the tile |

### 3.3 Not built now, and why

- **The Experience button (rank 2):** possible later as its own package if
  the owner wants Breeze in Comfort rather than among the lights.
- **Extras on the fan's light (rank 3):** a second Navigator path to the
  same thing, behind a press and hold, absent without a light kit, and its
  XML is not in Snap One's docs. Lua-only, so it can come later.
- **History entries (rank 5):** waits for the probe U11 asks for.
- **A `Breeze Strength` variable or event:** the strength is a setting, not
  a state programming waits for; a variable can be added later at the end of
  the order (BE9).
- **A Composer action or property for Breeze:** section 2.

### 3.4 What the house needs

1. The release carries two packages; the Windows session installs both in
   place through "Add or Update Driver or Agent…" (standing approval). No
   `<capabilities>` of the existing device change, so no reboot. The brief
   reads back the fan's `Driver Version` and the new rows.
2. The Windows session clicks **Add Breeze Switch** on the fan item; Last
   Action names the new item; it checks Connections (the binding on 400).
3. File ▸ Refresh Navigators (the Windows session).
4. The owner glances at the phone and one touchscreen: the switch, its
   state, one tap each way (BN3, under a minute).
5. Nothing is re-created, no keypad is rebound, no programming changes.

## 4. Edge cases

Texts are proposals; the contract numbers them (L33 and on). "Variable,
events, LED, tile" means the `Breeze` variable, Breeze Started or Stopped,
link 311's LED and the companion's tile, which always move together.

| ID | Case | What each side sees | Decision | Text | Sources |
| --- | --- | --- | --- | --- | --- |
| BC1 | Breeze turned on in the Modern Forms app (home Wi-Fi or cloud) | Fan: `wind` true, `userData` `local_wifi` or `cloud`. Driver: at the next poll (15 s, or 2 s in the fast window) | **A** report: variable 1, Breeze Started once, condition true, LED lit, tile on, Status. **F** turning it back off (rule 5: a change made at the fan is shown, never undone) | Last Change By `Modern Forms app or another local client at 14:05` | ECC rule 5, R1; V1D 7.3; BRR 2 |
| BC2 | Breeze from the remote or the wall control (Bluetooth models: fan and reverse held 4 s) | Fan: `wind` true, `userData` probably `ble` | **A** as BC1 | `Remote or wall control at 14:05` (if BR7 shows `ble`) | BRR 2 (MF-RCBT, MF-WCBT); BR7 |
| BC3 | Breeze turned off outside Control4 | `wind` false | **A** variable 0, Breeze Stopped once, LED dark, tile off | Last Change By as BC1 | R1 |
| BC4 | Strength changed outside (`windSpeed` 2 → 3) | `windSpeed` | **A** Status only; no event, no variable change | Status `… speed 3 Breeze 3, …` | section 3.3 |
| BC5 | Speed changed in the app while Breeze blows | `fanSpeed`, `wind` as the fan says | **A** both reported as the fan reports them | — | R1, BRR 2 |
| BC6 | A Control4 speed (Navigator, Speed link, `SET_SPEED`, Cycle) while Breeze blows | The driver sends `fanOn`/`fanSpeed` only | **A** report what the answer shows: Breeze goes on or ends as the fan decides (BR4); an answer showing `wind` false fires Breeze Stopped. **F** adding `{"wind":false}` to the speed, or re-sending `{"wind":true}` after it | Manual: "A speed change keeps Breeze if the fan does" | BRR 5 item 4; V8 |
| BC7 | Off, Toggle off, the Fan Off link while Breeze blows | `{"fanOn":false}` only | **A** variable 0, Breeze Stopped, LED dark, tile off (the fan stopped blowing). **F** clearing `wind` with it: what the next start does is the fan's memory, as with the remote (BR3) | Status `fan off Breeze set` if `wind` stays true | ECC rule 5; BRR 5 item 5 |
| BC8 | The fan started (ON, Toggle, a speed, the app) while `wind` is still set | The fan may resume Breeze (BR3) | **A** reported: Breeze Started fires if the answer shows it; a speed LED and the Breeze LED may both be lit | Manual says so | BRR 5 item 5 |
| BC9 | **Breeze On** (command, link, tile) while the fan is off | — | **A** turn the fan on at the preset speed, then `{"wind":true}` (two requests, fan first; one body only if BR2 shows `wind` alone starts the fan and the contract prefers it). A tap on a "Breeze" tile means "make a breeze"; refusing would leave a dead tile | — | V11 (the preset); BRR 4; BR2 |
| BC10 | Breeze On while Breeze already blows; Breeze Off while it does not | Nothing changes at the fan | **A** sent anyway (V8: Control4's commands are always sent); no event (no change) | — | V8; R1 |
| BC11 | **Toggle Breeze** and the 311 link | — | **A** from the shown value: blowing → Breeze Off; anything else (off, fan off, `wind` set while off) → Breeze On (BC9) | — | V10; V1D 4.6 (Toggle reads the shown state) |
| BC12 | Several taps, presses or commands in a burst | — | **A** latest wins, one request in flight, the LED and tile show the target at once and are corrected on the answer | — | R5; V10; ECC C13 |
| BC13 | A double tap on a button bound to 311 | Two pushes (K6) | **A** two toggles, so Breeze ends where it started, as on Fan Toggle (307) today; the manual says so | — | V12; K6 |
| BC14 | **Set Breeze Strength** while Breeze is off, or the fan is off | `{"windSpeed":N}` | **A** sent alone; what it does is BR5 (if it also starts Breeze, the answer says so and BC1's reports follow as "command"). N outside 1 to 3: refused | `Breeze strength 5 refused: use 1, 2 or 3` | BRR 4; BR5 |
| BC15 | A fan without Breeze hardware (Gen 3, no `wind` key) | No `wind` in any answer | **F** sending `wind` or `windSpeed` (AIO drops them too). Commands refused with Last Action; the 311 press refused, its LED dark; variable 0, condition false, no event; Add Breeze Switch refused; a companion bound anyway shows offline. The commands stay listed (XML is the same for every device; no API was found that hides a driver command per device [assumed]) | `Breeze not available: this fan reports no Breeze`; `No Breeze switch added: this fan reports no Breeze` | BRR 1 (capability); BE9 |
| BC16 | Gen 1/2 fans | No `wind` key, ever | **F** as BC15 | as BC15 | BRR 1 |
| BC17 | A command before the first answer after a restart | `has_wind` restored from `mf_wind` | **A** held until the contact's identity check, as every command (V5), then sent or refused by BC15 | — | V1D 6.1 (waiting) |
| BC18 | Breeze hardware gone: another fan picked (Use Selected Fan), a firmware or model change | `mf_wind` false on a re-point (#69); a new answer without `wind` | **A** variable 0 and Breeze Stopped once if it was 1 (what the device does changed); the companion goes offline | — | V1D 8 (`mf_wind`); ECM H3 |
| BC19 | Gen 4, a foreign fan, not a fan, no address, rebooting | — | **F** as every command (V4, V1D 6.1); the link press refused, LED unchanged; the companion offline (unset, foreign, Gen 4, not a fan) or unchanged (rebooting) | `Breeze not sent: no fan of this device answers at 10.0.2.151` | V1D 5.1, 6.1 |
| BC20 | The fan offline (a wall switch cut, Wi-Fi gone) | Three failed polls | **A** a Breeze command is tried once and dropped (P8); the variable keeps its last value (R7: no change reported for offline); no event; the tile goes grey (`ONLINE_CHANGED` false) as the fan's light does; LEDs keep their state | — | V13; ECC R7, P3; ECM P8 |
| BC21 | Back online | The contact reads the state | **A** a change made meanwhile is reported once, with its event (R8); nothing re-sent | — | ECC R8; V1D 6.3 |
| BC22 | Driver restart, Director restart, an update, a controller reboot | The variable is created again | **A** seeded from `mf_breeze` so a restart alone changes nothing (as D9 for `Online`); at the first contact a difference fires its event once (ECC P2); the LED and the tile wait for the first contact, a newly bound link is told dark (ECC C14) | — | ECC P2, C14, D9 |
| BC23 | **Gusts move `fanSpeed`** (BR1) | Each poll sees another speed | **F** reporting gust speeds: no `CURRENT_SPEED`, no speed events, no speed-LED flicker, no fast window, no "outside", while the confirmed `wind` is true (BRR 5 item 1, whatever BR1 shows); the speed is told again when Breeze ends. **A** a speed changed by Control4 during Breeze is still sent and reported from its own answer | — | BRR 5 item 1; ECC R1, R3 |
| BC24 | A programming loop: "When Breeze Started → Breeze Off" and "When Breeze Stopped → Breeze On" | Each event fires only after the fan confirms | **A** no guard in the driver, as for speed and light (ECC P4): one request at a time, 250 ms apart, so the loop runs at the fan's pace; the manual warns. **F** muting the events for Control4's own commands: programming hears every change, as it does from the proxies. The link's LED and the tile fire no driver event (MATCH_LED_STATE fires no programming); the companion's own light events do fire, and the same warning covers them | Manual, chapter 4 | ECC P4; V10 |
| BC25 | Programming tries to write the `Breeze` variable | — | **F** the variable is read-only; the commands are the way to switch | — | API `36_variable/_1-AddVariable.md` |
| BC26 | A later update on a project whose programming uses the commands, the variable, the events or the condition | — | **F** removing, renaming or retyping any of them, or adding a variable before `Breeze`; `Breeze` is added on every device, Breeze or not. A rollback to 1.1 leaves those lines pointing at nothing; the release notes say so | Release notes | BE9; ECC F2, F24 |
| BC27 | Binding and unbinding 311; a keypad on Follow Connection | `OnBindingChanged`; `REQUEST_BUTTON_COLORS` | **A** as 300 to 308: `Keypad Links` updated, the LED answered at once, the keypad's own colours (no `BUTTON_COLORS`, as Off, Toggle and Cycle) | `Fan Breeze: Example Keypad (456)` | V1D 5.1, 5.3 |
| BC28 | **Add Breeze Switch** clicked | — | **O** only on the click: `C4:AddDevice` into the fan item's room, named after it, then `C4:Bind` on 400. Refused without a pin, without Breeze, or while a switch is already bound. **F** adding one at load, at an update, at the first contact or because Breeze was seen | `Breeze switch added: Aviator 5 Breeze`; `A Breeze switch is already connected: Aviator 5 Breeze` | BE6; API `9_helper/_0.1-AddDevice.md` |
| BC29 | The companion deleted, or unbound in Connections | `OnBindingChanged` false on 400 | **A** forget it; a new click adds another. The fan driver never deletes or rebinds it | — | ECC rule 1 |
| BC30 | The fan device deleted, or the companion bound to nothing | Its binding empty | **A** the tile offline; its Status `Not connected to a Modern Forms Fan`; a tap refused. **O** bind it again in Connections | as left | BE7 |
| BC31 | Two companions on one fan (one added, one bound by hand) | One provider, two consumers | **A** both work and show the same state | — | HUE (one provider, many consumers) |
| BC32 | The companion renamed or moved to another room | — | **A** kept; **F** either driver renaming it later | — | V28; ECC U6 |
| BC33 | The companion in "all lights off" groups, lighting scenes, a voice assistant's lights | An ordinary switch | **A** off ends Breeze, the fan keeps turning; on starts the fan (BC9). It cannot join an Advanced Lighting Scene (BE7). The manual: keep it out of "all on" groups | Manual | BE7; [assumed: how each assistant groups it] |
| BC34 | The switch does not appear on a Navigator | Navigators cache the project | **A** the install brief ends with File ▸ Refresh Navigators | — | HUE ("Scene dimmer, build 160"); ECC U7 |
| BC35 | Project restore onto the same or a new controller | Bindings and devices come back with the project | **A** the state is sent again at the first contact; [assumed: the binding on 400 survives, as the Hue drivers' do] | — | V1D 8; ECC D10 |
| BC36 | The fan tile during Breeze | `fanSpeed` the fan reports (the base speed, if BC23's rule holds) | **A** the tile keeps the base speed and direction the fan reports; Breeze is shown by the switch, not by the fan tile (BE1) | — | BE1 |

## 5. Checks on the house (each under a minute)

The fan-side checks BR1 to BR5 (BRR section 6) come first: they settle
BC6 to BC9, BC14 and BC23 before the contract freezes. Then, after the
install:

| # | What | Who | Settles |
| --- | --- | --- | --- |
| BN1 | Programming, read only: the fan item lists the four Breeze commands with the `Strength` list, the events Breeze Started and Breeze Stopped, the condition "Breeze is on" and the variable `Breeze` | Windows session | BE11, BC26 |
| BN2 | Add Breeze Switch: Last Action, the new item in the fan's room, the binding on 400 in Connections; Refresh Navigators | Windows session | BC28, BC34 |
| BN3 | The switch on the owner's phone and one touchscreen: its state, a tap on (Breeze starts, Status follows), a tap off | the owner's eyes, once | rank 1, BC9 |
| BN4 | Where the switch and the fan are listed (the room's Navigator settings in Composer: Lights, Comfort) | Windows session, read only | BC33 |
| BN5 | One If line on "Breeze is on" in a throw-away script, then deleted | Windows session | BOOL `VALUE` (as V1D 2.7's ASSUMED) |

Parked under "no long test waits": gust behaviour over minutes (BRR 6), an
OS 4.x controller, and every assistant's grouping of the switch.

## 6. Decisions for the contract

1. The meaning of "Breeze blows" (`wind` and `fanOn`) for the variable,
   events, condition, LED and tile; Status keeps the raw flag.
2. The command names and the `Strength` list; their descriptions in
   Programming; sort orders 0 to 3.
3. Event ids 4 and 5 (3 stays reserved), condition id 1, variable order 2,
   persisted key `mf_breeze`.
4. Link 311; the companion binding (id 400 proposed) and its class; the
   action "Add Breeze Switch" at sort order 7.
5. Breeze On from off: two requests or one body (BR2).
6. The gust rule (BC23) and the "command" attribution (BRR 5 items 2 and 3).
7. The companion's messages (state, availability, online; on, off, toggle)
   and its texts.
8. The Last Action texts of section 4 and the Status additions.
9. Tooling: `tools/build.sh` already builds one package per
   `src/*/driver.xml`; the release, `deploy.py` and the brief carry two
   packages and count the new device.

## 7. Questions for the owner

None. The one judgement call, where the Breeze switch lives, is decided
here: among the room's lights (rank 1), because that is where a tile is
seen at a glance and the pattern is proven on this house. If the owner
would rather have it in Comfort, rank 2 is the same companion with another
proxy and can follow without touching the fan device.
