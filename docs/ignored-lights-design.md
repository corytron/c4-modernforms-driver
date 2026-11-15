# Which room lights the pause leaves out: the contract (#247)

The room-dark pause ([`room-dark-pause-design.md`](room-dark-pause-design.md))
pauses the fan's LED animations at night while every light in its room is
off. A relay that Control4 keeps on to power smart bulbs or an outlet
reports on around the clock, so it would keep the pause from ever starting.
In 1.11 the owner named those lights by hand in `Pause Ignores Lights`. The
owner wants the driver to work this out itself, very reliably
(2026-11-15). This contract says how. Its evidence comes from
[`ignored-lights-sdk-research.md`](ignored-lights-sdk-research.md), the
cases in [`edge-cases-ignored-lights.md`](edge-cases-ignored-lights.md), and
the house's keep-on programming in [`keep-on-design.md`](keep-on-design.md).

## 1. Decisions

| # | Decision |
| --- | --- |
| IL-D1 | **A light that Control4 programming keeps on is left out.** Such a light has an enabled *On* command, aimed at that same light, in the script of its own *Turned Off* event (light_v2 event 5101), and every item that encloses the command is enabled too. Its on state says nothing about whether the room is dark, and the programming is the installer's own statement that it must stay on. Conditions around the command (a maintenance switch, a cap) don't matter. |
| IL-D2 | **Read with `C4:GetCodeItems(proxy, 5101)`** [API 9_helper/_5.9-GETCODEITEMS.md, available from OS 3.3.0]. As measured on the house (OS 3.4.3, 2026-11-15), it returns `{ codeitems = { ... } }`. Each item carries `enabled`, `type` (1 command, 2 condition, 4 else), `device` (the light's proxy id for the *On*) and `cmdcond.xml`, and nests its children in `subitems`. The *On* is a type 1 item with `device` equal to the light's proxy id, whose XML holds `<command>ON</command>`. |
| IL-D3 | **Only positive evidence leaves a light out.** A failed read, an answer of the wrong shape, a Director without `GetCodeItems` (before OS 3.3.0), or a script with no matching *On* all mean the light counts. The worst a wrong "counts" can do is keep the pause from starting, which is how things were before 1.11. A wrong "left out" would pause the animations while a light is on. |
| IL-D4 | **Signals not used**, and why. *Buttons Control Load* and *Hide From Nav* can't be read: they travel only in the device's GET_PROPERTIES answer to Composer, not in the project XML (Composer round, 2026-11-15). Rocker links bound to another device, on/off-only lights and the energy counters (MINUTES_ON and MINUTES_OFF, undocumented) are all readable. But a lamp that only programming switches looks the same in every one of them, and a counter-based rule would need days of history. IL-D1 is exact and immediate, so these are left for later. |
| IL-D5 | **When it is decided:** at every scan of the room's lights. Scans happen at the start, each time the night window opens or closes, and when `Pause LED Animations` or `Pause Ignores Lights` changes. Programming added or removed during the day takes effect by the next window change at the latest, so always before the pause can start. One `GetCodeItems` call per room light per scan. |
| IL-D6 | **`Pause Ignores Lights` stays** with its 1.11 meaning: lights the dealer leaves out by hand, added to those of IL-D1. The driver never edits it. On the house it can be emptied once IL-D1 is seen working. |
| IL-D7 | **Composer shows the result** in a new read-only property, `Pause Leaves Out`, right after `Pause Ignores Lights`. It lists each light left out with its reason, `Name (id): kept on by Control4 programming` or `Name (id): in Pause Ignores Lights`, joined by `; `, or `None`. The scan's info line ("Room lights: N in this room (...)") is unchanged; one more info line, `Room lights: left out: ...`, says the same as the property. |
| IL-D8 | **A light that stops being left out**, because its keep-on programming was removed or disabled, counts again from that scan. Being on, it keeps the pause from starting. |

## 2. Interface (`src/modernforms_fan/fan/keepon.lua`)

A pure module: no C4 calls of its own.

- `keepon.EVENT_TURNED_OFF = 5101`
- `keepon.kept_on(items, proxy)` → `true` or `false`. `items` is what
  `GetCodeItems` returned. True only when IL-D1 holds: an enabled type 1
  item with `device == proxy` (number or numeric string), whose
  `cmdcond.xml` contains `<command>ON</command>` (case-insensitive, white
  space allowed inside the tags), and every enclosing item enabled.
  Anything malformed means false. Recursion is bounded to depth 32 and to
  2000 items.
- `keepon.check(proxy, get)` → `kept, why`. It calls `get(proxy, 5101)`
  under `pcall`, where `get` wraps `C4:GetCodeItems`. Returns
  `true, "kept on by Control4 programming"`, or `false` with one of
  `"no keep-on programming"`, `"programming unreadable: <error, cut to 80
  characters>"` or `"programming unreadable: not a table"`.

The driver (coordinator) skips a light in `lights()` when it is in
`Pause Ignores Lights` or `keepon.check` says kept. It writes
`Pause Leaves Out` after each scan, and adds the property to
`fan/ledrows.lua`'s row list after `Pause Ignores Lights`.

## 3. Verified on the house

To be recorded on #247: after the update, `Pause Leaves Out` names both
relays as kept on by programming; with `Pause Ignores Lights` emptied, the
scan still counts 6 lights; and the pause starts at night with those 6 off.
