//! A probe that plays a capture back instead of reading the ADS1115.
//!
//! `--test-random-probe` is a probe nobody's hand was ever on: it holds a
//! touch at one level, so the `learned` model's share sits still and the
//! drone climbs a clean line. A capture is the rig as the room met it -- the
//! rail flipping through a hold, the share wandering -- and playing one back
//! through the real detector and the real drone is the only bench that sounds
//! like the room without going to it.
//!
//! One row per poll, which is how `--capture` writes them, so the sink's pace
//! is the capture's pace and a hold lasts as long as it did. At the end the
//! capture starts again.

const std = @import("std");
const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");

pub const Error = error{ MissingColumn, EmptyCapture };

/// Which column holds what, read off the header: a later status sink may have
/// gained columns, as replay.zig also allows for.
const Columns = struct {
    raw_a: usize,
    raw_bc: usize,

    fn parse(header: []const u8) Error!Columns {
        var raw_a: ?usize = null;
        var raw_bc: ?usize = null;
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, header, " \r\n"), ',');
        var index: usize = 0;
        while (it.next()) |name| : (index += 1) {
            if (std.mem.eql(u8, name, "raw_a")) raw_a = index;
            if (std.mem.eql(u8, name, "raw_bc")) raw_bc = index;
        }
        return .{
            .raw_a = raw_a orelse return Error.MissingColumn,
            .raw_bc = raw_bc orelse return Error.MissingColumn,
        };
    }
};

/// One row's two readings, or null for a short or garbled row, which a
/// capture taken across a restart has and which is no reason to refuse it.
fn parseRow(columns: Columns, line: []const u8) ?ports.Reading {
    var raw_a: ?i16 = null;
    var raw_bc: ?i16 = null;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \r\n"), ',');
    var index: usize = 0;
    while (it.next()) |field| : (index += 1) {
        if (index == columns.raw_a) raw_a = std.fmt.parseInt(i16, field, 10) catch return null;
        if (index == columns.raw_bc) raw_bc = std.fmt.parseInt(i16, field, 10) catch return null;
    }
    return .{ .raw_a = raw_a orelse return null, .raw_bc = raw_bc orelse return null };
}

pub const Adapter = struct {
    gpa: std.mem.Allocator,
    readings: []ports.Reading,
    next: usize,
    /// How many times the capture has come round, so a long bench run can say
    /// which pass it is on.
    passes: u32,

    pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Adapter {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
        defer gpa.free(text);
        return fromText(gpa, text);
    }

    pub fn fromText(gpa: std.mem.Allocator, text: []const u8) !Adapter {
        var lines = std.mem.splitScalar(u8, text, '\n');
        const columns = try Columns.parse(lines.next() orelse return Error.EmptyCapture);

        var list: std.ArrayList(ports.Reading) = .empty;
        errdefer list.deinit(gpa);
        while (lines.next()) |line| {
            if (parseRow(columns, line)) |reading| try list.append(gpa, reading);
        }
        if (list.items.len == 0) return Error.EmptyCapture;
        return .{
            .gpa = gpa,
            .readings = try list.toOwnedSlice(gpa),
            .next = 0,
            .passes = 0,
        };
    }

    pub fn seconds(self: *const Adapter) f32 {
        const polls = @as(f32, @floatFromInt(self.readings.len));
        return polls * @as(f32, @floatFromInt(core.sensor_frames)) /
            @as(f32, @floatFromInt(core.sample_rate));
    }

    pub fn source(self: *Adapter) ports.ProbeSource {
        return .{
            .context = self,
            .read_fn = readPort,
            .deinit_fn = closePort,
        };
    }

    pub fn close(self: *Adapter) void {
        self.gpa.free(self.readings);
        self.readings = &.{};
    }

    fn readPort(context: *anyopaque, frames: usize) ports.Reading {
        const self: *Adapter = @ptrCast(@alignCast(context));
        return self.read(frames);
    }

    /// The next poll's readings. `frames` is not consulted: the engine polls
    /// in `sensor_frames`, and so did the run that wrote the capture.
    fn read(self: *Adapter, _: usize) ports.Reading {
        const reading = self.readings[self.next];
        self.next += 1;
        if (self.next == self.readings.len) {
            self.next = 0;
            self.passes += 1;
            std.debug.print("probe file: end of capture, starting pass {d}\n", .{self.passes + 1});
        }
        return reading;
    }

    fn closePort(context: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.close();
    }
};

test "a capture plays back row by row and starts again at the end" {
    var probe = try Adapter.fromText(std.testing.allocator,
        \\t_s,raw_a,raw_bc
        \\0.000,1,0
        \\0.003,25886,12
        \\0.006,735,-3
        \\
    );
    defer probe.close();
    var src = probe.source();

    const want = [_][2]i16{ .{ 1, 0 }, .{ 25886, 12 }, .{ 735, -3 }, .{ 1, 0 } };
    for (want) |w| {
        const r = src.read(core.sensor_frames);
        try std.testing.expectEqual(w[0], r.raw_a);
        try std.testing.expectEqual(w[1], r.raw_bc);
    }
    try std.testing.expectEqual(@as(u32, 1), probe.passes);
}

test "columns are found by name, and a garbled row is skipped" {
    // A later sink wrote more columns and in another order; a restart left a
    // short line. Neither is a reason to refuse the capture.
    var probe = try Adapter.fromText(std.testing.allocator,
        \\raw_bc,state,raw_a
        \\7,none,100
        \\8,none
        \\9,held,25000
    );
    defer probe.close();
    try std.testing.expectEqual(@as(usize, 2), probe.readings.len);
    try std.testing.expectEqual(@as(i16, 25000), probe.readings[1].raw_a);
    try std.testing.expectEqual(@as(i16, 9), probe.readings[1].raw_bc);
}

test "a capture without the readings is refused" {
    try std.testing.expectError(Error.MissingColumn, Adapter.fromText(std.testing.allocator, "t_s,state\n0,none\n"));
    try std.testing.expectError(Error.EmptyCapture, Adapter.fromText(std.testing.allocator, "raw_a,raw_bc\n"));
    try std.testing.expectError(Error.MissingColumn, Adapter.fromText(std.testing.allocator, ""));
}
