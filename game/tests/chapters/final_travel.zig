const std = @import("std");
const ch = @import("chapters");
const travel = ch.middle_travel;
const travel_data = @import("middle_assets").travel;
const final = ch.final_travel;
const data = @import("final_assets").final_travel;

const allocator = std.testing.allocator;

const Loaded = struct {
    parent: std.json.Parsed(travel.Asset),
    asset: std.json.Parsed(final.Asset),

    fn deinit(self: *Loaded) void {
        self.asset.deinit();
        self.parent.deinit();
    }
};

fn load() !Loaded {
    const parent = try travel.open(allocator, travel_data.json);
    errdefer parent.deinit();
    return .{ .parent = parent, .asset = try final.open(allocator, data.json, parent.value) };
}

test "asset hash and one-way final-region census validate every reference" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var loaded = try load();
    defer loaded.deinit();
    try final.validate(loaded.asset.value, loaded.parent.value);
    try std.testing.expectEqual(@as(usize, 2), loaded.asset.value.incoming_ids.len);
    try std.testing.expectEqual(@as(usize, 144), loaded.asset.value.region_ids.len);
    try std.testing.expectEqual(@as(u16, 0), loaded.asset.value.coverage.external_returns);
}

test "both external entrances resolve VAC with source spawn coordinates" {
    var loaded = try load();
    defer loaded.deinit();
    for (loaded.asset.value.incoming_ids) |id| {
        const decision = try final.plan(loaded.asset.value, loaded.parent.value, id);
        const edge = decision.selected;
        try std.testing.expectEqualStrings("DATA/15_AREA.Z/VAC.BIN", edge.destination.area_file.?);
        try std.testing.expectEqual(@as(i32, 808), edge.destination.x.?);
        try std.testing.expectEqual(@as(i32, 1040), edge.destination.y.?);
        try std.testing.expectEqualStrings("unverified", edge.destination.spawn_state);
    }
}

test "all final-local destinations stay inside Z and no return is invented" {
    var loaded = try load();
    defer loaded.deinit();
    for (loaded.asset.value.region_ids) |id| {
        const edge = final.edgeById(loaded.parent.value, id).?;
        try std.testing.expectEqualStrings("room", edge.destination.kind);
        try std.testing.expect(std.mem.startsWith(u8, edge.destination.area_file.?, final.z_prefix));
    }
}

test "out-of-scope and unresolved destinations do not select a route" {
    var loaded = try load();
    defer loaded.deinit();
    try std.testing.expectEqual(final.Decision.outside_final_scope, try final.plan(loaded.asset.value, loaded.parent.value, "travel_0000"));
    const edges = try allocator.dupe(travel.Edge, loaded.parent.value.edges);
    defer allocator.free(edges);
    for (edges) |*edge| {
        if (std.mem.eql(u8, edge.id, "travel_0235")) edge.destination.kind = "world";
    }
    var parent = loaded.parent.value;
    parent.edges = edges;
    try std.testing.expectEqual(final.Decision.blocked_destination, try final.plan(loaded.asset.value, parent, "travel_0235"));
}

test "a stale entrance reference is rejected" {
    var loaded = try load();
    defer loaded.deinit();
    const ids = try allocator.dupe([]const u8, loaded.asset.value.incoming_ids);
    defer allocator.free(ids);
    ids[0] = "travel_0000";
    var bad = loaded.asset.value;
    bad.incoming_ids = ids;
    try std.testing.expectError(error.InvalidFinalEntrance, final.validate(bad, loaded.parent.value));
}

test "VZ7 remains a source terminal rather than a travel return" {
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 0x80010EE8), parsed.asset.value.terminal.main_ending);
    try std.testing.expectEqual(@as(u32, 0x800103B8), parsed.asset.value.terminal.ending_exit);
    try std.testing.expectEqualStrings("source_only_not_a_travel_edge", parsed.asset.value.terminal.state);
    try std.testing.expectEqual(@as(u16, 0), parsed.asset.value.coverage.production_edges);
}
