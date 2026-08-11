const std = @import("std");
const builtin = @import("builtin");
const plant = @import("plant");
const web = @import("web.zig");

const sample_rate: u32 = 44100;
const step_ms: u32 = 200;
const step_samples: usize = sample_rate * step_ms / 1000;
const max_seq_gap_ms: i64 = 3000;

const Options = struct {
    mode: enum { mock, net, web } = .mock,
    port: u16 = plant.net.default_port,
    attack_ms: f32 = 6.0,
    decay_ms: f32 = 40.0,
    sustain: f32 = 0.7,
    release_ms: f32 = 30.0,
    volume: f32 = 0.5,
    mock_every_s: f32 = 8.0,
    duration_s: f32 = 0,
    seed: u64 = 42,
    web: bool = false,
    web_port: u16 = 9090,
    k: f32 = 1.2,
    /// Pitch the vibration channel shifts around, in Hz. Stands in for the
    /// sample's own pitch, which only the browser player has.
    base_freq: f32 = 220.0,
    pitch_range_st: f32 = plant.sensor.default_pitch_range_st,
    /// Which installation this process is running. Station 2 and 3 read the
    /// vibration line as a logic level; station 1 reads it as an analog value.
    source: web.Source = .sample,
    track_path: ?[]const u8 = null,
    track_mode: plant.track.Mode = .one_shot,
    spread_st: f32 = plant.voices.default_spread_st,
    debounce_ms: f32 = plant.sensor.default_debounce_ms,
};

fn usage(w: *std.Io.Writer) void {
    w.print(
        \\sensor-ui - plant sensor dashboard + sonification
        \\
        \\usage: sensor-ui [options]
        \\  --mode mock|net|web    input source (default: mock)
        \\  --port N               UDP listen port in net mode (default: 9090)
        \\  --attack MS            envelope attack in ms (default: 6)
        \\  --decay MS             envelope decay in ms (default: 40)
        \\  --sustain 0..1         level held after decay (default: 0.7)
        \\  --release MS           envelope release in ms (default: 30)
        \\  --volume 0..1          output volume (default: 0.5)
        \\  --mock-every S         seconds between mock touches (default: 8)
        \\  --duration S           run for S seconds, 0 = until q is pressed
        \\  --seed N               mock RNG seed (default: 42)
        \\  --web                  start web envelope editor server (default: off)
        \\  --web-port N           web server port (default: 9090)
        \\  --k X                  EM-sensor volume strength 0..3 (default: 1.2)
        \\  --base-freq HZ         pitch the vibration channel shifts from (default: 220)
        \\  --pitch-range ST       semitones full-scale vibration adds (default: 12)
        \\  --source NAME          sample|random|track station (default: sample)
        \\  --track PATH           .wav played directly, anything else via ffmpeg
        \\  --track-mode NAME      one-shot|restart|gate (default: one-shot)
        \\  --spread ST            random-tone pitch spread 0..48 (default: 24)
        \\  --debounce MS          digital vibration debounce 0..500 (default: 40)
        \\  -h, --help             show this help
        \\
    , .{}) catch {};
}

fn parseArgs(args: []const []const u8) !Options {
    var o = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return error.HelpRequested;
        if (std.mem.eql(u8, a, "--web")) {
            o.web = true;
            continue;
        }
        var it = a;
        if (std.mem.startsWith(u8, a, "--")) it = a[2..];
        const eq = std.mem.indexOfScalar(u8, it, '=');
        const name = if (eq) |e| it[0..e] else it;
        const val = if (eq) |e| it[e + 1 ..] else if (i + 1 < args.len) blk: {
            i += 1;
            break :blk args[i];
        } else return error.MissingValue;
        if (std.mem.eql(u8, name, "mode")) {
            if (std.mem.eql(u8, val, "mock")) o.mode = .mock else if (std.mem.eql(u8, val, "net")) o.mode = .net else if (std.mem.eql(u8, val, "web")) o.mode = .web else return error.BadMode;
        } else if (std.mem.eql(u8, name, "web-port")) {
            o.web_port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, name, "k")) {
            o.k = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "base-freq")) {
            o.base_freq = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "pitch-range")) {
            o.pitch_range_st = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "source")) {
            o.source = web.Source.fromString(val) orelse return error.BadSource;
        } else if (std.mem.eql(u8, name, "track")) {
            o.track_path = val;
        } else if (std.mem.eql(u8, name, "track-mode")) {
            o.track_mode = plant.track.Mode.fromString(val) orelse return error.BadTrackMode;
        } else if (std.mem.eql(u8, name, "spread")) {
            o.spread_st = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "debounce")) {
            o.debounce_ms = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "port")) {
            o.port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, name, "attack")) {
            o.attack_ms = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "decay")) {
            o.decay_ms = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "sustain")) {
            o.sustain = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "release")) {
            o.release_ms = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "volume")) {
            o.volume = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "mock-every")) {
            o.mock_every_s = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "duration")) {
            o.duration_s = try std.fmt.parseFloat(f32, val);
        } else if (std.mem.eql(u8, name, "seed")) {
            o.seed = try std.fmt.parseInt(u64, val, 10);
        } else {
            std.debug.print("unknown option: {s}\n", .{a});
            return error.BadArg;
        }
    }
    if (o.mode == .web) o.web = true;
    return o;
}

/// The envelope in force for one tick. Grouped so the dashboard and the tick
/// loop pass one value around instead of five positional floats.
const Env = struct {
    attack_ms: f32,
    decay_ms: f32,
    sustain: f32,
    release_ms: f32,
    base_volume: f32,
};

const MockToneParams = struct {
    gain: f32,
    touch_intensity: f32,
};

fn mockToneParams(env: Env, input: plant.sensor.InputState) MockToneParams {
    return .{
        .gain = env.base_volume,
        .touch_intensity = input.touch_intensity,
    };
}

/// What the two sensor channels asked for on this tick, for the dashboard.
const Channels = struct {
    em_v: f32,
    vib_v: f32,
    pitch_ratio: f32,
};

/// Which station is running and what it is doing, for the dashboard.
const Station = struct {
    source: web.Source,
    digital_high: bool,
    triggers: u64,
    voices: usize,
    track_pos_s: f32,
    track_len_s: f32,
    mode: plant.track.Mode,
};

fn drawStation(w: *std.Io.Writer, st: Station) void {
    w.print("station: \x1b[1m{s}\x1b[0m   digital: {s}   triggers: {d}\n", .{
        @tagName(st.source),
        if (st.digital_high) "\x1b[32mHIGH\x1b[0m" else "low",
        st.triggers,
    }) catch {};
    switch (st.source) {
        .sample => {},
        .random => w.print("voices: {d}/{d}\n", .{ st.voices, plant.voices.max_voices }) catch {},
        .track => w.print("track [{s}]: {d:.1} / {d:.1} s\n", .{
            @tagName(st.mode),
            st.track_pos_s,
            st.track_len_s,
        }) catch {},
    }
}

fn drawDashboard(w: *std.Io.Writer, opts: Options, value: u16, freq: f32, gain: f32, env: Env, ch: Channels, st: Station, since_signal_ms: i64) void {
    const no_signal = since_signal_ms > max_seq_gap_ms;
    w.print("\x1b[2J\x1b[H", .{}) catch {};
    w.print("\x1b[1mPLANT SENSOR UI\x1b[0m   mode: {s}\n", .{@tagName(opts.mode)}) catch {};
    if (no_signal) {
        w.print("\x1b[31mNO SIGNAL ({d} s)\x1b[0m\n", .{@divTrunc(since_signal_ms, 1000)}) catch {};
    } else if (plant.sensor.isTouch(value)) {
        w.print("\x1b[32mTOUCH\x1b[0m\n", .{}) catch {};
    } else {
        w.print("resting\n", .{}) catch {};
    }
    w.print("value: {d:>6}   freq: {d:.1} Hz   gain: {d:.2}   base: {d:.2}\n", .{ value, freq, gain, env.base_volume }) catch {};
    const semitones = 12.0 * @log2(@max(0.0001, ch.pitch_ratio));
    w.print("em: {d:.2} V -> volume    vib: {d:.2} V -> pitch x{d:.3} ({s}{d:.1} st)\n", .{
        ch.em_v,
        ch.vib_v,
        ch.pitch_ratio,
        if (semitones >= 0) "+" else "-",
        @abs(semitones),
    }) catch {};
    w.print("attack: {d:.0} ms   decay: {d:.0} ms   sustain: {d:.2}   release: {d:.0} ms\n", .{ env.attack_ms, env.decay_ms, env.sustain, env.release_ms }) catch {};
    drawStation(w, st);
    const bar_len: usize = 24;
    const filled = @min(bar_len, @as(usize, @intFromFloat(@as(f32, @floatFromInt(value)) / 65535.0 * @as(f32, @floatFromInt(bar_len)))));
    w.print("signal: [", .{}) catch {};
    var i: usize = 0;
    while (i < bar_len) : (i += 1) {
        w.writeAll(if (i < filled) "#" else ".") catch {};
    }
    w.print("]\n", .{}) catch {};
    w.print("\x1b[2mq to quit\x1b[0m\n", .{}) catch {};
}

fn drawMockDashboard(
    w: *std.Io.Writer,
    opts: Options,
    input: plant.sensor.InputState,
    freq: f32,
    gain: f32,
    env: Env,
) void {
    const dry_threshold: u8 = 40;
    const wet_threshold: u8 = 70;
    const moisture = input.sample.moisture_pct;
    const moisture_state = if (moisture < dry_threshold) "DRY" else if (moisture >= wet_threshold) "WET" else "NORMAL";
    const value = plant.sensor.rawValueOfMoisture(moisture);

    w.print("\x1b[2J\x1b[H", .{}) catch {};
    w.print("\x1b[1mPLANT SENSOR UI\x1b[0m   mode: {s}\n", .{@tagName(opts.mode)}) catch {};
    w.print("moisture state: {s}\n", .{moisture_state}) catch {};
    w.print("value: {d:>6}   freq: {d:.1} Hz   gain: {d:.2}   base: {d:.2}\n", .{ value, freq, gain, env.base_volume }) catch {};
    w.print("moisture: {d}%   temperature: {d:.1} C   humidity: {d:.1}%\n", .{ moisture, input.sample.temperature_c, input.sample.humidity_pct }) catch {};
    w.print("touch: {d:.2}     freq: {d:.1} Hz       gain: {d:.2}\n", .{ input.touch_intensity, freq, gain }) catch {};
    w.print("attack: {d:.0} ms   decay: {d:.0} ms   sustain: {d:.2}   release: {d:.0} ms\n", .{ env.attack_ms, env.decay_ms, env.sustain, env.release_ms }) catch {};

    const bar_len: usize = 24;
    const filled = @min(bar_len, @as(usize, @intFromFloat(@as(f32, @floatFromInt(moisture)) / 100.0 * @as(f32, @floatFromInt(bar_len)))));
    w.print("signal: [", .{}) catch {};
    var i: usize = 0;
    while (i < bar_len) : (i += 1) {
        w.writeAll(if (i < filled) "#" else ".") catch {};
    }
    w.print("]\n", .{}) catch {};
    w.print("\x1b[2mq to quit\x1b[0m\n", .{}) catch {};
}

const termios = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_line: u8,
    c_cc: [32]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

const TCGETS: u32 = 0x5401;
const TCSETS: u32 = 0x5402;
const ISIG: u32 = 0x1;
const ICANON: u32 = 0x2;
const ECHO: u32 = 0x8;

var original_termios: termios = undefined;
var termios_saved = false;

fn rawMode(on: bool) void {
    if (builtin.os.tag != .linux) return;
    const fd = std.posix.STDIN_FILENO;
    if (!termios_saved) {
        const rc = std.os.linux.ioctl(fd, TCGETS, @intFromPtr(&original_termios));
        if (std.os.linux.errno(rc) != .SUCCESS) return;
        termios_saved = true;
    }
    var t = original_termios;
    if (on) {
        t.c_lflag &= ~(ICANON | ECHO | ISIG);
        t.c_cc[6] = 1; // VMIN
        t.c_cc[5] = 0; // VTIME
    }
    _ = std.os.linux.ioctl(fd, TCSETS, @intFromPtr(&t));
}

fn setNonBlocking(fd: std.posix.fd_t) ?std.os.linux.O {
    const r = std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0);
    if (std.os.linux.errno(r) != .SUCCESS) return null;
    var flags: std.os.linux.O = @bitCast(@as(u32, @truncate(r)));
    flags.NONBLOCK = true;
    const s = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(flags)))));
    if (std.os.linux.errno(s) != .SUCCESS) return null;
    return @bitCast(@as(u32, @truncate(r)));
}

fn restoreNonBlocking(fd: std.posix.fd_t, flags: std.os.linux.O) void {
    _ = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(flags)))));
}

fn quitKey() bool {
    var c: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &c) catch return false;
    if (n == 1 and (c[0] == 'q' or c[0] == 0x03)) return true;
    return n == 0;
}

/// Load a track as mono PCM at the mixer's rate. A .wav is parsed in-process;
/// anything else - mp3 included - goes through ffmpeg, which the exhibit
/// machines already carry, instead of growing a decoder in here.
fn loadTrack(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !plant.track.Track {
    const max_bytes = 256 * 1024 * 1024;
    if (std.ascii.endsWithIgnoreCase(path, ".wav")) {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes));
        defer gpa.free(bytes);
        return .{
            .samples = try plant.track.decodeWav(gpa, bytes, sample_rate),
            .sample_rate = sample_rate,
        };
    }
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "ffmpeg", "-v", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", "44100", "-" },
        .stdout_limit = .limited(max_bytes),
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("ffmpeg: {s}\n", .{res.stderr});
            return error.FfmpegFailed;
        },
        else => return error.FfmpegFailed,
    }
    const count = res.stdout.len / 2;
    const samples = try gpa.alloc(i16, count);
    for (samples, 0..) |*v, i| v.* = std.mem.readInt(i16, res.stdout[i * 2 ..][0..2], .little);
    return .{ .samples = samples, .sample_rate = sample_rate };
}

const Audio = struct {
    child: std.process.Child,
    stdin: std.Io.File,

    fn spawn(io: std.Io) !Audio {
        const child = try std.process.spawn(io, .{
            .argv = &.{ "aplay", "-q", "-r", "44100", "-c", "1", "-f", "S16_LE", "-t", "raw" },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        return .{ .child = child, .stdin = child.stdin.? };
    }

    fn write(self: *Audio, io: std.Io, data: []const u8) void {
        self.stdin.writeStreamingAll(io, data) catch {};
    }

    fn stop(self: *Audio, io: std.Io) void {
        _ = io;
        if (self.child.id) |pid| {
            _ = std.os.linux.kill(pid, std.os.linux.SIG.KILL);
        }
    }
};

const sockaddr_in = extern struct {
    family: u16,
    port: u16,
    addr: u32,
    zero: [8]u8,
};

const Socket = struct {
    fd: std.posix.fd_t,

    fn close(self: *Socket) void {
        _ = std.os.linux.close(self.fd);
    }
};

fn netSocket(port: u16) !Socket {
    const rc = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.DGRAM, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketCreateFailed;
    const fd: std.posix.fd_t = @intCast(rc);
    errdefer _ = std.os.linux.close(fd);
    const addr = sockaddr_in{
        .family = @intCast(std.os.linux.AF.INET),
        .port = @byteSwap(port),
        .addr = 0,
        .zero = .{0} ** 8,
    };
    const brc = std.os.linux.bind(fd, @ptrCast(&addr), @sizeOf(sockaddr_in));
    if (std.os.linux.errno(brc) != .SUCCESS) return error.BindFailed;
    _ = setNonBlocking(fd);
    return .{ .fd = fd };
}

fn recvPacket(s: *Socket, buf: []u8) usize {
    const rc = std.os.linux.recvfrom(s.fd, buf.ptr, buf.len, 0, null, null);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return rc,
        .AGAIN => return 0,
        else => |e| {
            std.debug.print("recv error: {s}\n", .{@tagName(e)});
            return 0;
        },
    }
}

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

    rawMode(true);
    defer rawMode(false);
    const stdin_flags = setNonBlocking(std.posix.STDIN_FILENO);
    defer if (stdin_flags) |f| restoreNonBlocking(std.posix.STDIN_FILENO, f);

    var audio: ?Audio = null;
    audio = Audio.spawn(io) catch |e| blk: {
        std.debug.print("warning: could not start aplay: {s} (visual only)\n", .{@errorName(e)});
        break :blk null;
    };
    defer if (audio) |*a| a.stop(io);

    var mock_model = plant.sensor.MockModel.init(opts.seed);
    var synth = plant.synth.Synth.init(sample_rate, step_samples);
    synth.setEnvelope(opts.attack_ms, opts.decay_ms, opts.sustain, opts.release_ms);

    var voice_engine = plant.voices.Engine.init(opts.seed, sample_rate);
    var player = plant.track.Player{ .mode = opts.track_mode };
    if (opts.track_path) |path| {
        if (loadTrack(arena, io, path)) |t| {
            player.load(t);
            std.debug.print("track: {s} ({d:.1} s)\n", .{ path, t.durationS() });
        } else |e| {
            std.debug.print("warning: cannot load track {s}: {s}\n", .{ path, @errorName(e) });
        }
    }

    var web_state = web.State.init(opts.volume, opts.attack_ms, opts.decay_ms, opts.sustain, opts.release_ms, opts.k, @tagName(opts.mode));
    web_state.pitch_range_st = opts.pitch_range_st;
    web_state.source = opts.source;
    web_state.track_mode = opts.track_mode;
    web_state.spread_st = opts.spread_st;
    web_state.deb.stable_ms = opts.debounce_ms;
    web_state.track_len_s = player.durationS();
    var web_server: ?web.Server = null;
    if (opts.web) {
        web_server = web.Server.init();
        web_server.?.start(&web_state, opts.web_port) catch |e| {
            web_server = null;
            if (opts.mode == .web) {
                std.debug.print("error: cannot start web server on 127.0.0.1:{d}: {s}\n", .{ opts.web_port, @errorName(e) });
                return error.WebServerFailed;
            }
            std.debug.print("warning: web disabled ({s}); continuing\n", .{@errorName(e)});
        };
        if (web_server != null) {
            std.debug.print("web ui: http://127.0.0.1:{d}\n", .{opts.web_port});
        }
    }
    defer if (web_server) |*s| s.stop();

    var sock: ?Socket = null;
    if (opts.mode == .net) {
        sock = netSocket(opts.port) catch |e| {
            std.debug.print("error: cannot bind UDP port {d}: {s}\n", .{ opts.port, @errorName(e) });
            return error.BindFailed;
        };
    }
    defer if (sock) |*s| s.close();

    var stdout_buffer: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .init(std.Io.File.stdout(), io, &stdout_buffer);
    var block_buf: [step_samples]i16 = undefined;

    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    var last_signal: i64 = start;
    if (opts.mode == .web) last_signal = start - (max_seq_gap_ms + 1);
    var last_input_seq: u64 = 0;
    var seq: u32 = 0;
    var value: u16 = 0;
    var vib_voltage: f32 = 0;
    var cur_range_st: f32 = opts.pitch_range_st;
    var em_smooth = plant.sensor.Smoother.init(0.0, 120.0);
    var vib_smooth = plant.sensor.Smoother.init(0.0, 120.0);
    // Stations 2 and 3 in mock and net mode debounce here; in web mode the HTTP
    // handler already did it, because it sees every reading and this loop only
    // sees one in forty.
    var local_deb = plant.sensor.Debouncer.init(opts.debounce_ms);
    var cur_source = opts.source;
    var prev_source = opts.source;
    var cur_spread = opts.spread_st;
    var last_rise: u64 = 0;
    var last_fall: u64 = 0;
    var triggers: u64 = 0;
    var digital_high = false;
    const ticks_per_touch: usize = @intFromFloat(@max(1.0, opts.mock_every_s * 1000.0 / @as(f32, @floatFromInt(step_ms))));
    const ticks_per_watering: usize = @intFromFloat(45.0 * 1000.0 / @as(f32, @floatFromInt(step_ms)));

    while (true) {
        const now = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        const elapsed_s = @as(f32, @floatFromInt(now - start)) / 1000.0;
        if (opts.duration_s > 0 and elapsed_s >= opts.duration_s) break;

        var env = Env{
            .attack_ms = opts.attack_ms,
            .decay_ms = opts.decay_ms,
            .sustain = opts.sustain,
            .release_ms = opts.release_ms,
            .base_volume = opts.volume,
        };
        var cur_k = opts.k;
        // Age the line before reading it: the browser posts only when a value
        // changes, so the last edge needs this tick to commit.
        if (opts.mode == .web) web_state.tickDigital();
        if (opts.web) {
            web_state.lock();
            env.attack_ms = web_state.attack_ms;
            env.decay_ms = web_state.decay_ms;
            env.sustain = web_state.sustain;
            env.release_ms = web_state.release_ms;
            env.base_volume = web_state.base_volume;
            cur_k = web_state.k;
            cur_range_st = web_state.pitch_range_st;
            const input_seq = web_state.input_seq;
            const input_value = web_state.input_value;
            const input_vib = web_state.input_vib_voltage;
            cur_source = web_state.source;
            cur_spread = web_state.spread_st;
            player.mode = web_state.track_mode;
            local_deb.stable_ms = web_state.deb.stable_ms;
            const rises = web_state.rise_count;
            const falls = web_state.fall_count;
            const high = web_state.digital_high;
            web_state.unlock();
            if (opts.mode == .web) {
                digital_high = high;
                // Several taps can land inside one 200 ms tick; replay each.
                while (last_rise < rises) : (last_rise += 1) {
                    triggers += 1;
                    switch (cur_source) {
                        .random => _ = voice_engine.trigger(cur_spread),
                        .track => player.onRise(),
                        .sample => {},
                    }
                }
                while (last_fall < falls) : (last_fall += 1) {
                    if (cur_source == .track) player.onFall();
                }
            }
            if (opts.mode == .web and input_seq != last_input_seq) {
                last_input_seq = input_seq;
                value = input_value;
                vib_voltage = input_vib;
                last_signal = now;
            }
        }

        var mock_input: ?plant.sensor.InputState = null;
        var freq: f32 = 0.0;
        var gain: f32 = 0.0;
        var pitch_ratio: f32 = 1.0;
        if (opts.mode == .mock) {
            const touched = (seq % ticks_per_touch) == 0;
            if (touched) mock_model.touch();
            if (seq != 0 and (seq % ticks_per_watering) == 0) mock_model.water();
            const input = mock_model.tick();
            mock_input = input;
            value = plant.sensor.rawValueOfMoisture(input.sample.moisture_pct);
            last_signal = now;
            // The mock plant has no vibration sensor, so a touch stands in for
            // one: it is the event the digital stations exist to react to.
            vib_voltage = if (input.touch_intensity > 0.5) plant.sensor.v_supply else 0.0;
            freq = plant.sensor.freqOfMoisture(input.sample.moisture_pct);
            gain = mockToneParams(env, input).gain;
        } else if (opts.mode == .net) {
            var got = false;
            var scratch: [plant.net.frame_size]u8 = undefined;
            while (true) {
                const n = recvPacket(&sock.?, &scratch);
                if (n == 0) break;
                if (plant.net.decode(scratch[0..n])) |f| {
                    value = f.value;
                    seq = f.seq;
                    vib_voltage = @as(f32, @floatFromInt(f.vib)) / 65535.0 * plant.sensor.v_supply;
                    got = true;
                } else {
                    std.debug.print("bad frame ({d} bytes)\n", .{n});
                }
            }
            if (got) last_signal = now;
            const no_signal = now - last_signal > max_seq_gap_ms;
            freq = if (no_signal) 0.0 else plant.sensor.freqOf(value);
            gain = if (no_signal) 0.0 else plant.sensor.gainOf(env.base_volume, cur_k, value);
        } else {
            // Web mode is the dual-sensor path: the electromagnetic channel sets
            // volume, the vibration channel bends pitch away from base_freq.
            // Both are smoothed so a jumpy reading slides instead of clicking.
            const no_signal = now - last_signal > max_seq_gap_ms;
            const em_v = @as(f32, @floatFromInt(value)) / 65535.0 * plant.sensor.v_supply;
            const em_s = em_smooth.step(em_v, @floatFromInt(step_ms));
            const vib_s = vib_smooth.step(vib_voltage, @floatFromInt(step_ms));
            pitch_ratio = plant.sensor.pitchRatioOfVibration(vib_s, cur_range_st);
            freq = if (no_signal) 0.0 else opts.base_freq * pitch_ratio;
            gain = if (no_signal) 0.0 else plant.sensor.volumeOfEm(env.base_volume, cur_k, em_s);
        }

        const no_signal = now - last_signal > max_seq_gap_ms;

        if (opts.mode != .web) {
            switch (local_deb.step(plant.sensor.isVibrating(vib_voltage), @floatFromInt(step_ms))) {
                .rise => {
                    triggers += 1;
                    switch (cur_source) {
                        .random => _ = voice_engine.trigger(cur_spread),
                        .track => player.onRise(),
                        .sample => {},
                    }
                },
                .fall => if (cur_source == .track) player.onFall(),
                .none => {},
            }
            digital_high = local_deb.stable;
        }

        // Gate mode tracks the level every tick, so switching modes or stations
        // mid-hold lands in the right state without waiting for an edge.
        if (cur_source == .track) player.setGate(digital_high);

        // Leaving a station silences it, so nothing keeps ringing under the one
        // that took over.
        if (cur_source != prev_source) {
            voice_engine.silence();
            player.stop();
            prev_source = cur_source;
        }

        switch (cur_source) {
            .sample => {
                synth.setEnvelope(env.attack_ms, env.decay_ms, env.sustain, env.release_ms);
                if (mock_input) |input| {
                    synth.renderTone(freq, gain, input.touch_intensity, &block_buf);
                } else {
                    synth.renderTone(freq, gain, 0.0, &block_buf);
                }
            },
            // Stations 2 and 3 have no EM channel: their level is the base
            // volume, and the vibration line only decides when to sound.
            .random => voice_engine.render(env.base_volume, &block_buf),
            .track => player.render(env.base_volume, &block_buf),
        }
        if (audio) |*a| a.write(io, std.mem.sliceAsBytes(&block_buf));

        if (opts.web) {
            web_state.lock();
            web_state.seq = seq;
            web_state.value = value;
            web_state.voltage = @as(f32, @floatFromInt(value)) / 65535.0 * 3.3;
            web_state.vib_voltage = vib_voltage;
            web_state.pitch_ratio = pitch_ratio;
            web_state.track_pos_s = player.positionS();
            web_state.track_len_s = player.durationS();
            web_state.active_voices = voice_engine.active();
            web_state.freq = freq;
            web_state.gain = gain;
            web_state.no_signal = no_signal;
            web_state.unlock();
        }

        if (mock_input) |input| {
            drawMockDashboard(&out.interface, opts, input, freq, gain, env);
            drawStation(&out.interface, .{
                .source = cur_source,
                .digital_high = digital_high,
                .triggers = triggers,
                .voices = voice_engine.active(),
                .track_pos_s = player.positionS(),
                .track_len_s = player.durationS(),
                .mode = player.mode,
            });
        } else {
            const channels = Channels{
                .em_v = @as(f32, @floatFromInt(value)) / 65535.0 * plant.sensor.v_supply,
                .vib_v = vib_voltage,
                .pitch_ratio = pitch_ratio,
            };
            drawDashboard(&out.interface, opts, value, freq, gain, env, channels, .{
                .source = cur_source,
                .digital_high = digital_high,
                .triggers = triggers,
                .voices = voice_engine.active(),
                .track_pos_s = player.positionS(),
                .track_len_s = player.durationS(),
                .mode = player.mode,
            }, now - last_signal);
        }
        out.interface.flush() catch {};
        if (quitKey()) break;

        seq +%= 1;
        std.Io.Clock.Duration.sleep(.{ .raw = std.Io.Duration.fromMilliseconds(step_ms), .clock = .awake }, io) catch {};
    }
}

const test_env = Env{ .attack_ms = 6.0, .decay_ms = 40.0, .sustain = 0.7, .release_ms = 30.0, .base_volume = 0.5 };
const test_channels = Channels{ .em_v = 2.5, .vib_v = 1.65, .pitch_ratio = 1.4 };
const test_station = Station{
    .source = .sample,
    .digital_high = false,
    .triggers = 0,
    .voices = 0,
    .track_pos_s = 0,
    .track_len_s = 0,
    .mode = .one_shot,
};

test "dashboard renders header and touch state" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    drawDashboard(&aw.writer, Options{}, 50000, 660.0, 0.5, test_env, test_channels, test_station, 0);
    var buf = aw.toArrayList();
    defer buf.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "PLANT SENSOR UI") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "TOUCH") != null);
}

test "dashboard reports both sensor channels" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    drawDashboard(&aw.writer, Options{}, 50000, 660.0, 0.5, test_env, test_channels, test_station, 0);
    var buf = aw.toArrayList();
    defer buf.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "em: 2.50 V -> volume") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "vib: 1.65 V -> pitch x1.400") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "+5.8 st") != null);
}

test "dashboard names the running station and its digital line" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var st = test_station;
    st.source = .random;
    st.digital_high = true;
    st.triggers = 12;
    st.voices = 3;
    drawDashboard(&aw.writer, Options{}, 50000, 660.0, 0.5, test_env, test_channels, st, 0);
    var buf = aw.toArrayList();
    defer buf.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "station:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "random") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "HIGH") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "triggers: 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "voices: 3/8") != null);
}

test "dashboard reports track position for the track station" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var st = test_station;
    st.source = .track;
    st.mode = .gate;
    st.track_pos_s = 12.5;
    st.track_len_s = 120.0;
    drawDashboard(&aw.writer, Options{}, 50000, 660.0, 0.5, test_env, test_channels, st, 0);
    var buf = aw.toArrayList();
    defer buf.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "track [gate]: 12.5 / 120.0 s") != null);
}

test "dashboard renders no-signal state" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    drawDashboard(&aw.writer, Options{}, 1000, 30.0, 0.0, test_env, test_channels, test_station, 99999);
    var buf = aw.toArrayList();
    defer buf.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "NO SIGNAL") != null);
}

test "dashboard reports every envelope stage" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    drawDashboard(&aw.writer, Options{}, 50000, 660.0, 0.5, test_env, test_channels, test_station, 0);
    var buf = aw.toArrayList();
    defer buf.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "attack: 6 ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "decay: 40 ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "sustain: 0.70") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "release: 30 ms") != null);
}

test "mock dashboard renders plant values and touch intensity" {
    const input = plant.sensor.InputState{
        .sample = .{
            .moisture_pct = 55,
            .temperature_c = 23.0,
            .humidity_pct = 60.0,
        },
        .touch_intensity = 0.75,
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    drawMockDashboard(&aw.writer, Options{}, input, 493.0, 0.56, test_env);
    var buf = aw.toArrayList();
    defer buf.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "moisture: 55%") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "temperature: 23.0 C") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "humidity: 60.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "touch: 0.75") != null);
}

test "mock tone keeps touch separate from base gain" {
    const input = plant.sensor.InputState{
        .sample = .{
            .moisture_pct = 55,
            .temperature_c = 23.0,
            .humidity_pct = 60.0,
        },
        .touch_intensity = 1.0,
    };
    const params = mockToneParams(test_env, input);
    try std.testing.expectEqual(test_env.base_volume, params.gain);
    try std.testing.expectEqual(input.touch_intensity, params.touch_intensity);
}
