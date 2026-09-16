# Learned Model, Both Ends and a Parked Branch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `learned` touch model answer a probe that wanders when untouched and parks at either rail when touched, without changing how it answers the rigs it already serves.

**Architecture:** Two changes inside `src/core/touch.zig` and one inside `src/core/spread.zig`. `Spread` learns to count the share of its window beyond a low edge and beyond a high edge at the same time. `stepLearned` arms a line at each end instead of one, takes the share as a maximum of the two, and stops treating a full gap as a refusal — a probe whose gap is full is asked instead whether its window parked away from home.

**Tech Stack:** Zig. No dependencies. Tests are `test` blocks in the same files as the code, run by `zig build test-core`.

**Spec:** `docs/superpowers/specs/2026-09-16-learned-both-ends-design.md`

## Global Constraints

- Zig, no new dependencies, no allocations on the audio thread. `Spread.recompute` uses a stack `scratch` buffer; keep it that way.
- Every existing test in `src/core/` must pass. One assertion is deliberately renamed (Task 2, Step 5); nothing else may change.
- `deviation` and `steady` model behaviour must not change. Neither shares a code path with this work.
- The production preset stays `.model = .deviation` in `src/application/production_config.zig`. Do not change it.
- Doc comments in this codebase explain *why*, in prose, in the voice of the surrounding file. Match that. Do not write `// set the flag` comments.
- Constants that are thresholds get a doc comment saying what they were measured against.
- `zig` may not be on `PATH` in every shell; the executor needs a machine where `zig build test-core` runs.

---

### Task 1: `Spread` counts both edges

**Files:**
- Modify: `src/core/spread.zig:52-101` (struct fields and `init`), `src/core/spread.zig:126-151` (`recompute`), and add `watchEdges` beside `watch` at `src/core/spread.zig:100`
- Test: `src/core/spread.zig` (test blocks at the end of the same file)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `pub fn watchEdges(self: *Spread, lo: ?i16, hi: ?i16) void`, and two public fields `below: f32` and `above: f32` on `Spread`. `below` is the share of the window at or below `lo`; `above` is the share at or above `hi`. Both are `0.0` when their edge is `null`. Task 2 and Task 3 read them.

- [ ] **Step 1: Write the failing tests**

Add at the end of `src/core/spread.zig`, after the existing test blocks:

```zig
test "the share past each edge is counted on its own" {
    // Two lines rather than one, because the model that asks this has to know
    // WHICH end a probe went to. Summed they would say only that it left the
    // middle, which a probe merely wandering does as often as a hand does.
    var spread: Spread = .init(1000.0, 44100, 128);
    spread.watchEdges(200, 800);

    // Three readings in ten below the low edge, five in ten above the high one.
    for (0..spread.len) |i| spread.push(switch (i % 10) {
        0, 1, 2 => 100,
        3, 4 => 500,
        else => 900,
    });

    try std.testing.expectApproxEqAbs(@as(f32, 0.3), spread.below, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), spread.above, 0.02);
}

test "an edge nobody set counts nothing" {
    var spread: Spread = .init(1000.0, 44100, 128);
    spread.watchEdges(null, 800);
    for (0..spread.len) |_| spread.push(900);

    try std.testing.expectEqual(@as(f32, 0.0), spread.below);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), spread.above, 0.001);

    // And neither edge set is neither count.
    var bare: Spread = .init(1000.0, 44100, 128);
    for (0..bare.len) |_| bare.push(900);
    try std.testing.expectEqual(@as(f32, 0.0), bare.below);
    try std.testing.expectEqual(@as(f32, 0.0), bare.above);
}

test "the edges leave the band alone" {
    // `watch` and `inside` are the steady model's, and a room that set a band
    // must go on getting exactly the answer it got before.
    var spread: Spread = .init(1000.0, 44100, 128);
    spread.watch(650, 660);
    spread.watchEdges(200, 800);
    for (0..spread.len) |i| spread.push(if (i % 5 == 0) 900 else 655);

    try std.testing.expectApproxEqAbs(@as(f32, 0.8), spread.inside, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), spread.above, 0.02);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test-core`

Expected: compile error — `no field named 'watchEdges' in struct 'spread.Spread'` (or `below`/`above` not found). A compile failure is the correct failing state here; Zig cannot run a test that names a method that does not exist.

- [ ] **Step 3: Add the fields**

In `src/core/spread.zig`, after the `band_lo`/`band_hi`/`inside` fields (ends at `src/core/spread.zig:77`), add:

```zig
    /// Two lines, and the share of the window beyond each.
    ///
    /// The band above asks how much of the window is in one place. This asks
    /// how much of it is past a line, at each end separately — which is a
    /// different question and cannot be answered by the band, because a model
    /// watching both ends of a probe needs to know which end the window went
    /// to. Summed, the two counts say only that the probe left the middle, and
    /// a probe merely wandering leaves the middle as much as a hand does.
    edge_lo: ?i16,
    edge_hi: ?i16,
    below: f32,
    above: f32,
```

In `init`, alongside `.inside = 0.0,`:

```zig
            .edge_lo = null,
            .edge_hi = null,
            .below = 0.0,
            .above = 0.0,
```

- [ ] **Step 4: Add `watchEdges`**

Immediately after the existing `watch` function (`src/core/spread.zig:100`):

```zig
    /// Say where the two lines are, so the share past each can be counted.
    ///
    /// Either may be `null`, which is that end not being watched at all and
    /// its count staying at nought.
    pub fn watchEdges(self: *Spread, lo: ?i16, hi: ?i16) void {
        self.edge_lo = lo;
        self.edge_hi = hi;
    }
```

- [ ] **Step 5: Count them in `recompute`**

In `src/core/spread.zig`, inside `recompute`, replace the early return in the band block so both counts are always computed. The band block currently reads:

```zig
        if (self.band_lo == null and self.band_hi == null) {
            self.inside = 0.0;
            return;
        }
        var within: usize = 0;
        for (scratch[0..n]) |sample| {
            if (self.band_lo) |band_lo| if (sample < band_lo) continue;
            if (self.band_hi) |band_hi| if (sample > band_hi) continue;
            within += 1;
        }
        self.inside = @as(f32, @floatFromInt(within)) / @as(f32, @floatFromInt(n));
```

Replace it with:

```zig
        const total = @as(f32, @floatFromInt(n));

        // Counted in the same pass the sort was for, so asking costs nothing
        // extra on the audio thread.
        if (self.band_lo == null and self.band_hi == null) {
            self.inside = 0.0;
        } else {
            var within: usize = 0;
            for (scratch[0..n]) |sample| {
                if (self.band_lo) |band_lo| if (sample < band_lo) continue;
                if (self.band_hi) |band_hi| if (sample > band_hi) continue;
                within += 1;
            }
            self.inside = @as(f32, @floatFromInt(within)) / total;
        }

        var under: usize = 0;
        var over: usize = 0;
        for (scratch[0..n]) |sample| {
            if (self.edge_lo) |lo| if (sample <= lo) {
                under += 1;
            };
            if (self.edge_hi) |hi| if (sample >= hi) {
                over += 1;
            };
        }
        self.below = if (self.edge_lo == null) 0.0 else @as(f32, @floatFromInt(under)) / total;
        self.above = if (self.edge_hi == null) 0.0 else @as(f32, @floatFromInt(over)) / total;
```

Delete the now-duplicated `// Counted in the same pass...` comment from its old position above the band block if it is left stranded.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test-core`

Expected: PASS, all of it. The three new tests pass and no existing `spread.zig` or `touch.zig` test has changed behaviour — nothing calls `watchEdges` yet, so `below` and `above` are `0.0` everywhere else.

- [ ] **Step 7: Commit**

```bash
git add src/core/spread.zig
git commit -m "feat(core): the window can be asked about each of its ends

A band says how much of the window is in one place. A model watching a
probe that a hand takes to either rail has to know which rail it went
to, and the band cannot say -- so the window gains a line at each end
and a count past each, taken in the sort pass it was already doing."
```

---

### Task 2: `stepLearned` watches both ends

**Files:**
- Modify: `src/core/touch.zig:997-1045` (the line-drawing and `away` block inside `stepLearned`)
- Test: `src/core/touch.zig` (test blocks at the end of the same file)

**Interfaces:**
- Consumes: `Spread.watchEdges(lo, hi)`, `spread.below`, `spread.above` from Task 1.
- Produces: `stepLearned` arms `hi_line` and `lo_line` independently and decides the readable branch on `@max(spread.above, spread.below)`. Task 3 adds a branch beside it and reuses `hi_line`, `lo_line` and the `past` flag defined here.

- [ ] **Step 1: Write the failing test**

Add at the end of `src/core/touch.zig`, after the existing `learned` tests:

```zig
test "one probe answers a hand at either rail in the same run" {
    // The rig the room actually has: a hand takes probe A to the top some
    // touches and the bottom others, and nothing says in advance which. A
    // model that picked the further of the two ends and watched only that
    // answered half the evening's hands and was silent through the rest.
    var detector: Detector = .init(learnedConfig());
    for (0..cluster_warmup) |poll| _ = detector.update(restingAt(12000, poll));

    for (0..steady_warmup) |poll| _ = detector.update(restingAt(25000, poll));
    try std.testing.expect(detector.on);

    for (0..cluster_warmup) |poll| _ = detector.update(restingAt(12000, poll));
    try std.testing.expect(!detector.on);

    // The other way, same detector, nothing reconfigured in between.
    for (0..steady_warmup) |poll| _ = detector.update(restingAt(300, poll));
    try std.testing.expect(detector.on);
}

test "the share is a maximum of the two ends and never a sum" {
    // A probe wandering across its whole range spends about a quarter of the
    // window past each line. Summed that is a half, which sits close enough to
    // the share that the separation the count exists for is gone. Held apart,
    // a wanderer scores a quarter and a hand scores nearly all of it.
    var cfg = learnedConfig();
    cfg.band_share = 0.45;

    var detector: Detector = .init(cfg);
    var prng: std.Random.DefaultPrng = .init(20260916);
    for (0..cluster_warmup) |_| _ = detector.update(wandering(prng.random()));
    for (0..steady_warmup * 2) |_| _ = detector.update(wandering(prng.random()));

    try std.testing.expect(@max(detector.spread.above, detector.spread.below) < 0.45);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test-core`

Expected: FAIL on `"one probe answers a hand at either rail in the same run"` — the final `expect(detector.on)` is false, because only the further end is armed. The maximum test may already pass; it is a pin against a later simplification, not a red test. Note which failed in the commit.

- [ ] **Step 3: Arm both ends**

In `src/core/touch.zig`, replace the block from `const rest = self.baseline.base;` (`touch.zig:1001`) down to and including the `const away = if (second_level and readable) blk: { ... }` expression's `break :blk self.spread.inside >= self.band_share;` line (`touch.zig:1025`), leaving the two `else` branches below it in place for now:

```zig
        // Which ends a hand takes this probe to, and the lines between there
        // and home. Both ends, because a hand on this rig goes to the top some
        // touches and the bottom others and nothing says which in advance --
        // and each line is drawn from its own end's reach rather than from the
        // larger of the two, or the nearer end's line would sit past the end
        // itself and a real touch there could never cross it.
        const rest = self.baseline.base;
        const up = clampedAbsDiff(self.baseline.high, rest);
        const down = clampedAbsDiff(self.baseline.low, rest);

        const hi_line: ?i16 = if (up >= self.still_move)
            saturatingAdd(rest, @divTrunc(up, 2))
        else
            null;
        const lo_line: ?i16 = if (down >= self.still_move)
            saturatingAdd(rest, -@divTrunc(down, 2))
        else
            null;

        // Whether the probe has been anywhere but home. Short of this nothing
        // has ever taken it anywhere, so there is no second level and no line.
        const second_level = hi_line != null or lo_line != null;
        // Whether the two ends are two levels rather than the ends of one
        // wander, which is what says a line may be drawn between them at all.
        const readable = self.baseline.dead <= max_dead;

        self.spread.watchEdges(lo_line, hi_line);

        const away = if (second_level and readable)
            // A touch has been seen, so the rig is known and the question is a
            // count: how much of the last window was past a line. Counted
            // rather than measured, because a hand that drops out one poll in
            // fifteen has a median dragged home and a range the height of the
            // dropout, and neither reads as the hand that is there.
            //
            // The maximum of the two and never their sum. A probe wandering
            // across its range is past each line about a quarter of the time,
            // and summing those says only that it left the middle -- which is
            // the one thing a wander and a hand have in common.
            @max(self.spread.above, self.spread.below) >= self.band_share
```

Stop there. The existing `else if (second_level)` line, its comment block, its bare `false`, and the final `else` branch all stay exactly where they are — do not retype them, or the branch will appear twice. Task 3 replaces the `false`.

- [ ] **Step 4: Delete the dead `reach` binding if the compiler says so**

`reach` is no longer read by this block. If `zig build test-core` reports `unused local variable 'reach'`, delete the `const reach = @max(up, down);` line. If Task 3's branch is expected to want it back, it does not — it uses `hi_line` and `lo_line`.

- [ ] **Step 5: Move the renamed assertion**

In `test "a hand under half the window is counted, not written off"`, change the one assertion:

```zig
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), detector.spread.above, 0.06);
```

It read `detector.spread.inside` before. Same quantity — that branch used `watch(lo, null)`, which counts the share at or above `lo`, and `above` is now the field that holds it. The test's claim is unchanged.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test-core`

Expected: PASS, all of it. In particular these four must still pass untouched, and a failure in any of them means the change leaked out of the `learned` model:

- `a hand on a probe that drops out half the time is still a hand`
- `a long hand does not become where the probe lives`
- `a probe that only wanders has no two levels to find`
- `a probe whose home moves is quiet on the way, not touched for the journey`

- [ ] **Step 7: Commit**

```bash
git add src/core/touch.zig
git commit -m "feat(core): a hand is answered at whichever rail it goes to

The model drew one line, at the further of the two levels the probe
visits, and watched that side alone. A rig whose hand goes up some
touches and down others lost every touch in the other direction and
said nothing about it.

Both ends are armed now, each line drawn from its own end's reach --
the larger end's half would sit past the nearer end entirely -- and the
share is the maximum of the two counts. Never their sum: a probe merely
wandering is past each line about a quarter of the time, and summing
those says only that it left the middle, which is what a wander and a
hand have in common."
```

---

### Task 3: A full gap asks a second question

**Files:**
- Modify: `src/core/touch.zig` — the `else if (second_level)` branch left in place by Task 2, the `Detector` struct's fields, `Detector.init`, `Config`, and the constants block near `default_still_move` (`touch.zig:418`)
- Test: `src/core/touch.zig`

**Interfaces:**
- Consumes: `hi_line`, `lo_line`, `second_level`, `readable`, `level`, `rest` from Task 2's block; `spread.range` (already on `Spread`).
- Produces: `pub const default_learned_park: i16 = 512;`, `Config.learned_park: i16`, `Detector.learned_park: i16`. Nothing after this task reads them.

- [ ] **Step 1: Write the failing tests**

Add at the end of `src/core/touch.zig`:

```zig
/// The rig the room has now: untouched the probe wanders across the middle of
/// its range from one poll to the next, and a hand parks it at a rail.
///
/// The inverse of `flipping`, where rest is flat and the hand is the flailing.
/// Both rigs are real and the model has to answer both.
fn wanderingWide(rng: std.Random) i16 {
    return rng.intRangeAtMost(i16, 6638, 21330);
}

/// A hand on that rig: the probe parked, with the dropout the journal shows
/// every eighth poll or so.
fn parkedAt(level: i16, poll: usize) i16 {
    return if (poll % 8 == 7) 1200 else restingAt(level, poll);
}

test "a hand that parks is answered on a probe that wanders at rest" {
    // The journal the room brought: 10545, 21330, 19894, 10571, 12020, 14746
    // with nobody on it, then 1, 1, 2, 1, 0, 0, 1200, 1 under a hand. The gap
    // between the probe's two ends is full -- the wander fills it -- so the
    // share means nothing here and the model used to answer by refusing. What
    // is left that still separates the two is that the hand parks and the
    // wander does not.
    var detector: Detector = .init(learnedConfig());
    var prng: std.Random.DefaultPrng = .init(20260916);
    for (0..cluster_warmup) |_| _ = detector.update(wanderingWide(prng.random()));
    try std.testing.expect(!detector.on);

    for (0..steady_warmup) |poll| _ = detector.update(parkedAt(1, poll));
    try std.testing.expect(detector.on);

    // And it lets go when the wander comes back.
    for (0..steady_warmup * 2) |_| _ = detector.update(wanderingWide(prng.random()));
    try std.testing.expect(!detector.on);
}

test "the same wandering probe answers a hand at the other rail" {
    var detector: Detector = .init(learnedConfig());
    var prng: std.Random.DefaultPrng = .init(20260916);
    for (0..cluster_warmup) |_| _ = detector.update(wanderingWide(prng.random()));

    for (0..steady_warmup) |poll| _ = detector.update(parkedAt(25900, poll));
    try std.testing.expect(detector.on);
}

test "a probe that has stopped reading is parked, and is not a hand" {
    // Nothing is stiller than a dead probe. The range gate says held and the
    // lines have to be what says nobody is there.
    var detector: Detector = .init(learnedConfig());
    for (0..cluster_warmup * 2) |_| _ = detector.update(0);
    try std.testing.expect(!detector.on);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test-core`

Expected: FAIL on `"a hand that parks is answered on a probe that wanders at rest"` at the first `expect(detector.on)`, and on `"the same wandering probe answers a hand at the other rail"`. Both fail because the `else if (second_level)` branch still returns `false`. `"a probe that has stopped reading"` should already pass.

- [ ] **Step 3: Add the constant**

In `src/core/touch.zig`, immediately after `default_still_move` (`touch.zig:418`):

```zig
/// How tightly the window must cluster before a probe that wanders at rest is
/// taken to be held, in counts.
///
/// Asked only where the gap between a probe's two levels is full -- where the
/// share has already been shown to mean nothing -- and never anywhere else. On
/// the flipping rig a held probe is not still for a single poll, and a
/// stillness gate asked of that rig rejects every real hand it has.
///
/// `still_range` at thirty-two cannot serve: it was measured for the steady
/// model on that other rig. This is measured against the two things it has to
/// tell apart on this one. A probe whose home has moved -- `wanderedHome`,
/// 11275 to 13353 -- spreads about twelve hundred between the percentiles and
/// is still wandering; a hand parks the probe and spreads about two. Five
/// hundred and twelve sits two and a half times under the first and two
/// hundred times over the second, which is as much room either side as any
/// threshold in this file has.
///
/// Drift wanders, a hand parks. That is the whole of it.
pub const default_learned_park: i16 = 512;
```

- [ ] **Step 4: Thread it through `Config` and `Detector`**

In `Config`, beside `still_move` (`touch.zig:508`):

```zig
    /// How tightly the window must cluster where the gap is full. `learned`
    /// only.
    learned_park: i16 = default_learned_park,
```

In the `Detector` struct, beside `still_move`:

```zig
    /// The spread at or under which a probe that wanders at rest counts as
    /// parked. Read only on the branch where the gap is full.
    learned_park: i16,
```

In `Detector.init`, beside `.still_move = cfg.still_move,`:

```zig
            .learned_park = cfg.learned_park,
```

`Config.forBc` needs no entry: it copies by value and there is no per-probe override for this.

- [ ] **Step 5: Replace the refusal with the question**

In `stepLearned`, replace the `else if (second_level)` branch — the comment block and its bare `false` (`touch.zig:1026-1039` before Task 2's edit) — with:

```zig
        else if (second_level) blk: {
            // The ends are a long way apart and the gap between them is full,
            // so this is one wander rather than two levels and the share
            // cannot answer: a wanderer is past a line about as much of every
            // window as a hand is. On `service-log4` that is 0.399 against
            // 0.400, which is not a strict answer but no answer.
            //
            // What is left is that the wander does not stop and a hand does.
            // So the question becomes whether the window has parked, and
            // parked somewhere the probe does not live -- both, because
            // nothing is stiller than a probe that has stopped reading
            // altogether.
            //
            // This is also what keeps a probe whose home has moved quiet. It
            // sits a long way from a rest that has not caught up and would
            // score a share of one, which is the ninety-six seconds of a clip
            // looping at an empty plant. But it is still wandering while it
            // does so, and wandering is exactly what this branch refuses.
            if (self.spread.range > self.learned_park) break :blk false;
            if (lo_line) |lo| if (level <= lo) break :blk true;
            if (hi_line) |hi| if (level >= hi) break :blk true;
            break :blk false;
        } else
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `zig build test-core`

Expected: PASS, all of it. The four guard-rail fixtures from Task 2 Step 6 must still pass — `a probe that only wanders has no two levels to find` and `a probe whose home moves is quiet on the way` are the two this task could plausibly break, and they hold because both fixtures keep wandering (ranges of about 3700 and 1250) and so never clear `learned_park`.

- [ ] **Step 7: Commit**

```bash
git add src/core/touch.zig
git commit -m "feat(core): a full gap asks a second question rather than ending it

A probe whose two levels have a full gap between them was written off:
the share cannot read such a rig, so the model said so and stayed
quiet. That is the right answer for a probe whose home has moved and
the wrong one for the rig the room now has, where the probe wanders
across the middle of its range untouched and a hand parks it at a rail.

So the refusal becomes a question. Where the gap is full, a hand is a
window that has parked, and parked somewhere the probe does not live --
the second half because nothing is stiller than a probe that has
stopped reading. A drifted probe is still wandering while it sits far
from home, so it clears neither test and stays quiet as before.

Drift wanders, a hand parks."
```

---

### Task 4: The status line says why

**Files:**
- Modify: `src/core/touch.zig` (set `self.z` at the end of `stepLearned`)
- Test: `src/core/touch.zig`

**Interfaces:**
- Consumes: `spread.above`, `spread.below` from Task 1.
- Produces: nothing later tasks read. `Detector.z` is already plumbed to `ports.Snapshot.z_a`/`z_bc` by `src/application/engine.zig` and printed by `src/adapters/stderr_status.zig`; no change is needed in either.

- [ ] **Step 1: Write the failing test**

Add at the end of `src/core/touch.zig`:

```zig
test "the learned model puts its own number on the status line" {
    // `z` is written on the deviation path only, so a room running this model
    // read `z0=0.0` on every poll of every log it ever took -- a column that
    // said nothing while the plant was silent for a reason the column could
    // have named.
    var detector: Detector = .init(learnedConfig());
    for (0..cluster_warmup) |poll| _ = detector.update(restingAt(0, poll));
    for (0..steady_warmup) |poll| _ = detector.update(restingAt(25000, poll));

    try std.testing.expect(detector.on);
    try std.testing.expect(detector.z > 0.9);

    for (0..steady_warmup * 2) |poll| _ = detector.update(restingAt(0, poll));
    try std.testing.expect(detector.z < 0.1);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-core`

Expected: FAIL at `expect(detector.z > 0.9)` — `z` is `0.0`, never written on this path.

- [ ] **Step 3: Write the share into `z`**

In `stepLearned`, immediately before `const held = away;`:

```zig
        // What the decision was made on, so a quiet plant can be read off one
        // line: `r0` where the model thinks home is, `l0` where the probe is
        // now, and this how much of the last window was past a line. The field
        // carried nought on this path for as long as the model has existed.
        self.z = @max(self.spread.above, self.spread.below);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test-core`

Expected: PASS, all of it.

- [ ] **Step 5: Say so where `z` is declared**

`src/adapters/stderr_status.zig` needs no change — it prints whatever `z` holds. The field's own doc comment in `src/core/touch.zig` currently reads:

```zig
    /// The last score, kept for the log and the status line.
    z: f32,
```

Replace it with:

```zig
    /// The last score, kept for the log and the status line.
    ///
    /// Two models, two numbers, one column. Under `deviation` it is the score:
    /// how many of the probe's own deviations from its own median the reading
    /// has moved. Under `learned` it is the share of the last window past the
    /// line. Both are the number that model's answer turns on, which is what
    /// the column is for. `steady` writes neither and leaves it at nought.
    z: f32,
```

- [ ] **Step 6: Commit**

```bash
git add src/core/touch.zig
git commit -m "feat(core): the learned model writes the number it decided on

The score column is written on the deviation path alone, so every log
a room took under this model read z0=0.0 on every poll. It carries the
share past the line now -- the number the answer actually turns on --
so a plant that is quiet can be read off one line instead of guessed at."
```

---

### Task 5: Measure `default_learned_park` against the rig

**Files:**
- Modify: `src/core/touch.zig` (the value of `default_learned_park`, only if the capture disagrees with 512)
- Create: `rig.csv` at the repo root, untracked

**Interfaces:**
- Consumes: everything above.
- Produces: either a confirmation that 512 stands, or a measured replacement.

This task needs the room. It cannot be completed from the tree.

- [ ] **Step 1: Take a capture**

On the Pi, with the service stopped:

```bash
mami_sound --capture=rig.csv --capture-seconds=900
```

Touch plant A several times during it, going to the top on some touches and the bottom on others, with stretches of nobody touching anything in between. Note roughly when each touch happened.

- [ ] **Step 2: Sweep it**

```bash
zig build replay -- rig.csv --model=learned --sweep
```

- [ ] **Step 3: Read the sweep against the touches you made**

Expected: the touches you noted appear as latches and the stretches between them do not. If a threshold column shows a wide band of values that all give the same answer, `default_learned_park` belongs in the middle of it.

- [ ] **Step 4: Confirm or replace the constant**

If 512 sits inside that band, change nothing and say so. If it does not, edit the value in `src/core/touch.zig` and rewrite the measured paragraph of its doc comment to describe this capture rather than the fixtures — the comment must always name what the number was measured against.

- [ ] **Step 5: Run the tests**

Run: `zig build test-core`

Expected: PASS. If changing the constant broke a fixture, the fixture and the capture disagree about the rig, and that is a finding to report rather than a test to loosen.

- [ ] **Step 6: Commit, if anything changed**

```bash
git add src/core/touch.zig
git commit -m "fix(core): the parked threshold is the rig's number now

Five hundred and twelve was read off the fixtures. This is what a
fifteen-minute capture of the rig actually gives."
```

---

## Not in this plan

- **Moving the production preset to `.learned`.** It stays `.deviation`. That is a decision for the room with the capture from Task 5 in hand, and it is one line when it comes.
- **A release threshold beside `learned_park`.** `settle`'s hold and drop counters already carry the hysteresis, and a second constant here would be one nobody measured.
- **Retiring `Baseline.dead`.** It keeps being computed and keeps choosing which question is asked. It is the one measured description of the older rigs in the tree.
