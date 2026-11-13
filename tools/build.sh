#!/usr/bin/env bash
# Build one build/<driver>.c4z per src/<driver>/driver.xml (today modernforms_fan
# and modernforms_breeze_fan) with Control4's dp3 packager. That directory list is the one list of the packages
# (docs/prerelease-design.md, section 2): build/manifest.json names them, and the Release
# workflow and tools/deploy.py read it from there.
#
# Usage: tools/build.sh [--dev] [--serve]
#   --dev   developer build: ships common/devloop.lua (the self-reloading dev
#           loop, see docs/dev-loop.md) with the dev key baked in as
#           common/devkey.lua, and allows the Lua command window in Composer
#           (dp3 --allowexecute). Release builds contain none of it. Implies
#           --serve.
#   --serve also copy each package into a directory of its own with a random
#           name, build/serve/<32 hex characters>/<driver>.c4z, for the one
#           download of an install that bypasses tools/deploy.py (a dev build,
#           or a feature-branch build for a hardware test), and print each
#           package's URL path. Serve them with
#             python3 -I -m http.server 8091 --bind <this VM's LAN address> --directory build/serve
#           for the duration of the download only: build/serve/index.html is
#           empty, so the server lists no directory, and a package can be
#           fetched only by whoever knows its random path.
#
# Every build empties build/serve first, so no package of an earlier build, and
# least of all a dev package, which carries the key, stays where it can be served.
#
# The dev key (docs/dev-loop.md, "Security") is the file tools/devserver.py
# uses: ~/.config/c4-modernforms-driver/devkey, or $C4_MF_DEVKEY_FILE; created
# on first use. It is written into the stage of a dev build only and removed
# from it once packed; the dev packages are written 0600, since whoever
# holds one holds the key. The key is never printed or put on a command line.
#
# Each driver is staged into build/stage/<driver>/ with src/common copied in
# as common/, so `require("common.log")` resolves inside the .c4z the same way
# it does in the tests. The driver.xml <version> is set to the git commit
# count so every build from a newer commit is seen by Composer as an update.
#
# A package carries regular files only: the packager would pack the file a
# symbolic link points at, wherever that is. The build refuses a link anywhere
# under src/, among its other inputs (LICENSE, NOTICE, CHANGELOG.md, the
# codename files, build/ itself) and in each stage before it is packed. Once
# packed, every package is opened again and compared with its stage
# (check_package below).
#
# Environment: DP3, the packager's dp3/driverpackager.py (default: under
# ~/c4-tools/drivers-driverpackager); C4_MF_RELEASE_TAG, the tag the Release
# workflow builds (below); C4_MF_DEVKEY_FILE, read by tools/devserver.py.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DP3="${DP3:-$HOME/c4-tools/drivers-driverpackager/dp3/driverpackager.py}"
DRIVERS=()
for xml in "$ROOT"/src/*/driver.xml; do
	[[ -f "$xml" ]] || continue
	DRIVERS+=("$(basename "$(dirname "$xml")")")
done
if [[ ${#DRIVERS[@]} -eq 0 ]]; then
	echo "build.sh: no src/*/driver.xml" >&2
	exit 1
fi

# What a release package never carries (docs/dev-loop.md, "Security"), by name,
# wherever it stands in a driver's stage and in any case: the dev loop
# (common/devloop.lua), the dev key (common/devkey.lua) and a driver's
# development commands (fan/devcmds.lua). A new development-only module takes
# one of these names (devcmds_<what>.lua, say) and so stays out of every
# release with no change here. Development-only properties and actions stand
# in driver.xml between a <!-- DEV-ONLY BEGIN ... --> line and a
# <!-- DEV-ONLY END --> line, which a release build strips (from any staged
# .xml file that has one); a DEV-ONLY marker left in any staged .lua or .xml
# file fails the build.
DEV_ONLY_NAMES=('devloop*' 'devkey*' 'devcmds*')
dev_only_find=()
for pattern in "${DEV_ONLY_NAMES[@]}"; do
	[[ ${#dev_only_find[@]} -eq 0 ]] || dev_only_find+=(-o)
	dev_only_find+=(-iname "$pattern")
done

extra_args=()
dev_build=no
serve=no
for arg in "$@"; do
	case "$arg" in
		--dev) extra_args+=(--allowexecute); dev_build=yes; serve=yes ;;
		--serve) serve=yes ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

# No symbolic link among what the build reads into a package.
mapfile -t links < <(find "$ROOT/src" -type l -printf 'src/%P\n' | sort)
for input in build LICENSE NOTICE CHANGELOG.md .github/codenames.json .github/codename-meanings.json; do
	if [[ -L "$ROOT/$input" ]]; then
		links+=("$input")
	fi
done
if [[ ${#links[@]} -gt 0 ]]; then
	echo "build.sh: a package carries regular files only, and these are symbolic links: ${links[*]}" \
		"(replace each with the file itself)" >&2
	exit 1
fi

# A key in the source tree could be committed or packed into a release:
# the dev key only ever exists in the stage of a dev build.
mapfile -t keys < <(find "$ROOT/src" -iname 'devkey*' -printf 'src/%P\n' | sort)
if [[ ${#keys[@]} -gt 0 ]]; then
	echo "${keys[*]} must not exist: the dev key is written into the stage of a dev build only" \
		"(docs/dev-loop.md, Security); delete it" >&2
	exit 1
fi

if [[ ! -f "$DP3" ]]; then
	echo "dp3 packager not found at $DP3 (set DP3=...)" >&2
	exit 1
fi

# Apache 2.0 §4: the license and notice travel with every package, and
# src/common is in every package as common/.
for required in LICENSE NOTICE; do
	if [[ ! -f "$ROOT/$required" ]]; then
		echo "build.sh: $required is missing: every package carries LICENSE and NOTICE (Apache License 2.0, section 4)" >&2
		exit 1
	fi
done
if [[ ! -d "$ROOT/src/common" ]]; then
	echo "build.sh: src/common is missing: every package carries it as common/" >&2
	exit 1
fi

dev_key=""
if [[ "$dev_build" == yes ]]; then
	if [[ ! -f "$ROOT/tools/devserver.py" ]]; then
		echo "tools/devserver.py is missing: a dev build takes the dev key from it (docs/dev-loop.md)" >&2
		exit 1
	fi
	# devserver.py creates the key file if missing (0600) and checks it; it
	# prints the path on stdout and the fingerprint on stderr.
	key_file="$(python3 "$ROOT/tools/devserver.py" --ensure-key)" || exit 1
	IFS= read -r dev_key < "$key_file" || true
	if [[ ! "$dev_key" =~ ^[0-9a-f]{64}$ ]]; then
		echo "the dev key in $key_file is not 64 lowercase hex characters" >&2
		exit 1
	fi
fi

version="$(git -C "$ROOT" rev-list --count HEAD)"
if [[ -n "$(git -C "$ROOT" status --porcelain -- src)" ]]; then
	echo "warning: src/ has uncommitted changes; version $version may repeat" >&2
fi

# The changelog at the bottom of every Documentation tab (docs/changelog-design.md
# §3): rendered once from CHANGELOG.md, as this release when HEAD carries a
# v* tag, as a development build in a --dev build, else as it stands. A
# release's heading takes the codename .github/codenames.json gives its X.Y,
# and tools/changelog.py refuses a version the file does not name.
# The Release workflow names its tag in C4_MF_RELEASE_TAG: a commit can carry both a
# prerelease tag and a stable one, and describe would pick either.
release_tag="${C4_MF_RELEASE_TAG:-$(git -C "$ROOT" describe --tags --exact-match --match 'v*' HEAD 2>/dev/null || true)}"
changelog_args=()
if [[ "$dev_build" == yes ]]; then
	changelog_args=(--dev-build "$version")
elif [[ -n "$release_tag" ]]; then
	changelog_args=(--release "${release_tag#v}" --build "$version" --date "$(date -u +%F)")
fi
changelog_html="$ROOT/build/changelog.html"
mkdir -p "$ROOT/build"
rm -rf "$ROOT/build/serve"
logs="$(mktemp -d)"
cleanup() {
	rm -rf "$logs"
	if [[ "$dev_build" == yes ]]; then
		# Even a build that fails half-way leaves no key in the stage.
		rm -f "$ROOT/build/stage"/*/common/devkey.lua
	fi
}
trap cleanup EXIT

# The check and the rendering run at the same time; the check's verdict comes first, as when they
# ran one after the other.
python3 -I "$ROOT/tools/changelog.py" check --file "$ROOT/CHANGELOG.md" >/dev/null &
check_pid=$!
python3 -I "$ROOT/tools/changelog.py" html --file "$ROOT/CHANGELOG.md" "${changelog_args[@]}" \
	> "$changelog_html" 2> "$logs/changelog.err" &
html_pid=$!
wait "$check_pid" && status=0 || status=$?
if [[ $status -ne 0 ]]; then
	wait "$html_pid" || true
	exit "$status"
fi
wait "$html_pid" && status=0 || status=$?
cat "$logs/changelog.err" >&2
if [[ $status -ne 0 ]]; then
	exit "$status"
fi

stage_root="$ROOT/build/stage"
rm -rf "$stage_root"
mkdir -p "$stage_root"

# check_package release|dev <package> <stage> <version>: opens a packed .c4z
# again and compares it with its stage. The package must hold exactly the
# stage's files (the generated .c4zproj aside), each once, none a link, none
# outside the package, each with the stage's bytes: driver.xml as XML, with
# the <version> and <modified> dp3 stamps, and in a dev package driver.lua with
# dp3's two --allowexecute lines appended. A release package must also hold no
# development-only file (by the names above), no DEV-ONLY marker in a .lua or
# .xml file, and nothing that opens the Lua command window: an
# AllowExecute(true) call in any of its spellings (C4:AllowExecute(true),
# C4.AllowExecute(C4, true), pcall(C4.AllowExecute, C4, true)) or
# gIsDevelopmentVersionOfDriver, which dp3 --allowexecute appends with it. The
# call that locks the window, pcall(C4.AllowExecute, C4, false), passes. It
# reads the package's contents, not the manifest's dev flag, and prints what
# is wrong, never a file's contents.
check_package() {
	python3 -I - "$@" <<'PY'
import os
import re
import stat
import sys
import xml.etree.ElementTree as ET
import zipfile

kind, package, stage, version = sys.argv[1:5]
DEV_ONLY = re.compile(r"(?i)^(?:devloop|devkey|devcmds)")
OPENS_WINDOW = re.compile(
    rb"AllowExecute\s*\(\s*(?:C4\s*,\s*)?true|AllowExecute\s*,\s*C4\s*,\s*true|gIsDevelopmentVersionOfDriver"
)


def canonical(data, stamp=None):
    root = ET.fromstring(data)
    for tag, value in (stamp or {}).items():
        element = root.find(tag)
        if element is not None:
            element.text = value
    return ET.canonicalize(ET.tostring(root, encoding="unicode"))


problems = []
staged = {}
for folder, dirs, files in os.walk(stage):
    for name in dirs + files:
        path = os.path.join(folder, name)
        rel = os.path.relpath(path, stage).replace(os.sep, "/")
        if os.path.islink(path):
            problems.append("%s is a symbolic link in the stage" % rel)
        elif name in files and not rel.endswith(".c4zproj"):
            staged[rel] = path
packed = {}
with zipfile.ZipFile(package) as z:
    names = [info.filename for info in z.infolist()]
    for name in sorted({name for name in names if names.count(name) > 1}):
        problems.append("%s is in the package more than once" % name)
    for info in z.infolist():
        name = info.filename
        parts = name.split("/")
        if name.startswith("/") or "\\" in name or ".." in parts or "" in parts:
            problems.append("%r is no path inside the package" % name)
        elif stat.S_ISLNK(info.external_attr >> 16):
            problems.append("%s is a symbolic link in the package" % name)
        else:
            if kind == "release" and any(DEV_ONLY.match(part) for part in parts):
                problems.append("%s is a development-only file" % name)
            packed[name] = z.read(info)
for name in sorted(set(packed) - set(staged)):
    problems.append("%s is in the package but not in the stage" % name)
for name in sorted(set(staged) - set(packed)):
    problems.append("%s is in the stage but not in the package" % name)
for name in sorted(set(packed) & set(staged)):
    data = packed[name]
    with open(staged[name], "rb") as f:
        source = f.read()
    if name == "driver.xml":
        try:
            stamp = {tag: ET.fromstring(data).findtext(tag) for tag in ("version", "modified")}
            same = canonical(source, stamp) == canonical(data)
        except ET.ParseError as error:
            problems.append("driver.xml does not parse: %s" % error)
            continue
        if stamp["version"] != version:
            problems.append("driver.xml has the version %r, not %s" % (stamp["version"], version))
        if not same:
            problems.append("driver.xml differs from the stage beyond its <version> and <modified>")
    elif kind == "dev" and name == "driver.lua":
        if not data.startswith(source):
            problems.append("driver.lua is not the staged driver.lua with dp3's lines appended")
    elif data != source:
        problems.append("%s differs from the stage" % name)
    if kind == "release" and name.endswith((".lua", ".xml")):
        if OPENS_WINDOW.search(data):
            problems.append("%s opens the Lua command window (AllowExecute(true) or gIsDevelopmentVersionOfDriver)" % name)
        if b"DEV-ONLY" in data:
            problems.append("%s carries a DEV-ONLY marker" % name)
if problems:
    sys.exit("%s:\n  %s" % (os.path.basename(package), "\n  ".join(problems)))
PY
}

# Stages and packs one driver in build/stage/<driver>/ into build/<driver>.c4z. The drivers share
# nothing but their inputs, so they build at the same time (#183).
build_driver() {
	local driver="$1" stage="$stage_root/$1" item doc manifest entry name
	local -a found
	cp -R "$ROOT/src/$driver" "$stage"
	cp -R "$ROOT/src/common" "$stage/common"
	if [[ "$dev_build" == yes ]]; then
		# What common/devloop.lua checks every bundle and command against.
		# printf is a builtin, so the key is on no command line.
		(umask 077 && printf 'return "%s"\n' "$dev_key" > "$stage/common/devkey.lua")
	else
		# Release builds: no dev loop, no dev key, no development commands,
		# none of the DEV-ONLY properties and actions.
		find "$stage" -depth \( "${dev_only_find[@]}" \) -exec rm -rf -- {} +
		while IFS= read -r -d '' item; do
			awk '/<!-- DEV-ONLY BEGIN/ { skip = 1 } !skip { print } /<!-- DEV-ONLY END -->/ { skip = 0 }' \
				"$item" > "$item.release" && mv "$item.release" "$item"
		done < <(find "$stage" -name '*.xml' \( -path "$stage/driver.xml" -o -exec grep -q '<!-- DEV-ONLY BEGIN' {} \; \) -print0)
		mapfile -t found < <(find "$stage" \( "${dev_only_find[@]}" \) -printf '%P\n' | sort)
		if [[ ${#found[@]} -eq 0 ]]; then
			mapfile -t found < <(grep -rl --include='*.lua' --include='*.xml' -e 'DEV-ONLY' "$stage" | sort)
			if [[ ${#found[@]} -gt 0 ]]; then
				found=("a DEV-ONLY marker in ${found[0]#"$stage"/}")
			fi
		fi
		if [[ ${#found[@]} -gt 0 ]]; then
			echo "release build still carries development items in $driver (${found[0]})" >&2
			exit 1
		fi
	fi
	# The changelog replaces the marker line in the staged manual only; src/
	# keeps the marker. A manual without the marker fails the build.
	doc="$stage/www/documentation.html"
	if [[ "$(grep -c '^<!-- CHANGELOG -->$' "$doc")" != 1 ]]; then
		echo "$doc: needs exactly one <!-- CHANGELOG --> line (docs/changelog-design.md)" >&2
		exit 1
	fi
	python3 -I - "$doc" "$changelog_html" <<'PY'
import sys
doc, fragment = sys.argv[1], sys.argv[2]
with open(doc, encoding="utf-8") as f:
    text = f.read()
with open(fragment, encoding="utf-8") as f:
    html = f.read().rstrip("\n")
with open(doc, "w", encoding="utf-8") as f:
    f.write(text.replace("<!-- CHANGELOG -->", html, 1))
PY
	# Apache 2.0 §4: the license and notice travel with every package.
	cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$stage/"
	# The drivers' own copy of the version (common/device.lua falls back to
	# it): Director's answer can be empty at a device's first init, which the
	# Hue project measured (its docs/status.md, 2026-10-24).
	printf 'return "%s"\n' "$version" > "$stage/common/build_version.lua"

	# What is packed is the stage, regular files only.
	mapfile -t found < <(find "$stage" -type l -printf '%P\n' | sort)
	if [[ ${#found[@]} -gt 0 ]]; then
		echo "build.sh: ${found[0]} in the stage of $driver is a symbolic link; a package carries regular files only" >&2
		exit 1
	fi

	# dp3 only stamps <version>/<modified> when building from a manifest, so
	# generate one listing everything staged (directories recursively).
	manifest="$stage/$driver.c4zproj"
	{
		echo "<Driver type=\"c4z\" name=\"$driver\" squishLua=\"false\">"
		echo "<Items>"
		for entry in "$stage"/*; do
			name="${entry##*/}"
			[[ "$name" == "$driver.c4zproj" ]] && continue
			if [[ -d "$entry" ]]; then
				echo "	<Item type=\"dir\" name=\"$name\" recurse=\"true\"/>"
			else
				echo "	<Item type=\"file\" name=\"$name\"/>"
			fi
		done
		echo "</Items>"
		echo "</Driver>"
	} > "$manifest"

	rm -f "$ROOT/build/$driver.c4z"
	python3 "$DP3" --driver-version "$version" --update-modified "${extra_args[@]}" \
		"$stage" "$ROOT/build" "$driver.c4zproj" >/dev/null

	if [[ ! -f "$ROOT/build/$driver.c4z" ]]; then
		echo "dp3 did not produce build/$driver.c4z" >&2
		exit 1
	fi
	if [[ "$dev_build" == yes ]]; then
		# The package carries the key: as secret as the key file.
		chmod 600 "$ROOT/build/$driver.c4z"
		check_package dev "$ROOT/build/$driver.c4z" "$stage" "$version"
		rm -f "$stage/common/devkey.lua"
		echo "built build/$driver.c4z (version $version, DEV build, carries the dev key)"
	else
		check_package release "$ROOT/build/$driver.c4z" "$stage" "$version"
		echo "built build/$driver.c4z (version $version)"
	fi
}

# Every driver at once (at most JOBS at a time, default nproc; JOBS=1 builds one after the other),
# each one's output kept apart and printed in the order of DRIVERS. As when they were built in turn,
# the first driver that fails ends the build after its own messages, with its exit status.
jobs="${JOBS:-$(nproc)}"
if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
	echo "build.sh: JOBS must be a positive integer, not '$jobs'" >&2
	exit 2
fi
pids=()
statuses=()
waited=0
for index in "${!DRIVERS[@]}"; do
	if ((index - waited >= jobs)); then
		wait "${pids[$waited]}" && statuses[waited]=0 || statuses[waited]=$?
		waited=$((waited + 1))
	fi
	build_driver "${DRIVERS[$index]}" > "$logs/$index.out" 2> "$logs/$index.err" &
	pids+=($!)
done
while ((waited < ${#DRIVERS[@]})); do
	wait "${pids[$waited]}" && statuses[waited]=0 || statuses[waited]=$?
	waited=$((waited + 1))
done
for index in "${!DRIVERS[@]}"; do
	cat "$logs/$index.out"
	cat "$logs/$index.err" >&2
	if [[ ${statuses[$index]} -ne 0 ]]; then
		exit "${statuses[$index]}"
	fi
done

# build/manifest.json: what this build is, for the release assets and for
# tools/deploy.py (docs/cicd-gitops-design.md, section 5.2). The tag is the
# exact release tag on HEAD, or null for a build between releases.
tag="$release_tag"
commit="$(git -C "$ROOT" rev-parse HEAD)"
dev_json=false
[[ "$dev_build" == yes ]] && dev_json=true
{
	echo "{"
	echo "  \"schema\": 1,"
	if [[ -n "$tag" ]]; then
		echo "  \"tag\": \"$tag\","
		echo "  \"version\": \"${tag#v}\","
	else
		echo "  \"tag\": null,"
		echo "  \"version\": null,"
	fi
	echo "  \"build\": $version,"
	echo "  \"commit\": \"$commit\","
	echo "  \"built_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
	echo "  \"dev\": $dev_json,"
	echo "  \"packages\": {"
	last="${DRIVERS[${#DRIVERS[@]}-1]}"
	for driver in "${DRIVERS[@]}"; do
		sum="$(sha256sum "$ROOT/build/$driver.c4z" | cut -d' ' -f1)"
		bytes="$(stat -c %s "$ROOT/build/$driver.c4z")"
		sep=","
		[[ "$driver" == "$last" ]] && sep=""
		echo "    \"$driver.c4z\": {\"sha256\": \"$sum\", \"bytes\": $bytes}$sep"
	done
	echo "  }"
	echo "}"
} > "$ROOT/build/manifest.json"
python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$ROOT/build/manifest.json"
echo "wrote build/manifest.json (build $version${tag:+, $tag})"

# --serve (and --dev): each package alone in a directory with a random name of
# 128 bits under build/serve/, whose empty index.html keeps the HTTP server from
# listing it. Directories 0700; a dev package stays 0600.
if [[ "$serve" == yes ]]; then
	serve_root="$ROOT/build/serve"
	(umask 077 && mkdir -p "$serve_root" && : > "$serve_root/index.html")
	for driver in "${DRIVERS[@]}"; do
		token="$(python3 -I -c 'import secrets; print(secrets.token_hex(16))')"
		(umask 077 && mkdir "$serve_root/$token" && cp "$ROOT/build/$driver.c4z" "$serve_root/$token/")
		echo "serve build/$driver.c4z at the URL path /$token/$driver.c4z"
	done
	echo "serve with: python3 -I -m http.server 8091 --bind <this VM's LAN address> --directory build/serve" \
		"(for the download only; stop it afterwards)"
fi
