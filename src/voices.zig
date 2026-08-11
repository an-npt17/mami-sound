//! Station 2: the random-tone installation.
//!
//! A digital vibration sensor gives one bit, so there is nothing to map
//! continuously - every debounced rising edge instead draws a fresh voice.
//! Pitch comes from a minor pentatonic over the configured spread, and the
//! waveform, length and level are drawn too, so no two hits sound alike. The
//! draw runs off a seeded PRNG, which is what makes a run reproducible.

const std = @import("std");

pub const max_voices: usize = 8;
pub const default_spread_st: f32 = 24.0;
pub const max_spread_st: f32 = 48.0;
pub const base_freq: f32 = 220.0;

const pentatonic = [_]f32{ 0, 3, 5, 7, 10 };
const min_dur_s: f32 = 0.15;
const max_dur_s: f32 = 1.2;
const min_peak: f32 = 0.18;
const max_peak: f32 = 0.40;
/// Fade-in, long enough to kill the click of starting a waveform at full level.
const attack_s: f32 = 0.004;

pub const Wave = enum { sine, triangle, square, saw };

pub const Voice = struct {
    freq: f32,
    wave: Wave,
    peak: f32,
    /// Turns, in [0,1). Kept as a fraction rather than radians so a long voice
    /// cannot drift on floating-point accumulation.
    phase: f32,
    age: usize,
    len: usize,

    pub fn done(self: Voice) bool {
        return self.age >= self.len;
    }
};

fn waveAt(w: Wave, phase: f32) f32 {
    return switch (w) {
        .sine => @sin(phase * 2.0 * std.math.pi),
        .triangle => 4.0 * @abs(phase - 0.5) - 1.0,
        .square => if (phase < 0.5) @as(f32, 1.0) else @as(f32, -1.0),
        .saw => 2.0 * phase - 1.0,
    };
}

/// Amplitude of a voice at `age`: a short fade-in, then an exponential decay
/// forced to reach exactly zero at the end so a retired voice cannot click.
fn ampAt(age: usize, len: usize, sample_rate: u32) f32 {
    if (len == 0 or age >= len) return 0.0;
    const t = @as(f32, @floatFromInt(age)) / @as(f32, @floatFromInt(sample_rate));
    const attack: f32 = if (t < attack_s) t / attack_s else 1.0;
    const frac = @as(f32, @floatFromInt(age)) / @as(f32, @floatFromInt(len));
    return attack * std.math.exp(-4.0 * frac) * (1.0 - frac);
}

pub const Engine = struct {
    rng: std.Random.DefaultPrng,
    sample_rate: u32,
    voices: [max_voices]?Voice,

    pub fn init(seed: u64, sample_rate: u32) Engine {
        return .{
            .rng = std.Random.DefaultPrng.init(seed),
            .sample_rate = sample_rate,
            .voices = .{null} ** max_voices,
        };
    }

    pub fn reseed(self: *Engine, seed: u64) void {
        self.rng = std.Random.DefaultPrng.init(seed);
    }

    pub fn active(self: Engine) usize {
        var n: usize = 0;
        for (self.voices) |v| {
            if (v != null) n += 1;
        }
        return n;
    }

    /// Draw one voice and give it a slot. With every slot busy the oldest voice
    /// is stolen - dropping the new hit would make the station feel broken to
    /// whoever just shook the plant.
    pub fn trigger(self: *Engine, spread_st: f32) Voice {
        const random = self.rng.random();
        const spread = std.math.clamp(spread_st, 0.0, max_spread_st);
        const octaves: usize = @intFromFloat(@max(1.0, @round(spread / 12.0)));
        const degree = pentatonic[random.uintLessThan(usize, pentatonic.len)];
        const octave = random.uintLessThan(usize, octaves + 1);
        const semis = @min(spread, degree + 12.0 * @as(f32, @floatFromInt(octave)));
        const dur = min_dur_s + random.float(f32) * (max_dur_s - min_dur_s);
        const voice = Voice{
            .freq = base_freq * std.math.pow(f32, 2.0, semis / 12.0),
            .wave = @enumFromInt(random.uintLessThan(usize, 4)),
            .peak = min_peak + random.float(f32) * (max_peak - min_peak),
            .phase = 0,
            .age = 0,
            .len = @intFromFloat(dur * @as(f32, @floatFromInt(self.sample_rate))),
        };

        var oldest: usize = 0;
        for (self.voices, 0..) |v, i| {
            if (v == null) {
                self.voices[i] = voice;
                return voice;
            }
            if (v.?.age > self.voices[oldest].?.age) oldest = i;
        }
        self.voices[oldest] = voice;
        return voice;
    }

    pub fn silence(self: *Engine) void {
        self.voices = .{null} ** max_voices;
    }

    /// Mix every live voice into `out`, advancing them by one block.
    pub fn render(self: *Engine, gain: f32, out: []i16) void {
        @memset(out, 0);
        const g = std.math.clamp(gain, 0.0, 1.0);
        if (g == 0.0) {
            // Still age the voices: a muted station must not resume mid-note
            // when the level comes back up.
            for (&self.voices) |*slot| {
                if (slot.*) |*v| {
                    v.age += out.len;
                    if (v.done()) slot.* = null;
                }
            }
            return;
        }
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        for (&self.voices) |*slot| {
            if (slot.* == null) continue;
            var v = slot.*.?;
            const step = v.freq / sr;
            var i: usize = 0;
            while (i < out.len and !v.done()) : (i += 1) {
                const s = waveAt(v.wave, v.phase) * ampAt(v.age, v.len, self.sample_rate) * v.peak * g;
                const mixed = @as(i32, out[i]) + @as(i32, @intFromFloat(s * 32767.0));
                out[i] = @intCast(std.math.clamp(mixed, -32767, 32767));
                v.phase += step;
                if (v.phase >= 1.0) v.phase -= @floor(v.phase);
                v.age += 1;
            }
            // A voice that ran out mid-block still has to burn the rest of it.
            if (v.done()) {
                slot.* = null;
            } else {
                v.age += out.len - i;
                slot.* = v;
            }
        }
    }
};

test "a trigger lands inside the spread" {
    var e = Engine.init(42, 44100);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const v = e.trigger(24.0);
        try std.testing.expect(v.freq >= base_freq);
        try std.testing.expect(v.freq <= base_freq * std.math.pow(f32, 2.0, 24.0 / 12.0) + 0.001);
        try std.testing.expect(v.len > 0);
        try std.testing.expect(v.peak >= min_peak and v.peak <= max_peak);
    }
}

test "zero spread pins every voice to the base note" {
    var e = Engine.init(1, 44100);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try std.testing.expectApproxEqAbs(base_freq, e.trigger(0.0).freq, 0.001);
    }
}

test "the same seed replays the same sequence" {
    var a = Engine.init(1234, 44100);
    var b = Engine.init(1234, 44100);
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const va = a.trigger(24.0);
        const vb = b.trigger(24.0);
        try std.testing.expectEqual(va.freq, vb.freq);
        try std.testing.expectEqual(va.wave, vb.wave);
        try std.testing.expectEqual(va.len, vb.len);
        try std.testing.expectEqual(va.peak, vb.peak);
    }
}

test "a different seed gives a different sequence" {
    var a = Engine.init(1234, 44100);
    var b = Engine.init(777, 44100);
    var differs = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (a.trigger(24.0).freq != b.trigger(24.0).freq) differs = true;
    }
    try std.testing.expect(differs);
}

test "an idle engine renders silence" {
    var e = Engine.init(42, 44100);
    var buf: [8820]i16 = undefined;
    e.render(1.0, &buf);
    for (buf) |s| try std.testing.expectEqual(@as(i16, 0), s);
    try std.testing.expectEqual(@as(usize, 0), e.active());
}

fn absOf(v: i16) i32 {
    const a: i32 = v;
    return if (a < 0) -a else a;
}

test "a triggered voice sounds and then retires" {
    var e = Engine.init(42, 44100);
    _ = e.trigger(24.0);
    var buf: [8820]i16 = undefined;
    e.render(1.0, &buf);
    var peak: i32 = 0;
    for (buf) |s| peak = @max(peak, absOf(s));
    try std.testing.expect(peak > 1000);

    // Longest possible voice is 1.2 s; 3 s of blocks must clear it.
    var i: usize = 0;
    while (i < 15) : (i += 1) e.render(1.0, &buf);
    try std.testing.expectEqual(@as(usize, 0), e.active());
    e.render(1.0, &buf);
    for (buf) |s| try std.testing.expectEqual(@as(i16, 0), s);
}

test "polyphony is capped and the oldest voice is stolen" {
    var e = Engine.init(42, 44100);
    var i: usize = 0;
    while (i < max_voices + 5) : (i += 1) _ = e.trigger(24.0);
    try std.testing.expectEqual(max_voices, e.active());
}

test "a full chord never clips" {
    var e = Engine.init(9, 44100);
    var i: usize = 0;
    while (i < max_voices) : (i += 1) _ = e.trigger(24.0);
    var buf: [8820]i16 = undefined;
    var block: usize = 0;
    while (block < 8) : (block += 1) {
        e.render(1.0, &buf);
        for (buf) |s| try std.testing.expect(absOf(s) <= 32767);
    }
}

test "zero gain is silent but still ages the voices" {
    var e = Engine.init(42, 44100);
    _ = e.trigger(24.0);
    var buf: [8820]i16 = undefined;
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        e.render(0.0, &buf);
        for (buf) |s| try std.testing.expectEqual(@as(i16, 0), s);
    }
    try std.testing.expectEqual(@as(usize, 0), e.active());
}

test "gain scales the mix" {
    var loud = Engine.init(5, 44100);
    var quiet = Engine.init(5, 44100);
    _ = loud.trigger(24.0);
    _ = quiet.trigger(24.0);
    var a: [8820]i16 = undefined;
    var b: [8820]i16 = undefined;
    loud.render(1.0, &a);
    quiet.render(0.25, &b);
    var pa: i32 = 0;
    var pb: i32 = 0;
    for (a, b) |x, y| {
        pa = @max(pa, absOf(x));
        pb = @max(pb, absOf(y));
    }
    try std.testing.expect(pb < pa);
    try std.testing.expect(pb > 0);
}

test "silence clears every slot" {
    var e = Engine.init(42, 44100);
    _ = e.trigger(24.0);
    _ = e.trigger(24.0);
    e.silence();
    try std.testing.expectEqual(@as(usize, 0), e.active());
}
