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
    .level_bc = 10.0,
    .hold_bc_ms = 20.0,
    .window_bc = .{ .ms = 1000.0 },
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

/// How big a move a touch must be on each probe, as the room asked. `null` is
/// the room not having said, which keeps the measured preset.
pub const Floors = struct {
    counts: ?i16 = null,
    counts_bc: ?i16 = null,
};

/// The preset with the room's overrides applied. Anything left unset on the
/// command line keeps the number above, which is the one that was measured.
pub fn touchWith(
    model: ?core.touch.Model,
    still_range: ?i16,
    still_release: ?i16,
    still_window_ms: ?f32,
    plant_band: [2]?[2]i16,
    /// The tap window each plant was given, where the room said. Unset leaves
    /// the preset's answer standing, which is a window on plant B and none on
    /// plant A.
    plant_window: [2]?core.touch.Window,
    /// Which plants sound while they are held. A held probe drops its tap
    /// window: the window asks whether a hand left in time, a hold asks whether
    /// it is still there, and both cannot be answered at once.
    held: [2]bool,
    /// The counts floor each probe was given, where the room said. Named rather
    /// than passed as two more `?i16` in a row: a caller that swapped them
    /// would compile, run, and be wrong in a way no test could see.
    floors: Floors,
) core.touch.Config {
    var cfg = touch;
    if (model) |chosen| cfg.model = chosen;
    // Zero is the room asking for no floor at all, which is a different thing
    // from leaving the flag off: off keeps the measured number, zero puts the
    // probe back on the score alone.
    if (floors.counts) |counts| cfg.counts = if (counts == 0) null else counts;
    if (floors.counts_bc) |counts| cfg.counts_bc = if (counts == 0) null else counts;
    cfg.hold = held[0];
    cfg.hold_bc = held[1];
    if (still_range) |counts| cfg.still_range = counts;
    if (still_release) |counts| cfg.still_release = counts;
    if (still_window_ms) |ms| cfg.still_window_ms = ms;
    if (plant_band[0]) |band| {
        cfg.touch_band_lo = band[0];
        cfg.touch_band_hi = band[1];
    }
    if (plant_band[1]) |band| {
        cfg.touch_band_lo_bc = band[0];
        cfg.touch_band_hi_bc = band[1];
    }
    // Plant A's window is a plain length, so `off` and "no window" are the
    // same thing there. Plant B's is not: `null` on BC means A's, and the room
    // saying `off` has to survive that.
    if (plant_window[0]) |chosen| cfg.window_ms = switch (chosen) {
        .off => null,
        .ms => |ms| ms,
    };
    if (plant_window[1]) |chosen| cfg.window_bc = chosen;
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
    const cfg = touchWith(.steady, 64, null, null, .{ null, null }, .{ null, null }, .{ false, false }, .{});
    try std.testing.expectEqual(core.touch.Model.steady, cfg.model);
    try std.testing.expectEqual(@as(i16, 64), cfg.still_range);
    // Untouched by the override, so still the measured number.
    try std.testing.expectEqual(touch.still_release, cfg.still_release);
    try std.testing.expectEqual(touch.level_bc, cfg.level_bc);
}

test "no overrides is the preset exactly" {
    try std.testing.expectEqual(touch, touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, false }, .{}));
}

test "each plant is told to hold on its own" {
    // Whichever plant is held, the other keeps whatever it was given. The two
    // are configured separately and must stay that way through every layer.
    const a_held = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ true, false }, .{});
    try std.testing.expect(a_held.hold);
    try std.testing.expect(!a_held.hold_bc);

    const both = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ true, true }, .{});
    try std.testing.expect(both.hold);
    try std.testing.expect(both.hold_bc);

    const neither = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, false }, .{});
    try std.testing.expect(!neither.hold);
    try std.testing.expect(!neither.hold_bc);
}

test "a room may take plant B's tap window away without a rebuild" {
    // The preset gives plant B a window for the rig it was measured on, where
    // a hand left resting was drift rather than a request. On a rig where a
    // hand stays put, that window is what makes the plant look deaf.
    const off = touchWith(null, null, null, null, .{ null, null }, .{ null, .off }, .{ false, false }, .{});
    const machine: core.touch.Machine = .init(off);
    try std.testing.expect(machine.bc.window == null);

    // And a length rather than the preset's, for a room that wants a slower
    // tap counted.
    const longer = touchWith(null, null, null, null, .{ null, null }, .{ null, .{ .ms = 3000.0 } }, .{ false, false }, .{});
    try std.testing.expectEqual(@as(f32, 3000.0), longer.window_bc.?.ms);

    // Plant A takes the same flag, where the preset gives it no window at all.
    const a_window = touchWith(null, null, null, null, .{ null, null }, .{ .{ .ms = 500.0 }, null }, .{ false, false }, .{});
    try std.testing.expectEqual(@as(f32, 500.0), a_window.window_ms.?);
}

test "a held plant drops its tap window, and only that plant's" {
    // The preset gives plant B a tap window for the rig it was measured on. A
    // plant told to sound while it is held cannot also be asked whether the
    // hand left in time, and the other plant keeps whatever it was given.
    const b_held = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, true }, .{});
    try std.testing.expect(!b_held.hold);
    try std.testing.expect(b_held.hold_bc);

    const machine: core.touch.Machine = .init(b_held);
    try std.testing.expect(machine.bc.window == null);
}

test "a room may set each probe's counts floor, or neither" {
    // Off keeps the measured number, which is the whole point of the preset.
    const preset = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, false }, .{});
    try std.testing.expectEqual(@as(?i16, default_counts), preset.counts);
    try std.testing.expectEqual(@as(?i16, default_counts_bc), preset.counts_bc);

    const asked = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, false }, .{
        .counts = 1500,
        .counts_bc = 20000,
    });
    try std.testing.expectEqual(@as(?i16, 1500), asked.counts);
    try std.testing.expectEqual(@as(?i16, 20000), asked.counts_bc);

    // One without the other.
    const only_a = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, false }, .{ .counts = 1500 });
    try std.testing.expectEqual(@as(?i16, 1500), only_a.counts);
    try std.testing.expectEqual(@as(?i16, default_counts_bc), only_a.counts_bc);
}

test "a floor of zero puts a probe back on the score alone" {
    // Zero is a setting and not a typo: it says "no floor", which `null` cannot
    // say because there it already means "keep the preset".
    const bare = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, false }, .{
        .counts = 0,
        .counts_bc = 0,
    });
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
