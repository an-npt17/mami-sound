//! Choosing a clip at random from a directory of them.
//!
//! Plants B and C play from a folder rather than a named file, so the pieces a
//! visitor hears are not the same two every time the installation is switched
//! on. The folders hold tens of minutes of audio between them, far more than a
//! Pi has room to decode and keep, so one file per plant is chosen up front and
//! only that one is decoded.

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

/// The path of one clip from `dir_path`, chosen uniformly at random. Caller
/// owns the returned slice.
pub fn pick(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    random: std.Random,
) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var chosen: ?[]u8 = null;
    errdefer if (chosen) |name| gpa.free(name);
    var seen: usize = 0;

    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (!isAudio(entry.name)) continue;

        seen += 1;
        // Reservoir sampling: hold one name, and replace it with probability
        // 1/seen. One pass and one name in memory, with every file equally
        // likely, without having to count the folder first or keep a list of
        // it. The entry's name is only valid until the next step, hence the
        // copy.
        if (random.uintLessThan(usize, seen) == 0) {
            if (chosen) |old| gpa.free(old);
            chosen = try gpa.dupe(u8, entry.name);
        }
    }

    const name = chosen orelse return Error.NoAudioFiles;
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ dir_path, name });
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

test "every file in a folder can come up" {
    // Reservoir sampling over a known list: with enough draws each of the five
    // has to appear, or the choice is not uniform over the folder.
    const names = [_][]const u8{ "a.mp3", "b.mp3", "c.mp3", "d.mp3", "e.mp3" };
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();

    var counts = [_]usize{0} ** names.len;
    for (0..2000) |_| {
        var chosen: usize = 0;
        var seen: usize = 0;
        for (names, 0..) |_, i| {
            seen += 1;
            if (random.uintLessThan(usize, seen) == 0) chosen = i;
        }
        counts[chosen] += 1;
    }
    // Uniform would be 400 each; this only has to rule out a file that never
    // comes up, or one that always does.
    for (counts) |c| {
        try testing.expect(c > 200);
        try testing.expect(c < 700);
    }
}
