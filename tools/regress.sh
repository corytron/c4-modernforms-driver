#!/usr/bin/env bash
# Dev-loop regression pass (docs/dev-loop.md, "Regression pass"): the generic part of the
# dev-loop checks of docs/release-checklist.md, run through tools/devctl.py against a --dev build on
# the house, and with --fan the fan's own pass of docs/v1-design.md section 12 (F1 to F9). The generic
# part checks the loop itself and is read-only:
#   1. status: the dev server answers, a device polled it within the last 10 s, the device's dev key
#      is the server's, exactly one device polls, and the code every device runs is the local tree
#      (a reload that is due right after an edit gets 15 s to land);
#   2. a property read-back: Debug Mode is set to the value it already has, a signed command that
#      changes nothing, and its command_done report must bring that value back with a Driver
#      Version;
#   3. the shipped log: no error, traceback, refusal or failed reload in its last 400 lines.
# --fan moves the fan and its light, so it is opt-in, and it runs only when the checks above all
# passed. It drives the signed development commands of fan/devcmds.lua (Dev Fan State, Dev Proxy,
# Dev Press) and reads each result back from the Dev State row: every speed, off, the toggle and
# cycle links, the light's targets and its top button, then the fan and the light as F1 found them.
# Needs tools/devserver.py running and the dev driver polling it (tools/devctl.py status).
#
# Usage: tools/regress.sh [--fan [--default-on N]] [--server URL] [--key-file FILE] [--state-dir DIR]
#   --default-on N  the light's Default On Brightness (the house keeps 100): F7 then wants exactly N
#                   instead of any level
#   every other argument goes to each tools/devctl.py call
# Exit status: the number of failed checks (0: all passed; the fan pass stops at its first), or 2
# at once when tools/devctl.py status fails (no server, no dev key, a server with another key) or
# the arguments are wrong.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fan_pass=no
default_on=""
default_on_given=no
devctl_args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--fan) fan_pass=yes ;;
		--default-on)
			default_on_given=yes
			default_on="${2:-}"
			[[ $# -gt 0 ]] && shift
			;;
		*) devctl_args+=("$1") ;;
	esac
	[[ $# -gt 0 ]] && shift
done
if [[ "$default_on_given" == yes ]]; then
	if [[ "$fan_pass" == no ]]; then
		echo "regress.sh: --default-on belongs to --fan" >&2
		exit 2
	fi
	if [[ ! "$default_on" =~ ^[0-9]+$ ]] || ((10#$default_on < 1 || 10#$default_on > 100)); then
		echo "regress.sh: --default-on wants a level from 1 to 100" >&2
		exit 2
	fi
	default_on=$((10#$default_on))
fi
DEVCTL=(python3 -I "$ROOT/tools/devctl.py" "${devctl_args[@]}")
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
finish() {
	say "result"
	if [[ $fail -eq 0 ]]; then
		echo "ALL PASS"
	else
		echo "$fail check(s) failed"
	fi
	exit "$fail"
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

# The fan pass -----------------------------------------------------------------------------------
#
# Every step of F1 to F9 is one dev-loop batch: a Dev Fan State read, then the step's commands, then
# a wait for the last of them. The read comes first, so it shows what the step before left, one poll
# (3 s) after that step's commands ran; this step's own result is read, and the step before checked,
# by the next batch. A step costs one poll instead of two, which keeps the pass near a minute, and a
# step that is still busy at its read has taken longer than a poll and fails (v1-design allows 5 s).
# The first step that does not read back as expected ends the pass: the fan and the light are put
# back as F1 found them (best effort), and the exit status is the number of failed checks.

dev_state=""      # the Dev State row of the latest batch's read
prev_state=""     # the one before
queued=""         # id of the latest command queued
moved=no          # whether a command that moves the fan has been queued
start_fan=""      # fan= and light= as F1 found them
start_light=""
preset=""         # the fan's preset speed, learned by F4
current_label=""  # the step whose result the latest read is checked as
pending_label=""  # the step whose result the next read must show
pending_check=()  # ... and the function and arguments that check it

# The value of <key> in a Dev State line: key=value pairs, separated by spaces ("" when absent).
field() { # field <key> <line>
	local -a pairs=()
	local pair
	read -ra pairs <<<"$2"
	for pair in "${pairs[@]}"; do
		if [[ "$pair" == "$1="* ]]; then
			printf '%s\n' "${pair#*=}"
			return
		fi
	done
}

# The leds field of a Dev State line without the light's buttons: "300:1,301:0,...,308:1".
fan_leds_of() { # fan_leds_of <line>
	field leds "$1" | cut -d, -f1-9
}

# The lit state links 300 to 308 should show with the fan at <speed> (0: off): Fan Off lit while the
# fan is off, Toggle and Cycle while it is on, a speed link at its own speed.
fan_leds() { # fan_leds <speed>
	local speed="$1" link lit out=""
	for link in 300 301 302 303 304 305 306 307 308; do
		case "$link" in
			300) lit=$((speed == 0)) ;;
			307 | 308) lit=$((speed > 0)) ;;
			*) lit=$((speed == link - 300)) ;;
		esac
		out+="${out:+,}$link:$lit"
	done
	printf '%s\n' "$out"
}

# The notify.fan the latest read should show: one more than the read before when the fan's state
# changed (one notification per real change, R1), else the same.
expected_notify() {
	local before
	before="$(field notify.fan "$prev_state")"
	if [[ ! "$before" =~ ^[0-9]+$ ]]; then
		echo "?"
	elif [[ "$(field fan "$prev_state")" != "$(field fan "$dev_state")" ]]; then
		echo $((before + 1))
	else
		echo "$before"
	fi
}

# Queues one signed development command (devctl.py run) and remembers its id.
queue() { # queue "Dev Press" LINK=307 ACTION=tap
	if ! queued="$("${DEVCTL[@]}" run "$@" 2>&1)"; then
		echo "$queued"
		return 1
	fi
}

# One batch: a Dev Fan State read, then the commands given (words of one command, "--" between
# commands), then the wait for the last, whose report brings the Dev State row.
run_batch() { # run_batch ["Dev Proxy" BINDING=5001 ... [-- "Dev Press" LINK=307 ...]]
	local -a words=()
	local out
	queue "Dev Fan State" || return 1
	while [[ $# -gt 0 ]]; do
		if [[ "$1" == -- ]]; then
			queue "${words[@]}" || return 1
			words=()
		else
			words+=("$1")
		fi
		shift
	done
	if [[ ${#words[@]} -gt 0 ]]; then
		queue "${words[@]}" || return 1
	fi
	if ! out="$("${DEVCTL[@]}" wait "$queued" --timeout 20 2>&1)"; then
		echo "$out"
		return 1
	fi
	prev_state="$dev_state"
	dev_state="$(property "Dev State" "$out")"
	if [[ -z "$dev_state" ]]; then
		echo "$out"
		echo "the report has no Dev State row: is the installed driver a --dev build with the fan's development commands?"
		return 1
	fi
}

# The commands that put the fan and the light back as F1 read them, in the array `restore` of the
# caller (words, "--" between commands): speed 0 for off, the speed for on/N; the light's target 0
# for off, the level for on/N; nothing for a light that is not there.
fan_restore_args() {
	restore=()
	case "$start_fan" in
		off) restore+=("Dev Proxy" BINDING=5001 COMMAND=SET_SPEED SPEED=0) ;;
		on/[1-6]) restore+=("Dev Proxy" BINDING=5001 COMMAND=SET_SPEED "SPEED=${start_fan#on/}") ;;
	esac
	case "$start_light" in
		off | on/*)
			[[ ${#restore[@]} -gt 0 ]] && restore+=(--)
			restore+=("Dev Proxy" BINDING=5002 COMMAND=SET_BRIGHTNESS_TARGET RATE=0)
			if [[ "$start_light" == off ]]; then
				restore+=(LIGHT_BRIGHTNESS_TARGET=0)
			else
				restore+=("LIGHT_BRIGHTNESS_TARGET=${start_light#on/}")
			fi
			;;
	esac
}

# Ends the pass: the fan and the light back as F1 found them (queued, not verified), then the result.
fan_stop() {
	local -a restore=()
	trap - INT TERM
	if [[ "$moved" == yes && -n "$start_fan" ]]; then
		fan_restore_args
		echo "putting the fan and its light back as F1 found them: fan=$start_fan light=$start_light"
		run_batch "${restore[@]}" >/dev/null 2>&1 || echo "(the restore was not confirmed)"
	fi
	finish
}

fan_abort() { # fan_abort <why>: the pass cannot go on and no step failed
	flunk "$1"
	fan_stop
}

fan_fail() { # fan_fail <what was wrong>: a step did not read back as expected
	flunk "$1"
	echo "  Dev State: $dev_state"
	fan_stop
}

# The latest read must show every pair, plus the invariants of a settled fan: no group busy, and what
# is shown is what is confirmed. Pairs are exact key=value, or
#   notify.fan=auto   as expected_notify says
#   leds.fan=<speed>  links 300 to 308 lit as fan_leds says for that speed
check_pairs() { # check_pairs <key=value>...
	local want key value have bad="" shown
	for want in busy=- "$@"; do
		key="${want%%=*}"
		value="${want#*=}"
		case "$key" in
			leds.fan)
				have="$(fan_leds_of "$dev_state")"
				value="$(fan_leds "$value")"
				;;
			notify.fan)
				have="$(field notify.fan "$dev_state")"
				[[ "$value" == auto ]] && value="$(expected_notify)"
				;;
			*) have="$(field "$key" "$dev_state")" ;;
		esac
		[[ "$have" == "$value" ]] || bad+=" $key=$have (wanted $value);"
	done
	for key in fan light; do
		shown="$(field "shown.$key" "$dev_state")"
		have="$(field "$key" "$dev_state")"
		[[ "$shown" == "$have" ]] || bad+=" shown.$key=$shown differs from $key=$have;"
	done
	if [[ -n "$bad" ]]; then
		fan_fail "$current_label:$bad"
	fi
	pass "$current_label ($*)"
}

# F4: Toggle from off turns the fan on at its preset, whichever speed that is. The preset is learned
# here and F5 counts from it.
check_preset_on() {
	local fan
	fan="$(field fan "$dev_state")"
	if [[ ! "$fan" =~ ^on/[1-6]$ ]]; then
		fan_fail "$current_label: fan=$fan, wanted the fan on at its preset (on/1 to on/6)"
	fi
	preset="${fan#on/}"
	check_pairs "fan=on/$preset" "told.fan=$preset" "leds.fan=$preset" notify.fan=auto
}

# F5: Cycle three times from the preset; Cycle stops at 6, as the proxy's does (V11, #77), and the
# burst coalesces into one report.
check_cycled() {
	local want=$((preset + 3 > 6 ? 6 : preset + 3))
	check_pairs "fan=on/$want" "told.fan=$want" "leds.fan=$want" notify.fan=auto
}

# F7: the top button turns the light on at Default On Brightness. Without --default-on any level
# does, but one that equals the level F6 left (70) cannot tell Default On from the kept level.
check_default_on() {
	local light level
	light="$(field light "$dev_state")"
	if [[ ! "$light" =~ ^on/([0-9]+)$ ]]; then
		fan_fail "$current_label: light=$light, wanted the light on at Default On Brightness"
	fi
	level="${BASH_REMATCH[1]}"
	if [[ -n "$default_on" && "$level" != "$default_on" ]]; then
		fan_fail "$current_label: light=on/$level, wanted on/$default_on (Default On Brightness)"
	fi
	check_pairs "light=on/$level" "told.light=$level" changing=0
	if [[ -z "$default_on" && "$level" == 70 ]]; then
		echo "NOTE  the light came on at 70, the level F6 left: only --default-on 70 tells Default On from the kept level"
	fi
}

# The check queued by expect_next, run on the read it now has: `pairs` with its pairs, or one of the
# dynamic checks above.
run_pending() {
	case "${pending_check[0]}" in
		pairs) check_pairs "${pending_check[@]:1}" ;;
		preset_on) check_preset_on ;;
		cycled) check_cycled ;;
		default_on) check_default_on ;;
		*) fan_abort "regress.sh has no check called '${pending_check[0]}'" ;;
	esac
}

# advance <command words...>: one batch (with no commands, just the read). Its read is checked against
# the step the batch before queued.
advance() {
	moved=yes
	run_batch "$@" || fan_abort "the dev loop did not bring a Dev State: the fan pass cannot go on"
	if [[ -n "$pending_label" ]]; then
		current_label="$pending_label"
		pending_label=""
		run_pending
	fi
}

# expect_next <label> <check> [<key=value>...]: what the read of the next batch must show: check is
# `pairs` (every pair given), `preset_on`, `cycled` or `default_on`.
expect_next() {
	pending_label="$1"
	shift
	pending_check=("$@")
}

fan_pass_run() {
	local before_lines n tries=0 log new errors
	local -a restore=()
	say "fan pass (docs/v1-design.md section 12, F1 to F9)"
	trap 'fan_abort "interrupted"' INT TERM
	before_lines="$("${DEVCTL[@]}" log -n 1000000 2>/dev/null | wc -l)"

	# F1: the state before. No command that moves anything has been queued yet, so a failure here
	# leaves the fan alone.
	while :; do
		run_batch || fan_abort "the dev loop did not bring a Dev State: the fan pass cannot go on"
		[[ "$(field busy "$dev_state")" == "-" ]] && break
		tries=$((tries + 1))
		[[ $tries -ge 3 ]] && break
	done
	start_fan="$(field fan "$dev_state")"
	start_light="$(field light "$dev_state")"
	current_label="F1 Dev Fan State"
	if [[ "$(field phase "$dev_state")" != online ]]; then
		fan_fail "$current_label: phase=$(field phase "$dev_state"), wanted online"
	elif [[ ! "$start_fan" =~ ^(off|on/[1-6])$ ]] || [[ ! "$start_light" =~ ^(off|on/[0-9]+|-)$ ]]; then
		fan_fail "$current_label: fan=$start_fan light=$start_light, wanted a known state"
	elif [[ "$(field busy "$dev_state")" != "-" ]]; then
		fan_fail "$current_label: busy=$(field busy "$dev_state") after 3 reads"
	fi
	pass "$current_label (phase=online fan=$start_fan light=$start_light)"

	# F2: every speed, 1 to 6, from the fan proxy.
	for n in 1 2 3 4 5 6; do
		advance "Dev Proxy" BINDING=5001 COMMAND=SET_SPEED "SPEED=$n"
		expect_next "F2 SET_SPEED $n" pairs "fan=on/$n" "told.fan=$n" "leds.fan=$n" notify.fan=auto
	done
	# F3: off.
	advance "Dev Proxy" BINDING=5001 COMMAND=SET_SPEED SPEED=0
	expect_next "F3 SET_SPEED 0" pairs fan=off told.fan=0 leds.fan=0 notify.fan=auto
	# F4: the Fan Toggle link, from off, to the preset. F5: Fan Cycle, a burst of three taps.
	advance "Dev Press" LINK=307 ACTION=tap
	expect_next "F4 Dev Press 307 tap" preset_on
	advance "Dev Press" LINK=308 ACTION=tap COUNT=3 EVERY=150
	expect_next "F5 Dev Press 308 tap x3" cycled
	# F6 and F7: the light, unless the fan has no light kit.
	if [[ "$start_light" != "-" ]]; then
		for n in 30 70 0; do
			advance "Dev Proxy" BINDING=5002 COMMAND=SET_BRIGHTNESS_TARGET "LIGHT_BRIGHTNESS_TARGET=$n" RATE=0
			if [[ $n -eq 0 ]]; then
				expect_next "F6 SET_BRIGHTNESS_TARGET 0" pairs light=off told.light=0 changing=0
			else
				expect_next "F6 SET_BRIGHTNESS_TARGET $n" pairs "light=on/$n" "told.light=$n" changing=0
			fi
		done
		advance "Dev Press" LINK=200 ACTION=tap
		expect_next "F7 Dev Press 200 tap" default_on
	fi
	# F8: the fan and the light back as F1 found them, read back by one more batch.
	fan_restore_args
	advance "${restore[@]}"
	if [[ "$start_light" == "-" ]]; then
		expect_next "F8 back to F1's state" pairs "fan=$start_fan"
	else
		expect_next "F8 back to F1's state" pairs "fan=$start_fan" "light=$start_light"
	fi
	advance
	trap - INT TERM
	if [[ "$start_light" == "-" ]]; then
		echo "SKIP  F6 F7: the fan has no light kit (light=-)"
	fi

	# F9: the shipped log since F1.
	current_label="F9 shipped log"
	log="$("${DEVCTL[@]}" log -n 1000000 2>&1)" || log=""
	new="$(tail -n +$((before_lines + 1)) <<<"$log")"
	errors="$(grep -niE '\[ERROR\]|attempt to |stack traceback|runtime error|refus|signed command .* failed|devloop: error' \
		<<<"$new" || true)"
	if [[ -n "$errors" ]]; then
		echo "$errors"
		flunk "$current_label: error, traceback or refusal lines since F1"
	else
		pass "$current_label (no error, traceback or refusal line since F1)"
	fi
}

if [[ "$fan_pass" == yes ]]; then
	if [[ $fail -eq 0 ]]; then
		fan_pass_run
	else
		say "fan pass"
		echo "SKIP  the fan pass: the checks above failed, and it moves the fan"
	fi
fi

finish
