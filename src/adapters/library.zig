//! Listing the recordings that make up Plant B's clip pool.
//!
//! Plant B combines every playable file from `interview files/` and `field
//! records/`. The loader decodes the combined pool at startup so a new touch
//! can choose a clip immediately.

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
/// The whole folder is loaded because a touch has to start a clip *now* —
/// decoding one on demand means shelling out to ffmpeg for seconds while the
/// sound card starves. Folders are therefore sized by what a machine can hold:
/// see the total this prints at start up.
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
        try paths.append(gpa, try std.fs.path.join(gpa, &.{ dir_path, entry.name }));
    }

    if (paths.items.len == 0) return Error.NoAudioFiles;
    return paths.toOwnedSlice(gpa);
}

pub fn freeList(gpa: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| gpa.free(path);
    gpa.free(paths);
}

const testing = std.testing;

test "clips are recognised whatever the case of the extension" {
    try testing.expect(isAudio("chim choc.mp3"));
    try testing.expect(isAudio("night sound 1.MP3"));
    try testing.expect(isAudio("Rau ngot. Gia Tran.1_.11.mp3"));
    try testing.expect(isAudio("dừa ẻo. GiaTrân. 3_.37.mp3"));
    try testing.expect(isAudio("take.WAV"));
    try testing.expect(isAudio("field.flac"));
}

test "everything else in the folder is passed over" {
    try testing.expect(!isAudio("notes.txt"));
    try testing.expect(!isAudio("cover.jpg"));
    try testing.expect(!isAudio("session.als"));
    try testing.expect(!isAudio(""));
    // Hidden files and macOS resource forks, which are not audio however they
    // are named.
    try testing.expect(!isAudio(".hidden.mp3"));
    try testing.expect(!isAudio("._Chim CHó.2_13.mp3"));
    // A name that is only an extension is a hidden file, not a clip.
    try testing.expect(!isAudio(".mp3"));
}
