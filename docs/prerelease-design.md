# Prereleases for testers

Status: contract, 2026-10-27, ported with the scaffold (#1) from the Hue
project's prerelease contract
([corytron/c4-hue-driver](https://github.com/corytron/c4-hue-driver),
`docs/prerelease-design.md`, its #269), where a GitHub prerelease first put a
feature in an outside tester's hands before the release. Here the Release
workflow, [`tools/changelog.py`](../tools/changelog.py) and
[`tools/deploy.py`](../tools/deploy.py) implement it from the first commit;
no prerelease has been cut yet. Unlike in the Hue project, a prerelease may
come before the first release, as `1.0-beta.N` (decided with the scaffold,
2026-10-27; section 7). What a prerelease is for in this project (a fan
model or firmware the house does not have, a keypad setup the owner cannot
reproduce) is decided per feature; the mechanics below do not depend on it.

## 1. Versions and tags

| Kind | Version | Tag | Tag moves? | On GitHub |
| --- | --- | --- | --- | --- |
| Stable | `X.Y` | `vX.Y` | yes, every build of X.Y moves it | a release, "Latest" |
| Prerelease | `X.Y-beta.N`, N = 1, 2, ... | `vX.Y-beta.N` | **never**: each beta gets a new tag | a prerelease, never "Latest" |

- One pattern everywhere: `^[0-9]+\.[0-9]+(-beta\.[1-9][0-9]*)?$` for versions, and the same with a leading `v` for tags. This covers the workflow, `tools/deploy.py`, `tools/changelog.py`, `deploy/house.yaml` and the drift issue's title.
- A prerelease takes the codename of its X.Y from [`.github/codenames.json`](../.github/codenames.json) (one codename per X.Y, from Denis Villeneuve's Dune films). The file starts empty: the Release workflow refuses a release or prerelease whose X.Y it does not name, before building anything.
- Prereleases are built from `main`, by the same two-job Release workflow ([`.github/workflows/release.yml`](../.github/workflows/release.yml)), with the same checks, attestations and assets as a stable release. `main` is the only source.
- GitHub's `releases/latest` and the README's download links skip prereleases, so they keep serving the stable release (before 1.0 they have none to serve).
- A dispatch whose prerelease tag already exists fails before building anything.
- `X.Y` is the version still to come: later than every version in [`CHANGELOG.md`](../CHANGELOG.md). It may be the first version: `1.0-beta.N` comes before any release, and its notes then name no stable release (section 7).

## 2. The packages: one list

The packages are named in one place: the directories `src/<name>/` that hold a `driver.xml`, sorted by name. Today there is one, `modernforms_fan`, the fan and its light; if the v1 research gives the light a driver of its own, that is a second such directory and nothing below changes.
- `tools/build.sh` builds exactly those.
- `build/manifest.json` lists them.
- The Release workflow's checks (the file listing, `SHA256SUMS.txt`, the provenance subjects, the upload) take the list from the manifest, never a literal list. The manifest is itself checked against the `src/*/driver.xml` directories of the commit.
- CI's build job does the same.
- `deploy/house.yaml`'s `drivers:` must equal the release manifest's packages; `tools/deploy.py start` refuses otherwise.

## 3. Notes

- **Stable releases:** notes come from `## Unreleased` ([`changelog-design.md`](changelog-design.md)), and the desired-state PR stamps the entry afterwards.
- **Prereleases:**
  - `tools/changelog.py notes --version X.Y-beta.N ...` fills a separate template, [`.github/prerelease-notes.md`](../.github/prerelease-notes.md), from the same `## Unreleased` entry. That entry is everything since the last stable release (before 1.0, everything so far), which is what a tester should read.
  - The template says, in this order:
    - that this is a prerelease for testing;
    - which stable release it follows, or, before the first release, that there is none;
    - how to install it: all packages at once through Driver ▸ "Add or Update Driver or Agent…", updating in place, never deleting and re-adding a Modern Forms Fan device; before the first release also that the first install adds the device beside the stock WAC device, whose programming is disabled rather than deleted;
    - how to go back: install the latest stable release's files the same way, or, before the first release, return to the stock WAC driver (section 7);
    - how to report: the "Beta feedback" issue form, or the person who sent the link;
    - the verify-a-download block;
    - the license lines.
  - There is no `{history}` (betas are not in `CHANGELOG.md`).
  - The alternatives are whole-line blocks ([`changelog-design.md`](changelog-design.md), section 4): `<!-- if stable -->` … `<!-- end if -->` is kept while `CHANGELOG.md` lists a release, `<!-- if no stable -->` … `<!-- end if -->` only while it lists none, and the marker lines never reach the notes. `{stable}` and `{stable_version}` have a value only while a release is listed, so they stand only inside `if stable` blocks: `tools/changelog.py notes` refuses them anywhere else for a prerelease before the first release.
  - An empty `## Unreleased` fails the run, as for a stable release.
- `tools/changelog.py stamp` refuses a prerelease version: `CHANGELOG.md` lists stable releases only, and the stable X.Y entry later carries everything.
- The release title is `X.Y beta N "Codename" (build B)`.
- `gh release create --prerelease --latest=false`.

## 4. The house

- `deploy/house.yaml` may name a prerelease tag. `tools/deploy.py` accepts it (validate, start, done, record, status).
- The drift issue's title becomes `Deploy vX.Y-beta.N (build B) to the house`. The title matcher accepts both forms and nothing else.
- The brief says "prerelease" and lists every package of the manifest.
- Going back to stable is an ordinary desired-state PR. Before the first release the way back is the migration's rollback to the stock WAC device (section 7), which the Windows session does like any other Composer change.
- Before the first install the desired state is `release: none` (the house runs the stock WAC driver); that is neither a release nor a prerelease, and with no Deployment it is no drift.

## 5. Feedback

- The issue form [`.github/ISSUE_TEMPLATE/beta-feedback.yml`](../.github/ISSUE_TEMPLATE/beta-feedback.yml), "Beta feedback". It asks for:
  - the prerelease version and the device's `Driver Version`;
  - the Control4 OS and Composer Pro versions;
  - the fan's model (with or without a light) and its firmware;
  - the devices involved, for example the fan, its light, a keypad and its buttons, the remote or the wall control;
  - what was done and what was seen;
  - the relevant Lua output, with addresses, the MAC and the client id replaced by placeholders and no account e-mail.
- No form asks for an address, a MAC or an id: the versions and models are enough, and the form's first lines name the placeholders ([`scaffold-design.md`](scaffold-design.md), section 2).
- A label `beta-feedback` in `.github/labels.json`.
- The owner may also paste feedback that came by other channels ("Reported another way").

## 6. Where it lives

| Part | Files |
| --- | --- |
| Versions, tags, the build, the checks, the publication | `.github/workflows/release.yml` (both jobs), `tools/build.sh` |
| The package list | `src/*/driver.xml`, `build/manifest.json`; checked in `.github/workflows/ci.yml` (build job) and `.github/workflows/release.yml` |
| Notes and title | `tools/changelog.py notes`, `.github/prerelease-notes.md`, `.github/release-notes.md`, `.github/codenames.json` |
| The house | `deploy/house.yaml`, `tools/deploy.py`, `.github/workflows/drift.yml` |
| Feedback | `.github/ISSUE_TEMPLATE/beta-feedback.yml`, `.github/labels.json` |
| Going back before the first release | `docs/edge-cases-control4.md`, section 2 (the phased migration from the stock driver and its rollback) |
| The steps for the coordinator | [`release-checklist.md`](release-checklist.md#prerelease) |

## 7. A prerelease before the first release

Decided with the scaffold (2026-10-27): allowed. A `1.0-beta.N` can put the driver in a tester's hands, for example with a fan model or a firmware the house does not have, before 1.0 exists. What differs from a later prerelease:

- **Codename:** the 1.0 name must be approved and in `.github/codenames.json` first; the Release workflow refuses a 1.0 beta otherwise, as any version whose X.Y the file does not name.
- **Notes:** there is no stable release, so `{stable}` and `{stable_version}` have no value and the template's `if no stable` blocks take over (section 3): the notes say that the prerelease comes before the first release and that the project has no stable release yet, list the whole `Unreleased` entry (everything so far) under "What to try", and send the tester back to the stock WAC driver.
- **Install:** the first install is no update. The tester adds a Modern Forms Fan device beside the stock WAC device of the same fan, and the stock device stays in the project with its programming disabled, not deleted (the phased migration of `docs/edge-cases-control4.md`, section 2: disable before delete). Later betas update that device in place.
- **Going back:** to the stock WAC driver, by the migration's rollback: disconnect the new device's links, set each keypad button's LED Behavior back to Programmed (disconnecting does not restore it), enable the stock device's programming again, undo anything done to quiet the stock device, then delete the Modern Forms Fan device or keep it unused.
- **Changelog:** the rules do not change. A prerelease is never stamped, the 1.0 entry carries everything when 1.0 is released, and until then the Documentation tab shows the `Unreleased` entry as `1.0 beta 1 "<codename>" (prerelease), build N (date)`.
