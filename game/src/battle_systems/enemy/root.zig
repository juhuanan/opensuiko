//! Enemy decision/effect resolution layered on the `campaign_policies.enemy_policy`
//! path.
//!
//! `campaign_policies.enemy_policy` remains the authority for its reviewed
//! families: this module delegates to `campaign_policies.enemy_policy.decide`
//! whenever the record is handled by the base policy, then attaches the resolved
//! effect plan.  Records that need a pre-scan special draw are planned here
//! directly.
//!
//! Invariants preserved from the source callbacks:
//!   * a blocked record is refused before any draw, with its typed blocker;
//!   * the pre-scan special consumes its scaled pre-draw first, then either a
//!     random-slot draw or the ordered front-row scan;
//!   * locked/inactive candidates consume no draw;
//!   * a random slot that is not selectable falls back to the scan in the same
//!     decision instead of abandoning the turn;
//!   * an unresolved effect is refused as a whole and the caller's random
//!     cursor is restored, so a retry starts from the same state;
//!   * an unknown record id or effect family is an error, never another
//!     record's policy.

const std = @import("std");
const systems = @import("battle_rules");
const enemy_policy = @import("campaign_policies").enemy_policy;
pub const catalogue = @import("catalogue.zig");
const data = @import("battle_systems_data").enemy_effects;

pub const json = data.enemy_effects_json;
pub const vectors_json = data.vectors_json;

pub const Packet = catalogue.Packet;
pub const Record = catalogue.Record;
pub const Effect = catalogue.Effect;
pub const Blocker = catalogue.Blocker;
pub const PartyRow = enemy_policy.PartyRow;
pub const scanTargets = enemy_policy.scanTargets;

pub const Attack = struct {
    target_slot: u8,
    draws_used: usize,
};

pub const Special = struct {
    target_slot: ?u8,
    draws_used: usize,
    effect: *const Effect,
};

pub const Pending = struct {
    draws_used: usize,
};

pub const Outcome = union(enum) {
    attack: Attack,
    special: Special,
    pending: Pending,
    disabled: Pending,
    blocked: Blocker,
};

pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Packet) {
    return catalogue.load(allocator, json);
}

pub fn loadBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    return catalogue.load(allocator, bytes);
}

pub fn drawValue(kind: []const u8, roll: u15) !u32 {
    if (std.mem.eql(u8, kind, "percent_100")) return enemy_policy.drawValue(.percent_100, roll);
    if (std.mem.eql(u8, kind, "scale_100_32767")) return enemy_policy.drawValue(.scale_100_32767, roll);
    if (std.mem.eql(u8, kind, "scale_100_32767_mod_100")) return enemy_policy.drawValue(.scale_100_32767_mod_100, roll);
    return error.UnknownDrawKind;
}

/// Decide one enemy action.  `party` is the reviewed six-slot target domain and
/// `source_slot_count` is scene+0x1C's actor count used by the pre-scan random
/// slot.  Both are supplied by the coordinator host; this module keeps no
/// battle state.
pub fn decide(
    effects_catalogue: *const Packet,
    base: *const enemy_policy.Packet,
    record_id: []const u8,
    party: []const enemy_policy.PartyRow,
    own: enemy_policy.OwnSlot,
    source_slot_count: u8,
    draws: *systems.Draws,
) !Outcome {
    const record = effects_catalogue.find(record_id) orelse return error.UnknownEnemyRecord;
    if (std.mem.eql(u8, record.status, "blocked")) {
        const blocker = record.decision.blocker orelse record.effect.blocker orelse return error.BlockedRecordWithoutBlocker;
        return .{ .blocked = blocker };
    }
    const saved = draws.*;
    return decideInner(record, base, party, own, source_slot_count, draws) catch |err| {
        draws.* = saved;
        return err;
    };
}

fn decideInner(
    record: *const Record,
    base: *const enemy_policy.Packet,
    party: []const enemy_policy.PartyRow,
    own: enemy_policy.OwnSlot,
    source_slot_count: u8,
    draws: *systems.Draws,
) !Outcome {
    if (std.mem.eql(u8, record.decision.family, "pre_scan_special"))
        return planPreScanSpecial(record, party, source_slot_count, draws);

    const base_record = base.record(record.id) orelse return error.UnknownBaseRecord;
    const decision = try enemy_policy.decide(base_record, party, own, draws);
    switch (decision) {
        .attack => |attack| return .{ .attack = .{
            .target_slot = attack.target_slot,
            .draws_used = attack.draws_used,
        } },
        .pending => |pending| return .{ .pending = .{ .draws_used = pending.draws_used } },
        .disabled => return .{ .disabled = .{ .draws_used = draws.cursor } },
        .blocked => |blocker| return .{ .blocked = .{
            .code = blockerCodeName(blocker.code),
            .detail = blocker.detail,
        } },
        .special => |action| {
            const effect = &record.effect;
            if (std.mem.eql(u8, effect.family, "blocked") or effect.blocker != null) {
                const blocker = effect.blocker orelse return error.BlockedEffectWithoutBlocker;
                return .{ .blocked = blocker };
            }
            return .{ .special = .{
                .target_slot = action.target_slot,
                .draws_used = action.draws_used,
                .effect = effect,
            } };
        },
    }
}

fn planPreScanSpecial(
    record: *const Record,
    party: []const enemy_policy.PartyRow,
    source_slot_count: u8,
    draws: *systems.Draws,
) !Outcome {
    const start = draws.cursor;
    const decision = record.decision;
    const gate = decision.pre_gate orelse return error.MissingPreGate;
    const scan = decision.scan orelse return error.MissingPolicyScan;
    if (source_slot_count == 0) return error.InvalidSourceSlotCount;
    if (record.decision.special == null) return error.MissingSpecial;

    const pre = try draws.next();
    if (try drawValue(gate.draw_kind, pre) >= gate.special_at_least) {
        const roll = try draws.next();
        // Source actor IDs add one; PartyRow slots already use zero-based IDs.
        const slot: u8 = @intCast(enemy_policy.drawValue(.scale_100_32767, roll) % source_slot_count);
        if (selectable(party, slot)) {
            return .{ .special = .{
                .target_slot = slot,
                .draws_used = draws.cursor - start,
                .effect = &record.effect,
            } };
        }
        // Predicate rejected the random slot: fall back to the ordered scan.
    }

    var eligible = false;
    const kind = std.meta.stringToEnum(enemy_policy.policy_data.DrawKind, scan.draw_kind) orelse return error.UnknownDrawKind;
    if (try enemy_policy.scanTargets(.{ .front_only = scan.front_only, .draw_kind = kind, .accept_at_least = scan.accept_at_least }, party, draws, &eligible)) |chosen| {
        return .{ .attack = .{
            .target_slot = chosen.slot,
            .draws_used = draws.cursor - start,
        } };
    }
    if (eligible) return .{ .pending = .{ .draws_used = draws.cursor - start } };
    return .{ .disabled = .{ .draws_used = draws.cursor - start } };
}

fn selectable(party: []const enemy_policy.PartyRow, slot: u8) bool {
    for (party) |member| {
        if (member.slot == slot) return member.active and !member.locked;
    }
    return false;
}

fn blockerCodeName(code: enemy_policy.BlockerCode) []const u8 {
    return switch (code) {
        .unclassified_callback => "unclassified_callback",
        .pre_scan_special => "pre_scan_special",
        .unresolved_library_slot_124 => "unresolved_library_slot_124",
        .unresolved_special_effect => "unresolved_special_effect",
        .unresolved_script_effect => "unresolved_script_effect",
        .unresolved_descriptor_effect => "unresolved_descriptor_effect",
    };
}

/// The effect of one impact, expressed in gameplay units.
pub const Applied = struct {
    damage: i32,
    latch_mask: u8,
    target_script: ?[]const u8,
    clears_callback: bool,
};

/// Apply a resolved effect plan to one raw physical result.  A blocked or
/// unknown family is refused: there is no default multiplier.
pub fn applyEffect(effect: *const Effect, raw_result: i32) !Applied {
    if (effect.blocker != null or std.mem.eql(u8, effect.family, "blocked"))
        return error.BlockedEnemyEffect;
    if (!catalogue.knownEffectFamily(effect.family)) return error.UnknownEnemyEffectFamily;
    const damage = effect.damage orelse return error.MissingEffectDamage;
    if (damage.denominator <= 0) return error.InvalidEffectDamage;
    if (!std.mem.eql(u8, damage.rounding, "toward_zero")) return error.InvalidEffectDamage;
    const wide: i64 = @as(i64, raw_result) * @as(i64, damage.numerator);
    const scaled: i32 = @intCast(@divTrunc(wide, @as(i64, damage.denominator)));
    return .{
        .damage = scaled,
        .latch_mask = effect.latch_mask,
        .target_script = effect.target_script,
        .clears_callback = effect.clears_callback,
    };
}
