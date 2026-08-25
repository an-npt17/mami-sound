//! Test root for the adapters.
//!
//! The adapters reach sideways into `core/` and `ports/`, which a module rooted
//! at `src/adapters/root.zig` cannot see. Rooting the test module here — at the
//! top of the tree the imports are written against — is what lets them compile.
pub const adapters = @import("adapters/root.zig");

test {
    _ = adapters;
}
