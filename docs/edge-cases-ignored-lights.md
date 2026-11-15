# Which room lights the pause counts, and the always-on relays: the edge cases

> **Research (2026-11-15) for [issue #247](https://github.com/corytron/c4-modernforms-driver/issues/247)
> and [issue #248](https://github.com/corytron/c4-modernforms-driver/issues/248)**,
> desk research only: nothing was sent to the controller, the switches, the
> Hue bridge, the dev server or the fan while writing it. Two features:
>
> - **A (#247).** The room-dark pause of 1.11
>   ([`room-dark-pause-design.md`](room-dark-pause-design.md), RD-D1 to
>   RD-D13) decides by itself which of the room's lights it leaves out, in
>   place of (or beside) the hand-filled `Pause Ignores Lights`.
> - **B (#248).** An automation on the house keeps the two relay switches
>   that feed smart bulbs and an outlet on: on at project load and after
>   reboots, back on at once when turned off, a periodic check, and nothing
>   else.
>
> Two sibling notes are written at the same time: which of the candidate
> signals Lua can read, and which mechanism B uses (Composer programming or
> a driver). This note is the **lifecycle side** of both: every corner case,
> with a decision for each, judged against a recommended rule (section 1.2).
> Every decision holds whichever subset of signals turns out readable and
> whichever mechanism B uses, unless the row says otherwise. The fan itself
> plays no part, except that its light is one of the room's lights.

**The decisions in short.**

1. **Leave a light out only on positive evidence; count it when unsure.**
   Counting an always-on light costs only the pause (the behaviour before
   #247); leaving a real light out pauses the chase while it lights the room,
   which the owner does not want. A signal the driver cannot read is no
   evidence, never evidence of absence.
2. **Four sources, in this order.** The owner's lists (a new "always count"
   list beside `Pause Ignores Lights`; count wins when a light is in both);
   the project's own keep-on rule for that light (B); Control4's own settings
   that say the device is a keypad and not its load's control, together with
   the light observed on without a real break for days; otherwise the light
   counts (section 1.2).
3. **B's rule is A's best evidence.** The relays B keeps on are by
   definition power feeds. If B's set is readable (a fixed programming shape,
   or a variable a driver publishes), A leaves those lights out from the
   moment the rule exists, through restarts, with no waiting.
4. **Settings alone never suffice.** "Buttons Control Load" off, keypad mode,
   bound rockers and "Hide From Nav" are also exactly how a lamp switched
   only by programming is set up (IA24). They need the observed always-on
   behaviour beside them, and only a relay (a light with no Brightness
   variable) qualifies.
5. **Short offs are not breaks.** A relay turned off by an All Off scene and
   back on by B within minutes keeps its evidence; otherwise every bedtime
   would restart the clock and the pause would flap (IA10, IX2).
6. **Re-decided at every scan and at every report of that light**, so a
   setting changed back, a rule disabled or a light switched off counts again
   at once or within the scan interval.
7. **The 1.11 list stays** with its meaning unchanged and is never cleared,
   converted or narrowed by the driver (IA40).
8. **The owner sees which lights are left out and why**, and gets hints that
   are never acted on (IA42, IA43).
9. **B never fights a person, a protection or a loop.** One documented way
   to suspend it that survives restarts and never ends by itself; a cap on
   how often it turns a light back on within an hour; no blind periodic ON;
   one log line per episode (sections 3.3 to 3.5).
10. **The night outage risk is the Hue bulbs', not B's.** By default a Hue
    bulb that gets power back lights warm white at full brightness. Whatever
    turns the relay back on (its own firmware or B) then lights the room in
    the middle of the night. The cure is each bulb's power-on behaviour, set
    in the Hue app, never written from this project (KB4).

**Decisions:** **A** automatic (the driver or the automation does it by
itself), **O** offered (a setting, a hint, the manual, a Windows-session
round), **F** forbidden without a click (or never, where the row says so).

**Markers:**
- **VERIFIED-code** names a file and line in this repository, read on
  2026-11-15. Other agents are editing the checkout, so lines may move.
- **VERIFIED-doc** names an SDK file or a Control4 page; Snap One's text is
  paraphrased, never quoted.
- **MEASURED** is a measurement on the house, from the note that recorded
  it.
- **COMMUNITY** is a public non-vendor source (an open-source library, a
  forum, the press). Signify's own CLIP v2 reference is behind a login and
  was not read.
- **INFERRED** is reasoning from the above; **ASSUMED** has no source yet;
  **UNKNOWN** needs a read or a check on the hardware.

Placeholders only: `Example Switch (123)`, `Example Lamp (124)`; controller
10.0.2.10.

| Key | Source |
| --- | --- |
| RDP | [`room-dark-pause-design.md`](room-dark-pause-design.md): RD-D1 to RD-D13, RE1 to RE15, the interface of `fan/roomdark.lua` |
| ECC | [`edge-cases-control4.md`](edge-cases-control4.md): facts F19 to F26 (programming, devices, bindings, persistence, updates) |
| STATUS | [`status.md`](status.md): the house's room lights and the 1.11 install |
| KLD | [`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md), section 1.2: the house's keypad dimmer and switches |
| KLV | [`keypad-leds-visibility-sdk-research.md`](keypad-leds-visibility-sdk-research.md): which reads of another device exist on OS 3.x |
| MIN | [`edge-cases-min-on.md`](edge-cases-min-on.md): MT11, the store after a restore onto a new controller |
| API, FUND, LV2 | Snap One's references under `~/c4-tools/reference/`: `docs-driverworks-api/source/includes/`, `docs-driverworks-fundamentals/source/includes/`, `docs-driverworks-proxyprotocol-lightv2/source/includes/` |
| BP | FUND `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md` (and `_51-LIGHTV2EXTRAS.md`, which has nothing on this subject) |
| C4-SW | Composer Pro help, device settings for switches: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/device_settings_for_switches.htm> (read 2026-11-15) |
| C4-DIM | Composer help, device settings for dimmers: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerhe_userguide/device_settings_for_dimmers.htm> (read 2026-11-15) |
| C4-SW-IG | Installation guide of the C4-SW120277 switch (PDF): <https://docs.control4.com/docs/product/wireless-switch-120v-277v/installation-guide/english/latest> (read 2026-11-15) |
| C4-CONNECTS | Control4's "Connects with Control4" automation guide (PDF): <https://docs.control4.com/docs/product/connects-with-control4-automation-guide/brochure/english/latest> (read 2026-11-15) |
| AIOHUE-F, AIOHUE-L | The `aiohue` library's CLIP v2 models, `feature.py` and `light.py`: <https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/feature.py>, <https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/light.py> (read 2026-11-15) |
| OPENHUE | The community OpenAPI description of CLIP v2, `src/light/schemas/Powerup.yaml`: <https://github.com/openhue/openhue-api/blob/main/src/light/schemas/Powerup.yaml> (read 2026-11-15) |
| HA-PU | Home Assistant community thread on Hue power-on behaviour through the bridge: <https://community.home-assistant.io/t/control-philips-hue-power-on-behavior-via-hue-bridge/817293> (read 2026-11-15) |
| MR-2018 | MacRumors, 2018-12-13, the Hue app's per-light power-on setting: <https://www.macrumors.com/2018/12/13/philips-hue-ios-app-power-outage/> |
| HUE-EC | The Hue project's Hue-side edge cases, "Bulb unreachable": <https://github.com/corytron/c4-hue-driver/blob/main/docs/edge-cases-hue.md> |

## 0. Facts the decisions rest on

| # | Fact | Status |
| --- | --- | --- |
| IF1 | The room's lights are every `light_v2` proxy in the fan item's room, from `C4:GetDevices({ C4iNames = "light_v2.c4i" }, room)`, read again at late init, when `Pause LED Animations` or `Pause Ignores Lights` is set, at sunrise and sunset, and every 6 hours. A light whose proxy id or protocol id is in `Pause Ignores Lights` is left out. | VERIFIED-code: `src/modernforms_fan/driver.lua:517-551`, `:922`, `:1054-1063`; RDP RD-D3, RD-D13 |
| IF2 | `GetDevices` gives, per light proxy, its name, its room and a `protocol` sub-table with the protocol device's id and driver file (the reference's example is a keypad dimmer's `combo_dimmer.c4i`). On the house the filter is a comma-separated string. | VERIFIED-doc: API `22_miscellaneous/_9-GetDevices.md`; ECC F20 |
| IF3 | The house: the fan's room has 8 lights: the load of a keypad dimmer (C4-KD120, `combo_dimmer.c4i`), two switches of the C4-SW120277 family (`switch_gen3.c4i`, firmware 5.1.1) set up as two-button keypads, four devices of the Hue driver and the fan's own light. The two switches are relays that feed Hue bulbs and an outlet; their Light State reads 1 day and night. Since build 251 they are in `Pause Ignores Lights`, so 6 lights count. | MEASURED: STATUS (the #233 and #240 item; 1.11 build 251); KLD section 1.2 |
| IF4 | Light State (variable 1000) is true while the brightness is not at the Off preset. On a switch only that variable exists; a dimmer also has Brightness Percent (1001) and the rest. Setting Light State true on a dimmer takes it to its On preset. | VERIFIED-doc: LV2 `30_Light_v2_variables/_0-HEADER.md` |
| IF5 | `GetDeviceVariable` returns nil for a variable that does not exist. `RegisterVariableListener` fails for one, and otherwise reports at once after it is set. | VERIFIED-doc: API `36_variable/_5-GetDeviceVariable.md`, `_10-RegisterVariableListener.md` |
| IF6 | Composer's settings of a Control4 switch: *Buttons Control Load* (the device directly controls its electrical load), *LEDs Follow Load* (the LEDs show the load's state), *Use as 2 Button Keypad* (the device is set up and programmed as a two-button keypad; per button an LED behaviour that follows the bound device or the load, or shows push and release), *Hide From Nav* (hidden from Navigators once they are refreshed), and a view-only *Energy Information* (minutes since the last off and the last on, minutes on today, the power drawn now, the energy used, lifetime and today). Dimmers have the same rows. | VERIFIED-doc: C4-SW, C4-DIM (paraphrased) |
| IF7 | No OS 3.x API is documented to read another device's Composer settings. `GetDeviceData` returns the first two levels of a device's `<devicedata>`, its driver definition. `GetDeviceVariables` returns a device's variables, but no document lists a Control4 switch's. `GetProjectItems` returns the project as XML, with filters, but not what a device's entry holds. `GetCapabilityById` and `GetDriverConfigInfoById` are 4.0 and 4.2. What Lua can read is the sibling note's. | VERIFIED-doc (silent): API `22_miscellaneous/_8-GetDeviceData.md`, `_12-GetDeviceVariables.md`, `_17-GetProjectItems.md`; KLV, "Every candidate signal" |
| IF8 | Bindings: `GetBindingsByDevice` (3.0.0, by proxy id) lists a device's bindings; `GetBoundConsumerDevices` a provider binding's consumers. `OnBindingChanged` reaches a driver for its own control bindings only, and whether it comes at a start is undocumented. | VERIFIED-doc: ECC F20, F22 |
| IF9 | Programming is readable, never writable: `GetAllCodeItems` and `GetCodeItems(device, event)` (3.3.0) give each code item's enabled flag, type, target device, display text and command XML, with nested items. | VERIFIED-doc: API `9_helper/_5.5-GETALLCODEITEMS.md`, `_5.9-GETCODEITEMS.md`; ECC F19 |
| IF10 | A light's events for programming and other drivers include Light On (5100) and Light Off (5101). | VERIFIED-doc: LV2 `25_light_v2_events/_0-HEADER.md` |
| IF11 | Persisted data is saved in the project and its backups, survives updates and belongs to the device id; drivers should not write it often. After a restore onto a new controller the store may come back empty. | VERIFIED-doc: ECC F25; ASSUMED: MIN MT11 |
| IF12 | A light proxy starts online, and offline disables its UI. When a Hue lamp loses power the bridge's light resource does not change; the Hue driver takes the device offline and keeps its last level, so its Light State keeps its last value. | VERIFIED-doc: LV2 notifications `_15-ONLINECHANGED.md`; HUE-EC; RDP RE4 |
| IF13 | `GetBootID` (3.3.0) changes at every boot of the controller, so a driver can tell a reboot from a Director restart. | VERIFIED-doc: API `9_helper/_5.7-GETBOOTID.md` |
| IF14 | The C4-SW120277 guide: stand-alone, the top button turns the load on and the bottom one off; tap sequences for identify, Zigbee channel, reboot (15 taps), factory reset (9-4-9) and leave mesh and reset (13-4-13); for servicing, the breaker is switched off. It says nothing on the relay's state when power returns and names no air gap. | VERIFIED-doc: C4-SW-IG (paraphrased) |
| IF15 | What a Control4 relay does when power returns is not in Control4's documents. Forum users report switches and dimmers going back to their state before the outage (a search summary of <https://www.c4forums.com/topic/29479-disabling-c4-dimmerswitch-memory-after-power-loss/>, a thread that refused automated reads). | UNKNOWN (COMMUNITY, not read) |
| IF16 | Control4's own examples build "All On" and "All Off" as Advanced Lighting scenes that include every light, and run Room Off as a separate command beside them (a keypad's Media Off button, a good-night routine). | VERIFIED-doc: C4-CONNECTS |
| IF17 | A CLIP v2 light may carry `powerup`: a `preset` of `safety`, `powerfail`, `last_on_state` or `custom`; `configured`, whether the lamp has taken the values shown; and, with `custom` only, an on mode (`on`, `toggle`, `previous`), a dimming mode (`dimming`, `previous`) and a colour mode (`color_temperature`, `color`, `previous`). `previous` means the state before the power was cut; `toggle` alternates at each power cycle. | COMMUNITY: AIOHUE-F, AIOHUE-L, OPENHUE |
| IF18 | As users describe the presets: `safety`, the default, is warm white at full brightness; `powerfail` returns the last colour and brightness; `last_on_state` the last on or off; `custom` what was set. The Hue app has offered this per light as "power-on behaviour" since late 2018; older lamps may not support it, and the setting is said to live in the lamp. | COMMUNITY: HA-PU, MR-2018 |
| IF19 | The pause: inside the window (sunset to 30 minutes after sunrise), paused while at least one light counts and every counted light is known off; an unknown light keeps it from starting; any counted light on ends it. | VERIFIED-doc: RDP RD-D5 to RD-D7 |
| IF20 | Today a light whose listener cannot be set is left out, with one warning, and tried again at the next scan. | VERIFIED-code: `src/modernforms_fan/fan/roomdark.lua:342-367`; RDP RD-D4 |

## 1. The evidence

### 1.1 The signals

What each candidate signal says, what it cannot say, and how it changes
over the life of the system. "Notice" is how soon the driver can learn of a
change; "the next scan" is at most 6 hours away (IF1).

| # | Signal | Says | Does not say | Changes when | Notice | Role in section 1.2 |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | *Buttons Control Load* off | the device's own buttons do not switch its load | that nothing else switches it (programming, scenes, Composer, a Navigator) or what the load is | a dealer edits it; a factory reset or replacement may bring defaults back (ASSUMED) | none documented: the next scan or report | required for C |
| S2 | *Use as 2 Button Keypad* on | its buttons are a keypad for other things | anything about the load | edited | none documented | C needs S2 or S3; S2 readable and off contradicts |
| S3 | Its buttons bound to other devices' links | the same, from the bindings (IF8) | anything about the load | bound or unbound in Connections | none for other devices; `OnBindingChanged` when bound to the fan's own links | alternative to S2 |
| S4 | LED behaviour follows the bound device, *LEDs Follow Load* off | its LEDs do not show the load | anything about the load | edited | none documented | if readable, "follows the load" contradicts |
| S5 | *Hide From Nav* ticked | nobody switches it from a Navigator | programming, scenes, Composer, voice | edited | none documented | if readable, unticked contradicts |
| S6 | Energy counters: minutes on since the last off | how long it has been on without any off | why; resets at every off, however short | every off | none documented | may seed S8, never alone |
| S7 | A switch: no Brightness Percent (1001), or its protocol file | a relay: on means full power on the load | what is wired to it | replacement | at the scan (IF4, IF5, IF2) | required for C |
| S8 | Observed: Light State on with no break longer than G, for N | the driver's own watch of S6, under the grace rule | why | every report | at once | required for C |
| S9 | A keep-on rule for that light (B) | the project keeps it on: a power feed | what is wired, strictly | the rule edited, disabled or deleted | none documented: the next scan or report | R: sufficient |
| S10 | The owner's lists | the owner's word | — | set in Composer | at once (a scan) | K: final |

### 1.2 The rule the cases are judged against

Recommended for the contract. For each light the scan finds in the room:

1. **K, count.** In a new list of lights that always count: counted. This
   wins over everything below, and over the ignore list when a light is in
   both (the safe direction).
2. **K, ignore.** In `Pause Ignores Lights`: left out (1.11's meaning).
3. **R, the keep-on rule.** The project keeps the light on: B's set names it
   and B is not suspended for it. Read as B publishes it: if B is
   programming, an enabled code item on that light's Light Off event (5101)
   that turns the same light on (IF9, IF10); if B is a driver, a variable
   it publishes for that purpose (IF5). Left out at once.
4. **C, Control4's configuration with its behaviour.** All four of: S7 (a
   switch); S1 (its buttons do not control its load); S2 or S3 (its buttons
   serve as a keypad); and S8 (on with no break longer than G for at least
   N). Neither S4 nor S5, where readable, may contradict. Left out.
5. **Otherwise counted**, including a light that cannot be read, cannot be
   watched (IA29) or reports nothing.

A signal the driver cannot read is no evidence. A signal it can read that
contradicts always counts for counting. The evidence is decided again at
every scan, at every report of that light, and (when the fan's own links are
involved) at `OnBindingChanged`. N and G are the owner's to set
(IQ3); this note's cases use the recommended N = 7 days and G = 15 minutes.

### 1.3 What each readable subset allows

| Readable (beyond what 1.11 reads) | What the rule can do | Decision |
| --- | --- | --- |
| Nothing | K only. S8 alone may feed a hint (IA13), never a leave-out | A for K; O for the hint |
| Programming (IF9), and B is programming of the fixed shape, or B is a driver that publishes its set | K and R: the house's two relays left out from the moment B exists | A |
| S7 and S1, with S2 or S3 | C as well, after N | A |
| S4, S5 too | C made stricter (more ways to contradict) | A |
| S6 | Seeds S8 at the first sight of a light, so C need not wait N after an install | A |
| S1, with S2 or S3, but not S7 | C cannot tell a relay from a dimmer, so it is not available: a dimmer must never qualify (IA21, IA27) | F: C without S7 |

## 2. Feature A: which lights the pause counts

### 2.1 Settings changed later

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| IA1 | *Buttons Control Load* turned on again | C lapses at the next scan or the light's next report; counted from then. R and K do not change. If K still leaves it out, Status and one log line say so: "Pause Ignores Lights leaves out Example Switch (123), whose buttons now control its load" | A (C); O (the hint); F (removing it from K) | The device is again its load's control. K is the owner's word and only the owner edits it |
| IA2 | *Hide From Nav* unticked | Where S5 is readable, C lapses as in IA1 | A; O (hint for K) | People can now switch it from a Navigator |
| IA3 | *Use as 2 Button Keypad* turned off | Where S2 is readable, C lapses, even if bindings remain (S3); what Composer does with the bindings is UNKNOWN | A | A contradiction counts for counting |
| IA4 | Rockers rebound to other links | S3 still holds: nothing changes | A | — |
| IA5 | Rockers unbound | With S2 readable and on, C holds (a keypad without bindings is still not a light switch); with only S3, C lapses | A | S3 was the only evidence of keypad use |
| IA6 | Rockers bound to the same light's own links | S3 is false: the buttons control the load through a binding; counted | A | Equivalent to *Buttons Control Load* on |
| IA7 | Rockers bound to the fan's own links | `OnBindingChanged` reaches the fan driver, which re-decides that light at once | A | Cheap and documented (IF8) |
| IA8 | *LEDs Follow Load* on while the buttons are bound elsewhere | S4 contradicts: counted unless R or K | A | Someone wants to see the load's state, as on a light switch |
| IA9 | A setting changed with no event | Decided at the next scan or report, at most 6 hours. A light left out by C is on and stays on, so the delay only matters until it is switched, and its report re-decides at once | A | The owner's rows force a scan at once (IF1) |

### 2.2 The observed duration (S6, S8)

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| IA10 | Off for less than G, then on again (an All Off scene and B; the Composer Control tab) | The observation goes on; the light stays left out. Off, it would not keep the pause from starting anyway | A | Otherwise every bedtime All Off would restart N and the pause would flap (IX2) |
| IA11 | Off for longer than G (maintenance, B suspended or failing) | The observation starts again at the next on; counted for N; Status says until when ("counted until 22 Nov: off for 2 h on 15 Nov") | A | The safe direction; R does not have this delay |
| IA12 | The energy counter restarts at every off (S6) | Used only to seed S8 when the driver first sees the light; it never resets S8 | A | S6 knows no grace |
| IA13 | On for N or more, but S1 or S7 cannot be read | Counted. Status and one log line offer: "Example Switch (123) has been on for 9 days without a break: if it only powers smart bulbs or an outlet, pick it in Pause Ignores Lights" | A (count); O (hint) | Behaviour alone is not positive evidence: a lamp left on for a week still lights the room |
| IA14 | The record of S8 | One persisted record per light (on since, last seen on), written only when that changes, deleted when the light leaves the room | A | IF11: rare writes; a restart must not restart N (IA34) |

### 2.3 The room's membership and names

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| IA15 | A light added to the room, or moved in | Counted from the next scan (RDP RE1); R and K apply at once, C after N (or at once with S6) | A | — |
| IA16 | A light moved out, or deleted | Dropped at the next scan with its listener (RE2) and its S8 record. Entries for it in K stay, inert; Status names them as "not in this room" | A; F (editing K) | K is the owner's text |
| IA17 | A light renamed | Everything is keyed by device id; the new name shows from the next scan | A | — |
| IA18 | The fan item moved to another room | A new set (RE3); the old room's S8 records dropped; K entries inert | A | — |

### 2.4 Devices replaced, swapped, removed, reset

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| IA19 | Switch replaced through Composer's *Replace Legacy Control4 Device* | The project's device, and its id, stay (ASSUMED); K and R hold; S6 starts from zero on the new hardware; S8 holds if the relay stays on. If the new hardware arrives with default settings (S1 on, keypad off), C lapses and the light counts | A | The safe direction |
| IA20 | Replaced by deleting and adding a device (new id) | A new light: counted until R (B must be pointed at it anyway), K (the owner picks it) or C after N. Its old id in K is dead; Status names it | A; O (the hint) | No guessing that the new device is the old one |
| IA21 | Switch swapped for a dimmer | A dimmer never qualifies for C (S7); counted unless R or K | A; F (C for a dimmer) | A Control4 dimmer is not made to feed smart bulbs or an outlet (INFERRED); an always-on dimmer is more likely a lamp left on |
| IA22 | Switch removed | As IA16; B's own case is KB18 | A | — |
| IA23 | Factory reset or leave mesh at the switch (IF14) | Offline; its Light State keeps its last value (IF12). Back in the project, its settings may come back as defaults until Composer sends them again (ASSUMED): C lapses, the light counts | A | — |

### 2.5 Lights whose settings mean something else, or cannot be read

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| IA24 | **A lamp switched only by programming** (hidden, its buttons do not control it, keypad mode, a schedule switches a real lamp) | S1, S2 and S5 all point at "not a light switch", but S8 never reaches N: the schedule turns it off every day for hours. Counted. If it is forgotten on for N, C leaves it out until its next off longer than G: a narrow false leave-out, which is why N is days, not hours, and why Status names every light left out | A; F (leaving out on settings alone) | It is a real lamp. Settings cannot tell it from a power feed; only its behaviour can |
| IA25 | A switched outlet feeding a lamp without a switch of its own | Switched by people or programming: as IA24, counted | A | It is the lamp's switch |
| IA26 | A switched outlet that is always on, feeding a lamp with its own switch | C may leave it out. That lamp's light was never visible to Control4 (RDP RD-D3: loads not in Control4 do not count): leaving the relay out loses nothing Control4 knew | A; O (the manual says so) | Counting it would only mean never pausing. What is on the house's outlet is IQ5 |
| IA27 | A keypad dimmer used as a keypad | A dimmer: counted (S7). On the house its load is one of the 6 lights that count, which is right | A | IA21 |
| IA28 | A light hidden from Navigators for other reasons (a closet light on a motion sensor, a lamp only programming uses) | S5 never suffices: counted | A | Hidden is not dark |
| IA29 | A light that cannot be watched (no variable 1000, the listener refused) | Today it is left out with a warning (IF20): a leave-out without evidence. Recommended: it counts as unknown, which keeps the pause from starting; Status names it; K can leave it out | A (a change to RD-D4; IQ4) | The owner's rule: when unsure, count |
| IA30 | Lights whose settings cannot be read: third-party `light_v2` drivers, the Hue driver's lights, zone lights and scenes, the fan's own light | No C. Counted unless R or K. A Hue scene device counts as on while its scene is active, which is right: its lamps are lit | A | — |
| IA31 | A relay that feeds smart bulbs Control4 does not know | Leaving the relay out hides nothing Control4 could see; counting it means never pausing. R, K and C apply as usual | A; O (the manual: import such bulbs into the same room) | RD-D3 |
| IA32 | A light that never reports | Unknown keeps the pause from starting (RE13), as today | A | — |
| IA33 | Old `light.c4i` proxies | Out of scope, as in RD-D3 | — | — |

### 2.6 Restarts, reboots, restores

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| IA34 | Driver update or Director restart | The late-init scan: K at once; R if programming is readable at late init (IQ10); C from the persisted S8 record. A second scan a few minutes after the start catches what arrives late (settings, bindings, Zigbee state). Until R is read a relay counts and, being on, keeps the pause from starting: no blip | A | Nothing is lost by a restart; nothing guesses |
| IA35 | Controller reboot (`GetBootID` changed, IF13) | As IA34. Zigbee switches may report late. The time the driver was not running is not a break when the light was on before it and is on after it | A | The driver saw no off. A strict alternative restarts N after every gap; the owner may prefer it (IQ3) |
| IA36 | Power outage | The relays lose power with everything else. The outage is not a person switching them: the gap rule of IA35 applies once they are on again | A | — |
| IA37 | Project restored from a backup, same controller | K and R come back with the project; the S8 records from the backup (old times); the gap rule applies | A | IF11 |
| IA38 | Restored onto a new controller | The store may be empty: C waits N again (or S6 seeds it); K and R hold | A | IF11 |
| IA39 | OS 4.x | The same rule; the 4.x-only reads (IF7) are not needed | A | — |

### 2.7 The 1.11 list on the house (migration)

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| IA40 | `Pause Ignores Lights` already names the house's two relays | Kept, its meaning unchanged: the owner's list wins over every automatic decision except the count list. When R or C also leaves one of its lights out, one log line says so ("Example Switch (123) is also left out by its keep-on rule"), so the owner may empty the list later by a click | A (keep); O (empty it); F (clearing, converting or narrowing it by the driver) | It is the only evidence that works on the first day: R needs B, C needs N days. A property must not be retyped in an update (ECC F2) |
| IA41 | A light in both lists | Counted, and Status says so | A | The safe direction |

### 2.8 What the owner sees

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| IA42 | Which lights are left out and why | A read-only row within Composer's 75 characters ("6 count, 2 left out: 1 keep-on rule, 1 your list"), and the names in the `Room lights:` log line with their reasons. A change of a light's decision is one line at always ("Room lights: Example Switch (123) left out: its keep-on rule turns it back on"; "counted again: off for 2 h") | A | #247 asks for it; decisions change a few times a year |
| IA43 | Hints | IA1, IA13, IA20, IA29: shown and logged once per change, never acted on | O | A hint the driver acted on would be an automatic decision without evidence |

## 3. Feature B: keeping the relays on

Whatever the mechanism, B commands the relay's light proxy (ON), reads its
Light State, and nothing else. It never changes a switch setting.

### 3.1 The start: project load, Director restart, controller reboot

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| KB1 | Project load or Director restart | One ON to each kept-on relay, as the owner asked, unless keep-on is suspended for it (KB8). The relays keep their state through a Director restart (INFERRED: the Zigbee devices are not restarted), so the ON normally changes nothing. A check a few minutes later | A | Whether an ON to a relay already on fires Light On or makes radio traffic is IQ8 |
| KB2 | Controller reboot | As KB1. The Zigbee mesh may need minutes, and an ON sent before it is ready may be lost: checks at about 2 and 10 minutes after the start, then the periodic one | A | — |
| KB3 | Light State stale or unknown at the start | No decision is taken from it: the start ON covers it, the later checks read again | A | The proxy may hold the value from before the restart (ASSUMED) |

### 3.2 Power outage and the Hue bulbs' power-on behaviour

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| KB4 | **Power returns at night** | The relay comes back on or off by its firmware (IF15); if off, B turns it on. Either way the Hue bulbs behind it get power and do what their power-on behaviour says (IF17, IF18). With the default, warm white at full brightness, the room lights up in the middle of the night, and the pause resumes (rightly: the room is lit) | O: each bulb's power-on behaviour set to come back as it was (the Hue app's power-loss recovery or last-on-state, or `custom` with `previous` for on, dimming and colour); F: this project writing to the Hue bridge; F: B delaying the ON until morning without the owner's word | The bulb decides, not the relay. Which preset keeps an off bulb off is to be read and checked (IQ6) |
| KB5 | Several cuts in a row (a flicker) | Each cut is a power cycle for the bulbs | F: the `toggle` on mode | It alternates on and off at each cycle (IF17) |
| KB6 | A bulb without `powerup`, or with `configured` false | Its power-on behaviour cannot be relied on | O: the read of IQ6 lists them | Older lamps may not support it (IF18) |
| KB7 | The outlet feeds network gear (a bridge, a hub) | A relay off takes it offline, with every device behind it; the Hue driver shows its devices offline. B restores power at once | A | What is on the house's outlet is IQ5 |

### 3.3 Turned off: on purpose, by scenes, by a protection

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| KB8 | Turned off on purpose for maintenance | B would turn it back on at once and fight the person | O: one documented way to suspend keep-on, per relay or for all, which survives restarts, reboots and restores, and a way back; while suspended B sends nothing, the start ON included. F: B re-energising a suspended relay; F: a suspension that ends by itself | Safety: someone may be working on the fixture. The manual says what the installation guide says: electrical work starts at the breaker, not at the switch (IF14) |
| KB9 | The rockers | With *Buttons Control Load* off they do not switch the load (IF6). If it is turned on again, the bottom rocker turns the load off and B turns it back on: the device fights its user | O: where S1 is readable, a hint in Status and the log ("Example Switch (123): its buttons control its load again; keep-on fights them") | Never a silent suspension either: the owner decides |
| KB10 | An All Off scene, Room Off programming or another lighting scene includes the relay | B turns it back on at once. The bulbs behind it lose and regain power: with "previous" they may come back on if the cut reached them before the scene's own Hue command (a race), so the scene seems not to turn them off; with the default they come back bright. The scene's tracking reads not active | O: take the relays out of every scene, All Off and Room Off programming, with the Hue lights in their place (a Windows-session round; Room Off itself is a media command unless programmed, IF16); F: B editing scenes (no API, IF9) | B cannot fix what the scene does; the scene must not cut the power |
| KB11 | A voice assistant's "turn off the lights" | As KB10 if the relays are exposed to it; whether *Hide From Nav* hides them from voice is UNKNOWN | O: hide or remove them from voice (IQ9) | — |
| KB12 | **A protection or a loop turns it off again and again** (the switch's fault detection, an overload, programming that turns it off when it comes on) | B stops after K re-ons within an hour (recommended 3), keeps it suspended, and says so once in Status and the log; a click resumes it | A (stop); O (resume); F (unbounded re-ons) | Fault detection exists on these switches (C4-SW); whether a fault switches the load off is ASSUMED. Overriding a protection forever is a hazard |

### 3.4 The device's life

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| KB13 | Firmware update of the switch (Control4 updates its Zigbee devices) | The device restarts; whether the relay drops for a moment is UNKNOWN. If it does, the bulbs power-cycle (KB4) and B may need to turn it on | A (KB16's retries); O: firmware updates by day | — |
| KB14 | Reboot, factory reset or leave mesh at the switch (IF14) | Offline, then back; the relay as its firmware decides; a factory reset may bring *Buttons Control Load* back on (ASSUMED; KB9) | A (KB16) | — |
| KB15 | An air gap pulled | None on the C4-SW120277 (IF14). On a model that has one: offline (KB16), then as at power-up | A | — |
| KB16 | **Offline** (Zigbee lost, breaker off) | An ON cannot be confirmed (no acknowledgement reaches Lua, ASSUMED). After an ON, Light State is read again after about 10 s; still off, retried at 1, 2, 5 and 15 minutes, then at the periodic check. One log line when the episode starts and one when the relay answers again; Status names it meanwhile | A; F (tight loops, a line per retry, errors raised into Director) | Log spam and radio traffic help nobody |
| KB17 | Replaced with the same device id | B goes on | A | IA19 |
| KB18 | Replaced with a new id, or removed | Programming that names a deleted device: what Composer does is undocumented (ECC section 2.2). A driver holding a dead id: one log line and a Status line, no more commands to it, until its setting changes | A (stop); O (name the new one); F (guessing the new one by name or room) | "Must not error forever" |
| KB19 | Two relays | Handled one by one: one offline never delays the other | A | — |
| KB20 | A dimmer among the kept-on lights | An ON takes a dimmer to its On preset (IF4), which would then have to be 100 %; recommended: B for switches only | O; F (B setting a dimmer's preset) | B changes no setting |

### 3.5 The periodic check

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| KB21 | Its cost | It reads Light State (Director's own value, no radio traffic) at an interval the owner sets (recommended 15 minutes) and sends ON only when it reads off. On: nothing sent, nothing logged, no event | A; F (a blind ON every interval) | "Otherwise does nothing"; a blind ON would fire Light On programming and make radio traffic (IQ8) |
| KB22 | Light On programming on the relay | B's ON fires it like any other ON | O: keep none there; the Windows-session read of IQ9 lists any | IF10 |
| KB23 | Clock changes, daylight saving | Timers run on intervals: no case | A | — |

## 4. A and B together

| # | Case | What happens | Decision | Why |
| --- | --- | --- | --- | --- |
| IX1 | **B's rule is A's evidence** | A leaves a relay out from the moment B keeps it on (R), at once and through every restart. The contract fixes how A reads B's set: the programming shape (event Light Off on the relay's light proxy, an enabled command that turns the same proxy on) or a variable a B driver publishes | A | One source of truth, set once by the owner (#248 names the relays) |
| IX2 | **The relay off for seconds, then on again by B, at night** | Left out (K, R, or C with its grace): no effect on the pause. Counted (no evidence): if every other light is off, the pause starts during the seconds off and ends when B turns it on ("Example Switch (123) came on"): one blip per off. A counted relay that stays on simply keeps the pause from starting | A | The cure is R or K; C's grace (IA10) makes sure C never loses its evidence over such an off |
| IX3 | The bulbs behind the relay come back on with the power | The Hue lights report on and the pause ends: right, the room is lit. The cure is the bulbs' power-on behaviour (KB4) | A; O (KB4) | — |
| IX4 | B suspended for maintenance | R lapses (the rule is disabled); the relay counts, and being off it does not keep the pause from starting. When B resumes, R holds again at the relay's next report | A | — |
| IX5 | B removed for good | R is gone; the relay counts and, being on, keeps the pause from starting; Status shows it counted | A; O (K) | — |
| IX6 | The Hue bulbs unreachable while the relay is off | Their Light State keeps its last value (IF12): on at the cut, they keep the pause from starting until power returns | A | The safe direction |
| IX7 | Order at the start | A's first scan may come before B's start ON: an off relay does not keep the pause from starting; once on, it is left out (R) or counted | A | — |
| IX8 | The cost of R | One `GetCodeItems(light, 5101)` per room light at each scan and at each report of that light: a handful of small reads (ASSUMED small) | A | — |

## 5. Control4 guidelines

| Item | How these features meet it |
| --- | --- |
| Lighting follows Control4's lights (RDP section 5) | The pause still follows Light State as Control4 reports it. A light is left out only on Control4's own word: the owner's list, a keep-on rule in the project, or the device's own settings saying it is a keypad and not its load's control (IF6), with its behaviour. A departure from "every light counts", written down with its reason |
| L53, LEDs show the real state | Unchanged: the pause never touches the steady LEDs (RD-D9) |
| light_v2 best practice and the proxy's variables | A switch reports a brightness change only (BP) and has Light State alone (IF4): the basis of S7. The extras page has nothing on this |
| Keypads and switches behave as Control4's own | B uses the proxy's ON and reads Light State; it changes no switch setting, LED or binding |

## 6. For the contract

- The rule of section 1.2: the count list, `Pause Ignores Lights` unchanged,
  R, C with S7, S1, S2 or S3, S8, and the contradictions of S4 and S5;
  otherwise counted. Count wins over ignore.
- How R reads B's set (IX1), fixed together with B's mechanism.
- N and G, and whether a gap while the driver is not running is a break
  (IA35).
- The S8 record: what is persisted, when it is written, when it is deleted
  (IA14, IA16).
- The triggers: every scan, every report of the light, `OnBindingChanged`
  on the fan's own links, the owner's rows, and a second scan a few minutes
  after every start (IA34).
- A light that cannot be watched counts as unknown (IA29), a change to
  RD-D4.
- The Status row, the log lines and the hints of section 2.8, within 75
  characters.
- `Pause Ignores Lights` kept as it is; the driver never edits either list
  (IA40).
- For B: the start ON, the event-driven ON, the read-only periodic check,
  the retries of KB16, the cap of KB12, the suspension of KB8, the dead ids of
  KB18, switches only (KB20), and the manual's lines on the breaker, scenes
  (KB10) and the bulbs' power-on behaviour (KB4).

## 7. Open questions

| # | Question | Recommended | Cheap way to answer |
| --- | --- | --- | --- |
| IQ1 | Which of S1 to S7 and S9 Lua reads on the house | The sibling note's answer | With the dev loop ([`dev-loop.md`](dev-loop.md)), read only: `GetDeviceVariable` of variable 1001 on a relay's light proxy (nil means S7), `GetDeviceVariables` of the relay's protocol device, `GetBindingsByDevice` of its proxy, `GetDevices` of its id. Under a minute |
| IQ2 | Is R alone enough to leave a light out? | Yes: the owner keeps a light on only where it feeds power | The owner's word |
| IQ3 | Is C automatic or a hint only, and with which N and G? Is a gap a break? | Automatic, N = 7 days, G = 15 minutes, a gap not a break | The owner's word |
| IQ4 | Does a light that cannot be watched count (IA29)? | Yes, as unknown | The owner's word |
| IQ5 | What is on the outlet behind the second relay: a lamp with its own switch, network gear, something else? | — | The owner's word |
| IQ6 | The power-on behaviour of the Hue bulbs behind the relay (`powerup.preset`, `configured`) | Set in the Hue app to come back as they were | A read-only GET of those lights on the bridge with the Hue project's tooling; nothing written from this project. The owner then picks the preset; checking that an off bulb stays off needs one power cycle of that relay by day with the owner watching |
| IQ7 | What the C4-SW120277 relay (firmware 5.1.1) does when power returns | Not needed once IQ6 is settled; parked | A cut of that circuit at the breaker, by day: the owner's hands |
| IQ8 | Does an ON to a relay already on fire Light On, or send anything on the radio? | — | The Windows session watches the relay's Light On in Composer while one ON is sent from the Control tab. Under a minute |
| IQ9 | Which scenes, Room Off programming and voice integrations include the relays | Take them out (KB10, KB11) | A read-only Windows-session round of the Lighting agent, the room's programming and the voice settings |
| IQ10 | Is programming readable at `OnDriverLateInit`, and do bindings and settings read the same right after a reboot? | — | With the dev loop: one `GetCodeItems` and the IQ1 reads right after a Director restart |
| IQ11 | B's cap (re-ons per hour) and its periodic interval | 3 per hour; 15 minutes | The owner's word |
