# Breeze on the keypad LEDs: hardware, Zigbee and the eye

> **Status (2026-11-13, #213).** Built in 1.4 (#137) by
> [`breeze-leds-design.md`](breeze-leds-design.md), whose revision after the
> house round of 2026-11-09 (its section 1a) replaced several
> recommendations here: only buttons on the speed links animate (Off does
> not join, so the house column is four buttons, not five); every button is
> dark between gusts instead of a resting blue column; the palette is white
> with ice, teal and sky, never pure blue, because `0000ff` vanished at
> night (BL-D20); the step is `Breeze LED Step (ms)`, 60 to 400, default
> 120, not 300; the house kept about 40 messages a second clean, and the
> engine allows 30 (BL-D24), well above this note's planning figure of
> about 10; and the gusts run the way the fan blows (BL-D30). The Composer
> read of 2026-11-12 answered Q1a and H4: one status LED curve over the
> ambient reading, no separate level for lit and dark buttons
> ([`keypad-led-dimming-sdk-research.md`](keypad-led-dimming-sdk-research.md)
> section 1.2). Since 1.9 (#207) the animation pauses while the bound
> keypad reads dark ([`ambient-pause-design.md`](ambient-pause-design.md)).
> The hardware, Zigbee and perception findings stand.

Research for [issue #137](https://github.com/corytron/c4-modernforms-driver/issues/137), written
2026-11-08: everything outside the DriverWorks SDK that decides whether the keypad buttons bound to
the fan can play a rising blue, teal and white "breeze" while Breeze blows, and how fast. The SDK
side (what `BUTTON_COLORS` and `MATCH_LED_STATE` carry, driver timers) is a separate note. Two owner
decisions arrived while this was written: the **driver** animates over its keypad links (not
Composer programming), so Q2 is short; and the animation must **respect the keypad's ambient-light
LED dimming** (section Q1a).

**Reliability key.** *Official*: a Snap One/Control4 document. *Dealer*: a forum post by a Control4
dealer. *Forum*: a user post. *Vendor*: a third-party seller's page. *Chip*: a radio-chip vendor.
*Academic*, *Hobbyist* as named. *read*: the page was read in full. *snippet*: c4forums.com refuses
automated reading, so the thread is known only from a search engine's summary of it; treat it as
the weakest evidence here. Sources are numbered S1 to S41 in [Sources](#sources). Snap One text is
summarised, never copied. Placeholder keypad: "Example Keypad" (device 456).

## Summary

- **Possible:** one RGB LED per full-size button, any 24-bit colour; the fan's column is **five
  LEDs** (seven buttons = five singles plus the Up/Down pair at the bottom, bound to the light).
  No built-in effect: every step is one message per changed button. Nobody has published one.
- **Zigbee sets the pace:** 40 to 160 ms per message, LED updates reported as low priority, about
  10 unicasts/s as a mesh ceiling. Budget **about 10 LED messages/s in a burst, 3 to 5/s average**.
- **Frame rate:** a white-head, teal-trail comet (3 messages per step) steps every **250 to 350 ms**;
  a one-edge wave every 150 to 200 ms. The eye sees steps there, so motion comes from the trail and a
  steady cadence, played as **gusts with rests**.
- **Dimming:** the keypad scales LED brightness by room light, so draw the trail with **hue at full
  components** (white, cyan, azure, blue: luminance 1.00, 0.79, 0.23, 0.07), never low values.
- **Risks:** mesh load over hours of Breeze, latency jitter, white beside the sensor bar brightening
  the keypad at night, the five links' physical order (unknown to the driver), dark-state brightness.

## Q1. The keypad hardware

**Buttons and LEDs.** The keypad dimmer (C4-KD120/240/277) is a dimmer and a configurable keypad in
one, with programmable RGB status LEDs, backlit engraving with its own colour, and an ambient light
sensor that sets backlight and status LED brightness (S1, Official, read). It takes two to seven
buttons in 37 layouts made of single, double, triple and split Up/Down keycaps (S2, Official, read).
The split Up/Down pair must go in the bottom slot, the ambient sensor bar snaps on directly below
the buttons, and each button's LED light pipe is on its right edge (S3, Official, read). Seven
buttons is only reachable as five single buttons plus the split pair, so the house keypad is very
probably five fan buttons stacked above Up and Down side by side at the bottom (inference from S2
and S3; H1). The driver's links (Fan Speed 2 to 5 and Fan Off) do not tell it which row each button
is on.

**Up and Down.** No official statement on whether the split pair has status LEDs. The Keypad Button
Colors driver hides "Up/Down buttons in position 5 and 6" as buttons it cannot control (S24, Vendor,
read). The probe showed Up and Down have Button Link rows (S41), which says nothing about an LED.
Treat the column as five LEDs (H2). The bottom of the animation is therefore the lowest fan button.

**Colours accepted.** Composer gives each button an LED behaviour (follow the bound device, follow
the load, push/release with push and release colours, programmed), a finish and a backlight colour
(S5 pp. 158-164, S7; Official, read). On the house keypad `#8000FF`, `#800000`, `0,0,255` and
`255,96,0` all show as intended (S41), so 24-bit values are accepted and middle components (96, 128)
render, at least in daylight. On previous-generation (non-Lux) lighting a programmed LED state is
temporary: the button's next configured behaviour replaces it (S12, Official, read). Whoever drives
the link's LED wins the next update; a press during Breeze repaints that button.

**Built-in effects.** None for status LEDs. A dealer: there is no blink; set a colour, delay, set
black, repeat (S14, Dealer, read, 2016). The only firmware animations found are indications: all
LEDs green at first power-up (S4, Official), the old dimmers' LEDs flashing while a bound load ramps
(S14, Forum), and a blinking signal-strength mode (S22, snippet). Keypad Enhancer's "blink" is the
driver sending commands (S26, Vendor).

**Colour accuracy.** Marketing promises virtually any colour (S8, Official). In the field, white and
the stock blue look different between hardware generations (S23, snippet), and one KD120/APD120
showed green for turquoise while blue and green alone worked (S17, snippet): a weak channel shows
only in mixes, so check every button with white (H3). Equal RGB on an RGB LED is usually tinted, and
uncorrected mixes drift because LED output is linear while vision is not (S38, Vendor tutorial). No
source says how the keypad maps 0-255 to drive level or whether it gamma-corrects. "Teal" such as
`0,128,128` is only cyan at half power, which the keypad's dimming does anyway: use full-power cyan.

**LED latency and queueing (field).** A user driving backlight colours on several keypads from
garage-door macros saw lag; replies blamed LED and backlight changes being low priority on the
Zigbee command stack (a few seconds at worst), a flooded mesh, and advised splitting devices into
groups with delays (S15, snippet). On newer keypads, LEDs changed by a macro appear to sweep from top
to bottom (S16, snippet, question only), which is what per-button messages with visible gaps would
look like. Vendors: tap a colour and wait, dragging may delay (S24, S25); Calendar Wizard added
"ordered, staggered dispatch" for LED updates in October 2026 (S28). **No measured figure** for
message-to-LED latency exists in any source found (H6).

## Q1a. Ambient light dimming (owner requirement, 2026-11-08)

**Documented.** The sensor adjusts backlight and status LED brightness by itself (S1, S2; Official).
In Composer, Advanced Properties ▸ Ambient Light Profiles offers presets or "Fully Customized", where
each brightness level is set per ambient condition; sensing is Independent, Source or Follower, a
follower taking its level from another device through the Ambient Light Level connection (S5
pp. 158-163, S7; Official, read). Snap One's newer Lux line (different hardware) exposes separate
status-LED intensities for dark, dim and bright rooms, a switch to turn status LEDs off in bright
rooms, and fixed intensities when sensing is off (S13, Official, snippet).

**Field.** Profiles are per device, set in System Design or Monitoring; users quote minimum/maximum
pairs such as 255/254 (constant) or 180/75, and a 0 at low ambient turns the LEDs off in a dark room
(S19, snippet). Sensors pick up the buttons' own light (one read 255 under electrical tape), keypads
side by side read differently, and black finishes have a smaller light pipe (S18, S19; snippet).

**Not documented: lit versus dark brightness.** No public source names separate brightness levels
for a lit (on) and a dark (off) button on this keypad generation; the Gen-3 "Fully Customized" table
is not described anywhere public. The house uses black as the off colour, so it has not mattered.
If such a level exists and is low, a frame drawn with off-state colours would vanish: draw every
visible animation colour as the button's **lit** colour, and use the dark state only for black (H4).

**Is the sent colour scaled?** The documents say brightness follows the room for whatever colour is
shown, so hue and intensity are separate. The likely mechanism is the keypad scaling all three
channels by its current level (inference; H3). Then small components round away. At a night level
of, say, 5%: `0,0,255` drives about `0,0,13`, `0,0,96` about `0,0,5`, `0,0,40` about `0,0,2`; a
three-step blue fade collapses into one visible blue and two near-dark LEDs, and `0,64,255` loses
its green and turns plain blue. A profile level of 0 turns every LED off; the animation is then
invisible, which is what respecting the dimming means.

**What it means for the palette.** Make the trail by **hue, not level**: use components of 0 or at
least 128 (best 0 or 255) and never send a dimmed colour. The hue ladder white ▸ cyan ▸ azure ▸ blue
carries its own luminance fall-off (sRGB/Rec. 709 weights 0.2126 R + 0.7152 G + 0.0722 B on linear
values, S39): **1.00 ▸ 0.79 ▸ 0.23 ▸ 0.07**, so a comet still fades toward its tail at full
components, at every keypad level. At night the eye's sensitivity shifts toward blue and blue-green
(Purkinje effect, S40, Encyclopaedia), which helps the tail.

**Sensor feedback.** The bottom fan button sits just above the sensor bar (S3). A white head there
may raise the reading in a dark room and lift the whole keypad's brightness, which then drops when
the head moves on: visible "pumping" (inference from S18; H5). Enter at the bottom with cyan and turn
white from the second row up.

## Q2. Composer programming timing (short, after the owner's decision)

- **Delay** (Programming Control): a number and a unit drop-down, seconds by default (S6 p. 215,
  Official, Composer Pro 2.5.3; S5 p. 415 for 3.2.2). A dealer describes LED blinks as colour,
  delay so many milliseconds, black (S14, Dealer), so sub-second units probably exist; the guides do
  not list them. A delay holds every later line of the same script (S21, snippet).
- **Timer agent:** interval in hh:mm:ss, so one-second granularity; Start, Stop, Restart, Reset,
  Pause, Resume and Change from programming; expiry is an event (S5 pp. 391-393, Official).
- **Loops and variables:** While loops exist and must contain delays or they eat the CPU (S5
  pp. 423-424); dealers prefer a repeating timer (S21, snippet). Number variables take "+ n" and
  "If is = n" (S5 p. 440). Homeowner When >> Then automations wait in seconds or minutes (S11).
- **Precision:** a dealer advised timer blinks of at least 2 s, 1 s possible on a fast controller
  (S14, Dealer); a forum reply in S21 says flash timing is not exact. OS 3.3/3.4/4.x programming
  changes were not pursued. Programming cannot reliably beat about one step per second.

## Q3. Field reports

- **No keypad chaser, "Knight Rider", rainbow, progress bar or wave was found** on c4forums,
  DriverCentral, Snap One's documents, or in search results for Reddit r/control4 and YouTube.
- **What people do:** blink one LED with delays of about 100 to 500 ms between colour and black
  (S20, snippet) or with a timer toggling a variable at 1 to 2 s (S14, Dealer); drive backlight or
  LED colours across many keypads from macros (S10, Official, dealer-written; S15), which lagged.
- **Dealer advice found:** timers instead of loops (S21); spread LED changes over groups with delays
  (S15); expect LED updates to queue behind other Zigbee traffic (S15); check the mesh first when
  keypads lag (S22, snippet: lags of 20 s to minutes on unhealthy meshes).
- **Other Zigbee ecosystems:** Inovelli's Zigbee switches with LED bars run their effects ("rising",
  "falling", "aurora") in firmware, and Home Assistant users driving the LEDs one message per LED
  report the network saturating unless they add delays (S34, Hobbyist, snippet). Hue's guidance for
  apps: about 10 light commands per second, 1 group command per second (S33, Vendor).

## Q4. Third-party drivers

| Driver (maker) | What it does with keypad LEDs | How / OS / price | Speed notes |
|---|---|---|---|
| Keypad Button Colors (Whistle Projects) S24 | Per-button colours from a Navigator Extras screen, presets; works with Follow Connection, Programmed, Push/Release; Up/Down hidden | Mechanism not stated; OS not stated; $90 | "Tap and wait, dragging may delay"; do not use the keypads while adjusting |
| Keypad Backlights (Whistle Projects) S25 | Backlight colours per keypad or group | Not stated; $95 | Same dragging warning; brightness follows the ambient profile |
| Keypad Enhancer (Domosapiens) S26 | Sits between keypad and targets; sets LED colours, blinks by programming command, blink colour (v12) | Through the keypad's bindings; $90 | None stated |
| Keypad RGB Tracker (Domosapiens) S27 | Mirrors an RGB light on a keypad LED; 14-step colour sequences for the light | OS 3.3.0+ colour support; $90 | None stated |
| Calendar Wizard (Home Innomations) S28 | Seasonal themes on keypad and switch LEDs (Gen3 and Lux) | OS 3.3.0+; $100; June 2026 | "Ordered, staggered dispatch" of LED updates (20261017) |
| LED Wizard (Control4 driver library) S10 | Backlight colours across many devices from one macro line | Composer macros | Lag reported with several keypads (S15) |

None documents an animation, a frame rate, or whether it addresses keypads by link, proxy or device
id. The only speed evidence is negative: two vendors had to tell users to slow down.

## Q5. Zigbee throughput and the message budget

**Control4's mesh (Official, S9, written for OS 2.6 and HC-250/HC-800 controllers).** Control4 Zigbee
PRO on 2.4 GHz; every extra hop and every retry adds latency; under heavy Wi-Fi interference the
mesh controller waits for a clear channel; firmware updates are limited to three devices at a time
because they are bandwidth-heavy; tested scale is 70 nodes per mesh controller (fewer in larger
projects). No message rate is published.

**Per-message latency (Chip).** TI's large-mesh test: average 40 ms at one hop, 60 at two, 82 at
three, 104 at four, 160 at five (68-byte frames, light load) (S29, read). Silicon Labs publishes
latency only as graphs (S30, read); a trade-press summary puts one-hop Zigbee throughput near 21 kbps
(S31, snippet). Broadcasts are far costlier: each node repeats them and a small table limits them to
about one per second (S32, read), so per-button unicast is the only way to animate.

**Safe rate.** The best public rule for a Zigbee lighting mesh is Signify's: about 10 unicast light
commands per second through one coordinator (S33, Vendor, read). Control4 shares that airtime with
every other device in the house, and forum reports put LED updates behind other traffic (S15).
Planning figures: **peaks of about 10 LED messages/s, sustained 3 to 5/s**, and no backlog ever
allowed to build (drop a frame or a gust rather than queue).

**Unicast or batched.** Whether one `BUTTON_COLORS` becomes one radio frame, or one per colour, is
not public (SDK note; H6). The top-to-bottom sweep users notice (S16) suggests one message per button.

**Cost of a pattern = number of colour edges it moves.** Every step changes only the LEDs at the
pattern's colour boundaries:

| Pattern on five LEDs | Messages per step | Step time at 10/s peak |
|---|---|---|
| One-edge wave (bands of colour rising one LED per step) | 1 | 100-150 ms (perception, not radio, limits it) |
| White band rising through blue | 2 | 200 ms |
| White head, cyan trail, over blue (recommended) | 3 | 300 ms |
| White, cyan, blue comet over black | 4 | 400 ms |
| Every LED changes every step (colour cycle per LED) | 5 | 500 ms |

**Congestion symptoms** to watch during tests: presses on other keypads or lights answering late,
LEDs updating out of order or seconds late, keypads showing stale states (S15, S22).

## Q6. Perceived motion and palette

**Timing.** In Wertheimer's experiments two flashes looked simultaneous at about 30 ms, moved
optimally at about 56-60 ms, and were seen one after the other from about 180-200 ms (S35, Academic,
read). Korte's third law: the further apart the lights, the slower the rate that still gives motion
(S36, Encyclopaedia). Adjacent keypad LEDs are close together, which favours motion, but every step
time the radio budget allows (150-350 ms) is in the "succession" range. So:

- **Overlap carries the motion.** Never hop a single dot: each frame should share lit LEDs with the
  previous one (head plus trail), the way a Larson scanner's trail is made by stepping each LED's
  brightness on every tick (S37 for beta movement; [a Larson scanner tutorial](https://www.baldengineer.com/?p=5501), Hobbyist, snippet).
- **Cadence beats speed.** Radio jitter of tens of milliseconds will show; a steady 300 ms looks
  smoother than a ragged 200 ms. Change only the LEDs that differ, and send the **head first** in each
  step so a late message delays the tail, not the leading edge.
- **Gusts.** Five rows plus entry and exit is a seven-step gust (about 2 s at 300 ms); a random rest
  of 2 to 6 s between gusts fits a breeze and cuts the average load to about 3 messages/s.
- **Easing** is optional: a gust that accelerates upward (for example 350, 300, 260, 230, 210 ms)
  reads as a gust; keep the variation larger than the jitter or it disappears.

**Palette (full components only; luminance from S39, linear sRGB approximation).**

| Role | RGB | Hex | Rel. luminance |
|---|---|---|---|
| Head (white) | 255,255,255 | `#FFFFFF` | 1.00 |
| Pale aqua (optional step between white and teal) | 128,255,255 | `#80FFFF` | 0.83 |
| Teal / cyan (trail) | 0,255,255 (or a greener 0,255,192) | `#00FFFF` / `#00FFC0` | 0.79 / 0.75 |
| Azure (long trail) | 0,128,255 | `#0080FF` | 0.23 |
| Blue (calm air, tail) | 0,0,255 | `#0000FF` | 0.07 |
| Dark | 0,0,0 | `#000000` | 0 |

Avoid low-component "fades" such as `0,0,40`, `0,0,96`, `0,64,128` or `0,128,128` (Q1a). If white
looks blue or green on this keypad, compensate by hue (for example `255,255,224`) not by lowering it.

**Recommended gust** (row 1 = lowest fan button; W white, C cyan, B blue; 14 messages per gust):

| Step | Row 1 | Row 2 | Row 3 | Row 4 | Row 5 | Messages |
|---|---|---|---|---|---|---|
| rest | B | B | B | B | B | 0 |
| 1 | C | B | B | B | B | 1 |
| 2 | C | W | B | B | B | 1 |
| 3 | B | C | W | B | B | 3 |
| 4 | B | B | C | W | B | 3 |
| 5 | B | B | B | C | W | 3 |
| 6 | B | B | B | B | C | 2 |
| 7 | B | B | B | B | B | 1 |

## Recommendations for the design

1. Animate the **five fan buttons** only; leave Up and Down to the light. Let the owner set the
   bottom-to-top order of the five links (a property), since the driver cannot know the rows; default
   to the order H1 finds on the house.
2. Use **hue-only colours** from the palette table, every visible colour sent as the button's lit
   colour; send no brightness and no dimmed colours, so the ambient profile sets intensity.
3. Default pattern: the **white-head, cyan-trail gust over a blue column**, entering with cyan at the
   bottom; **300 ms per step**, a random **2 to 6 s rest** between gusts; let a property tune the
   step time (about 200 to 400 ms) so the owner can find the hardware's limit.
4. Send only changed LEDs, head first; keep the pattern's edges few (Q5 table); never queue: if a
   step is still unsent when the next is due, skip to the next gust.
5. Offer the one-edge **wave** (150 to 200 ms per step) as the "fast and fluid" alternative if H6
   shows the radio copes and the owner prefers it.
6. When Breeze ends, one burst restores every LED to its link state (5 to 7 messages), as today.
7. Consider limiting the animation's duration (for example the first minutes of Breeze, or after a
   press) and holding a still blue column after that, if H7 shows the mesh suffers over long runs.

## Open questions for the hardware (each under a minute)

- **H1 Rows.** Which fan link is on which row, and are Up/Down the split pair at the bottom? Look at
  the keypad, or have the Windows session read the keypad's button list in Composer.
- **H2 Up/Down LEDs.** With the light on, does any LED show beside Up or Down?
- **H3 Palette and scaling.** Put the five buttons in `#FFFFFF`, `#00FFFF`, `#0080FF`, `#0000FF` and
  `0,0,40` (dev loop or programmed colours); look in daylight, then with the room dark. Do the four
  hues stay distinct, does `0,0,40` vanish, does white show a tint, does any button lack a channel?
- **H4 Profile.** Windows session, read-only: the keypad's Ambient Light Profile and, if "Fully
  Customized", its table, including any separate levels for lit and dark LEDs or a level of 0.
- **H5 Feedback.** Room dark, lowest fan button white for 10 s: does the whole keypad brighten, does
  Composer's ambient reading rise?
- **H6 Latency.** Dev loop: change all five LEDs at once and film at 240 fps; measure the gap to the
  first LED and between LEDs. Is one `BUTTON_COLORS` one visible change or two?
- **H7 Load.** Run the gust at 300 ms, then 200 ms, for 30 s each while pressing another keypad's
  light button: do presses or LEDs elsewhere lag?
- **H8** Keypad model and firmware (being read separately): Gen-3 Zigbee or Lux changes Q1a.

## Sources

Official (Snap One/Control4):
S1 [Wireless Keypad Dimmer data sheet](https://control4.com/docs/product/wireless-keypad-dimmer/data-sheet/english/latest) (read) ·
S2 [Keypad Dimmer, Contemporary data sheet rev A](https://docs.control4.com/docs/product/wireless-keypad-dimmer-contemporary/data-sheet/english/latest//wireless-keypad-dimmer-contemporary-data-sheet-rev-a.pdf) (read) ·
S3 [Keypad Buttons Installation Guide](https://www.control4.com/docs/product/keypad-buttons/dealer-installation-guide/english/latest/keypad-buttons-installation-guide-rev-c.pdf) (read) ·
S4 [Keypad Dimmer Installation Guide](https://www.control4.com/docs/product/wireless-keypad-dimmer/installation-guide-120v277v/english/latest) (read) ·
S5 [Composer Pro 3.2.2 User Guide](https://www.control4.com/docs/product/composer-pro/dealer-user-guide/english/revision/X) (read) ·
S6 [Composer Pro 2.5.3 User Guide](https://docs.control4.com/docs/product/composer-pro/dealer-user-guide/revision/M/composer-pro-user-guide-rev-m.pdf) (read) ·
S7 [Composer help: Configurable Keypads](https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/device_settings_for_configurable.htm) (read) ·
S8 [Lighting solutions brochure rev C](https://docs.control4.com/docs/product/control4-lighting-solutions/brochure/english/revision/C/control4-lighting-solutions-brochure-rev-c.pdf) (read) ·
S9 [Zigbee PRO Best Practices and Design Guide](https://control4.com/docs/product/zigbee/best-practices/english/latest) (read) ·
S10 [Programming Tips and Tricks rev D](https://control4.com/docs/product/programming/dealer-tips-and-tricks/english/revision/D/programming-tips-and-tricks-rev-d.pdf) (read; dealer-written) ·
S11 [Programming Solutions Guide rev D](https://control4.com/docs/product/programming/solutions-guide/english/revision/D/programming-solutions-guide-rev-d.pdf) (read) ·
S12 [Lux status and backlight LED programming](https://help.snapone.com/lux-qs/Content/KB%20Topics/Lux%20status%20&%20backlight%20LED%20programming.htm) (read; Lux) ·
S13 [Lux Configurable Keypad driver](https://help.snapone.com/lux-qs/Content/Lux/Lux%20Configurable%20Keypad%20Driver.htm) (snippet; Lux)

C4 Forums (c4forums.com, topic numbers):
S14 [19925 How to make an LED blink?](https://www.c4forums.com/forums/topic/19925-how-to-make-an-led-blink/) (Dealer, read from the Internet Archive, 2016) ·
S15 [43700 Backlight macros for garage door](https://c4forums.com/forums/topic/43700-backlight-macros-for-garage-door/) ·
S16 [28493 Wireless keypad LEDs](https://www.c4forums.com/forums/topic/28493-wireless-keypad-leds/) ·
S17 [39264 Keypad LED turquoise not working](https://c4forums.com/forums/topic/39264-keypad-led-turquoise-not-working) ·
S18 [33291](https://www.c4forums.com/forums/topic/33291-dual-load-wireless-dimmer-issue/), [23888](https://www.c4forums.com/forums/topic/23888-keypad-leds-at-night-not-working-some-brighter-and-new-buttons-not-working/) ·
S19 [29422](https://www.c4forums.com/forums/topic/29422-keypad-dimmer-backlight-behavior/), [34252](https://www.c4forums.com/forums/topic/34252-change-keypad-led-brightness/), [35379](https://www.c4forums.com/forums/topic/35379-led-brightness-on-configurable-keypads/), [28060](https://www.c4forums.com/forums/topic/28060-turning-off-leds-at-night/) ·
S20 [32498 Garage doors and blink LED](https://www.c4forums.com/topic/32498-garage-doors-and-blink-led-color-on-switch-or-dimmer/) ·
S21 [18673](https://www.c4forums.com/topic/18673-loop-controlled-with-variable/), [40165](https://c4forums.com/forums/topic/40165-while-command-missing-from-composer-he), [42035](https://www.c4forums.com/forums/topic/42035-programming-a-delay/), [12228](https://www.c4forums.com/forums/topic/12228-delay-programming-in-he/) ·
S22 [39076](https://c4forums.com/forums/topic/39076-keypads-lagging), [2873](https://www.c4forums.com/forums/topic/2873-ongoing-intermittent-lag/), [14768](https://www.c4forums.com/forums/topic/14768-wireless-keypad-dimmer-gen-3-leds-blink-constantly/) ·
S23 [30201 Backlighting on keypads](https://www.c4forums.com/forums/topic/30201-backlighting-on-keypadsdimmersswitches/)
(all snippet except S14; Forum unless a dealer is named)

Vendors (DriverCentral, read):
S24 [Keypad Button Colors](https://drivercentral.io/platforms/control4-drivers/lighting/keypad-button-colors/) ·
S25 [Keypad Backlights](https://drivercentral.io/platforms/control4-drivers/lighting/keypadbacklights/) ·
S26 [Keypad Enhancer](https://drivercentral.io/platforms/control4-drivers/utility/keypad-enhancer/) ·
S27 [Keypad RGB Tracker](https://drivercentral.io/platforms/control4-drivers/lighting/keypad-rgb-tracker/) ·
S28 [Calendar Wizard](https://drivercentral.io/platforms/control4-drivers/lighting/calendar-wizard)

Zigbee:
S29 [TI SWRA650B, large network test results](https://www.ti.com/document-viewer/lit/html/SWRA650B/test-procedure-and-results-id-b4e39ee4-bda7-4f4b-a032-4fa742363802) (Chip, read) ·
S30 [Silicon Labs Zigbee mesh performance](https://docs.silabs.com/zigbee/8.2.2/zigbee-mesh-network-performance/04-testing-and-results) (Chip, read) ·
S31 [EE Journal: which wireless mesh performs best](https://www.eejournal.com/article/which-wireless-mesh-performs-best) (trade press, snippet) ·
S32 [Digi: delays when streaming broadcasts](https://www.digi.com/support/knowledge-base/why-are-there-delays-when-streaming-packets-in-bro) (Chip, read) ·
S33 [Hue developer FAQ](https://developers.meethue.com/?p=497) (Vendor, read) ·
S34 [Inovelli Blue LED script thread](https://community.home-assistant.io/t/z2m-inovelli-blue-series-switch-led-notification-script-vzm31-sn-vzm35-sn/489620?page=6) (Hobbyist, snippet)

Perception and colour:
S35 [University of Würzburg: Wertheimer's tachistoscope](https://www.uni-wuerzburg.de/en/zgp/archive/video-photo-archive/max-wertheimer-tachistoscope/) (Academic, read) ·
S36 [Korte's third law](https://en.wikipedia.org/wiki/Korte%27s_third_law_of_apparent_motion) ·
S37 [Beta movement](https://en.wikipedia.org/wiki/Beta_movement) ·
S38 [Adafruit: LED tricks, gamma correction](https://learn.adafruit.com/led-tricks-gamma-correction) ·
S39 [Imatest: luminance weights (sRGB, BT.709)](https://www.imatest.com/docs/luminance/) (snippet) ·
S40 [Purkinje effect](https://en.wikipedia.org/wiki/Purkinje_effect) (read)

Internal: S41 [`status.md`](status.md) (house keypad colours, the probe's Button Link rows).
