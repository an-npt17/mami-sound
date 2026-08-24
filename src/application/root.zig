const std = @import("std");

const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");
const engine = @import("engine.zig");
const production_config = @import("production_config.zig");

const testing = std.testing;

const FakeProbe = struct {
    reading: ports.Reading,
    calls: usize = 0,
    frames: [core.block_frames / core.sensor_frames]usize = undefined,

    fn read(context: *anyopaque, frames: usize) ports.Reading {
        const self: *FakeProbe = @ptrCast(@alignCast(context));
        self.frames[self.calls] = frames;
        self.calls += 1;
        return self.reading;
    }

    fn deinit(_: *anyopaque) void {}

    fn source(self: *FakeProbe) ports.ProbeSource {
        return .{
            .context = self,
            .read_fn = read,
            .deinit_fn = deinit,
        };
    }
};

const FakeAudio = struct {
    writes: usize = 0,
    lengths: [4]usize = undefined,
    last: [core.block_frames]i16 = undefined,

    fn write(context: *anyopaque, frames: []const i16) anyerror!void {
        const self: *FakeAudio = @ptrCast(@alignCast(context));
        self.lengths[self.writes] = frames.len;
        self.writes += 1;
        @memcpy(&self.last, frames);
    }

    fn finish(_: *anyopaque) anyerror!void {}

    fn sink(self: *FakeAudio) ports.AudioSink {
        return .{
            .context = self,
            .write_fn = write,
            .finish_fn = finish,
        };
    }
};

const FakeStatus = struct {
    observed: usize = 0,
    last: ?ports.Snapshot = null,

    fn observe(context: *anyopaque, snapshot: ports.Snapshot) void {
        const self: *FakeStatus = @ptrCast(@alignCast(context));
        self.observed += 1;
        self.last = snapshot;
    }

    fn sink(self: *FakeStatus) ports.StatusSink {
        return .{
            .context = self,
            .observe_fn = observe,
        };
    }
};

fn random() std.Random {
    var prng = std.Random.DefaultPrng.init(1);
    return prng.random();
}

fn primeBc(engine_under_test: *engine.Engine) void {
    engine_under_test.machine.a.baseline.count = 30;
    engine_under_test.machine.a.baseline.base = -2049;
    engine_under_test.machine.a.baseline.mad = 1.0;
    engine_under_test.machine.bc.baseline.count = 30;
    engine_under_test.machine.bc.baseline.base = 1000;
    engine_under_test.machine.bc.baseline.mad = 1.0;
    engine_under_test.machine.bc.count = 1;
    engine_under_test.machine.bc.on = true;
    engine_under_test.machine.bc.armed = true;
}

test "production config keeps the fixed installation tuning" {
    try testing.expectEqual(@as(u32, 44100), production_config.touch.sample_rate);
    try testing.expectEqual(@as(usize, 128), production_config.touch.poll_frames);
    try testing.expectEqual(core.touch.Model.deviation, production_config.touch.model);
    try testing.expectEqual(@as(f32, 20.0), production_config.touch.level_bc.?);
    try testing.expectEqual(@as(f32, 30.0), production_config.touch.hold_bc_ms.?);
    try testing.expectEqual(@as(f32, 1000.0), production_config.touch.window_bc_ms.?);
    try testing.expectEqual(@as(i16, 3000), production_config.drone.span);
    try testing.expectEqual(@as(f32, 0.15), production_config.drone.jump);
    try testing.expectEqual(@as(f32, 4.0), production_config.drone.glide_s);
    try testing.expectEqual(@as(f32, 0.5), production_config.drone.release_s.?);
    try testing.expectEqual(@as(u64, 0xC0FFEE), production_config.seed);
}

test "step polls each sensor piece, writes one PCM block, and reports one snapshot" {
    var fake_probe = FakeProbe{ .reading = .{ .raw_a = -2049, .raw_bc = 123 } };
    var fake_audio = FakeAudio{};
    var fake_status = FakeStatus{};
    var app = engine.Engine.init(
        core.plant.all,
        fake_probe.source(),
        fake_audio.sink(),
        fake_status.sink(),
        &.{},
        random(),
    );

    try app.step();

    try testing.expectEqual(@as(usize, core.block_frames / core.sensor_frames), fake_probe.calls);
    for (fake_probe.frames) |frames| try testing.expectEqual(core.sensor_frames, frames);
    try testing.expectEqual(@as(usize, 1), fake_audio.writes);
    try testing.expectEqual(@as(usize, core.block_frames), fake_audio.lengths[0]);
    try testing.expectEqual(@as(usize, 1), fake_status.observed);
    try testing.expectEqual(core.block_frames, app.block.len);
    try testing.expectEqual(core.block_frames, app.pcm.len);
    try testing.expectEqual(core.block_frames, app.rendered);
    try testing.expectEqual(core.block_frames, fake_status.last.?.block.len);
    try testing.expectEqualSlices(i16, &app.pcm, &fake_audio.last);
    try testing.expectEqual(core.touch.State.none, fake_status.last.?.state);
    try testing.expectEqual(.{ false, false }, fake_status.last.?.touched);
    try testing.expectEqual(@as(i16, -2049), fake_status.last.?.raw_a);
    try testing.expectEqual(@as(i16, 123), fake_status.last.?.raw_bc);
    try testing.expect(fake_status.last.?.z_a < 0.0);
    try testing.expect(fake_status.last.?.z_bc > 0.0);
}

test "step renders the selected Plant B clip" {
    const clips = [_][]const f32{&([_]f32{0.5} ** core.block_frames)};
    var fake_probe = FakeProbe{ .reading = .{ .raw_a = -2049, .raw_bc = 1000 } };
    var fake_audio = FakeAudio{};
    var fake_status = FakeStatus{};
    var app = engine.Engine.init(
        .{ false, true },
        fake_probe.source(),
        fake_audio.sink(),
        fake_status.sink(),
        &clips,
        random(),
    );
    primeBc(&app);

    try app.step();

    try testing.expectEqual(@as(usize, core.block_frames), app.plant_b.position());
    try testing.expectEqual(@as(usize, 1), fake_audio.writes);
    try testing.expectEqual(core.block_frames, fake_status.last.?.rendered);
}

test "step does not start Plant B when only Plant A is selected" {
    var fake_probe = FakeProbe{ .reading = .{ .raw_a = -2049, .raw_bc = 1000 } };
    var fake_audio = FakeAudio{};
    var fake_status = FakeStatus{};
    var app = engine.Engine.init(
        .{ true, false },
        fake_probe.source(),
        fake_audio.sink(),
        fake_status.sink(),
        &.{&([_]f32{0.5} ** core.block_frames)},
        random(),
    );
    primeBc(&app);

    try app.step();

    try testing.expectEqual(@as(usize, 0), app.plant_b.position());
    try testing.expectEqual(.{ false, false }, fake_status.last.?.touched);
}

test {
    _ = engine;
    _ = production_config;
}
