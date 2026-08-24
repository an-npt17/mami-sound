pub const Reading = struct {
    raw_a: i16,
    raw_bc: i16,
};

pub const ProbeSource = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, usize) Reading,
    deinit_fn: *const fn (*anyopaque) void,

    pub fn read(self: *ProbeSource, frames: usize) Reading {
        return self.read_fn(self.context, frames);
    }

    pub fn deinit(self: *ProbeSource) void {
        self.deinit_fn(self.context);
    }
};
