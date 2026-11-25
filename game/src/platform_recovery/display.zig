//! Supported display scaling for the existing fixed canvases.
//!
//! The running loops already letterbox an integer multiple of a fixed canvas.
//! This module states that policy once: the supported domain is an integer
//! scale >= 1 on a window at least as large as the canvas minimum, centered with
//! the same truncated arithmetic the loops use.  A smaller or nonsensical window
//! returns a readable error instead of the old `@max(1, ...)` result, which drew
//! the canvas larger than the window and clipped it.
//!
//! The fractional 320x240 -> 640x480 opening overlay is deliberately not
//! converted here; changing it is a visual change and stays a native-review
//! blocker.

const std = @import("std");
const settings = @import("pause_menu");
const diagnostic = @import("diagnostic.zig");

pub const window_limit: i32 = 16384;

pub const Canvas = enum { field, journey, battle, replay_world, replay_field };

pub const Spec = struct {
    width: i32,
    height: i32,
    top: i32,
    min_width: i32,
    min_height: i32,
};

pub fn spec(canvas: Canvas) Spec {
    return switch (canvas) {
        // 512x432 field canvas, minimum window 512x432.
        .field => .{ .width = 512, .height = 432, .top = 0, .min_width = 512, .min_height = 432 },
        // journey_main.zig: 640x480 canvas, minimum window 640x480.
        .journey => .{ .width = 640, .height = 480, .top = 0, .min_width = 640, .min_height = 480 },
        // 640x480 battle canvas, minimum window 640x480.
        .battle => .{ .width = 640, .height = 480, .top = 0, .min_width = 640, .min_height = 480 },
        // world_replay_platform.zig: 320x240 world canvas under a 48px HUD,
        // minimum window 640x528.
        .replay_world => .{ .width = 320, .height = 240, .top = 48, .min_width = 640, .min_height = 528 },
        // world_replay_platform.zig: 512x432 field canvas under the same HUD.
        .replay_field => .{ .width = 512, .height = 432, .top = 48, .min_width = 640, .min_height = 528 },
    };
}

pub const Window = struct {
    width: i32,
    height: i32,
};

pub const ModeFade = struct {
    pub const half_ticks = 8;
    ticks_left: u8 = 0,

    pub fn begin(self: *ModeFade) void {
        if (!self.showsOutgoing()) self.ticks_left = 2 * half_ticks - self.ticks_left;
    }

    pub fn advance(self: *ModeFade, updates: u8) void {
        const remaining = self.ticks_left -| updates;
        // Always present black before revealing the incoming canvas.
        self.ticks_left = if (self.showsOutgoing()) @max(half_ticks, remaining) else remaining;
    }

    pub fn showsOutgoing(self: ModeFade) bool {
        return self.ticks_left > half_ticks;
    }

    pub fn alpha(self: ModeFade) u8 {
        const black_ticks = @min(self.ticks_left, 2 * half_ticks - self.ticks_left);
        return @intCast(@as(u16, black_ticks) * 255 / half_ticks);
    }
};

pub const Layout = struct {
    canvas: Canvas,
    scale: i32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Error = error{ InvalidWindowSize, UnsupportedWindowSize };

/// Pure integer layout.  Inputs in the documented supported domain reproduce
/// the current loop formula exactly; outside it the caller keeps the previous
/// layout and renders the readable diagnostic.
pub fn resolve(canvas: Canvas, window: Window) Error!Layout {
    const s = spec(canvas);
    if (window.width <= 0 or window.height <= 0 or window.width > window_limit or window.height > window_limit) {
        return error.InvalidWindowSize;
    }
    if (window.height <= s.top or window.width < s.min_width or window.height < s.min_height) {
        return error.UnsupportedWindowSize;
    }
    const available_height = window.height - s.top;
    const scale = @max(1, @min(@divTrunc(window.width, s.width), @divTrunc(available_height, s.height)));
    const width = s.width * scale;
    const height = s.height * scale;
    return .{
        .canvas = canvas,
        .scale = scale,
        .x = @divTrunc(window.width - width, 2),
        .y = s.top + @divTrunc(available_height - height, 2),
        .width = width,
        .height = height,
    };
}

/// Remembers the last valid layout.  An unsupported resize (including the
/// transient size some platforms report while a fullscreen change settles)
/// keeps the last valid layout instead of producing a clipped frame.
pub const Policy = struct {
    last: ?Layout = null,
    invalid_frames: u32 = 0,
    last_error: ?diagnostic.Diagnostic = null,

    pub fn layout(self: *Policy, canvas: Canvas, window: Window) Layout {
        const next = resolve(canvas, window) catch |err| {
            self.invalid_frames +|= 1;
            self.last_error = diagnostic.describe(err);
            if (self.last) |value| return value;
            // No valid layout yet: a 1x canvas at the origin is the only
            // renderable fallback, and the diagnostic above says why.
            return .{ .canvas = canvas, .scale = 1, .x = 0, .y = spec(canvas).top, .width = spec(canvas).width, .height = spec(canvas).height };
        };
        self.last = next;
        self.last_error = null;
        return next;
    }
};

pub const PreferenceSink = struct {
    context: *anyopaque,
    set_fullscreen: *const fn (context: *anyopaque, fullscreen: bool) anyerror!void,
    set_vsync: *const fn (context: *anyopaque, vsync: bool) anyerror!void,
};

pub const PreferenceResult = struct {
    value: settings.Value,
    changed: bool = false,
    diagnostic: ?diagnostic.Diagnostic = null,
};

/// Apply fullscreen/vsync through the existing settings adapter.  The platform
/// may reject a request (or accept only part of it); the logical value is then
/// rolled back to the previous one, so the Setup screen never shows a state the
/// window does not have.
pub fn applyPreferences(current: settings.Value, next: settings.Value, sink: PreferenceSink) PreferenceResult {
    next.validate() catch |err| {
        return .{ .value = current, .diagnostic = diagnostic.describe(err) };
    };
    if (next.fullscreen == current.fullscreen and next.vsync == current.vsync) {
        return .{ .value = next };
    }
    var applied_fullscreen = false;
    if (next.fullscreen != current.fullscreen) {
        sink.set_fullscreen(sink.context, next.fullscreen) catch {
            sink.set_fullscreen(sink.context, current.fullscreen) catch {};
            return .{ .value = current, .diagnostic = diagnostic.of(.fullscreen_rejected) };
        };
        applied_fullscreen = true;
    }
    if (next.vsync != current.vsync) {
        sink.set_vsync(sink.context, next.vsync) catch {
            if (applied_fullscreen) sink.set_fullscreen(sink.context, current.fullscreen) catch {};
            return .{ .value = current, .diagnostic = diagnostic.of(.vsync_rejected) };
        };
    }
    return .{ .value = next, .changed = true };
}

test "unsupported window is a typed error, not a clamped 1x overflow" {
    try std.testing.expectError(error.UnsupportedWindowSize, resolve(.field, .{ .width = 500, .height = 432 }));
    try std.testing.expectError(error.InvalidWindowSize, resolve(.field, .{ .width = 0, .height = 0 }));
}
