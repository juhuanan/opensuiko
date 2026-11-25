const std = @import("std");
const travel = @import("chapters").middle_travel;
const data = @import("middle_assets").travel;

const allocator = std.testing.allocator;

fn load() !std.json.Parsed(travel.Asset) {
    return travel.open(allocator, data.json);
}

test "asset hash and full campaign edge census are pinned" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1660), parsed.value.edges.len);
    try std.testing.expectEqual(@as(usize, 89), parsed.value.sources.len);
}

test "VA1 handoff resolves through the real area descriptor" {
    var parsed = try load();
    defer parsed.deinit();
    const edge = travel.edgeAt(parsed.value, 0x514a0).?;
    try std.testing.expectEqualStrings("room", edge.destination.kind);
    try std.testing.expectEqualStrings("DATA/01_AREA.A/VA1.BIN", edge.destination.area_file.?);
    try std.testing.expectEqual(@as(u8, 0), edge.destination.room.?);
    try std.testing.expectEqual(@as(i32, 808), edge.destination.x.?);
    try std.testing.expectEqual(@as(i32, 56), edge.destination.y.?);
}

test "selector nine resolves VAA and spawn remains unverified" {
    var parsed = try load();
    defer parsed.deinit();
    const edge = travel.edgeAt(parsed.value, 0x3ebcc).?;
    try std.testing.expectEqualStrings("DATA/01_AREA.A/VAA.BIN", edge.destination.area_file.?);
    try std.testing.expectEqual(@as(i32, 312), edge.destination.x.?);
    try std.testing.expectEqual(@as(i32, 736), edge.destination.y.?);
    try std.testing.expectEqualStrings("unverified", edge.destination.spawn_state);
    try std.testing.expectEqualStrings("source_guard_unresolved", edge.unlock_state);
}

test "world transition coordinates stay in cells and outside room identity" {
    var parsed = try load();
    defer parsed.deinit();
    const edge = travel.edgeAt(parsed.value, 0x350fc).?;
    try std.testing.expectEqualStrings("world", edge.destination.kind);
    try std.testing.expect(edge.destination.area_file == null);
    try std.testing.expectEqual(@as(u8, 2), edge.destination.region.?);
    try std.testing.expectEqual(@as(i32, 59), edge.destination.x.?);
    try std.testing.expectEqual(@as(i32, 38), edge.destination.y.?);
    try std.testing.expectEqualStrings("world_cells", edge.destination.coordinate_units.?);
}

test "unresolved destinations remain blocked" {
    var parsed = try load();
    defer parsed.deinit();
    var count: usize = 0;
    for (parsed.value.edges) |edge| {
        if (!std.mem.eql(u8, edge.destination.kind, "unresolved")) continue;
        count += 1;
        try std.testing.expectEqualStrings("blocked", edge.destination.spawn_state);
        try std.testing.expect(edge.destination.reason != null);
    }
    try std.testing.expectEqual(@as(usize, 7), count);
}

test "source order is deterministic" {
    var parsed = try load();
    defer parsed.deinit();
    for (parsed.value.edges[1..], 1..) |edge, index| {
        const earlier = parsed.value.edges[index - 1];
        if (!std.mem.eql(u8, earlier.source_file, edge.source_file)) continue;
        try std.testing.expect(earlier.room <= edge.room);
        if (earlier.room != edge.room) continue;
        try std.testing.expect(earlier.stream <= edge.stream);
        if (earlier.stream != edge.stream) continue;
        try std.testing.expect(earlier.offset < edge.offset);
    }
}

test "accepted VB6 edge is the sole production checkpoint and fixed-zero guards stay invalid" {
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 1), parsed.value.coverage.production_edges);
    try std.testing.expectEqual(@as(u16, 1), parsed.value.coverage.unlocked_edges);
    try std.testing.expectEqual(@as(u16, 9), parsed.value.coverage.unsupported_guards);
    try std.testing.expectEqualStrings("region_c_world_ready", parsed.value.next_checkpoint);
    const chapter = parsed.value.chapter_edge;
    const edge = travel.edgeAt(parsed.value, 0x350fc).?;
    try std.testing.expectEqualStrings(chapter.edge_id, edge.id);
    try std.testing.expectEqualStrings("production", edge.runtime_state);
    try std.testing.expectEqualStrings("accepted_route_guard", edge.unlock_state);
    try std.testing.expectEqualStrings("accepted_world_ready", edge.destination.spawn_state);
    const plan = try travel.planChapter(parsed.value, 360, 383, 0);
    try std.testing.expectEqualStrings("vb6_r06_e01_to_region_c", plan.route_id);
    try std.testing.expectEqual(@as(u8, 1), plan.source_order);
    try std.testing.expectEqual(@as(u8, 2), plan.destination.region);
    try std.testing.expectEqual(@as(i32, 59), plan.destination.x);
    try std.testing.expectEqual(@as(i32, 38), plan.destination.y);
}

test "chapter checkpoint rejects an invented gate and altered route evidence" {
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectError(error.RouteTriggerMismatch, travel.planChapter(parsed.value, 359, 0, 0));
    try std.testing.expectError(error.RouteTriggerMismatch, travel.planChapter(parsed.value, 368, 0, 0));
    try std.testing.expectError(error.RouteTriggerMismatch, travel.planChapter(parsed.value, 360, 384, 0));
    try std.testing.expectError(error.TransitionBarrierBlocked, travel.planChapter(parsed.value, 360, 0, 1));
    var bad = parsed.value;
    bad.chapter_edge.guard.source_half_cell_x = 44;
    try std.testing.expectError(error.InvalidChapterEdge, travel.validate(bad));
    bad = parsed.value;
    bad.coverage.production_edges = 0;
    try std.testing.expectError(error.InvalidTravelCoverage, travel.validate(bad));
}

test "stale destination and production claims fail closed" {
    var parsed = try load();
    defer parsed.deinit();
    const edges = try allocator.dupe(travel.Edge, parsed.value.edges);
    defer allocator.free(edges);
    edges[0].destination.area_file = "DATA/unknown.BIN";
    var bad = parsed.value;
    bad.edges = edges;
    try std.testing.expectError(error.InvalidTravelDestination, travel.validate(bad));
    bad = parsed.value;
    bad.coverage.production_edges = 2;
    try std.testing.expectError(error.InvalidTravelCoverage, travel.validate(bad));
}
