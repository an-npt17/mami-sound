# Final Review Fix Report

Date: 2026-08-25

## Scope

Implemented the approved final-review fixes without changing the architecture,
the documented noise test, `src/core/touch.zig`, unrelated untracked artifacts,
or the approved asset/service cleanup.

## Fixes

1. Plant selection now gates Plant A rendering in
   `src/application/engine.zig`. A B-only engine step no longer calls the drone,
   so its idle signal cannot enter the PCM block. The application test in
   `src/application/root.zig` checks B-only PCM output is silent with no clips
   and checks the same setup renders non-zero PCM when Plant A is selected.

2. The fixed production configuration already contains
   `.window_bc_ms = 1000.0` in `src/application/production_config.zig`, and the
   application test already asserts the optional value is `1000.0`. This was
   verified and intentionally not rewritten redundantly.

3. `src/adapters/aplay_sink.zig` now validates the result of `Child.wait()`.
   Non-zero exits and non-normal termination return `error.ChildFailed`; wait
   errors still propagate. The adapter tests use `/bin/sh` as a portable
   stdin-draining test helper and deterministic exit/signal commands, never
   `aplay`.

4. `src/main.zig` now closes and finishes the sink explicitly. A clean engine
   run propagates a shutdown failure. If both engine and shutdown fail, the
   original engine error is returned and the shutdown error is reported rather
   than silently discarded. Focused composition tests cover both cases.

5. Added `src/cli_test_root.zig` and a dedicated CLI test module/target in
   `build.zig`. The target is a separate src-root test boundary and is included
   by `zig build test` without importing CLI into the core library boundary.

6. Removed the unused `library.pick()` API and its reservoir-sampling test.
   Updated `src/adapters/library.zig` documentation to describe Plant B's
   combined `interview files/` and `field records/` pool.

7. Strengthened the Plant B hard-switch test with longer, distinguishable
   clips. It now verifies the first clip is still active mid-clip, triggers a
   second rising edge, verifies the position reset, and checks the new output
   starts at the selected clip's first sample.

## Verification

### Formatting

- `nix develop --command zig fmt`: FAIL, exit 1. Zig 0.16 requires at least one
  file or directory argument.
- `nix develop --command zig fmt build.zig src/adapters/aplay_sink.zig src/adapters/library.zig src/application/engine.zig src/application/root.zig src/core/plant_b.zig src/main.zig src/cli_test_root.zig`: PASS, exit 0.
- The same intended-file set with `zig fmt --check`: PASS, exit 0.
- `src/core/touch.zig` was excluded from formatting and its pre-existing dirty
  diff was preserved.

### Focused tests

- `nix develop --command zig test src/application_test_root.zig --test-filter "application.root"`: PASS, 8/8.
- `nix develop --command zig test src/adapters_test_root.zig --test-filter finish`: PASS, 6/6.
- `nix develop --command zig test src/main.zig --test-filter composition`: PASS, 2/2. The expected test diagnostic `audio sink shutdown failed: ShutdownFailed` was emitted for the dual-failure case.
- `nix develop --command zig test src/core/plant_b.zig --test-filter "hard-switches"`: PASS, 1/1.
- `nix develop --command zig test src/cli_test_root.zig`: PASS, 13/13.

### Build and registered test gate

- `nix develop --command zig build`: PASS, exit 0.
- `nix develop --command zig build test`: FAIL, exit 1. The registered test
  gate reported `379/383` tests passed and four failures, all the documented
  pre-existing `core.noise.test.rest is audible rather than felt` assertion at
  `src/core/noise.zig:244`. The implementation remains `freq_min = 30.0` at
  `src/core/noise.zig:17`; the required `30` versus `60` discrepancy was not
  changed.

## Worktree protection

Only the intended fix files and the requested report were changed. The existing
dirty `src/core/touch.zig` modification and unrelated untracked artifacts were
not staged or modified.
