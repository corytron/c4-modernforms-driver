# Documentation review: coherence, contradictions and organisation

> **Contract for [issue #213](https://github.com/corytron/c4-modernforms-driver/issues/213)**
> (2026-11-13). The owner: "take a look at all documentation, both in the
> driver, and on github, and look for logical errors as it reads. Like
> saying we support 3 speeds, then pointing out later we have six. lets do a
> full review and try to make it more coherent, cogent, and readably
> organized." Five agents review disjoint sets of files at the same time;
> this page is the rules they share.

## 1. What is true

- **The code is the truth**, then `driver.xml`, then [`status.md`](status.md)
  for what runs on the house. A document that disagrees with the code about
  the present is wrong. Check every number, name and default against the
  source before keeping or changing it: property names, defaults and ranges
  in `src/*/driver.xml`; behaviour in `src/modernforms_fan/fan/*.lua` and
  `driver.lua`; texts in `fan/texts.lua`.
- Examples of facts that must agree everywhere: the **fan device has six
  speeds** (the fan proxy, Speed 1 to 6), the **Breeze fan device has three**
  (Breeze 1 to 3, a separate package since 1.3); Gen 1 to 3 fans only; the
  minimum OS is 3.3.0; the current release is 1.9 "Sandwalk", build 220;
  `Speed LED Rest (s)` defaults to 5; 21 keypad LED rows show only while a
  speed link is bound; the light's `Light Min On (%)` (1.8) and the
  animations' pause in the dark (1.9) exist.
- When the code itself looks wrong, do not "fix" the document to match a
  guess: report it in the hand-back.

## 2. What to change, by kind of document

| Kind | Files | Rule |
| --- | --- | --- |
| **Reader-facing** | The two Documentation tabs, `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `docs/README.md`, `docs/status.md`, `docs/design.md`, `docs/composer-checklist.md`, `docs/release-checklist.md`, `probes/README.md` | Make them **true, consistent and well organised**: fix every contradiction and every stale statement, remove repetition that says the same thing twice in different words, put the present first and history after, use headings a reader can scan, keep sections in the order a dealer or owner needs them. Rewriting and reordering are allowed; keep every fact that is still true and every anchor other pages link to (or update every link to it). |
| **Historical** | Every other `docs/*.md`: contracts (`*-design.md`), research (`*-research.md`), edge cases (`edge-cases-*.md`), `dev-loop.md`, `composer-remote.md`, `fan-probe.md`, `speed-leds-*.md` | They record what was decided when, and are **not rewritten**. Fix only (a) statements that were never true (typos, wrong numbers, wrong names, broken references) and (b) internal contradictions within one document. Where a later release changed a decision, add **one short note** at the top of the document or beside the statement: "Since 1.N (#NNN), …; see `x-design.md`." (with a real link) Do not delete superseded text. |
| **Changelog** | `CHANGELOG.md` | Release notes are history: fix only factual errors in an entry (a wrong property name, a wrong number), never reword. `tools/changelog.py check` must pass. |

## 3. Style

Plain English, short sentences, the driver's own words. Name things as
Composer shows them (`Speed LED Rest (s)`, "Ambient Light Level (Follower)").
No passages of Snap One's or WAC's documents. Placeholders only, never real
LAN data, MACs, client ids, room or project names (fan 10.0.2.151,
controller 10.0.2.10, VM 192.0.2.7, MAC 00:00:5e:00:53:01, client id
MF_00005E005301). How release codenames are chosen is never explained in
any public text (only each name's meaning, in `.github/codename-meanings.json`).

## 4. Pieces and owners

| Agent | Files |
| --- | --- |
| D1 | `src/modernforms_fan/www/documentation.html` |
| D2 | `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `src/modernforms_breeze_fan/www/documentation.html`, `probes/README.md` |
| D3 | `docs/README.md`, `docs/status.md`, `docs/design.md`, `docs/composer-checklist.md`, `docs/release-checklist.md` |
| D4 | the historical contracts and design notes: `docs/*-design.md` (all but `doc-coherence-design.md`), `docs/dev-loop.md`, `docs/composer-remote.md`, `docs/fan-probe.md`, `docs/speed-leds-c4-guidelines.md`, `docs/speed-leds-engine-options.md` |
| D5 | the historical research and edge cases: `docs/*-research.md`, `docs/edge-cases-*.md` |
| Coordinator | this file, `CLAUDE.md` (findings about it are reported, not edited by agents), integration, checks |

## 5. Checks

`python3 tools/check_links.py` (every link and anchor, including the
Documentation tabs), `python3 tools/changelog.py check`, an HTML parse of each
Documentation tab, and `tools/build.sh` (it renders the changelog into the
tabs). Each agent hands back a findings table: file, what was wrong, what it
says now.
