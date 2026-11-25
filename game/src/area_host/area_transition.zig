//! Source-backed area/menu transition parameter state for event opcode 0x43.
//!
//! MAIN.EXE `area_transition_param_set` @0x801397D0 stores the selector in
//! area_state+0x4E0 (0xFF is stored as 0), resolves an area-struct +0x10 table
//! entry, and for selector 0xFF/0x80 publishes the entry word to the one-shot
//! callback at area_state+0x498; otherwise publishes entry+0xC to the menu gold
//! word at area_state+0x494. It clears entity collision, sets
//! entity_flag_byte_80171C29 and game_driver_word_dc4c. This model owns those
//! observable fields; the entry table itself is supplied by the area owner.
const std = @import("std");

pub const State = struct {
    transition: u8 = 0,
    callback: ?u16 = null,
    menu_word: ?u16 = null,
    collision_enabled: bool = true,
    entity_flag: bool = false,
    driver_word: u16 = 0,

    /// `entry` is the resolved 16-bit word: the one-shot callback for
    /// 0xFF/0x80, otherwise the menu/gold word (entry+0xC is already resolved
    /// by the caller to that word).
    pub fn begin(self: *State, selector: u8, entry: u16) void {
        self.transition = if (selector == 0xFF) 0 else selector;
        if (selector == 0xFF or selector == 0x80) {
            self.callback = entry;
            self.menu_word = null;
        } else {
            self.menu_word = entry;
            self.callback = null;
        }
        self.collision_enabled = false;
        self.entity_flag = true;
        self.driver_word = 1;
    }
};
