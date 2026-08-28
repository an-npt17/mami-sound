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
) core.touch.Config {
    var cfg = touch;
    if (model) |chosen| cfg.model = chosen;
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

pub const drone: core.noise.Shape = .{
    .span = 3000,
    .burst_s = 0.4,
    .glide_s = 4.0,
    .release_s = 0.5,
};

const std = @import("std");

test "an override reaches the config and the rest of the preset stands" {
    const cfg = touchWith(.steady, 64, null, null, .{ null, null }, .{ null, null }, .{ false, false });
    try std.testing.expectEqual(core.touch.Model.steady, cfg.model);
    try std.testing.expectEqual(@as(i16, 64), cfg.still_range);
    // Untouched by the override, so still the measured number.
    try std.testing.expectEqual(touch.still_release, cfg.still_release);
    try std.testing.expectEqual(touch.level_bc, cfg.level_bc);
}

test "no overrides is the preset exactly" {
    try std.testing.expectEqual(touch, touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, false }));
}

test "each plant is told to hold on its own" {
    // Whichever plant is held, the other keeps whatever it was given. The two
    // are configured separately and must stay that way through every layer.
    const a_held = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ true, false });
    try std.testing.expect(a_held.hold);
    try std.testing.expect(!a_held.hold_bc);

    const both = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ true, true });
    try std.testing.expect(both.hold);
    try std.testing.expect(both.hold_bc);

    const neither = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, false });
    try std.testing.expect(!neither.hold);
    try std.testing.expect(!neither.hold_bc);
}

test "a room may take plant B's tap window away without a rebuild" {
    // The preset gives plant B a window for the rig it was measured on, where
    // a hand left resting was drift rather than a request. On a rig where a
    // hand stays put, that window is what makes the plant look deaf.
    const off = touchWith(null, null, null, null, .{ null, null }, .{ null, .off }, .{ false, false });
    const machine: core.touch.Machine = .init(off);
    try std.testing.expect(machine.bc.window == null);

    // And a length rather than the preset's, for a room that wants a slower
    // tap counted.
    const longer = touchWith(null, null, null, null, .{ null, null }, .{ null, .{ .ms = 3000.0 } }, .{ false, false });
    try std.testing.expectEqual(@as(f32, 3000.0), longer.window_bc.?.ms);

    // Plant A takes the same flag, where the preset gives it no window at all.
    const a_window = touchWith(null, null, null, null, .{ null, null }, .{ .{ .ms = 500.0 }, null }, .{ false, false });
    try std.testing.expectEqual(@as(f32, 500.0), a_window.window_ms.?);
}

test "a held plant drops its tap window, and only that plant's" {
    // The preset gives plant B a tap window for the rig it was measured on. A
    // plant told to sound while it is held cannot also be asked whether the
    // hand left in time, and the other plant keeps whatever it was given.
    const b_held = touchWith(null, null, null, null, .{ null, null }, .{ null, null }, .{ false, true });
    try std.testing.expect(!b_held.hold);
    try std.testing.expect(b_held.hold_bc);

    const machine: core.touch.Machine = .init(b_held);
    try std.testing.expect(machine.bc.window == null);
}
