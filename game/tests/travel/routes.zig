//! Focused checks: real catalogue data, boundary cells, direction,
//! ordered prefix commit, stale/repeated cues and unavailable destinations.
const std = @import("std");
const consumer = @import("travel").routes;
const event_runtime = @import("event_runtime");

const edges = consumer.edges;
const allocator = std.testing.allocator;

fn read(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(edges.max_json_bytes));
}

fn loadCatalogue() !std.json.Parsed(edges.Packet) {
    const bytes = try read("game/assets/travel/route_edges.json");
    defer allocator.free(bytes);
    return edges.load(allocator, bytes);
}

fn locationScope(packet: edges.Packet, buffer: *[32][]const u8, mode: enum { identity, journey, all }) consumer.Scope {
    var count: usize = 0;
    for (packet.locations) |location| {
        const include = switch (mode) {
            .identity => location.constructible,
            .journey => std.mem.eql(u8, location.export_package orelse "", "journey") or location.kind == .world_region,
            .all => true,
        };
        if (!include) continue;
        buffer[count] = location.id;
        count += 1;
    }
    return .{ .locations = buffer[0..count] };
}

fn cueFor(edge: edges.Edge, direction: ?edges.Direction) consumer.Cue {
    const trigger: consumer.Trigger = switch (edge.origin.trigger.kind) {
        .field_rectangle => .{ .field_rectangle = .{
            .position = .{ .domain = .field_pixel, .x = edge.origin.trigger.rectangle.?.x, .y = edge.origin.trigger.rectangle.?.y },
            .direction = direction,
        } },
        .world_point => .{ .world_point = edge.origin.trigger.point.? },
        .ordinary_event => .{ .ordinary_event = {} },
    };
    return .{ .origin_id = edge.origin.location_id, .trigger = trigger };
}

fn fieldCue(origin: []const u8, x: i32, y: i32, direction: ?edges.Direction) consumer.Cue {
    return .{ .origin_id = origin, .trigger = .{ .field_rectangle = .{
        .position = .{ .domain = .field_pixel, .x = x, .y = y },
        .direction = direction,
    } } };
}

fn worldCue(origin: []const u8, x: i32, y: i32) consumer.Cue {
    return .{ .origin_id = origin, .trigger = .{ .world_point = .{ .domain = .world_cell, .x = x, .y = y } } };
}

fn storyFor(edge: edges.Edge) event_runtime.StoryState {
    var story: event_runtime.StoryState = .{};
    for (edge.conditions) |condition| {
        const index = edges.scenarioIndex(condition.flag.id).?;
        if (condition.kind == .story_mask_set) {
            story.scenario[index] |= condition.flag.mask;
        } else {
            story.scenario[index] &= ~condition.flag.mask;
        }
    }
    return story;
}

fn applyStoryOr(story: *event_runtime.StoryState, effect: edges.Effect) void {
    if (effect.kind != .story_or) return;
    const flag = effect.flag orelse return;
    const index = edges.scenarioIndex(flag.id).?;
    story.scenario[index] |= flag.mask;
}

test "catalogue carries the derived 39-edge family" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    try std.testing.expectEqualStrings("suikoden-campaign-route-edges/1", packet.value.schema);
    try std.testing.expectEqual(@as(usize, 39), packet.value.edges.len);
    try std.testing.expectEqual(@as(usize, 16), packet.value.locations.len);
    try std.testing.expectEqual(@as(u16, 39), packet.value.coverage.edges);
    try std.testing.expectEqual(@as(u16, 34), packet.value.coverage.field_doorways);
    try std.testing.expectEqual(@as(u16, 7), packet.value.coverage.directional_field_doorways);
    try std.testing.expectEqual(@as(u16, 27), packet.value.coverage.directionless_field_doorways);
    try std.testing.expectEqual(@as(u16, 2), packet.value.coverage.world_point_entries);
    try std.testing.expectEqual(@as(u16, 2), packet.value.coverage.world_exits);
    try std.testing.expectEqual(@as(u16, 1), packet.value.coverage.ordinary_events);
    try std.testing.expectEqual(@as(u16, 1), packet.value.coverage.conditioned_edges);
    try std.testing.expectEqual(@as(u16, 4), packet.value.coverage.unavailable_destinations);
    try std.testing.expectEqual(@as(u16, 0), packet.value.coverage.unresolved);
    try std.testing.expectEqual(@as(usize, 2), packet.value.story_values.len);
    try std.testing.expect(packet.value.storyValue("scenario_0015") != null);
    try std.testing.expect(packet.value.storyValue("scenario_0039") != null);
    try std.testing.expect(packet.value.edge("vb6_r00_e05_to_blacksmith") != null);
    try std.testing.expect(packet.value.edge("vb6_r06_e07_same_room_reconstruction") != null);
    try std.testing.expect(packet.value.edge("region_b_point_05_to_village") != null);
}

test "every accepted route-transition id is present in the catalogue" {
    const bytes = try read("game/assets/routes/region_b_vb6_c.json");
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const routes = parsed.value.object.get("routes").?.array.items;
    try std.testing.expectEqual(@as(usize, 25), routes.len);
    const packet = try loadCatalogue();
    defer packet.deinit();
    for (routes) |route| {
        const id = route.object.get("id").?.string;
        try std.testing.expect(packet.value.edge(id) != null);
    }
}

test "every edge selects itself, orders its prefix and commits its units" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    var buffer: [32][]const u8 = undefined;
    const identity = locationScope(packet.value, &buffer, .identity);
    for (packet.value.edges) |edge| {
        var story = storyFor(edge);
        const direction: ?edges.Direction = edge.origin.trigger.direction;
        const cue = cueFor(edge, direction);
        var c: consumer.Consumer = .{};
        const destination = packet.value.location(edge.destination.location_id).?;
        if (!destination.constructible) {
            try std.testing.expectError(error.UnavailableDestination, c.begin(&packet.value, cue, &story, identity));
            try std.testing.expectEqual(consumer.State.idle, c.state);
            try std.testing.expect(c.pending == null);
            continue;
        }
        const proposal = try c.begin(&packet.value, cue, &story, identity);
        try std.testing.expectEqualStrings(edge.id, proposal.edge_id);
        try std.testing.expectEqual(edge.effects.len, proposal.effects.len);
        for (0..proposal.effects.len) |index| {
            const effect = try c.acknowledgeEffect(proposal.receipt, index);
            applyStoryOr(&story, effect);
        }
        const commit = try c.commit(&packet.value, proposal.receipt, &story);
        try std.testing.expectEqualStrings(edge.id, commit.edge_id);
        try std.testing.expect(std.meta.eql(edge.destination, commit.destination));
        try std.testing.expect(std.meta.eql(edge.reconstruction, commit.reconstruction));
        try std.testing.expect(std.meta.eql(edge.continuation, commit.continuation));
        try c.settle(commit.receipt);
        try std.testing.expectEqual(consumer.State.idle, c.state);
    }
}

test "world point entries use the inclusive 2x2 boundary cells" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    var buffer: [32][]const u8 = undefined;
    const identity = locationScope(packet.value, &buffer, .identity);
    const anchors = [_]struct { origin: []const u8, x: i32, y: i32, edge_id: []const u8 }{
        .{ .origin = "region_b", .x = 86, .y = 83, .edge_id = "region_b_point_05_to_village" },
        .{ .origin = "region_c", .x = 59, .y = 36, .edge_id = "region_c_point_06_to_kobold_village" },
    };
    for (anchors) |anchor| {
        const story: event_runtime.StoryState = .{};
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                var c: consumer.Consumer = .{};
                const cue = worldCue(anchor.origin, anchor.x + dx, anchor.y + dy);
                const inside = dx >= 0 and dx <= 1 and dy >= 0 and dy <= 1;
                if (!inside) {
                    try std.testing.expectError(error.NoMatchingEdge, c.begin(&packet.value, cue, &story, identity));
                    continue;
                }
                const proposal = try c.begin(&packet.value, cue, &story, identity);
                try std.testing.expectEqualStrings(anchor.edge_id, proposal.edge_id);
                try std.testing.expectEqual(@as(usize, 0), proposal.effects.len);
                try c.cancel(proposal.receipt);
            }
        }
        var c: consumer.Consumer = .{};
        try std.testing.expectError(error.NoMatchingEdge, c.begin(&packet.value, worldCue(anchor.origin, anchor.x + 2, anchor.y), &story, identity));
        try std.testing.expectError(error.NoMatchingEdge, c.begin(&packet.value, worldCue(anchor.origin, anchor.x, anchor.y - 1), &story, identity));
    }
    // Entry anchors and return cells are independent source facts.
    const b_entry = packet.value.edge("region_b_point_05_to_village").?;
    const b_return = packet.value.edge("vb6_r00_e01_to_region_b").?;
    const c_entry = packet.value.edge("region_c_point_06_to_kobold_village").?;
    const c_return = packet.value.edge("vb6_r06_e01_to_region_c").?;
    try std.testing.expect(std.meta.eql(b_entry.origin.trigger.point.?, .{ .domain = .world_cell, .x = 86, .y = 83 }));
    try std.testing.expect(std.meta.eql(b_return.destination.spawn, .{ .domain = .world_cell, .x = 86, .y = 85 }));
    try std.testing.expect(std.meta.eql(c_entry.origin.trigger.point.?, .{ .domain = .world_cell, .x = 59, .y = 36 }));
    try std.testing.expect(std.meta.eql(c_return.destination.spawn, .{ .domain = .world_cell, .x = 59, .y = 38 }));
}

test "directionless doors ignore input direction and up-doors require it" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    var buffer: [32][]const u8 = undefined;
    const identity = locationScope(packet.value, &buffer, .identity);
    const story: event_runtime.StoryState = .{};
    const door = packet.value.edge("vb6_r00_e00_to_forest_edge").?;
    const rect = door.origin.trigger.rectangle.?;
    for ([_]?edges.Direction{ null, .up, .down, .left, .right }) |direction| {
        var c: consumer.Consumer = .{};
        const proposal = try c.begin(&packet.value, fieldCue("vb6_village", rect.x, rect.y, direction), &story, identity);
        try std.testing.expectEqualStrings(door.id, proposal.edge_id);
        try c.cancel(proposal.receipt);
    }
    // Half-open rectangle boundaries: the last column/row is inside.
    for ([_]i32{ 0, 383 }) |y| {
        var c: consumer.Consumer = .{};
        const proposal = try c.begin(&packet.value, fieldCue("vb6_village", rect.x, y, null), &story, identity);
        try std.testing.expectEqualStrings(door.id, proposal.edge_id);
        try c.cancel(proposal.receipt);
    }
    try std.testing.expectError(error.NoMatchingEdge, terminal(&packet.value, fieldCue("vb6_village", rect.x + rect.w, 0, null), identity));
    try std.testing.expectError(error.NoMatchingEdge, terminal(&packet.value, fieldCue("vb6_village", rect.x - 8, 0, null), identity));

    const up_door = packet.value.edge("vb6_r00_e05_to_blacksmith").?;
    const up_rect = up_door.origin.trigger.rectangle.?;
    for ([_]?edges.Direction{ null, .down, .left, .right }) |direction| {
        try std.testing.expectError(error.NoMatchingEdge, terminal(&packet.value, fieldCue("vb6_village", up_rect.x, up_rect.y, direction), identity));
    }
    for ([_]struct { x: i32, y: i32 }{
        .{ .x = up_rect.x, .y = up_rect.y },
        .{ .x = up_rect.x, .y = up_rect.y + up_rect.h - 1 },
        .{ .x = up_rect.x + up_rect.w - 1, .y = up_rect.y },
    }) |point| {
        var c: consumer.Consumer = .{};
        const proposal = try c.begin(&packet.value, fieldCue("vb6_village", point.x, point.y, .up), &story, identity);
        try std.testing.expectEqualStrings(up_door.id, proposal.edge_id);
        try c.cancel(proposal.receipt);
    }
    try std.testing.expectError(error.NoMatchingEdge, terminal(&packet.value, fieldCue("vb6_village", up_rect.x + up_rect.w, up_rect.y, .up), identity));
    try std.testing.expectError(error.NoMatchingEdge, terminal(&packet.value, fieldCue("vb6_village", up_rect.x, up_rect.y + up_rect.h, .up), identity));
}

test "up-door prefix commits only in source order" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    var buffer: [32][]const u8 = undefined;
    const identity = locationScope(packet.value, &buffer, .identity);
    const edge = packet.value.edge("vb6_r00_e05_to_blacksmith").?;
    const rect = edge.origin.trigger.rectangle.?;
    var story: event_runtime.StoryState = .{};
    var c: consumer.Consumer = .{};
    const proposal = try c.begin(&packet.value, fieldCue("vb6_village", rect.x, rect.y, .up), &story, identity);
    try std.testing.expectEqual(@as(usize, 3), proposal.effects.len);
    try std.testing.expectError(error.PrefixIncomplete, c.commit(&packet.value, proposal.receipt, &story));
    try std.testing.expectError(error.PrefixOutOfOrder, c.acknowledgeEffect(proposal.receipt, 1));
    const first = try c.acknowledgeEffect(proposal.receipt, 0);
    try std.testing.expectEqual(edges.EffectKind.descriptor_state_transition, first.kind);
    try std.testing.expectEqual(@as(u8, 0x80), first.selector.?);
    try std.testing.expectEqual(@as(u8, 1), first.parameter.?);
    try std.testing.expectEqual(@as(u8, 1), first.mask.?);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x00 }, first.operands);
    try std.testing.expectError(error.PrefixOutOfOrder, c.acknowledgeEffect(proposal.receipt, 2));
    const second = try c.acknowledgeEffect(proposal.receipt, 1);
    try std.testing.expectEqual(edges.EffectKind.dialogue_cleanup, second.kind);
    const third = try c.acknowledgeEffect(proposal.receipt, 2);
    try std.testing.expectEqual(edges.EffectKind.scroll_set_y, third.kind);
    try std.testing.expectEqualSlices(u8, &.{0x02}, third.operands);
    try std.testing.expectError(error.NoMoreEffects, c.acknowledgeEffect(proposal.receipt, 3));
    const commit = try c.commit(&packet.value, proposal.receipt, &story);
    try std.testing.expect(std.meta.eql(commit.destination.spawn, .{ .domain = .field_pixel, .x = 184, .y = 208 }));
    try std.testing.expectEqualStrings("vb6_blacksmith", commit.destination.location_id);
}

test "stale story and repeated cues never replay the ordinary event" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    var buffer: [32][]const u8 = undefined;
    const identity = locationScope(packet.value, &buffer, .identity);
    const edge = packet.value.edge("vb6_r06_e07_same_room_reconstruction").?;
    const cue = cueFor(edge, null);
    var story: event_runtime.StoryState = .{};
    story.scenario[15] = 0x20;
    var c: consumer.Consumer = .{};
    const proposal = try c.begin(&packet.value, cue, &story, identity);
    try std.testing.expectEqual(@as(usize, 12), proposal.effects.len);
    for (0..proposal.effects.len) |index| _ = try c.acknowledgeEffect(proposal.receipt, index);
    // The host did not apply the final OR0x40: refuse instead of teleporting.
    try std.testing.expectError(error.UnexecutedStoryEffect, c.commit(&packet.value, proposal.receipt, &story));
    try std.testing.expectEqual(consumer.State.effects_pending, c.state);
    var committed_story = story;
    committed_story.scenario[15] |= 0x40;
    const commit = try c.commit(&packet.value, proposal.receipt, &committed_story);
    try std.testing.expect(std.meta.eql(commit.destination.spawn, .{ .domain = .field_pixel, .x = 216, .y = 200 }));
    try std.testing.expect(commit.reconstruction.same_room);
    try std.testing.expectEqual(edges.ContinuationKind.ordinary_source_selection, commit.continuation.kind);
    try c.settle(commit.receipt);
    // Repeating the cue after the event committed must select nothing: 0x40 is set.
    var repeat: consumer.Consumer = .{};
    try std.testing.expectError(error.NoMatchingEdge, repeat.begin(&packet.value, cue, &committed_story, identity));
    // A second cue while one is pending is refused.
    var pending: consumer.Consumer = .{};
    _ = try pending.begin(&packet.value, cue, &story, identity);
    try std.testing.expectError(error.CuePending, pending.begin(&packet.value, cue, &story, identity));
    // An externally changed guard between cue and commit is stale.
    var external: consumer.Consumer = .{};
    const stale_proposal = try external.begin(&packet.value, cue, &story, identity);
    for (0..stale_proposal.effects.len) |index| _ = try external.acknowledgeEffect(stale_proposal.receipt, index);
    var changed = story;
    changed.scenario[15] &= ~@as(u8, 0x20);
    try std.testing.expectError(error.StaleStory, external.commit(&packet.value, stale_proposal.receipt, &changed));
}

test "unavailable destination refuses without a substitute edge" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    var buffer: [32][]const u8 = undefined;
    const identity = locationScope(packet.value, &buffer, .identity);
    var all_buffer: [32][]const u8 = undefined;
    const all = locationScope(packet.value, &all_buffer, .all);
    var journey_buffer: [32][]const u8 = undefined;
    const journey = locationScope(packet.value, &journey_buffer, .journey);
    const story: event_runtime.StoryState = .{};
    const room_eight = packet.value.edge("vb6_r00_e03_to_room_08").?;
    const rect = room_eight.origin.trigger.rectangle.?;
    const cue = fieldCue("vb6_village", rect.x, rect.y, .up);
    var refused: consumer.Consumer = .{};
    try std.testing.expectError(error.UnavailableDestination, refused.begin(&packet.value, cue, &story, identity));
    try std.testing.expectEqual(consumer.State.idle, refused.state);
    try std.testing.expect(refused.pending == null);
    try std.testing.expectEqual(consumer.State.idle, refused.snapshot().state);
    // The same source edge works once a package can construct that room, and it
    // still resolves to room 8 rather than any nearby available room.
    var allowed: consumer.Consumer = .{};
    const proposal = try allowed.begin(&packet.value, cue, &story, all);
    try std.testing.expectEqualStrings("vb6_room_08", proposal.destination.location_id);
    try allowed.cancel(proposal.receipt);
    // Inn and shop need the first-room package; the blacksmith is already in the
    // connected journey package.
    const inn = packet.value.edge("vb6_r00_e02_to_inn").?;
    const inn_rect = inn.origin.trigger.rectangle.?;
    const inn_cue = fieldCue("vb6_village", inn_rect.x, inn_rect.y, .up);
    var journey_consumer: consumer.Consumer = .{};
    try std.testing.expectError(error.UnavailableDestination, journey_consumer.begin(&packet.value, inn_cue, &story, journey));
    var identity_consumer: consumer.Consumer = .{};
    const inn_proposal = try identity_consumer.begin(&packet.value, inn_cue, &story, identity);
    try std.testing.expectEqualStrings("vb6_inn", inn_proposal.destination.location_id);
    try identity_consumer.cancel(inn_proposal.receipt);
    const smith = packet.value.edge("vb6_r00_e05_to_blacksmith").?;
    const smith_rect = smith.origin.trigger.rectangle.?;
    var smith_consumer: consumer.Consumer = .{};
    const smith_proposal = try smith_consumer.begin(&packet.value, fieldCue("vb6_village", smith_rect.x, smith_rect.y, .up), &story, journey);
    try std.testing.expectEqualStrings("vb6_blacksmith", smith_proposal.destination.location_id);
    try smith_consumer.cancel(smith_proposal.receipt);
}

test "field edges wait for the low dialogue barrier while world entries do not" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    var buffer: [32][]const u8 = undefined;
    const identity = locationScope(packet.value, &buffer, .identity);
    const story: event_runtime.StoryState = .{};
    const door = packet.value.edge("vb6_r00_e00_to_forest_edge").?;
    const rect = door.origin.trigger.rectangle.?;
    var blocked = fieldCue("vb6_village", rect.x, rect.y, null);
    blocked.event_flags_low2 = 1;
    var c: consumer.Consumer = .{};
    try std.testing.expectError(error.NoMatchingEdge, c.begin(&packet.value, blocked, &story, identity));
    var entry_blocked = worldCue("region_b", 86, 83);
    entry_blocked.event_flags_low2 = 1;
    const proposal = try c.begin(&packet.value, entry_blocked, &story, identity);
    try std.testing.expectEqualStrings("region_b_point_05_to_village", proposal.edge_id);
    try c.cancel(proposal.receipt);
    const ordinary = packet.value.edge("vb6_r06_e07_same_room_reconstruction").?;
    var ordinary_cue = cueFor(ordinary, null);
    ordinary_cue.event_flags_low2 = 1;
    try std.testing.expectError(error.NoMatchingEdge, c.begin(&packet.value, ordinary_cue, &story, identity));
}

test "units and reconstruction contracts are source facts" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    for (packet.value.edges) |edge| {
        if (edge.destination.spawn.domain == .field_pixel) {
            try std.testing.expectEqual(edge.destination.source_spawn.domain, .half_cell);
            try std.testing.expectEqual(edge.destination.source_spawn.x * 8, edge.destination.spawn.x);
            try std.testing.expectEqual(edge.destination.source_spawn.y * 8, edge.destination.spawn.y);
            try std.testing.expect(edge.reconstruction.required);
            try std.testing.expectEqual(edges.ConstructionStory.current_after_prefix_effects, edge.reconstruction.construction_story);
        } else {
            try std.testing.expectEqual(edge.destination.spawn.domain, .world_cell);
            try std.testing.expectEqual(edge.destination.source_spawn.domain, .world_cell);
            try std.testing.expect(!edge.reconstruction.required);
            try std.testing.expectEqual(edges.ConstructionStory.not_applicable, edge.reconstruction.construction_story);
            try std.testing.expectEqual(edges.ContinuationKind.world_ready, edge.continuation.kind);
        }
        try std.testing.expect(edge.continuation.automatic_program_id == null);
    }
    const ordinary = packet.value.edge("vb6_r06_e07_same_room_reconstruction").?;
    try std.testing.expect(ordinary.reconstruction.same_room);
    try std.testing.expectEqual(@as(i32, 27), ordinary.destination.source_spawn.x);
    try std.testing.expectEqual(@as(i32, 25), ordinary.destination.source_spawn.y);
}

test "snapshot restore replays facts and rejects tampering" {
    const packet = try loadCatalogue();
    defer packet.deinit();
    var buffer: [32][]const u8 = undefined;
    const identity = locationScope(packet.value, &buffer, .identity);
    const edge = packet.value.edge("vb6_r00_e05_to_blacksmith").?;
    const rect = edge.origin.trigger.rectangle.?;
    const cue = fieldCue("vb6_village", rect.x, rect.y, .up);
    const story: event_runtime.StoryState = .{};
    var c: consumer.Consumer = .{};
    const proposal = try c.begin(&packet.value, cue, &story, identity);
    _ = try c.acknowledgeEffect(proposal.receipt, 0);
    _ = try c.acknowledgeEffect(proposal.receipt, 1);
    const pending = c.snapshot();
    try std.testing.expectEqual(consumer.State.effects_pending, pending.state);
    try std.testing.expectEqual(@as(u8, 2), pending.next_effect);
    var restored = try consumer.Consumer.restore(&packet.value, pending, cue, &story, identity);
    try std.testing.expectEqual(consumer.State.effects_pending, restored.state);
    try std.testing.expectEqual(@as(usize, 2), restored.pending.?.next_effect);
    _ = try restored.acknowledgeEffect(pending.receipt, 2);
    const commit = try restored.commit(&packet.value, pending.receipt, &story);
    const committed = restored.snapshot();
    try std.testing.expectEqual(consumer.State.committed, committed.state);
    var committed_restore = try consumer.Consumer.restore(&packet.value, committed, cue, &story, identity);
    try committed_restore.settle(committed.receipt);
    try std.testing.expectEqual(consumer.State.idle, committed_restore.state);
    var tampered = pending;
    tampered.next_effect = 99;
    try std.testing.expectError(error.InvalidSnapshot, consumer.Consumer.restore(&packet.value, tampered, cue, &story, identity));
    tampered = pending;
    tampered.edge_id = "vb6_r00_e00_to_forest_edge";
    try std.testing.expectError(error.InvalidSnapshot, consumer.Consumer.restore(&packet.value, tampered, cue, &story, identity));
    // A committed receipt cannot be restored into a session that cannot build it.
    var journey_buffer: [32][]const u8 = undefined;
    const journey = locationScope(packet.value, &journey_buffer, .journey);
    const inn = packet.value.edge("vb6_r00_e02_to_inn").?;
    const inn_rect = inn.origin.trigger.rectangle.?;
    const inn_cue = fieldCue("vb6_village", inn_rect.x, inn_rect.y, .up);
    var inn_consumer: consumer.Consumer = .{};
    const inn_proposal = try inn_consumer.begin(&packet.value, inn_cue, &story, identity);
    for (0..inn_proposal.effects.len) |index| _ = try inn_consumer.acknowledgeEffect(inn_proposal.receipt, index);
    const inn_commit = try inn_consumer.commit(&packet.value, inn_proposal.receipt, &story);
    const inn_snapshot = inn_consumer.snapshot();
    try std.testing.expectEqualStrings(inn_commit.edge_id, inn_snapshot.edge_id);
    try std.testing.expectError(error.UnavailableDestination, consumer.Consumer.restore(&packet.value, inn_snapshot, inn_cue, &story, journey));
    try std.testing.expectEqualStrings(edge.id, commit.edge_id);
}

test "a tampered catalogue fails validation before selection" {
    var packet = try loadCatalogue();
    defer packet.deinit();
    const original_coverage = packet.value.coverage;
    const saved_first = packet.value.edges[0];
    const saved_second = packet.value.edges[1];
    packet.value.coverage.field_doorways += 1;
    try std.testing.expectError(error.InvalidEdgeCoverage, edges.validate(packet.value));
    packet.value.coverage = original_coverage;
    packet.value.edges[0].origin.event_flags_low2_clear = !saved_first.origin.event_flags_low2_clear;
    try std.testing.expectError(error.InvalidEdgeBarrier, edges.validate(packet.value));
    packet.value.edges[0] = saved_first;
    packet.value.edges[1].id = saved_first.id;
    try std.testing.expectError(error.DuplicateEdge, edges.validate(packet.value));
    packet.value.edges[1] = saved_second;
    try edges.validate(packet.value);
}

fn terminal(packet: *const edges.Packet, cue: consumer.Cue, scope: consumer.Scope) anyerror!void {
    const story: event_runtime.StoryState = .{};
    var c: consumer.Consumer = .{};
    const proposal = try c.begin(packet, cue, &story, scope);
    try c.cancel(proposal.receipt);
}
