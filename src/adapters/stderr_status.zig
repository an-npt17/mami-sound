const std = @import("std");

const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");

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

    return std.fmt.bufPrint(
        buf,
        "t={d:.0}s a0={d} a1={d} l0={d} l1={d} r0={d} r1={d} z0={d:.1} z1={d:.1} state={s} touch={s}\n",
        .{
            audio_s,
            snapshot.raw_a,
            snapshot.raw_bc,
            snapshot.level_a,
            snapshot.level_bc,
            snapshot.rest_a,
            snapshot.rest_bc,
            snapshot.z_a,
            snapshot.z_bc,
            @tagName(snapshot.state),
            &touched,
        },
    );
}

test "formatLine labels runtime diagnostics" {
    const snapshot = ports.Snapshot{
        .raw_a = 12,
        .raw_bc = -34,
        .z_a = 1.5,
        .z_bc = -2.5,
        .rest_a = 660,
        .rest_bc = 1,
        .level_a = 662,
        .level_bc = 655,
        .state = .plant_bc,
        .touched = .{ true, false },
        .block = &.{},
        .rendered = 44100,
    };
    var buffer: [128]u8 = undefined;
    const line = try formatLine(&buffer, snapshot, 1.0);

    try std.testing.expectEqualStrings(
        "t=1s a0=12 a1=-34 l0=662 l1=655 r0=660 r1=1 z0=1.5 z1=-2.5 state=plant_bc touch=A-\n",
        line,
    );
}
