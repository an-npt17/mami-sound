const std = @import("std");

const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");
const production_config = @import("production_config.zig");

pub const Engine = struct {
    selection: core.plant.Selection,
    probe: ports.ProbeSource,
    sink: ports.AudioSink,
    status: ports.StatusSink,
    machine: core.touch.Machine,
    drone: core.noise.Noise,
    plant_b: core.plant_b.ClipSelector,
    clip_stream: ports.ClipStream,
    block: [core.block_frames]f32,
    pcm: [core.block_frames]i16,
    rendered: usize,

    pub fn init(
        selection: core.plant.Selection,
        touch_config: core.touch.Config,
        probe: ports.ProbeSource,
        sink: ports.AudioSink,
        status: ports.StatusSink,
        clip_stream: ports.ClipStream,
        /// Which folder each clip in the pool came from, so a touch can move to
        /// the other one.
        clip_folders: []const u8,
        random: std.Random,
    ) Engine {
        return .{
            .selection = selection,
            .probe = probe,
            .sink = sink,
            .status = status,
            .machine = core.touch.Machine.init(touch_config),
            .drone = core.noise.Noise.init(
                core.sample_rate,
                production_config.seed,
                production_config.drone,
            ),
            .plant_b = core.plant_b.ClipSelector.init(clip_folders, core.sample_rate, random),
            .clip_stream = clip_stream,
            .block = undefined,
            .pcm = undefined,
            .rendered = 0,
        };
    }

    pub fn step(self: *Engine) !void {
        @memset(&self.block, 0);
        var raw_a: i16 = 0;
        var raw_bc: i16 = 0;
        var state: core.touch.State = .none;
        var touched: core.plant.Selection = undefined;

        var offset: usize = 0;
        while (offset < self.block.len) : (offset += core.sensor_frames) {
            const piece = self.block[offset..][0..core.sensor_frames];
            const reading = self.probe.read(core.sensor_frames);
            raw_a = reading.raw_a;
            raw_bc = reading.raw_bc;
            const detected = self.machine.update(raw_a, raw_bc);
            touched = core.select.apply(self.selection, .{
                detected == .plant_a or detected == .both,
                detected == .plant_bc or detected == .both,
            });
            state = detected;
            if (self.selection[0]) {
                self.drone.render(piece, self.machine.a.deviation(), touched[0]);
            }
            // Asked before rendering, so the answer is about the clip already
            // running rather than about the one this poll might start.
            const sounding = self.clip_stream.sounding();
            const request = if (self.selection[1])
                self.plant_b.start(touched[1], sounding, core.sensor_frames)
            else
                null;
            self.clip_stream.render(piece, request);
        }

        core.pcm.toPcm(&self.block, &self.pcm);
        try self.sink.write(&self.pcm);
        self.rendered += core.block_frames;
        self.status.observe(.{
            .raw_a = raw_a,
            .raw_bc = raw_bc,
            .z_a = self.machine.a.z,
            .z_bc = self.machine.bc.z,
            .state = state,
            .touched = touched,
            .block = &self.block,
            .rendered = self.rendered,
        });
    }

    pub fn run(self: *Engine) !void {
        while (true) try self.step();
    }
};

const testing = std.testing;

/// A probe that reads back whatever the test wants it to, one pattern per
/// poll. The engine polls four times a block, so a pattern indexed by poll is
/// what puts a shape on the readings rather than on the blocks.
const FakeProbe = struct {
    poll: usize = 0,
    pattern: *const fn (usize) ports.Reading,

    fn read(context: *anyopaque, _: usize) ports.Reading {
        const self: *FakeProbe = @ptrCast(@alignCast(context));
        const reading = self.pattern(self.poll);
        self.poll += 1;
        return reading;
    }

    fn source(self: *FakeProbe) ports.ProbeSource {
        return .{ .context = self, .read_fn = read, .deinit_fn = ignoreDeinit };
    }

    fn ignoreDeinit(_: *anyopaque) void {}
};

/// Collects how loud the engine's output was, which is the only thing these
/// tests ask about.
const FakeSink = struct {
    peak: i16 = 0,
    energy: f64 = 0.0,
    blocks: usize = 0,

    fn write(context: *anyopaque, frames: []const i16) anyerror!void {
        const self: *FakeSink = @ptrCast(@alignCast(context));
        self.blocks += 1;
        for (frames) |frame| {
            self.peak = @max(self.peak, @as(i16, @intCast(@abs(@as(i32, frame)))));
            self.energy += @as(f64, @floatFromInt(@as(i32, frame) * @as(i32, frame)));
        }
    }

    fn finish(_: *anyopaque) anyerror!void {}

    fn port(self: *FakeSink) ports.AudioSink {
        return .{ .context = self, .write_fn = write, .finish_fn = finish };
    }

    /// Root mean square of everything written, in full-scale units.
    fn rms(self: *const FakeSink) f64 {
        const samples = self.blocks * core.block_frames;
        if (samples == 0) return 0.0;
        return @sqrt(self.energy / @as(f64, @floatFromInt(samples))) / 32767.0;
    }
};

fn ignoreStatus(_: *anyopaque, _: ports.Snapshot) void {}
fn ignoreClips(_: *anyopaque, _: []f32, _: ?usize) void {}
fn neverSounding(_: *anyopaque) bool {
    return false;
}

/// A probe A held at a level, with the dropouts this rig throws through it.
/// Probe BC is left flailing, so nothing here depends on plant B.
fn heldA(poll: usize) ports.Reading {
    return .{
        .raw_a = switch (poll % 8) {
            6 => 640,
            7 => -4095,
            else => 662,
        },
        .raw_bc = if (poll % 2 == 0) -4096 else 1,
    };
}

/// Both probes left alone: flipping between a rail and a zero, which is what
/// the Pi's journal shows when nobody is in the room.
fn untouched(poll: usize) ports.Reading {
    const value: i16 = if (poll % 2 == 0) -4096 else 1;
    return .{ .raw_a = value, .raw_bc = value };
}

/// Blocks enough to fill the steady model's window and satisfy its hold. Four
/// polls a block, a window of a second, and a hold on top of that.
const warmup_blocks: usize = 400;

fn runPlantA(pattern: *const fn (usize) ports.Reading, blocks: usize) !FakeSink {
    var probe: FakeProbe = .{ .pattern = pattern };
    var sink: FakeSink = .{};
    const status: ports.StatusSink = .{ .context = &sink, .observe_fn = ignoreStatus };
    const clips: ports.ClipStream = .{
        .context = &sink,
        .render_fn = ignoreClips,
        .sounding_fn = neverSounding,
    };
    var prng = std.Random.DefaultPrng.init(1);

    var app = Engine.init(
        // Plant A only, so anything heard is plant A's drone and not a clip.
        .{ true, false },
        .{
            .sample_rate = core.sample_rate,
            .poll_frames = core.sensor_frames,
            .model = .steady,
        },
        probe.source(),
        sink.port(),
        status,
        clips,
        &.{},
        prng.random(),
    );

    for (0..blocks) |_| try app.step();
    return sink;
}

test "a held probe A opens the drone's gate, not just its pitch" {
    // The thing the room asks for: a hand on plant A must be heard. Measured
    // against the same engine left alone rather than against silence, because
    // the drone idles rather than stopping.
    //
    // The numbers this is pitched between, from this test: held reads an RMS of
    // 0.032 against an idle 0.0089, and with the touch withheld from the voice
    // -- the gate shut, the pitch still moving -- it reads 0.012. A ratio of
    // two and a half sits above what the pitch alone can produce and well under
    // what the gate does, so the test says the gate opened and not merely that
    // something changed.
    const held = try runPlantA(heldA, warmup_blocks);
    const idle = try runPlantA(untouched, warmup_blocks);

    try testing.expect(held.rms() > idle.rms() * 2.5);
    try testing.expect(held.peak > idle.peak * 3);
}

test "plant A is audible at all rather than a quiet gate opening on nothing" {
    // A drone that never left zero would pass a ratio against another silence,
    // so the level is also asked for outright. A tenth of full scale is a peak
    // the idle voice cannot reach: it reads 873 against the held voice's 4264.
    const held = try runPlantA(heldA, warmup_blocks);
    try testing.expect(held.rms() > 0.02);
    try testing.expect(held.peak > 3276);
}

test "an untouched plant A stays at its idle" {
    const idle = try runPlantA(untouched, warmup_blocks);
    try testing.expect(idle.rms() < 0.015);
    try testing.expect(idle.peak < 2000);
}
