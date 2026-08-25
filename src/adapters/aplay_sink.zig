//! Audio output: raw PCM piped into `aplay`.
//!
//! Spawning `aplay` avoids linking libasound and C interop entirely. Writing a
//! block blocks until `aplay` is ready for more, so the sink also serves as the
//! program's clock: no timers, no sleeping, no drift.
//!
//! Moving to direct ALSA later means rewriting this file and nothing else.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const ports = @import("../ports/root.zig");

/// How much audio each queue between the mixer and the speaker may hold.
///
/// Both default to far more than this piece wants. The kernel gives a pipe
/// 64 KiB, which is 0.74 s of mono audio at 44100 Hz, and `aplay` asks ALSA for
/// a 500 ms buffer. They stack, and `write` only blocks once both are full, so
/// the steady state is both of them full: left alone, a touch is heard about
/// 1.2 s after it happens. That is an installation where the plants seem not to
/// respond, and no amount of polling the sensors faster can fix it.
///
/// These are the numbers to raise if the sound breaks up. A Zero 2 W that
/// misses a 93 ms deadline clicks, where a half-second buffer would have ridden
/// over the same stall — and the trade is one for one, every millisecond of
/// safety is a millisecond of delay.
const buffer_frames = 4096;
const period_frames = 512;
const pipe_frames = 4096;

comptime {
    // `aplay -f S16_LE` reads little-endian samples, and `write` hands it the
    // raw bytes of an `[]i16`.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

/// Shrink the pipe to `bytes`, so `aplay` cannot be handed more audio than it
/// is about to play.
///
/// `F_SETPIPE_SZ` is the only way to reach this queue: nothing about how the
/// writes are made changes how much the kernel is willing to hold, so a writer
/// that stays ahead will always sit on a full 64 KiB otherwise.
///
/// A failure is left alone rather than reported. The kernel rounds the request
/// up to a page and refuses to go under one, so the worst case is a machine
/// with unusual pages keeping more audio in flight than asked — more latency,
/// never a broken stream.
fn shrinkPipe(fd: linux.fd_t, bytes: usize) void {
    _ = linux.fcntl(fd, linux.F.SETPIPE_SZ, bytes);
}

pub const Adapter = struct {
    io: std.Io,
    child: std.process.Child,

    /// Spawns `aplay`. `argv[0]` is resolved through the parent's `PATH`, so
    /// the dev shell providing `alsa-utils` is enough.
    ///
    /// `device` is passed straight to `-D`. `default` follows whatever the
    /// machine's ALSA configuration points at, which on a board with a USB or
    /// I2S card added is often not the card wanted; naming it, as in
    /// `plughw:0,0`, settles it.
    ///
    /// The period is one engine block, so a block handed over is a block the
    /// card is about to play.
    pub fn init(
        io: std.Io,
        device: []const u8,
        comptime sample_rate: u32,
        comptime channels: u32,
    ) !Adapter {
        const child = try std.process.spawn(io, .{
            .argv = &.{
                "aplay",
                "-q",
                "-D",
                device,
                "-f",
                "S16_LE",
                "-r",
                std.fmt.comptimePrint("{d}", .{sample_rate}),
                "-c",
                std.fmt.comptimePrint("{d}", .{channels}),
                "--period-size",
                std.fmt.comptimePrint("{d}", .{period_frames}),
                "--buffer-size",
                std.fmt.comptimePrint("{d}", .{buffer_frames}),
                "-",
            },
            .stdin = .pipe,
        });

        // Shrinking `aplay`'s own buffer is only half of it: the pipe in front
        // of it is a queue too, and the larger one by default.
        const pipe_bytes = pipe_frames * @sizeOf(i16) * channels;
        comptime std.debug.assert(pipe_bytes >= 4096); // the kernel's own floor
        if (child.stdin) |stdin| shrinkPipe(stdin.handle, pipe_bytes);

        return .{ .io = io, .child = child };
    }

    pub fn port(self: *Adapter) ports.AudioSink {
        return .{
            .context = self,
            .write_fn = writePort,
            .finish_fn = finishPort,
        };
    }

    pub fn write(self: *Adapter, frames: []const i16) !void {
        const stdin = self.child.stdin orelse return error.SinkClosed;
        try stdin.writeStreamingAll(self.io, std.mem.sliceAsBytes(frames));
    }

    /// Close the pipe so `aplay` drains what it has and exits, then reap it.
    pub fn finish(self: *Adapter) !void {
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }
        const term = try self.child.wait(self.io);
        switch (term) {
            .exited => |code| if (code != 0) return error.ChildFailed,
            else => return error.ChildFailed,
        }
    }

    fn writePort(context: *anyopaque, frames: []const i16) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        return self.write(frames);
    }

    fn finishPort(context: *anyopaque) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        return self.finish();
    }
};

const testing = std.testing;

/// Milliseconds of audio `frames` is, at the rate the engine runs at.
fn millis(frames: u32) f32 {
    return @as(f32, @floatFromInt(frames)) / 44100.0 * 1000.0;
}

test "the queues in front of the card stay inside a playable delay" {
    // Both fill and stay full, so this sum is what a visitor waits between
    // touching a plant and hearing it. Under ~200 ms a touch still reads as
    // having caused the sound; the 1.2 s of stock defaults does not.
    const total = millis(pipe_frames) + millis(buffer_frames);
    try testing.expect(total < 250.0);

    // Left at their defaults these are 32768 frames of pipe and 22050 of ALSA
    // buffer. Guard the point of the exercise rather than the exact numbers.
    try testing.expect(pipe_frames < 32768);
    try testing.expect(buffer_frames < 22050);

    // One period per engine block: a block handed over is a block the card is
    // about to play, and never a fraction of one it has to wait to complete.
    try testing.expectEqual(@as(u32, 512), period_frames);
    try testing.expectEqual(@as(u32, 0), buffer_frames % period_frames);
}

test "the adapter port dispatches writes through its function table" {
    var adapter = Adapter{
        .io = undefined,
        .child = std.mem.zeroes(std.process.Child),
    };
    var sink = adapter.port();

    try testing.expectError(error.SinkClosed, sink.write(&.{}));
}

test "the adapter port dispatches finish through its function table" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const child = try std.process.spawn(io, .{
        .argv = &.{"/bin/sh"},
        .stdin = .pipe,
        .stdout = .ignore,
    });
    var adapter = Adapter{ .io = io, .child = child };
    var sink = adapter.port();

    try sink.finish();
}

test "finish reports a non-zero child exit" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 7" },
        .stdin = .pipe,
        .stdout = .ignore,
    });
    var adapter = Adapter{ .io = io, .child = child };

    try testing.expectError(error.ChildFailed, adapter.finish());
}

test "finish reports a child that did not exit normally" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "kill -TERM $$" },
        .stdin = .pipe,
        .stdout = .ignore,
    });
    var adapter = Adapter{ .io = io, .child = child };

    try testing.expectError(error.ChildFailed, adapter.finish());
}
