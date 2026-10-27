#!/usr/bin/env python3
"""Post to this repository's GitHub Discussions through `gh api graphql`.

  gh-discussion.py --category "Show and tell" --title "2026-10-27 — Subject" --body-file report.md [--pin]
  gh-discussion.py --comment 12 --body-file reply.md
  gh-discussion.py --check --category General --title "…" --body-file draft.md

The first form creates a discussion and prints its URL. --pin asks GitHub to
pin it; the GraphQL API has no pinDiscussion mutation as of 2026-10-27, so the
result says to pin it from the discussion's menu in the browser (the attempt
stays in case GitHub adds the mutation). The second form appends the body as
a comment to discussion number 12 and prints the comment's URL. --check runs
every check (repository, category, title, body) and prints what would be
posted, without posting anything.

A body or title is refused when it holds private data, the kinds that
.gitleaks.toml keeps out of the repository (docs/scaffold-design.md, section 2):
  - an address in the house subnet 10.0.1.x: anything starting with 10.0.1.,
    and such an address with zero-padded or hexadecimal octets or in the
    three-part short form;
  - any other IPv4 address that is neither a documented placeholder nor a
    textbook example: what passes is the fans 10.0.2.151 and 10.0.2.152, the
    controller 10.0.2.10, the documentation networks of RFC 5737 (192.0.2.x,
    which holds the VM 192.0.2.7 and the Windows VM 192.0.2.8, 198.51.100.x
    and 203.0.113.x), 0.x.x.x (also four-part version numbers), loopback,
    224.x.x.x and above (multicast groups, netmasks, broadcast) and the
    textbook 1.2.3.4. Stricter than .gitleaks.toml, which lets the manual's
    examples through: 192.168.x.x and 10.10.10.10 are refused, being LAN
    addresses a tester's real ones may be;
  - a MAC address, written with colons or hyphens, outside the documentation
    range 00:00:5e:00:53:xx of RFC 7042 (the placeholder is 00:00:5e:00:53:01),
    other than the all-zero and the broadcast address;
  - a Modern Forms client id, MF_ and twelve or more hex digits, other than
    one of that range (the placeholder is MF_00005E005301), all zeros or all F;
  - an e-mail address, a fan's device information naming its owner's account,
    unless it is in a documentation domain (example.com, .net or .org, or the
    reserved .example, .invalid, .test and .localhost), a GitHub noreply
    address or git@github.com;
  - a cloud identity id, an AWS region and a UUID (the fan's
    federatedIdentity), other than the all-zero one.
A reason names the kind and the line, never the data. A body is also refused
over GitHub's limit of 65,536 characters. Replace the data with the
placeholders or trim the text and run again. A title that one of the
repository's latest 100 discussions already carries is refused as well, so a
retry after a server error cannot post twice (GitHub has answered "Something
went wrong" after creating the discussion all the same);
--allow-duplicate-title posts anyway.

The repository is the one `gh repo view` resolves from the current directory,
or --repo owner/name. Standard library only; needs `gh` logged in with the
repo scope (`gh auth status`).

Exit codes: 0 success, 1 error (gh failed, unknown category, bad arguments),
2 body or title refused (private data, too long, or a title already used).
"""

import argparse
import json
import re
import subprocess
import sys

EXIT_OK, EXIT_ERROR, EXIT_REFUSED = 0, 1, 2
BODY_LIMIT = 65536

# ---------------------------------------------------------------------------
# Private data (docs/scaffold-design.md, section 2): never posted
# ---------------------------------------------------------------------------

# The house subnet, in every spelling: the prefix itself (also "10.0.1.x"), zero-padded or
# hexadecimal octets, and the three-part short form (10.0. and a last number from 256 to 511).
# Nothing in it passes. (Spelled out here, an address of that form would itself be a finding.)
HOUSE_SUBNET_RE = re.compile(
    r"(?<![0-9.])10\.0\.1\."
    r"|\b0{0,2}10\.0{1,3}\.0{0,2}1\.(?:[0-9]{1,3}|0x[0-9a-f]{1,2})\b"
    r"|\b0x0a\.0x0{1,2}\.0x0?1\.0x[0-9a-f]{1,2}\b"
    r"|\b10\.0\.(?:2(?:5[6-9]|[6-9][0-9])|[34][0-9]{2}|5(?:0[0-9]|1[01]))\b",
    re.IGNORECASE,
)
# A dotted IPv4 address: four numbers of one to three digits, not part of a longer dotted number.
IPV4_RE = re.compile(r"(?<![0-9])(?<![0-9]\.)([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(?!\.?[0-9])")
# The placeholders of the fans and the controller (the VM and the Windows VM are in TEST-NET-1), and
# the textbook 1.2.3.4.
PASSING_ADDRESSES = frozenset(
    tuple(int(octet) for octet in address.split("."))
    for address in ("10.0.2.151", "10.0.2.152", "10.0.2.10", "1.2.3.4")
)
DOCUMENTATION_NETWORKS = frozenset(((192, 0, 2), (198, 51, 100), (203, 0, 113)))  # RFC 5737, TEST-NET-1 to 3
# Six pairs of hex digits joined by one separator, colons or hyphens throughout.
MAC_RE = re.compile(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{2}([:-])[0-9A-Fa-f]{2}(?:\1[0-9A-Fa-f]{2}){4}(?![0-9A-Fa-f])")
# A Modern Forms client id: MF_ and the fan's MAC in hex digits (all of them, however many follow).
CLIENT_ID_RE = re.compile(r"(?<![A-Za-z0-9])MF_[0-9A-F]{12,}", re.IGNORECASE)
# RFC 7042's documentation range 00:00:5e:00:53:00 to 00:00:5e:00:53:ff, the all-zero address and the
# broadcast address name no device, as MACs and as client ids.
PASSING_HARDWARE = re.compile(r"00005e0053[0-9a-f]{2}|0{12}|f{12}")
EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b")
DOCUMENTATION_DOMAINS = ("example.com", "example.net", "example.org")  # RFC 2606, also their subdomains
RESERVED_TOP_LEVEL = ("example", "invalid", "test", "localhost")  # RFC 2606 and RFC 6761
# An AWS-style identity id, region:UUID, as the fan's device information gives its owner's identity.
IDENTITY_RE = re.compile(
    r"\b[a-z]{2}(?:-gov)?-[a-z]+-[0-9]{1,2}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
    re.IGNORECASE,
)


def ipv4_passes(match):
    """Whether the IPv4 rule lets an address through: a placeholder or 1.2.3.4, an address of a
    documentation network, one that is never a host on someone's network (0.x.x.x, which also holds
    four-part version numbers; loopback; 224.x.x.x and above: multicast groups, netmasks, broadcast),
    or no address at all (a number over 255). An address in the house subnet is left to that rule,
    which names it."""
    octets = tuple(int(number) for number in match.groups())
    if max(octets) > 255 or octets[:3] == (10, 0, 1):
        return True
    if octets in PASSING_ADDRESSES or octets[:3] in DOCUMENTATION_NETWORKS:
        return True
    return octets[0] in (0, 127) or octets[0] >= 224


def mac_passes(match):
    return PASSING_HARDWARE.fullmatch(re.sub(r"[:-]", "", match.group(0)).lower()) is not None


def client_id_passes(match):
    return PASSING_HARDWARE.fullmatch(match.group(0)[3:].lower()) is not None


def email_passes(match):
    address = match.group(0).lower()
    domain = address.rpartition("@")[2]
    if address == "git@github.com" or domain == "users.noreply.github.com":
        return True
    if any(domain == name or domain.endswith("." + name) for name in DOCUMENTATION_DOMAINS):
        return True
    return domain.rpartition(".")[2] in RESERVED_TOP_LEVEL


def identity_passes(match):
    return set(match.group(0).partition(":")[2].replace("-", "")) == {"0"}


# (pattern, what it is, whether a match passes). Every other match refuses the post.
PRIVATE_PATTERNS = (
    (HOUSE_SUBNET_RE, "an address in the house subnet 10.0.1.x", lambda match: False),
    (IPV4_RE, "an IPv4 address that is neither a documented placeholder nor a textbook example", ipv4_passes),
    (MAC_RE, "a MAC address outside the documentation range 00:00:5e:00:53:xx", mac_passes),
    (CLIENT_ID_RE, "a Modern Forms client id of a real fan (the placeholder is MF_00005E005301)", client_id_passes),
    (EMAIL_RE, "an e-mail address outside the documentation domains", email_passes),
    (IDENTITY_RE, "a cloud identity id (region:UUID) of a real account", identity_passes),
)

REPO_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    id
    discussionCategories(first: 25) { nodes { id name slug } }
  }
}
"""

CREATE_MUTATION = """
mutation($repositoryId: ID!, $categoryId: ID!, $title: String!, $body: String!) {
  createDiscussion(input: {repositoryId: $repositoryId, categoryId: $categoryId, title: $title, body: $body}) {
    discussion { id number url }
  }
}
"""

PIN_MUTATION = """
mutation($discussionId: ID!) {
  pinDiscussion(input: {discussionId: $discussionId}) { discussion { number } }
}
"""

TITLES_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    discussions(first: 100, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { number title url } }
  }
}
"""

DISCUSSION_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    discussion(number: $number) { id url title }
  }
}
"""

COMMENT_MUTATION = """
mutation($discussionId: ID!, $body: String!) {
  addDiscussionComment(input: {discussionId: $discussionId, body: $body}) { comment { url } }
}
"""


class GhError(Exception):
    """A user-facing error: printed to stderr, exit 1."""


# ---------------------------------------------------------------------------
# Talking to gh
# ---------------------------------------------------------------------------


def run_gh(args, stdin=None):
    try:
        return subprocess.run(["gh"] + args, input=stdin, capture_output=True, text=True)
    except FileNotFoundError:
        raise GhError("gh is not installed or not on PATH") from None


def graphql(query, variables):
    """Run one GraphQL document with variables; return its `data` or raise."""
    payload = json.dumps({"query": query, "variables": variables})
    proc = run_gh(["api", "graphql", "--input", "-"], stdin=payload)
    data = None
    if proc.stdout.strip():
        try:
            data = json.loads(proc.stdout)
        except ValueError:
            data = None
    if isinstance(data, dict) and data.get("errors"):
        messages = "; ".join(str(e.get("message", e)) for e in data["errors"])
        raise GhError("GraphQL: " + messages)
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or "exit %d" % proc.returncode
        raise GhError("gh api graphql failed: " + detail)
    if not isinstance(data, dict) or "data" not in data:
        raise GhError("gh api graphql returned no data: " + proc.stdout[:200])
    return data["data"]


def resolve_repo(spec):
    """owner, name from --repo or from the checkout gh sees."""
    if spec:
        parts = spec.split("/")
        if len(parts) != 2 or not all(parts):
            raise GhError("--repo wants owner/name, got %r" % spec)
        return parts[0], parts[1]
    proc = run_gh(["repo", "view", "--json", "owner,name"])
    if proc.returncode != 0:
        raise GhError("gh repo view failed (run it inside the repository or pass --repo): " + proc.stderr.strip())
    info = json.loads(proc.stdout)
    return info["owner"]["login"], info["name"]


def repo_and_categories(owner, name):
    repo = graphql(REPO_QUERY, {"owner": owner, "name": name})["repository"]
    if repo is None:
        raise GhError("repository %s/%s not found or not readable" % (owner, name))
    return repo["id"], repo["discussionCategories"]["nodes"]


def existing_with_title(owner, name, title):
    """The latest discussions whose title equals `title`."""
    nodes = graphql(TITLES_QUERY, {"owner": owner, "name": name})["repository"]["discussions"]["nodes"]
    return [d for d in nodes if d["title"].strip() == title.strip()]


def pick_category(categories, wanted):
    key = wanted.strip().lower()
    for cat in categories:
        if key in (cat["name"].lower(), cat["slug"].lower()):
            return cat
    names = ", ".join(c["name"] for c in categories)
    raise GhError("no discussion category %r; the repository has: %s" % (wanted, names))


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------


def refusals(text, what):
    """Reasons to refuse `text`, one per kind of private data it holds, each naming the first
    offending line (never the data itself, so the reason can be quoted anywhere)."""
    found = []
    for pattern, meaning, passes in PRIVATE_PATTERNS:
        for match in pattern.finditer(text):
            if not passes(match):
                line = text.count("\n", 0, match.start()) + 1
                found.append("%s holds %s (line %d)" % (what, meaning, line))
                break
    return found


def read_body(path):
    if path == "-":
        body = sys.stdin.read()
    else:
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
    if not body.strip():
        raise GhError("the body is empty")
    return body


def check_text(body, title):
    problems = refusals(body, "the body")
    if title is not None:
        problems += refusals(title, "the title")
    if len(body) > BODY_LIMIT:
        problems.append("the body is %d characters; GitHub allows %d (trim it)" % (len(body), BODY_LIMIT))
    return problems


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def create(args, body):
    owner, name = resolve_repo(args.repo)
    repo_id, categories = repo_and_categories(owner, name)
    category = pick_category(categories, args.category)
    same = existing_with_title(owner, name, args.title)
    if same and not args.allow_duplicate_title:
        print(
            "refused: a discussion with this title exists: %s (--allow-duplicate-title posts anyway)" % same[0]["url"],
            file=sys.stderr,
        )
        return EXIT_REFUSED
    if args.check:
        print(
            "OK: would post to %s in %s/%s: %r (%d characters%s)"
            % (category["name"], owner, name, args.title, len(body), ", then pin it" if args.pin else "")
        )
        return EXIT_OK
    result = graphql(
        CREATE_MUTATION,
        {
            "repositoryId": repo_id,
            "categoryId": category["id"],
            "title": args.title,
            "body": body,
        },
    )
    discussion = result["createDiscussion"]["discussion"]
    print(discussion["url"])
    if args.pin:
        try:
            graphql(PIN_MUTATION, {"discussionId": discussion["id"]})
            print("pinned", file=sys.stderr)
        except GhError as err:
            if "pinDiscussion" in str(err):
                print(
                    "not pinned: GitHub's API has no pinDiscussion mutation; pin it from the "
                    "discussion's menu in the browser",
                    file=sys.stderr,
                )
            else:
                print("not pinned: %s" % err, file=sys.stderr)
    return EXIT_OK


def comment(args, body):
    owner, name = resolve_repo(args.repo)
    repo = graphql(DISCUSSION_QUERY, {"owner": owner, "name": name, "number": args.comment})["repository"]
    discussion = repo and repo.get("discussion")
    if not discussion:
        raise GhError("no discussion #%d in %s/%s" % (args.comment, owner, name))
    if args.check:
        print(
            "OK: would comment on #%d %r in %s/%s (%d characters)"
            % (args.comment, discussion["title"], owner, name, len(body))
        )
        return EXIT_OK
    result = graphql(COMMENT_MUTATION, {"discussionId": discussion["id"], "body": body})
    print(result["addDiscussionComment"]["comment"]["url"])
    return EXIT_OK


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="gh-discussion.py",
        description="Create a GitHub discussion, or comment on one, through gh api graphql.",
        epilog=__doc__.split("\n\n", 1)[1],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--category", help="category name or slug (Announcements, General, Ideas, Polls, Q&A, Show and tell)"
    )
    parser.add_argument("--title", help="the discussion's title, YYYY-MM-DD — subject")
    parser.add_argument(
        "--body-file", required=True, metavar="PATH", help="Markdown file holding the body; - reads standard input"
    )
    parser.add_argument("--pin", action="store_true", help="ask GitHub to pin the new discussion (see below)")
    parser.add_argument(
        "--allow-duplicate-title", action="store_true", help="post even if a discussion with the same title exists"
    )
    parser.add_argument(
        "--comment", type=int, metavar="NUMBER", help="append the body as a comment to this discussion instead"
    )
    parser.add_argument("--repo", metavar="OWNER/NAME", help="the repository (default: the one gh resolves here)")
    parser.add_argument(
        "--check", action="store_true", help="run the checks and print what would be posted; post nothing"
    )
    args = parser.parse_args(argv)
    if args.comment is not None:
        if args.category or args.title or args.pin or args.allow_duplicate_title:
            parser.error("--comment takes only --body-file (and --repo, --check)")
    else:
        if not args.category or not args.title:
            parser.error("--category and --title are required to create a discussion")
    return args


def main(argv):
    args = parse_args(argv)
    try:
        body = read_body(args.body_file)
        problems = check_text(body, args.title)
        if problems:
            for problem in problems:
                print("refused: " + problem, file=sys.stderr)
            return EXIT_REFUSED
        if args.comment is not None:
            return comment(args, body)
        return create(args, body)
    except GhError as err:
        print("error: %s" % err, file=sys.stderr)
        return EXIT_ERROR
    except (OSError, KeyError, ValueError) as err:
        print("error: %s" % err, file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
