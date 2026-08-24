const std = @import("std");
pub const audio_sink = @import("audio_sink.zig");
pub const probe_source = @import("probe_source.zig");
pub const status_sink = @import("status_sink.zig");

const testing = std.testing;

pub const ProbeSource = probe_source.ProbeSource;
pub const Reading = probe_source.Reading;
pub const AudioSink = audio_sink.AudioSink;
pub const Snapshot = status_sink.Snapshot;
pub const StatusSink = status_sink.StatusSink;

const FakeProbe = struct {
    readings: []const probe_source.Reading,
    next: usize = 0,
    deinit_count: usize = 0,

    fn read(context: *anyopaque, frames: usize) probe_source.Reading {
        const self: *FakeProbe = @ptrCast(@alignCast(context));
        _ = frames;
        const reading = self.readings[self.next];
        self.next += 1;
        return reading;
    }

    fn deinit(context: *anyopaque) void {
        const self: *FakeProbe = @ptrCast(@alignCast(context));
        self.deinit_count += 1;
    }
};

const FakeAudio = struct {
    writes: usize = 0,
    frames: usize = 0,
    finished: bool = false,

    fn write(context: *anyopaque, frames: []const i16) anyerror!void {
        const self: *FakeAudio = @ptrCast(@alignCast(context));
        self.writes += 1;
        self.frames += frames.len;
    }

    fn finish(context: *anyopaque) anyerror!void {
        const self: *FakeAudio = @ptrCast(@alignCast(context));
        self.finished = true;
    }
};

const FakeStatus = struct {
    observed: usize = 0,
    last_state: ?status_sink.Snapshot = null,

    fn observe(context: *anyopaque, snapshot: status_sink.Snapshot) void {
        const self: *FakeStatus = @ptrCast(@alignCast(context));
        self.observed += 1;
        self.last_state = snapshot;
    }
};

test "probe port dispatches reads and deinitialization" {
    const readings = [_]probe_source.Reading{
        .{ .raw_a = -10, .raw_bc = 20 },
        .{ .raw_a = -11, .raw_bc = 21 },
    };
    var fake = FakeProbe{ .readings = &readings };
    var source = probe_source.ProbeSource{
        .context = &fake,
        .read_fn = FakeProbe.read,
        .deinit_fn = FakeProbe.deinit,
    };

    try testing.expectEqual(readings[0], source.read(512));
    try testing.expectEqual(readings[1], source.read(128));
    source.deinit();
    try testing.expectEqual(@as(usize, 1), fake.deinit_count);
}

test "audio port dispatches writes and finish" {
    var fake = FakeAudio{};
    var sink = audio_sink.AudioSink{
        .context = &fake,
        .write_fn = FakeAudio.write,
        .finish_fn = FakeAudio.finish,
    };
    const frames = [_]i16{ 1, -2, 3 };

    try sink.write(&frames);
    try sink.write(frames[0..1]);
    try sink.finish();

    try testing.expectEqual(@as(usize, 2), fake.writes);
    try testing.expectEqual(@as(usize, 4), fake.frames);
    try testing.expect(fake.finished);
}

test "status port dispatches semantic snapshots" {
    var fake = FakeStatus{};
    var sink = status_sink.StatusSink{
        .context = &fake,
        .observe_fn = FakeStatus.observe,
    };
    const block = [_]f32{ 0.25, -0.5 };
    const snapshot = status_sink.Snapshot{
        .raw_a = -10,
        .raw_bc = 20,
        .z_a = 1.5,
        .z_bc = -2.0,
        .state = .plant_a,
        .touched = .{ true, false },
        .block = &block,
        .rendered = 512,
    };

    sink.observe(snapshot);

    try testing.expectEqual(@as(usize, 1), fake.observed);
    try testing.expectEqual(snapshot.state, fake.last_state.?.state);
    try testing.expectEqual(snapshot.rendered, fake.last_state.?.rendered);
}
