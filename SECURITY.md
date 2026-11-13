# Security policy

This is a personal project for one Control4 home, offered as is under the
Apache License 2.0. Security reports are welcome all the same and are
handled in good faith, on a best-effort basis.

## Supported versions

Only the **latest release** on the
[Releases page](https://github.com/corytron/c4-modernforms-driver/releases)
is supported: the `.c4z` packages attached to it (`modernforms_fan.c4z` and
`modernforms_breeze_fan.c4z`), identified by the build number they show as
**Driver Version** in Composer. Older builds get no fixes; update in place
through Composer's *Add or Update Driver or Agent...* (see the README).
Development builds (`tools/build.sh --dev`) are for the developer's own
test system, carry the developer's dev-loop key, and are never supported as
a production driver.

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

## The threat model

<a id="the-threat-model-to-be-settled-by-the-v1-research"></a>

### The fan has no protection of its own

A Modern Forms fan of generation 1 to 3 answers plain HTTP on port 80 of
your local network, with **no authentication and no encryption**
([`docs/modernforms-api-research.md`](docs/modernforms-api-research.md#7-discovery-authentication-cloud),
section 7). Anyone on that network can already read and control the fan,
with or without this driver. The driver cannot add protection the fan does
not have, and does not pretend to: the protection of the fan is your
network's. What someone on your network can do by talking to the fan
directly is the fan's own threat model, not this driver's.

### What a release build sends, and where

- **To the fan.** HTTP POSTs to `/mf` on port 80 of **Fan Address**, one
  at a time: reads of the fan's state and identity, and the commands
  Control4 asks for (and, when `/mf` answers 404, one read of `/device` to
  recognise a generation 4 fan, which the driver then refuses). Nothing
  goes to the vendor's cloud or anywhere on the internet. The private
  details in the fan's answers (the owner's account, the Wi-Fi name) are
  dropped when they arrive.
- **One multicast DNS question** on the controller's own network segment:
  `_easylink._tcp.local`, sent to 224.0.0.251:5353 twice a second apart,
  with 3 seconds of answers read. The driver asks it by itself, with no
  click: a few seconds after every load and, while the device has no fan
  or no usable address, again on a schedule (30 seconds, 1, 2, 5 and 10
  minutes, then every 15 minutes), to keep **Found Fans** current
  ([`docs/auto-discovery-design.md`](docs/auto-discovery-design.md#1-decisions));
  and when the configured fan stops answering at its address, to follow it
  (below). It never scans a subnet. Any device on the segment can answer:
  the driver lists only answers that name port 80 and a private or
  link-local IPv4 address, and another fan heard this way is only listed:
  nothing is sent to it until the owner picks it.
- **The address follow.** When the configured fan has left **Fan
  Address**, the driver reads, after each search, at most three addresses
  that announced the configured fan's MAC address, each a private (RFC
  1918) or link-local address, with one fixed read-only request (the fan's
  static data), and
  moves only when that answer carries the configured fan's client id and
  MAC address
  ([`docs/address-follow-design.md`](docs/address-follow-design.md#1-decisions),
  F9). That read checks identity; it does not authenticate. The client id
  and MAC address are announced in the clear, so someone on the local
  network who copies them can draw that one read and then the driver's
  requests: the same exposure as spoofing the fan at a fixed address.
  **Follow Address Changes** set to Off turns the follow off.

The v1 contract ([`docs/v1-design.md`](docs/v1-design.md), section 3, V5a,
V29 and V30) names the hosts, ports and requests. A way to make a release
build talk to anything else (a public address, an address nobody
announced, a fan other than the configured one without the owner's pick or
click), or to open a connection the contract does not name, counts as a
vulnerability.

### What reaches the driver from inside Control4

Control4 hands a driver its commands without a sender the driver can
check: the fan item's actions and programming commands, the Breeze fan's
messages and the keypad's ambient reading all arrive the same way, and
anything on the controller that can send the fan device a command
(programming, another driver) can send them. The controller, and whoever
can change its project in Composer, are inside the trust boundary.

The reading on the **Ambient Light Level (Follower)** input (1.9, #207)
arrives as one such command, `AMBIENT_LIGHT_LEVEL`, which Control4 does not
document for drivers
([`docs/ambient-pause-design.md`](docs/ambient-pause-design.md)). The driver
takes a reading that is a whole number from 0 to 255: from the bound
keypad only when it knows that keypad's device id and the message names a
device, and from any sender while nothing is bound. A reading only pauses or
resumes the keypad LED animations (the speed chase and the Breeze gusts),
which **Keypad Links** reports. It changes nothing on the fan or the light,
no setting and no other LED, and nothing of it is stored.

### The development loop

Development builds (`tools/build.sh --dev`) fetch driver code from a
developer's machine (`tools/devserver.py`, port 8081, plain HTTP on the
LAN) and run actions queued with `tools/devctl.py`. The controller acts
only on bundles and command lists signed with HMAC-SHA256 under the
developer's dev key, which never crosses the wire; but each development
package carries that key, so a development package is never handed to
anyone and never installed as the production driver
([`docs/dev-loop.md`](docs/dev-loop.md#security)).

**A release build carries none of it:** not the dev-loop module
(`common/devloop.lua`), the key (`common/devkey.lua`), the development
commands (`fan/devcmds.lua`), the development-only rows of `driver.xml`
(Dev Server, Dev State) or the Lua command window. `tools/build.sh` leaves
them out and refuses to package a release build that still has one of
those files or a `DEV-ONLY` part of `driver.xml`. A released package that
carries any of it, or a way to make a release build fetch or run code from
the network, is a vulnerability.

### Private data and the release packages

- **Private data leaving the house.** A fan's device information names its
  network identity and, as far as the public clients' test data show, its
  owner's account. The project's own tooling refuses LAN addresses, MAC
  addresses, fan ids, e-mail addresses and cloud identities in what it
  posts to GitHub (`tools/gh-discussion.py`, `tools/deploy.py`), the
  screenshot tooling in what it lets out of the Windows machine
  (`tools/composer/Shots.ps1`), and the `secrets` check in the repository.
  A way past any of them counts.
- **The release packages.** A package attached to a release that was not
  built and attested by the Release workflow from `main`, or a way to make
  that workflow build from anything else, counts.

Not covered here: Control4 OS, Composer Pro and Director belong to Snap
One, and the fan's firmware, the Modern Forms app and its cloud service to
their maker; report problems in them there.

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
  workflow's token cannot read them. CodeQL has no Lua support: the drivers
  are covered by luacheck and the busted specs.
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
- **Build provenance.** The Release workflow builds the packages with
  read-only access and, in a second job that runs no third-party code,
  signs a build-provenance attestation for them, attached to the release
  as well. Verify each download with

  ```sh
  gh attestation verify modernforms_fan.c4z --repo corytron/c4-modernforms-driver \
    --signer-workflow corytron/c4-modernforms-driver/.github/workflows/release.yml
  ```

  (and the same for `modernforms_breeze_fan.c4z`), and its checksum against
  `SHA256SUMS.txt`; `--source-digest` with the `commit` from
  `manifest.json` also checks the commit it was built from. Use GitHub CLI
  2.102.0 or newer: `--signer-workflow` is what makes the Release workflow
  the only accepted signer, and older versions either lack it or match only
  the start of the workflow's path (GHSA-wjmr-j3rp-mh2g).
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
