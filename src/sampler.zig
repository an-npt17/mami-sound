//! Plant A's flute voice: a pitched multisample player.
//!
//! The ECG reading picks a target frequency exactly as the drone does. Instead of
//! filtering noise to that pitch, this finds the recorded note nearest the
//! target and replays it at a fractional rate so it lands on the target exactly.
//! Neighbouring recordings sit two to four semitones apart, so the stretch never
//! exceeds about two semitones and the flute still sounds like a flute.
//!
//! Nothing here knows it is a flute. Point it at another set of `{ path, f0 }`
//! entries and it plays that instrument instead.

const std = @import("std");
const decode = @import("decode.zig");

/// One recorded note.
pub const Sample = struct {
    path: []const u8,
    /// Measured, not parsed from the filename: this set's names are two octaves
    /// below the pitch they actually sound.
    f0: f32,
};

pub const flute_dir = "Flute Clean";

/// Frequencies measured by harmonic product spectrum over the sustain of each
/// file. The set is tuned 15-45 cents flat of A440; these are what it plays,
/// not what it is named.
pub const flute = [_]Sample{
    .{ .path = "FluteClean_C2.wav", .f0 = 259.24 },
    .{ .path = "FluteClean_D2.wav", .f0 = 289.69 },
    .{ .path = "FluteClean_F#2.wav", .f0 = 363.37 },
    .{ .path = "FluteClean_A2.wav", .f0 = 427.80 },
    .{ .path = "FluteClean_C3.wav", .f0 = 510.74 },
    .{ .path = "FluteClean_D3.wav", .f0 = 576.52 },
    .{ .path = "FluteClean_F#3.wav", .f0 = 732.30 },
    .{ .path = "FluteClean_A#3.wav", .f0 = 921.22 },
    .{ .path = "FluteClean_C4.wav", .f0 = 1034.27 },
    .{ .path = "FluteClean_D4.wav", .f0 = 1166.66 },
    .{ .path = "FluteClean_F#4.wav", .f0 = 1480.41 },
    .{ .path = "FluteClean_A#4.wav", .f0 = 1859.59 },
};

/// Kept before the loop point so a fresh touch hears the breath of the attack.
const attack_seconds: f32 = 0.4;

/// Tail-into-head crossfade that makes the loop region wrap without a step.
const loop_fade_seconds: f32 = 0.04;

/// Every recording is brought to this RMS. The raw set spans 0.305 to 0.551,
/// a 5 dB spread that would step in loudness at every zone crossing.
const target_rms: f32 = 0.25;

/// Time constant of the pitch smoother, matching the drone voice: this is what
/// turns a per-block sensor reading into a glide.
const smooth_tau_s: f32 = 1.0;

/// Gate fade length, long enough to avoid a click at touch and release.
const gate_ms: f32 = 150.0;

/// How far a new touch jumps toward the reading it finds, before the smoother
/// takes over for the rest.
///
/// The glide is the point of the piece, but at the moment of a touch it is the
/// wrong shape: the pitch sets off from wherever the last touch left it and
/// takes over a second to arrive, so the plant reads as not having answered.
/// Jumping the whole way would answer and then sit still. Three quarters is
/// enough to hear as a response, and leaves an audible settle behind it.
const onset_jump: f32 = 0.75;

/// Crossfade between two recordings when the target moves into a new zone.
const zone_fade_ms: f32 = 50.0;

/// How much closer a neighbour must be before the voice switches to it. Stops
/// a target sitting on a boundary from flickering between two recordings.
const hysteresis_cents: f32 = 30.0;

/// Samples compared when lining an incoming recording up with the outgoing
/// one. Long enough to span three periods of the lowest note in the set.
const align_window: usize = 512;

/// Headroom so three simultaneous voices rarely reach the clamp.
const voice_gain: f32 = 0.4;

pub const Error = error{
    /// A recording was shorter than the attack region it has to provide.
    SampleTooShort,
    /// The set was empty, so there is nothing to play.
    NoSamples,
} || std.mem.Allocator.Error;

/// A recording laid out for playback: the attack, followed by a loop region
/// whose end has been folded over its start. Reading past the end and
/// subtracting the loop length lands back at `loop_start` with no step, so one
/// float position covers the whole life of the note.
pub const Prepared = struct {
    buf: []f32,
    loop_start: usize,
    f0: f32,

    pub fn loopLen(self: Prepared) usize {
        return self.buf.len - self.loop_start;
    }
};

/// Bring `samples` to the shared RMS. Silence is left alone.
fn normalizeRms(samples: []f32) void {
    var sum: f64 = 0.0;
    for (samples) |s| sum += @as(f64, s) * @as(f64, s);
    const rms = @sqrt(sum / @as(f64, @floatFromInt(samples.len)));
    if (rms <= 0.0) return;

    const gain: f32 = @floatCast(target_rms / rms);
    for (samples) |*s| s.* *= gain;
}

/// The loop length, at most `period` shorter than the longest one available,
/// whose end matches the start of the loop region most closely. Scored by
/// normalized correlation so a loud stretch cannot win on level alone.
fn bestLoopLen(raw: []const f32, attack: usize, fade: usize, period: usize) usize {
    const longest = raw.len - attack - fade;
    const head = raw[attack..][0..fade];

    var head_energy: f32 = 0.0;
    for (head) |h| head_energy += h * h;
    if (head_energy <= 0.0) return longest;

    var best = longest;
    var best_score: f32 = -std.math.floatMax(f32);
    var back: usize = 0;
    while (back <= period and longest - back > fade) : (back += 1) {
        const len = longest - back;
        const tail = raw[attack + len ..][0..fade];

        var dot: f32 = 0.0;
        var tail_energy: f32 = 0.0;
        for (head, tail) |h, t| {
            dot += h * t;
            tail_energy += t * t;
        }
        if (tail_energy <= 0.0) continue;

        const score = dot / @sqrt(tail_energy);
        if (score > best_score) {
            best_score = score;
            best = len;
        }
    }
    return best;
}

/// Build the playback layout for one recording. Takes ownership of nothing:
/// `raw` is only read.
pub fn prepare(
    gpa: std.mem.Allocator,
    raw: []const f32,
    f0: f32,
    sample_rate: u32,
) Error!Prepared {
    const sr: f32 = @floatFromInt(sample_rate);
    const attack: usize = @intFromFloat(attack_seconds * sr);
    const fade: usize = @intFromFloat(loop_fade_seconds * sr);
    const period: usize = @intFromFloat(sr / f0);

    // The loop region has to hold a crossfade, a period to search over, and
    // still have something left to repeat.
    if (raw.len < attack + fade * 2 + period) return Error.SampleTooShort;

    // A loop whose length is not a whole number of periods folds its tail onto
    // its head out of phase, and the two cancel: a hole once per loop. Search
    // back over one period for the length that lines them up best.
    const loop_len = bestLoopLen(raw, attack, fade, period);

    const buf = try gpa.alloc(f32, attack + loop_len);
    errdefer gpa.free(buf);

    @memcpy(buf, raw[0 .. attack + loop_len]);

    // Fold the material that follows the loop over the start of it. Linear
    // rather than equal power: the two ends are now in phase, so they add and
    // a linear fade holds the level flat.
    const loop = buf[attack..];
    for (0..fade) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fade));
        loop[i] = loop[i] * t + raw[attack + loop_len + i] * (1.0 - t);
    }

    normalizeRms(buf);
    return .{ .buf = buf, .loop_start = attack, .f0 = f0 };
}

/// Decode and prepare a whole set. Runs once at startup, before audio begins.
pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    set: []const Sample,
    sample_rate: u32,
) ![]Prepared {
    if (set.len == 0) return Error.NoSamples;

    const out = try gpa.alloc(Prepared, set.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |p| gpa.free(p.buf);
        gpa.free(out);
    }

    for (set, out) |entry, *slot| {
        const path = try std.fs.path.join(gpa, &.{ dir, entry.path });
        defer gpa.free(path);

        const raw = try decode.loadFile(gpa, io, path, sample_rate);
        defer gpa.free(raw);

        slot.* = try prepare(gpa, raw, entry.f0, sample_rate);
        done += 1;
    }
    return out;
}

pub fn free(gpa: std.mem.Allocator, prepared: []Prepared) void {
    for (prepared) |p| gpa.free(p.buf);
    gpa.free(prepared);
}

/// Distance in cents, signed. Zone choice works in cents so that "nearest"
/// means nearest by ear rather than by hertz.
fn cents(hz: f32, ref: f32) f32 {
    return 1200.0 * std.math.log2(hz / ref);
}

/// The recording closest to `hz`, measured in cents. Boundaries therefore fall
/// on the geometric mean of neighbouring pitches.
pub fn nearestIndex(set: []const Prepared, hz: f32) usize {
    var best: usize = 0;
    var best_dist = @abs(cents(hz, set[0].f0));
    for (set[1..], 1..) |p, i| {
        const d = @abs(cents(hz, p.f0));
        if (d < best_dist) {
            best_dist = d;
            best = i;
        }
    }
    return best;
}

/// Map an ECG reading onto the range the set can actually reach, on a log scale
/// so equal steps in the count sound like equal pitch steps.
pub fn targetHz(set: []const Prepared, ecg: i16, ecg_max: i16) f32 {
    const lo = set[0].f0;
    const hi = set[set.len - 1].f0;
    const t = std.math.clamp(
        @as(f32, @floatFromInt(ecg)) / @as(f32, @floatFromInt(ecg_max)),
        0.0,
        1.0,
    );
    return lo * std.math.pow(f32, hi / lo, t);
}

/// Bring a read position back inside the buffer by whole loops.
fn wrapPos(p: Prepared, pos: f64) f64 {
    const len: f64 = @floatFromInt(p.buf.len);
    if (pos < len) return pos;
    const loop_len: f64 = @floatFromInt(p.loopLen());
    return pos - loop_len * @floor((pos - len) / loop_len + 1.0);
}

/// Linear interpolation between the two samples either side of `pos`.
fn readAt(p: Prepared, pos: f64) f32 {
    const i: usize = @intFromFloat(pos);
    const frac: f32 = @floatCast(pos - @floor(pos));
    const a = p.buf[i];
    // The sample after the last one is the start of the loop region, which is
    // exactly where `wrapPos` jumps to.
    const b = if (i + 1 < p.buf.len) p.buf[i + 1] else p.buf[p.loop_start];
    return a + (b - a) * frac;
}

/// One read head: which recording, and where in it.
const Head = struct {
    idx: usize,
    pos: f64,

    fn read(self: Head, set: []const Prepared) f32 {
        return readAt(set[self.idx], self.pos);
    }

    fn advance(self: *Head, set: []const Prepared, rate: f64) void {
        self.pos = wrapPos(set[self.idx], self.pos + rate);
    }

    /// Where this head sits within its loop region, 0 to 1. Used to drop an
    /// incoming head at the same point in its own loop so the crossfade does
    /// not jump in phase.
    fn loopPhase(self: Head, set: []const Prepared) f64 {
        const p = set[self.idx];
        const start: f64 = @floatFromInt(p.loop_start);
        if (self.pos <= start) return 0.0;
        return (self.pos - start) / @as(f64, @floatFromInt(p.loopLen()));
    }
};

pub const Voice = struct {
    set: []const Prepared,
    sample_rate: u32,
    ecg_max: i16,
    alpha: f32,
    gate_step: f32,
    zone_step: f32,

    /// Smoothed target pitch, in Hz.
    hz: f32,
    /// Gate envelope, 0 when untouched and 1 when held.
    env: f32,
    prev_touch: bool,

    head: Head,
    /// The recording being faded out, valid only while `fade < 1`.
    old: Head,
    /// Crossfade progress, 1 when no crossfade is running.
    fade: f32,

    pub fn init(set: []const Prepared, sample_rate: u32, ecg_max: i16) Voice {
        const sr: f32 = @floatFromInt(sample_rate);
        return .{
            .set = set,
            .sample_rate = sample_rate,
            .ecg_max = ecg_max,
            .alpha = 1.0 - @exp(-1.0 / (smooth_tau_s * sr)),
            .gate_step = 1.0 / (gate_ms / 1000.0 * sr),
            .zone_step = 1.0 / (zone_fade_ms / 1000.0 * sr),
            .hz = set[0].f0,
            .env = 0.0,
            .prev_touch = false,
            .head = .{ .idx = 0, .pos = 0.0 },
            .old = .{ .idx = 0, .pos = 0.0 },
            .fade = 1.0,
        };
    }

    /// Move to `idx`, fading out what is playing. The incoming head enters at
    /// the same phase of its loop region, never at the attack: a pitch change
    /// mid-note must not re-articulate the note.
    ///
    /// Both heads sound the same pitch during the fade, so they are coherent
    /// and their relative phase stays fixed for its whole length. Left to
    /// chance that phase can be opposition, and the two recordings cancel into
    /// a hole in the middle of the fade. So the entry point is nudged within
    /// one period of the incoming recording to the offset that lines up best
    /// with what is already sounding.
    fn crossTo(self: *Voice, idx: usize) void {
        const p = self.set[idx];
        const outgoing = self.set[self.head.idx];
        const phase = self.head.loopPhase(self.set);
        const base = @as(f64, @floatFromInt(p.loop_start)) +
            phase * @as(f64, @floatFromInt(p.loopLen()));

        const out_rate: f64 = @as(f64, self.hz) / @as(f64, outgoing.f0);
        const in_rate: f64 = @as(f64, self.hz) / @as(f64, p.f0);

        // What the outgoing head is about to play.
        var ref: [align_window]f32 = undefined;
        var rp = self.head.pos;
        for (&ref) |*r| {
            r.* = readAt(outgoing, rp);
            rp = wrapPos(outgoing, rp + out_rate);
        }

        // One period of the incoming recording covers every phase it can offer.
        const sr: f64 = @floatFromInt(self.sample_rate);
        const period: f64 = sr / @as(f64, p.f0);
        var best_offset: f64 = 0.0;
        var best_score: f32 = -std.math.floatMax(f32);
        var offset: f64 = 0.0;
        while (offset < period) : (offset += 1.0) {
            var cp = wrapPos(p, base + offset);
            var score: f32 = 0.0;
            for (ref) |r| {
                score += r * readAt(p, cp);
                cp = wrapPos(p, cp + in_rate);
            }
            if (score > best_score) {
                best_score = score;
                best_offset = offset;
            }
        }

        self.old = self.head;
        self.head = .{ .idx = idx, .pos = wrapPos(p, base + best_offset) };
        self.fade = 0.0;
    }

    /// Add this voice's output into `out`. Never overwrites, so voices mix by
    /// being rendered in sequence into the same block.
    pub fn render(self: *Voice, out: []f32, ecg: i16, touched: bool) void {
        const target = targetHz(self.set, ecg, self.ecg_max);
        const gate_target: f32 = if (touched) 1.0 else 0.0;

        // A new touch is a new note: jump most of the way to the current
        // reading rather than gliding up from wherever the last note ended,
        // and start at the attack so the breath is heard. The recording is
        // picked for the pitch that will actually sound, not for the target
        // the glide is still on its way to.
        if (touched and !self.prev_touch) {
            self.hz += (target - self.hz) * onset_jump;
            self.head = .{ .idx = nearestIndex(self.set, self.hz), .pos = 0.0 };
            self.fade = 1.0;
        }
        self.prev_touch = touched;

        for (out) |*sample| {
            self.hz += (target - self.hz) * self.alpha;

            // Only consider moving once the previous crossfade has finished,
            // and only if the neighbour is meaningfully closer.
            if (self.fade >= 1.0) {
                const cand = nearestIndex(self.set, self.hz);
                if (cand != self.head.idx) {
                    const here = @abs(cents(self.hz, self.set[self.head.idx].f0));
                    const there = @abs(cents(self.hz, self.set[cand].f0));
                    if (here - there > hysteresis_cents) self.crossTo(cand);
                }
            }

            var value = self.head.read(self.set);
            const rate: f64 = @as(f64, self.hz) / @as(f64, self.set[self.head.idx].f0);
            self.head.advance(self.set, rate);

            if (self.fade < 1.0) {
                // Linear, not equal power: `crossTo` has already lined the two
                // recordings up in phase, so they add rather than interfere and
                // a linear fade holds the level constant.
                const old_rate: f64 = @as(f64, self.hz) / @as(f64, self.set[self.old.idx].f0);
                value = value * self.fade + self.old.read(self.set) * (1.0 - self.fade);
                self.old.advance(self.set, old_rate);
                self.fade = @min(1.0, self.fade + self.zone_step);
            }

            if (self.env < gate_target) {
                self.env = @min(gate_target, self.env + self.gate_step);
            } else if (self.env > gate_target) {
                self.env = @max(gate_target, self.env - self.gate_step);
            }

            sample.* += std.math.clamp(value * self.env * voice_gain, -1.0, 1.0);
        }
    }
};

const testing = std.testing;

/// A stand-in recording: a steady sine at `f0`, so tests never need ffmpeg or
/// the installation's wav files.
fn sineSample(gpa: std.mem.Allocator, f0: f32, seconds: f32, sample_rate: u32) ![]f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const len: usize = @intFromFloat(seconds * sr);
    const buf = try gpa.alloc(f32, len);
    for (buf, 0..) |*s, i| {
        s.* = 0.5 * @sin(2.0 * std.math.pi * f0 * @as(f32, @floatFromInt(i)) / sr);
    }
    return buf;
}

/// A set with the same pitches as the flute, built from sines.
fn sineSet(gpa: std.mem.Allocator, sample_rate: u32) ![]Prepared {
    const out = try gpa.alloc(Prepared, flute.len);
    for (flute, out) |entry, *slot| {
        const raw = try sineSample(gpa, entry.f0, 1.5, sample_rate);
        defer gpa.free(raw);
        slot.* = try prepare(gpa, raw, entry.f0, sample_rate);
    }
    return out;
}

test "a new note starts most of the way to its pitch, on a recording that suits it" {
    const gpa = testing.allocator;
    const set = try sineSet(gpa, 44100);
    defer free(gpa, set);

    var v = Voice.init(set, 44100, 32767);
    const ecg: i16 = 30000;
    const target = targetHz(set, ecg, 32767);
    const from = v.hz;

    var block: [1]f32 = .{0};
    v.render(&block, ecg, true);

    const expected = from + (target - from) * onset_jump;
    try testing.expectApproxEqAbs(expected, v.hz, 1.0);
    try testing.expect(v.hz < target);

    // The head is on the recording nearest what is sounding now. Picking it for
    // the target instead would start the note on a zone up to a jump's worth of
    // pitch away and stretch it back down.
    try testing.expectEqual(nearestIndex(set, v.hz), v.head.idx);
    // Seeded at the attack, then advanced by the one sample just rendered.
    try testing.expect(v.head.pos < 2.0);
}
