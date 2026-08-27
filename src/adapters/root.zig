pub const ads1115 = @import("ads1115.zig");
pub const ads1115_probe = @import("ads1115_probe.zig");
pub const aplay_sink = @import("aplay_sink.zig");
pub const clip_heads = @import("clip_heads.zig");
pub const clip_loader = @import("clip_loader.zig");
pub const clip_ring = @import("clip_ring.zig");
pub const clip_stream = @import("clip_stream.zig");
pub const library = @import("library.zig");
pub const probe_capture = @import("probe_capture.zig");
pub const random_probe = @import("random_probe.zig");
pub const stderr_status = @import("stderr_status.zig");

test {
    _ = ads1115;
    _ = ads1115_probe;
    _ = aplay_sink;
    _ = clip_heads;
    _ = clip_loader;
    _ = clip_ring;
    _ = clip_stream;
    _ = library;
    _ = probe_capture;
    _ = random_probe;
    _ = stderr_status;
}
