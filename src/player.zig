//! Plants B and C: one-shot playback of a fixed clip.
//!
//! A touch starts the clip from the beginning and it plays all the way through,
//! whether or not the visitor lets go. Touching again while it is still playing
//! does nothing. Holding a touch does not loop it.
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

const testing = std.testing;

fn constantClip(comptime len: usize) [len]f32 {
    return .{1.0} ** len;
}
