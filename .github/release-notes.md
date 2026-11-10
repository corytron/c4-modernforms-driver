## {version} "{codename}" (build {build})

{meaning}

Released {date}.

Install every `.c4z` file of the release at once through Driver ▸ "Add or Update Driver or Agent…" in Composer Pro, updating every device in place; never delete and re-add a Modern Forms Fan device (that loses its settings and every connection and programming line that names it). When the changes below say a driver's capabilities changed, reboot the controller from System Manager afterwards: on OS 3.x, Composer's "Restart Director?" does not load them.

### New in build {build}

{this_build}

### What you get

- **Modern Forms Fan** driver: a Modern Forms ceiling fan and its light as ordinary Control4 devices. The fan has six speeds (Level 1 to Level 6), off and its direction, and the light dims. On a fan that has Breeze, programming switches Breeze and sets its strength, with events and a condition that follow it; the fan runs either in fan mode or in Breeze mode, and the fan device shows fan mode only. Thirteen Button Links of the driver's own (each speed, Off, Toggle, Cycle and Breeze, and the light's Top, Bottom and Toggle) bind keypad buttons whose LEDs follow the fan and the light, in the keypad's colours or one colour per speed. The state follows the Modern Forms app, the remote and the wall control. The driver finds the fans on the network by itself and lists them in Found Fans, and keeps to the fan it was given, following it to a new address by itself. Fan Offline and Fan Online are events for programming. What it does in detail, its properties and its actions are in the owner's manual on its Documentation tab, which also says how to replace the stock WAC driver by hand.
- **Modern Forms Breeze Fan** driver: the Breeze fan for the Navigators, a second fan with the three speeds Breeze 1, Breeze 2 and Breeze 3, because Control4's fan tile cannot show Breeze. The action Add Breeze Fan on a fan device adds one to the fan's room, named after the fan; it shows the strength while the fan blows a breeze and off otherwise, a speed starts Breeze at that strength and Off ends it. Install it with the fan driver even where no fan has Breeze: it adds nothing by itself. It replaces the Breeze switch of 1.2 (the driver Modern Forms Breeze, no longer included): delete that switch, then click Add Breeze Fan, as the fan's Documentation tab says.

Each driver's Documentation tab ends with the full list of releases.

### Requirements

- A Control4 controller on OS 3.3.0 or newer, managed with Composer Pro. Tried on OS 3.4.3 with Composer Pro 3.4.2; OS 4.x has not been tried.
- A Modern Forms fan of generation 1, 2 or 3 with six speeds, set up on Wi-Fi with the Modern Forms app, on the controller's network segment. Tried with one Gen 3 fan; a Gen 4 fan is refused. The driver talks to the fan directly, so Control4 keeps working when the Modern Forms cloud is down. A DHCP reservation for the fan is recommended but not required.

### Verify a download

```sh
sha256sum -c SHA256SUMS.txt
for f in *.c4z; do gh attestation verify "$f" --repo corytron/c4-modernforms-driver --signer-workflow corytron/c4-modernforms-driver/.github/workflows/release.yml; done
```

`gh` 2.102.0 or newer, in the folder that holds every file of the release. `manifest.json` names the build, the commit and each package's sha256.

### Earlier builds of {version}

{history}

Every release so far: [CHANGELOG.md](https://github.com/corytron/c4-modernforms-driver/blob/main/CHANGELOG.md).

### License

Apache License 2.0 (LICENSE and NOTICE travel inside each `.c4z`). Modern Forms and WAC Lighting are trademarks of their respective owners; Control4, Composer and DriverWorks are trademarks of Snap One, LLC. This project is not affiliated with, endorsed by or supported by WAC Lighting or Snap One.
