//! Enemy policy adapter: enemy policy/effect plans and settlement facts
//! presented to the ordinary battle enemy coordinator and result constructor.
//!
//! The adapter is deliberately free of battle state: the caller passes a
//! six-slot roster snapshot and the reviewed row predicate, and gets a
//! semantic decision back.  The battle caller translates `battle.State`.
//!
//! Contracts preserved from the recovered routines:
//!   * a rejected full target scan stays pending when an eligible candidate
//!     existed, so the same enemy turn retries later without new priority
//!     rolls; no eligible candidate disables the action;
//!   * locked candidates consume no draw and are skipped;
//!   * draws are consumed in source order (one per scanned candidate, then the
//!     record's second draw, then settlement's pair/rate draws), and every
//!     failure restores the caller's RNG value;
//!   * six slots, draw order, encoded reward fields and the signed 999999
//!     balance cap with its overflow are preserved;
//!   * a blocked policy is refused before any draw; an unresolved special
//!     effect is planned exactly (draws included) but marked blocked, so the
//!     executor refuses it and rolls the whole update back instead of
//!     substituting another rule;
//!   * a settlement token can be credited once; a repeated token is refused
//!     with no balance, item or draw change.

const std = @import("std");
const systems = @import("battle_rules");
pub const policy_data = @import("policy.zig");
const data = @import("campaign_policies_data").enemy_policy;

pub const json = data.enemy_policy_json;

pub const Packet = policy_data.Packet;
pub const Record = policy_data.Record;
pub const Special = policy_data.Special;
pub const Blocker = policy_data.Blocker;
pub const BlockerCode = policy_data.BlockerCode;
pub const EffectKind = policy_data.EffectKind;

pub const slot_count = policy_data.slot_count;
pub const front_below = policy_data.front_below;
pub const money_cap = policy_data.money_cap;
pub const money_rune = policy_data.money_rune;

pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Packet) {
    return policy_data.load(allocator, json);
}

pub fn loadBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    return policy_data.load(allocator, bytes);
}

// ---------------------------------------------------------------------------
// decision planning
// ---------------------------------------------------------------------------

/// One party member as the coordinator sees it.  `slot` is the zero-based
/// six-slot formation index; `front` is the reviewed row predicate (the
/// coordinator's own party row, not a comparison of `slot` against the source
/// +0x44 gate value).
pub const PartyRow = struct {
    slot: u8,
    front: bool,
    active: bool,
    locked: bool,
};

pub const OwnSlot = struct {
    slot: u8,
    front: bool,
};

pub const Attack = struct {
    target: u8,
    target_slot: u8,
    draws_used: usize,
};

pub const SpecialAction = struct {
    target: ?u8,
    target_slot: ?u8,
    special: *const Special,
    effect_blocked: bool,
    draws_used: usize,
};

pub const Pending = struct {
    eligible_seen: bool,
    draws_used: usize,
};

pub const Decision = union(enum) {
    attack: Attack,
    special: SpecialAction,
    pending: Pending,
    disabled,
    blocked: Blocker,

    /// True when the plan is a special whose effect is not recovered.  The
    /// executor must refuse it instead of running an ordinary attack.
    pub fn effectBlocked(self: Decision) bool {
        return switch (self) {
            .special => |action| action.effect_blocked,
            else => false,
        };
    }
};

pub fn decide(record: *const Record, party: []const PartyRow, own: OwnSlot, draws: *systems.Draws) !Decision {
    const saved = draws.*;
    return decideInner(record, party, own, draws) catch |err| {
        draws.* = saved;
        return err;
    };
}

fn decideInner(record: *const Record, party: []const PartyRow, own: OwnSlot, draws: *systems.Draws) !Decision {
    const start = draws.cursor;
    const policy = &record.policy;
    if (policy.family == .blocked) return .{ .blocked = policy.blocker.? };
    if (own.slot >= slot_count) return error.InvalidFormationSlot;
    if (party.len > slot_count) return error.InvalidParty;
    for (party) |member| if (member.slot >= slot_count) return error.InvalidFormationSlot;

    var scan_state = ScanState{ .policy = policy, .party = party, .draws = draws };
    var eligible_seen = false;

    const chosen: ?Chosen = switch (policy.family) {
        .blocked => unreachable,
        .random_target => try scan_state.scan(&eligible_seen),
        .target_then_script_chance, .target_then_special_chance => try scan_state.scan(&eligible_seen),
        .own_row_special => if (!own.front) null else try scan_state.scan(&eligible_seen),
        .target_row_special, .always_special => try scan_state.scan(&eligible_seen),
    };

    switch (policy.family) {
        .blocked => unreachable,
        .random_target => {
            if (chosen) |target| return .{ .attack = .{
                .target = target.index,
                .target_slot = target.slot,
                .draws_used = draws.cursor - start,
            } };
            return noSelection(policy, eligible_seen, draws, start);
        },
        .target_then_script_chance, .target_then_special_chance => {
            if (chosen == null) return noSelection(policy, eligible_seen, draws, start);
            const second = policy.second_draw.?;
            const roll = try draws.next();
            if (drawValue(second.kind, roll) >= second.threshold) {
                return .{ .special = specialAction(&policy.special.?, chosen, draws, start) };
            }
            return .{ .attack = .{
                .target = chosen.?.index,
                .target_slot = chosen.?.slot,
                .draws_used = draws.cursor - start,
            } };
        },
        .own_row_special => {
            if (!own.front) return .{ .special = specialAction(&policy.special.?, null, draws, start) };
            if (chosen) |target| return .{ .attack = .{
                .target = target.index,
                .target_slot = target.slot,
                .draws_used = draws.cursor - start,
            } };
            return noSelection(policy, eligible_seen, draws, start);
        },
        .target_row_special => {
            if (chosen == null) return noSelection(policy, eligible_seen, draws, start);
            if (!chosen.?.front) return .{ .special = specialAction(&policy.special.?, chosen, draws, start) };
            return .{ .attack = .{
                .target = chosen.?.index,
                .target_slot = chosen.?.slot,
                .draws_used = draws.cursor - start,
            } };
        },
        .always_special => {
            if (chosen == null) return noSelection(policy, eligible_seen, draws, start);
            return .{ .special = specialAction(&policy.special.?, chosen, draws, start) };
        },
    }
}

pub const Chosen = struct { index: u8, slot: u8, front: bool };

pub fn scanTargets(shape: policy_data.Scan, party: []const PartyRow, draws: anytype, eligible_seen: *bool) !?Chosen {
    for (party, 0..) |member, index| {
        if (!member.active or (shape.front_only and !member.front)) continue;
        // A locked eligible actor keeps the source callback pending without an RNG draw.
        eligible_seen.* = true;
        if (member.locked) continue;
        if (drawValue(shape.draw_kind, try draws.next()) >= shape.accept_at_least)
            return .{ .index = @intCast(index), .slot = member.slot, .front = member.front };
    }
    return null;
}

const ScanState = struct {
    policy: *const policy_data.Policy,
    party: []const PartyRow,
    draws: *systems.Draws,

    fn scan(self: *ScanState, eligible_seen: *bool) !?Chosen {
        return scanTargets(self.policy.scan.?, self.party, self.draws, eligible_seen);
    }
};

fn noSelection(policy: *const policy_data.Policy, eligible_seen: bool, draws: *systems.Draws, start: usize) Decision {
    return switch (policy.no_selection.?) {
        .pending_if_any_eligible => if (eligible_seen)
            .{ .pending = .{ .eligible_seen = true, .draws_used = draws.cursor - start } }
        else
            .disabled,
        .disabled => .disabled,
        .pending => .{ .pending = .{ .eligible_seen = eligible_seen, .draws_used = draws.cursor - start } },
    };
}

fn specialAction(special: *const Special, target: ?Chosen, draws: *systems.Draws, start: usize) SpecialAction {
    return .{
        .target = if (target) |chosen| chosen.index else null,
        .target_slot = if (target) |chosen| chosen.slot else null,
        .special = special,
        .effect_blocked = !special.resolved(),
        .draws_used = draws.cursor - start,
    };
}

pub fn drawValue(kind: policy_data.DrawKind, roll: u15) u32 {
    const value: u32 = roll;
    return switch (kind) {
        .percent_100 => value % 100,
        .scale_100_32767 => (value * 100) / 32767,
        .scale_100_32767_mod_100 => ((value * 100) / 32767) % 100,
    };
}

// ---------------------------------------------------------------------------
// settlement (result constructor)
// ---------------------------------------------------------------------------

pub const Present = struct {
    record: *const Record,
    eligible: bool,
};

pub const Grant = struct {
    item: u8,
    uses: u8,
};

pub const Receipt = struct {
    /// Encoded reward sum after rune doubling, u32 wrapping (source +0x34
    /// decode is signed; the plan keeps the source's unsigned sum term).
    money_delta: u32,
    /// Balance after the signed 999999 cap.
    balance_after: u32,
    /// Amount actually credited to the caller's balance (cap included).
    credited: u32,
    /// Amount suppressed by the cap.  The cap owns it; it is never paid out
    /// later.
    overflow: u32,
    item: ?Grant,
    eligible_count: u8,
    draws_used: usize,
};

/// Caller-owned per-victory identities.  A token must be a stable identity for
/// one valid result (the battle integration request uses the encounter index), so replaying
/// the result constructor cannot credit the same victory twice.
pub const AwardLedger = struct {
    tokens: [8]u64 = @splat(0),
    len: u8 = 0,

    pub fn awarded(self: AwardLedger, token: u64) bool {
        for (self.tokens[0..self.len]) |seen| if (seen == token) return true;
        return false;
    }

    fn push(self: *AwardLedger, token: u64) void {
        self.tokens[self.len] = token;
        self.len += 1;
    }
};

/// Plan and commit one ordinary victory settlement.
///
/// `present` are the six source enemy slots in actor order; ineligible actors
/// still occupy their slot but contribute neither money nor item rolls.
/// `money_runes` is the six party members' money-rune membership in party
/// order (the source rune id 0x17; the battle predicate is the existing
/// prosperity rune check).  Each true doubles the sum.  `token` identifies the valid result; the ledger refuses a
/// repeat.  On every error nothing is committed, the caller's `draws` value is
/// restored, and the ledger is unchanged.
pub fn settle(
    catalogue: *const Packet,
    present: []const Present,
    money_runes: []const bool,
    balance: u32,
    token: u64,
    ledger: *AwardLedger,
    draws: *systems.Draws,
) !Receipt {
    if (present.len > slot_count) return error.InvalidEnemySlots;
    if (money_runes.len > slot_count) return error.InvalidParty;
    if (ledger.awarded(token)) return error.RewardAlreadyAwarded;
    if (ledger.len >= ledger.tokens.len) return error.AwardLedgerFull;
    const saved = draws.*;
    const receipt = settleInner(catalogue, present, money_runes, balance, draws) catch |err| {
        draws.* = saved;
        return err;
    };
    ledger.push(token);
    return receipt;
}

fn settleInner(
    catalogue: *const Packet,
    present: []const Present,
    money_runes: []const bool,
    balance: u32,
    draws: *systems.Draws,
) !Receipt {
    const start = draws.cursor;
    var delta: u32 = 0;
    var eligible_count: u8 = 0;
    for (present) |entry| {
        if (!entry.eligible) continue;
        eligible_count += 1;
        delta +%= decodeMoney(entry.record.money_encoded);
    }
    for (money_runes) |carries| if (carries) {
        delta *%= 2;
    };
    const total = balance +% delta;
    const after = rewardBalance(balance, delta);
    var selected: ?Grant = null;
    if (eligible_count != 0) {
        for (present) |entry| {
            if (!entry.eligible or selected != null) continue;
            const pair = @as(usize, try draws.next()) % 3;
            const drop = entry.record.drops[pair];
            if (drop.item == 0) continue;
            const roll = @as(u32, try draws.next()) % 100;
            if (roll < drop.rate) {
                const item = catalogue.dropItem(drop.item) orelse return error.UnknownDropItem;
                selected = .{ .item = item.id, .uses = item.default_uses };
            }
        }
    }
    return .{
        .money_delta = delta,
        .balance_after = after,
        .credited = after -% balance,
        .overflow = total -% after,
        .item = selected,
        .eligible_count = eligible_count,
        .draws_used = draws.cursor - start,
    };
}

/// Decode record+0x34: even values add directly; odd values add
/// 100*trunc_toward_zero(value/10).  The result is the 32-bit sum term.
pub fn decodeMoney(encoded: i16) u32 {
    const bits: u16 = @bitCast(encoded);
    if (bits & 1 == 0) return @bitCast(@as(i32, encoded));
    const value: i32 = encoded;
    return @bitCast(@divTrunc(value, 10) * 100);
}

/// Signed comparison against the 999999 cap on the u32-wrapping total.
pub fn rewardBalance(balance: u32, delta: u32) u32 {
    const total = balance +% delta;
    const signed: i32 = @bitCast(total);
    return if (signed > money_cap) money_cap else total;
}

/// Bribe price: three times the raw signed +0x34 sum over occupied six-slot
/// roster entries.  It is not decoded reward money.
pub fn bribePrice(slots: []const ?*const Record) !u32 {
    if (slots.len > slot_count) return error.InvalidEnemySlots;
    var sum: i32 = 0;
    for (slots) |maybe| if (maybe) |record| {
        sum +%= record.money_encoded;
    };
    const price = sum *% 3;
    if (price < 0) return error.NegativeBribePrice;
    return @intCast(price);
}
