//! Station 3: the recorded-track installation.
//!
//! A digital vibration sensor starts a two-minute piece; what a second hit does
//! depends on the mode. Audio arrives as mono 16-bit PCM at the mixer's rate -
//! WAV is parsed here, anything else (mp3 included) is converted by ffmpeg
//! before it gets this far, so this file stays a decoder-free unit that tests
//! can drive with bytes it builds itself.

const std = @import("std");

pub const DecodeError = error{
    NotRiff,
    NotWave,
    MissingFmt,
    MissingData,
    UnsupportedFormat,
    NoChannels,
    Truncated,
};

pub const Track = struct {
    /// Mono, at `sample_rate`.
    samples: []i16,
    sample_rate: u32,

    pub fn deinit(self: *Track, gpa: std.mem.Allocator) void {
        gpa.free(self.samples);
        self.samples = &.{};
    }

    pub fn durationS(self: Track) f32 {
        if (self.sample_rate == 0) return 0;
        return @as(f32, @floatFromInt(self.samples.len)) / @as(f32, @floatFromInt(self.sample_rate));
    }
};

fn readU16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// Parse a RIFF/WAVE file into mono PCM at `target_rate`.
///
/// Handles the formats a recording actually arrives in: 8-bit unsigned, 16- and
/// 24-bit signed, and 32-bit float, mono or multi-channel. Extra channels are
/// averaged down; WAVE_FORMAT_EXTENSIBLE is read as PCM of its stated width.
pub fn decodeWav(gpa: std.mem.Allocator, bytes: []const u8, target_rate: u32) ![]i16 {
    if (bytes.len < 12) return DecodeError.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return DecodeError.NotRiff;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return DecodeError.NotWave;

    var format: u16 = 0;
    var channels: u16 = 0;
    var rate: u32 = 0;
    var bits: u16 = 0;
    var data: ?[]const u8 = null;

    var off: usize = 12;
    while (off + 8 <= bytes.len) {
        const id = bytes[off .. off + 4];
        const size = readU32(bytes, off + 4);
        const body_start = off + 8;
        if (body_start > bytes.len) return DecodeError.Truncated;
        // A truncated final chunk is common in the wild; take what is there.
        const body_end = @min(bytes.len, body_start + size);
        const body = bytes[body_start..body_end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return DecodeError.Truncated;
            format = readU16(body, 0);
            channels = readU16(body, 2);
            rate = readU32(body, 4);
            bits = readU16(body, 14);
        } else if (std.mem.eql(u8, id, "data")) {
            data = body;
        }
        // Chunks are word-aligned: an odd size carries a pad byte.
        off = body_start + size + (size & 1);
    }

    if (rate == 0 or bits == 0) return DecodeError.MissingFmt;
    if (channels == 0) return DecodeError.NoChannels;
    const payload = data orelse return DecodeError.MissingData;
    // 1 = PCM, 3 = IEEE float, 0xFFFE = extensible (read as PCM of `bits`).
    if (format != 1 and format != 3 and format != 0xFFFE) return DecodeError.UnsupportedFormat;
    if (format == 3 and bits != 32) return DecodeError.UnsupportedFormat;
    if (format != 3 and bits != 8 and bits != 16 and bits != 24 and bits != 32) {
        return DecodeError.UnsupportedFormat;
    }

    const bytes_per_sample = bits / 8;
    const frame_bytes = @as(usize, bytes_per_sample) * channels;
    if (frame_bytes == 0) return DecodeError.UnsupportedFormat;
    const frames = payload.len / frame_bytes;

    const mono = try gpa.alloc(i16, frames);
    errdefer gpa.free(mono);
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        var sum: f32 = 0;
        var c: usize = 0;
        while (c < channels) : (c += 1) {
            const at = f * frame_bytes + c * bytes_per_sample;
            sum += switch (bits) {
                8 => (@as(f32, @floatFromInt(payload[at])) - 128.0) / 128.0,
                16 => @as(f32, @floatFromInt(std.mem.readInt(i16, payload[at..][0..2], .little))) / 32768.0,
                24 => blk: {
                    const v: i32 = @as(i32, payload[at]) |
                        (@as(i32, payload[at + 1]) << 8) |
                        (@as(i32, @as(i8, @bitCast(payload[at + 2]))) << 16);
                    break :blk @as(f32, @floatFromInt(v)) / 8388608.0;
                },
                32 => if (format == 3)
                    @as(f32, @bitCast(readU32(payload, at)))
                else
                    @as(f32, @floatFromInt(std.mem.readInt(i32, payload[at..][0..4], .little))) / 2147483648.0,
                else => unreachable,
            };
        }
        const avg = std.math.clamp(sum / @as(f32, @floatFromInt(channels)), -1.0, 1.0);
        mono[f] = @intFromFloat(avg * 32767.0);
    }

    if (rate == target_rate) return mono;
    defer gpa.free(mono);
    return resample(gpa, mono, rate, target_rate);
}

/// Linear resample. Good enough for playback of a fixed recording, and it keeps
/// the module dependency-free.
pub fn resample(gpa: std.mem.Allocator, input: []const i16, from_rate: u32, to_rate: u32) ![]i16 {
    if (from_rate == to_rate or input.len == 0) return gpa.dupe(i16, input);
    const ratio = @as(f64, @floatFromInt(to_rate)) / @as(f64, @floatFromInt(from_rate));
    const out_len: usize = @intFromFloat(@as(f64, @floatFromInt(input.len)) * ratio);
    const out = try gpa.alloc(i16, @max(1, out_len));
    for (out, 0..) |*s, i| {
        const src = @as(f64, @floatFromInt(i)) / ratio;
        const idx: usize = @intFromFloat(@floor(src));
        const frac = src - @floor(src);
        const a = @as(f64, @floatFromInt(input[@min(idx, input.len - 1)]));
        const b = @as(f64, @floatFromInt(input[@min(idx + 1, input.len - 1)]));
        s.* = @intFromFloat(a + (b - a) * frac);
    }
    return out;
}

pub const Mode = enum {
    /// Play to the end; edges arriving mid-playback are ignored.
    one_shot,
    /// Every edge jumps back to the beginning.
    restart,
    /// Plays while the line is HIGH, pauses where it was on the way down.
    gate,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "one-shot") or std.mem.eql(u8, s, "one_shot")) return .one_shot;
        if (std.mem.eql(u8, s, "restart")) return .restart;
        if (std.mem.eql(u8, s, "gate")) return .gate;
        return null;
    }
};

pub const Player = struct {
    track: ?Track = null,
    mode: Mode = .one_shot,
    playing: bool = false,
    pos: usize = 0,

    pub fn load(self: *Player, t: Track) void {
        self.track = t;
        self.playing = false;
        self.pos = 0;
    }

    pub fn onRise(self: *Player) void {
        if (self.track == null) return;
        switch (self.mode) {
            .one_shot => if (!self.playing) {
                self.pos = 0;
                self.playing = true;
            },
            .restart => {
                self.pos = 0;
                self.playing = true;
            },
            .gate => self.playing = true,
        }
    }

    pub fn onFall(self: *Player) void {
        if (self.mode == .gate) self.playing = false;
    }

    /// Gate mode follows the level, not just its edges: switching into gate
    /// while the line is already LOW has to stop the track, and no falling edge
    /// is coming to say so.
    pub fn setGate(self: *Player, high: bool) void {
        if (self.mode != .gate or self.track == null) return;
        self.playing = high;
    }

    pub fn stop(self: *Player) void {
        self.playing = false;
        self.pos = 0;
    }

    pub fn positionS(self: Player) f32 {
        const t = self.track orelse return 0;
        if (t.sample_rate == 0) return 0;
        return @as(f32, @floatFromInt(self.pos)) / @as(f32, @floatFromInt(t.sample_rate));
    }

    pub fn durationS(self: Player) f32 {
        const t = self.track orelse return 0;
        return t.durationS();
    }

    /// Fill one block. Reaching the end stops playback and rewinds, so the next
    /// edge starts the piece over rather than finding it parked at the end.
    pub fn render(self: *Player, gain: f32, out: []i16) void {
        @memset(out, 0);
        const t = self.track orelse return;
        if (!self.playing or t.samples.len == 0) return;
        const g = std.math.clamp(gain, 0.0, 1.0);
        var i: usize = 0;
        while (i < out.len and self.pos < t.samples.len) : (i += 1) {
            out[i] = @intFromFloat(@as(f32, @floatFromInt(t.samples[self.pos])) * g);
            self.pos += 1;
        }
        if (self.pos >= t.samples.len) {
            self.playing = false;
            self.pos = 0;
        }
    }
};

// --- tests ---------------------------------------------------------------

fn buildWav(gpa: std.mem.Allocator, rate: u32, channels: u16, bits: u16, format: u16, frames: usize) ![]u8 {
    const bytes_per_sample = bits / 8;
    const data_len = frames * bytes_per_sample * channels;
    var buf = try gpa.alloc(u8, 44 + data_len);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], @intCast(36 + data_len), .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], format, .little);
    std.mem.writeInt(u16, buf[22..24], channels, .little);
    std.mem.writeInt(u32, buf[24..28], rate, .little);
    std.mem.writeInt(u32, buf[28..32], rate * channels * bytes_per_sample, .little);
    std.mem.writeInt(u16, buf[32..34], @intCast(channels * bytes_per_sample), .little);
    std.mem.writeInt(u16, buf[34..36], bits, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], @intCast(data_len), .little);
    @memset(buf[44..], 0);
    return buf;
}

test "decodes 16-bit mono at the mixer rate" {
    const gpa = std.testing.allocator;
    var wav = try buildWav(gpa, 44100, 1, 16, 1, 100);
    defer gpa.free(wav);
    // A ramp, so a mis-parse shows up as the wrong shape rather than silence.
    for (0..100) |i| {
        std.mem.writeInt(i16, wav[44 + i * 2 ..][0..2], @intCast(i * 100), .little);
    }
    const samples = try decodeWav(gpa, wav, 44100);
    defer gpa.free(samples);
    try std.testing.expectEqual(@as(usize, 100), samples.len);
    try std.testing.expectEqual(@as(i16, 0), samples[0]);
    // The i16 -> float -> i16 round trip normalises by 32768 and scales by
    // 32767, so a sample can land one LSB low. That is the conversion, not a
    // parse error.
    try std.testing.expect(@abs(@as(i32, samples[49]) - 4900) <= 1);
}

test "downmixes stereo to mono" {
    const gpa = std.testing.allocator;
    var wav = try buildWav(gpa, 44100, 2, 16, 1, 4);
    defer gpa.free(wav);
    for (0..4) |i| {
        std.mem.writeInt(i16, wav[44 + i * 4 ..][0..2], 10000, .little); // left
        std.mem.writeInt(i16, wav[44 + i * 4 + 2 ..][0..2], 0, .little); // right
    }
    const samples = try decodeWav(gpa, wav, 44100);
    defer gpa.free(samples);
    try std.testing.expectEqual(@as(usize, 4), samples.len);
    // (10000 + 0) / 2, within the round trip through the -1..1 domain.
    try std.testing.expect(@abs(@as(i32, samples[0]) - 5000) < 3);
}

test "resamples to the mixer rate" {
    const gpa = std.testing.allocator;
    const wav = try buildWav(gpa, 22050, 1, 16, 1, 1000);
    defer gpa.free(wav);
    const samples = try decodeWav(gpa, wav, 44100);
    defer gpa.free(samples);
    try std.testing.expectEqual(@as(usize, 2000), samples.len);
}

test "decodes 8-bit and float formats" {
    const gpa = std.testing.allocator;
    var eight = try buildWav(gpa, 44100, 1, 8, 1, 4);
    defer gpa.free(eight);
    eight[44] = 255; // full positive in unsigned 8-bit
    const a = try decodeWav(gpa, eight, 44100);
    defer gpa.free(a);
    try std.testing.expect(a[0] > 32000);

    var float = try buildWav(gpa, 44100, 1, 32, 3, 4);
    defer gpa.free(float);
    std.mem.writeInt(u32, float[44..][0..4], @bitCast(@as(f32, -1.0)), .little);
    const b = try decodeWav(gpa, float, 44100);
    defer gpa.free(b);
    try std.testing.expectEqual(@as(i16, -32767), b[0]);
}

test "rejects files that are not WAV" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(DecodeError.NotRiff, decodeWav(gpa, "not a wav at all", 44100));
    try std.testing.expectError(DecodeError.Truncated, decodeWav(gpa, "RIFF", 44100));
    var wav = try buildWav(gpa, 44100, 1, 16, 1, 4);
    defer gpa.free(wav);
    @memcpy(wav[8..12], "AVI ");
    try std.testing.expectError(DecodeError.NotWave, decodeWav(gpa, wav, 44100));
}

test "rejects a compressed WAV rather than playing noise" {
    const gpa = std.testing.allocator;
    const wav = try buildWav(gpa, 44100, 1, 16, 17, 4); // 17 = IMA ADPCM
    defer gpa.free(wav);
    try std.testing.expectError(DecodeError.UnsupportedFormat, decodeWav(gpa, wav, 44100));
}

fn testTrack(gpa: std.mem.Allocator, len: usize) !Track {
    const s = try gpa.alloc(i16, len);
    for (s, 0..) |*v, i| v.* = @intCast(@mod(@as(i32, @intCast(i)), 1000) + 1);
    return .{ .samples = s, .sample_rate = 44100 };
}

test "one-shot ignores retriggers and stops at the end" {
    const gpa = std.testing.allocator;
    var t = try testTrack(gpa, 400);
    defer t.deinit(gpa);
    var p = Player{ .mode = .one_shot };
    p.load(t);

    var buf: [100]i16 = undefined;
    p.onRise();
    p.render(1.0, &buf);
    try std.testing.expect(p.playing);
    try std.testing.expectEqual(@as(usize, 100), p.pos);

    p.onRise(); // must not rewind
    p.render(1.0, &buf);
    try std.testing.expectEqual(@as(usize, 200), p.pos);

    p.render(1.0, &buf);
    p.render(1.0, &buf);
    try std.testing.expect(!p.playing);
    try std.testing.expectEqual(@as(usize, 0), p.pos);
}

test "restart rewinds on every edge" {
    const gpa = std.testing.allocator;
    var t = try testTrack(gpa, 400);
    defer t.deinit(gpa);
    var p = Player{ .mode = .restart };
    p.load(t);

    var buf: [100]i16 = undefined;
    p.onRise();
    p.render(1.0, &buf);
    try std.testing.expectEqual(@as(usize, 100), p.pos);
    p.onRise();
    try std.testing.expectEqual(@as(usize, 0), p.pos);
    try std.testing.expect(p.playing);
}

test "gate plays while high and resumes where it paused" {
    const gpa = std.testing.allocator;
    var t = try testTrack(gpa, 400);
    defer t.deinit(gpa);
    var p = Player{ .mode = .gate };
    p.load(t);

    var buf: [100]i16 = undefined;
    p.onRise();
    p.render(1.0, &buf);
    p.onFall();
    try std.testing.expect(!p.playing);
    const paused = p.pos;
    try std.testing.expectEqual(@as(usize, 100), paused);

    // Paused means silent, and the position must not creep.
    p.render(1.0, &buf);
    for (buf) |s| try std.testing.expectEqual(@as(i16, 0), s);
    try std.testing.expectEqual(paused, p.pos);

    p.onRise();
    p.render(1.0, &buf);
    try std.testing.expectEqual(@as(usize, 200), p.pos);
}

test "gate follows the level, not only its edges" {
    const gpa = std.testing.allocator;
    var t = try testTrack(gpa, 400);
    defer t.deinit(gpa);
    var p = Player{ .mode = .one_shot };
    p.load(t);
    p.onRise();
    try std.testing.expect(p.playing);

    // Switched into gate while the line is low: the track must stop even though
    // no falling edge arrives.
    p.mode = .gate;
    p.setGate(false);
    try std.testing.expect(!p.playing);
    p.setGate(true);
    try std.testing.expect(p.playing);

    // The other modes ignore the level entirely.
    p.mode = .one_shot;
    p.setGate(false);
    try std.testing.expect(p.playing);
}

test "gate on an empty player stays stopped" {
    var p = Player{ .mode = .gate };
    p.setGate(true);
    try std.testing.expect(!p.playing);
}

test "a falling edge does not pause the one-shot modes" {
    const gpa = std.testing.allocator;
    var t = try testTrack(gpa, 400);
    defer t.deinit(gpa);
    for ([_]Mode{ .one_shot, .restart }) |mode| {
        var p = Player{ .mode = mode };
        p.load(t);
        p.onRise();
        p.onFall();
        try std.testing.expect(p.playing);
    }
}

test "no track loaded renders silence and ignores edges" {
    var p = Player{ .mode = .one_shot };
    var buf: [64]i16 = undefined;
    p.onRise();
    p.render(1.0, &buf);
    try std.testing.expect(!p.playing);
    for (buf) |s| try std.testing.expectEqual(@as(i16, 0), s);
}

test "gain scales playback" {
    const gpa = std.testing.allocator;
    var t = try testTrack(gpa, 400);
    defer t.deinit(gpa);
    var p = Player{ .mode = .one_shot };
    p.load(t);
    var full: [100]i16 = undefined;
    var half: [100]i16 = undefined;
    p.onRise();
    p.render(1.0, &full);
    p.stop();
    p.onRise();
    p.render(0.5, &half);
    try std.testing.expect(@abs(@as(i32, half[50]) * 2 - @as(i32, full[50])) <= 1);
}

test "position and duration report in seconds" {
    const gpa = std.testing.allocator;
    var t = try testTrack(gpa, 44100 * 2);
    defer t.deinit(gpa);
    var p = Player{ .mode = .one_shot };
    p.load(t);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), p.durationS(), 0.001);
    p.onRise();
    var buf: [22050]i16 = undefined;
    p.render(1.0, &buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.positionS(), 0.001);
}

test "mode parses from the wire spelling" {
    try std.testing.expectEqual(Mode.one_shot, Mode.fromString("one-shot").?);
    try std.testing.expectEqual(Mode.restart, Mode.fromString("restart").?);
    try std.testing.expectEqual(Mode.gate, Mode.fromString("gate").?);
    try std.testing.expect(Mode.fromString("loop") == null);
}
