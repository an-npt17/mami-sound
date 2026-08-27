//! Ctrl-C, and what a signal handler is allowed to do about it.
//!
//! Almost nothing, is the answer: a handler runs between two instructions of
//! whatever the program was doing, so it may not allocate, may not take a lock,
//! and may not touch anything the interrupted code was halfway through. Writing
//! a capture from inside one would be all three.
//!
//! So the handler sets a flag and returns, and the run loop notices it between
//! blocks and comes out through the ordinary shutdown -- which drains `aplay`,
//! reaps the decoders, and writes the capture with the whole program standing
//! still. A quarter of a second later than the keypress, and correct.
//!
//! `SIGTERM` as well as `SIGINT`, because systemd stops a unit with the first
//! and a person stops a terminal with the second, and a capture is worth
//! keeping either way.

const std = @import("std");
const posix = std.posix;

/// Set by the handler, read by the run loop. Atomic because those are two
/// different contexts looking at the same byte.
var stop_requested: std.atomic.Value(bool) = .init(false);

/// Ask for the interrupt to be caught rather than killing the process.
///
/// A failure is left alone: the fallback is the default handler, which stops
/// the program without writing the capture -- worse, and no reason to refuse
/// to run the piece.
pub fn listen() void {
    var action: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &action, null);
    posix.sigaction(posix.SIG.TERM, &action, null);
}

/// Whether somebody has asked the run to stop.
pub fn requested() bool {
    return stop_requested.load(.acquire);
}

/// For tests, which must not leave the flag set for the next one.
pub fn clear() void {
    stop_requested.store(false, .release);
}

fn onSignal(_: posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

test "the flag is clear until something sets it" {
    clear();
    try std.testing.expect(!requested());
}

test "the handler is all a handler does" {
    // Set the flag the way the signal would, and read it the way the run loop
    // does. Nothing else may happen in between, which is the whole design.
    clear();
    onSignal(posix.SIG.INT);
    try std.testing.expect(requested());
    clear();
}
