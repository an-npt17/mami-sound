//! Plant sensors: two ECG-style biopotential probes and one motion sensor per
//! plant.
//!
//! The probes do different jobs. The one on AIN0 is plant A's, and its reading
//! is a pitch: it is all plant A's voice ever listens to. The one on AIN1 sits
//! on the other side of the room and is a switch rather than a pitch — crossing
//! its threshold is what lets plants B and C play their clips. Neither probe
//! reaches the other's plants.
//!
//! Each input has a real backend and a simulated one, attached or not at start
//! up: the probes read an ADS1115 over I2C or an imitation of the bench, and
//! the plants
//! wake on GPIO motion lines or on a scripted timeline. Nothing downstream can
//! tell the difference, so the whole engine runs on a machine with no hardware
//! attached.

const std = @import("std");
const ads1115 = @import("ads1115.zig");
const gpio = @import("gpio.zig");

pub const plant_count = 3;

/// Where each probe is wired. Both are read against ground: these are two
/// separate probes on one chip, not the two halves of a differential pair.
pub const input_a: ads1115.Mux = .ain0_gnd;
pub const input_bc: ads1115.Mux = .ain1_gnd;

/// The converter's full scale: 32767 at the configured range, 0 at ground.
///
/// No longer anything to do with detection, which reads the signed count
/// directly and measures how far it has moved from its own rest. What is left
/// reading this is the flute and beep bench voices, which map a count onto a
/// pitch and need to know how big a count can get.
pub const ecg_max: i16 = std.math.maxInt(i16);

/// What the untouched rig reads on the bench, which is what the simulation
/// imitates. Probe A sits below ground and barely moves; probe BC floats and
/// picks up whatever is in the room, always positive.
const sim_a_rest: i16 = -2049;
const sim_bc_max: u16 = 2000;

fn simA(random: std.Random) i16 {
    return sim_a_rest - @as(i16, @intCast(random.uintLessThan(u8, 2)));
}

fn simBc(random: std.Random) i16 {
    return @intCast(random.uintLessThan(u16, sim_bc_max + 1));
}

/// Frames that must pass between pointing the multiplexer at a probe and
/// reading what it converted.
///
/// The engine polls four times per block, but not four times a block apart. It
/// renders the whole block in one burst — under 30 us of work — and then sits
/// in the sink's `write` until the card wants more, so consecutive polls are
/// only as far apart as the I2C transactions between them: a few hundred
/// microseconds, well under the 1.16 ms a conversion takes at 860 SPS. A probe
/// switched at one poll and read at the next would report the *other* probe's
/// last conversion.
///
/// One block is what reliably puts that blocking write between the switch and
/// the read. The cost is that each probe now updates every second block rather
/// than every second poll: a burst of four fresh conversions, then 23 ms of
/// holding. That is still far inside the voices' one-second smoothing, and
/// finer than a threshold can tell.
pub const switch_frames: u64 = 512;

pub const Reading = struct {
    /// The AIN0 probe, exactly as the chip reported it. Signed and unrectified:
    /// this probe rests below ground and rises through it when touched, so the
    /// sign is the signal and folding it away destroys the reading.
    raw_a: i16,
    /// The AIN1 probe, on the same terms.
    raw_bc: i16,
    /// Per plant, whether its motion sensor says someone is there. Indexed
    /// 0 = A, 1 = B, 2 = C. Unconsulted while the probes decide.
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

/// Where the per-plant awake flags come from.
pub const Touch = union(enum) {
    /// Every plant awake, every block. What to use while the motion sensors are
    /// not wired yet: it takes them out of the picture entirely, so anything
    /// still wrong is the ECG, the mix or the sound card.
    always,
    /// The scripted timeline, for demonstrating the piece without hardware.
    script,
    /// One GPIO line per plant.
    motion: gpio.Lines,
};

/// Which probe a reading belongs to. Also the order the chip is stepped
/// through, since there are only two.
const Probe = enum {
    a,
    bc,

    fn mux(self: Probe) ads1115.Mux {
        return switch (self) {
            .a => input_a,
            .bc => input_bc,
        };
    }

    fn other(self: Probe) Probe {
        return switch (self) {
            .a => .bc,
            .bc => .a,
        };
    }
};

pub const Sensors = struct {
    prng: std.Random.DefaultPrng,
    sample_rate: u32,
    elapsed_frames: u64,
    raw_a: i16,
    raw_bc: i16,
    /// Which probe the chip is converting, and so which one the next read
    /// belongs to. Meaningless without an ADC: the simulation redraws both
    /// probes every poll.
    selected: Probe,
    /// Frames since the multiplexer last moved, so the switch can be held off
    /// until a conversion has had time to finish. See `switch_frames`.
    frames_since_switch: u64,
    /// Held so a failed read repeats the last state instead of cutting a voice.
    touch_state: [plant_count]bool,
    touch: Touch,
    /// `null` runs the random walk instead.
    adc: ?ads1115.Ads1115,

    /// Both probes simulated, every plant awake. `attachAdc` and `attachMotion`
    /// swap in real hardware one input at a time, so a half-wired installation
    /// runs.
    pub fn init(sample_rate: u32, seed: u64) Sensors {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .sample_rate = sample_rate,
            .elapsed_frames = 0,
            // Start at rest, so the first block already reads as untouched.
            .raw_a = sim_a_rest,
            .raw_bc = 0,
            .selected = .a,
            .frames_since_switch = 0,
            .touch_state = .{true} ** plant_count,
            .touch = .always,
            .adc = null,
        };
    }

    /// Both probes now come from an already-opened ADS1115, whose multiplexer
    /// must be pointing at `input_a`. The seed still matters: it is what the
    /// simulation falls back to if the bus goes quiet.
    pub fn attachAdc(self: *Sensors, adc: ads1115.Ads1115) void {
        std.debug.assert(adc.cfg.mux == input_a);
        self.adc = adc;
        self.selected = .a;
        self.frames_since_switch = 0;
    }

    /// The plants now wake on motion. `lines` must carry exactly one line per
    /// plant, in plant order.
    pub fn attachMotion(self: *Sensors, lines: gpio.Lines) void {
        std.debug.assert(lines.count == plant_count);
        self.touch = .{ .motion = lines };
        // Nothing is known about the sensors until the first read; assume the
        // room is empty rather than opening every voice for one block.
        self.touch_state = .{false} ** plant_count;
    }

    pub fn useScript(self: *Sensors) void {
        self.touch = .script;
        self.touch_state = .{false} ** plant_count;
    }

    pub fn deinit(self: *Sensors) void {
        if (self.adc) |*adc| adc.close();
        switch (self.touch) {
            .motion => |*lines| lines.close(),
            else => {},
        }
        self.adc = null;
        self.touch = .always;
    }

    /// Advance by `frames` and report the current state. Called once per poll,
    /// which is also when the devices are sampled: one or two I2C transactions
    /// and one ioctl per poll, well inside the poll's own duration.
    pub fn tick(self: *Sensors, frames: usize) Reading {
        const t = @as(f32, @floatFromInt(self.elapsed_frames)) /
            @as(f32, @floatFromInt(self.sample_rate));

        if (self.adc) |*adc| {
            // One converter, two probes: read whichever the multiplexer is on,
            // and move it only once a whole block has passed, so the sink's
            // blocking write covers the conversion. Polls inside a block all
            // read the same probe — not the same number, since the chip keeps
            // converting continuously, so they are four fresh samples of it.
            //
            // A failed read holds the last value rather than dropping the voice
            // to silence: a glitch on the bus should not be audible.
            if (adc.readRaw()) |raw| {
                switch (self.selected) {
                    .a => self.raw_a = raw,
                    .bc => self.raw_bc = raw,
                }
            } else |_| {}

            self.frames_since_switch += frames;
            if (self.frames_since_switch >= switch_frames) {
                // A failed switch leaves the chip where it is, so the same
                // probe is read again and the other one holds. Better than
                // recording the new selection and then filing this input's
                // number under the other probe.
                const next = self.selected.other();
                if (adc.selectInput(next.mux())) |_| {
                    self.selected = next;
                    self.frames_since_switch = 0;
                } else |_| {}
            }
        } else {
            self.raw_a = simA(self.prng.random());
            self.raw_bc = simBc(self.prng.random());
        }

        switch (self.touch) {
            .always => self.touch_state = .{true} ** plant_count,
            .script => self.touch_state = touchAt(t),
            .motion => |*lines| {
                var next: [plant_count]bool = undefined;
                // A failed ioctl holds the last state, for the same reason a
                // failed ADC read holds the last reading.
                if (lines.read(&next)) |_| self.touch_state = next else |_| {}
            },
        }

        self.elapsed_frames += frames;

        return .{ .raw_a = self.raw_a, .raw_bc = self.raw_bc, .touch = self.touch_state };
    }
};

const testing = std.testing;

test "by default every plant is awake from the first block" {
    var sens = Sensors.init(44100, 1);
    for (0..10) |_| {
        for (sens.tick(512).touch) |awake| try testing.expect(awake);
    }
}

test "the script still gates the plants when asked for" {
    var sens = Sensors.init(44100, 1);
    sens.useScript();
    // Nothing is awake before plant A's cue at one second.
    for (sens.tick(512).touch) |awake| try testing.expect(!awake);

    var elapsed: usize = 512;
    while (elapsed < 44100 * 2) : (elapsed += 512) _ = sens.tick(512);
    try testing.expectEqual([plant_count]bool{ true, false, false }, sens.tick(512).touch);
}

test "the simulated rig looks like the bench: A pinned, BC noisy and positive" {
    var sens = Sensors.init(44100, 1);
    for (0..500) |_| {
        const reading = sens.tick(512);
        // Probe A untouched is -2049 or -2050 and nothing else.
        try testing.expect(reading.raw_a <= -2049 and reading.raw_a >= -2050);
        // Probe BC untouched wanders across the positive half.
        try testing.expect(reading.raw_bc >= 0 and reading.raw_bc <= sim_bc_max);
    }
}

test "the simulated probes are drawn apart, not as one number" {
    var sens = Sensors.init(44100, 7);
    var moved_apart = false;
    for (0..500) |_| {
        const reading = sens.tick(512);
        if (reading.raw_a != reading.raw_bc) moved_apart = true;
    }
    try testing.expect(moved_apart);
}

test "the simulation never fakes a touch" {
    // A run with no hardware reports an untouched rig, because that is what an
    // unattended bench is. `--touch=script` is how the piece is demonstrated
    // without electrodes; inventing touches here would hide a dead I2C bus.
    var sens = Sensors.init(44100, 1);
    for (0..500) |_| {
        const reading = sens.tick(512);
        try testing.expect(reading.raw_a < 0);
    }
}

test "the probes are two single-ended inputs, not a differential pair" {
    try testing.expectEqual(ads1115.Mux.ain0_gnd, input_a);
    try testing.expectEqual(ads1115.Mux.ain1_gnd, input_bc);
    try testing.expect(input_a != input_bc);
}

test "the chip is stepped between the two probes and back" {
    try testing.expectEqual(Probe.bc, Probe.a.other());
    try testing.expectEqual(Probe.a, Probe.bc.other());
    try testing.expectEqual(input_a, Probe.a.mux());
    try testing.expectEqual(input_bc, Probe.bc.mux());
}

test "the multiplexer holds still for a whole block between moves" {
    var sens = Sensors.init(44100, 1);
    // No chip on this machine, so drive the counter the way `tick` does and
    // check the rule it gates on rather than the I2C that follows from it.
    var frames: u64 = 0;
    var moves: usize = 0;
    while (frames < switch_frames * 4) : (frames += 128) {
        sens.frames_since_switch += 128;
        if (sens.frames_since_switch >= switch_frames) {
            sens.frames_since_switch = 0;
            moves += 1;
        }
    }
    // Four blocks' worth of polls, four moves: one per block, never one per
    // poll. A poll-rate switch would be sixteen.
    try testing.expectEqual(@as(usize, 4), moves);
}

test "a probe is never read sooner than a conversion after its own switch" {
    // 860 SPS, the rate `ads1115.Config` asks for.
    const conversion_ms = 1000.0 / 860.0;
    const held_ms = @as(f32, @floatFromInt(switch_frames)) / 44100.0 * 1000.0;
    try testing.expect(held_ms > conversion_ms);
    // With margin: the point is not to squeak past it.
    try testing.expect(held_ms > conversion_ms * 5.0);
}
