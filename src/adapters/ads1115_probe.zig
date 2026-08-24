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

    pub fn open(bus: [*:0]const u8, address: u16) ads1115.Error!Adapter {
        const adc = try ads1115.Ads1115.open(bus, address, .{ .mux = input_a });
        return .{
            .adc = adc,
            .selected = .a,
            .frames_since_switch = 0,
            .raw_a = 0,
            .raw_bc = 0,
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
        storeResult(self.adc.readRaw(), self.selected, &self.raw_a, &self.raw_bc);

        self.frames_since_switch += frames;
        if (self.frames_since_switch >= switch_frames) {
            const next = self.selected.other();
            if (self.adc.selectInput(next.mux())) |_| {
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
