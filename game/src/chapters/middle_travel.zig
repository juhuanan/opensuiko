const std = @import("std");

pub const schema = "suikoden-middle-travel/1";

pub const Source = struct { file: []const u8, lba: u32, size: u32, sha256: []const u8 };
pub const Destination = struct {
    kind: []const u8,
    reason: ?[]const u8 = null,
    area_file: ?[]const u8 = null,
    region: ?u8 = null,
    area_index: ?u16 = null,
    room: ?u8 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    coordinate_units: ?[]const u8 = null,
    source_room_status: ?[]const u8 = null,
    spawn_state: []const u8,
};
pub const Edge = struct {
    id: []const u8,
    source_file: []const u8,
    source_region: u8,
    source_area_index: u8,
    room: u8,
    entity_ids: []const u8,
    selection_mode: []const u8,
    stream: u32,
    offset: u32,
    format: []const u8,
    destination: Destination,
    unlock_state: []const u8,
    runtime_state: []const u8,
};
pub const Coverage = struct {
    edges: u16,
    source_files: u16,
    room_destinations: u16,
    world_destinations: u16,
    unresolved_destinations: u16,
    decoded_guards: u16,
    unsupported_guards: u16,
    initialization_edges: u16,
    unlocked_edges: u16,
    production_edges: u16,
};
pub const ChapterSource = struct {
    file: []const u8,
    room: u8,
    entity: u8,
    predicate_offset: u32,
    stream_offset: u32,
    transition_offset: u32,
};
pub const ChapterGuard = struct {
    kind: []const u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    source_half_cell_x: u8,
    event_flags_low2_clear: bool,
};
pub const ChapterDestination = struct {
    kind: []const u8,
    region: u8,
    x: i32,
    y: i32,
    coordinate_units: []const u8,
    spawn_state: []const u8,
};
pub const ChapterOrder = struct { source_order: u8, continuation: []const u8 };
pub const RouteSource = struct { path: []const u8, sha256: []const u8 };
pub const ChapterEdge = struct {
    edge_id: []const u8,
    route_id: []const u8,
    route_source: RouteSource,
    source: ChapterSource,
    guard: ChapterGuard,
    destination: ChapterDestination,
    order: ChapterOrder,
    next_checkpoint: []const u8,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    sources: []const Source,
    edges: []const Edge,
    chapter_edge: ChapterEdge,
    next_checkpoint: []const u8,
    coverage: Coverage,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

fn knownSource(asset: Asset, path: []const u8) bool {
    for (asset.sources) |source| {
        if (std.mem.eql(u8, source.file, path)) return true;
    }
    return false;
}

pub fn edgeAt(asset: Asset, stream: u32) ?Edge {
    for (asset.edges) |edge| {
        if (edge.stream == stream) return edge;
    }
    return null;
}

fn validateChapter(asset: Asset) !void {
    const chapter = asset.chapter_edge;
    if (!std.mem.eql(u8, chapter.edge_id, "travel_0778") or
        !std.mem.eql(u8, chapter.route_id, "vb6_r06_e01_to_region_c") or
        !std.mem.eql(u8, chapter.route_source.path, "game/assets/routes/region_b_vb6_c.json") or
        !std.mem.eql(u8, chapter.route_source.sha256, "b8607ae34c1351aee6bfab5dcdb9c163eebe625ce3bd9a999970fad094623616") or
        !std.mem.eql(u8, chapter.source.file, "DATA/02_AREA.B/VB6.BIN") or
        chapter.source.room != 6 or chapter.source.entity != 1 or
        chapter.source.predicate_offset != 217228 or chapter.source.stream_offset != 217340 or
        chapter.source.transition_offset != 217340 or
        !std.mem.eql(u8, chapter.guard.kind, "field_rectangle") or
        chapter.guard.x != 360 or chapter.guard.y != 0 or chapter.guard.w != 8 or chapter.guard.h != 384 or
        chapter.guard.source_half_cell_x != 45 or !chapter.guard.event_flags_low2_clear or
        !std.mem.eql(u8, chapter.destination.kind, "world") or chapter.destination.region != 2 or
        chapter.destination.x != 59 or chapter.destination.y != 38 or
        !std.mem.eql(u8, chapter.destination.coordinate_units, "world_cells") or
        !std.mem.eql(u8, chapter.destination.spawn_state, "accepted_world_ready") or
        chapter.order.source_order != 1 or !std.mem.eql(u8, chapter.order.continuation, "world_ready") or
        !std.mem.eql(u8, chapter.next_checkpoint, "region_c_world_ready") or
        !std.mem.eql(u8, asset.next_checkpoint, chapter.next_checkpoint)) return error.InvalidChapterEdge;
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64)
        return error.InvalidTravelSchema;
    if (asset.sources.len != 89 or asset.edges.len != 1660 or
        asset.coverage.edges != 1660 or asset.coverage.source_files != 89 or
        asset.coverage.room_destinations != 1599 or asset.coverage.world_destinations != 54 or
        asset.coverage.unresolved_destinations != 7 or asset.coverage.decoded_guards != 1651 or
        asset.coverage.unsupported_guards != 9 or asset.coverage.initialization_edges != 15 or
        asset.coverage.unlocked_edges != 1 or asset.coverage.production_edges != 1)
        return error.InvalidTravelCoverage;
    try validateChapter(asset);
    var room_destinations: usize = 0;
    var world_destinations: usize = 0;
    var unresolved: usize = 0;
    var unlocked: usize = 0;
    var production: usize = 0;
    for (asset.edges, 0..) |edge, index| {
        const is_chapter = std.mem.eql(u8, edge.id, asset.chapter_edge.edge_id);
        if (is_chapter) {
            unlocked += 1;
            production += 1;
        }
        if (!knownSource(asset, edge.source_file) or edge.entity_ids.len == 0 or
            (is_chapter and (!std.mem.eql(u8, edge.unlock_state, "accepted_route_guard") or
                !std.mem.eql(u8, edge.runtime_state, "production"))) or
            (!is_chapter and (!std.mem.eql(u8, edge.unlock_state, "source_guard_unresolved") or
                !std.mem.eql(u8, edge.runtime_state, "source_only")))) return error.InvalidTravelEdge;
        for (asset.edges[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, edge.id) or
                (std.mem.eql(u8, earlier.source_file, edge.source_file) and
                    earlier.room == edge.room and earlier.stream == edge.stream and earlier.offset == edge.offset))
                return error.DuplicateTravelEdge;
            if (std.mem.order(u8, earlier.source_file, edge.source_file) == .gt or
                (std.mem.eql(u8, earlier.source_file, edge.source_file) and
                    (earlier.room > edge.room or
                        (earlier.room == edge.room and earlier.stream > edge.stream) or
                        (earlier.room == edge.room and earlier.stream == edge.stream and earlier.offset > edge.offset))))
                return error.TravelSourceOrderMismatch;
        }
        const destination = edge.destination;
        if (std.mem.eql(u8, destination.kind, "room")) {
            room_destinations += 1;
            const path = destination.area_file orelse return error.InvalidTravelDestination;
            if (!knownSource(asset, path) or destination.room == null or
                destination.x == null or destination.y == null or
                !std.mem.eql(u8, destination.spawn_state, "unverified"))
                return error.InvalidTravelDestination;
            if (destination.source_room_status) |status| {
                if (!std.mem.eql(u8, status, "found") and !std.mem.eql(u8, status, "unresolved"))
                    return error.InvalidTravelDestination;
            }
        } else if (std.mem.eql(u8, destination.kind, "world")) {
            world_destinations += 1;
            const expected_spawn = if (is_chapter) "accepted_world_ready" else "unverified";
            if (destination.area_file != null or destination.coordinate_units == null or
                destination.x == null or destination.y == null or
                !std.mem.eql(u8, destination.coordinate_units.?, "world_cells") or
                !std.mem.eql(u8, destination.spawn_state, expected_spawn))
                return error.InvalidTravelDestination;
        } else if (std.mem.eql(u8, destination.kind, "unresolved")) {
            unresolved += 1;
            if (!std.mem.eql(u8, destination.spawn_state, "blocked") or destination.reason == null)
                return error.InvalidTravelDestination;
        } else return error.InvalidTravelDestination;
    }
    if (room_destinations != asset.coverage.room_destinations or
        world_destinations != asset.coverage.world_destinations or
        unresolved != asset.coverage.unresolved_destinations or
        unlocked != asset.coverage.unlocked_edges or production != asset.coverage.production_edges)
        return error.InvalidTravelCoverage;
}

pub const ChapterPlan = struct {
    edge_id: []const u8,
    route_id: []const u8,
    source_order: u8,
    destination: ChapterDestination,
    next_checkpoint: []const u8,
};

pub fn planChapter(asset: Asset, x: i32, y: i32, event_flags_low2: u2) !ChapterPlan {
    try validate(asset);
    const chapter = asset.chapter_edge;
    const guard = chapter.guard;
    if (guard.event_flags_low2_clear and event_flags_low2 != 0) return error.TransitionBarrierBlocked;
    if (x < guard.x or y < guard.y or x >= guard.x + guard.w or y >= guard.y + guard.h)
        return error.RouteTriggerMismatch;
    return .{
        .edge_id = chapter.edge_id,
        .route_id = chapter.route_id,
        .source_order = chapter.order.source_order,
        .destination = chapter.destination,
        .next_checkpoint = chapter.next_checkpoint,
    };
}
