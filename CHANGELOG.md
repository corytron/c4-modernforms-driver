# Changelog

Every published release of the Modern Forms Fan driver, newest first, with
what changed since the release before it. A version X.Y is the GitHub
release of the tag `vX.Y` and carries its own codename from Dune, Denis
Villeneuve's films (`.github/codenames.json`: a widely recognised
character, place or object for an X.0, a decidedly less important one for a
point release). A version can be released as several builds: the build
number is the commit count of the released commit and the Driver Version
that Composer shows for every device, and each newer build of a version
replaces the files of its release. Prereleases for testers (X.Y-beta.N),
development builds and builds installed only for tests are not listed; the
next release's entry carries what they changed.

## Unreleased

### Added

- First build of the Modern Forms Fan driver (`modernforms_fan.c4z`), for fans with six speeds (Gen 1 to 3): one device per fan with the fan's speeds, on and off and direction, and its light with dimming, in Control4 programming, the Navigators and the keypads (#26).
- Keypad buttons bind to the driver's own Button Links, one for each speed, Off, Toggle and Cycle and one each for the light's Top, Bottom and Toggle, and their LEDs follow the fan and the light; a speed link can also stay lit at one more speed, so a button whose double tap sets another speed keeps its LED (#26).
- A fan is added by typing its address, or with Find Fans, which lists the fans that answer on the network; the driver remembers which fan it is and refuses a different fan at that address until Use Selected Fan accepts it. Status, Last Action and the other rows say what the driver sees, and Fan Offline and Fan Online are events for programming (#26).
- Speed LED Colors: set it to `Per speed` and the fan's speed links show a colour for each speed on a keypad button (for example blue at Level 1 and orange at Level 6), with Speed 1 LED Color to Speed 6 LED Color and Speed LED Off Color; by default the keypad's own colours stay (#31).
- A Migration Report for replacing the stock WAC driver step by step, which only reads the project and says what still refers to the old device, and the Documentation tab and a Composer checklist for the first test (#26).
