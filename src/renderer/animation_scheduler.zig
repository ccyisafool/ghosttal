//! Pure policy helpers for renderer animation scheduling.
//!
//! Keeping focus/visibility decisions here makes the contract shared by the
//! timer and display-link paths deterministic and directly testable.

pub const MotionState = struct {
    visible: bool,
    focused: bool,
    cursor_active: bool,
    input_active: bool,
};

pub fn motionDelay(state: MotionState, interval_ms: u64) ?u64 {
    if (!state.visible or !state.focused) return null;
    if (!state.cursor_active and !state.input_active) return null;
    return interval_ms;
}

pub fn displayLinkShouldRun(
    visible: bool,
    focused: bool,
    cells_rebuilt: bool,
    animation_pending: bool,
) bool {
    return visible and focused and (cells_rebuilt or animation_pending);
}

test "motion scheduling requires a visible focused surface and active motion" {
    const interval: u64 = 8;
    try expectDelay(null, .{ .visible = false, .focused = true, .cursor_active = true, .input_active = false }, interval);
    try expectDelay(null, .{ .visible = true, .focused = false, .cursor_active = true, .input_active = false }, interval);
    try expectDelay(null, .{ .visible = true, .focused = true, .cursor_active = false, .input_active = false }, interval);
    try expectDelay(interval, .{ .visible = true, .focused = true, .cursor_active = true, .input_active = false }, interval);
    try expectDelay(interval, .{ .visible = true, .focused = true, .cursor_active = false, .input_active = true }, interval);
}

test "display link policy covers cell updates and animation transitions" {
    const testing = @import("std").testing;
    try testing.expect(!displayLinkShouldRun(false, true, true, true));
    try testing.expect(!displayLinkShouldRun(true, false, true, true));
    try testing.expect(!displayLinkShouldRun(true, true, false, false));
    try testing.expect(displayLinkShouldRun(true, true, true, false));
    try testing.expect(displayLinkShouldRun(true, true, false, true));
}

fn expectDelay(expected: ?u64, state: MotionState, interval_ms: u64) !void {
    try @import("std").testing.expectEqual(expected, motionDelay(state, interval_ms));
}
