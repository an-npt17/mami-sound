//! Command line: which plants play, and what plant A sounds like.
//!
//! Parsing is pure and works on a slice of arguments, so every flag can be
//! tested without a process.

const std = @import("std");
const select = @import("select.zig");
const sensors = @import("sensors.zig");
const ads1115 = @import("ads1115.zig");

pub const Error = error{
    UnknownFlag,
    UnknownVoice,
    UnknownTouch,
    InvalidDevice,
    InvalidTrigger,
    UnknownAdcInput,
    TooManyArguments,
} || select.Error;

/// The names `--adc` accepts, in the order the ADS1115 datasheet lists them:
/// `a0` and friends read one pin against ground, `a0-a1` reads the difference
/// between two. Spelled shorter than the `Mux` tags, which carry the register
/// layout in their names and are no fun to type at a prompt.
const adc_inputs = [_]struct { name: []const u8, mux: ads1115.Mux }{
    .{ .name = "a0", .mux = .ain0_gnd },
    .{ .name = "a1", .mux = .ain1_gnd },
    .{ .name = "a2", .mux = .ain2_gnd },
    .{ .name = "a3", .mux = .ain3_gnd },
    .{ .name = "a0-a1", .mux = .ain0_ain1 },
    .{ .name = "a0-a3", .mux = .ain0_ain3 },
    .{ .name = "a1-a3", .mux = .ain1_ain3 },
    .{ .name = "a2-a3", .mux = .ain2_ain3 },
};

/// The multiplexer setting for an `--adc` name, or null if there is no such
/// input. Pure, so the table can be checked without a chip.
pub fn adcInput(name: []const u8) ?ads1115.Mux {
    for (adc_inputs) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.mux;
    }
    return null;
}

/// Threshold `--trigger` means when given no number of its own: plant A pinned
/// at the top of its range.
pub const default_trigger: f32 = sensors.volts_max;

/// What decides when a plant is awake.
pub const Touch = enum {
    /// Every plant, always. The default while the motion sensors are not wired.
    always,
    /// The scripted timeline the piece was built against.
    script,
    /// One GPIO motion sensor per plant.
    motion,
};

/// What `aplay` opens when nothing was asked for: ALSA's own default, which is
/// whatever card the machine's configuration points at.
pub const default_device = "default";

/// Long enough for the names ALSA actually prints, `plughw:CARD=Headphones`
/// included.
pub const device_max = 63;

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
    touch: Touch = .always,
    /// Volts plant A must reach before plants B and C are allowed to sound.
    /// `null` lets them sound whenever they are awake, as before.
    trigger_volts: ?f32 = null,
    /// Which ADS1115 input plant A's probe is wired to.
    adc_input: ads1115.Mux = ads1115.Config.default_mux,
    /// The device name is carried inline rather than as a slice into `args`, so
    /// `Options` outlives the arguments it was parsed from and the caller is
    /// free to drop them.
    device_buf: [device_max]u8 = undefined,
    /// Zero means nothing was asked for.
    device_len: usize = 0,

    pub fn device(self: *const Options) []const u8 {
        if (self.device_len == 0) return default_device;
        return self.device_buf[0..self.device_len];
    }
};

/// Parse arguments, program name already removed.
pub fn parse(args: []const []const u8) Error!Options {
    var opts: Options = .{};
    var plants_seen = false;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--voice=")) {
            const name = arg["--voice=".len..];
            opts.voice = std.meta.stringToEnum(Voice, name) orelse return Error.UnknownVoice;
        } else if (std.mem.startsWith(u8, arg, "--adc=")) {
            opts.adc_input = adcInput(arg["--adc=".len..]) orelse return Error.UnknownAdcInput;
        } else if (std.mem.eql(u8, arg, "--trigger")) {
            opts.trigger_volts = default_trigger;
        } else if (std.mem.startsWith(u8, arg, "--trigger=")) {
            const volts = std.fmt.parseFloat(f32, arg["--trigger=".len..]) catch
                return Error.InvalidTrigger;
            // A threshold outside the sensor's range would either never fire or
            // always fire, which is a typo rather than an intention.
            if (!(volts >= 0.0) or volts > sensors.volts_max) return Error.InvalidTrigger;
            opts.trigger_volts = volts;
        } else if (std.mem.startsWith(u8, arg, "--touch=")) {
            const name = arg["--touch=".len..];
            opts.touch = std.meta.stringToEnum(Touch, name) orelse return Error.UnknownTouch;
        } else if (std.mem.startsWith(u8, arg, "--device=")) {
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
    \\usage: mami_sound [PLANTS] [--voice=drone|flute|beep] [--touch=always|script|motion]
    \\                 [--trigger[=VOLTS]] [--adc=INPUT] [--device=NAME]
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
    \\--touch decides when a plant is awake and sounding:
    \\  always  every plant, from the first block on (default)
    \\  script  the built-in timeline: A holds, B and C tap inside it
    \\  motion  one GPIO motion sensor per plant
    \\
    \\--trigger holds plants B and C silent until plant A's ECG reaches VOLTS,
    \\so the reading on one plant is what releases the other two. Given no
    \\number it uses the top of the range, 3.3 V. Left out, B and C sound
    \\whenever they are awake. Their clips are one-shots: crossing the
    \\threshold starts one, and it plays through even if the reading falls.
    \\
    \\The run ends on its own only under --touch=script. Otherwise it plays
    \\until stopped, as the installation does; B and C are one-shots, so they
    \\sound once at the start and plant A carries the rest.
    \\
    \\--adc is the ADS1115 input plant A's probe is wired to, a0 by default:
    \\  a0 a1 a2 a3      one pin read against ground
    \\  a0-a1 a0-a3      the difference between two pins, and likewise
    \\  a1-a3 a2-a3      for the other pairs the chip can measure
    \\Only these eight exist; the chip has four pins and one multiplexer, so
    \\it measures one of them at a time. A differential input swings negative,
    \\which the engine reads as zero.
    \\
    \\--device is the ALSA device aplay opens, `default` unless given. Run
    \\`aplay -l` to see the cards; card 0 device 0 is `plughw:0,0`, and the
    \\plug prefix is what resamples when the card cannot do 44100 Hz itself.
    \\
    \\  mami_sound                     all three plants, drone voice
    \\  mami_sound 1                   plant A alone
    \\  mami_sound 12                  plants A and B blended
    \\  mami_sound 1 --voice=flute     plant A as a flute
    \\  mami_sound 1 --voice=beep      plant A as a sine, no files needed
    \\  mami_sound --device=plughw:0,0 play through card 0 whatever else is set
    \\  mami_sound --touch=motion      wake the plants from the GPIO sensors
    \\  mami_sound --trigger           B and C wait for plant A to read 3.3 V
    \\  mami_sound --trigger=2.5       and the same at a lower threshold
    \\  mami_sound --adc=a2            read the probe on AIN2 instead of AIN0
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

test "the adc input defaults to AIN0 against ground" {
    try testing.expectEqual(ads1115.Mux.ain0_gnd, (try parse(&.{})).adc_input);
}

test "every input the chip has can be asked for" {
    try testing.expectEqual(ads1115.Mux.ain2_gnd, (try parse(&.{"--adc=a2"})).adc_input);
    try testing.expectEqual(ads1115.Mux.ain0_ain1, (try parse(&.{"--adc=a0-a1"})).adc_input);
    try testing.expectEqual(ads1115.Mux.ain2_ain3, (try parse(&.{"--adc=a2-a3"})).adc_input);

    // The table covers the multiplexer exactly: eight names, eight settings.
    var seen = std.enums.EnumSet(ads1115.Mux).initEmpty();
    for (adc_inputs) |entry| seen.insert(entry.mux);
    try testing.expectEqual(std.enums.values(ads1115.Mux).len, seen.count());
}

test "rejects a pin pairing the chip cannot measure" {
    try testing.expectError(Error.UnknownAdcInput, parse(&.{"--adc=a4"}));
    // Real pins, but not a pair the multiplexer offers.
    try testing.expectError(Error.UnknownAdcInput, parse(&.{"--adc=a1-a2"}));
    try testing.expectError(Error.UnknownAdcInput, parse(&.{"--adc="}));
}

test "no trigger unless asked for" {
    try testing.expectEqual(@as(?f32, null), (try parse(&.{})).trigger_volts);
}

test "trigger takes the top of the range, or a number" {
    try testing.expectEqual(
        @as(?f32, default_trigger),
        (try parse(&.{"--trigger"})).trigger_volts,
    );
    try testing.expectEqual(@as(?f32, 2.5), (try parse(&.{"--trigger=2.5"})).trigger_volts);
    try testing.expectEqual(@as(?f32, 0.0), (try parse(&.{"--trigger=0"})).trigger_volts);
}

test "rejects a threshold the sensor could never mean" {
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger=high"}));
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger="}));
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger=-1"}));
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger=5"}));
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger=nan"}));
}

test "touch defaults to every plant awake" {
    try testing.expectEqual(Touch.always, (try parse(&.{})).touch);
}

test "every touch source can be asked for by name" {
    for (std.enums.values(Touch)) |source| {
        var buf: [32]u8 = undefined;
        const arg = try std.fmt.bufPrint(&buf, "--touch={s}", .{@tagName(source)});
        try testing.expectEqual(source, (try parse(&.{arg})).touch);
    }
    try testing.expectError(Error.UnknownTouch, parse(&.{"--touch=maybe"}));
}

test "the device defaults to ALSA's own" {
    const opts = try parse(&.{});
    try testing.expectEqualStrings(default_device, opts.device());
}

test "device survives the arguments it came from" {
    var buf: [32]u8 = undefined;
    const arg = try std.fmt.bufPrint(&buf, "--device=plughw:0,0", .{});
    const opts = try parse(&.{arg});
    @memset(&buf, 0);
    try testing.expectEqualStrings("plughw:0,0", opts.device());
}

test "rejects a device name that is empty or too long" {
    try testing.expectError(Error.InvalidDevice, parse(&.{"--device="}));
    const long = "--device=" ++ "x" ** (device_max + 1);
    try testing.expectError(Error.InvalidDevice, parse(&.{long}));
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
