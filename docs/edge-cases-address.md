# Edge cases and lifecycle policy: following the fan's address

> **Status (2026-11-13, #213).** Built for 1.0 (#39) by
> [`address-follow-design.md`](address-follow-design.md) (F1 to F9), which
> wins where it and this note differ. The rule of section 3 holds, and the
> owner's five questions were answered as recommended. Changed by the
> contract: the texts proposed here as L22 and L23 are **L30 and L31** (L22
> to L29 went to Name Items After Fan); a pin without a MAC is never
> followed (no MAC is derived from the client id, review of #48); the first
> window opens 2 s after arming plus a slot of 3.5 s per device (device id
> mod 8) plus 0 to 0.5 s, not 0 to 3 s of jitter; and `heard` keeps up to 64
> pairs, not 8. Since 1.2 (#102) the Find Fans action is gone and every
> window, the follower's included, feeds `Found Fans`
> ([`auto-discovery-design.md`](auto-discovery-design.md#1-decisions), AD6
> and AD10), which replaces CA5 and the "never touches `Found Fans`" of
> sections 3.5 and 3.7. The manual's line numbers in section 3.8 are those
> of 2026-11-04.

> **Research (2026-11-04) for [issue #39](https://github.com/corytron/c4-modernforms-driver/issues/39)**,
> read-only: nothing here was tried on the house fan or the controller. The
> owner asked: "once we identify the fan in the driver we never have to
> manually do anything if its IP address changes." The contract says the
> opposite today: [`v1-design.md`](v1-design.md) V5 ("a new address of the
> pinned fan is followed when the owner types it or picks it, never on its
> own; no subnet scan, ever"), V5a, section 15, the manual, and
> [`edge-cases-modernforms.md`](edge-cases-modernforms.md) (ECM) N1, N3 and Q3.
> The earlier research already foresaw this: ECM N1 ("If the transport
> research finds passive discovery (an mDNS announcement or SDDP carrying the
> stored MAC), the new address is taken automatically and logged") and
> [`edge-cases-control4.md`](edge-cases-control4.md) (ECC) D19 (**A**:
> `Fan Address` updated by the driver, same identity only, noted in `Last
> Action`). Since then probe K10 showed that the driver's own multicast DNS
> query works on the house. This note enumerates the corner cases of the
> feature on both sides, decides each, and recommends the rule the
> coordinator turns into the contract. What changes is narrow: **the same fan
> is followed**; adopting another fan, scanning, and matching by name, model
> or address stay forbidden.

**Decisions:** **A** automatic (only after the checks of section 3), **O**
offered (a click: Find Fans, Use Selected Fan, typing `Fan Address`), **F**
forbidden without a click. **Markers:** `[verified: source]` names a primary
source, `[assumed: why]` is not shown. S1 to S14 and L1 to L21 are the ids of
V1D 7.1 and 7.2. Placeholders only: fans `10.0.2.151` and `10.0.2.152`, MAC
`00:00:5E:00:53:01`, client id `MF_00005E005301`.

| Key | Source |
| --- | --- |
| V1D, MFR, ECM, ECC | [`v1-design.md`](v1-design.md), [`modernforms-api-research.md`](modernforms-api-research.md), [`edge-cases-modernforms.md`](edge-cases-modernforms.md), [`edge-cases-control4.md`](edge-cases-control4.md); K10 is V1D 11.1 |
| code | `src/modernforms_fan/fan/{discovery,model,transport,wire,texts}.lua`, `driver.lua`; specs in `tests/spec/`, fixtures `tests/fixtures/mdns.lua` |
| API, FUND | the SDK under `~/c4-tools/reference/docs-driverworks-api/source/includes/` and `docs-driverworks-fundamentals/source/includes/`; paraphrased, never copied |
| CAP | `modernformasfan.pcapng` in the `aiomodernforms` repository (a Gen 1/2 fan, firmware 01.03.0025, 2021), decoded with tcpdump on 2026-11-04; no value of it is copied here |
| RFC | RFC 6762 (multicast DNS), sections 5.2, 8.3, 8.4, 10.2, 11, read 2026-11-04 |
| HA | Home Assistant `modern_forms`, `config_flow.py` and `manifest.json` on `dev`, read 2026-11-04 through a fetch tool that summarises |
| HUE | the Hue project (`~/projects/c4-hue-driver`, read-only): `docs/design.md` "Discovery", "Storage", "Concurrent transfers"; `docs/bridge-compat-design.md`; a grep of its `src/` |

## 0. Evidence the recommendation rests on

| # | Fact | Status |
| --- | --- | --- |
| E1 | The house Gen 3 fan (ESP32, firmware 02.00.0052) answers a PTR query for `_easylink._tcp.local` with one multicast datagram per query, 0.17 s after a `MULTICAST` query (0.35 s with a plain `UDP` binding): PTR (ttl 4500), SRV (ttl 120, port 80, target `<instance>.local`), TXT (ttl 4500) and the A record (ttl 120). The instance is `MF_Fan_` and the last six digits of the MAC. The TXT strings are `Protocol=com.modernforms.fan`, **`MAC=` six colon-separated uppercase hex pairs** and `Firmware Rev=`. The controller's own queries were not echoed and nothing foreign arrived in 3 s. | [verified: K10 (V1D 11.1, 9.10) and the probe's own log `build/m1/win/m1/k10-mdns-lua.txt`, untracked] |
| E2 | **So a Gen 3 answer carries the MAC, and the code reads it**: `discovery.parse` returns `mac` as 12 uppercase hex digits (`mac12`: bare, `:` or `-` separators), nil when the key is missing or malformed. The fixtures rebuild K10's two layouts (250 and 299 bytes) with `MAC=00:00:5E:00:53:01`. | [verified: `discovery.lua`; `tests/fixtures/mdns.lua`; `discovery_spec` "reads a MAC as 12 uppercase hex digits", "keeps a fan whose TXT record has no MAC"] |
| E3 | That TXT MAC is the station MAC the fan reports over HTTP: the owner's Use Selected Fan with a Found Fans pick was accepted on the house, and `Model:after_use` answers L21 (`not_picked`) when the pick's MAC differs from the fan's `mac`. An indirect proof; no direct comparison was logged. | [verified: `status.md` ("Found with Find Fans and accepted with Use Selected Fan"); the Phase 1 read-back of 2026-11-04 (`build/m3/m3/phase1-readback.txt`, untracked): `Last Action` read `Now using fan ... at <address>` after the click; `model.lua` `after_use`; `driver.lua` `Use_Selected_Fan`] |
| E4 | **Gen 1/2 carry the MAC the same way.** CAP shows one unsolicited announcement (not an answer): all four records in the answer section, ttl 1500, cache-flush on TXT, SRV and A, instance `WAC Windermier Fan#<6 hex>`, the same `MAC=` spelling beside `Hardware Rev`, `MICO OS Rev`, `Model`, `Manufacturer`, `Seed`. The parser reads that layout (spaces and `#` in the name, any section, cache-flush). That a Gen 1/2 fan answers a *query*, and that its TXT MAC equals its HTTP `mac`, are not shown. | [verified: CAP; `discovery_spec` "keeps the printable ASCII of an instance label, spaces and # included"] [assumed: any mDNS responder answers (RFC 6762 section 6); same module family; no Gen 1/2 fan on the house] |
| E5 | Gen 4 answers `/mf` with 404 and is refused (V4), so a pin is never Gen 4; its mDNS names are unknown. | [verified: V1D 1 V4; MFR 1] |
| E6 | The pin is `{client_id, mac, generation, address, learned}` in `mf_identity`, or parsed from the `Fan ID` row when the store is empty; `Model:same` needs the client id equal, and the MAC equal when both exist. A pin learned at first contact always has a MAC. | [verified: `model.lua` `start`, `same`, `finish_contact`; `texts.parse_fan_id`; V1D 8] |
| E7 | `Model:use_fan` is already "one info read at an address, adopt on a match": a non-match puts the address back and starts a `resume` contact; `begin_at` (the owner's edit) abandons a read under way; `Finder:find` while a window is open joins it. | [verified: `model.lua` `use_fan`, `after_use`, `abandon`; `discovery_spec` "lets a second find join the window"] |
| E8 | `OnPropertyChanged` is **not** called when the driver itself calls `UpdateProperty`. `UpdateProperty`, `SetTimer`, `CreateNetworkConnection`, `NetConnect` and `SendToNetwork` must not run before late init. Persisting spuriously stops Director from ever flushing. Timers die at `OnDriverDestroyed`. | [verified: API 24/_3-OnPropertyChanged, 24/_5-UpdateProperty, 22/_25.2-SafeUsageTable, 22/_24-OnDriverDestroyed; FUND 24/_1] |
| E9 | The driver already writes the editable `Fan Address` row itself, in Use Selected Fan, and Composer showed it on the house: the same read-back lists `Fan Address` = the picked address after a click whose `Last Action` was `Now using fan ... at <address>`, a text with no earlier pin, so no typed address had worked before and the row was evidently written by `prop`. Reading the new value back from `Properties` right after the write, and the value after a Director restart, are not shown for this row. | [verified: `build/m3/m3/phase1-readback.txt`; `driver.lua`] [assumed: the Properties table "contains the current value" (API 24/_1); properties are saved in the project (FUND 24/_1)] |
| E10 | `ReceivedFromNetwork` gets the sender only from OS 4.0.0; the driver uses the A record's address. | [verified: API 32/_15-ReceivedFromNetwork; `discovery.lua`] |
| E11 | A responder announces at start (at least two, one second apart) and **must re-announce when an address changes**, with the cache-flush bit; a continuous querier doubles its interval and may cap it at 60 minutes; a response sent to the group counts as local whatever its source (spoofing is the stated worry). Whether the Gen 3 fan re-announces after a lease change is not seen; the driver listens only in 3 s windows and would not hear it. | [verified: RFC 5.2, 8.3, 8.4, 10.2, 11] [assumed: the fan follows the RFC] |
| E12 | HA keys on the TXT MAC and, for a MAC it already has, **overwrites the stored host without an HTTP check**; its zeroconf filter is a name pattern, `wac*`. | [verified: HA] |
| E13 | The Hue project built no follow: a new bridge address is typed and the pairing survives; its designed discovery-endpoint follow ("IP change") has no code; it checks `/api/0/config` for the paired id before any keyed request and asks again every 30 s while the bridge is silent. It never ran multicast DNS from a controller ("Whether this works on the controller is assumed"), so K10 is the first evidence. | [verified: HUE "Discovery" (as built), `bridge-compat-design.md`, no `mdns` in its `src/`] |
| E14 | The stock WAC driver reached the fan by a static address on connection 6000, no SDDP. Gen 1-3 fans offer no SDDP (absence in WAC's reference); ARP (`C4:GetDeviceMAC`) maps an address to a MAC, not back. | [verified: V1D K1, K3; MFR 7; API 32/_7-GetDeviceMAC] |
| E15 | Offline is 3 failures in a row (about 45 s), polls then at 10, 20, 40, 60 s; a foreign fan is seen at the first answer, identity reads every 60 s; rebooting lasts up to 120 s. Director runs at most four `C4:url` transfers; an abandoned one holds its slot until its own timeout, here 5 s. | [verified: `model.lua` constants; V1D 3.4, 9.11; HUE "Concurrent transfers"; `transport.lua`] |
| E16 | Multicast from the controller reached the Wi-Fi fan and back on the house network. Across subnets, VLANs, guest Wi-Fi, client isolation, IGMP snooping or a multicast-filtering access point it need not: 224.0.0.251 is link-local. | [verified: K10] [assumed: for any other network, RFC 6762 section 11] |

## 1. The fan and the network

Columns: what the fan and network do; what the driver does; the decision; why.

| # | Case | Fan and network | Driver | Dec. | Reason and source |
| --- | --- | --- | --- | --- | --- |
| FA1 | Lease change or power cut gives the fan a new address | Same MAC and client id; answers a query within about 0.2 s (E1); a re-announcement is assumed (E11) | Polls at the old address fail: offline after 3 failures, or foreign / not a fan at once if something took the address. Step 1 of the ladder finds the MAC, one read confirms it, the address moves | **A** | The owner's case. ECM N1, ECC D19 foresaw it |
| FA2 | Fan switched off at the wall for hours or days | Nothing answers, mDNS or HTTP | A window finds nothing and **changes nothing**; Status stays S7/S8; polls stay at 60 s; the ladder settles at one window per 15 min | **A** the search; **F** any text that says "moved" or "gone", any step faster than the cap | Silence proves nothing: power, a stuck module and another subnet look alike (ECM P1, P3). Cost in 3.3 |
| FA3 | Fan comes back at the same address | Boots; HTTP up after seconds | The 60 s poll finds it first (V1D 6.3); a window that hears the MAC at the current address changes nothing | **A** nothing | Existing path |
| FA4 | Reboot Fan or firmware update | Silent for up to about 2 min; may return elsewhere | No search while rebooting (silence is expected, V23); at 120 s the phase is offline and the ladder starts | **A** after the window, **F** during it | V1D 6.4; ECM P6, F1 |
| FA5 | Router replaced, new subnet, VLAN, guest Wi-Fi, filtered multicast | Controller and fan on one new subnet: as FA1. Different subnets: the query does not arrive (E16) | Nothing heard, nothing changed; the device stays "not answering"; the owner types the address as today | **A** (nothing), **O** the typed address | No routed discovery, no scan (V5). ECM N6, N8 |
| FA6 | Wi-Fi set up again in the app | The fan is off the LAN in access-point mode, then joins, probably elsewhere; same MAC | As FA1, after minutes of silence: the ladder is at its slow steps, so at most one cap interval of waiting | **A** | ECM N5, N6 |
| FA7 | Factory reset | Wi-Fi, pairings, schedule cleared; MAC unchanged [assumed: ECM H10] | As FA6. A different MAC is a different fan (FA9) | **A** same MAC, **F** otherwise | ECM H10 |
| FA8 | Two fans swap addresses | Each answers at the other's address | Device A sees fan B at its address: foreign, ladder at once; its window finds A's MAC at the other address; the read confirms; it moves. Device B the same. Jitter keeps the windows apart. After a failure no command goes out before the identity is read again (contact rule); a swap between two polls while both stay online is the existing window of one poll interval (`on_state` checks `clientId` on each answer, not before a command), not widened | **A** both | Each device accepts only its own MAC. ECM N3 |
| FA9 | Another Modern Forms fan at the pinned fan's old address, or a replacement fan | Answers normally as someone else | S11 as today; the ladder looks for the **pinned** MAC only; the other fan is never adopted or written to. If the pinned MAC is nowhere, the device stays foreign with its 60 s identity reads; the owner's click re-points (L3) | **F** adopting, **A** following the pinned fan, **O** Use Selected Fan | V5, ECM N3, H1, ECC D18 |
| FA10 | The pinned MAC heard at two or more addresses (a gateway's stale record, a duplicate address, a cloned MAC) | Any of them may answer HTTP | Candidates in the order heard, at most 3 addresses; one equal to the current address is none; the first that passes the read wins, the rest are not contacted. At most 3 follows an hour (L23) | **A** first verified, then the flap guard | The identity is the only handle; a wrong pick reaches a device that claims to be the pinned fan, never another model |
| FA11 | Stale, cached, forged or lying answer | Gen 3 ttl 120 s (A record), Gen 1/2 1500 s (E1, E4); a gateway cache can repeat an old address; any host on the link can multicast a forged one | Never acted on alone: one read must return the pinned client id **and** MAC; only RFC 1918 and link-local addresses are read; at most 3 per window; the Finder keeps no cache between windows. Its dedupe by instance keeps the **first** answer, so a stale first answer would hide the fresh one: the follower needs every distinct address of an instance (3.9) | **A** through the read only, **F** acting on an answer alone or reading a public address | RFC 11; SECURITY.md (3.7); `discovery_spec` "de-duplicates by instance" |
| FA12 | A non-fan answers `_easylink._tcp` (other makers share the service name) | TXT `Protocol` differs | Skipped by the Protocol filter, then by the MAC | **F** | `discovery.lua`; fixture `OTHER_EASYLINK` |
| FA13 | Gen 1/2 fans | Same TXT keys and `MAC=` spelling, announcement layout and name differ (E4) | Same rule, same parser; their answer to a query is assumed | **A**, tried on Gen 3 only; the manual says so | E4 |
| FA14 | Gen 4 | Different protocol (E5) | A Gen 4 fan at the old address is `gen4` (S12): the ladder runs as for foreign; a Gen 4 candidate fails the read with 404 and is skipped | **F** following or driving it | V4 |
| FA15 | The fan answers mDNS but not HTTP (booting, or a stuck Wi-Fi module) | UDP up, TCP not [assumed: separate services] | The read fails: nothing changes. It is repeated at +10 s, +30 s and +90 s without a new window, then the ladder goes on. Heard at the **current** address: one warn per streak ("on the network, web server silent"); Reboot Fan cannot help then | **A** retry, **F** following without the read | ECM P4 |
| FA16 | TXT MAC missing, spelled otherwise, or not the station MAC | `mac12` accepts bare, `:` and `-`; Gen 3 has a second (access-point) MAC | No MAC match is no match; the fan still shows in Find Fans | **F** matching by instance name (6 digits = 24 bits), model or address | V5; ECM N9 and "Two MACs" |
| FA17 | Whole-house power cut; the controller boots before router and fan | No network for minutes | `find` ends with `open` or `send` errors: the step counts as not done, the ladder goes on, one warn per streak, nothing in Last Action | **A** | `Finder:finish` error paths |

## 2. Control4 and the driver

| # | Case | What happens | Dec. | Reason and source |
| --- | --- | --- | --- | --- |
| CA1 | The driver writes `Fan Address` itself | `OnPropertyChanged` will not follow (E8), so the model changes first (address, epoch, `mf_identity`) and the same function then writes the row. The address is passed, never read back (E9). Nothing runs before late init or in `OnDriverInit`. Same order as Use Selected Fan today | **A** | E8, E9; `driver.lua` |
| CA2 | The owner types an address at the same moment | `Model:begin_at` abandons a read under way; the follow's callback gets `no_answer` and does nothing. The later Set wins over an earlier follow | **O** owner wins | E7 |
| CA3 | The owner types an address later: the old one, a typo, another fan's, one for later | **Pending** until the pinned fan has answered at it (the Online phase), unless it equals `pin.address`, the last address the fan was seen at. While pending no window runs. A restart ends the rule (memory only: the pin, not the typed text, is the owner's lasting decision). Keeps checklist step 42 (type the second fan's address) and the re-point flow working | **F** the follow never overrides a typed address | ECM rule 3; "automation that makes a later manual fix harder is wrong" |
| CA4 | `Fan Address` empty, fan pinned | Phase unset, nothing sent, pin kept (V1D 3.5) | **F** no window, the row is not filled | The documented way to stop all traffic |
| CA5 | Find Fans clicked while an automatic window runs, or the reverse | One binding, one window; the second joins and every callback is told (E7). The automatic search never writes `Found Fans`, the pick or the click's texts. If the click's callback runs after the follow, its Last Action text overwrites L22; the log keeps both | **A** | E7 |
| CA6 | Use Selected Fan | Stays the only way to take another fan (L3) and a click-driven move (L2). After a follow a pick of the same fan at the same address is L4. A read of the click blocks a follow; the click replaces a follow's read | **O** unchanged | V1D 3.5 |
| CA7 | Director restart or reboot while the fan is away | Ladder, pending flag and guard are memory only. Late init starts the model; offline about 45 s later; ladder from step 1. `mf_online` makes Fan Offline fire only on a transition (ECC D9) | **A** | `model.lua` `start` |
| CA8 | Driver update in place | As CA7. The new `Follow Address Changes` row needs no capability or reboot (ECC F2) and defaults to On, so the update changes behaviour | **A** | ECC F2 |
| CA9 | Project restore with an old `Fan Address` and the same `Fan ID` | Properties from the backup, the store as it is [silent]; the pin comes from the store, else the `Fan ID` row (ECC D10). The old address fails; the MAC from the pin is searched and confirmed. With neither store nor row nothing is pinned and nothing follows | **A** with a pin, **F** learning from an announcement | ECM N10; V1D 8 |
| CA10 | Project copied to another house (same model, other fan) | The pinned MAC is not on that network; another fan is: foreign or silent. Nothing found, nothing taken; Find Fans and Use Selected Fan re-point | **F** | V5, ECC D18 |
| CA11 | Two devices, two fans | Own pin, ladder and jitter each (swap: FA8). Two Lua states opening a MULTICAST binding on port 5353 in the same instant is untried | **A** | [assumed: jitter suffices; a refused open ends as FA17] |
| CA12 | Two devices pinned to the same fan | Both follow, independently; the duplicate is not detected in v1 | **A** harmless | V1D 15, ECC D17 |
| CA13 | Online variable, Fan Offline / Fan Online, light `ONLINE_CHANGED` | **A move fires no event of its own**: it shows as the outage it is. Fan Offline at the third failure (at once for foreign), Fan Online after the follow's contact; differences reported as "online"; nothing is re-sent | **A** | [verified: `model.lua` `set_phase`, `adopt`, `enter_online`] |
| CA14 | Navigators, programming, keypad links, LEDs | Device id, proxies and links unchanged; LEDs keep the last state through the outage and are corrected after the contact | **A** | V1D 6.2 |
| CA15 | Last Action and the log | L22 on success, L23 on the guard; nothing for a window that finds nothing (it would overwrite the owner's last click every 15 min); one `log.always` line per success, debug lines per step | **A** | V1D 7.2 |
| CA16 | Load and timing | Ladder 3.3: one window at a time, at most 3 reads, 3 follows an hour | **A** within the caps, **F** a window while online, rebooting, unset, switched Off or before late init | 3.3 |
| CA17 | Migration Report's "same address" match | After a follow this `Fan Address` may differ from a stale stock device's; the report falls back to `Stock Device` | **A** nothing | `migration-design.md` section 4 |
| CA18 | OS 4.x; a controller with two network interfaces | K10 ran on 3.4.3 only. Which interface carries the multicast is [assumed: the default route's]. A refused open or send ends as nothing found | **A** | E10, E16 |
| CA19 | The owner switches following Off | Today's behaviour exactly | **O** | 3.5, question 1 |

## 3. Recommendation

### 3.1 The rule

The device is pinned to a fan, not to an address. When the pinned fan is not at
the address, the driver asks the network once in a while for the pinned MAC
and, if an answer names it, reads that address once, read-only, before anything
changes. It never adopts another fan, never scans, never matches by name,
model or address, never acts on an answer alone. Rejected: HA's way (overwrite
on a MAC match without a read, E12); a standing listener (not tried for hours,
E11); SDDP or ARP (E14); a unicast probe of addresses nobody announced.

### 3.2 Trigger

- **Armed** when `listener.phase` reports offline, foreign, gen4 or notfan
  (V1D 6.1's offline-like phases) and all hold: `Follow Address Changes` On;
  `Fan Address` not empty; a pin with a MAC (else the 12 digits of the client
  id); the typed address not pending (CA3); no Use Selected Fan read under way;
  the model not stopped. Late init needs no special trigger: the third failure
  arms it about 45 s after a start, a foreign fan at once.
- **Disarmed** (timers cancelled, back to step 1) when the phase becomes
  online, waiting, unset or rebooting, on a `Fan Address` edit, on Off, on stop.
- **Not on the first failed poll.** It would save about 35 s and the Fan
  Offline / Fan Online pair, but it couples automation to the hot path (a
  slow answer would start a window; the model would have to switch address in
  `online`) for a gain the owner can see only in programming. A Lua constant
  and one call later if wanted (question 2).

### 3.3 Schedule

Windows are `Finder:find` as the click runs it (open, query twice 1 s apart,
3 s of answers, close); nothing stays open between windows.

| Step | When | Notes |
| --- | --- | --- |
| 1 | arming + 2 s + 0..3 s jitter (a foreign fan is seen at its first answer, so it arms earliest) | jitter from the device id: two devices rarely open together |
| 2 to 6 | after the previous window closed: 30 s, 1 min, 2 min, 5 min, 10 min, each +/-20 % | the shape of RFC 5.2 (growing intervals, then a cap) |
| 7 on | every 15 min +/-20 % | the cap is ours: the lookup is for one known fan and an owner waits; the RFC's 60 min is for browsing |
| retry | a candidate heard but not verified: the read again at +10 s, +30 s, +90 s | no new window; then the ladder goes on |

Windows are never closer than 30 s; a change between offline-like phases pulls
the next one forward, but not to less than 30 s after the last. First hour: 8
windows; after that 4 an hour (about 100 a day). Each is two 38-byte questions
and, if the fan is up, two answers of 250 to 300 bytes, against the 60 HTTP
attempts an hour the offline polls already make [verified: E15]. Known-answer
suppression, which RFC 5.2 asks of a *continuous* querier, is not implemented:
each window is a one-shot lookup of one fan. A multicast frame costs a Wi-Fi
access point basic-rate airtime [assumed: general Wi-Fi behaviour]; at this
rate that is below noise. No quiet hours: a query is silent. The Off switch
stops it.

### 3.4 Match and verify

1. **Candidates:** heard entries whose `mac` equals the pin's, with SRV port 80
   and an address that is private (RFC 1918) or link-local, not the current
   `Fan Address`. At most 3 distinct addresses, in the order heard.
2. **Read:** for each, `model:follow(address, mac12, cb)`: one `queryStaticShadowData`
   through the transport. **Accept** only HTTP 200 JSON whose `clientId`
   equals the pin's (case-insensitive) **and** whose `mac` equals the pin's
   **and** the entry's TXT MAC. Anything else (no answer, 404, another fan, a
   mismatch) is silent and the next candidate is tried.
3. **Re-check at the moment of accepting:** phase still offline-like, no owner
   edit or click since the window opened, switch On, the guard not tripped.
4. **Then** the contact reads the state, which checks `clientId` again
   [verified: `on_state`]; a fan that fails it falls to foreign and the
   ladder restarts.

### 3.5 What is updated

| What | By | How |
| --- | --- | --- |
| Transport address, **new epoch**, `pin.address`, `mf_identity`, firmware record, phase `waiting`, contact | `model.lua` `follow` (the `adopt` path of "moved") | In one step, persisted before the property write |
| The `Fan Address` row | `driver.lua` `prop("Fan Address", address)` | After the model switched; the handler is not called (E8) |
| `Last Action` L22, the log, `Status` | `driver.lua` | 3.6 |
| Online, Fan Online, `ONLINE_CHANGED`, reports "online", the fast poll window | the existing contact path | Nothing new; nothing re-sent |
| Ladder, guard timestamp | the follower | Memory only; nothing new is persisted |
| `Found Fans`, the pick, `Fan ID` rows | untouched (`Fan ID` only if the fan's data changed) | |

New property **`Follow Address Changes`**, LIST `On` / `Off`, default On,
editable, after `Found Fans`: a property addition, no capability or reboot.

### 3.6 Texts

No new Status text: S7 `Not answering at 10.0.2.151 since 14:02; showing last
state`, then S4 `Waiting for the fan at 10.0.2.152`, then S5 (absence of an
answer must not read as "moved").

| Id | When | Text |
| --- | --- | --- |
| L22 | followed | `Followed fan MF_00005E005301 to 10.0.2.152 (was 10.0.2.151)` (59 characters; 69 with 15-character addresses) |
| L23 | the 4th follow in an hour is refused, once | `Fan MF_00005E005301 moved 3 times in an hour; not following` |
| log, always | followed | the L22 text with ids cut to `...5301`, as `result()` does |
| log, warn | heard at the current address, HTTP silent; query could not be sent | each once per streak: `Fan ...5301 is on the network at 10.0.2.151, but its web server does not answer`; `Following could not send its query on this controller` |
| log, debug | each step | `Follow: window 3 (next in 2 min): heard 0 fans`; `Follow: ...5301 heard at 10.0.2.152; reading it`; `Follow: 10.0.2.152 answers as another fan (...5302); not followed`; `Follow: waiting, the typed address has not answered yet` |

### 3.7 What never happens

- A subnet scan, a read of an address nobody announced, a cloud lookup.
- Adopting or learning a fan; matching by name, model, instance or address;
  acting on an answer without the read; reading a public address; more than 3
  addresses a window or 3 follows an hour; a window with the switch Off, with
  an empty `Fan Address`, before late init, while online or rebooting.
- Overriding a typed address that has not answered; touching `Found Fans`;
  writing Last Action for a window that found nothing.
- Any command, or any re-sent state, because of a move; creating, deleting or
  re-binding a device; a new event, variable or command (they are forever).
- Listening outside a window; persisting the ladder.
- **SECURITY.md** says a release build "is meant to send requests to the fan
  the owner configured and nowhere else". The follow sends, to an address no
  human chose, one fixed read-only POST (`queryStaticShadowData` to `/mf`),
  only to a private address that announced the pinned MAC. The sentence needs
  the owner's yes and new wording (question 3).

### 3.8 Documents the coordinator changes

`v1-design.md`: V5, V5a, sections 2.5 (the row), 3.5's last paragraph, 7.2
(L22, L23), 9.1, 9.5, 9.10, 14 (items 2 and 8), 15 ("Following a new address
by itself, ever"). ECM N1, N3, Q3 and ECC D19 point here. `composer-checklist.md`
steps 42 to 44. `SECURITY.md` ("What the driver talks to"). `CLAUDE.md`
(Scope: "never adds a fan by itself" stays true; the Find Fans sentence needs
the new one). `CHANGELOG.md` (Unreleased), `docs/status.md`, `docs/README.md`
(this note: an edge-case note, so the docs index and not the front page).
**The manual** (`documentation.html`): line 81, the reservation, becomes a
recommendation, "not required: without one the driver finds the fan again by
itself when its address changes, usually within a minute or two; programming
sees one Fan Offline and Fan Online pair, and it needs the fan and the
controller on one network segment (multicast DNS does not cross routers)";
lines 105, 115, 296 (the first row of chapter 8: the driver follows, the click
is for the fallback) and 446 ("never follows... never scans") say the opposite
today; add the typed-address rule, the switch, and "tried on Gen 3 only".

### 3.9 Modules

- **`discovery.lua`**: a pure `candidates(heard, mac12, current)` (3.4 step 1);
  `find`'s callback gets a third value, `heard`: every distinct
  (instance, address) pair of the window, up to 8, beside the unchanged
  first-answer-wins list (its spec stays).
- **`model.lua`**: `m:follow(address, mac12, cb)`, `use_fan` restricted to the
  same fan: `cb("followed")` after the `moved` adoption, `"not_same"`,
  `"no_answer"` or `"busy"` (a click's read is under way, or the phase is not
  offline-like) otherwise, never `now_using`. Nothing else changes.
- **`fan/follow.lua`** (new, pure like `discovery`): the ladder, jitter, retry,
  guard and pending flag over injected `find`, `follow`, `timer`, `now`,
  `random`, `phase`, `identity`, `log`.
- **`driver.lua`**: the property and its replay, the pending rule in the
  `Fan_Address` handler, `prop("Fan Address")`, `result`, `OnDriverDestroyed`
  (`follow:stop()`). **`texts.lua`**: L22, L23. **`devcmds.lua`**: Dev State
  gains `follow=` (off, idle, armed:N, pending).
- Specs: the ladder on the fake timer; `follow` (same fan, other fan, silent,
  TXT/HTTP MAC mismatch, address equal, guard, owner edit mid-read, switch);
  the Gen 1/2 announcement layout (E4) as a fixture; two addresses for one
  instance; a lying public address.

## 4. Questions for the owner

1. **An Off switch?** `Follow Address Changes` (On/Off, default On), or none:
   then clearing `Fan Address` is the only way to stop it, and that stops
   control too. Recommended: the switch.
2. **When to start:** at the offline phase (about 45 s, programming sees a
   Fan Offline / Fan Online pair), or from the first failed poll (about 15 s,
   usually no events, more change in the model)? Recommended: the offline
   phase, revisited after a month.
3. **SECURITY.md:** accept "the fan the owner configured, wherever its own
   multicast DNS answer puts it, after one read-only request, private
   addresses only" in place of "nowhere else"? Recommended: yes.
4. **Empty `Fan Address` with a pinned fan** (a restore that lost the row):
   stay off (recommended; empty is the stop switch), or search and fill it?
5. **A "Fan Address Changed" event** for programming? Events are forever.
   Recommended: no; Last Action and the Fan Offline / Online pair cover it.

## 5. Checks

| # | Check | How | Settles |
| --- | --- | --- | --- |
| K20 | A moved fan, simulated on the house (about 70 s; the device is offline to Control4 for that minute, a press is tried once and dropped) | dev loop: a new `Dev` command points the model at a dead address (the pending rule lives in the property handler, so the command bypasses it); read Status, Last Action, `Fan Address`, the events | trigger, step 1, match, read, rows, the event pair |
| K21 | 12 windows 5 s apart (about 70 s) | dev loop: each hears the fan; the 13th still works; Director not slowed | binding churn (assumed benign) |
| K22 | Stand-ins on the VM (HTTP on port 80 plus mDNS; port 80 and an alias address may need root [assumed]) for a throwaway second device in the test room: moved, swapped, mDNS without HTTP, a public address, another MAC | VM tool plus the Windows session; optional, never blocking | FA8, FA10, FA11, FA15, CA11 |
