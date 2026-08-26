const std = @import("std");
const plant_b = @import("core/plant_b.zig");
const touch = @import("core/touch.zig");
const select = @import("core/select.zig");

pub const Error = error{
    UnknownFlag,
    InvalidDevice,
    InvalidPlantB,
    InvalidTouchModel,
    InvalidStillThreshold,
    TooManyArguments,
} || select.Error;

/// What `aplay` opens when no device was requested: ALSA's configured default.
pub const default_device = "default";

/// Long enough for the names ALSA actually prints, `plughw:CARD=Headphones`
/// included.
pub const device_max = 63;

pub const Options = struct {
    plants: select.Selection = select.all,
    device_buf: [device_max]u8 = undefined,
    device_len: usize = 0,
    /// Which recordings a touch on plant B draws from. The interviews and the
    /// field records unless the room asked for a stem pool instead.
    pool: plant_b.Pool = .recordings,
    test_random_probe: bool = false,
    /// Which question the detector asks each probe, and the two spreads the
    /// `steady` model answers it with. Unset, the compiled-in preset stands.
    ///
    /// On the command line because the thresholds are a property of the rig on
    /// the day, not of the piece: an electrode moved between one morning and
    /// the next changes them, and a rebuild to try a number is a rebuild
    /// nobody does while a room is waiting.
    model: ?touch.Model = null,
    still_range: ?i16 = null,
    still_release: ?i16 = null,

    pub fn device(self: *const Options) []const u8 {
        if (self.device_len == 0) return default_device;
        return self.device_buf[0..self.device_len];
    }
};

pub fn parse(args: []const []const u8) Error!Options {
    var opts: Options = .{};
    var plants_seen = false;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--device=")) {
            const name = arg["--device=".len..];
            if (name.len == 0 or name.len > device_max) return Error.InvalidDevice;
            @memcpy(opts.device_buf[0..name.len], name);
            opts.device_len = name.len;
        } else if (std.mem.startsWith(u8, arg, "--plant-b=")) {
            opts.pool = plant_b.Pool.parse(arg["--plant-b=".len..]) catch
                return Error.InvalidPlantB;
        } else if (std.mem.startsWith(u8, arg, "--touch-model=")) {
            const name = arg["--touch-model=".len..];
            opts.model = parseModel(name) orelse return Error.InvalidTouchModel;
        } else if (std.mem.startsWith(u8, arg, "--still-range=")) {
            opts.still_range = parseCounts(arg["--still-range=".len..]) orelse
                return Error.InvalidStillThreshold;
        } else if (std.mem.startsWith(u8, arg, "--still-release=")) {
            opts.still_release = parseCounts(arg["--still-release=".len..]) orelse
                return Error.InvalidStillThreshold;
        } else if (std.mem.eql(u8, arg, "--test-random-probe")) {
            opts.test_random_probe = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return Error.UnknownFlag;
        } else {
            if (plants_seen) return Error.TooManyArguments;
            opts.plants = try select.parse(arg);
            plants_seen = true;
        }
    }

    return opts;
}

fn parseModel(name: []const u8) ?touch.Model {
    if (std.mem.eql(u8, name, "deviation")) return .deviation;
    if (std.mem.eql(u8, name, "steady")) return .steady;
    return null;
}

/// A threshold in counts. Negative is not a range, and zero would latch on
/// nothing at all, so both are refused rather than clamped.
fn parseCounts(text: []const u8) ?i16 {
    const value = std.fmt.parseInt(i16, text, 10) catch return null;
    return if (value > 0) value else null;
}

pub const usage =
    \\usage: mami_sound [PLANTS] [--device=NAME] [--plant-b=POOL]
    \\                  [--touch-model=MODEL] [--still-range=N] [--still-release=N]
    \\                  [--test-random-probe]
    \\
    \\PLANTS may be omitted, or must be exactly one of:
    \\  1  plant A, the sensor-driven drone
    \\  2  plant B, a random clip
    \\  12 both plants
    \\
    \\Plant B draws clips from ./interview files/ and ./field records/, which
    \\form one pool. Each new touch chooses a clip from it at random.
    \\
    \\--device selects the ALSA device for aplay. It defaults to `default`.
    \\Use `aplay -l` to list cards; for example, `plughw:0,0`.
    \\
    \\--plant-b swaps that pool for a folder of tuned stems, chosen the same way:
    \\  bell   ./Bell Stems/
    \\  piano  ./EPiano Stems/
    \\Left off, plant B plays the interviews and field records as usual.
    \\Plant A's drone is generated either way and is not affected.
    \\
    \\--touch-model picks what the detector asks each probe:
    \\  deviation  how far the probe has moved from its own recent past
    \\  steady     how tightly the last second of readings clusters, at any level
    \\Use `steady` on a rig whose probes clamp to a level you cannot predict.
    \\
    \\--still-range and --still-release are that model's two thresholds, in
    \\counts: at or below the range the probe is being held, at or above the
    \\release the touch is over, and between them nothing changes. Defaults are
    \\64 and 512. Raise the range if touches are missed, lower it if the rig
    \\latches on its own. `zig build replay -- CAPTURE --sweep` picks them from
    \\a recording rather than from the room.
    \\
    \\--test-random-probe skips I2C and simulates repeatable plant touch phases.
    \\
;

test "parse accepts either stem pool" {
    try std.testing.expectEqual(plant_b.Pool.bell, (try parse(&.{"--plant-b=bell"})).pool);
    try std.testing.expectEqual(plant_b.Pool.piano, (try parse(&.{"--plant-b=piano"})).pool);
}

test "plant B plays the recordings when nothing asked otherwise" {
    try std.testing.expectEqual(plant_b.Pool.recordings, (try parse(&.{})).pool);
    try std.testing.expectEqual(plant_b.Pool.recordings, (try parse(&.{"12"})).pool);
}

test "parse rejects a pool it has no folder for" {
    try std.testing.expectError(Error.InvalidPlantB, parse(&.{"--plant-b=cello"}));
    try std.testing.expectError(Error.InvalidPlantB, parse(&.{"--plant-b="}));
}

test "the flag the pool replaced is gone rather than ignored" {
    try std.testing.expectError(Error.UnknownFlag, parse(&.{"--noise-file=/tmp/test.wav"}));
}

test "parse accepts the random probe test flag" {
    const opts = try parse(&.{"--test-random-probe"});
    try std.testing.expect(opts.test_random_probe);
}

test "the touch model can be chosen on the command line" {
    try std.testing.expectEqual(touch.Model.steady, (try parse(&.{"--touch-model=steady"})).model.?);
    try std.testing.expectEqual(
        touch.Model.deviation,
        (try parse(&.{"--touch-model=deviation"})).model.?,
    );
    try std.testing.expectError(Error.InvalidTouchModel, parse(&.{"--touch-model=stillness"}));
}

test "an unset model leaves the compiled-in preset alone" {
    const opts = try parse(&.{});
    try std.testing.expect(opts.model == null);
    try std.testing.expect(opts.still_range == null);
}

test "the still thresholds take counts, and refuse what is not one" {
    const opts = try parse(&.{ "--still-range=64", "--still-release=900" });
    try std.testing.expectEqual(@as(i16, 64), opts.still_range.?);
    try std.testing.expectEqual(@as(i16, 900), opts.still_release.?);
    // Zero would latch on a probe that never went still, and a range has no
    // sign; both are a typo rather than a setting.
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--still-range=0"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--still-range=-8"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--still-release=wide"}));
}
