//! D-side spell planner: the reviewed D effect contract's version-1
//! envelope with the additive step families this pack proved.
//!
//! Contract shape (shared with D's `contract.zig`, pinned by hash in the report):
//!   * `prepare` validates admission against a rune's four spell slots and the
//!     actor's four tier counters. It consumes no RNG and mutates no host state.
//!   * `commit` records the caller's reservation; the caller owns its own locks.
//!   * `resolve` runs at the named impact boundary against borrowed target facts
//!     and a COPY of the caller's Draws. It returns ordered changes, the charge
//!     after-state, the magic continuation and the Draws after-state, or a named
//!     error. It never steps a coordinator and never mutates the caller.
//!
//! Purely a planner: the C bridge (`bridge.zig`) revalidates the plan and applies
//! it atomically. Nothing here draws outside `draws_after` and nothing here
//! retargets in a presentation module.

const std = @import("std");
const rules = @import("rules.zig");
const br = @import("battle_rules");

pub const version: u8 = 1;
pub const family_version = rules.family_version;
pub const max_targets = rules.max_targets;

pub const Side = enum { ally, enemy };
pub const Stage = enum { selected, committed, impacted };
pub const Boundary = enum { impact };

/// Borrowed target facts at the impact boundary. `affinity` is the source's six
/// coefficient columns (+0x20..+0x25); `death_immune` is the source target flag
/// bit 0x4000 that blocks an instant KO.
pub const Target = struct {
    id: u32,
    side: Side,
    hp: u16,
    max_hp: u16,
    affinity: [6]br.Affinity = @splat(.neutral),
    ko: bool = false,
    death_immune: bool = false,
    airborne: bool = false,
    protection: u8 = 0,
    status: u16 = 0,
    sleep: u8 = 0,
    skill_bonus: i16 = 0,
    defense_bonus: i16 = 0,
};

pub const Actor = struct { id: u32, rune_index: usize, charges: [4]u16, magic: u16 };

pub const Request = struct { spell_index: usize, target_id: u32 };

pub const Continuation = struct {
    version: u8 = version,
    content_id: []const u8,
    actor_id: u32,
    request: Request,
    tier: u2,
    expected_charge: u16,
    expected_rune: usize,
    stage: Stage = .selected,
};

pub const Change = struct { before: Target, after: Target };

pub const EffectPlan = struct {
    version: u8 = version,
    family_version: u8 = family_version,
    content_id: []const u8,
    actor_id: u32,
    request: Request,
    boundary: Boundary = .impact,
    expected_charge: u16,
    tier: u2,
    charge_after: u16,
    changes: [max_targets]Change = undefined,
    count: usize = 0,
    after: Continuation,
    draws_after: br.Draws,
};

fn tierFor(rune_spells: [4]?usize, spell_index: usize) !u2 {
    var found: ?u2 = null;
    for (rune_spells, 0..) |slot, index| {
        if (slot) |owned| if (owned == spell_index) {
            if (found != null) return error.AmbiguousTier;
            found = @intCast(index);
        };
    }
    return found orelse error.SpellNotOwned;
}

fn mapSide(value: rules.Side) Side {
    return switch (value) {
        .ally => .ally,
        .enemy => .enemy,
    };
}

fn stepMatches(target: Target, spell_side: Side, selected: u32, set: rules.TargetSet) bool {
    return switch (set) {
        .selected => target.id == selected and target.side == spell_side,
        .all_allies, .allies => target.side == .ally,
        .all_enemies, .enemies => target.side == .enemy,
    };
}

fn eligible(op: rules.Op, current: Target) bool {
    return switch (op) {
        // Damage, sleep, protection and the bonus scales only reach a living target.
        .damage, .sleep, .protection, .scale_bonus, .instant_ko => current.hp > 0 and !current.ko,
        // Healing and curing skip a knocked-out ally; after a revive step the same
        // target is no longer KO and this step applies (the source Yell order).
        .heal, .clear_status => !current.ko,
        // The source revive loop clears the KO byte for every slot in its set.
        .revive => true,
    };
}

/// The source damage consumer: base = power + caster.magic / 2, then the target's
/// affinity coefficient for the spell's channel. Channel 7 returns the base
/// before the coefficient read. Channels 0..5 index the six columns.
pub fn damageAmount(step: rules.Step, caster_magic: u16, target: Target) u32 {
    const base = @as(u32, step.power) + caster_magic / 2;
    const channel = step.channel orelse return base;
    if (!step.resisted or channel >= target.affinity.len) return base;
    return switch (target.affinity[channel]) {
        .neutral => base,
        .weak => base * 2,
        .resistant => base / 2,
        .immune => 0,
    };
}

fn healAmount(amount: rules.Amount, kind: rules.AmountKind, target: Target) !u32 {
    return switch (kind) {
        .to_max => target.max_hp,
        .flat => @as(u32, target.hp) + amount.value.?,
        .max_fraction => @as(u32, target.hp) + @as(u32, target.max_hp) * amount.numerator.? / amount.denominator.?,
        .fraction => @as(u32, target.max_hp) * amount.numerator.? / 100,
    };
}

/// One step on one target, in place. Returns error before any value is published
/// by the caller; `resolve` only keeps the result once every step succeeded.
fn applyStep(step: rules.Step, op: rules.Op, actor: Actor, current: Target, draws: *br.Draws) !Target {
    var after = current;
    switch (op) {
        .damage => {
            if (step.airborne_immune and current.airborne) return after;
            if (after.protection == 0) {
                const amount = damageAmount(step, actor.magic, current);
                after.hp = @intCast(@as(u32, after.hp) -| amount);
            }
            // The reviewed D contract wakes a damaged target.
            after.sleep = 0;
        },
        .heal => {
            if (after.protection == 0) {
                const amount = try healAmount(step.amount.?, try step.amountOf(), current);
                after.hp = @intCast(@min(@as(u32, after.max_hp), amount));
            }
        },
        .revive => after.ko = false,
        .clear_status => {
            after.status = 0;
            after.sleep = 0;
        },
        .sleep => {
            // The source record ward0x4000 gates both death and the sleep script.
            if (current.death_immune) return after;
            if (step.failure_percent) |failure| {
                if (br.statusPercent(try draws.next()) >= failure) after.sleep = 1;
            } else {
                after.sleep = @intCast(@min(@as(u32, step.power) + 1, 255));
            }
        },
        .scale_bonus => {
            const percent: i32 = step.percent orelse return error.UnsupportedStep;
            if (std.mem.eql(u8, step.field.?, "defense")) {
                after.defense_bonus = std.math.cast(i16, @divTrunc(@as(i32, current.defense_bonus) * percent, 100)) orelse return error.StatOverflow;
            } else {
                after.skill_bonus = std.math.cast(i16, @divTrunc(@as(i32, current.skill_bonus) * percent, 100)) orelse return error.StatOverflow;
            }
        },
        .protection => after.protection = @intCast(step.power),
        .instant_ko => {
            if (!current.death_immune) after.ko = true;
        },
    }
    return after;
}

/// Admission only: no RNG, no host state.
pub fn prepare(ruleset: *const rules.Rules, content_id: []const u8, rune_spells: [4]?usize, actor: Actor, request: Request, targets: []const Target) !Continuation {
    if (content_id.len == 0 or request.spell_index >= ruleset.spells.len or targets.len > max_targets) return error.InvalidSelection;
    const spell = ruleset.spells[request.spell_index];
    if (!std.mem.eql(u8, spell.status, "supported") and !std.mem.eql(u8, spell.status, "partial")) return error.UnsupportedSpell;
    if (spell.steps.len == 0) return error.UnsupportedSpell;
    const tier = try tierFor(rune_spells, request.spell_index);
    if (actor.charges[tier] == 0) return error.NoCharge;
    var found = false;
    const spell_side = mapSide(try spell.side());
    for (targets, 0..) |target, index| {
        for (targets[0..index]) |previous| if (previous.id == target.id) return error.DuplicateTarget;
        if (target.max_hp == 0 or target.hp > target.max_hp) return error.InvalidTarget;
        for (spell.steps) |step| {
            if (!stepMatches(target, spell_side, request.target_id, try step.targetOf())) continue;
            if (!eligible(try step.opOf(), target)) continue;
            found = true;
        }
    }
    if (!found) return error.TargetUnavailable;
    return .{ .content_id = content_id, .actor_id = actor.id, .request = request, .tier = tier, .expected_charge = actor.charges[tier], .expected_rune = actor.rune_index };
}

/// The caller persists this with its own reservation/locks. Purely a stage move.
pub fn commit(selection: Continuation) !Continuation {
    if (selection.version != version or selection.stage != .selected) return error.InvalidContinuation;
    var next = selection;
    next.stage = .committed;
    return next;
}

/// The source single-enemy retarget decision, on a coordinator copy: the selected
/// slot is kept while it is a living enemy, otherwise the first living enemy in
/// slot order is chosen. No RNG and no state are touched.
pub fn retarget(ruleset: *const rules.Rules, spell_index: usize, selected: u32, targets: []const Target) !?u32 {
    if (spell_index >= ruleset.spells.len) return error.InvalidSelection;
    for (targets) |target| if (target.id == selected and target.side == .enemy and target.hp > 0 and !target.ko) return selected;
    for (targets) |target| if (target.side == .enemy and target.hp > 0 and !target.ko) return target.id;
    return null;
}

pub fn resolve(ruleset: *const rules.Rules, continuation: Continuation, content_id: []const u8, rune_spells: [4]?usize, actor: Actor, targets: []const Target, draws: br.Draws) !EffectPlan {
    if (continuation.version != version or continuation.stage != .committed) return error.InvalidContinuation;
    if (!std.mem.eql(u8, continuation.content_id, content_id) or continuation.actor_id != actor.id) return error.InvalidContinuation;
    if (!draws.valid()) return error.InvalidRandomSource;
    const checks = try prepare(ruleset, content_id, rune_spells, actor, continuation.request, targets);
    if (checks.tier != continuation.tier or checks.expected_charge != continuation.expected_charge or checks.expected_charge != actor.charges[continuation.tier] or checks.expected_rune != continuation.expected_rune) return error.StaleReservation;
    if (continuation.expected_charge == 0) return error.NoCharge;

    const spell = ruleset.spells[continuation.request.spell_index];
    var plan = EffectPlan{
        .content_id = content_id,
        .actor_id = actor.id,
        .request = continuation.request,
        .expected_charge = continuation.expected_charge,
        .tier = continuation.tier,
        .charge_after = continuation.expected_charge - 1,
        .after = continuation,
        .draws_after = draws,
    };
    plan.after.stage = .impacted;

    for (targets) |before| {
        var current = before;
        var touched = false;
        for (spell.steps) |step| {
            const set = try step.targetOf();
            if (!stepMatches(before, mapSide(try spell.side()), continuation.request.target_id, set)) continue;
            const op = try step.opOf();
            if (!eligible(op, current)) continue;
            current = try applyStep(step, op, actor, current, &plan.draws_after);
            touched = true;
        }
        if (!touched) continue;
        if (plan.count == max_targets) return error.TooManyTargets;
        plan.changes[plan.count] = .{ .before = before, .after = current };
        plan.count += 1;
    }
    if (plan.count == 0) return error.NoEffect;
    return plan;
}
