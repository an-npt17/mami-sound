//! Which plants take part in a run.
//!
//! The command line takes one argument: the digits of the plants to enable,
//! in any order. `1` is plant A alone, `12` blends A and B, `123` is the whole
//! installation. No argument means all of them, so the default run is unchanged.
//!
//! Parsing is pure so the flag can be tested without touching audio.

const std = @import("std");
const sensors = @import("sensors.zig");

pub const Error = error{
    /// The argument was empty, or held something other than plant digits.
    InvalidSelection,
};

/// Enabled flag per plant, indexed the same way as `sensors.Reading.touch`:
/// 0 = A (ECG drone), 1 = B (interview), 2 = C (waterfall).
pub const Selection = [sensors.plant_count]bool;

pub const all: Selection = .{true} ** sensors.plant_count;

/// Parse the digit string. `null` (no argument given) selects every plant.
pub fn parse(text: ?[]const u8) Error!Selection {
    const digits = text orelse return all;
    if (digits.len == 0) return Error.InvalidSelection;

    var sel: Selection = .{false} ** sensors.plant_count;
    for (digits) |c| {
        // '1'-based on the command line because the plants are named A, B, C
        // to visitors and 1, 2, 3 on the panel; nobody counts from zero there.
        if (c < '1' or c > '0' + sensors.plant_count) return Error.InvalidSelection;
        sel[c - '1'] = true;
    }
    return sel;
}

/// Mask a sensor reading's touches so disabled plants read as untouched. That
/// is all it takes to silence a voice: an untouched voice fades out and stays
/// out, with no special case in the render loop.
pub fn apply(sel: Selection, touch: [sensors.plant_count]bool) [sensors.plant_count]bool {
    var out: [sensors.plant_count]bool = undefined;
    for (&out, touch, sel) |*o, t, on| o.* = t and on;
    return out;
}

pub const usage =
    \\usage: mami_sound [PLANTS]
    \\
    \\PLANTS is the digits of the plants to play, in any order:
    \\  1  plant A, the ECG drone
    \\  2  plant B, the interview clip
    \\  3  plant C, the waterfall clip
    \\
    \\  mami_sound       all three, the full installation
    \\  mami_sound 1     plant A alone
    \\  mami_sound 12    plants A and B blended
    \\
;
