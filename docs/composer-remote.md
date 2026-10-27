# Driving Composer Pro from here: the Windows session

The dev loop ([`dev-loop.md`](dev-loop.md)) lets the coordinator change and
exercise the driver on the live controller, but everything that happens *in
Composer Pro* (driver updates, properties and actions, dialogs, connections,
programming, what a Navigator tile shows) would need the owner's hands. The
second layer removes that: a Claude Code session running inside the Claude
desktop app **on the Windows VM** acts as the coordinator's hands in
Composer, driven by messages from the coordinator's session. It is the same
session, with the same rules, that has served the author's Hue driver since
2026-10-21 (that project's `docs/composer-remote.md` holds its rounds).

**Current state (2026-10-27):** this project has had no round of its own
yet. The session's rounds of 2026-10-27 on the house's fan keypad, run for
the Hue project (its
[issue #312](https://github.com/corytron/c4-hue-driver/issues/312)), tested
the stock fan driver's Button Links and produced the rules and the
"Learned" section below. A release install
follows [`release-checklist.md`](release-checklist.md): `tools/deploy.py
start` writes the brief the session works from ("Workflow" below). While a
dev build runs, the dev loop's shipped log is the coordinator's view; with a
release build, Composer is where results are read (rule 13).

## How it is wired

```
coordinator session (Ubuntu VM, this repo)   --SendMessage over Remote Control-->   "Composer" session (Windows VM)
   reads the shipped driver log, dev loop                                            PowerShell + Windows UI Automation
   decides the steps, interprets results         <--  report (texts, screenshots) --   Composer Pro 3.4.2, WinForms
```

- Both sessions belong to the owner's account and have **Remote Control**
  switched on; they then see each other in `ListAgents` as peer sessions
  and talk with `SendMessage`. The Windows side may hold an incoming
  message for the owner's approval, depending on its permission mode.
- The Windows session has no computer-use tools. It works through
  **PowerShell 5.1** (UI Automation: `UIAutomationClient` /
  `UIAutomationTypes` to read; to act, since Composer offers no patterns,
  mouse input through `SetCursorPos` and `mouse_event` via P/Invoke and keys
  through `SendKeys`), Git Bash, and a `Read` tool that renders PNG files
  it saved. No Python is installed on the VM and none is needed.
- Composer Pro is a WinForms application (`WindowsForms10.Window.8.app…`):
  its controls are exposed to UI Automation. Every element reports
  `ControlType.Pane`, but `Name` and `ClassName` (`EDIT`, `STATIC`,
  `BUTTON`, `COMBOBOX`) are meaningful, and a driver's Properties page is a
  sequence of label/value pairs, so the coordinator can read the property
  texts verbatim, without screenshots **[verified 2026-10-21, Hue
  project]**.
- Screenshots: `System.Drawing` `CopyFromScreen` after bringing Composer to
  the foreground (`SetForegroundWindow`), or `PrintWindow` with
  `PW_RENDERFULLCONTENT` for an occluded window; the Claude desktop app
  itself usually covers Composer on that screen.
- The Windows VM is on the same LAN as the controller and this VM, and
  reaches this VM's servers over it: the dev server (port 8081), the file
  server for dev and test builds (port 8091) and `tools/collect.py`, which
  receives screenshots (port 8092). The Hue project's servers use 8080 and
  8090, so both projects can run theirs at once. Release packages come from
  the GitHub release URLs instead. The session keeps this project's files under
  `C:\c4-mf\` (the module `C:\c4-mf\Composer.psm1`, screenshots under
  `C:\c4-mf\shots\`, downloaded releases under `C:\c4-mf\drivers\<tag>\`),
  apart from the Hue project's `C:\c4-hue\`.

## Rules for the Windows session

Written into every brief; the session is a teammate acting on the owner's
behalf, not the owner.

1. **Read first, click second.** Reading properties, listing actions,
   opening a dialog to inspect its pickers and cancelling it, taking
   screenshots: always allowed.
2. **Hard-to-undo steps are named in the brief**: deleting a device,
   Update Driver, Connections and Programming changes, Load/Save project,
   OK in a dialog that creates or changes a device. They are covered by
   the owner's standing approval (rule 8); the brief names them so the
   session knows what it is about to change.
3. **Stop on surprises**: any unexpected dialog, error or prompt ends the
   round with a report, not a guess.
4. **Report exact texts** (UIA Names, property values) and keep screenshots
   under `C:\c4-mf\shots\`. Reports leave the house's addresses, MAC
   addresses, fan ids, room and project names out, or replace them with the
   placeholders of [`scaffold-design.md`](scaffold-design.md), section 2:
   the repository and its Discussions are public.
5. **Keystrokes and clicks only into a verified target.** Before any key
   is sent, the focused control must have been checked (the tree's
   in-place editor, a dialog button, a text field) and no menu may be
   active; never tap ALT to gain foreground rights (use `AttachThreadInput`
   with `SetForegroundWindow`, or a click). Prefer window messages
   (`WM_SETTEXT`) and rectangle clicks over typing; re-check
   `Get-ComposerDialog` before every Enter and Cancel anything unexpected.
   **Every click** goes through `Invoke-SafeClick`, which refuses unless the
   intended top-level window is in the foreground and contains the point;
   the module's tab, tree, picker, rename and property clicks and
   `Invoke-ElementClick` go through it with their target's top-level window
   (`Get-ComposerRootWindow`), and `Invoke-MouseDrag` checks both points
   first (`Assert-SafePoint`) and releases at the start point if the window
   loses the foreground mid-drag. `Invoke-MouseClick` is called from
   `Invoke-SafeClick` alone. Learned the hard way in the Hue project
   (2026-10-21): an ALT tap left Composer's File menu in keyboard mode, and
   the Enter meant for the rename editor opened **File ▸ Clear Project**'s
   confirmation; the session cancelled it and nothing was lost, but the
   project must be backed up before any round that changes it.
6. **After every step** confirm the window title (project name) and the
   System Design row count are unchanged unless the step meant to change
   them.
7. **A property edit is not done until the row's Set button is clicked.**
   Composer shows the new value at once but sends nothing to Director until
   Set (which appears with Cancel beside the changed value).
   `Set-ComposerProperty` does it.
8. **Standing approval.** The owner approves everything, every time
   (`CLAUDE.md`, 2026-10-27, carried over from the Hue project, where it
   has stood since 2026-10-24): installs, "Restart Director?", Composer
   changes including Connections and Programming, deletes, Refresh
   Navigators, and the project actions the brief names. The session does
   not ask him again on its side. The safety rules that are not approvals
   stay: stop on surprises (rule 3), the click and focus checks, no ALT,
   never elevate. Every brief carries this sentence (an install brief that
   `tools/deploy.py start` writes carries its own shorter form of it):

   > **Standing approval:** Cory approves everything this brief asks, every
   > time (CLAUDE.md, 2026-10-27): installs, "Restart Director?", Composer
   > changes including Connections and Programming, the deletes it names,
   > Refresh Navigators and the project actions it names. Do not ask him
   > again on your side. The safety rules still hold: stop and report on any
   > surprise, check every click and every drag, no ALT, never elevate; a
   > controller reboot from System Manager is his, by hand.

9. **System Manager is out of reach.** `Sysman.exe` needs administrator
   rights and the non-elevated session's input cannot reach it, so a
   controller reboot is the owner's, by hand. Never elevate or work around
   it.
10. **Capability changes need a controller reboot.** Composer has no
    Director restart command. A build that changes the driver's
    `<capabilities>` (for example `proxy_fan_speed_connections`, the fan's
    speeds, the light's dimmer or LED capabilities, `hide_proxy_properties`)
    makes Composer ask "Restart Director?"; Yes does **not** restart
    Director, the device keeps the old capabilities and code until the
    owner reboots the controller from System Manager, and a per-device
    Update Driver ("Versions are equal", overwrite) does not help while
    Director's copy is stale. The brief says so whenever a build changes
    capabilities. Builds that change only Lua or connections take effect at
    once.
11. **Overlays are not dialogs.** Composer's permanent "GlassPanelForm"
    overlay and the device tooltips ("Device ID:" / "Proxy ID:") are never
    answered or closed.
12. **Re-orient after every Update Driver.** Composer reloads the project
    view (selection lost, panes recreated) and may leave the centre pane in
    List View, which hides the Properties tab: re-select the device and
    click the Properties header before reading.
13. **The Lua Output pane shows only live lines**, those arriving while
    that device's Lua tab is open; startup logs cannot be captured from
    Composer.
14. **Set every action parameter explicitly.** The Action Parameter List
    dialog remembers each action's last values.
15. **Through a controller reboot** a background logger records the status
    bar and any dialogs; after the reconnect Composer comes back on the
    project root, so devices are re-selected before anything is read.
16. **To find a stale driver copy**, compare the downloaded `.c4z`,
    Composer's driver store (`Documents\Control4\Drivers`) and the device's
    `Driver Version`.
17. **Never turn the mouse wheel over a property page.** It steps the
    drop-down under the pointer: on 2026-10-27 it moved Engraving Size on
    the project root's Lighting Defaults from Standard to Large (set back
    afterwards). Scroll with clicks on the scrollbar only.
18. **Check every drag twice.** Mid-drag, `GetGUIThreadInfo` must report a
    capture window and the drop or no-drop cursor, or the release drops
    nothing; afterwards the Connections lists, or a Script's Copy All
    (XML), must show the binding or the line where it was meant to go
    ("Learned 2026-10-27" below).
19. **Never read the Programming view's lists cross-process.** A
    cross-process list-view read there crashed Composer on 2026-10-26; read
    what the Programming view shows from screenshots, and a Script from its
    Copy All.
20. **Update in place; never delete and re-add.** The driver is installed
    and updated only through Driver ▸ "Add or Update Driver or Agent…",
    which updates every existing device in place. A deleted and re-added
    device loses its state, its connections and every programming line
    that names it.

## The helper module

`tools/composer/Composer.psm1` is the PowerShell module the Windows session
grows as it works: it develops and tests it there, then sends it back for
the repo. This copy was ported on 2026-10-27 from the Hue project's (its
state of 2026-10-25, every click checked): the Hue device helpers became
`Get-ComposerFanStatus` and `Format-FanStatus`, the paths moved to
`C:\c4-mf\` and the screenshot upload to port 8092; it holds 58 functions.
It is not run on this VM, but CI's `powershell` check runs PSScriptAnalyzer
over it and `Shots.ps1` (`tools/check.sh`). Composer exposes no UIA
patterns, so the module reads through UIA and acts through real mouse and
keyboard input at the reported rectangles.

| Purpose | Functions |
| --- | --- |
| Window, focus, input | `Get-ComposerProcess`, `Get-ComposerMainHandle`, `Get-ComposerWindow`, `Get-ComposerTopWindows`, `Show-Composer`, `Show-AnyWindow` (foreground without ALT), `Get-ComposerFocus`, `Invoke-SafeClick` (rule 5), `Assert-SafePoint`, `Get-ComposerRootWindow`, `Invoke-MouseClick` (from `Invoke-SafeClick` only), `Invoke-MouseDrag` (both points checked), `Move-MouseAway`, `Invoke-ElementClick`, `Send-Keys`, `Send-KeysTo` (keys only into the expected window) |
| Reading | `Find-ComposerElements`, `Get-ComposerElementInfo`, `Get-ComposerTree`, `Get-ComposerProperties`, `Get-ComposerProperty`, `Get-ComposerFanStatus` (selects the Modern Forms Fan device and returns its property table), `Format-FanStatus`, `Get-ComboItems` (a combo box's item count and selection; Composer's combos refuse their texts cross-process), `Get-ComboListItemsMsaa` (the texts of a dropped list through MSAA) |
| Tabs and actions | `Get-ComposerTabControl`, `Select-ComposerTab` (tab offsets measured on a Hue device; re-measure on the fan's page with `Set-ComposerTabOffset`), `Set-ComposerTabOffset`, `Get-ComposerActions`, `Invoke-ComposerAction` |
| Dialogs and pickers | `Get-ComposerDialog`, `Wait-ComposerDialog`, `Get-ComposerDialogText`, `Close-ComposerDialog`, `Confirm-ComposerDialog`, `Get-ListViewItems`, `Get-ListViewItemScreenPoint`, `Get-ComposerPickerItems`, `Open-ComposerPicker`, `Get-ComposerParameterValues`, `Select-ComposerPickerItem`, `Set-ComposerActionParameter` |
| Devices in the tree | `Get-ComposerTreeHandle`, `Get-ComposerDevices`, `Select-ComposerDevice`, `Get-ComposerSelectedDevice`, `Rename-ComposerDevice`, `Get-ComposerTreeEditor`, `Request-ComposerDeviceDelete` (opens the prompt, never confirms) |
| Properties | `Set-ComposerProperty` (edits the row and clicks Set, rule 7) |
| Checks | `Get-ComposerBaseline`, `Assert-ComposerUnchanged` (rule 6) |
| Screenshots | `Save-ComposerShot`, `Save-ScreenShot`, `Save-RegionShot`, `Save-ElementShot`, `Save-PropertyRowShot` (unscaled crops for the manual), `Send-DocShot` (PUT `/img/<name>` to `tools/collect.py` on this VM, port 8092) |
| Manual pictures (`tools/composer/Shots.ps1`, dot-sourced after the module) | `Initialize-Shots` (the `raw\`, `doc\` and `hold\` folders), `Get-HouseTerms` (the house's names for the deny check, in memory only), `Save-PaneShot` (captures one pane, dialog or row, a window by its visible frame; refuses a crop that shows the title bar, the status bar or the tree), `Get-TextRegions`, `Set-TextReplacement` (paints a neutral text in the measured font), `Test-ShotText` (refuses a house name, an address that is not a placeholder, a MAC address or fan client id outside the documentation range, an e-mail address or cloud identity, a device number outside the neutral set), `Save-ShotResult` (to `doc\`, or to `hold\` with the reasons), `Invoke-ShotPlan`, `Export-ShotPlanFromDoc`, `Export-ShotTexts` (the per-picture text list) |

Connections and Programming can be changed with synthesized drags
("Learned 2026-10-27" below): a binding when the drag starts on the
selected device's own row in the top pane of Connections, a Script line by
dragging an action's green arrow into the Script. The verified method moves
with relative input (`MOUSEEVENTF_MOVE`); this module's `Invoke-MouseDrag`
steps with absolute `SetCursorPos` instead, so until the module has a
function for the verified method (the Windows session sends its working one
back for the repo), a brief that binds or programs spells the method out.

## Workflow

1. The coordinator writes a numbered brief (what to observe, what to click,
   what to report), with the standing-approval sentence of rule 8 and, when
   a build changes capabilities, the reboot of rule 10, and sends it to the
   Windows session.
2. The Windows session runs it and reports texts and screenshots.
3. The coordinator correlates with the driver's own output: the dev loop's
   shipped log while a dev build runs; in production only the properties
   and the Lua Output pane (rule 13). It records findings in
   [`design.md`](design.md), [`status.md`](status.md) and the issue, posts
   the round to GitHub Discussions (`tools/gh-discussion.py`, private data
   replaced by the placeholders), and continues.

Installing a release: `tools/deploy.py start` writes
`build/release/<tag>/BRIEF.md` ([`release-checklist.md`](release-checklist.md))
and the coordinator sends it as it is: the GitHub download URL of every
package and its sha256, the PowerShell that fetches them into
`C:\c4-mf\drivers\<tag>\` and checks them with `Get-FileHash`, the Composer
steps, what to read back, and the standing-approval sentence. The session
installs every package at once with Driver ▸ "Add or Update Driver or
Agent…", in place (rule 20), and reads back every device's `Driver Version`
and `Debug Mode` (and the properties the v1 contract adds to that list);
the coordinator records the result with `tools/deploy.py done --devices N`
or `failed --note`. A dev build or a feature-branch test build is the
exception (`CLAUDE.md`, Deploy): the coordinator serves the `.c4z` from
`build/release/` on port 8091 (`python3 -I -m http.server 8091 --bind
0.0.0.0 --directory build/release`, stopped afterwards), puts its sha256 in
the brief, and records the install with `tools/deploy.py record
--no-manifest`.

The Composer checklist ([`composer-checklist.md`](composer-checklist.md))
remains the list of things to verify; its steps are briefs for the Windows
session. The brief names the steps that are hard to undo (rule 2) and the
standing approval covers them (rule 8); only what needs the owner's hands
(a controller reboot from System Manager, rule 9; a keypad, the fan, the
phone) waits for him. Connections and Programming are not among them: the
session binds and writes Script lines by synthetic drag and reads the
result back (rule 18).

## Learned 2026-10-27: Connections and Programming by synthetic drag

Verified on the house by the Windows session (Composer Pro 3.4.2, OS
3.4.3), on the fan's keypad, during the test of the stock fan driver
(recorded in the Hue project, its issue #312). It corrects an earlier
finding of the Hue project, from 2026-10-22, that synthesized input cannot
make a connection: those attempts began in the lower list, where no drag
starts.

- **Connections: drag from the top pane.** Select the device whose
  connection is to be made: the top pane lists its own connection rows
  (for a keypad, its "\<button> Button Link" Control Inputs). Drag that
  row onto the matching connection's row in the lower list ("BUTTON_LINK
  Output Devices" for a Button Link) and the binding is made. A drag that
  starts in the lower list never begins, from the row's text or from its
  icon (no capture, `IDC_ARROW`); double-clicking a lower row does
  nothing, and the right-click menu of either row offers only Disconnect.
- **The drag that works**: relative moves through `SendInput` or
  `mouse_event` (`MOUSEEVENTF_MOVE`). Press, wait 300 ms, move at least
  10 px of real travel in the first steps, then about 30 steps of 20 ms to
  the target, hover 500 ms, release. Windows scales relative moves: eight
  1 px moves travelled 4 px, exactly the edge of the list's drag rectangle
  (`SM_CXDRAG`, 4 px either side of the press point), and started nothing.
  Once a drag has begun, `GetGUIThreadInfo` reports a capture window and
  the cursor is the no-drop (`IDC_NO`) or the drop cursor (rule 18).
- **Disconnect** asks "Are you sure you want to disconnect \<device A>
  from \<device B>?": it names the devices, not the connection, so the row
  right-clicked decides which binding goes; read both lists again
  afterwards.
- **A keypad button follows its link by itself.** Making a button's link
  switched that button's LED Behavior to Follow Connection; disconnecting
  did not switch it back. LED Behavior offers Follow Connection, Follow
  Load, Push/Release and Programmed; Button Behavior offers Load On, Load
  Off, Toggle Load and Keypad.
- **Test one binding before building on a driver's links.** The stock fan
  driver's BUTTON_LINK connections bound normally and did nothing, neither
  for presses nor for the LED: a driver can declare links it does not
  implement. That is a bug of that driver, not a Composer limit, and the
  reason for this project.
- **Programming: drag an action's green arrow into the Script**, with the
  same drag (the capture holds, the drop cursor shows). A command nests
  inside an If only when dropped on the If's blue "?" icon, and each
  further drop there appends it as the If's last child; dropped on the If
  row's text, it lands at top level, before the If (upper half of the row)
  or after it (lower half).
- **The right-click menu of a Script line**: Move Up, Move Down, Disable
  Event, Disable Item (Enable Item once disabled), Insert Comment, View Code
  Item Description, Copy All, Copy Selected, Paste, Find and Replace,
  Delete, Delete All, Change to Customer. Delete asks "Are you sure you want
  to delete the code item: \<text>", Delete All "Are you sure you want to
  delete all code items?". A disabled line shows a grey arrow with a small
  red ×; disabling an If greys its children.
- **Copy All reads a Script back**: the clipboard gets the whole script as
  XML, `<cutitems>` holding `<item>` elements, each with its Type, its
  Description and its child items nested inside, so the nesting can be
  checked exactly (rule 18).
- **Keypad LED commands**: "Set LED On" and "Set LED Off" only choose the
  colour a button shows when lit or dark (the line reads "Set \<button>
  LED on the \<keypad> to \<colour> when on"); "Use the on color for
  \<button>" and "Use the off color for \<button>" light and darken it,
  with the button's LED Behavior on Programmed; "Set LED Current" shows a
  colour now. These are the commands of the house's LED workaround
  ([`status.md`](status.md)).
- **The Programming view's lists are read from screenshots only** (rule
  19): a cross-process list-view read there crashed Composer on
  2026-10-26.
- **The mouse wheel changes property values** (rule 17): over a property
  page it stepped the drop-down under the pointer, and Engraving Size on
  the project root's Lighting Defaults went from Standard to Large (set
  back afterwards). Scroll with clicks on the scrollbar only.

## History

No round of this project yet (2026-10-27). The rounds that made the rules
above, from the first reads of Composer's pages on 2026-10-21 to the
synthetic drags of 2026-10-27, are recorded in the Hue project's
[`docs/composer-remote.md`](https://github.com/corytron/c4-hue-driver/blob/main/docs/composer-remote.md).
This project's rounds are numbered from 1 here, each also posted to GitHub
Discussions as it arrives.
