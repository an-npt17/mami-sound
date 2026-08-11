const std = @import("std");

pub const max_value: u16 = 65535;
pub const touch_threshold: u16 = 40000;
pub const freq_min: f32 = 20.0;
pub const freq_max: f32 = 880.0;

const v_max: f32 = 3.3;
const rest_min_v: f32 = 0.3;
const rest_max_v: f32 = 0.9;
const touch_peak_v: f32 = 3.3;
const touch_decay: f32 = 0.88;

pub const Model = struct {
    rng: std.Random.DefaultPrng,
    baseline: f32,
    touch: f32,

    pub fn init(seed: u64) Model {
        var m = Model{
            .rng = std.Random.DefaultPrng.init(seed),
            .baseline = 0,
            .touch = 0,
        };
        m.baseline = rest_min_v + m.rng.random().float(f32) * (rest_max_v - rest_min_v);
        return m;
    }

    pub fn tick(self: *Model, touched: bool) u16 {
        if (touched) self.touch = touch_peak_v;
        const v: f32 = if (self.touch > 0) blk: {
            const vv = self.touch;
            self.touch *= touch_decay;
            if (self.touch < rest_max_v) self.touch = 0;
            break :blk vv;
        } else blk: {
            self.baseline += (self.rng.random().float(f32) - 0.5) * 0.08;
            self.baseline = std.math.clamp(self.baseline, 0.2, 1.2);
            break :blk self.baseline;
        };
        const norm = std.math.clamp(v / v_max, 0.0, 1.0);
        return @intFromFloat(norm * @as(f32, @floatFromInt(max_value)));
    }
};

pub fn freqOf(value: u16) f32 {
    const t = @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(max_value));
    return freq_min + t * (freq_max - freq_min);
}

pub fn isTouch(value: u16) bool {
    return value > touch_threshold;
}

pub fn valueOfVoltage(v: f32) u16 {
    const norm = std.math.clamp(v, 0.0, 3.3) / 3.3;
    return @intFromFloat(norm * @as(f32, @floatFromInt(max_value)));
}

pub fn gainOf(base: f32, k: f32, value: u16) f32 {
    const norm = @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(max_value));
    const boost = std.math.expm1(k * norm) + 1.0;
    return std.math.clamp(base * boost, 0.0, 1.0);
}

// --- Dual-sensor mapping -------------------------------------------------
//
// Two physical channels drive one sample-based preset:
//   electromagnetic sensor, 0..3.3 V analog  -> volume
//   vibration sensor, 0..3.3 V continuous    -> pitch
// Both are read as voltages so the simulator in the browser and the real ADC
// speak the same units.

pub const v_supply: f32 = 3.3;
/// Vibration below this fraction of full scale is bench noise, not a plant
/// being touched - it maps to "no pitch shift" so a resting plant plays the
/// sample at its recorded pitch.
pub const vib_deadzone: f32 = 0.05;
pub const default_pitch_range_st: f32 = 12.0;
pub const max_pitch_range_st: f32 = 24.0;

/// 0..3.3 V to 0..1, clamped.
pub fn normVoltage(v: f32) f32 {
    if (std.math.isNan(v)) return 0.0;
    return std.math.clamp(v, 0.0, v_supply) / v_supply;
}

/// Vibration voltage to 0..1 intensity, with the deadzone removed and the
/// remainder stretched back over the full range.
pub fn vibrationIntensity(vib_v: f32) f32 {
    const n = normVoltage(vib_v);
    if (n <= vib_deadzone) return 0.0;
    return (n - vib_deadzone) / (1.0 - vib_deadzone);
}

/// Semitones of pitch shift for a vibration reading. Still = 0 (sample plays
/// at its own pitch), shaking hard = +range_st.
pub fn semitonesOfVibration(vib_v: f32, range_st: f32) f32 {
    const range = std.math.clamp(range_st, 0.0, max_pitch_range_st);
    return vibrationIntensity(vib_v) * range;
}

/// Playback-rate multiplier for the sample: 2^(semitones/12).
pub fn pitchRatioOfVibration(vib_v: f32, range_st: f32) f32 {
    return std.math.pow(f32, 2.0, semitonesOfVibration(vib_v, range_st) / 12.0);
}

/// Snap a shift to whole semitones, for when a continuous glide is too seasick.
pub fn quantizeSemitones(st: f32) f32 {
    return @round(st);
}

/// Volume for an electromagnetic reading, in volts. Same exponential curve as
/// gainOf(), fed by the EM channel instead of the single legacy channel.
pub fn volumeOfEm(base: f32, k: f32, em_v: f32) f32 {
    return gainOf(base, k, valueOfVoltage(em_v));
}

// --- Digital vibration channel -------------------------------------------
//
// The other two installations read the vibration sensor as a bare logic line:
// it is either shaking or it is not. A comparator output like that chatters on
// every contact, so an edge only counts once the level has held.

/// Half the supply rail, the usual logic threshold for a 3.3 V comparator.
pub const digital_threshold_v: f32 = v_supply / 2.0;
pub const default_debounce_ms: f32 = 40.0;

pub fn isVibrating(v: f32) bool {
    return v >= digital_threshold_v;
}

pub const Edge = enum { none, rise, fall };

pub const Debouncer = struct {
    /// The level everything downstream reacts to.
    stable: bool,
    /// The level being timed out; equal to `stable` when nothing is pending.
    candidate: bool,
    held_ms: f32,
    stable_ms: f32,

    pub fn init(stable_ms: f32) Debouncer {
        return .{
            .stable = false,
            .candidate = false,
            .held_ms = 0,
            .stable_ms = @max(0.0, stable_ms),
        };
    }

    /// Feed one raw reading. Returns the edge this reading committed, if any.
    pub fn step(self: *Debouncer, raw: bool, dt_ms: f32) Edge {
        if (raw != self.candidate) {
            self.candidate = raw;
            self.held_ms = 0;
        } else if (self.candidate != self.stable) {
            self.held_ms += @max(0.0, dt_ms);
        }
        if (self.candidate != self.stable and self.held_ms >= self.stable_ms) {
            self.stable = self.candidate;
            self.held_ms = 0;
            return if (self.stable) .rise else .fall;
        }
        return .none;
    }
};

/// One-pole low-pass. Both channels are smoothed before they reach the audio
/// path, so a jittery ADC reading becomes a slide instead of a click.
pub const Smoother = struct {
    value: f32,
    tau_ms: f32,

    pub fn init(start: f32, tau_ms: f32) Smoother {
        return .{ .value = start, .tau_ms = @max(0.0, tau_ms) };
    }

    pub fn step(self: *Smoother, target: f32, dt_ms: f32) f32 {
        if (self.tau_ms <= 0.0 or dt_ms <= 0.0) {
            self.value = target;
            return self.value;
        }
        const alpha = 1.0 - std.math.exp(-dt_ms / self.tau_ms);
        self.value += (target - self.value) * alpha;
        return self.value;
    }
};

pub const Sample = struct {
    moisture_pct: u8,
    temperature_c: f32,
    humidity_pct: f32,
};

pub const InputState = struct {
    sample: Sample,
    touch_intensity: f32,
};

pub const MockModel = struct {
    rng: std.Random.DefaultPrng,
    moisture: f32,
    temperature_c: f32,
    humidity_pct: f32,
    touch_level: f32,

    pub fn init(seed: u64) MockModel {
        return .{
            .rng = std.Random.DefaultPrng.init(seed),
            .moisture = 55.0,
            .temperature_c = 23.0,
            .humidity_pct = 60.0,
            .touch_level = 0.0,
        };
    }

    pub fn water(self: *MockModel) void {
        self.moisture = 70.0;
    }

    pub fn touch(self: *MockModel) void {
        self.touch_level = 1.0;
    }

    pub fn tick(self: *MockModel) InputState {
        const random = self.rng.random();
        const touch_intensity = std.math.clamp(
            self.touch_level * (0.98 + random.float(f32) * 0.04),
            0.0,
            1.0,
        );

        const result = InputState{
            .sample = .{
                .moisture_pct = @intFromFloat(self.moisture),
                .temperature_c = self.temperature_c,
                .humidity_pct = self.humidity_pct,
            },
            .touch_intensity = touch_intensity,
        };

        self.moisture = @max(35.0, self.moisture - 0.15);
        self.temperature_c = std.math.clamp(
            self.temperature_c + (random.float(f32) - 0.5) * 0.6,
            18.0,
            29.0,
        );
        self.humidity_pct = std.math.clamp(
            self.humidity_pct + (random.float(f32) - 0.5) * 4.0,
            45.0,
            75.0,
        );
        self.touch_level *= 0.82;
        if (self.touch_level < 0.01) self.touch_level = 0.0;
        return result;
    }
};

/// Maps the calibrated 0..100 moisture index, not universal volumetric water content, to Hz.
pub fn freqOfMoisture(moisture_pct: u8) f32 {
    const clamped = @min(moisture_pct, @as(u8, 100));
    const t = @as(f32, @floatFromInt(clamped)) / 100.0;
    return freq_min + t * (freq_max - freq_min);
}

/// Converts the calibrated 0..100 moisture index, not universal volumetric water content, to raw telemetry.
pub fn rawValueOfMoisture(moisture_pct: u8) u16 {
    const clamped = @min(moisture_pct, @as(u8, 100));
    return @intFromFloat(@as(f32, @floatFromInt(clamped)) / 100.0 * @as(f32, @floatFromInt(max_value)));
}

test "resting values stay below touch threshold" {
    var m = Model.init(42);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const v = m.tick(false);
        try std.testing.expect(v < touch_threshold);
    }
}

test "touch spikes then decays" {
    var m = Model.init(7);
    var t = m.tick(true);
    try std.testing.expect(t > touch_threshold);
    var decayed: usize = 0;
    while (t > touch_threshold) : (decayed += 1) {
        t = m.tick(false);
        try std.testing.expect(decayed < 100);
    }
}

test "freq mapping is monotonic in range" {
    try std.testing.expectEqual(freq_min, freqOf(0));
    try std.testing.expectEqual(freq_max, freqOf(max_value));
    var prev: f32 = 0;
    var v: u32 = 0;
    while (v <= max_value) : (v += 1000) {
        const f = freqOf(@intCast(v));
        try std.testing.expect(f >= prev);
        try std.testing.expect(f >= freq_min and f <= freq_max);
        prev = f;
    }
}

test "isTouch boundary at threshold" {
    try std.testing.expect(!isTouch(touch_threshold));
    try std.testing.expect(!isTouch(touch_threshold - 1));
    try std.testing.expect(isTouch(touch_threshold + 1));
    try std.testing.expect(isTouch(max_value));
    try std.testing.expect(!isTouch(0));
}

test "valueOfVoltage maps volts to raw values" {
    try std.testing.expectEqual(@as(u16, 0), valueOfVoltage(0.0));
    try std.testing.expectEqual(max_value, valueOfVoltage(3.3));
    try std.testing.expectEqual(@as(u16, 32767), valueOfVoltage(1.65));
    try std.testing.expectEqual(@as(u16, 0), valueOfVoltage(-1.0));
    try std.testing.expectEqual(max_value, valueOfVoltage(5.0));
}


test "gainOf is monotonic in value" {
    try std.testing.expectEqual(@as(f32, 0.5), gainOf(0.5, 1.2, 0));
    var prev: f32 = 0;
    var v: u32 = 0;
    while (v <= max_value) : (v += 1000) {
        const g = gainOf(0.5, 1.2, @intCast(v));
        try std.testing.expect(g >= prev);
        try std.testing.expect(g <= 1.0);
        prev = g;
    }
}

test "gainOf clamps to one and k=0 disables boost" {
    try std.testing.expectEqual(@as(f32, 1.0), gainOf(1.0, 3.0, max_value));
    try std.testing.expectEqual(@as(f32, 0.5), gainOf(0.5, 0.0, 50000));
    try std.testing.expectEqual(@as(f32, 0.0), gainOf(0.0, 1.2, 30000));
}

test "voltage normalises and clamps to the supply rail" {
    try std.testing.expectEqual(@as(f32, 0.0), normVoltage(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), normVoltage(3.3));
    try std.testing.expectEqual(@as(f32, 0.0), normVoltage(-2.0));
    try std.testing.expectEqual(@as(f32, 1.0), normVoltage(5.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), normVoltage(1.65), 0.001);
}

test "vibration deadzone keeps a resting plant at its own pitch" {
    try std.testing.expectEqual(@as(f32, 0.0), vibrationIntensity(0.0));
    try std.testing.expectEqual(@as(f32, 0.0), vibrationIntensity(vib_deadzone * v_supply * 0.99));
    // Rounding can put the boundary itself a hair above the deadzone; it must
    // still be silent-adjacent, not a real shift.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), vibrationIntensity(vib_deadzone * v_supply), 1e-6);
    try std.testing.expectEqual(@as(f32, 1.0), vibrationIntensity(3.3));
    try std.testing.expect(vibrationIntensity(0.3) > 0.0);
    // The deadzone is removed, not just clipped: the range above it still reaches 1.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), vibrationIntensity((vib_deadzone + 0.5 * (1.0 - vib_deadzone)) * v_supply), 0.001);
}

test "pitch rises with vibration and rests at unity" {
    try std.testing.expectEqual(@as(f32, 0.0), semitonesOfVibration(0.0, 12.0));
    try std.testing.expectEqual(@as(f32, 1.0), pitchRatioOfVibration(0.0, 12.0));
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), semitonesOfVibration(3.3, 12.0), 0.001);
    // Full-scale vibration over a 12-semitone range is exactly one octave up.
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), pitchRatioOfVibration(3.3, 12.0), 0.001);

    var prev: f32 = 0.0;
    var i: usize = 0;
    while (i <= 33) : (i += 1) {
        const v = @as(f32, @floatFromInt(i)) / 10.0;
        const r = pitchRatioOfVibration(v, 12.0);
        try std.testing.expect(r >= prev);
        try std.testing.expect(r >= 1.0 and r <= 2.0);
        prev = r;
    }
}

test "pitch range is clamped and zero range disables the shift" {
    try std.testing.expectEqual(@as(f32, 1.0), pitchRatioOfVibration(3.3, 0.0));
    try std.testing.expectApproxEqAbs(max_pitch_range_st, semitonesOfVibration(3.3, 99.0), 0.001);
    try std.testing.expectEqual(@as(f32, 0.0), semitonesOfVibration(3.3, -5.0));
}

test "semitone quantise snaps to the nearest step" {
    try std.testing.expectEqual(@as(f32, 0.0), quantizeSemitones(0.4));
    try std.testing.expectEqual(@as(f32, 1.0), quantizeSemitones(0.5));
    try std.testing.expectEqual(@as(f32, 7.0), quantizeSemitones(6.7));
}

test "em volume follows the gain curve in volts" {
    try std.testing.expectEqual(gainOf(0.5, 1.2, valueOfVoltage(1.65)), volumeOfEm(0.5, 1.2, 1.65));
    try std.testing.expectEqual(@as(f32, 0.5), volumeOfEm(0.5, 0.0, 3.3));
    try std.testing.expect(volumeOfEm(0.5, 1.2, 3.3) > volumeOfEm(0.5, 1.2, 0.0));
    try std.testing.expect(volumeOfEm(0.5, 1.2, 3.3) <= 1.0);
}

test "digital threshold sits at half the rail" {
    try std.testing.expect(!isVibrating(0.0));
    try std.testing.expect(!isVibrating(1.6));
    try std.testing.expect(isVibrating(digital_threshold_v));
    try std.testing.expect(isVibrating(3.3));
}

test "debouncer commits an edge only after the level holds" {
    var d = Debouncer.init(40.0);
    try std.testing.expectEqual(Edge.none, d.step(true, 10.0));
    try std.testing.expectEqual(Edge.none, d.step(true, 10.0));
    try std.testing.expectEqual(Edge.none, d.step(true, 10.0));
    try std.testing.expectEqual(Edge.none, d.step(true, 10.0));
    try std.testing.expectEqual(Edge.rise, d.step(true, 10.0));
    try std.testing.expect(d.stable);
    // Steady state repeats no edge.
    try std.testing.expectEqual(Edge.none, d.step(true, 10.0));
}

test "debouncer swallows contact chatter" {
    var d = Debouncer.init(40.0);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        // 5 ms of alternating readings - a bouncing comparator, not a real hit.
        try std.testing.expectEqual(Edge.none, d.step(i % 2 == 0, 5.0));
    }
    try std.testing.expect(!d.stable);
}

test "debouncer reports the falling edge too" {
    var d = Debouncer.init(20.0);
    _ = d.step(true, 20.0);
    try std.testing.expectEqual(Edge.rise, d.step(true, 20.0));
    try std.testing.expectEqual(Edge.none, d.step(false, 20.0));
    try std.testing.expectEqual(Edge.fall, d.step(false, 20.0));
    try std.testing.expect(!d.stable);
}

test "zero debounce passes edges straight through" {
    var d = Debouncer.init(0.0);
    try std.testing.expectEqual(Edge.rise, d.step(true, 0.0));
    try std.testing.expectEqual(Edge.fall, d.step(false, 0.0));
    try std.testing.expectEqual(Edge.rise, d.step(true, 0.0));
}

test "smoother approaches its target without overshooting" {
    var s = Smoother.init(0.0, 100.0);
    var last: f32 = 0.0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const v = s.step(1.0, 20.0);
        try std.testing.expect(v >= last);
        try std.testing.expect(v <= 1.0);
        last = v;
    }
    try std.testing.expect(last > 0.99);
}

test "smoother with no time constant passes the target straight through" {
    var s = Smoother.init(0.0, 0.0);
    try std.testing.expectEqual(@as(f32, 0.75), s.step(0.75, 20.0));
    var t = Smoother.init(0.0, 100.0);
    try std.testing.expectEqual(@as(f32, 0.75), t.step(0.75, 0.0));
}

test "mock starts at the pothos baseline" {
    var m = MockModel.init(42);
    const input = m.tick();
    try std.testing.expectEqual(@as(u8, 55), input.sample.moisture_pct);
    try std.testing.expectApproxEqAbs(@as(f32, 23.0), input.sample.temperature_c, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), input.sample.humidity_pct, 0.001);
    try std.testing.expectEqual(@as(f32, 0.0), input.touch_intensity);
}

test "mock environmental outputs stay within calibrated bounds" {
    var m = MockModel.init(42);
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const input = m.tick();
        try std.testing.expect(input.sample.temperature_c >= 18.0);
        try std.testing.expect(input.sample.temperature_c <= 29.0);
        try std.testing.expect(input.sample.humidity_pct >= 45.0);
        try std.testing.expect(input.sample.humidity_pct <= 75.0);
    }
}

test "mock moisture dries and watering restores it" {
    var m = MockModel.init(42);
    _ = m.tick();
    var i: usize = 0;
    while (i < 100) : (i += 1) _ = m.tick();
    const dry = m.tick().sample.moisture_pct;
    try std.testing.expect(dry < 55);

    m.water();
    const wet = m.tick().sample.moisture_pct;
    try std.testing.expect(wet >= 69);
}

test "mock touch is continuous and decays" {
    var m = MockModel.init(42);
    m.touch();
    const peak = m.tick().touch_intensity;
    const next = m.tick().touch_intensity;
    try std.testing.expect(peak > 0.9 and peak <= 1.0);
    try std.testing.expect(next > 0.0 and next < peak);

    var i: usize = 0;
    while (i < 100) : (i += 1) _ = m.tick();
    try std.testing.expectEqual(@as(f32, 0.0), m.tick().touch_intensity);
}

test "mock output is deterministic for the same seed" {
    var a = MockModel.init(123);
    var b = MockModel.init(123);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const left = a.tick();
        const right = b.tick();
        try std.testing.expectEqual(left.sample.moisture_pct, right.sample.moisture_pct);
        try std.testing.expectEqual(left.sample.temperature_c, right.sample.temperature_c);
        try std.testing.expectEqual(left.sample.humidity_pct, right.sample.humidity_pct);
        try std.testing.expectEqual(left.touch_intensity, right.touch_intensity);
    }
}

test "moisture frequency mapping covers the audio range" {
    try std.testing.expectEqual(@as(f32, 20.0), freqOfMoisture(0));
    try std.testing.expectEqual(@as(f32, 880.0), freqOfMoisture(100));
    try std.testing.expect(freqOfMoisture(55) > 20.0 and freqOfMoisture(55) < 880.0);
}

test "moisture converts to the legacy raw-value domain" {
    try std.testing.expectEqual(@as(u16, 0), rawValueOfMoisture(0));
    try std.testing.expectEqual(@as(u16, 65535), rawValueOfMoisture(100));
}

test "moisture mappings clamp values above the calibrated range" {
    try std.testing.expectEqual(@as(f32, 880.0), freqOfMoisture(255));
    try std.testing.expectEqual(max_value, rawValueOfMoisture(255));
}
