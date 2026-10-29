const std = @import("std");
const timbre = @import("timbre.zig");

/// Pitch range. `freq_max` is the first number to retune for a different room
/// or smaller speakers.
///
/// `freq_min` is where the drone sits with nobody in the room, so it has to be
/// heard rather than merely felt: 20 Hz was under most speakers and the room
/// read as switched off. 100 Hz is what the ../drone-playground bench was
/// tuned at, and its three octaves to `freq_max` are the climb the room picked.
pub const freq_min: f32 = 100.0;
pub const freq_max: f32 = 400.0;

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
pub const default_gate_ms: f32 = 150.0;

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

/// How long a held touch takes to climb from `touch_floor` to the top of the
/// range, in seconds. Null asks the reading for the pitch, as this always has.
///
/// For the rig the `learned` model was reached for, where the reading cannot
/// carry a pitch at all. There `deviation` is the distance from the window's
/// middle to rest, and a middle is a median: on a probe that lives at two
/// levels a median is one of those two and never between them, so the reading
/// offers the bottom of the range and the top and nothing else. Measured over
/// an eight-second hold it took exactly two values, 0 and 25678, which is a
/// switch rather than an instrument -- and no `span` adds a third, because the
/// input has only two.
///
/// So the pitch is given the one thing about a touch on this rig that does vary
/// smoothly: how long it has lasted. A hand arrives partway up the range and
/// climbs while it stays.
///
/// Four seconds, which is the rise the design was written around and about the
/// length of the glide it replaces.
pub const default_touch_rise_s: f32 = 4.0;

/// Where a ramped touch starts, as a fraction of the range.
///
/// The bottom of the range is `freq_min`, which is where the drone already sits
/// with nobody in the room -- so a climb that started there would spend its
/// first second saying nothing, and on a four-second rise that is a quarter of
/// the gesture spent inaudible. At 0.35 a touch is answered at about 207 Hz the
/// moment it is called, and the climb is heard as a climb rather than as a
/// fade-in.
///
/// It was 0.6 when `freq_min` was 30 Hz, which put a touch at 215 Hz. With the
/// range starting at 100 Hz the same 0.6 is 348 Hz, a jump of twenty-one
/// semitones the instant a hand is called, which the room hears as the drone
/// going straight to the top. 0.35 is what box 2 and the bench use.
pub const default_touch_floor_ramped: f32 = 0.35;

/// How long a released ramp takes to fall home to `freq_min`, under the
/// `learned` model.
///
/// Without it a release is the smoother's to carry home, and on a machine
/// with no box the smoother runs at the glide, 0.15 s: from the top of the
/// range to the bottom, four octaves with `freq_min` at 50 Hz, in well under a
/// second, which the room hears as the drone dropping off a cliff. The climb
/// takes seconds to go up, so the fall takes seconds to come down, at the same
/// steady musical rate, and the gate fades to idle over the same time.
pub const default_touch_fall_s: f32 = 3.0;

/// How far a released ramp eases down over its fall, in semitones, when it
/// settles rather than falling home.
///
/// A fall all the way to `freq_min` is three octaves going downhill, and the
/// room hears the drone dropping rather than the plant letting go. Settled, a
/// release is the climb slowing to a rest a little under where the hand left
/// it: the level fades to idle and the pitch barely moves.
pub const default_touch_settle_semis: f32 = 2.0;

/// Time constant of the drift home once a settle is over. Long enough that
/// nobody hears it as a fall, short enough that an empty room is back near
/// the bottom within a couple of minutes and the next visitor gets a climb.
pub const settle_home_s: f32 = 30.0;

/// How far a ramped touch's pitch bends for each tenth of the probe's share,
/// in semitones. Zero leaves the climb a clean line.
///
/// A ramp is the length of the hold and nothing else, so every touch sounds
/// the same, and the room hears a machine rather than a plant. The share the
/// `learned` model latches on is the one thing a held probe offers by degree,
/// and on the box captures it wanders by about a tenth through a hold, so a
/// semitone for each tenth bends the climb audibly without turning it into a
/// siren. What the pitch follows is the share's quick wiggle less its slow
/// average, so the climb is still what carries the pitch upward.
pub const default_wobble_semis: f32 = 1.0;

/// How quickly the wobble follows the share. The share itself moves in steps
/// as its window slides, and this is what turns those steps into a bend.
/// At 0.15 s the steps still came through as small lurches in the climb; 0.4
/// keeps the bend and loses the steps.
pub const default_wobble_s: f32 = 0.4;

/// How slowly the share's own average follows it, which is what the wobble is
/// measured from: longer than any wiggle worth hearing, shorter than a hold.
const wobble_base_s: f32 = 1.5;

/// The furthest the wobble may take the pitch, in tenths of share. A share
/// that leaps when a hand shifts is a gesture, not an octave.
const wobble_swing_max: f32 = 2.0;

/// How plant A's pitch answers a touch: how far up the range a touch reaches
/// before the reading is consulted at all, how far up a deviation reaches from
/// there, how long the sweep up to it takes, how long the tracking behind it
/// takes, and how long the fall home takes once the hand has gone.
pub const Shape = struct {
    /// Deviation that reaches the top of the range, or null to read the pitch
    /// off where the probe sits between its own two ends instead.
    ///
    /// A span is a number somebody measured off a capture, and it only works
    /// where rest is an end of the range: a distance is rectified, so on a rig
    /// whose rest sits in the middle the pitch folds at rest and a hand going
    /// down sounds like a hand going up. Left out, the probe supplies its own
    /// ends and the mapping is monotonic without anything being measured.
    span: ?i16 = default_span,
    touch_floor: f32 = default_touch_floor,
    /// Set to climb on the hold rather than on the reading. Null keeps the
    /// mapping every existing rig was tuned against.
    touch_rise_s: ?f32 = null,
    /// How far that climb goes, in semitones above where it starts. Null
    /// climbs all the way to `freq_max`, as every ramp did before.
    touch_climb_semis: ?f32 = null,
    burst_s: f32 = default_burst_s,
    glide_s: f32 = default_glide_s,
    release_s: ?f32 = default_release_s,
    /// How far a ramped climb bends with the probe's share. Only a ramp reads
    /// it, and only while a share is offered.
    wobble_semis: f32 = 0.0,
    wobble_s: f32 = default_wobble_s,
    /// What the drone is made of. See timbre.zig.
    timbre: timbre.Kind = .band,
    gate_ms: f32 = default_gate_ms,
    /// How long a released ramp takes to fall home, and the gate with it.
    /// Null leaves the release to the smoother and the gate, as before.
    touch_fall_s: ?f32 = null,
    /// Set to settle a released ramp this many semitones down over its fall,
    /// and drift home slowly after, rather than fall all the way home. Null
    /// falls home as before.
    touch_settle_semis: ?f32 = null,
    /// How loud the drone sits with nobody touching, against 1 when held.
    idle_gain: f32 = default_idle_gain,
};

/// Time constant of the follower behind the shaped gate.
///
/// The gate's curve rounds both ends of a fade, but a hand coming back while
/// the drone is fading turns it round in the middle, where the curve is at its
/// steepest -- a corner the room hears as a bump. This rounds that corner, and
/// is short enough that nothing else about a fade changes.
const gain_follow_s: f32 = 0.08;

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
pub const default_idle_gain: f32 = 0.35;

/// Map a deviation from rest to centre frequency on a log scale, so equal steps
/// in the deviation sound like equal pitch steps.
pub fn freqFromDeviation(dev: i16, span: i16, floor: f32) f32 {
    const reach = std.math.clamp(floor, 0.0, 1.0);
    const t = std.math.clamp(
        @as(f32, @floatFromInt(dev)) / @as(f32, @floatFromInt(@max(span, 1))),
        0.0,
        1.0,
    );
    return freq_min * std.math.pow(f32, freq_max / freq_min, reach + (1.0 - reach) * t);
}

/// Map a position between the probe's own two ends to centre frequency, on
/// the same log scale and with the same floor as the span mapping.
///
/// What a rig gets when nobody has measured a span for it. `span` asks how far
/// the probe moved from rest and needs a number off a capture; this asks where
/// it sits between the ends it has actually been to, which the probe supplies
/// itself. It is also the only one of the two that is monotonic on a rig whose
/// rest sits mid-range: a distance is rectified, and folds.
pub fn freqFromPosition(pos: f32, floor: f32) f32 {
    const reach = std.math.clamp(floor, 0.0, 1.0);
    const t = std.math.clamp(pos, 0.0, 1.0);
    return freq_min * std.math.pow(f32, freq_max / freq_min, reach + (1.0 - reach) * t);
}

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
    /// How fast the gate closes to idle: `gate_step` unless a fall is set,
    /// when it takes the fall's length.
    gate_step_down: f32,
    idle_gain: f32,
    /// How long a released ramp takes to fall home, or null for the smoother.
    touch_fall_s: ?f32,
    /// Where the fall under way started, and how far into it the voice is.
    fall_from: f32,
    fall_samples: u64,
    /// Semitones a release settles by, or null to fall home.
    touch_settle_semis: ?f32,
    alpha_home: f32,
    /// Where a settling release has the pitch resting.
    rest_fc: f32,
    /// Where the ramp under way climbs from: the floor, or under a settle,
    /// wherever the last release left the pitch if that is higher, so a touch
    /// never swoops down before it climbs.
    climb_from: f32,
    /// Deviation that reaches `freq_max`, or null to read the pitch off the
    /// probe's own position between its two ends.
    span: ?i16,
    /// Where a touch starts the deviation counting from.
    touch_floor: f32,
    /// How long a held touch takes to reach the top, or null to ask the
    /// reading instead.
    touch_rise_s: ?f32,
    /// Semitones a ramp climbs from its start, or null for all the way up.
    touch_climb_semis: ?f32,
    /// How many samples the touch under way has lasted, which is what a ramped
    /// pitch is read off. Nought whenever nobody is touching.
    touch_samples: u64,
    /// How far the burst travels each sample, as a fraction of the sweep.
    burst_step: f32,
    /// Semitones of bend per tenth of share, and the two smoothers the bend
    /// is the difference of.
    wobble_semis: f32,
    alpha_wobble: f32,
    alpha_wobble_base: f32,
    /// The probe's share, set by whoever renders before each block, or null
    /// where the model has none to give. Null holds the climb straight.
    share: ?f32,
    share_fast: f32,
    share_slow: f32,

    /// Smoothed centre frequency, in Hz.
    fc: f32,
    /// Chamberlin state-variable filter state.
    low: f32,
    band: f32,
    /// Gate envelope, `idle_gain` when untouched and 1 when held. A straight
    /// line between the two, which is what a fade's progress is read off.
    env: f32,
    /// What is actually heard: `env` through an S-curve and a short follower.
    gain: f32,
    alpha_gain: f32,
    /// How far through the sweep a new touch is, from 0 at `freq_min` to 1 at
    /// the reading's pitch. Held at 1 once the sweep is over, which is what
    /// hands the pitch to the glide; put back to 0 on release, so the next
    /// touch sweeps rather than resuming.
    burst: f32,
    /// Last block's touch state, so a new touch can be told from a held one.
    prev_touch: bool,
    timbre: timbre.Kind,
    warm: timbre.Warm,
    wide: timbre.Wide,

    pub fn init(sample_rate: u32, seed: u64, shape: Shape) Noise {
        const sr = @as(f32, @floatFromInt(sample_rate));
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .sample_rate = sample_rate,
            .alpha = smoothingAlpha(shape.glide_s, sample_rate),
            .alpha_release = smoothingAlpha(shape.release_s orelse shape.glide_s, sample_rate),
            .gate_step = 1.0 / (shape.gate_ms / 1000.0 * sr),
            .gate_step_down = if (shape.touch_fall_s != null and shape.touch_rise_s != null)
                (1.0 - shape.idle_gain) / @max(shape.touch_fall_s.? * sr, 1.0)
            else
                1.0 / (shape.gate_ms / 1000.0 * sr),
            .idle_gain = shape.idle_gain,
            .touch_fall_s = if (shape.touch_rise_s != null) shape.touch_fall_s else null,
            .fall_from = freq_min,
            .fall_samples = 0,
            .touch_settle_semis = shape.touch_settle_semis,
            .alpha_home = smoothingAlpha(settle_home_s, sample_rate),
            .climb_from = freq_min,
            .rest_fc = freq_min,
            .span = shape.span,
            .touch_floor = shape.touch_floor,
            .touch_rise_s = shape.touch_rise_s,
            .touch_climb_semis = shape.touch_climb_semis,
            .touch_samples = 0,
            .burst_step = 1.0 / @max(shape.burst_s * sr, 1.0),
            .wobble_semis = shape.wobble_semis,
            .alpha_wobble = smoothingAlpha(shape.wobble_s, sample_rate),
            .alpha_wobble_base = smoothingAlpha(wobble_base_s, sample_rate),
            .share = null,
            .share_fast = 0.0,
            .share_slow = 0.0,
            .fc = freq_min,
            .low = 0.0,
            .band = 0.0,
            .env = shape.idle_gain,
            .gain = shape.idle_gain,
            .alpha_gain = smoothingAlpha(gain_follow_s, sample_rate),
            .burst = 0.0,
            .prev_touch = false,
            .timbre = shape.timbre,
            .warm = .init(sample_rate),
            .wide = .init(sample_rate),
        };
    }

    /// Add this voice's output into `out`. Never overwrites, so voices mix by
    /// being rendered in sequence into the same block.
    pub fn render(self: *Noise, out: []f32, dev: i16, pos: ?f32, touched: bool) void {
        // The floor belongs to the touch, so an untouched voice still maps to
        // the bottom of the range and the release still carries the pitch all
        // the way home rather than parking it on the floor.
        const floor = if (touched) self.touch_floor else 0.0;
        // A measured span maps the distance, which is what every rig so far
        // was tuned against. Without one the probe's own position is the
        // pitch -- and a probe that has not said where its ends are yet sits
        // at the bottom rather than somewhere invented.
        const reading_fc = if (self.span) |span|
            freqFromDeviation(dev, span, floor)
        else
            freqFromPosition(pos orelse 0.0, floor);
        // A ramped voice reads its pitch off the clock instead, but only while
        // somebody is there: released, it falls home on the same mapping as
        // every other voice, which is what keeps the release one behaviour.
        const ramping = touched and self.touch_rise_s != null;
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        const rand = self.prng.random();
        const gate_target: f32 = if (touched) 1.0 else self.idle_gain;

        // A new touch starts its sweep at the bottom whatever the last one left
        // behind, because the rise is the answer and a rise from halfway up is
        // not one. A release puts the sweep away rather than pausing it: the
        // pitch is then the smoother's to carry home.
        if (touched and !self.prev_touch) {
            self.burst = 0.0;
            self.touch_samples = 0;
            // A ramped touch starts partway up and climbs, so it has no sweep
            // to make and dropping the pitch to the bottom first would put a
            // swoop in front of every hand. The glide carries it to the floor.
            if (!ramping) self.fc = freq_min;
            const floor_fc = freq_min * std.math.pow(
                f32,
                freq_max / freq_min,
                std.math.clamp(self.touch_floor, 0.0, 1.0),
            );
            self.climb_from = floor_fc;
            // Under a settle, a hand coming back is the same gesture carrying
            // on, not a new one: the climb is picked up at the point on it
            // where the pitch now sits, at the speed it had there, rather
            // than a fresh four-second rise from wherever the fall had got to,
            // which made a hand coming back sound like a different touch.
            if (ramping and self.touch_settle_semis != null and self.fc > floor_fc) {
                const reached = if (self.touch_climb_semis) |semis|
                    12.0 * std.math.log2(self.fc / floor_fc) / @max(semis, 0.001)
                else
                    @log(self.fc / floor_fc) / @log(freq_max / floor_fc);
                // The climb is eased out, `1 - (1 - x)^2`; this is its inverse.
                const linear = 1.0 - @sqrt(1.0 - std.math.clamp(reached, 0.0, 1.0));
                self.touch_samples = @intFromFloat(linear * self.touch_rise_s.? * sr);
            }
            // The share leaps when a hand arrives. Starting both smoothers
            // there keeps that leap from playing as a lurch at every touch.
            if (self.share) |share| {
                self.share_fast = share;
                self.share_slow = share;
            }
        } else if (!touched) {
            // A hand just gone: the fall starts from wherever the pitch is.
            if (self.prev_touch) {
                self.fall_from = self.fc;
                self.fall_samples = 0;
            }
            self.burst = 0.0;
            self.touch_samples = 0;
        }
        self.prev_touch = touched;
        const falling = !touched and self.touch_fall_s != null;

        // Held, the smoother is the piece and runs at the glide. Released, it
        // is only the way home and runs at the release, which is the same rate
        // unless the command line asked for another.
        // A fall is a line like the climb, so it is followed at the glide too:
        // a slow release smoother would round its start into a lag.
        const alpha = if (touched or falling) self.alpha else self.alpha_release;

        for (out) |*sample| {
            var target_fc = reading_fc;
            if (ramping) {
                const rise = self.touch_rise_s.?;
                const age = @as(f32, @floatFromInt(self.touch_samples)) / sr;
                // Read per sample rather than per block, so a four-second climb
                // is a climb and not a staircase of block-sized steps.
                const linear = if (rise > 0.0)
                    std.math.clamp(age / rise, 0.0, 1.0)
                else
                    1.0;
                // Eased out: the climb leaves the floor at its quickest, so it
                // carries straight on from the glide up to it, and settles onto
                // the top rather than hitting it. A straight line turned a
                // corner at both ends, which the room heard as steps.
                const t = 1.0 - (1.0 - linear) * (1.0 - linear);
                const start = self.climb_from;
                if (self.touch_climb_semis) |semis| {
                    // A set number of semitones up from the floor, still never
                    // past the top of the range.
                    target_fc = @min(freq_max, start * std.math.pow(f32, 2.0, semis * t / 12.0));
                } else {
                    // The same line in the log domain as the floor-to-top
                    // climb always was, only from wherever the touch starts.
                    target_fc = start * std.math.pow(f32, freq_max / start, t);
                }
                self.touch_samples += 1;

                if (self.share) |share| {
                    self.share_fast += (share - self.share_fast) * self.alpha_wobble;
                    self.share_slow += (share - self.share_slow) * self.alpha_wobble_base;
                    if (self.wobble_semis != 0.0) {
                        const swing = std.math.clamp(
                            (self.share_fast - self.share_slow) / 0.1,
                            -wobble_swing_max,
                            wobble_swing_max,
                        );
                        target_fc *= std.math.pow(f32, 2.0, self.wobble_semis * swing / 12.0);
                    }
                }
            }

            if (falling) {
                const fall = self.touch_fall_s.?;
                const age = @as(f32, @floatFromInt(self.fall_samples)) / sr;
                const t = if (fall > 0.0) std.math.clamp(age / fall, 0.0, 1.0) else 1.0;
                if (self.touch_settle_semis) |semis| {
                    // Eased out like the climb: it leaves at its quickest and
                    // comes to rest, which is heard as slowing, not dropping.
                    if (t < 1.0) {
                        const eased = 1.0 - (1.0 - t) * (1.0 - t);
                        self.rest_fc = @max(
                            freq_min,
                            self.fall_from * std.math.pow(f32, 2.0, -semis * eased / 12.0),
                        );
                    } else {
                        // Rested: from there the pitch is only drifted home,
                        // far too slowly to hear as a fall.
                        self.rest_fc += (freq_min - self.rest_fc) * self.alpha_home;
                    }
                    target_fc = self.rest_fc;
                } else {
                    // Down in the log domain, at a steady musical rate, for the
                    // same reason the climb goes up in it.
                    target_fc = self.fall_from * std.math.pow(f32, freq_min / self.fall_from, t);
                }
                self.fall_samples += 1;
            }

            if (touched and !ramping and self.burst < 1.0) {
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

            const source = switch (self.timbre) {
                .band => blk: {
                    // Chamberlin state-variable filter, bandpass tap.
                    const f = 2.0 * @sin(std.math.pi * self.fc / sr);
                    const input = rand.float(f32) * 2.0 - 1.0;
                    self.low += f * self.band;
                    const high = input - self.low - damping * self.band;
                    self.band += f * high;
                    break :blk self.band * damping * makeup;
                },
                .warm => self.warm.next(rand, self.fc),
                .wide => self.wide.next(rand, self.fc),
            };

            if (self.env < gate_target) {
                self.env = @min(gate_target, self.env + self.gate_step);
            } else if (self.env > gate_target) {
                self.env = @max(gate_target, self.env - self.gate_step_down);
            }

            // Raised cosine between idle and full, so a fade leaves and arrives
            // gently instead of turning a corner at both ends.
            const width = 1.0 - self.idle_gain;
            const shaped = if (width > 0.0) blk: {
                const u = std.math.clamp((self.env - self.idle_gain) / width, 0.0, 1.0);
                break :blk self.idle_gain + width * (0.5 - 0.5 * @cos(std.math.pi * u));
            } else self.env;
            self.gain += (shaped - self.gain) * self.alpha_gain;

            const value = source * self.gain * voice_gain;
            // The warm voice is matched to the band's loudness with gain to
            // spare, so it saturates softly rather than squaring off.
            sample.* += switch (self.timbre) {
                .band => std.math.clamp(value, -1.0, 1.0),
                .warm, .wide => std.math.tanh(value),
            };
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
        voice.render(&block, dev, null, touched);
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

    // A release too short for the pitch to have fallen anywhere on its own:
    // a hundredth of a second, a fifth of the glide.
    var short: [441]f32 = .{0.0} ** 441;
    voice.render(&short, 0, null, false);
    const before = voice.fc;
    try std.testing.expect(before > 0.75 * held);

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

test "the touch is heard as a burst and not only as a change of pitch" {
    // The gate and the sweep are what make a touch audible; the pitch alone is
    // not. Both voices here are handed the same deviation, so the only thing
    // that can separate them is the touch itself -- which is exactly the wire
    // an engine could drop without any test noticing.
    const shape: Shape = .{ .span = 3000 };
    var touched: Noise = .init(44100, 1, shape);
    var idle: Noise = .init(44100, 1, shape);

    var touched_out = [_]f32{0.0} ** 44100;
    var idle_out = [_]f32{0.0} ** 44100;
    touched.render(&touched_out, 1500, null, true);
    idle.render(&idle_out, 1500, null, false);

    try std.testing.expect(rootMeanSquare(&touched_out) > rootMeanSquare(&idle_out) * 2.0);
}

fn rootMeanSquare(samples: []const f32) f32 {
    var sum: f64 = 0.0;
    for (samples) |sample| sum += @as(f64, sample) * @as(f64, sample);
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(samples.len))));
}

/// A voice shaped the way the faulty rig needs: the pitch is the length of the
/// hold rather than the size of the reading.
fn rampVoice() Noise {
    return .init(44100, 1, .{
        .span = 3000,
        .touch_floor = 0.6,
        .touch_rise_s = 4.0,
        .glide_s = 0.05,
    });
}

test "a ramped touch starts partway up the range and does not wait for a reading" {
    // On the learned model the reading is no help to a pitch. `deviation` there
    // is the distance from the window's middle to rest, and on a rig whose
    // probe lives at two levels a median is one of the two -- so the reading
    // offers exactly two pitches, the bottom of the range and the top, and
    // tuning `span` cannot add a third. The hold is what has a size here.
    var voice = rampVoice();

    // A tenth of a second in: already well clear of the untouched pitch,
    // because the floor is where a ramped touch starts rather than where it
    // ends up. The reading is nought, which under the old mapping was silence.
    renderBlocks(&voice, 1, 0, true);
    try std.testing.expect(voice.fc > 3.0 * freq_min);
    try std.testing.expect(voice.fc < freq_max);
}

test "a ramped touch climbs to the top of the range on the hold alone" {
    var voice = rampVoice();

    renderBlocks(&voice, 5, 0, true);
    const early = voice.fc;
    renderBlocks(&voice, 15, 0, true);
    const later = voice.fc;

    // Half a second against two: the same reading throughout, and the pitch has
    // moved. That movement is the whole point.
    try std.testing.expect(later > early);

    // Past the rise it is at the top and stays there.
    renderBlocks(&voice, 40, 0, true);
    try std.testing.expectApproxEqAbs(freq_max, voice.fc, 1.0);
}

test "a ramped touch ignores the reading entirely" {
    // Two voices, the same hold, readings a rail apart. A pitch that answered
    // the reading would separate them; this one must not, because on this rig
    // the reading is the rail chatter and not the hand.
    var quiet = rampVoice();
    var loud = rampVoice();
    renderBlocks(&quiet, 10, 0, true);
    renderBlocks(&loud, 10, 25000, true);
    try std.testing.expectApproxEqAbs(quiet.fc, loud.fc, 0.01);
}

test "a released ramp falls home and the next touch starts over" {
    var voice = rampVoice();
    renderBlocks(&voice, 60, 0, true);
    try std.testing.expectApproxEqAbs(freq_max, voice.fc, 1.0);

    renderBlocks(&voice, 10, 0, false);
    try std.testing.expect(voice.fc < 1.1 * freq_min);

    // The next hand gets its own rise, not the top of the last one.
    renderBlocks(&voice, 1, 0, true);
    try std.testing.expect(voice.fc < 0.5 * freq_max);
}

test "no rise asked for leaves the deviation mapping exactly as it was" {
    var voice = steadyVoice();
    renderBlocks(&voice, 20, 60, true);
    try std.testing.expectApproxEqAbs(freqFromDeviation(60, 200, 0.6), voice.fc, 1.0);
}

test "a position maps across the pitch range without a span to measure" {
    // The mapping a rig gets when nobody has measured a span for it. The ends
    // are whatever the probe has been to, so the only thing left to say is
    // where between them it sits -- and the range is spent on that, log
    // scaled like every other pitch here so equal steps sound equal.
    try std.testing.expectApproxEqRel(freq_min, freqFromPosition(0.0, 0.0), 0.001);
    try std.testing.expectApproxEqRel(freq_max, freqFromPosition(1.0, 0.0), 0.001);
    try std.testing.expectApproxEqRel(
        @sqrt(freq_min * freq_max),
        freqFromPosition(0.5, 0.0),
        0.001,
    );
}

test "an unset span reads the pitch off the probe's position instead" {
    // The whole point of leaving the span out: the room does not have to know
    // how far a hand moves this probe, because the probe has already been to
    // both ends and said so. A span left set keeps the mapping every rig so
    // far was tuned against, which is the next test.
    var voice: Noise = .init(44100, 1, .{
        .span = null,
        .glide_s = 0.002,
        .release_s = 0.002,
    });
    var block: [2048]f32 = undefined;
    @memset(&block, 0.0);

    // Halfway between the ends is the middle of the range. The deviation is
    // handed over as nought to prove it is not what the pitch came from.
    for (0..60) |_| voice.render(&block, 0, 0.5, false);
    try std.testing.expectApproxEqRel(@sqrt(freq_min * freq_max), voice.fc, 0.02);
}

test "a span that is set still maps the deviation, as every rig was tuned" {
    // Box 2 and box 5 measured a span off a capture and the drone was tuned
    // against it. Leaving the span out is the new behaviour; setting one has
    // to stay exactly the old one, or five boxes retune at once.
    var voice: Noise = .init(44100, 1, .{
        .span = 1000,
        .glide_s = 0.002,
        .release_s = 0.002,
    });
    var block: [2048]f32 = undefined;
    @memset(&block, 0.0);

    // The position is handed over as nought to prove the span wins.
    for (0..60) |_| voice.render(&block, 1000, 0.0, false);
    try std.testing.expectApproxEqRel(freq_max, voice.fc, 0.02);
}

/// Plays a ramped voice through a hold whose share wanders the way a held
/// probe's does on the box captures, and returns the pitch at the end of each
/// tenth of a second.
fn wobbledHold(semis: f32, wander: bool) [40]f32 {
    var voice: Noise = .init(44100, 1, .{
        .span = 3000,
        .touch_floor = 0.35,
        .touch_rise_s = 4.0,
        .glide_s = 0.15,
        .wobble_semis = semis,
        .wobble_s = 0.15,
    });
    var pitches: [40]f32 = undefined;
    var block: [441]f32 = undefined;
    for (0..40) |step| {
        // A wiggle a second, a tenth of share either way: the size of the
        // wander through a hold in probes-box2.csv. Faster wiggles are mostly
        // smoothed away, which is what the smoothers are for.
        const t = @as(f32, @floatFromInt(step)) / 10.0;
        voice.share = if (wander) 0.7 + 0.1 * @sin(2.0 * std.math.pi * t) else 0.7;
        for (0..10) |_| {
            @memset(&block, 0);
            voice.render(&block, 0, null, true);
        }
        pitches[step] = voice.fc;
    }
    return pitches;
}

test "a wandering share bends a ramped climb" {
    const straight = wobbledHold(1.0, false);
    const bent = wobbledHold(1.0, true);

    // The same hold with the plant moving and with it still: they part.
    var widest: f32 = 0.0;
    for (straight, bent) |a, b| widest = @max(widest, @abs(@log2(b / a)) * 12.0);
    try std.testing.expect(widest > 0.3);
    // And never by more than the swing allows.
    try std.testing.expect(widest <= 2.0 * 1.0 + 0.01);
}

test "the bent climb still climbs" {
    const bent = wobbledHold(1.0, true);

    // Second by second the pitch is higher than the second before, until the
    // climb tops out: the wobble rides the rise and does not undo it.
    for (1..4) |second| {
        try std.testing.expect(bent[second * 10 + 9] > bent[second * 10 - 1]);
    }
}

test "no wobble asked for leaves the climb a clean line" {
    const still = wobbledHold(0.0, false);
    const wandering = wobbledHold(0.0, true);
    for (still, wandering) |a, b| try std.testing.expectApproxEqAbs(a, b, 0.001);
}

test "a voice offered no share climbs straight whatever the wobble" {
    // The deviation and steady models have no share to give, and a voice told
    // nothing must not invent one.
    var voice: Noise = .init(44100, 1, .{ .span = 3000, .touch_floor = 0.35, .touch_rise_s = 4.0, .wobble_semis = 1.0 });
    var plain: Noise = .init(44100, 1, .{ .span = 3000, .touch_floor = 0.35, .touch_rise_s = 4.0 });
    renderBlocks(&voice, 20, 0, true);
    renderBlocks(&plain, 20, 0, true);
    try std.testing.expectApproxEqAbs(plain.fc, voice.fc, 0.001);
}

test "a climb given in semitones stops there and not at the top" {
    // The room heard a climb to freq_max as a siren. Told seven semitones, a
    // held touch ends a fifth above where it started, however long the hold.
    var voice: Noise = .init(44100, 1, .{
        .span = 3000,
        .touch_floor = 0.35,
        .touch_rise_s = 4.0,
        .touch_climb_semis = 7.0,
        .glide_s = 0.05,
    });
    renderBlocks(&voice, 1, 0, true);
    const start = freq_min * std.math.pow(f32, freq_max / freq_min, 0.35);

    renderBlocks(&voice, 79, 0, true);
    try std.testing.expectApproxEqRel(start * std.math.pow(f32, 2.0, 7.0 / 12.0), voice.fc, 0.01);
    try std.testing.expect(voice.fc < 0.6 * freq_max);
}

test "a climb in semitones never passes the top of the range" {
    var voice: Noise = .init(44100, 1, .{
        .span = 3000,
        .touch_floor = 0.6,
        .touch_rise_s = 1.0,
        .touch_climb_semis = 48.0,
        .glide_s = 0.05,
    });
    renderBlocks(&voice, 30, 0, true);
    try std.testing.expectApproxEqAbs(freq_max, voice.fc, 1.0);
}

fn fallingVoice() Noise {
    return .init(44100, 1, .{
        .span = 3000,
        .touch_floor = 0.35,
        .touch_rise_s = 4.0,
        .glide_s = 0.15,
        .touch_fall_s = 3.0,
    });
}

test "a released ramp falls home over its fall, not off a cliff" {
    var voice = fallingVoice();
    renderBlocks(&voice, 50, 0, true);
    const top = voice.fc;
    try std.testing.expect(top > 0.9 * freq_max);

    // A second after the hand has gone it is about a third of the way down in
    // pitch, not already at the bottom. The glide follows the line a
    // time constant behind, which on a four-octave fall over three seconds
    // is about two and a half semitones above it.
    renderBlocks(&voice, 10, 0, false);
    const third = top * std.math.pow(f32, freq_min / top, 1.0 / 3.0);
    const lag = std.math.pow(f32, 2.0, 2.5 / 12.0);
    try std.testing.expectApproxEqRel(third * lag, voice.fc, 0.05);

    // And past the fall it is home.
    renderBlocks(&voice, 25, 0, false);
    try std.testing.expectApproxEqRel(freq_min, voice.fc, 0.02);
}

test "the gate closes over the fall, not over the gate fade" {
    var voice = fallingVoice();
    renderBlocks(&voice, 50, 0, true);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), voice.env, 0.001);

    // Half way through the fall the level is half way to idle.
    renderBlocks(&voice, 15, 0, false);
    try std.testing.expectApproxEqAbs((1.0 + default_idle_gain) / 2.0, voice.env, 0.02);
}

test "a fall is only a ramp's: a voice reading its pitch releases as before" {
    var plain: Noise = .init(44100, 1, .{ .span = 200, .touch_floor = 0.6, .glide_s = 0.05 });
    var asked: Noise = .init(44100, 1, .{ .span = 200, .touch_floor = 0.6, .glide_s = 0.05, .touch_fall_s = 3.0 });
    renderBlocks(&plain, 5, 60, true);
    renderBlocks(&asked, 5, 60, true);
    renderBlocks(&plain, 4, 0, false);
    renderBlocks(&asked, 4, 0, false);
    try std.testing.expectApproxEqAbs(plain.fc, asked.fc, 0.001);
}

test "the idle level is the shape's to set" {
    const voice: Noise = .init(44100, 1, .{ .idle_gain = 0.12 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.12), voice.env, 0.0001);
}

fn settlingVoice() Noise {
    var shape: Shape = .{
        .span = 3000,
        .touch_floor = 0.35,
        .touch_rise_s = 4.0,
        .glide_s = 0.15,
        .touch_fall_s = 3.0,
    };
    shape.touch_settle_semis = 2.0;
    return .init(44100, 1, shape);
}

test "a settling release eases a little way down and rests, not downhill" {
    var voice = settlingVoice();
    renderBlocks(&voice, 50, 0, true);
    const top = voice.fc;
    try std.testing.expect(top > 0.9 * freq_max);

    // Well past the fall: two semitones under where the hand left it, and
    // nowhere near the bottom of the range.
    renderBlocks(&voice, 40, 0, false);
    const rested = top * std.math.pow(f32, 2.0, -2.0 / 12.0);
    try std.testing.expectApproxEqRel(rested, voice.fc, 0.03);
    try std.testing.expect(voice.fc > 4.0 * freq_min);
}

test "a settled drone drifts home slowly, and the next touch climbs without a swoop" {
    var voice = settlingVoice();
    renderBlocks(&voice, 50, 0, true);
    renderBlocks(&voice, 40, 0, false);
    const rested = voice.fc;

    // A touch now starts its climb where the pitch is resting: never lower.
    var lowest = voice.fc;
    for (0..10) |_| {
        renderBlocks(&voice, 1, 0, true);
        lowest = @min(lowest, voice.fc);
    }
    try std.testing.expect(lowest > 0.98 * rested);

    // Left alone for minutes it is back near the bottom of the range.
    renderBlocks(&voice, 40, 0, false);
    renderBlocks(&voice, 3000, 0, false);
    try std.testing.expect(voice.fc < 1.3 * freq_min);
}

test "a hand back during the fall carries the climb on rather than starting it again" {
    var voice = settlingVoice();
    // Two seconds up a four-second climb, then let go for a second.
    renderBlocks(&voice, 20, 0, true);
    renderBlocks(&voice, 10, 0, false);
    const before = voice.fc;

    // Back on: no jump either way, and the climb goes on at the gentle speed
    // it had up there rather than the fastest it has at the bottom.
    renderBlocks(&voice, 1, 0, true);
    const semis = 12.0 * std.math.log2(voice.fc / before);
    try std.testing.expect(semis > -0.5);
    try std.testing.expect(semis < 1.0);

    // And it is the same gesture: it reaches the top well inside a fresh rise.
    renderBlocks(&voice, 25, 0, true);
    try std.testing.expect(voice.fc > 0.95 * freq_max);
}

test "the gate's fade leaves and arrives gently" {
    var voice = fallingVoice();
    renderBlocks(&voice, 50, 0, true);
    // A tenth of the way into the fall the line has gone a tenth of the way,
    // and what is heard has barely started to move.
    renderBlocks(&voice, 3, 0, false);
    const line = 1.0 - voice.env;
    const heard = 1.0 - voice.gain;
    try std.testing.expect(heard < 0.5 * line);
}
