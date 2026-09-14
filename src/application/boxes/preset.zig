//! What one box is: the numbers its rig was measured at, and what its two
//! plants play.
//!
//! Every box runs the same detector. What differs between the five
//! installations is an electrode, a length of wire and a room, and all three
//! reach the program as numbers -- so they are written down here as numbers
//! rather than carried on a branch, which is how two boxes came to have two
//! detectors.

const core = @import("../../core/root.zig");

/// One plant's part in the piece.
pub const Plant = struct {
    source: core.source.Source,
    /// What a hand means here. The drone is held by nature and takes no mode,
    /// so a drone plant is recorded as `.trigger` and the detector is told
    /// nothing about it.
    mode: core.clips.Mode,
    /// How long a touch plays, and how long before the next is honoured.
    /// `null` leaves the source's own answer standing.
    seconds: ?f32 = null,
    retrigger: ?f32 = null,
};

/// Everything about a box that is not the algorithm.
pub const Preset = struct {
    touch: core.touch.Config,
    drone: core.noise.Shape,
    /// Indexed as the plant selection is: A first, then B.
    plants: [2]Plant,
};

const std = @import("std");

test "a plant is a source and what it does with a hand" {
    const plant: Plant = .{ .source = .voicebox3, .mode = .trigger };
    try std.testing.expectEqual(core.source.Source.voicebox3, plant.source);
    try std.testing.expectEqual(core.clips.Mode.trigger, plant.mode);
    // Unset lengths leave the source's own answer standing, which is what
    // every box wants until one of them measures otherwise.
    try std.testing.expect(plant.seconds == null);
    try std.testing.expect(plant.retrigger == null);
}
