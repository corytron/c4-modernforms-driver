# Edge cases and lifecycle policy: the fan side

> **Research (2026-10-27) for [issue #2](https://github.com/corytron/c4-modernforms-driver/issues/2)**, written before the v1 contract. Read-only: nothing here was tried on the house fan. It lists what a Modern Forms fan, its remotes, the Modern Forms app and WAC's cloud do over the life of the system. For each case it says what the driver sees and recommends what is automatic, what is only offered (a click in Composer) and what is forbidden without a click. The Control4 side is [`edge-cases-control4.md`](edge-cases-control4.md): Composer, Director, proxies, bindings, discovery APIs and the move from the stock driver. The fan's interface itself is [`modernforms-api-research.md`](modernforms-api-research.md); this file uses it only where a lifecycle case depends on it. The owner's answers go into §11; until then the recommended defaults stand.

A fan differs from the Hue bridge in three ways, and most rows here
follow from them:

1. **The fan never tells; the driver has to ask.** No public client and
   no vendor document describes a push or an event stream. Every known
   integration polls (§0), so a change made at the remote shows up at
   the next poll, and a command and a poll can cross.
2. **The fan's network side is fragile, and often switched off.** Its
   small HTTP server freezes under load, slows down and rejects large
   headers (§0). A wall switch, a breaker or the wall control's pull tab
   cuts its Wi-Fi together with the motor. The driver usually cannot
   tell "unpowered" from "stuck" or "moved".
3. **The fan acts on its own.** The fan or WAC's cloud runs schedules,
   away mode, adaptive learning, sleep timers and thermostat or voice
   integrations, and the remote and the wall control work without any
   network. The north star says automations live in Control4. So the
   driver detects these, reports them and offers a click to stop them.
   It never fights them by re-sending state.

## Rules behind every row

The first three are the Hue project's (its `docs/import-design.md` §1),
restated for one fan; the rest are new.

1. **The project is the owner's.** The driver never creates, deletes,
   renames, moves or re-points a Control4 device on its own
   ([`edge-cases-control4.md`](edge-cases-control4.md)).
2. **Nothing is lost by waiting.** Every change the driver detects is
   shown (`Status`, `Attention`) and logged, so the owner can act on it a
   week later.
3. **The Control4 device is the identity; the physical fan can be
   re-pointed.** Keypad links, programming and scenes hang on the Control4
   device. A replaced fan, receiver or Wi-Fi network is handled by
   re-pointing the device (`Use Selected Fan`), never by deleting it and
   adding it again.
4. **The fan is known by its own identity, not its address.** The key is
   the station MAC, as 12 hex digits. On generations 1 to 3 the client id
   carries the same digits. Every first answer after a silence is checked
   against the stored identity, and a mismatch stops every command.
5. **Report what is known; invent nothing.** A missing field is unknown,
   not false or zero. An unreachable fan is "not current", not off (Q1).
6. **One request at a time, gently.** One request in flight per fan,
   minimal headers, bounded timeouts, commands coalesced, and polls no
   more often than needed (Q4).
7. **Control4 is the source of truth.**
   - The driver sends only state that Control4 asked for (fan on, speed
     and direction, light on and level), and only when asked. It never
     re-sends state to "correct" the fan.
   - It detects and shows the fan's own automations automatically.
     Stopping one takes a click, and the click can be undone where the
     interface allows: the driver saves before it clears and offers
     Restore.
   - Destructive commands are never sent in v1 (§9).
8. **Private data stays private.** The owner's email, the AWS identity,
   the certificate id, the Wi-Fi SSID and BSSID, the time zone and (on
   generation 4) the location are never logged, shown or included in
   Diagnostics. The MAC and client id are shown in Composer only and
   redacted from anything that leaves the project.

## Status markers and sources

**[VERIFIED: key]** means a source shows the fact; for a community key
the fact is that someone *reported* it, and the row says "reported".
**[ASSUMED]** means nobody has shown it; §12 lists how to check.
**[proposal]** marks a number or name this document suggests for the v1
contract. Nothing is quoted at length; field names are cited as names.

| Key | Source |
| --- | --- |
| AIO | `aiomodernforms` 0.3.1 (MIT), files `const.py`, `models.py`, `modernforms.py`, `gen4.py`: https://github.com/wonderslug/aiomodernforms/tree/master/aiomodernforms |
| AIO-mock | its mock fan, `mock_fan/state.py`, `generations.py`: https://github.com/wonderslug/aiomodernforms/tree/master/mock_fan |
| AIO-readme | https://github.com/wonderslug/aiomodernforms#readme |
| AIO#99, #272, #287 | https://github.com/wonderslug/aiomodernforms/issues/99 (brightness before on), /issues/272 (a real generation 3 fan's report), /issues/287 (generation 4 testing) |
| HA | Home Assistant `modern_forms` (dev branch, Oct 2026), files `manifest.json`, `config_flow.py`, `coordinator.py`, `fan.py`, `light.py`, `diagnostics.py`: https://github.com/home-assistant/core/tree/dev/homeassistant/components/modern_forms |
| HA-docs | https://www.home-assistant.io/integrations/modern_forms/ |
| HA#59655, #123828, #144431, #146673, #149019, #169247 | https://github.com/home-assistant/core/issues/ + the number (light flash; timeouts on a mesh network; fan starting by itself; HTTP 431; stuck fans and polling; generation 4 not connecting) |
| HA-forum | https://community.home-assistant.io/t/modern-forms-fan-intermittently-unavailable-http-api-on-port-80-stops-responding/1024570 (Sep 2026) |
| ST | https://community.sharptools.io/t/modern-forms-fan-with-smartthings/11144 (2023) |
| Hubitat | https://github.com/bhamiltoncx/hubitat-modern-forms-fan |
| openHAB | https://www.openhab.org/addons/bindings/mffan/ |
| MF-app | Modern Forms app instructions (2019): https://cdn.shopify.com/s/files/1/2618/7426/files/AppInstructions.pdf |
| MF-feat | Modern Forms smart fan features brochure: https://media.lightingnewyork.com/content/Modern-Forms-Smart-Fans-Features.pdf |
| MF-rc | F-RC-WT remote instructions: https://images.thdstatic.com/catalog/pdfImages/07/07fad39c-56f6-4c95-af46-88b885896610.pdf |
| MF-wc | F-WC RF wall control spec sheet (2018): https://images.thdstatic.com/catalog/pdfImages/89/899880cd-045e-4ab9-b982-ba58e591fb0d.pdf |
| MF-wci | F-WC-WT wall control installation instructions: https://images.thdstatic.com/catalog/pdfImages/76/7619a509-bd0a-4878-b41f-0b5e9210d6a6.pdf |
| MF-2026 | 2026 Modern Forms fan supplement catalog: https://ebook.waclighting.com/2026/modernforms/2026_MODERN_FORMS_FAN_SUPPLEMENT_CATALOG.pdf |
| MF-faq | Smart fan FAQ (WAC group): https://schonbek.com/smart-fan-faqs-smart-advice/ |
| MF-store | Modern Forms app, App Store version history: https://apps.apple.com/us/app/modern-forms/id1425046298 |
| CEPro | May 2026 article on the 2026 line: https://www.cepro.com/news/wac-group-expands-modern-forms-smart-fan-line-with-new-designs-lighting-features/626711/ |
| Lowes | a fan sold with the light kit separate: https://www.lowes.com/pd/Modern-Forms-Aviator-Indoor-and-Outdoor-3-Blade-Smart-Ceiling-Fan-54in-Graphite-with-Wall-Control-Light-Kit-Sold-Separately/5000254581 |
| UVC | the UV-C "Ultra" fan: https://kbbonline.com/products/modern-forms-ultra-germicidal-smart-fan/81397/ |
| WWN | end of Works with Nest: https://support.google.com/googlenest/answer/9293712 |
| WAC-dev, WAC-lic | WAC's developer page and its API License Agreement (2021-10-21): https://www.waclighting.com/developer, https://waclighting-images.s3.amazonaws.com/developer/WAC_API_License_Agreement_21.10.2021.pdf |
| WAC-2021 | WAC's own third-party API reference for generations 1 to 3 (2021), as published in the aiomodernforms repository: https://github.com/wonderslug/aiomodernforms/blob/master/docs/WAC_Modern_Forms_3rd_Party_API_Reference.pdf (see Q7 before relying on it) |
| DW | the DriverWorks API reference, `~/c4-tools/reference/docs-driverworks-api/` |

## Names used below (proposals; the v1 contract fixes them)

Where a name is also in [`edge-cases-control4.md`](edge-cases-control4.md)
§6.2 (`Status`, `Fan Address`, `Fan ID`, `Fan Name`, `Last Seen`,
`Last Action`, `Find Fans`, `Use Selected Fan`), it is used as there; the
others are what the fan side adds.

| Name | Kind | What it shows or does |
| --- | --- | --- |
| `Fan Address` | property, editable | The fan's IPv4 address; the manual requires a DHCP reservation. |
| `Status` | property | One line: what the driver is doing, or what is wrong. |
| `Attention` | property | What needs the owner, one item per line; an item clears itself when its cause goes. |
| `Last Action` | property | The result of the last action clicked. |
| `Fan ID` | property | The client id and station MAC the driver learned. |
| `Fan Model` | property | Generation, fan type, light kit (or "no light kit"), Breeze. |
| `Firmware` | property | Firmware and motor-controller versions, with the date of the last change. |
| `Fan Name` | property | The fan's name in the Modern Forms app. |
| `Last Seen` | property | Time and duration of the last answer. |
| `Last Change By` | property | Who made the last change the driver did not send (from `userData`). |
| `Fan Automations` | property | The fan's own schedule, away mode, adaptive learning and sleep timers. |
| `After Power Returns` | property, editable | Q2. |
| `Poll Interval` | property, editable | Q4. |
| Actions | Composer actions | `Use Selected Fan` (here: re-point the device at the fan now answering at `Fan Address`, or the one picked from `Find Fans`), `Reboot Fan` (also a programming command), `Turn Off Away Mode`, `Turn Off Adaptive Learning`, `Clear Fan Schedule`, `Restore Fan Schedule`, `Clear Fan Timers`, `Accept Fan Automations`, `Diagnostics`; `Find Fans` as Q3 decides. |

## 0. Facts the policy rests on

| Fact | Status |
| --- | --- |
| **Interface.** Generations 1 to 3 speak plain HTTP on port 80: a JSON body POSTed to `/mf`. `queryDynamicShadowData` returns the state and `queryStaticShadowData` the identity and model. A command is a POST of the fields to change, and its answer is the whole state after the change. A separate `/config-read` gives the firmware, the RF version and the Wi-Fi strength (GET on generations 1 and 2, POST on 3). There are no credentials. | [VERIFIED: AIO `const.py`, `modernforms.py` (`_request`, `request` applies the answer as state, `config`), `models.py` `ConfigInfo`]; GET vs POST [VERIFIED: WAC-2021] |
| **State fields** (generations 1 to 3): `fanOn`; `fanSpeed` 1 to 6; `fanDirection` `forward` or `reverse`; `lightOn`; `lightBrightness` 1 to 100; `awayModeEnabled`; `adaptiveLearning`; `schedule` (base64); the sleep timers; `rfPairModeActive`, `resetRfPairList`, `factoryReset`, `decommission`. Generation 3 adds `wind`, `windSpeed` 1 to 3 (Breeze) and `userData`. There is no speed 0 and no brightness 0: off is `fanOn` or `lightOn` false. | [VERIFIED: AIO `const.py`, `models.py`; the ranges in `modernforms.py` `fan()` and `light()`]; which generation has `wind` and `userData` [VERIFIED: WAC-2021; AIO#272 for `wind` on a real generation 3 fan] |
| **Identity fields:** `clientId` (`MF_` or `WAC_` and the 12 hex digits of the MAC), `mac` (the station MAC), `deviceName` (the name set in the app), `fanType` (model and blade length), `lightType` (the light kit, empty when there is none), `fanMotorType`, `firmwareVersion`, `mainMcuFirmwareVersion`, `firmwareUrl`, and the account's `owner` (an email address) and `federatedIdentity` (an AWS identity). | [VERIFIED: AIO `const.py`, `models.py` `Info`; that `owner` and `federatedIdentity` are private: AIO-readme (its diagnose tool redacts them)]; prefixes and "empty without a light" [VERIFIED: WAC-2021; HA `light.py` makes no light entity when `lightType` is empty] |
| **Two MACs.** Generation 3 receivers use another MAC as an access point than on the home network, and the station MAC is the one that counts. Generation 4 reports `staMac`, `apMac` and `bleMac`. | [VERIFIED: WAC-2021; AIO `const.py`, `gen4.py` keys identity on `staMac`] |
| **Generations.** Generation 3 is told apart from 1 and 2 by its relative timers (`fanTimer`, `lightTimer`, seconds left) where 1 and 2 hold absolute epoch times (`fanSleepTimer`, `lightSleepTimer`). Generation 4 answers `/mf` with HTTP 404 and is read through `/device` and `/fixture`: a fan fixture plus one or more light fixtures, brightness 1 to 10000, colour temperature, no sleep timers and no adaptive learning. A fixture read-all lacks the state, so every fixture is read on its own. | [VERIFIED: AIO `models.py` `_infer_generation`, `modernforms.py` `update`, `_fill_gen4_fixture_state`, `gen4.py`; HA#169247] |
| **2026 line.** Elite fans use the MyWAC app, Select fans the Modern Forms app. The generation 4 fans reported so far are 2026 models (a Radiant). | [VERIFIED: MF-2026; AIO#287, HA#169247]; that the app split follows the generation [ASSUMED] |
| **No push.** Every integration polls: Home Assistant every 15 s, Hubitat 30 s, openHAB 120 s. Changes made at the remote and the wall control are picked up by polling. | [VERIFIED: HA `coordinator.py`; Hubitat; openHAB]; no push mechanism in WAC-2021 [VERIFIED: absent] |
| **Fragile server.** A normal answer takes 0.2 to 0.4 s; reports describe answers of 9 s, port 80 failing while ping answers, and fans whose Wi-Fi module froze under polling (an integration plus the app) until the power was cut. One generation 4 fan reported off while its blades turned, until a mains power cycle. An HTTP 431 error came from a 2 KB cookie header. | [VERIFIED reports: HA-forum, HA#149019, AIO#287, HA#146673] |
| **Without the cloud.** The fan needs the cloud once, at setup; after that local control works without it. A generation 4 fan never commissioned to the cloud was controlled locally. Home Assistant's docs suggest blocking the cloud and allowing NTP. | [VERIFIED: MF-feat; AIO#287 (reported); HA-docs] |
| **Remotes and wall controls.** Older ones are RF (315 MHz), newer ones Bluetooth. Up to 4 controls per fan; one RF control runs up to 2 fans, a Bluetooth remote many. They work without Wi-Fi, and holding a speed button steps through the speeds with beeps. They can also reset the fan's Wi-Fi (6 s hold) or factory reset it (10 s), and pairing one needs the fan's power cycled at the breaker. | [VERIFIED: MF-wc, MF-wci, MF-rc, MF-2026] |
| **Power.** The Modern Forms wall control is wired where the wall switch was and keeps the fan powered; its pull tab cuts the power for emergencies only. Anything else in the fan's supply (a plain switch, a dimmer, a relay, a Control4 load, the breaker) cuts the Wi-Fi together with the motor and the light. | [VERIFIED: MF-wci]; the second sentence [ASSUMED from the wiring] |
| **Resets.** A Wi-Fi reset clears only the Wi-Fi credentials. A factory reset also clears the remote and app pairings and the cloud registration. Afterwards the fan broadcasts its own access point, named after the last 6 hex digits of its MAC, until it is set up again in the app. A router change needs the same set-up. The app and the cloud can also factory reset a fan. | [VERIFIED: MF-rc, MF-wci, MF-app, MF-faq, AIO `modernforms.py` `factory_reset`, MF-store 1.4.17] |
| **Automations in the fan.** Schedules (weekly or calendar, with times, speed and brightness) are kept in the fan as the `schedule` blob. Away mode switches the fan and the light on and off at random. Adaptive learning learns habits and may run the fan by itself. Sleep timers switch fan or light off. `userData` names the last source of a change: `none`, `local_wifi`, `cloud`, `ble`, `sleep_timer`, `away_mode`, `schedule`. | [VERIFIED: MF-app, MF-feat, AIO `const.py`]; the `userData` values [VERIFIED: WAC-2021, generation 3 example only]; that the fan itself runs them [ASSUMED] |
| **Firmware** is updated from the app, also in access-point mode without an account. Generation 3 firmware already sends fields no document lists: SSID, BSSID, timezone, isUvcFan, FrCodes, cloudPort, feedbackToneMute and others. | [VERIFIED: MF-store 1.4.4, 1.4.25; AIO#272] |
| **Time.** Generation 1 and 2 timers are absolute times that depend on the fan's clock (NTP). The app sets the fan's time zone. | [VERIFIED: AIO `modernforms.py` `_sleep_command`; HA-docs; MF-store 1.4.24] |
| **Discovery.** The fan advertises the mDNS service `_easylink._tcp` with its MAC in a TXT record. DriverWorks has no mDNS call, but it has SDDP discovery info and an ARP-based MAC lookup. | [VERIFIED: HA `manifest.json`, `config_flow.py`; no mDNS, Bonjour or zeroconf in DW; DW `32_serial_network_device/_7-GetDeviceMAC.md`, `_8-GetDiscoveryInfo.md`]; the rest is in [`edge-cases-control4.md`](edge-cases-control4.md) |
| **WAC's terms.** WAC offers its REST API to third parties on request, under an API License Agreement. The agreement treats the API and its documents as confidential and forbids reverse engineering. It lets WAC limit usage, and it promises licensees 3 months' notice of backwards-incompatible changes. | [VERIFIED: WAC-dev, WAC-lic §6.3, §6.4, §7.1, §8]; see Q7 |

## 1. Address and identity

Columns, here and in §2 to §7: what the fan does; what the driver sees;
what it does on its own; what it offers as a click; what it never does
without one; the text the owner reads.

| # | Case | What the fan does | What the driver sees | Automatic | Offered (a click) | Forbidden without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- | --- |
| N1 | Address changes (DHCP without a reservation) | Gets a new address after a power cut, a reboot or a lease change [ASSUMED]; identity unchanged. | The old address times out, or something else answers there (N3, N4). | Offline by P1. The old address is retried with backoff. When the owner types a new `Fan Address`, the driver reads the static data there and resumes only if the MAC matches. If the transport research finds passive discovery (an mDNS announcement or SDDP carrying the stored MAC), the new address is taken automatically and logged. | `Find Fans`, as Q3 decides. | Scanning the network on its own; matching a fan by name, model or address. | `Status` "Fan not answering at 10.0.2.151 since 14:02 (power off at the wall, Wi-Fi changed, or a new address; reserve the fan's address in the router)". After a new address: `Last Action` "Same fan (MAC 00:00:5e:00:53:01) now at 10.0.2.152". |
| N2 | Address reserved in the router (the documented set-up) | Keeps its address. | — | Nothing. | — | — | The manual: reserve the address for the station MAC shown in `Fan ID`, not the access-point MAC (§0). |
| N3 | Another Modern Forms fan answers at the address: two fans swapped addresses, or a replacement got the old one | Answers normally. | Static data with another MAC and client id. | Every command and state update stops at once; the last state stays, marked not current. Each poll checks again, since the right fan may come back. | `Use Selected Fan` (re-point; H1). | Adopting it (with two fans, their keypads would cross); sending it anything. | `Status` "10.0.2.151 now answers as another fan (MAC 00:00:5e:00:53:02); nothing is sent. Replaced fan: Use Selected Fan. Swapped addresses: correct Fan Address and reserve both". `Attention` at once. |
| N4 | Something that is not a fan of this generation answers | — | Connection refused, an HTML page, an empty or non-JSON body, JSON without `mac`, or HTTP 404 on `/mf`. A generation 4 fan also gives 404 (H2). | Handled like offline. On a 404, one read-only `/device` query tells a generation 4 fan apart. No command is ever sent there. | — | Sending commands to an unknown interface. | `Status` "Something at 10.0.2.151 answers, but not as a Modern Forms fan (HTTP 404 on /mf); check Fan Address". |
| N5 | Fan's Wi-Fi reset (remote, fan buttons, app) | Forgets the Wi-Fi and broadcasts its own access point. Motor, light, remote and wall control keep working [VERIFIED: MF-rc for the reset; ASSUMED for the rest]. | Timeouts, as for a power cut. | As P1. | — | — | As P1. Changes made at the remote meanwhile appear when the fan is back (P2). |
| N6 | New router, SSID or Wi-Fi password | Must be set up again in the app; it stays listed there [VERIFIED: MF-rc, MF-faq]. Then comes back at a new address (N1) or on a network the controller cannot reach. | Timeouts; maybe answers elsewhere later. | As N1. | — | — | The manual's router-change steps: set up in the app, reserve the address, check `Fan Address`. |
| N7 | Router no longer offers what the fan needs (2.4 GHz, a password, a visible SSID) | Cannot join [VERIFIED: MF-faq]; WPA3-only networks [ASSUMED: same]. | Offline. | As P1. | — | — | The manual lists the Wi-Fi requirements. |
| N8 | The app reaches the fan, the controller does not (mesh satellite, client isolation, VLAN) | Works through the cloud. A user reported fans a wired host could not reach while a laptop could [VERIFIED: HA#123828]. | Timeouts while the app works. | As P1. | — | — | `Status` adds "(the app may still reach it through the cloud; check that the controller can reach 10.0.2.151)". |
| N9 | Which identity | — | `mac` and `clientId` on generations 1 to 3, `staMac` on 4. | The key is the station MAC as 12 uppercase hex digits; the client id is stored as well. Names, addresses and models are only shown. Home Assistant keys its devices on the MAC in the same way [VERIFIED: HA `config_flow.py`, `entity.py`]. | — | Keying on `deviceName`, the address or `fanType`. | `Fan ID` "MF_00005E005301 (MAC 00:00:5e:00:53:01)". |
| N10 | First contact (no identity stored yet) | — | The first answer at the typed address. | Nothing is sent until an address is entered. The first answer is learned: identity, generation, model, capabilities. `Status` names the fan as the app does, so a wrong address shows at once. | — | Learning from anything but the owner's typed address. | `Status` "Learned the fan 'Example Room' (generation 3, MAC 00:00:5e:00:53:01) at 10.0.2.151". |

## 2. Power and reachability

| # | Case | What the fan does | What the driver sees | Automatic | Offered (a click) | Forbidden without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1 | Power cut: the pull tab, the breaker, a plain switch or relay in the feed, a power failure | Motor, light, Wi-Fi and HTTP all stop [ASSUMED]. | Timeouts. | One failure shows nothing and is retried. After 3 failures at least 30 s apart [proposal] the fan is offline: `Status` says so, Online goes false where the proxy has it, and the last state stays, marked not current (Q1). Polls back off 10, 20, 40, then 60 s. `Attention` after 24 h, as for lamps in the Hue repo [proposal]. | — | Reporting "off" by guesswork (Q1); queueing commands for later (P8). | `Status` "Fan not answering at 10.0.2.151 since 14:02; showing its last state (power off at the wall?)". |
| P2 | Power comes back | Boots and rejoins Wi-Fi (how long it takes is unknown). It then comes up in an undocumented state: its last one, off, or with the light on [ASSUMED; check 3]. | Answers again. | Identity first (static data), then the state is reported as a change wherever it differs from what Control4 shows; events fire once. `After Power Returns` (Q2) defaults to reporting what the fan does. | — | Re-sending the last Control4 state unless the owner chose that in Q2. | `Status` back to normal; `Last Change By` "back after 3 min (power or Wi-Fi); state as the fan came up". |
| P3 | Wi-Fi drops while the fan has power | Runs on; the remotes work; it rejoins by itself or not [ASSUMED]. | Exactly as P1. | As P1. The driver cannot tell P1 from P3, which is why Q1's default keeps the last state. | — | — | As P1. |
| P4 | Network answers, HTTP does not (a stuck Wi-Fi module) | Reported: timeouts or refusals while ping answers; freezes under polling until the power is cut; a wrong reported state on generation 4 [VERIFIED reports: HA-forum, HA#149019, AIO#287]. | Timeouts or refusals; in the worst case a wrong answer the driver cannot detect. | As P1, keeping one request in flight with backoff (rule 6). Answer times are kept in `Last Seen`, and rising ones are logged. | `Reboot Fan` (the fan's reboot command), also as a programming command so the owner can schedule one in Control4 if his fan needs it. It is useless when HTTP is dead: then only the power helps, and the manual says so. | Rebooting on its own, or on a timer the driver sets itself. | `Status` "Fan not answering at 10.0.2.151 since 14:02 (if the network still reaches it, its Wi-Fi module may be stuck: Reboot Fan, or switch it off at the wall for 10 s)". |
| P5 | Slow answers (seconds) | Reported: 9 s at times, 0.2 to 0.4 s normally [VERIFIED: HA-forum]. | Late answers. | 5 s timeout per request [proposal; AIO's default, VERIFIED: AIO `const.py`]. A retry waits for the next poll and never runs alongside another request. Commands that arrive meanwhile coalesce (S8). | — | Parallel retries. | `Last Seen` "14:02:10 (4.8 s)". |
| P6 | Fan reboots (`Reboot Fan`, the app, a firmware update) | The reboot drops the connection [VERIFIED: AIO `modernforms.py` `reboot`]. Motor and light probably keep their state, since a separate motor controller drives them (`mainMcuFirmwareVersion`) [ASSUMED; check 10]. | The request times out, then a minute or two of silence. | After its own reboot command, up to 2 min of silence counts as rebooting, not offline. Identity and firmware are read again afterwards; a new firmware is F1. | — | — | `Status` "Rebooting the fan's network module (sent 14:02)…", then normal. |
| P7 | Others poll the same fan: the app open on a phone, Home Assistant, the stock driver left running during the move | A user reported the app's polling plus an integration's freezing the module [VERIFIED: HA#149019]. | Slower answers and timeouts. | Nothing the driver can see; backoff. Whether a second Control4 device for the same fan can be detected and refused is the Control4 side's. | — | — | The manual's move procedure ([`edge-cases-control4.md`](edge-cases-control4.md)) removes the stock driver before the new one polls, and says: one controller, and one Control4 device, per fan. |
| P8 | A Control4 command while the fan is offline | — | No answer. | Tried once (which doubles as a reachability check, as in [`edge-cases-control4.md`](edge-cases-control4.md) P3), then dropped; nothing is queued. The proxy keeps the last known state; logged. | — | Replaying the command when the fan returns: a fan that starts by itself an hour later is worse than one that did not start. | Log "Fan not answering: speed 3 not sent". |
| P9 | A late answer to a request the driver gave up on | — | An answer after its timeout, possibly after newer ones. | Every request carries a sequence number, and answers to abandoned requests are dropped. This is one cause of out-of-order reports (S7). | — | Applying it. | — |
| P10 | An answer with an empty or broken body | AIO retries empty answers up to 3 times [VERIFIED: AIO `modernforms.py`]. | No usable state. | Counted as a failed request, never as state; repeated, it is handled like offline. | — | Reading defaults into it. | `Status` "Fan at 10.0.2.151 answers with empty data". |

## 3. The hardware: replaced, reset, other models

| # | Case | What the fan does | What the driver sees | Automatic | Offered (a click) | Forbidden without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- | --- |
| H1 | Fan or its receiver replaced (same room) | A new MAC, client id and app name; no remotes paired; no schedule [ASSUMED]. | The old address goes silent (N1), or the new fan answers there (N3). | As N1 or N3; nothing is sent to the new fan. | `Use Selected Fan`: stores the new identity, model, firmware and capabilities. It keeps the Control4 device, its bindings, keypad links and programming (rule 3), then reports the first state. | Adopting by name, model or address; a delete and re-add in Composer. | `Last Action` "Now using the fan MAC 00:00:5e:00:53:02 (was 00:00:5e:00:53:01); bindings and programming kept. Pair its remote and wall control, set it up in the app". H3 runs next. |
| H2 | Replaced by another generation (a generation 4 fan where a 3 was) | `/mf` answers 404; `/device` answers [VERIFIED: HA#169247]. | N4, then the `/device` probe. | Recognised by the probe. If v1 supports generation 4 (Q6), `Use Selected Fan` works as in H1. | `Use Selected Fan` (only if Q6). | Driving it through the generation 1 to 3 interface. | `Status` "The fan at 10.0.2.151 is a generation 4 fan, which this driver version does not control". |
| H3 | Capabilities differ after H1, H2 or F1 | Light kit present or not, Breeze present or not, timer style, colour temperature. | Static and state data. | Detected again at every reconnection and logged when changed. A part that disappears follows H4. | — | Removing or hiding Control4 devices. | `Fan Model` "generation 3 · fan <fanType> · light <lightType> · Breeze"; `Attention` when a part Control4 uses disappears: "The fan reports no light kit since 10-27; the light device stays and does nothing". |
| H4 | Fan without a light kit | `lightType` empty [VERIFIED: HA `light.py`, WAC-2021]. Whether the light fields are then missing or still sent is not settled: the mock fan drops them, while the vendor's generation 3 example sends them with an empty `lightType` [ASSUMED either way]. | — | The light is "not present", decided by `lightType` and not by whether `lightOn` exists. Its commands are refused and logged, and its state is unknown. How the light device looks is decided in [`edge-cases-control4.md`](edge-cases-control4.md). | — | Inventing a light state. | Light `Status` "This fan reports no light kit". |
| H5 | Light kit added or removed later (some fans ship without one [VERIFIED: Lowes]) | Whether `lightType` follows the kit or is a factory setting is unknown [ASSUMED]. | Maybe a `lightType` change. | H3. | — | — | As H3. |
| H6 | Generation 4 fan with two lights (uplight and downlight, each with level and colour temperature) | [VERIFIED: AIO#287, MF-2026] | Two light fixtures. | Q6. | — | — | Q6. |
| H7 | Fewer speeds | All Modern Forms smart fans have 6 speeds [VERIFIED: MF-2026; AIO ranges]. | A speed outside 1 to 6 in an answer. | Logged once; shown clamped [proposal]. | — | Sending a speed outside 1 to 6. | — |
| H8 | UV-C ("Ultra") fan | Exists; generation 3 reports `isUvcFan` [VERIFIED: UVC, AIO#272]; how its UV-C module is switched is unknown [ASSUMED]. | `isUvcFan` true. | v1 switches no UV-C function, and the fan and light behave as `lightType` says. | — | Switching UV-C from Control4 (safety) without its own contract. | `Status` "UV-C functions are not controlled by this driver". |
| H9 | Two fans | One remote may run both, and app groups switch both [VERIFIED: MF-rc, MF-2026, MF-app]. | Each fan reports its own changes. | Nothing special; N3 when their addresses cross; one Control4 device per fan (P7). | — | — | — |
| H10 | Factory reset (remote 10 s, receiver button, app, cloud) | Forgets Wi-Fi, app, remotes and cloud registration, and goes back to its access point [VERIFIED: AIO `factory_reset`, MF-rc, MF-store 1.4.17]. After set-up in the app: the same MAC [ASSUMED], maybe a new address and name; schedule, away mode and adaptive learning probably cleared [ASSUMED]. | Offline (P1), then the same identity, maybe elsewhere (N1). | Resumes when the identity matches; `Fan Name` refreshed; automations audited again (§5). A changed name or account suggests a reset; `FrCodes` might record reset reasons (the app shows them since 1.4.19 [VERIFIED: MF-store]) [ASSUMED]. | — | — | `Attention` "The fan answered again after 2 days and its app name changed to 'Fan' (was it reset? pair its remote and wall control again)". |
| H11 | Remote or wall control added, replaced or unpaired | Pairing needs a power cycle at the breaker and a 3-minute window [VERIFIED: MF-rc, MF-wci]; generations 1 to 3 report no list of paired controls [ASSUMED]. | Only the power cycle (P1, P2). | As P1, P2. | — | Clearing pairings (§9). | — |

## 4. Firmware

| # | Case | What the fan does | What the driver sees | Automatic | Offered (a click) | Forbidden without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F1 | Firmware updated (from the app, or in access-point mode) | Reboots (P6); `firmwareVersion` and `mainMcuFirmwareVersion` change [VERIFIED: the fields, AIO]. | Silence, then a new version in the static data. | Identity checked; version stored with its date; capabilities detected again (H3); logged. Nothing else while everything still parses. | — | — | `Firmware` "02.00.0050 / MCU 03.00.0000 (since 10-27; was 02.00.0043)". |
| F2 | New fields appear | Generation 3 already sends undocumented fields [VERIFIED: AIO#272]. | Unknown keys. | Ignored. `Diagnostics` lists unknown field names, never their values. | `Diagnostics`. | Acting on an unknown field. | — |
| F3 | A needed field disappears or changes type (`fanDirection` is a string on generations 1 to 3 and a boolean on 4 [VERIFIED: AIO `gen4.py`]) | — | A missing or odd field. | That part becomes "not available": its commands are refused with a `Status` line, the rest keeps working, logged once. AIO fills missing fields with defaults, such as speed 6 and brightness 100 [VERIFIED: AIO `models.py`]; this driver does not (rule 5). | — | Defaults for missing fields. | `Status` "Fan firmware 02.00.0050 reports no fanSpeed; speed control paused". `Attention` at once. |
| F4 | The interface moves (`/mf` gone, a new endpoint, HTTPS only) | WAC promises licensees 3 months' notice of incompatible changes [VERIFIED: WAC-lic §7.1]; this project is not a licensee (Q7). | N4. | As N4 and H2. | — | Guessing a new interface. | `Status` "The fan no longer answers on /mf (firmware …); this driver version cannot control it; nothing is sent". |
| F5 | A field changes meaning between generations | Wi-Fi strength as a percentage or as dBm; timers absolute or relative [VERIFIED: AIO `models.py`, `modernforms.py`]. | — | Generation-specific fields are read only after the generation is known; the Wi-Fi strength is shown raw, with its unit [proposal]. | — | — | `Diagnostics` "Wi-Fi -62 dBm". |
| F6 | An update while Control4 sends commands | — | Failures (P8), then F1. | P8, F1. | — | Starting or scheduling firmware updates; writing `firmwareUrl` [field VERIFIED: AIO]. | — |

## 5. State changed by something other than Control4

The driver sees each of these at its next poll. On generation 3,
`userData` names the source [VERIFIED values: WAC-2021]; generations 1
and 2 seem to lack it, since their example has none [ASSUMED]. The
driver's own commands probably arrive as `local_wifi` too [ASSUMED]; the
driver knows what it sent. None of these is ever "corrected" by
re-sending state (rule 7).

| # | Case | What the fan does | What the driver sees | Automatic | Offered (a click) | Forbidden without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | Remote or wall control | Changes state; a held button steps through the speeds [VERIFIED: MF-rc]. | The changed fields; possibly intermediate speeds. | Each observed state is reported as a change, so events fire and keypad LEDs follow. `Last Change By` reads "remote or wall control" for `ble` [ASSUMED: that Bluetooth controls report `ble`, and what RF controls report; check 4]. | — | Putting the fan back to Control4's last command. | `Last Change By` "remote or wall control (14:05)". |
| A2 | The app on the home network | Commands the fan directly [VERIFIED: MF-faq]; `local_wifi`. | Changes. | Reported. | — | — | `Last Change By` "Modern Forms app or another local client". |
| A3 | The app away from home, Alexa, Google Assistant, SmartThings, app groups, sharing | Through WAC's cloud [VERIFIED: MF-app]; `cloud`. | Changes. | Reported. | — | — | `Last Change By` "Modern Forms cloud (app away from home, a voice assistant or SmartThings)". |
| A4 | A schedule set in the app | The app writes the `schedule` blob, and the fan switches at the set times [VERIFIED: MF-app for the feature; ASSUMED that the fan runs it; `userData` `schedule`]. A blob may hold only disabled events [ASSUMED]. | `schedule` not empty; changes marked `schedule`. | Detected: `Fan Automations` and `Attention` at once. The blob is never logged (Home Assistant redacts it too [VERIFIED: HA `diagnostics.py`]). | `Clear Fan Schedule`: saves the blob in the driver, then writes an empty schedule [ASSUMED: an empty string clears it; check 9]. `Restore Fan Schedule` writes the saved blob back. `Accept Fan Automations` silences the item until the set changes. | Clearing, editing or decoding it on its own; writing any other blob. | `Attention` "The fan has a schedule from the Modern Forms app; it may switch the fan by itself (Clear Fan Schedule, or Accept Fan Automations)"; `Last Action` "Fan schedule cleared and saved; Restore Fan Schedule puts it back". |
| A5 | Away mode | Switches fan and light on and off at random [VERIFIED: MF-app, HA-docs]; `away_mode`. | `awayModeEnabled` true; changes marked `away_mode`. | Detected: `Fan Automations` and `Attention` at once. Every random change is reported (programming sees it). | `Turn Off Away Mode`; `Accept Fan Automations`. | Turning it on or off by itself. | `Attention` "Away mode is on in the Modern Forms app: the fan and its light switch on and off by themselves (Turn Off Away Mode)". |
| A6 | Adaptive learning (generations 1 to 3) | Learns habits and may run the fan by itself [VERIFIED: MF-feat; MF-app calls it recommendations]. It would learn Control4's own use as well [ASSUMED]. | `adaptiveLearning` true. | Detected: `Fan Automations` and `Attention` at once. | `Turn Off Adaptive Learning`; `Accept Fan Automations`. | Changing it by itself. | `Attention` "Adaptive learning is on: the fan may start learned routines by itself (Turn Off Adaptive Learning)". |
| A7 | Sleep timer set in the app (generations 1 to 3) | Switches the fan or the light off at the time [VERIFIED: AIO]; generations 1 and 2 depend on the fan's clock [VERIFIED: HA-docs]. | Timer fields not zero; the off marked `sleep_timer`. On generation 3 the value probably counts down [ASSUMED; check 9]. | Shown in `Fan Automations`. A countdown is not a change event; the off is. | `Clear Fan Timers`. | Setting timers (§9). | `Fan Automations` "light off in 25 min (fan timer)"; `Last Change By` "fan's sleep timer". |
| A8 | Breeze (generation 3 and newer) | Varies the speed by itself [VERIFIED: HA-docs, MF-2026]. What `fanSpeed` reports meanwhile is unknown [ASSUMED: the base speed; check 6]. | `wind` true. | `Fan Model` shows "Breeze on"; the speed is reported as the fan reports it. | — | — | `Status` "Breeze on". |
| A9 | One power button for fan and light (app, Elite remote) | Both off together; "on" restores the last setting [VERIFIED: MF-app, MF-2026]. | Both change in one answer. | Both reported. | — | — | — |
| A10 | Thermostat integrations: ecobee runs the fan with the HVAC and sets the direction from heat or cool; Nest's ended with Works with Nest on 2023-09-29 | [VERIFIED: MF-app, WWN]; ecobee still working [ASSUMED]. | Changes marked `cloud`, including direction. | Reported. The driver cannot see the integration itself. | — | — | `Last Change By` "Modern Forms cloud"; the manual: such links are set, and removed, in the app. |
| A11 | Other local integrations (Home Assistant, Homey, Hubitat) | No authentication: any local client can command the fan [VERIFIED: AIO, no credentials used]. | `local_wifi` changes; load (P7). | Reported. | — | — | As A2. |
| A12 | "The fan starts by itself and won't stay off" (reported with Home Assistant, cause unknown) | [VERIFIED report: HA#144431] | — | The driver never re-sends state by itself, so it cannot be the cause; A4 to A7 and `Last Change By` point at the source. | — | — | `Last Change By`. |

## 6. Commands and state

| # | Case | What the fan does | What the driver sees | Automatic | Offered (a click) | Forbidden without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | Fan off vs speed 0 | No speed 0. Off is `fanOn` false, and `fanSpeed` keeps reporting the last speed while off [VERIFIED: AIO ranges; ST, reported]. | `fanOn` false with a speed. | Control4 shows off whenever `fanOn` is false. The reported speed is kept as the speed the fan resumes at. | — | Sending speed 0. | — |
| S2 | On at a speed | Home Assistant sends `fanOn` and `fanSpeed` together [VERIFIED: HA `fan.py`]. Whether a speed sent while off turns the fan on or only stores the speed is unknown [ASSUMED; check 7]. | One answer. | One request carries both. | — | — | — |
| S3 | Light at level 0; on at a level | No brightness 0. Both fields in one request flash the old level first, so the brightness goes first and `lightOn` second [VERIFIED: AIO#99, `modernforms.py` `light()`, HA#59655]. "On" without a level resumes the fan's own last level [ASSUMED]. Generation 4: level 1 to 10000, applied at once [VERIFIED: AIO `gen4.py`]. | Two answers. | Level 0 means `lightOn` false, with the level kept. On at a level is two requests, in that order. | — | Sending brightness 0. | — |
| S4 | Ramps and held buttons | The interface has no fade or ramp field [VERIFIED: none in AIO]. | — | The final level is sent once. While a button is held, at most one request per 0.5 s [proposal], coalesced (S8). | — | Stepping the level in many requests (rule 6). | — |
| S5 | Direction | `forward` is summer (air down) and `reverse` is winter [VERIFIED: MF-rc]. The remote reverses only while the fan runs [VERIFIED: MF-rc]; whether the interface accepts a reverse while off is unknown [ASSUMED; check 7]. Generation 4 uses a boolean [VERIFIED: AIO]. | The answer. | Sent when Control4 asks; reported as the fan reports. | — | — | — |
| S6 | Colour temperature | Generations 1 to 3 have none in the interface [VERIFIED: AIO drops it for those generations]. Their light kits offer four colour temperatures [VERIFIED: MF-2026], chosen on the fan itself rather than through the interface [ASSUMED]. Generation 4 has `mixColorTemp` with a per-light range [VERIFIED: AIO `gen4.py`]. | — | On generations 1 to 3 the light declares no colour temperature; generation 4 depends on Q6. | — | — | — |
| S7 | A command races a state report (the stock driver's late, out-of-order speed reports) | Fan-side causes: a poll and a command in flight together, with crossing answers; an answer to an abandoned request (P9); a held remote button (A1); the fan's state lagging its motor controller [ASSUMED; check 8]. | Answers in any order, if requests overlap. | One request in flight, commands before polls, answers applied in request order. A command's answer is the state after it. A poll 1 to 2 s after each command confirms it. No settle timer delays anything. | — | Parallel requests to one fan. | Keypad LEDs that follow without the Timer agent. |
| S8 | Keypad or slider bursts | — | — | While one request is in flight, each newer command replaces the queued one field by field, latest wins. A burst becomes one request in flight plus one waiting. The proxy shows the newest target at once (Q5). | — | — | — |
| S9 | A command the fan does not take | It may ignore bad input silently [ASSUMED: the mock fan models it so, AIO-mock]. | The answer differs from the command. | Commands are validated before sending, and the answer is compared with the command. A field that did not take is logged once and the proxy corrected to what the fan reports. | — | Retrying in a loop. | Log "The fan did not take light level 40 (reports 35)". |
| S10 | The driver starts (Director restart, driver update) | — | — | Nothing is sent before the first answer, which is reported ([`edge-cases-control4.md`](edge-cases-control4.md) says how that reaches the proxies). | — | Writing a remembered state at start. | `Status` "Waiting for the fan at 10.0.2.151". |
| S11 | Someone changes the fan in the same second as a command | — | The answer or the next poll differs. | The later observation wins and is reported. | — | — | `Last Change By`. |
| S12 | Rounding (generation 4 levels 1 to 10000) | [VERIFIED: AIO `gen4.py`] | Small differences. | The level the fan reports is shown; small differences are not answered with another command. | — | — | — |
| S13 | Beeps | The receiver beeps when a remote changes the speed [VERIFIED: MF-rc]; generation 3 has `feedbackToneMute` [VERIFIED: AIO#272]; whether network commands beep is unknown [ASSUMED: no]. | — | Nothing. | — | Changing tone settings. | — |

## 7. Cloud, app and vendor

| # | Case | What the fan does | What the driver sees | Automatic | Offered (a click) | Forbidden without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- | --- |
| V1 | Cloud outage or internet down | Local control keeps working [VERIFIED: MF-feat; AIO#287, reported]. The app away from home and voice assistants stop [VERIFIED: MF-faq]. Generation 1 and 2 timers and schedules may drift without NTP [VERIFIED: HA-docs]. | Nothing. | Nothing; the driver never talks to the cloud. | — | — | — |
| V2 | The owner blocks the fan's internet on purpose | As V1. | Nothing. | Nothing. | — | — | The manual: allow NTP (UDP 123) if the fan's own timers matter [VERIFIED: HA-docs]. |
| V3 | App or cloud discontinued | The Modern Forms app was last updated 2025-10-28, and the 2026 Elite fans use MyWAC [VERIFIED: MF-store, MF-2026]. Local control would go on [ASSUMED: it lives in the fan]. What goes: Wi-Fi set-up (manual commissioning exists but WAC does not support it [VERIFIED: WAC-2021]), firmware updates, remote access, voice. | Nothing. | Nothing. | — | — | The manual: keep the fan's Wi-Fi as it is; a router change needs the app. |
| V4 | Fan renamed in the app | `deviceName` changes [VERIFIED: the field, AIO]. | New name. | `Fan Name` refreshed; logged. | — | Renaming the Control4 device. | `Fan Name`. |
| V5 | Account changes, sharing, a new owner | `owner` changes [VERIFIED: the field, AIO]. | — | Nothing; never shown or logged (rule 8). | — | — | — |
| V6 | Private data in answers | The owner's email, AWS identity, certificate id, SSID and BSSID; on generation 4 also the location [VERIFIED: AIO-readme, AIO#287 (its diagnose tool redacts them)]. The time zone is treated as private too [proposal]. | — | Dropped on receipt. `Diagnostics` and the log redact as in rule 8. | — | Showing or logging them. | — |
| V7 | Fan clock and time zone (set by the app [VERIFIED: MF-store 1.4.24]) | — | Timer times. | The driver never sets the fan's time or zone, and never compares the fan's clock with the controller's. | — | Writing time or zone. | — |

## 8. What the driver shows when the fan's state is not known

| Situation | Kind | Fan and light proxies | `Status` | `Attention` |
| --- | --- | --- | --- | --- |
| No address yet | set-up | nothing | "Enter the fan's address in Fan Address" | — |
| Waiting for the first answer after a start | waiting | nothing sent until the first answer | "Waiting for the fan at 10.0.2.151" | — |
| One failed request | transient | unchanged | unchanged | — |
| Not answering (power off, Wi-Fi down, new address, stuck module) | failure | last state kept, marked not current (Q1) | "Fan not answering at 10.0.2.151 since 14:02; showing its last state" | after 24 h |
| Rebooting after `Reboot Fan` | expected | unchanged | "Rebooting the fan's network module…" | — (offline after 2 min) |
| Another fan at the address | identity | last state, not current; commands refused | "10.0.2.151 now answers as another fan (MAC 00:00:5e:00:53:02); nothing is sent" | at once |
| Not a Modern Forms fan, or an interface this version does not drive | identity | as above | "… answers, but not as a Modern Forms fan" / "… is a generation 4 fan, not controlled by this version" | at once |
| A part not available (no light kit, a field gone) | partial | that part has no state and refuses commands; the rest works | "This fan reports no light kit" / "… reports no fanSpeed; speed control paused" | at once |
| The fan's own automations active | informational | normal | normal | at once, until cleared or accepted |

## 9. Not offered in v1, so that nothing automates them

- **Destructive or irreversible commands, never sent:** factory reset
  and hard reset, decommission, clearing remote pairings
  (`resetRfPairList`), firmware updates and `firmwareUrl`, Wi-Fi set-up,
  time and time zone, renaming the fan in the app, tone settings.
- **Opening remote pairing** (`rfPairModeActive`): the app does it;
  pairing also needs the breaker (H11).
- **Setting sleep timers or schedules from Control4.** Control4's own
  timers and programming do that (the north star). The driver only clears
  what the app set, and restores what it cleared.
- **Turning away mode or adaptive learning on.**
- **Breeze on and off, and its strength, as programming commands.**
  Later, after check 6 shows what Breeze does to the reported speed.
- **UV-C functions** (H8).
- **Generation 4 extras:** identify (reported as unreliable [VERIFIED:
  AIO#287]), local automations and natural lighting; generation 4 itself
  only if Q6 says so.
- **Scanning the network on its own** (N1).

## 10. What the driver must persist

| Field | Needed by | Source |
| --- | --- | --- |
| station MAC (the key), client id, generation, learned at | N1 to N10, H1 | static data |
| last good address | N1 | the owner's entry, or passive discovery |
| `fanType`, `lightType`, `fanMotorType`; capabilities (light, Breeze, timer style, colour range) | H3 to H8, S6 | static and state data |
| firmware and motor-controller versions, with the date of change | F1 | static data |
| last state reported to Control4 (fan on, speed, direction; light on, level) | P2, S10, the start comparison | own |
| saved schedule blob and when it was saved (only after `Clear Fan Schedule`) | A4 | the fan |
| `Accept Fan Automations` snapshot | A4 to A6 | own |
| **never:** `owner`, `federatedIdentity`, certificate id, SSID, BSSID, time zone, location | rule 8 | — |

## 11. Questions for the owner (recommended default first)

1. **While the fan does not answer:** **keep its last state, marked not
   current** (as Hue lamps do; the driver cannot tell a power cut from a
   stuck Wi-Fi module while the blades turn, P3, P4), or show it off after
   some minutes, since most silences are a power cut, at the cost of a
   wrong "off" when the fan is in fact running?
2. **When power returns** (`After Power Returns`): **report what the fan
   does** (nothing is re-sent: a fan stopped deliberately with the pull
   tab is not restarted by Control4), or restore the last state Control4
   set, or switch the fan and light off?
3. **Finding the fan** (the Control4 side proposes `Find Fans` and
   `Use Selected Fan`). DriverWorks has no mDNS call, so a list of fans
   needs either the driver's own mDNS query (a multicast `C4:NetConnect`,
   per [`modernforms-api-research.md`](modernforms-api-research.md) §7)
   or a scan that POSTs a read-only query to every address on the
   subnet. **Recommended for v1:** the owner types `Fan Address`, the
   driver pins the identity, and only a changed address of the same
   identity is followed by itself. `Find Fans` comes when the mDNS query
   is built: it lists only, and adoption stays a click. No subnet scan,
   ever on its own. The alternative: a subnet scan behind the `Find Fans`
   click in v1.
4. **Polling:** **every 15 s while idle (Home Assistant's interval), every
   2 s for 20 s after any change, with backoff when the fan fails and a
   `Poll Interval` property of 5 to 120 s**? Or faster for quicker remote
   and app feedback, at the reported risk of freezing the fan's Wi-Fi
   (P4)?
5. **Keypad LEDs and proxies on a Control4 command:** **show the new
   target at once and correct it if the fan answers otherwise** (no
   one-second lag, no Timer agent), or change them only after the fan's
   answer (0.3 s normally, up to seconds when the fan struggles)?
6. **Generations in v1:** **only the house fan's generation and its
   siblings, 1 to 3 on `/mf`** (to confirm by check 1), or also
   generation 4 (`/device` and `/fixture`, two lights with colour
   temperature, the 2026 Elite and MyWAC fans)?
7. **WAC's documents and terms** (a process decision more than a design
   one). The aiomodernforms repository carries two WAC documents: the
   2021 reference cited here as WAC-2021, and a 2026 interface document
   marked confidential, which this file does not use. WAC's API License
   Agreement makes its API documentation confidential and forbids reverse
   engineering (WAC-lic §6.4, §8), which sits badly with a public repository.
   **Recommended:** do not sign up with WAC. Verify every field against the
   public open-source code (AIO, HA) and read-only queries of the house fan
   (check 1), then replace the few WAC-2021 citations with those
   observations. Alternative: become a licensee, which brings notice of
   API changes (§7.1) and the confidentiality duty.

## 12. Checks

Read-only queries of the house fan, any time:

1. **Identify:** the static and dynamic data and `/config-read`. Record
   the generation, the field names present (values reduced to the
   placeholders), whether `userData` exists and the answer times. This
   also settles Q6 and the WAC-2021 facts (Q7).
2. **Wi-Fi strength** from `/config-read`: a weak signal explains
   timeouts better than any setting (P4, P5).

The owner's hands, a minute each:

3. **Power cut:** fan at speed 3, light at 40 %. Pull the wall control's
   tab (or the breaker) for 10 s, restore it, and record when the fan
   answers again and what state it reports. Repeat with the light off
   (P2, Q2).
4. **Remote:** one press and one hold. What `userData` says and how soon
   the change shows (A1).
5. **App:** one change on the home Wi-Fi and one over mobile data, and
   what `userData` says for each (A2, A3).
6. **Breeze** from the remote: does `fanSpeed` move (A8)?

Commands, through the dev loop:

7. **From off:** a speed alone; on and speed together; reverse while
   off; a brightness while the light is off (S2, S3, S5).
8. **Lag:** one speed command, then polls every 0.5 s for 3 s. Does the
   state ever lag or bounce (S7)?
9. **Timers and schedule:** a 2-minute timer set in the app, polled to
   see whether it counts down (A7). An empty schedule compared with one
   whose events are all disabled (A4).
10. **`Reboot Fan`:** do the motor and the light change, and how long
    until the fan answers (P6)?

Hardware facts to collect (not decisions): the fan's model and
generation; how it is powered (a Modern Forms wall control, or any
switch, dimmer, relay or Control4 load in its supply); its remote (RF or
Bluetooth); whether its app has a schedule, away mode or adaptive
learning on; who else polls it (the stock driver, Home Assistant, a
phone with the app open).

Parked, long-running and not blocking a build: a day of answer times at
the chosen interval (Q4); an hour with the fan's internet blocked (V1).
