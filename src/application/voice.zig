//! What one plant sounds like for the length of one render.
//!
//! A plant is either the generated voice or a folder of clips, and this union
//! is the only place that distinction lives. Everything above it -- the engine,
//! the command line -- holds two of these and treats them alike, which is what
//! lets either plant be either thing without either of them knowing which plant
//! it is.
//!
//! The two arms are alternatives and never a mix: a drone under a bird call is
//! neither of them.

const std = @import("std");
const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");

/// A folder of clips and the state deciding which one a touch starts.
pub const Clips = struct {
    stream: ports.ClipStream,
    selector: core.clips.ClipSelector,
    /// Whether a touch sets the clip going or has to be kept up to hear it.
    mode: core.clips.Mode = .trigger,
    /// How open the gate is, 0 to 1. `trigger` leaves it wide; `hold` walks it
    /// between the two so letting go is a fade rather than a cut.
    gate: f32 = 1.0,
};

/// The most audio one render can ask for. The engine renders a sensor poll at a
/// time, which is a quarter of a block; the ceiling is a block so a caller that
/// hands over a whole one still fits.
const max_piece = core.block_frames;

pub const Voice = union(enum) {
    drone: core.noise.Noise,
    clips: Clips,

    /// Add this plant's output into `piece`.
    ///
    /// `probe` is the plant's own detector, which only the drone reads: the
    /// pitch is the probe's deviation, where a clip cares about the touch alone.
    pub fn render(
        self: *Voice,
        piece: []f32,
        probe: *const core.touch.Detector,
        touched: bool,
    ) void {
        switch (self.*) {
            .drone => |*voice| voice.render(piece, probe.deviation(), touched),
            .clips => |*clips| renderClips(clips, piece, touched),
        }
    }
    /// A folder of clips, gated or not.
    ///
    /// In `trigger` the gate is wide and the stream renders straight into the
    /// block, which is what it has always done. In `hold` the audio is walked
    /// through a gate that opens while somebody is holding the plant and closes
    /// when they let go -- and once it has closed the stream is not asked for
    /// anything at all. That last part is what pauses the clip rather than
    /// skipping it: nothing drains the ring, so the decoder fills it and blocks,
    /// and the next hold picks the clip up on the sample it stopped at.
    fn renderClips(clips: *Clips, piece: []f32, touched: bool) void {
        std.debug.assert(piece.len <= max_piece);

        // Asked before rendering, so the answer is about the clip already
        // running rather than the one this poll might start.
        const sounding = clips.stream.sounding();
        const request = clips.selector.start(touched, sounding, piece.len);

        if (clips.mode == .trigger) {
            clips.stream.render(piece, request);
            return;
        }

        const target: f32 = if (touched) 1.0 else 0.0;
        // Shut, released, and nothing asked for: the clip stays exactly where
        // it is until a hand comes back.
        if (request == null and clips.gate == 0.0 and target == 0.0) return;

        var scratch: [max_piece]f32 = undefined;
        const heard = scratch[0..piece.len];
        @memset(heard, 0.0);
        clips.stream.render(heard, request);

        const step = 1.0 / @max(core.clips.hold_fade_s * @as(f32, @floatFromInt(core.sample_rate)), 1.0);
        for (piece, heard) |*out, sample| {
            if (clips.gate < target) {
                clips.gate = @min(target, clips.gate + step);
            } else if (clips.gate > target) {
                clips.gate = @max(target, clips.gate - step);
            }
            out.* += sample * clips.gate;
        }
    }
};

/// A clip stream that answers every request with a steady tone, so a test can
/// tell a clip voice from a drone by what comes out.
const FakeStream = struct {
    playing: bool = false,
    requests: usize = 0,
    /// Samples handed over, so a test can tell a paused clip from a silent one.
    rendered: usize = 0,

    fn render(context: *anyopaque, out: []f32, request: ?usize) void {
        const self: *FakeStream = @ptrCast(@alignCast(context));
        if (request != null) {
            self.requests += 1;
            self.playing = true;
        }
        if (!self.playing) return;
        self.rendered += out.len;
        for (out) |*sample| sample.* += 0.5;
    }

    fn sounding(context: *anyopaque) bool {
        const self: *FakeStream = @ptrCast(@alignCast(context));
        return self.playing;
    }

    fn port(self: *FakeStream) ports.ClipStream {
        return .{ .context = self, .render_fn = render, .sounding_fn = sounding };
    }
};

fn holdVoice(stream: *FakeStream) Voice {
    const State = struct {
        var prng: std.Random.DefaultPrng = undefined;
        var folders = [_]u8{ 0, 0 };
    };
    State.prng = .init(1);
    return .{ .clips = .{
        .stream = stream.port(),
        .selector = .init(&State.folders, 5.0, 44100, State.prng.random()),
        .mode = .hold,
        .gate = 0.0,
    } };
}

fn testDetector() core.touch.Detector {
    return .init(.{ .sample_rate = 44100, .poll_frames = 128, .model = .steady });
}

test "a clip voice asks for a clip on a touch and plays it" {
    var stream: FakeStream = .{};
    var prng = std.Random.DefaultPrng.init(1);
    const folders = [_]u8{ 0, 0 };
    var voice: Voice = .{ .clips = .{
        .stream = stream.port(),
        .selector = .init(&folders, 5.0, 44100, prng.random()),
    } };

    const probe = testDetector();
    var piece = [_]f32{0.0} ** 128;
    voice.render(&piece, &probe, true);

    try std.testing.expectEqual(@as(usize, 1), stream.requests);
    try std.testing.expect(piece[0] != 0.0);
}

test "a clip voice does not ask again inside the guard" {
    var stream: FakeStream = .{};
    var prng = std.Random.DefaultPrng.init(1);
    const folders = [_]u8{ 0, 0 };
    var voice: Voice = .{ .clips = .{
        .stream = stream.port(),
        .selector = .init(&folders, 5.0, 44100, prng.random()),
    } };

    const probe = testDetector();
    var piece = [_]f32{0.0} ** 128;
    // Four seconds of a hand arriving and leaving, all inside the five-second
    // guard on a clip that is still sounding.
    for (0..4 * 44100 / 128) |poll| {
        voice.render(&piece, &probe, poll % 2 == 0);
    }
    try std.testing.expectEqual(@as(usize, 1), stream.requests);
}

test "a drone voice sounds without any clip being asked for" {
    const stream: FakeStream = .{};
    var voice: Voice = .{ .drone = .init(44100, 1, .{ .span = 3000 }) };

    const probe = testDetector();
    var piece = [_]f32{0.0} ** 4096;
    voice.render(&piece, &probe, true);

    var peak: f32 = 0.0;
    for (piece) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0.0);
    try std.testing.expectEqual(@as(usize, 0), stream.requests);
}

test "a held clip voice sounds while the hand is there" {
    var stream: FakeStream = .{};
    var voice = holdVoice(&stream);
    const probe = testDetector();
    var piece = [_]f32{0.0} ** 128;

    // Long enough for the fade to finish opening.
    for (0..64) |_| {
        @memset(&piece, 0);
        voice.render(&piece, &probe, true);
    }
    try std.testing.expectEqual(@as(usize, 1), stream.requests);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), piece[piece.len - 1], 0.01);
}

test "a released clip voice fades out and then stops consuming" {
    var stream: FakeStream = .{};
    var voice = holdVoice(&stream);
    const probe = testDetector();
    var piece = [_]f32{0.0} ** 128;

    for (0..64) |_| {
        @memset(&piece, 0);
        voice.render(&piece, &probe, true);
    }
    const drained_while_held = stream.rendered;

    // The hand comes off. What follows must be silence, and once the fade has
    // run the stream must stop being asked for audio at all -- that is what
    // leaves the clip where it was rather than skipping through it.
    for (0..64) |_| {
        @memset(&piece, 0);
        voice.render(&piece, &probe, false);
    }
    try std.testing.expectEqual(@as(f32, 0.0), piece[piece.len - 1]);
    try std.testing.expect(stream.rendered > drained_while_held);

    const drained_after_release = stream.rendered;
    for (0..64) |_| voice.render(&piece, &probe, false);
    try std.testing.expectEqual(drained_after_release, stream.rendered);
}

test "the release is a fade rather than a cut" {
    var stream: FakeStream = .{};
    var voice = holdVoice(&stream);
    const probe = testDetector();
    var piece = [_]f32{0.0} ** 128;

    for (0..64) |_| voice.render(&piece, &probe, true);

    // One render's worth of letting go: the first sample must still be near
    // full and the last one lower, with no step between neighbours.
    @memset(&piece, 0);
    voice.render(&piece, &probe, false);
    try std.testing.expect(piece[0] > piece[piece.len - 1]);
    for (piece[1..], piece[0 .. piece.len - 1]) |now, before| {
        try std.testing.expect(@abs(now - before) < 0.01);
    }
}

test "a second hold resumes rather than asking for another clip" {
    var stream: FakeStream = .{};
    var voice = holdVoice(&stream);
    const probe = testDetector();
    var piece = [_]f32{0.0} ** 128;

    for (0..64) |_| voice.render(&piece, &probe, true);
    for (0..64) |_| voice.render(&piece, &probe, false);
    for (0..64) |_| voice.render(&piece, &probe, true);

    // Still the clip it started with. A hold is a window onto one thing, not a
    // way of shuffling through the folder.
    try std.testing.expectEqual(@as(usize, 1), stream.requests);
}

test "a trigger voice ignores the hand once the clip is away" {
    // The other mode, unchanged: the clip runs its own length whether the hand
    // stays or not.
    var stream: FakeStream = .{};
    var prng = std.Random.DefaultPrng.init(1);
    const folders = [_]u8{ 0, 0 };
    var voice: Voice = .{ .clips = .{
        .stream = stream.port(),
        .selector = .init(&folders, 5.0, 44100, prng.random()),
        .mode = .trigger,
    } };

    const probe = testDetector();
    var piece = [_]f32{0.0} ** 128;
    voice.render(&piece, &probe, true);
    for (0..64) |_| {
        @memset(&piece, 0);
        voice.render(&piece, &probe, false);
    }
    // Still sounding at full level with the hand long gone.
    try std.testing.expectEqual(@as(f32, 0.5), piece[0]);
}
