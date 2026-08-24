// Keep this test root under src so every adapter, port, and core relative import
// remains inside the Zig module path when invoked directly.
const adapters = @import("adapters/root.zig");
const core = @import("core/root.zig");
const ports = @import("ports/root.zig");

test {
    _ = adapters;
    _ = core;
    _ = ports;
}
