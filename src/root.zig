pub const core = @import("core/root.zig");
pub const application = @import("application/root.zig");
pub const ports = @import("ports/root.zig");

test {
    _ = core;
    _ = application;
    _ = ports;
}
