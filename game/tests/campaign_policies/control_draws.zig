//! Focused gate: ordinary-control routing and logical draw state.
//!
//! Everything here is pure/port-level: no original instruction, no window, no
//! media, no original-code test.  The world and field compositions run against
//! the real `world`/`world_view`/`field` production types, so a change to those
//! types or to the checked-in content breaks this test instead of silently
//! drifting from the control-draws contract.

const std = @import("std");
const control_draws_mod = @import("campaign_policies").control_draws;
const field = @import("field");
const world = @import("world");
const view = @import("world_view");

const hex32 = control_draws_mod.draws.hex32;

/// The focused test reads the tracked authored content from the repository
/// root instead of embedding it: `@embedFile` cannot reach outside the module
/// package path, and duplicating the fixture into the owned packet would hide
/// which bytes were measured.  Run the gate from the repository root.
fn readTracked(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(8 * 1024 * 1024));
}

fn digestHex(digest: [32]u8) [64]u8 {
    return hex32(digest);
}

fn expectDigest(expected_hex: []const u8, actual: [32]u8) !void {
    const hex = digestHex(actual);
    try std.testing.expectEqualStrings(expected_hex, &hex);
}

// ---------------------------------------------------------------------------
// Packet identity and the contract/code cross-check.
// ---------------------------------------------------------------------------

test "embedded packet is the generated one" {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(control_draws_mod.data.control_contract_json);
    var out: [32]u8 = undefined;
    digest.final(&out);
    try std.testing.expectEqualStrings(control_draws_mod.data.control_contract_file_sha256, &digestHex(out));

    var second = std.crypto.hash.sha2.Sha256.init(.{});
    second.update(control_draws_mod.data.logical_draws_json);
    second.final(&out);
    try std.testing.expectEqualStrings(control_draws_mod.data.logical_draws_file_sha256, &digestHex(out));
    try std.testing.expectEqualStrings("control-draws.1", control_draws_mod.version);
}

test "the generated contract agrees with the compiled ownership table" {
    const parsed = try control_draws_mod.loadContract(std.testing.allocator);
    defer parsed.deinit();
    const contract = parsed.value;
    try std.testing.expectEqual(@as(usize, 4), contract.owners.len);
    try std.testing.expectEqualStrings("world", contract.owners[0]);
    try std.testing.expectEqualStrings("field", contract.owners[1]);
    try std.testing.expectEqualStrings("party", contract.owners[2]);
    try std.testing.expectEqualStrings("battle", contract.owners[3]);

    for (contract.transitions) |row| {
        const from = std.meta.stringToEnum(control_draws_mod.Owner, row.from) orelse return error.UnknownOwner;
        const to = std.meta.stringToEnum(control_draws_mod.Owner, row.to) orelse return error.UnknownOwner;
        const actual = control_draws_mod.owners.transition(from, to) orelse return error.MissingTransition;
        try std.testing.expectEqualStrings(row.id, @tagName(actual));
        try std.testing.expectEqualStrings(row.reason, actual.reason());
        const policy = control_draws_mod.owners.policy(actual);
        try std.testing.expectEqual(row.retain_direction, policy.retain_direction);
        try std.testing.expectEqual(row.navigation_until_release, policy.block_navigation_until_release);
        try std.testing.expectEqual(row.withhold_same_advance_edges, policy.withhold_boundary_edges);
    }
    for (contract.unsupported_transitions) |row| {
        const from = std.meta.stringToEnum(control_draws_mod.Owner, row.from) orelse return error.UnknownOwner;
        const to = std.meta.stringToEnum(control_draws_mod.Owner, row.to) orelse return error.UnknownOwner;
        try std.testing.expect(control_draws_mod.owners.transition(from, to) == null);
    }
    // Reload is a router-level reset, not a source mode transition.
    try std.testing.expectEqual(control_draws_mod.Transition.none, control_draws_mod.owners.transition(.party, .party).?);
    // Every mirrored fact names an existing shared file and a hash.
    for (contract.facts) |fact| {
        try std.testing.expect(fact.line > 0);
        try std.testing.expectEqual(@as(usize, 64), fact.text_hash.len);
        try std.testing.expect(fact.statement.len > 0);
    }
    try std.testing.expectEqual(@as(usize, 34), contract.facts.len);
    try std.testing.expectEqual(@as(usize, 8), contract.transitions.len);
    try std.testing.expectEqual(@as(usize, 4), contract.unsupported_transitions.len);
}

test "the package does not import a shared owner" {
    for ([_][]const u8{ control_draws_mod.review.owners_source, control_draws_mod.review.router_source, control_draws_mod.review.draws_source, control_draws_mod.review.contract_source }) |source| {
        try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"world\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"field\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"battle\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"world_travel") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "@import(\"world_session_save") == null);
    }
}

// ---------------------------------------------------------------------------
// Logical draws: independent agreement with the Python derivation.
// ---------------------------------------------------------------------------

const VectorFile = struct {
    schema: []const u8,
    resources: []const struct {
        id: []const u8,
        kind: []const u8,
        schema: []const u8,
        sha256: []const u8,
        source: []const u8,
    },
    vectors: std.json.Value,
};

const Packets = struct {
    manifest: std.json.Parsed(control_draws_mod.draws.Manifest),
    resources: control_draws_mod.Resources,
    vectors: std.json.Parsed(VectorFile),
};

fn loadPackets() !Packets {
    var manifest = try control_draws_mod.loadManifest(std.testing.allocator);
    errdefer manifest.deinit();
    const resources = try control_draws_mod.resources(&manifest.value);
    const vectors = try std.json.parseFromSlice(VectorFile, std.testing.allocator, control_draws_mod.data.logical_draws_json, .{ .ignore_unknown_fields = true });
    return .{ .manifest = manifest, .resources = resources, .vectors = vectors };
}

test "the resource manifest is exactly the qualified eight" {
    var packets = try loadPackets();
    defer packets.manifest.deinit();
    defer packets.vectors.deinit();
    try std.testing.expectEqualStrings("suikoden-logical-draws/1", packets.vectors.value.schema);
    try std.testing.expectEqual(@as(usize, 8), packets.resources.count());
    const expected = [_][]const u8{
        "world.region_b.art",
        "world.region_b.map",
        "world.region_c.art",
        "world.region_c.map",
        "battle.region_b.data",
        "battle.region_c.data",
        "field.package",
        "party.catalogue",
    };
    for (expected, 0..) |id, index| {
        try std.testing.expectEqualStrings(id, packets.resources.list[index].id);
        try std.testing.expect(std.mem.eql(u8, &packets.resources.list[index].sha256, &std.mem.zeroes([32]u8)) == false);
        try std.testing.expectEqualStrings(id, packets.vectors.value.resources[index].id);
    }
    // The authored marker is declared unqualified and is not bindable.
    try std.testing.expectError(error.MissingDrawResource, packets.resources.require("field.authored_marker"));
}

test "world region B composition matches the independent Python digest" {
    var packets = try loadPackets();
    defer packets.manifest.deinit();
    defer packets.vectors.deinit();
    const art_bytes = try readTracked("game/assets/world_art_b.json");
    defer std.testing.allocator.free(art_bytes);
    const art = try view.load(std.testing.allocator, art_bytes);
    defer art.deinit();
    var travel = world.State{ .camera = .{ .x = 0, .y = 0 }, .heading = .east };
    var visual = view.State.init(art.value);
    var plan = control_draws_mod.Plan{};
    const resource = try packets.resources.require("world.region_b.art");
    try control_draws_mod.draws.composeWorld(&plan, &packets.resources, resource, art.value, travel, &visual);
    const vector = packets.vectors.value.vectors.object.get("world_initial").?.object;
    try std.testing.expectEqual(@as(u16, @intCast(vector.get("count").?.integer)), plan.len);
    try expectDigest(vector.get("digest").?.string, plan.digest(&packets.resources));
    // The first draw is the layer-0 water tile at the canvas origin and the
    // last is the hero pose, exactly as the shared view composes.
    try std.testing.expectEqual(control_draws_mod.Kind.world_tile, plan.entries[0].kind);
    try std.testing.expectEqual(@as(i32, 0), plan.entries[0].dx);
    try std.testing.expectEqual(@as(i32, 0), plan.entries[0].dy);
    try std.testing.expectEqual(control_draws_mod.Kind.world_pose, plan.entries[plan.len - 1].kind);
    try std.testing.expectEqual(@as(i32, 160), plan.entries[plan.len - 1].dx);
    try std.testing.expectEqual(@as(i32, 128), plan.entries[plan.len - 1].dy);
    _ = &travel;
}

test "world region C composition matches the independent Python digest" {
    var packets = try loadPackets();
    defer packets.manifest.deinit();
    defer packets.vectors.deinit();
    const art_bytes = try readTracked("game/assets/world_art_c.json");
    defer std.testing.allocator.free(art_bytes);
    const art = try view.load(std.testing.allocator, art_bytes);
    defer art.deinit();
    const travel = world.State{ .camera = .{ .x = 0, .y = 0 }, .heading = .east };
    var visual = view.State.init(art.value);
    var plan = control_draws_mod.Plan{};
    const resource = try packets.resources.require("world.region_c.art");
    try control_draws_mod.draws.composeWorld(&plan, &packets.resources, resource, art.value, travel, &visual);
    const vector = packets.vectors.value.vectors.object.get("world_c_initial").?.object;
    try std.testing.expectEqual(@as(u16, 601), plan.len);
    try expectDigest(vector.get("digest").?.string, plan.digest(&packets.resources));
}

test "field composition matches the independent Python digest" {
    var packets = try loadPackets();
    defer packets.manifest.deinit();
    defer packets.vectors.deinit();
    const fixture_bytes = try readTracked("game/tests/fixtures/journey_room.json");
    defer std.testing.allocator.free(fixture_bytes);
    const parsed = try field.load(std.testing.allocator, fixture_bytes);
    defer parsed.deinit();
    const package = parsed.value;
    const room_index = package.roomIndex("vb6_village").?;
    const room = package.rooms[room_index];
    const clip = package.player_clips[@backingInt(field.Direction.down)];
    const hero = clip.frames[clip.idle_frame];
    const position = .{ .x = 352.0, .y = 216.0 };
    const origin = field.cameraOffset(room.width, room.height, position.x, position.y);
    const resource = try packets.resources.require("field.package");
    const actors = [_]control_draws_mod.draws.Actor{.{
        .resource = resource,
        .rect = .{ .x = hero.rect.x, .y = hero.rect.y, .w = hero.rect.w, .h = hero.rect.h },
        .x = origin.x + position.x - @as(f32, @floatFromInt(hero.anchor_x)),
        .y = origin.y + position.y - @as(f32, @floatFromInt(hero.anchor_y)),
        .depth = position.y / 8.0,
        .qualified = true,
    }};
    var plan = control_draws_mod.Plan{};
    try control_draws_mod.draws.composeField(&plan, &packets.resources, resource, room, field.game_state.Story.initial, 0, origin.x, origin.y, &actors);
    const vector = packets.vectors.value.vectors.object.get("field_village").?.object;
    try std.testing.expectEqual(@as(u16, 56), plan.len);
    try expectDigest(vector.get("digest").?.string, plan.digest(&packets.resources));
    try std.testing.expectEqual(control_draws_mod.Kind.field_scene, plan.entries[0].kind);
    try std.testing.expectEqual(@as(i32, 0), plan.entries[0].dx);
    try std.testing.expectEqual(@as(i32, 24), plan.entries[0].dy);
    const vector_actor = vector.get("actor").?.object;
    var found_actor = false;
    for (plan.entries[0..plan.len]) |entry| {
        if (entry.kind != .field_actor) continue;
        found_actor = true;
        try std.testing.expectEqual(@as(i32, @intCast(vector_actor.get("dx").?.integer)), entry.dx);
        try std.testing.expectEqual(@as(i32, @intCast(vector_actor.get("dy").?.integer)), entry.dy);
        try std.testing.expectEqual(@as(i32, @intCast(vector_actor.get("depth").?.integer)), entry.depth);
    }
    try std.testing.expect(found_actor);
}

test "battle vector preserves quad order, light and shadow count" {
    var packets = try loadPackets();
    defer packets.manifest.deinit();
    defer packets.vectors.deinit();
    const vector = packets.vectors.value.vectors.object.get("battle_conformance").?.object;
    const quads_json = vector.get("quads").?.array;
    const Quad = struct { sprite: struct { rect: control_draws_mod.draws.Rect }, x: i32, y: i32, w: i32, h: i32, light: [3]u16 };
    var quads: [4]Quad = undefined;
    for (quads_json.items, 0..) |item, index| {
        const rect = item.object.get("src").?.object;
        quads[index] = .{
            .sprite = .{ .rect = .{
                .x = @intCast(rect.get("x").?.integer),
                .y = @intCast(rect.get("y").?.integer),
                .w = @intCast(rect.get("w").?.integer),
                .h = @intCast(rect.get("h").?.integer),
            } },
            .x = @intCast(item.object.get("dx").?.integer),
            .y = @intCast(item.object.get("dy").?.integer),
            .w = @intCast(item.object.get("dw").?.integer),
            .h = @intCast(item.object.get("dh").?.integer),
            .light = .{
                @intCast(item.object.get("light").?.array.items[0].integer),
                @intCast(item.object.get("light").?.array.items[1].integer),
                @intCast(item.object.get("light").?.array.items[2].integer),
            },
        };
    }
    const shadows = [_]u8{ 0, 0 };
    const list = .{ .shadows = &shadows, .quads = &quads, .length = 2 };
    var plan = control_draws_mod.Plan{};
    const resource = try packets.resources.require("battle.region_b.data");
    try control_draws_mod.draws.composeBattle(&plan, &packets.resources, resource, list);
    try std.testing.expectEqual(@as(u16, 2), plan.shadows);
    try std.testing.expectEqual(@as(u16, 2), plan.len);
    try std.testing.expectEqual(control_draws_mod.Kind.battle_quad, plan.entries[0].kind);
    try std.testing.expectEqual(@as([3]u16, .{ 120, 130, 140 }), plan.entries[0].light);
    try std.testing.expectEqual(@as([3]u16, .{ 200, 128, 64 }), plan.entries[1].light);
    try expectDigest(vector.get("digest").?.string, plan.digest(&packets.resources));
}

test "party logical frame is text rows and a screen tag" {
    var packets = try loadPackets();
    defer packets.manifest.deinit();
    defer packets.vectors.deinit();
    var plan = control_draws_mod.Plan{};
    try control_draws_mod.draws.composeParty(&plan, 1, 6);
    const vector = packets.vectors.value.vectors.object.get("party_root").?.object;
    try std.testing.expectEqual(@as(u16, 0), plan.len);
    try std.testing.expectEqual(@as(u16, 6), plan.text_rows);
    try expectDigest(vector.get("digest").?.string, plan.digest(&packets.resources));
}

// ---------------------------------------------------------------------------
// Reload equality: retained resources and the plan both survive a checkpoint.
// ---------------------------------------------------------------------------

test "a captured logical frame verifies after a JSON save/load round trip" {
    var packets = try loadPackets();
    defer packets.manifest.deinit();
    defer packets.vectors.deinit();
    var plan = control_draws_mod.Plan{};
    try control_draws_mod.draws.composeParty(&plan, 1, 6);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const saved = try control_draws_mod.DrawState.capture(arena.allocator(), 2, &plan, &packets.resources);
    const text = try std.json.Stringify.valueAlloc(arena.allocator(), saved, .{});
    const restored = try std.json.parseFromSlice(control_draws_mod.DrawState, arena.allocator(), text, .{});
    try restored.value.verify(&plan, &packets.resources);

    // A content revision substitution changes every binding and is refused.
    var changed = packets.resources;
    try changed.bindAllHex("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    try std.testing.expectError(error.DrawResourceMismatch, restored.value.verify(&plan, &changed));

    // A different logical frame with the same resource table is refused.
    var other = control_draws_mod.Plan{};
    try control_draws_mod.draws.composeParty(&other, 1, 5);
    try std.testing.expectError(error.DrawPlanMismatch, restored.value.verify(&other, &packets.resources));
}

test "a field plan captured before reload recomposes identically afterwards" {
    var packets = try loadPackets();
    defer packets.manifest.deinit();
    defer packets.vectors.deinit();
    const fixture_bytes = try readTracked("game/tests/fixtures/journey_room.json");
    defer std.testing.allocator.free(fixture_bytes);
    const parsed = try field.load(std.testing.allocator, fixture_bytes);
    defer parsed.deinit();
    const package = parsed.value;
    const room = package.rooms[package.roomIndex("vb6_village").?];
    const resource = try packets.resources.require("field.package");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var saved_state: ?control_draws_mod.DrawState = null;
    for (0..2) |reload| {
        var plan = control_draws_mod.Plan{};
        try control_draws_mod.draws.composeField(&plan, &packets.resources, resource, room, field.game_state.Story.initial, 0, 0, 24, &.{});
        if (reload == 0) {
            saved_state = try control_draws_mod.DrawState.capture(arena.allocator(), 1, &plan, &packets.resources);
        } else {
            try saved_state.?.verify(&plan, &packets.resources);
        }
    }
}

// ---------------------------------------------------------------------------
// Ordinary-control routing: walk/interact/menu/confirm/cancel/fight/return.
// ---------------------------------------------------------------------------

test "held confirm and Up never act in the next owner" {
    var router = control_draws_mod.Router{};
    // World: walk north into an entrance with Up and confirm held.
    var obs = control_draws_mod.Observation{ .travel_mode = .world };
    _ = router.begin(obs, .{ .direction = .up, .navigation = .up });
    _ = router.begin(obs, .{ .direction = .up, .navigation = .up, .confirm = true });
    try router.finish(obs, false);
    // The entrance completes: the field owner begins while both are held.
    obs = .{ .travel_mode = .field_pending };
    _ = router.begin(obs, .{ .direction = .up });
    try router.finish(obs, false);
    obs = .{ .travel_mode = .field };
    const entered = router.begin(obs, .{ .direction = .up, .navigation = .up, .confirm = true });
    try std.testing.expectEqual(control_draws_mod.Owner.field, entered.owner);
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, .up), entered.ui.direction);
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, null), entered.ui.menu_direction);
    try std.testing.expect(entered.withheld.navigation);
    // A confirm pressed at this boundary frame belongs to the new owner; the
    // held Up still cannot move the field dialogue cursor.
    try std.testing.expect(entered.ui.action);
    const still_held = router.begin(obs, .{ .direction = .up, .navigation = .up });
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, null), still_held.ui.menu_direction);
    try std.testing.expect(still_held.withheld.navigation);

    // Menu: the player opens the pause menu while Up is held; the menu must not
    // scroll on the retained direction.
    obs = .{ .travel_mode = .field, .menu_closed = false };
    try router.finish(obs, false);
    const menu = router.begin(obs, .{ .direction = .up, .navigation = .up });
    try std.testing.expectEqual(control_draws_mod.Owner.party, menu.owner);
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, null), menu.ui.menu_direction);
    // A fresh navigation after release is admitted.
    _ = router.begin(obs, .{});
    const menu_press = router.begin(obs, .{ .navigation = .down });
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, .down), menu_press.ui.menu_direction);

    // Battle: close the menu, return to the world and enter battle with Up
    // held; the repeat must not move the battle cursor.
    obs = .{ .travel_mode = .field };
    try router.finish(obs, false);
    obs = .{ .travel_mode = .world };
    try router.finish(obs, false);
    obs = .{ .travel_mode = .battle_pending };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    obs = .{ .travel_mode = .battle };
    _ = router.begin(obs, .{ .direction = .up });
    try router.finish(obs, false);
    const battle = router.begin(obs, .{ .direction = .up, .navigation = .up, .confirm = true });
    try std.testing.expectEqual(control_draws_mod.Owner.battle, battle.owner);
    try std.testing.expect(!battle.combat.up);
    try std.testing.expect(battle.withheld.navigation);
    // Battle return, then the world walk resumes only on the retained vector.
    obs = .{ .travel_mode = .world };
    try router.finish(obs, false);
    const returned = router.begin(obs, .{ .direction = .up, .navigation = .up });
    try std.testing.expectEqual(control_draws_mod.Owner.world, returned.owner);
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, .up), returned.world.direction);
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, null), returned.ui.menu_direction);
}

test "menu-opening frame cannot confirm its own first row" {
    var router = control_draws_mod.Router{};
    var obs = control_draws_mod.Observation{ .travel_mode = .field };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    // Menu and confirm arrive in one sampled frame.
    const opened = router.begin(obs, .{ .menu = true, .confirm = true });
    try std.testing.expect(opened.menu);
    try std.testing.expect(!opened.ui.action);
    try std.testing.expectEqual(control_draws_mod.Owner.party, opened.withheld.predicted_owner.?);
    // The menu owns the next frame; a fresh confirm is delivered there.
    obs = .{ .travel_mode = .field, .menu_closed = false };
    try router.finish(obs, false);
    const press = router.begin(obs, .{ .confirm = true });
    try std.testing.expect(press.ui.action);
}

test "boundary receipts record the route and stay bounded" {
    var router = control_draws_mod.Router{};
    var obs = control_draws_mod.Observation{ .travel_mode = .world };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    obs = .{ .travel_mode = .field_pending };
    _ = router.begin(obs, .{ .direction = .right });
    try router.finish(obs, false);
    obs = .{ .travel_mode = .field };
    _ = router.begin(obs, .{ .direction = .right });
    try router.finish(obs, false);
    const field_receipt = router.lastReceipt().?;
    try std.testing.expectEqual(control_draws_mod.Transition.world_to_field, field_receipt.transition);
    try std.testing.expectEqual(control_draws_mod.Owner.field, field_receipt.to);
    try std.testing.expect(field_receipt.direction_retained);
    try std.testing.expect(field_receipt.navigation_blocked);
    try std.testing.expectEqualStrings("field_entered", field_receipt.reason);
    // Menu open/close receipts.
    obs = .{ .travel_mode = .field, .menu_closed = false };
    _ = router.begin(obs, .{ .menu = true });
    try router.finish(obs, false);
    try std.testing.expectEqual(control_draws_mod.Transition.field_to_party, router.lastReceipt().?.transition);
    obs = .{ .travel_mode = .field };
    _ = router.begin(obs, .{ .cancel = true });
    try router.finish(obs, false);
    try std.testing.expectEqual(control_draws_mod.Transition.party_to_field, router.lastReceipt().?.transition);
    // Battle start and return.
    obs = .{ .travel_mode = .world };
    try router.finish(obs, false);
    _ = router.begin(obs, .{});
    obs = .{ .travel_mode = .battle_pending };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    obs = .{ .travel_mode = .battle };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    try std.testing.expectEqual(control_draws_mod.Transition.world_to_battle, router.lastReceipt().?.transition);
    obs = .{ .travel_mode = .world };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    try std.testing.expectEqual(control_draws_mod.Transition.battle_to_world, router.lastReceipt().?.transition);
    // Unsupported pairs are refused with the owner unchanged.
    obs = .{ .travel_mode = .battle };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    obs = .{ .travel_mode = .field };
    const refused = router.begin(obs, .{ .confirm = true });
    try std.testing.expectEqual(control_draws_mod.Owner.battle, refused.owner);
    try std.testing.expectEqual(control_draws_mod.Refusal.unadmitted_boundary, router.last_refusal.?);
}

test "a checkpoint restore requires a release before navigation" {
    var router = control_draws_mod.Router{};
    var obs = control_draws_mod.Observation{ .travel_mode = .world };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    obs = .{ .travel_mode = .world, .menu_closed = false };
    _ = router.begin(obs, .{ .menu = true });
    try router.finish(obs, false);
    // The load restores the world while the menu button is still held.
    router.reset(.{ .travel_mode = .world });
    try std.testing.expectEqual(control_draws_mod.Owner.world, router.ownerNow());
    const first = router.begin(.{ .travel_mode = .world }, .{ .direction = .down, .navigation = .down });
    try std.testing.expectEqual(control_draws_mod.Owner.world, first.owner);
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, .down), first.world.direction);
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, null), first.ui.menu_direction);
}

test "focus loss clears the frame and refuses a held edge" {
    var router = control_draws_mod.Router{};
    const obs = control_draws_mod.Observation{ .travel_mode = .field };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    const lost = router.begin(.{ .travel_mode = .field, .focused = false }, .{ .direction = .up, .navigation = .up, .confirm = true });
    try std.testing.expect(lost.empty());
    try std.testing.expectEqual(control_draws_mod.Refusal.focus_lost, router.last_refusal.?);
    const reopened = router.begin(obs, .{ .direction = .up, .navigation = .up });
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, .up), reopened.ui.direction);
    try std.testing.expectEqual(@as(?control_draws_mod.Direction, null), reopened.ui.menu_direction);
}
