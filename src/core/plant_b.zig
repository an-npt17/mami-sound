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
