# Keypad LED rows only with a keypad: lifecycle edge cases

> **Research (2026-11-10) for [issue #178](https://github.com/corytron/c4-modernforms-driver/issues/178)**,
> read-only: nothing here was tried on the house and nothing is built. The
> owner asked that the keypad LED work (the per-speed colours, the Breeze
> gusts, the speed chase) show up in Composer only when a configurable
> keypad is linked to the driver, with clear instructions for both cases,
> that it be easy to disable, and "same for breeze modes". This note lists
> the lifecycle corner cases on the fan's side and on Control4's side and
> recommends one decision for each. The SDK side (which call hides a row,
> how to tell what kind of device is bound) is the sibling note
> `docs/keypad-leds-visibility-sdk-research.md`, written at the same time:
> where it settles a fact marked ASSUMED here, it wins.

**Decisions:** **AUTOMATIC** (the driver just does it), **OFFERED** (a
property, action or document line the dealer chooses), **FORBIDDEN** (never
without a click, or not at all where the row says so). **Markers:**
VERIFIED names a primary source (a repository file and line, an SDK file, a
house measurement); ASSUMED says the claim has none. Snap One's documents
are paraphrased, never quoted. Placeholders only: fan 10.0.2.151,
controller 10.0.2.10, keypad device id 456.

## The short answer

1. **Hide, never remove and never reset.** 20 rows (the six `Speed N Link Also Lit At`, the eight colour rows, the six animation rows) are hidden while no button is bound to a fan speed link (301 to 306). Their values stay, are still applied at every start, and are saved with the project. `Keypad Links` is never hidden: it says why the rows are not there.
2. **Show at once, hide late, and fail open.** A bind that qualifies shows the rows at once; a hide waits until the driver's own binding bookkeeping has settled (the 5 s second look at start, the 3 s re-read after an unbind) plus a short grace. A bound device whose kind is unknown counts as a colour keypad. A row whose value is acting on a bound button is never hidden.
3. **Only speed links count.** Off, Toggle, Cycle, Fan Breeze (311) and the light's links never take the driver's colours or animations, so a keypad bound only to them shows none of the 20 rows.
4. **Visibility is display only.** Showing or hiding never writes a value, never sends an LED message and never starts or stops an animation: without a bound speed button both animations are already idle, and they resume with the kept settings when one is bound again.
5. **Easy to disable: the two existing rows suffice.** `Breeze LED Animation` = `Off` and `Speed LED Animation` = `Off` each stop at once with one Set and leave the stock Follow Connection behaviour. No master row and no programming command. `Keypad's own` is not a clean off: the keypad keeps the last per-speed colours, and no API can give it back its own (written down as a departure).
6. **Instructions:** the `Keypad Links` summary says `…, LED settings hidden` or `…, LED settings shown`, a binding that changes the visibility writes one Last Action line, and the Documentation tab gets a short "Keypad LED settings" box with both cases.
7. **Breeze:** the Breeze-only rows (`Breeze LED Animation`, `Step`, `Night Brightness`) also hide on a fan that reports no Breeze (recommended default of Q2); `Breeze LED Bottom` stays with the chase, which uses it too. Breeze commands, the Add Breeze Fan action and link 311 cannot be hidden and stay.
8. **On the house nothing changes:** its keypad is on Fan Speed 2 to 5, so every row stays shown after the update.

| Key | Source |
| --- | --- |
| XML, LUA, LNK, TXT, DOC | `src/modernforms_fan/driver.xml`, `driver.lua`, `fan/links.lua`, `fan/texts.lua`, `www/documentation.html`, as of the checkout of 2026-11-10 |
| BLD, SLD | [`breeze-leds-design.md`](breeze-leds-design.md) (BL-D1 to BL-D30), [`speed-leds-design.md`](speed-leds-design.md) (SL-D1 to SL-D19) |
| BLE, SLE | [`edge-cases-breeze-leds.md`](edge-cases-breeze-leds.md) (BL rows, facts LF1 to LF19), [`edge-cases-speed-leds.md`](edge-cases-speed-leds.md) (SL rows, facts SF1 to SF16) |
| ECC, SG | [`edge-cases-control4.md`](edge-cases-control4.md) (F and C rows), [`speed-leds-c4-guidelines.md`](speed-leds-c4-guidelines.md) (SG1 to SG14) |
| SDK | `~/c4-tools/reference/docs-driverworks-*/source/includes/`: API, FUND, XMLD (xml), KP (keypad), LV2 (light_v2), UIB (uibutton) |
| HUE | the owner's Hue project, `~/projects/c4-hue-driver`, read as the reference (its drivers hide rows at run time on the house) |

## 0. Facts the decisions rest on

| # | Fact | Status |
| --- | --- | --- |
| KF1 | The LED rows on the fan item, in this order: `Keypad Links` (125, a DYNAMIC_LIST whose pick snaps back), `Speed 1` to `Speed 6 Link Also Lit At` (131 to 220), `Speed LED Colors` (224), `Speed 1` to `Speed 6 LED Color` (234 to 268), `Speed LED Off Color` (270), `Breeze LED Animation`, `Bottom`, `Step (ms)`, `Night Brightness (%)` (279 to 315), `Speed LED Animation` (319), `Speed LED Rest (s)` (332). The order is fixed ("never reordered", line 27). The fan item carries every property. | VERIFIED: XML lines as given; DOC 73 |
| KF2 | `C4:SetPropertyAttribs(name, 1)` hides a row on Composer's Properties tab, `0` shows it; it exists since OS 1.6.0 and is not to be called in `OnDriverInit`, nor before late init. | VERIFIED: API `24_properties/_4-SetPropertyAttribs.md`, `22_miscellaneous/_25.2-SafeUsageTable.md` (line 176); FUND `28_api_specific_info/_2-DRIVERINIT.md` |
| KF3 | A property in `driver.xml` has no hidden element (only a connection has `<hidden>`), so every row is shown from the moment the device is added until the driver's Lua hides it. | VERIFIED: XMLD `7_xml_data_hierarchy/_0-header.md`, `50_connections_xml/_60-hidden.md` |
| KF4 | On the house's Composer Pro, a show and a hide sent in the same burst as row text updates were dropped; the Hue bridge therefore sends visibility 400 ms after the texts and again at 1.5 s. The Hue drivers hide and show rows at run time (wrapped Last Action rows, motion sensor rows by kind, a scene's Recall As). | VERIFIED (hardware, 2026-10-24): HUE `src/hue_bridge/bridge/rows.lua` 35 to 42; `src/hue_motion/driver.lua` 466 to 486 (it also shows the rows while the kind is not known yet: fail open) |
| KF5 | Whether an open Properties page redraws on a show or hide without the device being selected again is not documented. | ASSUMED: HUE `docs/edge-cases-control4.md` line 356 ("silent") |
| KF6 | Whether a hidden state survives a Director restart, a driver update, a project save and restore, or a rollback to a build that never calls the API, is not documented. | ASSUMED (no SDK page; KH2, KH3) |
| KF7 | Property values are saved in the project and its backups and survive updates; properties may come and go in an update but should not be retyped (removing one from the XML would drop its value, hiding it does not); dynamic list items are not persisted. | VERIFIED: ECC F25, F2; FUND `15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md` |
| KF8 | Programming sees a driver's commands, variables, conditionals and events, never its properties. | VERIFIED: FUND `15_composerpro_interface_into_the_sdk/_7-PROGRAMMING.md` |
| KF9 | At late init every property value is replayed through its handler, whatever Composer shows. | VERIFIED: LUA 1236; `src/common/dispatch.lua` 117 |
| KF10 | The driver keeps, per link, the device ids bound to it: read with `GetBoundConsumerDevices` at late init, read again 5 s later for a link that answered nil (one nil is "unknown"), kept current by `OnBindingChanged`, and read again 3 s after an unbind that may leave another button of the same keypad on the link. A link not read yet counts as not bound. | VERIFIED: LNK 106, 107, 667, 710, 799, 843; ECC C15 |
| KF11 | Colours go only to the speed links 301 to 306, only under `Per speed`; Off, Toggle, Cycle, Fan Breeze and the light's links never get `BUTTON_COLORS` and show the keypad's own colours. | VERIFIED: LNK `colour_for` 312; DOC 383 |
| KF12 | Both animations use only the speed links with a bound button (the pixels); with none they are idle and send nothing; the chase needs at least two. | VERIFIED: LNK `pixels_list` 667; BLD BL-D2; SLD SL-D9; SLE SL25 |
| KF13 | `Speed N Link Also Lit At` changes only whether link 300 + N is lit (`MATCH_LED_STATE`), for any device bound to it, colour or not. | VERIFIED: LNK `lit` 289, `set_also` 434 |
| KF14 | Button links assume every keypad has the same button and LED abilities; some non-Control4 keypads have no LEDs; no API lets a driver ask the hardware what it supports. | VERIFIED: KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md` (introduction); SG6 |
| KF15 | The UI Button proxy (a button on the Navigators) takes `SELECT` and documents no button link; nothing in the uibutton protocol mentions `BUTTON_LINK`. That a Navigator, a touch screen or a remote can never be bound to the fan's links is inferred. | VERIFIED (full-text search of `~/c4-tools/reference/`, 2026-11-10: only the button link page names `BUTTON_LINK`, in KP `62/_1` and its copy in the general proxy protocol reference); the inference ASSUMED |
| KF16 | Going back to `Keypad's own` sends nothing: the keypad keeps the last colours it took until the dealer sets its own on the keypad. No API reads or writes a keypad's button settings; Disconnect leaves the button on Follow Connection. | VERIFIED: LNK `set_colors` 452; DOC 366, 392; ECC F16; BLE LF3, LF4 |
| KF17 | `Breeze LED Animation` = `Off` stops the gusts at once, without the ending wipe, and gives every speed button its real state; `Speed LED Animation` = `Off` ends the chase at once the same way. Both default to `Off`, so an update animates nobody. | VERIFIED: BLD BL-D11, BL-D18; SLD SL-D8, SL-D9; DOC 437, 458; XML 279 to 287, 319 to 330 |
| KF18 | L42 and L43 (the animations need `Per speed`) are written on a property change by the dealer, never on the late-init replay. | VERIFIED: LUA 820 to 834, 839 to 852 |
| KF19 | Actions cannot be hidden at run time (no API); connections are static in the XML and may never be removed in an update; commands, once released, are never removed. | VERIFIED: HUE `docs/simplify-research-composer.md` 106 (verified absence); ECC F2; BLE LF16 |
| KF20 | Control4's guidance for a light's Navigator extras: hide objects whose hardware or feature is absent rather than remove them, and avoid redraws while a user is working on the page. (Navigator extras, applied here by analogy to Composer rows.) | VERIFIED-doc: FUND `27_proxy_specific_info/_51-LIGHTV2EXTRAS.md` |
| KF21 | `hide_proxy_properties` is a static capability that hides all of a light's proxy properties; a capability change needs a controller reboot. | VERIFIED: LV2 `5_light_v2_capabilities/_38-HIDEPROXYPROPERTIES.md`; ECC F26; XML 493 |
| KF22 | Whether the fan has Breeze is read from the model's info (`has_wind`, from a read of the fan); before the first answer it is the restored info, or unknown. | VERIFIED: `src/modernforms_fan/fan/breeze.lua` 242; LUA `show_restored` |
| KF23 | `Keypad Links` reads `N of 13 links bound`, then one item per binding; Composer shows about 75 characters of a value. | VERIFIED: TXT 1158 to 1179; ECC F29 |
| KF24 | The house: the bedroom keypad is on Fan Speed 2 to 5, Fan Off, Light Top and Light Bottom (`7 of 13 links bound`), `Per speed`. | VERIFIED: [`status.md`](status.md) |
| KF25 | The test runtime already records `SetPropertyAttribs` (name, 1 or 0), so the rules below can be specified in busted. | VERIFIED: `tests/helpers/fake_c4.lua` 415, 429 to 431 |

## 1. The model the cases are decided against

Every name below is a proposal for the contract, not existing code.

- **Group A, speed LED state** (6 rows): `Speed 1` to `Speed 6 Link Also Lit At`.
- **Group B, speed colours** (8 rows): `Speed LED Colors`, `Speed 1` to `Speed 6 LED Color`, `Speed LED Off Color`.
- **Group C, animations** (6 rows): `Breeze LED Animation`, `Breeze LED Bottom`, `Breeze LED Step (ms)`, `Breeze LED Night Brightness (%)`, `Speed LED Animation`, `Speed LED Rest (s)`. **C-Breeze** is the three rows only Breeze uses (Animation, Step, Night Brightness); `Breeze LED Bottom` also orders the chase (SLD SL-D4) and goes with the chase.
- **Never hidden:** every other row, `Keypad Links` above all.
- **A bound device's kind** (the sibling note says how it is found): *colour keypad* (known to take colours over a link), *no colour* (known to have no LED, or a single-colour one), *unknown* (anything else, a lookup that fails included). Unknown counts as colour keypad.
- **Settled:** every speed link has been read (KF10) and no re-read is pending.
- **V1.** Group A is shown while any device is bound to a speed link.
- **V2.** Groups B and C are shown while a colour keypad or an unknown device is bound to a speed link, or while group A is shown and `Speed LED Colors` is `Per speed` (a colour is being sent, so its row must stay reachable).
- **V3** (Q2 default). C-Breeze is hidden besides while the fan's info, from a read, says it has no Breeze; unknown counts as Breeze.
- **V4.** Showing is at once. Hiding happens only when settled, after a grace of 3 s in which nothing changed. Every change of visibility goes out 400 ms after the row texts of the same pass and again at 1.5 s (KF4).
- **V5.** Visibility is decided at late init, on a binding change and on a change of the fan's Breeze ability. A dealer's own property change may **show** rows (V2) but never hides any until the next binding change or start, so nothing vanishes under the cursor (KF20).
- **V6.** Visibility never writes a property, never sends on a link, never starts or stops an animation, never persists anything (the bindings are the truth). One debug line per change.

## 2. Cases

### 2.1 Bindings

| ID | Case | Recommended behaviour | Decision | Source |
| --- | --- | --- | --- | --- |
| KV1 | First install, no keypad | Composer shows all rows from the add (KF3); at late init every link answers nil, the second look 5 s later settles "none bound", and the 20 rows hide about 8 s after the start (5 s plus the grace). `Keypad Links` reads `0 of 13 links bound, LED settings hidden`. No Last Action line (not a binding change). | **AUTOMATIC** | KF3, KF10, KF23 |
| KV2 | A keypad button bound later to a speed link, the first one | The bind event names the device; group A shows at once, and B and C too for a colour or unknown keypad. Values are what they were (the defaults on a new device). An animation starts only if it was already on, under `Per speed`, with its pixels (KF12). Last Action: a "shown" line (KV46). | **AUTOMATIC** | V1, V2; LNK 710 |
| KV3 | More buttons bound: other speed links, another keypad, the same link twice | No visibility change; `Keypad Links` updates as today. | **AUTOMATIC** | KF10 |
| KV4 | A binding moved from one speed link to another (Disconnect, then a drag), the only one | The grace of V4 covers the seconds between unbind and bind: nothing flickers. | **AUTOMATIC** | V4 |
| KV5 | The last speed-link binding removed | Once settled and after the grace: groups A, B, C hide. Values stay exactly as set. The animations are already idle (no pixels) and send nothing; the unbound button keeps its last LED, maybe an animation colour, as any disconnected button does (the existing manual line). Last Action: a "hidden" line. Resetting `Per speed`, `Gusts` or the chase to their defaults on an unbind would lose the dealer's work and make the next bind a manual fix. | **AUTOMATIC** (hide); a reset **FORBIDDEN** | KF12, KF16; BLD BL-D16; DOC 439 |
| KV6 | One of several keypads unbound, another still on a speed link | No change, unless every remaining device is *no colour* and the colours are `Keypad's own`: then B and C hide after the grace (V2). | **AUTOMATIC** | V2 |
| KV7 | A keypad replaced: the old one deleted, the new one added and bound minutes later | KV5, then KV2. The new keypad picks up the kept settings at once: the per-speed colours and any animation that was on. Those settings belong to the fan's links, as a Control4 load's settings stay when a keypad is swapped. A replacement that keeps the keypad's device id keeps its bindings: nothing happens. | **AUTOMATIC** (Q7) | ECC C5 (assumed); BLE BL43 |
| KV8 | A keypad deleted from the project without a Disconnect | Its bindings go with it, and an unbind event per link is expected; otherwise the next start's read finds them gone. Same as KV5. | **AUTOMATIC** | ECC C5 (assumed) |
| KV9 | Only Fan Off (300), Toggle (307) or Cycle (308) bound (a 2-button keypad, a switch used as one) | All 20 rows hidden: none of them acts on these links (KF11, KF13). `Keypad Links` reads `2 of 13 links bound, LED settings hidden`. | **AUTOMATIC** | KF11, KF13 |
| KV10 | Only Fan Breeze (311) bound | As KV9. The Breeze animation plays on the speed buttons only; 311 stays steady in the keypad's own colours (BLE BL23). The manual says the gusts need speed buttons. | **AUTOMATIC** | BLD BL-D2; KF11 |
| KV11 | Only the light's links (200 to 202) bound | The fan's 20 rows hidden. The light's LED colours are the light item's own Control4 settings page, not these rows; hiding that page needs the static `hide_proxy_properties`, which hides everything on it and costs a reboot. | **AUTOMATIC** (fan rows); light page **FORBIDDEN** | KF21; DOC 383 |
| KV12 | A device known to have no colour LEDs bound to a speed link, colours `Keypad's own` | Group A shown (it acts on any LED); B and C hidden. Nothing new is sent. | **AUTOMATIC** | KF13; V1, V2 |
| KV13 | A device whose kind cannot be told (a third-party keypad driver, a virtual keypad, a failed lookup) | Counted as a colour keypad: A, B and C shown; one debug line names the device id. The SDK gives no way to ask the hardware (KF14), and a hidden row that acts on a button is a fix the dealer cannot make. | **AUTOMATIC** (show); hiding on a guess **FORBIDDEN** | KF14; SG6 |
| KV14 | A Navigator, touch screen, phone or remote | No button link is documented for them (KF15): they cannot be bound, nothing to decide; their buttons work through programming. Should some driver expose one, KV13 applies. | **AUTOMATIC** (nothing) | KF15 |
| KV15 | Several keypads of mixed kinds | The union: A for any device, B and C for any colour or unknown keypad. One message on a link reaches every device bound to it, so the shown values serve all of them. | **AUTOMATIC** | BLE LF14 (assumed) |
| KV16 | `Per speed` set for an earlier colour keypad, and now only a *no colour* device on the speed links | B and C stay shown (V2): `BUTTON_COLORS` still go to that device, so the dealer must be able to switch them off. After a switch to `Keypad's own` they stay shown until the next binding change or start (V5). | **AUTOMATIC** | V2, V5; KF11 |
| KV17 | A single speed button bound | All shown. The gusts play on one button; the chase needs two and stays idle (the manual says so). No separate rule for the chase rows: rows appearing one button at a time would confuse more than they help. | **AUTOMATIC** | KF12; SLD SL-D9 |
| KV18 | A button without an LED bound to a speed link (a Regular Button) | Not distinguishable (KF14): decided by its keypad's kind. Messages to a button without an LED are wasted harmlessly. | **AUTOMATIC** | KF14; SG6 |
| KV19 | A keypad offline, unpowered or off the mesh | Its bindings stay, so the rows stay. It gets its LEDs back only if it asks (BLE BL43). | **AUTOMATIC** | ASSUMED (bindings outlive an offline keypad) |
| KV20 | A keypad renamed or moved to another room | No binding change: visibility unchanged; `Keypad Links` names it anew the next time the list is written. | **AUTOMATIC** | LNK `publish` 632 |

### 2.2 Restarts, updates, restore, the fan

| ID | Case | Recommended behaviour | Decision | Source |
| --- | --- | --- | --- | --- |
| KV21 | Director restart or controller reboot | Bindings are restored before late init without events, and one nil read may be wrong (ECC C15). Whatever Composer shows at load (KF6), the driver shows at once each group the first read qualifies, hides only after the 5 s second look, and never hides on an unknown read. No Last Action line at late init (as for L42, KF18). Nothing persisted. | **AUTOMATIC** | KF6, KF10; ECC C15 |
| KV22 | Update in place from a build that always showed the rows (every build before this change, 1.6 included) | Late init as KV21. On the house (keypad on 302 to 305) nothing changes. On a device with no speed binding the rows disappear a few seconds after the update, values kept; the changelog line says where they went. Lua only, no `<capabilities>` change, no reboot. | **AUTOMATIC** | KF7, KF24; ECC F26 |
| KV23 | Rollback to a build without the feature | If the hidden state is kept by Director or Composer (KF6), the old build never shows the rows again and the dealer cannot reach them: a fix only an update can make. KH3 settles it before release. If it is kept, the new build's `OnDriverDestroyed` shows every row (best effort; whether a call there lands is undocumented, BLD BL-D17), and the release notes say so. | **FORBIDDEN** to release before KH3; the fallback **AUTOMATIC** | KF6; BLD BL-D17 |
| KV24 | Project restored from a backup | Values, persisted data and bindings come back with the backup (KF7); late init as KV21, so the rows follow the backup's bindings. A backup from before the feature behaves the same. | **AUTOMATIC** | KF7 |
| KV25 | Dev-loop reload (`--dev` builds only) | `OnDriverDestroyed` cancels the visibility timers (the reload kills none itself); late init decides again. | **AUTOMATIC** | BLE LF13 |
| KV26 | The fan replaced (Use Selected Fan) or a firmware change makes Breeze appear or go | C-Breeze follows the fan's info as soon as a read gives it (V3); a change shows or hides at once, with the 400 ms and 1.5 s re-sends. `Breeze LED Animation` keeps its value either way. | **AUTOMATIC** (Q2) | KF22 |
| KV27 | The fan offline, or not contacted yet | The restored info decides; with none, Breeze counts as present and C-Breeze is shown (fail open). | **AUTOMATIC** | KF22 |

### 2.3 Composer

| ID | Case | Recommended behaviour | Decision | Source |
| --- | --- | --- | --- | --- |
| KV28 | The Properties tab open while a binding changes in Connections | Sent 400 ms after the texts and again at 1.5 s. Whether the open page redraws is KH1; the manual says to select the fan item again if the rows have not appeared yet. | **AUTOMATIC** | KF4, KF5 |
| KV29 | Visibility and the `Keypad Links` or Last Action text changed in one pass | Visibility always goes after the texts (V4); a change sent with them was dropped on the house. | **AUTOMATIC** | KF4 |
| KV30 | The dealer typing in a row when an unbind elsewhere hides it | The unsaved edit is probably lost (ASSUMED). Only an unbind can cause it (V5), after the grace. Accepted. | **AUTOMATIC** | V5 |
| KV31 | A hidden row "in programming" | Properties never appear in programming (KF8); the variables, events, commands and the condition are untouched. | **AUTOMATIC** (nothing) | KF8 |
| KV32 | A hidden row's value in a saved project or a backup | Kept and saved like any value (KF7; that hiding leaves it untouched is ASSUMED, KH2 reads it back); a restore applies it at late init (KF9). | **AUTOMATIC**; clearing a hidden value **FORBIDDEN** | KF7, KF9 |
| KV33 | A dealer who wants to set colours before binding | Bind first. With `Speed LED Colors` at `Keypad's own` (the default) a fresh binding shows the keypad's own colours, so the manual's order (colours first, `Per speed` last, no default blue in between) still works. No "always show" switch in the first build. | **AUTOMATIC**; a switch **OFFERED** only on request (Q6) | DOC 391 |
| KV34 | Composer working offline (no Director, no Lua) | Composer presumably shows every XML row (KF3); values typed there apply at the next late init. | **AUTOMATIC** (nothing) | ASSUMED |
| KV35 | Hidden rows still drive the engines | Late init replays every value (KF9): the engines are configured but idle without pixels, so nothing reaches any keypad. | **AUTOMATIC** | KF9, KF12 |
| KV36 | A show or hide that changes a value, sends an LED message or starts an animation | Never (V6). | **FORBIDDEN** | V6 |

### 2.4 Turning it off

| ID | Case | Recommended behaviour | Decision | Source |
| --- | --- | --- | --- | --- |
| KV37 | The Breeze gusts turned off | `Breeze LED Animation` = `Off`, Set: they stop at once without the ending wipe and every speed button shows its real state. One step, as built. | **AUTOMATIC** | KF17 |
| KV38 | The speed chase turned off | `Speed LED Animation` = `Off`, Set: the chase ends at once and every held button is put back. One step, as built. | **AUTOMATIC** | KF17 |
| KV39 | One master off for both | Not added: the two rows sit together in group C, and the manual gets one "Turning the LED animations off" box naming both. A third row would be one more value that can disagree with the two. | master row **OFFERED** only on request (Q3) | KF17 |
| KV40 | The per-speed colours turned off (`Keypad's own`) | Nothing is sent; the keypad keeps the last per-speed colours until the dealer sets its own colours on the keypad (KF16). The driver can neither read nor restore them. This departs from "easy to disable" because Control4 offers no way, and the manual says what to do. It also stops both animations, but it is not the clean way off. | **AUTOMATIC**; restoring the keypad's colours **FORBIDDEN** (no API; BLD BL-D1) | KF16 |
| KV41 | Turned off from programming (bedtime, a scene) | Properties are not programmable (KF8). A command would be permanent (KF19). Not in #178. | **FORBIDDEN** here; a command **OFFERED** later on request (Q3) | KF8, KF19 |
| KV42 | What the keypad shows after an animation is off | The stock Follow Connection picture: the button of the fan's speed lit (its per-speed colour, or the keypad's own), the rest dark, Off lit only while stopped; in Breeze every speed button dark and Fan Breeze lit. | **AUTOMATIC** | DOC 379 to 383 |
| KV43 | "Off" by unbinding every speed button | The animations idle; the unbound buttons keep their last LED (KV5), which the keypad's own settings fix (the manual's Follow Connection note). | **AUTOMATIC** | BLD BL-D16; DOC 366, 439 |

### 2.5 Instructions

| ID | Case | Recommended behaviour | Decision | Source |
| --- | --- | --- | --- | --- |
| KV44 | What the owner reads with no speed link bound | (a) On the Properties tab: `Keypad Links` reads `0 of 13 links bound, LED settings hidden` (about 40 characters, inside the 75 Composer shows). (b) On the Documentation tab, chapter 5, a box "Keypad LED settings" in plain words: which rows, that they appear when a keypad button is bound to Fan Speed 1 to 6, that values set earlier are kept, and to bind first. (c) A troubleshooting row "The LED settings are missing". | **AUTOMATIC** | KF23; DOC 501, 715 |
| KV45 | What the owner reads with a speed link bound | `Keypad Links` reads `4 of 13 links bound, LED settings shown`; the rows are there; chapter 5 as today, plus the box of KV44 and the "Turning the LED animations off" box of KV39. | **AUTOMATIC** | DOC 377 to 392 |
| KV46 | A binding that changes the visibility | One Last Action line, never at late init and never for a property change: `Keypad LED settings shown: a keypad is on a fan speed link` or `Keypad LED settings hidden: no keypad on a fan speed link; values kept`. Two new result keys, numbered by the contract. | **AUTOMATIC** | KF18; TXT 1097 to 1105 |
| KV47 | The Documentation tab's Properties table | The 20 rows are marked "shown only while a keypad button is bound to Fan Speed 1 to 6" (and C-Breeze "and the fan has Breeze"); the animations' "Turning it on" steps start with "bind the speed buttons". | **AUTOMATIC** (docs) | DOC 636 to 646, 413, 466 |
| KV48 | A new always-visible status row (for example `Keypad LEDs`) | Not needed: `Keypad Links` carries the state and is already the place the manual sends the dealer to. | **OFFERED** only on request (Q5) | KF23 |

## 3. Control4 lighting guidelines

| Item | How this meets it |
| --- | --- |
| A bound button follows the device's state (SG1, SG2) | Untouched: visibility sends nothing (V6); after an animation is off the keypad shows the stock picture (KV42). |
| Hide what the hardware or feature lacks, rather than remove it; no redraw while a user works (KF20) | Rows are hidden, never removed from the XML (values kept, KF7); hides wait for settled bookkeeping and a grace, and never follow the dealer's own edit (V4, V5). |
| Hardware abilities cannot be asked (SG6, KF14) | Fail open: unknown counts as a colour keypad (KV13). |
| Never a keypad setting (BLD BL-D1, SG8) | Kept: nothing here touches a keypad. |
| **Departure** | Turning the per-speed colours off cannot give the keypad its own colours back (KV40): no API reads them. Written in the manual. |

## 4. Questions only the owner can answer

1. **Which bound devices count as "a configurable keypad"?** *Recommended:* any device on a speed link not known to lack colour LEDs (Control4's configurable keypads and keypad dimmers, and anything the driver cannot identify); the six `Also Lit At` rows for any device on a speed link, since they act on any LED.
2. **"Same for breeze modes": what should it cover?** *Recommended:* the Breeze LED rows follow the keypad rule, and `Breeze LED Animation`, `Step` and `Night Brightness` also hide on a fan that reports no Breeze. The Breeze commands, Add Breeze Fan and link 311 cannot be hidden (KF19) and keep refusing on a fan without Breeze as they do now.
3. **"Easy to disable": the two animation rows, or also a master row or a programming command?** *Recommended:* the two rows, each one Set, plus a manual box; no master row and no command (a command can never be withdrawn).
4. **`Also Lit At` per link or as a group?** *Recommended:* as a group (shown while any speed link is bound), so rows do not come and go one button at a time.
5. **Nest further:** hide the animation rows under `Keypad's own`, or `Step` and `Night Brightness` while the gusts are `Off`? *Recommended:* no, not in this change: L42 and L43 already explain, and fewer moving rows are easier to describe.
6. **A way to see the rows before binding** (an "always show" choice)? *Recommended:* no; bind first, nothing is lost by it.
7. **After the last keypad is unbound and a new one bound, should the kept animations resume by themselves?** *Recommended:* yes, with the Last Action "shown" line.

## 5. Hardware checks (each under a minute, on a `--dev` build through the dev loop)

- **KH1** With the fan item's Properties tab open, hide and then show one row from the dev loop: does the open page redraw, or only after the item is selected again?
- **KH2** With one row hidden, restart Director: is the row hidden or shown when Composer reconnects, before late init hides it again, and is its value unchanged?
- **KH3** With one row hidden, install the same package again through Add or Update Driver, with the Lua not touching the row: does the row come back? (This is the rollback case, KV23.)
- **KH4** On a device of the driver with no speed binding, bind one keypad button to Fan Speed 1, then Disconnect it: the rows appear at once and go about 3 s after the Disconnect; `Keypad Links` and Last Action read as in KV44 to KV46; every value is unchanged.

## 6. What could not be verified

- Whether the hidden state is kept across a Director restart, an update, a project save and restore or a rollback (KH2, KH3); the SDK page describes only the call.
- Whether an open Properties page redraws on a show or hide (KH1).
- That hiding leaves the value untouched, in `Properties` and in the saved project. The SDK calls the API a display setting, and the Hue drivers rely on it, but nothing states it outright.
- How to tell a colour keypad from another bound device: the sibling note's subject; this note only assumes the three outcomes of section 1.
- That nothing but a keypad-like driver can be bound to a button link (KF15), and that deleting a keypad fires an unbind for each link (ECC C5).
- What Composer shows while working offline (KV34).
- OS 4.x and the date-versioned Composer Pro: the call is marked unchanged since OS 1.6.0; no 4.x controller to check.
- Whether setting the keypad's own colours again in Composer after `Keypad's own` brings them back on the buttons (KV40); the manual's advice rests on the house's single observation (BLE LF3).
