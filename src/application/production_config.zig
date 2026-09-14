const core = @import("../core/root.zig");

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
};

/// How long a tap may last and still be a tap, for whichever plant asks to be
/// one. Measured on the deviation rig, where it was plant B's whether anybody
/// wanted it or not.
pub const tap_window_ms: f32 = 1000.0;

/// The preset with the room's overrides applied. Anything left unset on the
/// command line keeps the number above, which is the one that was measured.
pub fn touchWith(
    overrides: Overrides,
    /// How each plant answers a hand. The detector is told the same thing the
    /// clips are: a hold wants a level, a tap wants a gesture, and a trigger
    /// wants the edge. Only a plant asked to be a tap is given a tap window --
    /// the window discards a hand that rests, which is the touch a room makes.
    modes: [2]core.clips.Mode,
) core.touch.Config {
    var cfg = touch;
    if (overrides.model) |chosen| cfg.model = chosen;

    cfg.hold = modes[0] == .hold;
    cfg.hold_bc = modes[1] == .hold;
    cfg.window_ms = if (modes[0] == .tap) tap_window_ms else null;
    cfg.window_bc = if (modes[1] == .tap) .{ .ms = tap_window_ms } else null;

    if (overrides.still_range) |counts| cfg.still_range = counts;
    if (overrides.still_release) |counts| cfg.still_release = counts;
    if (overrides.still_window_ms) |ms| cfg.still_window_ms = ms;
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

const std = @import("std");

test "an override reaches the config and the rest of the preset stands" {
    const cfg = touchWith(.{ .model = .steady, .still_range = 64 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(core.touch.Model.steady, cfg.model);
    try std.testing.expectEqual(@as(i16, 64), cfg.still_range);
    // Untouched by the override, so still the measured number.
    try std.testing.expectEqual(touch.still_release, cfg.still_release);
}

test "no overrides on two triggers is the preset exactly" {
    try std.testing.expectEqual(touch, touchWith(.{}, .{ .trigger, .trigger }));
}

test "each plant is told to hold on its own" {
    const a_held = touchWith(.{}, .{ .hold, .trigger });
    try std.testing.expect(a_held.hold);
    try std.testing.expect(!a_held.hold_bc);

    const both = touchWith(.{}, .{ .hold, .hold });
    try std.testing.expect(both.hold);
    try std.testing.expect(both.hold_bc);

    const neither = touchWith(.{}, .{ .trigger, .trigger });
    try std.testing.expect(!neither.hold);
    try std.testing.expect(!neither.hold_bc);
}

test "a plant left on trigger is given no tap window" {
    // The fault as the room met it. The preset handed plant B a tap window
    // nobody asked for, and a tap window discards a hand that rests -- which is
    // every touch a room makes. Plant B crossed its threshold twenty-four times
    // in one log of a thousand polls and sounded on none of them.
    const machine: core.touch.Machine = .init(touchWith(.{}, .{ .trigger, .trigger }));
    try std.testing.expect(machine.a.window == null);
    try std.testing.expect(machine.bc.window == null);
}

test "a plant asked for a tap is given the window" {
    const machine: core.touch.Machine = .init(touchWith(.{}, .{ .tap, .tap }));
    try std.testing.expect(machine.a.window != null);
    try std.testing.expect(machine.bc.window != null);
}

test "a room may take a tap plant's window away without a rebuild" {
    // A plant told to tap on a rig where a hand stays put still has to be
    // reachable, and `off` is the word for it.
    const off = touchWith(.{ .plant_window = .{ null, .off } }, .{ .trigger, .tap });
    const machine: core.touch.Machine = .init(off);
    try std.testing.expect(machine.bc.window == null);

    const longer = touchWith(.{ .plant_window = .{ null, .{ .ms = 3000.0 } } }, .{ .trigger, .tap });
    try std.testing.expectEqual(@as(f32, 3000.0), longer.window_bc.?.ms);
}

test "a held plant drops its tap window, and only that plant's" {
    const b_held = touchWith(.{}, .{ .trigger, .hold });
    try std.testing.expect(!b_held.hold);
    try std.testing.expect(b_held.hold_bc);

    const machine: core.touch.Machine = .init(b_held);
    try std.testing.expect(machine.bc.window == null);
}

test "each plant's band reaches its own probe" {
    // The two probes do not sit at the same place, so one band cannot serve
    // both: a hand puts one near 660 and the other near 25000.
    const cfg = touchWith(.{ .plant_band = .{ .{ 600, 700 }, .{ 24000, 26000 } } }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, 600), cfg.touch_band_lo);
    try std.testing.expectEqual(@as(?i16, 24000), cfg.touch_band_lo_bc);
}

test "a room may set each probe's counts floor, or neither" {
    const preset = touchWith(.{}, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, default_counts), preset.counts);
    try std.testing.expectEqual(@as(?i16, default_counts_bc), preset.counts_bc);

    const only_a = touchWith(.{ .counts = 1500 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(?i16, 1500), only_a.counts);
    try std.testing.expectEqual(@as(?i16, default_counts_bc), only_a.counts_bc);
}

test "a floor of zero puts a probe back on the score alone" {
    // Zero is a setting and not a typo: it says "no floor", which `null` cannot
    // say because there it already means "keep the preset".
    const bare = touchWith(.{ .counts = 0, .counts_bc = 0 }, .{ .trigger, .trigger });
    try std.testing.expect(bare.counts == null);
    try std.testing.expect(bare.counts_bc == null);
}

test "the span is the move the probe actually makes" {
    // The rig reads plant A at 0 or 1 untouched and about 25000 under a hand.
    // A span under that saturates on every touch and pins the pitch at the top
    // of the range, which is the one thing the drone must not do.
    try std.testing.expect(drone.span >= 20000);

    // And the quiet end has to be audible, or a light touch is a latch nobody
    // can hear.
    const just_over = core.noise.freqFromDeviation(default_counts, drone.span, drone.touch_floor);
    try std.testing.expect(just_over > 3.0 * core.noise.freq_min);
    try std.testing.expect(just_over < 0.5 * core.noise.freq_max);
}
