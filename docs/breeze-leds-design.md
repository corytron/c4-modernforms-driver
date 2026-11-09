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
| BL-D4 | **Order by speed number.** Pixel 1 (the bottom) is the lowest speed link by default; `Breeze LED Bottom` = `Speed 6` reverses it. The driver cannot learn button positions. | SDK 3; field Q1; BL25 |
| BL-D5 | **Colours only, full values, lit state only.** Every visible pixel is a lit button whose on colour is the frame colour; the off colour stays `Speed LED Off Color`, never touched. No brightness is ever computed or baked into a colour, so the keypad's active brightness and ambient dimming apply as to any lit LED. Palette: head `ffffff` (white), trail `00ffff` (teal), base `0080ff` (azure). Hue changes, not dimmed values, make the fade, so nothing vanishes when the keypad dims at night. | owner 2026-11-08 (dimming); SDK 8; field Q1a, Q6; BL61 to BL70 |
| BL-D6 | **Enter.** When the shown state turns to Breeze mode, the pixels are taken at once and a **rising wipe** plays: the white head climbs one pixel per step, each pixel it leaves turns base azure. Then the gust cycle starts with a rest. | owner; field Q6 |
| BL-D7 | **Gusts.** A rest (nothing sent; every pixel lit azure), then a **gust**: the white head climbs from below pixel 1 to above the top, the teal trail one pixel behind it, each pixel the trail leaves turning azure again; then the next rest. The rest is random within a range set by the Breeze strength: Breeze 1: 6 to 9 s, Breeze 2: 3.5 to 6 s, Breeze 3: 1.5 to 3.5 s (unknown strength: as 2). A strength change applies from the next rest. | owner 2026-11-09 ("gusts"); field Q5, Q6, rec. 3 |
| BL-D8 | **Leave.** When the shown state leaves Breeze mode for any reason while the fan is online (Off, a speed, On, Toggle, Cycle, Breeze off, the Breeze fan, the app, the remote, programming), whatever is in flight stops and a **falling wipe** plays once: the white head descends from the top one pixel per step, and each pixel it leaves is **settled**, given back to the links with its real fan-mode state (lit in its speed's colour, or dark). The pressed button lights as the head passes it. When the head has passed pixel 1, the animation is idle. | owner 2026-11-09 ("reverse breeze animation triggers once"); BL5, BL14 |
| BL-D9 | **Follows the shown state, from every source.** Start and leave are decided from `mode.breeze(shown)` in `listener.shown`, the same shown state the LEDs follow (wanted over in flight over confirmed). A press starts the leave wipe at once; a refused request brings Breeze back and with it a new rising wipe (BL8, BL17). Changes made in the Modern Forms app, by the remote or the wall control arrive with the next poll and play the same wipes. | V10; BL5 to BL10 |
| BL-D10 | **Interruptions.** Leave during an enter wipe or a gust: the falling wipe starts from the top at once; pixels not yet passed keep their frame until the head passes. Breeze again during a leave wipe: the rising wipe starts from pixel 1; pixels it passes are taken back. The newest shown state always wins. | BL12, BL13 |
| BL-D11 | **No wipe, settle at once** when the animation stops for anything other than leaving Breeze while online: the phase is not `online` (offline, rebooting, waiting; BL11), the property turned Off, `Speed LED Colors` left `Per speed`, or no pixel left. When the phase returns to `online` with Breeze still shown, the rising wipe plays again. | BL11, BL30 |
| BL-D12 | **Step time** `Breeze LED Step (ms)`, 200 to 600, default 300: one step moves the head one pixel. Wipes and gusts use the same step. | field Q5, rec. 3; SDK 4 |
| BL-D13 | **Pacing.** One one-shot timer at a time, re-armed each step. A late tick never bursts: the steps that fell due are applied together, each pixel gets only its final colour of those steps, and every pixel a leave wipe passed is settled. A pixel is sent only when its colour changes. | SDK 4; BL37, BL38 |
| BL-D14 | **Messages per pixel change:** `BUTTON_COLORS` (on = frame colour, off = `Speed LED Off Color`, current = frame colour), then `MATCH_LED_STATE` true, unless the animation itself last lit that pixel and `breezeleds.RECOLOUR_NEEDS_STATE` is false. It ships true (both messages, the behaviour verified on the house, K6) until hardware check HB2 shows `BUTTON_COLORS` alone repaints a lit button. A gust step changes three pixels. | SDK 1, 6; K6 |
| BL-D15 | **Held pixels.** While the animation holds a pixel the links send that link nothing on a shown change, a colour change (`set_colors`) or an `Also Lit At` change; they keep their tables, which the settle uses. A `REQUEST_BUTTON_COLORS` or a new binding on a held pixel is answered with the pixel's current frame colour. | SDK 6; BL40 to BL42 |
| BL-D16 | **Bindings mid-animation.** A speed link that gains a button joins at once (held, answered with the base colour, or the current frame). A link that loses its last button leaves the pixel list without a send (the button keeps its last colour, as any unbound button does; the manual says so). | BL40 to BL43; ECC C4 |
| BL-D17 | **Restart, update, reload.** `OnDriverDestroyed` cancels the timer and sends nothing (whether a send still arrives there is not documented). The keypad keeps its last frame until the first contact, whose refresh sends every link its real state; if Breeze still blows, the rising wipe plays. No state is persisted. | SDK 6; BL45 to BL47 |
| BL-D18 | **Off by default.** `Breeze LED Animation` = `Off` | `Gusts`, default `Off`: an update starts animating no one's keypad. A fan without Breeze never animates. No new command, event, variable or condition; property rows only, so no `<capabilities>` change and no controller reboot. | BL44 |

## 2. Properties (driver.xml, after `Speed LED Off Color`)

| Name | Type | Values | Default |
| --- | --- | --- | --- |
| `Breeze LED Animation` | LIST | `Off`, `Gusts` | `Off` |
| `Breeze LED Bottom` | LIST | `Speed 1`, `Speed 6` | `Speed 1` |
| `Breeze LED Step (ms)` | RANGED_INTEGER | 200 to 600 | 300 |

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

- Constants: `breezeleds.HEAD = "ffffff"`, `TRAIL = "00ffff"`,
  `BASE = "0080ff"`, `REST_MS = { [1] = {6000, 9000}, [2] = {3500, 6000},
  [3] = {1500, 3500} }`, `STEP_MIN = 200`, `STEP_MAX = 600`,
  `STEP_DEFAULT = 300`, `RECOLOUR_NEEDS_STATE = true`.
- Phases: `idle`, `enter`, `rest`, `gust`, `leave`. Active means enabled,
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

- `tests/spec/breezeleds_spec.lua`: every phase and transition of BL-D6 to
  BL-D11 with a fake timer, random and clock; the frames of an enter wipe,
  a gust and a leave wipe for 1, 2, 4 and 6 pixels, both bottoms; the rest
  ranges per strength; with_state per BL-D14; late ticks (BL-D13: no burst,
  every passed pixel settled); interruptions both ways; set_pixels while
  active; repaint; stop; failures in paint and settle; nothing sent when
  nothing changes.
- `tests/spec/links_spec.lua`: `paint`, `settle`, `pixels_list`, the held
  skips in shown, refresh, set_colors and set_also, `answer` on a held link,
  the `pixels` callback on bind, unbind and late init.
- `tests/spec/fan_driver_spec.lua` (coordinator): with `Per speed`, Gusts and
  four bound speed links: Breeze On from a keypad press on 311 plays the
  rising wipe (the sends in order); a speed press during a gust plays the
  falling wipe and ends with the pressed link lit in its colour; Off plays it
  and lights Off at once; Breeze from a poll (the app) plays the rising wipe;
  offline settles at once; the property Off settles at once; Keypad's own
  writes L42 and sends no frame.

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
