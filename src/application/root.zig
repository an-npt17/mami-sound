const std = @import("std");

const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");
const engine = @import("engine.zig");
const production_config = @import("production_config.zig");

// Without this the application layer has no tests at all: the test roots reach
// it through this file, and an import alone does not pull a module's tests in.
test {
    _ = engine;
    _ = production_config;
    _ = core;
    _ = ports;
    _ = std;
}
