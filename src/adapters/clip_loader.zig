const std = @import("std");

const decode = @import("decode.zig");
const library = @import("library.zig");

const testing = std.testing;

pub const LoadedPool = struct {
    clips: []const []const f32,
    names: [][]u8,

    pub const empty: LoadedPool = .{ .clips = &.{}, .names = &.{} };

    pub fn deinit(self: *LoadedPool, gpa: std.mem.Allocator) void {
        for (self.clips) |clip| gpa.free(clip);
        for (self.names) |name| gpa.free(name);
        if (self.clips.len != 0) gpa.free(@constCast(self.clips));
        if (self.names.len != 0) gpa.free(self.names);
        self.* = .empty;
    }
};

/// Append one decoded clip and its display name, transferring both allocations
/// to `pool`. The input allocations are released if the outer arrays grow fails.
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
    const next_clips = try gpa.alloc([]const f32, next_len);
    errdefer gpa.free(next_clips);
    @memcpy(next_clips[0..pool.clips.len], pool.clips);
    next_clips[next_len - 1] = clip;

    const next_names = try gpa.alloc([]u8, next_len);
    errdefer gpa.free(next_names);
    @memcpy(next_names[0..pool.names.len], pool.names);
    next_names[next_len - 1] = name;

    if (pool.clips.len != 0) gpa.free(@constCast(pool.clips));
    if (pool.names.len != 0) gpa.free(pool.names);
    pool.clips = next_clips;
    pool.names = next_names;
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

test "appendLoaded preserves source order and deinit releases owned clips" {
    var pool: LoadedPool = .empty;
    defer pool.deinit(testing.allocator);

    const interview_clip = try testing.allocator.dupe(f32, &[_]f32{ 0.1, 0.2 });
    const interview_name = try testing.allocator.dupe(u8, "interview files/first.mp3");
    try appendLoaded(testing.allocator, &pool, interview_clip, interview_name);

    const field_clip = try testing.allocator.dupe(f32, &[_]f32{ -0.3, 0.4, -0.5 });
    const field_name = try testing.allocator.dupe(u8, "field records/second.mp3");
    try appendLoaded(testing.allocator, &pool, field_clip, field_name);

    try testing.expectEqual(@as(usize, 2), pool.clips.len);
    try testing.expectEqual(@as(usize, 2), pool.names.len);
    try testing.expectEqualSlices(f32, &.{ 0.1, 0.2 }, pool.clips[0]);
    try testing.expectEqualSlices(f32, &.{ -0.3, 0.4, -0.5 }, pool.clips[1]);
    try testing.expectEqualStrings("interview files/first.mp3", pool.names[0]);
    try testing.expectEqualStrings("field records/second.mp3", pool.names[1]);
}
