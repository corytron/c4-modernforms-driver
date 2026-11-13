# Breeze LED animation: what the SDK allows

> **Status (2026-11-13, #213).** Approach B was built in 1.4 (#137) by
> [`breeze-leds-design.md`](breeze-leds-design.md). The SDK findings stand.
> The house probes of 2026-11-09 (that contract's section 1a) answered H1,
> H4 and H12, and H2 in part: `BUTTON_COLORS` with `CURRENT_COLOR` repaints a lit button
> at once, and without it leaves a dark button dark (a colour can be
> preloaded); about 40 messages a second over four buttons stayed even; pure
> blue `0000ff` vanished at night, so the keypad does scale link colours.
> Off does not join the animation (BL-D2), so the house has four pixels,
> Low to High, not the five of section 3; and the house keypad has Low at
> the top, the reverse of the order section 3 assumed (BL-D4,
> `Breeze LED Bottom` = `Highest speed`). The active and inactive
> brightness of summary item 9 and section 8 does not exist: the Composer
> read of 2026-11-12 found one status LED curve over the ambient reading
> ([`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md)
> section 1.4). The keypad also has an Ambient Light Level (Source)
> output, and since 1.9 (#207) the driver takes the keypad's reading from it
> through a consumer of class `AMBIENT_LEVEL`, an undocumented route
> measured on the house ([`ambient-pause-design.md`](ambient-pause-design.md)
> section 0).

Research for [issue #137](https://github.com/corytron/c4-modernforms-driver/issues/137),
written 2026-11-08. The owner wants the keypad buttons bound to the fan to
play a bottom-to-top animation in blues, teals and whites while Breeze
blows, and every LED back to its normal state when Breeze ends. The owner
has since chosen the driver-side approach (B: the driver animates its own
links); the Composer-only approach (A) is kept short in section 5. This note
says what the Control4 SDK documentation and this driver's code allow, and
what only a test on the keypad can settle. It is desk research: nothing was
sent to any device.

**Sources and status key.** SDK files are cited by path under
`~/c4-tools/reference/`: **KPD** `docs-driverworks-proxyprotocol-keypad/source/includes/`,
**LV2** `docs-driverworks-proxyprotocol-lightv2/source/includes/`,
**API** `docs-driverworks-api/source/includes/`,
**FUND** `docs-driverworks-fundamentals/source/includes/`,
**PP** `docs-driverworks-proxyprotocol/source/includes/`. The SDK text is
summarised, never copied. House facts come from
[`v1-design.md`](v1-design.md) section 11.1 (probe checks K6, K7, K8, K14)
and [`edge-cases-control4.md`](edge-cases-control4.md) (ECC rows). Code is
`src/modernforms_fan/fan/links.lua` (named by function). **VERIFIED** names
its source; **ASSUMED** says why; **SILENT** means the SDK says nothing.
Placeholders: "Example Keypad" (device 456), "Example Room", "Aviator 5".

## Summary

1. **Over a Button Link a driver has exactly two documented levers:**
   `MATCH_LED_STATE` (which of the button's two stored colours shows) and
   `BUTTON_COLORS` (the on and off colours). Both work on the house keypad,
   and a colour change shows at once when it is followed by
   `MATCH_LED_STATE` (VERIFIED: KPD 62/_1; house K6).
2. **Not known:** whether `BUTTON_COLORS` alone repaints a button without
   a following `MATCH_LED_STATE`, and whether one link message reaches every
   button on that link. Both are one-minute hardware tests (H1, H3).
3. **The cheapest fluid animation uses only verified behaviour:** a lit band
   that climbs, recolouring a button while it is dark and then lighting it.
   Three link messages per frame whatever the number of buttons (section 6).
4. **The keypad proxy's own commands** (`KEYPAD_BUTTON_COLOR`,
   `KEYPAD_BUTTON_INFO`, addressed by device id with `C4:SendToDevice`) also
   exist, but they reach any button and can rewrite a dealer's settings; the
   link messages are enough and stay inside what the owner bound.
5. **The driver cannot learn button positions:** nothing documented tells a
   load where a bound button sits on the keypad. Order must come from a
   convention (link order) or a property.
6. **Timers:** `C4:SetTimer` takes milliseconds, must be above 0, can
   repeat, and skips beats when Director is busy; no minimum or resolution
   is documented. The SDK warns that fast periodic light updates flood
   Zigbee and leave keypad LEDs wrong (FUND light_v2 best practice).
7. **Restore is exact only for colours the driver owns** (speed links with
   `Per speed`). It never knew the keypad's own colours (Off, Toggle, Cycle,
   Breeze, or any link with `Keypad's own`), and nothing documented reads
   them back, so the animation must not repaint those links.
8. Everything needed exists on OS 3.0 and later; nothing is OS 4-only.
9. **LED brightness and ambient light are absent from the SDK.** No
   documented message sets or reads a keypad's LED brightness. The
   animation therefore respects the keypad's dimming by using the lit state
   as the keypad does: a glowing position is lit in its frame colour (the
   active brightness), a dark one is dark in the resting off colour (the
   inactive brightness). It never touches an off colour, which also makes
   the restore three steps and a restart self-healing (sections 6, 8).

## 1. Every documented way to change a keypad button's LED

The keypad proxy documents two directions inside one keypad device: its
"proxy commands" go from the keypad proxy to the keypad's own protocol
driver, and its "protocol notifications" go back (KPD
`2_introduction/_1-INTRODUCTION.md`). A Control4 keypad dimmer is one
protocol driver with two proxies, a `light_v2` for the load and a
`keypad_proxy` for the buttons (VERIFIED: API
`22_miscellaneous/_9-GetDevices.md`, its keypad dimmer example). Button
Links, added in OS 3, are the separate channel between a keypad button and
another driver (KPD `3_whats_new/_20-WhatwasNewinOS3.md`,
`62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`).

| # | Way | How a driver sends it | Parameters, colour format | Changes | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | `MATCH_LED_STATE` on a link | `C4:SendToProxy(link, "MATCH_LED_STATE", {STATE = bool}, "COMMAND")` (`links:send_led`) | `STATE` true = on colour, false = off colour | the lit state only | VERIFIED: KPD 62/_1 (listed under the link's notifications); house: sent as a COMMAND it lights and darkens Follow Connection buttons (ECC F15, K6) |
| 2 | `BUTTON_COLORS` on a link | `C4:SendToProxy(link, "BUTTON_COLORS", {...}, "NOTIFY")` (`links:send_colors`) | `ON_COLOR`, `OFF_COLOR` as 6-digit hex such as `0000ff` (KPD 62/_1); the driver also sends `CURRENT_COLOR`, after Snap One's light template (`src/common/device.lua`), which KPD does not list | the stored on and off colours | VERIFIED: KPD 62/_1; house K6: red, then blue while lit, each followed by `MATCH_LED_STATE` true. Repaint without that follow-up: not tested (H1) |
| 3 | `SET_BUTTON_COLOR` on a link | listed among the link's commands | one parameter, the button id as a string; no colour fields | unclear | KPD 62/_1 says neither who sends it nor what it sets; the driver logs and ignores incoming ones (`links:set_button_color`). ASSUMED unusable for painting |
| 4 | `KEYPAD_BUTTON_COLOR` | `C4:SendToDevice(keypad proxy id, ...)` | `ON_COLOR`, `OFF_COLOR`, `CURRENT_COLOR` (the colour to show at once); the table omits the button id and its descriptions are garbled | on, off and the shown colour of one button | doc: KPD `60_keypad_proxy_commands/_5-KEYPADBUTTONCOLOR.md`. ASSUMED to work by this route: only `KEYPAD_BUTTON_ACTION` was sent this way on the house (K7, keypad Proxy ID and `BUTTON_ID`) |
| 5 | `KEYPAD_ALL_BUTTON_COLOR` | as 4 | the same three colours, typed INT in the table but hex strings in the matching notification (KPD 61/_5) | every button of the keypad, fan or not | KPD 60/_3. Off-limits: it repaints buttons the driver does not own |
| 6 | `KEYPAD_BUTTON_INFO` | as 4 | button id, name, on and off colours, engraving, button behaviour, LED behaviour, `STATE`, `MATCH LED STATE` | lit state, colours, and the button's settings | KPD 60/_6. Forbidden for us: it can rewrite a dealer's settings (ECC C4: the driver never touches a keypad's settings) |
| 7 | `KEYPAD_BUTTON_COLOR_CLEAR`, `KEYPAD_ALL_BUTTON_COLOR_CLEAR` | as 4 | as 4 | clears a colour set "programmatically" | KPD 60/_3.5, _3.6 and `61.1_keypad_capabilities/_1-clearledcurrentcolorsupport.md`: OS 3.4.2 and later, and only on a keypad whose protocol declares `clear_led_current_color_support` (SILENT on whether Control4's own keypads do) |
| 8 | `KEYPAD_BUTTON_ACTION` | as 4 | `ACTION` 0 release, 1 push, 2 click; button id | presses the button: drives its link and fires its programming | KPD 60/_4; house K7. Not an LED tool |
| 9 | light_v2 `SET_BUTTON_COLOR` | a command the light_v2 proxy sends to its own protocol driver | button id, optional `ON COLOR`, `OFF COLOR`, 6-digit hex | a light_v2 device's own buttons, ids 0 top, 1 bottom, 2 toggle (LV2 `10_light_v2_commands/_1-BUTTONACTION.md`) | LV2 `10_light_v2_commands/_12-SET_BUTTON_COLOR.md`; house K8: the proxy sends it for ids 0 to 2 from the light's colour settings (`has_leds`). On a keypad dimmer the configurable buttons sit on the `keypad_proxy`, so ASSUMED it does not reach Low…Off |
| 10 | light_v2 `SET_ALL_LED` | as 9 | `COLOR`, 6-digit hex | all of that light's buttons, on and off colour alike | LV2 `_13-SET_ALL_LED.md`; same limit as 9 |

The keypad's programming commands seen in Composer on 2026-10-27 ("Set LED
On/Off color", "Use the on/off color for …") are Composer's, not the SDK's.
How they map onto rows 4 to 7 is SILENT.

**Cost of one change.** Each row is one Director message. The SDK says
nothing about what reaches the keypad's radio (SILENT). ASSUMED: each link
message becomes at least one Zigbee packet to a Zigbee keypad, in order.

**(a) The cheapest message per frame.** `MATCH_LED_STATE` flips a button
between two colours already stored on it: one message, verified. A
`BUTTON_COLORS` with the same colour as on and off would make the lit state
irrelevant, so one message per button and frame, **if** the keypad repaints
on it. But a dark button would then show the frame colour at the inactive
brightness, so section 8 rules this out. The SDK hints that it may not on its own: its answer to
`REQUEST_BUTTON_COLORS` is both messages, colours then state (KPD 62/_1),
and K6 always sent the state afterwards. So:

- recolouring a **dark** button and then lighting it costs two messages and
  relies only on K6 (`BUTTON_COLORS`, then `MATCH_LED_STATE` true showed
  the new colour);
- recolouring a **lit** button costs two messages (`BUTTON_COLORS`, then
  `MATCH_LED_STATE` true again; K6 did exactly this, red to blue);
- recolouring with `BUTTON_COLORS` alone costs one, unverified (H1).
- `CURRENT_COLOR` might be a "show this now" field that leaves the stored
  pair alone, as in `KEYPAD_BUTTON_COLOR` (row 4). Not documented for the
  link (H2).

## 2. LED Behavior: which source wins

The SDK never names Follow Connection, Follow Load, Push/Release or
Programmed. It only carries an integer `LED BEHAVIOR` in the keypad
messages (KPD 60/_6, 60/_8, 61/_7, 61/_9) and lets a protocol name its
behaviours (KPD 61/_8). **SILENT** on precedence, with one hint:
`KEYPAD_BUTTON_INFO` has both `STATE` (use the on or the off colour) and
`MATCH LED STATE`, which applies only while the LED follows a bound device
(KPD 60/_6). Read with the house facts:

- Binding a link sets the button to Follow Connection by itself, and a
  disconnect leaves the setting and the last LED as they were (VERIFIED:
  ECC F16, C4; K6).
- A link's `MATCH_LED_STATE` drives a Follow Connection button (VERIFIED:
  F15, K6).
- A Programmed LED command ("Use the on color for Medium") still acts on a
  Follow Connection button (VERIFIED: K14).
- With Echo LED On Press, the button lights at the push and darkens at the
  release (VERIFIED: K6).
- ASSUMED: the last message wins among link, programming and echo; a link's
  state is ignored on a button set to Programmed (the `MATCH LED STATE`
  hint). H6 settles the second.

For approach B: the buttons must stay on Follow Connection (binding does
that), and the owner's remaining keypad programming must not paint the fan
buttons. On the house the only lines left are Low's and High's Double Tap,
which set the fan's level and paint nothing (ASSUMED from the brief).

## 3. What a driver may address

**Over links: only buttons bound to its own links.** A link is a provider
binding of the driver; its messages go to the consumers bound to it, and
the receiver tells buttons apart by binding id (VERIFIED: KPD 62/_1; API
`25_proxy/_6-SendToProxy.md`). `C4:GetBoundConsumerDevices(C4:GetDeviceID(),
link)` returns the bound devices, keyed by device id, never buttons
(VERIFIED: API `32_serial_network_device/_3-GetBoundConsumerDevices.md`;
`links:read_bound`). `OnBindingChanged` also gives the other side's binding
id (API `9_helper/_12-OnBindingChanged.md`), which `links:binding_changed`
already keeps per keypad (#92).

**By device id: any device.** `C4:SendToDevice` sends a command to any
device id; nothing restricts it to bound devices (VERIFIED: API
`32_serial_network_device/_19-SendToDevice.md`). That is how rows 4 to 8
would reach a keypad, and `C4:GetDevices` finds a keypad dimmer's
`keypad_proxy` id from its protocol device (API `22_miscellaneous/_9-GetDevices.md`).
How a link's binding id maps to a keypad button id is SILENT. Approach B
needs none of this.

**(b) One link message, several buttons.** SILENT. `SendToProxy` speaks of
"the proxy bound" in the singular, while a link may list several consumers
(API 32/_3). ECC C6 already assumes a link message reaches every bound
keypad; K5 bound Up and Medium to one fan proxy speed link in turn, and
Up has no LED, so it proves nothing. ASSUMED: yes, so buttons on
one link light in step, across keypads too; a frame then costs per link,
not per button. H3 settles it.

**(c) The physical order of the buttons.** Nothing documented tells a
load where a bound button sits:

- The link carries only presses and `REQUEST_BUTTON_COLORS` in, colours and
  state out (KPD 62/_1); no name, id or position.
- `NEW_KEYPAD_BUTTON` and `KEYPAD_BUTTON_INFO` carry a button id, name,
  colours, behaviours and `SLOTS` (the button's size), never a row or a
  position (KPD 61/_9, 61/_7), and they pass from the keypad's protocol to
  its own proxy, not to a bound load (KPD introduction).
- The keypad proxy documents no variables, so `C4:GetDeviceVariable` (API
  `36_variable/_5-GetDeviceVariable.md`) has nothing documented to read.
- `C4:GetBindingsByDevice` (OS 3.0+) returns "binding information" whose
  fields for control bindings are SILENT (API
  `32_serial_network_device/_2.5-GetBindingsByDevice.md`).
  `C4:GetBoundPartner` exists only from OS 4.0.0 (API
  `9_helper/_5.8-GETBOUNDPARTNER.md`).

So the order is the driver's **link order** (Off, Speed 1 to 6, then
Toggle, Cycle, Breeze), which matches a fan keypad laid out with Off at the
bottom and the highest speed at the top (ASSUMED for the house: H5), with a
property to reverse it or list the links in order. Since a frame is per
link (b), the order is per link anyway. Up and Down (Light Top and Bottom)
have no LED on the house keypad (VERIFIED: `v1-design.md` 5.4), so the
house animation has five steps: Off, Low (302), Medium (303), Med-High
(304), High (305).

## 4. Timers and message rates

**(d)** What the SDK documents:

- `C4:SetTimer(ms, callback, repeat)`, OS 2.7.0+: the delay is in
  milliseconds and must be above 0; with `repeat` true it fires until
  cancelled, and its callback gets a skip count when Director was too busy
  to serve it on time; it returns an object with `:Cancel()`. Not callable
  in `OnDriverInit` (VERIFIED: API `34_timer/_1-SetTimer.md`; the driver
  calls it from late init on, `driver.lua` `timer`).
- **No minimum interval and no resolution are documented** (SILENT). The
  same page says Director skips rapid timers it cannot keep up with,
  rather than queueing them, and that before this change a 1 to 100 ms
  repeating timer could lock Director up. So fast timers are possible but
  not guaranteed, and the driver's Lua runs on Director's time (ASSUMED: one
  thread per driver; the SDK never says).
- `C4:AddTimer` / `C4:KillTimer` with `OnTimerExpired` are the legacy
  interface, still valid but not recommended since OS 3 (VERIFIED: API
  `3_whats_new/_20-WhatwasNewinOS3.md`); this copy of the SDK has no
  reference page for them.
- `C4:GetTime()`: milliseconds since the epoch from OS 3.2.3, units and
  fractions from 4.0.0 (VERIFIED: API `34_timer/_2-GetTime.md`). Under the
  driver's minimum OS 3.3.0 the millisecond form is safe.

**Message rates.** Nothing about keypad LED update rates or Zigbee message
rates (SILENT). Two related warnings:

- Drivers that used to send light-level updates every 20 ms caused slow
  proxies and Director, excessive Zigbee traffic, often wrong keypad button
  LEDs and spurious programming (VERIFIED: FUND
  `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`).
- Navigator volume commands go every 750 ms by default; a driver may lower
  that, but under 200 ms is not recommended (VERIFIED: PP
  `116_proxy_and_protocol_best_practices/_4-OS3NAVIGATORUIANDVOLUMECONTROL.md`).
  A different device class, but the only number the SDK gives.

ASSUMED from both: link messages at a few per second are safe, tens per
second are risky on a Zigbee keypad. H4 measures it.

## 5. Approach A, Composer only (short)

Handles on the fan item (`src/modernforms_fan/driver.xml`): events Breeze
Started (4) and Breeze Stopped (5), conditional `BOOL_BREEZE` "Breeze is
on", variable `Breeze`, commands Breeze On, Breeze Off, Toggle Breeze, Set
Breeze Strength; the fan proxy's own events. Composer copies each
conditional into a Loops tab as a "while" statement, and the SDK warns that
loops can be expensive (VERIFIED: FUND `10_conditionals/_1-OVERVIEW.md`).
The SDK says nothing about Composer's Delay or Timer agent (SILENT; the
web agent covers them). Two limits from the driver's code: the events fire
when the fan *confirms* (`Breeze:settled` in `fan/breeze.lua`) while the
LEDs follow the *shown* state at once (V10, `listener.shown`), so the
driver's restore goes out before Breeze Stopped reaches programming, and
a loop mid-frame paints over it; and programming would have to repeat
every per-speed colour to restore them.

## 6. Driver-side sketch (approach B)

**Start and stop.** `links:shown(shown)` already sees every shown change.
Start when `mode.breeze(shown)` turns true, stop when it turns false
(`fan/mode.lua`), the same test as link 311's LED. A tap into or out of
Breeze then starts or stops the animation at once, before the fan
confirms, and a refused request puts it back (V10).

**Frame cost** for N animated links (one message per link reaches all its
buttons, if H3 holds):

| Scheme | Messages per frame | Relies on |
| --- | --- | --- |
| Chase, colours preloaded once (N `BUTTON_COLORS` at start): the head lights, the tail darkens | 2 | K6 |
| Chase, the head recoloured while dark, then lit; the tail darkened | 3 | K6 |
| Comet: w lit links recoloured each frame, the tail darkened | 2w + 1 | K6 (lit recolour) |
| Every link recoloured each frame, colours then state | 2N | K6 |
| Every link by `BUTTON_COLORS` alone, on = off = frame colour | N | ruled out (section 8) |

Five links at 200 ms per step: 10, 15, 35 (w = 3) and 50 messages a
second. The second row moves the colours (blue, teal, white climbing) for
the price of a fixed band. In every scheme the frame colour goes out as the
**on** colour only. The off colour stays `Speed LED Off Color`, so a dark
button looks as it does at rest, at the keypad's inactive brightness
(section 8). A link may be recoloured only if the driver knows its resting
on colour for every speed that lights it (its own and its `Also Lit At`).

**Timer.** One timer at a time, re-armed each frame with the driver's
existing one-shot `timer` (a missed beat then costs no backlog), or a
repeating `C4:SetTimer` that uses its skip count. The frame index comes
from `C4:GetTime()` so a late beat jumps ahead. The step time has a floor
set by H4.

**(e) Restore, with the existing code.** At stop:

1. Cancel the frame timer.
2. Clear `led[link]` and `led_speed[link]` for the animated links, so
   nothing counts as already sent.
3. Call `links:refresh()`: `push_led(link, shown, true)` for all ten fan
   links sends `BUTTON_COLORS` (`send_colors`: the speed's on colour,
   `off_color`, `CURRENT_COLOR` = on) before `MATCH_LED_STATE` to a lit
   speed link with `Per speed`, and `MATCH_LED_STATE` to every link, with 311
   from `breeze_blows()`. A dark link shows its untouched off colour. Its
   on colour is still the last frame's, but that shows only when it lights,
   and `push_led` sends the right one then because `led_speed` is clear.
4. **Links whose colours the driver never knew** (300, 307, 308 and 311
   always, BC27; every link under `Keypad's own`): the animation must
   never send them `BUTTON_COLORS`. Nothing documented reads a keypad's
   own colours back (KPD 62/_1 has no such message), so they could not be
   restored. They may join through `MATCH_LED_STATE` alone (lit in their own
   colour, the Off button's dark red on the house), stay out, or get colour
   rows of their own, a choice for the contract.

Cost: one colour message (the lit link, if any) and ten state messages,
once. No new send function is needed.

**During the animation** (proposed): `links:shown` keeps its tables but
sends nothing to animated links; `answer(link)` (a new binding or
`REQUEST_BUTTON_COLORS`) answers with the current frame and adds the link
to the animation; `set_colors` and `set_also` update the tables, which go
out at the restore.

**Stopping cleanly elsewhere.**

- Breeze Stopped, a switch to fan mode, Off: the shown change above (steps
  1 to 3).
- `OnDriverDestroyed` (an update, a dev reload, a Director restart):
  `links:stop()` cancels the timer. Whether `SendToProxy` still works there
  is SILENT, so the restore cannot rely on it. The keypad keeps the last
  frame (ASSUMED; H8) until the first contact. That contact already sends
  every fan link (`led` starts empty, so `links:shown` treats each as
  changed). Off colours were never touched, so it restores the keypad
  without a persisted flag; if Breeze still blows, the animation starts
  again.
- Unbound mid-animation: the button keeps its last frame (F16, C4), and the
  driver can no longer reach it. The manual says so.
- Offline: the shown state stays (ECC Q5). Keep animating, or stop to save
  traffic: a choice for the contract.

**A general feature, not a one-off.** Options only, no capabilities, so
no reboot (as `Speed LED Colors`, V27): an on/off row (default off, so no
keypad changes on update), a step time with a floor, three
`COLOR_SELECTOR` palette rows (FUND `15_composerpro_interface_into_the_sdk/_5-COLORSELECTOR.md`),
a direction or link order, and whether 311 animates or stays lit. Without
`Per speed` it falls back to a chase in each button's own colours
(`MATCH_LED_STATE` only), since the driver owns no colours then. It acts on
its own for the life of the system, so it needs the edge-case pass first
(CLAUDE.md, "Edge cases before automation").

## 7. OS 3.3 and 3.4 versus OS 4.x

- Approach B uses only `SendToProxy`, `BUTTON_COLORS`, `MATCH_LED_STATE`
  (OS 3.0+), `SetTimer` (2.7.0+) and `GetTime` in milliseconds (3.2.3+): all
  inside the 3.3.0 minimum (KPD `3_whats_new/_20-WhatwasNewinOS3.md`; API
  34/_1, 34/_2). The keypad proxy's change log lists no changes from 3.1
  to 3.4.2 (though KPD 61.1/_1 dates one capability to 3.4.2) and has no
  4.x entries (KPD `3_whats_new/`; SILENT on 4.x).
- 4.0.0 and later only: `GetBoundPartner`, `GetCapabilityById`,
  `GetProtocolDeviceById`, `GetTime`'s units (API
  `3_whats_new/_7-WhatsNewin400.md`). Nothing here needs them.
- 3.4.2 and later only: the Clear LED Current commands (row 7). Not usable
  on 3.3.x, and not needed.
- Risk on every OS: Zigbee traffic and wrong LEDs (FUND light_v2 best
  practice), Director load from fast timers (API 34/_1).
- Approach A: Composer's programming across versions is outside the SDK
  (SILENT).

## 8. LED brightness and ambient light

> Since 2026-11-12 (#198): the keypad has no "active" and "inactive" LED
> level, only one status LED curve over the ambient reading, and its
> Ambient Light Level connections include a (Source) output besides the
> input read here; see
> [`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md)
> section 1.4.

**What the SDK says: nothing (SILENT).** No API, FUND, KPD, LV2, PP or XML
file mentions ambient light, a light sensor, LED or backlight brightness,
active or inactive LED levels, automatic dimming or night levels; a
full-text search for these terms finds only unrelated hits. The link
carries colours and a lit state and nothing else (KPD 62/_1, which also
calls the link a plain passage, so undocumented messages cannot be ruled
out). No keypad proxy command or notification has a brightness field
(KPD 60, 61). A driver therefore has no documented way to set, read or
override a keypad's LED brightness, and the animation sends none.

**What is known from elsewhere.** The owner's Hue project records that OS
3.2.2 added an ambient-light "source and follower" feature for button
backlights (HUE `docs/motion-control4-research.md` section 3.2, verified
there from Control4's release notes). It also records that a third-party
sensor offers an `AMBIENT_LIGHT_LINK` output that probably feeds it
(ASSUMED there, community source). The keypad's own brightness settings
(active and inactive levels, night levels, whether it follows its sensor
or a source) belong to Composer and the keypad driver, not the SDK; H11
reads their names and values.

**Does the keypad scale the colours a load sends?** SILENT. ASSUMED yes:
the keypad treats a link colour as a colour and applies its own
brightness for the state shown, the on colour at the active level and the
off colour at the inactive level. Two reasons: the link has no brightness
field, so a load cannot know the level; and the keypad's own button
colours are the same 6-digit colours (KPD 61/_9), which a dealer sets once
for day and night. So the driver sends full colours (`0000ff`, `00c0c0`,
`ffffff`) and the keypad dims them. K6 recorded the colours but not their
brightness. H12 settles it.

**The "Ambient Light Level" row.** K19 saw it among the keypad's *Control
Inputs* (VERIFIED-house: `v1-design.md` 11.1). An input is a consumer
binding on the keypad, so through it the keypad *takes* a light level from
a provider, such as another keypad acting as source or a sensor. Its class
was not recorded; `AMBIENT_LIGHT_LINK` is likely (ASSUMED from the Hue
research; H10 reads it).
- *Bind to it:* a driver could only declare a provider connection of that
  class and become the keypad's light source. The protocol over it is
  SILENT, and the driver's numbers would replace the keypad's own sensor.
  Forbidden: it is the opposite of respecting the keypad's dimming.
- *Read the level:* no documented route. The input belongs to the keypad.
  A load sees none of its messages, and the keypad proxy documents no
  variable for `C4:GetDeviceVariable` (API 36/_5).
- *Use here:* none. The keypad applies its dimming by itself; the
  animation needs no level to respect it.

**Which lit state the animation uses.** A position that should glow is
**lit**: `BUTTON_COLORS` with the frame colour as on colour and the
resting off colour, then `MATCH_LED_STATE` true. It then shows at the
active brightness, like any lit button at that hour. A position that
should be dark is **dark**: `MATCH_LED_STATE` false, showing the resting off
colour (`Speed LED Off Color`, `000000` on the house) at the inactive
brightness, which may be very low or zero, as at rest. Consequences:
- The one-message scheme (on = off = frame colour) is out. A dark button
  would glow in the frame colour at the inactive level: invisible where
  that level is zero, too bright where it is high.
- The off colour is never changed, so dark buttons always look as they do
  at rest. That is what reduces the restore to three steps (section 6).
- A tail in darker RGB values (`004060` behind `00c0c0`) is possible, but
  how a dark colour looks at a low active level is unknown (H12). The
  palette rows default to full colours.
- When the ambient light changes mid-animation the driver does nothing
  (ASSUMED: the keypad re-applies its level to whatever it shows).
- `ffffff` at the active level is the brightest colour on the keypad. A
  palette row lets the owner tone it down.

## Open questions for the hardware

Each runs in under a minute from a `--dev` build's Lua command window (or
the probe) on the house keypad. The link of the button under test comes
first; no keypad setting is changed unless the test says so. Afterwards
the driver's normal LEDs are sent again (`links:refresh()`).

| # | Question | Test |
| --- | --- | --- |
| H1 | Does `BUTTON_COLORS` alone repaint? | Fan at speed 3 (Medium lit): send `BUTTON_COLORS {ON_COLOR=00ffff, OFF_COLOR=000000, CURRENT_COLOR=00ffff}` on 303, no state. Teal at once? Then on dark 304: `{ON_COLOR=ffffff, OFF_COLOR=0000ff, CURRENT_COLOR=0000ff}`. Blue at once? |
| H2 | Is `CURRENT_COLOR` a momentary colour? | Medium lit in its own colour: send `BUTTON_COLORS` with its own on and off colours and `CURRENT_COLOR=ffffff`. White? Then `MATCH_LED_STATE` true: back to its on colour? |
| H3 | Does one link message reach every button on it? | Needs two LED buttons on one link (a spare button on another keypad bound to 303 too). One `MATCH_LED_STATE` true: both light? If no spare button exists, H3 stays ASSUMED. |
| H4 | How fast can the keypad follow? | A five-link chase (second scheme) for 10 s each at 300, 200, 150 and 100 ms per step. Watch for lag, missed steps or a wrong final state after the restore. |
| H5 | The physical order | Read-only: the keypad's layout top to bottom (Composer's keypad view or the owner), and the binding numbers in Keypad Links against Composer's button ids. |
| H6 | Does a link drive a Programmed button? | Set Medium's LED Behavior to Programmed, send `MATCH_LED_STATE` true on 303, then set it back to Follow Connection. |
| H7 | Does `BUTTON_COLORS` overwrite the dealer's colour setting? | After H1, read Medium's colour settings in Composer: the old colours or teal? |
| H8 | What the keypad shows after the driver dies mid-frame | Start the chase, then `devctl reload`. Do the buttons keep the last frame until the first contact? |
| H9 | Does a keypad send its own colours to a link? | With debug logging, change the Off button's on colour in Composer and back. Does `SET_BUTTON_COLOR` arrive on 300, and with which fields? If it carries colours, the links of restore step 4 could be restored. |
| H10 | What is the Ambient Light Level row? | Read-only in Connections: its class, input or output, and what it is bound to (if anything). |
| H11 | The keypad's brightness settings | Read-only: the keypad's Properties (and Advanced pages) for LED brightness, active and inactive levels, night levels and the ambient sensor; names and current values. |
| H12 | Does the keypad dim link colours? | In a dim moment (or a hand over the keypad's sensor), with the fan at speed 2: send 303 `BUTTON_COLORS {ON_COLOR=00c0c0, OFF_COLOR=000000, CURRENT_COLOR=00c0c0}` and `MATCH_LED_STATE` true. Does teal Medium dim with Low (lit at speed 2) when the light drops, and brighten again with it? Then `MATCH_LED_STATE` false on 303: is it dark as Med-High is? |
