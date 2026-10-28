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

/// What a touch on plant A looks like.
pub const Style = enum {
    /// Held still at one level, as the steady and deviation rigs read a hand.
    steady,
    /// The installed rig: plant A rests near nought and a hand flips it
    /// between home and the far rail, spending a wandering share of the time
    /// at the rail. This is what the `learned` model was written for, and the
    /// share's wander is what the drone's wobble follows -- a touch held at one
    /// level gives the wobble nothing to follow and the climb a clean line.
    rig,
};

/// The rig style's touch is longer, so a slow climb has room to be heard, and
/// the rest around it longer still. The learned model takes the level the
/// probe spends most of its time at as rest, and the room is mostly nobody:
/// a cycle that was mostly hand taught the model the rail as rest, and then
/// the idle probe read as a touch.
const rig_touch_frames: u64 = sample_rate * 8;
const rig_idle_frames: u64 = sample_rate * 20;
const rig_bc_start_frames = rig_idle_frames + rig_touch_frames + idle_gap_frames;
const rig_cycle_frames = rig_bc_start_frames + bc_touch_frames + idle_gap_frames;

/// The rig's two levels for plant A, off the room's own journal: a held probe
/// ran 25886, 735, 10, 12, 25886 through a single touch.
const rig_rail: i16 = 25886;
const rig_home_max: u16 = 740;

/// How the share at the rail wanders through a touch: around three quarters,
/// a slow random walk of about a tenth either way. Sized so the learned
/// model's window share wanders the way it does on probes-box2.csv, and never
/// drops to the 0.4 that would release the touch.
const rig_share_mean: f32 = 0.75;
const rig_share_sd: f32 = 0.12;
const rig_share_tau_s: f32 = 0.6;
const rig_share_min: f32 = 0.55;

pub const Adapter = struct {
    prng: std.Random.DefaultPrng,
    frames: u64,
    style: Style,
    /// The chance this poll lands on the rail, during a rig-style touch.
    rail_chance: f32,

    pub fn init() Adapter {
        return initStyle(.steady);
    }

    pub fn initStyle(style: Style) Adapter {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .frames = 0,
            .style = style,
            .rail_chance = rig_share_mean,
        };
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
        if (self.style == .rig) return self.readRig(frames);
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

    fn readRig(self: *Adapter, frames: usize) ports.Reading {
        const rand = self.prng.random();
        const phase = self.frames % rig_cycle_frames;
        const a_touch = phase >= rig_idle_frames and
            phase < rig_idle_frames + rig_touch_frames;
        const bc_touch = phase >= rig_bc_start_frames and
            phase < rig_bc_start_frames + bc_touch_frames;

        var raw_a: i16 = @intCast(rand.uintLessThan(u16, 3));
        if (a_touch) {
            // Ornstein-Uhlenbeck, one step a poll: pulled back to the mean,
            // kicked by noise sized to hold the walk's spread at `sd`.
            const dt = @as(f32, @floatFromInt(frames)) / @as(f32, @floatFromInt(sample_rate));
            const kick = rand.floatNorm(f32) * rig_share_sd * @sqrt(2.0 * dt / rig_share_tau_s);
            self.rail_chance += (rig_share_mean - self.rail_chance) * dt / rig_share_tau_s + kick;
            self.rail_chance = std.math.clamp(self.rail_chance, rig_share_min, 1.0);
            raw_a = if (rand.float(f32) < self.rail_chance)
                rig_rail
            else
                @intCast(rand.uintLessThan(u16, rig_home_max));
        } else {
            self.rail_chance = rig_share_mean;
        }
        const raw_bc: i16 = if (bc_touch)
            -2049
        else
            @intCast(rand.uintLessThan(u16, 2001));
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

test "the rig style is held through its touch by the learned model, with a share that wanders" {
    var adapter = Adapter.initStyle(.rig);
    var source = adapter.source();
    var machine = core.touch.Machine.init(.{
        .sample_rate = core.sample_rate,
        .poll_frames = core.sensor_frames,
        .model = .learned,
    });

    // Two cycles: the first touch teaches the model the rail, the second is
    // the one measured.
    const polls = @as(usize, @intCast(2 * rig_cycle_frames / poll_frames));
    var latched: usize = 0;
    var share_lo: f32 = 1.0;
    var share_hi: f32 = 0.0;
    for (0..polls) |poll| {
        const reading = source.read(core.sensor_frames);
        const state = machine.update(reading.raw_a, reading.raw_bc);
        if (poll * poll_frames < rig_cycle_frames) continue;
        const phase = (poll * poll_frames) % rig_cycle_frames;
        const touching = phase >= rig_idle_frames and phase < rig_idle_frames + rig_touch_frames;
        // Nobody on it is nobody on it: idle must never read as a touch, bar
        // the moment the window takes to see the hand has gone.
        const releasing = phase >= rig_idle_frames + rig_touch_frames and
            phase < rig_idle_frames + rig_touch_frames + sample_rate;
        if (!touching) {
            if (!releasing) try std.testing.expect(state != .plant_a and state != .both);
            continue;
        }
        if (state == .plant_a or state == .both) {
            latched += 1;
            if (machine.a.share()) |share| {
                share_lo = @min(share_lo, share);
                share_hi = @max(share_hi, share);
            }
        }
    }

    // Most of the eight seconds is one latched hold...
    const touch_polls = rig_touch_frames / poll_frames;
    try std.testing.expect(latched > touch_polls * 3 / 4);
    // ...and the share moves inside it, which is all the wobble needs.
    try std.testing.expect(share_hi - share_lo > 0.1);
}
