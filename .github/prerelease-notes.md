## {release} beta {beta} "{codename}" (build {build})

**A prerelease for testing**, not a release: version {version}, built {date}, with what is coming in {release}, published so that it can be tried before it is released. GitHub marks it Pre-release and never Latest, so the project's download links keep serving the stable release. Codename **{codename}**: each X.Y release of this project has its own codename from Denis Villeneuve's Dune films (a widely recognised name for an X.0, a lesser character, place or object for a point release), and every build of {release}, prereleases included, keeps it.

It follows the stable release [{stable}](https://github.com/corytron/c4-modernforms-driver/releases/tag/v{stable_version}). The changes below are everything since then: they are what to try.

### Changes since {stable_version}

{this_build}

### Install

Install every `.c4z` file of this prerelease at once through Driver ▸ "Add or Update Driver or Agent…" in Composer Pro, updating every device in place; never delete and re-add a Modern Forms Fan device (that loses its settings and every connection and programming line that names it). When the changes above say a driver's capabilities changed, reboot the controller from System Manager afterwards: on OS 3.x, Composer's "Restart Director?" does not load them.

### Going back

Install every `.c4z` file of the [latest stable release](https://github.com/corytron/c4-modernforms-driver/releases/latest) the same way: all at once through "Add or Update Driver or Agent…", in place, never deleting a Modern Forms Fan device. Going back to an older build has not been tested yet, so afterwards read the fan device's properties and try the fan, its light and the keypad buttons linked to them rather than assume. A driver that only this prerelease has is not among those files: delete its devices in Composer if you go back for good.

### Feedback

Report what you tried and what you saw with the [Beta feedback form](https://github.com/corytron/c4-modernforms-driver/issues/new?template=beta-feedback.yml), or tell the person who sent you this link. Replace LAN addresses, the fan's MAC address and its client id with placeholders, and never paste the e-mail address of your Modern Forms account.

### Verify a download

```sh
sha256sum -c SHA256SUMS.txt
for f in *.c4z; do gh attestation verify "$f" --repo corytron/c4-modernforms-driver --signer-workflow corytron/c4-modernforms-driver/.github/workflows/release.yml; done
```

`gh` 2.102.0 or newer, in the folder that holds every file of the prerelease. `manifest.json` names the build, the commit and each package's sha256.

### License

Apache License 2.0 (LICENSE and NOTICE travel inside each `.c4z`). Modern Forms and WAC Lighting are trademarks of their respective owners; Control4, Composer and DriverWorks are trademarks of Snap One, LLC. This project is not affiliated with, endorsed by or supported by WAC Lighting or Snap One.
