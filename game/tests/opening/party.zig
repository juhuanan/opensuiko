const std = @import("std");
const party = @import("opening_party").party;
const data = @import("opening_assets").party_setup;

const allocator = std.testing.allocator;

fn load() !std.json.Parsed(party.Asset) {
    return party.open(allocator, data.json);
}

fn operation(asset: party.Asset, id: []const u8) !party.Operation {
    for (asset.operations) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return error.MissingOperation;
}

test "asset hash and canonical empty recruitment baseline are pinned" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u8, 8), parsed.value.boot.party_slots[0]);
    for (parsed.value.boot.recruit_flags) |flag| try std.testing.expectEqual(@as(u8, 0), flag);
}

test "Pahn is added before Gremio in source order" {
    var parsed = try load();
    defer parsed.deinit();
    var pahn_index: ?usize = null;
    var gremio_index: ?usize = null;
    for (parsed.value.operations, 0..) |entry, index| {
        if (entry.opcode != 0x3C or entry.stream != 0x3c3c4) continue;
        if (entry.source_character_id.? == 6) pahn_index = index;
        if (entry.source_character_id.? == 1) gremio_index = index;
    }
    try std.testing.expect(pahn_index.? < gremio_index.?);
}

test "Ted remains a guest rather than a fabricated Star identity" {
    var parsed = try load();
    defer parsed.deinit();
    var found = false;
    for (parsed.value.operations) |entry| {
        if (entry.source_character_id != 108) continue;
        found = true;
        try std.testing.expectEqualStrings("Ted", entry.character.?);
    }
    try std.testing.expect(found);
}

test "leave and follower operations map to HQ roster source actions" {
    var parsed = try load();
    defer parsed.deinit();
    var leaves: usize = 0;
    var followers: usize = 0;
    for (parsed.value.operations) |entry| {
        if (entry.opcode == 0x20) {
            leaves += 1;
            try std.testing.expectEqualStrings(entry.family, party.plan(entry).source_action);
        }
        if (entry.opcode == 0x36) {
            followers += 1;
            try std.testing.expectEqualStrings("follower_build", party.plan(entry).source_action);
        }
    }
    try std.testing.expect(leaves != 0);
    try std.testing.expect(followers != 0);
}

test "initial event joins select existing records without changing recruitment" {
    var parsed = try load();
    defer parsed.deinit();
    for (parsed.value.operations) |entry| {
        if (entry.opcode != 0x3C) continue;
        try std.testing.expectEqualStrings("source_action", entry.runtime_state);
        const decision = party.plan(entry).event_join;
        try std.testing.expectEqual(entry.source_character_id.?, decision.source_character_id);
        try std.testing.expectEqual(party.RecordRule.select_existing, decision.record);
        try std.testing.expectEqual(party.RecruitRule.unchanged, decision.recruit_bitmap);
    }
}

test "resource joins expose the area-table and first-free-slot contract" {
    var parsed = try load();
    defer parsed.deinit();
    var found = false;
    for (parsed.value.operations) |entry| {
        if (entry.opcode != 0x1F) continue;
        found = true;
        const decision = party.plan(entry).resource_join;
        try std.testing.expectEqual(entry.selector, decision.selector);
        try std.testing.expectEqual(party.RecordRule.select_existing, decision.record);
        try std.testing.expectEqual(party.RecruitRule.unchanged, decision.recruit_bitmap);
    }
    try std.testing.expect(found);
}

test "stale coverage and unsupported operation claims fail closed" {
    var parsed = try load();
    defer parsed.deinit();
    var bad = parsed.value;
    bad.coverage.operations += 1;
    try std.testing.expectError(error.InvalidPartyCoverage, party.validate(bad));
    const operations = try allocator.dupe(party.Operation, parsed.value.operations);
    defer allocator.free(operations);
    operations[0].runtime_state = "compiled";
    bad = parsed.value;
    bad.operations = operations;
    try std.testing.expectError(error.InvalidPartyOperation, party.validate(bad));
}
