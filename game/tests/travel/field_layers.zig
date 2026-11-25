//! Field-layer composer focused checks: one composer over eleven decoded rooms.
//!
//! The cases verify the acceptance facts, not a walkthrough:
//!   * different room sizes and layer tags emit correctly qualified lists;
//!   * the secondary tilemap's tag 0x00A is a foreground layer, and the same
//!     section can select 0x100/0x1FF from a different room record;
//!   * actor depth is the source ground rule (or the supporting scenery tag);
//!   * movement re-sorts and re-clips the list, and a reload reproduces it;
//!   * the camera is the validated follow/entry rule with the draw-time floor,
//!     and a small room is centred by the layer offset, not by the camera;
//!   * unknown lighting/shadow/camera limits stay disclosed.
//!
//! No original instruction is executed.  The field layers asset is generated from
//! static source facts.

const std = @import("std");
const composer_mod = @import("travel").composer;
const data = @import("travel_data").field_layers;

fn openPacket() !composer_mod.Opened {
    return composer_mod.open(std.testing.allocator, data.json);
}

fn room(asset: *const composer_mod.Asset, id: []const u8) *const composer_mod.Room {
    for (asset.rooms) |*candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate;
    unreachable;
}

fn frameAt(asset: *const composer_mod.Asset, target: *const composer_mod.Room, focus: composer_mod.Point) composer_mod.Frame {
    const camera = composer_mod.renderCamera(asset.camera, target, asset.viewport, focus, .{ .x = 0, .y = 0 });
    return .{ .camera_x = camera.x, .camera_y = camera.y };
}

fn actorAt(cell_x: i32, cell_y: i32) composer_mod.Player {
    return .{ .id = "hero", .x = cell_x * 8, .y = cell_y * 8, .w = 23, .h = 47 };
}

fn expectedLength(target: *const composer_mod.Room, actors: usize) usize {
    return target.scenery.len + (if (target.secondary_present) @as(usize, 1) else 0) + 1 + actors;
}

const Found = struct { index: usize, item: composer_mod.Placed };

fn findKind(list: *const composer_mod.List, kind: composer_mod.LayerKind) ?Found {
    for (list.items[0..list.length], 0..) |item, index| if (item.kind == kind) return .{ .index = index, .item = item };
    return null;
}

fn findSceneryObject(list: *const composer_mod.List, object: u16, vertex: u16) ?Found {
    for (list.items[0..list.length], 0..) |item, index| switch (item.origin) {
        .scenery => |scenery| if (scenery.object == object and scenery.vertex == vertex) return .{ .index = index, .item = item },
        else => {},
    };
    return null;
}

fn findTag(list: *const composer_mod.List, tag: i32) ?Found {
    for (list.items[0..list.length], 0..) |item, index| if (item.kind == .scenery and item.tag == tag) return .{ .index = index, .item = item };
    return null;
}

fn anyVisibilityChanged(first: *const composer_mod.List, second: *const composer_mod.List) bool {
    for (first.items[0..first.length]) |a| {
        for (second.items[0..second.length]) |b| {
            if (!std.meta.eql(a.origin, b.origin)) continue;
            if (a.visibility != b.visibility) return true;
            break;
        }
    }
    return false;
}

fn countVisibility(list: *const composer_mod.List, value: composer_mod.Visibility) usize {
    var total: usize = 0;
    for (list.items[0..list.length]) |item| {
        if (item.visibility == value) total += 1;
    }
    return total;
}

test "eleven rooms validate with distinct sizes, layers and depths" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    try std.testing.expectEqual(@as(usize, 11), asset.rooms.len);
    try std.testing.expectEqual(@as(u32, 384), asset.counts.scenery_quads);
    try std.testing.expectEqual(@as(u16, 22), asset.counts.projected_entities);
    try std.testing.expectEqual(@as(u16, 51), asset.counts.static_words);

    var sizes: [16][2]i32 = undefined;
    var size_count: usize = 0;
    for (asset.rooms) |target| {
        var known = false;
        for (sizes[0..size_count]) |size| {
            if (size[0] == target.pixels_x and size[1] == target.pixels_y) known = true;
        }
        if (!known) {
            sizes[size_count] = .{ target.pixels_x, target.pixels_y };
            size_count += 1;
        }
        try std.testing.expectEqual(target.tiles_x * 16, target.pixels_x);
        try std.testing.expectEqual(target.tiles_y * 16, target.pixels_y);
        try std.testing.expectEqual(@as(i32, 256) - target.primary_tag, target.primary_depth);
        try std.testing.expectEqual(@as(i32, 256) - target.secondary_tag, target.secondary_depth);
    }
    try std.testing.expectEqual(@as(usize, 8), size_count);
    try std.testing.expectEqual(@as(i32, 256), room(asset, "vf1_room5").pixels_x);
    try std.testing.expectEqual(@as(i32, 896), room(asset, "vaa_room2").pixels_y);
}

test "camera probes reproduce the source rule and the draw-time floor" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const village = room(asset, "vb6_room0");
    for (village.camera_probes) |probe| {
        const focus: composer_mod.Point = .{ .x = probe.focus_x, .y = probe.focus_y };
        const nudge: composer_mod.Point = .{ .x = probe.nudge_x, .y = probe.nudge_y };
        const raw = composer_mod.followCamera(asset.camera, village, asset.viewport, focus, nudge);
        const render = composer_mod.renderCamera(asset.camera, village, asset.viewport, focus, nudge);
        try std.testing.expectEqual(probe.raw_x, raw.x);
        try std.testing.expectEqual(probe.raw_y, raw.y);
        try std.testing.expectEqual(probe.render_x, render.x);
        try std.testing.expectEqual(probe.render_y, render.y);
    }
    // Concrete vectors: focus 264/136 -> 264-152 / 136-112; a max corner clamps to
    // 512-320 / 384-240; the signed nudge byte moves both axes.
    try std.testing.expectEqual(@as(i32, 112), village.camera_probes[0].render_x);
    try std.testing.expectEqual(@as(i32, 24), village.camera_probes[0].render_y);
    try std.testing.expectEqual(@as(i32, 104), village.camera_probes[1].render_x);
    try std.testing.expectEqual(@as(i32, 32), village.camera_probes[1].render_y);
    try std.testing.expectEqual(@as(i32, 192), village.camera_probes[3].render_x);
    try std.testing.expectEqual(@as(i32, 144), village.camera_probes[3].render_y);

    // A room smaller than the viewport: the raw camera is negative and the draw
    // path floors it, so the layer offset does the centring.
    const vd6 = room(asset, "vd6_room4");
    const raw = composer_mod.followCamera(asset.camera, vd6, asset.viewport, .{ .x = 120, .y = 200 }, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(i32, -16), raw.x);
    const render = composer_mod.renderCamera(asset.camera, vd6, asset.viewport, .{ .x = 120, .y = 200 }, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(i32, 0), render.x);
    try std.testing.expectEqual(@as(i32, 8), composer_mod.layerOffset(304, 320));
    try std.testing.expectEqual(@as(i32, 0), composer_mod.layerOffset(320, 320));
    try std.testing.expectEqual(@as(i32, 8), composer_mod.layerOffset(224, 240));
    try std.testing.expectEqual(@as(i32, 32), composer_mod.layerOffset(256, 320));
}

test "room sizes drive the list, not a 512x384 constant" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    var list: composer_mod.List = .{};

    const village = room(asset, "vb6_room0");
    try composer_mod.compose(&list, asset, village, &.{}, frameAt(asset, village, .{ .x = 264, .y = 136 }));
    const village_primary = findKind(&list, .primary_map).?;
    try std.testing.expectEqual(@as(i32, 512), village_primary.item.screen.w);
    try std.testing.expectEqual(@as(i32, 384), village_primary.item.screen.h);
    try std.testing.expectEqual(@as(i32, -112), village_primary.item.screen.x);

    // 256 px wide: the source camera is 0 and the layer offset is 32, so the map
    // starts at 32 rather than at the port's (512-256)/2 = 128 camera shift.
    const vf1 = room(asset, "vf1_room5");
    try composer_mod.compose(&list, asset, vf1, &.{}, frameAt(asset, vf1, .{ .x = 0, .y = 0 }));
    const vf1_primary = findKind(&list, .primary_map).?;
    try std.testing.expectEqual(@as(i32, 256), vf1_primary.item.screen.w);
    try std.testing.expectEqual(@as(i32, 32), vf1_primary.item.screen.x);
    try std.testing.expectEqual(@as(i32, 32), vf1.centering_x);

    // 304x320: x-centred by 8, y scrolled by the camera.
    const vd6 = room(asset, "vd6_room4");
    try composer_mod.compose(&list, asset, vd6, &.{}, frameAt(asset, vd6, .{ .x = 120, .y = 200 }));
    const vd6_primary = findKind(&list, .primary_map).?;
    try std.testing.expectEqual(@as(i32, 304), vd6_primary.item.screen.w);
    try std.testing.expectEqual(@as(i32, 8), vd6_primary.item.screen.x);

    // 320x224: y-centred by 8 with a zero camera.
    const ve5 = room(asset, "ve5_room10");
    try composer_mod.compose(&list, asset, ve5, &.{}, frameAt(asset, ve5, .{ .x = 0, .y = 0 }));
    const ve5_primary = findKind(&list, .primary_map).?;
    try std.testing.expectEqual(@as(i32, 224), ve5_primary.item.screen.h);
    try std.testing.expectEqual(@as(i32, 8), ve5_primary.item.screen.y);
}

test "layer tags qualify backdrop, foreground and the order-0/order-1 variants" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    var list: composer_mod.List = .{};

    // VB6 room3: every scenery object uses order 0, so it is tag 0x1FF and sits
    // BEHIND the primary map (0x1FE).
    const room3 = room(asset, "vb6_room3");
    try composer_mod.compose(&list, asset, room3, &.{}, frameAt(asset, room3, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(usize, expectedLength(room3, 0)), list.length);
    try std.testing.expectEqual(composer_mod.LayerKind.scenery, list.items[0].kind);
    try std.testing.expectEqual(@as(i32, 511), list.items[0].tag);
    try std.testing.expectEqual(@as(i32, -255), list.items[0].depth);
    try std.testing.expectEqual(@as(usize, 27), findKind(&list, .primary_map).?.index);

    // VB6 room33: the room record selects secondary tag 0x1FF, so the secondary
    // layer is the furthest thing in the room, before the primary map.
    const room33 = room(asset, "vb6_room33");
    try composer_mod.compose(&list, asset, room33, &.{}, frameAt(asset, room33, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(composer_mod.LayerKind.secondary_map, list.items[0].kind);
    try std.testing.expectEqual(@as(i32, 511), list.items[0].tag);
    try std.testing.expectEqual(composer_mod.LayerKind.primary_map, list.items[1].kind);
    try std.testing.expectEqual(@as(u32, 0x6100), room33.secondary_mode);

    // VB6 room42 shares room0's section but its own record selects tag 0x100, so
    // the overlay is at depth 0 -- behind every prop, unlike room0's foreground.
    const room42 = room(asset, "vb6_room42");
    try composer_mod.compose(&list, asset, room42, &.{}, frameAt(asset, room42, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(composer_mod.LayerKind.primary_map, list.items[0].kind);
    try std.testing.expectEqual(composer_mod.LayerKind.secondary_map, list.items[1].kind);
    try std.testing.expectEqual(@as(i32, 256), list.items[1].tag);
    try std.testing.expectEqual(@as(i32, 0), list.items[1].depth);

    // VB6 room0: the same section with byte8 = 1 selects 0x00A, a foreground
    // overlay at depth 246 that is drawn after every prop and every actor.
    const village = room(asset, "vb6_room0");
    const hero = [_]composer_mod.Player{actorAt(33, 17)};
    try composer_mod.compose(&list, asset, village, &hero, frameAt(asset, village, .{ .x = 264, .y = 136 }));
    const overlay = findKind(&list, .secondary_map).?;
    try std.testing.expectEqual(@as(i32, 10), overlay.item.tag);
    try std.testing.expectEqual(@as(i32, 246), overlay.item.depth);
    try std.testing.expectEqual(@as(usize, list.length - 1), overlay.index);
    try std.testing.expectEqual(composer_mod.Relation.in_front_of_actors, overlay.item.relation);

    // VB6 room8: one object uses scenery order 1 -> tag 0xFF.
    const room8 = room(asset, "vb6_room8");
    try composer_mod.compose(&list, asset, room8, &.{}, frameAt(asset, room8, .{ .x = 0, .y = 0 }));
    const mid = findTag(&list, 255).?;
    try std.testing.expectEqual(@as(i32, 1), mid.item.depth);

    // VS1 room39: order 0 with room byte7 bit 3 -> tag 0x1FE, the same depth as
    // the primary map. That is a cross-path tie: deterministic, but undeclared.
    const vs1 = room(asset, "vs1_room39");
    try composer_mod.compose(&list, asset, vs1, &.{}, frameAt(asset, vs1, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(usize, expectedLength(vs1, 0)), list.length);
    var cross_path: usize = 0;
    var same_path: usize = 0;
    for (list.items[0..list.length], 0..) |item, index| {
        if (item.kind != .scenery or item.tag != 510) continue;
        if (item.tie == .cross_path_undeclared) cross_path += 1;
        if (index > 0 and list.items[index - 1].kind == .scenery and
            list.items[index - 1].depth == item.depth and item.tie == .reverse_emission_same_path) same_path += 1;
    }
    try std.testing.expect(cross_path >= 1);
    try std.testing.expect(same_path >= 60);
}

test "actor depth is the negated Y cell or the supporting scenery tag" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const village = room(asset, "vb6_room0");

    try std.testing.expectEqual(@as(i32, 239), try composer_mod.actorTag(village, actorAt(33, 17)));
    try std.testing.expectEqual(@as(i32, 0), try composer_mod.actorTag(village, actorAt(0, 0)));
    var list: composer_mod.List = .{};
    const grounded = [_]composer_mod.Player{actorAt(33, 17)};
    try composer_mod.compose(&list, asset, village, &grounded, frameAt(asset, village, .{ .x = 264, .y = 136 }));
    const actor_piece = findKind(&list, .actor).?;
    try std.testing.expectEqual(@as(i32, 239), actor_piece.item.tag);
    try std.testing.expectEqual(@as(i32, 17), actor_piece.item.depth);
    try std.testing.expectEqual(composer_mod.Relation.is_actor, actor_piece.item.relation);
    // Props finer than 17 are in front of the actor, coarser ones behind.
    const foreground_prop = findSceneryObject(&list, 2, 0).?;
    try std.testing.expectEqual(@as(i32, 18), foreground_prop.item.depth);
    try std.testing.expectEqual(composer_mod.Relation.in_front_of_actors, foreground_prop.item.relation);
    const background_prop = findSceneryObject(&list, 6, 0).?;
    try std.testing.expectEqual(@as(i32, 12), background_prop.item.depth);
    try std.testing.expectEqual(composer_mod.Relation.behind_actors, background_prop.item.relation);

    // Surface attached: the supporting scenery record's tag wins over the Y rule.
    const inn = room(asset, "vb6_room7");
    const attached = composer_mod.Player{ .id = "hero", .x = 288, .y = 72, .w = 23, .h = 47, .support = 7 };
    try std.testing.expectEqual(@as(i32, 238), try composer_mod.actorTag(inn, attached));
    // The unattached branch stores the TAG, not the depth: 256 - 247 = 9.
    try std.testing.expectEqual(@as(i32, 247), try composer_mod.actorTag(inn, actorAt(36, 9)));
    try std.testing.expectEqual(@as(i32, 256) - 247, @as(i32, 9));

    const missing = composer_mod.Player{ .id = "hero", .x = 288, .y = 72, .w = 23, .h = 47, .support = 999 };
    try std.testing.expectError(error.UnknownSupport, composer_mod.actorTag(inn, missing));
    try std.testing.expectError(error.ActorOutsideRoom, composer_mod.actorTag(village, actorAt(64, 0)));
    try std.testing.expectError(error.ActorNotOnCell, composer_mod.actorTag(village, .{ .id = "hero", .x = 4, .y = 8, .w = 8, .h = 8 }));
    try std.testing.expectError(error.InvalidActorFootprint, composer_mod.actorTag(village, .{ .id = "hero", .x = 8, .y = 8, .w = 0, .h = 8 }));
}

test "movement re-sorts, re-clips and moves the camera" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const village = room(asset, "vb6_room0");
    var first: composer_mod.List = .{};
    var second: composer_mod.List = .{};

    const before = [_]composer_mod.Player{actorAt(33, 17)};
    try composer_mod.compose(&first, asset, village, &before, frameAt(asset, village, .{ .x = 264, .y = 136 }));
    const after = [_]composer_mod.Player{actorAt(33, 27)};
    try composer_mod.compose(&second, asset, village, &after, frameAt(asset, village, .{ .x = 264, .y = 216 }));

    // The camera follows the moved actor by the same 80 px.
    try std.testing.expectEqual(@as(i32, 24), first.frame.camera_y);
    try std.testing.expectEqual(@as(i32, 104), second.frame.camera_y);
    try std.testing.expectEqual(@as(i32, 17), findKind(&first, .actor).?.item.depth);
    try std.testing.expectEqual(@as(i32, 27), findKind(&second, .actor).?.item.depth);

    // A prop at depth 18 was in front of the actor and is now behind it.
    const prop_before = findSceneryObject(&first, 2, 0).?;
    const prop_after = findSceneryObject(&second, 2, 0).?;
    try std.testing.expectEqual(composer_mod.Relation.in_front_of_actors, prop_before.item.relation);
    try std.testing.expectEqual(composer_mod.Relation.behind_actors, prop_after.item.relation);

    // A prop at depth 12 leaves the viewport once the camera moves down 80 px.
    const clipped_before = findSceneryObject(&first, 6, 0).?;
    const clipped_after = findSceneryObject(&second, 6, 0).?;
    try std.testing.expectEqual(composer_mod.Visibility.inside, clipped_before.item.visibility);
    try std.testing.expectEqual(composer_mod.Visibility.outside, clipped_after.item.visibility);
    try std.testing.expect(anyVisibilityChanged(&first, &second));

    // The emitted list really is different, and the ordering still ascends.
    try std.testing.expect(!std.mem.eql(u8, &first.fingerprint(), &second.fingerprint()));
    for (first.items[1..first.length], 1..) |item, index| {
        try std.testing.expect(first.items[index - 1].depth <= item.depth);
    }

    // The same movement rule in the 640x896 opening room: the camera scrolls
    // instead of clamping, and a prop at depth 46 crosses the actor.
    const opening = room(asset, "vaa_room2");
    var wide_a: composer_mod.List = .{};
    var wide_b: composer_mod.List = .{};
    const wide_before = [_]composer_mod.Player{actorAt(12, 43)};
    const wide_after = [_]composer_mod.Player{actorAt(12, 53)};
    try composer_mod.compose(&wide_a, asset, opening, &wide_before, frameAt(asset, opening, .{ .x = 96, .y = 344 }));
    try composer_mod.compose(&wide_b, asset, opening, &wide_after, frameAt(asset, opening, .{ .x = 96, .y = 424 }));
    try std.testing.expectEqual(@as(i32, 232), wide_a.frame.camera_y);
    try std.testing.expectEqual(@as(i32, 312), wide_b.frame.camera_y);
    try std.testing.expectEqual(@as(i32, 43), findKind(&wide_a, .actor).?.item.depth);
    try std.testing.expectEqual(@as(i32, 53), findKind(&wide_b, .actor).?.item.depth);
    const crossing_before = findTag(&wide_a, 210).?;
    const crossing_after = findTag(&wide_b, 210).?;
    try std.testing.expectEqual(@as(i32, 46), crossing_before.item.depth);
    try std.testing.expectEqual(composer_mod.Relation.in_front_of_actors, crossing_before.item.relation);
    try std.testing.expectEqual(composer_mod.Relation.behind_actors, crossing_after.item.relation);
}

test "reload re-derives the same qualified list" {
    var first = try openPacket();
    defer first.deinit();
    var second = try openPacket();
    defer second.deinit();
    const asset = first.asset();
    const village = room(asset, "vb6_room0");
    const hero = [_]composer_mod.Player{actorAt(33, 17)};
    const frame = frameAt(asset, village, .{ .x = 264, .y = 136 });

    const reloaded = second.asset();
    try std.testing.expectEqualStrings("vb6_room0", reloaded.rooms[0].id);
    var a: composer_mod.List = .{};
    var b: composer_mod.List = .{};
    try composer_mod.compose(&a, asset, village, &hero, frame);
    try composer_mod.compose(&b, reloaded, &reloaded.rooms[0], &hero, frame);
    try std.testing.expectEqual(a.length, b.length);
    try std.testing.expectEqualSlices(u8, &a.fingerprint(), &b.fingerprint());

    // Every room is reproducible room-by-room, including the large opening room.
    for (asset.rooms) |*target| {
        var one: [1]composer_mod.Player = undefined;
        var actors: []const composer_mod.Player = &.{};
        if (target.entities.len != 0) {
            const entity = target.entities[0];
            one[0] = .{ .id = "entity", .x = entity.x, .y = entity.y, .w = 23, .h = 47 };
            actors = one[0..1];
        }
        var left: composer_mod.List = .{};
        var right: composer_mod.List = .{};
        const target_frame = frameAt(asset, target, .{ .x = 8, .y = 8 });
        try composer_mod.compose(&left, asset, target, actors, target_frame);
        try composer_mod.compose(&right, reloaded, target, actors, target_frame);
        try std.testing.expectEqualSlices(u8, &left.fingerprint(), &right.fingerprint());
        try std.testing.expectEqual(expectedLength(target, actors.len), left.length);
    }
}

test "tampered packets are rejected with typed errors" {
    const allocator = std.testing.allocator;

    var opened = try openPacket();
    opened.deinit();

    const cases = [_]struct { from: []const u8, to: []const u8, expected: anyerror }{
        .{ .from = "\"pixels_x\":304,", .to = "\"pixels_x\":305,", .expected = error.InvalidRoom },
        .{ .from = "\"raw_x\":112", .to = "\"raw_x\":113", .expected = error.CameraProbeMismatch },
        .{ .from = "\"primary_depth\":-254", .to = "\"primary_depth\":-253", .expected = error.InvalidRoom },
        .{ .from = "\"room_byte7\":24,\"room_byte8\":16", .to = "\"room_byte7\":26,\"room_byte8\":16", .expected = error.InvalidRoom },
        .{ .from = "\"schema\":\"suikoden-field-layers/1\"", .to = "\"schema\":\"suikoden-field-layers/2\"", .expected = error.UnsupportedSchema },
    };
    for (cases) |case| {
        const bytes = try std.mem.replaceOwned(u8, allocator, data.json, case.from, case.to);
        defer allocator.free(bytes);
        try std.testing.expect(bytes.len != data.json.len or !std.mem.eql(u8, bytes, data.json));
        try std.testing.expectError(case.expected, composer_mod.open(allocator, bytes));
    }
}

const Recorder = struct {
    calls: [composer_mod.max_pieces]struct { width: i32, height: i32, x: i32, y: i32 } = undefined,
    length: usize = 0,

    fn draw(context: *anyopaque, width: i32, height: i32, x: i32, y: i32) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.calls[self.length] = .{ .width = width, .height = height, .x = x, .y = y };
        self.length += 1;
    }
};

test "the existing handler shape receives the list in emitted order" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const village = room(asset, "vb6_room0");
    const hero = [_]composer_mod.Player{actorAt(33, 17)};
    const frame = frameAt(asset, village, .{ .x = 264, .y = 136 });

    var recorder: Recorder = .{};
    try composer_mod.emit(asset, village, &hero, frame, .{ .context = @ptrCast(&recorder), .draw = Recorder.draw });

    var list: composer_mod.List = .{};
    try composer_mod.compose(&list, asset, village, &hero, frame);
    try std.testing.expectEqual(list.length, recorder.length);
    for (list.items[0..list.length], 0..) |item, index| {
        try std.testing.expectEqual(item.screen.w, recorder.calls[index].width);
        try std.testing.expectEqual(item.screen.h, recorder.calls[index].height);
        try std.testing.expectEqual(item.screen.x, recorder.calls[index].x);
        try std.testing.expectEqual(item.screen.y, recorder.calls[index].y);
    }
    // The first call is the map layer at the room's own size, not a constant.
    try std.testing.expectEqual(@as(i32, 512), recorder.calls[0].width);
    try std.testing.expectEqual(@as(i32, 384), recorder.calls[0].height);
}

test "unknown lighting, shadow and camera limits stay disclosed" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    var rotation = false;
    var shake = false;
    var lighting = false;
    var shadow = false;
    for (asset.camera.unsupported) |token| {
        if (std.mem.eql(u8, token, "rotation")) rotation = true;
        if (std.mem.eql(u8, token, "scripted_shake")) shake = true;
        if (std.mem.eql(u8, token, "lighting")) lighting = true;
        if (std.mem.eql(u8, token, "shadow")) shadow = true;
    }
    try std.testing.expect(rotation and shake and lighting and shadow);
    try std.testing.expect(asset.disclosures.len >= 8);
    var mentions_lighting = false;
    var mentions_shadow = false;
    var mentions_animation = false;
    for (asset.disclosures) |note| {
        if (std.mem.indexOf(u8, note, "Lighting") != null) mentions_lighting = true;
        if (std.mem.indexOf(u8, note, "shadow") != null) mentions_shadow = true;
        if (std.mem.indexOf(u8, note, "frame 0") != null) mentions_animation = true;
    }
    try std.testing.expect(mentions_lighting and mentions_shadow and mentions_animation);

    // Animated scenery is disclosed per room instead of being silently frozen.
    try std.testing.expectEqualSlices(u16, &[_]u16{ 0, 1 }, room(asset, "vb6_room3").animated_types);
    try std.testing.expectEqualSlices(u16, &[_]u16{ 27, 38 }, room(asset, "vaa_room2").animated_types);
}
