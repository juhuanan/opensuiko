//! Source-backed area-tile descriptor object model for event opcode 0x4D.
//!
//! MAIN.EXE `tile_variant_set` @0x80138AC4 resolves
//! `area_tile_desc_table (+0x8017DAA0) + tile * 24`, reads the object pointer at
//! descriptor +8, takes the current variant from the low nibble of object +0,
//! then writes the new variant through obj_initializer and refreshes the draw
//! byte from the object's +0x14 table entry. `op == 2` waits while the object
//! flag word +4 has bit 0x10000. This module owns that small state machine; it
//! does not claim the renderer or the callback scan buffer.
const std = @import("std");

pub const object_flag_wait: u32 = 0x0001_0000;

pub const Object = struct {
    variant: u8 = 0,
    draw: u8 = 0,
    flags: u32 = 0,
};

pub const Descriptor = struct {
    x: u8 = 0,
    y: u8 = 0,
    object: ?*Object = null,
};

pub const Table = struct {
    descriptors: []Descriptor,
    /// The object's own +0x14 table entry byte +0, indexed by variant.
    draw_by_variant: []const u8,
};

pub const Op = enum { increment, decrement, absolute, wait };

pub fn resolve(table: *const Table, tile: u8) ?*Descriptor {
    const index = @as(usize, tile);
    if (index >= table.descriptors.len) return null;
    return &table.descriptors[index];
}

/// Apply one source `0x4D` operation. `wait` returns true without mutation while
/// the object's flag word has bit 0x10000, matching the handler's rewind arm.
pub fn apply(table: *const Table, descriptor: *Descriptor, op: Op, absolute: u8) !bool {
    const object = descriptor.object orelse return error.MissingAreaTileObject;
    if (op == .wait) return object.flags & object_flag_wait != 0;
    const current = object.variant & 0x0F;
    const variant: u8 = switch (op) {
        .increment => (current +% 1) & 0x0F,
        .decrement => (current -% 1) & 0x0F,
        .absolute => absolute & 0x0F,
        .wait => unreachable,
    };
    if (variant >= table.draw_by_variant.len) return error.MissingAreaTileVariant;
    const draw = table.draw_by_variant[variant];
    object.variant = variant;
    object.draw = draw;
    return false;
}
