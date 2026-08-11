const std = @import("std");

pub const magic: u32 = 0x504C4E54; // "PLNT" in ASCII
pub const frame_size: usize = 12;
pub const default_port: u16 = 9090;

pub const Frame = struct {
    seq: u32,
    /// Electromagnetic channel, full scale = 3.3 V.
    value: u16,
    /// Vibration channel, same scale. Older senders left this field zero, which
    /// reads as "not vibrating" - exactly what a one-sensor rig means.
    vib: u16,
};

/// Encodes a Frame into a buffer. The buffer must be at least `frame_size` bytes long.
pub fn encode(buf: []u8, seq: u32, value: u16, vib: u16) usize {
    std.debug.assert(buf.len >= frame_size);
    std.mem.writeInt(u32, buf[0..4], magic, .little);
    std.mem.writeInt(u32, buf[4..8], seq, .little);
    std.mem.writeInt(u16, buf[8..10], value, .little);
    std.mem.writeInt(u16, buf[10..12], vib, .little);
    return frame_size;
}

pub fn decode(buf: []const u8) ?Frame {
    if (buf.len < frame_size) return null;
    if (std.mem.readInt(u32, buf[0..4], .little) != magic) return null;
    return .{
        .seq = std.mem.readInt(u32, buf[4..8], .little),
        .value = std.mem.readInt(u16, buf[8..10], .little),
        .vib = std.mem.readInt(u16, buf[10..12], .little),
    };
}

test "encode decode round trip" {
    var buf: [frame_size]u8 = undefined;
    const n = encode(&buf, 1234, 45000, 60000);
    try std.testing.expectEqual(frame_size, n);
    const f = decode(&buf).?;
    try std.testing.expectEqual(@as(u32, 1234), f.seq);
    try std.testing.expectEqual(@as(u16, 45000), f.value);
    try std.testing.expectEqual(@as(u16, 60000), f.vib);
}

test "a frame from a one-sensor rig reads as not vibrating" {
    var buf: [frame_size]u8 = undefined;
    _ = encode(&buf, 7, 1000, 0);
    try std.testing.expectEqual(@as(u16, 0), decode(&buf).?.vib);
}

test "short buffer rejected" {
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    try std.testing.expect(decode(&buf) == null);
}

test "bad magic rejected" {
    var buf: [frame_size]u8 = undefined;
    _ = encode(&buf, 1, 2, 3);
    buf[0] = 0;
    try std.testing.expect(decode(&buf) == null);
}
