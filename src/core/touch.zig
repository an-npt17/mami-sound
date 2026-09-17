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

/// One reading offset by another, saturating rather than wrapping.
///
/// A line drawn halfway between rest and a rail runs off the end of the type on
/// a rig whose probe rests at one, and an edge that wrapped to the far rail
/// would call the whole range a touch.
fn saturatingAdd(value: i16, delta: i16) i16 {
    const sum = @as(i32, value) + @as(i32, delta);
    return @intCast(std.math.clamp(sum, std.math.minInt(i16), std.math.maxInt(i16)));
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

/// The longest baseline worth keeping, about seven minutes of pushes.
///
/// Pushes, not seconds: the deviation model only pushes while the probe is at
/// rest, so this is seven minutes of nobody touching the plant however long the
/// wall clock took to supply them.
pub const max_baseline_samples = 4096;

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
    /// What the probe's window sat at, which is what `base` is the median of.
    samples: [max_baseline_samples]i16,
    /// The readings themselves, on the same schedule, which is what the two
    /// levels are the percentiles of.
    ///
    /// Two feeds because the window is asked two questions and one feed cannot
    /// answer both. Where the probe LIVES has to survive a hand that lasts:
    /// window middles give that for free, because a hand on this rig flips the
    /// probe home and back rather than holding it, and a window that is at the
    /// far rail four polls in ten still has its middle at home -- so no amount
    /// of such a hand moves rest. WHICH TWO LEVELS the probe visits cannot be
    /// asked of window middles at all, for the same reason: fed middles the
    /// window holds one level however long the hand stays, `reach` never leaves
    /// nought, and no line is ever drawn.
    raws: [max_baseline_samples]i16,
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
    /// The two levels the window actually holds, on the same schedule.
    ///
    /// A probe in this piece lives at one level and is taken to another by a
    /// hand. Over minutes the window therefore holds two clusters, and these
    /// are their ends: the untouched one is whichever is nearer the median,
    /// because nobody holds a plant for most of an evening, and the other is
    /// where a touch goes. That is how a rig can be read off the probe instead
    /// of measured with a meter and typed in.
    low: i16,
    high: i16,
    /// The median absolute deviation, on the same schedule.
    mad: f32,
    /// How much of the window sits BETWEEN the two levels, on the same
    /// schedule. What says whether there are two levels at all: see `max_dead`.
    dead: f32,
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
            .raws = undefined,
            .scratch = undefined,
            .len = std.math.clamp(@as(u32, @intFromFloat(@max(len, 1.0))), 1, max_baseline_samples),
            .count = 0,
            .head = 0,
            .decim = @intFromFloat(decim),
            .since = 0,
            .base = 0,
            .low = 0,
            .high = 0,
            .mad = 0.0,
            .dead = 0.0,
            .frozen = false,
        };
    }

    /// Feed one poll's mean. Most polls only advance the decimation counter.
    ///
    /// The two models that learn only rest have no second feed to give and pass
    /// the same value twice, which leaves the levels reading off rest -- and
    /// neither of them asks for the levels.
    pub fn push(self: *Baseline, mean_value: i16) void {
        self.pushBoth(mean_value, mean_value);
    }

    /// Feed one poll's window middle and the reading it came from.
    pub fn pushBoth(self: *Baseline, mean_value: i16, raw: i16) void {
        if (self.frozen) return;
        self.since += 1;
        if (self.since < self.decim) return;
        self.since = 0;

        if (self.count < self.len) self.count += 1;
        self.samples[self.head] = mean_value;
        self.raws[self.head] = raw;
        self.head = (self.head + 1) % self.len;

        self.recompute();
    }

    /// Throw the window away and measure again from the next reading.
    ///
    /// What a long hand leaves behind. The rest a probe returns to is not
    /// always the rest it left: fifteen minutes of a hand at twenty-five
    /// thousand warms an electrode and moves where it settles afterwards, and
    /// samples taken before the hand describe a probe that no longer exists.
    /// Dragging a three-thousand-sample median onto the new level takes
    /// minutes; starting over takes the warmup.
    pub fn clear(self: *Baseline) void {
        self.count = 0;
        self.head = 0;
        self.since = 0;
        self.base = 0;
        self.low = 0;
        self.high = 0;
        self.mad = 0.0;
        self.dead = 0.0;
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

        // The two levels the probe actually visits, off its own feed. Taken
        // inside the ends rather than at them, because the extremes of a long
        // window are a dropout and a rail rather than a level the probe ever
        // sits at.
        @memcpy(self.scratch[0..n], self.raws[0..n]);
        std.mem.sort(i16, self.scratch[0..n], {}, std.sort.asc(i16));
        self.low = self.scratch[n * level_percentile / 100];
        self.high = self.scratch[@min(n * (100 - level_percentile) / 100, n - 1)];

        for (self.scratch[0..n], self.samples[0..n]) |*out, sample| {
            out.* = clampedAbsDiff(sample, self.base);
        }
        std.mem.sort(i16, self.scratch[0..n], {}, std.sort.asc(i16));
        self.mad = @floatFromInt(self.scratch[n / 2]);

        // How much of the window falls in the middle third of the gap. Two
        // levels leave it empty; a probe that merely wanders fills it. One pass
        // and no sort, and only the readings are asked -- the middles cannot be
        // asked, since a window whose middle sits between the levels is exactly
        // what a probe flipping between them gives when nobody is on it.
        const reach = @max(
            clampedAbsDiff(self.high, self.base),
            clampedAbsDiff(self.low, self.base),
        );
        const near = @divTrunc(@as(i32, reach) * 33, 100);
        const far = @divTrunc(@as(i32, reach) * 67, 100);
        var between: usize = 0;
        for (self.raws[0..n]) |sample| {
            const distance = clampedAbsDiff(sample, self.base);
            if (distance >= near and distance <= far) between += 1;
        }
        self.dead = @as(f32, @floatFromInt(between)) / @as(f32, @floatFromInt(n));
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

/// How long the median looks back, in seconds of rest.
///
/// Five minutes rather than the one this started with. Gating the pushes on
/// rest is what makes the number affordable: a window of wall clock has to be
/// short enough to follow a probe's drift and long enough that no hand fills
/// half of it, and against ten-minute hands there is no number that is both. A
/// window of rest has no such conflict -- hands are not in it -- so it can be
/// long enough that a stray reading slipping through the gate on a slow release
/// is one sample in three thousand, and still track drift, because drift only
/// happens on the clock the window is now made of.
pub const default_baseline_s: f32 = 300.0;

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
/// Where the two levels a rig shows are taken from, as a percentile of the
/// long window. A twentieth in from each end: far enough past a dropout or a
/// rail to be a level the probe genuinely sits at, near enough the end that a
/// touch occupying a tenth of an evening is still found.
const level_percentile: u32 = 5;

/// How full the gap between the two levels may be before the probe is taken to
/// have no two levels at all.
///
/// A share low enough to answer this rig's own hands is also low enough for a
/// probe that is merely wandering to clear by accident, so `reach` alone cannot
/// be what licenses a line. `reach` only says the ends of the window are far
/// apart, which is as true of a probe drifting over six thousand counts as of
/// one flipping between two rails -- and on the second the line is the whole
/// method, while on the first it lands inside the wander and the probe reads
/// about as touched as untouched forever after. On `service-log4` that is 0.400
/// against 0.399, which is not a strict answer but no answer.
///
/// What tells them apart is the middle of the gap. Measured over the room's
/// logs, the middle third holds 0.031 to 0.067 of the readings on every probe
/// that visits two levels, and 0.577 on the one that only wanders; a probe
/// reading uniformly across its range would give 0.33. The gap between 0.07 and
/// 0.31 is wide enough that anything inside it works, which is the same kind of
/// number, measured the same way, as `still_range`.
const max_dead: f32 = 0.15;

pub const Model = enum { deviation, steady, learned };

/// How wide the window the `steady` model measures a probe's spread over.
///
/// Four hundred polls of this rig's poll rate, and the number that matters most
/// in this model.
///
/// It buys the answer's stability, not its speed. Swept against the capture in
/// `touch.csv`, probe BC gives 39 touches averaging 5.5 seconds over a
/// one-second window, 157 averaging 1.5 over half a second, and 582 averaging
/// 0.46 over a quarter. Nobody touched that plant 582 times in fifteen minutes:
/// a short window does not find more hands, it breaks one hand into many.
///
/// Shorter is still worth having on the command line. A held voice absorbs the
/// fragments -- it waits a second of no hand before letting a clip go -- so a
/// rig that wants to hear a hand sooner can trade the stability it no longer
/// needs.
///
/// A band is answered by counting, so the count wants to be worth something:
/// four hundred readings at three fifths is two hundred and forty of them where
/// a hand puts the probe, and nothing else on this rig sits there that long.
/// At 44100 over 128 frames a poll that is 1161 ms.
pub const default_still_window_ms: f32 = 1161.0;

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
/// A hand holds a probe far tighter than this. In the capture in `touch.csv`
/// the middle window of a held probe spreads three counts, and nine in ten
/// spread under fourteen -- so ten would be the number, and is the number this
/// wants to become.
///
/// Thirty-two is what the rig's dropouts force meanwhile. The fixture
/// `heldPlantA`, taken from fifteen minutes of the floating rig, spreads
/// twenty-two: not because the hand moves, but because the rails it throws at
/// one poll in eight push the twentieth percentile off the clamped level and
/// onto a dropout. At ten that probe never latches at all. At thirty-two it
/// latches with margin, and still rejects the thousands a probe left alone
/// spreads.
///
/// The cost of the difference is small and measured: against the same capture,
/// ten rejects about a tenth of genuinely held windows and thirty-two rejects
/// about a twentieth. Once the conversion reads come back clean, drop this to
/// ten with `--still-range=10`.
pub const default_still_range: i16 = 32;
pub const default_still_release: i16 = 512;

/// How far from its resting level a probe must have gone before its stillness
/// counts as a hand.
///
/// Stillness alone cannot tell a hand from a probe that has stopped moving, and
/// the second is what the rig gives when nothing is connected to the pair: the
/// journal shows probe BC reading nought and one for minutes, spread zero, and
/// the model calling that held for as long as it ran. Nothing is stiller than a
/// dead probe.
///
/// So a hand is stillness somewhere the probe does not normally sit. A hundred
/// counts is far more than a resting probe's own wobble and far less than the
/// six hundred and fifty a hand moves it, which is the gap this has to fall in.
pub const default_still_move: i16 = 100;

/// How long the steady model watches an untouched probe before it will judge
/// one, in seconds.
///
/// Rest is learned once and then kept, rather than tracked. A rolling median is
/// touch-proof only while touches take up less than half its window, and on the
/// capture in `touch.csv` they do not: for the first four hundred and fifty
/// seconds somebody is holding plant B most of the time, the median follows
/// them, and the probe ends up measured against the hand instead of against
/// rest. An installation powers on before the room opens, so the few seconds
/// after boot are the one stretch nobody is touching anything.
///
/// The cost is that a hand on a plant at power-on teaches the wrong rest, and
/// the plant stays quiet until it is restarted. The startup line prints what
/// each probe settled on so that is visible rather than mysterious.
pub const default_still_rest_s: f32 = 5.0;

/// Where a held probe sits, when the room knows and can say so.
///
/// Unset, the model works rest out for itself and calls a hand stillness a
/// hundred counts away from it -- which needs a stretch after power-on with
/// nobody touching anything, and teaches the wrong answer if it does not get
/// one. A band needs neither: it states outright what a touch looks like, so
/// there is nothing to learn and nothing to learn wrongly.
///
/// Worth setting once a rig has been watched. On this one a hand puts a probe
/// at 650 to 660 and nothing else does.
pub const default_touch_band_lo: ?i16 = null;
pub const default_touch_band_hi: ?i16 = null;

/// How much of the window has to be inside the band before it is a hand.
///
/// A band asks a plain question -- how much of the last second was the probe
/// where a hand puts it -- and this is the answer that counts as yes. Three
/// fifths is comfortably more than a rig throwing rails through a good touch
/// costs, and comfortably more than a probe passing through the band on its way
/// somewhere else ever manages.
pub const default_band_share: f32 = 0.6;

/// The share at or below which the touch is over.
///
/// Two numbers rather than one, for the reason the steady model has two: a
/// single line chatters, and a probe sitting on it latches and releases on
/// alternate windows. Between the two the state is whatever it already was.
///
/// The gap has to be wide enough to hold a real hand's wobble and narrow
/// enough that a probe left alone still clears it, and the width is the whole
/// value of the thing. Replayed against `probes-box1.csv` at a share of 0.6,
/// the same five touches on probe BC come out as five episodes whatever the
/// release is -- the gap finds no extra hands -- but their mean length runs
/// 1.13s at a release of 0.5, 5.88s at 0.4, and 5.94s at 0.3. A narrow gap
/// does not miss a touch, it breaks one into pieces, and a held voice plays
/// the pieces as a clip stuttering in and out.
///
/// Four tenths rather than a half for that reason, and not lower: at 0.2 the
/// five become two episodes of about forty-three seconds, which is a hand let
/// go minutes ago that the model is still holding.
pub const default_band_release: f32 = 0.4;

/// How long the readings must stop being still before a touch is called off,
/// in milliseconds. Longer than the attack on purpose: contact drops out for a
/// few polls in the middle of a real touch, and releasing on that would end a
/// clip, or with `--touch-window-bc` start one.
pub const default_drop_ms: f32 = 90.0;

/// A tap window as a room asked for it: a length, or none at all.
///
/// A plain optional cannot carry both answers for probe BC, where `null`
/// already means "whatever plant A was given". A room turning BC's window off
/// is saying something else, and this is the word for it.
pub const Window = union(enum) {
    off,
    ms: f32,
};

/// How long the deviation model holds an unlearned rest before it measures
/// rest again wherever the probe now sits, in seconds.
///
/// The ceiling on everything the gating can get wrong. Rest is learned only
/// while the probe is at rest, which is what lets a ten-minute hand be a hand
/// rather than something the median swallows -- but it means a probe that never
/// comes back never learns, and there are two ways that happens. A wrong latch
/// is one. A hand that leaves the electrode somewhere new is the worse one:
/// the probe reads four hundred where it used to read nought, the old median
/// calls that a touch, and the touch never ends because the reading never
/// moves.
///
/// Neither can be told apart from a hand that is genuinely still there --
/// stillness at a level is stillness at a level, and no amount of looking at
/// the readings separates them. Time is the only thing that does. So the
/// number is a bet: longer than the longest hand the room expects, so a real
/// hand is never cut off, and short enough that a probe which has gone wrong
/// fixes itself while the room is still open.
///
/// Twenty minutes against holds of ten to fifteen. A hand that outlasts it
/// stops sounding and rest is measured under the hand; a probe that drifted is
/// deaf for at most this long after the hand that moved it.
pub const default_baseline_stale_s: f32 = 1200.0;

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
    still_move: i16 = default_still_move,
    still_rest_s: f32 = default_still_rest_s,
    touch_band_lo: ?i16 = default_touch_band_lo,
    touch_band_hi: ?i16 = default_touch_band_hi,
    /// Probe BC's own band. `null` puts it on A's.
    ///
    /// The two probes do not sit at the same place: on this rig a hand puts one
    /// near six hundred and sixty and the other near twenty-five thousand, so
    /// one band for both cannot serve either.
    touch_band_lo_bc: ?i16 = null,
    touch_band_hi_bc: ?i16 = null,
    band_share: f32 = default_band_share,
    band_release: f32 = default_band_release,
    /// Probe BC's own thresholds. `null` puts it on A's.
    ///
    /// The two probes are not equally clean and do not have to be judged
    /// equally hard: a wrong latch on A moves a drone that was already
    /// sounding, where a wrong latch on BC starts a recording.
    still_range_bc: ?i16 = null,
    still_release_bc: ?i16 = null,
    still_move_bc: ?i16 = null,
    level: f32 = default_level,
    hold_ms: f32 = default_hold_ms,
    average_ms: f32 = default_average_ms,
    baseline_s: f32 = default_baseline_s,
    /// How long the deviation model may go without learning rest before it
    /// learns regardless. `deviation` only.
    baseline_stale_s: f32 = default_baseline_stale_s,
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
    /// Probe BC's own answer to the same question. `null` gives it A's, and
    /// `.off` is the room saying this plant takes no window at all -- which
    /// `null` cannot say, because there it already means "whatever A has".
    window_bc: ?Window = null,

    /// This config as probe BC sees it: its own threshold and hold where it was
    /// given them, A's everywhere else.
    pub fn forBc(self: Config) Config {
        var bc = self;
        bc.level = self.level_bc orelse self.level;
        bc.hold_ms = self.hold_bc_ms orelse self.hold_ms;
        bc.still_range = self.still_range_bc orelse self.still_range;
        bc.still_release = self.still_release_bc orelse self.still_release;
        bc.still_move = self.still_move_bc orelse self.still_move;
        if (self.touch_band_lo_bc) |lo| bc.touch_band_lo = lo;
        if (self.touch_band_hi_bc) |hi| bc.touch_band_hi = hi;
        bc.touch_band_lo_bc = null;
        bc.touch_band_hi_bc = null;
        bc.still_range_bc = null;
        bc.still_release_bc = null;
        bc.still_move_bc = null;
        bc.counts = self.counts_bc orelse self.counts;
        bc.window_ms = if (self.window_bc) |chosen| switch (chosen) {
            .off => null,
            .ms => |ms| ms,
        } else self.window_ms;
        bc.hold = self.hold_bc;
        bc.hold_bc = false;
        bc.level_bc = null;
        bc.hold_bc_ms = null;
        bc.counts_bc = null;
        bc.window_bc = null;
        return bc;
    }
};

/// One probe, judged against itself.
pub const Detector = struct {
    mean: Mean,
    /// The same readings over a much shorter window, which is what the counts
    /// floor is asked of.
    ///
    /// The two thresholds ask different questions and were sharing one average.
    /// The score wants `mean`'s two hundred milliseconds: `z` divides by a MAD,
    /// and a jumpy numerator over a small denominator is noise about noise. The
    /// floor asks how far the probe actually moved, which is a level, and a long
    /// average cannot answer it promptly -- it ramps. A rail-to-rail touch of
    /// twenty-five thousand counts against a floor of ten thousand was not
    /// believed until the mean had travelled forty per cent of its window,
    /// which is eighty-one milliseconds before the hold had started counting at
    /// all. Measured at 98.68 ms on the rig; the room hears that as the plant
    /// being slow to answer a hand that arrived all at once.
    ///
    /// Averaged over the hold rather than over a window of its own, because the
    /// hold already says how long a reading must persist to be believed and a
    /// second number here would be one nobody measured. At twenty milliseconds
    /// that is seven polls -- enough that probe B's one-poll-in-fifteen
    /// dropouts cannot clear the floor between them, which is the whole reason
    /// the floor is there.
    step: Mean,
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
    /// The last short mean, which is what the counts floor is measured from.
    /// Kept beside `last_mean` rather than replacing it: the pitch the drone
    /// plays is read off the long one, and moving it to this would make a
    /// held note jump about with every dropout.
    last_step: i16,
    /// Set while the other probe has this one pulled off its rest. The score is
    /// then measured from where the pull left it, so only a further move counts.
    base_override: ?i16,
    /// Polls the baseline has been held back for, and how many it may go before
    /// the probe is taken to be stuck rather than held and rest is measured
    /// where it now sits. `deviation` only.
    held: u32,
    stale_polls: u32,
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
    still_move: i16,
    /// How many baseline samples the calibration wants before rest is settled.
    rest_samples: u32,
    /// Where a held probe sits, when the room said so.
    ///
    /// Both models read it, for different reasons. The steady model uses it
    /// instead of learning rest. The deviation model uses it to tell a hand
    /// from a rail: it asks how far a probe has moved and not where it went, so
    /// a slam to the end of the range scores as high as a hand does.
    band_lo: ?i16,
    band_hi: ?i16,
    band_share: f32,
    /// The share at or below which the touch is over. `learned` only.
    band_release: f32,

    pub fn init(cfg: Config) Detector {
        return .{
            .mean = .init(holdPolls(cfg.average_ms, cfg.sample_rate, cfg.poll_frames)),
            .step = .init(@max(holdPolls(cfg.hold_ms, cfg.sample_rate, cfg.poll_frames), 1)),
            .baseline = .init(cfg.baseline_s, cfg.sample_rate, cfg.poll_frames),
            .level = cfg.level,
            .hold = @max(holdPolls(cfg.hold_ms, cfg.sample_rate, cfg.poll_frames), 1),
            .count = 0,
            .on = false,
            .z = 0.0,
            .last_mean = 0,
            .last_step = 0,
            .base_override = null,
            .held = 0,
            .stale_polls = @max(
                holdPolls(cfg.baseline_stale_s * 1000.0, cfg.sample_rate, cfg.poll_frames),
                1,
            ),
            .counts = cfg.counts,
            // A deviation-model idea, and only ever applied there. That model
            // reads an excursion that never comes back as drift, a probe
            // settling after power-on, or a hand left resting -- none of which
            // is somebody asking for a recording. The steady model asks the
            // opposite question: a touch there is a hand that stays, so a tap
            // window would discard every real one and then block the probe
            // until it was let go. The preset still carries `window_bc` for
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
            .spread = blk: {
                var window: spread_mod.Spread =
                    .init(cfg.still_window_ms, cfg.sample_rate, cfg.poll_frames);
                window.watch(cfg.touch_band_lo, cfg.touch_band_hi);
                break :blk window;
            },
            .still_range = cfg.still_range,
            .still_release = cfg.still_release,
            .still_move = cfg.still_move,
            .band_lo = cfg.touch_band_lo,
            .band_hi = cfg.touch_band_hi,
            .band_share = cfg.band_share,
            .band_release = cfg.band_release,
            .rest_samples = @max(
                @as(u32, @intFromFloat(cfg.still_rest_s * baseline_hz)),
                1,
            ),
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

    /// What the model is actually looking at, as opposed to the raw reading.
    ///
    /// The steady model compares the middle of its window against rest, and a
    /// single reading is neither of those -- so a status line showing only the
    /// raw value cannot answer the one question a room asks, which is why
    /// nothing happened when somebody touched the plant. With this and `rest`
    /// side by side the answer is a subtraction.
    pub fn compared(self: *const Detector) i16 {
        return switch (self.model) {
            .deviation => self.last_mean,
            // Both window models are looking at the middle of the window, so
            // the status line shows the same thing for either.
            .steady, .learned => self.spread.level,
        };
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
            // How far the hand has taken the probe from where it lives. This
            // model knows both, so the pitch can be the distance rather than
            // the level -- a rig that rests at a rail and one that rests at
            // nought then answer a hand the same way round, which the raw
            // level could not do.
            .learned => if (self.on)
                clampedAbsDiff(self.spread.level, self.baseline.base)
            else
                0,
        };
    }

    /// Whether a reading is where a held probe sits. True everywhere when the
    /// room has not said, which is what leaves both models as they were.
    fn inBand(self: *const Detector, value: i16) bool {
        if (self.band_lo) |lo| if (value < lo) return false;
        if (self.band_hi) |hi| if (value > hi) return false;
        return true;
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

        // Where this probe sits when nobody is on it. A median over a minute,
        // decimated, so a touch shorter than half of it cannot move the answer
        // -- which is what lets rest be learned while the piece is running
        // rather than measured once and typed in.
        //
        // A band is the room telling the model what a touch looks like, which
        // leaves it nothing to learn. Without one, rest is learned once and
        // then kept -- tracking it does not work, because a median is
        // touch-proof only while touches take up less than half its window, and
        // a plant somebody keeps hold of ends up measured against the hand.
        const banded = self.band_lo != null or self.band_hi != null;
        if (!banded) {
            self.baseline.frozen = self.baseline.count >= self.rest_samples;
            self.baseline.push(self.spread.level);
            if (self.baseline.count < self.rest_samples) {
                self.reset();
                return false;
            }
        }

        const level = self.spread.level;

        // Told where a hand puts the probe, the question is how much of the
        // last second was there. One count, which a rail thrown through a
        // perfectly good touch cannot move much -- where a median and a spread
        // survive that only up to the margin the percentiles leave.
        //
        // Told nothing, the probe has to be still and somewhere other than
        // where it rests, because neither of those says anything on its own: a
        // probe with nothing connected to it is stiller than any hand could
        // hold one, and a probe wandering past the right level is not a hand.
        const away = if (banded)
            self.spread.inside >= self.band_share
        else
            clampedAbsDiff(level, self.baseline.base) >= self.still_move;

        const held = if (banded) away else range <= self.still_range and away;
        // And let go once it is wandering again, or once it is no longer where
        // a held probe sits.
        //
        // The spread alone is not enough, though it looks it: a hand coming off
        // usually drags the window through both levels and that is a spread of
        // hundreds. But a rig whose untouched reading is a flat nought has no
        // spread to speak of at either end, and a release set wide enough not
        // to trip on ordinary noise then never trips at all -- the probe leaves
        // the band, stops being held, and stays latched because nothing tells
        // it not to. The drop counter is the hysteresis here; a reading sitting
        // on the edge of the band has ninety milliseconds to make its mind up.
        const loose = range >= self.still_release or !away;
        self.at_rest = loose;

        return self.settle(held, loose);
    }

    /// Move the latch on one poll's answer, and say whether the poll counted.
    ///
    /// Shared by every model that judges a window rather than a score: the
    /// hysteresis is the same question wherever the two booleans came from, and
    /// two copies of it would be two places for a release to rot.
    fn settle(self: *Detector, held: bool, loose: bool) bool {
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

    /// The model that is told nothing at all.
    ///
    /// `steady` asks how tightly the window clusters and needs a band before it
    /// can say where; `deviation` asks how far the probe moved from its own
    /// past and needs a rest it can only learn while it is already right. Both
    /// want a number from the room first. This one reads the rig off the probe:
    /// a plant in this piece lives at one level and is taken to another by a
    /// hand, so over minutes the long window holds two clusters, and which of
    /// them is rest is decided by which the probe keeps coming back to.
    ///
    /// The four shapes a rig takes are then one question. Rest at nought and a
    /// hand at twenty-five thousand, rest at twenty-five thousand and a hand
    /// pulling to ground, rest in the middle thrown either way: the far
    /// cluster is wherever it is, and the line between them is halfway.
    fn stepLearned(self: *Detector, raw: i16) bool {
        self.spread.push(raw);
        if (!self.spread.ready()) {
            self.reset();
            return false;
        }

        const level = self.spread.level;

        // Both feeds, because the window is asked two questions. The middle
        // says where the probe LIVES and survives a hand that lasts: a hand on
        // this rig flips the probe home and back rather than holding it, so a
        // window at the far rail four polls in ten still has its middle at
        // home, and no amount of such a hand moves rest. The reading says WHICH
        // TWO LEVELS the probe visits, which the middle cannot answer for
        // exactly the same reason -- fed middles alone this window holds one
        // level however long the hand stays, `reach` never leaves nought, no
        // line is ever drawn, and the model meant to read the rig off the probe
        // reads nothing off it at all. What answered the room then was the
        // stand-in meant for the first hand of the evening, which asks whether
        // the middle has left home: a fixed half-the-window vote nobody chose
        // and no room could move.
        //
        // The worry that kept the reading out -- a rail thrown through a good
        // touch becoming a sample of where the probe lives -- is a worry about
        // a mean. Nothing here is one: `base` is a median and the two levels
        // are percentiles, and a stray reading moves none of the three.
        //
        // Never frozen, unlike the other two models. They freeze because they
        // learn only rest, and a window that kept taking samples through a
        // hand would learn the hand. This one has to see BOTH levels -- a
        // frozen window holds one cluster and can never find the other, and
        // the line between them is the whole method.
        self.baseline.pushBoth(level, raw);
        if (self.baseline.count < self.rest_samples) {
            self.reset();
            return false;
        }

        // Which ends a hand takes this probe to, and the lines between there
        // and home. Both ends, because a hand on this rig goes to the top some
        // touches and the bottom others and nothing says which in advance --
        // and each line is drawn from its own end's reach rather than from the
        // larger of the two, or the nearer end's line would sit past the end
        // itself and a real touch there could never cross it. On the room's own
        // journal the larger half is 8089 counts while the whole downward
        // excursion is 5151, so one shared line is a plant that cannot be
        // touched downwards at all.
        const rest = self.baseline.base;
        const up = clampedAbsDiff(self.baseline.high, rest);
        const down = clampedAbsDiff(self.baseline.low, rest);

        const hi_line: ?i16 = if (up >= self.still_move)
            saturatingAdd(rest, @divTrunc(up, 2))
        else
            null;
        const lo_line: ?i16 = if (down >= self.still_move)
            saturatingAdd(rest, -@divTrunc(down, 2))
        else
            null;

        // Whether the probe has been anywhere but home. Short of this nothing
        // has ever taken it anywhere, so there is no second level and no line.
        const second_level = hi_line != null or lo_line != null;
        // Whether the two ends are two levels rather than the ends of one
        // wander, which is what says a line may be drawn between them at all.
        const readable = self.baseline.dead <= max_dead;

        self.spread.watchEdges(lo_line, hi_line);

        const away = if (second_level and readable)
            // A touch has been seen, so the rig is known and the question is a
            // count: how much of the last window was past a line. Counted
            // rather than measured, because a hand that drops out one poll in
            // fifteen has a median dragged home and a range the height of the
            // dropout, and neither reads as the hand that is there.
            //
            // The maximum of the two and never their sum. A probe wandering
            // across its range is past each line about a quarter of the time,
            // and summing those says only that it left the middle -- which is
            // the one thing a wander and a hand have in common. On box1's
            // capture the sum puts a wanderer at about a half against a share
            // of 0.6, which is no margin at all.
            @max(self.spread.above, self.spread.below) >= self.band_share
        else if (second_level)
            // The ends are a long way apart and the gap between them is full,
            // so this is one wander rather than two levels. Which means the
            // probe cannot be read just now -- and a probe that cannot be read
            // is quiet, not held.
            //
            // The stand-in below is emphatically not the answer here. It asks
            // whether the window sits far from rest, and a probe whose home has
            // moved sits far from rest by definition and for as long as the
            // long window takes to catch up: a hand that arrives without anyone
            // and never lets go. On the room's own capture, a probe that drifted
            // from nought to twelve thousand was held for ninety-six seconds at
            // an empty plant, looping a clip the whole way.
            false
        else
            // Nobody has touched it yet, so there is no second cluster to find
            // and no line to draw. Until there is, a touch is the plain thing:
            // the window sitting somewhere the probe does not live. The first
            // hand of the evening is answered on this, and teaches the rest.
            clampedAbsDiff(level, rest) >= self.still_move;

        // The count is the whole test, and stillness is not asked at all.
        //
        // The other two models ask it because they have to: told nothing about
        // where a hand puts the probe, stillness is the only thing separating a
        // hand from a probe wandering past the right level. Here the band is
        // known, so the share answers that on its own -- a probe flipping
        // between the two rails spends about half the window past the line and
        // cannot reach three fifths, while a hand holding it there spends
        // nearly all of it.
        //
        // And stillness is the one thing this rig will not give. A held probe
        // here reads its level, throws the far rail, and comes back, over and
        // over: on the room's own journal plant A ran 25886, 735, 10, 12, 25886
        // through a single touch. Between percentiles that is a range of the
        // full scale, so a stillness gate is not merely strict on this rig --
        // it can never open, and the plant is deaf for the evening.

        // Two lines where the share is what is being asked, and one everywhere
        // else. Between them nothing moves, which is the whole reason there
        // are two: on this rig a hand's share lands on the threshold rather
        // than far past it -- 0.628 held against a line at 0.600 -- and a
        // single line turns that into a latch and a release on alternate
        // windows, which a held voice plays as the clip wobbling in and out.
        //
        // The other two branches keep one line each. Neither is a share, and
        // neither has been seen to sit on its own threshold.
        const held = away;
        const loose = if (second_level and readable)
            @max(self.spread.above, self.spread.below) <= self.band_release
        else
            !away;
        self.at_rest = loose;

        return self.settle(held, loose);
    }

    /// Feed the median what rest looks like, and nothing else.
    ///
    /// A rolling median stays honest without any touch detection only while
    /// touches take up less than half its window. Ten-minute hands do not, so
    /// the median is told what to swallow: readings from a probe that is
    /// unlatched, unblocked and back inside the release band. The window then
    /// measures five minutes of rest rather than five minutes of wall clock,
    /// and a hand of any length contributes nothing at all.
    ///
    /// A probe letting go resumes the window it had, and never starts a new
    /// one. Throwing the window away means a warmup, and a warmup learns
    /// whatever it is given: a hand coming back inside those three seconds is
    /// learned as rest, and from then on the plant sounds when nobody is on it
    /// and goes quiet under a hand. Hand after hand, that is what the room sees
    /// as the effect reversing. There is nothing to gain against it either --
    /// a probe that got back inside the release band has just shown the old
    /// window to be right about where rest is.
    ///
    /// Circular only in appearance. The state doing the gating was decided by a
    /// median with a warmup behind it, and the one way the gate could wedge shut
    /// -- a probe that never comes back, drifted or wrongly latched -- is what
    /// `stale_polls` is for. Past it the hand is not a hand: the window is
    /// thrown away and rest is measured where the probe now sits, latch and all
    /// forgotten. That resample can be given a hand to learn, which is why it
    /// waits out a length no real hand lasts.
    fn learnRest(self: *Detector, back: bool) void {
        if (!self.on and !self.blocked and back) {
            self.held = 0;
            self.baseline.push(self.last_mean);
            return;
        }

        self.held +|= 1;
        if (self.held >= self.stale_polls) {
            self.baseline.clear();
            self.held = 0;
            self.reset();
        }
    }

    /// One poll of the deviation model, which sets `on` and `at_rest`.
    ///
    /// Returns false when the baseline has nothing behind it yet, which is the
    /// one case where this model cannot answer at all.
    fn stepDeviation(self: *Detector, raw: i16) bool {
        self.last_mean = self.mean.push(raw);
        self.last_step = self.step.push(raw);

        const denom = @max(self.baseline.mad, mad_floor);
        self.z = (@as(f32, @floatFromInt(self.last_mean)) -
            @as(f32, @floatFromInt(self.base()))) / denom;

        // Before the median has anything behind it the score is noise about
        // noise, and acting on it would start a clip at power-on. Nothing is
        // known well enough to be choosy about what gets learned yet, so the
        // warmup takes every reading -- which is why the few seconds after
        // power-on want nobody's hand on a plant.
        if (!self.baseline.ready()) {
            self.baseline.push(self.last_mean);
            self.reset();
            return false;
        }

        // How far the probe moved, off the short mean. The score below keeps
        // the long one: the two thresholds are asking different questions and
        // an average that suits the score's stability makes the floor late.
        const moved = clampedAbsDiff(self.last_step, self.base());
        // Where the probe went, as well as how far it moved. Without this a
        // rail scores as high as a hand, and on this rig the rails are the
        // commonest thing a probe does that nobody asked for.
        const in_band = self.inBand(self.last_mean);
        const over = @abs(self.z) >= self.level and
            (self.counts == null or moved >= self.counts.?) and
            in_band;

        // Back at rest is half of whatever it took to leave it, in both units.
        // Requiring the same number both ways would let a reading sitting on
        // the line arm and disarm on alternate polls.
        const back = @abs(self.z) < self.level / 2.0 and
            (self.counts == null or moved < @divTrunc(self.counts.?, 2));
        self.at_rest = back;
        self.learnRest(back);

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
        // A probe that has left the band has stopped being a touch whatever its
        // score says, so the latch decays even where a second threshold would
        // otherwise hold it: a hand going straight to a rail never passes back
        // through rest, and waiting for it to would never let go.
        if (over) {
            self.count = @min(self.count + 1, self.hold);
        } else if (!banded or back or !in_band) {
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
            .learned => if (!self.stepLearned(raw)) return false,
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

/// Feed a detector a spell of nobody being there, so it learns where the probe
/// rests before a hand is put on it. Every steady fixture needs this now: a
/// probe that has only ever read one value rests at that value, and stillness
/// there is not a hand.
fn settle(detector: *Detector) void {
    for (0..rest_warmup) |poll| _ = detector.update(flailing(poll));
}

/// The poll size the engine runs the detector at, which is what makes the hold
/// in these tests the same number of polls as it is in the room.
const sensor_poll_frames: usize = 128;

test "the steady model latches a probe held at any level at all" {
    // Two levels a band would have to be told about in advance, one of which
    // is also the commonest corrupt reading this rig throws. Neither is
    // configured anywhere, and both must latch.
    for ([_]i16{ 663, -2400 }) |level| {
        var detector: Detector = .init(steadyConfig());
        settle(&detector);
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
    settle(&detector);
    for (0..steady_warmup) |poll| _ = detector.update(heldPlantA(poll));
    try std.testing.expect(detector.on);
}

test "the steady model lets go once the probe is left alone again" {
    var detector: Detector = .init(steadyConfig());
    settle(&detector);
    for (0..steady_warmup) |_| _ = detector.update(663);
    try std.testing.expect(detector.on);

    for (0..steady_warmup) |poll| _ = detector.update(flailing(poll));
    try std.testing.expect(!detector.on);
}

test "the pitch follows the level the probe went still at, not a band" {
    var detector: Detector = .init(steadyConfig());
    settle(&detector);
    for (0..steady_warmup) |_| _ = detector.update(663);
    try std.testing.expectEqual(@as(i16, 663), detector.deviation());

    // A hand off the plant is no pitch at all, however the probe was reading
    // when it left.
    for (0..steady_warmup) |poll| _ = detector.update(flailing(poll));
    try std.testing.expectEqual(@as(i16, 0), detector.deviation());
}

test "the steady model is not subject to the tap window" {
    // The live preset carries `window_bc` for the deviation rig, where an
    // excursion that never comes back is drift or wiring settling rather than
    // somebody asking for a recording. The steady model asks the opposite
    // question: a touch there IS a hand that stays, so a tap window discards
    // every real one and then blocks the probe until it is let go.
    var cfg = steadyConfig();
    cfg.window_ms = 1000.0;
    var detector: Detector = .init(cfg);

    settle(&detector);
    for (0..steady_warmup) |_| _ = detector.update(663);
    try std.testing.expect(detector.on);
}

test "the preset's plant B window does not silence a steady rig" {
    // The same fault as it actually reaches the room: the compiled preset with
    // only the model swapped, which is exactly what `--touch-model=steady` does.
    var cfg = steadyConfig();
    cfg.window_bc = .{ .ms = 1000.0 };
    cfg.level_bc = 10.0;
    cfg.hold_bc_ms = 20.0;
    var machine: Machine = .init(cfg);

    var latched = false;
    for (0..rest_warmup) |poll| _ = machine.update(flailing(poll), flailing(poll));
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

test "dropping the window lets a deviation probe report a hand at all" {
    // Without the window a held probe reports the hand; with one it managed
    // fewer than ten polls in three thousand. How long it keeps reporting is a
    // question about the baseline, not the window, and
    // `a warm baseline does not absorb a hand the way a cold one does` answers
    // it: with a minute of rest behind the median, 98% of a thirty-second hold.
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
    settle(&detector);

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

test "a plant B told to take no window keeps none while plant A has one" {
    // On BC `null` already means "whatever A was given", so a room turning
    // that plant's window off needs a word of its own or it inherits A's.
    var cfg = deviationConfig();
    cfg.window_ms = 1000.0;
    cfg.window_bc = .off;
    const machine: Machine = .init(cfg);

    try std.testing.expect(machine.a.window != null);
    try std.testing.expect(machine.bc.window == null);
}

test "plant B's window survives when only plant A is held" {
    // The two probes are told separately. A held plant A must not quietly
    // retire the tap window plant B was given.
    var cfg = deviationConfig();
    cfg.window_bc = .{ .ms = 1000.0 };
    cfg.hold = true;
    const machine: Machine = .init(cfg);

    try std.testing.expect(machine.a.window == null);
    try std.testing.expect(machine.bc.window != null);
}

test "a warm baseline does not absorb a hand the way a cold one does" {
    // The earlier measurement started from nothing, so a held value was half
    // the median's window within seconds and the probe read itself back to
    // rest. In the room the median has a minute of rest behind it before
    // anybody arrives. This is what that difference is worth.
    var cfg = deviationConfig();
    cfg.hold = true;
    var detector: Detector = .init(cfg);

    // A full minute of the probe at rest, wobbling as a real one does.
    for (0..70 * 345) |poll| {
        _ = detector.update(if (poll % 3 == 0) 4 else -4);
    }

    var polls_reported: usize = 0;
    const held_polls = 30 * 345;
    for (0..held_polls) |poll| {
        if (detector.update(if (poll % 3 == 0) 3004 else 2996)) polls_reported += 1;
    }

    try std.testing.expect(polls_reported > held_polls / 2);
}

test "the steady model judges the range and not the value" {
    // The whole of what this model is: a probe held anywhere at all reads as
    // held, and four probes clamped thousands of counts apart with the same
    // wobble settle on the same answer. Nothing here consults where a drone
    // would map that level to, or anything else about the voice.
    //
    // Asked of the settled answer rather than of every poll. A level that sorts
    // inside the resting readings displaces them in a different order from one
    // that sorts above, so the changeover itself takes a different number of
    // polls -- which is arithmetic about the window, not the model caring where
    // the probe sits.
    const levels = [_]i16{ 663, -900, -2000, 12000 };
    var detectors: [levels.len]Detector = undefined;
    for (&detectors) |*detector| {
        detector.* = .init(steadyConfig());
        settle(detector);
    }

    for (0..steady_warmup) |poll| {
        const wobble: i16 = @intCast(@as(i32, @intCast(poll % 5)) - 2);
        for (&detectors, levels) |*detector, level| _ = detector.update(level +| wobble);
    }
    for (&detectors) |*detector| try std.testing.expect(detector.on);

    // And from here they agree poll for poll, whatever they are sitting at.
    for (0..steady_warmup) |poll| {
        const wobble: i16 = @intCast(@as(i32, @intCast(poll % 5)) - 2);
        var first: ?bool = null;
        for (&detectors, levels) |*detector, level| {
            const on = detector.update(level +| wobble);
            if (first) |expected| {
                try std.testing.expectEqual(expected, on);
            } else {
                first = on;
            }
        }
    }
}

test "a probe wandering further than the range is not held, wherever it sits" {
    // The other half. A slow drift is not a hand, and neither is a probe
    // parked at a plausible-looking level while still moving about.
    var detector: Detector = .init(steadyConfig());
    settle(&detector);
    for (0..steady_warmup) |poll| {
        const drift: i16 = @intCast(@as(i32, @intCast(poll % 400)) - 200);
        _ = detector.update(663 +| drift);
    }
    try std.testing.expect(!detector.on);
}

/// The rig's probe BC as the journal shows it: nought and one, for minutes.
fn flatlined(poll: usize) i16 {
    return if (poll % 3 == 0) 0 else 1;
}

/// Long enough for the spread's window and the baseline's median both.
const rest_warmup: usize = 4 * steady_warmup;

test "a probe that is not moving at all is not a hand" {
    // Straight off the rig: probe BC reading nought and one for minutes with a
    // spread of zero, and the model calling it held for as long as it ran --
    // because stillness is what it looked for, and nothing is stiller than a
    // probe that has stopped moving. A hand is the opposite of that.
    var detector: Detector = .init(steadyConfig());
    for (0..rest_warmup) |poll| _ = detector.update(flatlined(poll));
    try std.testing.expect(!detector.on);
}

test "stillness at a level the probe does not rest at is a hand" {
    var detector: Detector = .init(steadyConfig());
    for (0..rest_warmup) |poll| _ = detector.update(flatlined(poll));
    try std.testing.expect(!detector.on);

    // A hand takes it to 657 and holds it there.
    for (0..steady_warmup) |_| _ = detector.update(657);
    try std.testing.expect(detector.on);
}

test "a hand coming off lets go even though rest is still as still" {
    // The release has to watch the level too. A probe back at a rest it never
    // moves from has a spread of zero, so a release that only watched the
    // spread would latch on and stay there.
    var detector: Detector = .init(steadyConfig());
    for (0..rest_warmup) |poll| _ = detector.update(flatlined(poll));
    for (0..steady_warmup) |_| _ = detector.update(657);
    try std.testing.expect(detector.on);

    for (0..steady_warmup) |poll| _ = detector.update(flatlined(poll));
    try std.testing.expect(!detector.on);
}

test "a hand held for a minute is still a hand" {
    // The baseline is a median over a minute, and a touch occupying more than
    // half of it moves the median -- at which point the probe reads as resting
    // where the hand is holding it, and the plant lets go with somebody still
    // there. That is fine for a model watching for movement and fatal for one
    // watching for stillness, because `hold` means somebody may stay for the
    // length of an interview.
    var detector: Detector = .init(steadyConfig());
    settle(&detector);

    // Ninety seconds, well past the minute the median looks back over.
    const polls_per_s = 44100 / sensor_poll_frames;
    for (0..90 * polls_per_s) |_| _ = detector.update(657);

    try std.testing.expect(detector.on);
}

test "rest is learned once and not moved by a plant nobody leaves alone" {
    // What a rolling median could not do. On the capture in `touch.csv` plant B
    // is held for most of the first four hundred and fifty seconds, the median
    // follows the hand, and the probe ends up measured against the hand instead
    // of against rest. Learned once at power-on, it cannot.
    var detector: Detector = .init(steadyConfig());
    settle(&detector);

    // Then somebody who barely lets go: forty seconds on, five off, over and
    // over, which is more than half of every window a median could look back
    // over.
    const polls_per_s = 44100 / sensor_poll_frames;
    var latched: usize = 0;
    for (0..6) |_| {
        for (0..5 * polls_per_s) |poll| _ = detector.update(flailing(poll));
        for (0..40 * polls_per_s) |_| {
            _ = detector.update(657);
            if (detector.on) latched += 1;
        }
    }

    // Still finding the hand at the end of it, which needs rest to have stayed
    // where the empty room put it.
    try std.testing.expect(detector.on);
    try std.testing.expect(latched > 200 * polls_per_s);
}

test "a probe held at power-on teaches the wrong rest, and says so" {
    // The cost of learning once. Nothing can be done about it in software --
    // the probe has never been seen untouched -- so the thing that matters is
    // that it fails quietly silent rather than quietly wrong, and that the
    // level it settled on is available to be printed.
    var detector: Detector = .init(steadyConfig());
    for (0..rest_warmup) |_| _ = detector.update(657);
    for (0..steady_warmup) |_| _ = detector.update(657);

    try std.testing.expect(!detector.on);
    try std.testing.expectEqual(@as(i16, 657), detector.baseline.base);
}

test "nothing is judged until rest has been learned" {
    // The guard on a half-formed median. Whatever the probe does in the seconds
    // after power-on, the model has not yet seen enough of it to say where rest
    // is, and a plant that latched on the way to finding out would answer the
    // first person through the door for no reason.
    var cfg = steadyConfig();
    cfg.still_rest_s = 5.0;
    var detector: Detector = .init(cfg);

    const polls_per_s = 44100 / sensor_poll_frames;
    for (0..5 * polls_per_s) |poll| {
        // Perfectly still, a long way from anywhere, from the first poll.
        _ = detector.update(if (poll < polls_per_s) flailing(poll) else 9000);
        try std.testing.expect(!detector.on);
    }
}

test "a band says what a touch looks like, so no rest need be learned" {
    // What the room can see and the calibration cannot always get: on this rig
    // a hand puts the probe at 650 to 660 and nothing else does. Told that, the
    // model needs no untouched stretch at power-on to compare against, which is
    // the one failure it could not detect or recover from.
    var cfg = steadyConfig();
    cfg.touch_band_lo = 650;
    cfg.touch_band_hi = 660;
    var detector: Detector = .init(cfg);

    // Held from the very first poll, with no rest ever observed.
    for (0..steady_warmup) |_| _ = detector.update(655);
    try std.testing.expect(detector.on);
}

test "stillness outside the band is not a touch, however still" {
    var cfg = steadyConfig();
    cfg.touch_band_lo = 650;
    cfg.touch_band_hi = 660;
    var detector: Detector = .init(cfg);

    // The dead probe from the journal: nought and one, for as long as you like.
    for (0..steady_warmup * 2) |poll| _ = detector.update(flatlined(poll));
    try std.testing.expect(!detector.on);

    // And a probe parked still at a level that is simply not a hand.
    var other: Detector = .init(cfg);
    for (0..steady_warmup * 2) |_| _ = other.update(2400);
    try std.testing.expect(!other.on);
}

test "a banded probe lets go when the hand does" {
    var cfg = steadyConfig();
    cfg.touch_band_lo = 650;
    cfg.touch_band_hi = 660;
    var detector: Detector = .init(cfg);

    for (0..steady_warmup) |_| _ = detector.update(655);
    try std.testing.expect(detector.on);

    for (0..steady_warmup) |poll| _ = detector.update(flailing(poll));
    try std.testing.expect(!detector.on);
}

test "without a band the learned rest still decides" {
    // The band is an option, not a replacement: a rig whose touched level moves
    // about keeps the model that works that out for itself.
    var detector: Detector = .init(steadyConfig());
    settle(&detector);
    for (0..steady_warmup) |_| _ = detector.update(655);
    try std.testing.expect(detector.on);
}

test "a banded probe lets go even when rest is as still as the touch" {
    // The configuration a room actually types: a band around where a hand puts
    // the probe, a release wide enough not to trip on ordinary noise, and a rig
    // whose untouched reading is a flat nought.
    //
    // Release watched only the spread, and a flat rest has no spread. So the
    // probe left the band, stopped being held, and never came off -- because
    // nothing ever told it to.
    var cfg = steadyConfig();
    cfg.touch_band_lo = 630;
    cfg.touch_band_hi = 690;
    cfg.still_range = 400;
    cfg.still_release = 4000;
    var detector: Detector = .init(cfg);

    for (0..steady_warmup) |_| _ = detector.update(660);
    try std.testing.expect(detector.on);

    // The hand comes off and the probe goes flat at nought, as this rig does.
    for (0..steady_warmup) |poll| _ = detector.update(flatlined(poll));
    try std.testing.expect(!detector.on);
}

/// A probe that has been sitting at nought and slams to a rail: the shape of a
/// corrupt read or a wire moving, not of a hand.
fn railed(poll: usize) i16 {
    return if (poll % 2 == 0) -20000 else -19998;
}

test "a band keeps the deviation model from firing on a rail" {
    // The deviation model asks how far a probe has moved and not where it went,
    // so a slam to a rail scores as high as a hand does. Told where a hand puts
    // the probe, it can tell the two apart.
    var cfg = deviationConfig();
    cfg.touch_band_lo = 630;
    cfg.touch_band_hi = 690;
    var detector: Detector = .init(cfg);

    for (0..rest_warmup) |_| _ = detector.update(0);
    for (0..steady_warmup) |poll| _ = detector.update(railed(poll));
    try std.testing.expect(!detector.on);

    // And the same probe taken to where a hand puts it does fire.
    var hand: Detector = .init(cfg);
    for (0..rest_warmup) |_| _ = hand.update(0);
    for (0..steady_warmup) |_| _ = hand.update(660);
    try std.testing.expect(hand.on);
}

test "a banded deviation probe lets go when it leaves the band" {
    var cfg = deviationConfig();
    cfg.touch_band_lo = 630;
    cfg.touch_band_hi = 690;
    // With a second threshold in play the latch waits to be back at rest before
    // it decays, and a hand going straight to a rail never passes through rest.
    // Leaving the band has to be enough on its own.
    cfg.counts = 100;
    var detector: Detector = .init(cfg);

    for (0..rest_warmup) |_| _ = detector.update(0);
    for (0..steady_warmup) |_| _ = detector.update(660);
    try std.testing.expect(detector.on);

    // Straight from a hand to a rail, which never passes back through rest.
    for (0..steady_warmup) |poll| _ = detector.update(railed(poll));
    try std.testing.expect(!detector.on);
}

test "without a band the deviation model still fires on any big move" {
    // Unchanged where nobody has said where a hand puts the probe.
    var detector: Detector = .init(deviationConfig());
    for (0..rest_warmup) |_| _ = detector.update(0);
    for (0..steady_warmup) |poll| _ = detector.update(railed(poll));
    try std.testing.expect(detector.on);
}

test "how long the steady model takes to notice a hand arriving and leaving" {
    // The room's complaint is a wait between touching a plant and hearing it
    // change. This is the detector's share of that, measured with the settings
    // a room is actually running: a band where a hand puts the probe, a loose
    // range, and a probe that reads nought when nobody is there.
    var cfg = steadyConfig();
    cfg.touch_band_lo = 630;
    cfg.touch_band_hi = 690;
    cfg.still_range = 400;
    var detector: Detector = .init(cfg);

    const polls_per_s: usize = 44100 / sensor_poll_frames;
    for (0..3 * polls_per_s) |poll| _ = detector.update(flatlined(poll));

    var to_latch: usize = 0;
    while (!detector.on) : (to_latch += 1) _ = detector.update(660);

    var to_release: usize = 0;
    while (detector.on) : (to_release += 1) _ = detector.update(flatlined(to_release));

    // Measured: 314 polls to latch and 116 to release, which is 0.91s and
    // 0.34s. Asserted loosely because the exact figure is arithmetic about the
    // window; what matters is the order of magnitude. A room waiting ten
    // seconds between touching a plant and hearing it change is not waiting for
    // this, and this test is here so the next person does not have to guess.
    try std.testing.expect(to_latch < 2 * polls_per_s);
    try std.testing.expect(to_release < 2 * polls_per_s);
}

test "a band counts how much of the second the probe was there" {
    // The rule a room can check by eye: most of the last second inside the
    // band is a hand, and a rig throwing rails through a good touch does not
    // change the answer.
    var cfg = steadyConfig();
    cfg.touch_band_lo = 650;
    cfg.touch_band_hi = 670;
    var detector: Detector = .init(cfg);

    // Four readings in five where a hand puts it, the fifth from nowhere.
    for (0..steady_warmup) |poll| {
        _ = detector.update(if (poll % 5 == 4) -4096 else 660);
    }
    try std.testing.expect(detector.on);
}

test "a probe passing through the band is not a hand" {
    // Half in and half a long way out, which is a probe on its way somewhere
    // rather than one somebody is holding.
    var cfg = steadyConfig();
    cfg.touch_band_lo = 650;
    cfg.touch_band_hi = 670;
    var detector: Detector = .init(cfg);

    for (0..steady_warmup) |poll| {
        _ = detector.update(if (poll % 2 == 0) 660 else 12000);
    }
    try std.testing.expect(!detector.on);
}

test "the two probes are given their own bands" {
    // A hand puts one probe near six hundred and sixty and the other near
    // twenty-five thousand. One band for both would serve neither.
    var cfg = steadyConfig();
    cfg.touch_band_lo = 650;
    cfg.touch_band_hi = 670;
    cfg.touch_band_lo_bc = 24000;
    cfg.touch_band_hi_bc = 26000;
    var machine: Machine = .init(cfg);

    for (0..steady_warmup) |_| {
        _ = machine.update(660, 25000);
    }
    try std.testing.expect(machine.a.on);
    try std.testing.expect(machine.bc.on);
}

test "a probe in the other plant's band is not a hand on this one" {
    var cfg = steadyConfig();
    cfg.touch_band_lo = 650;
    cfg.touch_band_hi = 670;
    cfg.touch_band_lo_bc = 24000;
    cfg.touch_band_hi_bc = 26000;
    var machine: Machine = .init(cfg);

    // Each probe sitting where the other one's hand would put it.
    for (0..steady_warmup) |_| {
        _ = machine.update(25000, 660);
    }
    try std.testing.expect(!machine.a.on);
    try std.testing.expect(!machine.bc.on);
}

test "a band is asked of a whole window, not of a share of one still enough" {
    // A probe that is still and only sometimes where a hand puts it is not a
    // hand. The share is the whole question a band asks, so it has to be a
    // share worth having: a third of the window inside the band is a probe
    // that wandered past, and the rig has more of those than it has hands.
    var cfg = steadyConfig();
    cfg.touch_band_lo = 650;
    cfg.touch_band_hi = 670;
    var detector: Detector = .init(cfg);

    // Calm readings, a third of them in the band and the rest just outside it,
    // so nothing but the share can tell this from a touch.
    for (0..steady_warmup) |poll| {
        _ = detector.update(if (poll % 3 == 0) 660 else 700);
    }
    try std.testing.expect(!detector.on);
}

test "the share a band wants is the one the config was given" {
    // Above the share and it is a hand, below it and it is not, and the line
    // is the number in the config rather than one buried in the model.
    var cfg = steadyConfig();
    cfg.touch_band_lo = 650;
    cfg.touch_band_hi = 670;
    cfg.band_share = 0.9;
    var strict: Detector = .init(cfg);

    // Four readings in five inside the band: a hand under the preset's three
    // fifths, and not one under nine tenths.
    for (0..steady_warmup) |poll| {
        _ = strict.update(if (poll % 5 == 4) 700 else 660);
    }
    try std.testing.expect(!strict.on);

    cfg.band_share = default_band_share;
    var lenient: Detector = .init(cfg);
    for (0..steady_warmup) |poll| {
        _ = lenient.update(if (poll % 5 == 4) 700 else 660);
    }
    try std.testing.expect(lenient.on);
}

test "the preset window is four hundred polls of the rig's poll rate" {
    // What a band is asked of. Four hundred readings is enough that a share of
    // them means something: at three fifths that is two hundred and forty
    // readings where a hand puts the probe, which nothing but a hand manages
    // for that long.
    const window: spread_mod.Spread =
        .init(default_still_window_ms, 44100, sensor_poll_frames);
    try std.testing.expectEqual(@as(u32, 400), window.len);
}

/// Polls a second, at the size the engine runs the detector at.
const poll_rate: usize = 345;

/// A probe at rest on the deviation rig: a couple of counts of wobble, which is
/// what gives the median something to measure a deviation against.
fn restingWobble(poll: usize) i16 {
    return if (poll % 3 == 0) 4 else -4;
}

/// The same wobble around a hand's level.
fn heldWobble(poll: usize) i16 {
    return if (poll % 3 == 0) 3004 else 2996;
}

test "the deviation model holds a hand that outlasts the baseline window" {
    // The fault this rig actually shows: the median is a minute long, a hand
    // stays for three, and after thirty seconds the hand is most of the window.
    // The median walks onto the hand, the score falls to nothing, and the probe
    // reads itself back to rest with somebody still holding the plant.
    var cfg = deviationConfig();
    cfg.hold = true;
    var detector: Detector = .init(cfg);

    for (0..70 * poll_rate) |poll| _ = detector.update(restingWobble(poll));

    const held_polls = 180 * poll_rate;
    var polls_reported: usize = 0;
    for (0..held_polls) |poll| {
        if (detector.update(heldWobble(poll))) polls_reported += 1;
    }

    try std.testing.expect(detector.on);
    try std.testing.expect(polls_reported > held_polls * 95 / 100);
}

test "a probe is at rest again once a long hand comes off" {
    // The other half of the same fault. A median that learned the hand is a
    // median measuring rest as an excursion, so letting go reads as a touch --
    // which on plant B starts a recording nobody asked for.
    var cfg = deviationConfig();
    cfg.hold = true;
    var detector: Detector = .init(cfg);

    for (0..70 * poll_rate) |poll| _ = detector.update(restingWobble(poll));
    for (0..180 * poll_rate) |poll| _ = detector.update(heldWobble(poll));

    var polls_reported: usize = 0;
    for (0..5 * poll_rate) |poll| {
        if (detector.update(restingWobble(poll))) polls_reported += 1;
    }

    try std.testing.expect(!detector.on);
    try std.testing.expect(detector.at_rest);
    // The hand let go once, so the latch falls once. Nothing fires on the way
    // back down.
    try std.testing.expect(polls_reported < poll_rate);
}

test "a long hand at the level this rig reads is held for all of it" {
    // The rig's own numbers: a hand puts the probe near twenty-five thousand
    // and leaves it there for a quarter of an hour. Every sample of that is a
    // sample the median must not take.
    var cfg = deviationConfig();
    cfg.hold = true;
    var detector: Detector = .init(cfg);

    for (0..70 * poll_rate) |poll| _ = detector.update(restingWobble(poll));

    const held_polls = 15 * 60 * poll_rate;
    var polls_reported: usize = 0;
    for (0..held_polls) |poll| {
        const raw: i16 = if (poll % 3 == 0) 25004 else 24996;
        if (detector.update(raw)) polls_reported += 1;
    }

    try std.testing.expect(detector.on);
    try std.testing.expect(polls_reported > held_polls * 95 / 100);
}

test "a hand that leaves the probe somewhere new does not deafen it for good" {
    // The failure the resample exists for. Fifteen minutes of a hand moves
    // where the electrode settles, so the probe comes back to four hundred
    // rather than nought. Measured against a median full of samples from
    // before the hand, that is a touch -- and one that never ends, because the
    // reading never moves again.
    //
    // Nothing in the readings tells this from a hand still sitting there, so
    // the ceiling is what ends it: past it, rest is measured where the probe
    // now is. Shortened here to keep the test quick; in the room it is twenty
    // minutes.
    var cfg = deviationConfig();
    cfg.hold = true;
    cfg.baseline_stale_s = 60.0;
    var detector: Detector = .init(cfg);

    for (0..70 * poll_rate) |poll| _ = detector.update(restingWobble(poll));
    for (0..30 * poll_rate) |poll| {
        _ = detector.update(if (poll % 3 == 0) 25004 else 24996);
    }
    try std.testing.expect(detector.on);

    // The hand comes off, and the probe does not return to where it was.
    const drifted = struct {
        fn read(poll: usize) i16 {
            return if (poll % 3 == 0) 404 else 396;
        }
    }.read;
    for (0..90 * poll_rate) |poll| _ = detector.update(drifted(poll));

    try std.testing.expect(!detector.on);
    try std.testing.expect(detector.at_rest);

    // And it hears the next hand, measured against the rest it actually has.
    for (0..5 * poll_rate) |poll| {
        _ = detector.update(if (poll % 3 == 0) 25004 else 24996);
    }
    try std.testing.expect(detector.on);
}

test "hand after hand does not end up with the answer inside out" {
    // The fault the room reports: hold the plant over and over and at some
    // point the effect reverses -- the plant sounds when nobody is on it and
    // goes quiet under a hand. That is the median having learned the hand as
    // rest, and once it has, every reading means the opposite of what it says.
    var cfg = deviationConfig();
    cfg.hold = true;
    var detector: Detector = .init(cfg);

    for (0..70 * poll_rate) |poll| _ = detector.update(restingWobble(poll));

    // Twenty hands of a minute each, let go of for barely a third of a second
    // between them -- less than the median's warmup, which is what made the
    // answer turn over when letting go threw the window away.
    for (0..20) |_| {
        for (0..60 * poll_rate) |poll| {
            _ = detector.update(if (poll % 3 == 0) 25004 else 24996);
        }
        for (0..poll_rate / 3) |poll| _ = detector.update(restingWobble(poll));
    }

    // A plant nobody is touching is silent.
    for (0..5 * poll_rate) |poll| _ = detector.update(restingWobble(poll));
    try std.testing.expect(!detector.on);

    // And the next hand is still heard.
    for (0..5 * poll_rate) |poll| {
        _ = detector.update(if (poll % 3 == 0) 25004 else 24996);
    }
    try std.testing.expect(detector.on);
}

test "a probe that never comes back to rest learns anyway in the end" {
    // Learning only at rest is what saves the ten-minute hand, and it is also
    // how a probe goes deaf: one that has genuinely drifted, or latched by
    // mistake, is never at rest again and would refuse to learn forever. The
    // refusal expires, the median drags onto the new level, and the probe
    // hears the next hand.
    var cfg = deviationConfig();
    cfg.hold = true;
    cfg.baseline_stale_s = 20.0;
    var detector: Detector = .init(cfg);

    for (0..70 * poll_rate) |poll| _ = detector.update(restingWobble(poll));

    // Well inside the refusal: still reading the drift as a hand.
    for (0..15 * poll_rate) |poll| _ = detector.update(heldWobble(poll));
    try std.testing.expect(detector.on);

    for (0..120 * poll_rate) |poll| _ = detector.update(heldWobble(poll));
    try std.testing.expect(!detector.on);
    try std.testing.expect(detector.at_rest);
}

/// Probe B as the new rig's journal shows it: pinned at the supply rail, with a
/// share of its polls dropping toward ground between the readings a status line
/// prints. The dropouts are the difference between the 25761 the line shows and
/// the 23977 the averaging reads, and it is their *density* that wanders --
/// which is a move in the mean that nobody's hand had anything to do with.
fn pinnedWithDropouts(poll: usize, in_fifteen: usize) i16 {
    return if (poll % 15 < in_fifteen) 0 else 25761;
}

test "a wandering dropout density scores as a touch on the score alone" {
    // The fault as the rig hands it over. One dropout in fifteen puts the mean
    // at about 24000; two puts it at about 22300. That is seventeen hundred
    // counts of movement with the plant untouched, and against a probe this
    // smooth the median absolute deviation is on its floor -- so the score
    // divides seventeen hundred by twenty-five and calls it sixty-eight
    // deviations. Nothing about the score can tell this from a hand.
    var detector: Detector = .init(deviationConfig());

    for (0..70 * poll_rate) |poll| _ = detector.update(pinnedWithDropouts(poll, 1));
    try std.testing.expect(!detector.on);

    for (0..5 * poll_rate) |poll| _ = detector.update(pinnedWithDropouts(poll, 2));
    try std.testing.expect(detector.on);
}

test "a counts floor refuses the move the score could not" {
    // The same readings against a threshold in the units the probe reads. A
    // touch on this probe is the whole way to ground, twenty-four thousand
    // counts; seventeen hundred is not a small touch, it is not a touch.
    var cfg = deviationConfig();
    cfg.counts = 10000;
    var detector: Detector = .init(cfg);

    for (0..70 * poll_rate) |poll| _ = detector.update(pinnedWithDropouts(poll, 1));
    for (0..5 * poll_rate) |poll| {
        _ = detector.update(pinnedWithDropouts(poll, 2));
        try std.testing.expect(!detector.on);
    }
}

test "a counts floor still lets the hand through" {
    // And the floor has to be a floor rather than a gag: the move it is set
    // against is the one the room actually makes.
    var cfg = deviationConfig();
    cfg.counts = 10000;
    var detector: Detector = .init(cfg);

    for (0..70 * poll_rate) |poll| _ = detector.update(pinnedWithDropouts(poll, 1));
    for (0..5 * poll_rate) |_| _ = detector.update(0);
    try std.testing.expect(detector.on);

    // And lets go again, which the floor's own half-way release decides.
    for (0..10 * poll_rate) |poll| _ = detector.update(pinnedWithDropouts(poll, 1));
    try std.testing.expect(!detector.on);
}

test "each probe carries its own floor" {
    // The two probes move by different amounts on this rig -- plant A goes
    // about nine thousand counts up, plant B twenty-four thousand down -- so
    // one floor cannot serve both, and BC must not silently inherit A's.
    var cfg = deviationConfig();
    cfg.counts = 4000;
    cfg.counts_bc = 10000;

    const bc = cfg.forBc();
    try std.testing.expectEqual(@as(i16, 10000), bc.counts.?);

    // Unset, BC takes A's, which is the behaviour every other paired field has.
    var shared = deviationConfig();
    shared.counts = 4000;
    try std.testing.expectEqual(@as(i16, 4000), shared.forBc().counts.?);
}

fn learnedConfig() Config {
    return .{
        .sample_rate = 44100,
        .poll_frames = sensor_poll_frames,
        .model = .learned,
    };
}

/// A probe sitting at a level with the couple of counts of wobble any real one
/// has. Flat enough to be still, alive enough not to be a fixture nobody has
/// wired up.
fn restingAt(level: i16, poll: usize) i16 {
    return level +% @as(i16, if (poll % 3 == 0) 2 else -2);
}

test "a touch is answered wherever the probe rests and whichever way it goes" {
    // The four shapes a rig in this piece takes, which used to be four things
    // to measure and type in. Nothing here is configured: the model finds the
    // two levels the probe visits, decides which one it lives at by which it
    // keeps returning to, and puts the line halfway between.
    //
    //     rest ~0      ->  touch ~25000
    //     rest ~25000  ->  touch ~0
    //     rest ~12000  ->  touch ~0
    //     rest ~12000  ->  touch ~25000
    const rigs = [_][2]i16{
        .{ 0, 25000 },
        .{ 25000, 0 },
        .{ 12000, 0 },
        .{ 12000, 25000 },
    };

    for (rigs) |rig| {
        const rest = rig[0];
        const touch = rig[1];

        var detector: Detector = .init(learnedConfig());
        for (0..rest_warmup) |poll| _ = detector.update(restingAt(rest, poll));
        try std.testing.expect(!detector.on);

        for (0..steady_warmup) |poll| _ = detector.update(restingAt(touch, poll));
        try std.testing.expect(detector.on);

        // And it lets go. A rig that latches and never releases is the fault
        // this model was reached for.
        for (0..steady_warmup) |poll| _ = detector.update(restingAt(rest, poll));
        try std.testing.expect(!detector.on);
    }
}

test "the rig is read off the probe, not off a flag" {
    // What the model works out on its own, held here because it is the whole
    // claim: where the probe lives, and where a hand takes it.
    var detector: Detector = .init(learnedConfig());
    for (0..rest_warmup) |poll| _ = detector.update(restingAt(24000, poll));
    for (0..steady_warmup * 2) |poll| _ = detector.update(restingAt(300, poll));
    for (0..rest_warmup) |poll| _ = detector.update(restingAt(24000, poll));

    // Rest is the level it keeps coming back to, and the other cluster is
    // where the hand went -- below it on this rig, which nobody said.
    try std.testing.expect(@abs(@as(i32, detector.baseline.base) - 24000) < 500);
    try std.testing.expect(detector.baseline.low < 12000);
}

test "a hand that drops out is still a hand" {
    // What a count buys over a median and a range. A probe reads its held level
    // for fourteen polls and throws a rail on the fifteenth: the median of that
    // window is the held level, but the range is the rail's full height, and a
    // stillness test alone reads the whole touch as nobody there.
    var detector: Detector = .init(learnedConfig());
    for (0..rest_warmup) |poll| _ = detector.update(restingAt(0, poll));
    // One clean touch, so the rig is known before the dropouts start.
    for (0..steady_warmup) |poll| _ = detector.update(restingAt(25000, poll));
    for (0..rest_warmup) |poll| _ = detector.update(restingAt(0, poll));

    for (0..steady_warmup) |poll| {
        const raw: i16 = if (poll % 15 == 14) 0 else restingAt(25000, poll);
        _ = detector.update(raw);
    }
    try std.testing.expect(detector.on);
}

test "the first hand of the evening is answered before any rig is known" {
    // Nobody has touched it yet, so there is no second cluster and no line to
    // draw. The plain question stands in until there is: the window sitting
    // somewhere the probe does not live. A model that needed to see a touch
    // before it could report one would owe the first visitor nothing.
    var detector: Detector = .init(learnedConfig());
    for (0..rest_warmup) |poll| _ = detector.update(restingAt(0, poll));
    for (0..steady_warmup) |poll| _ = detector.update(restingAt(25000, poll));
    try std.testing.expect(detector.on);
}

/// The rig as the room's journal actually shows it: a probe that flips between
/// the two rails from one reading to the next, touched or not. `share` is how
/// much of the time it sits at the far rail.
fn flipping(poll: usize, rest: i16, far: i16, share: usize) i16 {
    return if (poll % 10 < share) far + @as(i16, if (poll % 3 == 0) 2 else -2) else rest;
}

test "a probe flailing between the rails with nobody on it stays quiet" {
    // Plant A on the journal, untouched: 25886, 735, 10, 12, 25886, 9, 1, 25616.
    // A third of its readings are at the far rail and it is still nobody. A
    // model that answered this would sound all evening with an empty room.
    var detector: Detector = .init(learnedConfig());
    for (0..rest_warmup) |poll| _ = detector.update(flipping(poll, 5, 25700, 3));
    for (0..steady_warmup * 2) |poll| _ = detector.update(flipping(poll, 5, 25700, 3));
    try std.testing.expect(!detector.on);
}

test "a hand on a probe that drops out half the time is still a hand" {
    // The same rig with somebody holding it: the probe still throws the home
    // rail constantly, but it is at the far one far more of the time than not.
    // Between percentiles both look identical -- full scale either way -- which
    // is why stillness cannot be the question here and the share is.
    var detector: Detector = .init(learnedConfig());
    for (0..rest_warmup) |poll| _ = detector.update(flipping(poll, 5, 25700, 3));
    for (0..steady_warmup * 2) |poll| _ = detector.update(flipping(poll, 5, 25700, 8));
    try std.testing.expect(detector.on);

    // And it goes quiet again when the hand comes off.
    for (0..steady_warmup * 2) |poll| _ = detector.update(flipping(poll, 5, 25700, 3));
    try std.testing.expect(!detector.on);
}

/// Polls enough to put a few hundred samples behind the long window.
///
/// `rest_warmup` fills the spread window and satisfies the calibration, which
/// is all the older fixtures need. Finding two clusters is a question about the
/// long window, and a long window with ninety samples in it answers it by
/// accident: one sample in twenty is the fifth percentile, so ninety samples
/// put `high` four readings from the end and a single stray reading moves it.
const cluster_warmup: usize = 10 * rest_warmup;

/// A probe that wanders rather than visiting two levels.
///
/// Probe A on `service-log4`, with nobody on it: it reads anywhere from 9776 to
/// 15976 and everywhere in between. The ends of that are thousands of counts
/// from the middle, so there is a `reach` to find and a line to draw -- and the
/// line falls inside the wander, where the probe spends about as much of every
/// window past it as not. On that log the share reads 0.399 untouched against
/// 0.400 touched, which is not a strict answer but no answer at all.
fn wandering(rng: std.Random) i16 {
    return rng.intRangeAtMost(i16, 9776, 15976);
}

test "the rig is learned from a hand that keeps flipping home" {
    // The journal's plant A, held: it reads the far rail about half the polls
    // and home the rest, over and over, and never once holds still. The
    // window's own median does not leave home on a touch shaped like that, so a
    // long window fed window medians is fed nothing but home -- it has no
    // second cluster to find, draws no line, and the model meant to read the
    // rig off the probe reads nothing off it at all.
    var detector: Detector = .init(learnedConfig());
    for (0..cluster_warmup) |poll| _ = detector.update(flipping(poll, 5, 25700, 3));
    for (0..steady_warmup * 2) |poll| _ = detector.update(flipping(poll, 5, 25700, 5));

    // Home is what it keeps coming back to and the far rail is the other level,
    // both found off a probe that was never still for a single poll.
    try std.testing.expect(clampedAbsDiff(detector.baseline.base, 5) < 100);
    try std.testing.expect(detector.baseline.high > 20000);
}

test "a hand under half the window is counted, not written off" {
    // Four polls in ten at the far rail is four tenths of the window past the
    // line: a number a room can read, compare against the share, and argue
    // with. Fed window medians this is not a small number but no number at
    // all -- `reach` stays nought, no line is ever drawn, and the count the
    // whole model rests on never runs. The plant is then judged by the
    // stand-in meant for the first hand of the evening, which asks whether the
    // window's median has left home: a fixed half-the-window vote that nobody
    // chose and no room can move.
    var detector: Detector = .init(learnedConfig());
    for (0..cluster_warmup) |poll| _ = detector.update(flipping(poll, 5, 25700, 3));
    for (0..steady_warmup * 2) |poll| _ = detector.update(flipping(poll, 5, 25700, 4));

    try std.testing.expectApproxEqAbs(@as(f32, 0.4), detector.spread.above, 0.06);
}

test "a probe that only wanders has no two levels to find" {
    // A share low enough to answer this rig's own hands -- on the room's logs a
    // held probe is past the line a quarter to half the time -- is also low
    // enough for a wandering probe to clear by accident. So the line may only
    // be drawn where there are genuinely two clusters to draw it between, and
    // what says so is the gap: two levels leave the middle of it empty, and a
    // probe merely wandering fills it. Measured on the room's own logs, the
    // middle third of the gap holds 0.031 to 0.067 of the readings where there
    // are two levels, and 0.577 on the probe that only wanders.
    var cfg = learnedConfig();
    cfg.band_share = 0.2;

    var detector: Detector = .init(cfg);
    var prng: std.Random.DefaultPrng = .init(20260915);
    for (0..cluster_warmup) |_| _ = detector.update(wandering(prng.random()));
    try std.testing.expect(!detector.on);

    // And the refusal is the gap being full, not the reach being small: there
    // is plenty of reach here, which is exactly why a line gets drawn on this
    // probe in the first place.
    try std.testing.expect(detector.baseline.high - detector.baseline.low > 1000);
}

test "a long hand does not become where the probe lives" {
    // What the reading feed would cost if it also decided rest. A hand is in
    // that feed in its own right, so one lasting long enough to fill half the
    // window would make the far rail the median and turn the model inside out:
    // the plant sounds with an empty room and goes quiet under a hand. Hand
    // after hand, that is what a room sees as the effect reversing.
    //
    // It does not, because rest is read off the middles, where a hand of this
    // shape leaves no mark at all -- and that immunity has an edge worth being
    // plain about. A middle is a median, so it stays home while the hand is at
    // the far rail for under half the window, and becomes a coin toss at
    // exactly half. Past that the middles are the hand too, and a hand long
    // enough takes rest with it. The room's logs put a held probe at the far
    // rail a quarter to half the time, so the margin is real but it is not
    // wide, and a rig that clamped harder than this one would want the window
    // lengthened rather than this test loosened.
    //
    // Shares with room either side: untouched two polls in ten, held four,
    // against a share of three. The preset's own 0.6 has nowhere to sit in
    // that at all.
    var cfg = learnedConfig();
    cfg.band_share = 0.3;

    var detector: Detector = .init(cfg);
    for (0..cluster_warmup) |poll| _ = detector.update(flipping(poll, 5, 25700, 2));
    for (0..cluster_warmup * 3 / 2) |poll| _ = detector.update(flipping(poll, 5, 25700, 4));
    try std.testing.expect(detector.on);

    // Home is still home, measured through all of it.
    try std.testing.expect(clampedAbsDiff(detector.baseline.base, 5) < 100);

    for (0..steady_warmup * 2) |poll| _ = detector.update(flipping(poll, 5, 25700, 2));
    try std.testing.expect(!detector.on);
}

/// A probe whose home has moved, wandering in a band a long way from where the
/// long window still says it lives.
///
/// Probe BC in `probes.csv`, which the room found sitting between 11275 and
/// 13353 after an evening that began with it at nought and the rail.
fn wanderedHome(rng: std.Random) i16 {
    return rng.intRangeAtMost(i16, 11275, 13353);
}

test "a probe whose home moves is quiet on the way, not touched for the journey" {
    // What an electrode that has been moved, or warmed, or simply let go does:
    // it stops visiting the two levels the window learned and settles somewhere
    // between them. The window still says home is nought, so every reading is a
    // long way from home and the crude stand-in calls that a hand -- one that
    // never lets go, because the probe never moves back. On the room's own
    // capture that was ninety-six seconds of a clip looping at an empty plant.
    //
    // The stand-in is for the first hand of the evening, when no second level
    // has been seen and there is nothing else to ask. It is not an answer for a
    // probe whose two levels have gone muddled: there the honest answer is that
    // this probe cannot be read just now, and a probe that cannot be read is
    // quiet.
    var detector: Detector = .init(learnedConfig());
    var prng: std.Random.DefaultPrng = .init(20260915);

    for (0..cluster_warmup) |poll| _ = detector.update(flipping(poll, 5, 25685, 2));
    try std.testing.expect(!detector.on);

    var latched: usize = 0;
    for (0..cluster_warmup * 3) |_| {
        if (detector.update(wanderedHome(prng.random()))) latched += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), latched);
}

test "one probe answers a hand at either rail in the same run" {
    // The rig the room actually has: a hand takes probe A to the top some
    // touches and the bottom others, and nothing says in advance which. A
    // model that picked the further of the two ends and watched only that
    // answered half the evening's hands and was silent through the rest.
    var detector: Detector = .init(learnedConfig());
    for (0..cluster_warmup) |poll| _ = detector.update(restingAt(12000, poll));

    for (0..steady_warmup) |poll| _ = detector.update(restingAt(25000, poll));
    try std.testing.expect(detector.on);

    for (0..cluster_warmup) |poll| _ = detector.update(restingAt(12000, poll));
    try std.testing.expect(!detector.on);

    // The other way, same detector, nothing reconfigured in between.
    for (0..steady_warmup) |poll| _ = detector.update(restingAt(300, poll));
    try std.testing.expect(detector.on);
}

test "the share is a maximum of the two ends and never a sum" {
    // A probe wandering across its whole range spends about a quarter of the
    // window past each line. Summed that is a half, which sits close enough to
    // the share that the separation the count exists for is gone. Held apart,
    // a wanderer scores a quarter and a hand scores nearly all of it.
    var cfg = learnedConfig();
    cfg.band_share = 0.45;

    var detector: Detector = .init(cfg);
    var prng: std.Random.DefaultPrng = .init(20260916);
    for (0..cluster_warmup) |_| _ = detector.update(wandering(prng.random()));
    for (0..steady_warmup * 2) |_| _ = detector.update(wandering(prng.random()));

    try std.testing.expect(@max(detector.spread.above, detector.spread.below) < 0.45);
}

test "a hand sitting on the line holds rather than chattering" {
    // The share a probe scores on this rig lands on the threshold, not far
    // past it: 0.512 untouched at worst and 0.628 held at the median, against
    // a line at 0.600. One threshold answering both directions makes that a
    // latch and a release on alternate windows, which a held voice plays as
    // the clip wobbling in and out.
    var cfg = learnedConfig();
    cfg.band_share = 0.6;
    cfg.band_release = 0.4;

    var detector: Detector = .init(cfg);
    for (0..cluster_warmup) |poll| _ = detector.update(restingAt(0, poll));
    for (0..steady_warmup) |poll| _ = detector.update(restingAt(25000, poll));
    try std.testing.expect(detector.on);

    // Half the window at the rail: under the latch share, over the release
    // share. Nothing may move.
    for (0..steady_warmup * 2) |poll| {
        _ = detector.update(if (poll % 2 == 0) restingAt(25000, poll) else restingAt(0, poll));
    }
    try std.testing.expect(detector.on);

    // And a hand genuinely off clears the release share and lets go.
    for (0..steady_warmup * 2) |poll| _ = detector.update(restingAt(0, poll));
    try std.testing.expect(!detector.on);
}
