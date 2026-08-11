// plant-sensor shared library. Re-exports submodules; grows with each task.

pub const sensor = @import("sensor.zig");
pub const synth = @import("synth.zig");
pub const net = @import("net.zig");
pub const voices = @import("voices.zig");
pub const track = @import("track.zig");
