# Breeze in Control4 (#111)

The contract for issue [#111](https://github.com/corytron/c4-modernforms-driver/issues/111):
the owner asked (2026-11-07) that the fan's Breeze be switched from Control4,
and that it show on the Navigators (the Control4 app, touchscreens), which
matters more than Composer. It rests on two research notes:
[`breeze-research.md`](breeze-research.md) (BRR: the fan's side) and
[`edge-cases-breeze.md`](edge-cases-breeze.md) (ECB: the Control4 side, BC1
to BC36). Where this file and they differ, this file wins; where it is
silent, ECB section 3 and its BC decisions are the rule.

## 1. Decisions

| # | Decision | Basis |
| --- | --- | --- |
| BZ1 | **"Breeze blows"** means the fan reports `wind` true **and** `fanOn` true. That one value drives the `Breeze` variable, the events, the condition, link 311's LED and the companion's tile. `Status` keeps the raw flag (` Breeze 2` blowing at strength 2, ` Breeze set` with the fan off). | ECB 3 |
| BZ2 | **The fan tile cannot show Breeze** (the fan proxy has no mode, preset mode or custom control; verified on every fan-proxy page). The Navigators get a **companion switch**: a new package `modernforms_breeze.c4z` with one on/off `light_v2` proxy, added by the action **Add Breeze Switch** on the fan item, bound to the fan device, lit while Breeze blows, one tap toggles. The installed fan device is updated in place; nothing is re-created and nothing needs a controller reboot. | owner; ECB 1, 3.2 |
| BZ3 | **Programming**: commands `Breeze On`, `Breeze Off`, `Toggle Breeze`, `Set Breeze Strength` (`STRENGTH` 1, 2, 3); a read-only `Breeze` variable (added second, after `Online`; seeded from the persisted `mf_breeze` so a restart fires nothing); events `Breeze Started` (id 4) and `Breeze Stopped` (id 5); condition `BOOL_BREEZE` "Breeze is on" (id 1). Never renamed, retyped or removed later. | ECB 3.1, BC22, BC26 |
| BZ4 | **Keypads**: Button Link **311** "Fan Breeze Button Link", handled like Fan Toggle (307): a push toggles, a click acts only without a push in the last 10 s, a release does nothing; its LED shows Breeze (the shown value), in the keypad's own colours. `Keypad Links` counts 13 links. | ECB 3.1, BC11, BC13, BC27 |
| BZ5 | **The tests on the house were skipped** (owner, 2026-11-07: "make a best guess on what the test would reveal and move on"). The design takes these as ASSUMED and works whatever the fan does, because the driver reports what the fan answers: (a) `fanSpeed` reports the set speed during gusts, and the driver guards anyway (BZ8); (b) `{"wind":true}` alone does not start a fan that is off, so Breeze On from off is two requests; (c) Off keeps `wind` set and the next start resumes Breeze; (d) a speed command keeps Breeze and sets its base speed; (e) a strength alone does not start Breeze; (f) the direction reads forward during Breeze and returns after. | owner; BRR 6 |
| BZ6 | **Breeze On while the fan is off** turns the fan on at the fan proxy's preset speed first, then sends `{"wind":true}` (two requests, the fan first, 250 ms apart, the model's one-group-per-request rule). | BC9; BZ5 (b) |
| BZ7 | **No hidden `wind:false`**: a speed command, Off, Toggle or Cycle sends only its own fields; whatever the answer shows about `wind` is reported. | BC6, BC7 |
| BZ8 | **The gust guard**: while the confirmed `wind` is true, a read whose only change is `fanSpeed` is not told to the proxy or the links, is not "outside", and opens no fast window (logged at debug); the speed is told again from the first read after `wind` goes false. A speed Control4 commands during Breeze is sent and reported from its own answer. | BRR 5 item 1; BC23 |
| BZ9 | **Attribution**: an answer counts as "command" for every group it changed, not only the group that was sent (a Breeze command that starts the fan or turns it forward is not "outside"). | BRR 5 items 2, 3 |
| BZ10 | **Fans without Breeze** (no `wind` key: Gen 1/2, Gen 3 without the hardware): nothing about Breeze is sent; the commands and the 311 press are refused with a Last Action line; the variable stays 0; Add Breeze Switch is refused; a companion shows offline. The commands stay listed (XML is the same for every device). | BC15, BC16 |
| BZ11 | **The companion is added only on the click** (never at load, an update, a contact or because Breeze was seen), into the fan item's room, named once after the fan item plus " Breeze", never renamed by either driver; refused without a pin, without Breeze, or while one is already bound. | BC28, BC32 |
| BZ12 | **Fans without a light kit and every other existing behaviour are unchanged**; nothing new persists except `mf_breeze`. | — |

## 2. The fan's side: model and wire (piece A)

- **A fourth command group `breeze`** after `fan` and `direction` (`GROUPS =
  { "fan", "direction", "breeze", "light" }` or `"light"` before it, as the
  model's request order needs; `fan` must go before `breeze`): fields
  `wind` (boolean) and `wind_speed` (integer 1 to 3), moved from the
  read-only rows to the fields (`FIELDS`, `GROUP_FIELDS`, `FIELD_NAME`:
  `wind = "breeze"`, `wind_speed = "breeze strength"`).
- **`model:want(fields)`** accepts `wind` and `wind_speed` like the other
  fields; `validate` refuses them with a new reason `no_breeze` while
  `has_wind` is not true, and `wind_speed` outside 1 to 3 with
  `breeze_range`. `{ fan_on = true, speed = P, wind = true }` plans two
  requests, `fan` then `breeze`.
- **`wire.body`** builds exactly `{"wind":true}`, `{"wind":false}`,
  `{"windSpeed":N}` and `{"wind":true,"windSpeed":N}` (numbers, never a
  string) for the `breeze` group, and refuses anything else; **`wire.state`**
  reads `windSpeed` with the range handling the speed has (1 to 3).
- **Settle and held values** work per field as today.
- **BZ8, the gust guard**, and **BZ9, the attribution**, in `reconcile` and
  `apply_answer`.
- **Events**: `settled("breeze", st, why)` and `idle("breeze", st)` like the
  other groups; `shown()` includes `wind` and `wind_speed` (wanted over in
  flight over confirmed, V10), so a target shows at once.
- `has_wind`, `mf_wind` and Fan Model's `, Breeze` are unchanged.

## 3. The Control4 face in the fan driver: `fan/breeze.lua` (new; piece B)

```lua
local breeze = require("fan.breeze")
local b = breeze.new({
	model = model,                      -- want(fields) -> ok, why; shown(); confirmed(); info(); phase(); identity()
	preset = fn() -> 1..6,              -- the fan proxy's preset speed (BZ6)
	set_variable = fn(value),           -- "1" | "0": C4:SetVariable("Breeze", value)
	fire = fn(event_id),                -- C4:FireEventByID: 4 Breeze Started, 5 Breeze Stopped
	persist = fn(key, value), recall = fn(key) -> value,   -- "mf_breeze"
	result = fn(key, args),             -- a Last Action line (texts.result keys of section 5)
	companions = fn() -> { device_id, ... },   -- the bound consumers of binding 400
	send = fn(device_id, command, params),     -- C4:SendToDevice
	add_device = fn(name, cb(device_id or nil, err)),   -- C4:AddDevice("modernforms_breeze.c4z", the fan item's room, name, cb)
	bind = fn(device_id) -> ok,         -- C4:Bind(this device, 400, device_id, 1, "MODERNFORMS_BREEZE")
	item_name = fn() -> string,         -- the fan item's display name (the companion's name)
	log = log,
})
b:command(name, params) -> handled     -- "Breeze_On" | "Breeze_Off" | "Toggle_Breeze" | "Set_Breeze_Strength" (STRENGTH)
b:toggle()                             -- link 311's press: from the shown value (BC11)
b:blows_shown() -> bool                -- for link 311's LED: shown wind and shown fan_on
b:settled(group, st, why)              -- from the model ("fan" and "breeze"): variable, events, mf_breeze, companions
b:shown(shown)                         -- from the model: the companions' tile target at once (BC12)
b:phase(phase)                         -- availability for the companions (offline, unset, foreign, gen4, notfan)
b:test_condition(name, params) -> bool | nil   -- BOOL_BREEZE ("VALUE" and "LOGIC" as BOOL_ONLINE); nil for other names
b:companion(command, params)           -- MF_BREEZE_SET (ON "1" | "0"), MF_BREEZE_TOGGLE, MF_BREEZE_HELLO
b:binding_changed(bound)               -- binding 400: send the state to every companion
b:add_switch()                         -- the action Add Breeze Switch (BZ11)
b:late_init()                          -- the state to the companions; the variable is seeded by driver.lua
b:stop()
breeze.EVENT_STARTED, breeze.EVENT_STOPPED, breeze.CONDITION   -- 4, 5, "BOOL_BREEZE"
```

- **Commands**: `Breeze_On` → `want({ wind = true })`, or, with the fan off
  (shown `fan_on` false), `want({ fan_on = true, speed = preset(), wind =
  true })`; `Breeze_Off` → `want({ wind = false })`; `Toggle_Breeze` →
  blowing (shown) ? off : on; `Set_Breeze_Strength` → `want({ wind_speed =
  N })` with N from `STRENGTH` ("1" to "3"; anything else refused with
  L34). Refusals from `want` map to Last Action (section 5); success writes
  nothing (as every proxy command).
- **Changes**: on every `settled` of `fan` or `breeze`, compute blows from
  the confirmed state; on a change: `set_variable`, `persist("mf_breeze")`,
  fire 4 or 5 once, send the state to every companion. The first contact
  after a restart fires an event only when it differs from `mf_breeze`
  (BC22). Offline keeps the last value (BC20).
- **Companion messages** (section 4): the state after every change, on
  `binding_changed`, on `MF_BREEZE_HELLO` and at `late_init`;
  `MF_BREEZE_SET` and `MF_BREEZE_TOGGLE` run the same paths as the commands
  (refusals write Last Action).
- **Add Breeze Switch**: refused without a pin (L39), without Breeze (L38),
  or with a companion already bound (L37, naming it); otherwise
  `add_device(item_name() .. " Breeze" (cut to 30 characters), cb)`, then
  `bind`, then L36; a failure of either writes L40.

## 4. The companion `modernforms_breeze.c4z` (new package; piece D)

- **`src/modernforms_breeze/driver.xml`**: one `light_v2` proxy (binding
  5001, "Modern Forms Breeze"), `dimmer` False, `on_off` True, no LEDs, no
  Button Links of its own, its own icons (small and large, drawn by
  `tools/make_icons.py`: a stylised gust, original art); a consumer control
  binding id 1, class `MODERNFORMS_BREEZE`; properties `Driver Version`,
  `Status`, `Debug Mode`; no actions; the minimum OS of the fan driver.
- **Messages** with `C4:SendToDevice` (they land in `ExecuteCommand`):
  - fan → companion `MF_BREEZE_STATE` `{ BLOWS = "1" | "0", AVAILABLE = "1"
    | "0", FAN = <fan item name> }` (AVAILABLE is "0" without Breeze or while
    the fan device's phase is not online, waiting or rebooting);
  - companion → fan (its provider, `C4:GetBoundProviderDevice(own id, 1)`):
    `MF_BREEZE_SET` `{ ON = "1" | "0" }`, `MF_BREEZE_TOGGLE` `{}`,
    `MF_BREEZE_HELLO` `{}` (at late init and on its binding's change).
- **The tile**: `ON`, `TOGGLE` from off, any level above 0 → `MF_BREEZE_SET
  ON=1`; `OFF`, level 0 → `ON=0`; `TOGGLE` from on → `ON=0`. It reports
  `LIGHT_BRIGHTNESS_CHANGED` 100 while BLOWS is "1", 0 otherwise, only from
  a state message (the fan confirms; no optimistic report); online false
  while unbound or AVAILABLE is "0". Built on `src/common/device.lua`'s
  light_v2 plumbing as far as it fits (it is the owner's own Apache-2.0
  code, shared with the Hue project).
- **Status**: `Breeze on Aviator 5` / `Breeze off on Aviator 5` / `Aviator 5
  has no Breeze` / `Waiting for Aviator 5` / `Not connected to a Modern
  Forms Fan`.
- **Documentation tab**: what it is, how to add it (the fan's action), what
  a tap does, that off ends Breeze while the fan keeps turning, to keep it
  out of "all lights on" groups.

## 5. Texts (`fan/texts.lua`; piece C)

| Id | When | Text |
| --- | --- | --- |
| S5 | online | ` Breeze 2` after the speed while blowing (strength), ` Breeze set` while `wind` is true and the fan is off (today ` Breeze`) |
| L33 | a Breeze command or press, no Breeze | `Breeze not available: this fan reports no Breeze` |
| L34 | strength not 1 to 3 | `Breeze strength 5 refused: use 1, 2 or 3` |
| L35 | a Breeze command refused for another reason | the refusal line every proxy command already writes for that reason, with "Breeze" as the command (reuse the existing keys; add one only if none fits) |
| L36 | Add Breeze Switch, done | `Breeze switch added: Aviator 5 Breeze` |
| L37 | Add Breeze Switch, one already bound | `A Breeze switch is already connected: Aviator 5 Breeze` |
| L38 | Add Breeze Switch, no Breeze | `No Breeze switch added: this fan reports no Breeze` |
| L39 | Add Breeze Switch, no fan set up | `No Breeze switch added: set up the fan first` |
| L40 | Add Breeze Switch, Composer refused | `No Breeze switch added: install modernforms_breeze.c4z first` |
| list | Keypad Links | `N of 13 links bound`; the row `Fan Breeze: Example Keypad (456)` |

Every text at most 70 characters with the placeholders.

## 6. Keypad link 311 (`fan/links.lua`; piece C)

`links.LINKS[311] = "Fan Breeze Button Link"` (row name `Fan Breeze`), the
13th link; its press calls `opts.breeze_toggle()` (push acts, click only
without a push in 10 s, release nothing, as 307); its LED is
`opts.breeze_blows()` on every `links:shown(...)`, sent with
`MATCH_LED_STATE` only (no `BUTTON_COLORS`); `REQUEST_BUTTON_COLORS` and a
fresh binding are answered at once as for 300 to 308; Keypad Links' total is
13.

## 7. The fan driver's XML and wiring (the coordinator)

`driver.xml`: the four commands (with `STRENGTH` 1, 2, 3), events 4 and 5,
the condition `BOOL_BREEZE` (id 1), connections 311 (as 307) and 400
(provider control binding, class `MODERNFORMS_BREEZE`, "Breeze Switch"),
the action **Add Breeze Switch** (sort order 7). `driver.lua`: the `Breeze`
variable after `Online` in `OnDriverInit` from `mf_breeze`; build `breeze`;
forward `settled`, `shown`, `phase`, the commands, `MF_BREEZE_*` from
`ExecuteCommand`, `TestCondition`, binding 400's changes; links get
`breeze_toggle` and `breeze_blows`; `OnDriverDestroyed` stops it.
`fan/devcmds.lua`'s `Dev Request` accepts the four Breeze bodies (they pass
`wire.body`). `deploy/house.yaml` and the release carry both packages.

## 8. Tests

Each piece's spec covers its section; `fan_driver_spec` (coordinator) runs
the commands end to end on the fake (Breeze On while running and while off,
Off, Toggle, Strength, the variable and the events once per change, no
event at a restart with `mf_breeze` equal, the condition, the gust guard
through the driver, link 311's press and LED, Add Breeze Switch with the
fake's AddDevice and Bind, the companion messages, a fan without Breeze);
`breeze_driver_spec` (piece D) runs the companion on the fake.

## 9. On the house (after the release install; Windows session)

1. Install both packages in place (no reboot). 2. Read back the fan's
`Driver Version` and that programming lists the four commands, two events,
the condition and the variable. 3. Click **Add Breeze Switch**; read Last
Action, the new item in the fan's room and the binding on 400. 4. File ▸
Refresh Navigators. The owner then sees the switch on the phone and a
touchscreen, and can tap it.

## 10. Pieces and owner files

| Piece | Owns (creates or edits only these) |
| --- | --- |
| A model and wire | `src/modernforms_fan/fan/model.lua`, `src/modernforms_fan/fan/wire.lua`, `tests/spec/model_spec.lua`, `tests/spec/wire_spec.lua` |
| B Breeze face | `src/modernforms_fan/fan/breeze.lua`, `tests/spec/breeze_spec.lua` |
| C links and texts | `src/modernforms_fan/fan/links.lua`, `src/modernforms_fan/fan/texts.lua`, `tests/spec/links_spec.lua`, `tests/spec/texts_spec.lua` |
| D companion | `src/modernforms_breeze/` (all), `tests/spec/breeze_driver_spec.lua`, `tools/make_icons.py`, `tools/tests/test_make_icons.py` |
| E documents | `src/modernforms_fan/www/documentation.html`, `docs/composer-checklist.md`, `README.md`, `docs/v1-design.md`, `docs/README.md`, `docs/release-checklist.md`, `.github/release-notes.md`, `.github/prerelease-notes.md`, `CHANGELOG.md` (`## Unreleased` only) |
| Coordinator | `src/modernforms_fan/driver.lua`, `src/modernforms_fan/driver.xml`, `src/modernforms_fan/fan/devcmds.lua`, `tests/spec/devcmds_spec.lua`, `tests/spec/fan_driver_spec.lua`, `tests/helpers/fake_c4.lua`, `tools/build.sh`, `deploy/house.yaml`, this contract, `docs/status.md`, `CLAUDE.md` |

A piece that needs a change in a file it does not own writes the exact change
into its hand-back.
