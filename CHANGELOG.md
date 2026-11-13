# Changelog

Every published release of the Modern Forms Fan driver, newest first, with
what changed since the release before it. A version X.Y is the GitHub
release of the tag `vX.Y`. A version can be released as several builds: the build
number is the commit count of the released commit and the Driver Version
that Composer shows for every device, and each newer build of a version
replaces the files of its release. Prereleases for testers (X.Y-beta.N),
development builds and builds installed only for tests are not listed; the
next release's entry carries what they changed.

## Unreleased

## 1.9 "Sandwalk", build 220 (2026-11-13)

### Added

- The speed chase and the Breeze animation can pause while the keypad's LEDs are dark, so they stop sending frames over Zigbee that nobody can see. Bind a keypad's Ambient Light Level (Source) output to the fan's new Ambient Light Level (Follower) input in Composer's Connections. Set that keypad's Status LED Min Brightness to 0 and the new `Pause LED Animations Below` to its Dark Room value (10 by default). While the keypad reads darker than that, nothing animates. The selected speed's LED still follows the fan. When the room has been light for 10 s, a new chase starts. With nothing bound, nothing changes. The keypad sends its reading only when it changes. The connection is not in Control4's driver documentation; it was measured on a Control4 keypad dimmer on OS 3.4. No controller reboot (#207).

## 1.8 "Carryall", build 207 (2026-11-13)

### Added

- `Light Min On (%)` on the fan's Properties page, for a light kit that stays dark at its lowest levels: set it a few points above the first level at which the light glows, and Control4's 1 % becomes that level, the way Min On trims a Control4 dimmer. A fade, a hold, a tap, the slider and a scene then light the light from their first step, and a dim down stops at the lowest lit level instead of going dark early. 0, the default, changes nothing. Fade, tap and hold times stay the same. A level set in the Modern Forms app, the remote or the wall control below Min On shows in Control4 as 1 % and is never changed. The Status row shows both levels, as "light 40 % (fan 52)", and the Documentation tab has a "Light Min On" section. No controller reboot (#195).

## 1.7 "Stillsuit", build 193 (2026-11-10)

### Changed

- The keypad LED settings (the Also Lit At rows, the per-speed colours, the Breeze LED rows and the speed chase rows, 20 rows in all) show in Composer only while a button is bound to one of the fan's speed links; without one they are hidden, keep their values and do nothing, and they come back as soon as a button is bound. The Breeze-only rows also hide on a fan without Breeze. `Keypad Links` says whether they are shown, a binding that shows or hides them writes a Last Action line, and the Documentation tab has a "Keypad LED settings" section for both cases, with how to turn each animation off (#178).

### Fixed

- Unbinding a keypad button from a fan link now takes the keypad off `Keypad Links` and out of the LED animations even when Director answers with nothing bound; before, the keypad could stay listed for good (#185).

## 1.7 "Stillsuit", build 188 (2026-11-10)

### Changed

- The speed LED chase starts sooner and repeats more often: its first chase now comes 2.5 s after a speed is selected, from any source (a keypad, a Navigator, programming, the Modern Forms app, remote or wall control, the last three once the driver's next poll sees them), and then one every `Speed LED Rest (s)`, whose default is now 5 s (it was 10; an installed fan keeps the value it has) (#177).

## 1.6 "Crysknife", build 182 (2026-11-10)

### Changed

- The speed LED chase no longer blinks the selected button twice at the keypad's edge speeds: when the dot starts on the selected button (on a keypad with the lowest speed at the top and the fan blowing down, speed 2) that button stays lit as the dot's first position, and when the dot ends on it (speed 5) it stays lit into the rest (#172).

## 1.6 "Crysknife", build 176 (2026-11-09)

### Added

- A chase on the keypad's speed LEDs at a fixed speed: with `Speed LED Colors` set to Per speed and the new `Speed LED Animation` set to `Speeds 2 to 5` (or `Speeds 1 to 6`), a dot in the selected speed's colour runs across the bound speed buttons, one after the other, in the direction the fan blows, faster at higher speeds (one button every 0.4 s at speed 2, 0.12 s at speed 5); between chases, for the same time at every speed (`Speed LED Rest (s)`, 10 s by default), the selected speed's LED is lit as before. Off by default; Breeze, Off, the fan going offline or the keypad's own colours stop it at once. About 13 messages to the keypad per chase with four buttons; no controller reboot (#159).

### Fixed

- During Breeze on the keypad LEDs, loading the next colour into a dark speed button now sends only the button's on and off colours, as the design says, instead of also its current colour (no difference was seen on the house; #164).

## 1.5 "Shadout Mapes", build 165 (2026-11-09)

### Added

- The fan's light now fades, as a Control4 dimmer does, in steps the driver sends to the fan (the fan has no fade of its own). A tap on a bound Light Top, Light Bottom or Light Toggle fades over the light's new Click Rates (3 s from off to full by default, so a tap from 50 to 100 takes 1.5 s); a second tap, after the keypad's double-tap time, stops the fade where it is; a double tap is the keypad's own event and changes nothing. Programming's On, Off, Toggle and Set Level, and the Navigators' on and off taps, use the light's Default Brightness Rate (set it to 3 s on the light's settings page to match the taps); a ramp or fade time in programming or an Advanced Lighting Scene is honoured; the Navigator slider still jumps. Holds use the same fade at the hold rates, in finer steps. Over 3 s a fade is about 7 to 18 steps, the most the fan takes; a rate of 0, or a fade under about a second, is instant. A fade ends at once if the fan's app, remote or wall control turns the light off, and never turns it back on; after a fade to off the app and remote turn the light on at the level it had before. The update adds Click Rates to the light's settings page, which needs one controller reboot from System Manager (#141).

### Changed

- The manual's chapter on fades and holds is rewritten for the fades above (#141).

## 1.4 "Sietch Tabr", build 152 (2026-11-09)

### Added

- Breeze on the keypad LEDs: with the new property Breeze LED Animation set to `Gusts`, the buttons bound to the fan's speed links (Fan Speed 1 to 6) play gusts while the fan blows in Breeze mode, every speed button dark between gusts and every few seconds a gust: a white front running along the buttons the way the fan blows (down while it blows down, up in reverse) with a twinkling tail of ice, teal and sky blue that travels with it and follows it off the end of the column, more often and with a longer tail at a higher Breeze strength. The buttons go dark when Breeze starts and an ending wipe plays once, the other way, when it ends, whoever started or ended it (a keypad, a Navigator, the Modern Forms app, the remote, programming), and a pressed speed button lights as the ending wipe passes it. Fan Off, Toggle, Cycle and Breeze buttons and the light's buttons never animate. It needs Speed LED Colors set to `Per speed` (otherwise Last Action reads `Breeze LEDs need Speed LED Colors set to Per speed`). The driver cannot see where buttons sit on the keypad, so it orders them by speed number, and Breeze LED Bottom (`Lowest speed` or `Highest speed`) says which end is at the bottom; Breeze LED Step (ms), 60 to 400 (default 120), sets the pace. Between sunset and sunrise at the project's location (worked out on the controller, no programming and no internet) the animation runs at Breeze LED Night Brightness (%), 10 to 100 (default 50), of its daytime strength, since blues and whites stand out in a dark room; the buttons return to exactly what they showed when Breeze ends. It changes colours only, never pure blue (which a keypad dimmed for the night barely shows), so the keypad's own LED brightness and its dimming by the room's light apply. Off by default; the update needs no controller reboot (#137).

## 1.3 "Ornithopter", build 124 (2026-11-08)

### Added

- The Breeze fan for the Navigators, a new package, `modernforms_breeze_fan.c4z` (driver "Modern Forms Breeze Fan"): a fan with three speeds, Breeze 1, Breeze 2 and Breeze 3, listed with the room's fans. A speed starts Breeze at that strength (a stopped fan starts straight in Breeze), On resumes the fan's last strength, and Off ends Breeze. Its tile shows only what the fan has confirmed and keeps its last value while the fan is offline. The fan's action Add Breeze Fan adds it to the fan's room, named after the fan (for example "Aviator 5 Breeze"); put it after the fan in the room's order and refresh the Navigators (#121).

### Changed

- The fan runs either in fan mode or in Breeze mode, never both, and the fan device now shows fan mode only: while Breeze blows its tile shows off, its speed, Toggle and Cycle keypad LEDs are dark, and the Fan Off LED lights only while the fan is stopped. Status reads `Breeze 2` instead of a speed in Breeze mode. A fan without Breeze works as before (#121).
- The fan device's own events and variables (turned off, speed changed, Is Off) follow fan mode, so they now also fire when Breeze starts or ends: add the condition "Breeze is on" with False to programming that should not react to Breeze. The fan device's direction is held while Breeze blows (#121).
- A speed, On, Toggle or Cycle on the fan device ends Breeze, and Off on the fan device stops the fan and clears a stored Breeze, so the next start is fan mode (#121).
- **Breeze Off and Toggle Breeze keep their names but now stop the fan while Breeze blows**; in 1.2 they left it turning. To go from Breeze back to fan mode, set a speed on the fan device. On a stopped fan they only clear a stored Breeze, and they never stop a fan in fan mode. A double tap on a button bound to Fan Breeze, from fan mode, now stops the fan on its second press (#121).
- Breeze On and the Fan Breeze link start a stopped fan straight in Breeze at its last strength (Breeze first, then the fan on) instead of starting it at the preset speed first (#121).
- The action Add Breeze Switch is now Add Breeze Fan, and the Breeze switch of 1.2 (`modernforms_breeze.c4z`, a light) is no longer part of the release. An owner who added one deletes it, then clicks Add Breeze Fan; until then Add Breeze Fan answers `Delete the old Breeze switch first: Aviator 5 Breeze`. Programming that named the old switch goes with it: rebuild it on the fan device's Breeze commands and events. The update needs no controller reboot (#121).

### Known limits

- "All fans on", or a scene that turns every fan on, gives the fan device and the Breeze fan contradictory targets, and the last to arrive wins: keep the Breeze fan out of such groups. "All fans off" is safe. Programming that turns one of the two devices on when the other turns off switches the fan back and forth between the modes. The remote's power button during Breeze may keep Breeze stored on the fan, so its next power-on resumes Breeze (#121).

## 1.2 "Thumper", build 115 (2026-11-07)

### Added

- The driver finds Modern Forms fans on the network by itself: a few seconds after it starts or is updated, and, while the device has no fan yet, again after 30 seconds, 1, 2, 5 and 10 minutes and then every 15 minutes. Found Fans fills by itself, its first line says what was found, and this device's fan is listed first. The search is one multicast DNS question on the controller's own network segment: it never takes a fan by itself and never writes Last Action (#102).
- Breeze from Control4, on Gen 3 fans that have it: the programming commands Breeze On, Breeze Off, Toggle Breeze and Set Breeze Strength (1, 2 or 3), the variable Breeze, the events Breeze Started and Breeze Stopped and the condition "Breeze is on", which all mean that the fan runs with Breeze. A new Button Link, Fan Breeze, toggles Breeze from a keypad button and lights its LED while Breeze blows, and Status shows the strength (`Breeze 2`), or `Breeze set` while the fan is off. Breeze On starts a fan that is off at its preset speed first; a speed change, Off or Toggle never switches Breeze off by itself. A fan without Breeze refuses the commands with a Last Action line. The update installs in place, with no controller reboot and no new fan device (#111).
- The Breeze switch for the Navigators, a new package, `modernforms_breeze.c4z`, because Control4's fan tile cannot show Breeze: the new action Add Breeze Switch, the sixth on the fan item, adds an on/off switch named after the fan (for example "Aviator 5 Breeze") to the fan's room, lit while Breeze blows; a tap toggles Breeze. Install both packages, click the action, then refresh the Navigators; keep the switch out of "all lights" groups, since off ends Breeze while the fan keeps turning (#111).

### Changed

- Picking a fan in Found Fans and clicking Set takes that fan at once, with the same result as Use Selected Fan: Fan Address is filled in and the items are named after the fan as before. A different fan picked on a device that already has its fan waits for Use Selected Fan (#102).
- The Find Fans action is gone: five actions remain, Use Selected Fan first. Status on a device without a fan reads `Not set up: pick a fan in Found Fans, or enter Fan Address`. Programming and connections are unchanged, and the update needs no controller reboot (#102).

## 1.1 "Jamis", build 97 (2026-11-05)

### Fixed

- Keypad Links keeps a keypad on a link while another of its buttons is still bound to that link: until now, disconnecting one of two buttons of a keypad from the same link took the keypad off the row and out of the count, though the other button kept working (#92).

## 1.1 "Jamis", build 87 (2026-11-05)

### Added

- The fan and its light have the driver's own icons in Composer: a five-blade ceiling fan and a drum-shaded ceiling light. A device keeps the icons it was created with, so one added with build 73 or earlier keeps Control4's own (#78).

### Changed

- The Fan Cycle Button Link stops at Level 6, as the fan's own Cycle Speed Up does: from off it goes to Level 1, then one speed up per press, and at Level 6 it stays there instead of starting again at Level 1 (#77).

## 1.0 "Arrakis", build 73 (2026-11-05)

### Fixed

- Fan Model shows Breeze from the moment the driver starts, before the fan first answers; until now it lacked it for the first seconds after a restart or an update (#69).

## 1.0 "Arrakis", build 67 (2026-11-05)

### Added

- First build of the Modern Forms Fan driver (`modernforms_fan.c4z`), for fans with six speeds (Gen 1 to 3): one device per fan with the fan's speeds, on and off and direction, and its light with dimming, in Control4 programming, the Navigators and the keypads (#26).
- Keypad buttons bind to the driver's own Button Links, one for each speed, Off, Toggle and Cycle and one each for the light's Top, Bottom and Toggle, and their LEDs follow the fan and the light; a speed link can also stay lit at one more speed, so a button whose double tap sets another speed keeps its LED (#26).
- A fan is added by typing its address, or with Find Fans, which lists the fans that answer on the network; the driver remembers which fan it is and refuses a different fan at that address until Use Selected Fan accepts it. Status, Last Action and the other rows say what the driver sees, and Fan Offline and Fan Online are events for programming (#26).
- Speed LED Colors: set it to `Per speed` and the fan's speed links show a colour for each speed on a keypad button (for example blue at Level 1 and orange at Level 6), with Speed 1 LED Color to Speed 6 LED Color and Speed LED Off Color; by default the keypad's own colours stay (#31); the Documentation tab says how Composer's colour rows are set (#55).
- The fan's product name (for example Aviator 5), looked up from the model number it reports, is shown in Fan Model, which also says whether the fan has Breeze, after a restart too (#59); Use Selected Fan names the fan and light items after it while they still have their original names, and the action Name Items After Fan names them whatever they are called (#37).
- When the fan gets a new address from the router, the driver finds it again by itself, usually within a minute or two: it asks the network for that fan alone, checks the answer, and then updates Fan Address and says so in Last Action; a DHCP reservation is no longer required. `Follow Address Changes` (On by default) turns it off (#39).
- The Documentation tab, with a short note on replacing the stock WAC driver by hand, and a Composer checklist for the first test (#26, #45).
