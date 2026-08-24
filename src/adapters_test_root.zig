// Keep the adapter module inside src so its relative core and port imports
// remain within the Zig module path when tested independently.
const adapters = @import("adapters/root.zig");

test {
    _ = adapters;
}
