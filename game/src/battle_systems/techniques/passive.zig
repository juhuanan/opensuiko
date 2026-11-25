//! Counter Rune eligibility.
//!
//! Source helper `0x800F78E4(actor, target)` is reached from the ordinary
//! attack resolver `0x800F4F14` after the accuracy check, and decides whether
//! the target counter-attacks.  Static shape:
//!
//! * actor range: the helper continues only when
//!   `actor_index > scene+0x1C + 1` (`0x800F78F8..0x800F7908`), i.e. the
//!   counter block is for actors past the party range and returns false for
//!   party actors; the `+1` is source code, not a port convenience;
//! * attacker capability: `scene+0x1344[actor_id]+0x26` bit 0
//!   (`0x800F7958`);
//! * target weapon flag: weapon record `+0x56` bit 0 (`0x800F796C`);
//!   the party loader stores that weapon pointer at scene+C[target]+4
//!   (`0x800DEDC4..0x800DEDFC`);
//! * target slot `+0x47 == 1` grants unconditionally (`0x800F798C..94`);
//! * target rune byte `+0x4C == 16` grants unconditionally (`0x800F79A4..A8`);
//! * otherwise the caller-owned RNG `0x80147E38` low bit decides
//!   (`0x800F79BC..C8`).
//!
//! Callers supply the enemy capability and weapon flag. Missing facts refuse
//! before the random arm; the weapon flag is the low bit of the exported range.

const std = @import("std");

pub const counter_rune: u8 = 16;
pub const helper = 0x800F78E4;
pub const rng_call = 0x80147E38;

pub const Input = struct {
    /// Actor index used by the helper's bounds check.
    actor_index: u32,
    /// `scene+0x1C + 1`, the lowest actor index the source continues for.
    counter_actor_floor: u32,
    /// `scene+0x1344[actor_id]+0x26` bit 0.  `null` means the shared content
    /// export does not provide it.
    attacker_capability: ?bool,
    /// Legacy field name: this is the target weapon record's range bit0.
    target_persistent_flag: ?bool,
    /// Target party slot `+0x47 == 1`.
    target_slot_47: bool,
    /// Target character record `+0x4C`.
    target_rune: u8,
    /// Low bit of the caller's own `0x80147E38` draw.  Ignored unless the
    /// random arm is reached.
    roll_low_bit: u1,
};

pub const Grant = enum {
    slot_47,
    counter_rune,
    random_low_bit,
};

pub const Refusal = enum {
    actor_in_party_range,
    attacker_capability_unavailable,
    target_persistent_flag_unavailable,
    attacker_not_counterable,
    target_not_marked,
    random_low_bit,
};

pub const Decision = union(enum) {
    granted: Grant,
    refused: Refusal,
};

pub fn decide(input: Input) Decision {
    if (input.actor_index <= input.counter_actor_floor) return .{ .refused = .actor_in_party_range };
    const capability = input.attacker_capability orelse
        return .{ .refused = .attacker_capability_unavailable };
    if (!capability) return .{ .refused = .attacker_not_counterable };
    const marked = input.target_persistent_flag orelse
        return .{ .refused = .target_persistent_flag_unavailable };
    if (!marked) return .{ .refused = .target_not_marked };
    if (input.target_slot_47) return .{ .granted = .slot_47 };
    if (input.target_rune == counter_rune) return .{ .granted = .counter_rune };
    if (input.roll_low_bit == 1) return .{ .granted = .random_low_bit };
    return .{ .refused = .random_low_bit };
}

/// Shared battle already owns Phero protection (`0x800F79E0` protector with
/// the `0x800F7B58` rune-26 compare).  This pack never duplicates it; the
/// predicate exists so a transition guard can assert the rune is unchanged.
pub const phero_rune: u8 = 26;
