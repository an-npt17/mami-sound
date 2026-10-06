const std = @import("std");
const clips = @import("core/clips.zig");
const source = @import("core/source.zig");
const touch = @import("core/touch.zig");
const select = @import("core/select.zig");
const boxes = @import("application/boxes/root.zig");

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
    InvalidTouchFloor,
    InvalidTouchRise,
    InvalidBandShare,
    InvalidCapture,
    InvalidBox,
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
    /// What each plant plays, indexed as the selection is. `null` is the room
    /// not having said, which leaves the box's own answer standing -- and is
    /// not the same as a room asking for the drone, which is what a plain
    /// default could not distinguish.
    plant_sources: [2]?source.Source = .{ null, null },
    /// How long a touch plays, and how long before the next one is honoured.
    /// `null` leaves the source's own answer standing.
    plant_seconds: [2]?f32 = .{ null, null },
    plant_retrigger: [2]?f32 = .{ null, null },
    /// Whether a touch sets a clip going or has to be kept up to hear it.
    /// `null` leaves the plant on `trigger`, which is what it has always done.
    plant_mode: [2]?clips.Mode = .{ null, null },
    /// How long a touch may last and still count, per plant. `null` leaves the
    /// preset's answer standing, which is a second on plant B and nothing on
    /// plant A.
    ///
    /// On the command line because it is the flag that decides whether a plant
    /// answers a hand that arrives and stays: with a window it wants a tap, and
    /// which of the two a rig needs is a property of the room rather than of
    /// the piece.
    plant_window: [2]?touch.Window = .{ null, null },
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
    /// How much of the window must be past the line before a touch counts,
    /// under the `learned` model.
    ///
    /// On the command line for the same reason the still thresholds are: it is
    /// a property of the rig on the day. On box1's capture a hand scores as
    /// little as 0.556 against a preset of 0.600, so the number that decides
    /// whether the plant answers at all was the one number nobody could change
    /// without rebuilding on the Pi.
    band_share: ?f32 = null,
    /// How little of the window past the line ends a touch, under `learned`.
    ///
    /// Below the share it latches at, so a hand sitting on the line holds
    /// rather than latching and releasing on alternate windows.
    band_release: ?f32 = null,
    /// How far up the pitch range a touch starts, as a fraction of it.
    touch_floor: ?f32 = null,
    /// How long a held touch takes to climb from that start to the top. Set,
    /// the drone reads its pitch off the hold rather than off the reading --
    /// which is the only thing that works on the `learned` rig, where the
    /// reading offers two pitches and no more.
    touch_rise_s: ?f32 = null,
    /// How big a move a touch must be, in the counts the probe reads, per
    /// probe. Unset keeps the measured preset; zero asks for no floor at all.
    ///
    /// On the command line for the same reason the thresholds are: the number
    /// is a property of the rig on the day. A probe whose dropouts get worse
    /// wants a higher floor, and finding that out should not want a rebuild.
    counts: ?i16 = null,
    counts_bc: ?i16 = null,
    /// Where a held probe sits, per plant, when the room can say. Both ends
    /// together or neither: half a band is a typo, not a setting.
    ///
    /// Per plant because the two probes do not sit at the same place: on this
    /// rig a hand puts one near six hundred and sixty and the other near
    /// twenty-five thousand.
    plant_band: [2]?[2]i16 = .{ null, null },
    /// Where to write down what the probes read, and for how long. Unset, the
    /// run measures nothing and writes nothing.
    capture_buf: [path_max]u8 = undefined,
    capture_len: usize = 0,
    capture_s: f32 = default_capture_s,
    /// Which box's measured numbers to run, where the room said so. `null` is
    /// the room not having said, and the hostname is asked instead.
    ///
    /// On the command line rather than compiled in because one binary serves
    /// all five Pis: a bench can then run box 5's floors against box 5's
    /// capture without a cross-build, and a deploy is the same everywhere.
    box: ?boxes.Box = null,

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
        } else if (std.mem.startsWith(u8, arg, "--plant-a-band=")) {
            opts.plant_band[0] = parseBand(arg["--plant-a-band=".len..]) orelse
                return Error.InvalidStillThreshold;
        } else if (std.mem.startsWith(u8, arg, "--plant-b-band=")) {
            opts.plant_band[1] = parseBand(arg["--plant-b-band=".len..]) orelse
                return Error.InvalidStillThreshold;
        } else if (std.mem.startsWith(u8, arg, "--counts=")) {
            opts.counts = parseFloor(arg["--counts=".len..]) orelse
                return Error.InvalidStillThreshold;
        } else if (std.mem.startsWith(u8, arg, "--counts-b=")) {
            opts.counts_bc = parseFloor(arg["--counts-b=".len..]) orelse
                return Error.InvalidStillThreshold;
        } else if (std.mem.startsWith(u8, arg, "--plant-a-mode=")) {
            opts.plant_mode[0] = parseMode(arg["--plant-a-mode=".len..]) orelse
                return Error.InvalidMode;
        } else if (std.mem.startsWith(u8, arg, "--plant-b-mode=")) {
            opts.plant_mode[1] = parseMode(arg["--plant-b-mode=".len..]) orelse
                return Error.InvalidMode;
        } else if (std.mem.startsWith(u8, arg, "--plant-a-window=")) {
            opts.plant_window[0] = parseWindow(arg["--plant-a-window=".len..]) orelse
                return Error.InvalidSeconds;
        } else if (std.mem.startsWith(u8, arg, "--plant-b-window=")) {
            opts.plant_window[1] = parseWindow(arg["--plant-b-window=".len..]) orelse
                return Error.InvalidSeconds;
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
        } else if (std.mem.startsWith(u8, arg, "--band-share=")) {
            const fraction = std.fmt.parseFloat(f32, arg["--band-share=".len..]) catch
                return Error.InvalidBandShare;
            if (!(fraction > 0.0) or fraction > 1.0) return Error.InvalidBandShare;
            opts.band_share = fraction;
        } else if (std.mem.startsWith(u8, arg, "--band-release=")) {
            const fraction = std.fmt.parseFloat(f32, arg["--band-release=".len..]) catch
                return Error.InvalidBandShare;
            if (!(fraction >= 0.0) or fraction > 1.0) return Error.InvalidBandShare;
            opts.band_release = fraction;
        } else if (std.mem.startsWith(u8, arg, "--touch-floor=")) {
            const fraction = std.fmt.parseFloat(f32, arg["--touch-floor=".len..]) catch
                return Error.InvalidTouchFloor;
            if (!(fraction >= 0.0) or fraction > 1.0) return Error.InvalidTouchFloor;
            opts.touch_floor = fraction;
        } else if (std.mem.startsWith(u8, arg, "--touch-rise=")) {
            const seconds = parseSeconds(arg["--touch-rise=".len..]) orelse
                return Error.InvalidTouchRise;
            if (seconds <= 0.0) return Error.InvalidTouchRise;
            opts.touch_rise_s = seconds;
        } else if (std.mem.eql(u8, arg, "--plant-a")) {
            // The shorthand the flag had when it was a switch, kept so a unit
            // file already passing it keeps starting.
            opts.plant_sources[0] = .daybird;
        } else if (std.mem.startsWith(u8, arg, "--box=")) {
            opts.box = parseBox(arg["--box=".len..]) orelse return Error.InvalidBox;
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
    for (opts.plant_sources, 0..) |maybe_chosen, plant| {
        const chosen = maybe_chosen orelse continue;
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

/// A tap window: a length in seconds, or `off` for a plant that takes none.
///
/// Zero is not a window -- a touch cannot end before the hold that starts it is
/// satisfied -- so it is refused rather than quietly read as `off`. A room that
/// wants no window says so in the word.
fn parseWindow(text: []const u8) ?touch.Window {
    if (std.mem.eql(u8, text, "off")) return .off;
    const seconds = std.fmt.parseFloat(f32, text) catch return null;
    return if (seconds > 0.0) .{ .ms = seconds * 1000.0 } else null;
}

fn parseMode(name: []const u8) ?clips.Mode {
    return std.meta.stringToEnum(clips.Mode, name);
}

/// A box by its number: `--box=3` rather than `--box=box3`, because the number
/// is what is written on the lid.
fn parseBox(text: []const u8) ?boxes.Box {
    if (text.len != 1) return null;
    const which = std.fmt.parseInt(u8, text, 10) catch return null;
    if (which < 1 or which > 5) return null;
    return @enumFromInt(which - 1);
}

fn parseModel(name: []const u8) ?touch.Model {
    if (std.mem.eql(u8, name, "deviation")) return .deviation;
    if (std.mem.eql(u8, name, "steady")) return .steady;
    if (std.mem.eql(u8, name, "learned")) return .learned;
    return null;
}

/// A floor in counts. Zero is the room asking for no floor, which is a setting
/// and not a typo -- unlike `parseCounts`, where zero would mean a threshold
/// nothing can clear. A negative move is not a move.
fn parseFloor(text: []const u8) ?i16 {
    const value = std.fmt.parseInt(i16, text, 10) catch return null;
    return if (value >= 0) value else null;
}

/// A threshold in counts. Negative is not a range, and zero would latch on
/// nothing at all, so both are refused rather than clamped.
fn parseCounts(text: []const u8) ?i16 {
    const value = std.fmt.parseInt(i16, text, 10) catch return null;
    return if (value > 0) value else null;
}

pub const usage =
    \\usage: mami_sound [PLANTS] [--device=NAME]
    \\                  [--plant-a=SOURCE] [--plant-a-mode=MODE] [--plant-a-band=LO:HI]
    \\                  [--plant-a-seconds=N] [--plant-a-retrigger=N] [--plant-a-window=N|off]
    \\                  [--plant-b=SOURCE] [--plant-b-mode=MODE] [--plant-b-band=LO:HI]
    \\                  [--plant-b-seconds=N] [--plant-b-retrigger=N] [--plant-b-window=N|off]
    \\                  [--touch-model=MODEL] [--still-range=N] [--still-release=N]
    \\                  [--still-window=SECONDS] [--band-share=FRACTION]
    \\                  [--band-release=FRACTION]
    \\                  [--counts=N] [--counts-b=N]
    \\                  [--touch-floor=FRACTION] [--touch-rise=SECONDS]
    \\                  [--capture=PATH] [--capture-seconds=N]
    \\                  [--box=N]
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
    \\--box is which of the five installations this is, 1 to 5. It picks the
    \\numbers that box's rig was measured at: the counts floor each probe needs,
    \\how far the drone's pitch spends its range, and what each plant plays.
    \\Left off, the hostname is read -- box3, box3.local and box3-pi are all
    \\box 3 -- and a machine that is none of the five runs the unmeasured
    \\defaults and says so on the loading line. Every other flag still wins over
    \\whatever the box says.
    \\
    \\--plant-a and --plant-b each name what that plant plays. Either plant
    \\takes any of them:
    \\  drone       the sensor-driven voice, generated rather than played
    \\  voicebox3   ./Voice Box 3/
    \\  voicebox5   ./Voice Box 5/
    \\  daybird     ./Day bird/
    \\  insect      ./Insect/
    \\  tradvn      ./Trad Vn Jam/
    \\  tradvn2     ./Trad Vn Jam 2/
    \\  bell        ./Bell Stems/
    \\  piano       ./EPiano Stems/
    \\Unasked, plant A is the drone and plant B is voicebox3. Bare --plant-a
    \\means --plant-a=daybird. Every source is one folder: a plant that wants
    \\two of them is two plants.
    \\
    \\Every source but one is shuffled: a touch answers with a clip the folder
    \\has not played this pass round, so a room cannot predict the next one.
    \\tradvn2 is the exception. Its folder holds one piece in numbered parts,
    \\so it is played in order -- song1, then song2, on to the last part and
    \\round to the first again -- and the numbering is read as numbers, so
    \\song10 follows song9 rather than song1. There is no flag for this: the
    \\order is a fact about what is in the folder.
    \\
    \\--plant-a-seconds and --plant-b-seconds are how long one touch plays.
    \\Zero plays the clip to its own end, which is how a source that is normally
    \\cut is uncapped, or one that normally runs long is cut. Left off, the
    \\source's own length stands: 4s for the stems, 5s for daybird and insect,
    \\and to the end for the voice boxes and both jams.
    \\
    \\--plant-a-mode and --plant-b-mode are how a plant answers a hand:
    \\  trigger  a touch sets a clip going and it runs its own length
    \\  hold     the clip sounds while the plant is held and fades when it is
    \\           let go, and the next hold picks it up where it stopped
    \\  tap      a hand that arrives and leaves again sets a clip going; one
    \\           left resting is drift or settling and starts nothing
    \\Left off, a plant triggers. The drone always holds and takes no mode.
    \\
    \\--plant-a-retrigger and --plant-b-retrigger are how long a clip is
    \\protected from the next touch, counted from when it started. A touch
    \\inside it is ignored and the clip keeps playing; a touch past it moves the
    \\plant on to a different clip. Left off, 10s for the voice boxes and 5s
    \\for everything else. The drone takes neither flag.
    \\
    \\--plant-a-window and --plant-b-window are how long a touch may last and
    \\still count, in seconds, under the deviation model. With a window the plant
    \\wants a tap: a hand that arrives and stays is read as drift or as somebody
    \\leaning on the plant, and is ignored until it lets go. `off` takes the
    \\window away, and the plant then answers a hand for as long as it is there.
    \\Left off, plant B gets a second and plant A gets none, which is what the
    \\rig was measured on. A plant on --plant-X-mode=hold drops its window
    \\whatever this says: a held voice has to know the hand is still there.
    \\The steady model takes no window at all.
    \\
    \\--touch-model picks what the detector asks each probe:
    \\  deviation  how far the probe has moved from its own recent past
    \\  steady     how tightly the last second of readings clusters, at any level
    \\  learned    which of the two levels the probe visits it is sitting at now
    \\
    \\`learned` is told nothing and measures nothing in advance. A plant lives at
    \\one level and a hand takes it to another, so over minutes the probe's own
    \\history holds two clusters; the model calls the one it keeps returning to
    \\rest, and a touch is the window spending itself past the halfway line. That
    \\covers a rig resting at nought and boosted to 25000, one resting at 25000
    \\and pulled to ground, and one resting mid-range thrown either way, without
    \\--plant-a-band or a trip to the room. It wants about six seconds of nobody
    \\touching after start, and answers the first hand on a plainer question
    \\while it waits to see what a touch on this rig looks like.
    \\Use `steady` on a rig whose probes clamp to a level you cannot predict.
    \\
    \\--touch-floor is how far up the pitch range a touch starts, as a fraction
    \\of it, and --touch-rise is how long a held touch takes to climb from there
    \\to the top. A rise turns the drone's pitch into the length of the hold
    \\rather than the size of the reading.
    \\
    \\The learned model takes both without being asked, because it cannot hand a
    \\pitch to the reading: its deviation is the gap between the window's middle
    \\and rest, and a middle is a median, so on a probe living at two levels the
    \\reading offers two pitches and no more. These flags are how to say other
    \\numbers, or to ask for the ramp on a model that did not choose it.
    \\
    \\--still-range and --still-release are that model's two thresholds, in
    \\counts: at or below the range the probe is being held, at or above the
    \\release the touch is over, and between them nothing changes. Defaults are
    \\32 and 512. A hand actually holds a probe to about three counts; 32 is
    \\room for the dropouts this rig throws, and --still-range=10 is the number
    \\to use once the conversion reads come back clean.
    \\
    \\--band-share is how much of the window has to be past the line before the
    \\learned model calls it a hand. Larger is harder to reach and harder to
    \\latch by accident; the number wants to sit between what the rig scores
    \\untouched and what it scores held, and `zig build replay -- PATH --sweep`
    \\is what prints both. The default is 0.6, which is above what one rig's
    \\hands actually reach -- a probe scoring 0.556 held answers nobody until
    \\this is lowered.
    \\
    \\--band-release is the share at or below which the touch is over. It sits
    \\under --band-share, and between the two nothing changes: a hand whose
    \\share lands on the line then holds rather than latching and releasing on
    \\alternate windows. The default is 0.5.
    \\
    \\--counts and --counts-b are how big a move a touch has to be on each probe,
    \\in the counts the status line's l0 and l1 show. `deviation` only.
    \\
    \\The score on its own cannot answer this: it divides a move by how much the
    \\probe normally wanders, so a probe that goes quiet scores enormous
    \\deviations on a move that is, in counts, nothing at all. This rig reads
    \\plant A at 0 or 1 untouched and about 25000 under a hand, so its floor is
    \\set well under the whole excursion -- a hand that only half connects still
    \\counts. Zero asks for no floor and puts a probe back on the score alone;
    \\left off, the measured default stands.
    \\
    \\--plant-a-band and --plant-b-band say where a hand puts that plant's probe,
    \\as LO:HI in counts. One each, because the two probes do not sit at the same
    \\place: on this rig a hand puts one near 660 and the other near 25000.
    \\
    \\Given a band, steady asks one plain question -- how much of the last window
    \\was the probe in there -- and calls three fifths or more a hand. The window
    \\is 400 readings, so three fifths is 240 of them where a hand puts it. That
    \\survives a rig throwing rails through a perfectly good touch, and needs no
    \\untouched stretch after power-on to learn anything from, so it cannot learn
    \\the wrong thing because somebody had hold of a plant while it was starting.
    \\The deviation model uses the band differently: it asks how far a probe
    \\moved and not where it went, so a slam to the end of the range scores as
    \\high as a hand, and a band throws those out.
    \\
    \\A band is the detector's answer to "is somebody there", so it decides for
    \\trigger and hold alike, and for the guard between one touch and the next.
    \\Left off, steady learns rest and calls a touch stillness a hundred counts
    \\away from it, and deviation fires on any large move. Set it once you have
    \\watched the rig: the status line's l0 and l1 are the levels to read it off.
    \\
    \\--counts and --counts-b are how big a move a touch has to be on each
    \\probe, in the counts the status line's l0 and l1 show. `deviation` only.
    \\
    \\The score on its own cannot answer this: it divides a move by how much
    \\the probe normally wanders, and a probe that goes quiet scores enormous
    \\deviations on a move that is, in counts, nothing. On this rig plant B
    \\reads the supply rail to within seventy counts while about one poll in
    \\fifteen drops toward ground, and the density of those dropouts alone
    \\moves its average far enough to fire. Defaults are 4000 for plant A,
    \\which a hand moves about 9000, and 10000 for plant B, which a hand moves
    \\about 24000. Zero asks for no floor and puts a probe back on the score
    \\alone; left off, the measured default stands.
    \\
    \\--still-window is how long a stretch of readings that range is measured
    \\over, in seconds, and how many readings a band is counted over. It buys the
    \\answer's stability rather than its speed: shortening it to a quarter of a
    \\second finds one hand fifteen times over rather than finding more hands.
    \\Default 1.161, which is 400 readings at this rig's poll rate. `zig build
    \\replay -- CAPTURE --sweep` picks all three from a recording rather than
    \\from the room.
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
    try std.testing.expectEqual(source.Source.insect, opts.plant_sources[0].?);
    try std.testing.expectEqual(source.Source.tradvn, opts.plant_sources[1].?);
}

test "left unsaid, a plant's source is the box's to answer" {
    // Not `.drone` and `.voicebox3` any more: those were a plain default no
    // room could tell apart from asking for them on purpose. `null` leaves
    // the box's own preset standing.
    const opts = try parse(&.{});
    try std.testing.expect(opts.plant_sources[0] == null);
    try std.testing.expect(opts.plant_sources[1] == null);
    try std.testing.expect(opts.plant_seconds[0] == null);
    try std.testing.expect(opts.plant_retrigger[1] == null);
}

test "either plant accepts any source, including the drone" {
    try std.testing.expectEqual(
        source.Source.drone,
        (try parse(&.{"--plant-b=drone"})).plant_sources[1].?,
    );
    try std.testing.expectEqual(
        source.Source.bell,
        (try parse(&.{"--plant-a=bell"})).plant_sources[0].?,
    );
}

test "bare --plant-a still means the bird calls" {
    // A unit file already passing the flag keeps starting.
    const opts = try parse(&.{"--plant-a"});
    try std.testing.expectEqual(source.Source.daybird, opts.plant_sources[0].?);
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
    // Checked only when the room named the drone outright -- a bare mode flag
    // says nothing about the source, which unsaid is now the box's to answer.
    try std.testing.expectError(
        Error.ModeOnDrone,
        parse(&.{ "--plant-a=drone", "--plant-a-mode=hold" }),
    );
}

test "the stillness window can be shortened from the command line" {
    const opts = try parse(&.{"--still-window=0.25"});
    try std.testing.expectEqual(@as(f32, 250.0), opts.still_window_ms.?);
    try std.testing.expect((try parse(&.{})).still_window_ms == null);
}

test "the drone's start and climb can be set from the command line" {
    // The two numbers that decide what a touch sounds like on the learned rig,
    // where the reading cannot carry a pitch and the hold has to.
    const opts = try parse(&.{ "--touch-floor=0.6", "--touch-rise=4" });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), opts.touch_floor.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), opts.touch_rise_s.?, 0.0001);

    const bare = try parse(&.{});
    try std.testing.expect(bare.touch_floor == null);
    try std.testing.expect(bare.touch_rise_s == null);
}

test "a floor outside the range is refused rather than clamped" {
    // A floor is a fraction of the pitch range. Silently clamping 6 to 1 would
    // hand back a drone pinned at the top and no way to tell why.
    try std.testing.expectError(Error.InvalidTouchFloor, parse(&.{"--touch-floor=1.5"}));
    try std.testing.expectError(Error.InvalidTouchFloor, parse(&.{"--touch-floor=-0.1"}));
    try std.testing.expectError(Error.InvalidTouchFloor, parse(&.{"--touch-floor=up"}));
}

test "a rise of no time at all is refused" {
    // Zero would be a touch that is at the top the instant it is called, which
    // is the switch this was added to stop being.
    try std.testing.expectError(Error.InvalidTouchRise, parse(&.{"--touch-rise=0"}));
    try std.testing.expectError(Error.InvalidTouchRise, parse(&.{"--touch-rise=-2"}));
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
        "--counts=",
        "--counts-b=",
        "--touch-floor=",
        "--touch-rise=",
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

test "each plant's tap window is set, or taken away, on the command line" {
    // The preset's window is what makes plant B want a tap rather than a hand
    // that stays. A room whose hands stay has to be able to say so without a
    // rebuild.
    const opts = try parse(&.{ "--plant-a-window=0.5", "--plant-b-window=off" });
    try std.testing.expectEqual(@as(f32, 500.0), opts.plant_window[0].?.ms);
    try std.testing.expectEqual(touch.Window.off, opts.plant_window[1].?);

    // Unasked, the preset's answer stands rather than being overwritten with a
    // default this layer invented.
    const bare = try parse(&.{});
    try std.testing.expect(bare.plant_window[0] == null);
    try std.testing.expect(bare.plant_window[1] == null);
}

test "a window of no length is refused rather than read as none" {
    // Zero would be a touch that had to end before the hold that starts it was
    // satisfied, which no gesture can do. `off` is the word for no window.
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-a-window=0"}));
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-b-window=-1"}));
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-b-window="}));
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-a-window=none"}));
}

test "each plant takes its own band, both ends, low first" {
    // The two probes do not sit at the same place, so one band for both would
    // serve neither.
    const opts = try parse(&.{ "--plant-a-band=650:660", "--plant-b-band=24000:26000" });
    try std.testing.expectEqual(@as(i16, 650), opts.plant_band[0].?[0]);
    try std.testing.expectEqual(@as(i16, 660), opts.plant_band[0].?[1]);
    try std.testing.expectEqual(@as(i16, 24000), opts.plant_band[1].?[0]);
    try std.testing.expectEqual(@as(i16, 26000), opts.plant_band[1].?[1]);

    // And one plant may have a band while the other has none.
    const only_b = try parse(&.{"--plant-b-band=24000:26000"});
    try std.testing.expect(only_b.plant_band[0] == null);
    try std.testing.expect(only_b.plant_band[1] != null);

    try std.testing.expect((try parse(&.{})).plant_band[0] == null);
}

test "half a band, or one the wrong way round, is refused" {
    // A band with one end open is a threshold wearing a band's name, and one
    // that runs backwards can never contain anything.
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--plant-a-band=650"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--plant-b-band=660:650"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--plant-a-band=650:"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--plant-b-band=a:b"}));
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

test "a plant can be asked for a tap" {
    // The third gesture. It was in the detector all along and reachable only by
    // being plant B, which is how a room got a plant that ignored a hand.
    try std.testing.expectEqual(
        clips.Mode.tap,
        (try parse(&.{"--plant-b-mode=tap"})).plant_mode[1].?,
    );
    // On plant A too, which the drone refuses -- so it is asked of a folder.
    try std.testing.expectEqual(
        clips.Mode.tap,
        (try parse(&.{ "--plant-a=bell", "--plant-a-mode=tap" })).plant_mode[0].?,
    );
}

test "the usage names every mode a plant can be given" {
    // A mode the usage does not mention is a mode nobody asks for, which is how
    // plant B came to answer taps in a room that rested its hands.
    inline for (@typeInfo(clips.Mode).@"enum".fields) |field| {
        if (std.mem.indexOf(u8, usage, field.name) == null) {
            std.debug.print("the usage omits the {s} mode\n", .{field.name});
            return error.ModeMissingFromUsage;
        }
    }
}

test "each probe's counts floor can be set from the room" {
    const opts = try parse(&.{ "--counts=2500", "--counts-b=15000" });
    try std.testing.expectEqual(@as(i16, 2500), opts.counts.?);
    try std.testing.expectEqual(@as(i16, 15000), opts.counts_bc.?);

    // Left off, the measured preset stands rather than being overwritten with
    // a number nobody chose.
    const quiet = try parse(&.{});
    try std.testing.expect(quiet.counts == null);
    try std.testing.expect(quiet.counts_bc == null);
}

test "a floor of zero is the room asking for no floor" {
    // Different from leaving the flag off: off keeps the preset, zero puts the
    // probe back on the score alone. `parseCounts` refuses zero for the
    // thresholds, where it would mean a line nothing can cross.
    const opts = try parse(&.{ "--counts=0", "--counts-b=0" });
    try std.testing.expectEqual(@as(i16, 0), opts.counts.?);
    try std.testing.expectEqual(@as(i16, 0), opts.counts_bc.?);
}

test "a floor that is not a move is refused" {
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--counts=-1"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--counts-b=lots"}));
    try std.testing.expectError(Error.InvalidStillThreshold, parse(&.{"--counts="}));
}

test "one probe's floor may be set without the other's" {
    const only_a = try parse(&.{"--counts=3000"});
    try std.testing.expectEqual(@as(i16, 3000), only_a.counts.?);
    try std.testing.expect(only_a.counts_bc == null);

    const only_b = try parse(&.{"--counts-b=12000"});
    try std.testing.expect(only_b.counts == null);
    try std.testing.expectEqual(@as(i16, 12000), only_b.counts_bc.?);
}

test "a room names its box on the command line" {
    const opts = try parse(&.{"--box=3"});
    try std.testing.expectEqual(boxes.Box.box3, opts.box.?);
}

test "no --box is the room not having said, which is not the same as box 1" {
    const opts = try parse(&.{});
    try std.testing.expect(opts.box == null);
}

test "a box that does not exist is refused rather than rounded" {
    // Six boxes would be a typo and zero would be a misreading of the range.
    // Either one silently answered with box1's floors is a rig running numbers
    // measured somewhere else, which is the fault this whole directory exists
    // to stop.
    try std.testing.expectError(Error.InvalidBox, parse(&.{"--box=6"}));
    try std.testing.expectError(Error.InvalidBox, parse(&.{"--box=0"}));
    try std.testing.expectError(Error.InvalidBox, parse(&.{"--box="}));
    try std.testing.expectError(Error.InvalidBox, parse(&.{"--box=two"}));
}

test "the model that learns the rig can be asked for by name" {
    const opts = try parse(&.{"--touch-model=learned"});
    try std.testing.expectEqual(touch.Model.learned, opts.model.?);
}

test "the usage names every model the parser takes" {
    // The message that offers them has fallen behind the code once already.
    inline for (@typeInfo(touch.Model).@"enum".fields) |field| {
        try std.testing.expect(std.mem.indexOf(u8, usage, field.name) != null);
    }
}

test "the share a touch must reach can be set on the command line" {
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.52),
        (try parse(&.{"--band-share=0.52"})).band_share.?,
        0.0001,
    );

    // Unset leaves the preset alone, which is what every other threshold does.
    try std.testing.expect((try parse(&.{})).band_share == null);
}

test "a share outside nought to one is a typo, not a setting" {
    try std.testing.expectError(Error.InvalidBandShare, parse(&.{"--band-share=1.4"}));
    try std.testing.expectError(Error.InvalidBandShare, parse(&.{"--band-share=-0.1"}));
    try std.testing.expectError(Error.InvalidBandShare, parse(&.{"--band-share=most"}));
    // Nought is not a setting here: no window can be less than nothing past
    // the line, so a share of nought latches on an empty room forever.
    try std.testing.expectError(Error.InvalidBandShare, parse(&.{"--band-share=0"}));
}

test "the share that ends a touch is its own flag" {
    const opts = try parse(&.{ "--band-share=0.55", "--band-release=0.40" });
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), opts.band_share.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.40), opts.band_release.?, 0.0001);

    // Nought is a setting here, unlike the share: it says the touch ends only
    // when nothing at all is left past the line.
    try std.testing.expect((try parse(&.{"--band-release=0"})).band_release.? == 0.0);
    try std.testing.expectError(Error.InvalidBandShare, parse(&.{"--band-release=1.2"}));
}
