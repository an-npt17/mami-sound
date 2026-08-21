# Flute multisample voice for plant A

**Status:** built and verified, 2026-08-12. This is an as-built record; the code
in `src/sampler.zig` is the authority.

## Problem

Plant A's voice was filtered white noise: the ECG level set a bandpass centre
frequency, so the plant's state was heard as pitch. The goal was to keep that
mapping but let the sound itself be something other than hiss — starting with a
flute.

Feeding a recording into the existing bandpass as excitation does not work for
this material. The filter selects pitch from whatever the source offers, so it
only tracks pitch when the source is broadband. The supplied flute set is
strongly tonal (h2/h1 as low as 0.04 in the top octave), so filtering it would
give a static note with a wah on it, not a pitch instrument.

The set turned out to be a full multisample: 12 mono wavs, 44.1 kHz, 1.1-2.1 s,
spanning 259-1860 Hz with 2-4 semitone gaps. That makes nearest-note replay
viable, since no target is ever more than ~2 semitones from a recording.

## Design

A pitched multisample voice. The ECG maps to a target frequency exactly as
before; the voice finds the recording nearest that target in cents and replays
it at a fractional rate so it lands on the target exactly.

```
sensors --ECG--> [one-pole smoother, tau 1 s] --> target Hz
                                                     |
                                        zone select (nearest in cents)
                                        rate = target / recording f0
                                                     |
                        12 prepared buffers --> head --+--> crossfade --> gate --> mix
                                                old ---+
```

### Components

- `src/sampler.zig` — the voice. Generic over a set of `{ path, f0 }` entries;
  the flute table is one const in the file. Load, preparation, zone selection,
  playback, crossfading.
- `src/cli.zig` — argument parsing, returning `Options { plants, voice }`.
  Pure, tested on a slice of strings.
- `src/select.zig` — unchanged; plant mask and touch masking.
- `src/noise.zig` — unchanged; still the default voice.
- `src/main.zig` — a `VoiceA` union so the render loop does not know which
  voice it holds.

### Load-time preparation, per recording

1. Decode through `decode.loadFile` (ffmpeg, mono f32 @ engine rate).
2. Split at 0.4 s: attack before, loop material after.
3. Choose the loop length by normalized correlation over one period, then fold
   the following 40 ms over the start of the loop with a linear fade. Stored as
   `attack ++ loop`; reading past the end and subtracting the loop length lands
   back at `loop_start`.
4. RMS normalize to 0.25. The raw set spans 0.305-0.551 RMS, a 5 dB spread that
   would step in loudness at every zone crossing. Peak normalization does not
   fix this.

### Playback

- Pitch: the existing one-pole smoother (tau 1 s) applied to the target
  frequency, so the pitch glides and never steps.
- Rate: `target / recording.f0`, applied to a float read position with linear
  interpolation. Rate stays within 0.89-1.12, where linear interpolation error
  is inaudible.
- Zone change: only when the previous crossfade has finished and the neighbour
  is more than 30 cents closer (hysteresis stops boundary flicker). The
  incoming head enters mid-loop, never at the attack, so a pitch change does
  not re-articulate the note.
- Attack: played only on the rising edge of a touch, where the pitch also jumps
  to the current reading rather than gliding in from the last note.
- Gate: the existing 150 ms linear fade at touch and release.

### Two coherence problems, and why they matter

Both heads sound the *same* pitch during a crossfade, so they are coherent and
their relative phase is fixed for the whole fade. Left to chance that phase can
be opposition, and the two recordings cancel into a hole. The same applies at
the loop seam, where the folded tail meets the head.

- **Loop seam:** the loop length is chosen by correlation so the fold lands in
  phase, then faded linearly. Choosing the longest available loop instead
  produced a recurring −14 dB hole (measured RMS ratio 6.8 across a sweep).
- **Zone crossfade:** the incoming head's entry point is searched over one
  period of the incoming recording for the best correlation with what is
  already sounding, then faded linearly. Equal-power fading is wrong here
  precisely because the sources are correlated.

### CLI

```
mami_sound [PLANTS] [--voice=drone|flute]
```

`--voice` affects plant A only. The flute set is decoded only when the flute
voice is requested *and* plant A is enabled, so `mami_sound 23 --voice=flute`
needs no wav files.

## Testing

All tests build synthetic sine "recordings" in-process, so they never need
ffmpeg or the installation's files.

- preparation: attack preserved, loop trimmed to a whole number of periods,
  shared RMS reached, too-short input rejected
- zone selection: nearest in cents, boundaries on the geometric mean, ends hold
  outside the range, no target needs more than 2.1 semitones of stretch
- playback: rate 1.0 reproduces the buffer sample for sample
- continuity: a 20 s sweep across the whole range crosses all 11 boundaries and
  never steps more than the material itself does (0.0340 against a 0.0374
  bound)
- level: RMS across the same sweep holds within 1 dB (measured 1.049)
- gating: silent untouched, sounds when touched, silent again after release
- output stays finite and inside the rails under worst-case pitch jumping

Verified on the real samples by capturing what `aplay` receives: 15 s render,
sounding 1.05-12.05 s, RMS ratio 1.31 with a deepest dip of −1.2 dB, pitch
gliding 487-599 Hz with a median step of 9 cents per 100 ms and a maximum of
52. The drone voice renders byte-identically across runs and is unaffected.

## Later addition: the beep voice

`src/tone.zig` adds `--voice=beep`: one unbroken sine at the ECG's pitch,
synthesized, needing no files at all. It shares the pitch range of the drone
(120-2000 Hz) rather than the flute's, so the same reading sounds lower on it.

The one thing that matters in it is that phase is accumulated rather than
computed from elapsed time. Recomputing `sin(2*pi*f*t)` after a frequency
change jumps the phase and clicks; accumulating cannot. The phase is wrapped
every turn so precision does not decay over a long hold, which is tested
directly over a simulated minute.

Verified on a real render: peak 0.140 (exactly amplitude times voice gain),
RMS steady within 0.1 dB across the whole sounding stretch, largest
sample-to-sample step 0.0079 against a theoretical 0.0078 for the frequency it
reached.

## Rejected

- **Filter excitation** (feed the file into the existing bandpass): wrong for
  tonal material, which is all this set contains. The seam remains cheap to add
  later if a broadband source shows up.
- **Note-stepping** (crossfade between recordings with no resampling): keeps
  the timbre exactly, but the pitch moves in 2-4 semitone steps, losing the
  glide that carries the plant's state.
- **Cubic interpolation:** unnecessary at these rates. Worth revisiting only if
  the pitch range is widened beyond the set.
