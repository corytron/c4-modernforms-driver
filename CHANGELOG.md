# Changelog

Every published release of the Modern Forms Fan driver, newest first, with
what changed since the release before it. A version X.Y is the GitHub
release of the tag `vX.Y` and carries its own codename from Dune, Denis
Villeneuve's films (`.github/codenames.json`: a widely recognised
character, place or object for an X.0, a lesser-known one tied to its X.0's
name for a point release). A version can be released as several builds: the build
number is the commit count of the released commit and the Driver Version
that Composer shows for every device, and each newer build of a version
replaces the files of its release. Prereleases for testers (X.Y-beta.N),
development builds and builds installed only for tests are not listed; the
next release's entry carries what they changed.

## Unreleased

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
