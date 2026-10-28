# MF Probe: the throwaway driver of M1

**MF Probe (delete after M1)** is a test driver for the hardware checks K4
to K10 and K14 of
[`v1-design.md`, section 11](../docs/v1-design.md#11-hardware-checks-before-the-first-install)
(issue #17). It declares what the v1 driver will declare, controls nothing,
and logs every call Director makes into it, so the Windows session can read
in Composer's Lua tab what the proxies, the keypads and Composer really do.
It is never the house's driver and never a release. It goes into a test room
beside the stock device for M1 and is deleted afterwards.

- **Its own identity.** The file is `mf_probe.c4z`, the driver name
  "MF Probe (delete after M1)", the model "MF Probe (M1 hardware checks)",
  and the items are "MF Probe Fan" and "MF Probe Light". None of these is
  the real driver's (`modernforms_fan`, ECC D27). It lives here, outside
  `src/`, so `tools/build.sh`, `build/manifest.json` and the Release
  workflow never see it.
- **What it declares** ([`mf_probe/driver.xml`](mf_probe/driver.xml)):
  - Proxies: the fan proxy `fan` on 5001, declared first and primary, and
    `light_v2` on 5002.
  - Capabilities: those of v1-design §2.3, plus
    `proxy_fan_speed_connections` True for K5.
  - Links: "Light Top Button Link" on 200 *with* `proxybindingid="5002"`,
    and "Fan Off Button Link" on 300 *without* it. Both are `BUTTON_LINK`
    providers.
  - One property, **Echo LED On Press** (Off/On), and two actions, **Run
    mDNS Probe** and **Dump State**.
  - No network connection in XML: K10 makes bindings 6001 to 6003 at run
    time.
- **What it does** ([`mf_probe/driver.lua`](mf_probe/driver.lua)): it logs
  and never answers a proxy, a keypad or a press. The one exception is Echo
  LED On Press: set to On, a `DO_PUSH` on 200 or 300 lights that link's LED
  and a `DO_RELEASE` darkens it. Its spec is
  [`tests/spec/probe_spec.lua`](../tests/spec/probe_spec.lua).
- **What K1 already settled** (issue #11, "M0, Windows side"): the fan
  proxy is `fan` with class `FAN`, and `speed_names` is the stock driver's
  "Level 1, Level 2, Level 3, Level 4, Level 5, Level 6"; the capability
  names are spelt as the stock driver spells them. K2 found that the
  first-declared proxy becomes the parent item, which carries the driver's
  properties, actions and Documentation tab. So **MF Probe Fan** should be
  the parent here, with Echo LED On Press, the actions and, presumably, the
  Lua tab; K4 confirms.

## Building

```
probes/build_probe.sh          # build/probe/mf_probe.c4z
probes/build_probe.sh --k9     # also build/probe/mf_probe_k9.c4z, for K9
```

- **What the script writes.** It stages the probe in `build/probe/stage/`
  with `LICENSE` and `NOTICE` and packs it with dp3 (`$DP3`, default
  `~/c4-tools/drivers-driverpackager/dp3/driverpackager.py`), using
  `--allowexecute`: dp3 appends `C4:AllowExecute(true)`, the route the Hue
  project's dev builds use for the Lua window, and `driver.lua` calls it in
  `OnDriverInit` too. The hashes go into `build/probe/SHA256SUMS.txt`.
- **What it refuses.** It writes under `build/probe/` only. It stops when a
  package name is one the release uses in `build/`, when `src/mf_probe`
  exists, or when the probe's `<name>` or `<model>` is a release driver's.
- **The version.** `<version>` is the number of minutes since 2026-01-01 UTC
  (or `PROBE_VERSION`). Every rebuild is newer, so "Add or Update Driver or
  Agent…" updates an installed probe in place.
- **The K9 copy.** `mf_probe_k9.c4z` is the same probe under its own file
  name, driver name, model and item names ("MF Probe K9 …"), declaring
  minimum OS 9.0.0.

## Installing it

The route is that of a feature-branch test build
([`CLAUDE.md`](../CLAUDE.md), Deploy;
[`composer-remote.md`](../docs/composer-remote.md#workflow)):

1. The coordinator builds it, serves the folder with
   `python3 -I -m http.server 8091 --bind 0.0.0.0 --directory build/probe`
   and puts each file's URL (`http://192.0.2.7:8091/mf_probe.c4z`) and its
   sha256 from `SHA256SUMS.txt` in the brief. The server is stopped after
   the install.
2. The Windows session fetches the file into `C:\c4-mf\drivers\probe\`. It
   checks it with `Get-FileHash -Algorithm SHA256` and stops on a mismatch.
3. In Composer, Driver ▸ "Add or Update Driver or Agent…" adds the new
   driver. Then the session adds one device to the **test room** from the
   Items pane (search "MF Probe").
4. **The test room** is a room the session creates for M1, **"MF Probe
   Test"**, and deletes with the probe. If a new room is unwelcome, the fan's
   own room serves; reports call it "Example Room"
   ([placeholders](../docs/scaffold-design.md#2-placeholders-the-repository-is-public)).
   A room of its own keeps the probe's fan and light off the family's room
   in the Navigators, and the owner finds them easily in the app for K8.
5. **Capabilities.** The probe is a new driver, so its capabilities load
   when the device is created, with no reboot (assumed, LSR H8). A later
   rebuild that changes only the Lua takes effect at once. A rebuild that
   changes `<capabilities>` makes Composer ask "Restart Director?". Yes does
   not load them: **the owner must reboot the controller from System
   Manager** ([rule 10](../docs/composer-remote.md#rules-for-the-windows-session)).
   So the probe's capabilities stay as they are for all of M1.
6. **Recording.** Whether the install is recorded with
   `tools/deploy.py record` is the coordinator's call. The probe is not the
   project's driver.

## The log

Every line looks like this:

```
[MFP] 42 14:02:31.120 +0.412 ReceivedFromProxy binding=300 (fan link) cmd=DO_PUSH {}
```

The fields are a sequence number, the controller's time of day to the
millisecond, and the seconds since the previous line. Composer may show `print` lines out
of order; the numbers restore the order.

- **What is logged.** Every call into the driver, with its binding,
  command and every parameter: `ReceivedFromProxy`, `ExecuteCommand`,
  `OnBindingChanged`, `OnPropertyChanged`, `ReceivedFromNetwork`,
  `OnConnectionStatusChanged`, `OnNetworkBindingChanged`,
  `OnWatchedVariableChanged`, and the four lifecycle calls. Strings are
  quoted, so their type shows (`SPEED="4"` is a string, `SPEED=4` a
  number).
- **Bindings are named.** 5001 is "fan proxy", 5002 "light proxy", 200
  "light link, proxybindingid 5002", 300 "fan link", and 6001 to 6003
  "mDNS …". Any other id reads "not declared by the probe", which is how a
  link the fan proxy made itself (K5) would show.
- **Only live lines show** in Composer's Lua output pane, those that arrive
  while the device's Lua tab is open
  ([rule 13](../docs/composer-remote.md#rules-for-the-windows-session)).
  The probe keeps its last 400 lines, and `P.history()` prints them again,
  including what happened at the add. So run the actions from the Lua window
  (`P.dump()`, `P.mdns()`). After clicking an action in the Actions tab
  instead, open the Lua tab and type `P.history(80)`.
- **Stray datagrams.** Outside a K10 window, the first 20 datagrams are
  logged and the rest only counted; `P.dump()` shows the count. This keeps
  a group connection that `NetDisconnect` might leave open from flooding the
  log.
- **Private data.** Every line has MAC-like text cut to its last four hex
  digits: `xx:xx:xx:xx:53:01`, `MF_Fan_xx5301`. mDNS traffic of other
  devices is counted, never printed. The decoded mDNS answer prints the
  fan's address in full, so reports replace it with `10.0.2.151` and any
  other house value with its
  [placeholder](../docs/scaffold-design.md#2-placeholders-the-repository-is-public)
  (rule 4 of [`composer-remote.md`](../docs/composer-remote.md#rules-for-the-windows-session)).

## The Lua window helpers

Typed into the probe device's Lua tab. Each call logs what it sent, or why
it could not.

| Call | Sends or does |
| --- | --- |
| `P.help()` | lists these calls |
| `P.led(link, on)` | `MATCH_LED_STATE {STATE = true/false}` on a link (200, 300 or another id), as a COMMAND |
| `P.colors(link, on, off, current)` | `BUTTON_COLORS {ON_COLOR, OFF_COLOR, CURRENT_COLOR}` as a NOTIFY, colours as `"rrggbb"`; `current` defaults to `on` |
| `P.notify(binding, cmd, params)` | any notification: `SendToProxy(binding, cmd, params or {}, "NOTIFY")` |
| `P.speed(n)` | `CURRENT_SPEED {SPEED = n}` to the fan proxy (5001); 0 is off |
| `P.keypad(device, button, action, key)` | `KEYPAD_BUTTON_ACTION` to a keypad with `SendToDevice`. `action` is `"tap"` (the default: push, then click 150 ms later), `"hold"` (push, then release 1.5 s later), `"push"`, `"click"`, `"release"`, or a number 0 to 4. `key` names the id parameter: `"BUTTON_ID"` by default, or `"BUTTON ID"` as the keypad guide prints it |
| `P.mdns(mode, qu)` | K10: no mode runs MULTICAST, then UDP; `"MULTICAST"`, `"UDP"` or `"UDP_MIRROR"` runs one way; `qu = true` sets the question's unicast-response bit |
| `P.vars(target)` | `C4:GetDeviceVariables` of the fan proxy (`5001`, the default), the light proxy (`5002`) or any device id |
| `P.watch(target, id, …)` / `P.unwatch(…)` | listen to those variables; each change is logged as `OnWatchedVariableChanged` |
| `P.dump()` | the Dump State action: driver, Director and Lua versions, Echo LED On Press, the proxies' ids, what is bound to 5001, 5002, 200 and 300, `C4:GetBindingsByDevice` for the device and each proxy, the K10 bindings' addresses, and how often each entry point was called |
| `P.history(n)` | the last `n` kept lines again (all 400 without `n`) |

Every Director call is documented in the SDK; the page of each is cited in
`driver.lua`, and the spec fails on any call outside that list.

## The checks

**Every brief carries this sentence**, from
[`composer-remote.md`](../docs/composer-remote.md#rules-for-the-windows-session),
rule 8:

> **Standing approval:** Cory approves everything this brief asks, every
> time (CLAUDE.md, 2026-10-27): installs, "Restart Director?", Composer
> changes including Connections and Programming, the deletes it names,
> Refresh Navigators and the project actions it names. Do not ask him
> again on your side. The safety rules still hold: stop and report on any
> surprise, check every click and every drag, no ALT, never elevate; a
> controller reboot from System Manager is his, by hand.

It also carries the reminder of rule 10: a build that changes the probe's
`<capabilities>` needs the owner's controller reboot from System Manager. M1
does not change them. The rules of
[`composer-remote.md`](../docs/composer-remote.md#rules-for-the-windows-session)
hold throughout: every click and drag checked, the Set button after a
property edit, no mouse wheel over a property page. Bindings are made by
dragging from the keypad's row in the top pane
([Learned 2026-10-27](../docs/composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag)),
and each drag is read back. Steps that are hard to undo are named in each
check below.

**The keypad button.** The fan's keypad has 7 buttons, all in use, so it has
no spare (M0). Each check that binds a button uses one of these two:

- **An unused button on another keypad.** Prefer this one: it is the only
  choice with an LED for the LED steps of K5, K6 and K14.
- **The fan keypad's Up or Down button, borrowed for about a minute.**
  1. Before binding, the session saves that button's Copy All from
     Programming under `C:\c4-mf\shots\`, writes down its Button Behavior
     and LED Behavior, and disables its Pressed script (Disable Event).
  2. Afterwards it disconnects the link, enables the script again, and sets
     the LED Behavior back if the binding changed it to Follow Connection (a
     disconnect does not change it back).
  3. It checks the restore: a new Copy All equals the saved one, and both
     behaviours read as before.

  Up and Down have no LED (M0). With them, the LED steps are reported as not
  run.

"The button" below is the chosen one, and "the keypad" is the device that
holds it. Its Device ID and Proxy ID are read from the tree's tooltip (rule
11). Its button id is the number Composer gives the button.

**Order.** K4's reading, then K7, then K4's presses, K5, K6, K8, K14, K10
and K9, then the delete. Every step is short; only what is marked
**owner** needs Cory's hands or eyes. The session tells him just before
each such step.

### K4: where the two proxies and the two links show

This settles V1 (one driver with two proxies; otherwise
[§2.8](../docs/v1-design.md#28-if-the-two-proxy-probe-fails)) and whether
the links carry `proxybindingid`. The button for the presses is an unused
one on another keypad, or the fan keypad's Up or Down, borrowed and restored
as described under "The keypad button".

1. **Read the tree.** Note the items under the test room, their names, their
   order and which one is the parent. For each item, note its tabs
   (Properties, Actions, Documentation, Lua) and its Properties rows. On
   "MF Probe Light", check for the light_v2 settings page: Default On
   Brightness, click and hold rates, LED colours.
2. **Read Connections.** Select each item and list its Control Outputs:
   under which item "Light Top Button Link" (200, with `proxybindingid`)
   and "Fan Off Button Link" (300, without) appear, and any other link
   (K5). Then select the keypad and read how the lower "BUTTON_LINK Output
   Devices" list names the probe's links.
3. **Bind 300.** Bind the button to "Fan Off Button Link" (a Connections
   change; hard to undo) and read the binding back. In the Lua tab, the
   `OnBindingChanged binding=300 …` line gives the keypad's id and binding.
4. **Press it.** Press with `P.keypad(<keypad id>, <button id>)` if K7
   works; otherwise the **owner** presses once. Read
   `ReceivedFromProxy binding=300 (fan link) cmd=…`.
5. **Repeat on 200.** Disconnect the button, bind it to "Light Top Button
   Link", press again and read `binding=200 (light link, proxybindingid
   5002)`. Then disconnect it.

Report the texts, a screenshot of each Connections view, and the Lua lines.

### K7: KEYPAD_BUTTON_ACTION from the Lua window (run it first)

This settles whether the later presses need the owner.

1. With the button bound to 300, type `P.keypad(<keypad Proxy ID>, <button
   id>)` in the probe's Lua window. Within a second, `ReceivedFromProxy
   binding=300 … cmd=DO_PUSH` and then `DO_CLICK` or `DO_RELEASE` should
   arrive.
2. If nothing arrives, try one change at a time, in this order:
   - the keypad's Device ID instead of its Proxy ID;
   - `P.keypad(<id>, <button>, "tap", "BUTTON ID")`;
   - the button id minus one.
3. Then `P.keypad(<id>, <button>, "hold")`.

Report which combination drives the link, the messages in order and the
`+seconds` column.

### K5: the fan proxy's own speed links

This records facts for a later version; v1 does not use
`proxy_fan_speed_connections`. The press in step 2 uses an unused button on
another keypad or the borrowed Up or Down ("The keypad button"); the LED in
step 3 needs the former.

1. From K4's step 2, note which links appear under the fan item beyond 200
   and 300: their names (from `speed_names`, "Level 1" … presumably),
   their number, and whether one is for Off. `P.dump()` lists
   `C4:GetBindingsByDevice(<fan proxy id>)` with the ids.
2. If there are any, bind the button to the second speed's link (hard to
   undo) and press it once, with K7 or by the **owner**. Read which of
   these arrives:
   - `ReceivedFromProxy binding=5001 (fan proxy) cmd=SET_SPEED {SPEED=…}`:
     the proxy acts on the press;
   - `DO_PUSH` on a binding "not declared by the probe": the press is
     forwarded;
   - nothing.

   A second press shows whether it toggles.
3. Needs a button with an LED, on Follow Connection: type `P.speed(2)`,
   then `P.speed(3)` 5 s later, then `P.speed(0)` 5 s after that. The
   **owner** glances: lit, dark, dark means the proxy lights its speed
   links by itself.
4. Disconnect the button.

### K6: what a keypad sends over a link, and colours

This settles V12 and §5.1's click rule (what a tap, a hold and a double tap
deliver), and V27 (whether a keypad takes colours over the link, and again
while bound). The button is an unused one on another keypad or the fan
keypad's Up or Down, borrowed and restored ("The keypad button"). Steps 3 to
5 and step 6's colour need a button with an LED; with the borrowed Up or
Down, only steps 1 and 2 and step 6's binding lines are run.

1. Bind the button to 300 (hard to undo), keep the Lua tab open, and type
   `P.history(5)` to mark the start.
2. The **owner** does a tap, a 2 s hold and a double tap, about 3 s apart.
   Read each `ReceivedFromProxy binding=300 cmd=…` line with its `+seconds`.
3. Type `P.led(300, true)` (lit?), then `P.led(300, false)` (dark?).
4. Type `P.colors(300, "ff0000", "000000")`, then `P.led(300, true)`. Is
   it red?
5. While it is lit, type `P.colors(300, "0000ff", "000000")`, then
   `P.led(300, true)`. Is it blue? Then `P.led(300, false)`.
6. Disconnect and bind again (Connections). Read the two `OnBindingChanged`
   lines and whether `cmd=REQUEST_BUTTON_COLORS` arrives after the new
   binding. The **owner** says which colour the button shows.
7. Optional, the whole path with real presses: set Echo LED On Press to On
   (with Set). The **owner** presses and holds: the LED should light on the
   push and go dark on the release. Set it back to Off.

The owner's part is about 40 s.

### K8: fan proxy notifications

This settles R9 (whether the driver may ever send `ON`) and whether
`DESIGNATE_PRESET` needs the `PRESET_SPEED` answer.

1. Right after the add, type `P.history()`. Did
   `ReceivedFromProxy binding=5001 (fan proxy) cmd=GET_CURRENT_STATE`
   arrive, and what did the light proxy send?
2. Type `P.vars(5001)`, which lists the fan proxy's variables and their
   ids. Then `P.watch(5001, <id of Is On>, <id of Current Speed>, <id of
   Current Preset>)`.
3. With the fan at 0, type `P.speed(2)` alone. Is Is On now 1? Then
   `P.notify(5001, "ON")` alone: does Current Speed jump to the preset (3)?
   Then `P.speed(0)`.
4. The **owner** uses the Control4 app on "MF Probe Fan" in the test room:
   speed 4, Off, reverse, and the preset if the app offers it. The probe
   logs `SET_SPEED`, `SET_DIRECTION` or `TOGGLE_DIRECTION`, and
   `DESIGNATE_PRESET {PRESET=…}`, and answers none of them.
5. Type `P.vars(5001)`. Has Current Preset stayed? Then
   `P.notify(5001, "PRESET_SPEED", { SPEED = <the preset picked> })` and
   `P.vars(5001)` again.
6. Type `P.unwatch(5001, <the same ids>)`.

### K14: a Programmed LED command on a Follow Connection button

This settles the migration's order (ECC H6) and needs a button with an LED.

1. The button is bound to 300, with LED Behavior Follow Connection.
2. In Programming, put the keypad's "Use the on color for <button>" under
   the event of "MF Probe Fan" that fires when the speed changes (the fan
   proxy's own event). This is a Programming change; check it with Copy
   All.
3. Type `P.led(300, false)`; the LED goes dark. Then `P.speed(1)`, which
   makes the proxy fire the event and the script run. The **owner**
   glances: lit means the programmed command still acts, dark means Follow
   Connection wins.
4. Type `P.speed(0)`, then delete the script line (hard to undo).

### K10: mDNS from a driver

This settles V5a: whether Find Fans is in v1.

1. Type `P.mdns()`. It asks for `_easylink._tcp.local` (PTR) at
   224.0.0.251:5353 over MULTICAST for 3 s, then over UDP with
   `MIRROR_UDP_PORT` off for 3 s, and ends with `mDNS probe done` after
   about 8 s. The Run mDNS Probe action does the same; then type
   `P.history(80)`.
2. Read, for each way:
   - its summary, `mDNS <way>: … N answer(s) about _easylink._tcp.local`;
   - the `OnConnectionStatusChanged` lines and any `… failed` line;
   - for each answer, the decoded lines and the hex. With placeholders,
     an answer looks like this:

     ```
     AN _easylink._tcp.local PTR IN ttl=4500 -> MF_Fan_xx5301._easylink._tcp.local
     AR MF_Fan_xx5301._easylink._tcp.local SRV IN flush ttl=120 priority=0 weight=0 port=80 target=MF_Fan_xx5301.local
     AR MF_Fan_xx5301._easylink._tcp.local TXT IN flush ttl=4500 "Protocol=com.modernforms.fan" "MAC=xx:xx:xx:xx:53:01" "Firmware Rev=02.00.0052"
     AR MF_Fan_xx5301.local A IN flush ttl=120 10.0.2.151
     ```

3. If neither way got an answer, try `P.mdns("MULTICAST", true)`,
   `P.mdns("UDP_MIRROR")` and `P.mdns("UDP_MIRROR", true)`, about 4 s each.
4. Type `P.dump()` for the bindings' addresses.

**It passes** when any way brings an answer about `_easylink._tcp.local`
that names the fan's instance, port and address.

### K9: a minimum OS above the controller's

This shows how much V3's run-time check has to carry.

1. The coordinator builds `probes/build_probe.sh --k9` and serves
   `mf_probe_k9.c4z` with its hash.
2. The session installs it with Add or Update Driver or Agent… and reports
   the dialog's exact text: refused, warned or added.
3. If it was added, the session adds it to the test room from Items and
   reports the texts. If a device was created, the session deletes it at
   once (hard to undo; named here).

## Deleting it after M1

1. **Disconnect** every binding to the probe's links in Connections.
   Restore a borrowed Up or Down button as described above, or set the
   other keypad's button's LED Behavior back to what it was.
2. **Delete** any K14 script line still there, the "MF Probe Fan" device
   (with its light), and the K9 device if one is left. These deletes are
   hard to undo and are named here. The probe's dynamic network bindings go
   with the device.
3. **Delete the room** "MF Probe Test" if it was created for M1.
4. **Remove the files** `mf_probe.c4z` and `mf_probe_k9.c4z` from
   `C:\c4-mf\drivers\probe\` and from Composer's driver store
   (`Documents\Control4\Drivers`).
5. **Check** that a tree search for "MF Probe" finds nothing and that the
   project's device count is back to what it was. The coordinator stops the
   file server if it still runs.

## References

- [`v1-design.md` §11](../docs/v1-design.md#11-hardware-checks-before-the-first-install):
  the checks.
- [§16](../docs/v1-design.md#16-what-m0-and-m1-may-still-change): what
  their results may change.
- [`fan-proxy-research.md` §8](../docs/fan-proxy-research.md#8-hardware-tests):
  tests T2 to T8, behind K5 to K8.
- [`light-structure-research.md` §5.3](../docs/light-structure-research.md#53-hardware-tests-each-under-a-minute):
  tests H1, H2, H7 and H8.
- [`edge-cases-control4.md` §7](../docs/edge-cases-control4.md#7-probes-in-order):
  probes H1 to H7.
