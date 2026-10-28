#!/usr/bin/env bash
# Build the M1 probe (docs/v1-design.md, section 11; probes/README.md):
# build/probe/mf_probe.c4z, a throwaway driver that is never the house's
# driver and never a release package. It lives in probes/, outside src/, so
# tools/build.sh, build/manifest.json and the Release workflow never see it;
# this script writes under build/probe/ only and refuses any name the release
# uses, and a probe whose <name> or <model> is a release driver's.
#
# Usage: probes/build_probe.sh [--k9]
#   --k9   also build build/probe/mf_probe_k9.c4z for check K9: the same probe
#          under its own file name, <name>, <model> and proxy names, declaring
#          minimum OS 9.0.0, to see what Composer does with it.
#
# Every package carries LICENSE and NOTICE (Apache License 2.0, section 4). dp3
# packs it with --allowexecute, which appends C4:AllowExecute(true) to the
# packed driver.lua: the route to the Lua window that the Hue project's dev
# builds use on the house (driver.lua also calls it in OnDriverInit). dp3
# stamps <version>. build/probe/SHA256SUMS.txt lists what this run built, for
# the brief to the Windows session.
#
# Environment: DP3, the packager's dp3/driverpackager.py (default: under
# ~/c4-tools/drivers-driverpackager); PROBE_VERSION, the <version> to stamp
# (default: minutes since 2026-01-01 UTC, so that every rebuild is newer to
# Composer and "Add or Update Driver or Agent..." updates the device in place).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/probes/mf_probe"
OUT_NAME="probe"
OUT="$ROOT/build/$OUT_NAME"
STAGE_ROOT="$OUT/stage"
DP3="${DP3:-$HOME/c4-tools/drivers-driverpackager/dp3/driverpackager.py}"
PROBE="mf_probe"
K9="mf_probe_k9"
EPOCH_2026=1767225600 # 2026-01-01T00:00:00Z

k9=no
for arg in "$@"; do
	case "$arg" in
		--k9) k9=yes ;;
		*)
			echo "usage: probes/build_probe.sh [--k9]" >&2
			exit 2
			;;
	esac
done

# What the release writes in build/ (tools/build.sh, tools/deploy.py,
# tools/collect.py, the dev loop and the Release workflow), and one package
# per src/*/driver.xml.
release_names=(manifest.json changelog.html release-notes.md SHA256SUMS.txt attestations.sigstore.json
	mf-drivers.intoto.jsonl stage release dev collect)
release_xmls=()
for xml in "$ROOT"/src/*/driver.xml; do
	[[ -f "$xml" ]] || continue
	release_xmls+=("$xml")
	release_names+=("$(basename "$(dirname "$xml")")" "$(basename "$(dirname "$xml")").c4z")
done
if [[ ${#release_xmls[@]} -eq 0 ]]; then
	echo "build_probe.sh: no src/*/driver.xml to keep the probe apart from" >&2
	exit 1
fi

refuse_release_name() {
	local name="$1" taken
	for taken in "${release_names[@]}"; do
		if [[ "$name" == "$taken" ]]; then
			echo "build_probe.sh: refusing $name: the release uses that name in build/" >&2
			exit 1
		fi
	done
}

refuse_release_name "$OUT_NAME"
refuse_release_name "$PROBE"
refuse_release_name "$PROBE.c4z"
refuse_release_name "$K9"
refuse_release_name "$K9.c4z"
for name in "$PROBE" "$K9"; do
	if [[ -e "$ROOT/src/$name" ]]; then
		echo "build_probe.sh: src/$name exists: the probe must never be in src/, which tools/build.sh releases" >&2
		exit 1
	fi
done
if [[ -L "$ROOT/build" || -L "$OUT" ]]; then
	echo "build_probe.sh: build/ or build/$OUT_NAME/ is a symbolic link; refusing to write through it" >&2
	exit 1
fi

if [[ ! -f "$SRC/driver.xml" || ! -f "$SRC/driver.lua" ]]; then
	echo "build_probe.sh: probes/mf_probe/driver.xml and driver.lua are needed" >&2
	exit 1
fi
for required in LICENSE NOTICE; do
	if [[ ! -f "$ROOT/$required" ]]; then
		echo "build_probe.sh: $required is missing: every package carries LICENSE and NOTICE (Apache License 2.0, section 4)" >&2
		exit 1
	fi
done
if [[ ! -f "$DP3" ]]; then
	echo "build_probe.sh: dp3 packager not found at $DP3 (set DP3=...)" >&2
	exit 1
fi

# The probe's driver.xml is well-formed, and its <name> and <model> are no
# release driver's (docs/edge-cases-control4.md, D27).
python3 -I - "$SRC/driver.xml" "${release_xmls[@]}" <<'PY'
import sys
import xml.etree.ElementTree as ET

probe = ET.parse(sys.argv[1]).getroot()
for path in sys.argv[2:]:
    release = ET.parse(path).getroot()
    for tag in ("name", "model"):
        mine = (probe.findtext(tag) or "").strip()
        if not mine or mine == (release.findtext(tag) or "").strip():
            sys.exit("build_probe.sh: the probe's <%s> %r is empty or the one of %s" % (tag, mine, path))
PY

version="${PROBE_VERSION:-$((($(date -u +%s) - EPOCH_2026) / 60))}"
if [[ ! "$version" =~ ^[1-9][0-9]{0,8}$ ]]; then
	echo "build_probe.sh: the version must be a whole number from 1 to 999999999, not $version" >&2
	exit 1
fi

rm -rf "${STAGE_ROOT:?}"
mkdir -p "$STAGE_ROOT"
rm -f "$OUT/$PROBE.c4z" "$OUT/$K9.c4z" "$OUT/SHA256SUMS.txt"

# A copy of probes/mf_probe/ with LICENSE and NOTICE in build/probe/stage/NAME,
# and the manifest dp3 builds from, listing everything staged (dp3 stamps
# <version> only when it builds from a manifest).
stage_probe() {
	local name="$1"
	local stage="$STAGE_ROOT/$name" entry item
	mkdir -p "$stage"
	cp -R "$SRC/." "$stage/"
	cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$stage/"
	{
		echo "<Driver type=\"c4z\" name=\"$name\" squishLua=\"false\">"
		echo "<Items>"
		for entry in "$stage"/*; do
			item="$(basename "$entry")"
			[[ "$item" == "$name.c4zproj" ]] && continue
			if [[ -d "$entry" ]]; then
				echo "	<Item type=\"dir\" name=\"$item\" recurse=\"true\"/>"
			else
				echo "	<Item type=\"file\" name=\"$item\"/>"
			fi
		done
		echo "</Items>"
		echo "</Driver>"
	} >"$stage/$name.c4zproj"
}

# The K9 copy: its own <name>, <model> and proxy names, and minimum OS 9.0.0.
make_k9() {
	python3 -I - "$STAGE_ROOT/$K9/driver.xml" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
swaps = [
    ("<name>MF Probe (delete after M1)</name>", "<name>MF Probe K9 (delete after M1)</name>"),
    ("<model>MF Probe (M1 hardware checks)</model>", "<model>MF Probe K9 (minimum OS 9.0.0)</model>"),
    ("<minimum_os_version>3.3.0</minimum_os_version>", "<minimum_os_version>9.0.0</minimum_os_version>"),
    ('name="MF Probe Fan"', 'name="MF Probe K9 Fan"'),
    ('name="MF Probe Light"', 'name="MF Probe K9 Light"'),
]
for old, new in swaps:
    if text.count(old) != 1:
        sys.exit("build_probe.sh: %s should hold %r once" % (path, old))
    text = text.replace(old, new)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY
}

# Pack one stage into build/probe/NAME.c4z and check what it holds.
pack() {
	local name="$1"
	refuse_release_name "$name.c4z"
	python3 "$DP3" --driver-version "$version" --update-modified --allowexecute \
		"$STAGE_ROOT/$name" "$OUT" "$name.c4zproj" >/dev/null
	if [[ ! -f "$OUT/$name.c4z" ]]; then
		echo "build_probe.sh: dp3 did not produce build/$OUT_NAME/$name.c4z" >&2
		exit 1
	fi
	python3 -I - "$OUT/$name.c4z" "$version" <<'PY'
import sys
import xml.etree.ElementTree as ET
import zipfile

path, version = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(path) as package:
    names = set(package.namelist())
    missing = {"driver.xml", "driver.lua", "LICENSE", "NOTICE"} - names
    if missing:
        sys.exit("build_probe.sh: %s lacks %s" % (path, ", ".join(sorted(missing))))
    stamped = ET.fromstring(package.read("driver.xml")).findtext("version")
    lua = package.read("driver.lua").decode("utf-8")
if stamped != version:
    sys.exit("build_probe.sh: %s says <version> %r, not %s" % (path, stamped, version))
if "C4:AllowExecute(true)" not in lua:
    sys.exit("build_probe.sh: %s: dp3 --allowexecute left no C4:AllowExecute(true)" % path)
PY
	built+=("$name.c4z")
	echo "built build/$OUT_NAME/$name.c4z (version $version)"
}

# Everything is staged before anything is packed, so a stage that fails
# leaves no package of this run behind.
built=()
names=("$PROBE")
stage_probe "$PROBE"
if [[ "$k9" == yes ]]; then
	stage_probe "$K9"
	make_k9
	names+=("$K9")
fi
for name in "${names[@]}"; do
	pack "$name"
done

(cd "$OUT" && sha256sum "${built[@]}") >"$OUT/SHA256SUMS.txt"
sed 's/^/  /' "$OUT/SHA256SUMS.txt"
echo "wrote build/$OUT_NAME/SHA256SUMS.txt"
