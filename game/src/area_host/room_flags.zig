//! Source-backed per-room flag bytes for event opcode 0x16.
//!
//! MAIN.EXE `gamestate_or_byte_280` @0x8013CC04 ORs the operand bits into
//! game_state[0x280 + id]. The +0x280 region is a 20-byte per-room reset block
//! (room-entry path 0x801348C4 zeroes 0x14 bytes), so it is not story state.
//! This model owns those 20 bytes and the OR operation only.
const std = @import("std");
const predicate = @import("area_predicate.zig");

pub const bytes = 20;

pub const State = struct {
    values: [bytes]u8 = @splat(0),

    pub fn orByte(self: *State, id: u8, bits: u8) !void {
        if (id >= bytes) return error.RoomFlagOutOfRange;
        self.values[id] |= bits;
    }

    pub fn matches(self: *const State, index: u8, mask: u8, set: bool) bool {
        return predicate.roomByteIntersects(&self.values, index, mask, set);
    }

    pub fn clear(self: *State) void {
        self.values = @splat(0);
    }
};
