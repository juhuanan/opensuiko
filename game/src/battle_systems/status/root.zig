//! Combat status, hit and protection interactions.
//!
//! Integration surface:
//!   * `rules` is the draw log/cursor layer over the shared `battle_rules`.
//!   * `status` owns the nine independent source masks, their proven durations,
//!     the general cure, battle exit and copper-flesh expiry.
//!   * `interaction.resolvePhysical` resolves one ordinary physical attack and
//!     returns the branch, amount, protector and exact draw sequence.  It never
//!     mutates HP/status and refuses unknown capabilities before drawing.
//!   * `coordinator.Coordinator` owns begin/impact/status/release/settle locks,
//!     one-time ward return and knockout commitment, plus a restartable snapshot.
//!
//! `data` is the generated, hash-pinned evidence asset.

const std = @import("std");

pub const schema = "suikoden-battle-status/1";
pub const version = "1.0.0";

pub const data = @import("constants.zig");
pub const rules = @import("rules.zig");
pub const status = @import("status.zig");
pub const interaction = @import("interaction.zig");
pub const coordinator = @import("coordinator.zig");

pub const Class = status.Class;
pub const Attempt = status.Attempt;
pub const StatusState = status.State;
pub const Side = interaction.Side;
pub const Combatant = interaction.Combatant;
pub const Branch = interaction.Branch;
pub const Outcome = interaction.Outcome;
pub const Reaction = interaction.Reaction;
pub const HpChange = interaction.HpChange;
pub const Frame = coordinator.Frame;
pub const Event = coordinator.Event;
pub const Snapshot = coordinator.Snapshot;

pub fn maskOf(class: Class) u16 {
    return status.maskOf(class);
}

pub fn selectProtector(defender: Combatant, party: []const Combatant) !?usize {
    return interaction.selectProtector(defender, party);
}

pub fn resolvePhysical(
    attacker: Combatant,
    defender: Combatant,
    party: []const Combatant,
    party_count: u8,
    draws: *@import("battle_rules").Draws,
    log: *rules.DrawLog,
) !Outcome {
    return interaction.resolvePhysical(attacker, defender, party, party_count, draws, log);
}

test {
    std.testing.refAllDecls(@This());
    _ = rules;
    _ = status;
    _ = interaction;
    _ = coordinator;
}
