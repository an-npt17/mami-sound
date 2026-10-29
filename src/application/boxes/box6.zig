//! Box 6. Its two probes need two different questions, so it is the one box
//! that asks them.
//!
//! Probe A rests at 582 to 592 and a hand takes it to -2060 to -2030: two
//! levels with a wide gap between. That is the `learned` rig exactly --
//! whichever level the probe keeps coming back to is rest, the other is a
//! hand, and the line is drawn halfway between them.
//!
//! Probe BC is the other way round. Untouched it scatters anywhere from about
//! 36 to 2030, and a hand pins it at 1030 to 1050 -- inside the very range it
//! scatters over, so no line can separate the two and `learned` would take the
//! scatter's middle for home. What separates them is how wide the window is,
//! which is what `scatter` asks. As `learned` does, it takes whichever state
//! the probe spends most of its time in as rest and the other as the hand, so
//! here the scatter is rest and stillness is the touch.

const defaults = @import("defaults.zig");

/// The spread at or below which BC's window is still, and at or above which it
/// is scattered. A hand holds it twenty counts wide; a scatter across 36 to
/// 2030 spreads over a thousand between the window's percentiles. Both lines
/// sit far from either, with the gap between them for the window passing from
/// one to the other.
const still_bc: i16 = 32;
const scattered_bc: i16 = 512;

/// Where a hand holds BC: 1030 to 1050 on the journal, with ten counts of
/// margin either side. Still anywhere else is not a hand -- the journal shows
/// the probe sliding off one to about 790 and sitting there, which with no
/// band played on as a touch.
const held_lo_bc: i16 = 1020;
const held_hi_bc: i16 = 1060;

pub const preset: defaults.Preset = blk: {
    var p = defaults.preset;
    p.touch.model = .learned;
    p.touch.model_bc = .scatter;
    p.touch.still_range_bc = still_bc;
    p.touch.still_release_bc = scattered_bc;
    p.touch.touch_band_lo_bc = held_lo_bc;
    p.touch.touch_band_hi_bc = held_hi_bc;
    break :blk p;
};

const std = @import("std");
const core = @import("../../core/root.zig");

test "box 6 asks each probe the question its rig answers" {
    try std.testing.expectEqual(core.touch.Model.learned, preset.touch.model);
    try std.testing.expectEqual(core.touch.Model.scatter, preset.touch.forBc().model);
}

test "BC's lines sit between a hand and a probe left scattering" {
    const held_width: i16 = 1050 - 1030;
    try std.testing.expect(still_bc > held_width);
    try std.testing.expect(scattered_bc > still_bc);
    try std.testing.expect(scattered_bc < (2030 - 36) / 2);
}

const poll_rate: usize = core.sample_rate / core.sensor_frames;

/// Probe A untouched: 582 to 592, as the room's log shows it.
fn restA(poll: usize) i16 {
    return 582 + @as(i16, @intCast(poll % 11));
}

/// Probe A under a hand: -2060 to -2030.
fn heldA(poll: usize) i16 {
    return -2060 + @as(i16, @intCast(poll % 31));
}

/// Probe BC untouched: anywhere from 36 to 2030.
fn restBc(poll: usize) i16 {
    const mixed = (poll *% 2654435761) >> 7;
    return 36 + @as(i16, @intCast(mixed % 1995));
}

/// Probe BC under a hand: 1030 to 1050.
fn heldBc(poll: usize) i16 {
    return 1030 + @as(i16, @intCast(poll % 21));
}

test "box 6 hears a hand on either plant, and only that plant" {
    var machine: core.touch.Machine = .init(preset.touch);
    var state: core.touch.State = .none;

    for (0..30 * poll_rate) |poll| state = machine.update(restA(poll), restBc(poll));
    try std.testing.expectEqual(core.touch.State.none, state);

    for (0..3 * poll_rate) |poll| state = machine.update(heldA(poll), restBc(poll));
    try std.testing.expectEqual(core.touch.State.plant_a, state);

    for (0..5 * poll_rate) |poll| state = machine.update(restA(poll), restBc(poll));
    try std.testing.expectEqual(core.touch.State.none, state);

    for (0..3 * poll_rate) |poll| state = machine.update(restA(poll), heldBc(poll));
    try std.testing.expectEqual(core.touch.State.plant_bc, state);

    for (0..3 * poll_rate) |poll| state = machine.update(restA(poll), restBc(poll));
    try std.testing.expectEqual(core.touch.State.none, state);

    // Held again, then slid off to about 790 and left still there.
    for (0..3 * poll_rate) |poll| state = machine.update(restA(poll), heldBc(poll));
    try std.testing.expectEqual(core.touch.State.plant_bc, state);
    for (0..3 * poll_rate) |poll| {
        state = machine.update(restA(poll), 786 + @as(i16, @intCast(poll % 9)));
    }
    try std.testing.expectEqual(core.touch.State.none, state);
}
