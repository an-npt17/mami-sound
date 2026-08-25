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
pub const freq_min: f32 = 30.0;
pub const freq_max: f32 = 1000.0;

/// Time constant of the pitch smoother. This *is* the slow-envelope extraction:
/// deviation wiggles faster than this never reach the filter. Raise it to make
/// plant A answer more slowly.
pub const default_glide_s: f32 = 0.5;

/// Time constant of the fall back to `freq_min` once nobody is touching, when
/// it wants to differ from the glide. `null` gives it the glide's.
///
/// The glide is set by how the pitch should answer a hand that is on the plant,
/// and a glide slow enough to be expressive there leaves the drone sinking for
/// seconds after the hand has gone, which reads as the plant not having noticed
/// the room empty. The release is gated on the touch state rather than on the
/// pitch falling: a fall *during* a touch is the plant answering a lighter
/// grip and belongs at glide speed.
pub const default_release_s: ?f32 = null;

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
/// reaches, how much of the remaining distance a new touch closes at once, how
/// long the rest of it takes, and how long the fall home takes once the hand
/// has gone.
pub const Shape = struct {
    span: i16 = default_span,
    jump: f32 = default_jump,
    glide_s: f32 = default_glide_s,
    release_s: ?f32 = default_release_s,
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
    /// The smoother's rate while nobody is touching, which is what carries the
    /// pitch home to `freq_min`.
    alpha_release: f32,
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
            .alpha_release = smoothingAlpha(shape.release_s orelse shape.glide_s, sample_rate),
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

        // Held, the smoother is the piece and runs at the glide. Released, it
        // is only the way home and runs at the release, which is the same rate
        // unless the command line asked for another.
        const alpha = if (touched) self.alpha else self.alpha_release;

        for (out) |*sample| {
            self.fc += (target_fc - self.fc) * alpha;

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
