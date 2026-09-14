//! The baseline every box derives from: the detector's own numbers, the
//! drone's own shape, and the two plants the installation has always had.
//!
//! A box file states what its rig measured and inherits the rest from here, so
//! a change that belongs to every box is made once. A box that has never been
//! to a room is exactly this.

const core = @import("../../core/root.zig");
const preset_mod = @import("preset.zig");

pub const Preset = preset_mod.Preset;
pub const Plant = preset_mod.Plant;

pub const preset: Preset = .{
    .touch = .{
        .sample_rate = core.sample_rate,
        .poll_frames = core.sensor_frames,
        .model = .deviation,
        .hold_bc_ms = 20.0,
    },
    .drone = .{},
    .plants = .{
        .{ .source = .drone, .mode = .trigger },
        .{ .source = .voicebox3, .mode = .trigger },
    },
};

const std = @import("std");

test "the defaults are a rig nobody has measured, and say so in their numbers" {
    // A box that has not been to a room yet runs the detector's own defaults:
    // no band, no counts floor, and the deviation model, which is what the
    // rig with an electrode that rests somewhere wants.
    try std.testing.expectEqual(core.touch.Model.deviation, preset.touch.model);
    try std.testing.expect(preset.touch.touch_band_lo == null);
    try std.testing.expect(preset.touch.counts == null);
    // And the two plants the installation has always had.
    try std.testing.expectEqual(core.source.Source.drone, preset.plants[0].source);
    try std.testing.expectEqual(core.source.Source.voicebox3, preset.plants[1].source);
}
