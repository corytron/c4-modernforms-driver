# Changelog

> **Status (2026-11-13, #213).** In use and current: `tools/changelog.py`,
> the templates and the Release workflow follow it, codename meanings
> included (#192). `CHANGELOG.md` lists 1.0 to 1.9; the lines below that
> describe the empty start state ("as it stands today", the empty codenames
> file) record 2026-10-27.

The contract for the project's one changelog: [`CHANGELOG.md`](../CHANGELOG.md)
lists every release, the Release workflow
([`release.yml`](../.github/workflows/release.yml)) writes each release's
title and notes from it, and every driver package carries the whole list at
the bottom of its Documentation tab. The tool is
[`tools/changelog.py`](../tools/changelog.py); its unit tests are
[`tools/tests/test_changelog.py`](../tools/tests/test_changelog.py).

## 1. The source: `CHANGELOG.md`

One file at the repository root, written by hand, newest first. Only
releases are listed: a release is a GitHub release that the Release workflow
cut from `main`. Prereleases, development builds and builds installed for
tests are never listed; the next release's entry carries what they changed.

```markdown
# Changelog

<free text: one paragraph saying what is listed and how versions and
build numbers relate; no headings>

## Unreleased

### Fixed
- One line per change, written for the people who install and use the
  driver. Issue numbers in brackets at the end: (#12).

## 1.0 "Name", build 42 (2026-11-02)

### Added
- ...
### Changed
- ...
### Fixed
- ...
### Security
- ...
### Known limits
- ...
```

Rules the checker enforces:

- The first line is `# Changelog`, and nothing before `## Unreleased` is a
  heading.
- The first `##` heading is exactly `## Unreleased`; it may be empty (no
  `###` sections and no bullets). Until the first release it is the only
  `##` heading, and the file passes as it stands today.
- Every other `##` heading matches
  `^## (\d+)\.(\d+) "([^"]+)", build (\d+) \((\d{4}-\d{2}-\d{2})\)$`:
  version, codename, build number, date (a day that exists).
- Released entries are ordered by build number, strictly decreasing; dates
  never increase going down; every entry carries the codename that
  `.github/codenames.json` gives its version X.Y (below).
- Inside an entry only `###` headings from this list, in this order, each
  at most once: `Added`, `Changed`, `Fixed`, `Security`, `Known limits`.
- Under a `###` heading only bullet lines (`- `) and their continuation
  lines (indented by two spaces); a blank line and a line indented by two
  spaces start the bullet's next paragraph. No nested lists, no tables, no
  HTML, no code blocks, no block quotes.
- Inline markup allowed in bullets: `` `code` ``, `**bold**`, and issue or
  PR references `#123`. Links `[text](url)` render as their text. Italics,
  strikethrough, images, entities and raw HTML are refused, since the
  Documentation tab would not show them as GitHub does.
- Every released entry has at least one bullet.

### Codenames: `.github/codenames.json`

Every X.Y has its own codename, and every build and prerelease of X.Y keeps
it. How names are chosen is kept out of the repository and out of every
public text (owner, 2026-11-08, #128, #130): titles carry the name, nothing
more. One file,
[`.github/codenames.json`](../.github/codenames.json), names them, and the
tool takes every codename from it. It started empty, `{}`; since
2026-10-27 (#6) 1.0 is "Arrakis". Filled in, it reads like this (the names here only show the form):

```json
{
  "1.0": "Name",
  "1.1": "Another Name"
}
```

- One JSON object. Each key is a version X.Y without leading zeros, once. A
  prerelease X.Y-beta.N has no key of its own: every build of X.Y, its
  betas included, takes the name of X.Y.
- Each name is plain, ASCII letters and digits joined by single spaces or
  hyphens (`Two Words`, `Hyphen-Name`), and no two versions share one,
  whatever the letter case.
- `check` reports what breaks these rules, each as
  `.github/codenames.json: message`, and every released entry whose X.Y
  the file does not name or whose codename is not the file's, at the
  entry's line.
- A version the file does not name cannot be built as a release or a
  prerelease: `html`, `notes` and `stamp` refuse it with
  `1.0 has no codename in .github/codenames.json: each X.Y gets its own
  there before its first build, ...`, and the Release workflow refuses it
  in its first step, before anything is built. With the file empty, nothing
  can be released before the owner has approved the name of 1.0.
- Before the first build of a new X.Y, its first prerelease included, the
  coordinator proposes its codename and waits for the owner's approval;
  a pull request then adds it, with its meaning (below). Renaming an X.Y
  that has published builds also means rewriting its meaning and correcting
  those releases' titles and notes and their Discussions announcements.

### Codename meanings: `.github/codename-meanings.json`

Every release's and prerelease's notes open with what its codename means
(owner, 2026-11-10, #192; the contract is
`docs/codename-meanings-design.md`): what the name is in the story it comes
from and, where it fits, how that ties to what the version changed. Only the
meaning is published; how the names are chosen is not (above).
One file, `.github/codename-meanings.json`, holds the meaning of each X.Y,
and every build and prerelease of that X.Y opens its notes with it
(section 4). Its form (the text here only shows the form):

```json
{
  "1.0": "**Name** is what the name is in its story, and how that fits what 1.0 changed.",
  "1.1": "**Another Name** is ..."
}
```

- One JSON object with the keys of `.github/codenames.json`: each a version
  X.Y without leading zeros, once, that the codenames file names. Every X.Y
  the codenames file names has a meaning; a prerelease takes its X.Y's.
- Each meaning is one paragraph of plain Markdown, 1 to 3 sentences, that
  starts with the codename in bold. The tool checks that it is a string,
  not empty, on one line (no line break of any kind), at most 450
  characters (characters, not bytes) and that it contains the codename
  exactly as `.github/codenames.json` writes it. What it says about the
  story must be right, and the tie must be true of that version's entries
  in `CHANGELOG.md`; a meaning says nothing about how its name was chosen
  or which one comes next.
- `check` reports what breaks these rules, each as
  `.github/codename-meanings.json: message`:
  - `1.8 has no meaning: every X.Y of .github/codenames.json has the meaning
    of its codename here, written with the name before its first build
    (docs/changelog-design.md)`
  - `"1.8": the meaning is empty`, `"1.8": a meaning is one paragraph of
    text, not 42` (or `null`, `an array`, ...)
  - `"1.8": the meaning has a line break: it is one paragraph, on one line`
  - `"1.8": the meaning is 451 characters long, over 450`
  - `"1.8": the meaning does not contain its codename "Name" as
    .github/codenames.json writes it`
  - `"v1.8": a key is a version X.Y, such as "1.0", without leading zeros,
    as in .github/codenames.json`, `"1.8" is a key twice: each X.Y has one
    meaning`, and `"2.0": .github/codenames.json does not name 2.0: a
    meaning explains the codename that file gives its X.Y`

  A file that is not one JSON object, or cannot be read, is refused with
  `error:` and nothing else is checked.
- `notes` refuses a meanings file that fails `check`, so no notes are
  written for a version without a meaning, and the Release workflow refuses
  an X.Y whose codename has no meaning in its first step, before anything is
  built. `html` and `stamp` do not read the file: the Documentation tabs
  and `CHANGELOG.md` carry no meanings.
- The meaning is written in the same pull request as its codename, before
  the first build of the X.Y. Changing it later changes the notes of the
  next run of the Release workflow for that version (a moved tag); the
  notes of releases already published are edited on GitHub by hand, the
  meaning paragraph only.

## 2. The tool: `tools/changelog.py`

Python 3.12, standard library only.

```
changelog.py check  [--file CHANGELOG.md] [--codenames .github/codenames.json]
                    [--meanings .github/codename-meanings.json]
changelog.py html   [--file F] [--codenames C]
                    [--release VERSION --build N --date YYYY-MM-DD]
                    [--dev-build N] [--codename NAME]
changelog.py notes  [--file F] [--codenames C] [--meanings M]
                    --version VERSION --build N --date YYYY-MM-DD
                    [--codename NAME] [--template .github/release-notes.md]
changelog.py stamp  [--file F] [--codenames C]
                    --version VERSION --build N --date YYYY-MM-DD
                    [--codename NAME]
```

`--codenames` names another codenames file than `.github/codenames.json`,
and `--meanings` (`check` and `notes` only) another meanings file than
`.github/codename-meanings.json` (the tests use their own).

- `check`: validates section 1, the codenames and meanings files included; prints
  `CHANGELOG.md: ok (N releases)`, or every problem (in `CHANGELOG.md` with
  its line number, in the other two files without) and the number of each
  file's problems, and exits 1.
- `html`: prints an HTML fragment (no `<html>` or `<body>`) for a
  Documentation tab: `<h2 id="changelog">Changelog</h2>`, one sentence of
  introduction, then per entry an `<h3>` with the heading text and per
  category a `<p><b>Fixed</b></p>` and a `<ul>` of `<li>`. Text is
  HTML-escaped and ASCII only; `` `code` `` becomes `<code>`, `**x**`
  becomes `<b>`, links become their text, `#123` stays text. With no
  release to show it says "No release yet."
  - With `--release`: the `Unreleased` entry, if it has bullets, is
    rendered as that release (`1.0 "Name", build N (date)`). The codename
    is the one `.github/codenames.json` gives the version's X.Y, and a
    version the file does not name is refused. `--codename` (`html`,
    `notes` and `stamp` all accept it) only confirms that name: any other
    is refused, and it never names a version the file does not.
  - With `--dev-build N`: a non-empty `Unreleased` renders as
    `Unreleased (development build N)`.
  - With neither: a non-empty `Unreleased` renders as `Unreleased`.
  - An empty `Unreleased` is never rendered.
- `notes`: prints the Markdown that the Release workflow publishes as the
  release's notes, from `.github/release-notes.md` (section 4) with its
  placeholders filled, the meaning of the version's codename first. It
  refuses (exit 1) when `Unreleased` has no bullets (a release must say what
  it changes), a meanings file that fails `check`, and a template that does
  not open with `{meaning}` (section 4).
- `stamp`: rewrites the file: the `Unreleased` heading becomes the released
  heading for `--version`, `--build` and `--date` (codename from
  `.github/codenames.json`), and a new empty `## Unreleased` is inserted
  above it. Refuses when `Unreleased` is empty or when the build already
  has an entry. Writes the file only after the result passes `check`.
- `html`, `notes` and `stamp` refuse a changelog or codenames file that
  fails `check`, `notes` a meanings file too, and a build or date that would
  not make the new entry the newest.

Prereleases ([`prerelease-design.md`](prerelease-design.md)): `--version`
and `html --release` also take `X.Y-beta.N`, which is never an entry of
`CHANGELOG.md`. `html` shows a non-empty `Unreleased` entry as
`1.0 beta 1 "Name" (prerelease), build N (date)`, with the codename of its
X.Y, never as the release. `notes` fills `.github/prerelease-notes.md` (its
default for a prerelease) without `{history}`. `stamp` refuses a
prerelease, and `html` and `notes` refuse a prerelease of a version the file
lists already: a prerelease comes before its release.

**A prerelease before the first release** (decided with the scaffold,
2026-10-27: the house and an outside tester try 1.0 betas before 1.0): while
`CHANGELOG.md` lists no release, `X.Y-beta.N` is accepted like any other
prerelease. Its notes then have no release to follow, so `{stable}` and
`{stable_version}` have no value: the template's lines for that case are its
`<!-- if no stable -->` blocks (section 4), and a template that names
`{stable}` outside an `<!-- if stable -->` block is refused with a message
that says so, rather than published with a link to no release.

Exit codes: 0 done, 1 refused or invalid, 2 usage.

## 3. Where it shows

- **Composer:** each driver's `www/documentation.html` carries one marker
  line `<!-- CHANGELOG -->` as the last section before the footer.
  [`tools/build.sh`](../tools/build.sh) replaces that marker in the
  **staged** copy with `changelog.py html`'s output: with `--release
  <version> --build <build> --date <today>` when the build is of a release
  or prerelease tag (the Release workflow names its tag; locally, a `v*`
  tag on HEAD), with `--dev-build <build>` in a `--dev` build, and with
  neither otherwise. The file in `src/` keeps the marker. A build whose
  documentation lacks the marker, or whose changelog fails `check`, fails.
  The build number is `git rev-list --count HEAD`, the Driver Version
  Composer shows.
- **GitHub, per release:** the Release workflow's build job runs
  `changelog.py notes` and hands the notes to the publish job with the
  packages; the publish job sets them as the release's notes on every run.
  The title is the notes' first heading without its `(build N)` for a
  release (`1.0 "Name"`), and the whole heading for a prerelease
  (`1.0 beta 1 "Name" (build N)`). A run with an empty `Unreleased` fails in
  the build job.
- **GitHub, the running list:** `CHANGELOG.md` itself, linked from the
  README, from each release's notes and from the Discussions announcement.

## 4. The notes templates

[`.github/release-notes.md`](../.github/release-notes.md) and
[`.github/prerelease-notes.md`](../.github/prerelease-notes.md) hold the
fixed part of every release's notes (what you get, requirements, install,
going back, verify, licence), with placeholders:

| Template | Placeholders |
| --- | --- |
| release | `{version}` (1.0), `{codename}`, `{meaning}` (the meaning of the codename, section 1), `{build}`, `{date}`, `{this_build}` (the `Unreleased` entry's sections as Markdown), `{history}` (every released entry of the same version, newest first, each under a `###` heading; for a new version "None: build N is the first build of X.Y.") |
| prerelease | `{version}` (1.0-beta.1), `{release}` (1.0), `{beta}` (1), `{codename}`, `{meaning}`, `{build}`, `{date}`, `{this_build}`, and while `CHANGELOG.md` lists a release `{stable}` (the newest release's heading) and `{stable_version}` (its version) |

- The first line is the heading the Release workflow reads the title from:
  `## {version} "{codename}" (build {build})` for a release,
  `## {release} beta {beta} "{codename}" (build {build})` for a prerelease.
- The first paragraph after it is `{meaning}`, alone on its line after a
  blank line, so the notes open with the meaning of the codename, before
  `Released {date}.` or "A prerelease for testing". `notes` refuses a
  template without `{meaning}`, and one whose first line after the heading
  that is not blank is anything else (once the blocks below are resolved).
- `{this_build}` is required; an unknown placeholder is refused; a value is
  never filled in again, so a bullet that shows `{build}` in code, or a
  meaning that does, keeps it.
- Neither template names or counts the packages: a release carries one
  `.c4z` per `src/<name>/driver.xml`, so they say "every `.c4z` file of the
  release".
- **Alternatives:** a line that is exactly `<!-- if stable -->` or
  `<!-- if no stable -->` opens a block that a line `<!-- end if -->`
  closes. An `if stable` block is kept while `CHANGELOG.md` lists a
  release, an `if no stable` block only while it lists none; the marker
  lines never reach the notes. Blocks do not nest, and a block that is never
  ended, or an end with no block, is refused with the template's line. Put
  blank lines outside the blocks. The prerelease template needs them for
  the sentence about the release it follows, the heading of its changes and
  its "going back" section:

  ```markdown
  <!-- if stable -->
  It follows the stable release [{stable}](https://github.com/corytron/c4-modernforms-driver/releases/tag/v{stable_version}). The changes below are everything since then: they are what to try.
  <!-- end if -->
  <!-- if no stable -->
  It comes before the first release of this project: there is no stable release to compare it with or to go back to.
  <!-- end if -->
  ```

## 5. Process

- A PR that changes what the driver does, or what its documentation says,
  adds a line under `## Unreleased` with the issue number (the PR template
  asks).
- After a release, the desired-state PR (`deploy/house.yaml`,
  [`cicd-gitops-design.md`](cicd-gitops-design.md), section 6) also runs
  `python3 tools/changelog.py stamp --version X.Y --build N --date
  YYYY-MM-DD`, so `CHANGELOG.md` names the build that was published. A
  prerelease is never stamped.
- `tools/check.sh` runs the check `changelog`
  (`python3 -I tools/changelog.py check --file CHANGELOG.md`), and CI's
  tooling job runs it on every pull request.
- The codename of a new X.Y is proposed and approved before its first build
  (section 1), and its meaning is written with it in the same pull request;
  [`release-checklist.md`](release-checklist.md) has the steps of a release.

## 6. How it is checked

- [`tools/tests/test_changelog.py`](../tools/tests/test_changelog.py) runs
  every rule and command on small synthetic changelogs, codenames files,
  meanings files and templates, never on the repository's `CHANGELOG.md`; a
  few tests read the repository's codenames and meanings files and notes
  templates, to prove that they pass the rules, fill every placeholder, open
  with the meaning and give the Release workflow its title line. No test
  depends on what a meaning of the repository says.
- The `changelog` check of `tools/check.sh` runs `check` on the
  repository's file, and `tools/build.sh` runs it again before it renders.
- `tools/check_links.py` treats a manual's `<!-- CHANGELOG -->` line as the
  `<h2 id="changelog">` that replaces it.
