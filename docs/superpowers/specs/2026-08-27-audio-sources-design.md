# Audio Sources Design

## Goal

Make every audio source one kind of thing, chosen per plant on the command
line, so adding a folder is a data change rather than a code change and neither
plant knows which of them it is.

## Why now

Plant A and plant B arrived at the same capability by different routes, and the
seams show:

- `--plant-a` is a boolean (drone or not); `--plant-b` takes a pool name. Two
  shapes for the same decision.
- The `Pool` enum lives in `core/plant_b.zig` but has served plant A since the
  `daybird` folder was added, and carries a variant deliberately hidden from
  its own `parse` so `--plant-b=daybird` stays an error.
- `main.zig` holds two near-identical load-and-prime blocks.
- `Engine` special-cases plant A's drone.

Two more folders — `Insect/` and `Trad Vn Jam/` — would add a third and fourth
copy of the same wiring. The asymmetry has cost three rounds of churn already.

## Scope

- One `Source` vocabulary covering the drone and every clip folder.
- Both plants choose a source by flag; both accept every source.
- Two per-source knobs, both overridable per plant on the command line: how
  long a touch plays, and how long before the next touch is honoured.
- Add `Insect/` and `Trad Vn Jam/` as sources.
- Keep `--plant-a`, giving it the same shape as `--plant-b`: a source name.
  Bare `--plant-a` stays valid as shorthand for `--plant-a=daybird`, so nothing
  already running on a Pi has to be edited.

Out of scope: the touch detector, the acquisition path, and the clip streamer's
internals, all reused unchanged. The retrigger guard keeps its mechanism and its
tests; only its length stops being a constant.

## Sources

| source | folder | plays | retrigger guard |
|---|---|---|---|
| `drone` | — | generative | — |
| `recordings` | `interview files/` + `field records/` | to the clip's end | 10 s |
| `daybird` | `Day bird/` | 5 s | 5 s |
| `insect` | `Insect/` | 5 s | 5 s |
| `tradvn` | `Trad Vn Jam/` | to the clip's end | 5 s |
| `bell` | `Bell Stems/` | 4 s | 5 s |
| `piano` | `EPiano Stems/` | 4 s | 5 s |

The two columns are different questions and have been conflated once already.
**Plays** is how much of the clip a touch gets before it is faded out. **Guard**
is how long a clip is protected from the next touch, counted from when it
started and applying only while it is still sounding — so a source that plays
for less than its guard is never held back by it, because the clip has ended and
the plant is listening again.

A jam cut at five seconds is a fragment rather than music, so `tradvn` plays to
its own end and uses the guard instead: a hand arriving inside the first five
seconds is somebody who has just heard it start, and a hand at twenty seconds is
a room that has heard enough.

`Insect/` holds five recordings of 13.8 to 40 seconds, which is ambience rather
than a phrase, so it is cut at five like `Day bird/`: a touch answered by forty
seconds of field recording has stopped being a plant responding to a hand.
`Trad Vn Jam/` holds four of 22 to 52 seconds, and those are performances.

## Architecture

### `core/source.zig` (new)

```zig
pub const Source = enum { drone, recordings, daybird, insect, tradvn, bell, piano };
pub fn parse(name: []const u8) Error!Source
pub fn isDrone(self: Source) bool
/// How long one touch plays. `null` runs to the clip's own end.
pub fn defaultSeconds(self: Source) ?f32
/// How long a clip is protected from the next touch, from when it started.
pub fn defaultRetriggerSeconds(self: Source) f32
```

The only place a source name exists. Nothing here knows a directory: turning a
name into a folder stays on the adapter side, where it already is.

### `core/clips.zig` (renamed from `core/plant_b.zig`)

Keeps `Limit`, `ClipSelector`, `open_after_s` and the play-length constants.
Loses `Pool` to `source.zig`. The rename is the point: this module has served
both plants since the `daybird` folder landed, and its name has been lying since.

### `application/voice.zig` (new)

```zig
pub const Voice = union(enum) {
    drone: core.noise.Noise,
    clips: struct {
        stream: ports.ClipStream,
        selector: core.clips.ClipSelector,
    },

    pub fn render(
        self: *Voice,
        piece: []f32,
        probe: *const core.touch.Detector,
        touched: bool,
    ) void;
};
```

The drone-or-clips branch lives here and nowhere else. `Engine` becomes
`voices: [2]Voice` and its step loops over both plants with the same code.

### `adapters/clip_loader.zig`

`directoriesFor` takes a `Source`. `drone` has no folders and is a programming
error to load, so it asserts rather than returning an empty pool: a silent
empty pool is the one failure nobody in the room can tell from the piece
working.

### `cli.zig`

```
--plant-a=SOURCE        --plant-b=SOURCE
--plant-a-seconds=N     --plant-b-seconds=N
--plant-a-retrigger=N   --plant-b-retrigger=N
```

Defaults: `--plant-a=drone`, `--plant-b=recordings`, which is what the
installation does today. An absent flag uses the source's default.

`--seconds` is the play length; `N=0` means play to the clip's own end, which is
how a capped source is uncapped or `recordings` is capped. `--retrigger` is the
guard, counted from when the clip started.

Bare `--plant-a`, with no value, keeps meaning `--plant-a=daybird`. It is one
line, and it means a unit file or script already passing the flag keeps working
rather than failing to start. `--plant-b` gains no such shorthand: it has never
had one and inventing one would be a second way to say the same thing.

### `main.zig`

One loop over the two plants, building whichever voice each was named. The two
bespoke blocks collapse into it.

## Data flow

Unchanged from today for a clip source: the loader lists paths and folder
indices, the stream adapter primes heads and runs its worker, the selector
answers a touch edge subject to the ten-second guard, and the audio thread mixes
head-then-ring into the engine block. What changes is only who decides which of
those a plant gets.

For a drone source the engine calls the same `Voice.render` and the union's
drone arm renders the generated voice from the probe's deviation, as plant A
does today.

Two plants naming the same clip source get two independent streams, each with
its own ring, worker and heads. Sharing one would mean a touch on either plant
cutting the other off, and the two would drift into playing the same clip in
lockstep. The cost is one more ffmpeg process and one more second of ring.

## Fitting on the Pi

The board is a Zero 2 W: four slow cores and 512 MB shared with the GPU. Two
plants that can both stream clips double every per-plant cost, so each one is
bounded on purpose.

**Memory.** The head cache is the only sizeable allocation. A capped source is
pre-decoded whole so a touch never waits on `ffmpeg`; an uncapped one keeps
only its two-second head and streams the rest.

| source | heads, per plant |
|---|---|
| `recordings` | 7.1 MB (21 clips x 2 s) |
| `daybird` | 4.4 MB (5 clips x 5 s) |
| `insect` | 4.4 MB (5 clips x 5 s) |
| `tradvn` | 1.4 MB (4 clips x 2 s head) |
| `piano` | 4.2 MB (6 clips x 4 s) |
| `bell` | 2.8 MB (4 clips x 4 s) |
| `drone` | none |

Worst case is both plants on `recordings` at 14.2 MB, plus two rings at 176 KB
each. Against 512 MB that is not a constraint, and it is bounded by the pool on
disk rather than by anything the room can type.

Except through `--seconds`, which is why the whole-pool pre-decode is bounded:
a source is taken whole only when its play length is eight seconds or under.
Past that it keeps a two-second head and streams the remainder, so
`--plant-a-seconds=60` costs the same memory as `--plant-a-seconds=8` rather
than fifty megabytes.

**Processes.** At most one `ffmpeg` per plant, and only while an uncapped clip
is streaming. A capped source spawns none at all after startup: its clips are
already in memory. Two plants on capped sources run no decoders in the steady
state, which on this board is the difference that matters.

**Audio thread.** Unchanged: no allocation, no locks, no blocking. Rendering a
voice is a memcpy from the head, an add from the ring, or the drone's filter --
the same work as today, done twice instead of once and a half.

**Startup.** Pre-decoding both pools is serial and one-time. Measured on x86 the
recordings pool takes 0.7 s; the Pi is five to ten times slower, and two pools
double it, so budget under thirty seconds before the sink opens.

## Error handling

- An unknown source name is a parse error naming the flag, as `--plant-b` does now.
- A source whose folder is missing or empty exits with the folder named, as now.
- A negative or unparseable `--seconds` is refused rather than clamped.
- A `--seconds` or `--retrigger` given for `drone` is refused. The drone has no clip to cut, so
  the flag can only be a typo, and silently ignoring a typo is how a room ends
  up hearing the wrong thing with no clue why.
- A clip head that fails to decode leaves that clip to start the slow way, as now.

## Testing

- `Source.parse` round-trips every name and refuses one that does not exist.
- `defaultSeconds` and `defaultRetriggerSeconds` for each source, including
  `drone` and `recordings`.
- A source that plays to its end is protected by its guard and then interruptible
  past it, and a source whose play length is under its guard is interruptible as
  soon as it has finished.
- Both `Voice` arms render: the drone arm produces the drone, the clips arm
  requests a clip on a touch edge and respects the ten-second guard.
- An engine test that either plant can be either kind. The symmetry is the whole
  point of the change, so it is what gets asserted.
- `directoriesFor` names the new folders, and loading `insect` and `tradvn`
  produces non-empty pools with folder indices.
- A real-audio duration test for `insect` and `tradvn`, in the shape of the
  existing `Day bird` one: drain the stream and assert what sounds is inside the
  requested window.
- The `--seconds` override reaches the limit a stream is built with, and the
  `--retrigger` override reaches the selector.

## Risks

The `Pool`→`Source` rename touches roughly forty call sites across eight files.
All are mechanical, and the compiler finds every one. `replay.zig` and
`production_config.zig` hold the detector work and reference no pools, so the
acquisition and detector investigation is untouched by this change.
