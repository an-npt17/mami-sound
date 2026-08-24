const std = @import("std");
const ads1115 = @import("ads1115.zig");
const ports = @import("../ports/root.zig");

const testing = std.testing;

pub const input_a: ads1115.Mux = .ain0_ain1;
pub const input_bc: ads1115.Mux = .ain2_ain3;
pub const switch_frames: u64 = 512;

const Probe = enum {
    a,
    bc,

    fn mux(self: Probe) ads1115.Mux {
        return switch (self) {
            .a => input_a,
            .bc => input_bc,
        };
    }

    fn other(self: Probe) Probe {
        return switch (self) {
            .a => .bc,
            .bc => .a,
        };
    }
};

pub const Adapter = struct {
    adc: ads1115.Ads1115,
    selected: Probe,
    frames_since_switch: u64,
    raw_a: i16,
    raw_bc: i16,
    io_context: *anyopaque,
    read_op: *const fn (*Adapter) ads1115.Error!i16,
    select_op: *const fn (*Adapter, ads1115.Mux) ads1115.Error!void,

    pub fn open(bus: [*:0]const u8, address: u16) ads1115.Error!Adapter {
        const adc = try ads1115.Ads1115.open(bus, address, .{ .mux = input_a });
        return .{
            .adc = adc,
            .selected = .a,
            .frames_since_switch = 0,
            .raw_a = 0,
            .raw_bc = 0,
            .io_context = undefined,
            .read_op = readAdc,
            .select_op = selectAdc,
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

        // A failed ADC read keeps the last real value, so a bus glitch does not
        // turn into an audible zero or move the value to the wrong probe.
        storeResult(self.read_op(self), self.selected, &self.raw_a, &self.raw_bc);

        self.frames_since_switch += frames;
        if (self.frames_since_switch >= switch_frames) {
            const next = self.selected.other();
            if (self.select_op(self, next.mux())) |_| {
                advanceTiming(&self.selected, &self.frames_since_switch, 0, true);
            } else |_| {
                // The low-level driver caches the requested mux before the
                // write. Restore the real selection so a retry does not
                // mistake a failed write for a successful switch.
                self.adc.cfg.mux = self.selected.mux();
            }
        }

        return .{ .raw_a = self.raw_a, .raw_bc = self.raw_bc };
    }

    fn readAdc(self: *Adapter) ads1115.Error!i16 {
        return self.adc.readRaw();
    }

    fn selectAdc(self: *Adapter, mux: ads1115.Mux) ads1115.Error!void {
        return self.adc.selectInput(mux);
    }

    fn deinitFn(context: *anyopaque) void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        self.close();
    }
};

fn advanceTiming(selected: *Probe, frames_since_switch: *u64, frames: usize, switched: bool) void {
    frames_since_switch.* += frames;
    if (frames_since_switch.* < switch_frames or !switched) return;
    selected.* = selected.*.other();
    frames_since_switch.* = 0;
}

fn storeReading(selected: Probe, raw: i16, raw_a: *i16, raw_bc: *i16) void {
    switch (selected) {
        .a => raw_a.* = raw,
        .bc => raw_bc.* = raw,
    }
}

fn storeResult(result: ads1115.Error!i16, selected: Probe, raw_a: *i16, raw_bc: *i16) void {
    if (result) |raw| {
        storeReading(selected, raw, raw_a, raw_bc);
    } else |_| {}
}

test "the probe inputs are the two non-overlapping differential pairs" {
    try testing.expectEqual(ads1115.Mux.ain0_ain1, input_a);
    try testing.expectEqual(ads1115.Mux.ain2_ain3, input_bc);
    try testing.expect(input_a != input_bc);
}

const FakeAdc = struct {
    reads: []const ads1115.Error!i16,
    next_read: usize = 0,
    selections: [1]ads1115.Mux = undefined,
    selection_count: usize = 0,
    fail_switch: bool = false,

    fn read(adapter: *Adapter) ads1115.Error!i16 {
        const self: *FakeAdc = @ptrCast(@alignCast(adapter.io_context));
        const result = self.reads[self.next_read];
        self.next_read += 1;
        return result;
    }

    fn select(adapter: *Adapter, mux: ads1115.Mux) ads1115.Error!void {
        const self: *FakeAdc = @ptrCast(@alignCast(adapter.io_context));
        self.selections[self.selection_count] = mux;
        self.selection_count += 1;
        adapter.adc.cfg.mux = mux;
        if (self.fail_switch) return error.WriteFailed;
    }
};

fn testAdapter(fake: *FakeAdc) Adapter {
    return .{
        .adc = .{ .fd = -1, .cfg = .{ .mux = input_a } },
        .selected = .a,
        .frames_since_switch = 0,
        .raw_a = 0,
        .raw_bc = 0,
        .io_context = fake,
        .read_op = FakeAdc.read,
        .select_op = FakeAdc.select,
    };
}

test "a partial source read keeps A selected" {
    const reads = [_]ads1115.Error!i16{ -10 };
    var fake = FakeAdc{ .reads = &reads };
    var adapter = testAdapter(&fake);
    var source = adapter.source();

    try testing.expectEqual(
        ports.Reading{ .raw_a = -10, .raw_bc = 0 },
        source.read(128),
    );
    try testing.expectEqual(Probe.a, adapter.selected);
    try testing.expectEqual(@as(u64, 128), adapter.frames_since_switch);
    try testing.expectEqual(@as(usize, 0), fake.selection_count);
}

test "a full source read switches A to BC" {
    const reads = [_]ads1115.Error!i16{ -10 };
    var fake = FakeAdc{ .reads = &reads };
    var adapter = testAdapter(&fake);
    var source = adapter.source();

    _ = source.read(512);

    try testing.expectEqual(Probe.bc, adapter.selected);
    try testing.expectEqual(@as(u64, 0), adapter.frames_since_switch);
    try testing.expectEqual(input_bc, adapter.adc.cfg.mux);
    try testing.expectEqual(@as(usize, 1), fake.selection_count);
    try testing.expectEqual(input_bc, fake.selections[0]);
}

test "a failed source read preserves both last-real values" {
    const reads = [_]ads1115.Error!i16{ -10, 20, error.ReadFailed };
    var fake = FakeAdc{ .reads = &reads };
    var adapter = testAdapter(&fake);
    var source = adapter.source();

    _ = source.read(512);
    _ = source.read(128);
    const reading = source.read(128);

    try testing.expectEqual(@as(i16, -10), reading.raw_a);
    try testing.expectEqual(@as(i16, 20), reading.raw_bc);
}

test "a failed source switch preserves selection timing and cached mux" {
    const reads = [_]ads1115.Error!i16{ -10 };
    var fake = FakeAdc{ .reads = &reads, .fail_switch = true };
    var adapter = testAdapter(&fake);
    var source = adapter.source();

    _ = source.read(512);

    try testing.expectEqual(Probe.a, adapter.selected);
    try testing.expectEqual(@as(u64, 512), adapter.frames_since_switch);
    try testing.expectEqual(input_a, adapter.adc.cfg.mux);
    try testing.expectEqual(@as(usize, 1), fake.selection_count);
    try testing.expectEqual(input_bc, fake.selections[0]);
}

test "the adapter steps between the two probe inputs" {
    try testing.expectEqual(Probe.bc, Probe.a.other());
    try testing.expectEqual(Probe.a, Probe.bc.other());
    try testing.expectEqual(input_a, Probe.a.mux());
    try testing.expectEqual(input_bc, Probe.bc.mux());
}

test "the default and probe config words preserve gain and rate" {
    try testing.expectEqual(@as(u16, 0xC2E3), ads1115.configWord(.{}));
    try testing.expectEqual(@as(u16, 0x82E3), ads1115.configWord(.{ .mux = input_a }));
    try testing.expectEqual(@as(u16, 0xB2E3), ads1115.configWord(.{ .mux = input_bc }));
}

test "the adapter holds a mux for a partial block and switches at a full block" {
    var selected: Probe = .a;
    var frames_since_switch: u64 = 0;

    advanceTiming(&selected, &frames_since_switch, 128, true);
    try testing.expectEqual(Probe.a, selected);
    try testing.expectEqual(@as(u64, 128), frames_since_switch);

    advanceTiming(&selected, &frames_since_switch, 384, true);
    try testing.expectEqual(Probe.bc, selected);
    try testing.expectEqual(@as(u64, 0), frames_since_switch);
}

test "a failed mux switch leaves the selected probe and elapsed block state" {
    var selected: Probe = .a;
    var frames_since_switch: u64 = 0;

    advanceTiming(&selected, &frames_since_switch, 512, false);

    try testing.expectEqual(Probe.a, selected);
    try testing.expectEqual(@as(u64, 512), frames_since_switch);
}

test "a successful reading updates only its selected probe" {
    var raw_a: i16 = -100;
    var raw_bc: i16 = 200;

    storeReading(.a, -10, &raw_a, &raw_bc);
    try testing.expectEqual(@as(i16, -10), raw_a);
    try testing.expectEqual(@as(i16, 200), raw_bc);

    storeReading(.bc, 20, &raw_a, &raw_bc);
    try testing.expectEqual(@as(i16, -10), raw_a);
    try testing.expectEqual(@as(i16, 20), raw_bc);
}

test "a failed reading holds both last real values" {
    var raw_a: i16 = -10;
    var raw_bc: i16 = 20;

    storeResult(error.ReadFailed, .a, &raw_a, &raw_bc);
    storeResult(error.ReadFailed, .bc, &raw_a, &raw_bc);

    try testing.expectEqual(@as(i16, -10), raw_a);
    try testing.expectEqual(@as(i16, 20), raw_bc);
}

test "a full mux block is longer than one ADC conversion" {
    const conversion_ms = 1000.0 / 860.0;
    const held_ms = @as(f32, @floatFromInt(switch_frames)) / 44100.0 * 1000.0;
    try testing.expect(held_ms > conversion_ms);
    try testing.expect(held_ms > conversion_ms * 5.0);
}
