//! Focused checks: source boarding guards and decline semantics,
//! water steering and the maelstrom guard, point dispatch, disembark/cleanup,
//! vessel lifetime and fresh-process pending/settled state.
const std = @import("std");
const boat_mod = @import("travel").boat;
const mode_result_mod = @import("campaign_policies").mode_result;
const event_runtime = @import("event_runtime");
const world = @import("world");

const allocator = std.testing.allocator;
const data = boat_mod.data;

fn read(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(data.max_json_bytes));
}

fn loadCatalogue() !std.json.Parsed(data.Packet) {
    const bytes = try read("game/assets/travel/water.json");
    defer allocator.free(bytes);
    return data.load(allocator, bytes);
}

fn factsFor(entry: data.Board) boat_mod.Facts {
    var facts = boat_mod.Facts{
        .story = .{},
        .recruitment_tier = 0,
        .hero_x = 0,
        .hero_y = 0,
        .pressed = 0,
        .upgrade_flag = false,
    };
    for (entry.predicate) |term| switch (term.kind) {
        .story_mask_set => facts.story.scenario[term.index] |= term.mask,
        .story_mask_clear => facts.story.scenario[term.index] &= ~term.mask,
        .hero_x_range => facts.hero_x = @divTrunc(@as(i32, term.lower) + @as(i32, term.upper), 2),
        .hero_y_range => facts.hero_y = @divTrunc(@as(i32, term.lower) + @as(i32, term.upper), 2),
        .input_mask => facts.pressed |= term.input,
    };
    return facts;
}

fn storyFor(kind: u8, packet: data.Packet, facts: *boat_mod.Facts) void {
    facts.recruitment_tier = 0;
    for (packet.point_rules) |rule| {
        if (rule.kind != kind) continue;
        for (rule.clauses) |clause| {
            if (clause.tier) |tier| facts.recruitment_tier = tier;
            if (clause.present) {
                facts.story.scenario[clause.story_index] |= clause.mask;
            } else {
                facts.story.scenario[clause.story_index] &= ~clause.mask;
            }
        }
        return;
    }
}

fn contentSha() !mode_result_mod.Sha {
    return mode_result_mod.Sha.initHex("439a166609dab8cde26249bd7661a835e4d55e79bb37a964761c981524e89d95");
}

fn baseStore() !mode_result_mod.Store {
    var store: mode_result_mod.Store = .{};
    store.party.count = 1;
    store.party.members[0] = .{
        .id = try mode_result_mod.Id.init("hero"),
        .hp = 10,
        .max_hp = 10,
        .level = 1,
        .weapon_level = 1,
    };
    store.story_bound = true;
    return store;
}

fn expectedFor(store: mode_result_mod.Store) !mode_result_mod.Expected {
    return .{
        .content_sha256 = try contentSha(),
        .revision = store.revision,
        .money = store.money,
        .roster = mode_result_mod.rosterDigest(store),
        .ledger = mode_result_mod.ledgerDigest(store),
        .story = mode_result_mod.storyDigest(store),
        .camera = store.camera,
        .receipt = store.receipts[0],
    };
}

fn sessionAt(entry_id: []const u8, camera: world.Point, heading: world.Direction, upgraded: bool) !boat_mod.Session {
    const vessel = boat_mod.Vessel{
        .entry_id = try mode_result_mod.Id.init(entry_id),
        .camera = camera,
        .heading = heading,
        .upgraded = upgraded,
    };
    return boat_mod.Session.begin(vessel, 1, .boat);
}

fn dispatchPoint(session: *boat_mod.Session, packet: data.Packet, camera: world.Point, facts: boat_mod.Facts) !data.Point {
    session.vessel.?.camera = camera;
    const step = try session.steer(packet, null, facts);
    return switch (step) {
        .point => |proposal| proposal.point,
        else => error.ExpectedPointDispatch,
    };
}

test "catalogue carries the exported source identity and reviewed digests" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    try std.testing.expectEqualStrings("suikoden-campaign-boat-water/1", packet.schema);
    try std.testing.expectEqualStrings("region_j_region_9", packet.id);
    try std.testing.expectEqual(@as(u8, 9), packet.region);
    try std.testing.expectEqual(@as(u16, 160), packet.water.width);
    try std.testing.expectEqual(@as(u16, 120), packet.water.height);
    try std.testing.expectEqual(@as(u16, 133), packet.water.threshold);
    try std.testing.expectEqualSlices(u16, &.{ 9, 4, 8, 7 }, &packet.water.probe.codes);
    try std.testing.expectEqualStrings("e1e363417ee8032ab395c356f719b93fd3a8552e97022a329c697f92b6d54da3", packet.water.codes_sha256);
    try std.testing.expectEqual(@as(usize, 37), packet.points.rows.len);
    try std.testing.expectEqualStrings("8d1ef51a82bc1c28f60bfb58ca951fae7a2b809ca59c2db116ad59c64d9950e8", packet.points.points_sha256);
    try std.testing.expectEqual(@as(usize, 5), packet.boards.len);
    try std.testing.expectEqual(@as(usize, 35), packet.anchors.len);
    try std.testing.expectEqual(@as(usize, 12), packet.point_rules.len);
    try std.testing.expect(packet.board("vb8_room0_entry0") != null);
    try std.testing.expect(packet.board("vd2_room0_entry17") != null);
    try std.testing.expect(packet.pointRule(1).?.always == false);
    try std.testing.expect(packet.pointRule(5).?.clauses.len == 2);
    try std.testing.expect(packet.pointRule(8) == null);
}

test "source board guards accept the exact window and reject each outside case" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const expected = try expectedFor(try baseStore());
    for (packet.boards) |entry| {
        const facts = factsFor(entry);
        var ledger: boat_mod.Ledger = .{};
        const outcome = try boat_mod.board(packet, &ledger, entry.id, "voyage_1", .foot, facts, .board, expected);
        try std.testing.expect(!outcome.declined);
        try std.testing.expect(outcome.vessel != null);
        try std.testing.expectEqual(@as(u64, 1), outcome.receipt);
        try std.testing.expectEqual(boat_mod.Mode.boat, outcome.mode_after.?);
        try std.testing.expectEqual(boat_mod.Mode.foot, outcome.mode_before);
        try std.testing.expect(outcome.result != null);
        const vessel = outcome.vessel.?;
        try std.testing.expectEqual(entry.board.camera_x, vessel.camera.x);
        try std.testing.expectEqual(entry.board.camera_y, vessel.camera.y);
        try std.testing.expectEqual(world.Direction.east, vessel.heading);
        for (entry.predicate) |term| {
            var broken = facts;
            switch (term.kind) {
                .story_mask_set => {
                    broken.story.scenario[term.index] &= ~term.mask;
                    try std.testing.expectError(error.StoryGuard, boat_mod.board(packet, &ledger, entry.id, "voyage_x", .foot, broken, .board, expected));
                },
                .story_mask_clear => {
                    broken.story.scenario[term.index] |= term.mask;
                    try std.testing.expectError(error.StoryGuard, boat_mod.board(packet, &ledger, entry.id, "voyage_x", .foot, broken, .board, expected));
                },
                .hero_x_range => {
                    broken.hero_x = @as(i32, term.upper) + 1;
                    try std.testing.expectError(error.PositionGuard, boat_mod.board(packet, &ledger, entry.id, "voyage_x", .foot, broken, .board, expected));
                    broken.hero_x = @as(i32, term.lower) - 1;
                    try std.testing.expectError(error.PositionGuard, boat_mod.board(packet, &ledger, entry.id, "voyage_x", .foot, broken, .board, expected));
                },
                .hero_y_range => {
                    broken.hero_y = @as(i32, term.upper) + 1;
                    try std.testing.expectError(error.PositionGuard, boat_mod.board(packet, &ledger, entry.id, "voyage_x", .foot, broken, .board, expected));
                },
                .input_mask => {
                    broken.pressed = 0;
                    try std.testing.expectError(error.InputGuard, boat_mod.board(packet, &ledger, entry.id, "voyage_x", .foot, broken, .board, expected));
                },
            }
        }
    }
    const vb2 = packet.board("vb2_room0_entry8").?;
    try std.testing.expectEqual(@as(usize, 4), vb2.predicate.len);
}

test "decline follows each source event: VB8 keeps boat mode, the others publish nothing" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const expected = try expectedFor(try baseStore());
    var ledger: boat_mod.Ledger = .{};
    var declines: usize = 0;
    for (packet.boards) |entry| {
        const facts = factsFor(entry);
        const outcome = try boat_mod.board(packet, &ledger, entry.id, "voyage_decline", .foot, facts, .decline, expected);
        try std.testing.expect(outcome.declined);
        try std.testing.expect(outcome.vessel == null);
        try std.testing.expect(outcome.result == null);
        try std.testing.expectEqual(expected.receipt, outcome.receipt);
        if (entry.pre_choice_mode_write) {
            try std.testing.expectEqual(boat_mod.Mode.boat, outcome.mode_after.?);
            try std.testing.expectEqualStrings("vb8_room0_entry0", entry.id);
        } else {
            try std.testing.expect(outcome.mode_after == null);
            declines += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), declines);
    try std.testing.expect(packet.board("vb8_room0_entry0").?.decline.world_mode.? == 1);
}

test "board publishes a real travel_board result through the mode-result host" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const content = try contentSha();
    const store = try baseStore();
    var ledger: boat_mod.Ledger = .{};
    const vb8 = packet.board("vb8_room0_entry0").?;
    const outcome = try boat_mod.board(packet, &ledger, vb8.id, "voyage_1", .foot, factsFor(vb8), .board, try expectedFor(store));
    var host = try mode_result_mod.Host.init(store, content);
    try host.begin(outcome.result.?);
    const committed = try host.commit();
    try std.testing.expectEqual(@as(u64, 1), committed.receipt);
    try std.testing.expectEqual(mode_result_mod.Place.world, host.store.camera.place);
    try std.testing.expectEqual(@as(i32, 36), host.store.camera.x);
    try std.testing.expectEqual(@as(i32, 59), host.store.camera.y);
    try std.testing.expectEqual(mode_result_mod.Facing.east, host.store.camera.facing);
    try std.testing.expectEqual(@as(u64, 1), host.store.receipts[0]);
    // A replayed result is refused by its stale before-facts before any mutation.
    try std.testing.expectError(error.StaleRevision, host.begin(outcome.result.?));
    const session = outcome.session().?;
    try std.testing.expectEqual(boat_mod.Mode.boat, session.world_mode);
    try std.testing.expectEqual(@as(u64, 1), session.receipt);
}

test "stale expected before-facts are refused before any mutation" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const vb8 = packet.board("vb8_room0_entry0").?;
    var ledger: boat_mod.Ledger = .{};
    const expected = try expectedFor(try baseStore());
    const outcome = try boat_mod.board(packet, &ledger, vb8.id, "voyage_1", .foot, factsFor(vb8), .board, expected);
    try std.testing.expectEqual(@as(u64, 1), outcome.receipt);
    var host = try mode_result_mod.Host.init(try baseStore(), try contentSha());
    var stale_receipt = outcome.result.?;
    stale_receipt.receipt = 5;
    stale_receipt.expected.receipt = 4;
    try std.testing.expectError(error.StaleReceipt, host.begin(stale_receipt));
    var stale_camera = outcome.result.?;
    stale_camera.expected.camera = .{ .x = 1, .y = 1, .facing = .south, .place = .world };
    try std.testing.expectError(error.StaleCamera, host.begin(stale_camera));
    try std.testing.expect(host.pending == null);
    try host.begin(outcome.result.?);
    try std.testing.expect(host.pending != null);
}

test "steering uses source water codes, the shared resolver and the 16-frame clock" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const facts: boat_mod.Facts = .{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
    var session = try sessionAt("voyage_1", .{ .x = 36, .y = 59 }, .east, false);
    try std.testing.expectEqual(boat_mod.Probe.pass, boat_mod.probeWater(packet, .{ .x = 36, .y = 59 }, .east, false));
    try std.testing.expectEqual(boat_mod.Probe.pass, boat_mod.probeWater(packet, .{ .x = 36, .y = 59 }, .south, false));
    try std.testing.expectEqual(boat_mod.Probe.blocked, boat_mod.probeWater(packet, .{ .x = 107, .y = 18 }, .north, false));
    const first = try session.steer(packet, .east, facts);
    try std.testing.expect(first == .none);
    try std.testing.expectEqual(@as(i32, 37), session.vessel.?.camera.x);
    try std.testing.expectEqual(@as(u8, 15), session.vessel.?.remaining);
    _ = try session.steer(packet, .north, facts);
    try std.testing.expectEqual(@as(i32, 37), session.vessel.?.camera.x);
    try std.testing.expectEqual(@as(i32, 59), session.vessel.?.camera.y);
    try std.testing.expectEqual(@as(u8, 14), session.vessel.?.remaining);
    var ticks: u8 = 0;
    while (session.vessel.?.remaining > 0) : (ticks += 1) _ = try session.steer(packet, null, facts);
    try std.testing.expectEqual(@as(u8, 14), ticks);
    _ = try session.steer(packet, .north, facts);
    try std.testing.expectEqual(@as(i32, 58), session.vessel.?.camera.y);
    try std.testing.expectEqual(world.Direction.north, session.vessel.?.heading);
}

test "normal and upgraded guards choose the maelstrom or the special cell" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const facts = boat_mod.Facts{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
    var normal = try sessionAt("voyage_normal", .{ .x = 48, .y = 17 }, .east, false);
    const normal_step = try normal.steer(packet, .south, facts);
    try std.testing.expectEqual(boat_mod.WarningStage.initial, normal_step.warning);
    try std.testing.expectEqual(boat_mod.Probe.conditional, boat_mod.probeWater(packet, .{ .x = 48, .y = 17 }, .south, false));
    // The special cell is refused; the shared resolver falls back to the
    // current east heading, exactly like ordinary walking into a blocked cell.
    try std.testing.expectEqual(@as(i32, 49), normal.vessel.?.camera.x);
    try std.testing.expectEqual(@as(i32, 17), normal.vessel.?.camera.y);
    try std.testing.expectEqual(world.Direction.east, normal.vessel.?.heading);
    try std.testing.expectEqual(@as(u8, 2), normal.vessel.?.spriteSlot(packet));

    var upgraded = try sessionAt("voyage_upgraded", .{ .x = 48, .y = 17 }, .east, true);
    const upgraded_step = try upgraded.steer(packet, .south, facts);
    try std.testing.expect(upgraded_step == .none);
    try std.testing.expectEqual(boat_mod.Probe.pass, boat_mod.probeWater(packet, .{ .x = 48, .y = 17 }, .south, true));
    try std.testing.expectEqual(@as(i32, 18), upgraded.vessel.?.camera.y);
    try std.testing.expectEqual(world.Direction.south, upgraded.vessel.?.heading);
    try std.testing.expectEqual(@as(u8, 4), upgraded.vessel.?.spriteSlot(packet));

    // The window lifecycle is host-driven and blocks movement until closed.
    while (normal.vessel.?.remaining > 0) _ = try normal.steer(packet, null, facts);
    const blocked = try normal.steer(packet, .east, facts);
    try std.testing.expectEqual(boat_mod.WarningStage.initial, blocked.warning);
    try std.testing.expectEqual(boat_mod.WarningStage.opening, try normal.advanceWarning(.{}));
    try std.testing.expectEqual(boat_mod.WarningStage.opening, try normal.advanceWarning(.{}));
    try std.testing.expectEqual(boat_mod.WarningStage.waiting, try normal.advanceWarning(.{ .opened = true }));
    try std.testing.expectEqual(boat_mod.WarningStage.waiting, try normal.advanceWarning(.{}));
    try std.testing.expectEqual(boat_mod.WarningStage.closing, try normal.advanceWarning(.{ .confirm = true }));
    try std.testing.expectEqual(boat_mod.WarningStage.closing, try normal.advanceWarning(.{}));
    try std.testing.expectEqual(boat_mod.WarningStage.closed, try normal.advanceWarning(.{ .closed = true }));
    try std.testing.expectEqual(boat_mod.WarningStage.none, try normal.advanceWarning(.{}));
    try std.testing.expectEqual(boat_mod.WarningStage.initial, (try normal.steer(packet, .south, facts)).warning);
}

test "point dispatch selects source rows in order and refuses a missing destination" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const facts: boat_mod.Facts = .{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };

    // Kind 0 is unconditional: all five reviewed disembark anchors dispatch.
    const anchors = [_]struct { camera: world.Point, id: []const u8 }{
        .{ .camera = .{ .x = 44, .y = 95 }, .id = "region_j_point_05" },
        .{ .camera = .{ .x = 35, .y = 57 }, .id = "region_j_point_03" },
        .{ .camera = .{ .x = 118, .y = 73 }, .id = "region_j_point_01" },
        .{ .camera = .{ .x = 47, .y = 11 }, .id = "region_j_point_02" },
        .{ .camera = .{ .x = 107, .y = 18 }, .id = "region_j_point_00" },
    };
    for (anchors) |anchor| {
        var fresh = try sessionAt("voyage_anchor", anchor.camera, .east, false);
        const point = try dispatchPoint(&fresh, packet, anchor.camera, facts);
        try std.testing.expectEqualStrings(anchor.id, point.id);
        try std.testing.expectEqual(boat_mod.Status.awaiting_point, fresh.status);
        try std.testing.expectEqual(@as(u16, 0), point.room);
    }

    // Tier/story-gated rows share the (99,73) anchor; source order picks first.
    // Kind 4 has no source row; tier 4 with story_0030 bit 1 reaches the kind 5
    // row first.  Expected ids keep the source row identity rather than the
    // compacted array index.
    const gated = [_]struct { tier: u8, story_index: u8, mask: u8, expected: []const u8 }{
        .{ .tier = 4, .story_index = 30, .mask = 1, .expected = "region_j_point_16" },
        .{ .tier = 3, .story_index = 29, .mask = 0x80, .expected = "region_j_point_16" },
        .{ .tier = 2, .story_index = 29, .mask = 0x40, .expected = "region_j_point_24" },
        .{ .tier = 1, .story_index = 29, .mask = 0x20, .expected = "region_j_point_32" },
        .{ .tier = 0, .story_index = 29, .mask = 0x20, .expected = "region_j_point_04" },
        .{ .tier = 0, .story_index = 29, .mask = 0, .expected = "region_j_point_44" },
        .{ .tier = 2, .story_index = 29, .mask = 0, .expected = "region_j_point_45" },
        .{ .tier = 3, .story_index = 29, .mask = 0, .expected = "region_j_point_46" },
        .{ .tier = 4, .story_index = 30, .mask = 0, .expected = "region_j_point_47" },
    };
    for (gated) |entry| {
        var gated_facts = facts;
        gated_facts.recruitment_tier = entry.tier;
        gated_facts.story.scenario[entry.story_index] |= entry.mask;
        var fresh = try sessionAt("voyage_gated", .{ .x = 0, .y = 0 }, .east, false);
        fresh.vessel.?.camera = .{ .x = 99, .y = 73 };
        const step = try fresh.steer(packet, null, gated_facts);
        switch (step) {
            .point => |proposal| try std.testing.expectEqualStrings(entry.expected, proposal.point.id),
            else => return error.ExpectedPointDispatch,
        }
    }

    // Kind 1 never dispatches; it is the reject handler.
    var reject_facts = facts;
    reject_facts.story.scenario[17] |= 0x01;
    try std.testing.expect(!packet.pointKindMatches(1, reject_facts.recruitment_tier, &reject_facts.story.scenario));
    try std.testing.expect(packet.pointKindMatches(0, 0, &reject_facts.story.scenario));

    // A synthetic row with no destination refuses instead of teleporting.
    const broken_bytes = try read("game/assets/travel/water.json");
    defer allocator.free(broken_bytes);
    var broken = try data.load(allocator, broken_bytes);
    defer broken.deinit();
    const rows = try allocator.dupe(data.Point, broken.value.points.rows);
    defer allocator.free(rows);
    rows[0].destination = null;
    var broken_packet = broken.value;
    broken_packet.points.rows = rows;
    var refusal = try sessionAt("voyage_refuse", .{ .x = 107, .y = 18 }, .east, false);
    try std.testing.expectError(error.UnsupportedPointDestination, refusal.steer(broken_packet, null, facts));
    try std.testing.expectEqual(boat_mod.Status.underway, refusal.status);
}

test "disembark publishes the field camera and keeps heading and field facing apart" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const content = try contentSha();
    const facts: boat_mod.Facts = .{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
    var store = try baseStore();
    store.receipts[0] = 1;
    store.camera = .{ .x = 44, .y = 95, .facing = .north, .place = .world };
    var host = try mode_result_mod.Host.init(store, content);
    var ledger: boat_mod.Ledger = .{};
    var session = try sessionAt("voyage_1", .{ .x = 0, .y = 0 }, .east, false);
    session.vessel.?.heading = .north;
    _ = try dispatchPoint(&session, packet, .{ .x = 44, .y = 95 }, facts);
    const point = packet.points.rows[session.pending.?.point_index];
    try std.testing.expectEqualStrings("vd2", point.destination.?);
    const result = try session.disembark(packet, try expectedFor(store), 2, facts);
    try std.testing.expectEqual(@as(u8, 2), result.saved_field_facing);
    try std.testing.expectEqual(mode_result_mod.Facing.west, result.field_facing);
    try std.testing.expectEqual(world.Direction.north, result.vessel.heading);
    try std.testing.expectEqual(boat_mod.Mode.boat, session.world_mode);
    try std.testing.expectEqual(boat_mod.Mode.foot, result.cleanup.world_mode);
    try std.testing.expectEqual(@as(u8, 255), result.cleanup.selector);
    try std.testing.expectEqual(@as(u8, 0), result.field.room);
    try std.testing.expectEqual(@as(u16, 696), result.field.spawn_x);
    try std.testing.expectEqual(@as(u16, 240), result.field.spawn_y);
    try std.testing.expectEqualStrings("vd2", result.field.destination);

    try host.begin(result.result);
    const committed = try host.commit();
    try std.testing.expectEqual(@as(u64, 2), committed.receipt);
    try std.testing.expectEqual(mode_result_mod.Place.field, host.store.camera.place);
    try std.testing.expectEqual(@as(i32, 696), host.store.camera.x);
    try std.testing.expectEqual(@as(i32, 240), host.store.camera.y);
    try std.testing.expectEqual(mode_result_mod.Facing.west, host.store.camera.facing);

    const settled = try session.settleCleanup(&ledger, result.receipt);
    try std.testing.expectEqual(boat_mod.Mode.foot, settled.world_mode);
    try std.testing.expectEqual(@as(u8, 255), settled.selector);
    try std.testing.expect(ledger.contains(result.entry_id));
    try std.testing.expectEqual(@as(u64, 2), ledger.settled_receipt);
    try std.testing.expectEqual(boat_mod.Status.settled, session.status);
    try std.testing.expect(session.vessel == null);
    try std.testing.expectError(error.NoFieldEntryPending, session.settleCleanup(&ledger, result.receipt));
    try std.testing.expectError(error.VesselNotAboard, session.steer(packet, .east, facts));
}

test "disembark and cleanup refuse stale facts and receipts before mutating" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const facts: boat_mod.Facts = .{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
    var store = try baseStore();
    store.receipts[0] = 1;
    store.camera = .{ .x = 44, .y = 95, .facing = .east, .place = .world };
    var ledger: boat_mod.Ledger = .{};
    var session = try sessionAt("voyage_1", .{ .x = 0, .y = 0 }, .east, false);
    try std.testing.expectError(error.NoPointPending, session.disembark(packet, try expectedFor(store), 0, facts));
    _ = try dispatchPoint(&session, packet, .{ .x = 44, .y = 95 }, facts);
    var expected = try expectedFor(store);
    expected.receipt = 5;
    try std.testing.expectError(error.StaleReceipt, session.disembark(packet, expected, 0, facts));
    expected = try expectedFor(store);
    expected.camera.x = 45;
    try std.testing.expectError(error.StaleCamera, session.disembark(packet, expected, 0, facts));
    expected = try expectedFor(store);
    var changed = facts;
    changed.story.scenario[0] = 1;
    try std.testing.expectError(error.StaleStory, session.disembark(packet, expected, 0, changed));
    try std.testing.expectError(error.InvalidFieldFacing, session.disembark(packet, expected, 4, facts));
    expected = try expectedFor(store);
    expected.pending_owner = .battle;
    try std.testing.expectError(error.StalePendingOwner, session.disembark(packet, expected, 0, facts));
    // A failed proposal does not consume the point.
    const result = try session.disembark(packet, try expectedFor(store), 0, facts);
    try std.testing.expectError(error.InvalidTravelReceipt, session.settleCleanup(&ledger, result.receipt + 1));
    _ = try session.settleCleanup(&ledger, result.receipt);
}

test "an old vessel snapshot cannot resurrect a boat after foot cleanup" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const facts: boat_mod.Facts = .{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
    var store = try baseStore();
    store.receipts[0] = 1;
    store.camera = .{ .x = 44, .y = 95, .facing = .east, .place = .world };
    var ledger: boat_mod.Ledger = .{};
    var session = try sessionAt("voyage_1", .{ .x = 0, .y = 0 }, .east, false);
    _ = try dispatchPoint(&session, packet, .{ .x = 44, .y = 95 }, facts);
    const pending_bytes = try session.encode(allocator, packet);
    defer allocator.free(pending_bytes);
    const result = try session.disembark(packet, try expectedFor(store), 1, facts);
    _ = try session.settleCleanup(&ledger, result.receipt);

    try std.testing.expectError(error.VesselExpiredAfterCleanup, boat_mod.restoreSession(allocator, &ledger, pending_bytes, packet));
    const settled_bytes = try session.encode(allocator, packet);
    defer allocator.free(settled_bytes);
    var settled = try boat_mod.restoreSession(allocator, &ledger, settled_bytes, packet);
    defer settled.deinit();
    try std.testing.expectEqual(boat_mod.Status.settled, settled.session.status);
    try std.testing.expect(settled.session.vessel == null);
}

test "a fresh process restores pending and settled state exactly once" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const content = try contentSha();
    const facts: boat_mod.Facts = .{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
    var store = try baseStore();
    store.receipts[0] = 1;
    store.camera = .{ .x = 44, .y = 95, .facing = .east, .place = .world };
    const ledger: boat_mod.Ledger = .{};
    var session = try sessionAt("voyage_1", .{ .x = 0, .y = 0 }, .east, false);
    _ = try dispatchPoint(&session, packet, .{ .x = 44, .y = 95 }, facts);
    const pending_checkpoint = try boat_mod.saveFresh(allocator, ledger, session, packet);
    defer allocator.free(pending_checkpoint);

    var fresh = try boat_mod.loadFresh(allocator, pending_checkpoint, packet);
    defer fresh.deinit();
    try std.testing.expectEqual(boat_mod.Status.awaiting_point, fresh.session.status);
    var restored = fresh.session;
    const result = try restored.disembark(packet, try expectedFor(store), 3, facts);
    const settled = try restored.settleCleanup(&fresh.ledger, result.receipt);
    try std.testing.expectEqual(@as(u64, 2), settled.receipt);
    const settled_checkpoint = try boat_mod.saveFresh(allocator, fresh.ledger, restored, packet);
    defer allocator.free(settled_checkpoint);

    var reloaded = try boat_mod.loadFresh(allocator, settled_checkpoint, packet);
    defer reloaded.deinit();
    try std.testing.expectEqual(boat_mod.Status.settled, reloaded.session.status);
    try std.testing.expect(reloaded.session.vessel == null);
    try std.testing.expectEqual(boat_mod.Mode.foot, reloaded.session.world_mode);
    try std.testing.expectEqual(@as(u8, 255), reloaded.session.selector);
    try std.testing.expect(reloaded.ledger.contains(result.entry_id));
    var cannot = reloaded.session;
    try std.testing.expectError(error.VesselNotAboard, cannot.steer(packet, .east, facts));

    // The pre-cleanup checkpoint is refused against the settled ledger.
    try std.testing.expectError(error.VesselExpiredAfterCleanup, boat_mod.validateAgainst(&fresh.ledger, session, packet));
    var host_page = try boat_mod.loadFresh(allocator, pending_checkpoint, packet);
    defer host_page.deinit();
    host_page.ledger = fresh.ledger;
    try std.testing.expectError(error.VesselExpiredAfterCleanup, boat_mod.validateAgainst(&host_page.ledger, host_page.session, packet));
    _ = content;
}

test "reboarding is a new source invocation and the retired identity is refused" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    const facts: boat_mod.Facts = .{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
    var store = try baseStore();
    store.receipts[0] = 1;
    store.camera = .{ .x = 44, .y = 95, .facing = .east, .place = .world };
    var ledger: boat_mod.Ledger = .{};
    var session = try sessionAt("voyage_1", .{ .x = 0, .y = 0 }, .east, false);
    _ = try dispatchPoint(&session, packet, .{ .x = 44, .y = 95 }, facts);
    const result = try session.disembark(packet, try expectedFor(store), 0, facts);
    _ = try session.settleCleanup(&ledger, result.receipt);
    store.receipts[0] = result.receipt;
    store.camera = .{ .x = 36, .y = 59, .facing = .east, .place = .world };
    const vb8 = packet.board("vb8_room0_entry0").?;
    try std.testing.expectError(error.EntryRetired, boat_mod.board(packet, &ledger, vb8.id, "voyage_1", .foot, factsFor(vb8), .board, try expectedFor(store)));
    const second = try boat_mod.board(packet, &ledger, vb8.id, "voyage_2", .foot, factsFor(vb8), .board, try expectedFor(store));
    try std.testing.expectEqual(@as(u64, 3), second.receipt);
    try std.testing.expect(second.session() != null);
    try std.testing.expectEqual(world.Direction.east, second.vessel.?.heading);
    try std.testing.expectEqual(@as(u8, 2), second.vessel.?.spriteSlot(packet));
    var host = try mode_result_mod.Host.init(store, try contentSha());
    try host.begin(second.result.?);
    _ = try host.commit();
    try std.testing.expectEqual(@as(u64, 3), host.store.receipts[0]);
}

test "point predicate clauses mirror the reviewed tier and story model" {
    const catalogue = try loadCatalogue();
    defer catalogue.deinit();
    const packet = catalogue.value;
    var facts: boat_mod.Facts = .{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
    try std.testing.expect(packet.pointKindMatches(0, 0, &facts.story.scenario));
    try std.testing.expect(!packet.pointKindMatches(1, 0, &facts.story.scenario));
    // kind 2 is true when scenario_0017 bit 0 is clear
    try std.testing.expect(packet.pointKindMatches(2, 0, &facts.story.scenario));
    facts.story.scenario[17] = 1;
    try std.testing.expect(!packet.pointKindMatches(2, 0, &facts.story.scenario));
    // kind 5 ORs two tier/story clauses
    var kind5 = boat_mod.Facts{ .story = .{}, .recruitment_tier = 3, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
    try std.testing.expect(!packet.pointKindMatches(5, 3, &kind5.story.scenario));
    kind5.story.scenario[29] = 0x80;
    try std.testing.expect(packet.pointKindMatches(5, 3, &kind5.story.scenario));
    kind5.recruitment_tier = 4;
    kind5.story.scenario[29] = 0;
    kind5.story.scenario[30] = 1;
    try std.testing.expect(packet.pointKindMatches(5, 4, &kind5.story.scenario));
    // The four tier-gated kinds share one anchor; source order selects first.
    for (packet.point_rules) |rule| {
        if (rule.always) |value| {
            try std.testing.expect(value == (rule.kind == 0));
            continue;
        }
        var probe = boat_mod.Facts{ .story = .{}, .recruitment_tier = 0, .hero_x = 0, .hero_y = 0, .pressed = 0, .upgrade_flag = false };
        storyFor(rule.kind, packet, &probe);
        try std.testing.expect(packet.pointKindMatches(rule.kind, probe.recruitment_tier, &probe.story.scenario));
    }
}
