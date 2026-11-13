# Speed LED chase: where the engine lives (#159, options)

A design-options note, not a contract. It compares ways to build the second
keypad animation (the chase at fixed speeds 2 to 5) beside the shipped Breeze
animation, names what the new engine can take from `fan/breezeleds.lua`, and
proposes the hand-over, the frames, the timing and the interface. Nothing here
is built. Every statement about existing behaviour cites the file and line as
the code stands now: `breezeleds.lua` is `src/modernforms_fan/fan/breezeleds.lua`
(1253 lines), `links.lua` is `src/modernforms_fan/fan/links.lua`, `driver.lua`
is `src/modernforms_fan/driver.lua`. The Breeze contract is
[`breeze-leds-design.md`](breeze-leds-design.md) and its reasons are
[`edge-cases-breeze-leds.md`](edge-cases-breeze-leds.md).

> **What was built** (2026-11-13, #213): option (a), in 1.6 (#159):
> `fan/speedleds.lua` beside `fan/breezeleds.lua` and the arbiter
> `fan/ledhub.lua`, released between chases (mode A), with a preload of
> the chase colour into each dark pixel on every chase
> ([`speed-leds-design.md`](speed-leds-design.md) SL-D1 to SL-D3, SL-D12).
> The contract's step table is 400, 300, 200 and 120 ms (not section 5's),
> its rest a property, 5 s by default since 1.7 (#177). The dropped
> `preload` argument this note opens with was fixed by #164 in the same
> release. The file and line numbers below are those of 2026-11-09.

The owner's request, in short: at speeds 2, 3, 4 and 5 a one-after-the-other
animation runs in the direction the fan blows, at even intervals; between runs
the selected speed's LED is lit, but not while the animation plays; the
animation's speed follows the fan speed (2 slow, 5 fast) while the gap between
runs is always the same; its colour is the one set for that speed in the driver.

Read first, because it changes the estimates below: `driver.lua:391-393` hands
`links:paint` only three of the four arguments the Breeze engine passes
(`function(link, colour, with_state) links:paint(link, colour, with_state) end`).
The fourth, `preload`, is dropped there. `breezeleds.lua` asks for a preload at
`breezeleds.lua:606` and `:547-564`, and `links:paint` honours it at
`links.lua:499-504`; as wired, every "preload" reaches the keypad as a
`BUTTON_COLORS` with `CURRENT_COLOR`. The busted replay of the driver spec
(`tests/spec/fan_driver_spec.lua`, the keypad model near line 939) ignores
`CURRENT_COLOR` on a dark button, so it would not notice. Whether a real keypad
lights a dark button on that message was not measured (the probes measured
`CURRENT_COLOR` on a lit button and the preload on a dark one). This is
either a wiring slip or a deliberate choice nobody wrote down; the owner or the
coordinator should settle it, and the new engine's message counts assume the
fourth argument is passed through.

## 1. Where the engine lives

What has to be shared with Breeze in any option: the three links callbacks,
`held(link)`, `repaint(link)` and `pixels(list)` (`links.lua:173-175`,
`links.lua:364-374`, `404-413`, `681-696`, wired at `driver.lua:434-442`), so
something must route them to whichever engine is active; and the pixels
themselves, since both animate the same bound speed links 301 to 306.

### Option (a): a sibling module `fan/speedleds.lua` and a small arbiter

A new pure module with its own small state machine (idle, rest, chase) and no
budget, no night, no randomness. The arbiter is about 40 lines, best as its
own pure module (`fan/ledhub.lua`, with a spec) so `driver.lua` only wires it:
`held` is `breeze:held(l) or speed:held(l)`, `repaint` goes to whichever holds
the link, `set_pixels` and `stop` go to both, and `update(view)` calls the
speed engine first, then Breeze (section 3 says why).

- Lines touched: new `speedleds.lua` about 330 lines, of which about 120 are
  copies of tiny helpers (section 2); `ledhub.lua` about 50; `driver.lua` about
  30 (a require, the instance, `configure` calls, three closures re-pointed,
  `OnDriverDestroyed`, a `speed` field in `leds_view`); `links.lua` none;
  `breezeleds.lua` none; new specs about 500 lines.
- Risk to Breeze: none by construction. `breezeleds.lua` and its spec
  (139 examples, green today) are untouched. The only shared surface is the
  hub's order of calls and the one-line fix of the preload argument, if the
  owner wants it.
- Duplication: `try`, `number_of`, `round`, `links_of`, `same_list`, `reorder`,
  `lane`, the clock (`advance_time`), the timer trio (`cancel`, `arm`, `fire`),
  `record`, `send_light`, `send_paint`, `take`, `release`. About 120 lines.
- Lua 5.1 limits: `breezeleds.lua`'s main chunk has 16 locals (measured with
  `luac5.1 -l -l`); a sibling of the same shape stays near that. The only
  risk is `driver.lua`: its main chunk has 122 locals (same measurement), so
  three or four more locals (the module, the engine, the hub) stay far under
  180; the closures it adds capture two or three upvalues each, far under 50.
  (`tools/lua_limits.py`, the check the Hue repository has, is not in this
  checkout; I measured with `luac5.1`.)
- Testability: best of the three. The chase is deterministic, so its spec needs
  no scripted random, and the fake timer and clock of the Breeze spec
  (`tests/spec/breezeleds_spec.lua:68-168`, `tick` at `:171-182`) are copied
  as they are.

### Option (b): a new mode inside `breezeleds.lua`

A fourth phase pair (`chase`, `calm`) in the same state machine.

- Lines touched: about 230 added to a 1253-line file, plus edits to
  `active` (`:335`), `leaving` (`:341`), `fire` (`:467`), `evaluate` (`:1043`),
  `configure` (`:1059`), `update` (`:1099`), `set_pixels` (`:1120`),
  `debug` (`:1194`) and the `new` fields (`:280`).
- Risk to Breeze: real. Every one of those functions is exercised by the 139
  examples; a new mode has to be threaded through `evaluate`'s three-way
  decision (settle, leave, start) and `RUNNING` (`:160`), and the leave wipe
  (`:1002`) would have to learn that a fixed-speed end is not a Breeze end.
  The spec would stay green only if the new branches never run in it, which is
  also what the new tests cannot then check independently.
- Duplication: none. But the module's header (the contract text at `:1-128`)
  and its name say "Breeze", and the file is already the largest in `fan/`.
- Lua 5.1 limits: the same file, 16 main-chunk locals, methods are table
  fields; no problem.
- Testability: the Breeze spec's helpers fit; but the new cases live in a
  2100-line file, and any helper change risks the old cases.

### Option (c): extract the shared machinery into `fan/pixels.lua`

Move the timer and tick, the budget (`stamp`, `room`, `prune`), the per-pixel
known state with `apply`, `take` and `release`, `shade`, `settle_all` and the
pixel ordering (`reorder`, `lane`) into one module used by both engines.

- Lines touched: about 330 moved out of `breezeleds.lua` and rewritten as a
  composed object, a new `pixels.lua` of about 350, and every `self.shows`,
  `self.hold`, `self.window`, `self.vt`, `self.gen`, `self.order` and
  `self.reserve` reference in `breezeleds.lua` (well over 100 sites, in the
  gust code too) pointed at the object. `drop` (`:515-521`) reaches into
  `self.gust`, `apply` reads the module constant `breezeleds.RECOLOUR_NEEDS_STATE`
  (`:596`, `:668`) which the spec writes (`breezeleds_spec.lua`, three uses), and
  `debug()` (`:1194-1251`) reports fields from all of it.
- Risk to Breeze: highest. The spec only uses public methods, constants and
  `debug()` (88 `debug` calls out of 222 method calls), so a faithful
  refactor is checkable, but the budget's reserve and the late-tick logic read
  and write the same fields (`:876-912`), and a slip changes timing in ways the
  hardware showed to matter (#137 probes). It would be a refactor of shipped,
  hardware-tuned code made for the sake of a feature that is not yet proven on
  the keypad.
- Duplication: none after the move.
- Lua 5.1 limits: fine; but `driver.lua`'s `debug`-style access to the engine
  would have to be kept as it is.
- Testability: the shared object gets its own spec, and Breeze's spec must stay
  untouched to prove the move; that is two big moving parts at once.

### Recommendation

Option (a), and its smallest safe version:

1. `fan/speedleds.lua` with the chase only: no budget, no night scaling, no
   randomness, no `bottom` of its own (it reads the same `Breeze LED Bottom`
   setting), released between chases ("mode A" of section 4), colours read on
   demand through a `colour(speed)` callback so `links.lua` needs no change.
2. `fan/ledhub.lua`, the arbiter, with its own spec.
3. `driver.lua`: re-point the three links closures at the hub, add `speed` to
   the view, one new property row and its `configure`.
4. Keep every helper in `speedleds.lua` named and shaped exactly as in
   `breezeleds.lua`, so that if the chase survives the hardware round, option
   (c) can still be done as a mechanical follow-up with both specs as the net.

Reason: it is the only option that leaves shipped, hardware-tuned code and its
spec literally untouched, and the 120 duplicated lines are small, stable
helpers rather than logic.

## 2. What the new engine takes from `breezeleds.lua`

"As is" means the code can be copied unchanged (a sibling module cannot call
the locals, which are not exported). "Parameter" means the logic stays and an
argument or field changes. "Rewrite" means new logic.

| Function (breezeleds.lua) | What it does | For the chase |
| --- | --- | --- |
| `try` `:168-173` | `pcall` of an option; a missing function fails like one that raises | as is |
| `number_of` `:182`, `round` `:184`, `ceil_div` `:189` | number helpers | as is (`ceil_div` not needed) |
| `step_of` `:194-206` | rounds and clamps the Breeze step to 60..400 | rewrite: a table by speed (section 5) |
| `strength_of` `:209`, `percent_of` `:218`, `scale` `:235` | strength and night helpers | not needed |
| `links_of` `:249-264`, `same_list` `:266-276` | the bound speed links, ascending, 301..306 only, duplicates dropped | as is |
| `new` `:280-323` | the instance fields | rewrite: keep `o`, `log`, `enabled`, `per_speed`, `bottom`, `links`, `order`, `phase`, `hold`, `shows`, `vt`, `cref`, the timer fields (`handle`, `armed`, `gen`, `arm_vt`, `arm_ms`) and `stopped`; drop the budget fields, `gust`, `strength` |
| `say` `:325-333` | log with a prefix, through `pcall` | parameter: the prefix text |
| `any_held` `:345` | whether any pixel is held | as is |
| `reorder` `:349-355`, `lane` `:358-367` | pixel 1 is the bottom (the lowest link, or the highest with `bottom = 6`); `lane(down)` is the pixels in the order a gust runs | as is; the chase runs `lane(down)` |
| `clock` `:407`, `advance_time` `:421-432` | the engine's own time follows `now`, never backwards | as is |
| `cancel` `:436-447`, `arm` `:449-460` | cancels the pending timer (bumps `gen`), arms one one-shot timer | as is |
| `fire` `:467-484` | ignores a cancelled callback, brings time up, never early on the engine's time, then dispatches by phase | parameter: dispatch to `start_chase` (from rest) and `chase_step` (from chase) |
| `prune`, `stamp`, `room`, `drop` `:488-521` | the sliding 30-a-second window | not needed; the `stamp` calls inside `send_*` and `release` are deleted |
| `record` `:525`, `send_light` `:534-545`, `send_paint` `:547-564` | the per-pixel record and the two sends; a failed send leaves that part unknown | as is, without `stamp` |
| `shade` `:567-572` | night scaling | not needed (section 6) |
| `apply` `:578-615` | brings one held pixel to lit-in-colour or dark with the fewest messages | as is with `must` always true (the budget is gone); see below |
| `take` `:617-620`, `release` `:623-631` | hold a pixel (record emptied); give it back (hold and record dropped, then `settle(link)`) | as is |
| `idle` `:933-938`, `settle_all` `:941-951` | forget everything; release every held pixel at once | as is |
| `start` `:954-963` | every pixel taken and sent dark at once, then the first gust | parameter: dark-first plus the preload of the chase colour, then the chase's first frame |
| `wipe_tick` `:1023-1040` | the late-tick rule of a fixed-pace sequence: `k = 1 + floor((vt - due) / step)` steps together, the next arm on the cadence `due + k*step - vt` | pattern to copy for `chase_step` |
| `evaluate` `:1043-1055` | decides settle, leave or start from the inputs | rewrite: two cases, active or not |
| `configure` `:1059-1097` | takes enabled, per_speed, step, night, bottom | rewrite: enabled, per_speed, bottom, rest |
| `update` `:1099-1118` | takes breeze, online, strength, direction | rewrite: speed, online, direction |
| `set_pixels` `:1120-1163` | takes the list; a new pixel joins dark | rewrite: any change settles and rests (section 3) |
| `held` `:1165`, `repaint` `:1170-1185`, `stop` `:1187-1192`, `debug` `:1194-1251` | the links' questions, the shutdown, the inspector | as is for `held`, `repaint`, `stop`; `debug` rewritten for the chase fields |

The gust code (`start_gust` `:733`, `gust_at` `:801-929`, the schedule and
peak functions `:667-731`, `start_rest` `:966`, the wipe `:979-1020`) is not
used.

How the points the brief asked about work today:

**How a pixel is held and released.** `take` (`:617-620`) sets `hold[link]` and
empties `shows[link]`; nothing is sent. From then on the links answer
`is_held(link)` true (`links.lua:364-374`), so `shown`, `refresh`, `set_colors`
and `set_also` send that link nothing (`follow`, `links.lua:378-384`, and the
loops at `:388-400`, `:445`, `:471`) and `answer` goes to `repaint`
(`links.lua:419-429`). `release` (`:623-631`) clears `hold` and `shows` first,
then calls `settle(link)`, so by the time the links hear it `held` is false.
`links:settle` (`links.lua:534-561`) first clears `led` and `led_speed` for the
link, then, in Per speed, sends `BUTTON_COLORS` (on = current = the colour of
the speed the link is lit at, or, for a dark link, its own speed's colour; off =
the Speed LED Off Color) and then `MATCH_LED_STATE`. That is two messages, and
it sets `led[link]` and `led_speed[link]`, so the next `shown` finds nothing to
resend.

**What `settle` does to the stored colour.** In the engine the record is gone
(`:625`). In the links, a pixel that is lit at the shown speed gets that speed's
colour (`links.lua:551-552`); a dark one gets its own speed's colour as its on
colour (`links.lua:553-555`), so a frame colour does not stay loaded. One hole:
when that own speed has no colour set, nothing is sent (`links.lua:556-558`)
and the colour the animation loaded stays on the dark button until something
paints it. Breeze's leave wipe has the same hole; the chase would meet it more
often because it settles every cycle.

**How `apply(link, lit, colour, must, spare)` tracks the pixel and picks the
message** (`:578-615`). The record `shows[link]` has `lit` (true, false or nil =
unknown), `colour` (the colour loaded, as sent) and `base` (the animation colour
it was sent for). The cost table:

| Wanted | Pixel shows | Sent | Messages |
| --- | --- | --- | --- |
| dark | dark | nothing | 0 |
| dark | lit or unknown | `light(link, false)` | 1 |
| lit in C | lit in C (same `colour`, or same `base`) | nothing | 0 |
| lit in C | lit in another colour | `paint(link, C, false, false)`: `BUTTON_COLORS` with `CURRENT_COLOR` (`RECOLOUR_NEEDS_STATE` is false, `:153`) | 1 |
| lit in C | dark, C already loaded | `light(link, true)` | 1 |
| lit in C | dark, another colour or none loaded | `paint(link, C, false, true)` (preload), then `light(link, true)` | 2 |
| lit in C | unknown | `paint(link, C, true, false)`: `BUTTON_COLORS` with `CURRENT_COLOR`, then `MATCH_LED_STATE` | 2 |
| any | a failed send | the part becomes unknown, so the next call sends it again (`:539-541`, `:553-557`) | |

Without `must` a change is sent only if the window has room for it and `spare`
more (`fits`, `:580-582`); otherwise it is dropped and counted (`drop`,
`:515-521`), and nothing queues it: the next tick recomputes what every pixel
wants from the tick number, so a deferred frame is simply tried again (`gust_at`,
`:876-912`).

**What `preload` does and when a colour is already loaded.** A preload is
`BUTTON_COLORS` without `CURRENT_COLOR` (`links.lua:499-504`): the keypad takes
the colour and a dark button stays dark (measured, #137, 2026-11-09). A colour
counts as loaded when `shows[link].colour` equals the colour about to be sent
(`:602`), which is true only for a pixel this engine already sent that colour
since its last `take`; after `take` nothing is loaded, after a failed paint
nothing is loaded, and `repaint` of a dark pixel forgets it (`:1183`).

**How late ticks coalesce.** The gust evaluates the tick that fell due last and
sends each pixel only its final state (`gust_tick`, `:777-786`); the wipe applies
the steps that fell due together (`wipe_tick`, `:1023-1040`). The engine's time
never runs backwards and a timer is never early on it (`fire`, `:471-476`).

**How the budget defers a frame.** Described above (`room`, `drop`, the
`reserve` of `due`, `:697-703`). The chase does not use it.

## 3. Hand-over between the engines

### The rule

Two engines, one keypad. The invariant: **a speed link is held by at most one
engine, and `held(link)` answers `breeze:held(link) or speed:held(link)`.** It
holds because:

- The speed engine's input is "fan mode, speed 2 to 5, online" and Breeze's is
  "Breeze mode, online" (plus its leave wipe). Both come from the same shown
  state (`fanmode.speed(shown)` is 0 in Breeze mode and when stopped,
  `fan/mode.lua`), so they are disjoint except during Breeze's leave wipe.
- The hub calls the speed engine's `update` **before** Breeze's, in the two
  places the driver calls `bleds:update` today (`driver.lua:276`, `:302`), so a
  speed engine that has to let go does so before Breeze takes the pixels in
  `start` (`breezeleds.lua:954-963`), which does not look at anyone else.
- The speed engine holds nothing while it rests, and takes pixels only when a
  `blocked()` callback (any pixel held by Breeze, answered by the hub) says
  false. A chase that is due while Breeze's leave wipe still holds pixels
  tries again after a short wait (the wipe lasts at most six steps of 400 ms).
- The hub's `debug()` reports a link both engines hold, and the spec asserts it
  never happens.

Any change of the pixel list during a chase settles it and goes back to rest:
a chase lasts under a second and its lane changes length with the list, so
there is nothing worth carrying over (Breeze keeps its gust, `breezeleds.lua:1144-1151`).

### The sequences

"Rest" is the engine armed with its one long timer and holding nothing;
"chase" is holding the pixels. Messages are for four bound pixels (N = 4).

| From to | Calls and messages |
| --- | --- |
| Breeze on to fixed speed 4 (a speed press) | The shown state becomes fan mode, speed 4. Hub: `speed:update{speed = 4}` arms the rest timer, sends nothing. `bleds:update{breeze = false}` starts the leave wipe (`breezeleds.lua:1002-1020`): the head lights white on the first pixel and each pixel it leaves is settled, and `links:settle` reads the shown state, so speed 4's pixel ends lit in its colour and the others dark. Then `links:shown` finds nothing to resend. When the rest timer fires: if the wipe is still running, `blocked()` is true and the timer is re-armed for 200 ms; otherwise the first chase starts. |
| Fixed speed, resting, to Breeze (a press of the Breeze link) | `speed:update{speed = 0}`: cancel the rest timer, idle, 0 messages. `bleds:update{breeze = true}`: `start` takes every pixel and darkens it (N messages), then the first gust. |
| Fixed speed, chasing, to Breeze | `speed:update{speed = 0}`: `settle_all` (cancel the timer, release every pixel: `links:settle` reads the shown state, now Breeze, so each pixel goes dark with its own colour loaded: 2N messages). `bleds:update` then darkens them again (N messages). Three messages a pixel in a rare transition; a "yield without settling" would save 2N but needs a Breeze-is-coming signal the hub does not have when Breeze's property is off. Not worth it for v1. |
| Fixed speed to Off (motor stopped) | Resting: `speed:update{speed = 0}` cancels the timer. Chasing: `settle_all`, 2N messages; the shown state is stopped, so every speed link is dark (Off, link 300, is not a pixel and lights through `links:shown`). |
| Fixed speed A to fixed speed B, resting | `speed:update{speed = B}`: cancel the timer, arm a new full rest. 0 messages: nothing is held, so `links:shown` moves the lit LED from A's link to B's as it always did. Restarting the rest gives the new LED a full rest to be seen before any chase. |
| Fixed speed A to B, chasing | `settle_all` (2N messages; `links:settle` reads the shown state, now B, so B's pixel ends lit in B's colour and A's dark), then a full rest at B. The chase never finishes in A's colour: the speed the owner just chose is shown at once. |
| A to B where B is 1 or 6 (no chase) | As above, then idle: no timer. |
| Same speed again (a poll) | No change: `update` compares the new speed and online with the ones it has and returns, so a poll every few seconds does not restart the rest. Direction alone changes nothing until the next chase starts (as Breeze's `:1111-1116`). |
| Offline or the property turned Off | `settle_all`, the same as Breeze's rule (BL-D11). |
| Pixel list changes (a keypad bound or unbound) | Chasing: `settle_all`, then rest. Resting: just keep the list. |
| `OnDriverDestroyed` | `stop()` on both engines before `links:stop()`: cancel the timer, forget the holds, send nothing (`driver.lua:1250` pattern). |

The "A to B while chasing" and "off while chasing" rows have a subtle point
worth a test: the driver calls the engine before `links:shown` (`driver.lua:276-277`),
so the settle already reads the new shown state; and `settle` sets
`led[link]`, so `links:shown` that follows resends nothing.

## 4. The chase

### Two ways to treat the pixels between chases

**Mode A, released between chases (recommended for v1).** During the rest the
engine holds nothing: the links paint the real, truthful state, as they do
today. A chase takes every pixel, plays, and settles every pixel. The engine
needs no knowledge of the speed's LED, `Also Lit At`, or colour changes made
while resting. Cost: a settle burst at the end (2N messages), and a
`BUTTON_COLORS` with `CURRENT_COLOR` on every dark pixel inside it (the settle
of a dark pixel, `links.lua:553-559`), whose effect on a dark button is not
measured.

**Mode B, held through the rest.** The engine keeps the pixels held, paints the
rest picture itself (selected pixel and `Also Lit At` pixels lit in the speed's
colour, the others dark) and never settles until it stops. Steady-state cost per
chase is far lower (2N + 2 messages against 6N - 1) because the chase colour
is the resting colour and stays loaded. But the engine would then own the whole
picture: it needs a callback for "what does the link show at rest"
(`links:lit` plus `links:colour_for`, `links.lua:289-317`), it must repaint
whenever the speed, the colours or `Also Lit At` change while links skips the
held pixels (there is no callback for colour or `Also Lit At` changes today),
and the hand-over with Breeze's leave wipe needs the speed engine to be holding
at the moment the wipe settles pixels. All of that is new surface in `links.lua`
and the hub. Mode B is the optimisation to reach for if the keypad shows the
settle burst or the rate to be a problem.

### The frames

The chase is **one moving dot** over the pixels of `lane(down)`
(`breezeleds.lua:358-367`): from the bottom up for reverse and for an unknown
direction, from the top down for forward (the owner's "the direction the fan is
blowing"; the Breeze rule BL-D30 uses the same mapping, `driver.lua:260`).
Its colour is `colour(speed)`: the selected speed's colour, the same on every
pixel. The selected speed's own LED is not lit as the resting LED while the
chase plays: it is darkened at the start with all the others, lit only for the
step the dot is on it (the dot is the animation and passes it like any pixel),
darkened again, and restored by the settle at the end.

For N = 4, pixels 302, 303, 304, 305 (bottom first), fan at speed 3 (link 303
resting lit), direction up, colour C:

| Frame | When | What is sent | The keypad shows (302 303 304 305) |
| --- | --- | --- | --- |
| 0 | start of the chase | `take` on all four; `light(false)` on each (4 messages); `paint(C, false, preload)` on each (4 messages) | `. . . .` (303 went dark) |
| 1 | + 1 step | `light(302, true)` (1) | `C . . .` |
| 2 | + 2 steps | `light(302, false)`, `light(303, true)` (2) | `. C . .` |
| 3 | + 3 steps | `light(303, false)`, `light(304, true)` (2) | `. . C .` |
| 4 | + 4 steps | `light(304, false)`, `light(305, true)` (2) | `. . . C` |
| 5 | + 5 steps | `settle` on all four (8 messages); 305 is settled straight from lit, so it is not darkened first | `. L . .` with L = 303 lit in its colour |

Then the rest timer is armed from frame 5. Total 23 messages for N = 4. The
dark of frame 0 is a step on its own so that the owner sees the selected LED go
out before the dot appears; it costs no messages. The first frame needs the
dark to have been sent first: the order inside frame 0 is darken, then preload,
so a pixel that was lit (the selected one) is dark before its colour changes
and `BUTTON_COLORS` without `CURRENT_COLOR` never touches a lit pixel.

### What it looks like for 1 to 6 pixels

| N | Frames | Messages (same colour on every pixel) |
| --- | --- | --- |
| 1 | start (dark, preloaded); dot on the pixel for one step; settle | 5. A pulse; with one pixel there is no direction. Recommend: no chase for N under 2 (inactive), the owner's call |
| 2 | start; dot on 1; dot on 2; settle | 11 |
| 3 | start; 3 dots; settle | 17 |
| 4 | as the table | 23 |
| 5 | | 29 |
| 6 | | 35 |

The count is 6N - 1: N dark, N preloads, N arrivals, N - 1 darkenings (the last
pixel is settled instead of darkened), 2N for the settle. It is the same whether
the preload is sent for every pixel at the start, as above (which keeps each
step at two messages, one light on and one off), or lazily as each dot
arrives (preload plus light, three messages a step). The first is better paced.

A **differing-colours** case needs defining. Within one chase the colour is
one value, so nothing differs. It arises when the colour changes between the
preload and the dot's arrival (the owner edits `Speed N LED Color`, or the
colour getter answers something else): a dark pixel whose loaded colour is the
old one costs the preload and the light (2 instead of 1), a lit one a
`BUTTON_COLORS` with `CURRENT_COLOR` (1), so at most N extra messages and the
chase still finishes. `apply`'s cost table above gives the per-case numbers. In
Mode B, steady state, with the colour already loaded: 2N + 2 = 10 messages for
N = 4 (one darkening of the selected pixel, N arrivals, N - 1 darkenings, one
last darkening and one relight of the selected pixel); the first chase after
entry adds up to N preloads.

Variants worth a sentence for the owner: a **fill** (each pixel stays lit
behind the dot) costs 5N and has no darkenings, but reads as a bar, not as
"one after the other"; a **settle on leaving** (each non-selected pixel is
settled as the dot leaves it, the selected one darkened and settled at the end)
costs 21 for N = 4 with the selected pixel in the middle and spreads the end
burst, at the price of a `CURRENT_COLOR` repaint on each dark pixel during the
chase.

### Rate

The steady rate is two messages a step. At the fastest step (section 5, 120 ms)
that is under 17 messages a second, but the start (2N) and the end (2N) are
bursts, and a 4-pixel chase is 23 messages in about 0.6 s. The probes measured
about 40 messages a second spread over four buttons as clean and 20 changes a
second on one button as distinctly flickering (`breeze-leds-design.md` section 1a);
they did not measure bursts. Breeze already settles all pixels at once when
interrupted (`breezeleds.lua:941-951`, 2N messages), so a burst of 2N is not new.
With six pixels at the fastest step the chase is 35 messages in about 0.8 s:
check it on the keypad.

## 5. Timing

- **Step by speed.** A table, not a formula: speed 2 to 5 map to 300, 220, 160
  and 120 ms. Speed 5 equals the Breeze default front step (`STEP_DEFAULT` 120,
  `breezeleds.lua:138`), the one measured on the keypad; the rest are spread
  evenly slower. The values are proposals; the owner may prefer a property for
  the slowest and the fastest. Speeds 1 and 6 have no chase (the owner named 2
  to 5). `step_of(speed)` returns nil for anything else, and nil means inactive.
- **No `TICK_MS`.** Breeze ticks every 50 ms (`TICK_MS`, `:135`) because its
  tails blink at tick resolution. The chase has one event per step, so it arms
  exactly the step (the wipe does the same, `:1019` and `:1039`) and never
  needs rounding to ticks. If the steps are kept multiples of 50 ms, a later
  merge into Breeze's clock stays possible; the table above is.
- **Rest.** One constant, `REST_MS`, between the end of a chase and the start of
  the next (the owner: "the amount of time in between animations is always the
  same"). A proposal of 3000 ms, so the lit LED is seen for as long as the
  chase is long at speed 2 (about 1.8 s with four pixels); the owner's call, and
  probably a property. The period from one chase's start to the next's is
  therefore `(N + 1) * step + REST_MS`, while the gap, which is what the owner
  asked to be constant, is `REST_MS`.
- **No ticking in the rest.** One long timer, exactly as Breeze's rest
  (`arm_rest`, `:462-465`; the header, `:33-34`): nothing changes on the keypad
  while resting, so waking up would only add risk. The first chase after
  entering fixed speed is one rest after the entry, not immediately, so a press
  on a speed button shows its LED before anything animates.
- **What the clock does with a long sleep.** `arm` records `arm_vt` and `arm_ms`
  (`:459`); `fire` brings the engine's time up by the clock's difference
  (`advance_time`, `:421-432`), then never leaves it earlier than due
  (`:471-476`). A timer that fires seconds late (a busy controller) just starts
  the chase: there is no catch-up and no burst, because the rest has nothing to
  replay. Inside the chase, the wipe's rule applies: `k = 1 + floor((vt - due)
  / step)` steps are applied together (the dot jumps `k` pixels; a pixel it
  jumped over was never lit and is not touched), and the next arm is on the
  cadence. Without a `now` clock the engine's time advances by what the timer
  was armed for (`:474-476`). The budget window is not used, so a long sleep
  has no state to prune.

## 6. Proposed interface

```lua
local b = speedleds.new({
    paint = fn(link, colour, with_state, preload),  -- links:paint (the fourth argument must be passed through)
    light = fn(link, lit),                          -- links:light
    settle = fn(link),                              -- links:settle
    timer = fn(ms, cb) -> handle,                   -- handle:Cancel(); the driver's one-shot timer
    now = fn() -> ms,                               -- a clock (only differences are used); optional
    colour = fn(speed) -> "rrggbb" | nil,           -- the colour of Speed N LED Color; nil: no chase for that speed
    blocked = fn() -> bool,                         -- true while the other engine holds a pixel; optional
    log = log,
})
b:configure({ enabled = bool, per_speed = bool, bottom = 1 | 6, rest = ms })
b:set_pixels(list)       -- the bound speed links, any order (same rules as breezeleds)
b:update({ speed = 0 .. 6 | nil, online = bool, direction = "down" | "up" | nil })
b:held(link) -> bool
b:repaint(link) -> bool  -- what the pixel shows: lit, paint(colour, true); otherwise light(false), as Breeze's
b:stop()                 -- cancel the timer, forget every hold, send nothing; final
b:debug() -> table       -- phase (idle, rest, chase), pixels, held, frame, step, rest, direction, speed
```

There is no `random` (the chase is deterministic) and no `night`: the chase
colour is the very colour the link shows at rest, which is at full value and
dimmed by the keypad as the rest LED is, so scaling it would make the dot
dimmer than the LED it replaces. The owner may want a night setting anyway;
`shade` (`breezeleds.lua:567-572`) is four lines to copy.

**What `update` needs.** `speed` is `fanmode.speed(shown)` (`fan/mode.lua`): the
fan-mode speed, 0 when stopped or in Breeze mode, nil while unknown (treated as
0); one field replaces `on` and `breeze`. `online` is `phase == "online"`,
`direction` is `AIRFLOW[shown.direction]` (`driver.lua:260`), nil counting as up.
These are fields of `leds_view` (`driver.lua:262-269`), which today builds
`breeze`, `strength`, `online` and `direction`; one `speed` field is added. The
shown state is the wanted one over the in-flight one over the confirmed, so
the engine reacts to a press at once.

**Where the colours come from.** `driver.lua`'s `apply_colors` (`:690-705`)
reads the six `Speed N LED Color` rows and hands `links:set_colors(mode, colors,
off)`; `links:set_colors` stores them in `links.colors` (`links.lua:458-465`).
`links:colour_for(link, speed)` (`links.lua:312-317`) answers `colors[speed]` in
Per speed and nil otherwise, so the closure `colour = function(speed) return
links:colour_for(300 + speed, speed) end` needs no change in `links.lua` and
always reads the current value (an edit mid-chase takes effect at the next
arrival and the settle uses it too). A colour that is nil, or any speed
outside 2 to 5, or fewer than two pixels, or not Per speed, makes the engine
inactive for that speed, with one debug line saying which. The chase never
invents a colour.

**Properties.** One new LIST `Speed LED Animation` (`Off`, `Chase`, default
`Off`), with the same L42 note as Breeze's (Per speed needed). `Breeze LED
Bottom` is read by both (the owner's "bottom" is the keypad's physical order,
not a Breeze thing), or renamed later; renaming a property in `driver.xml`
loses the owner's value, so v1 keeps the name.

**Busted spec cases** (`tests/spec/speedleds_spec.lua`, fake timer, clock and
recorders as in the Breeze spec, no random):

1. Constants: the step table (120 for speed 5, slower below), the rest.
2. Inactive: not enabled, not per_speed, not online, speed 0, 1, 6 or nil,
   fewer than two pixels, a nil colour: nothing sent, no timer, `held` false.
3. Entry: speed 4 and online arms one rest timer of `REST_MS`, sends nothing.
4. The first chase after the rest: frame 0 sends dark then preload for every
   pixel, in that order; the pixels are held.
5. Frames for N = 2, 3, 4, 6, direction up and down, bottom 1 and 6: the dot's
   order, exactly one lit pixel at any frame, each step's timer is `step`.
6. The selected speed's pixel is dark during the chase and lit again after it.
7. The last frame settles every pixel once, and the pixel that held the dot is
   settled without a darkening; the rest timer is armed after it.
8. Message counts: 6N - 1 for N = 1 to 6; the colour changed mid-chase adds at
   most N.
9. The rest's length is the same at every speed; the step differs by speed.
10. Speed change mid-rest restarts the rest with nothing sent; mid-chase it
    settles all pixels (2N) and rests; to 1 or 6 it settles and idles.
11. Same inputs again change nothing (no new timer).
12. Breeze arrival (speed 0) mid-chase settles; mid-rest cancels; offline the same.
13. `blocked()` true at the end of a rest re-arms 200 ms and holds nothing; false
    starts the chase.
14. Late tick inside the chase: `k` steps together, the dot jumps, no pixel left
    lit behind it, the cadence kept; a late rest timer starts one chase, no burst.
15. `set_pixels` mid-chase settles and rests; at rest it only stores.
16. `held` true only during a chase; `repaint` of a held lit pixel sends
    `paint(colour, true)`, of a dark one `light(false)`.
17. Failures: a `paint` or `light` that raises leaves that part unknown and the
    chase finishes; a timer, clock or colour callback that raises is logged, never raised.
18. `stop` cancels, forgets, answers `held` false and ignores every later call.
19. `debug` reports phase, held pixels and the frame.

Hub spec (`tests/spec/ledhub_spec.lua`): `held` is the or of both; `update`
calls the speed engine first; a link held by both is reported; `repaint` goes to
the holder; `set_pixels` and `stop` reach both; `blocked` reflects Breeze's holds.

Integration (`tests/spec/fan_driver_spec.lua`, the replayed keypad of
`:925-960`): a press on Speed 3 with four bound pixels shows, after the rest,
the dot passing and the pixel for 3 lit again; Breeze then takes over with no
two animations at once.

## 7. What `links.lua` and `driver.lua` would change

`links.lua`: nothing is required. `held`, `repaint` and `pixels` stay single
callbacks (`:173-175`) and now point at the hub. Optional, cosmetic: the debug
and warn texts say "the Breeze animation" (`:370`, `:406`, `:411`, `:693`) and
the header (`:37-55`) names only Breeze.

`driver.lua`:

- top, requires (`:34-45`): add `fan.speedleds` and `fan.ledhub`.
- locals line (`:190`): add `sleds` and `hub`.
- `leds_view` (`:262-269`): add `speed = fanmode.speed(shown)`.
- `listener.shown` (`:271-280`): `bleds:update(...)` becomes `hub:update(...)`.
- `listener.phase` (`:302`): the same.
- `bleds = breezeleds_mod.new` (`:390-404`): the `paint` closure passes `preload`
  through (the open question at the top).
- after it: create `sleds` with `paint`, `light`, `settle`, `timer`, `now`, a
  `colour` closure over `links:colour_for` and a `blocked` closure over the hub.
- `hub = ledhub_mod.new({ breeze = bleds, speed = sleds })` before `links`.
- `links_mod.new` (`:408-445`): `held`, `repaint`, `pixels` closures call the hub.
- `apply_breeze_leds` (`:775-789`) or a sibling `apply_speed_leds`:
  `sleds:configure{ enabled, per_speed, bottom, rest }` from the new property.
- `dispatch.properties` (`:791-805`): the new row, and `Speed_LED_Colors`
  configures the speed engine before `apply_colors`, as for Breeze (leaving Per
  speed settles with the per-speed colours).
- the L42 note (`:786-788`): also for the new property.
- `OnDriverDestroyed` (`:1250`): `hub:stop()`.

Also: `src/modernforms_fan/driver.xml` (the new property row, `:276-318` area),
the owner's manual (`www/documentation.html`), `CHANGELOG.md`, and the Composer
checklist; and the contract for the feature (the brief's edge-cases-first rule).

## Risks and unknowns

1. The dropped `preload` at `driver.lua:391-393` (above). Unknown whether it
   is deliberate; fixing it changes what the shipped Breeze sends.
2. The settle of a dark pixel sends `BUTTON_COLORS` with `CURRENT_COLOR` before
   `MATCH_LED_STATE false` (`links.lua:334-338`, `:557-559`). Whether a dark
   keypad button flashes on that was not measured; the chase would do it to
   every dark pixel each cycle (Breeze's wipe does it once).
3. Bursts of 2N messages (start, end) at five or six pixels and the fastest
   step were not measured; only an evenly spread 40 messages a second was.
4. Whether `BUTTON_COLORS` without `CURRENT_COLOR` on a lit button leaves it lit
   was not measured; the proposed order (darken, then preload) avoids needing
   to know.
5. A pixel whose own speed has no colour keeps the chase colour loaded after
   the settle (`links.lua:556-558`).
6. Owner decisions the code cannot settle: the step table, the rest length
   (and whether it is a property), no chase below two pixels, single dot or
   fill, whether speeds 1 and 6 stay still, night scaling, the property's name,
   the shared `Breeze LED Bottom`, and what the dot does when the selected
   speed's pixel is not bound (the proposal: nothing special).
7. Mode B (held through the rest) is cheaper in messages (10 against 23 for
   N = 4, steady state) but needs new links callbacks; whether Mode A is good
   enough is a hardware question.
8. The shown state is the wanted one: a command the fan refuses brings the
   shown speed back (`listener.dropped`, `driver.lua:240-245`), which the
   engine will see as a speed change and settle and rest.
9. Everything here is read from code and the 139-example Breeze spec, which I
   ran (green, as was `luacheck src`); none of it was run on a keypad.
