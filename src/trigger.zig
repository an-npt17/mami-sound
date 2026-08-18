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

/// `hold_ms` expressed in polls. At least one, so a hold of zero still means
/// "one poll decides" rather than "nothing ever decides".
pub fn holdPolls(hold_ms: f32, sample_rate: u32, poll_frames: usize) u32 {
    const polls_per_s = @as(f32, @floatFromInt(sample_rate)) /
        @as(f32, @floatFromInt(poll_frames));
    const polls = @round(hold_ms / 1000.0 * polls_per_s);
    if (!(polls >= 1.0)) return 1;
    return @intFromFloat(polls);
}

pub const Trigger = struct {
    level: i16,
    /// Polls of agreement needed to change the answer. The counter's full
    /// travel, so it is also how long a spike train has to keep up to win.
    hold: u32,
    /// Where the counter sits between 0 and `hold`.
    count: u32,
    /// The debounced answer. Held between the ends of the counter's travel,
    /// which is what stops a reading hovering on the line from chattering.
    on: bool,

    pub fn init(level: i16, hold: u32) Trigger {
        return .{
            .level = level,
            .hold = @max(hold, 1),
            .count = 0,
            .on = false,
        };
    }

    /// Feed one poll's reading and get the debounced touch.
    pub fn update(self: *Trigger, reading: i16) bool {
        if (reading >= self.level) {
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

test "a single spike never counts as a touch" {
    var t = Trigger.init(25000, 35);
    // The shape of a probe sitting near ground: mostly nothing, the odd spike.
    for (0..500) |i| {
        const reading: i16 = if (i % 50 == 0) 30000 else 0;
        try testing.expect(!t.update(reading));
    }
}

test "a sustained crossing turns it on, after the hold and not before" {
    var t = Trigger.init(25000, 35);
    for (0..34) |_| try testing.expect(!t.update(30000));
    // The 35th poll is the one that decides: 35 polls is ~100 ms.
    try testing.expect(t.update(30000));
}

test "it stays on through a dip and releases only at the bottom" {
    var t = Trigger.init(25000, 10);
    for (0..10) |_| _ = t.update(30000);
    try testing.expect(t.on);

    // Nine polls under: the counter falls to 1 but the answer is held.
    for (0..9) |_| try testing.expect(t.update(0));
    // The tenth empties it.
    try testing.expect(!t.update(0));
}

test "a reading hovering on the line does not chatter" {
    var t = Trigger.init(25000, 10);
    for (0..10) |_| _ = t.update(30000);

    // Alternating either side of the threshold: the counter walks up and down
    // in the middle of its travel and never reaches an end, so the answer that
    // was reached last stands.
    for (0..100) |i| {
        const reading: i16 = if (i % 2 == 0) 24999 else 25001;
        try testing.expect(t.update(reading));
    }
}

test "a touch has to be over the line more often than under it" {
    var t = Trigger.init(25000, 35);
    // One poll in three: climbs one, falls two. Never arrives, which is the
    // point — that is a threshold set for a signal's peaks, not its level.
    for (0..3000) |i| {
        const reading: i16 = if (i % 3 == 0) 30000 else 0;
        try testing.expect(!t.update(reading));
    }
    // Two in three: climbs two, falls one, and gets there.
    var s = Trigger.init(25000, 35);
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
