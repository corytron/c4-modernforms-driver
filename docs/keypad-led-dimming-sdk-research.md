# Keypad LED dimming by ambient light: what a driver can see and do

> **Status (2026-11-13, #213).** Sections 1 and 2 stand. Decision 1 was
> taken the same day, wider than (a): at the owner's word the keypad dimmer
> **and both switches** got Status LED Min Brightness 0, with Max 255, Dark
> Room below 10 and Bright Room above 50 ([`status.md`](status.md), #198).
> The house probe of 2026-11-12 then answered H4 and H5
> ([`ambient-pause-design.md`](ambient-pause-design.md) section 0, #207):
> `GET_AMBIENT_LEVEL` sent by a driver is answered to Composer only (route
> 3.3 fails), while a consumer connection of class `AMBIENT_LEVEL` bound to
> the keypad's Ambient Light Level (Source) output receives the reading in
> `ExecuteCommand` as `AMBIENT_LIGHT_LEVEL` (`GROUP`, `LEVEL`, `TARGET`), on
> change only (route 3.4 works; still undocumented, measured on OS 3.4.3).
> So summary item 4's "no documented route" stays true, but an
> undocumented one exists. 1.9 built decision 2 on it: `Pause LED
> Animations Below` (default 10) pauses both animations while the bound
> keypad reads dark. BL-D28's night halving stays (decision 5).

Research for [issue #198](https://github.com/corytron/c4-modernforms-driver/issues/198), written
2026-11-12. The owner saw the speed chase ([`speed-leds-design.md`](speed-leds-design.md), #159)
still lit at night while the LEDs of the switches beside the keypad had gone "totally dark", and
asked that the chase and the Breeze gusts ([`breeze-leds-design.md`](breeze-leds-design.md), #137)
follow the keypad's LED dimming exactly: dark and stopped while the policy has the LEDs dark, lit
and running again when the room brightens. This note says what the Control4 documents, the SDK,
one published third-party driver, this driver's code and two house measurements allow. It is desk
research: nothing was sent to any device while it was written.

**Sources.** SDK files by path under `~/c4-tools/reference/`: **API**
`docs-driverworks-api/source/includes/`, **FUND** `docs-driverworks-fundamentals/source/includes/`,
**KPD** `docs-driverworks-proxyprotocol-keypad/source/includes/`, **UIB**
`docs-driverworks-proxyprotocol-uibutton/source/includes/`, **LV2**, **PP**, **XML** likewise.
Control4 and third-party documents are numbered **S1** to **S12** in [Sources](#sources). Snap One
and third-party text is summarised, never copied. Earlier notes of this project: **BLS**
[`breeze-leds-sdk-research.md`](breeze-leds-sdk-research.md), **BLF**
[`breeze-leds-field-research.md`](breeze-leds-field-research.md), **BLE**
[`edge-cases-breeze-leds.md`](edge-cases-breeze-leds.md). Placeholders only: "Example Keypad", a
keypad dimmer whose protocol device is 455, light proxy 456 and keypad proxy 457; fan 10.0.2.151,
controller 10.0.2.10, VM 192.0.2.7. No room or device name of the house appears here.

**Status key.** **VERIFIED-doc**: the named document says so. **VERIFIED-code**: read in the named
code (this driver's, or, where said, the published `driver.xml` and manual of a third-party
driver). **MEASURED**: seen on the house: the Windows session's Composer read of 2026-11-12, or
the dev-loop `Dev Vars` read of 2026-11-09 (issue #137). **INFERRED**: follows from the sources,
with the reason. **ASSUMED**: believed without direct evidence. **UNKNOWN**: nothing settles it;
the [open hardware questions](#open-hardware-questions) do.

## Summary

1. **The keypad already dims what the driver paints, and its policy never turns a lit status LED
   off.** On the house the keypad dimmer and the two switches beside it run a Fully Customized
   ambient profile whose **status LED minimum is 13 (dimmer) and 17 (switches) out of 255**, reached
   below an ambient reading of 10; at night the reading is 2 to 3 (MEASURED). Colours the driver
   sends over a Button Link are scaled by that curve: pure blue `0000ff` sent over a link vanished
   at night (MEASURED, 2026-11-09, BL-D20), which a full-strength colour would not do; at Min 13 it
   is about 13 of 255 on one channel (INFERRED, linear scaling). So the chase dot is lit at the
   same minimum as every lit LED on that keypad, the resting speed LED included. Nothing documented
   or measured says a link message escapes or "wakes" the profile (section 2).
2. **"Totally dark" is therefore most likely what the switches show, not their policy:** a button
   whose state is off shows its off colour, often `000000`, and a low-luminance colour such as blue
   is near invisible at 17/255 (INFERRED; H1, H2 settle it in under a minute).
3. **If the owner wants keypad LEDs dark at night, the policy is the keypad's:** setting the
   dimmer's Status LED *Min Brightness* to 0 in Composer makes the keypad darken every status LED
   below its Dark Room threshold, the chase and the gusts included, and bring them back as the room
   brightens, with no driver change (INFERRED from the measured curve and scaling; H8 checks it).
4. **The driver cannot read the dimming state through any documented route:** the keypad and its
   devices expose no ambient or LED-level variable (MEASURED twice), the keypad proxy protocol has
   no brightness message (VERIFIED-doc), and no SDK file mentions ambient light at all. Two
   **undocumented** routes might give the ambient reading: the `GET_AMBIENT_LEVEL` command Composer
   sends (MEASURED in Composer's log), tried through `C4:SendUIRequest`; and a consumer connection
   of class `AMBIENT_LEVEL` bound to the keypad's *Ambient Light Level (Source)* output, as a
   published third-party driver does (VERIFIED-code, third party). Both need a one-minute dev-loop
   test before any design (H4, H5).
5. **Recommended approach:** settle H1, H2 and H4 to H6 first (all under a minute, no shipped
   tooling). Then (a) the owner decides whether the keypad's own policy should reach dark (decision
   1, a Composer setting); and (b) only if a level is readable, the driver **pauses both animations**
   while the bound keypad's reading is below a dark threshold and resumes them, through the existing
   settle path, when it rises; the resting LEDs stay whatever the keypad's policy makes them. If no
   level is readable, the ranked fallback is a programming command pair the dealer drives (section
   5), not a house-only schedule.

## 1. How a Control4 keypad dims its LEDs

### 1.1 What the documents say

| Fact | Source | Marker |
| --- | --- | --- |
| Gen 3 keypads, keypad dimmers, dimmers and switches carry an ambient light sensor that sets backlight and status LED brightness by the room's light. | S1, S2 data sheets; S9 (a third-party driver built on "newer (GEN3)" sensors) | VERIFIED-doc |
| Composer: *Advanced Properties ▸ Ambient Light Profiles* offers preset brightness profiles for the backlight and the LEDs, or *Fully Customized*, where each level is set by hand against the ambient light. *Backlight Color* defaults to black, meaning no backlight. | S3 (help pages for configurable keypads, dimmers, switches); S4 (Composer Pro 3.3 user guide, pp. 160-161, 218-219) | VERIFIED-doc |
| *Sensing Mode*: Independent (own sensor), Source (others use this sensor) or Follower (uses another device's sensor). A Source is made by connecting its *Ambient Light Level (Source)* Control Output to each follower. | S3 (dimmers page); S4 p. 161 | VERIFIED-doc |
| Source and follower sharing arrived in OS 3.2.2 (May 2021). No later release in the history up to OS 4.1 mentions ambient light. | S5 (release history) | VERIFIED-doc |
| No document names the Fully Customized fields, their ranges, the preset names, a dim-to-off floor, a timeout or a wake-on-press. A 2021 forum request for "dark at night, light on any press, fade after a while" suggests Gen 3 has no wake-on-press of its own. | S3, S4 (silent); S10 (forum, snippet) | INFERRED |
| Lux (Snap One's newer line, its own Composer driver) has status and backlight intensities per dark, dim and bright room, a switch for status LEDs in bright rooms, fixed intensities when ambient sensing is off, and disconnects its Ambient Light Level connections when sensing is disabled. Its pages are behind a login. | S6 (search summaries only) | INFERRED |
| Gen 1 and Gen 2 devices: no evidence of a sensor; OS 4.1 is their last build. | S5 (X4 4.1 end-of-life list); S9 ("newer (GEN3)") | INFERRED |
| The SDK says nothing: a full-text search of API, FUND, KPD, UIB, LV2, PP and XML for ambient, lux, backlight brightness, LED level or sensor finds only unrelated hits (a thermostat colour selector; the project's default `BackLight` colour in `C4:GetProjectProperty`, API `24_properties/_2-GetProjectProperty.md`). The keypad proxy's What's New lists no change from OS 3.1 to 3.4.2. | the search, 2026-11-12; KPD `3_whats_new/` | VERIFIED-doc (silent) |

### 1.2 The house (MEASURED, Composer read of 2026-11-12)

| Item | Value |
| --- | --- |
| Devices | The keypad on the fan's speed links: a Keypad Dimmer C4-KD120 (`combo_dimmer.c4i`, its buttons on `keypad_proxy.c4i`). Beside it two switches of the C4-SW120277 family (`switch_gen3.c4i`) used as two-button keypads. Firmware 5.1.1 on all three. |
| Profile | *Ambient Light Profiles* = Fully Customized; Sensing Mode Independent (each device its own sensor); Backlight Color `000000`. |
| Status LED curve | Min Brightness 13 (dimmer) and 17 (switches), Max 255; below *Dark Room* 10 the LEDs sit at Min, above *Bright Room* 50 at Max, ramping between, on an ambient scale of 0 to 255. |
| Backlight curve | Min 0, Max 180, Dark Room below 1, Dim Room below 4, "Off in high brightness" unticked. |
| Presets | Rows 1 to 4 exist, inactive (Off 0, Dim 25, Status Bright 210, Backlight Bright 180; thresholds 2/75 and 1/4). |
| Ambient reading | Shown only inside the customisation editor, fetched by Composer with a command named `GET_AMBIENT_LEVEL` (seen in Composer's log); 2 to 3 in the dark room at night. |
| Absent | No auto-dim timeout, no wake-on-press, no proximity, no LEDs-off level other than the Status Min. |
| Buttons | LED Behavior Follow Connection; on and off colours per button (for example `8000ff` on, `000000` off); `LOCK_COLORS` True (meaning undocumented: no SDK file names it). |

### 1.3 Where it is computed

The profile is a per-device setting and the reading comes from the device's own sensor in
Independent mode, so the device works out its LED level itself: **in firmware, per device**
(INFERRED from S3, S4 and the measured editor). The controller is involved only for sharing a
reading (Source and Follower) and when Composer asks for the reading. One consequence: two devices
side by side read and dim differently; forum users report one unit of a bank reading 94 while the
rest read 0, a sensor reading 255 under tape, and LEDs feeding their own sensor (S10, snippets).

### 1.4 Corrections to earlier notes

- BLE LF19 and BLS section 8 assumed an "active" level for lit LEDs and an "inactive" level for
  dark ones. The measured editor has no such pair: one **status LED curve** over the ambient
  reading and one **backlight curve**. A button looks dark only because its current colour is dark
  (its off colour `000000`), at any level. The driver already keeps `Speed LED Off Color` black and
  never touches it (BL-D5), so nothing it does relied on the wrong model.
- BLS section 8 called the keypad's Ambient Light Level row an input that only takes a level. The
  documents show each device also has an *Ambient Light Level (Source)* **output** (S3, S4); section
  3.4 is about that output.

## 2. Why the chase shows while nearby LEDs look dark

| Candidate | What supports or weakens it | Marker |
| --- | --- | --- |
| **A. Nothing escapes the policy; the switches show off colours or dim hues.** At 2 to 3 every lit status LED is at its Min: 13/255 on the keypad, 17/255 on the switches. The chase dot and the resting speed LED are both lit purple `8000ff` at 13; the switches' buttons, with their loads off at night, show their off colour, black if so set, or a blue that vanishes at that level as `0000ff` did on the keypad. | MEASURED curve and reading; MEASURED blue vanishing (BL-D20); the switches' colours and states not read | INFERRED, most likely; H1, H2 |
| **B. A link message wakes the keypad** to a higher level for a while, as a press might. | No wake setting exists on these devices (MEASURED). The SDK has no wake or brightness message (KPD `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`). On 2026-11-09 pure blue sent over a link was invisible at night, which a full-brightness wake would not give. | UNKNOWN, weak; H1 compares the dot with the resting LED |
| **C. Dimming applies only to idle or resting LEDs**, not to a newly painted one. | Weakened by the same 2026-11-09 probes: colours sent during the night were dimmed (blue invisible), and half white stayed visible beside full white. | INFERRED unlikely |
| **D. The sent colours are full values that override the dim.** | Link messages carry colours and a lit state only, no brightness (KPD 62/_1); the keypad scales them (above). Full values are what BL-D5 chose so the scaling leaves a visible hue. | INFERRED no |
| **E. The animation raises its own keypad's reading.** A lit button near the sensor bar can lift an Independent device's reading (S10; BLF "Sensor feedback"). From 2 to 3 the reading would need to pass 10 before the keypad brightens. | Forum reports only | UNKNOWN; H7 |

## 3. Can a driver learn the keypad's dimming state?

What a driver would need is either the device's current LED level (no route found) or its ambient
reading plus its profile's Dark Room threshold and Min.

| Route | Documented API | Result on the house | OS 3.x / 4.x / models | Marker |
| --- | --- | --- | --- | --- |
| **Variables** read with `C4:GetDeviceVariable` / `C4:GetDeviceVariables`, watched with `C4:RegisterVariableListener` | API `36_variable/_5-GetDeviceVariable.md` (1.6.0), `22_miscellaneous/_12-GetDeviceVariables.md` (2.8.0), `36_variable/_10-RegisterVariableListener.md` (1.6.0; fails if the variable does not exist) | Keypad proxy: no variables. Protocol device: three fault flags and six energy counters (4567 to 4572). Light proxy: state, level, presets and Navigator data (1000, 1001, 1006, 1310, 1311, 6661). Neighbouring switches: the same kinds. None is ambient or LED level. Composer's log showed none either. The Programming view's variable list was not opened. | APIs on every target OS. Gen 3 on 3.4.3: none. 4.x, Lux: UNKNOWN | MEASURED (Dev Vars 2026-11-09; Composer read 2026-11-12) |
| **A message over the Button Link** | KPD 62/_1 lists `DO_PUSH`, `DO_CLICK`, `DO_RELEASE`, `REQUEST_BUTTON_COLORS`, `SET_BUTTON_COLOR` towards the driver and `BUTTON_COLORS`, `MATCH_LED_STATE` from it; the keypad proxy's commands and notifications (KPD `60_keypad_proxy_commands/`, `61_keypad_protocol_notifications/`) carry colours, names, behaviours and online state | Nothing about brightness or light arrives (the driver's debug log names every message, `common/dispatch.lua`) | All OS | VERIFIED-doc (silent) |
| **`GET_AMBIENT_LEVEL`** sent by the driver | Not in any SDK file and not found on the web. Carriers that are documented: `C4:SendUIRequest(id, request, params)` returns the target's XML answer, but is documented for drivers that implement `UIRequest` (API `22_miscellaneous/_36-SendUIRequest.md`, 2.9.0); `C4:SendToDevice` returns nothing (API `32_serial_network_device/_19-SendToDevice.md`, 1.6.0) | Composer sends it and gets the reading; its target device and reply format were not recorded | Whether a driver gets an answer: UNKNOWN on every OS and model | MEASURED (Composer uses it); UNKNOWN (driver); H3, H4 |
| **An `AMBIENT_LEVEL` connection**: a consumer the dealer binds to the keypad's *Ambient Light Level (Source)* output | `C4:AddDynamicBinding(id, "CONTROL", false, name, class, …)` is documented (API `22_miscellaneous/_1-AddDynamicBinding.md`, 1.6.0), and a `driver.xml` connection is ordinary XML; the class `AMBIENT_LEVEL` and its messages are in no SDK file | A third-party driver (S9) declares a consumer "Ambient Light Level (Follower)" and a provider "(Source)", class `AMBIENT_LEVEL`, type 1 (control). Its manual: Gen 3 devices report a level of 0 to 255 over it; since its OS 3.2.2 update it accepts the level as a proxy message or as a command; connected keypads send extra Zigbee reports at times the driver does not control, so it advises few instances; its own Source output can force followers' LED intensity. Its Lua is encrypted, so the message name is unknown. | Gen 3 on OS 3.2.2 and later per S9 (its first release, April 2020, predates 3.2.2, so the connection existed earlier under other names). Lux: Ambient Light Level connections exist (S6, snippet). 4.x: UNKNOWN | VERIFIED-code (third party: `driver.xml`, manual); message UNKNOWN; H5 |
| **Project data**: the profile in `C4:GetDeviceData(id, tag)` or `C4:GetProjectItems(filters)` | API `22_miscellaneous/_8-GetDeviceData.md` (2.10.0; the device's `<devicedata>`, first two XML levels only), `_17-GetProjectItems.md` (1.6.0; the project as XML) | Not tried. Even if present, it gives the thresholds and Min, not the current reading | UNKNOWN | UNKNOWN; H6 |

**Effect of the `AMBIENT_LEVEL` route on the keypad.** Binding its Source output makes it a Source
(S3, S4). A Source keeps using its own sensor, so its own dimming should not change (INFERRED from
the mode's definition); Composer's Sensing Mode would read Source instead of Independent, and the
binding is a manual Connections step per keypad. This is not the route BLE BL70 forbade: BL70 is
about the keypad's **input**, through which a driver would feed the keypad a level and replace its
sensor. Feeding a level, or forcing a Source level as the third-party driver can, stays forbidden:
it overrides the policy instead of following it.

**The threshold.** With a reading in hand, the driver still has to know where "dark" starts. The
profile is per device and unreadable unless H6 finds it, so a contract would need a property for
the reading at and below which the animations pause, defaulting to Control4's measured Dark Room
value of 10 (or the preset's 2), and say so in the documentation.

## 4. Can a driver send LEDs that the keypad then dims by its policy?

Yes, and it already does. Over a Button Link the driver can set only the two colours and the lit
state (KPD 62/_1); there is no brightness field, no "follow the keypad's brightness" mode and no
"do not wake" flag, because nothing needs one: the keypad scales whatever colour it shows by its
status curve (MEASURED, section 2 row A). The driver's own choices on top of that:

- full component values (BL-D5, BL-D20), so the hue survives the scaling, and black off colours,
  so a dark pixel is dark at any level;
- the Breeze gusts halved between sunset and sunrise (BL-D28, `Breeze LED Night Brightness (%)`),
  which at the house's Min 13 gives about 6 of 255 per channel;
- nothing for the chase at night (SL-D15).

A dark result at night therefore comes from the keypad (Min 0) or from the driver not lighting
anything (a pause); a dimmer colour from the driver only lowers the level the policy sets.

## 5. Fallbacks if no level is readable, ranked

All of these are generic settings any dealer could use; none is house-only tooling. None follows
the keypad's sensor, so none meets "exactly as the policy" by itself.

1. **A programming command pair the dealer drives** (`Pause Keypad LED Animations` /
   `Resume Keypad LED Animations`, or one Boolean), from whatever the project knows about darkness:
   the room's lights all off, a bedtime scene, the Scheduler, or a third-party ambient driver's
   Dark Zone event (S9). Documented on every OS (driver.xml `<commands>`, FUND), no Zigbee cost, and
   as exact as the dealer's source. Cost: programming the owner must write.
2. **The project's sunrise and sunset**, already computed on the controller
   ([`sun.lua`](../src/modernforms_fan/fan/sun.lua), BL-D29): an option such as "pause animations at
   night". No setup, but it ignores lamps and curtains: animations would stop in a lit room at 9 pm
   and run in a dark one at noon.
3. **A dark-time schedule property** (from and to hours): handles bedtime better than sunset, but
   adds rows and still ignores the room's light.
4. **A read by the Windows Composer session**: for investigation only (the profile, the reading,
   the switches' colours). Never a shipped mechanism, by the owner's rule against one-off tooling.

## 6. What a driver change would touch (for the contract, if the owner chooses it)

Only to size the work; the contract decides. A pause belongs to the LED hub
([`ledhub.lua`](../src/modernforms_fan/fan/ledhub.lua)): while paused, neither engine holds a
pixel, a running chase or gust ends through its settle path (SL-D11, BL-D8 without the wipe or with
it, to decide), and the links show their truth, which the keypad then dims by its policy. Resume
starts a new chase run (`FIRST_MS`, SL-D19) or the next gust. Only the bound keypads' readings
matter; with several keypads on one link, the rule (pause when all, or any, are dark) is a
decision. No `<capabilities>` change is involved; a `driver.xml` connection or a dynamic binding
takes effect without a controller reboot (the Hue project saw new connections appear on an
ordinary update, HUE `docs/keypad-design.md`, hardware findings of 2026-10-22).

## Open hardware questions

Each takes about a minute; nothing here needs a shipped feature. Dev-loop items run from a `--dev`
build's Dev action or Composer's Lua command window ([`dev-loop.md`](dev-loop.md)); Windows-session
items follow [`composer-remote.md`](composer-remote.md) and are covered by the standing approval. A
report that does not arrive within a minute is parked.

| # | Question | How | Who | Settles |
| --- | --- | --- | --- | --- |
| H1 | At night, is the resting lit speed LED visible, and is the chase dot as bright as it, no brighter? | Fan at speed 3, room dark; watch one rest (5 s) and one chase | owner, 30 s | A versus B |
| H2 | What do the two switches show at night? | Read each button's on and off colours and LED behaviour, and the states of what they follow, at the time of H1 | Windows session, read-only | A ("totally dark" = off colour or blue) |
| H3 | Which device does Composer send `GET_AMBIENT_LEVEL` to, and what comes back? | Open the dimmer's profile editor and copy the log lines of the request and the reply | Windows session, read-only | the target id and reply format for H4 |
| H4 | Does a driver get the reading? | `C4:SendUIRequest(455, "GET_AMBIENT_LEVEL", {})` and the same on 457, log the return; then `C4:SendToDevice(455, "GET_AMBIENT_LEVEL", {})` and watch the log for anything arriving | VM, dev loop | route 3.3 |
| H5 | What arrives on an `AMBIENT_LEVEL` follower binding? | `C4:AddDynamicBinding(500, "CONTROL", false, "Ambient Light Level (Follower)", "AMBIENT_LEVEL", false, false)`; the Windows session binds the dimmer's *Ambient Light Level (Source)* output to it; log every `ReceivedFromProxy` and `ExecuteCommand` for a minute while a lamp is switched on and off; then unbind, `C4:RemoveDynamicBinding(500)` (API `22_miscellaneous/_31-RemoveDynamicBinding.md`) and check Sensing Mode is Independent again | VM, Windows session, owner for the lamp | route 3.4; the report rate (Zigbee cost) |
| H6 | Is the profile in project data? | Log `C4:GetDeviceData(455)` and the keypad's item from `C4:GetProjectItems("DEVICES")`, search for ambient, profile, brightness, threshold; keep the dump on the VM (it is project data) | VM, dev loop | the threshold property |
| H7 | Does the animation lift the keypad's own reading? | At night, read the editor's ambient value with the animation off, then during a chase and a Breeze gust | Windows session, owner starts Breeze | E |
| H8 | With Status Min 0, do the chase and gusts go dark with the rest and come back by themselves? | Only if the owner picks decision 1 (a): set Min to 0 on the dimmer, then look at night and in daylight | Windows session (setting), owner (look) | Summary 3 |
| H9 | The same on OS 4.x and on Lux keypads | No such hardware in the house | parked | 3.3, 3.4 on other targets |

## Decisions for the owner

1. **Where should "dark at night" come from?** (a) *Recommended:* the keypad's own policy: set the
   keypad dimmer's Status LED Min Brightness to 0 (and the switches' too if all should match); every
   status LED, the chase and gusts included, then goes dark below the Dark Room threshold and comes
   back as the room brightens, with no driver change. (b) Keep Min 13 and have the driver pause only
   the animations in the dark; the resting LEDs stay lit at 13, as the policy says. (c) Both.
2. **Should the driver also stop sending while dark** (no messages over the mesh all night)?
   *Recommended:* yes, but only on a reading it can get (H4 or H5), with a pause threshold property
   defaulting to 10 unless H6 finds the profile.
3. **If both routes work, which one?** *Recommended:* the request (`GET_AMBIENT_LEVEL`): no binding
   to make, the keypad stays Independent, and the driver asks only while an animation would play, at
   most about once a minute. The `AMBIENT_LEVEL` binding is the second choice: a manual binding per
   keypad, the keypad becomes a Source, and the device sets the report rate. Either relies on an
   undocumented command or class verified only by the test, which the contract must say.
4. **If neither works:** *Recommended:* the programming command pair (section 5, item 1); sunset
   and sunrise as a second option the owner may want for zero setup.
5. **The Breeze night halving (BL-D28)** stays as it is under any of these (recommended); with
   Min 0 it only matters in the dim band between the thresholds.

## Sources

Control4 and Snap One:
S1 [Wireless Keypad Dimmer data sheet](https://docs.control4.com/docs/product/wireless-keypad-dimmer/data-sheet/english/latest/wireless-keypad-dimmer-data-sheet-rev-b.pdf) ·
S2 [Wireless Keypad Dimmer, Contemporary data sheet](https://docs.control4.com/docs/product/wireless-keypad-dimmer-contemporary/data-sheet/english/latest/wireless-keypad-dimmer-contemporary-data-sheet-rev-a.pdf) ·
S3 Composer help: [configurable keypads](https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/device_settings_for_configurable.htm), [dimmers](https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerhe_userguide/device_settings_for_dimmers.htm), [switches](https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/device_settings_for_switches.htm) (read) ·
S4 [Composer Pro 3.3 User Guide](https://docs.control4.com/docs/product/composer-pro/dealer-user-guide/english/latest) (read, pp. 160-161 and 218-219) ·
S5 [Control4 X4 (OS 4.1) release notes with the release history](https://docs.control4.com/docs/product/control4-software/dealer-release-notes/english/latest/control4-software-release-notes-rev-aw.pdf) (read) ·
S6 Lux: [Configurable Keypad driver](https://help.snapone.com/lux-qs/Content/Lux/Lux%20Configurable%20Keypad%20Driver.htm), [Keypad Dimmer Switch driver](https://help.snapone.com/lux-qs/Content/Lux/Lux%20Keypad%20Dimmer%20Switch%20Driver.htm) (login; search summaries only) ·
S7 [Lux status and backlight LED programming](https://help.snapone.com/lux-qs/Content/KB%20Topics/Lux%20status%20&%20backlight%20LED%20programming.htm) (read: LED priorities; programmed LED states temporary on earlier generations) ·
S8 [Lux Keypad Dimmer Switch spec sheet](https://help.snapone.com/lux-qs/Content/156_24_LuxLighting_SpecSheet_C4-L-KDS.pdf) (read: Zigbee 3.0, backlit buttons; nothing on ambient)

Third party:
S9 [Ambient Light Monitor by Domosapiens](https://drivercentral.io/platforms/control4-drivers/ambient-light-monitor/) (page, manual and `driver.xml` of version 11.0.0 read; Lua encrypted)

C4 Forums (search summaries only; the site refuses automated reading):
S10 [29422 keypad dimmer backlight behavior](https://www.c4forums.com/topic/29422-keypad-dimmer-backlight-behavior/),
[33291 dual load wireless dimmer issue](https://www.c4forums.com/forums/topic/33291-dual-load-wireless-dimmer-issue/),
[24987 ambient light sensor issues](https://www.c4forums.com/topic/24987-ambient-light-sensor-issues/),
[33139 keypad backlight turning on randomly](https://www.c4forums.com/forums/topic/33139-keypad-backlight-turning-on-randomly/),
[37923 backlight and LEDs with any button press in the dark](https://www.c4forums.com/topic/37923-controlling-backlightleds-with-any-button-press-in-the-dark/) ·
S11 [12633 keypad LEDs off at set times](https://www.c4forums.com/forums/topic/12633-anyone-know-how-to-set-the-leds-on-keypads-to-shut-off-at-times/) (a schedule and a night variable as the field's workaround)

This project: S12 the Dev Vars read and the night probes of 2026-11-09 in
[issue #137](https://github.com/corytron/c4-modernforms-driver/issues/137); BL-D20, BL-D28 in
[`breeze-leds-design.md`](breeze-leds-design.md); SL-D15 in [`speed-leds-design.md`](speed-leds-design.md).
