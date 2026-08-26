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

/// How long a clip is protected from the next touch.
///
/// A hand on plant B while a clip is running is somebody enjoying it or
/// somebody brushing past, and neither is a request to hear the first four
/// seconds of something else. Ten seconds is long enough that the clip has
/// established itself and short enough that a room which has heard enough can
/// move it on.
///
/// Counted from the clip starting, and only while it is still sounding: a stem
/// that has already finished its four seconds answers the next touch at once
/// rather than sulking for another six.
pub const open_after_s: f32 = 10.0;

/// Which clip a touch on plant B starts, and whether a touch starts one at all.
pub const ClipSelector = struct {
    /// Which folder each clip came from, by index into the pool. The pool is
    /// flat -- one list of paths -- so this is what is left of the fact that it
    /// was built from two directories.
    folders: []const u8,
    random: std.Random,
    previous_touch: bool,
    /// The folder the clip now playing was drawn from, so the next one can be
    /// drawn from the other. `null` before anything has played.
    last_folder: ?u8,
    /// Frames since the last clip was started, and how many make ten seconds.
    frames_since_start: u64,
    open_frames: u64,

    pub fn init(folders: []const u8, sample_rate: u32, random: std.Random) ClipSelector {
        return .{
            .folders = folders,
            .random = random,
            .previous_touch = false,
            .last_folder = null,
            .frames_since_start = 0,
            .open_frames = @intFromFloat(open_after_s * @as(f32, @floatFromInt(sample_rate))),
        };
    }

    /// One poll's answer: the clip to start, or nothing.
    ///
    /// `sounding` is whether plant B is still playing; `frames` is how much
    /// audio this poll covers.
    pub fn start(
        self: *ClipSelector,
        touched: bool,
        sounding: bool,
        frames: usize,
    ) ?usize {
        self.frames_since_start +|= frames;

        const rising = touched and !self.previous_touch;
        self.previous_touch = touched;
        if (!rising or self.folders.len == 0) return null;

        // A clip still inside its ten seconds is left alone. This is the whole
        // of the fix for a plant that answered every stray edge with the first
        // second of a new recording.
        if (sounding and self.frames_since_start < self.open_frames) return null;

        const index = self.pick();
        self.last_folder = self.folders[index];
        self.frames_since_start = 0;
        return index;
    }

    /// A clip from whichever folder the last one did not come from.
    ///
    /// A pool built from one folder -- either stem pool -- has no other folder
    /// to go to, so it draws from the whole pool as it always did.
    fn pick(self: *ClipSelector) usize {
        const wanted = self.countOther();
        if (wanted == 0) return self.random.uintLessThan(usize, self.folders.len);

        var remaining = self.random.uintLessThan(usize, wanted);
        for (self.folders, 0..) |folder, index| {
            if (self.last_folder) |last| if (folder == last) continue;
            if (remaining == 0) return index;
            remaining -= 1;
        }
        unreachable;
    }

    fn countOther(self: *const ClipSelector) usize {
        const last = self.last_folder orelse return self.folders.len;
        var count: usize = 0;
        for (self.folders) |folder| {
            if (folder != last) count += 1;
        }
        return count;
    }
};

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

/// A pool shaped like the recordings: two folders read as one flat list.
const two_folders = [_]u8{ 0, 0, 0, 1, 1, 1 };

/// The poll the engine runs the selector at, and how many of them a second is.
const poll_frames: usize = 128;
const polls_per_s: usize = 44100 / poll_frames;

fn testSelector(folders: []const u8, seed: u64) ClipSelector {
    const State = struct {
        var prng: std.Random.DefaultPrng = undefined;
    };
    State.prng = .init(seed);
    return ClipSelector.init(folders, 44100, State.prng.random());
}

test "a touch starts a clip when plant B is silent" {
    var selector = testSelector(&two_folders, 1);
    try std.testing.expect(selector.start(false, false, poll_frames) == null);
    try std.testing.expect(selector.start(true, false, poll_frames) != null);
}

test "a touch inside the clip's ten seconds is ignored" {
    var selector = testSelector(&two_folders, 1);
    try std.testing.expect(selector.start(true, false, poll_frames) != null);

    // Nine seconds of somebody leaning on the plant, touching it over and over.
    // The clip must survive every one of those edges.
    for (0..9 * polls_per_s) |poll| {
        const touched = poll % 2 == 0;
        try std.testing.expect(selector.start(touched, true, poll_frames) == null);
    }
}

test "a touch past the ten seconds cuts in" {
    var selector = testSelector(&two_folders, 1);
    _ = selector.start(true, false, poll_frames);

    for (0..11 * polls_per_s) |_| {
        try std.testing.expect(selector.start(false, true, poll_frames) == null);
    }
    try std.testing.expect(selector.start(true, true, poll_frames) != null);
}

test "a clip that has already finished answers the next touch at once" {
    // What keeps a four-second stem responsive: the ten seconds only protect a
    // clip that is still sounding.
    var selector = testSelector(&two_folders, 1);
    _ = selector.start(true, false, poll_frames);
    _ = selector.start(false, false, poll_frames);
    try std.testing.expect(selector.start(true, false, poll_frames) != null);
}

test "consecutive clips come from alternating folders" {
    var selector = testSelector(&two_folders, 7);
    var previous: ?u8 = null;
    for (0..8) |_| {
        const index = selector.start(true, false, poll_frames).?;
        const folder = two_folders[index];
        if (previous) |last| try std.testing.expect(folder != last);
        previous = folder;
        _ = selector.start(false, false, poll_frames);
    }
}

test "a pool built from one folder still draws from all of it" {
    // Either stem pool. There is no other folder to alternate with, and the
    // plant must not fall silent for want of one.
    const one_folder = [_]u8{ 0, 0, 0, 0 };
    var selector = testSelector(&one_folder, 3);
    for (0..8) |_| {
        try std.testing.expect(selector.start(true, false, poll_frames) != null);
        _ = selector.start(false, false, poll_frames);
    }
}
