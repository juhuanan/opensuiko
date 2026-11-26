//! Field callback ownership for headquarters party selection.
const State = @import("journey.zig").State;
const field = @import("field");
const std = @import("std");
const battle = @import("battle");
const events = @import("field_events");
const party = @import("party_session");
const roster = @import("journey_roster.zig");
pub const selector = party.selector;
pub const Active = struct { receipt: events.Receipt, menu: selector.Selector = .{}, windows: selector.Windows = .{} };

pub fn advanceFrame(state: *State, input: ?selector.Sampler.Sample) !void {
    if (input) |sample| try tick(state, sample.forPhase(state.party_selection.?.menu.phase));
    state.elapsed_ticks +|= 1;
}

pub fn takeWindowOpenCues(state: *State) u8 {
    const active = if (state.party_selection) |*value| value else return 0;
    var count: u8 = 0;
    while (active.windows.takeOpenCue()) count += 1;
    return count;
}

pub fn inspect(state: *const State, id: []const u8) !selector.Details {
    for (state.combat.progress.party.items(), 0..) |member, index| if (std.mem.eql(u8, member.id, id)) {
        return selector.Details.derive(state.combat.content.characterRules(), state.combat.ownedMember(index), state.activeExtra(index));
    };
    for (state.reserve_slots[0..state.reserveCount()]) |slot| {
        const owned = state.combat.progress.party.backing()[slot.?];
        const extra = state.roster_extras[slot.?];
        if (std.mem.eql(u8, owned.id, id)) return selector.Details.derive(state.combat.content.characterRules(), owned, extra);
    }
    const catalogue = state.party_catalog orelse return error.MissingPartyCatalogue;
    const seed = try party.catalogue.materializeBound(state.combat.content.characterRules(), catalogue, id, state.party_bindings);
    return selector.Details.derive(state.combat.content.characterRules(), seed.owned, seed.extra);
}

pub const View = struct {
    characters: [78]selector.Candidate = undefined,
    active: [6][]const u8 = undefined,
    forced: [6][]const u8 = undefined,
    active_count: usize = 0,
    forced_count: usize = 0,

    pub fn read(self: *View, state: *const State) !selector.Roster {
        const catalog = state.party_catalog orelse return error.MissingPartyCatalogue;
        const story = state.combat.progress.story.scenario orelse return error.MissingSourceStoryState;
        const owner = state.field_event orelse return error.MissingFieldPartySelectRequest;
        if (catalog.characters.len != self.characters.len) return error.InvalidCatalogue;
        const recruit_flags = roster.recruitFlags(story);
        for (catalog.characters, &self.characters) |character, *candidate| {
            const id = character.source_character_id;
            const flags: u8 = if (id < recruit_flags.len) recruit_flags[id] else 0;
            candidate.* = .{ .id = character.id, .recruited = flags & 3 == 1, .blocked = flags & 4 != 0, .guest = id == 108 or id == 109 };
        }
        self.active_count = state.combat.partyCount();
        if (self.active_count == 0 or self.active_count > 6 or self.active_count != owner.binding.party.len) return error.FieldEventPartyMismatch;
        self.forced_count = 0;
        const host = (state.combat.integration orelse return error.MissingBattleIntegration).host;
        const auxiliary = state.field_state.auxiliary_party orelse return error.MissingAuxiliaryPartyState;
        const required = if (owner.session.pendingPartySelectCommand()) |command| command.required_party orelse &.{} else &.{};
        for (state.combat.progress.party.items(), 0..) |member, index| {
            self.active[index] = member.id;
            const source_id = host.characterId(member.id) orelse return error.UnknownFieldEventPartyMember;
            if (source_id != owner.binding.party[index]) return error.FieldEventPartyMismatch;
            if (std.mem.indexOfScalar(u8, &auxiliary, source_id) != null or std.mem.indexOfScalar(u8, required, source_id) != null) {
                self.forced[self.forced_count] = member.id;
                self.forced_count += 1;
            }
        }
        const result: selector.Roster = .{
            .characters = &self.characters,
            .active = self.active[0..self.active_count],
            .forced = self.forced[0..self.forced_count],
            .reserve_slot = owner.session.partySelectReservesSlot(),
        };
        try result.validate();
        return result;
    }
};

fn validateOwner(state: *const State) !Active {
    const active = state.party_selection orelse return error.MissingFieldPartySelectRequest;
    const owner = state.field_event orelse return error.MissingFieldPartySelectRequest;
    if (state.mode != .field or state.menu.phase != .closed or state.dice_game != null or state.auto_travel != null or
        !std.mem.eql(u8, owner.binding.room, state.package.rooms[state.field_state.room].id) or
        owner.session.hero.x != state.field_state.x or owner.session.hero.y != state.field_state.y) return error.InvalidFieldPartySelectOwner;
    const pending = owner.session.queuedPartySelect() orelse return error.InvalidFieldPartySelectReceipt;
    if (!events.semanticEqual(pending, active.receipt)) return error.InvalidFieldPartySelectReceipt;
    try owner.session.validate(owner.binding.*);
    var view: View = .{};
    _ = try view.read(state);
    return active;
}

pub fn begin(state: *State) !void {
    if (state.mode != .field or state.menu.phase != .closed or state.party_selection != null or
        state.dice_game != null or state.auto_travel != null) return error.GameBusy;
    const owner = state.field_event orelse return error.MissingFieldPartySelectRequest;
    const receipt = owner.session.queuedPartySelect() orelse return error.MissingFieldPartySelectRequest;
    const request = owner.session.pendingPartySelectCommand().?;
    if (request.index != null and (owner.binding.party.len < 6 or !owner.session.partySelectReservesSlot())) {
        return resumeSelection(state, receipt);
    }
    var view: View = .{};
    const facts = try view.read(state);
    try owner.session.validate(owner.binding.*);
    state.party_selection = .{
        .receipt = receipt,
        .menu = if (facts.reserve_slot and facts.active.len == 6) .{ .phase = .list_setup, .action = .eject } else .{},
    };
    errdefer state.party_selection = null;
    _ = try validateOwner(state);
}

fn resumeSelection(state: *State, receipt: events.Receipt) !void {
    const owner = state.field_event.?;
    var members: [6]battle.Member = undefined;
    var draft: field.game_state.Progress = undefined;
    var next_field = state.stageField(&draft, &members);
    try owner.session.resumePartySelect(owner.binding.*, &next_field, receipt);
    state.commitFieldTransaction(next_field);
    state.party_selection = null;
}

fn commit(state: *State, active: *Active) !void {
    const request = active.menu.pending orelse return error.MissingSelectorRequest;
    const owner = state.field_event.?;
    const rooms = state.room_battles orelse return error.MissingFieldPartySelectOwner;
    if (owner.session != &rooms.session or owner.binding != &rooms.active_binding) return error.InvalidFieldPartySelectOwner;
    var view: View = .{};
    var facts = try view.read(state);
    for (request.before, 0..) |maybe, index| {
        if (index < facts.active.len) {
            if (maybe == null or !std.mem.eql(u8, maybe.?, facts.active[index])) return error.StaleSelectorRoster;
        } else if (maybe != null) return error.StaleSelectorRoster;
    }
    var choices: [78][]const u8 = undefined;
    const candidates = active.menu.list(facts, &choices);
    for (candidates) |id| {
        if (std.mem.eql(u8, id, request.character)) break;
    } else return error.StaleSelectorRoster;
    if (request.action == .eject) for (facts.forced) |id| {
        if (std.mem.eql(u8, id, request.character)) return error.ForcedMember;
    };
    const backing = state.party_backing orelse return error.MissingPartyBacking;
    const catalog = state.party_catalog orelse return error.MissingPartyCatalogue;
    const Plan = union(enum) { admit: roster.PartyJoin, eject: roster.PartyLeave };
    const plan: Plan = switch (request.action) {
        .admit => .{ .admit = try roster.preparePartyJoin(state, backing, catalog, state.party_bindings, request.character) },
        .eject => .{ .eject = try roster.preparePartyLeave(state, request.character) },
        .no_change => return error.InvalidSelectorRequest,
    };
    var ids: [6][]const u8 = undefined;
    var count: usize = 0;
    for (facts.active, 0..) |id, index| {
        if (plan == .eject and index == plan.eject.member) continue;
        ids[count] = id;
        count += 1;
    }
    if (plan == .admit) {
        ids[count] = request.character;
        count += 1;
    }
    facts.active = ids[0..count];
    var next_menu = active.menu;
    try next_menu.acknowledge(facts);
    const host = state.combat.integration.?.host;
    var source_ids: [6]u8 = @splat(255);
    for (facts.active, source_ids[0..count]) |id, *source_id| source_id.* = host.characterId(id) orelse return error.UnknownFieldEventPartyMember;
    var story = state.combat.progress.story.scenario.?;
    if (plan == .admit) story.markCharacterLoaded(source_ids[count - 1]);
    try owner.session.validateStory(&story);
    try owner.session.updateSelectorParty(owner.binding.*, active.receipt, source_ids[0..count], state.field_state.auxiliary_party.?);
    // Every fallible preparation precedes changes to the live owned records.
    switch (plan) {
        .admit => |join| roster.commitPartyJoin(state, backing, join),
        .eject => |leave| roster.commitPartyLeave(state, leave),
    }
    rooms.party = source_ids;
    rooms.active_binding.party = rooms.party[0..count];
    if (story.castle_tier != state.combat.progress.story.scenario.?.castle_tier)
        state.combat.progress.story.recruitment_tier = story.castle_tier;
    state.setScenarioStory(story);
    active.menu = next_menu;
}

pub fn tick(state: *State, controls: selector.Controls) !void {
    var active = try validateOwner(state);
    var view: View = .{};
    const facts = try view.read(state);
    if (active.menu.phase == .loading) {
        try commit(state, &active);
        active.windows.afterCommit(active.menu, state.combat.partyCount());
    } else try active.windows.tick(&active.menu, facts, controls);
    if (active.menu.phase == .done) {
        try resumeSelection(state, active.receipt);
    } else state.party_selection = active;
}
