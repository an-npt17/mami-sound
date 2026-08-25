//! Deciding which plant is being touched.
//!
//! Two probes, one decision. Each probe is judged against its own recent past
//! rather than against a number typed on the command line: a rolling median is
//! what the probe normally reads and the median absolute deviation is how much
//! it normally wanders, so a reading that is many deviations from the median is
//! a touch whatever the probe's resting level happens to be that day. That is
//! what lets one threshold serve two probes whose idle readings are −2049 and
//! +1000, and lets it keep serving them when the electrodes are moved.
//!
//! Nothing here is rectified. Touching plant A moves its probe from −2049 up to
//! +660 and touching the other moves it from positive noise down past −2049;
//! folding away the sign puts the second probe's touched state on top of its
//! untouched state, 26 counts apart, which is why no single threshold ever
//! worked on this rig.

const std = @import("std");

const testing = std.testing;

/// The distance between two readings, clamped to what an `i16` can carry.
///
/// Two readings at opposite ends of the range are 65535 apart, which does not
/// fit the type they came from, so the subtraction is done wider and the result
/// saturates rather than wrapping.
fn clampedAbsDiff(a: i16, b: i16) i16 {
    const delta = @abs(@as(i32, a) - @as(i32, b));
    return @intCast(@min(delta, std.math.maxInt(i16)));
}

/// The longest window worth averaging over, about three seconds of polls.
pub const max_mean_polls = 1024;

/// `hold_ms` expressed in polls. At least one, so a hold of zero still means
/// "one poll decides" rather than "nothing ever decides".
pub fn holdPolls(hold_ms: f32, sample_rate: u32, poll_frames: usize) u32 {
    const polls_per_s = @as(f32, @floatFromInt(sample_rate)) /
        @as(f32, @floatFromInt(poll_frames));
    const polls = @round(hold_ms / 1000.0 * polls_per_s);
    if (!(polls >= 1.0)) return 1;
    return @intFromFloat(polls);
}

/// A running mean of the last `len` polls, signed.
///
/// A true mean over a window rather than a one-pole smoother: a spike's
/// contribution is then exactly one sample's worth and it leaves the window
/// altogether once the window has passed, where a one-pole would let it decay
/// away with a long tail that outlives the touch.
pub const Mean = struct {
    window: [max_mean_polls]i16,
    len: u32,
    /// How many have arrived so far, which is what the mean divides by until
    /// the window is full. Dividing by `len` from the start would read as a
    /// long silence for the first window and hold off a touch already under
    /// way.
    count: u32,
    head: u32,
    sum: i32,

    pub fn init(window_polls: u32) Mean {
        return .{
            .window = undefined,
            .len = std.math.clamp(window_polls, 1, max_mean_polls),
            .count = 0,
            .head = 0,
            .sum = 0,
        };
    }

    /// Add one poll's reading and get the mean including it.
    pub fn push(self: *Mean, reading: i16) i16 {
        if (self.count == self.len) {
            self.sum -= self.window[self.head];
        } else {
            self.count += 1;
        }
        self.window[self.head] = reading;
        self.sum += reading;
        self.head = (self.head + 1) % self.len;

        return @intCast(@divTrunc(self.sum, @as(i32, @intCast(self.count))));
    }
};

/// The longest baseline worth keeping, about a hundred seconds of pushes.
pub const max_baseline_samples = 1024;

/// How many baseline samples a second. The median only has to track a probe's
/// resting level, which moves over minutes; pushing every poll would need
/// twenty thousand samples for the same window and buy nothing.
const baseline_hz: f32 = 10.0;

/// How many samples must have arrived before a probe may be judged. Three
/// seconds. Before this the median is whatever the first few readings were, so
/// the score means nothing and a clip could start on it.
const warmup_samples: u32 = 30;

/// What a probe normally reads, and how far it normally wanders from that.
///
/// A median rather than a leaky average because a median is touch-proof for
/// free: a touch occupying less than half the window cannot move it, so there
/// is no need to detect a touch in order to stop the baseline learning it —
/// which would be circular, since the baseline is what detects the touch.
///
/// The cost is at the other end: a touch lasting more than half the window
/// *does* move the median, and the state releases while the hand is still
/// there. The window is the knob, and it wants to be about four times the
/// longest touch expected.
pub const Baseline = struct {
    samples: [max_baseline_samples]i16,
    scratch: [max_baseline_samples]i16,
    /// The window, in samples.
    len: u32,
    count: u32,
    head: u32,
    /// Polls between pushes.
    decim: u32,
    since: u32,
    /// The median, recomputed on each push and held between them.
    base: i16,
    /// The median absolute deviation, on the same schedule.
    mad: f32,
    /// While set, readings are dropped rather than learned. Crosstalk must not
    /// teach a probe that being pulled by the other plant is its resting state.
    frozen: bool,

    pub fn init(window_s: f32, sample_rate: u32, poll_frames: usize) Baseline {
        const polls_per_s = @as(f32, @floatFromInt(sample_rate)) /
            @as(f32, @floatFromInt(poll_frames));
        const decim = @max(1.0, @round(polls_per_s / baseline_hz));
        const len = @round(window_s * baseline_hz);
        return .{
            .samples = undefined,
            .scratch = undefined,
            .len = std.math.clamp(@as(u32, @intFromFloat(@max(len, 1.0))), 1, max_baseline_samples),
            .count = 0,
            .head = 0,
            .decim = @intFromFloat(decim),
            .since = 0,
            .base = 0,
            .mad = 0.0,
            .frozen = false,
        };
    }

    /// Feed one poll's mean. Most polls only advance the decimation counter.
    pub fn push(self: *Baseline, mean_value: i16) void {
        if (self.frozen) return;
        self.since += 1;
        if (self.since < self.decim) return;
        self.since = 0;

        if (self.count < self.len) self.count += 1;
        self.samples[self.head] = mean_value;
        self.head = (self.head + 1) % self.len;

        self.recompute();
    }

    /// Whether enough has arrived for the numbers to mean anything.
    pub fn ready(self: *const Baseline) bool {
        return self.count >= warmup_samples;
    }

    fn recompute(self: *Baseline) void {
        const n = self.count;
        @memcpy(self.scratch[0..n], self.samples[0..n]);
        std.mem.sort(i16, self.scratch[0..n], {}, std.sort.asc(i16));
        self.base = self.scratch[n / 2];

        for (self.scratch[0..n], self.samples[0..n]) |*out, sample| {
            out.* = clampedAbsDiff(sample, self.base);
        }
        std.mem.sort(i16, self.scratch[0..n], {}, std.sort.asc(i16));
        self.mad = @floatFromInt(self.scratch[n / 2]);
    }
};

/// How many deviations from its own median a probe must read before it counts
/// as touched. One number for both probes: that is what measuring in
/// deviations buys.
pub const default_level: f32 = 6.0;

/// How long the score has to keep saying so.
pub const default_hold_ms: f32 = 100.0;

/// How long the reading is averaged over before the score sees it.
pub const default_average_ms: f32 = 200.0;

/// How long the median looks back.
pub const default_baseline_s: f32 = 60.0;

/// How long the other probe is given to settle after this one is touched,
/// before its crosstalk level is taken as its temporary rest.
pub const default_settle_ms: f32 = 300.0;

/// The smallest deviation the score will divide by, in counts.
///
/// Probe A is too quiet for its own good: untouched it reads -2049 and -2050
/// and nothing else, so its true MAD is about half a count and a one-count
/// wobble would score two deviations. The floor is what stops a probe being
/// punished for being clean.
const mad_floor: f32 = 25.0;

/// What question a probe is asked.
///
/// The two rigs this has run on need opposite questions. On the first, a probe
/// rests somewhere and a touch moves it, so the question is how far it has
/// moved from its own recent past. On the second the electrode floats: nobody
/// on it and it flails over the whole range and slams the rails, and a hand
/// clamps it to about 660 counts and holds it there. There the touch is the
/// quiet, and a rolling median of the flailing is a number about nothing.
pub const Model = enum { deviation, steady };

/// Where a clamped probe sits, in counts, when a level is worth insisting on.
/// Unset by default: a probe that has gone still has been taken hold of
/// whatever level it went still at, and the two probes on the floating rig
/// clamp to quite different ones — plant A's to 650-750, plant B's to about 1.
///
/// A band is worth setting when the margin needs widening. Untouched readings
/// are then thrown out on level before stillness is asked about at all, which
/// leaves only the stillness of a probe parked inside the band to argue with.
pub const default_band_lo: ?i16 = null;
pub const default_band_hi: ?i16 = null;

/// How far a clamped probe may move between readings and still count as still.
/// In the capture it moves by one count, occasionally seven.
pub const default_jitter: i16 = 8;

/// How long the readings must stop being still before a touch is called off,
/// in milliseconds. Longer than the attack on purpose: contact drops out for a
/// few polls in the middle of a real touch, and releasing on that would end a
/// clip, or with `--touch-window-bc` start one.
pub const default_drop_ms: f32 = 90.0;

pub const Config = struct {
    sample_rate: u32,
    poll_frames: usize,
    model: Model = .deviation,
    /// The band a clamped probe reads in, and how far it may move between
    /// readings and still count as clamped. `steady` only.
    band_lo: ?i16 = default_band_lo,
    band_hi: ?i16 = default_band_hi,
    jitter: i16 = default_jitter,
    /// Probe BC's own band. `null` puts it in A's.
    ///
    /// The two probes clamp to different levels on the floating rig: a hand on
    /// plant A holds its probe at 650-750, a hand on plant B holds BC at about
    /// 1. Same question, different answer, which is what a band per probe is
    /// for — and why one band for both cannot work here.
    band_lo_bc: ?i16 = null,
    band_hi_bc: ?i16 = null,
    /// How long the stillness must be gone before the touch is. `steady` only.
    drop_ms: f32 = default_drop_ms,
    level: f32 = default_level,
    hold_ms: f32 = default_hold_ms,
    average_ms: f32 = default_average_ms,
    baseline_s: f32 = default_baseline_s,
    settle_ms: f32 = default_settle_ms,
    /// Probe BC's own threshold and hold, when it wants asking a different
    /// question from A's. `null` gives it A's.
    ///
    /// The two probes do different jobs and can afford different answers.
    /// Plant A's probe is a pitch: a wrong latch there moves a drone that was
    /// already sounding, and nobody can tell. BC's is a switch that starts a
    /// recording and runs it for minutes, so a wrong latch there is the fault
    /// people actually hear. BC can be held to a much larger move than A
    /// without making A deaf.
    level_bc: ?f32 = null,
    hold_bc_ms: ?f32 = null,
    /// A second threshold, in counts from the probe's own rest, that a touch
    /// must also clear. `null` asks the score alone.
    ///
    /// The score divides by how much the probe normally wanders, so a probe
    /// that goes quiet scores enormous deviations on a move that is, in counts,
    /// nothing at all. `mad_floor` is the crude guard against that; this is the
    /// one that can be set from the room, and it says how big a move has to be
    /// in the units the probe actually reads.
    counts: ?i16 = null,
    counts_bc: ?i16 = null,
    /// How long a touch may last and still count. `null` latches instead: the
    /// state stays on for as long as the probe reads touched.
    ///
    /// A tap is a move out and a move back. An excursion that never comes back
    /// is a hand left resting, a probe that has drifted or wiring settling
    /// after power-on, and none of those is somebody asking for a recording.
    /// Timed from the moment the hold has been satisfied, so the whole gesture
    /// may last the hold plus this.
    window_ms: ?f32 = null,
    window_bc_ms: ?f32 = null,

    /// This config as probe BC sees it: its own threshold and hold where it was
    /// given them, A's everywhere else.
    pub fn forBc(self: Config) Config {
        var bc = self;
        bc.level = self.level_bc orelse self.level;
        bc.hold_ms = self.hold_bc_ms orelse self.hold_ms;
        if (self.band_lo_bc) |lo| bc.band_lo = lo;
        if (self.band_hi_bc) |hi| bc.band_hi = hi;
        bc.band_lo_bc = null;
        bc.band_hi_bc = null;
        bc.counts = self.counts_bc orelse self.counts;
        bc.window_ms = self.window_bc_ms orelse self.window_ms;
        bc.level_bc = null;
        bc.hold_bc_ms = null;
        bc.counts_bc = null;
        bc.window_bc_ms = null;
        return bc;
    }
};

/// One probe, judged against itself.
pub const Detector = struct {
    mean: Mean,
    baseline: Baseline,
    level: f32,
    /// Polls of agreement needed to change the answer, and where the counter
    /// sits between 0 and it.
    hold: u32,
    count: u32,
    /// The latched answer, held between the ends of the counter's travel, which
    /// is what stops a score hovering on the line from chattering.
    on: bool,
    /// The last score, kept for the log and the status line.
    z: f32,
    /// The last mean, which is what the score and the pitch are both taken
    /// from.
    last_mean: i16,
    /// Set while the other probe has this one pulled off its rest. The score is
    /// then measured from where the pull left it, so only a further move counts.
    base_override: ?i16,
    /// A move in counts that a touch must also clear, on top of the score.
    counts: ?i16,
    /// Polls an excursion may last and still be a tap. `null` latches instead.
    window: ?u32,
    /// Polls the current excursion has been latched for.
    over_polls: u32,
    /// Whether the excursion under way is still eligible to fire on its way
    /// out. Cleared when it outlasts the window.
    armed: bool,
    /// Set when an excursion outlasted the window, and held until the probe
    /// comes back to rest. Without it a hand left on the plant sits at the
    /// threshold and re-arms on every poll.
    blocked: bool,
    /// This poll's answer in window mode: true on the one poll the tap ends.
    pulse: bool,
    /// Which question this probe is asked.
    model: Model,
    /// The band and the jitter allowance, in counts. `steady` only, and the
    /// band is optional: unset, any level will do so long as it holds still.
    band_lo: ?i16,
    band_hi: ?i16,
    jitter: i16,
    /// Polls of lost stillness that call a touch off, and how many have come
    /// in a row. `steady` only.
    drop: u32,
    dropped: u32,
    /// The previous raw reading, which is what the jitter is measured against.
    /// `null` before the first. `steady` only.
    prev_raw: ?i16,
    /// Whether the probe is at rest as this model sees it: back inside the
    /// deviation model's release band, or no longer still in the steady one.
    at_rest: bool,

    pub fn init(cfg: Config) Detector {
        return .{
            .mean = .init(holdPolls(cfg.average_ms, cfg.sample_rate, cfg.poll_frames)),
            .baseline = .init(cfg.baseline_s, cfg.sample_rate, cfg.poll_frames),
            .level = cfg.level,
            .hold = @max(holdPolls(cfg.hold_ms, cfg.sample_rate, cfg.poll_frames), 1),
            .count = 0,
            .on = false,
            .z = 0.0,
            .last_mean = 0,
            .base_override = null,
            .counts = cfg.counts,
            .window = if (cfg.window_ms) |ms|
                @max(holdPolls(ms, cfg.sample_rate, cfg.poll_frames), 1)
            else
                null,
            .over_polls = 0,
            .armed = false,
            .blocked = false,
            .pulse = false,
            .model = cfg.model,
            .band_lo = cfg.band_lo,
            .band_hi = cfg.band_hi,
            .jitter = cfg.jitter,
            .drop = @max(holdPolls(cfg.drop_ms, cfg.sample_rate, cfg.poll_frames), 1),
            .dropped = 0,
            .prev_raw = null,
            .at_rest = true,
        };
    }

    /// Forget the excursion under way, latch and all. What the settle and the
    /// warmup both need: the readings either side of them are not one gesture.
    pub fn reset(self: *Detector) void {
        self.count = 0;
        self.on = false;
        self.over_polls = 0;
        self.armed = false;
        self.blocked = false;
        self.pulse = false;
        self.dropped = 0;
    }

    /// What the score is measured from: the crosstalk floor while one is set,
    /// the learned median otherwise.
    pub fn base(self: *const Detector) i16 {
        return self.base_override orelse self.baseline.base;
    }

    /// How far the probe sits from rest. Unsigned, because this is what the
    /// drone's pitch is mapped from and a pitch has no sign.
    ///
    /// In the steady model there is no rest to be far from, so what the pitch
    /// gets instead is the level the probe went still at, measured from the
    /// bottom of the band where there is one and from zero where there is not.
    /// A held probe moves by five to nine counts against a jitter allowance of
    /// eight, so `--pitch-span` wants to be about that much travel and the
    /// pitch will wander inside it on its own.
    pub fn deviation(self: *const Detector) i16 {
        return switch (self.model) {
            .deviation => clampedAbsDiff(self.last_mean, self.base()),
            // Nobody on it is no pitch at all. The mean only takes still
            // readings, so without this it would keep reporting the level of
            // the last touch for as long as the rig ran, and the drone would
            // never fall home — the release would be a gate closing over a
            // pitch that never moved.
            .steady => if (self.on)
                @max(self.last_mean - (self.band_lo orelse 0), 0)
            else
                0,
        };
    }

    /// Whether this reading is a clamped probe: inside the band and no further
    /// than the jitter allowance from the one before it.
    fn isStill(self: *const Detector, raw: i16) bool {
        if (self.band_lo) |lo| if (raw < lo) return false;
        if (self.band_hi) |hi| if (raw > hi) return false;
        const prev = self.prev_raw orelse return true;
        return clampedAbsDiff(raw, prev) <= self.jitter;
    }

    /// One poll of the steady model, which sets `on` and `at_rest`.
    ///
    /// Judged on the raw reading, never on the mean. The mean is an average of
    /// the flailing, which is a plausible-looking number about nothing, and
    /// averaging is exactly what destroys the stillness that is the signal
    /// here. The mean is still kept, from the still readings only, because the
    /// pitch wants something that does not step and holds through a dropout.
    fn stepSteady(self: *Detector, raw: i16) void {
        const still = self.isStill(raw);
        self.prev_raw = raw;
        self.at_rest = !still;

        // The score has no meaning here; what the log and the status line get
        // instead is the move that was judged, in jitter allowances.
        self.z = @as(f32, @floatFromInt(self.deviation())) /
            @as(f32, @floatFromInt(@max(self.jitter, 1)));

        if (self.blocked) {
            if (self.at_rest) self.blocked = false;
            self.count = 0;
            self.on = false;
            return;
        }

        // The release leaks rather than counting a run: a flailing probe throws
        // the odd repeated reading, and a release that demanded consecutive
        // movement would have those reset it every time — a touch, once
        // latched, would never end. Leaking also costs a dropout inside a real
        // touch nothing, because the still readings either side pay it back.
        if (still) {
            self.last_mean = self.mean.push(raw);
            self.dropped -|= 1;
            self.count = @min(self.count + 1, self.hold);
            if (self.count == self.hold) self.on = true;
        } else {
            self.count = 0;
            self.dropped = @min(self.dropped + 1, self.drop);
            if (self.dropped == self.drop) self.on = false;
        }
    }

    /// One poll of the deviation model, which sets `on` and `at_rest`.
    ///
    /// Returns false when the baseline has nothing behind it yet, which is the
    /// one case where this model cannot answer at all.
    fn stepDeviation(self: *Detector, raw: i16) bool {
        self.last_mean = self.mean.push(raw);
        self.baseline.push(self.last_mean);

        const denom = @max(self.baseline.mad, mad_floor);
        self.z = (@as(f32, @floatFromInt(self.last_mean)) -
            @as(f32, @floatFromInt(self.base()))) / denom;

        // Before the median has anything behind it the score is noise about
        // noise, and acting on it would start a clip at power-on.
        if (!self.baseline.ready()) {
            self.reset();
            return false;
        }

        const dev = self.deviation();
        const over = @abs(self.z) >= self.level and
            (self.counts == null or dev >= self.counts.?);

        // Back at rest is half of whatever it took to leave it, in both units.
        // Requiring the same number both ways would let a reading sitting on
        // the line arm and disarm on alternate polls.
        const back = @abs(self.z) < self.level / 2.0 and
            (self.counts == null or dev < @divTrunc(self.counts.?, 2));
        self.at_rest = back;

        // A hand that outlasted the window is still on the plant, and reads as
        // over the threshold for as long as it stays. Nothing may start again
        // until the probe has been back at rest.
        if (self.blocked) {
            if (back) self.blocked = false;
            self.count = 0;
            self.on = false;
            return false;
        }

        // On the score alone, releasing as soon as the reading is not over is
        // what this has always done, and the test bears it. Once there is a
        // second threshold in play the reading spends time between the two,
        // and decaying there chatters the latch off and straight back on —
        // which, on a probe that starts recordings, is heard as clip after
        // clip. So anything with a band waits to be back at rest.
        const banded = self.window != null or self.counts != null;
        if (over) {
            self.count = @min(self.count + 1, self.hold);
        } else if (!banded or back) {
            self.count -|= 1;
        }

        if (self.count == self.hold) {
            self.on = true;
        } else if (self.count == 0) {
            self.on = false;
        }
        return true;
    }

    /// Feed one poll's signed reading and get this poll's answer: the latched
    /// state, or in window mode the single poll a tap ends on.
    pub fn update(self: *Detector, raw: i16) bool {
        self.pulse = false;
        const was_on = self.on;

        switch (self.model) {
            .deviation => if (!self.stepDeviation(raw)) return false,
            .steady => self.stepSteady(raw),
        }

        // The tap layer is the same question of either model: did the state go
        // on and back off again soon enough to have been a gesture rather than
        // a hand left where it was?
        const window = self.window orelse return self.on;

        if (self.on) {
            if (!was_on) {
                self.over_polls = 0;
                self.armed = true;
            }
            self.over_polls += 1;
            if (self.over_polls > window) {
                self.count = 0;
                self.on = false;
                self.dropped = 0;
                self.armed = false;
                self.blocked = true;
            }
        } else if (was_on and self.armed) {
            // The move out was big enough and the move back came in time: this
            // was a tap, and it is reported the instant it ends.
            self.pulse = true;
            self.armed = false;
        }
        return self.pulse;
    }
};

/// Which plants are being touched.
pub const State = enum { none, plant_a, plant_bc, both };

/// Both probes, and the rule that tells a touch from the other probe's shadow.
///
/// Probe A is dominant: on the bench, touching plant A drags the other probe
/// down to about -2049, while touching the other leaves plant A's probe exactly
/// where it was. So the arbitration is one-directional, and the shadow it has
/// to see through is the awkward kind — the crosstalk floor is the same value a
/// genuine touch on the other probe produces, so no level can separate them.
///
/// What separates them is that a real touch on top of the crosstalk goes
/// further still, to about -3900. So when A latches, the other probe is given a
/// moment to settle and whatever it settles at becomes its rest for as long as
/// A is held. Sitting on the crosstalk floor is then no deviation at all, and
/// only a further move counts. Nothing here is a tuned constant: the floor is
/// measured each time, so it can move with the weather.
pub const Machine = struct {
    a: Detector,
    bc: Detector,
    /// How long the other probe is given to settle, and how much of that is
    /// left. While it is running, BC cannot latch: the transition itself is
    /// exactly the kind of large move that would look like a touch.
    settle_polls: u32,
    settle_left: u32,
    /// Whether the settle now running ends in a re-baselining. It does not when
    /// BC was already touched before A arrived.
    rebasing: bool,
    prev_a: bool,

    pub fn init(cfg: Config) Machine {
        return .{
            .a = .init(cfg),
            .bc = .init(cfg.forBc()),
            .settle_polls = holdPolls(cfg.settle_ms, cfg.sample_rate, cfg.poll_frames),
            .settle_left = 0,
            .rebasing = false,
            .prev_a = false,
        };
    }

    /// Feed one poll of both probes, signed and unrectified, and get the state.
    pub fn update(self: *Machine, raw_a: i16, raw_bc: i16) State {
        const a_on = self.a.update(raw_a);

        // The shadow is a deviation-model problem. On the floating rig a hand
        // on A leaves BC flipping between zero and the rail, nowhere near the
        // band, so there is nothing to see through — and freezing a baseline
        // the steady model never reads, or resetting BC's stillness for a third
        // of a second every time A latches, would only lose real touches.
        if (self.bc.model == .steady) {
            const bc_on = self.bc.update(raw_bc);
            if (a_on and bc_on) return .both;
            if (a_on) return .plant_a;
            if (bc_on) return .plant_bc;
            return .none;
        }

        // A's edges are handled before BC is updated, so the freeze is in place
        // before the first crosstalk-poisoned reading could be learned.
        if (a_on and !self.prev_a and !self.bc.on) {
            self.rebasing = true;
            self.settle_left = self.settle_polls;
            self.bc.baseline.frozen = true;
        } else if (!a_on and self.prev_a) {
            self.rebasing = false;
            self.settle_left = 0;
            self.bc.base_override = null;
            self.bc.baseline.frozen = false;
        }
        self.prev_a = a_on;

        var bc_on = self.bc.update(raw_bc);

        if (self.settle_left > 0) {
            self.settle_left -= 1;
            self.bc.reset();
            bc_on = false;
            if (self.settle_left == 0 and self.rebasing) {
                self.bc.base_override = self.bc.last_mean;
            }
        }

        if (a_on and bc_on) return .both;
        if (a_on) return .plant_a;
        if (bc_on) return .plant_bc;
        return .none;
    }
};

test "the hold converts to whole polls, never to none" {
    try testing.expectEqual(@as(u32, 34), holdPolls(100.0, 44100, 128));
    try testing.expectEqual(@as(u32, 3), holdPolls(10.0, 44100, 128));
    try testing.expectEqual(@as(u32, 1), holdPolls(0.0, 44100, 128));
}

test "the mean passes a steady reading through, sign and all" {
    var m = Mean.init(100);
    for (0..500) |_| try testing.expectEqual(@as(i16, -2049), m.push(-2049));
}

test "the mean answers from the first poll, not after a full window" {
    var m = Mean.init(100);
    try testing.expectEqual(@as(i16, -2000), m.push(-2000));
    try testing.expectEqual(@as(i16, -1000), m.push(0));
}

test "a negative reading lowers the mean instead of reading as silence" {
    // `trigger.Average` clamped negatives to zero, which is the whole reason
    // this type exists: probe A never once reads positive while untouched.
    var m = Mean.init(4);
    _ = m.push(-2049);
    _ = m.push(-2049);
    _ = m.push(-2049);
    try testing.expectEqual(@as(i16, -2049), m.push(-2049));
}

test "one spike moves the mean by a bounded amount and then leaves it" {
    var m = Mean.init(100);
    for (0..100) |_| _ = m.push(0);
    try testing.expectEqual(@as(i16, 327), m.push(32767));
    for (0..99) |_| _ = m.push(0);
    try testing.expectEqual(@as(i16, 0), m.push(0));
}

test "a window longer than the buffer is clamped rather than overrunning it" {
    var m = Mean.init(holdPolls(100_000.0, 44100, 128));
    try testing.expectEqual(max_mean_polls, m.len);
    for (0..2000) |_| _ = m.push(-1000);
    try testing.expectEqual(@as(i16, -1000), m.push(-1000));
}

/// Ten seconds of window at the engine's real poll rate, which is what the
/// baseline tests want: long enough to have a median, short enough to fill.
fn testBaseline(window_s: f32) Baseline {
    return Baseline.init(window_s, 44100, 128);
}

test "the baseline is pushed at ten hertz, not at the poll rate" {
    var b = testBaseline(60.0);
    // 344.5 polls a second, so one push every 34 polls.
    try testing.expectEqual(@as(u32, 34), b.decim);
    // Sixty seconds of ten-hertz pushes.
    try testing.expectEqual(@as(u32, 600), b.len);

    for (0..34) |_| b.push(100);
    try testing.expectEqual(@as(u32, 1), b.count);
    for (0..34) |_| b.push(100);
    try testing.expectEqual(@as(u32, 2), b.count);
}

test "the median is the reading a steady probe keeps giving" {
    var b = testBaseline(10.0);
    for (0..34 * 100) |_| b.push(-2049);
    try testing.expectEqual(@as(i16, -2049), b.base);
    // A probe that never moves has no deviation to speak of.
    try testing.expect(b.mad < 1.0);
}

test "the median ignores a minority of touched samples" {
    var b = testBaseline(70.0);
    // Seventy seconds of idle at -2049, then nine seconds of touch at +660: the
    // touch is a minority of the window and the median does not follow it.
    for (0..34 * 700) |_| b.push(-2049);
    for (0..34 * 90) |_| b.push(660);
    try testing.expectEqual(@as(i16, -2049), b.base);
}

test "the mad measures how far a noisy probe normally wanders" {
    var b = testBaseline(10.0);
    // The shape of the untouched BC probe: positive, broad, centred near 1000.
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    for (0..34 * 400) |_| b.push(@intCast(rand.uintLessThan(u16, 2001)));
    try testing.expect(b.base > 800 and b.base < 1200);
    // A uniform spread of 0..2000 has a median absolute deviation near 500.
    try testing.expect(b.mad > 300.0 and b.mad < 700.0);
}

test "a frozen baseline is not moved by what arrives while it is frozen" {
    var b = testBaseline(10.0);
    for (0..34 * 100) |_| b.push(-2049);
    b.frozen = true;
    for (0..34 * 100) |_| b.push(660);
    try testing.expectEqual(@as(i16, -2049), b.base);
}

test "a detector may not answer until the baseline has warmed up" {
    var b = testBaseline(60.0);
    try testing.expect(!b.ready());
    // Three seconds of ten-hertz pushes.
    for (0..34 * 30) |_| b.push(-2049);
    try testing.expect(b.ready());
}

/// The engine's real rates, with the windows the installation runs.
fn testConfig() Config {
    return .{ .sample_rate = 44100, .poll_frames = 128 };
}

/// Feed a detector one value for `polls` polls and return its last answer.
fn hold(d: *Detector, raw: i16, polls: usize) bool {
    var on = false;
    for (0..polls) |_| on = d.update(raw);
    return on;
}

test "a detector says nothing until its baseline has warmed up" {
    var d = Detector.init(testConfig());
    // One second of the probe's resting level, which is under the three the
    // warm-up wants.
    try testing.expect(!hold(&d, -2049, 344));
}

test "probe A's pinned idle never latches" {
    var d = Detector.init(testConfig());
    // Ten minutes of what the bench capture shows: -2049 and -2050, nothing
    // else. A MAD of half a count would score that at z = 2 without the floor.
    var prng = std.Random.DefaultPrng.init(3);
    const rand = prng.random();
    for (0..344 * 600) |_| {
        const raw: i16 = if (rand.boolean()) -2049 else -2050;
        try testing.expect(!d.update(raw));
    }
}

test "probe A's step to touched latches after the hold and not before" {
    var d = Detector.init(testConfig());
    _ = hold(&d, -2049, 344 * 10);
    try testing.expect(!d.on);

    // The hold is 100 ms, 34 polls. The mean window is 200 ms, so the mean
    // needs a moment to arrive before the vote can even start.
    _ = hold(&d, 660, 34);
    try testing.expect(!d.on);
    _ = hold(&d, 660, 344);
    try testing.expect(d.on);
}

test "an isolated spike never latches" {
    var d = Detector.init(testConfig());
    for (0..344 * 60) |i| {
        const raw: i16 = if (i % 500 == 0) 660 else -2049;
        try testing.expect(!d.update(raw));
    }
}

test "probe BC's noisy positive idle never latches" {
    var d = Detector.init(testConfig());
    var prng = std.Random.DefaultPrng.init(5);
    const rand = prng.random();
    for (0..344 * 300) |_| {
        try testing.expect(!d.update(@intCast(rand.uintLessThan(u16, 2001))));
    }
}

test "probe BC latches on a drop through zero, which no rectified reading could" {
    var d = Detector.init(testConfig());
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    for (0..344 * 60) |_| _ = d.update(@intCast(rand.uintLessThan(u16, 2001)));
    try testing.expect(!d.on);

    // -2049 is 2049 once rectified, which sits inside the idle spread of
    // 0..2000 the probe was just showing. Signed, it is nowhere near it.
    _ = hold(&d, -2049, 344);
    try testing.expect(d.on);
}

test "it releases when the probe returns to rest" {
    var d = Detector.init(testConfig());
    _ = hold(&d, -2049, 344 * 10);
    _ = hold(&d, 660, 344);
    try testing.expect(d.on);
    _ = hold(&d, -2049, 344);
    try testing.expect(!d.on);
}

/// Feed a detector one value for `polls` polls and count the taps it reported.
fn taps(d: *Detector, raw: i16, polls: usize) usize {
    var fired: usize = 0;
    for (0..polls) |_| {
        if (d.update(raw)) fired += 1;
    }
    return fired;
}

fn windowConfig(window_ms: f32) Config {
    return .{ .sample_rate = 44100, .poll_frames = 128, .window_ms = window_ms };
}

test "in window mode a tap fires once, on the way out" {
    var d = Detector.init(windowConfig(1000.0));
    _ = taps(&d, 660, 344 * 10);

    // Half a second of hand. Being touched is not the answer in window mode:
    // nothing has been asked for until the hand comes off.
    try testing.expectEqual(@as(usize, 0), taps(&d, -2049, 172));
    try testing.expect(d.on);

    // And off again. One poll of it, not one per poll of rest afterwards.
    try testing.expectEqual(@as(usize, 1), taps(&d, 660, 344));
}

test "in window mode a hand left on the plant never fires" {
    var d = Detector.init(windowConfig(1000.0));
    _ = taps(&d, 660, 344 * 10);

    // Five seconds, well past the window.
    try testing.expectEqual(@as(usize, 0), taps(&d, -2049, 344 * 5));
    // And taking it off is not a tap either: the gesture was disqualified
    // while it was still under way, not at its end.
    try testing.expectEqual(@as(usize, 0), taps(&d, 660, 344 * 2));
}

test "a disqualified hand can tap again once the probe is back at rest" {
    var d = Detector.init(windowConfig(1000.0));
    _ = taps(&d, 660, 344 * 10);
    _ = taps(&d, -2049, 344 * 5);
    _ = taps(&d, 660, 344 * 2);

    try testing.expectEqual(@as(usize, 0), taps(&d, -2049, 172));
    try testing.expectEqual(@as(usize, 1), taps(&d, 660, 344));
}

test "the window does not replace the hold: a move too brief to count fires nothing" {
    var d = Detector.init(.{
        .sample_rate = 44100,
        .poll_frames = 128,
        .hold_ms = 1000.0,
        .window_ms = 2000.0,
    });
    _ = taps(&d, 660, 344 * 10);
    // Half a second of hand against a hold of a whole one: never latched, so
    // there is no excursion for the way out to end.
    try testing.expectEqual(@as(usize, 0), taps(&d, -2049, 172));
    try testing.expect(!d.on);
    try testing.expectEqual(@as(usize, 0), taps(&d, 660, 344 * 2));
}

test "the counts gate ignores a move that only scores big because the probe is quiet" {
    // A probe reading two values and nothing else has a MAD at the floor, so a
    // move of 200 counts scores eight deviations and latches on the score
    // alone. In counts it is a tenth of what a touch on this rig is worth.
    var quiet = Detector.init(testConfig());
    var gated = Detector.init(.{ .sample_rate = 44100, .poll_frames = 128, .counts = 1000 });
    for (0..344 * 10) |i| {
        const raw: i16 = if (i % 2 == 0) -2049 else -2050;
        _ = quiet.update(raw);
        _ = gated.update(raw);
    }

    _ = hold(&quiet, -1849, 344);
    _ = hold(&gated, -1849, 344);
    try testing.expect(quiet.on);
    try testing.expect(!gated.on);

    // The move a real touch makes still gets through.
    _ = hold(&gated, 660, 344);
    try testing.expect(gated.on);
}

test "an override baseline is what the score is measured from" {
    var d = Detector.init(testConfig());
    _ = hold(&d, -2049, 344 * 10);
    d.base_override = 660;
    // Long enough for the mean to arrive at the override; a single poll would
    // still be averaging in the ten seconds of rest before it.
    _ = hold(&d, 660, 344);
    // Sitting exactly on the override is no deviation at all, even though it is
    // a long way from what the median learned.
    try testing.expectApproxEqAbs(@as(f32, 0.0), d.z, 0.5);
}

test "deviation is the distance from rest, which is what the pitch wants" {
    var d = Detector.init(testConfig());
    _ = hold(&d, -2049, 344 * 10);
    try testing.expectEqual(@as(i16, 0), d.deviation());
    _ = hold(&d, 660, 344);
    try testing.expectEqual(@as(i16, 2709), d.deviation());
}

/// Feed the machine one pair of readings for `polls` polls, last answer wins.
fn holdBoth(m: *Machine, raw_a: i16, raw_bc: i16, polls: usize) State {
    var state: State = .none;
    for (0..polls) |_| state = m.update(raw_a, raw_bc);
    return state;
}

/// The idle rig: probe A pinned, probe BC wandering about the positive half.
fn idle(m: *Machine, rand: std.Random, polls: usize) State {
    var state: State = .none;
    for (0..polls) |_| {
        state = m.update(-2049, @intCast(rand.uintLessThan(u16, 2001)));
    }
    return state;
}

test "an idle rig reports nothing touched" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    try testing.expectEqual(State.none, idle(&m, prng.random(), 344 * 120));
}

test "plant A alone" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);
    try testing.expectEqual(State.plant_a, holdBoth(&m, 660, 900, 344 * 2));
}

test "plant BC alone" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);
    try testing.expectEqual(State.plant_bc, holdBoth(&m, -2049, -2049, 344 * 2));
}

test "crosstalk from A does not read as a touch on BC" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);

    // A is touched and pulls BC down with it. Rectified, BC's -2049 is
    // indistinguishable from its idle spread; signed, it is a huge move. Only
    // the re-baselining tells it apart from a real touch.
    try testing.expectEqual(State.plant_a, holdBoth(&m, 660, -2049, 344 * 5));
}

test "a real touch on BC while A is held goes further than the crosstalk" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);
    _ = holdBoth(&m, 660, -2049, 344 * 5);
    // The bench capture's simultaneous touch: BC keeps going, past the floor
    // its crosstalk settled at.
    try testing.expectEqual(State.both, holdBoth(&m, 660, -3947, 344 * 2));
}

test "BC touched first is not re-baselined out from under itself" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);

    try testing.expectEqual(State.plant_bc, holdBoth(&m, -2049, -2049, 344 * 2));
    // A joins in. BC was already latched, so nothing about it is reinterpreted.
    try testing.expectEqual(State.both, holdBoth(&m, 660, -2049, 344 * 2));
}

test "releasing A puts BC back on its learned rest" {
    var m = Machine.init(testConfig());
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 60);
    _ = holdBoth(&m, 660, -2049, 344 * 5);
    try testing.expectEqual(@as(?i16, -2049), m.bc.base_override);

    try testing.expectEqual(State.none, idle(&m, prng.random(), 344 * 3));
    try testing.expectEqual(@as(?i16, null), m.bc.base_override);
}

test "BC can be given its own threshold and hold" {
    const m = Machine.init(.{
        .sample_rate = 44100,
        .poll_frames = 128,
        .level = 6.0,
        .hold_ms = 100.0,
        .level_bc = 20.0,
        .hold_bc_ms = 30.0,
    });
    try testing.expectEqual(@as(f32, 6.0), m.a.level);
    try testing.expectEqual(@as(f32, 20.0), m.bc.level);
    // 30 ms of polls against 100 ms of them.
    try testing.expect(m.bc.hold < m.a.hold);
}

test "BC can be given a counts gate and a window of its own" {
    const m = Machine.init(.{
        .sample_rate = 44100,
        .poll_frames = 128,
        .counts_bc = 1500,
        .window_bc_ms = 1000.0,
    });
    try testing.expectEqual(@as(?i16, null), m.a.counts);
    try testing.expectEqual(@as(?u32, null), m.a.window);
    try testing.expectEqual(@as(?i16, 1500), m.bc.counts);
    try testing.expectEqual(holdPolls(1000.0, 44100, 128), m.bc.window.?);
}

test "BC is asked A's question when it was given none of its own" {
    const m = Machine.init(.{ .sample_rate = 44100, .poll_frames = 128, .level = 9.0 });
    try testing.expectEqual(m.a.level, m.bc.level);
    try testing.expectEqual(m.a.hold, m.bc.hold);
}

test "a move that latches BC at A's level is ignored at its own bigger one" {
    // The same reading through two machines, so what differs is the threshold
    // and nothing else. BC's deviation here is a few hundred counts, which is
    // ten-ish deviations: over A's 6, nowhere near 200.
    var shared = Machine.init(testConfig());
    var split = Machine.init(Config{
        .sample_rate = 44100,
        .poll_frames = 128,
        .level_bc = 200.0,
    });
    var prng_a = std.Random.DefaultPrng.init(11);
    var prng_b = std.Random.DefaultPrng.init(11);
    _ = idle(&shared, prng_a.random(), 344 * 60);
    _ = idle(&split, prng_b.random(), 344 * 60);

    try testing.expectEqual(State.plant_bc, holdBoth(&shared, -2049, 1470, 344 * 2));
    try testing.expectEqual(State.none, holdBoth(&split, -2049, 1470, 344 * 2));
}

test "a touch longer than half the baseline window reads as released" {
    // The documented limit of a median baseline. Ten-second window here so the
    // test does not have to run for minutes; the installation's default is 60.
    var cfg = testConfig();
    cfg.baseline_s = 10.0;
    var m = Machine.init(cfg);
    var prng = std.Random.DefaultPrng.init(11);
    _ = idle(&m, prng.random(), 344 * 20);

    try testing.expectEqual(State.plant_a, holdBoth(&m, 660, 900, 344 * 2));
    // Held past half the window, the median migrates onto the touched level and
    // the score decays to nothing. Raise --touch-baseline to push this out.
    try testing.expectEqual(State.none, holdBoth(&m, 660, 900, 344 * 20));
}

const floating = @embedFile("testdata/touch-floating.txt");

/// The floating-probe capture, split into the blocks its comment lines mark
/// out: 0 both probes flailing, 1 a hand on A, 2 flailing again, 3 a hand on BC
/// with the contact dropping in and out, 4 a hand on BC throughout.
fn floatingSection(want: usize, rows: *[128][2]i16) usize {
    var block: usize = 0;
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, floating, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') {
            // A comment only ends a block that had something in it; the header
            // is a run of them with no readings between.
            if (n != 0) {
                if (block == want) return n;
                block += 1;
                n = 0;
            }
            continue;
        }
        var cols = std.mem.tokenizeAny(u8, trimmed, " \t");
        const a_text = cols.next() orelse continue;
        const bc_text = cols.next() orelse continue;
        rows[n] = .{
            std.fmt.parseInt(i16, a_text, 10) catch continue,
            std.fmt.parseInt(i16, bc_text, 10) catch continue,
        };
        n += 1;
        if (n == rows.len) return n;
    }
    return if (block == want) n else 0;
}

/// The capture was taken at 860 SPS shared between the probes. The engine polls
/// each one every 128 frames of 44100, which is close enough that a poll is a
/// poll; what the fixture is for is the shape, not the clock.
fn steadyConfig() Config {
    return .{
        .sample_rate = 44100,
        .poll_frames = 128,
        .model = .steady,
        // Ten polls of attack, thirty of release. Ten is the floor: untouched,
        // BC sits dead still at 1 for as long as eight polls at a stretch, and
        // with no band to throw those out on level the attack is the only thing
        // that tells them from a hand. Twelve is the shortest real touch in the
        // capture, so there is not much room above it either.
        .hold_ms = 30.0,
        .drop_ms = 87.0,
    };
}

/// Feed one probe's column through a detector and report how it answered.
fn steadyRun(d: *Detector, rows: []const [2]i16, probe: usize) struct { on: usize, edges: usize } {
    var on: usize = 0;
    var edges: usize = 0;
    var prev = false;
    for (rows) |row| {
        const now = d.update(row[probe]);
        if (now) on += 1;
        if (now and !prev) edges += 1;
        prev = now;
    }
    return .{ .on = on, .edges = edges };
}

test "the steady model is not put through the crosstalk settle" {
    // Both probes on the floating rig, played through the machine as recorded:
    // A latches on its own block and BC on both of its, and A's edges do not
    // reach into BC.
    var rows: [128][2]i16 = undefined;
    var m = Machine.init(steadyConfig());

    const flail = floatingSection(0, &rows);
    for (rows[0..flail]) |row| try testing.expectEqual(State.none, m.update(row[0], row[1]));

    const a_held = floatingSection(1, &rows);
    var seen_a = false;
    for (rows[0..a_held]) |row| {
        const st = m.update(row[0], row[1]);
        if (st == .plant_a) seen_a = true;
        try testing.expect(st != .plant_bc and st != .both);
    }
    try testing.expect(seen_a);

    const bc_held = floatingSection(4, &rows);
    var seen_bc = false;
    for (rows[0..bc_held]) |row| {
        if (m.update(row[0], row[1]) == .plant_bc) seen_bc = true;
    }
    try testing.expect(seen_bc);
}

test "the deviation model cannot see a touch on a floating probe" {
    // The section where a hand is on probe A. Its median is a median of
    // flailing and its MAD is thousands, so a hand clamping the probe to a
    // quiet 670 scores nothing at all. This is the rig the steady model is for.
    var rows: [128][2]i16 = undefined;
    const n = floatingSection(1, &rows);
    var d = Detector.init(testConfig());
    const answer = steadyRun(&d, rows[0..n], 0);
    try testing.expectEqual(@as(usize, 0), answer.on);
}

test "the steady model latches on a probe that has gone quiet" {
    var rows: [128][2]i16 = undefined;
    const n = floatingSection(1, &rows);
    try testing.expect(n > 60);

    var d = Detector.init(steadyConfig());
    const answer = steadyRun(&d, rows[0..n], 0);
    // Latched within the first handful of polls and stayed there, once.
    try testing.expectEqual(@as(usize, 1), answer.edges);
    try testing.expect(answer.on > n - 14);
}

test "the steady model reads the other probe as untouched at the same time" {
    // While a hand is on A, BC is flipping between zero and the rail. Nothing
    // in that is inside the band.
    var rows: [128][2]i16 = undefined;
    const n = floatingSection(1, &rows);
    var d = Detector.init(steadyConfig());
    const answer = steadyRun(&d, rows[0..n], 1);
    try testing.expectEqual(@as(usize, 0), answer.on);
}

test "a flailing probe never latches the steady model" {
    for ([_]usize{ 0, 2 }) |section| {
        var rows: [128][2]i16 = undefined;
        const n = floatingSection(section, &rows);
        try testing.expect(n > 10);
        for ([_]usize{ 0, 1 }) |probe| {
            var d = Detector.init(steadyConfig());
            const answer = steadyRun(&d, rows[0..n], probe);
            try testing.expectEqual(@as(usize, 0), answer.on);
        }
    }
}

test "a dropout in the middle of a touch does not end it" {
    // The patchy section: BC is held throughout, but contact is lost for a few
    // polls at a time. A release as quick as the attack lets go on every one of
    // them and the touch is reported in pieces.
    var rows: [128][2]i16 = undefined;
    const n = floatingSection(3, &rows);

    var patient = Detector.init(steadyConfig());
    const held = steadyRun(&patient, rows[0..n], 1);

    var cfg = steadyConfig();
    cfg.drop_ms = 15.0;
    var hasty = Detector.init(cfg);
    const flickered = steadyRun(&hasty, rows[0..n], 1);

    try testing.expectEqual(@as(usize, 1), held.edges);
    try testing.expect(held.on > flickered.on * 3);
}

test "the steady model's pitch is the level the probe went still at" {
    var rows: [128][2]i16 = undefined;
    const n = floatingSection(4, &rows);

    // With no band, the pitch is measured from zero: the clean BC block reads
    // 658-663 and that is what the drone gets.
    var bare = Detector.init(steadyConfig());
    _ = steadyRun(&bare, rows[0..n], 1);
    try testing.expect(bare.deviation() >= 650);
    try testing.expect(bare.deviation() <= 670);

    // Given a band, it is measured from the bottom of it instead, which is the
    // travel a hand can actually produce rather than where the rig happens to
    // clamp.
    var cfg = steadyConfig();
    cfg.band_lo = 600;
    cfg.band_hi = 750;
    var banded = Detector.init(cfg);
    _ = steadyRun(&banded, rows[0..n], 1);
    try testing.expect(banded.deviation() >= 50);
    try testing.expect(banded.deviation() <= 70);
}

test "BC can be given a band of its own, which is what the rig needs" {
    const m = Machine.init(.{
        .sample_rate = 44100,
        .poll_frames = 128,
        .model = .steady,
        .band_lo = 650,
        .band_hi = 750,
        .band_lo_bc = -5,
        .band_hi_bc = 5,
    });
    try testing.expectEqual(@as(i16, 650), m.a.band_lo);
    try testing.expectEqual(@as(i16, 750), m.a.band_hi);
    try testing.expectEqual(@as(i16, -5), m.bc.band_lo);
    try testing.expectEqual(@as(i16, 5), m.bc.band_hi);
}

test "BC is put in A's band when it was given none of its own" {
    const m = Machine.init(.{
        .sample_rate = 44100,
        .poll_frames = 128,
        .model = .steady,
        .band_lo = 650,
        .band_hi = 750,
    });
    try testing.expectEqual(m.a.band_lo, m.bc.band_lo);
    try testing.expectEqual(m.a.band_hi, m.bc.band_hi);
}

test "a zero band on BC needs an attack longer than its untouched parking" {
    // Untouched, BC does not flail evenly: it bounces off zero and the rail,
    // and it sits dead still at 1 for as long as nine polls at a stretch. A
    // zero band with a short attack calls each of those a touch.
    var rows: [128][2]i16 = undefined;
    var cfg = steadyConfig();
    cfg.band_lo_bc = -5;
    cfg.band_hi_bc = 5;

    var hasty = cfg;
    hasty.hold_bc_ms = 15.0;
    var patient = cfg;
    patient.hold_bc_ms = 100.0;

    var hasty_on: usize = 0;
    var patient_on: usize = 0;
    for ([_]usize{ 0, 1, 2, 3 }) |section| {
        const n = floatingSection(section, &rows);
        var h = Detector.init(hasty.forBc());
        var q = Detector.init(patient.forBc());
        for (rows[0..n]) |row| {
            if (h.update(row[1])) hasty_on += 1;
            if (q.update(row[1])) patient_on += 1;
        }
    }
    // Not one poll of it at a hundred milliseconds, against a hold that lasts
    // seconds when a hand is really there.
    try testing.expectEqual(@as(usize, 0), patient_on);
    try testing.expect(hasty_on > 100);
}

test "a probe clamped to zero is a touch, with or without a band to say so" {
    // The rig's other answer: a hand on plant B holds BC at about 1. With no
    // band that is a touch like any other stillness, which is the whole reason
    // the band is optional.
    var bare = Detector.init(steadyConfig().forBc());
    for (0..11) |_| _ = bare.update(1);
    try testing.expect(bare.on);

    var cfg = steadyConfig();
    cfg.band_lo_bc = -5;
    cfg.band_hi_bc = 5;
    cfg.hold_bc_ms = 100.0;
    var banded = Detector.init(cfg.forBc());
    for (0..34) |_| _ = banded.update(1);
    try testing.expect(banded.on);

    // Held to plant A's band, the same readings are nothing at all: this is
    // what a band buys, and what it costs.
    var a_band = steadyConfig();
    a_band.band_lo = 600;
    a_band.band_hi = 750;
    var in_a = Detector.init(a_band);
    for (0..344) |_| try testing.expect(!in_a.update(1));
}

test "the pitch falls home when the hand goes" {
    // The mean only takes still readings, so on release there is nothing to
    // pull it back: what says the touch is over is the latch, not the mean.
    var rows: [128][2]i16 = undefined;
    const n = floatingSection(1, &rows);
    var d = Detector.init(steadyConfig());
    _ = steadyRun(&d, rows[0..n], 0);
    try testing.expect(d.on);
    try testing.expect(d.deviation() > 600);

    // The flailing that follows a release. That block is thirteen polls and
    // the release is thirty, so the opening block's flailing follows it: what
    // matters is that these are readings of nobody touching anything.
    const after = floatingSection(2, &rows);
    for (rows[0..after]) |row| _ = d.update(row[0]);
    const more = floatingSection(0, &rows);
    for (rows[0..more]) |row| _ = d.update(row[0]);
    try testing.expect(!d.on);
    try testing.expectEqual(@as(i16, 0), d.deviation());
}

test "a stray repeated reading in the flailing does not hold a touch open" {
    // A flailing probe lands on the same value twice now and then. Counting a
    // run of movement instead of leaking would let each of those reset the
    // release, and the latch would outlive the hand by the length of the run.
    var d = Detector.init(steadyConfig());
    for (0..20) |_| _ = d.update(669);
    try testing.expect(d.on);

    // Movement, with a repeat every third poll.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const raw: i16 = switch (i % 3) {
            0 => 1,
            1 => 1,
            else => -4096,
        };
        _ = d.update(raw);
    }
    try testing.expect(!d.on);
}

test "a reading outside the band is never still, however little it moved" {
    var cfg = steadyConfig();
    cfg.band_lo = 600;
    cfg.band_hi = 750;
    var d = Detector.init(cfg);
    // Rock steady at 1, and inside this band it is not a touch.
    for (0..344) |_| try testing.expect(!d.update(1));
    try testing.expect(!d.on);
}

const fixture = @embedFile("testdata/touch-sample.txt");

const Row = struct { a: i16, bc: i16 };

/// The bench capture, comment lines dropped.
fn parseFixture(rows: *[128]Row) usize {
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var cols = std.mem.tokenizeAny(u8, trimmed, " \t");
        const a_text = cols.next() orelse continue;
        const bc_text = cols.next() orelse continue;
        rows[n] = .{
            .a = std.fmt.parseInt(i16, a_text, 10) catch continue,
            .bc = std.fmt.parseInt(i16, bc_text, 10) catch continue,
        };
        n += 1;
    }
    return n;
}

test "the bench capture plays through the machine the way it was recorded" {
    var rows: [128]Row = undefined;
    const n = parseFixture(&rows);
    // The capture, minus its comment header. A recount against the checked-in
    // file (5 comment lines, then data) found 97 data rows, not the 96 the
    // plan expected; the row-index assertions below were re-verified against
    // that recount and line up on 0-based indexing, so 97 is what is asserted
    // here rather than what the plan guessed before the file was final.
    try testing.expectEqual(@as(usize, 97), n);

    // The capture has no timestamps, so each row is held for a second of polls.
    // That makes the idle prefix long enough to warm the median and keeps every
    // touch well under half the baseline window.
    const polls_per_row = 344;
    var cfg = testConfig();
    // The capture takes three rows to show the crosstalk arriving, so the
    // settle window has to span them.
    cfg.settle_ms = 4000.0;
    var m = Machine.init(cfg);

    var states: [128]State = undefined;
    var z_bc: [128]f32 = undefined;
    for (rows[0..n], 0..) |row, i| {
        var state: State = .none;
        for (0..polls_per_row) |_| state = m.update(row.a, row.bc);
        states[i] = state;
        z_bc[i] = m.bc.z;
    }

    // Rows 0-28 are the untouched rig. Nothing may fire there, and this is the
    // claim that matters most: every false clip in the room starts here.
    for (states[0..29]) |state| try testing.expectEqual(State.none, state);

    // Rows 29-31: probe A has jumped to +660 while BC is still showing its
    // ordinary positive noise.
    try testing.expectEqual(State.plant_a, states[30]);

    // Rows 33-35: A still held, BC pinned at the crosstalk floor. This is the
    // claim the whole arbitration exists for — BC must not be reported as
    // touched on the strength of a pull it did not choose, even though these
    // rows read exactly like row 44, which is a real touch on BC.
    for (states[33..36]) |state| try testing.expectEqual(State.plant_a, state);

    // Row 44 is the only row in the capture with A at rest and BC negative: a
    // touch on BC alone. What is asserted here is that the machine *sees* it —
    // rectified, this reading was 2049, indistinguishable from the idle spread
    // of 0..2023 the probe shows untouched, and no threshold could have found
    // it. Signed, it is five and a half deviations out.
    //
    // It is deliberately not asserted that the latch fires. This replay holds
    // each row for a whole second of polls, so the 200 ms mean settles exactly
    // onto the row's value and BC's MAD is the raw spread of the rows, 548
    // counts, with no averaging benefit whatever. The rig samples continuously,
    // so a real 200 ms mean covers 69 samples and BC's MAD is far smaller. This
    // is a zero-smoothing worst case the installation never runs in.
    try testing.expect(z_bc[44] < -5.0);

    // The arbitration's whole reason to exist, on measured data: the same
    // -2049-ish reading is loud when BC is genuinely touched (row 44) and
    // quiet when it is only being dragged by A's crosstalk (rows 33-35, scored
    // against the settled override). If these scores were comparable, nothing
    // would tell a real BC touch apart from A's shadow.
    for (z_bc[33..36]) |z| try testing.expect(@abs(z) < @abs(z_bc[44]));

    // Rows 36-37 (-3947, -3766) are what a real touch on BC on top of A's
    // crosstalk looks like, and `both` is what the machine should say there.
    // It is deliberately not asserted: the capture carries no timestamps, so
    // this test holds each row for a second, and at that rate the 200 ms mean
    // does no smoothing and BC's MAD stays as wide as its raw spread. Whether
    // -3947 clears six deviations from the -2049 floor depends on a sample rate
    // this file does not record. The synthetic test in Task 4 covers the rule;
    // a live CSV settles the margin.
}
