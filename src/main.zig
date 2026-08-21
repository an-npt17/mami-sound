//! Wires the simulated sensors to the three voices and pipes the mix to aplay.

const std = @import("std");
const ms = @import("mami_sound");

/// Where plants B and C draw their clips from. One file is chosen out of each
/// folder at start up, so switching the installation on gives a different pair
/// rather than the same two recordings every day.
///
/// A folder rather than a list: dropping a new recording in is all it takes to
/// put it in the rotation, with nothing here to edit.
const clip_b_dir = "interview files";
const clip_c_dir = "field records";

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

    fn render(self: *VoiceA, block: []f32, ecg: i16, touched: bool) void {
        switch (self.*) {
            inline else => |*v| v.render(block, ecg, touched),
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
                "--trigger takes a whole number between 0 and {d}, or nothing at all.\n\n",
                .{ms.sensors.ecg_max},
            ),
            error.InvalidInterrupt => std.debug.print(
                "--interrupt takes seconds between 0 and 3600.\n\n",
                .{},
            ),
            error.InvalidTriggerAverage => std.debug.print(
                "--trigger-average takes milliseconds between 0 and 3000.\n\n",
                .{},
            ),
            error.InvalidTriggerHold => std.debug.print(
                "--trigger-hold takes milliseconds between 0 and 5000.\n\n",
                .{},
            ),
            error.InvalidDevice => std.debug.print("--device needs a name, at most 63 characters.\n\n", .{}),
            error.UnknownFlag => std.debug.print("unknown flag.\n\n", .{}),
            else => std.debug.print("could not read arguments: {s}\n\n", .{@errorName(err)}),
        }
        std.debug.print("{s}", .{ms.cli.usage});
        std.process.exit(if (err == error.HelpRequested) 0 else 1);
    };
    const sel = opts.plants;

    // The engine's own `seed` is fixed so a run sounds identical; which clips a
    // touch draws is the one thing that should not be.
    var shuffle = std.Random.DefaultPrng.init(shuffleSeed(io));
    const draw = shuffle.random();

    // A plant that is not playing needs no clips, so a run of `1` works on a
    // machine with no audio folders and no ffmpeg.
    var folder_b: Folder = if (sel[1]) try loadFolder(gpa, io, clip_b_dir) else .empty;
    defer folder_b.deinit(gpa);
    var folder_c: Folder = if (sel[2]) try loadFolder(gpa, io, clip_c_dir) else .empty;
    defer folder_c.deinit(gpa);
    const folders = [_]*const Folder{ &folder_b, &folder_c };

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
            .{ .flute = ms.sampler.Voice.init(flute, ms.sample_rate, ms.sensors.ecg_max) }
        else
            .{ .drone = ms.noise.Noise.init(ms.sample_rate, seed, ms.noise.default_span) },
        .beep => .{ .beep = ms.tone.Tone.init(ms.sample_rate, ms.sensors.ecg_max) },
        .drone => .{ .drone = ms.noise.Noise.init(ms.sample_rate, seed, ms.noise.default_span) },
    };
    // B and C answer one probe between them, so they are one voice with two
    // folders rather than two voices that happen to share a threshold.
    var voices_bc = ms.player.Sequence.init(
        .{ folder_b.clips, folder_c.clips },
        ms.sample_rate,
        @as(u64, @intFromFloat(opts.interrupt_s * @as(f32, @floatFromInt(ms.sample_rate)))),
        draw,
    );

    // The threshold, debounced. A reading is a vote rather than a decision:
    // see `trigger.zig` for why one poll of it cannot be trusted.
    var gate: ?ms.trigger.Trigger = if (opts.trigger_level) |level|
        ms.trigger.Trigger.init(
            level,
            ms.trigger.holdPolls(opts.trigger_hold_ms, ms.sample_rate, ms.sensor_frames),
            ms.trigger.holdPolls(opts.trigger_average_ms, ms.sample_rate, ms.sensor_frames),
        )
    else
        null;

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
        voices_bc.isPlaying())
    {
        // Voices add into the block, so it starts from silence each time.
        @memset(&block, 0);

        // The block is rendered in poll-sized pieces, each one driven by its
        // own sensor reading, so the sound follows the plants at the sensor
        // rate rather than the sound card's.
        var raw_a: i16 = 0;
        var raw_bc: i16 = 0;
        var touch: [ms.sensors.plant_count]bool = undefined;

        var offset: usize = 0;
        while (offset < block.len) : (offset += ms.sensor_frames) {
            const piece = block[offset..][0..ms.sensor_frames];

            const reading = sens.tick(ms.sensor_frames);
            raw_a = reading.raw_a;
            raw_bc = reading.raw_bc;
            // Disabled plants read as untouched, so their voices never open.
            touch = ms.select.apply(sel, reading.touch);

            // The AIN1 probe *is* the touch for plants B and C: crossing the
            // threshold plays one clip, and the other waits for the next
            // crossing. Their motion sensors have no say — a threshold was
            // asked for, so the threshold is the sensor. Without one there is
            // nothing to cross, and the plants fall back to being awake.
            //
            // Passed as a level rather than wrapped around `render`, because
            // the clip has to keep running once started: skipping the call
            // would freeze it mid-word and resume it later, where this way the
            // threshold only decides when a clip *begins*.
            const open = if (gate) |*g|
                g.update(raw_bc)
            else
                touch[1] or touch[2];

            // Plant A hears its own probe, and only that one.
            voice_a.render(piece, raw_a, touch[0]);

            // The threshold is tested here, every poll, 344 times a second,
            // while the status line below prints once a second. A reading that
            // crosses for a few milliseconds starts a clip and is gone before
            // the next line, which looks exactly like a clip starting on its
            // own. Say so at the moment it happens, with the number that did
            // it and the recording it drew.
            //
            // Counted rather than watched for idle-to-playing: an interrupt
            // replaces one clip with another inside a single block, and never
            // passes through idle at all.
            const before = voices_bc.starts;
            voices_bc.render(piece, open);
            if (voices_bc.starts != before) reportStart(&voices_bc, folders, raw_bc);

            // Report the clip that is actually sounding, not the pair's gate:
            // under a sequence only one of them can be audible at a time.
            const sounding = voices_bc.playingIndex();
            touch[1] = sounding == 0;
            touch[2] = sounding == 1;
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
        status.observe(io, raw_a, raw_bc, touch, &block, rendered);
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
///   * `a0` and `a1` are the two probes and `touch` the motion sensors, all as
///     the voices see them. `a0` is plant A's pitch; `a1` is the number the
///     `--trigger` threshold is compared against.
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
        raw_a: i16,
        raw_bc: i16,
        touched: [ms.sensors.plant_count]bool,
        block: []const f32,
        rendered: usize,
    ) void {
        for (block) |sample| self.peak = @max(self.peak, @abs(sample));
        if (rendered < self.next_frame) return;
        self.next_frame += period;

        const now_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
        self.last_ns = now_ns;
        const audio_s = @as(f64, @floatFromInt(rendered)) /
            @as(f64, @floatFromInt(ms.sample_rate));
        // Every line covers exactly one second of audio, so the ratio is just
        // how long that second took to hand over.

        const letters = [ms.sensors.plant_count]u8{ 'A', 'B', 'C' };
        var touch: [ms.sensors.plant_count]u8 = undefined;
        for (&touch, letters, touched) |*out, letter, awake| {
            out.* = if (awake) letter else '-';
        }

        std.debug.print("t={d:.0}s a0={d} a1={d} touch={s}\n", .{ audio_s, raw_a, raw_bc, &touch });
        self.peak = 0.0;
    }
};

/// Attach whichever devices are actually present. Each one falls back to its
/// simulation on its own, so the same binary runs on the finished installation,
/// on a half-wired bench and on a laptop with no hardware at all.
fn openSensors(touch: ms.cli.Touch) ms.sensors.Sensors {
    var sens = ms.sensors.Sensors.init(ms.sample_rate, seed);

    // The multiplexer starts on plant A's probe; `sensors` steps it from there.
    if (ms.ads1115.Ads1115.open(
        ms.ads1115.default_bus,
        ms.ads1115.default_address,
        .{ .mux = ms.sensors.input_a },
    )) |adc| {
        sens.attachAdc(adc);
    } else |err| {
        std.debug.print(
            \\no ADS1115 on {s}: {s}
            \\Both probes run simulated.
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

/// A seed that differs from run to run, taken from the wall clock. Only the
/// clip draw uses it.
fn shuffleSeed(io: std.Io) u64 {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @truncate(@as(u96, @bitCast(ns)));
}

/// One plant's folder: the decoded clips, and the names to call them by.
const Folder = struct {
    clips: []const []const f32,
    /// Held past loading only so a clip can be named when it starts.
    names: [][]u8,

    const empty: Folder = .{ .clips = &.{}, .names = &.{} };

    fn deinit(self: *Folder, gpa: std.mem.Allocator) void {
        for (self.clips) |clip| gpa.free(clip);
        if (self.clips.len != 0) gpa.free(self.clips);
        if (self.names.len != 0) ms.library.freeList(gpa, self.names);
        self.* = .empty;
    }
};

/// Say which recording just started and what let it in. An operator hearing
/// something unexpected needs the name, and the reading tells them whether the
/// threshold is doing its job or noise is.
fn reportStart(
    seq: *const ms.player.Sequence,
    folders: [ms.player.Sequence.count]*const Folder,
    reading: i16,
) void {
    const slot = seq.playingIndex() orelse return;
    const clip = seq.playingClip() orelse return;
    const names = folders[slot].names;
    if (clip >= names.len) return;
    std.debug.print("clip {c}: {s}  (a1={d})\n", .{
        @as(u8, 'B') + @as(u8, @intCast(slot)),
        names[clip],
        reading,
    });
}

/// Decode every clip in `dir`, listing them and what they cost.
///
/// A touch has to start a clip at once, and decoding one takes ffmpeg seconds,
/// so the whole folder is held in memory and drawn from. The total is printed
/// because that is the number which decides how many recordings a machine can
/// carry: roughly 10 MB per minute of audio.
fn loadFolder(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) !Folder {
    const paths = ms.library.list(gpa, io, dir) catch |err| {
        switch (err) {
            ms.library.Error.NoAudioFiles => std.debug.print(
                \\no audio files in ./{s}/
                \\Put the recordings for that plant there; mp3, wav, ogg and
                \\flac are all read.
                \\
            , .{dir}),
            else => std.debug.print(
                \\could not read ./{s}/: {s}
                \\That folder is where the plant's recordings live.
                \\
            , .{ dir, @errorName(err) }),
        }
        // A folder that is missing or empty is a setup mistake, the same class
        // as a bad flag: it has been explained, so leave without a stack trace.
        std.process.exit(1);
    };
    errdefer ms.library.freeList(gpa, paths);

    const pool = try gpa.alloc([]const f32, paths.len);
    var done: usize = 0;
    errdefer {
        for (pool[0..done]) |clip| gpa.free(clip);
        gpa.free(pool);
    }

    var frames: usize = 0;
    for (paths, pool) |path, *slot| {
        slot.* = try loadClip(gpa, io, path);
        frames += slot.len;
        done += 1;
        std.debug.print("  {s}\n", .{path});
    }

    const seconds = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(ms.sample_rate));
    std.debug.print("{s}: {d} clips, {d:.0}s, {d:.0} MB\n", .{
        dir,
        pool.len,
        seconds,
        @as(f64, @floatFromInt(frames * @sizeOf(f32))) / (1024.0 * 1024.0),
    });
    return .{ .clips = pool, .names = paths };
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
