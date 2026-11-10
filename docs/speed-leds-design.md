# Speed LED chase: design contract

> **Contract for [issue #159](https://github.com/corytron/c4-modernforms-driver/issues/159)**
> (2026-11-09). Every piece of the feature is built against this text. The
> research behind it: [`edge-cases-speed-leds.md`](edge-cases-speed-leds.md)
> (rows SL1 onward), [`speed-leds-c4-guidelines.md`](speed-leds-c4-guidelines.md)
> (SG1 to SG11) and [`speed-leds-engine-options.md`](speed-leds-engine-options.md).
> The Breeze animation it sits beside: [`breeze-leds-design.md`](breeze-leds-design.md)
> (BL-D1 to BL-D30) and `src/modernforms_fan/fan/breezeleds.lua`.
> Placeholders only: fan 10.0.2.151, controller 10.0.2.10.

The owner asked: at a fixed speed of 2, 3, 4 or 5, a simple animation runs
across the keypad's speed LEDs, one after the other, in the direction the fan
blows, at even intervals. Between animations the selected speed's LED is lit;
while one plays, it is not. The animation's pace follows the fan's speed
(speed 2 slowest, speed 5 fastest), the time between animations is always the
same, and its colour is the one set for that speed in the driver.

## 1. Decisions

| # | Decision | Why |
| --- | --- | --- |
| SL-D1 | A **second engine**, `fan/speedleds.lua`, beside the Breeze engine, and a small pure arbiter, `fan/ledhub.lua`. `breezeleds.lua` and `links.lua` are not changed. | Leaves the hardware-tuned Breeze code and its spec untouched (engine options, option a). |
| SL-D2 | **One owner per pixel.** A speed link is held by at most one engine; `held(link)` is `breeze:held(link) or speed:held(link)`. Breeze always wins: the hub updates the speed engine first, so it lets go before Breeze takes the pixels. | SL12 to SL16. |
| SL-D3 | The chase **holds pixels only while it plays.** During the rest the links own every LED and light the selected speed's button exactly as a build without the feature does, `Also Lit At` included. | SL63: everything already right at rest stays right. |
| SL-D4 | The shape is **a single dot** that travels across every bound speed button, in the airflow direction: `forward` (blowing down) runs from the top button to the bottom one, `reverse` from the bottom up. Which end is the top comes from the existing `Breeze LED Bottom` row. An unknown direction: no chase. | Owner: "one after the other, in the direction the fan is blowing"; an unknown direction cannot honour that. |
| SL-D5 | **Pace by speed, fixed in the first build:** one dot step lasts 400, 300, 200, 120 ms at speeds 2, 3, 4, 5; 500 ms at speed 1 and 100 ms at speed 6 when those are on. Floor 100 ms. | Guidelines 8.3; with four buttons a chase lasts 1.6 s at speed 2 and 0.48 s at speed 5. |
| SL-D6 | **Constant rest** between the end of one chase and the start of the next: `Speed LED Rest (s)`, 5 to 60, **default 5** (#177; 10 before 1.7), the same at every speed. **After a speed is selected the first chase comes 2.5 s later** (`FIRST_MS`, fixed, not a property), then one every rest while the speed stays (#177); see SL-D19. | Owner: "the amount of time in between animations is always the same"; owner, 2026-11-10: "the default for everyone to be 5s", "after a speed is selected i want the chase to start after 2.5s that first time, then after that it switches to 5s". At 5 s four buttons send about 2 messages a second on average, inside the budget. |
| SL-D7 | **Colour:** the chase uses the selected speed's `Speed N LED Color`, read at the start of every chase. No colour of its own. | Owner; SL49. |
| SL-D8 | **Which speeds:** `Speed LED Animation` = `Off` (default), `Speeds 2 to 5`, `Speeds 1 to 6`. Off by default so an update animates nobody's keypad; the house is set to `Speeds 2 to 5`. | BL-D18; owner's text names 2 to 5. |
| SL-D9 | **Only under `Speed LED Colors` = `Per speed`**, only in fan mode (`mode.fan_on(shown) == true`, so never in Breeze), only while the fan is online, only with at least two bound speed buttons. Otherwise no chase and every held pixel is put back at once. Under `Keypad's own` the driver writes the same kind of Last Action line the Breeze animation writes there. | SF2, SG truthful-stop row. |
| SL-D10 | **Restart only on a real change** of the inputs (enabled speeds, mode, speed, direction, online, pixel list). A rest change is not a restart: while resting it moves the next chase to the last chase's end plus the new rest, never earlier than now (SL-D19). The model fires `shown` on any field, light level included; a light fade tick changes nothing. | SL7. |
| SL-D11 | **Any change during a chase ends it** with a settle of every pixel the engine holds (the links send their truth), forgets what it loaded, and starts a new run (its first chase `FIRST_MS` later, SL-D19). A chase lasts under 2 s, so nothing is worth carrying over. | Engine options section 3. |
| SL-D12 | **Messages per chase** (N buttons, L of them lit at rest, usually 1): darken the L lit buttons; for each button in order, load the chase colour into it if it was dark at rest (`paint(link, colour, false, true)`, the preload), light it (`light(link, true)`), and darken the one before it; darken the last; relight the L buttons (`light(link, true)`, no colour: theirs is already the speed's colour). That is 2N + 2L + (N - L) messages, 13 for the house's four buttons (less at the edges, SL-D18). The preload is sent every chase, so nothing the links or a bind sent behind the engine's back can show a wrong colour. | Guidelines sections 4 and 8.2, with a stateless preload; `links:lit` / `colour_for` (`links.lua` 289 to 317): a lit speed button carries the colour of the speed the fan is at. |
| SL-D13 | **Budget:** the Breeze window (30 messages per 1,000 ms, BL-D24). Every chase message is must-send; when the window is full the next step is delayed, never dropped. | Guidelines 8.2. |
| SL-D14 | **Waiting for Breeze:** a chase that falls due while Breeze holds any pixel (its leave wipe) tries again after 200 ms. | SL15. |
| SL-D15 | **Night:** as by day; the keypad's own dimming applies. A night option comes only after the owner has seen a night. | SL55 to SL57, question 5. |
| SL-D16 | A **bind or `REQUEST_BUTTON_COLORS`** on a held pixel (`repaint`) ends the chase as SL-D11 does. `OnDriverDestroyed` stops it (the timer is cancelled). | SF7; BL-D11. |
| SL-D17 | No `<capabilities>` change; property rows only, so no controller reboot. | BL44. |
| SL-D18 | **No double blink at the edges** (#172, owner at the keypad, 2026-11-10). A button lit at rest that is the dot's **first** position is not darkened at the start: it stays lit and is the first frame, and darkens only when the dot moves on. A button lit at rest that is the dot's **last** position is not darkened at the end: the dot stays on it and it is lit again for the rest without a message. Each case saves two messages (11 instead of 13 for four buttons); the middle speeds do not change. | On the house, speed 2 (dot starts on Low) blinked at the start and speed 5 (dot ends on High) at the end. |
| SL-D19 | **A new run starts with the short delay, whatever its source** (#177). A run is new when the chase becomes possible or its inputs change for real (SL-D10): a speed change from a keypad, a Navigator, programming, the driver's actions, the Modern Forms app, its remote or wall control (the last three seen at the driver's next poll of the fan), the fan starting at a speed, Breeze ending at a speed (after the Breeze leave wipe, SL-D14), the chase turned on or its speeds widened, the fan back online, a direction change, a changed pixel list. Its first chase comes `FIRST_MS` (2,500 ms) after the engine sees the change; every later chase comes a rest after the previous one ends. A light-level change or a poll that changes nothing is not a new run. A rest change while resting reschedules from the last chase's end (or from the run's start if none has played yet), never earlier than now. | Owner: "Make sure the chase starts no matter how speed is selected, ie from phone or api." |

## 2. Properties (`driver.xml`, after the Breeze LED rows)

| Row | Type | Values | Default |
| --- | --- | --- | --- |
| `Speed LED Animation` | LIST | `Off`, `Speeds 2 to 5`, `Speeds 1 to 6` | `Off` |
| `Speed LED Rest (s)` | RANGED_INTEGER | 5 to 60 | 5 |

Both sit with the Breeze LED rows and, like them, are always shown and take
effect only under `Per speed`. The chase also reads `Breeze LED Bottom`; its description in
the documentation says so.

## 3. Interfaces

### 3.1 `fan/speedleds.lua`

```lua
local speedleds = require("fan.speedleds")
speedleds.STEP_MS      -- { [1] = 500, [2] = 400, [3] = 300, [4] = 200, [5] = 120, [6] = 100 }
speedleds.REST_DEFAULT -- 5 (seconds, #177); speedleds.REST_MIN 5, speedleds.REST_MAX 60
speedleds.FIRST_MS     -- 2500: a new run's first chase (SL-D19)
speedleds.RETRY_MS     -- 200

local s = speedleds.new({
	paint = function(link, colour, with_state, preload) end, -- links:paint
	light = function(link, lit) end,      -- links:light (MATCH_LED_STATE only)
	settle = function(link) end,          -- links:settle (the links send their truth)
	lit = function(link) return bool end, -- is the link lit at rest now (links:lit on the model's shown)
	colour = function(speed) return "rrggbb" or nil end, -- links:colour_for(300 + speed, speed)
	blocked = function(link) return bool end, -- another engine (Breeze) holds the link
	timer = function(ms, callback) return handle end, -- one-shot; handle:Cancel()
	now = function() return ms end,
	log = { debug = f, info = f, warn = f },
})
s:configure({ speeds = "off" | "2-5" | "1-6", per_speed = bool, bottom = 1 | 6, rest = seconds })
s:set_pixels({ 302, 303, 304, 305 }) -- bound speed links, any order; the engine orders them
s:update({ fan_mode = bool | nil, speed = 0..6 | nil, online = bool, direction = "forward" | "reverse" | nil })
s:held(link)    -- true while a chase holds the link
s:repaint(link) -- a bind or REQUEST_BUTTON_COLORS on a held link: ends the chase (SL-D16)
s:stop()        -- puts back every held pixel (settle), cancels the timer
s:debug()       -- a table for the dev loop: state ("off", "resting", "chasing", "waiting"), first (the run's first chase is still to come), speed, step, rest, held links
```

- `configure`, `set_pixels` and `update` are idempotent: called with the
  same inputs they send nothing and keep the timer running (SL-D10).
- Every callback is called through `pcall`; a failing callback is logged at
  warn and the engine carries on as the Breeze engine does (`try`).
- One one-shot timer at a time; no repeating timers; no globals.
- Helpers keep the names and shapes of their `breezeleds.lua` twins
  (`try`, the budget window, `order`), so a later shared module stays a
  mechanical change.

### 3.2 `fan/ledhub.lua`

```lua
local hub = require("fan.ledhub").new({ breeze = bleds, speed = sleds })
hub:held(link)           -- breeze:held(link) or speed:held(link)
hub:repaint(link)        -- to the engine that holds it (Breeze first); nothing if neither
hub:set_pixels(list)     -- to both, the speed engine first, each its own copy of the list
hub:stop()               -- to both, the speed engine first
hub:update(breeze_view, speed_view) -- speed:update(speed_view) first, then breeze:update(breeze_view)
hub:debug()              -- { breeze = breeze:debug(), speed = speed:debug(), both = { links held by both } }
```

Pure: no timers, no C4 calls; a spec asserts `both` stays empty through
every sequence it plays.

### 3.3 `driver.lua` (coordinator)

- Builds `sleds` after `bleds`, with the closures above (`paint` passes all
  four arguments, as #164 fixed for Breeze), and the hub; the links'
  `held`, `repaint` and `pixels` closures point at the hub; `OnDriverDestroyed`
  calls `hub:stop()`.
- `listener.shown` and `listener.phase` call `hub:update(leds_view(...), speed_view(...))`
  where `bleds:update(...)` is called today, before `links:shown`.
- Property dispatch for the two rows; a `Speed LED Colors` or `Breeze LED Bottom`
  change calls `sleds:configure` again; a `Speed N LED Color` or `Speed LED Off
  Color` change ends a chase in progress (`repaint` on a held link, SL-D11)
  before the links take the new colours, because the chase's relight sends no
  colour of its own.

## 4. What the owner sees (house: four buttons, Low to High, all purple, defaults)

At speed 3 the Medium button is lit purple. 2.5 seconds after the speed was
selected it goes dark,
a purple dot runs down the four buttons (fan blowing down), one button every
0.3 s, and when the dot leaves the last button the Medium button lights
again; five seconds later the next chase, and so on. At speed 5 the dot runs
in under half a second; at speed 2 it takes 1.6 s; the five seconds between
them do not change. A speed press shows the new button at once and the first
chase comes 2.5 s later, whatever selected the speed. Breeze, Off, the fan going offline, or `Keypad's own` stop
the chase at once and leave the keypad as it is today.

## 5. Tests

- `tests/spec/speedleds_spec.lua`: a fake timer and clock, recorded calls.
  The order per direction and per `bottom`; step times per speed; the rest is
  constant across speeds, and a new run's first chase comes `FIRST_MS` after
  the change (SL-D19); the message sequence and count of
  SL-D12 for 2 to 6 buttons with 0, 1 and 2 lit at rest; idempotent updates
  (a light-level change sends nothing); every stop path settles every held
  pixel and holds nothing after; `blocked` delays a chase by `RETRY_MS`;
  the budget delays, never drops; speeds 1 and 6 only under `1-6`; no chase
  under one button, `per_speed = false`, offline, unknown direction or
  `fan_mode` not true; `repaint` ends a chase; a throwing callback is
  survived.
- `tests/spec/ledhub_spec.lua`: delegation, update order, repaint routing,
  and `both` empty through Breeze start, Breeze leave wipe and chase
  sequences played with stub engines.
- `tests/spec/fan_driver_spec.lua` (coordinator): the two rows exist and are
  hidden with the Breeze rows; a full chase at speed 3 on the house keypad
  model, then the rest, then the next chase; a Breeze press mid-chase.

## 6. Hardware checks on the house (owner watching; each under a minute)

1. `Speed LED Animation` = `Speeds 2 to 5`, fan at speed 3, blowing down:
   the Medium LED goes dark, a purple dot runs top to bottom, Medium relights;
   again five seconds later.
2. Speed 5, then speed 2: the dot is visibly faster, then slower; the gap is
   the same.
3. Reverse the fan: the dot runs bottom to top.
4. Press Breeze mid-rest: the gusts start as today; press a speed: the wipe,
   then the new speed's LED, and a chase a rest later.

## 7. Control4 guidelines

Sources: `_50-LIGHTV2BESTPRACTICE.md`, `_51-LIGHTV2EXTRAS.md`, the keypad
and button link protocols (`62_keypad_button_link_bindings`), summarised in
[`speed-leds-c4-guidelines.md`](speed-leds-c4-guidelines.md) section 8.1.

| Item | How the chase meets it, or the departure and its reason |
| --- | --- |
| The LED follows the bound device, from every source | Met at rest (the links, unchanged). **Departs during each chase**, when the selected LED is dark and the others light in turn: the owner's design. Kept short (under 2 s), off by default. |
| Only the driver's own buttons | Met: bound speed links under `Per speed` only. |
| No periodic updates that flood the keypad's network | **Departs in kind** (a chase every rest, for hours) and is met in rate: 13 messages per chase for four buttons (11 at the edge speeds, SL-D18), about 1.2 a second on average at the default rest, peaks well under the 30-a-second window, rest floor 5 s. |
| Transitions instead of emulated steps | **Departs, forced:** a button link has no effect or transition message. |
| Back-to-back changes coalesce | Met: the newest state wins, a change ends the chase, no queue. |
| Buttons without LEDs | Met as far as possible: off by default. |
| A press acts at once | Met: a press changes the shown state, which ends the chase before the links act. |
| Colours are 6-hex on and off | Met: the speed's colour and `Speed LED Off Color`. |
| Keypad dimming is the keypad's | Met: full colours only (SL-D15). |
| Programmed LED commands on the same buttons | **Departs, unavoidable:** they can clash with a chase; the documentation says the speed buttons should follow the connection. |
| A stock install behaves like a stock keypad | Met: `Off` by default, no capability. |
| Truthful whenever it stops | Met: every stop settles every held pixel. |

## 8. Pieces and owners

| Piece | Owner | Files |
| --- | --- | --- |
| Chase engine and spec | agent A | `src/modernforms_fan/fan/speedleds.lua`, `tests/spec/speedleds_spec.lua` |
| Arbiter and spec | agent B | `src/modernforms_fan/fan/ledhub.lua`, `tests/spec/ledhub_spec.lua` |
| Owner documentation | agent C | `src/modernforms_fan/www/documentation.html` |
| Integration | coordinator | `driver.xml`, `driver.lua`, `fan/texts.lua`, `tests/spec/fan_driver_spec.lua`, `CHANGELOG.md`, `docs/README.md`, `docs/status.md`, `.github/codenames.json` |
