//! Run a captured probe log back through the detector.
//!
//! Thresholds on this rig have been guessed, and a guess costs a trip to the
//! room to find out it was wrong. A capture is 880 seconds of the real probes
//! and replaying it takes under a second, so the numbers can be chosen from
//! what the rig actually does and only the last of them has to be carried in.
//!
//! What comes out is episodes: how many touches the detector would have called,
//! how long each lasted, and how much of the capture it spent latched. A
//! setting that reports one 800-second touch is a detector stuck on, and a
//! setting that reports four hundred half-second ones is a detector chattering.
//! Both look like a plausible number of latched polls if you only count polls.
//!
//! The CSV wants a header naming `raw_a` and `raw_bc`; `t_s` is used when it is
//! there and assumed from the poll rate when it is not. `touch.csv` in the
//! repository root is one of these.
//!
//!     zig build replay -- touch.csv
//!     zig build replay -- touch.csv --model=steady --still-range=64
//!     zig build replay -- touch.csv --sweep

const std = @import("std");
const core = @import("core/root.zig");

const poll_frames = core.sensor_frames;
const polls_per_s = @as(f32, @floatFromInt(core.sample_rate)) /
    @as(f32, @floatFromInt(poll_frames));

const Reading = struct {
    raw_a: i16,
    raw_bc: i16,
};

/// One run of polls the detector held a probe latched for.
const Episode = struct {
    start_poll: usize,
    polls: usize,

    fn seconds(self: Episode) f32 {
        return @as(f32, @floatFromInt(self.polls)) / polls_per_s;
    }

    fn at(self: Episode) f32 {
        return @as(f32, @floatFromInt(self.start_poll)) / polls_per_s;
    }
};

/// What one replay says about one probe.
const Summary = struct {
    episodes: usize = 0,
    latched_polls: usize = 0,
    longest: f32 = 0.0,
    shortest: f32 = std.math.inf(f32),

    fn fraction(self: Summary, polls: usize) f32 {
        if (polls == 0) return 0.0;
        return @as(f32, @floatFromInt(self.latched_polls)) /
            @as(f32, @floatFromInt(polls));
    }

    fn mean_s(self: Summary) f32 {
        if (self.episodes == 0) return 0.0;
        return @as(f32, @floatFromInt(self.latched_polls)) /
            @as(f32, @floatFromInt(self.episodes)) / polls_per_s;
    }
};

pub const Error = error{
    MissingColumn,
    NoRows,
};

/// Which column holds what, read off the header rather than assumed. A capture
/// written by a later version of the status sink may have gained columns.
const Columns = struct {
    raw_a: usize,
    raw_bc: usize,

    fn parse(header: []const u8) Error!Columns {
        var raw_a: ?usize = null;
        var raw_bc: ?usize = null;
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, header, " \r\n"), ',');
        var index: usize = 0;
        while (it.next()) |name| : (index += 1) {
            if (std.mem.eql(u8, name, "raw_a")) raw_a = index;
            if (std.mem.eql(u8, name, "raw_bc")) raw_bc = index;
        }
        return .{
            .raw_a = raw_a orelse return Error.MissingColumn,
            .raw_bc = raw_bc orelse return Error.MissingColumn,
        };
    }
};

/// One row's two readings, or null for a row that does not carry both. A
/// capture taken while the rig was restarted has short lines in it, and one
/// short line is not a reason to refuse the other three hundred thousand.
fn parseRow(columns: Columns, line: []const u8) ?Reading {
    var raw_a: ?i16 = null;
    var raw_bc: ?i16 = null;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \r\n"), ',');
    var index: usize = 0;
    while (it.next()) |field| : (index += 1) {
        if (index == columns.raw_a) raw_a = std.fmt.parseInt(i16, field, 10) catch return null;
        if (index == columns.raw_bc) raw_bc = std.fmt.parseInt(i16, field, 10) catch return null;
    }
    if (raw_a == null or raw_bc == null) return null;
    return .{ .raw_a = raw_a.?, .raw_bc = raw_bc.? };
}

/// Feed every reading through a fresh detector and collect what it did.
fn replay(
    gpa: std.mem.Allocator,
    readings: []const Reading,
    cfg: core.touch.Config,
) !struct { a: Summary, bc: Summary, a_episodes: []Episode, bc_episodes: []Episode } {
    var machine: core.touch.Machine = .init(cfg);

    var a_list: std.ArrayList(Episode) = .empty;
    errdefer a_list.deinit(gpa);
    var bc_list: std.ArrayList(Episode) = .empty;
    errdefer bc_list.deinit(gpa);

    var a_start: ?usize = null;
    var bc_start: ?usize = null;

    for (readings, 0..) |reading, poll| {
        _ = machine.update(reading.raw_a, reading.raw_bc);
        try edge(gpa, &a_list, &a_start, machine.a.on, poll);
        try edge(gpa, &bc_list, &bc_start, machine.bc.on, poll);
    }

    // A capture that ends mid-touch still ends that touch, or the last episode
    // is silently dropped and every count is one short.
    try close(gpa, &a_list, &a_start, readings.len);
    try close(gpa, &bc_list, &bc_start, readings.len);

    return .{
        .a = summarise(a_list.items),
        .bc = summarise(bc_list.items),
        .a_episodes = try a_list.toOwnedSlice(gpa),
        .bc_episodes = try bc_list.toOwnedSlice(gpa),
    };
}

fn edge(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Episode),
    start: *?usize,
    on: bool,
    poll: usize,
) !void {
    if (on and start.* == null) {
        start.* = poll;
    } else if (!on) {
        if (start.*) |began| try list.append(gpa, .{ .start_poll = began, .polls = poll - began });
        start.* = null;
    }
}

fn close(gpa: std.mem.Allocator, list: *std.ArrayList(Episode), start: *?usize, end: usize) !void {
    if (start.*) |began| try list.append(gpa, .{ .start_poll = began, .polls = end - began });
    start.* = null;
}

fn summarise(episodes: []const Episode) Summary {
    var out: Summary = .{};
    for (episodes) |episode| {
        out.episodes += 1;
        out.latched_polls += episode.polls;
        out.longest = @max(out.longest, episode.seconds());
        out.shortest = @min(out.shortest, episode.seconds());
    }
    if (out.episodes == 0) out.shortest = 0.0;
    return out;
}

fn report(name: []const u8, summary: Summary, polls: usize) void {
    std.debug.print(
        "  {s:<6} {d:4} episodes  {d:5.1}% latched  mean {d:6.2}s  shortest {d:6.2}s  longest {d:7.2}s\n",
        .{
            name,
            summary.episodes,
            summary.fraction(polls) * 100.0,
            summary.mean_s(),
            summary.shortest,
            summary.longest,
        },
    );
}

const Args = struct {
    path: []const u8 = "touch.csv",
    model: core.touch.Model = .steady,
    latch: ?i16 = null,
    release: ?i16 = null,
    sweep: bool = false,
    list: bool = false,
};

fn parseArgs(argv: []const []const u8) Args {
    var out: Args = .{};
    for (argv) |arg| {
        if (std.mem.startsWith(u8, arg, "--model=")) {
            const name = arg["--model=".len..];
            if (std.mem.eql(u8, name, "deviation")) out.model = .deviation;
            if (std.mem.eql(u8, name, "steady")) out.model = .steady;
        } else if (std.mem.startsWith(u8, arg, "--still-range=")) {
            out.latch = std.fmt.parseInt(i16, arg["--still-range=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--still-release=")) {
            out.release = std.fmt.parseInt(i16, arg["--still-release=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--sweep")) {
            out.sweep = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            out.list = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            out.path = arg;
        }
    }
    return out;
}

/// The range thresholds a sweep tries. Spaced by doubling because the gap the
/// thresholds live in spans two orders of magnitude, and a linear sweep across
/// it spends every step in the part that was never in question.
const sweep_ranges = [_]i16{ 4, 8, 16, 32, 64, 128, 256, 512, 1024 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |arg| gpa.free(arg);
        argv.deinit(gpa);
    }
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip();
    while (it.next()) |arg| try argv.append(gpa, try gpa.dupe(u8, arg));

    const args = parseArgs(argv.items);

    const text = std.Io.Dir.cwd().readFileAlloc(io, args.path, gpa, .limited(1 << 30)) catch |err| {
        std.debug.print("could not read {s}: {s}\n", .{ args.path, @errorName(err) });
        std.process.exit(1);
    };
    defer gpa.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse {
        std.debug.print("{s} is empty\n", .{args.path});
        std.process.exit(1);
    };
    const columns = Columns.parse(header) catch {
        std.debug.print("{s} has no raw_a/raw_bc columns\n", .{args.path});
        std.process.exit(1);
    };

    var readings: std.ArrayList(Reading) = .empty;
    defer readings.deinit(gpa);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (parseRow(columns, line)) |reading| try readings.append(gpa, reading);
    }
    if (readings.items.len == 0) {
        std.debug.print("{s} has no readings\n", .{args.path});
        std.process.exit(1);
    }

    const polls = readings.items.len;
    std.debug.print("{s}: {d} polls, {d:.1}s at {d:.0} polls/s\n\n", .{
        args.path,
        polls,
        @as(f32, @floatFromInt(polls)) / polls_per_s,
        polls_per_s,
    });

    var base: core.touch.Config = .{
        .sample_rate = core.sample_rate,
        .poll_frames = poll_frames,
        .model = args.model,
    };
    if (args.latch) |v| base.still_range = v;
    if (args.release) |v| base.still_release = v;

    if (args.sweep) {
        std.debug.print("sweeping the range, release held at {d}:\n", .{@as(u16, @intCast(base.still_release))});
        for (sweep_ranges) |range| {
            var cfg = base;
            cfg.still_range = range;
            // A release below the range is not a hysteresis, it is a single
            // line with the two sides swapped. Kept above it whatever is swept.
            cfg.still_release = @max(base.still_release, range * 4);
            const result = try replay(gpa, readings.items, cfg);
            defer gpa.free(result.a_episodes);
            defer gpa.free(result.bc_episodes);
            std.debug.print("range {d:5}  release {d:5}\n", .{
                @as(u16, @intCast(range)),
                @as(u16, @intCast(cfg.still_release)),
            });
            report("A", result.a, polls);
            report("BC", result.bc, polls);
        }
        return;
    }

    std.debug.print("model {t}", .{base.model});
    if (base.model == .steady) {
        std.debug.print("  range {d}  release {d}", .{
            @as(u16, @intCast(base.still_range)),
            @as(u16, @intCast(base.still_release)),
        });
    }
    std.debug.print("\n", .{});

    const result = try replay(gpa, readings.items, base);
    defer gpa.free(result.a_episodes);
    defer gpa.free(result.bc_episodes);
    report("A", result.a, polls);
    report("BC", result.bc, polls);

    if (!args.list) return;
    std.debug.print("\nepisodes:\n", .{});
    for (result.a_episodes) |episode| {
        std.debug.print("  A   at {d:8.2}s for {d:6.2}s\n", .{ episode.at(), episode.seconds() });
    }
    for (result.bc_episodes) |episode| {
        std.debug.print("  BC  at {d:8.2}s for {d:6.2}s\n", .{ episode.at(), episode.seconds() });
    }
}

test "the columns are found by name, wherever they sit" {
    const columns = try Columns.parse("t_s,raw_a,mean_a,raw_bc,state");
    try std.testing.expectEqual(@as(usize, 1), columns.raw_a);
    try std.testing.expectEqual(@as(usize, 3), columns.raw_bc);
}

test "a header without the readings is refused" {
    try std.testing.expectError(Error.MissingColumn, Columns.parse("t_s,state"));
}

test "a row is read from the named columns" {
    const columns = try Columns.parse("t_s,raw_a,raw_bc");
    const reading = parseRow(columns, "0.003,-4096,662").?;
    try std.testing.expectEqual(@as(i16, -4096), reading.raw_a);
    try std.testing.expectEqual(@as(i16, 662), reading.raw_bc);
}

test "a short or unparseable row is skipped rather than fatal" {
    const columns = try Columns.parse("t_s,raw_a,raw_bc");
    try std.testing.expect(parseRow(columns, "0.003,-4096") == null);
    try std.testing.expect(parseRow(columns, "0.003,mid-restart,662") == null);
}

test "episodes are counted at the edges, and one still open at the end is closed" {
    const gpa = std.testing.allocator;
    var readings: std.ArrayList(Reading) = .empty;
    defer readings.deinit(gpa);

    // Nobody there first, so the detector learns where the probes rest: it
    // reads a hand as stillness somewhere other than rest, and a probe that has
    // only ever read one value rests at that value.
    for (0..6000) |i| try readings.append(gpa, .{
        .raw_a = if (i % 2 == 0) -4096 else 1,
        .raw_bc = if (i % 2 == 0) -4096 else 1,
    });
    // Then held, then flailing, then held again to the end of the capture.
    for (0..900) |_| try readings.append(gpa, .{ .raw_a = 663, .raw_bc = 663 });
    for (0..900) |i| try readings.append(gpa, .{
        .raw_a = if (i % 2 == 0) -4096 else 1,
        .raw_bc = if (i % 2 == 0) -4096 else 1,
    });
    for (0..900) |_| try readings.append(gpa, .{ .raw_a = 663, .raw_bc = 663 });

    const result = try replay(gpa, readings.items, .{
        .sample_rate = core.sample_rate,
        .poll_frames = poll_frames,
        .model = .steady,
    });
    defer gpa.free(result.a_episodes);
    defer gpa.free(result.bc_episodes);

    try std.testing.expectEqual(@as(usize, 2), result.a.episodes);
    try std.testing.expect(result.a.latched_polls > 0);
}
