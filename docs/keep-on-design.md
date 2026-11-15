# Keeping the always-on relays on: the contract (#248)

Some Control4 relay switches do not switch a lamp: they stay on to power
smart bulbs or an outlet, and their own buttons are set not to control the
load. If one is ever turned off, everything behind it goes dark and offline.
This contract says how the house keeps them on. The owner decided
(2026-11-15) that it is **Control4 Composer programming only, in no driver**.
The research is [`keep-on-research.md`](keep-on-research.md), and the
lifecycle cases are section 3 of
[`edge-cases-ignored-lights.md`](edge-cases-ignored-lights.md) (KB1 to KB23).
This document is the decision.

## 1. The programming

Every script runs only while the Boolean variable **Relay Maintenance** is
False. "Re-on" below means: add 1 to **Relay Re-ons**; if it is now 3 or
more, set **Relay Maintenance** True and send a push notification saying
the relays keep turning off and keep-on is suspended; otherwise send *On*
to that relay.

| Piece | What it does |
| --- | --- |
| Variable *Relay Maintenance* (Boolean, False) | True suspends everything; False resumes it. Set by a person, or by the cap below |
| Variable *Relay Re-ons* (Number, 0) | How many times the programming had to turn a relay back on in the current hour |
| Timer *Relay Keep-On Check* (00:01:00, repeating) | Every minute: for each relay that reads *Is Off*, re-on |
| Timer *Relay Re-on Window* (01:00:00, repeating) | Every hour: *Relay Re-ons* back to 0 |
| Project root, *When Project … Loads* | Start both timers; send *On* to each relay that reads off (no count: a start is not a loop) |
| Each relay, *Turned Off* | Re-on that relay |
| *Relay Maintenance* changes | If it is now False: *Relay Re-ons* to 0, then *On* to each relay that reads off |
| Scheduler, daily at 12:00 PM | Start both timers (a stopped timer can't stay stopped for more than a day) |

## 2. The cases and what decides them

| Case | Decision |
| --- | --- |
| Project load, Director restart, controller reboot (KB1 to KB3) | The load script turns on any relay that reads off and starts the check. If the first *On* is lost while the devices are still joining, the 1-minute check sends it again |
| A timer that stops by itself, or does not survive a restart (undocumented) | The load script and the daily entry both start it |
| Turned off by a scene, Room Off or voice (KB10, KB11) | Back on at once. Such programming should not include the relays at all, since every off power-cycles the bulbs behind them. The relays are listed for the owner, never removed from scenes by the programming |
| Turned off on purpose for maintenance (KB8) | Set *Relay Maintenance* True first. Its value survives restarts; after an abnormal shutdown it may come back False (the Composer Pro guide), so electrical work still starts at the breaker, as the switch's installation guide says |
| A protection or a loop keeps turning it off (KB12) | The third re-on within an hour suspends keep-on (*Relay Maintenance* True) and sends one notification. A person sets it back to False to resume. It never re-powers a relay without limit |
| Offline (KB16) | Its state keeps its last value. If that is off, *On* goes out once a minute until it answers, and the cap above ends it within the hour |
| Power outage (KB4) | Whatever the relay does at power-up, the load script and the check turn it on. What the bulbs behind it do when power returns is their Hue power-on behaviour: the owner sets *Power loss recovery* in the Hue app (2026-11-15). No Control4 programming writes Hue settings |
| The switch's buttons set to control the load again (KB9) | The bottom rocker would turn it off and the programming would turn it back on, so the cap suspends it within three presses. It shouldn't happen: the switch settings are not touched |
| A relay replaced or removed (KB17, KB18) | Composer drops programming that names a removed device; a replacement needs its scripts added again |
| Checking costs (KB21) | The check only reads Director's state; it sends nothing while the relays read on |

## 3. What the fan driver reads from it

The fan's room-dark pause (#247) treats a light whose own *Turned Off*
event has programming that turns that same light on as kept on, and leaves
it out of the pause. That programming is this contract's, read with
`C4:GetCodeItems` (OS 3.3.0 and later). While *Relay Maintenance* is True the
programming is still there, so the relay stays left out; being off, it would
not hold the pause off anyway.

## 4. Verified on the house

Recorded on #248 as each test runs: the relay snaps back on after an *Off*;
it stays off under *Relay Maintenance*; it comes back when that is set
False; and the third re-on in an hour suspends keep-on and notifies.
