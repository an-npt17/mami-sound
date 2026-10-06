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

/// Every clip in `dir_path`, sorted the way the folder is numbered.
///
/// `listSorted` compares byte by byte, which puts `song10` between `song1` and
/// `song2`. For a pool of alternatives that is only an order; for a folder
/// holding one piece in numbered parts it is the wrong one, and a room would
/// hear part ten arrive second. So a run of digits is compared as the number it
/// spells, and everything else byte by byte as before.
pub fn listNatural(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![][]u8 {
    const paths = try list(gpa, io, dir_path);
    std.mem.sort([]u8, paths, {}, lessByNatural);
    return paths;
}

/// How long the run of digits starting at `at` is. Zero when there is none.
fn digitRun(text: []const u8, at: usize) usize {
    var end = at;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return end - at;
}

/// Compare two runs of digits as numbers. `null` when they spell the same one,
/// so the caller carries on past them rather than calling it a tie.
///
/// Leading zeros are skipped before the lengths are compared, so `song07` and
/// `song7` are the same part -- which they are, to anybody who renamed half a
/// folder and stopped.
fn digitsLess(a: []const u8, b: []const u8) ?bool {
    const a_digits = std.mem.trimStart(u8, a, "0");
    const b_digits = std.mem.trimStart(u8, b, "0");
    if (a_digits.len != b_digits.len) return a_digits.len < b_digits.len;
    if (std.mem.eql(u8, a_digits, b_digits)) return null;
    return std.mem.lessThan(u8, a_digits, b_digits);
}

fn lessByNatural(_: void, a: []u8, b: []u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const a_run = digitRun(a, i);
        const b_run = digitRun(b, j);

        // A number on one side and a letter on the other is not a number
        // comparison; fall through to the bytes.
        if (a_run != 0 and b_run != 0) {
            if (digitsLess(a[i..][0..a_run], b[j..][0..b_run])) |answer| return answer;
            i += a_run;
            j += b_run;
            continue;
        }

        if (a[i] != b[j]) return a[i] < b[j];
        i += 1;
        j += 1;
    }

    // One ran out inside the other: the shorter name comes first, which is what
    // byte order would have said too.
    return a.len - i < b.len - j;
}

pub fn freeList(gpa: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| gpa.free(path);
    gpa.free(paths);
}

/// Sort a list of names the natural way, so the comparator can be tested
/// without a folder to point it at.
fn sortedNaturally(names: [][]u8) void {
    std.mem.sort([]u8, names, {}, lessByNatural);
}

test "a numbered folder sorts by its numbers and not its bytes" {
    var one = "song1.wav".*;
    var two = "song2.wav".*;
    var nine = "song9.wav".*;
    var ten = "song10.wav".*;
    var twenty_one = "song21.wav".*;

    var names = [_][]u8{ &ten, &one, &twenty_one, &nine, &two };
    sortedNaturally(&names);

    try std.testing.expectEqualStrings("song1.wav", names[0]);
    try std.testing.expectEqualStrings("song2.wav", names[1]);
    try std.testing.expectEqualStrings("song9.wav", names[2]);
    try std.testing.expectEqualStrings("song10.wav", names[3]);
    try std.testing.expectEqualStrings("song21.wav", names[4]);
}

test "the folder a numbered name sits in is not what orders it" {
    // Every path carries the same directory prefix, digits in it and all.
    var one = "Trad Vn Jam 2/song1.wav".*;
    var ten = "Trad Vn Jam 2/song10.wav".*;
    var two = "Trad Vn Jam 2/song2.wav".*;

    var names = [_][]u8{ &ten, &two, &one };
    sortedNaturally(&names);

    try std.testing.expectEqualStrings("Trad Vn Jam 2/song1.wav", names[0]);
    try std.testing.expectEqualStrings("Trad Vn Jam 2/song2.wav", names[1]);
    try std.testing.expectEqualStrings("Trad Vn Jam 2/song10.wav", names[2]);
}

test "a padded number is the part it spells" {
    // Half a folder renamed and the other half not is a folder somebody will
    // hand over, and part seven is part seven however it is written.
    var seven = "song07.wav".*;
    var eight = "song8.wav".*;

    var names = [_][]u8{ &eight, &seven };
    sortedNaturally(&names);

    try std.testing.expectEqualStrings("song07.wav", names[0]);
    try std.testing.expectEqualStrings("song8.wav", names[1]);
}

test "a name with no numbers in it sorts as it always did" {
    var bell = "bell.wav".*;
    var cello = "cello.wav".*;

    var names = [_][]u8{ &cello, &bell };
    sortedNaturally(&names);

    try std.testing.expectEqualStrings("bell.wav", names[0]);
    try std.testing.expectEqualStrings("cello.wav", names[1]);
}

test "a name that is the start of another comes before it" {
    // Both run out of digits at the same number, so what is left of the longer
    // name decides -- and nothing comes before something.
    var short = "song1".*;
    var long = "song1.wav".*;

    var names = [_][]u8{ &long, &short };
    sortedNaturally(&names);

    try std.testing.expectEqualStrings("song1", names[0]);
    try std.testing.expectEqualStrings("song1.wav", names[1]);
}

test "what follows the number is still compared byte by byte" {
    // Two takes of the same part. The numbers tie, so the bytes after them
    // decide, exactly as they did before any of this -- and '-' is below '.',
    // which is what byte order has always said.
    var plain = "song1.wav".*;
    var alt = "song1-alt.wav".*;

    var names = [_][]u8{ &plain, &alt };
    sortedNaturally(&names);

    try std.testing.expectEqualStrings("song1-alt.wav", names[0]);
    try std.testing.expectEqualStrings("song1.wav", names[1]);
}

test "a number on one side and a letter on the other falls through to the bytes" {
    var numbered = "song1.wav".*;
    var named = "songA.wav".*;

    var names = [_][]u8{ &named, &numbered };
    sortedNaturally(&names);

    // '1' is below 'A', which is what byte order says and what this should not
    // have changed.
    try std.testing.expectEqualStrings("song1.wav", names[0]);
    try std.testing.expectEqualStrings("songA.wav", names[1]);
}

test "sorting a numbered folder is a total order" {
    // std.mem.sort will happily produce nonsense from a comparator that says
    // two different names are each less than the other. Check every pair.
    var buffers: [12][16]u8 = undefined;
    var names: [12][]u8 = undefined;
    for (&buffers, 0..) |*buffer, i| {
        names[i] = std.fmt.bufPrint(buffer, "song{d}.wav", .{i + 1}) catch unreachable;
    }

    for (names) |a| {
        for (names) |b| {
            const a_less = lessByNatural({}, a, b);
            const b_less = lessByNatural({}, b, a);
            if (std.mem.eql(u8, a, b)) {
                try std.testing.expect(!a_less and !b_less);
            } else {
                try std.testing.expect(a_less != b_less);
            }
        }
    }
}
