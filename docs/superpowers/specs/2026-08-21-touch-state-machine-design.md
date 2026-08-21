# mami-sound — touch state machine

Date: 2026-08-21
Status: approved design, not yet implemented

## Purpose

Replace the single absolute threshold that decides when a plant is touched with
a two-stage state machine that decides *which* plant is touched.

The installation has two biopotential probes on one ADS1115: plant A on AIN0,
plants B and C sharing one on AIN1. Today a single `--trigger=LEVEL` compares
the rectified AIN1 reading against a number typed on the command line. No number
has been found that works: it fires on nothing, or refuses to fire on a hand.
This design says why that is, and replaces the threshold with a per-probe
z-score against each probe's own rolling statistics, plus an arbitration stage
that separates a genuine touch from crosstalk.

## Why the threshold cannot exist today

Bench capture, two columns of raw ADS1115 counts, column 1 = probe A,
column 2 = probe BC:

| probe | untouched | touched |
|---|---|---|
| A  | −2049 … −2050, σ ≈ 0.5 | ≈ +660 (358 … 1086) |
| BC | +15 … +2023, σ ≈ 600 | −2048 … −2050, sometimes −3947 / −3766 |

Both probes separate cleanly **in signed counts**. But `sensors.ecgFromAdc`
rectifies before anything downstream sees the reading:

```
BC untouched, worst case:  +2023  ->  2023
BC touched:                −2049  ->  2049
                                       ^^^ 26 counts apart
```

Rectification folds BC's touched state onto its untouched state. It also
inverts A: touching A *lowers* its rectified value (2049 → 660) while touching
BC *raises* it (1000 → 2049), so one threshold cannot serve both directions
whatever value it takes.

A second consequence, in the audio path: `noise.freqFromEcg` maps the rectified
reading across 0…32767, but this rig's signal lives inside ±4000 counts. A
untouched lands on 25.5 Hz and A touched on 21.6 Hz — the whole piece is
squashed into the bottom 5 Hz of a 20–1000 Hz range, running backwards.

Rectification is removed entirely. Nothing downstream needs it once pitch comes
from deviation rather than level.

## Architecture

New `src/touch.zig`, which knows nothing about plants, clips or I2C: it takes
two signed readings per poll and returns a state. It imports nothing from
`sensors.zig` or `noise.zig`, so its tests are arrays of numbers.

```zig
pub const State = enum { none, plant_a, plant_bc, both };

pub const Mean;       // signed running mean over a window of polls
pub const Baseline;   // decimated rolling median + MAD
pub const Detector;   // one probe: Mean -> Baseline -> z -> hysteresis latch
pub const Machine;    // two Detectors + crosstalk arbitration -> State
pub fn holdPolls(ms: f32, sample_rate: u32, poll_frames: usize) u32;
```

Data flow per poll, in `main.zig`'s inner loop:

```
sens.tick() -> raw_a, raw_bc  (signed)
  -> machine.update(raw_a, raw_bc) -> State
     -> voice_a.render(piece, deviation_a, a_touched)
     -> voices_bc.render(piece, bc_touched)
     -> log.row(...)          // when --log-touch is given
```

`src/touchlog.zig` writes the CSV. `touch.zig` performs no I/O.

## Stage 1 — per-probe detection

```
raw i16 ──> signed mean over --touch-average (200 ms)       = mean
        ──> rolling median of decimated means (60 s @ 10 Hz) = base
        ──> median |sample − base| over the same buffer      = mad
            z = (mean − base) / @max(mad, mad_floor)
            vote: @abs(z) >= --touch-level
            hysteresis counter: climbs on a vote, decays otherwise,
            latches on at --touch-hold, releases at 0
```

### Signed mean

A true mean over a window of polls, not a one-pole smoother, so a spike
contributes exactly one sample's worth and leaves the window entirely once the
window has passed. Signed: the sign is the whole signal on this rig.

The mean divides by however many polls have arrived until the window is full,
rather than by the window length, so it answers from the first poll.

### Baseline: rolling median and MAD

Median rather than a leaky average because a median is inherently touch-proof:
a touch shorter than half the window cannot move it, so no freeze-while-touched
logic is needed.

Pushed at 10 Hz rather than at the poll rate (344 polls/s): 60 s of window is
600 samples instead of 20,000. Buffer is `[1024]i16`, covering windows up to ~100 s. Median and MAD are recomputed on
push only — two sorts of ≤1024 elements at 10 Hz — and cached between pushes.

What is pushed is the *mean*, not the raw reading, so the baseline measures the
same quantity the z-score compares against.

MAD is the median of `|sample − base|` over the same buffer.

### Why z and not a relative score

Dividing the deviation by the baseline fails on this rig: A's baseline is
negative. MAD is always positive and answers the right question — how surprising
is this reading for *this* probe. Against the captured data:

| | base | mad | touched | z |
|---|---|---|---|---|
| A | −2049 | ≈0.5 → floor 25 | +660 | **+108** |
| BC | ≈+1000 | ≈150 (estimated) | −2049 | **−20** |
| A idle jitter | −2049 | 25 | −2050 | 0.04 |

BC's MAD is an estimate, and the one number here that is not read directly off
the capture. It is the deviation of the *200 ms means*, not of the raw samples,
so it depends on how much averaging smooths BC's idle noise — which in turn
depends on whether that noise is white or correlated, something a capture
without timestamps cannot say. The raw spread is about 500 counts; the mean's
will be smaller. A live CSV settles it.

`--touch-level = 6` clears both by a factor of three or more and never
approaches idle jitter. One number serves both probes, and it re-derives itself
every session: a baseline that drifts from −2049 to something else next week
needs no retuning.

`mad_floor = 25` counts exists because probe A is *too* quiet. Its true MAD of
≈0.5 would score a one-count wobble at z = 2.

### Warm-up

The median is taken over however many samples have arrived, but a Detector is
forced off until 3 s of samples exist. Without this the first seconds — when
base ≈ mean ≈ whatever — produce meaningless z and can start a clip at startup.

## Stage 2 — arbitration

Probe A is dominant: in the capture, touching A pulls BC to ≈ −2049, while
touching BC leaves A at −2050. The rule is therefore one-directional. Crosstalk
parks BC at the same value a genuine BC-only touch produces, so level alone
cannot separate them; what separates them is that a real simultaneous touch goes
*further* (−3947 / −3766).

```
on A's rising edge, and only if BC is currently off:
    suppress BC for --touch-settle (300 ms)      // ignore the transition itself
    freeze BC's median buffer                    // crosstalk must not poison idle stats
    at settle expiry:
        bc.base := BC's current mean             // the crosstalk floor, ≈ −2049
        bc.mad  := unchanged (idle mad, ≈150)

on A's falling edge:
    bc.base reverts to the idle median; buffer unfreezes
```

BC then needs the same `|z| >= 6` measured from the crosstalk floor: a steady
−2049 gives z ≈ 0 and does not fire, while −3947 is 1898 counts further out and
fires if BC's MAD is under about 316. That last condition is the design's one
unverified number — see the note on BC's MAD above — and it is the first thing
to read off a live CSV.

If BC is already latched when A rises, it is left alone — a touch already in
progress is never re-baselined out from under itself.

Using the idle MAD rather than the crosstalk-period MAD is deliberate: while
pinned, BC's real variance is ≈1 count, which would make any wobble score huge.

## Audio mapping

```
none      -> drone at rest pitch, idle gain, no clips
plant_a   -> drone tracks A's deviation, full gain
plant_bc  -> drone at rest pitch + clip B or C starts
both      -> drone tracks A + clip starts
```

Pitch comes from deviation rather than level:

```
dev = |mean − base|
t   = clamp(dev / --pitch-span, 0, 1)          // span default 3000 counts
freq = freq_min * (freq_max / freq_min) ^ t
```

Rest (dev 0) is `freq_min`; A touched (dev ≈ 2709) gives t ≈ 0.90 and ≈ 680 Hz.
This also delivers "while B is touched, A holds around its average" with no
special case: A's deviation is ≈0, so A sits at rest pitch.

`freq_min` rises from 20 Hz to **80 Hz** so rest is a low audible hum rather
than something felt but not heard. `noise.zig` gains an `idle_gain` (0.35): the
gate target is 1.0 when touched and `idle_gain` otherwise, instead of 0.0, so
the room is never silent. The `flute` and `beep` debug voices keep gating to
zero — they are bench tools, not the installation.

Clip behaviour is unchanged: `bc_touched` decides only when a clip *starts*.
Once started it runs to its end or until `--interrupt`.

## CLI

Removed: `--trigger`, `--trigger-hold`, `--trigger-average`. Passing any of them
prints a line naming its replacement rather than "unknown flag".

```
--touch=probes|always|script|motion   where state comes from (default probes)
--touch-level=Z        6.0    |z| needed to latch
--touch-hold=MS        100    how long z must hold it
--touch-average=MS     200    signed mean window
--touch-baseline=S     60     rolling median window
--touch-settle=MS      300    crosstalk re-baseline delay
--pitch-span=COUNTS    3000   deviation mapping to freq_max
--log-touch=PATH       -      CSV, see below
```

`--touch=probes` is the installation. `always`, `script` and `motion` force or
script the state for demonstration and bench work without electrodes. Under
`motion` the state is built from the GPIO lines: plant A's line gives
`plant_a`, either of B's or C's gives `plant_bc`.

## CSV log

One row per poll (344 rows/s, ≈20 MB per 15 minutes), buffered, flushed once per
block:

```
t_s,raw_a,mean_a,base_a,mad_a,z_a,on_a,raw_bc,mean_bc,base_bc,mad_bc,z_bc,on_bc,state
```

Every number the decision was made from, so a wrong latch is replayed offline
instead of re-touched in the room.

The status line gains the two z values and the state name.

## Known limitation

A median over 60 s is touch-proof only for touches shorter than about 30 s.
Hold plant A for a minute and the median migrates toward the touched level, z
decays, and the state reads as released. `--touch-baseline` is the knob: set it
to roughly four times the longest expected touch. The default assumes touches
under ~15 s.

This is asserted by a test rather than left to be discovered.

**Measured, 2026-08-22.** Replaying the capture through the finished machine,
the BC-only touch scores **z = −5.66** against a level of 6.0. It does not
latch. The replay holds each row for a constant second of polls, so the 200 ms
mean settles exactly onto the row's value and BC's MAD is the raw spread of the
rows — 548 counts, with no averaging benefit at all. The rig samples 344 times a
second, so a real 200 ms mean covers 69 samples and BC's MAD is smaller by
somewhere between a little and a factor of eight, depending on how correlated
the noise is. The replay is a zero-smoothing worst case the installation never
runs in, and no choice of replay rate escapes it, because the captured rows are
constant.

What this means for the installation: if the real rig smooths as little as the
fixture does, `--touch-level` must come down to about **5.1** before a BC-only
touch will fire. Whether it needs to is the first thing a live CSV answers, and
it now outranks every other open question here. The same measurement is
reassuring about the other half of the design — BC's score on the crosstalk rows
came out at −0.00, so the re-baselining silences the pull almost exactly.

A second limitation is smaller but sharper: `both` requires a touch on BC to
clear the threshold measured from the crosstalk floor, and the margin there
rests on BC's MAD, which this capture cannot pin down. If it turns out too
tight, the lever is a longer `--touch-average` — which shrinks BC's MAD by
smoothing its idle — rather than a lower `--touch-level`, which would loosen
both probes in every state.

## Testing

The bench capture becomes `src/testdata/touch-sample.txt` and is replayed
through `Machine` via `@embedFile`. It carries no timestamps, so the replay
holds each row for a second of polls and asserts the claims that survive not
knowing the capture rate, rather than an exact state sequence:

- the 29 idle rows produce `none` throughout — the false-positive claim, and the
  one that matters most in a gallery
- the rows where A alone has moved produce `plant_a`
- the rows where A is held and BC sits on the crosstalk floor produce
  `plant_a`, not `both` — even though those rows read identically to the row
  where BC is genuinely touched alone
- the single row with A at rest and BC negative is *seen*: BC's score there is
  five and a half deviations out, where the rectified reading was 2049 and sat
  inside the idle spread no threshold could separate. That it does not *latch*
  is asserted deliberately — see the measurement below
- BC's score on the crosstalk rows is far smaller in magnitude than its score on
  that row, which is the arbitration demonstrated on measured data: the same
  −2049 reading, loud when BC is touched alone and silent when it is only being
  dragged

The `both` case is left to a synthetic test, where the sample rate is known.

Unit tests:

- median and MAD over a partly-filled buffer (warm-up)
- a Detector is off until the warm-up period has passed
- A's pinned idle (−2049/−2050 forever) never latches
- the −2049 → +660 step latches after `--touch-hold` and not before
- BC's noisy positive idle (+15…+2023) never latches
- BC alone reaching −2049 latches
- with A latched, BC held at −2049 stays off; BC reaching −3947 latches
- BC latched before A rises is not re-baselined
- both probes returning to idle releases to `none`
- a touch longer than half the baseline window reads as released (the
  documented limitation)
- `holdPolls` converts milliseconds to whole polls and never to zero

## Files

| file | change |
|---|---|
| `src/touch.zig` | new — `Mean`, `Baseline`, `Detector`, `Machine`, `holdPolls` |
| `src/touchlog.zig` | new — CSV writer |
| `src/testdata/touch-sample.txt` | new — the bench capture |
| `src/trigger.zig` | deleted — `Trigger` has no caller left; `Average` was rectified-only and is replaced by the signed `Mean` |
| `src/sensors.zig` | `Reading` carries signed raw; `ecgFromAdc` deleted; simulated walks retuned to the real rig (A pinned near −2049, BC noisy positive) so a no-hardware run exercises the machine |
| `src/noise.zig` | `freq_min` 20→80, `idle_gain`, `span` replaces `ecg_max`, input is deviation |
| `src/cli.zig` | flags above |
| `src/main.zig` | wiring; status line shows z and state |
| `src/root.zig` | export `touch` and `touchlog`, drop `trigger` |

## Out of scope

- The three GPIO motion lines stay wired and unconsulted. `gpio.zig` is
  unchanged and remains reachable through `--touch=motion`.
- Crosstalk from BC into A. The capture shows none; if it appears, the
  arbitration is written so the mirrored rule is a small addition.
- Any change to clip selection, the sequencer, or the sink.
