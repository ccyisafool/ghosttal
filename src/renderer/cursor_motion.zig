//! Cursor motion animation ("caret motion"). This is a pure, self-contained
//! animation state machine that eases a cursor quad between cell positions.
//!
//! This file intentionally has no dependencies beyond `std` and knows nothing
//! about the renderer, the terminal, or the GPU. It deals only in screen
//! pixels. The caller owns time: every entry point takes an explicit
//! monotonic timestamp in milliseconds so that the animation is fully
//! deterministic and testable. We never read the clock ourselves.
//!
//! The typical renderer usage is:
//!
//!   * On every frame, call `setTarget` with the rect the cursor _should_
//!     occupy for the current terminal state. Retargeting mid-flight is
//!     cheap and continuous; passing the same rect repeatedly is a no-op.
//!   * Call `sample` to get the rect (and optional trail quad) to draw.
//!   * Call `isActive` to decide whether another frame must be scheduled.
//!   * Call `snap` whenever the animation would be nonsensical or unwanted:
//!     focus loss, resize, scroll, or a reduce-motion preference.

const std = @import("std");

/// The available cursor motion styles. Each style shares the same timing
/// contract (`duration_ms` is the nominal time of the move) but differs in
/// how the rect is interpolated and deformed along the way.
pub const Style = enum {
    /// Cubic ease-out of both position and size. No trail.
    ease,
    /// Under-damped spring with a single gentle overshoot.
    spring,
    /// Ease-out where the head outruns the tail, leaving a trail quad
    /// that spans the gap until the tail catches up.
    smear,
    /// Ease-out where the rect stretches along the direction of travel
    /// and un-squashes with a small settle bounce on arrival.
    squash,
};

/// An axis-aligned rectangle in screen pixels. `pos` is the top-left corner,
/// matching the renderer's screen coordinate system (y grows downwards).
pub const Rect = struct {
    pos: [2]f32,
    size: [2]f32,

    pub const zero: Rect = .{ .pos = .{ 0, 0 }, .size = .{ 0, 0 } };

    /// Component-wise linear interpolation of position and size.
    pub fn lerp(a: Rect, b: Rect, t: f32) Rect {
        return .{
            .pos = .{
                mix(a.pos[0], b.pos[0], t),
                mix(a.pos[1], b.pos[1], t),
            },
            .size = .{
                mix(a.size[0], b.size[0], t),
                mix(a.size[1], b.size[1], t),
            },
        };
    }

    /// The center point of the rect.
    pub fn center(self: Rect) [2]f32 {
        return .{
            self.pos[0] + (self.size[0] / 2),
            self.pos[1] + (self.size[1] / 2),
        };
    }

    /// The smallest rect that fully contains both `a` and `b`.
    pub fn bounds(a: Rect, b: Rect) Rect {
        const x0 = @min(a.pos[0], b.pos[0]);
        const y0 = @min(a.pos[1], b.pos[1]);
        const x1 = @max(a.pos[0] + a.size[0], b.pos[0] + b.size[0]);
        const y1 = @max(a.pos[1] + a.size[1], b.pos[1] + b.size[1]);
        return .{ .pos = .{ x0, y0 }, .size = .{ x1 - x0, y1 - y0 } };
    }

    /// True if all components are bit-for-bit identical. This is only used
    /// to detect a redundant retarget, where the caller hands us back the
    /// exact same rect it handed us on the previous frame.
    pub fn eql(a: Rect, b: Rect) bool {
        return a.pos[0] == b.pos[0] and
            a.pos[1] == b.pos[1] and
            a.size[0] == b.size[0] and
            a.size[1] == b.size[1];
    }
};

/// One evaluated frame of the animation.
pub const Sample = struct {
    /// Where to draw the cursor quad this frame.
    rect: Rect,
    /// An elongated quad connecting the tail to the head, used by the
    /// smear style and by spring overshoot. Null when there is nothing
    /// meaningful to draw (settled, or the gap is sub-pixel).
    trail: ?Rect = null,
    /// The directional geometry for `trail`. `trail` remains available as
    /// the conservative damage/bounds rect, while renderers use this line to
    /// draw a ribbon in the actual direction of travel instead of filling a
    /// diagonal move's whole bounding box.
    trail_line: ?TrailLine = null,
    /// Opacity in the range 0..1 for the trail quad. Always 0 when
    /// `trail` is null.
    trail_alpha: f32 = 0,
};

/// A ribbon joining two cursor centers. The renderer gives this its own
/// oriented quad; keeping this geometry here makes diagonal trails as
/// deterministic as the rest of the animation state machine.
pub const TrailLine = struct {
    from: [2]f32,
    to: [2]f32,
    thickness: f32,
};

/// Movements smaller than this many pixels are not worth animating and are
/// treated as an instant snap. A cursor that moves less than a pixel would
/// only produce sub-pixel shimmer.
const min_distance_px: f32 = 1.0;

/// Spring tuning. The damping ratio is under one so that we overshoot, and
/// the natural frequency is expressed in radians per `duration_ms` so that
/// the shape of the curve is independent of the configured duration.
///
/// With zeta=0.6 the first peak overshoots by ~9.5% of the distance at
/// ~0.49x duration, and the damped period is ~0.98x duration, which reads
/// as a single gentle oscillation.
const spring_zeta: f32 = 0.6;
const spring_omega: f32 = 8.0;

/// The spring is considered settled once the residual oscillation envelope
/// falls below this many pixels.
const spring_settle_px: f32 = 0.5;

/// Hard cap on spring settle time as a multiple of the duration, so that a
/// very long move can never animate forever.
const spring_max_factor: f32 = 2.0;

/// Peak amplitude of the oscillating term in `springStep`, i.e. the most
/// the residual can exceed the bare exponential envelope. Needed so that
/// the settle time is derived from the true worst case rather than from
/// the envelope alone.
const spring_gain: f32 = gain: {
    const zw = spring_zeta * spring_omega;
    const wd = spring_omega * @sqrt(1.0 - (spring_zeta * spring_zeta));
    break :gain @sqrt(1.0 + ((zw / wd) * (zw / wd)));
};

/// The spring trail is the position this far in the past (as a fraction of
/// the duration), which streaks in the direction of travel including during
/// the overshoot back towards the target.
const spring_trail_lag: f32 = 0.12;

/// The smear head reaches the target in this fraction of the duration; the
/// tail takes the full duration.
const smear_head_factor: f32 = 0.6;

/// Trails narrower than this many pixels are dropped entirely.
const min_trail_px: f32 = 1.0;

/// Squash tuning. `stretch` is the maximum additional length along the
/// direction of travel (1.35x total), `ramp` is the fraction of the
/// duration over which the stretch is faded in so that a retarget can
/// never pop, and the bounce is a decaying sine over `bounce` durations
/// after arrival.
const squash_max_stretch: f32 = 0.35;
const squash_ramp: f32 = 0.1;
const squash_bounce: f32 = 0.3;
const squash_bounce_amplitude: f32 = 0.12;

/// A cursor animation. This is a plain value type: it owns no memory and
/// needs no deinit. Copying it copies the animation.
pub const CursorMotion = struct {
    /// The active style. See `setStyle`.
    style: Style,

    /// Nominal duration of a move in milliseconds. See `setDuration`.
    duration_ms: f32,

    /// The rect the current animation started from. When settled this is
    /// unused; `target` is authoritative.
    start: Rect = .zero,

    /// The rect we're animating towards. This is where we sit once settled.
    target: Rect = .zero,

    /// When the current animation began, in caller-supplied milliseconds.
    start_ms: f32 = 0,

    /// When the current animation is fully settled. Derived from the style,
    /// duration, and distance at `setTarget` time so that `sample` can stay
    /// const and deterministic.
    end_ms: f32 = 0,

    /// Distance in pixels of the current animation, used for the spring
    /// settle threshold and trail opacity.
    distance: f32 = 0,

    /// Whether an animation is in flight. False means we're parked on
    /// `target`.
    animating: bool = false,

    pub fn init(style: Style, duration_ms: f32) CursorMotion {
        return .{ .style = style, .duration_ms = duration_ms };
    }

    /// Set a new target rect. If it differs from the current target, the
    /// animation is restarted from the CURRENT interpolated position so
    /// that mid-flight retargeting is smooth and never jumps back.
    ///
    /// Handing us the same rect we're already targeting is a no-op, so the
    /// renderer can call this unconditionally every frame.
    ///
    /// `now_ms` is monotonic milliseconds.
    pub fn setTarget(self: *CursorMotion, rect: Rect, now_ms: f32) void {
        if (Rect.eql(self.target, rect)) return;

        // Anchor on exactly what we drew last, deformations included, so
        // that the visible quad is continuous across the retarget.
        const from = self.sample(now_ms).rect;
        const dist = distance(from, rect);

        self.target = rect;
        self.start_ms = now_ms;
        self.distance = dist;

        // Degenerate moves snap. This covers a disabled animation
        // (duration <= 0) as well as sub-pixel movement.
        if (self.duration_ms <= 0 or dist < min_distance_px) {
            self.start = rect;
            self.end_ms = now_ms;
            self.animating = false;
            return;
        }

        self.start = from;
        self.end_ms = now_ms + self.totalMs();
        self.animating = true;
    }

    /// Evaluate the animation at `now_ms`.
    pub fn sample(self: *const CursorMotion, now_ms: f32) Sample {
        const rect = self.base(now_ms);

        // Outside the animation window there is nothing to deform and
        // nothing to trail.
        if (!self.animating or
            now_ms <= self.start_ms or
            now_ms >= self.end_ms) return .{ .rect = rect };

        const tau = (now_ms - self.start_ms) / self.duration_ms;

        return switch (self.style) {
            .ease => .{ .rect = rect },

            .spring => spring: {
                // The tail is simply where we were a moment ago. During the
                // overshoot this streaks backwards towards the target,
                // which is exactly the read we want.
                const tail: Rect = .lerp(
                    self.start,
                    self.target,
                    springStep(tau - spring_trail_lag),
                );
                const gap = distance(tail, rect);
                if (gap < min_trail_px) break :spring .{ .rect = rect };

                // Fade with the gap rather than with time so that the
                // overshoot keeps a faint streak instead of vanishing.
                const ref = @max(self.distance * 0.2, min_trail_px);
                break :spring .{
                    .rect = rect,
                    .trail = .bounds(tail, rect),
                    .trail_line = trailLine(tail, rect),
                    .trail_alpha = @min(gap / ref, 1.0),
                };
            },

            .smear => smear: {
                // `rect` is the head, which has already finished its move
                // by smear_head_factor of the duration. The tail eases over
                // the full duration.
                const tail: Rect = .lerp(
                    self.start,
                    self.target,
                    easeOutCubic(@min(tau, 1.0)),
                );
                const gap = distance(tail, rect);
                if (gap < min_trail_px) break :smear .{ .rect = rect };
                break :smear .{
                    .rect = rect,
                    .trail = .bounds(tail, rect),
                    .trail_line = trailLine(tail, rect),
                    // Fades 1 -> 0 over the move as the tail catches up.
                    .trail_alpha = 1.0 - @min(tau, 1.0),
                };
            },

            .squash => .{ .rect = squashRect(
                rect,
                self.axis(),
                squashAmount(tau),
            ) },
        };
    }

    /// True while animating, meaning the caller must keep frames flowing.
    /// Goes false once we're settled on the target.
    pub fn isActive(self: *const CursorMotion, now_ms: f32) bool {
        return self.animating and now_ms < self.end_ms;
    }

    /// Snap instantly to `rect`, cancelling any animation. Used on focus
    /// loss, resize, scroll, and when the user prefers reduced motion.
    pub fn snap(self: *CursorMotion, rect: Rect) void {
        self.start = rect;
        self.target = rect;
        self.distance = 0;
        self.end_ms = self.start_ms;
        self.animating = false;
    }

    /// Change the style. An in-flight animation keeps its start, target,
    /// and start time, and simply re-derives its settle time, so a config
    /// reload mid-move stays continuous in position.
    pub fn setStyle(self: *CursorMotion, style: Style) void {
        if (self.style == style) return;
        self.style = style;
        if (self.animating) self.end_ms = self.start_ms + self.totalMs();
    }

    /// Change the nominal duration. A duration of zero or less disables
    /// animation entirely, which immediately settles any in-flight move.
    pub fn setDuration(self: *CursorMotion, duration_ms: f32) void {
        if (self.duration_ms == duration_ms) return;
        self.duration_ms = duration_ms;
        if (duration_ms <= 0) {
            self.snap(self.target);
            return;
        }
        if (self.animating) self.end_ms = self.start_ms + self.totalMs();
    }

    /// The undeformed rect at `now_ms`: pure interpolation between start
    /// and target with no squash and no trail. This is the geometric spine
    /// of the animation that every style shares.
    fn base(self: *const CursorMotion, now_ms: f32) Rect {
        if (!self.animating) return self.target;
        if (now_ms >= self.end_ms) return self.target;
        if (now_ms <= self.start_ms) return self.start;
        const tau = (now_ms - self.start_ms) / self.duration_ms;
        return .lerp(self.start, self.target, self.progress(tau));
    }

    /// Normalized 0..1 (spring may exceed 1) progress along start -> target
    /// for a normalized elapsed time `tau` (elapsed / duration).
    fn progress(self: *const CursorMotion, tau: f32) f32 {
        return switch (self.style) {
            .ease, .squash => easeOutCubic(@min(tau, 1.0)),
            // The head finishes early; the tail is computed in `sample`.
            .smear => easeOutCubic(@min(tau / smear_head_factor, 1.0)),
            .spring => springStep(tau),
        };
    }

    /// Total wall time of the current animation, in milliseconds, from
    /// start to fully settled.
    fn totalMs(self: *const CursorMotion) f32 {
        return self.duration_ms * switch (self.style) {
            .ease, .smear => 1.0,
            .squash => 1.0 + squash_bounce,
            // Settle once the oscillation can no longer be more than half
            // a pixel from the target, clamped so we always animate for at
            // least the duration and never longer than the cap.
            .spring => spring: {
                const residual = @max(
                    self.distance * spring_gain,
                    spring_settle_px,
                );
                break :spring std.math.clamp(
                    @log(residual / spring_settle_px) /
                        (spring_zeta * spring_omega),
                    1.0,
                    spring_max_factor,
                );
            },
        };
    }

    /// The dominant axis of travel, 0 for horizontal and 1 for vertical.
    /// Used to pick the stretch direction for the squash style.
    fn axis(self: *const CursorMotion) usize {
        const a = self.start.center();
        const b = self.target.center();
        return if (@abs(b[0] - a[0]) >= @abs(b[1] - a[1])) 0 else 1;
    }
};

/// Cubic ease-out. f(0) = 0, f(1) = 1, and the derivative decays from 3 to 0.
fn easeOutCubic(t: f32) f32 {
    const inv = 1.0 - t;
    return 1.0 - (inv * inv * inv);
}

/// Closed-form unit step response of an under-damped second order spring
/// with zero initial velocity, evaluated at normalized time `tau`.
///
/// This is deliberately a closed form rather than a per-frame integrator:
/// `sample` is const and must return the same answer for the same time no
/// matter how many times, or in what order, it is called.
fn springStep(tau: f32) f32 {
    if (tau <= 0) return 0;
    const zw = spring_zeta * spring_omega;
    const wd = spring_omega * @sqrt(1.0 - (spring_zeta * spring_zeta));
    return 1.0 - (@exp(-zw * tau) *
        (@cos(wd * tau) + ((zw / wd) * @sin(wd * tau))));
}

/// The signed stretch along the direction of travel at normalized time
/// `tau`: positive elongates, negative compresses.
///
/// While moving this tracks the normalized velocity of the easing curve
/// (the derivative of `easeOutCubic`, scaled to 0..1) rather than any
/// frame delta, so it is frame-rate independent. A short ramp keeps it at
/// zero at tau = 0 so that starting or redirecting a move never pops the
/// quad. After arrival a decaying sine gives a small settle bounce.
fn squashAmount(tau: f32) f32 {
    if (tau <= 0) return 0;

    if (tau < 1.0) {
        const inv = 1.0 - tau;
        const velocity = inv * inv;
        const ramp = @min(tau / squash_ramp, 1.0);
        return squash_max_stretch * velocity * ramp;
    }

    const u = (tau - 1.0) / squash_bounce;
    if (u >= 1.0) return 0;
    return -squash_bounce_amplitude * @exp(-4.0 * u) *
        @sin(2.0 * std.math.pi * u);
}

/// Stretch `rect` along `ax` by `amount`, thinning the other axis by the
/// reciprocal so that the area is conserved, keeping the center fixed.
fn squashRect(rect: Rect, ax: usize, amount: f32) Rect {
    if (amount == 0) return rect;
    const scale = 1.0 + amount;
    const other = 1 - ax;
    const c = rect.center();

    var out = rect;
    out.size[ax] = rect.size[ax] * scale;
    out.size[other] = rect.size[other] / scale;
    out.pos[ax] = c[ax] - (out.size[ax] / 2);
    out.pos[other] = c[other] - (out.size[other] / 2);
    return out;
}

fn trailLine(a: Rect, b: Rect) TrailLine {
    // A ribbon roughly one cursor-stroke wide reads clearly for block,
    // underline, and bar cursors alike. The head is drawn above it, so the
    // exact end cap is deliberately unimportant.
    return .{
        .from = a.center(),
        .to = b.center(),
        .thickness = @max(1.0, @min(
            @min(a.size[0], a.size[1]),
            @min(b.size[0], b.size[1]),
        )),
    };
}

/// How far apart two rects are, in pixels. This is the larger of the
/// center displacement and the size change so that a pure resize (a cursor
/// style change, say) still animates.
fn distance(a: Rect, b: Rect) f32 {
    const ca = a.center();
    const cb = b.center();
    const moved = std.math.hypot(cb[0] - ca[0], cb[1] - ca[1]);
    const resized = std.math.hypot(
        b.size[0] - a.size[0],
        b.size[1] - a.size[1],
    );
    return @max(moved, resized);
}

fn mix(a: f32, b: f32, t: f32) f32 {
    return a + ((b - a) * t);
}

test "cursor_motion: snap is instant" {
    const testing = std.testing;

    var m: CursorMotion = .init(.spring, 100);
    const rect: Rect = .{ .pos = .{ 10, 20 }, .size = .{ 8, 16 } };
    m.setTarget(rect, 0);
    try testing.expect(m.isActive(0));

    m.snap(.{ .pos = .{ 100, 200 }, .size = .{ 8, 16 } });
    try testing.expect(!m.isActive(0));
    try testing.expect(!m.isActive(1000));

    const s = m.sample(0);
    try testing.expectEqual(@as(f32, 100), s.rect.pos[0]);
    try testing.expectEqual(@as(f32, 200), s.rect.pos[1]);
    try testing.expect(s.trail == null);
    try testing.expectEqual(@as(f32, 0), s.trail_alpha);
}

test "cursor_motion: ease reaches target exactly at duration" {
    const testing = std.testing;

    var m: CursorMotion = .init(.ease, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    const target: Rect = .{ .pos = .{ 200, 40 }, .size = .{ 10, 20 } };
    m.setTarget(target, 0);

    // Starts exactly on the origin rect.
    const first = m.sample(0);
    try testing.expectEqual(@as(f32, 0), first.rect.pos[0]);
    try testing.expect(first.trail == null);

    // Ease-out: more than half the distance is covered in half the time.
    const mid = m.sample(50);
    try testing.expect(mid.rect.pos[0] > 100);
    try testing.expect(mid.rect.pos[0] < 200);

    // Exact arrival, and it stays there.
    const end = m.sample(100);
    try testing.expectEqual(target.pos[0], end.rect.pos[0]);
    try testing.expectEqual(target.pos[1], end.rect.pos[1]);
    try testing.expectEqual(target.size[0], end.rect.size[0]);
    try testing.expectEqual(target.size[1], end.rect.size[1]);
    try testing.expectEqual(target.pos[0], m.sample(1_000).rect.pos[0]);
}

test "cursor_motion: ease interpolates size as well as position" {
    const testing = std.testing;

    var m: CursorMotion = .init(.ease, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 100, 0 }, .size = .{ 2, 20 } }, 0);

    const mid = m.sample(50).rect;
    try testing.expect(mid.size[0] < 10);
    try testing.expect(mid.size[0] > 2);
    try testing.expectEqual(@as(f32, 20), mid.size[1]);
    try testing.expectEqual(@as(f32, 2), m.sample(100).rect.size[0]);
}

test "cursor_motion: ease never produces a trail" {
    const testing = std.testing;

    var m: CursorMotion = .init(.ease, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 400, 0 }, .size = .{ 10, 20 } }, 0);

    var t: f32 = 0;
    while (t <= 120) : (t += 1) {
        const s = m.sample(t);
        try testing.expect(s.trail == null);
        try testing.expectEqual(@as(f32, 0), s.trail_alpha);
    }
}

test "cursor_motion: zero duration snaps" {
    const testing = std.testing;

    var m: CursorMotion = .init(.smear, 0);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 500, 300 }, .size = .{ 10, 20 } }, 0);

    try testing.expect(!m.isActive(0));
    try testing.expectEqual(@as(f32, 500), m.sample(0).rect.pos[0]);
    try testing.expect(m.sample(0).trail == null);
}

test "cursor_motion: sub-pixel movement snaps" {
    const testing = std.testing;

    var m: CursorMotion = .init(.spring, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 0.4, 0.2 }, .size = .{ 10, 20 } }, 0);

    try testing.expect(!m.isActive(0));
    try testing.expectEqual(@as(f32, 0.4), m.sample(0).rect.pos[0]);
}

test "cursor_motion: repeated setTarget does not restart" {
    const testing = std.testing;

    var m: CursorMotion = .init(.ease, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    const target: Rect = .{ .pos = .{ 100, 0 }, .size = .{ 10, 20 } };
    m.setTarget(target, 0);

    const expected = m.sample(50).rect.pos[0];

    // The renderer calls setTarget unconditionally every frame; the same
    // rect must not restart or perturb the in-flight animation.
    m.setTarget(target, 10);
    m.setTarget(target, 20);
    m.setTarget(target, 50);
    try testing.expectEqual(expected, m.sample(50).rect.pos[0]);
    try testing.expectEqual(@as(f32, 100), m.end_ms);
}

test "cursor_motion: mid-flight retarget is continuous" {
    const testing = std.testing;

    // The whole point of retargeting from the current interpolated rect:
    // whatever we drew on the frame before the retarget must be what we
    // draw on the frame of the retarget. This must hold for every style,
    // deformations included.
    for (std.enums.values(Style)) |style| {
        var m: CursorMotion = .init(style, 100);
        m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
        m.setTarget(.{ .pos = .{ 300, 0 }, .size = .{ 10, 20 } }, 0);

        const before = m.sample(37).rect;
        m.setTarget(.{ .pos = .{ 0, 200 }, .size = .{ 10, 20 } }, 37);
        const after = m.sample(37).rect;

        try testing.expectApproxEqAbs(before.pos[0], after.pos[0], 0.001);
        try testing.expectApproxEqAbs(before.pos[1], after.pos[1], 0.001);
        try testing.expectApproxEqAbs(before.size[0], after.size[0], 0.001);
        try testing.expectApproxEqAbs(before.size[1], after.size[1], 0.001);

        // And it must not jump back towards the original start: the very
        // next frame continues onwards from where we were.
        const next = m.sample(38).rect;
        try testing.expect(next.pos[1] > before.pos[1]);

        // The redirected move still lands exactly on the new target.
        try testing.expect(!m.isActive(10_000));
        const settled = m.sample(10_000).rect;
        try testing.expectEqual(@as(f32, 0), settled.pos[0]);
        try testing.expectEqual(@as(f32, 200), settled.pos[1]);
        try testing.expectEqual(@as(f32, 10), settled.size[0]);
        try testing.expectEqual(@as(f32, 20), settled.size[1]);
    }
}

test "cursor_motion: spring overshoots and settles" {
    const testing = std.testing;

    var m: CursorMotion = .init(.spring, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 100, 0 }, .size = .{ 10, 20 } }, 0);

    // Somewhere in the flight we must go past the target.
    var peak: f32 = 0;
    var t: f32 = 0;
    while (t <= 200) : (t += 0.5) {
        peak = @max(peak, m.sample(t).rect.pos[0]);
    }
    try testing.expect(peak > 100);
    // ...but only slightly. This is a caret, not a slingshot.
    try testing.expect(peak < 115);

    // It comes back down: after the first peak there is a frame below the
    // target, which is the single gentle oscillation we're after.
    var dipped = false;
    t = 60;
    while (t <= 200) : (t += 0.5) {
        if (m.sample(t).rect.pos[0] < 99.9) dipped = true;
    }
    try testing.expect(dipped);

    // Settles within ~1.5x the duration for a move of this size. The
    // half-pixel guarantee is at the settle instant, which is what makes
    // going idle invisible; the envelope decays so the frames leading up
    // to it are only slightly looser.
    try testing.expect(m.end_ms <= 160);
    try testing.expect(@abs(m.sample(m.end_ms - 0.01).rect.pos[0] - 100) <
        spring_settle_px);
    t = m.end_ms - 5;
    while (t < m.end_ms) : (t += 0.1) {
        try testing.expect(@abs(m.sample(t).rect.pos[0] - 100) < 1.0);
    }
    try testing.expectEqual(@as(f32, 100), m.sample(m.end_ms).rect.pos[0]);
}

test "cursor_motion: spring residual is sub-pixel at settle for any distance" {
    const testing = std.testing;

    for ([_]f32{ 2, 8, 20, 100, 500, 2_000 }) |dist| {
        var m: CursorMotion = .init(.spring, 100);
        m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
        m.setTarget(.{ .pos = .{ dist, 0 }, .size = .{ 10, 20 } }, 0);
        const residual = @abs(m.sample(m.end_ms - 0.01).rect.pos[0] - dist);
        // The cap can cut a very long move short; everything within the
        // uncapped range must land under the threshold.
        if (m.end_ms < 100 * spring_max_factor) {
            try testing.expect(residual < spring_settle_px);
        }
        try testing.expect(residual < 2.0);
    }
}

test "cursor_motion: spring settle time is bounded" {
    const testing = std.testing;

    var m: CursorMotion = .init(.spring, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 100_000, 0 }, .size = .{ 10, 20 } }, 0);

    // Even an absurd distance is capped.
    try testing.expectEqual(@as(f32, 100 * spring_max_factor), m.end_ms);
    try testing.expect(!m.isActive(m.end_ms));
}

test "cursor_motion: smear trail spans head and tail" {
    const testing = std.testing;

    var m: CursorMotion = .init(.smear, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 300, 0 }, .size = .{ 10, 20 } }, 0);

    const s = m.sample(30);
    const trail = s.trail orelse return error.TestExpectedTrail;

    // The head leads the tail.
    const tail: Rect = .lerp(m.start, m.target, easeOutCubic(0.3));
    try testing.expect(s.rect.pos[0] > tail.pos[0]);

    // The trail is the bounding rect of the two, so it contains both and
    // is longer than either.
    try testing.expectApproxEqAbs(tail.pos[0], trail.pos[0], 0.001);
    try testing.expectApproxEqAbs(
        s.rect.pos[0] + s.rect.size[0],
        trail.pos[0] + trail.size[0],
        0.001,
    );
    try testing.expect(trail.size[0] > s.rect.size[0]);
    try testing.expectApproxEqAbs(@as(f32, 20), trail.size[1], 0.001);

    // The head arrives early, the tail keeps going.
    try testing.expectEqual(@as(f32, 300), m.sample(60).rect.pos[0]);
    try testing.expect(m.sample(70).trail != null);
}

test "cursor_motion: smear trail spans diagonal and vertical moves" {
    const testing = std.testing;

    for ([_][2]f32{
        .{ 0, 300 }, // vertical
        .{ 300, 300 }, // diagonal
        .{ -300, 150 }, // diagonal, backwards
    }) |delta| {
        var m: CursorMotion = .init(.smear, 100);
        m.snap(.{ .pos = .{ 400, 400 }, .size = .{ 10, 20 } });
        m.setTarget(.{
            .pos = .{ 400 + delta[0], 400 + delta[1] },
            .size = .{ 10, 20 },
        }, 0);

        const s = m.sample(30);
        const trail = s.trail orelse return error.TestExpectedTrail;
        const tail: Rect = .lerp(m.start, m.target, easeOutCubic(0.3));
        const want: Rect = .bounds(tail, s.rect);
        try testing.expectApproxEqAbs(want.pos[0], trail.pos[0], 0.001);
        try testing.expectApproxEqAbs(want.pos[1], trail.pos[1], 0.001);
        try testing.expectApproxEqAbs(want.size[0], trail.size[0], 0.001);
        try testing.expectApproxEqAbs(want.size[1], trail.size[1], 0.001);

        // The bounding rect must contain both quads.
        try testing.expect(trail.size[0] >= s.rect.size[0]);
        try testing.expect(trail.size[1] >= s.rect.size[1]);
    }
}

test "cursor_motion: diagonal smear exposes a directional trail" {
    var motion = CursorMotion.init(.smear, 100);
    motion.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    motion.setTarget(.{ .pos = .{ 30, 40 }, .size = .{ 10, 20 } }, 0);

    const sample = motion.sample(30);
    const line = sample.trail_line orelse return error.TestExpectedEqual;
    try std.testing.expect(line.to[0] > line.from[0]);
    try std.testing.expect(line.to[1] > line.from[1]);
    // The ribbon width is a cursor stroke, not the diagonal bounding box.
    try std.testing.expectEqual(@as(f32, 10), line.thickness);
}

test "cursor_motion: smear trail alpha fades to zero" {
    const testing = std.testing;

    var m: CursorMotion = .init(.smear, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 300, 0 }, .size = .{ 10, 20 } }, 0);

    var prev: f32 = 1.1;
    var t: f32 = 1;
    while (t < 100) : (t += 1) {
        const s = m.sample(t);
        if (s.trail == null) {
            try testing.expectEqual(@as(f32, 0), s.trail_alpha);
            continue;
        }
        try testing.expect(s.trail_alpha >= 0 and s.trail_alpha <= 1);
        try testing.expect(s.trail_alpha < prev);
        prev = s.trail_alpha;
    }

    // Nothing left once we're settled.
    const done = m.sample(100);
    try testing.expect(done.trail == null);
    try testing.expectEqual(@as(f32, 0), done.trail_alpha);
}

test "cursor_motion: squash conserves area" {
    const testing = std.testing;

    var m: CursorMotion = .init(.squash, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 300, 0 }, .size = .{ 10, 20 } }, 0);

    const area = 10.0 * 20.0;
    var max_stretch: f32 = 1;
    var t: f32 = 0;
    while (t <= 130) : (t += 0.5) {
        const r = m.sample(t).rect;
        try testing.expectApproxEqRel(area, r.size[0] * r.size[1], 0.0001);
        max_stretch = @max(max_stretch, r.size[0] / 10.0);
    }

    // Stretches along the direction of travel, up to ~1.35x.
    try testing.expect(max_stretch > 1.1);
    try testing.expect(max_stretch <= 1.0 + squash_max_stretch + 0.001);
}

test "cursor_motion: squash stretches along the axis of travel" {
    const testing = std.testing;

    var m: CursorMotion = .init(.squash, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 0, 300 }, .size = .{ 10, 20 } }, 0);

    // A vertical move stretches vertically and thins horizontally.
    const r = m.sample(15).rect;
    try testing.expect(r.size[1] > 20);
    try testing.expect(r.size[0] < 10);

    // The center is preserved by the deformation.
    const base = Rect.lerp(m.start, m.target, easeOutCubic(0.15));
    try testing.expectApproxEqAbs(base.center()[1], r.center()[1], 0.001);
    try testing.expectApproxEqAbs(base.center()[0], r.center()[0], 0.001);
}

test "cursor_motion: squash bounces then settles on target" {
    const testing = std.testing;

    var m: CursorMotion = .init(.squash, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 300, 0 }, .size = .{ 10, 20 } }, 0);

    // Position arrives on schedule (center of a 10px wide rect at x=300),
    // but we keep animating for the bounce.
    try testing.expectApproxEqAbs(
        @as(f32, 305),
        m.sample(100).rect.center()[0],
        0.001,
    );
    try testing.expect(m.isActive(100));

    // The bounce compresses along the travel axis after arrival.
    var min_len: f32 = 10;
    var t: f32 = 100;
    while (t <= 130) : (t += 0.5) {
        min_len = @min(min_len, m.sample(t).rect.size[0]);
    }
    try testing.expect(min_len < 10);
    try testing.expect(min_len > 9); // subtle, not a pancake

    // Fully settled at 1.3x duration, exactly on the target.
    try testing.expect(!m.isActive(130));
    const r = m.sample(130).rect;
    try testing.expectEqual(@as(f32, 300), r.pos[0]);
    try testing.expectEqual(@as(f32, 10), r.size[0]);
    try testing.expectEqual(@as(f32, 20), r.size[1]);
}

test "cursor_motion: isActive edge transitions" {
    const testing = std.testing;

    // Idle before anything happens.
    var m: CursorMotion = .init(.ease, 100);
    try testing.expect(!m.isActive(0));

    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    try testing.expect(!m.isActive(0));

    m.setTarget(.{ .pos = .{ 100, 0 }, .size = .{ 10, 20 } }, 1_000);
    try testing.expect(m.isActive(1_000));
    try testing.expect(m.isActive(1_099.9));
    // Exactly at the settle time we are done, not one frame later.
    try testing.expect(!m.isActive(1_100));
    try testing.expect(!m.isActive(1_101));

    // A snap mid-flight ends it immediately.
    m.setTarget(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } }, 2_000);
    try testing.expect(m.isActive(2_050));
    m.snap(.{ .pos = .{ 50, 50 }, .size = .{ 10, 20 } });
    try testing.expect(!m.isActive(2_050));
    try testing.expectEqual(@as(f32, 50), m.sample(2_050).rect.pos[0]);
}

test "cursor_motion: setStyle and setDuration" {
    const testing = std.testing;

    var m: CursorMotion = .init(.ease, 100);
    m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 300, 0 }, .size = .{ 10, 20 } }, 0);
    try testing.expectEqual(@as(f32, 100), m.end_ms);

    // Switching to squash mid-flight extends the settle time for the
    // bounce but keeps the position continuous in style-independent terms.
    m.setStyle(.squash);
    try testing.expectEqual(@as(f32, 130), m.end_ms);
    try testing.expect(m.isActive(100));

    // Lengthening the duration rescales the remaining flight.
    m.setStyle(.ease);
    m.setDuration(200);
    try testing.expectEqual(@as(f32, 200), m.end_ms);
    try testing.expect(m.isActive(150));

    // Disabling animation settles us immediately on the target.
    m.setDuration(0);
    try testing.expect(!m.isActive(0));
    try testing.expectEqual(@as(f32, 300), m.sample(0).rect.pos[0]);

    // And subsequent moves are instant.
    m.setTarget(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } }, 10);
    try testing.expect(!m.isActive(10));
    try testing.expectEqual(@as(f32, 0), m.sample(10).rect.pos[0]);
}

test "cursor_motion: all styles land exactly on target and go idle" {
    const testing = std.testing;

    for (std.enums.values(Style)) |style| {
        var m: CursorMotion = .init(style, 60);
        m.snap(.{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } });
        const target: Rect = .{ .pos = .{ 137, 42 }, .size = .{ 3, 20 } };
        m.setTarget(target, 500);

        // Sampling at a dense 120fps cadence must never produce a NaN or
        // a wildly out of range rect.
        var t: f32 = 500;
        while (t <= 700) : (t += 1.0 / 120.0 * 1000.0 / 8.0) {
            const s = m.sample(t);
            try testing.expect(!std.math.isNan(s.rect.pos[0]));
            try testing.expect(!std.math.isNan(s.rect.pos[1]));
            try testing.expect(s.rect.size[0] > 0);
            try testing.expect(s.rect.size[1] > 0);
            try testing.expect(s.trail_alpha >= 0 and s.trail_alpha <= 1);
            if (s.trail == null) {
                try testing.expectEqual(@as(f32, 0), s.trail_alpha);
            }
        }

        try testing.expect(!m.isActive(700));
        const s = m.sample(700);
        try testing.expect(s.trail == null);
        try testing.expectEqual(target.pos[0], s.rect.pos[0]);
        try testing.expectEqual(target.pos[1], s.rect.pos[1]);
        try testing.expectEqual(target.size[0], s.rect.size[0]);
        try testing.expectEqual(target.size[1], s.rect.size[1]);
    }
}

test "cursor_motion: pure resize animates" {
    const testing = std.testing;

    // A cursor style change (block -> bar) moves no distance but changes
    // size; that should still animate rather than pop.
    var m: CursorMotion = .init(.ease, 100);
    m.snap(.{ .pos = .{ 40, 40 }, .size = .{ 10, 20 } });
    m.setTarget(.{ .pos = .{ 40, 40 }, .size = .{ 2, 20 } }, 0);

    try testing.expect(m.isActive(0));
    const mid = m.sample(50).rect;
    try testing.expect(mid.size[0] < 10 and mid.size[0] > 2);
    try testing.expectEqual(@as(f32, 2), m.sample(100).rect.size[0]);
}

test "cursor_motion: Rect helpers" {
    const testing = std.testing;

    const a: Rect = .{ .pos = .{ 0, 0 }, .size = .{ 10, 20 } };
    const b: Rect = .{ .pos = .{ 100, 50 }, .size = .{ 20, 40 } };

    const half: Rect = .lerp(a, b, 0.5);
    try testing.expectEqual(@as(f32, 50), half.pos[0]);
    try testing.expectEqual(@as(f32, 25), half.pos[1]);
    try testing.expectEqual(@as(f32, 15), half.size[0]);
    try testing.expectEqual(@as(f32, 30), half.size[1]);

    const c = a.center();
    try testing.expectEqual(@as(f32, 5), c[0]);
    try testing.expectEqual(@as(f32, 10), c[1]);

    const bb: Rect = .bounds(a, b);
    try testing.expectEqual(@as(f32, 0), bb.pos[0]);
    try testing.expectEqual(@as(f32, 0), bb.pos[1]);
    try testing.expectEqual(@as(f32, 120), bb.size[0]);
    try testing.expectEqual(@as(f32, 90), bb.size[1]);

    try testing.expect(Rect.eql(a, a));
    try testing.expect(!Rect.eql(a, b));
}

test "cursor_motion: easing and spring curves" {
    const testing = std.testing;

    try testing.expectEqual(@as(f32, 0), easeOutCubic(0));
    try testing.expectEqual(@as(f32, 1), easeOutCubic(1));
    try testing.expect(easeOutCubic(0.5) > 0.5);

    try testing.expectEqual(@as(f32, 0), springStep(0));
    try testing.expectEqual(@as(f32, 0), springStep(-1));
    // The first peak overshoots by ~9.5% at ~0.49x the duration.
    try testing.expectApproxEqAbs(@as(f32, 1.095), springStep(0.491), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), springStep(2.0), 0.001);

    // Squash is continuous at both ends of the bounce window.
    try testing.expectEqual(@as(f32, 0), squashAmount(0));
    try testing.expectApproxEqAbs(@as(f32, 0), squashAmount(1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), squashAmount(1.3), 0.0001);
    try testing.expectEqual(@as(f32, 0), squashAmount(1.5));
    try testing.expect(squashAmount(1.05) < 0);
}
