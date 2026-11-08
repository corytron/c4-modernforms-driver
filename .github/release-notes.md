## {version} "{codename}" (build {build})

Codename: **{codename}**. Each X.Y release of this project has its own codename from Denis Villeneuve's Dune films (a widely recognised character, place or object for an X.0, a lesser-known one from that X.0's own world for a point release); every build of {version} keeps it. Released {date}.

Install every `.c4z` file of the release at once through Driver ▸ "Add or Update Driver or Agent…" in Composer Pro, updating every device in place; never delete and re-add a Modern Forms Fan device (that loses its settings and every connection and programming line that names it). When the changes below say a driver's capabilities changed, reboot the controller from System Manager afterwards: on OS 3.x, Composer's "Restart Director?" does not load them.

### New in build {build}

{this_build}

### What you get

- **Modern Forms Fan** driver: a Modern Forms ceiling fan and its light as ordinary Control4 devices. The fan has six speeds (Level 1 to Level 6), off and its direction, and the light dims. Twelve Button Links of the driver's own (each speed, Off, Toggle and Cycle, and the light's Top, Bottom and Toggle) bind keypad buttons whose LEDs follow the fan and the light, in the keypad's colours or one colour per speed. The state follows the Modern Forms app, the remote and the wall control. Find Fans lists the fans on the network, and the driver keeps to the fan it was given, following it to a new address by itself. Fan Offline and Fan Online are events for programming. What it does in detail, its properties and its actions are in the owner's manual on its Documentation tab, which also says how to replace the stock WAC driver by hand.

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
