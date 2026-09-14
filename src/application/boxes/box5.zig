//! Box 5. Probe B reads the supply rail and drops toward ground about one poll
//! in fifteen, so its floor is read in counts rather than in deviations.

const defaults = @import("defaults.zig");

/// Measured over fourteen seconds of the journal: probe B's rest reached 4.4
/// deviations against a threshold of six, which over an evening crosses. The
/// floors are in units the room can read off the status line and the rig
/// cannot inflate -- plant A's touch takes its probe from about 16300 past
/// 25000, plant B's from about 24000 down to ground, and each floor sits near
/// half of that.
const counts: i16 = 4000;
const counts_bc: i16 = 10000;

pub const preset: defaults.Preset = blk: {
    var p = defaults.preset;
    p.touch.counts = counts;
    p.touch.counts_bc = counts_bc;
    p.plants[1] = .{ .source = .voicebox5, .mode = .trigger };
    // The drone reads plant A's probe, and the core default span of 3000 is
    // under this rig's own floor of 4000 -- inherited unexamined from the
    // branch, where nothing tested it. Plant A's touch takes its probe from
    // about 16300 up past 25000: a move of about 8674, which is the span it
    // wants so a touch spends the range instead of saturating it.
    p.drone.span = 8674;
    break :blk p;
};

const std = @import("std");

test "the floors clear what the rig's rest actually does" {
    // The numbers off fourteen seconds of the journal at one hertz: the worst
    // either probe's average wandered from its own median with nobody there.
    // Held here because the floors are only worth having while they are well
    // clear of these, and because a later capture that moves them should fail
    // this test rather than quietly leave a probe firing on its own dropouts.
    const worst_rest_a: i16 = 1199;
    const worst_rest_bc: i16 = 763;
    try std.testing.expect(preset.touch.counts.? > worst_rest_a * 3);
    try std.testing.expect(preset.touch.counts_bc.? > worst_rest_bc * 3);

    // And are still under the move a hand makes, or they would gag the plant.
    const touch_move_a: i16 = 8674;
    const touch_move_bc: i16 = 23977;
    try std.testing.expect(preset.touch.counts.? < touch_move_a);
    try std.testing.expect(preset.touch.counts_bc.? < touch_move_bc);
}

test "the span is the move plant A's probe actually makes" {
    // Not a ratio of the floor: the span is the deviation that should reach the
    // top of the pitch range, so it is the move itself. Plant A's touch takes
    // its probe from about 16300 up past 25000. The branch left this at the
    // core default of 3000, under this rig's own floor of 4000, where every
    // touch that counted at all arrived at the top of the range -- which is the
    // one thing the drone must not do.
    const touch_move_a: i16 = 8674;
    try std.testing.expectEqual(touch_move_a, preset.drone.span);
}
