"""Unit tests for tools/changelog.py, on small synthetic changelogs and codenames files in a temporary
directory; never the repository's CHANGELOG.md (docs/changelog-design.md).

Run: python3 -B -m unittest discover -s tools/tests -v
"""

import argparse
import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from html.parser import HTMLParser

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import changelog  # noqa: E402

SCRIPT = os.path.join(TOOLS, "changelog.py")

# Line numbers: 5 "## Unreleased", 7 its "### Fixed", 8 and 9 its bullets (9 continues on 10),
# 12 build 61 (14 Added, 16 Fixed), 19 build 48 (21 Changed, 24 Known limits), 27 build 20 of 0.9.
UNRELEASED_BODY = (
    "### Fixed\n"
    "- The light slider no longer jumps back after a dim (#31).\n"
    "- Keypad LEDs follow a speed set in the Modern Forms app,\n"
    "  also after the fan loses power (#32).\n"
    "\n"
)
SAMPLE = (
    "# Changelog\n"
    "\n"
    "Every release of the drivers, newest first; builds count the commits of the repository.\n"
    "\n"
    "## Unreleased\n"
    "\n" + UNRELEASED_BODY + '## 1.0 "Arrakis", build 61 (2026-12-02)\n'
    "\n"
    "### Added\n"
    "- A `Status` property in Composer (#20).\n"
    "### Fixed\n"
    "- **Speed links** survive a power cut; see [the manual](https://example.com/manual#links) (#18).\n"
    "\n"
    '## 1.0 "Arrakis", build 48 (2026-12-01)\n'
    "\n"
    "### Changed\n"
    "- The fan is followed through a change of its IP address.\n"
    "\n"
    "### Known limits\n"
    "- No sleep timer yet.\n"
    "\n"
    '## 0.9 "Jamis", build 20 (2026-11-20)\n'
    "\n"
    "### Added\n"
    "- The first build.\n"
)
EMPTY_UNRELEASED = SAMPLE.replace(UNRELEASED_BODY, "")

# The codenames file of the tests, invented for them (the project's own names are in
# .github/codenames.json): SAMPLE's 0.9 and 1.0, and 1.1 for the next release and its betas; 2.0 has
# none. "Stilgar" is only ever a name that is refused.
CODENAME_OF = {"0.9": "Jamis", "1.0": "Arrakis", "1.1": "Shishakli"}
CODENAMES = json.dumps(CODENAME_OF, indent=2) + "\n"
MISSING = (
    "has no codename in %s: each X.Y gets its own there before its first build, a name from Dune (Denis "
    "Villeneuve's films) that the owner approves (docs/changelog-design.md)"
)

TEMPLATE = (
    '## {version} "{codename}" (build {build})\n'
    "\n"
    'Released {date}. Braces that name no placeholder stay: {"key": 1}, ${{ github.sha }}, {Version}.\n'
    "\n"
    "### New in build {build}\n"
    "\n"
    "{this_build}\n"
    "\n"
    "### Earlier builds of {version}\n"
    "\n"
    "{history}\n"
    "\n"
    "Every release: CHANGELOG.md.\n"
)

RELEASE = ("--version", "1.0", "--build", "70", "--date", "2026-12-09")
HTML_RELEASE = ("--release", "1.0", "--build", "70", "--date", "2026-12-09")
NEW_HEADING = '## 1.0 "Arrakis", build 70 (2026-12-09)'

# Prereleases (docs/prerelease-design.md): the same Unreleased entry, never shown as the release.
PRERELEASE = ("--version", "1.1-beta.1", "--build", "70", "--date", "2026-12-09")
HTML_PRERELEASE = ("--release", "1.1-beta.1", "--build", "70", "--date", "2026-12-09")
PRERELEASE_H3 = "<h3>1.1 beta 1 &quot;Shishakli&quot; (prerelease), build 70 (2026-12-09)</h3>"
PRERELEASE_TEMPLATE = (
    '## {release} beta {beta} "{codename}" (build {build})\n'
    "\n"
    "Version {version}, built {date}, follows [{stable}](https://example.com/v{stable_version}).\n"
    "\n"
    "{this_build}\n"
)
# The same with the alternatives a prerelease before the first release needs
# (docs/changelog-design.md, section 4).
BLOCK_TEMPLATE = (
    '## {release} beta {beta} "{codename}" (build {build})\n'
    "\n"
    "Version {version}, built {date}.\n"
    "\n"
    "<!-- if stable -->\n"
    "It follows [{stable}](https://example.com/v{stable_version}).\n"
    "<!-- end if -->\n"
    "<!-- if no stable -->\n"
    "No release precedes it.\n"
    "<!-- end if -->\n"
    "\n"
    "{this_build}\n"
)
FIRST_PRERELEASE = ("--version", "1.0-beta.1", "--build", "12", "--date", "2026-11-30")


def text_of(*rows):
    """A file made of rows, one per line: row k is line k + 1."""
    return "\n".join(rows) + "\n"


# A CHANGELOG.md that lists no release yet, with something to release.
FIRST = text_of(
    "# Changelog",
    "",
    "Every release of the drivers, newest first.",
    "",
    "## Unreleased",
    "",
    "### Added",
    "- The fan driver (#3).",
)


class TagCollector(HTMLParser):
    """Every tag of an HTML fragment with its attributes, and whether it holds anything else."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags = []
        self.other = []

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, attrs))

    def handle_startendtag(self, tag, attrs):
        self.tags.append((tag, attrs))

    def handle_comment(self, data):
        self.other.append("comment " + data)

    def handle_decl(self, decl):
        self.other.append("declaration " + decl)

    def handle_pi(self, data):
        self.other.append("processing instruction " + data)


# ---------------------------------------------------------------------------
# The parser
# ---------------------------------------------------------------------------


class ParseTest(unittest.TestCase):
    def test_entries_with_their_fields_and_line_numbers(self):
        parsed = changelog.parse(SAMPLE)
        self.assertEqual(parsed.problems, [])
        self.assertEqual(
            [
                (entry.kind, entry.line, entry.version, entry.codename, entry.build, entry.date)
                for entry in parsed.entries
            ],
            [
                ("unreleased", 5, None, None, None, None),
                ("release", 12, (1, 0), "Arrakis", 61, "2026-12-02"),
                ("release", 19, (1, 0), "Arrakis", 48, "2026-12-01"),
                ("release", 27, (0, 9), "Jamis", 20, "2026-11-20"),
            ],
        )
        self.assertIs(parsed.unreleased, parsed.entries[0])
        self.assertEqual([entry.build for entry in parsed.releases], [61, 48, 20])
        self.assertEqual(parsed.entries[1].heading, '1.0 "Arrakis", build 61 (2026-12-02)')
        self.assertEqual(
            [[(section.name, section.line) for section in entry.sections] for entry in parsed.entries],
            [[("Fixed", 7)], [("Added", 14), ("Fixed", 16)], [("Changed", 21), ("Known limits", 24)], [("Added", 29)]],
        )
        fixed = parsed.unreleased.sections[0]
        self.assertEqual([bullet.line for bullet in fixed.bullets], [8, 9])
        self.assertEqual(
            fixed.bullets[1].paragraphs[0].text,
            "Keypad LEDs follow a speed set in the Modern Forms app, also after the fan loses power (#32).",
        )
        self.assertEqual(
            fixed.bullets[1].source,
            ["- Keypad LEDs follow a speed set in the Modern Forms app,", "  also after the fan loses power (#32)."],
        )
        self.assertEqual(parsed.unreleased.bullet_count(), 2)

    def test_empty_unreleased_entry(self):
        parsed = changelog.parse(EMPTY_UNRELEASED)
        self.assertEqual(parsed.problems, [])
        self.assertEqual(parsed.unreleased.sections, [])
        self.assertEqual(parsed.unreleased.bullet_count(), 0)

    def test_no_release_yet(self):
        parsed = changelog.parse(text_of("# Changelog", "", "Every release, newest first.", "", "## Unreleased"))
        self.assertEqual(parsed.problems, [])
        self.assertEqual((parsed.unreleased.line, parsed.releases), (5, []))

    def test_crlf_line_endings(self):
        parsed = changelog.parse(SAMPLE.replace("\n", "\r\n"))
        self.assertEqual(parsed.problems, [])
        self.assertEqual([entry.build for entry in parsed.releases], [61, 48, 20])
        self.assertEqual(parsed.unreleased.sections[0].bullets[1].source[1], "  also after the fan loses power (#32).")


class MultiParagraphTest(unittest.TestCase):
    """A blank line, then a line indented by two spaces: the bullet's next paragraph."""

    TEXT = text_of(
        "# Changelog",
        "",
        "## Unreleased",
        "",
        "### Fixed",
        "- First paragraph of the bullet,",  # 6
        "  wrapped once.",
        "",
        "  Second paragraph of the same bullet (#9).",  # 9
        "- Next bullet.",  # 10
    )

    def test_parsed_as_two_paragraphs_of_one_bullet(self):
        parsed = changelog.parse(self.TEXT)
        self.assertEqual(parsed.problems, [])
        bullets = parsed.unreleased.sections[0].bullets
        self.assertEqual([bullet.line for bullet in bullets], [6, 10])
        self.assertEqual(
            [paragraph.text for paragraph in bullets[0].paragraphs],
            ["First paragraph of the bullet, wrapped once.", "Second paragraph of the same bullet (#9)."],
        )
        self.assertEqual(
            bullets[0].source,
            ["- First paragraph of the bullet,", "  wrapped once.", "", "  Second paragraph of the same bullet (#9)."],
        )
        self.assertEqual(bullets[0].paragraphs[1].line_at(0), 9)

    def test_html_gives_each_paragraph_its_p(self):
        out = changelog.render_html(changelog.parse(self.TEXT), "Unreleased")
        self.assertIn(
            "<li><p>First paragraph of the bullet, wrapped once.</p>"
            "<p>Second paragraph of the same bullet (#9).</p></li>\n<li>Next bullet.</li>",
            out,
        )

    def test_notes_keep_the_lines_as_written(self):
        self.assertEqual(
            changelog.markdown_sections(changelog.parse(self.TEXT).unreleased),
            "**Fixed**\n\n- First paragraph of the bullet,\n  wrapped once.\n\n"
            "  Second paragraph of the same bullet (#9).\n- Next bullet.",
        )

    def test_a_problem_in_the_second_paragraph_names_its_line(self):
        text = self.TEXT.replace("same bullet (#9).", "same <b>bullet</b> (#9).")
        self.assertEqual([line for line, _ in changelog.parse(text).problems], [9])


# ---------------------------------------------------------------------------
# check: every rule of section 1, each with its line number
# ---------------------------------------------------------------------------


class CheckRulesTest(unittest.TestCase):
    HEAD = ["# Changelog", "## Unreleased", "### Fixed", "- A fix."]  # a fifth row is line 5

    def assertProblems(self, rows, *expected, codenames=None):
        """Exactly the expected (line, fragment of the message) problems, in line order."""
        problems = changelog.parse(text_of(*rows), codenames).problems
        self.assertEqual([line for line, _ in problems], [line for line, _ in expected], problems)
        for (_, message), (_, fragment) in zip(problems, expected, strict=True):
            self.assertIn(fragment, message)

    def release(self, build, date="2026-12-02", codename="Arrakis", version="1.0"):
        return ['## %s "%s", build %d (%s)' % (version, codename, build, date), "### Fixed", "- A fix."]

    def test_sample_passes(self):
        self.assertEqual(changelog.parse(SAMPLE).problems, [])
        self.assertEqual(changelog.parse(EMPTY_UNRELEASED).problems, [])

    def test_first_line_is_the_title(self):
        self.assertProblems(["# Change log", "", "## Unreleased"], (1, "the first line must be '# Changelog'"))
        self.assertProblems(["## Unreleased"], (1, "the first line must be '# Changelog', not '## Unreleased'"))
        self.assertProblems(
            ["# Changelog", "", "# Second title", "## Unreleased"], (3, "no headings before '## Unreleased'")
        )

    def test_no_headings_in_the_introduction(self):
        self.assertProblems(
            ["# Changelog", "", "### Notes", "Text.", "  ## Indented", "", "## Unreleased"],
            (3, "no headings before '## Unreleased'"),
            (5, "no headings before '## Unreleased'"),
        )

    def test_first_entry_heading_is_unreleased(self):
        self.assertProblems(
            ["# Changelog", ""] + self.release(61),
            (3, "the first ## heading must be '## Unreleased' (it may be empty), not '## 1.0"),
        )
        self.assertProblems(["# Changelog", "## unreleased"], (2, "not '## unreleased'"))
        self.assertProblems(["# Changelog", "", "Intro."], (3, "no '## Unreleased' heading"))
        self.assertProblems([], (1, "the first line must be"), (1, "no '## Unreleased' heading"))

    def test_unreleased_only_once(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(61) + ["## Unreleased"],
            (6, "'## Unreleased' only once"),
        )

    def test_unreleased_may_be_empty(self):
        self.assertProblems(["# Changelog", "", "## Unreleased", ""] + self.release(61))
        self.assertProblems(["# Changelog", "## Unreleased"])

    def test_release_heading_shape(self):
        for heading in (
            '## 1.0 "Arrakis" build 61 (2026-12-02)',
            "## 1.0 Arrakis, build 61 (2026-12-02)",
            '## v1.0 "Arrakis", build 61 (2026-12-02)',
            '## 1 "Arrakis", build 61 (2026-12-02)',
            '## 1.0 "", build 61 (2026-12-02)',
            '## 1.0 "Arrakis", Build 61 (2026-12-02)',
            '## 1.0 "Arrakis", build 61 (02.12.2026)',
            '## 1.0 "Arrakis", build 61 (2026-12-02) ',
            '##  1.0 "Arrakis", build 61 (2026-12-02)',
            '## 1.0-beta.1 "Arrakis", build 61 (2026-12-02)',
            "## Released",
        ):
            with self.subTest(heading=heading):
                self.assertProblems(
                    ["# Changelog", "## Unreleased", heading, "### Fixed", "- A fix."],
                    (3, "a release heading reads '## 1.0 \"Name\", build 42 (2026-11-02)', not %r" % heading),
                )

    def test_release_date_exists(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(61, date="2026-02-30"), (3, "no such date: 2026-02-30")
        )

    def test_builds_strictly_decrease(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(40) + self.release(61, date="2026-12-01"),
            (6, "build 61 is below build 40 on line 3"),
        )
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(61) + self.release(61),
            (6, "build 61 has an entry already, on line 3"),
        )

    def test_dates_never_increase(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(61, date="2026-12-01") + self.release(40),
            (6, "2026-12-02 is below 2026-12-01 on line 3"),
        )
        self.assertProblems(["# Changelog", "## Unreleased"] + self.release(61) + self.release(40))  # same day

    def test_each_release_carries_the_codename_of_its_version(self):
        codenames = changelog.parse_codenames(CODENAMES)
        head = ["# Changelog", "## Unreleased"]
        self.assertProblems(
            head
            + self.release(80, version="1.1", codename="Shishakli")
            + self.release(61)
            + self.release(20, version="0.9", codename="Jamis"),
            codenames=codenames,
        )
        # One codename per X.Y, not per major version: 1.1 does not take 1.0's, nor any other.
        self.assertProblems(
            head + self.release(80, version="1.1", codename="Arrakis") + self.release(61),
            (3, '1.1 is named "Shishakli" in .github/codenames.json, not "Arrakis"'),
            codenames=codenames,
        )
        self.assertProblems(
            head + self.release(80, version="1.1", codename="Stilgar") + self.release(61, codename="arrakis"),
            (3, '1.1 is named "Shishakli" in .github/codenames.json, not "Stilgar"'),
            (6, '1.0 is named "Arrakis" in .github/codenames.json, not "arrakis"'),
            codenames=codenames,
        )
        self.assertProblems(
            head + self.release(90, version="2.0", codename="Gurney Halleck") + self.release(61),
            (3, "2.0 " + MISSING % ".github/codenames.json"),
            codenames=codenames,
        )
        # The codenames file the project starts with names nothing: every release is refused.
        self.assertProblems(
            head + self.release(61),
            (3, "1.0 " + MISSING % ".github/codenames.json"),
            codenames=changelog.parse_codenames("{}"),
        )
        # Without a codenames file the parser checks the form only.
        self.assertProblems(
            head + self.release(90, version="2.0", codename="Gurney Halleck") + self.release(61, codename="arrakis")
        )

    def test_only_known_categories(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", "### Removed", "- A removal."], (3, "unknown category 'Removed'")
        )
        self.assertProblems(
            ["# Changelog", "## Unreleased", "### Fixed ", "- A fix."], (3, "unknown category 'Fixed '")
        )
        self.assertProblems(["# Changelog", "## Unreleased", "### fixed", "- A fix."], (3, "unknown category 'fixed'"))

    def test_categories_in_order(self):
        self.assertProblems(self.HEAD + ["### Added", "- An addition."], (5, "### Added after ### Fixed"))
        self.assertProblems(
            ["# Changelog", "## Unreleased"]
            + ["### Added", "- a.", "### Changed", "- b.", "### Fixed", "- c.", "### Security", "- d."]
            + ["### Known limits", "- e."]
        )

    def test_each_category_at_most_once(self):
        self.assertProblems(
            self.HEAD + ["### Fixed", "- Another fix."], (5, "### Fixed a second time in this entry (first on line 3)")
        )

    def test_a_category_has_bullets(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", "### Fixed", "", "### Security", "- A fix."],
            (3, "### Fixed has no bullets"),
        )

    def test_every_released_entry_has_a_bullet(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", '## 1.0 "Arrakis", build 61 (2026-12-02)', ""],
            (3, '1.0 "Arrakis", build 61 (2026-12-02) has no bullets'),
        )

    def test_nothing_outside_a_category(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", "Some text.", "- A bullet."],
            (3, "text outside a ### category"),
            (4, "a bullet outside a ### category"),
        )

    def test_only_bullets_and_continuation_lines_under_a_category(self):
        for line, fragment in (
            ("* A star bullet.", "bullets start with '- ', not '* '"),
            ("+ A plus bullet.", "bullets start with '- ', not '+ '"),
            ("1. A numbered line.", "no numbered lists"),
            ("| a | b |", "no tables"),
            ("<div>HTML</div>", "no HTML"),
            ("```", "no code blocks"),
            ("> A quote.", "no block quotes"),
            ("---", "no horizontal rules"),
            ("Plain text.", "only bullets ('- ' and the text) and their continuation lines"),
            ("-x", "only bullets ('- ' and the text) and their continuation lines"),
            (" one space", "indented by exactly two spaces, not 1"),
            ("   three spaces", "indented by exactly two spaces, not 3"),
            ("      code block", "indented by exactly two spaces, not 6"),
            ("\ttab", "not a tab"),
            ("  \ttab", "not a tab"),
            ("-", "an empty bullet"),
            ("- ", "an empty bullet"),
            ("-  Two spaces.", "one space after the dash"),
            ("#### Deeper heading", "only ## and ### headings"),
        ):
            with self.subTest(line=line):
                self.assertProblems(self.HEAD + [line], (5, fragment))

    def test_no_nested_lists_or_other_blocks_in_a_bullet(self):
        for line, fragment in (
            ("  - A nested bullet.", "no nested lists"),
            ("  * A nested star.", "no nested lists"),
            ("  1. A nested number.", "no nested lists"),
            ("  > A quote.", "no block quotes"),
            ("  | a | b |", "no tables"),
            ("  ---", "no rules or underlined headings"),
            ("  ===", "no rules or underlined headings"),
            ("  # A heading.", "no headings inside a bullet"),
            ("  ~~~", "no code blocks"),
        ):
            with self.subTest(line=line):
                self.assertProblems(self.HEAD + [line], (5, fragment))
        for line, fragment in (
            ("- - A nested bullet.", "no nested lists"),
            ("- 2. A nested number.", "no nested lists"),
            ("- # A heading.", "no headings inside a bullet"),
            ("- [ ] A task.", "no task-list boxes"),
            ("- > A quote.", "no block quotes"),
        ):
            with self.subTest(line=line):
                self.assertProblems(self.HEAD[:3] + [line], (4, fragment))
        # After a blank line any number starts a list; within a paragraph only 1 does.
        self.assertProblems(self.HEAD + ["", "  2. A list after a blank line."], (6, "no nested lists"))
        self.assertProblems(self.HEAD[:3] + ["- Wrapped in the", "  2026. year, as text (#5)."])

    def test_continuation_line_needs_a_bullet(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", "### Fixed", "", "  An orphan.", "- A fix."],
            (5, "a continuation line (two spaces) with no bullet above it"),
        )

    def test_inline_markup_rules(self):
        for bullet, fragment in (
            ("- Unclosed `code here.", "unclosed `code`"),
            ("- Closed `code` then a stray ` here.", "unclosed `code`"),
            ("- Unclosed **bold here.", "unclosed **bold**"),
            ("- Three **markers** and ** one.", "unclosed **bold**"),
            ("- Inline <b>HTML</b>.", "no HTML"),
            ("- A <br/> break.", "no HTML"),
            ("- A comment <!-- note -->.", "no HTML"),
            ("- An entity &amp; here.", "no HTML entities"),
            ("- A number &#38; here.", "no HTML entities"),
            ("- An image ![alt](https://example.com/a.png).", "no images"),
            ("- An autolink <https://example.com/a>.", "a link is written [text](url)"),
            ("- A [broken link](https://example.com/a b).", "with no space in the url"),
            ("- A [reference][1] link.", "with no space in the url"),
            ("- Some *italic* text.", "no *italic*"),
            ("- Some _italic_ text.", "no _italic_"),
            ("- Some ~~struck~~ text.", "no ~~strikethrough~~"),
            ("- Italic code *`x`*.", "no *italic*"),
        ):
            with self.subTest(bullet=bullet):
                self.assertProblems(self.HEAD[:3] + [bullet], (4, fragment))

    def test_inline_problem_names_the_line_it_is_on(self):
        self.assertProblems(
            self.HEAD[:3] + ["- First line of the bullet,", "  then <b>HTML</b> on the second,", "  and a third."],
            (5, "no HTML"),
        )
        self.assertProblems(
            self.HEAD[:3] + ["- A `code span", "  across two lines` is fine, but **bold", "  never closes."],
            (5, "unclosed **bold**"),
        )

    def test_allowed_inline_markup_passes(self):
        self.assertProblems(
            self.HEAD[:3]
            + [
                "- `<!-- CHANGELOG -->` in code, and `a*b*c`, `x_y_z`, `&amp;`, `<b>` (#5).",
                "- **Bold**, **`bold code`**, [a link](https://example.com/x_y_z?a=1&b=2) and [`code`](https://example.com).",
                "- Escaped \\*stars\\*, \\_underscores\\_, \\`backticks\\` and \\<b> stay text.",
                "- Sums 2 * 3 * 4, snake_case_name, __init__, a < b, x > y, R&D;, A & B, C# and #123.",
                "- About ~5 to ~10 seconds, ~/path and 5 ~ 6.",
                "- Code ``with `ticks` inside`` and ``` `` ```.",
                "- A box [ ] in the middle of a bullet is text.",
            ]
        )


class CodenamesFileTest(unittest.TestCase):
    """.github/codenames.json (docs/changelog-design.md, section 1): each X.Y its own name."""

    def problems(self, text):
        return changelog.parse_codenames(text).problems

    def test_names_each_version(self):
        codenames = changelog.parse_codenames(CODENAMES)
        self.assertEqual(
            (codenames.path, codenames.names, codenames.problems),
            (changelog.CODENAMES_FILE, {(0, 9): "Jamis", (1, 0): "Arrakis", (1, 1): "Shishakli"}, []),
        )
        self.assertEqual((changelog.parse_codenames("{}").names, self.problems("{}")), ({}, []))
        self.assertEqual(self.problems('{"10.0": "Arrakis", "0.10": "Shishakli"}'), [])
        for name in ("Shai-Hulud", "Gurney Halleck", "Thopter2", "Liet Kynes", "Harah", "0-0-0"):
            with self.subTest(name=name):
                self.assertEqual(self.problems(json.dumps({"12.34": name})), [])

    def test_no_name_twice(self):
        self.assertEqual(
            self.problems('{"1.0": "Arrakis", "1.1": "Shishakli", "1.2": "Shishakli", "2.0": "ARRAKIS"}'),
            [
                '"1.2": "Shishakli" names 1.1 already: each X.Y has its own codename',
                '"2.0": "ARRAKIS" names 1.0 already (as "Arrakis"): each X.Y has its own codename',
            ],
        )

    def test_a_key_is_a_version_x_y(self):
        for key in ("1.0-beta.1", "v1.0", "1", "1.0.0", "01.0", "1.01", "1.", ".1", "", " 1.0", "1.0 ", "1,0"):
            with self.subTest(key=key):
                self.assertEqual(
                    self.problems(json.dumps({key: "Arrakis"})),
                    [
                        '%s: a key is a version X.Y, such as "1.0", without leading zeros; a beta takes the '
                        "codename of its X.Y" % json.dumps(key)
                    ],
                )
        self.assertEqual(len(self.problems('{"\\u0661.\\u0660": "Arrakis"}')), 1)  # ASCII digits only

    def test_a_version_once(self):
        codenames = changelog.parse_codenames('{"1.1": "Shishakli", "1.1": "Stilgar"}')
        self.assertEqual(codenames.problems, ['"1.1" is a key twice: each X.Y has one codename'])
        self.assertEqual(codenames.names, {(1, 1): "Shishakli"})

    def test_a_codename_is_plain(self):
        cases = [(text, text) for text in ('""', '" Harah"', '"Harah "', '"Ha  rah"', '"-Harah"', '"Harah-"')]
        cases += [(text, text) for text in ('"Ha--rah"', '"Harah!"', '"Say \\"hi\\""', '"H\\u00e4rah"')]
        cases += [('"Ha\\nrah"', '"Ha\\nrah"'), ('"Ha\\trah"', '"Ha\\trah"'), ("42", "42"), ("null", "null")]
        cases += [("true", "true"), ('["Harah"]', "an array"), ('{"name": "Harah"}', "an object")]
        for value, shown in cases:
            with self.subTest(value=value):
                self.assertEqual(
                    self.problems('{"1.1": %s}' % value),
                    ['"1.1": a codename is %s, not %s' % (changelog.CODENAME_SHAPE, shown)],
                )

    def test_refuses_what_is_not_one_json_object(self):
        for text, fragment in (
            ("", ".github/codenames.json is not JSON: Expecting value: line 1 column 1"),
            ('{"1.0": "Arrakis",}', ".github/codenames.json is not JSON: "),
            ('{"1.0": "Arrakis"} {}', "is not JSON: Extra data"),
            ("﻿{}", "is not JSON: Unexpected UTF-8 BOM"),
            (
                '["Arrakis"]',
                '.github/codenames.json holds one JSON object that names each version X.Y, such as {"1.0": "Name"}, '
                "not an array",
            ),
            ('"Arrakis"', 'X.Y, such as {"1.0": "Name"}, not "Arrakis"'),
            ("null", "not null"),
        ):
            with self.subTest(text=text):
                with self.assertRaises(changelog.ChangelogError) as raised:
                    changelog.parse_codenames(text)
                self.assertIn(fragment, str(raised.exception))

    def test_the_repository_file(self):
        self.assertEqual(changelog.CODENAMES_FILE, os.path.join(os.path.dirname(TOOLS), ".github", "codenames.json"))
        if not os.path.isfile(changelog.CODENAMES_FILE):
            self.skipTest(".github/codenames.json is not in this checkout")
        # It starts empty and gains each X.Y's name once the owner has approved it; whatever it
        # names, it passes the file's rules.
        self.assertEqual(changelog.read_codenames(changelog.CODENAMES_FILE).problems, [])


# ---------------------------------------------------------------------------
# The command line
# ---------------------------------------------------------------------------


class CliCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.file = os.path.join(self.tmp.name, "CHANGELOG.md")
        self.template = os.path.join(self.tmp.name, "release-notes.md")
        self.codenames = os.path.join(self.tmp.name, "codenames.json")
        self.write(SAMPLE)
        self.write_codenames(CODENAMES)
        self.write_template(TEMPLATE)

    def write(self, text):
        with open(self.file, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)

    def write_codenames(self, text):
        with open(self.codenames, "w", encoding="utf-8") as handle:
            handle.write(text)

    def write_template(self, text):
        with open(self.template, "w", encoding="utf-8") as handle:
            handle.write(text)

    def read(self):
        with open(self.file, encoding="utf-8", newline="") as handle:
            return handle.read()

    def run_main(self, command, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = changelog.main([command, "--file", self.file, "--codenames", self.codenames, *argv])
        return code, out.getvalue(), err.getvalue()

    def usage_error(self, command, *argv):
        """The exit code and stderr of a run that argparse ends."""
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as raised:
                changelog.main([command, "--file", self.file, "--codenames", self.codenames, *argv])
        return raised.exception.code, err.getvalue()

    def html(self, *argv):
        code, out, err = self.run_main("html", *argv)
        self.assertEqual(code, 0, err)
        return out

    def notes(self, *argv):
        return self.run_main("notes", "--template", self.template, *argv)

    def repository_template(self, path):
        """A notes template of the repository (another file of the checkout), or the test is skipped."""
        if not os.path.isfile(path):
            self.skipTest("%s is not in this checkout" % changelog.display_path(path))
        return path


class CheckCommandTest(CliCase):
    def test_ok(self):
        self.assertEqual(self.run_main("check"), (0, "%s: ok (3 releases)\n" % self.file, ""))
        self.write(
            text_of("# Changelog", "## Unreleased", '## 1.0 "Arrakis", build 7 (2026-10-01)', "### Added", "- One.")
        )
        self.assertEqual(self.run_main("check")[1], "%s: ok (1 release)\n" % self.file)

    def test_every_problem_with_its_line_number(self):
        self.write(SAMPLE.replace("### Changed", "### Removed").replace("(2026-11-20)", "(2026-12-20)"))
        code, out, err = self.run_main("check")
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        lines = err.splitlines()
        self.assertEqual(len(lines), 3, err)
        self.assertTrue(lines[0].startswith("%s:21: unknown category 'Removed'" % self.file), lines[0])
        self.assertTrue(lines[1].startswith("%s:27: 2026-12-20 is below 2026-12-01 on line 19" % self.file), lines[1])
        self.assertEqual(lines[2], "%s: 2 problems" % self.file)

    def test_missing_file(self):
        os.unlink(self.file)
        code, out, err = self.run_main("check")
        self.assertEqual(code, 1)
        self.assertIn("error: cannot read %s" % self.file, err)

    def test_every_release_against_the_codenames_file(self):
        self.write_codenames(json.dumps({"1.0": "Arrakis", "1.1": "Shishakli", "1.2": "shishakli"}))
        self.write(SAMPLE.replace('## 1.0 "Arrakis", build 48', '## 1.0 "Stilgar", build 48'))
        code, out, err = self.run_main("check")
        self.assertEqual((code, out), (1, ""))
        self.assertEqual(
            err.splitlines(),
            [
                '%s:19: 1.0 is named "Arrakis" in %s, not "Stilgar"' % (self.file, self.codenames),
                "%s:27: 0.9 %s" % (self.file, MISSING % self.codenames),
                '%s: "1.2": "shishakli" names 1.1 already (as "Shishakli"): each X.Y has its own codename'
                % self.codenames,
                "%s: 2 problems" % self.file,
                "%s: 1 problem" % self.codenames,
            ],
        )

    def test_a_codenames_file_that_fails_alone(self):
        self.write_codenames(json.dumps({**CODENAME_OF, "1.1": "Jamis"}))
        self.assertEqual(
            self.run_main("check"),
            (
                1,
                "",
                '%s: "1.1": "Jamis" names 0.9 already: each X.Y has its own codename\n%s: 1 problem\n'
                % (self.codenames, self.codenames),
            ),
        )

    def test_a_codenames_file_that_cannot_be_read(self):
        self.write_codenames('{"1.0": "Arrakis",}')
        code, out, err = self.run_main("check")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("error: %s is not JSON: " % self.codenames, err)
        os.unlink(self.codenames)
        code, out, err = self.run_main("check")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("error: cannot read %s" % self.codenames, err)


class StartStateTest(CliCase):
    """The project as it starts: .github/codenames.json is {}, and CHANGELOG.md lists no release
    under an empty Unreleased entry (docs/changelog-design.md)."""

    START = text_of(
        "# Changelog",
        "",
        "Every published release of the driver, newest first.",
        "",
        "## Unreleased",
    )

    def setUp(self):
        super().setUp()
        self.write(self.START)
        self.write_codenames("{}\n")

    def test_check_passes(self):
        self.assertEqual(self.run_main("check"), (0, "%s: ok (0 releases)\n" % self.file, ""))

    def test_the_documentation_tab_says_no_release_yet(self):
        for argv in ((), ("--dev-build", "5"), ("--release", "1.0", "--build", "5", "--date", "2026-11-30")):
            with self.subTest(argv=argv):
                out = self.html(*argv)
                self.assertIn("<p>No release yet.</p>", out)
                self.assertNotIn("Unreleased", out)
                self.assertEqual(out.count("<h3>"), 0)

    def test_a_release_or_prerelease_without_a_codename_is_refused(self):
        self.write(self.START + "\n### Added\n- The fan driver (#3).\n")
        before = self.read()
        message = "error: 1.0 %s\n" % (MISSING % self.codenames)
        for command, argv in (
            ("html", ("--release", "1.0", "--build", "12", "--date", "2026-11-30")),
            ("html", ("--release", "1.0-beta.1", "--build", "12", "--date", "2026-11-30")),
            ("notes", ("--template", self.template, "--version", "1.0", "--build", "12", "--date", "2026-11-30")),
            ("notes", ("--template", self.template) + FIRST_PRERELEASE),
            ("stamp", ("--version", "1.0", "--build", "12", "--date", "2026-11-30")),
            ("stamp", ("--version", "1.0", "--build", "12", "--date", "2026-11-30", "--codename", "Arrakis")),
        ):
            with self.subTest(command=command, argv=argv):
                self.assertEqual(self.run_main(command, *argv), (1, "", message))
                self.assertEqual(self.read(), before)

    def test_the_first_release_once_named(self):
        self.write(self.START + "\n### Added\n- The fan driver (#3).\n")
        self.write_codenames('{"1.0": "Arrakis"}\n')
        code, out, err = self.run_main("stamp", "--version", "1.0", "--build", "12", "--date", "2026-11-30")
        self.assertEqual(code, 0, err)
        self.assertIn('\n## Unreleased\n\n## 1.0 "Arrakis", build 12 (2026-11-30)\n', self.read())
        self.assertEqual(self.run_main("check"), (0, "%s: ok (1 release)\n" % self.file, ""))


class HtmlTest(CliCase):
    SMALL = text_of(
        "# Changelog",
        "",
        "Intro.",
        "",
        "## Unreleased",
        "",
        "### Fixed",
        "- A fix with `code` (#2).",
        "",
        '## 1.0 "Arrakis", build 61 (2026-12-02)',
        "",
        "### Added",
        "- **New** things; see [the manual](https://example.com/m) (#1).",
        "### Known limits",
        "- One limit.",
    )

    def test_fragment(self):
        self.write(self.SMALL)
        self.assertEqual(
            self.html(),
            '<h2 id="changelog">Changelog</h2>\n'
            "<p>%s</p>\n"
            "<h3>Unreleased</h3>\n"
            "<p><b>Fixed</b></p>\n"
            "<ul>\n"
            "<li>A fix with <code>code</code> (#2).</li>\n"
            "</ul>\n"
            "<h3>1.0 &quot;Arrakis&quot;, build 61 (2026-12-02)</h3>\n"
            "<p><b>Added</b></p>\n"
            "<ul>\n"
            "<li><b>New</b> things; see the manual (#1).</li>\n"
            "</ul>\n"
            "<p><b>Known limits</b></p>\n"
            "<ul>\n"
            "<li>One limit.</li>\n"
            "</ul>\n" % changelog.INTRO,
        )
        self.assertIn("Modern Forms Fan driver", changelog.INTRO)

    def test_escaping_of_lt_amp_and_quotes_in_bullets(self):
        self.write(SAMPLE.replace("- The first build.", "- Levels <5 & >2 stay \"as typed\" and 'quoted' (#7)."))
        self.assertIn(
            "<li>Levels &lt;5 &amp; &gt;2 stay &quot;as typed&quot; and &#39;quoted&#39; (#7).</li>", self.html()
        )

    def test_inline_markup(self):
        self.write(
            SAMPLE.replace(
                "- The first build.",
                "- `<!-- CHANGELOG -->` and `a & b`, **bold `code`**, [the text](https://example.com/x) "
                "and \\*escaped\\* stay; #123 is text; café … ▸.",
            )
        )
        self.assertIn(
            "<li><code>&lt;!-- CHANGELOG --&gt;</code> and <code>a &amp; b</code>, <b>bold <code>code</code></b>, "
            "the text and *escaped* stay; #123 is text; caf&#233; &#8230; &#9656;.</li>",
            self.html(),
        )

    def test_unreleased_as_it_stands(self):
        out = self.html()
        self.assertIn("<h3>Unreleased</h3>\n<p><b>Fixed</b></p>", out)
        self.assertLess(out.index("<h3>Unreleased</h3>"), out.index("build 61"))

    def test_unreleased_as_a_development_build(self):
        out = self.html("--dev-build", "65")
        self.assertIn("<h3>Unreleased (development build 65)</h3>\n<p><b>Fixed</b></p>", out)
        self.assertEqual(out.count("<h3>"), 4)

    def test_unreleased_as_the_release(self):
        out = self.html(*HTML_RELEASE)
        self.assertIn("<h3>1.0 &quot;Arrakis&quot;, build 70 (2026-12-09)</h3>\n<p><b>Fixed</b></p>", out)
        self.assertNotIn("Unreleased", out)
        self.assertEqual(out.count("<h3>"), 4)

    def test_unreleased_as_a_prerelease(self):
        out = self.html(*HTML_PRERELEASE)
        self.assertIn(PRERELEASE_H3 + "\n<p><b>Fixed</b></p>", out)
        self.assertNotIn("Unreleased", out)
        self.assertNotRegex(out, r"<h3>1\.1 &quot;Shishakli&quot;")  # never as the release 1.1
        self.assertEqual(out.count("<h3>"), 4)
        self.assertLess(out.index(PRERELEASE_H3), out.index("build 61"))
        # Every beta of 1.1 takes the codename the codenames file gives 1.1, not 1.0's.
        beta_4 = "<h3>1.1 beta 4 &quot;Shishakli&quot; (prerelease), build 80 (2026-12-10)</h3>"
        for extra in ((), ("--codename", "Shishakli")):
            with self.subTest(extra=extra):
                out = self.html("--release", "1.1-beta.4", "--build", "80", "--date", "2026-12-10", *extra)
                self.assertIn(beta_4 + "\n<p><b>Fixed</b></p>", out)
                self.assertNotIn("beta 4 &quot;Arrakis&quot;", out)
        self.write_codenames(json.dumps({**CODENAME_OF, "2.0": "Gurney Halleck"}))
        out = self.html("--release", "2.0-beta.3", "--build", "70", "--date", "2026-12-09")
        self.assertIn("<h3>2.0 beta 3 &quot;Gurney Halleck&quot; (prerelease), build 70 (2026-12-09)</h3>", out)

    def test_prerelease_refusals(self):
        for argv, fragment in (
            (
                ("--release", "1.0-beta.1", "--build", "70", "--date", "2026-12-09"),
                "1.0-beta.1 is a prerelease of 1.0, but CHANGELOG.md lists 1.0 already (line 12): a prerelease comes "
                "before its version's release, so name a later version, such as 1.1-beta.1",
            ),
            (("--release", "0.9-beta.2", "--build", "70", "--date", "2026-12-09"), "lists 1.0 already (line 12)"),
            (("--release", "1.1-beta.1", "--build", "61", "--date", "2026-12-09"), "build 61 has an entry already"),
            (("--release", "1.1-beta.1", "--build", "50", "--date", "2026-12-09"), "build 50 is older than build 61"),
            (("--release", "1.1-beta.1", "--build", "70", "--date", "2026-11-30"), "2026-11-30 is before 2026-12-02"),
            (
                ("--release", "2.0-beta.1", "--build", "70", "--date", "2026-12-09"),
                "2.0 " + MISSING % self.codenames,
            ),
            (
                HTML_PRERELEASE + ("--codename", "Stilgar"),
                '1.1 is named "Shishakli" in %s, not "Stilgar"' % self.codenames,
            ),
            (
                HTML_PRERELEASE + ("--codename", "Arrakis"),
                '1.1 is named "Shishakli" in %s, not "Arrakis"' % self.codenames,
            ),
        ):
            with self.subTest(argv=argv):
                code, out, err = self.run_main("html", *argv)
                self.assertEqual((code, out), (1, ""))
                self.assertIn(fragment, err)

    def test_empty_unreleased_never_shows(self):
        self.write(EMPTY_UNRELEASED)
        for argv in ((), ("--dev-build", "65"), HTML_RELEASE, HTML_PRERELEASE):
            with self.subTest(argv=argv):
                out = self.html(*argv)
                self.assertNotIn("Unreleased", out)
                self.assertNotIn("build 70", out)
                self.assertEqual(out.count("<h3>"), 3)
        self.write(text_of("# Changelog", "## Unreleased"))
        self.assertIn("<p>No release yet.</p>", self.html())

    def test_release_codename_comes_from_the_codenames_file(self):
        out = self.html("--release", "1.1", "--build", "70", "--date", "2026-12-09")
        self.assertIn("<h3>1.1 &quot;Shishakli&quot;, build 70 (2026-12-09)</h3>", out)
        self.assertIn(
            "<h3>1.0 &quot;Arrakis&quot;, build 70 (2026-12-09)</h3>",
            self.html(*HTML_RELEASE, "--codename", "Arrakis"),
        )
        # A version the file does not name is refused, --codename or not: the file is the one source.
        for extra in ((), ("--codename", "Gurney Halleck")):
            with self.subTest(extra=extra):
                code, out, err = self.run_main(
                    "html", "--release", "2.0", "--build", "70", "--date", "2026-12-09", *extra
                )
                self.assertEqual((code, out, err), (1, "", "error: 2.0 %s\n" % (MISSING % self.codenames)))
        self.write_codenames(json.dumps({**CODENAME_OF, "2.0": "Gurney Halleck"}))
        out = self.html("--release", "2.0", "--build", "70", "--date", "2026-12-09")
        self.assertIn("<h3>2.0 &quot;Gurney Halleck&quot;, build 70 (2026-12-09)</h3>", out)

    def test_the_default_codenames_file_is_the_repository_one(self):
        if not os.path.isfile(changelog.CODENAMES_FILE):
            self.skipTest(".github/codenames.json is not in this checkout")
        names = changelog.read_codenames(changelog.CODENAMES_FILE).names
        self.write(text_of("# Changelog", "", "## Unreleased", "", "### Fixed", "- A fix (#1)."))
        # A version the repository file does not name (it starts empty), and every one it names.
        unnamed = "%d.0" % (max([major for major, _minor in names] + [0]) + 1)
        cases = [(unnamed, None)] + [("%d.%d" % version, name) for version, name in sorted(names.items())]
        for version, name in cases:
            with self.subTest(version=version):
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    code = changelog.main(
                        ["html", "--file", self.file, "--release", version, "--build", "70", "--date", "2026-12-09"]
                    )
                if name is None:
                    self.assertEqual((code, out.getvalue()), (1, ""))
                    self.assertEqual(err.getvalue(), "error: %s %s\n" % (version, MISSING % ".github/codenames.json"))
                else:
                    self.assertEqual(code, 0, err.getvalue())
                    self.assertIn("<h3>%s &quot;%s&quot;, build 70 (2026-12-09)</h3>" % (version, name), out.getvalue())

    def test_release_refusals(self):
        for argv, fragment in (
            (
                ("--release", "1.0", "--build", "61", "--date", "2026-12-09"),
                "build 61 has an entry already, on line 12",
            ),
            (("--release", "1.0", "--build", "50", "--date", "2026-12-09"), "build 50 is older than build 61"),
            (("--release", "1.0", "--build", "70", "--date", "2026-11-30"), "2026-11-30 is before 2026-12-02"),
            (HTML_RELEASE + ("--codename", "Stilgar"), '1.0 is named "Arrakis" in %s, not "Stilgar"' % self.codenames),
            (
                HTML_RELEASE + ("--codename", "Shishakli"),
                '1.0 is named "Arrakis" in %s, not "Shishakli"' % self.codenames,
            ),
        ):
            with self.subTest(argv=argv):
                code, out, err = self.run_main("html", *argv)
                self.assertEqual((code, out), (1, ""))
                self.assertIn(fragment, err)

    def test_composer_safe(self):
        self.write(SAMPLE.replace("- The first build.", "- `<script>alert(1)</script>` and `<img src=x>` stay text."))
        for argv in ((), ("--dev-build", "65"), HTML_RELEASE, HTML_PRERELEASE):
            with self.subTest(argv=argv):
                out = self.html(*argv)
                collector = TagCollector()
                collector.feed(out)
                collector.close()
                self.assertEqual(collector.other, [])
                self.assertTrue(collector.tags)
                for tag, attrs in collector.tags:
                    self.assertIn(tag, {"h2", "h3", "p", "b", "ul", "li", "code"})
                    self.assertEqual(attrs, [("id", "changelog")] if tag == "h2" else [])
                self.assertEqual([tag for tag, _ in collector.tags].count("h2"), 1)
                self.assertTrue(out.isascii())
                self.assertNotIn("example.com", out)
                self.assertNotIn("<script", out)
                self.assertIn("&lt;script&gt;", out)

    def test_refuses_a_file_that_fails_check(self):
        self.write(SAMPLE.replace("### Changed", "### Removed"))
        code, out, err = self.run_main("html")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("%s:21: unknown category 'Removed'" % self.file, err)
        self.assertIn("error: %s fails check: nothing done" % self.file, err)

    def test_refuses_a_codenames_file_that_fails_check(self):
        self.write_codenames(json.dumps({**CODENAME_OF, "1.2": "Shishakli"}))
        for argv in ((), ("--dev-build", "65"), HTML_RELEASE, HTML_PRERELEASE):
            with self.subTest(argv=argv):
                code, out, err = self.run_main("html", *argv)
                self.assertEqual((code, out), (1, ""))
                self.assertEqual(
                    err.splitlines(),
                    [
                        '%s: "1.2": "Shishakli" names 1.1 already: each X.Y has its own codename' % self.codenames,
                        "error: %s fails check: nothing done" % self.codenames,
                    ],
                )
        self.write(SAMPLE.replace('"Arrakis", build 48', '"Stilgar", build 48'))
        code, out, err = self.run_main("html")
        self.assertEqual((code, out), (1, ""))
        self.assertIn('%s:19: 1.0 is named "Arrakis" in %s, not "Stilgar"' % (self.file, self.codenames), err)
        self.assertIn("error: %s and %s fail check: nothing done" % (self.file, self.codenames), err)

    def test_usage_errors(self):
        for argv in (
            ("--release", "1.0"),
            ("--build", "70", "--date", "2026-12-09"),
            HTML_RELEASE + ("--dev-build", "71"),
            ("--codename", "Arrakis"),
            ("--dev-build", "0"),
            ("--release", "1.0.1", "--build", "70", "--date", "2026-12-09"),
            ("--release", "1.1-beta.0", "--build", "70", "--date", "2026-12-09"),
            ("--release", "1.1-rc.1", "--build", "70", "--date", "2026-12-09"),
            ("--release", "v1.1-beta.1", "--build", "70", "--date", "2026-12-09"),
            HTML_PRERELEASE + ("--codename", "Shishakli!"),
        ):
            with self.subTest(argv=argv):
                self.assertEqual(self.usage_error("html", *argv)[0], 2)


class NotesTest(CliCase):
    def test_notes_from_the_template(self):
        code, out, err = self.notes(*RELEASE)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out,
            '## 1.0 "Arrakis" (build 70)\n'
            "\n"
            'Released 2026-12-09. Braces that name no placeholder stay: {"key": 1}, ${{ github.sha }}, {Version}.\n'
            "\n"
            "### New in build 70\n"
            "\n"
            "**Fixed**\n"
            "\n"
            "- The light slider no longer jumps back after a dim (#31).\n"
            "- Keypad LEDs follow a speed set in the Modern Forms app,\n"
            "  also after the fan loses power (#32).\n"
            "\n"
            "### Earlier builds of 1.0\n"
            "\n"
            '### 1.0 "Arrakis", build 61 (2026-12-02)\n'
            "\n"
            "**Added**\n"
            "\n"
            "- A `Status` property in Composer (#20).\n"
            "\n"
            "**Fixed**\n"
            "\n"
            "- **Speed links** survive a power cut; see [the manual](https://example.com/manual#links) (#18).\n"
            "\n"
            '### 1.0 "Arrakis", build 48 (2026-12-01)\n'
            "\n"
            "**Changed**\n"
            "\n"
            "- The fan is followed through a change of its IP address.\n"
            "\n"
            "**Known limits**\n"
            "\n"
            "- No sleep timer yet.\n"
            "\n"
            "Every release: CHANGELOG.md.\n",
        )

    def test_refuses_an_empty_unreleased_entry(self):
        self.write(EMPTY_UNRELEASED)
        code, out, err = self.notes(*RELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("'## Unreleased' (line 5) has no bullets: a release must say what it changes", err)

    def test_first_build_of_a_new_version(self):
        code, out, err = self.notes("--version", "1.1", "--build", "70", "--date", "2026-12-09")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('## 1.1 "Shishakli" (build 70)\n'), out)
        self.assertIn("### Earlier builds of 1.1\n\nNone: build 70 is the first build of 1.1.\n", out)
        argv = ("--version", "2.0", "--build", "70", "--date", "2026-12-09")
        for extra in ((), ("--codename", "Gurney Halleck")):
            with self.subTest(extra=extra):
                code, out, err = self.notes(*argv, *extra)
                self.assertEqual((code, out), (1, ""))
                self.assertIn("error: 2.0 has no codename in %s" % self.codenames, err)
        self.write_codenames(json.dumps({**CODENAME_OF, "2.0": "Gurney Halleck"}))
        code, out, err = self.notes(*argv)
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('## 2.0 "Gurney Halleck" (build 70)\n'), out)

    def test_codename_option_must_agree_with_the_codenames_file(self):
        for argv, version, name in (
            (RELEASE, "1.0", "Shishakli"),
            (RELEASE, "1.0", "Stilgar"),
            (PRERELEASE, "1.1", "Arrakis"),
            (PRERELEASE, "1.1", "Stilgar"),
        ):
            with self.subTest(argv=argv, name=name):
                self.write_template(TEMPLATE if argv is RELEASE else PRERELEASE_TEMPLATE)
                code, out, err = self.notes(*argv, "--codename", name)
                self.assertEqual((code, out), (1, ""))
                named = CODENAME_OF[version]
                self.assertIn('error: %s is named "%s" in %s, not "%s"' % (version, named, self.codenames, name), err)

    def test_values_are_not_filled_in_again(self):
        self.write(SAMPLE.replace("after a dim (#31).", "after a dim; the notes name `{build}` (#31)."))
        code, out, err = self.notes(*RELEASE)
        self.assertEqual(code, 0, err)
        self.assertIn("the notes name `{build}` (#31).", out)

    def test_template_refusals(self):
        for template, fragment in (
            (TEMPLATE + "{tag}\n", "names {tag}; the placeholders are {version}, {codename}"),
            (TEMPLATE.replace("{this_build}", "nothing"), "has no {this_build}"),
            (TEMPLATE + "<!-- if stable -->\n", "<!-- if stable --> is never ended by <!-- end if -->"),
        ):
            with self.subTest(fragment=fragment):
                self.write_template(template)
                code, out, err = self.notes(*RELEASE)
                self.assertEqual((code, out), (1, ""))
                self.assertIn(fragment, err)
        os.unlink(self.template)
        code, out, err = self.notes(*RELEASE)
        self.assertEqual(code, 1)
        self.assertIn("cannot read", err)

    def test_prerelease_notes_from_the_template(self):
        self.write_template(PRERELEASE_TEMPLATE)
        code, out, err = self.notes(*PRERELEASE)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out,
            '## 1.1 beta 1 "Shishakli" (build 70)\n'
            "\n"
            'Version 1.1-beta.1, built 2026-12-09, follows [1.0 "Arrakis", build 61 (2026-12-02)]'
            "(https://example.com/v1.0).\n"
            "\n"
            "**Fixed**\n"
            "\n"
            "- The light slider no longer jumps back after a dim (#31).\n"
            "- Keypad LEDs follow a speed set in the Modern Forms app,\n"
            "  also after the fan loses power (#32).\n",
        )

    def test_each_kind_has_its_default_template(self):
        prerelease_template = os.path.join(self.tmp.name, "prerelease-notes.md")
        with open(prerelease_template, "w", encoding="utf-8") as handle:
            handle.write(PRERELEASE_TEMPLATE)
        for name, path in (("TEMPLATE_FILE", self.template), ("PRERELEASE_TEMPLATE_FILE", prerelease_template)):
            self.addCleanup(setattr, changelog, name, getattr(changelog, name))
            setattr(changelog, name, path)
        code, out, err = self.run_main("notes", *PRERELEASE)
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('## 1.1 beta 1 "Shishakli" (build 70)\n'), out)
        code, out, err = self.run_main("notes", *RELEASE)
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('## 1.0 "Arrakis" (build 70)\n'), out)

    def test_prerelease_refusals(self):
        self.write_template(PRERELEASE_TEMPLATE + "{history}\n")
        code, out, err = self.notes(*PRERELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn(
            "names {history}; the placeholders are {version}, {release}, {beta}, {codename}, {build}, {date}, "
            "{this_build}, {stable}, {stable_version}",
            err,
        )
        self.write_template(PRERELEASE_TEMPLATE)
        code, out, err = self.notes("--version", "1.0-beta.2", "--build", "70", "--date", "2026-12-09")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("CHANGELOG.md lists 1.0 already (line 12)", err)
        code, out, err = self.notes("--version", "2.0-beta.1", "--build", "70", "--date", "2026-12-09")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("error: 2.0 has no codename in %s" % self.codenames, err)
        self.write(EMPTY_UNRELEASED)
        code, out, err = self.notes(*PRERELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("'## Unreleased' (line 5) has no bullets: a prerelease must say what it changes", err)

    def test_the_repository_prerelease_template_fills(self):
        template = self.repository_template(changelog.PRERELEASE_TEMPLATE_FILE)
        code, out, err = self.run_main("notes", "--template", template, *PRERELEASE)
        self.assertEqual(code, 0, err)
        # The Release workflow takes the first line, whole, for the title.
        self.assertEqual(out.splitlines()[0], '## 1.1 beta 1 "Shishakli" (build 70)')
        self.assertIsNone(changelog.PLACEHOLDER_RE.search(out), "every placeholder is filled")
        self.assertNotIn("<!--", out)
        self.assertIn(
            "- Keypad LEDs follow a speed set in the Modern Forms app,\n  also after the fan loses power (#32).", out
        )
        self.assertIn('1.0 "Arrakis", build 61 (2026-12-02)', out)  # the release it follows
        self.assertNotIn("build 48", out)  # no history: prereleases are not in CHANGELOG.md
        for leftover in ("c4-hue-driver", "Andor"):
            self.assertNotIn(leftover, out)
        # docs/prerelease-design.md: install, then going back, then verify a download, then the license.
        marks = ['"Add or Update Driver or Agent…"', "Going back", "sha256sum -c SHA256SUMS.txt", "Apache License 2.0"]
        self.assertNotIn(-1, [out.find(mark) for mark in marks])
        self.assertEqual([out.find(mark) for mark in marks], sorted(out.find(mark) for mark in marks))

    def test_the_repository_prerelease_template_before_the_first_release(self):
        """A 1.0 beta while CHANGELOG.md lists no release: the template's <!-- if no stable --> lines,
        or, while it has none, a refusal that says so rather than notes that name no release."""
        template = self.repository_template(changelog.PRERELEASE_TEMPLATE_FILE)
        with open(template, encoding="utf-8") as handle:
            has_blocks = changelog.BLOCK_NO_STABLE in handle.read()
        self.write(FIRST)
        code, out, err = self.run_main("notes", "--template", template, *FIRST_PRERELEASE)
        if has_blocks:
            self.assertEqual(code, 0, err)
            self.assertEqual(out.splitlines()[0], '## 1.0 beta 1 "Arrakis" (build 12)')
            self.assertIsNone(changelog.PLACEHOLDER_RE.search(out), "every placeholder is filled")
            self.assertNotIn("<!--", out)
            self.assertNotIn("releases/tag/v)", out)
            self.assertIn("- The fan driver (#3).", out)
        else:
            self.assertEqual((code, out), (1, ""))
            self.assertIn("outside an <!-- if stable --> block", err)

    def test_every_beta_of_1_1_takes_its_name(self):
        template = self.repository_template(changelog.PRERELEASE_TEMPLATE_FILE)
        for beta in (1, 4, 12):
            with self.subTest(beta=beta):
                code, out, err = self.run_main(
                    "notes",
                    "--template",
                    template,
                    *("--version", "1.1-beta.%d" % beta, "--build", "80", "--date", "2026-12-10"),
                )
                self.assertEqual(code, 0, err)
                self.assertTrue(out.startswith('## 1.1 beta %d "Shishakli" (build 80)\n' % beta), out[:80])
                self.assertIn("Shishakli", out)

    def test_the_repository_templates_count_no_packages(self):
        for path in (changelog.TEMPLATE_FILE, changelog.PRERELEASE_TEMPLATE_FILE):
            with self.subTest(path=path):
                with open(self.repository_template(path), encoding="utf-8") as handle:
                    text = handle.read()
                self.assertIn("every `.c4z` file of", text)
                self.assertIsNone(re.search(r"\b[A-Za-z0-9_-]+\.c4z\b", text), "a template names no package file")

    def test_the_repository_template_fills(self):
        template = self.repository_template(changelog.TEMPLATE_FILE)
        code, out, err = self.run_main("notes", "--template", template, *RELEASE)
        self.assertEqual(code, 0, err)
        # The Release workflow's title is the first line without its "(build N)": 1.0 "Arrakis".
        self.assertEqual(out.splitlines()[0], '## 1.0 "Arrakis" (build 70)')
        self.assertIn(
            "- Keypad LEDs follow a speed set in the Modern Forms app,\n  also after the fan loses power (#32).", out
        )
        self.assertIn('### 1.0 "Arrakis", build 48 (2026-12-01)', out)
        self.assertNotIn("Jamis", out)
        self.assertIsNone(changelog.PLACEHOLDER_RE.search(out), "every placeholder is filled")
        self.assertNotIn("<!--", out)
        self.assertIn("CHANGELOG.md", out)
        for leftover in ("c4-hue-driver", "Andor"):
            self.assertNotIn(leftover, out)


class TemplateBlocksTest(unittest.TestCase):
    """The alternatives of a notes template (docs/changelog-design.md, section 4)."""

    TEXT = text_of(
        "a", "<!-- if stable -->", "b", "<!-- end if -->", "<!-- if no stable -->", "c", "<!-- end if -->", "d"
    )

    def test_each_side(self):
        self.assertEqual(changelog.select_blocks(self.TEXT, True, "t.md"), "a\nb\nd\n")
        self.assertEqual(changelog.select_blocks(self.TEXT, False, "t.md"), "a\nc\nd\n")

    def test_markers_with_spaces_around_them_and_crlf(self):
        text = self.TEXT.replace("<!-- if stable -->", "  <!-- if stable -->  ").replace("\n", "\r\n")
        self.assertEqual(changelog.select_blocks(text, True, "t.md"), "a\r\nb\r\nd\r\n")
        self.assertEqual(changelog.select_blocks(text, False, "t.md"), "a\r\nc\r\nd\r\n")

    def test_a_template_without_blocks_is_unchanged(self):
        for stable in (True, False):
            self.assertEqual(changelog.select_blocks(TEMPLATE, stable, "t.md"), TEMPLATE)

    def test_refusals(self):
        for rows, message in (
            (("a", "<!-- if stable -->", "b"), "t.md:2: <!-- if stable --> is never ended by <!-- end if -->"),
            (
                ("<!-- if stable -->", "<!-- if no stable -->", "<!-- end if -->"),
                "t.md:2: <!-- if no stable --> inside the block that line 1 opens: blocks do not nest",
            ),
            (("a", "<!-- end if -->"), "t.md:2: <!-- end if --> ends no block"),
        ):
            with self.subTest(rows=rows):
                with self.assertRaises(changelog.ChangelogError) as raised:
                    changelog.select_blocks(text_of(*rows), True, "t.md")
                self.assertEqual(str(raised.exception), message)


class FirstPrereleaseTest(CliCase):
    """A prerelease before the first release: 1.0-beta.1 while CHANGELOG.md lists no release, which
    the house and a tester try before 1.0 (docs/changelog-design.md, section 2)."""

    def setUp(self):
        super().setUp()
        self.write(FIRST)
        self.write_template(BLOCK_TEMPLATE)

    def test_notes_take_the_lines_for_no_stable_release(self):
        code, out, err = self.notes(*FIRST_PRERELEASE)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out,
            '## 1.0 beta 1 "Arrakis" (build 12)\n'
            "\n"
            "Version 1.0-beta.1, built 2026-11-30.\n"
            "\n"
            "No release precedes it.\n"
            "\n"
            "**Added**\n"
            "\n"
            "- The fan driver (#3).\n",
        )

    def test_once_a_release_exists_the_lines_for_it(self):
        self.write(SAMPLE)
        code, out, err = self.notes(*PRERELEASE)
        self.assertEqual(code, 0, err)
        self.assertIn('\n\nIt follows [1.0 "Arrakis", build 61 (2026-12-02)](https://example.com/v1.0).\n\n', out)
        self.assertNotIn("No release precedes it.", out)

    def test_a_template_that_names_the_stable_release_outside_a_block_is_refused(self):
        self.write_template(PRERELEASE_TEMPLATE)
        self.assertEqual(
            self.notes(*FIRST_PRERELEASE),
            (
                1,
                "",
                "error: %s names {stable}, {stable_version} outside an <!-- if stable --> block, but %s lists no "
                "release for it to name: a prerelease before the first release takes the lines of the "
                "<!-- if no stable --> blocks instead (docs/changelog-design.md)\n" % (self.template, self.file),
            ),
        )

    def test_the_documentation_tab_and_the_stamp(self):
        out = self.html("--release", "1.0-beta.1", "--build", "12", "--date", "2026-11-30")
        self.assertIn("<h3>1.0 beta 1 &quot;Arrakis&quot; (prerelease), build 12 (2026-11-30)</h3>", out)
        code, _out, err = self.run_main("stamp", *FIRST_PRERELEASE)
        self.assertEqual(code, 1)
        self.assertIn("1.0-beta.1 is a prerelease: CHANGELOG.md lists releases only", err)
        self.assertEqual(self.read(), FIRST)
        # Later betas too, and then the release itself.
        out = self.html("--release", "1.0-beta.2", "--build", "15", "--date", "2026-12-01")
        self.assertIn("<h3>1.0 beta 2 &quot;Arrakis&quot; (prerelease), build 15 (2026-12-01)</h3>", out)
        code, _out, err = self.run_main("stamp", "--version", "1.0", "--build", "20", "--date", "2026-12-02")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.run_main("check"), (0, "%s: ok (1 release)\n" % self.file, ""))

    def test_a_release_template_takes_the_blocks_too(self):
        self.write_template(
            TEMPLATE.replace(
                "Every release: CHANGELOG.md.\n",
                "<!-- if stable -->\nUpgrade from {version}.\n<!-- end if -->\n"
                "<!-- if no stable -->\nThe first release.\n<!-- end if -->\n",
            )
        )
        code, out, err = self.notes("--version", "1.0", "--build", "12", "--date", "2026-11-30")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.endswith("None: build 12 is the first build of 1.0.\n\nThe first release.\n"), out)
        self.write(SAMPLE)
        code, out, err = self.notes(*RELEASE)
        self.assertEqual(code, 0, err)
        self.assertTrue(out.endswith("\n\nUpgrade from 1.0.\n"), out)


class StampTest(CliCase):
    def test_round_trip(self):
        code, out, err = self.run_main("stamp", *RELEASE)
        self.assertEqual(code, 0, err)
        self.assertIn("'## Unreleased' is now '%s', below a new empty '## Unreleased'" % NEW_HEADING, out)
        stamped = self.read()
        self.assertEqual(stamped, SAMPLE.replace("## Unreleased\n", "## Unreleased\n\n%s\n" % NEW_HEADING, 1))
        self.assertEqual(self.run_main("check"), (0, "%s: ok (4 releases)\n" % self.file, ""))
        parsed = changelog.parse(stamped)
        self.assertEqual(parsed.unreleased.sections, [])
        self.assertEqual((parsed.releases[0].line, parsed.releases[0].build), (7, 70))
        out = self.html()
        self.assertNotIn("Unreleased", out)
        self.assertIn("<h3>1.0 &quot;Arrakis&quot;, build 70 (2026-12-09)</h3>\n<p><b>Fixed</b></p>", out)
        # The release's notes and Documentation tab, rendered before the stamp, describe the same entry.
        self.write(SAMPLE)
        self.assertIn("<h3>1.0 &quot;Arrakis&quot;, build 70 (2026-12-09)</h3>", self.html(*HTML_RELEASE))

    def test_refuses_an_empty_unreleased_entry(self):
        self.assertEqual(self.run_main("stamp", *RELEASE)[0], 0)
        stamped = self.read()
        code, out, err = self.run_main("stamp", "--version", "1.0", "--build", "71", "--date", "2026-12-09")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("'## Unreleased' (line 5) has no bullets: nothing to stamp", err)
        self.assertEqual(self.read(), stamped)

    def test_refuses_a_prerelease(self):
        code, out, err = self.run_main("stamp", *PRERELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn(
            "1.1-beta.1 is a prerelease: CHANGELOG.md lists releases only, and the 1.1 entry will carry these "
            "changes (docs/prerelease-design.md); nothing stamped",
            err,
        )
        self.assertEqual(self.read(), SAMPLE)

    def test_refuses_a_build_that_has_an_entry(self):
        code, out, err = self.run_main("stamp", "--version", "1.0", "--build", "61", "--date", "2026-12-09")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("build 61 has an entry already, on line 12", err)
        self.assertEqual(self.read(), SAMPLE)

    def test_refuses_an_older_build_or_date(self):
        for argv, fragment in (
            (("--version", "1.0", "--build", "50", "--date", "2026-12-09"), "build 50 is older than build 61"),
            (("--version", "1.0", "--build", "70", "--date", "2026-12-01"), "2026-12-01 is before 2026-12-02"),
        ):
            with self.subTest(argv=argv):
                code, _out, err = self.run_main("stamp", *argv)
                self.assertEqual(code, 1)
                self.assertIn(fragment, err)
                self.assertEqual(self.read(), SAMPLE)

    def test_codename_of_a_new_version(self):
        argv = ("--version", "2.0", "--build", "70", "--date", "2026-12-09")
        for extra in ((), ("--codename", "Gurney Halleck")):
            with self.subTest(extra=extra):
                code, _out, err = self.run_main("stamp", *argv, *extra)
                self.assertEqual(code, 1)
                self.assertIn("2.0 " + MISSING % self.codenames, err)
                self.assertEqual(self.read(), SAMPLE)
        # 1.1 takes the name the codenames file gives it, not 1.0's.
        code, _out, err = self.run_main("stamp", "--version", "1.1", "--build", "70", "--date", "2026-12-09")
        self.assertEqual(code, 0, err)
        self.assertIn('\n## 1.1 "Shishakli", build 70 (2026-12-09)\n', self.read())
        self.assertEqual(self.run_main("check")[0], 0)
        # Every build of 1.1 keeps it: another name is refused.
        self.write(self.read().replace("## Unreleased\n", "## Unreleased\n\n### Fixed\n- Another fix.\n", 1))
        unstamped = self.read()
        later = ("--version", "1.1", "--build", "75", "--date", "2026-12-10")
        for name in ("Stilgar", "Arrakis"):
            with self.subTest(name=name):
                code, _out, err = self.run_main("stamp", *later, "--codename", name)
                self.assertEqual(code, 1)
                self.assertIn('1.1 is named "Shishakli" in %s, not "%s"' % (self.codenames, name), err)
                self.assertEqual(self.read(), unstamped)
        code, _out, err = self.run_main("stamp", *later, "--codename", "Shishakli")
        self.assertEqual(code, 0, err)
        self.assertIn('\n## 1.1 "Shishakli", build 75 (2026-12-10)\n', self.read())
        # 2.0 once the file names it, with a space in the name.
        self.write(self.read().replace("## Unreleased\n", "## Unreleased\n\n### Fixed\n- A third fix.\n", 1))
        self.write_codenames(json.dumps({**CODENAME_OF, "2.0": "Gurney Halleck"}))
        code, _out, err = self.run_main("stamp", "--version", "2.0", "--build", "80", "--date", "2026-12-11")
        self.assertEqual(code, 0, err)
        self.assertIn('\n## 2.0 "Gurney Halleck", build 80 (2026-12-11)\n', self.read())
        self.assertEqual(self.run_main("check"), (0, "%s: ok (6 releases)\n" % self.file, ""))

    def test_keeps_crlf_line_endings(self):
        self.write(SAMPLE.replace("\n", "\r\n"))
        self.assertEqual(self.run_main("stamp", *RELEASE)[0], 0)
        expected = SAMPLE.replace("## Unreleased\n", "## Unreleased\n\n%s\n" % NEW_HEADING, 1)
        self.assertEqual(self.read(), expected.replace("\n", "\r\n"))

    def test_writes_only_a_result_that_passes_check(self):
        saved = changelog.release_title
        changelog.release_title = lambda *args: ("Arrakis", "1.0 Arrakis build 70")
        self.addCleanup(setattr, changelog, "release_title", saved)
        code, out, err = self.run_main("stamp", *RELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("a release heading reads", err)
        self.assertIn("stamped, the file would fail check", err)
        self.assertEqual(self.read(), SAMPLE)

    def test_refuses_a_file_that_fails_check(self):
        broken = SAMPLE.replace("### Changed", "### Removed")
        self.write(broken)
        code, _out, err = self.run_main("stamp", *RELEASE)
        self.assertEqual(code, 1)
        self.assertIn("fails check: nothing done", err)
        self.assertEqual(self.read(), broken)

    def test_refuses_a_codenames_file_that_fails_check(self):
        for text in (json.dumps({**CODENAME_OF, "1.2": "jamis"}), "[]"):
            with self.subTest(text=text):
                self.write_codenames(text)
                code, _out, err = self.run_main("stamp", *RELEASE)
                self.assertEqual(code, 1)
                self.assertIn("error: %s " % self.codenames, err)
                self.assertEqual(self.read(), SAMPLE)


class VersionTest(unittest.TestCase):
    """docs/prerelease-design.md: MAJOR.MINOR, or MAJOR.MINOR-beta.N for a prerelease, whole."""

    def test_accepted(self):
        for text, version in (
            ("1.0", changelog.Version(1, 0)),
            ("0.9", changelog.Version(0, 9)),
            ("12.34", changelog.Version(12, 34)),
            ("1.0-beta.1", changelog.Version(1, 0, 1)),
            ("1.1-beta.10", changelog.Version(1, 1, 10)),
            ("2.0-beta.123", changelog.Version(2, 0, 123)),
        ):
            with self.subTest(text=text):
                self.assertEqual(changelog.version_arg(text), version)
                self.assertEqual(str(version), text)
                self.assertEqual(version.release, (version.major, version.minor))

    def test_refused(self):
        for text in (
            "1",
            "1.0.1",
            "v1.0",
            "1.1-beta",
            "1.1-beta.",
            "1.1-beta.0",
            "1.1-beta.01",
            "1.1-Beta.1",
            "1.1-rc.1",
            "1.1-alpha.1",
            "1.1-beta.1.1",
            "1.1beta1",
            "1.1-beta-1",
            "1.0+5",
            " 1.0",
            "1.0 ",
            "1.0\n",
            "1.1-beta.1\n",
            "",
            "١.٠",
        ):
            with self.subTest(text=text):
                with self.assertRaises(argparse.ArgumentTypeError):
                    changelog.version_arg(text)


class CommandLineTest(CliCase):
    def test_help_of_the_tool_and_of_every_subcommand(self):
        env = dict(os.environ, NO_COLOR="1")
        env.pop("FORCE_COLOR", None)
        for argv in ([], ["check"], ["html"], ["notes"], ["stamp"]):
            with self.subTest(argv=argv):
                done = subprocess.run(
                    [sys.executable, "-I", SCRIPT, *argv, "--help"],
                    capture_output=True,
                    text=True,
                    env=env,
                    check=False,
                )
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertIn("changelog.py", done.stdout)
                self.assertIn("--file" if argv else "Exit codes: 0 done, 1 refused or invalid, 2 usage.", done.stdout)
                if argv:
                    self.assertIn("--codenames", done.stdout)

    def test_usage_errors_exit_2_and_change_nothing(self):
        for command, *argv in (
            ("bogus",),
            ("notes", "--build", "70", "--date", "2026-12-09"),
            ("notes", "--version", "1", "--build", "70", "--date", "2026-12-09"),
            ("stamp", "--version", "1.0", "--build", "x", "--date", "2026-12-09"),
            ("stamp", "--version", "1.0", "--build", "0", "--date", "2026-12-09"),
            ("stamp", "--version", "1.0", "--build", "70", "--date", "2026-13-01"),
            ("stamp", "--version", "1.0", "--build", "70", "--date", "2026-12-9"),
            ("stamp", "--version", "1.1-beta.0", "--build", "70", "--date", "2026-12-09"),
            ("notes", "--version", "1.1-rc.1", "--build", "70", "--date", "2026-12-09"),
            ("notes", "--version", "1.1-beta", "--build", "70", "--date", "2026-12-09"),
            ("stamp", *RELEASE, "--codename", 'Say "hi"'),
            ("stamp", *RELEASE, "--codename", " Stilgar"),
            ("stamp", *RELEASE, "--codename", ""),
            ("stamp", *RELEASE, "--codename", "Arrakis!"),
            ("notes", *PRERELEASE, "--codename", "Shi  shakli"),
            ("notes", *PRERELEASE, "--codename", "-Shishakli"),
        ):
            with self.subTest(argv=[command, *argv]):
                code, err = self.usage_error(command, *argv)
                self.assertEqual(code, 2)
                self.assertIn("usage:", err)
                self.assertEqual(self.read(), SAMPLE)


if __name__ == "__main__":
    unittest.main()
