const std = @import("std");
const clips = @import("core/clips.zig");
const source = @import("core/source.zig");
const touch = @import("core/touch.zig");
const select = @import("core/select.zig");

pub const Error = error{
    UnknownFlag,
    InvalidDevice,
    InvalidSource,
    InvalidSeconds,
    InvalidMode,
    ModeOnDrone,
    SecondsOnDrone,
    InvalidTouchModel,
    InvalidStillThreshold,
    InvalidCapture,
    TooManyArguments,
} || select.Error;

/// What `aplay` opens when no device was requested: ALSA's configured default.
pub const default_device = "default";

/// Long enough for the names ALSA actually prints, `plughw:CARD=Headphones`
/// included.
pub const device_max = 63;

/// Long enough for a path somebody types at a Pi.
pub const path_max = 127;

pub const Options = struct {
    plants: select.Selection = select.all,
    device_buf: [device_max]u8 = undefined,
    device_len: usize = 0,
    /// What each plant plays, indexed as the selection is. The defaults are
    /// what the installation did before either flag took a value.
    plant_sources: [2]source.Source = .{ .drone, .voicebox3 },
    /// How long a touch plays, and how long before the next one is honoured.
    /// `null` leaves the source's own answer standing.
    plant_seconds: [2]?f32 = .{ null, null },
    plant_retrigger: [2]?f32 = .{ null, null },
    /// Whether a touch sets a clip going or has to be kept up to hear it.
    /// `null` leaves the plant on `trigger`, which is what it has always done.
    plant_mode: [2]?clips.Mode = .{ null, null },
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
    still_window_ms: ?f32 = null,
    /// Where a held probe sits, when the room can say. Both ends together or
    /// neither: half a band is a typo, not a setting.
    still_band: ?[2]i16 = null,
    /// Where to write down what the probes read, and for how long. Unset, the
    /// run measures nothing and writes nothing.
    capture_buf: [path_max]u8 = undefined,
    capture_len: usize = 0,
    capture_s: f32 = default_capture_s,

    /// The capture path, or null in a run that is not measuring the rig.
    pub fn capture(self: *const Options) ?[]const u8 {
        if (self.capture_len == 0) return null;
        return self.capture_buf[0..self.capture_len];
    }

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
        } else if (std.mem.startsWith(u8, arg, "--plant-a=")) {
            opts.plant_sources[0] = source.Source.parse(arg["--plant-a=".len..]) catch
                return Error.InvalidSource;
        } else if (std.mem.startsWith(u8, arg, "--plant-b=")) {
            opts.plant_sources[1] = source.Source.parse(arg["--plant-b=".len..]) catch
                return Error.InvalidSource;
        } else if (std.mem.startsWith(u8, arg, "--plant-a-seconds=")) {
            opts.plant_seconds[0] = parseSeconds(arg["--plant-a-seconds=".len..]) orelse
                return Error.InvalidSeconds;
        } else if (std.mem.startsWith(u8, arg, "--plant-b-seconds=")) {
            opts.plant_seconds[1] = parseSeconds(arg["--plant-b-seconds=".len..]) orelse
                return Error.InvalidSeconds;
        } else if (std.mem.startsWith(u8, arg, "--plant-a-retrigger=")) {
            opts.plant_retrigger[0] = parseSeconds(arg["--plant-a-retrigger=".len..]) orelse
                return Error.InvalidSeconds;
        } else if (std.mem.startsWith(u8, arg, "--plant-b-retrigger=")) {
            opts.plant_retrigger[1] = parseSeconds(arg["--plant-b-retrigger=".len..]) orelse
                return Error.InvalidSeconds;
        } else if (std.mem.startsWith(u8, arg, "--capture=")) {
            const path = arg["--capture=".len..];
            if (path.len == 0 or path.len > path_max) return Error.InvalidCapture;
            @memcpy(opts.capture_buf[0..path.len], path);
            opts.capture_len = path.len;
        } else if (std.mem.startsWith(u8, arg, "--capture-seconds=")) {
            const secs = parseSeconds(arg["--capture-seconds=".len..]) orelse
                return Error.InvalidCapture;
            if (secs <= 0.0) return Error.InvalidCapture;
            opts.capture_s = secs;
        } else if (std.mem.startsWith(u8, arg, "--still-band=")) {
            opts.still_band = parseBand(arg["--still-band=".len..]) orelse
                return Error.InvalidStillThreshold;
        } else if (std.mem.startsWith(u8, arg, "--plant-a-mode=")) {
            opts.plant_mode[0] = parseMode(arg["--plant-a-mode=".len..]) orelse
                return Error.InvalidMode;
        } else if (std.mem.startsWith(u8, arg, "--plant-b-mode=")) {
            opts.plant_mode[1] = parseMode(arg["--plant-b-mode=".len..]) orelse
                return Error.InvalidMode;
        } else if (std.mem.startsWith(u8, arg, "--touch-model=")) {
            const name = arg["--touch-model=".len..];
            opts.model = parseModel(name) orelse return Error.InvalidTouchModel;
        } else if (std.mem.startsWith(u8, arg, "--still-range=")) {
            opts.still_range = parseCounts(arg["--still-range=".len..]) orelse
                return Error.InvalidStillThreshold;
        } else if (std.mem.startsWith(u8, arg, "--still-release=")) {
            opts.still_release = parseCounts(arg["--still-release=".len..]) orelse
                return Error.InvalidStillThreshold;
        } else if (std.mem.startsWith(u8, arg, "--still-window=")) {
            const ms = parseSeconds(arg["--still-window=".len..]) orelse
                return Error.InvalidStillThreshold;
            if (ms <= 0.0) return Error.InvalidStillThreshold;
            opts.still_window_ms = ms * 1000.0;
        } else if (std.mem.eql(u8, arg, "--plant-a")) {
            // The shorthand the flag had when it was a switch, kept so a unit
            // file already passing it keeps starting.
            opts.plant_sources[0] = .daybird;
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

    // Checked here rather than per-argument because the source and its length
    // can arrive in either order.
    for (opts.plant_sources, 0..) |chosen, plant| {
        if (!chosen.isDrone()) continue;
        if (opts.plant_seconds[plant] != null or opts.plant_retrigger[plant] != null) {
            return Error.SecondsOnDrone;
        }
        // The drone is held by nature -- its gate opens under a hand and falls
        // to an idle floor when the hand goes. A mode flag on it would be a
        // word that changed nothing, which is worse than one that is refused.
        if (opts.plant_mode[plant] != null) return Error.ModeOnDrone;
    }

    return opts;
}

/// Five minutes of probes, which is 1.2 MB and long enough to hold a few dozen
/// touches. Long enough to be worth sweeping, short enough that nobody has to
/// wait about for it.
pub const default_capture_s: f32 = 300.0;

/// A length in seconds. Negative is not a length; zero is "to the clip's end"
/// and is deliberately allowed.
fn parseSeconds(text: []const u8) ?f32 {
    const value = std.fmt.parseFloat(f32, text) catch return null;
    return if (value >= 0.0) value else null;
}

/// `LO:HI`, both ends, low end first. A band with one end open would be a
/// threshold wearing a band's name.
fn parseBand(text: []const u8) ?[2]i16 {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const lo = std.fmt.parseInt(i16, text[0..colon], 10) catch return null;
    const hi = std.fmt.parseInt(i16, text[colon + 1 ..], 10) catch return null;
    return if (lo < hi) .{ lo, hi } else null;
}

fn parseMode(name: []const u8) ?clips.Mode {
    return std.meta.stringToEnum(clips.Mode, name);
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
    \\usage: mami_sound [PLANTS] [--device=NAME]
    \\                  [--plant-a=SOURCE] [--plant-a-mode=MODE]
    \\                  [--plant-a-seconds=N] [--plant-a-retrigger=N]
    \\                  [--plant-b=SOURCE] [--plant-b-mode=MODE]
    \\                  [--plant-b-seconds=N] [--plant-b-retrigger=N]
    \\                  [--touch-model=MODEL] [--still-range=N] [--still-release=N]
    \\                  [--still-window=SECONDS] [--still-band=LO:HI]
    \\                  [--capture=PATH] [--capture-seconds=N]
    \\                  [--test-random-probe]
    \\
    \\PLANTS may be omitted, or must be exactly one of:
    \\  1  plant A only
    \\  2  plant B only
    \\  12 both plants
    \\
    \\--device selects the ALSA device for aplay. It defaults to `default`.
    \\Use `aplay -l` to list cards; for example, `plughw:0,0`.
    \\
    \\--plant-a and --plant-b each name what that plant plays. Either plant
    \\takes any of them:
    \\  drone       the sensor-driven voice, generated rather than played
    \\  voicebox3   ./Voice Box 3/
    \\  voicebox5   ./Voice Box 5/
    \\  daybird     ./Day bird/
    \\  insect      ./Insect/
    \\  tradvn      ./Trad Vn Jam/
    \\  bell        ./Bell Stems/
    \\  piano       ./EPiano Stems/
    \\Unasked, plant A is the drone and plant B is voicebox3. Bare --plant-a
    \\means --plant-a=daybird. Every source is one folder: a plant that wants
    \\two of them is two plants.
    \\
    \\--plant-a-seconds and --plant-b-seconds are how long one touch plays.
    \\Zero plays the clip to its own end, which is how a source that is normally
    \\cut is uncapped, or one that normally runs long is cut. Left off, the
    \\source's own length stands: 4s for the stems, 5s for daybird and insect,
    \\and to the end for the voice boxes and tradvn.
    \\
    \\--plant-a-mode and --plant-b-mode are how a plant answers a hand:
    \\  trigger  a touch sets a clip going and it runs its own length
    \\  hold     the clip sounds while the plant is held and fades when it is
    \\           let go, and the next hold picks it up where it stopped
    \\Left off, a plant triggers. The drone always holds and takes no mode.
    \\
    \\--plant-a-retrigger and --plant-b-retrigger are how long a clip is
    \\protected from the next touch, counted from when it started. A touch
    \\inside it is ignored and the clip keeps playing; a touch past it moves the
    \\plant on to a different clip. Left off, 10s for the voice boxes and 5s
    \\for everything else. The drone takes neither flag.
    \\
    \\--touch-model picks what the detector asks each probe:
    \\  deviation  how far the probe has moved from its own recent past
    \\  steady     how tightly the last second of readings clusters, at any level
    \\Use `steady` on a rig whose probes clamp to a level you cannot predict.
    \\
    \\--still-range and --still-release are that model's two thresholds, in
    \\counts: at or below the range the probe is being held, at or above the
    \\release the touch is over, and between them nothing changes. Defaults are
    \\32 and 512. A hand actually holds a probe to about three counts; 32 is
    \\room for the dropouts this rig throws, and --still-range=10 is the number
    \\to use once the conversion reads come back clean.
    \\
    \\--still-band says where a held probe sits, as LO:HI in counts. Given one,
    \\the model needs no untouched stretch after power-on to work rest out from,
    \\and cannot learn the wrong rest because somebody had hold of a plant while
    \\it was starting. Left off, rest is learned and a touch is stillness a
    \\hundred counts away from it. Set it once you have watched the rig: the
    \\status line's l0 and l1 are the levels to read it off.
    \\
    \\--still-window is how long a stretch of readings that range is measured
    \\over, in seconds. It buys the answer's stability rather than its speed:
    \\shortening it to a quarter of a second finds one hand fifteen times over
    \\rather than finding more hands. Default 1. `zig build replay -- CAPTURE
    \\--sweep` picks all three from a recording rather than from the room.
    \\
    \\--capture writes down what the probes actually read, every poll of both,
    \\to a file `zig build replay` can sweep. Start it, touch each plant a few
    \\times, then Ctrl-C: the run comes out through its ordinary shutdown and
    \\the capture is written on the way. Then
    \\  zig build replay -- PATH --model=steady --sweep
    \\reads the thresholds off this rig instead of guessing them.
    \\
    \\--capture-seconds is how much room the capture has, not how long you wait
    \\-- five minutes by default, which is 1.2 MB held in memory. It reaches the
    \\disk once, at the end, so the room gets one click then and none during.
    \\Recording stops if the room runs out; the piece carries on either way.
    \\
    \\--test-random-probe skips I2C and simulates repeatable plant touch phases.
    \\
;

test "each plant chooses its own source" {
    const opts = try parse(&.{ "--plant-a=insect", "--plant-b=tradvn" });
    try std.testing.expectEqual(source.Source.insect, opts.plant_sources[0]);
    try std.testing.expectEqual(source.Source.tradvn, opts.plant_sources[1]);
}

test "the defaults are what the installation already does" {
    const opts = try parse(&.{});
    try std.testing.expectEqual(source.Source.drone, opts.plant_sources[0]);
    try std.testing.expectEqual(source.Source.voicebox3, opts.plant_sources[1]);
    try std.testing.expect(opts.plant_seconds[0] == null);
    try std.testing.expect(opts.plant_retrigger[1] == null);
}

test "either plant accepts any source, including the drone" {
    try std.testing.expectEqual(
        source.Source.drone,
        (try parse(&.{"--plant-b=drone"})).plant_sources[1],
    );
    try std.testing.expectEqual(
        source.Source.bell,
        (try parse(&.{"--plant-a=bell"})).plant_sources[0],
    );
}

test "bare --plant-a still means the bird calls" {
    // A unit file already passing the flag keeps starting.
    const opts = try parse(&.{"--plant-a"});
    try std.testing.expectEqual(source.Source.daybird, opts.plant_sources[0]);
}

test "a source no folder answers to is refused" {
    try std.testing.expectError(Error.InvalidSource, parse(&.{"--plant-a=cello"}));
    try std.testing.expectError(Error.InvalidSource, parse(&.{"--plant-b="}));
}

test "both lengths can be set per plant" {
    const opts = try parse(&.{
        "--plant-a=insect",
        "--plant-a-seconds=8",
        "--plant-b-retrigger=20",
    });
    try std.testing.expectEqual(@as(f32, 8.0), opts.plant_seconds[0].?);
    try std.testing.expectEqual(@as(f32, 20.0), opts.plant_retrigger[1].?);
}

test "zero seconds is how a source is uncapped" {
    const opts = try parse(&.{ "--plant-a=bell", "--plant-a-seconds=0" });
    try std.testing.expectEqual(@as(f32, 0.0), opts.plant_seconds[0].?);
}

test "a length that is not one is refused" {
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-a-seconds=-1"}));
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-b-seconds=soon"}));
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-a-retrigger=-3"}));
}

test "a length given to the drone is refused rather than ignored" {
    // The drone has no clip to cut, so the flag can only be a typo, and a
    // silently ignored typo is how a room hears the wrong thing with no clue.
    try std.testing.expectError(
        Error.SecondsOnDrone,
        parse(&.{ "--plant-a=drone", "--plant-a-seconds=5" }),
    );
    try std.testing.expectError(
        Error.SecondsOnDrone,
        parse(&.{ "--plant-b=drone", "--plant-b-retrigger=5" }),
    );
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

test "a plant can be told to hold rather than trigger" {
    const opts = try parse(&.{ "--plant-a=insect", "--plant-a-mode=hold" });
    try std.testing.expectEqual(clips.Mode.hold, opts.plant_mode[0].?);
    try std.testing.expect(opts.plant_mode[1] == null);

    try std.testing.expectEqual(
        clips.Mode.trigger,
        (try parse(&.{ "--plant-b=bell", "--plant-b-mode=trigger" })).plant_mode[1].?,
    );
}

test "a mode no plant has is refused" {
    try std.testing.expectError(Error.InvalidMode, parse(&.{ "--plant-a=bell", "--plant-a-mode=latch" }));
    try std.testing.expectError(Error.InvalidMode, parse(&.{ "--plant-a=bell", "--plant-a-mode=" }));
}

test "a mode given to the drone is refused" {
    // The drone already holds: its gate opens under a hand and falls to an idle
    // floor when the hand goes. A flag that changed nothing would only mislead.
    try std.testing.expectError(Error.ModeOnDrone, parse(&.{"--plant-a-mode=hold"}));
}

test "the stillness window can be shortened from the command line" {
    const opts = try parse(&.{"--still-window=0.25"});
    try std.testing.expectEqual(@as(f32, 250.0), opts.still_window_ms.?);
    try std.testing.expect((try parse(&.{})).still_window_ms == null);
}

test "a window of no time at all is refused" {
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--still-window=0"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--still-window=-1"}));
}

test "the usage banner names every flag the parser takes" {
    // The banner has gone stale twice: --plant-a-mode and --still-window both
    // worked, were documented in the body, and were missing from the summary
    // at the top. A flag nobody can find is a flag nobody uses.
    const flags = [_][]const u8{
        "--device=",
        "--plant-a=",
        "--plant-a-mode=",
        "--plant-a-seconds=",
        "--plant-a-retrigger=",
        "--plant-b=",
        "--plant-b-mode=",
        "--plant-b-seconds=",
        "--plant-b-retrigger=",
        "--touch-model=",
        "--still-range=",
        "--still-release=",
        "--still-window=",
        "--test-random-probe",
    };
    const banner_end = std.mem.indexOf(u8, usage, "\nPLANTS").?;
    const banner = usage[0..banner_end];

    for (flags) |flag| {
        // The name without its `=`, so the banner may write it as `=N` or
        // `=SOURCE` however it likes.
        const name = flag[0 .. flag.len - @as(usize, if (flag[flag.len - 1] == '=') 1 else 0)];
        if (std.mem.indexOf(u8, banner, name) == null) {
            std.debug.print("usage banner does not name {s}\n", .{name});
            return error.FlagMissingFromBanner;
        }
    }
}

test "a band takes both ends, low first" {
    const opts = try parse(&.{"--still-band=650:660"});
    try std.testing.expectEqual(@as(i16, 650), opts.still_band.?[0]);
    try std.testing.expectEqual(@as(i16, 660), opts.still_band.?[1]);
    try std.testing.expect((try parse(&.{})).still_band == null);
}

test "half a band, or one the wrong way round, is refused" {
    // A band with one end open is a threshold wearing a band's name, and one
    // that runs backwards can never contain anything.
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--still-band=650"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--still-band=660:650"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--still-band=650:"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--still-band=a:b"}));
}

test "a run can be told to write down what the probes read" {
    const opts = try parse(&.{ "--capture=probes.csv", "--capture-seconds=900" });
    try std.testing.expectEqualStrings("probes.csv", opts.capture().?);
    try std.testing.expectEqual(@as(f32, 900.0), opts.capture_s);

    // And measures nothing unless asked.
    const quiet = try parse(&.{});
    try std.testing.expect(quiet.capture() == null);
    try std.testing.expectEqual(default_capture_s, quiet.capture_s);
}

test "a capture with no path or no time is refused" {
    try std.testing.expectError(Error.InvalidCapture, parse(&.{"--capture="}));
    try std.testing.expectError(Error.InvalidCapture, parse(&.{"--capture-seconds=0"}));
    try std.testing.expectError(Error.InvalidCapture, parse(&.{"--capture-seconds=-5"}));
}
