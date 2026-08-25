const std = @import("std");
const testing = std.testing;

const voice_gain: f32 = 0.4;

pub const ClipPlayer = struct {
    pool: []const []const f32,
    random: std.Random,
    current: ?usize,
    position_index: usize,
    previous_touch: bool,

    pub fn init(pool: []const []const f32, random: std.Random) ClipPlayer {
        return .{
            .pool = pool,
            .random = random,
            .current = null,
            .position_index = 0,
            .previous_touch = false,
        };
    }

    pub fn isPlaying(self: ClipPlayer) bool {
        return self.current != null;
    }

    pub fn playingIndex(self: ClipPlayer) ?usize {
        return self.current;
    }

    pub fn position(self: ClipPlayer) usize {
        return self.position_index;
    }

    pub fn render(self: *ClipPlayer, out: []f32, touched: bool) void {
        const rising = touched and !self.previous_touch;
        self.previous_touch = touched;
        if (rising and self.pool.len != 0) {
            self.current = self.random.uintLessThan(usize, self.pool.len);
            self.position_index = 0;
        }

        for (out) |*sample| {
            const index = self.current orelse break;
            if (self.position_index >= self.pool[index].len) {
                self.current = null;
                break;
            }
            sample.* += self.pool[index][self.position_index] * voice_gain;
            self.position_index += 1;
        }
    }
};

test "a new touch starts one random clip" {
    const clips = [_][]const f32{ &.{ 1.0, 1.0, 1.0 }, &.{ 2.0, 2.0, 2.0 } };
    var prng = std.Random.DefaultPrng.init(1);
    var player = ClipPlayer.init(&clips, prng.random());
    var out: [1]f32 = .{0};

    player.render(&out, true);
    try testing.expect(player.isPlaying());
    try testing.expect(player.playingIndex() != null);
}

test "a new touch hard-switches the current clip" {
    const clips = [_][]const f32{
        &.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 },
        &.{ 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0 },
    };
    var prng = std.Random.DefaultPrng.init(3);
    var player = ClipPlayer.init(&clips, prng.random());
    var out: [2]f32 = .{ 0, 0 };

    player.render(&out, true);
    const first_index = player.playingIndex().?;
    try testing.expectEqual(@as(usize, 2), player.position());

    @memset(&out, 0);
    player.render(&out, false);
    try testing.expect(player.isPlaying());
    try testing.expectEqual(first_index, player.playingIndex().?);
    try testing.expectEqual(@as(usize, 4), player.position());
    const mid_clip_sample = out[0];

    @memset(&out, 0);
    player.render(&out, true);
    const second_index = player.playingIndex().?;
    try testing.expectEqual(@as(usize, 2), player.position());
    try testing.expectEqual(clips[second_index][0] * voice_gain, out[0]);
    try testing.expect(mid_clip_sample != out[0]);
}

test "a held touch does not retrigger every poll" {
    const clips = [_][]const f32{&.{ 1.0, 1.0 }};
    var prng = std.Random.DefaultPrng.init(5);
    var player = ClipPlayer.init(&clips, prng.random());
    var out: [1]f32 = .{0};

    player.render(&out, true);
    player.render(&out, true);
    try testing.expectEqual(@as(usize, 2), player.position());
}
