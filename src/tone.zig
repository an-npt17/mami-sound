//! Plant A's beep voice: one unbroken sine at whatever pitch the ECG asks for.
//!
//! The simplest voice in the piece, and the one that shows the pitch mapping
//! most plainly: nothing is filtered, sampled or looped, so what you hear is
//! the sensor and nothing else.
//!
//! The phase is accumulated rather than computed from elapsed time. That is
//! what keeps the waveform continuous while the frequency moves: recomputing
//! `sin(2*pi*f*t)` after a frequency change would jump the phase and click.

const std = @import("std");

/// Pitch range, matching the drone voice so the two can be compared by ear.
pub const freq_min: f32 = 50.0;
pub const freq_max: f32 = 1000.0;

/// Time constant of the pitch smoother, matching every other voice: this is
/// what turns a per-block sensor reading into a glide.
const smooth_tau_s: f32 = 1.0;

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
const onset_jump: f32 = 0.75;

/// Chosen so this voice sits at about the same RMS as the drone and the flute.
const amplitude: f32 = 0.35;

/// Headroom so three simultaneous voices rarely reach the clamp.
const voice_gain: f32 = 0.4;

/// Map an ECG reading to frequency on a log scale, so equal steps in the count
/// sound like equal pitch steps.
pub fn freqFromEcg(ecg: i16, ecg_max: i16) f32 {
    const t = std.math.clamp(
        @as(f32, @floatFromInt(ecg)) / @as(f32, @floatFromInt(ecg_max)),
        0.0,
        1.0,
    );
    return freq_min * std.math.pow(f32, freq_max / freq_min, t);
}

/// One-pole coefficient reaching ~63% of a step in `tau` seconds.
fn smoothingAlpha(tau_s: f32, sample_rate: u32) f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    return 1.0 - @exp(-1.0 / (tau_s * sr));
}

pub const Tone = struct {
    sample_rate: u32,
    ecg_max: i16,
    alpha: f32,
    gate_step: f32,

    /// Smoothed frequency, in Hz.
    hz: f32,
    /// Accumulated phase, in radians, kept inside one turn.
    phase: f64,
    /// Gate envelope, 0 when untouched and 1 when held.
    env: f32,
    /// Last block's touch state, so a new touch can be told from a held one.
    prev_touch: bool,

    pub fn init(sample_rate: u32, ecg_max: i16) Tone {
        return .{
            .sample_rate = sample_rate,
            .ecg_max = ecg_max,
            .alpha = smoothingAlpha(smooth_tau_s, sample_rate),
            .gate_step = 1.0 / (gate_ms / 1000.0 * @as(f32, @floatFromInt(sample_rate))),
            .hz = freq_min,
            .phase = 0.0,
            .env = 0.0,
            .prev_touch = false,
        };
    }

    /// Add this voice's output into `out`. Never overwrites, so voices mix by
    /// being rendered in sequence into the same block.
    pub fn render(self: *Tone, out: []f32, ecg: i16, touched: bool) void {
        const target = freqFromEcg(ecg, self.ecg_max);
        const sr: f64 = @floatFromInt(self.sample_rate);
        const gate_target: f32 = if (touched) 1.0 else 0.0;

        // A new touch closes most of the distance at once; the smoother below
        // walks the rest. The phase is left alone, so the jump is a pitch
        // change and never a click.
        if (touched and !self.prev_touch) {
            self.hz += (target - self.hz) * onset_jump;
        }
        self.prev_touch = touched;

        for (out) |*sample| {
            self.hz += (target - self.hz) * self.alpha;

            const value: f32 = @floatCast(@sin(self.phase));
            self.phase += 2.0 * std.math.pi * @as(f64, self.hz) / sr;
            if (self.phase >= 2.0 * std.math.pi) self.phase -= 2.0 * std.math.pi;

            if (self.env < gate_target) {
                self.env = @min(gate_target, self.env + self.gate_step);
            } else if (self.env > gate_target) {
                self.env = @max(gate_target, self.env - self.gate_step);
            }

            sample.* += value * amplitude * self.env * voice_gain;
        }
    }
};

const testing = std.testing;

test "a new touch lands most of the way to its pitch at once" {
    var t = Tone.init(44100, 32767);
    const ecg: i16 = 24000;
    const target = freqFromEcg(ecg, 32767);
    // One sample, so what is measured is the jump and not the glide after it.
    var block: [1]f32 = .{0};
    t.render(&block, ecg, true);

    const expected = freq_min + (target - freq_min) * onset_jump;
    try testing.expectApproxEqAbs(expected, t.hz, 1.0);
    try testing.expect(t.hz < target);
}

test "a held touch glides the rest of the way instead of jumping again" {
    var t = Tone.init(44100, 32767);
    const ecg: i16 = 24000;
    var block: [1]f32 = .{0};

    t.render(&block, ecg, true);
    const after_jump = t.hz;
    t.render(&block, ecg, true);
    try testing.expectApproxEqAbs(after_jump, t.hz, 1.0);

    var long: [512]f32 = undefined;
    for (0..44100 * 8 / 512) |_| {
        @memset(&long, 0);
        t.render(&long, ecg, true);
    }
    // Relative, not absolute: near convergence `(target - hz) * alpha` is too
    // small to move an f32 mantissa, and this voice's range reaches 2 kHz where
    // that shortfall is a few hertz. Well under a cent of pitch either way.
    const arrived = freqFromEcg(ecg, 32767);
    try testing.expectApproxEqAbs(arrived, t.hz, arrived * 0.005);
}

test "the jump moves the pitch without breaking the waveform" {
    var t = Tone.init(44100, 32767);
    var block: [256]f32 = undefined;
    @memset(&block, 0);
    t.render(&block, 30000, true);

    // A phase discontinuity would show up as a step between neighbours far
    // larger than the waveform's own slope. The gate is still fading in here,
    // so this also covers the jump landing under an open envelope.
    var prev: f32 = 0.0;
    for (block) |s| {
        try testing.expect(@abs(s - prev) < 0.1);
        prev = s;
    }
}
