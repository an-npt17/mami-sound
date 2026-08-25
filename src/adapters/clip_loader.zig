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
pub fn directoriesFor(pool: core.plant_b.Pool) []const []const u8 {
    return switch (pool) {
        .recordings => &.{ "interview files", "field records" },
        .bell => &.{"Bell Stems"},
        .piano => &.{"EPiano Stems"},
    };
}

/// List every Plant B clip without decoding it. The stream adapter decodes one
/// selected path at a time on its worker thread.
///
/// A pool whose folder is missing or holds nothing playable is an error rather
/// than an empty list. Silence out of plant B is the one failure nobody in the
/// room can tell from the piece working, and a `--plant-b` that quietly did
/// nothing would be found out at the opening.
pub fn loadPlantB(
    gpa: std.mem.Allocator,
    io: std.Io,
    which: core.plant_b.Pool,
) !LoadedPool {
    const directories = directoriesFor(which);
    var pool: LoadedPool = .empty;
    errdefer pool.deinit(gpa);

    for (directories) |directory| {
        const paths = try library.list(gpa, io, directory);
        defer library.freeList(gpa, paths);

        for (paths) |path| try appendPath(gpa, &pool, path);
    }

    return pool;
}

test "each pool names the folders it is made of" {
    try std.testing.expectEqual(@as(usize, 2), directoriesFor(.recordings).len);
    try std.testing.expectEqualStrings("interview files", directoriesFor(.recordings)[0]);
    try std.testing.expectEqualStrings("field records", directoriesFor(.recordings)[1]);

    try std.testing.expectEqual(@as(usize, 1), directoriesFor(.bell).len);
    try std.testing.expectEqualStrings("Bell Stems", directoriesFor(.bell)[0]);

    try std.testing.expectEqual(@as(usize, 1), directoriesFor(.piano).len);
    try std.testing.expectEqualStrings("EPiano Stems", directoriesFor(.piano)[0]);
}
