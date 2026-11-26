const std = @import("std");
const opening_party = @import("opening_party");
const creation = opening_party.creation;
const event_join = opening_party.event_join;
const party = opening_party.party;
const battle = @import("battle");
const party_session = @import("party_session");
const operations_data = @import("opening_assets").party_setup;

const allocator = std.testing.allocator;

fn operation(asset: party.Asset, id: []const u8) !party.Operation {
    for (asset.operations) |candidate| {
        if (std.mem.eql(u8, candidate.id, id)) return candidate;
    }
    return error.MissingOperation;
}

fn bootOwner(context: creation.Context) !creation.Owner {
    const hero = try party_session.catalogue.materialize(context.rules, context.catalogue, "hero");
    var roster: party_session.Snapshot = .{
        .entry_id = "boot",
        .content_id = "source",
        .receipt = "boot",
        .baseline_revision = 0,
    };
    roster.members[0] = hero.owned;
    roster.extras[0] = hero.extra;
    roster.eligible[0] = true;
    roster.active[0] = hero.owned.id;
    return creation.Owner.fromSnapshot(context, roster);
}

fn adoptEntry(owner: *creation.Owner) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/campaign/opening/party_setup/entry_resources.json", allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    var resources = try creation.openEntryResources(allocator, bytes);
    defer resources.deinit();
    var entry = try creation.Entry.init(
        .{ 8, 0xff, 0xff, 0xff, 0xff, 0xff },
        .{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe },
        1,
        resources.parsed.value.initial_config,
    );
    for ([_]u8{ 108, 6, 1, 2 }, 0..) |id, index| {
        const begin_checkpoint: u64 = @intCast(index * 2 + 1);
        const request = (try entry.propose(begin_checkpoint)).?;
        try std.testing.expectEqual(id, request.source.operand);
        try entry.start(request);
        try entry.acknowledge(.{
            .source_id = id,
            .expected_revision = entry.state.revision,
            .receipt = entry.state.receipt,
            .checkpoint = begin_checkpoint + 1,
        }, &resources);
    }
    try owner.adoptEntry(entry, 1);
}

test "0x3C selects a loaded record and appends Pahn without recruit writes" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/journey_battle.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const catalogue = try party_session.catalogue.decode(allocator, @import("party_data").json);
    defer catalogue.deinit();
    const template_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/campaign/opening/party_setup/local_template.json", allocator, .limited(64 * 1024));
    defer allocator.free(template_bytes);
    const template = try creation.local.open(allocator, template_bytes);
    defer template.deinit();
    var operations = try party.open(allocator, operations_data.json);
    defer operations.deinit();
    const rules = content.value.characterRules();
    var owner = try bootOwner(.{ .rules = rules, .catalogue = catalogue.value, .sources = .{}, .template = template.value });
    const context: creation.Context = .{ .rules = rules, .catalogue = catalogue.value, .sources = .{}, .template = template.value };
    try adoptEntry(&owner);
    try owner.commit(context, try owner.propose(context, .{ .initialize_template = 6 }, 2));

    const pahn_operation = try operation(operations.value, "party_op_03");
    const pahn = try event_join.propose(owner, context, pahn_operation, 3);
    try std.testing.expectEqual(@as(usize, 1), pahn.record.?.roster_index);
    try std.testing.expectEqual(@as(u8, 6), pahn.record.?.source_character_id);
    try std.testing.expectEqualStrings("pahn", pahn.record.?.member_id);
    try std.testing.expectEqual(@as(?u8, 2), pahn.source_slot);
    try std.testing.expectEqual(@as(?u8, 1), pahn.active_order_index);
    try std.testing.expect(pahn.area == null);
    var forged = pahn;
    forged.owner.after.recruit_flags[0] = 1;
    try std.testing.expectError(error.InvalidEventJoinProposal, event_join.commit(&owner, context, pahn_operation, forged));
    try std.testing.expectEqual(@as(u8, 1), owner.state.count);
    try event_join.commit(&owner, context, pahn_operation, pahn);
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 0xfe, 0xfe, 0xfe, 0xfe }, &owner.state.order);
    try std.testing.expectEqualStrings("pahn", owner.state.roster.active[1].?);
    try std.testing.expectEqualSlices(u8, &.{ 8, 108, 6, 1, 2, 0xff }, &owner.state.area_party.?);
    try std.testing.expectEqual(@as(u8, 2), owner.state.count);
    for (owner.state.recruit_flags) |flag| try std.testing.expectEqual(@as(u8, 0), flag);
}

test "0x3C missing slot only rebuilds area order and keeps the initialized record inactive" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/journey_battle.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const catalogue = try party_session.catalogue.decode(allocator, @import("party_data").json);
    defer catalogue.deinit();
    const template_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/campaign/opening/party_setup/local_template.json", allocator, .limited(64 * 1024));
    defer allocator.free(template_bytes);
    const template = try creation.local.open(allocator, template_bytes);
    defer template.deinit();
    var operations = try party.open(allocator, operations_data.json);
    defer operations.deinit();
    const rules = content.value.characterRules();
    var owner = try bootOwner(.{ .rules = rules, .catalogue = catalogue.value, .sources = .{}, .template = template.value });
    const context: creation.Context = .{ .rules = rules, .catalogue = catalogue.value, .sources = .{}, .template = template.value };
    try owner.commit(context, try owner.propose(context, .{ .initialize_template = 6 }, 1));
    const pahn_operation = try operation(operations.value, "party_op_03");
    const proposal = try event_join.propose(owner, context, pahn_operation, 2);
    try std.testing.expect(proposal.record == null);
    try std.testing.expect(proposal.source_slot == null);
    try std.testing.expect(proposal.active_order_index == null);
    try event_join.commit(&owner, context, pahn_operation, proposal);
    try std.testing.expectEqual(@as(u8, 1), owner.state.count);
    try std.testing.expectEqualStrings("pahn", owner.state.roster.members[1].?.id);
    try std.testing.expect(!owner.state.roster.eligible[1]);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }, &owner.state.area_party.?);
    var wrong_source = pahn_operation;
    wrong_source.offset += 2;
    try std.testing.expectError(error.UnqualifiedEventJoin, event_join.propose(owner, context, wrong_source, 3));
}

test "0x1F resolves VA1 entry 11 and atomically loads existing Viktor" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/journey_battle.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const catalogue = try party_session.catalogue.decode(allocator, @import("party_data").json);
    defer catalogue.deinit();
    const template_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/campaign/opening/party_setup/local_template.json", allocator, .limited(64 * 1024));
    defer allocator.free(template_bytes);
    const template = try creation.local.open(allocator, template_bytes);
    defer template.deinit();
    var operations = try party.open(allocator, operations_data.json);
    defer operations.deinit();
    const rules = content.value.characterRules();
    var owner = try bootOwner(.{ .rules = rules, .catalogue = catalogue.value, .sources = .{}, .template = template.value });
    const context: creation.Context = .{ .rules = rules, .catalogue = catalogue.value, .sources = .{}, .template = template.value };
    const viktor_operation = try operation(operations.value, "party_op_02");
    try std.testing.expectError(error.PersistentRecordUnavailable, event_join.propose(owner, context, viktor_operation, 1));
    try owner.commit(context, try owner.propose(context, .{ .initialize_template = 35 }, 1));
    const proposal = try event_join.propose(owner, context, viktor_operation, 2);
    try std.testing.expectEqual(@as(usize, 1), proposal.record.?.roster_index);
    try std.testing.expectEqual(@as(u8, 35), proposal.record.?.source_character_id);
    try std.testing.expectEqualStrings("viktor", proposal.record.?.member_id);
    try std.testing.expectEqual(@as(?u8, 1), proposal.source_slot);
    try std.testing.expectEqual(@as(?u8, 1), proposal.active_order_index);
    const area = proposal.area.?;
    try std.testing.expectEqual(@as(u32, 0x59e8), area.area_header_offset);
    try std.testing.expectEqual(@as(u8, 11), area.header_bias);
    try std.testing.expectEqual(@as(u32, 0x451d4), area.table_offset);
    try std.testing.expectEqual(@as(u8, 11), area.table_index);
    try std.testing.expectEqual(@as(u32, 0x45200), area.table_entry_offset);
    try std.testing.expectEqual(@as(u32, 0x5a324), area.template_offset);
    try std.testing.expectEqual(@as(u32, 0x5000), area.template_copy_bytes);
    try std.testing.expectEqualStrings("DATA/04_PLAY/VIC.BIN", area.resource.file);
    try std.testing.expectEqualStrings("f68a6fccbc03b1a16a09b0d14c1b4838b6cc4206f0bd84c5b496c9d97b7fae20", area.resource.sha256);
    try std.testing.expect(proposal.resource.?.set_loaded_bit);
    try std.testing.expect(proposal.resource.?.recount_required);
    try event_join.commit(&owner, context, viktor_operation, proposal);
    try std.testing.expect(owner.state.loaded[35]);
    try std.testing.expectEqualSlices(u8, &.{ 8, 35, 0xff, 0xff, 0xff, 0xff }, &owner.state.slots);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0xfe, 0xfe, 0xfe, 0xfe }, &owner.state.order);
    try std.testing.expectEqualStrings("viktor", owner.state.roster.active[1].?);
    try std.testing.expect(owner.state.roster.eligible[1]);
    for (owner.state.recruit_flags) |flag| try std.testing.expectEqual(@as(u8, 0), flag);
}
