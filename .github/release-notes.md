## {version} "{codename}" (build {build})

Codename: **{codename}**. Each X.Y release of this project has its own codename from Denis Villeneuve's Dune films (a widely recognised character, place or object for an X.0, a decidedly lesser one for a point release); every build of {version} keeps it. Released {date}.

Install every `.c4z` file of the release at once through Driver ▸ "Add or Update Driver or Agent…" in Composer Pro, updating every device in place; never delete and re-add a Modern Forms Fan device (that loses its settings and every connection and programming line that names it). When the changes below say a driver's capabilities changed, reboot the controller from System Manager afterwards: on OS 3.x, Composer's "Restart Director?" does not load them.

### New in build {build}

{this_build}

### What you get

- **Modern Forms Fan** driver: a Modern Forms ceiling fan and its light in Control4, with keypad Button Links and state that follows the Modern Forms app, the remote and the wall control. What it does in detail, its properties and its actions are in the owner's manual on its Documentation tab.

Each driver's Documentation tab ends with the full list of releases.

### Requirements

- A Control4 controller on OS 3.x or 4.x, at or above the minimum version the driver declares (its Documentation tab names it).
- A Modern Forms fan on the controller's LAN, reachable over HTTP. The driver talks to the fan directly, so Control4 keeps working when the Modern Forms cloud is down.

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
