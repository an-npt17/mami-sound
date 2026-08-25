const std = @import("std");

pub const ClipStream = struct {
    context: *anyopaque,
    render_fn: *const fn (*anyopaque, []f32, ?usize) void,

    pub fn render(self: *ClipStream, out: []f32, request: ?usize) void {
        self.render_fn(self.context, out, request);
    }
};

test "clip stream port forwards a render request" {
    const Context = struct {
        called: bool = false,
        fn render(context: *anyopaque, _: []f32, request: ?usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = request == 3;
        }
    };
    var context = Context{};
    var port = ClipStream{
        .context = &context,
        .render_fn = Context.render,
    };
    var block = [_]f32{0.0};
    port.render(&block, 3);
    try std.testing.expect(context.called);
}
