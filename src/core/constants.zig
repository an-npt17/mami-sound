const std = @import("std");

pub const sample_rate: u32 = 44100;
pub const channels: u32 = 1;
pub const block_frames: usize = 512;
pub const sensor_frames: usize = 128;

comptime {
    std.debug.assert(block_frames % sensor_frames == 0);
}
