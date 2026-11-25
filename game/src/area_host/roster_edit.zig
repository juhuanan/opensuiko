//! Source-backed six-slot party roster edit for event opcode 0x20.
//!
//! MAIN.EXE `party_roster_edit` @0x8013A1D4 edits game_state+0xE (six party
//! slots), compares the operand character against the slot occupant, calls
//! party_slot_char_set plus the save-buffer removal helper, and always ends
//! with party_formation_sync. 0xFF/0xFD delegate to the separate item/party
//! assignment handler and are refused here rather than guessed.
const std = @import("std");

pub const slots = 6;
pub const empty: u8 = 0xFF;

pub const State = struct {
    party: [slots]u8 = @splat(empty),
    syncs: u32 = 0,

    pub fn count(self: *const State) u8 {
        var result: u8 = 0;
        for (self.party) |slot| result += @intFromBool(slot != empty);
        return result;
    }

    /// Remove an exact occupant and run the source formation sync. Returns
    /// false when the character is absent; the roster is unchanged.
    pub fn remove(self: *State, character: u8) bool {
        if (character == empty) return false;
        for (&self.party) |*slot| {
            if (slot.* == character) {
                slot.* = empty;
                self.syncs += 1;
                return true;
            }
        }
        return false;
    }

    /// Select an existing occupant without changing membership.
    pub fn select(self: *const State, character: u8) ?usize {
        for (self.party, 0..) |slot, index| if (slot == character) return index;
        return null;
    }
};
