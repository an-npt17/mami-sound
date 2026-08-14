//! Wires the simulated sensors to the three voices and pipes the mix to aplay.

const std = @import("std");
const ms = @import("mami_sound");

/// Plant B's clip: a spoken interview.
const clip_b_path = "interview.ogg";
/// Plant C's clip: running water.
const clip_c_path = "waterfall.mp3";

/// Length of the sensor script. The loop keeps running past this until the
/// one-shot clips have finished, so nothing is cut off mid-playback. With real
/// sensors the script goes away and the loop becomes unbounded.
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

    var out = ms.sink.Sink.init(io, ms.sample_rate, ms.channels) catch |err| {
        std.debug.print(
            \\could not start aplay: {s}
            \\aplay comes from alsa-utils; run this inside `nix develop`.
            \\
        , .{@errorName(err)});
        return err;
    };

    var sens = ms.sensors.Sensors.init(ms.sample_rate, seed);
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
    var rendered: usize = 0;
    while (rendered < script_frames or voice_b.isPlaying() or voice_c.isPlaying()) {
        // Voices add into the block, so it starts from silence each time.
        @memset(&block, 0);

        const reading = sens.tick(ms.block_frames);
        // Disabled plants read as untouched, so their voices simply never open.
        const touch = ms.select.apply(sel, reading.touch);
        voice_a.render(&block, reading.ecg_volts, touch[0]);
        std.debug.print("ecg={d:.2}\n", .{reading.ecg_volts}); // TEST: for debugging the ECG sensor in comptime
        voice_b.render(&block, touch[1]);
        voice_c.render(&block, touch[2]);

        ms.sink.toPcm(&block, &pcm);
        // Blocks until aplay wants more, which is what paces the whole program.
        try out.write(&pcm);

        rendered += ms.block_frames;
    }

    try out.finish();
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
