# The learned model on a probe that wanders

2026-09-16

## The rig this is about

Probe A on the current rig rests nowhere. Untouched it wanders across the
middle of the range, thousands of counts at a time, and a touch takes it to a
rail and holds it there — sometimes the top, sometimes the bottom, on the same
probe in the same evening.

Sixteen seconds of the room's journal, one poll a second:

```
idle    10545  21330  19894  10571  12020  14746  6638  7436  10323
touch       1      1      2      1      0      0  1200     1
```

The touch is the tight one. Rest is the smear.

## Why the model refuses

`stepLearned` asks two questions of the long window and both give the wrong
answer here.

**The gap is full.** `readable` (`touch.zig:1011`) requires `dead <= 0.15` —
at most a seventh of the readings may sit in the middle third between rest and
the far level. Against `r0 = 5151`, `high ≈ 21330`, `low ≈ 0`: `reach = 16179`,
middle third is raw ∈ [10490, 15990], and four of the sixteen readings above
land in it. That is 0.25 on a thin sample, and the idle median of ~11300 sits
dead centre of the band, so over the real three-thousand-sample window it is
higher still. `readable` is false, `away` is false on every poll, and the branch
at `touch.zig:1026` returns quiet forever.

The test is not wrong. It asks whether the window holds two levels or one
wander, and it was measured on probes where rest is a level: 0.031 to 0.067 on
every probe that visits two, 0.577 on the one that only wanders. This probe
wanders. The model's own assumption — tight rest cluster, tight touch cluster,
empty gap — is inverted here, because rest *is* the gap.

**Only one end is watched.** Past the gate, `touch.zig:1020-1024` takes
`if (up >= down)` and arms a half-line on that side alone. A rig whose touches
go both ways loses every touch in the other direction, silently.

## What replaces them

Three changes, all inside `stepLearned` and `Spread`. Nothing outside the
detector sees a difference.

### Both ends, each on its own line

Each end gets a half-line at the midpoint between rest and that end's own
level, and a side is armed only if its own reach clears `still_move`:

```zig
const rest = self.baseline.base;
const up   = clampedAbsDiff(self.baseline.high, rest);
const down = clampedAbsDiff(self.baseline.low, rest);

const hi_line = if (up >= self.still_move)
    saturatingAdd(rest, @divTrunc(up, 2)) else null;
const lo_line = if (down >= self.still_move)
    saturatingAdd(rest, -@divTrunc(down, 2)) else null;
```

Asymmetric on purpose: a probe reaching 15000 up and 5000 down gets its lines at
`rest + 7500` and `rest - 2500`, which is where those two ends actually are.

### The share is a maximum, never a sum

```zig
self.spread.watchEnds(lo_line, hi_line);
const share = @max(self.spread.above, self.spread.below);
const away = share >= self.band_share;
```

Maximum rather than sum, and this is the load-bearing choice. A probe wandering
across its whole range spends about a quarter of the window past each line;
summed that is 0.5, which sits close enough to `band_share` of 0.6 that the
separation the test exists for is gone. Taken separately the wanderer scores
0.25 and a probe parked at one rail scores near 1.0.

The count also survives the dropouts this rig throws through a good touch. The
journal's `25886, 735, 10, 12, 25886, 25886, 9, 25886` is five of eight past the
upper line — 0.625, still a touch.

### Stillness is the drift guard

`readable` was not only a two-levels test. It was what stopped a probe whose
home had moved from latching at an empty plant: after a drift the whole window
sits on one side of a rest that has not caught up, `share` reads 1.0, and the
model reports a hand that never arrived and never leaves. The room's own capture
has ninety-six seconds of that, looping a clip throughout.

Two guards were considered and rejected:

- **Requiring the long window to still hold readings near rest.** It reads
  healthy exactly when it must fire. During the dangerous stretch of a drift the
  window is split between the old home and the new one, so the old home is still
  there in quantity, and the guard passes.
- **`baseline_stale_s` alone.** Twenty minutes is the right backstop for a probe
  wedged permanently, and no use at all against a false hold of ninety-six
  seconds.

What separates a hand from drift on this rig is in the data already: a drifted
probe is still wandering, and a held one is parked. So the share says *which*
end and the spread says *parked*:

```zig
const held = away and self.spread.range <= self.learned_range;
const loose = !away or self.spread.range >= self.learned_release;
```

This contradicts the comment at `touch.zig:1057-1062`, which says stillness is
the one thing this rig will not give. That was written about the other rig —
flat nought at rest, 25886 under a hand, rails through the touch — where the
untouched reading has no spread either and a stillness gate separates nothing.
Here the untouched reading has thousands of counts of spread and the touch has
single digits. The comment is retired with the model it described, and the
change note says why.

`still_range` at 32 is too tight for it. A parked touch with a dropout every
eighth poll has a 20th-to-80th-percentile range in the single digits, and the
idle wander has thousands; anything from a few hundred to a couple of thousand
separates them with enormous margin. The model gets its own pair —
`default_learned_range` and `default_learned_release` — rather than borrowing
the steady model's, whose numbers were measured on the other rig and mean
something different there.

**The numbers in those two constants are provisional and must not ship
unmeasured.** There is no capture of this rig: `probes.csv` opens at
`raw_a=1` and `touch.csv` at `raw_a=653`, both the old one. The provisional
pair is 256 and 1024, chosen to sit in the middle of the gap the journal
implies, and the capture replaces them.

## Spread gains two lines

`Spread` already counts the share inside a band for the steady model. It gains
the same thing pointing outward, computed in the sort pass `recompute` already
does:

```zig
edge_lo: ?i16,
edge_hi: ?i16,
below: f32,   // share of window strictly below edge_lo, 0 when unset
above: f32,   // share of window strictly above edge_hi, 0 when unset

pub fn watchEnds(self: *Spread, lo: ?i16, hi: ?i16) void
```

`watch`/`inside` are untouched, so the steady model and any room-given band
behave exactly as before.

## The log says why

`z0`/`z1` are written only on the deviation path (`touch.zig:1119`), so under
`learned` the status line prints `z0=0.0` on every poll — a field that has told
the room nothing since the model was added. It carries the share instead:
`max(above, below)`, the number the decision is actually made on. `l0` and `r0`
keep their meanings.

With that, a quiet plant is readable off one line: `r0` says where the model
thinks home is, `l0` where the probe is now, `z0` how much of the last window
was past the line.

## Untouched

- The pitch. `deviation()` for `learned` already returns
  `|spread.level - baseline.base|`, which is unsigned and so answers a touch at
  either rail the same way. The `learned`/ramp pairing in
  `production_config.zig:196` stands.
- `deviation` and `steady`. Neither shares a code path with this.
- `Machine` arbitration, the tap window, `Baseline.dead`. `dead` stops being
  read by `stepLearned` but is left computed and tested — it is the one measured
  description of the old rigs in the tree.
- The preset. It stays on `.deviation`; moving the rig to `learned` is a
  separate decision with the capture in hand.

## Testing

Fixtures go beside the existing ones in `src/core/touch.zig`, built from the
journal's shape rather than invented:

1. **A touch at the bottom latches.** Idle wander 6000–21000, then a parked run
   at 0–2 with a 1200 every eighth poll. Must latch, and must have latched on
   `below`.
2. **A touch at the top latches, same detector, same run.** The same wander,
   then a parked run at 25900. Both directions in one test, which is the defect
   at `touch.zig:1020-1024` stated as a test.
3. **The wander alone never latches.** Fifteen minutes of 6000–21000 and
   nothing else. This is the test the current model passes by refusing to judge
   and the new one must pass by judging.
4. **A drifted probe never latches.** Home steps from 11000 to 24000 and keeps
   wandering with the same spread. Covers the ninety-six seconds.
5. **A dead probe never latches.** Flat at one value forever: parked, so the
   stillness gate says yes and `still_move` must say no.
6. **Sum versus maximum.** A uniform wander scores under `band_share` on the
   maximum. Pins the choice so a later simplification to a sum fails loudly.
7. **`watchEnds` counts both sides and neither when unset**, and `watch`/
   `inside` still behave as they did.

Then the capture, which is what settles the two constants:

```
mami_sound --capture=rig.csv --capture-seconds=900
zig build replay -- rig.csv --model=learned --sweep
```

Touching plant A both directions several times during it.

## Order

1. `Spread.watchEnds` with its tests.
2. `stepLearned` on both ends with the share as a maximum; fixtures 1, 2, 3, 6.
3. The stillness gate and its constants; fixtures 4, 5.
4. The share into `z0`.
5. Capture, sweep, replace the provisional constants with measured ones.

Steps 1–4 are verifiable in the tree. Step 5 needs the room.
