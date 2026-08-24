pub const plant = @import("plant.zig");
pub const plant_b = @import("plant_b.zig");
pub const constants = @import("constants.zig");
pub const sample_rate = constants.sample_rate;
pub const channels = constants.channels;
pub const block_frames = constants.block_frames;
pub const sensor_frames = constants.sensor_frames;
pub const select = @import("select.zig");
pub const touch = @import("touch.zig");
pub const noise = @import("noise.zig");

test {
    _ = plant;
    _ = plant_b;
    _ = constants;
    _ = select;
    _ = touch;
    _ = noise;
}
