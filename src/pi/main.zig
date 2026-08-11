const std = @import("std");
const builtin = @import("builtin");
const plant = @import("plant");

const Options = struct {
    channel: u5 = 0,
    rate_ms: u32 = 200,
    host: []const u8 = "127.0.0.1",
    port: u16 = plant.net.default_port,
    source: enum { spi, stdin } = .spi,
    /// Second MCP3008 channel carrying the vibration sensor. Off by default so a
    /// one-sensor rig keeps working unchanged.
    vib_channel: ?u5 = null,
};

const spi_dev = "/dev/spidev0.0";

// Matches the kernel `struct spi_ioc_transfer` (include/uapi/linux/spi/spidev.h).
const SpiIocTransfer = extern struct {
    tx_buf: u64,
    rx_buf: u64,
    len: u32,
    speed_hz: u32,
    delay_usecs: u16,
    bits_per_word: u8,
    cs_change: u8,
    tx_nbits: u8,
    rx_nbits: u8,
    word_delay_usecs: u8,
    pad: u8,
};

// SPI_IOC_MESSAGE(1) = _IOW('k', 0, char[32]) per the kernel uapi: WRITE
// direction (bit 30 = 1), size 32 (bits 16-29), type 'k' (bits 8-15), nr 0.
const SPI_IOC_MESSAGE_1: u32 = (1 << 30) | (32 << 16) | ('k' << 8) | 0;

fn readMcp3008(fd: std.posix.fd_t, channel: u5) !u16 {
    var tx: [3]u8 = .{ 0x01, 0x80 | (@as(u8, channel) << 4), 0x00 };
    var rx: [3]u8 = .{ 0, 0, 0 };
    const transfer = SpiIocTransfer{
        .tx_buf = @intFromPtr(&tx),
        .rx_buf = @intFromPtr(&rx),
        .len = 3,
        .speed_hz = 100000,
        .delay_usecs = 0,
        .bits_per_word = 0,
        .cs_change = 0,
        .tx_nbits = 0,
        .rx_nbits = 0,
        .word_delay_usecs = 0,
        .pad = 0,
    };
    const rc = std.os.linux.ioctl(fd, SPI_IOC_MESSAGE_1, @intFromPtr(&transfer));
    if (std.os.linux.errno(rc) != .SUCCESS) {
        return error.SpiTransferFailed;
    }
    const raw: u16 = (@as(u16, rx[1] & 0x03) << 8) | rx[2];
    return @intFromFloat(@as(f32, @floatFromInt(raw)) / 1023.0 * 65535.0);
}

fn usage(w: *std.Io.Writer) void {
    w.print(
        \\sensor-pi - read MCP3008 ADC on a Raspberry Pi, stream over UDP
        \\
        \\usage: sensor-pi [options]
        \\  --channel N          MCP3008 channel 0..7 (default: 0)
        \\  --rate MS            read interval in ms (default: 200)
        \\  --host H             UDP destination host (default: 127.0.0.1)
        \\  --port N             UDP destination port (default: 9090)
        \\  --source spi|stdin   spi = /dev/spidev0.0, stdin = one int per line
        \\  --vib-channel N      MCP3008 channel for the vibration sensor (default: off)
        \\  -h, --help           show this help
        \\
    , .{}) catch {};
}

fn parseArgs(args: []const []const u8) !Options {
    var o = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return error.HelpRequested;
        var it = a;
        if (std.mem.startsWith(u8, a, "--")) it = a[2..];
        const eq = std.mem.indexOfScalar(u8, it, '=');
        const name = if (eq) |e| it[0..e] else it;
        const val = if (eq) |e| it[e + 1 ..] else if (i + 1 < args.len) blk: {
            i += 1;
            break :blk args[i];
        } else return error.MissingValue;
        if (std.mem.eql(u8, name, "channel")) {
            o.channel = try std.fmt.parseInt(u5, val, 10);
            if (o.channel > 7) return error.BadChannel;
        } else if (std.mem.eql(u8, name, "rate")) {
            o.rate_ms = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, name, "host")) {
            o.host = val;
        } else if (std.mem.eql(u8, name, "port")) {
            o.port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, name, "vib-channel")) {
            const c = try std.fmt.parseInt(u5, val, 10);
            if (c > 7) return error.BadChannel;
            o.vib_channel = c;
        } else if (std.mem.eql(u8, name, "source")) {
            if (std.mem.eql(u8, val, "spi")) o.source = .spi else if (std.mem.eql(u8, val, "stdin")) o.source = .stdin else return error.BadSource;
        } else {
            std.debug.print("unknown option: {s}\n", .{a});
            return error.BadArg;
        }
    }
    return o;
}

// Raw fd reads on a pipe can return several lines at once, so keep a
// persistent buffer across reads and split on '\n', holding any remainder
// for the next call.
const StdinSource = struct {
    buf: [64]u8 = undefined,
    n: usize = 0,
    start: usize = 0,

    fn next(self: *StdinSource) !u16 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.buf[self.start..self.n], '\n')) |nl| {
                const line = std.mem.trim(u8, self.buf[self.start .. self.start + nl], " \t\r\n");
                self.start += nl + 1;
                return std.fmt.parseInt(u16, line, 10);
            }
            if (self.start > 0) {
                const remaining = self.n - self.start;
                std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.start..self.n]);
                self.n = remaining;
                self.start = 0;
            }
            if (self.n == self.buf.len) return error.LineTooLong;
            const got = try std.posix.read(std.posix.STDIN_FILENO, self.buf[self.n..]);
            if (got == 0) {
                if (self.n == 0) return error.Eof;
                const line = std.mem.trim(u8, self.buf[self.start..self.n], " \t\r\n");
                self.n = 0;
                self.start = 0;
                return std.fmt.parseInt(u16, line, 10);
            }
            self.n += got;
        }
    }
};

fn nextValue(spi_fd: ?std.posix.fd_t, stdin_src: ?*StdinSource, opts: Options) !u16 {
    switch (opts.source) {
        .spi => return readMcp3008(spi_fd.?, opts.channel),
        .stdin => return stdin_src.?.next(),
    }
}

// std.net.Address.parseIp is gone in 0.16; IPv4-only dotted quad is enough.
fn parseHost(host: []const u8) !u32 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (it.next()) |oct| : (i += 1) {
        if (i >= 4) return error.BadHost;
        octets[i] = try std.fmt.parseInt(u8, oct, 10);
    }
    if (i != 4) return error.BadHost;
    return (@as(u32, octets[0]) << 24) | (@as(u32, octets[1]) << 16) | (@as(u32, octets[2]) << 8) | octets[3];
}

const sockaddr_in = extern struct {
    family: u16,
    port: u16,
    addr: u32,
    zero: [8]u8,
};

fn printUsage(file: std.Io.File, io: std.Io) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = .init(file, io, &buf);
    usage(&w.interface);
    w.interface.flush() catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const opts = parseArgs(args) catch |e| switch (e) {
        error.HelpRequested => {
            printUsage(std.Io.File.stdout(), io);
            return;
        },
        else => {
            printUsage(std.Io.File.stderr(), io);
            return error.InvalidArgs;
        },
    };

    var spi_fd: ?std.posix.fd_t = null;
    defer {
        if (spi_fd) |fd| _ = std.os.linux.close(fd);
    }
    if (opts.source == .spi) {
        if (builtin.os.tag != .linux) {
            std.debug.print("error: SPI source requires Linux\n", .{});
            return error.NotSupported;
        }
        // openFileAbsolute is gone in 0.16; open relative to the cwd dir fd.
        const fd = std.posix.openat(std.posix.AT.FDCWD, spi_dev, .{ .ACCMODE = .RDWR }, 0) catch |e| {
            std.debug.print("error: cannot open {s}: {s}\n", .{ spi_dev, @errorName(e) });
            std.debug.print("enable SPI: sudo raspi-config -> Interface Options -> SPI -> Yes, then reboot\n", .{});
            return error.SpiUnavailable;
        };
        spi_fd = fd;
    }

    const dst_addr = sockaddr_in{
        .family = @intCast(std.os.linux.AF.INET),
        .port = @byteSwap(opts.port),
        // Little-endian hosts store the parsed value in reverse byte order,
        // so byte-swap into network order — same idiom as the port field.
        .addr = @byteSwap(parseHost(opts.host) catch {
            std.debug.print("error: bad host: {s}\n", .{opts.host});
            return error.BadHost;
        }),
        .zero = .{0} ** 8,
    };

    const src = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.DGRAM, 0);
    if (std.os.linux.errno(src) != .SUCCESS) {
        std.debug.print("error: socket: {s}\n", .{@tagName(std.os.linux.errno(src))});
        return error.SocketFailed;
    }
    const sock_fd: std.posix.fd_t = @intCast(src);
    defer _ = std.os.linux.close(sock_fd);

    var frame: [plant.net.frame_size]u8 = undefined;
    var stdin_src = StdinSource{};
    var seq: u32 = 0;
    while (true) {
        const value = nextValue(spi_fd, &stdin_src, opts) catch |e| switch (e) {
            error.Eof => break,
            else => {
                std.debug.print("read error: {s}\n", .{@errorName(e)});
                continue;
            },
        };
        // The vibration channel is only read when it is configured; without it
        // the frame carries a zero, which the receiver reads as "still".
        const vib: u16 = if (opts.vib_channel) |c| blk: {
            if (opts.source != .spi) break :blk 0;
            break :blk readMcp3008(spi_fd.?, c) catch 0;
        } else 0;
        const n = plant.net.encode(&frame, seq, value, vib);
        const sr = std.os.linux.sendto(sock_fd, frame[0..n].ptr, n, 0, @ptrCast(&dst_addr), @sizeOf(sockaddr_in));
        if (std.os.linux.errno(sr) != .SUCCESS) {
            std.debug.print("send error: {s}\n", .{@tagName(std.os.linux.errno(sr))});
        }
        std.debug.print("seq={d} value={d} vib={d}\n", .{ seq, value, vib });
        seq +%= 1;
        std.Io.Clock.Duration.sleep(.{ .raw = std.Io.Duration.fromMilliseconds(opts.rate_ms), .clock = .awake }, io) catch {};
    }
}
