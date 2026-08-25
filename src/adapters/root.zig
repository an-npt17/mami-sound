pub const ads1115 = @import("ads1115.zig");
pub const ads1115_probe = @import("ads1115_probe.zig");
pub const aplay_sink = @import("aplay_sink.zig");
pub const clip_loader = @import("clip_loader.zig");
pub const clip_stream = @import("clip_stream.zig");
pub const decode = @import("decode.zig");
pub const library = @import("library.zig");
pub const random_probe = @import("random_probe.zig");
pub const stderr_status = @import("stderr_status.zig");

test {
    _ = ads1115;
    _ = ads1115_probe;
    _ = aplay_sink;
    _ = clip_loader;
    _ = clip_stream;
    _ = decode;
    _ = library;
    _ = random_probe;
    _ = stderr_status;
}
