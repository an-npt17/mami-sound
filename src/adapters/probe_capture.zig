//! Writing down what the probes actually read, so a threshold can be chosen
//! from this rig rather than from the last one.
//!
//! `replay` has been able to read a capture since it was written, and nothing
//! has been able to make one: the file it was built against came from a version
//! of the status sink that has since been replaced, and the status line writes
//! one row a second where the detector runs at three hundred and forty-five.
//! So every threshold in the steady model was measured against a capture from a
//! different rig, taken before the bus was fixed, which opens with both plants
//! already held. This is how that stops.
//!
//! Recording happens on the audio thread, so it does no I/O at all: the
//! readings go into memory the whole run and reach the disk once, when the
//! capture is full. That last write is a block the audio thread spends not
//! rendering, which is a click -- once, at a moment the room can be told about,
//! in a mode nobody runs during a performance.

const std = @import("std");
const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");

pub const Adapter = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    /// Both probes per poll, interleaved. Preallocated: growing it mid-run
    /// would allocate on the audio thread.
    readings: []i16,
    used: usize,
    written: bool,

    /// A capture long enough to hold `seconds` of polls at the engine's rate.
    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        path: []const u8,
        wanted_s: f32,
    ) !Adapter {
        const polls_per_s = @as(f32, @floatFromInt(core.sample_rate)) /
            @as(f32, @floatFromInt(core.sensor_frames));
        const polls: usize = @intFromFloat(@max(wanted_s * polls_per_s, 1.0));

        return .{
            .io = io,
            .gpa = gpa,
            .path = path,
            .readings = try gpa.alloc(i16, polls * 2),
            .used = 0,
            .written = false,
        };
    }

    pub fn deinit(self: *Adapter) void {
        self.gpa.free(self.readings);
        self.* = undefined;
    }

    pub fn port(self: *Adapter) ports.ProbeCapture {
        return .{ .context = self, .record_fn = recordPort };
    }

    /// How much of the capture is spent, so the room can be told.
    pub fn seconds(self: *const Adapter) f32 {
        const polls_per_s = @as(f32, @floatFromInt(core.sample_rate)) /
            @as(f32, @floatFromInt(core.sensor_frames));
        return @as(f32, @floatFromInt(self.used / 2)) / polls_per_s;
    }

    pub fn full(self: *const Adapter) bool {
        return self.used >= self.readings.len;
    }

    /// One poll of both probes. Silent once the capture is full: a diagnostic
    /// that stopped the piece to complain would be a worse diagnostic.
    pub fn record(self: *Adapter, raw_a: i16, raw_bc: i16) void {
        if (self.full()) {
            self.flush();
            return;
        }
        self.readings[self.used] = raw_a;
        self.readings[self.used + 1] = raw_bc;
        self.used += 2;
    }

    /// Write the capture out, once. Failure is reported and not retried: the
    /// run is not the capture's, and a diagnostic that took the room down would
    /// be a poor trade.
    pub fn flush(self: *Adapter) void {
        if (self.written) return;
        self.written = true;

        self.write() catch |err| {
            std.debug.print("capture not written to {s}: {s}\n", .{ self.path, @errorName(err) });
            return;
        };
        std.debug.print(
            "capture written: {s} ({d} polls, {d:.0}s)\n",
            .{ self.path, self.used / 2, self.seconds() },
        );
    }

    fn write(self: *Adapter) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);

        // The columns `replay` reads, and the header it finds them by.
        try text.appendSlice(self.gpa, "t_s,raw_a,raw_bc\n");

        const polls_per_s = @as(f32, @floatFromInt(core.sample_rate)) /
            @as(f32, @floatFromInt(core.sensor_frames));
        var poll: usize = 0;
        while (poll * 2 < self.used) : (poll += 1) {
            try text.print(self.gpa, "{d:.3},{d},{d}\n", .{
                @as(f32, @floatFromInt(poll)) / polls_per_s,
                self.readings[poll * 2],
                self.readings[poll * 2 + 1],
            });
        }

        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.path,
            .data = text.items,
        });
    }

    fn recordPort(context: *anyopaque, raw_a: i16, raw_bc: i16) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.record(raw_a, raw_bc);
    }
};

test "a capture holds the seconds it was asked for" {
    const gpa = std.testing.allocator;
    var adapter = try Adapter.init(std.testing.io, gpa, "unused.csv", 2.0);
    defer adapter.deinit();

    // Two seconds of polls, both probes each. The rate is not a whole number,
    // so this is computed the way the adapter computes it rather than rounded.
    const polls_per_s = @as(f32, @floatFromInt(core.sample_rate)) /
        @as(f32, @floatFromInt(core.sensor_frames));
    const polls: usize = @intFromFloat(2.0 * polls_per_s);
    try std.testing.expectEqual(polls * 2, adapter.readings.len);
    try std.testing.expect(!adapter.full());
}

test "readings go in in order, and both probes keep their own column" {
    const gpa = std.testing.allocator;
    var adapter = try Adapter.init(std.testing.io, gpa, "unused.csv", 1.0);
    defer adapter.deinit();

    adapter.record(660, 1);
    adapter.record(661, 2);

    try std.testing.expectEqual(@as(i16, 660), adapter.readings[0]);
    try std.testing.expectEqual(@as(i16, 1), adapter.readings[1]);
    try std.testing.expectEqual(@as(i16, 661), adapter.readings[2]);
    try std.testing.expectEqual(@as(i16, 2), adapter.readings[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 * 128.0 / 44100.0), adapter.seconds(), 0.001);
}

test "a full capture stops taking readings rather than growing" {
    // Growing it would allocate on the audio thread, and the run belongs to the
    // piece rather than to the diagnostic.
    const gpa = std.testing.allocator;
    var adapter = try Adapter.init(std.testing.io, gpa, "unused.csv", 0.01);
    defer adapter.deinit();

    // Marked written so the full capture does not try to reach the disk.
    adapter.written = true;

    const room = adapter.readings.len / 2;
    for (0..room + 50) |_| adapter.record(1, 2);

    try std.testing.expect(adapter.full());
    try std.testing.expectEqual(adapter.readings.len, adapter.used);
}
