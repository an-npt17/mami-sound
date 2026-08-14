//! Plant A's voice: white noise pushed through a resonant bandpass filter.
//!
//! The filter's centre frequency is what the ear hears as pitch. It follows the
//! ECG level through a slow one-pole smoother, so the drone tracks the plant's
//! overall state rather than individual spikes: a healthy plant reads higher and
//! sounds higher, an unhealthy one reads lower and sounds lower. The pitch
//! glides and never steps.

const std = @import("std");
const sensors = @import("sensors.zig");

/// Pitch range. `freq_max` is the first number to retune for a different room
/// or smaller speakers.
pub const freq_min: f32 = 120.0;
pub const freq_max: f32 = 2000.0;

/// Time constant of the pitch smoother. This *is* the slow-envelope extraction:
/// ECG wiggles faster than this never reach the filter.
const smooth_tau_s: f32 = 1.0;

/// Gate fade length, long enough to avoid a click at touch and release.
const gate_ms: f32 = 150.0;

/// Filter damping, `1 / Q`. Lower is a narrower, more whistle-like band.
const damping: f32 = 0.08;

/// Compensates for the bandpass passing only a sliver of the noise spectrum.
/// Verified by the output-level test below.
const makeup: f32 = 9.0;

/// Headroom so three simultaneous voices rarely reach the clamp.
const voice_gain: f32 = 0.4;

/// Map ECG volts to centre frequency on a log scale, so equal voltage steps
/// sound like equal pitch steps.
pub fn freqFromVolts(volts: f32) f32 {
    const t = std.math.clamp(volts / sensors.volts_max, 0.0, 1.0);
    return freq_min * std.math.pow(f32, freq_max / freq_min, t);
}

/// One-pole coefficient reaching ~63% of a step in `tau` seconds.
fn smoothingAlpha(tau_s: f32, sample_rate: u32) f32 {
    const sr = @as(f32, @floatFromInt(sample_rate));
    return 1.0 - @exp(-1.0 / (tau_s * sr));
}

pub const Noise = struct {
    prng: std.Random.DefaultPrng,
    sample_rate: u32,
    alpha: f32,
    gate_step: f32,

    /// Smoothed centre frequency, in Hz.
    fc: f32,
    /// Chamberlin state-variable filter state.
    low: f32,
    band: f32,
    /// Gate envelope, 0 when untouched and 1 when held.
    env: f32,

    pub fn init(sample_rate: u32, seed: u64) Noise {
        const sr = @as(f32, @floatFromInt(sample_rate));
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .sample_rate = sample_rate,
            .alpha = smoothingAlpha(smooth_tau_s, sample_rate),
            .gate_step = 1.0 / (gate_ms / 1000.0 * sr),
            .fc = freq_min,
            .low = 0.0,
            .band = 0.0,
            .env = 0.0,
        };
    }

    /// Add this voice's output into `out`. Never overwrites, so voices mix by
    /// being rendered in sequence into the same block.
    pub fn render(self: *Noise, out: []f32, ecg_volts: f32, touched: bool) void {
        const target_fc = freqFromVolts(ecg_volts);
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const rand = self.prng.random();
        const gate_target: f32 = if (touched) 1.0 else 0.0;

        for (out) |*sample| {
            self.fc += (target_fc - self.fc) * self.alpha;

            // Chamberlin state-variable filter, bandpass tap.
            const f = 2.0 * @sin(std.math.pi * self.fc / sr);
            const input = rand.float(f32) * 2.0 - 1.0;
            self.low += f * self.band;
            const high = input - self.low - damping * self.band;
            self.band += f * high;

            if (self.env < gate_target) {
                self.env = @min(gate_target, self.env + self.gate_step);
            } else if (self.env > gate_target) {
                self.env = @max(gate_target, self.env - self.gate_step);
            }

            const value = self.band * damping * makeup * self.env * voice_gain;
            sample.* += std.math.clamp(value, -1.0, 1.0);
        }
    }
};

const testing = std.testing;

test "pitch mapping hits both ends and rises with voltage" {
    try testing.expectApproxEqAbs(freq_min, freqFromVolts(0.0), 0.01);
    try testing.expectApproxEqAbs(freq_max, freqFromVolts(sensors.volts_max), 0.01);

    var prev = freqFromVolts(0.0);
    var i: u32 = 1;
    while (i <= 100) : (i += 1) {
        const v = @as(f32, @floatFromInt(i)) / 100.0 * sensors.volts_max;
        const f = freqFromVolts(v);
        try testing.expect(f > prev);
        prev = f;
    }
}

test "pitch mapping clamps outside the sensor range" {
    try testing.expectApproxEqAbs(freq_min, freqFromVolts(-5.0), 0.01);
    try testing.expectApproxEqAbs(freq_max, freqFromVolts(99.0), 0.01);
}

test "smoother converges to its target without overshooting" {
    const alpha = smoothingAlpha(smooth_tau_s, 44100);
    var x: f32 = 0.0;
    const target: f32 = 1000.0;
    for (0..44100 * 10) |_| {
        x += (target - x) * alpha;
        try testing.expect(x <= target);
    }
    // f32 granularity stops the step short of the target: near convergence
    // `(target - x) * alpha` is too small to move the mantissa. 0.5% of a
    // frequency is well under a cent of pitch, so it never matters here.
    try testing.expectApproxEqAbs(target, x, target * 0.005);
}

test "filter stays bounded at both pitch extremes" {
    for ([_]f32{ 0.0, sensors.volts_max }) |volts| {
        var n = Noise.init(44100, 99);
        var block: [512]f32 = undefined;
        for (0..200) |_| {
            @memset(&block, 0);
            n.render(&block, volts, true);
            try testing.expect(std.math.isFinite(n.band));
            try testing.expect(std.math.isFinite(n.low));
            try testing.expect(@abs(n.band) < 100.0);
        }
    }
}

test "output is audible but not pinned to the clamp" {
    var n = Noise.init(44100, 4);
    var block: [512]f32 = undefined;
    var sum_sq: f64 = 0.0;
    var count: usize = 0;
    var clipped: usize = 0;

    // Skip the gate ramp, then measure.
    for (0..100) |i| {
        @memset(&block, 0);
        n.render(&block, 1.65, true);
        if (i < 20) continue;
        for (block) |s| {
            sum_sq += @as(f64, s) * @as(f64, s);
            if (@abs(s) >= 0.999) clipped += 1;
            count += 1;
        }
    }

    const rms = @sqrt(sum_sq / @as(f64, @floatFromInt(count)));
    try testing.expect(rms > 0.02);
    try testing.expect(rms < 0.4);
    try testing.expect(clipped * 1000 < count);
}

test "gate reaches silence and full level in the expected time" {
    var n = Noise.init(44100, 1);
    const ramp_frames: usize = @intFromFloat(gate_ms / 1000.0 * 44100.0);
    var block: [64]f32 = undefined;

    for (0..(ramp_frames / 64 + 2)) |_| {
        @memset(&block, 0);
        n.render(&block, 1.65, true);
    }
    try testing.expectEqual(@as(f32, 1.0), n.env);

    for (0..(ramp_frames / 64 + 2)) |_| {
        @memset(&block, 0);
        n.render(&block, 1.65, false);
    }
    try testing.expectEqual(@as(f32, 0.0), n.env);
}

/// Zero crossings per second, a cheap stand-in for a pitch detector. For noise
/// through a narrow bandpass this lands near twice the centre frequency.
fn crossingRate(volts: f32) f32 {
    var n = Noise.init(44100, 21);
    var block: [512]f32 = undefined;

    // Let the one-second smoother settle before measuring.
    for (0..44100 * 5 / 512) |_| {
        @memset(&block, 0);
        n.render(&block, volts, true);
    }

    var crossings: usize = 0;
    var measured: usize = 0;
    var prev: f32 = 0.0;
    for (0..44100 * 2 / 512) |_| {
        @memset(&block, 0);
        n.render(&block, volts, true);
        for (block) |s| {
            if ((s >= 0.0) != (prev >= 0.0)) crossings += 1;
            prev = s;
            measured += 1;
        }
    }
    return @as(f32, @floatFromInt(crossings)) /
        (@as(f32, @floatFromInt(measured)) / 44100.0);
}
