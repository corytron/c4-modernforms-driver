# The keypad's LED dimming and the LED animations: lifecycle edge cases

> **Research (2026-11-12) for [issue #198](https://github.com/corytron/c4-modernforms-driver/issues/198)**,
> read-only: nothing here was tried on the house and nothing is built. The
> owner's request (2026-11-12): "the fan led chase still lights even when the
> LEDS on the switches nearby have gone totally dark due to their dimming
> policy based on ambient light. I'd like the led chase when the fan is on and
> the breeze one too to honor the led dimming policy and act exactly the LED is
> supposed to act based on the policy. so if its totally dark, in this case,
> the chase stops and the leds go dark. if the ambient light comes back up then
> the leds follow the policy and light up and the chase resumes."
> The Control4 side (how a keypad's ambient dimming works, and whether a driver
> can read it) is the sibling note `docs/keypad-led-dimming-sdk-research.md`,
> written at the same time. Where a decision here depends on its answer, the
> row gives the decision for each answer: **(a)** the driver can read the
> keypad's dimming state or level per keypad; **(b)** it can only infer it (the
> sun, a schedule); **(c)** it can do nothing but stop sending changes, so the
> keypad's own policy rules. Where the sibling note and this one differ on a
> Control4 fact, the sibling note wins.
> Placeholders only: keypad "Example Keypad" (device 456), a second keypad
> "Example Keypad 2" (457), switches "Example Switch A" and "B", room "Example
> Room"; fan 10.0.2.151, controller 10.0.2.10.

**The short answer.**

1. **On the house the keypad already does what its policy says.** The
   Windows session's read of 2026-11-12 (HF1 to HF7) shows a profile whose
   Status LEDs never go off: in a dark room every lit LED sits at its minimum,
   13 of 255 on the keypad dimmer and 17 on the two switches. The chase
   dot is a lit LED, so at night it shows at 13 of 255, which is what the policy
   gives a lit LED. The switches beside it look "totally dark" for a reason
   the read does not give (their colours at night were not read, Q2). The
   driver sends colours and lit or dark states and no brightness (DF1, DF3).
   It cannot make an LED dimmer or darker than the keypad's level.
2. **The exact remedy is in the policy, not the driver: set the keypad
   dimmer's Status LED Min Brightness to 0** (E2, DM4). The keypad then goes
   dark from its own sensor, and lights up and shows the chase again when
   the room brightens, which is the owner's sentence word for word. It takes
   one Composer change by the Windows session and can be undone. The
   steady LEDs (the selected speed, Off) go dark at night too, which matches
   "the leds go dark". It is offered, and it waits for the owner's word (Q1).
3. **A driver-side pause is an approximation on this house.** (a) is not
   available here. The devices have no LED-level or ambient variable, and the
   ambient level is read only in Composer's editor (HF5, HF6). Asking the
   keypad for it would be a keypad command by device id, which BL-D1 forbids.
   That leaves (b), the sun the driver already computes (BL-D29), or (c), a
   hook for the owner's programming. Both stop sending at night, which removes
   the traffic: about 6,000 to 8,100 chase messages an hour at the house's
   5 s rest (DM60). Neither follows the room. A lamp-lit room at night loses
   its chase, and the steady LEDs stay at Min 13 (DM66, DM44).
4. **Pause, never imitate.** If the driver pauses, it only stops sending
   animation frames. A frame in flight ends truthfully. The selected speed's
   LED, Off, 311 and the light's LEDs keep following the fan, and the
   keypad applies its own level to them. The following are **forbidden**:
   sending dark or black to stand in for the policy, scaling a colour by the
   room, a driver copy of the keypad's curve, and reading
   `GET_AMBIENT_LEVEL` from the driver (DM5, DM8, DM9, DM47).
5. **When the pause ends, a new run starts.** The chase's first chase comes
   2.5 s later (SL-D19). Breeze goes dark first and then gusts (BL-D19).
   Nothing missed while dark is replayed.
6. **Over a link the decision is per link set, never per keypad.** One
   message reaches every keypad on the link (LF14). If keypads disagree,
   a dark one wins (DM28). Each device has its own sensor, so neighbours can
   disagree (DM6). The keypad's sensor also sees its own lit buttons (DM7).
   Making the keypad a Follower of a switch's sensor is a Composer remedy that
   is offered.
7. **Failure modes.** A source that answered before and goes quiet counts as
   dark. Where no source exists, the animations run as today, because a
   keypad with a constant level is never dark (DM72 to DM74).
8. **What earlier decisions this touches.** BL61 said "Forbidden: the driver
   following the room's light". The owner's request now overrides it, but only
   for pausing. BL63, which allows no brightness in a colour from the room,
   still stands. BL70, which says never to bind the keypad's Ambient Light Level
   input, still stands. BL-D28 (Breeze at half strength at night) stays beside
   the pause. Under (b) the two must be merged into one choice (DM64).

**Decisions:** **AUTOMATIC** (the driver does it by itself), **OFFERED** (a
property, a Status or Last Action line, the manual, or a step in a Windows
session brief), **FORBIDDEN** (not without a click, or not at all where the row
says so). **Markers:** VERIFIED names a primary source (a repository file and
line, an SDK file, a house measurement recorded in a repository); MEASURED is
the Windows session's Composer read of 2026-11-12 as the coordinator relayed
it; ASSUMED has no source and names the question that settles it. Snap One's
documents are paraphrased, never quoted.

| Key | Source |
| --- | --- |
| SPD, BRZ, LNK, HUB, ROWS, SUN | `src/modernforms_fan/fan/speedleds.lua`, `breezeleds.lua`, `links.lua`, `ledhub.lua`, `ledrows.lua`, `sun.lua` (line numbers of the checkout of 2026-11-12) |
| DRV, TXT, MDL, DOC | `src/modernforms_fan/driver.lua`, `src/modernforms_fan/fan/texts.lua`, `src/modernforms_fan/fan/model.lua`, `src/modernforms_fan/www/documentation.html` |
| SLD, SLE, SG | [`speed-leds-design.md`](speed-leds-design.md) (SL-D1 to SL-D19), [`edge-cases-speed-leds.md`](edge-cases-speed-leds.md) (SF, SL rows), [`speed-leds-c4-guidelines.md`](speed-leds-c4-guidelines.md) (SG rows) |
| BLD, BLE, BLS, BLF | [`breeze-leds-design.md`](breeze-leds-design.md) (BL-D1 to BL-D30), [`edge-cases-breeze-leds.md`](edge-cases-breeze-leds.md) (LF facts, BL rows), [`breeze-leds-sdk-research.md`](breeze-leds-sdk-research.md), [`breeze-leds-field-research.md`](breeze-leds-field-research.md) |
| KLD, KVE | [`keypad-leds-visibility-design.md`](keypad-leds-visibility-design.md) (KL-D1 to KL-D11), [`edge-cases-keypad-leds-visibility.md`](edge-cases-keypad-leds-visibility.md) (KF facts) |
| CHK, ST | [`composer-checklist.md`](composer-checklist.md), [`status.md`](status.md) |
| HUE-ST, HUE-G | the Hue project, read only: `~/projects/c4-hue-driver/docs/status.md`, `~/projects/c4-hue-driver/docs/c4-lighting-guidelines.md` |
| SIB | the sibling research, `docs/keypad-led-dimming-sdk-research.md` (not written yet when this note was) |

## 0. Facts the decisions rest on

### 0.1 The house (MEASURED, the Windows session's Composer read of 2026-11-12)

| # | Fact | Status |
| --- | --- | --- |
| HF1 | The keypad bound to the fan's speed links is a Control4 Keypad Dimmer C4-KD120. Two Control4 switches beside it are run as 2-button keypads and are not bound to the fan. All three run firmware 5.1.1. | MEASURED |
| HF2 | Their LED dimming is set under "Ambient Light Profiles", "Fully Customized". Each device uses its own ambient sensor ("Mode: Independent"). | MEASURED |
| HF3 | Status LEDs: Min Brightness 13 on the keypad dimmer and 17 on the switches, Max 255. Dark Room is below ambient 10 and Bright Room is above 50, on a 0 to 255 scale, with a ramp between. **In a dark room a lit status LED sits at its Min, never at 0.** This matches the Hue project's record of the change of 2026-11-11 (HUE-ST 73 to 79). | MEASURED |
| HF4 | Backlight (the engraving): Min 0, Max 180, Dark Room below ambient 1. | MEASURED |
| HF5 | Composer reads the current ambient level only in its editor, with a command named `GET_AMBIENT_LEVEL`. It read 2 to 3 at night: below the Status LEDs' Dark Room (Status at Min) and just above the Backlight's. | MEASURED |
| HF6 | Not present on these devices: an auto-dim timeout, wake on press, a proximity setting, an LED-level variable. The devices report only energy variables, and their light proxies report variables 1000, 1001 and 1311. | MEASURED |
| HF7 | The keypad's fan buttons are on "Follow Connection" with per-button on and off colours, for example on `8000ff`, off `000000`. | MEASURED; ST 198 to 208 |
| HF8 | The owner (2026-11-12): the chase still lit while the switches' LEDs nearby looked "totally dark". | owner, #198 |

What follows from HF3 to HF7 (ASSUMED until Q2): at night, at ambient 2 to 3,
the keypad's selected speed button and the chase dot are lit `8000ff` at Min
13. A dark button shows `000000`, which is black at any level. The switches'
status LEDs are at Min 17, so they look totally dark either because they show
a dark off colour or because their colour vanishes at that level. Pure blue
does vanish at the keypad's night level (DF7). Their colours were not read.
The moving dot also draws the eye more than a still LED at the same level
(SLE SL57).

### 0.2 The driver and the earlier research

| # | Fact | Status |
| --- | --- | --- |
| DF1 | Today neither animation reads, infers or reacts to the keypad's dimming. Both send full colours and lit or dark states and leave the level to the keypad. Neither engine's update takes a dimming input. | VERIFIED: BLD BL-D5 (line 36); SLD SL-D15 (line 37); DOC 476, 523; SPD `update` 821 to 840; BRZ `update` 1099 to 1118 |
| DF2 | BL61 forbade the driver following the room's light. BL63 forbade brightness from the room or the hour baked into a colour. BL70 forbade binding or reading the keypad's Ambient Light Level input. BL-D28 and BL-D29 later added half-strength Breeze colours between sunset and sunrise, at the owner's word. | VERIFIED: BLE 253, 255, 262; BLD 78, 79 |
| DF3 | The SDK pages read for #137 document no message, variable or call that sets or reads a keypad LED brightness or ambient level. A link carries colours and a lit state only. | VERIFIED-doc as of 2026-11-08: BLS section 8 (lines 360 to 371); SG SG10 (line 93); HUE-G L54 (line 181, "the keypad's own driver handles these") |
| DF4 | The keypad's Control Inputs have an Ambient Light Level row. A device can take its level from another device (Source and Follower) through it. | VERIFIED: `v1-design.md` K19 (line 2003); BLF 84 to 88; BLE LF18 (line 91) |
| DF5 | A keypad's sensor picks up its own buttons' light, and keypads side by side read differently. A profile with 0 at low ambient turns the LEDs off in a dark room. Snap One's Lux line can turn status LEDs off in **bright** rooms. | BLF 88 to 95 (field snippets; Lux: Official snippet) |
| DF6 | The keypad dims colours sent over a link. Pure blue `0000ff` vanished at its night level in the probes of 2026-11-09, and half white stayed clearly visible. Which message paths were tried is not recorded, so that it holds for every path (a preload plus `MATCH_LED_STATE`, or `BUTTON_COLORS` with `CURRENT_COLOR`) is ASSUMED. | VERIFIED-house: CHK 923; BLD 64, 78 |
| DF7 | One message on a link reaches every keypad bound to it. The driver never sends a keypad proxy command by device id, never changes a keypad setting, and never uses the Ambient Light Level input. | LF14 ASSUMED (BLE 87); the rule VERIFIED: BLD BL-D1 (line 32) |
| DF8 | The pixels are the speed links 301 to 306 with a device bound, taken from the links' bookkeeping. Off, Toggle, Cycle, 311 and the light's links never animate. | VERIFIED: LNK `pixels_list` 667 to 676, `read_bound` 568 to 588, `binding_changed` 710 to 771; BLD BL-D2 |
| DF9 | The chase has four states: off, resting, waiting and chasing. It holds pixels only while chasing. A real change of its inputs settles every held pixel (two messages each) and starts a new run whose first chase comes `FIRST_MS` = 2,500 ms later, or it goes off. `why_not` lists why no chase can run, and `inputs()` lists what a real change is. | VERIFIED: SPD 15 to 21, 97, 292 to 309, 317 to 323, 539 to 547, 563 to 576, 587 to 592, 596 to 608, 750 |
| DF10 | Breeze has four phases: idle, gust, rest and leave. Active needs enabled, `per_speed`, online, Breeze and a pixel. Leaving Breeze while the rest holds plays the ending wipe. Any other way out settles every held pixel at once. Start darkens every pixel, then gusts at once. Between gusts every pixel is dark and nothing is sent. | VERIFIED: BRZ 11 to 40, 335 to 343, 941 to 951, 954 to 963, 966 to 975, 1002 to 1020, 1043 to 1055 |
| DF11 | Breeze colours are scaled by `Breeze LED Night Brightness (%)` between sunset and sunrise. The driver works out night from the project's latitude and longitude with `fan/sun.lua`, re-arming at each sunrise and sunset or every 6 h, only while `Breeze LED Animation` is `Gusts`. The chase has no night setting. | VERIFIED: BRZ 567 to 572, 235 to 246; DRV 861 to 890 (the gate at 865); SUN 1 to 36; SLD SL-D15; DOC 523 |
| DF12 | Both engines are fed through the hub from `listener.shown` and `listener.phase`, the chase first. A new input would reach them the same way. | VERIFIED: DRV 272 to 290, 292 to 305, 309 to 328; HUB 80 to 83 |
| DF13 | The links send a speed LED only when its lit state or colour changes. They answer a bind or `REQUEST_BUTTON_COLORS` in full, send a held link nothing, and refresh all ten fan links at the first contact. | VERIFIED: LNK 343 to 359, 378 to 384, 395 to 400, 419 to 429 |
| DF14 | The budget is 30 messages in any 1,000 ms. 40 a second was measured clean, and one button flickers distinctly at 20 changes a second. Snap One warns that fast periodic LED updates flood Zigbee. A chase costs 13 messages (11 when a lit button is at an edge). | VERIFIED: SPD 99 to 100; BLD BL-D24 (line 74) and 1a (62, 63); BLE LF15; SLD SL-D12, SL-D18 |
| DF15 | `OnDriverDestroyed` cancels the night timer, stops the chase (which settles the pixels it holds) and stops Breeze (which sends nothing). Nothing of an animation is persisted. | VERIFIED: DRV 1403 to 1421; SPD 861 to 870; BRZ 1187 to 1192; BLE BL50 (line 226) |
| DF16 | Programming sees commands, variables, conditionals and events, never properties. A released command is never removed. Properties may come and go, and their values survive updates and restores. | VERIFIED: KVE KF7, KF8, KF19 (lines 53, 54, 65) |
| DF17 | The 20 LED rows are shown only while a speed link is bound, hidden 8 s late, display only. | VERIFIED: KLD KL-D1, KL-D2, KL-D4, KL-D5; ROWS 58 to 79, 88 |
| DF18 | Last Action L42 to L45 cover the LED features, written on a dealer's change or a binding, never on the late-init replay. The next free key in this checkout is L46. | VERIFIED: TXT 65 to 77, 1143 to 1162; DRV 544 to 548, 906, 924; KVE KF18 |
| DF19 | Minimum OS 3.3.0. The house runs OS 3.4.3, and no OS 4 controller is available. | VERIFIED: `CLAUDE.md` (Targets, Environment) |
| DF20 | `shown` fires for any field that changes, the light's level included, so every input must be idempotent. | VERIFIED: MDL 408 to 416; SLE SL7 |
| DF21 | A change made in the Modern Forms app, by its remote or at the wall control arrives with the next poll: 15 s, or 2 s inside the 20 s window after a change. | VERIFIED: MDL 68, 69; SLE SF3 |

## 1. What "honour the policy exactly" can mean here

The keypad scales the brightness. The driver only sends colours and states
(DF1, DF3, DF6). Three readings of the request follow, and the cases
below are decided against them.

| # | Reading | What it takes | On the house |
| --- | --- | --- | --- |
| E1 | **Literal.** Every LED shows at the level the policy gives it. | Nothing: the keypad applies its level to link colours (DF6). | Already met. At night the dot is a lit LED at Min 13 (HF3), as is the selected speed's LED. |
| E2 | **Visual: the keypad looks like its neighbours.** Its LEDs go off in the dark and come back with the room. | The keypad's own policy turning lit LEDs off in a dark room: Status Min Brightness 0. Composer only, no driver change. | Exact by construction, from the keypad's own sensor. The resume when the room brightens is free. The steady LEDs go dark too ("the leds go dark"). The messages go on, unseen (DM60). |
| E3 | **The driver stops sending** while the LEDs are dark. | A dark signal: (a) a read, (b) an inference, (c) a hook. | (a) is not available on the house (HF5, HF6). (b) and (c) are approximations: a lamp-lit room at night is not "dark" to the keypad. With Min 13 the steady LEDs stay faintly lit. |

**Recommendation:** E2 first (Q1), watched for one night. E3 by the sun only
if the owner then wants the night's traffic gone too, or keeps Min 13 and
still wants no chase at night (Q3).

## 2. The three answers the sibling research may give

| Answer | What the driver would have | Fit on the house |
| --- | --- | --- |
| (a) Read | Per keypad, the result of the policy: an LED level or a "dark" flag that a load can read without sending the keypad anything (an event, or a value Director already holds). Only that counts as (a). A raw ambient value would need the keypad's curve to mean anything (DM9). | Not available: no LED-level variable (HF6). `GET_AMBIENT_LEVEL` is an editor command to the keypad (HF5), so a driver would need a keypad command by device id (forbidden by BL-D1, DM8), and the answer is ambient, not the level. |
| (b) Infer | Night from the sun at the project's location, already computed for Breeze (DF11). A clock schedule is forbidden (BL54, BLE 235). The fan's own light being off is a weak hint. | Available today, approximate (DM66). |
| (c) Nothing | No read and no inference inside the driver. It can only stop sending when told: a command or a writable variable that programming sets (DF16). The keypad's own policy rules the rest (E2). | E2 needs nothing from the driver. A hook comes only at the owner's ask (DM67). |

## 3. The model the E3 cases are decided against

- **One input, `dark`**, true, false or unknown, worked out by the driver.
  Under (a) it is the counted keypads with dark winning (DM28, DM29), under
  (b) the sun and the row of DM64, under (c) the hook. It is fed to both
  engines with the other inputs (DF12).
- **The chase:** `dark` is one more reason in `why_not` and one more field
  in `inputs()` (SPD 292 to 309, 317 to 323). A change therefore takes the
  existing path (SPD 762 to 769, 596 to 608). Every held pixel is settled and
  the chase goes off. When `dark` ends, a new run starts with its first chase
  `FIRST_MS` later (SL-D19).
- **Breeze:** `dark` takes the engine out of active, and leaving is false
  while dark, so it settles instead of playing the ending wipe (BRZ 335 to
  343, 1043 to 1055). When `dark` ends with Breeze still blowing, start runs
  again: dark first, then a gust (BRZ 954 to 963).
- **Hysteresis (a only):** dark acts at the first reading. Lit acts only
  after it has held for `LIT_HOLD_MS` (proposal: 10 s) without a break. At
  start, unknown pauses until the first answer, for at most `START_WAIT_MS`
  (proposal: 10 s, longer than `FIRST_MS`). Under (b) the flip is at
  sunrise or sunset and needs no hold.
- **The steady LEDs belong to the links and the keypad:** nothing is
  sent to any LED because of `dark` alone, except to make a pixel the
  engine held truthful as it lets go.

Under E2 alone none of this is built. The "Today" column is then also what
E2 does, with every frame invisible in a dark room.

## 4. Cases

### 4.1 The policy, the colours and the neighbours (the house facts)

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM1 | The policy scales brightness and the driver only sends colours | Full colours and lit or dark states, no brightness (DF1, DF3). The keypad dims link colours (DF6). | No change. Under E1 the request is already met: what the dot shows is the policy's level for a lit LED. The driver has no lever on the level, only on whether it sends a frame (E3) and which colour. | AUTOMATIC (nothing to do) |
| DM2 | Status Min above 0: in a dark room the policy's "dark" is dim, not off (HF3: 13 on the keypad, 17 on the switches) | The selected LED and the dot show at Min 13, faint purple (HF7, ASSUMED until Q1's look) | The driver cannot make a Min-13 LED darker without lying about the fan's state (DM47). Faint is what the policy says, so faint is honest. | AUTOMATIC (nothing to do) |
| DM3 | The colour decides what "dim" looks like: pure blue vanishes at the night level, half white stays visible (DF6), black is off at any level | The owner's purple `8000ff` shows at Min 13. The switches look dark; their colours were not read (Q2). | Explained, not acted on. The manual's line on blue at night stands (DOC 523). | AUTOMATIC (documentation) |
| DM4 | **Make the keypad as dark as its neighbours by its own policy (E2):** Status LED Min Brightness 0 on the keypad dimmer | Min 13 | A Windows session brief, under a minute, in the same Ambient Light Customization editor used for the Hue project's change (HUE-ST 76 to 79). The value is read back from Composer's log, and setting 13 again undoes it. Below ambient 10 every lit LED is off (the selected speed, the dot, Off). Above it the LEDs ramp up and the chase shows again. No driver change, no reboot. | OFFERED (Q1); FORBIDDEN for the driver to change it (BL-D1, LF4) |
| DM5 | Dodging the dim by choosing colours from the room or the hour (a colour that vanishes at Min) | Not done; BL63 forbids it | Stays forbidden. Colours are the dealer's, and a colour chosen to vanish at night would also change the day. | FORBIDDEN |
| DM6 | **Neighbours' sensors disagree:** each device dims by its own sensor (HF2), so the keypad can be in the Dark Room band while a switch beside it is not, or the reverse | Each device follows its own reading. The driver knows neither. | Under E1 and E2 each device is exact for its own reading, and the driver takes no side. Under (a) the driver follows the keypads bound to its pixel links, never a neighbour that is not bound (DM29). To make the three dim together, one device can follow another's sensor: the Source and Follower setting, Composer only (DF4). | AUTOMATIC; the Follower setting OFFERED (Q5) |
| DM7 | The keypad's sensor sees its own lit buttons: the dot, a white Breeze head, the selected LED (DF5; the sensor bar sits just below the buttons, BLF 39) | Its reading may sit above its neighbours' while the chase runs, so it dims later than they do | Under E2 there is no light in the dark band, so no feedback. Under (a) a pause is decided from readings the animation inflated and a resume from clean ones: stable, but late to pause. Making the keypad a Follower of a switch removes the bias (DM6). | OFFERED (Q5); unmeasured (BLF H5) |
| DM8 | The driver asks the keypad for its ambient level (`GET_AMBIENT_LEVEL`, HF5) | Not done | It would be a keypad proxy command by device id (BL-D1), on a timer (a radio query, DM61), undocumented as a driver call (SIB), and it returns the ambient value, not the LED level (DM9). | FORBIDDEN unless SIB documents it **and** the owner lifts BL-D1 |
| DM9 | A copy of the keypad's curve in the driver (thresholds 10 and 50, Min 13) to turn an ambient value into "dark" | Not done | No API reads a keypad's settings (LF4). A copy drifts the moment the dealer edits the curve in Composer: automation that makes a later manual fix harder. | FORBIDDEN |

### 4.2 The chase when the dark starts or ends (E3)

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM10 | Dark starts during the rest (resting, nothing held, SPD 16, 579 to 584) | A chase every 5 s, whatever the room (SPD 94) | The rest's timer is cancelled and the state goes off with the reason "the keypad LEDs are dark". **Nothing is sent**, because nothing is held (SPD 563 to 576 settles only held links). | (a) AUTOMATIC; (b) at sunset, by the row of DM64; (c) on the hook |
| DM11 | Dark starts in the 2.5 s before a run's first chase (resting with `first`, SPD 587 to 592) | The first chase comes 2.5 s after the run starts | As DM10: the run is dropped. Its `first` is forgotten, and the run that follows the dark gets its own 2.5 s. | as DM10 |
| DM12 | Dark starts mid-chase (chasing, every pixel held, SPD 679 to 681) | The chase plays on | It ends now through the existing stop path: every held pixel is settled (BUTTON_COLORS and MATCH_LED_STATE, 2 each: 8 on the house; SPD 539 to 547, LNK 534 to 561), so each button shows its real state at the keypad's level. No more frames. A cheaper variant, a closing frame that darkens the dot and relights the buttons lit at rest (2 messages at most, SPD 690 to 711), is worth it only if a dark keypad lights up on a link message (Q6). | as DM10; the variant OFFERED after Q6 |
| DM13 | Dark starts while the chase waits for Breeze's ending wipe (waiting, SPD 18 to 20, 644 to 648) | Retried every 200 ms | Off. Nothing held, nothing sent. The wipe is DM17. | as DM10 |
| DM14 | Dark ends at an animated speed in fan mode | Not applicable | A new run: the first chase `FIRST_MS` after the engine sees "not dark", then one every rest (SL-D19). Under (a) that is `LIT_HOLD_MS` plus 2.5 s after the room lights up, 12.5 s with the proposed hold. | (a) AUTOMATIC; (b) at sunrise; (c) on the hook |
| DM15 | The reading flaps (a lamp on and off, a TV, a door, headlights) | Not applicable | (a): lit must hold `LIT_HOLD_MS` before the chase resumes, so a flap pauses once and resumes once. Acting on every reading is forbidden. (b) and (c) do not flap. | AUTOMATIC; acting per reading FORBIDDEN |

### 4.3 Breeze when the dark starts or ends (E3)

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM16 | Dark starts during Breeze's start (dark first, then the first gust) or mid-gust | Gusts play on, scaled at night by `Breeze LED Night Brightness (%)` (DF11) | Stop at once with no ending wipe, the BL-D11 path (BRZ 941 to 951): every held pixel settled (8 messages), which in Breeze shows every speed LED dark while the links keep 311 lit (BLE LF10). Variant: darken only the lit pixels (at most 4) and keep holding them dark as an endless rest (BL-D19's rest: all dark, nothing sent). | AUTOMATIC; the variant OFFERED after Q6 |
| DM17 | Dark starts during the ending wipe (the white head, the brightest frame the keypad shows; BRZ 1002 to 1040) | The wipe plays out | No more head: every pixel the wipe still holds is settled at once (2 each), so the buttons take their fan-mode state (the selected speed lit at the keypad's level). | AUTOMATIC |
| DM18 | Dark starts during a Breeze rest (every pixel dark already, BRZ 966 to 975) | Nothing sent until the next gust | With the settle path, 8 messages to buttons that are already dark. With the variant, nothing: the rest's timer is cancelled and the pixels stay held. This is the case for the variant if Q6 shows link messages are visible on a dark keypad. | AUTOMATIC |
| DM19 | Dark ends while Breeze still blows | Not applicable | Start again (BL-D19): every pixel taken dark (4 messages to buttons the links already darkened, a harmless repeat) and the first gust at once. From the variant's endless rest, the next gust after a rest drawn by strength (BL-D22). | AUTOMATIC |
| DM20 | Breeze starts while dark (a keypad, the Breeze fan, programming, the app, the remote) | Dark first, then gusts | The engine stays idle. The links show the Breeze state (speed LEDs, Off, Toggle and Cycle dark, 311 lit; BLE LF10). These are real-state messages: unavoidable and right. Gusts start when the dark ends (DM19). | AUTOMATIC |
| DM21 | Breeze ends while dark (any source) | The ending wipe once (BL-D8) | No wipe, which is an animation. Nothing is held, or the variant's held pixels are settled at once. The links show the new state (the selected speed or Off lit). The wipe is not played later. | AUTOMATIC |

### 4.4 Fan off, offline

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM22 | Dark starts or ends with the fan off | No animation. Off is lit in the keypad's own colour (LNK 296). | Nothing to send. `dark` is recorded, so a fan turned on while dark starts no run. | AUTOMATIC |
| DM23 | The fan turned on at a speed while dark (any source) | The selected LED lights and a run starts (SL-D19) | The links light the selected LED (colours and state, 2 messages) at the keypad's level. No run until the dark ends. | AUTOMATIC |
| DM24 | Offline, rebooting or waiting while dark, or the dark flips while offline | The animations are stopped while not online (SL-D9, BL-D11; DRV 276, 287) | `online` and `dark` are separate inputs. A run or gusts start only when the fan is online and it is not dark. | AUTOMATIC |

### 4.5 Partial dimming: the ramp between Dark Room and Bright Room

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM25 | The LEDs are dimmer but lit (ambient 10 to 50 on the house: Status between Min and Max, HF3) | The chase and gusts play. The keypad dims them like every lit LED (DF6). | They run as today. A lit LED at a lowered level is lit, and the dot matches the selected LED's level, as the owner asked ("the colour set for that speed", SL-D7). Under (a) any level above the off state is lit. (b) only knows night from day. (c) as today. | AUTOMATIC |
| DM26 | Do the driver's colours override the dim? | No: link colours are dimmed (DF6). The chase lights a preloaded colour with `MATCH_LED_STATE`, the same path as a steady LED (SPD 38 to 39). | No change. Scaling colours to a read level (double dimming, BL63) and sending a brighter colour to beat the dim are both forbidden. | AUTOMATIC; both FORBIDDEN |
| DM27 | Breeze at night on top of the keypad's own dim: the night percent multiplies with Min 13, so half-strength sky `205880` may not show while the purple selected LED does | BL-D28 at 50 % (DF11) | BL-D28 stays as the owner set it, a hue balance against purple. Whether it goes to 100 once a pause or E2 exists is the owner's call (Q4). | OFFERED (Q4) |

### 4.6 Several keypads on the same links

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM28 | Two keypads on the same pixel links in different rooms, one dark and one lit | Both show the chase in step: one message per link (DF7) | The decision is per link set, because over a link the driver cannot address one keypad (BL-D1). (a): **dark wins**. The animations pause while any counted keypad reports dark. The lit keypad keeps its steady LEDs and loses the animation meanwhile, and the manual says so. "Lit wins" is exact only if a dark keypad shows nothing of a lit link message, true under E2 (Min 0) and not at Min 13. (b) and (c): one state per driver anyway. | (a) AUTOMATIC; "lit wins" OFFERED only after Q1 (Min 0 everywhere); parked: the house has one keypad on the links |
| DM29 | Which devices count | Not applicable | Only devices bound to a pixel link (301 to 306), as `pixels_list` counts them (LNK 667 to 676). A keypad on Off, Toggle, Cycle, 311 or the light alone does not count (its LEDs never animate), and neither do the switches beside the keypad (HF1). | AUTOMATIC |
| DM30 | A counted device that reports nothing (no sensor, sensing off, a third-party keypad with no LEDs; KVE KF14) | Not applicable | No information. It neither pauses nor keeps the animations running on its own. If no counted device reports at all, see DM71. | AUTOMATIC |
| DM31 | Two fan drivers on one keypad (SLE SL66) | Each chases its own links | Each follows the same keypad, so both pause and resume together. Nothing more. | AUTOMATIC |
| DM32 | A keypad that follows another device's sensor (Source and Follower, DF4) | Not applicable | Transparent: the state the keypad reports is its own result, whatever sensor feeds it (DM6). | AUTOMATIC |

### 4.7 Presses and wakes

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM33 | A speed pressed on a dark keypad | The links light the new LED at once (V10). The first chase comes 2.5 s later (SL-D19). | The links act as today, at the keypad's level. The house devices have no wake on press (HF6), so the press shows the new LED at Min (faint, or dark under E2). E3: no run while dark. (a) on a keypad that does wake on a press and reports it: the chase resumes only after `LIT_HOLD_MS` plus 2.5 s, so a short wake shows the new LED and no chase, while a longer wake plays chases while it lasts (exact). | AUTOMATIC |
| DM34 | A press that changes nothing (the selected speed again; Echo LED On Press, SLE SL65) | No shown change; the keypad's echo is its own (SLE SL3) | No change. | AUTOMATIC |
| DM35 | Breeze (311) or Off pressed on a dark keypad | Gusts, or the ending wipe | DM20 and DM21: the steady LEDs follow; no gust and no wipe while dark. | AUTOMATIC |
| DM36 | A hold, or the double taps' programming (Low to Level 1, High to Level 6; ST 203 to 204) while dark | Speed changes as presses | Each speed change moves the steady LED only. No run. | AUTOMATIC |
| DM37 | Does a link message light a keypad whose LEDs are off by its policy? | Not known. The house has no wake setting (HF6), but a firmware reaction to link messages is not ruled out. | Q6 settles it. Holding back real-state LED changes while dark is forbidden: the LED would lie the moment the room brightens. | FORBIDDEN (holding back state) |

### 4.8 Speed and mode changes from any source while dark

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM38 | A speed changed from a keypad, a Navigator, programming, the driver's actions, the Modern Forms app, its remote or the wall control (the last three at the next poll, DF21) | A new run, the first chase 2.5 s later, whatever the source (SL-D19) | The links move the steady LED (2 to 3 messages). The chase records the new speed and stays off. When the dark ends, one new run at the speed of that moment. Queueing or replaying the chases missed during the dark is forbidden. | AUTOMATIC; replay FORBIDDEN |
| DM39 | Several changes while dark (a slider, Cycle presses) | A new run each time | Only the steady LED moves. No timer, no hold. | AUTOMATIC |
| DM40 | The direction reversed while dark | From the next chase or gust | Recorded; the next run or gust takes it. | AUTOMATIC |

### 4.9 The steady LEDs while dark

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM41 | The selected speed's LED (Also Lit At included) | Lit in its speed's colour by the links (LNK 289 to 307, 343 to 359). The keypad applies its level: Min 13 at night (HF3). | Unchanged. It shows what the policy shows for an "on" LED: faint at Min 13, off with Min 0 (E2). | AUTOMATIC |
| DM42 | Off, Toggle, Cycle, 311, and the light's links 200 to 202 | The keypad's own colours. The house's Up and Down have no LED (BLE LF8, line 81). | Unchanged; the policy applies to them as to any LED. | AUTOMATIC |
| DM43 | The pixels after a chase pauses | Not applicable | Not held, so the links own them (SL-D3). A bind or `REQUEST_BUTTON_COLORS` gets the truth (LNK 419 to 429). With the Breeze variant (held dark), the repaint answers dark (BRZ 1170 to 1185), which is true in Breeze. | AUTOMATIC |
| DM44 | "The leds go dark" (the owner) while the keypad's Min is above 0 | The selected LED stays faintly lit | The driver cannot make it dark honestly (DM47). The way is E2 (DM4). | OFFERED (Q1) |
| DM45 | Echo LED On Press or programming that paints the same buttons (SLE SL64, SL65) | The last writer wins | Unchanged. The manual already says programming should not paint the fan's buttons. | AUTOMATIC |
| DM46 | The driver changing a keypad's LED settings (Min, profile, Follower) to suit the dark | Never (BL-D1, LF4) | Stays never: a Composer change through the Windows session (DM4, DM6). | FORBIDDEN |
| DM47 | Imitating the policy: sending `MATCH_LED_STATE` false, black or a scaled colour to the steady LEDs while "dark" | Not done | It would lie about the fan's state, fight the keypad's own level, and cost a put-back at every change between dark and lit. Under (b) it would also be wrong whenever the sun is (DM66). | FORBIDDEN |

### 4.10 Restarts, updates, keypads replaced, rows hidden

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM48 | Driver restart, Director restart, controller reboot (about 7.5 minutes down, BLE BL47) | `OnDriverDestroyed` as DF15. At the first contact the links refresh all ten (LNK 395 to 400). The chase starts a run, and Breeze starts dark first if it blows. | (a): `dark` starts unknown. The animations wait for the first answer for up to `START_WAIT_MS`, so no chase plays at night before the first read, then follow the failure rules (DM72 to DM74). (b): worked out at once in late init (SUN is pure; DRV 861 to 890). (c): the hook's last word is not kept, so the animations run as today until told. The first-contact refresh is today's behaviour: needed and harmless. Persisting `dark` is forbidden (BLE BL50). | AUTOMATIC; persisting FORBIDDEN |
| DM49 | Project load, or a restore from a backup | Properties come back (KF7) | As DM48. A new row (DM64) comes back with the project. | AUTOMATIC |
| DM50 | The driver updated in place while paused or mid-chase | As DM48 | As DM48. While paused the chase holds nothing, so its stop sends nothing. Breeze's stop never sends. | AUTOMATIC |
| DM51 | The dev loop's reload (`--dev` builds only) | The reload kills no timer (BLE LF13). `cancel_night_timer` covers the sun's (DRV 1413). | Every new timer (the lit hold, the start wait, a read) is cancelled in `OnDriverDestroyed`. A dimming timer that outlives a reload is forbidden. | AUTOMATIC; FORBIDDEN otherwise |
| DM52 | A keypad replaced (a new device id) or re-added | Old bindings go, new ones arrive one by one, each answered (SLE SL31) | (a): the old keypad's state leaves the count with its last binding. The new one counts from its first answer and is "no information" until then (DM30). If it is the only counted keypad, the start wait of DM48 applies to it. | AUTOMATIC |
| DM53 | A keypad re-bound to other buttons (same device id) | A pixel list change: a new run (SL-D10) | Its state keeps counting. | AUTOMATIC |
| DM54 | The only dark keypad unbound from every pixel link (after the reread, KL-D11) | A pixel list change | Its state leaves the count. If nothing else is dark, a new run starts (`FIRST_MS`), with no lit hold: the set changed, not a reading. | AUTOMATIC |
| DM55 | The LED rows hidden (#178: no speed link bound) | Both engines idle, with no pixels (KVE KF12) | The dimming follow reads nothing and arms nothing while there are no pixels, at no cost. A new row (DM64) joins `ledrows.ROWS` (ROWS 58 to 79) and KL-D1's list, shown and hidden with them, display only, its value still applied (KL-D5). | AUTOMATIC |
| DM56 | Both animations Off, or `Keypad's own` | Nothing animates (KVE KF17) | The follow reads and arms nothing. | AUTOMATIC |

### 4.11 Message cost

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM57 | What a pause sends | Not applicable | The chase at rest or before its first chase: 0. The chase mid-chase: 8 (2 per held pixel), or at most 2 with the variant of DM12. Breeze mid-gust: 8, or at most 4 with the variant. Breeze resting: 8, or 0 with the variant. The ending wipe: 2 per pixel still held. Stops are sent at once and stamped in the window (SPD 63, 541). | AUTOMATIC |
| DM58 | What a resume sends | Not applicable | Nothing at once. Then a normal chase after `FIRST_MS` (11 or 13; SL-D12, SL-D18), or Breeze's dark first (4) and a gust, or from the variant the next gust. | AUTOMATIC |
| DM59 | Bursts from flapping | Not applicable | Bounded by `LIT_HOLD_MS`: at most one pause (up to 8) and one chase (up to 13) per hold and first chase, 21 messages in 12.5 s, about 1.7 a second. That is inside the 30 a second window and the field note's 3 to 5 sustained (SLE SL58). The window delays a chase and never drops one (SPD 504 to 512, 721 to 737). | AUTOMATIC |
| DM60 | The night's traffic | The chase at the house's 5 s rest: 11 messages a chase at speeds 2 and 5, 13 at 3 and 4, every 6.6, 6.2, 5.8 and 5.5 s (SLE section 5). That is **about 6,000 to 8,100 an hour, 48,000 to 65,000 in 8 hours**. E2 alone leaves it running, unseen. | E3 sends none of it while dark: the one gain E3 has over E2 on the house. | OFFERED (Q3) |
| DM61 | The read itself (a) | Not applicable | It must add no radio traffic: an event, or a value Director already holds, read no faster than every few seconds and only while there are pixels. A timer that queries the keypad over Zigbee is forbidden (DF14's warning, DM8). (b): one sun timer, which exists. (c): none. | AUTOMATIC; Zigbee polling FORBIDDEN |

### 4.12 Night, the sun and Breeze LED Night Brightness

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM62 | (a): the keypad's dark and the sun's night | The sun scales Breeze colours (DF11) | They coexist. Dark pauses both animations. The sun only scales Breeze's colours at night while it plays (BL-D28). | AUTOMATIC |
| DM63 | E2 and the sun | The same | They coexist. Below the Dark Room band nothing shows anyway. In the ramp, Breeze is at the night percent of the keypad's level (DM27). | AUTOMATIC; Q4 |
| DM64 | (b): night by the sun as "dark" | BL-D28 dims Breeze at night. The chase runs as by day (SLD SL-D15). | If night pauses Breeze, BL-D28 never shows and its row is dead. So one choice for both animations: a row such as `Keypad LED Animations at Night` = `Run` or `Pause`, with the night percent applying to Breeze only under `Run`. The sun logic runs while either animation is on: today it is gated on `Gusts` (DRV 865; SLE SL56). The row joins the managed rows (DM55). A dealer's change writes a Last Action line (L46) as L42 and L43 do, never on the replay (DF18). | OFFERED (Q3); default: Q3 |
| DM65 | (b) by a clock schedule (from and until times) | Not built | Automations live in Control4. | FORBIDDEN (BLE BL54) |
| DM66 | (b)'s wrong cases | Not applicable | A lamp-lit room at night has its chase paused although its LEDs are bright. A dark room by day (blinds, a nap) gets chases at the Min level. A Lux keypad's bright-room off (DF5) gets frames by day. The manual must say (b) follows the sun, not the room. | OFFERED (documentation) |
| DM67 | (c): a hook for programming (pause and resume in the scene that darkens the room) | Not built | A command pair is forever (DF16). A variable works only if programming can write it (SIB). Built only at the owner's ask: Control4 programming already knows the room's scenes, so it would be exact where the sun is not. | OFFERED (Q3) |

### 4.13 OS versions and keypad kinds

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM68 | OS 3.x and 4.x differ in what a driver can read (SIB) | The animations use the same calls on both (SLE section 7) | Detected at run time, falling back to (b) or (c) where (a) is missing. No `<capabilities>` change. The minimum OS stays 3.3.0 (DF19), so raising it for this is forbidden. | AUTOMATIC; FORBIDDEN (raising the minimum) |
| DM69 | OS 4 untested on the house | No OS 4 controller | Parked under "no long test waits". | parked |
| DM70 | Keypads without a sensor, with sensing off, or with a constant profile (255/254, BLF 93) | The animations run | They run: the policy never darkens them, so running is exact. | AUTOMATIC |
| DM71 | A Lux-type keypad that turns its status LEDs off in bright rooms (DF5) | The animations run | (a): they pause by day too, which is exact. (b): wrong by day (DM66). E2-style settings are the keypad's own. | AUTOMATIC under (a) |

### 4.14 Failure modes (a)

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM72 | No source: the read is not supported (the house today, HF6), no counted keypad reports, or the OS lacks it | Not applicable | The animations run as today, with one debug line. The manual says they follow the keypad only where it reports its dimming. A keypad with a constant level is never dark, so running is exact for it. | AUTOMATIC |
| DM73 | A source that answered before goes stale or fails | Not applicable | Fail toward the policy: dark after `STALE_MS` (proposal: two missed reads or 60 s), and lit again only after its answer has held `LIT_HOLD_MS`. Being wrong costs a missing animation, not a lit LED in a dark room. | AUTOMATIC |
| DM74 | A read that raises or returns a non-number | Not applicable | Wrapped in `pcall` and counted as no answer. One warning per run of failures, as SPD 376 to 395 does for `blocked`. Never raised into the engines. | AUTOMATIC |
| DM75 | A dead keypad (unpowered, off Zigbee) | Messages to it are lost (BLE BL43) | Its state goes stale, so dark wins: no harm for itself, and the other keypads on its links lose their animation until it is back or unbound (DM28). | AUTOMATIC |
| DM76 | (b) with no project location or no clock | Never night, one log line (DRV 853 to 859, 872 to 876) | The same: the animations run as today. | AUTOMATIC |

### 4.15 What the owner sees in Composer

| # | Case | Today | Proposal | Decision |
| --- | --- | --- | --- | --- |
| DM77 | Status | No animation state shown (SLE SL70) | Unchanged. A paused animation is a normal state, not a fault. | AUTOMATIC |
| DM78 | Last Action | L42 to L45 (DF18) | No line for a change between dark and lit, which happens twice a day or more on its own. L46 only for a dealer's change of a new row (DM64), never on the replay. | AUTOMATIC |
| DM79 | `Keypad Links` | First row "7 of 13 links bound; LED settings shown" (ST 127 to 128; TXT 1218 to 1223; DRV 410 to 424) | (a): while paused, the first row's note may end `; LED animations paused: keypad LEDs dark`, rewritten only on a change between dark and lit (one property write each). (b): `; LED animations paused at night` while paused. (c) and E2: nothing. | OFFERED (Q7) |
| DM80 | The debug log and the dev loop | `say_night` writes each different line once (DRV 853 to 859) | One line for each change between dark and lit and each change of source, never one per reading. The engines' `debug()` add `dark` (SPD 872 to 919, BRZ 1194 to 1251). | AUTOMATIC |
| DM81 | The manual | "At night" (DOC 523) and Breeze "Dimming" (DOC 476) | It says what the keypad's profile does to the animations (Min above 0 means faint, not off), the E2 setting for keypads that should go dark, and the E3 behaviour that ships: the sun, several keypads, the steady LEDs belonging to the keypad. | OFFERED (documentation, the coordinator) |

## 5. For the contract

1. **E2 first.** On the owner's yes (Q1), a Windows session brief sets the
   keypad dimmer's Status LED Min Brightness from 13 to 0 under the standing
   approval, reads it back from Composer's log, and the owner looks once at
   night. The driver is not changed for it. The driver never writes keypad
   settings (DM4, DM46).
2. **The driver sends no brightness and imitates nothing.** No `MATCH_LED_STATE`
   false, no black and no scaled colour stand in for the policy. Steady LEDs
   always follow the fan (DM26, DM47).
3. **If E3 is built:** one input `dark`, fed to both engines through the hub
   with the other inputs (DF12). For the chase it is a `why_not` reason and an
   `inputs()` field. For Breeze it is part of active, and leaving is false while
   dark (section 3).
4. **Pausing reuses the stop paths:** a settle of held pixels, no ending
   wipe, nothing sent at rest. The cheaper variants (DM12, DM16, DM18) come
   only if Q6 shows link messages are visible on a dark keypad (DM57).
5. **Resuming starts a new run.** `FIRST_MS` for the chase, dark first for
   Breeze. Nothing missed is replayed (DM14, DM19, DM38).
6. **Source per answer.** (a) is the bound keypads' own result, dark winning,
   with `LIT_HOLD_MS`, `START_WAIT_MS` and `STALE_MS`, and no Zigbee polling
   (DM28, DM48, DM61, DM73). (b) is the sun through one row for both
   animations (DM64). (c) is a hook only at the owner's ask (DM67). Never
   `GET_AMBIENT_LEVEL` from the driver, never a copy of the curve, never a
   clock schedule, never the Ambient Light Level input (DM8, DM9, DM65, BL70).
7. **Failure:** no source means as today. A stale source means dark. A failing
   read counts as no answer (DM72 to DM74).
8. **Lifecycle:** nothing persisted. Every new timer is cancelled in
   `OnDriverDestroyed`. Nothing is read or armed without pixels. A new row
   joins KL-D1's managed rows (DM48 to DM56).
9. **Composer:** Status unchanged. No Last Action line for a change between
   dark and lit. L46 only for a dealer's change of a new row. The
   `Keypad Links` note is optional (DM77 to DM79). The manual says what Min
   above 0 means (DM81).
10. **Control4 guidelines section** of the contract: "Keypad dimming is the
    keypad's" (SLD section 7, SG10) stays met. Under E3 the pause departs from
    "the LED follows the device" less than the animation itself does. Under
    (b) it departs from "follows the room" (DM66), and the contract says so.

## 6. Open questions (recommended answer first, then the cheapest way to settle it)

1. **Should the keypad go dark at night like its neighbours?** *Recommended:*
   yes. Set its Status LED Min Brightness from 13 to 0 (E2, DM4), which gives
   the owner's sentence exactly, resume included. The steady LEDs go dark below
   ambient 10 too. *Cheapest:* the owner's word (10 s). Then a Windows session
   brief sets it and reads it back from Composer's log (under a minute), and
   the owner looks once in the dark room (30 s): no dot, no selected LED, and
   both back when a lamp goes on.
2. **What do the switches show at night that looks "totally dark"?**
   *Recommended assumption:* their LEDs at Min 17 show either a dark off colour
   or a colour that vanishes at that level (pure blue, DF6). *Cheapest:* the
   Windows session reads both switches' button on and off colours in Composer
   (under a minute). This only explains the difference. It changes no decision.
3. **Beyond E2, should the driver stop sending at night (E3 by the sun,
   DM64)?** *Recommended:* not in the first step. Decide after Q1's night. If
   E2 satisfies the owner, E3 only saves about 6,000 to 8,100 messages an hour
   of darkness (DM60), at the cost of no chase in a lamp-lit room at night. If
   it is wanted: a `Pause` row, the house set to `Pause` and new installs
   defaulting to `Pause` (it never animates more than today). A hook for
   programming (DM67) comes only if the owner wants the pause tied to scenes.
   *Cheapest:* the owner's word (10 s).
4. **Breeze LED Night Brightness once E2 or E3 exists.** *Recommended:* keep 50
   until the owner has watched one Breeze at night with the new setting, then
   choose 50 or 100 (DM27, DM63). *Cheapest:* the owner at the keypad, one
   Breeze at night (1 minute, the Breeze fan's tile).
5. **Should the keypad follow a switch's sensor?** *Recommended:* only if, after
   Q1, the keypad and its neighbours still dim at visibly different times
   (DM6, DM7). *Cheapest:* the owner's glance at dusk. If yes, the Windows
   session sets the keypad to Follower in Composer (a minute, reversible) and
   reads which device it follows.
6. **Does a link message show on a keypad whose LEDs are off by its policy?**
   *Recommended assumption:* no. The house devices have no wake setting (HF6),
   and the keypad applies its level to whatever it shows (DF6). *Cheapest:*
   during Q1's look, after E2, the owner presses a speed in the Control4 app in
   the dark room and watches the keypad for 10 s. If it lights, the cheaper
   pause variants (DM12, DM16, DM18) are chosen.
7. **Show the pause in `Keypad Links`?** *Recommended:* yes if E3 ships with
   (a) or (b), as the first row's note (DM79). *Cheapest:* the owner's word.
8. **Several keypads: dark wins?** *Recommended:* yes (DM28). *Cheapest:* the
   owner's word. Any hardware check is parked, because the house has one keypad
   on the links.

## 7. What could not be verified

- **Whether Min 0 turns a status LED fully off**, and how the ramp from 0
  looks just above ambient 10: assumed from the profile's meaning. Q1's look
  settles it.
- **Whether the keypad dims every link message path alike** (a preload and
  `MATCH_LED_STATE`, or `BUTTON_COLORS` with `CURRENT_COLOR`): only pure blue
  vanishing was recorded (DF6).
- **Whether a driver can read any dimming state on OS 3.x or 4.x:** SIB's
  question. The house read found no variable (HF6).
- **The switches' colours at night and why they look totally dark:** not
  read (Q2).
- **Self-illumination of the keypad's sensor by the chase:** inferred
  (DF5), not measured (BLF H5).
- **Several keypads on one link, OS 4, a night of E3:** parked (no long
  test waits; the house has one keypad on the links and an OS 3.4.3
  controller).
