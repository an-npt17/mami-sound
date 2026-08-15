//! Plant sensors: one ECG-style biopotential probe on plant A and one motion
//! sensor per plant.
//!
//! Each input has a real backend and a simulated one, attached or not at start
//! up: the ECG probe reads an ADS1115 over I2C or a random walk, and the plants
//! wake on GPIO motion lines or on a scripted timeline. Nothing downstream can
//! tell the difference, so the whole engine runs on a machine with no hardware
//! attached.

const std = @import("std");
const ads1115 = @import("ads1115.zig");
const gpio = @import("gpio.zig");

pub const plant_count = 3;

/// Full scale of the ECG sensor.
pub const volts_max: f32 = 3.3;

/// The simulated plant never reaches the rails; a real one would not either.
const walk_min: f32 = 0.3;
const walk_max: f32 = 3.0;

/// Volts of drift per block. Small enough that audible pitch movement takes
/// seconds, which is what the slow-envelope mapping wants.
const walk_step: f32 = 0.05;

pub const Reading = struct {
    ecg_volts: f32,
    /// Per plant, whether it is awake: someone is at it. Indexed 0 = A (the ECG
    /// plant), 1 = B, 2 = C.
    touch: [plant_count]bool,
};

/// The scripted stand-in for the motion sensors, in seconds.
///
/// Plant A is held long enough to hear the drone glide. B and C are brief taps
/// placed inside that window so every run exercises two and three voices
/// sounding at once.
const a_start: f32 = 1.0;
const a_end: f32 = 12.0;
const b_start: f32 = 3.0;
const b_end: f32 = 3.1;
const c_start: f32 = 7.0;
const c_end: f32 = 7.1;

/// Touch state at time `t` seconds. Pure, so the schedule can be tested without
/// running the engine.
pub fn touchAt(t: f32) [plant_count]bool {
    return .{
        t >= a_start and t < a_end,
        t >= b_start and t < b_end,
        t >= c_start and t < c_end,
    };
}

/// Fold an ADS1115 reading onto the range the voices expect.
///
/// The probe reads plant health as a level against ground, on the same 0-3.3 V
/// scale the voices already map from, so the reading passes straight through.
/// The clamp is for the ADC's range overhanging the supply: it is set to
/// +/-4.096 V so that 3.3 V does not saturate, which also means it can report
/// volts the plant cannot actually produce. Pure, so the mapping is testable
/// without a chip.
pub fn ecgFromAdc(volts: f32) f32 {
    return std.math.clamp(volts, 0.0, volts_max);
}

pub const Sensors = struct {
    prng: std.Random.DefaultPrng,
    sample_rate: u32,
    elapsed_frames: u64,
    ecg_volts: f32,
    /// Held so a failed read repeats the last state instead of cutting a voice.
    touch: [plant_count]bool,
    /// `null` runs the random walk instead.
    adc: ?ads1115.Ads1115,
    /// `null` runs the scripted timeline instead.
    motion: ?gpio.Lines,

    /// Fully simulated. `attachAdc` and `attachMotion` swap in real hardware
    /// one input at a time, so a half-wired installation still runs.
    pub fn init(sample_rate: u32, seed: u64) Sensors {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .sample_rate = sample_rate,
            .elapsed_frames = 0,
            // Start mid-range so the first block is already audible.
            .ecg_volts = (walk_min + walk_max) / 2.0,
            .touch = .{false} ** plant_count,
            .adc = null,
            .motion = null,
        };
    }

    /// Plant A's voltage now comes from an already-opened ADS1115. The seed
    /// still matters: it is what the walk falls back to if the bus goes quiet.
    pub fn attachAdc(self: *Sensors, adc: ads1115.Ads1115) void {
        self.adc = adc;
    }

    /// The plants now wake on motion. `lines` must carry exactly one line per
    /// plant, in plant order.
    pub fn attachMotion(self: *Sensors, lines: gpio.Lines) void {
        std.debug.assert(lines.count == plant_count);
        self.motion = lines;
    }

    pub fn deinit(self: *Sensors) void {
        if (self.adc) |*adc| adc.close();
        if (self.motion) |*lines| lines.close();
        self.adc = null;
        self.motion = null;
    }

    /// Advance by `frames` and report the current state. Called once per audio
    /// block, which is also when both devices are sampled: one I2C transaction
    /// and one ioctl per block, well inside the block's own duration.
    pub fn tick(self: *Sensors, frames: usize) Reading {
        const t = @as(f32, @floatFromInt(self.elapsed_frames)) /
            @as(f32, @floatFromInt(self.sample_rate));

        if (self.adc) |*adc| {
            // A failed read holds the last value rather than dropping the voice
            // to silence: a glitch on the bus should not be audible.
            if (adc.readVolts()) |volts| {
                self.ecg_volts = ecgFromAdc(volts);
            } else |_| {}
        } else {
            const delta = (self.prng.random().float(f32) - 0.5) * 2.0 * walk_step;
            self.ecg_volts = std.math.clamp(self.ecg_volts + delta, walk_min, walk_max);
        }

        if (self.motion) |*lines| {
            var next: [plant_count]bool = undefined;
            if (lines.read(&next)) |_| self.touch = next else |_| {}
        } else {
            self.touch = touchAt(t);
        }

        self.elapsed_frames += frames;

        return .{ .ecg_volts = self.ecg_volts, .touch = self.touch };
    }
};

const testing = std.testing;

test "adc readings land inside the voice's range" {
    // A reading the plant can produce is the voltage the voices see, untouched.
    try testing.expectApproxEqAbs(@as(f32, 0.0), ecgFromAdc(0.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.65), ecgFromAdc(1.65), 0.001);
    try testing.expectApproxEqAbs(volts_max, ecgFromAdc(volts_max), 0.001);
    // The ADC's range overhangs the supply at both ends; the voices' does not.
    try testing.expectApproxEqAbs(volts_max, ecgFromAdc(4.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), ecgFromAdc(-0.5), 0.001);
}

test "without an adc the walk stays in range" {
    var sens = Sensors.init(44100, 1);
    for (0..500) |_| {
        const reading = sens.tick(512);
        try testing.expect(reading.ecg_volts >= walk_min);
        try testing.expect(reading.ecg_volts <= walk_max);
    }
}
