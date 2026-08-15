//! GPIO inputs through the Linux gpiochip character device.
//!
//! One motion sensor per plant: a PIR module holds its line high while it sees
//! movement, so a plant only speaks while someone is standing at it. That is
//! read exactly like the scripted touch it replaces, once per audio block.
//!
//! The v2 character-device uAPI rather than `/sys/class/gpio`: sysfs GPIO is
//! gone from current kernels. Requesting lines hands back one fd covering all
//! of them, so a poll of every plant is a single ioctl.

const std = @import("std");
const linux = std.os.linux;

/// BCM line offsets for plants A, B and C: header pins 11, 13 and 15 on a Pi
/// Zero 2 W. Chosen away from the pins with boot-time meaning (0-1 for the ID
/// EEPROM, 2-3 wired to the I2C the ADS1115 already uses, 14-15 for the UART).
pub const default_offsets = [_]u32{ 17, 27, 22 };

/// How many `/dev/gpiochipN` nodes `openDefault` will look at.
const max_chips = 8;

pub const Error = error{
    OpenFailed,
    RequestFailed,
    ReadFailed,
    TooManyLines,
    NoChip,
};

/// Internal pull on the input pin. PIR modules drive their output both ways,
/// so `.disabled` is right for them; a bare switch to ground wants `.pull_up`
/// plus `active_low`.
pub const Bias = enum {
    disabled,
    pull_up,
    pull_down,
};

pub const Config = struct {
    bias: Bias = .disabled,
    /// For sensors that idle high and pull low on trigger.
    active_low: bool = false,
    /// Kernel-side debounce. PIR modules already hold their output steady for
    /// seconds, so the default is off; a bare switch wants a few thousand.
    debounce_us: u32 = 0,
    /// Shown by `gpioinfo` as the owner of the line.
    consumer: []const u8 = "mami-sound",
};

// ---------------------------------------------------------------------------
// <linux/gpio.h>, v2 uAPI. Layouts are ABI, so they are asserted below rather
// than trusted.

const max_lines = 64;
const max_attrs = 10;
const name_size = 32;

const flag_active_low: u64 = 1 << 1;
const flag_input: u64 = 1 << 2;
const flag_bias_pull_up: u64 = 1 << 8;
const flag_bias_pull_down: u64 = 1 << 9;
const flag_bias_disabled: u64 = 1 << 10;

/// `id` of the debounce attribute.
const attr_id_debounce: u32 = 3;

const LineAttribute = extern struct {
    id: u32,
    padding: u32,
    value: extern union {
        flags: u64 align(8),
        values: u64 align(8),
        debounce_period_us: u32,
    },
};

const LineConfigAttribute = extern struct {
    attr: LineAttribute,
    mask: u64 align(8),
};

const LineConfig = extern struct {
    flags: u64 align(8),
    num_attrs: u32,
    padding: [5]u32,
    attrs: [max_attrs]LineConfigAttribute,
};

const LineRequest = extern struct {
    offsets: [max_lines]u32,
    consumer: [name_size]u8,
    config: LineConfig,
    num_lines: u32,
    event_buffer_size: u32,
    padding: [5]u32,
    fd: i32,
};

const LineValues = extern struct {
    bits: u64 align(8),
    mask: u64 align(8),
};

const ChipInfo = extern struct {
    name: [name_size]u8,
    label: [name_size]u8,
    lines: u32,
};

comptime {
    std.debug.assert(@sizeOf(LineAttribute) == 16);
    std.debug.assert(@sizeOf(LineConfigAttribute) == 24);
    std.debug.assert(@sizeOf(LineConfig) == 272);
    std.debug.assert(@sizeOf(LineRequest) == 592);
    std.debug.assert(@sizeOf(LineValues) == 16);
    std.debug.assert(@sizeOf(ChipInfo) == 68);
}

/// `_IOWR` and `_IOR` from <asm-generic/ioctl.h>: direction, then the size of
/// the argument, the driver's magic number and the call number.
fn iowr(comptime magic: u8, comptime nr: u8, comptime T: type) u32 {
    return (3 << 30) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, magic) << 8) | nr;
}

fn ior(comptime magic: u8, comptime nr: u8, comptime T: type) u32 {
    return (2 << 30) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, magic) << 8) | nr;
}

const GPIO_GET_CHIPINFO_IOCTL = ior(0xB4, 0x01, ChipInfo);
const GPIO_V2_GET_LINE_IOCTL = iowr(0xB4, 0x07, LineRequest);
const GPIO_V2_LINE_GET_VALUES_IOCTL = iowr(0xB4, 0x0E, LineValues);

// ---------------------------------------------------------------------------

/// A set of input lines requested together and read together.
pub const Lines = struct {
    /// The request fd, not the chip fd. Closing it releases every line.
    fd: linux.fd_t,
    count: usize,

    /// Request `offsets` from the SoC's own GPIO controller, whichever
    /// `/dev/gpiochipN` that turns out to be.
    ///
    /// The number is not stable: a Pi Zero 2 W exposes the header on
    /// `gpiochip0` next to a two-line virtual chip for the activity LED, and
    /// which one comes first has moved between kernel releases. Finding the
    /// chip by what it says it is costs one ioctl at startup and never has to
    /// be revisited on a new image.
    pub fn openDefault(offsets: []const u32, cfg: Config) Error!Lines {
        var path_buf: [32:0]u8 = undefined;
        for (0..max_chips) |i| {
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/gpiochip{d}", .{i}) catch
                unreachable;

            const rc = linux.open(path.ptr, .{ .ACCMODE = .RDWR }, 0);
            // A gap in the numbering is not the end of the search: the node may
            // simply not exist, or belong to root on a machine where a later
            // one does not.
            if (linux.errno(rc) != .SUCCESS) continue;
            const chip: linux.fd_t = @intCast(rc);

            var info: ChipInfo = undefined;
            const ok = linux.errno(linux.ioctl(
                chip,
                GPIO_GET_CHIPINFO_IOCTL,
                @intFromPtr(&info),
            )) == .SUCCESS;

            if (ok and isHeaderChip(&info)) {
                defer _ = linux.close(chip);
                return requestOn(chip, offsets, cfg);
            }
            _ = linux.close(chip);
        }
        return Error.NoChip;
    }

    pub fn open(chip_path: [*:0]const u8, offsets: []const u32, cfg: Config) Error!Lines {
        const rc = linux.open(chip_path, .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(rc) != .SUCCESS) return Error.OpenFailed;
        const chip: linux.fd_t = @intCast(rc);
        // The request fd carries its own reference to the chip, so the chip fd
        // is not needed past this function either way.
        defer _ = linux.close(chip);

        return requestOn(chip, offsets, cfg);
    }

    fn requestOn(chip: linux.fd_t, offsets: []const u32, cfg: Config) Error!Lines {
        if (offsets.len == 0 or offsets.len > max_lines) return Error.TooManyLines;

        var req = std.mem.zeroes(LineRequest);
        for (offsets, 0..) |offset, i| req.offsets[i] = offset;
        req.num_lines = @intCast(offsets.len);

        const name_len = @min(cfg.consumer.len, name_size - 1);
        @memcpy(req.consumer[0..name_len], cfg.consumer[0..name_len]);

        req.config.flags = flag_input | switch (cfg.bias) {
            .disabled => flag_bias_disabled,
            .pull_up => flag_bias_pull_up,
            .pull_down => flag_bias_pull_down,
        };
        if (cfg.active_low) req.config.flags |= flag_active_low;

        if (cfg.debounce_us != 0) {
            req.config.num_attrs = 1;
            req.config.attrs[0] = .{
                .attr = .{
                    .id = attr_id_debounce,
                    .padding = 0,
                    .value = .{ .debounce_period_us = cfg.debounce_us },
                },
                .mask = maskOf(offsets.len),
            };
        }

        if (linux.errno(linux.ioctl(chip, GPIO_V2_GET_LINE_IOCTL, @intFromPtr(&req))) != .SUCCESS) {
            return Error.RequestFailed;
        }

        return .{ .fd = req.fd, .count = offsets.len };
    }

    pub fn close(self: *Lines) void {
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    /// One ioctl for every line. Bit `i` is the line at `offsets[i]`, already
    /// corrected for `active_low` by the kernel.
    pub fn readBits(self: *Lines) Error!u64 {
        var values: LineValues = .{ .bits = 0, .mask = maskOf(self.count) };
        const rc = linux.ioctl(self.fd, GPIO_V2_LINE_GET_VALUES_IOCTL, @intFromPtr(&values));
        if (linux.errno(rc) != .SUCCESS) return Error.ReadFailed;
        return values.bits;
    }

    /// Fill `out` with one bool per requested line.
    pub fn read(self: *Lines, out: []bool) Error!void {
        std.debug.assert(out.len == self.count);
        unpack(try self.readBits(), out);
    }
};

/// Is this the controller the 40-pin header is wired to?
///
/// Every Pi names it `pinctrl-` something: `pinctrl-bcm2835` on a Zero 2 W and
/// the older boards, `pinctrl-bcm2711` on a Pi 4, `pinctrl-rp1` on a Pi 5. The
/// line count rules out the small virtual chips, which have a handful of lines
/// for the activity LED and the power button.
fn isHeaderChip(info: *const ChipInfo) bool {
    const label = std.mem.sliceTo(&info.label, 0);
    return info.lines >= 32 and std.mem.startsWith(u8, label, "pinctrl-");
}

/// A set bit per requested line. `count` is at most 64, so the shift cannot
/// overflow, but 64 itself would, hence the branch.
fn maskOf(count: usize) u64 {
    if (count >= 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(count)) - 1;
}

/// Spread a bitmask over a bool per line. Pure, so the decoding is testable
/// without a chip.
pub fn unpack(bits: u64, out: []bool) void {
    for (out, 0..) |*line, i| line.* = (bits >> @intCast(i)) & 1 == 1;
}

const testing = std.testing;

test "mask covers exactly the requested lines" {
    try testing.expectEqual(@as(u64, 0b1), maskOf(1));
    try testing.expectEqual(@as(u64, 0b111), maskOf(3));
    try testing.expectEqual(std.math.maxInt(u64), maskOf(64));
}

test "ioctl numbers match <linux/gpio.h>" {
    try testing.expectEqual(@as(u32, 0x8044B401), GPIO_GET_CHIPINFO_IOCTL);
    try testing.expectEqual(@as(u32, 0xC250B407), GPIO_V2_GET_LINE_IOCTL);
    try testing.expectEqual(@as(u32, 0xC010B40E), GPIO_V2_LINE_GET_VALUES_IOCTL);
}

test "the header chip is told apart from the virtual ones" {
    const chipInfo = struct {
        fn make(label: []const u8, lines: u32) ChipInfo {
            var info = std.mem.zeroes(ChipInfo);
            @memcpy(info.label[0..label.len], label);
            info.lines = lines;
            return info;
        }
    }.make;

    // A Pi Zero 2 W, and the boards either side of it.
    try testing.expect(isHeaderChip(&chipInfo("pinctrl-bcm2835", 54)));
    try testing.expect(isHeaderChip(&chipInfo("pinctrl-bcm2711", 58)));
    try testing.expect(isHeaderChip(&chipInfo("pinctrl-rp1", 54)));
    // The activity LED and the firmware's own expander are not it.
    try testing.expect(!isHeaderChip(&chipInfo("brcmvirt-gpio", 2)));
    try testing.expect(!isHeaderChip(&chipInfo("raspberrypi-exp-gpio", 8)));
}

test "bits unpack in line order" {
    var out: [3]bool = undefined;
    unpack(0b101, &out);
    try testing.expectEqual([3]bool{ true, false, true }, out);
    unpack(0, &out);
    try testing.expectEqual([3]bool{ false, false, false }, out);
    // Lines past the ones requested are ignored by the caller's slice length.
    unpack(0b1000, &out);
    try testing.expectEqual([3]bool{ false, false, false }, out);
}
