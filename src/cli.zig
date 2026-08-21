//! Command line: which plants play, and what plant A sounds like.
//!
//! Parsing is pure and works on a slice of arguments, so every flag can be
//! tested without a process.

const std = @import("std");
const select = @import("select.zig");
const noise = @import("noise.zig");
const touch = @import("touch.zig");

pub const Error = error{
    UnknownFlag,
    UnknownVoice,
    UnknownTouch,
    InvalidDevice,
    InvalidTouchLevel,
    InvalidTouchHold,
    InvalidTouchAverage,
    InvalidTouchBaseline,
    InvalidTouchSettle,
    InvalidPitchSpan,
    InvalidPitchJump,
    InvalidPitchGlide,
    InvalidLogPath,
    TriggerRetired,
    InvalidInterrupt,
    TooManyArguments,
} || select.Error;

/// How long a clip plays before a touch is allowed to cut it short. Long
/// enough that a visitor hears what they started, short enough that they are
/// not held there by a recording they have finished with.
pub const default_interrupt_s: f32 = 10.0;

/// What decides when a plant is awake.
pub const Touch = enum {
    /// The probes themselves, each judged against its own recent past. The
    /// installation.
    probes,
    /// Every plant, always. What to use while chasing a fault in the mix or the
    /// sound card, since it takes detection out of the picture entirely.
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

/// Long enough for any path a log is likely to be pointed at.
pub const path_max = 255;

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
    touch: Touch = .probes,
    /// How many deviations from its own median a probe must read before it
    /// counts as touched. One number for both probes.
    touch_level: f32 = touch.default_level,
    /// How long the score must keep saying so, in milliseconds.
    touch_hold_ms: f32 = touch.default_hold_ms,
    /// How long a reading is averaged over before the score sees it.
    touch_average_ms: f32 = touch.default_average_ms,
    /// How far back the median looks, in seconds. Wants to be about four times
    /// the longest touch expected: a touch filling more than half the window
    /// teaches the median that it is the resting state.
    touch_baseline_s: f32 = touch.default_baseline_s,
    /// How long the other probe is given to settle after this one is touched,
    /// before its crosstalk level is taken as its temporary rest.
    touch_settle_ms: f32 = touch.default_settle_ms,
    /// Probe BC's own threshold and hold. `null` asks it A's question.
    ///
    /// BC starts a recording that then runs for minutes, so a wrong latch
    /// there is the fault people hear; A's only moves a drone that was already
    /// sounding. BC can be held to a much larger move without making A deaf.
    touch_level_bc: ?f32 = null,
    touch_hold_bc_ms: ?f32 = null,
    /// The deviation that maps to the top of plant A's pitch range.
    pitch_span: i16 = noise.default_span,
    /// How much of the distance to a new pitch is closed at once, and how long
    /// the rest takes. Between them, how sharply plant A answers.
    pitch_jump: f32 = noise.default_jump,
    pitch_glide_s: f32 = noise.default_glide_s,
    /// How long a clip must have been playing before a fresh touch may cut it
    /// short and draw another, in seconds. Zero lets every clip finish.
    interrupt_s: f32 = default_interrupt_s,
    /// The device name is carried inline rather than as a slice into `args`, so
    /// `Options` outlives the arguments it was parsed from and the caller is
    /// free to drop them.
    device_buf: [device_max]u8 = undefined,
    /// Zero means nothing was asked for.
    device_len: usize = 0,
    /// Where the per-poll CSV goes, carried inline for the same reason the
    /// device name is.
    log_path_buf: [path_max]u8 = undefined,
    log_path_len: usize = 0,

    pub fn device(self: *const Options) []const u8 {
        if (self.device_len == 0) return default_device;
        return self.device_buf[0..self.device_len];
    }

    pub fn logPath(self: *const Options) ?[]const u8 {
        if (self.log_path_len == 0) return null;
        return self.log_path_buf[0..self.log_path_len];
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
        } else if (std.mem.eql(u8, arg, "--trigger") or
            std.mem.startsWith(u8, arg, "--trigger=") or
            std.mem.startsWith(u8, arg, "--trigger-hold=") or
            std.mem.startsWith(u8, arg, "--trigger-average="))
        {
            // Named rather than swept into UnknownFlag: anyone running the
            // installation has these in a shell history somewhere.
            return Error.TriggerRetired;
        } else if (std.mem.startsWith(u8, arg, "--touch-level=")) {
            const level = std.fmt.parseFloat(f32, arg["--touch-level=".len..]) catch
                return Error.InvalidTouchLevel;
            // Under about two deviations everything is a touch, and past a
            // hundred nothing is.
            if (!(level >= 1.0) or level > 100.0) return Error.InvalidTouchLevel;
            opts.touch_level = level;
        } else if (std.mem.startsWith(u8, arg, "--touch-hold=")) {
            const held = std.fmt.parseFloat(f32, arg["--touch-hold=".len..]) catch
                return Error.InvalidTouchHold;
            if (!(held >= 0.0) or held > 5000.0) return Error.InvalidTouchHold;
            opts.touch_hold_ms = held;
        } else if (std.mem.startsWith(u8, arg, "--touch-average=")) {
            const window = std.fmt.parseFloat(f32, arg["--touch-average=".len..]) catch
                return Error.InvalidTouchAverage;
            if (!(window >= 0.0) or window > 3000.0) return Error.InvalidTouchAverage;
            opts.touch_average_ms = window;
        } else if (std.mem.startsWith(u8, arg, "--touch-baseline=")) {
            const window = std.fmt.parseFloat(f32, arg["--touch-baseline=".len..]) catch
                return Error.InvalidTouchBaseline;
            // A hundred seconds is the longest the buffer holds at ten hertz.
            if (!(window > 0.0) or window > 100.0) return Error.InvalidTouchBaseline;
            opts.touch_baseline_s = window;
        } else if (std.mem.startsWith(u8, arg, "--touch-settle=")) {
            const settle = std.fmt.parseFloat(f32, arg["--touch-settle=".len..]) catch
                return Error.InvalidTouchSettle;
            if (!(settle >= 0.0) or settle > 5000.0) return Error.InvalidTouchSettle;
            opts.touch_settle_ms = settle;
        } else if (std.mem.startsWith(u8, arg, "--touch-level-bc=")) {
            const level = std.fmt.parseFloat(f32, arg["--touch-level-bc=".len..]) catch
                return Error.InvalidTouchLevel;
            if (!(level >= 1.0) or level > 100.0) return Error.InvalidTouchLevel;
            opts.touch_level_bc = level;
        } else if (std.mem.startsWith(u8, arg, "--touch-hold-bc=")) {
            const held = std.fmt.parseFloat(f32, arg["--touch-hold-bc=".len..]) catch
                return Error.InvalidTouchHold;
            if (!(held >= 0.0) or held > 5000.0) return Error.InvalidTouchHold;
            opts.touch_hold_bc_ms = held;
        } else if (std.mem.startsWith(u8, arg, "--pitch-jump=")) {
            const jump = std.fmt.parseFloat(f32, arg["--pitch-jump=".len..]) catch
                return Error.InvalidPitchJump;
            // A fraction of the distance, so outside 0..1 it means nothing.
            if (!(jump >= 0.0) or jump > 1.0) return Error.InvalidPitchJump;
            opts.pitch_jump = jump;
        } else if (std.mem.startsWith(u8, arg, "--pitch-glide=")) {
            const glide = std.fmt.parseFloat(f32, arg["--pitch-glide=".len..]) catch
                return Error.InvalidPitchGlide;
            // Zero is a step, which is the one thing the piece is built to
            // avoid; past a minute the pitch stops tracking the plant at all.
            if (!(glide > 0.0) or glide > 60.0) return Error.InvalidPitchGlide;
            opts.pitch_glide_s = glide;
        } else if (std.mem.startsWith(u8, arg, "--pitch-span=")) {
            const span = std.fmt.parseInt(i16, arg["--pitch-span=".len..], 10) catch
                return Error.InvalidPitchSpan;
            if (span <= 0) return Error.InvalidPitchSpan;
            opts.pitch_span = span;
        } else if (std.mem.startsWith(u8, arg, "--log-touch=")) {
            const path = arg["--log-touch=".len..];
            if (path.len == 0 or path.len > path_max) return Error.InvalidLogPath;
            @memcpy(opts.log_path_buf[0..path.len], path);
            opts.log_path_len = path.len;
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
    \\usage: mami_sound [PLANTS] [--voice=drone|flute|beep]
    \\                 [--touch=probes|always|script|motion] [--touch-level=Z]
    \\                 [--touch-hold=MS] [--touch-average=MS] [--touch-baseline=S]
    \\                 [--touch-settle=MS] [--touch-level-bc=Z] [--touch-hold-bc=MS]
    \\                 [--pitch-span=COUNTS] [--pitch-jump=FRACTION]
    \\                 [--pitch-glide=SECONDS] [--log-touch=PATH]
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
    \\the probe across AIN0 and AIN1, and nothing else does:
    \\  drone  filtered noise, pitch following the probe (default)
    \\  flute  recorded flute notes, replayed at the probe's pitch
    \\  beep   a bare synthesized sine at the probe's pitch
    \\
    \\--touch decides when a plant is awake and sounding:
    \\  probes  the probes themselves decide (default)
    \\  always  every plant, from the first block on
    \\  script  the built-in timeline: A holds, B and C tap inside it
    \\  motion  one GPIO motion sensor per plant
    \\
    \\Each probe is judged against its own recent past rather than against a
    \\number typed here. --touch-level is how many deviations from its own
    \\rolling median a probe must read before it counts as touched, 6 by
    \\default, and the same number serves both probes: a probe resting at
    \\-2049 and one resting at +1000 are both asked the same question.
    \\
    \\--touch-average is how long a reading is averaged over before the score
    \\sees it, 200 ms by default. Nothing is rectified: a probe rests wherever
    \\its wiring leaves it, above or below zero, and a touch can move it either
    \\way from there, so the sign is the signal and folding it away would throw
    \\half of it out.
    \\
    \\--touch-hold is how long the score must keep saying so before it counts,
    \\100 ms by default. The score is tested 344 times a second, so without a
    \\hold one noisy poll could start a clip that runs for minutes.
    \\
    \\--touch-baseline is how far back the median looks, 60 seconds by
    \\default. A touch filling more than half that window teaches the median
    \\that being touched is the resting state, and the plant goes quiet with a
    \\hand still on it; set this to about four times the longest touch you
    \\expect.
    \\
    \\--touch-settle is how long the other probe is given to settle after this
    \\one is touched, 300 ms by default. Touching plant A drags the other probe
    \\with it, to the same reading a real touch on it would give; after the
    \\settle, wherever it was dragged to becomes its rest for as long as A is
    \\held, so only a further move counts as a touch of its own.
    \\
    \\--touch-level-bc and --touch-hold-bc ask probe BC a different question
    \\from A's, and are the two knobs to reach for when clips start on their
    \\own. Left out, BC is asked A's. The two probes can afford to differ: a
    \\wrong latch on A moves a drone that was already sounding and nobody can
    \\tell, while a wrong latch on BC starts a recording that then runs for
    \\minutes. Hold BC to a much larger move than A without making A deaf.
    \\
    \\--pitch-span is the deviation from rest that reaches the top of plant A's
    \\range, 3000 counts by default. Raise it if the drone slams to the top of
    \\its range on the smallest touch, which means the probe is moving by more
    \\counts than the span allows for.
    \\
    \\--pitch-jump is how much of the distance to a new pitch is closed the
    \\instant a touch lands, three quarters by default, and --pitch-glide is
    \\how long the rest of it takes, one second. Between them they are how
    \\sharply plant A answers: lower the jump and lengthen the glide and the
    \\pitch swells into place instead of arriving all at once. A jump of 0 is a
    \\pure glide, which is the gentlest the piece will go.
    \\
    \\--log-touch writes every poll's numbers to PATH as CSV: both probes' raw
    \\reading, mean, median, deviation, score and latch, and the state they
    \\produced. About 20 MB per fifteen minutes. This is how a threshold that
    \\fires in an empty room gets diagnosed at a desk instead of in the
    \\gallery.
    \\
    \\--interrupt is how long a clip must have been playing before a fresh
    \\touch cuts it short and draws another, 10 seconds by default. Below that
    \\a touch is ignored, so the clip a visitor started is theirs to hear; past
    \\it the clip fades out and the next turn begins at once. Pass 0 to let
    \\every clip play to its end.
    \\
    \\B and C share the probe across AIN2 and AIN3, so they take turns, one clip
    \\per touch:
    \\the first touch plays the interview, and when it ends nothing sounds
    \\until the next touch, which plays the waterfall. Then the interview
    \\again, and so on. A clip plays through even if the touch ends, and a
    \\touch while one is playing is ignored rather than queued. A plant left
    \\out of PLANTS never takes a turn, so `13` plays the waterfall on every
    \\touch.
    \\
    \\Under --touch=probes the motion sensors are not consulted at all: the
    \\probes are what a touch means. The other three modes are for
    \\demonstrating and for chasing faults, and reach the voices through the
    \\same door.
    \\
    \\The run ends on its own only under --touch=script. Otherwise it plays
    \\until stopped, as the installation does; B and C are one-shots, so they
    \\sound once at the start and plant A carries the rest.
    \\
    \\Both probes sit on one ADS1115, each across a differential pair rather
    \\than against ground: plant A's on AIN0-AIN1, plants B and C's on
    \\AIN2-AIN3. Those are the only two of the chip's four differential
    \\combinations that share no pin, so neither probe sits on the other's
    \\reference, and interference reaching both halves of a pair at once —
    \\mains hum, most of all — subtracts away instead of landing in the
    \\reading. Which pin is which is wiring, not a flag. The chip has one
    \\converter, so it is switched between the two probes once a block and each
    \\is sampled every other block. The count is passed on signed and
    \\unrectified: which way a probe moves from its rest is exactly what the
    \\sign is there to carry.
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
    \\  mami_sound --touch-level=5     latch on a smaller move than the default
    \\  mami_sound --log-touch=/tmp/touch.csv
    \\                                 record every poll for a look afterwards
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

test "the probes decide unless something else was asked for" {
    const opts = try parse(&.{});
    try testing.expectEqual(Touch.probes, opts.touch);
    try testing.expectEqual(touch.default_level, opts.touch_level);
    try testing.expectEqual(touch.default_baseline_s, opts.touch_baseline_s);
    try testing.expectEqual(noise.default_span, opts.pitch_span);
    try testing.expectEqual(@as(?[]const u8, null), opts.logPath());
}

test "every touch knob takes a number" {
    const opts = try parse(&.{
        "--touch-level=8",
        "--touch-hold=250",
        "--touch-average=400",
        "--touch-baseline=90",
        "--touch-settle=500",
        "--pitch-span=4000",
    });
    try testing.expectEqual(@as(f32, 8.0), opts.touch_level);
    try testing.expectEqual(@as(f32, 250.0), opts.touch_hold_ms);
    try testing.expectEqual(@as(f32, 400.0), opts.touch_average_ms);
    try testing.expectEqual(@as(f32, 90.0), opts.touch_baseline_s);
    try testing.expectEqual(@as(f32, 500.0), opts.touch_settle_ms);
    try testing.expectEqual(@as(i16, 4000), opts.pitch_span);
}

test "nonsense on the touch knobs is refused rather than rounded" {
    try testing.expectError(Error.InvalidTouchLevel, parse(&.{"--touch-level=0"}));
    try testing.expectError(Error.InvalidTouchLevel, parse(&.{"--touch-level=-3"}));
    try testing.expectError(Error.InvalidTouchHold, parse(&.{"--touch-hold=9000"}));
    try testing.expectError(Error.InvalidTouchAverage, parse(&.{"--touch-average=5000"}));
    try testing.expectError(Error.InvalidTouchBaseline, parse(&.{"--touch-baseline=0"}));
    try testing.expectError(Error.InvalidTouchSettle, parse(&.{"--touch-settle=9000"}));
    try testing.expectError(Error.InvalidPitchSpan, parse(&.{"--pitch-span=0"}));
}

test "the old trigger flags say what replaced them" {
    try testing.expectError(Error.TriggerRetired, parse(&.{"--trigger"}));
    try testing.expectError(Error.TriggerRetired, parse(&.{"--trigger=25000"}));
    try testing.expectError(Error.TriggerRetired, parse(&.{"--trigger-hold=250"}));
    try testing.expectError(Error.TriggerRetired, parse(&.{"--trigger-average=400"}));
}

test "BC can be told apart from A" {
    const opts = try parse(&.{ "--touch-level-bc=20", "--touch-hold-bc=30" });
    try testing.expectEqual(@as(?f32, 20.0), opts.touch_level_bc);
    try testing.expectEqual(@as(?f32, 30.0), opts.touch_hold_bc_ms);
}

test "BC is asked A's question when it was given none of its own" {
    const opts = try parse(&.{"--touch-level=9"});
    try testing.expectEqual(@as(?f32, null), opts.touch_level_bc);
    try testing.expectEqual(@as(?f32, null), opts.touch_hold_bc_ms);
}

test "plant A's rise can be slowed" {
    const opts = try parse(&.{ "--pitch-jump=0.1", "--pitch-glide=4" });
    try testing.expectEqual(@as(f32, 0.1), opts.pitch_jump);
    try testing.expectEqual(@as(f32, 4.0), opts.pitch_glide_s);
}

test "nonsense on the per-probe and pitch knobs is refused" {
    try testing.expectError(Error.InvalidTouchLevel, parse(&.{"--touch-level-bc=0"}));
    try testing.expectError(Error.InvalidTouchHold, parse(&.{"--touch-hold-bc=9000"}));
    // A jump is a fraction of the distance, so outside 0..1 it means nothing.
    try testing.expectError(Error.InvalidPitchJump, parse(&.{"--pitch-jump=1.5"}));
    try testing.expectError(Error.InvalidPitchJump, parse(&.{"--pitch-jump=-1"}));
    // A glide of zero is a step, which is what the piece is built to avoid.
    try testing.expectError(Error.InvalidPitchGlide, parse(&.{"--pitch-glide=0"}));
    try testing.expectError(Error.InvalidPitchGlide, parse(&.{"--pitch-glide=120"}));
}

test "the log path is carried inline so the arguments can be dropped" {
    const opts = try parse(&.{"--log-touch=/tmp/touch.csv"});
    try testing.expectEqualStrings("/tmp/touch.csv", opts.logPath().?);
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

test "the touch hold defaults to something that rejects a lone poll" {
    try testing.expectEqual(touch.default_hold_ms, (try parse(&.{})).touch_hold_ms);
    // Long enough to span many polls, so one noisy reading cannot decide.
    try testing.expect(touch.holdPolls(
        (try parse(&.{})).touch_hold_ms,
        44100,
        128,
    ) > 10);
}

test "rejects a hold that is not a length of time" {
    try testing.expectError(Error.InvalidTouchHold, parse(&.{"--touch-hold=soon"}));
    try testing.expectError(Error.InvalidTouchHold, parse(&.{"--touch-hold="}));
    try testing.expectError(Error.InvalidTouchHold, parse(&.{"--touch-hold=-1"}));
    try testing.expectError(Error.InvalidTouchHold, parse(&.{"--touch-hold=nan"}));
    // Nobody holds a plant for six seconds to start a clip.
    try testing.expectError(Error.InvalidTouchHold, parse(&.{"--touch-hold=6000"}));
}

test "the baseline window cannot be asked for longer than the ring holds" {
    // 1024 samples at 10 Hz is 102.4 seconds, and past that `Baseline.init`
    // clamps: the window would quietly mean something other than what was
    // typed. Refused at the flag instead.
    try testing.expectEqual(@as(f32, 100.0), (try parse(&.{"--touch-baseline=100"})).touch_baseline_s);
    try testing.expectError(Error.InvalidTouchBaseline, parse(&.{"--touch-baseline=101"}));
}

test "rejects a log path that is empty or too long" {
    try testing.expectError(Error.InvalidLogPath, parse(&.{"--log-touch="}));
    const long = "--log-touch=" ++ "x" ** (path_max + 1);
    try testing.expectError(Error.InvalidLogPath, parse(&.{long}));
}
