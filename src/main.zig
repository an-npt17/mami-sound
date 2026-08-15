//! Wires the simulated sensors to the three voices and pipes the mix to aplay.

const std = @import("std");
const ms = @import("mami_sound");

/// Plant B's clip: a spoken interview.
const clip_b_path = "phong-van1.mp3";
/// Plant C's clip: running water.
const clip_c_path = "am-thanh-tu-nhien.mp3";

/// Length of the sensor script, which is the only thing that ever ends a run.
/// The loop keeps going past this until the one-shot clips have finished, so
/// nothing is cut off mid-playback. Every other touch source plays until the
/// program is stopped.
const script_seconds: usize = 15;

/// Fixed so every run sounds identical and can be compared by ear.
const seed: u64 = 0xC0FFEE;

/// Plant A's voice, whichever was asked for. Both are driven the same way, so
/// the render loop never has to know which one it is holding.
const VoiceA = union(ms.cli.Voice) {
    drone: ms.noise.Noise,
    flute: ms.sampler.Voice,
    beep: ms.tone.Tone,

    fn render(self: *VoiceA, block: []f32, ecg_volts: f32, touched: bool) void {
        switch (self.*) {
            inline else => |*v| v.render(block, ecg_volts, touched),
        }
    }
};

pub fn main(init: std.process.Init) !void {
    // `init.io` comes from the startup code already carrying the real
    // environment, which is what lets `aplay` and `ffmpeg` be found on PATH.
    const io = init.io;
    const gpa = init.gpa;

    // A bad flag is a user mistake, not a crash: say what is wrong, show the
    // usage and leave, with no stack trace.
    const opts = parseArgs(gpa, init.minimal.args) catch |err| {
        switch (err) {
            error.HelpRequested => {},
            error.TooManyArguments => std.debug.print("takes at most one plant selection.\n\n", .{}),
            error.InvalidSelection => std.debug.print("PLANTS must be digits 1-3.\n\n", .{}),
            error.UnknownVoice => std.debug.print("--voice must be drone, flute or beep.\n\n", .{}),
            error.UnknownTouch => std.debug.print("--touch must be always, script or motion.\n\n", .{}),
            error.InvalidTrigger => std.debug.print(
                "--trigger takes volts between 0 and {d:.1}, or nothing at all.\n\n",
                .{ms.sensors.volts_max},
            ),
            error.InvalidDevice => std.debug.print("--device needs a name, at most 63 characters.\n\n", .{}),
            error.UnknownFlag => std.debug.print("unknown flag.\n\n", .{}),
            else => std.debug.print("could not read arguments: {s}\n\n", .{@errorName(err)}),
        }
        std.debug.print("{s}", .{ms.cli.usage});
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };
    const sel = opts.plants;

    // A plant that is not playing does not need its clip, so a run of `1` works
    // on a machine with no audio files and no ffmpeg.
    const clip_b: []const f32 = if (sel[1]) try loadClip(gpa, io, clip_b_path) else &.{};
    defer if (clip_b.len != 0) gpa.free(clip_b);
    const clip_c: []const f32 = if (sel[2]) try loadClip(gpa, io, clip_c_path) else &.{};
    defer if (clip_c.len != 0) gpa.free(clip_c);

    // Likewise the flute set: twelve files to decode, and only when both the
    // flute voice was asked for and plant A is actually playing.
    const flute: []ms.sampler.Prepared = if (opts.voice == .flute and sel[0])
        try loadFlute(gpa, io)
    else
        &.{};
    defer if (flute.len != 0) ms.sampler.free(gpa, flute);

    var out = ms.sink.Sink.init(io, opts.device(), ms.sample_rate, ms.channels) catch |err| {
        std.debug.print(
            \\could not start aplay on {s}: {s}
            \\aplay comes from alsa-utils; run this inside `nix develop`.
            \\`aplay -l` lists the cards, then pass --device=plughw:0,0.
            \\
        , .{ opts.device(), @errorName(err) });
        return err;
    };

    var sens = openSensors(opts.touch);
    defer sens.deinit();
    var voice_a: VoiceA = switch (opts.voice) {
        // Falls back to the drone when the flute was asked for but plant A is
        // not playing, in which case nothing was loaded and nothing is heard.
        .flute => if (flute.len != 0)
            .{ .flute = ms.sampler.Voice.init(flute, ms.sample_rate, ms.sensors.volts_max) }
        else
            .{ .drone = ms.noise.Noise.init(ms.sample_rate, seed) },
        .beep => .{ .beep = ms.tone.Tone.init(ms.sample_rate, ms.sensors.volts_max) },
        .drone => .{ .drone = ms.noise.Noise.init(ms.sample_rate, seed) },
    };
    var voice_b = ms.player.Player.init(clip_b);
    var voice_c = ms.player.Player.init(clip_c);

    var block: [ms.block_frames]f32 = undefined;
    var pcm: [ms.block_frames]i16 = undefined;

    const script_frames = ms.sample_rate * script_seconds;
    // Only the script has an end to reach. Driven by sensors, real or assumed,
    // the installation plays until it is switched off.
    const scripted = opts.touch == .script;
    var rendered: usize = 0;

    var status: Status = .init(io);

    while (!scripted or
        rendered < script_frames or
        voice_b.isPlaying() or
        voice_c.isPlaying())
    {
        // Voices add into the block, so it starts from silence each time.
        @memset(&block, 0);

        // The block is rendered in poll-sized pieces, each one driven by its
        // own sensor reading, so the sound follows the plants at the sensor
        // rate rather than the sound card's.
        var ecg_volts: f32 = 0.0;
        var touch: [ms.sensors.plant_count]bool = undefined;

        var offset: usize = 0;
        while (offset < block.len) : (offset += ms.sensor_frames) {
            const piece = block[offset..][0..ms.sensor_frames];

            const reading = sens.tick(ms.sensor_frames);
            ecg_volts = reading.ecg_volts;
            // Disabled plants read as untouched, so their voices never open.
            touch = ms.select.apply(sel, reading.touch);

            // Plant A's reading can hold the other two shut. Folded into their
            // touch flags rather than wrapped around `render`: skipping the
            // call would freeze a clip in place mid-word and resume it later,
            // where this way the threshold is just another thing that has to be
            // true for a clip to start, and a started clip still plays through.
            if (opts.trigger_volts) |threshold| {
                const open = ecg_volts >= threshold;
                touch[1] = touch[1] and open;
                touch[2] = touch[2] and open;
            }

            voice_a.render(piece, ecg_volts, touch[0]);
            voice_b.render(piece, touch[1]);
            voice_c.render(piece, touch[2]);
        }

        ms.sink.toPcm(&block, &pcm);
        // Blocks until aplay wants more, which is what paces the whole program.
        out.write(&pcm) catch |err| switch (err) {
            // aplay gave up on the card and closed the pipe. It has already
            // said why on its own stderr, so add what to do about it.
            error.BrokenPipe => reportSinkDeath(gpa, io, opts.device()),
            else => return err,
        };

        rendered += ms.block_frames;
        // The letters report what the voices were told, threshold included, so
        // a line showing `A--` under `--trigger` is the gate doing its job.
        status.observe(io, ecg_volts, touch, &block, rendered);
    }

    try out.finish();
}

/// Say what a dead `aplay` means and list what else could be played through.
///
/// The device existing is not the same as the device accepting this stream: a
/// Pi's HDMI card is present whether or not a display is, and refuses to set
/// hardware parameters when nothing is plugged into it. `aplay -l` is the list
/// of what is really there, and it is worth printing rather than telling
/// someone to go and run it.
fn reportSinkDeath(gpa: std.mem.Allocator, io: std.Io, device: []const u8) noreturn {
    std.debug.print(
        \\
        \\aplay stopped: {s} would not take this stream (44100 Hz, mono,
        \\S16_LE). Its own reason is above.
        \\
    , .{device});

    if (std.process.run(gpa, io, .{
        .argv = &.{ "aplay", "-l" },
        .stdout_limit = .limited(64 * 1024),
        .reserve_amount = 4096,
    })) |result| {
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        std.debug.print("\n{s}\n", .{result.stdout});
    } else |_| {}

    std.debug.print(
        \\Pass --device=plughw:CARD,DEVICE with the numbers from that list. The
        \\`plug` prefix resamples for a card that cannot do 44100 Hz itself.
        \\
    , .{});
    std.process.exit(1);
}

/// One line a second on stderr, in place of anything per block: a print every
/// 11.6 ms is both unreadable and slow enough to matter on a Zero 2 W.
///
/// The three numbers answer the three questions worth asking of a run that is
/// not making the noise it should:
///
///   * `peak` is the loudest sample of the last second. Zero means the engine
///     itself is silent, so no plant was awake and nothing is wrong downstream.
///   * `realtime` is audio time over wall time. `aplay` blocks until the card
///     wants more, so a healthy run sits at x1.00. Much above that means
///     nothing is being paced: the samples are going somewhere that swallows
///     them, which is the shape of a wrong `--device`.
///   * `ecg` and `touch` are the sensors as the voices see them.
const Status = struct {
    /// When the last line went out, so each line reports the second it covers
    /// rather than an average since startup. An average would hide a sink that
    /// stops pacing partway through, and takes a while to shake off `aplay`
    /// swallowing the first second into its buffer as fast as it is offered.
    last_ns: i96,
    next_frame: usize,
    peak: f32,

    /// Audio frames between lines.
    const period = ms.sample_rate;

    fn init(io: std.Io) Status {
        return .{
            .last_ns = std.Io.Timestamp.now(io, .awake).nanoseconds,
            .next_frame = period,
            .peak = 0.0,
        };
    }

    fn observe(
        self: *Status,
        io: std.Io,
        ecg_volts: f32,
        touched: [ms.sensors.plant_count]bool,
        block: []const f32,
        rendered: usize,
    ) void {
        for (block) |sample| self.peak = @max(self.peak, @abs(sample));
        if (rendered < self.next_frame) return;
        self.next_frame += period;

        const now_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
        const wall_s = @as(f64, @floatFromInt(now_ns - self.last_ns)) / std.time.ns_per_s;
        self.last_ns = now_ns;
        const audio_s = @as(f64, @floatFromInt(rendered)) /
            @as(f64, @floatFromInt(ms.sample_rate));
        // Every line covers exactly one second of audio, so the ratio is just
        // how long that second took to hand over.
        const interval_s = @as(f64, @floatFromInt(period)) /
            @as(f64, @floatFromInt(ms.sample_rate));

        const letters = [ms.sensors.plant_count]u8{ 'A', 'B', 'C' };
        var touch: [ms.sensors.plant_count]u8 = undefined;
        for (&touch, letters, touched) |*out, letter, awake| {
            out.* = if (awake) letter else '-';
        }

        std.debug.print("t={d:.0}s ecg={d:.2}V touch={s} peak={d:.2} realtime=x{d:.2}\n", .{
            audio_s,
            ecg_volts,
            &touch,
            self.peak,
            // Guarded so a clock that has not moved yet reports nothing absurd.
            if (wall_s > 0) interval_s / wall_s else 0.0,
        });
        self.peak = 0.0;
    }
};

/// Attach whichever devices are actually present. Each one falls back to its
/// simulation on its own, so the same binary runs on the finished installation,
/// on a half-wired bench and on a laptop with no hardware at all.
fn openSensors(touch: ms.cli.Touch) ms.sensors.Sensors {
    var sens = ms.sensors.Sensors.init(ms.sample_rate, seed);

    if (ms.ads1115.Ads1115.open(
        ms.ads1115.default_bus,
        ms.ads1115.default_address,
        .{},
    )) |adc| {
        sens.attachAdc(adc);
    } else |err| {
        std.debug.print(
            \\no ADS1115 on {s}: {s}
            \\Plant A runs on the simulated ECG.
            \\
        , .{ ms.ads1115.default_bus, @errorName(err) });
    }

    switch (touch) {
        // The GPIO sensors are only opened when they are asked for, so a run
        // during bring-up neither depends on them nor complains about them.
        .always => {},
        .script => sens.useScript(),
        .motion => {
            if (ms.gpio.Lines.openDefault(&ms.gpio.default_offsets, .{})) |lines| {
                sens.attachMotion(lines);
            } else |err| {
                std.debug.print(
                    \\no motion sensors on GPIO {any}: {s}
                    \\Every plant stays awake instead.
                    \\
                , .{ ms.gpio.default_offsets, @errorName(err) });
            }
        },
    }

    return sens;
}

/// Collect the arguments and hand them to the parser, which is pure.
fn parseArgs(
    gpa: std.mem.Allocator,
    args: std.process.Args,
) (ms.cli.Error || std.mem.Allocator.Error || error{HelpRequested})!ms.cli.Options {
    var it = try args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip(); // program name

    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |a| gpa.free(a);
        list.deinit(gpa);
    }

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        }
        try list.append(gpa, try gpa.dupe(u8, arg));
    }

    return ms.cli.parse(list.items);
}

fn loadClip(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]f32 {
    return ms.decode.loadFile(gpa, io, path, ms.sample_rate) catch |err| {
        switch (err) {
            ms.decode.Error.FfmpegNotFound => std.debug.print(
                \\could not run ffmpeg, needed to decode {s}.
                \\Run this inside `nix develop`.
                \\
            , .{path}),
            else => std.debug.print(
                \\could not load {s}: {s}
                \\Expected it in the current directory.
                \\
            , .{ path, @errorName(err) }),
        }
        return err;
    };
}

fn loadFlute(gpa: std.mem.Allocator, io: std.Io) ![]ms.sampler.Prepared {
    return ms.sampler.load(
        gpa,
        io,
        ms.sampler.flute_dir,
        &ms.sampler.flute,
        ms.sample_rate,
    ) catch |err| {
        std.debug.print(
            \\could not load the flute samples: {s}
            \\Expected {d} wav files in ./{s}/, and ffmpeg on PATH.
            \\
        , .{ @errorName(err), ms.sampler.flute.len, ms.sampler.flute_dir });
        return err;
    };
}
