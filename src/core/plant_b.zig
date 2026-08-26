const std = @import("std");

pub const Error = error{UnknownPool};

/// Which pool of recordings a touch on plant B draws from.
///
/// The piece's own voice is the interviews and the field records, and that is
/// what runs when nobody has asked for anything else. The two stem pools are
/// for the room rather than the work: a set of short tuned notes that makes
/// what the plant is doing legible in a space where a spoken clip is not, and
/// makes the rig demonstrable without playing somebody's interview to a
/// corridor.
///
/// A pool is named, not pointed at. The folders are fixed and live beside the
/// binary, so a path on the command line would only be a way of typing one of
/// three answers wrong.
pub const Pool = enum {
    /// `interview files/` and `field records/` together, as one pool.
    recordings,
    bell,
    piano,

    pub fn parse(name: []const u8) Error!Pool {
        if (std.mem.eql(u8, name, "bell")) return .bell;
        if (std.mem.eql(u8, name, "piano")) return .piano;
        return Error.UnknownPool;
    }

    /// How long one touch plays a clip from this pool, or `null` where the
    /// clip runs to its own end.
    pub fn playSeconds(self: Pool) ?f32 {
        return switch (self) {
            .recordings => null,
            .bell, .piano => stem_play_s,
        };
    }
};

/// How long a touch plays a stem before the clip is faded out and plant B
/// falls quiet again.
///
/// The stems are single tuned notes with long tails, and a plant that answers a
/// touch with nine seconds of decaying bell reads as a machine finishing its
/// turn rather than as something that responded: by the time it ends, whoever
/// touched it has stopped listening and the room has no idea the two were
/// connected. Four seconds is the note plus enough of its tail to hear it as a
/// note, and it leaves the room quiet and waiting for the next hand.
pub const stem_play_s: f32 = 4.0;

/// The fade that ends a capped clip. Long enough that a stem still ringing at
/// the cut is not a click through a PA, short enough to be heard as the note
/// ending rather than as somebody turning a knob down.
pub const stem_fade_s: f32 = 0.15;

/// How much of a clip one touch is allowed to play, and the fade that ends it.
///
/// Counted in samples rather than clocked, so the cut lands in the same place
/// every time whatever the decoder and the audio thread are doing between them.
/// One of these is spent per clip: a touch takes a fresh copy.
pub const Limit = struct {
    /// Samples this clip may play in total.
    total: usize,
    /// How many of those at the end are the fade.
    fade: usize,
    /// How many have been taken so far.
    emitted: usize = 0,

    /// The recordings, which are not capped at all. Plant B's other job is to
    /// start an interview and let it run, and four seconds of somebody talking
    /// is not a fragment of the piece, it is a fault.
    pub const unlimited: Limit = .{ .total = std.math.maxInt(usize), .fade = 0 };

    pub fn forPool(pool: Pool, sample_rate: u32) Limit {
        const seconds = pool.playSeconds() orelse return .unlimited;
        const sr: f32 = @floatFromInt(sample_rate);
        const total = @max(seconds * sr, 1.0);
        return .{
            .total = @intFromFloat(total),
            .fade = @intFromFloat(@min(stem_fade_s * sr, total)),
        };
    }

    pub fn finished(self: *const Limit) bool {
        return self.emitted >= self.total;
    }

    /// Shape the next run of decoded samples in place and say how many of them
    /// survive. Fewer than were offered once the cut falls inside the run, and
    /// zero once the clip is over — which is the caller's cue to stop decoding.
    ///
    /// In place because the alternative is a second buffer for every read, and
    /// the samples are already the decoder's own and going nowhere else.
    pub fn take(self: *Limit, samples: []f32) usize {
        if (self.finished()) return 0;

        const count = @min(samples.len, self.total - self.emitted);
        const fade_from = self.total - self.fade;
        for (samples[0..count], 0..) |*sample, i| {
            const at = self.emitted + i;
            if (at < fade_from) continue;
            const gone: f32 = @floatFromInt(at - fade_from + 1);
            const span: f32 = @floatFromInt(self.fade);
            sample.* *= 1.0 - gone / span;
        }
        self.emitted += count;
        return count;
    }
};

pub const ClipSelector = struct {
    path_count: usize,
    random: std.Random,
    previous_touch: bool,

    pub fn init(path_count: usize, random: std.Random) ClipSelector {
        return .{
            .path_count = path_count,
            .random = random,
            .previous_touch = false,
        };
    }

    pub fn start(self: *ClipSelector, touched: bool) ?usize {
        const rising = touched and !self.previous_touch;
        self.previous_touch = touched;
        if (!rising or self.path_count == 0) return null;
        return self.random.uintLessThan(usize, self.path_count);
    }
};

test "selector emits one path request per touch edge" {
    var prng = std.Random.DefaultPrng.init(1);
    var selector = ClipSelector.init(2, prng.random());
    try std.testing.expect(selector.start(false) == null);
    try std.testing.expect(selector.start(true) != null);
    try std.testing.expect(selector.start(true) == null);
    try std.testing.expect(selector.start(false) == null);
    try std.testing.expect(selector.start(true) != null);
}

test "the named pools are the two the command line offers" {
    try std.testing.expectEqual(Pool.bell, try Pool.parse("bell"));
    try std.testing.expectEqual(Pool.piano, try Pool.parse("piano"));
    try std.testing.expectError(Error.UnknownPool, Pool.parse("Bell"));
    try std.testing.expectError(Error.UnknownPool, Pool.parse(""));
    // The recordings are what runs unasked, so there is no word for them.
    try std.testing.expectError(Error.UnknownPool, Pool.parse("recordings"));
}

test "a stem pool caps a touch, the recordings do not" {
    try std.testing.expectEqual(@as(?f32, null), Pool.recordings.playSeconds());
    try std.testing.expectEqual(@as(?f32, stem_play_s), Pool.bell.playSeconds());
    try std.testing.expectEqual(@as(?f32, stem_play_s), Pool.piano.playSeconds());
}

test "the recordings spend an allowance that never runs out" {
    var limit: Limit = .forPool(.recordings, 44100);
    var samples = [_]f32{ 1.0, 1.0, 1.0, 1.0 };

    try std.testing.expectEqual(@as(usize, 4), limit.take(&samples));
    // Untouched: an uncapped clip is never faded, so nothing here is a gain
    // stage the interviews have to pay for.
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 1.0, 1.0, 1.0 }, &samples);
    try std.testing.expect(!limit.finished());
}

test "a stem pool's allowance is four seconds of samples" {
    const limit: Limit = .forPool(.bell, 44100);
    try std.testing.expectEqual(@as(usize, 4 * 44100), limit.total);
    try std.testing.expectEqual(@as(usize, 6615), limit.fade); // 150 ms
}

test "the allowance cuts the run it falls inside and refuses the rest" {
    // Six samples' worth of clip, no fade, offered eight at a time.
    var limit: Limit = .{ .total = 6, .fade = 0 };
    var first = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    try std.testing.expectEqual(@as(usize, 4), limit.take(&first));

    var second = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    try std.testing.expectEqual(@as(usize, 2), limit.take(&second));
    try std.testing.expect(limit.finished());

    // The decoder is still producing; the clip is over. Nothing more is taken,
    // which is what tells the worker to stop reading.
    var third = [_]f32{ 1.0, 1.0 };
    try std.testing.expectEqual(@as(usize, 0), limit.take(&third));
}

test "the cut is a fade that reaches silence, and only touches the tail" {
    var limit: Limit = .{ .total = 8, .fade = 4 };
    var samples = [_]f32{ 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };
    try std.testing.expectEqual(@as(usize, 8), limit.take(&samples));

    // Everything before the fade is the clip untouched.
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 1.0, 1.0, 1.0 }, samples[0..4]);
    // And the fade walks down to actual silence rather than stopping near it,
    // which is the whole point: a stem still ringing at the cut must not click.
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), samples[4], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), samples[5], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), samples[6], 0.000001);
    try std.testing.expectEqual(@as(f32, 0.0), samples[7]);
}

test "the fade survives being split across reads" {
    // The decoder hands over whatever the pipe gave it, so the fade has to land
    // in the same place however the run boundaries fall.
    var whole: Limit = .{ .total = 8, .fade = 4 };
    var one_run = [_]f32{1.0} ** 8;
    _ = whole.take(&one_run);

    var split: Limit = .{ .total = 8, .fade = 4 };
    var runs = [_]f32{1.0} ** 8;
    _ = split.take(runs[0..3]);
    _ = split.take(runs[3..5]);
    _ = split.take(runs[5..8]);

    try std.testing.expectEqualSlices(f32, &one_run, &runs);
}
