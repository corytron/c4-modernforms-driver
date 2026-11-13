# Keypad LED rows only with a keypad: design contract

> **Contract for [issue #178](https://github.com/corytron/c4-modernforms-driver/issues/178)**
> (2026-11-10). The research behind it:
> [`edge-cases-keypad-leds-visibility.md`](edge-cases-keypad-leds-visibility.md)
> (facts KF1 onward, cases KV1 to KV48, the owner questions with their
> defaults) and [`keypad-leds-visibility-sdk-research.md`](keypad-leds-visibility-sdk-research.md)
> (the API and how the Hue drivers already do it on the house). Placeholders
> only: fan 10.0.2.151, controller 10.0.2.10.

> **Status (2026-11-13, #213).** Shipped in 1.7 "Stillsuit" (build 193,
> with KL-D11's fix, #185) and holds today. Since 1.9 a 21st managed row
> follows the gate alone: `Pause LED Animations Below`
> ([`ambient-pause-design.md`](ambient-pause-design.md) AP-D10, #207), and
> while the animations pause the `Keypad Links` note reads `; LED
> animations paused: the keypad is dark` in place of `; LED settings
> shown`. Section 4's checks ran on 2026-11-10: the scratch device's rows
> hid by themselves about 15 s after the add and the house fan kept every
> row ([`status.md`](status.md)).

The owner asked that the keypad LED work (the per-speed colours, the Breeze
animation, the speed chase) show up in Composer only when a keypad is linked
to the driver, with clear instructions for both cases, easy to disable, and
"same for breeze modes".

## 1. Decisions

| # | Decision | Why |
| --- | --- | --- |
| KL-D1 | **The managed rows** (20): `Speed 1` to `Speed 6 Link Also Lit At`, `Speed LED Colors`, `Speed 1` to `Speed 6 LED Color`, `Speed LED Off Color`, `Breeze LED Animation`, `Breeze LED Bottom`, `Breeze LED Step (ms)`, `Breeze LED Night Brightness (%)`, `Speed LED Animation`, `Speed LED Rest (s)`. `Keypad Links` is never hidden. | KV short answer 1. |
| KL-D2 | **The gate:** the rows are shown while at least one device is bound to a fan speed link (301 to 306), whatever the device: no documented API tells a colour keypad from another consumer on OS 3.x, and an unknown kind counts as a colour keypad (fail open). Off, Toggle, Cycle, Fan Breeze (311) and the light's links do not count: they never take the driver's colours. | SDK research 3; KV short answer 3. |
| KL-D3 | **Breeze:** the three Breeze-only rows (`Breeze LED Animation`, `Step (ms)`, `Night Brightness (%)`) also need a fan that reports Breeze; while that is not known yet they follow the gate alone. `Breeze LED Bottom` follows the gate alone (the chase uses it too). | Owner: "same for breeze modes"; Q2 default. |
| KL-D4 | **Show at once, hide late.** A change that shows rows takes effect at once. A hide waits until "nothing bound" has held for `HIDE_MS` = 8,000 ms without a break (the links' own second look at start is 5 s and their re-read after an unbind 3 s, plus a grace), so a binding that is only being re-read never flickers the rows. | KV short answer 2. |
| KL-D5 | **Display only.** Showing or hiding never writes a value, never sends an LED message and never starts or stops an animation; hidden values are kept, still applied, and saved with the project. Without a bound speed button both animations are already idle; they resume with the kept settings when one is bound again. | KV short answer 4. |
| KL-D6 | **How the call is made:** `C4:SetPropertyAttribs(name, 1)` hides, `0` shows; never in `OnDriverInit`. Every managed row's state is sent at late init and after each change, **400 ms after** any row text update of the same moment and **again at 1,500 ms**, because Composer on the house dropped visibility changes sent in the same burst as text updates (the Hue drivers do the same). Rows that did not change are sent too in those two sends (idempotent). | SDK research 1; KF2, KF4. |
| KL-D7 | **Instructions in Composer.** The `Keypad Links` summary ends in `; LED settings shown` or `; LED settings hidden: bind a button to a Fan Speed link`. A change of visibility caused by a binding (never the late-init replay) writes one Last Action line: L44 `Keypad LED settings shown: a button is on a Fan Speed link` or L45 `Keypad LED settings hidden: no button on a Fan Speed link`. | KV short answer 6. |
| KL-D8 | **Easy off:** `Speed LED Animation` = `Off` and `Breeze LED Animation` = `Off` each stop their animation at once with one Set and leave the keypad's stock behaviour (Follow Connection). No master row, no programming command, no "always show" switch. `Speed LED Colors` = `Keypad's own` is documented as the way back to the keypad's own colours, with its limit (the keypad keeps the last colours it was sent until its own button colours are set again in Composer; no API gives them back, KV40). | KV short answer 5; Q3, Q6 defaults. |
| KL-D9 | **On the house nothing changes:** its keypad is bound to Fan Speed 2 to 5, so every row stays shown. | KV short answer 8. |
| KL-D10 | No `<capabilities>` change; no new property rows. | No controller reboot. |
| KL-D11 | **The unbind must be believed** (#185): the links' reread after an unbind treats Director's `nil` as unknown once and as nothing bound the second time, as the second look at late init does, so a hide follows an unbind about 6 s plus `HIDE_MS` later. | Found while building this; without it the rows never hid after an unbind. |

## 2. Interfaces

### 2.1 `fan/ledrows.lua` (new, pure)

```lua
local ledrows = require("fan.ledrows")
ledrows.ROWS      -- the 20 managed row names in driver.xml order
ledrows.BREEZE    -- { ["Breeze LED Animation"] = true, ["Breeze LED Step (ms)"] = true, ["Breeze LED Night Brightness (%)"] = true }
ledrows.HIDE_MS   -- 8000
ledrows.SEND_MS   -- { 400, 1500 }

local r = ledrows.new({
	set_hidden = function(name, hidden) end, -- C4:SetPropertyAttribs(name, hidden and 1 or 0)
	timer = function(ms, callback) return handle end, -- one-shot; handle:Cancel()
	now = function() return ms end,
	changed = function(shown, cause) end, -- the applied visibility changed; cause "binding" or "start" (the hide late init armed)
	log = { debug = f, info = f, warn = f },
})
r:start()                     -- late init: the first apply (both sends), no `changed`
r:update({ speed_bound = bool, has_breeze = true | false | nil })
r:shown()                     -- true while the gate (KL-D2) is open as applied
r:debug()                     -- state for the dev loop
r:stop()                      -- cancels every timer; sends nothing
```

- Before `start`, `update` only records the inputs.
- `update` with the same inputs does nothing. A show applies at once (both sends); a hide arms the `HIDE_MS` timer, cancelled by a show; when it fires, it applies (both sends) and calls `changed(false)`.
- Every callback through `pcall`; a failure is logged at warn and survived.

### 2.2 `driver.lua` and `texts.lua` (coordinator)

- Build `rows` with `set_hidden` calling `C4:SetPropertyAttribs`; `rows:start()` at the end of late init; `rows:stop()` in `OnDriverDestroyed`.
- Feed `speed_bound` from the links' bookkeeping (any of 301 to 306 bound, the same source as `pixels`), and `has_breeze` from the fan's Breeze support.
- The `Keypad Links` summary gets the KL-D7 suffix from `rows:shown()`; `changed` writes L44 or L45.

## 3. Tests

- `tests/spec/ledrows_spec.lua`: the row list and order against `driver.xml`; nothing before `start`; `start` sends every row twice (400 and 1,500 ms) with the gate's state; a show at once, a hide only after 8 s of "nothing bound", a bind inside the 8 s cancels it; Breeze-only rows hidden for `has_breeze = false`, shown for `nil` and `true` when the gate is open; same inputs send nothing; `changed` only for binding-driven changes; `stop` cancels; a throwing `set_hidden` is survived.
- `tests/spec/fan_driver_spec.lua`: a driver with no keypad hides the 20 rows after late init plus 8 s; binding a button to Fan Speed 3 shows them at once with L44; unbinding hides them 8 s later with L45; a keypad on Off only keeps them hidden; the `Keypad Links` suffix; values unchanged throughout; no `SetPropertyAttribs` in `OnDriverInit`.

## 4. Hardware checks (Windows session, no owner needed)

1. **KH4 + KH1:** add a scratch Modern Forms Fan device in a test room (no fan address, nothing bound): after about 10 s the 20 rows are gone from its Properties page (re-select if needed; note whether the open page redrew by itself); the house fan's rows are all still there.
2. **KH3:** update the drivers in place again with the same build: the scratch device's rows stay hidden, the house fan's stay shown, values unchanged.
3. Delete the scratch device.

## 5. Control4 guidelines

| Item | How it is met |
| --- | --- |
| A stock install behaves like a stock driver | Met: the rows a fan without keypad cannot use are hidden; nothing is sent to any keypad. |
| Keypad LEDs follow the bound device | Unchanged: hiding is display only (KL-D5). |
| Settings changed only by the dealer | Met: hiding never writes a value; the dealer's choices are kept for when a keypad is bound. |

## 6. Pieces and owners

| Piece | Owner | Files |
| --- | --- | --- |
| Row visibility module and spec | agent A | `src/modernforms_fan/fan/ledrows.lua`, `tests/spec/ledrows_spec.lua` |
| Owner documentation | agent B | `src/modernforms_fan/www/documentation.html` |
| Integration | coordinator | `driver.lua`, `fan/texts.lua`, `tests/spec/fan_driver_spec.lua`, `tests/spec/texts_spec.lua`, `CHANGELOG.md`, `docs/README.md`, `docs/status.md` |
