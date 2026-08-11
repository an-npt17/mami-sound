const std = @import("std");
const plant = @import("plant");

const loopback: u32 = 0x7F000001;

/// Monotonic milliseconds. The debouncer needs a gap between readings, and a
/// wall clock that can step sideways would invent or swallow edges.
fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Which installation the Zig audio path is running.
pub const Source = enum {
    sample,
    random,
    track,

    pub fn fromString(v: []const u8) ?Source {
        if (std.mem.eql(u8, v, "sample")) return .sample;
        if (std.mem.eql(u8, v, "random")) return .random;
        if (std.mem.eql(u8, v, "track")) return .track;
        return null;
    }
};

pub const State = struct {
    lock_state: SpinLock = .{},
    seq: u32 = 0,
    value: u16 = 0,
    voltage: f32 = 0,
    /// Vibration channel, reported back so the page can show what the audio
    /// path actually used rather than what the slider last said.
    vib_voltage: f32 = 0,
    /// Playback-rate multiplier the vibration channel asks for, 1.0 = the
    /// sample's own pitch.
    pitch_ratio: f32 = 1.0,
    freq: f32 = 0,
    gain: f32 = 0,
    base_volume: f32,
    attack_ms: f32,
    decay_ms: f32,
    /// Held level after decay, as a fraction of the peak (0..1).
    sustain: f32,
    release_ms: f32,
    k: f32,
    /// How many semitones full-scale vibration lifts the pitch.
    pitch_range_st: f32 = plant.sensor.default_pitch_range_st,
    no_signal: bool = false,
    input_value: u16 = 0,
    input_vib_voltage: f32 = 0,
    input_seq: u64 = 0,
    mode: []const u8 = "mock",
    /// Bumped on every accepted POST /env so a browser can tell its own echo
    /// apart from an edit made elsewhere.
    env_seq: u64 = 0,

    // --- digital vibration line, for stations 2 and 3 ---------------------
    //
    // Debouncing happens here rather than in the tick loop: POSTs arrive at up
    // to 100 Hz while the loop runs at 5 Hz, and a 200 ms tap sampled every
    // 200 ms is a tap that sometimes never happened.
    deb: plant.sensor.Debouncer = plant.sensor.Debouncer.init(plant.sensor.default_debounce_ms),
    /// Last raw level seen, so the line can keep being timed out after the
    /// readings stop.
    last_raw: bool = false,
    last_step_ms: i64 = 0,
    digital_high: bool = false,
    rise_count: u64 = 0,
    fall_count: u64 = 0,
    source: Source = .sample,
    track_mode: plant.track.Mode = .one_shot,
    spread_st: f32 = plant.voices.default_spread_st,
    /// Reported back by the tick loop so the page can show what the Zig side is
    /// actually doing.
    track_pos_s: f32 = 0,
    track_len_s: f32 = 0,
    active_voices: usize = 0,

    pub fn init(base_volume: f32, attack_ms: f32, decay_ms: f32, sustain: f32, release_ms: f32, k: f32, mode: []const u8) State {
        return .{
            .base_volume = base_volume,
            .attack_ms = attack_ms,
            .decay_ms = decay_ms,
            .sustain = sustain,
            .release_ms = release_ms,
            .k = k,
            .mode = mode,
        };
    }

    /// Advance the debouncer by however long it has been since the last step.
    /// Callers must hold the lock.
    fn stepDigital(self: *State, raw: bool, now_ms: i64) void {
        // The first reading after a quiet spell has no meaningful gap; treat it
        // as zero rather than letting a stale timestamp commit an edge instantly.
        const dt: f32 = if (self.last_step_ms == 0) 0.0 else @floatFromInt(now_ms - self.last_step_ms);
        self.last_step_ms = now_ms;
        self.last_raw = raw;
        switch (self.deb.step(raw, dt)) {
            .rise => self.rise_count += 1,
            .fall => self.fall_count += 1,
            .none => {},
        }
        self.digital_high = self.deb.stable;
    }

    /// Keep timing the line out when no reading has arrived. A sender that only
    /// posts on change - the browser does exactly that - would otherwise leave
    /// its last edge pending forever, so the release of a button would never be
    /// heard.
    pub fn tickDigital(self: *State) void {
        self.lock();
        defer self.unlock();
        self.stepDigital(self.last_raw, nowMs());
    }

    pub fn lock(self: *State) void {
        self.lock_state.lock();
    }

    pub fn unlock(self: *State) void {
        self.lock_state.unlock();
    }
};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

pub const Server = struct {
    state: *State,
    listen_fd: std.posix.fd_t, // file descriptor for the listening socket
    running: std.atomic.Value(bool), // whether the server is running
    thread: std.Thread,

    pub fn init() Server {
        return .{
            .state = undefined,
            .listen_fd = -1,
            .running = std.atomic.Value(bool).init(false),
            .thread = undefined,
        };
    }

    pub fn start(self: *Server, state: *State, port: u16) !void {
        self.state = state;
        self.listen_fd = try listenSocket(port);
        errdefer _ = std.os.linux.close(self.listen_fd);
        self.running.store(true, .seq_cst);
        self.thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch {
            return error.ThreadSpawnFailed;
        };
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .seq_cst); // Signal the accept loop to stop.
        self.thread.join(); // Wait for the accept loop to finish.
        _ = std.os.linux.close(self.listen_fd);
    }
};

const sockaddr_in = extern struct {
    family: u16,
    port: u16,
    addr: u32,
    zero: [8]u8,
};
/// Listens on the given port and returns a file descriptor for the listening socket.
/// Args:
///   port: The port to listen on.
fn listenSocket(port: u16) !std.posix.fd_t {
    const rc = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SocketCreateFailed;
    const fd: std.posix.fd_t = @intCast(rc);
    errdefer _ = std.os.linux.close(fd);
    var yes: c_int = 1;
    _ = std.os.linux.setsockopt(fd, std.os.linux.SOL.SOCKET, std.os.linux.SO.REUSEADDR, @ptrCast(&yes), @sizeOf(c_int));
    const addr = sockaddr_in{
        .family = @intCast(std.os.linux.AF.INET),
        .port = @byteSwap(port),
        .addr = @byteSwap(loopback),
        .zero = .{0} ** 8,
    };
    const brc = std.os.linux.bind(fd, @ptrCast(&addr), @sizeOf(sockaddr_in));
    if (std.os.linux.errno(brc) != .SUCCESS) return error.BindFailed;
    const lrc = std.os.linux.listen(fd, 8);
    if (std.os.linux.errno(lrc) != .SUCCESS) return error.ListenFailed;
    return fd;
}

fn acceptLoop(srv: *Server) void {
    while (srv.running.load(.seq_cst)) {
        var pfd = [1]std.os.linux.pollfd{.{ .fd = srv.listen_fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
        const prc = std.os.linux.poll(&pfd, 1, 200);
        const err = std.os.linux.errno(prc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) break;
        if (!srv.running.load(.seq_cst)) break; // Exit if the server is no longer running.
        if ((pfd[0].revents & std.os.linux.POLL.IN) == 0) continue; // No incoming connection, continue polling.
        const arc = std.os.linux.accept(srv.listen_fd, null, null); // Accept a new connection.
        switch (std.os.linux.errno(arc)) {
            .SUCCESS => {
                const fd: std.posix.fd_t = @intCast(arc);
                const ctx = std.heap.page_allocator.create(ConnCtx) catch {
                    _ = std.os.linux.close(fd);
                    continue;
                };
                ctx.* = .{ .srv = srv, .fd = fd };
                const t = std.Thread.spawn(.{}, handleConn, .{ctx}) catch {
                    std.heap.page_allocator.destroy(ctx);
                    _ = std.os.linux.close(fd);
                    continue;
                };
                t.detach();
            },
            .AGAIN, .INTR => continue,
            else => break,
        }
    }
}

const ConnCtx = struct {
    srv: *Server,
    fd: std.posix.fd_t,
};

const index_html = @embedFile("index.html");

fn handleConn(ctx: *ConnCtx) void {
    defer {
        _ = std.os.linux.close(ctx.fd);
        std.heap.page_allocator.destroy(ctx);
    }
    var buf: [8192]u8 = undefined;
    const n = readRequest(ctx.fd, &buf) orelse {
        respond(ctx.fd, "400 Bad Request", "text/plain", "bad request\n");
        return;
    };
    const head = parseHead(buf[0..n]) orelse {
        respond(ctx.fd, "400 Bad Request", "text/plain", "bad request\n");
        return;
    };
    const body = if (head.content_length) |cl| buf[head.header_end .. head.header_end + cl] else buf[0..0];
    if (std.mem.eql(u8, head.method, "GET") and std.mem.eql(u8, head.path, "/")) {
        // The page is baked into the binary, so a cached copy survives a
        // rebuild and quietly serves the old UI against the new server.
        respondNoStore(ctx.fd, "200 OK", "text/html", index_html);
    } else if (std.mem.eql(u8, head.method, "GET") and std.mem.eql(u8, head.path, "/events")) {
        serveEvents(ctx);
    } else if (std.mem.eql(u8, head.method, "GET") and std.mem.eql(u8, head.path, "/favicon.ico")) {
        // Browsers probe this on every page load; answering keeps a 404 out of
        // the console for a page that has no icon to serve.
        respond(ctx.fd, "204 No Content", "text/plain", "");
    } else if (std.mem.eql(u8, head.method, "POST") and std.mem.eql(u8, head.path, "/env")) {
        handleEnv(ctx, body);
    } else if (std.mem.eql(u8, head.method, "POST") and std.mem.eql(u8, head.path, "/input")) {
        handleInput(ctx, body);
    } else {
        respond(ctx.fd, "404 Not Found", "text/plain", "not found\n");
    }
}

fn handleEnv(ctx: *ConnCtx, body: []const u8) void {
    const b = parseBody(body) orelse {
        respond(ctx.fd, "400 Bad Request", "text/plain", "bad body\n");
        return;
    };
    if (b.attack) |v| {
        if (std.math.isNan(v) or v < 0 or v > 200) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "attack out of range 0..200\n");
            return;
        }
    }
    if (b.decay) |v| {
        if (std.math.isNan(v) or v < 0 or v > 200) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "decay out of range 0..200\n");
            return;
        }
    }
    if (b.sustain) |v| {
        if (std.math.isNan(v) or v < 0 or v > 1) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "sustain out of range 0..1\n");
            return;
        }
    }
    if (b.release) |v| {
        if (std.math.isNan(v) or v < 0 or v > 200) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "release out of range 0..200\n");
            return;
        }
    }
    if (b.volume) |v| {
        if (std.math.isNan(v) or v < 0 or v > 1) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "volume out of range 0..1\n");
            return;
        }
    }
    if (b.k) |v| {
        if (std.math.isNan(v) or v < 0 or v > 3) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "k out of range 0..3\n");
            return;
        }
    }
    if (b.range) |v| {
        if (std.math.isNan(v) or v < 0 or v > plant.sensor.max_pitch_range_st) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "range out of range 0..24\n");
            return;
        }
    }
    if (b.spread) |v| {
        if (std.math.isNan(v) or v < 0 or v > plant.voices.max_spread_st) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "spread out of range 0..48\n");
            return;
        }
    }
    if (b.debounce) |v| {
        if (std.math.isNan(v) or v < 0 or v > 500) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "debounce out of range 0..500\n");
            return;
        }
    }
    var new_source: ?Source = null;
    if (b.source) |v| {
        new_source = Source.fromString(v) orelse {
            respond(ctx.fd, "400 Bad Request", "text/plain", "source must be sample|random|track\n");
            return;
        };
    }
    var new_mode: ?plant.track.Mode = null;
    if (b.track_mode) |v| {
        new_mode = plant.track.Mode.fromString(v) orelse {
            respond(ctx.fd, "400 Bad Request", "text/plain", "mode must be one-shot|restart|gate\n");
            return;
        };
    }
    const s = ctx.srv.state;
    s.lock();
    if (b.attack) |v| s.attack_ms = v;
    if (b.decay) |v| s.decay_ms = v;
    if (b.sustain) |v| s.sustain = v;
    if (b.release) |v| s.release_ms = v;
    if (b.volume) |v| s.base_volume = v;
    if (b.k) |v| s.k = v;
    if (b.range) |v| s.pitch_range_st = v;
    if (b.spread) |v| s.spread_st = v;
    if (b.debounce) |v| s.deb.stable_ms = v;
    if (new_source) |v| s.source = v;
    if (new_mode) |v| s.track_mode = v;
    s.env_seq += 1;
    s.unlock();
    respond(ctx.fd, "200 OK", "text/plain", "ok\n");
}

fn handleInput(ctx: *ConnCtx, body: []const u8) void {
    const b = parseBody(body) orelse {
        respond(ctx.fd, "400 Bad Request", "text/plain", "bad body\n");
        return;
    };
    const voltage = b.voltage orelse {
        respond(ctx.fd, "400 Bad Request", "text/plain", "missing voltage\n");
        return;
    };
    if (std.math.isNan(voltage) or voltage < 0 or voltage > 3.3) {
        respond(ctx.fd, "400 Bad Request", "text/plain", "voltage out of range 0..3.3\n");
        return;
    }
    // The vibration channel is optional so a single-sensor rig - and the old
    // voltage-only clients - keep working; absent means "not vibrating".
    if (b.vibration) |v| {
        if (std.math.isNan(v) or v < 0 or v > 3.3) {
            respond(ctx.fd, "400 Bad Request", "text/plain", "vibration out of range 0..3.3\n");
            return;
        }
    }
    const s = ctx.srv.state;
    const now_ms = nowMs();
    s.lock();
    s.input_value = plant.sensor.valueOfVoltage(voltage);
    const vib = b.vibration orelse 0.0;
    s.input_vib_voltage = vib;
    s.input_seq += 1;
    s.stepDigital(plant.sensor.isVibrating(vib), now_ms);
    s.unlock();
    respond(ctx.fd, "200 OK", "text/plain", "ok\n");
}

fn serveEvents(ctx: *ConnCtx) void {
    _ = writeAll(ctx.fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n") catch return;
    const s = ctx.srv.state;
    while (ctx.srv.running.load(.seq_cst)) {
        var seq: u32 = 0;
        var value: u16 = 0;
        var voltage: f32 = 0;
        var vib_voltage: f32 = 0;
        var pitch_ratio: f32 = 1;
        var range: f32 = 0;
        var spread: f32 = 0;
        var debounce: f32 = 0;
        var digital: bool = false;
        var rises: u64 = 0;
        var track_pos: f32 = 0;
        var track_len: f32 = 0;
        var voices_on: usize = 0;
        var source: Source = .sample;
        var track_mode: plant.track.Mode = .one_shot;
        var freq: f32 = 0;
        var gain: f32 = 0;
        var base: f32 = 0;
        var attack: f32 = 0;
        var decay: f32 = 0;
        var sustain: f32 = 0;
        var release: f32 = 0;
        var k: f32 = 0;
        var no_signal = false;
        var env_seq: u64 = 0;
        var mode: []const u8 = "mock";
        s.lock();
        seq = s.seq;
        value = s.value;
        voltage = s.voltage;
        vib_voltage = s.vib_voltage;
        pitch_ratio = s.pitch_ratio;
        range = s.pitch_range_st;
        spread = s.spread_st;
        debounce = s.deb.stable_ms;
        digital = s.digital_high;
        rises = s.rise_count;
        track_pos = s.track_pos_s;
        track_len = s.track_len_s;
        voices_on = s.active_voices;
        source = s.source;
        track_mode = s.track_mode;
        freq = s.freq;
        gain = s.gain;
        base = s.base_volume;
        attack = s.attack_ms;
        decay = s.decay_ms;
        sustain = s.sustain;
        release = s.release_ms;
        k = s.k;
        no_signal = s.no_signal;
        env_seq = s.env_seq;
        mode = s.mode;
        s.unlock();
        var line: [768]u8 = undefined;
        const out = std.fmt.bufPrint(
            &line,
            "data: seq={d} value={d} voltage={d:.3} vib={d:.3} ratio={d:.4} range={d:.1} freq={d:.1} gain={d:.3}" ++
                " base={d:.3} attack={d:.1} decay={d:.1} sustain={d:.3} release={d:.1} k={d:.2} nosig={d} envseq={d} mode={s}" ++
                " source={s} digital={d} rises={d} spread={d:.1} debounce={d:.0} trackmode={s} trackpos={d:.2} tracklen={d:.2} voices={d}\n\n",
            .{
                seq,               value,      voltage,        vib_voltage,          pitch_ratio, range,
                freq,              gain,       base,           attack,               decay,       sustain,
                release,           k,          @intFromBool(no_signal), env_seq,     mode,
                @tagName(source),  @intFromBool(digital),      rises,                spread,      debounce,
                @tagName(track_mode), track_pos, track_len,    voices_on,
            },
        ) catch return;
        writeAll(ctx.fd, out) catch return;
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 200_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}

fn readRequest(fd: std.posix.fd_t, buf: []u8) ?usize {
    var total: usize = 0;
    while (total < buf.len) {
        const rc = std.os.linux.read(fd, buf[total..].ptr, buf.len - total);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                total += rc;
            },
            .INTR => continue,
            else => return null,
        }
        if (parseHead(buf[0..total])) |h| {
            if (h.content_length) |cl| {
                if (total >= h.header_end + cl) return total;
            } else {
                return total;
            }
        }
    }
    return null;
}

fn respondNoStore(fd: std.posix.fd_t, status: []const u8, content_type: []const u8, body: []const u8) void {
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    writeAll(fd, head) catch return;
    writeAll(fd, body) catch return;
}

fn respond(fd: std.posix.fd_t, status: []const u8, content_type: []const u8, body: []const u8) void {
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    writeAll(fd, head) catch return;
    writeAll(fd, body) catch return;
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data[off..].ptr, data[off..].len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    content_length: ?usize,
    header_end: usize,
};

pub fn parseHead(buf: []const u8) ?Request {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    const line1_end = std.mem.indexOf(u8, buf, "\r\n") orelse return null;
    const line1 = buf[0..line1_end];
    const sp1 = std.mem.indexOfScalar(u8, line1, ' ') orelse return null;
    const sp2 = std.mem.indexOfScalarPos(u8, line1, sp1 + 1, ' ') orelse return null;
    const method = line1[0..sp1];
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "POST")) return null;
    const path = line1[sp1 + 1 .. sp2];
    var content_length: ?usize = null;
    var i: usize = line1_end + 2;
    while (i < header_end) {
        const line_end = std.mem.indexOfScalarPos(u8, buf, i, '\n') orelse break;
        var line_end_adj = line_end;
        if (line_end > i and buf[line_end - 1] == '\r') line_end_adj -= 1;
        const line = buf[i..line_end_adj];
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " ");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                const value = std.mem.trim(u8, line[colon + 1 ..], " ");
                const parsed = std.fmt.parseInt(usize, value, 10) catch return null;
                if (parsed > 8192) return null;
                content_length = parsed;
            }
        }
        i = line_end + 1;
    }
    return .{ .method = method, .path = path, .content_length = content_length, .header_end = header_end + 4 };
}

pub const Body = struct {
    attack: ?f32 = null,
    decay: ?f32 = null,
    sustain: ?f32 = null,
    release: ?f32 = null,
    volume: ?f32 = null,
    k: ?f32 = null,
    voltage: ?f32 = null,
    vibration: ?f32 = null,
    range: ?f32 = null,
    spread: ?f32 = null,
    debounce: ?f32 = null,
    source: ?[]const u8 = null,
    track_mode: ?[]const u8 = null,
};

pub fn parseBody(body: []const u8) ?Body {
    var b = Body{};
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
        const name = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, name, "attack")) {
            b.attack = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "decay")) {
            b.decay = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "sustain")) {
            b.sustain = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "release")) {
            b.release = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "volume")) {
            b.volume = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "k")) {
            b.k = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "voltage")) {
            b.voltage = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "vibration")) {
            b.vibration = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "range")) {
            b.range = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "spread")) {
            b.spread = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "debounce")) {
            b.debounce = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, name, "source")) {
            b.source = value;
        } else if (std.mem.eql(u8, name, "mode")) {
            b.track_mode = value;
        }
    }
    return b;
}

test "parseHead gets GET with no body" {
    const req = "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const h = parseHead(req) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("GET", h.method);
    try std.testing.expectEqualStrings("/events", h.path);
    try std.testing.expect(h.content_length == null);
}

test "parseHead gets POST content-length body" {
    const req = "POST /input HTTP/1.1\r\nContent-Length: 12\r\nHost: localhost\r\n\r\nvoltage=2.40";
    const h = parseHead(req) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("POST", h.method);
    try std.testing.expectEqualStrings("/input", h.path);
    try std.testing.expectEqual(@as(?usize, 12), h.content_length);
    try std.testing.expectEqual(@as(usize, req.len), h.header_end + 12);
}

test "parseHead rejects malformed and non-http methods" {
    try std.testing.expect(parseHead("no request line\r\n\r\n") == null);
    try std.testing.expect(parseHead("PUT / HTTP/1.1\r\n\r\n") == null);
    try std.testing.expect(parseHead("GET / HTTP/1.1") == null);
}

test "parseHead rejects oversized content-length" {
    const req = "POST /input HTTP/1.1\r\nContent-Length: 18446744073709551615\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(parseHead(req) == null);
}

test "parseBody extracts fields" {
    const b = parseBody("attack=8&release=35&volume=0.5&k=1.2") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 8.0), b.attack.?);
    try std.testing.expectEqual(@as(f32, 35.0), b.release.?);
    try std.testing.expectEqual(@as(f32, 0.5), b.volume.?);
    try std.testing.expectEqual(@as(f32, 1.2), b.k.?);
    try std.testing.expect(b.voltage == null);
}

test "parseBody extracts the vibration channel and pitch range" {
    const b = parseBody("voltage=1.20&vibration=2.75&range=7") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 1.20), b.voltage.?);
    try std.testing.expectEqual(@as(f32, 2.75), b.vibration.?);
    try std.testing.expectEqual(@as(f32, 7.0), b.range.?);
}

test "parseBody leaves vibration unset for a voltage-only client" {
    const b = parseBody("voltage=1.20") orelse return error.TestUnexpectedResult;
    try std.testing.expect(b.vibration == null);
    try std.testing.expect(b.range == null);
}

test "parseBody rejects a non-numeric vibration" {
    try std.testing.expect(parseBody("vibration=hard") == null);
    try std.testing.expect(parseBody("range=wide") == null);
}

test "parseBody rejects malformed pairs" {
    try std.testing.expect(parseBody("attack=8&garbage") == null);
    try std.testing.expect(parseBody("volume=high") == null);
    try std.testing.expect(parseBody("") != null);
}

test "parseBody extracts decay and sustain" {
    const b = parseBody("attack=8&decay=40&sustain=0.7&release=35") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 40.0), b.decay.?);
    try std.testing.expectEqual(@as(f32, 0.7), b.sustain.?);
    try std.testing.expectEqual(@as(f32, 8.0), b.attack.?);
    try std.testing.expectEqual(@as(f32, 35.0), b.release.?);
}

test "parseBody leaves decay and sustain unset when absent" {
    const b = parseBody("attack=8") orelse return error.TestUnexpectedResult;
    try std.testing.expect(b.decay == null);
    try std.testing.expect(b.sustain == null);
}

test "parseBody rejects a non-numeric sustain" {
    try std.testing.expect(parseBody("sustain=loud") == null);
    try std.testing.expect(parseBody("decay=soon") == null);
}
