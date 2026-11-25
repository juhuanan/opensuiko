//! Source-qualified VAA palace rooms, field actors and onward route bindings.
const std = @import("std");
const ground = @import("travel").ground;
const field_actors = @import("field_actors");
const event_runtime = @import("event_runtime");
const field_events = @import("field_events");
const motion = @import("opening_audience");
const scene_population = @import("scene_population");
const field = @import("field");

const destination_data = @import("opening_assets").destination;
pub const asset_sha256 = destination_data.asset_sha256;
pub const ground_asset_sha256 = destination_data.ground_sha256;
pub const schema = "suikoden-opening-destination/1";
pub const Source = struct { file: []const u8, sha256: []const u8, lba: u32, size: u32 };
pub const GroundIdentity = struct { id: []const u8, sha256: []const u8 };
pub const RoomDescriptorContext = struct { room: []const u8, value: u8, entry_title_hold: bool };
pub const Opcode0eRecord = struct {
    index: u16,
    source_offset: u32,
    x: u8,
    y: u8,
    kind: u8,
    order: u8,
    width_cells: u8,
    height_cells: u8,
    level: u8,
    initial_flags: u8,
    eligible: bool,
};
pub const Opcode0eProbe = struct {
    hero_cell: [2]u8,
    facing: []const u8,
    query_cell: [2]u8,
    hit_record_indexes: []const u16,
    result: []const u8,
    dispatch_if_hit: u16,
};
pub const Opcode0eSourceState = struct {
    schema: []const u8,
    room_index: u8,
    room_record_byte_7: u8,
    record_count: u16,
    record_source_base: ?u32,
    record_stride: u8,
    runtime_record_stride: u8,
    flags_initialization: []const u8,
    eligibility_mask: u8,
    eligible_record_indexes: []const u16,
    levels: []const u8,
    records: []const Opcode0eRecord,
    home_door_probe: ?Opcode0eProbe = null,
};
pub const Descriptor07Operation = struct {
    selector: u8,
    mode: u8,
    value: u8,
    entity: u8,
    descriptor_write: struct { descriptor_offset: u8, value: u8 },
    follow_up: []const u8,
    writer: []const u8,
    follow_up_handler: ?[]const u8 = null,
};
pub const DescriptorBaseline = struct {
    selector: u8,
    entity: u8,
    actor_id: []const u8,
    classifier: u32,
    source_character_id: u8,
    initial: struct { plus_0: u8, plus_1: u8, plus_4: u8, plus_5: u8, plus_6: u8, plus_7: u8 },
    after_direct_writes: struct { plus_0: u8, plus_1: u8, plus_4: u8, plus_5: u8, plus_6: u8, plus_7: u8 },
    parallel_state: struct {
        selector_index: u8,
        row_stride: u8,
        descriptor_pointer_entity: u8,
        bytes_0_to_3: []const u8,
        pointer_at_plus_4: []const u8,
    },
};
pub const Initializer07 = struct {
    source_entity: u8,
    stream: u32,
    source_bytes: []const u8,
    selected_on_story: []const u8,
    selected_initializers: []const u8,
    instructions: std.json.Value,
    operations: []const Descriptor07Operation,
    descriptor_baselines: []const DescriptorBaseline,
    source_witnesses: std.json.Value,
};
pub const Term = struct { kind: []const u8, semantics: []const u8 };
pub const Guard = struct { pointer_state: []const u8, terms: []const Term };
pub const QualifiedGuard = struct {
    units: []const u8,
    x_min: u8,
    x_max: u8,
    y_min: u8,
    y_max: u8,
    bounds: []const u8,
    entry_flags: u16,
    predicate_bytes: []const u8,
};
pub const Route = struct {
    source_room: u8,
    source_entity: u8,
    program_id: []const u8,
    stream: u32,
    guard: Guard,
    guard_provenance: std.json.Value,
    instructions: std.json.Value,
    destination: []const u8,
    x: u16,
    y: u16,
    qualified_guard: QualifiedGuard,

    pub fn matchesCell(self: Route, x: u8, y: u8) bool {
        const g = self.qualified_guard;
        return x >= g.x_min and x <= g.x_max and y >= g.y_min and y <= g.y_max;
    }
};
pub const OrdinaryRoute = struct {
    source_room: u8,
    source_entity: u8,
    program_id: []const u8,
    stream: u32,
    guard: Guard,
    guard_provenance: std.json.Value,
    instructions: std.json.Value,
    destination: []const u8,
    x: u16,
    y: u16,
    qualified_guard: ?QualifiedGuard = null,

    pub fn matchesCell(self: OrdinaryRoute, x: u8, y: u8) bool {
        const g = self.qualified_guard orelse return false;
        return x >= g.x_min and x <= g.x_max and y >= g.y_min and y <= g.y_max;
    }
};
pub const Constructor = struct {
    room_record_byte7: []const RoomDescriptorContext,
    section: u32,
    cell_capacity: u32,
    bindings: std.json.Value,
    actors: std.json.Value,
    actor_proofs: std.json.Value,
    source_records: std.json.Value,
    field_actors: field_actors.Packet,
    animations: []const motion.Animation,
    field_population: scene_population.Packet,
    events: event_runtime.Content,
    context: field_events.Context,
    dialogue: field_events.DialogueData,
    route_population: scene_population.Packet,
    route_events: event_runtime.Content,
    route_context: field_events.Context,
    construction_story: event_runtime.StoryState,
    initialization: std.json.Value,
    va1_room1: Va1Room1,
    va1_room2: Va1Room2,
    room10_section: u32,
    room10_cell_capacity: u32,
    room10_bindings: std.json.Value,
    room10_actors: std.json.Value,
    room10_actor_proofs: std.json.Value,
    room10_source_records: std.json.Value,
    room10_field_actors: field_actors.Packet,
    room10_animations: []const motion.Animation,
    room10_population: scene_population.Packet,
    room10_events: event_runtime.Content,
    room10_context: field_events.Context,
    room10_initialization: std.json.Value,
    va1_room0: TownRoom,
    status: []const u8,
    reason: []const u8,
};
pub const TownRoom = struct {
    section: u32,
    cell_capacity: u32,
    bindings: std.json.Value,
    actors: std.json.Value,
    actor_proofs: std.json.Value,
    source_records: std.json.Value,
    field_actors: field_actors.Packet,
    animations: []const motion.Animation,
    population: scene_population.Packet,
    events: event_runtime.Content,
    context: field_events.Context,
    dialogue: field_events.DialogueData,
    initialization: std.json.Value,
    route_frontier: std.json.Value,
    interaction_proof: std.json.Value,
    spawn: [2]u16,
    path_to_entity_27_cells: []const [2]u16,
    compact_slots: std.json.Value,
    free_guards: []const TownFreeGuard,
    path_to_home_door_cells: []const [2]u16,
    home_door_path_proof: std.json.Value,
    home_door_event_proof: std.json.Value,
    opcode0e_source_state: Opcode0eSourceState,
};
pub const Va1Room1 = struct {
    section: u32,
    cell_capacity: u32,
    room_record_byte7: u8,
    bindings: std.json.Value,
    actors: std.json.Value,
    actor_proofs: std.json.Value,
    source_records: std.json.Value,
    field_actors: field_actors.Packet,
    animations: []const motion.Animation,
    population: scene_population.Packet,
    events: event_runtime.Content,
    context: field_events.Context,
    dialogue: field_events.DialogueData,
    compact_slots: std.json.Value,
    initializer07: Initializer07,
    opcode0e_source_state: Opcode0eSourceState,
    stairs: []const Va1StairRoute,
    path_to_stair_cells: []const [2]u16,
    path_to_stair_proof: std.json.Value,
};
pub const Va1StairRoute = struct {
    entity: u8,
    program_id: []const u8,
    source_stream: u32,
    source_bytes: []const u8,
    guard: std.json.Value,
    instructions: std.json.Value,
    destination: []const u8,
    pixel: [2]u16,
    transition_mapping: std.json.Value,
    cue_table_selector: u8,
    cue: u16,
};
pub const Va1Room2 = struct {
    section: u32,
    cell_capacity: u32,
    room_record_byte7: u8,
    bindings: std.json.Value,
    actors: std.json.Value,
    actor_proofs: std.json.Value,
    source_records: std.json.Value,
    field_actors: field_actors.Packet,
    animations: []const motion.Animation,
    population: scene_population.Packet,
    events: event_runtime.Content,
    context: field_events.Context,
    dialogue: field_events.DialogueData,
    compact_slots: std.json.Value,
    initializer_candidates: std.json.Value,
    source_admission: []const u8,
};
pub const TownGuardTerm = struct {
    kind: enum { x_range, y_range, up_input, story_mask_set, story_mask_clear, unsupported },
    opcode: u8,
    operands: []const u8 = &.{},
    min_cell: ?u8 = null,
    max_cell: ?u8 = null,
    mask: ?u8 = null,
    story_index: ?u8 = null,
    semantics: ?[]const u8 = null,
};
pub const TownFreeGuard = struct {
    source_order: u8,
    entity: u8,
    predicate_offset: u32,
    predicate_bytes: []const u8,
    terms: []const TownGuardTerm,
};
pub const Asset = struct {
    schema: []const u8,
    source: Source,
    va1_source: Source,
    route: Route,
    ordinary_routes: []const OrdinaryRoute,
    ground_sha256: []const u8,
    ground_rooms: []const GroundIdentity,
    walkable: []const u8,
    room10_walkable: []const u8,
    va1_walkable: []const u8,
    va1_room1_walkable: []const u8,
    va1_room2_walkable: []const u8,
    width: u16,
    height: u16,
    population: std.json.Value,
    source_population: std.json.Value,
    constructor: Constructor,
    content_sha256: []const u8,
};
pub const Opened = struct {
    parsed: std.json.Parsed(Asset),
    geometry: *ground.Geometry,
    pub fn deinit(self: *Opened) void {
        self.geometry.deinit();
        self.parsed.deinit();
    }
    pub fn room(self: *const Opened) *const ground.Room {
        return self.geometry.roomById("vaa_room_0").?;
    }

    pub fn fieldRoom(self: *const Opened) field.Room {
        const asset = &self.parsed.value;
        return .{ .id = "vaa_room_0", .title = "VAA Room 0", .width = asset.width, .height = asset.height, .walkable = asset.walkable, .draws = &.{}, .npcs = &.{}, .exits = &.{} };
    }

    pub fn fieldRoomFor(self: *const Opened, room_id: []const u8) ?field.Room {
        const asset = &self.parsed.value;
        const retained_room = self.geometry.roomById(room_id) orelse return null;
        const walkable = if (std.mem.eql(u8, room_id, "vaa_room_0")) asset.walkable else if (std.mem.eql(u8, room_id, "vaa_room_10")) asset.room10_walkable else if (std.mem.eql(u8, room_id, "va1_room_0")) asset.va1_walkable else if (std.mem.eql(u8, room_id, "va1_room_1")) asset.va1_room1_walkable else if (std.mem.eql(u8, room_id, "va1_room_2")) asset.va1_room2_walkable else return null;
        return .{ .id = retained_room.id, .title = retained_room.id, .width = @as(i32, retained_room.width_cells) * 8, .height = @as(i32, retained_room.height_cells) * 8, .walkable = walkable, .draws = &.{}, .npcs = &.{}, .exits = &.{} };
    }

    pub fn groundRoom(self: *const Opened, room_id: []const u8) ?*const ground.Room {
        return self.geometry.roomById(room_id);
    }

    pub fn groundIdentity(self: *const Opened, room_id: []const u8) ?[]const u8 {
        for (self.parsed.value.ground_rooms) |identity| {
            if (std.mem.eql(u8, identity.id, room_id)) return identity.sha256;
        }
        return null;
    }

    /// Source ground query for the imported rooms.  `null` means this asset
    /// carries no decoded ground for that room, never "walkable".
    pub fn walkableAt(self: *const Opened, room_id: []const u8, x: i32, y: i32) ?bool {
        const retained = self.groundRoom(room_id) orelse return null;
        if (x < 0 or y < 0) return null;
        const cell_x: u16 = @intCast(@divTrunc(x, 8));
        const cell_y: u16 = @intCast(@divTrunc(y, 8));
        if (cell_x >= retained.width_cells or cell_y >= retained.height_cells) return false;
        return ground.groundAt(retained, cell_x, cell_y, 0).walkable;
    }

    pub fn roomRecordByte7(self: *const Opened, room_id: []const u8) ?u8 {
        for (self.parsed.value.constructor.room_record_byte7) |record| {
            if (std.mem.eql(u8, record.room, room_id)) return record.value;
        }
        return null;
    }

    pub fn roomDescriptorContext(self: *const Opened, room_id: []const u8) ?RoomDescriptorContext {
        for (self.parsed.value.constructor.room_record_byte7) |record| {
            if (std.mem.eql(u8, record.room, room_id)) return record;
        }
        return null;
    }

    pub fn va1Room1(self: *const Opened) *const Va1Room1 {
        return &self.parsed.value.constructor.va1_room1;
    }
    pub fn va1Room2(self: *const Opened) *const Va1Room2 {
        return &self.parsed.value.constructor.va1_room2;
    }

    /// Evaluate the first source-ordered free-event guard at a field cell.
    /// Unknown source predicates are a hard stop once prior known terms pass.
    pub fn firstTownOrdinary(self: *const Opened, x_cell: u16, y_cell: u16, up_held: bool, story: event_runtime.StoryState) !?u8 {
        if (!std.mem.eql(u8, story.schema, "suikoden-event-story/1")) return error.InvalidTownOrdinaryStory;
        for (self.parsed.value.constructor.va1_room0.free_guards) |guard| {
            var matches = true;
            for (guard.terms) |term| {
                switch (term.kind) {
                    .x_range => {
                        const low = term.min_cell orelse return error.InvalidTownOrdinaryGuard;
                        const high = term.max_cell orelse return error.InvalidTownOrdinaryGuard;
                        if (x_cell < low or x_cell > high) {
                            matches = false;
                            break;
                        }
                    },
                    .y_range => {
                        const low = term.min_cell orelse return error.InvalidTownOrdinaryGuard;
                        const high = term.max_cell orelse return error.InvalidTownOrdinaryGuard;
                        if (y_cell < low or y_cell > high) {
                            matches = false;
                            break;
                        }
                    },
                    .up_input => {
                        if (term.mask == null or term.mask.? != 0x04) return error.InvalidTownOrdinaryGuard;
                        if (!up_held) {
                            matches = false;
                            break;
                        }
                    },
                    .story_mask_set, .story_mask_clear => {
                        const index = term.story_index orelse return error.InvalidTownOrdinaryGuard;
                        const mask = term.mask orelse return error.InvalidTownOrdinaryGuard;
                        if (index >= story.scenario.len or mask == 0) return error.InvalidTownOrdinaryGuard;
                        const set = story.scenario[index] & mask != 0;
                        if (set != (term.kind == .story_mask_set)) {
                            matches = false;
                            break;
                        }
                    },
                    .unsupported => return error.UnsupportedPotentialTownOrdinaryPredicate,
                }
            }
            if (matches) return guard.entity;
        }
        return null;
    }

    pub fn route(self: *const Opened, source_room: u8, source_entity: u8) ?OrdinaryRoute {
        for (self.parsed.value.ordinary_routes) |entry| {
            if (entry.source_room == source_room and entry.source_entity == source_entity) return entry;
        }
        return null;
    }

    pub fn bindingRoom(self: *const Opened, base: field_events.Binding, room_id: []const u8) !field_events.Binding {
        var result = base;
        var selected_dialogue = self.parsed.value.constructor.dialogue;
        if (std.mem.eql(u8, room_id, "vaa_room_0")) {
            result.room = self.parsed.value.constructor.context.room;
            result.context = self.parsed.value.constructor.context;
            result.content = self.parsed.value.constructor.events;
            result.population = self.parsed.value.constructor.field_population;
            result.ordinary = self.parsed.value.constructor.field_actors;
            result.animations = self.parsed.value.constructor.animations;
            result.ground = null;
            result.spatial_source = null;
            const hero_context = self.roomDescriptorContext(room_id) orelse return error.MissingSourceRoomRecordByte7;
            result.hero_descriptor = .{ .room_byte7 = hero_context.value, .entry_title_hold = hero_context.entry_title_hold };
        } else if (std.mem.eql(u8, room_id, "vaa_room_1")) {
            result.room = self.parsed.value.constructor.route_context.room;
            result.context = self.parsed.value.constructor.route_context;
            result.content = self.parsed.value.constructor.route_events;
            result.population = self.parsed.value.constructor.route_population;
            result.ordinary = null;
            result.animations = &.{};
            result.ground = null;
            result.spatial_source = null;
        } else if (std.mem.eql(u8, room_id, "vaa_room_10")) {
            result.room = self.parsed.value.constructor.room10_context.room;
            result.context = self.parsed.value.constructor.room10_context;
            result.content = self.parsed.value.constructor.room10_events;
            result.population = self.parsed.value.constructor.room10_population;
            result.ordinary = self.parsed.value.constructor.room10_field_actors;
            result.animations = self.parsed.value.constructor.room10_animations;
            result.ground = null;
            result.spatial_source = null;
            const hero_context = self.roomDescriptorContext(room_id) orelse return error.MissingSourceRoomRecordByte7;
            result.hero_descriptor = .{ .room_byte7 = hero_context.value, .entry_title_hold = hero_context.entry_title_hold };
        } else if (std.mem.eql(u8, room_id, "va1_room_0")) {
            const town = self.parsed.value.constructor.va1_room0;
            result.room = town.context.room;
            result.context = town.context;
            result.content = town.events;
            result.population = town.population;
            result.ordinary = town.field_actors;
            result.animations = town.animations;
            result.ground = null;
            result.spatial_source = .{ .source_sha256 = self.parsed.value.va1_source.sha256, .room = 0, .levels = town.opcode0e_source_state.levels };
            selected_dialogue = town.dialogue;
            const hero_context = self.roomDescriptorContext(room_id) orelse return error.MissingSourceRoomRecordByte7;
            result.hero_descriptor = .{ .room_byte7 = hero_context.value, .entry_title_hold = hero_context.entry_title_hold };
        } else if (std.mem.eql(u8, room_id, "va1_room_1")) {
            const home = self.parsed.value.constructor.va1_room1;
            result.room = home.context.room;
            result.context = home.context;
            result.content = home.events;
            result.population = home.population;
            result.ordinary = home.field_actors;
            result.animations = home.animations;
            result.ground = null;
            result.spatial_source = null;
            const hero_context = self.roomDescriptorContext(room_id) orelse return error.MissingSourceRoomRecordByte7;
            result.hero_descriptor = .{ .room_byte7 = hero_context.value, .entry_title_hold = hero_context.entry_title_hold };
            selected_dialogue = home.dialogue;
        } else if (std.mem.eql(u8, room_id, "va1_room_2")) {
            const next = self.parsed.value.constructor.va1_room2;
            result.room = next.context.room;
            result.context = next.context;
            result.content = next.events;
            result.population = next.population;
            result.ordinary = next.field_actors;
            result.animations = next.animations;
            result.ground = null;
            result.spatial_source = null;
            const hero_context = self.roomDescriptorContext(room_id) orelse return error.MissingSourceRoomRecordByte7;
            result.hero_descriptor = .{ .room_byte7 = hero_context.value, .entry_title_hold = hero_context.entry_title_hold };
            selected_dialogue = next.dialogue;
        } else return error.UnsupportedDestinationRoom;
        result.dialogue = selected_dialogue;
        result.dispatch = null;
        result.queues.graphics = null;
        return result;
    }

    pub fn binding(self: *const Opened, base: field_events.Binding, source_route: bool) field_events.Binding {
        return self.bindingRoom(base, if (source_route) "vaa_room_1" else "vaa_room_0") catch unreachable;
    }

    pub fn validateFreshStory(self: *const Opened, story: event_runtime.StoryState) !void {
        const expected = self.parsed.value.constructor.construction_story;
        if (!std.mem.eql(u8, story.schema, expected.schema) or !std.mem.eql(u8, &story.scenario, &expected.scenario))
            return error.InvalidDestinationConstructionStory;
    }
};

fn freshConstructionStory(story: event_runtime.StoryState) bool {
    if (!std.mem.eql(u8, story.schema, "suikoden-event-story/1") or story.scenario[0] != 0x40) return false;
    for (story.scenario[1..]) |value| if (value != 0) return false;
    return true;
}

pub fn open(allocator: std.mem.Allocator, bytes: []const u8, geometry_bytes: []const u8) !Opened {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, asset_sha256)) return error.InvalidDestinationDigest;
    std.crypto.hash.sha2.Sha256.hash(geometry_bytes, &digest, .{});
    const ground_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &ground_hex, ground_asset_sha256)) return error.InvalidDestinationGroundDigest;
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    const a = parsed.value;
    if (!std.mem.eql(u8, a.schema, schema) or a.content_sha256.len != 64 or
        !std.mem.eql(u8, a.ground_sha256, ground_asset_sha256) or a.ground_rooms.len != 5 or
        !std.mem.eql(u8, a.ground_rooms[0].id, "vaa_room_0") or a.ground_rooms[0].sha256.len != 64 or
        !std.mem.eql(u8, a.ground_rooms[1].id, "vaa_room_10") or a.ground_rooms[1].sha256.len != 64 or
        !std.mem.eql(u8, a.ground_rooms[2].id, "va1_room_0") or a.ground_rooms[2].sha256.len != 64 or
        !std.mem.eql(u8, a.ground_rooms[3].id, "va1_room_1") or a.ground_rooms[3].sha256.len != 64 or
        !std.mem.eql(u8, a.ground_rooms[4].id, "va1_room_2") or a.ground_rooms[4].sha256.len != 64 or
        !std.mem.eql(u8, a.source.file, "DATA/01_AREA.A/VAA.BIN") or
        !std.mem.eql(u8, a.source.sha256, "c029671098582c2668fd15161b753df6723b8074ac4e0c0c4a61c0caaea97110") or
        a.source.lba != 51822 or a.source.size != 447732 or
        !std.mem.eql(u8, a.va1_source.file, "DATA/01_AREA.A/VA1.BIN") or
        !std.mem.eql(u8, a.va1_source.sha256, "dcca6119f28f3863250f31be8cd164d4795eaa493aeec5b51ca0737690979fed") or
        a.va1_source.lba != 50475 or a.va1_source.size != 452536 or
        a.route.source_room != 1 or a.route.source_entity != 1 or a.route.stream != 328084 or
        !std.mem.eql(u8, a.route.program_id, "vaa_r01_e01_exit") or
        !std.mem.eql(u8, a.route.destination, "vaa_room_0") or a.route.x != 312 or a.route.y != 104 or
        a.width != 1280 or a.height != 768 or a.walkable.len != 160 * 96 or a.walkable[13 * 160 + 39] != '1' or
        !std.mem.eql(u8, a.route.qualified_guard.units, "8-pixel cells") or
        !std.mem.eql(u8, a.route.qualified_guard.bounds, "inclusive") or
        a.route.qualified_guard.entry_flags != 0 or a.route.qualified_guard.x_min != 32 or
        a.route.qualified_guard.x_max != 38 or a.route.qualified_guard.y_min != 104 or
        a.route.qualified_guard.y_max != 104 or
        !std.mem.eql(u8, a.route.qualified_guard.predicate_bytes, "0b20260c686806") or
        !std.mem.eql(u8, a.route.guard.pointer_state, "present") or a.route.guard.terms.len != 2 or
        !std.mem.eql(u8, a.route.guard.terms[0].kind, "unsupported") or
        !std.mem.eql(u8, a.route.guard.terms[0].semantics, "event_predicate_0b") or
        !std.mem.eql(u8, a.route.guard.terms[1].kind, "unsupported") or
        !std.mem.eql(u8, a.route.guard.terms[1].semantics, "event_predicate_0c") or
        !std.mem.eql(u8, a.constructor.status, "fresh_story_bound")) return error.InvalidDestination;
    const va1_guard_ids = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 35, 38, 39, 40, 42, 43, 44 };
    const town_guards = a.constructor.va1_room0.free_guards;
    if (town_guards.len != va1_guard_ids.len) return error.InvalidVa1TownGuards;
    for (town_guards, va1_guard_ids, 0..) |guard, expected_entity, order| {
        if (guard.entity != expected_entity or guard.source_order != expected_entity or guard.terms.len == 0 or
            guard.predicate_bytes.len < 2 or guard.predicate_offset == 0) return error.InvalidVa1TownGuards;
        if (order != 0 and town_guards[order - 1].source_order >= guard.source_order) return error.InvalidVa1TownGuards;
        for (guard.terms) |term| switch (term.kind) {
            .x_range, .y_range => {
                const low = term.min_cell orelse return error.InvalidVa1TownGuards;
                const high = term.max_cell orelse return error.InvalidVa1TownGuards;
                const expected_opcode: u8 = if (term.kind == .x_range) 0x0b else 0x0c;
                if (term.opcode != expected_opcode or high < low or term.operands.len != 2 or
                    term.operands[0] != low or term.operands[1] != high) return error.InvalidVa1TownGuards;
            },
            .up_input => if (term.opcode != 0x04 or term.mask == null or term.mask.? != 0x04 or
                term.operands.len != 1 or term.operands[0] != 0) return error.InvalidVa1TownGuards,
            .story_mask_set, .story_mask_clear => if (term.opcode != @as(u8, if (term.kind == .story_mask_set) 0x07 else 0x08) or
                term.story_index == null or term.mask == null or term.mask.? == 0 or term.operands.len != 2 or
                term.operands[0] != term.story_index.? or term.operands[1] != term.mask.?) return error.InvalidVa1TownGuards,
            .unsupported => if (term.semantics == null or term.operands.len > 2) return error.InvalidVa1TownGuards,
        };
    }
    try scene_population.validate(a.constructor.field_population);
    try scene_population.validate(a.constructor.route_population);
    try scene_population.validate(a.constructor.room10_population);
    try scene_population.validate(a.constructor.va1_room0.population);
    try scene_population.validate(a.constructor.va1_room1.population);
    try scene_population.validate(a.constructor.va1_room2.population);
    try a.constructor.events.validate();
    try a.constructor.route_events.validate();
    try a.constructor.room10_events.validate();
    try a.constructor.va1_room0.events.validate();
    try a.constructor.va1_room1.events.validate();
    try a.constructor.va1_room2.events.validate();
    try a.constructor.field_actors.validate(a.constructor.animations);
    try a.constructor.room10_field_actors.validate(a.constructor.room10_animations);
    try a.constructor.va1_room0.field_actors.validate(a.constructor.va1_room0.animations);
    try a.constructor.va1_room1.field_actors.validate(a.constructor.va1_room1.animations);
    try a.constructor.va1_room2.field_actors.validate(a.constructor.va1_room2.animations);
    if (!std.mem.eql(u8, a.constructor.field_population.id, "vaa_room0") or
        !std.mem.eql(u8, a.constructor.route_population.id, "vaa_room1") or
        !std.mem.eql(u8, a.constructor.field_actors.scene, "vaa_room0") or
        !std.mem.eql(u8, a.constructor.context.room, "vaa_room_0") or
        !std.mem.eql(u8, a.constructor.context.event_id, a.constructor.events.id) or
        !std.mem.eql(u8, a.constructor.context.event_sha256, a.constructor.events.content_sha256) or
        !std.mem.eql(u8, a.constructor.context.population_sha256, a.constructor.field_population.content_sha256) or
        a.constructor.context.ordinary_sha256 == null or
        !std.mem.eql(u8, a.constructor.context.ordinary_sha256.?, a.constructor.field_actors.content_sha256) or
        !std.mem.eql(u8, a.constructor.context.dialogue_sha256, a.constructor.dialogue.content_sha256) or
        !std.mem.eql(u8, a.constructor.route_context.room, "vaa_room_1") or
        !std.mem.eql(u8, a.constructor.route_context.event_id, a.constructor.route_events.id) or
        !std.mem.eql(u8, a.constructor.route_context.event_sha256, a.constructor.route_events.content_sha256) or
        !std.mem.eql(u8, a.constructor.route_context.population_sha256, a.constructor.route_population.content_sha256) or
        a.constructor.route_context.ordinary_sha256 != null or
        !std.mem.eql(u8, a.constructor.route_context.dialogue_sha256, a.constructor.dialogue.content_sha256) or
        !std.mem.eql(u8, a.constructor.room10_population.id, "vaa_room10") or
        !std.mem.eql(u8, a.constructor.room10_field_actors.scene, "vaa_room10") or
        !std.mem.eql(u8, a.constructor.room10_context.room, "vaa_room_10") or
        !std.mem.eql(u8, a.constructor.room10_context.event_id, a.constructor.room10_events.id) or
        !std.mem.eql(u8, a.constructor.room10_context.event_sha256, a.constructor.room10_events.content_sha256) or
        !std.mem.eql(u8, a.constructor.room10_context.population_sha256, a.constructor.room10_population.content_sha256) or
        a.constructor.room10_context.ordinary_sha256 == null or
        !std.mem.eql(u8, a.constructor.room10_context.ordinary_sha256.?, a.constructor.room10_field_actors.content_sha256) or
        !std.mem.eql(u8, a.constructor.room10_context.dialogue_sha256, a.constructor.dialogue.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room0.population.id, "va1_room0") or
        !std.mem.eql(u8, a.constructor.va1_room0.field_actors.scene, "va1_room0") or
        !std.mem.eql(u8, a.constructor.va1_room0.context.room, "va1_room_0") or
        !std.mem.eql(u8, a.constructor.va1_room0.context.event_id, a.constructor.va1_room0.events.id) or
        !std.mem.eql(u8, a.constructor.va1_room0.context.event_sha256, a.constructor.va1_room0.events.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room0.context.population_sha256, a.constructor.va1_room0.population.content_sha256) or
        a.constructor.va1_room0.context.ordinary_sha256 == null or
        !std.mem.eql(u8, a.constructor.va1_room0.context.ordinary_sha256.?, a.constructor.va1_room0.field_actors.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room0.context.dialogue_sha256, a.constructor.va1_room0.dialogue.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room0.dialogue.schema, "suikoden-field-dialogue/6") or
        a.constructor.va1_room0.dialogue.anchors.len != 1 or a.constructor.va1_room0.dialogue.texts.len != 1 or
        a.constructor.va1_room0.dialogue.prefixes.len != 0 or a.constructor.va1_room0.dialogue.images.len != 0 or
        a.constructor.va1_room0.dialogue.descriptor_changes.len != 0 or
        !a.constructor.va1_room0.dialogue.allow_pages or a.constructor.va1_room0.dialogue.allow_substitution or
        !std.mem.eql(u16, &a.constructor.va1_room0.context.dialogue_counts, &.{ 1, 1, 0, 0, 0 }) or
        !std.mem.eql(u8, a.constructor.va1_room1.population.id, "va1_room1") or
        !std.mem.eql(u8, a.constructor.va1_room1.field_actors.scene, "va1_room1") or
        !std.mem.eql(u8, a.constructor.va1_room1.context.room, "va1_room_1") or
        !std.mem.eql(u8, a.constructor.va1_room1.context.event_id, a.constructor.va1_room1.events.id) or
        !std.mem.eql(u8, a.constructor.va1_room1.context.event_sha256, a.constructor.va1_room1.events.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room1.context.population_sha256, a.constructor.va1_room1.population.content_sha256) or
        a.constructor.va1_room1.context.ordinary_sha256 == null or
        !std.mem.eql(u8, a.constructor.va1_room1.context.ordinary_sha256.?, a.constructor.va1_room1.field_actors.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room1.context.dialogue_sha256, a.constructor.va1_room1.dialogue.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room1.events.id, "va1_room1_field_events") or
        !std.mem.eql(u8, a.constructor.va1_room1.field_actors.population_sha256, a.constructor.va1_room1.population.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room1.field_actors.event_sha256, a.constructor.va1_room1.events.content_sha256) or
        a.constructor.va1_room1.events.programs.len != 3 or
        a.constructor.va1_room1.field_actors.actors.len != 17 or a.constructor.va1_room1.animations.len != 10 or
        a.constructor.va1_room1.cell_capacity != 48 * 64 or
        !std.mem.eql(u8, a.constructor.va1_room2.population.id, "va1_room2") or
        !std.mem.eql(u8, a.constructor.va1_room2.field_actors.scene, "va1_room2") or
        !std.mem.eql(u8, a.constructor.va1_room2.context.room, "va1_room_2") or
        !std.mem.eql(u8, a.constructor.va1_room2.context.event_id, a.constructor.va1_room2.events.id) or
        !std.mem.eql(u8, a.constructor.va1_room2.context.event_sha256, a.constructor.va1_room2.events.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room2.context.population_sha256, a.constructor.va1_room2.population.content_sha256) or
        a.constructor.va1_room2.context.ordinary_sha256 == null or
        !std.mem.eql(u8, a.constructor.va1_room2.context.ordinary_sha256.?, a.constructor.va1_room2.field_actors.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room2.context.dialogue_sha256, a.constructor.va1_room2.dialogue.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room2.events.id, "va1_room2_field_events") or
        a.constructor.va1_room2.events.programs.len != 1 or
        !std.mem.eql(u8, a.constructor.va1_room2.events.programs[0].id, "va1_r02_e02_ordinary") or
        a.constructor.va1_room2.events.programs[0].commands.len != 35 or
        !std.mem.eql(u8, a.constructor.va1_room2.field_actors.population_sha256, a.constructor.va1_room2.population.content_sha256) or
        !std.mem.eql(u8, a.constructor.va1_room2.field_actors.event_sha256, a.constructor.va1_room2.events.content_sha256) or
        a.constructor.va1_room2.field_actors.actors.len != 13 or a.constructor.va1_room2.animations.len != 6 or
        a.constructor.va1_room2.cell_capacity != 48 * 48 or
        a.constructor.va1_room1.stairs.len != 2 or a.constructor.va1_room1.path_to_stair_cells.len < 2 or
        a.constructor.room_record_byte7.len != 6 or
        !std.mem.eql(u8, a.constructor.room_record_byte7[0].room, "vaa_room_0") or
        !std.mem.eql(u8, a.constructor.room_record_byte7[1].room, "vaa_room_1") or
        !std.mem.eql(u8, a.constructor.room_record_byte7[2].room, "vaa_room_10") or
        !std.mem.eql(u8, a.constructor.room_record_byte7[3].room, "va1_room_0") or
        !std.mem.eql(u8, a.constructor.room_record_byte7[4].room, "va1_room_1") or
        !std.mem.eql(u8, a.constructor.room_record_byte7[5].room, "va1_room_2") or
        a.constructor.room_record_byte7[0].entry_title_hold or a.constructor.room_record_byte7[1].entry_title_hold or
        a.constructor.room_record_byte7[2].entry_title_hold or !a.constructor.room_record_byte7[3].entry_title_hold or
        a.constructor.room_record_byte7[4].entry_title_hold or
        a.constructor.room_record_byte7[5].entry_title_hold or
        a.constructor.va1_room2.room_record_byte7 != a.constructor.room_record_byte7[5].value or
        a.constructor.va1_room0.opcode0e_source_state.room_record_byte_7 != a.constructor.room_record_byte7[3].value or
        a.constructor.va1_room1.opcode0e_source_state.room_record_byte_7 != a.constructor.room_record_byte7[4].value or
        a.constructor.va1_room0.opcode0e_source_state.record_count != 253 or
        a.constructor.va1_room0.opcode0e_source_state.records.len != 253 or
        a.constructor.va1_room0.opcode0e_source_state.levels.len != 253 or
        a.constructor.va1_room0.opcode0e_source_state.eligible_record_indexes.len != 0 or
        a.constructor.va1_room0.opcode0e_source_state.home_door_probe == null or
        a.constructor.va1_room0.opcode0e_source_state.home_door_probe.?.query_cell[0] != 131 or
        a.constructor.va1_room0.opcode0e_source_state.home_door_probe.?.query_cell[1] != 43 or
        a.constructor.va1_room0.opcode0e_source_state.home_door_probe.?.hit_record_indexes.len != 0 or
        !std.mem.eql(u8, a.constructor.va1_room0.opcode0e_source_state.home_door_probe.?.result, "no_hit_no_state_mutation_no_dispatch") or
        a.constructor.va1_room1.opcode0e_source_state.record_count != 51 or
        a.constructor.va1_room1.opcode0e_source_state.levels.len != 51 or
        a.constructor.va1_room1.initializer07.operations.len != 9 or
        !freshConstructionStory(a.constructor.construction_story)) return error.InvalidDestinationConstruction;
    const initializer = a.constructor.events.program("vaa_r00_init_26") orelse return error.MissingDestinationInitializer;
    if (initializer.entity != 26 or initializer.entry != .initialization or initializer.commands.len != 4 or
        initializer.commands[0].kind != .continue_tick or initializer.commands[1].kind != .cue or initializer.commands[1].cue != 128 or
        initializer.commands[2].kind != .yield_tick or initializer.commands[3].kind != .end_stream) return error.InvalidDestinationInitializer;
    const room10_initializer = a.constructor.room10_events.program("vaa_r10_init_02") orelse return error.MissingRoom10Initializer;
    if (room10_initializer.entity != 2 or room10_initializer.entry != .initialization or room10_initializer.commands.len != 3 or
        room10_initializer.commands[0].kind != .continue_tick or room10_initializer.commands[1].kind != .yield_tick or
        room10_initializer.commands[2].kind != .end_stream or a.constructor.room10_field_actors.actors.len != 1 or
        a.constructor.room10_field_actors.actors[0].entity != 4 or a.constructor.room10_field_actors.actors[0].slot != 0 or
        !std.mem.eql(u8, a.constructor.room10_field_actors.actors[0].resource, "vaa_room10_character_110") or
        !std.mem.eql(u8, a.constructor.room10_field_actors.actors[0].graphic, "palace_character_110") or
        a.constructor.room10_field_actors.actors[0].x != 2040 or a.constructor.room10_field_actors.actors[0].y != 2040 or
        a.constructor.room10_field_actors.actors[0].source_graphics != .child_present) return error.InvalidRoom10Construction;
    const va1_initializer = a.constructor.va1_room0.events.program("va1_r00_init_47") orelse return error.MissingVa1Room0Initializer;
    const va1_interaction = a.constructor.va1_room0.events.program("va1_r00_e27_ordinary") orelse return error.MissingVa1Room0Interaction;
    const va1_home = a.constructor.va1_room0.events.program("va1_r00_e03_home") orelse return error.MissingVa1HomeDoorProgram;
    if (va1_initializer.entity != 47 or va1_initializer.entry != .initialization or va1_initializer.commands.len != 3 or
        va1_initializer.commands[0].kind != .continue_tick or va1_initializer.commands[1].kind != .yield_tick or
        va1_initializer.commands[2].kind != .end_stream or a.constructor.va1_room0.field_actors.actors.len != 13 or
        va1_interaction.entity != 27 or va1_interaction.entry != .ordinary or va1_interaction.trigger != .interaction or
        va1_interaction.commands.len != 5 or va1_interaction.commands[0].kind != .open_box or
        va1_interaction.commands[0].box == null or va1_interaction.commands[0].box.? != 0 or
        va1_interaction.commands[0].layout == null or va1_interaction.commands[0].layout.? != 0 or
        va1_interaction.commands[1].kind != .text or va1_interaction.commands[2].kind != .wait_for_accept or
        va1_interaction.commands[3].kind != .close_box or va1_interaction.commands[4].kind != .end_stream or
        va1_home.entity != 3 or va1_home.entry != .ordinary or va1_home.commands.len != 5 or
        va1_home.commands[0].kind != .actor_transition or va1_home.commands[0].actor == null or
        !std.mem.eql(u8, va1_home.commands[0].actor.?, "hero") or va1_home.commands[0].transition != 1 or
        va1_home.commands[1].kind != .spatial_object_probe or va1_home.commands[1].selector != 0x80 or
        va1_home.commands[2].kind != .delay or va1_home.commands[2].updates != 10 or
        va1_home.commands[3].kind != .cue or va1_home.commands[3].cue != 1068 or
        va1_home.commands[4].kind != .room_transition or va1_home.commands[4].destination == null or
        !std.mem.eql(u8, va1_home.commands[4].destination.?, "va1_room_1") or
        va1_home.commands[4].x != 184 or va1_home.commands[4].y != 352 or
        a.constructor.va1_room0.population.entities[3].event.status != .resolved or
        a.constructor.va1_room0.population.entities[3].event.program_id == null or
        !std.mem.eql(u8, a.constructor.va1_room0.population.entities[3].event.program_id.?, "va1_r00_e03_home") or
        !std.mem.eql(u8, a.constructor.va1_room0.dialogue.anchors[0].program, "va1_r00_e27_ordinary") or
        a.constructor.va1_room0.dialogue.anchors[0].command != 0 or a.constructor.va1_room0.dialogue.anchors[0].box != 0 or
        a.constructor.va1_room0.dialogue.anchors[0].actor == null or
        !std.mem.eql(u8, a.constructor.va1_room0.dialogue.anchors[0].actor.?, "scene_actor_0") or
        a.constructor.va1_room0.animations.len != 7 or !std.mem.eql(u16, &a.constructor.va1_room0.spawn, &.{ 808, 56 }) or
        a.constructor.va1_room0.path_to_entity_27_cells.len < 2 or
        a.constructor.va1_room0.path_to_home_door_cells.len < 2) return error.InvalidVa1Room0Construction;
    const va1_room1_initializer = a.constructor.va1_room1.events.program("va1_r01_init_03") orelse return error.MissingVa1Room1Initializer;
    if (va1_room1_initializer.entity != 3 or va1_room1_initializer.entry != .initialization or
        va1_room1_initializer.commands.len != 12 or
        va1_room1_initializer.commands[0].kind != .continue_tick or
        va1_room1_initializer.commands[10].kind != .yield_tick or
        va1_room1_initializer.commands[11].kind != .end_stream or
        !std.mem.eql(u8, a.constructor.va1_room1.initializer07.source_bytes, "30070001270700020b070000000702010c07020208070200000701011b0701020b0701000031fd") or
        !std.mem.eql(u8, a.constructor.va1_room1.initializer07.selected_initializers, &.{3}) or
        a.constructor.va1_room1.initializer07.descriptor_baselines.len != 3 or
        a.constructor.va1_room1.population.entities[3].event.status != .resolved or
        a.constructor.va1_room1.population.entities[3].event.program_id == null or
        !std.mem.eql(u8, a.constructor.va1_room1.population.entities[3].event.program_id.?, "va1_r01_init_03")) return error.InvalidVa1Room1Initializer;
    for (va1_room1_initializer.commands[1..10], a.constructor.va1_room1.initializer07.operations) |command, operation| {
        if (command.kind != .descriptor_display or command.selector == null or command.selector.? != operation.selector or
            command.parameter == null or command.parameter.? != operation.mode or
            command.value == null or command.value.? != operation.value) return error.InvalidVa1Room1Initializer;
    }
    const descriptor_baselines = a.constructor.va1_room1.initializer07.descriptor_baselines;
    const descriptor_entities = [_]u8{ 5, 6, 9 };
    if (descriptor_baselines.len != descriptor_entities.len) return error.InvalidVa1Room1Initializer;
    for (descriptor_baselines, descriptor_entities, 0..) |baseline, entity_id, selector| {
        if (baseline.selector != selector or baseline.entity != entity_id or
            baseline.initial.plus_0 != 254 or baseline.initial.plus_1 != 254 or
            baseline.initial.plus_5 != 0 or baseline.initial.plus_6 != 0 or baseline.initial.plus_7 != 0 or
            baseline.parallel_state.selector_index != selector or baseline.parallel_state.row_stride != 8 or
            baseline.parallel_state.descriptor_pointer_entity != entity_id or
            !std.mem.eql(u8, baseline.parallel_state.bytes_0_to_3, "uninitialized_by_constructor") or
            !std.mem.eql(u8, baseline.parallel_state.pointer_at_plus_4, "descriptor")) return error.InvalidVa1Room1Initializer;
    }
    for (a.constructor.va1_room0.opcode0e_source_state.records, 0..) |record, index| {
        if (record.index != index or record.level != 1 or record.level != a.constructor.va1_room0.opcode0e_source_state.levels[index] or record.initial_flags != 0 or record.eligible)
            return error.InvalidVa1HomeDoorSpatialProof;
    }
    for (a.constructor.va1_room1.opcode0e_source_state.records, 0..) |record, index| {
        if (record.index != index or record.level != a.constructor.va1_room1.opcode0e_source_state.levels[index] or
            record.initial_flags != 0 or record.eligible) return error.InvalidVa1Room1SpatialSource;
    }
    if (a.constructor.va1_room0.opcode0e_source_state.home_door_probe.?.dispatch_if_hit != 0x506 or
        a.constructor.va1_room1.opcode0e_source_state.eligible_record_indexes.len != 0)
        return error.InvalidVa1HomeDoorSpatialProof;
    if (a.ordinary_routes.len != 5 or a.room10_walkable.len != 48 * 32) return error.InvalidDestinationRoutes;
    const route_cases = [_]struct { room: u8, entity: u8, id: []const u8 }{
        .{ .room = 0, .entity = 15, .id = "vaa_r00_e15_exit" },
        .{ .room = 0, .entity = 16, .id = "vaa_r00_e16_exit" },
        .{ .room = 1, .entity = 1, .id = "vaa_r01_e01_exit" },
        .{ .room = 10, .entity = 0, .id = "vaa_r10_e00_exit" },
        .{ .room = 10, .entity = 1, .id = "vaa_r10_e01_exit" },
    };
    for (route_cases, 0..) |expected, index| {
        const route = a.ordinary_routes[index];
        if (route.source_room != expected.room or route.source_entity != expected.entity or !std.mem.eql(u8, route.program_id, expected.id)) return error.InvalidDestinationRoutes;
    }
    const room0_exit = a.ordinary_routes[0];
    const room10_exit = a.ordinary_routes[4];
    if (room0_exit.qualified_guard == null or !room0_exit.matchesCell(37, 93) or !room0_exit.matchesCell(41, 94) or
        room0_exit.matchesCell(36, 93) or room0_exit.matchesCell(37, 95) or
        !std.mem.eql(u8, room0_exit.destination, "vaa_room_10") or room0_exit.x != 184 or room0_exit.y != 56 or
        room10_exit.qualified_guard == null or !room10_exit.matchesCell(18, 29) or !room10_exit.matchesCell(28, 30) or
        room10_exit.matchesCell(17, 29) or room10_exit.matchesCell(18, 31) or
        !std.mem.eql(u8, room10_exit.destination, "va1_room_0") or room10_exit.x != 808 or room10_exit.y != 56) return error.InvalidDestinationRoutes;
    const geometry = try ground.Geometry.load(allocator, geometry_bytes);
    errdefer geometry.deinit();
    const room = geometry.roomById("vaa_room_0") orelse return error.MissingDestinationRoom;
    if (room.width_cells != 160 or room.height_cells != 96 or !ground.groundAt(room, 39, 13, 0).walkable)
        return error.InvalidDestinationGround;
    const room10 = geometry.roomById("vaa_room_10") orelse return error.MissingRoom10Geometry;
    if (room10.width_cells != 48 or room10.height_cells != 32 or !ground.groundAt(room10, 23, 7, 0).walkable or a.room10_walkable[7 * 48 + 23] != '1')
        return error.InvalidRoom10Ground;
    const va1_room0 = geometry.roomById("va1_room_0") orelse return error.MissingVa1Room0Geometry;
    if (va1_room0.width_cells != 184 or va1_room0.height_cells != 112 or
        !ground.groundAt(va1_room0, 101, 7, 0).walkable or
        a.va1_walkable.len != 184 * 112 or a.va1_walkable[7 * 184 + 101] != '1' or
        !ground.groundAt(va1_room0, 101, 61, 0).walkable or a.va1_walkable[61 * 184 + 101] != '1')
        return error.InvalidVa1Room0Ground;
    const va1_room1 = geometry.roomById("va1_room_1") orelse return error.MissingVa1Room1Geometry;
    if (va1_room1.width_cells != 48 or va1_room1.height_cells != 64 or
        !ground.groundAt(va1_room1, 23, 44, 0).walkable or
        a.va1_room1_walkable.len != 48 * 64 or a.va1_room1_walkable[44 * 48 + 23] != '1')
        return error.InvalidVa1Room1Ground;
    const va1 = a.constructor.va1_room0;
    if (va1.path_to_entity_27_cells[0][0] != 101 or va1.path_to_entity_27_cells[0][1] != 7 or
        va1.path_to_entity_27_cells[va1.path_to_entity_27_cells.len - 1][0] != 101 or
        va1.path_to_entity_27_cells[va1.path_to_entity_27_cells.len - 1][1] != 59) return error.InvalidVa1Room0Path;
    for (va1.path_to_entity_27_cells, 0..) |cell, index| {
        const walk_index = @as(usize, cell[1]) * @as(usize, va1_room0.width_cells) + @as(usize, cell[0]);
        if (cell[0] >= va1_room0.width_cells or cell[1] >= va1_room0.height_cells or
            a.va1_walkable[walk_index] != '1') return error.InvalidVa1Room0Path;
        if (index != 0) {
            const prior = va1.path_to_entity_27_cells[index - 1];
            const dx = if (cell[0] > prior[0]) cell[0] - prior[0] else prior[0] - cell[0];
            const dy = if (cell[1] > prior[1]) cell[1] - prior[1] else prior[1] - cell[1];
            if (dx + dy != 1) return error.InvalidVa1Room0Path;
        }
    }
    const home_path = va1.path_to_home_door_cells;
    if (home_path[0][0] != 100 or home_path[0][1] != 59 or
        home_path[home_path.len - 1][0] != 131 or home_path[home_path.len - 1][1] != 44) return error.InvalidVa1HomeDoorPath;
    var opened = Opened{ .parsed = parsed, .geometry = geometry };
    for (home_path, 0..) |cell, index| {
        const walk_index = @as(usize, cell[1]) * @as(usize, va1_room0.width_cells) + @as(usize, cell[0]);
        if (cell[0] >= va1_room0.width_cells or cell[1] >= va1_room0.height_cells or
            a.va1_walkable[walk_index] != '1')
            return error.InvalidVa1HomeDoorPath;
        if (index + 1 < home_path.len) {
            const next = home_path[index + 1];
            const dx = @abs(@as(i32, next[0]) - @as(i32, cell[0]));
            const dy = @abs(@as(i32, next[1]) - @as(i32, cell[1]));
            if (dx + dy != 1) return error.InvalidVa1HomeDoorPath;
            const up_held = next[1] < cell[1];
            if (try opened.firstTownOrdinary(cell[0], cell[1], up_held, a.constructor.construction_story) != null)
                return error.InvalidVa1HomeDoorPath;
        }
        for (va1.field_actors.actors) |actor| {
            if (!a.constructor.construction_story.matches(actor.conditions) or actor.source_graphics != .child_present or actor.x < 0 or actor.y < 0 or
                actor.x >= @as(i32, va1_room0.width_cells) * 8 or
                actor.y >= @as(i32, va1_room0.height_cells) * 8) continue;
            const actor_cell_x: i32 = @divTrunc(actor.x, 8);
            const actor_cell_y: i32 = @divTrunc(actor.y, 8);
            const cell_x: i32 = @intCast(cell[0]);
            const cell_y: i32 = @intCast(cell[1]);
            if (cell_x >= actor_cell_x - 1 and cell_x <= actor_cell_x + 1 and
                cell_y >= actor_cell_y - 1 and cell_y <= actor_cell_y) return error.InvalidVa1HomeDoorPath;
        }
        if (index != 0) {
            const prior = home_path[index - 1];
            const dx = if (cell[0] > prior[0]) cell[0] - prior[0] else prior[0] - cell[0];
            const dy = if (cell[1] > prior[1]) cell[1] - prior[1] else prior[1] - cell[1];
            if (dx + dy != 1) return error.InvalidVa1HomeDoorPath;
        }
    }
    if (try opened.firstTownOrdinary(131, 44, true, a.constructor.construction_story) != 3)
        return error.InvalidVa1HomeDoorPath;
    return opened;
}
