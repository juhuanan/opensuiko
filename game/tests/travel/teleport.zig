//! Teleport focused checks: the Viki destination list, its admission,
//! unlock/payment/item boundaries and the source arrival plans, all through the
//! one shared handler.  No original instruction executes and no game window or
//! media is touched; the data is the static export in
//! `game/assets/travel/`.

const std = @import("std");
const teleport_mod = @import("travel").teleport;
const data = @import("travel_data").teleport;
const event = @import("event_runtime");

const allocator = std.testing.allocator;
const content_sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn load() !teleport_mod.catalogue.Loaded {
    return teleport_mod.catalogue.load(allocator, data.viki_json, data.mirror_json);
}

fn allUnlocked() event.StoryState {
    var story: event.StoryState = .{};
    story.scenario[39] = 0xFF;
    story.scenario[40] = 0xFF;
    story.scenario[41] = 0xFF;
    story.scenario[42] = 0xFF;
    story.scenario[43] = 0x1F;
    return story;
}

fn storyWith(byte_index: u8, mask: u8) event.StoryState {
    var story: event.StoryState = .{};
    story.scenario[byte_index] = mask;
    return story;
}

fn entry(id: []const u8, receipt: u64, story: event.StoryState) teleport_mod.Entry {
    return .{
        .entry_id = id,
        .content_sha256 = content_sha,
        .receipt = receipt,
        .money = 1500,
        .story = story,
        .world_mode = 1,
    };
}

fn itemEntry(id: []const u8, item_id: u16, story: event.StoryState) teleport_mod.Entry {
    var value = entry(id, 1, story);
    value.item = .{ .item_id = item_id, .slot = 3, .present = true, .owner = "hero" };
    return value;
}

const viki_request = teleport_mod.Request{
    .kind = .viki_event,
    .selector = 0xFF,
    .index = 3,
    .callback = 0x800136B4,
    .request_entry = 0x800136B4,
    .room = 2,
};

fn mirrorRequest(item_id: u16) teleport_mod.Request {
    return .{ .kind = .item_use, .item_id = item_id, .handler = if (item_id == 81) 13 else 12, .slot = 3 };
}

/// The source arrival this pack derives for Great Forest (VB6, region 1 point 5)
/// is also the retained point used by the Escape Talisman test.
fn greatForest() teleport_mod.RetainedPoint {
    return .{
        .region = 1,
        .point = 5,
        .area = "DATA/02_AREA.B/VB6.BIN",
        .room = 0,
        .source_spawn = .{ .x = 33, .y = 43 },
        .spawn = .{ .x = 264, .y = 344 },
    };
}

test "the catalogue validates, carries 37 source destinations and three families" {
    var loaded = try load();
    defer loaded.deinit();
    const viki = loaded.viki.value;
    const mirror = loaded.mirror.value;
    try std.testing.expectEqual(@as(usize, 37), viki.destinations.len);
    try std.testing.expectEqualStrings("Seika", viki.destinations[0].name);
    try std.testing.expectEqualStrings("Great Forest", viki.destinations[4].name);
    try std.testing.expectEqualStrings("Mt. Tigerwolf", viki.destinations[36].name);
    try std.testing.expectEqualStrings("DATA/02_AREA.B/VB1.BIN", viki.destinations[0].arrival.area);
    try std.testing.expectEqualStrings("DATA/02_AREA.B/VB6.BIN", viki.destinations[4].arrival.area);
    try std.testing.expectEqual(@as(u8, 0x1B6 - 0x190), teleport_mod.escape_scenario_byte);
    try std.testing.expectEqual(@as(usize, 2), mirror.items.len);
    try std.testing.expectEqual(@as(usize, 5), mirror.tiers.len);
    try std.testing.expectEqualStrings("DATA/02_AREA.B/VB7A.BIN", mirror.tiers[0].area);
    try std.testing.expectEqualStrings("DATA/02_AREA.B/VB5CG.BIN", mirror.tiers[3].area);
    try std.testing.expectEqualStrings(mirror.tiers[3].area, mirror.tiers[4].area);
    const blinking = mirror.itemById(81).?;
    const escape = mirror.itemById(73).?;
    try std.testing.expectEqual(@as(u8, 13), blinking.handler);
    try std.testing.expectEqual(@as(u8, 1), blinking.gate.world_mode_required);
    try std.testing.expectEqual(@as(u8, 12), escape.handler);
    try std.testing.expectEqual(@as(u8, 0), escape.gate.world_mode_required);
    try std.testing.expectEqual(teleport_mod.escape_scenario_byte, escape.gate.extra.?.scenario_byte);
    try std.testing.expectEqual(@as(u8, 2), escape.gate.extra.?.mask);
    // The static write audit is part of the packet: the admitted Viki/mirror
    // paths write only transition fields, never money or inventory.
    try std.testing.expectEqual(@as(usize, 14), mirror.write_audit.stores.len);
    for (mirror.write_audit.stores) |store| {
        const allowed = store.offset == 0 or store.offset == 1 or store.offset == 2 or
            store.offset == 4 or store.offset == 6 or store.offset == 0x1BB8 or
            store.offset == 0x1BBC or store.offset == 0x35 or store.offset == 0x38;
        try std.testing.expect(allowed);
    }
}

test "a tampered digest or witness is refused before any session opens" {
    var loaded = try load();
    defer loaded.deinit();
    var viki = loaded.viki.value;
    viki.content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.InvalidVikiDigest, viki.validate());
    var bad_witness = loaded.viki.value.witnesses[0];
    bad_witness.table_matches_primary = false;
    var bad_witnesses = [_]teleport_mod.catalogue.Witness{bad_witness};
    var witnesses = loaded.viki.value;
    witnesses.witnesses = &bad_witnesses;
    try std.testing.expectError(error.InvalidVikiWitness, witnesses.validate());
    var mirror = loaded.mirror.value;
    mirror.content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.InvalidMirrorDigest, mirror.validate());
}

test "locked destinations are absent from the list and cannot be confirmed" {
    var loaded = try load();
    defer loaded.deinit();
    const story = storyWith(39, 0x01);
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, entry("viki_entry", 1, story));
    var buffer: [teleport_mod.catalogue.max_destinations]u8 = undefined;
    const list = session.eligible(&buffer);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(u8, 0), list[0]);
    try std.testing.expectError(error.LockedDestination, session.confirmViki(1));
    try std.testing.expectError(error.LockedDestination, session.confirmViki(4));
    try std.testing.expectError(error.UnknownDestination, session.confirmViki(99));
    const proposal = try session.confirmViki(0);
    try std.testing.expectEqualStrings("Seika", proposal.plan.name);
    try std.testing.expectEqualStrings("viki_destination_00", proposal.plan.destination_id);
    try std.testing.expectEqual(teleport_mod.ResultKind.travel_teleport, proposal.plan.result_kind);
    try std.testing.expectEqualStrings("viki_us_11", proposal.plan.result_entry_id);
}

test "the eligible list keeps source order and only unlocked bits" {
    var loaded = try load();
    defer loaded.deinit();
    var story = storyWith(39, 0x01 | 0x04);
    story.scenario[41] = 0x20;
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, entry("viki_entry", 1, story));
    var buffer: [teleport_mod.catalogue.max_destinations]u8 = undefined;
    const list = session.eligible(&buffer);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(u8, 0), list[0]);
    try std.testing.expectEqual(@as(u8, 2), list[1]);
    try std.testing.expectEqual(@as(u8, 21), list[2]);
    try std.testing.expectEqualStrings("Kouan", loaded.viki.value.destinations[list[1]].name);
    try std.testing.expectEqualStrings("Neclord's Castle", loaded.viki.value.destinations[list[2]].name);
}

test "the list is a nine-row page with source clamp rules" {
    var loaded = try load();
    defer loaded.deinit();
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, entry("viki_entry", 1, allUnlocked()));
    try std.testing.expectEqual(@as(usize, 37), session.visibleCount());
    // The source refuses a tenth row; the page only moves on left/right.
    for (0..12) |_| _ = try session.tick(.down);
    try std.testing.expectEqual(@as(u8, 8), session.row);
    // Right advances to the next page and keeps the row while the page is full.
    try std.testing.expectEqual(teleport_mod.Event.none, try session.tick(.right));
    try std.testing.expectEqual(@as(u8, 1), session.page);
    try std.testing.expectEqual(@as(u8, 8), session.row);
    // The last page is page 4 (37 = 4 * 9 + 1); right clamps there and the row
    // is clamped to the single visible entry.
    for (0..6) |_| _ = try session.tick(.right);
    try std.testing.expectEqual(@as(u8, 4), session.page);
    try std.testing.expectEqual(@as(u8, 0), session.row);
    try std.testing.expectEqual(teleport_mod.Event.none, try session.tick(.down));
    try std.testing.expectEqual(@as(u8, 0), session.row);
    // Left moves back and clamps at page zero.
    _ = try session.tick(.left);
    try std.testing.expectEqual(@as(u8, 3), session.page);
    for (0..8) |_| _ = try session.tick(.left);
    try std.testing.expectEqual(@as(u8, 0), session.page);
    try std.testing.expectEqual(@as(u8, 0), session.row);
    // Up clamps at row zero.
    _ = try session.tick(.up);
    try std.testing.expectEqual(@as(u8, 0), session.row);
}

test "confirm selects page times nine plus row" {
    var loaded = try load();
    defer loaded.deinit();
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, entry("viki_entry", 1, allUnlocked()));
    _ = try session.tick(.right);
    _ = try session.tick(.down);
    _ = try session.tick(.down);
    const proposal = try session.confirmViki(@intCast(@as(usize, session.page) * 9 + session.row));
    try std.testing.expectEqualStrings("Pannu Yakuta", proposal.plan.name);
    try std.testing.expectEqual(@as(u8, 0), proposal.plan.room);
    try std.testing.expectEqual(@as(u16, 248), proposal.plan.spawn.x);
    try std.testing.expectEqual(@as(u16, 480), proposal.plan.spawn.y);
    try std.testing.expectEqual(@as(u8, 2), proposal.plan.selector.region);
    try std.testing.expectEqual(@as(u8, 5), proposal.plan.selector.point);
}

test "a valid choice commits the source arrival and settles the receipt once" {
    var loaded = try load();
    defer loaded.deinit();
    const value = entry("viki_entry", 7, storyWith(39, 0x01));
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value);
    _ = try session.tick(.confirm);
    const committed = try session.commit(teleport_mod.currentFacts(value));
    try std.testing.expectEqual(@as(u64, 7), committed.receipt);
    try std.testing.expectEqualStrings("DATA/02_AREA.B/VB1.BIN", committed.plan.area);
    try std.testing.expectEqual(@as(u8, 0), committed.plan.room);
    try std.testing.expectEqual(@as(u16, 256), committed.plan.spawn.x);
    try std.testing.expectEqual(@as(u16, 592), committed.plan.spawn.y);
    try std.testing.expectEqual(@as(u16, 32), committed.plan.source_spawn.x);
    try std.testing.expectEqual(@as(u16, 74), committed.plan.source_spawn.y);
    try std.testing.expectEqual(@as(u16, 86), committed.plan.world_camera.?.x);
    try std.testing.expectEqual(@as(u16, 14), committed.plan.world_camera.?.y);
    try std.testing.expectEqual(teleport_mod.Phase.acknowledged, session.phase);
    try std.testing.expectEqual(@as(u64, 7), session.settled);
    try std.testing.expectError(error.NoPending, session.commit(teleport_mod.currentFacts(value)));
    // The same entry can only continue with a later receipt.
    var settled_entry = value;
    settled_entry.settled_receipt = 7;
    settled_entry.receipt = 8;
    var next = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, settled_entry);
    _ = try next.tick(.cancel);
}

test "an already settled receipt is refused before selection" {
    var loaded = try load();
    defer loaded.deinit();
    var value = entry("viki_entry", 4, allUnlocked());
    value.settled_receipt = 4;
    try std.testing.expectError(error.RepeatedReceipt, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value));
}

test "changed money, story, content, entry or receipt reject atomically and stay retryable" {
    var loaded = try load();
    defer loaded.deinit();
    const value = entry("viki_entry", 3, allUnlocked());
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value);
    _ = try session.tick(.confirm);
    var facts = teleport_mod.currentFacts(value);
    facts.money += 1;
    try std.testing.expectError(error.StaleMoney, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.story[40] = 0;
    try std.testing.expectError(error.StaleStory, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.content_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    try std.testing.expectError(error.StaleContent, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.entry_id = "another_entry";
    try std.testing.expectError(error.StaleEntry, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.receipt = 4;
    try std.testing.expectError(error.StaleReceipt, session.commit(facts));
    // A failed commit publishes nothing and keeps the proposal retryable.
    try std.testing.expectEqual(teleport_mod.Phase.pending, session.phase);
    const committed = try session.commit(teleport_mod.currentFacts(value));
    try std.testing.expectEqual(@as(u64, 3), committed.receipt);
}

test "cancel returns field ownership, consumes no receipt and leaves the list intact" {
    var loaded = try load();
    defer loaded.deinit();
    const value = entry("viki_entry", 5, allUnlocked());
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value);
    const returned = try session.cancel();
    try std.testing.expectEqual(teleport_mod.Owner.field, returned.owner);
    try std.testing.expectEqual(@as(u64, 5), returned.receipt);
    try std.testing.expectEqual(@as(u64, 0), returned.settled);
    try std.testing.expectEqual(teleport_mod.Phase.cancelled, session.phase);
    _ = try std.testing.expectError(error.NoPending, session.commit(teleport_mod.currentFacts(value)));
    // Re-opening the same entry is allowed because nothing settled.
    var again = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value);
    _ = try again.tick(.confirm);
    _ = try again.commit(teleport_mod.currentFacts(value));
}

test "a cancel after a commit is refused and keeps the settled state" {
    var loaded = try load();
    defer loaded.deinit();
    const value = entry("viki_entry", 1, allUnlocked());
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value);
    _ = try session.tick(.confirm);
    _ = try session.commit(teleport_mod.currentFacts(value));
    try std.testing.expectError(error.NotSelecting, session.cancel());
}

test "the viki menu only opens for the exact stage-C source request" {
    var loaded = try load();
    defer loaded.deinit();
    const value = entry("viki_entry", 1, allUnlocked());
    var wrong = viki_request;
    wrong.selector = 0x80;
    try std.testing.expectError(error.NotAdmitted, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, wrong, value));
    wrong = viki_request;
    wrong.index = 2;
    try std.testing.expectError(error.NotAdmitted, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, wrong, value));
    wrong = viki_request;
    wrong.callback = 0x800108B8;
    try std.testing.expectError(error.NotAdmitted, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, wrong, value));
    wrong = viki_request;
    wrong.request_entry = 0x80013730;
    try std.testing.expectError(error.NotAdmitted, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, wrong, value));
    wrong = viki_request;
    wrong.room = 1;
    try std.testing.expectError(error.NotAdmitted, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, wrong, value));
    try std.testing.expectError(error.NotAdmitted, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(99), value));
    // An item request is routed to the item admission, never to Viki: this
    // entry has no used item, so the item gate (not the Viki gate) answers.
    try std.testing.expectError(error.ItemNotInSlot, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(81), value));
}

test "the Blinking Mirror uses the castle tier area and the outside gate" {
    var loaded = try load();
    defer loaded.deinit();
    const mirror = &loaded.mirror.value;
    const areas = [_][]const u8{
        "DATA/02_AREA.B/VB7A.BIN",
        "DATA/02_AREA.B/VB5AG.BIN",
        "DATA/02_AREA.B/VB5BG.BIN",
        "DATA/02_AREA.B/VB5CG.BIN",
        "DATA/02_AREA.B/VB5CG.BIN",
    };
    const area_indices = [_]u8{ 128, 32, 24, 16, 16 };
    for (areas, 0..) |area, tier| {
        var value = itemEntry("mirror_entry", 81, .{});
        value.castle_stage = @intCast(tier);
        value.world_mode = 1;
        var session = try teleport_mod.Session.open(&loaded.viki.value, mirror, mirrorRequest(81), value);
        const proposal = try session.confirmItem();
        try std.testing.expectEqualStrings("Blinking Mirror", proposal.plan.name);
        try std.testing.expectEqual(@as(teleport_mod.Family, .blinking_mirror), proposal.plan.family);
        try std.testing.expectEqual(teleport_mod.ResultKind.travel_mirror, proposal.plan.result_kind);
        try std.testing.expectEqualStrings(area, proposal.plan.area);
        try std.testing.expectEqual(@as(u8, 1), proposal.plan.selector.region);
        try std.testing.expectEqual(area_indices[tier], proposal.plan.selector.area_index);
        try std.testing.expectEqual(@as(u8, 2), proposal.plan.room);
        try std.testing.expectEqual(@as(u16, 112), proposal.plan.spawn.x);
        try std.testing.expectEqual(@as(u16, 120), proposal.plan.spawn.y);
        const committed = try session.commit(teleport_mod.currentFacts(value));
        try std.testing.expectEqual(@as(u64, 1), committed.receipt);
    }
    // An unknown castle stage refuses instead of picking a nearest area.
    var value = itemEntry("mirror_entry", 81, .{});
    value.castle_stage = 5;
    value.world_mode = 1;
    var session = try teleport_mod.Session.open(&loaded.viki.value, mirror, mirrorRequest(81), value);
    try std.testing.expectError(error.InvalidCastleStage, session.confirmItem());
    // The gate is the source world-mode byte.
    value.castle_stage = 0;
    value.world_mode = 0;
    try std.testing.expectError(error.OutsideRequired, teleport_mod.Session.open(&loaded.viki.value, mirror, mirrorRequest(81), value));
}

test "the mirror commit rejects a changed item slot, item, tier or money" {
    var loaded = try load();
    defer loaded.deinit();
    var value = itemEntry("mirror_entry", 81, .{});
    value.world_mode = 1;
    value.castle_stage = 2;
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(81), value);
    _ = try session.tick(.confirm);
    var facts = teleport_mod.currentFacts(value);
    facts.item.present = false;
    try std.testing.expectError(error.StaleItem, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.item.slot = 4;
    try std.testing.expectError(error.StaleItem, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.item.item_id = 73;
    try std.testing.expectError(error.StaleItem, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.castle_stage = 3;
    try std.testing.expectError(error.StaleTier, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.money -= 300;
    try std.testing.expectError(error.StaleMoney, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.world_mode = 0;
    try std.testing.expectError(error.StaleWorldMode, session.commit(facts));
    const committed = try session.commit(teleport_mod.currentFacts(value));
    try std.testing.expectEqualStrings("DATA/02_AREA.B/VB5BG.BIN", committed.plan.area);
}

test "the Escape Talisman requires the field gate, its story bit and a resolved point" {
    var loaded = try load();
    defer loaded.deinit();
    var story = event.StoryState{};
    story.scenario[teleport_mod.escape_scenario_byte] = 2;
    var value = itemEntry("escape_entry", 73, story);
    value.world_mode = 0;
    value.retained_point = greatForest();
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(73), value);
    const proposal = try session.confirmItem();
    try std.testing.expectEqual(@as(teleport_mod.Family, .escape_talisman), proposal.plan.family);
    try std.testing.expectEqual(teleport_mod.ResultKind.travel_mirror, proposal.plan.result_kind);
    try std.testing.expectEqualStrings("Escape talisman", proposal.plan.name);
    try std.testing.expectEqualStrings("DATA/02_AREA.B/VB6.BIN", proposal.plan.area);
    try std.testing.expectEqual(teleport_mod.SelectorKind.retained_point, proposal.plan.selector.kind);
    try std.testing.expectEqual(@as(u8, 1), proposal.plan.selector.region);
    try std.testing.expectEqual(@as(u8, 5), proposal.plan.selector.point);
    try std.testing.expectEqual(@as(u16, 264), proposal.plan.spawn.x);
    try std.testing.expectEqual(@as(u16, 344), proposal.plan.spawn.y);
    const committed = try session.commit(teleport_mod.currentFacts(value));
    try std.testing.expectEqualStrings("main_us_11_escape_talisman", committed.plan.result_entry_id);

    // Missing retained point refuses rather than guessing a room.
    var no_point = value;
    no_point.retained_point = null;
    var missing = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(73), no_point);
    try std.testing.expectError(error.UnresolvedRetainedPoint, missing.confirmItem());
    // Wrong world mode and a cleared story bit are separate rejections.
    var outside = value;
    outside.world_mode = 1;
    try std.testing.expectError(error.InsideRequired, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(73), outside));
    var no_bit = value;
    no_bit.story = event.StoryState{};
    try std.testing.expectError(error.EscapeUnavailable, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(73), no_bit));
    // The item must be the used slot's item.
    var no_item = value;
    no_item.item.present = false;
    try std.testing.expectError(error.ItemNotInSlot, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(73), no_item));
}

test "the escape commit rejects a changed retained point" {
    var loaded = try load();
    defer loaded.deinit();
    var story = event.StoryState{};
    story.scenario[teleport_mod.escape_scenario_byte] = 2;
    var value = itemEntry("escape_entry", 73, story);
    value.world_mode = 0;
    value.retained_point = greatForest();
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(73), value);
    _ = try session.tick(.confirm);
    var facts = teleport_mod.currentFacts(value);
    facts.retained_point.?.room = 1;
    try std.testing.expectError(error.StaleRetainedPoint, session.commit(facts));
    facts = teleport_mod.currentFacts(value);
    facts.retained_point.?.area = "DATA/02_AREA.B/VB1.BIN";
    try std.testing.expectError(error.StaleRetainedPoint, session.commit(facts));
    _ = try session.commit(teleport_mod.currentFacts(value));
}

test "one handler serves viki and both item families with distinct plans" {
    var loaded = try load();
    defer loaded.deinit();
    var viki_session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, entry("viki_entry", 1, allUnlocked()));
    _ = try viki_session.tick(.confirm);
    const viki_commit = try viki_session.commit(teleport_mod.currentFacts(entry("viki_entry", 1, allUnlocked())));

    var mirror_value = itemEntry("mirror_entry", 81, .{});
    mirror_value.world_mode = 1;
    mirror_value.castle_stage = 1;
    var mirror_session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(81), mirror_value);
    _ = try mirror_session.tick(.confirm);
    const mirror_commit = try mirror_session.commit(teleport_mod.currentFacts(mirror_value));

    var story = event.StoryState{};
    story.scenario[teleport_mod.escape_scenario_byte] = 2;
    var escape_value = itemEntry("escape_entry", 73, story);
    escape_value.world_mode = 0;
    escape_value.retained_point = greatForest();
    var escape_session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, mirrorRequest(73), escape_value);
    _ = try escape_session.tick(.confirm);
    const escape_commit = try escape_session.commit(teleport_mod.currentFacts(escape_value));

    try std.testing.expectEqual(teleport_mod.ResultKind.travel_teleport, viki_commit.plan.result_kind);
    try std.testing.expectEqual(teleport_mod.ResultKind.travel_mirror, mirror_commit.plan.result_kind);
    try std.testing.expectEqual(teleport_mod.ResultKind.travel_mirror, escape_commit.plan.result_kind);
    try std.testing.expect(!std.mem.eql(u8, viki_commit.plan.destination_id, mirror_commit.plan.destination_id));
    try std.testing.expect(!std.mem.eql(u8, mirror_commit.plan.destination_id, escape_commit.plan.destination_id));
    try std.testing.expect(!std.mem.eql(u8, mirror_commit.plan.area, escape_commit.plan.area));
}

test "a pending proposal round-trips through save/load and still commits" {
    var loaded = try load();
    defer loaded.deinit();
    const value = entry("viki_entry", 9, allUnlocked());
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value);
    _ = try session.tick(.right);
    _ = try session.tick(.down);
    const proposal = try session.confirmViki(@intCast(@as(usize, session.page) * 9 + session.row));
    const bytes = try teleport_mod.save(session, allocator);
    defer allocator.free(bytes);
    var decoded = try teleport_mod.load(allocator, bytes, &loaded.viki.value, &loaded.mirror.value);
    defer decoded.deinit();
    try std.testing.expectEqual(teleport_mod.Phase.pending, decoded.session.phase);
    try std.testing.expectEqual(session.page, decoded.session.page);
    try std.testing.expectEqual(session.row, decoded.session.row);
    try std.testing.expect(decoded.session.proposal != null);
    try std.testing.expectEqualStrings(proposal.plan.destination_id, decoded.session.proposal.?.plan.destination_id);
    const committed = try decoded.session.commit(teleport_mod.currentFacts(value));
    try std.testing.expectEqual(@as(u64, 9), committed.receipt);
    try std.testing.expectEqual(teleport_mod.Phase.acknowledged, decoded.session.phase);
}

test "a tampered pending snapshot is rejected instead of tolerated" {
    var loaded = try load();
    defer loaded.deinit();
    const value = entry("viki_entry", 2, allUnlocked());
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value);
    _ = try session.tick(.confirm);
    var stored = teleport_mod.snapshot(session);
    stored.proposal.?.expected.money += 1;
    try std.testing.expectError(error.InvalidSnapshot, teleport_mod.restore(&loaded.viki.value, &loaded.mirror.value, stored));
    var second = teleport_mod.snapshot(session);
    second.settled = 5;
    try std.testing.expectError(error.InvalidSnapshot, teleport_mod.restore(&loaded.viki.value, &loaded.mirror.value, second));
    var third = teleport_mod.snapshot(session);
    third.proposal.?.plan.room +%= 1;
    try std.testing.expectError(error.InvalidSnapshot, teleport_mod.restore(&loaded.viki.value, &loaded.mirror.value, third));
    var fourth = teleport_mod.snapshot(session);
    fourth.entry.story.scenario[39] = 0;
    fourth.proposal.?.expected.story[39] = 0;
    try std.testing.expectError(error.InvalidSnapshot, teleport_mod.restore(&loaded.viki.value, &loaded.mirror.value, fourth));
    var fifth = teleport_mod.snapshot(session);
    fifth.version = 2;
    try std.testing.expectError(error.InvalidSnapshot, teleport_mod.restore(&loaded.viki.value, &loaded.mirror.value, fifth));
}

test "an acknowledged snapshot keeps the settled receipt and refuses a duplicate" {
    var loaded = try load();
    defer loaded.deinit();
    const value = entry("viki_entry", 6, allUnlocked());
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value);
    _ = try session.tick(.confirm);
    _ = try session.commit(teleport_mod.currentFacts(value));
    const bytes = try teleport_mod.save(session, allocator);
    defer allocator.free(bytes);
    var decoded = try teleport_mod.load(allocator, bytes, &loaded.viki.value, &loaded.mirror.value);
    defer decoded.deinit();
    try std.testing.expectEqual(teleport_mod.Phase.acknowledged, decoded.session.phase);
    try std.testing.expectEqual(@as(u64, 6), decoded.session.settled);
    var settled_entry = value;
    settled_entry.settled_receipt = 6;
    try std.testing.expectError(error.RepeatedReceipt, teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, settled_entry));
    settled_entry.receipt = 7;
    _ = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, settled_entry);
}

test "a cancelled session round-trips without consuming the receipt" {
    var loaded = try load();
    defer loaded.deinit();
    const value = entry("viki_entry", 4, allUnlocked());
    var session = try teleport_mod.Session.open(&loaded.viki.value, &loaded.mirror.value, viki_request, value);
    _ = try session.tick(.cancel);
    const bytes = try teleport_mod.save(session, allocator);
    defer allocator.free(bytes);
    var decoded = try teleport_mod.load(allocator, bytes, &loaded.viki.value, &loaded.mirror.value);
    defer decoded.deinit();
    try std.testing.expectEqual(teleport_mod.Phase.cancelled, decoded.session.phase);
    try std.testing.expectEqual(@as(u64, 0), decoded.session.settled);
    try std.testing.expectError(error.NotSelecting, decoded.session.tick(.confirm));
}

test "the arrival plan for every destination keeps the source units and area" {
    var loaded = try load();
    defer loaded.deinit();
    for (loaded.viki.value.destinations) |destination| {
        try std.testing.expectEqual(destination.arrival.source_spawn.x * 8, destination.arrival.spawn.x);
        try std.testing.expectEqual(destination.arrival.source_spawn.y * 8, destination.arrival.spawn.y);
        try std.testing.expect(destination.arrival.world_camera != null);
        for (destination.arrival.area) |character| try std.testing.expect(character < 128);
    }
    const great = loaded.viki.value.destinations[4];
    try std.testing.expectEqualStrings(great.arrival.area, greatForest().area);
    try std.testing.expectEqual(great.arrival.room, greatForest().room);
    try std.testing.expectEqual(great.arrival.source_spawn.x, greatForest().source_spawn.x);
    try std.testing.expectEqual(great.arrival.source_spawn.y, greatForest().source_spawn.y);
}
