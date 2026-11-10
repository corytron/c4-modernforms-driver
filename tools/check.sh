#!/usr/bin/env bash
# Run every check of the repository the same way on the VM and in CI
# (docs/cicd-gitops-design.md, section 3).
#
# Usage: tools/check.sh [--strict] [--only <name>...]
#   --strict          a check whose tool is not installed fails instead of
#                     being skipped (CI runs with it, so nothing is silently
#                     skipped on the runner)
#   --only <name>...  run only the named checks; they still run in the order
#                     below, whatever the order given
#
# Checks, in order:
#   lua-lint     luacheck src tests tools (and probes/ if present)
#   lua-test     busted tests
#   shell        shellcheck -S style tools/*.sh (and probes/*.sh and setup-vm.sh if present)
#   python-lint  ruff check --no-cache tools; ruff format --check --no-cache tools
#   python-test  python3 -B -m unittest discover -s tools/tests (-B: no __pycache__,
#                whose constant-folded test vectors the secrets tree scan would flag)
#   xml          every src/*/driver.xml (and probes/*/driver.xml) is well-formed (xml.etree, no xmllint)
#   powershell   Invoke-ScriptAnalyzer over tools/composer (skipped without pwsh)
#   workflows    actionlint; zizmor --min-severity medium .github/workflows
#   secrets      gitleaks over the working tree, then over the history of every
#                local ref (git log --all) or, in GitHub Actions, of HEAD only
#   house        python3 tools/deploy.py validate (deploy/house.yaml, offline)
#   changelog    python3 tools/changelog.py check (CHANGELOG.md, docs/changelog-design.md)
#   links        python3 tools/check_links.py: every link in every tracked Markdown
#                file and Documentation tab resolves (files and heading anchors)
#
# One line per check: "ok <name>", "FAIL <name>" followed by the output of the
# failing command(s), or "skip <name> (<tool> not installed)". Exit 1 when a
# check failed, 2 on a usage error, else 0. Tools are looked up on PATH with
# ~/.local/bin first, where tools/setup-checks.sh installs them.
#
# Parallel (#183): the checks run at the same time, at most JOBS at once (default:
# every core, as nproc counts them), each with its output kept apart and printed in
# the order above, so the report reads as if they had run one after the other. The
# slow ones are parallel inside too, with the same JOBS: luacheck -j through
# tools/luacheck_jobs.lua, tools/busted_parallel.py (one busted process per spec
# file) and tools/unittest_parallel.py (one process per test class). JOBS=1 runs one
# check at a time with the plain commands (luacheck, busted tests, python3 -m
# unittest), as before. No check writes into the working tree (ruff runs with
# --no-cache), so the secrets check can scan it while the others run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.local/bin:$PATH"

ALL_CHECKS=(lua-lint lua-test shell python-lint python-test xml powershell workflows secrets house changelog links)

JOBS="${JOBS:-$(nproc)}"
if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
	echo "check.sh: JOBS must be a positive integer, not '$JOBS'" >&2
	exit 2
fi
export JOBS

usage() {
	echo "usage: tools/check.sh [--strict] [--only <name>...]" >&2
	echo "checks: ${ALL_CHECKS[*]}" >&2
}

# The executables a check needs on PATH; a missing one makes the check a skip
# (or a failure with --strict).
tools_for() {
	case "$1" in
		lua-lint) echo luacheck ;;
		lua-test) if [[ "$JOBS" -gt 1 ]]; then echo busted python3; else echo busted; fi ;;
		shell) echo shellcheck ;;
		python-lint) echo ruff ;;
		python-test | xml | house | changelog) echo python3 ;;
		links) echo python3 git ;;
		powershell) echo pwsh ;;
		workflows) echo actionlint zizmor ;;
		secrets) echo gitleaks ;;
		*) echo "check.sh: no such check: $1" >&2; exit 2 ;;
	esac
}

# Print the command, then run it; the check's log shows what was run.
run() {
	echo "\$ $*"
	"$@"
}

check_lua_lint() {
	local dirs=(src tests tools)
	# The M1 probe package (docs/v1-design.md, section 11) lives outside src/ so no release carries it.
	if [[ -d probes ]]; then
		dirs+=(probes)
	fi
	if [[ "$JOBS" -gt 1 ]]; then
		# luacheck's own -j, with processes instead of LuaLanes threads.
		run env LUA_INIT=@tools/luacheck_jobs.lua luacheck -j "$JOBS" "${dirs[@]}"
	else
		run luacheck "${dirs[@]}"
	fi
}

check_lua_test() {
	if [[ "$JOBS" -gt 1 ]]; then
		run python3 -I tools/busted_parallel.py tests
	else
		run busted tests
	fi
}

check_shell() {
	local files=(tools/*.sh)
	local probe
	for probe in probes/*.sh; do
		if [[ -f "$probe" ]]; then
			files+=("$probe")
		fi
	done
	if [[ -f setup-vm.sh ]]; then
		files+=(setup-vm.sh)
	fi
	run shellcheck -S style "${files[@]}"
}

check_python_lint() {
	local rc=0
	run ruff check --no-cache tools || rc=1
	run ruff format --check --no-cache tools || rc=1
	return "$rc"
}

check_python_test() {
	if [[ ! -d tools/tests ]]; then
		echo "tools/tests/ does not exist: there are no Python unit tests to run"
		return 1
	fi
	if [[ "$JOBS" -gt 1 ]]; then
		run python3 -B tools/unittest_parallel.py discover -s tools/tests
	else
		run python3 -B -m unittest discover -s tools/tests
	fi
}

check_xml() {
	local files=(src/*/driver.xml)
	local probe
	for probe in probes/*/driver.xml; do
		if [[ -f "$probe" ]]; then
			files+=("$probe")
		fi
	done
	# xml.etree rejects what Composer would reject: unclosed tags, bad
	# entities, text outside the root element.
	run python3 -I -c '
import sys
import xml.etree.ElementTree as ET

rc = 0
for path in sys.argv[1:]:
    try:
        ET.parse(path)
        print("well-formed", path)
    except (ET.ParseError, OSError) as error:
        print(path + ": " + str(error), file=sys.stderr)
        rc = 1
sys.exit(rc)
' "${files[@]}"
}

check_powershell() {
	# The Windows session's helpers (docs/composer-remote.md). A missing folder
	# fails, as a missing tools/tests does: an analysis of nothing proves nothing.
	if [[ ! -d tools/composer ]]; then
		echo "tools/composer/ does not exist: there are no PowerShell scripts to analyse"
		return 1
	fi
	run pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path tools/composer -Recurse -Severity Error -EnableExit"
}

check_workflows() {
	local rc=0
	run actionlint || rc=1
	run zizmor --min-severity medium .github/workflows || rc=1
	return "$rc"
}

# Which history the secrets check reads. Run by hand, every local ref
# (branches, tags, stashes and remote-tracking refs): a stale tag or branch
# can hold history that never reached GitHub, and a `git push --tags` or
# `--mirror` would publish it (the Hue project's security review of
# 2026-10-25, finding 14). In CI (GitHub Actions sets GITHUB_ACTIONS=true)
# the history of the checked-out commit only: the full-depth checkout also
# holds every other branch and tag of the repository, whose findings are not
# this change's.
secrets_log_opts() {
	if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
		echo HEAD
	else
		echo --all
	fi
}

check_secrets() {
	local rc=0
	if [[ ! -f .gitleaks.toml ]]; then
		echo ".gitleaks.toml is missing: the secrets check needs the repository's gitleaks rules"
		return 1
	fi
	run gitleaks dir . --config .gitleaks.toml --no-banner --redact || rc=1
	run gitleaks git . --config .gitleaks.toml --no-banner --redact "--log-opts=$(secrets_log_opts)" || rc=1
	return "$rc"
}

check_house() {
	if [[ ! -f tools/deploy.py ]]; then
		echo "tools/deploy.py is missing: the house check validates deploy/house.yaml with it"
		return 1
	fi
	run python3 tools/deploy.py validate
}

check_changelog() {
	run python3 -I tools/changelog.py check --file CHANGELOG.md
}

check_links() {
	run python3 -I tools/check_links.py
}

strict=no
selected=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--strict)
			strict=yes
			shift
			;;
		--only)
			shift
			if [[ $# -eq 0 || "$1" == --* ]]; then
				echo "check.sh: --only needs at least one check name" >&2
				usage
				exit 2
			fi
			while [[ $# -gt 0 && "$1" != --* ]]; do
				known=no
				for name in "${ALL_CHECKS[@]}"; do
					if [[ "$name" == "$1" ]]; then
						known=yes
					fi
				done
				if [[ "$known" == no ]]; then
					echo "check.sh: unknown check: $1" >&2
					usage
					exit 2
				fi
				selected+=("$1")
				shift
			done
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "check.sh: unknown argument: $1" >&2
			usage
			exit 2
			;;
	esac
done

# Run in the canonical order, each selected check once.
to_run=()
for name in "${ALL_CHECKS[@]}"; do
	if [[ ${#selected[@]} -eq 0 ]]; then
		to_run+=("$name")
		continue
	fi
	for wanted in "${selected[@]}"; do
		if [[ "$wanted" == "$name" ]]; then
			to_run+=("$name")
			break
		fi
	done
done

failed=()
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

# Each check's verdict: a line already decided (a missing tool), or the pid of the
# check running in the background; printed strictly in the order of to_run.
verdicts=()
pids=()
printed=0
running=0

# Waits for the next check in order, if it runs, and prints its verdict.
print_next() {
	local name="${to_run[$printed]}" status
	if [[ -n "${pids[$printed]}" ]]; then
		wait "${pids[$printed]}" && status=0 || status=$?
		running=$((running - 1))
		if [[ $status -eq 0 ]]; then
			echo "ok $name"
		else
			echo "FAIL $name"
			sed 's/^/  /' "$logs/$name.log"
			failed+=("$name")
		fi
	else
		echo "${verdicts[$printed]}"
		if [[ "${verdicts[$printed]}" == FAIL* ]]; then
			failed+=("$name")
		fi
	fi
	printed=$((printed + 1))
}

for index in "${!to_run[@]}"; do
	name="${to_run[$index]}"
	pids[index]=""
	verdicts[index]=""
	missing=""
	read -r -a tools <<< "$(tools_for "$name")"
	for tool in "${tools[@]}"; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing="$tool"
			break
		fi
	done
	if [[ -n "$missing" ]]; then
		if [[ "$strict" == yes ]]; then
			verdicts[index]="FAIL $name ($missing not installed)"
		else
			verdicts[index]="skip $name ($missing not installed)"
		fi
		continue
	fi
	while [[ $running -ge $JOBS ]]; do
		print_next
	done
	fn="check_${name//-/_}"
	# As `if "$fn"` did when the checks ran in turn: errexit off inside the check,
	# whose status is its last command's.
	( set +e; "$fn" ) >"$logs/$name.log" 2>&1 &
	pids[index]=$!
	running=$((running + 1))
done
while [[ $printed -lt ${#to_run[@]} ]]; do
	print_next
done

if [[ ${#failed[@]} -gt 0 ]]; then
	echo "check.sh: ${#failed[@]} failed: ${failed[*]}"
	exit 1
fi
