# The LED animations pause while the keypad is dark: design contract

> **Contract for [issue #207](https://github.com/corytron/c4-modernforms-driver/issues/207)**
> (2026-11-12). Since #198, the house's keypad dimmer turns every status LED
> off in a dark room (Status LED Min Brightness 0). The speed chase and the
> Breeze animation still send their frames over Zigbee while nothing shows.
> The owner: "I was hoping that when it was dark enough to trigger the LEDs
> to black, the animation would wind down and stop using bandwidth. And then
> when it was light enough it would come back." The research is
> [`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md)
> (KLD) and [`edge-cases-led-dimming.md`](edge-cases-led-dimming.md) (cases
> DM1 to DM81, variant (a)). The probe that settled the route ran on the
> house on 2026-11-12 (Discussion #208 and the issue).

## 0. What the probe measured (MEASURED, OS 3.4.3, a C4-KD120 keypad dimmer on firmware 5.1.1)

| # | Fact |
| --- | --- |
| AP1 | A driver connection of class `AMBIENT_LEVEL`, type 1 (control), consumer, bound in Composer to the keypad's **Ambient Light Level (Source)** output (its binding 400), receives the keypad's reading in **`ExecuteCommand`**, as the command `AMBIENT_LIGHT_LEVEL` with string parameters `GROUP` (the keypad's device id), `LEVEL` (the reading, the 0 to 255 scale of the keypad's Ambient Light Profile, 3 to 14 at night in the bedroom) and `TARGET` (a small number, 1 to 4 seen; its meaning is unknown and it is not used). Nothing arrives in `ReceivedFromProxy`. `OnBindingChanged` reports the bind and the unbind (class `AMBIENT_LEVEL`, the keypad's device and binding 400). |
| AP2 | The keypad sends **on change only**. In a steady minute nothing came. While the reading flickered between 3 and 6 it sent pairs about 5 s apart, then gaps of 7 to 32 s: 21 messages in 3 min 54 s, about 5 a minute. The chase sends far more: a dot step every 0.12 to 0.4 s during a chase, and a chase every 5 s. |
| AP3 | **The first message after a bind read `LEVEL` 0** (`TARGET` 1), while the room read 3 to 14. It is not a reading. |
| AP4 | While bound, the keypad's Sensing reads "Mode: Source"; its LED curve is unchanged. After the unbind it reads "Independent" again. |
| AP5 | `GET_AMBIENT_LEVEL`, sent by a driver with `C4:SendToDevice` or `C4:SendUIRequest`, is answered to Composer (a DataToUI), never to the driver. It is not used (KLD route 3.3, DM8). |

## 1. Decisions

| # | Decision |
| --- | --- |
| AP-D1 | **A new connection on the fan:** id 500, "Ambient Light Level (Follower)", type 1, consumer True, class `AMBIENT_LEVEL`, on the fan item (no `proxybindingid`). The dealer binds one keypad's **Ambient Light Level (Source)** output to it in Composer's Connections. A connection change needs no controller reboot. Unbound, nothing changes: the animations run as today. |
| AP-D2 | **A new property, `Pause LED Animations Below`**: `RANGED_INTEGER` 0 to 255, default 10, after `Speed LED Rest (s)`. The keypad is **dark** while its last reading is below this value. Set it to the keypad's profile's Dark Room value, with that profile's Status LED Min Brightness at 0, so the animations pause exactly when the keypad shows nothing. 0 never pauses. The driver never reads or copies the keypad's profile (DM9). |
| AP-D3 | **The state** (`fan/ambient.lua`): `unknown` (unbound, or bound with no reading yet), `lit` or `dark`. Only `dark` pauses: unknown runs as today (fail-open, DM72). A reading below the threshold makes it `dark` at once. A reading at or above it makes it `lit` only after no dark reading has come for `LIT_HOLD_MS` = 10 000 ms (DM15), so a flicker pauses once and resumes once. A changed threshold applies to the last reading at once (the hold still applies to resuming). |
| AP-D4 | **Readings that count:** `AMBIENT_LIGHT_LEVEL` whose `LEVEL` is a whole number 0 to 255. The first one within `BIND_SETTLE_MS` = 5 000 ms of a bind is ignored (AP3). A reading from a device other than the bound one (`GROUP` differs from the bound device id, when both are known) is ignored. An unbind makes the state `unknown`, cancels the hold, and the animations resume as today. |
| AP-D5 | **Nothing is persisted, and nothing is polled** (DM48, DM61). After a driver restart or a controller reboot the state is `unknown` (animations run) until the keypad's next change. A steady room may send nothing for minutes; the last reading holds until the next one: there is no staleness rule, because silence means "no change" (AP2). |
| AP-D6 | **Pausing reuses the stop paths** (edge cases 5.4): the chase gets the reason "the keypad LEDs are dark" in `why_not()` and `dark` in `inputs()`. A rest's timer is cancelled and nothing is sent. A chase in progress ends by settling its held pixels once. For Breeze, `dark` is part of "not active": gusts stop and held pixels settle once, with **no ending wipe** (leaving is false while dark). While dark, nothing is animated; steady LED changes (a speed picked, Breeze starting or ending) are still sent, because they are the fan's state (DM26, DM47). |
| AP-D7 | **Resuming starts a new run** (edge cases 5.5): the chase's first chase `FIRST_MS` after the engine sees lit; Breeze starts as it does today when Breeze begins (dark first, then the wipe in). Nothing missed is replayed. |
| AP-D8 | **The driver imitates nothing** (DM47): no `MATCH_LED_STATE` false, no black, no scaled colour stands in for the keypad's policy. It only stops sending frames. |
| AP-D9 | **One keypad.** The connection takes one Source. Several keypads on the speed links pause by the bound one (DM28 parked; the manual says so). |
| AP-D10 | **Reporting:** pauses and resumes are logged at debug (no Last Action line, DM77). `Keypad Links`' note says "LED animations paused: the keypad is dark" while dark (DM79). The new property joins the keypad LED rows that show only while a speed link is bound (#178, KL-D1). |
| AP-D11 | **The manual:** a section "Pausing the animations in the dark": bind the keypad's Ambient Light Level (Source) to the fan's Ambient Light Level (Follower); set the keypad's Status LED Min Brightness to 0 and `Pause LED Animations Below` to its Dark Room value; what pauses, what still updates, the 10 s resume hold, one keypad only, and what binding does to the keypad's Sensing (Source). |

## 2. Interfaces

`fan/ambient.lua` (agent A):

```lua
local ambient = require("fan.ambient")
ambient.LIT_HOLD_MS = 10000
ambient.BIND_SETTLE_MS = 5000
local a = ambient.new({
	now = fn,                 -- ms, any origin
	timer = fn(ms, callback), -- one-shot, returns an object with :Cancel()
	on_change = fn(dark, why),-- called when dark() changes (true/false), never at construction
	log = log,                -- default common.log
})
a:set_threshold(n)            -- AP-D2; nil/invalid -> 10; 0 never dark
a:bound(device_id_or_nil)     -- AP-D4: a bind (id) or an unbind (nil)
a:reading(params)             -- the AMBIENT_LIGHT_LEVEL params table (GROUP, LEVEL, TARGET)
a:dark()                      -- true only in state dark
a:state()                     -- "unknown" | "lit" | "dark"
a:stop()                      -- cancels the hold timer; nothing after it
a:debug()                     -- { state, level, threshold, bound, since_bind_ms, hold }
```

`fan/speedleds.lua` and `fan/breezeleds.lua` (agent B): both accept
`configure({ dark = true|false })`. Speed: `why_not()` returns "the keypad
LEDs are dark" when dark (after the existing reasons that make no chase
possible, before nothing); `inputs()` includes it. Breeze: dark makes it
inactive without the ending wipe. `debug()` of each includes `dark`.

`fan/ledrows.lua` (agent C): `Pause LED Animations Below` is a managed row.
`fan/texts.lua` (agent C): the `Keypad Links` note while dark.

`driver.lua` (coordinator): `dispatch.commands["AMBIENT_LIGHT_LEVEL"]` feeds
`ambient:reading`; `OnBindingChanged` for 500 feeds `ambient:bound`; the
property feeds `ambient:set_threshold`; `on_change` calls
`sleds:configure({dark})` and `bleds:configure({dark})` and rewrites
`Keypad Links`; `OnDriverDestroyed` calls `ambient:stop()`.

## 3. Pieces and owners

| Piece | Owner | Files |
| --- | --- | --- |
| The ambient state | agent A | `src/modernforms_fan/fan/ambient.lua` (new), `tests/spec/ambient_spec.lua` (new) |
| The pause in both engines | agent B | `src/modernforms_fan/fan/speedleds.lua`, `src/modernforms_fan/fan/breezeleds.lua`, `tests/spec/speedleds_spec.lua`, `tests/spec/breezeleds_spec.lua` |
| The managed row, the note, the manual | agent C | `src/modernforms_fan/fan/ledrows.lua`, `tests/spec/ledrows_spec.lua`, `src/modernforms_fan/fan/texts.lua`, `tests/spec/texts_spec.lua`, `src/modernforms_fan/www/documentation.html` |
| The connection, the property, the wiring, changelog, status, codename | coordinator | `src/modernforms_fan/driver.xml`, `src/modernforms_fan/driver.lua`, `tests/spec/fan_driver_spec.lua`, `CHANGELOG.md`, `docs/status.md`, `docs/README.md`, `.github/codenames.json`, `.github/codename-meanings.json` |

## 4. Control4 guidelines

| Guideline | How this meets it |
| --- | --- |
| Keypad dimming is the keypad's (speed-leds-design section 7) | Met: the keypad's own profile decides how bright its LEDs are; the driver only stops sending frames the profile would show as nothing. |
| The LED follows the device | Met for the steady LEDs, which still follow every change of the fan. The animation, already a departure, pauses. |
| No polling of devices | Met: the keypad pushes on change; the driver asks nothing. |
| Documented APIs only | **Departure:** the class `AMBIENT_LEVEL` and the command `AMBIENT_LIGHT_LEVEL` are in no SDK document; they are measured (section 0). The entry points used (`ExecuteCommand`, `OnBindingChanged`) and the connection XML are documented. Unbound, the driver behaves as before, so a firmware or OS that sends nothing leaves today's behaviour. OS 4.x is unchecked and parked. |

## 5. House checks (after the release, not blocking it)

The Windows session binds the keypad dimmer's Ambient Light Level (Source)
to the fan's Ambient Light Level (Follower) and sets `Pause LED Animations
Below` to 10. In the dark room the driver's debug log, or `Keypad Links`,
shows the pause; a lamp switched on resumes the chase after about 10 s.
