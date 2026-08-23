//! Command line: which plants play, and what plant A sounds like.
//!
//! Parsing is pure and works on a slice of arguments, so every flag can be
//! tested without a process.

const std = @import("std");
const select = @import("core/select.zig");
const noise = @import("core/noise.zig");
const touch = @import("core/touch.zig");

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
    InvalidTouchCounts,
    UnknownTouchModel,
    InvalidTouchBand,
    InvalidTouchJitter,
    InvalidTouchDrop,
    InvalidTouchWindow,
    InvalidPitchSpan,
    InvalidPitchJump,
    InvalidPitchGlide,
    InvalidPitchRelease,
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
    /// What question the probes are asked. The rigs need opposite ones: see
    /// `touch.Model`.
    touch_model: touch.Model = .deviation,
    /// Where a clamped probe reads, how far it may move between readings and
    /// still count as clamped, and how long the stillness must be gone before
    /// the touch is. All three are `steady` only.
    touch_band_lo: ?i16 = touch.default_band_lo,
    touch_band_hi: ?i16 = touch.default_band_hi,
    touch_jitter: i16 = touch.default_jitter,
    /// Probe BC's own band. `null` puts it in A's. On the floating rig a hand
    /// on plant A holds its probe at 650-750 while a hand on plant B holds BC
    /// at about 1, so one band cannot serve both.
    touch_band_lo_bc: ?i16 = null,
    touch_band_hi_bc: ?i16 = null,
    touch_drop_ms: f32 = touch.default_drop_ms,
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
    /// A move in counts that probe BC must also clear before it counts as
    /// touched. `null` asks the score alone.
    touch_counts_bc: ?i16 = null,
    /// How long a touch on BC may last and still count as one. `null` latches
    /// instead, so BC is on for as long as a hand is on it.
    touch_window_bc_ms: ?f32 = null,
    /// The deviation that maps to the top of plant A's pitch range.
    pitch_span: i16 = noise.default_span,
    /// How much of the distance to a new pitch is closed at once, and how long
    /// the rest takes. Between them, how sharply plant A answers.
    pitch_jump: f32 = noise.default_jump,
    pitch_glide_s: f32 = noise.default_glide_s,
    /// How long the fall back to the bottom of the range takes once nobody is
    /// touching. `null` gives it the glide's.
    pitch_release_s: ?f32 = noise.default_release_s,
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
        } else if (std.mem.startsWith(u8, arg, "--touch-model=")) {
            const name = arg["--touch-model=".len..];
            opts.touch_model = std.meta.stringToEnum(touch.Model, name) orelse
                return Error.UnknownTouchModel;
        } else if (std.mem.startsWith(u8, arg, "--touch-band=")) {
            const text = arg["--touch-band=".len..];
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse
                return Error.InvalidTouchBand;
            const lo = std.fmt.parseInt(i16, text[0..colon], 10) catch
                return Error.InvalidTouchBand;
            const hi = std.fmt.parseInt(i16, text[colon + 1 ..], 10) catch
                return Error.InvalidTouchBand;
            // A band the wrong way round, or one no reading can be inside, is
            // a probe that can never be touched.
            if (lo >= hi) return Error.InvalidTouchBand;
            opts.touch_band_lo = lo;
            opts.touch_band_hi = hi;
        } else if (std.mem.startsWith(u8, arg, "--touch-band-bc=")) {
            const text = arg["--touch-band-bc=".len..];
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse
                return Error.InvalidTouchBand;
            const lo = std.fmt.parseInt(i16, text[0..colon], 10) catch
                return Error.InvalidTouchBand;
            const hi = std.fmt.parseInt(i16, text[colon + 1 ..], 10) catch
                return Error.InvalidTouchBand;
            if (lo >= hi) return Error.InvalidTouchBand;
            opts.touch_band_lo_bc = lo;
            opts.touch_band_hi_bc = hi;
        } else if (std.mem.startsWith(u8, arg, "--touch-jitter=")) {
            const jitter = std.fmt.parseInt(i16, arg["--touch-jitter=".len..], 10) catch
                return Error.InvalidTouchJitter;
            if (jitter < 0) return Error.InvalidTouchJitter;
            opts.touch_jitter = jitter;
        } else if (std.mem.startsWith(u8, arg, "--touch-drop=")) {
            const drop = std.fmt.parseFloat(f32, arg["--touch-drop=".len..]) catch
                return Error.InvalidTouchDrop;
            if (!(drop >= 0.0) or drop > 5000.0) return Error.InvalidTouchDrop;
            opts.touch_drop_ms = drop;
        } else if (std.mem.startsWith(u8, arg, "--touch-counts-bc=")) {
            const counts = std.fmt.parseInt(i16, arg["--touch-counts-bc=".len..], 10) catch
                return Error.InvalidTouchCounts;
            if (counts <= 0) return Error.InvalidTouchCounts;
            opts.touch_counts_bc = counts;
        } else if (std.mem.startsWith(u8, arg, "--touch-window-bc=")) {
            const window = std.fmt.parseFloat(f32, arg["--touch-window-bc=".len..]) catch
                return Error.InvalidTouchWindow;
            // Under the hold nothing could ever fire; past ten seconds the
            // window is no longer telling a tap from a hand left resting.
            if (!(window > 0.0) or window > 10000.0) return Error.InvalidTouchWindow;
            opts.touch_window_bc_ms = window;
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
        } else if (std.mem.startsWith(u8, arg, "--pitch-release=")) {
            const release = std.fmt.parseFloat(f32, arg["--pitch-release=".len..]) catch
                return Error.InvalidPitchRelease;
            if (!(release > 0.0) or release > 60.0) return Error.InvalidPitchRelease;
            opts.pitch_release_s = release;
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
    \\                 [--touch=probes|always|script|motion]
    \\                 [--touch-model=deviation|steady] [--touch-band=LO:HI]
    \\                 [--touch-band-bc=LO:HI] [--touch-jitter=COUNTS]
    \\                 [--touch-drop=MS] [--touch-level=Z]
    \\                 [--touch-hold=MS] [--touch-average=MS] [--touch-baseline=S]
    \\                 [--touch-settle=MS] [--touch-level-bc=Z] [--touch-hold-bc=MS]
    \\                 [--touch-counts-bc=COUNTS] [--touch-window-bc=MS]
    \\                 [--pitch-span=COUNTS] [--pitch-jump=FRACTION]
    \\                 [--pitch-glide=SECONDS] [--pitch-release=SECONDS]
    \\                 [--log-touch=PATH]
    \\                 [--interrupt=SECONDS] [--device=NAME]
    \\
    \\PLANTS is the digits of the plants to play, in any order:
    \\  1  plant A, the sensor-driven voice
    \\  2  plant B, an interview
    \\
    \\B draws one clip from ./interview files/, chosen at random when the program
    \\starts, so a run is different from the last one. Drop a recording into a
    \\folder to put it in the rotation; mp3, wav, ogg and flac are all read.
    \\The name of what was
    \\drawn is printed at start up.
    \\
    \\--voice selects what plant A sounds like. Both take their pitch from
    \\the probe across AIN0 and AIN1, and nothing else does:
    \\  drone  filtered noise, pitch following the probe (default)
    \\  flute  recorded flute notes, replayed at the probe's pitch
    \\  beep   a bare synthesized sine at the probe's pitch
    \\
    \\--touch decides when a plant is awake and sounding:
    \\  probes  the probes themselves decide (default)
    \\  always  every plant, from the first block on
    \\  script  the built-in timeline: A holds, B taps inside it
    \\  motion  one GPIO motion sensor per plant
    \\
    \\--touch-model is which question the probes are asked, and the two rigs
    \\this has run on need opposite ones:
    \\  deviation  how far has the probe moved from its own recent past
    \\  steady     has the probe stopped moving, at any level or in a band
    \\
    \\On the first rig a probe rests somewhere and a touch moves it, so how far
    \\it has moved is the whole answer. On the second the electrode floats: with
    \\nobody on it the reading flails over the whole range and slams the rails
    \\from one poll to the next, and a hand clamps it to about 660 counts and
    \\holds it there. There the touch is the quiet, and a rolling median of the
    \\flailing is a number about nothing — which is why `deviation` on that rig
    \\hears nothing at all, however low the threshold is set.
    \\
    \\--touch-jitter is how far a probe may move between readings and still
    \\count as held, 8 counts by default. Judged on the raw reading rather than
    \\on the average: averaging is what destroys the stillness that is the
    \\signal here.
    \\
    \\--touch-band is optional, and left out any level will do so long as it
    \\holds still. That is usually what is wanted, because the two probes clamp
    \\to quite different levels — plant A's to 650-750, plant B's to about 1 —
    \\and a level that is a touch on one is the untouched reading of the other.
    \\
    \\Set a band to widen the margin: untouched readings are then thrown out on
    \\level before stillness is asked about, leaving only a probe parked inside
    \\the band to argue with. --touch-band-bc gives BC a band of its own, and
    \\left out BC is asked A's.
    \\
    \\With no band, --touch-hold is the only thing telling a held probe from an
    \\untouched one that has gone quiet for a moment, and it wants sizing from
    \\a capture. In `testdata/touch-floating.txt` an untouched probe holds still
    \\for as long as eight polls at a stretch and the shortest real touch holds
    \\for twelve, so the hold belongs between them: about 30 ms at 344 polls a
    \\second. The 100 ms default is a deviation-model number and is long enough
    \\here to drop a real touch on the floor.
    \\
    \\--touch-drop is how long the stillness must be gone before the touch is,
    \\90 ms by default, against --touch-hold on the way in. Longer on purpose:
    \\contact drops out for a few polls in the middle of a real touch, and
    \\releasing on that ends a clip, or with --touch-window-bc starts one.
    \\
    \\Under `steady` plant A's pitch is where in the band the probe sits rather
    \\than how far it has moved, so --pitch-span wants to be about the width of
    \\the band. That is a few counts of travel against a jitter allowance of
    \\eight, so expect the pitch to wander inside the band on its own.
    \\--touch-counts-bc, --touch-baseline and --touch-settle are all
    \\deviation-model ideas and do nothing here.
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
    \\--touch-counts-bc is a second threshold BC must also clear, in counts from
    \\its own rest rather than in deviations. The score divides by how much the
    \\probe normally wanders, so a probe that has gone quiet scores enormous
    \\deviations on a move that is, in counts, nothing at all; this is the
    \\threshold that says how big a move has to be in the units the probe
    \\actually reads. Left out, the score decides alone.
    \\
    \\--touch-window-bc is how long a touch on BC may last and still count as
    \\one. With it, BC starts a clip on the *end* of a touch rather than on the
    \\start: the probe has to go past the threshold and come back inside the
    \\window, which is what a tap looks like. An excursion that never comes back
    \\is a hand left resting, a drifting probe or wiring still settling, and it
    \\starts nothing, and nothing else can start until the probe has been back
    \\at rest. The clock starts once the hold is satisfied, so the whole gesture
    \\may last --touch-hold-bc plus this. Left out, BC latches as before and is
    \\on for as long as a hand is on it.
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
    \\--pitch-release is how long the fall back to the bottom of the range takes
    \\once nobody is touching, and it is only the way home: a fall while a hand
    \\is still on the plant is the plant answering a lighter grip, and keeps the
    \\glide. A glide slow enough to be expressive under a hand leaves the drone
    \\sinking for seconds after the room has emptied, which reads as the plant
    \\not having noticed. Left out, the fall takes the glide.
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
        select.Selection{ true, true },
        (try parse(&.{"12"})).plants,
    );
}

test "voice can be chosen, in either order" {
    const a = try parse(&.{ "1", "--voice=flute" });
    try testing.expectEqual(Voice.flute, a.voice);
    try testing.expectEqual(select.Selection{ true, false }, a.plants);

    const b = try parse(&.{ "--voice=flute", "1" });
    try testing.expectEqual(Voice.flute, b.voice);
    try testing.expectEqual(select.Selection{ true, false }, b.plants);
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

test "the steady model and its band are parsed" {
    const opts = try parse(&.{ "--touch-model=steady", "--touch-band=550:800", "--touch-jitter=12", "--touch-drop=120" });
    try testing.expectEqual(touch.Model.steady, opts.touch_model);
    try testing.expectEqual(@as(i16, 550), opts.touch_band_lo);
    try testing.expectEqual(@as(i16, 800), opts.touch_band_hi);
    try testing.expectEqual(@as(i16, 12), opts.touch_jitter);
    try testing.expectEqual(@as(f32, 120.0), opts.touch_drop_ms);
}

test "the deviation model is what a run gets when it asks for nothing" {
    const opts = try parse(&.{});
    try testing.expectEqual(touch.Model.deviation, opts.touch_model);
    try testing.expectEqual(touch.default_band_lo, opts.touch_band_lo);
    try testing.expectEqual(touch.default_jitter, opts.touch_jitter);
    try testing.expectEqual(touch.default_drop_ms, opts.touch_drop_ms);
}

test "no band is asked for by default, so any steady level is a touch" {
    const opts = try parse(&.{"--touch-model=steady"});
    try testing.expectEqual(@as(?i16, null), opts.touch_band_lo);
    try testing.expectEqual(@as(?i16, null), opts.touch_band_hi);
    try testing.expectEqual(@as(?i16, null), opts.touch_band_lo_bc);
}

test "BC can be given a band of its own" {
    const opts = try parse(&.{ "--touch-band=650:750", "--touch-band-bc=-5:5" });
    try testing.expectEqual(@as(i16, 650), opts.touch_band_lo);
    try testing.expectEqual(@as(i16, 750), opts.touch_band_hi);
    try testing.expectEqual(@as(?i16, -5), opts.touch_band_lo_bc);
    try testing.expectEqual(@as(?i16, 5), opts.touch_band_hi_bc);
    // Left out, BC is put in A's, which `touch` reads as null.
    const shared = try parse(&.{"--touch-band=650:750"});
    try testing.expectEqual(@as(?i16, null), shared.touch_band_lo_bc);
}

test "nonsense on the steady knobs is refused" {
    try testing.expectError(Error.UnknownTouchModel, parse(&.{"--touch-model=quiet"}));
    // A band the wrong way round can never contain a reading.
    try testing.expectError(Error.InvalidTouchBand, parse(&.{"--touch-band=800:200"}));
    try testing.expectError(Error.InvalidTouchBand, parse(&.{"--touch-band=600"}));
    try testing.expectError(Error.InvalidTouchBand, parse(&.{"--touch-band=six:hundred"}));
    try testing.expectError(Error.InvalidTouchJitter, parse(&.{"--touch-jitter=-1"}));
    try testing.expectError(Error.InvalidTouchBand, parse(&.{"--touch-band-bc=5:-5"}));
    try testing.expectError(Error.InvalidTouchBand, parse(&.{"--touch-band-bc=zero"}));
    try testing.expectError(Error.InvalidTouchDrop, parse(&.{"--touch-drop=9000"}));
}

test "BC's counts gate and window are parsed" {
    const opts = try parse(&.{ "--touch-counts-bc=1500", "--touch-window-bc=1000" });
    try testing.expectEqual(@as(?i16, 1500), opts.touch_counts_bc);
    try testing.expectEqual(@as(?f32, 1000.0), opts.touch_window_bc_ms);
}

test "BC latches as before when neither the counts gate nor the window is asked for" {
    const opts = try parse(&.{"--touch-level-bc=20"});
    try testing.expectEqual(@as(?i16, null), opts.touch_counts_bc);
    try testing.expectEqual(@as(?f32, null), opts.touch_window_bc_ms);
}

test "a counts gate or a window outside its range is refused" {
    try testing.expectError(Error.InvalidTouchCounts, parse(&.{"--touch-counts-bc=0"}));
    try testing.expectError(Error.InvalidTouchCounts, parse(&.{"--touch-counts-bc=-5"}));
    try testing.expectError(Error.InvalidTouchCounts, parse(&.{"--touch-counts-bc=soon"}));
    // Zero would be a window nothing could ever come back inside.
    try testing.expectError(Error.InvalidTouchWindow, parse(&.{"--touch-window-bc=0"}));
    try testing.expectError(Error.InvalidTouchWindow, parse(&.{"--touch-window-bc=20000"}));
}

test "plant A's fall home can be shortened without touching its rise" {
    const opts = try parse(&.{ "--pitch-glide=4", "--pitch-release=0.5" });
    try testing.expectEqual(@as(f32, 4.0), opts.pitch_glide_s);
    try testing.expectEqual(@as(?f32, 0.5), opts.pitch_release_s);
    // Left out, the fall takes the glide, which `noise` reads as null.
    try testing.expectEqual(@as(?f32, null), (try parse(&.{"--pitch-glide=4"})).pitch_release_s);
    try testing.expectError(Error.InvalidPitchRelease, parse(&.{"--pitch-release=0"}));
    try testing.expectError(Error.InvalidPitchRelease, parse(&.{"--pitch-release=120"}));
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
