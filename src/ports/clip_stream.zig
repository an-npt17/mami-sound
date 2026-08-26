const std = @import("std");

pub const ClipStream = struct {
    context: *anyopaque,
    render_fn: *const fn (*anyopaque, []f32, ?usize) void,
    sounding_fn: *const fn (*anyopaque) bool,

    pub fn render(self: *ClipStream, out: []f32, request: ?usize) void {
        self.render_fn(self.context, out, request);
    }

    /// Whether a clip is still playing. What decides when a touch may cut in:
    /// the selector protects a clip that is sounding and lets a finished one go.
    pub fn sounding(self: *ClipStream) bool {
        return self.sounding_fn(self.context);
    }
};

test "clip stream port forwards a render request" {
    const Context = struct {
        called: bool = false,
        fn render(context: *anyopaque, _: []f32, request: ?usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = request == 3;
        }
        fn sounding(_: *anyopaque) bool {
            return false;
        }
    };
    var context = Context{};
    var port = ClipStream{
        .context = &context,
        .render_fn = Context.render,
        .sounding_fn = Context.sounding,
    };
    var block = [_]f32{0.0};
    port.render(&block, 3);
    try std.testing.expect(context.called);
}
