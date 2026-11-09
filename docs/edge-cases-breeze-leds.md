# Breeze on the keypad LEDs: lifecycle edge cases

> **Research (2026-11-08) for [issue #137](https://github.com/corytron/c4-modernforms-driver/issues/137)**,
> read-only: nothing here was tried on the house. The owner asked that,
> while the fan is in Breeze mode, the keypad buttons bound to the fan play
> an animation rising from the bottom button towards the top in blues, teals
> and whites, like a breeze, and that every LED go back to what it would show
> without it when Breeze ends (Breeze off, or a switch to fan mode), as fast
> and fluid as the hardware allows. The same day the owner decided that **the
> driver animates its own linked buttons** (approach B). This note lists the
> lifecycle corner cases on both sides for B, decides each, and keeps
> Composer programming (A) only as a contrast. The SDK's side (every way to
> change a keypad LED, which source wins) and the field side (the keypad's
> LEDs, Zigbee rates, how few LEDs still look like motion) are the sibling
> notes [`breeze-leds-sdk-research.md`](breeze-leds-sdk-research.md) and
> [`breeze-leds-field-research.md`](breeze-leds-field-research.md), written
> at the same time: where they settle a fact this note marks ASSUMED, they
> win.

**The short answer.**

1. **B handles the corner cases; A cannot.** Only the driver knows what each
   LED must show when the animation ends (the shown target of a press,
   `Speed N Link Also Lit At`, the per-speed colours, Off lit only when
   stopped), and only the driver hears a press, a restart or a binding in
   the same Lua pass in which it can stop the animation (BL5, BL14, BL40).
2. **One rule keeps B from making a later fix harder: the animation touches
   only LED colours the driver can put back.** Those are the speed links'
   per-speed colours (`Speed LED Colors` = `Per speed`). Off, Toggle, Cycle
   and Breeze take the keypad's own colours, which no API can read, so they
   stay out unless H2 shows a passing colour the keypad forgets by itself
   (BL21 to BL24). On the house that leaves Low, Medium, Med-High and High:
   four LEDs, enough for a rising wave.
3. **Off until the owner turns it on.** A new property, default Off; an
   update never starts animating anybody's keypad (BL44).
4. **The driver knows links, not positions.** The order is the speed
   number, with a property for which end is at the bottom (BL25).
5. **Pacing:** one frame changes one link with one message (the colours go
   with a pixel's first lighting); a skipped timer tick drops frames, never
   bursts (BL37, BL38).
6. **The keypad's dimming stays the keypad's.** Frames are full-value
   colours and lit or dark states, so the active and inactive brightness
   and the ambient follower apply to them as to any LED; no brightness is
   baked into a colour, and the Ambient Light Level input is never bound
   (BL61 to BL70).
7. **Hardware** (each under a minute): the physical order, whether colours
   change without a second message, the frame floor, the keypad's request
   after a reboot, the dimming of link colours (section 6).

**Decisions:** **Automatic** (the driver does it by itself), **Offered** (a
property, a Status or Last Action line, the manual, or a step in a brief),
**Forbidden** (not without a click, or not at all where the row says so).
**Markers:** VERIFIED names a primary source (an SDK file, a measurement on
this house, code in this repository); ASSUMED says the claim has none and,
where it matters, names the check of section 6 that settles it. Snap One's
documents are paraphrased, never quoted. Placeholders only: keypad "Example
Keypad" (device 456), room "Example Room", fan item "Aviator 5".

| Key | Source |
| --- | --- |
| KP, API, FUND | `~/c4-tools/reference/docs-driverworks-proxyprotocol-keypad/`, `docs-driverworks-api/`, `docs-driverworks-fundamentals/`, each `source/includes/` |
| V1D | [`v1-design.md`](v1-design.md): section 5 (links and LEDs), V10, V26, V27, and the hardware results K6, K14, K19 of section 11.1 |
| ECC | [`edge-cases-control4.md`](edge-cases-control4.md): F14 to F16, F22, F23, F25, F26, C3, C4, C6, C12, C14, C15 |
| ECB, BFE, BZ | [`edge-cases-breeze.md`](edge-cases-breeze.md) (BC rows), [`edge-cases-breeze-fan.md`](edge-cases-breeze-fan.md) (BF rows), [`breeze-design.md`](breeze-design.md) (BZ and BF-D decisions) |
| MIG | [`migration-design.md`](migration-design.md) sections 1.3 and 1.4 and G9: the house's old LED workaround, painted by programming |
| CR | [`composer-remote.md`](composer-remote.md): "A keypad button follows its link by itself", "Keypad LED commands"; the install rule that a deleted device loses every programming line naming it |
| code | `src/modernforms_fan/fan/links.lua`, `src/modernforms_fan/driver.lua` (`OnDriverDestroyed`), `src/common/device.lua`, as of build 124 |
| DEV | [`dev-loop.md`](dev-loop.md) (the reload sequence) |

## 0. Facts the decisions rest on

| # | Fact | Status |
| --- | --- | --- |
| LF1 | Over a link the driver lights a button with `MATCH_LED_STATE` (on or off colour), sets its colours with `BUTTON_COLORS`, and the keypad asks for both with `REQUEST_BUTTON_COLORS`. | VERIFIED: KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md` |
| LF2 | The house keypad applies `BUTTON_COLORS` over a link (red, then blue while lit); `REQUEST_BUTTON_COLORS` arrives about 3 ms after a bind and a button not answered stays dark. Whether `BUTTON_COLORS` alone, without a `MATCH_LED_STATE` after it, changes a lit button was not isolated (each step sent both). | VERIFIED: house K6 (V1D 11.1); the isolation ASSUMED (H2) |
| LF3 | Colours taken over a link stay on the keypad until set again: the driver's manual says so for a switch back to `Keypad's own`. Whether they also rewrite the colours Composer shows, or live only in the keypad, is not recorded. | Documented behaviour (`www/documentation.html`, `links.lua` `set_colors`); the storage ASSUMED |
| LF4 | Binding a button's link switches its LED Behavior to Follow Connection; Disconnect does not switch it back; no API reads or writes a keypad's button settings (colours, LED Behavior, brightness). | VERIFIED: ECC F16, C4; CR |
| LF5 | The keypad proxy applies a "match LED state" only while the LED tracks a bound device, so a button on Programmed ignores the driver's link LED. | VERIFIED-doc: KP `60_keypad_proxy_commands/_6-KEYPADBUTTONINFO.md`; that the link message behaves the same: ASSUMED |
| LF6 | A Programmed LED command ("Use the on color") still acts on a Follow Connection button; "Set LED On/Off" choose (and keep) the colours a button shows lit or dark; "Set LED Current" shows a colour now. | VERIFIED: house K14 (V1D 11.1); CR "Keypad LED commands"; MIG G9 |
| LF7 | A button's position on the keypad reaches no driver: the keypad's button id, size and colours travel only between the keypad and its own proxy; `OnBindingChanged` gives the keypad's binding id, whose relation to a position is undocumented and which is unknown for bindings made before a restart (`links.lua` keeps them as "?"). | VERIFIED-doc: KP `61_keypad_protocol_notifications/_9-NEW_KEYPAD_BUTTON.md`, `_7-KEYPAD_BUTTON_INFO.md`; API `9_helper/_12-OnBindingChanged.md`; code (`links.lua` `UNKNOWN`) |
| LF8 | The house keypad: Low → Speed 2 (also lit at 1), Medium → 3, Med-High → 4, High → 5 (also lit at 6), Off → Fan Off, Up → Light Top, Down → Light Bottom; Up and Down are Regular Buttons **without an LED**; `Speed LED Colors` = `Per speed` (1 blue, 2 to 5 `#8000FF`, 6 `#ff6000`, off black); Off shows the keypad's own `#800000`. Its physical order bottom to top is not recorded. | VERIFIED: [`status.md`](status.md), MIG 1.4, V1D 5.4 (K19); the order ASSUMED (H1) |
| LF9 | The links today: an LED follows the shown state (wanted over in flight over confirmed, V10) and is sent only when its lit state or colour changes; `BUTTON_COLORS` goes only to a lit speed link under `Per speed` with a valid colour; Off, Toggle, Cycle and Breeze (311) never get colours; `REQUEST_BUTTON_COLORS` and a fresh binding are answered at once with the true state; `set_also` re-sends its link's LED with force. | VERIFIED: code (`links.lua` `lit`, `colour_for`, `push_led`, `answer`, `set_also`, `set_colors`) |
| LF10 | In Breeze mode every speed, Toggle, Cycle and Off LED is dark (Off lights only when the motor is stopped), 311 is lit; on the house every bound fan button is dark during Breeze. | VERIFIED: BF-D2, BFE BF93, code (`links.lua` `lit`) |
| LF11 | Breeze Started and Breeze Stopped fire from the confirmed state, once per change; the `Breeze` variable is seeded from `mf_breeze`, so a restart, update or reboot fires neither. | VERIFIED: BZ3, ECB BC22, code |
| LF12 | A repeating `C4:SetTimer` skips calls when Director falls behind and tells the callback how many it skipped. | VERIFIED: API `34_timer/_1-SetTimer.md` |
| LF13 | Director kills a driver's timers when it is updated, deleted or shut down (`OnDriverDestroyed`). The dev loop's reload calls `OnDriverDestroyed` itself and Director kills nothing, so the driver cancels its own timers there. | VERIFIED: API `22_miscellaneous/_24-OnDriverDestroyed.md`; DEV (reload sequence); code (`OnDriverDestroyed`) |
| LF14 | One message on a link reaches every keypad bound to it. | ASSUMED: ECC C6 (expected; the house has one keypad) |
| LF15 | Keypad LED messages travel over Zigbee. Snap One warns that fast periodic level updates (its example: every 20 ms) flood Zigbee and leave keypad LEDs wrong; the rate a keypad and the mesh carry without delaying other loads is not documented. | VERIFIED-doc: FUND `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`; the rate ASSUMED (the field note; H3) |
| LF16 | Commands, once released, are never removed; properties may come and go. Programming cannot call an action. | VERIFIED: ECC F2; ECB BE9, BE10 |
| LF17 | The Breeze fan (`modernforms_breeze_fan.c4z`) has no Button Links. | VERIFIED: BFE BF24, BF62 |
| LF18 | The house keypad's Control Inputs list an Ambient Light Level row beside its Button Link rows. Control4 added an ambient light source and follower for button backlights in OS 3.2.2 (release notes, as the Hue project read them); no SDK page documents its class, protocol or messages (a search of KP, API and FUND finds no "ambient"). | VERIFIED: house K19 (V1D 11.1); Hue `docs/motion-control4-research.md` section 3.2; the search, 2026-11-08 |
| LF19 | The keypad dims its LEDs itself: a lit button shows its on colour at the active brightness, a dark one its off colour at the inactive brightness (which may be near zero), both set on the keypad in Composer and lowered by the ambient light where that is on. No API reads or writes them (LF4). Whether colours received over a link are dimmed exactly as the keypad's own colours, and how a dimmed low channel renders (vanishes, steps), is not documented. | The two levels: owner, 2026-11-08; the rest ASSUMED (H7) |

## 1. Why not Composer programming (approach A)

A would paint the LEDs from a script on Breeze Started (Delay or a Timer
agent timer and a counter) and put them back on Breeze Stopped. It needs no
release, can paint buttons not linked to the fan, and a driver update does
not touch it. It loses on every case that matters below: (1) putting the
LEDs back needs the driver's LED rules (the pressed target, Also Lit At,
per-speed colours, Off when stopped), so the script would copy them: the 12
Ifs of the "Fan LED Settle" workaround the cutover deleted (MIG I10 to I12);
(2) its events come from the confirmed state and are seeded across restarts
(LF11), so a press races the loop for up to a second and a restart neither
resumes nor cleans; (3) "Set LED On" keeps the frame colour as the button's
own (LF6), so a cut animation leaves Off lit in a teal later; (4) a replaced
keypad deletes every line naming it (CR); (5) no backpressure (LF12 is a
driver API). The guess that A needs LED Behavior Programmed is wrong
(LF6: K14), and Programmed would stop the driver's LEDs for good (LF5): it
is **Forbidden** under either approach. The A column below stays short.

## 2. The model the cases are decided against (B)

- **Trigger:** the shown "Breeze blows" (BZ1: shown `wind` and shown
  `fan_on`), the value link 311's LED already follows; paused while the
  fan device is not online.
- **Pixels:** the speed links 301 to 306 with at least one keypad bound and
  owned colours (`Per speed`, a valid colour for the link's own speed and
  for its Also Lit At speed). Everything else stays out (section 3.4).
- **Order:** by speed number, with `Breeze LED Direction` saying whether
  speed 1 is at the bottom or the top.
- **Frames:** a fixed colour per position (blue at the bottom, teal, light
  teal, white at the top, interpolated for more pixels, each with its
  strongest channel at full value: `0000ff`, `00c0ff`, `80ffff`, `ffffff`),
  sent with a pixel's first lighting; no brightness is ever baked into a
  colour, so the keypad's own dimming applies to every frame (section
  3.9); the motion is lit and dark: the pixels light one by one
  from the bottom, then darken one by one from the bottom, and again. One
  frame changes one link: one `MATCH_LED_STATE`, plus `BUTTON_COLORS` the
  first time that pixel lights in this run. A repeating timer at the period
  `Breeze LED Speed` picks.
- **Put-back:** when the animation ends, every pixel gets `BUTTON_COLORS`
  with its owned colours (the colour of the speed it is lit at, else of its
  own speed; `Speed LED Off Color`) and `MATCH_LED_STATE` with its true lit
  state; the `led` bookkeeping then says what the keypad shows. A second
  pass of states only, 2 s later, catches a late frame.
- **While it runs the animation owns its pixels:** every other path that
  would send a pixel's LED (`links:shown`, `answer`, `set_also`,
  `set_colors`) sends the current frame for that pixel instead.

## 3. Cases

### 3.1 Breeze starts and stops

| ID | Case | The driver (B) | A, for contrast | Decision |
| --- | --- | --- | --- | --- |
| BL1 | Breeze started from Control4: the Breeze fan's tile, Breeze On, Toggle Breeze, link 311, programming | Starts from the shown state at once, as 311 lights (V10) | Starts after the fan confirms (two requests 250 ms apart from stopped, BF42) | **Automatic** |
| BL2 | Breeze started outside: app, remote, wall control | Starts in the poll that sees it (15 s, 2 s in a fast window, BC1) | Same delay, plus the event | **Automatic**; the manual says up to 15 s |
| BL3 | Breeze stored with the motor stopped (Status ` Breeze set`) | Not blowing (BZ1): no animation; the remote's power-on that resumes it is seen at the poll | Same | **Automatic** |
| BL4 | Breeze ends to stopped: keypad Off, the Breeze fan off, Breeze Off, 311, app, remote | Same Lua pass: timer cancelled, put-back (all pixels dark), then the normal pass lights Off in the keypad's own colour, untouched by the animation | The script's "Off" repaint and the driver's Off LED arrive in either order (both act, LF6) | **Automatic** |
| BL5 | Breeze ends to fan mode by a speed: keypad button, the main tile, a schedule, a Double Tap line, the remote | Put-back lights the right link in its per-speed colour, Also Lit At included (Low blue at 1, High orange at 6) | Needs the 12-If logic in programming | **Automatic**; **Forbidden**: rebuilding the settle workaround in programming |
| BL6 | A quick off and on: Breeze 2, off, Breeze 1 in a second; two Toggles | Put-back at the off, frame 0 at the on: a short blink. One timer per driver | A Delay loop still running when Started fires again doubles: two loops pass "If Breeze is on" for good | **Automatic**; **Forbidden**: a second animation timer |
| BL7 | Breeze On while it blows; Breeze Off while it does not (sent anyway, V8) | "Blows" does not change: nothing restarts | No event | **Automatic** |
| BL8 | A Breeze command refused or failing (offline, foreign, no Breeze) | The shown state goes to the target and back: a short start, then an exact put-back | Nothing | **Automatic** |

### 3.2 While Breeze blows

| ID | Case | The driver (B) | A, for contrast | Decision |
| --- | --- | --- | --- | --- |
| BL9 | Strength 1 to 3 changes (the Breeze fan, Set Breeze Strength, the app) | With `Breeze LED Speed` = Follow strength, the next tick uses the new period; no restart, no jump | Only the Breeze fan's speed_changed (BF43) | **Offered** (the property); **Automatic** once chosen |
| BL10 | Gusts move `fanSpeed` | Not reported (BZ8): no LED change | Same | **Automatic** |
| BL11 | The fan goes offline in Breeze (about 45 s of failed polls) | Pauses and puts back: the steady Breeze picture (pixels dark, 311 lit), which is what "the LEDs keep the last state" (V1D 5.1) means without the embellishment; a fan that lost power at the wall switch is not shown blowing, and the mesh is spared | Runs on unless the script also hears Fan Offline | **Automatic**; the Rebooting phase (Reboot Fan) alike |
| BL12 | Back online still in Breeze | Resumes at frame 0 after the first contact | Nothing fires (no change) | **Automatic** |
| BL13 | Back online in fan mode or stopped | The normal LEDs from the first contact's refresh; no animation | Breeze Stopped fires (R8) | **Automatic** |

### 3.3 Presses during the animation

| ID | Case | The driver (B) | A, for contrast | Decision |
| --- | --- | --- | --- | --- |
| BL14 | A speed button: fan mode at that speed (BF80) | The push changes the shown state; the same pass cancels the timer, puts back and lights the pressed button at once (V10) | The loop keeps painting until Breeze Stopped, up to a second later, over the button the driver just lit | **Automatic** |
| BL15 | Off pressed: the motor stops (BF94) | As BL4 | Race as BL4 | **Automatic** |
| BL16 | Low's and High's double taps (two pushes, then the keypad's Double Tap line: Level 1 or 6) | Ends at the first push; the next two changes are ordinary LEDs | Races three times | **Automatic** |
| BL17 | A press refused or failing (tried once while offline) | Shown flips and comes back: put-back, then the pause of BL11 if offline | — | **Automatic** |
| BL18 | A hold (push, release, no click, K6) | As the push | — | **Automatic** |
| BL19 | Echo LED On Press, where set on the keypad | The button lights at the push and darkens at the release (K6), over a frame, until the next frame or the put-back | — | **Automatic** (the keypad's); **Forbidden**: the driver changing it |
| BL20 | Up and Down (the light) | The light changes; the animation goes on; their LEDs are not the fan's (BL24) | — | **Automatic** |

### 3.4 Which buttons, in which order

| ID | Case | The driver (B) | A, for contrast | Decision |
| --- | --- | --- | --- | --- |
| BL21 | Speed links 301 to 306 | Join when bound and their colours are owned (section 2); on the house 302 to 305 | The owner's choice | **Automatic** |
| BL22 | Off (300), Toggle (307), Cycle (308): dark in Breeze, the keypad's own colours | Out: a colour painted on them could not be put back (LF3, LF4), and the owner would find Off lit in white after the fan stops. They may join only if H2 shows a passing colour that a `MATCH_LED_STATE` replaces with the keypad's own, or a later row gives the driver their colours | Can paint them, and leaves the frame colour as theirs (LF6) | **Forbidden** without H2 or owned colours; **Offered** after H2 |
| BL23 | Fan Breeze (311): lit in Breeze, the keypad's own colours | Out: it is the steady "Breeze is on" button; blinking it removes that meaning, and its colours are not owned | — | **Automatic** (stays steady) |
| BL24 | The light's links 200 to 202 (Up and Down on the house) | Out: no LED on the house (LF8); elsewhere their LEDs show the light (`common/device.lua`) | Could paint them where they have LEDs | **Forbidden** |
| BL25 | The order: the driver knows links, not positions | By speed number, with `Breeze LED Direction` = "Speed 1 at the bottom" or "Speed 1 at the top" (a fan keypad lists its speeds in order); the house's default set by H1 | Names buttons, so knows positions | **Offered** (the property) |
| BL26 | A free-form order (a list of links) | Error-prone text in Composer, for a layout no fan keypad has | — | not built; a property can come later (LF16) |
| BL27 | Asking the keypad for positions | No documented call (LF7); the binding id is unknown after a restart | — | **Forbidden** to depend on |
| BL28 | Gaps: a keypad without Speed 1 or 6, links not bound | Positions count only the pixels, so the wave has no pause | — | **Automatic** |
| BL29 | Several keypads laid out the other way round | One direction per driver: on that keypad the wave runs down | Per keypad | **Offered**: the manual says so |

### 3.5 Settings changed while it runs

| ID | Case | The driver (B) | A, for contrast | Decision |
| --- | --- | --- | --- | --- |
| BL30 | `Breeze LED Animation` set Off while running | Put-back at once | Disabling the Started script leaves a running timer; disabling both leaves frames for good | **Automatic** |
| BL31 | Set On while Breeze blows | Starts at once | — | **Automatic** |
| BL32 | `Breeze LED Speed` changed (Slow, Medium, Fast, Follow strength) | The timer is re-armed with the new period; the frame count is kept | Edit every Delay | **Automatic** |
| BL33 | `Breeze LED Direction` changed | Put-back, then frame 0 with the colours per position re-sent as the pixels light | — | **Automatic** |
| BL34 | `Speed N LED Color` or `Speed LED Off Color` changed | Frames unaffected (they use the position colours); the put-back uses the new values. A colour made invalid takes its link out: that pixel is put back with the colours it last had, then the wave restarts on the rest | Programming keeps the old colours | **Automatic** |
| BL35 | `Speed LED Colors` set to `Keypad's own` | Every pixel is put back with its last owned colours (the keypad keeps them, as the manual already says of that switch), then the animation stops; Status or Last Action says the animation needs `Per speed` (or not, after H2) | — | **Automatic**, the line **Offered** |
| BL36 | `Speed N Link Also Lit At` changed | Today's forced re-send would darken a lit pixel; while running it sends that pixel's frame instead; the put-back follows the new rule; the pixel set is recomputed when it changes eligibility | — | **Automatic** |

### 3.6 Keypads, links and the mesh

| ID | Case | The driver (B) | A, for contrast | Decision |
| --- | --- | --- | --- | --- |
| BL37 | Pacing | One frame changes one link with one message (`MATCH_LED_STATE`), and `BUTTON_COLORS` before it only on a pixel's first lighting in a run; at most one frame per tick; a skipped tick drops frames (LF12), never a burst; the period never below the floor H3 finds (proposal: 500 ms until then); the put-back (two messages per pixel, as a first-contact refresh already sends) is the only burst | Every frame a burst of commands that queue; no skip | **Automatic** |
| BL38 | Hours of Breeze (a night in the bedroom) | At 500 ms, two messages a second to each bound keypad for the whole time (LF14, LF15) | Same or worse | **Offered**: continuous (as asked) or a few rising passes then a still gradient (question 1, section 7) |
| BL39 | Several keypads on one link | One message per link reaches every bound button (LF14): all play in step at no extra cost in the driver; the mesh carries one copy per keypad (ASSUMED) | One set of lines per keypad | **Automatic** |
| BL40 | `REQUEST_BUTTON_COLORS` mid-animation (a keypad rebooting or rejoining) | For a pixel, the current frame (its position colour and frame state), not today's true-state answer (dark), which would leave it dark until its next change; every keypad on the link gets it, harmlessly | The keypad shows whatever it kept | **Automatic** |
| BL41 | A link bound mid-animation | `REQUEST_BUTTON_COLORS` follows in milliseconds (K6) and gets the frame as BL40; a new pixel restarts the wave on the new set | Nothing until programming names it | **Automatic** |
| BL42 | A link unbound mid-animation | The button keeps its last LED (ECC C4), maybe lit in a frame colour that is now its stored colour; the driver can no longer reach it. A link with no keypad left leaves the set and the wave restarts | Same | **Offered**: the manual says to set the button's LED Behavior and colours on the keypad after a Disconnect, as it already does |
| BL43 | A keypad replaced, rebooting, unpowered or off Zigbee mid-frame | Frames to it are lost (ASSUMED); a new keypad's bindings ask and get BL40's answer; a returning keypad gets it only if it asks (H4). Left colours are only owned slots, and a speed link always gets its colours before it lights, so the next lighting heals them | A replaced keypad loses every line naming it (CR) | **Automatic** |

### 3.7 Reloads, updates, restarts and restores

| ID | Case | The driver (B) | A, for contrast | Decision |
| --- | --- | --- | --- | --- |
| BL44 | The update that brings the feature to existing devices | `Breeze LED Animation` defaults to Off; nothing animates until a click. The house turns it on in the install brief | — | **Forbidden**: on by itself |
| BL45 | Dev-loop Lua reload mid-animation | Director kills no timer (LF13): `OnDriverDestroyed` must cancel the animation timer, or the old code keeps painting beside the new one, with nothing left to cancel it. LEDs: the last frame until the new code's first contact, then put-back and resume | — | **Automatic**; a spec covers the cancel |
| BL46 | Driver update in place mid-animation | Timers die (LF13); `OnDriverDestroyed` tries a put-back of states (best effort, in `pcall`; whether it is delivered then is H5); the new code's first contact puts back every pixel (it cannot know which frame was cut), then resumes | The script runs on | **Automatic** |
| BL47 | Director restart or controller reboot | As BL46; while Director is down (about 7.5 minutes for a reboot, ECC F26) the keypad keeps the last frame, or the steady picture if the best-effort put-back arrived | Seeded events: no resume, frame colours left (LF11) | **Automatic** |
| BL48 | Rollback to a build without the feature | Its first contact darkens the pixels; left colours are owned slots, healed at the next lighting (BL43) | — | **Automatic** (harmless by the colour rule) |
| BL49 | Composer project restore from a backup | The properties come back with the project (ECC F25); the first contact paints from the state. A backup from before the feature is BL48 | The scripts as in the backup | **Automatic** |
| BL50 | What persists | Only the new properties; no frame, no "was animating" flag (the first contact puts back anyway) | — | **Forbidden**: persisting animation state |

### 3.8 Other writers and surfaces

| ID | Case | The driver (B) | A, for contrast | Decision |
| --- | --- | --- | --- | --- |
| BL51 | The owner puts a button on Programmed, or changes its colours on the keypad | Frames no longer show on a Programmed button (LF5), nor does its fan LED: the owner's choice wins. Colours set on the keypad are overwritten for owned links, as `Per speed` already does | — | **Forbidden**: the driver touching keypad settings (LF4) |
| BL52 | Programming or another driver lighting the same buttons | The last writer wins; the next frame paints over during Breeze, the put-back after it | — | **Offered**: the manual says the animation owns those buttons while Breeze blows |
| BL53 | The keypad's LED brightness and ambient dimming | Section 3.9 | — | see BL61 to BL70 |
| BL54 | Off at night, or only when someone is in the room | Programming cannot set a property or call an action (LF16) | Natural in programming | **Offered later**: a command `Set Breeze LED Animation` (approach C), only if the owner asks, since a command is forever; **Forbidden**: a schedule inside the driver (automations live in Control4) |
| BL55 | Debug Mode on | Per-frame sends would flood the log the dev loop ships back | — | **Automatic**: log start, stop, pause and skips, not frames |
| BL56 | Navigators or the app showing keypad LEDs | If a keypad view mirrors colours, it animates too, late (ASSUMED) | Same | **Offered**: H6 |
| BL57 | A fan without Breeze; the property On | "Blows" never true; nothing runs; Status or Last Action says the fan has no Breeze | — | **Automatic** |
| BL58 | The property On, no pixel (no speed link bound, or `Keypad's own`) | Nothing runs; one line says why | — | **Automatic**, the line **Offered** |
| BL59 | The Breeze fan's own buttons | It has no Button Links (LF17); buttons programmed on it are the keypad's | The owner's | **Automatic** (untouched) |
| BL60 | Two fans in Breeze, one keypad with buttons for both | Each driver animates its own links: two waves | — | **Automatic** |

### 3.9 The keypad's own dimming (ambient light, active and inactive brightness)

The owner's requirement (2026-11-08): the animation reflects and respects
the keypad's LED dimming. The way to honour it is to leave it entirely to
the keypad: the driver sends colours and lit or dark states only, the same
two states every other LED uses, and the keypad applies its brightness to
both (LF19).

| ID | Case | The driver (B) | A, for contrast | Decision |
| --- | --- | --- | --- | --- |
| BL61 | The room goes dark or light while the wave plays | Nothing: the keypad lowers or raises every LED itself, frames included; the wave goes on at the keypad's brightness of the moment | Same | **Automatic** (nothing to do); **Forbidden**: the driver following the room's light |
| BL62 | Active against inactive brightness | The motion is lit and dark, so a lit pixel shows its position colour at the active brightness and a dark one the off colour (`Speed LED Off Color`, black on the house) at the inactive brightness: near zero, the wave reads as light rising and falling; higher, a non-black off colour would glow there too | A "Set LED Current" frame bypasses the two states (LF6) | **Automatic** |
| BL63 | A fade or trail made by sending darker RGB (`003040` for a dim teal), or colours chosen by time of day | Would be dimmed again by the keypad (double dimming), vanish at night and fight the owner's settings | Same temptation | **Forbidden**: baking brightness into a colour, or any colour that depends on the room, the hour or the keypad's level |
| BL64 | Low RGB values that vanish or step when dimmed | Every position colour keeps its strongest channel at full value (LF19 ASSUMED, H7); positions differ by hue and saturation, not by value; interpolated colours too | — | **Automatic** (fixed palette) |
| BL65 | A trail in the off colour (a pale blue left behind the wave) | Possible within the rules (the off colour is owned for speed links and put back), and it would follow the inactive brightness; not in the first build | — | **Offered** later, if the owner asks |
| BL66 | The owner changes the active or inactive brightness, or the ambient follower, in Composer mid-animation | The keypad applies it; the driver neither knows nor needs to; nothing restarts | — | **Automatic**; **Forbidden**: reading or re-sending them (no API, LF4) |
| BL67 | Several keypads in different light levels on one link | One message per link (LF14); each keypad dims its copy itself: in step in time, each at its own brightness | Per keypad lines, same result | **Automatic** |
| BL68 | The put-back and the normal LEDs | Colours and states only, as today: the keypad's dimming applies unchanged after the animation | — | **Automatic** |
| BL69 | A keypad without an ambient sensor, or with the follower off | Shows the active and inactive levels as set; nothing differs for the driver | — | **Automatic** |
| BL70 | The keypad's Ambient Light Level input (Control Inputs) | Not bound, not read, not offered: its class and protocol are undocumented (LF18), the driver must not invent a protocol, and a binding from the fan would take the input a real light sensor may need later | — | **Forbidden**; revisit only if Snap One documents it |

## 4. Verdict

B, as the owner decided, and the cases confirm it. The deciding ones:
**BL5 and BL14** (only the driver can put the LEDs back right, and it stops
the animation in the pass that lights a press); **BL47** (after a restart
the driver repaints and resumes, where seeded events leave A frozen);
**BL43** (a replaced keypad keeps working without new lines); **BL6 and
BL30** (one timer, stopped by a property); **BL37** (backpressure from the
timer's skips). A's only gains are no release and buttons outside the
fan's links; C is B plus one command later, if the owner wants programming
to switch it (BL54).

## 5. For the contract

1. Trigger, pause and pixels as section 2; the light links, 311, and Off,
   Toggle and Cycle out (Off, Toggle, Cycle may join only after H2).
2. Properties (removable later, unlike commands): `Breeze LED Animation`
   Off (default) / On; `Breeze LED Speed` Slow / Medium / Fast / Follow
   strength, periods from H3; `Breeze LED Direction` Speed 1 at the bottom
   / at the top, the house's value from H1.
3. Frames and pacing as BL37; put-back as section 2, also at every first
   contact while the property is On, and best effort in `stop()`.
4. While running, the animation owns its pixels' LEDs (BL36, BL40, BL41);
   the `led` bookkeeping matches the keypad after every put-back.
5. `OnDriverDestroyed` cancels the timer (BL45); nothing new persists;
   no new command, event or variable; logs as BL55.
6. Colours: the fixed full-value palette of section 2; never a colour
   scaled for brightness, room light or hour; the Ambient Light Level input
   untouched (BL63, BL64, BL70).
7. The manual: what it does, which buttons, the direction, that the
   keypad's own active and inactive brightness and ambient dimming apply
   (set them on the keypad), programming that lights the same buttons, a
   Disconnect mid-animation.

## 6. Questions only the hardware can settle (each under a minute)

| # | Test | Who | Settles |
| --- | --- | --- | --- |
| H1 | Which of Low, Medium, Med-High, High is lowest on Example Keypad, and whether Up and Down sit below them | Windows session from Composer's keypad view, or the owner's glance (10 s) | BL25's default |
| H2 | On one lit speed link: `BUTTON_COLORS` alone with a new colour (does it change?); then `BUTTON_COLORS` with the stored on and off colours and `CURRENT_COLOR` teal (does it show teal?), then `MATCH_LED_STATE` true (back to the stored colour?) | dev loop on a feature build; the owner watches (30 s) | BL22, one message per colour change (BL37) |
| H3 | The rising wave at 1000, 500, 250 and 150 ms per frame, 10 s each; at the fastest the owner taps Up to see that the light still answers at once | dev loop; the owner (50 s) | the floor and the speed choices (BL37, BL32) |
| H4 | The Windows session reboots Example Keypad from Composer, if it offers that; does `REQUEST_BUTTON_COLORS` arrive (dev-loop log)? | Windows session (about 1 min) | BL40, BL43 |
| H5 | At the next update during Breeze: steady picture or frozen frame during the update? | the owner's glance at an install already planned | BL46 |
| H6 | Does the Control4 app show the keypad's LEDs during H3? | the owner (10 s) | BL56 |
| H7 | During H3 the owner covers the keypad's light sensor with a hand for 10 s (or the Windows session lowers the active brightness and sets it back): does the wave dim with the rest, and does the blue at the bottom stay visible at the lowest level? | the owner, or the Windows session and the owner's glance (20 s) | LF19, BL61, BL64 |

Parked under "no long test waits": two keypads on one link (the house has
one), a night of Breeze and the mesh, an OS 4 controller.

## 7. Questions for the owner

1. **Continuous, or a few rising passes then a still gradient?** The
   request says continuous; a night of Breeze then sends two messages a
   second to the keypad for hours (BL38). Default proposed: continuous at
   the H3 floor, the still gradient as a later choice of `Breeze LED
   Animation`.
2. **Off in the wave?** Only if H2 shows a passing colour; otherwise it
   stays out (BL22), and the wave runs over the four speed buttons.
