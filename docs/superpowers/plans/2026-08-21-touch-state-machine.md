# Touch State Machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single absolute `--trigger` threshold with a two-stage state machine that reports which plant is touched (`none` / `plant_a` / `plant_bc` / `both`) from per-probe z-scores against each probe's own rolling median and MAD.

**Architecture:** A new pure module `src/touch.zig` turns two signed ADC readings per poll into a `State`. Stage one is per-probe: signed mean → rolling median + MAD → z-score → hysteresis latch. Stage two arbitrates: probe A is dominant, so when A latches, probe BC is re-baselined onto the crosstalk floor it settles at and must deviate from *that* to count. Detection stops rectifying the readings — rectification is what made the old threshold impossible — and plant A's pitch comes from deviation instead of level.

**Tech Stack:** Zig 0.16.0 via `nix develop`. No dependencies. Tests are `test` blocks inside each source file, run by `zig build test`.

**Spec:** `docs/superpowers/specs/2026-08-21-touch-state-machine-design.md`

## Global Constraints

- Zig **0.16.0**, supplied by `flake.nix`. Every command runs inside the dev shell: `nix develop -c zig build test`.
- Zig 0.16 I/O takes an explicit `std.Io`. The idioms already used in this repo, and the only ones to copy: `std.Io.Dir.cwd().openDir(io, path, .{})` (`library.zig:51`), `file.writeStreamingAll(io, bytes)` and `file.close(io)` (`sink.zig:115`, `sink.zig:121`). Do not write code for Zig 0.13/0.14 — it will not compile.
- `sample_rate = 44100`, `block_frames = 512`, `sensor_frames = 128` — all from `src/root.zig`. Polls per second = 44100/128 = **344.5**.
- Detection never rectifies. `@abs` appears only where a magnitude is genuinely wanted (pitch deviation).
- One threshold serves both probes: `--touch-level` is a z-score, default **6.0**.
- Every new file is registered in `src/root.zig`'s `pub const` list **and** its `test { _ = ... }` block, or its tests never run.
- Comment style: this codebase explains *why*, in prose, in full sentences. Match it. Do not add comments that restate the code.
- `zig build test` must pass at the end of every task.
- Commit after every task. Do not push.

---

### Task 1: `Mean` and `holdPolls` in a new `touch.zig`

The signed running mean every later stage is built on. `trigger.zig`'s `Average` cannot be reused: it clamps negatives to zero, which destroys the only signal this rig has.

**Files:**
- Create: `src/touch.zig`
- Modify: `src/root.zig` (add `pub const touch = @import("touch.zig");` beside the others, and `_ = touch;` inside `test { }`)
- Test: `src/touch.zig` (Zig keeps tests in the file under test)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `pub fn holdPolls(hold_ms: f32, sample_rate: u32, poll_frames: usize) u32`
  - `pub const Mean = struct { pub fn init(window_polls: u32) Mean; pub fn push(self: *Mean, reading: i16) i16; }`
  - `pub const max_mean_polls = 1024;`

- [ ] **Step 1: Write the failing tests**

Create `src/touch.zig` containing only the doc comment, the imports, and these tests:

```zig
//! Deciding which plant is being touched.
//!
//! Two probes, one decision. Each probe is judged against its own recent past
//! rather than against a number typed on the command line: a rolling median is
//! what the probe normally reads and the median absolute deviation is how much
//! it normally wanders, so a reading that is many deviations from the median is
//! a touch whatever the probe's resting level happens to be that day. That is
//! what lets one threshold serve two probes whose idle readings are −2049 and
//! +1000, and lets it keep serving them when the electrodes are moved.
//!
//! Nothing here is rectified. Touching plant A moves its probe from −2049 up to
//! +660 and touching the other moves it from positive noise down past −2049;
//! folding away the sign puts the second probe's touched state on top of its
//! untouched state, 26 counts apart, which is why no single threshold ever
//! worked on this rig.

const std = @import("std");

const testing = std.testing;

test "the hold converts to whole polls, never to none" {
    try testing.expectEqual(@as(u32, 34), holdPolls(100.0, 44100, 128));
    try testing.expectEqual(@as(u32, 3), holdPolls(10.0, 44100, 128));
    try testing.expectEqual(@as(u32, 1), holdPolls(0.0, 44100, 128));
}

test "the mean passes a steady reading through, sign and all" {
    var m = Mean.init(100);
    for (0..500) |_| try testing.expectEqual(@as(i16, -2049), m.push(-2049));
}

test "the mean answers from the first poll, not after a full window" {
    var m = Mean.init(100);
    try testing.expectEqual(@as(i16, -2000), m.push(-2000));
    try testing.expectEqual(@as(i16, -1000), m.push(0));
}

test "a negative reading lowers the mean instead of reading as silence" {
    // `trigger.Average` clamped negatives to zero, which is the whole reason
    // this type exists: probe A never once reads positive while untouched.
    var m = Mean.init(4);
    _ = m.push(-2049);
    _ = m.push(-2049);
    _ = m.push(-2049);
    try testing.expectEqual(@as(i16, -2049), m.push(-2049));
}

test "one spike moves the mean by a bounded amount and then leaves it" {
    var m = Mean.init(100);
    for (0..100) |_| _ = m.push(0);
    try testing.expectEqual(@as(i16, 327), m.push(32767));
    for (0..99) |_| _ = m.push(0);
    try testing.expectEqual(@as(i16, 0), m.push(0));
}

test "a window longer than the buffer is clamped rather than overrunning it" {
    var m = Mean.init(holdPolls(100_000.0, 44100, 128));
    try testing.expectEqual(max_mean_polls, m.len);
    for (0..2000) |_| _ = m.push(-1000);
    try testing.expectEqual(@as(i16, -1000), m.push(-1000));
}
```

Then add to `src/root.zig`: `pub const touch = @import("touch.zig");` after the `sensors` line, and `_ = touch;` inside the existing `test { }` block.

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `use of undeclared identifier 'holdPolls'` and `'Mean'`.

- [ ] **Step 3: Write the implementation**

Insert above the tests in `src/touch.zig`:

```zig
/// The longest window worth averaging over, about three seconds of polls.
pub const max_mean_polls = 1024;

/// `hold_ms` expressed in polls. At least one, so a hold of zero still means
/// "one poll decides" rather than "nothing ever decides".
pub fn holdPolls(hold_ms: f32, sample_rate: u32, poll_frames: usize) u32 {
    const polls_per_s = @as(f32, @floatFromInt(sample_rate)) /
        @as(f32, @floatFromInt(poll_frames));
    const polls = @round(hold_ms / 1000.0 * polls_per_s);
    if (!(polls >= 1.0)) return 1;
    return @intFromFloat(polls);
}

/// A running mean of the last `len` polls, signed.
///
/// A true mean over a window rather than a one-pole smoother: a spike's
/// contribution is then exactly one sample's worth and it leaves the window
/// altogether once the window has passed, where a one-pole would let it decay
/// away with a long tail that outlives the touch.
pub const Mean = struct {
    window: [max_mean_polls]i16,
    len: u32,
    /// How many have arrived so far, which is what the mean divides by until
    /// the window is full. Dividing by `len` from the start would read as a
    /// long silence for the first window and hold off a touch already under
    /// way.
    count: u32,
    head: u32,
    sum: i32,

    pub fn init(window_polls: u32) Mean {
        return .{
            .window = undefined,
            .len = std.math.clamp(window_polls, 1, max_mean_polls),
            .count = 0,
            .head = 0,
            .sum = 0,
        };
    }

    /// Add one poll's reading and get the mean including it.
    pub fn push(self: *Mean, reading: i16) i16 {
        if (self.count == self.len) {
            self.sum -= self.window[self.head];
        } else {
            self.count += 1;
        }
        self.window[self.head] = reading;
        self.sum += reading;
        self.head = (self.head + 1) % self.len;

        return @intCast(@divTrunc(self.sum, @as(i32, @intCast(self.count))));
    }
};
```

The sum is an `i32` because a full window of full-scale readings is 1024 × 32767 ≈ 33.5 M, which an `i32` holds with room to spare and an `i16` does not.

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/touch.zig src/root.zig
git commit -m "feat(touch): add signed running mean and hold conversion"
```

---

### Task 2: `Baseline` — decimated rolling median and MAD

**Files:**
- Modify: `src/touch.zig`
- Test: `src/touch.zig`

**Interfaces:**
- Consumes: `Mean` (Task 1) — only conceptually; `Baseline` takes already-averaged values.
- Produces:
  - `pub const max_baseline_samples = 1024;`
  - `pub const Baseline = struct { base: i16, mad: f32, frozen: bool, pub fn init(window_s: f32, sample_rate: u32, poll_frames: usize) Baseline; pub fn push(self: *Baseline, mean_value: i16) void; pub fn ready(self: *const Baseline) bool; }`

- [ ] **Step 1: Write the failing tests**

Append to the test section of `src/touch.zig`:

```zig
/// Ten seconds of window at the engine's real poll rate, which is what the
/// baseline tests want: long enough to have a median, short enough to fill.
fn testBaseline(window_s: f32) Baseline {
    return Baseline.init(window_s, 44100, 128);
}

test "the baseline is pushed at ten hertz, not at the poll rate" {
    var b = testBaseline(60.0);
    // 344.5 polls a second, so one push every 34 polls.
    try testing.expectEqual(@as(u32, 34), b.decim);
    // Sixty seconds of ten-hertz pushes.
    try testing.expectEqual(@as(u32, 600), b.len);

    for (0..34) |_| b.push(100);
    try testing.expectEqual(@as(u32, 1), b.count);
    for (0..34) |_| b.push(100);
    try testing.expectEqual(@as(u32, 2), b.count);
}

test "the median is the reading a steady probe keeps giving" {
    var b = testBaseline(10.0);
    for (0..34 * 100) |_| b.push(-2049);
    try testing.expectEqual(@as(i16, -2049), b.base);
    // A probe that never moves has no deviation to speak of.
    try testing.expect(b.mad < 1.0);
}

test "the median ignores a minority of touched samples" {
    var b = testBaseline(10.0);
    // Sixty seconds of idle at -2049, then nine seconds of touch at +660: the
    // touch is a minority of the window and the median does not follow it.
    for (0..34 * 700) |_| b.push(-2049);
    for (0..34 * 90) |_| b.push(660);
    try testing.expectEqual(@as(i16, -2049), b.base);
}

test "the mad measures how far a noisy probe normally wanders" {
    var b = testBaseline(10.0);
    // The shape of the untouched BC probe: positive, broad, centred near 1000.
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    for (0..34 * 400) |_| b.push(@intCast(rand.uintLessThan(u16, 2001)));
    try testing.expect(b.base > 800 and b.base < 1200);
    // A uniform spread of 0..2000 has a median absolute deviation near 500.
    try testing.expect(b.mad > 300.0 and b.mad < 700.0);
}

test "a frozen baseline is not moved by what arrives while it is frozen" {
    var b = testBaseline(10.0);
    for (0..34 * 100) |_| b.push(-2049);
    b.frozen = true;
    for (0..34 * 100) |_| b.push(660);
    try testing.expectEqual(@as(i16, -2049), b.base);
}

test "a detector may not answer until the baseline has warmed up" {
    var b = testBaseline(60.0);
    try testing.expect(!b.ready());
    // Three seconds of ten-hertz pushes.
    for (0..34 * 30) |_| b.push(-2049);
    try testing.expect(b.ready());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `use of undeclared identifier 'Baseline'`.

- [ ] **Step 3: Write the implementation**

Insert after `Mean` in `src/touch.zig`:

```zig
/// The longest baseline worth keeping, about a hundred seconds of pushes.
pub const max_baseline_samples = 1024;

/// How many baseline samples a second. The median only has to track a probe's
/// resting level, which moves over minutes; pushing every poll would need
/// twenty thousand samples for the same window and buy nothing.
const baseline_hz: f32 = 10.0;

/// How many samples must have arrived before a probe may be judged. Three
/// seconds. Before this the median is whatever the first few readings were, so
/// the score means nothing and a clip could start on it.
const warmup_samples: u32 = 30;

/// What a probe normally reads, and how far it normally wanders from that.
///
/// A median rather than a leaky average because a median is touch-proof for
/// free: a touch occupying less than half the window cannot move it, so there
/// is no need to detect a touch in order to stop the baseline learning it —
/// which would be circular, since the baseline is what detects the touch.
///
/// The cost is at the other end: a touch lasting more than half the window
/// *does* move the median, and the state releases while the hand is still
/// there. The window is the knob, and it wants to be about four times the
/// longest touch expected.
pub const Baseline = struct {
    samples: [max_baseline_samples]i16,
    scratch: [max_baseline_samples]i16,
    /// The window, in samples.
    len: u32,
    count: u32,
    head: u32,
    /// Polls between pushes.
    decim: u32,
    since: u32,
    /// The median, recomputed on each push and held between them.
    base: i16,
    /// The median absolute deviation, on the same schedule.
    mad: f32,
    /// While set, readings are dropped rather than learned. Crosstalk must not
    /// teach a probe that being pulled by the other plant is its resting state.
    frozen: bool,

    pub fn init(window_s: f32, sample_rate: u32, poll_frames: usize) Baseline {
        const polls_per_s = @as(f32, @floatFromInt(sample_rate)) /
            @as(f32, @floatFromInt(poll_frames));
        const decim = @max(1.0, @round(polls_per_s / baseline_hz));
        const len = @round(window_s * baseline_hz);
        return .{
            .samples = undefined,
            .scratch = undefined,
            .len = std.math.clamp(@as(u32, @intFromFloat(@max(len, 1.0))), 1, max_baseline_samples),
            .count = 0,
            .head = 0,
            .decim = @intFromFloat(decim),
            .since = 0,
            .base = 0,
            .mad = 0.0,
            .frozen = false,
        };
    }

    /// Feed one poll's mean. Most polls only advance the decimation counter.
    pub fn push(self: *Baseline, mean_value: i16) void {
        if (self.frozen) return;
        self.since += 1;
        if (self.since < self.decim) return;
        self.since = 0;

        if (self.count < self.len) self.count += 1;
        self.samples[self.head] = mean_value;
        self.head = (self.head + 1) % self.len;

        self.recompute();
    }

    /// Whether enough has arrived for the numbers to mean anything.
    pub fn ready(self: *const Baseline) bool {
        return self.count >= warmup_samples;
    }

    fn recompute(self: *Baseline) void {
        const n = self.count;
        @memcpy(self.scratch[0..n], self.samples[0..n]);
        std.mem.sort(i16, self.scratch[0..n], {}, std.sort.asc(i16));
        self.base = self.scratch[n / 2];

        for (self.scratch[0..n], self.samples[0..n]) |*out, sample| {
            const delta = @abs(@as(i32, sample) - @as(i32, self.base));
            out.* = @intCast(@min(delta, std.math.maxInt(i16)));
        }
        std.mem.sort(i16, self.scratch[0..n], {}, std.sort.asc(i16));
        self.mad = @floatFromInt(self.scratch[n / 2]);
    }
};
```

The deviation is computed in `i32` before being narrowed: two `i16` readings at opposite ends of the range are 65535 apart, which does not fit the type they came from.

Both sorts run on a push, so at most ten times a second over at most 1024 elements. That is nothing next to rendering 44100 samples a second, and it means the median is free at every poll in between.

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/touch.zig
git commit -m "feat(touch): add decimated rolling median and MAD baseline"
```

---

### Task 3: `Detector` — z-score and hysteresis latch

**Files:**
- Modify: `src/touch.zig`
- Test: `src/touch.zig`

**Interfaces:**
- Consumes: `Mean`, `Baseline`, `holdPolls`.
- Produces:
  - `pub const default_level: f32 = 6.0;`, `pub const default_hold_ms: f32 = 100.0;`, `pub const default_average_ms: f32 = 200.0;`, `pub const default_baseline_s: f32 = 60.0;`, `pub const default_settle_ms: f32 = 300.0;`
  - `pub const Config = struct { sample_rate: u32, poll_frames: usize, level: f32, hold_ms: f32, average_ms: f32, baseline_s: f32, settle_ms: f32 }`
  - `pub const Detector = struct { mean: Mean, baseline: Baseline, on: bool, z: f32, last_mean: i16, base_override: ?i16, pub fn init(cfg: Config) Detector; pub fn update(self: *Detector, raw: i16) bool; pub fn base(self: *const Detector) i16; pub fn deviation(self: *const Detector) i16; }`

- [ ] **Step 1: Write the failing tests**

Append to the test section of `src/touch.zig`:

```zig
/// The engine's real rates, with the windows the installation runs.
fn testConfig() Config {
    return .{ .sample_rate = 44100, .poll_frames = 128 };
}

/// Feed a detector one value for `polls` polls and return its last answer.
fn hold(d: *Detector, raw: i16, polls: usize) bool {
    var on = false;
    for (0..polls) |_| on = d.update(raw);
    return on;
}

test "a detector says nothing until its baseline has warmed up" {
    var d = Detector.init(testConfig());
    // One second of the probe's resting level, which is under the three the
    // warm-up wants.
    try testing.expect(!hold(&d, -2049, 344));
}

test "probe A's pinned idle never latches" {
    var d = Detector.init(testConfig());
    // Ten minutes of what the bench capture shows: -2049 and -2050, nothing
    // else. A MAD of half a count would score that at z = 2 without the floor.
    var prng = std.Random.DefaultPrng.init(3);
    const rand = prng.random();
    for (0..344 * 600) |_| {
        const raw: i16 = if (rand.boolean()) -2049 else -2050;
        try testing.expect(!d.update(raw));
    }
}

test "probe A's step to touched latches after the hold and not before" {
    var d = Detector.init(testConfig());
    _ = hold(&d, -2049, 344 * 10);
    try testing.expect(!d.on);

    // The hold is 100 ms, 34 polls. The mean window is 200 ms, so the mean
    // needs a moment to arrive before the vote can even start.
    _ = hold(&d, 660, 34);
    try testing.expect(!d.on);
    _ = hold(&d, 660, 344);
    try testing.expect(d.on);
}

test "an isolated spike never latches" {
    var d = Detector.init(testConfig());
    for (0..344 * 60) |i| {
        const raw: i16 = if (i % 500 == 0) 660 else -2049;
        try testing.expect(!d.update(raw));
    }
}

test "probe BC's noisy positive idle never latches" {
    var d = Detector.init(testConfig());
    var prng = std.Random.DefaultPrng.init(5);
    const rand = prng.random();
    for (0..344 * 300) |_| {
        try testing.expect(!d.update(@intCast(rand.uintLessThan(u16, 2001))));
    }
}

test "probe BC latches on a drop through zero, which no rectified reading could" {
    var d = Detector.init(testConfig());
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    for (0..344 * 60) |_| _ = d.update(@intCast(rand.uintLessThan(u16, 2001)));
    try testing.expect(!d.on);

    // -2049 is 2049 once rectified, which sits inside the idle spread of
    // 0..2023 the probe was just showing. Signed, it is nowhere near it.
    _ = hold(&d, -2049, 344);
    try testing.expect(d.on);
}

test "it releases when the probe returns to rest" {
    var d = Detector.init(testConfig());
    _ = hold(&d, -2049, 344 * 10);
    _ = hold(&d, 660, 344);
    try testing.expect(d.on);
    _ = hold(&d, -2049, 344);
    try testing.expect(!d.on);
}

test "an override baseline is what the score is measured from" {
    var d = Detector.init(testConfig());
    _ = hold(&d, -2049, 344 * 10);
    d.base_override = 660;
    // Long enough for the mean to arrive at the override; a single poll would
    // still be averaging in the ten seconds of rest before it.
    _ = hold(&d, 660, 344);
    // Sitting exactly on the override is no deviation at all, even though it is
    // a long way from what the median learned.
    try testing.expectApproxEqAbs(@as(f32, 0.0), d.z, 0.5);
}

test "deviation is the distance from rest, which is what the pitch wants" {
    var d = Detector.init(testConfig());
    _ = hold(&d, -2049, 344 * 10);
    try testing.expectEqual(@as(i16, 0), d.deviation());
    _ = hold(&d, 660, 344);
    try testing.expectEqual(@as(i16, 2709), d.deviation());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `use of undeclared identifier 'Config'` and `'Detector'`.

- [ ] **Step 3: Write the implementation**

Insert after `Baseline` in `src/touch.zig`:

```zig
/// How many deviations from its own median a probe must read before it counts
/// as touched. One number for both probes: that is what measuring in
/// deviations buys.
pub const default_level: f32 = 6.0;

/// How long the score has to keep saying so.
pub const default_hold_ms: f32 = 100.0;

/// How long the reading is averaged over before the score sees it.
pub const default_average_ms: f32 = 200.0;

/// How long the median looks back.
pub const default_baseline_s: f32 = 60.0;

/// How long the other probe is given to settle after this one is touched,
/// before its crosstalk level is taken as its temporary rest.
pub const default_settle_ms: f32 = 300.0;

/// The smallest deviation the score will divide by, in counts.
///
/// Probe A is too quiet for its own good: untouched it reads -2049 and -2050
/// and nothing else, so its true MAD is about half a count and a one-count
/// wobble would score two deviations. The floor is what stops a probe being
/// punished for being clean.
const mad_floor: f32 = 25.0;

pub const Config = struct {
    sample_rate: u32,
    poll_frames: usize,
    level: f32 = default_level,
    hold_ms: f32 = default_hold_ms,
    average_ms: f32 = default_average_ms,
    baseline_s: f32 = default_baseline_s,
    settle_ms: f32 = default_settle_ms,
};

/// One probe, judged against itself.
pub const Detector = struct {
    mean: Mean,
    baseline: Baseline,
    level: f32,
    /// Polls of agreement needed to change the answer, and where the counter
    /// sits between 0 and it.
    hold: u32,
    count: u32,
    /// The latched answer, held between the ends of the counter's travel, which
    /// is what stops a score hovering on the line from chattering.
    on: bool,
    /// The last score, kept for the log and the status line.
    z: f32,
    /// The last mean, which is what the score and the pitch are both taken
    /// from.
    last_mean: i16,
    /// Set while the other probe has this one pulled off its rest. The score is
    /// then measured from where the pull left it, so only a further move counts.
    base_override: ?i16,

    pub fn init(cfg: Config) Detector {
        return .{
            .mean = .init(holdPolls(cfg.average_ms, cfg.sample_rate, cfg.poll_frames)),
            .baseline = .init(cfg.baseline_s, cfg.sample_rate, cfg.poll_frames),
            .level = cfg.level,
            .hold = @max(holdPolls(cfg.hold_ms, cfg.sample_rate, cfg.poll_frames), 1),
            .count = 0,
            .on = false,
            .z = 0.0,
            .last_mean = 0,
            .base_override = null,
        };
    }

    /// What the score is measured from: the crosstalk floor while one is set,
    /// the learned median otherwise.
    pub fn base(self: *const Detector) i16 {
        return self.base_override orelse self.baseline.base;
    }

    /// How far the probe sits from rest. Unsigned, because this is what the
    /// drone's pitch is mapped from and a pitch has no sign.
    pub fn deviation(self: *const Detector) i16 {
        const delta = @abs(@as(i32, self.last_mean) - @as(i32, self.base()));
        return @intCast(@min(delta, std.math.maxInt(i16)));
    }

    /// Feed one poll's signed reading and get the latched answer.
    pub fn update(self: *Detector, raw: i16) bool {
        self.last_mean = self.mean.push(raw);
        self.baseline.push(self.last_mean);

        const denom = @max(self.baseline.mad, mad_floor);
        self.z = (@as(f32, @floatFromInt(self.last_mean)) -
            @as(f32, @floatFromInt(self.base()))) / denom;

        // Before the median has anything behind it the score is noise about
        // noise, and acting on it would start a clip at power-on.
        if (!self.baseline.ready()) {
            self.count = 0;
            self.on = false;
            return false;
        }

        if (@abs(self.z) >= self.level) {
            self.count = @min(self.count + 1, self.hold);
        } else {
            self.count -|= 1;
        }

        if (self.count == self.hold) {
            self.on = true;
        } else if (self.count == 0) {
            self.on = false;
        }
        return self.on;
    }
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

If "probe A's step to touched latches" fails by latching a poll or two early or late, the test's poll counts are the thing to adjust, not the hold — the mean window and the hold are both real and both deliberate.

- [ ] **Step 5: Commit**

```bash
git add src/touch.zig
git commit -m "feat(touch): add per-probe z-score detector with hysteresis"
```

---

### Task 4: `Machine` — state enum and crosstalk arbitration

**Files:**
- Modify: `src/touch.zig`
- Test: `src/touch.zig`

**Interfaces:**
- Consumes: `Detector`, `Config`, `holdPolls`.
- Produces:
  - `pub const State = enum { none, plant_a, plant_bc, both };`
  - `pub const Machine = struct { a: Detector, bc: Detector, pub fn init(cfg: Config) Machine; pub fn update(self: *Machine, raw_a: i16, raw_bc: i16) State; }`

- [ ] **Step 1: Write the failing tests**

Append to the test section of `src/touch.zig`:

```zig
/// Feed the machine one pair of readings for `polls` polls, last answer wins.
fn holdBoth(m: *Machine, raw_a: i16, raw_bc: i16, polls: usize) State {
    var state: State = .none;
    for (0..polls) |_| state = m.update(raw_a, raw_bc);
    return state;
}

/// The idle rig: probe A pinned, probe BC wandering about the positive half.
fn idle(m: *Machine, rand: std.Random, polls: usize) State {
    var state: State = .none;
    for (0..polls) |_| {
        state = m.update(-2049, @intCast(rand.uintLessThan(u16, 2001)));
    }
    return state;
}

test "an idle rig reports nothing touched" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    try testing.expectEqual(State.none, idle(&m, prng.random(), 344 * 120));
}

test "plant A alone" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);
    try testing.expectEqual(State.plant_a, holdBoth(&m, 660, 900, 344 * 2));
}

test "plant BC alone" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);
    try testing.expectEqual(State.plant_bc, holdBoth(&m, -2049, -2049, 344 * 2));
}

test "crosstalk from A does not read as a touch on BC" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);

    // A is touched and pulls BC down with it. Rectified, BC's -2049 is
    // indistinguishable from its idle spread; signed, it is a huge move. Only
    // the re-baselining tells it apart from a real touch.
    try testing.expectEqual(State.plant_a, holdBoth(&m, 660, -2049, 344 * 5));
}

test "a real touch on BC while A is held goes further than the crosstalk" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);
    _ = holdBoth(&m, 660, -2049, 344 * 5);
    // The bench capture's simultaneous touch: BC keeps going, past the floor
    // its crosstalk settled at.
    try testing.expectEqual(State.both, holdBoth(&m, 660, -3947, 344 * 2));
}

test "BC touched first is not re-baselined out from under itself" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);

    try testing.expectEqual(State.plant_bc, holdBoth(&m, -2049, -2049, 344 * 2));
    // A joins in. BC was already latched, so nothing about it is reinterpreted.
    try testing.expectEqual(State.both, holdBoth(&m, 660, -2049, 344 * 2));
}

test "releasing A puts BC back on its learned rest" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);
    _ = holdBoth(&m, 660, -2049, 344 * 5);
    try testing.expectEqual(@as(?i16, -2049), m.bc.base_override);

    try testing.expectEqual(State.none, idle(&m, prng.random(), 344 * 3));
    try testing.expectEqual(@as(?i16, null), m.bc.base_override);
}

test "a touch longer than half the baseline window reads as released" {
    // The documented limit of a median baseline. Ten-second window here so the
    // test does not have to run for minutes; the installation's default is 60.
    var cfg = testConfig();
    cfg.baseline_s = 10.0;
    var m = Machine.init(cfg);
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 20);

    try testing.expectEqual(State.plant_a, holdBoth(&m, 660, 900, 344 * 2));
    // Held past half the window, the median migrates onto the touched level and
    // the score decays to nothing. Raise --touch-baseline to push this out.
    try testing.expectEqual(State.none, holdBoth(&m, 660, 900, 344 * 20));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `use of undeclared identifier 'Machine'`.

- [ ] **Step 3: Write the implementation**

Insert after `Detector` in `src/touch.zig`:

```zig
/// Which plants are being touched.
pub const State = enum { none, plant_a, plant_bc, both };

/// Both probes, and the rule that tells a touch from the other probe's shadow.
///
/// Probe A is dominant: on the bench, touching plant A drags the other probe
/// down to about -2049, while touching the other leaves plant A's probe exactly
/// where it was. So the arbitration is one-directional, and the shadow it has
/// to see through is the awkward kind — the crosstalk floor is the same value a
/// genuine touch on the other probe produces, so no level can separate them.
///
/// What separates them is that a real touch on top of the crosstalk goes
/// further still, to about -3900. So when A latches, the other probe is given a
/// moment to settle and whatever it settles at becomes its rest for as long as
/// A is held. Sitting on the crosstalk floor is then no deviation at all, and
/// only a further move counts. Nothing here is a tuned constant: the floor is
/// measured each time, so it can move with the weather.
pub const Machine = struct {
    a: Detector,
    bc: Detector,
    /// How long the other probe is given to settle, and how much of that is
    /// left. While it is running, BC cannot latch: the transition itself is
    /// exactly the kind of large move that would look like a touch.
    settle_polls: u32,
    settle_left: u32,
    /// Whether the settle now running ends in a re-baselining. It does not when
    /// BC was already touched before A arrived.
    rebasing: bool,
    prev_a: bool,

    pub fn init(cfg: Config) Machine {
        return .{
            .a = .init(cfg),
            .bc = .init(cfg),
            .settle_polls = holdPolls(cfg.settle_ms, cfg.sample_rate, cfg.poll_frames),
            .settle_left = 0,
            .rebasing = false,
            .prev_a = false,
        };
    }

    /// Feed one poll of both probes, signed and unrectified, and get the state.
    pub fn update(self: *Machine, raw_a: i16, raw_bc: i16) State {
        const a_on = self.a.update(raw_a);

        // A's edges are handled before BC is updated, so the freeze is in place
        // before the first crosstalk-poisoned reading could be learned.
        if (a_on and !self.prev_a and !self.bc.on) {
            self.rebasing = true;
            self.settle_left = self.settle_polls;
            self.bc.baseline.frozen = true;
        } else if (!a_on and self.prev_a) {
            self.rebasing = false;
            self.settle_left = 0;
            self.bc.base_override = null;
            self.bc.baseline.frozen = false;
        }
        self.prev_a = a_on;

        var bc_on = self.bc.update(raw_bc);

        if (self.settle_left > 0) {
            self.settle_left -= 1;
            self.bc.count = 0;
            self.bc.on = false;
            bc_on = false;
            if (self.settle_left == 0 and self.rebasing) {
                self.bc.base_override = self.bc.last_mean;
            }
        }

        if (a_on and bc_on) return .both;
        if (a_on) return .plant_a;
        if (bc_on) return .plant_bc;
        return .none;
    }
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

Two things to know before debugging failures here.

The MAD these tests divide by is the MAD **of the 200 ms means**, not of the raw samples. BC's simulated idle is a fresh uniform draw per poll, so a 69-poll mean smooths it from a spread of ~500 counts down to ~50, and `−3947` against a `−2049` override scores about z = 40. On real hardware BC's noise is correlated — mains hum, not white — so the mean smooths it less and the margin is smaller. How much smaller is exactly what the CSV from a live session answers; it is listed under "After the plan".

The two probes race at A's rising edge. A's z is enormous (its MAD sits on the floor of 25), so A latches in about 40 polls, while BC needs its mean to travel most of a 69-poll window before it even starts voting. A therefore wins and freezes BC before BC can latch on the crosstalk. If "crosstalk from A does not read as a touch on BC" fails, print both `count` fields per poll around the edge — the fix is not to lengthen BC's hold but to check that A's edge handling really does run before `bc.update`.

If a test fails on a margin, report `m.bc.z` rather than editing `cfg.level` or `mad_floor`. Those two are the design; the test's poll counts are not.

- [ ] **Step 5: Commit**

```bash
git add src/touch.zig
git commit -m "feat(touch): add state machine with crosstalk re-baselining"
```

---

### Task 5: Replay the bench capture

`src/testdata/touch-sample.txt` already exists: 96 rows of two tab-separated signed counts, with a `#` header recording that column one is probe A and column two probe BC.

**Files:**
- Modify: `src/touch.zig`
- Read: `src/testdata/touch-sample.txt`
- Test: `src/touch.zig`

**Interfaces:**
- Consumes: `Machine`, `State`.
- Produces: nothing public.

- [ ] **Step 1: Write the failing test**

Append to the test section of `src/touch.zig`:

```zig
const fixture = @embedFile("testdata/touch-sample.txt");

const Row = struct { a: i16, bc: i16 };

/// The bench capture, comment lines dropped.
fn parseFixture(rows: *[128]Row) usize {
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var cols = std.mem.tokenizeAny(u8, trimmed, " \t");
        const a_text = cols.next() orelse continue;
        const bc_text = cols.next() orelse continue;
        rows[n] = .{
            .a = std.fmt.parseInt(i16, a_text, 10) catch continue,
            .bc = std.fmt.parseInt(i16, bc_text, 10) catch continue,
        };
        n += 1;
    }
    return n;
}

test "the bench capture plays through the machine the way it was recorded" {
    var rows: [128]Row = undefined;
    const n = parseFixture(&rows);
    // The capture, minus its comment header.
    try testing.expectEqual(@as(usize, 96), n);

    // The capture has no timestamps, so each row is held for a second of polls.
    // That makes the idle prefix long enough to warm the median and keeps every
    // touch well under half the baseline window.
    const polls_per_row = 344;
    var cfg = testConfig();
    // The capture takes three rows to show the crosstalk arriving, so the
    // settle window has to span them.
    cfg.settle_ms = 4000.0;
    var m = Machine.init(cfg);

    var states: [128]State = undefined;
    for (rows[0..n], 0..) |row, i| {
        var state: State = .none;
        for (0..polls_per_row) |_| state = m.update(row.a, row.bc);
        states[i] = state;
    }

    // Rows 0-28 are the untouched rig. Nothing may fire there, and this is the
    // claim that matters most: every false clip in the room starts here.
    for (states[0..29]) |state| try testing.expectEqual(State.none, state);

    // Rows 29-31: probe A has jumped to +660 while BC is still showing its
    // ordinary positive noise.
    try testing.expectEqual(State.plant_a, states[30]);

    // Rows 33-35: A still held, BC pinned at the crosstalk floor. This is the
    // claim the whole arbitration exists for — BC must not be reported as
    // touched on the strength of a pull it did not choose, even though these
    // rows read exactly like row 44, which is a real touch on BC.
    for (states[33..36]) |state| try testing.expectEqual(State.plant_a, state);

    // Row 44 is the only row in the capture with A at rest and BC negative.
    try testing.expectEqual(State.plant_bc, states[44]);

    // Rows 36-37 (-3947, -3766) are what a real touch on BC on top of A's
    // crosstalk looks like, and `both` is what the machine should say there.
    // It is deliberately not asserted: the capture carries no timestamps, so
    // this test holds each row for a second, and at that rate the 200 ms mean
    // does no smoothing and BC's MAD stays as wide as its raw spread. Whether
    // -3947 clears six deviations from the -2049 floor depends on a sample rate
    // this file does not record. The synthetic test in Task 4 covers the rule;
    // a live CSV settles the margin.
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix develop -c zig build test`
Expected: FAIL. Either `@embedFile` cannot find the file, or the state assertions do not hold yet.

If the failure is `unable to open 'testdata/touch-sample.txt'`, the module needs the file declared. Add to `build.zig`, immediately after `const mod = b.addModule(...)`:

```zig
mod.addAnonymousImport("touch-sample", .{ .root_source_file = b.path("src/testdata/touch-sample.txt") });
```

and change the test to `const fixture = @import("touch-sample");`. Try the plain `@embedFile` first — a relative path from the importing file usually resolves without any build change.

- [ ] **Step 3: Make the test pass**

No new implementation should be needed: Tasks 1–4 built the machine this replays. If an assertion fails, the fault is in the machine or in the plan's reading of the capture, and it is worth stopping to look at rather than editing the assertion until it is green. Print the whole `states` array alongside `m.a.z` and `m.bc.z` per row and compare against the capture before changing anything.

The one legitimate adjustment: `polls_per_row` and `cfg.settle_ms` are inventions of this test, since the capture carries no timestamps. Those may be tuned. `cfg.level` and `mad_floor` may not — they are the design.

- [ ] **Step 4: Run the test to verify it passes**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/touch.zig build.zig
git commit -m "test(touch): replay the bench capture through the state machine"
```

---

### Task 6: Deviation pitch and an idle drone

**Files:**
- Modify: `src/noise.zig`
- Modify: `src/main.zig` (the two `noise.Noise.init` calls)
- Modify: `src/root.zig` (`peakOf` calls `noise.Noise.init`)
- Test: `src/noise.zig`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `pub fn freqFromDeviation(dev: i16, span: i16) f32`
  - `pub fn Noise.init(sample_rate: u32, seed: u64, span: i16) Noise`
  - `pub const default_span: i16 = 3000;`
  - `Noise.render(out: []f32, dev: i16, touched: bool)` — signature unchanged, meaning changed: the second argument is now a deviation from rest, not a level.

- [ ] **Step 1: Write the failing tests**

In `src/noise.zig`, replace the existing tests that mention `freqFromEcg` or `sensors.ecg_max` with these, and add the new ones:

```zig
test "rest is the bottom of the range and a full deviation the top" {
    try testing.expectApproxEqAbs(freq_min, freqFromDeviation(0, default_span), 0.01);
    try testing.expectApproxEqAbs(freq_max, freqFromDeviation(default_span, default_span), 0.01);
    // Past the span it clamps rather than running off the top.
    try testing.expectApproxEqAbs(freq_max, freqFromDeviation(32767, default_span), 0.01);
}

test "the pitch rises with the deviation, on a log scale" {
    var last: f32 = 0.0;
    for (0..100) |i| {
        const dev: i16 = @intCast(i * @as(usize, @intCast(default_span)) / 100);
        const f = freqFromDeviation(dev, default_span);
        try testing.expect(f > last);
        last = f;
    }
}

test "plant A's touch reaches the top half of the range" {
    // The bench capture: rest -2049, touched +660, so a deviation of 2709
    // against the default span of 3000.
    const f = freqFromDeviation(2709, default_span);
    try testing.expect(f > 500.0);
}

test "an untouched drone is quieter but never silent" {
    var n = Noise.init(44100, 1, default_span);
    var block: [4096]f32 = undefined;
    // Long enough for the gate to finish its fade.
    for (0..20) |_| {
        @memset(&block, 0);
        n.render(&block, 0, false);
    }
    var peak: f32 = 0.0;
    for (block) |s| peak = @max(peak, @abs(s));
    try testing.expect(peak > 0.0);

    var touched_peak: f32 = 0.0;
    for (0..20) |_| {
        @memset(&block, 0);
        n.render(&block, 2709, true);
    }
    for (block) |s| touched_peak = @max(touched_peak, @abs(s));
    try testing.expect(touched_peak > peak);
}

test "rest is audible rather than felt" {
    // 20 Hz was under most speakers; the room has to hum while nobody is there.
    try testing.expect(freq_min >= 60.0);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `use of undeclared identifier 'freqFromDeviation'`.

- [ ] **Step 3: Write the implementation**

In `src/noise.zig`:

1. Change `pub const freq_min: f32 = 20.0;` to `pub const freq_min: f32 = 80.0;` and update its comment to say why: rest is heard, not merely felt.

2. Delete `freqFromEcg` and the `sensors` import if nothing else uses it, and add:

```zig
/// Deviation from rest that maps to the top of the pitch range.
///
/// Not the sensor's full scale: this rig's whole signal lives inside a few
/// thousand counts, and mapping across 32767 squashed the entire piece into the
/// bottom five hertz of the range. Plant A's touch is a move of about 2700
/// counts, so 3000 spends most of the range on it.
pub const default_span: i16 = 3000;

/// How loud the drone sits while nobody is touching anything.
///
/// The room is never silent: an installation that goes quiet reads as broken
/// rather than as waiting. A touch is then a swell rather than an entrance.
const idle_gain: f32 = 0.35;

/// Map a deviation from rest to centre frequency on a log scale, so equal steps
/// in the deviation sound like equal pitch steps.
///
/// Deviation rather than level, because level is meaningless here: probe A
/// rests at -2049 and reads +660 when touched, so the reading's magnitude
/// *falls* on a touch. Distance from rest rises on a touch whichever way the
/// probe happens to move, and it is zero when nobody is there.
pub fn freqFromDeviation(dev: i16, span: i16) f32 {
    const t = std.math.clamp(
        @as(f32, @floatFromInt(dev)) / @as(f32, @floatFromInt(@max(span, 1))),
        0.0,
        1.0,
    );
    return freq_min * std.math.pow(f32, freq_max / freq_min, t);
}
```

3. Add a `span: i16` field to `Noise`, take it in `init`, and use it: `const target_fc = freqFromDeviation(dev, self.span);`. Rename the `ecg` parameter of `render` to `dev`.

4. Change the gate target line from `const gate_target: f32 = if (touched) 1.0 else 0.0;` to `const gate_target: f32 = if (touched) 1.0 else idle_gain;`.

5. In `src/main.zig`, both `ms.noise.Noise.init(ms.sample_rate, seed)` calls become `ms.noise.Noise.init(ms.sample_rate, seed, opts.pitch_span)` — but `opts.pitch_span` does not exist until Task 7, so pass `ms.noise.default_span` here and change it in Task 8.

6. In `src/root.zig`, `peakOf` calls `noise.Noise.init(sample_rate, 1)` — add the third argument `noise.default_span` — and renders with `16500`, which is now a deviation far past the span; change it to `noise.default_span`.

`sampler.Voice` and `tone.Tone` keep gating to zero. They are bench tools for hearing whether the wiring works, not voices in the room.

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/noise.zig src/main.zig src/root.zig
git commit -m "feat(noise): pitch from deviation, idle drone at 80 Hz"
```

---

### Task 7: Signed readings out of `sensors`

**Files:**
- Modify: `src/sensors.zig`
- Modify: `src/main.zig` (reads `reading.ecg_a` / `reading.ecg_bc`, and `reportStart`)
- Test: `src/sensors.zig`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `sensors.Reading = struct { raw_a: i16, raw_bc: i16, touch: [plant_count]bool }`
- Removes: `sensors.ecgFromAdc`, `sensors.ecg_max`.

- [ ] **Step 1: Write the failing tests**

In `src/sensors.zig`, delete the test `"adc readings land inside the voice's range"` entirely — it asserts the rectification this task removes. Replace the two simulation tests with these:

```zig
test "the simulated rig looks like the bench: A pinned, BC noisy and positive" {
    var sens = Sensors.init(44100, 1);
    for (0..500) |_| {
        const reading = sens.tick(512);
        // Probe A untouched is -2049 or -2050 and nothing else.
        try testing.expect(reading.raw_a <= -2049 and reading.raw_a >= -2050);
        // Probe BC untouched wanders across the positive half.
        try testing.expect(reading.raw_bc >= 0 and reading.raw_bc <= sim_bc_max);
    }
}

test "the simulated probes are drawn apart, not as one number" {
    var sens = Sensors.init(44100, 7);
    var moved_apart = false;
    for (0..500) |_| {
        const reading = sens.tick(512);
        if (reading.raw_a != reading.raw_bc) moved_apart = true;
    }
    try testing.expect(moved_apart);
}

test "the simulation never fakes a touch" {
    // A run with no hardware reports an untouched rig, because that is what an
    // unattended bench is. `--touch=script` is how the piece is demonstrated
    // without electrodes; inventing touches here would hide a dead I2C bus.
    var sens = Sensors.init(44100, 1);
    for (0..500) |_| {
        const reading = sens.tick(512);
        try testing.expect(reading.raw_a < 0);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, no field `raw_a` in `Reading`, and `sim_bc_max` undeclared.

- [ ] **Step 3: Write the implementation**

In `src/sensors.zig`:

1. Delete `ecg_max`, `ecgFromAdc`, `walk_min`, `walk_max`, `walk_step` and `walkStep`.

2. Rewrite the `Reading` fields and their comments:

```zig
pub const Reading = struct {
    /// The AIN0 probe, exactly as the chip reported it. Signed and unrectified:
    /// this probe rests below ground and rises through it when touched, so the
    /// sign is the signal and folding it away destroys the reading.
    raw_a: i16,
    /// The AIN1 probe, on the same terms.
    raw_bc: i16,
    /// Per plant, whether its motion sensor says someone is there. Indexed
    /// 0 = A, 1 = B, 2 = C. Unconsulted while the probes decide.
    touch: [plant_count]bool,
};
```

3. Add the simulation constants and generators, replacing the random walk:

```zig
/// What the untouched rig reads on the bench, which is what the simulation
/// imitates. Probe A sits below ground and barely moves; probe BC floats and
/// picks up whatever is in the room, always positive.
const sim_a_rest: i16 = -2049;
const sim_bc_max: u16 = 2000;

fn simA(random: std.Random) i16 {
    return sim_a_rest - @as(i16, @intCast(random.uintLessThan(u8, 2)));
}

fn simBc(random: std.Random) i16 {
    return @intCast(random.uintLessThan(u16, sim_bc_max + 1));
}
```

4. Rename the `ecg_a` / `ecg_bc` fields of `Sensors` to `raw_a` / `raw_bc`, initialise them to `sim_a_rest` and `0`, store `raw` directly where `ecgFromAdc(raw)` was called, and replace the `else` branch of the ADC block with `self.raw_a = simA(...); self.raw_bc = simBc(...);`.

5. In `src/main.zig`: rename the local `ecg_a` / `ecg_bc` to `raw_a` / `raw_bc`, read them from the new field names, and update `reportStart` and `Status.observe` parameter names to match. The status line's `a0=` and `a1=` labels stay — they name the pins.

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/sensors.zig src/main.zig
git commit -m "refactor(sensors): report signed raw counts, drop rectification"
```

---

### Task 8: Command line and wiring; delete `trigger.zig`

**Files:**
- Modify: `src/cli.zig`
- Modify: `src/main.zig`
- Modify: `src/root.zig`
- Delete: `src/trigger.zig`
- Test: `src/cli.zig`

**Interfaces:**
- Consumes: `touch.Config`, `touch.Machine`, `touch.State`, `touch.default_*`, `noise.default_span`.
- Produces: `cli.Options` gains `touch_level: f32`, `touch_hold_ms: f32`, `touch_average_ms: f32`, `touch_baseline_s: f32`, `touch_settle_ms: f32`, `pitch_span: i16`, `log_path_buf`/`log_path_len` with `pub fn logPath(self: *const Options) ?[]const u8`. `cli.Touch` gains `probes` and defaults to it.

- [ ] **Step 1: Write the failing tests**

Replace the `--trigger` tests in `src/cli.zig` with:

```zig
test "the probes decide unless something else was asked for" {
    const opts = try parse(&.{});
    try testing.expectEqual(Touch.probes, opts.touch);
    try testing.expectEqual(touch.default_level, opts.touch_level);
    try testing.expectEqual(touch.default_baseline_s, opts.touch_baseline_s);
    try testing.expectEqual(noise.default_span, opts.pitch_span);
    try testing.expectEqual(@as(?[]const u8, null), opts.logPath());
}

test "every touch knob takes a number" {
    const opts = try parse(&.{
        "--touch-level=8",
        "--touch-hold=250",
        "--touch-average=400",
        "--touch-baseline=120",
        "--touch-settle=500",
        "--pitch-span=4000",
    });
    try testing.expectEqual(@as(f32, 8.0), opts.touch_level);
    try testing.expectEqual(@as(f32, 250.0), opts.touch_hold_ms);
    try testing.expectEqual(@as(f32, 400.0), opts.touch_average_ms);
    try testing.expectEqual(@as(f32, 120.0), opts.touch_baseline_s);
    try testing.expectEqual(@as(f32, 500.0), opts.touch_settle_ms);
    try testing.expectEqual(@as(i16, 4000), opts.pitch_span);
}

test "nonsense on the touch knobs is refused rather than rounded" {
    try testing.expectError(Error.InvalidTouchLevel, parse(&.{"--touch-level=0"}));
    try testing.expectError(Error.InvalidTouchLevel, parse(&.{"--touch-level=-3"}));
    try testing.expectError(Error.InvalidTouchHold, parse(&.{"--touch-hold=9000"}));
    try testing.expectError(Error.InvalidTouchAverage, parse(&.{"--touch-average=5000"}));
    try testing.expectError(Error.InvalidTouchBaseline, parse(&.{"--touch-baseline=0"}));
    try testing.expectError(Error.InvalidTouchSettle, parse(&.{"--touch-settle=9000"}));
    try testing.expectError(Error.InvalidPitchSpan, parse(&.{"--pitch-span=0"}));
}

test "the old trigger flags say what replaced them" {
    try testing.expectError(Error.TriggerRetired, parse(&.{"--trigger"}));
    try testing.expectError(Error.TriggerRetired, parse(&.{"--trigger=25000"}));
    try testing.expectError(Error.TriggerRetired, parse(&.{"--trigger-hold=250"}));
    try testing.expectError(Error.TriggerRetired, parse(&.{"--trigger-average=400"}));
}

test "the log path is carried inline so the arguments can be dropped" {
    const opts = try parse(&.{"--log-touch=/tmp/touch.csv"});
    try testing.expectEqualStrings("/tmp/touch.csv", opts.logPath().?);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `Touch.probes` and `Error.InvalidTouchLevel` undeclared.

- [ ] **Step 3: Write the implementation**

In `src/cli.zig`:

1. Replace `const trigger = @import("trigger.zig");` with `const touch = @import("touch.zig");` and add `const noise = @import("noise.zig");`.

2. In `Error`, drop `InvalidTrigger`, `InvalidTriggerHold`, `InvalidTriggerAverage`; add `InvalidTouchLevel`, `InvalidTouchHold`, `InvalidTouchAverage`, `InvalidTouchBaseline`, `InvalidTouchSettle`, `InvalidPitchSpan`, `InvalidLogPath`, `TriggerRetired`.

3. Delete `default_trigger`. Add `probes` to `Touch` as the first member with the comment that it is the installation, and change `Options.touch`'s default to `.probes`.

4. Replace the three `trigger_*` fields with:

```zig
    /// How many deviations from its own median a probe must read before it
    /// counts as touched. One number for both probes.
    touch_level: f32 = touch.default_level,
    /// How long the score must keep saying so, in milliseconds.
    touch_hold_ms: f32 = touch.default_hold_ms,
    /// How long a reading is averaged over before the score sees it.
    touch_average_ms: f32 = touch.default_average_ms,
    /// How far back the median looks, in seconds. Wants to be about four times
    /// the longest touch expected: a touch filling more than half the window
    /// teaches the median that it is the resting state.
    touch_baseline_s: f32 = touch.default_baseline_s,
    /// How long the other probe is given to settle after this one is touched,
    /// before its crosstalk level is taken as its temporary rest.
    touch_settle_ms: f32 = touch.default_settle_ms,
    /// The deviation that maps to the top of plant A's pitch range.
    pitch_span: i16 = noise.default_span,
    /// Where the per-poll CSV goes, carried inline for the same reason the
    /// device name is.
    log_path_buf: [path_max]u8 = undefined,
    log_path_len: usize = 0,
```

with `pub const path_max = 255;` beside `device_max`, and:

```zig
    pub fn logPath(self: *const Options) ?[]const u8 {
        if (self.log_path_len == 0) return null;
        return self.log_path_buf[0..self.log_path_len];
    }
```

5. Replace the `--trigger*` branches in `parse` with:

```zig
        } else if (std.mem.eql(u8, arg, "--trigger") or
            std.mem.startsWith(u8, arg, "--trigger=") or
            std.mem.startsWith(u8, arg, "--trigger-hold=") or
            std.mem.startsWith(u8, arg, "--trigger-average="))
        {
            // Named rather than swept into UnknownFlag: anyone running the
            // installation has these in a shell history somewhere.
            return Error.TriggerRetired;
        } else if (std.mem.startsWith(u8, arg, "--touch-level=")) {
            const level = std.fmt.parseFloat(f32, arg["--touch-level=".len..]) catch
                return Error.InvalidTouchLevel;
            // Under about two deviations everything is a touch, and past a
            // hundred nothing is.
            if (!(level >= 1.0) or level > 100.0) return Error.InvalidTouchLevel;
            opts.touch_level = level;
        } else if (std.mem.startsWith(u8, arg, "--touch-hold=")) {
            const held = std.fmt.parseFloat(f32, arg["--touch-hold=".len..]) catch
                return Error.InvalidTouchHold;
            if (!(held >= 0.0) or held > 5000.0) return Error.InvalidTouchHold;
            opts.touch_hold_ms = held;
        } else if (std.mem.startsWith(u8, arg, "--touch-average=")) {
            const window = std.fmt.parseFloat(f32, arg["--touch-average=".len..]) catch
                return Error.InvalidTouchAverage;
            if (!(window >= 0.0) or window > 3000.0) return Error.InvalidTouchAverage;
            opts.touch_average_ms = window;
        } else if (std.mem.startsWith(u8, arg, "--touch-baseline=")) {
            const window = std.fmt.parseFloat(f32, arg["--touch-baseline=".len..]) catch
                return Error.InvalidTouchBaseline;
            // A hundred seconds is the longest the buffer holds at ten hertz.
            if (!(window > 0.0) or window > 100.0) return Error.InvalidTouchBaseline;
            opts.touch_baseline_s = window;
        } else if (std.mem.startsWith(u8, arg, "--touch-settle=")) {
            const settle = std.fmt.parseFloat(f32, arg["--touch-settle=".len..]) catch
                return Error.InvalidTouchSettle;
            if (!(settle >= 0.0) or settle > 5000.0) return Error.InvalidTouchSettle;
            opts.touch_settle_ms = settle;
        } else if (std.mem.startsWith(u8, arg, "--pitch-span=")) {
            const span = std.fmt.parseInt(i16, arg["--pitch-span=".len..], 10) catch
                return Error.InvalidPitchSpan;
            if (span <= 0) return Error.InvalidPitchSpan;
            opts.pitch_span = span;
        } else if (std.mem.startsWith(u8, arg, "--log-touch=")) {
            const path = arg["--log-touch=".len..];
            if (path.len == 0 or path.len > path_max) return Error.InvalidLogPath;
            @memcpy(opts.log_path_buf[0..path.len], path);
            opts.log_path_len = path.len;
        }
```

6. Replace the `--trigger` paragraphs of `usage` with this, and update the usage line at the top to `[--touch=probes|always|script|motion] [--touch-level=Z] [--touch-hold=MS] [--touch-average=MS] [--touch-baseline=S] [--touch-settle=MS] [--pitch-span=COUNTS] [--log-touch=PATH]`:

```zig
    \\Each probe is judged against its own recent past rather than against a
    \\number typed here. --touch-level is how many deviations from its own
    \\rolling median a probe must read before it counts as touched, 6 by
    \\default, and the same number serves both probes: a probe resting at
    \\-2049 and one resting at +1000 are both asked the same question.
    \\
    \\--touch-average is how long a reading is averaged over before the score
    \\sees it, 200 ms by default. Nothing is rectified: this rig's probes rest
    \\below ground and one of them rises through it when touched, so the sign
    \\is the signal.
    \\
    \\--touch-hold is how long the score must keep saying so before it counts,
    \\100 ms by default. The score is tested 344 times a second, so without a
    \\hold one noisy poll could start a clip that runs for minutes.
    \\
    \\--touch-baseline is how far back the median looks, 60 seconds by
    \\default. A touch filling more than half that window teaches the median
    \\that being touched is the resting state, and the plant goes quiet with a
    \\hand still on it; set this to about four times the longest touch you
    \\expect.
    \\
    \\--touch-settle is how long the other probe is given to settle after this
    \\one is touched, 300 ms by default. Touching plant A drags the other probe
    \\with it, to the same reading a real touch on it would give; after the
    \\settle, wherever it was dragged to becomes its rest for as long as A is
    \\held, so only a further move counts as a touch of its own.
    \\
    \\--pitch-span is the deviation from rest that reaches the top of plant A's
    \\range, 3000 counts by default. Plant A's touch moves its probe about 2700
    \\counts, so most of the range is spent on it.
    \\
    \\--log-touch writes every poll's numbers to PATH as CSV: both probes' raw
    \\reading, mean, median, deviation, score and latch, and the state they
    \\produced. About 20 MB per fifteen minutes. This is how a threshold that
    \\fires in an empty room gets diagnosed at a desk instead of in the
    \\gallery.
```

In `src/main.zig`:

7. Replace the `gate` block with the machine:

```zig
    var machine = ms.touch.Machine.init(.{
        .sample_rate = ms.sample_rate,
        .poll_frames = ms.sensor_frames,
        .level = opts.touch_level,
        .hold_ms = opts.touch_hold_ms,
        .average_ms = opts.touch_average_ms,
        .baseline_s = opts.touch_baseline_s,
        .settle_ms = opts.touch_settle_ms,
    });
```

8. Replace the `open` computation and the two render calls in the poll loop with:

```zig
            // The probes decide, unless a demonstration asked for something
            // else. `select` masks a plant that was left out of this run, which
            // is all it takes to keep its voice shut.
            const state = switch (opts.touch) {
                .probes => machine.update(raw_a, raw_bc),
                else => stateFrom(ms.select.apply(sel, reading.touch)),
            };
            const a_touched = sel[0] and (state == .plant_a or state == .both);
            const bc_touched = (sel[1] or sel[2]) and
                (state == .plant_bc or state == .both);

            // Plant A hears its own probe, as a distance from that probe's
            // rest. Untouched that distance is zero, so the drone sits at the
            // bottom of its range and hums rather than falling silent — and
            // while the other plant is being touched, plant A holds there too,
            // with no special case for it.
            voice_a.render(piece, machine.a.deviation(), a_touched);
```

with `voices_bc.render(piece, bc_touched)` below, and this helper beside `openSensors`:

```zig
/// The state a motion-driven or scripted run reports, so the demonstration
/// modes reach the voices through the same door the probes do.
fn stateFrom(touched: [ms.sensors.plant_count]bool) ms.touch.State {
    const bc = touched[1] or touched[2];
    if (touched[0] and bc) return .both;
    if (touched[0]) return .plant_a;
    if (bc) return .plant_bc;
    return .none;
}
```

Keep the existing `voices_bc.starts` comparison and `reportStart` call unchanged, and keep the two lines that rewrite `touch[1]` and `touch[2]` from `voices_bc.playingIndex()` for the status line.

9. Pass `opts.pitch_span` to both `ms.noise.Noise.init` calls, replacing the `ms.noise.default_span` left there by Task 6.

10. Add the retired-flag message to the error switch in `main`:

```zig
            error.TriggerRetired => std.debug.print(
                \\--trigger is gone. The threshold it set could not exist: the
                \\reading was rectified before it was compared, which folded one
                \\probe's touched state onto its untouched one.
                \\Use --touch-level, which is in deviations and serves both
                \\probes. See --help.
                \\
            , .{}),
```

and these beside it:

```zig
            error.InvalidTouchLevel => std.debug.print(
                "--touch-level takes deviations between 1 and 100.\n\n",
                .{},
            ),
            error.InvalidTouchHold => std.debug.print(
                "--touch-hold takes milliseconds between 0 and 5000.\n\n",
                .{},
            ),
            error.InvalidTouchAverage => std.debug.print(
                "--touch-average takes milliseconds between 0 and 3000.\n\n",
                .{},
            ),
            error.InvalidTouchBaseline => std.debug.print(
                "--touch-baseline takes seconds between 0 and 100.\n\n",
                .{},
            ),
            error.InvalidTouchSettle => std.debug.print(
                "--touch-settle takes milliseconds between 0 and 5000.\n\n",
                .{},
            ),
            error.InvalidPitchSpan => std.debug.print(
                "--pitch-span takes a whole number of counts above zero.\n\n",
                .{},
            ),
            error.InvalidLogPath => std.debug.print(
                "--log-touch takes a path of up to {d} characters.\n\n",
                .{ms.cli.path_max},
            ),
```

and change the `UnknownTouch` message to `"--touch must be probes, always, script or motion.\n\n"`.

11. Change `Status.observe` to take `z_a: f32`, `z_bc: f32` and `state: ms.touch.State` in place of `ecg_a` / `ecg_bc`, and print:

```zig
        std.debug.print("t={d:.0}s a0={d} a1={d} z0={d:.1} z1={d:.1} {s} touch={s}\n", .{
            audio_s, raw_a, raw_bc, z_a, z_bc, @tagName(state), &touch,
        });
```

keeping `raw_a` / `raw_bc` as parameters too. Update the `Status` doc comment: `z0` and `z1` are how many deviations from its own rest each probe is reading, and `--touch-level` is the line they are being held against.

In `src/root.zig`:

12. Delete `pub const trigger = @import("trigger.zig");` and `_ = trigger;`.

13. `git rm src/trigger.zig`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

Then check the binary starts and says something sensible with no hardware:

Run: `nix develop -c zig build run -- --touch=script`
Expected: fifteen seconds of audio, status lines showing `z0` and `z1` near zero and a state name.

Run: `nix develop -c zig build run -- --trigger=25000`
Expected: the retirement message and the usage, exit without playing.

- [ ] **Step 5: Commit**

```bash
git add -A src/cli.zig src/main.zig src/root.zig src/trigger.zig
git commit -m "feat(cli): replace --trigger with the touch state machine"
```

---

### Task 9: The CSV log

**Files:**
- Create: `src/touchlog.zig`
- Modify: `src/root.zig`
- Modify: `src/main.zig`
- Test: `src/touchlog.zig`

**Interfaces:**
- Consumes: `touch.Machine`, `touch.State`, `cli.Options.logPath`.
- Produces: `pub const Log = struct { pub fn create(io: std.Io, path: []const u8) !Log; pub fn row(self: *Log, io: std.Io, t_s: f64, raw_a: i16, a: *const touch.Detector, raw_bc: i16, bc: *const touch.Detector, state: touch.State) void; pub fn flush(self: *Log, io: std.Io) void; pub fn close(self: *Log, io: std.Io) void; }`, `pub const header`.

- [ ] **Step 1: Write the failing test**

Create `src/touchlog.zig` with only the doc comment, imports and this test:

```zig
const testing = std.testing;

test "a row carries every number the decision was made from" {
    var buf: [512]u8 = undefined;
    var m = touch.Machine.init(.{ .sample_rate = 44100, .poll_frames = 128 });
    for (0..344 * 10) |_| _ = m.update(-2049, 900);

    const line = format(&buf, 1.5, -2049, &m.a, 900, &m.bc, .none);

    // The columns the header promises, in the order it promises them.
    var cols = std.mem.splitScalar(u8, std.mem.trimRight(u8, line, "\n"), ',');
    var n: usize = 0;
    while (cols.next()) |_| n += 1;
    var head = std.mem.splitScalar(u8, std.mem.trimRight(u8, header, "\n"), ',');
    var head_n: usize = 0;
    while (head.next()) |_| head_n += 1;
    try testing.expectEqual(head_n, n);

    try testing.expect(std.mem.startsWith(u8, line, "1.500,-2049,"));
    try testing.expect(std.mem.endsWith(u8, line, ",none\n"));
}

test "the header names fourteen columns" {
    var head = std.mem.splitScalar(u8, std.mem.trimRight(u8, header, "\n"), ',');
    var n: usize = 0;
    while (head.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 14), n);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix develop -c zig build test`
Expected: FAIL, `use of undeclared identifier 'format'`.

- [ ] **Step 3: Write the implementation**

Write `src/touchlog.zig`:

```zig
//! The per-poll record of why the machine decided what it did.
//!
//! A threshold that fires in an empty room, or refuses to fire on a hand, is
//! almost impossible to diagnose by standing next to it: the status line prints
//! once a second and the decision is made three hundred times in that second.
//! So every poll's numbers go to a file, and a wrong answer is replayed at a
//! desk instead of re-touched in the gallery.
//!
//! Formatting is separated from writing so the columns can be tested without a
//! filesystem.

const std = @import("std");
const touch = @import("touch.zig");

/// Enough for a poll's worth of columns, with room for the widest float.
const row_max = 256;

/// How much is held before it goes to the file. One block is four polls, so
/// this is a few hundred blocks: the disk is touched rarely and a crash loses
/// under a second.
const buffer_bytes = 64 * 1024;

pub const header =
    "t_s,raw_a,mean_a,base_a,mad_a,z_a,on_a,raw_bc,mean_bc,base_bc,mad_bc,z_bc,on_bc,state\n";

/// One row into `buf`, returned as the slice actually written.
pub fn format(
    buf: []u8,
    t_s: f64,
    raw_a: i16,
    a: *const touch.Detector,
    raw_bc: i16,
    bc: *const touch.Detector,
    state: touch.State,
) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{d:.3},{d},{d},{d},{d:.1},{d:.2},{d},{d},{d},{d},{d:.1},{d:.2},{d},{s}\n",
        .{
            t_s,
            raw_a,        a.last_mean,  a.base(),  a.baseline.mad,  a.z,  @intFromBool(a.on),
            raw_bc,       bc.last_mean, bc.base(), bc.baseline.mad, bc.z, @intFromBool(bc.on),
            @tagName(state),
        },
    ) catch buf[0..0];
}

/// The file, and what has not reached it yet.
pub const Log = struct {
    file: std.Io.File,
    buf: [buffer_bytes]u8,
    len: usize,

    pub fn create(io: std.Io, path: []const u8) !Log {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        var log: Log = .{ .file = file, .buf = undefined, .len = 0 };
        @memcpy(log.buf[0..header.len], header);
        log.len = header.len;
        return log;
    }

    /// Add one poll. A failure here is dropped rather than reported: a full
    /// disk should cost the recording, never the installation's sound.
    pub fn row(
        self: *Log,
        io: std.Io,
        t_s: f64,
        raw_a: i16,
        a: *const touch.Detector,
        raw_bc: i16,
        bc: *const touch.Detector,
        state: touch.State,
    ) void {
        if (self.len + row_max > self.buf.len) self.flush(io);
        const written = format(self.buf[self.len..], t_s, raw_a, a, raw_bc, bc, state);
        self.len += written.len;
    }

    pub fn flush(self: *Log, io: std.Io) void {
        if (self.len == 0) return;
        self.file.writeStreamingAll(io, self.buf[0..self.len]) catch {};
        self.len = 0;
    }

    pub fn close(self: *Log, io: std.Io) void {
        self.flush(io);
        self.file.close(io);
    }
};
```

Check `createFile`'s exact 0.16 spelling against `library.zig:51`, which opens a directory the same way; if the signature differs, follow what compiles rather than what is written here.

In `src/root.zig`: add `pub const touchlog = @import("touchlog.zig");` and `_ = touchlog;`.

In `src/main.zig`, after the machine is built:

```zig
    // Opened once, so a bad path is a startup failure rather than something
    // discovered an hour into a recording.
    var log: ?ms.touchlog.Log = if (opts.logPath()) |path|
        ms.touchlog.Log.create(io, path) catch |err| blk: {
            std.debug.print("could not write {s}: {s}\n", .{ path, @errorName(err) });
            break :blk null;
        }
    else
        null;
    defer if (log) |*l| l.close(io);
```

and inside the poll loop, after `state` is computed:

```zig
            if (log) |*l| {
                const t_s = @as(f64, @floatFromInt(rendered + offset)) /
                    @as(f64, @floatFromInt(ms.sample_rate));
                l.row(io, t_s, raw_a, &machine.a, raw_bc, &machine.bc, state);
            }
```

and after the block is written to the sink:

```zig
        if (log) |*l| l.flush(io);
```

Add `--log-touch=PATH` to `usage` in `cli.zig`, saying what the columns are for and that it writes about 20 MB per fifteen minutes.

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

Then produce a real file:

Run: `nix develop -c zig build run -- --touch=script --log-touch=/tmp/touch.csv && head -3 /tmp/touch.csv && wc -l /tmp/touch.csv`
Expected: a header row, data rows, and roughly 344 rows per second of audio.

- [ ] **Step 5: Commit**

```bash
git add src/touchlog.zig src/root.zig src/main.zig src/cli.zig
git commit -m "feat(touchlog): write per-poll detection numbers to CSV"
```

---

## After the plan

Two things this plan deliberately does not do, both needing the rig rather than the keyboard:

1. **Confirm `--touch-level = 6` against a live session.** Run with `--log-touch`, touch each plant several times, and check from the CSV that `z_a` and `z_bc` during a touch clear 6 by a comfortable margin and that idle never approaches it. The number is derived from a 96-row capture; it wants a longer one.
2. **Confirm that `both` is reachable on real hardware.** The `both` state needs a touch on BC to clear six deviations measured from the crosstalk floor A put it on. In simulation BC's idle noise is independent per poll, so the 200 ms mean smooths it and the margin is large; real noise is correlated and the margin will be smaller. From a live CSV, touch A and then also touch B, and read `z_bc` for those polls. If it sits under 6, the honest fix is a longer `--touch-average`, which smooths BC's idle more and shrinks its MAD — not a lower `--touch-level`, which would loosen both probes everywhere.
3. **Confirm `--touch-baseline = 60` against real visitors.** If people hold a plant longer than about fifteen seconds, raise it — the failure mode is a touch that goes quiet while the hand is still there.
