const std = @import("std");
const validation = @import("validation");
const event_runtime = @import("event_runtime");
const route_coordinates = @import("route_coordinates");
const coordinates = @import("field_coordinates");

pub const schema = "suikoden-route-transitions/1";
pub const max_json_bytes = 1024 * 1024;
pub const max_routes = 64;
pub const max_effects = 16;

pub const Source = struct {
    file: []const u8,
    lba: u32,
    size: u32,
    sha256: []const u8,
};
pub const Location = struct {
    id: []const u8,
    kind: enum { world_region, field_room },
    source_file: ?[]const u8 = null,
    source_room: ?u8 = null,
    world_region: ?u8 = null,
};
pub const CoordinateDomain = route_coordinates.Domain;
pub const Coordinate = route_coordinates.Coordinate;
pub const Rectangle = route_coordinates.Rectangle;
pub const Direction = enum { down, up, left, right };
pub const Trigger = struct {
    kind: enum { field_rectangle, world_point, ordinary_event },
    rectangle: ?Rectangle = null,
    point: ?Coordinate = null,
    direction: ?Direction = null,
};
pub const Origin = struct { location_id: []const u8, trigger: Trigger };
pub const Destination = struct {
    location_id: []const u8,
    source_spawn: Coordinate,
    spawn: Coordinate,
};
pub const StoryValue = struct {
    id: []const u8,
    storage: enum { scenario },
    byte_index: u8,
};
pub const TrackCommand = struct {
    kind: enum { move, finish },
    direction: ?Direction = null,
    cells: ?u16 = null,
};
pub const Track = struct {
    id: []const u8,
    selector: u8,
    commands: []const TrackCommand,
};
pub const Effect = struct {
    kind: enum {
        glyph_descriptor_display,
        queue_track,
        wait_text_queue_empty,
        descriptor_state_transition,
        open_dialogue_box,
        start_or_wait_dialogue,
        dialogue,
        wait_for_accept,
        close_dialogue_box,
        wait_event_flags_low2_clear,
        story_or,
        area_index_set,
    },
    source_offset: u32,
    source_address: u32,
    operands: []const u8,
    flag: ?event_runtime.Flag = null,
    area_index: ?u16 = null,
    area_index_source_address: ?u32 = null,
    track: ?Track = null,
    selector: ?u8 = null,
    parameter: ?u8 = null,
    mask: ?u8 = null,
    slot: ?u8 = null,
    layout: ?u8 = null,
    code: ?u8 = null,
    speaker_slot: ?u8 = null,
    table: ?u8 = null,
    index: ?u8 = null,
    pages: ?[]const []const u8 = null,
};
pub const Reconstruction = struct {
    required: bool,
    same_room: bool,
    construction_story: enum { not_applicable, current_after_prefix_effects },
};
pub const Continuation = struct {
    kind: enum { field_ready, world_ready, ordinary_source_selection },
    automatic_program_id: ?[]const u8 = null,
};
pub const Provenance = struct {
    file: []const u8,
    room: ?u8 = null,
    entity: ?u8 = null,
    entry_offset: ?u32 = null,
    predicate_offset: ?u32 = null,
    stream_offset: ?u32 = null,
    prefix_hex: ?[]const u8 = null,
    transition_offset: ?u32 = null,
    transition_operands: ?[]const u8 = null,
    predicate: ?std.json.Value = null,
    world_table: ?[]const u8 = null,
    point_index: ?u8 = null,
    record_stride: ?u8 = null,
    consumers: []const []const u8,
};
pub const Route = struct {
    id: []const u8,
    status: enum { proven },
    source_order: u8,
    origin: Origin,
    destination: Destination,
    conditions: []const event_runtime.Condition,
    event_flags_low2_clear: bool,
    effects: []const Effect,
    reconstruction: Reconstruction,
    continuation: Continuation,
    provenance: Provenance,
};
pub const CoordinateContracts = route_coordinates.Contracts;
pub const Coverage = struct {
    proven: u8,
    unresolved: u8,
    field_doorways: u8,
    world_entries_and_returns: u8,
    same_room_reconstructions: u8,
};
pub const Packet = struct {
    schema: []const u8,
    id: []const u8,
    content_sha256: []const u8,
    sources: []const Source,
    locations: []const Location,
    coordinate_contracts: CoordinateContracts,
    ordering: []const u8,
    story_values: []const StoryValue,
    routes: []const Route,
    coverage: Coverage,

    pub fn location(self: Packet, id: []const u8) ?Location {
        for (self.locations) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn storyValue(self: Packet, id: []const u8) ?StoryValue {
        for (self.story_values) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn route(self: Packet, id: []const u8) ?Route {
        for (self.routes) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
};

pub const FieldTrigger = struct {
    position: Coordinate,
    direction: ?Direction = null,
};
pub const RequestTrigger = union(enum) {
    field_rectangle: FieldTrigger,
    world_point: Coordinate,
    ordinary_event: void,
};
pub const Request = struct {
    route_id: []const u8,
    origin_id: []const u8,
    trigger: RequestTrigger,
    event_flags_low2: u2 = 0,
};
pub const TransitionPlan = struct {
    route_id: []const u8,
    source_order: u8,
    destination: Destination,
    effects: []const Effect,
    reconstruction: Reconstruction,
    continuation: Continuation,
};

fn validId(id: []const u8) !void {
    if (!validation.isAsciiId(id, 96, "_")) return error.InvalidRouteId;
}

fn validHash(hash: []const u8) !void {
    if (!validation.isHex64(hash)) return error.InvalidRouteIdentity;
}

fn parseScenarioId(id: []const u8) ?u16 {
    return validation.parseScenarioId(id);
}

fn validCoordinate(value: Coordinate) !void {
    if (value.x < 0 or value.y < 0) return error.InvalidRouteCoordinate;
    switch (value.domain) {
        .half_cell => if (value.x > 255 or value.y > 255) return error.InvalidRouteCoordinate,
        .field_pixel => if (value.x > 2040 or value.y > 2040) return error.InvalidRouteCoordinate,
        .world_cell => if (value.x > 4096 or value.y > 4096) return error.InvalidRouteCoordinate,
    }
}

fn validateCondition(packet: Packet, condition: event_runtime.Condition) !void {
    if (condition.flag.mask == 0 or packet.storyValue(condition.flag.id) == null) return error.UnsupportedRoutePredicate;
}

fn validateEffect(packet: Packet, effect: Effect) !void {
    if (effect.source_address != 0x80010000 + effect.source_offset or effect.operands.len > 8) return error.InvalidRouteEffect;
    switch (effect.kind) {
        .story_or => {
            const value = effect.flag orelse return error.InvalidRouteEffect;
            if (value.mask == 0 or packet.storyValue(value.id) == null) return error.UnknownRouteStoryValue;
            if (effect.operands.len != 2) return error.InvalidRouteEffect;
        },
        .area_index_set => {
            if (effect.operands.len != 1 or effect.area_index == null or effect.area_index_source_address == null) return error.InvalidRouteEffect;
            if (effect.area_index_source_address.? != 0x80171C2C + 2 * @as(u32, effect.operands[0])) return error.InvalidRouteEffect;
        },
        .queue_track => {
            const track = effect.track orelse return error.InvalidRouteEffect;
            try validId(track.id);
            if (track.commands.len == 0 or track.commands[track.commands.len - 1].kind != .finish) return error.InvalidRouteTrack;
            for (track.commands) |command| switch (command.kind) {
                .move => if (command.direction == null or command.cells == null or command.cells.? == 0) return error.InvalidRouteTrack,
                .finish => if (command.direction != null or command.cells != null) return error.InvalidRouteTrack,
            };
        },
        .descriptor_state_transition => if (effect.selector == null or effect.parameter == null or effect.mask == null or effect.mask.? == 0) return error.InvalidRouteEffect,
        .open_dialogue_box => if (effect.slot == null or effect.layout == null) return error.InvalidRouteEffect,
        .start_or_wait_dialogue => if (effect.slot == null or effect.code == null) return error.InvalidRouteEffect,
        .dialogue => if (effect.speaker_slot == null or effect.table == null or effect.index == null or effect.pages == null or effect.pages.?.len == 0) return error.InvalidRouteEffect,
        else => {},
    }
}

pub fn validate(packet: Packet) !void {
    if (!std.mem.eql(u8, packet.schema, schema)) return error.UnsupportedRouteSchema;
    try validId(packet.id);
    try validHash(packet.content_sha256);
    if (packet.sources.len == 0 or packet.sources.len > 8 or packet.locations.len == 0 or packet.locations.len > 16 or packet.routes.len == 0 or packet.routes.len > max_routes) return error.InvalidRouteContent;
    if (packet.coverage.proven != packet.routes.len or packet.coverage.unresolved != 0) return error.InvalidRouteCoverage;
    for (packet.sources) |source| {
        if (source.file.len == 0 or source.size == 0) return error.InvalidRouteSource;
        try validHash(source.sha256);
    }
    for (packet.locations, 0..) |location, index| {
        try validId(location.id);
        for (packet.locations[0..index]) |other| if (std.mem.eql(u8, location.id, other.id)) return error.DuplicateRouteLocation;
        switch (location.kind) {
            .world_region => if (location.world_region == null or location.source_room != null or location.source_file != null) return error.InvalidRouteLocation,
            .field_room => {
                if (location.source_room == null or location.world_region != null) return error.InvalidRouteLocation;
                if (!std.mem.eql(u8, location.source_file orelse return error.InvalidRouteLocation, "DATA/02_AREA.B/VB6.BIN")) return error.InvalidRouteLocation;
            },
        }
    }
    for (packet.story_values, 0..) |value, index| {
        try validId(value.id);
        const byte_index = parseScenarioId(value.id) orelse return error.InvalidRouteStoryValue;
        if (byte_index >= 240 or byte_index != value.byte_index) return error.InvalidRouteStoryValue;
        for (packet.story_values[0..index]) |other| {
            if (std.mem.eql(u8, value.id, other.id) or value.byte_index == other.byte_index) return error.DuplicateRouteStoryValue;
        }
    }
    for (packet.routes, 0..) |route, index| {
        try validId(route.id);
        for (packet.routes[0..index]) |other| if (std.mem.eql(u8, route.id, other.id)) return error.DuplicateRoute;
        const origin = packet.location(route.origin.location_id) orelse return error.UnknownRouteOrigin;
        const destination_location = packet.location(route.destination.location_id) orelse return error.UnknownRouteDestination;
        if (route.effects.len > max_effects) return error.TooManyRouteEffects;
        if (route.event_flags_low2_clear != (origin.kind == .field_room)) return error.InvalidRouteBarrier;
        const trigger = route.origin.trigger;
        switch (trigger.kind) {
            .field_rectangle => {
                if (origin.kind != .field_room or trigger.point != null) return error.InvalidRouteTrigger;
                const rect = trigger.rectangle orelse return error.InvalidRouteTrigger;
                if (rect.domain != .field_pixel or rect.w <= 0 or rect.h <= 0 or rect.w > 2040 or rect.h > 2040) return error.InvalidRouteTrigger;
                try validCoordinate(.{ .domain = rect.domain, .x = rect.x, .y = rect.y });
            },
            .world_point => {
                if (origin.kind != .world_region or trigger.rectangle != null or trigger.direction != null) return error.InvalidRouteTrigger;
                const point = trigger.point orelse return error.InvalidRouteTrigger;
                if (point.domain != .world_cell) return error.InvalidRouteTrigger;
                try validCoordinate(point);
            },
            .ordinary_event => if (origin.kind != .field_room or trigger.rectangle != null or trigger.point != null or trigger.direction != null) return error.InvalidRouteTrigger,
        }
        const destination = route.destination;
        const expected_domain: CoordinateDomain = if (destination_location.kind == .world_region) .world_cell else .field_pixel;
        const source_domain: CoordinateDomain = if (expected_domain == .world_cell) .world_cell else .half_cell;
        if (destination.spawn.domain != expected_domain or destination.source_spawn.domain != source_domain) return error.InvalidRouteCoordinateDomain;
        try validCoordinate(destination.spawn);
        try validCoordinate(destination.source_spawn);
        if (source_domain == .half_cell) {
            const source: coordinates.HalfCell = .{ .x = destination.source_spawn.x, .y = destination.source_spawn.y };
            const pixels = source.toPixels();
            if (destination.spawn.x != pixels.x or destination.spawn.y != pixels.y) return error.RouteCoordinateMismatch;
        }
        if (source_domain == .world_cell and (destination.spawn.x != destination.source_spawn.x or destination.spawn.y != destination.source_spawn.y)) return error.RouteCoordinateMismatch;
        for (route.conditions) |condition| try validateCondition(packet, condition);
        for (route.effects) |effect| try validateEffect(packet, effect);
        const reconstruction = route.reconstruction;
        if (reconstruction.required != (destination_location.kind == .field_room) or reconstruction.same_room != (origin.kind == .field_room and std.mem.eql(u8, route.origin.location_id, destination.location_id))) return error.InvalidRouteReconstruction;
        if (reconstruction.required != (reconstruction.construction_story == .current_after_prefix_effects)) return error.InvalidRouteReconstruction;
        const continuation = route.continuation;
        if (continuation.automatic_program_id != null) return error.UnsupportedRouteContinuation;
        switch (continuation.kind) {
            .world_ready => if (destination_location.kind != .world_region) return error.InvalidRouteContinuation,
            .field_ready => if (destination_location.kind != .field_room or reconstruction.same_room) return error.InvalidRouteContinuation,
            .ordinary_source_selection => if (!reconstruction.same_room) return error.InvalidRouteContinuation,
        }
        if (origin.kind == .field_room) {
            if (route.provenance.room == null or route.provenance.entity == null or route.provenance.entity.? != route.source_order or route.provenance.stream_offset == null) return error.InvalidRouteProvenance;
            if (!std.mem.eql(u8, route.provenance.file, "DATA/02_AREA.B/VB6.BIN")) return error.InvalidRouteProvenance;
        }
    }
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    if (bytes.len > max_json_bytes) return error.RouteContentTooLarge;
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

fn matchesTrigger(trigger: Trigger, request: RequestTrigger) bool {
    switch (trigger.kind) {
        .field_rectangle => switch (request) {
            .field_rectangle => |input| {
                if (input.position.domain != .field_pixel) return false;
                if (trigger.direction != null and input.direction != trigger.direction) return false;
                const rect = trigger.rectangle.?;
                return input.position.x >= rect.x and input.position.y >= rect.y and
                    input.position.x < rect.x + rect.w and input.position.y < rect.y + rect.h;
            },
            else => return false,
        },
        .world_point => switch (request) {
            .world_point => |point| {
                const expected = trigger.point.?;
                return point.domain == .world_cell and
                    point.x >= expected.x and point.x <= expected.x + 1 and
                    point.y >= expected.y and point.y <= expected.y + 1;
            },
            else => return false,
        },
        .ordinary_event => return request == .ordinary_event,
    }
}

pub fn plan(packet: Packet, story: *const event_runtime.StoryState, request: Request) !TransitionPlan {
    try validate(packet);
    const route = packet.route(request.route_id) orelse return error.UnknownRoute;
    if (!std.mem.eql(u8, route.origin.location_id, request.origin_id)) return error.RouteOriginMismatch;
    if (!story.matches(route.conditions)) return error.RouteIneligible;
    if (route.event_flags_low2_clear and request.event_flags_low2 != 0) return error.TransitionBarrierBlocked;
    if (!matchesTrigger(route.origin.trigger, request.trigger)) return error.RouteTriggerMismatch;
    return .{
        .route_id = route.id,
        .source_order = route.source_order,
        .destination = route.destination,
        .effects = route.effects,
        .reconstruction = route.reconstruction,
        .continuation = route.continuation,
    };
}
