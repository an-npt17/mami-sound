//! Loads an audio file into memory as mono f32 samples.
//!
//! Zig's standard library decodes no compressed audio formats, and the
//! installation's clips are Vorbis and MP3. Rather than vendor two decoders,
//! this shells out to ffmpeg once at startup and reads raw samples back — the
//! same trick the sink uses for playback. ffmpeg also handles the resampling
//! and stereo downmixing the source files need.
//!
//! Decoding happens before the audio loop starts, so this never runs while
//! sound is playing.

const std = @import("std");

/// Level every clip is normalized to, so a quiet recording and a loud one sit
/// at the same place in the mix.
const target_peak: f32 = 0.8;

pub const Error = error{
    FfmpegNotFound,
    FfmpegFailed,
    EmptyAudio,
} || std.mem.Allocator.Error;

/// Decode `path` to mono f32 at `sample_rate`, normalized to a fixed peak.
/// Caller owns the returned slice.
pub fn loadFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    sample_rate: u32,
) ![]f32 {
    var rate_buf: [16]u8 = undefined;
    const rate = try std.fmt.bufPrint(&rate_buf, "{d}", .{sample_rate});

    const result = std.process.run(gpa, io, .{
        .argv = &.{
            "ffmpeg",
            "-v",
            "error",
            "-i",
            path,
            "-f",
            "f32le",
            "-ac", "1", // downmix to mono
            "-ar", rate, // resample to the engine rate
            "-",
        },
        // A few minutes of audio at 4 bytes per sample.
        .stdout_limit = .limited(256 * 1024 * 1024),
        .reserve_amount = 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return Error.FfmpegNotFound,
        else => return err,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("ffmpeg failed on {s}:\n{s}\n", .{ path, result.stderr });
            return Error.FfmpegFailed;
        },
        else => return Error.FfmpegFailed,
    }

    const count = result.stdout.len / @sizeOf(f32);
    if (count == 0) return Error.EmptyAudio;

    // Copy rather than reinterpret: the byte slice is not f32-aligned.
    const samples = try gpa.alloc(f32, count);
    errdefer gpa.free(samples);
    @memcpy(std.mem.sliceAsBytes(samples), result.stdout[0 .. count * @sizeOf(f32)]);

    normalize(samples);
    return samples;
}

/// Scale so the loudest sample sits at `target_peak`. Silence is left alone.
pub fn normalize(samples: []f32) void {
    var peak: f32 = 0.0;
    for (samples) |s| peak = @max(peak, @abs(s));
    if (peak <= 0.0) return;

    const gain = target_peak / peak;
    for (samples) |*s| s.* *= gain;
}
