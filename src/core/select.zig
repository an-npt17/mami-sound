//! Which plants take part in a run.
//!
//! The command line takes one argument: the digits of the plants to enable,
//! in any order. `1` is plant A alone and `12` enables both plants. No argument
//! means all of them, so the default run is unchanged.
//!
//! Parsing is pure so the flag can be tested without touching audio.

const std = @import("std");
const plant = @import("plant.zig");

pub const Error = error{
    /// The argument was empty, or held something other than plant digits.
    InvalidSelection,
};

/// Enabled flag per plant, indexed as A (ECG drone), then B (interview).
pub const Selection = plant.Selection;

pub const all: Selection = plant.all;

/// Parse the digit string. `null` (no argument given) selects every plant.
pub fn parse(text: ?[]const u8) Error!Selection {
    const digits = text orelse return all;
    if (digits.len == 0) return Error.InvalidSelection;

    var sel: Selection = .{false} ** plant.count;
    for (digits) |c| {
        // '1'-based on the command line because the plants are named A and B
        // to visitors and 1, 2 on the panel; nobody counts from zero there.
        if (c < '1' or c > '0' + plant.count) return Error.InvalidSelection;
        sel[c - '1'] = true;
    }
    return sel;
}

/// Mask a sensor reading's touches so disabled plants read as untouched. That
/// is all it takes to silence a voice: an untouched voice fades out and stays
/// out, with no special case in the render loop.
pub fn apply(sel: plant.Selection, touch: plant.Selection) plant.Selection {
    var out: plant.Selection = undefined;
    for (&out, touch, sel) |*o, t, on| o.* = t and on;
    return out;
}

pub const usage =
    \\usage: mami_sound [PLANTS]
    \\
    \\PLANTS is the digits of the plants to play, in any order:
    \\  1  plant A, the ECG drone
    \\  2  plant B, the interview clip
    \\
    \\  mami_sound       both plants, the full installation
    \\  mami_sound 1     plant A alone
    \\  mami_sound 12    plants A and B blended
    \\
;

test "plant selection has only A and B" {
    try std.testing.expectEqual(@as(usize, 2), plant.count);
    try std.testing.expectEqual(plant.Selection{ true, true }, plant.all);
    try std.testing.expectError(Error.InvalidSelection, parse("3"));
}
