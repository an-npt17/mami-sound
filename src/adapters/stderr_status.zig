const std = @import("std");

const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");

const testing = std.testing;

pub const Adapter = struct {
    io: std.Io,
    last_ns: i96,
    next_frame: usize,
    peak: f32,

    const period = core.sample_rate;

    pub fn init(io: std.Io) Adapter {
        return .{
            .io = io,
            .last_ns = std.Io.Timestamp.now(io, .awake).nanoseconds,
            .next_frame = period,
            .peak = 0.0,
        };
    }

    pub fn port(self: *Adapter) ports.StatusSink {
        return .{
            .context = self,
            .observe_fn = observePort,
        };
    }

    fn updatePeak(self: *Adapter, block: []const f32) void {
        for (block) |sample| self.peak = @max(self.peak, @abs(sample));
    }

    fn reportDue(self: *Adapter, rendered: usize) bool {
        if (rendered < self.next_frame) return false;
        self.next_frame += period;
        return true;
    }

    fn resetPeak(self: *Adapter) void {
        self.peak = 0.0;
    }

    fn observePort(context: *anyopaque, snapshot: ports.Snapshot) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.observe(snapshot);
    }

    fn observe(self: *Adapter, snapshot: ports.Snapshot) void {
        self.updatePeak(snapshot.block);
        if (!self.reportDue(snapshot.rendered)) return;

        self.last_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const audio_s = @as(f64, @floatFromInt(snapshot.rendered)) /
            @as(f64, @floatFromInt(core.sample_rate));
        var line_buf: [128]u8 = undefined;
        const line = formatLine(&line_buf, snapshot, audio_s) catch return;
        std.debug.print("{s}", .{line});
        self.resetPeak();
    }
};

fn formatLine(
    buf: []u8,
    snapshot: ports.Snapshot,
    audio_s: f64,
) ![]u8 {
    const letters = [core.plant.count]u8{ 'A', 'B' };
    var touched: [core.plant.count]u8 = undefined;
    for (&touched, letters, snapshot.touched) |*out, letter, awake| {
        out.* = if (awake) letter else '-';
    }

    return std.fmt.bufPrint(buf, "t={d:.0}s a0={d} a1={d} z0={d:.1} z1={d:.1} {s} touch={s}\n", .{
        audio_s,
        snapshot.raw_a,
        snapshot.raw_bc,
        snapshot.z_a,
        snapshot.z_bc,
        @tagName(snapshot.state),
        &touched,
    });
}

test "status line formats signed readings, state, and both plant flags" {
    const block = [_]f32{ 0.25, -0.5 };
    const snapshot = ports.Snapshot{
        .raw_a = -10,
        .raw_bc = 20,
        .z_a = 1.5,
        .z_bc = -2.0,
        .state = .plant_a,
        .touched = .{ true, false },
        .block = &block,
        .rendered = core.sample_rate,
    };
    var buf: [128]u8 = undefined;

    const line = try formatLine(&buf, snapshot, 1.0);

    try testing.expectEqualStrings(
        "t=1s a0=-10 a1=20 z0=1.5 z1=-2.0 plant_a touch=A-\n",
        line,
    );
}

test "status schedules each completed second and resets the accumulated peak" {
    var status = Adapter{
        .io = undefined,
        .last_ns = 0,
        .next_frame = Adapter.period,
        .peak = 0.0,
    };

    status.updatePeak(&.{ 0.25, -0.75 });
    try testing.expectEqual(@as(f32, 0.75), status.peak);
    try testing.expect(!status.reportDue(Adapter.period - 1));
    try testing.expectEqual(Adapter.period, status.next_frame);
    try testing.expect(status.reportDue(Adapter.period));
    try testing.expectEqual(Adapter.period * 2, status.next_frame);

    status.resetPeak();
    try testing.expectEqual(@as(f32, 0.0), status.peak);
    status.updatePeak(&.{-0.5});
    try testing.expectEqual(@as(f32, 0.5), status.peak);
    try testing.expect(!status.reportDue(Adapter.period * 2 - 1));
    try testing.expect(status.reportDue(Adapter.period * 2));
}
