# Keypad LED rows only with a keypad: what the SDK allows

Research for issue #178, written 2026-11-10. The owner asked that the
keypad LED rows (colours, the Breeze animation, the speed chase) show only
when a configurable keypad is linked to the driver, that the driver say
clearly how it works in either case, that the features be easy to turn off,
and the same for Breeze. This note says what the Control4 SDK documentation,
Snap One's helper library, the sibling Hue project and this driver's code
allow. It is desk research: nothing was sent to any device. The lifecycle
cases (bind, unbind, restore, update) are the sibling note
`docs/edge-cases-keypad-leds-visibility.md`, written at the same time.

**Sources.** SDK files are cited by path under `~/c4-tools/reference/`:
**API** `docs-driverworks-api/source/includes/`, **FUND**
`docs-driverworks-fundamentals/source/includes/`, **XML**
`docs-driverworks-xml/source/includes/`, **KPD**
`docs-driverworks-proxyprotocol-keypad/source/includes/`, **UIB**
`docs-driverworks-proxyprotocol-uibutton/source/includes/`, **LV2**
`docs-driverworks-proxyprotocol-lightv2/source/includes/`. **LIB** is
Snap One's `~/c4-tools/drivers-common-public/` (read only, never vendored).
**HUE** is `~/projects/c4-hue-driver/` (read only). The SDK text is
summarised, never copied. Code is `src/modernforms_fan/` unless named.

**Status key.** **VERIFIED-doc**: the SDK file says so. **VERIFIED-house**:
seen on this house's controller (OS 3.4.x, Composer Pro 3.4.2), naming the
project and check. **VERIFIED-code**: read in the code named. **ASSUMED**:
inferred, with the reason. **SILENT**: the SDK says nothing.

## Short answers

1. **Hiding rows: `C4:SetPropertyAttribs(name, 1)` hides a row of the
   driver's own Properties page, `0` shows it.** Every controller since
   OS 1.6.0 has it, so OS 3.3.0 to 4.x alike; never in `OnDriverInit`.
   The Hue drivers hide and show rows with it on this house today. The SDK
   is silent on persistence, values and repainting: hiding is presentation
   only (the value stays and keeps acting unless the Lua ignores it), the
   state must be sent again at every `OnDriverLateInit` with an explicit
   0 or 1 for every managed row, and it must go out in its own batch a
   moment after any text updates, because Composer drops attribute changes
   that arrive with them (HUE, hardware).
2. **Knowing a keypad is bound: already done.** `OnBindingChanged` and
   `C4:GetBoundConsumerDevices` are documented and in use; `links.lua`
   funnels every change through `bookkeeping_changed`, and
   `pixels_list()` is exactly "the speed links 301 to 306 with something
   bound". The visibility belongs on that hook.
3. **Telling a colour keypad from anything else: not possible by any
   documented means on OS 3.x.** The Button Link page itself says there is
   no API to ask a device what its buttons support, and that some keypads
   have no LEDs. A bound device's driver file can be read
   (`C4:GetDevices`), but no document maps file names to LED hardware, and
   one Control4 keypad can mix buttons with and without LEDs (the house's
   Up button has none). `REQUEST_BUTTON_COLORS` is no signal either: it
   cannot be attributed to a device, and on this house the LED-less Up
   button sent it at every bind too.
4. **Messages:** a read-only row written with `UpdateProperty` (the
   driver's `Keypad Links` summary and `Last Action`), a static `<tooltip>`
   per row, and the Documentation tab. No API changes a tooltip, an action
   or a command at run time.
5. **Easy off:** a property is the Control4-normal place for a lasting
   setting; actions are for setup and show no state. The single master
   off already exists: `Speed LED Colors` = `Keypad's own` stops the
   per-speed colours and both animations (VERIFIED-code).

**Recommendation to build on:** gate the LED rows on "something is bound
to a Fan Speed link" (`links:pixels_list()` not empty), the Breeze rows
also on "the fan has Breeze" (`breeze:has_breeze()`), and the dependent
rows on their parent's value; apply them with `SetPropertyAttribs` from
one function called at late init, on `bookkeeping_changed` and on the
relevant `OnPropertyChanged`, sent as a batch 400 ms after the texts and
again at 1.5 s, as the Hue bridge does. Keep `Keypad Links` always shown as
the explanation. Do not try to classify keypads.

## 1. Hiding rows

| # | Fact | Source | Status |
| --- | --- | --- | --- |
| H1 | `C4:SetPropertyAttribs(strName, int)` displays or hides one of the driver's own properties on Composer's Properties page; added in OS 1.6.0. The parameter table names only the property; the integer is shown only by an example, where 1 keeps the row from being displayed. | API `24_properties/_4-SetPropertyAttribs.md` | VERIFIED-doc |
| H2 | 0 shows the row again. | LIB `global/handlers.lua` `SetPropertyVisible` (sends 0 for visible, 1 for hidden); HUE `src/hue_bridge/bridge/rows.lua` `row_visible`, used for the `Last Action (2)` to `(6)` rows, shown and hidden on the house since build 247 (HUE `docs/status.md`) | VERIFIED-house (HUE); SILENT in the API page |
| H3 | Not in `OnDriverInit`: the page says so, and both safe-usage tables mark it "NO" before `OnDriverLateInit`. | API `24_properties/_4`; API `22_miscellaneous/_25.2-SafeUsageTable.md`; FUND `28_api_specific_info/_2-DRIVERINIT.md` | VERIFIED-doc |
| H4 | OS 3.x: works on this house's OS 3.4.x. The Hue Scene driver hides `Recall As` on time-based scenes and the bridge hides unused `Last Action` rows, both seen on the house; the Hue motion driver does the same for an area's sensor rows (code). OS 4.x: the API page lists no OS-specific behaviour. | API `24_properties/_4`; HUE `src/hue_scene/driver.lua` `apply_recall_as`, `src/hue_motion/driver.lua` `apply_rows_visibility`, `docs/status.md` ("Recall As hidden") | VERIFIED-house on 3.4.x; ASSUMED the same on 4.x (no doc says otherwise; never tried) |
| H5 | No XML way to hide a property: a `<property>` takes name, type, readonly, tooltip, default, minimum, maximum, items and multiselect. `<hidden>` exists only for connections. | XML `20_properties/` (file list), `50_connections_xml/_60-hidden.md` | VERIFIED-doc |
| H6 | No API hides, renames or adds an action or a programming command at run time; the property calls are the only visibility control. So `Add Breeze Fan` and the Breeze commands stay listed whatever is hidden. | API `24_properties/` (the whole section: `Properties`, `GetProjectProperty`, `OnPropertyChanged`, `SetPropertyAttribs`, `UpdateProperty`, `UpdatePropertyList`); FUND `15_composerpro_interface_into_the_sdk/_6-ACTIONS.md`; HUE `docs/simplify-research-composer.md` (searched, none) | VERIFIED-doc by absence |
| H7 | A hidden row keeps its value. The SDK does not say. Property values in general persist (dynamic list items are the documented exception), and the Hue bridge writes text to a hidden continuation row and shows it 400 ms later with that text. | FUND `15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md` (list items are not persisted, which it contrasts with most other properties); HUE `rows.lua` lines 35 to 42 | SILENT; VERIFIED-house (HUE) for a text written while hidden |
| H8 | `OnPropertyChanged` fires only when the user changes a value on the Properties page, never for `UpdateProperty`. A hidden row has no control to change, so it should never fire from Composer. | API `24_properties/_3-OnPropertyChanged.md` | VERIFIED-doc for the rule; ASSUMED for hidden rows |
| H9 | A hidden row still acts. Director never calls `OnPropertyChanged` at start (the SDK's own init example loops over `Properties` itself), and this driver replays every value at late init (`dispatch.replay_properties(Properties)`) and reads `Properties["Speed LED Colors"]`, `["Breeze LED Animation"]` and the rest whatever is shown. Hiding is not turning off. | API `22_miscellaneous/_25-OnDriverInit.md` (example); `driver.lua` `OnDriverLateInit`, the LED configure functions (lines 748, 821 to 846) | VERIFIED-doc; VERIFIED-code |
| H10 | Across a Director restart or a driver update, whether the hidden state is kept: SILENT. Snap One's library keeps the state only in a Lua global (empty at each load) and hides rows from `OnDriverLateInit`; the Hue drivers apply theirs at every late init. A driver update keeps the configuration and restores properties after a load. | LIB `global/handlers.lua` (`PropertyVisibility`), `global/msp.lua` (`OnDriverLateInit`: every row but Driver Version hidden on a too-old OS); HUE `apply_recall_as` ("shown or hidden again at every late init"); FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` | SILENT; ASSUMED not kept, so re-applied every time |
| H11 | Composer and timing: Composer dropped a show (Hue build 243) and a hide (build 245) that arrived in the same burst as the rows' text updates, and once showed `Last Action (3)` without `(2)` when both appeared together. Since then the bridge sends the visibility of every managed row as one batch 400 ms after the texts and once more at 1.5 s, which has held. Whether the open Properties page repaints without re-selecting the device is not recorded. | HUE `rows.lua` lines 35 to 42; HUE commits `580a3e2`, `b2c57ae` (#68); HUE `docs/smart-scenes-research.md` section (b) (the question, unanswered) | VERIFIED-house (HUE) for the drops and the fix; SILENT on the repaint |
| H12 | Control4's own guidance for the light_v2 Extras pages (Navigators, not Composer) is to hide an object when the hardware or the feature is not available, and to hide rather than remove. | FUND `27_proxy_specific_info/_51-LIGHTV2EXTRAS.md` | VERIFIED-doc for Extras; applying it to Composer rows is an analogy |
| H13 | The test runtime already models it: `c4:SetPropertyAttribs(name, attribs)` records the call and keeps `c4.property_attribs[name]`. | `tests/helpers/fake_c4.lua` (the properties block); `tests/spec/fake_harness_spec.lua` | VERIFIED-code |

**What this means for the build.**

- Nothing in `driver.xml` changes for hiding; no `<capabilities>` change,
  so no "Restart Director?" and no reboot (FUND `14_.../_2`: properties
  may be added; connections and proxies untouched). Tooltips (section 4)
  are a property change only.
- Look the call up and protect it, as the Hue drivers do
  (`if C4.SetPropertyAttribs then pcall(...)`), so a runtime without it
  only skips it and a failure can never stop late init.
- Send an explicit 0 or 1 for **every** managed row at every late init.
  If the hidden state did persist (H10), a row a later build no longer
  hides would otherwise stay hidden.
- Send the visibility after any `UpdateProperty`, `UpdatePropertyList` or
  `Last Action` text of the same moment, as one batch 400 ms later and
  again at 1.5 s (H11); the second send is cheap and covers a drop. Cancel
  the timer in `OnDriverDestroyed` (a HUE review found such a row timer
  calling `SetPropertyAttribs` after a dev-loop reload, #376, HUE
  `docs/dev-loop.md`).
- Decide in Lua, not in Composer, whether a hidden row acts (H9). For the
  rows in question it does not matter: both animations are inert without
  bound speed links and without `Per speed` (`breezeleds.lua` line 336
  needs `per_speed` and at least one pixel; `speedleds.lua` `why_not`
  needs `Per speed` and at least two bound speed buttons), and a hidden
  colour row only colours links nobody is bound to.

## 2. Knowing a keypad is bound

| # | Fact | Source | Status |
| --- | --- | --- | --- |
| B1 | `OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)` is called when one of the driver's bindings is bound or unbound (from 2.9.0). A protocol driver gets it for control bindings only, not AV or room bindings. A second page of the same name says 1.6.0 and opens with an unrelated sentence. | API `9_helper/_12-OnBindingChanged.md`; API `22_miscellaneous/_23-OnBindingChanged.md` | VERIFIED-doc |
| B2 | The thirteen links are control connections (`<type>1</type>`, `<consumer>False</consumer>`, class `BUTTON_LINK`), so B1 applies. | `driver.xml` connections 200 to 202, 300 to 308, 311; FUND `11_connections/_1-OVERVIEW.md` (control bindings 1 to 999) | VERIFIED-code; VERIFIED-doc |
| B3 | `C4:GetBoundConsumerDevices(deviceId, bindingId)` lists the consumers of one of this device's provider bindings: nil when none, else `{ [id] = name }`; 0 means this device; not in `OnDriverInit`; from 1.6.0. | API `32_serial_network_device/_3-GetBoundConsumerDevices.md` | VERIFIED-doc |
| B4 | On this house the value in B3's table is the consumer driver's `<name>`, not its Composer name; `C4:GetDeviceDisplayName(id)` gives the Composer name. A binding with nothing bound answers nil, and right after a start a bound one may answer nil once, so one nil is "unknown" and a second nil 5 s later "none". | HUE `docs/design.md`, "Project APIs: verified on hardware" and "Hardware facts of the 2026-10-25 dev pass"; API `32_serial_network_device/_6-GetDeviceDisplayName.md` | VERIFIED-house (HUE) |
| B5 | On this house a bind made by a drag in Connections reaches the driver at once, and the keypad sends `REQUEST_BUTTON_COLORS` on that link 3 to 4 ms after every bind, from the LED-less Up button (K4) as from Medium (K6); an unbind that leaves another button of the same keypad on the link is handled (#92). | `fan/links.lua` header comment; [`v1-design.md`](v1-design.md) section 11.1, rows K4 and K6; `docs/status.md` (#92) | VERIFIED-house (this project) |
| B6 | Whether `OnBindingChanged` fires at Director start for bindings that already exist, and whether it fires when a bound keypad is deleted from the project. | API `9_helper/_12` (nothing on either); [`edge-cases-control4.md`](edge-cases-control4.md) C15, H12 (parked) | SILENT |
| B7 | What the driver does today: `late_init` reads all thirteen links, reads the ones that answered nil once more 5 s later; `binding_changed` merges the event with Director's table per keypad and button; `reread_later` and `look_again` settle the rest. Every path ends in `bookkeeping_changed`, which calls `publish` (the `Keypad Links` row) and `send_pixels` (the bound speed links, `pixels_list()`, handed to the animations through `ledhub`). `OnBindingChanged` is wrapped by `dev.binding_changed`, so an early call waits for late init. | `fan/links.lua` (`late_init`, `look_again`, `binding_changed`, `reread_later`, `bookkeeping_changed`, `pixels_list`, `send_pixels`); `driver.lua` `OnBindingChanged`, `OnDriverLateInit` | VERIFIED-code |

**So:** "a keypad is bound to a fan speed link" is `#links:pixels_list() >
0`, already kept current from every source above; "anything bound
anywhere" is `links:debug().bound > 0`. A new optional callback on
`links.new` (called from `bookkeeping_changed` with the same lists), or a
check in the existing `pixels` callback's caller in `driver.lua`, is
enough to drive the rows. The only window where it is wrong is B6: until
the 5 s second look, a link Director answered nil for once counts as not
bound, so a row may appear a few seconds after a restart; and a deleted
keypad may leave its rows shown until the next start if no unbind event
comes (SILENT, harmless: shown rows do nothing without a binding).

## 3. Telling a colour keypad from other consumers

**What can bind.** Composer pairs a provider with consumer connections of
the same class (ASSUMED from the docs' structure: the class name is what
Composer's Connections area shows and what `OnBindingChanged` reports,
XML `50_connections_xml/_75-classname.md`; seen on the house, where the
keypad's inputs list the driver's links under "BUTTON_LINK Output
Devices", `www/documentation.html` chapter 5). The Button Link page
says `BUTTON_LINK` is how Control4 keypads and drivers that expose
physical or virtual keypad buttons talk to other drivers, that it assumes
every keypad's buttons and LEDs work alike, that some non-Control4 keypads
have no LEDs, that some drivers fake release or colour handling for that
reason, and that no API lets a driver ask the hardware what it supports
(KPD `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`,
VERIFIED-doc). `BUTTON_LINK` appears in no other SDK file. Navigator and
touch-screen buttons are the UI Button proxy, a proxy of its own with
class `UIBUTTON`, not a Button Link (UIB
`103_ui_button_proxy_overview/_1-UIBUTTONPROXYOVERVIEW.md`): VERIFIED-doc
by absence that they do not bind here. Remotes: SILENT. This driver's
manual names keypads and a Switch V2 or Essential Switch set to "Use as 2
Button Keypad" (`www/documentation.html`, chapter 5); which of those have
colour LEDs is not in the SDK (ASSUMED from product knowledge only).

**Within one keypad.** The house keypad's **Up** button has no LED while
its other buttons do ([`v1-design.md`](v1-design.md) section 11, "The test
button", VERIFIED-house). Knowing the device is a colour keypad would not
tell whether the bound button has an LED, and the button a link names
(`otherBindingID`) has no documented relation to a position or a button
id ([`edge-cases-breeze-leds.md`](edge-cases-breeze-leds.md) LF7).

**Every candidate signal, on OS 3.x:**

| Signal | Call | OS | What it can tell | Verdict |
| --- | --- | --- | --- | --- |
| A consumer is bound | `GetBoundConsumerDevices`, `OnBindingChanged` (section 2) | 1.6.0, 2.9.0 | something is bound to this link | **Use it.** Documented, current, already kept |
| The consumer's driver file | `C4:GetDevices({ DeviceIds = "456" })` returns `driverFileName`, the room, and a `protocol` or `proxies` sub-table naming the other files (the dimmer example shows `keypad_proxy.c4i` beside `combo_dimmer.c4i`); on the house the filter must be a comma-separated string | 2.10.0 | which driver the bound id belongs to | Possible, not for gating: no document lists which files are keypads with colour LEDs, the keypad proxy page says it does not support configurable multi-row keypads while another keypad page mentions Control4 configurable keypads, and an allow-list of file names would be our guess, wrong for every model we never saw. Whether the link reports the proxy or the protocol id is not recorded. API `22_miscellaneous/_9-GetDevices.md`; KPD `60_keypad_proxy_commands/_1-OVERVIEW.md`, `_9-SETTRACKPREVBUTTON.md`; HUE `docs/design.md` (string filter) |
| The consumer's driver name | the value in `GetBoundConsumerDevices`' table (B4) | 1.6.0 | the driver's `<name>` | Same limits as the file name |
| Devices of a given file | `C4:GetDevicesByC4iName(name)` | 1.6.0 | membership | Same limits. API `25_proxy/_4-GetDevicesByC4iName.md` |
| The consumer's variables | `C4:GetDeviceVariables(id)` | 2.8.0 | every variable of that device | The keypad proxy documents no variables, so nothing to test against. API `22_miscellaneous/_12-GetDeviceVariables.md`; KPD (no variables section) |
| The consumer's device data | `C4:GetDeviceData(id, tag)` | 2.10.0 | the first two levels of its `<devicedata>` | The only keypad capability documented is `clear_led_current_color_support` (3.4.2), which says nothing about colour LEDs; `has_leds` is a light_v2 capability for a light's own buttons. API `22_miscellaneous/_8-GetDeviceData.md`; KPD `61.1_keypad_capabilities/_1-clearledcurrentcolorsupport.md`; LV2 `5_light_v2_capabilities/_28-HASLEDS.md` |
| `REQUEST_BUTTON_COLORS` arrives | `ReceivedFromProxy(idBinding, strCommand, tParams)` on the link | 1.6.0 | something on this link asked for colours | **Not LED-only:** the house's Up button, which has no LED, sent it at every bind (B5, VERIFIED-house). Not attributable either (no sender in the callback, so two keypads on a link are one), and seen only right after a bind, not at a Director start or a keypad reboot. API `25_proxy/_5-ReceivedFromProxy.md`; KPD `62/_1` (drivers may fake colour handling) |
| Another device's capability or config | `C4:GetCapabilityById`, `C4:GetDriverConfigInfoById`, `C4:GetProtocolDeviceById`, `C4:GetBoundPartner` | 4.0.0, 4.2.0, 4.0.0, 4.0.0 | a capability or root tag of another device | Not on OS 3.x, and still nothing documented to read. API `9_helper/_5.6-GETCAPABILITYBYID.md`, `22_miscellaneous/_7.5-GetDriverConfigInfoById.md`, `9_helper/_8.5-GETPROTOCOLDEVICEBYID.md`, `9_helper/_5.8-GETBOUNDPARTNER.md` |
| This driver's own file | `C4:GetDriverFileName()` | 3.3.0 | this driver only (no parameter) | Not about the consumer. API `22_miscellaneous/_13.5-GetDriverFileName.md` |

**Recommendation.** The most reliable signal that works on OS 3.x is the
binding itself: "a consumer is bound to Fan Speed 1 to 6" for the speed
LED and animation rows. It is documented, it is what the LED code acts on,
and it errs safely: a keypad without colour LEDs shows rows whose defaults
(`Keypad's own`, `Off`) do nothing. Word the rows and the manual as "shown
once a keypad button is bound to a Fan Speed link", not "a configurable
keypad". If the owner wants the keypad's model named, `GetDevices` can add
it to the `Keypad Links` line or the log (U5 first), never to a gate.

**Which row on which condition** (input for the contract, not decided
here; every input is something the driver already knows):

| Rows | Shown while | Known from |
| --- | --- | --- |
| `Keypad Links` | always (it is the explanation) | — |
| `Speed N Link Also Lit At` | link 30N bound (or: any speed link bound) | `links.consumers` / `pixels_list()` |
| `Speed LED Colors` | any speed link bound | `pixels_list()` |
| `Speed 1..6 LED Color`, `Speed LED Off Color` | the above and `Per speed` | the property |
| `Speed LED Animation` | the above | the property |
| `Speed LED Rest (s)` | the above and not `Off` | the property |
| `Breeze LED Animation` | any speed link bound, `Per speed`, the fan has Breeze | `breeze:has_breeze()` (`fan/breeze.lua`) |
| `Breeze LED Step (ms)`, `Breeze LED Night Brightness (%)` | the above and `Gusts` | the property |
| `Breeze LED Bottom` | `Gusts` or a speed chase on: the chase reads it too | `driver.lua` lines 826 and 845 |

`Breeze LED Bottom` is shared: hiding it with the Breeze rows alone would
hide the chase's orientation. A fan whose Breeze is not known yet (no
first answer) should count as "has Breeze" for showing, so the rows do not
flicker at every start; that is the sibling note's case to settle.

## 4. Messages instead of rows

| Way | What it is | Changes at run time | Source | Fit |
| --- | --- | --- | --- | --- |
| A read-only STRING row | "Provides a read only string"; written with `C4:UpdateProperty` after late init | yes | FUND `15_composerpro_interface_into_the_sdk/_1-PROPERTIES.md`; XML `20_properties/_25-readonly.md`; API `24_properties/_5-UpdateProperty.md` | The driver's `Last Action` is one: one line when the rows appear or disappear ("Keypad LED settings shown: a button is bound to Fan Speed 2") |
| A DYNAMIC_LIST row | summary on the row, every item in the drop-down; items not persisted, rebuilt at init | yes | FUND `15_.../_2-DYNAMICLISTPROPERTIES.md`; API `24_properties/_6-UpdatePropertyList.md` | `Keypad Links` already is one; its summary can carry the hint while nothing is bound (for example "0 of 13 links bound; LED settings appear when a speed button is bound"). Composer shows about 75 characters of a value and clips the rest (HUE `docs/design.md`, "Superseded (2026-10-24, #121 and #68)", VERIFIED-house) |
| `<tooltip>` | hover text on one property in Composer | no (no API) | XML `20_properties/_30-tooltip.md` | Static instructions on each LED row ("only acts with Per speed"); the Hue drivers use it; this driver has none today |
| The Documentation tab | `<documentation file="www/...">`, shown under the device's Documentation tab | no (shipped with the driver) | XML `15_common_xml/_70-documentation.md`; FUND `26_markdown_driver_documentation/_0-Header.md` | The full "with a keypad / without one / how to turn it off" text belongs in chapter 5 of `www/documentation.html` |
| An action | a button on the Actions tab for setup work | no; shows no state | FUND `15_.../_6-ACTIONS.md` | Not for messages |
| The log | `print`, `C4:ErrorLog` | — | API `9_helper/_14-print.md`, `13_log/_2-Errorlog.md` | Not seen by a dealer in normal use |

`<description>` appears in one Fundamentals example of a STRING property
but is not one of the documented property elements (XML `20_properties/`):
SILENT on what Composer does with it; do not rely on it. `Status` is the
fan's state (`texts.status`) and should not carry keypad hints.

## 5. Easy off

A property is the Control4-normal place for a setting that lasts: the
property types are list, ranged numbers, string, password, device
selector, colour selector, dynamic list and link, with no separate toggle
(FUND `15_.../_1-PROPERTIES.md`), so an on/off is a LIST, as `Breeze LED
Animation` and `Speed LED Animation` already are. Actions are for
installation and setup and hold no state the dealer can read (FUND
`15_.../_6-ACTIONS.md`); a "Turn LED Effects Off" action would leave no
trace of what is set. A programming command could switch an animation
from a schedule, but that is a feature nobody asked for (XML
`35_commands_xml/`). The single master off exists already: `Speed LED
Colors` = `Keypad's own` sends no colours and stops both animations,
whatever they are set to (`breezeleds.lua` line 336 needs `per_speed`;
`speedleds.lua` `why_not` answers "Speed LED Colors is not Per speed"). With the rows of section 3
hidden under it, turning that one row back is "everything off" and the
other values wait, unchanged, for the next `Per speed`.

## What could not be verified

Each is a short read or click; none blocks a build, because the
recommended design behaves correctly either way.

- **U1. Hidden state across restarts and updates** (H10). SILENT.
  Mitigated by sending every managed row's 0 or 1 at every late init.
  Check: hide a row, restart Director, read the page before the driver's
  late init could act (not practical) or, simpler, ship and observe that
  the page is right after the first restart.
- **U2. Repaint without re-selecting the device** (H11). The Windows
  session reads the Properties page right after a bind in Connections, then
  after selecting another device and coming back.
- **U3. A hidden row's value** (H7). Expected kept (HUE evidence); read a
  row's value after hiding and showing it.
- **U4. OS 4.x and date-versioned Composer** (H4). Not tried; the API page
  gives no version limits beyond 1.6.0.
- **U5. What the house keypad reports.** Which id a link names (keypad
  proxy or protocol), and what `GetDevices` and the binding table say for
  it (file names, driver `<name>`): a dev-loop read of the ids `Keypad
  Links` lists, informational only.
- **U6. Binding events at start and on a deleted keypad** (B6). SILENT;
  parked as [`edge-cases-control4.md`](edge-cases-control4.md) H12. The
  design tolerates both.
- **U7. Tooltips on Composer Pro 3.4.2.** Documented and used by the Hue
  drivers; not recorded as seen on this house.
