const std = @import("std");
const routes = @import("route_transitions");
const event_runtime = @import("event_runtime");

const allocator = std.testing.allocator;

const FixtureTrigger = struct {
    kind: []const u8,
    position: ?routes.Coordinate = null,
    direction: ?routes.Direction = null,
};
const FixtureRequest = struct {
    route_id: []const u8,
    origin_id: []const u8,
    trigger: FixtureTrigger,
    story: std.json.Value,
    event_flags_low2: u2,
};
const Expected = struct {
    status: enum { plan, @"error" },
    destination_id: ?[]const u8 = null,
    spawn: ?routes.Coordinate = null,
    effect_kinds: ?[]const []const u8 = null,
    reconstruction: ?routes.Reconstruction = null,
    continuation: ?routes.Continuation = null,
    @"error": ?[]const u8 = null,
};
const Case = struct {
    id: []const u8,
    request: FixtureRequest,
    expected: Expected,
};
const Fixture = struct {
    schema: []const u8,
    id: []const u8,
    content_sha256: []const u8,
    packet_content_sha256: []const u8,
    cases: []const Case,
};

fn read(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(routes.max_json_bytes));
}

fn loadPacket(path: []const u8) !std.json.Parsed(routes.Packet) {
    const bytes = try read(path);
    defer allocator.free(bytes);
    return routes.load(allocator, bytes);
}

fn loadFixture() !std.json.Parsed(Fixture) {
    const bytes = try read("game/tests/fixtures/route_transitions.json");
    defer allocator.free(bytes);
    return std.json.parseFromSlice(Fixture, allocator, bytes, .{ .allocate = .alloc_always });
}

fn request(input: FixtureRequest) routes.Request {
    const trigger: routes.RequestTrigger = if (std.mem.eql(u8, input.trigger.kind, "field_rectangle"))
        .{ .field_rectangle = .{ .position = input.trigger.position.?, .direction = input.trigger.direction } }
    else if (std.mem.eql(u8, input.trigger.kind, "world_point"))
        .{ .world_point = input.trigger.position.? }
    else
        .{ .ordinary_event = {} };
    return .{ .route_id = input.route_id, .origin_id = input.origin_id, .trigger = trigger, .event_flags_low2 = input.event_flags_low2 };
}

fn storyFrom(value: std.json.Value) !event_runtime.StoryState {
    var story: event_runtime.StoryState = .{};
    if (value != .object) return error.InvalidFixtureStory;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.*.len != 13 or !std.mem.startsWith(u8, entry.key_ptr.*, "scenario_")) return error.InvalidFixtureStory;
        const index = try std.fmt.parseInt(u8, entry.key_ptr.*[9..], 10);
        story.scenario[index] = @intCast(entry.value_ptr.integer);
    }
    return story;
}

fn runCase(packet: routes.Packet, case: Case) !void {
    var story = try storyFrom(case.request.story);
    if (case.expected.status == .@"error") {
        if (routes.plan(packet, &story, request(case.request))) |_| {
            return error.ExpectedTransitionFailure;
        } else |err| try std.testing.expectEqualStrings(case.expected.@"error".?, @errorName(err));
        return;
    }
    const result = try routes.plan(packet, &story, request(case.request));
    try std.testing.expectEqualStrings(case.request.route_id, result.route_id);
    try std.testing.expectEqualStrings(case.expected.destination_id.?, result.destination.location_id);
    try std.testing.expect(std.meta.eql(case.expected.spawn.?, result.destination.spawn));
    const kinds = case.expected.effect_kinds.?;
    try std.testing.expectEqual(kinds.len, result.effects.len);
    for (kinds, result.effects) |kind, effect| try std.testing.expectEqualStrings(kind, @tagName(effect.kind));
    try std.testing.expect(std.meta.eql(case.expected.reconstruction.?, result.reconstruction));
    try std.testing.expect(std.meta.eql(case.expected.continuation.?, result.continuation));
}

test "language-neutral fixtures produce plans and typed failures" {
    const packet = try loadPacket("game/assets/routes/region_b_vb6_c.json");
    defer packet.deinit();
    const fixture = try loadFixture();
    defer fixture.deinit();
    try std.testing.expectEqualStrings("suikoden-route-transition-fixtures/1", fixture.value.schema);
    try std.testing.expectEqualStrings(packet.value.content_sha256, fixture.value.packet_content_sha256);
    try std.testing.expectEqual(@as(usize, 14), fixture.value.cases.len);
    for (fixture.value.cases) |case| try runCase(packet.value, case);
}

test "all 25 source routes plan without reverse inference or automatic continuation" {
    const packet = try loadPacket("game/assets/routes/region_b_vb6_c.json");
    defer packet.deinit();
    try std.testing.expectEqual(@as(usize, 25), packet.value.routes.len);
    try std.testing.expectEqual(@as(u8, 20), packet.value.coverage.field_doorways);
    try std.testing.expectEqual(@as(u8, 4), packet.value.coverage.world_entries_and_returns);
    try std.testing.expectEqual(@as(u8, 0), packet.value.coverage.unresolved);
    for (packet.value.routes) |route| {
        var story: event_runtime.StoryState = .{};
        for (route.conditions) |condition| {
            const index = try std.fmt.parseInt(u8, condition.flag.id[9..], 10);
            if (condition.kind == .story_mask_set) story.scenario[index] |= condition.flag.mask else story.scenario[index] &= ~condition.flag.mask;
        }
        const trigger: routes.RequestTrigger = switch (route.origin.trigger.kind) {
            .field_rectangle => .{ .field_rectangle = .{
                .position = .{ .domain = .field_pixel, .x = route.origin.trigger.rectangle.?.x, .y = route.origin.trigger.rectangle.?.y },
                .direction = route.origin.trigger.direction,
            } },
            .world_point => .{ .world_point = route.origin.trigger.point.? },
            .ordinary_event => .{ .ordinary_event = {} },
        };
        const result = try routes.plan(packet.value, &story, .{
            .route_id = route.id,
            .origin_id = route.origin.location_id,
            .trigger = trigger,
        });
        try std.testing.expectEqualStrings(route.id, result.route_id);
        try std.testing.expect(result.continuation.automatic_program_id == null);
        try std.testing.expect(result.reconstruction.required == (result.destination.spawn.domain == .field_pixel));
    }
}

test "unrestricted doorways accept headings and world entrances cover two by two cells" {
    const packet = try loadPacket("game/assets/routes/region_b_vb6_c.json");
    defer packet.deinit();
    var story: event_runtime.StoryState = .{};
    const doorway = packet.value.route("vb6_r00_e01_to_region_b").?;
    for ([_]?routes.Direction{ null, .down, .up, .left, .right }) |direction| {
        _ = try routes.plan(packet.value, &story, .{
            .route_id = doorway.id,
            .origin_id = doorway.origin.location_id,
            .trigger = .{ .field_rectangle = .{
                .position = .{ .domain = .field_pixel, .x = 224, .y = 360 },
                .direction = direction,
            } },
        });
    }
    for (packet.value.routes[0..2]) |route| {
        const anchor = route.origin.trigger.point.?;
        for (0..3) |dy| for (0..3) |dx| {
            const req = routes.Request{
                .route_id = route.id,
                .origin_id = route.origin.location_id,
                .trigger = .{ .world_point = .{
                    .domain = .world_cell,
                    .x = anchor.x + @as(i32, @intCast(dx)) - 1,
                    .y = anchor.y + @as(i32, @intCast(dy)) - 1,
                } },
            };
            if (dx != 0 and dy != 0) {
                _ = try routes.plan(packet.value, &story, req);
            } else {
                try std.testing.expectError(error.RouteTriggerMismatch, routes.plan(packet.value, &story, req));
            }
        };
    }
    const copied = try allocator.dupe(routes.Route, packet.value.routes);
    defer allocator.free(copied);
    var changed = packet.value;
    changed.routes = copied;
    copied[22].origin.trigger.direction = .up;
    const gated = routes.Request{
        .route_id = copied[22].id,
        .origin_id = copied[22].origin.location_id,
        .trigger = .{ .field_rectangle = .{
            .position = .{ .domain = .field_pixel, .x = 224, .y = 360 },
            .direction = .up,
        } },
    };
    _ = try routes.plan(changed, &story, gated);
    var wrong = gated;
    wrong.trigger.field_rectangle.direction = .down;
    try std.testing.expectError(error.RouteTriggerMismatch, routes.plan(changed, &story, wrong));
}

test "prefix order coordinates and E7 reconstruction remain source-explicit" {
    const packet = try loadPacket("game/assets/routes/region_b_vb6_c.json");
    defer packet.deinit();
    const village = packet.value.route("vb6_r00_e00_to_forest_edge").?;
    try std.testing.expectEqual(@as(usize, 1), village.effects.len);
    try std.testing.expect(village.effects[0].kind == .area_index_set);
    try std.testing.expectEqual(@as(u16, 0x445), village.effects[0].area_index.?);
    const forest = packet.value.route("vb6_r01_e00_to_village").?;
    try std.testing.expectEqual(@as(u16, 0x40c), forest.effects[0].area_index.?);
    const world_b = packet.value.route("vb6_r00_e01_to_region_b").?;
    try std.testing.expect(world_b.destination.spawn.domain == .world_cell);
    try std.testing.expectEqual(@as(i32, 86), world_b.destination.spawn.x);
    try std.testing.expectEqual(@as(i32, 85), world_b.destination.spawn.y);
    try std.testing.expectEqualStrings("scenario_0039", world_b.effects[0].flag.?.id);
    try std.testing.expectEqual(@as(u8, 0x10), world_b.effects[0].flag.?.mask);

    const e7 = packet.value.route("vb6_r06_e07_same_room_reconstruction").?;
    try std.testing.expectEqual(@as(usize, 12), e7.effects.len);
    try std.testing.expectEqual(@as(u32, 0x35164), e7.provenance.stream_offset.?);
    try std.testing.expectEqual(@as(u32, 0x35181), e7.effects[e7.effects.len - 1].source_offset);
    try std.testing.expectEqual(@as(i32, 216), e7.destination.spawn.x);
    try std.testing.expectEqual(@as(i32, 200), e7.destination.spawn.y);
    try std.testing.expect(e7.destination.source_spawn.domain == .half_cell);
    try std.testing.expect(e7.reconstruction.required and e7.reconstruction.same_room);
    try std.testing.expect(e7.reconstruction.construction_story == .current_after_prefix_effects);
    try std.testing.expect(e7.continuation.kind == .ordinary_source_selection);
    try std.testing.expect(e7.effects[e7.effects.len - 1].kind == .story_or);
    try std.testing.expectEqualStrings("scenario_0015", e7.effects[e7.effects.len - 1].flag.?.id);
    try std.testing.expectEqual(@as(u8, 0x40), e7.effects[e7.effects.len - 1].flag.?.mask);
    try std.testing.expectEqual(@as(usize, 2), e7.effects[2].track.?.commands.len);
    try std.testing.expect(e7.effects[2].track.?.commands[0].direction.? == .right);
    try std.testing.expectEqual(@as(u16, 22), e7.effects[2].track.?.commands[0].cells.?);
}

test "story boundaries barrier origin and trigger failures never fall back" {
    const packet = try loadPacket("game/assets/routes/region_b_vb6_c.json");
    defer packet.deinit();
    const id = "vb6_r06_e07_same_room_reconstruction";
    var story: event_runtime.StoryState = .{};
    story.scenario[15] = 0xa0;
    const result = try routes.plan(packet.value, &story, .{ .route_id = id, .origin_id = "vb6_kobold_village", .trigger = .{ .ordinary_event = {} } });
    try std.testing.expectEqualStrings(id, result.route_id);
    story.scenario[15] = 0x60;
    try std.testing.expectError(error.RouteIneligible, routes.plan(packet.value, &story, .{ .route_id = id, .origin_id = "vb6_kobold_village", .trigger = .{ .ordinary_event = {} } }));
    story.scenario[15] = 0x20;
    try std.testing.expectError(error.TransitionBarrierBlocked, routes.plan(packet.value, &story, .{ .route_id = id, .origin_id = "vb6_kobold_village", .trigger = .{ .ordinary_event = {} }, .event_flags_low2 = 3 }));
    try std.testing.expectError(error.RouteOriginMismatch, routes.plan(packet.value, &story, .{ .route_id = id, .origin_id = "region_c", .trigger = .{ .ordinary_event = {} } }));
    try std.testing.expectError(error.UnknownRoute, routes.plan(packet.value, &story, .{ .route_id = "not_a_route", .origin_id = "vb6_kobold_village", .trigger = .{ .ordinary_event = {} } }));
    const world = packet.value.route("region_c_point_06_to_kobold_village").?;
    try std.testing.expectError(error.RouteTriggerMismatch, routes.plan(packet.value, &story, .{
        .route_id = world.id,
        .origin_id = "region_c",
        .trigger = .{ .world_point = .{ .domain = .world_cell, .x = 59, .y = 38 } },
    }));
}

test "malformed references coordinates predicates and JSON fail before a plan" {
    const packet = try loadPacket("game/assets/routes/region_b_vb6_c.json");
    defer packet.deinit();
    var story: event_runtime.StoryState = .{};
    var changed = packet.value;
    const copied = try allocator.dupe(routes.Route, packet.value.routes);
    defer allocator.free(copied);
    changed.routes = copied;
    copied[0].destination.location_id = "missing_room";
    try std.testing.expectError(error.UnknownRouteDestination, routes.plan(changed, &story, .{ .route_id = copied[0].id, .origin_id = copied[0].origin.location_id, .trigger = .{ .world_point = copied[0].origin.trigger.point.? } }));
    copied[0] = packet.value.routes[0];
    copied[0].destination.spawn.x += 8;
    try std.testing.expectError(error.RouteCoordinateMismatch, routes.validate(changed));
    copied[0] = packet.value.routes[0];
    copied[1].id = copied[0].id;
    try std.testing.expectError(error.DuplicateRoute, routes.validate(changed));
    copied[1] = packet.value.routes[1];
    const conditions = try allocator.dupe(event_runtime.Condition, packet.value.routes[24].conditions);
    defer allocator.free(conditions);
    copied[24].conditions = conditions;
    conditions[0].flag.id = "scenario_0016";
    try std.testing.expectError(error.UnsupportedRoutePredicate, routes.validate(changed));
    copied[24] = packet.value.routes[24];
    changed.schema = "suikoden-route-transitions/2";
    try std.testing.expectError(error.UnsupportedRouteSchema, routes.validate(changed));
    if (routes.load(allocator, "{")) |parsed| {
        parsed.deinit();
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}
