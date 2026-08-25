//! Plant A's voice: white noise pushed through a resonant bandpass filter.
//!
//! The filter's centre frequency is what the ear hears as pitch. A touch fires
//! a burst — the pitch drops to the bottom of the range and sweeps up to what
//! the probe is reading — and from then on it follows how far the probe has
//! moved from its own rest through a slow one-pole smoother, so the drone
//! tracks the plant's overall state rather than individual spikes: a firmer
//! touch reads further out and sounds higher. The pitch sweeps or glides and
//! never steps.

const std = @import("std");

/// Pitch range. `freq_max` is the first number to retune for a different room
/// or smaller speakers.
///
/// `freq_min` is where the drone sits with nobody in the room, so it has to be
/// heard rather than merely felt: 20 Hz was under most speakers and the room
/// read as switched off.
pub const freq_min: f32 = 30.0;
pub const freq_max: f32 = 800.0;

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

/// How long a new touch takes to sweep from the bottom of the range up to the
/// reading it found.
///
/// The glide is the point of the piece while a hand is on the plant, but at the
/// moment of a touch it is the wrong shape: the pitch sets off from wherever
/// the last touch left it and creeps to the new one, so a touch that follows
/// another sounds like nothing happened at all. What the room reads as the
/// plant answering is the rise itself, which means it has to start from the
/// bottom every time rather than from whatever was left over.
///
/// So a touch is a burst: the pitch is put back at `freq_min` and swept up to
/// what the reading asks for, and only then does the glide take over and track
/// the grip. This is the knob for how urgent that answer is. Much under a
/// tenth of a second and the sweep is a click rather than a gesture; much over
/// a second and the hand is gone before the plant has finished replying.
pub const default_burst_s: f32 = 0.4;

/// How far up the pitch range a touch reaches before the reading has said
/// anything, as a fraction of the range.
///
/// Zero by default, because in the deviation model the reading already spends
/// the whole range on its own and a floor there would only lift the drone's
/// rest along with it.
///
/// The steady model cannot work without one. There the pitch is the level the
/// probe went still at measured from the bottom of its band, and the band is a
/// hundred counts wide: a hand on plant A holds the probe at about 660 inside
/// a band starting at 600, which is 60 counts, which against any span wide
/// enough to be safe maps to 31 Hz — one hertz above the untouched 30, and
/// inaudible. The touch is real, latched, and silent. A floor of about 0.6
/// puts a touch at 220 Hz the moment it is called, and leaves the wander
/// inside the band to spend the rest of the range on top of that.
pub const default_touch_floor: f32 = 0.0;

/// How plant A's pitch answers a touch: how far up the range a touch reaches
/// before the reading is consulted at all, how far up a deviation reaches from
/// there, how long the sweep up to it takes, how long the tracking behind it
/// takes, and how long the fall home takes once the hand has gone.
pub const Shape = struct {
    span: i16 = default_span,
    touch_floor: f32 = default_touch_floor,
    burst_s: f32 = default_burst_s,
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
///
/// `floor` is where the deviation starts counting from: at zero the deviation
/// has the whole range, and at 0.6 it has the top 40% of it and everything
/// below that belongs to the fact of being touched at all.
pub fn freqFromDeviation(dev: i16, span: i16, floor: f32) f32 {
    const reach = std.math.clamp(floor, 0.0, 1.0);
    const t = std.math.clamp(
        @as(f32, @floatFromInt(dev)) / @as(f32, @floatFromInt(@max(span, 1))),
        0.0,
        1.0,
    );
    return freq_min * std.math.pow(f32, freq_max / freq_min, reach + (1.0 - reach) * t);
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
    /// Where a touch starts the deviation counting from.
    touch_floor: f32,
    /// How far the burst travels each sample, as a fraction of the sweep.
    burst_step: f32,

    /// Smoothed centre frequency, in Hz.
    fc: f32,
    /// Chamberlin state-variable filter state.
    low: f32,
    band: f32,
    /// Gate envelope, `idle_gain` when untouched and 1 when held.
    env: f32,
    /// How far through the sweep a new touch is, from 0 at `freq_min` to 1 at
    /// the reading's pitch. Held at 1 once the sweep is over, which is what
    /// hands the pitch to the glide; put back to 0 on release, so the next
    /// touch sweeps rather than resuming.
    burst: f32,
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
            .touch_floor = shape.touch_floor,
            .burst_step = 1.0 / @max(shape.burst_s * sr, 1.0),
            .fc = freq_min,
            .low = 0.0,
            .band = 0.0,
            .env = idle_gain,
            .burst = 0.0,
            .prev_touch = false,
        };
    }

    /// Add this voice's output into `out`. Never overwrites, so voices mix by
    /// being rendered in sequence into the same block.
    pub fn render(self: *Noise, out: []f32, dev: i16, touched: bool) void {
        // The floor belongs to the touch, so an untouched voice still maps to
        // the bottom of the range and the release still carries the pitch all
        // the way home rather than parking it on the floor.
        const target_fc = freqFromDeviation(dev, self.span, if (touched) self.touch_floor else 0.0);
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const rand = self.prng.random();
        const gate_target: f32 = if (touched) 1.0 else idle_gain;

        // A new touch starts its sweep at the bottom whatever the last one left
        // behind, because the rise is the answer and a rise from halfway up is
        // not one. A release puts the sweep away rather than pausing it: the
        // pitch is then the smoother's to carry home.
        if (touched and !self.prev_touch) {
            self.burst = 0.0;
            self.fc = freq_min;
        } else if (!touched) {
            self.burst = 0.0;
        }
        self.prev_touch = touched;

        // Held, the smoother is the piece and runs at the glide. Released, it
        // is only the way home and runs at the release, which is the same rate
        // unless the command line asked for another.
        const alpha = if (touched) self.alpha else self.alpha_release;

        for (out) |*sample| {
            if (touched and self.burst < 1.0) {
                self.burst = @min(1.0, self.burst + self.burst_step);
                // Swept in the log domain, for the same reason the reading is
                // mapped there: a sweep that is linear in hertz spends most of
                // its length in the top octave and arrives as a chirp. This
                // one climbs at a steady musical rate. The target is read every
                // sample, so a grip that changes mid-sweep bends it rather than
                // waiting for the end.
                self.fc = freq_min * std.math.pow(f32, target_fc / freq_min, self.burst);
            } else {
                self.fc += (target_fc - self.fc) * alpha;
            }

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

test "the touch floor lifts a held probe clear of the untouched pitch" {
    // What the steady model hands over: a band a hundred counts wide, and a
    // hand on plant A holding the probe sixty counts into it.
    const untouched = freqFromDeviation(0, 200, 0.0);
    const held = freqFromDeviation(60, 200, 0.6);

    try std.testing.expectApproxEqAbs(freq_min, untouched, 0.001);
    // Without the floor this reading was 31 Hz. An octave and a half up is the
    // least that reads as the plant having answered.
    try std.testing.expect(held > 4.0 * untouched);
    try std.testing.expect(held < freq_max);
}

test "a floor of zero leaves the deviation model's mapping alone" {
    try std.testing.expectApproxEqAbs(freq_min, freqFromDeviation(0, 3000, 0.0), 0.001);
    try std.testing.expectApproxEqAbs(freq_max, freqFromDeviation(3000, 3000, 0.0), 0.01);
}

test "the floor spends only the range a touch has not already claimed" {
    // Whatever the floor, the top of the span is still the top of the range:
    // it moves where a touch starts, never where it can reach.
    try std.testing.expectApproxEqAbs(freq_max, freqFromDeviation(200, 200, 0.6), 0.01);
}

/// A tenth of a second at the engine's rate, which is what makes the block
/// counts in these tests readable as time.
const test_block = 4410;

fn renderBlocks(voice: *Noise, blocks: usize, dev: i16, touched: bool) void {
    var block: [test_block]f32 = undefined;
    for (0..blocks) |_| {
        @memset(&block, 0);
        voice.render(&block, dev, touched);
    }
}

fn steadyVoice() Noise {
    return .init(44100, 1, .{
        .span = 200,
        .touch_floor = 0.6,
        .burst_s = 0.4,
        .glide_s = 0.05,
    });
}

test "a steady touch drives the drone up, and the release carries it home" {
    var voice = steadyVoice();

    // The whole burst, then the glide behind it.
    renderBlocks(&voice, 5, 60, true);
    try std.testing.expect(voice.fc > 4.0 * freq_min);

    // Released, the steady model reports no pitch at all, and the floor goes
    // with the touch rather than holding the drone up under a closed gate.
    // Four time constants of it, which is the fall being over rather than the
    // first instant of it.
    renderBlocks(&voice, 4, 0, false);
    try std.testing.expect(voice.fc < 1.1 * freq_min);
}

test "a touch sweeps up rather than arriving" {
    var voice = steadyVoice();
    const target = freqFromDeviation(60, 200, 0.6);

    // A tenth of the way into a four-tenths burst the pitch has left the
    // bottom and is nowhere near the top: that gap is the gesture.
    renderBlocks(&voice, 1, 60, true);
    const early = voice.fc;
    try std.testing.expect(early > freq_min);
    try std.testing.expect(early < 0.5 * target);

    renderBlocks(&voice, 1, 60, true);
    try std.testing.expect(voice.fc > early);

    // By the end of the burst it has arrived.
    renderBlocks(&voice, 3, 60, true);
    try std.testing.expectApproxEqRel(target, voice.fc, 0.05);
}

test "the sweep climbs at a steady musical rate rather than in hertz" {
    var voice = steadyVoice();

    // Two equal slices of the burst are equal pitch intervals, not equal
    // numbers of hertz. A sweep linear in hertz would spend the first slice
    // almost stationary and the last one covering hundreds of hertz.
    renderBlocks(&voice, 1, 60, true);
    const first = voice.fc;
    renderBlocks(&voice, 1, 60, true);
    const second = voice.fc;
    renderBlocks(&voice, 1, 60, true);
    const third = voice.fc;

    try std.testing.expectApproxEqRel(first / freq_min, second / first, 0.05);
    try std.testing.expectApproxEqRel(second / first, third / second, 0.05);
}

test "every touch sweeps from the bottom, however high the last one left it" {
    var voice = steadyVoice();
    renderBlocks(&voice, 5, 60, true);
    const held = voice.fc;
    try std.testing.expect(held > 4.0 * freq_min);

    // A release too short for the pitch to have fallen anywhere on its own.
    renderBlocks(&voice, 1, 0, false);
    const before = voice.fc;
    try std.testing.expect(before > 2.0 * freq_min);

    // The next touch still starts at the bottom. Without that, a touch that
    // follows another is inaudible: the pitch is already where it is going.
    renderBlocks(&voice, 1, 60, true);
    try std.testing.expect(voice.fc < before);
    try std.testing.expect(voice.fc < 0.5 * held);
}

test "a release part-way through a burst hands the pitch back to the glide" {
    var voice = steadyVoice();
    renderBlocks(&voice, 1, 60, true);
    const abandoned = voice.fc;

    // The hand comes off mid-sweep. The sweep must not resume and drag the
    // pitch up under a closing gate; the release owns it from here.
    renderBlocks(&voice, 4, 0, false);
    try std.testing.expect(voice.fc < abandoned);
    try std.testing.expect(voice.fc < 1.1 * freq_min);
}
