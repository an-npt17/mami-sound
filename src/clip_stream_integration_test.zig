const std = @import("std");
const core = @import("core/root.zig");
const clip_heads = @import("adapters/clip_heads.zig");
const clip_stream = @import("adapters/clip_stream.zig");

test "worker streams a checked-in clip without blocking the consumer" {
    var adapter = try clip_stream.Adapter.init(
        std.testing.io,
        std.testing.allocator,
        &.{"field records/chum giuoc.mp3"},
        .unlimited,
    );
    defer adapter.deinit();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    var heard = false;
    for (0..200) |_| {
        std.Io.sleep(std.testing.io, .fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
        for (block) |sample| {
            if (sample != 0.0) heard = true;
        }
        if (heard) break;
    }
    try std.testing.expect(heard);
}

test "worker shuts down while its ring is full" {
    var adapter = try clip_stream.Adapter.init(
        std.testing.io,
        std.testing.allocator,
        &.{"field records/chum giuoc.mp3"},
        .unlimited,
    );
    defer adapter.deinit();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 1;
    port.render(&block, 0);
    std.Io.sleep(std.testing.io, .fromNanoseconds(2 * std.time.ns_per_s), .awake) catch {};
}

test "worker replaces a clip while its ring is full" {
    var adapter = try clip_stream.Adapter.init(
        std.testing.io,
        std.testing.allocator,
        &.{ "field records/chum giuoc.mp3", "field records/chum giuoc.mp3" },
        .unlimited,
    );
    defer adapter.deinit();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);
    std.Io.sleep(std.testing.io, .fromNanoseconds(2 * std.time.ns_per_s), .awake) catch {};

    port.render(&block, 1);
    var heard = false;
    for (0..200) |_| {
        std.Io.sleep(std.testing.io, .fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
        for (block) |sample| {
            if (sample != 0.0) heard = true;
        }
        if (heard) break;
    }
    try std.testing.expect(heard);
}

test "a capped touch plays its allowance and then stops on its own" {
    // A bell stem is longer than the cap, so what comes out is the cap rather
    // than the file. Nothing here asks the stream to stop: the point is that it
    // runs out by itself and waits for the next touch.
    const sample_rate = 44100;
    const limit: core.plant_b.Limit = .forPool(.bell, sample_rate);

    var adapter = try clip_stream.Adapter.init(
        std.testing.io,
        std.testing.allocator,
        &.{"Bell Stems/Bell_01.wav"},
        limit,
    );
    defer adapter.deinit();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    // Drain for longer than the clip is allowed to last, counting what arrives.
    // The ring is the only thing between the decoder and here, so every sample
    // the worker let through is counted exactly once.
    var heard: usize = 0;
    var silent_rounds: usize = 0;
    for (0..2000) |_| {
        std.Io.sleep(std.testing.io, .fromNanoseconds(2 * std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
        var any = false;
        for (block) |sample| {
            if (sample != 0.0) {
                heard += 1;
                any = true;
            }
        }
        if (heard == 0) continue;
        // Once it has gone quiet and stayed quiet, the clip is over.
        silent_rounds = if (any) 0 else silent_rounds + 1;
        if (silent_rounds > 200) break;
    }

    try std.testing.expect(heard > 0);
    // Never more than the allowance. A handful short is the fade's last samples
    // reaching exact zero and a stem's own silences, not the cap leaking.
    try std.testing.expect(heard <= limit.total);
    try std.testing.expect(heard > limit.total * 9 / 10);
}
test "a primed head sounds on the very first render after a touch" {
    var adapter = try clip_stream.Adapter.init(
        std.testing.io,
        std.testing.allocator,
        &.{"Bell Stems/Bell_01.wav"},
        .unlimited,
    );
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    // No sleep, no retry loop: the point of the head is that the clip is
    // already audible before ffmpeg has been asked for anything.
    var peak: f32 = 0.0;
    for (block) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0.001);
}

test "the stream picks the clip up exactly where the head stops" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = "Bell Stems/Bell_01.wav";

    // A hundred milliseconds past the head, which is where a seek-based seam
    // would show up as a repeat or a gap.
    const head_len: usize = @intFromFloat(clip_heads.head_s * 44100.0);
    const want = head_len + 4410;

    var reference: std.ArrayList(f32) = .empty;
    defer reference.deinit(gpa);
    try clip_heads.decodeHead(gpa, io, path, want, &reference);
    try std.testing.expectEqual(want, reference.items.len);

    var adapter = try clip_stream.Adapter.init(io, gpa, &.{path}, .unlimited);
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    var heard: std.ArrayList(f32) = .empty;
    defer heard.deinit(gpa);

    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);
    try heard.appendSlice(gpa, &block);

    // The worker is given the ring's own second to get ahead before the head
    // runs out, which is the margin the design counts on rather than a fudge
    // for the test: the head is twice as long again.
    while (heard.items.len < want) {
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
        try heard.appendSlice(gpa, &block);
    }

    for (reference.items, heard.items[0..want], 0..) |expected, actual, index| {
        std.testing.expectApproxEqAbs(
            expected * clip_stream.voice_gain,
            actual,
            1e-6,
        ) catch |err| {
            std.debug.print("sample {d} of {d} differs (head is {d})\n", .{
                index,
                want,
                head_len,
            });
            return err;
        };
    }
}
