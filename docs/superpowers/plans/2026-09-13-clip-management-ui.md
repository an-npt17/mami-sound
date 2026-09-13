# Clip Management UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let museum staff add and remove the recordings a plant plays from a web page on the Pi, with no rebuild, no ssh, and no restart of the installation.

**Architecture:** Two processes on one box, talking through two files in `/home/pi/mami-sound/`. A Python `http.server` writes clip folders and leaves a `reload.request`; the Zig installation picks it up, builds the replacement pool on a helper thread, swaps the plant's voice between render blocks while that plant is silent, and writes `reload.result` back. No lock ever enters the render path: each streamer stays write-once and what changes is which streamer a plant points at.

**Tech Stack:** Zig 0.16.0 (cross-compiled `-Dtarget=aarch64-linux`), Python 3 standard library only (`http.server`, `json`, `email` for multipart), uv for the dev/test environment, systemd, ffprobe.

**Spec:** `docs/superpowers/specs/2026-09-13-clip-management-ui-design.md`

## Global Constraints

- **Seven clip folders, never eight.** `drone` is generated and has no folder (`src/adapters/clip_loader.zig:74` is `unreachable`). The seven are `voicebox3`, `voicebox5`, `daybird`, `insect`, `tradvn`, `bell`, `piano`.
- **Folder names are owned by `clip_loader.directoriesFor`.** Nothing else may spell them. Python reads them from a generated list, never a hand-copied one.
- **The render path takes no locks and allocates nothing.** Staging, decoding, and teardown all happen on a helper thread.
- **An empty pool is refused, never fatal.** `src/main.zig:158` exits on `NoAudioFiles` at startup; that behaviour is correct there and must NOT be reached by a reload.
- **A swap happens only while that plant is untouched and not sounding.**
- **Both files are written to a temp name in the same directory and renamed into place.** Readers never see half a file.
- **No authentication; bind to the LAN address only.** Recorded as a deliberate risk in the spec.
- **Python: standard library only.** No Flask, no pip installs on the Pi. ~13 MB RSS on a 512 MB board.
- **Zig target for deploy:** `zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast`.
- **`zig build test` takes >10 minutes** (it decodes real folders through ffmpeg). Use `zig build test-core` for the fast loop and run the full suite once before deploy.
- **Build via `nix develop`.** The real binary is `/run/current-system/sw/bin/nix` — `nix` is a shell function locally, which breaks under `timeout`.

## The file protocol

Both files live in `/home/pi/mami-sound/`, the shared `WorkingDirectory`.

`reload.request`, written by Python, deleted by Zig once read:

```json
{"id": "20260913T185301Z-a1b2c3", "sources": ["piano", "insect"]}
```

`reload.result`, written by Zig, read by Python:

```json
{"id": "20260913T185301Z-a1b2c3",
 "outcomes": [{"source": "piano", "status": "applied", "clips": 9, "detail": ""},
              {"source": "insect", "status": "refused", "clips": 0, "detail": "folder holds no playable clips"}]}
```

`status` is exactly one of `applied`, `refused`, `not_playing`, `failed`. `not_playing` means the source is real but no plant is currently playing it — the files were still written and the next start picks them up. It is not an error.

---

# Phase 1 — the installation reloads a pool

## Task 1: The request/result protocol, parsed and serialised

**Files:**
- Create: `src/adapters/reload_protocol.zig`
- Modify: `src/adapters/root.zig`
- Test: in-file `test` blocks (this repo's convention)

**Interfaces:**
- Consumes: `core.source.Source` from `src/core/source.zig`
- Produces:
  - `pub const Status = enum { applied, refused, not_playing, failed }`
  - `pub const max_sources: usize = 7`
  - `pub const Request = struct { id: [64]u8, id_len: usize, sources: [max_sources]core.source.Source, count: usize }`
  - `pub const Outcome = struct { source: core.source.Source, status: Status, clips: usize, detail: []const u8 }`
  - `pub fn parseRequest(text: []const u8) ParseError!Request`
  - `pub fn writeResult(w: *std.Io.Writer, id: []const u8, outcomes: []const Outcome) !void`

- [ ] **Step 1: Write the failing test**

```zig
test "a request names its id and its sources" {
    const req = try parseRequest(
        \\{"id": "20260913T185301Z-a1b2c3", "sources": ["piano", "insect"]}
    );
    try std.testing.expectEqualStrings("20260913T185301Z-a1b2c3", req.id[0..req.id_len]);
    try std.testing.expectEqual(@as(usize, 2), req.count);
    try std.testing.expectEqual(core.source.Source.piano, req.sources[0]);
    try std.testing.expectEqual(core.source.Source.insect, req.sources[1]);
}

test "a source no folder answers to is refused, not guessed at" {
    try std.testing.expectError(
        ParseError.UnknownSource,
        parseRequest(
            \\{"id": "x", "sources": ["harpsichord"]}
        ),
    );
}

test "the drone is not a reloadable source" {
    // It has no folder at all; asking to reload it is a bug in the caller,
    // not an empty pool.
    try std.testing.expectError(
        ParseError.UnknownSource,
        parseRequest(
            \\{"id": "x", "sources": ["drone"]}
        ),
    );
}

test "a truncated request is refused rather than half-read" {
    try std.testing.expectError(
        ParseError.Malformed,
        parseRequest("{\"id\": \"x\", \"sources\": [\"pia"),
    );
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `/run/current-system/sw/bin/nix develop -c zig build test-adapters`
Expected: FAIL — `reload_protocol.zig` does not exist.

- [ ] **Step 3: Write the implementation**

Parse with `std.json.parseFromSlice` into a temporary struct, then map each
source name through `core.source.Source.parse`. Reject `.drone` explicitly
after parsing — `Source.parse("drone")` succeeds, and it must not here.
Cap at `max_sources`; a longer list is `ParseError.TooManySources`.

`writeResult` formats the JSON by hand into the writer (the outcome set is
tiny and fixed-shape, and this avoids an allocator on the writing side).
Escape `detail` for `"` and `\` at minimum.

- [ ] **Step 4: Run the test and watch it pass**

Run: `/run/current-system/sw/bin/nix develop -c zig build test-adapters`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/adapters/reload_protocol.zig src/adapters/root.zig
git commit -m "feat(adapters): a reload request names sources, and a result answers each one"
```

---

## Task 2: The port the engine asks between blocks

**Files:**
- Create: `src/ports/voice_reload.zig`
- Modify: `src/ports/root.zig`

**Interfaces:**
- Consumes: `ports.ClipStream` from `src/ports/clip_stream.zig`, `core.clips.ClipSelector`
- Produces:
  - `pub const Replacement = struct { stream: clip_stream.ClipStream, selector: core.clips.ClipSelector }`
  - `pub const VoiceReload = struct { context, take_fn, released_fn, pub fn take(self, plant) ?Replacement, pub fn released(self, plant) void }`

The port carries a built `ClipSelector` rather than a clip count because the
engine has neither the retrigger seconds nor the RNG to build one, and giving
it both would put composition decisions in the render loop.

`released` is how the engine says it has let go of the voice it replaced, so
the old streamer can be shut down off the render loop. It takes no stream
argument: the reloader handed the replacement over and knows what it displaced.

- [ ] **Step 1: Write the failing test**

```zig
test "a port with nothing staged hands over nothing" {
    var fake: FakeReload = .{};
    var port = fake.port();
    try std.testing.expect(port.take(0) == null);
}

test "a staged replacement is handed over once and then gone" {
    var fake: FakeReload = .{ .staged = someReplacement() };
    var port = fake.port();
    try std.testing.expect(port.take(0) != null);
    try std.testing.expect(port.take(0) == null);
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `/run/current-system/sw/bin/nix develop -c zig build test` (ports have no
test root of their own; they compile into the library module).
Expected: FAIL — `voice_reload.zig` does not exist.

- [ ] **Step 3: Write the implementation**

Follow the shape of `src/ports/clip_stream.zig` exactly: a `context:
*anyopaque` plus function pointers, with thin `pub fn` wrappers.

- [ ] **Step 4: Run the test and watch it pass**

- [ ] **Step 5: Commit**

```bash
git add src/ports/voice_reload.zig src/ports/root.zig
git commit -m "feat(ports): a plant can be handed a new pool without knowing where it came from"
```

---

## Task 3: The engine swaps, and only into silence

**Files:**
- Modify: `src/application/engine.zig` (add field, extend `init`, poll in `step`)
- Modify: `src/application/voice.zig` (add `pub fn sounding`)
- Modify: `src/main.zig` (pass `null` at the call site for now)
- Test: in-file `test` blocks in `src/application/engine.zig`

**Interfaces:**
- Consumes: `ports.VoiceReload`, `ports.Replacement` from Task 2
- Produces: `Engine.init(..., reload: ?ports.VoiceReload)` — one new trailing parameter, `null` for every existing caller

- [ ] **Step 1: Write the failing test**

```zig
test "a plant being touched keeps the pool it is playing" {
    // The swap must not cut a recording off in the room: the room cannot
    // tell that from a fault.
    var reload: FakeReload = .{ .staged = .{ replacementOf(&new_stream), null } };
    var sink = try runVoicesWithReload(heldA, guard_blocks, .{ true, false },
        .{ clipVoice(&old_stream, 0), droneVoice() }, &reload);
    _ = sink;
    try std.testing.expect(!reload.taken[0]);
}

test "a silent plant takes the new pool" {
    var reload: FakeReload = .{ .staged = .{ replacementOf(&new_stream), null } };
    _ = try runVoicesWithReload(resting, guard_blocks, .{ true, false },
        .{ clipVoice(&old_stream, 0), droneVoice() }, &reload);
    try std.testing.expect(reload.taken[0]);
    try std.testing.expect(reload.released[0]);
}

test "a plant still sounding keeps the pool it is playing" {
    var old: FakeClips = .{ .sounding = true };
    var reload: FakeReload = .{ .staged = .{ replacementOf(&new_stream), null } };
    _ = try runVoicesWithReload(resting, guard_blocks, .{ true, false },
        .{ clipVoice(&old, 0), droneVoice() }, &reload);
    try std.testing.expect(!reload.taken[0]);
}

test "a plant the request did not name is left alone" {
    var reload: FakeReload = .{ .staged = .{ null, replacementOf(&new_stream) } };
    _ = try runVoicesWithReload(resting, guard_blocks, .all,
        .{ clipVoice(&old_stream, 0), clipVoice(&other, 1) }, &reload);
    try std.testing.expect(!reload.taken[0]);
    try std.testing.expect(reload.taken[1]);
}

test "a run with no reload port behaves exactly as it always has" {
    // Every existing test relies on this; null is the whole of the default.
    const before = try runVoices(resting, guard_blocks, .all, .{ droneVoice(), droneVoice() });
    const after = try runVoicesWithReload(resting, guard_blocks, .all,
        .{ droneVoice(), droneVoice() }, null);
    try std.testing.expectEqualSlices(i16, before.written.items, after.written.items);
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `/run/current-system/sw/bin/nix develop -c zig build test-core` for the pure
parts, then the application tests:
`/run/current-system/sw/bin/nix develop -c zig build test` — but note this is the
slow step; prefer building just the application test binary while iterating.
Expected: FAIL — `Engine.init` takes no reload parameter.

- [ ] **Step 3: Write the implementation**

In `src/application/voice.zig`:

```zig
/// Whether this plant is still making sound. A drone always is while it is
/// fading, so only a folder of clips can answer usefully -- and only a folder
/// of clips can be reloaded.
pub fn sounding(self: *const Voice) bool {
    return switch (self.*) {
        .drone => true,
        .clips => |*c| c.stream.sounding() or c.gate != 0.0,
    };
}
```

In `src/application/engine.zig`, add `reload: ?ports.VoiceReload` as the last
field and the last `init` parameter, plus `touched_last: core.plant.Selection`
initialised to `.{ false, false }`.

At the **top** of `step`, before rendering — so the swap lands on a block
boundary and never mid-block:

```zig
if (self.reload) |*port| {
    for (&self.voices, 0..) |*plant_voice, plant| {
        if (!self.selection[plant]) continue;
        if (plant_voice.* != .clips) continue;
        if (self.touched_last[plant]) continue;
        if (plant_voice.sounding()) continue;
        const replacement = port.take(plant) orelse continue;
        plant_voice.clips.stream = replacement.stream;
        plant_voice.clips.selector = replacement.selector;
        plant_voice.clips.loaded = false;
        // The old streamer is never deinitialised here: `deinit` joins the
        // ffmpeg worker, and a join on the render loop is a dropout.
        port.released(plant);
    }
}
```

At the end of `step`, record `self.touched_last = touched;`.

- [ ] **Step 4: Run the tests and watch them pass**

- [ ] **Step 5: Commit**

```bash
git add src/application/engine.zig src/application/voice.zig src/main.zig
git commit -m "feat(application): a plant takes a new pool between blocks, and only into silence"
```

---

## Task 4: The reloader — staging and teardown, both off the render loop

**Files:**
- Create: `src/adapters/pool_reloader.zig`
- Modify: `src/adapters/root.zig`

**Interfaces:**
- Consumes: `reload_protocol` (Task 1), `ports.VoiceReload` (Task 2), `clip_loader.loadPool`, `clip_stream.Adapter`
- Produces:
  - `pub const Adapter = struct { pub fn init(gpa, io, dir, plant_sources, plant_limits, plant_retrigger, seed) !Adapter, pub fn start(self) !void, pub fn deinit(self) void, pub fn port(self) ports.VoiceReload }`

The helper thread does all four slow things: polling for the request file,
`loadPool`, `primeHeads`, and `deinit` of displaced streamers. `take` and
`released` are called from the render loop and must never block — they touch
only atomics.

- [ ] **Step 1: Write the failing test**

```zig
test "a request for a source no plant plays is answered, not dropped" {
    // Not an error: the files were written and the next start picks them up.
    // Reporting success for a swap that did not happen is the bug.
    var reloader = try Adapter.init(gpa, io, tmp_dir, .{ .drone, .piano }, ...);
    defer reloader.deinit();
    try writeRequest(tmp_dir, "id-1", &.{.insect});
    try reloader.pumpOnce();
    const result = try readResult(tmp_dir);
    try std.testing.expectEqual(Status.not_playing, result.outcomes[0].status);
}

test "a folder that would leave no clips is refused and the old pool stands" {
    var reloader = try Adapter.init(gpa, io, empty_folder_dir, .{ .drone, .piano }, ...);
    defer reloader.deinit();
    try writeRequest(empty_folder_dir, "id-2", &.{.piano});
    try reloader.pumpOnce();
    const result = try readResult(empty_folder_dir);
    try std.testing.expectEqual(Status.refused, result.outcomes[0].status);
    // And nothing was staged for the engine to take.
    var p = reloader.port();
    try std.testing.expect(p.take(1) == null);
}

test "the request file is consumed so it is not applied twice" {
    try writeRequest(tmp_dir, "id-3", &.{.piano});
    try reloader.pumpOnce();
    try std.testing.expect(!fileExists(tmp_dir, "reload.request"));
}

test "take is empty until staging has finished" {
    // The engine must never be handed a half-built pool.
    var p = reloader.port();
    try std.testing.expect(p.take(1) == null);
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `/run/current-system/sw/bin/nix develop -c zig build test-adapters`
Expected: FAIL — `pool_reloader.zig` does not exist.

- [ ] **Step 3: Write the implementation**

Per plant, a staging slot guarded by a release/acquire flag:

```zig
const Slot = struct {
    ready: std.atomic.Value(bool),     // release on publish, acquire on take
    released: std.atomic.Value(bool),  // engine has let go of the displaced one
    staged: ?*clip_stream.Adapter,     // written before `ready` is set
    selector: core.clips.ClipSelector,
    live: ?*clip_stream.Adapter,       // what the engine is playing now
    retiring: ?*clip_stream.Adapter,   // displaced, awaiting teardown
};
```

`take` does an acquire load of `ready`; if set, it clears `ready`, moves
`staged` to `live` and the old `live` to `retiring`, and returns the
replacement. `released` sets the `released` flag. Both are pure atomic work.

The worker loop, once per second:
1. If `released` is set for a plant, `deinit` and free `retiring`, clear both.
2. Stat `reload.request`. If absent, continue.
3. Read it, `parseRequest`, delete the file.
4. For each named source: find the plant playing it (`plant_sources`); if
   none, record `not_playing`. Otherwise `loadPool`; on `NoAudioFiles` record
   `refused` **without exiting** — this is the one place the startup rule at
   `src/main.zig:158` must not apply. On success build a `clip_stream.Adapter`
   on the heap, `primeHeads`, `start`, build the selector from the recorded
   retrigger seconds and a fresh RNG, write `staged`, then release-store `ready`.
5. Write `reload.result` to `reload.result.tmp` and rename it into place.

`pumpOnce` is the worker body without the loop, exported so the tests above
drive it deterministically with no thread and no sleeping.

- [ ] **Step 4: Run the tests and watch them pass**

- [ ] **Step 5: Commit**

```bash
git add src/adapters/pool_reloader.zig src/adapters/root.zig
git commit -m "feat(adapters): pools are rebuilt and retired on a helper thread, never on the render loop"
```

---

## Task 5: Wire it into the installation

**Files:**
- Modify: `src/main.zig` (build the reloader, pass its port to `Engine.init`)
- Modify: `src/cli.zig` (add `--reload-dir=PATH`, default off)
- Test: in-file `test` blocks in `src/cli.zig`

**Interfaces:**
- Consumes: `pool_reloader.Adapter` (Task 4)
- Produces: `Options.reload_dir_buf` / `reload_dir_len` / `pub fn reloadDir(self) ?[]const u8`

Off by default, exactly like `--capture`. A run that was not given a directory
builds no reloader, passes `null`, and is the program as it is today.

- [ ] **Step 1: Write the failing test**

```zig
test "a run is given somewhere to watch, or watches nothing" {
    const off = try parse(&.{});
    try std.testing.expect(off.reloadDir() == null);

    const on = try parse(&.{"--reload-dir=."});
    try std.testing.expectEqualStrings(".", on.reloadDir().?);
}

test "a reload directory longer than a path is refused" {
    const long = "--reload-dir=" ++ ("x" ** (path_max + 1));
    try std.testing.expectError(Error.InvalidReloadDir, parse(&.{long}));
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `/run/current-system/sw/bin/nix develop -c zig build test-cli` — add this
step to `build.zig` beside `test-core` if it is not there; `run_cli_tests`
already exists at `build.zig:96`.
Expected: FAIL — `InvalidReloadDir` is not a member of `Error`.

- [ ] **Step 3: Write the implementation**

Follow `--capture` at `src/cli.zig` exactly: fixed buffer, length, accessor.
In `main.zig`, after the streams are started and before `Engine.init`, build
the reloader when `opts.reloadDir()` is set, `start` it, `defer deinit`, and
pass `reloader.port()`.

- [ ] **Step 4: Run the tests and watch them pass**

- [ ] **Step 5: Run the full suite once, then commit**

```bash
/run/current-system/sw/bin/nix develop -c zig build test    # slow: >10 min
git add src/main.zig src/cli.zig build.zig
git commit -m "feat: a run may be told where to watch for a reload request"
```

---

## Task 6: Prove it on the Pi

**Files:**
- Modify: `mami-sound.service` (add `--reload-dir=/home/pi/mami-sound`)

- [ ] **Step 1: Cross-compile**

```bash
cd /home/annpt/Museum/mami-sound
/run/current-system/sw/bin/nix develop -c zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast --prefix zig-out-pi
file zig-out-pi/bin/mami_sound   # expect: ELF 64-bit ... ARM aarch64, statically linked
```

- [ ] **Step 2: Back up and ship**

```bash
ssh Mami-Sound2 'cp ~/mami-sound/zig-out/bin/mami_sound ~/mami-sound/zig-out/bin/mami_sound.bak'
scp zig-out-pi/bin/mami_sound Mami-Sound2:/home/pi/mami-sound/zig-out/bin/mami_sound.new
scp mami-sound.service Mami-Sound2:/tmp/mami-sound.service
```

- [ ] **Step 3: Install and restart**

```bash
ssh Mami-Sound2 '
  sudo systemctl stop mami-sound.service
  mv ~/mami-sound/zig-out/bin/mami_sound.new ~/mami-sound/zig-out/bin/mami_sound
  chmod +x ~/mami-sound/zig-out/bin/mami_sound
  sudo cp /tmp/mami-sound.service /etc/systemd/system/mami-sound.service
  sudo systemctl daemon-reload
  sudo systemctl start mami-sound.service'
```

- [ ] **Step 4: Drop a request by hand and watch the swap**

```bash
ssh Mami-Sound2 '
  cd ~/mami-sound
  cp "EPiano Stems/$(ls "EPiano Stems" | head -1)" "EPiano Stems/zz-added-by-hand.mp3"
  printf "{\"id\":\"hand-1\",\"sources\":[\"piano\"]}" > reload.request.tmp
  mv reload.request.tmp reload.request
  sleep 20
  cat reload.result; echo
  sudo journalctl -u mami-sound.service --since "-1 min" --no-pager | tail -20'
```

Expected: `reload.result` shows `"status": "applied"` with a `clips` count one
higher than the startup line, the journal shows no restart, and
`systemctl show -p NRestarts` is unchanged.

- [ ] **Step 5: Commit**

```bash
git add mami-sound.service
git commit -m "feat: the installation watches its working directory for a reload request"
```

---

# Phase 2 — the web page

## Task 7: The folder list, generated rather than copied

**Files:**
- Create: `clips_ui/pyproject.toml`, `clips_ui/src/clips_ui/__init__.py`, `clips_ui/src/clips_ui/folders.py`
- Create: `clips_ui/tests/test_folders.py`
- Create: `tools/dump_sources.zig` (prints the seven name/folder pairs as JSON)

**Interfaces:**
- Produces:
  - `SOURCES: dict[str, str]` — source name to folder name, loaded from `sources.json`
  - `def folder_for(root: Path, source: str) -> Path` — raises `UnknownSource`
  - `def safe_target(root: Path, source: str, filename: str) -> Path` — raises `UnsafeName`
  - `AUDIO_EXTENSIONS: frozenset[str]`
  - `def is_audio(name: str) -> bool`

Generated, because the Global Constraints say `clip_loader.directoriesFor`
owns these names. A hand-copied list is a second source of truth that will
drift the first time a folder is renamed — and they have been renamed once
already.

- [ ] **Step 1: Write the failing test**

```python
def test_every_source_maps_to_a_folder():
    assert len(SOURCES) == 7
    assert "drone" not in SOURCES          # generated, has no folder at all
    assert SOURCES["piano"] == "EPiano Stems"

def test_an_unknown_source_is_refused():
    with pytest.raises(UnknownSource):
        folder_for(Path("/srv"), "harpsichord")

@pytest.mark.parametrize("evil", [
    "../../etc/passwd", "..", "/etc/passwd", "a/../../b", "", ".", "x\x00y",
])
def test_traversal_is_refused(evil):
    with pytest.raises(UnsafeName):
        safe_target(Path("/srv"), "piano", evil)

def test_a_plain_name_lands_in_its_folder():
    assert safe_target(Path("/srv"), "piano", "new.mp3") == Path("/srv/EPiano Stems/new.mp3")

def test_leading_dot_is_not_audio():
    # Hidden files and the ._name resource forks a macOS machine leaves on a
    # USB stick are not audio however they are named.
    assert not is_audio("._track.mp3")
    assert is_audio("track.MP3")
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd clips_ui && uv run pytest tests/test_folders.py -v`
Expected: FAIL — `clips_ui.folders` does not exist.

- [ ] **Step 3: Write the implementation**

`tools/dump_sources.zig` imports `clip_loader.directoriesFor` and prints
`{"piano": "EPiano Stems", ...}` for the seven non-drone sources. Add a
`dump-sources` step to `build.zig`. `folders.py` loads the JSON it produces.

`safe_target` takes `Path(filename).name`, then rejects empty, `.`, `..`,
anything containing a separator or a NUL, and anything starting with `.`.
Resolve the result and assert it is inside the folder.

`AUDIO_EXTENSIONS` mirrors `src/adapters/library.zig:19` — `.mp3 .wav .ogg
.opus .flac .m4a .aac .aif .aiff .wma` — matched case-insensitively.

- [ ] **Step 4: Run the tests and watch them pass**

- [ ] **Step 5: Commit**

```bash
git add clips_ui tools/dump_sources.zig build.zig
git commit -m "feat(clips-ui): the folder list is generated from the loader, not copied"
```

---

## Task 8: Writing a request and reading the result back

**Files:**
- Create: `clips_ui/src/clips_ui/protocol.py`, `clips_ui/tests/test_protocol.py`

**Interfaces:**
- Produces:
  - `def new_request_id() -> str`
  - `def write_request(root: Path, request_id: str, sources: list[str]) -> None`
  - `def read_result(root: Path, request_id: str) -> Result | None` — `None` while the installation has not answered this id yet
  - `@dataclass Result: id: str; outcomes: list[Outcome]`
  - `@dataclass Outcome: source: str; status: str; clips: int; detail: str`

- [ ] **Step 1: Write the failing test**

```python
def test_a_request_is_renamed_into_place(tmp_path):
    write_request(tmp_path, "id-1", ["piano"])
    assert json.loads((tmp_path / "reload.request").read_text()) == {
        "id": "id-1", "sources": ["piano"]}
    assert not list(tmp_path.glob("*.tmp"))   # no temp file left behind

def test_a_result_for_another_request_is_not_mine(tmp_path):
    (tmp_path / "reload.result").write_text(
        '{"id": "older", "outcomes": []}')
    assert read_result(tmp_path, "id-1") is None

def test_a_matching_result_is_returned(tmp_path):
    (tmp_path / "reload.result").write_text(json.dumps({
        "id": "id-1",
        "outcomes": [{"source": "piano", "status": "applied",
                      "clips": 9, "detail": ""}]}))
    result = read_result(tmp_path, "id-1")
    assert result.outcomes[0].status == "applied"
    assert result.outcomes[0].clips == 9

def test_a_half_written_result_reads_as_not_ready(tmp_path):
    # Should never happen -- the installation renames into place -- but a
    # crash mid-write must not raise into the page.
    (tmp_path / "reload.result").write_text('{"id": "id-1", "outc')
    assert read_result(tmp_path, "id-1") is None
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `cd clips_ui && uv run pytest tests/test_protocol.py -v`

- [ ] **Step 3: Write the implementation**

`write_request` writes `reload.request.tmp` in the same directory then
`os.replace`s it. `read_result` catches `FileNotFoundError` and
`json.JSONDecodeError` and returns `None` for both.

- [ ] **Step 4: Run the tests and watch them pass**

- [ ] **Step 5: Commit**

```bash
git add clips_ui/src/clips_ui/protocol.py clips_ui/tests/test_protocol.py
git commit -m "feat(clips-ui): requests are renamed into place and results matched by id"
```

---

## Task 9: An upload is decoded before it is accepted

**Files:**
- Create: `clips_ui/src/clips_ui/audio.py`, `clips_ui/tests/test_audio.py`

**Interfaces:**
- Produces: `def is_decodable(path: Path, *, runner=subprocess.run) -> bool`

An extension check is not the same question as whether ffmpeg can read it. An
undecodable file in a pool becomes a slot in the rotation that plays nothing —
the exact failure `src/adapters/clip_loader.zig:86` says must not happen.

- [ ] **Step 1: Write the failing test**

```python
def test_a_file_ffprobe_reads_is_accepted(tmp_path):
    calls = []
    def fake(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout="audio\n", stderr="")
    assert is_decodable(tmp_path / "a.mp3", runner=fake)
    assert "ffprobe" in calls[0][0]

def test_a_file_ffprobe_rejects_is_refused(tmp_path):
    def fake(cmd, **kw):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="invalid data")
    assert not is_decodable(tmp_path / "a.mp3", runner=fake)

def test_a_file_with_no_audio_stream_is_refused(tmp_path):
    # A video container with only a video stream has a valid header and no
    # sound in it.
    def fake(cmd, **kw):
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
    assert not is_decodable(tmp_path / "a.mp4", runner=fake)

def test_ffprobe_hanging_is_refused_not_waited_on(tmp_path):
    def fake(cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, 10)
    assert not is_decodable(tmp_path / "a.mp3", runner=fake)
```

- [ ] **Step 2: Run the test and watch it fail**

- [ ] **Step 3: Write the implementation**

```python
def is_decodable(path, *, runner=subprocess.run):
    try:
        done = runner(
            ["ffprobe", "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=codec_type", "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, timeout=30)
    except (subprocess.TimeoutExpired, OSError):
        return False
    return done.returncode == 0 and "audio" in done.stdout
```

- [ ] **Step 4: Run the tests and watch them pass**

- [ ] **Step 5: Commit**

```bash
git add clips_ui/src/clips_ui/audio.py clips_ui/tests/test_audio.py
git commit -m "feat(clips-ui): an upload is decoded before it reaches a pool"
```

---

## Task 10: Staging — what is pending, and what Apply does with it

**Files:**
- Create: `clips_ui/src/clips_ui/staging.py`, `clips_ui/tests/test_staging.py`

**Interfaces:**
- Produces:
  - `@dataclass Pending: adds: dict[str, list[Path]]; removes: dict[str, list[str]]`
  - `class Staging: def stage_add(source, tmp_path, filename); def stage_remove(source, filename); def pending_for(source) -> Pending; def would_empty(source, live_names) -> bool; def apply(root) -> str` (returns the request id)

Changes stage rather than apply, so staff can upload three and delete two and
press Apply once. A page that shows a file the installation is not yet playing
has to say so.

- [ ] **Step 1: Write the failing test**

```python
def test_staged_changes_do_not_touch_the_folder_until_apply(tmp_path):
    s = Staging(); s.stage_remove("piano", "old.mp3")
    assert (tmp_path / "EPiano Stems" / "old.mp3").exists()

def test_apply_deletes_and_moves_then_writes_one_request(tmp_path):
    s = Staging()
    s.stage_add("piano", upload, "new.mp3")
    s.stage_remove("piano", "old.mp3")
    request_id = s.apply(tmp_path)
    assert (tmp_path / "EPiano Stems" / "new.mp3").exists()
    assert not (tmp_path / "EPiano Stems" / "old.mp3").exists()
    assert json.loads((tmp_path / "reload.request").read_text())["sources"] == ["piano"]

def test_removing_every_clip_is_caught_before_anything_is_deleted():
    s = Staging()
    s.stage_remove("piano", "a.mp3"); s.stage_remove("piano", "b.mp3")
    assert s.would_empty("piano", ["a.mp3", "b.mp3"])

def test_an_add_offsets_a_remove():
    s = Staging()
    s.stage_remove("piano", "a.mp3"); s.stage_add("piano", upload, "new.mp3")
    assert not s.would_empty("piano", ["a.mp3"])

def test_apply_names_only_the_sources_that_changed():
    s = Staging(); s.stage_add("insect", upload, "x.wav")
    assert json.loads(...)["sources"] == ["insect"]
```

- [ ] **Step 2: Run the test and watch it fail**

- [ ] **Step 3: Write the implementation**

`would_empty` is checked in `apply` for every touched source **before any
file is moved or deleted**, and raises `WouldEmptyPool` naming the folder.
This is the page's own guard; the installation refusing the reload afterwards
is the second line, not the first.

- [ ] **Step 4: Run the tests and watch them pass**

- [ ] **Step 5: Commit**

```bash
git add clips_ui/src/clips_ui/staging.py clips_ui/tests/test_staging.py
git commit -m "feat(clips-ui): changes stage, and Apply refuses to empty a pool"
```

---

## Task 11: The server and the page

**Files:**
- Create: `clips_ui/src/clips_ui/server.py`, `clips_ui/src/clips_ui/page.py`
- Create: `clips_ui/tests/test_server.py`

**Interfaces:**
- Produces: `def build_server(root: Path, bind: str, port: int) -> ThreadingHTTPServer`
- Routes: `GET /` (page), `GET /list/<source>` (JSON), `GET /download/<source>/<name>`, `POST /upload/<source>` (multipart), `POST /remove/<source>/<name>`, `POST /apply`, `GET /status/<request_id>`

- [ ] **Step 1: Write the failing test**

```python
def test_an_unknown_folder_is_a_404_not_a_new_pool(client):
    assert client.get("/list/harpsichord").status == 404

def test_a_traversal_upload_is_refused(client):
    assert client.post("/upload/piano", files={"f": ("../../evil.mp3", b"x")}).status == 400

def test_an_undecodable_upload_leaves_the_folder_untouched(client, tmp_path, no_decode):
    before = set((tmp_path / "EPiano Stems").iterdir())
    assert client.post("/upload/piano", files={"f": ("bad.mp3", b"x")}).status == 400
    assert set((tmp_path / "EPiano Stems").iterdir()) == before

def test_upload_is_refused_when_the_disk_is_nearly_full(client, full_disk):
    # An SD card that fills corrupts in ways worse than a refused upload.
    assert client.post("/upload/piano", files={"f": ("a.mp3", b"x")}).status == 507

def test_download_returns_the_bytes(client):
    r = client.get("/download/piano/existing.mp3")
    assert r.status == 200 and r.body == (tmp_path / "EPiano Stems" / "existing.mp3").read_bytes()

def test_apply_that_would_empty_a_pool_is_refused(client):
    client.post("/remove/piano/a.mp3"); client.post("/remove/piano/b.mp3")
    r = client.post("/apply")
    assert r.status == 409 and "no clips" in r.json()["detail"]
```

- [ ] **Step 2: Run the test and watch it fail**

- [ ] **Step 3: Write the implementation**

`ThreadingHTTPServer` with a `BaseHTTPRequestHandler` subclass. Parse
multipart with `email.parser.BytesParser` — stream the part to a
`NamedTemporaryFile` in the same filesystem as the target so the final move is
a rename, not a copy.

Check free space with `shutil.disk_usage(root)` before writing; refuse with
507 below a 200 MB floor.

`page.py` returns one self-contained HTML string: a source picker across the
seven folders, a table of live files with size and a download link and a
remove button, a multi-file chooser, a pending list, and an Apply button that
polls `GET /status/<id>` until the result arrives.

- [ ] **Step 4: Run the tests and watch them pass**

- [ ] **Step 5: Commit**

```bash
git add clips_ui/src/clips_ui/server.py clips_ui/src/clips_ui/page.py clips_ui/tests/test_server.py
git commit -m "feat(clips-ui): a page for adding and removing what a plant plays"
```

---

## Task 12: Ship it

**Files:**
- Create: `mami-clips.service`

- [ ] **Step 1: Write the unit**

```ini
[Unit]
Description=Mami clip management UI
After=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/mami-sound
ExecStart=/usr/bin/python3 -m clips_ui --root /home/pi/mami-sound --bind ${MAMI_CLIPS_BIND} --port 8080
Environment=MAMI_CLIPS_BIND=127.0.0.1
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**The bind address is a decision, not a default.** It ships as `127.0.0.1`,
which reaches nobody, so that a wrong value is a UI that does not work rather
than a UI that is exposed. There is no authentication, so whoever can reach
the port can delete every clip in every pool. Pick one before enabling:

- the Tailscale address (`100.83.113.99` on Mami-Sound2) — reachable only from
  the tailnet, the tightest option, but staff must be on Tailscale
- the museum wifi address — reachable by anyone on that wifi, which is what
  the spec assumed and accepted
- `0.0.0.0` — every interface, tailnet and wifi and anything else. Do not use
  this while there is no authentication.

- [ ] **Step 2: Deploy**

```bash
rsync -av --delete clips_ui/src/clips_ui/ Mami-Sound2:/home/pi/mami-sound/clips_ui/
scp mami-clips.service Mami-Sound2:/tmp/
ssh Mami-Sound2 'sudo cp /tmp/mami-clips.service /etc/systemd/system/ &&
  sudo systemctl daemon-reload && sudo systemctl enable --now mami-clips.service &&
  systemctl is-active mami-clips.service'
```

- [ ] **Step 3: Walk it end to end**

Open `http://100.83.113.99:8080/`, upload a clip to EPiano Stems, press Apply,
and confirm: the page reports `applied`, `reload.result` shows a `clips` count
one higher, and `systemctl show -p NRestarts mami-sound.service` is unchanged —
the installation never restarted.

- [ ] **Step 4: Commit**

```bash
git add mami-clips.service
git commit -m "feat: a unit for the clip management UI"
```
