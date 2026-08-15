//! ADS1115 16-bit ADC over Linux i2c-dev.
//!
//! This is the real version of the ECG probe that `sensors.zig` otherwise
//! simulates. The chip is put in continuous-conversion mode once, at open, and
//! every later read is a two-byte fetch of the conversion register, so a read
//! costs one I2C transaction and never waits on the chip.
//!
//! Raw syscalls rather than `std.Io`: an I2C transfer must be exactly one
//! `write` and one `read` on the device node, with no buffering in between,
//! and the device address is set with an ioctl that has no `std` wrapper.

const std = @import("std");
const linux = std.os.linux;

/// The only I2C bus exposed on a Raspberry Pi header by default.
pub const default_bus = "/dev/i2c-1";

/// ADDR pin tied to GND. VDD gives 0x49, SDA 0x4a, SCL 0x4b.
pub const default_address: u16 = 0x48;

/// From <linux/i2c-dev.h>. Sets the slave address every later read/write on
/// this fd talks to.
const I2C_SLAVE: u32 = 0x0703;

/// Register pointers.
const reg_conversion: u8 = 0x00;
const reg_config: u8 = 0x01;

pub const Error = error{
    OpenFailed,
    AddressFailed,
    WriteFailed,
    ReadFailed,
};

/// Input multiplexer. The first four are differential pairs, the last four are
/// single-ended against GND.
pub const Mux = enum(u3) {
    ain0_ain1 = 0b000,
    ain0_ain3 = 0b001,
    ain1_ain3 = 0b010,
    ain2_ain3 = 0b011,
    ain0_gnd = 0b100,
    ain1_gnd = 0b101,
    ain2_gnd = 0b110,
    ain3_gnd = 0b111,
};

/// Programmable gain, named by the full-scale range it gives.
pub const Gain = enum(u3) {
    fs_6_144v = 0b000,
    fs_4_096v = 0b001,
    fs_2_048v = 0b010,
    fs_1_024v = 0b011,
    fs_0_512v = 0b100,
    fs_0_256v = 0b101,

    /// Volts at a raw reading of +32767.
    pub fn fullScale(self: Gain) f32 {
        return switch (self) {
            .fs_6_144v => 6.144,
            .fs_4_096v => 4.096,
            .fs_2_048v => 2.048,
            .fs_1_024v => 1.024,
            .fs_0_512v => 0.512,
            .fs_0_256v => 0.256,
        };
    }
};

/// Samples per second. Must stay at or above the block rate (~86 Hz for 512
/// frames at 44.1 kHz) or the same conversion is read twice.
pub const Rate = enum(u3) {
    sps_8 = 0b000,
    sps_16 = 0b001,
    sps_32 = 0b010,
    sps_64 = 0b011,
    sps_128 = 0b100,
    sps_250 = 0b101,
    sps_475 = 0b110,
    sps_860 = 0b111,
};

/// The defaults are what this installation's probe wants, not what the
/// reference C driver used.
///
/// The engine reads plant health as a slow 0-3.3 V level against ground, so the
/// input is single-ended, and the range has to cover the whole supply: at the C
/// driver's +/-2.048 V the ADC saturates at two thirds of the way up and every
/// healthy plant reads the same. +/-4.096 V is the smallest range that clears
/// 3.3 V. A differential probe wants `.ain0_ain1` back, and a mapping in
/// `sensors.zig` that expects negative volts.
pub const Config = struct {
    mux: Mux = .ain0_gnd,
    gain: Gain = .fs_4_096v,
    rate: Rate = .sps_128,
};

/// The 16-bit config register value: continuous conversion, comparator off.
///
/// Bit 15 (OS) is a one-shot trigger that is ignored in continuous mode; it is
/// set anyway so the same word also works if the mode bit is ever flipped.
pub fn configWord(cfg: Config) u16 {
    return (@as(u16, 1) << 15) |
        (@as(u16, @intFromEnum(cfg.mux)) << 12) |
        (@as(u16, @intFromEnum(cfg.gain)) << 9) |
        // bit 8 = 0: continuous conversion.
        (@as(u16, @intFromEnum(cfg.rate)) << 5) |
        // bits 4..2 default, bits 1..0 = 11: comparator disabled.
        0b11;
}

/// Convert a conversion-register reading to volts. Pure, so the scaling can be
/// tested without a chip on the bus.
pub fn voltsFromRaw(raw: i16, gain: Gain) f32 {
    return @as(f32, @floatFromInt(raw)) * gain.fullScale() / 32768.0;
}

pub const Ads1115 = struct {
    fd: linux.fd_t,
    gain: Gain,

    /// Open the bus, claim the address and write the config register.
    ///
    /// The first conversion is not ready for one sample period; a read before
    /// then returns whatever the chip powered up with, which is harmless here
    /// because the caller reads once per audio block forever after.
    pub fn open(bus: [*:0]const u8, address: u16, cfg: Config) Error!Ads1115 {
        const rc = linux.open(bus, .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(rc) != .SUCCESS) return Error.OpenFailed;
        const fd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);

        if (linux.errno(linux.ioctl(fd, I2C_SLAVE, address)) != .SUCCESS) {
            return Error.AddressFailed;
        }

        const word = configWord(cfg);
        const frame = [3]u8{ reg_config, @truncate(word >> 8), @truncate(word) };
        try writeAll(fd, &frame);

        return .{ .fd = fd, .gain = cfg.gain };
    }

    pub fn close(self: *Ads1115) void {
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    /// Point at the conversion register and read it, big-endian and signed.
    pub fn readRaw(self: *Ads1115) Error!i16 {
        try writeAll(self.fd, &[_]u8{reg_conversion});

        var data: [2]u8 = undefined;
        const rc = linux.read(self.fd, &data, data.len);
        if (linux.errno(rc) != .SUCCESS or rc != data.len) return Error.ReadFailed;

        return std.mem.readInt(i16, &data, .big);
    }

    pub fn readVolts(self: *Ads1115) Error!f32 {
        return voltsFromRaw(try self.readRaw(), self.gain);
    }
};

/// I2C has no partial transfers: a short write is a failed transaction, not a
/// reason to loop.
fn writeAll(fd: linux.fd_t, bytes: []const u8) Error!void {
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(rc) != .SUCCESS or rc != bytes.len) return Error.WriteFailed;
}

const testing = std.testing;

test "config word matches the reference C driver" {
    // AIN0-AIN1, +/-2.048 V, continuous, 128 SPS: 0x84, 0x83.
    try testing.expectEqual(
        @as(u16, 0x8483),
        configWord(.{ .mux = .ain0_ain1, .gain = .fs_2_048v }),
    );
}

test "the default config is single-ended and covers the supply" {
    // AIN0 against ground, +/-4.096 V, continuous, 128 SPS.
    try testing.expectEqual(@as(u16, 0xC283), configWord(.{}));
    const defaults: Config = .{};
    try testing.expect(defaults.gain.fullScale() > 3.3);
}

test "config word tracks each field" {
    try testing.expectEqual(
        @as(u16, 0xC683),
        configWord(.{ .mux = .ain0_gnd, .gain = .fs_1_024v }),
    );
    try testing.expectEqual(@as(u16, 0xC2E3), configWord(.{ .rate = .sps_860 }));
}

test "raw readings scale to volts" {
    try testing.expectEqual(@as(f32, 0.0), voltsFromRaw(0, .fs_2_048v));
    try testing.expectApproxEqAbs(
        @as(f32, 1.024),
        voltsFromRaw(16384, .fs_2_048v),
        0.001,
    );
    // Negative differentials stay negative; clamping is the caller's business.
    try testing.expectApproxEqAbs(
        @as(f32, -2.048),
        voltsFromRaw(-32768, .fs_2_048v),
        0.001,
    );
}
