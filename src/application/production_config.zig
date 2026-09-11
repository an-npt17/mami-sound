const core = @import("../core/root.zig");

/// The rig in the room decides which of the two models this is.
///
/// `deviation` is right where a probe rests somewhere and a touch moves it.
/// `steady` is right where the electrode floats: the flailing has no rest to
/// measure from, so what is asked instead is whether the probe has gone still.
/// On the floating rig `deviation` reads a MAD of about 260 counts on probe A,
/// which is a threshold no touch can clear.
///
/// The floating rig's preset. `steady` has to be told nothing about where a
/// held probe sits, which is the point: plant A's probe clamps somewhere near
/// 660 and plant B's near 1, neither is predictable from one day to the next,
/// and the model asks how tightly the readings cluster rather than where:
///
///     pub const touch: core.touch.Config = .{
///         .sample_rate = core.sample_rate,
///         .poll_frames = core.sensor_frames,
///         .model = .steady,
///     };
///
/// The two thresholds have defaults measured off `touch.csv`; `zig build
/// replay -- touch.csv --sweep` is how to check them against a fresh capture,
/// and `--still-range` is how to try a number without a rebuild.
///
/// `drone.span` has to move with it. In `steady` the pitch is the level the
/// probe went still at, so the span wants to be about the range those levels
/// fall in, and the floor is what makes a touch audible at all:
///
///     pub const drone: core.noise.Shape = .{
///         .span = 1000,
///         .touch_floor = 0.6,
///         .burst_s = 0.4,
///         .glide_s = 4.0,
///         .release_s = 0.5,
///     };
pub const touch: core.touch.Config = .{
    .sample_rate = core.sample_rate,
    .poll_frames = core.sensor_frames,
    .model = .deviation,
    .hold_bc_ms = 20.0,
    .counts = default_counts,
    .counts_bc = default_counts_bc,
};

/// How big a move a touch must be, in the counts the probe actually reads.
///
/// The score alone cannot answer this. It divides a move by how much the probe
/// normally wanders, and on this rig that denominator is meaningless: probe B
/// reads the supply rail to within seventy-two counts, so its median absolute
/// deviation sits on the floor of twenty-five -- while about one poll in
/// fifteen drops toward ground, and the *density* of those dropouts wanders
/// enough to move the average by seven hundred counts with nobody in the room.
/// Measured over fourteen seconds of the journal, probe B's rest reached 4.4
/// deviations against a threshold of six. Over an evening it crosses.
///
/// So a second threshold, in units the room can read off the status line and
/// the rig cannot inflate. Plant A's touch takes its probe from about 16300 up
/// past 25000, and plant B's takes its probe from about 24000 down to ground:
/// nine thousand counts and twenty-four thousand. The floors are set near half
/// of each, which is three times the worst wander probe A showed and thirteen
/// times probe B's.
///
/// Setting them also puts both probes on the banded release, where the latch
/// waits to be back at rest rather than decaying the moment the score dips.
/// That is what stops a reading sitting between the two thresholds from
/// chattering a clip on and off.
///
/// Read off fourteen seconds of a status line at one hertz. A capture is what
/// confirms them: `--capture=touch2.csv` in the room, then `zig build replay --
/// touch2.csv --model=deviation`.
pub const default_counts: i16 = 4000;
pub const default_counts_bc: i16 = 10000;

/// How long a tap may last and still be a tap, for whichever plant asks to be
/// one. Measured on the deviation rig, where it was plant B's whether anybody
/// wanted it or not.
pub const tap_window_ms: f32 = 1000.0;

/// What the room asked for on the command line, or nothing where it did not.
///
/// Named rather than positional because four of these are `?i16` in a row: a
/// caller that handed the range where the floor goes would compile, run, and
/// be wrong in a way no test could see.
pub const Overrides = struct {
    model: ?core.touch.Model = null,
    still_range: ?i16 = null,
    still_release: ?i16 = null,
    still_window_ms: ?f32 = null,
    touch_band: ?[2]i16 = null,
    /// The move in counts a touch must clear, per probe. Zero is the room
    /// saying "no floor at all", which is a different thing from leaving the
    /// flag off: off keeps the measured number, zero asks the score alone.
    counts: ?i16 = null,
    counts_bc: ?i16 = null,
};

/// The preset with the room's overrides applied. Anything left unset on the
/// command line keeps the number above, which is the one that was measured.
pub fn touchWith(
    overrides: Overrides,
    /// How each plant answers a hand. The detector is told the same thing the
    /// clips are: a hold wants a level, a tap wants a gesture, and a trigger
    /// wants the edge. Only a plant asked to be a tap is given a tap window --
    /// the window discards a hand that rests, which is the touch a room makes.
    modes: [2]core.clips.Mode,
) core.touch.Config {
    var cfg = touch;
    if (overrides.model) |chosen| cfg.model = chosen;
    cfg.hold = modes[0] == .hold;
    cfg.hold_bc = modes[1] == .hold;
    cfg.window_ms = if (modes[0] == .tap) tap_window_ms else null;
    cfg.window_bc_ms = if (modes[1] == .tap) tap_window_ms else null;
    if (overrides.still_range) |counts| cfg.still_range = counts;
    if (overrides.still_release) |counts| cfg.still_release = counts;
    if (overrides.still_window_ms) |ms| cfg.still_window_ms = ms;
    if (overrides.touch_band) |band| {
        cfg.touch_band_lo = band[0];
        cfg.touch_band_hi = band[1];
    }
    // Zero is the room asking for no floor, which the detector spells `null`.
    if (overrides.counts) |floor| cfg.counts = if (floor == 0) null else floor;
    if (overrides.counts_bc) |floor| cfg.counts_bc = if (floor == 0) null else floor;
    return cfg;
}

pub const seed: u64 = 0xC0FFEE;

pub const drone: core.noise.Shape = .{
    .span = 3000,
    .burst_s = 0.4,
    .glide_s = 4.0,
    .release_s = 0.5,
};

const std = @import("std");

test "an override reaches the config and the rest of the preset stands" {
    const cfg = touchWith(.{ .model = .steady, .still_range = 64 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(core.touch.Model.steady, cfg.model);
    try std.testing.expectEqual(@as(i16, 64), cfg.still_range);
    // Untouched by the override, so still the measured number.
    try std.testing.expectEqual(touch.still_release, cfg.still_release);
    try std.testing.expectEqual(touch.level_bc, cfg.level_bc);
}

test "no overrides is the preset exactly" {
    try std.testing.expectEqual(touch, touchWith(.{}, .{ .trigger, .trigger }));
}

test "each plant is told to hold on its own" {
    // Whichever plant is held, the other keeps whatever it was given. The two
    // are configured separately and must stay that way through every layer.
    const a_held = touchWith(.{}, .{ .hold, .trigger });
    try std.testing.expect(a_held.hold);
    try std.testing.expect(!a_held.hold_bc);

    const both = touchWith(.{}, .{ .hold, .hold });
    try std.testing.expect(both.hold);
    try std.testing.expect(both.hold_bc);

    const neither = touchWith(.{}, .{ .trigger, .trigger });
    try std.testing.expect(!neither.hold);
    try std.testing.expect(!neither.hold_bc);
}

test "a held plant drops its tap window, and only that plant's" {
    // The preset gives plant B a tap window for the rig it was measured on. A
    // plant told to sound while it is held cannot also be asked whether the
    // hand left in time, and the other plant keeps whatever it was given.
    const b_held = touchWith(.{}, .{ .trigger, .hold });
    try std.testing.expect(!b_held.hold);
    try std.testing.expect(b_held.hold_bc);

    const machine: core.touch.Machine = .init(b_held);
    try std.testing.expect(machine.bc.window == null);
}

test "a plant left on trigger is given no tap window" {
    // The fault as the room met it. The preset handed plant B a tap window
    // nobody asked for, and a tap window discards a hand that rests -- which is
    // every touch a room makes. Plant B crossed its threshold twenty-four times
    // in one log of a thousand polls and sounded on none of them.
    const cfg = touchWith(.{}, .{ .trigger, .trigger });
    const machine: core.touch.Machine = .init(cfg);
    try std.testing.expect(machine.a.window == null);
    try std.testing.expect(machine.bc.window == null);
}

test "a plant asked for a tap is given the window" {
    // And the gesture is still there for whoever wants it, on either plant.
    const cfg = touchWith(.{}, .{ .tap, .tap });
    const machine: core.touch.Machine = .init(cfg);
    try std.testing.expect(machine.a.window != null);
    try std.testing.expect(machine.bc.window != null);
}

test "both probes need the same excursion to count as touched" {
    // Plant B asked for ten deviations against plant A's six, which made it the
    // harder plant to sound for no reason the rig ever gave. Unset, plant B
    // takes plant A's level.
    try std.testing.expect(touch.level_bc == null);
}

test "a hand left resting on plant B latches under the shipped preset" {
    // The whole of the bug in one test: the compiled preset, no flags, a hand
    // that arrives and stays. This is what the service runs.
    const cfg = touchWith(.{}, .{ .trigger, .trigger });
    var machine: core.touch.Machine = .init(cfg);

    var polls_on: usize = 0;
    for (0..4000) |_| _ = machine.update(0, 0);
    for (0..3000) |_| {
        _ = machine.update(0, 3000);
        if (machine.bc.on) polls_on += 1;
    }
    // Windowed, this managed under five hundred. A probe that reports the hand
    // reports it for most of the time it is there.
    try std.testing.expect(polls_on > 1500);
}

test "a rail-to-rail touch is answered the same in either direction" {
    // The rig's actual gesture: a probe sitting at one rail and a hand throwing
    // it to the other. Which rail is rest varies by plant and by day -- one
    // install rests near 660 and is boosted to 25905, another rests at 25905
    // and is pulled to 660 -- so the model is asked for the size of the move
    // and never for its sign. Both directions must cost the same.
    //
    // The numbers are the room's, not an implementation detail: how long after
    // the hand lands the clip starts. They are held here so a change to the
    // averaging or the debounce cannot quietly make the piece late.
    const cfg = touchWith(.{}, .{ .trigger, .trigger });
    const polls_per_s =
        @as(f32, @floatFromInt(core.sample_rate)) / @as(f32, @floatFromInt(core.sensor_frames));

    var latch_ms: [2]f32 = undefined;
    for ([_][2]i16{ .{ 660, 25905 }, .{ 25905, 660 } }, 0..) |rails, direction| {
        var machine: core.touch.Machine = .init(cfg);
        for (0..8000) |_| _ = machine.update(0, rails[0]);

        var on: usize = 0;
        while (!machine.bc.on and on < 4000) : (on += 1) _ = machine.update(0, rails[1]);
        latch_ms[direction] = @as(f32, @floatFromInt(on)) / polls_per_s * 1000.0;

        var off: usize = 0;
        while (machine.bc.on and off < 4000) : (off += 1) _ = machine.update(0, rails[0]);
        const release_ms = @as(f32, @floatFromInt(off)) / polls_per_s * 1000.0;

        // Plant B debounces for twenty milliseconds and no more: the move is a
        // thousand deviations wide, so nothing is gained by looking longer.
        try std.testing.expect(latch_ms[direction] < 40.0);
        // Letting go costs the averaging window, which is the price of a mean
        // that a spike cannot drag. A quarter second is under the fade.
        try std.testing.expect(release_ms < 300.0);

        var a_machine: core.touch.Machine = .init(cfg);
        for (0..8000) |_| _ = a_machine.update(rails[0], 0);
        var a_on: usize = 0;
        while (!a_machine.a.on and a_on < 4000) : (a_on += 1) _ = a_machine.update(rails[1], 0);
        const a_ms = @as(f32, @floatFromInt(a_on)) / polls_per_s * 1000.0;
        // Plant A holds for a hundred milliseconds before it believes a hand.
        try std.testing.expect(a_ms < 120.0);
    }

    // The sign of the move buys nothing and costs nothing.
    try std.testing.expectEqual(latch_ms[0], latch_ms[1]);
}

test "the preset carries a floor for each probe" {
    // Unset, the score was the only threshold either probe had, and on this
    // rig the score's denominator is noise about noise.
    try std.testing.expect(touch.counts != null);
    try std.testing.expect(touch.counts_bc != null);
    try std.testing.expectEqual(default_counts_bc, touch.forBc().counts.?);
    try std.testing.expectEqual(default_counts, touch.counts.?);
}

test "the floors clear what the rig's rest actually does" {
    // The numbers off fourteen seconds of the journal at one hertz: the worst
    // either probe's average wandered from its own median with nobody there.
    // Held here because the floors are only worth having while they are well
    // clear of these, and because a later capture that moves them should fail
    // this test rather than quietly leave a probe firing on its own dropouts.
    const worst_rest_a: i16 = 1199;
    const worst_rest_bc: i16 = 763;
    try std.testing.expect(default_counts > worst_rest_a * 3);
    try std.testing.expect(default_counts_bc > worst_rest_bc * 3);

    // And are still under the move a hand makes, or they would gag the plant.
    const touch_move_a: i16 = 8674;
    const touch_move_bc: i16 = 23977;
    try std.testing.expect(default_counts < touch_move_a);
    try std.testing.expect(default_counts_bc < touch_move_bc);
}

test "a floor asked for in the room replaces the measured one" {
    const cfg = touchWith(.{ .counts = 2500, .counts_bc = 15000 }, .{ .trigger, .trigger });
    try std.testing.expectEqual(@as(i16, 2500), cfg.counts.?);
    try std.testing.expectEqual(@as(i16, 15000), cfg.counts_bc.?);
    try std.testing.expectEqual(@as(i16, 15000), cfg.forBc().counts.?);
}

test "zero is no floor at all, which is not the same as leaving the flag off" {
    // Off keeps the measured number; zero is the room saying it wants the
    // score alone back, which is the one way to get the old behaviour without
    // a rebuild.
    const none = touchWith(.{ .counts = 0, .counts_bc = 0 }, .{ .trigger, .trigger });
    try std.testing.expect(none.counts == null);
    try std.testing.expect(none.counts_bc == null);
    try std.testing.expect(none.forBc().counts == null);

    const untouched_by_flags = touchWith(.{}, .{ .trigger, .trigger });
    try std.testing.expectEqual(default_counts, untouched_by_flags.counts.?);
}

test "one probe's floor can be cleared without clearing the other's" {
    // They are separate thresholds about separate probes, and `forBc` falls
    // back to A's when BC has none -- so clearing A alone must not take BC's
    // floor with it.
    const cfg = touchWith(.{ .counts = 0 }, .{ .trigger, .trigger });
    try std.testing.expect(cfg.counts == null);
    try std.testing.expectEqual(default_counts_bc, cfg.forBc().counts.?);
}
