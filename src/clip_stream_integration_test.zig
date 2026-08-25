const std = @import("std");
const clip_stream = @import("adapters/clip_stream.zig");

test "worker streams a checked-in clip without blocking the consumer" {
    var adapter = try clip_stream.Adapter.init(
        std.testing.io,
        std.testing.allocator,
        &.{"field records/chum giuoc.mp3"},
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
