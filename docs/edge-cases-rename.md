# Renaming the driver's own items: lifecycle cases and rules

> Research (2026-11-04) for [issue #37](https://github.com/corytron/c4-modernforms-driver/issues/37),
> read-only: nothing here was tried on the house. The owner asked (2026-11-04)
> that the fan's marketing name, worked out from its model information, be
> printed in a property and "used for renaming the fan device in Composer
> once the fan is selected". Another note decides which models have a name;
> this one takes "the name for this `fanType`, or none" as given and decides
> *when* the driver may rename its two Composer items, *which* items, and what
> it must never do. It overrides, and only as far as the cases below say,
> the "never" of [`edge-cases-control4.md`](edge-cases-control4.md) D15 (a
> proxy renamed in Composer: the name is the owner's; forbidden: `RenameDevice`
> by the driver), U6 and U7, and the manual's "you may rename them; the driver
> never does". Every "Decision" is a proposal for the contract; section 6 lists
> what needs the owner.

## In short

- **Two moments, both clicks.** (1) Use Selected Fan, whenever it ends with a
  fan pinned (L2, L3 or L4): a *guarded* rename. (2) A new action, Name Items
  After Fan: the *forced* way back. Nothing else renames: not the first contact
  from a typed address (Q2), not start-up, an update, a restore, a poll, a
  firmware or light-kit change, or any event.
- **Both items or neither.** The fan item becomes `<Name>` and the light item
  `<Name> Light`, for a fan with a light kit and for one without.
- **Ours until touched.** The guarded rename changes an item only while its
  Composer name is the shipped default or the exact string the driver wrote
  last. A name an owner, a dealer or the cutover typed is never overwritten,
  and the click says so. This keeps the cutover's "(new)" names and the
  family's "Fan" and "Fan Light", and lets a replaced fan's names follow its
  model while nobody has touched them. It is this note's reading of the project's
  rule that automation must not make a manual fix harder, not something the
  request says: Q1.
- **Never guess.** No name for the model, no item ids, or a rename Director
  does not confirm: nothing is renamed or recorded, and the text says why.
- The property that prints the name follows `fanType` by itself. That is a
  row, not a rename, and is not covered here.

## Legend, sources

**A** automatic: the driver does it with no click (reads and its own record
only). **A-click** automatic inside a Use Selected Fan click, because the
owner asked for it on 2026-11-04, and bound by rules N1 to N6. **O** offered:
a click on an action. **F** forbidden without a click (some rows: never).
Evidence: **[verified: SRC]** names a primary source, **[assumed: why]** is our
reading with the check that settles it (section 5.11), **[silent]** means the
documents say nothing.

Keys. `API`, `FUND`, `XML` are the DriverWorks references under
`~/c4-tools/reference/docs-driverworks-api/`, `-fundamentals/` and `-xml/`
(each `source/includes/`); `API 22/_32` is `22_miscellaneous/_32-RenameDevice.md`.
Paraphrased, never quoted. `HUE` is the owner's Hue project
(`~/projects/c4-hue-driver`, read-only), measurements on this house (OS
3.4.2 and 3.4.3), file and section. `V1`, `ECC`, `ECM`, `MIG` are
[`v1-design.md`](v1-design.md), [`edge-cases-control4.md`](edge-cases-control4.md),
[`edge-cases-modernforms.md`](edge-cases-modernforms.md) and
[`migration-design.md`](migration-design.md); `MFR` is
[`modernforms-api-research.md`](modernforms-api-research.md). "The house" is the owner's
controller. Placeholders as everywhere: fan `10.0.2.151`, a second fan
`10.0.2.152`, `MF_00005E005301`, "Example Room"; `Sample` stands for a
marketing name and `1811-5-54` is the house fan's `fanType` as M0 read it.

## 1. Facts the decisions rest on

| # | Fact | Source |
| --- | --- | --- |
| RF1 | `C4:RenameDevice(id, name)` takes a proxy id or a device id and a string, returns nothing (no error value), exists since 1.6.0, may be called by a driver for a device that is not its own, and refreshes the project on every call. Composer shows the proxy device, so the protocol driver's own id is, in most cases, not the one to pass. It must not run in `OnDriverInit` and works from `OnDriverLateInit`. The reference states no limit on a name's length or characters, and no 4.x page mentions renaming. | [verified: API 22/_32; API 3_whats_new/_20-WhatwasNewinOS3.md; a search of the whole reference for "rename", 2026-11-04] |
| RF2 | RenameDevice, GetDeviceDisplayName, GetBoundConsumerDevices and GetProxyDevices are all listed as unsafe before late init (`GetDevices` is not listed; it is only called after late init here too). | [verified: API 22/_25.2; FUND 28/_2] |
| RF3 | `C4:GetDeviceDisplayName(id)` returns the name Composer shows, for a protocol id and a proxy id alike. | [verified: API 32/_6; HUE `docs/design.md`, "Project APIs: verified on hardware"] |
| RF4 | A proxy's default name is the `name` attribute of its `<proxy>`: here "Modern Forms Fan" (5001, the fan, declared first, the parent item) and "Modern Forms Fan Light" (5002, its child). The shipped defaults are therefore two known constants. | [verified: FUND 8/_2; `src/modernforms_fan/driver.xml`; V1 2.2, 11.1 K4] |
| RF5 | This device's two proxy ids are the keys of `C4:GetBoundConsumerDevices(C4:GetDeviceID(), 5001)` and of `(..., 5002)`; on the house the probe (the same two proxies) read the fan proxy's variables through the id it got from 5001. `C4:GetDevices({DeviceIds = "<device id>"})` lists the same ids under `proxies = { [proxyId] = { deviceName, driverFileName } }`, a second route that also gives each proxy's current name. `C4:GetProxyDevices()` documents one return value and is not used. A rename of one proxy of a two-proxy device has not been tried. | [verified: API 32/_3, 22/_9, 25/_1; house: `probes/mf_probe/driver.lua` `proxy_id`, V1 11.1 K8; HUE `design.md`, "Project APIs" for the shape] [assumed: that RenameDevice acts the same on the fan proxy; K-R1, K-R2] |
| RF6 | The Hue drivers renamed a proxy with `C4:RenameDevice(proxy_id, name)` on the house, from an owner's click (Adopt Hue Name on a re-linked scene device, 2026-10-21). Not recorded there: how long Director needed, whether an open Composer repainted its tree unaided, whether Navigators followed without File » Refresh Navigators. | [verified-house: HUE `design.md`, "Scenes build: verified on hardware"; `docs/composer-checklist.md` item 32] [assumed: the rest; K-R2] |
| RF7 | A rename made in Composer reaches a driver registered with `C4:RegisterSystemEvent(C4SystemEvents["OnItemNameChanged"], 0)` as `OnSystemEvent` XML whose `iditem` is the proxy id (`itemtype` 7; 6 is a protocol device). The reference names the event and says a name change raises the Navigators' "Refresh Navigator" notification, but its id table does not list the event. | [verified: API 7/_1, 7/_5.5; verified-house: HUE `design.md`, "Composer Pro 3.4.2 UI: verified through the Windows session"] |
| RF8 | Programming descriptions show a device as "Room->Name" (the NAME macro). That programming, scenes and agents hold the device id and so survive a rename is the usual reading and untested here. Code that looks a device up by its name (`GetDevicesByName`; the Hue drivers' Link Devices) would not survive one. | [verified: FUND 10/_2, API 22/_10] [assumed: ids, ECC D14] |
| RF9 | Navigators, the Control4 app and voice assistants show the project's names. The house refreshes Navigators with File » Refresh Navigators after adds and renames. That a voice assistant needs a new discovery after a rename, and that a routine naming the old name stops matching, is the same assumption as the migration's "the owner's phone" steps. | [assumed: ECC U7, 2.2; MIG 1.5; nothing in the docs] |
| RF10 | A device's persisted values survive an update and a reboot, and are lost by deleting and re-adding the device. A project restore: the properties are in the backup, the store is [silent]. | [verified: ECC F25; V1 8] |
| RF11 | Adding an action in an update is allowed and needs no controller reboot (only a capability change does); `sort_order` is a display order only. | [verified: FUND 14/_2; XML 30_actions/_45; HUE: actions were added in many updates on the house] |
| RF12 | The fan reports `fanType` ("the model number and blade span") and `lightType` (empty without a kit); the driver persists both in `mf_info` and shows them in `Fan Model`. The app's name for the fan, `deviceName`, is private and dropped on receipt. A Gen 4 fan is refused before any model is read. | [verified: MFR 2.4; V1 V20, 3.6, 7.3, 8; `fan/model.lua` `record_info`] |
| RF13 | `model:use_fan(address, mac, cb)` ends in `already`, `moved` or `now_using` (a fan accepted) or in a failure key. For `moved` and `now_using` the model has recorded the new info before the callback runs. The first contact tells `learned` through the listener. | [verified: `fan/model.lua` `after_use`, `adopt`, `finish_contact`, read 2026-11-04] |
| RF14 | Late init replays every property handler, then starts the model; the `Fan Address` handler returns while `started` is false. Nothing that renames may hang on a property handler. | [verified: `driver.lua`; `common/dispatch.lua` `replay_properties`] |
| RF15 | The fake runtime already records `RenameDevice` (`c4.renamed`), answers `GetDeviceDisplayName` and models a device with two proxies. | [verified: `tests/helpers/fake_c4.lua`] |

## 2. Rules behind every row

The Hue drivers name a device once, at creation (`AddDevice` takes a name), and
rename only on an owner's click (`HUE docs/edge-cases-ux.md`, "Naming policy").
This driver's device is created by the owner in Composer, so the first chance
to name it is the moment a fan is accepted (`OnDriverLateInit("DIT_ADDING")`,
API 22/_25.1, knows the device is new but no fan yet).

- **N1 Ours until touched.** An item's name is the driver's to change only if
  it equals the shipped default (RF4) or the exact string the driver last wrote
  to that item (the record, 5.3). Any other name is the owner's.
- **N2 Only on a click, and only two clicks.** Use Selected Fan and Name Items
  After Fan. No start-up, update, restore, poll, event or fan-side change
  renames, no property handler does, and no timer of its own does (the job's
  one-shot timer, 5.7, belongs to a click).
- **N3 Compare, call, read back, record.** No call when the live name already
  equals the target. After the calls, read the names back and record only what
  Director confirms.
- **N4 Never guess.** No name for the model, no item ids, a lookup that
  fails, or a name that breaks 5.4: nothing is renamed or recorded. The fan's
  app name is never used.
- **N5 Both or neither.** The guarded rename needs both items ours; the forced
  one (the action) renames both whatever they are, but still obeys N4.
- **N6 Say it.** The result is written to `Last Action` and logged, including a
  decline, with the reason and the way to override.

## 3. Control4-side cases

| # | Case | What happens (Control4; the fan where it matters) | Decision | Why, source |
| --- | --- | --- | --- | --- |
| RC1 | First contact after the owner types Fan Address (L1: the fan is learned and pinned) | The row's Set starts a contact; the model pins the fan and persists its info. The items carry the names they were created with, or the owner's. | **O** | It is not an accept click, and a mistyped address that reaches another Modern Forms fan would name the items after the wrong model. The click that names them is the next one: Use Selected Fan (its target is `Fan Address` when nothing is picked; it answers "already", RC3) or the action. Q2. V1 3.5; ECC D1. |
| RC2 | Find Fans, a pick, Use Selected Fan; no fan pinned before (L3 without "was") | The fan's identity and info are pinned, then the callback runs. Items have the defaults, or the dealer's. | **A-click** | The moment the request names ("once the fan is selected"). Both defaults: renamed (RC16). Otherwise kept (RC7). V1 3.5; RF13. |
| RC3 | Use Selected Fan, the pinned fan again at its address (L4, "already") | The model changes nothing. | **A-click**, usually no call | The natural click for a typed-address device (RC1) to get its names without a new action. The guard decides; if both items already carry their targets no call is made and the text gets no suffix. The alternative (only when the pin changes) costs that device its click and leaves the action. |
| RC4 | Use Selected Fan, the pinned fan at a new address (L2, "moved") | `Fan Address` is set and followed; identity unchanged. Typing the new address gives the same L2 from the first contact (`finish_contact`), and renames nothing (RC1). | **A-click**, as RC3 | Same reason. |
| RC5 | Use Selected Fan, another fan (L3 with "was"): a replacement | Pin, model and firmware replaced; the device, links and programming stay (ECC D18). | **A-click**: names follow the new model while ours; the owner's names stay; same model: equal strings, no call (Q4) | The names are a view of the pinned fan until the owner takes them over. A new model with no name leaves the old model's name in place (N4); resetting ours to the shipped default was rejected as one more automation for a rare corner. |
| RC6 | Use Selected Fan that accepts nothing (L5 no answer, L6 Gen 4 or not a fan, L21 wrong pick, L7 nothing to use) | Nothing changes; the transport goes back. | **F** | Nothing was accepted. |
| RC7 | The owner, a dealer or the Windows session named an item before the first selection ("Example Room Fan"; the cutover's "Fan (new)") | The live name is neither a default nor the record. | **Kept**; the click says "names kept". **O**: the action | D15's reason stands: the name is the owner's. Programming shows it, Navigators and assistants say it aloud (RF8, RF9), and the Windows session picks Connections rows by the "(new)" suffix (MIG Phase 3, step 2). |
| RC8 | The owner renamed an item after the driver named it, then selects again (same fan or another) | The record no longer matches the live name. | As RC7 | The driver stops naming from the moment the owner touches either item; it remembers nothing but the one record. |
| RC9 | The owner renamed one of the two | One item ours, one not. | **Kept**: both stay as they are (N5) | A pair named by two hands ("Example Room Fan" and "Sample Light") is worse than what the owner left. The action names both. |
| RC10 | The cutover: Phase 1 names the new items "(new)", Phase 6 gives them "Fan" and "Fan Light" | Names typed by the Windows session. | **Kept** (RC7); the migration brief never clicks the action; Phase 1 keeps its order (names, then the confirming action) | G14's reason holds: no two items share a name, and the session picks by name. Whether the house's fan should ever carry the marketing name is Q3. MIG G14. |
| RC11 | Two fans of the same model, in one room or in the project | Both devices end with the same two names. | **F** (a number, a room name or any suffix added by the driver); the owner renames one and N1 respects it | A guessed suffix is automation a manual fix must undo, and duplicates are legal [assumed: Composer does not refuse them; two new devices already share the shipped defaults]. A duplicate check over `GetDevices({})` is not in v1. |
| RC12 | Driver update in place (`DIT_UPDATING`), also the first build with this feature | Persisted keys survive; `mf_names` does not exist yet. | **A** (nothing happens) | No trigger. The house's device keeps its names; the action is its way. FUND 14/_2. |
| RC13 | Director restart or controller reboot (`DIT_STARTUP`) | All init, then all late init; the property replay calls every handler (RF14). | **F** at start | RenameDevice is unsafe before late init (RF2), and a loop that keeps the names right at every start is what the project forbids. |
| RC14 | Project restored from a backup: older names, an older `Fan ID` | Names come back as saved; the store may be newer or empty (RF10); the identity comes from the store, else the `Fan ID` row (ECC D10). | **A** (nothing); **O** (the clicks) | A live name matching neither a default nor the record is the owner's, so a store newer than the backup can only make the driver do less. An older identity that no longer fits the fan is RM5. |
| RC15 | Device deleted and added again; a project copied to another controller | A new device has new ids, an empty store and the defaults; a copied project carries its source's names (per-device copy: [assumed absent, HUE `edge-cases-control4.md` 1.6, community]). | **O** (clicks only) | Defaults are ours, so the first Use Selected Fan names them; copied names are the owner's. ECC D8, D11. |
| RC16 | The light item: its own proxy id, its own name | Consumer of 5002, the child under the fan. | **A-click**, with the fan item | The shipped pair is "Modern Forms Fan" and "Modern Forms Fan Light"; the named pair keeps the shape `<Name>` and `<Name> Light`. |
| RC17 | A fan without a light kit (`lightType` empty) | The light item can never be removed (ECC F1) and is greyed for good by `ONLINE_CHANGED` false (V1 4.7). | **A-click**: named like any light | A kit added later needs no second rename, and the name claims nothing. Q5. |
| RC18 | Which id to pass | The protocol device is `C4:GetDeviceID()`; Composer shows the proxies. | **A**: the fan item is the key of `GetBoundConsumerDevices(C4:GetDeviceID(), 5001)`, the light item the key of `(..., 5002)`, and both must also appear under this device's `proxies` in `GetDevices`; otherwise nothing is renamed | RF1, RF5. Never the protocol id, never a guess from id order: on the stock device the light, declared first, has the higher id (MIG, "Words"). |
| RC19 | Timing | RenameDevice is unsafe before late init (RF2); a project refresh takes a moment; the click's callback runs inside the transfer's `OnDone`. | **A**: the callback writes its usual line, then starts one one-shot timer; the job (5.7) runs there; never from a property handler or at start; a second request while a job is pending is answered "busy" (L29; the click's own suffix is `; not renamed`) | RF2, RF14. [assumed: a Director call inside the transfer callback is untested, and the timer costs nothing; K-R2 times the job.] |
| RC20 | The project refresh while Composer is open | Every call refreshes the project (RF1); what an open Composer does with its tree, its selection and an open Properties page is [silent]. | **A**, minimal: at most two calls per click, none when the names already match | K-R2 watches the tree, the selection and the Properties page across one rename. |
| RC21 | Name length and characters | No limit is documented (RF1); a name shows in the tree, as "Room->Name" in programming, on Navigator tiles and in list rows. | **F** for anything outside 5.4 | The names come from the model table only. The Hue drivers cap at 100 characters and strip control characters (their code, not a Control4 limit); a table of short ASCII names makes both unnecessary. |
| RC22 | Navigators, the Control4 app, voice assistants | A name change raises the Navigators' refresh notification (RF7); whether every screen follows unaided is not documented. | **A** (nothing the driver can do); the manual says File » Refresh Navigators, and re-discover in the assistant if a routine names the fan | RF9, ECC U7. It is also why N1 never overwrites a name the family has learned. |
| RC23 | Programming, scenes, the Scheduler and Timer agents, History | References by device id [assumed]; descriptions follow the new name (RF8); History written earlier keeps the name it was written with [assumed]. | **A** (nothing) | Code that finds the device by name (third-party drivers; the Hue drivers' Link Devices) stops finding it: the same reason as RC7. |
| RC24 | A dealer's project shipped to a customer who names rooms and devices | After handover the customer's names are the customer's. | **A** (nothing): the guard never overwrites them, not even for a replacement fan | N1. A dealer who wants the driver's names leaves the defaults or clicks the action. |
| RC25 | The owner types the shipped default, or the exact string the driver wrote | The live name equals a default or the record. | Counted as ours | Harmless: the driver cannot tell a decision from a coincidence, and the names can be retyped. |
| RC26 | A second device of this driver: does Composer number the default ("Modern Forms Fan 2")? | [silent] | **A**: the test is an exact match, so a numbered default reads as the owner's and is kept | Safe either way; K-R3 reads it. |
| RC27 | Registering for `OnItemNameChanged` to notice the owner's renames | Works (RF7), as a listener on every device of the project. | **F** (not used) | The compare at the click does the same job with no listener, no payload parsing and no start-up work. |
| RC28 | Director does not confirm: the call raises, a name reads back unchanged, an id has gone | RenameDevice returns nothing (RF1). | **A**: each call in `pcall`; the read-back decides; the record gets only confirmed names; L26 or L27; the next click tries again | N3. A half-done pair is two ours. |
| RC29 | Name Items After Fan with no fan pinned, an unknown or unread model, or the fan not answering | The action reads the persisted pin and info, not the network. | **O**: refuses with L24, L25 or L28 when it has no name; otherwise works offline, even while another fan answers, naming after the *pinned* fan | The names belong to the device's identity, not to the fan's state. |
| RC30 | OS 4.x, and the newer date-versioned Composer Pro releases | RenameDevice is documented without version differences (RF1); the refresh and Composer's reaction are [silent] for every release. | **A**: the same code | ECC D13: the Composer checklist is run again after an upgrade, and K-R2 is a step of it. |

## 4. Modern Forms-side cases

| # | Case | What happens (the fan; then Control4) | Decision | Why, source |
| --- | --- | --- | --- | --- |
| RM1 | The owner renames the fan in the Modern Forms app | `deviceName` changes; it is private and dropped on receipt (V20). | **F**: the Control4 names never follow it and it is never read for a name | It is often a room name, the project keeps it out of the driver, and Control4 is the source of truth. The read-only `Fan Name` row of the early plan (ECC 6.2, ECM V4) went with V20. |
| RM2 | A firmware update changes `fanType`, or a later build changes the name table | The static data is re-read at the next contact; `record_info` logs the difference and persists it (ECM F1, H3). | The name property follows (**A**: a function of `fanType`); the items' names do not (**F** without a click); the next Use Selected Fan or the action applies it | A rename on a firmware event would be an automation nobody clicked, at an hour nobody chose. |
| RM3 | The light kit is added or removed (`lightType` changes) | `Fan Model` and the light's `ONLINE_CHANGED` follow at the next contact. | **F** for the items: nothing triggers | RC17: the names do not depend on the kit. |
| RM4 | Factory reset, Wi-Fi reset, router change | The same MAC (ECM H10 [assumed]), maybe a new address, silence meanwhile. | No trigger | At another address it is RC4; as another identity, RM5. |
| RM5 | A different fan answers at the address: swapped addresses, a lease handed on, a replaced fan, a restored older `Fan ID` | Foreign: nothing is sent (Status S11); the pin is kept. | **F** until the click; then RC5 | V1 3.5, 6. |
| RM6 | A Gen 4 fan | HTTP 404 on `/mf`, then `fan_g4`: refused (S12); no `fanType` is read. | No name, no rename; L6 "nothing changed" | V1 V4, 3.6. |
| RM7 | The model has no name: `fanType` not in the table, empty, or not read yet | No name. | **F**: never guess; L24 or L25 says which; the action refuses | N4. The property prints the raw type (the sibling note). |
| RM8 | Two driver devices pointed at one fan | Both name their items after the same model. | As RC11 | ECC D17. |
| RM9 | `fanType` written differently for one model: blanks, case, a different blade span | A different string. | **F**: no fuzzy matching; the key is compared exactly as the sibling note defines it, and a miss is RM7 | N4. A wrong name on a fan is worse than none, and a miss costs one report that adds a table row. |

## 5. Recommendation

### 5.1 The moments

1. **Use Selected Fan, when it leaves a fan pinned** (`already`, `moved`,
   `now_using`: L4, L2, L3): the guarded rename, after the usual `Last Action`
   line. Failures (L5, L6, L7, L21) never rename.
2. **Name Items After Fan**, a new action: the forced rename (5.6).
3. Nothing else. In particular not the first contact (L1, Q2), `OnDriverInit`
   or late init, a property handler, a poll, an `info` or `phase` event, a
   firmware or kit change, or an update.

### 5.2 What is renamed, and to what

Both items, from the persisted `fan_type` (the pinned fan's own info, so the
action works while the fan is silent): the fan item `<Name>`, the light item
`<Name> Light`, whether or not there is a light kit. `<Name>` is the sibling
note's string for this `fanType`; no entry, or an entry that fails 5.4, means
no rename. The names of other models, of the light kit and of the app are
never used.

### 5.3 The guard and its record

`ours(item)` is true when the live name, from `GetDeviceDisplayName(proxy id)`
and trimmed, equals the shipped default of that item or the string in the
record. The default pair is a list of every pair a build ever shipped (today
one), and a spec asserts the current constants equal the `name` attributes in
`driver.xml`. The record is one persisted key,
`mf_names = { fan = "Sample", light = "Sample Light", at = <epoch s> }` (V1
8), written per item after the read-back confirms it. It holds nothing
private and is absent on every device until the first confirmed rename.
Guarded: rename only when `ours(fan) and ours(light)`; skip an item whose live
name already equals its target. Forced: skip nothing but that equality.

### 5.4 The name's constraints, from the Control4 side

- Nothing in `C4:RenameDevice` limits length or characters (RF1), so the
  limits are ours, and the model table is the only source of a name.
- ASCII letters, digits, spaces and hyphens. No `"`, `'`, `<`, `>`, `&`,
  commas, semicolons, `|`, backslashes, control characters or non-ASCII. The
  inch sign is the likely trap (blade spans are written 54"): leave the span
  out; it is in `Fan Model`. Reasons: Director writes names into the project
  file [assumed: it escapes `<` and `&`, HUE
  `docs/reviews/security-2026-10-24.md`, finding 10];
  names appear in Lua-built list rows, where a comma splits the row (the
  Migration Report and Keypad Links print device names and replace commas by
  U+201A); programming shows "Room->Name".
- `<Name>` at most 22 characters, no leading or trailing blank, and not ending
  in " Light"; the light item is `<Name> Light`, at most 28. This keeps L22
  under 70 characters and a Navigator tile readable [assumed: tile width].
- No room name, no number, no "Modern Forms" prefix added by the driver
  (RC11): a fan's name is the model's, and the room is the tree's.
- A table entry that breaks these is refused at load by the module (fail
  closed: "no name known"), and a spec checks every entry.

### 5.5 What Last Action and the log say

After a Use Selected Fan, L2, L3 or L4 is written at once, as today. When the
job ends (about 2 s later, 5.7) the same line is written again with one short
suffix, so the whole stays under 70 characters (L3 plus the longest suffix is
66): `; items renamed`, `; names kept` (RC7 to RC10, only when a rename was
possible and declined) or `; not renamed` (N4). Nothing is added when the
names already matched. The sentences below are the action's, and the log's.

| Id | When | Text |
| --- | --- | --- |
| L22 | the action renamed | `Items named Sample and Sample Light` |
| L23 | the action found nothing to change | `Items already named Sample and Sample Light` |
| L24 | the model has no name | `No name known for fan type 1811-5-54; items not renamed` (the type cut to 14 characters) |
| L25 | the fan type is not read yet | `Fan type not read yet; try again in a moment` |
| L26 | the items' ids were not found | `Items not renamed: this device's items were not found` |
| L27 | Director did not confirm | `Rename not confirmed; check the item names in Composer` |
| L28 | the action, no fan pinned | `Nothing to name the items after: no fan is set up yet` |
| L29 | the action, a job is pending | `Naming in progress; try again in a moment` |

One always-on log line per job (`log.always`, as `result` does for every Last
Action): `names (Use Selected Fan): fan item <id> "Modern Forms Fan" ->
"Sample"; light item <id> "Modern Forms Fan Light" -> "Sample Light"`; a
decline names the live name and the target: `kept: fan item <id> is "Example
Room Fan", not a default or a name the driver set; fan type 1811-5-54 would
be "Sample"`; the action logs the old names too, which is the owner's way back.
Debug Mode adds the lookups (the ids, the cross-check, the read-back). Old
names are the owner's own words: a `--dev` build's redactor should withhold
the quoted old names (the coordinator's call), and anything posted to GitHub
gets the placeholders.

### 5.6 Name Items After Fan

Yes, it should exist: it is the way back for every "kept" (RC7 to RC10), for
the typed-address device (RC1) and for a model that gained a name in a later
build (RM2), and it makes the guard acceptable because nothing is ever stuck.
An action on the Actions tab, not a programming command (V1 V25); after Use
Selected Fan in the list (RF11). Forced: it renames both items whatever they
are called; it refuses on N4 and on no pinned fan; it works offline (RC29); it
is idempotent (L23); after it the new names are ours again, so a later
replacement fan's names follow. It is not part of `tools/regress.sh` on the
house's device. A dev-only command, `Dev Names Plan` (beside Dev Press and Dev Proxy),
prints what either click would do without calling RenameDevice: the Windows
session and the VM read the ids and the plan with it before anything is
renamed.

### 5.7 The job

Started by the callback of the two clicks, from one one-shot timer (RC19):

1. Target from `model:info()` and the name table, else L24 or L25 and stop.
2. Ids from the two bindings, cross-checked with `GetDevices`; else L26.
3. Live names from `GetDeviceDisplayName`; guarded: both ours, else "names
   kept" and stop.
4. `C4:RenameDevice(id, target)` for each item whose live name differs, each
   in `pcall`; the fan item first, the light item in the same tick [assumed:
   two back-to-back calls and their two refreshes are fine; K-R2 times them,
   and the light item moves to its own tick if not].
5. About 2 s later, read both names back; record those that match; write
   Last Action (L22/L23 or L27, or the suffix) and the log line.

A restart or an update kills the timer (API 22/_24), and `OnDriverDestroyed`
cancels it like every other timer here (a dev reload runs it in the same Lua
state); the record then holds only what was confirmed, and the next click
finishes the job (RC28). One job at a
time; a request during one is answered "busy" (L29) and changes nothing.

### 5.8 The manual changes

- Chapter 1: the sentence that the driver "never adds, renames, moves or
  deletes a Control4 device" becomes: it never adds, moves or deletes one and
  never changes keypad programming, and it renames its own two items only when
  you click Use Selected Fan or Name Items After Fan, and never one you named
  yourself. "What appears in Composer": instead of "you may rename them; the
  driver never does", say that you may rename them any time, that the driver
  then leaves them alone, and that Name Items After Fan takes them back.
- Chapter 3: the Use Selected Fan table gains the three suffixes; a new
  subsection "The names of the two items" says when (the two clicks), what (the
  fan's marketing name, the light the same plus " Light"), the rule (only while
  they still have the names they were created with or the driver gave them),
  that nothing renames at start-up, update, restore, a new address, a firmware
  or light-kit change, and that two fans of one model get the same name, so
  rename one. After a rename: File » Refresh Navigators, and a new discovery in
  a voice assistant whose routines name the fan. For an unknown model: no name;
  note `Fan Model` and open an issue.
- Chapter 8: the replaced-fan row says the items follow the new model unless
  you named them; the firmware and light-kit rows say the names do not change
  by themselves.
- Chapter 10: the action's row and the sibling note's property row.
  Chapter 11: your "(new)" and family names stay; do not click Name Items
  After Fan during the move.

### 5.9 The cutover

No phase changes order. G14 gains one sentence: the "(new)" names and the
family's "Fan" and "Fan Light" are the owner's, so the driver leaves them
(N1). The Phase 1 check expects the confirming action's `Last Action` to end
in `; names kept` (or `; not renamed` if the model has no name), and the briefs
say the session never clicks Name Items After Fan during the migration. Phase 1
keeps its order (names, then the confirming action): in the other order the
marketing names land first and the session renames over them, which is
harmless but loses the "(new)" mark between the two steps. The way back
(Phase 6's, and MIG section 6) is unchanged: the driver never renamed anything
the session has to undo. Whether the finished house keeps "Fan" and "Fan
Light" is Q3. (The cutover renames in Phase 6, before the stock device goes in
Phase 8.)

### 5.10 Other documents

`v1-design.md`: a decision V28 (the two moments, N1 to N6); 2.6 the action and
its `sort_order`; the 3.5 table's result column; 7.2 the texts L22 to L29 and
the suffixes; 8 the key `mf_names`; 9 a pure `fan/names.lua` (`plan(live,
record, target, mode)` returning the calls and the text, Director's calls
handed in as an `api` table as `migration.lua` does) and its spec; 9.12.
`edge-cases-control4.md`: D15 ("A-click, guarded; O the action; F otherwise"),
U6, U7. `edge-cases-modernforms.md`: rule 1 and V4 (their "never renames"
gets a pointer here). `migration-design.md`: G14, the Phase 1 check, the
briefs.
`composer-checklist.md`: a names section from 5.11. `docs/README.md` (a note
for the index, not the front page), `CHANGELOG.md` (#37) and `status.md`.

### 5.11 Tests and hardware checks

Specs (busted, the fake runtime of RF15): the guard table (both defaults;
both recorded; one owner's; none); no `RenameDevice` after late init with a
pinned fan and default names, nor after an update, a restore or a firmware
change (assert `c4.renamed` is empty); each Use Selected Fan outcome; same
model, no call; ids missing or not under `proxies`; a read-back that differs;
an unknown or unread model; the busy answer; the constants against
`driver.xml`; every table name against 5.4.

Checks for the Windows session, each under a minute, with the standing
approval named in the brief. K-R1 and K-R2 need no new build: the M1 probe
(`mf_probe`, still installed in the test room) has the same two proxies on 5001
and 5002 and a Lua command window, and it is a throwaway by construction; the
names are put back afterwards and nothing is saved or loaded.

- **K-R1 (read-only):** the two ids from `GetBoundConsumerDevices(<probe id>,
  5001)` and `(..., 5002)` equal the tree's two items and the keys of
  `proxies` in `GetDevices`; what `GetDeviceDisplayName` returns for the
  protocol id and for both proxies. Settles RF5.
- **K-R2 (one rename, then back):** `C4:RenameDevice` on the fan proxy's id,
  then the light's: seconds until `GetDeviceDisplayName` shows the new name;
  whether the open tree repaints by itself and keeps its selection; whether an
  open Properties page survives; no dialog and no "Restart Director?"; whether
  the protocol device's name changed; whether two calls in one tick behave.
  Settles RC19, RC20, RC30 (and again after an OS or Composer upgrade).
- **K-R3:** a second probe device added and deleted: does it carry the shipped
  default or a numbered one (RC26)?
- **K-R4 (the owner's phone, optional, blocks nothing):** the tile's name
  before and after File » Refresh Navigators.

Once the code exists: `Dev Names Plan` on a throwaway device repeats K-R1, and
the Composer checklist gets the steps of the four moments (a fresh device, a
renamed item, the cutover's names, the action).

Verified in the Hue project and used here: RenameDevice on a proxy id acts on
the house (RF6), `GetDeviceDisplayName` takes either id (RF3), a Composer
rename fires `OnItemNameChanged` with the proxy id (RF7). Assumed: the fan
proxy of a two-proxy device renames the same way, the refresh's effect on an
open Composer, Navigators and assistants following, duplicates being allowed,
default names not being numbered, programming holding ids.

## 6. Open questions for the owner

Recommended answer first; the note stands on the defaults until one is given.

1. **Q1 The guard.** Use Selected Fan renames only items that still have the
   shipped names or the driver's own last names (N1, RC7 to RC9), and says
   "names kept" otherwise. Or should it rename whatever the names are, as the
   request reads literally? Without the guard: the cutover's "(new)" names are
   overwritten by Phase 1's confirming action (the session picks Connections
   rows by that suffix), a dealer's or customer's names are overwritten by any
   later Use Selected Fan, and a voice routine breaks without a word. What the
   guard costs: one persisted key and one compare. Recommended: the guard.
2. **Q2 Typed address.** The first contact after a typed `Fan Address` (L1)
   does not rename; Use Selected Fan (which also takes the typed address) or
   Name Items After Fan does. Or should L1 rename too, with the same guard?
   Recommended: not at L1. The request says "once the fan is selected", L1 is
   a side effect of a property's Set, and a mistyped address would name the
   items after the wrong model (it heals at the next Use Selected Fan, but it
   is noise). The cost: a dealer who only types the address sees no names
   until one more click.
3. **Q3 The house's own fan.** After the cutover the items stay "Fan" and "Fan
   Light" (the guard keeps them; the marketing name shows in the property). Or
   should the house take the marketing name too: one click on Name Items After
   Fan after Phase 6, changing what the family and the voice assistants call
   the fan? Recommended: keep the family's names.
4. **Q4 A replacement of another model.** While the names are still the
   driver's, they follow the new fan's model (recommended: they are a view of
   the pinned fan until you take them over). Or stay as first set until you
   click the action? Then "ours" is the shipped default alone and `mf_names`
   is not needed.
5. **Q5 A fan without a light kit** (minor). Name its light item too
   (recommended: the item stays for good and a later kit needs no second
   rename), or leave its default name?
