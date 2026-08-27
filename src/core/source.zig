//! What a plant can be told to play.
//!
//! One vocabulary for the generated drone and for every folder of clips, so a
//! plant is configured by naming a source rather than by a flag that means one
//! thing on plant A and another on plant B. Adding a folder is a variant here
//! and a line in the loader; nothing else in the program learns its name.
//!
//! Two lengths travel with a source because they answer different questions and
//! have been conflated once already. `defaultSeconds` is how much of a clip a
//! touch gets before it is faded out. `defaultRetriggerSeconds` is how long that
//! clip is protected from the next touch, counted from when it started.

const std = @import("std");

pub const Error = error{UnknownSource};

/// How long a clip is protected from the next hand, for everything but the
/// recordings. Long enough that a clip has established itself, short enough
/// that a room which has heard enough can move it on.
pub const default_retrigger_s: f32 = 5.0;

/// The voice boxes run for minutes and are the piece's own voice rather than an
/// answer to a hand, so they are given twice as long before a touch may cut in.
pub const long_form_retrigger_s: f32 = 10.0;

/// A tuned note plus enough of its tail to hear it as a note.
pub const stem_play_s: f32 = 4.0;

/// A call, or a few seconds of ambience. The folders behind `daybird` and
/// `insect` hold recordings of up to forty seconds, which is a field recording
/// rather than a plant answering somebody.
pub const fragment_play_s: f32 = 5.0;

/// Every source name, comma-separated, built from the enum.
///
/// So a message listing them cannot fall behind the list: it did once, and
/// told a room to try a pool that had been deleted.
pub const names = blk: {
    const fields = @typeInfo(Source).@"enum".fields;
    var line: []const u8 = "";
    for (fields, 0..) |field, i| {
        line = line ++ field.name;
        if (i + 2 == fields.len) {
            line = line ++ " or ";
        } else if (i + 1 < fields.len) {
            line = line ++ ", ";
        }
    }
    break :blk line;
};

pub const Source = enum {
    /// The sensor-driven voice. Generated rather than played, so it has no
    /// folder and neither length means anything to it.
    drone,
    /// The two boxes of voices, one folder each. They were one pool read from
    /// two folders once; every source is its own folder now, and a plant that
    /// wants both is two plants.
    voicebox3,
    voicebox5,
    daybird,
    insect,
    tradvn,
    bell,
    piano,

    pub fn parse(name: []const u8) Error!Source {
        return std.meta.stringToEnum(Source, name) orelse Error.UnknownSource;
    }

    pub fn isDrone(self: Source) bool {
        return self == .drone;
    }

    /// How long one touch plays. `null` runs to the clip's own end, which is
    /// what the two long-form sources want: an interview cut at five seconds is
    /// a fragment, and a jam cut there is not music.
    pub fn defaultSeconds(self: Source) ?f32 {
        return switch (self) {
            .drone, .voicebox3, .voicebox5, .tradvn => null,
            .daybird, .insect => fragment_play_s,
            .bell, .piano => stem_play_s,
        };
    }

    /// How long a clip is protected from the next touch, from when it started.
    ///
    /// A source whose play length is under its guard is never held back by it:
    /// the clip has ended, so the plant is listening again whatever the guard
    /// says. It matters only where a clip is still sounding.
    pub fn defaultRetriggerSeconds(self: Source) f32 {
        return switch (self) {
            .voicebox3, .voicebox5 => long_form_retrigger_s,
            else => default_retrigger_s,
        };
    }
};

test "every source name parses to itself" {
    try std.testing.expectEqual(Source.drone, try Source.parse("drone"));
    try std.testing.expectEqual(Source.voicebox3, try Source.parse("voicebox3"));
    try std.testing.expectEqual(Source.voicebox5, try Source.parse("voicebox5"));
    try std.testing.expectEqual(Source.daybird, try Source.parse("daybird"));
    try std.testing.expectEqual(Source.insect, try Source.parse("insect"));
    try std.testing.expectEqual(Source.tradvn, try Source.parse("tradvn"));
    try std.testing.expectEqual(Source.bell, try Source.parse("bell"));
    try std.testing.expectEqual(Source.piano, try Source.parse("piano"));
}

test "a name no source has is refused" {
    try std.testing.expectError(Error.UnknownSource, Source.parse("cello"));
    // The pool that read two folders as one. Every source is its own folder now.
    try std.testing.expectError(Error.UnknownSource, Source.parse("recordings"));
    try std.testing.expectError(Error.UnknownSource, Source.parse(""));
}

test "only the drone is the drone" {
    try std.testing.expect(Source.drone.isDrone());
    try std.testing.expect(!Source.voicebox3.isDrone());
    try std.testing.expect(!Source.tradvn.isDrone());
}

test "a source that plays to its own end has no length" {
    try std.testing.expect(Source.voicebox3.defaultSeconds() == null);
    try std.testing.expect(Source.voicebox5.defaultSeconds() == null);
    try std.testing.expect(Source.tradvn.defaultSeconds() == null);
    try std.testing.expect(Source.drone.defaultSeconds() == null);
}

test "a source that answers with a fragment carries its length" {
    try std.testing.expectEqual(@as(f32, 5.0), Source.daybird.defaultSeconds().?);
    try std.testing.expectEqual(@as(f32, 5.0), Source.insect.defaultSeconds().?);
    try std.testing.expectEqual(@as(f32, 4.0), Source.bell.defaultSeconds().?);
    try std.testing.expectEqual(@as(f32, 4.0), Source.piano.defaultSeconds().?);
}

test "the voice boxes are protected for longer than anything else" {
    // They are the piece's own voice and run for minutes; the rest are answers
    // to a hand and want moving on sooner.
    try std.testing.expectEqual(@as(f32, 10.0), Source.voicebox3.defaultRetriggerSeconds());
    try std.testing.expectEqual(@as(f32, 10.0), Source.voicebox5.defaultRetriggerSeconds());
    try std.testing.expectEqual(@as(f32, 5.0), Source.tradvn.defaultRetriggerSeconds());
    try std.testing.expectEqual(@as(f32, 5.0), Source.daybird.defaultRetriggerSeconds());
    try std.testing.expectEqual(@as(f32, 5.0), Source.bell.defaultRetriggerSeconds());
}

test "the list of names holds every source" {
    // The message that offers them is built from this, so a source added
    // without touching the message still gets mentioned by it.
    inline for (@typeInfo(Source).@"enum".fields) |field| {
        if (std.mem.indexOf(u8, names, field.name) == null) {
            std.debug.print("the name list omits {s}\n", .{field.name});
            return error.SourceMissingFromNames;
        }
    }
    // And nothing that is no longer a source.
    try std.testing.expect(std.mem.indexOf(u8, names, "recordings") == null);
}
