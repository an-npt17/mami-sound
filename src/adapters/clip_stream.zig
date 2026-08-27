const std = @import("std");
const linux = std.os.linux;
const clip_heads = @import("clip_heads.zig");
const clip_ring = @import("clip_ring.zig");
const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");

const none_index = std.math.maxInt(usize);
/// Re-exported so callers keep reading it from the streamer they render through.
pub const voice_gain = clip_ring.voice_gain;

pub const Adapter = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    ring: clip_ring.Ring,
    requested_index: std.atomic.Value(usize),
    request_generation: std.atomic.Value(u64),
    /// How much of a clip one touch plays. Spent per clip: each decode takes a
    /// fresh copy, so this one is only ever the template.
    limit: core.clips.Limit,
    /// The opening of every clip, decoded up front. Written by `primeHeads`
    /// before the worker exists and read-only from then on, which is what lets
    /// both the audio thread and the worker hold it without a lock.
    heads: clip_heads.Heads,
    /// The head now playing and how far through it the audio thread is. Touched
    /// only from `render`.
    head: []const f32,
    head_cursor: usize,
    /// The generation the worker has finished decoding. While this trails
    /// `request_generation` a clip is still being fetched, which is what makes
    /// `sounding` exact rather than a guess from an empty ring: a worker that
    /// has fallen behind mid-clip leaves the ring empty for a moment, and a
    /// touch landing in that moment must not read as the clip having ended.
    completed_generation: std.atomic.Value(u64),
    shutdown: std.atomic.Value(bool),
    child_pid: std.atomic.Value(i32),
    thread: ?std.Thread,
    started: bool,

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        paths: []const []const u8,
        limit: core.clips.Limit,
    ) !Adapter {
        return .{
            .io = io,
            .gpa = gpa,
            .paths = paths,
            .ring = try clip_ring.Ring.init(gpa),
            .limit = limit,
            .heads = .none,
            .head = &.{},
            .head_cursor = 0,
            .requested_index = .init(none_index),
            .request_generation = .init(0),
            .completed_generation = .init(0),
            .shutdown = .init(false),
            .child_pid = .init(-1),
            .thread = null,
            .started = false,
        };
    }

    /// Decode every clip's head into RAM. Before `start`, and optional: a
    /// streamer that skips it behaves exactly as it did before heads existed,
    /// which is what the tests that do not care about startup latency rely on.
    pub fn primeHeads(self: *Adapter) !void {
        if (self.started) return error.AlreadyStarted;
        self.heads = try clip_heads.decode(
            self.gpa,
            self.io,
            self.paths,
            self.limit,
            core.sample_rate,
        );
    }

    pub fn start(self: *Adapter) !void {
        if (self.started) return error.AlreadyStarted;
        self.started = true;
        errdefer self.started = false;
        if (self.paths.len == 0) return;
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    /// How much RAM the primed heads hold, for the startup line. Worth saying
    /// out loud on a board with 512 MB of it.
    pub fn headBytes(self: *const Adapter) usize {
        return self.heads.samples.len * @sizeOf(f32);
    }

    pub fn port(self: *Adapter) ports.ClipStream {
        return .{
            .context = self,
            .render_fn = renderPort,
            .sounding_fn = soundingPort,
        };
    }

    pub fn deinit(self: *Adapter) void {
        self.shutdown.store(true, .release);
        const pid = self.child_pid.load(.acquire);
        if (pid >= 0) _ = linux.kill(pid, linux.SIG.KILL);
        if (self.thread) |thread| thread.join();
        self.heads.deinit(self.gpa);
        self.ring.deinit(self.gpa);
        self.* = undefined;
    }

    /// Whether a clip is still playing: its head not yet spent, or audio still
    /// queued, or the worker still fetching more of it.
    pub fn sounding(self: *Adapter) bool {
        if (self.head_cursor < self.head.len) return true;
        if (self.ring.pending() != 0) return true;
        return self.completed_generation.load(.acquire) !=
            self.request_generation.load(.acquire);
    }

    fn soundingPort(context: *anyopaque) bool {
        const self: *Adapter = @ptrCast(@alignCast(context));
        return self.sounding();
    }

    fn renderPort(context: *anyopaque, out: []f32, request: ?usize) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.render(out, request);
    }

    fn render(self: *Adapter, out: []f32, request: ?usize) void {
        if (request) |index| {
            if (index >= self.paths.len) return;
            self.ring.clear();
            // A clip with no head leaves this empty, which is the old
            // behaviour: nothing sounds until the worker has decoded something.
            self.head = self.heads.get(index);
            self.head_cursor = 0;
            self.requested_index.store(index, .release);
            const generation = self.request_generation.load(.acquire);
            self.request_generation.store(generation + 1, .release);
        }

        const generation = self.request_generation.load(.acquire);

        // The head is played straight from memory and the ring picks the clip
        // up exactly where the head stops -- the worker is told to throw away
        // the samples the head already holds, so the seam is a sample boundary
        // and not a seek.
        var offset: usize = 0;
        if (self.head_cursor < self.head.len) {
            const count = @min(out.len, self.head.len - self.head_cursor);
            for (out[0..count], self.head[self.head_cursor..][0..count]) |*sample, head| {
                sample.* += head * voice_gain;
            }
            self.head_cursor += count;
            offset = count;
        }

        _ = self.ring.mix(out[offset..], generation);
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
            if (index < self.paths.len) {
                self.decodePath(self.paths[index], generation, self.heads.get(index).len);
            }
            // Marked whatever happened, including a clip that failed to decode:
            // a generation nobody will ever finish would leave plant B reading
            // as sounding for the rest of the run and deaf to every touch.
            self.completed_generation.store(generation, .release);
        }
    }

    /// `skip` is how many samples of this clip the head already holds. They
    /// are decoded and thrown away rather than seeked past: `-ss` on an mp3
    /// lands on a frame boundary, not a sample, and a seam that is a few
    /// milliseconds out is a click in the middle of every clip. Decoding two
    /// seconds nobody hears costs the worker a few milliseconds, once.
    fn decodePath(self: *Adapter, path: []const u8, generation: u64, skip: usize) void {
        var limit = self.limit;
        // The allowance counts from the start of the clip, so the head's share
        // of it is already spent. A stem whose whole cap fits in the head is
        // finished before ffmpeg is asked for anything.
        limit.emitted = @min(skip, limit.total);
        if (limit.finished()) return;
        var remaining_skip = skip;

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
            var run = samples;
            if (remaining_skip != 0) {
                const dropped = @min(remaining_skip, run.len);
                remaining_skip -= dropped;
                run = run[dropped..];
            }
            if (run.len != 0) self.pushSamples(run, generation, &limit);
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
        limit: *core.clips.Limit,
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
