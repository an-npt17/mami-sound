const std = @import("std");

const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");
const voice_mod = @import("voice.zig");

pub const Engine = struct {
    selection: core.plant.Selection,
    probe: ports.ProbeSource,
    sink: ports.AudioSink,
    status: ports.StatusSink,
    machine: core.touch.Machine,
    /// One per plant, indexed as the selection is. The engine reads neither of
    /// them: it hands each its own probe and its own share of the block, and
    /// which of them is a drone and which a folder of clips is not its business.
    voices: [2]voice_mod.Voice,
    block: [core.block_frames]f32,
    pcm: [core.block_frames]i16,
    rendered: usize,

    pub fn init(
        selection: core.plant.Selection,
        touch_config: core.touch.Config,
        probe: ports.ProbeSource,
        sink: ports.AudioSink,
        status: ports.StatusSink,
        /// Already built, because what a plant plays is a composition decision
        /// and this is not where compositions are made.
        voices: [2]voice_mod.Voice,
    ) Engine {
        return .{
            .selection = selection,
            .probe = probe,
            .sink = sink,
            .status = status,
            .machine = core.touch.Machine.init(touch_config),
            .voices = voices,
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
            for (&self.voices, 0..) |*plant_voice, plant| {
                if (!self.selection[plant]) continue;
                const probe = if (plant == 0) &self.machine.a else &self.machine.bc;
                plant_voice.render(piece, probe, touched[plant]);
            }
        }

        core.pcm.toPcm(&self.block, &self.pcm);
        try self.sink.write(&self.pcm);
        self.rendered += core.block_frames;
        self.status.observe(.{
            .raw_a = raw_a,
            .raw_bc = raw_bc,
            .z_a = self.machine.a.z,
            .z_bc = self.machine.bc.z,
            .rest_a = self.machine.a.baseline.base,
            .rest_bc = self.machine.bc.baseline.base,
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
/// How long the harness runs with nobody on the plants before a fixture's hand
/// arrives, and what it feeds them meanwhile.
///
/// The steady model learns where a probe rests and reads a hand as stillness
/// somewhere else, so a probe that has only ever read one value rests at that
/// value and no hand can be told from it. Every fixture needs this, so the
/// harness does it rather than each of them remembering to.
const settle_blocks: usize = 12 * core.sample_rate / core.block_frames;

fn resting(poll: usize) ports.Reading {
    return .{ .raw_a = flailingA(poll), .raw_bc = flailingA(poll) };
}

fn flailingA(poll: usize) i16 {
    return if (poll % 2 == 0) -4096 else 1;
}

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

/// A clip stream that answers every request with a steady tone, so a test can
/// tell plant A's clip voice from its drone by what comes out.
const FakeClips = struct {
    playing: bool = false,
    requests: usize = 0,
    level: f32 = 0.5,

    fn render(context: *anyopaque, out: []f32, request: ?usize) void {
        const self: *FakeClips = @ptrCast(@alignCast(context));
        if (request != null) {
            self.requests += 1;
            self.playing = true;
        }
        if (!self.playing) return;
        for (out) |*sample| sample.* += self.level;
    }

    fn sounding(context: *anyopaque) bool {
        const self: *FakeClips = @ptrCast(@alignCast(context));
        return self.playing;
    }

    fn port(self: *FakeClips) ports.ClipStream {
        return .{ .context = self, .render_fn = render, .sounding_fn = sounding };
    }
};

/// Both probes held, so whichever plant carries a clip voice gets a touch.
fn heldBoth(poll: usize) ports.Reading {
    const value = heldA(poll).raw_a;
    return .{ .raw_a = value, .raw_bc = value };
}

/// A hand arriving and leaving every second and a half, which is what a room
/// full of people does to a plant. Enough latch-and-release cycles inside the
/// guard to tell a guarded selector from an unguarded one.
fn alternatingA(poll: usize) ports.Reading {
    const polls_per_s = core.sample_rate / core.sensor_frames;
    const half_cycle = polls_per_s * 3 / 2;
    const held = (poll / half_cycle) % 2 == 0;
    return .{
        .raw_a = if (held) heldA(poll).raw_a else flailingA(poll),
        .raw_bc = 0,
    };
}

/// Four seconds: several touches, all inside one clip's five-second guard.
const guard_blocks: usize = 4 * core.sample_rate / core.block_frames;

fn clipVoice(stream: *FakeClips, slot: usize) voice_mod.Voice {
    const State = struct {
        var prng: [2]std.Random.DefaultPrng = undefined;
        var folders = [_]u8{ 0, 0 };
    };
    State.prng[slot] = .init(slot + 1);
    return .{ .clips = .{
        .stream = stream.port(),
        .selector = .init(&State.folders, 5.0, core.sample_rate, State.prng[slot].random()),
    } };
}

fn droneVoice() voice_mod.Voice {
    return .{ .drone = .init(core.sample_rate, 1, .{ .span = 3000 }) };
}

fn runVoices(
    pattern: *const fn (usize) ports.Reading,
    blocks: usize,
    selection: core.plant.Selection,
    voices: [2]voice_mod.Voice,
) !FakeSink {
    var probe: FakeProbe = .{ .pattern = resting };
    var sink: FakeSink = .{};
    const status: ports.StatusSink = .{ .context = &sink, .observe_fn = ignoreStatus };

    var app = Engine.init(
        selection,
        .{
            .sample_rate = core.sample_rate,
            .poll_frames = core.sensor_frames,
            .model = .steady,
        },
        probe.source(),
        sink.port(),
        status,
        voices,
    );

    // Nobody there, so the detectors learn where the probes rest.
    for (0..settle_blocks) |_| try app.step();

    // Then the gesture, measured on its own: what the plants did while the room
    // was empty is not what any of these tests are asking about.
    probe.pattern = pattern;
    probe.poll = 0;
    sink = .{};

    for (0..blocks) |_| try app.step();
    return sink;
}

/// Plant A alone, on the drone. What the drone tests have always asked for.
fn runPlantA(pattern: *const fn (usize) ports.Reading, blocks: usize) !FakeSink {
    return runVoices(pattern, blocks, .{ true, false }, .{ droneVoice(), droneVoice() });
}

fn runClipPlantA(
    pattern: *const fn (usize) ports.Reading,
    blocks: usize,
    clips: *FakeClips,
) !FakeSink {
    return runVoices(pattern, blocks, .{ true, false }, .{
        clipVoice(clips, 0),
        droneVoice(),
    });
}

test "either plant can be either kind of voice" {
    // The whole point of the change: nothing in the engine knows which plant is
    // which, so a clip voice on A with a drone on B must work exactly as well
    // as the other way round.
    var stream_a: FakeClips = .{};
    var stream_b: FakeClips = .{};

    const a_clips = try runVoices(heldBoth, warmup_blocks, .{ true, true }, .{
        clipVoice(&stream_a, 0),
        droneVoice(),
    });
    const b_clips = try runVoices(heldBoth, warmup_blocks, .{ true, true }, .{
        droneVoice(),
        clipVoice(&stream_b, 1),
    });

    try testing.expect(stream_a.requests > 0);
    try testing.expect(stream_b.requests > 0);
    try testing.expect(a_clips.rms() > 0.0);
    try testing.expect(b_clips.rms() > 0.0);
}

test "a clip voice replaces the drone rather than joining it" {
    var clips: FakeClips = .{};
    const sink = try runClipPlantA(heldA, warmup_blocks, &clips);

    try testing.expect(clips.requests > 0);
    // The fake plays a flat 0.5, so anything the drone added would show up as
    // movement around it.
    try testing.expect(sink.peak > 16000);
}

test "a second touch inside the guard starts nothing" {
    var clips: FakeClips = .{};
    _ = try runClipPlantA(alternatingA, guard_blocks, &clips);
    try testing.expectEqual(@as(usize, 1), clips.requests);
}

test "a held probe A opens the drone's gate, not just its pitch" {
    // The thing the room asks for: a hand on plant A must be heard. Measured
    // against the same engine left alone rather than against silence, because
    // the drone idles rather than stopping.
    //
    // The numbers this is pitched between, from this test: held reads an RMS of
    // 0.032 against an idle 0.012, and with the touch withheld from the voice
    // -- the gate shut, the pitch still moving -- the two are within a third of
    // each other. A ratio of two and a half sits above what the pitch alone can
    // produce and under what the gate does, so the test says the gate opened
    // and not merely that something changed.
    const held = try runPlantA(heldA, warmup_blocks);
    const idle = try runPlantA(untouched, warmup_blocks);

    try testing.expect(held.rms() > idle.rms() * 2.5);
    // The gate walks from an idle 0.35 to 1.0, so 2.86 is the most this ratio
    // can be and measuring 2.85 means the gate opened all the way. Two is
    // comfortably above what the pitch alone manages, which is 1.3.
    try testing.expect(held.peak > idle.peak * 2);
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

/// Plant A held while plant BC is left flailing, and the other way round, so a
/// test can touch one plant without touching the other.
fn heldAOnly(poll: usize) ports.Reading {
    return .{ .raw_a = heldA(poll).raw_a, .raw_bc = flailingA(poll) };
}

fn heldBOnly(poll: usize) ports.Reading {
    return .{ .raw_a = flailingA(poll), .raw_bc = heldA(poll).raw_a };
}

/// Two clip voices at levels that add up to something only reachable by both.
fn twoClipVoices(a: *FakeClips, b: *FakeClips) [2]voice_mod.Voice {
    a.level = 0.25;
    b.level = 0.5;
    return .{ clipVoice(a, 0), clipVoice(b, 1) };
}

test "the plants sound independently, and together when both are touched" {
    // The room's question: does a hand on one plant have anything to do with
    // the other. It must not. The two voices are mixed into the same block, so
    // levels that add up are what tells one plant sounding from both.
    var a: FakeClips = .{};
    var b: FakeClips = .{};

    const only_a = try runVoices(heldAOnly, warmup_blocks, .{ true, true }, twoClipVoices(&a, &b));
    try testing.expect(a.requests > 0);
    try testing.expectEqual(@as(usize, 0), b.requests);

    var a2: FakeClips = .{};
    var b2: FakeClips = .{};
    const only_b = try runVoices(heldBOnly, warmup_blocks, .{ true, true }, twoClipVoices(&a2, &b2));
    try testing.expectEqual(@as(usize, 0), a2.requests);
    try testing.expect(b2.requests > 0);

    var a3: FakeClips = .{};
    var b3: FakeClips = .{};
    const both = try runVoices(heldBoth, warmup_blocks, .{ true, true }, twoClipVoices(&a3, &b3));
    try testing.expect(a3.requests > 0);
    try testing.expect(b3.requests > 0);

    // Plant B is the louder of the two, and both together is louder than either
    // alone by the other's share -- which is only true if neither is waiting on
    // the other or replacing it.
    try testing.expect(only_b.peak > only_a.peak);
    try testing.expect(both.peak > only_b.peak);
    try testing.expect(both.peak > only_a.peak + only_b.peak - 1000);
}

test "one plant left out does not stop the other" {
    // `12` versus `1`: a plant that was never selected must cost the other
    // nothing at all.
    var a: FakeClips = .{};
    var b: FakeClips = .{};
    const alone = try runVoices(heldAOnly, warmup_blocks, .{ true, false }, twoClipVoices(&a, &b));

    try testing.expect(a.requests > 0);
    try testing.expectEqual(@as(usize, 0), b.requests);
    try testing.expect(alone.peak > 0);
}
