# Audio Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every audio source one named thing that either plant can be told to
play, configured entirely from the command line.

**Architecture:** A `Source` enum in `core/` names the drone and every clip
folder and carries its two default lengths. A `Voice` tagged union in
`application/` is either the generated drone or a clip stream plus its selector,
so the engine holds `[2]Voice` and stops knowing which plant is which. The
adapter side keeps owning the mapping from a source name to directories on disk.

**Tech Stack:** Zig 0.16, `nix develop` for the toolchain, `ffmpeg` for decoding,
`aplay` for output. Build with `zig build`, test with `zig build test`.

**Spec:** `docs/superpowers/specs/2026-08-27-audio-sources-design.md`

## Global Constraints

- Zig 0.16. All commands run inside `nix develop -c ...`.
- Target is a Raspberry Pi Zero 2 W: four slow cores, 512 MB RAM shared with the GPU.
- The audio thread allocates nothing, takes no locks, and never blocks on a decoder.
- Files stay between 200 and 400 lines; split past 400.
- Every function has a doc comment explaining why, not what. Comments in English.
- `zig fmt --check src/ build.zig` must pass before every commit.
- `zig build test` must pass before every commit.
- Sources and their defaults, copied from the spec:

  | source | folder | plays | retrigger guard |
  |---|---|---|---|
  | `drone` | — | generative | — |
  | `recordings` | `interview files/` + `field records/` | to the clip's end | 10 s |
  | `daybird` | `Day bird/` | 5 s | 5 s |
  | `insect` | `Insect/` | 5 s | 5 s |
  | `tradvn` | `Trad Vn Jam/` | to the clip's end | 5 s |
  | `bell` | `Bell Stems/` | 4 s | 5 s |
  | `piano` | `EPiano Stems/` | 4 s | 5 s |

- Flags: `--plant-a=SOURCE`, `--plant-b=SOURCE`, `--plant-a-seconds=N`,
  `--plant-b-seconds=N`, `--plant-a-retrigger=N`, `--plant-b-retrigger=N`.
  Bare `--plant-a` means `--plant-a=daybird`. `N=0` on `--seconds` plays to the
  clip's own end. `--seconds` or `--retrigger` on `drone` is refused.
- Defaults with no flags: `--plant-a=drone`, `--plant-b=recordings`, which is
  what the installation does today.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/core/source.zig` (new) | The `Source` enum, its parser, its two default lengths. Knows no directories. |
| `src/core/clips.zig` (renamed from `plant_b.zig`) | `Limit`, `ClipSelector`, clip length constants. Serves both plants. |
| `src/application/voice.zig` (new) | The `Voice` union: drone or clips. Owns the branch. |
| `src/application/engine.zig` | Holds `[2]Voice`, loops over plants identically. |
| `src/adapters/clip_loader.zig` | `Source` to directories, and loading a pool with folder indices. |
| `src/cli.zig` | The six flags, plus the bare `--plant-a` shorthand. |
| `src/main.zig` | One loop over the two plants, building whichever voice each was named. |

---

### Task 1: The `Source` vocabulary

**Files:**
- Create: `src/core/source.zig`
- Modify: `src/core/root.zig`

**Interfaces:**
- Consumes: nothing.
- Produces: `Source` enum with variants `drone, recordings, daybird, insect, tradvn, bell, piano`;
  `Source.parse(name: []const u8) Error!Source`;
  `Source.isDrone(self: Source) bool`;
  `Source.defaultSeconds(self: Source) ?f32`;
  `Source.defaultRetriggerSeconds(self: Source) f32`;
  `Error = error{UnknownSource}`.

- [ ] **Step 1: Write the failing tests**

Create `src/core/source.zig` containing only the tests for now:

```zig
const std = @import("std");

test "every source name parses to itself" {
    try std.testing.expectEqual(Source.drone, try Source.parse("drone"));
    try std.testing.expectEqual(Source.recordings, try Source.parse("recordings"));
    try std.testing.expectEqual(Source.daybird, try Source.parse("daybird"));
    try std.testing.expectEqual(Source.insect, try Source.parse("insect"));
    try std.testing.expectEqual(Source.tradvn, try Source.parse("tradvn"));
    try std.testing.expectEqual(Source.bell, try Source.parse("bell"));
    try std.testing.expectEqual(Source.piano, try Source.parse("piano"));
}

test "a name no source has is refused" {
    try std.testing.expectError(Error.UnknownSource, Source.parse("cello"));
    try std.testing.expectError(Error.UnknownSource, Source.parse(""));
}

test "only the drone is the drone" {
    try std.testing.expect(Source.drone.isDrone());
    try std.testing.expect(!Source.recordings.isDrone());
    try std.testing.expect(!Source.tradvn.isDrone());
}

test "a source that plays to its own end has no length" {
    try std.testing.expect(Source.recordings.defaultSeconds() == null);
    try std.testing.expect(Source.tradvn.defaultSeconds() == null);
    try std.testing.expect(Source.drone.defaultSeconds() == null);
}

test "a source that answers with a fragment carries its length" {
    try std.testing.expectEqual(@as(f32, 5.0), Source.daybird.defaultSeconds().?);
    try std.testing.expectEqual(@as(f32, 5.0), Source.insect.defaultSeconds().?);
    try std.testing.expectEqual(@as(f32, 4.0), Source.bell.defaultSeconds().?);
    try std.testing.expectEqual(@as(f32, 4.0), Source.piano.defaultSeconds().?);
}

test "the recordings are protected for longer than anything else" {
    // They are the piece's own voice and run for minutes; the rest are answers
    // to a hand and want moving on sooner.
    try std.testing.expectEqual(@as(f32, 10.0), Source.recordings.defaultRetriggerSeconds());
    try std.testing.expectEqual(@as(f32, 5.0), Source.tradvn.defaultRetriggerSeconds());
    try std.testing.expectEqual(@as(f32, 5.0), Source.daybird.defaultRetriggerSeconds());
    try std.testing.expectEqual(@as(f32, 5.0), Source.bell.defaultRetriggerSeconds());
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `use of undeclared identifier 'Source'`.

- [ ] **Step 3: Write the implementation**

Prepend to `src/core/source.zig`, above the tests:

```zig
//! What a plant can be told to play.
//!
//! One vocabulary for the generated drone and for every folder of clips, so a
//! plant is configured by naming a source rather than by a flag that means one
//! thing on plant A and another on plant B. Adding a folder is a variant here
//! and a line in the loader; nothing else in the program learns its name.
//!
//! Two lengths travel with a source because they answer different questions and
//! have been conflated once already. `defaultSeconds` is how much of a clip a
//! touch gets before it is faded out. `defaultRetriggerSeconds` is how long that
//! clip is protected from the next touch, counted from when it started.

pub const Error = error{UnknownSource};

/// How long a clip is protected from the next hand, for everything but the
/// recordings. Long enough that a clip has established itself, short enough
/// that a room which has heard enough can move it on.
pub const default_retrigger_s: f32 = 5.0;

/// The recordings run for minutes and are the piece's own voice rather than an
/// answer to a hand, so they are given twice as long before a touch may cut in.
pub const recordings_retrigger_s: f32 = 10.0;

/// A tuned note plus enough of its tail to hear it as a note.
pub const stem_play_s: f32 = 4.0;

/// A call, or a few seconds of ambience. The folders behind `daybird` and
/// `insect` hold recordings of up to forty seconds, which is a field recording
/// rather than a plant answering somebody.
pub const fragment_play_s: f32 = 5.0;

pub const Source = enum {
    /// The sensor-driven voice. Generated rather than played, so it has no
    /// folder and neither length means anything to it.
    drone,
    recordings,
    daybird,
    insect,
    tradvn,
    bell,
    piano,

    pub fn parse(name: []const u8) Error!Source {
        return std.meta.stringToEnum(Source, name) orelse Error.UnknownSource;
    }

    pub fn isDrone(self: Source) bool {
        return self == .drone;
    }

    /// How long one touch plays. `null` runs to the clip's own end, which is
    /// what the two long-form sources want: an interview cut at five seconds is
    /// a fragment, and a jam cut there is not music.
    pub fn defaultSeconds(self: Source) ?f32 {
        return switch (self) {
            .drone, .recordings, .tradvn => null,
            .daybird, .insect => fragment_play_s,
            .bell, .piano => stem_play_s,
        };
    }

    /// How long a clip is protected from the next touch, from when it started.
    ///
    /// A source whose play length is under its guard is never held back by it:
    /// the clip has ended, so the plant is listening again whatever the guard
    /// says. It matters only where a clip is still sounding.
    pub fn defaultRetriggerSeconds(self: Source) f32 {
        return switch (self) {
            .recordings => recordings_retrigger_s,
            else => default_retrigger_s,
        };
    }
};
```

- [ ] **Step 4: Register the module**

In `src/core/root.zig`, add alongside the other exports and inside the `test` block:

```zig
pub const source = @import("source.zig");
```
```zig
    _ = source;
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
nix develop -c zig fmt --check src/ build.zig
git add src/core/source.zig src/core/root.zig
git commit -m "feat(core): name every audio source in one vocabulary"
```

---

### Task 2: Rename `plant_b.zig` to `clips.zig` and make the guard configurable

**Files:**
- Rename: `src/core/plant_b.zig` to `src/core/clips.zig`
- Modify: `src/core/root.zig`, `src/adapters/clip_heads.zig`, `src/adapters/clip_loader.zig`, `src/adapters/clip_stream.zig`, `src/application/engine.zig`, `src/clip_stream_integration_test.zig`, `src/cli.zig`, `src/main.zig`

**Interfaces:**
- Consumes: `core.source.Source` from Task 1.
- Produces: `core.clips.Limit` with `Limit.forSource(source: core.source.Source, seconds: ?f32, sample_rate: u32) Limit`;
  `core.clips.ClipSelector.init(folders: []const u8, retrigger_s: f32, sample_rate: u32, random: std.Random) ClipSelector`;
  `ClipSelector.start(self: *ClipSelector, touched: bool, sounding: bool, frames: usize) ?usize` unchanged.
  `Pool` no longer exists.

- [ ] **Step 1: Write the failing tests**

Append to `src/core/plant_b.zig` (it becomes `clips.zig` in step 3):

```zig
test "a source's own length becomes its limit" {
    const capped: Limit = .forSource(.bell, null, 44100);
    try std.testing.expectEqual(@as(usize, 4 * 44100), capped.total);
    try std.testing.expect(capped.fade > 0);

    const uncapped: Limit = .forSource(.tradvn, null, 44100);
    try std.testing.expectEqual(Limit.unlimited.total, uncapped.total);
}

test "an override replaces the source's length" {
    const longer: Limit = .forSource(.bell, 12.0, 44100);
    try std.testing.expectEqual(@as(usize, 12 * 44100), longer.total);

    // Zero is how a capped source is uncapped from the command line.
    const uncapped: Limit = .forSource(.bell, 0.0, 44100);
    try std.testing.expectEqual(Limit.unlimited.total, uncapped.total);

    // And how a source that runs to its end is capped.
    const capped: Limit = .forSource(.recordings, 30.0, 44100);
    try std.testing.expectEqual(@as(usize, 30 * 44100), capped.total);
}

test "the guard length reaches the selector" {
    var prng = std.Random.DefaultPrng.init(1);
    const folders = [_]u8{ 0, 0 };
    var selector = ClipSelector.init(&folders, 5.0, 44100, prng.random());
    try std.testing.expectEqual(@as(u64, 5 * 44100), selector.open_frames);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `no member named 'forSource'`.

- [ ] **Step 3: Rename the file and update the module registration**

```bash
git mv src/core/plant_b.zig src/core/clips.zig
```

In `src/core/root.zig` replace the `plant_b` export and its `test` entry:

```zig
pub const clips = @import("clips.zig");
```
```zig
    _ = clips;
```

- [ ] **Step 4: Replace `Pool` and rework `Limit` and `ClipSelector`**

In `src/core/clips.zig`: delete the whole `Pool` enum and the `stem_play_s`,
`bird_play_s` and `open_after_s` constants — Task 1 owns all of them now. Add
the import and replace `forPool`:

```zig
const source_mod = @import("source.zig");
```

```zig
    /// The allowance a source asks for, or the one the room asked for instead.
    ///
    /// `seconds` of zero means play to the clip's own end. It is the only way
    /// to uncap a capped source from the command line, and the reason this
    /// takes an optional rather than a plain float: absent is "use the
    /// source's own", zero is "use none".
    pub fn forSource(
        source: source_mod.Source,
        seconds: ?f32,
        sample_rate: u32,
    ) Limit {
        const chosen = seconds orelse source.defaultSeconds() orelse return .unlimited;
        if (chosen <= 0.0) return .unlimited;

        const sr: f32 = @floatFromInt(sample_rate);
        const total = @max(chosen * sr, 1.0);
        return .{
            .total = @intFromFloat(total),
            .fade = @intFromFloat(@min(stem_fade_s * sr, total)),
        };
    }
```

Change `ClipSelector.init` to take the guard length, and its `open_frames`
computation to use it:

```zig
    pub fn init(
        folders: []const u8,
        retrigger_s: f32,
        sample_rate: u32,
        random: std.Random,
    ) ClipSelector {
        return .{
            .folders = folders,
            .random = random,
            .previous_touch = false,
            .last_folder = null,
            .frames_since_start = 0,
            .open_frames = @intFromFloat(retrigger_s * @as(f32, @floatFromInt(sample_rate))),
        };
    }
```

- [ ] **Step 5: Update every call site**

Every `core.plant_b.` becomes `core.clips.`, and every `plant_b.Pool` becomes
`source.Source`. The compiler names each one. In the existing tests inside
`src/core/clips.zig`, `testSelector` gains the guard length:

```zig
fn testSelector(folders: []const u8, seed: u64) ClipSelector {
    const State = struct {
        var prng: std.Random.DefaultPrng = undefined;
    };
    State.prng = .init(seed);
    return ClipSelector.init(folders, 10.0, 44100, State.prng.random());
}
```

The existing guard tests were written against ten seconds and keep passing with
that value passed explicitly.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
nix develop -c zig fmt --check src/ build.zig
git add -A src/
git commit -m "refactor(core): rename plant_b to clips and take both lengths from the source"
```

---

### Task 3: Teach the loader the new folders

**Files:**
- Modify: `src/adapters/clip_loader.zig`

**Interfaces:**
- Consumes: `core.source.Source` from Task 1.
- Produces: `directoriesFor(source: core.source.Source) []const []const u8`;
  `loadPool(gpa: std.mem.Allocator, io: std.Io, which: core.source.Source) !LoadedPool`
  (renamed from `loadPlantB`); `LoadedPool` unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `src/adapters/clip_loader.zig`:

```zig
test "the new folders are named" {
    try std.testing.expectEqual(@as(usize, 1), directoriesFor(.insect).len);
    try std.testing.expectEqualStrings("Insect", directoriesFor(.insect)[0]);

    try std.testing.expectEqual(@as(usize, 1), directoriesFor(.tradvn).len);
    try std.testing.expectEqualStrings("Trad Vn Jam", directoriesFor(.tradvn)[0]);
}

test "the new folders load into non-empty pools" {
    const gpa = std.testing.allocator;
    for ([_]core.source.Source{ .insect, .tradvn }) |which| {
        var pool = try loadPool(gpa, std.testing.io, which);
        defer pool.deinit(gpa);
        try std.testing.expect(pool.paths.len > 0);
        try std.testing.expectEqual(pool.paths.len, pool.folders.len);
        for (pool.folders) |folder| try std.testing.expectEqual(@as(u8, 0), folder);
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `no field named 'insect'` or `use of undeclared identifier 'loadPool'`.

- [ ] **Step 3: Write the implementation**

In `src/adapters/clip_loader.zig`, change the signature and body of
`directoriesFor`, and rename `loadPlantB` to `loadPool`:

```zig
/// The folders each source is made of, relative to where the binary is run.
///
/// The recordings are two folders read as one, so a clip is drawn from both
/// without either being over-represented by having its own turn. Every other
/// source is one folder.
///
/// This is the only place the folder names live. Nothing in `core` knows them:
/// a source there is a name, and turning a name into a directory is exactly the
/// kind of thing that belongs on this side of the port.
pub fn directoriesFor(source: core.source.Source) []const []const u8 {
    return switch (source) {
        // Asked for by a caller that should have checked `isDrone` first. There
        // is no folder to return and an empty list would load as a pool with no
        // clips, which is silence nobody can tell from the piece working.
        .drone => unreachable,
        .recordings => &.{ "interview files", "field records" },
        .daybird => &.{"Day bird"},
        .insect => &.{"Insect"},
        .tradvn => &.{"Trad Vn Jam"},
        .bell => &.{"Bell Stems"},
        .piano => &.{"EPiano Stems"},
    };
}
```

```zig
pub fn loadPool(
    gpa: std.mem.Allocator,
    io: std.Io,
    which: core.source.Source,
) !LoadedPool {
```

Update the existing `directoriesFor` test in this file to the new source names,
and every `loadPlantB` call in `src/main.zig` to `loadPool`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
nix develop -c zig fmt --check src/ build.zig
git add -A src/
git commit -m "feat(adapters): add the insect and tradvn folders as sources"
```

---

### Task 4: The `Voice` union

**Files:**
- Create: `src/application/voice.zig`
- Modify: `src/application/root.zig`

**Interfaces:**
- Consumes: `core.clips.ClipSelector`, `core.noise.Noise`, `ports.ClipStream`, `core.touch.Detector`.
- Produces: `Voice` union with variants `drone: core.noise.Noise` and `clips: Clips`;
  `Clips = struct { stream: ports.ClipStream, selector: core.clips.ClipSelector }`;
  `Voice.render(self: *Voice, piece: []f32, probe: *const core.touch.Detector, touched: bool) void`.

- [ ] **Step 1: Write the failing tests**

Create `src/application/voice.zig` containing only the tests:

```zig
const std = @import("std");
const core = @import("../core/root.zig");
const ports = @import("../ports/root.zig");

/// A clip stream that answers every request with a steady tone, so a test can
/// tell a clip voice from a drone by what comes out.
const FakeStream = struct {
    playing: bool = false,
    requests: usize = 0,

    fn render(context: *anyopaque, out: []f32, request: ?usize) void {
        const self: *FakeStream = @ptrCast(@alignCast(context));
        if (request != null) {
            self.requests += 1;
            self.playing = true;
        }
        if (!self.playing) return;
        for (out) |*sample| sample.* += 0.5;
    }

    fn sounding(context: *anyopaque) bool {
        const self: *FakeStream = @ptrCast(@alignCast(context));
        return self.playing;
    }

    fn port(self: *FakeStream) ports.ClipStream {
        return .{ .context = self, .render_fn = render, .sounding_fn = sounding };
    }
};

fn testDetector() core.touch.Detector {
    return .init(.{ .sample_rate = 44100, .poll_frames = 128, .model = .steady });
}

test "a clip voice asks for a clip on a touch and plays it" {
    var stream: FakeStream = .{};
    var prng = std.Random.DefaultPrng.init(1);
    const folders = [_]u8{ 0, 0 };
    var voice: Voice = .{ .clips = .{
        .stream = stream.port(),
        .selector = .init(&folders, 5.0, 44100, prng.random()),
    } };

    const probe = testDetector();
    var piece = [_]f32{0.0} ** 128;
    voice.render(&piece, &probe, true);

    try std.testing.expectEqual(@as(usize, 1), stream.requests);
    try std.testing.expect(piece[0] != 0.0);
}

test "a clip voice does not ask again inside the guard" {
    var stream: FakeStream = .{};
    var prng = std.Random.DefaultPrng.init(1);
    const folders = [_]u8{ 0, 0 };
    var voice: Voice = .{ .clips = .{
        .stream = stream.port(),
        .selector = .init(&folders, 5.0, 44100, prng.random()),
    } };

    const probe = testDetector();
    var piece = [_]f32{0.0} ** 128;
    // Four seconds of a hand arriving and leaving, all inside the five-second
    // guard on a clip that is still sounding.
    for (0..4 * 44100 / 128) |poll| {
        voice.render(&piece, &probe, poll % 2 == 0);
    }
    try std.testing.expectEqual(@as(usize, 1), stream.requests);
}

test "a drone voice sounds without any clip being asked for" {
    var stream: FakeStream = .{};
    var voice: Voice = .{ .drone = .init(44100, 1, .{ .span = 3000 }) };

    const probe = testDetector();
    var piece = [_]f32{0.0} ** 4096;
    voice.render(&piece, &probe, true);

    var peak: f32 = 0.0;
    for (piece) |sample| peak = @max(peak, @abs(sample));
    try std.testing.expect(peak > 0.0);
    try std.testing.expectEqual(@as(usize, 0), stream.requests);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `use of undeclared identifier 'Voice'`.

- [ ] **Step 3: Write the implementation**

Prepend to `src/application/voice.zig`, above the tests:

```zig
//! What one plant sounds like for the length of one render.
//!
//! A plant is either the generated voice or a folder of clips, and this union
//! is the only place that distinction lives. Everything above it -- the engine,
//! the command line -- holds two of these and treats them alike, which is what
//! lets either plant be either thing without either of them knowing which plant
//! it is.
//!
//! The two arms are alternatives and never a mix: a drone under a bird call is
//! neither of them.

/// A folder of clips and the state deciding which one a touch starts.
pub const Clips = struct {
    stream: ports.ClipStream,
    selector: core.clips.ClipSelector,
};

pub const Voice = union(enum) {
    drone: core.noise.Noise,
    clips: Clips,

    /// Add this plant's output into `piece`.
    ///
    /// `probe` is the plant's own detector, which only the drone reads: the
    /// pitch is the probe's deviation, where a clip cares about the touch alone.
    pub fn render(
        self: *Voice,
        piece: []f32,
        probe: *const core.touch.Detector,
        touched: bool,
    ) void {
        switch (self.*) {
            .drone => |*voice| voice.render(piece, probe.deviation(), touched),
            .clips => |*clips| {
                // Asked before rendering, so the answer is about the clip
                // already running rather than the one this poll might start.
                const sounding = clips.stream.sounding();
                const request = clips.selector.start(touched, sounding, piece.len);
                clips.stream.render(piece, request);
            },
        }
    }
};
```

- [ ] **Step 4: Register the module**

In `src/application/root.zig`, add the import and its `test` entry:

```zig
const voice = @import("voice.zig");
```
```zig
    _ = voice;
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
nix develop -c zig fmt --check src/ build.zig
git add src/application/voice.zig src/application/root.zig
git commit -m "feat(application): one voice type for a drone or a folder of clips"
```

---

### Task 5: The engine holds two voices

**Files:**
- Modify: `src/application/engine.zig`

**Interfaces:**
- Consumes: `Voice` from Task 4.
- Produces: `Engine.init(selection: core.plant.Selection, touch_config: core.touch.Config, probe: ports.ProbeSource, sink: ports.AudioSink, status: ports.StatusSink, voices: [2]voice_mod.Voice) Engine`.
  The `clip_stream`, `clip_folders`, `plant_a_stream`, `plant_a_folders` and
  `random` parameters are gone: a voice arrives already built.

- [ ] **Step 1: Write the failing test**

Append to `src/application/engine.zig`, alongside the existing engine tests:

```zig
test "either plant can be either kind of voice" {
    // The whole point of the change: nothing in the engine knows which plant is
    // which, so a clip voice on A and a drone on B must work exactly as well as
    // the other way round.
    var stream_a: FakeClips = .{};
    var stream_b: FakeClips = .{};

    const a_clips = try runVoices(heldBoth, warmup_blocks, .{
        clipVoice(&stream_a, 0),
        droneVoice(),
    });
    const b_clips = try runVoices(heldBoth, warmup_blocks, .{
        droneVoice(),
        clipVoice(&stream_b, 1),
    });

    try testing.expect(stream_a.requests > 0);
    try testing.expect(stream_b.requests > 0);
    try testing.expect(a_clips.rms() > 0.0);
    try testing.expect(b_clips.rms() > 0.0);
}
```

Add the helpers this needs, next to the existing `runPlantA`:

```zig
/// Both probes held, so whichever plant carries a clip voice gets a touch.
fn heldBoth(poll: usize) ports.Reading {
    const value = heldA(poll).raw_a;
    return .{ .raw_a = value, .raw_bc = value };
}

fn clipVoice(stream: *FakeClips, seed: u64) voice_mod.Voice {
    const State = struct {
        var prng: [2]std.Random.DefaultPrng = undefined;
        var folders = [_]u8{ 0, 0 };
    };
    State.prng[seed] = .init(seed + 1);
    return .{ .clips = .{
        .stream = stream.port(),
        .selector = .init(&State.folders, 5.0, core.sample_rate, State.prng[seed].random()),
    } };
}

fn droneVoice() voice_mod.Voice {
    return .{ .drone = .init(core.sample_rate, 1, .{ .span = 3000 }) };
}

fn runVoices(
    pattern: *const fn (usize) ports.Reading,
    blocks: usize,
    voices: [2]voice_mod.Voice,
) !FakeSink {
    var probe: FakeProbe = .{ .pattern = pattern };
    var sink: FakeSink = .{};
    const status: ports.StatusSink = .{ .context = &sink, .observe_fn = ignoreStatus };

    var app = Engine.init(
        .{ true, true },
        .{
            .sample_rate = core.sample_rate,
            .poll_frames = core.sensor_frames,
            .model = .steady,
        },
        probe.source(),
        sink.port(),
        status,
        voices,
    );

    for (0..blocks) |_| try app.step();
    return sink;
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix develop -c zig build test`
Expected: FAIL, `expected 10 argument(s), found 6`.

- [ ] **Step 3: Rework the engine**

In `src/application/engine.zig`, add the import:

```zig
const voice_mod = @import("voice.zig");
```

Replace the `drone`, `plant_a_stream`, `plant_a`, `plant_b` and `clip_stream`
fields with one:

```zig
    /// One per plant, indexed as the selection is. The engine reads neither of
    /// them: it hands each its own probe and its own share of the block.
    voices: [2]voice_mod.Voice,
```

Replace `init` with the six-parameter form above, dropping `random` (a selector
arrives inside its voice) and storing `voices` directly.

Replace the two per-plant render calls in `step` with one loop:

```zig
            for (&self.voices, 0..) |*plant_voice, plant| {
                if (!self.selection[plant]) continue;
                const probe = if (plant == 0) &self.machine.a else &self.machine.bc;
                plant_voice.render(piece, probe, touched[plant]);
            }
```

Delete `renderPlantA`, the `drone` field's initialisation, and the
`core.plant_b.ClipSelector` usage. Update the existing `runPlantA` helper to
call `runVoices` with `droneVoice()` in slot 0 so the drone tests keep working.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS, including the existing drone gate tests.

- [ ] **Step 5: Commit**

```bash
nix develop -c zig fmt --check src/ build.zig
git add src/application/engine.zig
git commit -m "refactor(application): the engine holds two voices and knows nothing else"
```

---

### Task 6: The six flags

**Files:**
- Modify: `src/cli.zig`

**Interfaces:**
- Consumes: `core.source.Source` from Task 1.
- Produces: `Options.plant_sources: [2]source.Source`;
  `Options.plant_seconds: [2]?f32`; `Options.plant_retrigger: [2]?f32`;
  `Error` gains `InvalidSource`, `InvalidSeconds`, `SecondsOnDrone`;
  `Options.pool`, `Options.plant_a_clips` and `Error.InvalidPlantB` are gone.

- [ ] **Step 1: Write the failing tests**

Append to `src/cli.zig`:

```zig
test "each plant chooses its own source" {
    const opts = try parse(&.{ "--plant-a=insect", "--plant-b=tradvn" });
    try std.testing.expectEqual(source.Source.insect, opts.plant_sources[0]);
    try std.testing.expectEqual(source.Source.tradvn, opts.plant_sources[1]);
}

test "the defaults are what the installation already does" {
    const opts = try parse(&.{});
    try std.testing.expectEqual(source.Source.drone, opts.plant_sources[0]);
    try std.testing.expectEqual(source.Source.recordings, opts.plant_sources[1]);
    try std.testing.expect(opts.plant_seconds[0] == null);
    try std.testing.expect(opts.plant_retrigger[1] == null);
}

test "either plant accepts any source, including the drone" {
    try std.testing.expectEqual(
        source.Source.drone,
        (try parse(&.{"--plant-b=drone"})).plant_sources[1],
    );
    try std.testing.expectEqual(
        source.Source.bell,
        (try parse(&.{"--plant-a=bell"})).plant_sources[0],
    );
}

test "bare --plant-a still means the bird calls" {
    // A unit file already passing the flag keeps starting.
    const opts = try parse(&.{"--plant-a"});
    try std.testing.expectEqual(source.Source.daybird, opts.plant_sources[0]);
}

test "a source no folder answers to is refused" {
    try std.testing.expectError(Error.InvalidSource, parse(&.{"--plant-a=cello"}));
    try std.testing.expectError(Error.InvalidSource, parse(&.{"--plant-b="}));
}

test "both lengths can be set per plant" {
    const opts = try parse(&.{
        "--plant-a=insect",
        "--plant-a-seconds=8",
        "--plant-b-retrigger=20",
    });
    try std.testing.expectEqual(@as(f32, 8.0), opts.plant_seconds[0].?);
    try std.testing.expectEqual(@as(f32, 20.0), opts.plant_retrigger[1].?);
}

test "zero seconds is how a source is uncapped" {
    const opts = try parse(&.{ "--plant-a=bell", "--plant-a-seconds=0" });
    try std.testing.expectEqual(@as(f32, 0.0), opts.plant_seconds[0].?);
}

test "a length that is not one is refused" {
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-a-seconds=-1"}));
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-b-seconds=soon"}));
    try std.testing.expectError(Error.InvalidSeconds, parse(&.{"--plant-a-retrigger=-3"}));
}

test "a length given to the drone is refused rather than ignored" {
    // The drone has no clip to cut, so the flag can only be a typo, and a
    // silently ignored typo is how a room hears the wrong thing with no clue.
    try std.testing.expectError(
        Error.SecondsOnDrone,
        parse(&.{ "--plant-a=drone", "--plant-a-seconds=5" }),
    );
    try std.testing.expectError(
        Error.SecondsOnDrone,
        parse(&.{"--plant-b-retrigger=5"}),
    );
}
```

The last case relies on plant B defaulting to `recordings`, so write it as
`parse(&.{ "--plant-b=drone", "--plant-b-retrigger=5" })` instead.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL, `no member named 'plant_sources'`.

- [ ] **Step 3: Write the implementation**

In `src/cli.zig`, replace the `plant_b` import with `source`, replace
`InvalidPlantB` in `Error` with `InvalidSource, InvalidSeconds, SecondsOnDrone`,
and replace the `pool` and `plant_a_clips` fields:

```zig
    /// What each plant plays, indexed as the selection is. The defaults are
    /// what the installation did before either flag took a value.
    plant_sources: [2]source.Source = .{ .drone, .recordings },
    /// How long a touch plays and how long before the next one is honoured.
    /// `null` leaves the source's own answer standing.
    plant_seconds: [2]?f32 = .{ null, null },
    plant_retrigger: [2]?f32 = .{ null, null },
```

Add the parsing arms, before the catch-all `-` arm:

```zig
        } else if (std.mem.startsWith(u8, arg, "--plant-a=")) {
            opts.plant_sources[0] = source.Source.parse(arg["--plant-a=".len..]) catch
                return Error.InvalidSource;
        } else if (std.mem.startsWith(u8, arg, "--plant-b=")) {
            opts.plant_sources[1] = source.Source.parse(arg["--plant-b=".len..]) catch
                return Error.InvalidSource;
        } else if (std.mem.eql(u8, arg, "--plant-a")) {
            // The shorthand the flag had when it was a switch, kept so a unit
            // file already passing it keeps starting.
            opts.plant_sources[0] = .daybird;
        } else if (std.mem.startsWith(u8, arg, "--plant-a-seconds=")) {
            opts.plant_seconds[0] = parseSeconds(arg["--plant-a-seconds=".len..]) orelse
                return Error.InvalidSeconds;
        } else if (std.mem.startsWith(u8, arg, "--plant-b-seconds=")) {
            opts.plant_seconds[1] = parseSeconds(arg["--plant-b-seconds=".len..]) orelse
                return Error.InvalidSeconds;
        } else if (std.mem.startsWith(u8, arg, "--plant-a-retrigger=")) {
            opts.plant_retrigger[0] = parseSeconds(arg["--plant-a-retrigger=".len..]) orelse
                return Error.InvalidSeconds;
        } else if (std.mem.startsWith(u8, arg, "--plant-b-retrigger=")) {
            opts.plant_retrigger[1] = parseSeconds(arg["--plant-b-retrigger=".len..]) orelse
                return Error.InvalidSeconds;
```

Add the helper and the drone check at the end of `parse`, before `return opts`:

```zig
/// A length in seconds. Negative is not a length; zero is "to the clip's end"
/// and is deliberately allowed.
fn parseSeconds(text: []const u8) ?f32 {
    const value = std.fmt.parseFloat(f32, text) catch return null;
    return if (value >= 0.0) value else null;
}
```

```zig
    for (opts.plant_sources, 0..) |chosen, plant| {
        if (!chosen.isDrone()) continue;
        if (opts.plant_seconds[plant] != null or opts.plant_retrigger[plant] != null) {
            return Error.SecondsOnDrone;
        }
    }
```

Delete the old `--plant-b=` arm that parsed a pool. Update `usage` to list the
six flags, and update `main.zig`'s error switch: `InvalidPlantB` becomes
`InvalidSource` with the message
`"--plant-a and --plant-b take a source: drone, recordings, daybird, insect, tradvn, bell or piano.\n\n"`,
plus arms for `InvalidSeconds`
(`"--seconds and --retrigger take a number of seconds, zero or more.\n\n"`) and
`SecondsOnDrone` (`"the drone has no clip, so it takes no length.\n\n"`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
nix develop -c zig fmt --check src/ build.zig
git add src/cli.zig src/main.zig
git commit -m "feat(cli): one source and two lengths per plant"
```

---

### Task 7: One way to build a voice

**Files:**
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: everything from Tasks 1 to 6.
- Produces: nothing other code depends on. `runComposition` builds both voices
  through one helper and hands them to `Engine.init`.

- [ ] **Step 1: Replace both bespoke blocks**

In `src/main.zig`, delete the two clip-loading blocks and the two stream setups.
In their place, hold the per-plant resources in arrays so their `defer`s stay in
`runComposition`'s scope:

```zig
    var pools: [2]clip_loader.LoadedPool = .{ .empty, .empty };
    defer for (&pools) |*pool| pool.deinit(gpa);

    var streams: [2]clip_stream.Adapter = undefined;
    var stream_live: [2]bool = .{ false, false };
    defer for (&streams, stream_live) |*stream, live| {
        if (live) stream.deinit();
    };

    var voices: [2]voice_mod.Voice = .{ droneVoice(), droneVoice() };

    for (opts.plant_sources, 0..) |chosen, plant| {
        const name: []const u8 = if (plant == 0) "A" else "B";
        if (!opts.plants[plant]) {
            std.debug.print("loading: plant {s} skipped\n", .{name});
            continue;
        }
        if (chosen.isDrone()) {
            std.debug.print("loading: plant {s} is the drone\n", .{name});
            continue;
        }

        std.debug.print("loading: plant {s} clips ({t})...\n", .{ name, chosen });
        pools[plant] = clip_loader.loadPool(gpa, io, chosen) catch |err| {
            std.debug.print("no plant {s} clips: {s}\n", .{ name, @errorName(err) });
            for (clip_loader.directoriesFor(chosen)) |directory| {
                std.debug.print("  looked in ./{s}/\n", .{directory});
            }
            std.process.exit(1);
        };
        std.debug.print(
            "loading: plant {s} clips ready ({d})\n",
            .{ name, pools[plant].paths.len },
        );

        const limit: core.clips.Limit = .forSource(
            chosen,
            opts.plant_seconds[plant],
            core.sample_rate,
        );
        streams[plant] = try clip_stream.Adapter.init(io, gpa, pools[plant].paths, limit);
        stream_live[plant] = true;

        std.debug.print("loading: plant {s} clip heads...\n", .{name});
        if (streams[plant].primeHeads()) |_| {
            const megabytes: f32 =
                @as(f32, @floatFromInt(streams[plant].headBytes())) / 1024.0 / 1024.0;
            std.debug.print(
                "loading: plant {s} clip heads ready ({d:.1} MB)\n",
                .{ name, megabytes },
            );
        } else |err| {
            std.debug.print(
                "plant {s} clip heads unavailable ({s}); clips start after ffmpeg does\n",
                .{ name, @errorName(err) },
            );
        }
        try streams[plant].start();

        const retrigger = opts.plant_retrigger[plant] orelse
            chosen.defaultRetriggerSeconds();
        voices[plant] = .{ .clips = .{
            .stream = streams[plant].port(),
            .selector = .init(
                pools[plant].folders,
                retrigger,
                core.sample_rate,
                shuffle.random(),
            ),
        } };
    }
```

`shuffle` must be declared before this loop rather than after it:

```zig
    var shuffle = std.Random.DefaultPrng.init(shuffleSeed(io));
```

Add the drone helper near the bottom of the file:

```zig
/// The generated voice, with the room's preset shape.
fn droneVoice() voice_mod.Voice {
    return .{ .drone = .init(
        core.sample_rate,
        production_config.seed,
        production_config.drone,
    ) };
}
```

Add the import `const voice_mod = @import("application/voice.zig");` and hand
the voices to the engine:

```zig
    var app = engine.Engine.init(
        opts.plants,
        production_config.touchWith(opts.model, opts.still_range, opts.still_release),
        probe.source(),
        sink_port,
        status.port(),
        voices,
    );
```

- [ ] **Step 2: Build and run both configurations**

Run:

```bash
nix develop -c zig build
timeout 60 nix develop -c ./zig-out/bin/mami_sound 12 --test-random-probe --device=null
timeout 60 nix develop -c ./zig-out/bin/mami_sound 12 --test-random-probe --device=null \
  --plant-a=insect --plant-b=tradvn
```

Expected: the first prints `plant A is the drone` and loads 21 plant B clips.
The second loads 5 insect clips and 4 tradvn clips, prints a head size for each,
and reaches `loading: complete`.

- [ ] **Step 3: Run the tests**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
nix develop -c zig fmt --check src/ build.zig
git add src/main.zig
git commit -m "refactor(main): build both plants' voices the same way"
```

---

### Task 8: The new sources sound for the length they were given

**Files:**
- Modify: `src/clip_stream_integration_test.zig`

**Interfaces:**
- Consumes: `core.clips.Limit.forSource`, `core.source.Source`, `library.listSorted`.
- Produces: nothing other code depends on.

- [ ] **Step 1: Write the failing tests**

Append to `src/clip_stream_integration_test.zig`:

```zig
test "a capped source sounds for the length it was given" {
    // insect is cut at five seconds. The folder holds recordings of up to
    // forty, so this is entirely down to the cap holding.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const paths = try library.listSorted(gpa, io, "Insect");
    defer library.freeList(gpa, paths);
    try std.testing.expect(paths.len > 0);

    const limit: core.clips.Limit = .forSource(.insect, null, 44100);
    var adapter = try clip_stream.Adapter.init(io, gpa, &.{paths[0]}, limit);
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    var sounded: usize = 0;
    var drained: usize = 0;
    while (drained < 44100 * 10) : (drained += block.len) {
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
        for (block) |sample| {
            if (sample != 0.0) sounded += 1;
        }
    }

    const seconds = @as(f32, @floatFromInt(sounded)) / 44100.0;
    try std.testing.expect(seconds >= 4.0);
    try std.testing.expect(seconds <= 5.5);
    try std.testing.expect(!port.sounding());
}

test "a source that runs to its end is still sounding past five seconds" {
    // tradvn plays the whole jam. Its guard, not a cut, is what stops the next
    // hand restarting it, so at eight seconds it must still be playing.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const paths = try library.listSorted(gpa, io, "Trad Vn Jam");
    defer library.freeList(gpa, paths);
    try std.testing.expect(paths.len > 0);

    const limit: core.clips.Limit = .forSource(.tradvn, null, 44100);
    try std.testing.expectEqual(core.clips.Limit.unlimited.total, limit.total);

    var adapter = try clip_stream.Adapter.init(io, gpa, &.{paths[0]}, limit);
    defer adapter.deinit();
    try adapter.primeHeads();
    try adapter.start();

    var port = adapter.port();
    var block = [_]f32{0.0} ** 512;
    port.render(&block, 0);

    std.Io.sleep(io, .fromNanoseconds(500 * std.time.ns_per_ms), .awake) catch {};

    var drained: usize = 0;
    while (drained < 44100 * 8) : (drained += block.len) {
        std.Io.sleep(io, .fromNanoseconds(2 * std.time.ns_per_ms), .awake) catch {};
        @memset(&block, 0);
        port.render(&block, null);
    }
    try std.testing.expect(port.sounding());
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nix develop -c zig build test`
Expected: PASS, because Tasks 1 to 3 have already put the cap in place. That
makes these characterisation tests rather than red-green ones, so prove they
bite before trusting them: change `Source.defaultSeconds` for `.insect` to
`null` in `src/core/source.zig`, run the suite, and confirm
`a capped source sounds for the length it was given` fails with a duration near
forty seconds. Put the `5.0` back and confirm it passes again.

- [ ] **Step 3: Run the tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS.

- [ ] **Step 4: Verify the whole suite and the formatting**

Run:

```bash
nix develop -c zig build test
nix develop -c zig build
nix develop -c zig fmt --check src/ build.zig
```

Expected: all three exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/clip_stream_integration_test.zig
git commit -m "test: the new sources sound for the length they were given"
```

---

### Task 9: Bound what the head cache pre-decodes

**Files:**
- Modify: `src/adapters/clip_heads.zig`

**Interfaces:**
- Consumes: `core.clips.Limit` from Task 2.
- Produces: `pub const whole_pool_limit_s: f32 = 8.0;` — the play length at or
  under which a source is decoded whole rather than headed.

This task is independent of Tasks 4 to 8 and can be done at any point after
Task 2.

- [ ] **Step 1: Write the failing test**

Append to `src/adapters/clip_heads.zig`:

```zig
test "a long allowance keeps a head rather than the whole clip" {
    // `--plant-a-seconds=60` on a folder of five must not ask for fifty
    // megabytes. Past the bound a clip keeps its two-second head and the
    // streamer carries the rest, exactly as an uncapped source does.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const paths = try library.listSorted(gpa, io, "Insect");
    defer library.freeList(gpa, paths);

    const long: core.clips.Limit = .forSource(.insect, 60.0, 44100);
    var heads = try decode(gpa, io, &.{paths[0]}, long, 44100);
    defer heads.deinit(gpa);

    const head_samples: usize = @intFromFloat(head_s * 44100.0);
    try std.testing.expectEqual(head_samples, heads.get(0).len);
}

test "a short allowance is still taken whole" {
    // The property that keeps ffmpeg out of the touch path for the stems and
    // the five-second sources: their clips are already in memory.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const paths = try library.listSorted(gpa, io, "Insect");
    defer library.freeList(gpa, paths);

    const short: core.clips.Limit = .forSource(.insect, null, 44100);
    var heads = try decode(gpa, io, &.{paths[0]}, short, 44100);
    defer heads.deinit(gpa);

    try std.testing.expectEqual(short.total, heads.get(0).len);
}
```

- [ ] **Step 2: Run the tests to verify the first fails**

Run: `nix develop -c zig build test`
Expected: FAIL on `a long allowance keeps a head rather than the whole clip`,
with `expected 88200, found 2646000` — the whole sixty seconds was decoded.

- [ ] **Step 3: Write the implementation**

In `src/adapters/clip_heads.zig`, add the constant next to `head_s`:

```zig
/// The longest allowance still worth holding whole.
///
/// A capped source is pre-decoded entirely so a touch never waits on `ffmpeg`,
/// and for four or five seconds across a folder that is a few megabytes. The
/// command line can ask for any length though, and `--plant-a-seconds=60`
/// across five clips would be fifty. Past this bound a clip keeps its head and
/// the streamer carries the rest, which is what an uncapped source has always
/// done.
pub const whole_pool_limit_s: f32 = 8.0;
```

Replace the `want` computation inside `decode`:

```zig
    const head_samples: usize = @intFromFloat(head_s * @as(f32, @floatFromInt(sample_rate)));
    const whole_limit: usize =
        @intFromFloat(whole_pool_limit_s * @as(f32, @floatFromInt(sample_rate)));

    // A capped source short enough to hold is taken whole; anything longer,
    // capped or not, keeps a head and streams the remainder.
    const want = if (limit.total <= whole_limit) limit.total else head_samples;
```

Note this also replaces the old `limit.total == unlimited.total` comparison:
an unlimited total is `maxInt(usize)`, which is comfortably past the bound, so
it takes the head branch as before.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS, including the existing
`a capped pool is pre-decoded whole, not just to the head length`.

- [ ] **Step 5: Commit**

```bash
nix develop -c zig fmt --check src/ build.zig
git add src/adapters/clip_heads.zig
git commit -m "perf(adapters): bound what a head cache holds whole"
```

---

## Verification

After every task, the whole suite must be green — these are not
task-local checks:

```bash
nix develop -c zig build test
nix develop -c zig build
nix develop -c zig fmt --check src/ build.zig
```

And the two configurations that matter in the room:

```bash
./zig-out/bin/mami_sound 12 --test-random-probe --device=null
./zig-out/bin/mami_sound 12 --test-random-probe --device=null --plant-a=insect --plant-b=tradvn
```
