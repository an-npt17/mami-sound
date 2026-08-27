const std = @import("std");
const core = @import("core/root.zig");
const clip_heads = @import("adapters/clip_heads.zig");
const library = @import("adapters/library.zig");
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
    const limit: core.clips.Limit = .forSource(.bell, null, .trigger, sample_rate);

    const stems = try library.listSorted(std.testing.allocator, std.testing.io, "Bell Stems");
    defer library.freeList(std.testing.allocator, stems);

    var adapter = try clip_stream.Adapter.init(
        std.testing.io,
        std.testing.allocator,
        &.{stems[0]},
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
    const stems = try library.listSorted(std.testing.allocator, std.testing.io, "Bell Stems");
    defer library.freeList(std.testing.allocator, stems);

    var adapter = try clip_stream.Adapter.init(
        std.testing.io,
        std.testing.allocator,
        &.{stems[0]},
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
    const stems = try library.listSorted(gpa, io, "Bell Stems");
    defer library.freeList(gpa, stems);
    const path = stems[0];

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

    // Let the worker spawn ffmpeg and fill the ring before any of it is drained.
    // Without this the test is racing its own decoder: a ring that runs dry
    // mixes nothing, the untouched block appends as silence, and the comparison
    // fails on a gap the room would never hear.
    std.Io.sleep(io, .fromNanoseconds(500 * std.time.ns_per_ms), .awake) catch {};

    while (heard.items.len < want) {
        std.Io.sleep(io, .fromNanoseconds(2 * std.time.ns_per_ms), .awake) catch {};
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

test "a clip reads as sounding until it has actually run out" {
    // What the ten-second guard is asked. A ring that has momentarily run dry
    // mid-clip must still read as sounding, or a touch landing in that gap
    // restarts the recording -- which is the fault the room hears as plant B
    // playing one second of something and stopping.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const limit: core.clips.Limit = .forSource(.bell, null, .trigger, 44100);

    const stems = try library.listSorted(gpa, io, "Bell Stems");
    defer library.freeList(gpa, stems);

    var adapter = try clip_stream.Adapter.init(io, gpa, &.{stems[0]}, limit);
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    try std.testing.expect(!port.sounding());

    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);
    try std.testing.expect(port.sounding());

    // Drain past the four seconds the stem is allowed. It must go quiet on its
    // own and say so.
    var drained: usize = 0;
    while (drained < 44100 * 6) : (drained += block.len) {
        @memset(&block, 0);
        port.render(&block, null);
    }
    try std.testing.expect(!port.sounding());
}

test "a stem plays between three and five seconds and then stops" {
    // The room's requirement for --plant-b=bell and --plant-b=piano: a touch is
    // answered by a note, not by a recording that outstays it.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for ([_]core.source.Source{ .bell, .piano }) |pool| {
        const directory: []const u8 = if (pool == .bell) "Bell Stems" else "EPiano Stems";
        const stems = try library.listSorted(gpa, io, directory);
        defer library.freeList(gpa, stems);

        const limit: core.clips.Limit = .forSource(pool, null, .trigger, 44100);
        var adapter = try clip_stream.Adapter.init(io, gpa, &.{stems[0]}, limit);
        defer adapter.deinit();
        try adapter.primeHeads();
        try adapter.start();

        var port = adapter.port();
        var block = [_]f32{0.0} ** 512;
        port.render(&block, 0);

        // Count what actually arrives rather than trusting the allowance: the
        // fade is applied to real samples and the cut has to land on one.
        var sounded: usize = 0;
        var drained: usize = 0;
        while (drained < 44100 * 8) : (drained += block.len) {
            @memset(&block, 0);
            port.render(&block, null);
            for (block) |sample| {
                if (sample != 0.0) sounded += 1;
            }
        }

        const seconds = @as(f32, @floatFromInt(sounded)) / 44100.0;
        try std.testing.expect(seconds >= 3.0);
        try std.testing.expect(seconds <= 5.0);
        try std.testing.expect(!port.sounding());
    }
}

test "an uncapped clip keeps sounding once the head has handed over" {
    // The head is two seconds; a recording runs for minutes. Past the seam the
    // ring is what is playing, and the guard has to keep reading it as a clip
    // in progress rather than as one that ended at the head.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var adapter = try clip_stream.Adapter.init(
        io,
        gpa,
        &.{"field records/chum giuoc.mp3"},
        .unlimited,
    );
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    // Four seconds, which is twice the head. Sounding must not drop once.
    var drained: usize = 0;
    while (drained < 44100 * 4) : (drained += block.len) {
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
        try std.testing.expect(port.sounding());
    }
}

test "a bird call plays five seconds and then stops" {
    // Plant A's pool, under `--plant-a`. The recordings in the folder run from
    // thirteen seconds to over a minute, so this is entirely down to the cap
    // holding: without it a touch would answer with the whole dawn chorus.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const calls = try library.listSorted(gpa, io, "Day bird");
    defer library.freeList(gpa, calls);
    try std.testing.expect(calls.len > 0);

    const limit: core.clips.Limit = .forSource(.daybird, null, .trigger, 44100);
    var adapter = try clip_stream.Adapter.init(io, gpa, &.{calls[0]}, limit);
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    var sounded: usize = 0;
    var drained: usize = 0;
    while (drained < 44100 * 10) : (drained += block.len) {
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
        for (block) |sample| {
            if (sample != 0.0) sounded += 1;
        }
    }

    const seconds = @as(f32, @floatFromInt(sounded)) / 44100.0;
    try std.testing.expect(seconds >= 4.0);
    try std.testing.expect(seconds <= 5.5);
    try std.testing.expect(!port.sounding());
}

test "a capped source sounds for the length it was given" {
    // insect is cut at five seconds. The folder holds recordings of up to
    // forty, so this is entirely down to the cap holding.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const paths = try library.listSorted(gpa, io, "Insect");
    defer library.freeList(gpa, paths);
    try std.testing.expect(paths.len > 0);

    const limit: core.clips.Limit = .forSource(.insect, null, .trigger, 44100);
    var adapter = try clip_stream.Adapter.init(io, gpa, &.{paths[0]}, limit);
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    var sounded: usize = 0;
    var drained: usize = 0;
    while (drained < 44100 * 10) : (drained += block.len) {
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
        for (block) |sample| {
            if (sample != 0.0) sounded += 1;
        }
    }

    const seconds = @as(f32, @floatFromInt(sounded)) / 44100.0;
    try std.testing.expect(seconds >= 4.0);
    try std.testing.expect(seconds <= 5.5);
    try std.testing.expect(!port.sounding());
}

test "a source that runs to its end is still sounding past five seconds" {
    // tradvn plays the whole jam. Its guard, not a cut, is what stops the next
    // hand restarting it, so at eight seconds it must still be playing.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const paths = try library.listSorted(gpa, io, "Trad Vn Jam");
    defer library.freeList(gpa, paths);
    try std.testing.expect(paths.len > 0);

    const limit: core.clips.Limit = .forSource(.tradvn, null, .trigger, 44100);
    try std.testing.expectEqual(core.clips.Limit.unlimited.total, limit.total);

    var adapter = try clip_stream.Adapter.init(io, gpa, &.{paths[0]}, limit);
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    std.Io.sleep(io, .fromNanoseconds(500 * std.time.ns_per_ms), .awake) catch {};

    var drained: usize = 0;
    while (drained < 44100 * 8) : (drained += block.len) {
        std.Io.sleep(io, .fromNanoseconds(2 * std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
    }
    try std.testing.expect(port.sounding());
}

test "seconds=0 plays to the end, and a later touch replaces it mid-clip" {
    // What `--plant-b-seconds=0` is for: the clip runs its own length, and the
    // only thing that ends it early is somebody asking for another one. The
    // replacement has to be audible immediately and the clip it interrupted has
    // to be gone rather than mixed underneath.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const paths = try library.listSorted(gpa, io, "Insect");
    defer library.freeList(gpa, paths);
    try std.testing.expect(paths.len >= 2);

    // insect is normally cut at five seconds; zero is how the room uncaps it.
    const limit: core.clips.Limit = .forSource(.insect, 0.0, .trigger, 44100);
    try std.testing.expectEqual(core.clips.Limit.unlimited.total, limit.total);

    var adapter = try clip_stream.Adapter.init(io, gpa, paths, limit);
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    // Well past the five seconds it would have been cut at.
    var drained: usize = 0;
    while (drained < 44100 * 7) : (drained += block.len) {
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
    }
    try std.testing.expect(port.sounding());

    // Another touch, another clip. It must be audible on the render that asks
    // for it, which is the head cache doing its job.
    @memset(&block, 0);
    port.render(&block, 1);
    var peak: f32 = 0.0;
    for (block) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0.0);
    try std.testing.expect(port.sounding());
}
