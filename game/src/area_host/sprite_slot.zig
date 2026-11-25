//! Source-backed sprite-slot state for Opening first-town.
//!
//! MAIN.EXE `event_slot_spawn_text` @0x8013B51C: if sprite_slot_flags[idx] is
//! set, rewind one byte and yield; otherwise allocate the text struct at screen
//! (x*8-0x96, y*8-0x68), size (w+8,h), store it in sprite_slot_table[idx],
//! clear the slot flags, clear the text buffer and issue display command 0x0501.
//!
//! `event_slot_flag_set` @0x8013B694: sprite_flag_set_state(handle,0x14),
//! sprite_slot_flags[idx] = 2, sprite_slot_byte_b5[idx] = 0, and raise event
//! state bit 1 for idx 0 else bit 2. The renderer itself is outside this model.
const std = @import("std");

pub const slots = 8;

pub const Slot = struct {
    flags: u8 = 0,
    byte_b5: u8 = 0,
    handle: ?u32 = null,
    screen_x: i16 = 0,
    screen_y: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
};

pub const State = struct {
    slots: [slots]Slot = @splat(.{}),
    flags: u16 = 0,
    next_handle: u32 = 1,

    pub fn spawn(self: *State, index: u8, x: u8, y: u8, w: u8, h: u8) !bool {
        if (index >= slots) return error.SpriteSlotOutOfRange;
        if (self.slots[index].flags != 0) return true;
        const slot = &self.slots[index];
        slot.handle = self.next_handle;
        self.next_handle += 1;
        slot.screen_x = @as(i16, x) * 8 - 0x96;
        slot.screen_y = @as(i16, y) * 8 - 0x68;
        slot.width = @as(u16, w) + 8;
        slot.height = h;
        slot.flags = 0;
        self.flags &= ~flagFor(index);
        return false;
    }

    pub fn flagSet(self: *State, index: u8) !void {
        if (index >= slots) return error.SpriteSlotOutOfRange;
        self.slots[index].flags = 2;
        self.slots[index].byte_b5 = 0;
        self.flags |= flagFor(index);
    }

    pub fn release(self: *State, index: u8) !void {
        if (index >= slots) return error.SpriteSlotOutOfRange;
        self.slots[index] = .{};
        self.flags &= ~flagFor(index);
    }

    fn flagFor(index: u8) u16 {
        return if (index == 0) 0x0001 else 0x0002;
    }
};
