const std = @import("std");

/// Somewhere for the raw readings to go while a rig is being measured.
///
/// Every threshold the steady model uses was chosen against a capture from a
/// different rig. This is the port that lets a room make its own, so the next
/// number comes from the probes it will actually run against.
pub const ProbeCapture = struct {
    context: *anyopaque,
    record_fn: *const fn (*anyopaque, i16, i16) void,

    pub fn record(self: *ProbeCapture, raw_a: i16, raw_bc: i16) void {
        self.record_fn(self.context, raw_a, raw_bc);
    }
};

test "the capture port forwards both probes" {
    const Context = struct {
        a: i16 = 0,
        bc: i16 = 0,
        fn record(context: *anyopaque, raw_a: i16, raw_bc: i16) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.a = raw_a;
            self.bc = raw_bc;
        }
    };
    var context = Context{};
    var port = ProbeCapture{ .context = &context, .record_fn = Context.record };
    port.record(660, -3);

    try std.testing.expectEqual(@as(i16, 660), context.a);
    try std.testing.expectEqual(@as(i16, -3), context.bc);
}
