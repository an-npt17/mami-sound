//! Listing the recordings that make up Plant B's clip pool.
//!
//! A source is one folder. The loader retains its paths at startup; a
//! background stream worker decodes the selected clip when a new touch
//! arrives.

const std = @import("std");

pub const Error = error{
    /// The folder is there but holds nothing playable.
    NoAudioFiles,
} || std.mem.Allocator.Error;

/// What ffmpeg is asked to decode. Anything else in the folder — a text note, a
/// cover image, a stray project file — is passed over rather than handed to
/// ffmpeg to fail on.
const audio_extensions = [_][]const u8{
    ".mp3", ".wav", ".ogg", ".opus", ".flac",
    ".m4a", ".aac", ".aif", ".aiff", ".wma",
};

/// Whether a directory entry names a clip. Pure, so the rule can be checked
/// without a directory to point it at.
pub fn isAudio(name: []const u8) bool {
    // Leading dots cover both hidden files and the `._name` resource forks a
    // macOS machine leaves on a USB stick, which are not audio however they
    // are named.
    if (name.len == 0 or name[0] == '.') return false;

    for (audio_extensions) |ext| {
        if (name.len <= ext.len) continue;
        if (std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// Every clip in `dir_path`, in whatever order the directory gives them. Caller
/// owns the paths and the slice holding them; `freeList` returns both.
///
/// The whole folder is listed so a touch can choose a path immediately. Audio
/// decoding happens later in the bounded background stream worker rather than
/// in this startup path or the real-time audio thread.
pub fn list(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) ![][]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (!isAudio(entry.name)) continue;
        // The entry's name is only valid until the next step, so join now.
        const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        paths.append(gpa, path) catch |err| {
            gpa.free(path);
            return err;
        };
    }

    if (paths.items.len == 0) return Error.NoAudioFiles;
    return paths.toOwnedSlice(gpa);
}

/// Every clip in `dir_path`, sorted by name.
///
/// Directory order is whatever the filesystem hands back, so a caller that
/// wants "the first clip" would otherwise be depending on the disk. Sorting
/// makes it depend on the folder's contents instead -- which is still the
/// room's to change, but at least it is the same answer twice running.
///
/// This is what the tests use rather than naming a file: the stems have been
/// renamed once already, and a test that breaks when somebody tidies a folder
/// is a test that will be deleted rather than fixed.
pub fn listSorted(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![][]u8 {
    const paths = try list(gpa, io, dir_path);
    std.mem.sort([]u8, paths, {}, lessByName);
    return paths;
}

fn lessByName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn freeList(gpa: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| gpa.free(path);
    gpa.free(paths);
}
