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
    .window_bc_ms = 1000.0,
};

/// The preset with the room's overrides applied. Anything left unset on the
/// command line keeps the number above, which is the one that was measured.
pub fn touchWith(
    model: ?core.touch.Model,
    still_range: ?i16,
    still_release: ?i16,
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
    const cfg = touchWith(.steady, 64, null, .{ false, false });
    try std.testing.expectEqual(core.touch.Model.steady, cfg.model);
    try std.testing.expectEqual(@as(i16, 64), cfg.still_range);
    // Untouched by the override, so still the measured number.
    try std.testing.expectEqual(touch.still_release, cfg.still_release);
    try std.testing.expectEqual(touch.level_bc, cfg.level_bc);
}

test "no overrides is the preset exactly" {
    try std.testing.expectEqual(touch, touchWith(null, null, null, .{ false, false }));
}

test "a held plant drops its tap window, and only that plant's" {
    // The preset gives plant B a tap window for the rig it was measured on. A
    // plant told to sound while it is held cannot also be asked whether the
    // hand left in time, and the other plant keeps whatever it was given.
    const b_held = touchWith(null, null, null, .{ false, true });
    try std.testing.expect(!b_held.hold);
    try std.testing.expect(b_held.hold_bc);

    const machine: core.touch.Machine = .init(b_held);
    try std.testing.expect(machine.bc.window == null);
}
