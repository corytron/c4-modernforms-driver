# Prereleases for testers

Status: contract, 2026-10-27, ported with the scaffold (#1) from the Hue
project's prerelease contract
([corytron/c4-hue-driver](https://github.com/corytron/c4-hue-driver),
`docs/prerelease-design.md`, its #269), where a GitHub prerelease first put a
feature in an outside tester's hands before the release. Here the Release
workflow, [`tools/changelog.py`](../tools/changelog.py) and
[`tools/deploy.py`](../tools/deploy.py) implement it from the first commit;
no prerelease has been cut yet. What a prerelease is for in this project (a
fan model or firmware the house does not have, a keypad setup the owner
cannot reproduce) is decided per feature; the mechanics below do not depend
on it.

## 1. Versions and tags

| Kind | Version | Tag | Tag moves? | On GitHub |
| --- | --- | --- | --- | --- |
| Stable | `X.Y` | `vX.Y` | yes, every build of X.Y moves it | a release, "Latest" |
| Prerelease | `X.Y-beta.N`, N = 1, 2, ... | `vX.Y-beta.N` | **never**: each beta gets a new tag | a prerelease, never "Latest" |

- One pattern everywhere: `^[0-9]+\.[0-9]+(-beta\.[1-9][0-9]*)?$` for versions, and the same with a leading `v` for tags. This covers the workflow, `tools/deploy.py`, `tools/changelog.py`, `deploy/house.yaml` and the drift issue's title.
- A prerelease takes the codename of its X.Y from [`.github/codenames.json`](../.github/codenames.json) (one codename per X.Y, from Denis Villeneuve's Dune films). The file starts empty: the Release workflow refuses a release or prerelease whose X.Y it does not name, before building anything.
- Prereleases are built from `main`, by the same two-job Release workflow ([`.github/workflows/release.yml`](../.github/workflows/release.yml)), with the same checks, attestations and assets as a stable release. `main` is the only source.
- GitHub's `releases/latest` and the README's download links skip prereleases, so they keep serving the stable release.
- A dispatch whose prerelease tag already exists fails before building anything.
- `X.Y` is the version still to come: later than every version in [`CHANGELOG.md`](../CHANGELOG.md). A prerelease follows a stable release, since its notes name the release it follows and how to go back to it (section 3); before 1.0 there is none (section 7).

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
  - `tools/changelog.py notes --version X.Y-beta.N ...` fills a separate template, [`.github/prerelease-notes.md`](../.github/prerelease-notes.md), from the same `## Unreleased` entry. That entry is everything since the last stable release, which is what a tester should read.
  - The template says, in this order:
    - that this is a prerelease for testing;
    - which stable release it follows;
    - how to install it: all packages at once through Driver ▸ "Add or Update Driver or Agent…", updating in place, never deleting and re-adding a Modern Forms Fan device;
    - how to go back: install the latest stable release's files the same way;
    - how to report: the "Beta feedback" issue form, or the person who sent the link;
    - the verify-a-download block;
    - the license lines.
  - There is no `{history}` (betas are not in `CHANGELOG.md`).
  - An empty `## Unreleased` fails the run, as for a stable release.
- `tools/changelog.py stamp` refuses a prerelease version: `CHANGELOG.md` lists stable releases only, and the stable X.Y entry later carries everything.
- The release title is `X.Y beta N "Codename" (build B)`.
- `gh release create --prerelease --latest=false`.

## 4. The house

- `deploy/house.yaml` may name a prerelease tag. `tools/deploy.py` accepts it (validate, start, done, record, status).
- The drift issue's title becomes `Deploy vX.Y-beta.N (build B) to the house`. The title matcher accepts both forms and nothing else.
- The brief says "prerelease" and lists every package of the manifest.
- Going back to stable is an ordinary desired-state PR.
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
| The steps for the coordinator | [`release-checklist.md`](release-checklist.md#prerelease) |

## 7. Open: a prerelease before 1.0

As ported, a prerelease follows a stable release: its notes name that release and send a tester back to it, and the changelog tool refuses a prerelease while `CHANGELOG.md` lists no release. So the first prerelease of this project can be a beta of 1.1 at the earliest. A 1.0 beta, for a tester with a fan model the house does not have, would need two decisions first, and is a question for the owner: notes that follow no release, and a "going back" that is no install of release files but a return to the stock WAC driver, which redoes the connections and programming the migration contract moved.
