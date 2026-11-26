//! Roster operations for the journey state: reserves, party snapshot and joins.
const std = @import("std");
const State = @import("journey.zig").State;
const StoryState = @import("field").game_state.event_runtime.StoryState;
const battle = @import("battle");
const party_session = @import("party_session");
const game_state = @import("field").game_state;
const Reserves = @import("journey.zig").Reserves;
const Party = battle.Party;

pub fn recruitFlags(story: StoryState) [108]u8 {
    var flags = story.recruit_flags;
    // The duel result is persisted even in saves that leave Pahn marked recruited.
    if (story.scenario[34] & 2 != 0) flags[6] = (flags[6] & ~@as(u8, 1)) | 0x42;
    return flags;
}

pub fn recordPahnDuel(story: *StoryState, outcome: u8) void {
    story.scenario[34] |= outcome;
    if (outcome == 2) story.recruit_flags = recruitFlags(story.*);
}

fn emptyExtra(extra: party_session.CharacterExtra) bool {
    if (extra.member_id.len != 0 or extra.weapon_element != .none) return false;
    for (extra.weapon_fragments) |count| if (count != 0) return false;
    for (extra.locked_equipment) |locked| if (locked) return false;
    return true;
}

pub fn extraMatches(extra: party_session.CharacterExtra, member_id: []const u8) bool {
    return if (extra.member_id.len == 0) emptyExtra(extra) else std.mem.eql(u8, extra.member_id, member_id);
}

pub fn validate(
    rules: game_state.CharacterRules,
    progress: game_state.Progress,
    formation: [6]u8,
    extras: [6]party_session.CharacterExtra,
    reserves: *const Reserves,
    reserve_extras: [72]?party_session.CharacterExtra,
    require_reserve_extras: bool,
) !void {
    const active = progress.party.items();
    if (active.len == 0 or active.len > extras.len) return error.InvalidParty;
    if (progress.money > game_state.max_money) return error.InvalidMoney;
    for (active, extras[0..active.len]) |member, extra| {
        if (!extraMatches(extra, member.id)) return error.InvalidExtras;
    }
    for (extras[active.len..]) |extra| if (!emptyExtra(extra)) return error.InvalidExtras;
    try progress.validate();
    var seen: [6]bool = @splat(false);
    for (formation, 0..) |member, slot| {
        if (member >= seen.len or seen[member] or (slot < active.len and member >= active.len)) return error.InvalidFormation;
        seen[member] = true;
    }
    for (active) |member| try rules.validate(member.*);

    var has_maas = false;
    for (active) |member| has_maas = has_maas or std.mem.eql(u8, member.id, "maas");
    for (reserves) |entry| if (entry) |member| {
        has_maas = has_maas or std.mem.eql(u8, member.id, "maas");
    };
    if (progress.story.maas_recruited and !progress.story.maas_recruitment_blocked and !has_maas) return error.MissingRecruitedMember;

    var ended = false;
    for (reserves, 0..) |entry, index| {
        if (entry) |member| {
            if (ended) return error.InvalidReserves;
            try rules.validate(member);
            for (active) |other| if (std.mem.eql(u8, member.id, other.id)) return error.DuplicateMember;
            for (reserves[0..index]) |other| if (std.mem.eql(u8, member.id, other.?.id)) return error.DuplicateMember;
        } else ended = true;
    }
    for (reserves, reserve_extras) |entry, extra| {
        if (extra) |value| {
            const member = entry orelse return error.InvalidExtras;
            if (!extraMatches(value, member.id)) return error.InvalidExtras;
        } else if (entry != null and require_reserve_extras) return error.InvalidExtras;
    }
}

fn validateChange(state: *const State) !void {
    if (state.menu.phase != .closed or state.field_state.action_pending) return error.GameBusy;
    try state.requireIdleField();
    _ = try state.bindSharedItems(state.shared_items);
    var extras: [6]party_session.CharacterExtra = @splat(.{ .member_id = "" });
    for (extras[0..state.combat.partyCount()], 0..) |*extra, index| extra.* = state.activeExtra(index);
    var reserves: Reserves = @splat(null);
    var reserve_extras: [72]?party_session.CharacterExtra = @splat(null);
    for (state.reserve_slots[0..state.reserveCount()], 0..) |slot, index| {
        reserves[index] = state.combat.progress.party.backing()[slot.?];
        reserve_extras[index] = state.roster_extras[slot.?];
    }
    try validate(state.combat.content.characterRules(), state.combat.progress, state.combat.formationOrder(), extras, &reserves, reserve_extras, true);
}

pub fn putMember(state: *State, slot: Party.Slot, owned: battle.OwnedMember, extra: party_session.CharacterExtra) void {
    const profile = state.combat.content.partyProfile(owned.id).?;
    const member = &state.combat.progress.party.backing()[slot];
    member.* = owned;
    member.id = profile.id;
    member.name = profile.name;
    member.weapon_augment = party_session.weaponAugment(extra);
    state.roster_extras[slot] = extra;
    if (extra.member_id.len != 0) state.roster_extras[slot].member_id = profile.id;
}

pub fn retainReserve(state: *State, owned: battle.OwnedMember) !void {
    try validateChange(state);
    try state.combat.validateOwnedMember(owned);
    const party = &state.combat.progress.party;
    const count = state.reserveCount();
    const owned_count = party.len + count;
    for (party.backing()[0..owned_count]) |member| {
        if (std.mem.eql(u8, member.id, owned.id)) return error.DuplicateMember;
    }
    if (count == state.reserve_slots.len) return error.RosterFull;
    const slot: Party.Slot = @intCast(owned_count);
    putMember(state, slot, owned, .{ .member_id = "" });
    state.reserve_slots[count] = slot;
}

pub fn swapReserve(state: *State, member_id: []const u8, reserve_id: []const u8) !void {
    try validateChange(state);
    const combat = state.combat;
    const party = &combat.progress.party;
    const active = for (party.items(), 0..) |member, index| {
        if (std.mem.eql(u8, member.id, member_id)) break index;
    } else return error.InvalidMember;
    for (state.reserve_slots[0..state.reserveCount()]) |*entry| {
        const slot = entry.*.?;
        if (!std.mem.eql(u8, party.backing()[slot].id, reserve_id)) continue;
        const outgoing = party.slot(active);
        party.select(active, slot);
        combat.formation.replace(outgoing, slot);
        entry.* = outgoing;
        return;
    }
    return error.UnknownReserve;
}

pub fn buildPartySnapshot(state: *const State) party_session.Snapshot {
    var snapshot: party_session.Snapshot = .{ .entry_id = "journey", .content_id = "journey", .receipt = "journey", .baseline_revision = 0 };
    for (0..state.combat.progress.party.len) |i| {
        const owned = state.combat.ownedMember(i);
        snapshot.members[i] = owned;
        snapshot.extras[i] = if (state.activeExtra(i).member_id.len == 0) .{ .member_id = owned.id } else state.activeExtra(i);
        snapshot.eligible[i] = true;
        snapshot.active[i] = owned.id;
    }
    var index = state.combat.progress.party.len;
    for (state.reserve_slots[0..state.reserveCount()]) |slot| {
        const owned = state.combat.progress.party.backing()[slot.?];
        const extra = state.roster_extras[slot.?];
        snapshot.members[index] = owned;
        snapshot.extras[index] = if (extra.member_id.len != 0) extra else .{ .member_id = owned.id };
        index += 1;
    }
    snapshot.storage = state.combat.progress.storage;
    snapshot.shared = state.shared_items;
    return snapshot;
}

pub fn useWeaponPiece(state: *State, owner: usize, slot: usize, target: usize, replace: bool) !void {
    if (owner >= state.combat.partyCount() or target >= state.combat.partyCount()) return error.InvalidMember;
    const combat = state.combat;
    const rules = combat.content.characterRules();
    const source = combat.progress.party.at(owner);
    const recipient = combat.progress.party.at(target);
    try rules.validate(source.*);
    if (!extraMatches(state.activeExtra(owner), source.id) or !extraMatches(state.activeExtra(target), recipient.id)) return error.InvalidExtras;
    if (owner != target) try rules.validate(recipient.*);
    const extra = &state.roster_extras[combat.progress.party.slot(target)];
    var next = extra.*;
    if (next.member_id.len == 0) next.member_id = recipient.id;
    try party_session.attachWeaponPiece(rules, source, slot, &next, replace);
    extra.* = next;
    recipient.weapon_augment = party_session.weaponAugment(next);
}

pub const Growth = struct {
    owned: battle.OwnedMember,
    active: ?usize,
    reserve: ?usize,
    extra: party_session.CharacterExtra,
    random: std.Random.DefaultPrng,
};

pub fn prepareGrowth(state: *const State, id: []const u8, advances: u8) !Growth {
    if (advances == 0 or advances > 99 or state.combat.content.systems == null or state.combat.replay_draws != null) return error.InvalidCharacterGrowth;
    var active: ?usize = null;
    var reserve: ?usize = null;
    var extra: party_session.CharacterExtra = .{ .member_id = "" };
    const owned = for (state.combat.progress.party.items(), 0..) |member, index| {
        if (std.mem.eql(u8, member.id, id)) {
            active = index;
            break state.combat.ownedMember(index);
        }
    } else reserve_member: {
        for (state.reserve_slots[0..state.reserveCount()], 0..) |slot, index| {
            const member = state.combat.progress.party.backing()[slot.?];
            if (std.mem.eql(u8, member.id, id)) {
                reserve = index;
                extra = state.roster_extras[slot.?];
                break :reserve_member member;
            }
        }
        const count = state.reserveCount();
        if (count == state.reserve_slots.len) return error.RosterFull;
        reserve = count;
        const catalog = state.party_catalog orelse return error.MissingPartyCatalogue;
        const materialized = try party_session.catalogue.materializeBound(state.combat.content.characterRules(), catalog, id, state.party_bindings);
        extra = materialized.extra;
        break :reserve_member materialized.owned;
    };
    try state.combat.validateOwnedMember(owned);
    const rules = state.combat.content.systems.?;
    const profile = state.combat.content.partyProfile(owned.id).?;
    var result = owned;
    result.id = profile.id;
    result.name = profile.name;
    var random = state.combat.random;
    for (0..@min(advances, 99 - owned.level)) |_| {
        var rolls: [7]u15 = undefined;
        for (&rolls) |*roll| roll.* = random.random().int(u15);
        result.levelUp(rules, profile.growth, rolls);
    }
    result.refillRuneCharges(rules);
    std.debug.assert(result.level == @min(@as(u16, 99), @as(u16, owned.level) + advances));
    try state.combat.validateOwnedMember(result);
    return .{ .owned = result, .active = active, .reserve = reserve, .extra = extra, .random = random };
}

pub fn commitGrowth(state: *State, growth: Growth) void {
    if (growth.active) |index| {
        state.combat.setOwnedMember(index, growth.owned);
    } else {
        const reserve = growth.reserve.?;
        const slot = state.reserve_slots[reserve] orelse @as(Party.Slot, @intCast(state.combat.partyCount() + reserve));
        putMember(state, slot, growth.owned, growth.extra);
        state.reserve_slots[reserve] = slot;
    }
    state.combat.random = growth.random;
}

pub const PartyJoin = struct {
    slot: Party.Slot,
    origin: union(enum) { reserve: usize, recruit: party_session.catalogue.Materialized },
};

pub fn preparePartyJoin(state: *const State, backing: []battle.Member, catalog: party_session.catalogue.Catalogue, bindings: ?party_session.catalogue.OwnershipBindings, id: []const u8) !PartyJoin {
    const party = &state.combat.progress.party;
    if (party.len >= Party.capacity) return error.PartyFull;
    if (backing.ptr != party.backing().ptr or backing.len != Party.roster_capacity) return error.InvalidParty;
    for (party.items()) |member| if (std.mem.eql(u8, member.id, id)) return error.DuplicateMember;
    const count = state.reserveCount();
    for (state.reserve_slots[0..count], 0..) |entry, index| {
        const slot = entry.?;
        if (std.mem.eql(u8, party.backing()[slot].id, id)) return .{ .slot = slot, .origin = .{ .reserve = index } };
    }
    return .{
        .slot = @intCast(party.len + count),
        .origin = .{ .recruit = try party_session.catalogue.materializeBound(state.combat.content.characterRules(), catalog, id, bindings) },
    };
}

pub fn commitPartyJoin(state: *State, _: []battle.Member, join: PartyJoin) void {
    const party = &state.combat.progress.party;
    switch (join.origin) {
        .recruit => |record| putMember(state, join.slot, record.owned, record.extra),
        .reserve => |index| {
            const count = state.reserveCount();
            std.mem.copyForwards(?Party.Slot, state.reserve_slots[index .. count - 1], state.reserve_slots[index + 1 .. count]);
            state.reserve_slots[count - 1] = null;
        },
    }
    state.combat.formation.append(party.len, join.slot);
    party.select(party.len, join.slot);
    state.updateOpeningPartyMilestone();
}

pub const PartyLeave = struct { member: usize, reserve: usize };

pub const PartyDismiss = struct { keep: usize, count: u3 = 0, leaves: [5]PartyLeave = undefined };

pub fn preparePartyDismiss(state: *const State) !PartyDismiss {
    const members = state.combat.progress.party.items();
    if (members.len == 0 or members.len > 6) return error.InvalidParty;
    const keep = for (members, 0..) |member, index| {
        if (std.mem.eql(u8, member.id, "hero")) break index;
    } else members.len - 1;
    var plan: PartyDismiss = .{ .keep = keep };
    var next_reserve: usize = 0;
    for (members, 0..) |_, index| {
        try state.combat.validateOwnedMember(state.combat.ownedMember(index));
        if (index == keep) continue;
        const reserve = for (state.reserve_slots[next_reserve..], next_reserve..) |entry, slot| {
            if (entry == null) break slot;
        } else return error.RosterFull;
        plan.leaves[plan.count] = .{ .member = index - plan.count, .reserve = reserve };
        plan.count += 1;
        next_reserve = reserve + 1;
    }
    std.debug.assert(@as(usize, plan.count) + 1 == members.len);
    return plan;
}

pub fn commitPartyDismiss(state: *State, plan: PartyDismiss) void {
    const kept = state.combat.progress.party.at(plan.keep).id;
    for (plan.leaves[0..plan.count]) |leave| commitPartyLeave(state, leave);
    std.debug.assert(state.combat.partyCount() == 1);
    std.debug.assert(std.mem.eql(u8, state.combat.progress.party.at(0).id, kept));
}

pub fn preparePartyLeave(state: *const State, id: []const u8) !PartyLeave {
    const party = state.combat.progress.party.items();
    if (party.len <= 1) return error.LastPartyMember;
    const member = for (party, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id, id)) break index;
    } else return error.InvalidMember;
    const reserve = for (state.reserve_slots, 0..) |entry, index| {
        if (entry == null) break index;
    } else return error.RosterFull;
    return .{ .member = member, .reserve = reserve };
}

pub fn commitPartyLeave(state: *State, leave: PartyLeave) void {
    const combat = state.combat;
    const party = &combat.progress.party;
    const slot = party.slot(leave.member);
    state.reserve_slots[leave.reserve] = slot;
    combat.formation.remove(party.len, slot);
    party.remove(leave.member);
}

pub fn joinPartyMember(state: *State, backing: []battle.Member, catalog: party_session.catalogue.Catalogue, bindings: ?party_session.catalogue.OwnershipBindings, id: []const u8) !void {
    const member = try preparePartyJoin(state, backing, catalog, bindings, id);
    commitPartyJoin(state, backing, member);
}

pub fn joinOnRoomEntry(state: *State, backing: []battle.Member, catalog: party_session.catalogue.Catalogue, bindings: ?party_session.catalogue.OwnershipBindings, room_id: []const u8) !void {
    if (state.route.stage == .world or state.packagedOpeningRoute() != null) return;
    if (std.mem.eql(u8, room_id, "va1_room_1")) {
        if (state.room_battles) |rooms| if (rooms.ownsPartyJoin("cleo")) return;
        for (state.combat.progress.party.items()) |member| if (std.mem.eql(u8, member.id, "cleo")) return;
        try joinPartyMember(state, backing, catalog, bindings, "cleo");
    }
    if (std.mem.eql(u8, room_id, "va1_room_2")) {
        if (state.room_battles) |rooms| if (rooms.ownsPartyJoin("ted")) return;
        for (state.combat.progress.party.items()) |member| if (std.mem.eql(u8, member.id, "ted")) return;
        try joinPartyMember(state, backing, catalog, bindings, "ted");
    }
}
