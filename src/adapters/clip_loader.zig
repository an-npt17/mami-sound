const std = @import("std");

const decode = @import("decode.zig");
const library = @import("library.zig");

pub const LoadedPool = struct {
    clips: []const []const f32,
    names: [][]u8,
    clip_capacity: usize = 0,
    name_capacity: usize = 0,

    pub const empty: LoadedPool = .{ .clips = &.{}, .names = &.{} };

    pub fn deinit(self: *LoadedPool, gpa: std.mem.Allocator) void {
        for (self.clips) |clip| gpa.free(clip);
        for (self.names) |name| gpa.free(name);
        if (self.clip_capacity != 0) {
            gpa.free(@constCast(self.clips.ptr[0..self.clip_capacity]));
        }
        if (self.name_capacity != 0) {
            gpa.free(self.names.ptr[0..self.name_capacity]);
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

fn ensureClipCapacity(
    gpa: std.mem.Allocator,
    pool: *LoadedPool,
    needed: usize,
) !void {
    if (needed <= pool.clip_capacity) return;

    const capacity = nextCapacity(pool.clip_capacity, needed);
    const next = try gpa.alloc([]const f32, capacity);
    @memcpy(next[0..pool.clips.len], pool.clips);
    if (pool.clip_capacity != 0) {
        gpa.free(@constCast(pool.clips.ptr[0..pool.clip_capacity]));
    }
    pool.clips = next[0..pool.clips.len];
    pool.clip_capacity = capacity;
}

fn ensureNameCapacity(
    gpa: std.mem.Allocator,
    pool: *LoadedPool,
    needed: usize,
) !void {
    if (needed <= pool.name_capacity) return;

    const capacity = nextCapacity(pool.name_capacity, needed);
    const next = try gpa.alloc([]u8, capacity);
    @memcpy(next[0..pool.names.len], pool.names);
    if (pool.name_capacity != 0) {
        gpa.free(pool.names.ptr[0..pool.name_capacity]);
    }
    pool.names = next[0..pool.names.len];
    pool.name_capacity = capacity;
}

/// Append one decoded clip and its display name, transferring both allocations
/// to `pool`. The outer arrays grow geometrically instead of per clip.
pub fn appendLoaded(
    gpa: std.mem.Allocator,
    pool: *LoadedPool,
    clip: []const f32,
    name: []u8,
) !void {
    errdefer {
        gpa.free(clip);
        gpa.free(name);
    }

    const next_len = pool.clips.len + 1;
    try ensureClipCapacity(gpa, pool, next_len);
    try ensureNameCapacity(gpa, pool, next_len);
    pool.clips = pool.clips.ptr[0..next_len];
    @constCast(pool.clips)[next_len - 1] = clip;
    pool.names = pool.names.ptr[0..next_len];
    pool.names[next_len - 1] = name;
}

/// Decode every Plant B clip in a fixed folder order. Names are retained for
/// diagnostics when a clip starts, while the returned pool owns all allocations.
pub fn loadPlantB(
    gpa: std.mem.Allocator,
    io: std.Io,
    sample_rate: u32,
) !LoadedPool {
    const directories = [_][]const u8{ "interview files", "field records" };
    var pool: LoadedPool = .empty;
    errdefer pool.deinit(gpa);

    for (directories) |directory| {
        const paths = try library.list(gpa, io, directory);
        defer library.freeList(gpa, paths);

        for (paths) |path| {
            const clip = try decode.loadFile(gpa, io, path, sample_rate);
            const name = gpa.dupe(u8, path) catch |err| {
                gpa.free(clip);
                return err;
            };
            try appendLoaded(gpa, &pool, clip, name);
        }
    }

    return pool;
}
