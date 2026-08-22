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
            error.UnknownTouch => std.debug.print("--touch must be probes, always, script or motion.\n\n", .{}),
            error.TriggerRetired => std.debug.print(
                \\--trigger is gone. The threshold it set could not exist: the
                \\reading was rectified before it was compared, which folded one
                \\probe's touched state onto its untouched one.
                \\Use --touch-level, which is in deviations and serves both
                \\probes. See --help.
                \\
            , .{}),
            error.InvalidInterrupt => std.debug.print(
                "--interrupt takes seconds between 0 and 3600.\n\n",
                .{},
            ),
            error.InvalidTouchLevel => std.debug.print(
                "--touch-level and --touch-level-bc take deviations between 1 and 100.\n\n",
                .{},
            ),
            error.InvalidTouchHold => std.debug.print(
                "--touch-hold and --touch-hold-bc take milliseconds between 0 and 5000.\n\n",
                .{},
            ),
            error.InvalidTouchAverage => std.debug.print(
                "--touch-average takes milliseconds between 0 and 3000.\n\n",
                .{},
            ),
            error.InvalidTouchBaseline => std.debug.print(
                "--touch-baseline takes seconds between 0 and 100.\n\n",
                .{},
            ),
            error.InvalidTouchSettle => std.debug.print(
                "--touch-settle takes milliseconds between 0 and 5000.\n\n",
                .{},
            ),
            error.UnknownTouchModel => std.debug.print(
                "--touch-model must be deviation or steady.\n\n",
                .{},
            ),
            error.InvalidTouchBand => std.debug.print(
                "--touch-band takes LO:HI in counts, with LO below HI.\n\n",
                .{},
            ),
            error.InvalidTouchJitter => std.debug.print(
                "--touch-jitter takes a whole number of counts, zero or above.\n\n",
                .{},
            ),
            error.InvalidTouchDrop => std.debug.print(
                "--touch-drop takes milliseconds between 0 and 5000.\n\n",
                .{},
            ),
            error.InvalidTouchCounts => std.debug.print(
                "--touch-counts-bc takes a whole number of counts above zero.\n\n",
                .{},
            ),
            error.InvalidTouchWindow => std.debug.print(
                "--touch-window-bc takes milliseconds between 0 and 10000.\n\n",
                .{},
            ),
            error.InvalidPitchSpan => std.debug.print(
                "--pitch-span takes a whole number of counts above zero.\n\n",
                .{},
            ),
            error.InvalidPitchJump => std.debug.print(
                "--pitch-jump takes a fraction between 0 and 1.\n\n",
                .{},
            ),
            error.InvalidPitchGlide => std.debug.print(
                "--pitch-glide takes seconds between 0 and 60.\n\n",
                .{},
            ),
            error.InvalidPitchRelease => std.debug.print(
                "--pitch-release takes seconds between 0 and 60.\n\n",
                .{},
            ),
            error.InvalidLogPath => std.debug.print(
                "--log-touch takes a path of up to {d} characters.\n\n",
                .{ms.cli.path_max},
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
            .{ .drone = ms.noise.Noise.init(ms.sample_rate, seed, .{
            .span = opts.pitch_span,
            .jump = opts.pitch_jump,
            .glide_s = opts.pitch_glide_s,
            .release_s = opts.pitch_release_s,
        }) },
        .beep => .{ .beep = ms.tone.Tone.init(ms.sample_rate, ms.sensors.ecg_max) },
        .drone => .{ .drone = ms.noise.Noise.init(ms.sample_rate, seed, .{
            .span = opts.pitch_span,
            .jump = opts.pitch_jump,
            .glide_s = opts.pitch_glide_s,
            .release_s = opts.pitch_release_s,
        }) },
    };
    // B and C answer one probe between them, so they are one voice with two
    // folders rather than two voices that happen to share a threshold.
    var voices_bc = ms.player.Sequence.init(
        .{ folder_b.clips, folder_c.clips },
        ms.sample_rate,
        @as(u64, @intFromFloat(opts.interrupt_s * @as(f32, @floatFromInt(ms.sample_rate)))),
        draw,
    );

    // Both probes, each judged against its own recent past. A reading is a vote
    // rather than a decision: see `touch.zig` for why one poll cannot be
    // trusted, and for what happens to the other probe when this one is held.
    var machine = ms.touch.Machine.init(.{
        .sample_rate = ms.sample_rate,
        .poll_frames = ms.sensor_frames,
        .model = opts.touch_model,
        .band_lo = opts.touch_band_lo,
        .band_hi = opts.touch_band_hi,
        .jitter = opts.touch_jitter,
        .band_lo_bc = opts.touch_band_lo_bc,
        .band_hi_bc = opts.touch_band_hi_bc,
        .drop_ms = opts.touch_drop_ms,
        .level = opts.touch_level,
        .hold_ms = opts.touch_hold_ms,
        .average_ms = opts.touch_average_ms,
        .baseline_s = opts.touch_baseline_s,
        .settle_ms = opts.touch_settle_ms,
        .level_bc = opts.touch_level_bc,
        .hold_bc_ms = opts.touch_hold_bc_ms,
        .counts_bc = opts.touch_counts_bc,
        .window_bc_ms = opts.touch_window_bc_ms,
    });

    // Opened once, so a bad path is a startup failure rather than something
    // discovered an hour into a recording.
    var log: ?ms.touchlog.Log = if (opts.logPath()) |path|
        ms.touchlog.Log.create(io, path) catch |err| blk: {
            std.debug.print("could not write {s}: {s}\n", .{ path, @errorName(err) });
            break :blk null;
        }
    else
        null;
    defer if (log) |*l| l.close(io);

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
        var state: ms.touch.State = .none;
        var touch: [ms.sensors.plant_count]bool = undefined;

        var offset: usize = 0;
        while (offset < block.len) : (offset += ms.sensor_frames) {
            const piece = block[offset..][0..ms.sensor_frames];

            const reading = sens.tick(ms.sensor_frames);
            raw_a = reading.raw_a;
            raw_bc = reading.raw_bc;
            // Disabled plants read as untouched, so their voices never open.
            touch = ms.select.apply(sel, reading.touch);

            // The machine runs in every mode, not only under `probes`: plant
            // A's pitch is how far its probe has moved from rest whoever is
            // deciding when to open the voice, and a machine left unpolled
            // reports a deviation of zero forever, which pins the drone at the
            // bottom of its range for the whole of a demonstration.
            const probed = machine.update(raw_a, raw_bc);

            // The probes decide, unless a demonstration asked for something
            // else. `select` masks a plant that was left out of this run, which
            // is all it takes to keep its voice shut.
            state = switch (opts.touch) {
                .probes => probed,
                else => stateFrom(touch),
            };
            if (log) |*l| {
                const t_s = @as(f64, @floatFromInt(rendered + offset)) /
                    @as(f64, @floatFromInt(ms.sample_rate));
                l.row(io, t_s, raw_a, &machine.a, raw_bc, &machine.bc, state);
            }

            const a_touched = sel[0] and (state == .plant_a or state == .both);
            const open = (sel[1] or sel[2]) and
                (state == .plant_bc or state == .both);
            // So the status line reports what the voice was told rather than
            // what the motion sensors said, which under `probes` nothing read.
            touch[0] = a_touched;

            // Plant A hears its own probe, as a distance from that probe's
            // rest. Untouched that distance is zero, so the drone sits at the
            // bottom of its range and hums rather than falling silent — and
            // while the other plant is being touched, plant A holds there too,
            // with no special case for it.
            voice_a.render(piece, machine.a.deviation(), a_touched);

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

        if (log) |*l| l.flush(io);

        rendered += ms.block_frames;
        // The letters report what the voices were told, detection included, so
        // a line showing `A--` while a hand is on plant A is the arbitration
        // doing its job.
        status.observe(io, raw_a, raw_bc, machine.a.z, machine.bc.z, state, touch, &block, rendered);
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
///   * `a0` and `a1` are the two probes as the chip reported them, signed and
///     unrectified, and `z0` and `z1` are how many deviations from its own
///     rest each one is reading. `--touch-level` is the line those two scores
///     are held against. The name after them is the state the pair produced,
///     and `touch` is what each voice was told.
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
        z_a: f32,
        z_bc: f32,
        state: ms.touch.State,
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

        std.debug.print("t={d:.0}s a0={d} a1={d} z0={d:.1} z1={d:.1} {s} touch={s}\n", .{
            audio_s, raw_a, raw_bc, z_a, z_bc, @tagName(state), &touch,
        });
        self.peak = 0.0;
    }
};

/// The state a motion-driven or scripted run reports, so the demonstration
/// modes reach the voices through the same door the probes do.
fn stateFrom(touched: [ms.sensors.plant_count]bool) ms.touch.State {
    const bc = touched[1] or touched[2];
    if (touched[0] and bc) return .both;
    if (touched[0]) return .plant_a;
    if (bc) return .plant_bc;
    return .none;
}

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
        // Under `probes` nothing reads them at all.
        .probes, .always => {},
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
