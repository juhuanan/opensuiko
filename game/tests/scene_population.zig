const std = @import("std");
const population = @import("scene_population");
const event_runtime = @import("event_runtime");

const allocator = std.testing.allocator;

fn load(path: []const u8) !std.json.Parsed(population.Packet) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(population.max_json_bytes));
    defer allocator.free(bytes);
    return population.load(allocator, bytes);
}

fn expectLoadFailure(bytes: []const u8) !void {
    if (population.load(allocator, bytes)) |parsed| {
        parsed.deinit();
        return error.ExpectedPopulationLoadFailure;
    } else |_| {}
}

fn expectSelectFailure(packet: population.Packet, story: *const event_runtime.StoryState, expected: anyerror) !void {
    var output: [64]population.Entity = undefined;
    output[0] = packet.entities[0];
    try std.testing.expectError(expected, population.select(packet, .{ .story = story, .active_party_count = 0 }, &output));
    try std.testing.expectEqualStrings(packet.entities[0].id, output[0].id);
}

test "VAA validates and selects source-ordered population across audience states" {
    const fixture = try load("game/tests/fixtures/scene_population/vaa_room2.json");
    defer fixture.deinit();
    const production = try load("game/assets/scenes/population/vaa_room2.json");
    defer production.deinit();
    try std.testing.expectEqualStrings(fixture.value.content_sha256, production.value.content_sha256);
    try std.testing.expectEqual(@as(usize, 26), fixture.value.entities.len);
    try std.testing.expectEqual(@as(usize, 3), fixture.value.programs.len);

    var story: event_runtime.StoryState = .{};
    var output: [64]population.Entity = undefined;
    var result = try population.select(fixture.value, .{ .story = &story, .active_party_count = 0 }, &output);
    try std.testing.expectEqual(@as(usize, 14), result.entities.len);
    for (result.entities[1..], 1..) |entity, index| {
        try std.testing.expect(entity.source_order > result.entities[index - 1].source_order);
        try std.testing.expect(entity.population_candidate);
    }
    try std.testing.expectEqualStrings("vaa_room2_entity_22", result.entities[result.entities.len - 2].id);
    try std.testing.expectEqualStrings("vaa_room2_entity_25", result.entities[result.entities.len - 1].id);

    story.scenario[0] = 64;
    result = try population.select(fixture.value, .{ .story = &story, .active_party_count = 0 }, &output);
    try std.testing.expectEqual(@as(usize, 13), result.entities.len);
    for (result.entities) |entity| try std.testing.expect(!std.mem.eql(u8, entity.id, "vaa_room2_entity_22"));
    story.scenario[0] = 32;
    result = try population.select(fixture.value, .{ .story = &story, .active_party_count = 0 }, &output);
    try std.testing.expectEqual(@as(usize, 13), result.entities.len);
    for (result.entities) |entity| try std.testing.expect(!std.mem.eql(u8, entity.id, "vaa_room2_entity_16"));
    story.scenario[0] = 96;
    result = try population.select(fixture.value, .{ .story = &story, .active_party_count = 0 }, &output);
    try std.testing.expectEqual(@as(usize, 12), result.entities.len);
}

test "VB6 preserves staged records and adds exactly three placed records after story mask" {
    const fixture = try load("game/tests/fixtures/scene_population/vb6_room6.json");
    defer fixture.deinit();
    try std.testing.expectEqual(@as(usize, 36), fixture.value.entities.len);
    var story: event_runtime.StoryState = .{};
    var output: [64]population.Entity = undefined;
    var result = try population.select(fixture.value, .{ .story = &story, .active_party_count = 0 }, &output);
    try std.testing.expectEqual(@as(usize, 23), result.entities.len);
    for (result.entities) |entity| {
        try std.testing.expect(entity.position.placement == .off_map_staging);
        try std.testing.expectEqual(@as(i32, 2032), entity.position.x);
        try std.testing.expectEqual(@as(i32, 2032), entity.position.y);
    }
    story.scenario[19] = 8;
    result = try population.select(fixture.value, .{ .story = &story, .active_party_count = 0 }, &output);
    try std.testing.expectEqual(@as(usize, 26), result.entities.len);
    const expected = [_]struct { id: []const u8, x: i32, y: i32 }{
        .{ .id = "vb6_room6_entity_33", .x = 216, .y = 144 },
        .{ .id = "vb6_room6_entity_34", .x = 272, .y = 232 },
        .{ .id = "vb6_room6_entity_35", .x = 64, .y = 192 },
    };
    for (expected, 23..) |wanted, index| {
        try std.testing.expectEqualStrings(wanted.id, result.entities[index].id);
        try std.testing.expect(result.entities[index].position.placement == .placed);
        try std.testing.expectEqual(wanted.x, result.entities[index].position.x);
        try std.testing.expectEqual(wanted.y, result.entities[index].position.y);
    }
    try std.testing.expectEqualStrings("party_character_008", fixture.value.entities[29].resource_id.?);
    try std.testing.expect(fixture.value.entities[29].resource_domain.? == .active_party_character);
    try std.testing.expectEqual(@as(u8, 35), fixture.value.entities[35].source_order);
}

test "logical party counts do not alter either room classification" {
    inline for (.{
        "game/tests/fixtures/scene_population/vaa_room2.json",
        "game/tests/fixtures/scene_population/vb6_room6.json",
    }) |path| {
        const fixture = try load(path);
        defer fixture.deinit();
        var story: event_runtime.StoryState = .{};
        if (std.mem.eql(u8, fixture.value.id, "vb6_room6")) story.scenario[19] = 8;
        var expected_count: ?usize = null;
        for ([_]u8{ 0, 1, 3, 6 }) |count| {
            var output: [64]population.Entity = undefined;
            const result = try population.select(fixture.value, .{ .story = &story, .active_party_count = count }, &output);
            if (expected_count) |expected| try std.testing.expectEqual(expected, result.entities.len) else expected_count = result.entities.len;
            for (result.entities[1..], 1..) |entity, index| try std.testing.expect(entity.source_order > result.entities[index - 1].source_order);
        }
    }
}

test "invalid source bounds and malformed JSON fail without a population" {
    var story: event_runtime.StoryState = .{};
    try expectLoadFailure("game/tests/fixtures/scene_population/bounds_invalid.json");
    const invalid = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/scene_population/bounds_invalid.json", allocator, .limited(population.max_json_bytes));
    defer allocator.free(invalid);
    const parsed = try std.json.parseFromSlice(population.Packet, allocator, invalid, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try expectSelectFailure(parsed.value, &story, error.InvalidPopulationSourceCoordinate);

    try expectLoadFailure("{");
    const version = try load("game/tests/fixtures/scene_population/vaa_room2.json");
    defer version.deinit();
    var changed = version.value;
    changed.schema = "suikoden-scene-population/99";
    try expectSelectFailure(changed, &story, error.UnsupportedPopulationSchema);
    try expectLoadFailure("{\"schema\":\"suikoden-scene-population/1\"}");
    const valid = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/scene_population/vaa_room2.json", allocator, .limited(population.max_json_bytes));
    defer allocator.free(valid);
    const wrong_type = try allocator.dupe(u8, valid);
    defer allocator.free(wrong_type);
    const needle = "\"room\": 2";
    const at = std.mem.indexOf(u8, wrong_type, needle) orelse return error.MissingFixtureNeedle;
    wrong_type[at + needle.len - 1] = '"';
    try expectLoadFailure(wrong_type);
}

test "identity bounds duplicate and reference validation are atomic" {
    const fixture = try load("game/tests/fixtures/scene_population/vaa_room2.json");
    defer fixture.deinit();
    var story: event_runtime.StoryState = .{};
    var changed = fixture.value;
    const story_values = try allocator.dupe(population.StoryValue, fixture.value.story_values);
    defer allocator.free(story_values);
    const entities = try allocator.dupe(population.Entity, fixture.value.entities);
    defer allocator.free(entities);
    changed.story_values = story_values;
    changed.entities = entities;

    story_values[0].id = "scenario_0001";
    try expectSelectFailure(changed, &story, error.InvalidPopulationStoryValue);
    story_values[0].id = "scenario_0240";
    try expectSelectFailure(changed, &story, error.InvalidPopulationStoryValue);
    story_values[0] = fixture.value.story_values[0];

    entities[1].id = entities[0].id;
    try expectSelectFailure(changed, &story, error.DuplicatePopulationEntity);
    entities[1] = fixture.value.entities[1];
    entities[1].event.reference = entities[0].event.reference;
    try expectSelectFailure(changed, &story, error.DuplicatePopulationEventReference);
    entities[1] = fixture.value.entities[1];

    entities[22].event.program_id = "missing_program";
    try expectSelectFailure(changed, &story, error.UnknownPopulationProgram);
    entities[22] = fixture.value.entities[22];
    const terms = try allocator.dupe(population.Term, fixture.value.entities[22].classification.terms);
    defer allocator.free(terms);
    entities[22].classification.terms = terms;
    terms[0].flag.?.id = "scenario_0001";
    try expectSelectFailure(changed, &story, error.UnknownPopulationStoryValue);
    entities[22] = fixture.value.entities[22];
    entities[2].resource_id = "";
    try expectSelectFailure(changed, &story, error.InvalidPopulationId);
    entities[2] = fixture.value.entities[2];
    entities[24].event.program_id = "missing_late_program";
    try expectSelectFailure(changed, &story, error.UnknownPopulationProgram);
}

test "coordinate conversion placement and output bounds reject before writes" {
    const fixture = try load("game/tests/fixtures/scene_population/vb6_room6.json");
    defer fixture.deinit();
    var story: event_runtime.StoryState = .{};
    var changed = fixture.value;
    const entities = try allocator.dupe(population.Entity, fixture.value.entities);
    defer allocator.free(entities);
    changed.entities = entities;
    entities[33].position.x = -8;
    try expectSelectFailure(changed, &story, error.InvalidPopulationPixelCoordinate);
    entities[33] = fixture.value.entities[33];
    entities[33].position.x += 8;
    try expectSelectFailure(changed, &story, error.PopulationCoordinateMismatch);
    entities[33] = fixture.value.entities[33];
    entities[33].position.placement = .off_map_staging;
    try expectSelectFailure(changed, &story, error.InvalidPopulationPlacement);
    entities[33] = fixture.value.entities[33];
    entities[0].source_order = 1;
    try expectSelectFailure(changed, &story, error.InvalidPopulationSourceOrder);

    var output: [1]population.Entity = undefined;
    output[0] = fixture.value.entities[0];
    try std.testing.expectError(error.PopulationOutputTooSmall, population.select(fixture.value, .{ .story = &story, .active_party_count = 0 }, output[0..0]));
    try std.testing.expectEqualStrings(fixture.value.entities[0].id, output[0].id);
}

test "unsupported classification is explicit and event predicates stay separate" {
    const fixture = try load("game/tests/fixtures/scene_population/vaa_room2.json");
    defer fixture.deinit();
    var story: event_runtime.StoryState = .{};
    var changed = fixture.value;
    const entities = try allocator.dupe(population.Entity, fixture.value.entities);
    defer allocator.free(entities);
    changed.entities = entities;
    const unsupported = [_]population.Term{.{ .kind = .unsupported, .semantics = "classification_predicate_13" }};
    entities[2].classification.terms = &unsupported;
    try expectSelectFailure(changed, &story, error.UnsupportedPopulationPredicate);

    entities[2] = fixture.value.entities[2];
    entities[2].event_selection.terms = &unsupported;
    var output: [64]population.Entity = undefined;
    const result = try population.select(changed, .{ .story = &story, .active_party_count = 0 }, &output);
    try std.testing.expectEqual(@as(usize, 14), result.entities.len);
}

test "placed props interact without entering the drawable population" {
    const fixture = try load("game/tests/fixtures/scene_population/vaa_room2.json");
    defer fixture.deinit();
    var packet = fixture.value;
    const entities = try allocator.dupe(population.Entity, packet.entities);
    defer allocator.free(entities);
    packet.entities = entities;
    packet.schema = population.prop_schema;
    const prop = &entities[22];
    prop.record_role = .event;
    prop.population_candidate = false;
    prop.source_character_id = null;
    prop.resource_id = null;
    prop.resource_domain = null;
    prop.trigger = .interaction;
    try population.validate(packet);
    var story: event_runtime.StoryState = .{};
    const facts: population.Facts = .{ .story = &story, .active_party_count = 0 };
    try std.testing.expectEqual(.eligible, population.interactionEligibility(prop.*, facts));
    try std.testing.expectEqual(.ineligible, population.eligibility(prop.*, facts));
    story.scenario[0] = 64;
    try std.testing.expectEqual(.ineligible, population.interactionEligibility(prop.*, facts));
    packet.schema = population.extended_schema;
    try std.testing.expectError(error.InvalidPopulationEntityRole, population.validate(packet));
    packet.schema = population.prop_schema;
    prop.source_character_id = 255;
    try std.testing.expectError(error.InvalidPopulationEntityRole, population.validate(packet));
}

test "level predicates distinguish stored records at zero threshold" {
    var levels: [population.hq_level_slots]u8 = @splat(0);
    const story: event_runtime.StoryState = .{};
    const facts: population.Facts = .{ .story = &story, .active_party_count = 1, .levels = &levels };
    const predicate: population.Term = .{ .kind = .level_at_least, .character_id = 4, .level = 0 };
    try std.testing.expectEqual(false, population.eventTermMatchesWithFacts(predicate, facts, false, null).?);
    levels[4] = 1;
    try std.testing.expectEqual(true, population.eventTermMatchesWithFacts(predicate, facts, false, null).?);
}
