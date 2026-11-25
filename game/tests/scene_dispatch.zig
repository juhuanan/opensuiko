const std = @import("std");
const dispatch = @import("scene_dispatch");
const population = @import("scene_population");
const event_runtime = @import("event_runtime");

const allocator = std.testing.allocator;

test "borrowed predicate facts short-circuit and never guess a missing term" {
    const packet = try loadPacket();
    defer packet.deinit();
    const pop = try loadPopulation("vb6_room6");
    defer pop.deinit();
    const contents = try loadContents("vb6_room6");
    defer contents.deinit();
    const scene = packet.value.scene("vb6_room6").?;
    var story: event_runtime.StoryState = .{};
    story.scenario[15] = 40;
    var construction: event_runtime.StoryState = .{};
    construction.scenario[15] = 8;
    const Resolver = struct {
        first_x: ?bool,
        first_y: ?bool,
        calls: *[2]u8,
        fn resolve(raw: *const anyopaque, entity: u8, term: usize, _: []const u8) ?bool {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            if (entity == 0 and term < 2) {
                self.calls[term] += 1;
                return if (term == 0) self.first_x else self.first_y;
            }
            return if (entity >= 1 and entity <= 4 and term == 0) false else null;
        }
    };
    var calls: [2]u8 = .{ 0, 0 };
    var resolver: Resolver = .{ .first_x = false, .first_y = true, .calls = &calls };
    const facts: dispatch.Facts = .{
        .phase = .free_selection,
        .story = &story,
        .construction = .{ .scene_id = scene.id, .phase = .active, .population = scene.population, .bundle = scene.bundle, .story = &construction },
        .initialization_cursor = scene.initialization_count,
        .contents = contents.slice(),
        .locks = .{ .free_gate = .clear },
        .term_resolver = .{ .context = &resolver, .resolve_fn = Resolver.resolve },
    };
    const next = try dispatch.plan(packet.value, scene.id, pop.value, facts);
    try std.testing.expectEqual(.blocked, next.kind);
    try std.testing.expectEqual(@as(?u8, 7), next.source_order);
    try std.testing.expectEqual(.room_coordinate_transition, next.reason.?);
    try std.testing.expectEqualDeep([2]u8{ 1, 0 }, calls);
    resolver.first_x = true;
    resolver.first_y = null;
    const unknown = try dispatch.plan(packet.value, scene.id, pop.value, facts);
    try std.testing.expectEqual(@as(?u8, 0), unknown.source_order);
    try std.testing.expectEqual(.unsupported_predicate, unknown.reason.?);
    resolver.first_y = true;
    const earlier = try dispatch.plan(packet.value, scene.id, pop.value, facts);
    try std.testing.expectEqual(@as(?u8, 0), earlier.source_order);
    try std.testing.expectEqual(.program_not_compiled, earlier.reason.?);

    var typed = pop.value;
    const entities = try allocator.dupe(population.Entity, typed.entities);
    defer allocator.free(entities);
    typed.schema = population.coordinate_schema;
    typed.entities = entities;
    entities[0].event_selection.terms = &.{
        .{ .kind = .coordinate_range, .coordinate = .{ .axis = .x, .first = 9, .last = 10 } },
        .{ .kind = .coordinate_range, .coordinate = .{ .axis = .y, .first = 8, .last = 8 } },
    };
    var coordinate_facts = facts;
    var legacy = typed;
    legacy.schema = population.schema;
    try std.testing.expectError(error.InvalidPopulationPredicate, dispatch.plan(packet.value, scene.id, legacy, coordinate_facts));
    const missing_cell = try dispatch.plan(packet.value, scene.id, typed, coordinate_facts);
    try std.testing.expectEqual(.unsupported_predicate, missing_cell.reason.?);
    coordinate_facts.field_cell = population.Cell.fromPixels(80, 64);
    const on_edge = try dispatch.plan(packet.value, scene.id, typed, coordinate_facts);
    try std.testing.expectEqual(@as(?u8, 0), on_edge.source_order);
    try std.testing.expectEqual(.program_not_compiled, on_edge.reason.?);
    coordinate_facts.field_cell = population.Cell.fromPixels(80, 72);
    const outside = try dispatch.plan(packet.value, scene.id, typed, coordinate_facts);
    try std.testing.expectEqual(@as(?u8, 7), outside.source_order);
}

const OwnerFact = struct {
    source_order: u8,
    content_id: []const u8,
    content_sha256: []const u8,
    program_id: []const u8,
    active: bool,
    pc: u16,
    wait: ?[]const u8,
    reloop: bool,
};
const ConstructionFact = struct {
    scene_id: []const u8,
    phase: dispatch.ConstructionPhase,
    population: dispatch.Identity,
    bundle: dispatch.Identity,
    story: std.json.Value,
};
const Fact = struct {
    scene_id: []const u8,
    phase: dispatch.CallerPhase,
    story: std.json.Value,
    construction: ConstructionFact,
    initialization_cursor: u8,
    owner: ?OwnerFact,
    locks: dispatch.Locks,
    interaction_entity: ?u8,
    unsupported_terms: dispatch.UnsupportedTerms,
};
const Expected = struct {
    kind: []const u8,
    source_entity_id: ?[]const u8 = null,
    program_id: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    next_initialization_cursor: ?u8 = null,
    @"error": ?[]const u8 = null,
};
const Case = struct { id: []const u8, facts: Fact, expected: Expected };
const Fixture = struct {
    schema: []const u8,
    id: []const u8,
    content_sha256: []const u8,
    packet_content_sha256: []const u8,
    cases: []const Case,
};

fn read(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(dispatch.max_json_bytes));
}

fn loadPacket() !std.json.Parsed(dispatch.Packet) {
    const bytes = try read("game/assets/scenes/dispatch/vaa_vb6.json");
    defer allocator.free(bytes);
    return dispatch.load(allocator, bytes);
}

fn loadPopulation(scene_id: []const u8) !std.json.Parsed(population.Packet) {
    const path = if (std.mem.eql(u8, scene_id, "vaa_room2"))
        "game/assets/scenes/population/vaa_room2.json"
    else
        "game/assets/scenes/population/vb6_room6.json";
    const bytes = try read(path);
    defer allocator.free(bytes);
    return population.load(allocator, bytes);
}

const LinkedBundle = struct { contents: []const struct { content: ?event_runtime.Content = null } };
const Contents = struct {
    bundle: std.json.Parsed(LinkedBundle),
    external: ?std.json.Parsed(event_runtime.Content) = null,
    values: [8]event_runtime.Content = undefined,
    count: usize = 0,
    fn slice(self: *const Contents) []const event_runtime.Content {
        return self.values[0..self.count];
    }
    fn deinit(self: Contents) void {
        if (self.external) |external| external.deinit();
        self.bundle.deinit();
    }
};
fn loadContents(scene_id: []const u8) !Contents {
    const path = if (std.mem.eql(u8, scene_id, "vaa_room2")) "game/assets/scenes/events/vaa_room2.json" else "game/assets/scenes/events/vb6_room6.json";
    const bytes = try read(path);
    defer allocator.free(bytes);
    var result: Contents = .{ .bundle = try std.json.parseFromSlice(LinkedBundle, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) };
    errdefer result.deinit();
    for (result.bundle.value.contents) |record| if (record.content) |content| {
        result.values[result.count] = content;
        result.count += 1;
    };
    if (std.mem.eql(u8, scene_id, "vb6_room6")) {
        const external = try read("game/assets/events/vb6_room6_field_host.json");
        defer allocator.free(external);
        result.external = try std.json.parseFromSlice(event_runtime.Content, allocator, external, .{ .allocate = .alloc_always });
        result.values[result.count] = result.external.?.value;
        result.count += 1;
    }
    return result;
}

fn loadFixture() !std.json.Parsed(Fixture) {
    const bytes = try read("game/tests/fixtures/scene_dispatch.json");
    defer allocator.free(bytes);
    return std.json.parseFromSlice(Fixture, allocator, bytes, .{ .allocate = .alloc_always });
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

fn ownerFrom(value: ?OwnerFact) !?event_runtime.Instance {
    const fact = value orelse return null;
    const wait: ?event_runtime.Wait = if (fact.wait) |kind|
        .{ .kind = std.meta.stringToEnum(@FieldType(event_runtime.Wait, "kind"), kind) orelse return error.InvalidFixtureWait }
    else
        null;
    return .{
        .content_id = fact.content_id,
        .content_sha256 = fact.content_sha256,
        .program_id = fact.program_id,
        .execution = .{ .pc = fact.pc, .active = fact.active, .reloop = fact.reloop, .wait = wait },
    };
}

fn runCase(packet: dispatch.Packet, case: Case) !void {
    const pop = try loadPopulation(case.facts.scene_id);
    defer pop.deinit();
    const contents = try loadContents(case.facts.scene_id);
    defer contents.deinit();
    var story = try storyFrom(case.facts.story);
    var construction_story = try storyFrom(case.facts.construction.story);
    var owner = try ownerFrom(case.facts.owner);
    const facts = dispatch.Facts{
        .phase = case.facts.phase,
        .story = &story,
        .construction = .{
            .scene_id = case.facts.construction.scene_id,
            .phase = case.facts.construction.phase,
            .population = case.facts.construction.population,
            .bundle = case.facts.construction.bundle,
            .story = &construction_story,
        },
        .initialization_cursor = case.facts.initialization_cursor,
        .contents = contents.slice(),
        .owner = if (owner) |*value| value else null,
        .locks = case.facts.locks,
        .interaction_entity = case.facts.interaction_entity,
        .unsupported_terms = case.facts.unsupported_terms,
    };
    if (std.mem.eql(u8, case.expected.kind, "error")) {
        if (dispatch.plan(packet, case.facts.scene_id, pop.value, facts)) |_| {
            return error.ExpectedDispatchFailure;
        } else |err| try std.testing.expectEqualStrings(case.expected.@"error".?, @errorName(err));
        return;
    }
    const result = try dispatch.plan(packet, case.facts.scene_id, pop.value, facts);
    try std.testing.expectEqualStrings(case.expected.kind, @tagName(result.kind));
    if (case.expected.source_entity_id) |expected| try std.testing.expectEqualStrings(expected, result.source_entity_id.?) else try std.testing.expect(result.source_entity_id == null);
    if (case.expected.program_id) |expected| try std.testing.expectEqualStrings(expected, result.program.?.program_id) else try std.testing.expect(result.program == null);
    if (case.expected.reason) |expected| try std.testing.expectEqualStrings(expected, @tagName(result.reason.?)) else try std.testing.expect(result.reason == null);
    try std.testing.expectEqual(case.expected.next_initialization_cursor, result.next_initialization_cursor);
}

fn baseFacts(packet: dispatch.Packet, scene_id: []const u8, story: *const event_runtime.StoryState, construction_story: *const event_runtime.StoryState, contents: []const event_runtime.Content) dispatch.Facts {
    const scene = packet.scene(scene_id).?;
    return .{
        .phase = .free_selection,
        .story = story,
        .construction = .{
            .scene_id = scene_id,
            .phase = .active,
            .population = scene.population,
            .bundle = scene.bundle,
            .story = construction_story,
        },
        .initialization_cursor = scene.initialization_count,
        .contents = contents,
        .locks = .{ .free_gate = .clear, .vm_gate = .clear },
        .unsupported_terms = .all_false,
    };
}

test "language-neutral dispatch fixtures cover source phases ownership locks and blockers" {
    const packet = try loadPacket();
    defer packet.deinit();
    const fixture = try loadFixture();
    defer fixture.deinit();
    try std.testing.expectEqualStrings("suikoden-scene-dispatch-fixtures/1", fixture.value.schema);
    try std.testing.expectEqualStrings(packet.value.content_sha256, fixture.value.packet_content_sha256);
    try std.testing.expectEqual(@as(usize, 23), fixture.value.cases.len);
    for (fixture.value.cases) |case| try runCase(packet.value, case);
}

test "qualified references preserve source order execution modes and E7 separation" {
    const packet = try loadPacket();
    defer packet.deinit();
    try std.testing.expectEqual(@as(usize, 2), packet.value.scenes.len);
    try std.testing.expectEqual(@as(usize, 3), packet.value.scenes[0].entries.len);
    try std.testing.expectEqual(@as(usize, 4), packet.value.scenes[1].entries.len);
    try std.testing.expectEqual(@as(u8, 2), packet.value.scenes[0].initialization_count);
    try std.testing.expectEqual(@as(u8, 3), packet.value.scenes[1].initialization_count);
    for (packet.value.scenes) |scene| for (scene.entries) |entry| {
        if (entry.status == .executable) {
            try std.testing.expectEqual(entry.phase, entry.program.?.entry);
            try std.testing.expectEqualStrings("suikoden-event-ir/1", entry.program.?.namespace);
        } else {
            try std.testing.expect(entry.program == null and entry.blocker != null);
        }
    };
    const e7 = packet.value.scenes[1].entry(7).?;
    const e9 = packet.value.scenes[1].entry(9).?;
    try std.testing.expect(e7.status == .blocked_unsupported and e7.program == null);
    try std.testing.expect(e7.blocker.?.reason == .room_coordinate_transition);
    try std.testing.expect(e9.status == .executable);
    try std.testing.expect(!sameReferenceForTest(e7.program, e9.program));
}

fn sameReferenceForTest(a: ?dispatch.QualifiedReference, b: ?dispatch.QualifiedReference) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?.content_id, b.?.content_id) and
        std.mem.eql(u8, a.?.content_sha256, b.?.content_sha256) and
        std.mem.eql(u8, a.?.program_id, b.?.program_id);
}

test "current story drives ordinary guards without rebuilding the construction snapshot" {
    const packet = try loadPacket();
    defer packet.deinit();
    const pop = try loadPopulation("vb6_room6");
    defer pop.deinit();
    const contents = try loadContents("vb6_room6");
    defer contents.deinit();
    var story: event_runtime.StoryState = .{};
    story.scenario[15] = 0x28;
    var construction_story: event_runtime.StoryState = .{};
    construction_story.scenario[15] = 8;
    var facts = baseFacts(packet.value, "vb6_room6", &story, &construction_story, contents.slice());
    const first = try dispatch.plan(packet.value, "vb6_room6", pop.value, facts);
    try std.testing.expect(first.kind == .blocked and first.reason.? == .room_coordinate_transition);
    try std.testing.expectEqualStrings("vb6_room6_entity_07", first.source_entity_id.?);
    construction_story.scenario[15] = 0x40;
    facts.construction.phase = .recreated;
    const second = try dispatch.plan(packet.value, "vb6_room6", pop.value, facts);
    try std.testing.expect(std.meta.eql(first, second));
    story.scenario[15] = 0;
    const third = try dispatch.plan(packet.value, "vb6_room6", pop.value, facts);
    try std.testing.expect(third.kind == .no_candidate and third.reason.? == .no_ordinary_match);
}

test "stale construction population source entity and owner references fail closed" {
    const packet = try loadPacket();
    defer packet.deinit();
    const pop = try loadPopulation("vb6_room6");
    defer pop.deinit();
    const contents = try loadContents("vb6_room6");
    defer contents.deinit();
    var story: event_runtime.StoryState = .{};
    story.scenario[15] = 0x28;
    var construction_story: event_runtime.StoryState = .{};
    var facts = baseFacts(packet.value, "vb6_room6", &story, &construction_story, contents.slice());
    var changed = packet.value;
    const scenes = try allocator.dupe(dispatch.Scene, packet.value.scenes);
    defer allocator.free(scenes);
    changed.scenes = scenes;
    scenes[1].population.content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.StaleDispatchPopulation, dispatch.plan(changed, "vb6_room6", pop.value, facts));
    scenes[1] = packet.value.scenes[1];
    const entries = try allocator.dupe(dispatch.Entry, packet.value.scenes[1].entries);
    defer allocator.free(entries);
    scenes[1].entries = entries;
    entries[3].source_order = 8;
    try std.testing.expectError(error.DispatchEntityMismatch, dispatch.plan(changed, "vb6_room6", pop.value, facts));
    entries[3] = packet.value.scenes[1].entries[3];
    entries[1].program.?.entry = .ordinary;
    try std.testing.expectError(error.InvalidDispatchProgramReference, dispatch.plan(changed, "vb6_room6", pop.value, facts));
    entries[1] = packet.value.scenes[1].entries[1];
    entries[2].program = entries[3].program;
    try std.testing.expectError(error.InvalidDispatchEntry, dispatch.plan(changed, "vb6_room6", pop.value, facts));
    facts.construction.bundle.content_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    try std.testing.expectError(error.StaleDispatchConstruction, dispatch.plan(packet.value, "vb6_room6", pop.value, facts));
}

test "unsupported dependencies callback phases and invalid ownership are distinct" {
    const packet = try loadPacket();
    defer packet.deinit();
    const pop = try loadPopulation("vb6_room6");
    defer pop.deinit();
    const contents = try loadContents("vb6_room6");
    defer contents.deinit();
    var story: event_runtime.StoryState = .{};
    var construction_story: event_runtime.StoryState = .{};
    var facts = baseFacts(packet.value, "vb6_room6", &story, &construction_story, contents.slice());
    facts.locks.free_gate = .unsupported;
    try std.testing.expectError(error.UnsupportedDispatchDependency, dispatch.plan(packet.value, "vb6_room6", pop.value, facts));
    facts.locks.free_gate = .clear;
    facts.phase = .area_49c_callback;
    try std.testing.expectError(error.UnsupportedDispatchPhase, dispatch.plan(packet.value, "vb6_room6", pop.value, facts));
    facts.phase = .event_frame;
    try std.testing.expectError(error.InvalidDispatchOwnership, dispatch.plan(packet.value, "vb6_room6", pop.value, facts));
    const reference = packet.value.scenes[1].entry(5).?.program.?;
    var owner: event_runtime.Instance = .{
        .content_id = reference.content_id,
        .content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .program_id = reference.program_id,
    };
    facts.owner = &owner;
    try std.testing.expectError(error.UnknownDispatchOwner, dispatch.plan(packet.value, "vb6_room6", pop.value, facts));
}

test "malformed dispatch JSON and schema fail before planning" {
    if (dispatch.load(allocator, "{")) |parsed| {
        parsed.deinit();
        return error.ExpectedMalformedDispatchFailure;
    } else |_| {}
    const packet = try loadPacket();
    defer packet.deinit();
    var changed = packet.value;
    changed.schema = "suikoden-scene-dispatch/2";
    try std.testing.expectError(error.UnsupportedDispatchSchema, dispatch.validate(changed));
}

test "source-only initializer cannot borrow another real initializer program" {
    const packet = try loadPacket();
    defer packet.deinit();
    const pop = try loadPopulation("vb6_room6");
    defer pop.deinit();
    const contents = try loadContents("vb6_room6");
    defer contents.deinit();
    var story: event_runtime.StoryState = .{};
    story.scenario[15] = 0x40;
    var construction_story: event_runtime.StoryState = .{};
    var changed = packet.value;
    const scenes = try allocator.dupe(dispatch.Scene, packet.value.scenes);
    defer allocator.free(scenes);
    changed.scenes = scenes;
    const original = scenes[1].entries;
    const entries = try allocator.alloc(dispatch.Entry, original.len + 1);
    defer allocator.free(entries);
    @memcpy(entries[0..original.len], original);
    entries[original.len] = scenes[1].entry(6).?;
    entries[original.len].source_entity_id = "vb6_room6_entity_08";
    entries[original.len].source_order = 8;
    scenes[1].entries = entries;
    var facts = baseFacts(changed, "vb6_room6", &story, &construction_story, contents.slice());
    facts.phase = .construction_initialization;
    facts.construction.phase = .constructing;
    facts.initialization_cursor = 1;
    const before_story = story;
    const before_construction = construction_story;
    try std.testing.expectError(error.DispatchProgramEntityMismatch, dispatch.plan(changed, "vb6_room6", pop.value, facts));
    try std.testing.expect(std.meta.eql(before_story, story) and std.meta.eql(before_construction, construction_story));
    facts.contents = &.{};
    facts.initialization_cursor = 0;
    try std.testing.expectError(error.MissingDispatchProgramContent, dispatch.plan(packet.value, "vb6_room6", pop.value, facts));
}

test "missing host gates never assume admission or completion" {
    const packet = try loadPacket();
    defer packet.deinit();
    const pop = try loadPopulation("vb6_room6");
    defer pop.deinit();
    const contents = try loadContents("vb6_room6");
    defer contents.deinit();
    var story: event_runtime.StoryState = .{};
    var construction_story: event_runtime.StoryState = .{};
    var facts = baseFacts(packet.value, "vb6_room6", &story, &construction_story, contents.slice());
    facts.locks = .{};
    try std.testing.expectError(error.UnsupportedDispatchDependency, dispatch.plan(packet.value, "vb6_room6", pop.value, facts));
    const ref = packet.value.scenes[1].entry(5).?.program.?;
    var owner: event_runtime.Instance = .{ .content_id = ref.content_id, .content_sha256 = ref.content_sha256, .program_id = ref.program_id, .execution = .{ .active = false, .pc = 28 } };
    facts.phase = .event_frame;
    facts.owner = &owner;
    const saved = owner;
    try std.testing.expectError(error.UnsupportedDispatchDependency, dispatch.plan(packet.value, "vb6_room6", pop.value, facts));
    facts.locks.completion_gate = .blocked;
    const waiting = try dispatch.plan(packet.value, "vb6_room6", pop.value, facts);
    try std.testing.expect(waiting.kind == .wait_current_instance and waiting.action == .none and waiting.reason.? == .completion_gate);
    facts.locks.completion_gate = .clear;
    const completed = try dispatch.plan(packet.value, "vb6_room6", pop.value, facts);
    try std.testing.expect(completed.kind == .no_candidate and completed.action == .rearm_free_selection);
    try std.testing.expect(std.meta.eql(saved, owner));
}
