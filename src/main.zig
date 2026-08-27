const std = @import("std");

const cli = @import("cli.zig");
const core = @import("core/root.zig");
const engine = @import("application/engine.zig");
const ports = @import("ports/root.zig");
const production_config = @import("application/production_config.zig");
const ads1115 = @import("adapters/ads1115.zig");
const ads1115_probe = @import("adapters/ads1115_probe.zig");
const aplay_sink = @import("adapters/aplay_sink.zig");
const clip_loader = @import("adapters/clip_loader.zig");
const clip_stream = @import("adapters/clip_stream.zig");
const voice_mod = @import("application/voice.zig");
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
            error.InvalidSource => std.debug.print(
                "--plant-a and --plant-b take a source: drone, recordings, " ++
                    "daybird, insect, tradvn, bell or piano.\n\n",
                .{},
            ),
            error.InvalidSeconds => std.debug.print(
                "--seconds and --retrigger take a number of seconds, zero or more.\n\n",
                .{},
            ),
            error.SecondsOnDrone => std.debug.print(
                "the drone has no clip, so it takes no length.\n\n",
                .{},
            ),
            error.InvalidMode => std.debug.print(
                "--plant-a-mode and --plant-b-mode take `trigger` or `hold`.\n\n",
                .{},
            ),
            error.ModeOnDrone => std.debug.print(
                "the drone already sounds while it is held; it takes no mode.\n\n",
                .{},
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

    // One pool and one stream per plant. Two, not one shared: a touch on either
    // plant would otherwise cut the other off, and both would drift into
    // playing the same clip in lockstep.
    var shuffle = std.Random.DefaultPrng.init(shuffleSeed(io));

    var pools: [2]clip_loader.LoadedPool = .{ .empty, .empty };
    defer for (&pools) |*pool| pool.deinit(gpa);

    var streams: [2]clip_stream.Adapter = undefined;
    var stream_live: [2]bool = .{ false, false };
    defer for (&streams, stream_live) |*stream, live| {
        if (live) stream.deinit();
    };

    var voices: [2]voice_mod.Voice = .{ droneVoice(), droneVoice() };
    var held: [2]bool = .{ false, false };

    for (opts.plant_sources, 0..) |chosen, plant| {
        const name: []const u8 = if (plant == 0) "A" else "B";
        if (!opts.plants[plant]) {
            std.debug.print("loading: plant {s} skipped\n", .{name});
            continue;
        }
        if (chosen.isDrone()) {
            std.debug.print("loading: plant {s} is the drone\n", .{name});
            continue;
        }

        std.debug.print("loading: plant {s} clips ({t})...\n", .{ name, chosen });
        pools[plant] = clip_loader.loadPool(gpa, io, chosen) catch |err| {
            // Naming the folders is the whole of the fix: the source is chosen
            // by name, so the one thing the message has to say is which folder
            // on disk was not there.
            std.debug.print("no plant {s} clips: {s}\n", .{ name, @errorName(err) });
            for (clip_loader.directoriesFor(chosen)) |directory| {
                std.debug.print("  looked in ./{s}/\n", .{directory});
            }
            std.process.exit(1);
        };
        std.debug.print(
            "loading: plant {s} clips ready ({d})\n",
            .{ name, pools[plant].paths.len },
        );

        const limit: core.clips.Limit = .forSource(
            chosen,
            opts.plant_seconds[plant],
            core.sample_rate,
        );
        if (limit.total == core.clips.Limit.unlimited.total) {
            std.debug.print("loading: plant {s} plays each clip to its end\n", .{name});
        } else {
            const seconds =
                @as(f32, @floatFromInt(limit.total)) / @as(f32, @floatFromInt(core.sample_rate));
            std.debug.print(
                "loading: each touch on plant {s} plays {d:.1}s\n",
                .{ name, seconds },
            );
        }

        streams[plant] = try clip_stream.Adapter.init(io, gpa, pools[plant].paths, limit);
        stream_live[plant] = true;

        // Before `start`, and never fatal. The heads are what make a touch
        // audible straight away instead of one ffmpeg startup later; without
        // them the streamer still plays every clip, just late.
        std.debug.print("loading: plant {s} clip heads...\n", .{name});
        if (streams[plant].primeHeads()) |_| {
            const megabytes: f32 =
                @as(f32, @floatFromInt(streams[plant].headBytes())) / 1024.0 / 1024.0;
            std.debug.print(
                "loading: plant {s} clip heads ready ({d:.1} MB)\n",
                .{ name, megabytes },
            );
        } else |err| {
            std.debug.print(
                "plant {s} clip heads unavailable ({s}); clips start after ffmpeg does\n",
                .{ name, @errorName(err) },
            );
        }
        try streams[plant].start();

        const retrigger = opts.plant_retrigger[plant] orelse chosen.defaultRetriggerSeconds();
        const mode = opts.plant_mode[plant] orelse .trigger;
        if (mode == .hold) {
            held[plant] = true;
            std.debug.print("loading: plant {s} sounds while it is held\n", .{name});
            // Said out loud because it is a limit of the model rather than a
            // setting: the deviation model measures how far a probe has moved
            // from its own recent past, so a hand left in place becomes that
            // past within about three seconds and the plant falls quiet under
            // a hand that never left.
            if ((opts.model orelse touch_preset_model) == .deviation) {
                std.debug.print(
                    "warning: plant {s} holds for about three seconds on the deviation model;" ++
                        " --touch-model=steady holds for as long as the hand is there\n",
                    .{name},
                );
            }
        }
        voices[plant] = .{
            .clips = .{
                .stream = streams[plant].port(),
                .selector = .init(
                    pools[plant].folders,
                    retrigger,
                    core.sample_rate,
                    shuffle.random(),
                ),
                .mode = mode,
                // Shut, so the first hold is heard opening rather than arriving.
                .gate = if (mode == .hold) 0.0 else 1.0,
            },
        };
    }

    std.debug.print("loading: opening audio sink...\n", .{});
    var sink = try sink_opener.open(io, opts.device());
    std.debug.print("loading: audio sink ready\n", .{});

    var status = stderr_status.Adapter.init(io);
    var sink_port = sink.port();
    std.debug.print("loading: starting engine...\n", .{});
    var app = engine.Engine.init(
        opts.plants,
        production_config.touchWith(opts.model, opts.still_range, opts.still_release, held),
        probe.source(),
        sink_port,
        status.port(),
        voices,
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

/// The generated voice, with the room's preset shape.
/// The model the compiled preset asks for, for the warning above.
const touch_preset_model = production_config.touch.model;

fn droneVoice() voice_mod.Voice {
    return .{ .drone = .init(
        core.sample_rate,
        production_config.seed,
        production_config.drone,
    ) };
}

fn shuffleSeed(io: std.Io) u64 {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @truncate(@as(u96, @bitCast(ns)));
}
