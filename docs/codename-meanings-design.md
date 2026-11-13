# Codename meanings in the release notes: design contract

> **Contract for [issue #192](https://github.com/corytron/c4-modernforms-driver/issues/192)**
> (2026-11-10). The owner asked that every release's notes, past and future,
> open with what its codename means in the story it comes from and, where it
> fits, how that ties to what the release changed. How the names are chosen
> stays private: only each name's meaning is published.

> **Status (2026-11-13, #213).** In use and current: the meanings file
> covers 1.0 to 1.9, `tools/changelog.py check` and the Release workflow
> enforce CM-D5, and CM-D6's rewrite of the past notes was a one-off.

## 1. Decisions

| # | Decision |
| --- | --- |
| CM-D1 | **The source:** `.github/codename-meanings.json`, an object keyed by X.Y like `.github/codenames.json`: `{"1.0": "<meaning>", ...}`. One meaning per X.Y, used by every build and every prerelease of it. |
| CM-D2 | **The text:** one paragraph, plain Markdown, 1 to 3 sentences, at most 450 characters. It starts with the codename in bold and says what it is in Dune (the books and the films), then, where it fits, ties it to what that version changed (for example: Stillsuit, the Fremen suit that wastes nothing, and 1.7 hides the LED settings that a fan without a keypad cannot use). Facts about Dune must be right; the tie must be true of that version's CHANGELOG entries. |
| CM-D3 | **Never published:** how the names are chosen, their order or their source list. A meaning never says why a name was picked, what comes next, or that names follow a rule; it does not need to say "Dune" more than once. |
| CM-D4 | **Placement:** `tools/changelog.py notes` puts the meaning as the first paragraph of the notes, right after the `## {version} "{codename}" (build {build})` heading and before `Released {date}.`, through a `{meaning}` placeholder in `.github/release-notes.md` and `.github/prerelease-notes.md`. |
| CM-D5 | **Enforced:** `tools/changelog.py check` fails when an X.Y of `.github/codenames.json` has no meaning, a meaning is empty, over 450 characters, has a line break, or does not contain its codename; `notes` refuses a version without one; the Release workflow's first step (the one that refuses an X.Y without a codename) also refuses one without a meaning, so nothing is released without it. |
| CM-D6 | **Past releases:** the coordinator rewrites the notes of every existing release (v1.0 to v1.7, v1.0-beta.1 to beta.3) once, inserting the meaning paragraph right after the first heading and changing nothing else. A later run of the Release workflow for a moved tag writes the notes from the template, meaning included. |
| CM-D7 | **Before the first build of a new X.Y** the meaning is written with its codename (same PR), so the checks pass; `CLAUDE.md` says so. |

## 2. Pieces and owners

| Piece | Owner | Files |
| --- | --- | --- |
| Tooling, templates, workflow step, tests, release docs | agent A | `tools/changelog.py`, `tools/tests/test_changelog.py`, `.github/release-notes.md`, `.github/prerelease-notes.md`, `.github/workflows/release.yml`, `docs/changelog-design.md`, `docs/release-checklist.md` |
| The meanings 1.0 to 1.7 | agent B | `.github/codename-meanings.json` |
| Integration, `CLAUDE.md`, `docs/README.md`, past release notes | coordinator | the rest |
