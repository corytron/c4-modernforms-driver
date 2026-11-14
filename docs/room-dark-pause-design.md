# The LED animations pause in a dark room at night: design contract

> **Contract for [issue #233](https://github.com/corytron/c4-modernforms-driver/issues/233)**
> (2026-11-14). The owner, after the chase stayed stopped in a sunny bedroom
> under 1.10: "revert everything back to before we made any changes to the
> chase based on ambient light. take the code back to where it was when the
> chase feature was completed. Then just simply make it so that if all the
> lights are off in the room and it's after sunset, then the chase turns off.
> if the lights come on at all in the room then chase comes back." This
> replaces the ambient pause of 1.9 and 1.10
> ([`ambient-pause-design.md`](ambient-pause-design.md), withdrawn).
>
> **Revised for [issue #240](https://github.com/corytron/c4-modernforms-driver/issues/240)**
> (2026-11-14, a new build of 1.11). The owner: "i want pause to occur only
> after sunset and before sunrise plus 30min and only if all lights are off".
> The pause is no longer a latch. It is a plain condition, re-checked
> whenever any part of it changes: the window from sunset to 30 minutes
> after sunrise, and every room light off. RD-D5 to RD-D8, RE6, RE10, RE11
> and section 3 below say it the new way. Build 244 had the latch: sunrise
> did not end a pause, and the pause was saved over a restart.

## 1. Decisions

| # | Decision |
| --- | --- |
| RD-D1 | **The ambient pause is withdrawn, whole.** Gone from the driver: the input `Ambient Light Level (Follower)` (connection 500), the property `Pause LED Animations Below`, `fan/ambient.lua`, the command `AMBIENT_LIGHT_LEVEL`, the keypad rebind after a start, the `dark` input of both LED engines, the 21st keypad LED row as it was, the Keypad Links reading note, and the MF Probe's ambient input and helper. `fan/speedleds.lua`, `fan/breezeleds.lua`, `fan/ledrows.lua` (with their specs) and the probe are back to their 1.8 text (commit 887be32, the chase as completed); everything else of 1.9 and 1.10 that is not the ambient pause stays (the security hardening, Min On, the documentation review). The keypads' own LED settings in Composer (their Ambient Light Profiles) are the keypads' and never the driver's. |
| RD-D2 | **One property, `Pause LED Animations`**, a `LIST` of `Room lights off after sunset` (the default) and `Never`, on the fan item's Properties tab right after `Speed LED Rest (s)` (where `Pause LED Animations Below` was). It is a keypad LED row: shown only while a button is bound to a Fan Speed link, and never Breeze-only, since it pauses both animations (`ledrows.ROWS`, 21 rows again, like `Breeze LED Bottom` it follows the gate alone; 22 since #240 with `Pause Ignores Lights`, RD-D13). No controller reboot: no capability changes. |
| RD-D3 | **The room's lights** are every `light_v2` proxy in the fan item's room: `C4:GetDevices({ C4iNames = "light_v2.c4i" }, tostring(C4:RoomGetId()))` [API 22_miscellaneous/_9-GetDevices.md: the key is the proxy id, `driverFileName` "light_v2.c4i"; _33-RoomGetID.md; both not before late init, _25.2-SafeUsageTable.md]. That includes the fan's own light when it is in that room, Control4's dimmers, switches and keypad dimmers, and any other light_v2 driver. Old `light.c4i` proxies, other rooms, scenes and loads not in Control4 do not count. The list is read again (a **scan**) at late init, when `Pause LED Animations` is set, at every sunrise and sunset, and at the 6-hourly look of the sun (`NIGHT_RECHECK_MS`). |
| RD-D4 | **A light's state is its Light State variable (id 1000)** [light_v2 proxy protocol, 30_Light_v2_variables: "Boolean indicating if the light Brightness is not at the Off preset"], watched with `C4:RegisterVariableListener(id, 1000)` for every light a scan finds new, and `C4:UnregisterVariableListener(id, 1000)` for every light a scan no longer finds [API 36_variable/_10, _11]. Director calls `OnWatchedVariableChanged(id, 1000, value)` right after a listener is set (so possibly inside the register call) and at every change. `"1"`, `"true"` (any case) or a number above 0 is **on**; `"0"`, `"false"` or 0 is **off**; anything else, and a light that has not reported, is **unknown**. A register call that fails (pcall) leaves that light out, with one warning; the next scan tries again. |
| RD-D5 | **The window** is from sunset to **30 minutes after sunrise** at the project's location (#240). It is `fan/sun.lua`'s `night(lat, lon, now, rise_delay_s)` with `rise_delay_s` = `PAUSE_AFTER_SUNRISE_S` = 1800: each sunrise counts 30 minutes later. The location is `C4:GetProjectProperty("Latitude")` and `("Longitude")`, as for the Breeze night brightness (BL-D28, BL-D29). The Breeze brightness keeps plain sunset to sunrise (no delay). No location, or the controller's clock not set: never in the window, so the animations never pause (logged once, as the Breeze night brightness does). |
| RD-D6 | **Paused exactly while** all of these hold (#240: a condition, not a latch):<br>- `Pause LED Animations` is `Room lights off after sunset`;<br>- it is inside the window (RD-D5);<br>- the room has at least one light;<br>- every light is known **off** (none on, none unknown).<br><br>It is decided again whenever one of them may have changed: a light reporting, the window opening or closing, a scan, the property being set, and the start. So:<br>- the last light switched off inside the window pauses at once;<br>- a room already dark at sunset pauses at sunset;<br>- any light switched on resumes at once, and the last one off again inside the window pauses again;<br>- 30 minutes after sunrise the animations resume, even with every light still off. |
| RD-D7 | **So the pause ends** when any light reports **on** (a light still unknown keeps a pause, RE13, so a new light's first report causes no blip), when the window closes (30 minutes after sunrise), when the property is set to `Never`, or when a scan finds no light in the room. A light switched on and off again by day does not pause (outside the window). (Build 244 latched: sunrise did not end a pause, #240 withdrew that.) |
| RD-D8 | **Nothing is saved** (#240). After a restart the condition decides again as the lights report: their listeners report right after they are set, so a restart inside the window with every light off pauses again within moments, and one outside the window does not pause. The key `mf_room_dark_pause` that build 244 saved is deleted at the start. (Build 244 restored a saved pause.) |
| RD-D9 | **The engines** take `configure({ paused = bool })`, `false` at first. Speed chase: one more reason no chase can run, `"the room is dark at night"`, after every other reason (so those keep their texts), and one more input, so pausing takes the stop path (a rest's, first delay's or wait's timer cancelled, a chase in progress settles its held pixels once, nothing more is sent) and unpausing is a real change: a new run, its first chase `FIRST_MS` later, at the speed and direction of that moment. Breeze: paused is not active and not leaving, so it settles every held pixel at once with no ending wipe, and nothing animates or is armed while paused; unpausing with Breeze still blowing starts as Breeze starting does (dark first, then the first gust). Nothing missed is replayed. The engines never send black, a dark state or a scaled colour for the pause: they only stop sending frames, and the steady LEDs stay the links'. The Breeze night brightness (BL-D28) is unchanged and separate. |
| RD-D10 | **Keypad Links** (KL-D7's note): while paused and the rows shown, the first row reads `5 of 13 links bound; LED animations paused: room dark at night` in place of `; LED settings shown` (63 characters with "13 of 13", under the 75 Composer shows). Otherwise as in 1.8. |
| RD-D11 | **The log.** A pause and its end are written whatever Debug Mode says (`log.always`, a few lines a day): `LED animations paused: all 4 lights in the room are off after sunset` and `LED animations resumed: Example Lamp (123) came on` (or `30 minutes after sunrise` (#240), `Pause LED Animations is Never`, `no light in the room`). A scan that changes the list logs at info: `Room lights: 4 in this room (Example Lamp 123, ...)`, or `Room lights: none in this room; the LED animations never pause`. Each light's report is a debug line. |
| RD-D13 | **`Pause Ignores Lights`** (#240): a `DEVICE_SELECTOR` property, multi-select, items `light_v2.c4i` [FUND 15_composerpro_interface_into_the_sdk/_3.1-DEVICESELECTOR.md: the value is a comma list of device ids], empty by default, right after `Pause LED Animations`. It is the 22nd keypad LED row (`ledrows.ROWS`, the gate alone). A light whose proxy id, or whose protocol device's id, is in it is left out of the room's lights (RD-D3), and setting the row reads the room again at once. **Why:** measured on the house (2026-11-14), two Control4 switches in the fan's room are relays that stay on all the time. They power Hue bulbs and an outlet, and are set up as 2-button keypads whose LEDs show other links, so their Light State reads on day and night and "every light off" could never hold. Nothing is guessed about which lights to leave out: the dealer picks them. |
| RD-D12 | **Out of scope:** lights other than the room's (only leaving some of the room's out, RD-D13), lights in other rooms, a delay before the pause, resuming at sunrise, any keypad setting. |

## 2. Edge cases (Control4 side; the fan is not involved)

The module only watches: it creates, moves and changes nothing, so no case
can make a later manual fix harder. The owner asked for the simple form, so
these were enumerated here rather than by a research round.

| # | Case | What happens |
| --- | --- | --- |
| RE1 | A light added to the room, or moved into it | Counted from the next scan (sunrise, sunset, the 6-hourly look, or setting the property) |
| RE2 | A light moved out of the room, or deleted | Its last state counts until the next scan drops it and its listener |
| RE3 | The fan item moved to another room | The next scan reads the new room (`RoomGetId` at every scan) |
| RE4 | A light offline (Zigbee lost) | Its Light State keeps its last value, and that counts |
| RE5 | Room Off, a scene, a timer or programming turns the lights off at night | The last report of off pauses |
| RE6 | A light on by day, off again by day | No pause; at sunset, if all are still off, the pause starts |
| RE7 | Every light off before sunset | The pause starts at sunset |
| RE8 | A room with no light_v2 light | Never pauses; logged at the scan |
| RE9 | No project location, polar day or night, clock not set | Never night, never pauses (logged) |
| RE10 | Driver update or Director restart while paused | The condition decides again as the lights report: still paused inside the window with every light off (#240) |
| RE11 | Restart by day, every light off | No pause until sunset |
| RE12 | The fan off, in Breeze or offline | The pause is tracked as always; the engines have nothing to animate anyway |
| RE13 | A register call that fails, or a light that never reports | Left out (warning) / unknown: an unknown light keeps the pause from starting, never from ending |
| RE14 | `Pause LED Animations` set to `Never` while paused | Resumes at once |
| RE15 | A light that is always on: a relay switch powering smart bulbs or an outlet, set up as a keypad | Its Light State reads on day and night, so the room never counts as dark: pick it in `Pause Ignores Lights` (RD-D13) |

## 3. Interfaces

`fan/roomdark.lua` (agent A), pure: every Director call comes in through `opts`.

```lua
local roomdark = require("fan.roomdark")
local r = roomdark.new({
	lights = fn() -> { [id] = name, ... } | nil, err,  -- the room's light_v2 proxies now (RD-D3)
	listen = fn(id) -> true | false, err,              -- RegisterVariableListener(id, 1000); may call r:light inside
	unlisten = fn(id),                                 -- UnregisterVariableListener(id, 1000)
	on_change = fn(paused, why),                       -- only on a real change; why is RD-D11's phrase
	log = { always, info, warn, debug },               -- common/log.lua's functions
})
r:configure({ enabled = bool })  -- Pause LED Animations is "Room lights off after sunset"
r:set_night(bool)                -- inside the window or not (RD-D5); before start() it is only kept
r:start()                        -- late init: scan, then decide (RD-D6); nothing is restored (RD-D8)
r:scan(why)                      -- RD-D3: read the room again, listen to the new, unlisten the gone
r:light(id, value)               -- OnWatchedVariableChanged(id, 1000, value); an id not watched is ignored
r:paused() -> bool
r:counts() -> lights, on, unknown
r:stop()                         -- OnDriverDestroyed: unlisten every light, nothing more is called
r:debug() -> table
```

Nothing calls `on_change` before `start()`. `configure` and
`set_night` may come before it (the late-init replay of the properties and
the first look at the sun).

The engines (agent B): `speedleds` and `breezeleds` `configure` take
`paused = bool` as RD-D9 says; `debug()` shows it. `ledrows.ROWS` gains
`Pause LED Animations` after `Speed LED Rest (s)`, not in `BREEZE`.

`fan/texts.lua` (agent C): `texts.keypad_leds_note(shown, paused)`; only
`paused == true` with `shown` gives RD-D10's note.

`driver.lua` (coordinator): builds `roomdark` with the Director calls,
routes `OnWatchedVariableChanged` (variable 1000 only) to `r:light` after
late init, turns the Breeze night look into one look at the sun for both
(`r:set_night` and a scan at every look, the timer kept while either needs
it), feeds `on_change` to both engines and to Keypad Links, and handles the
property.

## 4. Pieces and owners

| Piece | Owner | Files |
| --- | --- | --- |
| The room's lights and the pause | agent A | `src/modernforms_fan/fan/roomdark.lua`, `tests/spec/roomdark_spec.lua` |
| The engines' `paused`, the row | agent B | `src/modernforms_fan/fan/speedleds.lua`, `src/modernforms_fan/fan/breezeleds.lua`, `src/modernforms_fan/fan/ledrows.lua`, `tests/spec/speedleds_spec.lua`, `tests/spec/breezeleds_spec.lua`, `tests/spec/ledrows_spec.lua` |
| The note, the manual, the probe's README | agent C | `src/modernforms_fan/fan/texts.lua`, `tests/spec/texts_spec.lua`, `src/modernforms_fan/www/documentation.html`, `probes/README.md` |
| The withdrawal, the wiring, the property, the fake runtime, the changelog, the docs | coordinator | `src/modernforms_fan/driver.lua`, `src/modernforms_fan/driver.xml`, `tests/helpers/fake_c4.lua`, `tests/spec/fan_driver_spec.lua`, `CHANGELOG.md`, `docs/*.md`, `.github/codenames.json`, `.github/codename-meanings.json` |

## 5. Control4 guidelines

| Row | How it meets it |
| --- | --- |
| L53 LEDs show the real state | The steady LEDs (the selected speed lit, the others dark) are the links' and never paused; only the animation frames stop. |
| Keypad LEDs follow the keypad's own settings | The driver reads and changes no keypad setting; a keypad's Ambient Light Profile dims its LEDs as before. |
| Lighting follows Control4's lights | The pause follows the room's Control4 lights as Control4 reports them (Light State), so Room Off, scenes and programming count. |
