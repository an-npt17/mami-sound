# mami-sound — ECG-driven plant sound installation

Date: 2026-08-11
Status: approved design, not yet implemented

## Purpose

A museum installation with three plants. Visitors touch a plant to make it sound.
One plant carries an ECG-style biopotential sensor; its voice is a continuous
noise drone whose pitch tracks the plant's signal level. A healthy plant reads
higher voltage and sounds higher; an unhealthy plant reads lower and sounds
lower. The other two plants play fixed audio clips.

Written in Zig, single binary, Linux.

## Toolchain

Zig **0.16.0**, supplied by the repo's `flake.nix` along with `zls` and
`alsa-utils`. All commands run inside `nix develop`:

```
nix develop -c zig build test
nix develop -c zig build run
```

Zig 0.16 reworked I/O: `std.fs.File` moved to `std.Io.File`, and I/O
operations take an explicit `Io` parameter obtained from an implementation
such as `std.Io.Threaded`. Code samples written for Zig 0.13/0.14 will not
compile. The relevant verified signatures are:

```zig
std.Io.Threaded.init(gpa: Allocator, options) Threaded
Threaded.io(t: *Threaded) Io
std.process.spawn(io: Io, options: SpawnOptions) SpawnError!Child
Child.stdin: ?std.Io.File
std.Io.File.writer(file, io: Io, buffer: []u8) File.Writer  // .interface is an Io.Writer
Child.wait(child: *Child, io: Io) WaitError!Term
```

`std.process.spawn` resolves `argv[0]` through the parent process's `PATH`,
so `aplay` is found via the dev shell without an absolute path.

## Starting point

`src/` is empty and `build.zig` still references files that no longer exist.
This is a clean rewrite: every source file is written from scratch and
`build.zig` is replaced. No code from the previous version is carried over.

Nothing is committed to git as part of this work.

## Hardware model

Three plants, four sensors:

| Plant | Sensors | Voice |
|-------|---------|-------|
| A | ECG (0–3.3 V) + touch | Continuous filtered noise, pitch from ECG |
| B | touch | Audio clip 1, one-shot |
| C | touch | Audio clip 2, one-shot |

**Sensors are simulated in this phase.** No hardware is read. Real ADC/GPIO
reads replace `src/sensors.zig` later without changing its public signature.

## Audio output

The program spawns `aplay` as a child process and writes raw PCM to its stdin:

```
aplay -q -f S16_LE -r 44100 -c 1 -
```

This avoids libasound and C interop. Writing a block to `aplay` blocks until
`aplay` is ready for more, so the sink is also the program's clock — no timers,
no sleeping, no drift. Latency is roughly `aplay`'s buffer (~100 ms), which is
irrelevant for a slow drone.

Swapping to direct ALSA later touches only `src/sink.zig`.

## Audio format

| Parameter | Value |
|-----------|-------|
| Sample rate | 44100 Hz |
| Channels | 1 (mono) |
| Sample format | i16, little-endian |
| Block size | 512 frames (~11.6 ms) |
| Internal mixing | f32 in [-1, 1] |

## Architecture

Single thread. One fixed pipeline, no dynamic dispatch, no allocation inside
the audio loop. Three concrete voice structs; `main.zig` sums them.

```
Sensors.tick() ──► ecg_volts: f32, touch: [3]bool
                        │
     ┌──────────────────┼──────────────────┐
     ▼                  ▼                  ▼
  Noise (A)         Player (B)         Player (C)
  render(block)     render(block)      render(block)
     └──────────────────┼──────────────────┘
                        ▼
              clamp, f32 → i16
                        ▼
              Sink.write() → aplay stdin
```

Each `render` **adds** its output into the shared `[512]f32` block, which
`main` zeroes at the top of each iteration. No scratch buffers.

### Files

| File | Responsibility | Approx. lines |
|------|----------------|---------------|
| `src/main.zig` | Wire everything, run the block loop | 90 |
| `src/sensors.zig` | Simulated ECG voltage + 3 touch booleans | 70 |
| `src/noise.zig` | Plant A voice: noise → smoothed pitch → resonant bandpass → gate envelope | 110 |
| `src/player.zig` | One-shot playback of a `[]const f32` buffer | 60 |
| `src/clips.zig` | Generate the two placeholder clip buffers | 60 |
| `src/sink.zig` | Spawn `aplay`, write i16 blocks | 60 |
| `src/root.zig` | Re-export modules for the test build | 10 |

`build.zig` is rewritten to build one executable from `src/main.zig` plus a
test step covering both `src/root.zig` and the executable's module.

## Voice: Noise (plant A)

Continuous noise shaped by a resonant bandpass filter. The filter's centre
frequency is the perceived pitch.

Per sample:

1. **Source** — white noise, `rng.float(f32) * 2 - 1`, xoshiro PRNG.
2. **Pitch target** — map ECG volts to frequency on a log scale, so equal
   voltage steps sound like equal pitch steps:

   ```
   t      = clamp(ecg_volts / 3.3, 0, 1)
   target = 120.0 * pow(2000.0 / 120.0, t)
   ```

   120 Hz at 0 V, 2000 Hz at 3.3 V.

3. **Smoothing** — one-pole lowpass toward the target:

   ```
   fc += (target - fc) * alpha,   alpha = 1 - exp(-1 / (tau * sample_rate))
   ```

   with `tau = 1.0 s`. This is the "slow envelope only" behaviour: fast
   wiggles and spikes in the ECG are filtered out here, so pitch follows the
   slow trend and reads as plant health. No separate envelope-follower stage
   exists — this smoother *is* it.

4. **Filter** — Chamberlin state-variable filter, bandpass output, fixed high
   resonance. Coefficients `f = 2 * sin(pi * fc / sample_rate)` and
   `q = 1 / Q`. At 44100 Hz and `fc <= 2000 Hz`, `f <= 0.285`, comfortably
   inside the filter's stability limit.

5. **Gate envelope** — linear ramp 0↔1 over 150 ms following plant A's touch
   state. Silence when untouched.

6. **Output gain** — a fixed makeup gain compensates for the bandpass being
   quiet at high resonance.

Pitch glides continuously and never steps between notes.

## Voice: Player (plants B and C)

Holds a `[]const f32` clip and a play position.

- Touch **rising edge** → `pos = 0`, voice becomes active.
- Plays to the end of the buffer regardless of whether the visitor lets go.
- Touch while already playing is **ignored** — it does not restart or layer.
- On reaching the end, the voice goes idle and adds nothing.

The player never inspects the clip's origin, so replacing generated clips with
decoded WAV data requires no change here.

## Placeholder clips

`src/clips.zig` synthesizes two distinguishable buffers at startup, allocated
once before the audio loop begins:

- **Clip B** — three-note descending sine phrase, ~2.0 s.
- **Clip C** — two simultaneous sine tones with a slow tremolo, ~2.0 s.

Both get 20 ms fades at each end so they start and stop without clicking.

These are stand-ins. Real audio files will replace them later; that work is a
new function returning `[]const f32` and is out of scope for this spec.

## Polyphony

The three voices are fully independent and may sound at the same time. All
seven non-silent combinations must work: A, B, C, A+B, A+C, B+C, A+B+C.

Each voice applies a gain of 0.4 before adding into the block. The summed
block is hard-clamped to [-1, 1] before conversion to i16, so simultaneous
voices reduce headroom but never wrap around.

## Simulated sensors

`Sensors.tick()` is called once per block and returns the current ECG voltage
and three touch booleans. The simulation is a fixed script driven by elapsed
sample count, seeded deterministically so every run produces identical audio
and results can be compared by ear between runs.

- **ECG** — random walk within 0.3–3.0 V, clamped, stepping slowly enough that
  audible pitch movement takes seconds.
- **Touch A** — held from t=1 s to t=12 s.
- **Touch B** — brief touch at t=3 s.
- **Touch C** — brief touch at t=7 s.

The overlap at t=3 s and t=7 s exercises polyphony during a normal run: at
those moments plant A's drone and a clip sound together.

`zig build run` renders 15 seconds and exits cleanly. A fixed length keeps the
run reproducible and terminates without needing a signal handler. With real
sensors the loop becomes unbounded; that is a one-line change in `main.zig`.

## Error handling

All failures happen at startup, where they can be reported clearly:

- `aplay` missing or fails to spawn → print the reason, exit non-zero. The
  message names `alsa-utils` and `nix develop`, since that is the likely cause.
- A failed write to `aplay` mid-run is fatal; the process exits rather than
  continuing to produce silence.
- On exit, the writer is flushed, the child's stdin is closed so `aplay` drains
  and terminates, and the child is waited on.

There is no error handling inside the per-sample DSP path.

## Testing

`zig build test` covers the pure functions; nothing under test performs I/O or
spawns a process.

- Frequency mapping is monotonically increasing, returns 120 Hz at 0 V and
  2000 Hz at 3.3 V, and clamps outside 0–3.3 V.
- The one-pole smoother converges toward a constant target and never overshoots.
- The state-variable filter output stays bounded when driven with noise at both
  frequency extremes.
- The gate envelope reaches exactly 0 and 1 and takes the expected sample count.
- `Player` produces silence before its first trigger, non-silence after, exact
  clip length, silence after the end, and ignores a re-trigger mid-playback.
- Generated clips are the expected length and start and end at zero amplitude.
- Mixing three full-scale voices clamps to i16 limits rather than wrapping.

## Out of scope

- Real sensor hardware (ADC, SPI/I2C, GPIO)
- WAV or any audio file decoding
- Direct ALSA output
- Networking, web UI, visuals
- Stereo or spatialization
- Multiple ECG sensors
