const std = @import("std");
const duel = @import("duel");
const campaign = @import("chapters").middle_duel_adapter;
const data = @import("middle_assets").duel_entries;

const allocator = std.testing.allocator;
const facts = campaign.Facts{ .story_revision = 7, .roster_digest = @splat(0x5a) };
const low_hp = [2]duel.FighterState{
    .{ .maximum_hp = 40, .hp = 40, .attack = 160, .defense = 80 },
    .{ .maximum_hp = 40, .hp = 40, .attack = 160, .defense = 80 },
};

const Loaded = struct {
    content: std.json.Parsed(duel.Content),
    asset: std.json.Parsed(campaign.Asset),

    fn deinit(self: *Loaded) void {
        self.content.deinit();
        self.asset.deinit();
    }
};

fn load() !Loaded {
    return .{ .content = try duel.load(allocator, duel.content_json), .asset = try campaign.open(allocator, data.json) };
}

fn entry(asset: campaign.Asset, id: []const u8) !campaign.Entry {
    for (asset.entries) |candidate| {
        if (std.mem.eql(u8, candidate.duel_id, id)) return candidate;
    }
    return error.MissingDuelEntry;
}

fn finish(session: *campaign.Session) !void {
    if (session.state.phase == .choosing) try session.choose(.attack);
    for (0..1024) |_| {
        if (session.state.phase == .finished) return;
        try session.tick();
    }
    return error.DuelDidNotFinish;
}

test "asset pins all three shared encounters and unresolved mappings" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var loaded = try load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 3), loaded.asset.value.entries.len);
    for (loaded.asset.value.entries) |candidate| {
        try std.testing.expectEqualStrings("source_entry_unresolved", candidate.story_entry);
        try std.testing.expectEqualStrings("source_consequences_unresolved", candidate.consequences);
    }
}

test "stale before-state is rejected before RNG admission" {
    var loaded = try load();
    defer loaded.deinit();
    const selected = try entry(loaded.asset.value, "pahn_teo");
    const stale = campaign.Facts{ .story_revision = 8, .roster_digest = facts.roster_digest };
    try std.testing.expectError(error.StaleBeforeState, campaign.Session.begin(&loaded.content.value, selected, facts, stale, low_hp, .{ .bios_state = 1 }));
}

test "all three duels return source outcomes and stable receipts" {
    var loaded = try load();
    defer loaded.deinit();
    for ([_][]const u8{ "pahn_teo", "shu_kwanda", "shu_teo" }) |id| {
        const selected = try entry(loaded.asset.value, id);
        var session = try campaign.Session.begin(&loaded.content.value, selected, facts, facts, low_hp, .{ .bios_state = 1 });
        try finish(&session);
        const result = try session.takeResult();
        try std.testing.expectEqual(duel.Outcome.victory, result.outcome);
        try std.testing.expectEqualStrings("source_consequences_unresolved", result.consequences);
        try std.testing.expectEqual(facts.story_revision, result.expected_story_revision);
    }
}

test "a result receipt cannot be consumed twice" {
    var loaded = try load();
    defer loaded.deinit();
    const selected = try entry(loaded.asset.value, "pahn_teo");
    var session = try campaign.Session.begin(&loaded.content.value, selected, facts, facts, low_hp, .{ .bios_state = 1 });
    try finish(&session);
    _ = try session.takeResult();
    try std.testing.expectError(error.DuplicateResult, session.takeResult());
}

test "mid-exchange restore continues with the same outcome and receipt" {
    var loaded = try load();
    defer loaded.deinit();
    const selected = try entry(loaded.asset.value, "shu_kwanda");
    var original = try campaign.Session.begin(&loaded.content.value, selected, facts, facts, low_hp, .{ .bios_state = 1 });
    try original.choose(.attack);
    for (0..5) |_| try original.tick();
    const snapshot = try original.capture();
    var restored = try campaign.Session.restore(&loaded.content.value, selected, facts, facts, snapshot);
    try finish(&original);
    try finish(&restored);
    const left = try original.takeResult();
    const right = try restored.takeResult();
    try std.testing.expectEqual(left.receipt, right.receipt);
    try std.testing.expectEqual(left.final_random.cursor, right.final_random.cursor);
}

test "restoring a consumed final screen cannot duplicate consequences" {
    var loaded = try load();
    defer loaded.deinit();
    const selected = try entry(loaded.asset.value, "shu_teo");
    var session = try campaign.Session.begin(&loaded.content.value, selected, facts, facts, low_hp, .{ .bios_state = 1 });
    try finish(&session);
    const result = try session.takeResult();
    const snapshot = try session.capture();
    var restored = try campaign.Session.restore(&loaded.content.value, selected, facts, facts, snapshot);
    try std.testing.expectError(error.DuplicateResult, restored.takeResult());
    try std.testing.expectEqual(result.receipt, restored.result.?.receipt);
}

test "mismatched snapshots and scenarios fail closed" {
    var loaded = try load();
    defer loaded.deinit();
    const selected = try entry(loaded.asset.value, "pahn_teo");
    var session = try campaign.Session.begin(&loaded.content.value, selected, facts, facts, low_hp, .{ .bios_state = 1 });
    try session.choose(.attack);
    var snapshot = try session.capture();
    snapshot.current_exchange_id = "missing";
    try std.testing.expectError(error.SnapshotMismatch, campaign.Session.restore(&loaded.content.value, selected, facts, facts, snapshot));
    snapshot.duel_id = "shu_kwanda";
    try std.testing.expectError(error.SnapshotMismatch, campaign.Session.restore(&loaded.content.value, selected, facts, facts, snapshot));
}

test "cancel does not change the encounter or consume a result" {
    var loaded = try load();
    defer loaded.deinit();
    const selected = try entry(loaded.asset.value, "pahn_teo");
    var session = try campaign.Session.begin(&loaded.content.value, selected, facts, facts, low_hp, .{ .bios_state = 1 });
    const before = session.state;
    try std.testing.expect(!session.state.cancel());
    try std.testing.expectEqual(before, session.state);
    try std.testing.expectError(error.ResultPending, session.takeResult());
}
