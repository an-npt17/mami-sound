const core = @import("../core/root.zig");

pub const touch: core.touch.Config = .{
    .sample_rate = core.sample_rate,
    .poll_frames = core.sensor_frames,
    .model = .deviation,
    .level_bc = 20.0,
    .hold_bc_ms = 30.0,
    .window_bc_ms = 1000.0,
};

pub const seed: u64 = 0xC0FFEE;

pub const drone: core.noise.Shape = .{
    .span = 3000,
    .jump = 0.15,
    .glide_s = 4.0,
    .release_s = 0.5,
};
