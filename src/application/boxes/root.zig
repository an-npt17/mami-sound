//! Which box this is, and what that box was measured at.
//!
//! Five files, one detector. A box may set a number the detector reads; it may
//! not ask the detector a different question. That is the whole rule, and the
//! reason this directory exists.

const core = @import("../../core/root.zig");
const defaults = @import("defaults.zig");

pub const Preset = defaults.Preset;
pub const Plant = defaults.Plant;

pub const Box = enum { box1, box2, box3, box4, box5 };

/// What a machine that is none of the five runs: the defaults, unmeasured and
/// saying so.
pub const default_preset: Preset = defaults.preset;

pub fn presetFor(box: Box) Preset {
    return switch (box) {
        .box1 => @import("box1.zig").preset,
        .box2 => @import("box2.zig").preset,
        .box3 => @import("box3.zig").preset,
        .box4 => @import("box4.zig").preset,
        .box5 => @import("box5.zig").preset,
    };
}

/// The box a hostname names, or none.
///
/// A prefix rather than an exact match, because the Pis answer to `box3`,
/// `box3.local` and `box3-pi` depending on who is asking. Anything that is not
/// one of the five is none: a bench silently running box2's floors is worse
/// than one that says it is nobody.
pub fn fromHostname(name: []const u8) ?Box {
    inline for (@typeInfo(Box).@"enum".fields) |field| {
        if (std.mem.startsWith(u8, name, field.name)) {
            // `boxing-club` starts with `box1`? No -- but `box1x` does start
            // with `box1`, so what follows the name has to be a separator
            // rather than more name.
            const rest = name[field.name.len..];
            if (rest.len == 0 or rest[0] == '.' or rest[0] == '-') {
                return @enumFromInt(field.value);
            }
        }
    }
    return null;
}

const std = @import("std");

test "every box resolves to a preset, and none of them is a different detector" {
    // The whole point of the file per box: five presets, one algorithm. What a
    // box may change is a number the detector reads, never which question it
    // asks -- and a box that wants the other model says so here, in one line,
    // where the next person can see it next to the other four.
    inline for (@typeInfo(Box).@"enum".fields) |field| {
        const box: Box = @enumFromInt(field.value);
        const chosen = presetFor(box);
        try std.testing.expectEqual(core.sample_rate, chosen.touch.sample_rate);
        try std.testing.expectEqual(core.sensor_frames, chosen.touch.poll_frames);
    }
}

test "a Pi is recognised by its hostname, and anything else is not" {
    try std.testing.expectEqual(Box.box3, fromHostname("box3").?);
    // The Pis answer to more than their bare name.
    try std.testing.expectEqual(Box.box5, fromHostname("box5.local").?);
    try std.testing.expectEqual(Box.box1, fromHostname("box1-pi").?);
    // A machine that is not one of the five gets the defaults rather than a
    // guess: a bench running box2's floors while claiming to be box2 is worse
    // than one that says it is nobody.
    try std.testing.expect(fromHostname("raspberrypi") == null);
    try std.testing.expect(fromHostname("") == null);
    try std.testing.expect(fromHostname("boxing-club") == null);
}

test "a box's drone span covers the move its probe actually makes" {
    // A span under the excursion saturates on every touch and pins the pitch
    // at the top of the range, which is the one thing the drone must not do:
    // the room hears the same throttle opened every time.
    inline for (@typeInfo(Box).@"enum".fields) |field| {
        const chosen = presetFor(@as(Box, @enumFromInt(field.value)));
        // A box that has left its span out has none to get wrong: its pitch
        // is read off the ends the probe itself has been to, which cover the
        // excursion by construction rather than by a number somebody typed.
        if (chosen.drone.span) |span| if (chosen.touch.counts) |floor| {
            try std.testing.expect(span >= floor);
            // And the quiet end has to be audible, or a light touch is a latch
            // nobody can hear.
            const just_over = core.noise.freqFromDeviation(
                floor,
                span,
                chosen.drone.touch_floor,
            );
            try std.testing.expect(just_over > 3.0 * core.noise.freq_min);
        };
    }
}

test "no box asks the detector a different question than the others" {
    // A box may set a number. A box that changed the model would be a second
    // algorithm arriving by the door this directory was built to close, so it
    // is refused here rather than discovered in a room.
    inline for (@typeInfo(Box).@"enum".fields) |field| {
        const chosen = presetFor(@as(Box, @enumFromInt(field.value)));
        try std.testing.expectEqual(default_preset.touch.model, chosen.touch.model);
    }
}
