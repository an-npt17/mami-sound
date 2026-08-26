const std = @import("std");
const linux = std.os.linux;
const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");

const ring_capacity = 44100;
const none_index = std.math.maxInt(usize);
const voice_gain: f32 = 0.4;

var test_ring_storage: [8]f32 = undefined;
var test_ring_tags: [8]u64 = undefined;

const Ring = struct {
    samples: []f32,
    tags: []u64,
    read_index: std.atomic.Value(usize),
    write_index: std.atomic.Value(usize),

    fn init(gpa: std.mem.Allocator) !Ring {
        const samples = try gpa.alloc(f32, ring_capacity);
        errdefer gpa.free(samples);
        const tags = try gpa.alloc(u64, ring_capacity);
        return .{
            .samples = samples,
            .tags = tags,
            .read_index = .init(0),
            .write_index = .init(0),
        };
    }

    fn initForTest() Ring {
        return .{
            .samples = &test_ring_storage,
            .tags = &test_ring_tags,
            .read_index = .init(0),
            .write_index = .init(0),
        };
    }

    fn deinit(self: *Ring, gpa: std.mem.Allocator) void {
        if (self.samples.len == ring_capacity) {
            gpa.free(self.samples);
            gpa.free(self.tags);
        }
        self.* = undefined;
    }

    fn clear(self: *Ring) void {
        const write = self.write_index.load(.acquire);
        self.read_index.store(write, .release);
    }

    fn push(self: *Ring, input: []const f32, generation: u64) usize {
        const read = self.read_index.load(.acquire);
        const write = self.write_index.load(.acquire);
        const used = write - read;
        const count = @min(input.len, self.samples.len - used);
        for (input[0..count], 0..) |sample, i| {
            const index = (write + i) % self.samples.len;
            self.samples[index] = sample;
            self.tags[index] = generation;
        }
        self.write_index.store(write + count, .release);
        return count;
    }

    fn pop(self: *Ring, output: []f32) usize {
        const read = self.read_index.load(.acquire);
        const write = self.write_index.load(.acquire);
        const count = @min(output.len, write - read);
        for (output[0..count], 0..) |*sample, i| {
            sample.* = self.samples[(read + i) % self.samples.len];
        }
        self.read_index.store(read + count, .release);
        return count;
    }

    fn mix(self: *Ring, output: []f32, generation: u64) usize {
        const read = self.read_index.load(.acquire);
        const write = self.write_index.load(.acquire);
        const count = @min(output.len, write - read);
        for (output[0..count], 0..) |*sample, i| {
            const index = (read + i) % self.samples.len;
            if (self.tags[index] == generation) {
                sample.* += self.samples[index] * voice_gain;
            }
        }
        self.read_index.store(read + count, .release);
        return count;
    }
};

pub const Adapter = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    ring: Ring,
    requested_index: std.atomic.Value(usize),
    request_generation: std.atomic.Value(u64),
    /// How much of a clip one touch plays. Spent per clip: each decode takes a
    /// fresh copy, so this one is only ever the template.
    limit: core.plant_b.Limit,
    shutdown: std.atomic.Value(bool),
    child_pid: std.atomic.Value(i32),
    thread: ?std.Thread,
    started: bool,

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        paths: []const []const u8,
        limit: core.plant_b.Limit,
    ) !Adapter {
        return .{
            .io = io,
            .gpa = gpa,
            .paths = paths,
            .ring = try Ring.init(gpa),
            .limit = limit,
            .requested_index = .init(none_index),
            .request_generation = .init(0),
            .shutdown = .init(false),
            .child_pid = .init(-1),
            .thread = null,
            .started = false,
        };
    }

    pub fn start(self: *Adapter) !void {
        if (self.started) return error.AlreadyStarted;
        self.started = true;
        errdefer self.started = false;
        if (self.paths.len == 0) return;
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn port(self: *Adapter) ports.ClipStream {
        return .{
            .context = self,
            .render_fn = renderPort,
        };
    }

    pub fn deinit(self: *Adapter) void {
        self.shutdown.store(true, .release);
        const pid = self.child_pid.load(.acquire);
        if (pid >= 0) _ = linux.kill(pid, linux.SIG.KILL);
        if (self.thread) |thread| thread.join();
        self.ring.deinit(self.gpa);
        self.* = undefined;
    }

    fn renderPort(context: *anyopaque, out: []f32, request: ?usize) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.render(out, request);
    }

    fn render(self: *Adapter, out: []f32, request: ?usize) void {
        if (request) |index| {
            if (index >= self.paths.len) return;
            self.ring.clear();
            self.requested_index.store(index, .release);
            const generation = self.request_generation.load(.acquire);
            self.request_generation.store(generation + 1, .release);
        }

        const generation = self.request_generation.load(.acquire);
        _ = self.ring.mix(out, generation);
    }

    fn workerMain(self: *Adapter) void {
        var handled_generation: u64 = 0;
        while (!self.shutdown.load(.acquire)) {
            const generation = self.request_generation.load(.acquire);
            if (generation == handled_generation) {
                self.pause();
                continue;
            }
            handled_generation = generation;

            const index = self.requested_index.load(.acquire);
            if (index >= self.paths.len) continue;
            self.decodePath(self.paths[index], generation);
        }
    }

    fn decodePath(self: *Adapter, path: []const u8, generation: u64) void {
        var child = std.process.spawn(self.io, .{
            .argv = &.{
                "ffmpeg",
                "-v",
                "error",
                "-i",
                path,
                "-af",
                "alimiter=limit=0.8",
                "-f",
                "f32le",
                "-ac",
                "1",
                "-ar",
                std.fmt.comptimePrint("{d}", .{core.sample_rate}),
                "-",
            },
            .stdout = .pipe,
        }) catch |err| {
            std.debug.print("clip stream failed for {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        self.child_pid.store(@intCast(child.id.?), .release);
        var reaped = false;
        defer {
            self.child_pid.store(-1, .release);
            if (!reaped) {
                _ = linux.kill(child.id.?, linux.SIG.KILL);
                _ = child.wait(self.io) catch {};
            }
        }

        const stdout = child.stdout orelse return;
        const flags_result = linux.fcntl(stdout.handle, linux.F.GETFL, 0);
        if (linux.errno(flags_result) != .SUCCESS) {
            std.debug.print("clip stream could not configure stdout for {s}\n", .{path});
            return;
        }
        const flags = @as(usize, @intCast(flags_result));
        const set_result = linux.fcntl(
            stdout.handle,
            linux.F.SETFL,
            flags | linux.SOCK.NONBLOCK,
        );
        if (linux.errno(set_result) != .SUCCESS) {
            std.debug.print("clip stream could not enable nonblocking stdout for {s}\n", .{path});
            return;
        }
        var bytes: [16 * 1024]u8 align(@alignOf(f32)) = undefined;
        var pending: [@sizeOf(f32)]u8 = undefined;
        var pending_len: usize = 0;
        var limit = self.limit;

        while (!self.shouldStop(generation)) {
            if (pending_len != 0) @memcpy(bytes[0..pending_len], pending[0..pending_len]);
            const rc = linux.read(stdout.handle, bytes[pending_len..].ptr, bytes.len - pending_len);
            const read_errno = linux.errno(rc);
            if (read_errno == .AGAIN) {
                self.pause();
                continue;
            }
            if (read_errno != .SUCCESS) {
                std.debug.print("clip stream read failed for {s}: {s}\n", .{
                    path,
                    @tagName(read_errno),
                });
                return;
            }
            const read: usize = @intCast(rc);
            if (read == 0) {
                break;
            }

            const total = pending_len + read;
            const complete = total - total % @sizeOf(f32);
            const samples = std.mem.bytesAsSlice(f32, bytes[0..complete]);
            self.pushSamples(samples, generation, &limit);
            pending_len = total - complete;
            if (pending_len != 0) @memcpy(pending[0..pending_len], bytes[complete..total]);

            // The clip has had its four seconds. Returning here rather than
            // breaking is deliberate: the loop's exit path reaps ffmpeg, and
            // ffmpeg is still mid-file with a pipe nobody is draining, so
            // waiting on it would hang the worker forever. The deferred kill
            // is the only correct way out.
            if (limit.finished()) return;
        }

        if (self.shouldStop(generation)) return;

        const term = child.wait(self.io) catch |err| {
            std.debug.print("clip stream wait failed for {s}: {s}\n", .{
                path,
                @errorName(err),
            });
            return;
        };
        reaped = true;
        switch (term) {
            .exited => |code| if (code != 0) {
                std.debug.print("ffmpeg failed for {s} with exit code {d}\n", .{ path, code });
            },
            else => if (!self.shouldStop(generation)) {
                std.debug.print("ffmpeg stopped unexpectedly for {s}\n", .{path});
            },
        }
    }

    /// Push one run of decoded samples into the ring, shaped by what is left of
    /// the clip's allowance. Uncapped pools spend an allowance that never runs
    /// out, so there is no branch here for them.
    fn pushSamples(
        self: *Adapter,
        samples: []f32,
        generation: u64,
        limit: *core.plant_b.Limit,
    ) void {
        const kept = limit.take(samples);
        var offset: usize = 0;
        while (offset < kept and !self.shouldStop(generation)) {
            const pushed = self.ring.push(samples[offset..kept], generation);
            offset += pushed;
            if (pushed == 0) self.pause();
        }
    }

    fn pause(self: *Adapter) void {
        std.Io.sleep(self.io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
    }

    fn shouldStop(self: *Adapter, generation: u64) bool {
        return self.shutdown.load(.acquire) or
            self.request_generation.load(.acquire) != generation;
    }
};

test "ring wraps and reports underflow without blocking" {
    var ring = Ring.initForTest();
    var first = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    var output = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    try std.testing.expectEqual(@as(usize, 6), ring.push(&first, 1));
    try std.testing.expectEqual(@as(usize, 4), ring.pop(&output));
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 2.0, 3.0, 4.0 }, &output);
    @memset(&output, 0);
    try std.testing.expectEqual(@as(usize, 2), ring.pop(&output));
    try std.testing.expectEqualSlices(f32, &.{ 5.0, 6.0, 0.0, 0.0 }, &output);

    var second = [_]f32{ 7.0, 8.0, 9.0, 10.0, 11.0, 12.0 };
    try std.testing.expectEqual(@as(usize, 6), ring.push(&second, 1));
    var wrapped = [_]f32{0.0} ** 8;
    try std.testing.expectEqual(@as(usize, 6), ring.pop(&wrapped));
    try std.testing.expectEqualSlices(f32, &.{ 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 0.0, 0.0 }, &wrapped);
}

test "ring mixing preserves audio already in the engine block" {
    var ring = Ring.initForTest();
    var input = [_]f32{ 1.0, 2.0 };
    var output = [_]f32{ 10.0, 20.0, 30.0 };
    _ = ring.push(&input, 1);
    try std.testing.expectEqual(@as(usize, 2), ring.mix(&output, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 10.4), output[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.8), output[1], 0.000001);
    try std.testing.expectEqual(@as(f32, 30.0), output[2]);
}

test "adapter rejects duplicate starts" {
    var adapter = try Adapter.init(
        std.testing.io,
        std.testing.allocator,
        &.{},
        .unlimited,
    );
    defer adapter.deinit();
    try adapter.start();
    try std.testing.expectError(error.AlreadyStarted, adapter.start());
}
