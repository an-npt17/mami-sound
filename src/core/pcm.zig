const std = @import("std");

pub fn toPcm(block: []const f32, out: []i16) void {
    std.debug.assert(block.len == out.len);
    for (block, out) |sample, *pcm| {
        pcm.* = @intFromFloat(std.math.clamp(sample, -1.0, 1.0) * 32767.0);
    }
}
