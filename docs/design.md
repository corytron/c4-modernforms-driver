# Design notes

The engineering notebook of the two drivers: how they are built today, the
reasons, and where each decision is specified. What runs on the house and
what is open is [`status.md`](status.md); where this notebook and
`status.md` disagree about the present, `status.md` and the code win. The
full specification is in the contracts: [`v1-design.md`](v1-design.md) for
the driver as a whole, and one `*-design.md` per later feature
([`README.md`](README.md) lists them).

This notebook was opened on 2026-10-27 as a list of questions for the v1
research ([issue #2](https://github.com/corytron/c4-modernforms-driver/issues/2)).
The research and the owner's decisions ([#6](https://github.com/corytron/c4-modernforms-driver/issues/6))
answered them; each section now opens with what the code does, marks with
"Since 1.N (#NNN)" what a later release changed, and ends with the
questions it was opened with, as they were asked.

## Method

**Status key.** **[verified]** = checked in a primary source, named at the
claim; **[verified on hardware]** = observed on the author's house, with the
date and the build; **[measured]** = seen on the house but in no SDK
document; **[assumed]** = not yet confirmed, to be tested on the controller
or the fan. What counts as a primary source:

- **Control4:** Snap One's DriverWorks documentation, cloned under
  `~/c4-tools/reference/` (API, Fundamentals, XML, the general proxy
  protocol and the fan, keypad, `light_v2` and uibutton proxy references).
  A claim names the file by its path below that folder, for example
  `docs-driverworks-proxyprotocol-fan/source/includes/43_fan_capabilities/_4.5-proxyfanspeedconnections.md`;
  it is never quoted, since the repository is public and the text is Snap
  One's. Snap One's public drivers count for how an API behaves in practice,
  marked as such.
- **Modern Forms:** a field, command or range is verified by the source of
  the public `aiomodernforms` library or of Home Assistant's `modern_forms`
  integration (file and version named), or by a read-only query of a fan
  (date, model and firmware named, the answer reduced to the placeholders
  of `scaffold-design.md`, section 2). A field nobody has verified is not
  used. WAC publishes a reference of the fan's local interface itself, under
  its API License Agreement, which treats that documentation as
  confidential. The project stays off that agreement (decided 2026-10-27,
  #6, [`status.md`](status.md#decided-not-open)): the reference is cited at
  most as corroboration, by page, and nothing of it, or of anything else of
  the maker's, is copied.
- **The house:** a measurement on the controller (OS 3.4.3, Composer Pro
  3.4.2) through the dev loop ([`dev-loop.md`](dev-loop.md)) or the Windows
  session ([`composer-remote.md`](composer-remote.md)), with the date and
  the build; hardware findings also go into the issue as comments.

**Dated history.** Contracts, research notes and edge-case notes keep what
was decided when; a later change adds a short "Since 1.N (#NNN)" note
beside the old text and never rewrites it. This notebook and `status.md`
are kept true for the present instead.

**How the work gets done** (process, not architecture): every change that
can be split into parts touching disjoint files is built by parallel agents
against a contract written first, with one coordinator integrating, testing
and committing (`CLAUDE.md`, "Working with agents"); anything that acts on
its own over the life of the system starts with its lifecycle edge cases
and a decision per case (automatic, offered, or never without a click).
Testing on the controller goes through the dev loop, so a change can be
pushed, reloaded and exercised on hardware without Composer; what only
Composer can show goes to the Windows session.

## Targets

- **Controller.** OS 3.4.3 at the house, managed with Composer Pro 3.4.2;
  the drivers must also work on OS 4.x and with the date-versioned Composer
  Pro releases, so they use documented APIs and nothing that is 4.x-only.
  One measured departure: since 1.9 (#207) the ambient connection's class
  `AMBIENT_LEVEL` and its command `AMBIENT_LIGHT_LEVEL` are in no SDK
  document **[measured, 2026-11-12, OS 3.4.3, a C4-KD120 keypad dimmer:
  [`ambient-pause-design.md`](ambient-pause-design.md) section 0]**;
  unbound, it changes nothing. OS 4.x has not been tried.
- **Minimum OS: 3.3.0**, declared as `minimum_os_version` in both
  `driver.xml` files and checked at run time by the fan driver (Status
  `Controller OS … is older than 3.3.0; the light may misbehave`). See
  [Minimum OS](#minimum-os) below.
- **Lua.** With `jit="1"` on its `<script>` element each driver is loaded by
  LuaJIT, which follows the Lua 5.1 language standard **[verified:
  `docs-driverworks-fundamentals/source/includes/7_driverworks_and_luajit/_1-OS3LUAJIT.md`;
  the attribute in
  `docs-driverworks-xml/source/includes/15_common_xml/_71-script.md`]**.
  No Lua 5.2+ features, no C modules, no `require` of anything not packaged
  in the driver; the specs run under `lua5.1` against the fake DriverWorks
  runtime (`tests/helpers/fake_c4.lua`).
- **The fan.** Modern Forms Gen 1 to 3 fans with six speeds, through their
  local interface: JSON POSTs to `http://<fan>/mf`, the way `aiomodernforms`
  and Home Assistant's `modern_forms` integration use it **[verified:
  [`modernforms-api-research.md`](modernforms-api-research.md)]**. A Gen 4
  fan (a different protocol) is refused with a clear Status. Control4 keeps
  working when the vendor's cloud is down: nothing depends on it.
- **Keypads.** Every Button Link the driver declares works in both
  directions: a press reaches the fan or the light, and the bound button's
  LED follows the state. That was the reason for the project (the next
  section).

## The stock driver on the house (2026-10-27)

**[verified on hardware, 2026-10-27: a hands-on test on the house, OS
3.4.3, Composer Pro 3.4.2]** The fan ran on the stock driver
`wac_mf_fan_and_light_controller(v4).c4z`, which declares 12 BUTTON_LINK
connections: Fan Off, Fan Speed 1 to 6, Toggle Preset and Cycle Speed for
the fan, and Top, Bottom and Light Toggle for the light. Keypad buttons bind
to them normally, and nothing happens in either direction: a press reaches
neither the fan nor the light (the driver handles no button commands), and
the driver sends no LED state back (no `MATCH_LED_STATE`), so a button on
Follow Connection never shows their state. A driver can declare links it
does not implement; that is a bug of that driver, not a Composer limit
([`composer-remote.md`](composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag)).

The house worked around it with Control4 programming: scripts on the
keypad's button events that set the speeds, LED scripts with the buttons'
LED Behavior on Programmed, and a one-second one-shot Timer agent,
restarted on every "Fan Speed Changed" event, that let the stock driver's
late and out-of-order speed reports settle before the LEDs were set. The v1
driver had to make all of it unnecessary: links that act and light by
themselves, and state reports that arrive in order.

Since 1.0 (the cutover of 2026-11-04, deploy issue #30) the stock device,
its LED scripts and the settle timer are gone from the house
([`migration-design.md`](migration-design.md), [`status.md`](status.md)).

## Driver structure

**Two packages.**

- **Modern Forms Fan** (`src/modernforms_fan/`, `modernforms_fan.c4z`): one
  device per fan with two proxies, the `fan` proxy on binding 5001 (declared
  first and primary, so it is the parent item with every property, action
  and the Documentation tab) and a `light_v2` proxy on binding 5002 (V1,
  probes K2 and K4). Its connections: the light's Button Links 200 to 202,
  the fan's 300 to 308 and, since 1.2 (#111), 311 Fan Breeze; 400 `Breeze
  Switch`, a provider binding of class `MODERNFORMS_BREEZE` (since 1.2);
  and since 1.9 (#207) 500 `Ambient Light Level (Follower)`, a consumer of
  class `AMBIENT_LEVEL`. The multicast DNS search runs on the dynamic
  network binding 6001.
- **Modern Forms Breeze Fan** (`src/modernforms_breeze_fan/`,
  `modernforms_breeze_fan.c4z`), since 1.3 (#121): a second fan device per
  Breeze fan for the Navigators, one `fan` proxy with three speeds Breeze 1
  to 3, three properties (`Driver Version`, `Status`, `Debug Mode`) and no
  actions, commands or events of its own. It never talks to the fan: its
  consumer binding 1 is bound to the fan device's 400, and the two drivers
  speak with `C4:SendToDevice` (`MF_BREEZE_SET`, `MF_BREEZE_TOGGLE`,
  `MF_BREEZE_CYCLE`, `MF_BREEZE_HELLO` to the fan device, `MF_BREEZE_STATE`
  back). It is added only by the fan's action Add Breeze Fan. It is a new
  package because an installed device cannot change its proxy type: 1.2's
  Breeze switch (`modernforms_breeze.c4z`, a `light_v2` on/off) is no longer
  shipped ([`breeze-design.md`](breeze-design.md#11-13-ornithopter-fan-mode-breeze-mode-and-the-breeze-fan-121)).

**The fan driver's modules** (`src/modernforms_fan/fan/`; `driver.lua`
builds them, hands each what touches Director as arguments, and wires the
entry points, properties, actions and events; the layout is
[`v1-design.md`](v1-design.md#91-layout-and-routing), section 9):

| Module | What it does | Since |
| --- | --- | --- |
| `wire.lua` | request bodies from an allow-list and answers reduced to the fields used, pure | 1.0 |
| `transport.lua` | the one-request-in-flight HTTP slot over `C4:url` | 1.0 |
| `model.lua` | the state model, the scheduler (polls, backoff) and the phases | 1.0 |
| `fanproxy.lua` | the fan proxy: commands to wanted fields, settled reports to the proxy | 1.0 |
| `links.lua` | the ten fan links (300 to 308, 311), their LEDs, and `Keypad Links` for all thirteen | 1.0 |
| `light.lua` | the light on `light_v2`, over `common/device.lua`'s keypad machine; fades since 1.5 (#141), Min On since 1.8 (#195) | 1.0 |
| `texts.lua` | every string the owner can read | 1.0 |
| `names.lua`, `rename.lua` | the product name from the model code, and naming the two items after it | 1.0 (#37) |
| `discovery.lua` | the multicast DNS question and the parser of its answers | 1.0 |
| `follow.lua` | following the pinned fan to a new address | 1.0 (#39) |
| `search.lua`, `found.lua` | when the driver searches by itself, and the list of fans heard | 1.2 (#102) |
| `breeze.lua` | Breeze as Control4 sees it: commands, variable, events, condition, link 311, the Breeze fan | 1.2 (#111), 1.3 (#121) |
| `mode.lua` | the three states of one motor: stopped, fan mode, Breeze mode | 1.3 (#121) |
| `breezeleds.lua`, `sun.lua` | the Breeze animation on the speed links, and night at the project's location | 1.4 (#137) |
| `speedleds.lua`, `ledhub.lua` | the speed chase, and the one owner of the speed links between the two engines | 1.6 (#159) |
| `ledrows.lua` | showing the keypad LED rows only while a speed link is bound | 1.7 (#178) |
| `ambient.lua` | whether the bound keypad's LEDs are dark | 1.9 (#207) |
| `devcmds.lua` | the signed development commands, in `--dev` builds only | 1.0 |

`src/common/` is the owner's own Apache-2.0 code shared with the Hue
project: `dispatch.lua` (the entry points), `log.lua`, `device.lua` (the
`light_v2` plumbing and the keypad press machine, measured on this house
with the Hue drivers) and `devloop.lua` (`--dev` builds only).

**Adding a fan.** By the address the owner types in `Fan Address`, or by a
pick in `Found Fans`. The first answer pins the fan's identity (client id
and MAC, `Fan ID`); a different fan at that address is refused until Use
Selected Fan accepts it. Gen 4 and anything that is not a fan are refused.
Since 1.2 (#102) `Found Fans` fills by itself and a pick takes that fan at
once (a different fan on a pinned device waits for Use Selected Fan); the
Find Fans action is gone.

The questions of 2026-10-27, answered in
[`light-structure-research.md`](light-structure-research.md) and
[`edge-cases-modernforms.md`](edge-cases-modernforms.md):

- One driver with a fan proxy and a `light_v2` proxy (the scaffold's
  default, `scaffold-design.md` section 1), or two drivers; what Composer
  shows for each, and what OS 3.x and 4.x support.
- How a fan is added (by its address; discovery if the research finds a
  way) and how it is identified (its MAC address or client id), so that a
  new address is followed and not taken for a new fan.

## Transport

The local `POST /mf` JSON interface of Gen 1–3 fans, with no authentication
and no push ([`modernforms-api-research.md`](modernforms-api-research.md),
[`v1-design.md`](v1-design.md#3-transport) section 3). A fan's Wi-Fi module
freezes under load, so `fan/transport.lua` keeps **one request in flight**
per fan, 250 ms between the end of one and the start of the next, a 5 s
limit on the whole transfer (3 s to connect), and no retry of its own; the
model decides what follows. The fan pushes nothing, so the model **polls**:
every `Poll Interval (s)` (15 by default, 10 to 120), every 2 s for 20 s
after a change, with backoff (10, 20, 40, 60 s) while the fan does not
answer; three failures in a row are offline. A command's own answer is
authoritative. The fan's static data is read again every 6 hours.
Authentication and encryption: the fan has neither (no key, no TLS), so
anyone on the LAN can command it as the driver does; the threat model that
follows from it is settled in
[`SECURITY.md`](../SECURITY.md#the-threat-model).

The questions of 2026-10-27:

- What the fan's local interface offers: how state is read, which commands
  exist, their field names, types and ranges (fan on and speed, direction,
  light on and brightness, and whatever else the fan reports), each
  verified as the method above says.
- Which DriverWorks API carries the requests (for example `C4:url` for an
  HTTP POST), with which timeouts and how many in flight at once, each
  verified in the API reference.
- How a change made in the Modern Forms app, with the remote or at the wall
  control reaches the driver: whether the fan announces anything by itself,
  or the driver has to ask, and how often the fan tolerates being asked.
- Authentication and encryption: none assumed; what the research finds
  rewrites the threat model (answered: none exist, and the threat model is
  settled in [`SECURITY.md`](../SECURITY.md#the-threat-model)).

## State model

`fan/model.lua` keeps per field a confirmed value (the last the fan
reported), a wanted value (what Control4 asked for) and what is in flight,
with sequence numbers, a settle window (a read that contradicts a
just-answered command is held 2.5 s), coalescing of a fast series of
presses, and the report rules R1 to R9
([`v1-design.md`](v1-design.md#45-settled-reports-r1r9),
[`edge-cases-control4.md`](edge-cases-control4.md#51-the-report-contract)):
the proxies hear a value only when it differs from the last one sent,
nothing before the first contact, and never a late or out-of-order report.
The phases are not set up, waiting, online, offline, rebooting, another fan,
Gen 4 and not a fan; offline keeps the last state on show, with the events
Fan Offline and Fan Online. What survives a restart (the pin, the fan's
static data, the online flag, Breeze, the preset, the names the driver
wrote) is in [`v1-design.md`](v1-design.md#8-persistence-and-restore),
section 8; the fan's state is never persisted.

- **Since 1.3 (#121):** one motor, three states (`fan/mode.lua`): stopped,
  fan mode, and Breeze mode (`fanOn` and `wind` both true). The fan device
  shows fan mode only; a speed, On, Toggle or Cycle on it ends Breeze, and
  Off stops the motor.

The questions of 2026-10-27:

- The one state the driver keeps per fan (fan on and speed, direction,
  light on and level) and where each value comes from: the fan's own
  reports, or a command the driver sent and the fan has not yet confirmed.
- How the driver never shows a late or out-of-order report, the stock
  driver's failing: ordering, coalescing a fast series of presses, and what
  wins when a report and a command cross.
- The fan offline (a wall switch that cuts its power), an address change, a
  firmware change, and a fan replaced or reset: what the driver sees of
  each, and what it shows in Composer.

## Fan proxy and speed links

The fan proxy declares six discrete speeds named Level 1 to Level 6, a
preset (3 by default, settable) and reverse. The driver tells it
`CURRENT_SPEED` (0 when off) and `DIRECTION`, never `ON` or `OFF`: ON moves
the proxy's speed to the preset **[verified on hardware, K8, 2026-10-27]**.
`proxy_fan_speed_connections` (OS 3.4.2) is not declared: the driver
declares its own Button Links for Off, Speed 1 to 6, Toggle and Cycle
(300 to 308), and since 1.2 (#111) Fan Breeze (311)
([`fan-proxy-research.md`](fan-proxy-research.md),
[`v1-design.md`](v1-design.md#5-links-and-keypad-leds) section 5).

A keypad tap is `DO_PUSH` then `DO_CLICK` 0.15 to 0.25 s later; a hold is
`DO_PUSH` then `DO_RELEASE`; a double tap is two tap pairs and no message
of its own **[verified on hardware, K6 and K7, 2026-11-04]**. So `DO_PUSH`
acts at once, a `DO_CLICK` acts only when no push came on that link in the
last 10 s, a hold is one action, and a double tap acts twice (the keypad's
own Double Tap event still fires, which the house's programming uses).

- **Since 1.0 (#31, V27):** `Speed LED Colors` = Per speed sends each speed
  link the colour of the speed it is lit at; `Speed N Link Also Lit At`
  (V26) keeps a link lit at one more speed.
- **Since 1.1 (#77):** Fan Cycle stops at Level 6, as the fan's own Cycle
  Speed Up does.
- **Since 1.3 (#121):** the speed, Toggle and Cycle links light from fan
  mode and Fan Off only while the fan is stopped; a speed ends Breeze.

The questions of 2026-10-27:

- The fan proxy's capabilities the driver declares (discrete speeds and
  their names, a preset speed, reverse), from the fan proxy reference
  (`docs-driverworks-proxyprotocol-fan/source/includes/43_fan_capabilities/`).
- `proxy_fan_speed_connections`: which Button Link connections the proxy
  then creates by itself, per speed, and which the driver still declares
  (Off, Toggle, Cycle).
- What a bound keypad button sends on each link (`DO_PUSH`, `DO_CLICK`,
  `DO_RELEASE`;
  `docs-driverworks-proxyprotocol-keypad/source/includes/62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`)
  and what the driver does with each: a press sets the speed, and what a
  hold does.
- How the stock driver's 12 connections (ids 0–11, M0) map onto the new
  ones, for the migration contract.

## Light: light_v2

A `light_v2` dimmer without colour, with Top, Bottom and Toggle links (200
to 202) on the shared keypad machine of `common/device.lua` (taps, the
double-tap window, holds, the click guard, Default On Brightness)
([`light-structure-research.md`](light-structure-research.md),
[`v1-design.md`](v1-design.md#47-the-light) section 4.7).

- **Since 1.5 (#141):** the light fades in steps the driver sends, since the
  fan has no fade of its own ([`light-fades-design.md`](light-fades-design.md)).
  A tap fades over the light's Click Rates (the `click_rates` capability, 3 s
  by default; a capability change, so the owner reboots the controller once);
  a second tap stops it; commands without a time use the Default Brightness
  Rate; holds run at the hold rates in finer steps; a rate of 0 or a fade
  under about 1 s is one request. The fan takes one request at a time, so a
  3 s fade is about 7 to 18 steps.
- **Since 1.8 (#195):** `Light Min On (%)` (0 to 99, default 0): Control4's
  1 % becomes that fan level and the rest of the range is spread above it,
  converted only in `fan/light.lua`; levels set outside Control4 are never
  corrected ([`min-on-design.md`](min-on-design.md)).

The questions of 2026-10-27:

- The light's on/off and dimming as the fan reports them (range, steps,
  whether it dims at all on every model), and the `light_v2` capabilities
  that match.
- Top, Bottom and Toggle Button Links as the Hue Light does them (taps,
  holds, the keypad settings the proxy shows), and what of the Hue
  project's shared keypad machine (`src/common/device.lua`) applies as it
  is.

## Keypad LEDs

Each link sends `MATCH_LED_STATE` for its own state and answers
`REQUEST_BUTTON_COLORS`; the pressed target lights at once and is corrected
if the fan disagrees ([`fan-proxy-research.md`](fan-proxy-research.md)).
**[verified on hardware, 2026-10-27]** Making a keypad button's link
switched that button's LED Behavior to Follow Connection by itself, and
disconnecting did not switch it back
([`composer-remote.md`](composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag)).

The animations change colours and lit state only, never brightness, so the
keypad's own Ambient Light Profile dims them with its other LEDs (#198,
[`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md)).
Both need `Speed LED Colors` = Per speed and play only on the bound speed
links 301 to 306; Off, Toggle, Cycle, Fan Breeze and the light's links never
animate.

- **Since 1.4 (#137):** Breeze on the keypad LEDs (`fan/breezeleds.lua`,
  [`breeze-leds-design.md`](breeze-leds-design.md)): with `Breeze LED
  Animation` = Gusts, the speed buttons go dark when Breeze starts, gusts
  (a white head with a twinkling tail of ice, teal and sky) run the way the
  fan blows, and an ending wipe runs the other way once when it ends;
  `Breeze LED Bottom` says which end is at the bottom, `Breeze LED Step (ms)`
  sets the pace, and between sunset and sunrise at the project's location
  (`fan/sun.lua`, no internet) the colours run at `Breeze LED Night
  Brightness (%)`.
- **Since 1.6 (#159):** the speed chase (`fan/speedleds.lua`,
  [`speed-leds-design.md`](speed-leds-design.md)): with `Speed LED
  Animation` = Speeds 2 to 5 or Speeds 1 to 6, a dot in the speed's colour
  runs across the bound speed buttons in the airflow direction, one button
  every 0.5 s at speed 1 down to 0.1 s at speed 6, then a constant rest of
  `Speed LED Rest (s)` with the selected speed lit. `fan/ledhub.lua` gives
  the speed links one owner; Breeze wins. At most 30 messages a second.
  **Since 1.7 (#177):** a run's first chase comes 2.5 s after a speed is
  selected from any source, and the rest defaults to 5 s (10 before).
- **Since 1.7 (#178):** the keypad LED rows (`fan/ledrows.lua`,
  [`keypad-leds-visibility-design.md`](keypad-leds-visibility-design.md))
  show only while at least one device is bound to a speed link 301 to 306:
  they show at once and hide when nothing has been bound for 8 s; the three
  Breeze-only rows also hide on a fan without Breeze. Display only: hidden
  values are kept and still apply. 20 rows then, **21 since 1.9 (#207)**:
  `Speed 1` to `Speed 6 Link Also Lit At`, `Speed LED Colors`, `Speed 1` to
  `Speed 6 LED Color`, `Speed LED Off Color`, the four `Breeze LED` rows,
  `Speed LED Animation`, `Speed LED Rest (s)` and `Pause LED Animations
  Below`.
- **Since 1.9 (#207):** the animations pause while the keypad is dark
  (`fan/ambient.lua`, [`ambient-pause-design.md`](ambient-pause-design.md)).
  A keypad's Ambient Light Level (Source), bound to the fan's Ambient Light
  Level (Follower), sends its reading on change only; below `Pause LED
  Animations Below` (0 to 255, default 10; 0 never pauses) the chase and the
  gusts send nothing, and a new run starts after 10 s of light. The steady
  LEDs still follow the fan. Nothing is persisted or polled: after a restart
  the animations run until the keypad's next reading.

The questions of 2026-10-27:

- What a link must send so that a keypad button on Follow Connection is lit
  exactly while its speed is the fan's speed, and dark otherwise
  (`MATCH_LED_STATE` per link, answering `REQUEST_BUTTON_COLORS`; the keypad
  button-link reference above), and whether the fan proxy sends any of it by
  itself with `proxy_fan_speed_connections`.
- The same for the light's Top, Bottom and Toggle links.

## Breeze

Since 1.2 (#111, [`breeze-design.md`](breeze-design.md)): "Breeze is on"
means the fan blows a breeze, `wind` and `fanOn` both true. Programming has
the commands Breeze On, Breeze Off, Toggle Breeze and Set Breeze Strength
(1, 2 or 3), the variable `Breeze`, the events Breeze Started and Breeze
Stopped and the condition "Breeze is on"; a keypad button binds to Fan
Breeze (311).

- **Since 1.3 (#121):** fan mode and Breeze mode exclude each other on the
  owner's fan. The fan device shows fan mode only; the Breeze fan shows
  Breeze 1 to 3. Breeze Off and Toggle Breeze stop the fan while Breeze
  blows; Breeze On starts a stopped fan straight in Breeze.

## Finding and following the fan

- **The search** (`fan/discovery.lua`): one multicast DNS question for
  `_easylink._tcp.local`, asked twice a second apart, answers collected for
  3 s **[verified on hardware, K10, 2026-10-27]**; only answers on port 80
  with a private or link-local IPv4 address count. Since 1.2 (#102,
  [`auto-discovery-design.md`](auto-discovery-design.md)) the driver asks by
  itself (`fan/search.lua`): at every load and, while the device has no fan
  or no usable address, again after 30 s, 1, 2, 5 and 10 min, then every
  15 min; a device whose fan answers asks only at load, one with a pin and
  an empty `Fan Address` never. It never takes a fan by itself.
- **The follow** (`fan/follow.lua`, #39,
  [`address-follow-design.md`](address-follow-design.md)): once a fan is
  pinned and stops answering at `Fan Address`, the driver asks for the
  pinned MAC on a backing-off schedule, reads at most three announced
  addresses, and moves only when the read shows the same client id and MAC.
  Never a subnet scan, never another fan; a typed address wins until the
  fan answers there; at most three follows an hour; `Follow Address
  Changes` (On) switches it off.
- **Names** (`fan/names.lua`, `fan/rename.lua`, #37,
  [`fan-name-design.md`](fan-name-design.md)): the product name from an
  exact lookup of the fan's `fanType`, shown in `Fan Model`. Use Selected
  Fan renames the two items only while both carry a default name or the
  names the driver gave them; Name Items After Fan renames them whatever
  they are called; nothing renames on its own.

## Minimum OS

3.3.0, decided by the owner with the research's default (#6, V3), for the
`light_v2` brightness target the light uses; the driver's own Button Links
need nothing newer ([`light-structure-research.md`](light-structure-research.md),
[`v1-design.md`](v1-design.md#21-header) section 2.1). It is declared in
both `driver.xml` files and checked at run time. **[verified on hardware,
K9, 2026-11-04]** Composer Pro refuses to add a package whose minimum is
above the controller's OS.

Known when the question was asked **[verified]**:

- `proxy_fan_speed_connections` is documented as available from OS 3.4.2
  on its capability page
  (`docs-driverworks-proxyprotocol-fan/source/includes/43_fan_capabilities/_4.5-proxyfanspeedconnections.md`)
  and as the fan proxy's addition in 3.4.2 in the general proxy reference
  (`docs-driverworks-proxyprotocol/source/includes/3_whats_new/_7-WHATSNEWIN342.md`),
  while the fan reference's own page on what changed in 3.4.2 lists no
  change to the fan proxy
  (`docs-driverworks-proxyprotocol-fan/source/includes/3_whats_new/_7-WhatsNewin342.md`).
  Two pages of three say 3.4.2. The driver does not declare it, so it does
  not set the floor.
- The scaffold declared 3.3.0 as a stand-in, the Hue drivers' minimum (they
  need the `light_v2` colour APIs of 3.3.0); the research kept the value
  for this driver's light.

## Texts

Every string the owner can read (Status, Last Action, the other rows, the
list items) comes from `fan/texts.lua`, pure, so the specs pin every word:
ASCII only, rows under about 70 characters (Composer clips near 75), the
client id and MAC in full only in `Fan ID` and the lines that pin a fan,
another fan named by its last four hex digits
([`v1-design.md`](v1-design.md#7-texts) section 7).
