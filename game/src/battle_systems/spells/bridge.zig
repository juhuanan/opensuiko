//! C bridge: validate and apply a D spell effect plan atomically.
//!
//! C owns coordinator order, impact timing and owner/target locks. This module is
//! the apply half: it takes the host view of the battle state, revalidates the
//! plan against that exact view, and commits every target change, the tier
//! charge and the calls-after Draws together — or nothing at all.
//!
//! Atomicity is structural: `apply` mutates only a local copy of the host and
//! assigns it back at a single point after the whole plan succeeded. Any named
//! error returns with the original host byte-identical, including the Draws
//! cursor/state, so an insufficient charge, a retarget decision or a late
//! failure can never leave a half-applied update behind.

const std = @import("std");
const plan = @import("plan.zig");
const br = @import("battle_rules");

pub const max_targets = plan.max_targets;

pub const Host = struct {
    content_id: []const u8,
    actor: plan.Actor,
    /// The four resolved spell indices of the actor's rune, slot index = tier.
    rune_spells: [4]?usize,
    targets: [max_targets]plan.Target = undefined,
    count: usize = 0,
    draws: br.Draws = .{},

    pub fn find(self: *Host, id: u32) ?*plan.Target {
        for (self.targets[0..self.count]) |*target| if (target.id == id) return target;
        return null;
    }

    pub fn chargeOf(self: *const Host, tier: u2) u16 {
        return self.actor.charges[tier];
    }
};

pub fn sameTarget(a: plan.Target, b: plan.Target) bool {
    if (a.id != b.id or a.side != b.side or a.hp != b.hp or a.max_hp != b.max_hp) return false;
    if (a.ko != b.ko or a.airborne != b.airborne or a.death_immune != b.death_immune or a.protection != b.protection) return false;
    if (a.status != b.status or a.sleep != b.sleep) return false;
    if (a.skill_bonus != b.skill_bonus or a.defense_bonus != b.defense_bonus) return false;
    return std.mem.eql(br.Affinity, &a.affinity, &b.affinity);
}

fn stage(host: *Host, effect: plan.EffectPlan) !void {
    if (effect.version != plan.version or effect.family_version != plan.family_version) return error.ContractMismatch;
    if (effect.boundary != .impact) return error.WrongBoundary;
    if (!std.mem.eql(u8, effect.content_id, host.content_id)) return error.ContentMismatch;
    if (effect.actor_id != host.actor.id) return error.ActorMismatch;
    if (effect.count == 0 or effect.count > host.count or effect.count > max_targets) return error.InvalidPlan;
    if (effect.tier >= 4) return error.InvalidPlan;
    if (host.rune_spells[effect.tier] == null or host.rune_spells[effect.tier].? != effect.request.spell_index) return error.TierSpellMismatch;
    if (host.actor.charges[effect.tier] != effect.expected_charge) return error.StaleCharge;
    if (effect.expected_charge == 0 or effect.charge_after != effect.expected_charge - 1) return error.InvalidPlan;
    if (effect.after.stage != .impacted) return error.InvalidContinuation;

    for (effect.changes[0..effect.count], 0..) |change, index| {
        const target = host.find(change.before.id) orelse return error.UnknownTarget;
        if (!sameTarget(target.*, change.before)) return error.StaleBeforeState;
        for (effect.changes[0..index]) |previous| {
            if (previous.before.id == change.before.id) return error.DuplicateChange;
        }
        // A plan cannot change a target's identity or its capacity.
        if (change.after.id != change.before.id or change.after.side != change.before.side or
            change.after.max_hp != change.before.max_hp) return error.InvalidPlan;
        if (change.after.hp > change.after.max_hp) return error.InvalidPlan;
    }

    // Past this point nothing can fail, so the staged copy is a complete update.
    for (effect.changes[0..effect.count]) |change| {
        host.find(change.before.id).?.* = change.after;
    }
    host.actor.charges[effect.tier] = effect.charge_after;
    host.draws = effect.draws_after;
}

/// Validate and commit the whole plan, or leave the host exactly as it was.
pub fn apply(host: *Host, effect: plan.EffectPlan) !void {
    var staged = host.*;
    try stage(&staged, effect);
    host.* = staged;
}
