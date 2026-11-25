//! Source-backed dialogue-box state for event opcode 0x05.
//!
//! MAIN.EXE `dialogue_box_render` @0x8013BCDC uses state byte 0x8017C018.
//! State 0xFF is the build arm: the style byte is stored with bit 0x80 set and
//! a sprite handle is allocated. The open arm reads selector and completion
//! skip, sets state = (selector & 0x7F) + skip, and uses selector bit 0x80 as
//! the "changed" flag: changed rebuilds/draws; unchanged clears the draw flag
//! and frees the sprite. Pad-driven stepping and the renderer are outside this
//! model.
const std = @import("std");

pub const idle_state: u8 = 0xFF;

pub const Box = struct {
    state: u8 = idle_state,
    style: u8 = 0,
    handle: ?u32 = null,

    /// Arm A: box not built. Bit 0x80 is source state, not a style bit.
    pub fn open(self: *Box, style: u8, handle: u32) !void {
        if (self.state != idle_state or self.handle != null) return error.DialogueBoxAlreadyOpen;
        self.style = style;
        self.state = style | 0x80;
        self.handle = handle;
    }

    pub const Update = struct {
        state: u8,
        draw: bool,
        freed: bool,
    };

    /// Arm B: selector bit 0x80 means changed. Unchanged frees the sprite and
    /// returns the box to 0xFF, matching the source draw-flag/free arm.
    pub fn update(self: *Box, selector: u8, completion_skip: u8) !Update {
        if (self.state == idle_state or self.handle == null) return error.DialogueBoxNotOpen;
        const next: u8 = (selector & 0x7F) +% completion_skip;
        const changed = selector & 0x80 != 0;
        if (changed) {
            self.state = next;
            return .{ .state = next, .draw = true, .freed = false };
        }
        self.state = idle_state;
        self.handle = null;
        return .{ .state = idle_state, .draw = false, .freed = true };
    }
};
