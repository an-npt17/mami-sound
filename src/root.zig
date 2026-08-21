//! The sound engine. Everything here is free of I/O except `sink` and
//! `decode`, so the whole signal path can be exercised by `zig build test`
//! without a sound card.

const std = @import("std");

pub const sensors = @import("sensors.zig");
pub const ads1115 = @import("ads1115.zig");
pub const gpio = @import("gpio.zig");
pub const noise = @import("noise.zig");
pub const player = @import("player.zig");
pub const decode = @import("decode.zig");
pub const sink = @import("sink.zig");
pub const select = @import("select.zig");
pub const sampler = @import("sampler.zig");
pub const tone = @import("tone.zig");
pub const cli = @import("cli.zig");
pub const touch = @import("touch.zig");
pub const touchlog = @import("touchlog.zig");
pub const library = @import("library.zig");

pub const sample_rate: u32 = 44100;
pub const channels: u32 = 1;

/// ~11.6 ms per block. This is the unit handed to `aplay`, so it sets how
/// often the program talks to the sound card and nothing else.
pub const block_frames: usize = 512;

/// ~2.9 ms per poll: the sensors are read four times inside every block, and
/// the voices are rendered in the same four pieces so each one hears its own
/// reading.
///
/// Splitting them apart matters because the two rates want opposite things. A
/// smaller block means more writes to the card for no gain, while a smaller
/// poll means the ECG is followed closely enough that a touch or a spike is
/// caught rather than averaged away. The floor is the I2C transaction itself,
/// around half a millisecond on a 100 kHz bus.
pub const sensor_frames: usize = 128;

comptime {
    // The render loop walks the block in whole polls.
    std.debug.assert(block_frames % sensor_frames == 0);
    // The polls inside a block happen back to back — the whole block is
    // rendered in tens of microseconds and the sink blocks for the rest of it —
    // so the only wall-clock gap the ADC can count on is a block boundary.
    // `sensors.switch_frames` is what holds the multiplexer still until one
    // arrives, and it is worth nothing if it is shorter than a block.
    std.debug.assert(sensors.switch_frames >= block_frames);
}

test {
    _ = sensors;
    _ = ads1115;
    _ = gpio;
    _ = noise;
    _ = player;
    _ = decode;
    _ = sink;
    _ = select;
    _ = sampler;
    _ = tone;
    _ = cli;
    _ = touch;
    _ = touchlog;
    _ = library;
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
fn peakOf(touch_state: [3]bool, blocks: usize) !f32 {
    const gpa = testing.allocator;

    const clip_b = try toneClip(gpa, sample_rate * 2);
    defer gpa.free(clip_b);
    const clip_c = try toneClip(gpa, sample_rate * 2);
    defer gpa.free(clip_c);

    var voice_a = noise.Noise.init(sample_rate, 1, noise.default_span);
    var voice_b = player.Player.init(clip_b);
    var voice_c = player.Player.init(clip_c);

    var block: [block_frames]f32 = undefined;
    var peak: f32 = 0.0;

    for (0..blocks) |_| {
        @memset(&block, 0);
        voice_a.render(&block, noise.default_span, touch_state[0]);
        voice_b.render(&block, touch_state[1]);
        voice_c.render(&block, touch_state[2]);
        for (block) |s| peak = @max(peak, @abs(s));
    }
    return peak;
}
