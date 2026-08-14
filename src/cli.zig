//! Command line: which plants play, and what plant A sounds like.
//!
//! Parsing is pure and works on a slice of arguments, so every flag can be
//! tested without a process.

const std = @import("std");
const select = @import("select.zig");

pub const Error = error{
    UnknownFlag,
    UnknownVoice,
    TooManyArguments,
} || select.Error;

/// What renders plant A.
pub const Voice = enum {
    /// Filtered noise whose pitch follows the ECG. The original installation.
    drone,
    /// Recorded flute notes, replayed at whatever pitch the ECG asks for.
    flute,
    /// A bare sine at the ECG's pitch, synthesized here. Needs no files.
    beep,
};

pub const Options = struct {
    plants: select.Selection = select.all,
    voice: Voice = .drone,
};

/// Parse arguments, program name already removed.
pub fn parse(args: []const []const u8) Error!Options {
    var opts: Options = .{};
    var plants_seen = false;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--voice=")) {
            const name = arg["--voice=".len..];
            opts.voice = std.meta.stringToEnum(Voice, name) orelse return Error.UnknownVoice;
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
    \\usage: mami_sound [PLANTS] [--voice=drone|flute|beep]
    \\
    \\PLANTS is the digits of the plants to play, in any order:
    \\  1  plant A, the sensor-driven voice
    \\  2  plant B, the interview clip
    \\  3  plant C, the waterfall clip
    \\
    \\--voice selects what plant A sounds like:
    \\  drone  filtered noise, pitch following the ECG (default)
    \\  flute  recorded flute notes, replayed at the ECG's pitch
    \\  beep   a bare synthesized sine at the ECG's pitch
    \\
    \\  mami_sound                  all three plants, drone voice
    \\  mami_sound 1                plant A alone
    \\  mami_sound 12               plants A and B blended
    \\  mami_sound 1 --voice=flute  plant A as a flute
    \\  mami_sound 1 --voice=beep   plant A as a sine, no files needed
    \\
;

const testing = std.testing;

test "no arguments gives every plant and the drone" {
    const opts = try parse(&.{});
    try testing.expectEqual(select.all, opts.plants);
    try testing.expectEqual(Voice.drone, opts.voice);
}

test "plant digits are read as before" {
    try testing.expectEqual(
        select.Selection{ true, true, false },
        (try parse(&.{"12"})).plants,
    );
}

test "voice can be chosen, in either order" {
    const a = try parse(&.{ "1", "--voice=flute" });
    try testing.expectEqual(Voice.flute, a.voice);
    try testing.expectEqual(select.Selection{ true, false, false }, a.plants);

    const b = try parse(&.{ "--voice=flute", "1" });
    try testing.expectEqual(Voice.flute, b.voice);
    try testing.expectEqual(select.Selection{ true, false, false }, b.plants);
}

test "every voice can be asked for by name" {
    for (std.enums.values(Voice)) |v| {
        var buf: [32]u8 = undefined;
        const arg = try std.fmt.bufPrint(&buf, "--voice={s}", .{@tagName(v)});
        try testing.expectEqual(v, (try parse(&.{arg})).voice);
    }
}

test "rejects a voice that does not exist" {
    try testing.expectError(Error.UnknownVoice, parse(&.{"--voice=tuba"}));
}

test "rejects unknown flags" {
    try testing.expectError(Error.UnknownFlag, parse(&.{"--loud"}));
}

test "rejects two plant selections" {
    try testing.expectError(Error.TooManyArguments, parse(&.{ "1", "2" }));
}

test "bad plant digits still fail" {
    try testing.expectError(select.Error.InvalidSelection, parse(&.{"5"}));
}
