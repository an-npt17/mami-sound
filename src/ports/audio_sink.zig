pub const AudioSink = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, []const i16) anyerror!void,
    finish_fn: *const fn (*anyopaque) anyerror!void,

    pub fn write(self: *AudioSink, frames: []const i16) !void {
        return self.write_fn(self.context, frames);
    }

    pub fn finish(self: *AudioSink) !void {
        return self.finish_fn(self.context);
    }
};
