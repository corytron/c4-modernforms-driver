# Control4-side edge cases: the Modern Forms fan driver

> Research for the v1 design ([issue #2](https://github.com/corytron/c4-modernforms-driver/issues/2)),
> 2026-10-27, read-only. This document covers what Director, Composer, the
> fan, `light_v2` and keypad proxies, Control4 programming and the Navigators
> do around the driver over the life of the system, and the migration from
> the stock driver. The fan side (the fan's own lifecycle: reset, firmware,
> new address, its app and remote) is `docs/edge-cases-modernforms.md`,
> written in parallel. Every "Decision" here is a proposal: the v1 contract
> and its migration part decide, and §8 lists what needs the owner.

The owner's rule: before anything acts on its own, every lifecycle corner
case gets a decision. **A** = automatic (the driver does it by itself).
**O** = offered (one click: an action, or a property the owner sets in
Composer). **F** = forbidden without a click (some rows: never). Automation
that makes a later manual fix harder is wrong, and Control4 is the source of
truth.

## Sources and markers

- **[verified: …]** names a primary source:
  - `API`, `FUND`, `XML`, `FAN`, `KPD`, `LV2` are Snap One's DriverWorks
    references under `~/c4-tools/reference/`, in this order:
    `docs-driverworks-api/source/includes/`,
    `docs-driverworks-fundamentals/source/includes/`,
    `docs-driverworks-xml/source/includes/`,
    `docs-driverworks-proxyprotocol-fan/source/includes/`,
    `docs-driverworks-proxyprotocol-keypad/source/includes/`,
    `docs-driverworks-proxyprotocol-lightv2/source/includes/`. The folder
    and file follow the abbreviation. The text is paraphrased, never quoted
    (Snap One's terms).
  - `HUE <file>, "<section>"` is a measurement on this house with the Hue
    drivers (OS 3.4.2, later 3.4.3; Composer Pro 3.4.2), recorded under
    `docs/` in [corytron/c4-hue-driver](https://github.com/corytron/c4-hue-driver).
  - [`status.md`](status.md) and [`design.md`](design.md) hold this
    repository's measurement of the stock driver (2026-10-27).
- **[practice: TPL]** is Snap One's public template code,
  `snap-one/drivers-template-code-public`, branch `release`, folder
  `proxies/fan_proxy/`, read 2026-10-27. **[practice: community]** is the
  public fan drivers `finitelabs/control4-esphome` (`drivers/esphome_fan`),
  `michelo76/control4-smartbuildos` (`drivers/bond-fan`) and
  `bphillips09/Control4-HA-Fan`, read 2026-10-27 (AGPL). Both say how
  drivers behave in the field, not what Director guarantees; behaviour is
  noted, nothing is copied.
- **[assumed]** is our reading, to be probed (§7). **[silent]** means the
  docs say nothing; the case is listed so it is tested, not guessed.

Vocabulary: *protocol device* = the driver's Lua device; *fan proxy* and
*light proxy* = the two proxy devices Composer shows; *link* = a
`BUTTON_LINK` connection; *stock device* = a device running
`wac_mf_fan_and_light_controller(v4).c4z`; *identity* = the fan's own id
(its MAC or client id; the fan-side document picks which); *WS* = the
Windows Composer session.

## 0. The facts everything below rests on

| # | Fact | Source |
| --- | --- | --- |
| F1 | A driver's proxies are created only when a device is added. Adding, removing or retyping a `<proxy>` in an update leaves updated devices corrupt; a different proxy set needs a new driver file. | [verified: FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`] |
| F2 | In an update, connections may only be added, never removed or redefined; events and commands must not be removed (or event ids changed); variables must not be removed, renamed, retyped or renumbered; properties may come and go but should not be retyped. | [verified: same file] |
| F3 | A multi-proxy driver lists each proxy with its own `proxybindingid`; one proxy device per proxy appears when the driver is added; a proxy's `name` attribute is its default device name; a `<connection>` can name the proxy it belongs to with a `proxybindingid` attribute. | [verified: FUND `8_proxies_and_proxy_types/_1-SINGLEANDMULTIPROXIES.md`, `_2-MODIFYINGTHEDEFAULTNAMINGOFPROXIES.md`; FUND `11_connections/_5-PROXYBINDINGMULTIPLE.md`, `_1-OVERVIEW.md`] |
| F4 | `<replaces>`: once the new driver loads, Director removes the named driver from the project without warning, removes its file from Composer's local store and marks it obsolete. | [verified: XML `15_common_xml/_33.5-replaces.md`] |
| F5 | `SINGLETON_ID` lets a driver be loaded only once per project. | [verified: XML `15_common_xml/_72-singletonid.md`] |
| F6 | Fan proxy commands: ON (to the preset, or the last speed: the driver's choice), OFF, TOGGLE, SET_SPEED (0 = off), CYCLE_SPEED_UP and DOWN (wrap or stop: the driver's choice), DESIGNATE_PRESET, SET_DIRECTION, TOGGLE_DIRECTION. Notifications: CURRENT_SPEED (0 when off), DIRECTION, PRESET_SPEED, ON, OFF; on ON the proxy assumes the fan went to its preset speed. | [verified: FAN `41_fan_proxy_commands/`, `42_fan_protocol_notifications/_1-CURRENTSPEED.md`, `_4-ON.md`] |
| F7 | The fan proxy fires turned_on, turned_off, speed_changed (also on every on and off) and direction_changed; its variables Is On, Current Selected Speed, Is Reversed and Current Preset are read/write; its conditionals are Is On, Is Off, Current Speed equal or not, Is Reversed. | [verified: FAN `45_fan_events/_1-FANEVENTS.md`, `46_fan_variables/_1-FANVARIABLES.md`, `44_fan_conditionals/`] |
| F8 | Fan capabilities: `discrete_levels`, `speed_names` (defaults by count; more than five speeds default to numbered levels), `preset_speed` (default: the highest speed), `can_set_preset`, `can_reverse`, and `proxy_fan_speed_connections`, with which the proxy creates per-speed links from `discrete_levels` and `speed_names`, from OS 3.4.2 (the fan reference's own 3.4.2 "What's New" page lists no change; the docs disagree). No fan capability is documented as dynamic; the fan proxy documents no DYNAMIC_CAPABILITIES_CHANGED and no ONLINE_CHANGED. | [verified: FAN `43_fan_capabilities/` (all six), `3_whats_new/_7-WhatsNewin342.md`] [silent: the rest of FAN] |
| F9 | The proxy answers GET_SETUP for user interfaces (speed count and names, reverse, preset) from those capabilities. | [verified: FAN `41_fan_proxy_commands/_12-GETSETUP.md`] |
| F10 | `light_v2` ONLINE_CHANGED: the proxy starts online, and offline disables its UI. LIGHT_BRIGHTNESS_CHANGED belongs at driver start and when the hardware comes back. On the house a decimal brightness left the proxy at 0; whole percents work. | [verified: LV2 `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/_15-ONLINECHANGED.md`, `_10.2-LIGHTBRIGHTNESSCHANGED.md`; HUE `design.md`, "Lights: verified on hardware"] |
| F11 | The light's events (Light On 5100, Light Off 5101, Brightness Changed 4001, …) and variables (Light State 1000, Brightness Percent 1001, …) are the proxy's. | [verified: LV2 `25_light_v2_events/_0-HEADER.md`, `30_Light_v2_variables/_0-HEADER.md`] |
| F12 | `hide_proxy_properties`, `has_leds`, `has_button_events` and `reduced_als_support` are static capabilities on OS 3; the `hide_proxy_*` ones become dynamic only in 4.2.1. | [verified: LV2 `5_light_v2_capabilities/_38-HIDEPROXYPROPERTIES.md`, `_28-HASLEDS.md`, `_26-HASBUTTONEVENTS.md`, `22-REDUCEDALSSUPPORT.md`; LV2 `3_whats_new/_6-WhatsNewin421.md`] |
| F13 | On this house the `light_v2` proxy itself creates only its Brightness Stop and Color Stop links. Top, Bottom and Toggle are provider links the driver declares (ids 200 to 202 on the Hue Light), and a bound keypad button sends DO_PUSH, DO_RELEASE and DO_CLICK on them. Links added in an update reached existing devices at once. | [verified: HUE `keypad-design.md`, "Hardware findings"] |
| F14 | Over a link a keypad button sends DO_PUSH, then DO_CLICK (not held) or DO_RELEASE (after a hold); REQUEST_BUTTON_COLORS asks the load for BUTTON_COLORS and MATCH_LED_STATE. Control4 advises acting on the press when click and hold mean the same. Multi-tap over links is newer and older drivers ignore it. A short press can look like a long hold to the driver. | [verified: KPD `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`] |
| F15 | `MATCH_LED_STATE {STATE}` sent as a COMMAND on the driver's links lit Follow Connection buttons on the house; BUTTON_INFO and BUTTON_COLORS carry the colours. | [verified: HUE `keypad-design.md`, "Keypad LEDs" (on hardware 2026-10-24)] |
| F16 | Binding a keypad button's link in Composer switches the button's LED Behavior to Follow Connection; disconnecting does not switch it back. LED Behavior offers Follow Connection, Follow Load, Push/Release, Programmed; Button Behavior offers Load On, Load Off, Toggle Load, Keypad. | [verified: HUE `composer-remote.md`, "Learned 2026-10-27"] |
| F17 | WS binds by dragging the consumer's own row in Connections' top pane onto the lower list; writes Script lines by drag (nested only when dropped on an If's "?" icon); a Script line's menu has Disable Event, Disable Item, Copy All (XML), Paste, Find and Replace and Delete. Disconnect names the two devices, not the connection. | [verified: same section] |
| F18 | A keypad proxy takes KEYPAD_BUTTON_ACTION, which makes it act as if a button were used; its protocol reports CLICK_COUNT, from which it fires single, double and triple tap events. | [verified: KPD `60_keypad_proxy_commands/_4-KEYPADBUTTONACTION.md`, `61_keypad_protocol_notifications/_2-CLICKCOUNT.md`] |
| F19 | `C4:GetAllCodeItems()` and `C4:GetCodeItems(device, event)` (3.3.0+) return the project's programming as tables: per event its device id and event id, and nested items with their type (command, condition, loop, …), target device, enabled flag, display text and command XML. No API writes, disables or deletes programming. | [verified: API `9_helper/_5.5-GETALLCODEITEMS.md`, `_5.9-GETCODEITEMS.md`, `3_whats_new/_13-WhatsNewin330.md`; sweep of API] |
| F20 | `C4:GetDevices({C4iNames=…})` lists every device of a driver file with names, rooms and proxies (on the house the filters are comma-separated strings). `GetBindingsByDevice(proxy)` (3.0.0+) returns a device's bindings; `GetBoundConsumerDevices` lists a provider binding's consumers (nil for none); `GetDeviceVariable` reads another device's variable; a `DEVICE_SELECTOR` property lets the owner pick devices of given drivers. | [verified: API `22_miscellaneous/_9-GetDevices.md`, `32_serial_network_device/_2.5-GetBindingsByDevice.md`, `_3-GetBoundConsumerDevices.md`, `36_variable/_5-GetDeviceVariable.md`; FUND `15_composerpro_interface_into_the_sdk/_3.1-DEVICESELECTOR.md`; HUE `design.md`, "Project APIs"] |
| F21 | `C4:Bind` and `C4:Unbind` (2.9.0) do what Connections does; `C4:AddDevice` is for user-initiated use only; no API deletes or moves a device. | [verified: API `9_helper/_1-bind.md`, `_19-unbind.md`, `_0.1-AddDevice.md`; HUE `edge-cases-ux.md`, "Facts the policy rests on"] |
| F22 | `OnBindingChanged(id, class, bound, otherDevice, otherBinding)` comes for control bindings, not AV or room bindings; on the house it reached the provider in the millisecond a `C4:Bind` made the binding. Whether it comes at Director start for existing bindings is undocumented. `OnBindingValidate` can refuse a binding. | [verified: API `9_helper/_12-OnBindingChanged.md`, `32_serial_network_device/_26-OnBindingValidate.md`; HUE `design.md`, "Project APIs"] [silent: start] |
| F23 | Project load runs every OnDriverInit, then every OnDriverLateInit (`DIT_ADDING`, `DIT_STARTUP`, `DIT_UPDATING`, 3.2.0+); OnDriverDestroyed gets `DIT_UPDATING` or `DIT_LOADED`, and timers die; OnDriverRemovedFromProject comes on a delete. FireEvent, SetVariable, SendToProxy, UpdateProperty and URL calls belong after late init; AddVariable belongs in OnDriverInit, or programming on the variable may fail after a restart. | [verified: FUND `28_api_specific_info/_2-DRIVERINIT.md`, `_3-DRIVERINIANDDESTRUCT.md`; API `22_miscellaneous/_24-OnDriverDestroyed.md`, `_26-OnDriverRemovedFromProject.md`] |
| F24 | Programming names variables by an id allocated in AddVariable order: never reorder, or delete and re-add. Events have fixed ids, at most 1000 per driver, and XML events are never deleted at run time. | [verified: API `36_variable/_1-AddVariable.md`, `7_event/_2-DeleteEvent.md`; XML `40_events_xml/_1-INTRODUCTION.md`] |
| F25 | PersistSetValue writes to Director's state database (its thread starts just before late init). The PersistData table and properties are saved in the project and its backups and survive updates; sandbox database files are not backed up. Persisted data is per device id: an update keeps it, a delete and re-add loses it. | [verified: API `26.5_persistence/_4-PersistSetValue.md`; FUND `24_persisting_driver_data/_1-PERSISTINGDRIVERDATA.md`, `3_what's_new/_17-WHATWASNEWIN313.md`; HUE `design.md`, "Storage"] |
| F26 | Driver ▸ "Add or Update Driver or Agent…" moves every device of the driver to the new version at once. Lua and connection changes take effect at once; a capability change makes Composer ask "Restart Director?", Yes does not load it, and devices keep the old capabilities until the owner reboots the controller from System Manager (WS cannot; about 7.5 minutes back to idle). | [verified: HUE `design.md`, "Composer Pro 3.4.2 UI" and "Keypad and scene dimmer: verified on hardware"; HUE `composer-remote.md`, rules 9 and 10] |
| F27 | An update that moves the script between PUC Lua and LuaJIT loses properties and state for a while. | [verified: FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`] |
| F28 | A proxy device's tree icon is decided at creation: a device created under a build without a custom icon keeps the default for good. | [verified: HUE `design.md`, "Composer Pro 3.4.2 UI" (builds 125 and 135)] |
| F29 | Composer clips a property value on screen at about 75 characters; an edit reaches Director only through the row's Set button; the mouse wheel steps a drop-down under the pointer; without `sort_order` the Actions tab lists actions in reverse. | [verified: HUE `design.md`, "Composer Pro 3.4.2 UI" and "import-ui: verified on hardware"; HUE `composer-remote.md`, rules 7 and 17] |
| F30 | Director runs at most four `C4:url` transfers at once, across all hosts, and the Hue bridge driver can hold two of them for its event stream. | [verified: HUE `design.md`, "Concurrent transfers"] [assumed: one budget per Director, not per driver] |
| F31 | Snap One's fan template handles no link traffic; it sends ON or OFF when the power flips and CURRENT_SPEED on every report; DESIGNATE_PRESET carries `PRESET`, SET_DIRECTION and the DIRECTION notification carry `DIRECTION`. No public driver on GitHub uses `proxy_fan_speed_connections` (code search, 2026-10-27). The community fan drivers declare their own links (ids 300 to 305, or 200 to 202); the two whose Lua was read act on DO_CLICK; one sends ONLINE_CHANGED to its fan proxy; one lights only its Toggle link; one builds a driver file per speed count and per reversibility, since `discrete_levels` is static. | [practice: TPL `fan_device_class.lua`, `fan_proxy_notifies.lua`; practice: community] |
| F32 | Control4's automatic driver update works only for drivers in its online driver database. | [verified: FUND `14_updating_released_drivers/_1-UPDATINGRELEASEDDRIVERS.md`] |
| F33 | OS 4.0 adds `GetBoundPartner`, `GetCapabilityById` and `GetProtocolDeviceById` to help replace devices and move settings; 4.1 adds dynamic commands and conditionals and `GetRoomID`; LuaSocket is being retired. None exists on the house's 3.4.3, and none writes programming. | [verified: API `3_whats_new/_7-WhatsNewin400.md`, `_6-WhatsNewin410.md`] |

## 1. Five rules behind the decisions

1. **The project is the owner's.** The driver may change its own properties,
   its persisted data and, when asked, the fan. It never adds, deletes,
   renames, moves, binds, unbinds or re-programs anything in the project by
   itself (F21: most of it has no API anyway). Reading the project (devices,
   bindings, programming; F19, F20) is always allowed, and is how the driver
   helps with everything it may not do.
2. **The Control4 device is the identity.** A fan that is replaced, reset
   or readdressed is re-pointed from the same device, so its links,
   programming and names stay. Deleting and re-adding is never the fix
   (F25).
3. **Reports are truthful, in order and quiet.** One proxy notification per
   real change; never an older state after a newer one; nothing the fan did
   not report; nothing fired at start-up or on reconnect that did not
   happen (§5.1). The stock driver's late, out-of-order reports are the
   reason the house needs a settle timer today ([`status.md`](status.md)).
4. **Disable before delete.** Nothing irreversible happens before the way
   back exists: the migration disables the old programming and keeps the
   stock device until the owner removes it.
5. **A change made at the fan is shown, never undone.** The remote, the
   wall control and the Modern Forms app change the fan; Control4 reports
   it and its programming may react, but the driver never reverts it by
   itself (the fan-side document covers the fan's own schedules).

## 2. Migration from the stock driver

### 2.1 Why a migration and not an update

- The stock driver and ours are different files with different proxies and
  connections. Moving a device from one to the other would change exactly
  what F1 and F2 forbid in an update, so the stock device can only be
  replaced by a new device.
- `<replaces>` is the tempting shortcut and the worst one: it deletes the
  stock device, unannounced, the moment our driver loads (F4), taking the
  rollback path with it. **F, never declared.**
- Nothing can carry programming across (F19 is read-only; F33 is 4.x-only
  and does not write programming either). The tools are therefore: the new
  device beside the old one, a read-only **Migration Report** from our
  driver (F19, F20), WS's Composer work (F16, F17), and the owner's hands
  only for a keypad press or a phone.

### 2.2 What names the stock device today, and who redoes it

| What | Where it lives | Seen by the Migration Report | Redone by | Basis |
| --- | --- | --- | --- | --- |
| Keypad speed scripts (Single Tap and Double Tap set speeds) | code items on the keypad's button events; their commands target the stock fan | yes (target device) | WS: disable, then the link, or a Double Tap line (Q3) | [verified: F19 fields] [assumed: keypad events are in the table] |
| LED lines in those scripts ("Use the on color for …") | the same scripts; they target the keypad only | as lines of a script that also names the stock fan | WS: disabled with the script, deleted in M8 | [assumed] |
| "Fan Speed Changed" on the stock device, restarting the timer | code items on the stock device's event | yes (event of the stock device) | WS: Disable Event, delete in M8 | [verified: F19 event ids] |
| The Timer agent's "Fan LED Settle" timer and its expiry script (12 Ifs on the stock fan's speed) | the Timer agent; its conditions name the stock fan | yes, through the conditions | WS: Disable Event, delete the timer in M8 | [assumed: a condition item carries its device] |
| Scheduler events, macros, voice scenes, other scripts that command or test the fan | code items under those agents | yes | WS: new lines by drag, or Find and Replace if it can swap devices (H9) | [assumed: agents' programming is in the table] |
| Variables the workaround may use | code items naming the Variables agent (device 100001) | as lines | WS | [verified: API `36_variable/_5-GetDeviceVariable.md`, the agent's id] |
| Keypad buttons bound to the stock links | bindings | yes (F20) | expected none: the links do nothing ([`status.md`](status.md)) | [measured: status.md] |
| Advanced Lighting Scenes holding the stock light | the Lighting agent's own data, not code items | no | WS in the agent's screens; the new light joins only with `reduced_als_support` (Q8) | [assumed] |
| Navigator favourites, per-room visibility | Navigator and room settings | no | favourites: the owner's phone; visibility: WS | [assumed] |
| Voice assistants' device lists and routines | the assistant's cloud | no | the owner's phone, after M6 | [assumed] |
| The names the family uses | device names | no | M6 | — |

What Composer does with programming that names a deleted device is
[silent]. The migration never relies on it: everything is disabled first and
deleted explicitly before the device (M8). Lines that only target the keypad
(the LED lines) would survive the stock device's deletion and keep painting
LEDs, which is why they are removed by name, not by the device delete.

### 2.3 Both drivers on one fan

| Overlap | What happens | Decision |
| --- | --- | --- |
| Two drivers polling one fan | twice the requests; slower answers for both [assumed; fan side] | keep the overlap short. After the cutover WS may *disarm* the stock device by pointing its address property at nothing (O, undone by restoring the value) [assumed: the stock driver has such a property; H1's T1 reads it] |
| Two tiles for one fan | each follows the fan at its own pace; confusing for the family | the new proxies are named "(new)" until M6; WS can hide the stock proxies from the Navigators during the soak (O) [assumed] |
| The stock programming fires on changes the new device makes (the stock driver sees them, late) | the settle timer repaints LEDs from stale reports | harmless while the buttons are on Programmed. Once a button is linked, its LED lines are disabled in the same step, and the 12-If script when the last button moves. H6 says whether Programmed LED commands touch a Follow Connection button at all |
| A press runs the old script and the new link | two commands to one fan; speeds flap | per button, one step: disable its old lines, then bind its link (M4) |
| Double taps | the link may also see both taps (H4) | Q3 |
| The stock driver re-asserting a last state when it starts | the fan jumps after a restart [assumed: it does not; watch once] | ours never does (D9) |
| The stock driver updated by Control4's Driver Update Agent | it changes under the migration | only drivers in Control4's online database update that way (F32); WS reads the agent's list once in M0 |
| The URL budget shared with the Hue drivers (F30) | queued requests, late reports | the fan-side transport choice; H13 measures |

### 2.4 Decisions

| Case | A | O | F | Owner sees |
| --- | --- | --- | --- | --- |
| Find the stock devices | at each report run (`GetDevices` by the stock file name) | — | — | `Migration`: "Stock WAC devices: 1 (Example Room, device 123)" |
| Decide which stock device is this fan's | when its network binding's address equals our fan's (H10) | `Stock Device` (DEVICE_SELECTOR) | — | "Stock device: 123 (matched by address)" |
| List the programming that names it | — | action `Migration Report` (reads the whole project: never at start-up, never on a timer) | — | rows such as "Keypad ▸ button 2 Single Tap: set speed 2 (enabled)" |
| Track progress | the last report's counts persist and show after a restart | re-run the report | — | "14 items name the stock fan: 0 enabled, 14 disabled; safe to remove" |
| Disable, delete or rewrite programming | — | WS, per brief | the driver (no API; F19, F21) | — |
| Bind keypad links | — | WS drag | the driver's own `C4:Bind` of keypad buttons (Connections stays the one place they are made and read) | `Keypad Links`: "9 of 14 links bound" |
| Take over the stock device's settings | — | the stock address offered as the first `Fan` entry when H10 can read it | applying it without the click | — |
| Delete the stock device | — | WS in M8, only once the report says no enabled item names it | `<replaces>`, forever | — |

### 2.5 The stock links and their replacements

Nothing is bound to the stock links today, since they do nothing
([`status.md`](status.md)); the mapping guides the Connections work and the
manual. Whether the speed links are ours or the fan proxy's is Q1.

| Stock link | New link | A press does | LED lit while |
| --- | --- | --- | --- |
| Fan Off | Fan Off | OFF | the fan is off |
| Fan Speed 1 to 6 | Fan Speed 1 to 6 | SET_SPEED n | the speed is n |
| Toggle Preset | Fan Toggle | TOGGLE (ON per Q4) | the fan is on |
| Cycle Speed | Fan Speed Up, and a new Fan Speed Down | CYCLE_SPEED_UP or DOWN (ends per Q4) | the fan is on |
| — | Fan Direction (if the model reverses) | TOGGLE_DIRECTION | the fan runs in reverse |
| Top | Light Top | as the Hue Light: tap on to the preset, hold brightens | the light is on |
| Bottom | Light Bottom | tap off, hold dims | the light is off |
| Light Toggle | Light Toggle | tap toggles, hold dims up or down | the light is on |

### 2.6 Migration checklist (outline)

Each step names who does it (WS, the owner, or the driver), how it is
undone, and how it is checked. Standing approval covers every WS step; each
brief still names the hard-to-undo ones.

- **M0 Prepare (WS, no change).** Back up the project (WS rule: a backup
  before any round that changes the project; HUE `composer-remote.md`, rule
  5) [assumed: the File menu's backup item]. Copy All of every script on the
  keypad's buttons, on the stock device's events and in the Timer agent, into
  `C:\c4-mf\migration\` on the Windows machine (local only: it holds the
  house's names). Screenshots of the keypad's and the stock device's
  Connections. Read the Driver Update Agent's list.
- **M1 Add the new device (WS).** Install the release with "Add or Update
  Driver or Agent…", add Modern Forms Fan to the fan's room (by drag from the
  Items pane or a double-click; H2), name its proxies "(new)", run `Find
  Fans`, choose the fan, `Use Selected Fan`. Check that `Status` reads online
  and that speed and light match the fan. A first add needs no reboot
  [assumed: a new device takes its capabilities when created]. The room keeps
  running on the stock programming. Undo: delete the new device.
- **M2 Migration Report (WS click, read-only).** The stock device(s), their
  links, every item that names them. WS saves the rows beside the M0 XML.
- **M3 Test one binding before building on the links** (HUE
  `composer-remote.md`, "Learned 2026-10-27"). Bind one button (a spare, else
  the first to move), press it (H5, or the owner once), check fan, LED and
  `Keypad Links`. Undo: Disconnect, LED Behavior back to Programmed,
  re-enable.
- **M4 Cut over, button by button (WS, one sitting).** Per button: Disable
  Item (or Disable Event) on its old lines; bind its link by the top-pane
  drag (LED Behavior turns to Follow Connection by itself, F16); read both
  Connections lists and `Keypad Links` again (F17); press test. After the
  last button, Disable Event on the 12-If expiry script and on the stock
  "Fan Speed Changed" handler. Double taps per Q3. Each button is down for
  seconds; the fan's remote and app work throughout [assumed].
- **M5 Everything else in the report (WS).** Scheduler, macros, voice
  scenes, other scripts: new lines by drag, or Find and Replace (H9);
  Advanced Lighting Scenes if any (Q8).
- **M6 Names (WS).** The stock proxies become "… (old)", the new ones take
  the house's names; File ▸ Refresh Navigators (HUE `design.md`, "Keypad and
  scene dimmer: verified on hardware"). Then the owner's phone: favourites,
  voice assistants' rediscovery.
- **M7 Soak.** Nothing waits on it (the owner's rule against long test
  waits). The stock device stays, its programming disabled, perhaps disarmed
  (§2.3); the report reads "0 enabled".
- **M8 Remove (WS, any later day, one sitting).** Delete the disabled lines
  and scripts, then the Timer agent's timer, then the stock device(s) (the
  prompt "Are you sure you want to delete the item '<name>'?"; HUE
  `design.md`, "import-ui: verified on hardware"). Re-run the report: "No
  stock WAC devices; nothing names them". Back up.

**Rollback** before M8: Disconnect the new links; LED Behavior back to
Programmed on each button (disconnecting does not restore it, F16);
re-enable the disabled items; undo the disarm; keep or delete the new
device. After M8: load the M0 backup (it replaces the whole project, every
later change included) [assumed], or rebuild from the M0 XML.

**What needs the owner:** keypad presses and LED looks (unless H5 lets WS
press), and the phone (favourites, the tile, voice). No controller reboot:
the migration adds a device and changes no capability [assumed, as in M1].

## 3. Driver life

| # | Case | What Director and Composer do | Decision | Owner sees | Basis |
| --- | --- | --- | --- | --- | --- |
| D1 | Device added (`DIT_ADDING`) | both proxies created in the chosen room; Properties empty at first init (a blank Driver Version was seen on the house) | A: write Driver Version at late init; discovery may run (read-only). O: choose the fan. F: choosing one by itself, even the only one found (a second fan's new device, its fan offline, would grab the first) | "Not set up: Find Fans, choose a fan, Use Selected Fan" | F3, F23; HUE `composer-remote.md`, History (rounds 24 to 29) |
| D2 | Update, Lua only | `DIT_UPDATING`; properties, persisted values and bindings kept | A: read the fan, send state and LEDs once | unchanged | F23, F26 |
| D3 | Update adding connections, properties, events, variables or commands | allowed; new links reach existing devices at once | A | new rows | F2, F13 |
| D4 | Update changing a capability | "Restart Director?"; old capabilities until the owner's reboot | O: only with the reboot named in the deploy brief; avoided by fixing capabilities first (Q8) | — | F26 |
| D5 | Update adding, removing or retyping a proxy; removing or redefining a connection; removing or renumbering an event, variable or command | project corruption, broken programming | F, forever: a new driver file instead | — | F1, F2, F24 |
| D6 | Update moving between PUC Lua and LuaJIT | properties and state lost for a while | F: `jit="1"` from the first release, never changed | — | F27 |
| D7 | Device deleted | OnDriverRemovedFromProject, OnDriverDestroyed(`DIT_LOADED`), timers killed | A: stop all requests. F: any command to the fan, which keeps running as it is | — | F23 |
| D8 | Deleted, then added again | new ids, empty persistence; its links and programming are gone | O: choose the fan again. The manual: never delete to fix | "Not set up: …" | F25 |
| D9 | Director restart or reboot (`DIT_STARTUP`) | all OnDriverInit, then all OnDriverLateInit; bindings restored first | A: one read, one report (R6); Fan Online or Offline only if it differs from the persisted last state. F: commanding the fan at start ("restore the last state") | "Online: speed 3, light 40 %" after the first read | F23; §5.1 |
| D10 | Project restored from a backup | properties and PersistData come from the backup; the PersistSetValue store [silent] | A: the identity is also kept in the read-only `Fan ID` property [assumed: a value the driver wrote is in the backup] and checked at first contact; a different fan at the address is refused. O: `Use Selected Fan` | "Wrong fan at 10.0.2.151 (MF_00005E005302); nothing sent" | F25 |
| D11 | Project copied to a second controller on the same network | two controllers command one fan [assumed: not detectable] | F: nothing to do by itself; the manual warns | — | [assumed] |
| D12 | Controller replaced | the project moves to the new controller | A: check the identity again; nothing of ours is tied to the controller unless the fan needs a secret (fan side) | — | [assumed] |
| D13 | OS 3.x to 4.x | fan proxy: no change documented through 3.4.2, no 4.x pages; `light_v2`: `hide_proxy_*` dynamic from 4.2.1 | A: nothing; re-run the Composer checklist after an upgrade | — | F12, F33; FAN `3_whats_new/` |
| D14 | A proxy moved to another room | programming keeps the device; descriptions show "Room->Name" | A: nothing; no behaviour depends on the room | — | FUND `10_conditionals/_2-SIMPLECONDITIONAL.md` (the NAME macro) [assumed: ids kept] |
| D15 | A proxy renamed in Composer | the name is the owner's | F: `RenameDevice` by the driver (each call refreshes the whole project); the fan's own name shown read-only in `Fan Name` | — | API `22_miscellaneous/_32-RenameDevice.md` |
| D16 | Two fans in one project | two devices with the same default names | A: each device keeps its own identity; never `SINGLETON_ID` | — | F5 |
| D17 | Two of our devices on one fan (a re-add, a typo) | both command it | A: detect it (our devices by file name, each one's identity in a hidden variable read with `GetDeviceVariable`) and say so on both. F: disabling either. O: the owner deletes or re-points one | "Also controlled by device 1234 (Second Room)" | F20 [assumed: H11] |
| D18 | Fan hardware replaced (new identity, same place) | the fan side sees the mismatch | O: `Use Selected Fan` re-points the same device; links, programming and names stay. F: adopting a different fan by itself; deleting the device to fix it | "Wrong fan at 10.0.2.151; Use Selected Fan to accept it" | rule 2 |
| D19 | Fan readdressed (DHCP) | the fan side finds it again by identity | A: `Fan Address` updated by the driver (same identity only), noted in `Last Action` | "Fan moved from 10.0.2.151 to 10.0.2.152" | fan side |
| D20 | `Forget Fan` | — | O: clears the identity, stops requests; links and programming stay | "Not set up: …" | rule 2 |
| D21 | Debug Mode left On by a dev build | — | A: the deploy brief reads it back. F: a release build turning it on | — | `CLAUDE.md`, Deploy |
| D22 | Composer's driver store and Director hold different copies | — | A: WS reads every device's Driver Version after an install | — | HUE `composer-remote.md`, rule 16 |
| D23 | `<auto_update>` | only for drivers in Control4's online database | F: never declared | — | F32 |
| D24 | `<replaces>` naming the stock file | deletes the stock device unannounced | F, forever | — | F4 |
| D25 | Icons | decided at creation | A: the final (or a placeholder custom) icon in the first build that creates the house's device | — | F28 |
| D26 | Other drivers on the controller (the Hue bridge's stream) | one URL budget [assumed] | the fan-side transport choice; H13 | late tiles while starved | F30 |
| D27 | A dev or test build of the real driver file whose capabilities differ from the release | Director keeps the capabilities it loaded for that file until the owner's reboot, and a per-device overwrite does not refresh them | F: capability experiments only in a throwaway file with its own name; a dev build of the real file declares exactly the release's capabilities | — | F26; HUE `keypad-design.md`, "Hardware findings" |

## 4. Connections: Button Links and keypads

| # | Case | What happens | Decision | Owner sees | Basis |
| --- | --- | --- | --- | --- | --- |
| C1 | The link set and its ids | fixed by the first build installed on the house (add-only afterwards) | declare every link the driver will ever want in that build: fan Off, Speed 1 to 6, Toggle, Speed Up, Speed Down, Direction; light Top, Bottom, Toggle. Proposal: fan 300 to 310, light 200 to 202 as on the Hue Light, proxies 5001 (fan) and 5002 (light); each link with its proxy's `proxybindingid` if H2 shows Composer groups them that way | rows in Connections | F2, F3, F13 |
| C2 | Speed links: ours, or the fan proxy's (`proxy_fan_speed_connections`) | ours: the pattern verified on this house. The proxy's: 3.4.2+, behaviour undocumented, unused by any public driver, and a static capability | Q1. Never both sets on one driver file (duplicate rows forever) | — | F8, F13, F31 |
| C3 | A keypad button bound to a link | our side gets OnBindingChanged true [assumed for Connections; verified for `C4:Bind`]; the keypad may ask REQUEST_BUTTON_COLORS; LED Behavior becomes Follow Connection | A: BUTTON_COLORS and MATCH_LED_STATE on that link at once (last known state); `Keypad Links` updated | "Speed 2 ← device 456, binding 3" | F14, F15, F16, F22 |
| C4 | A link removed (Disconnect) | OnBindingChanged false; the button keeps its last LED and Follow Connection | A: log, update the list. F: touching the keypad's settings (no API; not ours). The manual: set LED Behavior back | "Speed 2: not bound" | F16 |
| C5 | Keypad replaced or deleted | its links go with it [assumed]; a Composer replacement that keeps the keypad's device id would keep them [assumed] | A: list updated. O: WS binds again | "9 of 14 links bound (11 before)" | [assumed] |
| C6 | Several keypads on one link | one provider link, many consumers; a message on the link reaches all of them [assumed] | A: one press machine per link; a second press while one is down is ignored until its release | — | F20, [assumed] |
| C7 | One button that should do two things | a consumer link takes one provider [assumed] | Q3 (taps), or programming | — | [assumed] |
| C8 | Presses on fan links | DO_PUSH, then DO_CLICK or DO_RELEASE | A: act on DO_PUSH (Control4's advice); the rest only ends the press; no repeat while held; a release is always expected | — | F14 |
| C9 | Presses on light links | — | A: as the Hue Light (tap top on to the preset, bottom off, toggle toggles; hold sends LIGHT_BRIGHTNESS_CHANGING and dims, release reports the final level) | — | HUE `keypad-design.md`; FUND `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md` |
| C10 | Double and triple taps | what arrives over a link is [silent] (H4); the keypad fires its own tap events from CLICK_COUNT | Q3 | — | F14, F18 |
| C11 | What each LED means | per §2.5 | A | — | §2.5 |
| C12 | LED colours | the fan proxy offers no LED colour settings [silent]; the light proxy does, with `has_leds` | A: the fan links' on and off colours are driver properties (COLOR_SELECTOR), sent as BUTTON_COLORS; a colour per speed is possible (the house uses blue for 1 and orange for 6) | `Speed 1 LED On Color` | FUND `15_composerpro_interface_into_the_sdk/_5-COLORSELECTOR.md`; F12, F15 |
| C13 | LED timing | the keypad shows what the driver sends | A: on a press the target's LED lights at once (MATCH_LED_STATE, not a proxy notification, so no programming fires) and is corrected on the fan's answer or failure | — | rule 3; R4 |
| C14 | Bound before the first read, or while the fan is offline | — | A: last known state, else dark; corrected at the next read | — | R6, R7 |
| C15 | Director start | bindings restored before late init; OnBindingChanged for them [silent] | A: `GetBoundConsumerDevices` per link at late init (one nil = unknown, a nil five seconds later = none, as the Hue drivers learned); LEDs sent after the first read | `Keypad Links` | F22; HUE `design.md`, "Hardware facts of the 2026-10-25 dev pass" |
| C16 | A wrong class offered for a link | — | A: OnBindingValidate accepts only BUTTON_LINK on link ids | — | F22 |
| C17 | Speeds a model lacks | links exist, nothing to set | A: they stay dark; `Status` says so (Q2) | "This fan has 3 speeds; Speed 4 to 6 do nothing" | Q2 |
| C18 | WS's drags and Disconnects | drags start only from the top pane; Disconnect names devices, not links | A: `Keypad Links` is the cross-check after every Connections step | — | F17 |

## 5. Programming: events, variables, conditionals, timing

### 5.1 The report contract

The proxies fire the events programming hangs on (F7, F11), and they fire
them when our notifications arrive. So the driver owns their timing:

- **R1 One notification per change.** CURRENT_SPEED when the confirmed
  speed differs from the last one sent; DIRECTION likewise;
  LIGHT_BRIGHTNESS_CHANGED in whole percents, never 0 while on (F10). No
  periodic re-sends of an unchanged state.
- **R2 Never older after newer.** Every read and every command answer
  carries a sequence number; an answer older than the newest one applied is
  dropped.
- **R3 Settle after a command.** Reads that started before a command's
  answer are ignored; the answer (or the first read after it) is the truth.
  A different speed then (someone at the remote) is reported as it is.
- **R4 Confirmed only.** Proxy notifications carry only what the fan
  reported. Instant feedback goes to keypad LEDs alone (C13), which fire no
  programming.
- **R5 Bursts coalesce.** The latest command wins; CYCLE steps are counted
  from the target, not from the last report; intermediate steps are not
  reported unless the fan confirms them.
- **R6 Start.** Nothing before the first successful read; then the whole
  state once, and the light's ONLINE_CHANGED true.
- **R7 Offline.** Once the fan side declares the fan unreachable: the
  light's ONLINE_CHANGED false, the ONLINE variable 0, Fan Offline once. No
  fan notification: never CURRENT_SPEED 0 to mean offline (it would fire
  turned_off and speed_changed).
- **R8 Back online.** The state is read; a change made meanwhile is
  reported, so programming catches up late rather than never (the Hue
  motion contract's choice); Fan Online once.
- **R9 ON and OFF notifications** are not sent by default: CURRENT_SPEED
  covers on and off (F6). ON makes the proxy assume the preset speed (F6),
  so ON followed by the real speed could report the preset first and fire
  speed_changed twice. That looks like the out-of-order reports the house
  works around today [assumed]. H3 decides.

### 5.2 What the driver adds

| Kind | Proposal | Why | Basis |
| --- | --- | --- | --- |
| Events | `Fan Offline` (id 1), `Fan Online` (id 2); optionally `Changed Outside Control4` (id 3) if the fan side can tell who changed it | the fan proxy has no online state (F8); the third lets programming react to a person at the remote | F2, F24 |
| Variables | `ONLINE` (BOOL, id 1, read-only); `FAN_ID` (STRING, id 2, hidden) for D17 | added in OnDriverInit, numeric ids, never reordered | F23, F24 |
| Conditional | `Fan is online` (BOOLEAN) | If and While in programming | FUND `10_conditionals/_1-OVERVIEW.md` |
| Commands | none beyond the proxies' in v1 | every command is forever once released | F2 |
| Everything else | speed, on and off, direction, preset, the light's on, off and level come from the proxies' own events, variables and conditionals | — | F7, F11 |

### 5.3 Cases

| # | Case | Decision | Basis |
| --- | --- | --- | --- |
| P1 | Programming on speed_changed, turned_on, turned_off | fires once per real change, in order (R1 to R3) | F7 |
| P2 | Programming on Fan Offline and Online | transitions only, after the fan side's debounce, compared with the persisted last state; never at start unless the state changed across the restart | R6 to R8 |
| P3 | A command while offline | attempted once (it doubles as a reachability check), then dropped; never queued for later replay | `Status`: "Offline: SET_SPEED 3 not sent" |
| P4 | A slider, repeated CYCLE presses, a programming loop | coalesced, latest wins (R5); the request rate is the fan side's | R5 |
| P5 | Programming writes Is On or Current Selected Speed (read/write, F7) | the proxy turns the write into a command [assumed]; same path as P4 | F7 |
| P6 | "If the fan is on" right after SET_SPEED | sees the old value until the fan confirms (R3); the manual: react to events rather than test right after a command | R3 |
| P7 | While loops on fan conditionals | can be expensive; the manual says so; nothing in the driver | FUND `10_conditionals/_1-OVERVIEW.md` |
| P8 | A change at the remote, wall control or app | reported like any change, so programming fires; F: reverting it | rule 5 |
| P9 | What the proxies hold right after a restart (do they fire turned_on for the first report?) | [silent]; H12, parked to the next reboot | F23 |

## 6. What people see: Navigators, apps, Composer

### 6.1 Cases

| # | Case | Decision | Basis |
| --- | --- | --- | --- |
| U1 | The fan tile | speed count, names, preset and reverse come from capabilities (F9): fixed before the first device exists (Q8); six speeds default to numbered levels | F8, F9 |
| U2 | The light tile | a dimmer; disabled while ONLINE_CHANGED is false | F10 |
| U3 | The fan offline | the fan proxy has no offline flag (F8): the tile stays live with the last speed; taps per P3; the owner sees `Status`, the ONLINE variable and Fan Offline. Whether ONLINE_CHANGED sent to the fan proxy does anything (a community driver sends it) is H3; LEDs per Q5 | F8, F31 |
| U4 | Before the first read (new device, after a restart) | the light tile disabled; the fan tile shows what its proxy holds [assumed] | R6 |
| U5 | Where the devices show | both proxies land in the room chosen at the add; the fan among the room's comfort controls, the light among its lights [assumed: the owner's eyes once] | F3 |
| U6 | Names | the proxies' default names come from their `name` attributes; two fans in a room are renamed by the owner | F3 |
| U7 | After adds, renames, capability changes | File ▸ Refresh Navigators (WS) | HUE `design.md`, "Keypad and scene dimmer: verified on hardware" |
| U8 | Long texts in Composer | rows under about 70 characters; lists as DYNAMIC_LIST (the Hue `Room Mappings` lesson) | F29; HUE `edge-cases-ux.md`, §6 |
| U9 | The Actions tab | every action carries `sort_order` | F29 |
| U10 | The tree icon | D25 | F28 |
| U11 | History entries for offline and online | not in v1; probe `C4:RecordHistory` first, as the Hue motion research decided | API `9_helper/_15-RecordHistory.md`; HUE `motion-control4-research.md`, §2.3 |

### 6.2 Properties and texts (proposal)

| Property | Type | Example text |
| --- | --- | --- |
| `Status` | STRING, read-only | "Online: speed 3, light 40 %"; "Offline since 18:02 (10.0.2.151 not answering)"; "Not set up: Find Fans, choose a fan, Use Selected Fan"; "Wrong fan at 10.0.2.151 (MF_00005E005302); nothing sent"; "Also controlled by device 1234 (Second Room)" |
| `Fan` | DYNAMIC_LIST | "Example fan (10.0.2.151, …5301)" per fan found; a pick only records the choice, `Use Selected Fan` acts |
| `Fan Address` | STRING | 10.0.2.151 |
| `Fan ID`, `Fan Name`, `Last Seen` | STRING, read-only | MF_00005E005301; the fan's own name; "2026-10-27 18:02" |
| `Keypad Links` | DYNAMIC_LIST, a pick snaps back | first row "5 of 14 links bound", then "Speed 2 ← device 456, binding 3" |
| `Stock Device` | DEVICE_SELECTOR (stock file) | only when the automatic match fails |
| `Migration` | DYNAMIC_LIST | "Stock WAC devices: 1; 14 items name them (14 enabled)", then one row per item |
| LED colours | COLOR_SELECTOR per fan link | on and off colour |
| `Last Action` | STRING, read-only, wrapped rows | "Use Selected Fan: MF_00005E005301 at 10.0.2.151" |
| `Driver Version`, `Debug Mode` | as in the scaffold | — |

Actions: `Find Fans`, `Use Selected Fan`, `Forget Fan`, `Migration Report`,
each with `sort_order`.

## 7. Probes, in order

Each is under a minute of waiting except H12, which waits for the next
controller reboot the owner does anyway and blocks no build. Logs and
reports that leave the controller carry placeholders only.

1. **H1 `proxy_fan_speed_connections`** on a test device in a test room,
   deleted afterwards, built from a throwaway probe package with its own
   file and driver name, never the real driver's (D27): which links appear
   (names, ids, where in Connections); what a bound button's press delivers
   to the protocol device; whether the proxy sends SET_SPEED by itself;
   whether the LED follows CURRENT_SPEED without our MATCH_LED_STATE.
   Decides Q1. The step-by-step version is tests T1 to T4 of
   `docs/fan-proxy-research.md`; T1 (WS reads the stock package's
   `driver.xml` from Composer's driver store, names and ids only) also
   answers what H10 and the disarm row of §2.3 assume about the stock
   driver.
2. **H2 Two proxies in one driver** (WS): the tree rows; which device shows
   Properties, Actions and Documentation; where driver-declared links show,
   with and without `proxybindingid`; whether the proxies can sit in
   different rooms; how a device is added from the Items pane by drag.
3. **H3 Fan proxy notifications** (dev loop): list the fan proxy's variables
   with `GetDeviceVariables`, register listeners on them, then send
   CURRENT_SPEED alone, ON then CURRENT_SPEED, CURRENT_SPEED then ON, OFF,
   CURRENT_SPEED 0, a repeated identical value, and ONLINE_CHANGED; log
   every variable change. Decides R9 and U3.
4. **H4 What a keypad sends over a link** for one, two and three taps and a
   hold, with timestamps (simulated through H5, or one series of presses by
   the owner). Decides Q3.
5. **H5 KEYPAD_BUTTON_ACTION** from a dev build to the keypad proxy: does it
   drive links and tap events as a real press does? If so, every later
   keypad test runs without the owner (F18).
6. **H6 Programmed LED commands on a Follow Connection button** (WS, on one
   button): does "Use the on color for <button>" still act? Decides whether
   M4 disables the LED lines per button or at the end.
7. **H7 OnBindingChanged for a link** made and removed in Connections: its
   parameters on our side, and whether REQUEST_BUTTON_COLORS follows.
8. **H8 `GetAllCodeItems` on the house** (dev loop, read-only, counts only):
   size and time; whether keypad events, the Timer agent and the Scheduler
   appear; whether a condition carries its device; the enabled flag after
   Disable Item and Disable Event.
9. **H9 Find and Replace** in a Script (WS, read-only): what it offers;
   Cancel.
10. **H10 `GetBindingsByDevice`** on the stock device (dev loop, read-only):
    does it reveal the fan's address, for the automatic match? T1 of
    `docs/fan-proxy-research.md` shows first whether the stock driver has a
    network binding at all.
11. **H11 Duplicate detection**: two of our devices on one fan, each reading
    the other's hidden identity variable.
12. **H12 At the next reboot (parked):** the proxies' values and events for
    the first report after a restart; OnBindingChanged at start; the light's
    level kept or not.
13. **H13 The URL budget** with the Hue drivers running: the time of a fan
    request while the Hue stream holds its transfers (for the fan-side
    transport choice).

## 8. Open questions for the owner

1. **Q1 Who owns the speed links.** The driver's own links (works on OS 3.3
   and later, our tap logic, LED colours and timing, the pattern the Hue
   drivers proved on this house), or the fan proxy's
   (`proxy_fan_speed_connections`: OS 3.4.2 and later, behaviour
   undocumented, used by no public driver)? Either is permanent for this
   driver file. The v1 scope names the proxy's links; recommended: run H1
   first, and choose our own links unless the proxy's handle presses and
   LEDs completely and beat ours.
2. **Q2 Speed count.** The fan proxy cannot change its speed count at run
   time (F8), so one driver file cannot show "fewer speeds where a model has
   fewer". Recommended: v1 for six-speed fans, with `Status` flagging any
   other count; a separate file per speed count only when a real fan needs
   one.
3. **Q3 Double taps** (today a double tap gives speed 1 with a blue LED, or
   speed 6 with an orange one). (a) Single-speed links plus Double Tap lines
   on the keypad's own events, aimed at the new fan: simple, if H4 shows the
   link does not also act on the taps. (b) A driver link per button with a
   tap speed, a double-tap speed and a colour per speed: no programming
   left, and the first tap acts at once while a second corrects it within
   about half a second. Recommended: (b) if H4 shows taps arrive distinctly,
   else (a).
4. **Q4 ON, Toggle and Cycle.** Does ON (and Toggle from off) go to a preset
   kept in Control4 (`can_set_preset`; recommended default 3, not the
   proxy's default of the highest speed) or to the fan's last speed? Does
   Speed Up stop at 6 and Speed Down stop at 1 (recommended; no wrap, never
   off by cycling)?
5. **Q5 Keypad LEDs while the fan is offline.** Keep the last state
   (recommended: honest about what was last known), or darken every fan
   link as a visible sign that also misstates the speed?
6. **Q6 One driver, two proxies.** One device with a fan proxy and a light
   proxy (recommended; the house's fan has a light). A fan without a light
   kit would keep a light proxy that can never be removed (F1); shown
   offline with "No light on this fan", or a second driver file without the
   light, chosen at add time (moving between them means delete and re-add).
   Two bound drivers (fan and light) are not recommended: two identities,
   two pollers, a binding lifecycle.
7. **Q7 Migration pace.** Cut over button by button in one sitting, keep the
   old programming disabled and the stock device (perhaps disarmed) until
   you say, then remove both in one later sitting (recommended)? Or delete
   right after the cutover?
8. **Q8 Fix before the first device exists** (static, a reboot to change
   later; F12, F26): may the fan's light join Advanced Lighting Scenes
   (`reduced_als_support`; yes only if you use them with it)? Show the
   light's preset, rates and LED colours (`hide_proxy_properties` False,
   recommended, as on the Hue drivers)? `can_reverse` per the model, the
   speed names, and the custom icon (D25).
