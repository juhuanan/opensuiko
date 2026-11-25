const std = @import("std");
const field = @import("field");
const rec = @import("opening_records");
const entry = rec.entry;
const records = rec.field_records;
const ted = rec.ted_party_add;
const checkpoint = rec.ted_party_checkpoint;

fn heroMember() field.game_state.Member {
    return .{ .id = "hero", .name = "Tir", .hp = 17, .max_hp = 17, .status = .healthy, .rune_charges = @splat(0), .max_rune_charges = @splat(0) };
}

fn loadedEntryState() entry.EntryState {
    var s: entry.EntryState = .{ .slots = .{ 8, 108, 6, 1, 2, 0xff }, .order = .{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe }, .count = 1, .init_config = 0, .revision = 8, .receipt = 8, .checkpoint = 8 };
    for ([_]u8{ 8, 108, 6, 1, 2 }) |id| s.loaded[id] = true;
    return s;
}

fn tedAddRequest() ted.Request {
    return .{ .content_id = "va1_room2_field_events", .content_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", .program = "va1_r02_e02_ordinary", .instance = 2, .batch = 3, .origin = 9, .source_offset = 0x3d1a6, .source_character_id = 108 };
}

test "source seed, field materialization and active slot order" {
    var owner = try records.Owner.init(heroMember(), loadedEntryState());
    try std.testing.expectEqual(@as(u16, 1), owner.state.detached[2].?.max_rune_charges[0]);
    try std.testing.expectEqual(@as(u16, 18), owner.state.detached[0].?.hp);
    try std.testing.expectEqual(@as(u16, 25), owner.state.detached[1].?.hp);
    const p = try owner.proposeAdd(6, 1);
    try owner.commitAdd(p);
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 0xfe, 0xfe, 0xfe, 0xfe }, &owner.state.order);
    try std.testing.expectEqualSlices(u8, &.{ 8, 108, 6, 1, 2, 0xff }, &owner.state.area_party.?);
    try std.testing.expectEqualStrings("pahn", owner.activeMembers()[1].id);
    try std.testing.expect(owner.state.detached[1] == null);
    try std.testing.expectError(error.StaleBeforeState, owner.commitAdd(p));
    try std.testing.expectError(error.UnmodeledNativePartyAppend, owner.proposeAdd(6, 2));
}

test "no loaded slot is a successful sync; invalid proposals are atomic" {
    var skipped = try entry.Entry.init(.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }, .{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe }, 1, 0x80);
    var owner = try records.Owner.init(heroMember(), skipped.state);
    var p = try owner.proposeAdd(6, 1);
    p.after.active[0].hp = 1;
    try std.testing.expectError(error.InvalidProposal, owner.commitAdd(p));
    try std.testing.expectEqual(@as(u16, 17), owner.state.active[0].hp);
    p = try owner.proposeAdd(6, 1);
    try owner.commitAdd(p);
    try std.testing.expectEqual(@as(u8, 1), owner.state.count);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }, &owner.state.area_party.?);
    _ = &skipped;
}

test "restore rejects forged state and rebinds JSON strings" {
    var owner = try records.Owner.init(heroMember(), loadedEntryState());
    try owner.commitAdd(try owner.proposeAdd(1, 1));
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, owner.state, .{});
    defer std.testing.allocator.free(bytes);
    const decoded = try std.json.parseFromSlice(records.State, std.testing.allocator, bytes, .{ .allocate = .alloc_always });
    defer decoded.deinit();
    const restored = try records.Owner.restore(decoded.value, "Tir");
    try std.testing.expectEqualStrings("cleo", restored.state.active[1].id);
    var bad = decoded.value;
    bad.order[1] = 1;
    try std.testing.expectError(error.InvalidState, records.Owner.restore(bad, "Tir"));
    bad = decoded.value;
    bad.receipt += 1;
    try std.testing.expectError(error.InvalidState, records.Owner.restore(bad, "Tir"));
}

test "detached provenance and equipment handoff fail closed" {
    var owner = try records.Owner.init(heroMember(), loadedEntryState());
    var forged = owner.state;
    forged.detached[0].?.hp = 1;
    try std.testing.expectError(error.InvalidState, records.Owner.restore(forged, "Tir"));
    try owner.commitAdd(try owner.proposeAdd(6, 1));
    const equipment = try records.seedEquipment(owner.state.active[1], 6);
    try std.testing.expectEqual(@as(?u8, 1), equipment.inventory_indices[0]);
    try std.testing.expectEqual(@as(?u8, 0), equipment.inventory_indices[1]);
    try std.testing.expectEqual(@as(?u8, 2), equipment.inventory_indices[3]);
    owner.state.active[1].hp = 1;
    try owner.validate();
    owner.state.active[1].inventory.slots[0] = null;
    try std.testing.expectError(error.UnmodeledInventoryMutation, records.seedEquipment(owner.state.active[1], 6));
}

test "stage and commit preserve source slot ordering" {
    var owner = try records.Owner.init(heroMember(), loadedEntryState());
    try owner.commitAdd(try owner.proposeAdd(6, 1));
    const p = try ted.propose(owner, tedAddRequest(), 2);
    try std.testing.expectEqualSlices(u8, &.{ 8, 6, 108, 0xff, 0xff, 0xff }, &p.active_ids);
    try std.testing.expectEqualSlices(u8, &.{ 8, 108, 6, 1, 2, 0xff }, &p.area_party);
    try ted.commit(&owner, tedAddRequest(), p);
    try std.testing.expectEqual(@as(u8, 3), owner.state.count);
    try std.testing.expectError(error.StaleTedAdd, ted.commit(&owner, tedAddRequest(), p));
}

test "forged request, before and candidate are refused atomically" {
    var owner = try records.Owner.init(heroMember(), loadedEntryState());
    var invalid = tedAddRequest();
    invalid.source_offset += 1;
    try std.testing.expectError(error.InvalidTedAddRequest, ted.propose(owner, invalid, 1));
    const p = try ted.propose(owner, tedAddRequest(), 1);
    var wrong = tedAddRequest();
    wrong.batch += 1;
    try std.testing.expectError(error.StaleTedAdd, ted.commit(&owner, wrong, p));
    var forged = p;
    forged.after.active[1].hp = 1;
    try std.testing.expectError(error.InvalidTedAddProposal, ted.commit(&owner, tedAddRequest(), forged));
    try std.testing.expectEqual(@as(u8, 1), owner.state.count);
}

test "missing Ted slot still publishes slot-order area sync" {
    const skipped = try entry.Entry.init(.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }, .{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe }, 1, 0x80);
    var owner = try records.Owner.init(heroMember(), skipped.state);
    const p = try ted.propose(owner, tedAddRequest(), 1);
    try ted.commit(&owner, tedAddRequest(), p);
    try std.testing.expectEqual(@as(u8, 1), owner.state.count);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }, &p.area_party);
}

test "initial and single Ted replay compare complete saved state" {
    var owner = try records.Owner.init(heroMember(), loadedEntryState());
    try checkpoint.validate(heroMember(), loadedEntryState(), owner.state, .initial, null);
    const proposal = try ted.propose(owner, tedAddRequest(), 1);
    try ted.commit(&owner, tedAddRequest(), proposal);
    try checkpoint.validate(heroMember(), loadedEntryState(), owner.state, .{ .ted_add = tedAddRequest() }, tedAddRequest());
    try std.testing.expectError(error.InvalidTedPartyHistory, checkpoint.validate(heroMember(), loadedEntryState(), owner.state, .{ .ted_add = tedAddRequest() }, null));
    try std.testing.expectError(error.InvalidTedPartyCheckpoint, checkpoint.validate(heroMember(), loadedEntryState(), owner.state, .initial, null));
}

test "forged request or party snapshot is refused" {
    var owner = try records.Owner.init(heroMember(), loadedEntryState());
    const proposal = try ted.propose(owner, tedAddRequest(), 1);
    try ted.commit(&owner, tedAddRequest(), proposal);
    var altered = tedAddRequest();
    altered.batch += 1;
    try std.testing.expectError(error.InvalidTedPartyHistory, checkpoint.validate(heroMember(), loadedEntryState(), owner.state, .{ .ted_add = altered }, tedAddRequest()));
    var saved = owner.state;
    saved.active[1].hp = 1;
    try std.testing.expectError(error.InvalidTedPartyCheckpoint, checkpoint.validate(heroMember(), loadedEntryState(), saved, .{ .ted_add = tedAddRequest() }, tedAddRequest()));
    saved = owner.state;
    saved.checkpoint = 2;
    try std.testing.expectError(error.InvalidTedPartyCheckpoint, checkpoint.validate(heroMember(), loadedEntryState(), saved, .{ .ted_add = tedAddRequest() }, tedAddRequest()));
}

test "Ted missing from source slots cannot stand in for an add" {
    const source = try entry.Entry.init(.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }, .{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe }, 1, 0x80);
    const owner = try records.Owner.init(heroMember(), source.state);
    try std.testing.expectError(error.UnsupportedTedPartyHistory, checkpoint.validate(heroMember(), source.state, owner.state, .{ .ted_add = tedAddRequest() }, tedAddRequest()));
}
