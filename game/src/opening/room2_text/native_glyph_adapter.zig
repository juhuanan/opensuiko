//! Mirror a native prefix from the shared text clock; this module never ticks it.
const std = @import("std");
const slots = @import("native_slots.zig");

pub const Observation = struct {
    generation: u64,
    cursor: u8,
    countdown: u8,
    done: bool,
    /// Prefix fragment emitted so far, including its final newline when consumed.
    visible: []const u8,
};

pub const Adapter = struct {
    request: slots.Request,
    generation: u64,
    cursor: u8 = 0,
    countdown: u8,
    done: bool = false,
    visible_len: u8 = 0,
    visible: [33]u8 = @splat(0),

    /// Call after the owner's start proposal has been acknowledged. Countdown
    /// comes from the existing text object, not a newly started clock.
    pub fn start(owner: slots.Owner, request: slots.Request, name: slots.Name, countdown: u8) !Adapter {
        try owner.validate();
        const slot = owner.slots[@backingInt(request.slot)];
        if (slot.waiting == null or !std.meta.eql(slot.waiting.?, request) or slot.prefix == null or
            slot.prefix.?.consumed != 0 or slot.prefix.?.done) return error.InvalidNativeGlyphAdapter;
        const adapter: Adapter = .{ .request = request, .generation = slot.prefix.?.generation, .countdown = countdown };
        try adapter.validate(owner, name);
        return adapter;
    }

    /// Rebind name from the verified asset before validating a restored snapshot.
    pub fn validate(self: Adapter, owner: slots.Owner, name: slots.Name) !void {
        try owner.validate();
        const slot = owner.slots[@backingInt(self.request.slot)];
        if (!slots.hasPrefix(self.request.code) or name.code != self.request.code or
            name.text.len > 32 or name.glyph_ends.len > 32 or slot.waiting == null or
            !std.meta.eql(slot.waiting.?, self.request) or slot.prefix == null) return error.InvalidNativeGlyphAdapter;
        const prefix = slot.prefix.?;
        if (prefix.generation != self.generation or prefix.glyph_count != name.glyph_ends.len or
            prefix.consumed != self.cursor or prefix.done != self.done) return error.InvalidNativeGlyphAdapter;
        var last: usize = 0;
        for (name.glyph_ends) |end| {
            if (end <= last or end > name.text.len) return error.InvalidNativeGlyphAdapter;
            last = end;
        }
        if (last != name.text.len or self.cursor > name.glyph_ends.len + 1 or
            self.done != (self.cursor == name.glyph_ends.len + 1)) return error.InvalidNativeGlyphAdapter;
        const glyphs = @min(self.cursor, name.glyph_ends.len);
        const bytes: usize = if (glyphs == 0) 0 else name.glyph_ends[glyphs - 1];
        const length = bytes + @intFromBool(self.done);
        if (self.visible_len != length or !std.mem.eql(u8, self.visible[0..bytes], name.text[0..bytes]) or
            (self.done and self.visible[bytes] != '\n')) return error.InvalidNativeGlyphAdapter;
        for (self.visible[length..]) |byte| if (byte != 0) return error.InvalidNativeGlyphAdapter;
    }

    /// Observe the already-ticked shared text state; publish owner and adapter
    /// together only after both validate. A stationary cursor updates countdown
    /// but does not manufacture a glyph receipt.
    pub fn observe(self: *Adapter, owner: *slots.Owner, name: slots.Name, state: Observation) !void {
        try self.validate(owner.*, name);
        if (state.generation != self.generation or state.cursor < self.cursor or
            state.visible.len > self.visible.len) return error.StaleNativeGlyphObservation;
        var next = self.*;
        var next_owner = owner.*;
        if (state.cursor > self.cursor) {
            try next_owner.observeGlyphs(.{ .request = self.request, .generation = state.generation, .consumed = state.cursor, .done = state.done });
        } else if (state.done != self.done or !std.mem.eql(u8, state.visible, self.visible[0..self.visible_len])) {
            return error.StaleNativeGlyphObservation;
        }
        next.cursor = state.cursor;
        next.countdown = state.countdown;
        next.done = state.done;
        next.visible_len = @intCast(state.visible.len);
        @memset(&next.visible, 0);
        @memcpy(next.visible[0..state.visible.len], state.visible);
        try next.validate(next_owner, name);
        owner.* = next_owner;
        self.* = next;
    }
};
