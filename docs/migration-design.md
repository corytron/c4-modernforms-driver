# Migration from the stock WAC driver (contract)

Status: contract, 2026-10-27, for
[issue #12](https://github.com/corytron/c4-modernforms-driver/issues/12)
(branch `feature/v1-contract-12`), written beside the driver's own contract,
[`v1-design.md`](v1-design.md), which names the properties, actions and links
used here. It says how the house moves from the stock
`wac_mf_fan_and_light_controller(v4).c4z` to the Modern Forms Fan driver, and
back if need be: what is replaced (section 1), the decisions (2), the phases
(3), the read-only Migration Report (4), the briefs for the Windows Composer
session (5), the way back from every phase (6), how each install is recorded
(7) and what is still open (8).

The owner's decisions it applies (#6, 2026-10-27, every recommended
default): one driver with a fan proxy and a `light_v2` proxy; driver-declared
Button Links for Fan Speed 1 to 6, Off, Toggle and Cycle and the light's Top,
Bottom and Toggle, each lighting its keypad LED (Follow Connection); double
taps stay keypad programming on the button's own events; ON and Toggle go to
the proxy's preset speed (default 3); a pressed target lights at once; a fan
that goes offline keeps its last state, with Fan Offline and Fan Online
events; `<replaces>` is forbidden; 1.0-beta.N may run on the house before
1.0; and the pace: **cut over in one sitting** (the new device beside the
stock one, the links, the programming rebuilt; the stock programming
disabled, not deleted), **then remove the stock device and the LED workaround
in a later sitting, once a Migration Report shows nothing references the
stock device**. The lifecycle cases behind them are
[`edge-cases-control4.md`](edge-cases-control4.md#2-migration-from-the-stock-driver),
section 2, whose outline M0 to M8 becomes the phases here, and, for the fan,
[`edge-cases-modernforms.md`](edge-cases-modernforms.md).

**Written before the Windows side of M0**
([#11](https://github.com/corytron/c4-modernforms-driver/issues/11)). The VM
side has reported: the house fan is a generation 3 Modern Forms fan with six
speeds and a dimmable light; it answers `POST /mf` on the LAN and announces
itself over mDNS (`_easylink._tcp`). The Windows session's inventory of the
stock device, the keypad and the programming is still to come: every cell it
fills reads `[M0]`. The repository is public, so the inventory enters this
file with the placeholders of
[`scaffold-design.md`](scaffold-design.md#2-placeholders-the-repository-is-public)
(fan 10.0.2.151, controller 10.0.2.10, client id MF_00005E005301, "Example
Room"), device ids from 1201 to 1206 (the neutral set of
`tools/composer/Shots.ps1`) and button labels only; the full record stays on
the Windows machine (G5).

**Markers.** [verified: …] names a primary source: `API`, `FUND`, `XML` and
`KPD` are Snap One's DriverWorks references under `~/c4-tools/reference/`
(`docs-driverworks-api`, `docs-driverworks-fundamentals`,
`docs-driverworks-xml`, `docs-driverworks-proxyprotocol-keypad`, each
`source/includes/`), paraphrased, never quoted. [house: …] is a measurement
on this house (OS 3.4.3, Composer Pro 3.4.2), in
[`composer-remote.md`](composer-remote.md) or the Hue project
([corytron/c4-hue-driver](https://github.com/corytron/c4-hue-driver)).
[assumed] is not seen yet; section 8 names what settles it. The probes H1 to
H13 are those of
[`edge-cases-control4.md`](edge-cases-control4.md#7-probes-in-order), section
7, and T1 to T9 those of
[`fan-proxy-research.md`](fan-proxy-research.md#8-hardware-tests).

**Words.** The *stock device*: the device running the stock driver, with its
proxies (written 1201, 1202 and 1203). The *new device*: the Modern Forms Fan
device with its fan and light proxies (1204, 1205 and 1206). A *script*: the
programming under one event; a *line*: one item of it. *Old lines* name the
stock device or belong to the LED workaround; *new lines* name the new
device. (The report counts only the first kind of old line as "old" and the
workaround's LED lines among "other", 4.3.) The *LED workaround*: the LED
lines of the keypad's scripts, the stock device's "Fan Speed Changed"
script, and the Timer agent's 1 s one-shot timer "Fan LED Settle" with its
12-If expiry script. *WS*: the Windows
Composer session ([`composer-remote.md`](composer-remote.md)). *The VM*: the
coordinator's session on this machine. The *milestones* M0 to M5 are the
plan's (#6); the *phases* 0 to 8 are this contract's; the *decisions* are G1
to G16.

## 1. What the migration replaces

The stock device stays in the project until Phase 8: what names it is
disabled in the cutover sitting and deleted in the removal sitting. The
tables below are the inventory that M0 fills in; the Migration Report's first
run (Phase 2) must find the same scripts.

### 1.1 The stock device and the fan

| What | On the house | Source |
| --- | --- | --- |
| Driver file | `wac_mf_fan_and_light_controller(v4).c4z`; the exact name Director reports for the device `[M0]` (the report's search and `Stock Device`'s items use it, 4.2) | [`status.md`](status.md) |
| Its items in Composer | a protocol device and its proxies, expected a fan proxy and a light proxy (H1, H3 of [`light-structure-research.md`](light-structure-research.md)); names and ids `[M0]`, written here 1201 (protocol), 1202 (fan), 1203 (light) | `[M0]` |
| How it reaches the fan | an address property or a network binding; on the LAN or through WAC's cloud; how often it asks the fan `[M0]` (decides G13) | Q9 of [`modernforms-api-research.md`](modernforms-api-research.md) |
| Its links | 13 BUTTON_LINK connections: Fan Off, Fan Speed 1 to 6, Toggle Preset, Cycle Speed, Top, Bottom, Light Toggle; ids and the item that carries them `[M0]`; bound to nothing, since they do nothing (tested 2026-10-27) | [`status.md`](status.md) |
| Automatic updates | whether the Driver Update Agent lists it `[M0]`; only drivers in Control4's online database update that way | F32 of [`edge-cases-control4.md`](edge-cases-control4.md) |
| The fan | generation 3, six speeds, a dimmable light; `POST /mf` on the LAN; mDNS `_easylink._tcp`. Every stock speed has a new link of the same number, and the light becomes the new `light_v2` proxy | M0, VM side, 2026-10-27 (#11) |

### 1.2 The links, old and new

Nothing moves from the stock links, which are bound to nothing; the table
says which new link takes over a button's script (names and ids:
[`v1-design.md`](v1-design.md)).

| Stock link | New link | A press on the new link | Bound today |
| --- | --- | --- | --- |
| Fan Off | Fan Off | off | none |
| Fan Speed 1 to 6 | Fan Speed 1 to 6 | that speed | none |
| Toggle Preset | Fan Toggle | off when on; on at the preset speed (default 3) when off | none |
| Cycle Speed | Fan Cycle | one speed up (the end rule is v1-design.md's) | none |
| Top | Light Top | on to the light's preset; a hold brightens | none |
| Bottom | Light Bottom | off; a hold dims | none |
| Light Toggle | Light Toggle | toggles; a hold dims up or down | none |

### 1.3 Programming that names the stock device

One row per script. "Names it as" is how the Migration Report sees the script
(4.3); "Phase" is where it changes.

| # | Script (device ▸ event) | Today | Names it as | LED workaround | After the migration | Phase |
| --- | --- | --- | --- | --- | --- | --- |
| I1 | Keypad ▸ Low, Single Tap | the stock fan to speed `[M0]`; paints the buttons' LEDs | command | its LED lines | Low bound to Fan Speed `[M0]`; the lines disabled, then deleted | 3, 8 |
| I2 | Keypad ▸ Low, Double Tap | the stock fan to speed 1; Low's LED blue | command | its LED lines | a new line: the new fan to speed 1 | 3, 4, 8 |
| I3 | Keypad ▸ High, Single Tap | the stock fan to speed `[M0]`; paints the LEDs | command | its LED lines | High bound to Fan Speed `[M0]` | 3, 8 |
| I4 | Keypad ▸ High, Double Tap | the stock fan to speed 6; High's LED orange | command | its LED lines | a new line: the new fan to speed 6 | 3, 4, 8 |
| I5 | Keypad ▸ each other button that commands the fan or its light `[M0]` | `[M0]` | command | `[M0]` | bound to its link (1.2) | 3, 8 |
| I6 | Stock fan ▸ Fan Speed Changed | restarts the timer "Fan LED Settle" | event of the stock device | yes | nothing | 5, 8 |
| I7 | Timer agent ▸ Fan LED Settle expires | 12 Ifs on the stock fan's speed, each painting LEDs | conditions (H8) | yes | nothing | 5, 8 |
| I8 | Timer agent: the timer "Fan LED Settle" itself | not a script | — | yes | deleted | 8 |
| I9 | Scheduler, macros, voice scenes, the Variables agent, other scripts `[M0]` | none known | commands or conditions | no | the same line aimed at the new device | 6, 8 |

The lines per script `[M0]` (from the Copy All files of Phase 0) are what the
report's first run is compared with.

### 1.4 The keypad, button by button

| Button | Single Tap today | Double Tap today | LED today: Behavior; colours | Button Behavior | New link | Double Tap after | LED after |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Low | speed `[M0]` | speed 1 | Programmed; `[M0]` at its speed, blue at 1 | `[M0]` | Fan Speed `[M0]` | the new fan to speed 1 | Follow Connection, lit at its speed; at speed 1 see section 8, item 11 |
| High | speed `[M0]` | speed 6 | Programmed; `[M0]` at its speed, orange at 6 | `[M0]` | Fan Speed `[M0]` | the new fan to speed 6 | Follow Connection, lit at its speed; at speed 6 see section 8, item 11 |
| `[M0]`, each other fan or light button | `[M0]` | `[M0]` | `[M0]` | `[M0]` | 1.2 | `[M0]` | Follow Connection |
| a spare button, if any `[M0]` | none | none | `[M0]` | `[M0]` | Phase 2's test, then none | none | as before |

Phase 3 takes the buttons in this table's order after one change: a button
without a double tap goes first, if there is one.

### 1.5 What the report cannot see

| What | Where it lives | Redone by | Phase |
| --- | --- | --- | --- |
| Advanced Lighting Scenes holding the stock light `[M0]` | the Lighting agent's own data | WS, in the agent's screens [assumed] | 6 |
| The room's Navigator visibility of the stock items | room settings | WS | 6 |
| Navigator favourites and voice assistants' lists or routines naming the fan `[M0]` | the owner's phone, the assistant's cloud | the owner, only if `[M0]` names any | 6 |
| The names the family uses | device names | WS (G14) | 6 |

## 2. Decisions

**G1. Beside, never instead.** The new device is added beside the stock
device. Nothing converts a device: its proxies are fixed when it is created,
and an update may neither change them nor remove connections, so the stock
device cannot be moved to another driver file [verified: FUND
`14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`]. `<replaces>`
is never declared, in any build: once the new driver loads, Director would
remove the stock driver from the project and from Composer's driver store,
without warning, and the way back with it [verified: XML
`15_common_xml/_33.5-replaces.md`] [owner, #6]. Reusing the stock file's name
to pass as its update is forbidden too: its proxies and connections would
have to match, and it would impersonate WAC's driver
([`light-structure-research.md`](light-structure-research.md#24-replacing-the-stock-driver-any-option)).

**G2. Two sittings; nothing waits on the calendar.** Phases 0 to 2 happen on
any earlier days and change nothing the house uses. The **cutover sitting**
runs Phases 3 to 6 in one go. Phase 7 (observation) has no minimum length.
The **removal sitting** (Phase 8) comes on any later day on which its entry
conditions hold. Basis: [owner, #6, item 13]; disable before delete
([`edge-cases-control4.md`](edge-cases-control4.md#1-five-rules-behind-the-decisions),
rule 4); no test waits longer than about a minute
([`../CLAUDE.md`](../CLAUDE.md), "No long test waits"), so the removal waits
for the report's verdict and the closing check, not for a soak period.

**G3. Two stopping points.** Between sittings the house is left only where
every button is wholly old or wholly new and the LED workaround matches:
after Phase 2 (all old, the new device idle beside the stock one) or after
Phase 6 (all new, the workaround off). A surprise inside Phases 3 to 6 ends
the round with a report (rule 3 of
[`composer-remote.md`](composer-remote.md#rules-for-the-windows-session)); the
VM then resolves it within the sitting, or WS goes back to the state before
Phase 3 (section 6). Basis: a half-moved keypad mixes two drivers and two LED
mechanisms
([`edge-cases-control4.md`](edge-cases-control4.md#23-both-drivers-on-one-fan),
section 2.3).

**G4. The cutover runs on a release build.** The new device may be created
and checked with a `--dev` build through the dev loop (the plan's milestone
M4), but Phase 3 starts only when the device runs a release build, 1.0-beta.N
or 1.0, installed in place. Basis: a dev build is never the production
driver, and a dev package carries the dev key ([`../CLAUDE.md`](../CLAUDE.md),
"Commands"). The build that creates the device already declares the release's
capabilities and icon, since a device keeps the capabilities it was created
with until a controller reboot and its icon for good (D25 and D27 of
[`edge-cases-control4.md`](edge-cases-control4.md#3-driver-life)). So no
install in this contract needs a reboot, and one that makes Composer ask
"Restart Director?" stops the round (rule 10 of
[`composer-remote.md`](composer-remote.md#rules-for-the-windows-session)).

**G5. A backup before every change; the house's names stay on the Windows
machine.** WS backs up the project at the start of Phase 0, of the cutover
sitting and of the removal sitting, and at the end of Phases 6 and 8, and
saves every script it will change as a Copy All file, with screenshots, in
`C:\c4-mf\migration\<date>\` on the Windows VM. Those files hold room, device
and project names and the fan's address: they never reach the repository, an
issue or a Discussion. Reports carry counts, kinds, ids and the placeholders.
Basis: rules 4 and 5 of
[`composer-remote.md`](composer-remote.md#rules-for-the-windows-session) (a
backup before any round that changes the project; texts with the
placeholders); [`scaffold-design.md`](scaffold-design.md#2-placeholders-the-repository-is-public).

**G6. Disable before bind; unbind before enable.** Per button, its old lines
are disabled before its link is bound, and going back unbinds before it
enables, so a press never reaches the fan through both drivers. Disabled
lines stay until Phase 8. Basis:
[`edge-cases-control4.md`](edge-cases-control4.md#23-both-drivers-on-one-fan),
section 2.3 (a press that runs the old script and the new link sends two
commands; speeds flap) and section 1, rule 4.

**G7. Disable Event only for a script that loses every line.** A script all
of whose lines go (a Single Tap script that only sets the stock fan's speed
and paints LEDs; "Fan Speed Changed"; the timer's expiry) is disabled with
Disable Event; any other with Disable Item on exactly its old lines, top-level
items first (disabling an If greys its children). The Double Tap scripts are
always of the second kind: Phase 4 adds a line to them, and a line added
under a disabled event would not run [assumed]. If H8 shows that Disable
Event leaves no trace in the code items' `enabled` flags, Disable Item on
every top-level line replaces it, so that the report can see it. Basis: the
Script line menu
([`composer-remote.md`](composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag)).

**G8. Single taps become links; double taps stay programming.** Every button
that commands the fan or its light today is bound to the new link that does
the same (1.2), and its Single Tap (or Pushed) lines go. Its Double Tap lines
are rebuilt on the button's own Double Tap event, aimed at the new fan proxy:
speed 1 on Low, speed 6 on High. A link acts on the press, so a double tap
first sets the single-tap speed and the Double Tap line then corrects it; the
driver coalesces the two (the latest wins), and the button's LED lights for
the first target and goes dark for the second. Basis: [owner, #6, items 2
and 9]; acting on the press [verified: KPD
`62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`]; H4 (section
8, item 5).

**G9. The LED workaround goes off in one step, after the last button.**
While Phases 3 and 4 move the buttons, the workaround stays on: it keeps
painting the buttons not yet moved, and it paints the fan's settled speed,
which is what the moved buttons' links show [assumed: the 12 Ifs paint each
speed's buttons as the links light them; M0's Copy All shows it]. At worst a
moved button flickers a second after a change, if Programmed LED commands
reach a Follow Connection button at all (H6). Phase 5 then disables "Fan
Speed Changed" and the timer's expiry script and sets each moved button's
colours again: the workaround's "Set LED On" and "Set LED Off" lines choose a
button's colours [house: composer-remote.md, "Learned 2026-10-27"], so they
may have left a speed's blue or orange as its colour. Phase 8 deletes the
scripts and the timer. Basis: [owner, #6] (the workaround is removed with the
stock device, in the later sitting);
[`edge-cases-control4.md`](edge-cases-control4.md#23-both-drivers-on-one-fan),
section 2.3.

**G10. The owner's hands: two short moments, no reboot.** One press and a
glance at its LED after the first binding (Phase 2 on a spare button, else
Phase 3's first button), and one round of presses at the end of the cutover
sitting (Phase 6), each under a minute; his phone only if the fan is among
his Navigator favourites or in a voice routine (asked once, with M0). The
cutover sitting is
scheduled when he can give those two moments. No controller reboot (G4);
everything else is WS's or the VM's. Basis: [`../CLAUDE.md`](../CLAUDE.md)
(ask only when something needs his hands, such as a keypad test; no manual
steps otherwise);
[`edge-cases-control4.md`](edge-cases-control4.md#26-migration-checklist-outline),
section 2.6.

**G11. The Migration Report measures progress.** A driver action that reads
the project and changes nothing (section 4): it finds the stock devices by
their driver file name, uses `Stock Device` only when it cannot tell which is
this fan's, counts the lines that name the stock device and how many of them
are enabled, and keeps its last result across restarts. It runs on a click
only. No API writes, disables or deletes programming: the only code-item
functions read [verified: API `9_helper/_5.5-GETALLCODEITEMS.md` and
`_5.9-GETCODEITEMS.md`, the only ones in API that name code items]. So the
driver cannot do the migration and never tries; Connections and Programming
stay WS's work
([`edge-cases-control4.md`](edge-cases-control4.md#24-decisions), section 2.4).

**G12. When the stock device may go.** "Safe to remove" needs all of: the
stock device is identified (4.2); no enabled line names it, a line being
enabled only if it and every item above it up to its event are enabled; no
keypad is bound to any of its links. The keypad's LED lines, which name only
the keypad, do not block the verdict; Phase 8 removes them by the inventory
(G15). Basis:
[`edge-cases-control4.md`](edge-cases-control4.md#24-decisions), section 2.4;
each item's `enabled`, `device` and `subitems` [verified: API
`9_helper/_5.9-GETCODEITEMS.md`].

**G13. The stock device is disarmed after the cutover, if it asks the fan
on the LAN.** Two pollers add load to the fan's small network stack, which is
reported to freeze under polling
([`modernforms-api-research.md`](modernforms-api-research.md#8-limits-and-fragility);
P7 of
[`edge-cases-modernforms.md`](edge-cases-modernforms.md#2-power-and-reachability)).
At the end of Phase 6, when M0 shows the stock driver reaching the fan
through an address it can be given, WS clears that address and keeps the old
value in the local migration folder; the way back restores it. If the stock
driver talks to the fan through the cloud, or holds no address to clear,
nothing is done. Until then both drivers ask the fan, so Phase 3 follows
Phase 1 within days. Basis:
[`edge-cases-control4.md`](edge-cases-control4.md#23-both-drivers-on-one-fan),
section 2.3 ("disarm") [assumed: M0].

**G14. Names.** In Phase 1 every item of the new device is named after its
stock counterpart with " (new)". In Phase 6 the stock items become "… (old)"
first, and the new items then take the stock items' former names, so no two
items ever share a name; File ▸ Refresh Navigators follows. Basis: in
Connections' lower list and in Programming both devices offer the same links
and commands, and WS picks by name
([`composer-remote.md`](composer-remote.md), the helper module);
[`edge-cases-control4.md`](edge-cases-control4.md#26-migration-checklist-outline),
section 2.6, step M6, and U7.

**G15. Delete by the list, never by the device.** Phase 8 deletes the
disabled old lines first, script by script, then the timer, then the stock
device. Delete All only on a script whose Copy All shows nothing but old
lines; a Double Tap script, which holds a new line, loses its old lines one
Delete at a time. Basis: what Composer does with programming that names a
deleted device is not documented, and the keypad's LED lines name only the
keypad, so a device delete would leave them behind
([`edge-cases-control4.md`](edge-cases-control4.md#22-what-names-the-stock-device-today-and-who-redoes-it),
section 2.2); the prompts of Delete and Delete All [house:
composer-remote.md, "Learned 2026-10-27"].

**G16. Betas take the GitOps route; `release: none` lasts only until the
first one.** Every 1.0-beta.N, like 1.0 itself, reaches the house through a
desired-state pull request that sets [`deploy/house.yaml`](../deploy/house.yaml)
to it (`release: v1.0-beta.N` and its build), the deploy issue the drift
workflow then opens, `tools/deploy.py start` with its brief, and `deploy.py
done` (section 7). `release: none` holds only until the first beta is
installed; it is not kept until 1.0. Only a `--dev` build, or a
feature-branch build that no release carries, is recorded after the fact
with `deploy.py record --no-manifest --commit SHA`. Basis: decided for #12
(2026-10-27), following
[`cicd-gitops-design.md`](cicd-gitops-design.md#10-from-release-none-to-the-first-install),
section 10, step 2, and
[`prerelease-design.md`](prerelease-design.md#4-the-house), section 4; `start`
verifies every package's sha256 and provenance before a deployment exists,
and the deploy issue stays open while the house is off its desired state
([`cicd-gitops-design.md`](cicd-gitops-design.md#71-drift-logic), section
7.1).

## 3. Phases

| Phase | What | Who | When | Outline step |
| --- | --- | --- | --- | --- |
| 0 | Backup and inventory | WS (read-only, a backup) | before the first install | M0 |
| 1 | The new device beside the stock one | WS; the VM records the install | the plan's milestone M4 | M1 |
| 2 | Checks before anything moves | the VM (dev loop), WS; the owner once if a spare button exists | after Phase 1 | M2, M3 |
| 3 | Buttons to links | WS; the owner once | cutover sitting | M4 |
| 4 | Double taps rebuilt | WS | cutover sitting | M4 (Q3) |
| 5 | The LED workaround off | WS | cutover sitting | M4 |
| 6 | Everything else, names, closing check | WS; the owner once | cutover sitting | M5, M6 |
| 7 | Observation | the house; the VM | no minimum length | M7 |
| 8 | Removal | WS | removal sitting | M8 |

"Outline step" is the step of
[`edge-cases-control4.md`](edge-cases-control4.md#26-migration-checklist-outline),
section 2.6. Each phase gives who, what it changes, its check (every step of
it under a minute: a read in Composer or a press) and its way back; section 5
turns the phases into briefs and section 6 collects the ways back.

### Phase 0: Backup and inventory

- **Who:** WS, read-only apart from the backup. The Windows side of M0.
- **Changes:** none in the project. WS backs up the project (G5) [assumed:
  Composer's File menu has a backup item; WS reads the menu and names it
  first] and collects, for section 1:
  1. The stock device: its items in System Design with their ids; its
     Properties page and Documentation tab (local or cloud, how often it asks
     the fan); its driver file name as Director shows it and as Composer's
     driver store holds it; from that `.c4z`, a zip, its `driver.xml`'s
     proxies, its connections (the 13 links' ids, classes and owning item)
     and the property or binding that holds the fan's address, names and ids
     only (T1, and H3 of `light-structure-research.md`); whether the Driver
     Update Agent lists it.
  2. Connections of the stock device and of the keypad: screenshots of both
     panes.
  3. The keypad: for every button its LED Behavior, Button Behavior and LED
     colours, and whether it is a spare (no programming, no link).
  4. Programming: for every keypad button event with lines, every event of
     the stock device, the timer "Fan LED Settle" and every other script that
     names the stock fan or its light, a screenshot and the script's Copy
     All, saved locally (rule 19: the Programming view is read from
     screenshots and Copy All only).
  5. The Lighting agent's scenes that hold the stock light, and where a
     room's Navigator visibility is set (opened and cancelled).
- **Check:** the backup exists (path and size reported); every script of 1.3
  has its Copy All file; the VM writes section 1's `[M0]` cells from the
  report, with the placeholders.
- **Way back:** nothing changed.

### Phase 1: The new device beside the stock one

- **Who:** WS; the VM serves a dev build, or runs the desired-state route
  for a beta, and records the install (section 7).
- **Entry:** Phase 0 done; the build that creates the device declares the
  release's capabilities and icon (G4).
- **Changes:**
  1. `modernforms_fan.c4z` installed with Driver ▸ "Add or Update Driver or
     Agent…" after its sha256 is checked.
  2. A Modern Forms Fan device added to the fan's room, from the Items pane
     [assumed: a double-click with the room selected, or a drag; H2].
  3. Each of its items named after its stock counterpart with " (new)"
     (G14).
  4. Pointed at the fan: if [`v1-design.md`](v1-design.md) offers `Find
     Fans` (the fan answers mDNS), WS runs it and picks, in `Found Fans`, the
     entry at the stock device's address; otherwise WS types that address
     into `Fan Address` and clicks Set. Then the confirming action v1-design.md names
     (such as `Use Selected Fan`). WS compares the two addresses on its side
     and reports only whether they match.
  5. Nothing else: no binding, no programming, the stock device untouched.
- **Check:** no "Restart Director?"; `Driver Version` is the build; `Status`
  reads online, with a speed and a light level that agree with the stock
  device's; `Fan ID` is filled (reported as `MF_00005E005301`); `Keypad
  Links` shows nothing bound; `Migration` reads "Not run yet: click Migration
  Report on the Actions tab"; System Design shows the new items and nothing
  else changed (rule 6).
- **Way back:** delete the new device; nothing binds or names it yet. Its
  driver file may stay in Composer's store.

### Phase 2: Checks before anything moves

- **Who:** the VM through the dev loop while a dev build runs; WS; the owner
  for one press if a spare button exists.
- **Changes:** none to what the house uses; at most one temporary binding of
  a spare button, and the release build installed in place.
  1. The dev-loop pass of [`release-checklist.md`](release-checklist.md),
     section 1, items 1, 2, 3 and 5 (start, the fan and light round trips, no
     error line). The fan changes speed meanwhile, and the stock programming
     follows it as it follows the remote.
  2. WS clicks `Migration Report` and reads the `Migration` rows (section
     4); the VM compares them with 1.3. Every script there must appear, with
     its line count. A script the report misses (H8: a condition that does
     not carry its device) stays on the inventory's list for Phases 5 and 8,
     and section 8 records it.
  3. With a spare button: WS binds it to the new Fan Speed 3 link (the drag
     of Phase 3, step 2) and reads both Connections lists, its LED Behavior
     (now Follow Connection) and `Keypad Links`; the owner presses it once
     and glances at its LED; WS then Disconnects it and sets its LED Behavior
     back to its Phase 0 value. Without a spare, Phase 3's first button is
     the test.
  4. If the device runs a dev build: `Debug Mode` Off, then the beta
     installed in place over it by the desired-state route of section 7,
     which ends the dev loop.
- **Check:** the report matches the inventory, or the gap is recorded; the
  spare's press moved the fan to speed 3 and lit its LED; before Phase 3,
  `Driver Version` reads the beta's build and `Debug Mode` Off.
- **Way back:** the spare's binding is already undone; otherwise as Phase 1.

### Phase 3: Buttons to links (cutover sitting)

- **Who:** WS; the owner for one press after the first button, unless Phase 2
  tested a spare.
- **Entry:** the owner reachable for two moments (G10); the device on a
  release build (G4); WS's backup (G5); `Migration Report` run, its verdict
  noted (expected "Stock device 1201: 14 enabled lines name it; keep it",
  with 1.3's count).
- **Changes, button by button** in 1.4's order:
  1. Programming: the button's old lines disabled as G7 says: Disable Event
     on a Single Tap (or Pushed) script that loses every line, Disable Item
     otherwise; the old lines of its Double Tap script by Disable Item. A
     Copy All of each script changed.
  2. Connections: select the keypad, and drag the button's "… Button Link"
     row from the top pane onto the new device's link row in the lower "…
     Output Devices" list (the row whose device name ends in "(new)"). The
     drag that works: press, wait 300 ms, at least 10 px of real travel
     first, then about 30 steps of 20 ms, hover 500 ms, release; the capture
     and the drop cursor checked mid-drag (rule 18).
  3. Read: both Connections lists show the binding; the button's LED
     Behavior reads Follow Connection (the binding sets it); `Keypad Links`
     lists it.
  4. After the first button only: the owner presses it once; the fan goes to
     its speed and its LED lights. The next button waits for that.
- **Check (per button):** the Copy All files show every old line of the
  button disabled and nothing else changed; the binding in both lists and in
  `Keypad Links`; LED Behavior Follow Connection. After the last button,
  `Keypad Links` counts one binding per moved button, and the report's rows
  for their scripts read "old 0/…".
- **Way back (per button, the last first):** Disconnect its binding
  (right-click the binding's row; the prompt names the two devices; read both
  lists afterwards); LED Behavior back to its Phase 0 value, Programmed
  (Disconnect does not restore it); then Enable Event or Enable Item on its
  old lines (G6).

### Phase 4: Double taps rebuilt (cutover sitting)

- **Who:** WS.
- **Changes,** per button with a Double Tap (1.4): in the Programming view,
  the keypad's button and its Double Tap event; the new fan proxy's speed
  command dragged by its green arrow into the script, at the top level below
  the disabled lines (onto an If's blue "?" icon only if the old speed line
  sat inside an If); its speed set explicitly, 1 on Low and 6 on High.
- **Check:** the script's Copy All shows one enabled line naming the new fan
  with the right speed, and every old line still disabled; the report's row
  for the script reads "old 0/… · new 1/1".
- **Way back:** Delete the new line (the prompt "Are you sure you want to
  delete the code item: …"); Phase 3's way back enables the old ones.

### Phase 5: The LED workaround off (cutover sitting)

- **Who:** WS.
- **Changes:**
  1. Disable Event on the stock device's "Fan Speed Changed" script (I6),
     on the Timer agent's "Fan LED Settle" expiry script (I7) and on any
     other LED-only script 1.3 lists. The timer itself stays until Phase 8.
  2. Each moved button's colours set to 1.4's "LED after", where
     [`v1-design.md`](v1-design.md) says a linked button takes them from (the
     keypad's own LED colours, or the driver's colour properties).
- **Check:** the Copy All files of both scripts show every line disabled;
  the colours read back as set; the report's rows for the scripts of I1 to I7
  show no line on but the new Double Tap lines ("old 0/…", "other 0/…"). The
  LEDs the workaround painted last stay until the fan's next change; the
  closing check's presses refresh them.
- **Way back:** Enable Event on both scripts; the colours back to Phase 0's
  record.

### Phase 6: Everything else, names, closing check (cutover sitting)

- **Who:** WS; the owner once at the end; his phone only if needed (G10).
- **Changes:**
  1. Every other script that 1.3 (I9) or the report lists: Disable Item on
     its old line, and the same command or condition on the new device by
     drag (or by Find and Replace, if H9 shows it can swap a line's device).
     Advanced Lighting Scenes that hold the stock light: the new light added
     at the same level, the stock light taken out [assumed: the Lighting
     agent's screens].
  2. Names (G14): the stock items "… (old)", then the new items the stock
     items' former names; the stock items hidden from the Navigators where
     Phase 0 found the setting; File ▸ Refresh Navigators.
  3. The stock device disarmed (G13), if that applies: its address cleared
     with Set, the old value kept in the local migration folder.
  4. `Migration Report`: the verdict must read "Stock device 1201: nothing
     enabled names it; safe to remove". WS saves the rows locally and
     reports them with the placeholders.
  5. Backup (G5).
  6. The owner's closing check, under a minute: each moved button once (the
     fan follows; only that button's LED lights), a double tap on Low and on
     High, the light's buttons if any, and the fan's tile on his phone under
     its usual name. Favourites and voice routines only if they name the fan
     (section 8, item 4).
- **Check:** step 4's verdict; step 6's results.
- **Way back:** per step, the last first: re-arm the stock device; the names
  back (the new items to "… (new)" first, then the stock items to their
  names); visibility and scenes back; the moved lines enabled and their new
  lines deleted; then Phases 5, 4 and 3 back. A closing check that fails and
  cannot be fixed within the sitting takes the house back to before Phase 3
  (G3).

### Phase 7: Observation

- **Who:** the house in daily use; the VM.
- **Changes:** none to the migration. Fixes reach the house as later betas,
  and 1.0 here or later, each installed in place by the desired-state route
  (section 7).
- **Check:** after every install, WS reads `Driver Version`, `Debug Mode` and
  `Keypad Links` and runs `Migration Report`, whose verdict must not change;
  the owner's remarks go into the issue as comments.
- **Exit:** any day on which Phase 8's entry conditions hold; there is no
  minimum length (G2).
- **Way back:** section 6; everything is still reversible in Composer.

### Phase 8: Removal (a later sitting)

- **Who:** WS.
- **Entry:** Phase 6's closing check passed; no open issue whose remedy
  would be going back to the stock driver; WS's backup; `Migration Report`
  reads "safe to remove" at the start of the sitting.
- **Changes,** in this order (G15):
  1. The old lines, script by script as the report lists them: Delete on
     each disabled old line and on the LED workaround's lines (1.3); Delete
     All only on a script whose Copy All shows nothing else.
  2. The Timer agent's timer "Fan LED Settle" [assumed: the agent's screen
     deletes a timer].
  3. `Stock Device` cleared, if it was set.
  4. The stock device: its protocol device deleted (the prompt "Are you sure
     you want to delete the item '…'?"); its proxies go with it [assumed: as
     for any device with proxies]. Its driver file may stay in Composer's
     store.
  5. `Migration Report`: "Stock device 1201 is gone; nothing names it".
  6. File ▸ Refresh Navigators; backup.
- **Check:** each changed script's Copy All before and after (only old lines
  gone); System Design lost exactly the stock items; `Keypad Links`
  unchanged; step 5's verdict.
- **Way back:** section 6, "After Phase 8".

## 4. The Migration Report

This section is the report's specification; [`v1-design.md`](v1-design.md)
lists its action and its two properties with the driver's others.

### 4.1 What it is, and what it never does

| Element | Kind | Purpose |
| --- | --- | --- |
| `Migration Report` | action (Actions tab, with the `sort_order` v1-design.md gives it) | reads the project, writes the `Migration` list, persists the result |
| `Migration` | DYNAMIC_LIST property | the verdict on its row; the report's rows in its drop-down; a pick changes nothing and snaps back to the verdict |
| `Stock Device` | DEVICE_SELECTOR property, one device, empty by default | names this fan's stock device when the report cannot tell (4.2) |

It runs only when the action is clicked: never at start-up, on a timer or
on a property change, since it reads the whole project's programming at once
(H8 measures how long that takes on the house). It reads with the documented
read-only calls of 4.2 and 4.3. It never writes, disables or deletes
programming (no API can, G11); never binds or unbinds (`C4:Bind`,
`C4:Unbind`); never adds, renames or deletes a device; and never sends
anything to the stock device or the fan. It writes only its own property
list, its persisted value and one log line. Sources: an action arrives as
`LUA_ACTION` in `ExecuteCommand` [verified: API
`5_director_command/_1-ExecuteCommand.md`; `sort_order` from 3.3.0, every
action needing one: FUND
`15_composerpro_interface_into_the_sdk/_6-ACTIONS.md`]; DYNAMIC_LIST [verified:
FUND `15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md`];
DEVICE_SELECTOR [verified: FUND
`15_composerpro_interface_into_the_sdk/_3.1-DEVICESELECTOR.md`].

### 4.2 Finding the stock device

1. `C4:GetDevices({})`: every device with its file name, name, room and
   proxies [verified: API `22_miscellaneous/_9-GetDevices.md`, from 2.10.0;
   an empty filter returns every device] [house: the result's shape, Hue
   `design.md`, "Project APIs"]. A **stock device** is one whose
   `driverFileName` is one of the stock file names M0 reads (a constant of
   the driver) or begins with `wac_mf_fan`, case ignored, so that another
   version of WAC's file is found too. Its ids are its protocol device's and
   its proxies'.
2. Which one is this fan's, in this order:
   - `Stock Device` set: that device, if it is a stock device; otherwise the
     verdict "Report failed: Stock Device 1204 is not a stock WAC device".
   - Exactly one stock device: that one ("the only one").
   - Several: the one whose address equals this device's `Fan Address`,
     where `C4:GetBindingsByDevice` on its proxy shows the address (H10)
     ("same address") [verified: API
     `32_serial_network_device/_2.5-GetBindingsByDevice.md`, from 3.0.0, the
     proxy's id for a device with proxies].
   - Otherwise no verdict: "3 stock WAC devices: pick this fan's in Stock
     Device".
3. `Stock Device` offers the stock file names M0 reads as its items, one
   device at a time; the driver reads the chosen id from `Properties`
   [verified: FUND
   `15_composerpro_interface_into_the_sdk/_3.1-DEVICESELECTOR.md`]. A stock
   file of another name is added to the items in a later build (a property,
   not a capability) [assumed: no reboot]. The same page says that Set
   "binds" the driver to the chosen device; whether a later delete of that
   device notices is not documented, so Phase 8 clears the property first.

### 4.3 Reading the programming and the links

1. `C4:GetAllCodeItems()`: every event's code items, each event with its
   device id and event id, each item with `enabled`, `device`, `type`,
   `display` and `subitems` [verified: API `9_helper/_5.5-GETALLCODEITEMS.md`,
   `_5.9-GETCODEITEMS.md`; from 3.3.0, `3_whats_new/_13-WhatsNewin330.md`].
   The shape on the house is H8's.
2. A **script** is one event's tree. A **line** is an item of type 1
   (command), 2 (condition) or 3 (loop); containers, comments, else and
   operators are walked through and not counted. A line is **enabled** when
   it and every item above it, up to the event's root, are enabled.
3. A line is **old** when its `device` is a stock id, or when its script's
   event belongs to a stock device (everything under "Fan Speed Changed"
   runs because of the stock device); **new** when its `device` is one of
   this device's ids (`C4:GetDeviceID()`, `C4:GetProxyDevices()`) [verified:
   API `22_miscellaneous/_11-GetDeviceID.md`, `25_proxy/_1-GetProxyDevices.md`];
   **other** otherwise. A script is reported when it holds an old or a new
   line [assumed: a condition carries the device it tests in `device`; H8:
   the timer's 12 Ifs must show as old lines].
4. The stock links' bindings: `C4:GetBoundConsumerDevices(id, link)` for each
   stock id and each stock link id M0 reads; nil (or an empty table) means
   nothing is bound [verified: API
   `32_serial_network_device/_3-GetBoundConsumerDevices.md`].
5. Names: from step 4.2.1's table, and `C4:GetDeviceDisplayName(id)` for an
   id it lacks, such as an agent [verified: API
   `32_serial_network_device/_6-GetDeviceDisplayName.md`]. A line's text is
   its `display` with the device's name in place of the NAME macro, which
   Composer fills with "Room->Name" [verified: FUND
   `10_conditionals/_2-SIMPLECONDITIONAL.md`].

### 4.4 Rows

`C4:UpdatePropertyList` takes the list as one comma-delimited string, the
value shown being one of its items [verified: API
`24_properties/_6-UpdatePropertyList.md`]: no row holds a comma, and one in a
device name or a line's text is drawn as `‚` (U+201A), as the Hue drivers do.
Rows stay under 70 characters, since Composer clips a value at about 75
[house: Hue `design.md`, "Composer Pro 3.4.2 UI"]: a room name is cut to 22
characters, a device name as far as its row needs (never below 12), and a
line's text at the row's end, each with "…"; arrows display on the house
[house: the Hue `Room Mappings` rows, "→"]. The verdict is the property's
value, which the dev loop ships to the VM with the other properties: it
holds ids and counts only. The other rows name rooms and devices and stay in
Composer. The rows, in list order (`<…>` is a value):

| # | Row | When |
| --- | --- | --- |
| 1 | the verdict (4.5) | always first |
| 2 | `Report of <YYYY-MM-DD HH:MM> by build <N>; it changed nothing` | |
| 3 | `Stock: device <id> in <room> (<how>)` | one per stock device; `<how>` is `the only one`, `same address`, `set in Stock Device` or `not this fan's` |
| 4 | `Stock links bound to keypads: <b> of <t>` | |
| 5 | `Lines naming device <id>: <n> in <s> scripts; <m> enabled` | the stock device |
| 6 | `Lines naming this device: <n> in <s> scripts; <m> enabled` | |
| 7 | `Other lines still on in scripts naming it: <k>` | other lines (the keypad's LED lines among them) still enabled in the scripts of row 9 |
| 8 | `Script rows count lines on/total: old · new · other` | the legend |
| 9 | `<device> ▸ event <id>: old <a>/<b> · new <c>/<d> · other <e>/<f>` | one per script, those with an enabled old line first; a part with nothing to count is left out |
| 10 | `  first: <text of the script's first old line, else its first new line>` | under each script row |
| 11 | `  on: <text of an enabled old line>` | under its script row, at most 5, then `  on: … and <n> more` |
| 12 | `… <n> more scripts; the Lua tab lists all by id` | after 40 script rows |
| 13 | `Not read here: lighting scenes; favourites; voice` | always last |

Before the cutover (Phase 3's entry), with the placeholders of this file and
an illustrative line text:

```text
Stock device 1201: 14 enabled lines name it; keep it
Report of 2026-11-02 21:04 by build 57; it changed nothing
Stock: device 1201 in Example Room (the only one)
Stock links bound to keypads: 0 of 13
Lines naming device 1201: 27 in 6 scripts; 14 enabled
Lines naming this device: 0 in 0 scripts; 0 enabled
Other lines still on in scripts naming it: 30
Script rows count lines on/total: old · new · other
Example Room Keypad ▸ event 12: old 1/1 · other 4/4
  first: Set speed on Example Room->Fan to 2
  on: Set speed on Example Room->Fan to 2
Not read here: lighting scenes; favourites; voice
```

After the cutover, the same keypad's Double Tap script reads `Example Room
Keypad ▸ event 13: old 0/1 · new 1/1 · other 0/2`, and the verdict `Stock
device 1201: nothing enabled names it; safe to remove`.

### 4.5 The verdict

| Verdict (row 1, the property's value) | When |
| --- | --- |
| `Not run yet: click Migration Report on the Actions tab` | nothing persisted yet |
| `Stock Device changed: click Migration Report again` | `Stock Device` set since the last run |
| `No stock WAC device in the project; nothing to migrate` | none found and none remembered |
| `<k> stock WAC devices: pick this fan's in Stock Device` | 4.2, the last case |
| `Stock device <id>: <m> enabled lines name it; keep it` | m > 0, no link bound |
| `Stock device <id>: <b> keypad links bound to it; keep it` | m = 0, b > 0 |
| `Stock device <id>: <m> enabled lines and <b> links; keep it` | m > 0 and b > 0 |
| `Stock device <id>: nothing enabled names it; safe to remove` | G12 holds |
| `Stock device <id> is gone; nothing names it` | the remembered stock device no longer exists, and no line names its ids |
| `Stock device <id> is gone; <n> lines still name it` | it no longer exists, but lines name its ids |
| `Report failed: <reason>` | `this OS has no GetAllCodeItems (needs 3.3.0)`, `Stock Device 1204 is not a stock WAC device`, `reading the programming failed; see the Lua tab` |

"Safe to remove" is said exactly when G12 holds. It is advice for Phase 8,
not an act: the driver deletes nothing.

### 4.6 What it persists

One value, written with `C4:PersistSetValue` at the end of every run
[verified: API `26.5_persistence/_4-PersistSetValue.md`, tables allowed]
[house: kept through an update in place and a reboot, lost when a device is
deleted and added again; Hue `design.md`, "Storage"]: the run's time and
build; the stock device's ids (protocol and proxies) and how it was matched;
the counts of rows 4 to 7; the verdict; and the rows as written. At
`OnDriverLateInit` the driver rebuilds the `Migration` list from it, because
Director keeps no DYNAMIC_LIST items and `UpdatePropertyList` does not belong
in `OnDriverInit` [verified: FUND
`15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md`; API
`24_properties/_6-UpdatePropertyList.md`]; row 2 then says when the rows were
read. The remembered ids let a run after Phase 8 still find lines that name
the deleted device (the "is gone" verdicts). A pick in the list is answered
by setting the verdict back with `C4:UpdateProperty`, which raises no
`OnPropertyChanged` [verified: API `24_properties/_3-OnPropertyChanged.md`].

### 4.7 Limits

- It cannot see Advanced Lighting Scenes, Navigator favourites or voice
  assistants (row 13; 1.5).
- The keypad's LED lines count as "other" in a script that names the stock
  device and are invisible elsewhere; Phase 8 removes the workaround by the
  inventory (G15).
- The code items give event ids, not names [assumed: no documented call names
  another device's events]: a script row shows its event's id and its first
  line, and Phase 0's Copy All files map ids to the events WS sees.
- Its log line carries the counts, the ids and the time the run took, never a
  name: logs leave the controller through the dev loop.
- `C4:GetAllCodeItems` needs OS 3.3.0, the driver's minimum (v1-design.md);
  the driver checks that the function exists before calling it.

## 5. Briefs for the Windows session

### 5.1 What every brief carries

- The round's number, phase and purpose, and what to read:
  [`composer-remote.md`](composer-remote.md#rules-for-the-windows-session)
  (its rules, and "Learned 2026-10-27" for the drag, the If's blue "?" icon,
  the Script line menu, Copy All and the keypad LED commands) and the parts
  of this contract the round needs.
- The standing-approval sentence, as rule 8 of `composer-remote.md` gives it:

  > **Standing approval:** Cory approves everything this brief asks, every
  > time (CLAUDE.md, 2026-10-27): installs, "Restart Director?", Composer
  > changes including Connections and Programming, the deletes it names,
  > Refresh Navigators and the project actions it names. Do not ask him
  > again on your side. The safety rules still hold: stop and report on any
  > surprise, check every click and every drag, no ALT, never elevate; a
  > controller reboot from System Manager is his, by hand.

- The round's hard-to-undo steps, named (rule 2): installs, OK in a dialog
  that adds or changes a device, Connections, Programming (Disable, a new
  line, Delete), Sets on the stock device's properties, deletes, backups.
- The rules that bite here: stop on surprises (rule 3); every click and drag
  checked, a drag's capture and drop cursor mid-drag and its result read back
  from both Connections lists or a Copy All (rules 5 and 18); the window
  title and System Design's row count after every step (rule 6); an edit
  counts only after Set (rule 7); no mouse wheel over a property page (rule
  17); the Programming view read from screenshots and Copy All only (rule
  19); the new device never deleted and added again once Phase 3 has begun
  (rule 20).
- Where files go: screenshots under `C:\c4-mf\shots\`; backups, Copy All
  files and anything holding the house's names or the fan's address under
  `C:\c4-mf\migration\<date>\`, never sent (G5).
- What the report back holds: exact texts (UIA names, property values,
  prompts), counts and ids, names as the placeholders, and any surprise.

### 5.2 Per phase

| Phase | Read | Change (the named hard-to-undo steps) | Report | Stop if |
| --- | --- | --- | --- | --- |
| 0 | section 1 (what to fill) | the backup only | 1's `[M0]` cells as placeholders; the backup's path and size; the Copy All files' list; the File menu's backup and load items | a dialog other than the backup's offers a change |
| 1 | G4, G14, Phase 1 | the install; the device added; the renames; `Fan Address` and Set, or the `Find Fans` pick; the confirming action | Phase 1's check; the new items' ids; whether the addresses match | "Restart Director?"; an install error; `Status` not online within a minute |
| 2 | section 4 | the spare's binding, its Disconnect and LED Behavior back; the beta's install | the `Migration` rows (the dropped list read with `Get-ComboListItemsMsaa`, scrolled by its scrollbar); `Keypad Links` before, during and after; both Connections lists; LED Behavior | the report fails; a drag does not start |
| 3 | 1.4 (buttons, order, scripts), G6, G7 | the backup; every Disable Event and Disable Item; every binding | per button: the Copy All summary, both lists, LED Behavior, `Keypad Links`; a pause after the first button for the owner's press | a binding lands on a stock link or on another button (Disconnect it); a script holds a line 1.3 does not list |
| 4 | 1.4 | each new Double Tap line | the Copy All summaries; the new line's text as shown | the line lands inside an If unintended (delete it); no speed parameter is offered |
| 5 | 1.3 (I6, I7), 1.4's colours | two Disable Events; the colour Sets | the Copy All summaries; the colours read back | a script holds a line 1.3 does not list |
| 6 | 1.3 (I9), 1.5, G13, G14 | Disable Item and the new lines; scene membership; the renames and visibility; Refresh Navigators; the stock address cleared; the backup | the summaries; the verdict and rows; then a wait for the owner's closing check | the verdict is not "safe to remove" |
| 7 | — | nothing (an install is section 7's brief) | after an install: `Driver Version`, `Debug Mode`, `Keypad Links`, the verdict | the verdict changed |
| 8 | G15, the last report's rows | the backup; every Delete and Delete All; the timer's delete; `Stock Device` cleared; the stock device's delete; Refresh Navigators; the backup | each script's Copy All before and after; each prompt's text; System Design's rows before and after; the verdict | the verdict at the start is not "safe to remove"; a prompt names an unexpected item |

## 6. Going back

Before Phase 8 every step is undone in Composer, newest first, by WS under
the standing approval; the owner is needed only for a press that confirms
it.

| From | Undo, newest first | Check |
| --- | --- | --- |
| Phase 0 | nothing changed (the backup and the local files stay) | — |
| Phase 1 | delete the new device (nothing binds or names it) | System Design as after Phase 0 |
| Phase 2 | the spare is unbound already; the beta stays, or the device goes as from Phase 1 | as Phase 1 |
| Phase 3 | per button, the last first: Disconnect its binding (read both lists); LED Behavior back to its Phase 0 value (Disconnect does not restore it); Enable Event or Enable Item on its old lines | each Copy All equals Phase 0's file; no binding left; the verdict's count as before Phase 3 |
| Phase 4 | Delete each new Double Tap line | Copy All |
| Phase 5 | Enable Event on "Fan Speed Changed" and on the timer's expiry; the colours back | Copy All; the colours |
| Phase 6 | re-arm the stock device (its address from the local record, Set); names back, the new items to "… (new)" first; visibility and scenes back; the moved lines enabled and their new lines deleted; Refresh Navigators | names and verdict as before Phase 3 |
| Phase 7 | as from Phase 6, then 5, 4 and 3 | the verdict's count is Phase 2's |
| Back to the stock driver | the rows above from Phase 6 down to Phase 1; the new device deleted last, once the report's row 6 reads 0 lines, or kept unused | the stock programming runs; the LEDs follow as before |
| After Phase 8 | load the backup taken at the start of Phase 8 [assumed: Composer's Load Project replaces the controller's project, every later change included]; or rebuild: the stock driver's device added again in its room, its address set, each script pasted back from Phase 0's Copy All files [assumed: Paste takes Copy All's XML]; no link to rebind, since Phase 0 found none | the report finds a stock device again (with new ids, if rebuilt); the old scripts run |

This is the way back that the 1.0 prereleases promise
([`prerelease-design.md`](prerelease-design.md#7-a-prerelease-before-the-first-release)).
When going back for good deletes the new device, a desired-state pull
request sets `release: none` and `build: none` again; with an install
recorded, the drift run then reports drift without an issue
([`cicd-gitops-design.md`](cicd-gitops-design.md#9-automation-decisions),
section 9). A device kept unused leaves the desired state as it is.

## 7. Recording the installs

Every install of `modernforms_fan.c4z` on the house is recorded on the
GitHub environment `house`
([`cicd-gitops-design.md`](cicd-gitops-design.md), section 7, and
[`tools/deploy.py`](../tools/deploy.py)).
[`deploy/house.yaml`](../deploy/house.yaml) reads `release: none` and `build:
none` only until the first beta is installed; from then on it names the beta
or the release the house should run (G16).

| Install | When | Route | Recorded by |
| --- | --- | --- | --- |
| `--dev` build, or a feature-branch build that no release carries | Phase 1 (the plan's milestone M4); a fix tried on the house before it is merged | built from a pushed commit; its sha256 in the brief; served from `build/release/` on port 8091 for the download only ([`../CLAUDE.md`](../CLAUDE.md), "Commands", Deploy); `deploy/house.yaml` unchanged | `python3 tools/deploy.py record --no-manifest --commit <sha> --build <N> --at <time> --note "<phase>: <what>"` |
| `1.0-beta.N` | the end of Phase 2 (or Phase 1, when no dev build came first); each fix during Phase 7 | the prerelease cut from `main`; a desired-state pull request sets `release: v1.0-beta.N`, `build:` its build and `drivers: modernforms_fan` (`CHANGELOG.md` is not stamped for a prerelease); on its merge the drift workflow opens "Deploy v1.0-beta.N (build N) to the house", added to project board 2 by hand; `python3 tools/deploy.py start` downloads and verifies the packages (sha256, provenance) and writes `build/release/v1.0-beta.N/BRIEF.md`, which says "prerelease"; WS installs in place ([`release-checklist.md`](release-checklist.md#prerelease), item 5) | `python3 tools/deploy.py done --devices 1`, which closes the deploy issue; `failed --note "…"` keeps it open |
| `1.0` | Phase 7 or later | the same route ([`release-checklist.md`](release-checklist.md#deploy-to-the-house)), with `CHANGELOG.md` stamped in the desired-state pull request | `python3 tools/deploy.py done --devices 1` |

- When a beta creates the device (Phase 1 with no dev build before it),
  Phase 1's steps follow the install of `BRIEF.md` in the same round: `start
  --note "first install: add the device beside the stock one
  (migration-design.md, Phase 1)"` carries that into the brief, and `done
  --devices 1` comes once the new device reads the build.
- `record`: `--at` is ISO 8601 with an offset (such as
  `2026-11-02T21:04:00-05:00`), when WS reported the install done; `--note`
  names the phase, such as "phase 1: Modern Forms Fan added beside the stock
  device"; `deploy.py` refuses a note or a brief that holds private data.
  Without `--tag`, `record` needs the commit on GitHub (the branch pushed
  first).
- Drift: while only a dev build has been installed and the file says
  `release: none`, `python3 tools/deploy.py status` exits 3 and the drift
  workflow opens no issue. Once the file names a beta, recording a dev or
  feature-branch build installed over it opens the deploy issue, or keeps it
  open, until a release build (that beta again, or the next one) is installed
  ([`cicd-gitops-design.md`](cicd-gitops-design.md#71-drift-logic), section
  7.1). [`status.md`](status.md) says which build runs.
- Before a release build replaces a dev build, `Debug Mode` is set Off
  ([`dev-loop.md`](dev-loop.md#leaving-the-loop-production)): Director keeps
  the value through the install, and WS reads it back against
  `deploy/house.yaml`'s `debug_mode: Off`.
- Every install after Phase 1 is an update in place: the device exists, and
  its links and programming stay
  ([`composer-checklist.md`](composer-checklist.md), step 2).
- The M1 probe's throwaway package is not one of `drivers:`; its round report
  is its record.
- Every WS round of the migration is posted to GitHub Discussions with the
  placeholders ([`../CLAUDE.md`](../CLAUDE.md)).

## 8. Open items

What M0's Windows inventory (#11) fills in:

1. Section 1's `[M0]` cells. They also set: the report's stock file names and
   link ids (4.2, 4.3); Phase 3's buttons, order and scripts; whether G13
   applies (an address on the LAN to clear); whether a spare button exists
   (Phase 2 or Phase 3 holds the first press).
2. Composer's backup and Load Project items and where a backup lands (Phase
   0; section 6, "After Phase 8").
3. Where a room's Navigator visibility is set (Phase 6, step 2).
4. Whether the fan is among Navigator favourites or in a voice routine
   (asked once; the closing check).

What the M1 probe and the first dev install may change:

5. H4, what a double tap sends over a link. If the Double Tap event can come
   before the second tap's press reaches the link, or a linked button fires
   no Double Tap event, Phase 4 changes and the owner's decision 9 (#6) goes
   back to him (the alternative: a driver link with a double-tap speed, in
   v1-design.md).
6. H6, Programmed LED commands on a Follow Connection button: no order
   changes (G9); it says whether moved buttons may flicker until Phase 5.
7. H8, `C4:GetAllCodeItems` on the house: its shape, size and time; whether
   keypad, Timer agent and Scheduler events appear; whether conditions carry
   their device (if not, the 12 Ifs are invisible to the report, and Phases 5
   and 8 go by the inventory alone); the `enabled` flags after Disable Item
   and Disable Event (G7's fallback).
8. H9, Find and Replace: if it swaps a line's device, Phase 6 uses it instead
   of drags.
9. H10, `C4:GetBindingsByDevice` on the stock device: whether its address can
   be read (it matters only with several stock devices).
10. H1 and H2, the two-proxy presentation: which item carries the new links
    in Connections' lower list (Phase 3) and which items Phase 1 renames.
11. T6 and v1-design.md's LED colours: what Low shows at speed 1 and High at
    speed 6 (today blue and orange). A button on Follow Connection has one
    lit state, so they are dark at their double-tap speed unless
    v1-design.md lights a link for a second speed in its own colour; the
    closing check shows the owner which.
12. The Button Behavior of a linked button: kept unless the first press
    (Phase 2 or 3) shows that it must change.
13. `Find Fans`: if v1-design.md offers it (the fan answers mDNS), Phase 1
    picks the fan from its list; otherwise the address is typed. Both are
    written.

Pointers in other documents (the coordinator's, with this contract's pull
request):

14. `prerelease-design.md`, section 7, and
    [`.github/prerelease-notes.md`](../.github/prerelease-notes.md) point at
    `edge-cases-control4.md`, section 2, for the way back; section 6 here is
    now its contract.
15. [`composer-checklist.md`](composer-checklist.md), section I, can take
    Phases 3 to 8's checks as its steps, and
    [`release-checklist.md`](release-checklist.md), section 2, can point here
    for the first install.
