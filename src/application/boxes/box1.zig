//! Box 1. The detector has not been measured in this room yet -- the floors and
//! the drone's span are what a visit with `--capture` is for, and a number here
//! before then would be a guess dressed as a measurement.
//!
//! What IS known is what box 1 plays, because it has been running it: a bird on
//! plant A and a bell on plant B, both to the clip's own end, both with a
//! three second guard. That was carried in the service unit's flags, where it
//! could not be read from the source and drifted out of anybody's sight; it is
//! written down here instead.

const defaults = @import("defaults.zig");

/// Both plants play the whole clip rather than a slice of one.
///
/// Zero is a setting and not an absence: the sources' own answers are five
/// seconds for a bird call and four for a bell stem, and the room asked for
/// neither. A call cut at five seconds is half a call, and a stem cut at four
/// is the note without its tail.
const play_to_the_end: f32 = 0.0;

/// How long a clip is protected from the next hand, counted from when it
/// started. Three rather than the five every source defaults to: these are
/// short recordings, and a room that has heard one is ready for the next
/// sooner than a voice box's five minutes would want.
const guard_s: f32 = 3.0;

pub const preset: defaults.Preset = blk: {
    var p = defaults.preset;
    p.plants = .{
        .{
            .source = .daybird,
            .mode = .trigger,
            .seconds = play_to_the_end,
            .retrigger = guard_s,
        },
        .{
            .source = .bell,
            .mode = .trigger,
            .seconds = play_to_the_end,
            .retrigger = guard_s,
        },
    };
    break :blk p;
};

const std = @import("std");

test "box 1 plays what box 1 has been playing" {
    // The service unit's flags, as a preset. This test is the record that the
    // two agree: if somebody changes what the room runs, one of them has to
    // move, and this is what makes it the visible one.
    //
    //     --plant-a=daybird --plant-a-seconds=0 --plant-a-retrigger=3
    //     --plant-b=bell    --plant-b-seconds=0 --plant-b-retrigger=3
    try std.testing.expectEqual(@as(@TypeOf(preset.plants[0].source), .daybird), preset.plants[0].source);
    try std.testing.expectEqual(@as(@TypeOf(preset.plants[1].source), .bell), preset.plants[1].source);
    try std.testing.expectEqual(@as(f32, 0.0), preset.plants[0].seconds.?);
    try std.testing.expectEqual(@as(f32, 0.0), preset.plants[1].seconds.?);
    try std.testing.expectEqual(@as(f32, 3.0), preset.plants[0].retrigger.?);
    try std.testing.expectEqual(@as(f32, 3.0), preset.plants[1].retrigger.?);
}

test "neither plant is asked to be held" {
    // Both were left off the mode flag in the room, which is a trigger: a touch
    // sets the clip going and it runs its own length whether the hand stays or
    // not. Recorded rather than defaulted, because a hold would reach the
    // detector through touchWith and make this a different rig.
    try std.testing.expectEqual(@as(@TypeOf(preset.plants[0].mode), .trigger), preset.plants[0].mode);
    try std.testing.expectEqual(@as(@TypeOf(preset.plants[1].mode), .trigger), preset.plants[1].mode);
}

test "the detector is still the unmeasured default" {
    // The half of this box nobody has measured. A floor here would be a number
    // from another room; when box 1 is captured and swept, this is the test
    // that should start failing.
    try std.testing.expect(preset.touch.counts == null);
    try std.testing.expect(preset.touch.counts_bc == null);
    try std.testing.expectEqual(defaults.preset.drone.span, preset.drone.span);
}
