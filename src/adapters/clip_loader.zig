const std = @import("std");

const core = @import("../core/root.zig");
const library = @import("library.zig");

pub const LoadedPool = struct {
    paths: []const []const u8,
    path_capacity: usize = 0,

    pub const empty: LoadedPool = .{ .paths = &.{} };

    pub fn deinit(self: *LoadedPool, gpa: std.mem.Allocator) void {
        for (self.paths) |path| gpa.free(path);
        if (self.path_capacity != 0) {
            gpa.free(@constCast(self.paths.ptr[0..self.path_capacity]));
        }
        self.* = .empty;
    }
};

fn nextCapacity(current: usize, needed: usize) usize {
    if (current >= needed) return current;
    if (current == 0) return @max(@as(usize, 4), needed);
    if (current > std.math.maxInt(usize) / 2) return needed;
    return @max(current * 2, needed);
}

fn ensurePathCapacity(
    gpa: std.mem.Allocator,
    pool: *LoadedPool,
    needed: usize,
) !void {
    if (needed <= pool.path_capacity) return;

    const capacity = nextCapacity(pool.path_capacity, needed);
    const next = try gpa.alloc([]const u8, capacity);
    @memcpy(next[0..pool.paths.len], pool.paths);
    if (pool.path_capacity != 0) {
        gpa.free(@constCast(pool.paths.ptr[0..pool.path_capacity]));
    }
    pool.paths = next[0..pool.paths.len];
    pool.path_capacity = capacity;
}

fn appendPath(
    gpa: std.mem.Allocator,
    pool: *LoadedPool,
    path: []const u8,
) !void {
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);

    const next_len = pool.paths.len + 1;
    try ensurePathCapacity(gpa, pool, next_len);
    pool.paths = pool.paths.ptr[0..next_len];
    @constCast(pool.paths)[next_len - 1] = owned;
}

/// The folders each pool is made of, relative to where the binary is run.
///
/// The recordings are two folders read as one, so a clip is drawn from both
/// without either being over-represented by having its own turn. The stem
/// pools are one folder each.
///
/// This is the only place the folder names live. Nothing in `core` knows them:
/// a pool there is a name, and turning a name into a directory is exactly the
/// kind of thing that belongs on this side of the port.
pub fn directoriesFor(source: core.source.Source) []const []const u8 {
    return switch (source) {
        // Asked for by a caller that should have checked `isDrone` first. There
        // is no folder to return and an empty list would load as a pool with no
        // clips, which is silence nobody can tell from the piece working.
        .drone => unreachable,
        .voicebox3 => &.{"Voice Box 3"},
        .voicebox5 => &.{"Voice Box 5"},
        .insect => &.{"Insect"},
        .tradvn => &.{"Trad Vn Jam"},
        .tradvn2 => &.{"Trad Vn Jam 2"},
        .bell => &.{"Bell Stems"},
        .daybird => &.{"Day bird"},
        .piano => &.{"EPiano Stems"},
    };
}

/// List every clip a source is made of, without decoding any. The stream adapter decodes one
/// selected path at a time on its worker thread.
///
/// A pool whose folder is missing or holds nothing playable is an error rather
/// than an empty list. Silence out of plant B is the one failure nobody in the
/// room can tell from the piece working, and a `--plant-b` that quietly did
/// nothing would be found out at the opening.
///
/// A source played in order is listed by its numbering rather than in whatever
/// order the disk hands back. The selector walks the pool by index and knows
/// nothing about filenames, so this is where "part one" is decided -- and a
/// folder listed by the filesystem would start the piece somewhere in its
/// middle and play it in a different wrong order on the next machine.
pub fn loadPool(
    gpa: std.mem.Allocator,
    io: std.Io,
    which: core.source.Source,
) !LoadedPool {
    var pool: LoadedPool = .empty;
    errdefer pool.deinit(gpa);

    const sequential = which.defaultOrder() == .sequential;
    for (directoriesFor(which)) |directory| {
        const paths = if (sequential)
            try library.listNatural(gpa, io, directory)
        else
            try library.list(gpa, io, directory);
        defer library.freeList(gpa, paths);

        for (paths) |path| try appendPath(gpa, &pool, path);
    }

    return pool;
}

test "every source names the one folder it is made of" {
    // One each. The pool that read two folders as one went when the interviews
    // became two boxes; a plant that wants both is two plants.
    const sources = [_]core.source.Source{
        .voicebox3, .voicebox5, .daybird, .insect, .tradvn, .tradvn2, .bell, .piano,
    };
    for (sources) |which| {
        try std.testing.expectEqual(@as(usize, 1), directoriesFor(which).len);
    }

    try std.testing.expectEqualStrings("Voice Box 3", directoriesFor(.voicebox3)[0]);
    try std.testing.expectEqualStrings("Voice Box 5", directoriesFor(.voicebox5)[0]);
    try std.testing.expectEqualStrings("Day bird", directoriesFor(.daybird)[0]);
    try std.testing.expectEqualStrings("Insect", directoriesFor(.insect)[0]);
    try std.testing.expectEqualStrings("Trad Vn Jam", directoriesFor(.tradvn)[0]);
    try std.testing.expectEqualStrings("Trad Vn Jam 2", directoriesFor(.tradvn2)[0]);
    try std.testing.expectEqualStrings("Bell Stems", directoriesFor(.bell)[0]);
    try std.testing.expectEqualStrings("EPiano Stems", directoriesFor(.piano)[0]);
}

test "the second jam loads in the order it is numbered" {
    // The selector walks this pool by index, so index 0 has to be part one and
    // index 9 part ten -- not part ten second, which is where byte order puts
    // it. This is the whole of what makes the piece play in order.
    const gpa = std.testing.allocator;
    var pool = try loadPool(gpa, std.testing.io, .tradvn2);
    defer pool.deinit(gpa);

    var previous: ?usize = null;
    for (pool.paths) |path| {
        const number = partNumber(path) orelse continue;
        if (previous) |last| {
            if (number <= last) {
                std.debug.print("part {d} came after part {d}\n", .{ number, last });
                return error.PartsOutOfOrder;
            }
        }
        previous = number;
    }
    try std.testing.expect(previous != null);
}

/// The last run of digits in a path, which is the part number for a folder
/// named the way this one is. `null` when there is none to read.
fn partNumber(path: []const u8) ?usize {
    var end = path.len;
    while (end > 0 and !std.ascii.isDigit(path[end - 1])) end -= 1;
    if (end == 0) return null;

    var start = end;
    while (start > 0 and std.ascii.isDigit(path[start - 1])) start -= 1;
    return std.fmt.parseInt(usize, path[start..end], 10) catch null;
}

test "every source loads into a pool with clips in it" {
    const gpa = std.testing.allocator;
    const sources = [_]core.source.Source{
        .voicebox3, .voicebox5, .daybird, .insect, .tradvn, .tradvn2, .bell, .piano,
    };
    for (sources) |which| {
        var pool = try loadPool(gpa, std.testing.io, which);
        defer pool.deinit(gpa);
        try std.testing.expect(pool.paths.len > 0);
    }
}

test "the new folders are named" {
    try std.testing.expectEqual(@as(usize, 1), directoriesFor(.insect).len);
    try std.testing.expectEqualStrings("Insect", directoriesFor(.insect)[0]);

    try std.testing.expectEqual(@as(usize, 1), directoriesFor(.tradvn).len);
    try std.testing.expectEqualStrings("Trad Vn Jam", directoriesFor(.tradvn)[0]);
}

test "the new folders load into non-empty pools" {
    const gpa = std.testing.allocator;
    for ([_]core.source.Source{ .insect, .tradvn }) |which| {
        var pool = try loadPool(gpa, std.testing.io, which);
        defer pool.deinit(gpa);
        try std.testing.expect(pool.paths.len > 0);
    }
}
