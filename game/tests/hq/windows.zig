//! Recruitment windows focused checks: the static recruitment ledger, its
//! admission conjunction, the five source routes and the single non-escape
//! grant. No original instruction executes and no game window or media is
//! touched.

const std = @import("std");
const windows_mod = @import("hq").windows;
const data = @import("hq_data").recruitment_windows;

const allocator = std.testing.allocator;

var story: [0x300]u8 = undefined;
var recruit: [108]u8 = undefined;
var party: [108]u8 = undefined;
var levels: [108]u8 = undefined;

fn baseFacts() windows_mod.Facts {
    @memset(&story, 0);
    @memset(&recruit, 0);
    @memset(&party, 0);
    @memset(&levels, 0);
    return .{
        .interaction = true,
        .story = &story,
        .recruit = &recruit,
        .party = &party,
        .levels = &levels,
        .money = 25_000,
        .tier = 2,
        .eligible = 99,
    };
}

fn load() !windows_mod.Loaded {
    return windows_mod.open(allocator, data.json);
}

fn expectRoute(outcome: windows_mod.Outcome, route: windows_mod.Route) !void {
    try std.testing.expectEqual(route, outcome.route);
}

fn expectNoPlan(outcome: windows_mod.Outcome) !void {
    try std.testing.expect(outcome.plan == null);
}

test "the generated asset hash, schema and coverage are pinned" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const digest = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &digest);
    var loaded = try load();
    defer loaded.deinit();
    const asset = loaded.asset();
    try std.testing.expectEqualStrings(windows_mod.schema, asset.schema);
    try std.testing.expectEqual(@as(usize, 64), asset.content_sha256.len);
    try std.testing.expectEqual(@as(usize, 108), asset.identity.identities.len);
    try std.testing.expectEqual(@as(usize, 75), asset.windows.len);
    try std.testing.expectEqual(@as(usize, 59), asset.coverage.identities_with_window);
    try std.testing.expectEqual(@as(usize, 49), asset.coverage.identities_without_window);
    try std.testing.expectEqual(@as(usize, 49), asset.coverage.choice_windows);
    try std.testing.expectEqual(@as(usize, 44), asset.coverage.verified_choices);
    try std.testing.expectEqual(@as(usize, 42), asset.coverage.verified_decline_routes);
    for (asset.windows) |window| {
        try std.testing.expectEqualStrings("roster.recruit_present", window.operation.op_id);
        try std.testing.expectEqual(@as(u8, 0x45), window.operation.op_code);
        try std.testing.expectEqualStrings("non_escape", window.operation.arm);
        try std.testing.expectEqual(window.cid, window.operation.operands[0]);
    }
}

test "a corrupt ledger fails closed" {
    var loaded = try load();
    defer loaded.deinit();
    var bad = loaded.parsed.value;
    bad.schema = "not-the-schema";
    try std.testing.expectError(error.InvalidSchema, windows_mod.validate(&bad));

    var window = loaded.parsed.value.windows[0];
    window.operation.op_code = 0x44;
    var windows = [_]windows_mod.Window{window};
    var bad_operation = loaded.parsed.value;
    bad_operation.windows = &windows;
    try std.testing.expectError(error.InvalidOperation, windows_mod.validate(&bad_operation));
}

test "positive admission emits one grant and the identity block is display only" {
    var loaded = try load();
    defer loaded.deinit();
    const asset = loaded.asset();
    const window = windows_mod.windowById(asset, "recruit_window_000").?;
    const facts = baseFacts();
    const outcome = windows_mod.evaluate(window, facts);
    try expectRoute(outcome, .admitted);
    try std.testing.expect(outcome.plan != null);
    try std.testing.expectEqual(@as(u8, 10), outcome.plan.?.cid);
    try std.testing.expectEqual(@as(u8, 0x45), outcome.plan.?.op_code);
    try std.testing.expectEqualStrings("recruit_window_000", outcome.plan.?.window_id);
    // The same site is still admitted when its identity row is absent: names
    // and portraits are lookup data, never admission inputs.
    const flag_only = windows_mod.windowByCid(asset, 58).?;
    try std.testing.expect(flag_only.identity == null);
    try expectRoute(windows_mod.evaluate(flag_only, baseFacts()), .admitted);
    try std.testing.expect(windows_mod.windowByCid(asset, 1) == null);
    try std.testing.expectEqualStrings("Sonya", windows_mod.identity(asset, 10).?.name.?);
    try std.testing.expect(windows_mod.identity(asset, 255) == null);
}

test "interaction, absent and duplicate routes are source-conditioned" {
    var loaded = try load();
    defer loaded.deinit();
    const window = windows_mod.windowById(loaded.asset(), "recruit_window_000").?;
    var facts = baseFacts();
    facts.interaction = false;
    const no_touch = windows_mod.evaluate(window, facts);
    try expectRoute(no_touch, .window_not_open);
    try expectNoPlan(no_touch);
    try std.testing.expectEqual(windows_mod.BlockCode.interaction_required, no_touch.blocker.?.code);

    facts = baseFacts();
    facts.entity_available = false;
    const absent = windows_mod.evaluate(window, facts);
    try expectRoute(absent, .absent);
    try std.testing.expectEqual(windows_mod.BlockCode.entity_unloaded, absent.blocker.?.code);

    facts = baseFacts();
    recruit[10] = 1;
    const duplicate = windows_mod.evaluate(window, facts);
    try expectRoute(duplicate, .already_recruited);
    try expectNoPlan(duplicate);
}

test "a required-clear story byte is a missed window, not a generic lock" {
    var loaded = try load();
    defer loaded.deinit();
    const window = windows_mod.windowById(loaded.asset(), "recruit_window_040").?;
    var facts = baseFacts();
    story[391] = 2;
    const missed = windows_mod.evaluate(window, facts);
    try expectRoute(missed, .missed_window);
    try expectNoPlan(missed);
    try std.testing.expectEqual(windows_mod.BlockCode.story_closed, missed.blocker.?.code);

    facts = baseFacts();
    recruit[73] = 0;
    try expectRoute(windows_mod.evaluate(window, facts), .admitted);
}

test "decline leaves the bitmap untouched and repeated interaction is a duplicate" {
    var loaded = try load();
    defer loaded.deinit();
    const window = windows_mod.windowById(loaded.asset(), "recruit_window_007").?;
    const facts = baseFacts();
    const declined = windows_mod.choose(window, 1, facts);
    try expectRoute(declined, .declined);
    try expectNoPlan(declined);
    try std.testing.expectEqual(@as(u8, 0), recruit[22]);
    const accepted = windows_mod.choose(window, 0, facts);
    try expectRoute(accepted, .admitted);
    try std.testing.expectEqual(@as(u8, 22), accepted.plan.?.cid);
    try expectRoute(windows_mod.choose(window, 1, facts), .declined);
    const invalid = windows_mod.choose(window, 2, facts);
    try expectRoute(invalid, .invalid_choice);
    try std.testing.expectEqual(@as(u8, 0), recruit[22]);
    recruit[22] = 1;
    const repeat = windows_mod.choose(window, 0, facts);
    try expectRoute(repeat, .already_recruited);
    try expectNoPlan(repeat);
}

test "unverified and service second arms stay typed, never declines" {
    var loaded = try load();
    defer loaded.deinit();
    const asset = loaded.asset();
    const unlabelled = windows_mod.windowById(asset, "recruit_window_002").?;
    const second = windows_mod.choose(unlabelled, 1, baseFacts());
    try expectRoute(second, .second_route);
    try std.testing.expectEqual(windows_mod.BlockCode.second_arm_unproved, second.blocker.?.code);
    try expectNoPlan(second);

    const service = windows_mod.windowById(asset, "recruit_window_061").?;
    var facts = baseFacts();
    recruit[96] = 0;
    const items = [_]u16{154};
    facts.items = &items;
    const service_route = windows_mod.choose(service, 1, facts);
    try expectRoute(service_route, .second_route);
    try std.testing.expectEqual(windows_mod.BlockCode.second_arm_unproved, service_route.blocker.?.code);
}

test "money, item, party, level and eligible gates are typed blockers" {
    var loaded = try load();
    defer loaded.deinit();
    const asset = loaded.asset();

    const money = windows_mod.windowById(asset, "recruit_window_007").?;
    var facts = baseFacts();
    facts.money = 19_999;
    try expectRoute(windows_mod.evaluate(money, facts), .insufficient_money);
    facts.money = 20_000;
    try expectRoute(windows_mod.evaluate(money, facts), .admitted);

    const item = windows_mod.windowById(asset, "recruit_window_051").?;
    facts = baseFacts();
    facts.tier = 3;
    try expectRoute(windows_mod.evaluate(item, facts), .missing_item);
    const items = [_]u16{172};
    facts.items = &items;
    try expectRoute(windows_mod.evaluate(item, facts), .admitted);

    const party_gate = windows_mod.windowById(asset, "recruit_window_042").?;
    facts = baseFacts();
    facts.tier = 1;
    try expectRoute(windows_mod.evaluate(party_gate, facts), .party_conflict);
    party[39] = 1;
    try expectRoute(windows_mod.evaluate(party_gate, facts), .admitted);

    const level_gate = windows_mod.windowById(asset, "recruit_window_010").?;
    facts = baseFacts();
    facts.tier = 1;
    levels[8] = 24;
    try expectRoute(windows_mod.evaluate(level_gate, facts), .level_too_low);
    levels[8] = 25;
    try expectRoute(windows_mod.evaluate(level_gate, facts), .admitted);

    const eligible_gate = windows_mod.windowById(asset, "recruit_window_029").?;
    facts = baseFacts();
    facts.eligible = 79;
    try expectRoute(windows_mod.evaluate(eligible_gate, facts), .recruit_count_too_low);
    facts.eligible = 80;
    try expectRoute(windows_mod.evaluate(eligible_gate, facts), .admitted);
}

test "an incomplete caller snapshot is an invalid state, not a grant" {
    var loaded = try load();
    defer loaded.deinit();
    const window = windows_mod.windowById(loaded.asset(), "recruit_window_000").?;
    var facts = baseFacts();
    facts.recruit = &.{};
    const short = windows_mod.evaluate(window, facts);
    try expectRoute(short, .invalid_state);
    try std.testing.expectEqual(windows_mod.BlockCode.missing_recruit_bitmap, short.blocker.?.code);
    try expectNoPlan(short);

    const story_window = windows_mod.windowById(loaded.asset(), "recruit_window_040").?;
    facts = baseFacts();
    facts.story = &.{};
    const no_story = windows_mod.evaluate(story_window, facts);
    try expectRoute(no_story, .invalid_state);
    try std.testing.expectEqual(windows_mod.BlockCode.missing_story, no_story.blocker.?.code);
}
