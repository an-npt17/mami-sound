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
    var b = testBaseline(70.0);
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
