//! Selector windows advance after their owning callback, independently of drawing.
const field = @import("field");

pub const Window = struct {
    // shortcut: nonoverlapping selector requests only; qualify concurrent open/close before adding other callers.
    pub const transition_updates: u8 = @import("party_data").selector.transition_updates;
    target: field.Rect,
    phase: enum { closed, opening, open, closing } = .closed,
    remaining: u8 = 0,

    pub fn init(target: field.Rect) !Window {
        if (target.w < 1 or target.h < 1 or target.x < -32768 or target.y < -32768 or
            target.w > 32767 or target.h > 32767 or target.x > 32767 - target.w or target.y > 32767 - target.h)
            return error.InvalidSelectorWindow;
        return .{ .target = target };
    }

    pub fn open(self: *Window) void {
        if (self.phase != .closed) return;
        self.phase = .opening;
        self.remaining = transition_updates;
    }

    pub fn close(self: *Window) void {
        if (self.phase != .open) return;
        self.phase = .closing;
        self.remaining = transition_updates;
    }

    pub fn ready(self: Window) bool {
        return self.remaining == 0;
    }

    // The callback observes the prior countdown; the window then decrements it.
    pub fn tick(self: *Window) void {
        switch (self.phase) {
            .opening, .closing => if (self.remaining != 0) {
                self.remaining -= 1;
            } else {
                self.phase = if (self.phase == .opening) .open else .closed;
            },
            .open, .closed => {},
        }
    }

    pub fn outline(self: Window) ?field.Rect {
        if (self.phase != .opening and self.phase != .closing) return null;
        const point: field.Rect = .{ .x = self.target.x + @divTrunc(self.target.w, 2), .y = self.target.y + @divTrunc(self.target.h, 2), .w = 1, .h = 1 };
        const amount = if (self.phase == .opening) transition_updates - self.remaining else self.remaining;
        return .{ .x = blend(point.x, self.target.x, amount), .y = blend(point.y, self.target.y, amount), .w = blend(point.w, self.target.w, amount), .h = blend(point.h, self.target.h, amount) };
    }

    fn blend(start: i32, end: i32, amount: u8) i32 {
        return @divTrunc(start * @as(i32, transition_updates - amount) + end * @as(i32, amount), transition_updates);
    }
};
