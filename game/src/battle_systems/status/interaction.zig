//! Interaction resolver: accuracy, forced hit, parry, dodge, counter,
//! critical, protection interception and physical damage.
//!
//! The resolver is pure.  It never mutates a combatant's HP or status; it
//! returns the branch, the computed/applied amount, the protector index (if any)
//! and the exact draw sequence.  A refused branch restores the caller's draw
//! cursor, so an unknown capability cannot quietly become an ordinary attack.
//!
//! Source chain
//!   party attack   0x800F491C -> 0x800F4AD0 feature 0x8000, 0x800F4AE4 accuracy,
//!                  0x800F4AF4 feature 0x0002 parry, 0x800F4B6C feature 0x0004
//!                  dodge, 0x800F4BD8 initializer 0x800F4834 -> 0x800F835C
//!   enemy attack   0x800F4E64 -> 0x800F4F04 accuracy, 0x800F4F14 counter helper
//!                  0x800F78E4, record bit 0x0008, 0x800F4D5C protection
//!   protection     0x800F79E0 selector, 0x800F8604 eligibility, table 0x8016C814
//!   damage         0x800F7E90; critical 0x800F5ABC applies 3x

const std = @import("std");
const rules = @import("rules.zig");
const status = @import("status.zig");
const battle_rules = @import("battle_rules");
const data = @import("constants.zig");
const phero_rune: u8 = 0x1A;

pub const Side = enum { party, enemy };

pub const Combatant = struct {
    native_id: u8,
    character_type: ?u8 = null,
    side: Side,
    /// Source battle-slot index.  Party slots are 1..party_count; the first
    /// enemy slot is party_count+1 (the counter helper excludes it).
    source_slot: u8,
    hp: u16,
    max_hp: u16,
    attack: u16,
    defense: u16,
    skill: u16,
    luck: u16 = 0,
    rune: u8 = 0,
    defending: bool = false,
    active: bool = true,
    locked: bool = false,
    pending_damage: u16 = 0,
    /// Target weapon range bit0, required before a counter is possible.
    counter_guard: ?bool = null,
    /// The attacker weapon range permits parry; long-range weapons do not.
    can_be_parried: ?bool = null,
    features: u16 = 0,
    /// Party record +0x26; only bit 0x0008 is consumed.
    target_record_flags: u16 = 0,
    /// Pointed hat (item 3) is worn: balloon classes 1..3 are blocked after
    /// the status draw, exactly as the source setter does.
    pointed_hat: bool = false,
    status: status.State = .{},

    pub fn protectionBlocked(self: Combatant) bool {
        return self.status.protectionActive();
    }

    pub fn eligibleForProtection(self: Combatant) bool {
        return self.active and !self.locked and self.hp > self.pending_damage;
    }

    pub fn canAct(self: Combatant) bool {
        return self.active and self.hp > 0 and !self.locked and
            !self.status.has(.sleep) and !self.status.has(.recovery);
    }
};

pub const Branch = enum { hit, critical, parry, dodge, counter, protected, protection_failed };

pub const ReactionKind = enum { parry, dodge, counter };

pub const Reaction = struct {
    kind: ReactionKind,
    callback: u32,
    responder_id: u8,
    attacker_id: u8,
};

pub const Outcome = struct {
    branch: Branch,
    critical: bool = false,
    computed_damage: u32 = 0,
    applied_damage: u32 = 0,
    damage_blocked: bool = false,
    protector: ?usize = null,
    reaction: ?Reaction = null,
    draw_count: usize = 0,
    draws: [8]rules.DrawRecord = undefined,

    pub fn drawSlice(self: *const Outcome) []const rules.DrawRecord {
        return self.draws[0..self.draw_count];
    }
};

pub const HpChange = struct { applied: u32, blocked: bool, knocked_out: bool };

pub fn applyDamage(combatant: *Combatant, amount: u32) HpChange {
    if (combatant.status.protectionActive()) return .{ .applied = 0, .blocked = true, .knocked_out = false };
    const applied: u32 = @min(amount, combatant.hp);
    combatant.hp = @intCast(combatant.hp - applied);
    return .{ .applied = applied, .blocked = false, .knocked_out = combatant.hp == 0 };
}

pub fn applyHeal(combatant: *Combatant, amount: u32) HpChange {
    if (combatant.status.protectionActive()) return .{ .applied = 0, .blocked = true, .knocked_out = false };
    const room = combatant.max_hp - combatant.hp;
    const applied: u32 = @min(amount, room);
    combatant.hp += @intCast(applied);
    return .{ .applied = applied, .blocked = false, .knocked_out = false };
}

/// Commit the deferred knockout at the release tick.  Source keeps the hurt
/// lock while HP is zero and clears the classes/flags only when it releases.
pub fn commitKnockout(combatant: *Combatant) bool {
    if (combatant.hp != 0 or !combatant.active) return false;
    combatant.status.clearAll();
    combatant.active = false;
    return true;
}

fn copyLog(outcome: *Outcome, log: *const rules.DrawLog) void {
    outcome.draw_count = @min(log.count, outcome.draws.len);
    for (0..outcome.draw_count) |index| outcome.draws[index] = log.entries[index];
}

fn reaction(kind: ReactionKind, responder: Combatant, attacker: Combatant, callback: u32, log: *const rules.DrawLog) Outcome {
    var outcome = Outcome{
        .branch = switch (kind) {
            .parry => .parry,
            .dodge => .dodge,
            .counter => .counter,
        },
        .reaction = .{ .kind = kind, .callback = callback, .responder_id = responder.native_id, .attacker_id = attacker.native_id },
    };
    copyLog(&outcome, log);
    return outcome;
}

/// Source 0x800F7A4C..0x800F7A74: strict `current_hp < trunc(max_hp/4)`.
/// Multiplication is not equivalent (max_hp 101, hp 25 is not below 25).
pub fn belowQuarter(defender: Combatant) bool {
    if (defender.max_hp == 0) return false;
    const quarter = defender.max_hp / data.protection_hp_divisor;
    return defender.hp < quarter;
}

/// Main 0x800F79E0 plus 0x800F8604.  Returns the index of the selected
/// protector in `party`; relationship pairs precede Phero's wrapped type scan.
pub fn selectProtector(defender: Combatant, party: []const Combatant) !?usize {
    if (defender.side != .party or !belowQuarter(defender)) return null;
    for (data.protection_pairs) |pair| {
        if (pair.ward != defender.native_id) continue;
        for (party, 0..) |candidate, index| {
            if (candidate.side != .party or candidate.native_id != pair.protector) continue;
            if (candidate.native_id == defender.native_id) continue;
            if (!candidate.eligibleForProtection()) continue;
            return index;
        }
    }
    if (defender.rune != phero_rune) return null;
    const ward_type = defender.character_type orelse return error.MissingProtectionCharacterType;
    const ward = for (party, 0..) |candidate, index| {
        if (candidate.side == .party and candidate.source_slot == defender.source_slot) break index;
    } else return error.InvalidProtectionTarget;
    for (1..party.len) |step| {
        const index = (ward + step) % party.len;
        const candidate = party[index];
        if (candidate.side != .party or !candidate.active or candidate.locked) continue;
        const candidate_type = candidate.character_type orelse return error.MissingProtectionCharacterType;
        // Phero checks inactivity/lock and type, without the relationship path's pending-HP test.
        if (candidate_type != ward_type) return index;
    }
    return null;
}

fn preflightParty(attacker: Combatant, defender: Combatant) !void {
    if (defender.features & ~data.known_feature_mask != 0) return error.UnsupportedFeatureMask;
    if (defender.features & data.feature_parry != 0 and attacker.can_be_parried == null) return error.MissingParryCapability;
}

fn preflightEnemy(defender: Combatant) !void {
    if (defender.counter_guard == null) return error.MissingCounterGuard;
}

fn counterAvailable(attacker: Combatant, defender: Combatant, party_count: u8, draws: *battle_rules.Draws, log: *rules.DrawLog) !bool {
    const first_enemy_slot: u16 = @as(u16, party_count) + 1;
    if (@as(u16, attacker.source_slot) <= first_enemy_slot) return false;
    if (attacker.features & data.feature_counter_eligible == 0) return false;
    if (!(defender.counter_guard orelse return error.MissingCounterGuard)) return false;
    if (defender.defending or defender.rune == data.counter_rune) return true;
    const roll = try rules.pull(draws, log, .counter_availability);
    return roll & 1 == 1;
}

fn ordinaryOrProtection(
    attacker: Combatant,
    defender: Combatant,
    party: []const Combatant,
    draws: *battle_rules.Draws,
    log: *rules.DrawLog,
) !Outcome {
    const protector = try selectProtector(defender, party);
    const receiver = if (protector) |index| party[index] else defender;
    const variance = try rules.pull(draws, log, .physical_variance);
    const computed = rules.physicalDamage(attacker.attack, receiver.defense, variance, receiver.defending);
    var outcome = Outcome{
        .branch = if (protector != null) .protected else .hit,
        .computed_damage = computed,
        .applied_damage = if (receiver.protectionBlocked()) 0 else computed,
        .damage_blocked = receiver.protectionBlocked(),
        .protector = protector,
    };
    copyLog(&outcome, log);
    return outcome;
}

/// Resolve one ordinary physical attack.
pub fn resolvePhysical(
    attacker: Combatant,
    defender: Combatant,
    party: []const Combatant,
    party_count: u8,
    draws: *battle_rules.Draws,
    log: *rules.DrawLog,
) !Outcome {
    if (attacker.side == defender.side) return error.InvalidSides;
    if (!attacker.canAct()) return error.ActorCannotAct;
    if (attacker.side == .party) try preflightParty(attacker, defender) else try preflightEnemy(defender);

    const cursor = rules.mark(draws);
    const start = log.count;
    errdefer {
        rules.restore(draws, cursor);
        log.count = start;
    }

    if (attacker.side == .party) {
        const feats = defender.features;
        var connected = false;
        if (feats & data.feature_forced_hit == 0) {
            const roll = try rules.pull(draws, log, .accuracy);
            connected = rules.hit(attacker.skill, defender.skill, roll, attacker.status.has(.accuracy_reduced));
        }
        if (!connected) {
            if (feats & data.feature_parry != 0 and attacker.can_be_parried.?) {
                return reaction(.parry, defender, attacker, 0x800F5DB4, log);
            }
            if (feats & data.feature_dodge != 0) {
                return reaction(.dodge, defender, attacker, 0x800F5C1C, log);
            }
        }
        const critical_roll = try rules.pull(draws, log, .critical);
        const is_critical = rules.criticalHit(attacker.skill, attacker.luck, attacker.rune == data.killer_rune, critical_roll);
        const variance = try rules.pull(draws, log, .physical_variance);
        var computed = rules.physicalDamage(attacker.attack, defender.defense, variance, defender.defending);
        if (is_critical) computed *= data.critical_damage_multiplier;
        var outcome = Outcome{
            .branch = if (is_critical) .critical else .hit,
            .critical = is_critical,
            .computed_damage = computed,
            .applied_damage = if (defender.protectionBlocked()) 0 else computed,
            .damage_blocked = defender.protectionBlocked(),
        };
        copyLog(&outcome, log);
        return outcome;
    }

    const accuracy = try rules.pull(draws, log, .accuracy);
    const hit = rules.hit(attacker.skill, defender.skill, accuracy, defender.rune == data.hazy_rune);
    if (hit) return ordinaryOrProtection(attacker, defender, party, draws, log);
    if (try counterAvailable(attacker, defender, party_count, draws, log)) {
        return reaction(.counter, defender, attacker, 0x800F5DB4, log);
    }
    if (defender.target_record_flags & data.feature_ordinary_landing != 0) {
        return ordinaryOrProtection(attacker, defender, party, draws, log);
    }
    return reaction(.dodge, defender, attacker, 0x800F5C1C, log);
}

test "party forced hit skips accuracy and still reaches the critical roll" {
    const attacker = Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 50, .defense = 20, .skill = 200, .luck = 0 };
    var defender = Combatant{ .native_id = 3, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 0 };
    defender.features = data.feature_forced_hit;
    var draws = battle_rules.Draws{ .values = &.{ 0, 10, 0 } };
    var log = rules.DrawLog{};
    const outcome = try resolvePhysical(attacker, defender, &.{}, 6, &draws, &log);
    try std.testing.expectEqual(Branch.critical, outcome.branch);
    try std.testing.expectEqual(@as(usize, 2), outcome.draw_count);
    try std.testing.expectEqual(@as(usize, 0), log.countOf(.accuracy));
}

test "party parry and dodge consume only the accuracy draw" {
    const attacker = Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 50, .defense = 20, .skill = 0, .luck = 0, .can_be_parried = true };
    var parry = Combatant{ .native_id = 3, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 200 };
    parry.features = data.feature_parry;
    var draws = battle_rules.Draws{ .values = &.{99} };
    var log = rules.DrawLog{};
    const parried = try resolvePhysical(attacker, parry, &.{}, 6, &draws, &log);
    try std.testing.expectEqual(Branch.parry, parried.branch);
    try std.testing.expectEqual(@as(usize, 1), parried.draw_count);
    try std.testing.expectEqual(@as(u32, 0x800F5DB4), parried.reaction.?.callback);

    var dodge = parry;
    dodge.features = data.feature_dodge;
    var draws2 = battle_rules.Draws{ .values = &.{99} };
    var log2 = rules.DrawLog{};
    const dodged = try resolvePhysical(attacker, dodge, &.{}, 6, &draws2, &log2);
    try std.testing.expectEqual(Branch.dodge, dodged.branch);
    try std.testing.expectEqual(@as(u32, 0x800F5C1C), dodged.reaction.?.callback);
}

test "parry eligibility belongs to the attacker weapon, independently of defender weapon" {
    var attacker = Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 50, .defense = 20, .skill = 0, .luck = 0, .can_be_parried = false };
    const defender = Combatant{ .native_id = 3, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 200, .features = data.feature_parry, .can_be_parried = true };
    var draws = battle_rules.Draws{ .values = &.{ 99, 99, 0 } };
    var log = rules.DrawLog{};
    const long_range = try resolvePhysical(attacker, defender, &.{}, 6, &draws, &log);
    try std.testing.expectEqual(Branch.hit, long_range.branch);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    attacker.can_be_parried = true;
    draws.cursor = 0;
    log = .{};
    const melee = try resolvePhysical(attacker, defender, &.{}, 6, &draws, &log);
    try std.testing.expectEqual(Branch.parry, melee.branch);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
    attacker.can_be_parried = null;
    draws.cursor = 0;
    log = .{};
    try std.testing.expectError(error.MissingParryCapability, resolvePhysical(attacker, defender, &.{}, 6, &draws, &log));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "unknown feature and missing inputs refuse without consuming draws" {
    const attacker = Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 50, .defense = 20, .skill = 100, .luck = 0 };
    var defender = Combatant{ .native_id = 3, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 100 };
    defender.features = 0x0010;
    var draws = battle_rules.Draws{ .values = &.{ 0, 0, 0 } };
    var log = rules.DrawLog{};
    try std.testing.expectError(error.UnsupportedFeatureMask, resolvePhysical(attacker, defender, &.{}, 6, &draws, &log));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try std.testing.expectEqual(@as(usize, 0), log.count);

    var parry = defender;
    parry.features = data.feature_parry;
    try std.testing.expectError(error.MissingParryCapability, resolvePhysical(attacker, parry, &.{}, 6, &draws, &log));

    const enemy = Combatant{ .native_id = 3, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 50, .defense = 20, .skill = 100 };
    const target = Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 100 };
    try std.testing.expectError(error.MissingCounterGuard, resolvePhysical(enemy, target, &.{}, 6, &draws, &log));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "protection selector uses quarter HP, pair order and eligibility" {
    var ward = Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 24, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    var gremio = Combatant{ .native_id = 2, .side = .party, .source_slot = 2, .hp = 100, .max_hp = 100, .attack = 10, .defense = 40, .skill = 10 };
    const pahn = Combatant{ .native_id = 6, .side = .party, .source_slot = 3, .hp = 100, .max_hp = 100, .attack = 10, .defense = 40, .skill = 10 };
    var party = [_]Combatant{ ward, gremio, pahn };
    try std.testing.expectEqual(@as(?usize, 1), try selectProtector(ward, &party));

    ward.hp = 25;
    party[0] = ward;
    try std.testing.expectEqual(@as(?usize, null), try selectProtector(party[0], &party));

    var edge = ward;
    edge.max_hp = 101;
    edge.hp = 25;
    try std.testing.expect(!belowQuarter(edge));
    edge.hp = 24;
    try std.testing.expect(belowQuarter(edge));

    ward.hp = 10;
    party[0] = ward;
    gremio.locked = true;
    party[1] = gremio;
    try std.testing.expectEqual(@as(?usize, 2), try selectProtector(party[0], &party));

    gremio.locked = false;
    gremio.hp = 0;
    party[1] = gremio;
    try std.testing.expectEqual(@as(?usize, 2), try selectProtector(party[0], &party));
}
