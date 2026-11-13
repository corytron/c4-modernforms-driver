# Edge cases and lifecycle policy: finding fans by itself

> **Status (2026-11-13, #213).** Built in 1.2 (#102) by
> [`auto-discovery-design.md`](auto-discovery-design.md), which wins where
> it and this note differ. The owner's answers: question 1, **only at
> load** (AD4: a pinned device whose fan answers does not search hourly);
> question 3, **yes** (AD3: a pick takes the fan at once, except a pick of
> a different fan on a pinned device, which waits for Use Selected Fan,
> L32); question 2 stayed no (AD8). Also changed by the contract: the first
> row is a summary of the last search (its section 3.1), not `Pick a fan`;
> S2 reads `Not set up: pick a fan in Found Fans, or enter Fan Address`,
> and S15 and S16 were not added; L21 ends `; searching again`; rows come
> this device's fan first, then by instance, the instance cut at its start
> to 25 characters, up to 16 item rows; and the load window waits for the
> device's slot at `DIT_ADDING` too. Built as recommended: one list fed by
> every window, three missed windows, no Last Action, no read of a listed
> fan, no alias. The code line numbers are those of build 97.

> **Research (2026-11-07) for [issue #102](https://github.com/corytron/c4-modernforms-driver/issues/102)**,
> read-only: nothing here was tried on the house fan or the controller. The
> owner asked that fan discovery run by itself at driver load and
> periodically, as bridge detection does in the Hue driver, and that the
> **Find Fans** action go. Today (v1.1, build 97) Find Fans is a click: one
> multicast DNS question for `_easylink._tcp.local` (sent twice, 1 s apart, 3 s
> of answers) fills `Found Fans`; the owner picks a row and clicks **Use
> Selected Fan**. This note lists the lifecycle corner cases of the new
> behaviour on both sides, decides each one, and ends with the decisions the
> contract must make and the few questions only the owner can answer. The
> mechanism itself (the calls, the binding, the timers) is the other research
> note of #102, `docs/auto-discovery-research.md`; where the two overlap, this
> note decides policy and that one decides mechanics. What changes is narrow:
> **the list fills itself**. Adding a fan stays a click or a typed address;
> adopting another fan, scanning a subnet and matching by name, model or
> address stay forbidden.

**Decisions:** **A** automatic, **O** only offered (shown, waiting for a
click or a typed value), **F** forbidden without a click. **Markers:**
`[verified: source]` names a primary source (an SDK file, a code line, a
hardware check, the Modern Forms primary sources as
[`modernforms-api-research.md`](modernforms-api-research.md) cites them);
`[assumed: why]` is not shown anywhere yet. Ids S1 to S14 and L1 to L31 are
those of [`v1-design.md`](v1-design.md#71-status) 7.1 and
[7.2](v1-design.md#72-last-action); S15, S16 and the new L21 text are
proposals of this note. Placeholders only: fans `10.0.2.151` and
`10.0.2.152`, controller `10.0.2.10`, VM `192.0.2.7`, MAC `00:00:5E:00:53:01`
(log tail `...5301`, a second fan `...5302`), client id `MF_00005E005301`,
instance `MF_Fan_005301`, room "Example Room", keypad "Example Keypad".

| Key | Source |
| --- | --- |
| V1D | [`v1-design.md`](v1-design.md); K10 is its [section 11.1](v1-design.md#111-what-the-probe-has-shown-so-far-17) |
| AFD | [`address-follow-design.md`](address-follow-design.md#1-decisions) (F1 to F9) |
| ECA | [`edge-cases-address.md`](edge-cases-address.md) (E1 to E16, FA1 to FA17, CA1 to CA19) |
| ECC | [`edge-cases-control4.md`](edge-cases-control4.md) (F1 to F33, D1 to D27) |
| ECM | [`edge-cases-modernforms.md`](edge-cases-modernforms.md) (N1 to N10, P1 to P10, H1 to H11) |
| FND, ECR | [`fan-name-design.md`](fan-name-design.md#1-decisions) (N1 to N9), [`edge-cases-rename.md`](edge-cases-rename.md) (RC1 to RC24) |
| MFR | [`modernforms-api-research.md`](modernforms-api-research.md) |
| code | `src/modernforms_fan/driver.lua`, `driver.xml`, `fan/{discovery,follow,model,texts,names}.lua`, `www/documentation.html`; line numbers as of build 97 |
| API, FUND | `~/c4-tools/reference/docs-driverworks-api/source/includes/` and `docs-driverworks-fundamentals/source/includes/`; paraphrased, never copied |
| HUE | the Hue project, read-only (`~/projects/c4-hue-driver`, [public on GitHub](https://github.com/corytron/c4-hue-driver)): `docs/simplify-actions-design.md` (D5, D12, section 3.4, the review table of section 4, rows 2, 3 and 6), `docs/simplify-research-discovery.md` (2.4, 2.5), `docs/simplify-research-compat.md` (section 1), `src/hue_bridge/driver.lua` (Bridges Found, about lines 2912 to 3100, and late init) |

## 0. Evidence the decisions rest on

| # | Fact | Status |
| --- | --- | --- |
| DE1 | On OS 3.4.3 a `MULTICAST` (or plain `UDP`) dynamic binding to 224.0.0.251:5353 sent the question and got the house Gen 3 fan's answers, the first 0.17 s later; each answer holds PTR, SRV (port 80), TXT (`Protocol=com.modernforms.fan`, `MAC=`, `Firmware Rev=`) and the A record in one datagram; nothing foreign arrived in 3 s. The Gen 3 TXT record has **no model**. | [verified: K10; ECA E1] |
| DE2 | One window is one binding: `Finder:find` opens it, sends the question at once and 1 s later, collects for 3 s, closes it, then calls every callback. A `find` while a window is open joins it. Datagrams outside a window are dropped. The window's list keeps the first answer per instance; its `heard` list keeps every distinct (instance, address) pair, up to 64. | [verified: `discovery.lua` 523 to 572, 586 to 641] |
| DE3 | `discovery.parse` keeps only answers with the Modern Forms TXT `Protocol`, needs TXT, SRV and A in one datagram, reads A records only (no IPv6), never raises, and drops addresses that start with 0, 127, or 224 and above; it does **not** drop public addresses or check the SRV port. `discovery.candidates` (the follower's filter) keeps only port 80 and RFC 1918 or link-local addresses. | [verified: `discovery.lua` 258 to 364, 401 to 440; fixture `OTHER_EASYLINK` per ECA FA12] |
| DE4 | Today: Find Fans writes `Found Fans` with the row `Pick a fan` first and writes L8, L9 or L10; Use Selected Fan matches the row text `Properties["Found Fans"]` against the last list and reads that row's address; the pick is cleared after every outcome; late init writes the list empty; a pick does nothing by itself. The follower never writes the list or the pick (AFD F8). | [verified: `driver.lua` 509, 633 to 726, 776 to 779] |
| DE5 | A `DYNAMIC_LIST`'s items are not persisted and are rebuilt by the driver; choosing an item and clicking Set calls `OnPropertyChanged`; the driver's own `UpdateProperty` does not. On the house a list's shown row moved only with `UpdateProperty` beside `UpdatePropertyList`. | [verified: FUND `15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md`; API `24_properties/_3-OnPropertyChanged.md`; `driver.lua` 137 to 145 (a Hue measurement, 2026-10)] |
| DE6 | Network calls, timers, `GetDeviceID` and `UpdateProperty` are not for `OnDriverInit`. `OnDriverLateInit` says why it runs (`DIT_ADDING`, `DIT_STARTUP`, `DIT_UPDATING`) from OS 3.2.0. An update moves every device of the driver at once. Timers die with the driver. | [verified: API `22_miscellaneous/_25.2-SafeUsageTable.md`, `_25.1-OnDriverLateInit.md`, `_24-OnDriverDestroyed.md`; ECC F26] |
| DE7 | `ReceivedFromNetwork` names the sender only from OS 4.0.0 (the driver reads the A record instead). OS 4.0.0 changed several UDP calls as part of retiring LuaSocket. K10 ran on OS 3.4.3 only. | [verified: API `32_serial_network_device/_15-ReceivedFromNetwork.md`, `3_whats_new/_7-WhatsNewin400.md`] [assumed: a `MULTICAST` binding behaves the same on OS 4.x] |
| DE8 | Programming cannot refer to an action; removing or renaming actions in an in-place update worked on the house with the Hue drivers, with no reboot. Actions and properties may come and go in an update. No tool, brief script or spec outside the driver's own specs calls `Find Fans`. | [verified: HUE `simplify-research-compat.md` section 1, items 1 and 4; ECC F2; a grep of `tools/`, `tests/`, `probes/` on 2026-11-07] |
| DE9 | The Hue precedent: Bridges Found searches 3 s after late init, then at 1 and 5 min, then every 15 min **until paired**, and stops once paired; automatic searches write the row and the log, never Last Action (review row 3); Forget Pairing redraws the row and restarts the searches (row 2); a missing bridge gets Attention (row 6); a pick acts at once. Its second stage, a TCP probe of up to two /24 networks (D12), is a subnet scan, which this project forbids. | [verified: HUE `simplify-actions-design.md` 1.8 D5, 1.9 D12, section 4; `driver.lua` Bridges Found] |
| DE10 | The client id is `MF_` or `WAC_` plus the station MAC; a Gen 3 module uses another MAC as an access point. The TXT MAC is the station MAC (shown indirectly). Gen 1/2 TXT records carry `Model` and `Manufacturer`; the Gen 3 answer on the house does not. | [verified: MFR [2.4](modernforms-api-research.md#24-identity-the-static-shadow-and-config-read) (WAC's reference as corroboration only), [7](modernforms-api-research.md#7-discovery-authentication-cloud); ECA E3, E4; K10] |
| DE11 | One HTTP request in flight per device: a Use Selected Fan read and a follower read take that slot. A discovery window uses only its UDP binding. | [verified: V1D V6; `model.lua` `begin_use`; `discovery.lua` `Finder`] |
| DE12 | Rows are written only when their text changes; Composer clips near 75 characters; a list item holds no comma. | [verified: `driver.lua` 126 to 136; ECC F29; V1D 2.5] |
| DE13 | After Use Selected Fan pins a fan, the rename suffix (`; items renamed` and so on) is written about 2 s later only if nothing else wrote Last Action in between. | [verified: `driver.lua` 150 to 160, 700 to 722; FND N4] |
| DE14 | 224.0.0.251 stays on one network segment; fans are reported to announce themselves inconsistently. | [verified: ECA E16 (RFC 6762 section 11)] [assumed: MFR 7's report from the Homey app's journal] |

## 1. The fan and the network

Columns: the trigger; what the fan side and the driver see; the decision;
what the owner sees; why.

| # | Trigger | What each side sees | Dec. | Owner sees | Why (sources) |
| --- | --- | --- | --- | --- | --- |
| DC1 | A new fan is set up in the app while a device is **unpinned** | Fan: answers the next question. Driver: the next window of the unpinned ladder (section 4.2) hears it | **A** list; **O** pick and Use Selected Fan; **F** pin | A row `MF_Fan_005302 at 10.0.2.152`; Status S2 | The owner's request. ECC D1: discovery may run; choosing stays a click |
| DC2 | A new fan joins while every device is **pinned and online** | Driver: heard at the next pinned window (hourly by default) or a follower window | **A** list | The row appears within about an hour | Nothing waits on it: a new fan gets its own device, which searches at once (DC25). Owner question 1 |
| DC3 | Exactly one fan answers a new device | One row | **A** list; **F** pinning it, even as the only one | S2; the row | ECC D1: a second fan's new device, its fan off at the wall, would grab the first fan |
| DC4 | Several fans, one Control4 device per fan | Every device hears every fan | **A** list on each device; **O** one pick per device; **F** matching by name, room or order | Rows sorted: this device's fan first, then by address | V5; ECM N9 (the MAC is the identity, names are only shown) |
| DC5 | A fan is already pinned by **another** device of this driver | Listed like any other; the driver cannot tell without reading the other device | **A** list unmarked; **O** a pick on a second device (then two devices drive one fan); **F** anything automatic | `MF_Fan_005301 at 10.0.2.151` with no mark | ECC D17 (not in v1, V1D 15); ECM P7 (two pollers freeze modules). A mark costs a variable forever: owner question 2 |
| DC6 | The pinned fan is off at the wall or its power is cut | Not heard. Driver: offline after about 45 s; the follower's windows run | **A** the follower as today; the row drops after 3 windows without it | S7; the row goes | V29; a row for a fan nobody hears would mislead. ECA FA2 |
| DC7 | The pinned fan's Wi-Fi or factory reset, set up again in the app | Same MAC and client id, maybe a new address | **A** the follower follows (L30); the list shows it at its new address, marked | `MF_Fan_005301 at 10.0.2.152 (this device's fan)` | ECA FA6, FA7; ECM H10 [assumed there: the MAC survives a reset] |
| DC8 | Set up again with another client id but the same MAC | Only a brand prefix could change (`MF_`/`WAC_`), since the id is the MAC [assumed: never happens] | **A** mark by MAC; **F** the follower refuses (client id); **O** Use Selected Fan re-points | The row marked as this device's fan; after the click `Now using fan WAC_00005E005301 (was MF_00005E005301)` (L3) | DE10; `model.lua` `follow_verdict`, `use_verdict` (identity is client id and MAC) |
| DC9 | The pinned fan replaced by another of the same model, at the same address | Driver: another fan answers there (foreign, S11); the follower looks for the old MAC only | **A** list the new fan; **F** re-pointing by itself, even when the old fan is never heard again; **O** pick and Use Selected Fan | S11 `Another fan (...5302) answers at 10.0.2.151; nothing is sent`; the new row; then L3 | V5; ECA FA9; ECM H1; ECC D18. The names stay (same model: FND N4 finds nothing to change) |
| DC10 | Replaced by a fan at another address | Driver: offline (S7); the new fan is listed | As DC9 | S7; the new row; L3 after the click | As DC9 |
| DC11 | The pinned fan moves to another address on the same segment | Answers from the new address | **A** the follower (V29); the list follows at the next window | L30; the marked row at the new address | AFD F1 to F6 |
| DC12 | The fan on another subnet, VLAN or guest Wi-Fi; client isolation, IGMP snooping or a filtering access point | Nothing heard | **A** nothing; **O** the typed address; **F** a scan, a routed search or a cloud lookup | Unpinned: S16 `Not set up: no fan answered; enter the fan's address in Fan Address` | ECA FA5, E16; ECM N8; the owner's rule against internet reliance |
| DC13 | A router's mDNS reflector repeats a fan from another segment | Heard with an address on another subnet | **A** list (a private address); **O** the click reads it once, which works only if routed | The row | [assumed: reflectors repeat 224.0.0.251]; the click's read decides (V1D 3.5) |
| DC14 | A Gen 4 fan on the network | Its multicast DNS names are not known | **A** list only if it answers as a Gen 1 to 3 fan does; **O** a pick reads it and is refused | L6 `10.0.2.152 is not a Gen 1 to 3 Modern Forms fan; nothing changed` | V4; ECA E5, FA14 |
| DC15 | Another maker's `_easylink._tcp` device answers | Its TXT `Protocol` differs | **F** listed | Nothing | DE3; ECA FA12 |
| DC16 | A malformed, truncated, looping or split answer | Parse skips what is incomplete and never raises | **A** dropped; a debug tally | Nothing | DE3. [assumed: a fan sends all four records in one datagram, as K10's two answers did; one that splits them is never listed] |
| DC17 | Gen 1/2 fans, whose layout differs from Gen 3 | An announcement layout and an instance such as `WAC Windermier Fan#005301` with spaces and `#` | **A** the same parser and list | `WAC Windermier Fan#005301 at 10.0.2.152` | ECA E4 [verified: the CAP fixture]; [assumed: Gen 1/2 answer a question, not only announce] |
| DC18 | A listed fan updates its firmware | Silent for a minute or two, then a new `Firmware Rev` in TXT | **A** the row stays (3-window rule); firmware is not shown, so nothing is rewritten | Nothing | ECM F1, P6; DE12 |
| DC19 | A fan answers multicast DNS but not HTTP (a stuck module) | Listed; HTTP times out | **A** list; **O** a pick reads it | L5 `No fan answers at 10.0.2.152; nothing changed`; pinned and offline: the follower's warning (ECA FA15) | ECM P4. Hiding it would hide that the fan is on the network |
| DC20 | Duplicate answers: one fan twice a window; one MAC at two addresses (a stale cache); two instance names for one MAC; two MACs with one instance name (the 6-digit tail collides and one is renamed) | The window's list keeps the first answer per instance; `heard` keeps every pair | **A** one row per MAC, built from `heard`, with the address of its latest answer; two MACs give two rows; **F** keying rows by instance | Distinct rows per fan | ECA FA10, FA11 (a stale first answer hides the fresh one); RFC 6762 section 9 renames a conflicting instance [assumed: the fans do] |
| DC21 | A public address, 0/8, loopback or multicast; an SRV port other than 80; IPv6 only | Today a public address is listed (DE3) | **F** listed: the list takes the follower's filter (RFC 1918 or link-local, port 80, A records); **O** a typed `Fan Address` for any network | Nothing; a debug line | AFD F4, F8, F9 ("private addresses only"). [assumed: a dealer network on public or 100.64/10 addresses is rare; it types the address] |
| DC22 | A fan with a link-local 169.254 address (no DHCP lease) | Heard | **A** list; **O** pick | The row | Same filter as the follower; it follows later when the fan gets a lease |
| DC23 | Multicast loss on Wi-Fi: a fan missing from one window | One window without it | **A** a row stays until 3 windows in a row miss it | Nothing changes | DE14; ECA E11. A list that flickers loses picks (DC42) |
| DC24 | More than 16 fans | Up to 64 heard per window | **A** 15 rows (this device's fan first, then by address) and a last row `... and 3 more: type the address in Fan Address` | That row | `texts.MAX_FOUND` = 16 (`texts.lua` 43); a sorted list is the same from window to window |

## 2. Control4 and the driver

| # | Trigger | What each side sees | Dec. | Owner sees | Why (sources) |
| --- | --- | --- | --- | --- | --- |
| DC25 | First add of the driver (`DIT_ADDING`): no pin, no address | Late init; the first window 3 s later, with no per-device slot (one device is being added and the owner waits) | **A** search and list; **F** pin, rename, fill `Fan Address` | S15 `Not set up: looking for fans, or enter the address in Fan Address`, then S2 or S16; Last Action empty | ECC D1; DE6; HUE's 3 s. Replaces "Find Fans, choose a fan, Use Selected Fan" |
| DC26 | The owner types `Fan Address` on a new device | The first contact pins the fan (L1); the unpinned ladder ends and the pinned schedule begins | **O** (the typed value); **F** a rename (FND N6) | L1 `Learned fan MF_00005E005301 (Gen 3) at 10.0.2.151`; the row gains `(this device's fan)` at the next window | V1D 3.5; ECR RC1 |
| DC27 | A pick and Use Selected Fan on a new device | One read at the address where the picked MAC was last heard; pinned (L3); the guarded rename | **O** | L3 `Now using fan MF_00005E005301 at 10.0.2.151`, then `; items renamed` | V1D 3.5; FND N4; ECR RC2 |
| DC28 | Update in place, a **pinned** device online (the house) | `DIT_UPDATING`; the Actions tab loses Find Fans; one window at 3 s plus the device's slot | **A** the list fills; **F** writing Last Action, renaming, touching the pin, `Fan Address`, `Follow Address Changes` or Status | Found Fans lists the fan, marked; every other row as before; no "Restart Director?" | DE8 (no capability change); ECC D2; CA8. The owner's last result must survive an update |
| DC29 | Update in place, an **unpinned** device | The unpinned ladder from 3 s plus the slot | **A** | S2 or S16 replace the old S2 text | As DC25 |
| DC30 | A pinned device with an empty `Fan Address` (the stop switch), at an update or any time | Phase unset, nothing sent | **F** any window: the stop switch stops the questions too | S1 `Not set up: enter the fan's address in Fan Address` | AFD F5 ("never filled, never searched"); ECA CA4. Typing an address resumes |
| DC31 | Director restart or controller reboot (`DIT_STARTUP`) | Every device's late init; windows at 3 s plus each device's slot | **A** | The list refills within about 30 s; nothing else | DE5 (lists are not persisted); ECC D9; follower slots (`follow.lua` 41 to 45) |
| DC32 | Whole-house power cut; the controller is up before the router and the fans | Windows cannot open or send, or hear nothing | **A** the ladder goes on; one warning per streak; nothing in Last Action | Unpinned: S1 while no question can be sent, S16 while sent and unanswered | ECA FA17; `Finder:finish` error words |
| DC33 | Project restored from a backup on the same controller | Lists are not in the backup; the pin from the store or the `Fan ID` row | **A** the load window refills; **F** learning a fan from the list | As DC31 | DE5; ECC D10; ECA CA9 |
| DC34 | Restored on a new controller, or the project copied to another house | The pinned MAC is not on that network; other fans are | **A** list; **F** adopting one; **O** pick and Use Selected Fan | S7 or S11; other rows | ECA CA10; ECC D18 |
| DC35 | A device copied or duplicated in Composer | If the copy keeps `Fan Address` and `Fan ID` with an empty store, it pins from the row (two devices, one fan) | **F** anything automatic; **O** re-point one of them | Both lists mark the fan as their own | ECC D10, D17. [assumed: whether Composer Pro copies a device with its properties at all] |
| DC36 | Device deleted and added again | A new device id, an empty store and empty rows: unpinned | **A** search; **F** re-adopting the old fan, even as the only one heard; **O** pick (the defaults are then renamed, FND N4) | S15, then S2 | ECC D8, D1 |
| DC37 | OS 3.x against OS 4.x | 3.4.3 verified; 4.0.0 changed UDP calls; the sender parameter is not needed | **A** as on 3.x; a failure looks like DC12 | S16 or S1; the typed address works | DE7. Parked: no OS 4 controller on the house |
| DC38 | A project with many fans: every device searching | An update or a restart starts every device together; windows that overlap hear each other's answers (multicast) | **A** spread by the slot of 3.5 s per device (device id mod 8); unpinned about 100 windows a day per device, pinned about 25 | Nothing | ECA 3.3 (the ladder's count); [assumed: two `MULTICAST` bindings on 5353 opened in the same moment both work, ECA CA11; a refused open ends as DC32] |
| DC39 | The owner types `Fan Address` while a window runs | The edit acts at once (a contact; the follower pending, AFD F5); the window ends later | **O** the typed value wins; **F** the window touching `Fan Address` | S4, then L1 or S5 | ECA CA2, CA3 |
| DC40 | Use Selected Fan while a window runs | The click's target is fixed at the click; the window's rewrite keeps the pick until the click's outcome clears it | **O** | The click's own line | DE4; ECA CA5 (one binding, one window) |
| DC41 | Use Selected Fan on a stale row: the picked fan moved, or another fan now answers at its address | One read at the picked MAC's latest address: another MAC, or silence | **O** nothing changes; **A** one window at once (rows only) so the list shows where the fan is now | L21 `The fan at 10.0.2.151 is not the one picked; nothing changed`, or L5 | `model.lua` `use_verdict` (`not_picked`); today's L21 says "Find Fans again", which no longer exists |
| DC42 | The list is rewritten while the owner has a pick set | A rewrite as Find Fans makes one today selects `Pick a fan`: the pick would be lost and the click would fall back to `Fan Address` | **A** a rewrite keeps the pick selected (by MAC, under its new address text if it moved), never drops a picked row, and happens only when the rows change | The pick stays shown | DE4, DE5. [assumed: a rewrite also resets a drop-down the owner has open but not Set; writing only on change makes that rare] |
| DC43 | Composer open, or closed, when the list changes | Director holds the list; Composer reads it when the page opens | **A** | Closed: the next open shows the current list | [assumed: an open Properties page repaints a rewritten list by itself; K23] |
| DC44 | Debug Mode On or Off | Each window's tally is a debug line today | **A** one always-on line when the rows change, MAC tails only; window tallies at debug; one warning per streak when nothing can be sent | Log: `Found Fans: 2 fans (...5301 at 10.0.2.151, ...5302 at 10.0.2.152)` | V1D 3.7 (MACs as their last four digits; addresses may be logged) |
| DC45 | Dev builds | Dev State, the redactor, property reports to the VM | **A** Dev State gains the schedule's state; Found Fans reaches the VM in property reports (instance names carry six MAC digits) and never GitHub unreplaced | Nothing | V1D 3.7, 9.10; `docs/dev-loop.md`. A dev-only command to open a window now is allowed (the no-one-off-tooling rule binds shipped builds) |
| DC46 | Existing projects lose the action | The in-place update removes the button; programming never named it | **A** | The Actions tab shows five actions | DE8. The manual, README, checklist and SECURITY.md change (section 4.6) |

## 3. Interplay with what the driver already does

| # | Trigger | What each side sees | Dec. | Owner sees | Why (sources) |
| --- | --- | --- | --- | --- | --- |
| DC47 | The follower (V29) and the automatic search | One binding, 6001, and one window at a time; a `find` during a window joins it (DE2). Today the follower never writes the list (AFD F8) | **A** every window's `heard` list, the follower's included, feeds the one list writer; the list schedule pauses while the follower is armed; the follower still never changes the pick and writes no Last Action but L30 and L31 | While the fan is away, the list shows where fans are now | A stale list is the worst one to pick from (DC9). AFD F8's "touching `Found Fans`" becomes "changing the pick" |
| DC48 | Last Action, and the rename suffix after Use Selected Fan | An automatic line would overwrite the owner's last result, and would cancel the suffix (DE13) | **F** an automatic window writing Last Action | Last Action changes only after a click, a typed address, a follow (L30, L31) or a refused follow | HUE review row 3; ECA CA15 |
| DC49 | Status texts that name Find Fans | S2 names it; L7 does not; L8 to L10 exist only as the click's results; L21 says "Find Fans again" | **A** new S2, S15, S16; S1 when no question can be sent; L8 to L10 retired (their content goes to the list's first row and the log); new L21 | Section 4.5 | V1D 7.1, 7.2; the 70-character limit (ECC F29) |
| DC50 | The names rule | Only Use Selected Fan (guarded) and Name Items After Fan rename | **F** a rename from any window, list change or first contact | Nothing | FND N4, N6; ECR RC1, RC6 |
| DC51 | "A different fan is never taken by itself" and "no subnet scan, ever" | The list only offers | **F** adopting or learning a listed fan, an HTTP read of a listed fan by itself (to show its product name, say), any probe of an address nobody announced | Nothing | V5; V1D 15; AFD F8; ECM N10. A read would also take the device's one request slot (DE11) |
| DC52 | Keypad presses and the 10 s click rule while a window runs | A window uses only its UDP binding; the fan links and their click rule (V1D 5.1) use the transport and the proxies | **A** nothing interacts | Presses act as always | DE11 |
| DC53 | The schedule while pinned and the fan answers: what for? | The follower covers a moved fan; a pinned device's list matters only for re-pointing (a replacement, DC9) and for showing new fans | **A** one window at load, then hourly by default | The list is at most about an hour old | Owner question 1. HUE stops searching once paired (DE9) |
| DC54 | `Follow Address Changes` Off | The follower is off; the list keeps its schedule | **A** the pinned schedule goes on (it only looks) | Nothing | AFD F7. The switch is about moving the device, not about looking |
| DC55 | What a row shows | The instance name, the address, the mark `(this device's fan)` | **A** that, unchanged; **F** the product name of another fan (needs an HTTP read, DC51); the product name of this device's fan is in `Fan Model` already | `MF_Fan_005301 at 10.0.2.151 (this device's fan)` | DE1, DE10 (no model in a Gen 3 TXT record); FND N3. "Used by Example Room" is owner question 2 |
| DC56 | `SECURITY.md` ("What the driver talks to") | Today: the question of Find Fans, and since #39 the follower's | **A** reworded: the same question also goes out by itself at load and on a schedule; nothing else is sent to a listed fan without a click | — | AFD F9 set the pattern; the owner reads the change in the PR |

## 4. Recommendation

### 4.1 The rule

The driver keeps `Found Fans` current by itself. It asks the same multicast
DNS question as today, at load and on a schedule, and writes what it hears
into the list and the log. It never writes Last Action for that, never pins,
reads, renames or adopts a listed fan, never fills `Fan Address`, never scans.
The owner still accepts a fan with a pick and **Use Selected Fan**, or by
typing `Fan Address`. The **Find Fans** action and its command go, and no
"Search again" row takes their place (the Hue list has one): the schedule
and the refresh after a failed pick (DC41) cover it.

### 4.2 When it asks

| State of the device | Windows | Notes |
| --- | --- | --- |
| Unpinned (no pin; any `Fan Address`) | first at late init + 3 s (`DIT_ADDING`), or + 3 s + the device's slot (id mod 8, 3.5 s each) + 0 to 0.5 s (`DIT_STARTUP`, `DIT_UPDATING`); then 30 s, 1, 2, 5, 10 min after the previous window closed; then every 15 min; each step ±20 %, never closer than 30 s | The follower's ladder (AFD F3; `follow.lua` 41 to 52), so one shape of schedule; about 8 windows in the first hour, then 4 an hour |
| Pinned, the follower not armed (online, waiting, rebooting, or switched Off) | one at late init + 3 s + the slot; then every 60 min ±20 % | Owner question 1; about 25 a day |
| Pinned, the follower armed (offline-like) | the follower's windows only, and they feed the list | No second schedule on top of it (DC47) |
| Pinned, `Fan Address` empty (the stop switch) | none | AFD F5 |
| After a click's L5 or L21 on a pick | one window at once (not before 30 s after the last) | DC41 |
| Unpinned becomes pinned (L1, L3) | the unpinned ladder ends; the next window in 60 min | DC26, DC27 |

Memory only, as the follower: a restart starts afresh. No quiet hours: a
question is silent and cheap (two 38-byte datagrams, ECA 3.3).

### 4.3 The list

- **Built from every window's `heard` list**, keyed by MAC (by the instance,
  case aside, when an answer has no MAC), with the address of the key's
  latest answer. RFC 1918 or link-local addresses and SRV port 80 only, as
  `discovery.candidates` filters (DC21).
- **Kept** until 3 windows in a row miss a fan (DC23). A picked row stays
  until the click's outcome or a new pick (DC42).
- **Order:** this device's fan first, then by address, numerically; at most
  15 fan rows plus the overflow row (DC24). The same fans give the same rows,
  so the list is **written only when its rows change**, with the pick kept
  selected.
- **Rows** as today: `<instance, cut to 30 characters> at <address>`, plus
  ` (this device's fan)` when the MAC is the pinned one. The first row, which
  means "no pick", reads `Pick a fan`, or `No fan answered yet` while the list
  is empty.

### 4.4 The pick

`OnPropertyChanged` on `Found Fans` records the picked fan by its MAC (or key)
in memory; the first row, the overflow row and the late-init replay record no
pick (DE4: late init writes the list before the replay). Use Selected Fan
reads the address where that MAC was last heard and checks the MAC there
(`not_picked`, L21), as today. The pick is cleared after every outcome; L5
and L21 on a pick start one window (DC41). Without a pick the click uses
`Fan Address`, as today.

### 4.5 Texts

| Id | When | Text |
| --- | --- | --- |
| S1 | unset, and no question could be sent in the last window, or a pinned device with an empty `Fan Address` | `Not set up: enter the fan's address in Fan Address` (unchanged) |
| S2 | unset, the list holds a fan | `Not set up: pick a fan in Found Fans, then click Use Selected Fan` (65; replaces `Not set up: Find Fans, or ...`) |
| S15 | unset, before this run's first window has closed | `Not set up: looking for fans, or enter the address in Fan Address` (65) |
| S16 | unset, windows ran and nothing answered | `Not set up: no fan answered; enter the fan's address in Fan Address` (67) |
| L7 | Use Selected Fan with nothing to use | unchanged: `Nothing to use: pick a fan in Found Fans, or enter Fan Address` |
| L8, L9, L10 | (the click's results) | retired; their content is the list's first row and the log |
| L21 | the picked fan is not at its address | `The fan at 10.0.2.151 is not the one picked; nothing changed` (64 with a 15-character address) |
| list | first row; overflow | `Pick a fan` or `No fan answered yet`; `... and 3 more: type the address in Fan Address` |
| log, always | the rows changed | `Found Fans: 2 fans (...5301 at 10.0.2.151, ...5302 at 10.0.2.152)`; `Found Fans: no fan answered` |
| log, warn | nothing could be sent, once per streak | `Looking for fans: the query could not be sent on this controller` |
| log, debug | each window | the tally `Find Fans` writes today (sent, answers, others, queries, unparsed, fans), renamed |

Status keeps V1D 7.1's priority: S3, then S1, S2, S15 and S16, then the rest.

### 4.6 Documents and code the coordinator changes

[`v1-design.md`](v1-design.md): V5, V5a, [2.5](v1-design.md#25-properties-in-this-order)
row 5, [2.6](v1-design.md#26-actions), [3.5](v1-design.md#35-first-contact-identity-and-address-changes)
(the pick is a MAC), 7.1, 7.2, [7.3](v1-design.md#73-the-other-rows) (the
`Found Fans` row), 9.1, [9.10](v1-design.md#910-fandevcmdslua-and-fandiscoverylua),
[14](v1-design.md#14-the-manual-documentation-tab) items 3, 8, 10, 11 and
13, [15](v1-design.md#15-not-in-v1). [`address-follow-design.md`](address-follow-design.md#1-decisions)
F8 (DC47). [`edge-cases-control4.md`](edge-cases-control4.md#3-driver-life)
D1's "Owner sees". [`composer-checklist.md`](composer-checklist.md) steps 1,
4, 5, 6, 9, 43 and 45. The manual
([`documentation.html`](../src/modernforms_fan/www/documentation.html#find-fans)):
the network note, chapter 3's Find Fans section and the Status table,
chapter 8's fallbacks, the property and action tables, chapter 11's steps,
the troubleshooting row, the privacy paragraph. [`README.md`](../README.md)
(finding the fan, the network note, the install steps). [`SECURITY.md`](../SECURITY.md)
(DC56). `CLAUDE.md`'s Scope line on Find Fans. `CHANGELOG.md` (Unreleased,
#102). `docs/status.md`. [`docs/README.md`](README.md) indexes this note (a
research note, so the docs index, not the front page). Code and specs:
`driver.xml` (the action and the `Found Fans` comment), `driver.lua`,
`fan/texts.lua`, `fan/discovery.lua` (comments), `fan/follow.lua` (the list
feed, if the follower calls it), `fan_driver_spec` (the action list, the S2
assertion, the Find Fans block), `texts_spec`, `discovery_spec`.

### 4.7 Checks on the house

Each under a minute, none blocking ("No long test waits").

| # | Check | How | Settles |
| --- | --- | --- | --- |
| K23 | After the update in place, with Composer open on the fan item and no click: `Found Fans` and `Last Action` read at once and after 30 s | Windows session, read-only | DC28 (the list fills, Last Action keeps its line), DC43 (whether the open page repaints by itself) |
| K24 | Optional: a throw-away device added in a test room, no pick: Status S15, then S2 within about 10 s; the row unmarked; then the device deleted | Windows session (adding and deleting are covered by the standing approval) | DC25, DC5 |
| — | Parked: an OS 4.x controller (DC37); two devices opening their windows in one instant (DC38) | no such controller; not reproducible on demand | — |

## 5. Decisions the contract must make

Each with the recommended default.

1. **Schedule:** section 4.2: the follower's ladder while unpinned; one window
   at load and then hourly while pinned and not followed; only the
   follower's windows while it is armed; none with an empty `Fan Address` on
   a pinned device; memory only.
2. **One list writer, fed by every window** (the automatic one, the
   follower's, the one after L5 or L21): it writes the row and the log, never
   Last Action. AFD F8 changes to "the follower never changes the pick".
3. **List rules:** section 4.3: keyed by MAC from `heard`, private or
   link-local addresses and port 80 only, sorted, at most 16 rows, kept for 3
   missed windows, written only on change, today's row format.
4. **The pick is a fan, not a row text:** recorded at `OnPropertyChanged`,
   kept across rewrites, cleared after every click outcome; the click reads
   the picked MAC's latest address.
5. **Texts:** section 4.5: S2 rewritten, S15 and S16 added, S1 for "cannot
   ask", L8 to L10 retired, L21 rewritten, L7 kept.
6. **The action and its command:** removed from `driver.xml` and from the
   dispatch table, with no hidden alias (nothing calls it, DE8; HUE's aliases
   served tools that called its actions); the other actions keep their
   `sort_order`. A dev-only command may open a window for tests.
7. **Nothing new that is forever:** no variable, event, command, connection
   or capability; no reboot; nothing new persisted.
8. **No reads of listed fans:** no product name for other fans; the list
   shows what the answer says.
9. **First window timing:** 3 s at `DIT_ADDING`, 3 s plus the device's slot
   at a restart or an update.
10. **K23 runs at the release install;** K24 is optional; OS 4.x is parked.

## 6. Questions for the owner

Each has a default that holds until the owner answers.

1. **Should a pinned device keep refreshing `Found Fans` while its fan
   answers?** Hourly, so a replacement fan or a new fan shows up within an
   hour, or only once at load (the Hue driver stops searching once paired).
   Default: **hourly**.
2. **Should a row say that another device of this driver already uses that
   fan** (`... (used by Example Room)`)? It needs a hidden variable on every
   device that can never be removed again (ECC F24), read across devices.
   Default: **no**, parked with ECC D17.
3. **Should a pick in `Found Fans` accept the fan when Set is clicked**, as
   Bridges Found does in the Hue driver, instead of waiting for Use Selected
   Fan? Default: **no**: the pick waits for Use Selected Fan, which stays the
   one accept click and the guarded rename.
