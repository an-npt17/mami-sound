const std = @import("std");

const cli = @import("cli.zig");
const core = @import("core/root.zig");
const engine = @import("application/engine.zig");
const ports = @import("ports/root.zig");
const ads1115 = @import("adapters/ads1115.zig");
const ads1115_probe = @import("adapters/ads1115_probe.zig");
const aplay_sink = @import("adapters/aplay_sink.zig");
const clip_loader = @import("adapters/clip_loader.zig");
const decode = @import("adapters/decode.zig");
const random_probe = @import("adapters/random_probe.zig");
const stderr_status = @import("adapters/stderr_status.zig");

const ProductionProbeOpener = struct {
    fn open(_: *ProductionProbeOpener, _: std.Io) ads1115.Error!ads1115_probe.Adapter {
        return ads1115_probe.Adapter.open(ads1115.default_bus, ads1115.default_address);
    }
};

const TestProbeOpener = struct {
    fn open(_: *TestProbeOpener, _: std.Io) !random_probe.Adapter {
        return random_probe.Adapter.init();
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
            error.InvalidNoiseFile => std.debug.print(
                "--noise-file needs a path, at most {d} characters.\n\n",
                .{cli.noise_file_max},
            ),
            error.UnknownFlag => std.debug.print("unknown flag.\n\n", .{}),
            else => std.debug.print("could not read arguments: {s}\n\n", .{@errorName(err)}),
        }
        std.debug.print("{s}", .{cli.usage});
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    var sink_opener = ProductionSinkOpener{};
    if (opts.test_random_probe) {
        std.debug.print("loading: using test random probe\n", .{});
        var probe_opener = TestProbeOpener{};
        return runComposition(io, gpa, opts, &probe_opener, &sink_opener) catch |err| {
            std.debug.print("mami_sound stopped: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    var probe_opener = ProductionProbeOpener{};
    return runComposition(io, gpa, opts, &probe_opener, &sink_opener) catch |err| {
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
    std.debug.print("loading: opening probe...\n", .{});
    var probe = try probe_opener.open(io);
    defer probe.close();
    std.debug.print("loading: probe ready\n", .{});

    const noise_file_samples: ?[]f32 = if (opts.noiseFile()) |path| blk: {
        std.debug.print("loading: noise file {s}...\n", .{path});
        const samples = try decode.loadFile(gpa, io, path, core.sample_rate);
        std.debug.print("loading: noise file ready ({d} samples)\n", .{samples.len});
        break :blk samples;
    } else null;
    defer {
        if (noise_file_samples) |samples| gpa.free(samples);
    }

    var clips: clip_loader.LoadedPool = if (opts.plants[1]) blk: {
        std.debug.print("loading: Plant B clips...\n", .{});
        const loaded = try clip_loader.loadPlantB(gpa, io, core.sample_rate);
        std.debug.print("loading: Plant B clips ready ({d})\n", .{loaded.clips.len});
        break :blk loaded;
    } else blk: {
        std.debug.print("loading: Plant B clips skipped\n", .{});
        break :blk clip_loader.LoadedPool.empty;
    };
    defer clips.deinit(gpa);

    std.debug.print("loading: opening audio sink...\n", .{});
    var sink = try sink_opener.open(io, opts.device());
    std.debug.print("loading: audio sink ready\n", .{});

    var status = stderr_status.Adapter.init(io);
    var shuffle = std.Random.DefaultPrng.init(shuffleSeed(io));
    var sink_port = sink.port();
    std.debug.print("loading: starting engine...\n", .{});
    var app = engine.Engine.init(
        opts.plants,
        probe.source(),
        sink_port,
        status.port(),
        noise_file_samples,
        clips.clips,
        shuffle.random(),
    );
    std.debug.print("loading: complete\n", .{});
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
