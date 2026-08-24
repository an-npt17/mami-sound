const std = @import("std");

pub fn toPcm(block: []const f32, out: []i16) void {
    std.debug.assert(block.len == out.len);
    for (block, out) |sample, *pcm| {
        pcm.* = @intFromFloat(std.math.clamp(sample, -1.0, 1.0) * 32767.0);
    }
}

const testing = std.testing;

test "toPcm clamps and scales a mixed block" {
    const block = [_]f32{ -2.0, -0.5, 0.0, 0.5, 2.0 };
    var out: [block.len]i16 = undefined;

    toPcm(&block, &out);

    try testing.expectEqualSlices(i16, &.{ -32767, -16383, 0, 16383, 32767 }, &out);
}
