# The fan's product name and naming the items after it (#37)

The contract for issue [#37](https://github.com/corytron/c4-modernforms-driver/issues/37):
the owner asked (2026-11-04) that the driver work out the fan's marketing name
from its model information, show it in Properties, and use it to rename the
device in Composer once the fan is selected. It rests on two research notes:
[`fan-names-research.md`](fan-names-research.md) (FNR: `fanType` and the name
table) and [`edge-cases-rename.md`](edge-cases-rename.md) (ECR: the lifecycle
cases, the guard, the job, the texts). Where this file and they differ, this
file wins; where this file is silent, ECR's section 5 is the rule.

## 1. Decisions

| # | Decision | Basis |
| --- | --- | --- |
| N1 | **Exact lookup only.** `fanType` (trimmed) is looked up in a table shipped with the driver; no prefix, family-number or fuzzy match, no guess. An unknown `fanType` shows today's text and renames nothing. | FNR §7; ECR RC24 |
| N2 | **The name form is the maker's family name**, ASCII, no brand, no size unless the maker's name has one, no inch sign: the house's `1811-5-54` is `Aviator 5`; the light item is `<Name> Light`. | FNR §7, §8 item 1 (default: `Aviator 5`, not `Aviator 5 Fan`) |
| N3 | **Shown in Properties** in the `Fan Model` row: `Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30, Breeze`; unknown: `Gen 3, fan 1811-5-54, light kit …` as today. No new row. | FNR §7 |
| N4 | **Use Selected Fan renames, guarded.** When the click leaves a fan pinned (`already`, `moved`, `now_using`), both items are renamed only while both still carry the shipped default names or the names the driver last wrote and confirmed (`mf_names`). A name anyone typed is never overwritten by this path. | ECR 5.1, 5.3; the owner's request; the project's rule that automation must not make a manual fix harder |
| N5 | **Name Items After Fan**, a new action after Use Selected Fan: forced, renames both items whatever they are called, works while the fan is silent (from the stored pin and info), refuses without a pin or a known name, idempotent. It is the way back for every "names kept". | ECR 5.6 |
| N6 | **Nothing else renames**: not the first contact from a typed `Fan Address` (the owner clicks Name Items After Fan), not start-up, late init, an update, a restore, a poll, a new address, a firmware or light-kit change, and never the Modern Forms app's `deviceName`. Duplicates (two fans of one model) get the same name: no suffix, number or room. | ECR 5.1, RC11, F rows |
| N7 | **Both items or neither** in the guarded path; the forced path renames each item whose name differs. The light item is renamed also on a fan without a light kit. | ECR 5.2, 5.3; ECR Q5 (default yes) |
| N8 | **On the house**, the items keep "Fan" and "Fan Light" (named in the cutover): the guard keeps them; the owner may click Name Items After Fan. | ECR Q3 (default keep) |
| N9 | D15 of [`edge-cases-control4.md`](edge-cases-control4.md) changes from "forbidden" to "only on the two clicks, guarded as N4"; U6 and U7 follow. | this contract |

## 2. Modules (section 9 style of [`v1-design.md`](v1-design.md))

### 2.1 `fan/names.lua` (new, pure: no Director)

```lua
local names = require("fan.names")
names.TABLE              -- [fan_type] = name: FNR Appendix B's 75 entries, each with a comment naming its family
names.DEFAULTS           -- { { fan = "Modern Forms Fan", light = "Modern Forms Fan Light" } }: every pair a build shipped
names.valid(name) -> bool          -- ECR 5.4: ASCII letters, digits, space, hyphen; 1 to 22 chars; no leading or
                                   -- trailing blank; not ending in " Light"
names.lookup(fan_type) -> name|nil -- trimmed exact match; nil for nil, "", unknown, or an entry that fails valid()
names.light(name) -> name .. " Light"
```

At load every entry is checked with `valid()`; one that fails is dropped
(fail closed) and the spec checks there are none.

### 2.2 `fan/rename.lua` (new; the job of ECR 5.7)

```lua
local rename = require("fan.rename")
local job = rename.new({
	ids = fn() -> fan_id|nil, light_id|nil,      -- the two proxy ids (driver.lua: the bound consumers of 5001, 5002)
	display_name = fn(id) -> string|nil,        -- C4:GetDeviceDisplayName (API 22_miscellaneous)
	rename = fn(id, name),                      -- C4:RenameDevice (API 22_miscellaneous/_32-RenameDevice.md)
	fan_type = fn() -> string|nil,              -- model:info().fan_type, stored, so known while the fan is silent
	pinned = fn() -> bool,
	lookup = names.lookup, light = names.light, defaults = names.DEFAULTS,
	timer = fn(ms, cb) -> handle,               -- driver.lua's timer (handle:Cancel())
	store = { get = fn(key), set = fn(key, value) },   -- key "mf_names" = { fan, light, at }
	now = fn() -> epoch s,
	log = log,
	confirm_ms = 2000,
})
job:run(mode, done)   -- mode "guarded" | "forced"; done(outcome, args) exactly once
job:plan(mode) -> { outcome, fan_id, light_id, fan_live, light_live, fan_to, light_to }   -- no rename (Dev Names Plan)
job:busy() -> bool
job:stop()            -- cancels the confirm timer (OnDriverDestroyed)
```

Steps: target from `fan_type` and `lookup` (else `no_type` or `no_name`);
ids (else `no_ids`); live names; guarded: both items ours (live name trimmed
equals a default of that item or the `mf_names` record's), else `kept`;
`rename` each item whose live name differs (fan first, each in `pcall`); after
`confirm_ms` read both back, record in `mf_names` only what matches, then
`renamed`, or `unconfirmed` if any differs. Nothing to change: `same` at once.
Forced without a pin: `no_pin`. A run while one is pending: `busy`. The job
never runs inside the click's own call: `run` starts it from a timer of 1 ms
(ECR RC19), so a callback that writes Last Action first is never interleaved.

Outcomes and `args`: `renamed` {fan, light}, `same` {fan, light}, `kept`
{fan_live, fan_to}, `no_name` {fan_type}, `no_type`, `no_ids`, `unconfirmed`,
`no_pin`, `busy`. One `log.always` line per run, as ECR 5.5 (the old names
too, for the forced path).

### 2.3 `fan/texts.lua` (changed)

- `texts.fan_model(pin, info, has_wind)` puts the name in front of the type
  when `names.lookup(info.fan_type)` knows it (N3); texts.lua requires
  `fan.names`.
- `texts.result` gains the keys `name_renamed` (L22), `name_same` (L23),
  `name_unknown` (L24, the type cut to 14 characters), `name_no_type` (L25),
  `name_no_ids` (L26), `name_unconfirmed` (L27), `name_no_pin` (L28),
  `name_busy` (L29), with ECR 5.5's texts and placeholder names.
- `texts.rename_suffix(outcome) -> string`: `renamed` → `; items renamed`,
  `kept` → `; names kept`, `no_name`, `no_type`, `no_ids`, `unconfirmed` →
  `; not renamed`, anything else → `""`. L2, L3 and L4 plus the longest
  suffix stay at or under 70 characters with the placeholders.

### 2.4 `fan/devcmds.lua` (changed, dev builds only)

`Dev Names Plan` (param `MODE` = `guarded` | `forced`, default guarded):
prints `job:plan(mode)` without renaming. devcmds gets the job as `o.names`.

### 2.5 `driver.lua`, `driver.xml` (the coordinator)

- `driver.xml`: action `Name Items After Fan` after Use Selected Fan
  (sort_order 3; the later ones move down one).
- `driver.lua`: the job's options (ids from the bound consumers of 5001 and
  5002, one each, else nil); the action runs `job:run("forced", …)` and writes
  `result("name_" …)`; Use Selected Fan, after its `result(key)` for
  `already`, `moved`, `now_using`, runs `job:run("guarded", …)` and, when
  `rename_suffix` is not empty, writes the same line again with the suffix;
  `OnDriverDestroyed` stops the job; devcmds gets `names = job`.

## 3. Documents (one writer: the docs agent)

ECR 5.8 to 5.10: the manual (`src/modernforms_fan/www/documentation.html`,
chapters 1, 3, 8, 10, 11), [`composer-checklist.md`](composer-checklist.md)
(the Fan Model row and a step for Name Items After Fan),
[`edge-cases-control4.md`](edge-cases-control4.md) (D15, U6, U7),
[`edge-cases-modernforms.md`](edge-cases-modernforms.md) (its rule on names and
the V4 pointer), [`migration-design.md`](migration-design.md) (the cutover's
names and N8), [`v1-design.md`](v1-design.md) (a decision V28 pointing here,
the action in 2.6, the texts in 7, the key `mf_names` in 8, the modules in 9).
The coordinator writes `CHANGELOG.md`, `docs/README.md`'s index and
`docs/status.md`.

## 4. Tests

Specs for `names.lua` (every entry valid, the house's `1811-5-54` →
`Aviator 5`, exact match only, fail closed), `rename.lua` (both modes, the
guard, each outcome, confirm and the record, busy, stop, pcall around
`rename`), `texts.lua` (Fan Model with and without a name, the eight results
and the suffixes, all under 70 characters), `devcmds.lua` (Dev Names Plan),
and `fan_driver_spec.lua` (the action in driver.xml; Use Selected Fan on a
fresh device renames both items; a device someone renamed keeps its names
and Last Action ends in `; names kept`; the action renames it).

## 5. Assumed until the first click on the house

RenameDevice on the fan proxy of a two-proxy device (the Hue project renamed
a single-proxy scene device on OS 3.4, ECR RF facts); the refresh's timing;
whether an open Composer repaints its tree; whether Navigators follow without
File ▸ Refresh Navigators. The house keeps its names unless the owner clicks
the action (N8), so nothing renames by itself on the first install of this
build.
