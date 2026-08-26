const std = @import("std");

const core = @import("../core/root.zig");
const library = @import("library.zig");

pub const LoadedPool = struct {
    paths: []const []const u8,
    /// Which directory each path came from, by index into `directoriesFor`.
    ///
    /// The pool is flat so a clip can be drawn from both folders without either
    /// getting its own turn, and this is what is left of the fact that there
    /// were two. Plant B alternates on it: the next clip comes from whichever
    /// folder the last one did not.
    folders: []const u8 = &.{},
    path_capacity: usize = 0,

    pub const empty: LoadedPool = .{ .paths = &.{} };

    pub fn deinit(self: *LoadedPool, gpa: std.mem.Allocator) void {
        for (self.paths) |path| gpa.free(path);
        if (self.path_capacity != 0) {
            gpa.free(@constCast(self.paths.ptr[0..self.path_capacity]));
        }
        if (self.folders.len != 0) gpa.free(@constCast(self.folders));
        self.* = .empty;
    }
};

/// The most folders a pool is made of. Two, and the array below is sized for
/// twice that so adding a third is a change to `directoriesFor` alone.
const max_directories = 4;

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
    std.debug.assert(directories.len <= max_directories);

    var pool: LoadedPool = .empty;
    errdefer pool.deinit(gpa);

    // Where each directory's clips stop, so the folder each path came from can
    // be written down once the pool has stopped moving under `appendPath`.
    var ends: [max_directories]usize = undefined;

    for (directories, 0..) |directory, folder| {
        const paths = try library.list(gpa, io, directory);
        defer library.freeList(gpa, paths);

        for (paths) |path| try appendPath(gpa, &pool, path);
        ends[folder] = pool.paths.len;
    }

    const folders = try gpa.alloc(u8, pool.paths.len);
    var start: usize = 0;
    for (ends[0..directories.len], 0..) |end, folder| {
        for (folders[start..end]) |*of| of.* = @intCast(folder);
        start = end;
    }
    pool.folders = folders;

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

test "the pool remembers which folder each clip came from" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var pool = try loadPlantB(gpa, io, .recordings);
    defer pool.deinit(gpa);

    try std.testing.expectEqual(pool.paths.len, pool.folders.len);

    const directories = directoriesFor(.recordings);
    for (directories, 0..) |directory, folder| {
        const listed = try library.list(gpa, io, directory);
        defer library.freeList(gpa, listed);

        var counted: usize = 0;
        for (pool.folders) |of| {
            if (of == folder) counted += 1;
        }
        try std.testing.expectEqual(listed.len, counted);
    }

    // Both folders present, or there is nothing for plant B to alternate with.
    try std.testing.expect(pool.folders[0] != pool.folders[pool.folders.len - 1]);
}

test "a one-folder pool marks every clip as the same folder" {
    const gpa = std.testing.allocator;
    var pool = try loadPlantB(gpa, std.testing.io, .bell);
    defer pool.deinit(gpa);

    try std.testing.expect(pool.folders.len > 0);
    for (pool.folders) |folder| try std.testing.expectEqual(@as(u8, 0), folder);
}
