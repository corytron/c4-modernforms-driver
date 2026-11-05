# Following the pinned fan to a new address (#39)

The contract for issue [#39](https://github.com/corytron/c4-modernforms-driver/issues/39):
the owner asked (2026-11-04) that once the driver has identified the fan, an
IP address change never needs a manual step. It rests on the read-only
research note [`edge-cases-address.md`](edge-cases-address.md) (ECA: the
evidence E1 to E16, the cases FA1 to FA17 and CA1 to CA19, the recommendation
in section 3). Where this file and ECA differ, this file wins; where it is
silent, ECA section 3 is the rule.

## 1. Decisions

| # | Decision | Basis |
| --- | --- | --- |
| F1 | **The device is pinned to a fan, not an address.** When the pinned fan is not at `Fan Address`, the driver asks the network for the pinned MAC by multicast DNS (the Find Fans query), reads the announced address once, read-only, and changes nothing before that read shows the pinned fan. | ECA 3.1; K10 (a Gen 3 fan's TXT record carries its MAC, verified on the house) |
| F2 | **Trigger:** the model's phase becomes offline (three failed polls, about 45 s), foreign, gen4 or notfan, while `Follow Address Changes` is On, `Fan Address` is not empty, the pin has a MAC (none is derived from the client id; review of #48), the typed address is not pending (F5), no Use Selected Fan read runs and the model is not stopped or rebooting. Not on the first failed poll. | ECA 3.2; owner question 2 (default: offline phase) |
| F3 | **Schedule:** windows as Find Fans runs them (query twice 1 s apart, 3 s of answers, closed between windows): the first 2 s after arming plus a slot of 3.5 s per device (device id mod 8) plus 0..0.5 s, then 30 s, 1, 2, 5, 10 min, then every 15 min, each ±20 %, never closer than 30 s; each follower draws from a generator of its own, seeded from the device id and the clock at its first arm (the id is read then, never at load), so two devices never step alike (review of #48); a candidate heard but not verified is read again at +10, +30, +90 s. Disarmed on online, waiting, unset, rebooting, a `Fan Address` edit, Off or stop. Memory only. | ECA 3.3 |
| F4 | **Match:** a heard entry whose TXT MAC equals the pin's, SRV port 80, a private (RFC 1918) or link-local address other than the current one, at most 3 a window; then one `queryStaticShadowData`, accepted only with HTTP 200 whose `clientId` and `mac` equal the pin's and the TXT MAC; checked again before each read (phase, switch, no owner edit or Use Selected Fan click since the window opened, guard). The read is the accept: a switch to Off during a read (at most 5 s) lets it finish. The model refuses a non-private address itself too. | ECA 3.4 |
| F5 | **The owner's typed address wins** until the pinned fan has answered there: after a `Fan Address` edit the follower is pending and stays off until a contact at that address succeeds. Typing the address the pinned fan was last seen at (the pin's address) is no such edit: the follower stays as it was, so typing the old address back resumes (v1-design 3.5; ECA CA3). An empty `Fan Address` is the stop switch: never filled, never searched. | ECA CA3, CA4; owner question 4 (default: stay off) |
| F6 | **What changes on a follow:** the model switches the transport address with a new epoch, the stored pin and firmware record, phase waiting (persisted first); then the driver writes the `Fan Address` row and Last Action L30. No new Status text, event, variable or command: programming sees one Fan Offline / Fan Online pair. A flap guard refuses a fourth follow in an hour (L31, once). | ECA 3.5, 3.6; owner question 5 (default: no event) |
| F7 | **A switch:** the property `Follow Address Changes`, LIST `On` / `Off`, default On, after `Found Fans`. | owner question 1 (default: the switch, On) |
| F8 | **Never:** a subnet scan, a read of an address nobody announced, a cloud lookup, adopting or learning another fan, matching by name, model, instance or address, acting on an announcement without the read, a public address, a standing listener, a window while online, rebooting, unset or before late init, touching `Found Fans` or the pick. | ECA 3.7 |
| F9 | **SECURITY.md** changes from "the fan the owner configured and nowhere else" to: the fan the owner configured, wherever its own multicast DNS answer puts it, after one fixed read-only request, private addresses only. The read checks identity; it does not authenticate (the client id and MAC are announced in the clear), the same exposure as a spoofed fixed address. | owner question 3 (default: yes) |

## 2. Modules (section 9 style of [`v1-design.md`](v1-design.md))

### 2.1 `fan/discovery.lua` (changed)

- `discovery.candidates(heard, mac12, current) -> { address, ... }`: pure;
  F4's first step over the window's `heard` list (at most 3, in the order
  heard).
- `find`'s callback gets a third value, `heard`: every distinct
  (instance, address) pair of the window, up to 64 (MAX_FOUND; `candidates` still reads at most 3), each `{ instance, address,
  mac, port }`, beside the unchanged first-answer-wins list (Find Fans and its
  spec stay as they are).

### 2.2 `fan/model.lua` (changed)

`m:follow(address, mac12, cb)`: `use_fan` restricted to the same fan. One
`queryStaticShadowData` to `address`; `cb("followed", { address, was })` after
the adoption of the "moved" path (new epoch, pin, `mf_identity`, firmware,
phase waiting, persisted before the callback); otherwise `cb("not_same")`,
`cb("no_answer")` or `cb("busy")` (a click's read under way, or the phase not
offline-like), never `now_using`. A refused read restores the previous address
exactly as a failed Use Selected Fan does. Nothing else in the model changes.

### 2.3 `fan/follow.lua` (new, pure)

```lua
local follow = require("fan.follow")
local f = follow.new({
	find = fn(cb(list, err, heard)),        -- discovery:find
	candidates = discovery.candidates,
	follow = fn(address, mac12, cb),        -- model:follow
	phase = fn() -> string,                 -- the model's phase
	identity = fn() -> pin|nil,             -- model:identity()
	address = fn() -> string,               -- the current Fan Address
	enabled = fn() -> bool,                 -- Follow Address Changes is On
	timer = fn(ms, cb) -> handle, now = fn() -> ms, random = fn() -> 0..1,   -- random: tests only; else its own
	seed = fn() -> number,                  -- the device id, read at the first arm: the slot and the generator's seed
	on_followed = fn(address, was),         -- driver.lua: the row, Last Action L30
	on_refused = fn(),                      -- the guard, L31 once
	log = log,
})
f:phase_changed(phase)   -- the model's listener.phase
f:address_edited()       -- the owner typed Fan Address: pending (F5), disarmed
f:clicked()              -- a Use Selected Fan click: the open window's candidates are dropped (F4)
f:contact()              -- a contact succeeded at the current address: pending cleared
f:switch(on)             -- Follow Address Changes
f:state() -> "off" | "idle" | "armed:N" | "pending"   -- Dev State
f:stop()
```

### 2.4 `fan/texts.lua` (changed; after #37's L22 to L29)

`texts.result` keys `followed` (L30: `Followed fan MF_00005E005301 to
10.0.2.152 (was 10.0.2.151)`) and `follow_refused` (L31: `Fan
MF_00005E005301 moved 3 times in an hour; not following`), at most 70
characters with 15-character addresses (exactly 70 with a `WAC_` id).

### 2.5 `driver.lua`, `driver.xml`, `fan/devcmds.lua` (the coordinator)

The property (F7) and its replay; the follower built after the model and
discovery; the model's `phase` listener and the contact feeding it; the
`Fan_Address` handler calls `f:address_edited()`; `on_followed` writes
`prop("Fan Address", address)` and `result("followed", …)`; `OnDriverDestroyed`
calls `f:stop()`; Dev State gains `follow=`. Find Fans clicked during a window
waits for it or shares it (one binding, one window).

## 3. Documents

ECA 3.8: [`v1-design.md`](v1-design.md) (V5, V5a, 2.5, 3.5, 7.2, 9.1, 9.5,
9.10, 14, 15), [`edge-cases-modernforms.md`](edge-cases-modernforms.md) (N1,
N3, Q3), [`edge-cases-control4.md`](edge-cases-control4.md) (D19),
[`composer-checklist.md`](composer-checklist.md) (steps 42 to 44),
`SECURITY.md` (F9), the manual (the DHCP reservation becomes a
recommendation: not required, the driver finds the fan again by itself,
usually within a minute or two, on one network segment, tried on Gen 3 only;
the passages that say it never follows), `CLAUDE.md`'s scope,
`CHANGELOG.md`, `docs/status.md`, `docs/README.md`.

## 4. Tests

The ladder on the fake timer (steps, jitter bounds, cap, retry, disarm on each
cause, nothing while online); `candidates` (MAC, port, private and link-local
only, not the current address, the cap, a lying public address, two addresses
for one instance); `model:follow` (same fan, another fan, silent, TXT/HTTP MAC
mismatch, a click's read under way, the epoch and pin after a follow); the
pending rule (and the old address typed back); the flap guard; the switch; the driver's wiring (a typed address that never answers, Off and On while armed, destroy while armed, a restart with the fan away); `fan_driver_spec.lua` end to end on
the fake (the fan stops answering at 10.0.2.151, announces 10.0.2.152, the
driver follows, `Fan Address` and Last Action read so); a Gen 1/2
announcement layout as a fixture (ECA E4).

## 5. Assumed until seen on the house

ECA section 5's K20 to K22: Gen 1/2 answer a query as Gen 3 does; the fan
re-announces after a lease change; about 100 window open-close cycles a day
are harmless on the controller; a driver-written `Fan Address` survives a
restart. The owner's rule against long waits holds: none of them blocks the
build.
