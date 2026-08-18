//! Turning a noisy probe reading into a touch.
//!
//! Comparing a reading straight against a threshold makes every sample a vote,
//! and on a biopotential probe a single sample is worth nothing: mains hum, a
//! brushed pot or plain static will cross any line you draw for one poll. At
//! 344 polls a second that is 2.9 ms deciding whether a five-minute clip plays.
//!
//! So the crossing has to persist. A counter climbs while the reading is over
//! the threshold and falls while it is under; the touch turns on only at the
//! top of its travel and off only at the bottom. An isolated spike moves it one
//! step and decays away, while a real touch walks it all the way up.
//!
//! Note what this asks of the threshold: the counter only climbs if the reading
//! is over the line *more often than it is under it*. A probe whose signal
//! swings about ground and clears the threshold on brief peaks alone will never
//! trigger, however long it is held — the threshold is then set for the peaks
//! of a signal rather than its level, and wants an envelope in front of it
//! rather than a longer debounce.

const std = @import("std");

/// How long a crossing has to persist before it counts as a touch.
pub const default_hold_ms: f32 = 100.0;

/// How long the reading is averaged over before the threshold sees it.
pub const default_window_ms: f32 = 200.0;

/// The longest window worth averaging over, about three seconds of polls.
pub const max_window_polls = 1024;

/// `hold_ms` expressed in polls. At least one, so a hold of zero still means
/// "one poll decides" rather than "nothing ever decides".
pub fn holdPolls(hold_ms: f32, sample_rate: u32, poll_frames: usize) u32 {
    const polls_per_s = @as(f32, @floatFromInt(sample_rate)) /
        @as(f32, @floatFromInt(poll_frames));
    const polls = @round(hold_ms / 1000.0 * polls_per_s);
    if (!(polls >= 1.0)) return 1;
    return @intFromFloat(polls);
}

/// A running mean of the last `len` polls.
///
/// A true average over a window rather than a one-pole smoother: a spike's
/// contribution is then exactly one sample's worth, and it leaves the window
/// altogether once the window has passed, where a one-pole would let it decay
/// away with a long tail.
///
/// The readings have already had their negative half folded to zero by
/// `sensors.ecgFromAdc`, which makes this an envelope rather than a mean: a
/// probe swinging about ground averages to something above zero, in proportion
/// to how hard it is swinging. That is a level a threshold can be set against,
/// where the raw samples are half zeroes and half peaks.
pub const Average = struct {
    window: [max_window_polls]u16,
    /// How many polls the mean is taken over.
    len: u32,
    /// How many have arrived so far, which is what the mean divides by until
    /// the window is full. Dividing by `len` from the start would read as a
    /// long silence for the first window and hold off a touch already under
    /// way.
    count: u32,
    head: u32,
    sum: u32,

    pub fn init(window_polls: u32) Average {
        return .{
            .window = undefined,
            .len = std.math.clamp(window_polls, 1, max_window_polls),
            .count = 0,
            .head = 0,
            .sum = 0,
        };
    }

    /// Add one poll's reading and get the mean including it.
    pub fn push(self: *Average, reading: i16) i16 {
        // Negatives are folded away upstream; fold again rather than trust it,
        // since one negative would wrap the unsigned sum.
        const value: u16 = @intCast(@max(reading, 0));

        if (self.count == self.len) {
            self.sum -= self.window[self.head];
        } else {
            self.count += 1;
        }
        self.window[self.head] = value;
        self.sum += value;
        self.head = (self.head + 1) % self.len;

        return @intCast(self.sum / self.count);
    }
};

pub const Trigger = struct {
    /// What the threshold is compared against: the averaged reading, never the
    /// raw one.
    average: Average,
    level: i16,
    /// Polls of agreement needed to change the answer. The counter's full
    /// travel, so it is also how long a spike train has to keep up to win.
    hold: u32,
    /// Where the counter sits between 0 and `hold`.
    count: u32,
    /// The debounced answer. Held between the ends of the counter's travel,
    /// which is what stops a reading hovering on the line from chattering.
    on: bool,

    pub fn init(level: i16, hold: u32, window: u32) Trigger {
        return .{
            .average = .init(window),
            .level = level,
            .hold = @max(hold, 1),
            .count = 0,
            .on = false,
        };
    }

    /// Feed one poll's reading and get the debounced touch.
    pub fn update(self: *Trigger, reading: i16) bool {
        const level = self.average.push(reading);
        if (level >= self.level) {
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

const testing = std.testing;

/// A window of one poll: the average passes the reading straight through, so a
/// test can exercise the counter on its own.
const no_average: u32 = 1;

test "a single spike never counts as a touch" {
    var t = Trigger.init(25000, 35, no_average);
    // The shape of a probe sitting near ground: mostly nothing, the odd spike.
    for (0..500) |i| {
        const reading: i16 = if (i % 50 == 0) 30000 else 0;
        try testing.expect(!t.update(reading));
    }
}

test "a sustained crossing turns it on, after the hold and not before" {
    var t = Trigger.init(25000, 35, no_average);
    for (0..34) |_| try testing.expect(!t.update(30000));
    // The 35th poll is the one that decides: 35 polls is ~100 ms.
    try testing.expect(t.update(30000));
}

test "it stays on through a dip and releases only at the bottom" {
    var t = Trigger.init(25000, 10, no_average);
    for (0..10) |_| _ = t.update(30000);
    try testing.expect(t.on);

    // Nine polls under: the counter falls to 1 but the answer is held.
    for (0..9) |_| try testing.expect(t.update(0));
    // The tenth empties it.
    try testing.expect(!t.update(0));
}

test "a reading hovering on the line does not chatter" {
    var t = Trigger.init(25000, 10, no_average);
    for (0..10) |_| _ = t.update(30000);

    // Alternating either side of the threshold: the counter walks up and down
    // in the middle of its travel and never reaches an end, so the answer that
    // was reached last stands.
    for (0..100) |i| {
        const reading: i16 = if (i % 2 == 0) 24999 else 25001;
        try testing.expect(t.update(reading));
    }
}

test "what the threshold sees is the average, not the peaks" {
    // A probe that touches 30000 one poll in three averages to 10000, so a
    // threshold at 25000 is set for peaks the signal only brushes: off, which
    // is the honest answer.
    var high = Trigger.init(25000, 35, 100);
    for (0..3000) |i| {
        const reading: i16 = if (i % 3 == 0) 30000 else 0;
        try testing.expect(!high.update(reading));
    }

    // The same signal against a threshold set for its *level* does trigger.
    // Without the average this was impossible at any hold, since two polls in
    // three were under the line and the counter could never climb.
    var level = Trigger.init(8000, 35, 100);
    var fired = false;
    for (0..3000) |i| {
        const reading: i16 = if (i % 3 == 0) 30000 else 0;
        if (level.update(reading)) fired = true;
    }
    try testing.expect(fired);
}

test "the average passes a steady reading through unchanged" {
    var a = Average.init(100);
    for (0..500) |_| try testing.expectEqual(@as(i16, 8000), a.push(8000));
}

test "the average answers from the first poll, not after a full window" {
    // Dividing by the window rather than by what has arrived would read as
    // near-silence and hold off a touch already under way.
    var a = Average.init(100);
    try testing.expectEqual(@as(i16, 30000), a.push(30000));
    try testing.expectEqual(@as(i16, 20000), a.push(10000));
}

test "one spike moves the average by a bounded amount and then leaves it" {
    var a = Average.init(100);
    for (0..100) |_| _ = a.push(0);
    // Full scale for one poll in a hundred: a hundredth of the way up.
    try testing.expectEqual(@as(i16, 327), a.push(32767));
    // And once the window has passed it is gone completely, where a one-pole
    // would still be decaying.
    for (0..99) |_| _ = a.push(0);
    try testing.expectEqual(@as(i16, 0), a.push(0));
}

test "the average is an envelope: a signal about ground reads above zero" {
    var a = Average.init(100);
    var mean: i16 = 0;
    for (0..1000) |i| {
        // What `sensors.ecgFromAdc` hands over for an AC signal: the positive
        // half, with the negative half folded to zero.
        const reading: i16 = if (i % 2 == 0) 20000 else 0;
        mean = a.push(reading);
    }
    try testing.expectEqual(@as(i16, 10000), mean);
}

test "negative readings count as silence rather than wrapping the sum" {
    var a = Average.init(10);
    for (0..10) |_| _ = a.push(std.math.minInt(i16));
    try testing.expectEqual(@as(i16, 0), a.push(-1));
}

test "a window longer than the buffer is clamped rather than overrunning it" {
    var a = Average.init(holdPolls(100_000.0, 44100, 128));
    try testing.expectEqual(max_window_polls, a.len);
    for (0..2000) |_| _ = a.push(1000);
    try testing.expectEqual(@as(i16, 1000), a.push(1000));
}

test "the counter alone needs a majority of polls" {
    var t = Trigger.init(25000, 35, no_average);
    // One poll in three: climbs one, falls two. Never arrives, which is the
    // point — that is a threshold set for a signal's peaks, not its level.
    for (0..3000) |i| {
        const reading: i16 = if (i % 3 == 0) 30000 else 0;
        try testing.expect(!t.update(reading));
    }
    // Two in three: climbs two, falls one, and gets there.
    var s = Trigger.init(25000, 35, no_average);
    var fired = false;
    for (0..3000) |i| {
        const reading: i16 = if (i % 3 == 0) 0 else 30000;
        if (s.update(reading)) fired = true;
    }
    try testing.expect(fired);
}

test "the hold converts to whole polls, never to none" {
    // 100 ms at 344 polls a second.
    try testing.expectEqual(@as(u32, 34), holdPolls(100.0, 44100, 128));
    try testing.expectEqual(@as(u32, 3), holdPolls(10.0, 44100, 128));
    // Anything that would round to nothing still costs one poll.
    try testing.expectEqual(@as(u32, 1), holdPolls(0.0, 44100, 128));
    try testing.expectEqual(@as(u32, 1), holdPolls(1.0, 44100, 128));
}
