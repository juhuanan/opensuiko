//! Field fade overlay state.
//!
//! Source anchors (MAIN.EXE, static analysis): mode-2 area initialization
//! @0x80130EC4 writes area_state+0x39 = 4 at 0x801310A4..0x801310A8;
//! event opcode 0x24 @0x80139BEC enables the overlay, starts level 0, sets
//! blend 2 / slot 10 and event flag 0x10; scroll_offset_accumulator
//! @0x8013ED6C adds 2*(area_state+0x39) at 0x8013EE6C, stores the byte level,
//! then compares it against 0xFF-2*step at 0x8013EE9C..0x8013EEA4. The
//! completion arm clamps to 0xFF and clears flag 0x10. Opcode 0x25 starts
//! at 255 with flag 0x40; its update arm subtracts twice the area step, then
//! clamps to zero and removes the overlay at completion (0x8013EEE4..0x8013EF5C).

const std = @import("std");

pub const Direction = enum { to_black, from_black };

pub const default_step: u8 = 4;
pub const active_flag: u16 = 0x0010;
pub const overlay_blend: u8 = 2;
pub const overlay_slot: u8 = 10;

pub const Wire = struct {
    schema: u8 = 1,
    enabled: bool,
    level: u8,
    blend: u8,
    slot: u8,
    step: u8,
    active: bool,
    direction: Direction = .to_black,

    pub fn jsonStringify(self: Wire, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Wire)) |name| {
            if (comptime !std.mem.eql(u8, name, "direction")) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            } else if (self.direction != .to_black) {
                try writer.objectField(name);
                try writer.write(self.direction);
            }
        }
        try writer.endObject();
    }
};

pub const OverlayDescriptor = struct {
    color: [3]u8,
    blend: u8,
    slot: u8,
    x: i16 = -160,
    y: i16 = -120,
    width: u16 = 320,
    height: u16 = 240,
};

pub const State = struct {
    enabled: bool = false,
    level: u8 = 0,
    blend: u8 = overlay_blend,
    slot: u8 = overlay_slot,
    step: u8 = default_step,
    /// Direction distinguishes the source to-black and from-black operations.
    active: bool = false,
    direction: Direction = .to_black,

    pub fn jsonStringify(self: State, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(State)) |name| {
            if (comptime !std.mem.eql(u8, name, "direction")) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            } else if (self.direction != .to_black) {
                try writer.objectField(name);
                try writer.write(self.direction);
            }
        }
        try writer.endObject();
    }

    pub fn initArea() State {
        return .{};
    }

    pub fn validate(self: State) !void {
        if (self.blend != overlay_blend or self.slot != overlay_slot) return error.InvalidFadeState;
        if (self.active and (!self.enabled or (self.direction == .to_black and self.level == 0xff) or (self.direction == .from_black and self.level == 0))) return error.InvalidFadeState;
        if (!self.enabled and (self.active or self.level != 0)) return error.InvalidFadeState;
        if (self.enabled and !self.active and (self.direction != .to_black or self.level != 0xff)) return error.InvalidFadeState;
    }

    pub fn request(self: *State) !void {
        try self.validate();
        if (self.active) return error.FadeAlreadyActive;
        self.enabled = true;
        self.direction = .to_black;
        self.level = 0;
        self.blend = overlay_blend;
        self.slot = overlay_slot;
        self.active = true;
    }

    pub fn requestIn(self: *State) !void {
        try self.validate();
        if (self.active) return error.FadeAlreadyActive;
        self.enabled = true;
        self.direction = .from_black;
        self.level = 255;
        self.blend = overlay_blend;
        self.slot = overlay_slot;
        self.active = true;
    }

    /// Event opcode 0x48 writes the shared per-area fade step byte.
    pub fn setStep(self: *State, step: u8) void {
        self.step = step;
    }

    /// Advance one source update; true means this update completed the fade.
    pub fn tick(self: *State) !bool {
        try self.validate();
        if (!self.active) return false;

        const amount: u16 = @as(u16, self.step) * 2;
        if (self.direction == .from_black) {
            self.level -%= @as(u8, @truncate(amount));
            if (@as(u16, self.level) <= amount) {
                self.level = 0;
                self.enabled = false;
                self.active = false;
                return true;
            }
            return false;
        }
        self.level = @truncate(@as(u16, self.level) + amount);
        const threshold: i16 = 255 - @as(i16, @intCast(amount));
        if (threshold < @as(i16, self.level)) {
            self.level = 0xff;
            self.active = false;
            return true;
        }
        return false;
    }

    pub fn overlay(self: State) ?OverlayDescriptor {
        if (!self.enabled) return null;
        return .{
            .color = .{ self.level, self.level, self.level },
            .blend = self.blend,
            .slot = self.slot,
        };
    }

    pub fn toWire(self: State) !Wire {
        try self.validate();
        return .{
            .schema = if (self.direction == .from_black) 2 else 1,
            .direction = self.direction,
            .enabled = self.enabled,
            .level = self.level,
            .blend = self.blend,
            .slot = self.slot,
            .step = self.step,
            .active = self.active,
        };
    }

    pub fn fromWire(wire: Wire) !State {
        if ((wire.schema == 1 and wire.direction != .to_black) or (wire.schema == 2 and wire.direction != .from_black) or (wire.schema != 1 and wire.schema != 2)) return error.InvalidFadeState;
        const state = State{
            .direction = wire.direction,
            .enabled = wire.enabled,
            .level = wire.level,
            .blend = wire.blend,
            .slot = wire.slot,
            .step = wire.step,
            .active = wire.active,
        };
        try state.validate();
        return state;
    }
};

/// MAIN 0x80132524 -> 0x801325A4 -> 0x80132790/0x80132938.
/// Callback ownership, not rendering, admits the next ordinary input frame.
pub const Entry = struct {
    phase: enum { pending, fade, handoff, ordinary } = .pending,
    title_hold: bool,
    held: u8 = 0,
    level: u8 = 255,

    pub fn validate(self: Entry) !void {
        if (self.held > 40 or (!self.title_hold and self.held != 0)) return error.InvalidEntryFade;
        if (self.phase == .pending and (self.held != 0 or self.level != 255)) return error.InvalidEntryFade;
        if ((self.phase == .handoff or self.phase == .ordinary) and self.level != 15) return error.InvalidEntryFade;
        if (self.phase == .fade and self.level % 16 != 15) return error.InvalidEntryFade;
        if (self.title_hold and self.level != 255 and self.held != 40) return error.InvalidEntryFade;
    }
    pub fn ordinaryReady(self: Entry) bool {
        return self.phase == .handoff or self.phase == .ordinary;
    }
    pub fn tick(self: *Entry, skip_title: bool) !void {
        try self.validate();
        switch (self.phase) {
            .pending => self.phase = .fade,
            .fade => {
                if (self.title_hold and self.held < 40) {
                    self.held = if (skip_title) 40 else self.held + 1;
                    if (self.held < 40) return;
                }
                if (self.level < 17) self.phase = .handoff else self.level -= 16;
            },
            .handoff => self.phase = .ordinary,
            .ordinary => {},
        }
    }
    pub fn overlay(self: Entry) ?OverlayDescriptor {
        if (self.phase != .fade) return null;
        return .{ .color = .{ self.level, self.level, self.level }, .blend = overlay_blend, .slot = overlay_slot };
    }
};
