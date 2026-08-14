//! The sound engine. Everything here is free of I/O except `sink` and
//! `decode`, so the whole signal path can be exercised by `zig build test`
//! without a sound card.

const std = @import("std");

pub const sensors = @import("sensors.zig");
pub const noise = @import("noise.zig");
pub const player = @import("player.zig");
pub const decode = @import("decode.zig");
pub const sink = @import("sink.zig");
pub const select = @import("select.zig");
pub const sampler = @import("sampler.zig");
pub const tone = @import("tone.zig");
pub const cli = @import("cli.zig");

pub const sample_rate: u32 = 44100;
pub const channels: u32 = 1;

/// ~11.6 ms per block. Sensors are polled once per block, which is far faster
/// than the one-second pitch smoothing cares about.
pub const block_frames: usize = 512;

test {
    _ = sensors;
    _ = noise;
    _ = player;
    _ = decode;
    _ = sink;
    _ = select;
    _ = sampler;
    _ = tone;
    _ = cli;
}

const testing = std.testing;

/// A stand-in clip, so the mixing tests do not depend on ffmpeg or on the
/// installation's audio files being present.
fn toneClip(gpa: std.mem.Allocator, len: usize) ![]f32 {
    const buf = try gpa.alloc(f32, len);
    for (buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        s.* = 0.8 * @sin(2.0 * std.math.pi * 440.0 * t);
    }
    return buf;
}

/// Render `blocks` blocks with the given touch state held throughout and return
/// the loudest sample produced. This is the same voice wiring `main` uses.
fn peakOf(touch: [3]bool, blocks: usize) !f32 {
    const gpa = testing.allocator;

    const clip_b = try toneClip(gpa, sample_rate * 2);
    defer gpa.free(clip_b);
    const clip_c = try toneClip(gpa, sample_rate * 2);
    defer gpa.free(clip_c);

    var voice_a = noise.Noise.init(sample_rate, 1);
    var voice_b = player.Player.init(clip_b);
    var voice_c = player.Player.init(clip_c);

    var block: [block_frames]f32 = undefined;
    var peak: f32 = 0.0;

    for (0..blocks) |_| {
        @memset(&block, 0);
        voice_a.render(&block, 1.65, touch[0]);
        voice_b.render(&block, touch[1]);
        voice_c.render(&block, touch[2]);
        for (block) |s| peak = @max(peak, @abs(s));
    }
    return peak;
}
