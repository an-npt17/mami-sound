// Keep the application module inside src so its relative core and port imports
// remain within the Zig module path when tested independently.
const application = @import("application/root.zig");

test {
    _ = application;
}
