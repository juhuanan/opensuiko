//! Battle entry/return flow for the journey state.
const std = @import("std");
const State = @import("journey.zig").State;
const battle = @import("battle");
const field = @import("field");
const encounter_policy = @import("campaign_policies").encounter;
const party = @import("party_session");
const roster = @import("journey_roster.zig");
const events = field.game_state.event_runtime;

pub const FieldEncounterClock = struct {
    updates: u16 = 0,
    ready: bool = false,
    enabled: bool = true,
};

/// Battle mutates the shared party backing, so retain the encounter's
/// original members separately from the other progress fields.
pub const Checkpoint = struct {
    progress: field.game_state.Progress,
    members: [6]field.game_state.Character,
    formation: field.game_state.Formation,
    random: std.Random.DefaultPrng,
    elapsed_ticks: u64,

    fn capture(state: *const State) Checkpoint {
        const party_members = state.combat.progress.party;
        const members = party_members.values();
        return .{
            .progress = state.combat.progress,
            .members = members,
            .formation = state.combat.formation,
            .random = state.combat.random,
            .elapsed_ticks = state.elapsed_ticks,
        };
    }
};

pub fn encounterIndex(content: battle.Content, id: []const u8) ?usize {
    for (content.encounters, 0..) |encounter, i| if (std.mem.eql(u8, encounter.id, id)) return i;
    return null;
}

pub const FieldEncounters = struct {
    pub const Room = struct {
        room: []const u8,
        rate: u8,
        counter_threshold: u8,
        candidates: []const encounter_policy.Candidate,
    };

    schema: []const u8,
    rooms: []const Room,
    suppress_when: ?events.Condition = null,
    clear_suppression_on_world_entry: bool = false,

    pub fn forRoom(self: FieldEncounters, id: []const u8) ?*const Room {
        for (self.rooms) |*entry| if (std.mem.eql(u8, entry.room, id)) return entry;
        return null;
    }

    pub fn validate(self: FieldEncounters, package: field.Package, content: battle.Content) !void {
        const with_world_reset = std.mem.eql(u8, self.schema, "suikoden-field-movement-encounters/3");
        const with_suppression = with_world_reset or std.mem.eql(u8, self.schema, "suikoden-field-movement-encounters/2");
        if ((!with_suppression and !std.mem.eql(u8, self.schema, "suikoden-field-movement-encounters/1")) or
            self.rooms.len == 0 or self.rooms.len > package.rooms.len) return error.InvalidFieldEncounters;
        if (self.suppress_when) |condition| {
            if (!with_suppression or condition.flag.scenarioIndex() == null) return error.InvalidFieldEncounters;
        }
        if (self.clear_suppression_on_world_entry and (!with_world_reset or self.suppress_when == null or
            self.suppress_when.?.kind != .story_mask_set)) return error.InvalidFieldEncounters;
        for (self.rooms, 0..) |entry, index| {
            if (package.roomIndex(entry.room) == null) return error.UnknownRoom;
            if (entry.rate == 0 or entry.candidates.len == 0 or entry.candidates.len > encounter_policy.max_candidates) return error.InvalidFieldEncounters;
            for (self.rooms[0..index]) |other| if (std.mem.eql(u8, entry.room, other.room)) return error.InvalidFieldEncounters;
            for (entry.candidates) |candidate| {
                const encounter = content.encounters[encounterIndex(content, candidate.id) orelse return error.UnknownEncounter];
                var level_sum: u16 = 0;
                for (encounter.enemies) |enemy| level_sum += content.enemies[content.enemyIndex(enemy) orelse return error.UnknownEnemy].level;
                if (candidate.enemy_level_sum != level_sum) return error.InvalidFieldEncounterLevels;
            }
        }
    }
};

pub fn initialFieldEncounterClock(data: ?FieldEncounters, story: ?events.StoryState) FieldEncounterClock {
    const suppress_when = (data orelse return .{}).suppress_when orelse return .{};
    const current = story orelse events.StoryState{};
    return .{ .enabled = !current.matches(&.{suppress_when}) };
}

pub fn beginReadyFieldEncounter(state: *State) !bool {
    const world = &state.field_state;
    if (!state.field_encounter_clock.ready or state.mode != .field or state.field_event != null or
        state.menu.phase != .closed or state.menu.pending or world.remaining != 0 or
        world.dialogue != null or world.rest_ticks != 0) return false;
    const entry = (state.data.field_encounters orelse return false).forRoom(state.package.rooms[world.room].id) orelse return false;
    var traits: encounter_policy.Party = .{};
    for (0..state.combat.partyCount()) |slot| {
        traits.level_sum += state.combat.progress.party.at(slot).level;
        traits.suppression_rune = traits.suppression_rune or state.combat.hasRune(slot, "champion's");
    }
    const outcome = try encounter_policy.attempt(.{
        .encounters_enabled = state.field_encounter_clock.enabled,
        .travel_counter = state.field_encounter_clock.updates,
        .counter_threshold = entry.counter_threshold,
    }, traits, .{ .source = .{ .rate = entry.rate, .counter_threshold = entry.counter_threshold } }, entry.candidates, .{ .prng = state.combat.random });

    const random = state.combat.random;
    const elapsed = state.elapsed_ticks;
    errdefer {
        state.combat.random = random;
        state.elapsed_ticks = elapsed;
    }
    switch (outcome) {
        .blocked => {},
        .rate_failed => |progress| state.combat.random = progress.draws.prng.?,
        .rejected => |rejection| state.combat.random = rejection.progress.draws.prng.?,
        .selected => |selection| {
            const index = encounterIndex(state.combat.content, selection.candidate.id) orelse return error.UnknownEncounter;
            state.combat.random = selection.progress.draws.prng.?;
            state.elapsed_ticks +|= 1;
            try beginCombat(state, index);
            return true;
        },
    }
    state.field_encounter_clock.ready = false;
    return false;
}

pub fn beginEncounter(state: *State, index: usize) !void {
    if (index >= state.data.encounters.len) return error.GameBusy;
    const encounter = encounterIndex(state.combat.content, state.data.encounters[index].encounter) orelse return error.UnknownEncounter;
    try beginCombat(state, encounter);
    state.encounter_trigger = index;
}

pub fn beginCombat(state: *State, encounter: usize) !void {
    if (state.mode != .field or state.scripted_battle != null or state.menu.phase != .closed or state.field_state.dialogue != null or state.field_state.remaining != 0) return error.GameBusy;
    if (encounter >= state.combat.content.encounters.len) return error.UnknownEncounter;
    try state.requireIdleField();
    const members = state.combat.progress.party.items();
    if (members.len == 0 or members.len > battle.Party.capacity) return error.InvalidParty;
    for (members, 0..) |member, i| {
        const extra = state.activeExtra(i);
        if (!roster.extraMatches(extra, member.id)) return error.InvalidExtras;
    }
    state.checkpoint = .capture(state);
    startCombat(state, encounter);
}

pub fn retryCombat(state: *State) !void {
    const checkpoint = state.checkpoint orelse return error.MissingBattleCheckpoint;
    const encounter = state.combat.encounter;
    checkpoint.progress.party.copyFrom(checkpoint.members[0..checkpoint.progress.party.len]);
    state.combat.progress = checkpoint.progress;
    state.combat.formation = checkpoint.formation;
    state.combat.random = checkpoint.random;
    state.elapsed_ticks = checkpoint.elapsed_ticks;
    startCombat(state, encounter);
}

fn startCombat(state: *State, encounter: usize) void {
    for (0..state.combat.partyCount()) |member| {
        state.combat.progress.party.at(member).weapon_augment = party.weaponAugment(state.activeExtra(member));
    }
    state.combat.encounter = encounter;
    state.combat.startEncounter();
    state.combat.quit_requested = false;
    state.mode = .battle;
    state.field_encounter_clock = .{ .enabled = state.field_encounter_clock.enabled };
    state.field_state.walking = false;
    state.field_state.action_pending = false;
}

pub fn returnFromBattle(state: *State, won: bool) void {
    if (state.encounter_trigger) |index| {
        if (won) {
            state.combat.progress.story.complete(state.data.encounters[index].flag);
            const uses_prototype_battle = if (state.room_battles) |rooms| rooms.opening_battles.len == 0 else true;
            if (uses_prototype_battle and state.route.stage == .dungeon and std.mem.eql(u8, state.package.rooms[state.field_state.room].id, "vaa_room_0")) state.route.noteOpeningBattle(.victory_returned);
        } else {
            state.world_battle_started = false;
            state.world_battle_ticks = 0;
        }
        state.suppressed_trigger = index;
    }
    state.combat.clearSleep();
    state.combat.clearTemporaryStats();
    state.combat.unbalanced = @splat(0);
    state.encounter_trigger = null;
    state.checkpoint = null;
    state.mode = .field;
    state.menu = .{ .preferences = state.menu.preferences, .save_slot = state.menu.save_slot, .region_bgm = state.menu.region_bgm };
    state.bind();
}
