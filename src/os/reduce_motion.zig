//! Process-wide cached accessibility state.
//!
//! Platform runtimes update this value when their native accessibility
//! settings change. Renderers only read the atomic cache, keeping native UI
//! framework calls out of frame-critical paths.

const std = @import("std");

var enabled: std.atomic.Value(bool) = .init(false);

pub fn get() bool {
    return enabled.load(.acquire);
}

pub fn set(value: bool) void {
    enabled.store(value, .release);
}

test "reduce motion cache updates atomically" {
    const original = get();
    defer set(original);

    set(true);
    try std.testing.expect(get());
    set(false);
    try std.testing.expect(!get());
}
