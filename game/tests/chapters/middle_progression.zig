const std = @import("std");
const battles = @import("chapters").middle_battle_graph;
const data = @import("middle_assets").battle_graph;

const allocator = std.testing.allocator;

fn load() !std.json.Parsed(battles.Asset) {
    return battles.open(allocator, data.json);
}

test "asset hash and complete battle census are pinned" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 90), parsed.value.formations.len);
    try std.testing.expectEqual(@as(usize, 50), parsed.value.entries.len);
    try std.testing.expectEqual(@as(u16, 0), parsed.value.coverage.production_entries);
}

test "VA2 entries bind the one-BonBon source formation" {
    var parsed = try load();
    defer parsed.deinit();
    for ([_]u32{ 0x267f0, 0x2683e, 0x26893 }) |stream| {
        const entry = battles.entryByOffset(parsed.value, stream).?;
        try std.testing.expectEqualStrings("area_a.encounter.01", entry.formation_id.?);
        const formation = battles.formationById(parsed.value, entry.formation_id.?).?;
        try std.testing.expectEqual(@as(usize, 1), formation.slots.len);
        try std.testing.expectEqual(@as(u8, 1), formation.slots[0].enemy_id);
        try std.testing.expectEqual(@as(u32, 127996), formation.slots[0].stats_offset.?);
    }
}

test "all battle entries resolve real formation identities" {
    var parsed = try load();
    defer parsed.deinit();
    for (parsed.value.entries) |entry| {
        try std.testing.expect(battles.formationById(parsed.value, entry.formation_id.?) != null);
        try std.testing.expectEqualStrings("source_entry", entry.entry_state);
        try std.testing.expectEqualStrings("source_only", entry.runtime_state);
    }
}

test "reviewed and source-only policy domains stay separate" {
    var parsed = try load();
    defer parsed.deinit();
    var reviewed: usize = 0;
    var source_only: usize = 0;
    for (parsed.value.formations) |formation| {
        if (std.mem.eql(u8, formation.policy_state, "reviewed_finite_policy")) {
            reviewed += 1;
        } else {
            source_only += 1;
            try std.testing.expectEqualStrings("source_only_policy_unresolved", formation.policy_state);
            try std.testing.expectEqualStrings("DATA/15_AREA.Z/Z_DATA.BIN", formation.source_file);
        }
    }
    try std.testing.expectEqual(@as(usize, 77), reviewed);
    try std.testing.expectEqual(@as(usize, 13), source_only);
}

test "source ordering and shared streams remain distinct by room" {
    var parsed = try load();
    defer parsed.deinit();
    for (parsed.value.entries[1..], 1..) |entry, index| {
        const earlier = parsed.value.entries[index - 1];
        const order = std.mem.order(u8, earlier.source_file, entry.source_file);
        try std.testing.expect(order != .gt);
        if (order != .eq) continue;
        try std.testing.expect(earlier.room <= entry.room);
        if (earlier.room != entry.room) continue;
        try std.testing.expect(earlier.stream <= entry.stream);
        if (earlier.stream != entry.stream) continue;
        try std.testing.expect(earlier.offset < entry.offset);
    }
}

test "outcome continuations do not imply victory or escape" {
    var parsed = try load();
    defer parsed.deinit();
    for (parsed.value.entries) |entry| {
        try std.testing.expectEqualStrings("return_to_source_stream_no_auto_chain", entry.victory);
        try std.testing.expectEqualStrings("game_over_not_victory", entry.defeat);
        try std.testing.expectEqualStrings("typed_blocker_source_retry_unresolved", entry.escape);
    }
}

test "stale formation references fail closed" {
    var parsed = try load();
    defer parsed.deinit();
    const entries = try allocator.dupe(battles.Entry, parsed.value.entries);
    defer allocator.free(entries);
    entries[0].formation_id = "area_a.encounter.99";
    var bad = parsed.value;
    bad.entries = entries;
    try std.testing.expectError(error.MissingBattleFormation, battles.validate(bad));
    bad = parsed.value;
    bad.coverage.production_entries = 1;
    try std.testing.expectError(error.InvalidBattleCoverage, battles.validate(bad));
}
