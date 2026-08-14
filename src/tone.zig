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
pub const freq_min: f32 = 120.0;
pub const freq_max: f32 = 2000.0;

/// Time constant of the pitch smoother, matching every other voice: this is
/// what turns a per-block sensor reading into a glide.
const smooth_tau_s: f32 = 1.0;

/// Gate fade length, long enough to avoid a click at touch and release.
const gate_ms: f32 = 150.0;

/// Chosen so this voice sits at about the same RMS as the drone and the flute.
const amplitude: f32 = 0.35;

/// Headroom so three simultaneous voices rarely reach the clamp.
const voice_gain: f32 = 0.4;

/// Map ECG volts to frequency on a log scale, so equal voltage steps sound like
/// equal pitch steps.
pub fn freqFromVolts(volts: f32, volts_max: f32) f32 {
    const t = std.math.clamp(volts / volts_max, 0.0, 1.0);
    return freq_min * std.math.pow(f32, freq_max / freq_min, t);
}

/// One-pole coefficient reaching ~63% of a step in `tau` seconds.
fn smoothingAlpha(tau_s: f32, sample_rate: u32) f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    return 1.0 - @exp(-1.0 / (tau_s * sr));
}

pub const Tone = struct {
    sample_rate: u32,
    volts_max: f32,
    alpha: f32,
    gate_step: f32,

    /// Smoothed frequency, in Hz.
    hz: f32,
    /// Accumulated phase, in radians, kept inside one turn.
    phase: f64,
    /// Gate envelope, 0 when untouched and 1 when held.
    env: f32,

    pub fn init(sample_rate: u32, volts_max: f32) Tone {
        return .{
            .sample_rate = sample_rate,
            .volts_max = volts_max,
            .alpha = smoothingAlpha(smooth_tau_s, sample_rate),
            .gate_step = 1.0 / (gate_ms / 1000.0 * @as(f32, @floatFromInt(sample_rate))),
            .hz = freq_min,
            .phase = 0.0,
            .env = 0.0,
        };
    }

    /// Add this voice's output into `out`. Never overwrites, so voices mix by
    /// being rendered in sequence into the same block.
    pub fn render(self: *Tone, out: []f32, ecg_volts: f32, touched: bool) void {
        const target = freqFromVolts(ecg_volts, self.volts_max);
        const sr: f64 = @floatFromInt(self.sample_rate);
        const gate_target: f32 = if (touched) 1.0 else 0.0;

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
