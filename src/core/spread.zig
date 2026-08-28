//! How tightly a probe's recent readings cluster.
//!
//! What the `steady` model is built on, and the second answer it has had. The
//! first asked whether a reading had moved less than a jitter allowance from
//! the one before it, inside a band the level was expected to fall in. Neither
//! half of that question survives this rig. A held probe drops out: it reads its clamped level for a few polls, throws a
//! rail or a zero, and comes straight back. Judged on consecutive readings
//! every dropout is a move, and since losing stillness restarts the run, a
//! probe that is genuinely being held never accumulates enough of one.
//!
//! So the question is asked of a window instead, and asked in a way a handful
//! of bad readings cannot answer: the range from the tenth percentile to the
//! ninetieth. A hand holding the probe anywhere at all gives a small range
//! whatever the level, and a probe left alone -- flipping between a rail and a
//! zero -- gives a range of thousands. A fifth of the window at each end can be
//! garbage without moving the answer at all, which is the margin this rig needs
//! and the reason the range is taken between percentiles rather than between
//! the minimum and the maximum. Past that fifth the junk does move it, and a
//! test says so: the tolerance is exactly the margin the percentiles leave, not
//! an unlimited immunity.
//!
//! Nothing here looks at the level, so nothing here has to be told what the
//! level will be. That is what retires the band: the two probes clamp to quite
//! different values, neither is predictable from one day to the next, and a
//! band that has to be told the answer in advance is a setting nobody in the
//! room can get right.

const std = @import("std");

/// The longest window worth keeping, about three seconds of polls.
pub const max_polls = 1024;

/// How often the percentiles are recomputed, in hertz.
///
/// The window has to be sorted to be asked, which is work proportional to its
/// length, and a spread measured over a second does not change meaningfully
/// between one poll and the next. Twenty times a second is far finer than the
/// hold that follows it and a fraction of the cost of doing it every poll.
const recompute_hz: f32 = 20.0;

/// Where the range is taken from. A fifth at each end is what buys the
/// tolerance for dropouts, and it is measured rather than picked: on the
/// capture in `touch.csv`, moving from a tenth to a fifth lifts the share of
/// windows that read as held from 24% to 27% on probe BC while the ambiguous
/// band between the two thresholds stays near one percent. A quarter is worse
/// -- the ambiguous band opens to three percent, which is separation being
/// traded away for tolerance that is no longer needed.
const low_percentile: u32 = 20;
const high_percentile: u32 = 80;

pub const Spread = struct {
    window: [max_polls]i16,
    /// The window, in polls.
    len: u32,
    /// How many readings have arrived, up to `len`.
    count: u32,
    head: u32,
    /// Polls between recomputes, and how many have passed.
    decim: u32,
    since: u32,
    /// The last computed range, held between recomputes.
    range: i16,
    /// The median over the same window: what the probe is sitting at, for the
    /// pitch. A median rather than a mean because an average of a clamped level
    /// and a rail is a number that was never read.
    level: i16,
    /// The band a room has said a held probe sits in, and the share of the
    /// window that is inside it. Nought where nobody has said.
    ///
    /// Counted rather than inferred from the percentiles: a room that knows
    /// where a hand puts the probe is asking a plain question -- how much of
    /// the last second was there -- and the answer survives a rig that throws
    /// rails through a perfectly good touch, which a median and a spread only
    /// survive up to the margin they leave.
    band_lo: ?i16,
    band_hi: ?i16,
    inside: f32,

    pub fn init(window_ms: f32, sample_rate: u32, poll_frames: usize) Spread {
        const polls_per_s = @as(f32, @floatFromInt(sample_rate)) /
            @as(f32, @floatFromInt(poll_frames));
        const polls = @round(window_ms / 1000.0 * polls_per_s);
        const len: u32 = if (polls >= 1.0) @intFromFloat(polls) else 1;
        const decim = @round(polls_per_s / recompute_hz);
        return .{
            .window = undefined,
            .len = std.math.clamp(len, 1, max_polls),
            .count = 0,
            .head = 0,
            .decim = if (decim >= 1.0) @intFromFloat(decim) else 1,
            .since = 0,
            .range = std.math.maxInt(i16),
            .level = 0,
            .band_lo = null,
            .band_hi = null,
            .inside = 0.0,
        };
    }

    /// Say where a held probe sits, so the share inside it can be counted.
    pub fn watch(self: *Spread, lo: ?i16, hi: ?i16) void {
        self.band_lo = lo;
        self.band_hi = hi;
    }

    /// Whether the window has enough behind it to be worth asking.
    ///
    /// The whole window, not half of it: a range taken over a part-filled
    /// window is a range over less time than was asked for, which reads as
    /// quieter than the truth and would latch a touch at power-on.
    pub fn ready(self: *const Spread) bool {
        return self.count == self.len;
    }

    /// Add one poll's reading, recomputing the range on schedule.
    pub fn push(self: *Spread, raw: i16) void {
        self.window[self.head] = raw;
        self.head = (self.head + 1) % self.len;
        if (self.count < self.len) self.count += 1;

        self.since += 1;
        if (self.since < self.decim and self.count == self.len) return;
        self.since = 0;
        self.recompute();
    }

    fn recompute(self: *Spread) void {
        var scratch: [max_polls]i16 = undefined;
        const n = self.count;
        @memcpy(scratch[0..n], self.window[0..n]);
        std.mem.sort(i16, scratch[0..n], {}, std.sort.asc(i16));

        const lo = scratch[n * low_percentile / 100];
        const hi = scratch[@min(n * high_percentile / 100, n - 1)];
        const delta = @as(i32, hi) - @as(i32, lo);
        self.range = @intCast(@min(delta, std.math.maxInt(i16)));
        self.level = scratch[n / 2];

        // Counted in the same pass the sort was for, so asking costs nothing
        // extra on the audio thread.
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
    }
};

test "a probe held at one level has no spread at all" {
    var spread: Spread = .init(1000.0, 44100, 128);
    for (0..spread.len) |_| spread.push(663);
    try std.testing.expect(spread.ready());
    try std.testing.expectEqual(@as(i16, 0), spread.range);
    try std.testing.expectEqual(@as(i16, 663), spread.level);
}

test "a probe flipping between a rail and a zero spreads across the range" {
    var spread: Spread = .init(1000.0, 44100, 128);
    for (0..spread.len) |i| spread.push(if (i % 2 == 0) -4096 else 1);
    try std.testing.expect(spread.range > 4000);
}

test "junk inside the percentile margin does not move the answer" {
    // What a held probe on this rig looks like: mostly its clamped level, with
    // rails and zeros thrown through it. The consecutive-jitter test calls
    // every one of those a move; this must not.
    var spread: Spread = .init(1000.0, 44100, 128);
    const junk = spread.len / 10; // a tenth at each end, inside the margin
    for (0..spread.len) |i| spread.push(if (i < junk)
        -4096
    else if (i < 2 * junk)
        2047
    else
        663);

    try std.testing.expect(spread.ready());
    try std.testing.expectEqual(@as(i16, 0), spread.range);
    try std.testing.expectEqual(@as(i16, 663), spread.level);
}

test "junk past the percentile margin opens the range up" {
    // The tolerance is exactly the margin the percentiles leave, and it is
    // worth a test saying so: a quarter of the window at one end is past a
    // tenth, and the range must show it rather than quietly absorb it.
    var spread: Spread = .init(1000.0, 44100, 128);
    const junk = spread.len / 4;
    for (0..spread.len) |i| spread.push(if (i < junk) -4096 else 663);

    try std.testing.expect(spread.range > 4000);
}

test "the window is not judged until it is full" {
    var spread: Spread = .init(1000.0, 44100, 128);
    for (0..spread.len - 1) |_| spread.push(663);
    try std.testing.expect(!spread.ready());
    spread.push(663);
    try std.testing.expect(spread.ready());
}

test "a window that has moved on forgets what it held before" {
    var spread: Spread = .init(1000.0, 44100, 128);
    for (0..spread.len) |i| spread.push(if (i % 2 == 0) -4096 else 1);
    try std.testing.expect(spread.range > 4000);
    // A hand arrives and the probe clamps. Once the flailing has left the
    // window entirely, nothing of it may remain in the answer.
    for (0..spread.len) |_| spread.push(650);
    try std.testing.expectEqual(@as(i16, 0), spread.range);
}

test "the share inside a band is what a room can count" {
    var spread: Spread = .init(1000.0, 44100, 128);
    spread.watch(650, 660);

    // Four readings in five inside the band, the fifth a rail: what a held
    // probe on this rig looks like.
    for (0..spread.len) |i| spread.push(if (i % 5 == 4) -4096 else 655);
    try std.testing.expect(spread.ready());
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), spread.inside, 0.02);
}

test "a probe that never enters the band shares none of it" {
    var spread: Spread = .init(1000.0, 44100, 128);
    spread.watch(650, 660);

    for (0..spread.len) |i| spread.push(if (i % 3 == 0) 0 else 1);
    try std.testing.expectEqual(@as(f32, 0.0), spread.inside);
}

test "a probe wandering across the band is only sometimes in it" {
    var spread: Spread = .init(1000.0, 44100, 128);
    spread.watch(650, 660);

    // Half the readings land inside, half a long way out.
    for (0..spread.len) |i| spread.push(if (i % 2 == 0) 655 else 3000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), spread.inside, 0.02);
}

test "with no band nothing is inside one" {
    var spread: Spread = .init(1000.0, 44100, 128);
    for (0..spread.len) |_| spread.push(655);
    try std.testing.expectEqual(@as(f32, 0.0), spread.inside);
}

