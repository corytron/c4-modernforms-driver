# Composer checklist

What only Composer, a Navigator, a keypad or the Modern Forms app can show,
as steps for the owner; each step is also a brief for the Windows session
([`composer-remote.md`](composer-remote.md)). A **Done** line under a step
says when it was checked on the house and what it showed, in the words of
that day; **Open** means it has not been checked yet. What runs on the
house and what is open overall is [`status.md`](status.md); the engineering
record behind each result is [`design.md`](design.md).

**A skeleton (2026-10-27), to be completed by the v1 contract.** No build of
this driver exists to check yet. The sections below are the checks the
driver must pass; the v1 contract fills in the property names, the action
names and the exact texts to expect, which are left as `<…>` until then.

## Before you start

- **Release builds only.** A release reaches the house from GitHub
  ([`release-checklist.md`](release-checklist.md)): `tools/deploy.py start`
  writes the brief, and the Windows session downloads the package of the
  release from its GitHub URL (checksum checked) and installs it (step 1).
  A development build goes on the house only when the developer asks for a
  test, and a release replaces it afterwards.
- **Capability changes need a reboot.** If an install makes Composer ask
  "Restart Director?", answer Yes, but it does not restart Director: the
  device keeps its old capabilities until you reboot the controller from
  System Manager (Tools > System Manager; it runs elevated, so only you can
  operate it). Then choose File » Refresh Navigators. Builds that change only
  Lua or connections take effect at once. Composer has no "Restart
  Director" command of its own.
- **Logs.** A device's Lua output is in its **Lua** tab in Composer. When a
  step asks for it, set that device's `Debug Mode` to On first and back to
  Off afterwards.
- A quoted property or result text is the exact text to expect; `<…>`
  stands for a value that varies, or for a text the v1 contract has not
  written yet. Where a step does not quote, paste what you see.

The house on 2026-10-27 ([`status.md`](status.md)): one Modern Forms fan on
the stock driver `wac_mf_fan_and_light_controller(v4).c4z`, a keypad driven
by programming (button scripts that set the speeds, LED scripts, a
one-second settle Timer agent), and nothing of this driver installed.

## A. Install and update

1. Driver » "Add or Update Driver or Agent…", select `modernforms_fan.c4z`
   of the release, Open. Expect "Update Succeeded: Drivers or agents were
   successfully updated: modernforms_fan.c4z" (the text Composer Pro 3.4.2
   shows for the Hue drivers), and within a minute every Modern Forms Fan
   device showing the new `Driver Version`. A right-click "Update Driver" is
   only for reloading the same version ("Versions are equal. Do you want to
   overwrite…?").
   - **Open.**
2. The update is **in place**. Never delete and re-add the device: a
   re-added device has a new device id and an empty store, and its
   connections and every programming line that names it are gone. Expect
   the device's properties to read as before the update, `Debug Mode`
   unchanged.
   - **If Composer asked "Restart Director?"**: reboot the controller as
     described under "Before you start", wait until Composer has Director
     again, choose File » Refresh Navigators, then check this step again.
   - **Open.**

## B. Adding the fan (the v1 contract)

3. Add the Modern Forms Fan device to its room and give it the fan's
   address the way the v1 contract says (`<property or action>`). Expect
   `<status text>` and the fan's identity (`<MAC or client id row>`, for
   example `MF_00005E005301`) once the driver has reached the fan.
   - **Open.**
4. A second Modern Forms Fan device for the same fan is refused or
   reported, as the v1 contract decides (`<text>`).
   - **Open.**

## C. Properties

5. The device's Properties show `Driver Version` (the build number of the
   release, as on the Releases page) and `Debug Mode` (Off), and the rows
   the v1 contract adds (`<rows>`), each with the text it says.
   - **Open.**

## D. Fan speed links (the fan proxy's per-speed connections)

6. Connections: select the Modern Forms Fan device. Under its Control
   Outputs expect one Button Link per speed of the fan (the stock driver
   declares six) and the Off, Toggle and Cycle links, under the names the
   v1 contract gives (`<names>`). Then bind a keypad button to each link to
   be tested: select the keypad and drag its button's row from the top pane
   onto the fan's link in the lower list ("BUTTON_LINK Output Devices"), the
   way
   [`composer-remote.md`](composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag)
   describes; read both lists afterwards and check the binding.
   - **Open.**
7. Press a button bound to a speed: the fan runs at that speed within
   `<time>`, the Navigator's fan tile shows it, and the Modern Forms app
   shows it too. Off, Toggle and Cycle do what the v1 contract says.
   - **Open.**

## E. Light links (light_v2)

8. The light (the Modern Forms Fan device, or the device the v1 contract
   gives it) lists **Top**, **Bottom** and **Toggle Button Link** under its
   Control Outputs; bind keypad buttons to them as in step 6. Tap top: the
   light turns on (`<level>`); tap bottom: it turns off; hold: it dims up or
   down while held, as the v1 contract says. The Navigator's light tile
   follows.
   - **Open.**

## F. Keypad LEDs (Follow Connection)

9. Making a button's link switches its LED Behavior to Follow Connection by
   itself (seen on 2026-10-27); check that it reads so for every bound
   button.
   - **Open.**
10. With the fan at speed 3, only the speed 3 button is lit; pressing
    speed 5 darkens 3 and lights 5, with no programming and no settle
    delay, and the LEDs follow a change made with the Modern Forms app, the
    remote or the wall control the same way (section G). The light's
    buttons: top lit while the light is on, bottom while it is off (or the
    colours the v1 contract gives).
    - **Open.**

## G. Changes made elsewhere

11. Change the speed, the light and the direction in the **Modern Forms
    app**, with the **remote** and at the **wall control**: each change
    reaches the Navigator tiles and the keypad LEDs within `<time>`, in
    order, and a fast series of changes ends on the last one, never on an
    earlier report.
    - **Open.**
12. Control4 programming on the fan's events (`<event names>`) fires for
    those changes too.
    - **Open.**

## H. Offline, address and firmware (the v1 contract)

13. Cut the fan's power at the wall: the device reports it as the v1
    contract says (`<text>`) within `<time>`, and comes back by itself when
    power returns.
    - **Open.**
14. The fan gets a new address: the driver follows it, or reports it and
    offers the fix, as the v1 contract decides; it is never taken for a new
    fan.
    - **Open.**
15. After a firmware update of the fan, the device reads `<text>` and works
    as before.
    - **Open.**

## I. Moving from the stock driver (the migration contract)

16. The migration contract's steps, in its order: the connections and the
    programming to redo on the new device, then the house's LED scripts and
    its one-second Timer agent removed. Until that contract exists, nothing
    of the stock driver's setup is touched.
    - **Open.**

## What to paste back

For each step: the property texts as shown, what the Navigator, keypad,
fan or light did, the times where asked, and the Lua output of the device a
step names (its Lua tab in Composer). When something differs from the
expectation, the exact wording matters: it tells us which code path ran.
Replace addresses, MAC addresses, fan ids and room names with the
placeholders of [`scaffold-design.md`](scaffold-design.md), section 2.
