# The learned model on a probe that wanders

2026-09-16

## The rig this is about

Probe A on the current rig rests nowhere. Untouched it wanders across the
middle of the range, thousands of counts at a time, and a touch takes it to a
rail and parks it there — sometimes the top, sometimes the bottom, on the same
probe in the same evening.

Sixteen seconds of the room's journal, one poll a second:

```
idle    10545  21330  19894  10571  12020  14746  6638  7436  10323
touch       1      1      2      1      0      0  1200     1
```

The touch is the tight one. Rest is the smear.

This is the inverse of every rig the model was measured on. There a probe rests
flat and a hand makes it flail: `flipping(poll, 5, 25700, 8)` in the fixtures,
a held probe that throws home constantly and never holds still for a poll. Here
rest is the flailing and the hand is the stillness. Both rigs are real and both
have to keep working.

## Why the model refuses

`stepLearned` asks two questions of the long window.

**The gap is full.** `readable` (`touch.zig:1011`) requires `dead <= 0.15` — at
most a seventh of the readings may sit in the middle third between rest and the
far level. Against `r0 = 5151`, `high ≈ 21330`, `low ≈ 0`: `reach = 16179`,
middle third is raw ∈ [10490, 15990], and four of the sixteen readings above
land in it. That is 0.25 on a thin sample, and the idle median of ~11300 sits
dead centre of the band, so over the real three-thousand-sample window it is
higher. `readable` is false, `away` is false on every poll, and the branch at
`touch.zig:1026` returns quiet forever.

The repo already holds this probe as a fixture and asserts it must stay quiet:

```zig
fn wandering(rng: std.Random) i16 { return rng.intRangeAtMost(i16, 9776, 15976); }

test "a probe that only wanders has no two levels to find"
```

That is `service-log4`'s probe A, the same shape as the journal above. So the
model is not malfunctioning. It is doing what it was told: a probe whose gap is
full cannot be read by a share, because a share low enough to answer a real hand
is also low enough for a wanderer to clear by accident — 0.399 untouched against
0.400 touched on that log.

**Only one end is watched.** Past the gate, `touch.zig:1020-1024` takes
`if (up >= down)` and arms a half-line on that side alone. A probe whose touches
go both ways in one run loses every touch in the other direction, silently. No
existing fixture covers that — each rig in
`"a touch is answered wherever the probe rests and whichever way it goes"` uses
a fresh detector and visits one end.

## What changes

`dead` stops being a refusal and becomes the choice of which question to ask.
A probe with two clean levels is read by the share, exactly as now. A probe
whose gap is full is no longer written off — it is asked the one question that
still separates a hand from the wander on such a rig: **did the window park,
and did it park away from home.**

```zig
const rest = self.baseline.base;
const up = clampedAbsDiff(self.baseline.high, rest);
const down = clampedAbsDiff(self.baseline.low, rest);
const reach = @max(up, down);

// Each end gets a line at the midpoint between rest and that end's own
// level, and a side is armed only where its own reach is worth arming.
const hi_line: ?i16 = if (up >= self.still_move)
    saturatingAdd(rest, @divTrunc(up, 2)) else null;
const lo_line: ?i16 = if (down >= self.still_move)
    saturatingAdd(rest, -@divTrunc(down, 2)) else null;

const second_level = hi_line != null or lo_line != null;
const readable = self.baseline.dead <= max_dead;

self.spread.watchEdges(lo_line, hi_line);

var past = false;
if (lo_line) |lo| { if (level <= lo) past = true; }
if (hi_line) |hi| { if (level >= hi) past = true; }

const away = if (second_level and readable)
    @max(self.spread.above, self.spread.below) >= self.band_share
else if (second_level)
    self.spread.range <= self.learned_park and past
else
    clampedAbsDiff(level, rest) >= self.still_move;
```

### Both ends, each on its own line

Asymmetric on purpose: a probe reaching 15000 up and 5000 down gets its lines at
`rest + 7500` and `rest - 2500`, which is where those two ends actually are. A
single `reach/2` would put the near end's line past the end itself — on the
journal above, `reach/2` is 8089 while the whole downward excursion is 5151, so
a real touch at the bottom would never cross it.

### The share is a maximum, never a sum

A probe wandering across its range spends about a quarter of the window past
each line. Summed that is 0.5, close enough to `band_share` of 0.6 that the
separation is gone. Taken separately the wanderer scores 0.25 and a probe parked
at one rail scores near 1.0.

The count also survives the dropouts this rig throws through a good touch. The
journal's `25886, 735, 10, 12, 25886, 25886, 9, 25886` is five of eight past the
upper line — 0.625, still a touch.

### Parking is only ever asked of the unreadable branch

This is the part that must not leak. Stillness cannot be a general gate for
`learned`: on the flipping rig a held probe is never still for a single poll,
and a stillness gate there rejects every real hand. It is asked only where the
gap is full, which is the one case where the share has already been shown to
mean nothing.

The same restriction is what keeps the drift protection. A probe whose home has
moved — `wanderedHome`, 11275 to 13353 — sits a long way from a stale rest and
would score a share of 1.0, which is the ninety-six seconds of a clip looping at
an empty plant the fixture exists for. But a drifted probe is *still wandering*:
its window range is about 1250. A hand parks: range about 2. That is the whole
separation, and it is worth stating plainly — **drift wanders, a hand parks.**

`still_range` at 32 cannot serve. It was measured for the steady model on the
flipping rig. The parked branch gets its own constant, `default_learned_park`,
at **512**: two and a half times under the drifted probe's 1250 and two hundred
times over a parked touch's 2. No release threshold — `settle`'s existing hold
and drop counters carry the hysteresis, and a second number here would be one
nobody measured.

## Spread gains two edges

`Spread.watch`/`inside` already counts one side, which is how the current share
branch works (`watch(lo, null)` means "share at or above lo"). Two sides at once
needs two counters, computed in the sort pass `recompute` already does:

```zig
edge_lo: ?i16,
edge_hi: ?i16,
below: f32,   // share of the window at or below edge_lo, 0 when unset
above: f32,   // share of the window at or above edge_hi, 0 when unset

pub fn watchEdges(self: *Spread, lo: ?i16, hi: ?i16) void
```

`watch`/`inside` stay exactly as they are, so the steady model and any
room-given band are untouched. `stepLearned` stops calling `watch`.

One existing test reads the old field:

```zig
test "a hand under half the window is counted, not written off"
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), detector.spread.inside, 0.06);
```

It moves to `detector.spread.above`. Same quantity, same number, new name — the
test's claim is unchanged.

## The log says why

`z0`/`z1` are written only on the deviation path (`touch.zig:1119`), so under
`learned` the status line prints `z0=0.0` on every poll — a field that has told
the room nothing since the model was added. It carries
`@max(above, below)` instead, the number the decision is made on. `l0` and `r0`
keep their meanings.

A quiet plant is then readable off one line: `r0` where the model thinks home
is, `l0` where the probe is now, `z0` how much of the last window was past the
line.

## Untouched

- **The pitch.** `deviation()` for `learned` already returns
  `|spread.level - baseline.base|`, unsigned, so it answers a touch at either
  rail the same way. The `learned`/ramp pairing in `production_config.zig:196`
  stands.
- **`deviation` and `steady`.** Neither shares a code path with this.
- **`Machine` arbitration, the tap window, `Baseline`.** `dead` keeps being
  computed and keeps deciding; it only stops being final.
- **The preset.** It stays on `.deviation`. Moving the rig to `learned` is a
  separate decision, with the capture in hand.

## Testing

Every existing `learned` fixture must still pass unchanged, except the one
rename above. Four of them are the guard rails for this change:

| Fixture | Holds |
|---|---|
| `a probe that only wanders has no two levels to find` | wanderer's range ~3700 > 512, and its level sits between the lines |
| `a probe whose home moves is quiet on the way` | drift's range ~1250 > 512 |
| `a hand on a probe that drops out half the time is still a hand` | `readable` true there, so it never reaches the parked branch |
| `a long hand does not become where the probe lives` | same |

New fixtures, built from the journal rather than invented:

1. **A parked touch at the bottom latches on a wandering probe.** Idle uniform
   6638–21330, then a parked run at 0–2 with a 1200 every eighth poll.
2. **A parked touch at the top latches on the same detector in the same run.**
   The same wander, then a parked run at 25900. Both directions in one
   detector — the defect at `touch.zig:1020-1024` stated as a test.
3. **The wander alone never latches**, at the preset's own `band_share`.
4. **A dead probe never latches.** Flat at one value forever: parked, so the
   range gate says yes and `past` must say no.
5. **Maximum, not sum.** A uniform wander scores under `band_share` on the
   maximum. Pins the choice so a later simplification fails loudly.
6. **`watchEdges` counts both sides, and neither when unset**, and
   `watch`/`inside` still behave as they did.

Then the capture, which is what confirms `default_learned_park`:

```
mami_sound --capture=rig.csv --capture-seconds=900
zig build replay -- rig.csv --model=learned --sweep
```

Touching plant A both directions several times during it.

## Order

1. `Spread.watchEdges` with its tests.
2. `stepLearned` on both ends, share as a maximum, `watch` → `watchEdges`;
   fixtures 2, 5, and the renamed assertion.
3. The parked branch and `default_learned_park`; fixtures 1, 3, 4.
4. The share into `z0`.
5. Capture, sweep, confirm or replace 512.

Steps 1–4 are verifiable in the tree. Step 5 needs the room.
