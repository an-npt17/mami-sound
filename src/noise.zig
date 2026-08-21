//! Plant A's voice: white noise pushed through a resonant bandpass filter.
//!
//! The filter's centre frequency is what the ear hears as pitch. It follows how
//! far the probe has moved from its own rest through a slow one-pole smoother,
//! so the drone tracks the plant's overall state rather than individual spikes:
//! a firmer touch reads further out and sounds higher. The pitch glides and
//! never steps.

const std = @import("std");

/// Pitch range. `freq_max` is the first number to retune for a different room
/// or smaller speakers.
///
/// `freq_min` is where the drone sits with nobody in the room, so it has to be
/// heard rather than merely felt: 20 Hz was under most speakers and the room
/// read as switched off.
pub const freq_min: f32 = 80.0;
pub const freq_max: f32 = 1000.0;

/// Time constant of the pitch smoother. This *is* the slow-envelope extraction:
/// deviation wiggles faster than this never reach the filter. Raise it to make
/// plant A answer more slowly.
pub const default_glide_s: f32 = 1.0;

/// Gate fade length, long enough to avoid a click at touch and release.
const gate_ms: f32 = 150.0;

/// How far a new touch jumps toward the reading it finds, before the smoother
/// takes over for the rest.
///
/// The glide is the point of the piece, but at the moment of a touch it is the
/// wrong shape: the pitch sets off from wherever the last touch left it and
/// takes over a second to arrive, so the plant reads as not having answered.
/// Jumping the whole way would answer and then sit still. Three quarters is
/// enough to hear as a response, and leaves an audible settle behind it.
///
/// This is the knob for a rise that arrives too sharply: at three quarters the
/// pitch is most of the way there before the gate has finished opening, which
/// on a probe whose touch is worth thousands of counts reads as a jolt rather
/// than as an answer.
pub const default_jump: f32 = 0.75;

/// How plant A's pitch answers a touch: how far up the range a deviation
/// reaches, how much of the remaining distance a new touch closes at once, and
/// how long the rest of it takes.
pub const Shape = struct {
    span: i16 = default_span,
    jump: f32 = default_jump,
    glide_s: f32 = default_glide_s,
};

/// Filter damping, `1 / Q`. Lower is a narrower, more whistle-like band.
const damping: f32 = 0.08;

/// Compensates for the bandpass passing only a sliver of the noise spectrum.
/// Verified by the output-level test below.
const makeup: f32 = 9.0;

/// Headroom so three simultaneous voices rarely reach the clamp.
const voice_gain: f32 = 0.4;

/// Deviation from rest that maps to the top of the pitch range.
///
/// Not the sensor's full scale: this rig's whole signal lives inside a few
/// thousand counts, and mapping across 32767 squashed the entire piece into the
/// bottom five hertz of the range. Plant A's touch is a move of about 2700
/// counts, so 3000 spends most of the range on it.
pub const default_span: i16 = 3000;

/// How loud the drone sits while nobody is touching anything.
///
/// The room is never silent: an installation that goes quiet reads as broken
/// rather than as waiting. A touch is then a swell rather than an entrance.
const idle_gain: f32 = 0.35;

/// Map a deviation from rest to centre frequency on a log scale, so equal steps
/// in the deviation sound like equal pitch steps.
///
/// Deviation rather than level, because level is meaningless here: probe A
/// rests at -2049 and reads +660 when touched, so the reading's magnitude
/// *falls* on a touch. Distance from rest rises on a touch whichever way the
/// probe happens to move, and it is zero when nobody is there.
pub fn freqFromDeviation(dev: i16, span: i16) f32 {
    const t = std.math.clamp(
        @as(f32, @floatFromInt(dev)) / @as(f32, @floatFromInt(@max(span, 1))),
        0.0,
        1.0,
    );
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
    /// Deviation that reaches `freq_max`.
    span: i16,
    /// Fraction of the distance a new touch closes at once.
    jump: f32,

    /// Smoothed centre frequency, in Hz.
    fc: f32,
    /// Chamberlin state-variable filter state.
    low: f32,
    band: f32,
    /// Gate envelope, `idle_gain` when untouched and 1 when held.
    env: f32,
    /// Last block's touch state, so a new touch can be told from a held one.
    prev_touch: bool,

    pub fn init(sample_rate: u32, seed: u64, shape: Shape) Noise {
        const sr = @as(f32, @floatFromInt(sample_rate));
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .sample_rate = sample_rate,
            .alpha = smoothingAlpha(shape.glide_s, sample_rate),
            .gate_step = 1.0 / (gate_ms / 1000.0 * sr),
            .span = shape.span,
            .jump = shape.jump,
            .fc = freq_min,
            .low = 0.0,
            .band = 0.0,
            .env = idle_gain,
            .prev_touch = false,
        };
    }

    /// Add this voice's output into `out`. Never overwrites, so voices mix by
    /// being rendered in sequence into the same block.
    pub fn render(self: *Noise, out: []f32, dev: i16, touched: bool) void {
        const target_fc = freqFromDeviation(dev, self.span);
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const rand = self.prng.random();
        const gate_target: f32 = if (touched) 1.0 else idle_gain;

        // A new touch closes most of the distance at once; the smoother below
        // walks the rest. Done before the gate has finished opening, so what
        // fades in is already near pitch rather than sliding up under the fade.
        if (touched and !self.prev_touch) {
            self.fc += (target_fc - self.fc) * self.jump;
        }
        self.prev_touch = touched;

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

test "rest is the bottom of the range and a full deviation the top" {
    try testing.expectApproxEqAbs(freq_min, freqFromDeviation(0, default_span), 0.01);
    try testing.expectApproxEqAbs(freq_max, freqFromDeviation(default_span, default_span), 0.01);
    // Past the span it clamps rather than running off the top.
    try testing.expectApproxEqAbs(freq_max, freqFromDeviation(32767, default_span), 0.01);
}

test "the pitch rises with the deviation, on a log scale" {
    var last: f32 = 0.0;
    for (0..100) |i| {
        const dev: i16 = @intCast(i * @as(usize, @intCast(default_span)) / 100);
        const f = freqFromDeviation(dev, default_span);
        try testing.expect(f > last);
        last = f;
    }
}

test "plant A's touch reaches the top half of the range" {
    // The bench capture: rest -2049, touched +660, so a deviation of 2709
    // against the default span of 3000.
    const f = freqFromDeviation(2709, default_span);
    try testing.expect(f > 500.0);
}

test "an untouched drone is quieter but never silent" {
    var n = Noise.init(44100, 1, .{});
    var block: [4096]f32 = undefined;
    // Long enough for the gate to finish its fade.
    for (0..20) |_| {
        @memset(&block, 0);
        n.render(&block, 0, false);
    }
    var peak: f32 = 0.0;
    for (block) |s| peak = @max(peak, @abs(s));
    try testing.expect(peak > 0.0);

    var touched_peak: f32 = 0.0;
    for (0..20) |_| {
        @memset(&block, 0);
        n.render(&block, 2709, true);
    }
    for (block) |s| touched_peak = @max(touched_peak, @abs(s));
    try testing.expect(touched_peak > peak);
}

test "rest is audible rather than felt" {
    // 20 Hz was under most speakers; the room has to hum while nobody is there.
    try testing.expect(freq_min >= 60.0);
}

test "a deviation below rest clamps to the bottom of the range" {
    // `Machine` never emits a negative deviation, but nothing in the type stops
    // one, and a negative `t` would run the pitch under `freq_min`.
    try testing.expectApproxEqAbs(freq_min, freqFromDeviation(-2000, default_span), 0.01);
    try testing.expectApproxEqAbs(freq_min, freqFromDeviation(std.math.minInt(i16), default_span), 0.01);
}

test "a gentler onset jump lands nearer where it started" {
    var sharp = Noise.init(44100, 3, .{ .jump = 0.75 });
    var gentle = Noise.init(44100, 3, .{ .jump = 0.1 });
    var block: [1]f32 = .{0};
    sharp.render(&block, 2200, true);
    block[0] = 0;
    gentle.render(&block, 2200, true);
    // Both answer; the gentle one just does not leap most of the way at once.
    try testing.expect(gentle.fc < sharp.fc);
    try testing.expect(gentle.fc > freq_min);
}

test "a longer glide takes longer to arrive" {
    // No jump on either, so what is measured is the smoother alone.
    var quick = Noise.init(44100, 3, .{ .jump = 0.0, .glide_s = 1.0 });
    var slow = Noise.init(44100, 3, .{ .jump = 0.0, .glide_s = 5.0 });
    var block: [4096]f32 = undefined;
    for (0..10) |_| {
        @memset(&block, 0);
        quick.render(&block, 2200, true);
        @memset(&block, 0);
        slow.render(&block, 2200, true);
    }
    try testing.expect(slow.fc < quick.fc);
    try testing.expect(slow.fc > freq_min);
}

test "smoother converges to its target without overshooting" {
    const alpha = smoothingAlpha(default_glide_s, 44100);
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
    for ([_]i16{ 0, default_span }) |dev| {
        var n = Noise.init(44100, 99, .{});
        var block: [512]f32 = undefined;
        for (0..200) |_| {
            @memset(&block, 0);
            n.render(&block, dev, true);
            try testing.expect(std.math.isFinite(n.band));
            try testing.expect(std.math.isFinite(n.low));
            try testing.expect(@abs(n.band) < 100.0);
        }
    }
}

test "output is audible but not pinned to the clamp" {
    var n = Noise.init(44100, 4, .{});
    var block: [512]f32 = undefined;
    var sum_sq: f64 = 0.0;
    var count: usize = 0;
    var clipped: usize = 0;

    // Skip the gate ramp, then measure.
    for (0..100) |i| {
        @memset(&block, 0);
        n.render(&block, 2709, true);
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

test "gate reaches the idle floor and full level in the expected time" {
    var n = Noise.init(44100, 1, .{});
    const ramp_frames: usize = @intFromFloat(gate_ms / 1000.0 * 44100.0);
    var block: [64]f32 = undefined;

    for (0..(ramp_frames / 64 + 2)) |_| {
        @memset(&block, 0);
        n.render(&block, 2709, true);
    }
    try testing.expectEqual(@as(f32, 1.0), n.env);

    for (0..(ramp_frames / 64 + 2)) |_| {
        @memset(&block, 0);
        n.render(&block, 2709, false);
    }
    // The drone falls back to the idle floor, not to silence.
    try testing.expectEqual(idle_gain, n.env);
}

/// Zero crossings per second, a cheap stand-in for a pitch detector. For noise
/// through a narrow bandpass this lands near twice the centre frequency.
fn crossingRate(dev: i16) f32 {
    var n = Noise.init(44100, 21, .{});
    var block: [512]f32 = undefined;

    // Let the one-second smoother settle before measuring.
    for (0..44100 * 5 / 512) |_| {
        @memset(&block, 0);
        n.render(&block, dev, true);
    }

    var crossings: usize = 0;
    var measured: usize = 0;
    var prev: f32 = 0.0;
    for (0..44100 * 2 / 512) |_| {
        @memset(&block, 0);
        n.render(&block, dev, true);
        for (block) |s| {
            if ((s >= 0.0) != (prev >= 0.0)) crossings += 1;
            prev = s;
            measured += 1;
        }
    }
    return @as(f32, @floatFromInt(crossings)) /
        (@as(f32, @floatFromInt(measured)) / 44100.0);
}

test "a new touch lands most of the way to its pitch at once" {
    var n = Noise.init(44100, 3, .{});
    const dev: i16 = 2200;
    const target = freqFromDeviation(dev, default_span);
    // One sample, so what is measured is the jump and not the glide after it.
    var block: [1]f32 = .{0};
    n.render(&block, dev, true);

    const expected = freq_min + (target - freq_min) * default_jump;
    try testing.expectApproxEqAbs(expected, n.fc, 1.0);
    // Short of the target: the settle has to stay audible.
    try testing.expect(n.fc < target);
}

test "a held touch glides the rest of the way instead of jumping again" {
    var n = Noise.init(44100, 3, .{});
    const dev: i16 = 2200;
    var block: [1]f32 = .{0};

    n.render(&block, dev, true);
    const after_jump = n.fc;
    n.render(&block, dev, true);
    // One sample of a one-second smoother, not another quarter of the distance.
    try testing.expectApproxEqAbs(after_jump, n.fc, 1.0);

    // And it does arrive, given the time.
    var long: [512]f32 = undefined;
    for (0..44100 * 8 / 512) |_| {
        @memset(&long, 0);
        n.render(&long, dev, true);
    }
    try testing.expectApproxEqAbs(freqFromDeviation(dev, default_span), n.fc, 1.0);
}

test "releasing re-arms the jump for the next touch" {
    var n = Noise.init(44100, 3, .{});
    var block: [1]f32 = .{0};

    n.render(&block, 400, true);
    const low = n.fc;
    n.render(&block, 400, false);

    n.render(&block, 2800, true);
    const target = freqFromDeviation(2800, default_span);
    try testing.expectApproxEqAbs(low + (target - low) * default_jump, n.fc, 1.0);
}
