#!/usr/bin/env bash
# Dev-loop regression pass, read-only (docs/dev-loop.md, "Regression pass"): the generic part of the
# dev-loop checks of docs/release-checklist.md, run through tools/devctl.py against a --dev build on
# the house. The fan's own actions (a speed, the light, the links and their LEDs, each read back
# from what the fan answers) come with the v1 contract, which adds them here; until then this
# checks the loop itself:
#   1. status: the dev server answers, a device polled it within the last 10 s, the device's dev key
#      is the server's, exactly one device polls, and the code every device runs is the local tree
#      (a reload that is due right after an edit gets 15 s to land);
#   2. a property read-back: Debug Mode is set to the value it already has, a signed command that
#      changes nothing, and its command_done report must bring that value back with a Driver
#      Version;
#   3. the shipped log: no error, traceback, refusal or failed reload in its last 400 lines.
# Needs tools/devserver.py running and the dev driver polling it (tools/devctl.py status). Creates,
# deletes and changes nothing.
#
# Usage: tools/regress.sh [--server URL] [--key-file FILE] [--state-dir DIR]
#   every argument goes to each tools/devctl.py call
# Exit status: the number of failed checks (0: all passed), or 2 at once when tools/devctl.py
# status fails (no server, no dev key, a server with another key).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVCTL=(python3 -I "$ROOT/tools/devctl.py" "$@")
fail=0

say() { printf '\n== %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$1"; }
flunk() {
	printf 'FAIL  %s\n' "$1"
	fail=$((fail + 1))
}
expect() { # expect <extended regex> <text> <label>
	if grep -qE -- "$1" <<<"$2"; then
		pass "$3"
	else
		flunk "$3 (no match for /$1/)"
	fi
}
# The value of property <name> in devctl's "  <name> = <value>" rows of <text>.
property() { # property <name> <text>
	awk -v name="$1" 'index($0, "  " name " ") == 1 && $0 ~ /^  [^=]*= / { sub(/^[^=]*= /, ""); print; exit }' <<<"$2"
}

say "status"
if ! out="$("${DEVCTL[@]}" status 2>&1)"; then
	echo "$out"
	echo "tools/devctl.py status failed: is tools/devserver.py running, and does this machine hold its dev key?"
	exit 2
fi
# Right after an edit a reload is due: give the loop a few polls to land it.
for _ in 1 2 3 4 5; do
	grep -q "DIFFERS from local" <<<"$out" || break
	sleep 3
	out="$("${DEVCTL[@]}" status 2>&1)" || break
done
echo "$out"

seen=""
if [[ "$out" =~ (^|$'\n')last_seen\ +([0-9]+)s\ ago ]]; then
	seen="${BASH_REMATCH[2]}"
fi
if [[ -n "$seen" && "$seen" -le 10 ]]; then
	pass "a device polled the dev server ${seen}s ago"
else
	flunk "no device polled the dev server within 10 s (last_seen: ${seen:-never}): is its Dev Server set?"
fi
expect "^dev_key +matches the server's" "$out" "the device's dev key is the server's"
if grep -q "MORE THAN ONE device" <<<"$out"; then
	flunk "more than one device polls the dev server: empty Dev Server on all but one"
elif grep -qE "^device +none has reported yet" <<<"$out"; then
	flunk "no device has reported to the dev server"
else
	pass "one device polls the dev server"
fi
if grep -q "DIFFERS from local" <<<"$out"; then
	flunk "a device runs code other than the local tree (the tree rows above say which)"
else
	expect "^  (running|forwarded) +[0-9a-f]{12}  \(matches local\)" "$out" "the device runs the local tree"
fi

say "property read-back: Debug Mode, set to the value it already has"
debug="$(property "Debug Mode" "$out")"
if [[ -z "$debug" ]]; then
	flunk "the reported properties have no Debug Mode"
elif ! id="$("${DEVCTL[@]}" set "Debug Mode" "$debug" 2>&1)"; then
	flunk "tools/devctl.py set failed: $id"
elif ! back="$("${DEVCTL[@]}" wait "$id" --timeout 60 2>&1)"; then
	echo "$back"
	flunk "the device did not report command $id done within 60 s"
else
	grep -E "^  (Debug Mode|Driver Version) +=" <<<"$back"
	value="$(property "Debug Mode" "$back")"
	if [[ "$value" == "$debug" ]]; then
		pass "Debug Mode reads back as $debug"
	else
		flunk "Debug Mode reads back as '$value', not '$debug'"
	fi
	expect "^  Driver Version += .+" "$back" "the report carries a Driver Version"
fi

say "shipped log: errors in the last 400 lines"
if ! log="$("${DEVCTL[@]}" log -n 400 2>&1)"; then
	echo "$log"
	flunk "the shipped log cannot be read"
else
	errors="$(grep -nE '\[ERROR\]|attempt to |stack traceback|runtime error|devloop: (error: |.*reload failed|.*refused)' \
		<<<"$log" || true)"
	if [[ -n "$errors" ]]; then
		echo "$errors"
		flunk "errors in the shipped log"
	else
		pass "no error lines in the last 400 lines of the shipped log"
	fi
fi

say "result"
if [[ $fail -eq 0 ]]; then
	echo "ALL PASS"
else
	echo "$fail check(s) failed"
fi
exit "$fail"
