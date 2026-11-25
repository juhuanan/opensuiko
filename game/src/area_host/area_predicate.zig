//! Source-backed event-selection predicates for the Opening first town.
//!
//! `archive/docs/entity_predicates.md`:
//!   0x0B/0x0C: lower <= hero X/Y <= upper (inclusive; 3 bytes)
//!   0x04:      pressed word 0x8017BDCC intersects mask table 0x80171708[index]
//!   0x09/0x0A: game_state[0x280+index] intersects / does not intersect mask
//!   0x01/0x02: lower < hero X/Y < upper (strict)
//! This module owns the pure comparisons; the host supplies the live words.
const std = @import("std");

pub const Position = struct { x: u8, y: u8 };

pub const Axis = enum { x, y };

pub const Bounds = enum { inclusive, strict };

pub fn coordinate(position: Position, axis: Axis, lower: u8, upper: u8, bounds: Bounds) bool {
    const value = switch (axis) {
        .x => position.x,
        .y => position.y,
    };
    return switch (bounds) {
        .inclusive => value >= lower and value <= upper,
        .strict => value > lower and value < upper,
    };
}

/// Source 0x04: the pressed word intersects the byte mask table entry.
pub fn inputIntersects(pressed: u16, mask_table: []const u8, index: u8) bool {
    if (index >= mask_table.len) return false;
    return pressed & mask_table[index] != 0;
}

/// Source 0x09/0x0A: the per-room byte intersects/does not intersect a mask.
pub fn roomByteIntersects(room_flags: []const u8, index: u8, mask: u8, set: bool) bool {
    if (index >= room_flags.len or mask == 0) return false;
    return (room_flags[index] & mask != 0) == set;
}
