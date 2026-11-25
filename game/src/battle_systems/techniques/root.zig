//! Physical rune techniques, passives and loadout carry.
//!
//! Data-driven and hook-shaped adapters consumed by `battle.zig` and `world_battle.zig`.

pub const physical = @import("physical.zig");
pub const passive = @import("passive.zig");
pub const carry = @import("carry.zig");

test {
    _ = physical;
    _ = passive;
    _ = carry;
}
