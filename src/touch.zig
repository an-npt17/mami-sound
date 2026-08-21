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
