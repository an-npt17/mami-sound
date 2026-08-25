const std = @import("std");
const ads1115 = @import("ads1115.zig");
const ports = @import("../ports/root.zig");

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
