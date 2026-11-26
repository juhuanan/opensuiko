const std = @import("std");
const creation = @import("opening_party").creation;
const battle = @import("battle");
const field = @import("field");
const party = @import("party_session");
const allocator = std.testing.allocator;

test "0x3C selectors resolve only to their persistent source records" {
    try std.testing.expectEqualStrings("pahn", creation.sources[0].character_id);
    try std.testing.expectEqual(@as(u32, 6), creation.sources[0].source_character_id);
    try std.testing.expectEqualStrings("PAN.BIN", creation.sources[0].resource);
    try std.testing.expectEqualStrings("cleo", creation.sources[1].character_id);
    try std.testing.expectEqual(@as(u32, 1), creation.sources[1].source_character_id);
    try std.testing.expectEqualStrings("CRE.BIN", creation.sources[1].resource);
    try std.testing.expectEqualStrings("gremio", creation.sources[2].character_id);
    try std.testing.expectEqual(@as(u32, 2), creation.sources[2].source_character_id);
    try std.testing.expectEqualStrings("GRE.BIN", creation.sources[2].resource);
}

test "stale before-state rejects the event addition before reading a binding" {
    const expected: party.Snapshot = .{
        .entry_id = "test-entry",
        .content_id = "source-fixture",
        .receipt = "receipt-1",
        .baseline_revision = 1,
    };
    var current = expected;
    current.baseline_revision = 1;
    current.receipt = "receipt-2";
    try std.testing.expectError(error.StaleBeforeState, creation.addLoaded(
        undefined,
        expected,
        current,
        6,
        null,
        .{},
    ));
}

test "unsupported source selectors fail closed" {
    const snapshot: party.Snapshot = .{
        .entry_id = "test-entry",
        .content_id = "source-fixture",
        .receipt = "receipt-1",
        .baseline_revision = 1,
    };
    try std.testing.expectError(error.UnsupportedEventPartySelector, creation.addLoaded(
        undefined,
        snapshot,
        snapshot,
        0x1F,
        null,
        .{},
    ));
}

test "Pahn's NewGame template materializes from the source fixture without roster mutation" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/journey_battle.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const catalogue = try party.catalogue.decode(allocator, @import("party_data").json);
    defer catalogue.deinit();
    var participants: [6]battle.Member = undefined;
    const combat = try battle.State.init(content.value, rules.value, &participants, 17);
    const pahn_source = try creation.initialTemplate(combat, catalogue.value, 6);
    try std.testing.expectEqualStrings("pahn", pahn_source.materialized.owned.id);
    try std.testing.expectEqualStrings("pahn", pahn_source.materialized.extra.member_id);
    try std.testing.expectEqual(@as(u32, 6), pahn_source.source.source_character_id);
    try std.testing.expectEqualStrings("PAN.BIN", pahn_source.source.resource);
    try std.testing.expectEqualStrings("9a7d91cf447765f872329d5f181d14c92cf9de1b96096bb337374dc1e35a2c08", pahn_source.source.resource_sha256);
}

test "0x3C remains blocked until a loaded party binding is supplied" {
    const snapshot: party.Snapshot = .{
        .entry_id = "test-entry",
        .content_id = "source-fixture",
        .receipt = "receipt-1",
        .baseline_revision = 1,
    };
    try std.testing.expectError(error.LoadedPartyBindingUnavailable, creation.addLoaded(
        undefined,
        snapshot,
        snapshot,
        6,
        null,
        .{},
    ));
}

test "party owner replays source additions and rejects forged or stale proposals" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/journey_battle.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const catalogue = try party.catalogue.decode(allocator, @import("party_data").json);
    defer catalogue.deinit();
    const template_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/campaign/opening/party_setup/local_template.json", allocator, .limited(64 * 1024));
    defer allocator.free(template_bytes);
    const template = try creation.local.open(allocator, template_bytes);
    defer template.deinit();
    var participants: [6]battle.Member = undefined;
    const combat = try battle.State.init(content.value, rules.value, &participants, 17);
    const hero = try party.catalogue.materialize(combat.content.characterRules(), catalogue.value, "hero");
    var roster: party.Snapshot = .{ .entry_id = "boot", .content_id = "source", .receipt = "boot", .baseline_revision = 0 };
    roster.members[0] = hero.owned;
    roster.extras[0] = hero.extra;
    roster.eligible[0] = true;
    roster.active[0] = hero.owned.id;
    var owner = try creation.Owner.init(combat, roster, .{});
    const context: creation.Context = .{ .combat = combat, .catalogue = catalogue.value, .sources = .{}, .template = template.value };
    const guarded = try creation.Entry.init(.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }, .{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe }, 1, 0x80);
    try std.testing.expect((try guarded.propose(1)) == null);
    const resource_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/campaign/opening/party_setup/entry_resources.json", allocator, .limited(64 * 1024));
    defer allocator.free(resource_bytes);
    var resources = try creation.openEntryResources(allocator, resource_bytes);
    defer resources.deinit();
    try std.testing.expectError(error.UntrustedEntryResources, creation.openEntryResources(allocator, resource_bytes[1..]));
    try std.testing.expectEqual(@as(u8, 0), resources.parsed.value.initial_config);
    var entry_owner = try creation.Entry.init(.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }, .{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe }, 1, resources.parsed.value.initial_config);
    var invalid_entry = entry_owner.state;
    invalid_entry.slots[1] = 6;
    invalid_entry.loaded[6] = true;
    invalid_entry.revision = 2;
    invalid_entry.receipt = 2;
    invalid_entry.checkpoint = 2;
    try std.testing.expectError(error.InvalidEntryState, creation.Entry.restore(invalid_entry));
    invalid_entry = entry_owner.state;
    invalid_entry.revision = 1;
    invalid_entry.receipt = 1;
    invalid_entry.checkpoint = 1;
    try std.testing.expectError(error.InvalidEntryState, creation.Entry.restore(invalid_entry));
    for ([_]u8{ 108, 6, 1, 2 }, 0..) |id, i| {
        const begin_checkpoint: u64 = @intCast(i * 2 + 1);
        const request = (try entry_owner.propose(begin_checkpoint)).?;
        try std.testing.expectEqual(id, request.source.operand);
        try entry_owner.start(request);
        try std.testing.expectError(error.StaleBeforeState, entry_owner.start(request));
        var ack: creation.EntryAck = .{ .source_id = id, .expected_revision = entry_owner.state.revision, .receipt = entry_owner.state.receipt, .checkpoint = begin_checkpoint + 1 };
        ack.source_id = 8;
        try std.testing.expectError(error.ResourceIdentityMismatch, entry_owner.acknowledge(ack, &resources));
        ack.source_id = id;
        resources.parsed.value.resources[0].clips[0].ticks[0] += 1;
        try std.testing.expectError(error.UntrustedEntryResources, entry_owner.acknowledge(ack, &resources));
        resources.parsed.value.resources[0].clips[0].ticks[0] -= 1;
        ack.receipt += 1;
        try std.testing.expectError(error.StaleBeforeState, entry_owner.acknowledge(ack, &resources));
        ack.receipt -= 1;
        entry_owner = try creation.Entry.restore(entry_owner.state);
        try entry_owner.acknowledge(ack, &resources);
        try std.testing.expectError(error.EntryLoadUnavailable, entry_owner.acknowledge(ack, &resources));
    }
    try std.testing.expect((try entry_owner.propose(9)) == null);
    try std.testing.expectEqualSlices(u8, &.{ 8, 108, 6, 1, 2, 0xff }, &entry_owner.state.slots);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe }, &entry_owner.state.order);
    try std.testing.expectEqual(@as(u8, 1), entry_owner.state.count);
    var adopted = owner;
    try adopted.adoptEntry(entry_owner, 1);
    try std.testing.expectEqualSlices(u8, &entry_owner.state.slots, &adopted.state.slots);
    try std.testing.expectError(error.ProfileUnavailable, owner.propose(context, .{ .initialize_template = 108 }, 1));
    const absent = try owner.propose(context, .{ .event_add = 6 }, 1);
    try std.testing.expectEqualDeep(owner.state.roster, absent.after.roster);
    try std.testing.expectEqualSlices(u8, &owner.state.slots, &absent.after.slots);
    try std.testing.expectEqualSlices(u8, &owner.state.order, &absent.after.order);
    try std.testing.expectEqualSlices(u8, &owner.state.recruit_flags, &absent.after.recruit_flags);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }, &absent.after.area_party.?);
    try owner.commit(context, absent);
    try owner.commit(context, try owner.propose(context, .{ .initialize_template = 6 }, 2));
    try owner.commit(context, try owner.propose(context, .{ .initialize_template = 2 }, 3));
    // These slots model an independently qualified loader, not 0x3C loading resources.
    var loaded_state = owner.state;
    loaded_state.slots[1] = 6;
    loaded_state.loaded[6] = true;
    loaded_state.slots[2] = 2;
    loaded_state.loaded[2] = true;
    owner = try creation.Owner.restore(context, loaded_state);
    const proposal = try owner.propose(context, .{ .event_add = 2 }, 4);
    var forged = proposal;
    forged.after.recruit_flags[0] = 1;
    try std.testing.expectError(error.InvalidProposal, owner.commit(context, forged));
    forged = proposal;
    forged.after.roster.members[0].?.hp -= 1;
    _ = try party.Session.init(combat.content.characterRules(), forged.after.roster, .{});
    try std.testing.expectError(error.InvalidProposal, owner.commit(context, forged));
    try owner.commit(context, proposal);
    try owner.commit(context, try owner.propose(context, .{ .event_add = 6 }, 5));
    try std.testing.expectError(error.StaleBeforeState, owner.commit(context, proposal));
    try std.testing.expectError(error.InvalidCheckpoint, owner.propose(context, .{ .event_add = 1 }, 5));
    try std.testing.expectEqualSlices(u8, &.{ 8, 6, 2, 0xff, 0xff, 0xff }, &owner.state.area_party.?);
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 1, 0xfe, 0xfe, 0xfe }, &owner.state.order);
    try std.testing.expectEqualStrings("gremio", owner.state.roster.active[1].?);
    try std.testing.expectEqualStrings("pahn", owner.state.roster.active[2].?);
    const bytes_saved = try std.json.Stringify.valueAlloc(allocator, owner.state, .{});
    defer allocator.free(bytes_saved);
    const decoded = try std.json.parseFromSlice(creation.OwnerState, allocator, bytes_saved, .{ .allocate = .alloc_always });
    defer decoded.deinit();
    var reloaded = try creation.Owner.restore(context, decoded.value);
    var replayed = proposal;
    replayed.before = decoded.value;
    replayed.after.checkpoint = 6;
    try std.testing.expectError(error.UnmodeledNativePartyAppend, owner.commit(context, replayed));
    var invalid = decoded.value;
    invalid.order[1] = 0;
    try std.testing.expectError(error.InvalidOwnerState, creation.Owner.restore(context, invalid));
    invalid = decoded.value;
    invalid.recruit_flags[0] = 1;
    try std.testing.expectError(error.InvalidOwnerState, creation.Owner.restore(context, invalid));
    invalid = decoded.value;
    invalid.loaded[6] = false;
    try std.testing.expectError(error.InvalidOwnerState, creation.Owner.restore(context, invalid));
    invalid = decoded.value;
    invalid.area_party = .{ 8, 1, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.InvalidOwnerState, creation.Owner.restore(context, invalid));
    invalid = decoded.value;
    invalid.area_party = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.InvalidOwnerState, creation.Owner.restore(context, invalid));
    try std.testing.expectError(error.ProfileUnavailable, reloaded.propose(context, .{ .initialize_template = 1 }, 6));
    const local_op: creation.Operation = .{ .local_template = .{ .room = 0, .entity = 37, .offset = 0x3b825, .selector = 0 } };
    try std.testing.expectError(error.PersistentRecordUnavailable, reloaded.propose(context, local_op, 6));
    try reloaded.commit(context, try reloaded.propose(context, .{ .initialize_template = 35 }, 6));
    try reloaded.commit(context, try reloaded.propose(context, local_op, 7));
    try std.testing.expect(reloaded.state.loaded[35]);
    try std.testing.expectEqual(@as(u8, 35), reloaded.state.slots[3]);
    try std.testing.expectEqual(@as(u8, 3), reloaded.state.order[3]);
    try std.testing.expectEqual(@as(u8, 4), reloaded.state.count);
    try std.testing.expectEqualStrings("viktor", reloaded.state.roster.active[3].?);
    try std.testing.expectError(error.AlreadyLoaded, reloaded.propose(context, local_op, 8));
    var bad_context = context;
    bad_context.template.table_offset += 1;
    try std.testing.expectError(error.UntrustedLocalTemplate, reloaded.propose(bad_context, local_op, 8));
}

test "initial-party caller refuses content without every required combat profile" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/journey_battle.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const catalogue = try party.catalogue.decode(allocator, @import("party_data").json);
    defer catalogue.deinit();
    var participants: [6]battle.Member = undefined;
    const combat = try battle.State.init(content.value, rules.value, &participants, 17);
    try std.testing.expect(content.value.partyProfile("cleo") == null);
    try std.testing.expectError(error.ProfileUnavailable, creation.beginInitialParty(combat, catalogue.value, .{}));
}
