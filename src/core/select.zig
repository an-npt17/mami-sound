//! Which plants take part in a run.
//!
//! The command line takes one argument: `1`, `2`, or `12` to choose the plants.
//! No argument means all of them, so the default run is unchanged.
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

/// Parse one of the allowed digit strings. `null` selects every plant.
pub fn parse(text: ?[]const u8) Error!Selection {
    const digits = text orelse return all;
    if (digits.len == 0) return Error.InvalidSelection;

    if (std.mem.eql(u8, digits, "1")) return .{ true, false };
    if (std.mem.eql(u8, digits, "2")) return .{ false, true };
    if (std.mem.eql(u8, digits, "12")) return all;
    return Error.InvalidSelection;
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
    \\PLANTS may be omitted, or must be exactly one of:
    \\  1  plant A, the ECG drone
    \\  2  plant B, the interview clip
    \\
    \\  mami_sound       both plants, the full installation
    \\  mami_sound 1     plant A alone
    \\  mami_sound 12    plants A and B blended
    \\
;
