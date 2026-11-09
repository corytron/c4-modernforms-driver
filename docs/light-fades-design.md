# Simulated light fades (#141)

The contract for [issue #141](https://github.com/corytron/c4-modernforms-driver/issues/141).
Every agent builds against this text. The research behind it:

- [the Control4 side](light-fades-sdk-research.md): every way Control4 asks
  the light to change, which inputs carry a rate, what the proxy expects to
  hear, what `click_rates` costs, and what Control4's own dimmers do;
- [the fan's side](edge-cases-light-fades.md): what one level step costs,
  how the fan takes bursts, and the corner cases FC1–FC18, FF1–FF14 and
  FL1–FL7 with a decision for each.

References like "SDK §2.5" and "EC FF4" point into those two notes, and
"HUE421 D5" into the Hue project's
[tap-stop contract](https://github.com/corytron/c4-hue-driver/blob/main/docs/tap-stop-design.md).

## 1. What the owner asked for and decided

**The request (#141).** The fan's light has no fade of its own: its local
API has only `lightOn` and a level from 1 to 100, with no transition time
(EC FT1). The owner wants the driver to fade it by stepping through levels,
so that a change of level looks like a Control4 dimmer's fade.
- A keypad tap ramps.
- A second tap stops the ramp.
- The default is a 3 s tap ramp, as across the owner's drivers (#140).

**The answers (#146, 2026-11-09).** The owner answered "all recommended" to
Q1–Q8 (the SDK note's questions) and FQ1–FQ5 (the fan note's). Q6 and FQ3
disagree about when the keypad LEDs change on a fade to off, and probe H4
decides between them (D18).

**Everything runs in the driver on the controller.** The owner checked this
on #146.
- Every step is timed with the controller's own `C4:SetTimer` and
  `C4:GetTime` [verified: API `34_timer/_1-SetTimer.md`, `_2-GetTime.md`].
- Every step is sent to the fan with `C4:url`, as every command is today.
- The VM, the dev loop and the internet take no part, and the fan has no
  fade to use.

## 2. Decisions

| # | Decision | Source |
| --- | --- | --- |
| LF-D1 | **One fade engine for every stepped change**, in `fan/light.lua`: tap ramps, timed targets, holds and scene ramps. It replaces the 500 ms hold ramp (`RAMP_STEP_MS` goes). | EC §5; SDK §5 |
| LF-D2 | **What fades, and for how long.** Section 3 has the full table. Click and hold rates are speeds: the time for the whole range, so a fade lasts `rate × distance / 100`. `RATE`, `TIME` and the Default Brightness Rate are durations: the time for this one change. | SDK §1.2; Q2 |
| LF-D3 | **Taps fade through Click Rates.** `click_rates` becomes True, with `click_rate_min` 0 and `click_rate_max` 86 400 000. The light's settings page then shows Click Rates Ramp Up and Ramp Down, as on Control4's dimmers and the Hue Light. Both default to **3000 ms**. The change is static, so after the release install the owner reboots the controller once from System Manager. The deprecated capabilities stay (Q8). | Q1, Q2, Q8; SDK §2 |
| LF-D4 | **Commands without a time use the Default Brightness Rate.** That covers `ON`, `OFF`, `TOGGLE`, `SET_LEVEL`, a `RAMP_TO_LEVEL` without `TIME` and a `SET_BRIGHTNESS_TARGET` without `RATE`. The proxy tells the driver the rate with `UPDATE_BRIGHTNESS_RATE_DEFAULT` {`RATE` ms} [verified: LV2 cmds `_20.2`, `_21.3`]; the driver persists it and does not answer. Until the proxy sends one, the driver uses **750 ms**, the rate the house's proxy is believed to use (ASSUMED, from SDK §3.4; H1 reads it). At the install, the Windows session sets this light's Default Brightness Rate to **3 s** in Composer (Q5). | Q3, Q5 |
| LF-D5 | **Too short or too small to fade** goes as one request, as today. That is a fade under `FADE_MIN_MS` = 1000 ms or over fewer than `FADE_MIN_LEVELS` = 3 levels. It covers a rate of 0, the Navigator slider (rate 0, Q4) and the 750 ms default rate. | EC §1.3 item 1; Q4 |
| LF-D6 | **Steps go by time, not by size.** A fade is a straight line `{ from, to, t0, T }`. Every `FADE_TICK_MS` = 50 ms the light computes the line's level for that moment, rounded, and wants it only if it differs from the level it last wanted. The model keeps only the newest wanted level and sends it when the slot frees. A slow answer therefore makes the next step bigger, and no level is wanted twice. At `t0 + T` the target itself is wanted. | EC §1.3, §1.4 |
| LF-D7 | **Fade gap.** After a fade step's answer the transport waits `FADE_GAP_MS` instead of 250 ms. That is **100 ms on Gen 3** if probe FP1 passes twice at 100 (otherwise the smallest gap that does). Gen 1/2 fans and fans of unknown generation keep 250 ms. Every other request keeps 250 ms. | FQ4; EC §1.4, FF13 |
| LF-D8 | **A budget keeps repeated fades gentle.** It is a bucket of `FADE_BUDGET` = 20 fade-step requests that refills at `FADE_REFILL_PER_S` = 2 a second, kept in the model. An empty bucket holds the next step until a token comes back. The fade's final target and every non-fade request ignore it. | EC §1.3 item 6, FC14 |
| LF-D9 | **A fade from off** first wants `{ light_on = true, level = first }` as an ordinary want. The model writes the level while the light is dark, then sends `lightOn` (EC FT2, FC12). `first = max(1, round(to × FIRST_STEP_MS / T))`, with `FIRST_STEP_MS` = 400. The line from `first` to `to` then runs over `T − FIRST_STEP_MS`. Its clock starts when the light hears the model's `idle` for that want, because a turn-on may take over a second (EC FT4, U4). | EC FC12 |
| LF-D10 | **A fade to off** steps down to 1, then wants `{ light_on = false }` as its final target. CHANGED 0 goes out at that want's `idle`. Then, if the light is still off and nothing else is wanted, the light wants `{ light_on = false, level = from }` once. That writes the starting level back while the light is dark, so the Modern Forms app, the remote or the wall control later turns the light on where it was, not at 1 %. The write is skipped when `from` is the level the fan keeps already. | FQ1; EC FC13, FF8 |
| LF-D11 | **Reporting.** `LIGHT_BRIGHTNESS_CHANGING` {current, target, `RATE` = the planned time in ms} goes out once at the start. `LIGHT_BRIGHTNESS_CHANGED` goes out once at the end or the stop, with the level the fan confirmed. Nothing is sent per step [verified: LV2 notif `_10.2`, `_10.3`, `_12`; BP "Brightness Target API"]. A fade too short to fade (LF-D5) keeps today's CHANGING with rate 0. The Status row may change with each step's answer, which is acceptable (EC FC10). | SDK §1.3; EC FC10 |
| LF-D12 | **The tap machine of HUE421 comes over whole**, in `common/device.lua`. A press within `DOUBLE_TAP_MS` = 600 ms of the previous press on the same button starts nothing and stops nothing. While a fade runs, the press of any button outside that window stops it, and the click that follows is swallowed. A press held past the hold time stops the fade, then holds from the stopped level. Any fade can be stopped this way, not only a tap's own. | Q7; HUE421 D4–D6; SDK §3.5 |
| LF-D13 | **The stop.** The light withdraws any level it wanted but the model has not sent (`m:withdraw("light")`, section 4.3) and lets the step in flight finish. It then reports CHANGED with the level the fan confirmed, at the `idle` that follows, or at once when nothing is in flight. No extra request goes out, and the reported level is the real one. `SET_BRIGHTNESS_STOP`, `STOP_SCENE_RAMP` and `STOP_RAMP_SCENE` stop the same way. | EC FC1, FC6; SDK I13; HUE421 D7 |
| LF-D14 | **A new command replaces the fade** from the level shown now. That covers a tap that is not a stop, a target, `ON`, `OFF`, a scene and a slider. It sends a new CHANGING with no CHANGED in between. A fan, direction or Breeze command does not end a fade: it takes the slot for one request, and the line makes the next step bigger. | EC FC4, FC5, FC7; SDK §1.4 |
| LF-D15 | **A fade never fights anyone.** An answer showing the light off when the fade did not turn it off ends the fade at once, with no further want. Such an off comes from the Modern Forms app, the remote, the wall control or the fan's timer. The model applies that off without its settle hold (section 4.3), and the off is reported as a change from outside. During a slow fade, a poll that shows a level the fade did not set also ends it, and is reported as a change from outside. The fade never turns the light back on or re-sends its level. | EC FF1, FF2, FF10; ECM rule 7 |
| LF-D16 | **A failure ends the fade.** At the first failed or given-up step: the fade ends, the CHANGING is closed with the confirmed level, and one warning is logged. Then the fade's target is wanted once as a jump, tied to the recovery contact (`after_contact`, section 4.3). That want does not hurry the contact, is dropped if the contact fails, and is never sent after the fan has gone offline. Nothing is retried step by step. An address change ends the fade and sends nothing of it to the new address. | FQ2; EC FF4, FF5, FF9 |
| LF-D17 | **Every fade has a deadline:** its planned end plus `WATCHDOG_MS` (10 s). Past it, the watchdog ends the fade and reports the confirmed level, even if a timer was lost. | EC FL1 |
| LF-D18 | **Toggle and the keypad LEDs during a fade.** `TOGGLE` and a toggle tap go by the fade's target: a fade to off counts as off, a fade up as on. For the LEDs, `light.LEDS_FOLLOW` decides. The default `"target"` changes them at the start of the fade (FQ3). `"light"` keeps a fade to off showing on until the light is off (Q6). Probe H4 sets the value the release ships with: a Control4 dimmer on the house, given a 5 s Click Rate Down and tapped off, shows when its LED changes. | Q6, FQ3; EC FC8, FC9 |
| LF-D19 | **Holds and scene ramps run on the engine**, at the hold rates, toward 100 (up) or 1 (down). A hold from off still turns on at 1 % first and starts after `DIM_AFTER_ON_MS`, as today. A release, or a scene's stop, is the LF-D13 stop. | EC §1.3 item 8, FC3 |
| LF-D20 | **Logging.** With Debug Mode On there is one summary line per fade, for example `light fade 0 → 100 over 3.0 s: 11 steps, ended at 3.2 s`. The per-step request and answer lines stay at debug, and so do the parameters of every rate command (H1–H3). A fade logs at most one warning, whether for a failure or for a fan that kept another level. The model's per-step warnings for fade steps go to debug. | EC FL3, FF4, FF7; SDK §7 |
| LF-D21 | **Nothing about a fade is stored.** After a restart, a reboot or an update installed mid-fade, the light stays where its last step left it, and the first contact tells Control4 that level. Resuming or finishing a fade after a restart is forbidden. | EC FC16, FC17, FL5 |
| LF-D22 | **A rate changed during a fade** applies to the next fade. | EC FL2 |
| LF-D23 | **The shape** is a straight line, unless probe FP2 shows a staircase at the bottom (FQ5). A curve would then be a later issue. | FQ5 |
| LF-D24 | **No new property.** Fades are turned off with Control4's own fields: Click Rate 0 makes taps instant, and a rate of 0 in programming is instant. | EC FL6 |

Constants, each a field of its module so the specs and the probes can set
it: `FADE_TICK_MS` 50, `FADE_MIN_MS` 1000, `FADE_MIN_LEVELS` 3,
`FIRST_STEP_MS` 400 and `LEDS_FOLLOW` `"target"` in `fan/light.lua`;
`FADE_GAP_MS` 100, `FADE_BUDGET` 20 and `FADE_REFILL_PER_S` 2 in
`fan/model.lua`; `DOUBLE_TAP_MS` 600 in `common/device.lua`. The probes
(section 7) may change `FADE_GAP_MS`, `FIRST_STEP_MS` and `LEDS_FOLLOW`
before the release.

## 3. The rule

"Fading" means a fade of LF-D1 is running. "Within the window" means a
press within `DOUBLE_TAP_MS` of the previous press on the same button. A
level is "at the preset" within 1 point. "Default rate" is LF-D4's.

| State | Input | Action |
| --- | --- | --- |
| Off | top tap, toggle tap | Fade to the preset over `click up × preset / 100` |
| On, below the preset | top tap | Fade up to the preset over `click up × distance / 100` |
| On, above the preset | top tap | Fade down to the preset over `click down × distance / 100` |
| At the preset | top tap | Nothing sent; CHANGED with the level |
| On | bottom tap, toggle tap | Fade to off over `click down × level / 100` |
| Off | bottom tap | Nothing |
| Any | `SET_BRIGHTNESS_TARGET` with `RATE` | Fade over `RATE` (0: one request, Q4) |
| Any | `SET_BRIGHTNESS_TARGET` without `RATE` | Fade over the default rate |
| Any | `RAMP_TO_LEVEL` | Fade over `TIME`, or the default rate without one |
| Any | `ON`, `OFF`, `SET_LEVEL` | To the preset, off or the level, over the default rate |
| Any | `TOGGLE` | By the fade's target while fading, else by the shown state (LF-D18), over the default rate |
| Any | a press within the window | Ignored (LF-D12); a fade goes on; held, it becomes a hold |
| Fading | a press outside the window, any button | Stop (LF-D13); the click that follows is swallowed |
| Fading | that press held past the hold time | Stop, then hold from the stopped level |
| Fading | its time runs out | The target is wanted; CHANGED at its `idle` |
| Fading | `SET_BRIGHTNESS_STOP`, `STOP_SCENE_RAMP`, `STOP_RAMP_SCENE` | Stop (LF-D13) |
| Fading | any other brightness command | A new fade (or one request) from the level shown now (LF-D14) |
| Fading | a fan, direction or Breeze command | The fade goes on (LF-D14) |
| Fading | an answer shows off that the fade did not send | The fade ends; reported from outside (LF-D15) |
| Fading | a step fails | The fade ends; the target once after the contact (LF-D16) |
| Fading | the deadline passes | The fade ends; CHANGED with the confirmed level (LF-D17) |
| Fading | the fan goes offline, rebooting, foreign | The fade ends; CHANGING closed with the told level, as today |
| Any | hold, scene ramp | A fade toward 100 or 1 at the hold rate (LF-D19) |
| Within the click guard after a hold's release, same button | click | Ignored (unchanged) |

Taps, holds and every command still go through the checks they have today:
no light kit refuses (EC FF12), and an unknown state refuses Toggle and
ramps (EC FC18).

## 4. Interfaces

### 4.1 `src/common/device.lua` (the button machine and the settings)

Port the #421 pieces of the Hue project's `src/common/device.lua`
(`~/projects/c4-hue-driver/src/common/device.lua`, Apache-2.0, the owner's
own code) and leave every other block as it is:
- `device.DOUBLE_TAP_MS = 600`, exported;
- the per-button time of the last press, from `C4:GetTime()`;
- the hooks `dev.ramp_active()` (default false) and
  `dev.on_ramp_stop(button)` (default nothing);
- press records marked `multi` or `stopped`, whose clicks are swallowed;
- a click with no press record gets the same window and stop rules at the
  click.

Two changes to `SETTINGS`:
- `click_up` and `click_down` default to **3000**.
- A new `brightness_rate` setting: key `brightness_rate_default`, default
  **750**, command `UPDATE_BRIGHTNESS_RATE_DEFAULT`, param `RATE`, min 0,
  max 86 400 000, and **no** answer notify, because the command returns
  nothing [verified: LV2 cmds `_20.2`]. The setting is taken only when the
  driver lists it (`opts.settings`), as the others are. When it arrives,
  `RATE` is logged at debug (H1).

### 4.2 `src/modernforms_fan/fan/light.lua` (the fade engine)

- **A fade record:** `{ kind = "tap" | "timed" | "hold" | "scene", h, from,
  to, t0, T, last, first_pending, deadline, steps, timer, restore }`.
  Levels are proxy levels, 0 for off.
- **`light:fade(to, T, kind, what)`.** Replaces `target`'s single want when
  LF-D5 allows a fade; otherwise it is today's one request. It stops any
  running fade first (LF-D14), opens CHANGING with the planned `T`, and
  starts the tick of LF-D6. From off it follows LF-D9, and to off LF-D10.
- **Fade steps** are wanted with `m:want(fields, { fade = true })`.
  - The first want of a fade from off is an ordinary one.
  - The final target is ordinary too: `{ light_on = true, level = to }`, or
    `{ light_on = false }`.
  - The LF-D10 restore is `{ light_on = false, level = from }`.
- **`light:stop_fade(why)`** does the stop of LF-D13: `m:withdraw("light")`,
  then the CHANGED at the `idle`, or at once with `close_if_idle`.
- **Hooks:** `dev.ramp_active` returns true while a fade runs, and
  `dev.on_ramp_stop(button)` calls `stop_fade`.
- **`dev.is_on`** follows LF-D18: with `LEDS_FOLLOW` `"target"` it returns
  `fade.to > 0` while a fade runs. `toggle` reads the fade's target. The
  light calls `dev.update_leds()` when a fade starts, ends or stops.
- **`light:dropped(why)`** is new, called by the coordinator's listener.
  - `"failed"` or `"given_up"`: LF-D16.
  - `"off_outside"`: LF-D15.
  - `"refused"`: as `ramp_refused` today.
- **`settled(st, why)` while fading:** `why == "outside"` with the light off,
  or with a level other than the fade's last wanted level, ends the fade
  (LF-D15) and is reported. Any other settled is ignored while fading.
- **`idle(st)` while fading:** after the first want of a fade from off it
  starts the line (LF-D9). After the final target it reports CHANGED and
  ends the fade, then runs the LF-D10 restore. Otherwise it is ignored
  (steps in between).
- **The watchdog** ends a fade past its deadline (LF-D17), and is no longer
  re-armed for as long as a ramp exists.
- **Rate commands** log their parameters at debug (H1–H3). A missing or
  non-numeric `RATE` or `TIME` means the default rate, and a negative one
  means 0.
- **`debug()`** adds `fading`, `fade_kind`, `fade_from`, `fade_to`,
  `fade_ms` and `fade_steps`.
- **Settings it reads:** `dev.setting("click_up" | "click_down" | "hold_up"
  | "hold_down" | "brightness_rate" | "preset")`.

### 4.3 `src/modernforms_fan/fan/model.lua` and `transport.lua`

- **`m:want(fields, opts)`** gains an optional `opts`:
  - **`opts.fade = true`** marks the light group's wanted fields as a fade
    step; a later want without it clears the mark.
    - The request planned from them carries `fade = true` and
      `gap_ms = self:fade_gap()`. That is `model.FADE_GAP_MS` on a Gen 3
      fan and `model.GAP_MS` on any other or unknown generation (from the
      pin's `generation`).
    - The budget of LF-D8 applies to these requests only.
    - When a fade step's wanted fields are dropped, the "not sent" warning
      of `release_group` is logged at debug, and so is the "did not take
      light level" warning on its answer.
  - **`opts.after_contact = true`** (LF-D16): the want is held until the
    next successful contact, then sent once.
    - It does not make the contact go sooner: `has_work` ignores it.
    - It is dropped with `dropped("light", "failed")` if that contact fails
      or the phase leaves online.
- **`m:withdraw(group)`** removes that group's wanted but unsent fields
  without a warning (`release_group` with no reason), leaves the request in
  flight alone, and returns true when something was removed.
- **`{ light_on = false, level = N }`** is accepted (LF-D10). It means off
  and then, once the off is answered, the dark write
  `{"lightBrightness":N}`. The write is skipped when the fan keeps N
  already. `validate` and `plan_group` take it, and `wire.light_body`
  already makes a level-only body.
- **A new listener event, `dropped(group, why)`**, emitted once, before the
  `idle` that follows. Why is one of:
  - `"failed"`: a request carrying the group's fields failed, through
    `on_failure`;
  - `"given_up"`: through `abandon_inflight`;
  - `"refused"`: through the phase's refusal;
  - `"off_outside"`: below.
- **The off from outside (LF-D15).** This applies while the light's wanted
  fields or its request in flight are a fade step, and the driver has sent
  no `{"lightOn":false}` since its last `{"lightOn":true}`. An answer whose
  own `lightOn` is false is then applied at once, without the settle
  window's hold (`apply_read_value`). The fade-step fields are dropped, and
  the listener hears `dropped("light", "off_outside")`, then the usual
  `settled("light", st, "outside")` and `outside` events.
- **`transport.send(req)`** honours an optional `req.gap_ms` (≥ 0) for the
  gap after that request's answer; `GAP_MS` is the default. The gap timer
  keeps its rule of a delay above 0 (1 ms at least).

### 4.4 `src/modernforms_fan/fan/devcmds.lua` (dev-only)

`Dev Light Steps`, exactly as EC §4 specifies:
- parameters `FROM`, `TO`, `STEP` or `DURATION`, `EVERY`, `GAP`, `BACK`,
  `REPEAT`;
- the path through `m:request`;
- the per-answer and summary log lines;
- the stop rules: a failure, an answer over 2 s, an unexpected `lightOn`,
  60 s or 150 requests;
- the restore, level first and then on, or off first and then the level;
- the refusals.

The file is in `DEV_ONLY_FILES`, so no release carries it.

### 4.5 `src/modernforms_fan/driver.lua`, `driver.xml` (coordinator)

- The light's settings list becomes `{ "preset", "click_up", "click_down",
  "hold_up", "hold_down", "brightness_rate" }`.
- The model's listener routes `dropped` to `light:dropped(why)` for the
  light group.
- `driver.xml` changes in `<capabilities>`: `click_rates` True,
  `click_rate_min` 0, `click_rate_max` 86400000 (LF-D3), with a comment that
  this needs a controller reboot.

## 5. Files and owners

Agents edit only their own files; others are editing the rest of the
checkout at the same time. No agent runs git.

| Owner | Files |
| --- | --- |
| Agent A | `src/common/device.lua`, `tests/spec/device_spec.lua` |
| Agent B | `src/modernforms_fan/fan/light.lua`, `tests/spec/light_spec.lua` |
| Agent C | `src/modernforms_fan/fan/model.lua`, `src/modernforms_fan/fan/transport.lua`, `src/modernforms_fan/fan/wire.lua` if needed, `tests/spec/model_spec.lua`, `tests/spec/transport_spec.lua`, `tests/spec/wire_spec.lua` if needed |
| Agent D | `src/modernforms_fan/fan/devcmds.lua`, `tests/spec/devcmds_spec.lua` |
| Agent E | `src/modernforms_fan/www/documentation.html`, `docs/composer-checklist.md`, `docs/v1-design.md` (only V14, V19 and §4.7, marked superseded by this contract), `docs/edge-cases-modernforms.md` (only S4, likewise) |
| Coordinator | `src/modernforms_fan/driver.lua`, `src/modernforms_fan/driver.xml`, `tests/spec/fan_driver_spec.lua`, `CHANGELOG.md`, `docs/README.md`, `docs/status.md`, `.github/codenames.json`, this file, integration and commits |

## 6. Done for each agent

- The behaviour of sections 2 to 4 for the agent's files, with busted specs
  for every row of section 3 and every interface of section 4 the files
  touch. Use the fake C4 runtime and the fake timers and clock the existing
  specs use.
- Lua 5.1 only, tabs, `.luacheckrc` clean.
- `luacheck src tests tools`, `busted tests` and `python3 tools/lua_limits.py`
  pass for the agent's files. Another agent's half-finished file may break
  other specs meanwhile: report those failures, don't fix them.
- Agent E: `python3 tools/check_links.py` passes, and the manual follows
  Control4's own words for its settings rows.
- Comments cite this contract as `#141 LF-D<n>` and mark DriverWorks claims
  [verified: …] or [assumed] as the code already does. Snap One's documents
  are never quoted.

## 7. On the house

All with the owner watching. Each probe takes under a minute and runs
twice, one at a time, asking the owner before each. They flash the bedroom
light, so they run only while the owner is awake and has said yes.

1. **A `--dev` build of this branch** through the Windows session, which
   needs the owner's own word in that session's chat. Record it with
   `deploy.py record --no-manifest`.
2. **The fan probes FP0–FP7** (EC §4) through `Dev Light Steps`. FP1 sets
   `FADE_GAP_MS`, FP2 checks the shape (LF-D23), and FP4 checks
   `FIRST_STEP_MS`. Results go into #141 as comments.
3. **The Control4 checks H1–H5** (SDK §7).
   - H1 reads the Default Brightness Rate the proxy sends; if it is not
     750, LF-D4's built-in value changes.
   - H4 sets `LEDS_FOLLOW` (LF-D18).
   - H7 (optional) tries `click_rates` dynamically; if it works, LF-D3
     needs no reboot.
4. **The acceptance check:** FP3 again through the real path, `Dev Proxy
   BINDING=5002 COMMAND=SET_BRIGHTNESS_TARGET LIGHT_BRIGHTNESS_TARGET=100
   RATE=3000`, then a keypad tap up, a tap to stop, and a tap down.
5. **The release** (1.5), its install, and then the owner's controller
   reboot from System Manager for LF-D3.
   - After the reboot, the Windows session reads the light's Click Rates
     (3.000 s), checks Composer accepts 3000 ms (H6), and sets the Default
     Brightness Rate to 3 s (LF-D4).

## 8. Not in this issue

- A curve instead of the straight line, unless FP2 asks for it (LF-D23).
- The light's own button events (`has_button_events`): another capability
  change and reboot.
- Dropping the deprecated capabilities (Q8).
- Brightness rate ranges (`brightness_rate_min`, `_max`): nothing here
  needs them.

## 9. Control4 guidelines

The owner's rule (#422): lighting behaves like Control4's own dimmers and
keypads. The rows are the SDK note's section 8 list as the Hue project's
#421 used it (HUE421 section 9).

| Guideline | How this design meets it |
| --- | --- |
| A tap ramps to full or off, and a tap while dimming stops it | LF-D3, LF-D12, LF-D13, section 3 |
| A hold brightens or dims while held | LF-D19; a hold during a fade starts from the stop |
| The On preset applies whatever the level | Section 3: a top tap fades to the preset, up or down |
| Click and hold rates are whole-range times | LF-D2 |
| Click rates for quick changes, hold rates for slow | 3000 ms click under 5000 ms hold |
| Rates inside the declared min and max | LF-D3: `click_rate_min` 0, `click_rate_max` 86 400 000; hold rates unchanged |
| Commands without a rate use the Default Brightness Rate | LF-D4 |
| Double and triple taps within about half a second are the keypad's | LF-D12 |
| Echo every `BUTTON_ACTION`; a release follows a push | Unchanged |
| On a link, act on the push where hold against click does not matter | The stop acts on the push (LF-D12) |
| CHANGING at the start, CHANGED at the end, no level per step | LF-D11 |
| Tiles animate from CHANGING | LF-D11: CHANGING carries the planned time |
| `supports_brightness_stop` means a ramp can be stopped | LF-D13 |
| Ramp events and `IS_BRIGHTNESS_TARGET` fire once per fade | LF-D11 |
| Keypad LEDs follow the bound device | LF-D18, set by H4 to match a Control4 dimmer |
| Every CHANGING is closed, even when a command fails | LF-D13, LF-D16, LF-D17 |
| The level is a whole percent, never 0 while on | Unchanged (EC FF8) |

**Departures, forced by the hardware:**
- A fade is a staircase of about 7 to 18 steps over 3 s, not a smooth
  dimmer curve. The fan takes one request at a time, about 2.4 to 6 a
  second (EC §1.2).
- A tap during a fade stops at the level of the step in flight, up to one
  step period after the press.
- A change made in the Modern Forms app or on the remote during a short
  fade may be overwritten by the next step (EC FF2). The manual says so.

## 10. What this supersedes

- [`v1-design.md`](v1-design.md): V14's "no fades", V19's `click_rates`
  False, and §4.7's "the rate is not honoured".
- [`edge-cases-modernforms.md`](edge-cases-modernforms.md): S4's "stepping
  the level in many requests" is now allowed, within LF-D7 and LF-D8.
- The manual's "No fades" and "Holds" sections, and its limits list.
- `RAMP_STEP_MS` in `fan/light.lua`.
