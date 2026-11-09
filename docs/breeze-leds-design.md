# Breeze on the keypad LEDs: the contract (#137)

The owner's request (2026-11-08) and decisions (2026-11-08 and 2026-11-09):
while the fan is in Breeze mode, the keypad buttons bound to the fan's speed
links play an animation in blues, teals and whites, rising from the bottom
button towards the top like a breeze. The driver does it, over its own links
(not Composer programming). It plays in **gusts**. **Off does not join.** Any
press of a fan-mode button (a speed, Off) ends Breeze and puts the LEDs back
to the fan-mode state; Off also stops the fan. When Breeze ends while the
animation runs, whatever is in flight stops and a **reverse animation plays
once**, top to bottom, to say "leaving Breeze", whether Breeze ended by Off
or by a speed. The same animations play whatever ended or started Breeze: a
keypad, the Control4 app or a touch screen, the Modern Forms app, the
remote, the wall control or programming. The keypad's own LED dimming by
ambient light keeps working. A keypad with no button on a speed link (for
example a 2-button keypad or a switch run as a 2-button keypad, bound to
Fan Toggle and Fan Off) shows no animation: its LEDs work as before.

The research this rests on: [`breeze-leds-sdk-research.md`](breeze-leds-sdk-research.md)
(SDK), [`breeze-leds-field-research.md`](breeze-leds-field-research.md)
(hardware, Zigbee, perception, palette) and
[`edge-cases-breeze-leds.md`](edge-cases-breeze-leds.md) (cases BL1 to BL70;
where this contract and a BL row differ, this contract wins). The Breeze
model is [`breeze-design.md`](breeze-design.md) section 11 (BF-D1 to
BF-D15); the links are [`v1-design.md`](v1-design.md) section 5 and
`src/modernforms_fan/fan/links.lua`.

## 1. Decisions

| # | Decision | Basis |
| --- | --- | --- |
| BL-D1 | **The driver animates its own links.** Only `BUTTON_COLORS` and `MATCH_LED_STATE` on the links the buttons are bound to; never a keypad proxy command by device id, never a keypad setting, never the keypad's Ambient Light Level input. | owner 2026-11-08; SDK 1, 3, 8; BL1 to BL4 |
| BL-D2 | **Pixels** are the speed links 301 to 306 that have a button bound (a known keypad, or a binding not yet known by number), one pixel per link. Every button on one link shows the same pixel. Off (300), Toggle (307), Cycle (308), Breeze (311) and the light's links (200 to 202) never animate and keep following their state as in 1.3 (in Breeze: Off dark, Toggle and Cycle dark, Breeze lit). On the house: Low (302), Medium (303), Med-High (304), High (305), four pixels. | owner 2026-11-09 ("off does not join"); SDK 6 (e); BL21 to BL24 |
| BL-D3 | **Only with `Speed LED Colors` = `Per speed`.** The driver may recolour only links whose resting colours it owns. Under `Keypad's own` nothing animates, and turning the animation on writes L42 to Last Action. | SDK 6 (e); BL22 |
| BL-D4 | **Order by speed number.** Pixel 1 (the bottom) is the lowest speed link by default; `Breeze LED Bottom` = `Highest speed` reverses it (the house: Low at the top, High at the bottom, so `Highest speed`, owner 2026-11-09). The driver cannot learn button positions. | SDK 3; field Q1; BL25 |
| BL-D5 | **Colours only, full values, lit state only.** Every visible pixel is a lit button whose on colour is the frame colour; the off colour stays `Speed LED Off Color`, never touched. No brightness is ever computed or baked into a colour, so the keypad's active brightness and ambient dimming apply as to any lit LED. Palette: head `ffffff` (white), trail `00ffff` (teal), base `0080ff` (azure). Hue changes, not dimmed values, make the fade, so nothing vanishes when the keypad dims at night. | owner 2026-11-08 (dimming); SDK 8; field Q1a, Q6; BL61 to BL70 |
| BL-D6 | **Enter.** When the shown state turns to Breeze mode, the pixels are taken at once and a **rising wipe** plays: the white head climbs one pixel per step, each pixel it leaves turns base azure. Then the gust cycle starts with a rest. | owner; field Q6 |
| BL-D7 | **Gusts.** A rest (nothing sent; every pixel lit azure), then a **gust**: the white head climbs from below pixel 1 to above the top, the teal trail one pixel behind it, each pixel the trail leaves turning azure again; then the next rest. The rest is random within a range set by the Breeze strength: Breeze 1: 6 to 9 s, Breeze 2: 3.5 to 6 s, Breeze 3: 1.5 to 3.5 s (unknown strength: as 2). A strength change applies from the next rest. | owner 2026-11-09 ("gusts"); field Q5, Q6, rec. 3 |
| BL-D8 | **Leave.** When the shown state leaves Breeze mode for any reason while the fan is online (Off, a speed, On, Toggle, Cycle, Breeze off, the Breeze fan, the app, the remote, programming), whatever is in flight stops and a **falling wipe** plays once: the white head descends from the top one pixel per step, and each pixel it leaves is **settled**, given back to the links with its real fan-mode state (lit in its speed's colour, or dark). The pressed button lights as the head passes it. When the head has passed pixel 1, the animation is idle. | owner 2026-11-09 ("reverse breeze animation triggers once"); BL5, BL14 |
| BL-D9 | **Follows the shown state, from every source.** Start and leave are decided from `mode.breeze(shown)` in `listener.shown`, the same shown state the LEDs follow (wanted over in flight over confirmed). A press starts the leave wipe at once; a refused request brings Breeze back and with it a new rising wipe (BL8, BL17). Changes made in the Modern Forms app, by the remote or the wall control arrive with the next poll and play the same wipes. | V10; BL5 to BL10 |
| BL-D10 | **Interruptions.** Leave during an enter wipe or a gust: the falling wipe starts from the top at once; pixels not yet passed keep their frame until the head passes. Breeze again during a leave wipe: the rising wipe starts from pixel 1; pixels it passes are taken back. The newest shown state always wins. | BL12, BL13 |
| BL-D11 | **No wipe, settle at once** when the animation stops for anything other than leaving Breeze while online: the phase is not `online` (offline, rebooting, waiting; BL11), the property turned Off, `Speed LED Colors` left `Per speed`, or no pixel left. When the phase returns to `online` with Breeze still shown, the rising wipe plays again. | BL11, BL30 |
| BL-D12 | **Step time** `Breeze LED Step (ms)`, 200 to 600, default 300: one step moves the head one pixel. Wipes and gusts use the same step. | field Q5, rec. 3; SDK 4 |
| BL-D13 | **Pacing.** One one-shot timer at a time, re-armed each sparkle tick (BL-D24; each step until section 1a). A late tick never bursts: the steps that fell due are applied together, each pixel gets only its final colour of those steps, and every pixel a leave wipe passed is settled. A pixel is sent only when its colour changes. | SDK 4; BL37, BL38 |
| BL-D14 | **Messages per pixel change:** `BUTTON_COLORS` (on = frame colour, off = `Speed LED Off Color`, current = frame colour), then `MATCH_LED_STATE` true, unless the animation itself last lit that pixel and `breezeleds.RECOLOUR_NEEDS_STATE` is false. It ships true (both messages, the behaviour verified on the house, K6) until hardware check HB2 shows `BUTTON_COLORS` alone repaints a lit button. A gust step changes three pixels. | SDK 1, 6; K6 |
| BL-D15 | **Held pixels.** While the animation holds a pixel the links send that link nothing on a shown change, a colour change (`set_colors`) or an `Also Lit At` change; they keep their tables, which the settle uses. A `REQUEST_BUTTON_COLORS` or a new binding on a held pixel is answered with the pixel's current frame colour. | SDK 6; BL40 to BL42 |
| BL-D16 | **Bindings mid-animation.** A speed link that gains a button joins at once (held, answered with the base colour, or the current frame). A link that loses its last button leaves the pixel list without a send (the button keeps its last colour, as any unbound button does; the manual says so). | BL40 to BL43; ECC C4 |
| BL-D17 | **Restart, update, reload.** `OnDriverDestroyed` cancels the timer and sends nothing (whether a send still arrives there is not documented). The keypad keeps its last frame until the first contact, whose refresh sends every link its real state; if Breeze still blows, the rising wipe plays. No state is persisted. | SDK 6; BL45 to BL47 |
| BL-D18 | **Off by default.** `Breeze LED Animation` = `Off` | `Gusts`, default `Off`: an update starts animating no one's keypad. A fan without Breeze never animates. No new command, event, variable or condition; property rows only, so no `<capabilities>` change and no controller reboot. | BL44 |

## 1a. Revision after the first hardware round (2026-11-09)

The owner watched the first build on the house keypad and the probes of
issue #137's comment of 2026-11-09 measured the keypad. These decisions
**replace** BL-D5 (palette), BL-D6 (enter), BL-D7 (gusts), BL-D12 (step)
and BL-D14 (messages); the rest of section 1 stands, BL-D8's falling wipe
included (the owner saw it and kept it).

What the keypad showed: a `BUTTON_COLORS` without `CURRENT_COLOR` leaves a
dark button dark (a colour can be preloaded); `MATCH_LED_STATE` true then
shows it; a `BUTTON_COLORS` with `CURRENT_COLOR` repaints a lit button at
once; one button flickers distinctly at 20 changes a second; four buttons at
10 changes a second each (about 40 messages a second) stay even and in step;
**pure blue `0000ff` vanishes at the keypad's night dimming**. The fan does
not report its gusts: `fanSpeed` stays at the set speed through Breeze.

| # | Decision | Basis |
| --- | --- | --- |
| BL-D19 | **Dark first, dark between.** When the animation starts, every pixel is taken and goes dark at once (`MATCH_LED_STATE` false), and the first gust starts at once. Between gusts every pixel is dark. A pixel is lit only while a gust uses it. There is no resting column. | owner 2026-11-09 (points 1 and 2) |
| BL-D20 | **A night-proof palette:** head white `ffffff`; sparkles ice `a0ffff`, teal `00ffff` and sky `40b0ff`. Nothing darker than sky, never pure blue. Hue changes only, full component values (BL-D5's dimming rule stands). | probe: `0000ff` invisible at night; `0080ff` seen as teal |
| BL-D21 | **A gust is a shimmering front.** A front rises one pixel per front step (`Breeze LED Step (ms)`, now 60 to 400, default 120, each step jittered by up to 20 % per gust). The pixel the front is on is white. Every pixel the front has passed **shimmers**: for a few sparkle ticks it flickers off and on and changes among ice, teal and sky at random, then goes dark; the shimmer fades (fewer lit ticks towards its end). Ahead of the front, a pixel may glint once in sky. Each gust draws its own randomness, so no two gusts look the same. Sometimes a second front follows the first by 2 to 4 front steps (a double gust). | owner 2026-11-09 (point 3); field Q6 |
| BL-D22 | **Strength sets the weather.** Breeze 1: rests of 4 to 8 s, 2 to 3 sparkle ticks a pixel, doubles 10 %. Breeze 2: rests of 2 to 5 s, 3 to 4 ticks, doubles 25 %. Breeze 3: rests of 1 to 3 s, 4 to 6 ticks, doubles 40 %. Unknown strength: as 2. A change applies from the next gust. The gusts stay random: the fan does not report its own. | owner ("fire when the physical fan is gusting if possible"; not possible) |
| BL-D23 | **The cheapest message for each change.** A colour for a dark pixel is preloaded silently (`BUTTON_COLORS` without `CURRENT_COLOR`), so lighting and flickering cost one `MATCH_LED_STATE` each; a lit pixel changes colour with one `BUTTON_COLORS` with `CURRENT_COLOR`. `RECOLOUR_NEEDS_STATE` is false (measured). | probes |
| BL-D24 | **One clock and a budget.** The engine ticks every sparkle tick, 50 ms; the front moves every front step. At most **30 messages a second** over all pixels (40 a second measured clean; headroom for the rest of the Zigbee mesh): a tick that would exceed it drops sparkle changes first, never a front pixel, a settle or the falling wipe. Late ticks still coalesce (BL-D13). | probes; BL-D13 |
| BL-D25 | **The falling wipe at the front's pace.** BL-D8 stands, at the front step (default 120 ms): from the top pixel, the head lights white and every pixel it leaves is settled. From a rest (all dark) the head still runs down the column. | owner (kept) |
| BL-D26 | **The tail twinkles.** BL-D21's shimmer is the gust's tail and must read as a twinkle, not a fade: every pixel the front has passed stays in the tail for its **tail time**, blinking off and on at random gaps of 2 to 4 sparkle ticks (100 to 200 ms) and relighting each time in a random sparkle colour (ice, teal or sky; sometimes the same colour, which costs one `MATCH_LED_STATE` instead of a preload and a `MATCH_LED_STATE`; sometimes a colour change while lit, one `BUTTON_COLORS` with `CURRENT_COLOR`). The gaps grow towards the end, so the tail thins out, then the pixel goes dark. Each pixel draws its own gaps, so neighbours never blink in step. The tail time replaces BL-D22's sparkle ticks: Breeze 1 300 to 500 ms, Breeze 2 500 to 800 ms, Breeze 3 700 to 1100 ms. The budget (BL-D24) drops tail changes first. | owner 2026-11-09 ("I'll want the tail of the gust to shimmer or twinkle") |
| BL-D27 | **The tail travels with its head.** A gust's tail is the stretch of the column its head passed within the last *L* front steps, *L* = the gust's tail time (BL-D26, now drawn once per gust, not per pixel) divided by its front step, rounded, at least 1. The tail's back edge rises with the head at the same pace: the pixel the back edge leaves goes dark and never relights in that gust. After the head passes the top pixel it runs on past the column, unseen, at the same pace, and the tail keeps rising behind it until its back edge has passed the top too; only then does the gust end and the rest begin. So no tail ever twinkles without its head ahead of it, on the column or just past its top. Inside the tail a dark pixel relights only while the pixel above it is lit, is the head, or lies past the top, so a twinkle never travels downwards; the pixel at the back edge blinks least (BL-D26's thinning, now by place in the tail instead of by age). Glints stay ahead of the head. Each front of a double gust has its own tail. | owner 2026-11-09 ("the tail should only exist if the head is ahead of it"; "continue moving forward and shimmering but never appear to shimmer backwards") |

**Interface changes for BL-D19 to BL-D27** (sections 3.1 and 3.2 otherwise stand):

```lua
-- links.lua
links:paint(link, colour, with_state, preload)  -- preload: BUTTON_COLORS without
	-- CURRENT_COLOR (a dark pixel stays dark); with_state as before
links:light(link, lit)  -- MATCH_LED_STATE (a COMMAND, boolean STATE) on a speed link 301..306 for the
	-- animation; clears led[link] and led_speed[link]; refused elsewhere
-- breezeleds.lua
breezeleds.new({ ..., light = fn(link, lit) })  -- links:light
-- constants: HEAD "ffffff"; SPARKS { "a0ffff", "00ffff", "40b0ff" }; GLINT "40b0ff";
-- TICK_MS 50; STEP_MIN 60, STEP_MAX 400, STEP_DEFAULT 120; BUDGET_PER_S 30;
-- REST_MS and the per-strength tables of BL-D22 (tail times of BL-D26 in place of
-- sparkle ticks); TAIL_GAP_TICKS 2..4; RECOLOUR_NEEDS_STATE false
```

## 2. Properties (driver.xml, after `Speed LED Off Color`)

| Name | Type | Values | Default |
| --- | --- | --- | --- |
| `Breeze LED Animation` | LIST | `Off`, `Gusts` | `Off` |
| `Breeze LED Bottom` | LIST | `Lowest speed`, `Highest speed` | `Lowest speed` |
| `Breeze LED Step (ms)` | RANGED_INTEGER | 60 to 400 (BL-D21) | 120 |

Text **L42**, written to Last Action when `Breeze LED Animation` is set to
`Gusts` while `Speed LED Colors` is not `Per speed` (and when `Speed LED
Colors` leaves `Per speed` while it is `Gusts`): `Breeze LEDs need Speed LED
Colors set to Per speed`.

## 3. Interfaces

### 3.1 `src/modernforms_fan/fan/breezeleds.lua` (new)

Pure logic; everything that touches Director is an argument, as in the
other `fan/` modules.

```lua
local breezeleds = require("fan.breezeleds")
local b = breezeleds.new({
	paint = fn(link, colour, with_state),  -- links:paint
	settle = fn(link),                     -- links:settle
	timer = fn(ms, cb) -> handle,          -- handle:Cancel(); the driver's one-shot timer
	random = fn(lo, hi) -> integer,        -- inclusive, ms; math.random in the driver
	log = log,                             -- default common.log
})
b:configure({ enabled = bool, per_speed = bool, bottom = 1 | 6, step = ms })
b:set_pixels(list)       -- the bound speed links, any order, duplicates ignored
b:update({ breeze = bool, strength = 1 | 2 | 3 | nil, online = bool })
b:held(link) -> bool     -- the links ask before sending a speed link anything
b:repaint(link)          -- a held pixel's REQUEST_BUTTON_COLORS or new binding
b:stop()                 -- OnDriverDestroyed: cancel the timer, release all, send nothing
b:debug() -> table       -- phase, pixels, held, frame, step, rest range
```

- Constants (section 1a): `HEAD = "ffffff"`, `SPARKS = { "a0ffff", "00ffff", "40b0ff" }`,
  `GLINT = "40b0ff"`, `GLINT_PERCENT = 30`, `TICK_MS = 50`, `STEP_MIN = 60`,
  `STEP_MAX = 400`, `STEP_DEFAULT = 120`, `JITTER_PERCENT = 20`,
  `REST_MS`, `TAIL_MS`, `DOUBLE_PERCENT` (per strength, BL-D22 and BL-D26),
  `DOUBLE_GAP_STEPS = {2, 4}`, `TAIL_GAP_TICKS = {2, 4}`, `BUDGET_PER_S = 30`,
  `WINDOW_MS = 1000`, `DARKEN_TICKS = 20`, `RECOLOUR_NEEDS_STATE = false`.
  `TRAIL` and `BASE` are gone. The options add `light = fn(link, lit)` and
  `now = fn() -> ms`; `debug()` reports `frame` as a colour, `"dark"` or
  `"unknown"`, plus `loaded`, `tail`, `double`, `gust` and `budget`.
- Phases: `idle`, `gust`, `rest`, `leave` (BL-D19 removed `enter`). Active means enabled,
  per_speed, online, breeze, and at least one pixel.
- `configure`, `set_pixels` and `update` may arrive in any order and as
  often as Director likes; each re-evaluates active and applies BL-D6 to
  BL-D11. Calls that change nothing send nothing.
- Every `paint` and `settle` call goes through `pcall` and a failure is
  logged, never raised.
- A pixel's first paint after it is taken passes `with_state = true`;
  later paints pass `RECOLOUR_NEEDS_STATE`.
- A step is one timer callback. The timer is re-armed for the next step
  (or the rest); `stop`, idle and every phase change cancel the pending
  one first. Late ticks follow BL-D13: the module keeps the time the step
  was due (from the timer's own scheduling, not a clock it reads), so the
  spec drives it with a fake timer and a fake clock passed as `now` (add
  `now = fn() -> ms` to the options if the coalescing needs a clock).

### 3.2 `src/modernforms_fan/fan/links.lua` (changes)

New options and methods; everything else unchanged.

```lua
links.new({ ...,
	held = fn(link) -> bool,       -- breezeleds:held; optional (absent: nothing held)
	repaint = fn(link),            -- breezeleds:repaint; optional
	pixels = fn(list),             -- breezeleds:set_pixels; optional, called with
	                               -- the bound speed links whenever they change
})
links:paint(link, colour, with_state)  -- BUTTON_COLORS {ON_COLOR = colour,
	-- OFF_COLOR = self.off_color, CURRENT_COLOR = colour} as NOTIFY, then,
	-- with with_state, MATCH_LED_STATE true as COMMAND. led[link] and
	-- led_speed[link] are cleared (the link's real state is no longer on the keypad).
links:settle(link)      -- the real state. Under Per speed always colours
	-- first, also for a dark link (its own speed's colour as the on colour,
	-- so no frame colour stays behind), then MATCH_LED_STATE; under Keypad's
	-- own the state only. led and led_speed as push_led sets them.
links:pixels_list()     -- the bound speed links (301 to 306 with a known
	-- consumer or a binding not yet known by number), ascending
```

- `shown`, `refresh`, `set_colors` and `set_also` skip a link while
  `held(link)` is true.
- `answer(link)` on a held link calls `repaint(link)` instead.
- `pixels(list)` is called after every change of the bound bookkeeping
  (where `publish` runs today), and once at late init; only speed links.
- No change for links 300, 307, 308, 311, 200 to 202.

### 3.3 `src/modernforms_fan/driver.lua` (coordinator)

- `breezeleds` is created before `links`; the two reach each other through
  closures. `listener.shown` calls `bleds:update{ breeze = mode.breeze(shown),
  strength = shown.wind_speed, online = <phase is online> }` **before**
  `links:shown(shown)`, so the pixels are held before the links look.
  `listener.phase` calls `bleds:update` with the new online flag.
- `OnPropertyChanged` for the three rows and for `Speed LED Colors`:
  `bleds:configure{...}`; L42 per section 2. For `Speed LED Colors` the
  Breeze LEDs are configured **before** the links take the new colour mode,
  so leaving `Per speed` settles the pixels with their per-speed colours.
- `OnDriverDestroyed`: `bleds:stop()` before `links:stop()`.
- The `fan_driver_spec` gets the integration specs (section 5).

## 4. What the owner sees (house, four pixels, defaults)

- Breeze starts (any source): the head climbs Low → High in four steps,
  leaving the column azure; 311 lights; Off and the speed LEDs' normal
  state are gone until Breeze ends.
- Every few seconds (by strength) a white-and-teal gust runs up the column.
- Medium pressed during Breeze: the fan leaves Breeze for speed 3; the
  white head runs down High → Low, and each button it passes shows its real
  state (Medium lights purple as the head passes it, the rest go dark).
- Off pressed during Breeze: the fan stops; the same falling wipe leaves
  every speed button dark; Off lights at once (it is not a pixel).
- The room darkens: the whole animation dims with the keypad.

## 5. Tests

- `tests/spec/breezeleds_spec.lua`: every phase and transition with a fake
  timer, random and clock; dark first (BL-D19); the front, tail and glints of
  a gust for 1, 2, 4 and 6 pixels, both bottoms (BL-D21, BL-D26: tail pixels
  blink more than once at gaps of 2 to 4 ticks, neighbours out of step, tail
  times by strength); doubles; rests per strength (BL-D22); preloads and
  lights (BL-D23); the budget (BL-D24: never over 30 in any second, tail
  changes dropped before a front); the falling wipe (BL-D25); late ticks
  (BL-D13); interruptions both ways; set_pixels while active; repaint; stop;
  failures in paint, light and settle; nothing sent when nothing changes.
- `tests/spec/links_spec.lua`: `paint`, `settle`, `pixels_list`, the held
  skips in shown, refresh, set_colors and set_also, `answer` on a held link,
  the `pixels` callback on bind, unbind and late init.
- `tests/spec/fan_driver_spec.lua` (coordinator): with `Per speed`, Gusts and
  four bound speed links, replayed through a keypad model (what each button
  shows): Breeze On from a press on 311 goes dark first, then the front rises
  bottom to top, never in pure blue; a speed press plays the falling wipe once
  and ends with the pressed link lit in its colour; Off lights at once and the
  wipe leaves every speed button dark; Breeze from a poll (the app) plays
  gusts; the property Off and offline settle at once and send nothing after;
  Keypad's own writes L42 and sends no frame.

## 6. Hardware checks on the house (owner watching; each under a minute)

Run with a `--dev` build through the dev loop, the owner at the keypad.

| # | Check | Settles |
| --- | --- | --- |
| HB1 | The keypad's physical button order (Windows session reads it in Composer, or the owner looks) | `Breeze LED Bottom` on the house |
| HB2 | One lit pixel recoloured with `BUTTON_COLORS` alone: does it change? | `RECOLOUR_NEEDS_STATE` |
| HB3 | The palette (white, teal, azure) in daylight, then the room dark: all visible and distinct, dimmed with the keypad's other LEDs? | BL-D5 |
| HB4 | A gust at 300, then 200 ms a step while the owner presses the light's Up: does anything lag? | the default step |
| HB5 | Medium pressed during a gust: the falling wipe, Medium lit purple at the end | BL-D8 |
| HB6 | Off pressed during a rest: the falling wipe, Off lit at once | BL-D8 |
| HB7 | Breeze started and stopped from the Modern Forms app | BL-D9 |

## 7. Pieces and owners

| Piece | Files (one writer each) |
| --- | --- |
| Animation module | `src/modernforms_fan/fan/breezeleds.lua`, `tests/spec/breezeleds_spec.lua` |
| Links changes | `src/modernforms_fan/fan/links.lua`, `tests/spec/links_spec.lua` |
| Owner documentation | `src/modernforms_fan/www/documentation.html`, `CHANGELOG.md`, `docs/composer-checklist.md` |
| Coordinator | this file, `src/modernforms_fan/driver.xml`, `src/modernforms_fan/driver.lua`, `src/modernforms_fan/fan/texts.lua`, `tests/spec/texts_spec.lua`, `tests/spec/fan_driver_spec.lua`, `docs/README.md`, `docs/status.md`, `CLAUDE.md` |
