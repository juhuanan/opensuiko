//! The Unite participant lifecycle over the current coordinator.
//!
//! The module owns no scheduler, no action table and no random source.  It is
//! the rule/transaction layer the existing action coordinator calls:
//!
//!   plan      match the record's members, validate the target (with the source
//!             repair scan), require every participant to be selectable
//!   commit    book `.unite`, the selected record and the target on every
//!             participant; clear their selectable flags
//!   impact    one physical result per participant in record order, combined as
//!             `sum * multiplier / 10`, applied once to the target
//!   finish    apply recovery (counter 1) to living members
//!   undo      restore the prior command state, flags and availability
//!
//! Source rules that shape the code (MAIN.EXE):
//!   * matcher `0x800F91C0` marks `B+0x46 = 1`, clears `A+0x40`, writes `B+0x49`,
//!     and iterates `m = 0 .. count-1` in record order;
//!   * commit `0x800EDE58` writes `B+0x47 = 4`, `B+0x48 = index + 1`,
//!     `B+0x49 = target` and clears `UI+0xB4+4*slot`;
//!   * availability `0x800EF104` accepts a member only when selectable,
//!     `0x800F8680` accepts the index, and `B+0x4A & 0x61` is clear;
//!   * validator `0x800F5x8C` dispatches on the record's low flag bits;
//!     `0x800F8680` validates and `0x800F6344` repairs an individual target;
//!   * `0x800F9488` gates on the selected actor's `A+0x40` bit 1 and clears every
//!     member's bit; `0x800F95E8` gates on the target's `B+0x45 == 0`;
//!   * the common return descriptor applies `op40(7,100)`, whose party handler
//!     sets `0x40` and counter 1; the round boundary retains it once and then
//!     clears the class (`0x800F657C..0x800F65B8`);
//!   * `0x800F6BF8..0x800F6C2C` clears `B+0x47/0x48/0x49` for every combatant
//!     at the round reset.
//!
//! Dispatch validates participants before initialization. Once started, damage
//! consumes the fixed matched roster without rechecking HP or status eligibility.
//! Port boundary: an out-of-range stale bypass target refuses rather than reading
//! an invalid target slot.

const std = @import("std");
const catalogue = @import("catalogue.zig");
const rng = @import("battle_rules");

pub const schema = "suikoden-unite-boundary/3";
pub const max_members = catalogue.max_members;
pub const max_party = catalogue.max_party;

/// Source constants; the comment names where the rule is implemented.
pub const rules = struct {
    /// `B+0x4A & 0x61`: sleep (0x20), recovery (0x40) and the down/other bit
    /// (0x01) all exclude a participant (`0x800EF29C`).
    pub const eligibility_mask: u16 = 0x61;
    /// Recovery class applied by the common return descriptor (`0x8016D284`).
    pub const recovery_mask: u16 = 0x40;
    /// `B+0x47 = 4` is the Unite row of the command menu (`0x800EDF98`).
    pub const unite_command: u8 = 4;
    /// `B+0x48 = record index + 1` (`0x800EDFB0`, matcher bias).
    pub const ordinal_bias: u8 = 1;
    /// `A+0x40` bit 1: the hit/commit gate read by `0x800F9488`.
    pub const hit_flag: u16 = 0x0002;
    /// `A+0x40` bit 2: the per-member completion slot set by `0x800F9390`.
    pub const ready_flag: u16 = 0x0004;
    /// The combined-damage divisor (`mult` then `div 10` at `0x800F9564..9574`).
    pub const damage_divisor: u32 = 10;
    /// Recovery counter written with the mask (`B+0x4D = 1` at `0x800E05CC`).
    pub const recovery_counter: u8 = 1;
};

pub const StatusFlags = packed struct(u16) {
    poisoned: bool = false,
    _unused1: u4 = 0,
    asleep: bool = false,
    recovering: bool = false,
    _unused7: u9 = 0,

    pub fn isIneligible(self: StatusFlags) bool {
        return self.poisoned or self.asleep or self.recovering;
    }

    pub fn fromMask(mask: u16) StatusFlags {
        return @bitCast(mask);
    }

    pub fn toMask(self: StatusFlags) u16 {
        return @bitCast(self);
    }
};

pub const ActorFlags = packed struct(u16) {
    _unused0: bool = false,
    hit_ready: bool = false,
    return_ready: bool = false,
    _unused3: u13 = 0,

    pub fn fromMask(mask: u16) ActorFlags {
        return @bitCast(mask);
    }

    pub fn toMask(self: ActorFlags) u16 {
        return @bitCast(self);
    }
};

pub const SlotCommand = enum(u8) {
    none = 0,
    attack = 1,
    rune = 2,
    item = 3,
    unite = 4,
    defend = 5,
    _,
};

pub const Target = union(enum) {
    none,
    party: usize,
    enemy: usize,

    pub fn fromSourceIndex(party_count: usize, raw: i16) Target {
        if (raw <= 0) return .none;
        const index: usize = @intCast(raw - 1);
        return if (index < party_count) .{ .party = index } else .{ .enemy = index - party_count };
    }

    pub fn toSourceIndex(self: Target, party_count: usize) i16 {
        return switch (self) {
            .none => 0,
            .party => |slot| @intCast(slot + 1),
            .enemy => |slot| @intCast(party_count + 1 + slot),
        };
    }

    pub fn fromCombatantIndex(party_count: usize, index: usize) Target {
        return if (index < party_count) .{ .party = index } else .{ .enemy = index - party_count };
    }

    pub fn toCombatantIndex(self: Target, party_count: usize) ?usize {
        return switch (self) {
            .none => null,
            .party => |slot| slot,
            .enemy => |slot| party_count + slot,
        };
    }

    pub fn eql(a: Target, b: Target) bool {
        return switch (a) {
            .none => b == .none,
            .party => |slot| b == .party and b.party == slot,
            .enemy => |slot| b == .enemy and b.enemy == slot,
        };
    }
};

pub const Slot = struct {
    character_id: u8,
    active: bool = true,
    status: StatusFlags = .{},
    hp: i16 = 1,
    status_byte: u8 = 0,
    available: bool = true,
    command: SlotCommand = .none,
    unite_record: ?u8 = null,
    target: Target = .none,
    recovery_counter: u8 = 0,
    actor_flags: ActorFlags = .{},
};

pub const CommandWrite = struct {
    command: SlotCommand,
    unite_record: ?u8,
    target: Target,
    available: bool,
};

pub const SlotState = struct {
    command: SlotCommand = .none,
    unite_record: ?u8 = null,
    target: Target = .none,
    available: bool = true,
    actor_flags: ActorFlags = .{},

    pub fn of(slot: Slot) SlotState {
        return .{
            .command = slot.command,
            .unite_record = slot.unite_record,
            .target = slot.target,
            .available = slot.available,
            .actor_flags = slot.actor_flags,
        };
    }

    pub fn write(self: SlotState) CommandWrite {
        return .{
            .command = self.command,
            .unite_record = self.unite_record,
            .target = self.target,
            .available = self.available,
        };
    }

    pub fn eql(a: SlotState, b: SlotState) bool {
        return a.command == b.command and a.unite_record == b.unite_record and
            a.target.eql(b.target) and a.available == b.available and
            a.actor_flags == b.actor_flags;
    }
};

pub const View = struct {
    party: []const Slot,
    enemies: []const Slot,

    pub fn enemySlot(self: View, target: Target) ?usize {
        return switch (target) {
            .enemy => |slot| if (slot < self.enemies.len) slot else null,
            else => null,
        };
    }

    pub fn livingEnemies(self: View) u8 {
        var n: u8 = 0;
        for (self.enemies) |enemy| if (enemy.active) {
            n += 1;
        };
        return n;
    }
};

pub const Request = struct {
    /// Zero-based party slot of the actor whose command selected Unite.
    actor: usize,
    /// Zero-based catalogue index of the selected record.
    record: u8,
    /// Chosen target (ignored for bypass).
    target: Target = .none,
};

pub const CommandKind = enum { attack, rune, unite, item, defend };

pub const Refusal = enum {
    unknown_record,
    actor_not_member,
    effect_family_blocked,
    missing_member,
    participant_down,
    participant_unavailable,
    participant_assigned,
    invalid_target,
    no_replacement,
    bypass_without_living_enemy,
    participant_lost,
    cancelled,
    not_committed,
    already_finished,
    overflow,
};

pub const Failure = union(enum) {
    refusal: Refusal,
    random: anyerror,
};

pub const Skip = enum { leader_hit_flag_clear, target_inactive };

pub const Impact = union(enum) {
    applied: u32,
    skipped: Skip,
    failed: Failure,
};

pub const PlanResult = union(enum) {
    boundary: Boundary,
    refusal: Refusal,
};

pub const Stage = enum { planned, committed, impacted, finished, rolled_back };

pub const TargetQueue = struct {
    pending: [max_party]bool = @splat(false),
    targets: [max_members]?usize = @splat(null),
    ready_at: [max_members]u16 = @splat(0),
    impact_at: [max_members]?u16 = @splat(null),
    return_at: [max_members]?u16 = @splat(null),
    finish_at: ?u16 = null,
};

pub const Boundary = struct {
    record_index: u8,
    command_owner: usize,
    sequence: ?TargetQueue = null,
    recovery: [max_members]bool = @splat(false),
    target: Target,
    /// `0x800F6344` replaced an invalid individual target.
    retargeted_from: ?Target = null,
    participants: [max_members]usize = @splat(0),
    count: u8 = 0,
    prior: [max_members]SlotState = @splat(.{}),
    stage: Stage = .planned,
    finished_members: u8 = 0,
    saved_draws: ?rng.Draws = null,
    amount: u32 = 0,

    pub fn wireOrdinal(self: Boundary) u8 {
        return self.record_index + rules.ordinal_bias;
    }

    pub fn hitActor(self: *const Boundary, record: *const catalogue.Record) ?usize {
        const actor = record.hit_actor orelse return null;
        return switch (actor.kind) {
            .command_owner => self.command_owner,
            .member => self.participants[actor.member.?],
        };
    }

    pub fn participantsSlice(self: *const Boundary) []const usize {
        return self.participants[0..self.count];
    }

    pub fn commit(self: *Boundary, host: Host) !void {
        return commitBoundary(self, host);
    }

    pub fn impact(
        self: *Boundary,
        cat: *const catalogue.Catalogue,
        view: View,
        host: Host,
        draws: *rng.Draws,
    ) Impact {
        return impactBoundary(self, cat, view, host, draws);
    }

    pub fn advanceSequence(self: *Boundary, cat: *const catalogue.Catalogue, view: View, host: Host, draws: *rng.Draws, tick: u16) ?Impact {
        const record = cat.recordAt(self.record_index) orelse return null;
        const timing = record.sequence orelse return null;
        var queue = self.sequence orelse return null;
        var applied: ?u32 = null;
        for (0..self.count) |member| {
            if (queue.return_at[member] == null and tick >= queue.ready_at[member]) {
                const chosen: ?usize = for (queue.pending, 0..) |pending, enemy| {
                    if (pending) break enemy;
                } else null;
                if (chosen) |enemy| {
                    queue.pending[enemy] = false;
                    queue.targets[member] = enemy;
                    queue.impact_at[member] = tick + timing.members[member].impact;
                    queue.ready_at[member] = tick + timing.members[member].ready;
                } else {
                    queue.targets[member] = null;
                    queue.return_at[member] = tick + timing.members[member].retreat;
                    queue.impact_at[member] = null;
                }
            }
        }
        for (0..self.count) |member| if (queue.impact_at[member]) |at| {
            if (tick < at) continue;
            var hit = self.*;
            hit.sequence = null;
            hit.stage = .committed;
            hit.target = .{ .enemy = queue.targets[member].? };
            const result = impactBoundary(&hit, cat, view, host, draws);
            switch (result) {
                .applied => |amount| {
                    applied = (applied orelse 0) +| amount;
                    self.amount +|= amount;
                    self.stage = .impacted;
                },
                .skipped => {},
                .failed => return result,
            }
            queue.impact_at[member] = null;
        };
        var complete = true;
        var finish_tick: u16 = 0;
        for (0..self.count) |member| {
            if (queue.return_at[member]) |at| {
                finish_tick = @max(finish_tick, @max(at, at - timing.members[member].retreat + timing.finish_delay));
            } else complete = false;
        }
        if (complete) queue.finish_at = finish_tick;
        self.sequence = queue;
        return if (applied) |amount| .{ .applied = amount } else null;
    }

    pub fn finish(self: *Boundary, view: View, host: Host) !void {
        return finishBoundary(self, view, host);
    }

    pub fn finishMember(self: *Boundary, view: View, host: Host, slot: usize) !void {
        if (self.stage != .impacted and self.stage != .committed) return error.InvalidBoundaryStage;
        if (slot >= view.party.len) return error.NotParticipant;
        const member = for (self.participantsSlice(), 0..) |participant, index| {
            if (participant == slot) break index;
        } else return error.NotParticipant;
        const bit = @as(u8, 1) << @intCast(member);
        if (self.finished_members & bit != 0) return error.MemberAlreadyFinished;
        const state = view.party[slot];
        if (state.active and self.recovery[member]) {
            var next_status = state.status;
            next_status.recovering = true;
            host.write_status(host.context, slot, next_status, rules.recovery_counter);
        }
        self.finished_members |= bit;
        if (self.finished_members == (@as(u8, 1) << @intCast(self.count)) - 1) self.stage = .finished;
    }

    pub fn undo(self: *Boundary, host: Host) void {
        return undoBoundaryPublic(self, host);
    }
};

pub const Host = struct {
    context: *anyopaque,
    write_slot: *const fn (context: *anyopaque, slot: usize, state: CommandWrite) void,
    write_status: *const fn (context: *anyopaque, slot: usize, status: StatusFlags, counter: u8) void,
    write_flags: *const fn (context: *anyopaque, slot: usize, flags: ActorFlags) void,
    apply_damage: *const fn (context: *anyopaque, target: Target, amount: u32) void,
    physical: *const fn (context: *anyopaque, slot: usize, target: Target, draws: *rng.Draws) anyerror!u32,
    hit_ready: *const fn (context: *anyopaque, slot: usize) bool,
};

const TargetResult = union(enum) {
    target: Target,
    refusal: Refusal,
};

fn resolveTarget(record: *const catalogue.Record, view: View, request: Request) TargetResult {
    switch (record.target_rule) {
        .individual => {
            if (view.enemySlot(request.target)) |slot| {
                const enemy = view.enemies[slot];
                if (enemy.active and enemy.hp >= 0) return .{ .target = request.target };
            }
            for (view.enemies, 0..) |enemy, i| {
                if (enemy.status_byte == 0 and enemy.active and enemy.hp > 0) {
                    return .{ .target = .{ .enemy = i } };
                }
            }
            return .{ .refusal = .no_replacement };
        },
        .bypass => {
            if (view.livingEnemies() == 0) return .{ .refusal = .bypass_without_living_enemy };
            if (record.sequence != null) for (view.enemies, 0..) |enemy, i| {
                if (enemy.active) return .{ .target = .{ .enemy = i } };
            };
            const existing = view.party[request.actor].target;
            if (view.enemySlot(existing)) |slot| {
                const enemy = view.enemies[slot];
                if (enemy.active and enemy.hp >= 0) return .{ .target = existing };
            }
            if (record.all_enemies) for (view.enemies, 0..) |enemy, i| {
                if (enemy.active and enemy.hp > 0) return .{ .target = .{ .enemy = i } };
            };
            return .{ .refusal = .invalid_target };
        },
    }
}

/// Validate a Unite selection and build the pending boundary.  Pure: it never
/// touches the host or the random stream.
pub fn plan(cat: *const catalogue.Catalogue, view: View, request: Request) PlanResult {
    const record = cat.recordAt(request.record) orelse return .{ .refusal = .unknown_record };
    if (!record.proven()) return .{ .refusal = .effect_family_blocked };
    if (request.actor >= view.party.len) return .{ .refusal = .actor_not_member };

    var boundary = Boundary{
        .record_index = record.index,
        .command_owner = request.actor,
        .recovery = record.recovery,
        .target = .none,
    };

    var used: [max_party]bool = @splat(false);
    var actor_found = false;
    for (record.membersSlice(), 0..) |member, m| {
        var found: ?usize = null;
        for (view.party, 0..) |slot, i| {
            if (!used[i] and slot.character_id == member) {
                found = i;
                break;
            }
        }
        const index = found orelse return .{ .refusal = .missing_member };
        used[index] = true;
        boundary.participants[m] = index;
        boundary.prior[m] = SlotState.of(view.party[index]);
        boundary.count += 1;
        if (index == request.actor) actor_found = true;
    }
    if (!actor_found) return .{ .refusal = .actor_not_member };

    for (boundary.participantsSlice()) |index| {
        const slot = view.party[index];
        if (!slot.active or slot.hp < 0) return .{ .refusal = .participant_down };
        if (slot.status.isIneligible()) return .{ .refusal = .participant_unavailable };
        if (!slot.available) return .{ .refusal = .participant_assigned };
    }

    const resolved = resolveTarget(record, view, request);
    switch (resolved) {
        .refusal => |refusal| return .{ .refusal = refusal },
        .target => |target| {
            // Only the individual rule can be repaired (0x800F6344); a bypass
            // record reuses its existing target and reports no retarget.
            if (record.target_rule == .individual and !target.eql(request.target))
                boundary.retargeted_from = request.target;
            boundary.target = target;
        },
    }
    if (record.sequence) |sequence| {
        if (view.enemies.len > max_party) return .{ .refusal = .invalid_target };
        var queue = TargetQueue{};
        for (view.enemies, 0..) |enemy, i| queue.pending[i] = enemy.active and enemy.status_byte == 0;
        for (sequence.members, 0..) |timing, i| queue.ready_at[i] = timing.setup_ready;
        boundary.sequence = queue;
    }
    return .{ .boundary = boundary };
}

/// Apply every pending write in one pass.
pub fn commitBoundary(boundary: *Boundary, host: Host) !void {
    if (boundary.stage != .planned) return error.InvalidBoundaryStage;
    for (boundary.participantsSlice()) |slot| {
        host.write_slot(host.context, slot, .{
            .command = .unite,
            .unite_record = boundary.record_index,
            .target = boundary.target,
            .available = false,
        });
    }
    boundary.stage = .committed;
}

/// Compute the combined hit and apply it once.
pub fn impactBoundary(
    boundary: *Boundary,
    cat: *const catalogue.Catalogue,
    view: View,
    host: Host,
    draws: *rng.Draws,
) Impact {
    return impactBoundaryImpl(boundary, cat, view, host, draws, true, false);
}

/// A repeating member calls the shared target helper without clearing its partner's signals.
pub fn impactSequenceTarget(boundary: *const Boundary, cat: *const catalogue.Catalogue, view: View, host: Host, draws: *rng.Draws, target: Target) Impact {
    var hit = boundary.*;
    hit.stage = .committed;
    hit.sequence = null;
    hit.target = target;
    return impactBoundaryImpl(&hit, cat, view, host, draws, false, true);
}

fn impactBoundaryImpl(
    boundary: *Boundary,
    cat: *const catalogue.Catalogue,
    view: View,
    host: Host,
    draws: *rng.Draws,
    clear_member_signals: bool,
    single_target: bool,
) Impact {
    if (boundary.stage != .committed) return .{ .failed = .{ .refusal = .not_committed } };
    const record = cat.recordAt(boundary.record_index) orelse
        return .{ .failed = .{ .refusal = .unknown_record } };
    const gate = record.gate orelse return .{ .failed = .{ .refusal = .effect_family_blocked } };

    switch (gate) {
        .leader_hit_flag => {
            if (!host.hit_ready(host.context, boundary.hitActor(record).?))
                return .{ .skipped = .leader_hit_flag_clear };
        },
        .target_active => {
            const slot = view.enemySlot(boundary.target) orelse
                return .{ .failed = .{ .refusal = .invalid_target } };
            if ((!record.all_enemies or single_target) and (!view.enemies[slot].active or (single_target and view.enemies[slot].status_byte != 0))) return .{ .skipped = .target_inactive };
        },
    }

    const all_targets = record.all_enemies and !single_target;
    const saved = draws.*;
    boundary.saved_draws = saved;
    var amounts: [catalogue.max_party]u32 = @splat(0);
    const target_count = if (all_targets) view.enemies.len else 1;
    if (target_count > amounts.len) {
        boundary.saved_draws = null;
        restoreBoundary(boundary, host);
        return .{ .failed = .{ .refusal = .invalid_target } };
    }
    var total: u64 = 0;
    for (0..target_count) |target_index| {
        if (all_targets and !view.enemies[target_index].active) continue;
        const target: Target = if (all_targets) .{ .enemy = target_index } else boundary.target;
        var sum: u64 = 0;
        for (boundary.participantsSlice()) |slot| {
            const contribution = host.physical(host.context, slot, target, draws) catch |err| {
                draws.* = saved;
                boundary.saved_draws = null;
                restoreBoundary(boundary, host);
                return .{ .failed = .{ .random = err } };
            };
            sum += contribution;
        }
        const amount = sum * record.multiplier / rules.damage_divisor;
        total += amount;
        if (total > std.math.maxInt(u32)) {
            draws.* = saved;
            boundary.saved_draws = null;
            restoreBoundary(boundary, host);
            return .{ .failed = .{ .refusal = .overflow } };
        }
        amounts[target_index] = @intCast(amount);
    }
    // Stage every target before publishing HP, so a late draw failure is atomic.
    for (0..target_count) |target_index| {
        if (all_targets and !view.enemies[target_index].active) continue;
        const target: Target = if (all_targets) .{ .enemy = target_index } else boundary.target;
        host.apply_damage(host.context, target, amounts[target_index]);
    }
    const amount: u32 = @intCast(total);
    // Damage consumes hit flags; each member's script supplies its own return-ready flag.
    if (clear_member_signals) for (boundary.participantsSlice()) |slot| {
        var flags = view.party[slot].actor_flags;
        flags.hit_ready = false;
        host.write_flags(host.context, slot, flags);
    };
    boundary.amount = amount;
    boundary.stage = .impacted;
    return .{ .applied = amount };
}

/// Apply recovery only to members whose selected source scripts carry op40(7,100).
pub fn finishBoundary(boundary: *Boundary, view: View, host: Host) !void {
    if (boundary.stage != .impacted and boundary.stage != .committed)
        return error.InvalidBoundaryStage;
    for (boundary.participantsSlice(), 0..) |slot, member| {
        if (boundary.finished_members & (@as(u8, 1) << @intCast(member)) == 0) try boundary.finishMember(view, host, slot);
    }
}

fn restoreBoundary(boundary: *Boundary, host: Host) void {
    for (boundary.participantsSlice(), 0..) |slot, k| {
        host.write_slot(host.context, slot, boundary.prior[k].write());
        host.write_flags(host.context, slot, boundary.prior[k].actor_flags);
    }
    boundary.stage = .rolled_back;
}

/// Cancel or abort a boundary.  Idempotent: undoing already-restored state is a no-op.
pub fn undoBoundaryPublic(boundary: *Boundary, host: Host) void {
    switch (boundary.stage) {
        .planned, .impacted, .committed => restoreBoundary(boundary, host),
        .rolled_back, .finished => {},
    }
}

pub const RecoveryTick = enum { idle, retained, cleared };

pub fn tickRecovery(slot: *Slot) RecoveryTick {
    if (!slot.status.recovering) return .idle;
    if (slot.recovery_counter != 0) {
        slot.recovery_counter -= 1;
        return .retained;
    }
    slot.status.recovering = false;
    slot.recovery_counter = 0;
    return .cleared;
}

pub fn allows(kind: CommandKind) bool {
    return switch (kind) {
        .attack, .rune, .unite => false,
        .item, .defend => true,
    };
}

pub fn roundReset() SlotState {
    return .{ .command = .none, .unite_record = null, .target = .none, .available = true, .actor_flags = .{} };
}

pub fn memberMark() u8 {
    return 1;
}
