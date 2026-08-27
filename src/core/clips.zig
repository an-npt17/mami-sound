const std = @import("std");
const source_mod = @import("source.zig");

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

    /// The allowance a source asks for, or the one the room asked for instead.
    ///
    /// `seconds` of zero means play to the clip's own end. It is the only way
    /// to uncap a capped source from the command line, and the reason this
    /// takes an optional rather than a plain float: absent is "use the
    /// source's own", zero is "use none".
    pub fn forSource(
        source: source_mod.Source,
        seconds: ?f32,
        sample_rate: u32,
    ) Limit {
        const chosen = seconds orelse source.defaultSeconds() orelse return .unlimited;
        if (chosen <= 0.0) return .unlimited;

        const sr: f32 = @floatFromInt(sample_rate);
        const total = @max(chosen * sr, 1.0);
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

/// Which clip a touch starts, and whether a touch starts one at all.
///
/// Serves either plant: nothing here knows which one it is working for.
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
    /// And which clip it was, so a pool with only one folder still answers a
    /// touch with something new. `null` before anything has played.
    last_index: ?usize,
    /// Frames since the last clip was started, and how many make ten seconds.
    frames_since_start: u64,
    open_frames: u64,

    pub fn init(
        folders: []const u8,
        retrigger_s: f32,
        sample_rate: u32,
        random: std.Random,
    ) ClipSelector {
        return .{
            .folders = folders,
            .random = random,
            .previous_touch = false,
            .last_folder = null,
            .last_index = null,
            .frames_since_start = 0,
            .open_frames = @intFromFloat(retrigger_s * @as(f32, @floatFromInt(sample_rate))),
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
        self.last_index = index;
        self.frames_since_start = 0;
        return index;
    }

    /// A clip from whichever folder the last one did not come from.
    ///
    /// A pool built from one folder -- either stem pool -- has no other folder
    /// to go to, so it draws from the whole pool as it always did.
    /// A clip that is not the one just playing.
    ///
    /// The recordings are two folders read as one, so the rule there is the
    /// folder: the next clip comes from whichever the last one did not, and a
    /// different folder is necessarily a different clip. Every other source is
    /// one folder and has no other to go to, so the rule falls back to the clip
    /// itself -- without which a touch would restart the same bell about one
    /// time in four, which is a room hearing the plant fail to answer.
    fn pick(self: *ClipSelector) usize {
        const other_folder = self.countOther();
        if (other_folder > 0) return self.nth(other_folder, .folder);

        const choices = self.countUnplayed();
        return self.nth(choices, .clip);
    }

    /// Which of the two rules is deciding what counts as a candidate.
    const Rule = enum { folder, clip };

    fn eligible(self: *const ClipSelector, index: usize, rule: Rule) bool {
        return switch (rule) {
            .folder => if (self.last_folder) |last| self.folders[index] != last else true,
            // A pool of one has to answer a touch with the clip it has, however
            // lately it played. Said here rather than at the counting, because a
            // count and a predicate that disagree walk off the end of the pool.
            .clip => if (self.folders.len <= 1)
                true
            else if (self.last_index) |last| index != last else true,
        };
    }

    /// The `wanted`-th eligible clip, counting from a fresh draw.
    fn nth(self: *ClipSelector, choices: usize, rule: Rule) usize {
        var remaining = self.random.uintLessThan(usize, choices);
        for (0..self.folders.len) |index| {
            if (!self.eligible(index, rule)) continue;
            if (remaining == 0) return index;
            remaining -= 1;
        }
        unreachable;
    }

    /// How many clips are not the one just playing.
    fn countUnplayed(self: *const ClipSelector) usize {
        var count: usize = 0;
        for (0..self.folders.len) |index| {
            if (self.eligible(index, .clip)) count += 1;
        }
        return count;
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

test "the recordings spend an allowance that never runs out" {
    var limit: Limit = .forSource(.recordings, null, 44100);
    var samples = [_]f32{ 1.0, 1.0, 1.0, 1.0 };

    try std.testing.expectEqual(@as(usize, 4), limit.take(&samples));
    // Untouched: an uncapped clip is never faded, so nothing here is a gain
    // stage the interviews have to pay for.
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 1.0, 1.0, 1.0 }, &samples);
    try std.testing.expect(!limit.finished());
}

test "a stem pool's allowance is four seconds of samples" {
    const limit: Limit = .forSource(.bell, null, 44100);
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
    return ClipSelector.init(folders, 10.0, 44100, State.prng.random());
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

test "a bird call is capped at five seconds with a fade" {
    const limit: Limit = .forSource(.daybird, null, 44100);
    try std.testing.expectEqual(@as(usize, 5 * 44100), limit.total);
    try std.testing.expect(limit.fade > 0);
}

test "a source's own length becomes its limit" {
    const capped: Limit = .forSource(.bell, null, 44100);
    try std.testing.expectEqual(@as(usize, 4 * 44100), capped.total);
    try std.testing.expect(capped.fade > 0);

    const uncapped: Limit = .forSource(.tradvn, null, 44100);
    try std.testing.expectEqual(Limit.unlimited.total, uncapped.total);
}

test "an override replaces the source's length" {
    const longer: Limit = .forSource(.bell, 12.0, 44100);
    try std.testing.expectEqual(@as(usize, 12 * 44100), longer.total);

    // Zero is how a capped source is uncapped from the command line.
    const uncapped: Limit = .forSource(.bell, 0.0, 44100);
    try std.testing.expectEqual(Limit.unlimited.total, uncapped.total);

    // And how a source that runs to its end is capped.
    const capped: Limit = .forSource(.recordings, 30.0, 44100);
    try std.testing.expectEqual(@as(usize, 30 * 44100), capped.total);
}

test "the guard length reaches the selector" {
    var prng = std.Random.DefaultPrng.init(1);
    const folders = [_]u8{ 0, 0 };
    const selector = ClipSelector.init(&folders, 5.0, 44100, prng.random());
    try std.testing.expectEqual(@as(u64, 5 * 44100), selector.open_frames);
}

/// How a plant answers a hand.
///
/// `trigger` is a doorbell: a touch starts a clip and the clip runs its own
/// length whether the hand stays or not. `hold` is a tap: the clip sounds while
/// somebody is holding the plant and falls silent when they let go, and the
/// next hold picks it up where it stopped.
pub const Mode = enum { trigger, hold };

/// How long a held clip takes to fade in or out, in seconds.
///
/// Short enough that letting go feels immediate, long enough that the cut is
/// heard as the sound stopping rather than as a click through a PA. The same
/// number both ways: a fade-in that outran its fade-out would click on a quick
/// re-grip, which is the gesture a room does most.
pub const hold_fade_s: f32 = 0.04;

test "a touch never restarts the clip that was just playing" {
    // Alternating folders guarantees a different clip for the recordings, which
    // are two folders read as one. Every other source is one folder, so there
    // is no other folder to go to and the only thing standing between a touch
    // and hearing the same bell again is this.
    const one_folder = [_]u8{ 0, 0, 0, 0 };
    var selector = testSelector(&one_folder, 11);

    var previous: ?usize = null;
    for (0..60) |_| {
        const index = selector.start(true, false, poll_frames).?;
        if (previous) |last| try std.testing.expect(index != last);
        previous = index;
        _ = selector.start(false, false, poll_frames);
    }
}

test "a pool of one clip has nothing else to offer and says so" {
    // The edge the rule above must not turn into a hang or an unreachable: one
    // clip, and a touch has to be answered with it.
    const single = [_]u8{0};
    var selector = testSelector(&single, 3);
    for (0..4) |_| {
        try std.testing.expectEqual(@as(usize, 0), selector.start(true, false, poll_frames).?);
        _ = selector.start(false, false, poll_frames);
    }
}
