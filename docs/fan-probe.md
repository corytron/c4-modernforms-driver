# The fan probe: `tools/mf_probe.py`

The VM's tool for M1 ([issue #17](https://github.com/corytron/c4-modernforms-driver/issues/17)):
it reads the fan and runs the write checks K11, K12, K13 and K15 of
[`v1-design.md` section 11](v1-design.md#11-hardware-checks-before-the-first-install)
straight from the VM over the fan's local interface (`POST /mf`, see
[`modernforms-api-research.md`](modernforms-api-research.md)), never through
the controller. The source and its full help: [`tools/mf_probe.py`](../tools/mf_probe.py)
(`python3 tools/mf_probe.py --help`). Standard library only.

## Commands

| Command | Sends | Writes to the fan |
| --- | --- | --- |
| `read --fan ADDR` | `{"queryDynamicShadowData":1}`; with `--static` `{"queryStaticShadowData":1}`; `--count N --interval S` repeats it (at most 60 reads, at least 0.5 s apart, within 60 s) | nothing |
| `check K11` | the opposite of the direction it finds (`{"fanDirection":"reverse"}` on a fan running forward), 3 reads over 10 s, the direction it had, 2 s, a read; a fan that is off is first started at its own speed, 3 s before | direction |
| `check K12` | `{"lightOn":false}` if the light is on, `{"lightBrightness":30}` (60 if it is at 30), a read, `{"lightOn":true}`, a read, `{"lightOn":false}`, a read; 1 s before each read | light |
| `check K13` | 10 `{"fanOn":true,"fanSpeed":N}` (1 to 6 and back), then 20 `{"lightBrightness":N}` (1 to 100 and back), back to back, each burst ending on the speed and level the fan had; 2 s, a read | speed, light |
| `check K15` | 12 `{"lightBrightness":N}` from 1 to 100, one every 0.25 s; 1 s; the same down to 1 | light |
| `fixture --from RAW --out tests/fixtures/NAME.json` | nothing: turns a raw answer into a fixture with the placeholders of `docs/scaffold-design.md` section 2 | nothing |

Every check first reads the identity and the state, and at the end puts back
what it found (fan on or off, speed, direction, light on or off, level) and
reads again to verify, also after an error or Ctrl-C. If the fan was off, K11
runs it at its own speed for the check and K13's speed burst starts it; if the
light was off, K13 and K15 switch it on for the light part. The report's
`verdict` gives the result for the contract: K11 `can_reverse` True or False,
K12 whether V14's two steps hold, K13 latency and errors for `GAP_MS` and
`RAMP_STEP_MS`, K15 a question for the owner's eyes.

## What to tell the owner first

With M0's latencies (0.25 to 0.39 s per request):

| Check | One line for the owner | Visible for |
| --- | --- | --- |
| K11 | "The fan reverses direction for about 10 s and then turns back; if it is off, it runs at its own speed for about 20 s meanwhile." | about 15 s, plus the motor's own spin-down and spin-up |
| K12 | "The fan's light comes on at 30 % for about 2 s and goes off again; if it is on, it goes off, shows 30 % briefly and returns to its level." | about 8 s |
| K13 | "The fan runs through its six speeds and the light through its levels, then both return to how they were." | about 20 s |
| K15 | "The fan's light ramps from 1 % to full in about 3 s and back down; please watch whether it looks like a smooth dim or a staircase." | about 10 s |

The stock driver keeps polling the fan meanwhile, so the keypad LEDs and
Composer may follow the changes late; nothing to fix. If a check reports that
the fan stopped answering, the owner switches it off at the wall for 10 s
(the report's `attention` says so, with the state it had).

## Safety rails

- `--fan` takes a dotted private IPv4 address only, optionally `:PORT`; no
  names, no IPv6, no public addresses. A loopback address needs
  `--allow-loopback`, which only the unit tests' fake fan uses.
- One request in flight, at least 0.25 s between requests (none inside K13's
  bursts, 1 s after a failure), a new connection per request with
  `Connection: close`, connect 3 s, total 5 s. After two failed requests in
  a row the fan counts as not answering: nothing more is sent, except one
  read by the restore. One `mf_probe.py` at a time (a lock in `build/`).
- A check runs only with `--yes-owner-told`, and only on the fan whose client
  id ends in `--expect-id`; every later answer must carry the same client id,
  and another fan answering stops everything, the restore included.
- Bodies come from the allow-list of
  [`v1-design.md` section 3.1](v1-design.md#31-requests) (the two queries,
  fan on at a speed, fan off, a direction, a light level, light on or off).
  A body naming `factoryReset`, `decommission`, `resetRfPairList`,
  `rfPairModeActive` or `reboot` anywhere is refused before anything is sent.
- The restore never starts a fan that is off just to correct the speed it
  keeps, and never flashes the light at a level it did not have (level first
  and on last when it was on; off first and level last when it was off).
  Ctrl-C during the restore waits for it.

## Reports and private data

The report (JSON on stdout) and the progress lines (stderr) can go into an
issue or a Discussion as they are; check with
`tools/gh-discussion.py --check` first. The fan's address is written `<fan>`;
the client id and the MAC `<private>...5301` (their last four hex digits);
`owner`, `federatedIdentity`, `deviceName`, `SSID`, `BSSID`, `timezone`,
`location`, `schedule`, `firmwareUrl`, certificates and other ids
`<private>`; anything the rules of `tools/gh-discussion.py` refuse is
masked, and a report that would still hold such data is not printed. Every
request is logged with its time (UTC), body, latency, outcome and the masked
answer. Raw answers are saved only with `--raw-dir`, which must lie under
`build/` (gitignored), as files only their owner can read.

## Examples

```sh
python3 tools/mf_probe.py read --fan 10.0.2.151 --static        # the id's last four digits: <private>...5301
python3 tools/mf_probe.py read --fan 10.0.2.151 --count 7 --interval 0.5 --raw-dir build/mf-raw
python3 tools/mf_probe.py check K11 --fan 10.0.2.151 --expect-id 5301 --yes-owner-told > build/mf-k11.json
python3 tools/mf_probe.py fixture --from build/mf-raw/mf-20261027T201500Z-01-read-1-of-7.json \
    --out tests/fixtures/mf_gen3_state.json
```

Exit codes: 0 done (a check: done, the state put back and verified), 1 an
error (the fan did not answer, the state was not put back), 2 refused or a
usage error (nothing was written to the fan), 130 interrupted (after the
state was put back).
