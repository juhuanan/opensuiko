//! Focused port gate: the integrator host glue, the generated scenario
//! deck and the consolidated human-review package.  No window, media, disc,
//! emulator or real user save is involved.

const std = @import("std");
const host = @import("package_host");
const scenarios_data = @import("package_host_data").scenarios;
const summaries = @import("pause_menu").save_slots;

test "the packaged opening bytes match the opening canonical start seed" {
    const check = host.verifyStartSeed(@import("opening_data").json);
    try std.testing.expect(check.ok);
    try std.testing.expectEqualSlices(u8, &host.entry.policy.start_seed_sha256, &check.digest);
}

test "a prototype slot label is not presented as a stored save name" {
    var items: [3]summaries.Summary = summaries.emptySummaries();
    items[0] = .{ .status = .ready, .name = summaries.defaultLabel(0), .scene = "vb6_village", .leader = "Hero", .level = 3 };
    items[1] = .{ .status = .ready, .name = try summaries.Label.init("Tir"), .scene = "vb6_forest_edge", .leader = "Tir", .level = 4 };
    var buffer: [3]host.entry.slots.SlotInfo = undefined;
    const infos = host.slotInfos(&buffer, &items);
    try std.testing.expectEqual(host.entry.slots.Status.damaged, infos[0].status);
    try std.testing.expectEqualStrings("", infos[0].name);
    try std.testing.expectEqual(host.entry.slots.Status.ready, infos[1].status);
    try std.testing.expectEqualStrings("Tir", infos[1].name);
}

test "the tablet reveal joins a FACE page and a 64x64 quadrant" {
    var flags: [host.frontiers.data.tablet_entry_count]u8 = @splat(1);
    const portrait = (try host.tabletPortrait(flags, 0)).?;
    try std.testing.expectEqual(@as(u8, 0), portrait.page);
    try std.testing.expectEqual(@as(u8, 0), portrait.cell);
    try std.testing.expectEqual(@as(u8, 0), portrait.portrait_index);
    try std.testing.expectEqual(@as(u16, 64), portrait.width);
    try std.testing.expectEqual(@as(u16, 64), portrait.height);
    flags = @splat(0);
    try std.testing.expect((try host.tabletPortrait(flags, 0)) == null);
}

test "the warehouse caller stays closed for ordinary play" {
    const admission = host.warehouseAdmission(7);
    try std.testing.expect(!admission.allowed);
    try std.testing.expectEqualStrings("azukari_npc_conversation_unresolved", admission.reason);
}

test "the generated data pins the checked-in scenario and review bytes" {
    try std.testing.expectEqualStrings(scenarios_data.schema, "suikoden-scenario-deck/1");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(scenarios_data.scenarios_json, &digest, .{});
    const scenarios_hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(scenarios_data.scenarios_sha256, &scenarios_hex);
    std.crypto.hash.sha2.Sha256.hash(scenarios_data.human_review_json, &digest, .{});
    const human_hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(scenarios_data.human_review_sha256, &human_hex);
}

test "the scenario deck keeps canonical, optional and ending rows distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), scenarios_data.scenarios_json, .{});
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("suikoden-scenario-deck/1", root.get("schema").?.string);
    try std.testing.expect(root.get("private_candidate_only").?.bool);
    try std.testing.expect(!root.get("full_game_claim").?.bool);
    const routes = root.get("routes").?.array.items;
    const optional = root.get("optional").?.array.items;
    const ending = root.get("ending").?.array.items;
    try std.testing.expect(routes.len >= 8);
    try std.testing.expect(optional.len >= 5);
    try std.testing.expectEqual(@as(usize, 1), ending.len);
    try std.testing.expectEqualStrings("blocked", ending[0].object.get("status").?.string);
    try std.testing.expectEqualStrings("final_and_optional_blocks_unavailable", ending[0].object.get("blocker").?.string);
    for (routes) |route| try std.testing.expect(!route.object.get("canonical_new_game").?.bool);
}

test "the human review package defers every native/media gate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), scenarios_data.human_review_json, .{});
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("deferred", root.get("status").?.string);
    try std.testing.expect(root.get("gates").?.array.items.len >= 6);
}
