const std = @import("std");

pub const Error = error{UnknownPool};

/// Which pool of recordings a touch on plant B draws from.
///
/// The piece's own voice is the interviews and the field records, and that is
/// what runs when nobody has asked for anything else. The two stem pools are
/// for the room rather than the work: a set of short tuned notes that makes
/// what the plant is doing legible in a space where a spoken clip is not, and
/// makes the rig demonstrable without playing somebody's interview to a
/// corridor.
///
/// A pool is named, not pointed at. The folders are fixed and live beside the
/// binary, so a path on the command line would only be a way of typing one of
/// three answers wrong.
pub const Pool = enum {
    /// `interview files/` and `field records/` together, as one pool.
    recordings,
    bell,
    piano,

    pub fn parse(name: []const u8) Error!Pool {
        if (std.mem.eql(u8, name, "bell")) return .bell;
        if (std.mem.eql(u8, name, "piano")) return .piano;
        return Error.UnknownPool;
    }
};

pub const ClipSelector = struct {
    path_count: usize,
    random: std.Random,
    previous_touch: bool,

    pub fn init(path_count: usize, random: std.Random) ClipSelector {
        return .{
            .path_count = path_count,
            .random = random,
            .previous_touch = false,
        };
    }

    pub fn start(self: *ClipSelector, touched: bool) ?usize {
        const rising = touched and !self.previous_touch;
        self.previous_touch = touched;
        if (!rising or self.path_count == 0) return null;
        return self.random.uintLessThan(usize, self.path_count);
    }
};

test "selector emits one path request per touch edge" {
    var prng = std.Random.DefaultPrng.init(1);
    var selector = ClipSelector.init(2, prng.random());
    try std.testing.expect(selector.start(false) == null);
    try std.testing.expect(selector.start(true) != null);
    try std.testing.expect(selector.start(true) == null);
    try std.testing.expect(selector.start(false) == null);
    try std.testing.expect(selector.start(true) != null);
}

test "the named pools are the two the command line offers" {
    try std.testing.expectEqual(Pool.bell, try Pool.parse("bell"));
    try std.testing.expectEqual(Pool.piano, try Pool.parse("piano"));
    try std.testing.expectError(Error.UnknownPool, Pool.parse("Bell"));
    try std.testing.expectError(Error.UnknownPool, Pool.parse(""));
    // The recordings are what runs unasked, so there is no word for them.
    try std.testing.expectError(Error.UnknownPool, Pool.parse("recordings"));
}
