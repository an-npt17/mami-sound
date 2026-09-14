//! Box 2. Probe A behaves as a switch rather than as a sensor.

const core = @import("../../core/root.zig");
const defaults = @import("defaults.zig");

/// How big a move a touch must be, in the counts the probe actually reads.
///
/// The score alone cannot answer this. It divides a move by how much the probe
/// normally wanders, and on this rig that denominator means very little: probe
/// A reads nought or one with nobody on it, so its median absolute deviation
/// sits on the floor of twenty-five and the smallest wobble scores deviations
/// the threshold cannot tell from a hand.
///
/// Plant A's floor is deliberately far under its excursion rather than near
/// half of it. The probe there is nought or one untouched and about twenty-five
/// thousand under a hand, and the room's complaint was that a light touch did
/// nothing and only a tight grip sounded. A floor at three thousand is twelve
/// per cent of a full touch and still forty times the worst wander the journal
/// shows at rest.
///
/// Plant B moves about twenty-four thousand and keeps a floor near half of it:
/// a wrong latch there starts a recording, which is the fault a room hears.
const counts: i16 = 3000;
const counts_bc: i16 = 10000;

pub const preset: defaults.Preset = blk: {
    var p = defaults.preset;
    p.touch.counts = counts;
    p.touch.counts_bc = counts_bc;
    // `span` is the deviation that reaches the top of the pitch range, and it
    // has to be the move the probe actually makes. Three thousand was measured
    // on a rig whose hand moved the probe about that far; this one moves it
    // twenty-five thousand, so every touch saturated and arrived at freq_max
    // whatever the grip -- the same throttle being opened every time.
    //
    // The floor is what keeps the quiet end audible: a move just over the
    // counts floor is a twelfth of the span, which without a floor is 44 Hz
    // against an idle of 30 and cannot be heard as an answer.
    p.drone.span = 25000;
    p.drone.touch_floor = 0.35;
    break :blk p;
};
