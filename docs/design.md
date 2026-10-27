# Design notes

**Current state:** [`status.md`](status.md) is the one page that says what
runs on the house, what the driver does now and what is open; where this
notebook and `status.md` disagree about the present, `status.md` and the
code win. This file is the engineering history: dated sections stay as
written, and where behaviour changes later a dated "Superseded (date): …"
line says so at that spot, and a "Current (date, build N): …" note marks
where the code has moved on from what a section first recorded.

On 2026-10-27 this is a skeleton: the targets and the method are written;
the sections after "The stock driver on the house" are headings the v1
research ([issue #2](https://github.com/corytron/c4-modernforms-driver/issues/2))
fills, each with the questions it has to answer.

## Method

**Status key.** **[verified]** = checked in a primary source, named at the
claim; **[verified on hardware]** = observed on the author's house, with the
date and the build; **[assumed]** = not yet confirmed, to be tested on the
controller or the fan. What counts as a primary source:

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
  confidential; whether the project accepts the agreement and counts that
  reference as a source is the owner's decision ([`status.md`](status.md),
  "Open"). Until then it is cited at most as corroboration, by page, and
  nothing of it, or of anything else of the maker's, is copied.
- **The house:** a measurement on the controller (OS 3.4.3, Composer Pro
  3.4.2) through the dev loop ([`dev-loop.md`](dev-loop.md)) or the Windows
  session ([`composer-remote.md`](composer-remote.md)), with the date and
  the build; hardware findings also go into the issue as comments.

**Dated sections.** Every section carries the date it was written. A later
finding never rewrites an earlier section in place: it adds a dated
"Superseded" or "Current" line there and its own dated section below.

**How the work gets done** (process, not architecture): every change that
can be split into parts touching disjoint files is built by parallel agents
against a contract written first, with one coordinator integrating, testing
and committing (`CLAUDE.md`, "Working with agents"); anything that acts on
its own over the life of the system starts with its lifecycle edge cases
and a decision per case (automatic, offered, or never without a click).
Testing on the controller goes through the dev loop, so a change can be
pushed, reloaded and exercised on hardware without Composer; what only
Composer can show goes to the Windows session.

## Targets (2026-10-27)

- **Controller.** OS 3.4.3 at the house, managed with Composer Pro 3.4.2;
  the driver must also work on OS 4.x and with the date-versioned Composer
  Pro releases, so it uses documented APIs only and nothing that is
  4.x-only. Which APIs the design needs, and since which OS version each
  exists, is the research's to list.
- **Minimum OS.** `driver.xml` declares a `minimum_os_version`; the
  scaffold's 3.3.0 is a stand-in (`scaffold-design.md`, section 7) until
  the research picks the value and justifies it ("Minimum OS" below).
- **Lua.** With `jit="1"` on its `<script>` element the driver is loaded by
  LuaJIT, which follows the Lua 5.1 language standard **[verified:
  `docs-driverworks-fundamentals/source/includes/7_driverworks_and_luajit/_1-OS3LUAJIT.md`;
  the attribute in
  `docs-driverworks-xml/source/includes/15_common_xml/_71-script.md`]**.
  No Lua 5.2+ features, no C modules, no `require` of anything not packaged
  in the driver; the specs run under `lua5.1` against the fake DriverWorks
  runtime (`tests/helpers/fake_c4.lua`).
- **The fan.** Its local interface: JSON POSTs to `http://<fan>/mf`, the
  way `aiomodernforms` and Home Assistant's `modern_forms` integration use
  it **[assumed until the research]**. Control4 must keep working when the
  vendor's cloud is down, so nothing of the design may depend on it.
- **Keypads.** Every Button Link the driver declares must work in both
  directions: a press reaches the fan or the light, and the bound button's
  LED follows the state. That is the reason for the project (the next
  section).

## The stock driver on the house (2026-10-27)

**[verified on hardware, 2026-10-27: a hands-on test on the house, OS
3.4.3, Composer Pro 3.4.2]** The fan runs on the stock driver
`wac_mf_fan_and_light_controller(v4).c4z`, which declares 13 BUTTON_LINK
connections: Fan Off, Fan Speed 1 to 6, Toggle Preset and Cycle Speed for
the fan, and Top, Bottom and Light Toggle for the light. Keypad buttons bind
to them normally, and nothing happens in either direction: a press reaches
neither the fan nor the light (the driver handles no button commands), and
the driver sends no LED state back (no `MATCH_LED_STATE`), so a button on
Follow Connection never shows their state. A driver can declare links it
does not implement; that is a bug of that driver, not a Composer limit
([`composer-remote.md`](composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag)).

The house works around it with Control4 programming: scripts on the
keypad's button events that set the speeds, LED scripts with the buttons'
LED Behavior on Programmed, and a
one-second one-shot Timer agent, restarted on every "Fan Speed Changed"
event, that lets the stock driver's late and out-of-order speed reports
settle before the LEDs are set (`status.md`). The v1 driver has to make
all of it unnecessary: links that act and light by themselves, and state
reports that arrive in order.

## Transport (open, 2026-10-27)

To be filled by the v1 research. Questions:

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
- Authentication and encryption: none assumed
  ([`SECURITY.md`](../SECURITY.md#the-threat-model-to-be-settled-by-the-v1-research));
  what the research finds rewrites that section.

## Driver structure (open, 2026-10-27)

To be filled by the v1 research. Questions:

- One driver with a fan proxy and a `light_v2` proxy (the scaffold's
  default, `scaffold-design.md` section 1), or two drivers; what Composer
  shows for each, and what OS 3.x and 4.x support.
- How a fan is added (by its address; discovery if the research finds a
  way) and how it is identified (its MAC address or client id), so that a
  new address is followed and not taken for a new fan.

## Fan proxy and speed links (open, 2026-10-27)

To be filled by the v1 research. Questions:

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
- How the stock driver's 13 connections map onto the new ones, for the
  migration contract.

## Light: light_v2 (open, 2026-10-27)

To be filled by the v1 research. Questions:

- The light's on/off and dimming as the fan reports them (range, steps,
  whether it dims at all on every model), and the `light_v2` capabilities
  that match.
- Top, Bottom and Toggle Button Links as the Hue Light does them (taps,
  holds, the keypad settings the proxy shows), and what of the Hue
  project's shared keypad machine (`src/common/device.lua`) applies as it
  is.

## Keypad LEDs (open, 2026-10-27)

To be filled by the v1 research. Questions:

- What a link must send so that a keypad button on Follow Connection is lit
  exactly while its speed is the fan's speed, and dark otherwise
  (`MATCH_LED_STATE` per link, answering `REQUEST_BUTTON_COLORS`; the keypad
  button-link reference above), and whether the fan proxy sends any of it by
  itself with `proxy_fan_speed_connections`.
- The same for the light's Top, Bottom and Toggle links.
- **[verified on hardware, 2026-10-27]** Making a keypad button's link
  switched that button's LED Behavior to Follow Connection by itself, and
  disconnecting did not switch it back
  ([`composer-remote.md`](composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag)).

## State model (open, 2026-10-27)

To be filled by the v1 research. Questions:

- The one state the driver keeps per fan (fan on and speed, direction,
  light on and level) and where each value comes from: the fan's own
  reports, or a command the driver sent and the fan has not yet confirmed.
- How the driver never shows a late or out-of-order report, the stock
  driver's failing: ordering, coalescing a fast series of presses, and what
  wins when a report and a command cross.
- The fan offline (a wall switch that cuts its power), an address change, a
  firmware change, and a fan replaced or reset: what the driver sees of
  each, and what it shows in Composer.

## Minimum OS (open, 2026-10-27)

To be filled by the v1 research. Known so far **[verified]**:

- `proxy_fan_speed_connections` is documented as available from OS 3.4.2
  on its capability page
  (`docs-driverworks-proxyprotocol-fan/source/includes/43_fan_capabilities/_4.5-proxyfanspeedconnections.md`)
  and as the fan proxy's addition in 3.4.2 in the general proxy reference
  (`docs-driverworks-proxyprotocol/source/includes/3_whats_new/_7-WHATSNEWIN342.md`),
  while the fan reference's own page on what changed in 3.4.2 lists no
  change to the fan proxy
  (`docs-driverworks-proxyprotocol-fan/source/includes/3_whats_new/_7-WhatsNewin342.md`).
  Two pages of three say 3.4.2; whether the speed links set the floor is
  the research's to settle, and the house runs 3.4.3 either way.
- The scaffold declares 3.3.0 as a stand-in, the Hue drivers' minimum (they
  need the `light_v2` colour APIs of 3.3.0, which this driver's light may
  not).
