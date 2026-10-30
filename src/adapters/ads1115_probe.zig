const std = @import("std");
const ads1115 = @import("ads1115.zig");
const ports = @import("../ports/root.zig");

pub const input_a: ads1115.Mux = .ain0_gnd;
pub const input_bc: ads1115.Mux = .ain1_gnd;

/// Both probes are converted once per this many frames: one audio block, so
/// the engine's first poll of every block gets fresh values and the rest of
/// the block reuses them. Two single-shot conversions cost about 2.5 ms of an
/// 11.6 ms block.
pub const refresh_frames: u64 = 512;

pub const Adapter = struct {
    adc: ads1115.Ads1115,
    frames_since_refresh: u64,
    raw_a: i16,
    raw_bc: i16,
    convert_op: *const fn (*Adapter, ads1115.Mux) ads1115.Error!i16,

    pub fn open(bus: [*:0]const u8, address: u16) ads1115.Error!Adapter {
        const adc = try ads1115.Ads1115.open(bus, address, .{ .mux = input_a });
        return .{
            .adc = adc,
            .frames_since_refresh = 0,
            .raw_a = 0,
            .raw_bc = 0,
            .convert_op = convertAdc,
        };
    }

    pub fn source(self: *Adapter) ports.ProbeSource {
        return .{
            .context = self,
            .read_fn = readFn,
            .deinit_fn = deinitFn,
        };
    }

    pub fn close(self: *Adapter) void {
        self.adc.close();
    }

    fn readFn(context: *anyopaque, frames: usize) ports.Reading {
        const self: *Adapter = @ptrCast(@alignCast(context));

        if (self.frames_since_refresh == 0) {
            // Each conversion names its own input and waits for its own
            // result, so a value can only land under the probe it came from.
            // A failed one keeps the last real value, so a bus glitch does not
            // turn into an audible zero.
            storeResult(self.convert_op(self, input_a), &self.raw_a);
            storeResult(self.convert_op(self, input_bc), &self.raw_bc);
        }

        self.frames_since_refresh += frames;
        if (self.frames_since_refresh >= refresh_frames) self.frames_since_refresh = 0;

        return .{ .raw_a = self.raw_a, .raw_bc = self.raw_bc };
    }

    fn convertAdc(self: *Adapter, mux: ads1115.Mux) ads1115.Error!i16 {
        return self.adc.convert(mux);
    }

    fn deinitFn(context: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.close();
    }
};

fn storeResult(result: ads1115.Error!i16, slot: *i16) void {
    if (result) |raw| slot.* = raw else |_| {}
}

fn testAdapter(convert_op: *const fn (*Adapter, ads1115.Mux) ads1115.Error!i16) Adapter {
    return .{
        .adc = undefined,
        .frames_since_refresh = 0,
        .raw_a = 0,
        .raw_bc = 0,
        .convert_op = convert_op,
    };
}

test "each probe gets the conversion taken on its own input" {
    // The fault this guards against: probe BC reporting probe A's value
    // because the read landed before the chip had converted the new input.
    var adapter = testAdapter(struct {
        fn convert(_: *Adapter, mux: ads1115.Mux) ads1115.Error!i16 {
            return switch (mux) {
                input_a => 1000,
                input_bc => 2000,
                else => unreachable,
            };
        }
    }.convert);

    var source_port = adapter.source();
    const reading = source_port.read(128);
    try std.testing.expectEqual(@as(i16, 1000), reading.raw_a);
    try std.testing.expectEqual(@as(i16, 2000), reading.raw_bc);
}

test "a failed conversion keeps that probe's last value and leaves the other alone" {
    const Fake = struct {
        var bc_fails = false;
        var a_value: i16 = 1000;

        fn convert(_: *Adapter, mux: ads1115.Mux) ads1115.Error!i16 {
            if (mux == input_bc and bc_fails) return ads1115.Error.ConversionTimeout;
            return if (mux == input_a) a_value else 2000;
        }
    };
    var adapter = testAdapter(Fake.convert);
    var source_port = adapter.source();

    _ = source_port.read(refresh_frames);
    Fake.bc_fails = true;
    Fake.a_value = 1500;
    const reading = source_port.read(refresh_frames);

    try std.testing.expectEqual(@as(i16, 1500), reading.raw_a);
    try std.testing.expectEqual(@as(i16, 2000), reading.raw_bc);
}

test "conversions run once per block, not once per poll" {
    const Counter = struct {
        var calls: u32 = 0;

        fn convert(_: *Adapter, _: ads1115.Mux) ads1115.Error!i16 {
            calls += 1;
            return 0;
        }
    };
    var adapter = testAdapter(Counter.convert);
    var source_port = adapter.source();

    // Two blocks of four 128-frame polls: two refreshes, two probes each.
    for (0..8) |_| _ = source_port.read(128);
    try std.testing.expectEqual(@as(u32, 4), Counter.calls);
}
