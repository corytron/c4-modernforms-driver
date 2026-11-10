# Fixed-speed chase on the keypad LEDs: lifecycle edge cases

> **Research (2026-11-09) for [issue #159](https://github.com/corytron/c4-modernforms-driver/issues/159)**,
> read-only: nothing here was tried on the house and nothing is built. The
> owner asked for a second keypad animation, for the fan's **fixed speeds**:
> at speed 2, 3, 4 or 5 a chase runs LED after LED across the bound speed
> buttons, in the direction the fan blows, at a pace matched to the speed
> (speed 2 slower, speed 5 faster), then a **constant rest** in which only the
> selected speed's LED is lit, then again. The chase's colour is that speed's
> `Speed N LED Color`. This note lists the lifecycle corner cases on the fan's
> side and on Control4's side, recommends one decision for each, and feeds the
> feature's contract. Where it needs a fact about the Breeze animation it
> takes it from the contract [`breeze-leds-design.md`](breeze-leds-design.md)
> and the shipped module `src/modernforms_fan/fan/breezeleds.lua`; the
> hardware and SDK facts behind both are in
> [`breeze-leds-field-research.md`](breeze-leds-field-research.md),
> [`breeze-leds-sdk-research.md`](breeze-leds-sdk-research.md) and
> [`edge-cases-breeze-leds.md`](edge-cases-breeze-leds.md) (rows BL1 to BL70).

**Decisions:** **AUTOMATIC** (the driver just does it), **OFFERED** (a
property or action the dealer chooses), **FORBIDDEN** (never without a
click, or not at all where the row says so). **Markers:** VERIFIED names a
primary source (a repository file and line, an SDK file, a house
measurement); ASSUMED says the claim has none. Snap One's documents are
paraphrased, never quoted. Placeholders only: fan 10.0.2.151, controller
10.0.2.10, MAC 00:00:5e:00:53:01.

**The short answer.**

1. **The chase is a second engine beside the Breeze one, and only one engine
   may own a pixel at a time.** Both want the same speed links 301 to 306 and
   the same three callbacks in `links.lua` (`held`, `repaint`, `pixels`). The
   Breeze animation always wins: it takes the pixels dark at once, and the
   chase waits while the Breeze ending wipe still holds any (SL12 to SL16).
2. **Hold pixels only while the chase runs.** During the rest the links own
   every LED and the selected speed's button is lit by the code that lights
   it today, Also Lit At included. That keeps the rest identical to a build
   with the animation off, so every lifecycle case that is already right
   today (a bind, a `REQUEST_BUTTON_COLORS`, a changed colour) stays right
   (SL63).
3. **Everything is decided from the same shown state, and must be
   idempotent.** The model fires `shown` for any field that changes, light
   level included (`src/modernforms_fan/fan/model.lua` lines 408 to 414), so
   the engine must restart only when the fan mode, speed, direction or online
   flag really changes, never on a light-level fade tick (SL7).
4. **The cost is small and steady.** About 11 messages per cycle with four
   pixels; 0.35 to 2 messages a second on average for the timings tried in
   section 5, peaks of 5 to 17 a second for under half a second, inside the
   Breeze engine's 30 a second budget and its measured clean 40 a second. The
   load that matters is the **hours**: a fan at speed 4 runs the chase all
   night (SL57, SL58).
5. **Two things the owner's text leaves open and the contract must settle:**
   speeds 1 and 6 (SL20, SL21) and the night (SL55).

| Key | Source |
| --- | --- |
| BLD | [`breeze-leds-design.md`](breeze-leds-design.md): BL-D1 to BL-D30 |
| BLE | [`edge-cases-breeze-leds.md`](edge-cases-breeze-leds.md): BL rows and facts LF1 to LF19 |
| FLD | [`breeze-leds-field-research.md`](breeze-leds-field-research.md) (Zigbee, the keypad) |
| V1D | [`v1-design.md`](v1-design.md): V10, V26, V27, section 11.1 K6 |
| ECC | [`edge-cases-control4.md`](edge-cases-control4.md): F14 to F16, C3, C4, C6, C14 |
| code | `src/modernforms_fan/fan/breezeleds.lua`, `links.lua`, `mode.lua`, `model.lua`, `driver.lua`, `driver.xml`, `texts.lua`, as of the checkout of 2026-11-09 |
| SDK | `~/c4-tools/reference/docs-driverworks-*`, each `source/includes/`: FUND `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`; API `34_timer/_1-SetTimer.md`, `22_miscellaneous/_24-OnDriverDestroyed.md`, `24_properties/_2-GetProjectProperty.md`; KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md` |

## 0. Facts the decisions rest on

| # | Fact | Status |
| --- | --- | --- |
| SF1 | A speed link's LED is decided by `links:lit(link, shown)`: lit when the shown speed is the link's own speed or its `Also Lit At` speed, and **always dark outside fan mode** (stopped, Breeze, state unknown). The colour sent just before a lit state is `colour_for(link, speed)`, the colour of the **speed the fan is at**, so a button lit through Also Lit At shows the colour of the speed it stands in for. | VERIFIED: `links.lua` `lit` (289 to 308), `colour_for` (312 to 317), `push_led` (343 to 358) |
| SF2 | "Fan mode" is `fan_on` true and `wind` not true. In Breeze the stored speed stays in the state, so an engine that reads only `speed` would chase during Breeze; it must gate on `mode.fan_on(shown) == true`. | VERIFIED: `mode.lua` (the header and `fan_on`, `speed`, `breeze`) |
| SF3 | Shown is wanted over in flight over confirmed. A press changes it at once, a refused or failed command changes it back, and a change from the Modern Forms app, the remote or the wall control arrives with the next poll (15 s; 2 s inside a 20 s fast window). | VERIFIED: `model.lua` `Model:shown` (600 to 613), `FAST_POLL_MS`, `FAST_WINDOW_MS` (68, 69); BLD BL-D9 |
| SF4 | `listener.shown` calls `bleds:update(...)` **before** `links:shown(shown)`, so pixels are held before the links look; `listener.phase` calls `bleds:update` with the online flag. | VERIFIED: `driver.lua` 272 to 279, 285 to 303 |
| SF5 | The fan's airflow: `forward` is blowing down, `reverse` is blowing up. The Breeze engine counts an unknown direction as up. `can_reverse` is declared `True`. A state read with no `fanDirection` is listed as missing by the model. | VERIFIED: `driver.lua` (`AIRFLOW`, `leds_view`), `driver.xml` line 440, `model.lua` `find_missing` (1440 to 1456); BLD BL-D30 |
| SF6 | A pixel is a speed link 301 to 306 with a bound button; `pixels_list()` includes a link bound by a button not yet known by number; every button on one link shows the same state. | VERIFIED: `links.lua` `pixels_list` (667), `bookkeeping_changed`, `send_pixels` |
| SF7 | While the Breeze engine holds a pixel the links send that link nothing on `shown`, `refresh`, `set_colors` and `set_also`; they keep their tables for the settle. `answer` (a bind or `REQUEST_BUTTON_COLORS`) on a held link calls `repaint(link)`. | VERIFIED: `links.lua` `follow` (378), `answer` (419), `set_also` (434), `set_colors` (452) |
| SF8 | `paint` and `light` clear `led[link]` and `led_speed[link]`, so the next ordinary `shown` after a release re-sends that link in full; `settle(link)` sends the link's colours first (always, under Per speed, also for a dark link: its own speed's colour) and then its state, two messages whatever was sent before. | VERIFIED: `links.lua` `paint` (487), `light` (515), `settle` (534 to 566) |
| SF9 | The Breeze engine's costs per change: a lit pixel recoloured 1 message; a dark pixel lit with its colour already loaded 1; a dark pixel lit with a new colour 2 (preload, then state); a darkening 1; a release 2. It keeps a sliding-window budget of 30 messages a second (40 a second measured clean on the house keypad, four buttons at 10 changes a second each); one button flickers distinctly at 20 changes a second. | VERIFIED: `breezeleds.lua` `apply` (578 to 614), `release` (623), `BUDGET_PER_S`; BLD section 1a and BL-D23, BL-D24 (house probes of 2026-11-09) |
| SF10 | Snap One warns that fast periodic level updates (its example: every 20 ms) flood Zigbee and leave keypad LEDs wrong. No keypad LED rate is documented. `C4:SetTimer` needs a delay above 0 and has no documented minimum. | VERIFIED-doc: FUND `_50-LIGHTV2BESTPRACTICE.md`; API `34_timer/_1-SetTimer.md`; BLE LF15 |
| SF11 | With Echo LED On Press set on a button, the button lit at the push and went dark at the release. | VERIFIED: V1D 11.1 K6 (one button, bound to Fan Off) |
| SF12 | `Speed 1` to `Speed 6 LED Color` all default to `0,0,255`, pure blue. Pure blue **vanished at the keypad's night dimming** on the house. | VERIFIED: `driver.xml` 233 to 268; BLD section 1a |
| SF13 | `apply_breeze_night` runs the sunrise and sunset logic only while `Breeze LED Animation` is `Gusts`; otherwise it sends `night = false`. | VERIFIED: `driver.lua` 741 to 770 |
| SF14 | The only result row the animation can write is L42 (`breeze_leds_need_per_speed`), on a property change, not on the late-init replay. Neither engine's state appears in Status or any property; `bleds:debug()` has no caller in `driver.lua`. | VERIFIED: `driver.lua` 775 to 790, `texts.lua` 1094 to 1098; `grep` of `driver.lua` finds no `debug()` call |
| SF15 | `OnDriverDestroyed` calls `bleds:stop()` before `links:stop()` and sends nothing; whether a send there would still arrive is not documented. The keypad keeps its last frame until the first contact, whose `links:refresh()` sends all ten links in full. | VERIFIED: `driver.lua` 1239 to 1256; `links.lua` `refresh` (395); BLD BL-D17; SDK API `22_miscellaneous/_24-OnDriverDestroyed.md` |
| SF16 | The second driver, `src/modernforms_breeze_fan/`, requires only `common.log`, `common.dispatch` and `common.device` and has no Button Links; the fan's links, LED code and animations live in `src/modernforms_fan/` only. | VERIFIED: `modernforms_breeze_fan/driver.lua` line 53 to 55, `driver.xml`; BLE LF17 |

## 1. The model the cases are decided against

Every name below is a proposal for the contract, not existing code.

- **Engine:** a new pure module beside `breezeleds.lua` (suggested
  `src/modernforms_fan/fan/speedleds.lua`), built the same way: everything
  that touches Director is an argument (`paint`, `light`, `settle`, `timer`,
  `random`, `now`, `log`), every call goes through `pcall`, one one-shot
  timer at a time, a generation counter so a cancelled timer's callback is
  ignored.
- **Active** means: enabled, `Speed LED Colors` = `Per speed`, fan online,
  fan mode (`mode.fan_on(shown) == true`), a speed that is animated, a
  colour set for that speed that is not the off colour, at least two pixels,
  a known direction.
- **Cycle:** rest of a constant length (nothing sent, nothing held), then a
  chase of N steps, one per pixel, in the airflow direction, the lit pixel in
  the speed's colour, every other pixel dark, the selected speed's own button
  dark while the chase runs; after the last step the selected button(s)
  light again by a forced re-assert and the next rest starts.
- **Step time** depends on the speed (the speed's pace); **rest** does not.
- **Hold only during the chase.** At the chase start the engine takes all
  pixels (`held` true), darkens the selected one(s) and lights the first dot;
  at its end it releases every pixel, forcing the selected pixel(s) with their
  colours and darkening any other pixel its table says is lit.
- **One owner:** `held(link)` in `driver.lua` becomes "the Breeze engine holds
  it or the chase engine holds it"; the chase never takes a pixel the Breeze
  engine holds and starts only when the Breeze engine is idle (SL14).

## 2. Cases

### 2.1 Speed changes and presses

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL1 | The speed changes mid-chase or mid-rest, up (2 to 4) or down (4 to 2) | The shown speed changed, so the engine stops at once: the chase is cancelled, every pixel is released with the diff rule (selected pixel of the **new** speed forced lit in its colour, the dot and the old selected pixel darkened), a new cycle starts with a full rest at the new pace. A chase never finishes at the old pace after the change. Cost about 3 to 5 messages, the same as a speed press today. | **AUTOMATIC** | SF3, SF8; BLD BL-D9 (newest shown state wins) |
| SL2 | Several presses in quick succession (2, 3, 4, 5 within a second) | Each press changes the shown speed; the engine re-evaluates each time and cancels its timer each time; nothing is chased while the speed keeps changing, because every change restarts the rest. The traffic is only the links' own LED messages for the press, as with the animation off. The engine must diff, not call `links:settle` on every pixel (2 messages a pixel, 8 for four): at 4 presses a second that would be about 32 messages a second. | **AUTOMATIC**; **FORBIDDEN**: a release that settles every pixel on every change | SF8, SF9; `links.lua` `settle` |
| SL3 | A press on the button of the speed the fan already has | No shown change, so the chase carries on or the rest runs on. If the keypad echoes the press (Echo LED On Press) the button goes dark at the release, and today nothing re-lights it; the engine's forced re-assert of the selected LED at the end of every chase heals that within one cycle, which is a small side benefit. | **AUTOMATIC** | SF11; `links.lua` `push_led` (changes only) |
| SL4 | A press on a button whose LED is the dot right now | The press is a speed command like any other. A different speed: SL1. The same speed: SL3, and the dot goes on (each dot arrival sends an explicit lit state, so a button the keypad echo darkened is lit again when the dot gets there, or one step later at worst). | **AUTOMATIC** | SF11 |
| SL5 | Fan Cycle (308) and Fan Toggle (307) | Cycle changes the speed (SL1). Toggle changes `fan_on`: off (SL8) or on at the stored speed (SL10). Neither is a pixel; both LEDs follow fan mode as today and are never touched. | **AUTOMATIC** | `links.lua` `lit` (307, 308 follow fan mode); BLD BL-D2 |
| SL6 | A press the fan refuses or never receives (shown goes to the target and back) | A short restart at the target speed, then a second restart at the real one. Each restart costs only the diff, and the rest is restarted both times, so no chase runs in the gap. | **AUTOMATIC** | BLE BL8, BL17; SF3 |
| SL7 | `shown` fires for a field that has nothing to do with the chase (the light's level while it fades, the light on or off, a poll that fills in a field) | The engine reads speed, direction, fan mode and online from the update and ignores the call when none of them changed, as `breezeleds.lua` `update` does (it re-evaluates and changes nothing). **Restarting the rest on every shown event would starve the chase**: during a light fade the model fires `shown` on every step. | **AUTOMATIC**; **FORBIDDEN**: restarting on an unchanged state | VERIFIED: `model.lua` 408 to 414 (`queue_shown` fires when any field differs); `breezeleds.lua` `update` (1099 to 1118) |

### 2.2 Fan off and on

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL8 | The fan is turned off mid-chase (keypad Off, the main tile, the app, programming) | The engine stops at once with no ending animation (the owner asked for none): pixels released, the dot darkened, nothing selected to light (every speed LED is dark when stopped), and the links light Off in the keypad's own colour as today. Off is not a pixel, so the chase never touches it. | **AUTOMATIC** | `links.lua` `lit` (300 follows `stopped`); BLD BL-D2 |
| SL9 | The fan is turned off mid-rest | The pixels are not held; the links do everything; the engine only cancels its rest timer. | **AUTOMATIC** | model section 1 (hold only during the chase) |
| SL10 | The fan is turned on at a speed (a press, the app, programming, a schedule) | The links light the selected button as today; the engine starts a cycle with a rest (SL1's rule), not a chase at once. Whether the first chase should come at once as a "the fan is running at this pace" confirmation is a design choice: owner question 3. | **AUTOMATIC**; first-chase timing: **OFFERED** (question 3) | SF3 |
| SL11 | The motor is stopped with a Breeze mode stored (status ` Breeze set`) | Not fan mode and not blowing: no chase. The remote's power-on that resumes Breeze is a Breeze start (SL12). | **AUTOMATIC** | `mode.lua` `fan_on` (false when stopped); BLE BL3 |
| SL12 | Fan mode to Breeze while the chase runs (any source), the Breeze animation **enabled** | The Breeze engine's `start()` takes every pixel dark at once and sends the dark itself. The chase engine must release **without sending anything** (not through `links:settle`) so nothing is sent twice; `led[link]` is already cleared by `light`, so the links resend honestly at the next ordinary `shown`. The `update` order of SF4 gives the Breeze engine its turn first; the chase engine is told in the same call. | **AUTOMATIC** | SF4, SF8; `breezeleds.lua` `start` (954) |
| SL13 | Fan mode to Breeze, the Breeze animation **disabled** (or not Per speed) | Nobody else takes the pixels, so the chase engine releases with a settle (diff rule): in Breeze mode every speed LED is dark, so the dot and the selected button go dark and 311 lights through the links. | **AUTOMATIC** | `links.lua` `lit` (Breeze: speed links dark); BLE LF10 |
| SL14 | Breeze to fan mode (a speed press, Toggle, Cycle, the app) while the Breeze **ending wipe** is still running (BL-D8, 4 pixels at 120 ms is about 0.5 s; up to 2.4 s with six at 400 ms) | The wipe settles pixels one by one and lights the pressed one as the head passes. The chase engine must not start while the wipe holds any pixel. Ownership rule: the chase starts its **rest** when the shown state is fan mode, and checks `not bleds:any_held()` again when the rest ends and again at every chase step; if the wipe is somehow still running it postpones by one step. Minimum rest 2 s exceeds the longest wipe at the defaults. The Breeze module has no idle callback today (`debug().phase` is the only way to read it); the contract should add an optional `on_idle` to it. | **AUTOMATIC** | `breezeleds.lua` `start_leave` (1002), `wipe_tick`, `idle` (933); BLD BL-D8, BL-D10 |
| SL15 | The Breeze animation is disabled, Breeze to fan mode | No wipe; the links answer normally; the chase starts with a rest. | **AUTOMATIC** | BLD BL-D11, BL-D18 |
| SL16 | Breeze, fan mode, Breeze again within a second or two (two presses, a Toggle pair, a refused press) | Each flip is decided by the owner rule of SL12 to SL14; the newest shown state wins. Because the chase engine starts with a rest and holds nothing during it, a flapping state never leaves a pixel with two owners. | **AUTOMATIC**; **FORBIDDEN**: a pixel held by both engines | BLD BL-D10 |
| SL17 | Both properties changed (Breeze LED Animation and the chase property) while Breeze is blowing or ending | Properties are read together and each engine is configured in the same `dispatch.properties` pass (the `Speed LED Colors` handler already does this in a fixed order, the Breeze engine first). The chase engine's own configure never takes a pixel the Breeze engine holds. | **AUTOMATIC** | `driver.lua` 788 to 800 |

### 2.3 Which speeds, which buttons, which order

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL18 | Speeds 2, 3, 4, 5 | The owner's list. Step times matched to the speed: slower at 2, fastest at 5, rest constant. Candidate (for the contract): step(s) = base + 3 x base x (5 - s) / 4 with base 120 ms at speed 5, that is 390, 300, 210, 120 ms; four pixels make a chase of 1.6, 1.2, 0.84, 0.48 s. | **AUTOMATIC** | the owner's text; section 5 |
| SL19 | Fan speed 0 or unknown | Stopped (SL8) or not known (nothing decided from an unknown state, as for the LEDs): no chase. | **AUTOMATIC** | `mode.lua` `speed`; `links.lua` `lit` returns nil for an unknown speed |
| SL20 | Speed 1 (the owner named only 2 to 5) | Options: (a) **no chase**, the LED rests as today (the literal reading); (b) chase at an extrapolated slow pace (about 480 ms a step by the candidate rule). On the house, speed 1 is the Low button lit blue through Also Lit At, so (b) is possible and consistent. The owner may have left 1 out on purpose (it is the quiet night speed) or by omission. | **OFFERED**: a list property (question 1); default for the first build: speeds 2 to 5 only | `links.lua` `lit` (Also Lit At); `status.md` house keypad rows |
| SL21 | Speed 6 | Same options. A chase faster than speed 5 would need a step under 120 ms: the candidate rule gives 30 ms, below the Breeze engine's smallest step (60 ms, `STEP_MIN`); two messages every 60 ms is 33 messages a second, above the 30 a second budget. If 6 is animated it must be clamped (about 100 ms, 20 messages a second at the peak) and so is barely faster than 5. That is a reason to leave 6 out by default. | **OFFERED** (question 1); clamp at 100 ms if on; **FORBIDDEN**: a step under 60 ms | `breezeleds.lua` `STEP_MIN`, `BUDGET_PER_S`; SF9 |
| SL22 | The selected speed's own button is not bound (fan at speed 4 with only 2, 3 and 5 bound; fan set to 6 from the app while only 2 to 5 are bound) | The rest has no lit LED (all dark, which is what the links show today: `lit` is false for every bound link). Animated speeds still chase over the bound pixels, since the pace is the speed's information. At an animated speed with the pixel missing the chase is the only sign. At an unanimated speed (6) nothing changes from today. | **AUTOMATIC** | `links.lua` `lit`; SF6 |
| SL23 | Also Lit At makes **two** buttons lit at one speed (Low also at 3 while Medium is Speed 3), or lights one button at two speeds (the house: Low at 1 and 2, High at 5 and 6) | "The selected buttons" are exactly the links for which `links:lit(link, shown)` is true, never a guess from the speed number. The chase darkens all of them while it runs and re-asserts all of them at its end, each in the colour `colour_for` gives for the shown speed. | **AUTOMATIC** | SF1; V1D V26 |
| SL24 | Exactly two pixels bound, or one | One pixel: the chase would be a blink of the button the rest already shows, not a chase; no chase. Two pixels: the dot runs 1 then 2, the rest lights the selected one (a 2-button run). Three or more: as the owner described. | **AUTOMATIC**: at least two pixels, else off | BLD BL-D2 (a 2-button keypad shows no animation); BLE BL28 |
| SL25 | No pixel bound (zero speed buttons: a 2-button keypad bound to Toggle and Off, or no keypad) | The engine is idle, holds nothing, sends nothing, and its timer is not armed. | **AUTOMATIC** | BLD BL-D2 |
| SL26 | Off (300), Toggle (307), Cycle (308), Breeze (311) and the light's links 200 to 202 | Never pixels: the same set as BL-D2. In fan mode Toggle and Cycle stay lit and Off dark; none of them is included, darkened or recoloured by the chase. | **AUTOMATIC**; **FORBIDDEN**: chase pixels outside 301 to 306 | `links.lua` (`FIRST_SPEED`, `LAST_SPEED`, `is_held`, 362 to 373); BLD BL-D2 |
| SL27 | Which end is the top | The keypad layout does not change between the two animations: reuse `Breeze LED Bottom` (`Lowest speed`, `Highest speed`, the house is `Highest speed`) and mark in the manual that it covers both. Renaming the property would drop the owner's value (properties may come and go but should not be retyped), so keep the name. | **AUTOMATIC** (reuse); a second bottom property **FORBIDDEN** | BLD BL-D4; ECC F2; `driver.xml` 289 to 297 |
| SL28 | Direction: the chase runs the way the fan blows | `forward` is down, so the dot starts on the **top** pixel and ends on the bottom one; `reverse` is up, bottom to top. "Top" means the end `Breeze LED Bottom` does not name. Use the same `AIRFLOW` mapping as BL-D30. | **AUTOMATIC** | SF5; `driver.lua` `AIRFLOW` |

### 2.4 Bindings, updates, restarts

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL29 | A speed button is bound while a chase runs | The new pixel is taken at once, answered dark; it joins the dot's route from the next chase (the current chase keeps its length). During a rest nothing is held: the links answer the bind in full as they do today. | **AUTOMATIC** | BLD BL-D16; `links.lua` `binding_changed`, `answer` |
| SL30 | A speed button is unbound (last button on that link) while a chase runs | The pixel leaves the list without a send, as in BL-D16; a dot due to land on it skips it. The button keeps its last colour like any unbound button (the manual says so). If the list falls below two pixels the chase ends and the pixels are released. | **AUTOMATIC** | BLD BL-D16; `breezeleds.lua` `set_pixels` (1120) |
| SL31 | The keypad is replaced or re-added in Composer | Every binding of the old keypad is gone (and programming naming it is deleted, `composer-remote.md`), so pixels fall to SL30; the new keypad's binds arrive one by one, each SL29. A burst of binds must not restart the cycle once per bind: `set_pixels` with an unchanged list changes nothing, with a changed list re-plans the route only. | **AUTOMATIC** | `breezeleds.lua` `same_list`; BLE BL40 to BL47 |
| SL32 | The driver is updated in place (Composer's Update Driver) | The chase is stopped by `OnDriverDestroyed` (timer cancelled, nothing sent); the keypad keeps its last frame (a dot lit, or the selected button dark) until the first contact, whose refresh sends every link in full; then a rest, then the cycle. No state is persisted. | **AUTOMATIC**; persisting the cycle is **FORBIDDEN** | SF15; BLD BL-D17 |
| SL33 | A Director restart or a controller reboot | The same as SL32 (timers die with Director; the keypad may or may not have its own state restored). The cycle restarts with a rest after the first contact. | **AUTOMATIC** | SF15; BLE LF13 |
| SL34 | `OnDriverDestroyed` during the chase | The engine cancels its timer, forgets its holds, and sends **nothing**: a send there may or may not arrive. Its `stop()` is final (every later call is ignored). | **AUTOMATIC** | `breezeleds.lua` `stop` (1187); `driver.lua` 1250 |
| SL35 | The dev loop's reload (a `--dev` build only) | The reload calls `OnDriverDestroyed` itself, so the driver cancels its own timers (SL34), then runs init again; `bleds` and the new engine must both be stopped in that order. | **AUTOMATIC** | BLE LF13; `dev-loop.md` |

### 2.5 The fan's side

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL36 | The fan goes offline (about 45 s of failed polls), mid-chase or mid-rest | Not online: the engine stops at once and releases (diff rule); the links keep the last state ("LEDs keep the last state"), so the selected button stays lit and the keypad is calm; a fan that lost power at the wall switch is not shown as running a chase. | **AUTOMATIC** | BLD BL-D11; BLE BL11 |
| SL37 | The fan comes back online | The state is re-read at the first contact; if fan mode at an animated speed still holds, a cycle starts with a rest. If the fan came back at another speed, SL1. | **AUTOMATIC** | BLD BL-D11 |
| SL38 | The fan is rebooting or waiting (phases `rebooting`, `waiting`, `foreign`, ...) | Any phase but `online` is "not online": SL36. | **AUTOMATIC** | `driver.lua` `leds_view` (`online = phase == "online"`) |
| SL39 | The speed or direction is changed in the Modern Forms app, by the remote or the wall control | Seen at the next poll, so the chase's pace or direction changes up to 15 s late (2 s in the fast window). The same as every LED today; the manual already says so for Breeze. | **AUTOMATIC** | SF3; BLE BL2 |
| SL40 | The direction is reversed mid-chase | The chase in flight finishes its way (at most about 1.6 s), the next one takes the new direction, as BL-D30 does for gusts. A reversal does not restart the rest. | **AUTOMATIC** | `breezeleds.lua` header (direction read when a gust starts); BLD BL-D30 |
| SL41 | The direction is unknown (a state with no `fanDirection`) | The Breeze engine counts unknown as up. For the chase **the direction is the whole point of the feature**, so an unknown direction runs **no chase** (the rest LED shows as today), with one log line; it resumes when the direction is known. This differs from BL-D30 and the contract says why. The model lists a missing `fanDirection` as a missing field, so a long unknown direction on an online fan is unlikely. | **AUTOMATIC** | SF5; `model.lua` `find_missing` |
| SL42 | The main fan's direction while Breeze blows | Not relevant: no chase in Breeze. The main proxy holds `DIRECTION` during Breeze and tells it after (BF-D14); the chase reads the model's shown direction, not the proxy's, and starts only after Breeze. | **AUTOMATIC** | `breeze-design.md` BF-D14; `fanproxy.lua` `tell_direction` |

### 2.6 Colours and settings

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL43 | `Speed LED Colors` is `Keypad's own` | The driver owns no colour to chase in or to put back; the speed colour properties are not used. No chase, and **L43** in Last Action on the property change (as L42 is for the Breeze animation): `Speed LEDs need Speed LED Colors set to Per speed`. A state-only chase (MATCH_LED_STATE only, each button in its own colour, nothing to restore) would be harmless and cheap, but then "the colour matches the speed's" has no meaning; leave it for later (question 6). | **AUTOMATIC** (no chase, one line); the state-only variant **OFFERED** later | BLD BL-D3; `texts.lua` L42; question 6 |
| SL44 | `Speed LED Colors` is switched from `Per speed` to `Keypad's own` mid-chase | The chase engine is configured first, in the existing handler order (the Breeze engine first, then this one, then `apply_colors`), and releases with a settle that still carries the per-speed colours, so no chase colour is left on any button. The reverse (Keypad's own to Per speed) starts a rest, no more. | **AUTOMATIC** | `driver.lua` 788 to 796 (the comment says why) |
| SL45 | The colour of the **current** speed is edited mid-chase (`Speed N LED Color`) | The engine restarts: pixels released (diff rule), new colours painted at the next chase, full rest. Editing a colour in Composer can fire several changes in a second; each restarts the rest, which is cheap and needs no debounce. During a held chase `set_colors` sends the held links nothing, so the engine must be told through its own configure or a read of the colours (the Breeze engine reads none; the contract adds an input). | **AUTOMATIC** | `links.lua` `set_colors` (452), `follow`; `driver.lua` `apply_colors` (690) |
| SL46 | A colour of another speed is edited | It matters only when the fan is at that speed or the Also Lit At of a lit button: no restart when the current speed's colour is unchanged. | **AUTOMATIC** | `colour_for` (312) |
| SL47 | `Speed LED Off Color` is edited | It is the OFF_COLOR sent with every paint, so the darkened buttons show it; apply from the next paint and restart the rest if a chase holds pixels. A non-black off colour makes the chase a dot over a coloured background; that is correct. | **AUTOMATIC** | `links.lua` `send_colors` (334), `set_colors` |
| SL48 | A speed's colour is blank, not a 6-digit hex, or **equals the off colour** | Blank or invalid: no chase for that speed (the existing warning is logged). Equal to the off colour: nothing could be seen, so no chase and no messages. | **AUTOMATIC** | `driver.lua` `color_hex`, `apply_colors` warnings; `links.lua` `hex6` |
| SL49 | The owner's colours: speeds 2 to 5 are all the same purple, so the dot and the resting LED are the same colour | What tells the chase from the rest is **motion, and the dark selected button during the chase**: one lit button that travels for about a second, then one lit button that stays for the rest. At the instant the dot is on the selected button it looks like the rest; the sequence is still unambiguous. The pace is the only speed cue besides position. No second colour is invented: the owner's rule is "the colour set for that speed". An offered "chase colour" row (same as the speed, or lighter) would break that rule and cost a preload per cycle. | **AUTOMATIC** (same colour); a separate colour **FORBIDDEN** unless the owner asks | owner's text; SF1 |
| SL50 | The driver's default colours (all `0,0,255`) with the chase turned on | Pure blue vanishes at the keypad's night dimming (house probe), so a chase at the defaults disappears at night. This is the dealer's choice of colour, not the engine's, but the manual line for the new property must say it, as the Breeze palette rule did. | **AUTOMATIC**; a documentation line | SF12 |
| SL51 | `Speed N Link Also Lit At` edited while the chase holds a pixel | `set_also` keeps its table and sends the held link nothing; at the chase end the release forces the selected set from the **new** tables. During a rest it is the existing behaviour (the link's LED is re-sent at once). | **AUTOMATIC** | `links.lua` `set_also` (434), `lit` |
| SL52 | The chase property turned Off mid-chase | Release at once with the diff rule, rest timer cancelled, nothing held. | **AUTOMATIC** | BLD BL-D11 (the property turned Off settles at once) |
| SL53 | The rest length or the step time (if a property) edited mid-cycle | Applies from the next rest or the next chase; nothing restarts; a change alone sends nothing. | **AUTOMATIC** | `breezeleds.lua` `configure` (step "from the next gust") |
| SL54 | `Breeze LED Bottom` edited mid-chase | The route reverses; the chase in flight ends with the pixels released, then the cycle restarts with a rest. | **AUTOMATIC** | `breezeleds.lua` `configure` (a bottom change during a gust darkens and rests) |

### 2.7 Night

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL55 | Should the chase follow the Breeze night dimming (`Breeze LED Night Brightness (%)`, 50 % between sunset and sunrise)? | The Breeze rule exists because **blues and whites catch the eye at night** (owner, BL-D28). The chase colour is the owner's speed colour (purple on the house), already dimmed by the keypad's own ambient dimming on top of the driver's colour. Scaling it would make the dot dimmer than the resting LED, so the two would no longer "match". Options: (a) as by day, the keypad's dimming only; (b) scaled by the same percent; (c) no chase at night, the rest LED only. Recommendation: (a), with (b) and (c) a later offer after a night on the house. | **OFFERED** (question 5); default (a) | BLD BL-D28, BL-D29; SF12 |
| SL56 | If (b) or (c) is chosen: the night logic only runs for `Breeze LED Animation` = `Gusts` | `apply_breeze_night` sends `night = false` unless that property is `Gusts`, so a fan with the chase on and the Breeze animation off would never be night. The contract must make the gate "either animation on" and say it. | **AUTOMATIC** once (b) or (c) exists | SF13 |
| SL57 | Hours of chase while someone sleeps in the room | A fixed speed runs overnight; the dot repeats every rest for 6 to 10 hours. The keypad dims itself at night, but a moving LED in a dark bedroom is the biggest practical risk of the feature, bigger than the radio load. This is the case where (c) matters and where a longer rest is the cheap mitigation; the owner decides after a night (question 5). | **OFFERED** (question 5) | owner's text; section 5 |

### 2.8 Load, pacing and the radio

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL58 | Message volume over hours and days | Section 5: about 11 messages a cycle with four pixels; 0.35 to 2 messages a second on average for rests of 30 s to 5 s, 82 000 to 90 000 a day at a 10 s rest, 28 000 to 31 000 at 30 s, 144 000 to 173 000 at 5 s. The Breeze animation never ran for days; a fixed speed does. The average stays below the field note's planning figure of 3 to 5 sustained a second; the peaks (5 to 17 a second for under 2 s) stay under its 10 a second only for speeds 2 to 4. | **AUTOMATIC**; the rest length **OFFERED** (question 4) | section 5; FLD Q5 |
| SL59 | A late tick (Director busy) | One timer at a time, re-armed each step. A late tick evaluates the dot where it should be **now** and sends only the final state of each pixel, never a burst of the missed steps (the dot may skip one pixel, rare at 4 pixels). The engine's own time never runs backwards if the controller's clock steps (NTP, DST). | **AUTOMATIC**; **FORBIDDEN**: catching up by replaying steps | `breezeleds.lua` `fire`, `advance_time`, BL-D13 |
| SL60 | The budget (30 messages a second) | The chase's own sends are always sent (the dot, the darkening, the end re-assert); it cannot exceed 2 messages per step, so at the clamped minimum step of 100 ms it is 20 a second and 120 ms 16.7 a second, under the budget by itself. Only the calls from outside (a press, a bind, a `REQUEST_BUTTON_COLORS`) can push a window past 30. The engine reuses the Breeze budget code (a shared helper) rather than copying it. | **AUTOMATIC** | `breezeleds.lua` `room`, `stamp` (503 to 513); BLD BL-D24 |
| SL61 | A button pressed during the chase | The press itself is not a radio send from the driver; it arrives at Director over the same mesh. The keypad's behaviour while LED messages arrive at 10 to 17 a second and a press is made is **not measured** (the Breeze check HB4, item 67 of `composer-checklist.md`, asks it for the Breeze animation and is still open). Probe before release: tap each speed button and the light's Up during a chase at speed 5 and watch for a late press or a lagging LED. | **AUTOMATIC**; probe **OFFERED** (unverified) | `composer-checklist.md` 938 to 950; BLD section 6 HB4 |
| SL62 | The other devices on the mesh | An LED message is a unicast to the keypad. Whether it costs one radio frame or several, and how it competes with load and sensor traffic, is not documented (FLD H6). The average load at a 10 s rest is below one message a second; the risk is the peak, so the contract should keep the 30 a second cap and prefer the longer default rest. | **AUTOMATIC**; the number **OFFERED** (question 4) | FLD Q5; SF10 |

### 2.9 The keypad and other drivers

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL63 | The keypad asks for its colours again (`REQUEST_BUTTON_COLORS`, which came 3 ms after a bind on the house) while the chase runs or rests | During the **rest** the pixels are not held, so the links answer in full with the true state, selected button lit. During a **chase** the pixel is held: `repaint(link)` answers with the engine's current frame (the dot lit in its colour, or dark), as for Breeze. Whether the keypad asks again after its own power loss or reboot is not recorded (only the bind-time request is); if it does, the same two rules cover it. | **AUTOMATIC** | SF7; V1D K6; `breezeleds.lua` `repaint` (1170) |
| SL64 | Other Composer programming paints a keypad LED the chase uses (Set LED On, Set LED Current), or another driver does | It fights the driver wherever a button follows a link: the existing situation. The dot always sends an explicit lit state when it arrives and the end re-assert forces the selected button, so the keypad is right again within a cycle. The engine cannot see the other writer. | **AUTOMATIC**; programming against the fan's own buttons **FORBIDDEN** by the manual | BLE LF5, LF6 |
| SL65 | Echo LED On Press on a speed button | The keypad lights it at the push and darkens it at the release (K6), over whatever the engine sent; healed by the next dot or the end re-assert (SL3, SL4). | **AUTOMATIC** (the keypad's own behaviour) | SF11; BLE BL19 |
| SL66 | **Two fan drivers on one keypad** (two Modern Forms fans, a button each) | Each driver chases its own links only; no coordination. Two fans started by one scene at the same moment would run **in step forever** (equal rests) and double the peak (2 x 16.7 = 33 a second at speed 5, each driver's own budget unaware of the other). Cure: a random start offset for the first rest of each cycle sequence (for example the first rest drawn once between half and one full rest), so that identical timings drift apart; later rests stay constant ("even intervals" holds per driver). | **AUTOMATIC** (random first rest) | `breezeleds.lua` `random` input; SF9 |
| SL67 | Two keypads bound to one speed link | One message on a link reaches every consumer (expected, ECC C6, ASSUMED; the house has one keypad). Both show the same frame; a keypad laid out the other way up shows the chase running the other way: the manual says one `Breeze LED Bottom` per driver. | **AUTOMATIC**; per-keypad direction **FORBIDDEN** (not possible) | ECC C6; BLE BL29 |
| SL68 | `modernforms_breeze_fan` and other Modern Forms drivers | The Breeze fan has no Button Links and no LED code and bundles only `common/`; nothing of this feature is built into it. A Breeze fan command that changes the main fan's speed arrives through the model as any other change. | **AUTOMATIC**; nothing to build there | SF16 |

### 2.10 What the owner sees in Composer

| ID | Case | What happens, and why | Decision | Evidence |
| --- | --- | --- | --- | --- |
| SL69 | The chase property is on and `Speed LED Colors` is not Per speed | L43 in Last Action, once, on the property change, not on the late-init replay (like L42); a new key in `texts.RESULT_KEYS`, one line in `texts.lua`, a spec. | **AUTOMATIC** | SF14 |
| SL70 | The chase cannot run for any other reason (no or one pixel, offline, an unanimated speed, no colour for the speed, a colour equal to the off colour, unknown direction, fan stopped or in Breeze) | These are states, not errors, and most are normal (the fan is off). No Status row and no Last Action line: a dealer would read them as faults. One debug line per change of reason, not per step. The reasons stay visible to a developer through the engine's `debug()` table, which the contract should hand to the dev loop's `devctl` (it has no caller today). Alternative offered: a read-only `Speed LED Animation State` property row (`Running at speed 3`, `Waiting: fan off`...), only if the owner wants to see why nothing moves. | **AUTOMATIC** (debug only); the row **OFFERED** | SF14; `driver.lua` (no `debug()` call) |
| SL71 | Debug Mode on for hours | `links.lua` logs every message at debug (`-> link N MATCH_LED_STATE ...`): about 11 lines a cycle, 17 000 lines a day at speed 5 with a 10 s rest. One summary line per chase (as the light fade contract does) and none per step. | **AUTOMATIC** | `links.lua` `send_led` (327); `light-fades-design.md` LF-D20 |

## 3. Table of every case

| ID | Short name | Recommendation |
| --- | --- | --- |
| SL1 | Speed changes mid-chase or mid-rest | AUTOMATIC |
| SL2 | Rapid presses | AUTOMATIC (diff release; settle-all FORBIDDEN) |
| SL3 | Press on the selected speed's button | AUTOMATIC |
| SL4 | Press on the button the dot is on | AUTOMATIC |
| SL5 | Cycle and Toggle | AUTOMATIC |
| SL6 | Press refused | AUTOMATIC |
| SL7 | Unrelated `shown` events (light fade) | AUTOMATIC (idempotent; restart on unchanged FORBIDDEN) |
| SL8 | Fan off mid-chase | AUTOMATIC |
| SL9 | Fan off mid-rest | AUTOMATIC |
| SL10 | Fan on | AUTOMATIC; first-chase timing OFFERED |
| SL11 | Stopped with Breeze stored | AUTOMATIC |
| SL12 | To Breeze, Breeze animation enabled | AUTOMATIC (silent release) |
| SL13 | To Breeze, Breeze animation disabled | AUTOMATIC |
| SL14 | Breeze to fan mode during the ending wipe | AUTOMATIC (wait until the wipe is done) |
| SL15 | Breeze to fan mode, animation disabled | AUTOMATIC |
| SL16 | Quick Breeze flapping | AUTOMATIC (one owner per pixel FORBIDDEN to break) |
| SL17 | Both properties changed | AUTOMATIC |
| SL18 | Speeds 2 to 5 | AUTOMATIC |
| SL19 | Speed 0 or unknown | AUTOMATIC |
| SL20 | Speed 1 | OFFERED (default off) |
| SL21 | Speed 6 | OFFERED (default off; step under 60 ms FORBIDDEN) |
| SL22 | Selected button not bound | AUTOMATIC |
| SL23 | Also Lit At, several selected buttons | AUTOMATIC (from `links:lit`) |
| SL24 | Fewer than two pixels | AUTOMATIC (no chase) |
| SL25 | Zero pixels | AUTOMATIC |
| SL26 | Off, Toggle, Cycle, Breeze, light links | AUTOMATIC; FORBIDDEN as pixels |
| SL27 | The bottom | AUTOMATIC (reuse `Breeze LED Bottom`) |
| SL28 | Direction | AUTOMATIC |
| SL29 | Binding added | AUTOMATIC |
| SL30 | Binding removed | AUTOMATIC |
| SL31 | Keypad replaced | AUTOMATIC |
| SL32 | Update in place | AUTOMATIC |
| SL33 | Director restart or reboot | AUTOMATIC |
| SL34 | `OnDriverDestroyed` | AUTOMATIC (sends nothing) |
| SL35 | Dev reload | AUTOMATIC |
| SL36 | Fan offline | AUTOMATIC |
| SL37 | Fan back online | AUTOMATIC |
| SL38 | Rebooting, waiting, foreign | AUTOMATIC |
| SL39 | Change from the app, remote or wall control | AUTOMATIC |
| SL40 | Direction reversed mid-chase | AUTOMATIC (from the next chase) |
| SL41 | Unknown direction | AUTOMATIC (no chase) |
| SL42 | Main proxy's direction hold in Breeze | AUTOMATIC |
| SL43 | `Keypad's own` colours | AUTOMATIC (no chase, L43); state-only variant OFFERED later |
| SL44 | Leaving Per speed mid-chase | AUTOMATIC |
| SL45 | Current speed's colour edited | AUTOMATIC |
| SL46 | Another speed's colour edited | AUTOMATIC |
| SL47 | Off colour edited | AUTOMATIC |
| SL48 | Blank, invalid or off-coloured speed colour | AUTOMATIC (no chase) |
| SL49 | Same colour at every speed | AUTOMATIC; a separate chase colour FORBIDDEN unless asked |
| SL50 | Default pure-blue colours at night | AUTOMATIC; documentation line |
| SL51 | Also Lit At edited | AUTOMATIC |
| SL52 | Property turned Off | AUTOMATIC |
| SL53 | Rest or step edited | AUTOMATIC |
| SL54 | `Breeze LED Bottom` edited | AUTOMATIC |
| SL55 | Night dimming | OFFERED (default as by day) |
| SL56 | Night gate on the Breeze property | AUTOMATIC once night is offered |
| SL57 | Overnight hours | OFFERED |
| SL58 | Message volume | AUTOMATIC; rest length OFFERED |
| SL59 | Late ticks | AUTOMATIC |
| SL60 | The budget | AUTOMATIC |
| SL61 | Press during the chase | AUTOMATIC; probe OFFERED (unverified) |
| SL62 | Other mesh devices | AUTOMATIC; rest length OFFERED |
| SL63 | `REQUEST_BUTTON_COLORS` | AUTOMATIC |
| SL64 | Other programming painting the LEDs | AUTOMATIC |
| SL65 | Echo LED On Press | AUTOMATIC |
| SL66 | Two fan drivers on one keypad | AUTOMATIC (random first rest) |
| SL67 | Two keypads on one link | AUTOMATIC |
| SL68 | The Breeze fan driver | AUTOMATIC (nothing to build) |
| SL69 | Property conflict line L43 | AUTOMATIC |
| SL70 | Why it is not running | AUTOMATIC (debug only); row OFFERED |
| SL71 | Debug log volume | AUTOMATIC |

## 4. Hand-over between the two engines, in one place

| From, to | What the code must do |
| --- | --- |
| rest, to Breeze (animation on) | Chase engine holds nothing; cancel its timer. Breeze engine takes and darkens. |
| chase, to Breeze (animation on) | Chase engine releases **silently** (no settle); Breeze engine's start sends the dark. |
| chase, to Breeze (animation off) | Chase engine releases with a settle (diff rule): the Breeze state is all speed LEDs dark. |
| Breeze, to fan mode (animation on) | The Breeze ending wipe runs; the chase engine starts its **rest** and checks the Breeze engine is idle before taking pixels. |
| Breeze, to fan mode (animation off) | Chase engine starts a rest. |
| any, to stopped or offline | Chase engine releases with a settle, no wipe. |

`held(link)` in `driver.lua` is the one place that says "somebody holds this";
the link code does not change.

## 5. Message volume: the arithmetic

Using the Breeze engine's message costs (SF9). One cycle with N pixels, the
dot as the only lit button, colours already loaded (true on the house, where
speeds 2 to 5 share one colour; otherwise add up to N preloads at the first
chase after a speed change):

| Step | Messages |
| --- | --- |
| darken the selected button | 1 |
| light the first dot | 1 |
| each of the other N - 1 steps: dark the previous, light the next | 2 each |
| darken the last dot | 1 |
| re-assert the selected button (colours, then state) | 2 |
| **total** | **2N + 3: 11 for N = 4; 15 for N = 6** |

The chase's own peak is 2 messages a step, so 2000 / step messages a second
for the length of the chase. A naive release by `links:settle` on every pixel
adds 2N - (a few) messages: about 16 a cycle for N = 4, 45 % more; this is why
the diff rule is recommended.

N = 4, 11 messages a cycle, candidate steps (390, 300, 210, 120 ms; the
table uses the round 400, 300, 200, 120 ms):

| Speed | Step | Chase | Peak | Rest 5 s: cycle, per hour, per day, average | Rest 10 s | Rest 30 s |
| --- | --- | --- | --- | --- | --- | --- |
| 2 | 400 ms | 1.60 s | 5.0 / s | 6.6 s, 6 000, 144 000, 1.67 / s | 11.6 s, 3 414, 81 900, 0.95 / s | 31.6 s, 1 253, 30 100, 0.35 / s |
| 3 | 300 ms | 1.20 s | 6.7 / s | 6.2 s, 6 387, 153 300, 1.77 / s | 11.2 s, 3 536, 84 900, 0.98 / s | 31.2 s, 1 269, 30 500, 0.35 / s |
| 4 | 200 ms | 0.80 s | 10.0 / s | 5.8 s, 6 828, 163 900, 1.90 / s | 10.8 s, 3 667, 88 000, 1.02 / s | 30.8 s, 1 286, 30 900, 0.36 / s |
| 5 | 120 ms | 0.48 s | 16.7 / s | 5.5 s, 7 226, 173 400, 2.01 / s | 10.5 s, 3 779, 90 700, 1.05 / s | 30.5 s, 1 299, 31 200, 0.36 / s |

Reading it. (1) Averages are 0.35 to 2 messages a second, under the field
note's planning figure of 3 to 5 sustained; a 5 s rest at speed 5 is the
heaviest, at about 2 a second all day. (2) Peaks of 5 to 10 a second at speeds
2 to 4 sit inside its 10 a second planning peak; speed 5 at 120 ms reaches
16.7 a second for half a second, over that planning figure and under the
measured clean 40 a second and the 30 a second budget. A longer step at
speed 5 (150 ms: 13.3 a second) is the cheap lever if a probe shows trouble.
(3) Six pixels (15 messages a cycle) at speed 5 with a 10 s rest: 0.72 s
chase, 10.7 s cycle, about 121 000 a day, average 1.4 a second. (4) For a
sense of scale the Breeze animation changes about three pixels a front step
and, for a few minutes at a time, runs near its budget; the chase runs for
hours but at a fraction of that rate.

Why the rest, not the step, is the main lever: the day's volume is almost
proportional to 1 / (chase + rest), and the chase is under 2 s. A 30 s rest
cuts the volume to about a fifth of a 5 s rest. **Recommended default rest:
10 s** (range 2 to 120 s), about 0.95 to 1.05 messages a second whatever the
speed, a visible cadence without being nervous.

Keypad and mesh. (a) The keypad is a mains-powered dimmer and a Zigbee node;
whether it forwards for other devices is not in the documents. (b) A single
dot lit for 120 ms on a dark column is a different pattern from the Breeze
probe (four buttons changing at 10 a second each, even and in step); one
button flickered distinctly at 20 changes a second, and the dot's button
changes twice in 120 ms plus 120 ms, which is under that. Whether a 120 ms
pulse reads as a pulse on the real keypad is **not measured** (probe).

## 6. Questions only the owner can answer

1. **Speeds 1 and 6.** Animate them or not? A three-way property, `Off`,
   `Speeds 2 to 5`, `Speeds 1 to 6`. *Recommended:* the property exists and
   defaults to `Off` (like `Breeze LED Animation`, BL-D18, so an update starts
   animating no one's keypad); the house is set to `Speeds 2 to 5` as the
   owner wrote. Speed 6 is clamped to a 100 ms step if on.
2. **The chase's shape.** A single dot travelling across (2 messages a
   step) or a column that fills one after the other and then clears (1
   message a step, cheaper)? *Recommended:* the single dot ("a chase"; the
   owner's "one after the other" read as LED after LED).
3. **After a speed change or a start, chase at once or rest first?**
   *Recommended:* a full rest first, so the rest is the even interval the
   owner asked for, and the pressed button's LED is itself the confirmation.
4. **The rest's length.** *Recommended:* `Speed LED Rest (s)` 2 to 120,
   default 10, from the arithmetic above (about 1 message a second whatever
   the speed). The step times are fixed by the speed (390, 300, 210, 120 ms
   at 2 to 5) in the first build.
5. **At night.** The chase as by day (the keypad's own dimming only), dimmed
   by the Breeze night percentage, or not at all between sunset and sunrise?
   *Recommended:* as by day for the first build, then decide after a night
   on the house; the property for (b) or (c) comes later (SL55 to SL57).
6. **Under `Keypad's own`.** No chase and L43 (the same as the Breeze
   animation), or a state-only chase in each button's own colour?
   *Recommended:* no chase and L43; the owner's rule ties the colour to the
   per-speed properties.

## 7. What could NOT be verified from the code or the documents

- **A press made while LED messages arrive at 10 to 17 a second.** No
  measurement exists; the Breeze check for it (HB4, `composer-checklist.md`
  item 67) is still open in this checkout.
- **A single 120 ms pulse of one button.** Not measured. The probes covered
  four buttons changing at 10 a second each and a distinct flicker at
  20 changes a second.
- **Whether one LED message is one radio frame, and the cost on the rest of
  the mesh.** Not documented (`breeze-leds-field-research.md`, H6); no rate
  for keypad LEDs is documented (FUND `_50-LIGHTV2BESTPRACTICE.md` gives only
  the warning).
- **Several keypads on one link.** One message reaching every consumer is
  expected (ECC C6), not seen; the house has one keypad.
- **Whether a keypad asks `REQUEST_BUTTON_COLORS` again after its own power
  loss or reboot.** Only the request after a bind was recorded (3 ms later).
- **Whether one keypad button can be bound to two providers' links at once**
  (the "other drivers on the same buttons" case). Not found in the SDK files
  read; the cases above assume one provider per button.
- **That "forward" is blowing down on every install.** It is the owner's
  statement for the house (BL-D30); the driver cannot read the mounting.
- **Echo LED On Press on a speed button.** Seen once, on a button bound to
  Fan Off (K6); not on a speed button.
- **OS 4.x.** Nothing in the files read differs, and none of the APIs the
  chase would use (`SendToProxy` over a link, `SetTimer`, `GetTime`) is
  marked changed; no 4.x controller is available to check.
- **Director's own load from a timer at 120 ms for hours.** Not measured;
  the Breeze animation ticks every 50 ms for seconds at a time, and the chase
  needs one timer a step and one long timer a rest.
- **Whether a send in `OnDriverDestroyed` arrives.** Not documented
  (BL-D17); the design sends nothing there.
