const std = @import("std");
const events = @import("event_runtime");
const engine = @import("battle");
const combat = @import("combat_session");

pub const schema = "suikoden-opening-battle/1";

pub const Guard = struct { byte_index: u8, mask: u8, required: enum { set, clear } };

const entry_guards = [_]Guard{
    .{ .byte_index = 4, .mask = 1, .required = .set },
    .{ .byte_index = 4, .mask = 2, .required = .clear },
    .{ .byte_index = 34, .mask = 8, .required = .clear },
};
pub const Entry = struct {
    id: []const u8,
    source_file: []const u8,
    room: u8,
    entity: u8,
    stream: u32,
    pre_effect_offset: u32,
    trigger_offset: u32,
    guard: []const Guard,
    pre_effect: StoryWrite,
    encounter_id: []const u8,
    victory: []const u8,
    defeat: []const u8,
    escape: []const u8,
};
pub const StoryWrite = struct { kind: []const u8, byte_index: u8, mask: u8 };
pub const Enemy = struct {
    record: []const u8,
    name: []const u8,
    hp: u16,
    stats_offset: u32,
    world: [3]i32,
    world_q12: [3]i32,
    policy: []const u8,
};
pub const Formation = struct {
    id: []const u8,
    descriptor_offset: u32,
    auxiliary_offset: u32,
    positions_offset: u32,
    roster: [6]u8,
    enemies: []const Enemy,
};
pub const Coverage = struct {
    battle_entries: u8,
    formations: u8,
    enemies: u8,
    victory_continuations: u8,
    defeat_continuations: u8,
    escape_blockers: u8,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    formation: Formation,
    entries: []const Entry,
    coverage: Coverage,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64)
        return error.InvalidBattleSchema;
    const formation = asset.formation;
    if (!std.mem.eql(u8, formation.id, "area_a.encounter.01") or
        !std.mem.eql(u8, &formation.roster, &[_]u8{ 1, 0, 0, 0, 0, 0 }) or
        formation.enemies.len != 1) return error.InvalidBattleFormation;
    const enemy = formation.enemies[0];
    if (!std.mem.eql(u8, enemy.record, "area_a.enemy.01") or
        !std.mem.eql(u8, enemy.name, "BonBon") or enemy.hp != 18 or
        enemy.stats_offset != 127996 or !std.mem.eql(i32, &enemy.world, &[_]i32{ -128, 0, 0 }))
        return error.InvalidBattleFormation;
    if (asset.entries.len != 3 or asset.coverage.battle_entries != 3 or
        asset.coverage.formations != 1 or asset.coverage.enemies != 1 or
        asset.coverage.victory_continuations != 3 or asset.coverage.defeat_continuations != 3 or
        asset.coverage.escape_blockers != 3) return error.InvalidBattleCoverage;
    for (asset.entries, 0..) |entry, index| {
        if (entry.room != 0 or entry.entity != 35 + index or
            !std.mem.eql(u8, entry.encounter_id, formation.id) or
            entry.pre_effect_offset >= entry.trigger_offset or
            entry.pre_effect.byte_index != 34 or entry.pre_effect.mask != 8 or
            !std.mem.eql(u8, entry.victory, "return_to_source_stream_no_auto_chain") or
            !std.mem.eql(u8, entry.defeat, "game_over_not_victory") or
            !std.mem.eql(u8, entry.escape, "typed_blocker_source_retry_unresolved"))
            return error.InvalidBattleEntry;
        if (entry.guard.len != entry_guards.len) return error.InvalidBattleGuard;
        for (entry.guard, entry_guards) |actual, expected| {
            if (!std.meta.eql(actual, expected)) return error.InvalidBattleGuard;
        }
    }
}

pub const Outcome = enum { unsettled, victory_returned, defeat_game_over };
pub const Session = struct {
    entry_id: []const u8,
    outcome: Outcome = .unsettled,
};

fn admitted(entry: Entry, story: *const events.StoryState) bool {
    for (entry.guard) |term| {
        const present = story.scenario[term.byte_index] & term.mask != 0;
        if (present != (term.required == .set)) return false;
    }
    return true;
}

pub fn begin(entry: Entry, story: *events.StoryState) !Session {
    if (!admitted(entry, story)) return error.BattleGuardFailed;
    story.scenario[entry.pre_effect.byte_index] |= entry.pre_effect.mask;
    return .{ .entry_id = entry.id };
}

pub fn settle(session: *Session, outcome: enum { victory, defeat, escape }) !void {
    if (session.outcome != .unsettled) return error.DuplicateSettlement;
    switch (outcome) {
        .victory => session.outcome = .victory_returned,
        .defeat => session.outcome = .defeat_game_over,
        .escape => return error.UnsupportedEscapeContinuation,
    }
}

const planSource = begin;
const settleSource = settle;

fn runtimeEncounter(asset: Asset, content: engine.Content, entry: Entry, runtime_id: []const u8) !engine.Encounter {
    try validate(asset);
    if (!std.mem.eql(u8, entry.encounter_id, asset.formation.id)) return error.InvalidBattleEntry;
    var found: ?engine.Encounter = null;
    for (content.encounters) |candidate| {
        if (!std.mem.eql(u8, candidate.id, runtime_id)) continue;
        if (candidate.enemies.len != asset.formation.enemies.len or candidate.positions.len != candidate.enemies.len) continue;
        var matches = true;
        for (asset.formation.enemies, candidate.enemies, candidate.positions) |expected, id, position| {
            const index = content.enemyIndex(id) orelse {
                matches = false;
                break;
            };
            const profile = content.enemies[index];
            if (!std.mem.eql(u8, profile.name, expected.name) or profile.max_hp != expected.hp or
                profile.action_policy != .attack or profile.target_policy != .random or
                !std.mem.eql(u8, expected.policy, "front_random_target") or
                position.x != @as(f32, @floatFromInt(expected.world[0])) or
                position.y != @as(f32, @floatFromInt(expected.world[1])) or
                position.z != @as(f32, @floatFromInt(expected.world[2])))
            {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        if (found != null) return error.AmbiguousOpeningBattleBinding;
        found = candidate;
    }
    return found orelse error.MissingOpeningBattleBinding;
}

pub const SourceContinuation = struct {
    entry_id: []const u8,
    stream: u32,
    trigger_offset: u32,
    resume_offset: u32,
};

pub const Settlement = struct {
    outcome: Outcome,
    continuation: ?SourceContinuation = null,
};

pub const CombatCaller = struct {
    planner: Session,
    session: combat.Session,
    source: engine.State,
    entry: Entry,
    admitted: [6]engine.OwnedMember,
    member_count: usize,

    pub fn begin(
        asset: Asset,
        entry: Entry,
        story: *events.StoryState,
        source: engine.State,
        scratch: []engine.Member,
        draws: engine.systems.Draws,
        runtime_id: []const u8,
        identity: combat.Entry,
    ) !CombatCaller {
        if (!admitted(entry, story)) return error.BattleGuardFailed;
        if (!std.mem.eql(u8, identity.encounter_id, entry.encounter_id)) return error.CombatIdentityMismatch;
        const runtime = try runtimeEncounter(asset, source.content, entry, runtime_id);
        var runtime_identity = identity;
        runtime_identity.encounter_id = runtime.id;
        const session = try combat.Session.begin(runtime_identity, source, scratch, draws);
        const planner = try planSource(entry, story);
        var admitted_members: [6]engine.OwnedMember = undefined;
        for (0..source.partyCount()) |index| admitted_members[index] = source.ownedMember(index);
        return .{
            .planner = planner,
            .session = session,
            .source = source,
            .entry = entry,
            .admitted = admitted_members,
            .member_count = source.partyCount(),
        };
    }

    pub fn tick(self: *CombatCaller, input: engine.Input, draws: *engine.systems.Draws) !void {
        if (self.planner.outcome != .unsettled) return error.DuplicateSettlement;
        try self.session.tick(input, draws);
    }

    fn commitVictory(self: *CombatCaller, result: combat.Result, draws: engine.systems.Draws) !void {
        if (result.member_count != self.member_count or self.source.partyCount() != self.member_count)
            return error.InvalidOpeningCombatResult;
        for (0..self.member_count) |index| {
            if (!std.meta.eql(self.admitted[index], self.source.ownedMember(index))) return error.StaleOpeningCombatState;
            try self.source.validateOwnedMember(result.members[index]);
        }
        var seen: [6]bool = @splat(false);
        for (result.formation) |slot| {
            if (slot >= result.member_count or seen[slot]) return error.InvalidFormation;
            seen[slot] = true;
        }
        var members: [6]engine.Member = undefined;
        var next = self.session.state;
        next.content = self.source.content;
        next.encounter = self.source.encounter;
        next.progress.party = members[0..result.member_count];
        for (0..result.member_count) |index| {
            members[index] = self.admitted[index].member;
            next.setOwnedMember(index, result.members[index]);
        }
        next.progress.money = result.money;
        next.formation = result.formation;
        next.asleep = @splat(0);
        next.clearTemporaryStats();
        next.unbalanced = @splat(0);
        next.medicine_action = null;
        try next.progress.validate();
        var acknowledged = self.session;
        try acknowledged.acknowledge(draws);
        @memcpy(self.source.progress.party, members[0..result.member_count]);
        next.progress.party = self.source.progress.party;
        self.source = next;
        self.session = acknowledged;
    }

    pub fn settle(self: *CombatCaller, draws: engine.systems.Draws) !Settlement {
        if (self.planner.outcome != .unsettled) return error.DuplicateSettlement;
        const result = try self.session.result(draws);
        switch (result.outcome) {
            .victory => {
                try self.commitVictory(result, draws);
                try settleSource(&self.planner, .victory);
                return .{
                    .outcome = self.planner.outcome,
                    .continuation = .{
                        .entry_id = self.entry.id,
                        .stream = self.entry.stream,
                        .trigger_offset = self.entry.trigger_offset,
                        .resume_offset = self.entry.trigger_offset + 2,
                    },
                };
            },
            .defeat => {
                var acknowledged = self.session;
                try acknowledged.acknowledge(draws);
                self.session = acknowledged;
                try settleSource(&self.planner, .defeat);
                return .{ .outcome = self.planner.outcome };
            },
            .fled, .released, .bribed => {
                try settleSource(&self.planner, .escape);
                unreachable;
            },
        }
    }
};
