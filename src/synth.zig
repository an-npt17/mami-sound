const std = @import("std");

fn touchGain(touch_intensity: f32) f32 {
    const touch = std.math.clamp(touch_intensity, 0.0, 1.0);
    return 1.0 + 0.15 * touch;
}

fn voiceAtPhase(phase: f32, touch_intensity: f32) f32 {
    const touch = std.math.clamp(touch_intensity, 0.0, 1.0);
    const fundamental = @sin(phase);
    if (touch == 0.0) return fundamental;
    const touched = 0.55 * fundamental
        + 0.30 * @sin(phase * 2.0)
        + 0.15 * @sin(phase * 3.0);
    return (1.0 - touch) * fundamental + touch * touched;
}

pub const Synth = struct {
    sample_rate: u32,
    step_samples: usize,
    attack_samples: usize,
    decay_samples: usize,
    release_samples: usize,
    /// Level the note holds at after decay, as a fraction of the peak (0..1).
    /// There is no note-off here - every step renders one complete note - so
    /// sustain is a level and its duration is whatever the ramps leave over.
    sustain: f32,

    pub fn init(sample_rate: u32, step_samples: usize) Synth {
        return .{
            .sample_rate = sample_rate,
            .step_samples = step_samples,
            .attack_samples = 0,
            .decay_samples = 0,
            .release_samples = 0,
            .sustain = 1.0,
        };
    }

    pub fn setEnvelope(self: *Synth, attack_ms: f32, decay_ms: f32, sustain: f32, release_ms: f32) void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));
        self.attack_samples = @intFromFloat(@max(0.0, attack_ms) * sr / 1000.0);
        self.decay_samples = @intFromFloat(@max(0.0, decay_ms) * sr / 1000.0);
        self.release_samples = @intFromFloat(@max(0.0, release_ms) * sr / 1000.0);
        self.sustain = std.math.clamp(sustain, 0.0, 1.0);
        const total: usize = self.attack_samples + self.decay_samples + self.release_samples;
        if (total > self.step_samples) {
            // Sustain time collapses first, then all three ramps shrink together
            // so no stage is ever dropped outright.
            const scale: f32 = @as(f32, @floatFromInt(self.step_samples)) / @as(f32, @floatFromInt(total));
            self.attack_samples = @intFromFloat(@as(f32, @floatFromInt(self.attack_samples)) * scale);
            self.decay_samples = @intFromFloat(@as(f32, @floatFromInt(self.decay_samples)) * scale);
            // Give the rounding remainder to release so the stages tile the note exactly.
            self.release_samples = self.step_samples - self.attack_samples - self.decay_samples;
        }
    }

    /// Envelope amplitude at sample `i`, peaking at 1.0.
    fn ampAt(self: Synth, i: usize, len: usize) f32 {
        if (self.attack_samples > 0 and i < self.attack_samples) {
            return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(self.attack_samples));
        }
        if (self.release_samples > 0 and i >= len - self.release_samples) {
            const t = @as(f32, @floatFromInt(len - i)) / @as(f32, @floatFromInt(self.release_samples));
            return self.sustain * t;
        }
        const decay_end = self.attack_samples + self.decay_samples;
        if (self.decay_samples > 0 and i < decay_end) {
            const t = @as(f32, @floatFromInt(i - self.attack_samples)) / @as(f32, @floatFromInt(self.decay_samples));
            return 1.0 - (1.0 - self.sustain) * t;
        }
        return self.sustain;
    }

    pub fn renderTone(self: Synth, freq: f32, gain: f32, touch_intensity: f32, out: []i16) void {
        std.debug.assert(out.len == self.step_samples);
        const g = std.math.clamp(gain, 0.0, 1.0);
        if (freq <= 0 or g == 0) {
            @memset(out, 0);
            return;
        }
        const period: f32 = @as(f32, @floatFromInt(self.sample_rate)) / freq;
        const two_pi: f32 = 2.0 * std.math.pi;
        const touch_gain = touchGain(touch_intensity);
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            const amp = self.ampAt(i, out.len);
            const phase: f32 = @as(f32, @floatFromInt(i)) / period * two_pi;
            const s = voiceAtPhase(phase, touch_intensity) * amp * g * touch_gain;
            out[i] = @intFromFloat(std.math.clamp(s, -1.0, 1.0) * 32767.0);
        }
    }
};

/// Peak absolute sample over a window - the envelope amplitude there, since a
/// 440 Hz tone in a 44100-sample buffer completes many cycles per window.
fn peakIn(buf: []const i16, from: usize, to: usize) u16 {
    var peak: u16 = 0;
    for (buf[from..to]) |b| {
        if (@abs(b) > peak) peak = @abs(b);
    }
    return peak;
}

fn harmonicProjection(buf: []const i16, sample_rate: f32, frequency: f32, harmonic: f32) f32 {
    var sum: f32 = 0.0;
    for (buf, 0..) |sample, i| {
        const phase = 2.0 * std.math.pi * frequency * harmonic * @as(f32, @floatFromInt(i)) / sample_rate;
        sum += @as(f32, @floatFromInt(sample)) * @sin(phase);
    }
    return @abs(sum);
}

test "decay falls from peak to the sustain level" {
    var s = Synth.init(44100, 44100);
    // 100 ms attack, 200 ms decay, sustain 0.5, no release.
    s.setEnvelope(100, 200, 0.5, 0);
    var buf: [44100]i16 = undefined;
    s.renderTone(440, 1.0, 0.0, &buf);

    const at_peak = peakIn(&buf, 4300, 4500); // end of attack, amp ~= 1.0
    const mid_decay = peakIn(&buf, 12000, 12400); // half way down, amp ~= 0.75
    const after_decay = peakIn(&buf, 14000, 14400); // settled, amp ~= 0.5

    try std.testing.expect(at_peak > mid_decay);
    try std.testing.expect(mid_decay > after_decay);
    // sustain level is half the peak, within rounding of the sine grid
    try std.testing.expect(@abs(@divTrunc(@as(i32, at_peak), 2) - @as(i32, after_decay)) < 900);
}

test "sustain segment holds flat at the sustain level" {
    var s = Synth.init(44100, 44100);
    s.setEnvelope(50, 50, 0.4, 50);
    var buf: [44100]i16 = undefined;
    s.renderTone(440, 1.0, 0.0, &buf);

    // Between end of decay (4410 samples) and start of release (41895).
    const early = peakIn(&buf, 6000, 6600);
    const late = peakIn(&buf, 39000, 39600);
    try std.testing.expect(@abs(@as(i32, early) - @as(i32, late)) < 400);
    // and it sits near 0.4 of full scale
    try std.testing.expect(early > 12000 and early < 14500);
}

test "sustain of one with no decay reproduces the trapezoid" {
    var adsr = Synth.init(44100, 44100);
    adsr.setEnvelope(100, 0, 1.0, 100);
    var a: [44100]i16 = undefined;
    adsr.renderTone(440, 0.8, 0.0, &a);

    // The plateau must be flat at full gain, exactly as the old shape was.
    const first = peakIn(&a, 5000, 5600);
    const middle = peakIn(&a, 22000, 22600);
    const last = peakIn(&a, 38000, 38600);
    try std.testing.expect(@abs(@as(i32, first) - @as(i32, middle)) < 400);
    try std.testing.expect(@abs(@as(i32, middle) - @as(i32, last)) < 400);
    try std.testing.expect(a[0] == 0);
    try std.testing.expect(a[44099] == 0);
}

test "overflowing stages scale down to fill exactly one note" {
    var s = Synth.init(44100, 8820); // 200 ms note
    // 120 + 80 + 80 = 280 ms of ramps in a 200 ms note -> scale by 200/280
    s.setEnvelope(120, 80, 0.5, 80);
    try std.testing.expectEqual(s.step_samples, s.attack_samples + s.decay_samples + s.release_samples);
    // proportions are preserved: attack is 120/280 of the note
    const expect_attack: usize = @intFromFloat(8820.0 * 120.0 / 280.0);
    try std.testing.expect(@abs(@as(i32, @intCast(s.attack_samples)) - @as(i32, @intCast(expect_attack))) <= 2);
}

test "sustain level is clamped to zero and one" {
    var s = Synth.init(44100, 8820);
    s.setEnvelope(10, 10, 5.0, 10);
    try std.testing.expectEqual(@as(f32, 1.0), s.sustain);
    s.setEnvelope(10, 10, -2.0, 10);
    try std.testing.expectEqual(@as(f32, 0.0), s.sustain);
}

test "invalid frequency renders silence" {
    var s = Synth.init(44100, 8820);
    var buf: [8820]i16 = undefined;
    s.renderTone(0, 1.0, 0.0, &buf);
    for (buf) |b| try std.testing.expect(b == 0);
}

test "attack ramps from zero and never clips" {
    var s = Synth.init(44100, 44100);
    s.setEnvelope(100, 0, 1.0, 0);
    var buf: [44100]i16 = undefined;
    s.renderTone(440, 1.0, 0.0, &buf);
    try std.testing.expect(buf[0] == 0);
    try std.testing.expect(@abs(buf[4411]) > @abs(buf[0]));
    for (buf) |b| try std.testing.expect(@abs(b) <= 32767);
}

test "release ends silent" {
    var s = Synth.init(44100, 44100);
    s.setEnvelope(0, 0, 1.0, 100);
    var buf: [44100]i16 = undefined;
    s.renderTone(440, 1.0, 0.0, &buf);
    try std.testing.expect(buf[44100 - 1] == 0);
    try std.testing.expect(@abs(buf[44100 - 10]) < @abs(buf[20000]));
}

test "frequency is within tolerance" {
    var s = Synth.init(44100, 44100);
    s.setEnvelope(0, 0, 1.0, 0);
    var buf: [44100]i16 = undefined;
    s.renderTone(440, 1.0, 0.0, &buf);
    var crossings: usize = 0;
    var i: usize = 1;
    while (i < buf.len) : (i += 1) {
        if ((buf[i - 1] < 0 and buf[i] >= 0) or (buf[i - 1] >= 0 and buf[i] < 0)) crossings += 1;
    }
    const expected: usize = 440 * 2;
    try std.testing.expect(@abs(@as(isize, @intCast(crossings)) - @as(isize, @intCast(expected))) < 10);
}

test "zero gain renders silence" {
    var s = Synth.init(44100, 44100);
    s.setEnvelope(0, 0, 1.0, 0);
    var buf: [44100]i16 = undefined;
    s.renderTone(440, 0.0, 0.0, &buf);
    for (buf) |b| try std.testing.expect(b == 0);
}

test "gain scales amplitude" {
    var s = Synth.init(44100, 44100);
    s.setEnvelope(0, 0, 1.0, 0);
    var buf: [44100]i16 = undefined;
    s.renderTone(440, 0.25, 0.0, &buf);
    var peak: u16 = 0;
    for (buf) |b| {
        if (@abs(b) > peak) peak = @abs(b);
    }
    try std.testing.expect(peak > @as(u16, 5000));
    try std.testing.expect(peak < @as(u16, 10000));
}

test "touch increases second-harmonic energy" {
    var s = Synth.init(44100, 44100);
    s.setEnvelope(0, 0, 1.0, 0);
    var resting: [44100]i16 = undefined;
    var touched: [44100]i16 = undefined;
    s.renderTone(440, 1.0, 0.0, &resting);
    s.renderTone(440, 1.0, 1.0, &touched);

    const resting_second = harmonicProjection(&resting, 44100.0, 440.0, 2.0);
    const touched_second = harmonicProjection(&touched, 44100.0, 440.0, 2.0);
    try std.testing.expect(touched_second > resting_second * 10.0);
}

test "touch gain boost is bounded" {
    var s = Synth.init(44100, 44100);
    s.setEnvelope(0, 0, 1.0, 0);
    var buf: [44100]i16 = undefined;
    s.renderTone(440, 1.0, 2.0, &buf);
    for (buf) |sample| try std.testing.expect(@abs(sample) <= 32767);
}

test "touch gain clamps to the bounded boost" {
    try std.testing.expectEqual(@as(f32, 1.0), touchGain(-1.0));
    try std.testing.expectEqual(@as(f32, 1.0), touchGain(0.0));
    try std.testing.expectEqual(@as(f32, 1.15), touchGain(1.0));
    try std.testing.expectEqual(@as(f32, 1.15), touchGain(2.0));
}
