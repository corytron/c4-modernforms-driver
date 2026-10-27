# The docs folder

What each file here is for. One rule runs through all of them: `status.md` is
the single page of the present; every other note keeps its history as
written, with dated "Superseded" or "Current" lines where behaviour changed
later, and where a note and `status.md` disagree about the present,
`status.md` and the code win. The owner's manual itself is not here but in
the driver: [`src/modernforms_fan/www/documentation.html`](../src/modernforms_fan/www/documentation.html)
(the driver's Documentation tab in Composer; until the v1 contract it says
that the driver is not ready). What each release changed is in
[`CHANGELOG.md`](../CHANGELOG.md); the working rules of the AI sessions that
build the driver are in [`CLAUDE.md`](../CLAUDE.md).

On 2026-10-27 the folder holds the scaffold's documents: the process,
copied from the author's [Hue driver](https://github.com/corytron/c4-hue-driver)
and adapted. The v1 research
([issue #2](https://github.com/corytron/c4-modernforms-driver/issues/2)), its
edge-case notes and the v1 contract are listed here when they land.

## Start here

- [`status.md`](status.md): what runs on the author's house (today the stock
  driver and its keypad workaround), what this repository has built, and
  what is open.
- [`design.md`](design.md): the engineering notebook. The targets (OS
  versions, Lua 5.1), the method (every claim marked verified or assumed,
  with its source), what was measured of the stock driver, and the headings
  the v1 research fills: transport, driver structure, the fan proxy and its
  speed links, the light, keypad LEDs, the state model and the minimum OS.
- [`release-checklist.md`](release-checklist.md): what a build must pass on
  the development machine, on the dev loop, in Composer and with the owner's
  phone, keypads and fan before it is called good (the hardware passes are a
  skeleton until the v1 contract); how a release is named (one Dune codename
  per X.Y), cut (the Release workflow) and brought to the house
  (`tools/deploy.py`).

## Process

- [`scaffold-design.md`](scaffold-design.md): the contract of the scaffold
  (2026-10-27, #1): the names, the placeholders, the checks and CI jobs, the
  build and manifest, the desired and observed state of the house, the
  GitHub conventions, the skeleton driver, and what of the Hue project's
  tooling was left out.
- [`cicd-gitops-design.md`](cicd-gitops-design.md): the CI/CD and GitOps
  contract: one check script for the development machine and CI
  (`tools/check.sh`), the four required jobs, the code scanning issue,
  attested releases from `main`, `deploy/house.yaml` as the desired state of
  the house, the GitHub Deployment as the observed state, the drift issue
  and `tools/deploy.py`.
- [`changelog-design.md`](changelog-design.md): the contract of the
  changelog: `CHANGELOG.md`'s format, `tools/changelog.py` (the check, the
  release notes, the Documentation tab's changelog, the stamp) and the
  release codenames.
- [`prerelease-design.md`](prerelease-design.md): prereleases for testers:
  versions `X.Y-beta.N` with tags that never move, built from `main` like
  every release, and their notes.
- [`dev-loop.md`](dev-loop.md): the development loop: a `--dev` build of the
  driver fetches its Lua from `tools/devserver.py`, reloads itself, runs
  actions queued with `tools/devctl.py` and ships its log back, every bundle
  and command signed with the developer's dev key.
- [`composer-remote.md`](composer-remote.md): driving Composer Pro from the
  development machine through a Claude Code session on the Windows machine
  (UI Automation from PowerShell, `tools/composer/Composer.psm1` and
  `Shots.ps1`), the rules every brief carries, and what was learned about
  Connections and Programming by synthetic drag.
- [`composer-checklist.md`](composer-checklist.md): the steps only
  Composer, a Navigator, a keypad or the Modern Forms app can show, as the
  owner runs them, with a "Done" line per step; a skeleton until the v1
  contract fills in its texts.
