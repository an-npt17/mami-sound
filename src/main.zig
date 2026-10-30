const std = @import("std");

const cli = @import("cli.zig");
const core = @import("core/root.zig");
const engine = @import("application/engine.zig");
const ports = @import("ports/root.zig");
const production_config = @import("application/production_config.zig");
const boxes = @import("application/boxes/root.zig");
const ads1115 = @import("adapters/ads1115.zig");
const ads1115_probe = @import("adapters/ads1115_probe.zig");
const aplay_sink = @import("adapters/aplay_sink.zig");
const clip_loader = @import("adapters/clip_loader.zig");
const interrupt = @import("adapters/interrupt.zig");
const clip_stream = @import("adapters/clip_stream.zig");
const voice_mod = @import("application/voice.zig");
const random_probe = @import("adapters/random_probe.zig");
const file_probe = @import("adapters/file_probe.zig");
const probe_capture = @import("adapters/probe_capture.zig");
const stderr_status = @import("adapters/stderr_status.zig");

const ProductionProbeOpener = struct {
    fn open(_: *ProductionProbeOpener, _: std.Io) ads1115.Error!ads1115_probe.Adapter {
        return ads1115_probe.Adapter.open(ads1115.default_bus, ads1115.default_address);
    }
};

const TestProbeOpener = struct {
    style: random_probe.Style,

    fn open(self: *TestProbeOpener, _: std.Io) !random_probe.Adapter {
        return random_probe.Adapter.initStyle(self.style);
    }
};

const FileProbeOpener = struct {
    gpa: std.mem.Allocator,
    path: []const u8,

    fn open(self: *FileProbeOpener, io: std.Io) !file_probe.Adapter {
        const probe = try file_probe.Adapter.load(io, self.gpa, self.path);
        std.debug.print(
            "loading: playing {s} as the probes, {d:.0} s a pass\n",
            .{ self.path, probe.seconds() },
        );
        return probe;
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
                "--plant-a and --plant-b take a source: {s}.\n\n",
                .{core.source.names},
            ),
            error.InvalidSeconds => std.debug.print(
                "--seconds and --retrigger take a number of seconds, zero or more.\n\n",
                .{},
            ),
            error.SecondsOnDrone => std.debug.print(
                "the drone has no clip, so it takes no length.\n\n",
                .{},
            ),
            error.InvalidCapture => std.debug.print(
                "--capture takes a path and --capture-seconds a number above zero.\n\n",
                .{},
            ),
            error.InvalidStillThreshold => std.debug.print(
                "--still-range, --still-release, --still-window and --edge-b take a number " ++
                    "above zero.\n--touch-confirm takes seconds, zero or more.\n--plant-a-band and --plant-b-band take LO:HI in counts, low end " ++
                    "first, both ends given.\n\n",
                .{},
            ),
            error.InvalidBandShare => std.debug.print(
                "--band-share and --band-share-b take a fraction above zero and at " ++
                    "most one, and --band-release and --band-release-b one from zero " ++
                    "to one.\n\n",
                .{},
            ),
            error.InvalidMode => std.debug.print(
                "--plant-a-mode and --plant-b-mode take a mode: {s}.\n\n",
                .{core.clips.mode_names},
            ),
            error.ModeOnDrone => std.debug.print(
                "the drone already sounds while it is held; it takes no mode.\n\n",
                .{},
            ),
            error.InvalidTouchFall => std.debug.print("--touch-fall takes a number of seconds above zero.\n\n", .{}),
            error.InvalidTouchGust => std.debug.print(
                "--touch-gust takes a number of semitones from zero to {d}.\n\n",
                .{core.noise.gust_max_semis},
            ),
            error.InvalidDroneGain => std.debug.print("--drone-gain takes a level in dB from -40 to 6.\n\n", .{}),
            error.InvalidDroneIdle => std.debug.print("--drone-idle takes a fraction from zero to one.\n\n", .{}),
            error.InvalidTimbre => std.debug.print(
                "--drone-timbre takes a timbre: {s}.\n\n",
                .{core.timbre.names},
            ),
            error.InvalidProbeFile => std.debug.print(
                "--test-probe-file takes the path of a capture CSV.\n\n",
                .{},
            ),
            error.UnknownFlag => std.debug.print("unknown flag.\n\n", .{}),
            else => std.debug.print("could not read arguments: {s}\n\n", .{@errorName(err)}),
        }
        std.debug.print("{s}", .{cli.usage});
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };

    var sink_opener = ProductionSinkOpener{};
    if (opts.probeFile()) |path| {
        var probe_opener = FileProbeOpener{ .gpa = gpa, .path = path };
        return runComposition(io, gpa, opts, &probe_opener, &sink_opener) catch |err| {
            std.debug.print("mami_sound stopped: {s}\n", .{@errorName(err)});
            return err;
        };
    }
    if (opts.test_random_probe) {
        // The learned model was written for the installed rig, whose probe
        // flips between rails under a hand; a probe held still at one level
        // gives it a share that never moves and the drone nothing to bend on.
        const style: random_probe.Style = if (opts.model == .learned) .rig else .steady;
        std.debug.print("loading: using test random probe ({s} touches)\n", .{@tagName(style)});
        var probe_opener = TestProbeOpener{ .style = style };
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

    // Which box this is decides what the plants play and what the detector is
    // given, so it is settled once, before anything is loaded off disk.
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const box = production_config.chosenBox(opts.box, hostname(&host_buf));
    const preset = if (box) |which| boxes.presetFor(which) else boxes.default_preset;
    if (box) |which| {
        std.debug.print("loading: {t}\n", .{which});
    } else {
        std.debug.print(
            "loading: no box named, and this machine is none of the five: " ++
                "running the unmeasured defaults\n",
            .{},
        );
    }

    // What a touch sounds like depends on which model is answering, so the
    // drone's shape is settled together with the model rather than before it.
    const drone_shape = production_config.droneWith(preset.drone, .{
        .touch_floor = opts.touch_floor,
        .touch_rise_s = opts.touch_rise_s,
        .wobble_semis = opts.touch_wobble,
        .gust_semis = opts.touch_gust,
        .drone_gain_db = opts.drone_gain,
        .touch_climb_semis = opts.touch_climb,
        .timbre = opts.timbre,
        .touch_fall_s = opts.touch_fall,
        .idle_gain = opts.drone_idle,
    }, opts.model orelse preset.touch.model);
    var voices: [2]voice_mod.Voice = .{ droneVoice(drone_shape), droneVoice(drone_shape) };
    // What each plant does with a hand, in the one place both the voice and
    // the detector read it from. The drone is held by nature and takes no
    // mode, so it is recorded as a trigger and the detector is told nothing.
    var modes: [2]core.clips.Mode = .{ .trigger, .trigger };

    for (0..2) |plant| {
        const name: []const u8 = if (plant == 0) "A" else "B";
        if (!opts.plants[plant]) {
            std.debug.print("loading: plant {s} skipped\n", .{name});
            continue;
        }
        // The room's answer, or this box's. A room that says nothing is not a
        // room asking for the drone, which is the distinction a plain default
        // could not make and the reason the field is optional.
        const chosen = opts.plant_sources[plant] orelse preset.plants[plant].source;
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

        const mode = opts.plant_mode[plant] orelse preset.plants[plant].mode;
        modes[plant] = mode;
        const seconds = opts.plant_seconds[plant] orelse preset.plants[plant].seconds;
        const limit: core.clips.Limit = .forSource(chosen, seconds, mode, core.sample_rate);
        if (limit.total == core.clips.Limit.unlimited.total) {
            std.debug.print("loading: plant {s} plays each clip to its end\n", .{name});
        } else {
            const played =
                @as(f32, @floatFromInt(limit.total)) / @as(f32, @floatFromInt(core.sample_rate));
            std.debug.print(
                "loading: each touch on plant {s} plays {d:.1}s\n",
                .{ name, played },
            );
        }

        streams[plant] = try clip_stream.Adapter.init(io, gpa, pools[plant].paths, limit);
        if (chosen == .piano) streams[plant].gain *= production_config.piano_clip_gain;
        if (chosen == .tradvn2) streams[plant].gain *= production_config.tradvn2_clip_gain;
        if (chosen == .bell) streams[plant].gain *= production_config.bell_clip_gain;
        if (chosen == .insect3 or chosen == .insect5) streams[plant].gain *= production_config.insect_clip_gain;
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

        // Three answers in order: the room's, the box's, the source's own.
        const retrigger = opts.plant_retrigger[plant] orelse
            preset.plants[plant].retrigger orelse
            chosen.defaultRetriggerSeconds();
        if (mode == .hold) {
            std.debug.print("loading: plant {s} sounds while it is held\n", .{name});
        }
        const order = pools[plant].order;
        if (order == .sequential) {
            std.debug.print(
                "loading: plant {s} plays its folder in order, part by part\n",
                .{name},
            );
        }
        voices[plant] = .{
            .clips = .{
                .stream = streams[plant].port(),
                .selector = .init(
                    pools[plant].paths.len,
                    retrigger,
                    core.sample_rate,
                    shuffle.random(),
                    order,
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

    // Only when the room asked. A capture holds every poll of both probes in
    // memory for its whole length, and reaches the disk once, when it is full.
    var capture: ?probe_capture.Adapter = if (opts.capture()) |path| blk: {
        const writer = try probe_capture.Adapter.init(io, gpa, path, opts.capture_s);
        std.debug.print(
            "loading: writing {d:.0}s of probe readings to {s}\n",
            .{ opts.capture_s, path },
        );
        break :blk writer;
    } else null;
    defer if (capture) |*writer| writer.deinit();

    var status = stderr_status.Adapter.init(io);
    var sink_port = sink.port();
    std.debug.print("loading: starting engine...\n", .{});
    var app = engine.Engine.init(
        opts.plants,
        production_config.touchWith(preset.touch, .{
            .model = opts.model,
            .still_range = opts.still_range,
            .still_release = opts.still_release,
            .still_window_ms = opts.still_window_ms,
            .band_share = opts.band_share,
            .band_release = opts.band_release,
            .band_share_bc = opts.band_share_bc,
            .band_release_bc = opts.band_release_bc,
            .edge_bc = opts.edge_bc,
            .edge = opts.edge_a,
            .plant_band = opts.plant_band,
            .plant_window = opts.plant_window,
            .counts = opts.counts,
            .counts_bc = opts.counts_bc,
            .confirm_ms = opts.confirm_ms,
        }, modes),
        probe.source(),
        sink_port,
        status.port(),
        voices,
        if (capture) |*writer| writer.port() else null,
    );
    // From here a Ctrl-C, or a systemd stop, comes out through the shutdown
    // below rather than killing the process where it stands.
    interrupt.listen();

    std.debug.print("loading: complete\n", .{});
    const outcome = app.run(interrupt.requested);

    // Whatever the run did, what it measured is worth keeping. Written here
    // rather than on the way out of a signal handler, where writing a file is
    // one of several things that are not allowed.
    if (capture) |*writer| writer.flush();

    return finishAfterRun(&sink_port, outcome);
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

/// The generated voice, with this box's measured shape.
fn droneVoice(shape: core.noise.Shape) voice_mod.Voice {
    return .{ .drone = .init(core.sample_rate, production_config.seed, shape) };
}

fn shuffleSeed(io: std.Io) u64 {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @truncate(@as(u96, @bitCast(ns)));
}

/// What this machine calls itself, or nothing.
///
/// Nothing rather than an error: a machine that cannot say its own name is a
/// bench or a container, and both should run the unmeasured defaults and be
/// told so on the loading line rather than refusing to start.
fn hostname(buf: *[std.posix.HOST_NAME_MAX]u8) []const u8 {
    return std.posix.gethostname(buf) catch "";
}
