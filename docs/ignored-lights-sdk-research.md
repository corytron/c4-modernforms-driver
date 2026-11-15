# Room lights that never go dark: what the SDK lets a driver read

Research for [issue #247](https://github.com/corytron/c4-modernforms-driver/issues/247),
written 2026-11-15. The room-dark pause
([`room-dark-pause-design.md`](room-dark-pause-design.md), RD-D3, RD-D13)
counts every `light_v2` light in the fan's room. A Control4 relay switch
kept on to power smart bulbs reports Light State 1 day and night, so the
room never counts as dark; 1.11 added the hand-filled `Pause Ignores
Lights`. The owner wants the driver to decide by itself, reliably, which
lights do not count: ignore a light only on positive evidence, count it
when unsure. This note says what the DriverWorks SDK documents for that,
what the house has shown, and what is still unknown. It is desk research:
nothing was sent to any device.

**Sources.** SDK files are cited by path under `~/c4-tools/reference/`:
**API** `docs-driverworks-api/source/includes/`, **FUND**
`docs-driverworks-fundamentals/source/includes/`, **LV2**
`docs-driverworks-proxyprotocol-lightv2/source/includes/`, **KPD**
`docs-driverworks-proxyprotocol-keypad/source/includes/`, **FAN**
`docs-driverworks-proxyprotocol-fan/source/includes/`, **PP**
`docs-driverworks-proxyprotocol/source/includes/`. **HUE** is the sibling
project `~/projects/c4-hue-driver/` (read only). Code is
`src/modernforms_fan/` unless named. The SDK text is summarised, never
copied.

**Status key.** **VERIFIED-doc**: the SDK file says so. **VERIFIED-house**:
seen on this house's controller (OS 3.4.x), naming where it is recorded.
**VERIFIED-code**: read in the code named. **INFERRED**: follows from the
sources, with the reason. **ASSUMED**: believed without direct evidence.
**SILENT**: the SDK says nothing. **UNKNOWN**: the probe of section 8
settles it.

**Placeholders.** "Relay switch A" (protocol device 701, light proxy 702),
its rockers bound to an "Example Hue Scene" (protocol 741, proxy 742);
"relay switch B" (711, 712), its rockers bound to an "Example Keypad
Dimmer" (protocol 721, light proxy 722, keypad proxy 723); an "Example Hue
Lamp" (731, 732); the fan's own light. No room, project or device name of
the house appears here.

**What the house showed** (Composer read, 2026-11-14, relayed in the brief
for #247): each relay is a Control4 switch (device file `switch_gen3.c4i`,
proxy file `light_v2.c4i`, proxy id = device id + 1) set to "Use as 2
Button Keypad" (`ROCKER_AS_KEYPAD` True), "Buttons Control Load" off
(`BUTTONS_CONTROL_LOAD` False), "LEDs Follow Load" off, LED Behavior
"Follow Connection", "Hide From Nav" ticked; its Top and Bottom Rocker
Links are bound to another light's Top and Bottom Button Links; the proxy
has variable 1000 = 1 and no 1001; `GET_SETUP` says dimmer False with the
levels Off 0 and On 100; the device carries energy counters (`MINUTES_ON`
about 31480, `MINUTES_OFF` 0 or 1, `MINUTES_ON_TODAY`, `CURRENT_POWER`,
`MAX_WATTS`). Composer read those settings through its own connection to
Director; which of them a driver can read is the subject of this note.

## Short answers

1. **Bindings are the one documented route to "this switch's buttons drive
   another device".** `C4:GetBindingsByDevice(id)` (OS 3.0.0+) lists a
   device's bindings, but its documented return is inconsistent (its
   example shows network-binding fields; the sibling
   `GetNetworkBindingsByDevice` page shows the per-binding fields one would
   expect, `bindingid`, `class`, `provider`, `isbound`, `name`). The probe
   must measure the shape. `C4:GetBoundProviderDevice(id, binding)`
   (1.6.0) then names the provider bound to a consumer binding such as a
   rocker link; on OS 3.4.2 it returns a number, 0 when nothing is bound
   (HUE, hardware). Proxy to protocol: `C4:GetDevices` returns a
   `protocol` sub-table (2.10.0); `C4:GetProtocolDeviceById` exists only
   from 4.0.0.
2. **No documented API reads another device's settings or its navigator
   visibility.** `C4:GetProjectItems` (1.6.0) returns the project XML; the
   SDK documents only its filters and that it can be parsed for variable
   ids. Whether Buttons Control Load, keypad mode or Hide From Nav are in
   it is UNKNOWN (probe). No API in the reference reads another device's
   properties, and a search of the whole reference for hidden, navigator,
   visible and HIDE finds connection `<hidden>`, scheduler `user_hidden`,
   the room's own Room Hidden variable and the light_v2 `hide_proxy_*`
   Composer capabilities, nothing about a device hidden from Navigators.
3. **A driver can read another device's variables** (`GetDeviceVariable`,
   1.6.0; `GetDeviceVariables`, 2.8.0; watch with
   `RegisterVariableListener`, 1.6.0). The SDK documents only the light_v2
   proxy's variables; it says a switch has only Light State (1000), no
   Brightness Percent (1001). The protocol device's energy counters are
   MEASURED on the house (six counters and three fault flags, read with
   `Dev Vars` on 2026-11-09) but SILENT in the SDK: no names, units or
   reset rules. No variable that mirrors Buttons Control Load has been
   seen.
4. **The light_v2 proxy documents nothing a consumer can read about load
   control.** Its capabilities (`dimmer`, `has_leds`, `has_button_events`)
   describe the driver, not a dealer's per-device setting;
   `buttons_are_virtual` was deprecated in 3.3.2 and `has_load` appears
   only in the Jumpstart template's defaults. `GET_SETUP` answers with
   setup XML (dimmer, buttons, levels); a driver can ask through
   `C4:SendUIRequest` (2.9.0), which returns the answer. That the proxy
   answers a driver this way is INFERRED (the LV2 pages show drivers
   calling `SendUIRequest` on a light_v2 proxy for colour presets) and
   unmeasured. `SendToDevice` returns nothing.
5. **OS.** Everything the recommendation needs exists on OS 3.0 and later.
   OS 4.0 adds `GetBoundPartner`, `GetProtocolDeviceById` and
   `GetCapabilityById`, 4.1 `GetRoomID`, 4.2 `GetDriverConfigInfoById`;
   no What's New entry for 4.x changes the 3.x calls used here.
6. **The Hue lights, Hue scenes and the fan's own light cannot misfire**
   on the rule below: they are dimmers, and their only consumer binding
   (Hue's bridge binding, class `HUE_BRIDGE`) is not a Button Link. The
   keypad dimmer is a dimmer too; its keypad buttons are bound to the
   fan's links, which is why bindings must be read on the light_v2 proxy
   only and filtered by class and side.
7. **Recommendation** (section 7): ignore a light only when it is not one
   of this driver's own proxies, is an on/off light (no variable 1001), has
   a consumer-side Button Link bound to a Button Link of another device
   (decisive), and has been on without a break for a day (confirmation).
   Undocumented signals (energy counters, project XML, `GET_SETUP` text)
   may only hold a light back, never put one on the list. Anything that
   cannot be read means the light counts.
8. **Probe** (section 8): read-only Lua for Composer's Lua command window
   of a `--dev` build, plus the dev commands `Dev Bindings`, `Dev Items`
   and `Dev Vars` (in `fan/devcmds.lua` on this branch), each bounded.

## 1. Bindings: who drives whom

### 1.1 What the SDK documents

| Call | OS | What the SDK says | Status |
| --- | --- | --- | --- |
| `C4:GetBindingsByDevice(id)` | 3.0.0 | Returns "binding information" for a device; for a device with a protocol and proxies pass the proxy id; 0 means this device. The example output lists a network binding (`networkbindingid`, `addr`, `uuid`, `status`, `ssdptype`, `deviceid`, `addresstype`). The OS 3 What's New page says it returns all of a device's binding information. API `32_serial_network_device/_2.5-GetBindingsByDevice.md`, `3_whats_new/_20-WhatwasNewinOS3.md` | VERIFIED-doc (existence, OS, parameter); return shape SILENT for control bindings |
| `C4:GetNetworkBindingsByDevice(id)` | 3.0.0 | Returns network binding information; same parameter note. Its example lists records with `deviceid`, `type`, `class`, `bindingid`, `name`, `provider`, `isbound`, `autobind`, `rank`, `flags`, `binding_info` for a serial and an IR binding. API `32_serial_network_device/_10-GetNetworkBindingsByDevice.md` | VERIFIED-doc |
| `C4:GetBoundProviderDevice(id, binding)` | 1.6.0 | What is bound to an input (consumer) binding of the device; proxy id for a protocol-with-proxy device; documented to return nil or a table of id/name pairs, while its own example prints a number. Not in OnDriverInit. API `32_serial_network_device/_4-GetBoundProviderDevice.md` | VERIFIED-doc; on OS 3.4.2 it returns a **number**, 0 when nothing is bound (HUE `docs/design.md`, "Project APIs", 2026-10-22): VERIFIED-house |
| `C4:GetBoundConsumerDevices(id, binding)` | 1.6.0 | The consumers of a provider (output) binding: nil, or a table of id/name pairs; same id note; not in OnDriverInit. API `32_serial_network_device/_3-GetBoundConsumerDevices.md` | VERIFIED-doc; the values are driver names, not Composer names (HUE `docs/zone-light-design.md`): VERIFIED-house |
| `C4:GetBoundPartner(id, binding, class)` | 4.0.0 | Device id and binding id of a binding's bound partner, given the source (producer) device, binding id and class. API `9_helper/_5.8-GETBOUNDPARTNER.md` | VERIFIED-doc; absent on the house's 3.4.3; whether "source" may be the consumer side is SILENT |
| `OnBindingChanged(...)` | 2.9.0 | Called for this driver's own control bindings only. API `9_helper/_12-OnBindingChanged.md` | VERIFIED-doc: no notice when another device is rebound |
| `C4:Bind(provider, pBinding, consumer, cBinding, class)` | 2.9.0 | A binding joins a provider and a consumer of one class; `<consumer>` in the connection XML says which side a driver is. API `9_helper/_1-bind.md`; FUND `11_connections/_1-OVERVIEW.md` (control bindings use ids 1 to 999) | VERIFIED-doc (the model, not used here) |

INFERRED: the examples of `GetBindingsByDevice` and
`GetNetworkBindingsByDevice` look swapped. The fields under
`GetNetworkBindingsByDevice` (class, provider, isbound for a serial and an
IR binding) are general binding records, and the fields under
`GetBindingsByDevice` (address, uuid, SSDP type) are network-binding
records. Neither example shows a bound partner. Until the probe prints the
real answer, the recommendation reads only the binding ids, class and side
from `GetBindingsByDevice` and asks `GetBoundProviderDevice` for the
partner.

### 1.2 How Button Links and rocker links appear

- **The load side is the provider.** A light's Top, Bottom and Toggle
  Button Links are provider connections of class `BUTTON_LINK`; keypad
  buttons bind to them as consumers. This driver declares 200 to 202, 300
  to 308 and 311 that way (`src/modernforms_fan/driver.xml`, `<consumer>False`)
  and finds the keypads with `GetBoundConsumerDevices(C4:GetDeviceID(),
  link)` (`driver.lua`, `links_mod.new{ bound = ... }`): VERIFIED-code and
  VERIFIED-house. The Hue Light and Hue Scene drivers declare the same
  three links (HUE `src/hue_light/driver.xml`, `src/hue_scene/driver.xml`).
  The messages on such a link are KPD
  `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`.
- **The proxy makes more links.** On the Hue lights the light_v2 proxy
  added "Brightness Stop" and "Color Stop" Button Links of its own (HUE
  `docs/keypad-design.md`, "Hardware findings", VERIFIED-house), and LV2
  `10_light_v2_commands/_1-BUTTONACTION.md` says the proxy creates and
  keeps consumer connections for the Top, Bottom and Toggle buttons of a
  light_v2 device and their Button Link bindings (VERIFIED-doc). INFERRED:
  the "Top Rocker Link" and "Bottom Rocker Link" Composer showed on the
  relay switches are those proxy-made consumer connections (the
  "wall control" half of the light_v2 proxy, LV2
  `3_whats_new/_20-WhatwasNewinOS3.md`), so they hang on the proxy id
  (702), not the protocol id (701). UNKNOWN until the probe: their binding
  ids, whether a Hue light's or the fan light's proxy has the same
  (unbound) consumer links, and which id `GetBindingsByDevice` lists them
  under.
- **A relay's rocker is the consumer.** Relay switch A's Top Rocker Link
  is bound to the Hue scene's Top Button Link (provider, 741/200), relay
  switch B's to the keypad dimmer's Top Button Link: VERIFIED-house
  (Composer, 2026-11-14; HUE `docs/status.md`, "Keypads", records the same
  set-up since 2026-10-27). So from the switch's side the evidence is "a
  consumer `BUTTON_LINK` whose provider is another device".
- **Names are not evidence.** "Rocker Link" is Composer's label on this
  hardware line; other models and OS versions may label it otherwise
  (UNKNOWN). The rule uses class and side, never names.

### 1.3 From a light_v2 proxy to its protocol device

- OS 2.10+: `C4:GetDevices({ DeviceIds = "702" })` returns
  `{ [702] = { deviceName, driverFileName = "light_v2.c4i", roomId,
  roomName, protocol = { [701] = { driverFileName, deviceName } } } }` (API
  `22_miscellaneous/_9-GetDevices.md`, example 2: VERIFIED-doc). The
  filter values are comma-separated strings; a table raises (HUE
  `docs/design.md`, "Project APIs": VERIFIED-house). The room scan already
  reads `info.protocol` from the room query (`driver.lua`, the `lights`
  function of `roomdark_mod.new`): VERIFIED-code. Whether every light_v2
  entry of the house carries the sub-table: ASSUMED, the probe prints it.
- The reverse, protocol to proxies, is the `proxies` sub-table (same page,
  example 3; HUE `docs/design.md`: VERIFIED-house), which also tells a
  combo device (a keypad dimmer lists a `light_v2.c4i` and a
  `keypad_proxy.c4i` proxy).
- OS 4.0+: `C4:GetProtocolDeviceById(proxy)` (API
  `9_helper/_8.5-GETPROTOCOLDEVICEBYID.md`). Not needed: `GetDevices`
  works on every target OS.

### 1.4 Which call can say "its buttons drive another device"

| Call | Can it? |
| --- | --- |
| `GetBindingsByDevice(proxy)` | Lists the candidate binding ids, and (if the records look like the `GetNetworkBindingsByDevice` example) their class and side. Necessary, not sufficient: no partner in either documented example |
| `GetBoundProviderDevice(proxy, rocker binding)` | **Yes**: a non-zero id that is neither the light's proxy nor its protocol is a device the rocker drives. Needs the binding id from the row above |
| `GetBoundConsumerDevices(...)` | Only from the other end (the partner's Button Link id must be known); useful in the probe to confirm, not for the rule |
| `GetBoundPartner(...)` (4.0+) | A cross-check on OS 4.x; not on the house |
| `OnBindingChanged` | No: never called for another device's bindings, so the driver learns of a rebinding at its next scan |

## 2. Project items and navigator visibility

- **`C4:GetProjectItems(filter, ...)`**, OS 1.6.0, not in OnDriverInit:
  the whole project as one XML string with no filter; filters ALL,
  LOCATIONS, PROXIES, DEVICES, AGENTS, LIMIT_DEVICE_DATA,
  JUST_CAPABILITIES, NO_ROOT_TAGS, each passed as its own string argument;
  the page says the XML can be parsed for variable ids (API
  `22_miscellaneous/_17-GetProjectItems.md`; `_25.2-SafeUsageTable.md`:
  VERIFIED-doc). The SDK does not describe the XML's elements and says
  nothing about a device's dealer settings, its navigator visibility or a
  room's hidden lists (SILENT). The filter names LIMIT_DEVICE_DATA and
  JUST_CAPABILITIES suggest the XML carries device data and capabilities
  (INFERRED). Cost: SILENT; it is the whole project unless filtered
  (ASSUMED large, tens to hundreds of kilobytes; the probe prints the
  length). Parsing is plain string work or `C4:ParseXml` (API
  `9_helper/_13-ParseXml.md`, 2.7.0).
- **Another device's properties.** API `24_properties/` documents only the
  driver's own properties (`Properties`, `UpdateProperty`,
  `SetPropertyAttribs`, `UpdatePropertyList`, `OnPropertyChanged`) and
  project-level values (`GetProjectProperty`: location, zip code, units,
  `_2-GetProjectProperty.md`). No call reads Buttons Control Load, Use as
  2 Button Keypad or LEDs Follow Load of another device: VERIFIED-doc by
  absence. Composer's `GET_PROPERTIES` is its own query to Director; the
  SDK documents a request of that name only for the camera proxy (PP
  `37_camera_proxy_commands/_6-GETPROPERTIES.md`), so sending it to a
  light device would rely on undocumented behaviour. Not proposed.
- **Navigator visibility.** Searched the whole reference for hidden,
  navigator, visible, HIDE. Hits: a connection's `<hidden>` (Composer's
  Connections view, FUND `11_connections/_1-OVERVIEW.md`), scheduler
  events' `hidden` and `user_hidden` (API `31_scheduler_agent_modify_event/`),
  the light_v2 `hide_proxy_properties`, `hide_proxy_events`,
  `hide_proxy_commands`, `hide_proxy_conditionals_loops` capabilities
  (Composer panes of a driver, LV2 `5_light_v2_capabilities/`,
  `3_whats_new/_6-WhatsNewin421.md`), the room variable list's
  `Variable_Room_Hidden` (the room itself, API
  `36_variable/_12-ListofRoomVariables.md`), and button visibility in
  other proxies. Nothing reads whether a device is hidden from Navigators:
  VERIFIED-doc by absence. Whether the project XML carries it: UNKNOWN
  (probe P8).
- **Programming.** `C4:GetAllCodeItems()` and `C4:GetCodeItems(device,
  event)` (3.3.0) return the project's programming (API
  `9_helper/_5.5-GETALLCODEITEMS.md`, `_5.9-GETCODEITEMS.md`). The house's
  relays are held at 100 % by a "when the project loads" program (HUE
  `docs/composer-checklist.md`, step 33), so such a program could be
  found. Too loose to be evidence (any light can be programmed on); not
  recommended.

## 3. Another device's variables

- **Reading.** `C4:GetDeviceVariable(device, variable)` returns another
  device's variable as a string, nil when it does not exist, not in
  OnDriverInit (API `36_variable/_5-GetDeviceVariable.md`, 1.6.0).
  `C4:GetDeviceVariables(id)` returns every variable of a proxy or
  protocol id with its information (API
  `22_miscellaneous/_12-GetDeviceVariables.md`, 2.8.0); the shape of that
  information is SILENT. `C4:RegisterVariableListener(device, variable)`
  calls `OnWatchedVariableChanged` at once and at every change, and fails
  when the variable does not exist (API `36_variable/_10-RegisterVariableListener.md`,
  `_9-OnWatchedVariableChanged.md`). VERIFIED-doc; the room-dark pause
  watches 1000 this way on the house (VERIFIED-house, 1.11, `status.md`).
- **The light_v2 proxy's variables** are documented (LV2
  `30_Light_v2_variables/_0-HEADER.md`): Light State 1000, Brightness
  Percent 1001, rates and presets 1002 to 1010, colour presets 1300 and
  1301, Light Dynamic Capabilities 6661 (XML, "for UI use"), nesting
  variables. The page says that on a switch only the first variable
  exists. VERIFIED-doc; the relay proxies have 1000 and no 1001
  (VERIFIED-house, 2026-11-14).
- **First-party protocol devices** have no documented variables (SILENT).
  On the house `Dev Vars` read, on 2026-11-09, three fault flags and six
  energy counters (ids 4567 to 4572) on the keypad dimmer's protocol
  device and "the same kinds" on the switches beside it, and on the light
  proxies 1000, 1001, 1006, 1310, 1311 and 6661
  ([`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md),
  the "Variables" row: VERIFIED-house). The counter names seen in
  Composer (`MINUTES_ON`, `MINUTES_OFF`, `MINUTES_ON_TODAY`,
  `CURRENT_POWER`, `MAX_WATTS`) are not in the SDK; their units, start
  and reset rules (since installation, since a Director start, per day)
  are UNKNOWN. A driver can read them (`GetDeviceVariable` on the
  protocol id once `GetDeviceVariables` has named the ids), but nothing
  guarantees them on other models or OS versions.
- **Nothing mirrors the settings.** No variable for Buttons Control Load,
  keypad mode, LED behaviour or navigator visibility was seen in the
  2026-11-09 read (VERIFIED-house by absence for the kinds listed). The
  probe reads the relays' protocol variables again to be sure.

## 4. The light_v2 proxy: what a consumer can learn

- **Capabilities** describe a driver file, not a dealer's choice for one
  device. `dimmer` (dynamic, LV2 `5_light_v2_capabilities/_5-DIMMER.md`),
  `has_leds` (Composer LED colour rows, `_28-HASLEDS.md`) and
  `has_button_events` (button events in programming,
  `_26-HASBUTTONEVENTS.md`) say what the driver supports.
  `buttons_are_virtual`, `num_buttons`, `on_off`, `min_max` and
  `ramp_level` were deprecated in 3.3.2 (LV2
  `3_whats_new/_10-WHATSNEWIN332.md`); `has_load` and
  `buttons_are_virtual` appear only in the Jumpstart template's default
  light capabilities (FUND `26.5_jumpstart/_3-Configuration.md`). Reading
  another device's capability: `C4:GetCapabilityById` from 4.0.0 (API
  `9_helper/_5.6-GETCAPABILITYBYID.md`); on 3.x
  `C4:GetDeviceData(id, "capabilities")` returns the first two levels of
  that device's `<devicedata>` (API `22_miscellaneous/_8-GetDeviceData.md`,
  2.10.0). Neither is documented to change with Buttons Control Load
  (SILENT; ASSUMED not, since it is a property of the device, not of its
  driver file). This driver's own light declares `buttons_are_virtual`
  True (`src/modernforms_fan/driver.xml`), which shows the flag is a
  driver's static claim.
- **`GET_SETUP`** makes the proxy answer at once with setup XML: online
  flag, min and max on, cold start, click and hold rate bounds,
  `NUMBER_BUTTONS` and `BUTTON_LIST_INFO` (names, on and off colours),
  `supports_target`, the brightness levels (each with a
  `buttonLinkBindingId` attribute), colour support and presets (LV2
  `10_light_v2_commands/_16.5-GETSETUP.md`: VERIFIED-doc). Nothing in the
  documented answer speaks of load control or navigator visibility
  (SILENT). On the house Composer showed the relay's answer as dimmer
  False with levels Off 0 and On 100 (VERIFIED-house, Composer).
- **Can another driver ask?** `C4:SendUIRequest(id, request, params)`
  (2.9.0) sends a request to a proxy or protocol id and returns the
  answer as XML (API `22_miscellaneous/_36-SendUIRequest.md`). The LV2
  pages show a driver calling it on a light_v2 proxy for
  `ADD_DRIVER_COLOR_PRESET`, `MODIFY_DRIVER_COLOR_PRESET` and
  `DELETE_DRIVER_COLOR_PRESET` and reading a result (LV2
  `10_light_v2_commands/_.5-ADDDRIVERCOLORPRESET.md`, `_15.5-...`,
  `_1.4-...`), and Fundamentals mentions it reaching the history agent
  before OS 3.4.0 (FUND `12.5_Events/_5-HISTORYEVENTNOTIFY.md`), so it
  reaches Director-side handlers, not only Lua `UIRequest` functions.
  INFERRED: `GET_SETUP` answers a driver the same way. The Hue light
  driver asks its own proxy so (HUE `src/hue_light/driver.lua`,
  `read_setup`), its result on the house not yet recorded (HUE
  `docs/composer-checklist.md`, step 114, open). UNKNOWN for a first-party
  proxy; probe P7.
- **`SendToDevice` returns nothing** (API
  `32_serial_network_device/_19-SendToDevice.md`), so no command sent that
  way answers. `GET_STATE` is documented for the fan proxy (FAN
  `41_fan_proxy_commands/_11-GETSTATE.md`), not for light_v2 (SILENT).
- **Button LED notices** (`BUTTON_INFO`, LV2
  `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/_2-BUTTONINFO.md`)
  go from a protocol to its own proxy; another driver never sees them.

## 5. OS availability

| Call | From | On 4.x | Source |
| --- | --- | --- | --- |
| `GetDevices` (with `protocol` / `proxies`) | 2.10.0 | unchanged | API `22_miscellaneous/_9-GetDevices.md` |
| `RoomGetId` | 1.6.0 | unchanged; 4.1 adds `GetRoomID(proxy)` | API `22_miscellaneous/_33-RoomGetID.md`, `9_helper/_9.5-getroomid.md` |
| `GetBindingsByDevice`, `GetNetworkBindingsByDevice` | 3.0.0 | unchanged | API `32_serial_network_device/_2.5-...`, `_10-...`; `3_whats_new/_20-WhatwasNewinOS3.md` |
| `GetBoundProviderDevice`, `GetBoundConsumerDevices` | 1.6.0 | unchanged | API `32_serial_network_device/_4-...`, `_3-...` |
| `GetBoundPartner`, `GetProtocolDeviceById`, `GetCapabilityById` | 4.0.0 | new | API `9_helper/_5.8-...`, `_8.5-...`, `_5.6-...`; `3_whats_new/_7-WhatsNewin400.md` |
| `GetDriverConfigInfoById` | 4.2.0 | new | API `22_miscellaneous/_7.5-GetDriverConfigInfoById.md`, `3_whats_new/_5-WhatsNewin420.md` |
| `GetDeviceVariable`, `RegisterVariableListener`, `UnregisterVariableListener` | 1.6.0 | unchanged | API `36_variable/_5-...`, `_10-...`, `_11-...` |
| `GetDeviceVariables` | 2.8.0 | unchanged | API `22_miscellaneous/_12-GetDeviceVariables.md` |
| `GetDeviceData` | 2.10.0 | unchanged | API `22_miscellaneous/_8-GetDeviceData.md` |
| `GetProjectItems` | 1.6.0 | unchanged | API `22_miscellaneous/_17-GetProjectItems.md` |
| `SendUIRequest` | 2.9.0 | unchanged | API `22_miscellaneous/_36-SendUIRequest.md` |
| `PersistSetValue` / `PersistGetValue` | 2.10.0 | unchanged | API `26.5_persistence/_4-PersistSetValue.md`, `_3-PersistGetValue.md` |
| `GetAllCodeItems`, `GetCodeItems` | 3.3.0 | unchanged | API `9_helper/_5.5-...`, `_5.9-...` |

"Unchanged" means no What's New entry for 4.0, 4.1 or 4.2 touches the
call (API `3_whats_new/_5-WhatsNewin420.md`, `_6-WhatsNewin410.md`,
`_7-WhatsNewin400.md`; LV2 `3_whats_new/_6-WhatsNewin421.md` adds only
the `hide_proxy_*` dynamic capabilities): VERIFIED-doc by absence. What
the SDK cannot say: first-party lighting on 4.x and other hardware lines
may use other driver files, binding names, rocker binding ids and
variables (UNKNOWN). The rule below depends on none of them: it reads
class, side, partner and the documented variables 1000 and 1001.
Every call above except `ParseXml` must stay out of OnDriverInit (API
`22_miscellaneous/_25.2-SafeUsageTable.md`); the room scan already runs
from late init on.

## 6. The other lights in such a room

Each candidate signal against each kind of light the fan's room has, and
two kinds it might have. "Consumer Button Link bound elsewhere" is the
decisive signal of section 7; "no 1001" the on/off guard.

| Light | Driver facts | Not own proxy | No 1001 (on/off) | Consumer Button Link bound elsewhere | Always on | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Relay switch A | first-party switch; rockers bound to a Hue scene's Top/Bottom (VERIFIED-house) | yes | yes (VERIFIED-house) | yes: provider 741 (expected; probe P3) | yes, weeks (counters, VERIFIED-house) | **ignored** |
| Relay switch B | same; rockers bound to the keypad dimmer's Top/Bottom | yes | yes | yes: provider 721 or 722 (probe P3) | yes | **ignored** |
| Keypad dimmer load | combo device: `light_v2` proxy 722 plus a `keypad_proxy` 723 (API 22/_9, example 3); its keypad buttons are bound to the fan's speed links; its own Top/Bottom Button Links have relay switch B as consumer | yes | **no** (it dims; 1001 VERIFIED-house) | its light proxy: none expected; its keypad proxy and protocol: yes, the fan's links, which is why only the light proxy is read | no | counted |
| Hue light | `hue_light.c4z`: consumer binding 1, class `HUE_BRIDGE`, bound to the bridge; provider `BUTTON_LINK` 200 to 202; `dimmer` True (HUE `src/hue_light/driver.xml`) | yes | **no** (dimmer True; 1001 ASSUMED, probe P6) | no: its one bound consumer binding is not a Button Link, so the class filter is essential | no | counted |
| Hue scene | `hue_scene.c4z`: the same bindings; `dimmer` True; relay switch A binds to its provider links (HUE `src/hue_scene/driver.xml`) | yes | **no** | no (it is the provider end) | no | counted |
| The fan's own light | this driver's proxy 5002: provider `BUTTON_LINK` 200 to 202, `dimmer` True, `buttons_are_virtual` True (`src/modernforms_fan/driver.xml`) | **no** | **no** | no | no | counted |
| A plain switch with a real lamp | Buttons Control Load on, rockers unbound | yes | yes | no | no | counted |
| A switch ganged to another light | Buttons Control Load on and rockers also bound to another light's links | yes | yes | **yes** | no: its own rocker turns it off | counted only thanks to the "always on" confirmation; without it this would misfire |
| A third-party on/off light (a plug driver) | dimmer False; its bound consumer bindings are its network or bridge bindings | yes | yes | no (class) | maybe | counted |

Two more cases the scan meets: a light whose rocker is bound to its own
Button Links (partner = itself: no evidence, counted), and a light whose
binding records cannot be read (no evidence, counted).

## 7. Ranking and recommendation

### 7.1 Every signal

| Signal | Readable from Lua | Documented | Rank |
| --- | --- | --- | --- |
| A consumer `BUTTON_LINK` of the light proxy bound to another device's Button Link | `GetBindingsByDevice(proxy)` for ids, class and side; `GetBoundProviderDevice(proxy, id)` for the partner | calls yes (3.0.0, 1.6.0); record shape no (probe P2) | **Decisive**: positive evidence that its buttons drive something else |
| On/off light: no variable 1001 | `GetDeviceVariable(proxy, 1001)` returns nil | yes (LV2 30/_0, API 36/_5) | **Guard**: required, keeps every dimmer (Hue, the fan light, keypad dimmers) out |
| One of this driver's own proxies | `GetDevices({ DeviceIds = me })`, `proxies` (already `item_ids` in `driver.lua`) | yes | **Guard**: required |
| On without a break | the driver's own watch of 1000 (already registered), with a persisted "on since" | yes (API 36/_10, 26.5/_4) | **Confirmation**: required; protects the ganged switch |
| Energy counters (`MINUTES_OFF` against `MINUTES_ON`) | `GetDeviceVariables(protocol)`, then `GetDeviceVariable` | API yes, variables no (SILENT; kinds VERIFIED-house) | **Supporting**: may hold a light back (many minutes off), or shorten the wait once the probe confirms their meaning; never decisive |
| `GET_SETUP` text (dimmer, buttons, levels) | `SendUIRequest(proxy, "GET_SETUP", {})` | request yes; answer to a driver INFERRED | **Supporting**: a second view of "dimmer"; nothing about load control is documented |
| Project XML (settings, Hide From Nav) | `GetProjectItems(...)` | call yes, content no | **Supporting at most**, and only if the probe finds the settings: whole-project cost, undocumented format |
| Buttons Control Load, keypad mode, LED behaviour, Hide From Nav | no documented call | no | **Unreadable** |
| Protocol driver file (`.c4i` first-party, `.c4z` third-party) | `GetDevices`, `protocol` | yes | **Log only**: an allow-list of file names would be a guess for every model not seen (same reasoning as [`keypad-leds-visibility-sdk-research.md`](keypad-leds-visibility-sdk-research.md)) |
| A program that holds the load on | `GetAllCodeItems` | yes | **Not used**: any light can be programmed |

### 7.2 The rule

At every scan of the room (late init, sunrise, sunset, the 6-hourly look,
a property change; RD-D3), a light found by `GetDevices` is left out
automatically only when all of these hold:

1. **G1.** It is not one of this driver's own proxies.
2. **G2.** It is an on/off light: `C4:GetDeviceVariable(proxy, 1001)`
   returns nil (pcall; an error is "unsure").
3. **E1, decisive.** `C4:GetBindingsByDevice(proxy)` lists at least one
   binding of class `BUTTON_LINK` on the consumer side (by the record's
   own side field once the probe shows it; failing that, a binding for
   which `GetBoundProviderDevice` answers a device is an input, since that
   call is documented for input bindings only), and
   `C4:GetBoundProviderDevice(proxy, binding)` answers an id other than 0,
   the light's proxy and its protocol. Accept a number or a table of
   id/name pairs (both are documented, the number is what OS 3.4.2
   returns). Read the proxy id only. Read the protocol id as well only
   when the probe shows the rocker links live there **and** `GetDevices`
   lists exactly one proxy for that protocol; a combo device's protocol
   also carries its keypad buttons, which on the house are bound to this
   fan's links (section 6).
4. **C1, confirmation.** Its Light State is on now and has been on
   without a break for at least 24 hours of the driver's own watching,
   kept over restarts as an "on since" time per proxy id (a report of off
   clears it). The counters may shorten this once the probe has shown
   what they count; they may also hold a light back (minutes off well
   above zero) but never put one on the list alone.

Plus the dealer's own list: `Pause Ignores Lights` (RD-D13) stays and is
added to what the rule finds, so the house keeps its two relays ignored
from the first minute of an update.

### 7.3 When a signal cannot be read

- A call that is missing or raises, an answer of an unexpected shape, a
  record without a class, a partner of 0 or nil: **no evidence; the light
  counts.** Log it once per scan at debug, with the light's name and id.
- The confirmation not yet met (a new relay, or the first day after the
  feature arrives): the light counts until the 24 hours pass.
- Undocumented sources (counters, `GET_SETUP` text, project XML) can only
  keep a light counted, never add one. A format change in them therefore
  costs a missed ignore, not a wrong pause.
- Everything is decided again at each scan, so a dealer who rebinds a
  switch, ticks Buttons Control Load or moves a device sees the result at
  the next scan (no `OnBindingChanged` comes for other devices' bindings,
  API `9_helper/_12-OnBindingChanged.md`).

### 7.4 What stays open

- **The ganged switch.** E1 cannot tell Buttons Control Load on from off;
  C1 covers it as long as the lamp is switched off now and then. A lamp
  of that kind left on for a whole day and night would be ignored while
  it stays on. The owner's evidence list for #247 names exactly the two
  facts the rule reads (bindings, weeks on), so this is the residual risk
  to accept or to cover with a longer C1.
- **A dimmer used as a keypad for another load** (Buttons Control Load
  off, its load held at 100 %) is never left out automatically (G2). The
  dealer list covers it.
- **The first-party proxy answering `GET_SETUP` to a driver, the record
  shape of `GetBindingsByDevice`, the rocker binding ids and where they
  hang, the counters' meaning**: all settled by the probe below, before
  the contract fixes the rule.

## 8. Probe on the house

Read-only and bounded. It needs a `--dev` build on the fan device
([`dev-loop.md`](dev-loop.md): the dev build allows Composer's Lua command
window and ships every `print` to the VM, at most 500 lines kept), so it
is the coordinator's call when to install one. The dev commands
`Dev Bindings`, `Dev Items` and `Dev Vars` are in
[`fan/devcmds.lua`](../src/modernforms_fan/fan/devcmds.lua) on this branch
(written for #247 at the same time as this note; their names and
parameters as they read on 2026-11-15). Nothing below sends anything to a
light: `GET_SETUP` is a read the proxy answers itself (LV2
`10_light_v2_commands/_16.5-GETSETUP.md`).

### 8.1 With the dev commands

```sh
tools/devctl.py run "Dev Bindings" DEVICE=702     # relay switch A's proxy
tools/devctl.py run "Dev Bindings" DEVICE=701     # its protocol device
tools/devctl.py run "Dev Bindings" DEVICE=722     # the keypad dimmer's light proxy
tools/devctl.py run "Dev Bindings" DEVICE=732     # a Hue lamp's proxy
tools/devctl.py run "Dev Vars" DEVICE=701         # the relay's counters; again 60 s later
tools/devctl.py run "Dev Items" FILTER=DEVICES,PROXIES DEVICE=701 WINDOW=4000
tools/devctl.py run "Dev Items" FILTER=DEVICES TERM=BUTTONS_CONTROL_LOAD
tools/devctl.py run "Dev Items" FILTER=DEVICES TERM=ROCKER
tools/devctl.py run "Dev Items" FILTER=DEVICES TERM=hide
tools/devctl.py log -n 200
```

### 8.2 In Composer's Lua command window (the fan device, dev build)

Paste once to define, then run `IL.list()`, and `IL.one(<proxy id>)` for
each light it lists, one at a time (each call prints at most 120 lines).
Every call is documented; every one is wrapped in `pcall`, because `C4` may
be userdata and a missing function raises.

```lua
IL = {}
local MAX_LINES, MAX_TEXT, lines = 120, 170, 0
local function out(s)
	if lines < MAX_LINES then lines = lines + 1; print("IL " .. s) end
end
local function text(v, max)
	local s = (tostring(v):gsub("%c", " "))
	max = max or MAX_TEXT
	return #s > max and (s:sub(1, max) .. "...") or s
end
local function api(name, ...) -- documented C4 calls only
	local found, fn = pcall(function() return C4[name] end)
	if not found or type(fn) ~= "function" then return false, "no C4:" .. name end
	return pcall(fn, C4, ...)
end
local function dump(label, v, depth)
	depth = depth or 0
	if type(v) ~= "table" then return out(label .. " = " .. text(v) .. " (" .. type(v) .. ")") end
	if depth >= 4 then return out(label .. " = {...}") end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	if #keys == 0 then return out(label .. " = {}") end
	for _, k in ipairs(keys) do dump(label .. "." .. tostring(k), v[k], depth + 1) end
end
local function has_bindingid(x)
	if type(x) ~= "table" then return false end
	for k in pairs(x) do if type(k) == "string" and k:lower() == "bindingid" then return true end end
	return false
end
-- Every bindingid field, and the top-level keys 1..999 of a table keyed by binding id.
local function binding_ids(v, found, depth)
	found, depth = found or {}, depth or 0
	if type(v) ~= "table" or depth > 4 then return found end
	for k, x in pairs(v) do
		if type(k) == "string" and k:lower() == "bindingid" and tonumber(x) then found[tonumber(x)] = true end
		local n = tonumber(k)
		if depth == 0 and n and n >= 1 and n <= 999 and not has_bindingid(x) then found[n] = true end
		binding_ids(x, found, depth + 1)
	end
	return found
end

function IL.list() -- P1: the room's lights, their protocol ids and files
	lines = 0
	local _, room = api("RoomGetId")
	local ok, lights = api("GetDevices", { C4iNames = "light_v2.c4i" }, tostring(room))
	if not ok or type(lights) ~= "table" then return out("GetDevices failed: " .. text(lights)) end
	for proxy, info in pairs(lights) do
		local line = "light " .. tostring(proxy) .. " " .. text(info.deviceName, 40)
		for protocol, p in pairs(type(info.protocol) == "table" and info.protocol or {}) do
			line = line .. " | protocol " .. tostring(protocol) .. " " .. text(type(p) == "table" and p.driverFileName, 40)
		end
		out(line)
	end
end

function IL.one(proxy) -- P2 to P7 for one light
	lines = 0
	proxy = tonumber(proxy)
	local _, devs = api("GetDevices", { DeviceIds = tostring(proxy) })
	local info = type(devs) == "table" and (devs[proxy] or devs[tostring(proxy)]) or {}
	local ids = { proxy }
	for protocol in pairs(type(info.protocol) == "table" and info.protocol or {}) do ids[#ids + 1] = tonumber(protocol) end
	for _, id in ipairs(ids) do
		local ok, b = api("GetBindingsByDevice", id)
		if ok then dump("bindings " .. id, b) else out("bindings " .. id .. " failed: " .. text(b)) end
		local list = {}
		for bid in pairs(binding_ids(ok and b or nil)) do list[#list + 1] = bid end
		table.sort(list)
		for _, bid in ipairs(list) do
			local _, p = api("GetBoundProviderDevice", id, bid)
			local _, c = api("GetBoundConsumerDevices", id, bid)
			dump("provider " .. id .. "/" .. bid, p)
			dump("consumers " .. id .. "/" .. bid, c)
		end
	end
	for _, var in ipairs({ 1000, 1001, 6661 }) do
		local _, v = api("GetDeviceVariable", proxy, var)
		out("var " .. proxy .. "/" .. var .. " = " .. text(v, var == 6661 and 400 or 40))
	end
	local ok, setup = api("SendUIRequest", proxy, "GET_SETUP", {})
	setup = ok and tostring(setup) or ("failed: " .. tostring(setup))
	out("GET_SETUP: " .. #setup .. " characters")
	for at = 1, math.min(#setup, 1020), 170 do out("GET_SETUP @" .. at .. " " .. text(setup:sub(at, at + 169))) end
	for i = 2, #ids do
		local okd, caps = api("GetDeviceData", ids[i], "capabilities")
		out("devicedata " .. ids[i] .. " capabilities: " .. text(okd and tostring(caps) or ("failed: " .. tostring(caps)), 400))
	end
end
```

Afterwards `IL = nil`.

### 8.3 What each step settles

| Step | Run on | Settles |
| --- | --- | --- |
| P1 | `IL.list()` | every light's proxy id, its protocol id and driver file (the `protocol` sub-table on the house) |
| P2 | `IL.one` / `Dev Bindings` on 702 and 701, 712 and 711 | the record shape of `GetBindingsByDevice`; whether the rocker links are listed, under the proxy or the protocol, with class `BUTTON_LINK` and a side field; their binding ids |
| P3 | the `provider` lines of P2 | `GetBoundProviderDevice` on a rocker link answers the partner (741 for relay switch A; 721 or 722 for relay switch B), as a number or a table |
| P4 | `IL.one(722)` / `Dev Bindings` on 722 and 721 | the keypad dimmer's light proxy shows its provider Button Links with relay switch B as consumer and no consumer Button Link bound elsewhere; whether its protocol lists the keypad buttons bound to the fan's links (the reason the rule reads the proxy only) |
| P5 | `IL.one(732)`, a Hue scene's proxy, the fan light's proxy | whether third-party light_v2 proxies carry proxy-made consumer Top/Bottom/Toggle links (expected unbound); that their bound consumer binding is the bridge's, class `HUE_BRIDGE` |
| P6 | the `var` lines | 1001 is nil on the relays and present on every dimmer (keypad dimmer, Hue lamp, Hue scene, fan light); 6661's `dimmer` agrees |
| P7 | the `GET_SETUP` lines | whether a first-party (and a Hue) proxy answers a driver's `SendUIRequest`; whether a relay's answer differs from the keypad dimmer's in anything that mirrors Buttons Control Load |
| P8 | `Dev Items` | the project XML's length (cost), whether it carries `BUTTONS_CONTROL_LOAD`, `ROCKER_AS_KEYPAD` or a navigator-visibility flag for a device, and in what form |
| P9 | `Dev Vars DEVICE=701`, twice, 60 s apart | the counters' names and ids on a switch, which one advances while the relay is on, so their meaning can be pinned down (or left as unknown) |

If P2 shows no class or side, or P3 answers 0 for a rocker link Composer
shows bound, E1 cannot be read on OS 3.4.3 and the rule must not be built
on it: the dealer list remains the way, and the contract says so.

## 9. For the contract

- The rule of section 7.2, its scan points (RD-D3's), and how Composer
  shows which lights were left out and why (the issue asks for it; a
  read-only row or the Keypad Links note, RD-D10).
- The 24-hour confirmation: its length, the persisted "on since" per
  proxy id (RD-D8 says the pause saves nothing; this would be the first
  saved state of the feature), and what clears it.
- The lifecycle cases (a switch rebound, its settings changed, hidden,
  replaced, moved, restored from a backup, a third-party light driver) are
  the edge-case note's; this note gives the facts they rest on, and
  [`edge-cases-control4.md`](edge-cases-control4.md) F20 to F33 the
  project-wide ones.
