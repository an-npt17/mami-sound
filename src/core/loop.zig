const std = @import("std");

const voice_gain: f32 = 0.4;

pub const Player = struct {
    samples: []const f32,
    position: usize,

    pub fn init(samples: []const f32) Player {
        std.debug.assert(samples.len != 0);
        return .{ .samples = samples, .position = 0 };
    }

    pub fn render(self: *Player, out: []f32) void {
        for (out) |*sample| {
            sample.* += self.samples[self.position] * voice_gain;
            self.position += 1;
            if (self.position == self.samples.len) self.position = 0;
        }
    }
};

test "render loops samples across output blocks" {
    var player = Player.init(&.{ 0.1, 0.2, 0.3 });
    var first = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    var second = [_]f32{ 0.0, 0.0, 0.0 };

    player.render(&first);
    player.render(&second);

    const expected_first = [_]f32{ 0.04, 0.08, 0.12, 0.04 };
    const expected_second = [_]f32{ 0.08, 0.12, 0.04 };
    for (first, expected_first) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
    }
    for (second, expected_second) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
    }
}
