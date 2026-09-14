const std = @import("std");

const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");
const engine = @import("engine.zig");
const voice = @import("voice.zig");
const production_config = @import("production_config.zig");
const boxes_preset = @import("boxes/preset.zig");
const boxes_defaults = @import("boxes/defaults.zig");
const boxes = @import("boxes/root.zig");

// Without this the application layer has no tests at all: the test roots reach
// it through this file, and an import alone does not pull a module's tests in.
test {
    _ = engine;
    _ = voice;
    _ = production_config;
    _ = core;
    _ = ports;
    _ = std;
    _ = boxes_preset;
    _ = boxes_defaults;
    _ = boxes;
}
