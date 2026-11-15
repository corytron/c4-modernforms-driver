# Keeping the always-on relay switches on: research

Research for [issue #248](https://github.com/corytron/c4-modernforms-driver/issues/248),
written 2026-11-15 by a read-only research agent. Nothing was sent to any
device and no Composer setting was changed.

The owner's request: "apply an effective automation in Control4 to make sure
they are always switched to the on position. Basically set them on at project
load, make sure they turn on then. If they are turned off at a later time we
check for that at some interval and turn them back on as soon as we know.
Otherwise we do nothing. We handle reboots correctly etc." It must work on the
house's OS 3.4.3 (Composer Pro 3.4.2) and keep working on OS 4.x.

**Owner decision (2026-11-15):** Control4 Composer programming only, in no
driver. A driver was compared and is recorded here only as rejected by the
owner (section 4).

## Contents

- [Summary](#summary)
- [Sources and markers](#sources-and-markers)
- [1. The two relays today](#1-the-two-relays-today)
- [2. What each part covers](#2-what-each-part-covers)
- [3. Composer programming: what the sources say](#3-composer-programming-what-the-sources-say)
- [4. Rejected by the owner: a driver](#4-rejected-by-the-owner-a-driver)
- [5. Reliability](#5-reliability)
- [6. The recommended build](#6-the-recommended-build)
- [7. What to verify on the house](#7-what-to-verify-on-the-house)
- [8. Open questions](#8-open-questions)

## Summary

The build is five small scripts, one timer, one daily Scheduler entry and one
Boolean user variable, all standard Composer Pro. A dealer finds each of them
where such a thing is normally looked for: the project root, each relay's own
events, and the Timer, Scheduler and Variables agents.

| Duty | Mechanism | Why this one |
| --- | --- | --- |
| On at every start | project root ▸ *When the project is loaded*, then a 1-minute delay and *On* to both relays, sent without asking, repeated 4 minutes later | The event runs at system startup, including after a power outage (VERIFIED-doc). The delay lets the Zigbee mesh come up. The second *On* catches a switch that joins late |
| Back on at once | each relay's off event (the proxy's *Light Off*, 5101) ▸ *On* | Zero cost until an off happens. Reacts within the time of one Zigbee round trip |
| Periodic check | Timer agent, 5 minutes; *Expires* ▸ *If relay is off* ▸ *On*, then the timer's Start | The interval is in hh:mm:ss, so any value of 1 s or more is possible. The check sends nothing while both relays read on. The startup script starts the timer every time, so it does not have to survive a restart |
| Re-arm, daily | Scheduler agent, daily ▸ the timer's Start and *On* to both | The Scheduler cannot repeat more often than daily (VERIFIED-doc), but once a day it restores a timer someone stopped and catches a relay whose state Control4 misread |
| Off on purpose | Boolean *Relay Maintenance*, created False (the default); every script runs only *If Relay Maintenance is False* | One visible switch, no script edits. A value lost in an abnormal shutdown falls back to False, so enforcement fails toward "on" |

Two facts matter as much as the programming:

- The Hue bulbs behind a relay come back on at their **power-on behaviour**
  each time it powers up (section 5).
- Nothing should turn the relays off in the first place: scenes, Room Off,
  voice, an auxiliary keypad (H2).

## Sources and markers

The Snap One reference is cited by path under `~/c4-tools/reference/` and
paraphrased, never copied. Composer labels are quoted only as names.

| Short name | Path or URL |
| --- | --- |
| API | `docs-driverworks-api/source/includes/` |
| FUND | `docs-driverworks-fundamentals/source/includes/` |
| LV2 | `docs-driverworks-proxyprotocol-lightv2/source/includes/`: **cmds** `10_light_v2_commands/`, **events** `25_light_v2_events/`, **vars** `30_Light_v2_variables/`, **cond** `20_light_V2_conditionals.5_light_V2_conditionals/`, **notif** `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/`, **new** `3_whats_new/` |
| CPRO | Composer Pro 3.2.2 User Guide (the newest full guide found), <https://docs.control4.com/docs/product/composer-pro/dealer-user-guide/english/revision/X>, read 2026-11-15; page numbers are the guide's own |
| C4-COND | Composer help, "Programming with conditionals", <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/programming_with_conditionals.htm> (read 2026-11-15) |
| C4-TIMER | Composer help, "Using the Timer agent", <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/using_the_timer_agent.htm> (read 2026-11-15; matches CPRO pp. 391-394) |
| C4-SCHED | Composer help, "Using the Scheduler agent", <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/using_the_scheduler_agent.htm> (read 2026-11-15; matches CPRO pp. 388-390) |
| SW-IG | Control4 Switch installation guide 200-00310-F.1, <https://docs.control4.com/docs/product/wireless-switch-120v-277v/installation-guide/english/latest> (read 2026-11-15) |
| FORUM | c4forums.com topics, seen **as search snippets only** (the site refuses automated reads): [17872](https://www.c4forums.com/topic/17872-run-macro-on-start-up/) (programming at start), [25378](https://www.c4forums.com/forums/topic/25378-program-dimmer-to-keep-circuit-on/) (keep a circuit on, 2017), [35435](https://www.c4forums.com/topic/35435-best-practices-hue-behind-a-c4-switch/) (Hue behind a C4 switch), [29409](https://www.c4forums.com/forums/topic/29409-configurable-dimmer-with-lifx-lights/) (2017, a safety caution), [43580](https://www.c4forums.com/forums/topic/43580-3-way-light-switch-disable-load-control-on-aux-switch/) (auxiliary switch), [29479](https://www.c4forums.com/topic/29479-disabling-c4-dimmerswitch-memory-after-power-loss/) (state after a power loss), [43697](https://www.c4forums.com/forums/topic/43697-room-off-in-family-room-turns-off-all-lights-in-all-downstairs-rooms/) (Room Off and lights) |
| HUE-PUB | Public Hue sources only: [MacRumors, 2018-12-13](https://www.macrumors.com/2018/12/13/philips-hue-ios-app-power-outage/), [Hue Essentials community](https://community.hueessentials.com/t/how-to-set-up-power-on-behaviour-for-my-lights/720), [Home Assistant community](https://community.home-assistant.io/t/control-philips-hue-power-on-behavior-via-hue-bridge/817293) |
| HUE-PROJ | The owner's Hue project, read only: `~/projects/c4-hue-driver` (`docs/design.md`, "Lights: verified on hardware (2026-10-21, through the dev loop)") |

**Markers.** VERIFIED-doc: an SDK file, a Control4 guide or a help page says
so (cited). VERIFIED-code: this repository's or the Hue repository's code does
so. VERIFIED-house: seen on the house (the record is cited). DEALER: a forum
report, unofficial. ASSUMED: none of these; the reasoning is given. SILENT: no
source says anything.

## 1. The two relays today

- Two Control4 switches in the fan's room, each a `light_v2` proxy device.
  They power Hue bulbs and an outlet. Both are set up with *Buttons Control
  Load* off, *Use as 2 Button Keypad* on and *Hide From Nav* on. Their
  rockers are bound to other lights' button links, and their LEDs follow
  those. Their Light State reads 1 day and night (VERIFIED-house:
  [`status.md`](status.md), #240; [`room-dark-pause-design.md`](room-dark-pause-design.md)
  RD-D13; #247 for the energy counters).
- What these settings mean (VERIFIED-doc, CPRO pp. 167-168):
  - *Buttons Control Load* tells the system whether the buttons drive the
    load.
  - *Use as 2 Button Keypad* makes the buttons programmable keypad buttons.
  - *Hide From Nav* takes the switch off every Navigator.

  So today the load changes only by a Control4 command: programming, a
  lighting scene, Room Off, voice, Composer. A press on the switch does not
  change it [ASSUMED from the setting's description; owner check H10].
- The fan driver leaves both out of the room-dark pause through `Pause
  Ignores Lights` (VERIFIED-code: `src/modernforms_fan/driver.lua`,
  `ignored_lights`). Nothing here changes that.

## 2. What each part covers

S = the startup script (6.3), E = the off events (6.4), T = the timer (6.5),
D = the daily Scheduler entry (6.6), V = the variable's change event (6.7).

| Case | What happens | Covered by |
| --- | --- | --- |
| Composer *Load Project*, or a project restored from backup | Director loads a project, and that project's own startup event runs [ASSUMED: a restored file brings its programming with it] | S |
| Director restart (Composer, a driver capability change) | The project loads again. The SDK calls this a startup for drivers (API `22_miscellaneous/_25.1-OnDriverLateInit.md`, `DIT_STARTUP`); that the programming event runs too is ASSUMED | S (H6) |
| Controller reboot (System Manager, an update, a crash) | Director starts and the project loads | S |
| Whole-house power outage | The controller boots and the project loads. The guide's own outage advice hangs a notification on that event (VERIFIED-doc, CPRO p. 536). The switches power up in a state their guide does not give (SW-IG; DEALER: FORUM 29479 says the previous state) | S; E and T if a switch reports off later |
| Breaker or branch outage, controller up | No project load. The switch drops off the mesh, then rejoins and reports | E when it reports off; T while Control4 reads off; D otherwise |
| An off sent by a scene, Room Off, voice, Composer or programming | The proxy reports off and its *Light Off* event fires | E at once; T as backup |
| An *On* lost (the switch busy or briefly offline) | The relay stays off and reads off | T within 5 minutes |
| A relay off while Control4 still reads on (a lost report) | No event; the conditional sees on | S at the next load; D within a day |
| The timer stopped by hand, or its chain broken | Nothing checks | S at the next load; D within a day |
| A switch factory reset (9-4-9) or left the mesh (13-4-13) | Offline until identified again. A reset switch obeys its own buttons (top on, bottom off, VERIFIED-doc: SW-IG) until Composer's settings reach it again [ASSUMED] | E and T after it rejoins |
| A relay replaced by new hardware | If the dealer identifies the new switch into the existing device, its id and programming stay [ASSUMED]. If the device is deleted and added again, its scripts are lost | H3 again after any replacement |
| A relay renamed or moved to another room | Programming refers to the device, not its name [ASSUMED, as in [`edge-cases-rename.md`](edge-cases-rename.md) RC23] | nothing to do |
| Maintenance | *Relay Maintenance* True stops S, E, T, D and V from sending | V turns both on when it is set back to False |
| OS upgrade, 3.x to 4.x | The project and its programming carry over [ASSUMED] | H1 and H3 again after the upgrade |

## 3. Composer programming: what the sources say

### 3.1 Startup

- **The start event.** In Programming, select the root of the project; its
  event *When the project is loaded* is the system startup event. The guide
  names it for initialising values or running programming at startup.
  VERIFIED-doc: CPRO p. 433, "Variable handling".
- **It runs after an outage too.** The troubleshooting table covers a
  controller that does not come back after a power outage. It advises an
  Email Notification on the project's top-level device events, sent when the
  project is loaded and the controller is up again. VERIFIED-doc: CPRO p. 536.
- **Wait before acting.** A dealer advises putting a delay before anything
  in a startup script, because the event marks the project's load, not a
  system that is fully up. DEALER: FORUM 17872. Zigbee switches need time to
  rejoin and report after a start [ASSUMED], so the build waits 1 minute and
  sends a second *On* 4 minutes later.
- **No reboot event as such.** The guide mentions "When a System reboots"
  only as an email example. No device or agent event of that name was found,
  and the troubleshooting entry uses the project-load event instead.
- **Delays in a script.** A Delay sits under Programming Controls, and every
  later line of the same script waits for it (CPRO pp. 423-424, the While
  example; [`breeze-leds-field-research.md`](breeze-leds-field-research.md)
  Q2). A Director restart during a delay ends the script; it runs again at
  the next load [ASSUMED].

### 3.2 The relay's event, condition and command

- **Events.** The `light_v2` proxy provides *Light On* (5100) and *Light
  Off* (5101) as system events for Composer programming (VERIFIED-doc: LV2
  events `_0-HEADER.md`). Composer's exact label on the relay's event list is
  read in H1.
- **The off condition.** The proxy's conditionals include `IS_ON` and
  `IS_OFF`; "off" means the Off preset (VERIFIED-doc: LV2 cond
  `_0-HEADER.md`). Composer shows the latter as *Is Off* on the Conditionals
  tab, and the script line reads "If \<room\>-\>\<light\> is off"
  (VERIFIED-doc: C4-COND).
- **The command.** *On* on the light's Commands tab (VERIFIED-doc: C4-COND;
  CPRO p. 437 for a light switch).
- **Do not use Toggle.** Its result depends on the state the proxy holds.
  The SDK warns against it wherever the final state matters (VERIFIED-doc:
  LV2 cmds `_7-TOGGLE.md`).
- **An off found at start.** Whether *Light Off* fires when Director starts
  and the relay reports off is SILENT. The proxy starts as online until told
  otherwise (LV2 notif `_15-ONLINECHANGED.md`). How it seeds its state at
  start is not documented. The startup script therefore sends *On* without
  asking.

### 3.3 The Timer agent

- **Fields.** A timer has a name and an interval in seconds, minutes or
  hours (hh:mm:ss).
- **Commands.** Start, Stop, Restart, Reset, Pause, Resume and Change.
- **The state table.** Start on a stopped timer starts it. Start on a running
  one restarts it and raises its Reset event, nothing worse.
- **Repeat.** A timer can repeat an action each time it expires, but no
  Repeat field is shown.
- **Expiry.** Expiry is the event a script hangs on.
- **Testing.** A script can be run on the spot with the Script pane's
  Execute.

VERIFIED-doc: CPRO pp. 391-394 and p. 410 (Execute); C4-TIMER. The expiry
event shows as *Expires* in this house's Composer (VERIFIED-house:
[`migration-design.md`](migration-design.md), row I11). Whether 3.4.2 adds a
Repeat option is read in H1.

- **After a restart.** Whether a timer runs again after a Director restart is
  SILENT in the guide and the SDK, and no forum report was found. The startup
  script therefore starts the timer every time; Start on a timer that is
  already running is harmless (the state table above).
- **Repeating.** The expiry script ends with the timer's Start. That works
  whether or not a Repeat option exists, and it is the dealers' usual
  pattern (DEALER: [`breeze-leds-field-research.md`](breeze-leds-field-research.md) Q2).
- **Not a While loop.** A While loop with a delay inside would also poll.
  The guide warns that a While without delays eats the CPU (VERIFIED-doc:
  CPRO pp. 423-424). A loop shows no state in the agents, and once broken it
  stays broken until the next load. The timer is the better tool.

### 3.4 The Scheduler agent

- **Repeats.** Events start at a time or at sunrise or sunset, with an
  optional randomisation, and repeat daily, weekly, monthly or yearly with an
  optional stop date (VERIFIED-doc: CPRO pp. 388-390; C4-SCHED). The
  Scheduler's driver API gives the same units, the smallest being every 1 to
  100 days (VERIFIED-doc: API `27_scheduler_agent/_1-Overview.md`). So **no
  Scheduler event repeats every N minutes**: it cannot be the periodic check.
- **Its role here.** A daily entry restarts the timer and sends *On* once a
  day. That covers the two holes no event shows: a timer someone stopped by
  hand, and a relay Control4 reads as on while it is off.
- **Restarts and missed times.** Scheduler entries are project data and stay
  after a restart [ASSUMED: they are listed and edited as project entries].
  Whether a time missed while Director was down runs later is SILENT. That
  does not matter here: the startup script covers the same ground.
- **When to run it.** Daytime (noon is proposed). A relay found off and
  turned on makes its bulbs follow their power-on behaviour, so the
  rare correction should not land at night (Q2, Q3).

### 3.5 The variable and turning it off on purpose

- **Booleans.** A Boolean user variable is made in Agents ▸ Variables ▸
  New, and its default value is **false**. In programming its conditionals
  are *Is True* and *Is False*, and its commands *Set to True* and *Set to
  False*. Variables appear under Variables in both the Device Events and the
  Device Actions panes. VERIFIED-doc: CPRO pp. 434-438. Its change event's
  exact label is read in H1.
- **Persistence.** User variables keep their values across a normal restart
  but maybe not after an abnormal shutdown (VERIFIED-doc: CPRO p. 433).
- **The sense of the variable.** *Relay Maintenance* is therefore created
  False, the default, which is normal operation. A lost value falls back to
  enforcement on. The opposite sense ("Always On", set to True by hand) would
  silently switch enforcement off after a bad shutdown.
- **Disabling a script.** The Script pane's right-click menu has Disable
  Event (the whole script), Disable Item (one line), Insert Comment, and
  Change to Customer. Composer programming stays locked out of the
  customer's When >> Then editing unless that last item allows it.
  VERIFIED-doc: CPRO p. 451; VERIFIED-house:
  [`composer-remote.md`](composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag).
  Disable Event is the way to stop the whole automation without deleting
  it. Each script carries a comment saying why it exists.
- **The dealers' usual setup.** For smart bulbs behind a Control4 switch,
  dealers set 2-button function, hide the load, and add programming that
  keeps it on. One thread suggests "if the dimmer turns off, wait 2 seconds,
  turn it on". DEALER: FORUM 25378, 35435.
- **A safety caution.** One reply warns that taking away the off may conflict
  with local code and is unsafe when changing bulbs (DEALER: FORUM 29409).
  The switch's guide says to cut power at the breaker before servicing it
  (VERIFIED-doc: SW-IG). The maintenance variable is for keeping a load off
  through Control4. Electrical work still starts at the breaker.

## 4. Rejected by the owner: a driver

A driver was compared before the owner's decision of 2026-11-15. It would
have used:

- `OnDriverLateInit` at every Director start (API `22_miscellaneous/_25.1-OnDriverLateInit.md`).
- A listener on each relay proxy's variable 1000, which reports at once and
  on each change (API `36_variable/_10-RegisterVariableListener.md`,
  `_9-OnWatchedVariableChanged.md`; LV2 vars `_0-HEADER.md`).
- A repeating `C4:SetTimer` (API `34_timer/_1-SetTimer.md`).
- `C4:SendToDevice` to the proxy. The SDK's example form is `RAMP_TO_LEVEL`
  (API `32_serial_network_device/_19-SendToDevice.md`); `light_v2` lists no
  `ON` (LV2 cmds). The Hue project saw `ON` work through a Hue light's proxy
  on this controller (HUE-PROJ).

Its listener gives a slightly better view of the state at start. That is
outweighed by the owner's rules:

- "Control4 is the source of truth" puts automations in programming.
- "No one-off tooling in the driver" keeps house-specific behaviour out of
  shipped code.
- Automation must never make a later manual fix harder: enforcement hidden
  in a driver is invisible from the relay's programming page.

## 5. Reliability

- **Check interval and its cost.** The off event is the primary path. The
  timer is the backstop for a lost event or a lost *On*. Five minutes means
  288 expiries a day. Each one runs two conditionals and sends nothing while
  both relays read on [ASSUMED: a conditional reads the state Director
  holds and queries no device]. One minute is just as cheap but adds nothing
  the off event does not already give. The worst case at 5 minutes is a
  relay off for 5 minutes after both the event's *On* and its report were
  lost.
- **A switch offline.**
  - While a light is offline its Light State keeps its last value
    ([`room-dark-pause-design.md`](room-dark-pause-design.md) RE4, ASSUMED
    there).
  - A relay that reads off resends *On* every 5 minutes until it answers:
    at most 288 small Zigbee commands a day. Nothing appears in any log a
    user sees [ASSUMED].
  - A relay that reads on sends nothing until it reports again. The daily
    entry then sends one *On*.
- **A whole-house outage.**
  - What a Control4 switch does to its load at power-up is SILENT in its
    guide, which only says its LEDs light green at first power (SW-IG).
  - A dealer reports that Control4 switches and dimmers return to their
    pre-outage state (DEALER: FORUM 29479).
  - Either way, the startup script's two unconditional *On*s (1 and 5
    minutes after the load) end with both relays on.
- **The Hue bulbs behind the relay.**
  - Every time power returns, each bulb follows its **power-on behaviour**,
    a per-light setting in the Hue app.
  - The default turns the bulb on in bright warm white. "Power loss
    recovery" brings back the bulb's previous state, so a bulb that was off
    stays off (HUE-PUB, MacRumors and Hue Essentials).
  - The bridge API exposes the same choice: a safety default, power-fail
    recovery, the last on/off state, or a custom setting (HUE-PUB, the Home
    Assistant thread, paraphrased).
  - With the default, every re-on lights the bulbs, at night too. That is
    the owner's call (Q2). It is a device setting, not an automation, so it
    does not conflict with "Control4 is the source of truth".
- **Not fighting a person.**
  - With *Buttons Control Load* off, nobody can switch the load at the wall.
    Every off comes from Control4: a scene, Room Off (which can include
    lights, DEALER: FORUM 43697), voice, Composer or programming.
  - So an off is either a mistake, which the scripts undo, or maintenance,
    which uses the variable.
  - A scene or script that turns a relay off would fight the scripts, one
    *On* per off, so H2 removes every such source.
  - A relay that refuses *On*, such as a switch in fault (CPRO p. 167, Fault
    Detection), produces no new off event, so nothing loops.
- **OS 4.x.**
  - The project-load event, the agents, and the proxy's events, conditionals
    and commands are standard features.
  - `light_v2` changed in 4.2.1 only by adding capabilities with which a
    driver may hide its own proxy's events, commands and conditionals
    (VERIFIED-doc: LV2 new `_6-WhatsNewin421.md`). That Control4's switch
    driver does not use them is ASSUMED.
  - After an OS 4 upgrade, H1 and H3 run again.

## 6. The recommended build

Names: "Relay A" and "Relay B" stand for the two switches. *Relay
Maintenance*, *Relay Keep-On Check* and *Relay Keep-On Daily* are proposals.
Composer's exact labels come from H1. Nested lines are dropped on the If's
"?" icon
([`composer-remote.md`](composer-remote.md#learned-2026-10-27-connections-and-programming-by-synthetic-drag)).
Every script starts with an Insert Comment line saying why it exists. Each
relay script (6.4) also says that a relay is turned off on purpose by setting
*Relay Maintenance* to True.

### 6.1 Variables agent

Add a Boolean user variable *Relay Maintenance*. Leave it at its default,
False.

### 6.2 Timer agent

Add the timer *Relay Keep-On Check* with the interval 00:05:00. If 3.4.2
shows a Repeat option, leave it off: the expiry script repeats the timer.

### 6.3 Project root ▸ When the project is loaded

```
Delay 1 minute
Relay Keep-On Check: Start
If Relay Maintenance is False
    Relay A: On
    Relay B: On
Delay 4 minutes
If Relay Maintenance is False
    Relay A: On
    Relay B: On
```

### 6.4 Relay A ▸ its off event (Light Off, 5101)

```
If Relay Maintenance is False
    Relay A: On
```

Add the same script on **Relay B**, with Relay B.

### 6.5 Timer agent ▸ Relay Keep-On Check ▸ Expires

```
If Relay Maintenance is False
    If Relay A is off
        Relay A: On
    If Relay B is off
        Relay B: On
Relay Keep-On Check: Start
```

The timer's Start stays outside the If, so it keeps running during
maintenance and resumes checking the moment maintenance ends.

### 6.6 Scheduler agent ▸ Relay Keep-On Daily

Daily at 12:00, no randomisation, no stop date.

```
Relay Keep-On Check: Start
If Relay Maintenance is False
    Relay A: On
    Relay B: On
```

### 6.7 Variables ▸ Relay Maintenance ▸ its change event

The label is read in H1.

```
If Relay Maintenance is False
    Relay A: On
    Relay B: On
```

### 6.8 Remove the other sources of an off

Take both relays out of every Advanced Lighting Scene, Room Off's lights and
voice control, as H2 finds.

### Maintenance, for whoever needs a relay off

1. Set *Relay Maintenance* to True (Agents ▸ Variables, or a programming
   command).
2. Turn the relay off from Composer.
3. When done, set *Relay Maintenance* back to False. Script 6.7 turns both
   relays on at once.

For electrical work, use the breaker as the switch's guide says. To retire
the automation, use Disable Event on scripts 6.3 to 6.7 rather than deleting
them.

## 7. What to verify on the house

The Windows session runs H1 to H7 and H9 under the owner's standing
approval. Turning a relay off cuts its Hue bulbs and its outlet for a moment,
and the bulbs come back per their power-on behaviour. So H4 to H7 run at a
time the owner picks, after Q2. None of them needs more than about a minute
of waiting: scripts are run with Execute and the timer is shortened during
the test.

| # | Check | Expect |
| --- | --- | --- |
| H1 | Read the labels: the relays' off event, *Is Off*, *On*; the root's *When the project is loaded*; the timer's fields (any Repeat option), *Start* and *Expires*; the Scheduler's daily entry fields; the variable's change event, *Is False* and *Set to True/False* | the names of section 6, corrected where they differ |
| H2 | List every path that can turn the relays off: Advanced Lighting Scenes, Room Off settings, other programming that names them, voice exposure, and auxiliary keypads (wiring, from the owner) | none left, or each removed |
| H3 | Build section 6; read every script back with Copy All | the XML matches section 6 |
| H4 | Turn Relay A off from Composer | back on within about 2 s (6.4) |
| H5 | Disable Event on 6.4 for Relay A; turn Relay A off; Execute script 6.5 | Relay A on; Enable 6.4 again |
| H6 | Disable Event on 6.4 for Relay A; turn Relay A off; restart Director | about 1 minute after Director is back: Relay A on, the timer running (6.3); Enable 6.4 again. This also answers whether the event runs on a Director restart |
| H7 | Set *Relay Maintenance* True; turn Relay A off; Execute 6.5 and 6.6 | Relay A stays off; set the variable False and Relay A comes on at once (6.7) |
| H8 | Parked, not blocking: the next controller reboot or power cut the owner has anyway, and a breaker cycle only if the owner wants one | the relays end on; what a switch does at power-up |
| H9 | Read the power-on behaviour of the bulbs behind the relays (Hue app, or a read-only bridge query with the Hue project's tools) | recorded for Q2 |
| H10 | The owner presses a relay's rockers once | the load does not change |

## 8. Open questions

- **Q1. The interval.** 5 minutes (recommended) or 1 minute?
- **Q2. The bulbs' power-on behaviour.** Keep the Hue default (on, bright,
  at every re-power) or set "Power loss recovery" on the bulbs behind the
  relays? It is a reversible device setting in the Hue app.
- **Q3. The daily entry's time.** Noon is proposed so that a rare correction
  does not light the bulbs at night.
- **Q4. Auxiliary keypads.** Is an auxiliary keypad wired to either switch?
  One report says an auxiliary switch still drives the load after the main
  switch became a 2-button keypad (DEALER: FORUM 43580).
- **Q5. Hard-wiring.** Wire the bulbs and the outlet always hot, so the
  relay cannot cut them? The forum mentions it (FORUM 35435), but it needs an
  electrician and local code may require a switched light. Out of this note's
  scope.
