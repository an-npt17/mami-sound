//! The first seconds of every clip, decoded once at startup and held in RAM.
//!
//! Spawning `ffmpeg` is the slowest thing in the path between a hand on plant B
//! and a sound: the process has to start, open the file and decode before one
//! sample exists, and on a Zero 2 W that is most of the delay people read as
//! the plant not responding. Nothing about it can be made fast, so it is moved
//! out of the way instead — the opening of each clip is already in memory when
//! the touch arrives, and `ffmpeg` is given the length of that head to catch up
//! in before anybody would hear it miss.
//!
//! Only the head. Decoding the recordings pool whole would want 539 MB of f32
//! against the board's 512 MB of RAM, which is not a tuning decision but a
//! machine that does not boot. Two seconds of each of the 21 recordings is
//! 7.1 MB, and the streamer carries the rest as it always did.
//!
//! The head is shaped by the pool's allowance as it is decoded, so a stem whose
//! four seconds fit inside the head carries its own fade and never reaches
//! `ffmpeg` at all.

const std = @import("std");
const linux = std.os.linux;
const core = @import("../core/root.zig");

/// How much of each clip is kept.
///
/// Long enough to cover an `ffmpeg` startup several times over on the slowest
/// board this runs on, short enough that the whole pool stays a rounding error
/// against the RAM. Raising it costs 3.5 MB a second across 21 recordings.
pub const head_s: f32 = 2.0;

/// The filter the clips are decoded through. Shared with the streamer, which
/// decodes the same clips from the head's end onwards: a head at one level and
/// a stream at another would be audible as a step at the seam.
pub const filter = "alimiter=limit=0.8";

/// Where one clip's head sits in the flat sample buffer.
pub const Span = struct {
    start: usize,
    len: usize,
};

pub const Heads = struct {
    /// Every head, end to end. One allocation rather than one per clip: they
    /// are written once and read forever, and nothing ever frees just one.
    samples: []f32,
    spans: []Span,

    /// No heads at all, which is what an unprimed streamer carries and what a
    /// pool with no clips decodes to. Every read path treats it as "no head for
    /// this clip" and falls back to waiting on `ffmpeg`, so a failed prime
    /// costs latency and never sound.
    pub const none: Heads = .{ .samples = &.{}, .spans = &.{} };

    /// One clip's head, or empty where there is none. Called from the audio
    /// thread, so it allocates nothing and takes no lock: the buffer is written
    /// before the worker starts and never touched again.
    pub fn get(self: Heads, index: usize) []const f32 {
        if (index >= self.spans.len) return &.{};
        const span = self.spans[index];
        return self.samples[span.start..][0..span.len];
    }

    pub fn deinit(self: *Heads, gpa: std.mem.Allocator) void {
        if (self.samples.len != 0) gpa.free(self.samples);
        if (self.spans.len != 0) gpa.free(self.spans);
        self.* = none;
    }
};

/// Decode the opening of every clip in `paths`.
///
/// A clip that fails to decode gets an empty head rather than failing the run.
/// The streamer still plays it the slow way, which is the behaviour before any
/// of this existed, and one unreadable file in a folder of twenty is not a
/// reason for an installation not to open.
pub fn decode(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    limit: core.plant_b.Limit,
    sample_rate: u32,
) !Heads {
    if (paths.len == 0) return .none;

    const head_samples: usize = @intFromFloat(head_s * @as(f32, @floatFromInt(sample_rate)));

    // A capped pool is taken whole rather than to the head length. Its clips
    // are four seconds each, so the whole pool is a few megabytes, and holding
    // all of it means a stem never reaches `ffmpeg` at all -- not on startup
    // and not on a touch.
    const want = if (limit.total == core.plant_b.Limit.unlimited.total)
        head_samples
    else
        limit.total;

    var samples: std.ArrayList(f32) = .empty;
    errdefer samples.deinit(gpa);

    const spans = try gpa.alloc(Span, paths.len);
    errdefer gpa.free(spans);

    for (paths, spans) |path, *span| {
        const start = samples.items.len;
        decodeHead(gpa, io, path, want, &samples) catch |err| {
            std.debug.print("clip head failed for {s}: {s}\n", .{ path, @errorName(err) });
            samples.shrinkRetainingCapacity(start);
            span.* = .{ .start = start, .len = 0 };
            continue;
        };

        // The allowance is spent from the front of the clip, so the head is
        // where a capped pool's fade falls. Charging it here is also what tells
        // the streamer where to pick the clip up.
        var clip_limit = limit;
        const kept = clip_limit.take(samples.items[start..]);
        samples.shrinkRetainingCapacity(start + kept);
        span.* = .{ .start = start, .len = kept };
    }

    return .{
        .samples = try samples.toOwnedSlice(gpa),
        .spans = spans,
    };
}

/// How many bytes of `ffmpeg` output are read at a time. Startup work on a
/// thread nobody is listening to, so this is sized for few syscalls rather than
/// for a deadline.
const chunk_bytes = 64 * 1024;

/// Decode at most `want` samples from the front of one clip, appending them to
/// `samples`.
///
/// Blocking reads, unlike the streamer's: this runs before the audio sink
/// exists, so there is no deadline to miss and nothing to poll for.
///
/// Public so a test can decode a reference longer than a head and check the
/// streamer against it across the seam.
pub fn decodeHead(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    want: usize,
    samples: *std.ArrayList(f32),
) !void {
    // `-t` bounds the decode to roughly what is wanted, rounded up by a second
    // so the request is never the thing that cuts it short. Formatted rather
    // than a constant because a test asks for more than a head.
    var duration: [32]u8 = undefined;
    const seconds = try std.fmt.bufPrint(&duration, "{d}", .{
        want / core.sample_rate + 1,
    });

    var child = try std.process.spawn(io, .{
        .argv = &.{
            "ffmpeg",
            "-v",
            "error",
            "-i",
            path,
            "-af",
            filter,
            "-t",
            seconds,
            "-f",
            "f32le",
            "-ac",
            "1",
            "-ar",
            std.fmt.comptimePrint("{d}", .{core.sample_rate}),
            "-",
        },
        .stdout = .pipe,
    });
    var reaped = false;
    defer if (!reaped) {
        _ = linux.kill(child.id.?, linux.SIG.KILL);
        _ = child.wait(io) catch {};
    };

    const stdout = child.stdout orelse return error.NoDecoderOutput;

    // Counted from where this clip's head begins, not from the start of the
    // buffer: `samples` already holds every head decoded before this one.
    const start = samples.items.len;

    var bytes: [chunk_bytes]u8 align(@alignOf(f32)) = undefined;
    var pending: [@sizeOf(f32)]u8 = undefined;
    var pending_len: usize = 0;

    while (samples.items.len - start < want) {
        if (pending_len != 0) @memcpy(bytes[0..pending_len], pending[0..pending_len]);
        const rc = linux.read(stdout.handle, bytes[pending_len..].ptr, bytes.len - pending_len);
        if (linux.errno(rc) != .SUCCESS) return error.DecoderReadFailed;
        const read: usize = @intCast(rc);
        if (read == 0) break;

        const total = pending_len + read;
        const complete = total - total % @sizeOf(f32);
        const decoded = std.mem.bytesAsSlice(f32, bytes[0..complete]);
        const room = want - (samples.items.len - start);
        try samples.appendSlice(gpa, decoded[0..@min(room, decoded.len)]);

        pending_len = total - complete;
        if (pending_len != 0) @memcpy(pending[0..pending_len], bytes[complete..total]);
    }

    // `-t` bounds the output, so ffmpeg is expected to finish on its own; the
    // kill in the defer only covers a clip whose head filled the request first.
    if (samples.items.len - start < want) {
        const term = try child.wait(io);
        reaped = true;
        switch (term) {
            .exited => |code| if (code != 0) return error.DecoderFailed,
            else => return error.DecoderFailed,
        }
    }
}

test "an empty pool decodes to no heads" {
    var heads = try decode(std.testing.allocator, std.testing.io, &.{}, .unlimited, 44100);
    defer heads.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), heads.spans.len);
    try std.testing.expectEqual(@as(usize, 0), heads.get(0).len);
}

test "a clip index past the end has no head" {
    const heads: Heads = .none;
    try std.testing.expectEqual(@as(usize, 0), heads.get(7).len);
}

test "heads are handed out by index" {
    var samples = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    var spans = [_]Span{
        .{ .start = 0, .len = 2 },
        .{ .start = 2, .len = 3 },
    };
    const heads: Heads = .{ .samples = &samples, .spans = &spans };
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 2.0 }, heads.get(0));
    try std.testing.expectEqualSlices(f32, &.{ 3.0, 4.0, 5.0 }, heads.get(1));
}

test "every clip in a pool gets its own head" {
    const gpa = std.testing.allocator;
    var heads = try decode(gpa, std.testing.io, &.{
        "Bell Stems/Bell_01.wav",
        "Bell Stems/Bell_02.wav",
    }, .unlimited, 44100);
    defer heads.deinit(gpa);

    const want: usize = @intFromFloat(head_s * 44100.0);
    try std.testing.expectEqual(want, heads.get(0).len);
    try std.testing.expectEqual(want, heads.get(1).len);
    // Two different bells: a head buffer that hands the same audio to every
    // clip would pass the lengths and still be wrong.
    try std.testing.expect(!std.mem.eql(f32, heads.get(0), heads.get(1)));
}

test "a capped pool is pre-decoded whole, not just to the head length" {
    const gpa = std.testing.allocator;
    const limit: core.plant_b.Limit = .forPool(.bell, 44100);
    var heads = try decode(gpa, std.testing.io, &.{"Bell Stems/Bell_01.wav"}, limit, 44100);
    defer heads.deinit(gpa);

    // The whole allowance, so the streamer has nothing left to fetch and the
    // touch never waits on ffmpeg at all.
    try std.testing.expectEqual(limit.total, heads.get(0).len);
    try std.testing.expect(limit.total > @as(usize, @intFromFloat(head_s * 44100.0)));
}
