const std = @import("std");
const war = @import("war");
const session = @import("war_session");
const campaign = @import("chapters").middle_war_adapter;
const data = @import("middle_assets").war_entries;

const allocator = std.testing.allocator;
const facts = campaign.Facts{ .story_revision = 11, .roster_digest = @splat(0x33) };

fn load() !std.json.Parsed(war.Packet) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/assets/war/scenarios.json", allocator, .limited(war.max_json_bytes));
    defer allocator.free(bytes);
    return war.load(allocator, bytes);
}

fn finish(adapter: *campaign.Adapter) !void {
    var ticks: usize = 0;
    var actions: usize = 0;
    while (adapter.session.engine.phase != .result and ticks < 20000 and actions < 100) : (ticks += 1) {
        if (adapter.session.engine.phase == .player_command) {
            try adapter.session.engine.issueTeam(0, 0);
            actions += 1;
        } else if (adapter.session.engine.script.?.phase == adapter.session.engine.scenario.lifecycle.wait_phase) {
            try adapter.session.engine.confirmScript();
        } else {
            try adapter.session.engine.tick();
        }
    }
    if (adapter.session.engine.phase != .result) {
        std.debug.print("war phase={s} updates={} script={any} troops={any} command={} selected={}\n", .{ @tagName(adapter.session.engine.phase), adapter.session.engine.updates, adapter.session.engine.script, adapter.session.engine.troops, adapter.session.command_index, adapter.session.engine.selected_index });
        return error.WarDidNotFinish;
    }
}

test "asset pins nine producer-v6 scenarios without accepted dependency claims" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var asset = try campaign.open(allocator, data.json);
    defer asset.deinit();
    try std.testing.expectEqual(@as(usize, 9), asset.value.entries.len);
    try std.testing.expectEqual(@as(u8, 0), asset.value.coverage.accepted_dependencies);
}

test "wrong scenario and stale before-state reject admission" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    try std.testing.expectError(error.WrongWarScenario, campaign.Adapter.begin(allocator, "wrong", scenario, facts, facts, .{ .state = 19 }));
    const stale = campaign.Facts{ .story_revision = 12, .roster_digest = facts.roster_digest };
    try std.testing.expectError(error.StaleBeforeState, campaign.Adapter.begin(allocator, scenario.id, scenario, facts, stale, .{ .state = 19 }));
}

test "genuine WAR result applies once with a stable receipt" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var adapter = try campaign.Adapter.begin(allocator, scenario.id, scenario, facts, facts, .{ .state = 19 });
    defer adapter.deinit();
    try finish(&adapter);
    const receipt = adapter.session.engine.result.?.receipt;
    const commit = try adapter.applyResult(receipt);
    try std.testing.expectEqual(receipt, commit.result.receipt);
    try std.testing.expectEqualStrings("canonical_story_mapping_unresolved", commit.canonical_mapping);
    try std.testing.expectError(error.WarResultAlreadyConsumed, adapter.applyResult(receipt));
}

test "mid-phase restore produces the same result and future RNG" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var original = try campaign.Adapter.begin(allocator, scenario.id, scenario, facts, facts, .{ .state = 19 });
    defer original.deinit();
    for (0..10) |_| try original.session.update(.{ .confirm = true });
    const snapshot = try original.capture(allocator);
    defer allocator.free(snapshot.session_json);
    var restored = try campaign.Adapter.restore(allocator, scenario.id, scenario, facts, facts, snapshot);
    defer restored.deinit();
    try finish(&original);
    try finish(&restored);
    try std.testing.expectEqual(original.session.engine.result.?.receipt, restored.session.engine.result.?.receipt);
    try std.testing.expectEqual(original.session.engine.rng, restored.session.engine.rng);
}

test "restored final host cannot apply consequences twice" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var adapter = try campaign.Adapter.begin(allocator, scenario.id, scenario, facts, facts, .{ .state = 19 });
    defer adapter.deinit();
    try finish(&adapter);
    const receipt = adapter.session.engine.result.?.receipt;
    _ = try adapter.applyResult(receipt);
    const snapshot = try adapter.capture(allocator);
    defer allocator.free(snapshot.session_json);
    var restored = try campaign.Adapter.restore(allocator, scenario.id, scenario, facts, facts, snapshot);
    defer restored.deinit();
    try std.testing.expectError(error.WarResultAlreadyConsumed, restored.applyResult(receipt));
}

test "malformed snapshots fail without host mutation" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    const snapshot = campaign.Snapshot{ .entry_id = scenario.id, .host = .{}, .session_json = "{}" };
    try std.testing.expectError(error.MissingField, campaign.Adapter.restore(allocator, scenario.id, scenario, facts, facts, snapshot));
}

test "restore revalidates before-state" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var adapter = try campaign.Adapter.begin(allocator, scenario.id, scenario, facts, facts, .{ .state = 19 });
    defer adapter.deinit();
    const snapshot = try adapter.capture(allocator);
    defer allocator.free(snapshot.session_json);
    const stale = campaign.Facts{ .story_revision = 12, .roster_digest = facts.roster_digest };
    try std.testing.expectError(error.StaleBeforeState, campaign.Adapter.restore(allocator, scenario.id, scenario, facts, stale, snapshot));
}

test "consequence mapping remains unresolved instead of inventing story IDs" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var adapter = try campaign.Adapter.begin(allocator, scenario.id, scenario, facts, facts, .{ .state = 19 });
    defer adapter.deinit();
    try finish(&adapter);
    const commit = try adapter.applyResult(adapter.session.engine.result.?.receipt);
    try std.testing.expectEqualStrings("canonical_story_mapping_unresolved", commit.canonical_mapping);
    try std.testing.expectEqual(commit.result.rng, adapter.session.engine.rng);
}
