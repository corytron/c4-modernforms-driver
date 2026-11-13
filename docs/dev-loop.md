# Dev loop: pushing code to a live driver without Composer

The dev build of a driver fetches its own Lua from a server on the
development VM, reloads itself when the code changes, runs actions queued
on the VM, and ships its log and properties back. After one Composer
install of a dev build, only `driver.xml` changes need Composer again (a
`<capabilities>` change also needs the owner's controller reboot from System
Manager, [`composer-remote.md`](composer-remote.md)).

Dev builds only: [`tools/build.sh`](../tools/build.sh) `--dev` packs
`src/common/devloop.lua` into every package with the dev key baked in as
`common/devkey.lua`, keeps the DEV-ONLY block of each `driver.xml` (the
`Dev Server` property) and allows Composer's Lua command window (dp3
`--allowexecute`); a release build carries none of it. The controller acts
only on what that key signed ([Security](#security)). The loop is inert
until a device's `Dev Server` property holds a `host:port`.

The loop is the Hue project's (corytron/c4-hue-driver), which ran it on
this house's controller through October 2026; facts marked *[Hue project,
hardware]* were measured there on OS 3.4.2 and are assumed for the house's
OS 3.4.3 until this project's first dev install shows them again.

**Current state (2026-11-13): not in use.** The house runs release builds
(`deploy/house.yaml` names the release: 1.9, build 220). A dev build of this
project ran there once, build 144 for the Breeze LED animation (#137),
between the 1.3 install of 2026-11-08 and the 1.4 install of 2026-11-09,
which ended it. [`status.md`](status.md) is the authority on what runs on the house. A
release build carries no `common/devloop.lua`, so once releases are
installed nothing on the controller polls this VM and no property can turn
the loop on.

To use the loop:

1. Start [`tools/devserver.py`](../tools/devserver.py) in the background on
   the VM (`tools/devserver.py --quiet`). It listens on this VM's LAN
   address, port 8081 (the Hue project's server keeps 8080, so both can
   run), creates the dev key on its first run, and prints the `Dev Server`
   value: `listening on http://192.0.2.7:8081 (Dev Server = 192.0.2.7:8081)`.
2. Build with `tools/build.sh --dev` from a commit after the installed one
   (the version is the commit count, so Composer sees an update). The
   packages carry the key ([The dev key](#the-dev-key)).
3. Install the dev `.c4z` through the Windows session the way `CLAUDE.md`
   (Deploy) describes an install that bypasses
   [`tools/deploy.py`](../tools/deploy.py): served from `build/release/`
   with `python3 -I -m http.server 8091 --bind 0.0.0.0 --directory
   build/release` for the duration of the download only, briefed with
   their sha256, recorded afterwards with `python3 tools/deploy.py record
   --no-manifest ...`. Update in place, never delete and re-add. A dev
   package is as secret as the key it carries.
4. Have the Windows session set `Dev Server` on **one** device, the one
   under test, to the value the server printed (a property edit counts only
   once the row's Set button is clicked, [`composer-remote.md`](composer-remote.md)).
   Every device whose `Dev Server` names the server polls it and runs every
   queued command; the server warns when a second one reports
   ([The polling device](#the-polling-device)).
5. `tools/devctl.py status` shows the tree running and the dev key
   matching.

`--dev` changes the Lua that is packed and keeps the DEV-ONLY rows that a
release strips; neither touches `<capabilities>`, so no reboot is needed
unless the commit itself changes them. Whether Director gives a row that
a release dropped and a dev build declares again its old value back is not
recorded: after a dev install, check that `Dev Server` holds the server's
`host:port`. Leaving the loop is a release install,
[Leaving the loop](#leaving-the-loop-production).

## Pieces

- [`tools/devserver.py`](../tools/devserver.py): the server on the VM, plain
  HTTP on one address (`--bind`, by default the VM's LAN address; every
  address only with `--bind 0.0.0.0`) and one port (`--port`, default
  8081). It serves one tree per `src/<driver>/driver.xml` it finds at
  start, named after the directory (today `modernforms_fan` and
  `modernforms_breeze_fan`; only the first has the hook, so only a fan
  device polls, [The driver hook](#the-driver-hook)): that
  directory's `.lua` and `.xml` files under the paths its `.c4z` uses, with
  `src/common/*.lua` mounted as `common/`. A file named `devkey.lua`,
  hidden files and everything else (the manual, icons) are never served; a
  module the bundle lacks, such as `common/build_version.lua`, still loads
  from the installed package. A new driver directory needs a server
  restart. The server signs every bundle and command list with the dev key
  and wants the admin token on `/status` and `/admin/*`.
- [`tools/devctl.py`](../tools/devctl.py): the developer's CLI: queue
  actions and property changes, force a reload, wait for a queued command,
  pin or unpin the trees, show status, tail the log. It derives the admin
  token from the dev key file and finds the server through
  `build/dev/server.json`; `log` reads `build/dev/driver.log` directly and
  needs neither.
- [`tools/regress.sh`](../tools/regress.sh): the regression pass, which presses
  the fan's links and moves its light on the house fan and puts the state back
  ([Regression pass](#regression-pass)).
- [`src/common/devloop.lua`](../src/common/devloop.lua): the driver side, in
  every dev package; [`tests/spec/devloop_spec.lua`](../tests/spec/devloop_spec.lua)
  pins it, and [`tools/tests/test_devserver.py`](../tools/tests/test_devserver.py)
  and [`tools/tests/test_devctl.py`](../tools/tests/test_devctl.py) the VM
  side. Both sides pin the same signing vectors, so they cannot drift
  apart.
- The driver's hook: a few lines of its `driver.lua` and the `Dev Server`
  row of its `driver.xml` ([The driver hook](#the-driver-hook)).
- The dev key: `~/.config/c4-modernforms-driver/devkey` on the VM, outside
  the repository, and `common/devkey.lua` inside each dev package
  ([The dev key](#the-dev-key)).

Files the server writes live under `build/dev/` (gitignored):
`driver.log` (shipped log lines), `reports.jsonl` (one JSON object per
report), `commands.json` (the queue), `server.json` (the address `devctl.py`
uses, while the server runs).

## Wire protocol

All JSON unless noted; only the driver ever initiates. `<tree>` is a tree
name: letters, digits and `_`, the name of its directory under `src/` and
of its package without `.c4z`.

`GET /manifest?tree=<tree>` →
`{"version": "<sha1 over sorted path+contents>", "tree": "<tree>", "files": ["common/log.lua", "driver.lua", ...], "server_time": <unix seconds>}`.
A tree the server does not serve is a 400. A request that names no tree
gets the only tree while the server serves exactly one, and a 400 while it
serves several. Unsigned: a new version only makes the driver fetch a
bundle, which must verify.

`GET /bundle?tree=<tree>` → a signed envelope (not JSON as a whole):
`<mac>\n<payload>`, where `<payload>` is the JSON
`{"version": "...", "tree": "<tree>", "files": {"driver.lua": "<source>", "fan/transport.lua": "<source>", ...}}`
in ASCII and `<mac>` the 64-hex-character MAC (label `bundle`) over the
payload's exact bytes ([What the controller checks](#what-the-controller-checks)).

`GET /file?path=<published path>[&tree=<tree>]` → `text/plain` source, 404
when the path is not a published one (`../`, absolute paths, a key file).

`GET /commands?after=<id>&nonce=<16-64 lowercase hex>` → a signed envelope
(label `commands`) whose payload is
`{"nonce": "<as sent>", "commands": [{"id": 7, "type": "execute", "command": "Some Action", "params": {"Key": "Value"}}, {"id": 8, "type": "set_property", "name": "Debug Mode", "value": "On"}, {"id": 9, "type": "reload"}]}`.
A missing or malformed `nonce` is a 400, and so is an `after` that is not
an integer. Ids increase monotonically across server restarts (persisted in
`commands.json`). A command stays in the queue until a driver reports
`command_done` for it, then moves to a bounded done list; so a driver that
starts fresh and asks `after=0` receives only unacknowledged commands.
`execute` runs the driver's development command of that name when it has
one (the table it hands to `devloop.set_signed_commands`, named the way
`common/dispatch.lua` names commands, so `"Dev Request"` finds
`Dev_Request` and `LUA_ACTION` is unwrapped to its `ACTION`), else the
driver's `ExecuteCommand(command, params)`, which serves Composer's actions;
`set_property` does `C4:UpdateProperty(name, value)`, sets
`Properties[name]` as Director does, then calls `OnPropertyChanged(name)`;
`reload` forgets refused versions and runs the reload sequence again on the
current version.

`POST /log` body `{"version": "<running version>", "tree": "<tree>", "lines": [{"t": <ms since epoch>, "line": "..."}]}` → 204.
The server appends `HH:MM:SS.mmm <line>` to `driver.log` and echoes it to
stdout. `lines` may also come as the object Director's `C4:JsonEncode`
makes of a Lua array (string keys); the server takes both.

`POST /report` body
`{"version": "...", "tree": "<tree>", "device_id": <id>, "forwarded": {"<tree>": "<version>"}, "event": "<see below>", "command_id": <id>, "properties": {...}, "error": "<text>", "sandbox": {...}, "elapsed_ms": <ms>, "key_fingerprint": "<16 hex>", "refused_tree": "<tree>", "refused_version": "..."}` → 204.
Fields without a value are left out: `version` until the first reload,
`tree` while the device cannot tell its own, `forwarded` until a polling
device forwarded a tree, `key_fingerprint` in a package without a key.
Events: `startup` (the loop started; `sandbox` holds `_VERSION`,
`jit.version` if any, the `type()` of `jit`, `loadstring`, `load`,
`setfenv`, `package`, `package.loaders`, `C4` and `bit`, the HMAC in use
(`hmac`: `C4:HMAC` or `Lua (<why>)`), the driver version from
`C4:GetDriverConfigInfo("version")` and the raw answer of
`C4:GetDriverFileName()` as `driver_file`), `reload` (new code running; its
`error` carries the text of an `OnDriverDestroyed` that failed),
`reload_failed` (error text; the old code may be half torn down),
`refused` (a bundle did not verify: `refused_tree`, `refused_version`,
`error`; once per version), `command_done` (with `command_id`, `elapsed_ms`
and, when the command failed, its redacted `error`), `heartbeat` (at the
end of a tick when no report went out for 30 s, properties only; also right
after a new version of a forwarded tree was forwarded, so `/status` catches
up at once).

`GET /status` (admin token) →
`{"trees": {"<tree>": {"local_version": ..., "live_version": ..., "pinned": <version or null>, "running_version": ..., "forwarded_version": ...}}, "device_id": <the latest reporter>, "devices": {"<id>": {"tree": ..., "last_seen": <unix>}}, "last_seen": <unix>, "server_time": <unix>, "last_event": ..., "last_error": ..., "properties": {...}, "pending_commands": [...], "done_commands": [ids], "last_done_id": N, "key_fingerprint": "<the server's>", "driver_key_fingerprint": "<last reported, or null>", "driver_reported_key": <whether any report said yet>}`.
`local_version` is what is served (the pinned version while pinned),
`live_version` what the working tree is now. `running_version` is what the
devices polling for a tree last reported running, `forwarded_version` what
a polling device last reported forwarding; with several devices the last
report wins. `last_seen` is bumped by any driver request. Times are unix
seconds as floats.

`POST /admin/enqueue` (admin token) body `{"type": "execute"|"set_property"|"reload", ...fields as above}` → `{"id": N}`.
`POST /admin/pin[?tree=<tree>]` and `POST /admin/unpin[?tree=<tree>]`
(admin token) → `{"pinned": {"<tree>": <version or null>}}`; every tree
when none is named. Used by `devctl.py`; the driver never calls them.
Without the token, or with a wrong one: 401.

## The driver hook

What a driver does to have the loop, the shape of the Hue Bridge driver's
hook; `src/modernforms_fan/driver.lua` and its `driver.xml` have it:

- `driver.xml` declares a `Dev Server` property (STRING, empty default)
  between a `<!-- DEV-ONLY BEGIN ... -->` line and a `<!-- DEV-ONLY END -->`
  line, which a release build strips (`tools/build.sh`).
- `driver.lua` requires the loop guarded:
  `local devloop_ok, devloop = pcall(require, "common.devloop")`. A release
  build has no such module; the error then reads "not found" under busted
  and "An unknown error occurred" on the controller *[Hue project,
  hardware]*, and anything else is printed as an `[ERROR]` line, since the
  loop is how the controller gets tested. `devloop` is nil from there on.
- With the module, it registers the `Dev_Server` property handler in
  `common/dispatch`: an empty value calls `devloop.stop()`; a `host:port`
  calls `devloop.start(host)`, but only once late init is done (the
  property replay at late init reaches the handler before the driver is
  up).
- At the very end of `OnDriverLateInit` it calls `devloop.start(host)` when
  `Properties["Dev Server"]` holds one, so a reload pushed through the loop
  sees a fully initialised driver.
- A driver with development-only commands hands them over with
  `devloop.set_signed_commands({ Dev_Fan_State = fn, ... })` at every load of
  its `driver.lua` (a reload's included), never into its dispatch table
  ([Development commands](#development-commands)); a driver that holds a
  secret (a key, a token) installs a redactor with
  `devloop.set_redactor(fn)` the same way. The Modern Forms Fan driver has
  both (`fan/devcmds.lua`); the Breeze fan driver has no hook at all (no
  `Dev Server` row, no `require` of the loop).
- `OnDriverDestroyed` cancels the driver's own timers: the reload calls it
  before it loads the new code, while the loop's own state outlives the
  reload.

A driver whose devices get child devices of another driver bound to them
would also list those trees in `devloop.TREES` before `devloop.start`, and
the children would register `devloop.reload_handler` as `DEV_RELOAD` and
install `devloop.forward_logs` ([Forwarded trees](#forwarded-trees)); the
polling driver would then register a `DEV_LOG` handler that prints each line
under its sender's name. Nothing in this project does yet: the Breeze fan
(since 1.3) is bound to the fan device on binding 400, but is not
forwarded.

## Driver-side behaviour

### The polling device

- `devloop.start(host_port)` is called at the end of the driver's late init
  in a dev build when `Dev Server` holds a value, and again whenever the
  row changes after late init; an emptied row stops the loop. Calling it
  again with the same host is a no-op; with a different host it restarts;
  `devloop.stop()` stops. A package without a dev key still starts (and
  says once that it will refuse every bundle and command), so the log and
  the reports still reach the server.
- The device polls for its own tree, the one its driver file is named
  after (`C4:GetDriverFileName()`, available from OS 3.3.0 [verified: API
  docs, `22_miscellaneous/_13.5-GetDriverFileName`]; its exact answer on
  the controller is assumed to be the file name, and the startup report's
  `sandbox.driver_file` shows it). A device whose file name names no tree
  asks without one and takes the tree the server names, which the server
  answers only while it serves exactly one; otherwise it says once that it
  is not updated, and still runs the commands. Every report names the
  device (`C4:GetDeviceID()`, read at start, never during `OnDriverInit`
  [verified: API docs, `22_miscellaneous/_11-GetDeviceID`]) and its tree.
- **One device at a time.** Every device whose `Dev Server` names the
  server polls it, reloads itself and runs every queued command, and
  `/status` shows whichever reported last. The server warns once per extra
  device (`WARNING device 16 reports here as well as device(s) 15: ...`),
  `devctl.py status` calls it out on its `device` row, and
  `tools/regress.sh` fails it. Empty `Dev Server` on all but the device
  under test.
- A command that stops or moves the loop reports first. `devctl.py set
  "Dev Server" ""`, or another `host:port`, reaches the property handler,
  which calls `devloop.stop()` (or `devloop.start(host)`) while the command
  runs. During an `execute` or `set_property` command both only note where
  the loop should end up (the last call wins; the host it already polls
  cancels a stop); once the command is done its `command_done` report
  starts towards the server the command came from, and then the loop stops
  or moves. The rest of that command list stays queued on that server for
  the loop's next start there, and nothing more of that tick goes to it: no
  log flush, no heartbeat (the lines still buffered leave with the loop's
  next tick, to whichever server it then polls).
- State lives in a global (`_G.__DEVLOOP`) so a reload cannot lose the
  loop, and `package.loaded["common.devloop"]` is never cleared by a
  reload. The dev key is not in that global: it lives in a local of the
  module.
- A repeating `C4:SetTimer` (3000 ms) drives everything. Each tick: at most
  one chain in flight; `GET /manifest?tree=<own>` and, if the version
  differs from the running one, `GET /bundle?tree=<own>`, verify, and
  reload; then each forwarded tree, if any ([Forwarded trees](#forwarded-trees));
  then `GET /commands?after=<last id>&nonce=<fresh>`, verify, and run each
  command in order, reporting `command_done` after each with a properties
  snapshot; then flush the log buffer with `POST /log`; then a heartbeat if
  one is due. A tick that finds the previous chain still in flight is
  skipped, and after ten such ticks that chain is abandoned (its callbacks
  are dropped). No answer at all, or a server error, is an unreachable
  server, said once per change, and ends the tick; a server that answers
  without the device's tree (400) is said once, and the tick goes on to the
  commands and the log. Never start a `C4:url` transfer from inside
  another transfer's `OnHeaders` or `OnBodyChunk` callback (Director fails
  it with curl error 2 *[Hue project, hardware]*); timers and `OnDone`
  callbacks are safe, and every step of the chain starts from the previous
  one's `OnDone`.
- A bundle that does not verify, or is signed for another tree, is refused
  (`devloop: modernforms_fan bundle <version> refused: signature mismatch`,
  once per version, and a `refused` report); nothing is torn down. That
  version is fetched again at most every 60 s, silently; a `reload` command
  forgets the refusals at once.
- A command list that does not verify, or answers another nonce, runs
  nothing (`devloop: commands refused: ...`, once per streak). A command
  whose id is not above the last one run is skipped.
- Reload sequence: `pcall(OnDriverDestroyed)`; clear every `package.loaded`
  entry the driver brought: `common.*` except `common.devloop`, and every
  module under a top-level directory of the old or the new bundle
  (`fan/transport.lua` makes every `fan.*` module the driver's) or named after
  one of its top-level files; modules no bundle brought, the runtime's and
  any library's, stay. Then install (or replace) a loader at
  `package.loaders[1]` that serves modules from the bundle (`a.b` →
  `a/b.lua`; what the bundle lacks falls through to the package); run
  `loadstring(bundle["driver.lua"], "=driver.lua")`; then
  `OnDriverInit("DIT_UPDATING")` and `OnDriverLateInit("DIT_UPDATING")`.
  Every step is `pcall`ed. An `OnDriverDestroyed` that fails is said and
  the reload goes on (the `reload` report carries its text); any later
  failure posts `reload_failed` and the loop keeps polling. The version is
  recorded before anything can fail, so a failed version is not loaded
  again: the next pushed version, or a `reload` command, retries. Only a
  verified bundle ever reaches this sequence.
- Signed commands: `devloop.execute(command, params)` runs a verified
  `execute` command through the table the driver handed to
  `devloop.set_signed_commands` first and through the global
  `ExecuteCommand` otherwise, looking both up as the command runs. A
  reload that fails before the driver hands its table over keeps the
  previous one, as it keeps the previous `ExecuteCommand`. A handler that
  raises is said (`devloop: signed command <name> failed: <error>`) and
  reported in `command_done`; the next command runs.
- Log capture: `_G.print` is wrapped once (keeping the original for
  Composer), so everything the driver prints is buffered and shipped; at
  most 500 lines are kept, dropping the oldest. The loop's own messages use
  the original print and are buffered too.
- Redaction: every line passes the redactor the driver installed with
  `devloop.set_redactor(fn)` (`fn(line)` returns what of the line may leave
  the controller; nil keeps nothing) when it is buffered and again when it
  is shipped, so a line buffered before the redactor knew the secret leaves
  without it too. A redactor that raises, or answers anything but a string
  or nil, withholds the line (`devloop: a log line was withheld (the
  redactor failed on it)` stands in its place), and so does a line the
  redactor prints itself. The `error` text of a report passes the redactor
  as well. The redactor is kept across a reload until the new code installs
  its own. Composer's own output (the original print) is not redacted.
- Properties snapshot: a copy of `Properties`; when `C4` is a Lua table,
  `C4.UpdateProperty` is also wrapped once to shadow the values the driver
  sets itself (the startup report's `sandbox.C4` says which applies).
- Nothing in the loop ever prints or reports the dev key or a MAC it
  computed to check one it received.

### Forwarded trees

Dormant: `devloop.TREES` is empty and the fan driver polls for itself; the
Breeze fan driver, bound to it since 1.3, has no hook and is not forwarded,
so a change under `src/modernforms_breeze_fan/` reaches the controller only
with a `.c4z` install. The Hue project's bridge used it to update the light and scene
devices bound to it, which have no `Dev Server` of their own. Should the v1
contract bind a second driver's devices to the fan driver's, a polling
device lists that driver's tree in `devloop.TREES` (and the binding in
`devloop.FORWARD_BINDING`, 1 by default), and then:

- Each tick it also asks `GET /manifest?tree=<t>` for each listed tree
  (never its own), fetches and verifies the bundle once per new version,
  and keeps it (payload and MAC as the server sent them) with, per bound
  device, the version that device last received.
- It reads `C4:GetBoundConsumerDevices(<own id>, FORWARD_BINDING)` every
  tick, learns each new id's `driverFileName` once with one `C4:GetDevices`
  (`DeviceIds` a comma-separated string [verified: API docs,
  `22_miscellaneous/_9-GetDevices`; Hue project, hardware]), and sends the
  bundle to each bound device whose driver file is `<t>.c4z` and that lacks
  the version, as
  `C4:SendToDevice(id, "DEV_RELOAD", { tree = ..., version = ..., bundle = <signed payload>, mac = <its MAC> }, false, false)`.
  The payload is the server's text, unchanged, so the device checks the
  very bytes the server signed. The two trailing `false`s are
  `allowEmptyValues` and `logCommand` [verified: API docs,
  `32_serial_network_device/_19-SendToDevice`]: with logging on, Director
  would write the whole bundle to its log on every forward. A device whose
  driver file cannot be read gets nothing; a device bound later gets the
  held version on the next tick; one unbound and bound again is new. A new
  version makes a heartbeat due at once, so `/status` shows it as
  `forwarded_version`.
- On the receiving device, `devloop.apply_forwarded(params)` (behind the
  `DEV_RELOAD` handler `devloop.reload_handler(log, tree)` builds) skips a
  bundle whose `tree` hint is another driver's, refuses everything while
  the device runs the loop itself, verifies the payload against the MAC
  with the device's own baked key, and loads it only when the signed tree
  is the device's own (a device that cannot tell its tree loads nothing);
  then the same reload sequence runs. The outcome goes through the
  device's original print (`devloop: light reload complete: version <v>`,
  `... refused: signature mismatch`), and `devloop.forward_logs` sends
  every non-debug line the device logs to the polling device as `DEV_LOG`
  `{ source, line }`.

## Developer workflow

```
tools/devserver.py --quiet         # once, in the background on the VM; prints its URL and the key fingerprint
tools/build.sh --dev               # dev .c4z files for the one-time Composer install (they carry the dev key)
tools/devctl.py status             # is the driver talking to us, which version, does the key match
# edit src/modernforms_fan or src/common, then wait ~3 s: the device reloads itself
tools/devctl.py run "Some Action" Key=Value   # prints the command id
tools/devctl.py wait 7 --timeout 120           # until command_done, then the properties it reported
tools/devctl.py set "Debug Mode" On
tools/devctl.py log -f
tools/devctl.py pin                  # serve src/ as it is now; later edits wait for the next pin or unpin
tools/devctl.py unpin                # back to live reloads
```

The server's first lines name the dev key's fingerprint (which
`tools/build.sh --dev` prints too), each tree it serves with its version,
and where it listens, the last part being the `Dev Server` value.
`devctl.py` finds the server through `build/dev/server.json`; `--server
URL` overrides it.

`devctl.py status` shows every tree, what the devices run against what is
local, then the key, the device and the properties of the latest report:

```
tree modernforms_fan
  running              1f3a9c0b2d4e  (matches local)
  local                1f3a9c0b2d4e
dev_key                matches the server's (fingerprint 3f9a0c1d2e4b5a6c)
device                 15 (modernforms_fan)
last_seen              2s ago
last_event             heartbeat
pending                0 command(s)
properties:
  Debug Mode     = Off
  Dev Server     = 192.0.2.7:8081
  Driver Version = 12
```

A tree reads `DIFFERS from local; a reload is due` right after an edit,
`no device has reported this tree yet` before the first report, and has a
`pinned` row while pinned. `dev_key` reads `DIFFERS` when the installed dev
build was made with another key, and `DRIVER HAS NONE` when it carries no
key: the controller then refuses everything the server signs. The `device`
row says `MORE THAN ONE device polls this server` when it is so.

Pin while several agents edit `src/` at once: the controller then only
reloads to states the coordinator has checked (`tools/check.sh --only
lua-lint lua-test` green), each pushed by a fresh `pin`.

`run`, `set` and `reload` print the bare id, so `devctl.py wait
$(devctl.py set "Debug Mode" Off)` works; `wait` gives up after `--timeout`
seconds (default 60) with exit code 2 and says what it knows: still pending
or never queued, no driver in touch for a while, and for a `Dev Server`
change what a lost report means ([Gotchas](#gotchas-learned-on-hardware)).
`pin` and `unpin` take `--tree <name>` (default: every tree); `log` takes
`-n`/`--lines` (default 50), `-f`/`--follow` and `--file`. The server takes
`--quiet` (no connection and request lines, no heartbeat summaries),
`--port`, `--bind`, `--key-file`, `--state-dir` and `--root`, and
`--ensure-key` ([The dev key](#the-dev-key)); `devctl.py` takes `--server`,
`--key-file` and `--state-dir`. `C4_MF_DEVKEY_FILE` names another key file
for all three tools.

### Regression pass

[`tools/regress.sh`](../tools/regress.sh) `[--fan [--default-on N]] [--server URL] [--key-file FILE] [--state-dir DIR]`
is the dev-loop regression pass of [`release-checklist.md`](release-checklist.md), through `devctl.py`.
Its generic part checks the loop itself and is read-only:

1. status: the server answers, a device polled it within the last 10 s,
   its dev key is the server's, exactly one device polls, and every device
   runs the local tree (a reload due right after an edit gets 15 s to
   land);
2. a property read-back: `Debug Mode` set to the value it already has, a
   signed command that changes nothing, whose `command_done` report must
   bring that value back with a `Driver Version`;
3. the shipped log: no `[ERROR]`, Lua error, traceback, refusal or failed
   reload in its last 400 lines.

It exits with the number of failed checks, or 2 at once when `devctl.py
status` fails or an argument is wrong. Without `--fan` it creates, deletes
and changes nothing; every argument but `--fan` and `--default-on` goes to
each `devctl.py` call.

**`--fan`** adds the fan's own pass, F1 to F9 of [the v1 contract](v1-design.md#12-dev-loop-actions-and-toolsregresssh),
after the generic checks and only when they all passed. It moves the fan
and its light, so it is opt-in. It queues the signed development commands
of [`Dev Fan State`, `Dev Proxy` and `Dev Press`](#development-commands)
and reads every result back from the `Dev State` row:

| Step | Commands | Passes when |
| --- | --- | --- |
| F1 | `Dev Fan State` | `phase=online`, `busy=-`, the fan and the light known: this is the state F8 returns to |
| F2 | `Dev Proxy` 5001 `SET_SPEED` 1 to 6 | `fan=on/N`, `told.fan=N`, links 300 to 308 lit for speed N, and `notify.fan` one higher than the step before (the same when the speed did not change: one notification per real change) |
| F3 | `Dev Proxy` 5001 `SET_SPEED` 0 | `fan=off`, `told.fan=0`, link 300 lit and 301 to 308 dark |
| F4 | `Dev Press` 307 `tap` | the fan on at its preset (any speed from 1 to 6: the pass learns it here), links 307 and 308 and only that speed's link lit |
| F5 | `Dev Press` 308 `tap` `COUNT=3` `EVERY=150` | the preset plus three, wrapping past 6, `notify.fan` one higher (the burst coalesced into one report). Since 1.1 (#77) the driver's Fan Cycle stops at 6 instead, and `tools/regress.sh` still expects the wrap, so F5 fails from a preset of 4 or more until the script is changed (the house's preset is 3) |
| F6 | `Dev Proxy` 5002 `SET_BRIGHTNESS_TARGET` 30, 70, then 0 | `light=on/30`, `on/70`, `off`; `told.light` the same; `changing=0` after each |
| F7 | `Dev Press` 200 `tap` | `light=on/N`, `told.light=N`, `changing=0`; N is Default On Brightness, which `--default-on N` pins exactly and which otherwise may be any level (one equal to the 70 F6 left cannot be told from the kept level, and the pass says so) |
| F8 | `Dev Proxy` back to F1's state | F1's `fan=` and `light=` again |
| F9 | the shipped log since F1 | no `[ERROR]`, "attempt to", traceback, refusal or failed signed command line |

Every step also wants `busy=-` and what is shown equal to what is confirmed
(`shown.fan` and `fan`, `shown.light` and `light`), since nothing is left
wanted or in flight a poll later. A fan without a light kit (`light=-`)
skips F6 and F7. The pass assumes the default `Speed N Link Also Lit At`
(`No other speed`): with the house's two extra speeds set, F2 would find
two links lit at speeds 1 and 6.

- **One poll per step.** Each step is one batch: a `Dev Fan State` read,
  then the step's commands, then a wait for the last. The read comes
  first, so it shows what the step before left, one poll (3 s) after that
  step's commands ran, and the batch checks that step against it. A step
  costs one poll instead of two, so the 16 batches take about a minute (an
  estimate: the pass has not run on the house yet). A step that is still
  busy at its read has taken longer than a poll and fails, where the
  contract allows 5 s.
- **F5 depends on how fast the fan answers.** The three taps are 150 ms
  apart and coalesce into one report only while the cycle group is still
  busy when the next tap arrives, which holds as long as the fan takes
  longer than 150 ms to answer the first command (the contract's example
  line shows 310 ms). A fan that answers in about 100 ms reports twice, and
  F5 then fails on `notify.fan` alone, with the speed, `told.fan` and the
  links right.
- **It stops at the first step that does not read back as expected**,
  printing the step, what differed and the whole `Dev State` line. On a
  failed step, a dev loop that stops answering for 20 s, or an interrupt,
  it queues the commands that put the fan and the light back as F1 found
  them (not verified) and ends. The exit status is the number of failed
  checks, so at least 1 after a failure. A pass that fails at F1 has moved
  nothing.
- **What it leaves changed**: the light's remembered level (F6 and F7 set
  it, and F8 cannot restore it when the light started off, since `Dev State`
  does not show a level for an off light) and nothing else; the fan's preset,
  direction and every property stay as they were. While it runs, the
  proxies fire their events for each change (the fan's speed events, the
  light's), so Control4 programming bound to them runs as for any change.

### Leaving the loop (production)

A release build (`tools/build.sh` without `--dev`) ships no
`common/devloop.lua` and no key; the driver requires the loop with `pcall`,
so the same `driver.lua` starts without it and the device simply never
contacts this VM again. A production install is a GitHub release, never a
VM build. Before installing one: `devctl.py set "Debug Mode" Off` (the
property survives the update, and `deploy/house.yaml` wants it Off), then
the GitOps install of [`release-checklist.md`](release-checklist.md)
([`tools/deploy.py`](../tools/deploy.py) `start`, its brief to the Windows
session, `tools/deploy.py done`). `devctl.py status` then shows
`last_seen` growing; stop `devserver.py`. A release's `driver.xml` has no
DEV-ONLY block, so the `Dev Server` row leaves Composer.

## Security

Dev builds only. A release build carries no `common/devloop.lua` and no dev
key, and `tools/build.sh` refuses to package one that does. These are the
Hue project's rules, carried over whole.

The loop runs over plain HTTP on the LAN: anything on the LAN can read it,
and anything that can answer as the VM's address can alter it. Nothing on
the wire is secret ([What is left](#what-is-left)). What keeps the loop
from being remote code execution is that the controller acts only on what
the dev key signed, and the key never crosses the wire.

### The dev key

- 32 random bytes, written as 64 lowercase hex characters to
  `~/.config/c4-modernforms-driver/devkey` (under `$XDG_CONFIG_HOME` when
  that is set; `C4_MF_DEVKEY_FILE` or `--key-file` name another file),
  outside the repository, and never the Hue project's key file. The first
  `tools/devserver.py` or `tools/build.sh --dev` creates it, mode 0600 in a
  0700 directory; `tools/devserver.py --ensure-key` does only that and
  prints the path (stdout) and the fingerprint (stderr), which is how
  `tools/build.sh` gets it. A key file that group or others can read, or
  that is not 64 lowercase hex characters, is refused.
- `tools/build.sh --dev` bakes it into each dev package as
  `common/devkey.lua` (`return "<hex>"`), written into the stage only
  (umask 077) and deleted from it once packed (also when the build fails
  half-way); the dev `.c4z` files are written 0600. Every build refuses to
  run while a `src/common/devkey.lua` exists, and a release build refuses
  to package one, so the key is never served from, committed with or
  released in the source tree. `devserver.py` never serves a file of that
  name.
- On the controller, `common/devloop.lua` reads it once, at load, into a
  local of the module: never into `_G.__DEVLOOP`, a property, a report or a
  log line. A bundle that brings its own `common/devkey.lua` changes
  nothing: the loop keeps the key it was loaded with.
- Every MAC is HMAC-SHA256 keyed with those 64 characters (as ASCII), over
  `c4-mf-devloop/1\n<label>\n<data>`, as lowercase hex. The labels are
  `bundle`, `commands`, `admin-token`, `fingerprint` and `nonce`, so a MAC
  made for one purpose is never valid for another; the domain is this
  project's own, so nothing the Hue project's loop signed is valid here,
  whatever key signed it.
- The fingerprint, the first 16 hex characters of the `fingerprint` MAC of
  nothing, names a key without revealing it: `tools/build.sh --dev` and the
  server print it, the driver reports it (`key_fingerprint`), and the
  server warns at once when the driver's differs from its own
  (`devctl.py status`, row `dev_key`).
- The tools print the key file's path and the fingerprint, never the key.
  `tools/build.sh` handles the key with shell builtins only, so it is never
  on a command line.

### What the controller checks

- **Bundles.** `GET /bundle` answers `<mac>\n<payload>`, the MAC (label
  `bundle`) over the exact bytes of the JSON payload `{"version", "tree",
  "files"}`. The driver checks it before decoding anything, and the
  payload's `tree` must be the tree it asked for. A bundle that is
  unsigned, does not match or was signed for another tree is refused with
  one line and a `refused` report; nothing is torn down and the running
  code stays. Only a verified bundle ever reaches `loadstring`.
- **Commands.** Each `GET /commands` carries a fresh nonce, 32 hex
  characters derived with the key from a per-load value and a counter, so
  it never repeats, not even after a reboot. The answer is
  `<mac>\n<payload>` with the MAC (label `commands`) over `{"nonce",
  "commands"}`. The driver runs nothing from an answer that does not verify
  or carries another nonce, so a recorded answer cannot be replayed; within
  a load, a command id must also be above the last one run. Signed
  commands cover `set_property` (`Dev Server`, `Debug Mode`, ...) and
  Composer's actions alike, and they are the only way to a driver's
  development commands.
- **`DEV_RELOAD`** (forwarded trees, dormant). The polling device forwards
  a bundle unchanged: the signed payload and its MAC. The receiving device
  verifies them with its own baked key and loads only a payload signed for
  its own tree; a device that runs the loop itself refuses every
  `DEV_RELOAD`. A `DEV_RELOAD` from any other driver in the project, a
  polling device's own bundle replayed, or a bundle in an unsigned form is
  refused the same way, with the running code untouched.
- **Which HMAC.** `C4:HMAC("SHA256", key, data, { return_encoding = "HEX",
  key_encoding = "NONE", data_encoding = "NONE" })` [verified: API docs,
  `6_encryption/_10-HMAC` and `_8-GetSupportedDigests`, available from
  1.6.0; `22_miscellaneous/_25.2-SafeUsageTable` allows it before late
  init]. At first use the loop checks it against RFC 4231 test case 2 and
  falls back to the pure-Lua HMAC-SHA256 in `devloop.lua` when `C4:HMAC` is
  missing, raises or answers wrong (about 0.4 MB/s under PUC Lua 5.1 on the
  VM *[Hue project]*; the specs pin it to the RFC 4231 and FIPS 180
  vectors). On OS 3.4.2 `C4:HMAC` exists and passes that test *[Hue
  project, hardware]*; the startup report's `sandbox.hmac` says which one
  runs.
- A received MAC is compared over its full length, and the MAC the
  controller expected is never logged or reported: it would let whoever
  answers as the server sign a payload of their choosing.

### Development commands

- **Out of the dispatch table.** `ExecuteCommand` has no sender parameter
  [verified: API docs, `5_director_command/_1-ExecuteCommand`], so whatever
  sits in a driver's dispatch table, any driver in the project can run
  with `C4:SendToDevice`. A dev build adds to that table only what Composer
  itself sends: the DEV-ONLY rows and actions of `driver.xml` (today the
  `Dev Server` and `Dev State` rows). Anything that only development needs
  (a keypad press, a proxy command, a probe of a `C4` call) goes into the
  table the driver hands to `devloop.set_signed_commands`, which only a
  signed `execute` command reaches (`devctl.py run`). The Modern Forms Fan
  driver builds that table in `fan/devcmds.lua`, a file `tools/build.sh`
  leaves out of a release package (`DEV_ONLY_FILES`), and hands it over at
  every load of its `driver.lua` together with the redactor.
- **The commands** ([the v1 contract, section 12](v1-design.md#12-dev-loop-actions-and-toolsregresssh)),
  run as `devctl.py run "<name>" KEY=value ...`; the names are the ones
  `common/dispatch.lua` gives (`Dev Press` finds `Dev_Press`), the
  parameters arrive as strings:

  | Command | Parameters | Does |
  | --- | --- | --- |
  | `Dev Fan State` | none | writes the DEV-ONLY row `Dev State` (described below), which comes back in the `command_done` report that follows (`devctl.py wait` prints it), and logs the same line |
  | `Dev Press` | `LINK` 200 to 202, 300 to 308 or 311; `ACTION` `tap`, `push`, `click` or `release`; `COUNT` 1 to 100 (default 1); `EVERY` 10 to 60000 ms (default 300) | `ReceivedFromProxy(LINK, command)` with `DO_PUSH`, `DO_CLICK` or `DO_RELEASE`, as a keypad sends them, `COUNT` times, `EVERY` ms apart. A `tap` is a push and, 100 ms later, a click. The first message goes at once and the rest on the controller's own timers, so the spacing is not the loop's 3 s poll; timers still waiting are cancelled when the driver is destroyed |
  | `Dev Proxy` | `BINDING` 5001 or 5002; `COMMAND`; any other parameters | `ReceivedFromProxy(BINDING, COMMAND, params)` as the proxy would call it, the other parameters as the strings they came as (`SPEED=3`; `LIGHT_BRIGHTNESS_TARGET=70 RATE=0`) |
  | `Dev Names Plan` | `MODE` `guarded` (default) or `forced` | logs what Use Selected Fan (guarded) or Name Items After Fan (forced) would do to the two items' names (`would=`, the fan type, the ids, the live and target names, whether each is the driver's), and renames nothing ([`fan-name-design.md`](fan-name-design.md) 2.4, #37) |
  | `Dev Request` | `BODY` | one request through the model's `request`, which the driver wires in and which sends only while the fan is online and nothing else is due (otherwise: `not sent (busy)`): one of the two queries, or a body `wire.body` builds from the fields the driver writes (any key order or spacing; the bytes sent are `wire.body`'s). The answer is logged normalized, `Dev Request #41 command: 200 in 0.31 s: fan on/4 forward, light off/100`, with the client id as `...5301` and nothing else of the answer |
  | `Dev Search` | none | asks for one search window as soon as the 30 s floor allows, for the house checks of [`auto-discovery-design.md`](auto-discovery-design.md#9-checks-on-the-house-each-under-a-minute) (#102): logs `Dev Search: a window is asked for (search=due:N)`; the list and its `Found Fans:` log line follow by themselves, and nothing goes to Last Action |
  | `Dev Link` | `LINK` 300 to 308 or 311; `KIND` `colors` (`ON`, `OFF` default `000000`, `CURRENT` default `ON`, or `none` to leave it out), `state` (`STATE` true or false) or `flicker` (`COUNT`, `EVERY` as `Dev Press`) | raw keypad LED messages on one fan link, for the Breeze LED probes (#137, [`breeze-leds-design.md`](breeze-leds-design.md) section 6): `BUTTON_COLORS`, `MATCH_LED_STATE`, or `MATCH_LED_STATE` true and false in turn. The links' own bookkeeping is not told: set `Speed LED Colors` again afterwards |
  | `Dev Vars` | `LINK` (a Button Link) or `DEVICE` (a device id) | logs every variable (`C4:GetDeviceVariables`) of each device bound to `LINK`, or of `DEVICE`; reads only (#137) |
  | `Dev Light Steps` | `FROM`, `TO` (0 to 100); `STEP` (1 to 50 levels a request) or `DURATION` (500 to 20000 ms); `EVERY` (0 to 2000 ms), `GAP` (0 to 250 ms, this run only), `BACK` (yes or no), `REPEAT` (1 to 4) | steps the light from `FROM` to `TO` through the model's slot, one log line per answer and a summary, for the fade probes of [`light-fades-design.md`](light-fades-design.md) (#141); stops at a failure, an answer slower than 2 s, an unexpected `lightOn`, 60 s or 150 requests, then puts the light and the gap back |

  A parameter outside what a command takes (a link that is none of the
  thirteen, a count of 0 or 101, a body with a key the driver never writes,
  a mix of groups) is refused: nothing is sent and one warning says why
  (`Dev Press refused: LINK 399 is not a Button Link (200 to 202, 300 to
  308, 311); nothing was done`). A refusal does not raise, so the `command_done`
  report carries no error: read the log.
- **Dev State.** One line of `key=value` pairs separated by spaces, always
  in this order: `phase`, `seq`, `fan`, `dir`, `light` (what the fan
  confirmed), `shown.fan`, `shown.light` (what the LEDs and Toggle work
  from: wanted over in flight over confirmed), `busy` (the groups with a
  command wanted or in flight, `fan,direction,light` in that order),
  `told.fan`, `told.dir`, `told.light` (what the proxies were last told),
  `notify.fan`, `notify.dir`, `notify.light` (the notifications sent since
  late init), `changing` (1 while the light's `CHANGING` is open), `leds`
  (links 300 to 308 and 311, then 200 to 202, as `303:1`), `follow` (the address
  follower of #39, [`address-follow-design.md`](address-follow-design.md):
  `off` while `Follow Address Changes` is Off, `pending` while a typed `Fan
  Address` has not answered yet, `armed:N` while it looks for the fan with
  window N due or under way, `idle` otherwise, `?` in a build without a
  follower), `search` (below) and `ms` (the last request's time). A fan or light reads `on/3`, `on/40` or `off`; `?` is
  unknown (a module that cannot say, before the first contact), `-` is none
  (`busy=-`, nothing told yet, `light=-` for a fan without a light kit). The
  light's buttons follow [the contract's LED rule](v1-design.md#52-light-links-200202)
  (200 and 202 lit while the light is on, 201 while it is off) unless the
  light module reports its own. An example
  `phase=online seq=231 fan=on/3 dir=forward light=on/40 shown.fan=on/3
  shown.light=on/40 busy=- told.fan=3 told.dir=forward told.light=40
  notify.fan=12 notify.dir=1 notify.light=8 changing=0
  leds=300:0,301:0,302:0,303:1,304:0,305:0,306:0,307:1,308:1,311:0,200:1,201:0,202:1
  follow=idle search=quiet ms=310` (one line; broken here for reading;
  `search=` is the fan search's state since #102: `off`, `stopped`,
  `standby`, `quiet`, `due:N` seconds or `open`).
- **A forwarded device's `DEV_LOG`** (dormant) must stay reachable through
  `ExecuteCommand`, since the devices send it with `C4:SendToDevice`: the
  polling driver's handler only prints one line under the sender's name,
  control characters turned into spaces, so a message cannot forge further
  lines of the shipped log.
- **Redaction.** A driver that comes to hold a secret installs a redactor
  ([The polling device](#the-polling-device)), so even a development
  command that printed the secret would not put it on the wire. The fan
  driver's (`devcmds.redactor`, handed the pinned identity) answers nothing
  for a line that holds a private key of the fan's answers in quotes
  (`owner`, `federatedIdentity`, `deviceName`, `SSID`, `BSSID`, `timezone`,
  `certificateId`, `schedule`, `FrCodes`; any case, single or double
  quotes, or inside a JSON text inside another) and in any other line
  replaces every client id (`MF_` or `WAC_` and 12 hex digits, the pinned
  one or another fan's) with `<client-id>`, every MAC in the colon form and
  the pinned MAC's twelve digits with `<mac>`, and every IPv4 address with
  `<ip>`. The last four digits of an id (`...5301`) stay: they are what the
  log may show. It remembers every identity it was told, so a line
  buffered before a re-point or after a stop is covered too, and it runs on
  each line twice (when buffered and when shipped), which it survives
  unchanged. The contract lets the address be logged; this redactor takes
  it out of the lines that leave the controller all the same, so
  `build/dev/driver.log` shows `<ip>` where a line had one.
- **The one module a reload never replaces.** A change to
  `common/devloop.lua` itself reaches the controller only with a dev `.c4z`
  install or a Director restart ([Gotchas](#gotchas-learned-on-hardware)):
  install a dev build made from the same commit as the server.

### What the server checks

- It listens on one address: `--bind`, by default this VM's LAN address
  (the source address of its default route, found at start; no packet is
  sent); `0.0.0.0` only when `--bind 0.0.0.0` says so. The address goes to
  `build/dev/server.json`, where `devctl.py` finds it.
- The developer endpoints, `/status` and `/admin/*`, want the header
  `X-Devloop-Token: <the admin-token MAC of nothing>`. `devctl.py` derives
  it from the key file, so it never leaves the VM when `devctl.py` runs
  there (as it must for `log`). Without it, or with a wrong one: 401 and
  one `DENY` line on the console, without the value presented.
- Unauthenticated by design: `/manifest` (a hint), `/file` (the
  repository's own source), and the driver's `POST /log` and `POST
  /report`. `/bundle` and `/commands` want no token either: they are
  signed.

### What is left

- **Reading.** Bundles (public source), reports (every property, the
  device id, the tree) and log lines cross the LAN in clear. None of it is
  secret: the dev key is in none of them, and a driver that holds a secret
  keeps it out of every shipped line and reported error with its redactor.
- **Withholding.** Anything that can answer as the VM can stop reloads and
  commands: a denial of service, nothing more.
- **Rollback.** A bundle the developer signed earlier can be replayed; the
  device then runs that earlier state until a genuine tick brings the
  current one back.
- **Spoofing the server's view.** Anything on the LAN can post log lines
  and reports to the server, for instance a `command_done` that drops a
  pending command unrun, or a device id that triggers the second-device
  warning. The server's view is advisory; nothing on the controller
  depends on it.
- **The key is as secret as a dev package.** Whoever holds a dev `.c4z`
  holds the key: they can sign bundles and commands for every dev build
  made with it, and derive the admin token. Never hand a `--dev` package to
  anyone; keep dev packages off shared places, serve them for the Windows
  download only for its duration (the HTTP server listens on every
  address), and never attach one to a release (the release workflow builds
  without `--dev`, and `tools/deploy.py` refuses a manifest that says
  `dev: true`). To rotate the key: delete the key file, run
  `tools/build.sh --dev` (it creates a new one), restart `devserver.py`,
  install the new dev build. Installing a release build ends the loop, and
  the old key's use with it.
- `Dev Server` stays empty when the loop is not in use; a release build has
  no such row.

Never install a dev build as the production driver.

## Gotchas learned on hardware

From the Hue project's dev loop on this house's controller *[Hue project,
hardware]*, and what follows from them here:

- **Keep files complete when saving.** The running controller reloads on
  every change to the tree, so a file saved half-written (or a sequence of
  edits that leaves the tree inconsistent between saves) is a real reload:
  the driver is torn down, the broken code fails to come up, and the
  device is dead until the next consistent save. Write whole files at
  once; when a change spans several files, `devctl.py pin` first and pin
  again once the tree is consistent. `devctl.py set "Dev Server" ""` stops
  the loop altogether: the device then polls nothing, so only Composer can
  start it again (the `Dev Server` row and its Set button).
- **A lost `Dev Server` report.** The loop reports a `Dev Server` change
  before it stops or moves, so `devctl.py wait` returns as for any
  command. If that report never arrives (the network dropped it), the
  command stays queued on the server, and a loop that later starts fresh
  there (a Director restart or a dev install; it asks `after=0`) receives
  it again and empties the row once more. To avoid that, take the leftover
  out before starting the loop again: stop `devserver.py`, delete the
  command from `commands` in `build/dev/commands.json`, start the server.
- `common/devloop.lua` is the one module a reload never replaces, so an
  edit to it reaches the controller only through a Director restart or a
  fresh dev `.c4z` install; the bundle carries the new file, but the
  running copy is the one that was `require`d first.
- Director's `C4:JsonEncode` writes Lua arrays as objects with string keys
  even with `encodeArrays = true`; the server accepts both shapes.
- Director runs at most four `C4:url` transfers at once across all hosts.
  A reload abandons whatever the old code had in flight (an abandoned
  transfer lives on until it completes or times out; `Cancel()` did
  nothing for the Hue event stream), and every other request, the dev
  loop's own included, waits behind the transfers that are open. Space
  reloads out when the driver keeps long requests open.
- Edits to `tools/devserver.py` need a server restart. Stop it by its
  pid, which `build/dev/server.json` holds (`kill "$(python3 -c 'import
  json; print(json.load(open("build/dev/server.json"))["pid"])')"`), and
  start it again in a separate command: a pattern such as `pkill -f
  "devserver[.]py"` also stops the Hue project's server, which runs the same
  script name, and a pattern that appears in your own command line stops
  your own shell.
- `build/dev/reports.jsonl` gets a heartbeat every 30 s; prune it when it
  grows.
