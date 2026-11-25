//! Rune/weapon-fragment loadout identity across field and battle.
//!
//! Persistent character record fields (proven by
//! `weapon_rune_fragments.md` and `rune_preparation_port.md`):
//!
//! * `+0x46` active weapon rune-piece type (0 none, 1..5);
//! * `+0x47..+0x4B` the five piece counts;
//! * `+0x4C` rune byte (0 none, 1..31, 32 masked, 33 True Holy);
//! * `+0x4D` rune detach lock.
//!
//! Four charge counters live in the battle/menu state, not in the persistent
//! record.  A field/battle transition therefore has to carry the rune byte,
//! its charges, the lock and the fragment vector without re-deriving them from
//! names, crystals or any generic rune id.

const std = @import("std");
const physical = @import("physical.zig");

pub const charge_slots = 4;
pub const fragment_slots = 5;
pub const no_rune: u8 = 0;
pub const masked_rune: u8 = 32;
pub const true_holy_rune: u8 = 33;

pub const RuneSlot = struct {
    byte: u8 = no_rune,
    charges: [charge_slots]u16 = @splat(0),
    locked: bool = false,
};

pub const Fragments = struct {
    active_type: u8 = 0,
    counts: [fragment_slots]u8 = @splat(0),
};

pub const Loadout = struct {
    /// Source character id (SLUS record order); transitions never cross it.
    member: u16,
    weapon_level: u8 = 1,
    rune: RuneSlot = .{},
    fragments: Fragments = .{},
};

pub const Error = error{
    UnknownRuneByte,
    RuneChanged,
    LockedRuneChanged,
    FragmentChanged,
    MemberChanged,
    LoadoutChanged,
    ChargesExceeded,
    InvalidFragmentType,
    InvalidChargeSlot,
};

/// A byte is known only when it is 0 (none) or one of 1..33.  Reserved
/// identities (1 Soul Eater, 32 masked, 33 True Holy) are valid bytes but have
/// no generic action substitution.
pub fn validRuneByte(byte: u8) bool {
    return byte == no_rune or (byte >= 1 and byte <= true_holy_rune);
}

pub fn carriesAction(byte: u8) bool {
    return physical.techniqueForRune(byte) != null or (byte >= 2 and byte <= 31);
}

/// A field/battle transition keeps the persistent identity and the exact
/// charge counters.  It never refills them (the inn service does that) and it
/// refuses a substitution.
pub fn carry(source: Loadout, destination: Loadout) Error!Loadout {
    if (source.member != destination.member) return error.MemberChanged;
    if (!validRuneByte(source.rune.byte) or !validRuneByte(destination.rune.byte))
        return error.UnknownRuneByte;
    if (source.rune.byte != destination.rune.byte) return error.RuneChanged;
    if (source.rune.locked != destination.rune.locked) return error.LockedRuneChanged;
    if (source.weapon_level != destination.weapon_level) return error.LoadoutChanged;
    if (!std.meta.eql(source.fragments, destination.fragments)) return error.FragmentChanged;
    return .{
        .member = source.member,
        .weapon_level = source.weapon_level,
        .rune = .{
            .byte = source.rune.byte,
            .charges = source.rune.charges,
            .locked = source.rune.locked,
        },
        .fragments = source.fragments,
    };
}

/// Restore the persistent charges into a live slot.  `maximum` is the rune's
/// tier capacity used by the battle rules; a stored charge above capacity is a
/// malformed record and is rejected rather than clamped silently.
pub fn restoreCharges(persistent: RuneSlot, live: RuneSlot, maximum: [charge_slots]u16) Error!RuneSlot {
    if (persistent.byte != live.byte) return error.RuneChanged;
    if (persistent.locked != live.locked) return error.LockedRuneChanged;
    for (persistent.charges, maximum) |stored, cap| {
        if (stored > cap) return error.ChargesExceeded;
    }
    for (live.charges, maximum) |running, cap| {
        if (running > cap) return error.ChargesExceeded;
    }
    return .{ .byte = persistent.byte, .charges = persistent.charges, .locked = persistent.locked };
}

/// The inn's proven service sets every counter to its maximum.  Kept separate
/// from transitions so a field/battle round-trip can never masquerade as one.
pub fn innRecover(slot: RuneSlot, maximum: [charge_slots]u16) RuneSlot {
    return .{ .byte = slot.byte, .charges = maximum, .locked = slot.locked };
}

pub fn attach(current: Loadout, requested: u8, maximum: [charge_slots]u16) Error!Loadout {
    if (!validRuneByte(requested)) return error.UnknownRuneByte;
    // A locked slot cannot be re-attached, not even to the same rune: the
    // source guard rejects an occupied slot before checking permissions, and a
    // starting locked rune is valid only as existing ownership.
    if (current.rune.locked) return error.LockedRuneChanged;
    var next = current;
    next.rune = .{ .byte = requested, .charges = maximum, .locked = false };
    return next;
}

pub fn detach(current: Loadout) Error!Loadout {
    if (current.rune.locked) return error.LockedRuneChanged;
    var next = current;
    next.rune = .{};
    return next;
}

/// Weapon rune-piece commit: type 1..5, one selected count incremented, every
/// other count cleared (`0x800D74E0..0x800D7568`).  The count is not replaced
/// with 1; a directly committed 255 wraps.
pub fn commitFragment(current: Fragments, piece_type: u8, selected_count: u8) Error!Fragments {
    _ = current; // the commit clears every non-selected count; source `0x800D74E0`
    if (piece_type < 1 or piece_type > fragment_slots) return error.InvalidFragmentType;
    var next = Fragments{ .active_type = piece_type, .counts = @splat(0) };
    next.counts[piece_type - 1] = selected_count;
    return next;
}
