# Box Presets Design

## Goal

Bring every box's branch onto `main` and leave one core algorithm behind, so
that what differs between the five installations is a file of measured numbers
rather than a fork of the detector.

## Why now

There is one `src/application/production_config.zig` and it describes one rig.
Every box that needed a different number therefore needed a different branch,
and once a branch existed the detector drifted with it. The state on the day
this was written:

| branch | vs `main` | holds |
|---|---|---|
| `box1` | 0 ahead, 29 behind | already in `main` |
| `touch-state-machine` | 0 ahead, 49 behind | already in `main` |
| `box2` | 3 ahead, 0 behind | counts floors, `drone.span` 25000, `touch_floor` 0.35 |
| `box5` | 2 ahead, 4 behind | counts floors at other values, `Mode.tap`, rest-learning fix, its own media |
| `feat/clip-management-ui` | 13 ahead, 0 behind | box2's three commits plus the Python clips UI |
| `feature/steady-band-touch` | 17 ahead, 43 behind | the hexagonal refactor, since superseded on `main` |

Two boxes have now changed `src/core/touch.zig` independently. Neither change
is about the box: box2 raised a counts floor because its probe reads as a
switch, box5 fixed where rest is learned from. One belongs in a preset and the
other belongs to every box, and with a branch per box there was nowhere to put
either. A third box tuned this way would be a third detector.

There is no `box3` and no `box4` branch. Those two have never been measured.

## Scope

- Merge `feat/clip-management-ui` and `box5` into `main`; delete `box1`,
  `touch-state-machine` and `feature/steady-band-touch`.
- A `Preset` type and one file per box holding that box's measured numbers and
  its plant wiring.
- Box selection at runtime by `--box=N`, defaulting to the hostname.
- `production_config.zig` stops being the preset and becomes the resolver.

Out of scope: the acquisition path, the clip streamer, the audio sink, and the
Python clips UI, all reused unchanged. No detector behaviour is redesigned —
this merges two lineages of it and moves numbers out of it.

## Merge

`box5`'s merge base is `135c754`, which carries neither `band_share` nor the
flicker guard. `box5` did not delete them; it forked before they were written.
The merge is a union of two sets of additions, and the conflicts are confined to
four places where both lineages edited the same lines: `touchWith`'s signature,
the flag block in `cli.zig`, the fields of `touch.Config`, and `clips.Mode`.

Order:

1. `main` ← `feat/clip-management-ui`, fast-forward. This brings box2's three
   commits with it, so `box2` needs no separate merge.
2. `main` ← `box5`, a real merge with the four conflicts resolved by hand.
3. Delete `box1`, `touch-state-machine`, `feature/steady-band-touch`, local and
   remote. `box2` and `box5` stay until the merged `main` has been verified on a
   Pi.

Resolution rule: where the two lineages disagree about structure, `main`'s
survives. Where `box5` added something the room needs, it comes across.

| delta | from | verdict |
|---|---|---|
| `band_share`, the `Window` union, per-probe bands | `main` | kept |
| the flicker guard (`released_frames`, `settled_frames`) | `main` | kept |
| rest learned from a probe at rest, not one under a hand | `box5` | kept |
| `Mode.tap`, and a tap window given only to a `.tap` plant | `box5` | kept |
| the ungated tap render in `voice.zig` | `box5` | kept |
| `counts` / `counts_bc` floors | both | kept; the values move to box files |
| `drone.span`, `touch_floor` | box2 and box5 disagree | not core; box files |
| `still_window_ms` documentation drift | `box5` | `main`'s wording stands |

`box5`'s media comes with the merge: the `Insect/insect_N.wav` → `insectN.wav`
renames, `Voice Box 5/5Box_Voice_7.mp3`, and `Bell Stems/compressed/bell9.mp3`.

## The preset

```
src/application/boxes/
├── root.zig       the Box enum, the registry, hostname lookup
├── preset.zig     the Preset type
├── defaults.zig   the one measured baseline every box derives from
└── box1.zig … box5.zig
```

```zig
pub const Plant = struct {
    source: core.source.Source,
    mode: core.clips.Mode,
    /// How long a touch plays, and how long before the next is honoured.
    /// `null` leaves the source's own answer standing.
    seconds: ?f32 = null,
    retrigger: ?f32 = null,
};

pub const Preset = struct {
    touch: core.touch.Config,
    drone: core.noise.Shape,
    plants: [2]Plant,
};
```

A box file is one value and the measurements that justify it. Zig has no
struct-update syntax, and a partial-struct mechanism would be a second thing to
maintain for no gain, so a box file is a comptime block over a copy of the
defaults:

```zig
//! Box 2. Probe A behaves as a switch rather than as a sensor.

const defaults = @import("defaults.zig");

/// Plant A's floor is deliberately far under its excursion rather than near
/// half of it. The probe there is nought or one untouched and about twenty-five
/// thousand under a hand, and the room's complaint was that a light touch did
/// nothing and only a tight grip sounded. A floor at three thousand is twelve
/// per cent of a full touch and still forty times the worst wander the journal
/// shows at rest.
const counts: i16 = 3000;
const counts_bc: i16 = 10000;

pub const preset: defaults.Preset = blk: {
    var p = defaults.preset;
    p.touch.counts = counts;
    p.touch.counts_bc = counts_bc;
    p.drone.span = 25000;
    p.drone.touch_floor = 0.35;
    break :blk p;
};
```

A drone plant records `.trigger`. The drone is held by nature and its gate is
its own; writing `.hold` there would reach the detector through `touchWith` and
make it a different rig, so the mode a drone carries has to be the one that
says nothing.

`box1.zig`, `box3.zig` and `box4.zig` are `pub const preset: defaults.Preset =
defaults.preset;` and a comment saying the rig has not been measured yet. They
exist so that adding a box is editing a file rather than cutting a branch.

`src/core/` gains nothing from this. It keeps taking a `Config` and knows no
box exists, which is what makes one algorithm provably one algorithm.

## Selection

Three layers, each overriding the one before:

```
defaults.zig  →  boxN.zig  →  command line
```

`--box=1` through `--box=5` names the preset. With the flag absent the hostname
is read and matched against `box1`…`box5`; with no match, `defaults`. The
resolved name is printed on the `loading:` line, so a room can see which preset
actually ran rather than inferring it from how the piece sounds.

`production_config.zig` keeps `touchWith` in the named-struct shape `box5` gave
it, with a base as its first argument: `touchWith(base, overrides, modes)`. What
changes is where that base comes from — the selected box's `touch` rather than a
constant in the file. Its existing tests keep asserting the same thing: an
override reaches the config and the rest of the preset stands.

There is no `resolve` that bundles all three layers. A run needs the box's
`plants` before the plant loop and its `modes` only after, so a single call
taking both would have to settle the box twice and throw half its answer away.
`chosenBox` answers which box this is, `presetFor` hands over its numbers, and
`touchWith` layers the room's overrides on at the end.

One binary serves all five Pis. Deployment is identical everywhere, and another
box's numbers can be tried on a bench with a flag instead of a cross-build:

    zig build run -- --box=5 --test-random-probe

Which box a Pi is comes from `--box=N`, or from the hostname when the flag is
absent — `box3`, `box3.local` and `box3-pi` are all box 3. A machine that is
none of the five prints `loading: no box named, and this machine is none of the
five: running the unmeasured defaults` and runs them, so a wrong preset cannot
be mistaken for a measured one.

## Testing

- Each box preset compiles and holds its invariants: `drone.span` covers the
  excursion the probe actually makes, the counts floor sits above the worst
  wander that box's journal shows, and a tap window exists only on a plant whose
  mode is `.tap`.
- `--box=N` resolves to that box; an unknown or absent flag falls back to the
  hostname and then to `defaults`; a command-line flag beats the box preset,
  which beats `defaults`.
- The core-only build step that arrived with box2 stays, and is the guard that
  `src/core` has learned nothing about boxes.
- The existing replay sweep (`zig build replay -- touch.csv --sweep`) still
  runs against a capture, unchanged.

## Risks

The merge resolution is the risk, not the preset mechanism. Two detector
lineages meeting in `touch.Config` and `clips.Mode` can compile while behaving
as neither branch did. Mitigation is that every behaviour named in the delta
table above already has a test on the branch it came from; those tests come
across with the merge and must pass together before the preset work starts.

The second risk is that `box1`, `box3` and `box4` ship as unmeasured defaults
and a room assumes a preset is the rig. The `loading:` line naming the resolved
box is what makes that visible.
