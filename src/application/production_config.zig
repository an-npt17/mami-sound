const core = @import("../core/root.zig");

/// The rig in the room decides which of the two models this is.
///
/// `deviation` is right where a probe rests somewhere and a touch moves it.
/// `steady` is right where the electrode floats: the flailing has no rest to
/// measure from, so what is asked instead is whether the probe has gone still,
/// and at what level. On the floating rig `deviation` reads a MAD of about 260
/// counts on probe A, which is a threshold no touch can clear.
///
/// The floating rig's preset, kept here because the numbers are measured
/// rather than guessable — plant A's probe clamps to 650-750 and plant B's to
/// about 1:
///
///     pub const touch: core.touch.Config = .{
///         .sample_rate = core.sample_rate,
///         .poll_frames = core.sensor_frames,
///         .model = .steady,
///         .band_lo = 600,
///         .band_hi = 800,
///         .band_lo_bc = -8,
///         .band_hi_bc = 8,
///     };
///
/// `drone.touch_floor` has to move with it. In `steady` the pitch is a level
/// measured from the bottom of a band a hundred counts wide, so `span` wants
/// to be that band and the floor is what makes a touch audible at all:
///
///     pub const drone: core.noise.Shape = .{
///         .span = 200,
///         .touch_floor = 0.6,
///         .burst_s = 0.4,
///         .glide_s = 4.0,
///         .release_s = 0.5,
///     };
pub const touch: core.touch.Config = .{
    .sample_rate = core.sample_rate,
    .poll_frames = core.sensor_frames,
    .model = .steady,
    .band_lo = 600,
    .band_hi = 800,
    .band_lo_bc = -8,
    .band_hi_bc = 8,
    .level_bc = 10.0,
    .hold_bc_ms = 20.0,
    .window_bc_ms = 1000.0,
};

pub const seed: u64 = 0xC0FFEE;

pub const drone: core.noise.Shape = .{
    .span = 3000,
    .burst_s = 0.4,
    .glide_s = 4.0,
    .release_s = 0.5,
};
