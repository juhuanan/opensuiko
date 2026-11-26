//! Roster operations for the journey state: reserves, party snapshot and joins.
const std = @import("std");
const State = @import("journey.zig").State;
const StoryState = @import("field").game_state.event_runtime.StoryState;
const battle = @import("battle");
const party_session = @import("party_session");
const save = @import("journey_save.zig");

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

pub fn retainReserve(state: *State, owned: battle.OwnedMember) !void {
    if (state.menu.phase != .closed or state.field_state.action_pending) return error.GameBusy;
    const snapshot = try save.Snapshot.capture(state.*);
    try snapshot.validate(state.*);
    try state.combat.validateOwnedMember(owned);
    for (state.combat.progress.party) |member| if (std.mem.eql(u8, member.id, owned.id)) return error.DuplicateMember;
    for (&state.reserves, 0..) |*entry, index| {
        if (entry.*) |other| {
            if (std.mem.eql(u8, other.id, owned.id)) return error.DuplicateMember;
        } else {
            entry.* = owned;
            const profile = state.combat.content.partyProfile(owned.id).?;
            entry.*.?.id = profile.id;
            entry.*.?.name = profile.name;
            state.reserve_extras[index] = .{ .member_id = "" };
            return;
        }
    }
    return error.RosterFull;
}

pub fn swapReserve(state: *State, member_id: []const u8, reserve_id: []const u8) !void {
    if (state.menu.phase != .closed or state.field_state.action_pending) return error.GameBusy;
    const snapshot = try save.Snapshot.capture(state.*);
    try snapshot.validate(state.*);
    for (state.combat.progress.party, 0..) |member, active_index| {
        if (!std.mem.eql(u8, member.id, member_id)) continue;
        for (&state.reserves, 0..) |*entry, index| if (entry.*) |owned| {
            if (!std.mem.eql(u8, owned.id, reserve_id)) continue;
            const leaving = state.combat.ownedMember(active_index);
            const leaving_extra = state.extras[active_index];
            state.combat.setOwnedMember(active_index, owned);
            state.extras[active_index] = state.reserve_extras[index] orelse .{ .member_id = "" };
            if (state.extras[active_index].member_id.len != 0) state.extras[active_index].member_id = state.combat.progress.party[active_index].id;
            state.combat.progress.party[active_index].weapon_augment = party_session.weaponAugment(state.extras[active_index]);
            entry.* = leaving;
            state.reserve_extras[index] = leaving_extra;
            return;
        };
        return error.UnknownReserve;
    }
    return error.InvalidMember;
}

pub fn buildPartySnapshot(state: *const State) party_session.Snapshot {
    var snapshot: party_session.Snapshot = .{ .entry_id = "journey", .content_id = "journey", .receipt = "journey", .baseline_revision = 0 };
    for (0..state.combat.progress.party.len) |i| {
        const owned = state.combat.ownedMember(i);
        snapshot.members[i] = owned;
        snapshot.extras[i] = if (state.extras[i].member_id.len == 0) .{ .member_id = owned.id } else state.extras[i];
        snapshot.eligible[i] = true;
        snapshot.active[i] = owned.id;
    }
    var index = state.combat.progress.party.len;
    for (state.reserves, state.reserve_extras) |maybe, extra| if (maybe) |owned| {
        snapshot.members[index] = owned;
        snapshot.extras[index] = if (extra != null and extra.?.member_id.len != 0) extra.? else .{ .member_id = owned.id };
        index += 1;
    };
    snapshot.storage = state.combat.progress.storage;
    snapshot.shared = state.shared_items;
    return snapshot;
}

pub fn useWeaponPiece(state: *State, owner: usize, slot: usize, target: usize, replace: bool) !void {
    if (owner >= state.combat.partyCount() or target >= state.combat.partyCount()) return error.InvalidMember;
    var session = try party_session.Session.init(state.combat.*, buildPartySnapshot(state), .{});
    try session.execute(.{ .weapon_piece = .{
        .owner = state.combat.progress.party[owner].id,
        .slot = slot,
        .target = state.combat.progress.party[target].id,
        .replace = replace,
    } });
    state.combat.progress.party[owner].inventory = session.current.members[owner].?.inventory;
    state.extras[target] = session.current.extras[target].?;
    state.combat.progress.party[target].weapon_augment = party_session.weaponAugment(state.extras[target]);
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
    const owned = for (state.combat.progress.party, 0..) |member, index| {
        if (std.mem.eql(u8, member.id, id)) {
            active = index;
            break state.combat.ownedMember(index);
        }
    } else reserve_member: {
        for (state.reserves, 0..) |entry, index| if (entry) |member| {
            if (std.mem.eql(u8, member.id, id)) {
                reserve = index;
                extra = state.reserve_extras[index] orelse extra;
                break :reserve_member member;
            }
        };
        reserve = for (state.reserves, 0..) |entry, index| {
            if (entry == null) break index;
        } else return error.RosterFull;
        const catalog = state.party_catalog orelse return error.MissingPartyCatalogue;
        const materialized = try party_session.catalogue.materializeBound(state.combat.*, catalog, id, state.party_bindings);
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
        state.reserves[growth.reserve.?] = growth.owned;
        state.reserve_extras[growth.reserve.?] = growth.extra;
    }
    state.combat.random = growth.random;
}

pub const PartyJoin = struct { member: party_session.catalogue.Materialized, reserve: ?usize = null };

pub fn preparePartyJoin(state: *const State, backing: []battle.Member, catalog: party_session.catalogue.Catalogue, bindings: ?party_session.catalogue.OwnershipBindings, id: []const u8) !PartyJoin {
    const count = state.combat.progress.party.len;
    if (count >= 6) return error.PartyFull;
    if (backing.len < count + 1) return error.InvalidParty;
    for (state.combat.progress.party) |member| if (std.mem.eql(u8, member.id, id)) return error.DuplicateMember;
    for (state.reserves, state.reserve_extras, 0..) |maybe, extra, index| if (maybe) |owned| {
        if (std.mem.eql(u8, owned.id, id)) return .{ .member = .{ .owned = owned, .extra = extra orelse .{ .member_id = "" } }, .reserve = index };
    } else break;
    return .{ .member = try party_session.catalogue.materializeBound(state.combat.*, catalog, id, bindings) };
}

pub fn commitPartyJoin(state: *State, backing: []battle.Member, join: PartyJoin) void {
    const materialized = join.member;
    const count = state.combat.progress.party.len;
    var active: [6]battle.Member = undefined;
    @memcpy(active[0..count], state.combat.progress.party);
    @memcpy(backing[0..count], active[0..count]);
    backing[count] = materialized.owned;
    state.party_backing = backing;
    state.replacePartySlice(backing[0 .. count + 1]);
    state.combat.setOwnedMember(count, materialized.owned);
    std.mem.swap(u8, &state.combat.formation[count], &state.combat.formation[state.combat.formationSlot(count)]);
    state.extras[count] = materialized.extra;
    state.combat.progress.party[count].weapon_augment = party_session.weaponAugment(materialized.extra);
    if (join.reserve) |index| {
        const last = state.reserves.len - 1;
        std.mem.copyForwards(?battle.OwnedMember, state.reserves[index..last], state.reserves[index + 1 ..]);
        std.mem.copyForwards(?party_session.CharacterExtra, state.reserve_extras[index..last], state.reserve_extras[index + 1 ..]);
        state.reserves[last] = null;
        state.reserve_extras[last] = null;
    }
    state.updateOpeningPartyMilestone();
}

pub const PartyLeave = struct { member: usize, reserve: usize };

pub const PartyDismiss = struct { keep: usize, count: u3 = 0, leaves: [5]PartyLeave = undefined };

pub fn preparePartyDismiss(state: *const State) !PartyDismiss {
    const members = state.combat.progress.party;
    if (members.len == 0 or members.len > 6) return error.InvalidParty;
    const keep = for (members, 0..) |member, index| {
        if (std.mem.eql(u8, member.id, "hero")) break index;
    } else members.len - 1;
    var plan: PartyDismiss = .{ .keep = keep };
    var next_reserve: usize = 0;
    for (members, 0..) |_, index| {
        try state.combat.validateOwnedMember(state.combat.ownedMember(index));
        if (index == keep) continue;
        const reserve = for (state.reserves[next_reserve..], next_reserve..) |entry, slot| {
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
    const kept = state.combat.progress.party[plan.keep].id;
    for (plan.leaves[0..plan.count]) |leave| commitPartyLeave(state, leave);
    std.debug.assert(state.combat.partyCount() == 1);
    std.debug.assert(std.mem.eql(u8, state.combat.progress.party[0].id, kept));
}

pub fn preparePartyLeave(state: *const State, id: []const u8) !PartyLeave {
    const party = state.combat.progress.party;
    if (party.len <= 1) return error.LastPartyMember;
    const member = for (party, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id, id)) break index;
    } else return error.InvalidMember;
    const reserve = for (state.reserves, 0..) |entry, index| {
        if (entry == null) break index;
    } else return error.RosterFull;
    return .{ .member = member, .reserve = reserve };
}

pub fn commitPartyLeave(state: *State, leave: PartyLeave) void {
    const combat = state.combat;
    const last = combat.partyCount() - 1;
    state.reserves[leave.reserve] = combat.ownedMember(leave.member);
    state.reserve_extras[leave.reserve] = state.extras[leave.member];
    for (leave.member..last) |index| {
        combat.setOwnedMember(index, combat.ownedMember(index + 1));
        state.extras[index] = state.extras[index + 1];
    }
    state.extras[last] = .{ .member_id = "" };
    const formation = combat.formation;
    var slot: usize = 0;
    for (formation[0 .. last + 1]) |member| {
        if (member == leave.member) continue;
        combat.formation[slot] = member - @intFromBool(member > leave.member);
        slot += 1;
    }
    combat.formation[last] = @intCast(last);
    state.replacePartySlice(combat.progress.party[0..last]);
}

pub fn joinPartyMember(state: *State, backing: []battle.Member, catalog: party_session.catalogue.Catalogue, bindings: ?party_session.catalogue.OwnershipBindings, id: []const u8) !void {
    const member = try preparePartyJoin(state, backing, catalog, bindings, id);
    commitPartyJoin(state, backing, member);
}

pub fn joinOnRoomEntry(state: *State, backing: []battle.Member, catalog: party_session.catalogue.Catalogue, bindings: ?party_session.catalogue.OwnershipBindings, room_id: []const u8) !void {
    if (state.route.stage == .world or state.packagedOpeningRoute() != null) return;
    if (std.mem.eql(u8, room_id, "va1_room_1")) {
        if (state.room_battles) |rooms| if (rooms.ownsPartyJoin("cleo")) return;
        for (state.combat.progress.party) |member| if (std.mem.eql(u8, member.id, "cleo")) return;
        try joinPartyMember(state, backing, catalog, bindings, "cleo");
    }
    if (std.mem.eql(u8, room_id, "va1_room_2")) {
        if (state.room_battles) |rooms| if (rooms.ownsPartyJoin("ted")) return;
        for (state.combat.progress.party) |member| if (std.mem.eql(u8, member.id, "ted")) return;
        try joinPartyMember(state, backing, catalog, bindings, "ted");
    }
}
