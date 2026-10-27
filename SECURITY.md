# Security policy

This is a personal project for one Control4 home, offered as is under the
Apache License 2.0. Security reports are welcome all the same and are
handled in good faith, on a best-effort basis.

## Supported versions

**None yet: there is no release** (2026-10-27). Once there is, only the
**latest release** on the
[Releases page](https://github.com/corytron/c4-modernforms-driver/releases)
is supported: the `.c4z` attached to it, identified by the build number it
shows as **Driver Version** in Composer. Older builds get no fixes; update
in place through Composer's *Add or Update Driver or Agent...* (see the
README). Development builds (`tools/build.sh --dev`) are for the developer's
own test system, carry the developer's dev-loop key, and are never supported
as a production driver.

## Reporting a vulnerability

Please do not open a public issue for anything security-sensitive. Use
GitHub's private vulnerability reporting on this repository (**Security >
Report a vulnerability**, or
<https://github.com/corytron/c4-modernforms-driver/security/advisories/new>).
If that is not available to you, contact the author privately through his
GitHub profile, [@corytron](https://github.com/corytron), instead of
posting details anywhere public.

Include the build number (Driver Version), the Control4 OS version, the
fan's model and firmware, what you found and how to reproduce it. Replace
your LAN addresses, MAC addresses, fan ids and account details with
placeholders (CONTRIBUTING.md lists them).

## The threat model (to be settled by the v1 research)

What the driver can protect depends on what the fan offers, and the v1
research ([issue #2](https://github.com/corytron/c4-modernforms-driver/issues/2))
establishes that; this section is rewritten when it has. **Assumed today**,
from the public open-source clients of the fan's local interface: the fan
answers plain HTTP on the local network, with no authentication and no
encryption, so anyone on the same network can already control it, with or
without this driver. The driver cannot add protection the fan does not
have, and will not pretend to: the protection of the fan is your network's.

What counts already, and will count in every release:

- **The development loop.** Development builds (`--dev`) fetch driver code
  from a developer's machine (`tools/devserver.py`) and run actions queued
  with `tools/devctl.py`, both signed with the developer's dev key, which
  each development package carries. A release build must contain none of
  it: neither the dev-loop module, nor the key, nor the development-only
  properties and actions (`tools/build.sh` refuses to package one that
  does). A released package that does, or a way to make a release build
  fetch or run code from the network, is a vulnerability.
- **What the driver talks to.** A release build is meant to send requests
  to the fan the owner configured and nowhere else. Once the v1 contract
  names the hosts, ports and requests, a way to make a release build talk to
  anything else, or to open a port on the controller that the contract does
  not name, counts.
- **Private data leaving the house.** A fan's device information names its
  network identity and, as far as the public clients' test data show, its
  owner's account. The project's own tooling refuses LAN addresses, MAC
  addresses, fan ids, e-mail addresses and cloud identities in what it posts
  to GitHub (`tools/gh-discussion.py`, `tools/deploy.py`), the screenshot
  tooling in what it lets out of the Windows machine
  (`tools/composer/Shots.ps1`), and the `secrets` check in the repository. A
  way past any of them counts.
- **The release packages.** A package attached to a release that was not
  built and attested by the Release workflow from `main`, or a way to make
  that workflow build from anything else, counts.

Not covered here: Control4 OS, Composer Pro and Director belong to Snap
One, and the fan's firmware, the Modern Forms app and its cloud service to
their maker; report problems in them there. What someone already on your
network can do by talking to the fan directly is the fan's own threat
model, not this driver's.

## What is checked automatically

Set up with the repository on 2026-10-27; `docs/status.md` says which of it
is switched on today.

- **Secrets and private data.** Every pull request and every push to `main`
  runs `gitleaks` with the repository's rules (`.gitleaks.toml`) over the
  working tree and the git history of the commit under test; locally,
  `tools/check.sh` runs the same rules over the tree and the history of
  every local branch and tag. A real key, token, private key, LAN address,
  MAC address, fan client id, e-mail address or cloud identity fails it.
  GitHub's secret scanning and push protection are on as well.
- **Code scanning.** GitHub's CodeQL default setup scans the Python tooling
  and the workflows on every pull request and every push to `main`, and
  OpenSSF Scorecard's findings land beside them on the Security tab. After
  each push to `main` the code scanning triage workflow waits for the scans
  of that commit and keeps one issue labelled `security`, *Code scanning: N
  open alert(s) on main*: opened when alerts appear, updated when the set
  changes, closed when none remain. It never dismisses an alert: the
  maintainer fixes each through a pull request or dismisses it with its
  reason, and checks secret scanning alerts separately, since the
  workflow's token cannot read them. CodeQL has no Lua support: the driver
  is covered by luacheck and the busted specs.
- **Pinned dependencies.** Every GitHub Action in the workflows is pinned to
  a full commit SHA. Dependabot proposes updates once a week, grouped, no
  sooner than 7 days after an upstream release (its cooldown; security
  updates are not delayed), and Dependabot security updates are on. Action
  updates merge on their own once the four required checks pass; updates of
  the Python check tools, pinned with the sha256 of every file in
  `tools/requirements-checks.txt`, are reviewed by hand. Snap One's packager
  and the luarocks tools are pinned in the workflows (a commit, exact
  versions) and moved by hand after reading their changes.
- **OpenSSF Scorecard** rates the repository's practices (pinned actions,
  branch protection, token permissions, signed releases):
  <https://securityscorecards.dev/viewer/?uri=github.com/corytron/c4-modernforms-driver>.
- **Build provenance.** The Release workflow builds the package with
  read-only access and, in a second job that runs no third-party code,
  signs a build-provenance attestation for it, attached to the release as
  well. Verify a download with

  ```sh
  gh attestation verify modernforms_fan.c4z --repo corytron/c4-modernforms-driver \
    --signer-workflow corytron/c4-modernforms-driver/.github/workflows/release.yml
  ```

  and its checksum against `SHA256SUMS.txt`; `--source-digest` with the
  `commit` from `manifest.json` also checks the commit it was built from.
  Use GitHub CLI 2.102.0 or newer: `--signer-workflow` is what makes the
  Release workflow the only accepted signer, and older versions either lack
  it or match only the start of the workflow's path (GHSA-wjmr-j3rp-mh2g).
  `tools/deploy.py start` runs the same check before an install on the
  author's house and refuses a package that fails it. A package that fails
  either check was not built by this repository's Release workflow: do not
  install it, and report it.

## What to expect

A personal project: no service level, no bounty. The author reads reports
as soon as he can, confirms receipt, and fixes a confirmed problem in a new
build on the Releases page, with a release note saying what changed. You are
credited there if you want to be. Please allow a reasonable time before
publishing details.
