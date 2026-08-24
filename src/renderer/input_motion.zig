//! Bounded, mutex-owned record of locally encoded input.
//!
//! This is deliberately an intent log, not a terminal-output detector:
//! renderer code may only animate a terminal snapshot when it can consume a
//! matching entry from here. PTY output never writes this structure.
const std = @import("std");

pub const Kind = enum { text, delete, commit };

pub const commit_quad_count = 32;
/// One rising glyph plus a fixed five-instance decay fan.
pub const decay_quad_count = 5;
pub const max_overlay_quads = 1 + decay_quad_count + commit_quad_count;
/// A shell commonly emits the newline before OSC 133 C. Keep a commit intent
/// briefly, but never long enough to turn unrelated output into an effect.
pub const commit_retry_limit: u3 = 3;
pub const local_echo_timeout_ns = 300 * std.time.ns_per_ms;
pub const commit_timeout_ns = 750 * std.time.ns_per_ms;

pub const Event = struct {
    generation: u64,
    kind: Kind,
    /// Unicode scalar count for text, one for delete/commit.
    count: u16,
    /// Small committed-text payload retained for exact snapshot matching.
    /// Larger IME commits deliberately use `count` only and are rejected by
    /// the conservative matcher rather than guessed.
    scalars: [4]u21 = .{ 0, 0, 0, 0 },
    scalar_len: u3 = 0,
    source_col: u16 = 0,
    source_row: u16 = 0,
    /// Active screen identity at input time. A screen switch is a hard
    /// barrier: never animate an edit that happened in another buffer.
    screen: u8 = 0,
    screen_generation: usize = 0,
    /// Backspace's logical glyph head and the scalar it removed. For narrow
    /// cells this is source_col - 1; for a wide-tail it is the wide head.
    target_col: u16 = 0,
    target_scalar: u21 = 0,
    target_width: u2 = 0,
    /// The bounded portion of the OSC-133 input row that is eligible for a
    /// carry animation. This is captured while semantic_content is `.input`.
    input_col_start: u16 = 0,
    input_col_end: u16 = 0,
    /// Number of dirty snapshots that have not yet crossed OSC 133 C.
    retries: u3 = 0,
    created: std.Io.Timestamp = .zero,
    deadline: std.Io.Timestamp = .zero,
};

pub const Queue = struct {
    const capacity = 16;
    events: [capacity]Event = undefined,
    head: u8 = 0,
    len: u8 = 0,
    next_generation: u64 = 1,

    pub fn record(self: *Queue, kind: Kind, count_: usize) void {
        const count: u16 = @intCast(@min(count_, std.math.maxInt(u16)));
        const at = (self.head + self.len) % capacity;
        self.events[at] = .{ .generation = self.next_generation, .kind = kind, .count = count };
        self.next_generation +%= 1;
        if (self.len < capacity) self.len += 1 else self.head = (self.head + 1) % capacity;
    }

    pub fn recordText(self: *Queue, text: []const u8, source_col: u16, source_row: u16, screen: u8, screen_generation: usize, now: std.Io.Timestamp) void {
        var event: Event = .{ .generation = self.next_generation, .kind = .text, .count = 0 };
        var view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            event.count +|= 1;
            if (event.scalar_len < event.scalars.len) {
                event.scalars[event.scalar_len] = @intCast(cp);
                event.scalar_len += 1;
            }
        }
        if (event.count == 0) return;
        event.source_col = source_col;
        event.source_row = source_row;
        event.screen = screen;
        event.screen_generation = screen_generation;
        event.created = now;
        event.deadline = now.addDuration(.{ .nanoseconds = local_echo_timeout_ns });
        const at = (self.head + self.len) % capacity;
        self.events[at] = event;
        self.next_generation +%= 1;
        if (self.len < capacity) self.len += 1 else self.head = (self.head + 1) % capacity;
    }

    pub fn recordBackwardDelete(
        self: *Queue,
        source_col: u16,
        source_row: u16,
        screen: u8,
        screen_generation: usize,
        target_col: u16,
        target_scalar: u21,
        target_width: u2,
        now: std.Io.Timestamp,
    ) void {
        if (source_col == 0 or target_scalar == 0 or target_width == 0) return;
        const at = (self.head + self.len) % capacity;
        self.events[at] = .{
            .generation = self.next_generation,
            .kind = .delete,
            .count = 1,
            .source_col = source_col,
            .source_row = source_row,
            .screen = screen,
            .screen_generation = screen_generation,
            .target_col = target_col,
            .target_scalar = target_scalar,
            .target_width = target_width,
            .created = now,
            .deadline = now.addDuration(.{ .nanoseconds = local_echo_timeout_ns }),
        };
        self.next_generation +%= 1;
        if (self.len < capacity) self.len += 1 else self.head = (self.head + 1) % capacity;
    }

    pub fn recordCommit(
        self: *Queue,
        source_col: u16,
        source_row: u16,
        screen: u8,
        screen_generation: usize,
        input_col_start: u16,
        now: std.Io.Timestamp,
    ) void {
        const at = (self.head + self.len) % capacity;
        self.events[at] = .{
            .generation = self.next_generation,
            .kind = .commit,
            .count = 1,
            .source_col = source_col,
            .source_row = source_row,
            .screen = screen,
            .screen_generation = screen_generation,
            .input_col_start = input_col_start,
            .input_col_end = source_col,
            .created = now,
            .deadline = now.addDuration(.{ .nanoseconds = commit_timeout_ns }),
        };
        self.next_generation +%= 1;
        if (self.len < capacity) self.len += 1 else self.head = (self.head + 1) % capacity;
    }

    pub fn take(self: *Queue) ?Event {
        if (self.len == 0) return null;
        const result = self.events[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return result;
    }

    pub fn peek(self: *const Queue) ?Event {
        if (self.len == 0) return null;
        return self.events[self.head];
    }

    /// Discard every expired head before snapshot matching. Deadlines are
    /// monotonic timestamps captured at key acceptance, not wall clock time.
    pub fn dropExpired(self: *Queue, now: std.Io.Timestamp) void {
        while (self.peek()) |event| {
            if (event.deadline.nanoseconds == 0 or now.nanoseconds <= event.deadline.nanoseconds) return;
            _ = self.take();
        }
    }

    /// Consume only if the event observed during snapshotting is still the
    /// queue head. This closes the renderer/IO handoff without ever taking a
    /// newer keystroke by mistake.
    pub fn takeIfGeneration(self: *Queue, generation: u64) ?Event {
        const event = self.peek() orelse return null;
        if (event.generation != generation) return null;
        return self.take();
    }

    /// Retain a semantically valid Enter while waiting for OSC 133 C. This
    /// modifies only the observed head and drops it once its tiny window is
    /// exhausted, so a delayed shell cannot block subsequent local input.
    pub fn retryCommitIfGeneration(self: *Queue, generation: u64) bool {
        const event = self.peek() orelse return false;
        if (event.generation != generation or event.kind != .commit) return false;
        if (self.events[self.head].retries >= commit_retry_limit) {
            _ = self.take();
            return false;
        }
        self.events[self.head].retries += 1;
        return true;
    }

    /// A resize, preedit, or full terminal redraw destroys the anchored
    /// relationship an intent needs. Do not let an old key accidentally
    /// animate later output after one of those barriers.
    pub fn reset(self: *Queue) void {
        self.head = 0;
        self.len = 0;
    }
};

/// Pure conservative gate shared by the renderer and its tests. This says
/// nothing about arbitrary terminal output: it only recognizes the terminal
/// state a one-scalar local echo must produce at the recorded cursor.
pub fn matchesSingleScalar(
    event: Event,
    current_scalar: u21,
    cursor_col: u16,
    cursor_row: u16,
    width: u16,
) bool {
    return event.kind == .text and event.scalar_len == 1 and
        event.scalars[0] == current_scalar and cursor_row == event.source_row and
        cursor_col == event.source_col +| width;
}

/// Backspace must be the smallest possible local edit: same screen and row,
/// cursor lands on the deleted glyph head, and that cell no longer contains
/// the old scalar. The caller separately requires exactly one dirty row and
/// a cached text sprite at target_col.
pub fn matchesBackwardDelete(
    event: Event,
    screen: u8,
    current_scalar: u21,
    cursor_col: u16,
    cursor_row: u16,
) bool {
    return event.kind == .delete and event.target_width > 0 and
        event.screen == screen and
        cursor_row == event.source_row and cursor_col == event.target_col and
        current_scalar != event.target_scalar;
}

/// Enter is special: do not infer a commit from a newline. Both endpoints
/// must be the OSC 133 semantic boundary and the active screen must be the
/// same one that accepted the key.
pub fn matchesSemanticCommit(event: Event, screen: u8, screen_generation: usize, target_is_output: bool) bool {
    return event.kind == .commit and event.screen == screen and
        event.screen_generation == screen_generation and target_is_output;
}

/// Metalterm-like deletion runs for 180ms. We use a bounded number of
/// afterimages rather than allocating particles per keypress.
pub fn decayProgress(elapsed_ms: f32) f32 {
    return decayProgressScaled(elapsed_ms, 180.0);
}

pub fn decayProgressScaled(elapsed_ms: f32, duration_ms: f32) f32 {
    if (duration_ms <= 0) return 1;
    return std.math.clamp(elapsed_ms / duration_ms, 0.0, 1.0);
}

pub fn commitProgressScaled(elapsed_ms: f32, duration_ms: f32) f32 {
    if (duration_ms <= 0) return 1;
    return std.math.clamp(elapsed_ms / duration_ms, 0.0, 1.0);
}

/// Draw batching and timer scheduling are intentionally distinct: a settled
/// typed overlay remains visible, but must not keep requesting frames.
pub fn overlayQuadCount(has_typed: bool, has_decay: bool) usize {
    return @intFromBool(has_typed) + if (has_decay) @as(usize, decay_quad_count) else 0;
}

pub fn overlayAnimating(typed_progress: f32, has_decay: bool) bool {
    return typed_progress < 1.0 or has_decay;
}

/// Metalterm's rise curve: 0 -> 1 in 150ms, cubic ease-out.
pub fn riseProgress(elapsed_ms: f32) f32 {
    return riseProgressScaled(elapsed_ms, 150.0);
}

pub fn riseProgressScaled(elapsed_ms: f32, duration_ms: f32) f32 {
    if (duration_ms <= 0) return 1;
    const t = std.math.clamp(elapsed_ms / duration_ms, 0.0, 1.0);
    return 1.0 - std.math.pow(f32, 1.0 - t, 3.0);
}

/// A start that never acquired a shaped glyph did not suppress any normal
/// CellText instance. It must not keep the draw timer running.
pub fn cancelAfterRebuild(has_quad: bool) bool {
    return !has_quad;
}

/// Accessibility cancellation is unlike a rebuild: a held typed quad is the
/// only glyph on screen, so retain it statically until the usual row rebuild.
pub fn retainTypedOverlayAfterCancellation(has_quad: bool) bool {
    return has_quad;
}

test "input motion queue is ordered and bounded" {
    var queue: Queue = .{};
    queue.record(.text, 2);
    queue.record(.delete, 1);
    try std.testing.expectEqual(Kind.text, queue.take().?.kind);
    try std.testing.expectEqual(@as(u16, 1), queue.take().?.count);
    try std.testing.expectEqual(@as(?Event, null), queue.take());

    queue.record(.commit, 1);
    const generation = queue.peek().?.generation;
    try std.testing.expectEqual(@as(?Event, null), queue.takeIfGeneration(generation + 1));
    try std.testing.expectEqual(Kind.commit, queue.takeIfGeneration(generation).?.kind);

    for (0..20) |_| queue.record(.text, 1);
    try std.testing.expectEqual(@as(u64, 8), queue.take().?.generation);
}

test "local echo matcher is anchored and exact" {
    const event: Event = .{
        .generation = 1,
        .kind = .text,
        .count = 1,
        .scalars = .{ 'x', 0, 0, 0 },
        .scalar_len = 1,
        .source_col = 4,
        .source_row = 2,
    };
    try std.testing.expect(matchesSingleScalar(event, 'x', 5, 2, 1));
    try std.testing.expect(!matchesSingleScalar(event, 'y', 5, 2, 1));
    try std.testing.expect(!matchesSingleScalar(event, 'x', 5, 3, 1));
    try std.testing.expect(!matchesSingleScalar(event, 'x', 7, 2, 1));
}

test "rise timing is cubic and bounded" {
    try std.testing.expectEqual(@as(f32, 0), riseProgress(-1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.875), riseProgress(75), 0.0001);
    try std.testing.expectEqual(@as(f32, 1), riseProgress(150));
    try std.testing.expectEqual(@as(f32, 1), riseProgress(1000));
}

test "backspace matcher is anchored and rejects stale screen/output" {
    const event: Event = .{
        .generation = 1,
        .kind = .delete,
        .count = 1,
        .source_col = 8,
        .source_row = 3,
        .screen = 1,
        .screen_generation = 7,
        .target_col = 6,
        .target_scalar = '界',
        .target_width = 2,
    };
    try std.testing.expect(matchesBackwardDelete(event, 1, 0, 6, 3));
    try std.testing.expect(!matchesBackwardDelete(event, 0, 0, 6, 3));
    try std.testing.expect(!matchesBackwardDelete(event, 1, '界', 6, 3));
    try std.testing.expect(!matchesBackwardDelete(event, 1, 0, 7, 3));
}

test "decay timing is bounded" {
    try std.testing.expectEqual(@as(f32, 0), decayProgress(-1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), decayProgress(90), 0.0001);
    try std.testing.expectEqual(@as(f32, 1), decayProgress(180));
}

test "input duration scales every motion phase" {
    try std.testing.expectEqual(@as(f32, 1), riseProgressScaled(80, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), decayProgressScaled(120, 240), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), commitProgressScaled(140, 280), 0.0001);
}

test "typed and decay overlays batch without keeping a settled glyph alive" {
    try std.testing.expectEqual(@as(usize, 6), overlayQuadCount(true, true));
    try std.testing.expectEqual(@as(usize, 1), overlayQuadCount(true, false));
    try std.testing.expect(!overlayAnimating(1.0, false));
    try std.testing.expect(overlayAnimating(1.0, true));
    try std.testing.expect(overlayAnimating(0.5, false));
}

test "unshaped input motion is cancelled after rebuild" {
    try std.testing.expect(cancelAfterRebuild(false));
    try std.testing.expect(!cancelAfterRebuild(true));
}

test "accessibility cancellation retains a withheld typed glyph" {
    try std.testing.expect(retainTypedOverlayAfterCancellation(true));
    try std.testing.expect(!retainTypedOverlayAfterCancellation(false));
}

test "semantic commit gate and expiry are strict" {
    var queue: Queue = .{};
    queue.recordCommit(7, 2, 1, 9, 3, .zero);
    const event = queue.peek().?;
    try std.testing.expect(matchesSemanticCommit(event, 1, 9, true));
    try std.testing.expect(!matchesSemanticCommit(event, 0, 9, true));
    try std.testing.expect(!matchesSemanticCommit(event, 1, 8, true));
    try std.testing.expect(!matchesSemanticCommit(event, 1, 9, false));
    try std.testing.expect(queue.retryCommitIfGeneration(event.generation));
    try std.testing.expect(queue.retryCommitIfGeneration(event.generation));
    try std.testing.expect(queue.retryCommitIfGeneration(event.generation));
    try std.testing.expect(!queue.retryCommitIfGeneration(event.generation));
    try std.testing.expectEqual(@as(?Event, null), queue.peek());
}

test "expired local echo heads do not block later input" {
    var queue: Queue = .{};
    const start = std.Io.Timestamp.fromNanoseconds(1);
    queue.recordText("x", 0, 0, 0, 1, start);
    queue.dropExpired(start.addDuration(.{ .nanoseconds = local_echo_timeout_ns + 1 }));
    try std.testing.expectEqual(@as(?Event, null), queue.peek());
}
