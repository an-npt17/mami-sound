const std = @import("std");
const select = @import("core/select.zig");

pub const Error = error{
    UnknownFlag,
    InvalidDevice,
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
    \\usage: mami_sound [PLANTS] [--device=NAME]
    \\
    \\PLANTS may be omitted, or must be exactly one of:
    \\  1  plant A, the sensor-driven drone
    \\  2  plant B, a random interview clip
    \\  12 both plants
    \\
    \\Plant B loads clips from ./interview files/ and ./field records/.
    \\The two folders form one pool, and each new touch chooses a clip.
    \\
    \\--device selects the ALSA device for aplay. It defaults to `default`.
    \\Use `aplay -l` to list cards; for example, `plughw:0,0`.
    \\
;
