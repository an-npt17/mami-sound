//! The per-poll record of why the machine decided what it did.
//!
//! A threshold that fires in an empty room, or refuses to fire on a hand, is
//! almost impossible to diagnose by standing next to it: the status line prints
//! once a second and the decision is made three hundred times in that second.
//! So every poll's numbers go to a file, and a wrong answer is replayed at a
//! desk instead of re-touched in the gallery.
//!
//! Formatting is separated from writing so the columns can be tested without a
//! filesystem.

const std = @import("std");
const touch = @import("core/touch.zig");

/// Enough for a poll's worth of columns, with room for the widest float.
const row_max = 256;

/// How much is held before it goes to the file. One block is four polls, so
/// this is a few hundred blocks: the disk is touched rarely and a crash loses
/// under a second.
const buffer_bytes = 64 * 1024;

pub const header =
    "t_s,raw_a,mean_a,base_a,mad_a,z_a,on_a,raw_bc,mean_bc,base_bc,mad_bc,z_bc,on_bc,state\n";

/// One row into `buf`, returned as the slice actually written.
pub fn format(
    buf: []u8,
    t_s: f64,
    raw_a: i16,
    a: *const touch.Detector,
    raw_bc: i16,
    bc: *const touch.Detector,
    state: touch.State,
) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{d:.3},{d},{d},{d},{d:.1},{d:.2},{d},{d},{d},{d},{d:.1},{d:.2},{d},{s}\n",
        .{
            t_s,
            raw_a,  a.last_mean,  a.base(),  a.baseline.mad,  a.z,  @intFromBool(a.on),
            raw_bc, bc.last_mean, bc.base(), bc.baseline.mad, bc.z, @intFromBool(bc.on),
            @tagName(state),
        },
    ) catch buf[0..0];
}

/// The file, and what has not reached it yet.
pub const Log = struct {
    file: std.Io.File,
    buf: [buffer_bytes]u8,
    len: usize,

    pub fn create(io: std.Io, path: []const u8) !Log {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        var log: Log = .{ .file = file, .buf = undefined, .len = 0 };
        @memcpy(log.buf[0..header.len], header);
        log.len = header.len;
        return log;
    }

    /// Add one poll. A failure here is dropped rather than reported: a full
    /// disk should cost the recording, never the installation's sound.
    pub fn row(
        self: *Log,
        io: std.Io,
        t_s: f64,
        raw_a: i16,
        a: *const touch.Detector,
        raw_bc: i16,
        bc: *const touch.Detector,
        state: touch.State,
    ) void {
        if (self.len + row_max > self.buf.len) self.flush(io);
        const written = format(self.buf[self.len..], t_s, raw_a, a, raw_bc, bc, state);
        self.len += written.len;
    }

    pub fn flush(self: *Log, io: std.Io) void {
        if (self.len == 0) return;
        self.file.writeStreamingAll(io, self.buf[0..self.len]) catch {};
        self.len = 0;
    }

    pub fn close(self: *Log, io: std.Io) void {
        self.flush(io);
        self.file.close(io);
    }
};

const testing = std.testing;

test "a row carries every number the decision was made from" {
    var buf: [512]u8 = undefined;
    var m = touch.Machine.init(.{ .sample_rate = 44100, .poll_frames = 128 });
    for (0..344 * 10) |_| _ = m.update(-2049, 900);

    const line = format(&buf, 1.5, -2049, &m.a, 900, &m.bc, .none);

    // The columns the header promises, in the order it promises them.
    var cols = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line, "\n"), ',');
    var n: usize = 0;
    while (cols.next()) |_| n += 1;
    var head = std.mem.splitScalar(u8, std.mem.trimEnd(u8, header, "\n"), ',');
    var head_n: usize = 0;
    while (head.next()) |_| head_n += 1;
    try testing.expectEqual(head_n, n);

    try testing.expect(std.mem.startsWith(u8, line, "1.500,-2049,"));
    try testing.expect(std.mem.endsWith(u8, line, ",none\n"));
}

test "the header names fourteen columns" {
    var head = std.mem.splitScalar(u8, std.mem.trimEnd(u8, header, "\n"), ',');
    var n: usize = 0;
    while (head.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 14), n);
}
