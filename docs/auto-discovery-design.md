# Finding fans by itself (#102)

> **Status (2026-11-13, #213).** Shipped in 1.2 "Thumper" and unchanged
> since: the code follows this contract. One count changed in the same
> release: 1.2 also added the action Add Breeze Switch (#111, renamed Add
> Breeze Fan in 1.3), so the Actions tab has six actions, not the five of
> check H1 (section 9).

The contract for issue [#102](https://github.com/corytron/c4-modernforms-driver/issues/102):
the owner asked (2026-11-07) that fan discovery run by itself at driver load
and periodically, as the Hue driver's bridge detection does, and that the
**Find Fans** action go. It rests on two research notes:
[`edge-cases-discovery.md`](edge-cases-discovery.md) (EDC: 56 lifecycle cases
on both sides) and [`auto-discovery-research.md`](auto-discovery-research.md)
(ADR: the Hue lessons, what exists here, the mechanism). Where this file and
they differ, this file wins; where it is silent, ADR section 4 is the rule,
then EDC section 4.

## 1. Decisions

| # | Decision | Basis |
| --- | --- | --- |
| AD1 | **The driver keeps `Found Fans` current by itself**, with the same multicast DNS question as today (V5a, K10), at every load and on the schedule of section 2. It writes the list and the log, **never Last Action**, and never pins, reads, renames or adopts a listed fan, never fills `Fan Address`, never scans a subnet, never asks the internet. | the owner's request; ADR 2.3 (the Hue rule); V5; CLAUDE.md |
| AD2 | **The Find Fans action and its command go**, with no hidden alias in release builds and **no "Search again" row** (owner, 2026-11-07). Dev builds get the signed command `Dev Search` for house checks. | owner; ADR 4.4, Q6 |
| AD3 | **A pick in `Found Fans` takes that fan at once** (owner, 2026-11-07), through the same path as Use Selected Fan, with the same results, `Fan Address` write and guarded rename. **Exception:** a pick of a different fan on a device already pinned reads nothing and waits for Use Selected Fan (L32). | owner; ADR 4.3.6 (B with the guard) |
| AD4 | **A pinned device whose fan answers searches only at load** (owner, 2026-11-07). While the follower is armed its windows feed the list; no second schedule runs. | owner; ADR 4.1 |
| AD5 | **An empty `Fan Address` on a pinned device is the stop switch**: no window at all, not even at load (as V29/F5 for the follower). | EDC 4.2; AFD F5 |
| AD6 | **One list, fed by every window** whoever opened it (the scheduler's or the follower's), keyed by fan (MAC), kept across windows until it misses three that sent their query. The follower still never acts on the list, the pick or another fan. | ADR 4.2; EDC 4.3 |
| AD7 | **No automatic read of listed fans**: other fans' rows carry what the answer says (instance and address), no product name. | EDC 5.8; ADR 4.3.2 |
| AD8 | **No "used by another device" mark** in this build (it needs a cross-device exchange; a later issue). | owner default; ADR 4.3.2, Q5 |
| AD9 | **Nothing new that is forever**: no variable, event, programming command, connection or capability, nothing new persisted; no controller reboot for the update. | EDC 5.7 |
| AD10 | V5a ("never writes `Found Fans`"), AFD F8 and ECA CA5 change to: the list shows what every window heard; the follower never acts on the list or the pick. | ADR 4.2 |

## 2. Modes and the schedule (`fan/search.lua`)

The scheduler asks `mode()` whenever it plans. `driver.lua` answers, in this
order:

| Mode | When | Windows of its own |
| --- | --- | --- |
| `stopped` | a fan is pinned and `Fan Address` is empty | none, not even at load |
| `standby` | the follower is armed (`follower:state()` starts with `armed`) | none: the follower's windows feed the list |
| `seek` | no fan is pinned; or a fan is pinned and `Fan Address` is not a usable address (phase `unset`) | the ladder below |
| `quiet` | otherwise: a fan is pinned and its address is set (the fan answers, or it is away with the follower not armed: Follow Address Changes Off keeps meaning "no windows" (F7), a typed address waits for its answer (F5), a pin without a MAC) | none after the load window |

- **The load window.** `start()` (end of `OnDriverLateInit`, so after every
  load, update in place, Director restart or dev-loop reload) plans one
  window at `FIRST_MS` (3000) + slot + jitter, unless the mode is `stopped`
  or `standby` then. The slot is `(device id mod SLOTS) * SLOT_MS` (8, 3500,
  as the follower's); the jitter is 0 to `JITTER_MS` (500). The device id
  comes through `seed()` at the first plan, never at load.
- **The seek ladder.** In `seek`, after the load window (or after entering
  `seek` later), the next windows open `SEEK_MS` = 30 s, 1, 2, 5, 10 min
  after the previous window closed, then every `SEEK_EVERY_MS` = 15 min; each
  step ±`SPREAD` (20 %). Entering `seek` again restarts the ladder.
- **The floor.** No window of the scheduler opens less than `MIN_GAP_MS`
  (30 s) after **any** window of this device closed (`last_closed()`); a due
  window waits for the floor. A window already open is joined by `find`, not
  doubled.
- **`changed()`** re-plans when the mode may have changed (the driver calls
  it on every phase change, after the follower reacted, after Fan Address
  changes and after every pick or Use Selected Fan outcome). Leaving `seek`
  cancels its pending window; `quiet`, `standby` and `stopped` plan nothing.
- **`poke(why)`** opens one window as soon as the floor allows, in any mode
  but `stopped`: `"stale"` (a pick or Use Selected Fan answered `not_picked`
  or `no_answer`), `"dev"` (Dev Search).
- **Randomness**: a Park–Miller generator of its own, seeded from the device
  id and the clock at the first plan (LuaJIT seeds every Lua state alike;
  the follower's note). Tests pass `random`.
- **Budget**: `seek` about 100 windows a day (the follower's accepted budget,
  ECA 3.3), `quiet` one per load, `standby` and `stopped` none of their own.
  Nothing is persisted: a load starts afresh.
- **Failures**: a window that could not open or send is logged as a warning
  once per streak by the list (section 3); the cadence continues.

## 3. The list (`fan/found.lua`) and its rows

- **Fed by every closed window** (`Finder`'s `on_window(list, err, heard)`,
  whoever opened it): `found:window(heard, err)`.
- **Keyed by fan**: the 12-hex MAC of the entry (lower case), or, with no
  MAC, `"i:" .. lower(instance)`. Each key keeps its instance, MAC and the
  address of its **latest** answer, and when it was last heard.
- **Usable entries only**: the driver passes `usable(entry)` (discovery's:
  SRV port 80, a private or link-local IPv4 address); others are ignored.
- **Ageing**: a key is removed after `MISSES` (3) windows in a row **that
  sent their query** without hearing it. A window with `err` set ages nothing
  and marks the list `failing()` until a window sends again. The kept pick's
  key (section 4) never ages out while it is kept.
- **Order**: this device's fan (the pinned MAC) first, then by instance
  (case-blind), then by address; stable from window to window.
- **Size**: at most `texts.MAX_FOUND` (16) item rows; with more fans the
  16th item row reads `... and 3 more: enter the address in Fan Address`.
- **The row is written only when its text changed** (summary or items, as
  `texts.found_rows` returns them), so an owner choosing in Composer is not
  disturbed by a window that heard the same fans. The write is
  `C4:UpdatePropertyList(name, items_with_summary_first, value)` and
  `C4:UpdateProperty(name, value)`, value = the kept pick's label, else the
  summary.
- **Log**: when the set of keys or an address changes, `log.always`:
  `Found Fans: 2 fans (...5301 at 10.0.2.151, ...5302 at 10.0.2.152)` (the
  last four MAC digits), or `Found Fans: no fan answered`; a failing streak's
  first window: `log.warn` `Search: the query could not be sent on this
  controller`. Debug Mode keeps the Finder's per-window tally.

### 3.1 The summary (the first item, and the value when no pick waits)

| State | Text |
| --- | --- |
| from load until this run's first window closed | `Looking for Modern Forms fans on the network...` |
| the last window could not open or send | `No search possible on this controller: enter Fan Address` |
| unpinned, one or more fans | `2 fans found: pick one and click Set to use it` (`1 fan found: pick it and click Set to use it`) |
| unpinned, none | `No fan found yet: enter its address in Fan Address` |
| pinned, its fan heard, alone | `This device's fan answered; no other fan found` |
| pinned, its fan heard, others too | `3 fans found; this device's fan is listed first` |
| pinned, its fan not heard | `2 fans found; this device's fan did not answer` (`1 fan found; ...`) |
| pinned, none heard | `No fan answered the last search` |
| stopped | `Not searching while Fan Address is empty` |

### 3.2 An item

`<instance> at <address>`, the instance cut at its start to 25 characters
when longer (so its last six MAC digits stay), plus, for the pinned MAC,
` (this device: Aviator 5)` when `fan/names.lua` knows the stored
`fanType`, else ` (this device's fan)`. An instance without the last six MAC
digits (an unknown layout) gets ` ...5302` from the TXT MAC. Commas go
through `texts.list_item`. Every item stays at or under 72 characters (the
product name is left out when it would pass).

## 4. The pick and Use Selected Fan (`driver.lua`)

`dispatch.properties["Found_Fans"]` (OnPropertyChanged, after Set):

1. Ignored before `started` (the late-init replay) and for any value that is
   not an item row of the list as last written; the summary and the overflow
   row do nothing (the row is written back to its value).
2. An item, unpinned device: **act at once**: `follower:clicked()`, then
   `model:use_fan(entry.address, entry.mac, cb)`; `cb` does exactly what Use
   Selected Fan's does today (the result line, `Fan Address` on `moved` and
   `now_using`, the guarded rename and its suffix). The row snaps back to the
   summary.
3. An item whose MAC is the pinned fan's: **act at once** the same way (L4
   `already`, or L2 `moved` at another address).
4. An item of a **different** fan on a pinned device: **read nothing**. The
   pick is kept (`found:keep(key)`), the row keeps showing it (its current
   label, also after rewrites and a new address), and Last Action writes L32.
   A later pick replaces it; the summary clears it.
5. Use Selected Fan: the kept pick if any (`use_fan(address, mac)` at its
   latest address), else `Fan Address`, as today. After every outcome the
   kept pick is cleared and the row snaps back to the summary.
6. `not_picked` (L21) and `no_answer` (L5) after a pick or Use Selected Fan
   poke one window (`"stale"`).

## 5. Texts (`fan/texts.lua`)

| Id | Change |
| --- | --- |
| S1 | unchanged; now used for an unset device whose list is failing |
| S2 | `Not set up: pick a fan in Found Fans, or enter Fan Address` (replaces `Not set up: Find Fans, or ...`); `view.find_fans` goes, the view gains `failing` (S1 against S2) |
| L7 | unchanged: `Nothing to use: pick a fan in Found Fans, or enter Fan Address` (no `find_fans` field any more) |
| L8, L9, L10 | removed with the action |
| L21 | `The fan at 10.0.2.151 is not the one picked; searching again` |
| L32 (new, `picked_wait`) | `Picked MF_Fan_005302: click Use Selected Fan to switch to it` (the instance cut at its start so the line stays at or under 70) |
| list | `texts.found_rows(view) -> summary, items` replaces `texts.found_fans`; section 3 |

Every new text is verbatim in `texts_spec` and at most 70 characters with a
15-character address and a 25-character instance (items: 72).

## 6. Modules

### 6.1 `fan/search.lua` (new, pure; piece A)

```lua
local search = require("fan.search")
local s = search.new({
	find = fn(cb(list, err, heard)),        -- discovery Finder:find (joins an open window)
	last_closed = fn() -> ms or nil,        -- Finder:last_closed(): any window's close
	mode = fn() -> "seek" | "quiet" | "standby" | "stopped",
	timer = fn(ms, cb) -> handle with :Cancel(),
	now = fn() -> ms,
	seed = fn() -> number,                  -- the device id, read at the first plan
	random = fn() -> 0 <= x < 1,            -- tests; else Park-Miller of its own
	log = log,
})
s:start()          -- the load window (section 2); a second start after stop() is a fresh run
s:changed()        -- re-plan for the current mode
s:poke(why)        -- "stale" | "dev": one window as soon as the floor allows (not in "stopped")
s:state() -> "off" | "stopped" | "standby" | "quiet" | "due:<s>" | "open"   -- Dev State's search=
s:stop()           -- cancels every timer; no callback afterwards
search.FIRST_MS, SLOTS, SLOT_MS, JITTER_MS, SEEK_MS (table), SEEK_EVERY_MS, SPREAD, MIN_GAP_MS
```

Every option is called through `pcall`; nothing raises; `new` arms nothing.
The scheduler never parses answers: `find`'s callback only notes the window's
end (the list is fed through `on_window`).

### 6.2 `fan/found.lua` (new, pure; piece B)

```lua
local found = require("fan.found")
local l = found.new({ usable = fn(entry) -> bool, now = fn() -> s, log = log, misses = 3 })
l:window(heard, err) -> changed          -- every closed window; err set: ages nothing, failing() true
l:entries(pin_mac) -> { { key, instance, address, mac, own } ... }   -- section 3's order, all of them
l:failing() -> bool
l:heard_once() -> bool                   -- a window has closed in this run (the "Looking..." summary)
l:get(key) -> entry or nil
l:keep(key) / l:kept() -> entry or nil / l:drop()   -- the waiting pick (section 4), by key
l:clear()
found.key(entry) -> key or nil           -- lower-case MAC12, else "i:" .. lower(instance)
```

The log lines of section 3 are written by `window`.

### 6.3 `fan/discovery.lua` (changed; piece D)

- `discovery.new(opts)` takes two more options: `now = fn() -> ms` and
  `on_window = fn(list, err, heard)`, called once after each window closes
  and after its callbacks, **whoever opened it**, inside `pcall`, never after
  `stop()`.
- `Finder:last_closed() -> ms or nil` (from `now`; nil before any window).
- `discovery.usable(entry) -> bool`: SRV port 80 and a private or link-local
  IPv4 address (the filter `candidates` already applies, exported).
- Log prefix `Search:` instead of `Find Fans:`; the header comment describes
  the scheduler's and the follower's windows. Query, parse, candidates,
  joining and `stop` are unchanged.

### 6.4 `fan/texts.lua` (changed; piece C)

Section 5; `texts.found_rows(view)` takes `{ state = "looking" | "failing" |
"stopped" | "listed", pinned = bool, entries = found:entries(...), info =
model:info() or nil }` and returns the summary (section 3.1) and the item rows
(section 3.2, with the overflow row). `texts.found_fans` and the `find_fans`
fields go. `RESULTS.picked_wait(f)` reads `f.instance`.

### 6.5 `driver.lua`, `driver.xml`, `fan/devcmds.lua` (the coordinator)

- `driver.xml`: the Find Fans action goes (the other actions keep their
  `sort_order`); the `Found Fans` comment says the list fills by itself.
- `driver.lua`: build `found` and `search` after the Finder and the follower;
  `on_window` feeds `found:window` and redraws `Found Fans` on change; `mode()`
  from `model:identity()`, the typed `Fan Address`, `model:phase()` and
  `follower:state()`; `search:changed()` where section 2 says;
  `search:start()` at the end of `OnDriverLateInit`, after the model and the
  follower; the `Found_Fans` handler and Use Selected Fan as section 4; the
  `Find_Fans` command and `PICK_ROW`/`picked_fan` go; `refresh_status` passes
  `failing` instead of `find_fans`; `OnDriverDestroyed` stops `search` before
  the Finder.
- `fan/devcmds.lua`: Dev State gains `search=`; `Dev Search` pokes `"dev"`
  and reports the window's tally (dev builds only, signed as every dev
  command).

## 7. Documents (piece E)

The manual (`src/modernforms_fan/www/documentation.html`: chapter 3's Find
Fans section becomes "Found Fans" — the driver looks by itself at load and
on a schedule, what a pick does, that a pinned device asks only at load, that
the list and the address follow use the same question, that it never takes a
fan by itself; the setup steps, Status and Properties and Actions tables, the
troubleshooting row, the network and privacy paragraphs),
[`composer-checklist.md`](composer-checklist.md) (the steps that name Find
Fans or S2; the action list of five; the checks of section 9),
[`README.md`](../README.md), [`SECURITY.md`](../SECURITY.md) (the question is
asked by itself), [`v1-design.md`](v1-design.md) (V5, V5a, a decision V30
pointing here, 2.5 row 5, 2.6, 7.1, 7.2, 7.3, 9.1, 9.10, 14),
[`address-follow-design.md`](address-follow-design.md) (F8 as AD10),
[`docs/README.md`](README.md) (the index: this contract and both research
notes; none of them goes on the front page) and `CHANGELOG.md` (`##
Unreleased`, #102). The coordinator writes `CLAUDE.md`'s scope line and
`docs/status.md`.

## 8. Tests

- `search_spec`: the load window's bounds per slot; none in `stopped` and
  `standby` at start; the seek ladder and its ±20 % bounds; restart of the
  ladder on re-entering `seek`; nothing in `quiet` after the load window; the
  floor after any window (a follower window too); `poke` under the floor and
  not in `stopped`; a join instead of a double window; `stop` leaves no timer;
  a fresh `start` after `stop`; a simulated week counting windows per mode.
- `found_spec`: keying (MAC, instance), latest address, ageing after three
  sending windows, failed windows age nothing, the order and own-first, the
  kept pick across windows and a new address, never aged while kept,
  unusable entries ignored, the log lines once per change.
- `discovery_spec`: `on_window` once per window for a window opened by either
  caller and joined by both, after the callbacks, never after `stop`;
  `last_closed`; `usable`; the `Search:` prefix.
- `texts_spec`: every text of sections 3 and 5 verbatim, lengths, the
  overflow row, the instance cut, the product-name mark.
- `fan_driver_spec` (coordinator): no Find Fans in the action order; a query
  on 6001 at 3 s plus the slot after late init; answers fill `Found Fans`,
  this device's fan first; Last Action untouched by automatic windows; a pick
  on an unpinned device pins it (L3, `Fan Address`); a pick of the own fan
  (L4); a pick of another fan on a pinned device waits (L32), survives a
  rewrite, and Use Selected Fan switches; no scheduler windows while the
  follower is armed; the follow still works; an empty `Fan Address` on a
  pinned device sends nothing; `OnDriverDestroyed` leaves no timer; a second
  late init starts again.

## 9. Checks on the house (each under a minute)

| # | Check | Expect |
| --- | --- | --- |
| H1 | After the install in place, the Actions tab | five actions, Use Selected Fan first; no Find Fans |
| H2 | `Found Fans` and `Last Action` 40 s after the install, no click | summary `This device's fan answered; no other fan found` and the item `MF_Fan_005301 at 10.0.2.151 (this device: Aviator 5)`; Last Action unchanged by the search |
| H3 | Pick the house fan's item, Set | L4 `Already using fan ...`; the row back on the summary; nothing else changes |

Parked (only time shows them): the `seek` cadence over hours, an open Composer
drop-down while the list changes, an OS 4.x controller, a second device of
this driver on the house.

## 10. Pieces and owner files

| Piece | Owns (creates or edits only these) |
| --- | --- |
| A scheduler | `src/modernforms_fan/fan/search.lua`, `tests/spec/search_spec.lua` |
| B list | `src/modernforms_fan/fan/found.lua`, `tests/spec/found_spec.lua` |
| C texts | `src/modernforms_fan/fan/texts.lua`, `tests/spec/texts_spec.lua` |
| D Finder | `src/modernforms_fan/fan/discovery.lua`, `tests/spec/discovery_spec.lua` |
| E documents | `src/modernforms_fan/www/documentation.html`, `docs/composer-checklist.md`, `README.md`, `SECURITY.md`, `docs/v1-design.md`, `docs/address-follow-design.md`, `docs/README.md`, `CHANGELOG.md` (`## Unreleased` only) |
| Coordinator | `src/modernforms_fan/driver.lua`, `src/modernforms_fan/driver.xml`, `src/modernforms_fan/fan/devcmds.lua`, `tests/spec/devcmds_spec.lua`, `tests/spec/fan_driver_spec.lua`, `tests/helpers/fake_c4.lua`, this contract, `docs/status.md`, `CLAUDE.md` |

A piece that needs a change in a file it does not own writes the exact change
into its hand-back.
