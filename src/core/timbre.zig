//! What the drone is made of, as against where its pitch goes.
//!
//! `band` is the drone as it always was: white noise through one narrow
//! bandpass at the pitch. Its loudness flickers at about fc/Q, which at these
//! pitches is 15-80 Hz and is heard as grain -- measured on the
//! ../drone-playground bench at about a quarter of the level, where a steady
//! tone reads nought. No narrower or wider band fixes that: narrower slows the
//! flicker into a whistle, wider turns it into hiss.
//!
//! `warm` is the bench's "Warm pad + plant wobble" pick, ported sample for
//! sample from its dsp.js: a sine at the pitch carries the note, and pink noise
//! through two bands an octave and two above it is the breath. The noise has to
//! sit off the tone's own pitch, because a band on the tone beats against it
//! and puts the grain straight back. Roughness on the bench: 1-4%.
//!
//! `wide` is the bench's "Wider band": still only noise and still the band
//! the room knows, but pink, and a third as sharp (Q about 3 against 12). The
//! flicker runs at fc/Q, so widening the band pushes it up past the rate the
//! ear hears as grain and into texture -- 18% on the bench against the band's
//! 27% -- at the cost of more hiss and a less certain note.

const std = @import("std");

pub const Kind = enum { band, warm, wide };

pub const names = "band, warm or wide";

/// Same `1 / Q` and makeup as the band voice in noise.zig, so the breath is
/// the same narrow band the room already knows, only moved off the note.
const damping: f32 = 0.08;
const makeup: f32 = 9.0;

/// The bench's mix: the tone is the note, the noise only the air around it.
const tone_level: f32 = 0.7;
const noise_level: f32 = 0.35;

/// A sine at this amplitude has the RMS of the band voice at about 300 Hz.
const tone_scale: f32 = 0.3;

/// The breath sits this many octaves above the tone, which is what keeps it
/// from beating against it.
const noise_octaves: f32 = 1.0;

/// A noise band's loudness rises with the square root of its centre, so a
/// climb would also be a swell. Held here at what it is at this pitch.
const comp_ref_hz: f32 = 300.0;

/// Brings the pink filter's output to the white band's level at ~300 Hz.
const pink_trim: f32 = 0.11 * 1.07;

/// Takes the edge off the breath's top band.
const post_lp_hz: f32 = 3000.0;

/// Matches the warm voice's loudness at the top of a climb to the band
/// voice's, as measured on the bench, so changing timbre is not a volume
/// change. 8.5 dB.
pub const out_gain: f32 = 2.6607;

const Svf = struct { low: f32 = 0.0, band: f32 = 0.0 };

/// Paul Kellet's refined pink filter, trimmed to the white band's level.
const Pink = struct {
    b: [7]f32 = .{0.0} ** 7,

    fn next(self: *Pink, rand: std.Random) f32 {
        const w = rand.float(f32) * 2.0 - 1.0;
        const b = &self.b;
        b[0] = 0.99886 * b[0] + w * 0.0555179;
        b[1] = 0.99332 * b[1] + w * 0.0750759;
        b[2] = 0.969 * b[2] + w * 0.153852;
        b[3] = 0.8665 * b[3] + w * 0.3104856;
        b[4] = 0.55 * b[4] + w * 0.5329522;
        b[5] = -0.7616 * b[5] - w * 0.016898;
        const out = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362;
        b[6] = w * 0.115926;
        return out * pink_trim;
    }
};

fn postAlpha(sample_rate: f32) f32 {
    const tau = 1.0 / (2.0 * std.math.pi * post_lp_hz);
    return 1.0 - @exp(-1.0 / (tau * sample_rate));
}

pub const Warm = struct {
    pink: Pink = .{},
    svf: [2]Svf = .{ .{}, .{} },
    phase: f32 = 0.0,
    post: f32 = 0.0,
    alpha_post: f32,
    sample_rate: f32,

    pub fn init(sample_rate: u32) Warm {
        const sr = @as(f32, @floatFromInt(sample_rate));
        return .{ .alpha_post = postAlpha(sr), .sample_rate = sr };
    }

    /// One sample at pitch `fc`, before the gate and the voice's gain.
    pub fn next(self: *Warm, rand: std.Random, fc: f32) f32 {
        const mix = noise_level * self.breath(rand, fc) + tone_level * self.tone(fc);
        self.post += (mix - self.post) * self.alpha_post;
        return self.post * out_gain;
    }

    /// Two bands, at the breath's pitch and the octave above it, the upper at
    /// half weight.
    fn breath(self: *Warm, rand: std.Random, fc: f32) f32 {
        const base = fc * std.math.pow(f32, 2.0, noise_octaves);
        const input = self.pink.next(rand);
        // Chamberlin goes unstable well before Nyquist.
        const ceiling = self.sample_rate / 6.0;
        var sum: f32 = 0.0;
        var weights: f32 = 0.0;
        for (&self.svf, 0..) |*s, k| {
            const n = @as(f32, @floatFromInt(k + 1));
            const f = base * n;
            if (f > ceiling) continue;
            const w = 1.0 / n;
            const g = 2.0 * @sin(std.math.pi * f / self.sample_rate);
            s.low += g * s.band;
            const high = input - s.low - damping * s.band;
            s.band += g * high;
            sum += w * s.band * damping;
            weights += w * w;
        }
        if (weights == 0.0) return 0.0;
        return sum / @sqrt(weights) * makeup * @sqrt(comp_ref_hz / base);
    }

    fn tone(self: *Warm, fc: f32) f32 {
        self.phase += fc / self.sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;
        return @sin(2.0 * std.math.pi * self.phase) * tone_scale;
    }
};

/// `1 / Q` of the wide band: about three, against the band voice's twelve.
const wide_damping: f32 = 0.3;

/// Matches the wide voice's loudness at the top of a climb to the band
/// voice's, as measured on the bench. 0.1 dB.
pub const wide_out_gain: f32 = 1.0116;

pub const Wide = struct {
    pink: Pink = .{},
    svf: Svf = .{},
    post: f32 = 0.0,
    alpha_post: f32,
    sample_rate: f32,

    pub fn init(sample_rate: u32) Wide {
        const sr = @as(f32, @floatFromInt(sample_rate));
        return .{ .alpha_post = postAlpha(sr), .sample_rate = sr };
    }

    /// One sample at pitch `fc`, before the gate and the voice's gain.
    pub fn next(self: *Wide, rand: std.Random, fc: f32) f32 {
        const input = self.pink.next(rand);
        const f = @min(fc, self.sample_rate / 6.0);
        const g = 2.0 * @sin(std.math.pi * f / self.sample_rate);
        self.svf.low += g * self.svf.band;
        const high = input - self.svf.low - wide_damping * self.svf.band;
        self.svf.band += g * high;
        // No pitch compensation, unlike the warm breath. A band's loudness
        // rises with its width, which rises with its pitch, but pink noise
        // falls with pitch by the same amount, so a pink band is already as
        // loud at 800 Hz as at 100. Compensating again made the bottom of the
        // range twice as loud as the top.
        const band = self.svf.band * wide_damping * makeup;
        self.post += (band - self.post) * self.alpha_post;
        return self.post * wide_out_gain;
    }
};

fn rms(samples: []const f32) f32 {
    var sum: f64 = 0.0;
    for (samples) |s| sum += @as(f64, s) * @as(f64, s);
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(samples.len))));
}

test "the warm voice sounds and stays inside the clamp" {
    var prng = std.Random.DefaultPrng.init(1);
    var voice = Warm.init(44100);
    var out: [44100]f32 = undefined;
    for (&out) |*s| s.* = voice.next(prng.random(), 400.0);
    const level = rms(out[4410..]);
    try std.testing.expect(level > 0.1);
    try std.testing.expect(level < 1.0);
}

test "the warm voice holds its loudness through a climb" {
    // The band's loudness rises with its pitch, so without the compensation a
    // climb is also a swell. The tone does not, and the breath is held flat.
    var prng = std.Random.DefaultPrng.init(1);
    var low = Warm.init(44100);
    var high = Warm.init(44100);
    var a: [44100]f32 = undefined;
    var b: [44100]f32 = undefined;
    for (&a) |*s| s.* = low.next(prng.random(), 200.0);
    for (&b) |*s| s.* = high.next(prng.random(), 800.0);
    try std.testing.expectApproxEqRel(rms(a[4410..]), rms(b[4410..]), 0.35);
}

test "the wide voice sounds, and holds its loudness through a climb" {
    var prng = std.Random.DefaultPrng.init(1);
    var low = Wide.init(44100);
    var high = Wide.init(44100);
    var a: [44100]f32 = undefined;
    var b: [44100]f32 = undefined;
    for (&a) |*s| s.* = low.next(prng.random(), 200.0);
    for (&b) |*s| s.* = high.next(prng.random(), 800.0);
    try std.testing.expect(rms(b[4410..]) > 0.1);
    try std.testing.expect(rms(b[4410..]) < 1.0);
    try std.testing.expectApproxEqRel(rms(a[4410..]), rms(b[4410..]), 0.35);
}
