# Min On for the fan's light: design contract

> **Contract for [issue #195](https://github.com/corytron/c4-modernforms-driver/issues/195)**
> (2026-11-12). The owner reported that the fan's light "starts late" when it
> is dimmed up from off: the lowest levels of the light kit do not light the
> LEDs. A Control4 dimmer fixes this with Min On. This driver does the same
> thing for the fan's light, which has no trim of its own. The research is
> [`min-on-sdk-research.md`](min-on-sdk-research.md) (cited as MSR) and
> [`edge-cases-min-on.md`](edge-cases-min-on.md) (cited by its row ids: MT,
> RO, OX, CM, TO, PL, RT, LB, LC, RP, BV). The owner said to ship without
> hardware rounds (2026-11-12): every open question takes its recommended
> answer below.

## 1. Decisions

| # | Decision |
| --- | --- |
| MO-D1 | **A driver property, `Light Min On (%)`**: `RANGED_INTEGER` 0 to 99, default 0, on the fan item's Properties page, after `Poll Interval (s)`. No capability changes, so no controller reboot (MSR Summary 1). Control4's own Range Levels (`min_max`) is deprecated since OS 3.3.2 and is not used. |
| MO-D2 | **The driver remaps, and the proxy stays 0 to 100** (MSR Summary 3, MT6). Everything toward Control4 (CHANGING, CHANGED, the preset, rates, scenes, the slider, the keypad) stays in Control4 levels. Only what goes to the fan and what comes back from it is converted, and only in `fan/light.lua`. The model, the wire, the transport and the dev commands stay in fan levels (edge cases 1.4). |
| MO-D3 | **The mapping**, with M the Min On and m = max(1, M), rounding half up (`math.floor(x + 0.5)`): **to the fan**, 0 stays off and a level s from 1 to 100 becomes `m + round((s - 1) * (100 - m) / 99)`. **From the fan**, off is 0. A fan level f below m, with the light on, is **1**. A fan level f from m to 100 is `1 + round((f - m) * 99 / (100 - m))`. M = 0 and M = 1 change nothing. |
| MO-D4 | **Round trips (RO1):** the light keeps the last Control4 level it wanted together with the fan level that went with it. A fan level equal to that fan level is reported as that Control4 level, and any other fan level is mapped back. The memory is cleared when M changes, and it is never persisted (RO4: after a restart the first report may be one point off, two above M = 67). |
| MO-D5 | **Levels set outside Control4 are never corrected** (OX1 to OX9). Below m they show as 1 %, never 0 while on, and nothing is written to the fan. |
| MO-D6 | **Times are measured over Control4's range** (RT1). A 3 s tap takes 3 s and a full hold 5 s, whatever M is. `FADE_MIN_LEVELS` counts fan levels (RT4). A fade's steps are wanted only when the fan level changes (RT3). |
| MO-D7 | **A turn-on from off is lit at once** (TO1, TO2, TO5, TO7). LF-D9's first dark level is worked out in Control4 levels and then mapped. A hold from off starts at 1 %, which is fan level m. A hold down or a scene ramp down stops at 1 %, which is m (TO6). A fade to off steps down to 1 %, which is m, then off (TO3). LF-D10's write-back after a fade to off restores the **raw fan level** the fade started from (TO4). A fade up from a fan level below m starts from m (TO10). |
| MO-D8 | **The eight checks of edge cases 1.4** each compare the unit that table names: `:527`, `:626`, `:730`, `:748`, `:785` and `:1072` in fan levels, `:546` in Control4 levels and then mapped, and `:1084` in Control4 levels (what the proxy heard). The `:1072` check comes first: a fade must never end itself because its own step mapped back to a neighbouring level. |
| MO-D9 | **Changing M (CM1 to CM9).** At load (late init's replay of the properties) M is taken and nothing is sent (CM7). On an owner's edit: with the light off, nothing is sent (CM1). With the light on at a level Control4 set (MO-D4's memory matches the fan), the Control4 level stays and the light moves to its new fan level in one request, with no fade and no CHANGED (CM2, MQ3's recommended answer). With the light on at a level set outside Control4, the fan is not touched, and the proxy hears the new Control4 level once (CM3). A running fade, hold or scene ramp keeps the M it started with. When it ends, CM2 or CM3 applies once (CM6). An offline, rebooting or foreign fan: M is kept and nothing is sent (CM9). |
| MO-D10 | **Bad values (BV1 to BV5):** not a number, below 0, or 100 and over are refused: the old value is kept, the property is written back to it, and one warning is logged. A decimal is rounded half up and then checked. |
| MO-D11 | **The Status row (RP1, MQ5):** while M is above 1 and the light is on, "light 40 % (fan 52)", the Control4 level first. Below m: "light 1 % (fan 5, below Min On)". At M of 0 or 1, today's "light 40 %" exactly. |
| MO-D12 | **The log (RP3):** one always-on info line per change of M that is not the load's: "Light Min On 20: Control4's 1 % is the fan's level 20" (or "Light Min On 0: levels are the fan's" at 0 or 1). The light's debug lines that name a level say which: "40 %" for Control4, "fan level 52" for the fan. |
| MO-D13 | **A new fan (LC1):** when Use Selected Fan takes a fan and M is above 0, one info line: "Light Min On is 20 %; check it for this fan's light". M is never reset or guessed. A new light kit, a firmware update and a restore are covered by the manual (LC2, LC3, LC6). |
| MO-D14 | **The manual (RP4):** a "Light Min On" section on the Documentation tab, in the driver's own words: what it is, that 0 is off, that 1 % becomes the first lit level, how to find the value (at 0, find the first level that lights, then set a few points above it, as Control4 suggests for its own dimmers), that times stay the same, that levels set in the Modern Forms app or by the remote below Min On show as 1 %, that the app's numbers no longer match Control4's, and to check the value after a new fan, light kit or firmware. Near 99 only two levels are left. |
| MO-D15 | **Out of scope:** Max On, Cold Start, a Range Levels route (MSR Summary 6). |

## 2. Interfaces

`fan/light.lua` (agent A) adds:

```lua
-- Pure functions, M any number (nil, below 2: identity).
light.to_fan(level, M)    -- Control4 0..100 -> fan 0..100 (0 stays 0)
light.from_fan(f, M)      -- fan 1..100 -> Control4 1..100 (below m -> 1); 0 -> 0

-- Methods.
light:set_min_on(value, why)  -- why = "load" | "property"; returns true, M
                              -- or false, reason (MO-D10). Acts as MO-D9.
light:min_on()                -- the M in use (0 until set)
light:c4_level(st)            -- the Control4 level for a fan state, with
                              -- MO-D4's memory; 0 when off; nil when unknown
```

`fan/texts.lua` (agent B): `texts.status(v)` for the online state reads two
new optional fields of `v`, `min_on` (number) and `light_level` (the Control4
level from `light:c4_level(st)`), and writes MO-D11's text. Missing or nil
fields give today's text.

`driver.lua` (coordinator): the property's handler calls
`light:set_min_on(value, started and "property" or "load")`; on refusal it
logs a warning and writes the kept value back with `C4:UpdateProperty`; it
then refreshes Status. `refresh_status()` sets `view.min_on` and
`view.light_level`. `take_fan` writes MO-D13's line.

## 3. Pieces and owners

| Piece | Owner | Files |
| --- | --- | --- |
| The mapping, M's changes, the eight checks, the fade record, the log lines | agent A | `src/modernforms_fan/fan/light.lua`, `tests/spec/light_spec.lua` |
| The Status row, the manual | agent B | `src/modernforms_fan/fan/texts.lua`, `tests/spec/texts_spec.lua`, `src/modernforms_fan/www/documentation.html` |
| The property, the wiring, the changelog, the status page, the codename and its meaning | coordinator | `src/modernforms_fan/driver.xml`, `src/modernforms_fan/driver.lua`, `CHANGELOG.md`, `docs/status.md`, `docs/README.md`, `.github/codenames.json`, `.github/codename-meanings.json` |

## 4. Control4 guidelines

The rows are the Hue project's checklist, `docs/c4-lighting-guidelines.md`
there (cited HUE-LG), the light_v2 best practices and extras, and Control4's
dealer help for dimmers (C4-DIM).

| Row | How Min On meets it |
| --- | --- |
| L26 Min On trims the bottom of the range | Emulated by MO-D3. **Departure:** the value is a driver property, not Range Levels on the light's settings page, because `min_max` is deprecated and the SDK names no replacement (MSR section 1). |
| L9 A light that is on never reads as off | MO-D5: on below m is 1 %. |
| L14, L15 Rates cover the whole range | MO-D6. |
| L17 The top tap goes to the preset from any level | The preset is a Control4 level and is mapped (PL1, PL9). |
| L43 A hold from off ramps up from the bottom | MO-D7: from 1 %, which is lit. |
| L53 LEDs show the real state | LB1: the light's LEDs follow on and off, unchanged. |
| L55 A slider move sticks | MO-D4. |
| L62 Scenes drive the light with targets | Mapped like any target (PL3, RO3). |
| L83 Settings survive updates; a bad one is refused | MO-D1 (a property comes back from the project), MO-D10. |

## 5. House checks (after the release, with the owner, not blocking it)

The owner said to ship without them. When convenient: set `Light Min On (%)`
on the house's fan; then a hold from off and a Navigator ON should both be
lit from the first moment, and the slider at 1 % should glow. The tap fades
and the second-tap stop (LF-D12, LF-D13) need the pending controller reboot
from System Manager first (status.md).
