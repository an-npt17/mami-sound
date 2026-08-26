//! The lock-free handoff between the clip decoder and the audio thread.
//!
//! One writer -- the streaming worker -- and one reader, the audio thread, with
//! no lock between them: the reader must never wait on a decoder, and a decoder
//! that has fallen behind must cost silence rather than a missed block.
//!
//! Every sample carries the generation of the request that produced it, so a
//! clip replaced mid-flight is dropped on the way out instead of being chased
//! down and erased. The writer can be halfway through a push when the touch
//! that asked for it is already over.

const std = @import("std");

pub const ring_capacity = 44100;

/// How loud a clip sits under the drone. Public so a test can check rendered
/// output against a reference decode.
pub const voice_gain: f32 = 0.4;

var test_ring_storage: [8]f32 = undefined;
var test_ring_tags: [8]u64 = undefined;

pub const Ring = struct {
    samples: []f32,
    tags: []u64,
    read_index: std.atomic.Value(usize),
    write_index: std.atomic.Value(usize),

    pub fn init(gpa: std.mem.Allocator) !Ring {
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

    pub fn initForTest() Ring {
        return .{
            .samples = &test_ring_storage,
            .tags = &test_ring_tags,
            .read_index = .init(0),
            .write_index = .init(0),
        };
    }

    pub fn deinit(self: *Ring, gpa: std.mem.Allocator) void {
        if (self.samples.len == ring_capacity) {
            gpa.free(self.samples);
            gpa.free(self.tags);
        }
        self.* = undefined;
    }

    pub fn clear(self: *Ring) void {
        const write = self.write_index.load(.acquire);
        self.read_index.store(write, .release);
    }

    pub fn push(self: *Ring, input: []const f32, generation: u64) usize {
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

    pub fn pop(self: *Ring, output: []f32) usize {
        const read = self.read_index.load(.acquire);
        const write = self.write_index.load(.acquire);
        const count = @min(output.len, write - read);
        for (output[0..count], 0..) |*sample, i| {
            sample.* = self.samples[(read + i) % self.samples.len];
        }
        self.read_index.store(read + count, .release);
        return count;
    }

    pub fn mix(self: *Ring, output: []f32, generation: u64) usize {
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
