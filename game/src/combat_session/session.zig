const std = @import("std");
const battle = @import("battle");
const rules = @import("battle_rules");
const battle_host = @import("battle_systems").host;

// Identity strings and content remain borrowed for the whole session and result.
pub const Entry = struct {
    id: []const u8,
    receipt: []const u8,
    content_id: []const u8,
    encounter_id: []const u8,
    content_fingerprint: []const u8,
};
pub const Outcome = enum { victory, fled, released, bribed, defeat };
pub const Result = struct {
    entry: Entry,
    outcome: Outcome,
    money: u32,
    members: [6]battle.OwnedMember,
    member_count: usize,
    formation: [6]u8,
    draws: rules.Draws,
};

// This is an in-process checkpoint: content, item rules and draw tape remain borrowed.
// It is not a disk format; a persistent save must encode identities and value fields.
pub const Checkpoint = struct {
    version: u32 = 1,
    entry: Entry,
    state: battle.State,
    members: [6]battle.Member,
    member_count: usize,
    draws: rules.Draws,
};

// Hash the validated semantic content and item rules, including derived views.
pub fn fingerprint(state: battle.State) ![64]u8 {
    const bytes = if (state.spell_scenes) |packet| try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .content = state.content, .rules = state.rules, .spell_scene_hash = try packet.digest() }, .{}) else try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .content = state.content, .rules = state.rules }, .{});
    defer std.heap.page_allocator.free(bytes);
    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes);
    if (state.unite_actors) |bundle| {
        hash.update("unite-actors/1");
        const actor_hash = try bundle.digest();
        hash.update(&actor_hash);
    }
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn sameDraws(a: rules.Draws, b: rules.Draws) bool {
    return a.cursor == b.cursor and a.bios_state == b.bios_state and std.meta.eql(a.prng, b.prng) and
        a.values.ptr == b.values.ptr and a.values.len == b.values.len;
}

pub const Session = struct {
    entry: Entry,
    state: battle.State,
    draws: rules.Draws,
    finished: bool = false,
    /// The immutable packets attached to this session.  A restored
    /// checkpoint rebinds to this host instead of the captured pointer.
    integration: ?*const battle_host.Host = null,

    // scratch belongs to the caller for the lifetime of the session. The source
    // state and its party are never modified by admission or subsequent ticks.
    pub fn begin(entry: Entry, source: battle.State, scratch: []battle.Member, draws: rules.Draws) !Session {
        if (entry.id.len == 0 or entry.receipt.len == 0 or entry.content_id.len == 0 or entry.encounter_id.len == 0) return error.InvalidCombatIdentity;
        if (source.replay_draws != null or !draws.valid() or source.partyCount() == 0 or source.partyCount() > 6 or scratch.len != source.partyCount()) return error.InvalidCombatEntry;
        try source.content.validate();
        try source.rules.validate();
        try source.progress.validate();
        const actual_fingerprint = try fingerprint(source);
        if (!std.mem.eql(u8, entry.content_fingerprint, &actual_fingerprint)) return error.CombatContentMismatch;
        if (source.content.systems == null) return error.MissingBattleSystems;
        const src_start = @intFromPtr(source.progress.party.ptr);
        const dst_start = @intFromPtr(scratch.ptr);
        const bytes = scratch.len * @sizeOf(battle.Member);
        if (src_start < dst_start + bytes and dst_start < src_start + bytes) return error.AliasedCombatParty;
        const index = for (source.content.encounters, 0..) |encounter, i| {
            if (std.mem.eql(u8, entry.encounter_id, encounter.id)) break i;
        } else return error.UnknownEncounter;
        for (0..source.partyCount()) |i| try source.validateOwnedMember(source.ownedMember(i));
        @memcpy(scratch, source.progress.party);
        var state = source;
        state.progress.party = scratch;
        state.encounter = index;
        state.escape_allowed = state.content.encounters[index].escape_allowed;
        state.reward_drop = false;
        state.quit_requested = false;
        state.action_ticks = 0;
        state.yes = true;
        state.item_slot = 0;
        state.spell_slot = 0;
        state.startEncounter();
        return .{ .entry = entry, .state = state, .draws = draws, .integration = if (state.integration) |value| value.host else null };
    }

    pub fn tick(self: *Session, input: battle.Input, draws: *rules.Draws) !void {
        if (self.finished) return error.CombatAlreadyFinished;
        if (!sameDraws(self.draws, draws.*)) return error.RandomStreamMismatch;
        if (input.restart or self.state.phase == .complete or self.state.phase == .confirm_quit) return error.UnsupportedCombatControl;
        if (self.state.phase == .defeat or self.state.phase == .escaped or (self.state.phase == .victory and self.state.rewardReady())) return error.CombatAwaitingResult;
        if (self.state.phase == .battle_menu and input.cancel) return;
        // Previously the resolved-action loop could not apply spell/rune/
        // Unite commands.  An attached integration host owns those bridges, so
        // the guard now applies only to a session without one.
        if (self.integration == null and self.state.phase == .resolving) for (self.state.actions) |maybe_action| {
            if (maybe_action) |action| switch (action) {
                .spell, .rune_attack, .unite => return error.MagicBridgeUnavailable,
                else => {},
            };
        };
        try self.state.tickReplay(input, draws);
        self.draws = draws.*;
    }

    // Return only after the existing engine completes reward and full-bag choices.
    pub fn result(self: *const Session, draws: rules.Draws) !Result {
        if (self.finished) return error.CombatAlreadyFinished;
        if (!draws.valid()) return error.InvalidRandomCursor;
        const current_fingerprint = try fingerprint(self.state);
        if (!std.mem.eql(u8, self.entry.content_fingerprint, &current_fingerprint)) return error.CombatContentMismatch;
        if (!sameDraws(self.draws, draws)) return error.RandomStreamMismatch;
        const outcome: Outcome = switch (self.state.phase) {
            .defeat => .defeat,
            .escaped => if (self.state.bribed_enemies) .bribed else if (self.state.released_enemies) .released else .fled,
            .victory => if (self.state.rewardReady()) .victory else return error.CombatNotSettled,
            else => return error.CombatNotSettled,
        };
        var result_members: [6]battle.OwnedMember = @splat(self.state.ownedMember(0));
        for (0..self.state.partyCount()) |i| result_members[i] = self.state.ownedMember(i);
        return .{ .entry = self.entry, .outcome = outcome, .money = self.state.progress.money, .members = result_members, .member_count = self.state.partyCount(), .formation = self.state.formation, .draws = draws };
    }

    // Call only after the host has durably committed the result and receipt.
    pub fn acknowledge(self: *Session, draws: rules.Draws) !void {
        _ = try self.result(draws);
        self.finished = true;
    }

    pub fn capture(self: Session, draws: rules.Draws) !Checkpoint {
        if (self.finished or self.state.replay_draws != null or !draws.valid() or !sameDraws(self.draws, draws)) return error.InvalidCombatCheckpoint;
        var members: [6]battle.Member = undefined;
        @memcpy(members[0..self.state.partyCount()], self.state.progress.party);
        return .{ .entry = self.entry, .state = self.state, .members = members, .member_count = self.state.partyCount(), .draws = draws };
    }

    pub fn restore(self: *Session, checkpoint: Checkpoint, draws: *rules.Draws) !void {
        if (!sameDraws(self.draws, draws.*)) return error.RandomStreamMismatch;
        const current_fingerprint = try fingerprint(self.state);
        if (!std.mem.eql(u8, self.entry.content_fingerprint, &current_fingerprint)) return error.CombatContentMismatch;
        if (checkpoint.version != 1 or self.finished or checkpoint.member_count != self.state.partyCount() or checkpoint.member_count > 6 or checkpoint.state.replay_draws != null) return error.InvalidCombatCheckpoint;
        if (!std.mem.eql(u8, self.entry.id, checkpoint.entry.id) or !std.mem.eql(u8, self.entry.receipt, checkpoint.entry.receipt) or !std.mem.eql(u8, self.entry.content_id, checkpoint.entry.content_id) or !std.mem.eql(u8, self.entry.encounter_id, checkpoint.entry.encounter_id) or !std.mem.eql(u8, self.entry.content_fingerprint, checkpoint.entry.content_fingerprint)) return error.CombatIdentityMismatch;
        const restored_draws = try draws.restorePosition(checkpoint.draws.cursor, checkpoint.draws.bios_state, checkpoint.draws.prng);
        if (checkpoint.state.encounter >= self.state.content.encounters.len or !std.mem.eql(u8, self.state.content.encounters[checkpoint.state.encounter].id, self.entry.encounter_id)) return error.CombatIdentityMismatch;
        // Validate all members before mutating the live session.
        for (0..checkpoint.member_count) |i| {
            const owned: battle.OwnedMember = .{ .member = checkpoint.members[i], .level = checkpoint.state.levels[i], .experience = checkpoint.state.experience[i], .stats = checkpoint.state.base_stats[i], .weapon_level = checkpoint.state.weapon_levels[i], .loadout = checkpoint.state.loadouts[i], .rune = checkpoint.state.runes[i] };
            try self.state.validateOwnedMember(owned);
        }
        var playback = checkpoint.state.unite_vm;
        if (self.state.unite_actors) |bundle| try playback.rebind(bundle);
        const party = self.state.progress.party;
        const content = self.state.content;
        const spell_scenes = self.state.spell_scenes;
        const unite_actors = self.state.unite_actors;
        const item_rules = self.state.rules;
        self.state = checkpoint.state;
        self.state.spell_scenes = spell_scenes;
        self.state.unite_actors = unite_actors;
        self.state.unite_vm = playback;
        self.state.content = content;
        self.state.rules = item_rules;
        self.state.progress.party = party;
        self.state.integration = if (self.integration) |host| .{ .host = host } else null;
        @memcpy(party, checkpoint.members[0..checkpoint.member_count]);
        draws.* = restored_draws;
        self.draws = restored_draws;
    }
};
