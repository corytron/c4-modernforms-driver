# Automatic fan discovery: the mechanism (research for #102)

This is the mechanism research for issue
[#102](https://github.com/corytron/c4-modernforms-driver/issues/102). The
owner asked on 2026-11-07 that the driver find fans by itself, at driver load
and periodically, the way the Hue driver finds its bridge, and that the
**Find Fans** action go away. This note says what the Hue driver did and
learned, maps what exists in this driver, and proposes the schedule, the
sharing of the mDNS binding with the address follower, the `Found Fans` list,
the removal of the action and a build split. It is read-only research: no
code or other document was changed. The lifecycle corner cases are a separate
research note (`docs/edge-cases-discovery.md`, written in parallel); where the
two disagree, the contract the coordinator writes decides.

**Status key.** **VERIFIED** names its source: an SDK file, a code file and
function, a Hue issue, commit or Discussion, or a hardware check (K10 and the
others of [`v1-design.md`](v1-design.md#11-hardware-checks-before-the-first-install)).
**ASSUMED** says what would settle it. SDK files are paraphrased, never
quoted. Prefixes: `API/` is
`~/c4-tools/reference/docs-driverworks-api/source/includes/`, `FUND/` the same
for `docs-driverworks-fundamentals`. Hue files are linked on GitHub (their
`main`, at commit `b414a26` when this was read). Placeholders only: fan
`10.0.2.151`, second fan `10.0.2.152`, MAC `00:00:5E:00:53:01`, client id
`MF_00005E005301`, controller `10.0.2.10`.

## 1. Findings

1. **The Hue driver searches at load and every 15 minutes only while it is
   unpaired** (3 s, 1 min, 5 min, then every 15 min). Once paired it does not
   search at all while the bridge answers; it searches for the paired id only
   when the bridge is missing. Automatic searches write the list row and the
   log, never Last Action. A pick in the list acts at once and the row snaps
   back to its summary. (Section 2.)
2. **This driver already has every part except the schedule.** The Finder in
   `fan/discovery.lua` owns binding 6001 and one window at a time, and a
   second `find` joins the open window. The follower already runs its own
   windows through it. What is missing is a scheduler, a list that outlives one
   window, and a pick handler. (Section 3.)
3. **Proposed schedule** (section 4.1): one search 3 s after late init plus a
   per-device slot, on every load (an update in place included). Then, while
   the device has no fan, or no usable address, or its fan is away and the
   follower is not looking: searches at 1 min, 5 min, then every 15 min, each
   ±20 %. While the pinned fan answers: no further searches (the Hue rule).
   While the follower is armed: no windows of its own, because the follower's
   windows already feed the list. At most about 100 windows a day per device,
   the follower's existing budget.
4. **One binding owner, one window, every answer to the list** (section 4.2):
   the Finder stays the only owner of binding 6001. It gains a listener that
   receives every closed window's answers, whoever opened the window. The list
   is built from that listener. The follower is unchanged and still never acts
   on the list or the pick.
5. **The list** (section 4.3): a summary row with a count and an instruction,
   then one item per fan heard (`MF_Fan_005301 at 10.0.2.151`), this device's
   fan first and marked, with its product name. Other devices of this driver
   can be listed with documented calls (`C4:GetDevicesByC4iName`,
   `C4:GetDevices`), but no documented call reads their pinned fan. Marking
   another device's fan needs a message exchange with `C4:SendToDevice`, so it
   is proposed as a later step.
6. **Recommendation: a pick acts at once**, as the Hue pick does, except a pick
   that would switch a pinned device to a *different* fan. That pick waits for
   **Use Selected Fan**, the Hue equivalent of "Forget Pairing first". The
   alternative, every pick waiting for the click as today, survives automatic
   list rewrites only if the driver keeps the pick itself. (Section 4.3.6.)
7. **Removing Find Fans** touches the driver, texts, three specs, the manual,
   the checklist, the v1 contract, the README and SECURITY.md. Composer drops
   the action at the update in place. No persisted state refers to it.
   (Section 4.4.)
8. **OS 3.x vs 4.x:** nothing the mechanism uses differs, except that
   `ReceivedFromNetwork` names the sender only from 4.0.0. The A record already
   gives the address. (Section 4.6.)

## 2. What the Hue driver did (the owner's reference)

Sources: the contract
[`simplify-actions-design.md`](https://github.com/corytron/c4-hue-driver/blob/main/docs/simplify-actions-design.md)
(D5, D12, §2.3, §3.4, §4), the research
[`simplify-research-discovery.md`](https://github.com/corytron/c4-hue-driver/blob/main/docs/simplify-research-discovery.md),
the code
[`bridge/discovery.lua`](https://github.com/corytron/c4-hue-driver/blob/main/src/hue_bridge/bridge/discovery.lua),
[`bridge/mdns.lua`](https://github.com/corytron/c4-hue-driver/blob/main/src/hue_bridge/bridge/mdns.lua),
[`bridge/sweep.lua`](https://github.com/corytron/c4-hue-driver/blob/main/src/hue_bridge/bridge/sweep.lua),
[`bridge/housekeeping.lua`](https://github.com/corytron/c4-hue-driver/blob/main/src/hue_bridge/bridge/housekeeping.lua)
and
[`driver.lua`](https://github.com/corytron/c4-hue-driver/blob/main/src/hue_bridge/driver.lua),
the commits `a4ba96d` (discovery), `4169881` (Bridges Found and the
follow-up), `432f50e` (the §4 fixes), `7cd65ba` and `0fc048c`, issue
[#334](https://github.com/corytron/c4-hue-driver/issues/334) and the dev rounds
in Discussions
[#369](https://github.com/corytron/c4-hue-driver/discussions/369) and
[#378](https://github.com/corytron/c4-hue-driver/discussions/378).

### 2.1 The schedule

| What | When | Source |
| --- | --- | --- |
| First-load searches | 3 s after late init, then 1 min, 5 min, then every 15 min, **only while unpaired**. At each step the timer checks again whether the driver is paired. | VERIFIED: `driver.lua` `FIRST_SEARCH_MS = { 3000, 60000, 300000 }`, `SEARCH_EVERY_MS = 900000`, `schedule_searches` |
| Started | at the end of `OnDriverLateInit` (`show_bridges()` then `schedule_searches()`), so every load restarts the schedule: a Director restart, an update in place, a dev-loop reload | VERIFIED: `driver.lua` `OnDriverLateInit` |
| Stopped | when a pairing succeeds: the timer is cancelled and the row redrawn at once (§4 finding 2) | VERIFIED: `driver.lua`, the pairing success path; commit `432f50e` |
| Restarted | by Forget Pairing (`bridges.restart()`, §4 finding 2) | VERIFIED: `driver.lua` |
| The follow-up | a housekeeping task, `find_bridge` (essential, `min_gap_s = 300`), runs only while paired and while the bridge does not answer at its address. It runs mDNS for the paired id, then at most an hourly subnet sweep (D12). | VERIFIED: `driver.lua` `start_housekeeping`; `discovery.lua` `find_paired` |
| An address typed by hand that never verified | one automatic search per address (`bridges.offer()`). The bridge's real address then shows in the list and in Attention; the typed value is never rewritten. | VERIFIED: `driver.lua` `bridges.offer`; research §2.5 |
| Paired and answering | no search at all | VERIFIED: `schedule_searches` returns while paired; the follow-up's guard "the bridge answers at its address" |

The research costed this at one datagram per search and 96 searches a day
while unpaired (research §2.4, §2.6). The engine's 5-minute quiet period after
a Director restart applies to *optional* housekeeping tasks only. The
first-load search runs at 3 s (VERIFIED: `housekeeping.lua` header, "the
quiet period by DIT").

### 2.2 The row and the pick

- **Bridges Found** is a `DYNAMIC_LIST` row right under Bridge IP Address.
  Its value is a summary: `Looking for Hue bridges on the network...`,
  `2 Hue bridges found: pick one and click Set to pair`, `No Hue bridge
  answered: type its address in Bridge IP Address` or `Paired with <model> at
  <ip>`. Then one item per bridge (the paired one first), then `Search again`,
  and the offered subnet search when nothing answered. VERIFIED:
  `driver.lua` `show_bridges`.
- **A pick acts at once.** On an unpaired driver it writes Bridge IP Address,
  runs that property's handler (the driver's own `UpdateProperty` fires no
  `OnPropertyChanged`) and opens the pairing window. The picked id is the
  expected one: a different bridge at that address is refused (§4 finding 4).
  On a paired driver, its own bridge at another address rewrites the address;
  another bridge is refused ("run Forget Pairing first"). VERIFIED:
  `driver.lua` `pick_bridge`, `set_bridge_address`,
  `dispatch.properties["Bridges_Found"]`.
- **The row snaps back to its summary** after every pick. The list is
  written to Director only when its text changed (`list_rows_sent`); a pick
  clears that memory so the snap-back is sent. A value that is not in the
  current list (the summary, or a label from an older list) does nothing.
  Commas in items become `‚` (U+201A). VERIFIED: `driver.lua` `show_list`,
  `commaless`, the `Bridges_Found` handler.
- **Search again** is a list item, not an action. It runs a search now and
  reports in Last Action. VERIFIED: `driver.lua` `SEARCH_AGAIN`.
- Never fill the address by itself, even when exactly one bridge answers
  (research O4, recommended no; built so).

### 2.3 Last Action belongs to the owner

Every automatic search wrote `Bridges Found: ...` to Last Action every 15
minutes over the owner's last result. The fix: automatic searches write the
row and the log only (Debug Mode); Last Action is for searches the owner
asked for (Search again, the subnet pick). VERIFIED: contract §4 finding 3;
commit `432f50e`; `driver.lua` `search_bridges(subnet, asked)`.

### 2.4 The binding and the window

- **One fixed binding id, created once per run of the Lua, never cleared**,
  connected for one window and disconnected at its end (Hue: 6008). A cleared
  and reused id misbehaved on OS 3.4.3, and a fresh id per search would leave
  hundreds of dead bindings (Hue #329). VERIFIED: `discovery.lua` header.
- **One window shared by every job that waits for it**: a second search while
  one is open joins it (`D:_mdns`). VERIFIED: `discovery.lua`.
- **What the house showed** (dev build 447, 2026-11-05): a query from the
  driver's own port on a `UDP` connection to 224.0.0.251:5353 got the bridge's
  answer 1 ms later; `MULTICAST` gave the same answer; `ReceivedFromNetwork`
  had three arguments (no sender), so the address came from the A record; port
  5353 is Director's own (`C4:PortInUse(5353)` true), so there is no query from
  5353; after `NetDisconnect` Director reported `OFFLINE` once and did not
  reconnect by itself. VERIFIED: `discovery.lua` header; #334 probe comment.
- **Every answer is only a candidate** until an identity read at that address
  confirms it, because an A record can be stale (Home Assistant core #75996,
  cited in research §2.2).

### 2.5 After an update, a restart and a reload

The schedule lives in memory and restarts from late init. Timers die at
`OnDriverDestroyed` (API/`22_miscellaneous/_24-OnDriverDestroyed.md`).
`DYNAMIC_LIST` items are not persisted, so the driver rebuilds them
(FUND/`15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md`).
The binding is created again in each run, a second create being allowed. Only
the sweep's last time is persisted, so a restart cannot reset its hourly limit
(VERIFIED: `discovery.lua` `STORE_LAST_SWEEP`). The hardware lesson of
`0fc048c`: a dev-loop reload that overlapped the previous one left an object
of the unloaded code connecting on a binding. It now stops at
`OnDriverDestroyed`, and the driver's callbacks start nothing after it
(VERIFIED: commit message; a dev-loop artifact, never a production start).

### 2.6 What went wrong on hardware, and what was fixed

| Seen | Fix | Source |
| --- | --- | --- |
| Bridges Found read `Paired with  at <ip>`: the model was missing for a pairing made before 1.1 | the identity check's model is used for the summary | dev 467, Discussion #369 finding 1; `7cd65ba` |
| Forget Pairing left the row reading "Paired ..." and the searches stopped until a restart; a new pairing left "N found" up to 15 min | both redraw at once; Forget Pairing restarts the first-load searches | §4 finding 2; `432f50e` |
| Automatic searches overwrote Last Action every 15 min | the row and the log only | §4 finding 3; `432f50e` |
| A picked bridge was not passed to the pairing, so another bridge at that address could be paired | the pick's id is the expected one | §4 finding 4; `432f50e` |
| The subnet item named the controller's /24 while the search started elsewhere | the label names what is searched | §4 finding 12 |
| A dev reload's stale object kept connecting on a binding | the last object owns the binding; destroyed objects start nothing | `0fc048c` |
| (dev 477) the row read `Paired with Hue Bridge Pro (BSB003) at <ip>` and the subnet item one network | as designed | Discussion #378 |

### 2.7 What carries over, what does not

| Hue | Here |
| --- | --- |
| Searches at 3 s, 1 min, 5 min, then every 15 min while unpaired | **Carries over** while the device has no fan pinned (or no usable address, section 4.1) |
| No search while the paired bridge answers | **Carries over**: no periodic search while the pinned fan answers (one at load, section 4.1) |
| The follow-up when the bridge is missing | **Already here**: the follower (V29). Its windows now also feed the list (section 4.2) |
| Automatic searches never write Last Action | **Carries over** |
| A pick acts at once; the row snaps back | **Carries over**, with a guard for switching a pinned device to another fan (section 4.3.6) |
| Another bridge on a paired driver is refused ("Forget Pairing first") | **Carries over** as "click Use Selected Fan to switch" (there is no pairing to forget) |
| Search again as a list item | **Offered**, the owner's call (section 7, Q1) |
| One fixed binding, connected per window, a joined window | **Already here** (6001, `Finder:find`) |
| Write the list only when it changed; commas to `‚`; `UpdatePropertyList` plus `UpdateProperty` | **Carries over**; the last two are already here (`texts.list_item`, `driver.lua` `prop_list`) |
| An identity read of every bridge found, for its name and model | **Does not carry over**: no automatic HTTP read of fans this device does not control. The name is shown for this device's own fan only (section 4.3.2) |
| The subnet sweep (D12) | **Forbidden**: no subnet scan, ever (CLAUDE.md, V5, F8) |
| Pairing window, link button, key, TLS and identity checks of a bridge, `replacesbridgeid` | **No equivalent**: a fan has no pairing step; its identity is the client id and MAC, checked by one read (`model:use_fan`) |
| Attention ("bridge missing") | **No equivalent row**; Status S7 to S9 already say the fan is not answering |
| The housekeeping engine and its persisted due times | **Not needed**: one small scheduler in memory, like the follower (F3) |

## 3. What exists here

### 3.1 `fan/discovery.lua`

- `discovery.query()` returns the 38-byte PTR question for
  `_easylink._tcp.local` (id 0, QM). `discovery.parse(datagram)` keeps only
  TXT `Protocol=com.modernforms.fan` and returns `{ instance, address, port,
  mac, firmware }` per fan; it never raises. `discovery.candidates(heard,
  mac12, current)` gives the follower at most 3 private or link-local addresses
  for the pinned MAC. VERIFIED: the code; `discovery_spec`.
- `discovery.new({ open, send, close, timer, log })` is the **Finder**.
  `Finder:find(cb)` opens the binding, sends the query at once and again 1 s
  later, collects answers for 3 s, closes the binding and calls `cb(list, err,
  heard)`. `list` is first-answer-wins by instance; `heard` holds every
  distinct (instance, address) pair, up to 64. **A `find` while a window is
  open adds its callback to that window** (one binding, one window).
  `Finder:received` parses every datagram of an open window once and drops
  everything outside a window (`"closed"`). `Finder:stop()` ends a window
  without calling back. The Finder has no clock and no record of when its last
  window closed. Its log lines say `Find Fans:`.
- The `err` words `open`, `timer` and `send` map to L10 today.

### 3.2 `fan/follow.lua`

The follower is armed on an offline-like phase (offline, foreign, gen4,
notfan) while `Follow Address Changes` is On, `Fan Address` is not empty, the
pin has a MAC and no typed address is pending. Its windows come through
`opts.find`, which is `discovery:find`: at 2 s plus a slot (device id mod 8,
3.5 s each) plus 0 to 0.5 s, then 30 s, 1, 2, 5 and 10 min, then every 15 min,
each ±20 %, never closer than 30 s after **its own** last window
(`last_close`). It draws from a Park–Miller generator seeded from the device id
and the clock, because LuaJIT seeds every Lua state alike (review of #48). It
reads `heard` through `candidates` and never touches `Found Fans`.
`Follower:state()` returns `off`, `pending`, `armed:N` or `idle`. It does not
own binding 6001; the Finder does. VERIFIED: the code;
[`v1-design.md` 9.14](v1-design.md#914-fanfollowlua-v29-39).

### 3.3 `fan/model.lua`

`Model:use_fan(address, mac12, cb)` makes one info read at the target, nothing
else. Its verdicts are `already` (L4), `moved` (L2), `now_using` (L3),
`no_answer` (L5), `not_a_fan` (L6) and `not_picked` (L21, when a pick's MAC
differs from the fan's), and `nothing_to_use` (L7) with `{ find_fans = true }`.
A follow is `use_fan` restricted to the pinned fan (`m:follow`). Nothing in the
model knows Find Fans. VERIFIED: `model.lua` `use_fan`, `use_verdict`.
**No change is needed in the model.**

### 3.4 `fan/texts.lua`

S2 (`Not set up: Find Fans, or enter the fan's address in Fan Address`, when
`view.find_fans`), L7 (`Nothing to use: pick a fan in Found Fans, or enter Fan
Address`), L8 and L9 (`Found 2 fans: pick one in Found Fans, then Use Selected
Fan`, `No Modern Forms fan answered on this network`), L10 (`Find Fans could
not send its query on this controller`), L21 (`The fan at 10.0.2.151 is not the
one picked; Find Fans again`), and `texts.found_fans(list, pin)`
(`MF_Fan_005301 at 10.0.2.151`, ` (this device's fan)` for the pinned MAC, at
most 16, commas through `texts.list_item`). VERIFIED: the code;
[`v1-design.md` 7.1](v1-design.md#71-status) to
[7.3](v1-design.md#73-the-other-rows).

### 3.5 `driver.lua`

- `FIND_BINDING = 6001`. The Finder's `open` calls
  `C4:CreateNetworkConnection(6001, "224.0.0.251")` once per run (a second
  create inside `pcall`), then `C4:NetConnect(6001, 5353, "MULTICAST")`; `send`
  uses `C4:SendToNetwork`; `close` uses `C4:NetDisconnect`.
  `ReceivedFromNetwork` routes binding 6001 to `discovery:received`. There is
  no `OnConnectionStatusChanged` for 6001; the immediate send plus the repeat
  after 1 s cover a binding that is not yet `ONLINE` (K10 measured 7 ms).
- `dispatch.commands["Find_Fans"]` runs one `find`, writes `Found Fans` as
  `{ "Pick a fan", items... }` with `"Pick a fan"` selected, and writes L8,
  L9 or L10.
- `Use_Selected_Fan` calls `follower:clicked()`, then takes `picked_fan()`
  (the `Found Fans` value matched against the last items) or `Fan Address`,
  and calls `model:use_fan`. After any outcome it re-selects `"Pick a fan"`
  (`clear_pick`), writes `Fan Address` on `moved` and `now_using`, and starts
  the guarded rename.
- `dispatch.properties` has no `Found_Fans` handler ("a pick waits for Use
  Selected Fan").
- `OnDriverLateInit` writes `Found Fans` as `{ "Pick a fan" }` before
  `dispatch.replay_properties`. Every property handler runs in that replay
  ([`v1-design.md` 2.5](v1-design.md#25-properties-in-this-order)).
- `refresh_status` always sets `view.find_fans = true`.
- `OnDriverDestroyed` stops the follower and then the Finder.

VERIFIED: the code.

### 3.6 `driver.xml`

Actions: `Find Fans` (sort 1), `Use Selected Fan` (2), `Name Items After Fan`
(3), `Reboot Fan` (4), `Turn Off Away Mode` (5), `Turn Off Adaptive Learning`
(6). `Found Fans` is a `DYNAMIC_LIST`, not read-only, with no `<default>`,
after `Fan Address` and before `Follow Address Changes`. VERIFIED: the file.

### 3.7 `fan/devcmds.lua`, the specs, the fake runtime

- `devcmds.new` takes `follow` for Dev State's `follow=`. There is no
  development command for a search: Find Fans was the action.
- `tests/spec/discovery_spec.lua` covers the Finder, parse and candidates (12
  mentions of Find Fans). `tests/spec/texts_spec.lua` covers S2, L7 to L10, L21
  and `found_fans` (20 mentions). `tests/spec/fan_driver_spec.lua` checks the
  action order `1:Find Fans, ...`, S2 at start, a "Find Fans" block and the
  follower end to end. Note: its test "stays at the typed address with Follow
  Address Changes Off" asserts **zero** `SendToNetwork` calls over 120 s, and
  its `run` helper counts queries. Any search at load breaks these
  assertions, so the coordinator must rewrite them.
- `tests/helpers/fake_c4.lua` already has what the specs need: dynamic network
  bindings, `fake.network_receive`, `c4.advance(ms)` that fires timers in
  order, `GetDevicesByC4iName`, `GetDriverFileName`, `fake.pair` with routed
  `SendToDevice`. VERIFIED: the file.

### 3.8 What must change and what must stay

| Part | Change | Stays |
| --- | --- | --- |
| `fan/discovery.lua` | a listener for every closed window; `last_closed()`; a clock option; log prefix | query, parse, candidates, the window, joining, `stop` |
| `fan/follow.lua` | nothing (comments may say "search windows") | everything: F1 to F9, its ladder and floor |
| `fan/model.lua` | nothing | `use_fan` serves the pick and Use Selected Fan |
| `fan/texts.lua` | S2, L8 to L10, L21, the list's summary and items, one new text for a pick that waits | L7, L1 to L6, L30, L31 |
| new | a scheduler (`fan/search.lua`) and the list state (`fan/found.lua`) | — |
| `driver.lua` | remove the Find Fans command; build the scheduler and the list; a `Found_Fans` pick handler; Use Selected Fan's target; wiring at late init, on phase changes and at destroy | binding 6001, `ReceivedFromNetwork` routing |
| `driver.xml` | remove the action; the `Found Fans` comment | the property (name and type unchanged), the other actions |
| docs | section 4.4 | CHANGELOG history |

## 4. The proposed mechanism

### 4.1 The schedule

**Modes.** The scheduler asks the driver which mode applies whenever it plans
the next window.

| Mode | When | Windows of its own |
| --- | --- | --- |
| `seek` | no fan pinned; or `Fan Address` is empty or not an IPv4 address (phase `unset`); or the pinned fan is away (an offline-like phase) and the follower is **not** armed (`Follow Address Changes` Off, a typed address pending, a pin without a MAC) | 1 min, 5 min after entering the mode, then every 15 min, each ±20 % |
| `quiet` | a fan is pinned and the phase is `online`, `waiting` or `rebooting` | none |
| `standby` | the follower is armed (`follower:state()` starts with `armed`) | none: the follower's windows feed the list (4.2) |

**At every load** (`OnDriverLateInit`, so also after an update in place, a
Director restart or a dev-loop reload), one window opens at 3 s plus the
device's slot plus jitter, whatever the mode. That makes "at driver load"
literal and refills the list, which is not persisted. After that window the
mode decides. When the mode changes, the next window is re-planned.

**Jitter and slots.** The slot is the follower's: device id mod 8, times
3.5 s, which is longer than a 3-second window. So devices of one project
started together in different slots never overlap: 8 devices spread over
28 s. Add 0 to 0.5 s of jitter, and ±20 % on every later step. The jitter
comes from the scheduler's own Park–Miller generator, seeded from the device
id and the clock at the first plan, as the follower's is; LuaJIT seeds every
Lua state alike (VERIFIED: `follow.lua` comment, review of #48). The device id
is read at the first plan, never at load (API/`22_miscellaneous/_11-GetDeviceID.md`,
not for `OnDriverInit`). Overlapping windows on two devices are harmless: each
has its own binding and hears the answers to its own queries.

**Floor.** No window of the scheduler opens less than 30 s after **any**
window of this device closed, its own or the follower's (`Finder:last_closed()`).
A window that is open when the scheduler's time comes is joined, not doubled
(`Finder:find`).

**Pulled forward** (`poke`), always respecting the floor:

- **Search again** (if the owner wants the item, section 7 Q1);
- a pick, or Use Selected Fan, whose read answered `not_picked` or
  `no_answer` (the list was stale);
- an unpinned device whose typed `Fan Address` did not answer at the first
  contact (the Hue `bridges.offer()` rule: the list then shows what does
  answer, and the typed value is never rewritten).

**Why no periodic search while the pinned fan answers.** The Hue driver does
not search while its paired bridge answers, and every use of the list on a
pinned device is covered without it. A replacement fan, or the pinned fan at a
new address, only matters once the pinned fan stops answering at `Fan
Address`. Then the follower's windows run (or `seek` does, with following
Off), and they feed the list. A second fan in the house belongs to a new
device, which is unpinned and searches by itself. What is lost is only how
fresh an informational list is. The summary row says when the last search ran.
The alternative is a search every 60 min ±20 % while `quiet`: 24 more windows
a day, a list never more than an hour old. It is noted, not recommended.

**Budget, per device** (a window is two 38-byte questions, and per fan that
answers, two answers of 250 to 300 bytes: VERIFIED, K10, ECA E1):

| Mode | Windows a day | Questions a day |
| --- | --- | --- |
| `seek` (unpinned, or the fan away with following Off) | 1 at load + 2 + 96 ≈ 99 | ≈ 198 |
| `quiet` | 1 per load | 2 per load |
| `standby` | 0 of its own (the follower's ladder: 8 in the first hour, then 4 an hour, about 100 a day) | 0 |

So no device exceeds the follower's budget of about 100 windows a day, which
ECA [3.3](edge-cases-address.md#33-schedule) accepted (its harmlessness on the
controller is ASSUMED, check K21).

**Back-off and failures.** The cadence is fixed (15 min in `seek`). The
follower's longer ladder is not repeated here, because the list is the setup
path and the Hue driver keeps 15 min while unpaired. A window that could not
open or send (`err` `open`, `timer` or `send`) is logged as a warning once per
streak, as the follower does (FA17). The summary row says searching is not
possible. The cadence continues and nothing goes to Last Action. Nothing is
persisted: the mode, the step and the floor live in memory and restart at
load, as the follower's do (F3).

### 4.2 Sharing binding 6001 and its window with the follower

- **One owner.** The Finder stays the only code that opens, sends on and
  closes binding 6001, and the only receiver of its datagrams
  (`ReceivedFromNetwork` → `discovery:received`). The scheduler and the
  follower are both callers of `Finder:find`. Neither touches the binding.
- **One window at a time.** A second `find` joins the open window. Each
  caller's callback receives the whole window's `list`, `err` and `heard`.
  Answers arrive within 0.2 to 0.35 s of each query (K10), so a late joiner
  loses nothing. No two windows of one device can overlap, and the floor of
  4.1 keeps the scheduler from opening one right after the follower's.
- **Every answer reaches the list.** The Finder gains one listener
  (`on_window(list, err, heard)`), called once after each window closes and
  after its callbacks, **whoever opened it**. The driver wires it to the list
  (`fan/found.lua`). The follower's windows therefore refresh the list without
  the follower knowing the list exists. The follower still reads only `heard`
  through `candidates` for the pinned MAC.
- **Who parses what.** `Finder:received` parses each datagram once
  (`discovery.parse`) into the window's `list` and `heard`. The follower uses
  `heard` (F4). The list uses `heard` too, keyed by MAC (or instance) and
  address, so a fan heard at two addresses shows both. The pick's read then
  settles which one is real (ECA FA11 for why first-answer-wins can hide a
  fresh address). Datagrams outside a window are dropped, as today; there is
  no standing listener (F8).
- **Contract changes this needs.** V5a ("never writes `Found Fans`") and F8
  ("touching `Found Fans` or the pick") apply to the follower's *actions*. The
  new text: the list shows what every window heard; the follower never acts on
  the list, the pick or another fan. ECA CA5 ("the automatic search never
  writes Found Fans") is superseded the same way.
- **Find Fans clicked during a follower window** (CA5) goes with the action.
  Search again, if kept, joins an open window like any other caller.

### 4.3 The list

#### 4.3.1 The summary (the row's value, the first item)

| State | Summary | Length (worst) |
| --- | --- | --- |
| from load until the first window closes | `Looking for Modern Forms fans on the network...` | 47 |
| unpinned, fans heard | `2 fans found: pick one and click Set to use it` (`1 fan found: pick it and click Set to use it`) | 46 |
| unpinned, none heard | `No fan found yet: enter its address in Fan Address` | 50 |
| pinned, its fan heard | `2 fans found at 14:02; this device's fan is listed first` (`This device's fan found at 14:02`) | about 60 |
| pinned, its fan not heard | `2 fans found at 14:02; this device's fan did not answer` | about 60 |
| searching impossible (open or send failed) | `No search possible on this controller: enter Fan Address` | 56 |

The time is the end of the last window that sent its query, as `texts.clock`
writes it (`10-26 14:02` after 24 h). These texts are proposals for the texts
piece; each stays under 70 characters (Composer clips near 75, ECC F29).

#### 4.3.2 An item

`<instance> at <address>`, plus a mark: ` (this device: Aviator 5)` for the
pinned MAC when `fan/names.lua` knows its `fanType` (from the stored
`mf_info`), otherwise ` (this device's fan)`. Example: `MF_Fan_005301 at
10.0.2.151 (this device: Aviator 5)`, 52 characters.

- **Telling two fans of one model apart.** The instance already ends in the
  last six hex digits of the MAC: `MF_Fan_XXXXXX`, `WAC_Fan_XXXXXX`, or Gen 1/2
  `WAC Windermier Fan#XXXXXX` (VERIFIED: ECA E1 for the house Gen 3 fan; E4
  and MFR §1 for the other forms). Those digits match the router's client list
  (the manual says so today). For an instance without the digits (an unknown
  layout), ` ...5302` from the TXT MAC is added. The instance is cut to 25
  characters, and when the item would pass 72 characters the product name is
  left out.
- **No product name for other fans.** The mDNS answer carries no `fanType`.
  The house fan's TXT has only `Protocol`, `MAC` and `Firmware Rev` (VERIFIED:
  K10, v1-design 9.10). A TXT `Model` key is documented for some fans (MFR §7)
  but was not seen on the house. Naming every heard fan would take one HTTP
  read (`queryStaticShadowData`) per fan, which is an automatic request to a
  device this device does not control. Fans of this generation have frozen
  under polling (MFR §8, HA's 5 s to 15 s), and the request would bring back
  private fields to drop (V20). Not recommended. The pick's own read learns
  the name the moment a fan is chosen.
- **Fans of other devices of this driver.** Listing those devices is
  documented: `C4:GetDevicesByC4iName(name)` returns the device ids of a
  driver file (API/`25_proxy/_4-GetDevicesByC4iName.md`, from 1.6.0; the fake
  reads it as id → name), and `C4:GetDevices({ C4iNames = ... })` adds names
  and rooms (API/`22_miscellaneous/_9-GetDevices.md`, from 2.10.0; the Hue
  bridge uses it on this house, `bridge/project.lua`).
  `C4:GetDriverFileName()` gives this driver's own file name
  (API/`22_miscellaneous/_13.5-GetDriverFileName.md`, from 3.3.0, the minimum
  OS). **No documented call reads another device's properties or persisted
  store** (VERIFIED absence: no such call under `API/24_properties/`,
  `API/22_miscellaneous/`, `API/26.5_persistence/`). Three documented
  workarounds, each with a cost:
  1. `C4:SendToDevice` (API/`32_serial_network_device/_19-SendToDevice.md`,
     from 1.6.0). It lands in the target's `ExecuteCommand`, which does not
     name the sender (dev-loop.md, "Development commands"). The Hue drivers
     use it both ways on this house (VERIFIED: Hue `docs/design.md`). Each
     device would announce `{ device, mac }` to its siblings at late init and
     on every pin change, and keep a map, dropping ids that
     `GetDevicesByC4iName` no longer lists. Cost: an inter-device protocol and
     its specs (`fake.pair` routes it), and a second device on the house to
     see it.
  2. A hidden variable holding the pinned MAC, read with `C4:GetDeviceVariables`
     (API/`22_miscellaneous/_12-GetDeviceVariables.md`, from 2.8.0; the
     returned table's layout is not documented). Cost: a variable is added in
     `OnDriverInit` (API/`36_variable/_1-AddVariable.md`) and is forever once
     released; the layout is ASSUMED.
  3. The controller registry (API/`26_registry/_1-Introduction.md`, from
     2.10.4). Its documentation says it is not for state. Cost: entries go
     stale when a device is deleted. Not recommended.

  **Recommendation:** none in this build. Mark only this device's fan, and
  file option 1 as a follow-up issue. It pays off only with two or more fans,
  and it cannot be seen on the house without a throwaway second device. If
  built, the mark is ` (used by <device name>)`, the name cut to 20
  characters.

#### 4.3.3 Order, size, ageing

- Order: this device's fan first, then the others by instance (case-blind),
  then by address. The list is stable from window to window, so the labels do
  not shift under the owner. At most 16 fans (today's `texts.MAX_FOUND`).
- Ageing: an entry is kept until two windows in a row **that sent their
  query** did not hear it. A window that could not send (`err` set) ages
  nothing. In `seek` mode that is about 30 min. In `quiet` mode an entry stays
  until the next window, and the summary's time says how old the list is.
  Fans may announce inconsistently (ASSUMED in MFR §7, from the HOMEY
  journal), so a single missed window removes nothing.
- No persistence: items are not persisted
  (FUND/`15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md`).
  The window at load refills the list 3 to 31 s after any load.

#### 4.3.4 Writing the row

- `C4:UpdatePropertyList(name, items, value)` plus `C4:UpdateProperty(name,
  value)`. On the house, the list's default alone did not move the shown row
  (VERIFIED: `driver.lua` `prop_list` comment, from the Hue project). The
  third parameter must be one of the items (API/`24_properties/_6-UpdatePropertyList.md`;
  the default parameter exists since OS 3).
- **Only when the text changed** (the Hue `list_rows_sent` rule). In `quiet`
  mode the row is written about once per load. In `seek` mode it is written
  only when a fan appears or ages out, or the summary's time changes (the
  time can be left out of the comparison, so a list whose fans stay the same
  is not rewritten every 15 min). This keeps the row still while an owner is
  choosing in Composer. What Composer does with a drop-down that is open,
  with a choice not yet Set, when the driver rewrites the list is not
  documented and was not seen: ASSUMED that the unsaved choice may be lost.
  Hence the rule.
- Commas become `‚` (`texts.list_item`, as the Hue drivers do).

#### 4.3.5 What happens to the owner's pick when the list is rewritten

The SDK: the owner chooses an item and clicks **Set**, then Director calls
`OnPropertyChanged` with that value
(FUND/`15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md`).
The driver's own `UpdateProperty` calls no handler
(API/`24_properties/_3-OnPropertyChanged.md`). So a rewrite that selects the
summary row **erases a pick that was waiting**, silently. Today that cannot
happen, because only a click writes the list. With automatic rewrites it can,
and that drives 4.3.6:

- If the pick acts at once (the Hue way), nothing waits, so nothing can be
  erased. The handler acts, then the row snaps back to the summary (clear the
  "sent" memory, write the list).
- If a pick waits, the driver must keep it itself as `{ mac, address,
  label }`, not read it back from `Properties`. A rewrite then selects the
  same label when it is still there, or the new label of that MAC. The pick is
  dropped when its fan ages out, and Last Action says so.
- In both cases the handler ignores a value that is not an item of the
  current list: the summary, `Search again` handled apart, or a label from an
  older list. The handler also runs in the late-init replay with whatever
  value was stored (v1-design 2.5). It must do nothing then: the list is empty
  until the first window, so the stored value matches nothing. And it must do
  nothing before `started`.

#### 4.3.6 Does a pick act at once, or wait for Use Selected Fan?

| | A. Every pick waits for Use Selected Fan (today) | B. A pick acts at once (Hue) |
| --- | --- | --- |
| Clicks to set up a new device | pick, Set, Actions tab, Use Selected Fan | pick, Set |
| A pick erased by an automatic rewrite | possible; needs the kept pick of 4.3.5 and a rule for its expiry | impossible: nothing waits |
| A mistaken pick on a pinned device | costs nothing until the second click | switches the device to another fan at once (its links and programming then drive that fan) unless guarded |
| What Use Selected Fan does | confirms the pick, or accepts the fan at `Fan Address` | accepts the fan at `Fan Address` (the S11 case: another fan answers there); with the guard below, also confirms a waiting switch |
| Consistency with the Hue driver | different | same |
| Texts | L8's "then Use Selected Fan" | the summary's "pick one and click Set" |

**Recommendation: B with one guard.** A pick acts at once through the same
call Use Selected Fan makes (`follower:clicked()`, then `model:use_fan(address,
mac)`), with the same results and the same guarded rename:

- **Unpinned device:** the pick pins that fan (L3 `Now using fan ... at
  ...`), writes `Fan Address`, and the names follow (N4).
- **Pinned device, its own fan:** L4 if the address is the current one, L2
  (`moved`) if it is another. This is what the follower would do by itself, so
  there is nothing to guard.
- **Pinned device, a different fan:** **nothing is read yet.** The pick waits
  (kept as in 4.3.5), the row keeps showing it, and Last Action reads `Picked
  MF_Fan_005302: click Use Selected Fan to switch to it` (at most 70 with the
  instance cut to 23). Use Selected Fan then switches (L3 with "was"). This is
  the Hue rule "another bridge on a paired driver is refused", here with a
  confirming click instead of Forget Pairing. It also keeps the CLAUDE.md rule
  "a different fan is refused until a click accepts it" literal, for the one
  case where a mis-click matters.
- `not_picked` and `no_answer` poke a search (4.1) and say so (L21 reworded,
  4.5).

Cost of B: a second meaning for a pick (acts, or waits), which the manual and
Last Action must explain; the pick handler and the waiting pick in
`driver.lua`. Cost of A: the kept pick and its expiry anyway, two clicks where
the Hue driver needs one, and L8 stays an instruction no automatic search may
write.

### 4.4 Removing the action

**Every place `Find Fans` appears** (a grep of the checkout on 2026-11-07):

| File | Places | Change |
| --- | --- | --- |
| `src/modernforms_fan/driver.xml` | the action (sort 1), the `Found Fans` comment | remove the action; the comment says the list fills by itself. Sort orders 2 to 6 may stay: v1-design 2.6 says "the numbers stay"; a gap is ASSUMED harmless, and `fan_driver_spec` checks the order |
| `src/modernforms_fan/driver.lua` | header, `FIND_BINDING` comment, `Find_Fans`, `PICK_ROW`, `picked_fan`, `clear_pick`, the "a pick waits" line, the late-init list, `ReceivedFromNetwork` comment | 4.2, 4.3; `PICK_ROW` gives way to the summary |
| `src/modernforms_fan/fan/texts.lua` | S2, L7 to L10, L21, `found_fans`, `find_fans` fields | 4.5 |
| `src/modernforms_fan/fan/discovery.lua` | header and log prefix `Find Fans:` | `Search:`; the header describes the scheduler's and the follower's windows |
| `src/modernforms_fan/fan/follow.lua`, `fan/model.lua` | comments only (`Find Fans windows`, `{ find_fans = true }`) | optional wording; no behaviour |
| `tests/spec/discovery_spec.lua`, `texts_spec.lua`, `fan_driver_spec.lua` | test names, the action order, S2, the Find Fans block, the zero-query assertion | rewritten by their pieces (section 5) |
| `src/modernforms_fan/www/documentation.html` | 19 places: chapter 3's `Find Fans` section (`id="find-fans"`, no link points at it), the setup steps, Use Selected Fan's table (L21), the Status table (S2), the Properties table (`Found Fans`), the Actions table, the quick checklist, the network and privacy paragraphs | a section "Found Fans" that says the driver searches by itself (when, and that it never adopts a fan), what a pick does, and that following and the list use the same question |
| `docs/composer-checklist.md` | steps 1 and 4 (S2), step 5 (Find Fans), step 9 (the action list), step 45 (a Find Fans click) | read the list after the install; five actions; step 45 reads the list instead of clicking |
| `docs/v1-design.md` | V5, V5a, 2.4 (binding 6001's note), 2.5 row 5, 2.6, 7.1 S1/S2, 7.2 L7 to L10 and L21, 7.3 Found Fans, 9.1 (routing), 9.10, 9.14, 14, 16 | a pointer to the new contract, as V28 and V29 were added |
| `docs/address-follow-design.md` | F8, 2.1, 2.5 | the list wording of 4.2 |
| `README.md` | lines 76, 133, 235, 294 | the setup and network paragraphs |
| `SECURITY.md` | line 57 | the multicast question is asked by itself, at load and on a schedule |
| `CLAUDE.md` | the scope line about Find Fans | the coordinator's |
| `docs/status.md`, `docs/README.md`, `CHANGELOG.md` | status, the docs index, one `## Unreleased` line | the coordinator's and the docs piece's; CHANGELOG history stays |
| `docs/edge-cases-*.md`, `docs/migration-design.md`, `probes/`, `.github/release-notes.md` | history and the probe | stay as records |

**What replaces "Find Fans again" and similar.** Wording that named the
action now names the list: L21 becomes `The fan at 10.0.2.151 is not the one
picked; searching again` (65 with a 15-character address) and pokes a search.
S2 becomes `Not set up: pick a fan in Found Fans, or enter Fan Address` (58).
The manual's "click Find Fans and then Use Selected Fan" becomes "pick the fan
in Found Fans and click Set".

**What an existing device sees after the update in place.** Composer re-reads
the actions from the new package, and Find Fans disappears from the Actions
tab. Removing an action is safe: programming never refers to actions (Hue
contract §1.1, verified there on the house when 39 actions became 9). The
`Found Fans` property keeps its name and type, so no row is orphaned. Its
last value from before the update is replaced at late init. **Nothing is
persisted for Find Fans** (v1-design 8 lists no key for it), so nothing needs
migrating. `Fan Address`, the pin and every setting stay. The first window
runs 3 to 31 s after the install, and the row shows this device's fan.

**Compatibility.** No VM tool calls `Find Fans` by command (grep of `tools/`:
none). The Hue driver kept removed commands as hidden aliases until 2.0,
because its dev loop, `regress.sh` and briefs called them (Hue contract §3.3).
Here a hidden `Find_Fans` would stay reachable by any driver through
`SendToDevice` (dev-loop.md, "Development commands"). Recommended instead: no
alias in a release build, and a signed development command `Dev Search` in
`fan/devcmds.lua` that pokes a window and reports it, for the house checks of
section 6.

### 4.5 Status and Last Action

| Id | Today | Proposed |
| --- | --- | --- |
| S1 | unused (`find_fans` is always true) | unchanged, kept for a build without the list |
| S2 | `Not set up: Find Fans, or enter the fan's address in Fan Address` | `Not set up: pick a fan in Found Fans, or enter Fan Address` |
| L7 | `Nothing to use: pick a fan in Found Fans, or enter Fan Address` | unchanged |
| L8, L9 | written by every Find Fans click | written only by a search the owner asked for (Search again, if kept): `Found 2 fans: pick one in Found Fans and click Set` (`Found 1 fan: pick it in Found Fans and click Set`), `No Modern Forms fan answered on this network`. Never by an automatic search (Hue §4 finding 3) |
| L10 | `Find Fans could not send its query on this controller` | asked: `The search could not send its query on this controller`; automatic: the summary row of 4.3.1 and one warning per streak in the log |
| L21 | `The fan at 10.0.2.151 is not the one picked; Find Fans again` | `The fan at 10.0.2.151 is not the one picked; searching again` |
| new L32 | — | `Picked MF_Fan_005302: click Use Selected Fan to switch to it` (the guarded pick, 4.3.6) |
| L1 to L6, L22 to L31 | | unchanged; a pick writes the same lines Use Selected Fan writes, with the rename suffix |

No automatic search writes Last Action, in any mode, unless the contract
decides otherwise. The always-on log gets one line only when the list's fans
change (`Found Fans: 2 fans, this device's fan at 10.0.2.151`), with MACs cut
to four digits (section 3.7 of the v1 contract). Debug Mode keeps the Finder's
per-window line.

### 4.6 OS 3.x and 4.x

| Call or behaviour | OS | Difference | Source |
| --- | --- | --- | --- |
| `C4:CreateNetworkConnection`, `C4:NetConnect` (`UDP`, `MULTICAST`), `C4:SendToNetwork`, `C4:NetDisconnect` | from 1.6.0 | none documented; what `MULTICAST` joins is undocumented on both | API/`32_serial_network_device/_1-CreateNetworkConnection.md`, `_23-NetConnect.md`, `_20-SendToNetwork.md`, `_24-NetDisconnect.md`; VERIFIED on OS 3.4.3 by K10 (both types) and by the Hue probe |
| `ReceivedFromNetwork(binding, port, data, from)` | from 1.6.0; `from` from 4.0.0 | 3.x passes three arguments (seen on the house); the A record gives the address on both | API/`32_serial_network_device/_15-ReceivedFromNetwork.md`; API/`3_whats_new/_7-WhatsNewin400.md` ("UDP Functionality"); Hue probe on 3.4.2 |
| 4.0.0's other UDP changes | 4.0.0 | `SendBroadcast`'s source port and `ServerSend`'s address: not used | API/`3_whats_new/_7-WhatsNewin400.md` |
| 4.1.0 and 4.2.0 | — | nothing about networking or timers (VERIFIED absence: no such lines in `_6-WhatsNewin410.md`, `_5-WhatsNewin420.md`) | API/`3_whats_new/` |
| `C4:SetTimer` | from 2.7.0 | delay must be above 0 on both; timers die at `OnDriverDestroyed` | API/`34_timer/_1-SetTimer.md`; API/`22_miscellaneous/_24-OnDriverDestroyed.md` |
| `C4:GetTime()` | from 3.2.3; units from 4.0.0 | called with no argument it returns ms since the epoch on both | API/`34_timer/_2-GetTime.md` |
| `C4:UpdatePropertyList` | from 2.7.0; the default parameter since OS 3 | none within 3.3.0 and later | API/`24_properties/_6-UpdatePropertyList.md` |
| Port 5353 | — | Director's own responder holds it (Hue probe, 3.4.2), so no `MIRROR_UDP_PORT` | Hue `discovery.lua` header |
| Calls not before late init | all | `UpdateProperty`, `SetTimer`, the network calls and `GetDeviceID` | API/`22_miscellaneous/_25.2-SafeUsageTable.md`; each call's page |
| `GetDevicesByC4iName`, `GetDevices`, `GetDriverFileName`, `SendToDevice` (only if siblings are built) | 1.6.0, 2.10.0, 3.3.0, 1.6.0 | none within the 3.3.0 minimum | the files cited in 4.3.2 |

ASSUMED, as for every dynamic binding of this driver: each device of a
project has its own binding 6001. API/`32_serial_network_device/_1-CreateNetworkConnection.md`
asks for unique binding ids within a system, which this note reads as within
one device. A throwaway second device on the house (section 6, H5) settles it.

## 5. Proposed build split

Five pieces with disjoint files, and the coordinator. Every piece follows the
project conventions: Lua 5.1, tabs, `.luacheckrc`, busted specs on the fake
runtime of `tests/helpers/fake_c4.lua`, `luacheck src tests tools` and `busted
tests` clean, and no `git`.

| Piece | Files (creates or edits only these) | Interface it provides |
| --- | --- | --- |
| A, scheduler | `src/modernforms_fan/fan/search.lua` (new), `tests/spec/search_spec.lua` (new) | below |
| B, list state | `src/modernforms_fan/fan/found.lua` (new), `tests/spec/found_spec.lua` (new) | below |
| C, texts | `src/modernforms_fan/fan/texts.lua`, `tests/spec/texts_spec.lua` | S2, L8 to L10, L21, L32 (`picked_wait`), `texts.found_rows(view) -> summary, items`, `texts.SEARCH_AGAIN` (if Q1 says yes) |
| D, Finder | `src/modernforms_fan/fan/discovery.lua`, `tests/spec/discovery_spec.lua` | `discovery.new({ open, send, close, timer, now, on_window, log })`; `on_window(list, err, heard)` once per closed window, after its callbacks, whoever opened it, never after `stop()`; `Finder:last_closed() -> ms or nil`; log prefix `Search:`. Parse, query, candidates and `find` unchanged |
| E, documents | `src/modernforms_fan/www/documentation.html`, `docs/composer-checklist.md`, `README.md`, `SECURITY.md`, `docs/v1-design.md`, `docs/address-follow-design.md`, `docs/README.md`, `CHANGELOG.md` (`## Unreleased` only) | the places of 4.4 |
| Coordinator | `src/modernforms_fan/driver.lua`, `src/modernforms_fan/driver.xml`, `src/modernforms_fan/fan/devcmds.lua`, `tests/spec/devcmds_spec.lua`, `tests/spec/fan_driver_spec.lua`, `tests/helpers/fake_c4.lua` (if anything is missing), the contract, `docs/status.md`, `CLAUDE.md` | the wiring below |

**A, `fan/search.lua`** (pure, like `follow.lua`: every option through
`pcall`, nothing raises, building it arms nothing):

```lua
local search = require("fan.search")
local s = search.new({
	find = fn(cb(list, err, heard)),   -- discovery:find (joins an open window)
	last_closed = fn() -> ms or nil,   -- discovery:last_closed(): any window's close (the 30 s floor)
	mode = fn() -> "seek" | "quiet" | "standby",   -- driver.lua, 4.1
	timer = fn(ms, cb) -> object with :Cancel(), now = fn() -> ms,
	random = fn() -> 0..1,             -- tests only; else a Park-Miller generator of its own
	seed = fn() -> number,             -- the device id, read at the first plan
	on_asked = fn(list, err, heard),   -- the result of a window a poke("asked") opened (Last Action L8 to L10)
	log = log,
})
s:start()            -- late init: window 1 at 3 s + slot + 0..0.5 s
s:changed()          -- the mode may have changed: re-plan (never under the floor)
s:poke(why)          -- "asked" (Search again), "stale" (L21, L5 after a pick), "typed" (unpinned, no answer)
s:state() -> "off" | "standby" | "quiet" | "due:<s>" | "open"   -- Dev State's search=
s:stop()
```

Constants: `FIRST_MS = 3000`, `SLOTS = 8`, `SLOT_MS = 3500`,
`JITTER_MS = 500`, `SEEK_MS = { 60000, 300000 }`, `SEEK_EVERY_MS = 900000`,
`SPREAD = 0.2`, `MIN_GAP_MS = 30000`. The spec runs on the fake timer: the
first window's bounds per slot, the seek ladder and its jitter bounds, no
windows in `quiet` and `standby`, re-planning on `changed`, the floor after a
follower window, `poke` under the floor, a join instead of a double window,
`stop`, a fresh `start` after a stop (the update in place), and a simulated
week (`c4.advance`) counting windows per mode against 4.1's budget.

**B, `fan/found.lua`** (pure):

```lua
local found = require("fan.found")
local l = found.new({ max = 16, clock = fn() -> s, log = log })
l:window(heard, err) -> changed     -- every closed window (the Finder's on_window); err set: ages nothing
l:entries(pin_mac) -> { { key, instance, address, mac, own } ... }   -- own first, then instance, then address
l:searched() -> s or nil            -- the end of the last window that sent its query
l:failing() -> bool                 -- the last window could not open or send
l:keep(entry) / l:kept() / l:drop() -- the waiting pick of 4.3.6 (by MAC; follows the MAC to a new address)
l:clear()
```

The spec: the ageing rule (two sending windows), failed windows, two addresses
for one MAC, the cap of 16 with own-first, a stable order, the kept pick
across rewrites and its drop when its fan ages out, and records that are not
fans.

**C, texts:** every new string verbatim in the spec, at most 70 characters
with 15-character addresses and 25-character instances, commas through
`list_item`, and an instance cut at the end so the MAC digits stay. Its
`found_rows(view)` takes `{ phase = "looking" | "unpinned" | "pinned" |
"failing", entries, pin, info, count, at, now, kept }`.

**Coordinator wiring** (`driver.lua`): build the list and the scheduler after
the Finder and the follower. Wire `on_window` to `found:window` and redraw
`Found Fans` when it reports a change. `mode()` comes from
`model:identity()`, `model:phase()` and `follower:state()`. Call `s:changed()`
from `listener.phase`, after the follower, and after every Use Selected Fan or
pick result. Call `s:start()` at the end of `OnDriverLateInit`, after
`model:start`. Add `dispatch.properties["Found_Fans"]`: ignored before
`started` and for any value not in the current items; the summary does
nothing; `Search again` pokes "asked"; the pick acts or waits (4.3.6) and the
row snaps back. Use Selected Fan targets the kept pick, else `Fan Address`.
Remove `Find_Fans`. Call `s:stop()` in `OnDriverDestroyed` before
`discovery:stop()`. Dev State gains `search=`, and `fan/devcmds.lua` gains
`Dev Search`. `driver.xml` loses the action.

`fan_driver_spec` end to end: no Find Fans in the action order; a query on
6001 at 3 s plus the slot after late init; answers fill `Found Fans` with this
device's fan first; Last Action untouched by automatic searches; a pick on an
unpinned device pins it (L3, `Fan Address`); a pick of another fan on a pinned
device waits (L32) and Use Selected Fan switches; a rewrite keeps the waiting
pick; no scheduler windows while the follower is armed; the follow still works
(the existing tests, with their query counts and the Follow-Off assertion
rewritten to "no follow"); `OnDriverDestroyed` leaves no timer; a second
`OnDriverLateInit("DIT_UPDATING")` starts again.

## 6. Test plan

**Unit, on the fake runtime:** the specs of section 5. They cover everything
the schedule, the list, the texts and the wiring decide, including a
simulated week of windows.

**On the house** (the Windows session reads Composer through UI Automation;
standing approval for the install and the throwaway device; each check under a
minute):

| # | Check | How | Expect |
| --- | --- | --- | --- |
| H1 | The action is gone | after the install in place, read the Actions tab | five actions, Use Selected Fan first |
| H2 | The window at load | read `Found Fans` and `Last Action` 40 s after the install | the pinned summary (`This device's fan found at ...`) and the house fan's item with its mark; Last Action is the install's or the previous one, untouched by the search |
| H3 | A pick of this device's own fan | pick its item, Set (or `devctl.py set "Found Fans" "<item>"` with a dev build) | L4 `Already using fan ... at ...`; the row back on the summary; no network change |
| H4 | A search on demand | dev build: `devctl.py run "Dev Search"`, then `devctl.py log` | one window: two queries, at least one answer, `search=` in Dev State; nothing in Last Action |
| H5 | An unpinned device | add a throwaway Modern Forms Fan device in a test room, read it for 40 s, delete it (standing approval; never pick on it, or it would pin the house fan) | S2's new text; its `Found Fans` lists the house fan without a "this device" mark; its window does not disturb the house device |
| H6 | The follow still works | checklist step 45's stand-in (about 55 s, as passed in #58) | `Followed fan ...`; meanwhile no scheduler window (Dev State `search=standby`) |

Parked, because only time shows them (the owner's no-long-waits rule): the
`seek` cadence over hours on a device left unpinned, the behaviour of an open
Composer drop-down when the list changes underneath it (mitigated by writing
only on change), and K21's open-close churn over days.

## 7. Open questions for the contract

Each has a recommended default, so one word decides it.

| # | Question | Recommended |
| --- | --- | --- |
| Q1 | Keep a `Search again` item at the end of the list (the Hue driver has one; it is not an action) for an installer who powers a fan on while the device is already in `seek` (otherwise up to 15 min of waiting)? | yes |
| Q2 | A pick acts at once (B with the guard of 4.3.6) instead of waiting for Use Selected Fan? | yes |
| Q3 | No periodic search while the pinned fan answers (only the one at load)? The alternative is hourly. | yes, none |
| Q4 | Search at the `seek` cadence when `Fan Address` is emptied on a pinned device? F5's "never searched" was written for the follower, and the list is how the device is set up again. | yes |
| Q5 | Mark fans used by other devices of this driver through `SendToDevice` (4.3.2) in a later issue rather than now? | later |
| Q6 | No hidden `Find_Fans` alias in release builds; a `Dev Search` development command instead? | yes |
