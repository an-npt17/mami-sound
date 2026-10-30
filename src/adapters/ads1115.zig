//! ADS1115 16-bit ADC over Linux i2c-dev.
//!
//! This is the low-level driver used by the real ECG probe adapter. Every
//! reading is a single-shot conversion: the config write names the input and
//! starts the conversion, the driver polls the status bit until the chip says
//! it is done, and only then fetches the conversion register. A reading can
//! therefore only ever come from the input that was asked for.
//!
//! This replaced continuous mode, where a mux switch leaves the *previous*
//! input's result in the conversion register for one sample period. Anything
//! that read inside that window filed probe A's value under probe BC, and the
//! window was only guarded by the audio sink happening to block in between.
//!
//! Both directions are checked. A register read is one combined transaction so
//! nothing can get between the pointer and the data, and a config write is read
//! back until the chip agrees with it -- I2C acknowledges a byte that arrived,
//! not a byte that arrived intact.
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

/// From <linux/i2c-dev.h>. Hands the driver a list of messages to run as one
/// transaction, which is the only way to get a repeated START out of this
/// interface.
const I2C_RDWR: u32 = 0x0707;

/// `I2C_M_RD`: this message is a read.
pub const flag_read: u16 = 0x0001;

/// `struct i2c_msg`. The layout is the kernel's and is asserted by a test.
pub const I2cMsg = extern struct {
    addr: u16,
    flags: u16,
    len: u16,
    buf: [*]u8,
};

/// `struct i2c_rdwr_ioctl_data`.
pub const I2cRdwr = extern struct {
    msgs: [*]I2cMsg,
    nmsgs: u32,
};

/// The two messages that read a register in a single transaction: write the
/// register pointer, then read the value, with a repeated START between them
/// and no STOP.
///
/// The ADS1115 wants exactly this. A separate `write` then `read` puts a STOP
/// and a fresh START between the pointer and the data, which leaves the chip
/// and any other master free to get in between -- and on a marginal bus it is
/// where a conversion read comes back with a corrupt high byte.
pub fn readMessages(address: u16, pointer: *[1]u8, data: *[2]u8) [2]I2cMsg {
    return .{
        .{ .addr = address, .flags = 0, .len = pointer.len, .buf = pointer },
        .{ .addr = address, .flags = flag_read, .len = data.len, .buf = data },
    };
}

/// Register pointers.
const reg_conversion: u8 = 0x00;
const reg_config: u8 = 0x01;

pub const Error = error{
    OpenFailed,
    AddressFailed,
    WriteFailed,
    ReadFailed,
    /// The driver cannot do combined transfers. Recoverable: the caller falls
    /// back to a separate write and read.
    Unsupported,
    /// The config register did not read back as written, after retries. The
    /// chip is on an input, gain or rate nobody asked for and the driver has
    /// no way to know which.
    ConfigUnverified,
    /// The status bit never reported a finished conversion within
    /// `conversion_polls` polls.
    ConversionTimeout,
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

/// How many times a config write is retried before it is called a fault.
///
/// A read-back can be corrupted as easily as a write on a marginal bus, so a
/// single mismatch is not proof of anything. Three is enough that agreement is
/// unlikely to be luck and few enough that a genuinely broken bus is reported
/// rather than retried forever.
const config_attempts: u32 = 3;

/// How many status polls a conversion gets before it is called a fault.
///
/// Each poll is a full I2C transaction (about 0.3 ms at 100 kHz, 75 us at
/// 400 kHz), so the bus itself paces the loop. 64 polls is at least ~5 ms even
/// on a fast bus, against a conversion of 1.16 ms at 860 SPS (+/-10% clock).
const conversion_polls: u32 = 64;

/// Bit 15 of the config register: written 1 it starts a single-shot
/// conversion; read back it is 0 while converting and 1 once done.
const status_bit: u16 = 0x8000;

/// Whether a config register read back matches what was written.
///
/// Bit 15 is the one-shot and status bit: it reads 1 while the chip is idle and
/// 0 mid-conversion, so it never comes back as written and is masked out.
/// Everything else must come back exactly -- the mux above all, because a mux
/// that landed wrong files every later reading under the wrong probe, and does
/// it silently.
pub fn configMatches(seen: u16, written: u16) bool {
    return (seen & ~status_bit) == (written & ~status_bit);
}

/// The 16-bit config register value: start a single-shot conversion,
/// comparator off.
pub fn configWord(cfg: Config) u16 {
    return status_bit |
        (@as(u16, @intFromEnum(cfg.mux)) << 12) |
        (@as(u16, @intFromEnum(cfg.gain)) << 9) |
        // bit 8 = 1: single-shot, power down after each conversion.
        (@as(u16, 1) << 8) |
        (@as(u16, @intFromEnum(cfg.rate)) << 5) |
        // bits 4..2 default, bits 1..0 = 11: comparator disabled.
        0b11;
}

pub const Ads1115 = struct {
    fd: linux.fd_t,
    /// Needed per message once reads go through `I2C_RDWR`, which addresses
    /// each message itself rather than inheriting the `I2C_SLAVE` setting.
    address: u16,
    /// Whether this driver does combined transfers. Cleared the first time the
    /// kernel says it cannot, and never set again: a bus that has no repeated
    /// START still works the old way, just less reliably.
    combined: bool,
    /// What was last written to the config register, so a conversion on
    /// another input can rewrite it without the caller repeating the gain and
    /// rate.
    cfg: Config,

    /// Open the bus, claim the address and write the config register.
    ///
    /// The write also starts one conversion nobody reads; that only proves the
    /// chip takes the config before the engine depends on it.
    pub fn open(bus: [*:0]const u8, address: u16, cfg: Config) Error!Ads1115 {
        const rc = linux.open(bus, .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(rc) != .SUCCESS) return Error.OpenFailed;
        const fd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);

        if (linux.errno(linux.ioctl(fd, I2C_SLAVE, address)) != .SUCCESS) {
            return Error.AddressFailed;
        }

        var chip: Ads1115 = .{ .fd = fd, .address = address, .combined = true, .cfg = cfg };
        try chip.writeConfig(cfg);

        return chip;
    }

    pub fn close(self: *Ads1115) void {
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    /// One fresh conversion on `mux`, waited for and returned.
    ///
    /// Blocks for one sample period (about 1.2 ms at 860 SPS) plus the bus
    /// traffic. The config write is verified before the wait, so the mux the
    /// result came from is known, not assumed. A failure at any step returns
    /// an error and no number: the caller keeps its last good reading rather
    /// than file a stale one under the wrong probe.
    pub fn convert(self: *Ads1115, mux: Mux) Error!i16 {
        var next = self.cfg;
        next.mux = mux;
        try self.writeConfig(next);
        self.cfg = next;

        try self.awaitConversion();
        return self.readRaw();
    }

    /// Poll the status bit until the conversion just started has finished.
    fn awaitConversion(self: *Ads1115) Error!void {
        var poll: u32 = 0;
        while (poll < conversion_polls) : (poll += 1) {
            // A failed poll is a bus glitch, not a finished conversion; it
            // spends one poll and the loop asks again.
            const seen = self.readRegister(reg_config) catch continue;
            if (seen & status_bit != 0) return;
        }
        return Error.ConversionTimeout;
    }

    /// Write the config register and read it back until the chip agrees.
    ///
    /// I2C acknowledges a byte that arrived, not a byte that arrived intact, so
    /// a write is not evidence that the chip took what was sent. On this rig it
    /// demonstrably does not always: probe A and probe BC were seen to swap
    /// wholesale mid-run and stay swapped, which is what a mux write landing
    /// wrong looks like from the outside.
    fn writeConfig(self: *Ads1115, cfg: Config) Error!void {
        const word = configWord(cfg);

        var attempt: u32 = 0;
        while (attempt < config_attempts) : (attempt += 1) {
            try writeAll(self.fd, &[3]u8{ reg_config, @truncate(word >> 8), @truncate(word) });

            // A read-back that itself fails is not proof the write was wrong,
            // so it spends an attempt rather than the whole budget.
            const seen = self.readRegister(reg_config) catch continue;
            if (configMatches(seen, word)) return;
        }

        return Error.ConfigUnverified;
    }

    /// One register, as an unsigned word. The conversion register is read
    /// signed by `readRaw`; the config register is a bit pattern.
    fn readRegister(self: *Ads1115, register: u8) Error!u16 {
        var data: [2]u8 = undefined;

        if (self.combined) {
            if (self.readCombined(register, &data)) |_| {
                return std.mem.readInt(u16, &data, .big);
            } else |err| switch (err) {
                Error.Unsupported => self.combined = false,
                else => return err,
            }
        }

        try writeAll(self.fd, &[_]u8{register});
        const rc = linux.read(self.fd, &data, data.len);
        if (linux.errno(rc) != .SUCCESS or rc != data.len) return Error.ReadFailed;

        return std.mem.readInt(u16, &data, .big);
    }

    /// Point at the conversion register and read it, big-endian and signed.
    ///
    /// The count is handed on as it comes off the chip. Scaling it to volts
    /// would only be undone by the pitch mapping, which works in fractions of
    /// full scale, so the gain is a hardware setting and not a factor anything
    /// multiplies by.
    ///
    /// Only meaningful straight after `awaitConversion`; `convert` is the
    /// public way in.
    fn readRaw(self: *Ads1115) Error!i16 {
        return @bitCast(try self.readRegister(reg_conversion));
    }

    /// Pointer write and value read as one transaction.
    fn readCombined(self: *Ads1115, register: u8, data: *[2]u8) Error!void {
        var pointer = [1]u8{register};
        var msgs = readMessages(self.address, &pointer, data);
        var request: I2cRdwr = .{ .msgs = &msgs, .nmsgs = msgs.len };

        const rc = linux.ioctl(self.fd, I2C_RDWR, @intFromPtr(&request));
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            // What a driver without `I2C_FUNC_I2C` answers. Not a bus fault.
            .NOTTY, .OPNOTSUPP, .NOSYS, .INVAL => return Error.Unsupported,
            else => return Error.ReadFailed,
        }
    }
};

/// I2C has no partial transfers: a short write is a failed transaction, not a
/// reason to loop.
fn writeAll(fd: linux.fd_t, bytes: []const u8) Error!void {
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(rc) != .SUCCESS or rc != bytes.len) return Error.WriteFailed;
}

test "a register read is one transaction: a write of the pointer, then a read" {
    var pointer = [1]u8{reg_conversion};
    var data = [2]u8{ 0, 0 };
    const msgs = readMessages(0x48, &pointer, &data);

    // Both halves are addressed to the same chip, and the pointer write has no
    // STOP after it -- that is the whole point of the pair.
    try std.testing.expectEqual(@as(u16, 0x48), msgs[0].addr);
    try std.testing.expectEqual(@as(u16, 0x48), msgs[1].addr);

    try std.testing.expectEqual(@as(u16, 0), msgs[0].flags);
    try std.testing.expectEqual(@as(u16, 1), msgs[0].len);
    try std.testing.expectEqual(@as([*]u8, &pointer), msgs[0].buf);

    try std.testing.expectEqual(flag_read, msgs[1].flags);
    try std.testing.expectEqual(@as(u16, 2), msgs[1].len);
    try std.testing.expectEqual(@as([*]u8, &data), msgs[1].buf);
}

test "the message struct matches the layout the kernel reads" {
    // Not decoration: a wrong offset here is a kernel reading a pointer out of
    // the padding, which fails as corrupt data rather than as an error.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(I2cMsg, "addr"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(I2cMsg, "flags"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(I2cMsg, "len"));
    try std.testing.expectEqual(@sizeOf(usize), @offsetOf(I2cMsg, "buf"));
}

test "a config register that reads back identically matches" {
    const word = configWord(.{ .mux = .ain0_ain1 });
    try std.testing.expect(configMatches(word, word));
}

test "the status bit is not part of the comparison" {
    // Bit 15 reads 1 while the chip is idle and 0 mid-conversion, so it never
    // comes back as written and would fail every check if it counted.
    const word = configWord(.{ .mux = .ain0_ain1 });
    try std.testing.expect(configMatches(word & 0x7FFF, word));
    try std.testing.expect(configMatches(word | 0x8000, word));
}

test "a mux that came back wrong does not match" {
    // The whole reason this exists. A config write corrupted on the wire leaves
    // the chip on an input nobody asked for, and every later reading is filed
    // under the wrong probe until another corrupted write flips it back.
    const asked = configWord(.{ .mux = .ain0_ain1 });
    const got = configWord(.{ .mux = .ain2_ain3 });
    try std.testing.expect(!configMatches(got, asked));
}

test "the config word starts a single-shot conversion" {
    const word = configWord(.{});
    // OS set: start converting. MODE set: single-shot, not continuous.
    try std.testing.expect(word & status_bit != 0);
    try std.testing.expect(word & 0x0100 != 0);
    // The default input is AIN0 against GND.
    try std.testing.expectEqual(@as(u16, 0b100), (word >> 12) & 0b111);
}

test "a gain or rate that came back wrong does not match" {
    const asked = configWord(.{ .mux = .ain0_ain1, .gain = .fs_4_096v, .rate = .sps_860 });
    try std.testing.expect(!configMatches(
        configWord(.{ .mux = .ain0_ain1, .gain = .fs_2_048v, .rate = .sps_860 }),
        asked,
    ));
    try std.testing.expect(!configMatches(
        configWord(.{ .mux = .ain0_ain1, .gain = .fs_4_096v, .rate = .sps_128 }),
        asked,
    ));
}
