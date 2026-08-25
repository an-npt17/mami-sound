const std = @import("std");
const plant_b = @import("core/plant_b.zig");
const select = @import("core/select.zig");

pub const Error = error{
    UnknownFlag,
    InvalidDevice,
    InvalidPlantB,
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

pub const usage =
    \\usage: mami_sound [PLANTS] [--device=NAME] [--plant-b=POOL] [--test-random-probe]
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
