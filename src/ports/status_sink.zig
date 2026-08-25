const plant = @import("../core/plant.zig");
const touch = @import("../core/touch.zig");

pub const Snapshot = struct {
    raw_a: i16,
    raw_bc: i16,
    z_a: f32,
    z_bc: f32,
    state: touch.State,
    touched: plant.Selection,
    block: []const f32,
    rendered: usize,
};

pub const StatusSink = struct {
    context: *anyopaque,
    observe_fn: *const fn (*anyopaque, Snapshot) void,

    pub fn observe(self: *StatusSink, snapshot: Snapshot) void {
        self.observe_fn(self.context, snapshot);
    }
};
