//! Prints the seven source/folder pairs out of `clip_loader.directoriesFor`
//! as JSON.
//!
//! `directoriesFor` is the one place those folder names live (see its own
//! doc comment in `src/adapters/clip_loader.zig`). This program exists so
//! that `clips_ui/src/clips_ui/sources.json` -- the copy the Python web UI
//! reads -- is generated from that function rather than hand-copied, which
//! would be a second source of truth that drifts the first time a folder is
//! renamed. (It has been renamed once already.)
//!
//! Regenerate the JSON file with:
//!
//!   zig build dump-sources > clips_ui/src/clips_ui/sources.json
//!
//! NOTE: `sources.json` as committed was hand-written to match
//! `directoriesFor`, because the zig toolchain could not be run on the
//! machine this file was authored on (see the matching note atop
//! `clips_ui/src/clips_ui/folders.py`). Run the command above and diff the
//! result the next time the toolchain is available, and always after a
//! folder name changes -- `clips_ui/tests/test_sources_drift.py` will fail
//! and say so if it is forgotten.

const std = @import("std");
const core = @import("mami_sound_core");
const adapters = @import("mami_sound_adapters");

const clip_loader = adapters.adapters.clip_loader;

/// Every source with a folder, deliberately excluding `.drone`: it is
/// generated audio with no folder at all, and `directoriesFor(.drone)` is
/// `unreachable`.
const sources = [_]core.source.Source{
    .voicebox3, .voicebox5, .insect, .tradvn, .bell, .daybird, .piano,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n");
    for (sources, 0..) |which, i| {
        const folders = clip_loader.directoriesFor(which);
        std.debug.assert(folders.len == 1);
        try out.print(gpa, "  \"{s}\": \"{s}\"", .{ @tagName(which), folders[0] });
        try out.appendSlice(gpa, if (i + 1 == sources.len) "\n" else ",\n");
    }
    try out.appendSlice(gpa, "}\n");

    try std.Io.File.stdout().writeStreamingAll(io, out.items);
}
