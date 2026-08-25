//! ADS1115 16-bit ADC over Linux i2c-dev.
//!
//! This is the low-level driver used by the real ECG probe adapter. The chip is
//! put in continuous-conversion mode once, at open, and
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

/// Samples per second. Must stay at or above the rate the engine polls at, or
/// the same conversion is read twice and the extra polls buy nothing.
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
/// 3.3 V. A differential probe wants `.ain0_ain1` back, and the probe adapter
/// keeps negative counts instead of folding them to zero.
/// The rate is the fastest the chip offers, which is the only setting that
/// keeps up with a poll every 2.9 ms: at 128 SPS a reading can be 7.8 ms stale
/// and most polls see the same number twice. The cost is noise — the effective
/// resolution at 860 SPS is a few counts worse than at 8 — and that lands well
/// under the voices' one-second pitch smoothing.
pub const Config = struct {
    /// Named so callers can default to the same input without repeating it.
    pub const default_mux: Mux = .ain0_gnd;

    mux: Mux = default_mux,
    gain: Gain = .fs_4_096v,
    rate: Rate = .sps_860,
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

pub const Ads1115 = struct {
    fd: linux.fd_t,
    /// What was last written to the config register, so a mux change can rewrite
    /// it without the caller repeating the gain and rate.
    cfg: Config,

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

        try writeConfig(fd, cfg);

        return .{ .fd = fd, .cfg = cfg };
    }

    pub fn close(self: *Ads1115) void {
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    /// Point the multiplexer at another input.
    ///
    /// The chip has one converter, so reading two probes means switching
    /// between them. Writing the config register restarts conversion on the new
    /// input, and the conversion register holds the *old* input's last result
    /// until that finishes — one sample period, 1.2 ms at 860 SPS. So this
    /// returns immediately and never waits: it is the caller's business to read
    /// far enough after the switch, which the probe adapter does by holding the
    /// multiplexer still for a whole block, so the sink's blocking write falls
    /// between the switch and the next read.
    pub fn selectInput(self: *Ads1115, mux: Mux) Error!void {
        if (self.cfg.mux == mux) return;
        self.cfg.mux = mux;
        try writeConfig(self.fd, self.cfg);
    }

    /// Point at the conversion register and read it, big-endian and signed.
    ///
    /// The count is handed on as it comes off the chip. Scaling it to volts
    /// would only be undone by the pitch mapping, which works in fractions of
    /// full scale, so the gain is a hardware setting and not a factor anything
    /// multiplies by.
    ///
    /// Which input this reads is whatever `selectInput` last pointed at.
    pub fn readRaw(self: *Ads1115) Error!i16 {
        try writeAll(self.fd, &[_]u8{reg_conversion});

        var data: [2]u8 = undefined;
        const rc = linux.read(self.fd, &data, data.len);
        if (linux.errno(rc) != .SUCCESS or rc != data.len) return Error.ReadFailed;

        return std.mem.readInt(i16, &data, .big);
    }
};

fn writeConfig(fd: linux.fd_t, cfg: Config) Error!void {
    const word = configWord(cfg);
    try writeAll(fd, &[3]u8{ reg_config, @truncate(word >> 8), @truncate(word) });
}

/// I2C has no partial transfers: a short write is a failed transaction, not a
/// reason to loop.
fn writeAll(fd: linux.fd_t, bytes: []const u8) Error!void {
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(rc) != .SUCCESS or rc != bytes.len) return Error.WriteFailed;
}
