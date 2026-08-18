//! Command line: which plants play, and what plant A sounds like.
//!
//! Parsing is pure and works on a slice of arguments, so every flag can be
//! tested without a process.

const std = @import("std");
const select = @import("select.zig");
const sensors = @import("sensors.zig");
const trigger = @import("trigger.zig");

pub const Error = error{
    UnknownFlag,
    UnknownVoice,
    UnknownTouch,
    InvalidDevice,
    InvalidTrigger,
    InvalidTriggerHold,
    InvalidTriggerAverage,
    InvalidInterrupt,
    TooManyArguments,
} || select.Error;

/// Threshold `--trigger` means when given no number of its own: the AIN1 probe
/// pinned at the top of its range.
pub const default_trigger: i16 = sensors.ecg_max;

/// How long a clip plays before a touch is allowed to cut it short. Long
/// enough that a visitor hears what they started, short enough that they are
/// not held there by a recording they have finished with.
pub const default_interrupt_s: f32 = 10.0;

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
    /// The reading the AIN1 probe must reach before plants B and C are allowed
    /// to sound. `null` lets them sound whenever they are awake, as before.
    trigger_level: ?i16 = null,
    /// How long the reading has to stay over the threshold before it counts as
    /// a touch, in milliseconds. Guards against a single noisy sample starting
    /// a clip that runs for minutes.
    trigger_hold_ms: f32 = trigger.default_hold_ms,
    /// How long the reading is averaged over before the threshold sees it.
    /// What turns a probe swinging about ground into a level.
    trigger_average_ms: f32 = trigger.default_window_ms,
    /// How long a clip must have been playing before a fresh touch may cut it
    /// short and draw another, in seconds. Zero lets every clip finish.
    interrupt_s: f32 = default_interrupt_s,
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
        } else if (std.mem.eql(u8, arg, "--trigger")) {
            opts.trigger_level = default_trigger;
        } else if (std.mem.startsWith(u8, arg, "--trigger=")) {
            // A threshold outside the sensor's range would either never fire or
            // always fire, which is a typo rather than an intention. The top of
            // the range is the largest `i16`, so the parse itself rejects
            // anything above it and only the negative half is left to check.
            const level = std.fmt.parseInt(i16, arg["--trigger=".len..], 10) catch
                return Error.InvalidTrigger;
            if (level < 0) return Error.InvalidTrigger;
            opts.trigger_level = level;
        } else if (std.mem.startsWith(u8, arg, "--trigger-hold=")) {
            const held = std.fmt.parseFloat(f32, arg["--trigger-hold=".len..]) catch
                return Error.InvalidTriggerHold;
            // A hold longer than a few seconds is a threshold nobody can cross
            // on purpose; NaN fails the first test.
            if (!(held >= 0.0) or held > 5000.0) return Error.InvalidTriggerHold;
            opts.trigger_hold_ms = held;
        } else if (std.mem.startsWith(u8, arg, "--trigger-average=")) {
            const window = std.fmt.parseFloat(f32, arg["--trigger-average=".len..]) catch
                return Error.InvalidTriggerAverage;
            // Past a few seconds the average stops tracking a touch at all.
            if (!(window >= 0.0) or window > 3000.0) return Error.InvalidTriggerAverage;
            opts.trigger_average_ms = window;
        } else if (std.mem.startsWith(u8, arg, "--interrupt=")) {
            const after = std.fmt.parseFloat(f32, arg["--interrupt=".len..]) catch
                return Error.InvalidInterrupt;
            // An hour is longer than any clip in the folders, so anything past
            // it is a typo rather than "never" — which is what 0 is for.
            if (!(after >= 0.0) or after > 3600.0) return Error.InvalidInterrupt;
            opts.interrupt_s = after;
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
    \\                 [--trigger[=LEVEL]] [--trigger-hold=MS] [--trigger-average=MS]
    \\                 [--interrupt=SECONDS] [--device=NAME]
    \\
    \\PLANTS is the digits of the plants to play, in any order:
    \\  1  plant A, the sensor-driven voice
    \\  2  plant B, an interview
    \\  3  plant C, a field recording
    \\
    \\B and C draw one clip each from ./interview files/ and ./field records/,
    \\chosen at random when the program starts, so a run is a different pair
    \\from the last one. Drop a recording into a folder to put it in the
    \\rotation; mp3, wav, ogg and flac are all read. The name of what was
    \\drawn is printed at start up.
    \\
    \\--voice selects what plant A sounds like. All three take their pitch from
    \\the probe on AIN0, and nothing else does:
    \\  drone  filtered noise, pitch following the probe (default)
    \\  flute  recorded flute notes, replayed at the probe's pitch
    \\  beep   a bare synthesized sine at the probe's pitch
    \\
    \\--touch decides when a plant is awake and sounding:
    \\  always  every plant, from the first block on (default)
    \\  script  the built-in timeline: A holds, B and C tap inside it
    \\  motion  one GPIO motion sensor per plant
    \\
    \\--trigger holds plants B and C silent until the probe on AIN1 reaches
    \\LEVEL, so a second probe is what releases their clips. That is the only
    \\thing this probe does, and plant A's probe on AIN0 has no say in it.
    \\LEVEL is the ADC's own number, 0 at ground and 32767 at full scale; given
    \\no number it uses the top of that range. Left out, B and C sound whenever
    \\they are awake.
    \\
    \\--interrupt is how long a clip must have been playing before a fresh
    \\touch cuts it short and draws another, 10 seconds by default. Below that
    \\a touch is ignored, so the clip a visitor started is theirs to hear; past
    \\it the clip fades out and the next turn begins at once. Pass 0 to let
    \\every clip play to its end.
    \\
    \\B and C share that one probe, so they take turns, one clip per touch:
    \\crossing the threshold plays the interview, and when it ends nothing
    \\sounds until the next crossing, which plays the waterfall. Then the
    \\interview again, and so on. A clip plays through even if the reading
    \\falls away, and a crossing while one is playing is ignored rather than
    \\queued. A plant left out of PLANTS never takes a turn, so `13` plays the
    \\waterfall on every touch.
    \\
    \\Under --trigger the probe is the only thing that starts B and C: their
    \\motion sensors are not consulted, since the threshold is what a touch
    \\means. Without --trigger they go back to sounding when they are awake.
    \\
    \\--trigger-average is how long the reading is averaged over before LEVEL
    \\sees it, 200 ms by default. A probe swings about ground and its negative
    \\half reads as zero, so the raw samples are half nothing and half peaks;
    \\their average is a level, and that is what LEVEL should be set against.
    \\Pass 0 to compare raw samples instead.
    \\
    \\--trigger-hold is how long the averaged reading must then stay over LEVEL
    \\before it counts
    \\counts, 100 ms by default. The threshold is tested 344 times a second, so
    \\without this a single noisy sample — mains hum, a brushed pot, static —
    \\starts a clip that then runs for minutes. Raise it if clips start on
    \\their own, lower it if a real touch feels slow to answer. It needs the
    \\reading to be over LEVEL more often than under it, so a probe that only
    \\peaks over the line will not trigger however long it is held; that is a
    \\LEVEL set too high, not a hold set too short.
    \\
    \\The run ends on its own only under --touch=script. Otherwise it plays
    \\until stopped, as the installation does; B and C are one-shots, so they
    \\sound once at the start and plant A carries the rest.
    \\
    \\Both probes are read against ground on one ADS1115, plant A's on AIN0 and
    \\the trigger probe on AIN1. Which pin is which is wiring, not a flag. The
    \\chip has one converter, so it is switched between the two once a block and
    \\each is sampled every other block. A probe below ground reads as zero.
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
    \\  mami_sound --trigger           B then C, once AIN1 reads 32767
    \\  mami_sound --trigger=25000     and the same at a lower threshold
    \\  mami_sound --trigger=25000 --trigger-hold=250
    \\                                 and only if it stays there a quarter second
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

test "the inputs are wired, not chosen" {
    // Each probe has a job that names its pin, so there is no flag to move them
    // with: `--adc=a1` would have pointed plant A's voice at the probe whose
    // whole purpose is gating B and C.
    try testing.expectError(Error.UnknownFlag, parse(&.{"--adc=a2"}));
}

test "no trigger unless asked for" {
    try testing.expectEqual(@as(?i16, null), (try parse(&.{})).trigger_level);
}

test "trigger takes the top of the range, or a number" {
    try testing.expectEqual(
        @as(?i16, default_trigger),
        (try parse(&.{"--trigger"})).trigger_level,
    );
    try testing.expectEqual(@as(?i16, 25000), (try parse(&.{"--trigger=25000"})).trigger_level);
    try testing.expectEqual(@as(?i16, 0), (try parse(&.{"--trigger=0"})).trigger_level);
}

test "rejects a threshold the sensor could never mean" {
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger=high"}));
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger="}));
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger=-1"}));
    // Above full scale, so it would never fire.
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger=40000"}));
    // A count is a whole number; there is nothing between two of them.
    try testing.expectError(Error.InvalidTrigger, parse(&.{"--trigger=2.5"}));
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

test "the trigger hold defaults to something that rejects a lone sample" {
    try testing.expectEqual(trigger.default_hold_ms, (try parse(&.{})).trigger_hold_ms);
    // Long enough to span many polls, so one noisy reading cannot decide.
    try testing.expect(trigger.holdPolls(
        (try parse(&.{})).trigger_hold_ms,
        44100,
        128,
    ) > 10);
}

test "the trigger hold can be tuned on site" {
    try testing.expectEqual(@as(f32, 250.0), (try parse(&.{"--trigger-hold=250"})).trigger_hold_ms);
    try testing.expectEqual(@as(f32, 0.0), (try parse(&.{"--trigger-hold=0"})).trigger_hold_ms);
}

test "rejects a hold that is not a length of time" {
    try testing.expectError(Error.InvalidTriggerHold, parse(&.{"--trigger-hold=soon"}));
    try testing.expectError(Error.InvalidTriggerHold, parse(&.{"--trigger-hold="}));
    try testing.expectError(Error.InvalidTriggerHold, parse(&.{"--trigger-hold=-1"}));
    try testing.expectError(Error.InvalidTriggerHold, parse(&.{"--trigger-hold=nan"}));
    // Nobody holds a plant for six seconds to start a clip.
    try testing.expectError(Error.InvalidTriggerHold, parse(&.{"--trigger-hold=6000"}));
}
