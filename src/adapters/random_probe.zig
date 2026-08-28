const std = @import("std");
const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");

const seed: u64 = 0x5EED;
const sample_rate: u64 = core.sample_rate;
const poll_frames: u64 = core.sensor_frames;
const idle_warmup_frames: u64 = sample_rate * 5;
const a_touch_frames: u64 = sample_rate * 2;
const idle_gap_frames: u64 = sample_rate * 2;
const bc_touch_frames: u64 = sample_rate * 2 / 5;
const bc_start_frames = idle_warmup_frames + a_touch_frames + idle_gap_frames;
const cycle_frames = idle_warmup_frames + a_touch_frames + idle_gap_frames +
    bc_touch_frames + idle_gap_frames;
const warmup_polls = (idle_warmup_frames + poll_frames - 1) / poll_frames;

pub const Adapter = struct {
    prng: std.Random.DefaultPrng,
    frames: u64,

    pub fn init() Adapter {
        return .{ .prng = std.Random.DefaultPrng.init(seed), .frames = 0 };
    }

    pub fn source(self: *Adapter) ports.ProbeSource {
        return .{
            .context = self,
            .read_fn = readPort,
            .deinit_fn = closePort,
        };
    }

    pub fn close(_: *Adapter) void {}

    fn readPort(context: *anyopaque, frames: usize) ports.Reading {
        const self: *Adapter = @ptrCast(@alignCast(context));
        return self.read(frames);
    }

    fn read(self: *Adapter, frames: usize) ports.Reading {
        const phase = self.frames % cycle_frames;
        const a_touch = phase >= idle_warmup_frames and
            phase < idle_warmup_frames + a_touch_frames;
        const bc_touch = phase >= bc_start_frames and
            phase < bc_start_frames + bc_touch_frames;

        const raw_a: i16 = if (a_touch)
            660
        else if (self.prng.random().boolean())
            -2049
        else
            -2050;
        const raw_bc: i16 = if (bc_touch)
            -2049
        else
            @intCast(self.prng.random().uintLessThan(u16, 2001));
        self.frames += @intCast(frames);
        return .{ .raw_a = raw_a, .raw_bc = raw_bc };
    }

    fn closePort(context: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.close();
    }
};

test "the probe is reproducible and reaches the A touch phase" {
    var first = Adapter.init();
    var second = Adapter.init();
    var first_source = first.source();
    var second_source = second.source();

    for (0..20) |_| {
        const a = first_source.read(core.sensor_frames);
        const b = second_source.read(core.sensor_frames);
        try std.testing.expectEqual(a.raw_a, b.raw_a);
        try std.testing.expectEqual(a.raw_bc, b.raw_bc);
    }

    var touch_probe = Adapter.init();
    var touch_source = touch_probe.source();
    for (0..warmup_polls) |_| _ = touch_source.read(core.sensor_frames);
    const touch = touch_source.read(core.sensor_frames);
    try std.testing.expectEqual(@as(i16, 660), touch.raw_a);
}

test "the probe reaches BC, releases, and repeats" {
    var adapter = Adapter.init();
    var source = adapter.source();

    while (adapter.frames < bc_start_frames) _ = source.read(core.sensor_frames);
    try std.testing.expectEqual(@as(i16, -2049), source.read(core.sensor_frames).raw_bc);

    while (adapter.frames < bc_start_frames + bc_touch_frames) {
        _ = source.read(core.sensor_frames);
    }
    try std.testing.expect(source.read(core.sensor_frames).raw_bc >= 0);

    while (adapter.frames < cycle_frames) _ = source.read(core.sensor_frames);
    try std.testing.expect(source.read(core.sensor_frames).raw_a != 660);
}

test "the simulated phases trigger both production touch states" {
    var adapter = Adapter.init();
    var source = adapter.source();
    var machine = core.touch.Machine.init(.{
        .sample_rate = core.sample_rate,
        .poll_frames = core.sensor_frames,
        .level_bc = 20.0,
        .hold_bc_ms = 30.0,
        .window_bc = .{ .ms = 1000.0 },
    });
    var saw_a = false;
    var saw_bc = false;

    const polls = @as(usize, @intCast(cycle_frames / poll_frames + 4));
    for (0..polls) |_| {
        const reading = source.read(core.sensor_frames);
        switch (machine.update(reading.raw_a, reading.raw_bc)) {
            .plant_a => saw_a = true,
            .plant_bc => saw_bc = true,
            .both => {
                saw_a = true;
                saw_bc = true;
            },
            .none => {},
        }
    }

    try std.testing.expect(saw_a);
    try std.testing.expect(saw_bc);
}
