//! HQ scene construction focused checks: headquarters stage construction from
//! source rooms/actors/doorways, story+roster presence, resource and
//! unproved-presence refusal, and save/rebuild identity retention.
//!
//! The catalogue and the actor/ground assets are compiled from the disc. Nothing
//! here executes an original instruction, opens a window or reads a save file:
//! the state objects are hand-authored test fixtures.

const std = @import("std");
const hq = @import("hq");
const scene = hq.scene;
const data = @import("hq_data").stages;
const event = @import("event_runtime");
const stage_mod = hq.stage;
const shared = @import("scene_population");

const allocator = std.testing.allocator;
const max_rooms = 64;
const max_actors = 512;

fn newState(stage_byte: u8) scene.State {
    var state: scene.State = .{};
    state.stage_byte = stage_byte;
    return state;
}

const Run = struct {
    construction: scene.Construction,
    rooms: [max_rooms]scene.RoomView,
    actors: [max_actors]scene.ActorView,

    fn init() Run {
        return .{
            .construction = undefined,
            .rooms = undefined,
            .actors = undefined,
        };
    }
};

fn run(catalogue: *const scene.Catalogue, state: *scene.State, result: *Run) !void {
    const facts = try state.facts();
    result.construction = try scene.reconstruct(catalogue, facts, &result.rooms, &result.actors);
}

fn expectActorIds(result: *const Run, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, result.construction.actors.len);
    for (expected, result.construction.actors) |want, got| {
        try std.testing.expectEqualStrings(want, got.id);
    }
}

fn expectRoomIndexes(result: *const Run, expected: []const u8) !void {
    try std.testing.expectEqual(expected.len, result.construction.rooms.len);
    for (expected, result.construction.rooms) |want, got| {
        try std.testing.expectEqual(want, got.index);
    }
}

// --- the compiled catalogue -------------------------------------------------

test "the compiled catalogue validates and binds the five accepted stages" {
    const parsed = try scene.load(allocator, data.stages_json);
    defer parsed.deinit();
    const catalogue = parsed.value;

    try std.testing.expectEqualStrings(scene.schema, catalogue.schema);
    try std.testing.expectEqual(@as(usize, 5), catalogue.stages.len);
    try std.testing.expectEqualStrings("suikoden-hq-stage-plan/1", catalogue.stage_source.schema);
    try std.testing.expectEqualStrings("0x8016f3af", catalogue.stage_source.table);

    const expected_mirror = [_]u8{ 128, 32, 24, 16, 16 };
    const expected_slot = [_]?u8{ null, 0, 1, 2, 2 };
    const expected_area = [_][]const u8{ "VB7A.BIN", "VB5AG.BIN", "VB5BG.BIN", "VB5CG.BIN", "VB5CG.BIN" };
    for (catalogue.stages, 0..) |entry, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), entry.stage);
        try std.testing.expectEqual(expected_mirror[index], entry.mirror_area_index);
        try std.testing.expectEqual(expected_slot[index], entry.castle_area_slot);
        try std.testing.expect(std.mem.endsWith(u8, entry.area.file, expected_area[index]));
        try std.testing.expectEqual(@as(u8, 2), entry.landing.room);
        try std.testing.expectEqual(@as(u16, 14), entry.landing.source_x);
        try std.testing.expectEqual(@as(u16, 15), entry.landing.source_y);
        try std.testing.expectEqual(@as(u16, 112), entry.landing.x);
        try std.testing.expectEqual(@as(u16, 120), entry.landing.y);
        try std.testing.expectEqualStrings("blinking_mirror_tier", entry.landing.identity);
    }
}

test "every stage reconstructs its landing and proved rooms from source rooms" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    const expected_rooms = [_][]const u8{
        &[_]u8{ 0, 2, 3 }, // stage 0
        &[_]u8{ 0, 1, 2, 3, 7 },
        &[_]u8{ 0, 1, 2, 3, 7 },
        &[_]u8{ 0, 1, 2, 3, 7 },
        &[_]u8{ 0, 1, 2, 3, 7 },
    };
    for (0..5) |stage_index| {
        var state = newState(@intCast(stage_index));
        var result = Run.init();
        try run(catalogue, &state, &result);
        try expectRoomIndexes(&result, expected_rooms[stage_index]);
        try std.testing.expectEqual(stage_index == 0, result.construction.actors.len == 0);
        try std.testing.expectEqual(@as(u16, 0), result.construction.skipped_unproved_entrances);
        // The landing room is always present and marked as such.
        var landing_seen = false;
        for (result.construction.rooms) |room| {
            if (room.index == 2) {
                landing_seen = true;
                try std.testing.expect(room.landing);
            }
            try std.testing.expect(std.mem.startsWith(u8, room.id, "hq_s"));
        }
        try std.testing.expect(landing_seen);
    }
}

test "every doorway destination is a materialized room of the same stage" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();
    for (catalogue.stages) |entry| {
        try std.testing.expect(entry.entrances.len > 0);
        for (entry.entrances) |entrance| {
            const origin = scene.findRoom(entry, entrance.room) orelse return error.TestUnexpectedResult;
            const destination = scene.findRoom(entry, entrance.destination.room) orelse return error.TestUnexpectedResult;
            try std.testing.expect(destination.materialized);
            _ = origin;
            // Source rectangles are byte-domain facts; a rectangle may extend
            // past a small room, so only the byte bounds are asserted here.
            try std.testing.expect(entrance.bounds.w > 0 and entrance.bounds.h > 0);
            try std.testing.expect(entrance.bounds.x <= 255 * 8 and entrance.bounds.y <= 255 * 8);
            if (entrance.proved) {
                try std.testing.expectEqual(@as(usize, 0), countUnproved(entrance.conditions));
            }
        }
    }
}

fn countUnproved(terms: []const scene.Term) usize {
    var count: usize = 0;
    for (terms) |term| if (term.kind == .unproved) {
        count += 1;
    };
    return count;
}

test "the shared actor pipeline accepts every compiled population packet" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();
    var checked: usize = 0;
    for (catalogue.stages) |entry| {
        for (entry.rooms) |room| {
            if (!room.materialized or room.entity_count == 0) continue;
            const bytes = data.populationById(room.population_id.?) orelse return error.TestUnexpectedResult;
            const packet = try shared.load(allocator, bytes);
            defer packet.deinit();
            try std.testing.expectEqualStrings(room.id, packet.value.id);
            try std.testing.expectEqual(room.entity_count, @as(u8, @intCast(packet.value.entities.len)));
            checked += 1;
        }
    }
    try std.testing.expect(checked >= 20);
}

test "the shared ground asset carries every materialized room id" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    const GroundAsset = struct {
        schema: []const u8,
        rooms: []const struct { id: []const u8 },
    };
    const ground = try std.json.parseFromSlice(GroundAsset, allocator, data.ground_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer ground.deinit();
    try std.testing.expectEqualStrings("suikoden-field-ground-geometry/1", ground.value.schema);

    for (catalogue.stages) |entry| {
        for (entry.rooms) |room| {
            if (!room.materialized) continue;
            const id = room.ground_id orelse return error.TestUnexpectedResult;
            var found = false;
            for (ground.value.rooms) |ground_room| {
                if (std.mem.eql(u8, ground_room.id, id)) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

// --- story and roster -------------------------------------------------------

test "stage 1 hall actors appear only under their source story masks" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    var state = newState(1);
    var result = Run.init();
    try run(catalogue, &state, &result);
    try expectActorIds(&result, &[_][]const u8{"hq_s1_r000_e05"});

    // scenario_0015 bit 0x02 set / 0x04 clear and scenario_0022 bit 0x08 set.
    state.story.scenario[15] = 0x02;
    state.story.scenario[22] = 0x08;
    try run(catalogue, &state, &result);
    try expectActorIds(&result, &[_][]const u8{
        "hq_s1_r000_e04",
        "hq_s1_r000_e05",
        "hq_s1_r000_e06",
        "hq_s1_r000_e07",
        "hq_s1_r000_e08",
        "hq_s1_r000_e09",
    });

    // Flipping the clear bit removes the same actors again.
    state.story.scenario[22] = 0x08 | 0x10;
    try run(catalogue, &state, &result);
    try expectActorIds(&result, &[_][]const u8{ "hq_s1_r000_e04", "hq_s1_r000_e05", "hq_s1_r000_e09" });
}

test "recruit bytes use bit0 recruited and bit1 removed, and party order gates staffing" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    var state = newState(1);
    var result = Run.init();

    // Recruited, not in the active party: the castle staff record appears.
    try state.setRecruit(92, 1);
    try run(catalogue, &state, &result);
    try expectActorIds(&result, &[_][]const u8{ "hq_s1_r000_e05", "hq_s1_r001_e03" });

    // In the active party: the same record is excluded by the party term.
    try state.setParty(&[_]u8{92});
    try run(catalogue, &state, &result);
    try expectActorIds(&result, &[_][]const u8{"hq_s1_r000_e05"});

    // Removed (bit1) is not "present"; the record disappears even out of party.
    try state.setParty(&[_]u8{});
    try state.setRecruit(92, 2);
    try run(catalogue, &state, &result);
    try expectActorIds(&result, &[_][]const u8{"hq_s1_r000_e05"});

    // Neither bit: still absent.
    try state.setRecruit(92, 0);
    try run(catalogue, &state, &result);
    try expectActorIds(&result, &[_][]const u8{"hq_s1_r000_e05"});
}

test "stage 2 ties a staff record to the story bit and a recruit-absence bit" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    var state = newState(2);
    var result = Run.init();
    state.story.scenario[31] = 0x40; // scenario_0031 bit 0x40
    try run(catalogue, &state, &result);
    var found = false;
    for (result.construction.actors) |actor| {
        if (std.mem.eql(u8, actor.id, "hq_s2_r002_e22")) found = true;
    }
    try std.testing.expect(found);

    try state.setRecruit(10, 1);
    try run(catalogue, &state, &result);
    found = false;
    for (result.construction.actors) |actor| {
        if (std.mem.eql(u8, actor.id, "hq_s2_r002_e22")) found = true;
    }
    try std.testing.expect(!found);

    // Story bit clear: the guarded record is absent even with the recruit absent.
    try state.setRecruit(10, 0);
    state.story.scenario[31] = 0;
    try run(catalogue, &state, &result);
    found = false;
    for (result.construction.actors) |actor| {
        if (std.mem.eql(u8, actor.id, "hq_s2_r002_e22")) found = true;
    }
    try std.testing.expect(!found);
}

test "stage 4 reconstructs exactly like stage 3 (same accepted area)" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    var third = newState(3);
    var fourth = newState(4);
    third.story.scenario[34] = 0x08;
    fourth.story.scenario[34] = 0x08;
    try third.setRecruit(59, 1);
    try fourth.setRecruit(59, 1);
    var a = Run.init();
    var b = Run.init();
    try run(catalogue, &third, &a);
    try run(catalogue, &fourth, &b);
    try std.testing.expectEqual(a.construction.rooms.len, b.construction.rooms.len);
    try std.testing.expectEqual(a.construction.actors.len, b.construction.actors.len);
    for (a.construction.actors, b.construction.actors) |left, right| {
        // The stable identity is the (room, entity) suffix; the stage prefix
        // differs because stage 4 is a distinct stage over the same area.
        try std.testing.expectEqualStrings(left.id[5..], right.id[5..]);
        try std.testing.expectEqual(left.room, right.room);
        try std.testing.expectEqual(left.entity_index, right.entity_index);
        try std.testing.expectEqual(left.placement, right.placement);
    }
}

test "presence terms use the documented opcode semantics" {
    const terms = [_]scene.Term{
        .{ .kind = .party_contains, .character_id = 7 },
        .{ .kind = .recruit_ever, .slot = 20 },
        .{ .kind = .level_at_least, .character_id = 7, .level = 12 },
        .{ .kind = .recruit_count_at_least, .count = 1 },
        .{ .kind = .party_count_equals, .count = 1 },
        .{ .kind = .stage_at_least, .stage = 2 },
        .{ .kind = .recruit_absent, .slot = 21 },
    };
    const story = event.StoryState{};
    var recruit: [scene.flag_slots]u8 = @splat(0);
    var levels: [scene.level_slots]u8 = @splat(0);
    recruit[20] = 2; // bit1 alone is "removed", which still counts as ever
    recruit[21] = 0;
    recruit[3] = 1; // one present recruit for the count term
    levels[7] = 12;
    const party = [_]u8{7};
    const facts = scene.Facts{
        .stage = try stage_mod.Stage.fromByte(2),
        .story = &story,
        .roster = .{ .recruit = &recruit, .party = &party, .levels = &levels },
    };
    try std.testing.expect(scene.evaluate(&terms, facts));

    // Unknown level cannot prove the level term.
    levels[7] = 0;
    try std.testing.expect(!scene.evaluate(&terms, facts));

    // A present-but-removed recruit is not "present".
    recruit[21] = 2;
    levels[7] = 12;
    try std.testing.expect(!scene.evaluate(&terms, facts));

    // An unproved semantic never spawns.
    const unproved = [_]scene.Term{.{ .kind = .unproved, .semantics = "random_quotient" }};
    try std.testing.expect(!scene.evaluate(&unproved, facts));

    // Stage threshold is the stage-plan byte, inclusive.
    const stage_terms = [_]scene.Term{.{ .kind = .stage_at_least, .stage = 3 }};
    try std.testing.expect(!scene.evaluate(&stage_terms, facts));
}

// --- refusal ----------------------------------------------------------------

const synthetic_sha = "0000000000000000000000000000000000000000000000000000000000000000";

fn syntheticStage(
    buffer: *[1]scene.StageEntry,
    rooms: []const scene.Room,
    actors: []const scene.Actor,
    entrances: []const scene.Entrance,
) scene.Catalogue {
    buffer[0] = .{
        .stage = 0,
        .mirror_area_index = 128,
        .castle_area_slot = null,
        .area = .{ .file = "DATA/02_AREA.B/VB7A.BIN", .lba = 1, .size = 2, .sha256 = synthetic_sha },
        .landing = .{ .room = 0, .source_x = 14, .source_y = 15, .x = 112, .y = 120, .identity = "blinking_mirror_tier" },
        .rooms = rooms,
        .actors = actors,
        .entrances = entrances,
    };
    return .{
        .schema = scene.schema,
        .id = "synthetic",
        .content_sha256 = synthetic_sha,
        .stage_source = .{
            .path = "game/assets/hq/stage_plan.json",
            .sha256 = synthetic_sha,
            .schema = "suikoden-hq-stage-plan/1",
            .table = "0x8016f3af",
            .bytes = "128,32,24,16,16",
        },
        .stages = buffer,
    };
}

fn syntheticRoom(index: u8, ground: bool) scene.Room {
    return .{
        .id = if (index == 0) "hq_s0_r000" else "hq_s0_r001",
        .index = index,
        .section = 0,
        .record_offset = 0,
        .width_tiles = 2,
        .height_tiles = 2,
        .width_cells = 4,
        .height_cells = 4,
        .entity_count = 0,
        .scenery_count = 0,
        .actor_ids = &[_][]const u8{},
        .entrance_ids = &[_][]const u8{},
        .reachable = true,
        .materialized = true,
        .ground_id = if (ground) (if (index == 0) "hq_s0_r000" else "hq_s0_r001") else null,
        .population_id = null,
    };
}

fn syntheticActor(classification: []const scene.Term, proved: bool, bound_resource: ?scene.Resource) scene.Actor {
    return .{
        .id = "hq_s0_r000_e00",
        .room = 0,
        .entity_index = 0,
        .record_role = .character,
        .source_flags = 3,
        .population_candidate = true,
        .source_character_id = 4,
        .resource = bound_resource,
        .position = .{ .source_x = 2, .source_y = 2, .x = 16, .y = 16 },
        .classification = classification,
        .classification_proved = proved,
        .trigger = .ordinary,
        .initialization_order = null,
        .placement = .placed,
    };
}

const resource = scene.Resource{
    .domain = .area_character_context,
    .key = "hq_s0_r000_character_004",
    .context_record = 100,
};

test "unproved presence is skipped, never defaulted to spawning" {
    const terms = [_]scene.Term{.{ .kind = .unproved, .semantics = "random_quotient" }};
    const rooms = [_]scene.Room{syntheticRoom(0, true)};
    const actors = [_]scene.Actor{syntheticActor(&terms, false, resource)};
    const entrances: [0]scene.Entrance = .{};
    var stage_buffer: [1]scene.StageEntry = undefined;
    var catalogue = syntheticStage(&stage_buffer, &rooms, &actors, &entrances);
    // An empty entrance list fails validation (a stage always has a doorway).
    try std.testing.expectError(error.InvalidStage, scene.validate(catalogue));

    // With one proved doorway the catalogue is valid; the unproved actor is
    // counted and excluded instead of spawning.
    const door = scene.Entrance{
        .id = "hq_s0_r000_e00_door",
        .room = 0,
        .entity_index = 1,
        .bounds = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .proved = true,
        .conditions = &[_]scene.Term{},
        .destination = .{ .room = 0, .source_x = 2, .source_y = 2, .x = 16, .y = 16, .domain = "half_cell" },
    };
    const doors = [_]scene.Entrance{door};
    catalogue = syntheticStage(&stage_buffer, &rooms, &actors, &doors);
    try scene.validate(catalogue);

    var state = newState(0);
    var result = Run.init();
    try run(&catalogue, &state, &result);
    try std.testing.expectEqual(@as(usize, 0), result.construction.actors.len);
    try std.testing.expectEqual(@as(u16, 1), result.construction.skipped_unproved_actors);
}

test "an unproved doorway closes a room instead of assuming it open" {
    const rooms = [_]scene.Room{ syntheticRoom(0, true), syntheticRoom(1, true) };
    const actors = [_]scene.Actor{syntheticActor(&[_]scene.Term{}, true, resource)};
    const bad_terms = [_]scene.Term{.{ .kind = .unproved, .semantics = "random_quotient" }};
    const doors = [_]scene.Entrance{.{
        .id = "hq_s0_r000_e00_door",
        .room = 0,
        .entity_index = 1,
        .bounds = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .proved = false,
        .conditions = &bad_terms,
        .destination = .{ .room = 1, .source_x = 2, .source_y = 2, .x = 16, .y = 16, .domain = "half_cell" },
    }};
    var stage_buffer: [1]scene.StageEntry = undefined;
    var catalogue = syntheticStage(&stage_buffer, &rooms, &actors, &doors);
    try scene.validate(catalogue);

    var state = newState(0);
    var result = Run.init();
    try run(&catalogue, &state, &result);
    try std.testing.expectEqual(@as(usize, 1), result.construction.rooms.len);
    try std.testing.expectEqual(@as(u8, 0), result.construction.rooms[0].index);
    try std.testing.expectEqual(@as(u16, 1), result.construction.skipped_unproved_entrances);
}

test "a character actor without its resource is refused at validation" {
    const rooms = [_]scene.Room{syntheticRoom(0, true)};
    const actors = [_]scene.Actor{syntheticActor(&[_]scene.Term{}, true, null)};
    const doors = [_]scene.Entrance{.{
        .id = "hq_s0_r000_e00_door",
        .room = 0,
        .entity_index = 1,
        .bounds = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .proved = true,
        .conditions = &[_]scene.Term{},
        .destination = .{ .room = 0, .source_x = 2, .source_y = 2, .x = 16, .y = 16, .domain = "half_cell" },
    }};
    var stage_buffer: [1]scene.StageEntry = undefined;
    const catalogue = syntheticStage(&stage_buffer, &rooms, &actors, &doors);
    try std.testing.expectError(error.InvalidActor, scene.validate(catalogue));
}

test "an output buffer that cannot hold the actors is an error, not a truncation" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    var state = newState(1);
    const facts = try state.facts();
    var rooms: [max_rooms]scene.RoomView = undefined;
    var actors: [0]scene.ActorView = .{};
    try std.testing.expectError(
        error.ActorOutputTooSmall,
        scene.reconstruct(catalogue, facts, &rooms, &actors),
    );
}

test "an unknown stage is refused" {
    const rooms = [_]scene.Room{syntheticRoom(0, true)};
    const actors = [_]scene.Actor{syntheticActor(&[_]scene.Term{}, true, resource)};
    const doors = [_]scene.Entrance{.{
        .id = "hq_s0_r000_e00_door",
        .room = 0,
        .entity_index = 1,
        .bounds = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .proved = true,
        .conditions = &[_]scene.Term{},
        .destination = .{ .room = 0, .source_x = 2, .source_y = 2, .x = 16, .y = 16, .domain = "half_cell" },
    }};
    var stage_buffer: [1]scene.StageEntry = undefined;
    const catalogue = syntheticStage(&stage_buffer, &rooms, &actors, &doors);
    try scene.validate(catalogue);
    var state = newState(1);
    var result = Run.init();
    try std.testing.expectError(error.UnknownStage, run(&catalogue, &state, &result));
}

// --- save / rebuild ---------------------------------------------------------

test "save and rebuild preserve stage, conditions and actor identity" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    var state = newState(3);
    state.story.scenario[22] = 0x08;
    state.story.scenario[15] = 0x02;
    try state.setRecruit(92, 1);
    try state.setRecruit(59, 1);
    try state.setParty(&[_]u8{ 59, 8 });
    state.levels[15] = 21;

    var first = Run.init();
    try run(catalogue, &state, &first);
    try std.testing.expect(first.construction.actors.len > 0);

    const bytes = state.encode();
    var rebuilt = try scene.State.decode(&bytes);
    var second = Run.init();
    try run(catalogue, &rebuilt, &second);

    try std.testing.expectEqual(first.construction.rooms.len, second.construction.rooms.len);
    try std.testing.expectEqual(first.construction.actors.len, second.construction.actors.len);
    try std.testing.expectEqual(first.construction.skipped_unproved_actors, second.construction.skipped_unproved_actors);
    for (first.construction.rooms, second.construction.rooms) |left, right| {
        try std.testing.expectEqualStrings(left.id, right.id);
        try std.testing.expectEqual(left.actor_count, right.actor_count);
    }
    for (first.construction.actors, second.construction.actors) |left, right| {
        try std.testing.expectEqualStrings(left.id, right.id);
        try std.testing.expectEqual(left.room, right.room);
        try std.testing.expectEqual(left.entity_index, right.entity_index);
        try std.testing.expectEqual(left.source_character_id, right.source_character_id);
        try std.testing.expectEqualStrings(left.resource_key, right.resource_key);
        try std.testing.expectEqual(left.placement, right.placement);
        try std.testing.expectEqual(left.x, right.x);
        try std.testing.expectEqual(left.y, right.y);
    }
    // The rebuilt state's facts are the saved ones, not a fresh default.
    try std.testing.expectEqual(@as(u8, 3), rebuilt.stage_byte);
    try std.testing.expectEqual(@as(u8, 0x08), rebuilt.story.scenario[22]);
    try std.testing.expectEqual(@as(u8, 1), rebuilt.recruit[92]);
    try std.testing.expectEqual(@as(usize, 2), rebuilt.party_len);
    try std.testing.expectEqual(@as(u8, 21), rebuilt.levels[15]);
}

test "tampered or out-of-domain snapshots are rejected" {
    var state = newState(2);
    try state.setRecruit(5, 1);
    try state.setParty(&[_]u8{ 5, 6 });

    var bytes = state.encode();
    bytes[0] = 'X';
    try std.testing.expectError(error.InvalidSnapshotMagic, scene.State.decode(&bytes));

    bytes = state.encode();
    bytes[8] = 9;
    try std.testing.expectError(error.UnsupportedSnapshotVersion, scene.State.decode(&bytes));

    bytes = state.encode();
    bytes[9] = 5;
    try std.testing.expectError(error.InvalidStage, scene.State.decode(&bytes));

    bytes = state.encode();
    bytes[10] = 7;
    try std.testing.expectError(error.InvalidParty, scene.State.decode(&bytes));

    bytes = state.encode();
    bytes[11] = 1;
    try std.testing.expectError(error.TamperedSnapshot, scene.State.decode(&bytes));

    bytes = state.encode();
    bytes[252] = 0xFF;
    try std.testing.expectError(error.TamperedSnapshot, scene.State.decode(&bytes));

    bytes = state.encode();
    bytes[362] = 4; // beyond party_len
    try std.testing.expectError(error.TamperedSnapshot, scene.State.decode(&bytes));

    try std.testing.expectError(error.InvalidSnapshotLength, scene.State.decode(bytes[0..100]));
}

test "reconstruction is deterministic for identical facts" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    var state = newState(2);
    state.story.scenario[22] = 0x08;
    try state.setRecruit(20, 1);
    var first = Run.init();
    var second = Run.init();
    try run(catalogue, &state, &first);
    try run(catalogue, &state, &second);
    try std.testing.expectEqual(first.construction.actors.len, second.construction.actors.len);
    for (first.construction.actors, second.construction.actors) |left, right| {
        try std.testing.expectEqualStrings(left.id, right.id);
    }
}

test "service actors are recorded as unbound headquarters interaction actors" {
    const parsed = try scene.load(allocator, data.stages_json);
    const catalogue = &parsed.value;
    defer parsed.deinit();

    var total: usize = 0;
    for (catalogue.stages) |entry| {
        for (entry.service_actors) |service| {
            try std.testing.expect(service.service_family == null);
            try std.testing.expectEqualStrings("unbound_pending_service_caller", service.binding_status);
            const actor = scene.findActor(entry, service.id) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(scene.Trigger.interaction, actor.trigger);
            try std.testing.expect(actor.population_candidate);
            total += 1;
        }
    }
    try std.testing.expect(total >= 50);
}
