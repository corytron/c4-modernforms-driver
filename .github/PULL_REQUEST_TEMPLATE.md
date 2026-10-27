<!-- Keep it short. The checklist is the one in CONTRIBUTING.md. -->

## What

<!-- The change in a sentence or two, and "Closes #N" for the issue it fixes. -->

## Why

<!-- The problem it solves or the behaviour it changes. If the driver would act on its
     own over the life of the system (finding a fan, following its address, syncing
     names or rooms, creating or removing devices, migrating from the stock driver),
     name the contract under docs/ that decided it. -->

## How it was tested

- [ ] `tools/check.sh` passes: lint, specs, shell, Python, XML, workflows, secrets, the
      house's desired state, the changelog and the links (CI runs the same script
      with `--strict`)
- [ ] A change of behaviour comes with a spec
- [ ] `tools/build.sh` builds every `.c4z` package (one per `src/*/driver.xml`)
- [ ] On hardware: <!-- Control4 OS version, Composer Pro version, fan model and firmware,
      what you clicked or pressed and what you saw; or "not run on a controller", which
      is fine if said -->

## Checklist

- [ ] **Capabilities.** This PR does not change a `driver.xml` `<capabilities>` block.
      If it does, say so prominently above: installing it makes Composer ask "Restart
      Director?" and every user must reboot their controller from System Manager before
      the new build loads.
- [ ] **No private data.** No real LAN address, MAC address, fan client id, Modern Forms
      account e-mail, room or Composer project name, key, certificate or screenshot of a
      real project; the placeholders of `docs/scaffold-design.md`, section 2.
- [ ] **No third-party text.** Nothing from Snap One's SDK repositories or documentation,
      nothing copied from WAC Lighting's materials; a fact about the fan's API names its
      source.
- [ ] **Manual.** `src/modernforms_fan/www/documentation.html` is updated if a property
      text, an action or a status line changed.
- [ ] **Changelog.** A change to what the driver does or what its documentation says
      has a line under `## Unreleased` in `CHANGELOG.md`, written for the people who
      install and use the driver, with the issue number (`docs/changelog-design.md`).
- [ ] **Status.** `docs/status.md` is updated if what runs or what is open changed.
- [ ] **Documents.** For a new document: decided whether visitors of the project page
      would find it useful, and if so the README links it (a design note goes in
      `docs/README.md`).
