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
