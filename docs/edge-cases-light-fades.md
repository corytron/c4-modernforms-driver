# Simulated light fades: the fan's limits and the edge cases

> **Research (2026-11-09) for [issue #141](https://github.com/corytron/c4-modernforms-driver/issues/141)**,
> desk research only: nothing was sent to the fan, the controller, the dev
> server or any other device while writing it. The fan's light has no fade
> of its own (the local API has no transition time,
> [`modernforms-api-research.md` §9](modernforms-api-research.md#9-fan-and-light-behaviour)),
> so the owner wants the driver to step through many levels until a change
> reads as a fade, as a Control4 dimmer does, with a 3 s tap ramp as the
> default across the owner's drivers ([#140](https://github.com/corytron/c4-modernforms-driver/issues/140)).
> This note is the **fan's side**: what one level step costs, how the light
> responds, the corner cases on both sides with a decision for each, and the
> probes that settle what is unknown. The **Control4 side** (which commands
> carry a rate, click rates and the `<capabilities>` change, `CHANGING` and
> `CHANGED`, Navigators, the double-tap window) is the sibling note
> `docs/light-fades-sdk-research.md`, written at the same time: where it
> settles a Control4 fact that this note marks ASSUMED, it wins.

**The short answer.**

1. **One step is one request, and only one is ever on the wire.** On the
   controller the fan answers in 0.15 s (the median of 416 answers; 99 %
   within 0.58 s), and the driver then waits 250 ms before the next request.
   One step therefore costs about 0.41 s: about 2.4 steps a second
   (MEASURED, FT5 and FT6).
2. **Fine steps over 3 s are out of reach.** A 3 s fade from off to full at
   1 level a step needs 33 requests a second; at 2 levels, 17; at 5 levels,
   7. The fan took about 4 a second back to back from the VM (K13: 20
   levels in 4.62 s). Realistic for a 3 s
   full-range fade: about 7 steps of 14 levels today, about 11 steps of 9
   levels with a 100 ms gap, about 18 steps of 5 to 6 levels with none
   (INFERRED from the measurements, table in section 1.2). Steps of 1 or 2
   levels need fades of 8 to 40 s.
3. **Pick the time, not the step size.** Each time the slot frees, the
   driver sends the level the fade should show at that moment (a straight
   line from start to target over the fade time). The step size then
   follows the fan's pace, a slow answer only makes the next step bigger,
   the last request is the target at the fade's end, and never more than
   one request goes per level of change, so slow fades stay gentle
   (section 1.3).
4. **The queue can already do most of it.** The latest wanted level wins
   and goes as soon as the slot is free; what holds a fade back is that the
   light wants a new level only every 500 ms, and the 250 ms gap after
   every answer (section 1.4). Probe FP1 decides how small the gap may get.
5. **Whether about ten steps in 3 s look like a fade is the open
   question.** Check K15 showed exactly that on the house light on
   2026-10-27 (12 steps of 9 levels in 3 s), but the owner's verdict was
   never recorded, and nobody knows whether the light glides between levels
   by itself (section 2; probes FP2 to FP4).
6. **A fade never fights anyone.** An answer showing the light off when the
   fade did not turn it off (the Modern Forms app, the remote, the wall
   control, the fan's own timer) ends the fade at once and is reported; the
   fade never turns the light back on, which today's hold ramp would do
   (FF1). A failed request ends the fade; no step is retried (FF4).
7. **Gentle on the fan:** fades under about 1 s or under 3 levels are sent
   at once, a request budget caps repeated fades at today's hold pace, and
   Gen 1/2 fans keep today's pace (nothing was measured on them).
8. **The probes** (each under a minute, each run twice) need one new
   dev-only command, `Dev Light Steps` (section 4).

**Decisions:** **Automatic** (the driver does it by itself), **Offered**
(a property, a Composer field, the manual, or a click), **Forbidden** (not
without a click, or not at all where the row says so). **Markers:**
MEASURED is a measurement on the house (the source named); VERIFIED names a
primary source (code in this repository, an SDK file, the API research's
verified rows); ASSUMED has none; INFERRED is reasoning from the measured
numbers; UNKNOWN needs a probe. Code references are files under
`src/modernforms_fan/fan/` unless named otherwise, with line numbers as read
on branch `feature/light-fades-141` at commit 714dbe2 (the 1.4 code). Snap
One's and WAC's documents are never quoted. Placeholders only: fan
10.0.2.151, controller 10.0.2.10, MAC 00:00:5E:00:53:01, client id
MF_00005E005301, room "Example Room".

| Key | Source |
| --- | --- |
| MFR | [`modernforms-api-research.md`](modernforms-api-research.md): the fan's local API, its fragility (§8), the light (§9), Director's transfers (§10) |
| V1D | [`v1-design.md`](v1-design.md): polling (§3.4), the request order (§4.3), answers (§4.4), reports R1–R9 (§4.5), the light (§4.7), the probe results (§11.1), the dev commands (§12) |
| ECM | [`edge-cases-modernforms.md`](edge-cases-modernforms.md): rule 6 (one request at a time), rule 7 (Control4 is the source of truth), P1–P9, S4, S8–S10 |
| LSR | [`light-structure-research.md`](light-structure-research.md) §1.5: rates, ramps and holds without a native dim; tests H5 and H6 |
| M1 | Issue [#17](https://github.com/corytron/c4-modernforms-driver/issues/17), first comment: K11 to K15 run from the VM with [`tools/mf_probe.py`](../tools/mf_probe.py) on 2026-10-27 ([`fan-probe.md`](fan-probe.md)); the per-request reports under the gitignored `build/m1/` (masked) |
| DEVLOG | The dev loop's shipped log of 2026-11-09, 01:14 to 02:27 (this driver on the house, Debug Mode On), gitignored `build/dev/driver.log`: the `-> fan #N` and `<- fan #N ... in X s` lines |
| HUE421 | The Hue project's tap-stop contract, [`docs/tap-stop-design.md`](https://github.com/corytron/c4-hue-driver/blob/main/docs/tap-stop-design.md) (#421): tap ramps, the second tap that stops, the double-tap window, 3 s click rates |
| code | [`transport.lua`](../src/modernforms_fan/fan/transport.lua), [`model.lua`](../src/modernforms_fan/fan/model.lua), [`wire.lua`](../src/modernforms_fan/fan/wire.lua), [`light.lua`](../src/modernforms_fan/fan/light.lua), [`devcmds.lua`](../src/modernforms_fan/fan/devcmds.lua), [`src/common/device.lua`](../src/common/device.lua), [`src/common/log.lua`](../src/common/log.lua), [`src/modernforms_fan/driver.lua`](../src/modernforms_fan/driver.lua) |

## 0. Facts the decisions rest on

| # | Fact | Status |
| --- | --- | --- |
| FT1 | The light is `lightOn` plus `lightBrightness` 1 to 100 on every Gen 1–3 fan; there is no level 0 (off is `lightOn` false) and no fade or transition field. | VERIFIED: MFR §2.2, §9 |
| FT2 | On the house fan a level written while the light is off is stored and keeps the light off; `lightOn` then lights it at that level; the level is kept after off. | MEASURED: K12 (M1) |
| FT3 | The house fan took 20 level writes back to back (1, 12, 23 … 100 and back down to 1, then 100), one in flight, in 4.62 s: 0 errors, every echo equal to the level sent, levels 1 and 100 included. | MEASURED: K13 (M1) |
| FT4 | From the VM (Python, a new connection per request): the 48 level writes of M1 took 0.20 s at the median, 0.31 s at the 90th percentile, 1.27 s at worst; all 90 M1 requests 0.20 s at the median, 8 of them over 1 s, 2.2 s at worst (a state read). Outliers came "once or twice per check, always on a single request". Two of the three `{"lightOn":true}` took 1.79 s and 1.42 s (the third 0.14 s); every `{"lightOn":false}` took under 0.2 s. | MEASURED: M1 |
| FT5 | Through the controller (Director's `C4:url`): 416 answers took 0.15 s at the median, 0.26 s (90 %), 0.37 s (95 %), 0.58 s (99 %), 0.89 s at worst, with no failure; the 16 commands among them 0.15 s at the median and 0.33 s at worst. Most of the 416 were state reads. | MEASURED: DEVLOG |
| FT6 | When work is waiting, the next request leaves 252 to 255 ms after an answer (the 250 ms gap timer firing on time); request to request, back to back, took 0.32 to 0.58 s, 0.41 s at the median (12 pairs). | MEASURED: DEVLOG |
| FT7 | K15 stepped the light 1 → 100 in 12 requests 0.25 s apart, then back down: 24 of 24 answered (medians 0.18 and 0.21 s). A low-level run, 1 → 10 → 1 in 0.4 s steps, answered 19 of 19. Whether either looked like a dim or a staircase was left to the owner's eyes and is not recorded. | MEASURED (the requests); the look UNKNOWN |
| FT8 | Fans' Wi-Fi modules freeze under sustained frequent polling (Home Assistant moved from 5 s to 15 s for this); no rate limit is documented; nobody had measured bursts before K13. | VERIFIED and field reports: MFR §8 |
| FT9 | Gen 1/2 fans use an older Wi-Fi module (MXCHIP's MiCO, read from their mDNS records) with a very small TCP window; Gen 3 runs ESP32 firmware; the house fan is Gen 3. Nothing was measured on a Gen 1/2 fan. | MFR §1, §8 (the module ASSUMED from evidence); M0 for the house |
| FT10 | Every answer is the Wi-Fi module's state after it took the command; whether the light itself (on Gen 3 driven by a separate main controller, `mainMcuFirmwareVersion`) always ends where the echo says is not known. | MFR §3 (ASSUMED there) |
| FT11 | The house fan's device information carries a `dimTableId`; it may name a dimming curve in the firmware. Its meaning is not documented anywhere the project has read. | V1D §10.1 (the value); meaning UNKNOWN |
| FT12 | On OS 3.4.2 Director runs one transfer per host at a time and at most four across all drivers (the Hue project's measurement). A fade holds one, as a hold does today. The house runs 3.4.3; OS 4.x may differ. | MFR §10 |

## 1. What one level step costs

### 1.1 The request path, end to end

1. **The light picks a level** and hands the model `{ light_on = true,
   level = N }` (`light.lua` `want`, L232–239). Today only a hold or a
   scene ramp steps, and it picks a new level every `RAMP_STEP_MS` = 500 ms
   (L55; `arm_tick` L383–390, `tick` L398–425): a straight-line estimate
   from the start level, at most one want per tick. Taps and timed targets
   are one level at once (`target` L314–328, which opens `CHANGING` with
   rate 0 at L319).
2. **The model coalesces.** `want` replaces the group's wanted fields, the
   latest wins, and pumps (`model.lua` L2003–2033). A wanted field is sent
   even when it equals the confirmed one (V8; the comment at L1996–2002), so
   a fade must never want a level it has already wanted.
3. **One request at a time.** The pump sends only when the transport is
   free: no request in flight and the gap after the last one over
   (`pump_once` L1107–1120; `transport.lua` `busy` L113–116, `send`
   refusing "busy" L329–331). Nothing is ever retried by the transport
   (header L1–5).
4. **What goes next** (`next_request` L1009–1040): a Use Selected Fan read,
   a reboot, a contact, then commands, groups in the order fan, direction,
   Breeze, light (`GROUPS` L83; Breeze first when a fan change and a Breeze
   change are paired, L84 and `command_order` L881–887), then the Away or
   learning switch-off (L997–1005), then the due poll. So a fan or Breeze
   command always overtakes a light step, and polls wait while a light
   level is wanted.
5. **The bodies.** A level is `{"lightBrightness":N}`; "on at N" from off is
   two requests, the level first and then `{"lightOn":true}` (V14;
   `plan_group` L862–886; `wire.lua` `light_body` L127–143); off is
   `{"lightOn":false}`. The level is skipped when the fan already keeps it
   (L872).
6. **The call.** `C4:url` POST with a 3 s connect and 5 s total timeout
   (`transport.lua` L23–27, L260–283).
7. **The answer** is the fan's whole state (MFR §3). The fields the command
   set become confirmed and start a 2.5 s settle window
   (`apply_command_fields` L1395–1415, `SETTLE_MS` L66); the command is
   finished (`finish_command` L1566–1590); groups no longer busy are
   compared with what the proxies were told (`reconcile` L1502–1525); the
   20 s fast-poll window opens and the poll is re-armed (L1472–1476).
8. **The gap.** The transport frees the slot only `GAP_MS` = 250 ms after
   the answer (`transport.lua` L23, marked "ASSUMED, K13 times it";
   `finish` L227–240, `arm_gap` L195–222), then calls the model's
   `on_idle`, which sends the next request (`model.lua` L757–760;
   `schedule_retry` L764–772 covers a want that arrives during the gap).

**One step costs** the request's own time plus 250 ms plus a few ms of
timers: 0.32 to 0.58 s, 0.41 s at the median, on the house controller
(MEASURED, FT5 and FT6).

**Polling in between.** While a level is wanted no poll leaves (commands go
first), and every answer counts as a poll and re-arms it (`arm_next_poll`
L785–791). After the fade the fast window reads the fan every 2 s for 20 s
(`FAST_POLL_MS`, `FAST_WINDOW_MS` L63–64): about ten reads per fade, as
after any command today (VERIFIED: code).

### 1.2 The rate a fade would need, and the rate the fan gives

What fixed step sizes would need for a 3 s fade over the full range
(INFERRED, arithmetic): 1 level a step, 33 requests a second; 2 levels, 17;
5 levels, 7; 10 levels, 3.3.

What the slot gives, and so what a fade gets:

| Gap after each answer | Step period (median) | Steps a second | 3 s, off → 100 | 3 s, 30 → 70 | 5 s hold, full range | Shortest full-range fade at 1 / 2 / 5 levels a step |
| --- | --- | --- | --- | --- | --- | --- |
| 250 ms (today) | 0.41 s, MEASURED | about 2.4 | 7 steps of 14 | 7 of 6 | 12 of 8 | 41 s / 20 s / 8 s |
| 100 ms | about 0.26 s, INFERRED | about 3.8 | 11 of 9 | 11 of 4 | 19 of 5 | 26 s / 13 s / 5 s |
| none | about 0.16 s, INFERRED | about 6 | 18 of 5 to 6 | 18 of 2 | 30 of 3 | 16 s / 8 s / 3.2 s |
| none, from the VM (K13) | 0.23 s, MEASURED | 4.3 | 13 of 8 | 13 of 3 | 21 of 5 | 23 s / 12 s / 5 s |

Today's hold wants a level every 500 ms, slower than the slot's 0.41 s, so
it runs at 2 steps a second: 10 steps of 10 levels over its 5 s range
(VERIFIED: `light.lua` L55; the default hold rate 5000 ms, `device.lua`
L152–155).

**Plain English:** with one request at a time, a 3 s fade over the whole
range is about 10 to 18 visible steps of 5 to 14 levels, depending on how
small the gap may get. Steps of 1 or 2 levels are possible only on slow
fades (a programmed ramp over 10 s or more). Slow answers make an
occasional step bigger: through the controller one answer in ten took over
0.26 s and one in a hundred over 0.58 s (FT5), so about one step in a
hundred is twice the usual size; from the VM slow answers were commoner
(8 of 90 over 1 s, FT4). An earlier note already
expected about four requests a second and tied tap ramps to it (LSR §1.5,
test H6); K13 then measured 4.3, but v1 kept taps instant.

### 1.3 Picking the step: by time, not by size

Recommendation for the contract (INFERRED; the constants are proposals the
probes tune):

1. **Instant when a fade cannot show.** A fade shorter than `FADE_MIN_MS`
   (about 1000 ms, two step periods) or over fewer than 3 levels is sent at
   once, as today. That covers a 250 ms click rate and the stock driver's
   0.75 s default rate (M0 read it, [`migration-design.md`](migration-design.md)
   section 1).
2. **The line.** A fade is `{ from, to, t0, T }`; the level it should show
   at time t is `from + (to − from) × (t − t0) / T`, rounded, held inside 1
   to 100 while on.
3. **Send when free.** Whenever the slot is about to free, the light wants
   the level of the line at that moment, unless it equals the level it last
   wanted. The step size is then `distance × step period / T`, whatever the
   fan's pace is that evening; a slow answer just makes the next step
   bigger.
4. **One request per level at most.** Because an unchanged level is never
   wanted again, a slow fade (a 30-minute programmed ramp) sends one level
   at a time at the pace the line needs, about one request every 18 s for
   100 levels over 30 minutes, and never faster.
5. **The end.** At `t0 + T` the target itself is wanted (the off pair for
   a fade to off, FC13). The fade is done when that request is answered;
   it ends late by at most the one request then in flight.
6. **A budget, so repeated fades stay gentle.** A bucket of 20 fade
   requests that refills at 2 a second: one 3 s fade spends 7 to 18 of
   them; back-to-back fades fall to 2 steps a second, today's hold pace,
   which the house fan has taken since 1.0. They never fall to nothing:
   the target always goes.
7. **Where the clock starts.** At the fade's first request rather than at
   the tap: a slot busy with a fan command or a Breeze pair delays the
   whole fade by up to two step periods instead of making its first step a
   jump. From off, at the `lightOn`'s answer (FC12).
8. **Holds use the same engine**, at the hold rate: the owner asked for
   finer steps than today's 500 ms hold (#141).

A curve that spends more steps at the bottom (where a step of 8 levels is
far more visible than at the top) is an option probe FP2 can test; this
note keeps the straight line by default, since that is how a Navigator
animates a `CHANGING` (ASSUMED; the SDK note says).

### 1.4 An adaptive rate: the newest level as soon as the slot frees

**Yes, the queue already works this way** (VERIFIED: code). The latest
wanted level replaces the earlier one (`model.lua` L2003–2033), and the
transport calls the model's `on_idle` when the gap after each answer ends,
which sends whatever is wanted then (`transport.lua` L195–222, `model.lua`
L757–760). Two things stop a fade from using it:

- **The light wants too rarely.** Its 500 ms tick (`light.lua` L55,
  L383–390) is slower than the slot (0.41 s). Proposal: the fade's timer
  runs every `FADE_TICK_MS` (50 ms) or when the line moves by one level,
  whichever is later, and wants only on a change; the level sent is then at
  most 50 ms old. The alternative, the model asking the light for "the
  level now" when it plans the light's request, is exact but adds an
  interface to the model; the tick needs none.
- **The 250 ms gap** (`transport.lua` L23, `model.lua` L65) was ASSUMED for
  a fragile Wi-Fi stack (MFR §11 row 3) and caps the pace at about 2.4 a
  second. K13 sent 30 commands with no gap from the VM without an error
  (FT3), but the controller's path under a burst was never measured.
  Proposal: a separate `FADE_GAP_MS` for fade steps only (100 ms proposed),
  set from probe FP1; every other request keeps 250 ms. Gen 1/2 fans keep
  250 ms for fades too (FF13).

### 1.5 What fades cost the fan over a day

INFERRED: polling every 15 s is 5,760 reads a day. A 3 s fade is about 7
to 18 commands plus the fast window's ten reads, so 20 fades a day add
about 10 %. The difference is the shape: bursts of 3 to 6 requests a second
for a few seconds, which K13 showed the house fan takes, rather than the
sustained frequent polling that froze modules in the field (FT8). Whether
each level write costs the fan flash wear is unknown (ASSUMED harmless,
LSR §1.5); the ESP32's storage is wear-levelled, which is general knowledge
about its SDK, not checked for this firmware.

## 2. The light's response between requests

**Known (MEASURED on the house, Gen 3):**

- Every level from 1 to 100 is taken and echoed, also in a burst with no
  gap (FT3); the final state after a burst matched the last command (K13).
- A level written while off stays dark and is kept; `lightOn` then lights
  at it (FT2), so a fade from off can set its first level invisibly.
- A step answers in 0.1 to 0.6 s almost always, with a rare outlier of
  0.9 s through the controller and up to 2 s from the VM (FT4, FT5).

**Unknown (each needs the owner's eyes; section 4):**

| # | Question | Why it matters | Probe |
| --- | --- | --- | --- |
| U1 | Does the light jump to each new level, or glide over a short time of its own (many LED drivers do)? | A glide of 0.2 to 0.4 s would make 10 steps in 3 s read as one smooth fade; a hard jump would show a staircase | FP4, FP2 |
| U2 | How do 1, 2 and 5 levels a step look at the fan's pace, at the top and at the bottom? | Sets the shortest fade worth stepping and whether a curve is needed | FP2 |
| U3 | Does 3 s at the fan's pace read as a fade, from off and to off? | The owner's default | FP3 |
| U4 | Does `lightOn` true or false itself fade in or out (a soft start)? Two of M1's three turn-ons were answered only after 1.4 to 1.8 s (FT4), which may be a soft start the fan waits for, or chance | Decides whether the fade's last step before off should be 1 % or higher, and when a fade from off starts its clock (FC12) | FP4, FP3 |
| U5 | Is level 1 visibly on, are levels 1 to 5 distinct, does anything flicker low down? `dimTableId` (FT11) hints at a curve | The bottom of a fade to off, and the restore of FC13 | FP2 (low range) |
| U6 | Does the light follow every echo in a burst, or can its controller drop or merge steps (FT10)? | A fade's end must be where the echo says | FP3, FP6 |
| U7 | Does the controller's path behave like the VM's under a burst (latency growth, failures)? | The fade gap and the budget | FP1, FP6 |

**Gen 1, 2 and 3.** Every Gen 1–3 fan has the same light fields and no
fade field (FT1). The sources tell Gen 1 from Gen 2 apart nowhere: both
run firmware 01.03.00xx and the same interface (MFR §1), so nothing
suggests their lights differ. What differs is Gen 1/2 against Gen 3, on
the Wi-Fi side: Gen 1/2 run an older module with a much smaller network
stack (FT9), and every number in this note was measured on the house's
Gen 3 fan. Whether light kits dim differently between generations or
models is unknown; the light kit is named by `lightType` in the device
information, and the house has one kit.
Gen 4 fans (another protocol) are refused by the driver and out of scope.

## 3. Corner cases

Each row: what happens today (with the code), the proposal, and the
decision. "The fade" means any stepped change: a tap ramp, a timed target
from programming, a Navigator or a scene, a scene ramp, or a hold.

### 3.1 Control4 side

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| FC1 | **A second tap mid-fade** (outside the double-tap window) | A tap is a new target (`light.lua` `on_click` L585–595 → `target` L314–328). This project's `device.lua` has neither the double-tap window nor the ramp-stop hooks of HUE421 (D4, D5; `ramp_active`, `on_ramp_stop`) | Stop where the light is (HUE421 D5): withdraw any level wanted but not yet sent, let the step in flight finish, then `CHANGED` with the level the fan confirms (at most one step period later). No extra request, and the reported level is the real one rather than an estimate. Needs a model call to withdraw a wanted level (`release_group` L1613–1632 is internal today) and the port of HUE421's machine into `common/device.lua` | Automatic |
| FC2 | A second tap inside the double-tap window | As FC1 | Ignored; the fade goes on, the keypad's double-tap programming runs (HUE421 D4). The first tap's first step leaves at once | Automatic (the window's length is the SDK note's) |
| FC3 | **A hold mid-fade** | A hold starts a ramp from the shown level (`begin_ramp` L474–504) | Stop (FC1), then hold from the stopped level with the same engine at the hold rate (HUE421 rule table) | Automatic |
| FC4 | **Off mid-fade** (bottom tap, OFF, a Navigator) | Latest wins in the model | A new fade (or an instant off, by its rate) from the level shown now; the old one ends; no conflict on the wire | Automatic |
| FC5 | **A new target mid-fade** (slider, programming, a timed target) | Latest wins | A new fade from the level shown now, with its own `CHANGING` | Automatic |
| FC6 | **A scene mid-fade** | Scene targets as FC5; `RAMP_SCENE_UP`/`DOWN` start a hold-style ramp (L539–546); `STOP_SCENE_RAMP`, `STOP_RAMP_SCENE` and `SET_BRIGHTNESS_STOP` freeze a ramp (L510–519) | The same, with the fade engine; a stop command stops as FC1 | Automatic |
| FC7 | **A fan speed, direction or Breeze command mid-fade** | The fan group goes before the light (`GROUPS` L83) and a Breeze pair takes two requests in a row (L894–951) | Unchanged: the fan command waits for the one step in flight at most (0.1 to 0.6 s), the fade's next step waits one period and the line makes it bigger, the fade still ends on time. The fan's keypad LEDs follow the shown state at once, as today. The Away and learning switch-offs and the polls wait until the fade ends | Automatic |
| FC8 | **Toggle mid-fade** (the `TOGGLE` command; a toggle tap is FC1) | Toggle goes by the shown on state (`toggle` L345–354): during a fade to off that is still "on", so Toggle would fade to off again instead of back on | During a fade, "on" for Toggle and for the LEDs is the fade's target (FC9) | Automatic (FQ3) |
| FC9 | **Keypad LEDs of Light Top, Bottom and Toggle** (links 200, 201, 202) | They follow the shown on state (`is_on` L572–581), sent only when that changes (`device.lua` `update_leds` L448–457), so no per-step LED traffic. A fade up from off lights Top at the tap; a fade to off would keep Top lit and Bottom dark until the last step, about 3 s later | LEDs follow the fade's target from the tap (V10's "at once"), and are corrected when a fade is stopped (FC1), refused (FC15) or ended from outside (FF1) | Automatic (FQ3; the SDK note may show Control4 dimmers do otherwise) |
| FC10 | **Navigators and programming during a fade** | One `CHANGING`, rate 0 (L319); one `CHANGED` when the light group goes idle; nothing per step while a ramp runs (`settled` L626, `idle` L645; R5) | `CHANGING` at the start with the planned fade time, `CHANGED` at the end with the confirmed level; never one per step (V1D §4.7). Programming's light events follow `CHANGED`, so once per fade. A fade that ends late is corrected by its `CHANGED`. The **Status** row changes with every step's answer ("light 40 %", `texts.lua` L609–618; `driver.lua` `refresh_status` L196–207 on every `settled` and `shown`): acceptable, or held during a fade | Automatic |
| FC11 | **Very short or tiny fades** (a 250 ms click rate, a 0.75 s default rate, 1 or 2 levels) | Every rate is ignored | Sent at once (section 1.3, item 1) | Automatic |
| FC12 | **A fade from off** | "On at N" is the level, then `lightOn` (V14, `plan_group` L862–886) | The fade's first level is written while the light is off (dark, FT2), then `lightOn`; the line's clock starts when the `lightOn` is answered, since a turn-on may take over a second (FT4, U4). Costs one invisible request (skipped when the fan keeps that level already, L872) | Automatic |
| FC13 | **A fade to off** | Off is one `{"lightOn":false}`; the fan keeps the level it had | The fade steps down to 1 % (or U4's floor), then off. The fan then keeps 1 %, and the Modern Forms app, remote or wall control would later turn the light on at 1 %, since they resume the kept level (ECM S3, ASSUMED there; FT2 shows it for the local API). Proposal: once the off is answered and shows the light off, write back the level the fade started from (dark, FT2; one request). Control4's own ON is unaffected either way (Default On Brightness, V14) | Automatic if the owner agrees (FQ1) |
| FC14 | **Programming that fades in a loop**, or many fades from a scene | Each target is one request | The budget (section 1.3, item 6): sustained fades fall to 2 steps a second, and every target still goes | Automatic |
| FC15 | **A command refused mid-fade** (another fan answers, Gen 4, rebooting; `refusal` L1893–1901) | A refused step ends a ramp and reports the told level (`ramp_refused` L393–396) | The same for every fade | Automatic |
| FC16 | **A driver restart mid-fade** (a Director restart, a controller reboot, a dev-loop reload, a project load) | Timers die with the driver (`light.stop` L715–720); the first contact reports the fan's state to the proxies once, as "start" (R6; `settled` L633) | The light stays where the last step left it, and Control4 is told that level, which also ends a Navigator's animation. Nothing about a fade is stored | Automatic; Forbidden: resuming or finishing the fade after the restart, or writing a remembered level (ECM S10) |
| FC17 | **An update installed mid-fade** | As FC16 | As FC16. Taps that honour a click rate need `click_rates` True, a `<capabilities>` change: Composer's "Restart Director?" does not load it, the owner reboots the controller from System Manager (`CLAUDE.md`). The house light has never stored a click rate (`click_rates` False since 1.0), so the code default applies: 250 ms in this project's `device.lua` (L148–151), 3000 ms in the Hue project since HUE421 D3. What Composer shows before the reboot is the SDK note's | Automatic |
| FC18 | **A tap before the fan's state is known** (just started, a contact pending) | Toggle and ramps from an unknown state are refused (L349–352, L478–481); a top or bottom target waits for the contact | No fade without a known start level: the target goes at once after the contact | Automatic |

### 3.2 Fan side

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| FF1 | **The Modern Forms app, the remote, the wall control or the fan's own timer turns the light off mid-fade** | A level write leaves `lightOn` alone, so the next answer shows the off (FT2). But inside the 2.5 s settle window of a `lightOn` the fade sent (a fade from off), that off is held for one answer (`apply_read_value` L1344–1375), and the ramp keeps wanting "on at N", which the model turns into a level and then `{"lightOn":true}` (L870–886): **today's hold ramp would turn the light back on** within a second | The fade reads every answer's own `lightOn`; one that says off while the fade wants on ends the fade at once, with no further want, and the off is reported as a change from outside (`Last Change By`) | Automatic; Forbidden: turning it back on or re-sending the fade's level (ECM rule 7) |
| FF2 | **They turn it on, or change its level, mid-fade** | Not visible: the answer to the next step shows the driver's own level | A level changed elsewhere during a short fade is overwritten by the next step (within one step period); the manual says a press during a fade may be lost. During a slow fade a poll between two steps sees a level the fade did not set: that ends the fade and is reported from outside | Automatic |
| FF3 | **A poll answer mid-fade with an intermediate level** | No poll leaves while a level is wanted (L1009–1040); one already on the wire when the fade starts is applied as a read, a value contradicting a just-answered command is held by the settle window (L1344–1375), and nothing is reported while the light is busy (`reconcile` L1502–1525; `settled` L626) | Unchanged | Automatic |
| FF4 | **A request fails or times out mid-fade**, or **the fan goes offline** (a wall switch, Wi-Fi) | The step fails after 3 s (no connection) or 5 s (no answer); the model drops the light's wanted fields ("tried once", `on_failure` L1693–1736, `release` L1646–1678) and makes the next request a contact; the third failure in a row makes the fan offline, the light greys out and an open `CHANGING` is closed with the told level (`light.phase` L700–706). **Gap:** the ramp ignores the `idle` that follows (L645) and keeps wanting levels, and each want makes the contact go at once (`has_work` L797–810), so the failing fan is asked again as soon as each attempt ends (up to 5 s each) until the third failure makes it offline, with a "not sent" warning for each dropped step (L1630) even with Debug Mode Off | The fade ends at the first failure: the model tells the light that its want was dropped (a new listener call, or a reason on `idle`). Then, if the owner agrees (FQ2), the fade's target is wanted once as a jump, tied to the recovery contact, which drops it if that fails, exactly as the model already ties a command to a contact (header of `model.lua`, "tried once"). Nothing is retried step by step, and nothing is replayed when the fan comes back after being offline (ECM P8) | Automatic; Forbidden: retries and replays |
| FF5 | **The address changes mid-fade** (DHCP, Use Selected Fan, Fan Address typed) | A new epoch: the step in flight is given up and its answer dropped (`transport.lua` L67–75; `abandon_inflight` L1680–1691, "Request given up") | The fade ends; nothing of it goes to the new address. The follower starts only from an offline-like phase (`OFFLINE_LIKE` L105, checked at L2331), after the fade has ended | Automatic |
| FF6 | **A slow answer** (an outlier, FT4 and FT5) | Not a failure under the 5 s timeout | The line makes the next step bigger; the fade ends at most one answer late | Automatic |
| FF7 | **The fan reports another level than it was sent** (a fan that clamps, or has a floor of its own) | The house fan echoed every level from 1 to 100 (FT3). Another fan might not: each mismatch prints "The fan did not take light level …" at warning level (L1408), so a clamping fan would print one per step even with Debug Mode Off | One warning per fade; the fade still ends at its target | Automatic |
| FF8 | **Level 0 and off** | The fan has no level 0 (FT1); the driver never sends one (`light_body` L127–143, `validate` L1972–1980); a 0 read while on is reported as 1 (`wire.lua` `level_of` L315–336) | A fade to 0 ends with `{"lightOn":false}` (FC13) | Automatic |
| FF9 | **The fan's Wi-Fi module restarts mid-fade** (Reboot Fan, a firmware update, the app) | Reboot Fan: wants are refused while rebooting (L1893–1901); otherwise as FF4 | As FC15 and FF4 | Automatic |
| FF10 | **The fan's own automations** (Away mode, a schedule, a sleep timer) change the light mid-fade | Reported as from outside, with `userData` naming the source on Gen 3 | As FF1 and FF2 | Automatic |
| FF11 | **Another client polls the fan** (the app open on a phone, Home Assistant) | Slower answers (ECM P7) | Fewer, larger steps; the fade never speeds up to make up for them | Automatic |
| FF12 | **No light kit** | Light commands are refused and logged (`no_kit` L252–258) | No fade, nothing sent | Automatic |
| FF13 | **A Gen 1/2 fan** | Today's 2 steps a second on holds; nothing measured (FT9) | Fades keep the 250 ms gap and the 2-a-second budget on Gen 1/2 until a Gen 1/2 owner reports; the generation is known from the first answer (V1D §4.1) | Automatic by generation; Offered: Click Rate 0 makes taps instant (FL6) |
| FF14 | **Breeze blowing during a fade** | Gusts move the fan's speed, never the light; the gust guard concerns `fanSpeed` only ([`breeze-design.md`](breeze-design.md), BZ8) | Nothing | Automatic |

### 3.3 Lifecycle

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| FL1 | **A fade that never finishes** (a lost timer) | The light's watchdog closes a forgotten `CHANGING` after 10 s, but re-arms for as long as a ramp exists (`watchdog_fired` L288–298, L293): a lost ramp timer would leave the `CHANGING` open and the ramp set for good. A step that raises is caught and the ramp stopped (`contain`, `recover` L185–205) | Every fade carries a deadline, its planned end plus 10 s; past it the watchdog ends the fade and reports the confirmed level | Automatic |
| FL2 | **A rate changed mid-fade** (Click Rate, Hold Ramp Rate or Default On Brightness on the settings page) | — | The running fade keeps its plan; the next one uses the new value | Automatic |
| FL3 | **Debug Mode noise** | Each step logs the request (`transport.lua` L339) and the answer (`log_answer`, `model.lua` L736–752) at debug: about 20 to 40 lines per 3 s fade with Debug Mode On; with it Off only warnings and errors print (`log.lua` L20–23) | One debug summary line per fade ("light fade 0 → 100 over 3.0 s: 11 steps, ended at 3.2 s"); per-step lines stay at debug; at most one warning per fade (FF4, FF7) | Automatic |
| FL4 | **A fade on a fan without a light kit** | — | FF12 | Automatic |
| FL5 | **Nothing to persist** | — | No fade is stored, so none can be resumed after a restart or a restore from backup (FC16); the budget starts full | Forbidden: storing or resuming a fade |
| FL6 | **Turning fades off** | — | Composer's own fields: Click Rate 0 makes taps instant and a rate of 0 in programming is instant (as HUE421 does); no new property | Offered |
| FL7 | **The decision this reopens** | ECM S4 forbade "stepping the level in many requests" and V1D says a rate is not honoured (V14, §4.7); the manual says the light cannot fade | The owner's #141 decision supersedes those rows; the contract says so, and the manual's "No fades" and "Holds" text changes with the feature | (the contract) |

## 4. Hardware probes

To run later with the owner watching, through the dev loop
([`dev-loop.md`](dev-loop.md#development-commands)). Each takes under a
minute, is designed to be run twice (the same parameters, the light put
back as it was found, so the second run starts where the first did), and
the two runs are compared: a second median more than 25 % away from the
first marks the result as noise, to be run again another time. The owner is
told first what the light (and in FP5 the fan) will do and for how long.
Results go into #141 as comments.

**Before them:** a `--dev` build with the dev loop on the house (today it
runs dev build 144; after the 1.4 install a dev build goes back through the
Windows session and is recorded with `deploy.py record --no-manifest`),
pinned to a state that passes lint and tests. The new command is Lua-only
and dev-only (`fan/devcmds.lua` is in `DEV_ONLY_FILES`,
[`tools/build.sh`](../tools/build.sh) L46), so no reboot and no release
carries it.

**The new dev-only command, `Dev Light Steps`:**

- **Parameters:** `FROM` and `TO` (0 to 100, 0 is off; the light is set to
  `FROM` at once and the run starts 1 s later); either `STEP` (1 to 50
  levels a request) or `DURATION` (500 to 20000 ms, the time-based line of
  section 1.3); `EVERY` (0 to 2000 ms added after each gap; 0 is "as soon
  as the slot frees"); `GAP` (0 to 250 ms, the gap for this run only:
  `transport.GAP_MS` and `model.GAP_MS` are read when used, `transport.lua`
  L199, `model.lua` L768, and are put back after); `BACK` (yes: run `TO` →
  `FROM` after); `REPEAT` (1 to 4).
- **The path:** through the model's own slot, the way Dev Request goes
  (`m:request`, `model.lua` L2477–2501), so one request is in flight at a
  time, the gap holds and a due poll can slip in between, as it would. The
  bodies are `wire.body`'s. (On this path the proxy hears each change from
  the next read, as a change from outside; acceptable for a dev run, and
  the restore puts it back.)
- **Logs:** one line per answer (`Dev Light Steps 7/40: level 37 in
  0.16 s, waited 0.25 s`) and a summary (`40 sent, 40 answered, 0 failed,
  10.4 s, 3.8 a second, median 0.15 s, 90 % 0.26 s, worst 0.41 s, gap
  100 ms`).
- **Stops at once** on a failure, an answer slower than 2 s, an answer
  whose `lightOn` is not what the run expects (FP7), 60 s or 150 requests,
  and then restores.
- **Restores** the light as found: level first and then on when it was on,
  off first and then the level when it was off (the rule of
  [`fan-probe.md`](fan-probe.md#safety-rails)), and the gap.
- **Refuses** unless the fan is online, has a light kit and nothing is
  wanted or in flight.

| # | Probe | Commands (`devctl.py run …`) | Measures | Passes when | Time |
| --- | --- | --- | --- | --- | --- |
| FP0 | **Today's hold**, the baseline; needs no new code | `Dev Proxy BINDING=5002 COMMAND=SET_BRIGHTNESS_TARGET LIGHT_BRIGHTNESS_TARGET=10 RATE=0`; `Dev Press LINK=200 ACTION=push`; after one `devctl.py wait`, `Dev Press LINK=200 ACTION=release`; the start level back with `Dev Proxy` | The owner's word for today's 2 steps a second: smooth, slightly steppy or a staircase (also Composer checklist step 28, still open) | A word is recorded | about 20 s |
| FP1 | **The pace the fan sustains**, by gap | `Dev Light Steps FROM=30 TO=70 STEP=1 EVERY=0 GAP=250`, then `GAP=100`, then `GAP=0` (about 17, 11 and 7 s) | Steps a second, latency (median, 90 %, worst), the first ten steps against the last ten, failures | No failure, no answer over 1.5 s, the last ten's median within 1.5 times the first ten's; `FADE_GAP_MS` is the smallest gap that passes twice | under a minute for the three |
| FP2 | **1, 2 and 5 levels a step** at the fan's pace, the owner watching | With FP1's gap: `FROM=30 TO=70 STEP=1 BACK=yes`, `STEP=2`, `STEP=5`; then the bottom: `FROM=1 TO=15 STEP=1 BACK=yes`, `STEP=5` | The owner's word per run; at the bottom also whether 1 % is visibly on and whether anything flickers (U2, U5) | A word for each run | about 45 s, then about 15 s |
| FP3 | **The real fade** | `Dev Light Steps FROM=0 TO=100 DURATION=3000`, then `FROM=100 TO=0 DURATION=3000` (both include the dark first level, `lightOn`, and the final off), then the same with `DURATION=5000` | Steps and levels a step, the end against the plan; the owner's word: does it read as a fade, does the start from off look abrupt (U3) | Ends within one step period of the plan; a word for each | about 30 s |
| FP4 | **The light's own response** | `Dev Proxy … SET_BRIGHTNESS_TARGET` 20, then 80, then 20 (rate 0), then `COMMAND=OFF` and `COMMAND=ON` | The owner's word: does a big jump snap or glide; do on and off snap or fade (U1, U4) | A word for each | about 20 s |
| FP5 | **Sharing the slot** | One batch: `Dev Light Steps FROM=20 TO=80 DURATION=3000` and `Dev Proxy BINDING=5001 COMMAND=SET_SPEED SPEED=<one above the current>`; then the speed back | The speed request's wait (at most the step in flight), the fade's end (late by one step period at most), failures. That a batch's commands run straight after each other is ASSUMED from [`dev-loop.md`](dev-loop.md); the log's times show it | All three hold | about 15 s |
| FP6 | **Repeated fades**, only after FP1 and FP3 passed | `Dev Light Steps FROM=30 TO=70 DURATION=3000 BACK=yes REPEAT=4` (24 s of fading) | Latency drift and failures under continuous fading; the budget's numbers (U6, U7). The stop rule ends it at the first sign of trouble; if the fan stops answering, the owner switches it off at the wall for 10 s (MFR §8) | No failure; the last fade's median within 1.5 times the first's | about 30 s |
| FP7 | **An off from outside**, optional, the owner's hands | `Dev Light Steps FROM=20 TO=80 DURATION=20000`; half way the owner turns the light off with the Modern Forms remote or app | That the next answer shows `lightOn` false (FF1) and the run stops there and says so | The stop line names the off | about 30 s |

Before the dev command exists, [`tools/mf_probe.py`](../tools/mf_probe.py)
`check K15` can show the owner K15's staircase again straight from the VM
(not through the controller), which answers FP2's question for 9 levels a
step. After the fade is built, FP3 runs again through the real path
(`Dev Proxy BINDING=5002 COMMAND=SET_BRIGHTNESS_TARGET
LIGHT_BRIGHTNESS_TARGET=100 RATE=3000`) as the feature's acceptance check.

## 5. For the contract, and questions for the owner

**What this note proposes for the contract** (each INFERRED until the
probes):

- One fade engine for tap ramps, timed targets, scene ramps and holds:
  time-based, sent when the slot frees, one request per level at most, a
  budget, a deadline (sections 1.3 and 1.4).
- Constants for the probes to settle: `FADE_GAP_MS` (100 proposed),
  `FADE_MIN_MS` (about 1000), 3 levels as the smallest fade, `FADE_TICK_MS`
  (50), the budget (20 requests, 2 more a second), the deadline (end + 10 s).
- Interfaces: a model call to withdraw a wanted level (FC1); the model
  telling the light that its want was dropped, and the fade seeing each
  answer's own `lightOn` (FF1, FF4); `is_on` and Toggle reading the fade's
  target (FC8, FC9); HUE421's double-tap window and stop hooks in
  `common/device.lua` (FC1, FC2).
- Rows the feature supersedes: ECM S4, V1D V14's "no fades" and §4.7's
  "the rate is not honoured", the manual's "No fades" and "Holds"
  sections, and `RAMP_STEP_MS` (FL7).

**Questions for the owner** (the recommended answer first):

| # | Question | Recommended |
| --- | --- | --- |
| FQ1 | After a fade to off, put back the level the fan keeps (one dark write), so the app, the remote or the wall control later turn the light on where it was rather than at 1 %? (FC13) | Yes |
| FQ2 | When a step fails mid-fade, try the fade's target once as a jump as soon as the fan answers again (tied to that first contact, dropped if it fails, never after the fan was offline)? Or leave the light where it stopped? (FF4) | Yes, the one jump |
| FQ3 | Do the keypad LEDs and Toggle follow the fade's target from the tap? (FC8, FC9) | Yes, unless the SDK note shows Control4's own dimmers do otherwise |
| FQ4 | A 100 ms gap for fade steps on Gen 3 fans if FP1 passes twice, 250 ms on Gen 1/2? (section 1.4, FF13) | Yes |
| FQ5 | A straight line, or a curve with more steps at the bottom? (section 1.3) | The straight line, unless FP2 shows the bottom as a staircase |

## Sources

Every claim above names its source: the code as cited (branch
`feature/light-fades-141`, commit 714dbe2), the measurements M1 (issue #17,
2026-10-27) and DEVLOG (2026-11-09; the numbers were counted from the log's
request and answer lines, nothing else of it is reproduced here), and the
project's own notes:
[`modernforms-api-research.md`](modernforms-api-research.md) (§1, §2.3, §3,
§8, §9, §10, §11),
[`v1-design.md`](v1-design.md#34-polling-backoff-and-offline) (§3.4,
[§4.3](v1-design.md#43-what-goes-next),
[§4.4](v1-design.md#44-applying-an-answer),
[§4.5](v1-design.md#45-settled-reports-r1r9),
[§4.7](v1-design.md#47-the-light),
[§11.1](v1-design.md#111-what-the-probe-has-shown-so-far-17)),
[`edge-cases-modernforms.md`](edge-cases-modernforms.md#6-commands-and-state),
[`light-structure-research.md`](light-structure-research.md#15-rates-ramps-and-holds-without-a-native-dim),
[`fan-probe.md`](fan-probe.md), [`dev-loop.md`](dev-loop.md),
[`status.md`](status.md), and the Hue project's tap-stop contract (HUE421).
The Control4 side is `docs/light-fades-sdk-research.md`.
