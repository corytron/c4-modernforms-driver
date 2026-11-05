# Composer checklist

What only Composer, a Navigator, a keypad or the Modern Forms app can show,
as steps for the owner; each step is also a brief for the Windows session
([`composer-remote.md`](composer-remote.md)). Every step ends in a **Done**
line. It reads **Done: open** until the step has been run on the house; then
it says when and what the step showed, in the words of that day. What runs on
the house and what is open overall is [`status.md`](status.md); the
engineering record behind each result is [`design.md`](design.md). The names
and exact texts a step quotes are those of the contract
([`v1-design.md`](v1-design.md), sections 2.5 to 2.7 and 7) and of the
driver's Documentation tab.

**This version is written for the first full-featured test build** (the
build of the M3 split, [`v1-design.md`](v1-design.md#13-m3-build-split)). No
build of this driver has been checked on the house yet, so every step is open.
Since #45 (2026-11-04) it has no migration steps: the Migration Report they
read is gone from the driver, and the house's cutover from the stock driver
is recorded in [`migration-design.md`](migration-design.md).

## Before you start

- **Who does what.** The Windows session does every click and every read in
  Composer from this text; the coordinator does anything that needs a
  command, on the VM. Your hands are needed only where a step says **By
  hand**: a keypad button or a Navigator tile, the remote or the wall
  control, the fan's power at the wall, the Modern Forms app, a look at an
  LED. **No step hands you a command**, and none asks for more than a minute
  of your time: where the driver itself needs longer (it notices a missing
  fan after about 45 seconds), the step says so and the Windows session
  reads the result, not you.
- **Briefs.** A brief made from a step carries the standing-approval sentence
  of [`composer-remote.md`](composer-remote.md#rules-for-the-windows-session)
  (rule 8) and names the hard-to-undo steps inside it: installs, bindings and
  Disconnects, a Set on a property, a rename of an item or the delete of a
  throw-away device (steps 7 and 48) and the throw-away programming scripts
  of step 35.
- **The test buttons.** Since the cutover (2026-11-04) the house keypad's
  fan and light buttons are bound to this driver's links
  ([`status.md`](status.md)), so the steps press those buttons themselves:
  Low to High and Off for the fan links, Up and Down for the light. Nothing
  is borrowed or restored. A press also runs what is left of the button's
  programming (Low's and High's Double Tap set Level 1 and Level 6); say so
  before you press. When the build allows it, the Windows session can press
  a bound link without hands (K7 of
  [`v1-design.md`](v1-design.md#11-hardware-checks-before-the-first-install));
  the LED steps still need your eyes.
- **Release builds only, except the first test.** A release reaches the house
  from GitHub ([`release-checklist.md`](release-checklist.md)): the
  coordinator sends the Windows session the install brief, which downloads
  the package of the release from its GitHub URL, checks its checksum and
  installs it (step 1). The first full-featured test build may instead be a
  feature-branch build served from the VM for that test; a release replaces
  it afterwards.
- **Capability changes need a reboot.** If an install makes Composer ask
  "Restart Director?", answer Yes, but it does not restart Director: the
  device keeps its old capabilities until you reboot the controller from
  System Manager (Tools > System Manager; it runs elevated, so only you can
  operate it). Then choose File » Refresh Navigators. Builds that change only
  Lua or connections take effect at once. Composer has no "Restart
  Director" command of its own. A new device is expected to take its
  capabilities with no reboot; step 1 is where that is seen.
- **Logs.** A device's Lua output is in its **Lua** tab in Composer. When a
  step asks for it, set that device's `Debug Mode` to On first and back to
  Off afterwards. Composer shows only the lines that arrive while the tab is
  open.
- **Texts.** A quoted property or result text is the exact text to expect.
  `<…>` stands for a value that varies (a time, an address, a build number).
  Reports use the placeholders of
  [`scaffold-design.md`](scaffold-design.md#2-placeholders-the-repository-is-public):
  fan `10.0.2.151`, second fan `10.0.2.152`, client id `MF_00005E005301`,
  "Example Room".
- **Put everything back.** At the end the settings these steps change read
  as they did: Default On Brightness 100, the fan item's Preset Level
  Level 3, every `Speed N Link Also Lit At` at `No other speed`, `Follow
  Address Changes` On, `Fan Address` the fan's address, the test
  buttons restored, `Debug Mode` Off, and the two items' names as they were
  before step 6 (the driver changes them in steps 6 and 7; they are put back
  by hand in step 48).

The house this version was written for (2026-11-04, before the first
install): one Modern Forms fan on the stock driver
`wac_mf_fan_and_light_controller(v4).c4z`, a keypad driven by programming
(button scripts that set the speeds, LED scripts, a one-second settle Timer
agent) with no spare button, the throw-away M1 probe still in a test room,
and nothing of this driver installed. The same day v1.0-beta.1 was
installed, the keypad moved to its links and the stock device was deleted
(deploy issue #30); the house as it is now is [`status.md`](status.md).

## A. Install and update

1. **Install and add the device.** Driver » "Add or Update Driver or Agent…",
   select `modernforms_fan.c4z` of the build, Open. Then add **Modern Forms
   Fan** to a room (the fan's room, as
   [`migration-design.md`](migration-design.md#3-phases) Phase 1 has it).
   - **Expect:** "Update Succeeded: Drivers or agents were successfully
     updated: modernforms_fan.c4z" (the text Composer Pro 3.4.2 shows for the
     Hue drivers) and **no** "Restart Director?". Two tree items: **Modern
     Forms Fan** (the fan, the parent) and **Modern Forms Fan Light** under
     it, with Control4's standard fan and light icons. On the fan item:
     `Driver Version` the build number, `Debug Mode` Off, `Poll Interval (s)`
     15, `Status` `Not set up: Find Fans, or enter the fan's address in Fan
     Address`. File » Refresh Navigators.
   - **Done:** open.
2. **The update is in place.** Run this one last, when a second build exists.
   Install it over the first the same way; never delete and re-add the
   device: a re-added device has a new device id and an empty store, and its
   connections and every programming line that names it are gone.
   - **Expect:** `Driver Version` shows the new build; `Fan Address`, `Poll
     Interval (s)`, every `Speed N Link Also Lit At`, `Follow Address
     Changes`, `Fan ID`, `Debug Mode`, the preset speed and the light's
     Default On Brightness read as before (an update from a build without
     `Follow Address Changes` shows the new row as `On`);
     `Status` reads `Online: …` again within a minute; `Keypad Links` still
     lists every binding and the Navigators still show both tiles.
   - **If Composer asked "Restart Director?"**: reboot the controller as
     described under "Before you start", wait until Composer has Director
     again, choose File » Refresh Navigators, then check this step again.
   - **Done:** open.

## B. Adding the fan

3. **Fan Address.** Select the fan item, **Properties** tab. In `Fan Address`
   type the fan's address (`10.0.2.151`) and click the row's **Set**.
   - **Expect:** `Status` `Waiting for the fan at 10.0.2.151`, then within a
     few seconds `Online: fan …, light …` with the fan's real state (for
     example `Online: fan speed 3, light 40 %`). `Last Action` `Learned fan
     MF_00005E005301 (Gen 3) at 10.0.2.151`. `Fan ID` `MF_00005E005301 (MAC
     00:00:5e:00:53:01)`. No further click was needed to pin the fan. The two
     tree items keep the names they had: the first contact renames nothing.
   - **Done:** open.
4. **A bad entry, an empty entry, the right entry again.** Set `Fan Address`
   to `fan.local`, then to nothing, then back to the fan's address.
   - **Expect:** `Status` `Fan Address "fan.local" is not an IPv4 address`
     (nothing is sent); then `Not set up: Find Fans, or enter the fan's
     address in Fan Address`, and the row stays empty (the driver never fills
     an empty `Fan Address` by itself, #39); then `Online: …` again with `Fan
     ID` unchanged (the identity was kept) and `Last Action` still the line
     of step 3.
   - **Done:** open.
5. **Find Fans.** Actions tab: **Find Fans**. Read `Found Fans` and `Last
   Action` after about 5 seconds.
   - **Expect:** `Last Action` `Found 1 fan: pick it in Found Fans, then Use
     Selected Fan` (`Found 2 fans: pick one in Found Fans, then Use Selected
     Fan` if another fan is awake); `Found Fans` holds `MF_Fan_005301 at
     10.0.2.151 (this device's fan)`, the instance name ending in the last
     six digits of the MAC. If it says `No Modern Forms fan answered on this
     network` or `Find Fans could not send its query on this controller`,
     record the exact text and the controller's OS.
   - **Done:** open.
6. **Use Selected Fan.** First read and note the two items' names in the
   System Design tree. Pick the entry and click **Use Selected Fan**; read
   `Last Action` and the tree again after about 3 seconds. Then clear `Fan
   Address` (Set), click **Use Selected Fan** with nothing picked, and type
   the address back (Set).
   - **Expect:** first `Already using fan MF_00005E005301 at 10.0.2.151` and
     the pick cleared, and about 2 seconds later the same line with one
     ending. `…; items renamed` when both items still had the names a new
     device is created with (**Modern Forms Fan** and **Modern Forms Fan
     Light**): the tree now shows **Aviator 5** and **Aviator 5 Light**.
     `…; names kept` when either item has another name (the house's own
     device, after the cutover: **Fan** and **Fan Light**): neither changed.
     Not `…; not renamed`: the model `1811-5-54` has a name. Then `Nothing to
     use: pick a fan in Found Fans, or enter Fan Address` (no ending: nothing
     was accepted, and the names stay as they are); then `Online: …`. When
     this click renamed the items, record what step 7 asks under (b) as well.
   - **Done:** open.
7. **Name Items After Fan, and the guard.** On the device of step 6. On the
   house's own device this renames the items the family knows as **Fan** and
   **Fan Light** until step 48 puts them back; the brief says whether the
   owner agrees, and if not the step runs on a second device added to a test
   room and deleted afterwards (step 6 is repeated on it first). (a) If step
   6 ended in `; items renamed`, rename the fan item by hand to `Fan (new)`
   (the name a cutover gives it) and click **Use Selected Fan** again; if
   step 6 ended in `; names kept`, skip (a). (b) Click **Name Items After
   Fan** and read `Last Action` and the tree once a second for 10 seconds.
   (c) Click it again. *By hand, optional, blocking nothing:* the fan's tile
   name on the phone before and after File » Refresh Navigators.
   - **Expect:** (a) `Already using fan MF_00005E005301 at 10.0.2.151`, and
     about 2 seconds later the same line ending `; names kept`; neither item
     changed, the light's included (both or neither). (b) Within about 3
     seconds `Items named Aviator 5 and Aviator 5 Light`, the tree shows
     **Aviator 5** and **Aviator 5 Light**, and there is no dialog and no
     "Restart Director?". Record the seconds until the tree showed the names,
     whether the tree repainted by itself or only after File » Refresh
     Navigators, whether the selected item and an open Properties page
     survived, and whether any other name in the project changed. (c) `Items
     already named Aviator 5 and Aviator 5 Light`, and nothing in the tree
     moves.
   - **Done:** open.

## C. Properties, the Documentation tab and the Navigators

8. **The rows.** Read the fan item's whole **Properties** tab, in order.
   - **Expect:** `Driver Version` the build, `Status` `Online: …`, `Last
     Action`, `Fan Address` the address, `Found Fans`, `Follow Address
     Changes` `On` (a list of `On` and `Off`; #39), `Fan ID`, `Fan Model`
     (for example `Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30,
     Breeze`: the product name of the model number the fan reports; a model
     the driver has no name for would read `Gen 3, fan <model>, light kit
     …`), `Firmware` (`<version> (motor <version>) since <date>`), `Last Seen`
     (`<date time>, answered in <s> s`, moving on every 10 seconds at most),
     `Last Change By` empty until the fan changes from outside, `Fan
     Automations` (`None` or `Active: …`), `Poll Interval (s)` 15, `Keypad
     Links` (`0 of 12 links bound`), `Speed 1 Link Also Lit At` to `Speed 6
     Link Also Lit At` all `No other speed`, `Speed LED Colors` `Keypad's
     own`, `Speed 1 LED Color` to `Speed 6 LED Color` `0,0,255` and `Speed LED
     Off Color` `0,0,0` (V27, #31), `Debug Mode` Off, and a release build has
     no `Dev Server` or `Dev State` row. No `Migration` or `Stock Device` row
     (gone since #45).
   - **Done:** open.
9. **The Actions tab.**
   - **Expect:** six actions in this order: `Find Fans`, `Use Selected Fan`,
     `Name Items After Fan`, `Reboot Fan`, `Turn Off Away Mode`, `Turn Off
     Adaptive Learning` (no `Migration Report` since #45).
   - **Done:** open.
10. **The Documentation tab.** Open the fan item's **Documentation** tab,
    scroll to the end.
    - **Expect:** the manual renders (headings, tables, readable text); a
      click on a chapter in the contents scrolls to it; the end shows the
      changelog and the non-affiliation lines.
    - **Done:** open.
11. **Programming, read only.** Open Programming and look at the fan item's
    events and conditions; do not add anything.
    - **Expect:** the fan proxy's own events and conditions, and the driver's
      two events `Fan Offline` ("When <name> stops answering on the
      network") and `Fan Online` ("When <name> answers on the network
      again"), and the condition "Fan is online". The light item lists its
      own light events.
    - **Done:** open.
12. **The fan on a Navigator.** *By hand*, after File » Refresh Navigators:
    open the fan on a Navigator or in the Control4 app. Tap each of Level 1
    to Level 6, then off.
    - **Expect:** the tile first shows the fan's real speed, in the names
      `Level 1` to `Level 6`; the fan follows each tap within about a
      second; the tile and `Status` follow; off stops the fan.
    - **Done:** open.
13. **On, Toggle and the preset.** With the fan off, tap the tile to turn it
    on. Then, in Composer, change the fan item's **Preset Level** to Level 4,
    turn the fan off and on again, and set the Preset Level back to Level 3.
    - **Expect:** on goes to Level 3 (the default preset), then to Level 4
      after the change, and to Level 3 again at the end. (On a fan that
      already runs, an On from programming changes nothing; a throw-away
      script of step 35 may show it.)
    - **Done:** open.
14. **Direction.** If the Navigator offers a direction control, set reverse and
    then forward again.
    - **Expect:** the fan reverses and reverts after its motor has turned
      around; `Status` shows `reverse` while it runs in reverse; the fan keeps
      answering (`Last Seen` keeps moving). If the fan drops off the Wi-Fi,
      record the model and stop here.
    - **Done:** open.
15. **The light on a Navigator.** *By hand*: tap the light's tile; set the
    Default On Brightness on the light item's settings page to 50 and tap it
    off and on; drag the slider from 40 to 70 and let go; tap off; set the
    Default On Brightness back to 100.
    - **Expect:** the first tap turns the light on at the Default On
      Brightness (100 on this house); after the change it comes on at 50
      (record it if a tile tap ignores the setting, which depends on the
      command Control4 sends); the slider ends at 70 within a couple of
      seconds, in a few jumps and without a fade; off turns it off and the fan
      keeps its level.
    - **Done:** open.
16. **The log.** Set `Debug Mode` to On (Set), tap Level 3 and then off on a
    Navigator, read the fan item's Lua tab, set `Debug Mode` back to Off.
    - **Expect:** a line for each request and answer (a command for speed 3,
      its answer with the fan's state and the time it took), the proxy message
      and no `[ERROR]` line, traceback or refusal; the lines hold no e-mail
      address, Wi-Fi name or client id (only its last four digits).
    - **Done:** open.

## D. Fan speed links (the driver's own Button Links)

17. **The links are listed.** Connections: select the fan item.
    - **Expect:** under its Control Outputs the nine fan links **Fan Off**,
      **Fan Speed 1** to **Fan Speed 6**, **Fan Toggle** and **Fan Cycle
      Button Link**, and the three light links **Light Top**, **Light
      Bottom** and **Light Toggle Button Link**; the light item lists the
      same twelve in this per-item view. In the lower list of a keypad's
      Connections they appear under the fan item only (seen with the probe
      on 2026-10-27).
    - **Done:** open.
18. **Bind a speed link.** Select the test button's keypad and drag the
    button's row from the top pane onto **Fan Speed 3 Button Link**, under the
    fan item, in the lower "BUTTON_LINK Output Devices" list (the drag of
    [`composer-remote.md`](composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag);
    read both lists afterwards).
    - **Expect:** both lists show the binding; the button's LED Behavior
      reads Follow Connection (the binding sets it, seen with the probe on
      2026-10-27); `Keypad Links` reads `1 of 12 links bound` and `Fan Speed
      3: <keypad> (<id>)`; the LED is already right for the fan's state.
    - **Done:** open.
19. **A press.** Press the bound button once (with the fan at another speed).
    - **Expect:** the LED lights at once, before the fan moves; the fan runs
      at Level 3 within about a second; the tile and `Status` show it; the
      LED stays lit.
    - **Done:** open.
20. **A hold.** Hold the same button for about 2 seconds.
    - **Expect:** one action only: the fan stays at Level 3, no repeat, nothing
      on release, the LED lit.
    - **Done:** open.
21. **The ends of the range.** Disconnect step 18's binding, then bind the
    test button to **Fan Speed 1 Button Link**, press it once, and do the same
    with **Fan Speed 6 Button Link** (the other speed links are pressed in
    steps 30, 31, 32 and 34).
    - **Expect:** the fan runs at Level 1 and at Level 6 within about a second
      of each press, the LED lit at once and the tile following.
    - **Done:** open.
22. **Fan Off.** Disconnect the previous binding, bind the test button to
    **Fan Off Button Link** and press it.
    - **Expect:** the fan stops; the LED is lit while the fan is off and
      darkens at once when the fan is started from a Navigator.
    - **Done:** open.
23. **Fan Toggle and Fan Cycle.** One at a time (disconnect the previous
    binding first): bind the test button to **Fan Toggle Button Link** and
    press it twice; then to **Fan Cycle Button Link** and, with the fan off,
    press it seven times.
    - **Expect:** Toggle: off goes on at the preset speed (Level 3), on goes
      off. Cycle: Level 1 to Level 6 on the first six presses, Level 1 again
      on the seventh; both LEDs lit while the fan is on.
    - **Done:** open.
24. **Disconnect.** Right-click the binding of each link used so far and
    choose Disconnect; read both lists.
    - **Expect:** the prompt names the two devices; both lists show the link
      unbound; `Keypad Links` reads `0 of 12 links bound`; set the button's LED
      Behavior back to Programmed (a Disconnect does not restore it) when the
      button is borrowed (R-K).
    - **Done:** open.

## E. Light links (light_v2)

25. **Light Top.** Bind the test button to **Light Top Button Link**. Tap it
    with the light off; tap it with the light on at a low level; hold it for
    about 2 seconds with the light on; hold it for about 2 seconds with the
    light off.
    - **Expect:** a tap turns the light on at the Default On Brightness (also
      from a low level); a hold brightens it toward 100 in small steps (twice
      a second at most; about 5 seconds for the whole range) and stops where
      you let go; from off a hold turns the light on at 1 % and brightens
      from there; the LED is lit while the light is on; a tap within a second
      after a hold is ignored.
    - **Done:** open.
26. **Light Bottom.** Bind **Light Bottom Button Link**. Tap it with the light
    on; hold it with the light on; hold it with the light off.
    - **Expect:** a tap turns the light off; a hold dims it toward 1 % and
      stops where you let go; a hold while it is off does nothing; the LED is
      lit while the light is off and dark while it is on.
    - **Done:** open.
27. **Light Toggle.** Bind **Light Toggle Button Link**; tap and hold it with
    the light off and on.
    - **Expect:** a tap switches the light the other way (on at the Default On
      Brightness); a hold brightens while the light is off (from 1 %) and
      dims while it is on; the LED is lit while the light is on.
    - **Done:** open.
28. **How a hold looks.** *By hand*, during step 25's hold: does the
    brightening look smooth enough, or like a staircase? Record the word. (The
    contract's K15; whether it needs changing is the owner's call.)
    - **Done:** open.

## F. Keypad LEDs (Follow Connection)

29. **Follow Connection by itself.** Read the LED Behavior of every bound
    button, then disconnect one.
    - **Expect:** it reads Follow Connection for every bound button, set by
      the binding itself (seen with the probe on 2026-10-27 and again on
      2026-11-04); disconnecting does not switch it back.
    - **Done:** open.
30. **Only the active speed is lit.** With a test button on **Fan Speed 3** and
    another on **Fan Speed 5**: set the fan to Level 3 from a Navigator, then
    press the Level 5 button.
    - **Expect:** at Level 3 only the Level 3 button is lit; pressing Level 5
      darkens it and lights the other at once, with no settle delay and no
      programming; the LEDs follow a change from the Modern Forms app, the
      remote or the wall control the same way (section G).
    - **Done:** open.
31. **Speed N Link Also Lit At.** With the test button on **Fan Speed 4**,
    press it, set `Speed 4 Link Also Lit At` to `Speed 5` and click **Set**,
    set the fan to Level 5 from a Navigator, then set the row back to `No
    other speed`.
    - **Expect:** the press runs the fan at Level 4 with the LED lit; the
      button stays lit at Level 5 while the row says `Speed 5`, and goes dark
      at once when it is set back; the row's own speed (`Speed 4`) means the
      same as `No other speed`.
    - **Done:** open.
32. **Bound while the fan is at that speed.** Disconnect and bind the test
    button on **Fan Speed 3** again while the fan runs at Level 3, then at
    Level 5.
    - **Expect:** the LED is right within about a second of the binding
      (lit at Level 3, dark at Level 5); the driver answers the keypad's
      request for colours (seen as `REQUEST_BUTTON_COLORS` with the probe).
    - **Done:** open.
33. **Colours.** *By hand*: with `Speed LED Colors` on `Keypad's own`, the
    fan buttons are lit in the colours set on the keypad itself (the driver
    sends none on the fan links); the light's Top and Toggle buttons are lit
    blue while the light is on, the Bottom button blue while it is off (the
    settings page's defaults). Then set `Speed 1 LED Color` to blue
    (`0,0,255`) and `Speed 6 LED Color` to `255,96,0`, then `Speed LED
    Colors` to `Per speed`, and move the fan to Levels 1 and 6. In Composer
    Pro 3.4.2 a colour row's R:, G: and B: boxes are read-only: its swatch
    opens Windows' Color dialog (Define Custom Colors, then Red, Green and
    Blue, then OK), and the row's Set appears only when the value changed.
    - **Expect:** the bound button lit at Level 1 shows blue and the one lit
      at Level 6 orange; changing a colour while its button is lit repaints it
      at once; going back to `Keypad's own` leaves the last colours on the
      keypad until its own are set.
    - **Done:** open.
34. **A double tap.** Double tap the test button bound to **Fan Speed 2**.
    - **Expect:** the fan ends at Level 2, the LED lit, `Status` online (a
      double tap is two presses and acts twice). Whether the keypad's own
      Double Tap event fires on a bound button is still open
      ([`migration-design.md`](migration-design.md#8-open-items), item 5):
      the cutover sitting pressed nothing, so record it here.
    - **Done:** open.

## G. Changes made elsewhere

35. **Three throw-away scripts.** The Windows session puts the same one-line
    script, with one harmless and visible effect of its choosing, on the fan's
    speed-changed event, on **Fan Offline** and on **Fan Online** (three
    drags, each read back with Copy All). They stay until step 47 and let
    steps 36, 37, 39 and 41 see the events fire.
    - **Expect:** each of the three events lists its one line, enabled.
    - **Done:** open.
36. **The Modern Forms app.** *By hand*: change the speed, the light and the
    direction in the app, one change each.
    - **Expect:** each change reaches the Navigator tile and the keypad LEDs
      within the poll interval (15 seconds, sooner while the 2-second polling
      of the 20 seconds after a change is open); the speed-changed script ran
      for the speed change; `Last Change By` reads `Modern Forms app or
      another local client at <time>` (or the cloud text `Modern Forms cloud
      (app away, voice assistant)`: record which); a quick series of changes
      ends on the last one.
    - **Done:** open.
37. **The remote and the wall control.** *By hand*: change the speed, the light
    and the direction with the remote, and the same with the wall control.
    - **Expect:** as step 36, the script included, as it does for a change
      from Control4; `Last Change By` reads `Remote or wall control at <time>`
      or `Outside Control4 (source not reported)`: record which each one gives
      (the contract's K16), and whether Breeze changes the speed the driver
      reports.
    - **Done:** open.
38. **The fan's own automations.** *By hand*: turn **Away mode** on in the
    Modern Forms app. In Composer read `Fan Automations`, click **Turn Off Away
    Mode**, then click it again; the same for adaptive learning.
    - **Expect:** `Fan Automations` reads `Active: away mode` within the poll
      interval; `Last Action` `Away mode turned off (the Modern Forms app can
      turn it on again)`, and the app shows it off; the second click `Away
      mode is already off`; for adaptive learning `Adaptive learning turned
      off (the Modern Forms app can turn it on)` and `Adaptive learning is
      already off`. No schedule or timer is touched.
    - **Done:** open.

## H. Offline, rebooting, the wrong fan, address and firmware

39. **Power off.** *By hand*: switch the fan's power off at the wall (the wall
    switch or the wall control's pull tab), press a bound speed button one
    time straight away, and leave the power off for a minute at most. The
    Windows session reads `Status` after about 50 seconds; your part is the
    switch and one press.
    - **Expect:** the LED lights at once and goes back within about 10
      seconds when the request fails (the press is tried once and dropped, so
      it is not delivered when the power returns). After about 50 seconds
      `Status` `Not answering at 10.0.2.151 since <time>; showing last state`;
      the `Fan Offline` event fired once (step 35's script ran once; the
      `Online` variable reads 0); the light's controls are greyed out on the
      Navigator; the fan tile and the keypad LEDs keep their last state.
      `Fan Address` still reads the fan's address and `Last Action` has no
      `Followed fan …` line: the driver's search for a fan that moved
      (#39) finds it nowhere and changes nothing.
    - **Done:** open.
40. **Reboot Fan while it is away.** While the power is still off and `Status`
    says `Not answering`, click **Reboot Fan**, then click **Name Items After
    Fan**.
    - **Expect:** `Last Action` `Reboot not sent: the fan is not answering
      (power it off for 10 s)`; then, from the model the driver remembers,
      `Items already named Aviator 5 and Aviator 5 Light` (`Items named …` if
      step 7 did not run): a fan that does not answer makes no difference to
      the naming.
    - **Done:** open.
41. **Power on.** *By hand*: switch the power back on. The Windows session reads
    `Status` every 10 seconds for a minute and once more a minute later (the
    fan needs time to start and the driver asks once a minute while it is
    away; record how long it took, the contract's K17). This step is an
    observation, not a gate: it does not block the others.
    - **Expect:** `Online: …`; `Fan Online` fired once (step 35's script ran
      once); the light's controls back; **nothing was re-sent**: the fan comes
      up in its own state, not at the speed the press of step 39 asked for.
    - **Done:** open.
42. **Reboot Fan.** With the fan answering, click **Reboot Fan**, then click it
    again straight away.
    - **Expect:** `Last Action` `Reboot sent to the fan's Wi-Fi module at
      <time>` and `Status` `Rebooting the fan's Wi-Fi module (sent <time>)`; the
      second click `Reboot already sent at <time>; waiting for the fan`; then
      `Online: …` again and no `Fan Offline`. Record the time until the fan
      answered, and whether the motor or the light changed (the contract's
      K18).
    - **Done:** open.
43. **The wrong fan.** *Needs a second Modern Forms fan on the network*
    (`10.0.2.152`); with only one, this step stays open and the specs of the
    model carry the refusal. Set `Fan Address` to the second fan's address.
    - **Expect:** `Status` `Another fan (...<last four digits>) answers at
      10.0.2.152; nothing is sent`; `Fan Offline` fires; a press on a bound
      button does nothing and its LED keeps its state; `Fan ID` is unchanged.
      `Fan Address` keeps the typed `10.0.2.152` and no `Followed fan …`
      line appears, although the first fan still answers at its own address:
      an address you type wins until the pinned fan answers there (#39).
      Set the first fan's address back: `Online: …` and `Fan Online`. Optional
      and only if meant: pick the second fan in `Found Fans` and click **Use
      Selected Fan** (`Now using fan MF_00005E005302 (was MF_00005E005301)`;
      links and programming stay), then point the device back at the first fan
      the same way.
    - **Done:** open.
44. **Not a fan.** Set `Fan Address` to another device on the network that
    answers on port 80 (any web page: the router's, a printer's), then back.
    - **Expect:** `Status` `<address> answers, but not as a Modern Forms fan;
      nothing is sent` (or, if that device answers every request with a page,
      `No usable answer from <address> since <time>; state unknown` after
      about 45 seconds: record which); `Fan Offline` fires; `Fan Address`
      keeps the typed address (no `Followed fan …` line, #39); the fan's own
      address back restores `Online: …`.
    - **Done:** open.
45. **A new address, followed by the driver (#39).** Optional and never
    blocking; the driver needs a minute or two, which the Windows session
    waits out. (a) *By hand, only if the router can do it cheaply:* give the
    fan another address (change its DHCP reservation), then switch the fan's
    power off at the wall for 10 seconds and on again so that it takes the
    new address. The Windows session reads `Status`, `Fan Address` and `Last
    Action` every 15 seconds for 3 minutes. Afterwards put the reservation
    back if you changed it, and read the same rows again until the driver has
    followed the fan back. (b) *A typed address wins.* Set `Fan Address` to a
    free address of the network on which nothing answers, read `Status`,
    `Fan Address` and `Last Action` after about a minute, then set the fan's
    own address back. (c) Set `Follow Address Changes` to `Off` (Set), then
    back to `On` (Set).
    - **Expect:** (a) `Status` `Not answering at 10.0.2.151 since <time>; …`
      (or `Another fan …` if something took the old address) for about a
      minute, then `Waiting for the fan at 10.0.2.152` and `Online: …`;
      `Fan Address` now `10.0.2.152`, written by the driver; `Last Action`
      `Followed fan MF_00005E005301 to 10.0.2.152 (was 10.0.2.151)`; `Fan
      Offline` and `Fan Online` fired once each (step 35's scripts, while
      they are there); `Fan ID`, `Found Fans`, the item names and the
      bindings unchanged. Record the seconds from the power coming back to
      `Online: …`. Putting the reservation back gives a second `Followed fan
      …` line, back to the old address. If nothing is followed within 3
      minutes, record `Status` and `Last Action` and click **Find Fans**:
      whether the fan is listed at its new address tells a network that
      keeps multicast from the controller apart from a driver fault. (b)
      After about 50 seconds `Status` `Not answering at <free address> since
      <time>; showing last state` and `Fan Offline`; `Fan Address` keeps the
      typed address and no `Followed fan …` line appears, although the fan
      answers at its own address; then `Online: …` and `Fan Online` once the
      fan's own address is back. (c) Nothing visible changes, the row reads
      `On` at the end, and the Lua tab shows no `[ERROR]` line. Without (a)
      the specs carry the follow itself (`fan_driver_spec`).
    - **Done:** open.
46. **A firmware change.** Parked, never blocking: after the next firmware
    update of the fan, `Firmware` reads `<version> (motor <version>) since
    <date>, was <old version>` and the device works as before.
    - **Done:** open.

## I. Putting everything back

47. **Delete the throw-away scripts.** Delete the three scripts of step 35,
    one line at a time (the prompt "Are you sure you want to delete the code
    item: …" names the line).
    - **Expect:** Programming shows nothing of them; every other script is as
      before the first binding (Copy All equal to the files saved then).
    - **Done:** open.
48. **Put the settings back.** Default On Brightness 100, the fan item's
    Preset Level Level 3, every `Speed N Link Also Lit At` at `No other
    speed`, `Follow Address Changes` On, `Fan Address` the fan's address
    (after step 45 (a), the address it was followed to is right), `Debug
    Mode` Off; the restore check R-K on any borrowed button
    that is still open; the two items' names back to what step 6 noted, by
    hand in Composer (**Fan** and **Fan Light** on the house; a throw-away
    device from step 7 is deleted instead), then File » Refresh Navigators.
    Then read the fan item's properties once more.
    - **Expect:** the rows read as in step 8; the item names are as before
      step 6; the keypad is as before step 18.
    - **Done:** open.

## What to paste back

For each step: the property texts as shown, what the Navigator, keypad,
fan or light did, the times where asked, and the Lua output of the device a
step names (its Lua tab in Composer). When something differs from the
expectation, the exact wording matters: it tells us which code path ran.
Replace addresses, MAC addresses, fan ids and room names with the
placeholders of [`scaffold-design.md`](scaffold-design.md#2-placeholders-the-repository-is-public).
