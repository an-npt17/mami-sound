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
        mode: Mode,
        sample_rate: u32,
    ) Limit {
        // Under a hold the hand is the length, and a second answer to the same
        // question can only contradict it: a cap running out mid-hold leaves
        // the plant silent with somebody still holding it and no rising edge
        // left to ask with.
        if (mode == .hold) return .unlimited;

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
    /// How many clips the source has. Every source is one folder, so this is
    /// the whole of what a selector needs to know about it.
    clip_count: usize,
    random: std.Random,
    previous_touch: bool,
    /// Which clip is playing, so the next touch answers with a different one.
    /// `null` before anything has played.
    last_index: ?usize,
    /// Which clips this pass through the folder has already dealt. Reset when
    /// they have all been heard, so every clip plays once before any plays
    /// twice.
    dealt: [max_shuffled]bool,
    /// Frames since the last clip was started, and how many make the guard.
    frames_since_start: u64,
    open_frames: u64,
    /// Frames since the hand came off, and how many make a real departure.
    ///
    /// A clip is replaced on a rising edge, and a detector that drops out for a
    /// poll and comes back gives one. Without this a five-minute recording is
    /// swapped for another by nobody, halfway through a sentence -- which is
    /// what a room hears as the piece breaking.
    released_frames: u64,
    settled_frames: u64,

    pub fn init(
        clip_count: usize,
        retrigger_s: f32,
        sample_rate: u32,
        random: std.Random,
    ) ClipSelector {
        const settled: u64 = @intFromFloat(
            hold_release_s * @as(f32, @floatFromInt(sample_rate)),
        );
        return .{
            .clip_count = clip_count,
            .random = random,
            .previous_touch = false,
            .last_index = null,
            .dealt = [_]bool{false} ** max_shuffled,
            .frames_since_start = 0,
            .open_frames = @intFromFloat(retrigger_s * @as(f32, @floatFromInt(sample_rate))),
            // Nobody has ever been holding it, so the first hand to arrive has
            // been away long enough by definition.
            .released_frames = settled,
            .settled_frames = settled,
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

        // How long the hand had been off before this poll. Read before it is
        // cleared, because on the poll a hand returns this is the length of the
        // gap it is returning from.
        const gone_for = self.released_frames;
        if (touched) {
            self.released_frames = 0;
        } else {
            self.released_frames +|= frames;
        }

        const rising = touched and !self.previous_touch;
        self.previous_touch = touched;
        if (!rising or self.clip_count == 0) return null;

        // A hand that was only away for a moment never left: it is the same
        // visit, and the same clip carries on. Only while something is playing,
        // because a flicker with nothing to cut short cuts nothing short, and a
        // plant that has fallen quiet should answer the next hand at once.
        if (sounding and gone_for < self.settled_frames) return null;

        // A clip still inside its ten seconds is left alone. This is the whole
        // of the fix for a plant that answered every stray edge with the first
        // second of a new recording.
        if (sounding and self.frames_since_start < self.open_frames) return null;

        return self.next();
    }

    /// A clip now, whatever the guard says.
    ///
    /// What `hold` uses. There the release decides when a clip is over, and a
    /// guard counting from the clip's start would swap a recording out from
    /// under a hand that never let go.
    pub fn next(self: *ClipSelector) ?usize {
        if (self.clip_count == 0) return null;

        const index = self.pick();
        self.last_index = index;
        self.frames_since_start = 0;
        return index;
    }

    /// A clip from whichever folder the last one did not come from.
    ///
    /// A pool built from one folder -- either stem pool -- has no other folder
    /// to go to, so it draws from the whole pool as it always did.
    /// The next clip of this pass through the folder.
    ///
    /// Not repeating the last one is not enough on its own: with five clips it
    /// still allows two of them traded back and forth all evening while the
    /// other three are never heard. So the pool is dealt like a hand of cards,
    /// every clip once before any comes round again, and the clip that ended
    /// the last pass cannot start the next -- the seam is the one place a
    /// shuffle can still repeat itself, and the one place a room would notice.
    fn pick(self: *ClipSelector) usize {
        if (self.countEligible() == 0) self.reshuffle();

        const choices = self.countEligible();
        // A pool of one has to answer with what it has, however lately it
        // played, and there is nothing to deal.
        if (choices == 0) return self.last_index orelse 0;

        var remaining = self.random.uintLessThan(usize, choices);
        for (0..self.clip_count) |index| {
            if (!self.eligible(index)) continue;
            if (remaining == 0) {
                if (index < max_shuffled) self.dealt[index] = true;
                return index;
            }
            remaining -= 1;
        }
        unreachable;
    }

    /// Whether this clip may be dealt now: not already dealt this pass, and not
    /// the one that just played.
    fn eligible(self: *const ClipSelector, index: usize) bool {
        if (self.clip_count <= 1) return true;
        if (self.last_index) |last| if (index == last) return false;
        // Past the ceiling there is no shuffle, only the rule it replaced.
        if (index >= max_shuffled) return true;
        return !self.dealt[index];
    }

    fn countEligible(self: *const ClipSelector) usize {
        var count: usize = 0;
        for (0..self.clip_count) |index| {
            if (self.eligible(index)) count += 1;
        }
        return count;
    }

    /// Everything is back in the hand. The clip just played stays out of reach
    /// through `eligible`, so the new pass cannot open on it.
    fn reshuffle(self: *ClipSelector) void {
        self.dealt = [_]bool{false} ** max_shuffled;
    }
};

test "the recordings spend an allowance that never runs out" {
    var limit: Limit = .forSource(.voicebox3, null, .trigger, 44100);
    var samples = [_]f32{ 1.0, 1.0, 1.0, 1.0 };

    try std.testing.expectEqual(@as(usize, 4), limit.take(&samples));
    // Untouched: an uncapped clip is never faded, so nothing here is a gain
    // stage the interviews have to pay for.
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 1.0, 1.0, 1.0 }, &samples);
    try std.testing.expect(!limit.finished());
}

test "a stem pool's allowance is four seconds of samples" {
    const limit: Limit = .forSource(.bell, null, .trigger, 44100);
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

/// A pool with enough clips in it to have a choice.
const six_clips: usize = 6;

/// The poll the engine runs the selector at, and how many of them a second is.
const poll_frames: usize = 128;
const polls_per_s: usize = 44100 / poll_frames;

fn testSelectorGuard(clip_count: usize, retrigger_s: f32, seed: u64) ClipSelector {
    const State = struct {
        var prng: std.Random.DefaultPrng = undefined;
    };
    State.prng = .init(seed);
    return ClipSelector.init(clip_count, retrigger_s, 44100, State.prng.random());
}

fn testSelector(clip_count: usize, seed: u64) ClipSelector {
    const State = struct {
        var prng: std.Random.DefaultPrng = undefined;
    };
    State.prng = .init(seed);
    return ClipSelector.init(clip_count, 10.0, 44100, State.prng.random());
}

test "a touch starts a clip when plant B is silent" {
    var selector = testSelector(six_clips, 1);
    try std.testing.expect(selector.start(false, false, poll_frames) == null);
    try std.testing.expect(selector.start(true, false, poll_frames) != null);
}

test "a touch inside the clip's ten seconds is ignored" {
    var selector = testSelector(six_clips, 1);
    try std.testing.expect(selector.start(true, false, poll_frames) != null);

    // Nine seconds of somebody leaning on the plant, touching it over and over.
    // The clip must survive every one of those edges.
    for (0..9 * polls_per_s) |poll| {
        const touched = poll % 2 == 0;
        try std.testing.expect(selector.start(touched, true, poll_frames) == null);
    }
}

test "a touch past the ten seconds cuts in" {
    var selector = testSelector(six_clips, 1);
    _ = selector.start(true, false, poll_frames);

    for (0..11 * polls_per_s) |_| {
        try std.testing.expect(selector.start(false, true, poll_frames) == null);
    }
    try std.testing.expect(selector.start(true, true, poll_frames) != null);
}

test "a clip that has already finished answers the next touch at once" {
    // What keeps a four-second stem responsive: the ten seconds only protect a
    // clip that is still sounding.
    var selector = testSelector(six_clips, 1);
    _ = selector.start(true, false, poll_frames);
    _ = selector.start(false, false, poll_frames);
    try std.testing.expect(selector.start(true, false, poll_frames) != null);
}

test "consecutive clips are different clips" {
    var selector = testSelector(six_clips, 7);
    var previous: ?usize = null;
    for (0..40) |_| {
        const index = selector.start(true, false, poll_frames).?;
        if (previous) |last| try std.testing.expect(index != last);
        previous = index;
        _ = selector.start(false, false, poll_frames);
    }
}

test "every clip in a pool is reachable" {
    var selector = testSelector(4, 3);
    for (0..8) |_| {
        try std.testing.expect(selector.start(true, false, poll_frames) != null);
        _ = selector.start(false, false, poll_frames);
    }
}

test "a bird call is capped at five seconds with a fade" {
    const limit: Limit = .forSource(.daybird, null, .trigger, 44100);
    try std.testing.expectEqual(@as(usize, 5 * 44100), limit.total);
    try std.testing.expect(limit.fade > 0);
}

test "a source's own length becomes its limit" {
    const capped: Limit = .forSource(.bell, null, .trigger, 44100);
    try std.testing.expectEqual(@as(usize, 4 * 44100), capped.total);
    try std.testing.expect(capped.fade > 0);

    const uncapped: Limit = .forSource(.tradvn, null, .trigger, 44100);
    try std.testing.expectEqual(Limit.unlimited.total, uncapped.total);
}

test "an override replaces the source's length" {
    const longer: Limit = .forSource(.bell, 12.0, .trigger, 44100);
    try std.testing.expectEqual(@as(usize, 12 * 44100), longer.total);

    // Zero is how a capped source is uncapped from the command line.
    const uncapped: Limit = .forSource(.bell, 0.0, .trigger, 44100);
    try std.testing.expectEqual(Limit.unlimited.total, uncapped.total);

    // And how a source that runs to its end is capped.
    const capped: Limit = .forSource(.voicebox3, 30.0, .trigger, 44100);
    try std.testing.expectEqual(@as(usize, 30 * 44100), capped.total);
}

test "the guard length reaches the selector" {
    var prng = std.Random.DefaultPrng.init(1);
    const selector = ClipSelector.init(2, 5.0, 44100, prng.random());
    try std.testing.expectEqual(@as(u64, 5 * 44100), selector.open_frames);
}

/// How a plant answers a hand.
///
/// `trigger` is a doorbell: a touch starts a clip and the clip runs its own
/// length whether the hand stays or not. `hold` is a tap: the clip sounds while
/// somebody is holding the plant and falls silent when they let go, and the
/// next hold picks it up where it stopped.
pub const Mode = enum { trigger, hold };

/// The largest pool a shuffle is kept for.
///
/// A pool is dealt like a hand of cards: every clip once before any of them
/// comes round again. That wants a mark per clip, and a mark per clip wants a
/// ceiling, because the selector runs on the audio thread and cannot allocate.
/// Two hundred and fifty-six is far past any folder here -- the largest holds
/// nine -- and a pool past it falls back to not repeating the last clip, which
/// is what the shuffle replaced.
pub const max_shuffled = 256;

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
    var selector = testSelector(4, 11);

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
    var selector = testSelector(1, 3);
    for (0..4) |_| {
        try std.testing.expectEqual(@as(usize, 0), selector.start(true, false, poll_frames).?);
        _ = selector.start(false, false, poll_frames);
    }
}

/// How long a hand must be off a held plant before the clip is over.
///
/// A detector flickers: even a probe reporting a thirty-second hold on 98% of
/// its polls drops the odd one, and a gate that believed every one of those
/// would stutter under a hand that never moved. A second is far longer than any
/// flicker and far shorter than somebody deciding they have heard enough.
///
/// It is also what makes letting go mean something. Inside the second the clip
/// is the same visit and carries on; past it the clip is finished, and the next
/// hand gets a different recording rather than the one it just heard.
pub const hold_release_s: f32 = 1.0;

test "a held plant is given no allowance to run out of" {
    // The fix for a plant going quiet in somebody's hand. Under `hold` the hand
    // is the length, and a cap is a second answer to that question which can
    // only contradict it -- there is no rising edge left to ask for the next
    // clip with while the hand is still there.
    for ([_]source_mod.Source{ .insect, .daybird, .bell, .piano }) |capped| {
        const triggered: Limit = .forSource(capped, null, .trigger, 44100);
        try std.testing.expect(triggered.total != Limit.unlimited.total);

        const held: Limit = .forSource(capped, null, .hold, 44100);
        try std.testing.expectEqual(Limit.unlimited.total, held.total);
    }
}

test "a length asked for on the command line is refused a held plant too" {
    // `--plant-a-seconds=3 --plant-a-mode=hold` is two answers to one question.
    // The hold is the one the room gave last and the one it can see.
    const held: Limit = .forSource(.insect, 3.0, .hold, 44100);
    try std.testing.expectEqual(Limit.unlimited.total, held.total);
}

test "every clip plays before any plays twice" {
    // Not repeating the last one is not enough: with five clips it still allows
    // two of them traded back and forth all evening while the other three are
    // never heard. A pass through the folder is what a room hears as variety.
    const clips_in_pool: usize = 5;
    var selector = testSelector(clips_in_pool, 5);

    var seen: [clips_in_pool]bool = undefined;
    for (0..6) |pass| {
        @memset(&seen, false);
        for (0..clips_in_pool) |_| {
            const index = selector.start(true, false, poll_frames).?;
            _ = selector.start(false, false, poll_frames);
            if (seen[index]) {
                std.debug.print("pass {d} played clip {d} twice\n", .{ pass, index });
                return error.ClipRepeatedInsidePass;
            }
            seen[index] = true;
        }
    }
}

test "a pass never begins with the clip the last one ended on" {
    // The seam between passes is the one place a shuffle can still repeat
    // itself, and it is the one place a room would notice.
    const clips_in_pool: usize = 4;
    var selector = testSelector(clips_in_pool, 9);

    var previous: ?usize = null;
    for (0..40) |_| {
        const index = selector.start(true, false, poll_frames).?;
        _ = selector.start(false, false, poll_frames);
        if (previous) |last| try std.testing.expect(index != last);
        previous = index;
    }
}

test "every clip in a pool is reached, and about as often as the others" {
    const clips_in_pool: usize = 5;
    var selector = testSelector(clips_in_pool, 3);

    var counts = [_]usize{0} ** clips_in_pool;
    for (0..clips_in_pool * 40) |_| {
        counts[selector.start(true, false, poll_frames).?] += 1;
        _ = selector.start(false, false, poll_frames);
    }
    // Forty passes, so exactly forty each: a bag deals every clip once a pass.
    for (counts) |count| try std.testing.expectEqual(@as(usize, 40), count);
}

test "a flicker in the detector does not count as a new visit" {
    // What cuts an interview off mid-sentence. A clip is replaced on a rising
    // edge past the guard, and a detector that drops out for a poll and comes
    // back gives one -- so a five-minute recording is swapped for another by
    // nobody, halfway through a sentence.
    // A three-second guard, as a room that wants to be able to move a clip on
    // would set.
    var selector = testSelectorGuard(six_clips, 3.0, 4);
    try std.testing.expect(selector.start(true, false, poll_frames) != null);

    // Well past the guard, then a flicker: one poll of nothing, straight back
    // to the same hand.
    for (0..5 * polls_per_s) |_| _ = selector.start(true, true, poll_frames);
    try std.testing.expect(selector.start(false, true, poll_frames) == null);
    try std.testing.expect(selector.start(true, true, poll_frames) == null);
}

test "a hand that really left does count as a new visit" {
    // And the other half: the guard is still the thing that decides, once
    // somebody has actually let go.
    var selector = testSelectorGuard(six_clips, 3.0, 4);
    _ = selector.start(true, false, poll_frames);

    for (0..5 * polls_per_s) |_| _ = selector.start(true, true, poll_frames);
    for (0..2 * polls_per_s) |_| _ = selector.start(false, true, poll_frames);
    try std.testing.expect(selector.start(true, true, poll_frames) != null);
}
