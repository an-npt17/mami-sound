pub const plant = @import("plant.zig");
pub const clips = @import("clips.zig");
pub const constants = @import("constants.zig");
pub const sample_rate = constants.sample_rate;
pub const channels = constants.channels;
pub const block_frames = constants.block_frames;
pub const sensor_frames = constants.sensor_frames;
pub const select = @import("select.zig");
pub const spread = @import("spread.zig");
pub const source = @import("source.zig");
pub const touch = @import("touch.zig");
pub const noise = @import("noise.zig");
pub const pcm = @import("pcm.zig");

test {
    _ = plant;
    _ = clips;
    _ = constants;
    _ = select;
    _ = spread;
    _ = source;
    _ = touch;
    _ = noise;
    _ = pcm;
}
