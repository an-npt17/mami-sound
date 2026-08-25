const std = @import("std");

const cli = @import("cli.zig");
const core = @import("core/root.zig");
const engine = @import("application/engine.zig");
const ports = @import("ports/root.zig");
const ads1115 = @import("adapters/ads1115.zig");
const ads1115_probe = @import("adapters/ads1115_probe.zig");
const aplay_sink = @import("adapters/aplay_sink.zig");
const clip_loader = @import("adapters/clip_loader.zig");
const stderr_status = @import("adapters/stderr_status.zig");

const ProductionProbeOpener = struct {
    fn open(_: *ProductionProbeOpener, _: std.Io) ads1115.Error!ads1115_probe.Adapter {
        return ads1115_probe.Adapter.open(ads1115.default_bus, ads1115.default_address);
    }
};

const ProductionSinkOpener = struct {
    fn open(
        _: *ProductionSinkOpener,
        io: std.Io,
        device: []const u8,
    ) !aplay_sink.Adapter {
        return aplay_sink.Adapter.init(io, device, core.sample_rate, core.channels);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const opts = parseArgs(gpa, init.minimal.args) catch |err| {
        switch (err) {
            error.HelpRequested => {},
            error.InvalidSelection => std.debug.print("PLANTS must be 1, 2 or 12.\n\n", .{}),
            error.TooManyArguments => std.debug.print("takes at most one plant selection.\n\n", .{}),
            error.InvalidDevice => std.debug.print(
                "--device needs a name, at most {d} characters.\n\n",
                .{cli.device_max},
            ),
            error.UnknownFlag => std.debug.print("unknown flag.\n\n", .{}),
            else => std.debug.print("could not read arguments: {s}\n\n", .{@errorName(err)}),
        }
        std.debug.print("{s}", .{cli.usage});
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    var probe_opener = ProductionProbeOpener{};
    var sink_opener = ProductionSinkOpener{};
    runComposition(io, gpa, opts, &probe_opener, &sink_opener) catch |err| {
        std.debug.print("mami_sound stopped: {s}\n", .{@errorName(err)});
        return err;
    };
}

fn runComposition(
    io: std.Io,
    gpa: std.mem.Allocator,
    opts: cli.Options,
    probe_opener: anytype,
    sink_opener: anytype,
) !void {
    // Probe startup is deliberately first: production must not spawn an audio
    // process when the mandatory ADS1115 is unavailable.
    var probe = try probe_opener.open(io);
    defer probe.close();

    var clips: clip_loader.LoadedPool = if (opts.plants[1])
        try clip_loader.loadPlantB(gpa, io, core.sample_rate)
    else
        .empty;
    defer clips.deinit(gpa);

    var sink = try sink_opener.open(io, opts.device());

    var status = stderr_status.Adapter.init(io);
    var shuffle = std.Random.DefaultPrng.init(shuffleSeed(io));
    var sink_port = sink.port();
    var app = engine.Engine.init(
        opts.plants,
        probe.source(),
        sink_port,
        status.port(),
        clips.clips,
        shuffle.random(),
    );
    return finishAfterRun(&sink_port, app.run());
}

fn finishAfterRun(sink: *ports.AudioSink, run_result: anyerror!void) !void {
    if (run_result) |_| {
        return sink.finish();
    } else |engine_err| {
        sink.finish() catch |finish_err| {
            std.debug.print("audio sink shutdown failed: {s}\n", .{@errorName(finish_err)});
        };
        return engine_err;
    }
}

fn parseArgs(
    gpa: std.mem.Allocator,
    args: std.process.Args,
) (cli.Error || std.mem.Allocator.Error || error{HelpRequested})!cli.Options {
    var it = try args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip();

    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |arg| gpa.free(arg);
        list.deinit(gpa);
    }

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        }
        try list.append(gpa, try gpa.dupe(u8, arg));
    }

    return cli.parse(list.items);
}

fn shuffleSeed(io: std.Io) u64 {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @truncate(@as(u96, @bitCast(ns)));
}

const testing = std.testing;

const FailingProbe = struct {
    fn close(_: *FailingProbe) void {}

    fn source(_: *FailingProbe) ports.ProbeSource {
        unreachable;
    }
};

const FailingProbeOpener = struct {
    fn open(_: *FailingProbeOpener, _: std.Io) error{ProbeFailed}!FailingProbe {
        return error.ProbeFailed;
    }
};

const FakeSink = struct {
    fn port(_: *FakeSink) ports.AudioSink {
        unreachable;
    }

    fn finish(_: *FakeSink) !void {}
};

const FakeSinkOpener = struct {
    called: bool = false,

    fn open(self: *FakeSinkOpener, _: std.Io, _: []const u8) !FakeSink {
        self.called = true;
        return .{};
    }
};

const FakeFinishSink = struct {
    failure: ?anyerror = null,
    finished: bool = false,

    fn write(_: *anyopaque, _: []const i16) anyerror!void {}

    fn finish(context: *anyopaque) anyerror!void {
        const self: *FakeFinishSink = @ptrCast(@alignCast(context));
        self.finished = true;
        if (self.failure) |err| return err;
    }

    fn port(self: *FakeFinishSink) ports.AudioSink {
        return .{
            .context = self,
            .write_fn = write,
            .finish_fn = finish,
        };
    }
};

test "composition propagates a shutdown failure after a clean engine run" {
    var fake = FakeFinishSink{ .failure = error.ShutdownFailed };
    var sink = fake.port();

    try testing.expectError(error.ShutdownFailed, finishAfterRun(&sink, {}));
    try testing.expect(fake.finished);
}

test "composition preserves the engine failure when shutdown also fails" {
    var fake = FakeFinishSink{ .failure = error.ShutdownFailed };
    var sink = fake.port();

    try testing.expectError(
        error.EngineFailed,
        finishAfterRun(&sink, error.EngineFailed),
    );
    try testing.expect(fake.finished);
}

test "probe startup failure prevents sink startup" {
    var probe_opener = FailingProbeOpener{};
    var sink_opener = FakeSinkOpener{};
    const options: cli.Options = .{ .plants = .{ true, false } };

    try testing.expectError(
        error.ProbeFailed,
        runComposition(undefined, testing.allocator, options, &probe_opener, &sink_opener),
    );
    try testing.expect(!sink_opener.called);
}
