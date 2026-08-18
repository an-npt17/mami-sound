//! Plants B and C: one clip at a time, drawn from a folder of them.
//!
//! Both plants answer the same probe on AIN1, and a probe cannot mean two
//! things at once, so they take turns. A touch starts one clip; when it ends
//! nothing sounds until the next touch, which starts the other plant's — and
//! each turn draws a fresh recording at random rather than replaying the same
//! one, so a visitor who waits hears something new.
//!
//! A touch during a clip is ignored while the clip is young, so a visitor
//! cannot machine-gun through the folder. Past `interrupt_after` it is taken as
//! "enough of this one": the clip fades out and the next turn begins.
//!
//! Nothing here knows which plants these are, or what is in the folders. It is
//! two pools of clips and the order to take turns in.

const std = @import("std");

/// Headroom so three simultaneous voices rarely reach the clamp.
const voice_gain: f32 = 0.4;

/// Fade at each end of a clip. Long enough that cutting one off part way
/// through is a fade rather than a click, short enough not to swallow a word.
const fade_ms: f32 = 30.0;

/// One clip, playing once through.
pub const Player = struct {
    clip: []const f32,
    /// Read position. Equal to `clip.len` means idle.
    pos: usize,
    /// Fade envelope, 0 at each end of the clip.
    env: f32,
    /// Envelope movement per sample.
    step: f32,
    /// Samples before the end at which the tail fade starts.
    tail: usize,
    /// Fading out early, on the way to idle.
    stopping: bool,

    pub fn init(clip: []const f32, sample_rate: u32) Player {
        const sr: f32 = @floatFromInt(sample_rate);
        const fade: usize = @intFromFloat(fade_ms / 1000.0 * sr);
        return .{
            .clip = clip,
            .pos = 0,
            .env = 0.0,
            .step = 1.0 / (fade_ms / 1000.0 * sr),
            // A clip shorter than two fades is all fade; better that than an
            // envelope that never opens.
            .tail = @min(fade, clip.len / 2),
            .stopping = false,
        };
    }

    /// An idle player, for a `Sequence` that has not started anything yet.
    pub fn silent() Player {
        return .{
            .clip = &.{},
            .pos = 0,
            .env = 0.0,
            .step = 1.0,
            .tail = 0,
            .stopping = false,
        };
    }

    pub fn isPlaying(self: Player) bool {
        return self.pos < self.clip.len;
    }

    /// Fade out from wherever it is and go idle. What an interrupting touch
    /// does: cutting the samples off dead would click.
    pub fn stop(self: *Player) void {
        self.stopping = true;
    }

    /// Add this clip's output into `out`, up to whatever is left of it, and
    /// report how many samples that was. Never overwrites, so voices mix by
    /// being rendered in sequence into the same block.
    ///
    /// The count is returned rather than left for the caller to work out from
    /// `pos`, because a fade that completes jumps `pos` to the end: the
    /// difference would then be the whole rest of the clip.
    pub fn render(self: *Player, out: []f32) usize {
        var written: usize = 0;
        for (out) |*sample| {
            if (self.pos >= self.clip.len) break;

            // The envelope closes for the tail of the clip as well as for an
            // interruption, so a recording that ends on a loud sample does not
            // click either.
            const remaining = self.clip.len - self.pos;
            const target: f32 = if (self.stopping or remaining <= self.tail) 0.0 else 1.0;
            if (self.env < target) {
                self.env = @min(target, self.env + self.step);
            } else if (self.env > target) {
                self.env = @max(target, self.env - self.step);
            }

            sample.* += self.clip[self.pos] * self.env * voice_gain;
            self.pos += 1;
            written += 1;

            // Faded away early: idle now rather than playing on silently.
            if (self.stopping and self.env == 0.0) {
                self.pos = self.clip.len;
                break;
            }
        }
        return written;
    }
};

/// Plants B and C, one clip per touch, drawn at random from their folders.
pub const Sequence = struct {
    /// Plants B and C, in the order they take turns.
    pub const count = 2;

    /// Every clip loaded for each plant. Empty means that plant is silent.
    pools: [count][]const []const f32,
    /// Which pool is sounding. `count` means silence.
    current: usize,
    /// Whose turn it is: what the next touch will start. `count` means there is
    /// nothing to play at all.
    next_up: usize,
    player: Player,
    /// The clip each pool played last, so the next draw can avoid repeating it.
    last_pick: [count]?usize,
    prev_open: bool,
    /// Frames the current clip has sounded, against `interrupt_after`.
    played: u64,
    /// How long a clip must have been going before a touch may cut it short.
    /// Zero means a clip is never interrupted.
    interrupt_after: u64,
    /// True while a faded-out clip is on its way to being replaced.
    switching: bool,
    /// How many clips have been started. A caller watching this sees every
    /// start, including one that comes from an interrupt part way through a
    /// block, which watching idle-to-playing would miss entirely.
    starts: u64,
    sample_rate: u32,
    random: std.Random,

    pub fn init(
        pools: [count][]const []const f32,
        sample_rate: u32,
        interrupt_after: u64,
        random: std.Random,
    ) Sequence {
        var seq: Sequence = .{
            .pools = pools,
            .current = count,
            .next_up = count,
            .player = .silent(),
            .last_pick = .{ null, null },
            .prev_open = false,
            .played = 0,
            .interrupt_after = interrupt_after,
            .switching = false,
            .starts = 0,
            .sample_rate = sample_rate,
            .random = random,
        };
        seq.next_up = seq.turnFrom(0);
        return seq;
    }

    pub fn isPlaying(self: Sequence) bool {
        return self.current < count;
    }

    /// Which pool is sounding, or null when nothing is. For the status line.
    pub fn playingIndex(self: Sequence) ?usize {
        return if (self.current < count) self.current else null;
    }

    /// Which clip of the sounding pool is playing, for naming it in a log.
    pub fn playingClip(self: Sequence) ?usize {
        if (self.current >= count) return null;
        return self.last_pick[self.current];
    }

    /// The next pool worth playing at or after `from`, wrapping. Skips the
    /// plants left out on the command line, so a single enabled pool simply
    /// takes every turn.
    fn turnFrom(self: Sequence, from: usize) usize {
        for (0..count) |i| {
            const idx = (from + i) % count;
            if (self.pools[idx].len != 0) return idx;
        }
        return count;
    }

    /// A clip from `slot`, never the one it played last. Drawing freely would
    /// repeat a recording immediately about as often as the folder is small,
    /// which reads as the installation being stuck rather than as chance.
    fn draw(self: *Sequence, slot: usize) usize {
        const clips = self.pools[slot];
        if (clips.len == 1) return 0;

        const last = self.last_pick[slot] orelse
            return self.random.uintLessThan(usize, clips.len);

        // Draw from the others and step over the one just played, so every
        // remaining clip is equally likely in one go rather than by retrying.
        var idx = self.random.uintLessThan(usize, clips.len - 1);
        if (idx >= last) idx += 1;
        return idx;
    }

    fn begin(self: *Sequence) void {
        const slot = self.next_up;
        if (slot >= count) return;

        const idx = self.draw(slot);
        self.player = .init(self.pools[slot][idx], self.sample_rate);
        self.last_pick[slot] = idx;
        self.current = slot;
        self.played = 0;
        self.starts += 1;
        self.next_up = self.turnFrom(slot + 1);
    }

    /// Add whichever clip is sounding into `out`. `open` is the touch: its
    /// rising edge starts a clip, or cuts short one that has had its time.
    pub fn render(self: *Sequence, out: []f32, open: bool) void {
        const rising = open and !self.prev_open;
        self.prev_open = open;

        if (rising) {
            if (!self.isPlaying()) {
                self.begin();
            } else if (self.interrupt_after != 0 and self.played >= self.interrupt_after) {
                // Enough of this one. Fade it out and take the next turn on the
                // far side of the fade, rather than cutting mid-word.
                self.switching = true;
                self.player.stop();
            }
        }

        var rest = out;
        while (rest.len != 0 and self.isPlaying()) {
            const written = self.player.render(rest);
            self.played += written;
            rest = rest[written..];

            if (self.player.isPlaying()) break;

            // The clip is done, by its own end or by being cut short. A cut
            // short is owed its replacement, and starts inside this same block
            // so the gap is only the fade.
            self.current = count;
            if (!self.switching) break;
            self.switching = false;
            self.begin();
        }
    }
};

const testing = std.testing;

/// Clips a test can tell apart: the level says which pool is sounding, and
/// which clip within it.
fn levelClip(gpa: std.mem.Allocator, len: usize, level: f32) ![]f32 {
    const clip = try gpa.alloc(f32, len);
    @memset(clip, level);
    return clip;
}

/// Whatever the mix holds once the fade has opened, as a clip level: the point
/// of a test is which clip is playing, not the shape of its first millisecond.
fn levelOf(seq: *Sequence, buf: []f32, open: bool) f32 {
    @memset(buf, 0);
    seq.render(buf, open);
    return buf[buf.len - 1] / voice_gain;
}

/// A pool of `n` clips, each a constant level of 1, 2, 3… so a test can say
/// which one is sounding.
fn pool(gpa: std.mem.Allocator, n: usize, len: usize) ![][]const f32 {
    const clips = try gpa.alloc([]const f32, n);
    for (clips, 0..) |*clip, i| {
        clip.* = try levelClip(gpa, len, @floatFromInt(i + 1));
    }
    return clips;
}

fn freePool(gpa: std.mem.Allocator, clips: [][]const f32) void {
    for (clips) |clip| gpa.free(clip);
    gpa.free(clips);
}

/// Render `buf` and report the clip level once the fade has opened, rounded to
/// the nearest whole level. Zero means nothing is sounding.
fn levelNow(seq: *Sequence, buf: []f32) f32 {
    @memset(buf, 0);
    seq.render(buf, seq.prev_open);
    return @round(buf[buf.len - 1] / voice_gain);
}

test "a touch draws a clip, and the turn moves to the other folder" {
    const gpa = testing.allocator;
    // Two clips of one level each, so the pool is identifiable but the draw
    // within it is not in question.
    const b = try pool(gpa, 1, 44100);
    defer freePool(gpa, b);
    const c = try pool(gpa, 1, 44100);
    defer freePool(gpa, c);
    // Level 1 in both pools, so tell them apart by `playingIndex` instead.

    var prng = std.Random.DefaultPrng.init(1);
    var seq = Sequence.init(.{ b, c }, 44100, 0, prng.random());
    var buf: [4410]f32 = undefined;

    @memset(&buf, 0);
    seq.render(&buf, true);
    try testing.expectEqual(@as(?usize, 0), seq.playingIndex());

    // Play it out, then a second touch takes the other folder's turn.
    while (seq.isPlaying()) _ = levelNow(&seq, &buf);
    @memset(&buf, 0);
    seq.render(&buf, false);
    @memset(&buf, 0);
    seq.render(&buf, true);
    try testing.expectEqual(@as(?usize, 1), seq.playingIndex());
}

test "a touch too soon is ignored, and one past the interrupt draws again" {
    const gpa = testing.allocator;
    const b = try pool(gpa, 4, 44100);
    defer freePool(gpa, b);
    const c = try pool(gpa, 4, 44100);
    defer freePool(gpa, c);

    var prng = std.Random.DefaultPrng.init(3);
    // Interrupt after 10000 frames.
    var seq = Sequence.init(.{ b, c }, 44100, 10000, prng.random());
    var buf: [1000]f32 = undefined;

    @memset(&buf, 0);
    seq.render(&buf, true);
    const first = seq.playingIndex().?;
    try testing.expectEqual(@as(usize, 0), first);

    // Five blocks in — 5000 frames, under the interrupt. A touch here is the
    // visitor being impatient, and the clip they started is theirs to hear.
    for (0..4) |_| _ = levelNow(&seq, &buf);
    @memset(&buf, 0);
    seq.render(&buf, false);
    @memset(&buf, 0);
    seq.render(&buf, true);
    try testing.expectEqual(@as(?usize, 0), seq.playingIndex());
    try testing.expect(seq.played < 10000);

    // Past the interrupt, the same touch cuts it short and takes the next turn.
    while (seq.played < 10000) _ = levelNow(&seq, &buf);
    @memset(&buf, 0);
    seq.render(&buf, false);
    @memset(&buf, 0);
    seq.render(&buf, true);
    // The switch happens inside one block, through the fade, so by the end of
    // the next one the other folder is sounding.
    _ = levelNow(&seq, &buf);
    try testing.expectEqual(@as(?usize, 1), seq.playingIndex());
    try testing.expect(seq.played < 10000);
}

test "an interrupted clip fades rather than cutting" {
    const gpa = testing.allocator;
    const b = try pool(gpa, 1, 44100);
    defer freePool(gpa, b);
    const c = try pool(gpa, 1, 44100);
    defer freePool(gpa, c);

    var prng = std.Random.DefaultPrng.init(5);
    var seq = Sequence.init(.{ b, c }, 44100, 1000, prng.random());
    var buf: [2048]f32 = undefined;

    @memset(&buf, 0);
    seq.render(&buf, true);
    while (seq.played < 1000) _ = levelNow(&seq, &buf);

    @memset(&buf, 0);
    seq.render(&buf, false);
    // Carry the last sample over: the join between blocks is exactly where a
    // hard cut would show, so it has to be part of the check.
    var prev: f32 = buf[buf.len - 1];

    @memset(&buf, 0);
    seq.render(&buf, true);

    // No step from one sample to the next larger than the fade's own slope.
    // A cut would show up as a jump of a whole clip level.
    for (buf) |s| {
        try testing.expect(@abs(s - prev) < 0.05);
        prev = s;
    }
    // And the fade really did close and reopen, rather than the level simply
    // continuing: somewhere in there is a sample at or near silence.
    var quietest: f32 = 1.0;
    for (buf) |s| quietest = @min(quietest, @abs(s));
    try testing.expect(quietest < 0.01);
}

test "the same clip is never drawn twice running" {
    const gpa = testing.allocator;
    // One pool, so every turn comes from it and repeats would be obvious.
    const b = try pool(gpa, 3, 4410);
    defer freePool(gpa, b);

    var prng = std.Random.DefaultPrng.init(11);
    var seq = Sequence.init(.{ b, &.{} }, 44100, 0, prng.random());
    var buf: [4410]f32 = undefined;

    var previous: f32 = 0;
    for (0..40) |_| {
        @memset(&buf, 0);
        seq.render(&buf, false);
        @memset(&buf, 0);
        seq.render(&buf, true);
        // Mid-clip, where the fade is fully open.
        const level = @round(buf[buf.len / 2] / voice_gain);
        try testing.expect(level != previous);
        previous = level;
        while (seq.isPlaying()) _ = levelNow(&seq, &buf);
    }
}

test "a folder of one clip repeats it rather than falling silent" {
    const gpa = testing.allocator;
    const b = try pool(gpa, 1, 4410);
    defer freePool(gpa, b);

    var prng = std.Random.DefaultPrng.init(13);
    var seq = Sequence.init(.{ b, &.{} }, 44100, 0, prng.random());
    // Shorter than the clip, so a block does not play the whole thing at once.
    var buf: [512]f32 = undefined;

    for (0..5) |_| {
        @memset(&buf, 0);
        seq.render(&buf, false);
        @memset(&buf, 0);
        seq.render(&buf, true);
        try testing.expect(seq.isPlaying());
        while (seq.isPlaying()) _ = levelNow(&seq, &buf);
    }
}

test "empty folders leave the sequence idle rather than stuck" {
    var prng = std.Random.DefaultPrng.init(17);
    var seq = Sequence.init(.{ &.{}, &.{} }, 44100, 0, prng.random());
    var buf: [512]f32 = undefined;
    @memset(&buf, 0);
    seq.render(&buf, true);
    try testing.expect(!seq.isPlaying());
    try testing.expectEqual(@as(?usize, null), seq.playingIndex());
    for (buf) |s| try testing.expectEqual(@as(f32, 0.0), s);
}
