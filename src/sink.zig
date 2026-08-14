//! Audio output: raw PCM piped into `aplay`.
//!
//! Spawning `aplay` avoids linking libasound and C interop entirely. Writing a
//! block blocks until `aplay` is ready for more, so the sink also serves as the
//! program's clock: no timers, no sleeping, no drift.
//!
//! Moving to direct ALSA later means rewriting this file and nothing else.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // `aplay -f S16_LE` reads little-endian samples, and `write` hands it the
    // raw bytes of an `[]i16`.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

/// Convert a mixed f32 block to signed 16-bit PCM.
///
/// Voices add into a shared block, so the sum can exceed full scale when
/// several sound at once. Clamping here keeps a loud moment loud instead of
/// letting it wrap around into noise.
pub fn toPcm(block: []const f32, out: []i16) void {
    std.debug.assert(block.len == out.len);
    for (block, out) |sample, *pcm| {
        pcm.* = @intFromFloat(std.math.clamp(sample, -1.0, 1.0) * 32767.0);
    }
}

pub const Sink = struct {
    io: std.Io,
    child: std.process.Child,

    /// Spawns `aplay`. `argv[0]` is resolved through the parent's `PATH`, so
    /// the dev shell providing `alsa-utils` is enough.
    pub fn init(io: std.Io, comptime sample_rate: u32, comptime channels: u32) !Sink {
        const child = try std.process.spawn(io, .{
            .argv = &.{
                "aplay",
                "-q",
                "-f",
                "S16_LE",
                "-r",
                std.fmt.comptimePrint("{d}", .{sample_rate}),
                "-c",
                std.fmt.comptimePrint("{d}", .{channels}),
                "-",
            },
            .stdin = .pipe,
        });
        return .{ .io = io, .child = child };
    }

    pub fn write(self: *Sink, frames: []const i16) !void {
        const stdin = self.child.stdin orelse return error.SinkClosed;
        try stdin.writeStreamingAll(self.io, std.mem.sliceAsBytes(frames));
    }

    /// Close the pipe so `aplay` drains what it has and exits, then reap it.
    pub fn finish(self: *Sink) !void {
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }
        _ = try self.child.wait(self.io);
    }
};
