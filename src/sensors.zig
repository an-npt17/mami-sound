//! Simulated plant sensors.
//!
//! Stands in for the real hardware: one ECG-style biopotential probe on plant A
//! and one touch pad per plant. Real ADC and GPIO reads replace the bodies of
//! `tick` and `touchAt` later; the types and signatures stay as they are.

const std = @import("std");

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
    /// Indexed by plant: 0 = A (ECG plant), 1 = B, 2 = C.
    touch: [plant_count]bool,
};

/// The scripted touch timeline, in seconds.
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

pub const Sensors = struct {
    prng: std.Random.DefaultPrng,
    sample_rate: u32,
    elapsed_frames: u64,
    ecg_volts: f32,

    pub fn init(sample_rate: u32, seed: u64) Sensors {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .sample_rate = sample_rate,
            .elapsed_frames = 0,
            // Start mid-range so the first block is already audible.
            .ecg_volts = (walk_min + walk_max) / 2.0,
        };
    }

    /// Advance the simulation by `frames` and report the current state.
    /// Called once per audio block.
    pub fn tick(self: *Sensors, frames: usize) Reading {
        const t = @as(f32, @floatFromInt(self.elapsed_frames)) /
            @as(f32, @floatFromInt(self.sample_rate));

        const delta = (self.prng.random().float(f32) - 0.5) * 2.0 * walk_step;
        self.ecg_volts = std.math.clamp(self.ecg_volts + delta, walk_min, walk_max);
        self.elapsed_frames += frames;

        return .{ .ecg_volts = self.ecg_volts, .touch = touchAt(t) };
    }
};
