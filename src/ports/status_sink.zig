const plant = @import("../core/plant.zig");
const touch = @import("../core/touch.zig");

pub const Snapshot = struct {
    raw_a: i16,
    raw_bc: i16,
    z_a: f32,
    z_bc: f32,
    /// Where each probe was found to rest. Only the steady model learns one;
    /// the deviation model tracks its own and this is its median. Shown because
    /// a rest learned while somebody was holding a plant is the one failure
    /// that looks like nothing at all.
    rest_a: i16,
    rest_bc: i16,
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
