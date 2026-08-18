//! Plants B and C: one-shot playback of a fixed clip, one clip at a time.
//!
//! A trigger starts the clip from the beginning and it plays all the way
//! through, whether or not the visitor lets go. Triggering again while it is
//! still playing does nothing, and holding does not loop it.
//!
//! `Player` is one clip. `Sequence` is the pair of them sharing a probe, which
//! is how plants B and C are actually wired: one after the other, never at once.
//!
//! The player never inspects where its buffer came from, so replacing the
//! generated placeholder clips with decoded audio files changes nothing here.

const std = @import("std");

/// Headroom so three simultaneous voices rarely reach the clamp.
const voice_gain: f32 = 0.4;

pub const Player = struct {
    clip: []const f32,
    /// Read position. Equal to `clip.len` means idle.
    pos: usize,
    prev_touch: bool,

    pub fn init(clip: []const f32) Player {
        return .{ .clip = clip, .pos = clip.len, .prev_touch = false };
    }

    pub fn isPlaying(self: Player) bool {
        return self.pos < self.clip.len;
    }

    /// Start the clip from the beginning, whatever it was doing. For a caller
    /// that decides when a clip runs on its own terms — `Sequence` does — rather
    /// than from a touch of its own.
    pub fn start(self: *Player) void {
        self.pos = 0;
    }

    /// Add this voice's output into `out`. Never overwrites, so voices mix by
    /// being rendered in sequence into the same block.
    pub fn render(self: *Player, out: []f32, touched: bool) void {
        // Rising edge only, and only when idle: a held touch must not retrigger
        // once the clip has finished.
        if (touched and !self.prev_touch and !self.isPlaying()) self.pos = 0;
        self.prev_touch = touched;

        for (out) |*sample| {
            if (self.pos >= self.clip.len) break;
            sample.* += self.clip[self.pos] * voice_gain;
            self.pos += 1;
        }
    }
};

/// Plants B and C, one clip per touch.
///
/// Both clips answer the same probe on AIN1, and a probe cannot mean two things
/// at once. So they take it in turns: a touch starts one clip, it plays to the
/// end, and then nothing sounds until the *next* touch, which starts the other.
/// Never two at once, and never one running straight into the other — a visitor
/// who walks away is not followed by a second clip they did not ask for.
///
/// The turn only advances when a clip actually starts, so the pair steps
/// forward one touch at a time and wraps around: B, C, B, C.
///
/// Nothing here knows which plants these are. It is a list of clips and the
/// order to take turns in.
pub const Sequence = struct {
    /// Plants B and C, in the order they take turns.
    pub const count = 2;

    players: [count]Player,
    /// A plant left out with `--plants` never takes a turn, so `13` plays the
    /// waterfall on every touch rather than every second one.
    enabled: [count]bool,
    /// Which clip is sounding. `count` means silence.
    current: usize,
    /// Whose turn it is: what the next touch will start. `count` means there is
    /// nothing to play at all.
    next_up: usize,
    prev_open: bool,

    pub fn init(clips: [count][]const f32, enabled: [count]bool) Sequence {
        var players: [count]Player = undefined;
        for (&players, clips) |*p, clip| p.* = Player.init(clip);
        var seq: Sequence = .{
            .players = players,
            .enabled = enabled,
            .current = count,
            .next_up = count,
            .prev_open = false,
        };
        seq.next_up = seq.turnFrom(0);
        return seq;
    }

    pub fn isPlaying(self: Sequence) bool {
        return self.current < count;
    }

    /// Which clip is sounding, or null when nothing is. For the status line, so
    /// it reports the clip that is actually audible.
    pub fn playingIndex(self: Sequence) ?usize {
        return if (self.current < count) self.current else null;
    }

    /// The next clip worth playing at or after `from`, wrapping. Skips the ones
    /// left out on the command line and the ones that were never loaded, so a
    /// single enabled clip simply takes every turn.
    fn turnFrom(self: Sequence, from: usize) usize {
        for (0..count) |i| {
            const idx = (from + i) % count;
            if (self.enabled[idx] and self.players[idx].clip.len != 0) return idx;
        }
        return count;
    }

    /// Add whichever clip is sounding into `out`. `open` is the touch: crossing
    /// the threshold. Its *rising* edge is what starts a clip, so a reading that
    /// simply stays high — a visitor keeping their hand on the plant — starts
    /// one clip and not a queue of them.
    pub fn render(self: *Sequence, out: []f32, open: bool) void {
        // Only when idle: a touch during a clip is not a queued turn, it is
        // ignored, and the run that is already going plays out.
        if (open and !self.prev_open and !self.isPlaying()) {
            if (self.next_up < count) {
                self.current = self.next_up;
                self.players[self.current].start();
                // The turn moves on only because a clip really started.
                self.next_up = self.turnFrom(self.current + 1);
            }
        }
        self.prev_open = open;

        if (self.current < count) {
            const player = &self.players[self.current];
            // `false`: the touch belongs to the sequence, not to the player,
            // which is why `start` was called above rather than a touch passed.
            player.render(out, false);
            // Finished: silence, and the next clip waits for its own touch.
            if (!player.isPlaying()) self.current = count;
        }
    }
};

const testing = std.testing;

fn constantClip(comptime len: usize) [len]f32 {
    return .{1.0} ** len;
}

/// Two clips a test can tell apart: whichever level comes out of the mix says
/// which plant is sounding.
const b_level: f32 = 1.0;
const c_level: f32 = 0.5;

fn twoClips(gpa: std.mem.Allocator, b_len: usize, c_len: usize) ![2][]f32 {
    const b = try gpa.alloc(f32, b_len);
    @memset(b, b_level);
    const c = try gpa.alloc(f32, c_len);
    @memset(c, c_level);
    return .{ b, c };
}

/// Render `len` samples with the touch held at `open`, and report what came out
/// of the first sample. Zero means nothing was sounding.
fn renderOnce(seq: *Sequence, buf: []f32, open: bool) f32 {
    @memset(buf, 0);
    seq.render(buf, open);
    return buf[0];
}

test "one touch plays one clip, and the next waits for its own touch" {
    const gpa = testing.allocator;
    const clips = try twoClips(gpa, 100, 100);
    defer gpa.free(clips[0]);
    defer gpa.free(clips[1]);

    var seq = Sequence.init(.{ clips[0], clips[1] }, .{ true, true });
    var out: [100]f32 = undefined;

    // First touch: B, all the way through.
    try testing.expectApproxEqAbs(b_level * voice_gain, renderOnce(&seq, &out, true), 0.0001);
    for (out) |s| try testing.expectApproxEqAbs(b_level * voice_gain, s, 0.0001);
    try testing.expect(!seq.isPlaying());

    // B has finished and C does *not* follow on its own, however long the
    // reading is held over the threshold.
    for (0..5) |_| {
        try testing.expectEqual(@as(f32, 0.0), renderOnce(&seq, &out, true));
    }

    // Falling back under the threshold is silent too.
    try testing.expectEqual(@as(f32, 0.0), renderOnce(&seq, &out, false));

    // Only a fresh crossing starts C.
    try testing.expectApproxEqAbs(c_level * voice_gain, renderOnce(&seq, &out, true), 0.0001);
    for (out) |s| try testing.expectApproxEqAbs(c_level * voice_gain, s, 0.0001);
}

test "the turn wraps back to the first clip" {
    const gpa = testing.allocator;
    const clips = try twoClips(gpa, 10, 10);
    defer gpa.free(clips[0]);
    defer gpa.free(clips[1]);

    var seq = Sequence.init(.{ clips[0], clips[1] }, .{ true, true });
    var out: [10]f32 = undefined;

    // B, C, then B again: an installation runs all day, so the pair cycles.
    const expected = [_]f32{ b_level, c_level, b_level, c_level };
    for (expected) |level| {
        _ = renderOnce(&seq, &out, false);
        try testing.expectApproxEqAbs(level * voice_gain, renderOnce(&seq, &out, true), 0.0001);
    }
}

test "a touch during a clip is ignored, not queued" {
    const gpa = testing.allocator;
    // B is six blocks long here, so it is unambiguously still playing when the
    // second crossing arrives.
    const clips = try twoClips(gpa, 300, 100);
    defer gpa.free(clips[0]);
    defer gpa.free(clips[1]);

    var seq = Sequence.init(.{ clips[0], clips[1] }, .{ true, true });
    var out: [50]f32 = undefined;

    _ = renderOnce(&seq, &out, true); // 50 of B
    _ = renderOnce(&seq, &out, false); // a dip, one third of the way in...
    // ...and a second crossing. B owns the rest of its length and the crossing
    // buys nothing: it is still B sounding, not C on top of it.
    try testing.expectApproxEqAbs(b_level * voice_gain, renderOnce(&seq, &out, true), 0.0001);
    try testing.expect(seq.isPlaying());
    try testing.expectEqual(@as(?usize, 0), seq.playingIndex());

    // Let B run out. The ignored crossing did not queue C behind it.
    for (0..3) |_| _ = renderOnce(&seq, &out, true);
    try testing.expect(!seq.isPlaying());
    try testing.expectEqual(@as(f32, 0.0), renderOnce(&seq, &out, true));

    // C is still owed a touch of its own, and gets one.
    _ = renderOnce(&seq, &out, false);
    try testing.expectApproxEqAbs(c_level * voice_gain, renderOnce(&seq, &out, true), 0.0001);
}

test "a plant left out on the command line never takes a turn" {
    const gpa = testing.allocator;
    const clips = try twoClips(gpa, 10, 10);
    defer gpa.free(clips[0]);
    defer gpa.free(clips[1]);

    // `mami_sound 13`: plant C without plant B. Every touch is C's.
    var seq = Sequence.init(.{ clips[0], clips[1] }, .{ false, true });
    var out: [10]f32 = undefined;
    for (0..3) |_| {
        _ = renderOnce(&seq, &out, false);
        try testing.expectApproxEqAbs(c_level * voice_gain, renderOnce(&seq, &out, true), 0.0001);
    }
}

test "nothing to play leaves the sequence idle rather than stuck" {
    var seq = Sequence.init(.{ &.{}, &.{} }, .{ true, true });
    var out: [32]f32 = undefined;
    try testing.expectEqual(@as(f32, 0.0), renderOnce(&seq, &out, true));
    try testing.expect(!seq.isPlaying());
    try testing.expectEqual(@as(?usize, null), seq.playingIndex());
}

test "a clip plays out even after the reading falls away" {
    const gpa = testing.allocator;
    const clips = try twoClips(gpa, 100, 100);
    defer gpa.free(clips[0]);
    defer gpa.free(clips[1]);

    var seq = Sequence.init(.{ clips[0], clips[1] }, .{ true, true });
    var out: [50]f32 = undefined;

    _ = renderOnce(&seq, &out, true);
    // The visitor lets go. The clip is a one-shot, so it finishes anyway.
    try testing.expectApproxEqAbs(b_level * voice_gain, renderOnce(&seq, &out, false), 0.0001);
    try testing.expect(!seq.isPlaying());
}
