# Box Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge every box branch onto `main` and replace the single compiled preset with one file of measured numbers per box, so all five installations run the same detector.

**Architecture:** Two merges bring the branches together (`feat/clip-management-ui` fast-forwards box2 in; `box5` is a hand-resolved union). Then a new `src/application/boxes/` holds a `Preset` per box, `production_config.zig` becomes the resolver that layers `defaults → boxN → command line`, and `src/core/` is left knowing no box exists.

**Tech Stack:** Zig (the repo builds with `zig build`), `std.Io`-based composition in `src/main.zig`, hexagonal layering: `core/` (pure), `ports/`, `adapters/`, `application/`.

**Spec:** `docs/superpowers/specs/2026-09-14-box-presets-design.md`

## Global Constraints

- Everything under `src/core/` stays pure and box-unaware: it takes a `core.touch.Config` and a `core.noise.Shape` and imports nothing from `application/`. `zig build test-core` is the guard.
- Tests live beside the code they test, as `test "…" { … }` blocks in the same file. There is no `tests/` directory in this repo.
- Test names are sentences about behaviour in the room ("a plant left on trigger is given no tap window"), not about functions.
- Comments explain why a number is what it is, with the measurement behind it. This repo's existing comments are the model; match them.
- Full suite is `zig build test`. Core only is `zig build test-core`. Adapters only is `zig build test-adapters`.
- Commits follow Conventional Commits with a scope: `feat(boxes):`, `fix(core):`, `docs(plan):`, `chore:`.
- Every commit ends with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  ```
- Do not delete `box2` or `box5` branches. Task 3 deletes only `box1`, `touch-state-machine`, `feature/steady-band-touch`.

---

### Task 1: Land the clip-UI branch, which brings box2 with it

`feat/clip-management-ui` is 13 commits ahead of `main` and 0 behind, and its first three commits are box2's. A fast-forward therefore merges box2 without a second merge.

**Files:**
- Modify: none by hand. This task is a merge and a verification.

**Interfaces:**
- Consumes: nothing.
- Produces: a `main` that has `production_config.touchWith(model, still_range, still_release, still_window_ms, plant_band, plant_window, held, floors)` with `floors: Floors`, `core.touch.Config.counts`/`.counts_bc`, `drone.span = 25000`, `drone.touch_floor = 0.35`, and the `clips_ui/` Python service. Task 2 rewrites that `touchWith` signature.

- [ ] **Step 1: Confirm the fast-forward is really a fast-forward**

```bash
git checkout main
git rev-list --left-right --count main...feat/clip-management-ui
```

Expected: `0	13`. A left-hand number other than 0 means `main` moved since this plan was written — stop and re-read the spec's merge section before going on.

- [ ] **Step 2: Merge**

```bash
git merge --ff-only feat/clip-management-ui
```

Expected: `Fast-forward`, no conflicts.

- [ ] **Step 3: Run the full suite**

```bash
zig build test
```

Expected: PASS. If the Python clips-UI tests are wanted too they live under `clips_ui/` and run with `uv run pytest`, but they are not part of `zig build test` and are not a gate for this task.

- [ ] **Step 4: Confirm box2's numbers arrived**

```bash
grep -n "default_counts" src/application/production_config.zig
grep -n "span = 25000" src/application/production_config.zig
```

Expected: `default_counts: i16 = 3000`, `default_counts_bc: i16 = 10000`, and the 25000 span.

- [ ] **Step 5: No commit needed**

A fast-forward writes no merge commit. Move on.

---

### Task 2: Merge box5 as a union of two detector lineages

`box5`'s merge base is `135c754`, which has neither `band_share` nor the flicker guard, so box5 did not remove them — it never had them. Git will take `main`'s side of those automatically. The conflicts are where both lineages restructured the same thing.

**Files:**
- Modify: `src/application/production_config.zig` (conflict: `touchWith`'s signature)
- Modify: `src/cli.zig` (conflict: the flag block and `usage`)
- Modify: `src/core/clips.zig` (conflict: `Mode`'s doc comment)
- Modify: `src/core/touch.zig` (conflict: `Config` fields around `window_bc`)
- Modify: `src/main.zig` (conflict: the `touchWith` call and the `held` array)
- Modify: `src/application/voice.zig`, `src/replay.zig` (expected to auto-merge)
- Add: box5's media, auto-merged — `Insect/insect1.wav`…`insect5.wav` replacing `insect_1.wav`…`insect_5.wav`, `Voice Box 5/5Box_Voice_7.mp3`, `Bell Stems/compressed/bell9.mp3`

**Interfaces:**
- Consumes: Task 1's `main`.
- Produces: the merged `production_config.touchWith(overrides: Overrides, modes: [2]core.clips.Mode) core.touch.Config`, with `Overrides` as written in Step 4 below. `core.clips.Mode` gains `.tap`. Task 7 adds a `base: core.touch.Config` as this function's first parameter and updates every test written here; nothing else calls it.

- [ ] **Step 1: Start the merge and see the conflicts**

```bash
git merge box5
git status --short | grep '^UU\|^AA'
```

Expected: conflicts in `src/application/production_config.zig`, `src/cli.zig`, `src/core/clips.zig`, `src/core/touch.zig`, `src/main.zig`. Files not in that list auto-merged; leave them alone.

- [ ] **Step 2: Resolve `src/core/clips.zig` — keep both docs, keep `.tap`**

`main` wrote a doc for the two-variant `Mode`; box5 added a third variant and rewrote the doc. Keep box5's variant list and its wording, and keep `main`'s `released_frames`/`settled_frames` guard, which box5 never had and did not intend to remove.

```zig
/// How a plant answers a hand.
///
/// `trigger` starts a clip on the way in and lets it run its own length.
/// `hold` sounds for as long as the hand is there, and the next hold picks the
/// clip up where it stopped. `tap` is the third and was reachable only by being
/// plant B: it wants a hand that arrives and leaves again, and discards one
/// that rests. That is the right question for a probe whose excursions are
/// mostly drift, and the wrong one for a room, so it is asked for by name now
/// rather than carried in a preset.
pub const Mode = enum { trigger, hold, tap };
```

Then confirm the guard survived:

```bash
grep -n "released_frames\|settled_frames" src/core/clips.zig
```

Expected: both present, in `ClipSelector` and in `init`. If they are gone, the wrong side of a hunk was taken — restore from `git show main:src/core/clips.zig`.

- [ ] **Step 3: Resolve `src/core/touch.zig` — `main`'s `Window` union survives**

Keep every field `main` has (`touch_band_lo_bc`, `touch_band_hi_bc`, `band_share`, `window_bc: ?Window`). Box5's `window_bc_ms: ?f32` is the same idea expressed before the union existed; delete it and keep the union. Box5's rest-learning change is in `Detector.observe`/the baseline and is not in conflict — leave it as merged.

After resolving:

```bash
grep -n "window_bc_ms" src/core/touch.zig
```

Expected: no output. Any survivor is a leftover from box5's side.

```bash
grep -n "band_share\|pub const Window" src/core/touch.zig
```

Expected: both present.

- [ ] **Step 4: Resolve `src/application/production_config.zig` — box5's named struct, `main`'s fields**

Box2 added a `Floors` struct as an eighth positional parameter; box5 replaced all the positionals with a named `Overrides` struct and added a `modes` parameter. Take box5's shape and put `main`'s per-plant band and window back into it:

```zig
/// What the room asked for on the command line, or nothing where it did not.
///
/// Named rather than positional because four of these are `?i16` in a row: a
/// caller that handed the range where the floor goes would compile, run, and
/// be wrong in a way no test could see.
pub const Overrides = struct {
    model: ?core.touch.Model = null,
    still_range: ?i16 = null,
    still_release: ?i16 = null,
    still_window_ms: ?f32 = null,
    /// Where a held probe sits, per plant. The two probes do not sit at the
    /// same place: on this rig a hand puts one near six hundred and sixty and
    /// the other near twenty-five thousand.
    plant_band: [2]?[2]i16 = .{ null, null },
    /// The tap window each plant was given, where the room said. A plant whose
    /// mode is `.tap` is given `tap_window_ms` without being asked; this is how
    /// a room says a different length, or none.
    plant_window: [2]?core.touch.Window = .{ null, null },
    /// The move in counts a touch must clear, per probe. Zero is the room
    /// saying "no floor at all", which is a different thing from leaving the
    /// flag off: off keeps the measured number, zero asks the score alone.
    counts: ?i16 = null,
    counts_bc: ?i16 = null,
};

/// How long a tap may last and still be a tap, for whichever plant asks to be
/// one. Measured on the deviation rig, where it was plant B's whether anybody
/// wanted it or not.
pub const tap_window_ms: f32 = 1000.0;

/// The preset with the room's overrides applied. Anything left unset on the
/// command line keeps the number above, which is the one that was measured.
pub fn touchWith(
    overrides: Overrides,
    /// How each plant answers a hand. The detector is told the same thing the
    /// clips are: a hold wants a level, a tap wants a gesture, and a trigger
    /// wants the edge. Only a plant asked to be a tap is given a tap window --
    /// the window discards a hand that rests, which is the touch a room makes.
    modes: [2]core.clips.Mode,
) core.touch.Config {
    var cfg = touch;
    if (overrides.model) |chosen| cfg.model = chosen;

    cfg.hold = modes[0] == .hold;
    cfg.hold_bc = modes[1] == .hold;
    cfg.window_ms = if (modes[0] == .tap) tap_window_ms else null;
    cfg.window_bc = if (modes[1] == .tap) .{ .ms = tap_window_ms } else null;

    if (overrides.still_range) |counts| cfg.still_range = counts;
    if (overrides.still_release) |counts| cfg.still_release = counts;
    if (overrides.still_window_ms) |ms| cfg.still_window_ms = ms;
    if (overrides.plant_band[0]) |band| {
        cfg.touch_band_lo = band[0];
        cfg.touch_band_hi = band[1];
    }
    if (overrides.plant_band[1]) |band| {
        cfg.touch_band_lo_bc = band[0];
        cfg.touch_band_hi_bc = band[1];
    }
    // Plant A's window is a plain length, so `off` and "no window" are the same
    // thing there. Plant B's is not: `null` on BC means A's, and a room saying
    // `off` has to survive that.
    if (overrides.plant_window[0]) |chosen| cfg.window_ms = switch (chosen) {
        .off => null,
        .ms => |ms| ms,
    };
    if (overrides.plant_window[1]) |chosen| cfg.window_bc = chosen;

    // Zero is the room asking for no floor, which the detector spells `null`.
    if (overrides.counts) |floor| cfg.counts = if (floor == 0) null else floor;
    if (overrides.counts_bc) |floor| cfg.counts_bc = if (floor == 0) null else floor;
    return cfg;
}
```

Keep box2's `default_counts = 3000` and `default_counts_bc = 10000` and box2's `drone` shape with its comments: those are this rig's measurements, and Task 5 moves them into `box2.zig`. Box5's different numbers are recovered in Task 5 from `git show box5:src/application/production_config.zig`.

The file's `touch` constant loses `.window_bc` — it is now decided by mode:

```zig
pub const touch: core.touch.Config = .{
    .sample_rate = core.sample_rate,
    .poll_frames = core.sensor_frames,
    .model = .deviation,
    .hold_bc_ms = 20.0,
    .counts = default_counts,
    .counts_bc = default_counts_bc,
};
```

- [ ] **Step 5: Rewrite this file's tests to the merged signature**

Every existing test in `production_config.zig` calls `touchWith` positionally. Replace the call sites, keep the assertions, and keep box5's four added tests. The full set after resolution:

```zig
test "an override reaches the config and the rest of the preset stands" {
    const cfg = touchWith(.{ .model = .steady, .still_range = 64 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(core.touch.Model.steady, cfg.model);
    try std.testing.expectEqual(@as(i16, 64), cfg.still_range);
    // Untouched by the override, so still the measured number.
    try std.testing.expectEqual(touch.still_release, cfg.still_release);
}

test "no overrides on two triggers is the preset exactly" {
    try std.testing.expectEqual(touch, touchWith(.{}, .{ .trigger, .trigger }));
}

test "each plant is told to hold on its own" {
    const a_held = touchWith(.{}, .{ .hold, .trigger });
    try std.testing.expect(a_held.hold);
    try std.testing.expect(!a_held.hold_bc);

    const both = touchWith(.{}, .{ .hold, .hold });
    try std.testing.expect(both.hold);
    try std.testing.expect(both.hold_bc);

    const neither = touchWith(.{}, .{ .trigger, .trigger });
    try std.testing.expect(!neither.hold);
    try std.testing.expect(!neither.hold_bc);
}

test "a plant left on trigger is given no tap window" {
    // The fault as the room met it. The preset handed plant B a tap window
    // nobody asked for, and a tap window discards a hand that rests -- which is
    // every touch a room makes. Plant B crossed its threshold twenty-four times
    // in one log of a thousand polls and sounded on none of them.
    const machine: core.touch.Machine = .init(touchWith(.{}, .{ .trigger, .trigger }));
    try std.testing.expect(machine.a.window == null);
    try std.testing.expect(machine.bc.window == null);
}

test "a plant asked for a tap is given the window" {
    const machine: core.touch.Machine = .init(touchWith(.{}, .{ .tap, .tap }));
    try std.testing.expect(machine.a.window != null);
    try std.testing.expect(machine.bc.window != null);
}

test "a room may take a tap plant's window away without a rebuild" {
    // A plant told to tap on a rig where a hand stays put still has to be
    // reachable, and `off` is the word for it.
    const off = touchWith(.{ .plant_window = .{ null, .off } }, .{ .trigger, .tap });
    const machine: core.touch.Machine = .init(off);
    try std.testing.expect(machine.bc.window == null);

    const longer = touchWith(.{ .plant_window = .{ null, .{ .ms = 3000.0 } } }, .{ .trigger, .tap });
    try std.testing.expectEqual(@as(f32, 3000.0), longer.window_bc.?.ms);
}

test "a held plant drops its tap window, and only that plant's" {
    const b_held = touchWith(.{}, .{ .trigger, .hold });
    try std.testing.expect(!b_held.hold);
    try std.testing.expect(b_held.hold_bc);

    const machine: core.touch.Machine = .init(b_held);
    try std.testing.expect(machine.bc.window == null);
}

test "each plant's band reaches its own probe" {
    // The two probes do not sit at the same place, so one band cannot serve
    // both: a hand puts one near 660 and the other near 25000.
    const cfg = touchWith(.{ .plant_band = .{ .{ 600, 700 }, .{ 24000, 26000 } } }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, 600), cfg.touch_band_lo);
    try std.testing.expectEqual(@as(?i16, 24000), cfg.touch_band_lo_bc);
}

test "a room may set each probe's counts floor, or neither" {
    const preset = touchWith(.{}, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, default_counts), preset.counts);
    try std.testing.expectEqual(@as(?i16, default_counts_bc), preset.counts_bc);

    const only_a = touchWith(.{ .counts = 1500 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, 1500), only_a.counts);
    try std.testing.expectEqual(@as(?i16, default_counts_bc), only_a.counts_bc);
}

test "a floor of zero puts a probe back on the score alone" {
    // Zero is a setting and not a typo: it says "no floor", which `null` cannot
    // say because there it already means "keep the preset".
    const bare = touchWith(.{ .counts = 0, .counts_bc = 0 }, .{ .trigger, .trigger });
    try std.testing.expect(bare.counts == null);
    try std.testing.expect(bare.counts_bc == null);
}
```

Keep box2's `test "the span is the move the probe actually makes"` unchanged — it reads `drone` and `default_counts`, neither of which this task moves.

- [ ] **Step 6: Resolve `src/cli.zig` — keep every flag both sides have**

Box5's side deletes `--plant-a-band`, `--plant-b-band`, `--plant-a-window` and `--plant-b-window` and adds a single `--touch-band`. It deletes them because it forked before they were written, not because the room stopped wanting them. Keep `main`'s four flags, keep `main`'s `parseWindow` and `parseBand`, keep `main`'s `Options` fields `plant_band` and `plant_window`, and do **not** add `--touch-band`. From box5's side take only the `tap` line in the mode help:

```
    \\  tap      a hand that arrives and leaves again sets a clip going; one
    \\           left resting is drift or settling and starts nothing
```

`usage` otherwise stays as `main` has it.

- [ ] **Step 7: Resolve `src/main.zig` — build a modes array, pass it**

The composition loop currently fills a `held: [2]bool`. Replace it with a modes array so the same word reaches the clips and the detector. Above the loop:

```zig
    // What each plant does with a hand, in the one place both the voice and
    // the detector read it from. The drone is held by nature and takes no
    // mode, so it is recorded as a trigger and the detector is told nothing.
    var modes: [2]core.clips.Mode = .{ .trigger, .trigger };
```

Inside the loop, where `const mode = opts.plant_mode[plant] orelse .trigger;` stands, add `modes[plant] = mode;` immediately after it, and delete the `held[plant] = true;` line and the `var held` declaration. Keep the `loading:` line that announces a held plant. Then the engine call becomes:

```zig
    var app = engine.Engine.init(
        opts.plants,
        production_config.touchWith(.{
            .model = opts.model,
            .still_range = opts.still_range,
            .still_release = opts.still_release,
            .still_window_ms = opts.still_window_ms,
            .plant_band = opts.plant_band,
            .plant_window = opts.plant_window,
            .counts = opts.counts,
            .counts_bc = opts.counts_bc,
        }, modes),
        probe.source(),
        sink_port,
        status.port(),
        voices,
        if (capture) |*writer| writer.port() else null,
    );
```

- [ ] **Step 8: Build and run everything**

```bash
zig build test
```

Expected: PASS. A failure in `src/core/touch.zig`'s tests means a hunk from the wrong lineage survived; compare against `git show main:src/core/touch.zig` before changing any assertion. Assertions are the record of what the room measured — resolve the code to the test, not the test to the code.

- [ ] **Step 9: Confirm box5's media came across**

```bash
git status --short | head
ls Insect/
```

Expected: `insect1.wav`…`insect5.wav` and no `insect_1.wav`.

- [ ] **Step 10: Commit the merge**

```bash
git add -A
git commit -m "merge: box 5's tap and its rest-learning fix, onto the banded detector

box5 forked before band_share, the Window union and the flicker guard
were written, so its side of those hunks is absence rather than
disagreement and main's stands. What box5 has that the room needs comes
across: a third mode for a hand that arrives and leaves, a tap window
given by mode rather than by being plant B, an ungated tap render, and
rest learned from a probe at rest.

touchWith takes box5's named Overrides now, with main's per-plant band
and window inside it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Delete the branches that are already in `main`

**Files:**
- Modify: none. Branch bookkeeping.

**Interfaces:**
- Consumes: Task 2's `main`.
- Produces: nothing the code reads.

- [ ] **Step 1: Prove each one is contained before deleting it**

```bash
git rev-list --count main..box1
git rev-list --count main..touch-state-machine
```

Expected: `0` for both. A non-zero count means the branch holds work `main` does not — stop and report it rather than deleting.

- [ ] **Step 2: Check what `feature/steady-band-touch` would lose**

```bash
git log --oneline main..feature/steady-band-touch
```

Expected: 17 commits, all of them the hexagonal refactor that `main` already arrived at by another route (`src/ports/`, `src/adapters/`, `src/application/` all exist on `main`). The spec records this as superseded. Confirm `src/gpio.zig`, `src/sampler.zig` and `src/sensors.zig` are absent from `main` — their removal is the refactor that already landed:

```bash
git ls-tree --name-only main -- src/gpio.zig src/sampler.zig src/sensors.zig
```

Expected: no output.

- [ ] **Step 3: Delete, local and remote**

```bash
git branch -D box1 touch-state-machine feature/steady-band-touch
git push origin --delete box1 touch-state-machine feature/steady-band-touch
```

- [ ] **Step 4: No commit**

Branch deletion writes no commit. `box2` and `box5` stay until a Pi has run the merged `main`.

---

### Task 4: The `Preset` type and the shared defaults

**Files:**
- Create: `src/application/boxes/preset.zig`
- Create: `src/application/boxes/defaults.zig`
- Modify: `src/application/root.zig` (pull the new files into the application test root)

**Interfaces:**
- Consumes: `core.touch.Config`, `core.noise.Shape`, `core.source.Source`, `core.clips.Mode` from Task 2's `main`.
- Produces: `boxes.preset.Preset{ touch, drone, plants }`, `boxes.preset.Plant{ source, mode, seconds, retrigger }`, and `boxes.defaults.preset`. Tasks 5, 6, 7 and 8 all read these names.

- [ ] **Step 1: Write the failing test**

Put this in `src/application/boxes/preset.zig`, below the type it tests:

```zig
const std = @import("std");

test "a plant is a source and what it does with a hand" {
    const plant: Plant = .{ .source = .voicebox3, .mode = .trigger };
    try std.testing.expectEqual(core.source.Source.voicebox3, plant.source);
    try std.testing.expectEqual(core.clips.Mode.trigger, plant.mode);
    // Unset lengths leave the source's own answer standing, which is what
    // every box wants until one of them measures otherwise.
    try std.testing.expect(plant.seconds == null);
    try std.testing.expect(plant.retrigger == null);
}
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
zig build test 2>&1 | head -20
```

Expected: FAIL — `preset.zig` does not exist yet, or `Plant` is undefined.

- [ ] **Step 3: Write `src/application/boxes/preset.zig`**

```zig
//! What one box is: the numbers its rig was measured at, and what its two
//! plants play.
//!
//! Every box runs the same detector. What differs between the five
//! installations is an electrode, a length of wire and a room, and all three
//! reach the program as numbers -- so they are written down here as numbers
//! rather than carried on a branch, which is how two boxes came to have two
//! detectors.

const core = @import("../../core/root.zig");

/// One plant's part in the piece.
pub const Plant = struct {
    source: core.source.Source,
    /// What a hand means here. The drone is held by nature and takes no mode,
    /// so a drone plant is recorded as `.trigger` and the detector is told
    /// nothing about it.
    mode: core.clips.Mode,
    /// How long a touch plays, and how long before the next is honoured.
    /// `null` leaves the source's own answer standing.
    seconds: ?f32 = null,
    retrigger: ?f32 = null,
};

/// Everything about a box that is not the algorithm.
pub const Preset = struct {
    touch: core.touch.Config,
    drone: core.noise.Shape,
    /// Indexed as the plant selection is: A first, then B.
    plants: [2]Plant,
};
```

- [ ] **Step 4: Run the test**

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Write the failing test for the defaults**

In `src/application/boxes/defaults.zig`:

```zig
const std = @import("std");

test "the defaults are a rig nobody has measured, and say so in their numbers" {
    // A box that has not been to a room yet runs the detector's own defaults:
    // no band, no counts floor, and the deviation model, which is what the
    // rig with an electrode that rests somewhere wants.
    try std.testing.expectEqual(core.touch.Model.deviation, preset.touch.model);
    try std.testing.expect(preset.touch.touch_band_lo == null);
    try std.testing.expect(preset.touch.counts == null);
    // And the two plants the installation has always had.
    try std.testing.expectEqual(core.source.Source.drone, preset.plants[0].source);
    try std.testing.expectEqual(core.source.Source.voicebox3, preset.plants[1].source);
}
```

- [ ] **Step 6: Run it to make sure it fails**

```bash
zig build test 2>&1 | head -20
```

Expected: FAIL — `defaults.zig` does not exist.

- [ ] **Step 7: Write `src/application/boxes/defaults.zig`**

```zig
//! The baseline every box derives from: the detector's own numbers, the
//! drone's own shape, and the two plants the installation has always had.
//!
//! A box file states what its rig measured and inherits the rest from here, so
//! a change that belongs to every box is made once. A box that has never been
//! to a room is exactly this.

const core = @import("../../core/root.zig");
const preset_mod = @import("preset.zig");

pub const Preset = preset_mod.Preset;
pub const Plant = preset_mod.Plant;

pub const preset: Preset = .{
    .touch = .{
        .sample_rate = core.sample_rate,
        .poll_frames = core.sensor_frames,
        .model = .deviation,
        .hold_bc_ms = 20.0,
    },
    .drone = .{},
    .plants = .{
        .{ .source = .drone, .mode = .trigger },
        .{ .source = .voicebox3, .mode = .trigger },
    },
};

const std = @import("std");
```

- [ ] **Step 8: Register both files with the application test root**

In `src/application/root.zig`, add the imports and pull them into the `test` block:

```zig
const boxes_preset = @import("boxes/preset.zig");
const boxes_defaults = @import("boxes/defaults.zig");
```

and inside `test { … }`:

```zig
    _ = boxes_preset;
    _ = boxes_defaults;
```

- [ ] **Step 9: Run the suite**

```bash
zig build test
```

Expected: PASS, with both new tests running. If they do not appear, the test root registration in Step 8 is missing — an import alone does not pull a module's tests in.

- [ ] **Step 10: Commit**

```bash
git add src/application/boxes/preset.zig src/application/boxes/defaults.zig src/application/root.zig
git commit -m "feat(boxes): a box is a Preset, and an unmeasured box is the defaults

What differs between the five installations is an electrode, a length of
wire and a room, and all three reach the program as numbers. Written
down as numbers they can share a detector; carried on a branch they grew
two.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: One file per box, and the registry that finds them

Box2's numbers are on `main` already, in `production_config.zig`. Box5's are recoverable with `git show box5:src/application/production_config.zig` — read them there rather than inventing any.

**Files:**
- Create: `src/application/boxes/box1.zig`, `box2.zig`, `box3.zig`, `box4.zig`, `box5.zig`
- Create: `src/application/boxes/root.zig`
- Modify: `src/application/root.zig`

**Interfaces:**
- Consumes: `preset.Preset`, `defaults.preset` from Task 4.
- Produces: `boxes.Box` (an enum `box1`…`box5`), `boxes.presetFor(box: Box) Preset`, `boxes.fromHostname(name: []const u8) ?Box`, `boxes.default_box` — all read by Tasks 6 and 8.

- [ ] **Step 1: Recover box5's measured numbers**

```bash
git show box5:src/application/production_config.zig | grep -A3 "default_counts\|pub const drone"
```

Expected: `default_counts: i16 = 4000`, `default_counts_bc: i16 = 10000`, and box5's `drone` shape. Use whatever this prints, not what is written here, if the two disagree — the branch is the record.

- [ ] **Step 2: Write the failing test for the registry**

In `src/application/boxes/root.zig`:

```zig
const std = @import("std");

test "every box resolves to a preset, and none of them is a different detector" {
    // The whole point of the file per box: five presets, one algorithm. What a
    // box may change is a number the detector reads, never which question it
    // asks -- and a box that wants the other model says so here, in one line,
    // where the next person can see it next to the other four.
    inline for (@typeInfo(Box).@"enum".fields) |field| {
        const box: Box = @enumFromInt(field.value);
        const chosen = presetFor(box);
        try std.testing.expectEqual(core.sample_rate, chosen.touch.sample_rate);
        try std.testing.expectEqual(core.sensor_frames, chosen.touch.poll_frames);
    }
}

test "a Pi is recognised by its hostname, and anything else is not" {
    try std.testing.expectEqual(Box.box3, fromHostname("box3").?);
    // The Pis answer to more than their bare name.
    try std.testing.expectEqual(Box.box5, fromHostname("box5.local").?);
    try std.testing.expectEqual(Box.box1, fromHostname("box1-pi").?);
    // A machine that is not one of the five gets the defaults rather than a
    // guess: a bench running box2's floors while claiming to be box2 is worse
    // than one that says it is nobody.
    try std.testing.expect(fromHostname("raspberrypi") == null);
    try std.testing.expect(fromHostname("") == null);
    try std.testing.expect(fromHostname("boxing-club") == null);
}
```

- [ ] **Step 3: Run it to make sure it fails**

```bash
zig build test 2>&1 | head -20
```

Expected: FAIL — `root.zig` in `boxes/` does not exist.

- [ ] **Step 4: Write the five box files**

`src/application/boxes/box2.zig` — the numbers move here verbatim from `production_config.zig`, comments and all:

```zig
//! Box 2. Probe A behaves as a switch rather than as a sensor.

const core = @import("../../core/root.zig");
const defaults = @import("defaults.zig");

/// How big a move a touch must be, in the counts the probe actually reads.
///
/// The score alone cannot answer this. It divides a move by how much the probe
/// normally wanders, and on this rig that denominator means very little: probe
/// A reads nought or one with nobody on it, so its median absolute deviation
/// sits on the floor of twenty-five and the smallest wobble scores deviations
/// the threshold cannot tell from a hand.
///
/// Plant A's floor is deliberately far under its excursion rather than near
/// half of it. The probe there is nought or one untouched and about twenty-five
/// thousand under a hand, and the room's complaint was that a light touch did
/// nothing and only a tight grip sounded. A floor at three thousand is twelve
/// per cent of a full touch and still forty times the worst wander the journal
/// shows at rest.
///
/// Plant B moves about twenty-four thousand and keeps a floor near half of it:
/// a wrong latch there starts a recording, which is the fault a room hears.
const counts: i16 = 3000;
const counts_bc: i16 = 10000;

pub const preset: defaults.Preset = blk: {
    var p = defaults.preset;
    p.touch.counts = counts;
    p.touch.counts_bc = counts_bc;
    // `span` is the deviation that reaches the top of the pitch range, and it
    // has to be the move the probe actually makes. Three thousand was measured
    // on a rig whose hand moved the probe about that far; this one moves it
    // twenty-five thousand, so every touch saturated and arrived at freq_max
    // whatever the grip -- the same throttle being opened every time.
    //
    // The floor is what keeps the quiet end audible: a move just over the
    // counts floor is a twelfth of the span, which without a floor is 44 Hz
    // against an idle of 30 and cannot be heard as an answer.
    p.drone.span = 25000;
    p.drone.touch_floor = 0.35;
    break :blk p;
};
```

`src/application/boxes/box5.zig` — box5's own floors, and the plants its media says it plays:

```zig
//! Box 5. Probe B reads the supply rail and drops toward ground about one poll
//! in fifteen, so its floor is read in counts rather than in deviations.

const core = @import("../../core/root.zig");
const defaults = @import("defaults.zig");

/// Measured over fourteen seconds of the journal: probe B's rest reached 4.4
/// deviations against a threshold of six, which over an evening crosses. The
/// floors are in units the room can read off the status line and the rig
/// cannot inflate -- plant A's touch takes its probe from about 16300 past
/// 25000, plant B's from about 24000 down to ground, and each floor sits near
/// half of that.
const counts: i16 = 4000;
const counts_bc: i16 = 10000;

pub const preset: defaults.Preset = blk: {
    var p = defaults.preset;
    p.touch.counts = counts;
    p.touch.counts_bc = counts_bc;
    p.plants[1] = .{ .source = .voicebox5, .mode = .trigger };
    break :blk p;
};
```

`src/application/boxes/box1.zig`, `box3.zig`, `box4.zig` — each identical but for the number in its name and its first line:

```zig
//! Box 1. Not measured in the room yet: this is the defaults, and the floors
//! and the drone's span are what a visit with `--capture` is for. Until then a
//! number here would be a guess dressed as a measurement.

const defaults = @import("defaults.zig");

pub const preset: defaults.Preset = defaults.preset;
```

- [ ] **Step 5: Write `src/application/boxes/root.zig`**

Above the tests from Step 2:

```zig
//! Which box this is, and what that box was measured at.
//!
//! Five files, one detector. A box may set a number the detector reads; it may
//! not ask the detector a different question. That is the whole rule, and the
//! reason this directory exists.

const core = @import("../../core/root.zig");
const defaults = @import("defaults.zig");

pub const Preset = defaults.Preset;
pub const Plant = defaults.Plant;

pub const Box = enum { box1, box2, box3, box4, box5 };

/// What a machine that is none of the five runs: the defaults, unmeasured and
/// saying so.
pub const default_preset: Preset = defaults.preset;

pub fn presetFor(box: Box) Preset {
    return switch (box) {
        .box1 => @import("box1.zig").preset,
        .box2 => @import("box2.zig").preset,
        .box3 => @import("box3.zig").preset,
        .box4 => @import("box4.zig").preset,
        .box5 => @import("box5.zig").preset,
    };
}

/// The box a hostname names, or none.
///
/// A prefix rather than an exact match, because the Pis answer to `box3`,
/// `box3.local` and `box3-pi` depending on who is asking. Anything that is not
/// one of the five is none: a bench silently running box2's floors is worse
/// than one that says it is nobody.
pub fn fromHostname(name: []const u8) ?Box {
    inline for (@typeInfo(Box).@"enum".fields) |field| {
        if (std.mem.startsWith(u8, name, field.name)) {
            // `boxing-club` starts with `box1`? No -- but `box1x` does start
            // with `box1`, so what follows the name has to be a separator
            // rather than more name.
            const rest = name[field.name.len..];
            if (rest.len == 0 or rest[0] == '.' or rest[0] == '-') {
                return @enumFromInt(field.value);
            }
        }
    }
    return null;
}
```

- [ ] **Step 6: Register with the application test root**

In `src/application/root.zig` add:

```zig
const boxes = @import("boxes/root.zig");
```

and inside `test { … }`:

```zig
    _ = boxes;
```

- [ ] **Step 7: Run the suite**

```bash
zig build test
```

Expected: PASS, including both tests from Step 2.

- [ ] **Step 8: Write the invariant test that stops a preset being nonsense**

Append to `src/application/boxes/root.zig`:

```zig
test "a box's drone span covers the move its probe actually makes" {
    // A span under the excursion saturates on every touch and pins the pitch
    // at the top of the range, which is the one thing the drone must not do:
    // the room hears the same throttle opened every time.
    inline for (@typeInfo(Box).@"enum".fields) |field| {
        const chosen = presetFor(@as(Box, @enumFromInt(field.value)));
        if (chosen.touch.counts) |floor| {
            try std.testing.expect(chosen.drone.span >= floor);
            // And the quiet end has to be audible, or a light touch is a latch
            // nobody can hear.
            const just_over = core.noise.freqFromDeviation(
                floor,
                chosen.drone.span,
                chosen.drone.touch_floor,
            );
            try std.testing.expect(just_over > 3.0 * core.noise.freq_min);
        }
    }
}

test "no box asks the detector a different question than the others" {
    // A box may set a number. A box that changed the model would be a second
    // algorithm arriving by the door this directory was built to close, so it
    // is refused here rather than discovered in a room.
    inline for (@typeInfo(Box).@"enum".fields) |field| {
        const chosen = presetFor(@as(Box, @enumFromInt(field.value)));
        try std.testing.expectEqual(default_preset.touch.model, chosen.touch.model);
    }
}
```

- [ ] **Step 9: Run it**

```bash
zig build test
zig build test-core
```

Expected: both PASS. `test-core` is the guard that nothing in this task leaked a box into `src/core/`: it compiles `src/core/root.zig` alone, so an import reaching back into `application/` fails there and nowhere else.

If `freqFromDeviation` has a different arity than the box2 test in `production_config.zig` uses, match that call site — it is the one already compiling on `main`.

- [ ] **Step 10: Commit**

```bash
git add src/application/boxes src/application/root.zig
git commit -m "feat(boxes): five files of measured numbers, and the rule between them

box2's floors and drone span come out of production_config, box5's out
of its branch. box1, box3 and box4 ship as the defaults and say in a
comment that nobody has measured them, because a number there would be a
guess dressed as a measurement.

The two tests are the rule: a box may set a number the detector reads,
and may not ask it a different question.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `--box` on the command line, and the hostname behind it

**Files:**
- Modify: `src/cli.zig` (the `Options` field, the parse arm, `Error`, `usage`)

**Interfaces:**
- Consumes: `boxes.Box`, `boxes.fromHostname` from Task 5.
- Produces: `cli.Options.box: ?boxes.Box` and `cli.Error.InvalidBox`. Task 7 reads `opts.box`.

- [ ] **Step 1: Write the failing test**

Append to `src/cli.zig`:

```zig
test "a room names its box on the command line" {
    const opts = try parse(&.{"--box=3"});
    try std.testing.expectEqual(boxes.Box.box3, opts.box.?);
}

test "no --box is the room not having said, which is not the same as box 1" {
    const opts = try parse(&.{});
    try std.testing.expect(opts.box == null);
}

test "a box that does not exist is refused rather than rounded" {
    // Six boxes would be a typo and zero would be a misreading of the range.
    // Either one silently answered with box1's floors is a rig running numbers
    // measured somewhere else, which is the fault this whole directory exists
    // to stop.
    try std.testing.expectError(Error.InvalidBox, parse(&.{"--box=6"}));
    try std.testing.expectError(Error.InvalidBox, parse(&.{"--box=0"}));
    try std.testing.expectError(Error.InvalidBox, parse(&.{"--box="}));
    try std.testing.expectError(Error.InvalidBox, parse(&.{"--box=two"}));
}
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
zig build test 2>&1 | head -20
```

Expected: FAIL — `box` is not a field of `Options`.

- [ ] **Step 3: Add the field, the error and the parse arm**

At the top of `src/cli.zig`, beside the other imports:

```zig
const boxes = @import("application/boxes/root.zig");
```

In `Error`, add `InvalidBox,`.

In `Options`:

```zig
    /// Which box's measured numbers to run, where the room said so. `null` is
    /// the room not having said, and the hostname is asked instead.
    ///
    /// On the command line rather than compiled in because one binary serves
    /// all five Pis: a bench can then run box 5's floors against box 5's
    /// capture without a cross-build, and a deploy is the same everywhere.
    box: ?boxes.Box = null,
```

In `parse`, beside the other `--` arms:

```zig
        } else if (std.mem.startsWith(u8, arg, "--box=")) {
            opts.box = parseBox(arg["--box=".len..]) orelse return Error.InvalidBox;
```

And the parser, beside `parseMode`:

```zig
/// A box by its number: `--box=3` rather than `--box=box3`, because the number
/// is what is written on the lid.
fn parseBox(text: []const u8) ?boxes.Box {
    if (text.len != 1) return null;
    const which = std.fmt.parseInt(u8, text, 10) catch return null;
    if (which < 1 or which > 5) return null;
    return @enumFromInt(which - 1);
}
```

- [ ] **Step 4: Run the test**

```bash
zig build test
```

Expected: PASS. `@enumFromInt(which - 1)` relies on `Box`'s fields being declared `box1`…`box5` in order; Task 5's enum is.

- [ ] **Step 5: Add the flag to `usage`**

In the synopsis block, on its own line after the `[PLANTS] [--device=NAME]` line:

```
    \\                  [--box=N]
```

And in the prose, after the `--device` paragraph:

```
    \\--box is which of the five installations this is, 1 to 5. It picks the
    \\numbers that box's rig was measured at: the counts floor each probe needs,
    \\how far the drone's pitch spends its range, and what each plant plays.
    \\Left off, the hostname is read -- box3, box3.local and box3-pi are all
    \\box 3 -- and a machine that is none of the five runs the unmeasured
    \\defaults and says so on the loading line. Every other flag still wins over
    \\whatever the box says.
```

- [ ] **Step 6: Run the suite**

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/cli.zig
git commit -m "feat(cli): a room may say which box this is

One binary for five Pis, so which box a run is has to be answerable at
run time. Six and zero are refused rather than rounded: a rig silently
running numbers measured somewhere else is the fault the presets exist
to stop.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: The resolver — defaults, then the box, then the room

**Files:**
- Modify: `src/application/production_config.zig` (base the preset on a box; add `resolve`)
- Modify: `src/application/root.zig` if any import needs it

**Interfaces:**
- Consumes: `boxes.Box`, `boxes.presetFor`, `boxes.default_preset` (Task 5); `Overrides` (Task 2); `cli.Options.box` (Task 6).
- Produces: `production_config.Resolved{ touch, drone, plants }` and `production_config.resolve(box: ?boxes.Box, hostname: []const u8, overrides: Overrides, modes: [2]core.clips.Mode) Resolved`, plus `production_config.chosenBox(box: ?boxes.Box, hostname: []const u8) ?boxes.Box`. Task 8 calls both.

- [ ] **Step 1: Write the failing test**

Append to `src/application/production_config.zig`:

```zig
test "the flag wins over the hostname, and the hostname over nothing" {
    try std.testing.expectEqual(boxes.Box.box5, chosenBox(.box5, "box2").?);
    try std.testing.expectEqual(boxes.Box.box2, chosenBox(null, "box2.local").?);
    try std.testing.expect(chosenBox(null, "somebodys-laptop") == null);
}

test "a box's numbers reach the config, and the room's beat the box's" {
    // Three layers, and each one only overrides what it actually says. Box 5
    // was measured at a floor of four thousand; a room that has watched the
    // rig this evening and says otherwise is the one that has just looked.
    const box_only = resolve(.box5, "", .{}, .{ .trigger, .trigger });
    try std.testing.expectEqual(
        boxes.presetFor(.box5).touch.counts,
        box_only.touch.counts,
    );

    const room_said = resolve(.box5, "", .{ .counts = 1500 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, 1500), room_said.touch.counts);
}

test "a machine that is no box runs the unmeasured defaults" {
    const nobody = resolve(null, "somebodys-laptop", .{}, .{ .trigger, .trigger });
    try std.testing.expectEqual(boxes.default_preset.drone.span, nobody.drone.span);
    try std.testing.expect(nobody.touch.counts == null);
}

test "what each plant plays comes from the box, and a mode still reaches the detector" {
    // Box 5 plays its own voice box. And the mode a run ends up with is the one
    // the detector is told about, or a held plant is one the clips think is
    // held and the detector does not.
    const five = resolve(.box5, "", .{}, .{ .trigger, .hold });
    try std.testing.expectEqual(core.source.Source.voicebox5, five.plants[1].source);
    try std.testing.expect(five.touch.hold_bc);
    try std.testing.expect(!five.touch.hold);
}
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
zig build test 2>&1 | head -20
```

Expected: FAIL — `chosenBox` and `resolve` are undefined.

- [ ] **Step 3: Base the file on a box instead of on a constant**

At the top of `src/application/production_config.zig`, add:

```zig
const boxes = @import("boxes/root.zig");
```

Change `touchWith` to take the base it is layering onto, so the existing tests keep their meaning and `resolve` has something to call:

```zig
/// The preset with the room's overrides applied. Anything left unset on the
/// command line keeps the number the box was measured at.
pub fn touchWith(
    base: core.touch.Config,
    overrides: Overrides,
    modes: [2]core.clips.Mode,
) core.touch.Config {
    var cfg = base;
    // ... body unchanged from Task 2 ...
}
```

Every test in this file written in Task 2 now passes `touch` as the first argument: `touchWith(touch, .{}, .{ .trigger, .trigger })`. Keep `pub const touch` as the file's own baseline so those tests keep testing the layering rather than a box.

- [ ] **Step 4: Write the resolver**

```zig
/// Everything a run needs that is not the algorithm: the detector's numbers,
/// the drone's shape, and what each plant plays.
pub const Resolved = struct {
    touch: core.touch.Config,
    drone: core.noise.Shape,
    plants: [2]boxes.Plant,
    /// Which box this turned out to be, for the loading line. `null` is a
    /// machine that is none of the five.
    box: ?boxes.Box,
};

/// Which box a run is: what the room said, or failing that what the machine is
/// called, or failing that nobody.
pub fn chosenBox(asked: ?boxes.Box, hostname: []const u8) ?boxes.Box {
    return asked orelse boxes.fromHostname(hostname);
}

/// The three layers, in the only order that makes sense: the defaults are what
/// every box shares, the box file is what its rig was measured at, and the
/// command line is what somebody standing in the room has just seen.
pub fn resolve(
    asked: ?boxes.Box,
    hostname: []const u8,
    overrides: Overrides,
    modes: [2]core.clips.Mode,
) Resolved {
    const box = chosenBox(asked, hostname);
    const preset = if (box) |which| boxes.presetFor(which) else boxes.default_preset;
    return .{
        .touch = touchWith(preset.touch, overrides, modes),
        .drone = preset.drone,
        .plants = preset.plants,
        .box = box,
    };
}
```

- [ ] **Step 5: Run the tests**

```bash
zig build test
```

Expected: PASS, including every test Task 2 wrote (now calling `touchWith(touch, …)`).

- [ ] **Step 6: Commit**

```bash
git add src/application/production_config.zig
git commit -m "feat(boxes): defaults, then the box, then the room

Each layer overrides only what it actually says. The command line wins
because the person holding it has just watched the rig; the box file
wins over the defaults because somebody measured that rig once.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Wire the composition to the resolver, and say on the loading line which box ran

**Files:**
- Modify: `src/main.zig` (read the hostname, resolve once, take plant sources and modes and the drone shape from the resolution)

**Interfaces:**
- Consumes: `production_config.resolve`, `production_config.Resolved` (Task 7); `cli.Options.box` (Task 6).
- Produces: nothing further tasks read. This is the composition root.

- [ ] **Step 1: Read the hostname**

Add to `src/main.zig`, beside `shuffleSeed`:

```zig
/// What this machine calls itself, or nothing.
///
/// Nothing rather than an error: a machine that cannot say its own name is a
/// bench or a container, and both should run the unmeasured defaults and be
/// told so on the loading line rather than refusing to start.
fn hostname(buf: *[std.posix.HOST_NAME_MAX]u8) []const u8 {
    return std.posix.gethostname(buf) catch "";
}
```

- [ ] **Step 2: Resolve once, before the plant loop**

In `runComposition`, above the `for (opts.plant_sources, 0..)` loop:

```zig
    // Which box this is decides what the plants play and what the detector is
    // given, so it is settled once, before anything is loaded off disk.
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const box = production_config.chosenBox(opts.box, hostname(&host_buf));
    const preset = if (box) |which| boxes.presetFor(which) else boxes.default_preset;
    if (box) |which| {
        std.debug.print("loading: {t}\n", .{which});
    } else {
        std.debug.print(
            "loading: no box named, and this machine is none of the five: " ++
                "running the unmeasured defaults\n",
            .{},
        );
    }
```

with `const boxes = @import("application/boxes/root.zig");` added to the imports at the top of the file. The `var modes: [2]core.clips.Mode = .{ .trigger, .trigger };` declaration is already there from Task 2 Step 7 — leave it where it is, immediately above this block.

- [ ] **Step 3: Let the box choose the sources, and the room override them**

`cli.Options.plant_sources` currently defaults to `.{ .drone, .voicebox3 }`, which cannot be told apart from a room asking for exactly that. Change the field in `src/cli.zig` to an optional so the box can be heard:

```zig
    /// What each plant plays, indexed as the selection is. `null` is the room
    /// not having said, which leaves the box's own answer standing -- and is
    /// not the same as a room asking for the drone, which is what a plain
    /// default could not distinguish.
    plant_sources: [2]?source.Source = .{ null, null },
```

Update the two parse arms to assign `opts.plant_sources[0] = …` as before (they already assign a `Source`, which coerces), the `--plant-a` shorthand arm to `opts.plant_sources[0] = .daybird;`, and the drone check at the end of `parse` to skip a `null`:

```zig
    for (opts.plant_sources, 0..) |chosen, plant| {
        const named = chosen orelse continue;
        if (!named.isDrone()) continue;
        if (opts.plant_seconds[plant] != null or opts.plant_retrigger[plant] != null) {
            return Error.SecondsOnDrone;
        }
        if (opts.plant_mode[plant] != null) return Error.ModeOnDrone;
    }
```

In `src/main.zig`'s plant loop, the source and the mode now come from the box unless the room said. The loop header changes from `for (opts.plant_sources, 0..) |chosen, plant|` to `for (0..2) |plant|`, and the whole body becomes:

```zig
    for (0..2) |plant| {
        const name: []const u8 = if (plant == 0) "A" else "B";
        if (!opts.plants[plant]) {
            std.debug.print("loading: plant {s} skipped\n", .{name});
            continue;
        }
        // The room's answer, or this box's. A room that says nothing is not a
        // room asking for the drone, which is the distinction a plain default
        // could not make and the reason the field is optional.
        const chosen = opts.plant_sources[plant] orelse preset.plants[plant].source;
        if (chosen.isDrone()) {
            std.debug.print("loading: plant {s} is the drone\n", .{name});
            continue;
        }

        std.debug.print("loading: plant {s} clips ({t})...\n", .{ name, chosen });
        pools[plant] = clip_loader.loadPool(gpa, io, chosen) catch |err| {
            // Naming the folders is the whole of the fix: the source is chosen
            // by name, so the one thing the message has to say is which folder
            // on disk was not there.
            std.debug.print("no plant {s} clips: {s}\n", .{ name, @errorName(err) });
            for (clip_loader.directoriesFor(chosen)) |directory| {
                std.debug.print("  looked in ./{s}/\n", .{directory});
            }
            std.process.exit(1);
        };
        std.debug.print(
            "loading: plant {s} clips ready ({d})\n",
            .{ name, pools[plant].paths.len },
        );

        const mode = opts.plant_mode[plant] orelse preset.plants[plant].mode;
        modes[plant] = mode;
        const seconds = opts.plant_seconds[plant] orelse preset.plants[plant].seconds;
        const limit: core.clips.Limit = .forSource(chosen, seconds, mode, core.sample_rate);
        if (limit.total == core.clips.Limit.unlimited.total) {
            std.debug.print("loading: plant {s} plays each clip to its end\n", .{name});
        } else {
            const played =
                @as(f32, @floatFromInt(limit.total)) / @as(f32, @floatFromInt(core.sample_rate));
            std.debug.print(
                "loading: each touch on plant {s} plays {d:.1}s\n",
                .{ name, played },
            );
        }

        streams[plant] = try clip_stream.Adapter.init(io, gpa, pools[plant].paths, limit);
        stream_live[plant] = true;

        // Before `start`, and never fatal. The heads are what make a touch
        // audible straight away instead of one ffmpeg startup later; without
        // them the streamer still plays every clip, just late.
        std.debug.print("loading: plant {s} clip heads...\n", .{name});
        if (streams[plant].primeHeads()) |_| {
            const megabytes: f32 =
                @as(f32, @floatFromInt(streams[plant].headBytes())) / 1024.0 / 1024.0;
            std.debug.print(
                "loading: plant {s} clip heads ready ({d:.1} MB)\n",
                .{ name, megabytes },
            );
        } else |err| {
            std.debug.print(
                "plant {s} clip heads unavailable ({s}); clips start after ffmpeg does\n",
                .{ name, @errorName(err) },
            );
        }
        try streams[plant].start();

        // Three answers in order: the room's, the box's, the source's own.
        const retrigger = opts.plant_retrigger[plant] orelse
            preset.plants[plant].retrigger orelse
            chosen.defaultRetriggerSeconds();
        if (mode == .hold) {
            std.debug.print("loading: plant {s} sounds while it is held\n", .{name});
        }
        voices[plant] = .{
            .clips = .{
                .stream = streams[plant].port(),
                .selector = .init(
                    pools[plant].paths.len,
                    retrigger,
                    core.sample_rate,
                    shuffle.random(),
                ),
                .mode = mode,
                // Shut, so the first hold is heard opening rather than arriving.
                .gate = if (mode == .hold) 0.0 else 1.0,
            },
        };
    }
```

`held` went in Task 2 Step 7; `grep -n "held" src/main.zig` should find only the `sounds while it is held` message. The detector learns a plant is held through `modes`, which Task 7's `resolve` reads.

- [ ] **Step 4: Give the engine the resolved config, and the drone its box's shape**

```zig
    const resolved = production_config.resolve(opts.box, hostname(&host_buf), .{
        .model = opts.model,
        .still_range = opts.still_range,
        .still_release = opts.still_release,
        .still_window_ms = opts.still_window_ms,
        .plant_band = opts.plant_band,
        .plant_window = opts.plant_window,
        .counts = opts.counts,
        .counts_bc = opts.counts_bc,
    }, modes);

    var app = engine.Engine.init(
        opts.plants,
        resolved.touch,
        probe.source(),
        sink_port,
        status.port(),
        voices,
        if (capture) |*writer| writer.port() else null,
    );
```

`droneVoice` takes the shape rather than reading the module constant, because the shape is now the box's:

```zig
/// The generated voice, with this box's measured shape.
fn droneVoice(shape: core.noise.Shape) voice_mod.Voice {
    return .{ .drone = .init(core.sample_rate, production_config.seed, shape) };
}
```

and its two call sites become `droneVoice(preset.drone)`.

- [ ] **Step 5: Build**

```bash
zig build
```

Expected: no errors. A "no field named plant_sources" style error means a call site of the optional field in Step 3 was missed — `grep -rn "plant_sources" src/` finds them all.

- [ ] **Step 6: Run the suite**

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Check the loading line by running against the test probe**

```bash
zig build run -- --box=5 --test-random-probe 2>&1 | head -8
```

Expected: an early line reading `loading: box5`, then plant B loading `voicebox5` rather than `voicebox3`. Ctrl-C to stop. On a machine with no audio device this will fail at the sink — the loading lines before that are what this step checks.

```bash
zig build run -- --test-random-probe 2>&1 | head -4
```

Expected: the "none of the five" line, unless the machine is called `boxN`.

- [ ] **Step 8: Commit**

```bash
git add src/main.zig src/cli.zig
git commit -m "feat(boxes): the run says which box it is, and plays what that box plays

The source a plant plays was a default nobody could override upward: a
room asking for the drone and a room saying nothing looked identical, so
a box could not choose. It is an optional now, and the box is heard when
the room is silent.

The loading line names the box, or says the machine is none of the five
and is running numbers nobody measured -- which is the only way a wrong
preset is visible before it is audible.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Leave the documentation true

**Files:**
- Modify: `docs/superpowers/specs/2026-09-14-box-presets-design.md` (two details the implementation settled differently)
- Modify: `README.md` if one exists at the repo root; otherwise skip that half of Step 2

**Interfaces:**
- Consumes: everything above.
- Produces: nothing the code reads.

- [ ] **Step 1: Correct the spec's two drifted details**

The spec sketched `defaults.with(.{ … })`. Zig has no struct-update syntax, and a partial-struct mechanism would be a second thing to maintain for no gain, so box files use a comptime block over a copy of `defaults.preset`. Replace the `box2.zig` example in the spec's "The preset" section with the real one from `src/application/boxes/box2.zig`.

The spec's same example gave the drone plant `.mode = .hold`. The drone is held by nature and takes no mode — `cli.parse` refuses `--plant-a-mode` on it — and recording `.hold` there would reach `touchWith` and set `cfg.hold`, which is a different rig. Correct it to `.trigger` and add the sentence: "A drone plant records `.trigger`; the drone's gate is its own and the detector is told nothing."

- [ ] **Step 2: Say how a box is chosen, where somebody deploying will look**

If `README.md` exists, add to it; otherwise put this in the spec under "Selection":

```markdown
Each Pi runs the same binary. Which box it is comes from `--box=N`, or from
the hostname when the flag is absent (`box3`, `box3.local` and `box3-pi` are
all box 3). A machine that is none of the five runs the unmeasured defaults
and says so on its loading line. To try another box's numbers on a bench:

    zig build run -- --box=5 --test-random-probe
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-09-14-box-presets-design.md README.md
git commit -m "docs: the preset as it was actually built

Zig has no struct-update syntax, so a box file is a comptime block over
a copy of the defaults rather than a with() call. And a drone plant
records trigger: the drone is held by nature, and writing hold there
would reach the detector and make it a different rig.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Verify on a box before the branches go

**Files:**
- Modify: none.

**Interfaces:**
- Consumes: everything above.
- Produces: the decision to delete `box2` and `box5`.

- [ ] **Step 1: Cross-build for the Pi**

```bash
zig build -Dtarget=aarch64-linux-gnu
```

Expected: builds. The repo has a `zig-out-pi/` in `.gitignore` from box2's chore commit, which is where this has been put before.

- [ ] **Step 2: Run it on box 5 and watch the first ten lines**

Copy the binary to box 5 and run it with no flags. Expected: `loading: box5` from the hostname, plant B loading `voicebox5`, and the status line showing counts floors of 4000 and 10000.

- [ ] **Step 3: Run it on box 2 the same way**

Expected: `loading: box2`, floors of 3000 and 10000, and a drone whose pitch spends its range rather than pinning at the top on every touch — the complaint box2's branch was cut to fix.

- [ ] **Step 4: Only then, delete the two branches**

```bash
git branch -D box2 box5
git push origin --delete box2 box5
```

If either box misbehaves, leave the branches: they are the only record of what those rigs were measured at, and this plan's Task 5 is the thing to re-check against them.

- [ ] **Step 5: Push `main`**

```bash
git push origin main
```
