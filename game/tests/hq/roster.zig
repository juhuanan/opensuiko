//! Focused gate: forced party, temporary departure/return, followers,
//! death/absence and one-to-six ownership through the canonical roster.
//!
//! Pure/port-level only: no original instruction, emulator, window, media or
//! user save is touched.  The real source packet is embedded, so a packet or
//! field-list change breaks this gate instead of silently drifting.
const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const party = @import("party_session");
const roster_mod = @import("hq").roster;
const data = @import("hq_data").roster;
const packet = roster_mod.source;
const roster = roster_mod.roster;

fn member(profile: packet.Profile, index: usize) battle.OwnedMember {
    var owned: battle.OwnedMember = .{
        .id = profile.id,
        .name = profile.name,
        .hp = 40 + @as(u16, @intCast(index % 20)),
        .max_hp = 99,
        .status = .healthy,
        .rune_charges = .{ 1, 2, 3, 4 },
        .max_rune_charges = .{ 4, 4, 4, 4 },
        .inventory = .{},
        .level = 1 + @as(u8, @intCast(index % 40)),
        .experience = @as(u32, @intCast((index * 17) % 1000)),
        .base_stats = .{
            .attack = 10 + @as(u16, @intCast(index)),
            .defense = 9,
            .skill = 8,
            .speed = 7,
            .magic = 6,
            .luck = 5,
        },
        .weapon_level = 1 + @as(u8, @intCast(index % 16)),
        .loadout = .{ .head = 0 },
        .rune = null,
    };
    owned.inventory.slots[0] = .{ .id = .medicine, .uses = 1 };
    owned.inventory.slots[1] = .{ .id = .bandanna, .uses = 0 };
    return owned;
}

fn extra(id: []const u8, index: usize) party.CharacterExtra {
    return .{
        .member_id = id,
        .weapon_element = .fire,
        .weapon_fragments = .{ @intCast(index % 10), 1, 2, 3, 4 },
        .locked_equipment = .{ false, false, false, false, false },
    };
}

const Fixture = struct {
    snapshot: party.Snapshot,
    noncombatants: [roster.max_noncombatants]roster.NoncombatantState,
};

fn makeFixture(p: packet.Packet, active_count: usize, owned_count: usize) !Fixture {
    if (active_count < 1 or active_count > 6 or owned_count < active_count or owned_count > p.profiles.len) return error.InvalidFixture;
    var snapshot = party.Snapshot{
        .entry_id = "hq-roster-entry",
        .content_id = "hq-roster-content",
        .receipt = "hq-roster-receipt",
        .baseline_revision = 7,
    };
    for (0..owned_count) |index| {
        const profile = p.profiles[index];
        snapshot.members[index] = member(profile, index);
        snapshot.extras[index] = extra(profile.id, index);
        snapshot.eligible[index] = true;
    }
    for (0..active_count) |index| snapshot.active[index] = p.profiles[index].id;
    snapshot.forced[0] = "hero";
    for (0..active_count) |index| snapshot.scene_order[index] = p.profiles[index].id;
    if (active_count > 1) snapshot.followers[0] = p.profiles[1].id;
    var noncombatants: [roster.max_noncombatants]roster.NoncombatantState = undefined;
    var count: usize = 0;
    for (p.identities) |identity| if (identity.combat_id == null) {
        noncombatants[count] = .{ .identity = identity.index, .recruited = (identity.index % 2) == 0 };
        count += 1;
    };
    if (count != roster.max_noncombatants) return error.InvalidFixture;
    return .{ .snapshot = snapshot, .noncombatants = noncombatants };
}

fn canonicalMember(r: *const roster.Roster, id: []const u8) battle.OwnedMember {
    const index = r.memberIndex(id).?;
    return r.snapshot.members[index].?;
}
fn canonicalExtra(r: *const roster.Roster, id: []const u8) party.CharacterExtra {
    const index = r.memberIndex(id).?;
    return r.snapshot.extras[index].?;
}

test "source packet fixes the 108/78 identity partition and twelve operations" {
    const parsed = try packet.load(std.testing.allocator, data.json);
    defer parsed.deinit();
    const p = parsed.value;
    try std.testing.expectEqual(@as(usize, 108), p.identities.len);
    try std.testing.expectEqual(@as(usize, 78), p.profiles.len);
    try std.testing.expectEqual(@as(usize, 2), p.guests.len);
    try std.testing.expectEqual(@as(usize, 32), p.counts.noncombatant_identities);
    try std.testing.expectEqual(@as(?u16, 0), p.identityOfCombat("hero"));
    try std.testing.expect(p.profile("joshua") == null);
    try std.testing.expect(p.isGuest("ted") and p.isGuest("odessa"));
    try std.testing.expect(p.operation("opcode20.leave_temporary") != null);
    try std.testing.expectEqual(packet.ActiveEffect.remove_nonhero, p.operation("opcode20.leave_all_nonhero").?.effects.active);
    try std.testing.expectEqual(packet.SlotEffect.retain, p.operation("opcode20.leave_temporary").?.effects.slot);
    try std.testing.expectEqual(packet.SlotEffect.clear, p.operation("opcode20.leave_permanent").?.effects.slot);
    try std.testing.expectEqual(packet.RecruitEffect.toggle, p.operation("opcode20.leave_permanent").?.effects.recruit);
    try std.testing.expectEqual(packet.SlotEffect.none, p.operation("opcode3b.scene_order").?.effects.slot);
}

test "one-to-six active members keep the full 78-record reserve" {
    const parsed = try packet.load(std.testing.allocator, data.json);
    defer parsed.deinit();
    const p = parsed.value;
    for (1..7) |n| {
        var fixture = try makeFixture(p, n, p.profiles.len);
        var value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
        try value.validate(p);
        try std.testing.expectEqual(n, value.activeCount());
        const snap = value.toSnapshot();
        var members: usize = 0;
        for (snap.members) |maybe| if (maybe != null) {
            members += 1;
        };
        try std.testing.expectEqual(@as(usize, 78), members);
    }
}

test "ordinary forced removal is rejected, source leave is allowed" {
    const parsed = try packet.load(std.testing.allocator, data.json);
    defer parsed.deinit();
    const p = parsed.value;
    var fixture = try makeFixture(p, 6, p.profiles.len);
    fixture.snapshot.forced[1] = p.profiles[1].id;
    var value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
    var selected: [6]?[]const u8 = @splat(null);
    selected[0] = "hero";
    try std.testing.expectError(error.ForcedMemberRemoval, value.select(p, selected));
    try std.testing.expectError(error.InvalidSource, value.leave(p, p.profiles[1].id, .temporary, ""));
    try value.leave(p, p.profiles[1].id, .temporary, "event-0x20-fc");
    try std.testing.expectEqual(@as(usize, 5), value.activeCount());
    try std.testing.expect(!value.isForced(p.profiles[1].id));
    try value.rejoin(p, p.profiles[1].id, false, "event-0x3c");
    try std.testing.expectEqual(@as(usize, 6), value.activeCount());
}

test "temporary departure preserves every member field and survives save/load/return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try packet.load(arena.allocator(), data.json);
    const p = parsed.value;
    var fixture = try makeFixture(p, 6, p.profiles.len);
    var value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
    const id = p.profiles[3].id;
    const before = canonicalMember(&value, id);
    const before_extra = canonicalExtra(&value, id);
    try value.leave(p, id, .temporary, "event-0x20-fc");
    try std.testing.expectEqual(roster.Presence.temporary_absent, value.stateOf(id).?.presence);
    try std.testing.expect(value.stateOf(id).?.loaded);
    try std.testing.expectEqualDeep(before, canonicalMember(&value, id));
    try std.testing.expectEqualDeep(before_extra, canonicalExtra(&value, id));
    // A battle and a field scene happen while the member is away.  The scene
    // order is the five remaining active members, never the absent one.
    try value.knockout(p, p.profiles[5].id, "battle-0x800e2c90");
    try value.setSceneOrder(p, .{ p.profiles[2].id, p.profiles[0].id, p.profiles[1].id, p.profiles[4].id, p.profiles[5].id, null });
    try value.setFollowers(p, .{ p.profiles[2].id, null, null, null, null, null });
    const bytes = try value.save(arena.allocator());
    const restored = try roster.Roster.restore(arena.allocator(), p, bytes);
    try std.testing.expectEqual(roster.Presence.temporary_absent, restored.stateOf(id).?.presence);
    try std.testing.expectEqualDeep(before, canonicalMember(&restored, id));
    try std.testing.expectEqualDeep(before_extra, canonicalExtra(&restored, id));
    try std.testing.expectEqual(@as(u16, 0), canonicalMember(&restored, p.profiles[5].id).hp);
    var copy = restored;
    try copy.rejoin(p, id, false, "event-0x3c");
    try std.testing.expectEqual(@as(usize, 6), copy.activeCount());
    try std.testing.expectEqualDeep(before, canonicalMember(&copy, id));
    try std.testing.expectEqualDeep(before_extra, canonicalExtra(&copy, id));
}

test "permanent departure clears recruit/slot but preserves the record; rejoin needs recruit" {
    const parsed = try packet.load(std.testing.allocator, data.json);
    defer parsed.deinit();
    const p = parsed.value;
    var fixture = try makeFixture(p, 6, p.profiles.len);
    var value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
    // Profile 4 is guest Ted, who has no portrait identity index; use the next
    // identity-mapped combat record so the recruit path is exercised.
    const id = p.profiles[5].id;
    const before = canonicalMember(&value, id);
    const identity = p.identityOfCombat(id).?;
    try value.leave(p, id, .permanent, "event-0x20-fe");
    try std.testing.expectEqual(roster.Presence.unrecruited, value.stateOf(id).?.presence);
    try std.testing.expect(!value.snapshot.eligible[value.memberIndex(id).?]);
    try std.testing.expectEqualDeep(before, canonicalMember(&value, id));
    try std.testing.expectError(error.NotTemporaryAbsence, value.rejoin(p, id, false, "event-0x3c"));
    try value.setRecruit(p, identity, true, "event-0x45");
    try std.testing.expectEqual(roster.Presence.reserve, value.stateOf(id).?.presence);
    try std.testing.expect(value.snapshot.eligible[value.memberIndex(id).?]);
    try value.loadJoin(p, id, false, "event-0x1f");
    try std.testing.expectEqual(roster.Presence.active, value.stateOf(id).?.presence);
    try std.testing.expectEqualDeep(before, canonicalMember(&value, id));
}

test "forced strip keeps Hero and every removed record; reload restores five" {
    const parsed = try packet.load(std.testing.allocator, data.json);
    defer parsed.deinit();
    const p = parsed.value;
    var fixture = try makeFixture(p, 6, p.profiles.len);
    var value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
    var before: [6]battle.OwnedMember = undefined;
    for (0..6) |i| before[i] = value.snapshot.members[i].?;
    try value.leaveAllNonHero(p, "event-0x20-ff");
    try std.testing.expectEqual(@as(usize, 1), value.activeCount());
    try std.testing.expectEqualStrings("hero", value.snapshot.active[0].?);
    // The strip releases the removed members' locks but keeps the Hero lock.
    try std.testing.expect(value.isForced("hero"));
    for (1..6) |i| {
        try std.testing.expectEqual(roster.Presence.detached, value.stateOf(before[i].id).?.presence);
        try std.testing.expectEqualDeep(before[i], canonicalMember(&value, before[i].id));
    }
    for (1..6) |i| try value.loadJoin(p, before[i].id, false, "event-0x1f");
    try std.testing.expectEqual(@as(usize, 6), value.activeCount());
    for (1..6) |i| try std.testing.expectEqualDeep(before[i], canonicalMember(&value, before[i].id));
}

test "followers and scene order are scene-only and never create roster entries" {
    const parsed = try packet.load(std.testing.allocator, data.json);
    defer parsed.deinit();
    const p = parsed.value;
    var fixture = try makeFixture(p, 6, p.profiles.len);
    var value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
    const members_before: usize = 78;
    const order: [6]?[]const u8 = .{ p.profiles[2].id, p.profiles[0].id, p.profiles[1].id, null, null, null };
    try value.setSceneOrder(p, order);
    try value.setFollowers(p, .{ p.profiles[1].id, null, null, null, null, null });
    var members_after: usize = 0;
    for (value.snapshot.members) |maybe| if (maybe != null) {
        members_after += 1;
    };
    try std.testing.expectEqual(members_before, members_after);
    try std.testing.expectEqual(@as(usize, 6), value.activeCount());
    try std.testing.expect(value.memberIndex("joshua") == null);
    // A guest may follow without becoming owned; the active party is unchanged.
    try value.setFollowers(p, .{ "ted", null, null, null, null, null });
    try std.testing.expect(value.memberIndex("ted") == null or value.isActive("ted"));
    try std.testing.expectEqual(@as(usize, 6), value.activeCount());
}

test "noncombatant recruit flags do not fabricate a combat profile" {
    const parsed = try packet.load(std.testing.allocator, data.json);
    defer parsed.deinit();
    const p = parsed.value;
    const identity = for (p.identities) |entry| {
        if (entry.combat_id == null) break entry;
    } else unreachable;
    var fixture = try makeFixture(p, 6, p.profiles.len);
    var value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
    try value.setRecruit(p, identity.index, false, "event-0x45");
    try std.testing.expect(!value.noncombatantState(identity.index).?.recruited);
    try value.setRecruit(p, identity.index, true, "event-0x45");
    try std.testing.expect(value.noncombatantState(identity.index).?.recruited);
    try std.testing.expect(value.memberIndex(identity.name) == null);
    try std.testing.expect(p.profile(identity.name) == null);
    try std.testing.expectError(error.UnknownMember, value.loadJoin(p, identity.name, false, "event-0x1f"));
}

test "knockout is a condition; gear, XP, rune and sidecar survive save/load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try packet.load(arena.allocator(), data.json);
    const p = parsed.value;
    var fixture = try makeFixture(p, 6, p.profiles.len);
    var value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
    const id = p.profiles[2].id;
    const before = canonicalMember(&value, id);
    const before_extra = canonicalExtra(&value, id);
    try value.knockout(p, id, "battle-0x800e2c90");
    const down = canonicalMember(&value, id);
    try std.testing.expectEqual(@as(u16, 0), down.hp);
    try std.testing.expectEqual(field.game_state.Status.unconscious, down.status);
    try std.testing.expectEqual(before.experience, down.experience);
    try std.testing.expectEqual(before.weapon_level, down.weapon_level);
    try std.testing.expectEqualDeep(before.inventory, down.inventory);
    try std.testing.expectEqualDeep(before.loadout, down.loadout);
    try std.testing.expectEqualDeep(before_extra, canonicalExtra(&value, id));
    const bytes = try value.save(arena.allocator());
    const restored = try roster.Roster.restore(arena.allocator(), p, bytes);
    try std.testing.expectEqualDeep(down, canonicalMember(&restored, id));
    try std.testing.expectEqualDeep(before_extra, canonicalExtra(&restored, id));
    var copy = restored;
    try copy.revive(p, id, "battle-0x800de1ec");
    try std.testing.expectEqual(before.hp, canonicalMember(&copy, id).hp);
    try std.testing.expectEqual(before.status, canonicalMember(&copy, id).status);
    try std.testing.expectEqual(before.experience, canonicalMember(&copy, id).experience);
}

test "roster journal is receipt-bound, atomic and rejects stale/empty replays" {
    const parsed = try packet.load(std.testing.allocator, data.json);
    defer parsed.deinit();
    const p = parsed.value;
    const fixture = try makeFixture(p, 6, p.profiles.len);
    const value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
    var journal = roster.Journal{ .baseline_revision = value.revision, .receipt = value.revision + 1 };
    journal.commands[0] = .{ .knockout = .{ .id = p.profiles[1].id, .source_text = "battle-0x800e2c90" } };
    journal.commands[1] = .{ .leave = .{ .id = p.profiles[1].id, .kind = .temporary, .source_text = "event-0x20-fc" } };
    const changed = try roster.replay(p, value, journal);
    try std.testing.expectEqual(@as(u64, 8), changed.revision);
    try std.testing.expectEqual(roster.Presence.temporary_absent, changed.stateOf(p.profiles[1].id).?.presence);
    try std.testing.expectError(error.InvalidReceipt, roster.replay(p, changed, journal));
    var stale = journal;
    stale.receipt = 9;
    try std.testing.expectError(error.InvalidReceipt, roster.replay(p, changed, stale));
    const empty = roster.Journal{ .baseline_revision = changed.revision, .receipt = changed.revision + 1 };
    try std.testing.expectError(error.EmptyJournal, roster.replay(p, changed, empty));
    const small_fixture = try makeFixture(p, 1, p.profiles.len);
    const small = try roster.Roster.init(p, small_fixture.snapshot, &small_fixture.noncombatants);
    var bad = roster.Journal{ .baseline_revision = small.revision, .receipt = small.revision + 1 };
    bad.commands[0] = .{ .leave = .{ .id = "hero", .kind = .temporary, .source_text = "event-0x20-fc" } };
    try std.testing.expectError(error.LastActive, roster.replay(p, small, bad));
    try std.testing.expectEqual(roster.Presence.active, small.stateOf("hero").?.presence);
}

test "save tampering and invalid packets are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try packet.load(arena.allocator(), data.json);
    const p = parsed.value;
    const fixture = try makeFixture(p, 6, p.profiles.len);
    const value = try roster.Roster.init(p, fixture.snapshot, &fixture.noncombatants);
    const bytes = try value.save(arena.allocator());
    var failed = false;
    _ = roster.Roster.restore(arena.allocator(), p, bytes[0 .. bytes.len / 2]) catch {
        failed = true;
    };
    try std.testing.expect(failed);
    // Malformed JSON is refused regardless of fixture length.
    const copy = try arena.allocator().dupe(u8, bytes);
    copy[0] ^= 0x40;
    _ = roster.Roster.restore(arena.allocator(), p, copy) catch {
        failed = true;
    };
    try std.testing.expect(failed);
    // A tampered schema header is refused.
    const schema_offset = std.mem.indexOf(u8, bytes, "\"schema\"").?;
    const schema_colon = std.mem.indexOfScalarPos(u8, bytes, schema_offset, ':').?;
    const schema_quote = std.mem.indexOfScalarPos(u8, bytes, schema_colon, '"').?;
    try std.testing.expect(schema_quote + 2 < bytes.len);
    const bad_schema = try arena.allocator().dupe(u8, bytes);
    bad_schema[schema_quote + 1] = if (bad_schema[schema_quote + 1] == 'x') 'y' else 'x';
    try std.testing.expectError(error.InvalidSave, roster.Roster.restore(arena.allocator(), p, bad_schema));
    // A structurally valid save with a different packet digest is refused.
    failed = false;
    const digest_offset = std.mem.indexOf(u8, bytes, "source_digest").?;
    const colon = std.mem.indexOfScalarPos(u8, bytes, digest_offset, ':').?;
    const quote = std.mem.indexOfScalarPos(u8, bytes, colon, '"').?;
    try std.testing.expect(quote + 2 < bytes.len);
    const tampered = try arena.allocator().dupe(u8, bytes);
    tampered[quote + 1] = if (tampered[quote + 1] == 'a') 'b' else 'a';
    _ = roster.Roster.restore(arena.allocator(), p, tampered) catch {
        failed = true;
    };
    try std.testing.expect(failed);
}
