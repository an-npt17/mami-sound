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
const spread_mod = @import("spread.zig");

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
/// stillness, and a rolling median of the flailing is a number about nothing.
pub const Model = enum { deviation, steady };

/// How wide the window the `steady` model measures a probe's spread over.
///
/// A second. Long enough that a probe left alone always shows its flailing
/// inside it, short enough that a hand is heard about a second after it lands
/// -- and the hold that follows is counted on top.
pub const default_still_window_ms: f32 = 1000.0;

/// The spread, in counts, at or below which a probe counts as held, and the one
/// at or above which the touch is over.
///
/// Two numbers rather than one because a single line chatters: a probe sitting
/// on it latches and releases on alternate windows, which on plant B is clip
/// after clip. Between the two the state is whatever it already was.
///
/// The gap between them is where the margin lives, and on the capture in
/// `touch.csv` it is enormous: over a one-second window probe BC spends 19% of
/// its time under a spread of 8 and 50% of it over a spread of 2048, with only
/// 3% anywhere between 32 and 512. Anything inside that gap works.
///
/// 64 rather than the 128 the gap would also allow, because `zig build replay
/// -- touch.csv --sweep` shows where the cliff is: every threshold from 4 to
/// 128 reports the same thing on that capture, 12 to 20 touches on A and 26 to
/// 37 on BC, and then 1024 reports A latched for 82% of the run, which is a
/// detector stuck on. Sitting in the middle of the plateau rather than at its
/// edge costs one episode in nine hundred seconds.
pub const default_still_range: i16 = 64;
pub const default_still_release: i16 = 512;

/// How long the readings must stop being still before a touch is called off,
/// in milliseconds. Longer than the attack on purpose: contact drops out for a
/// few polls in the middle of a real touch, and releasing on that would end a
/// clip, or with `--touch-window-bc` start one.
pub const default_drop_ms: f32 = 90.0;

pub const Config = struct {
    sample_rate: u32,
    poll_frames: usize,
    model: Model = .deviation,
    /// How long the stillness must be gone before the touch is. `steady` only.
    drop_ms: f32 = default_drop_ms,
    /// The window and the two thresholds the `steady` model judges by.
    /// `steady` only.
    still_window_ms: f32 = default_still_window_ms,
    still_range: i16 = default_still_range,
    still_release: i16 = default_still_release,
    /// Probe BC's own thresholds. `null` puts it on A's.
    ///
    /// The two probes are not equally clean and do not have to be judged
    /// equally hard: a wrong latch on A moves a drone that was already
    /// sounding, where a wrong latch on BC starts a recording.
    still_range_bc: ?i16 = null,
    still_release_bc: ?i16 = null,
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
    /// Whether this probe drives a voice that sounds while it is held.
    ///
    /// A tap window asks whether a hand left again in time; a held voice needs
    /// to know whether the hand is still there. Both cannot be answered at
    /// once, and it is the hold the room asked for -- so a held probe drops its
    /// window rather than reporting a three-millisecond blip and blocking.
    ///
    /// Per probe, because the two plants are told separately: a held plant A
    /// must not quietly retire the window plant B was given.
    hold: bool = false,
    hold_bc: bool = false,
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
        bc.still_range = self.still_range_bc orelse self.still_range;
        bc.still_release = self.still_release_bc orelse self.still_release;
        bc.still_range_bc = null;
        bc.still_release_bc = null;
        bc.counts = self.counts_bc orelse self.counts;
        bc.window_ms = self.window_bc_ms orelse self.window_ms;
        bc.hold = self.hold_bc;
        bc.hold_bc = false;
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
    /// from. `deviation` only: the steady model reads neither off an average,
    /// and the crosstalk floor it feeds is a deviation-model idea too.
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
    /// Polls of lost stillness that call a touch off, and how many have come
    /// in a row. `steady` only.
    drop: u32,
    dropped: u32,
    /// Whether the probe is at rest as this model sees it: back inside the
    /// deviation model's release band, or no longer still in the steady one.
    at_rest: bool,
    /// How tightly the recent readings cluster, and the two spreads that decide
    /// what that means. `steady` only.
    spread: spread_mod.Spread,
    still_range: i16,
    still_release: i16,

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
            // A deviation-model idea, and only ever applied there. That model
            // reads an excursion that never comes back as drift, a probe
            // settling after power-on, or a hand left resting -- none of which
            // is somebody asking for a recording. The steady model asks the
            // opposite question: a touch there is a hand that stays, so a tap
            // window would discard every real one and then block the probe
            // until it was let go. The preset still carries `window_bc_ms` for
            // the rig it was measured on, so this cannot be left to the caller
            // remembering to clear it.
            .window = if (cfg.model == .deviation and !cfg.hold) blk: {
                const ms = cfg.window_ms orelse break :blk null;
                break :blk @max(holdPolls(ms, cfg.sample_rate, cfg.poll_frames), 1);
            } else null,
            .over_polls = 0,
            .armed = false,
            .blocked = false,
            .pulse = false,
            .model = cfg.model,
            .drop = @max(holdPolls(cfg.drop_ms, cfg.sample_rate, cfg.poll_frames), 1),
            .dropped = 0,
            .at_rest = true,
            .spread = .init(cfg.still_window_ms, cfg.sample_rate, cfg.poll_frames),
            .still_range = cfg.still_range,
            .still_release = cfg.still_release,
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
    /// gets instead is the level the probe went still at, whatever that turned
    /// out to be. The model is deliberately told nothing about where a held
    /// probe sits, so the pitch is read off the probe rather than off a band --
    /// and a probe clamping at 1 one day and 660 the next is two different
    /// pitches, which is the rig being honest rather than a fault.
    pub fn deviation(self: *const Detector) i16 {
        return switch (self.model) {
            .deviation => clampedAbsDiff(self.last_mean, self.base()),
            // Nobody on it is no pitch at all. The mean only takes still
            // readings, so without this it would keep reporting the level of
            // the last touch for as long as the rig ran, and the drone would
            // never fall home — the release would be a gate closing over a
            // pitch that never moved.
            // Nobody on it is no pitch at all. Without this the drone would
            // keep reporting the level of the last touch for as long as the rig
            // ran and never fall home -- the release would be a gate closing
            // over a pitch that never moved.
            .steady => if (self.on) @max(self.spread.level, 0) else 0,
        };
    }

    /// One poll of the steady model, which sets `on` and `at_rest`.
    ///
    /// Judged on how tightly the last second of readings cluster, never on the
    /// mean and never on consecutive readings. The mean is an average of the
    /// flailing, a plausible-looking number about nothing, and averaging is
    /// what destroys the stillness that is the signal here. Consecutive
    /// readings are worse: a held probe on this rig drops out every few polls,
    /// and a test that restarts its run on every dropout never accumulates
    /// enough of one -- which is why plant A could not latch at all.
    ///
    /// Returns false while the window has less than its full length behind it,
    /// which is the one case this model cannot answer.
    fn stepSteady(self: *Detector, raw: i16) bool {
        self.spread.push(raw);
        if (!self.spread.ready()) {
            self.reset();
            return false;
        }

        const range = self.spread.range;

        // No score to report in this model; what the log gets instead is the
        // spread in latch-widths, so a number under one is a probe being held.
        self.z = @as(f32, @floatFromInt(range)) /
            @as(f32, @floatFromInt(@max(self.still_range, 1)));

        const held = range <= self.still_range;
        const loose = range >= self.still_release;
        self.at_rest = loose;

        if (self.blocked) {
            if (loose) self.blocked = false;
            self.count = 0;
            self.on = false;
            return false;
        }

        // Between the two thresholds nothing moves. That gap is the whole
        // reason there are two of them.
        if (held) {
            self.count = @min(self.count + 1, self.hold);
            self.dropped -|= 1;
            if (self.count == self.hold) self.on = true;
        } else if (loose) {
            self.count = 0;
            self.dropped = @min(self.dropped + 1, self.drop);
            if (self.dropped == self.drop) self.on = false;
        }
        return true;
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
            .steady => if (!self.stepSteady(raw)) return false,
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

/// The shape probe A actually reads while a hand is on plant A: six polls
/// clamped at 662, then one or two readings from nowhere, over and over. Taken
/// from a fifteen-minute capture of the floating rig.
fn heldPlantA(poll: usize) i16 {
    return switch (poll % 8) {
        6 => 640,
        7 => -4095,
        else => 662,
    };
}

fn deviationConfig() Config {
    return .{
        .sample_rate = 44100,
        .poll_frames = sensor_poll_frames,
        .model = .deviation,
    };
}

fn steadyConfig() Config {
    return .{
        .sample_rate = 44100,
        .poll_frames = sensor_poll_frames,
        .model = .steady,
    };
}

/// A probe left alone on the floating rig: flipping between a rail and a zero,
/// which is what the Pi's journal shows probe A doing for minutes at a time.
fn flailing(poll: usize) i16 {
    return switch (poll % 4) {
        0, 2 => -4096,
        1 => 1,
        else => 2,
    };
}

/// Polls enough to fill the one-second window and satisfy the hold on top.
const steady_warmup: usize = 800;

/// The poll size the engine runs the detector at, which is what makes the hold
/// in these tests the same number of polls as it is in the room.
const sensor_poll_frames: usize = 128;

test "the steady model latches a probe held at any level at all" {
    // Two levels a band would have to be told about in advance, one of which
    // is also the commonest corrupt reading this rig throws. Neither is
    // configured anywhere, and both must latch.
    for ([_]i16{ 663, 1 }) |level| {
        var detector: Detector = .init(steadyConfig());
        for (0..steady_warmup) |_| _ = detector.update(level);
        try std.testing.expect(detector.on);
    }
}

test "the steady model never latches a flailing probe" {
    var detector: Detector = .init(steadyConfig());
    for (0..steady_warmup) |poll| {
        _ = detector.update(flailing(poll));
        try std.testing.expect(!detector.on);
    }
}

test "the steady model latches through the dropouts a held probe throws" {
    // The case the consecutive-jitter test could never pass: six polls clamped,
    // then one or two readings from nowhere, over and over. Judged poll against
    // poll, every dropout restarted the run and the longest run the rig offered
    // was shorter than the hold.
    var detector: Detector = .init(steadyConfig());
    for (0..steady_warmup) |poll| _ = detector.update(heldPlantA(poll));
    try std.testing.expect(detector.on);
}

test "the steady model lets go once the probe is left alone again" {
    var detector: Detector = .init(steadyConfig());
    for (0..steady_warmup) |_| _ = detector.update(663);
    try std.testing.expect(detector.on);

    for (0..steady_warmup) |poll| _ = detector.update(flailing(poll));
    try std.testing.expect(!detector.on);
}

test "the pitch follows the level the probe went still at, not a band" {
    var detector: Detector = .init(steadyConfig());
    for (0..steady_warmup) |_| _ = detector.update(663);
    try std.testing.expectEqual(@as(i16, 663), detector.deviation());

    // A hand off the plant is no pitch at all, however the probe was reading
    // when it left.
    for (0..steady_warmup) |poll| _ = detector.update(flailing(poll));
    try std.testing.expectEqual(@as(i16, 0), detector.deviation());
}

test "the steady model is not subject to the tap window" {
    // The live preset carries `window_bc_ms` for the deviation rig, where an
    // excursion that never comes back is drift or wiring settling rather than
    // somebody asking for a recording. The steady model asks the opposite
    // question: a touch there IS a hand that stays, so a tap window discards
    // every real one and then blocks the probe until it is let go.
    var cfg = steadyConfig();
    cfg.window_ms = 1000.0;
    var detector: Detector = .init(cfg);

    for (0..steady_warmup) |_| _ = detector.update(663);
    try std.testing.expect(detector.on);
}

test "the preset's plant B window does not silence a steady rig" {
    // The same fault as it actually reaches the room: the compiled preset with
    // only the model swapped, which is exactly what `--touch-model=steady` does.
    var cfg = steadyConfig();
    cfg.window_bc_ms = 1000.0;
    cfg.level_bc = 10.0;
    cfg.hold_bc_ms = 20.0;
    var machine: Machine = .init(cfg);

    var latched = false;
    for (0..steady_warmup) |poll| {
        _ = machine.update(flailing(poll), 653);
        if (machine.bc.on) latched = true;
    }
    try std.testing.expect(latched);
    try std.testing.expect(machine.bc.on);
}

test "a windowed probe reports a tap, not a hand that stays" {
    // What `hold` needs from a detector is a level: is there a hand on it now.
    // A windowed probe answers a different question -- did a hand arrive and
    // leave again soon enough to have been a gesture -- and answers it on one
    // poll only. The live preset gives plant B a window, so this is what a held
    // plant B would hand a gate.
    var cfg = deviationConfig();
    cfg.window_ms = 1000.0;
    var detector: Detector = .init(cfg);

    var polls_reported: usize = 0;
    var polls_on: usize = 0;
    for (0..4000) |poll| {
        // Rest for a second, then a hand that arrives and stays.
        const raw: i16 = if (poll < 1000) 0 else 3000;
        if (detector.update(raw)) polls_reported += 1;
        if (detector.on) polls_on += 1;
    }

    // Three thousand polls of hand, and the probe says so on almost none.
    try std.testing.expect(polls_reported < 10);
    try std.testing.expect(polls_on < 500);
}

test "dropping the window lets a deviation probe report a hand for seconds" {
    // The fix for the above, and the limit of it. Without the window a held
    // probe reports the hand for about 950 polls -- near three seconds -- where
    // a windowed one managed fewer than ten. It does not last, and cannot: the
    // deviation model measures how far a probe has moved from its own recent
    // past, and a hand left in place becomes that past within a few seconds.
    var cfg = deviationConfig();
    cfg.window_ms = 1000.0;
    cfg.hold = true;
    var detector: Detector = .init(cfg);

    var polls_reported: usize = 0;
    for (0..4000) |poll| {
        const raw: i16 = if (poll < 1000) 0 else 3000;
        if (detector.update(raw)) polls_reported += 1;
    }

    try std.testing.expect(polls_reported > 500);
    // Never blocked, which is what the window used to do to it.
    try std.testing.expect(!detector.blocked);
}

test "the steady model reports a hand for as long as it is there" {
    // Why `hold` wants `--touch-model=steady`. This asks how tightly the
    // readings cluster, which stays true under a hand however long it stays.
    var detector: Detector = .init(steadyConfig());

    var polls_reported: usize = 0;
    for (0..4000) |poll| {
        const raw: i16 = if (poll < 1000) flailing(poll) else 663;
        if (detector.update(raw)) polls_reported += 1;
    }

    // Nearly every poll the hand was there for, less the window it takes to
    // notice and the hold it takes to be sure.
    try std.testing.expect(polls_reported > 2500);
    try std.testing.expect(detector.on);
}

test "plant B's window survives when only plant A is held" {
    // The two probes are told separately. A held plant A must not quietly
    // retire the tap window plant B was given.
    var cfg = deviationConfig();
    cfg.window_bc_ms = 1000.0;
    cfg.hold = true;
    const machine: Machine = .init(cfg);

    try std.testing.expect(machine.a.window == null);
    try std.testing.expect(machine.bc.window != null);
}
