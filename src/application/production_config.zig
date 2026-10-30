const core = @import("../core/root.zig");
const boxes = @import("boxes/root.zig");

/// The rig in the room decides which of the two models this is.
///
/// `deviation` is right where a probe rests somewhere and a touch moves it.
/// `steady` is right where the electrode floats: the flailing has no rest to
/// measure from, so what is asked instead is whether the probe has gone still.
/// On the floating rig `deviation` reads a MAD of about 260 counts on probe A,
/// which is a threshold no touch can clear.
///
/// The floating rig's preset. `steady` has to be told nothing about where a
/// held probe sits, which is the point: plant A's probe clamps somewhere near
/// 660 and plant B's near 1, neither is predictable from one day to the next,
/// and the model asks how tightly the readings cluster rather than where:
///
///     pub const touch: core.touch.Config = .{
///         .sample_rate = core.sample_rate,
///         .poll_frames = core.sensor_frames,
///         .model = .steady,
///     };
///
/// The two thresholds have defaults measured off `touch.csv`; `zig build
/// replay -- touch.csv --sweep` is how to check them against a fresh capture,
/// and `--still-range` is how to try a number without a rebuild.
///
/// `drone.span` has to move with it. In `steady` the pitch is the level the
/// probe went still at, so the span wants to be about the range those levels
/// fall in, and the floor is what makes a touch audible at all:
///
///     pub const drone: core.noise.Shape = .{
///         .span = 1000,
///         .touch_floor = 0.6,
///         .burst_s = 0.4,
///         .glide_s = 4.0,
///         .release_s = 0.5,
///     };
pub const touch: core.touch.Config = .{
    .sample_rate = core.sample_rate,
    .poll_frames = core.sensor_frames,
    .model = .deviation,
    .hold_bc_ms = 20.0,
    .counts = default_counts,
    .counts_bc = default_counts_bc,
};

/// How big a move a touch must be, in the counts the probe actually reads.
///
/// The score alone cannot answer this. It divides a move by how much the probe
/// normally wanders, and on this rig that denominator means very little: probe
/// A reads nought or one with nobody on it, so its median absolute deviation
/// sits on the floor of twenty-five and the smallest wobble scores deviations
/// the threshold cannot tell from a hand.
///
/// So a second threshold, in units the room can read off the status line and
/// the rig cannot inflate.
///
/// Plant A's is deliberately far under its excursion rather than near half of
/// it. The probe there behaves as a switch -- nought or one untouched, about
/// twenty-five thousand under a hand -- and the room's complaint was that a
/// light touch did nothing and only a tight grip sounded. A floor at three
/// thousand is twelve per cent of a full touch and still forty times the worst
/// wander the journal shows at rest, so a hand that only half connects counts
/// and nothing at rest does.
///
/// Plant B moves about twenty-four thousand and keeps a floor near half of it:
/// a wrong latch there starts a recording, which is the fault a room actually
/// hears.
///
/// `--counts` and `--counts-b` are how to try other numbers without a rebuild.
pub const default_counts: i16 = 3000;
pub const default_counts_bc: i16 = 10000;

/// What the room asked for on the command line, or nothing where it did not.
///
/// Named rather than positional because four of these are `?i16` in a row: a
/// caller that handed the range where the floor goes would compile, run, and
/// be wrong in a way no test could see.
pub const Overrides = struct {
    model: ?core.touch.Model = null,
    still_range: ?i16 = null,
    still_release: ?i16 = null,
    still_window_ms: ?f32 = null,
    /// How much of the window must be past the line before a touch counts,
    /// under `learned`. The number the model's answer turns on, and until now
    /// the one threshold that could not be tried without a rebuild.
    band_share: ?f32 = null,
    /// The share at or below which the touch is over, under `learned`.
    band_release: ?f32 = null,
    /// Probe BC's own share and release. Unset, BC takes A's.
    band_share_bc: ?f32 = null,
    band_release_bc: ?f32 = null,
    /// Probe BC's lines at a fixed distance from rest, under `learned`.
    edge_bc: ?i16 = null,
    /// Probe A's lines at a fixed distance from rest, under `learned`.
    edge: ?i16 = null,
    /// Where a held probe sits, per plant. The two probes do not sit at the
    /// same place: on this rig a hand puts one near six hundred and sixty and
    /// the other near twenty-five thousand.
    plant_band: [2]?[2]i16 = .{ null, null },
    /// The tap window each plant was given, where the room said. A plant whose
    /// mode is `.tap` is given `tap_window_ms` without being asked; this is how
    /// a room says a different length, or none.
    plant_window: [2]?core.touch.Window = .{ null, null },
    /// The move in counts a touch must clear, per probe. Zero is the room
    /// saying "no floor at all", which is a different thing from leaving the
    /// flag off: off keeps the measured number, zero asks the score alone.
    counts: ?i16 = null,
    counts_bc: ?i16 = null,
    /// How long a plant must stay latched before it counts as touched. Unset
    /// keeps `confirm_ms`; zero answers the latch at once.
    confirm_ms: ?f32 = null,
    /// How far up the pitch range a touch starts, and how long it takes to
    /// climb to the top from there. Unset leaves the box's own numbers.
    touch_floor: ?f32 = null,
    touch_rise_s: ?f32 = null,
    /// Semitones the climb bends per tenth of the probe's share. Zero is a
    /// straight climb; unset leaves the model's own choice.
    wobble_semis: ?f32 = null,
    /// Semitones the climb drifts at random either way. Unset leaves the
    /// model's own choice.
    gust_semis: ?f32 = null,
    /// The drone's level in dB against the level the boxes were tuned at.
    /// Unset leaves the model's own choice.
    drone_gain_db: ?f32 = null,
    /// What the drone is made of. Unset leaves the model's own choice.
    timbre: ?core.timbre.Kind = null,
    /// How long a released climb takes to fall home, and how loud the drone
    /// idles. Unset leaves the model's own choice.
    touch_fall_s: ?f32 = null,
    idle_gain: ?f32 = null,
    /// Semitones a held climb rises from its floor. Unset leaves the model's
    /// own choice; there is no way to ask for "all the way up" but a big one.
    touch_climb_semis: ?f32 = null,
};

/// How long a tap may last and still be a tap, for whichever plant asks to be
/// one. Measured on the deviation rig, where it was plant B's whether anybody
/// wanted it or not.
pub const tap_window_ms: f32 = 1000.0;

/// How long a plant must stay latched before it counts as touched, under every
/// model. The probes jump for a few hundred milliseconds with nobody on them,
/// and each jump was starting a clip; asked for on 2026-10-30.
pub const confirm_ms: f32 = 1500.0;

/// Which box a run is: what the room said, or failing that what the machine is
/// called, or failing that nobody.
pub fn chosenBox(asked: ?boxes.Box, hostname: []const u8) ?boxes.Box {
    return asked orelse boxes.fromHostname(hostname);
}

/// The preset with the room's overrides applied. Anything left unset on the
/// command line keeps the number the box was measured at.
pub fn touchWith(
    base: core.touch.Config,
    overrides: Overrides,
    /// How each plant answers a hand. The detector is told the same thing the
    /// clips are: a hold wants a level, a tap wants a gesture, and a trigger
    /// wants the edge. Only a plant asked to be a tap is given a tap window --
    /// the window discards a hand that rests, which is the touch a room makes.
    modes: [2]core.clips.Mode,
) core.touch.Config {
    var cfg = base;
    if (overrides.model) |chosen| cfg.model = chosen;
    cfg.confirm_ms = overrides.confirm_ms orelse confirm_ms;

    // Under `learned`, probe BC's line is drawn halfway to the deepest dip it
    // has seen, and on this rig that is ground: a line near thirteen thousand.
    // A hand on BC does not hold it down there -- it scatters it, 1158, 9421,
    // 17862, back to the rail a third of the time -- so only a fifth to a
    // third of a touch's window is past that line and it never latches. The
    // probe sits steady over 26k untouched, so the question that works is
    // whether it has left the rail at all: a line a thousand under rest, which
    // nothing untouched crosses and a touch is past 0.5 to 0.8 of the time.
    // Measured on the 2026-10-29 capture. The command line still wins.
    //
    // Probe A asks the same question for the same reason, deeper: untouched
    // it wanders from about 22k to 25.7k, and a hand drags it well down,
    // mostly under 15k and as far as nought. A line five thousand under rest
    // is clear of the wander by sixteen hundred, and every touch on that
    // capture spent most of its window past it. Rest is the model's own
    // rolling median, so a probe that settles somewhere new takes its line
    // with it rather than sounding until somebody restarts the box.
    if (cfg.model == .learned) {
        if (cfg.edge == null) cfg.edge = learned_edge_a;
        cfg.band_share = learned_band_share_a;
        cfg.band_release = learned_band_release_a;
        if (cfg.edge_bc == null) cfg.edge_bc = learned_edge_bc;
        if (cfg.band_share_bc == null) cfg.band_share_bc = learned_band_share_bc;
        if (cfg.band_release_bc == null) cfg.band_release_bc = learned_band_release_bc;
    }

    cfg.hold = modes[0] == .hold;
    cfg.hold_bc = modes[1] == .hold;
    cfg.window_ms = if (modes[0] == .tap) tap_window_ms else null;
    cfg.window_bc = if (modes[1] == .tap) .{ .ms = tap_window_ms } else null;

    if (overrides.still_range) |counts| cfg.still_range = counts;
    if (overrides.still_release) |counts| cfg.still_release = counts;
    if (overrides.still_window_ms) |ms| cfg.still_window_ms = ms;
    if (overrides.band_share) |fraction| cfg.band_share = fraction;
    if (overrides.band_release) |fraction| cfg.band_release = fraction;
    if (overrides.band_share_bc) |fraction| cfg.band_share_bc = fraction;
    if (overrides.band_release_bc) |fraction| cfg.band_release_bc = fraction;
    if (overrides.edge_bc) |counts| cfg.edge_bc = counts;
    if (overrides.edge) |counts| cfg.edge = counts;
    if (overrides.plant_band[0]) |band| {
        cfg.touch_band_lo = band[0];
        cfg.touch_band_hi = band[1];
    }
    if (overrides.plant_band[1]) |band| {
        cfg.touch_band_lo_bc = band[0];
        cfg.touch_band_hi_bc = band[1];
    }
    // Plant A's window is a plain length, so `off` and "no window" are the same
    // thing there. Plant B's is not: `null` on BC means A's, and a room saying
    // `off` has to survive that.
    if (overrides.plant_window[0]) |chosen| cfg.window_ms = switch (chosen) {
        .off => null,
        .ms => |ms| ms,
    };
    if (overrides.plant_window[1]) |chosen| cfg.window_bc = chosen;

    // Zero is the room asking for no floor, which the detector spells `null`.
    if (overrides.counts) |floor| cfg.counts = if (floor == 0) null else floor;
    if (overrides.counts_bc) |floor| cfg.counts_bc = if (floor == 0) null else floor;
    return cfg;
}

/// Probe A's line under `learned`, in counts under rest, and the share of the
/// window past it that starts and ends a touch. See `touchWith`.
pub const learned_edge_a: i16 = 5000;
pub const learned_band_share_a: f32 = 0.5;
pub const learned_band_release_a: f32 = 0.25;

/// Probe BC's line under `learned`, in counts under rest, and the share of the
/// window past it that starts and ends a touch. See `touchWith`.
pub const learned_edge_bc: i16 = 1000;
pub const learned_band_share_bc: f32 = 0.4;
pub const learned_band_release_bc: f32 = 0.2;

pub const seed: u64 = 0xC0FFEE;

/// What plant A sounds like.
///
/// `span` is the deviation that reaches the top of the pitch range, and it has
/// to be the move the probe actually makes. Three thousand was measured on a
/// rig whose hand moved the probe about that far. This one moves it twenty-five
/// thousand, so every touch saturated the span and arrived at `freq_max`
/// whatever the grip -- the room heard the same throttle being opened every
/// time, which is the complaint.
///
/// At twenty-five thousand a touch spends the range instead of pinning it, and
/// the floor is what keeps the quiet end audible: a move just over the counts
/// floor is a twelfth of the span, which without a floor is 44 Hz against an
/// idle of 30 and cannot be heard as an answer. A floor of 0.35 puts it at
/// about 120 Hz and leaves a full grip the whole way to 800.
pub const drone: core.noise.Shape = .{
    .span = 25000,
    .touch_floor = 0.35,
    .burst_s = 0.4,
    .glide_s = 4.0,
    .release_s = 0.5,
};

/// The drone shape with the room's overrides applied, and the pairing the
/// `learned` model needs.
///
/// `learned` cannot hand a pitch to the reading. Its `deviation` is the gap
/// between the window's middle and rest, and a middle is a median: on a probe
/// that lives at two levels the median is one of them and never between, so the
/// reading offers the bottom of the range and the top and nothing else --
/// measured over an eight-second hold it took exactly two values. A room that
/// asks for `learned` and gets the reading mapping gets a switch, and no `span`
/// mends that because the input has two values in it.
///
/// So choosing that model chooses the ramp with it, unless the room says
/// otherwise. The other two models are left exactly as they were: there the
/// reading does carry a pitch, and every box measured so far was tuned on it.
pub fn droneWith(
    base: core.noise.Shape,
    overrides: Overrides,
    model: core.touch.Model,
) core.noise.Shape {
    var shape = base;
    if (model == .learned) {
        shape.touch_rise_s = core.noise.default_touch_rise_s;
        // Starting a ramp at the bottom of the range spends its first second
        // inaudible, which on a four-second climb is a quarter of the gesture.
        if (shape.touch_floor == 0.0) shape.touch_floor = core.noise.default_touch_floor_ramped;
        // The ../drone-playground pick of 2026-10-29, "Current + wind gust":
        // the narrow band the room knows, its climb made uneven by the gust
        // below rather than by the plant. The probe only says touched -- the
        // share's wobble is left off, so nothing about the reading reaches
        // the pitch; `--touch-wobble` brings it back. The gate is slow enough
        // that a touch swells in rather than switching on.
        shape.timbre = .band;
        shape.gate_ms = ramped_gate_ms;
        // Let go, the climb slows to a rest a little under where it was, the
        // level fading with it, rather than sliding three octaves downhill.
        shape.touch_fall_s = core.noise.default_touch_fall_s;
        shape.touch_settle_semis = core.noise.default_touch_settle_semis;
        // The bench's 2026-10-29 pick: small random swells along the climb,
        // so it rises like wind rather than a line, and the drone a little
        // quieter than the level the other models were tuned at.
        shape.gust_semis = core.noise.default_gust_semis;
        shape.out_gain = learned_out_gain;
    }
    shape.out_gain *= drone_lift_gain;
    if (overrides.touch_climb_semis) |semis| shape.touch_climb_semis = semis;
    if (overrides.timbre) |kind| shape.timbre = kind;
    if (overrides.touch_fall_s) |seconds| shape.touch_fall_s = seconds;
    if (overrides.idle_gain) |gain| shape.idle_gain = gain;
    if (overrides.wobble_semis) |semis| shape.wobble_semis = semis;
    if (overrides.gust_semis) |semis| shape.gust_semis = semis;
    if (overrides.drone_gain_db) |db| shape.out_gain = std.math.pow(f32, 10.0, db / 20.0);
    if (overrides.touch_floor) |fraction| shape.touch_floor = fraction;
    if (overrides.touch_rise_s) |seconds| shape.touch_rise_s = seconds;
    // A ramped touch skips the burst and reaches its floor through the glide
    // alone, so the preset's four-second glide stacked on the four-second rise:
    // a second after a touch was called the drone had covered a fifth of the
    // way to its floor. The ramp is already the smooth part, so the glide only
    // has to take the edge off the jump to the floor.
    if (shape.touch_rise_s != null) shape.glide_s = @min(shape.glide_s, ramped_glide_s);
    return shape;
}

/// The glide under a ramp. Short enough that a touch is heard leaving the
/// bottom as soon as it is called, long enough that the jump to the floor is a
/// swell into the climb rather than a step: at 0.15 s the room heard the jump.
pub const ramped_glide_s: f32 = 0.4;

/// The learned drone's level against the others: 8 dB down. The bench's pick
/// was 5; with the piano on plant B answering again the drone sat too far
/// forward, so it went down another 3. `--drone-gain` tries others.
pub const learned_out_gain: f32 = 0.3981;

/// The drone lifted 2 dB under every model, asked for in the room on
/// 2026-10-29.
pub const drone_lift_gain: f32 = 1.2589;

/// How loud the piano stems sit against the other clips: matched by measure
/// to the second jam, asked for on 2026-10-30 after +7.2 dB of steps by ear
/// still left the piano small. The stems are mastered quiet: -33.6 LUFS mean
/// as decoded (mono), against -20.4 for the second jam, which plays at
/// -17.4 after its +3 dB. -17.4 - -33.6 = +16.2 dB = 6.457. The loudest stem
/// peaks at -20.4 dBFS mono, so with `voice_gain` it reaches about -12 dBFS
/// and the clamp in pcm.zig is still nowhere near.
pub const piano_clip_gain: f32 = 6.457;

/// How loud the second jam sits against the other clips: 3 dB up, asked for
/// on 2026-10-30.
pub const tradvn2_clip_gain: f32 = 1.4125;

/// A step 10% quieter to the ear. Loudness doubles about every 10 dB, so 10%
/// quieter is 10*log2(0.9) = -1.5 dB, not an amplitude of 0.9.
const ten_percent_quieter: f32 = 0.8395;

/// The bell stems at the same level as the other clips (0 dB), settled on
/// 2026-10-30 after a day of steps between -3 dB and +3.6 dB.
pub const bell_clip_gain: f32 = 1.0;

/// Voice box 3 down 3 dB against the other clips, asked for on 2026-10-30:
/// about 20% quieter to the ear, then another 10% step on top, -4.5 dB in
/// all.
pub const voicebox3_clip_gain: f32 = 0.7079 * ten_percent_quieter;

/// Voice box 5 down by the same -4.5 dB as voice box 3, asked for on
/// 2026-10-30.
pub const voicebox5_clip_gain: f32 = voicebox3_clip_gain;

/// A step 10% louder to the ear: 10*log2(1.1) = +1.4 dB.
const ten_percent_louder: f32 = 1.1717;

/// Both insect mixes 10% louder to the ear, asked for on 2026-10-30.
pub const insect_clip_gain: f32 = ten_percent_louder;

/// Both noise boxes (2 and 4) 10% louder to the ear, asked for on 2026-10-30.
pub const noise_clip_gain: f32 = ten_percent_louder;

/// The gate under the learned drone, from the bench's pick.
pub const ramped_gate_ms: f32 = 400.0;

const std = @import("std");

test "the learned model is given a pitch it can actually carry" {
    // Without this, asking for `learned` on the command line gets a drone with
    // two pitches in it: the bottom of the range and the top.
    const ramped = droneWith(drone, .{}, .learned);
    try std.testing.expect(ramped.touch_rise_s != null);
    try std.testing.expect(ramped.touch_floor > 0.0);
}

test "the learned drone falls home slowly and idles as the band always has" {
    const ramped = droneWith(drone, .{}, .learned);
    try std.testing.expectEqual(core.noise.default_touch_fall_s, ramped.touch_fall_s.?);
    try std.testing.expectEqual(core.noise.default_idle_gain, ramped.idle_gain);
    const asked = droneWith(drone, .{ .touch_fall_s = 6.0, .idle_gain = 0.2 }, .learned);
    try std.testing.expectEqual(@as(f32, 6.0), asked.touch_fall_s.?);
    try std.testing.expectEqual(@as(f32, 0.2), asked.idle_gain);
    // The models tuned on the old release keep it.
    const plain = droneWith(drone, .{}, .deviation);
    try std.testing.expect(plain.touch_fall_s == null);
    try std.testing.expectEqual(core.noise.default_idle_gain, plain.idle_gain);
}

test "the learned drone climbs to the top in the band voice, and settles when let go" {
    const ramped = droneWith(drone, .{}, .learned);
    try std.testing.expect(ramped.touch_climb_semis == null);
    try std.testing.expectEqual(core.timbre.Kind.band, ramped.timbre);
    try std.testing.expectEqual(core.timbre.Kind.warm, droneWith(drone, .{ .timbre = .warm }, .learned).timbre);
    try std.testing.expectEqual(core.noise.default_touch_settle_semis, ramped.touch_settle_semis.?);
    try std.testing.expect(droneWith(drone, .{}, .deviation).touch_settle_semis == null);
    // The room can ask for any voice on any model.
    try std.testing.expectEqual(core.timbre.Kind.band, droneWith(drone, .{ .timbre = .band }, .learned).timbre);
    try std.testing.expectEqual(core.timbre.Kind.wide, droneWith(drone, .{ .timbre = .wide }, .deviation).timbre);
    try std.testing.expectEqual(ramped_gate_ms, ramped.gate_ms);
    // The models that read their pitch off the probe keep the voice they
    // were tuned in.
    try std.testing.expectEqual(core.timbre.Kind.band, droneWith(drone, .{}, .deviation).timbre);
    try std.testing.expectEqual(@as(f32, 12.0), droneWith(drone, .{ .touch_climb_semis = 12.0 }, .learned).touch_climb_semis.?);
    // The models that read their pitch off the probe are not ramps at all.
    try std.testing.expect(droneWith(drone, .{}, .deviation).touch_climb_semis == null);
}

test "no drone bends with the plant unless asked" {
    // The learned drone's pitch is the hold and the gust, never the reading.
    for ([_]core.touch.Model{ .deviation, .steady, .learned }) |model| {
        try std.testing.expectEqual(@as(f32, 0.0), droneWith(drone, .{}, model).wobble_semis);
    }
    // The room can still ask for the plant's bend.
    try std.testing.expectEqual(@as(f32, 0.0), droneWith(drone, .{ .wobble_semis = 0.0 }, .learned).wobble_semis);
    try std.testing.expectEqual(@as(f32, 2.5), droneWith(drone, .{ .wobble_semis = 2.5 }, .learned).wobble_semis);
}

test "the learned drone gusts and sits a little lower, and the others do neither" {
    const ramped = droneWith(drone, .{}, .learned);
    try std.testing.expectEqual(core.noise.default_gust_semis, ramped.gust_semis);
    try std.testing.expectEqual(learned_out_gain * drone_lift_gain, ramped.out_gain);
    for ([_]core.touch.Model{ .deviation, .steady }) |model| {
        const plain = droneWith(drone, .{}, model);
        try std.testing.expectEqual(@as(f32, 0.0), plain.gust_semis);
        try std.testing.expectEqual(drone_lift_gain, plain.out_gain);
    }
    try std.testing.expectEqual(@as(f32, 0.0), droneWith(drone, .{ .gust_semis = 0.0 }, .learned).gust_semis);
    try std.testing.expectEqual(@as(f32, 1.2), droneWith(drone, .{ .gust_semis = 1.2 }, .learned).gust_semis);
    // The room can set the level on any model, in dB.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), droneWith(drone, .{ .drone_gain_db = -6.0206 }, .learned).out_gain, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), droneWith(drone, .{ .drone_gain_db = 0.0 }, .deviation).out_gain, 0.0001);
}

test "under learned, plant B asks whether its probe has left the rail" {
    const learned = touchWith(touch, .{ .model = .learned }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, learned_edge_bc), learned.edge_bc);
    try std.testing.expectEqual(@as(?f32, learned_band_share_bc), learned.band_share_bc);
    try std.testing.expectEqual(@as(?f32, learned_band_release_bc), learned.band_release_bc);
    // Plant A gets its own, deeper line and shares.
    try std.testing.expectEqual(@as(?i16, learned_edge_a), learned.edge);
    try std.testing.expectEqual(learned_band_share_a, learned.band_share);
    try std.testing.expectEqual(learned_band_release_a, learned.band_release);
    // The command line still wins.
    const said = touchWith(touch, .{ .model = .learned, .edge_bc = 600, .band_share_bc = 0.25, .band_share = 0.7 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, 600), said.edge_bc);
    try std.testing.expectEqual(@as(?f32, 0.25), said.band_share_bc);
    try std.testing.expectEqual(@as(f32, 0.7), said.band_share);
    // The other models never read these.
    const plain = touchWith(touch, .{ .model = .deviation }, .{ .trigger, .trigger });
    try std.testing.expect(plain.edge_bc == null);
    try std.testing.expect(plain.edge == null);
}

test "a ramped drone does not stack the slow glide on the rise" {
    const ramped = droneWith(drone, .{}, .learned);
    try std.testing.expect(ramped.glide_s <= ramped_glide_s);

    // Asking for the ramp on another model gets the short glide too.
    const asked = droneWith(drone, .{ .touch_rise_s = 2.0 }, .deviation);
    try std.testing.expect(asked.glide_s <= ramped_glide_s);

    // Without a ramp the glide is the piece and stays as tuned.
    try std.testing.expectEqual(drone.glide_s, droneWith(drone, .{}, .steady).glide_s);
}

test "the models that can carry a pitch keep the mapping they were tuned on" {
    for ([_]core.touch.Model{ .deviation, .steady }) |model| {
        const shape = droneWith(drone, .{}, model);
        try std.testing.expect(shape.touch_rise_s == null);
        try std.testing.expectEqual(drone.touch_floor, shape.touch_floor);
        try std.testing.expectEqual(drone.span, shape.span);
    }
}

test "the room outranks the pairing, in both directions" {
    const said = droneWith(drone, .{ .touch_floor = 0.2, .touch_rise_s = 9.0 }, .learned);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), said.touch_floor, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), said.touch_rise_s.?, 0.0001);

    // And a room may ask for the ramp on a model that did not choose it.
    const asked = droneWith(drone, .{ .touch_rise_s = 2.0 }, .deviation);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), asked.touch_rise_s.?, 0.0001);
}

test "an override reaches the config and the rest of the preset stands" {
    const cfg = touchWith(touch, .{ .model = .steady, .still_range = 64 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(core.touch.Model.steady, cfg.model);
    try std.testing.expectEqual(@as(i16, 64), cfg.still_range);
    // Untouched by the override, so still the measured number.
    try std.testing.expectEqual(touch.still_release, cfg.still_release);
}

test "no overrides on two triggers is the preset exactly" {
    try std.testing.expectEqual(touch, touchWith(touch, .{}, .{ .trigger, .trigger }));
}

test "each plant is told to hold on its own" {
    const a_held = touchWith(touch, .{}, .{ .hold, .trigger });
    try std.testing.expect(a_held.hold);
    try std.testing.expect(!a_held.hold_bc);

    const both = touchWith(touch, .{}, .{ .hold, .hold });
    try std.testing.expect(both.hold);
    try std.testing.expect(both.hold_bc);

    const neither = touchWith(touch, .{}, .{ .trigger, .trigger });
    try std.testing.expect(!neither.hold);
    try std.testing.expect(!neither.hold_bc);
}

test "a plant left on trigger is given no tap window" {
    // The fault as the room met it. The preset handed plant B a tap window
    // nobody asked for, and a tap window discards a hand that rests -- which is
    // every touch a room makes. Plant B crossed its threshold twenty-four times
    // in one log of a thousand polls and sounded on none of them.
    const machine: core.touch.Machine = .init(touchWith(touch, .{}, .{ .trigger, .trigger }));
    try std.testing.expect(machine.a.window == null);
    try std.testing.expect(machine.bc.window == null);
}

test "a plant asked for a tap is given the window" {
    const machine: core.touch.Machine = .init(touchWith(touch, .{}, .{ .tap, .tap }));
    try std.testing.expect(machine.a.window != null);
    try std.testing.expect(machine.bc.window != null);
}

test "both probes need the same excursion to count as touched" {
    // Plant B asked for ten deviations against plant A's six, which made it the
    // harder plant to sound for no reason the rig ever gave. Unset, plant B
    // takes plant A's level.
    try std.testing.expect(touch.level_bc == null);
}

test "the preset carries a floor for each probe" {
    // Unset, the score was the only threshold either probe had, and on this
    // rig the score's denominator is noise about noise.
    try std.testing.expect(touch.counts != null);
    try std.testing.expect(touch.counts_bc != null);
    try std.testing.expectEqual(default_counts_bc, touch.forBc().counts.?);
    try std.testing.expectEqual(default_counts, touch.counts.?);
}

test "a room may take a tap plant's window away without a rebuild" {
    // A plant told to tap on a rig where a hand stays put still has to be
    // reachable, and `off` is the word for it.
    const off = touchWith(touch, .{ .plant_window = .{ null, .off } }, .{ .trigger, .tap });
    const machine: core.touch.Machine = .init(off);
    try std.testing.expect(machine.bc.window == null);

    const longer = touchWith(touch, .{ .plant_window = .{ null, .{ .ms = 3000.0 } } }, .{ .trigger, .tap });
    try std.testing.expectEqual(@as(f32, 3000.0), longer.window_bc.?.ms);

    // Plant A takes the same flag, where the preset gives it no window at all.
    const a_window = touchWith(touch, .{ .plant_window = .{ .{ .ms = 500.0 }, null } }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(f32, 500.0), a_window.window_ms.?);
}

test "a held plant drops its tap window, and only that plant's" {
    const b_held = touchWith(touch, .{}, .{ .trigger, .hold });
    try std.testing.expect(!b_held.hold);
    try std.testing.expect(b_held.hold_bc);

    const machine: core.touch.Machine = .init(b_held);
    try std.testing.expect(machine.bc.window == null);
}

test "each plant's band reaches its own probe" {
    // The two probes do not sit at the same place, so one band cannot serve
    // both: a hand puts one near 660 and the other near 25000.
    const cfg = touchWith(touch, .{ .plant_band = .{ .{ 600, 700 }, .{ 24000, 26000 } } }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, 600), cfg.touch_band_lo);
    try std.testing.expectEqual(@as(?i16, 24000), cfg.touch_band_lo_bc);
}

test "a room may set each probe's counts floor, or neither" {
    const preset = touchWith(touch, .{}, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, default_counts), preset.counts);
    try std.testing.expectEqual(@as(?i16, default_counts_bc), preset.counts_bc);

    const only_a = touchWith(touch, .{ .counts = 1500 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, 1500), only_a.counts);
    try std.testing.expectEqual(@as(?i16, default_counts_bc), only_a.counts_bc);
}

test "a floor of zero puts a probe back on the score alone" {
    // Zero is a setting and not a typo: it says "no floor", which `null` cannot
    // say because there it already means "keep the preset".
    const bare = touchWith(touch, .{ .counts = 0, .counts_bc = 0 }, .{ .trigger, .trigger });
    try std.testing.expect(bare.counts == null);
    try std.testing.expect(bare.counts_bc == null);
}

test "one probe's floor can be cleared without clearing the other's" {
    // They are separate thresholds about separate probes, and `forBc` falls
    // back to A's when BC has none -- so clearing A alone must not take BC's
    // floor with it.
    const cfg = touchWith(touch, .{ .counts = 0 }, .{ .trigger, .trigger });
    try std.testing.expect(cfg.counts == null);
    try std.testing.expectEqual(default_counts_bc, cfg.forBc().counts.?);
}

test "the span is the move the probe actually makes" {
    // The rig reads plant A at 0 or 1 untouched and about 25000 under a hand.
    // A span under that saturates on every touch and pins the pitch at the top
    // of the range, which is the one thing the drone must not do.
    try std.testing.expect(drone.span.? >= 20000);

    // And the quiet end has to be audible, or a light touch is a latch nobody
    // can hear: an octave clear of the idle pitch. The range is three octaves
    // now, so the old bar of three times idle was most of it.
    const just_over = core.noise.freqFromDeviation(default_counts, drone.span.?, drone.touch_floor);
    try std.testing.expect(just_over > 2.0 * core.noise.freq_min);
    try std.testing.expect(just_over < 0.5 * core.noise.freq_max);
}

test "the flag wins over the hostname, and the hostname over nothing" {
    try std.testing.expectEqual(boxes.Box.box5, chosenBox(.box5, "box2").?);
    try std.testing.expectEqual(boxes.Box.box2, chosenBox(null, "box2.local").?);
    try std.testing.expect(chosenBox(null, "somebodys-laptop") == null);
}

test "a box's numbers reach the config, and the room's beat the box's" {
    const box_only = touchWith(boxes.presetFor(.box5).touch, .{}, .{ .trigger, .trigger });
    try std.testing.expectEqual(boxes.presetFor(.box5).touch.counts, box_only.counts);

    const room_said = touchWith(boxes.presetFor(.box5).touch, .{ .counts = 1500 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, 1500), room_said.counts);
}

test "a rail-to-rail touch is answered the same in either direction" {
    // The rig's actual gesture: a probe sitting at one rail and a hand throwing
    // it to the other. Which rail is rest varies by plant and by day -- one
    // install rests near 660 and is boosted to 25905, another rests at 25905
    // and is pulled to 660 -- so the model is asked for the size of the move
    // and never for its sign. Both directions must cost the same.
    //
    // The numbers are the room's, not an implementation detail: how long after
    // the hand lands the clip starts. They are held here so a change to the
    // averaging or the debounce cannot quietly make the piece late.
    const cfg = touchWith(boxes.presetFor(.box5).touch, .{}, .{ .trigger, .trigger });
    const polls_per_s =
        @as(f32, @floatFromInt(core.sample_rate)) / @as(f32, @floatFromInt(core.sensor_frames));

    var latch_ms: [2]f32 = undefined;
    for ([_][2]i16{ .{ 660, 25905 }, .{ 25905, 660 } }, 0..) |rails, direction| {
        var machine: core.touch.Machine = .init(cfg);
        for (0..8000) |_| _ = machine.update(0, rails[0]);

        var on: usize = 0;
        while (!machine.bc.on and on < 4000) : (on += 1) _ = machine.update(0, rails[1]);
        latch_ms[direction] = @as(f32, @floatFromInt(on)) / polls_per_s * 1000.0;

        var off: usize = 0;
        while (machine.bc.on and off < 4000) : (off += 1) _ = machine.update(0, rails[0]);
        const release_ms = @as(f32, @floatFromInt(off)) / polls_per_s * 1000.0;

        // Plant B debounces for twenty milliseconds and no more: the move is a
        // thousand deviations wide, so nothing is gained by looking longer.
        try std.testing.expect(latch_ms[direction] < 40.0);
        // Letting go costs the averaging window, which is the price of a mean
        // that a spike cannot drag. A quarter second is under the fade.
        try std.testing.expect(release_ms < 300.0);

        var a_machine: core.touch.Machine = .init(cfg);
        for (0..8000) |_| _ = a_machine.update(rails[0], 0);
        var a_on: usize = 0;
        while (!a_machine.a.on and a_on < 4000) : (a_on += 1) _ = a_machine.update(rails[1], 0);
        const a_ms = @as(f32, @floatFromInt(a_on)) / polls_per_s * 1000.0;
        // Plant A holds for a hundred milliseconds before it believes a hand.
        try std.testing.expect(a_ms < 120.0);
    }

    // The sign of the move buys nothing and costs nothing.
    try std.testing.expectEqual(latch_ms[0], latch_ms[1]);
}

test "the room's share beats the box's" {
    const said = touchWith(touch, .{ .band_share = 0.52 }, .{ .trigger, .trigger });
    try std.testing.expectApproxEqAbs(@as(f32, 0.52), said.band_share, 0.0001);

    const unset = touchWith(touch, .{}, .{ .trigger, .trigger });
    try std.testing.expectApproxEqAbs(core.touch.default_band_share, unset.band_share, 0.0001);
}
