//! Test root for the application layer. See `adapters_test_root.zig` for why
//! the root sits here rather than beside the code.
pub const application = @import("application/root.zig");

test {
    _ = application;
}
