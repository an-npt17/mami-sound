//! Test root for the command line. See `adapters_test_root.zig` for why the
//! root sits here rather than beside the code.
pub const cli = @import("cli.zig");

test {
    _ = cli;
}
