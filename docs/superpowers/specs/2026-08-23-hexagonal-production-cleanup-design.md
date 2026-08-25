# mami-sound - production cleanup and hexagonal architecture

Date: 2026-08-23
Status: draft for user review, not yet implemented

## Purpose

Reduce the installation to its actual production behavior and make the
dependency direction explicit through a pragmatic hexagonal architecture.

The production program has two plants:

- Plant A is the ADS1115-driven drone.
- Plant B is a random clip voice using recordings from both existing clip
  folders.

The program no longer needs GPIO motion sensors, randomized probe data,
scripted demonstrations, alternate voices, runtime touch tuning, or CSV touch
logging.

## Agreed behavior

### Sensors

The ADS1115 is mandatory. Startup opens it before starting `aplay`; an open
failure is reported and terminates the process. There is no simulated or random
sensor fallback.

The ADS1115 adapter retains the existing production wiring and timing:

- Plant A uses differential input `AIN0-AIN1`.
- Plant B uses differential input `AIN2-AIN3`.
- Readings remain signed `i16` values.
- The multiplexer is held for a full audio block before switching.
- Transient read or mux-switch failures hold the last valid real reading.

Holding the last valid hardware value is an error policy, not a simulation
path. No random value is generated in production.

### Voices

Plant A always uses the drone. The flute and beep voices are removed.

Plant B owns one combined pool containing audio files from:

- `interview files/`
- `field records/`

Each new accepted touch chooses one clip at random. It immediately replaces the
currently playing clip with a hard cut. There is no interrupt threshold and no
fade state. This is intentionally snappy; a click at the boundary is accepted
as part of the chosen behavior.

Plant C no longer exists.

### CLI

The supported command line is:

```text
mami_sound [PLANTS] [--device=NAME]
```

`PLANTS` accepts only `1`, `2`, or `12`:

- `1`: Plant A only.
- `2`: Plant B only.
- `12`: both plants.
- no selection: both plants, preserving the normal installation default.

`--device` selects the ALSA device and defaults to `default`.

The following are removed and must be rejected as unknown or obsolete flags:

- `--voice`
- `--touch`
- `--touch-model`
- all touch threshold, hold, band, baseline, settle, count, and window flags
- all pitch flags
- `--interrupt`
- `--log-touch`
- retired `--trigger` flags

### Fixed production configuration

Runtime tuning moves into one production configuration owned by the application
layer. The current values supplied by `mami-sound.service` are preserved:

- deviation touch model
- current general touch defaults from `touch.zig`
- BC touch level: `20`
- BC hold: `30 ms`
- BC window: `1000 ms`
- drone onset jump: `0.15`
- drone glide: `4 s`
- drone release: `0.5 s`

Clip interruption is not configured because every new touch hard-switches to a
new random clip.

## Architecture

The dependency direction is:

```text
CLI -> application -> core
                 -> ports <- adapters
```

### Core

`src/core/` contains behavior that can be tested without Linux, processes,
files, or hardware:

- `touch.zig`: signed probe detection and arbitration state machine.
- `noise.zig`: Plant A's drone voice.
- `plant_b.zig`: Plant B's combined random clip player and hard-switch logic.
- `plant.zig`: plant count, plant identifiers, and selection types.

Core modules must not import `std.os.linux`, `std.process`, `std.Io`,
filesystem APIs, GPIO, ADS1115, or `aplay`.

The existing pure touch and drone tests remain in the core test target. Synthetic
readings remain valid as unit-test fixtures; they must not be reachable from the
production composition root.

### Application

`src/application/engine.zig` owns the production block and poll loop:

```text
ProbeSource.read()
    -> touch.Machine.update(raw_a, raw_bc)
    -> plant selection masking
    -> drone.render()
    -> plant_b.render()
    -> PCM conversion
    -> AudioSink.write()
    -> human-readable status
```

`src/application/production_config.zig` owns the fixed installation tuning.

The application does not know CLI syntax, device paths, ffmpeg, directory names,
Linux syscalls, or process management. It receives already-composed ports and
loaded clip data.

The existing once-per-second stderr status remains because it is useful for
operating a physical installation. File-based touch logging is removed.

### Ports

`src/ports/` defines small runtime interfaces:

- `probe_source.zig`: reads semantic probe data, exposing only `raw_a` and
  `raw_bc` values and the operation needed by the engine.
- `audio_sink.zig`: writes PCM blocks and finishes the output stream.

The ports use small context/function-table structs so the application tests can
inject in-memory fakes without importing concrete adapters. Port interfaces do
not expose ADC muxes, file descriptors, child processes, or filesystem paths.

Clip loading is startup work. The application receives decoded clip pools; the
filesystem and decoder remain outside the core.

### Adapters

`src/adapters/` contains infrastructure implementations:

- `ads1115_probe.zig`: Linux I2C access, ADS1115 configuration, mux scheduling,
  conversion timing, and startup errors.
- `aplay_sink.zig`: `aplay` process creation, pipe management, and PCM writes.
- `clip_loader.zig`: directory scanning, ffmpeg decoding, and combining the two
  recording directories into Plant B's pool.

`main.zig` is the composition root and inbound CLI adapter. It parses the two
  supported CLI concepts, opens the mandatory probe adapter, loads clips,
  constructs the audio adapter, and starts the application engine.

The audio sink must not be started before mandatory ADS1115 startup succeeds.

## File changes

### New or moved responsibilities

- Move pure domain modules into `src/core/`.
- Move the render loop and fixed tuning into `src/application/`.
- Add `src/ports/` for probe and audio interfaces.
- Move hardware, process, decoder, and filesystem implementations into
  `src/adapters/`.
- Make `main.zig` a composition root instead of a 600-line application
  implementation.

The implementation may preserve individual filenames temporarily during the
migration, but the final dependency boundaries and directory organization must
match this layout.

### Explicit deletions approved by the user

- `src/gpio.zig`
- `src/sampler.zig`
- `src/tone.zig`
- `src/touchlog.zig`
- `src/sensors.zig`, after its ADS1115 timing logic is migrated
- `Flute Clean/`, after its assets are no longer referenced

The old B/C `Sequence` implementation will be replaced by the Plant B clip
player. No obsolete turn-taking or interruption fields should remain.

### Configuration updates

Update `mami-sound.service` to:

- remove `gpio` from `SupplementaryGroups`;
- remove all deleted CLI flags;
- retain `--device=plughw:0,0` if that remains the deployment device.

Do not modify unrelated untracked artifacts or the existing user modification
to `src/touch.zig`.

## Testing and verification

### Core tests

Retain and run the pure detector, arbitration, drone, selection, and clip-player
tests. Add or update tests for:

- Plant B combining two source pools.
- random clip selection on each touch.
- immediate replacement of a playing clip.
- no Plant C selection.
- hard-switch behavior without fade state.

### Application tests

Use fake probe and audio ports to verify:

- probe readings reach the touch machine;
- selected plants are the only voices rendered;
- a Plant B touch replaces the current clip;
- the application writes PCM blocks and finishes cleanly;
- no production branch generates random sensor values.

### Adapter tests

Keep ADS1115 config-word and mux timing tests in the adapter target. Keep pure
PCM conversion tests with the audio adapter or a small core audio utility.

Verify the startup composition path so an ADS1115 open error is returned before
the `aplay` adapter is spawned.

### CLI and deployment tests

Test valid selections `1`, `2`, `12`, the default selection, and `--device`.
Test that Plant C and every removed flag are rejected. Search the source and
service file for stale flags, GPIO references, flute/beep references, random
sensor fallback, and touch-log references.

Run formatting and `zig build test`. The repository currently has one unrelated
pre-existing failure: `noise.test.rest is audible rather than felt` asserts a
minimum of `60 Hz` while the implementation currently uses `30 Hz`. This
refactor will report that failure without changing the audio tuning unless a
separate decision is made.

## Out of scope

- Changing the existing user modification to `src/touch.zig`.
- Changing the physical ADS1115 wiring or probe algorithm beyond moving its
  adapter boundary.
- Adding a general-purpose dependency-injection framework.
- Deleting unrelated untracked files or experimental artifacts.
- Changing the drone's `30 Hz` minimum solely to make the pre-existing test pass.
