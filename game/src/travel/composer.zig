//! Compose source field layers and actor projection.
//!
//! The packet in the embedded campaign asset is produced by
//! the extraction pipeline from static source facts.  This module is the
//! runtime seam: it validates the decoded room geometry, composes an ordered
//! draw list for one room from the source layer tags, the ground-actor depth and
//! the validated camera, and emits that list through a handler-shaped sink.
//!
//! What it does *not* do: it owns no pixels, palettes, atlas rectangles, VRAM
//! residency, lighting, shadows, camera rotation/pitch/zoom or the scripted
//! shake offset.  The packet is geometry and ordering data; `disclosures` in it
//! records every one of those limits and `validate` refuses a packet that has
//! dropped them.
//!
//! Ordering follows the source: a larger tag sits further back, so pieces are
//! painted in ascending `depth = 256 - tag`.  Equal-tag inserts from one emitter
//! paint in reverse emission order because the ordering-table insert prepends
//! (`0x8014C850`).  The cross-emitter order at an equal tag is not decoded and
//! is reported as `cross_path_undeclared`, never guessed away.
//!
//! The camera is the source rule (`0x8012CA44`, duplicated at room entry
//! `0x801317AC..0x80131884`): `focus + nudge - (152,112)`, floored at zero and
//! clamped to `section_pixels - (320,240)`.  The raw value may go negative for a
//! room smaller than the viewport; the per-frame draw path floors it again
//! (`0x80134018..0x80134054`), and such a room is centred by the *layer* offset
//! `(viewport - layer_pixels) >> 1` (`0x80133F88..0x80134014`), not by the
//! camera.  Which layer's offset is in force during the scenery/actor passes is
//! not proven, so the caller declares it in `Frame`; the map layers use their own
//! validated offsets.
//!
//! No original instruction is executed and no allocation happens after `open`.

const std = @import("std");
const validation = @import("validation");

pub const schema = "suikoden-field-layers/1";
pub const max_rooms = 16;
pub const max_pieces = 512;
pub const max_actors = 64;

pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const Camera = Point;

pub const Viewport = struct { width: i32, height: i32 };

pub const CameraContract = struct {
    focus_scale: i32,
    bias_x: i32,
    bias_y: i32,
    floor: i32,
    supported: []const []const u8,
    unsupported: []const []const u8,
};

pub const SecondaryCase = struct { byte8_mask: u16, tag: i32 };

pub const LayerContract = struct {
    depth_origin: i32,
    primary_tag: i32,
    secondary_cases: []const SecondaryCase,
    secondary_default_tag: i32,
    scenery_order_zero_tags: []const i32,
    scenery_order_one_tag: i32,
    actor_tag_rule: []const u8,
    tie_rule: []const u8,
    tie_cross_path: []const u8,
};

pub const SceneryQuad = struct {
    object: u16,
    vertex: u16,
    scenery_type: u16,
    order: u16,
    tag: i32,
    depth: i32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    hflip: bool,
    vflip: bool,
    semi_transparent: bool,
};

pub const Entity = struct {
    index: u16,
    character_id: u16,
    x: i32,
    y: i32,
    tag: i32,
    depth: i32,
    flags: u16,
    interactive: bool,
};

pub const Probe = struct {
    id: []const u8,
    focus_x: i32,
    focus_y: i32,
    nudge_x: i32,
    nudge_y: i32,
    raw_x: i32,
    raw_y: i32,
    render_x: i32,
    render_y: i32,
};

pub const Room = struct {
    id: []const u8,
    role: []const u8,
    source_file: []const u8,
    source_lba: u32,
    source_size: u32,
    source_sha256: []const u8,
    record_index: u16,
    section_index: u16,
    tiles_x: i32,
    tiles_y: i32,
    pixels_x: i32,
    pixels_y: i32,
    cells_x: i32,
    cells_y: i32,
    room_byte7: u8,
    room_byte8: u8,
    primary_tag: i32,
    primary_depth: i32,
    secondary_present: bool,
    secondary_tag: i32,
    secondary_depth: i32,
    secondary_mode: u32,
    secondary_tiles_x: i32,
    secondary_tiles_y: i32,
    secondary_pixels_x: i32,
    secondary_pixels_y: i32,
    secondary_resolution: []const u8,
    centering_x: i32,
    centering_y: i32,
    secondary_centering_x: i32,
    secondary_centering_y: i32,
    animated_types: []const u16,
    unpositioned_entities: u16,
    out_of_room_entities: u16,
    scenery: []const SceneryQuad,
    entities: []const Entity,
    camera_probes: []const Probe,
};

pub const Counts = struct {
    rooms: u16,
    scenery_quads: u32,
    projected_entities: u16,
    static_words: u16,
};

pub const Asset = struct {
    schema: []const u8,
    target: []const u8,
    snapshot_base: []const u8,
    producer: []const u8,
    viewport: Viewport,
    camera: CameraContract,
    layer_contract: LayerContract,
    rooms: []const Room,
    disclosures: []const []const u8,
    counts: Counts,
    content_sha256: []const u8,
};

pub const LayerKind = enum { primary_map, secondary_map, scenery, actor };

pub const Visibility = enum { inside, partial, outside };

/// A piece's place relative to the actor band of one composed list.
pub const Relation = enum { no_actors, behind_actors, between_actors, in_front_of_actors, is_actor };

pub const Tie = enum { sole, reverse_emission_same_path, cross_path_undeclared };

pub const Origin = union(enum) {
    primary_map,
    secondary_map,
    scenery: struct { object: u16, vertex: u16 },
    actor: struct { slot: u16 },
};

/// One caller-supplied actor projection.  `x`/`y` are source pixels (8px cells
/// multiplied out), `w`/`h` are the caller's sprite frame bounds, and `support`
/// is the source scenery-object index of the surface the actor stands on --
/// the source surface-attached branch (`0x8012FE0C..0x8012FE40`) takes that
/// record's tag instead of the ground rule.
pub const Player = struct {
    id: []const u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    support: ?u16 = null,
};

/// The camera and the caller-declared layer-centring offset for one composition.
pub const Frame = struct {
    camera_x: i32,
    camera_y: i32,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
};

pub const Placed = struct {
    origin: Origin,
    kind: LayerKind,
    tag: i32,
    depth: i32,
    screen: Rect,
    visibility: Visibility,
    relation: Relation,
    tie: Tie,
};

pub const List = struct {
    items: [max_pieces]Placed = undefined,
    length: usize = 0,
    room_id: []const u8 = "",
    frame: Frame = .{ .camera_x = 0, .camera_y = 0 },

    pub fn slice(self: *const List) []const Placed {
        return self.items[0..self.length];
    }

    /// Deterministic identity of one composed list, so a reload can be compared
    /// against the list it replaces without comparing renderer state.
    pub fn fingerprint(self: *const List) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(self.room_id);
        var buffer: [4]u8 = undefined;
        for ([_]i32{ self.frame.camera_x, self.frame.camera_y, self.frame.offset_x, self.frame.offset_y }) |value| {
            std.mem.writeInt(i32, &buffer, value, .little);
            hasher.update(&buffer);
        }
        for (self.items[0..self.length]) |item| {
            hasher.update(&[_]u8{
                @intCast(@backingInt(item.kind)),
                @intCast(@backingInt(item.visibility)),
                @intCast(@backingInt(item.relation)),
                @intCast(@backingInt(item.tie)),
            });
            for ([_]i32{ item.tag, item.depth, item.screen.x, item.screen.y, item.screen.w, item.screen.h }) |value| {
                std.mem.writeInt(i32, &buffer, value, .little);
                hasher.update(&buffer);
            }
            switch (item.origin) {
                .primary_map => hasher.update(&[_]u8{0}),
                .secondary_map => hasher.update(&[_]u8{1}),
                .scenery => |scenery| {
                    hasher.update(&[_]u8{
                        2,
                        @truncate(scenery.object),
                        @truncate(scenery.object >> 8),
                        @truncate(scenery.vertex),
                        @truncate(scenery.vertex >> 8),
                    });
                },
                .actor => |actor| {
                    hasher.update(&[_]u8{
                        3,
                        @truncate(actor.slot),
                        @truncate(actor.slot >> 8),
                    });
                },
            }
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
};

/// The call shape of the existing field sprite handler: a source rectangle size
/// and a destination origin.  The atlas rectangle is the caller's mapping and is
/// deliberately not part of this packet.
pub const Sink = struct {
    context: *anyopaque,
    draw: *const fn (context: *anyopaque, width: i32, height: i32, x: i32, y: i32) void,

    pub fn piece(self: Sink, item: Placed) void {
        self.draw(self.context, item.screen.w, item.screen.h, item.screen.x, item.screen.y);
    }
};

pub const Opened = struct {
    parsed: std.json.Parsed(Asset),

    pub fn deinit(self: *Opened) void {
        self.parsed.deinit();
    }

    pub fn asset(self: *const Opened) *const Asset {
        return &self.parsed.value;
    }

    pub fn room(self: *const Opened, id: []const u8) ?*const Room {
        for (self.parsed.value.rooms) |*candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate;
        return null;
    }
};

fn validId(id: []const u8) bool {
    return validation.isAsciiId(id, 64, "_");
}

fn validHash(hash: []const u8) bool {
    return validation.isHex64(hash);
}

fn validText(text: []const u8, maximum: usize) bool {
    return text.len > 0 and text.len <= maximum;
}

/// 0x80133F88..0x80134014: (viewport - extent) >> 1 when the layer is smaller,
/// else zero.
pub fn layerOffset(extent: i32, viewport: i32) i32 {
    return if (extent < viewport) @divTrunc(viewport - extent, 2) else 0;
}

/// 0x8012CA44: the raw follow camera.  It can be negative for a room smaller
/// than the viewport; that is the source value, not a bug to smooth over.
pub fn followCamera(contract: CameraContract, room: *const Room, viewport: Viewport, focus: Point, nudge: Point) Camera {
    var x = focus.x + nudge.x + contract.bias_x;
    var y = focus.y + nudge.y + contract.bias_y;
    if (x < contract.floor) x = contract.floor;
    if (y < contract.floor) y = contract.floor;
    const upper_x = room.pixels_x - viewport.width;
    const upper_y = room.pixels_y - viewport.height;
    if (upper_x < x) x = upper_x;
    if (upper_y < y) y = upper_y;
    return .{ .x = x, .y = y };
}

/// 0x80134018..0x80134054: the per-frame draw path floors each axis at zero.
pub fn renderCamera(contract: CameraContract, room: *const Room, viewport: Viewport, focus: Point, nudge: Point) Camera {
    const raw = followCamera(contract, room, viewport, focus, nudge);
    return .{ .x = @max(0, raw.x), .y = @max(0, raw.y) };
}

/// The source draw tag for one actor: the surface-attached branch selects the
/// supporting scenery record's tag, otherwise the low byte of `-Y_cell`.
pub fn actorTag(room: *const Room, player: Player) !i32 {
    if (!validText(player.id, 96)) return error.InvalidActorIdentity;
    if (player.w <= 0 or player.h <= 0) return error.InvalidActorFootprint;
    if (player.x < 0 or player.y < 0 or player.x >= room.pixels_x or player.y >= room.pixels_y) return error.ActorOutsideRoom;
    if (@mod(player.x, 8) != 0 or @mod(player.y, 8) != 0) return error.ActorNotOnCell;
    if (player.support) |object| {
        for (room.scenery) |quad| if (quad.object == object) return quad.tag;
        return error.UnknownSupport;
    }
    const cell = @divTrunc(player.y, 8);
    return (-cell) & 0xFF;
}

fn pathRank(origin: Origin) u8 {
    return switch (origin) {
        .primary_map => 0,
        .secondary_map => 1,
        .scenery => 2,
        .actor => 3,
    };
}

fn visibility(rect: Rect, viewport: Viewport) Visibility {
    const right = rect.x + rect.w;
    const bottom = rect.y + rect.h;
    if (right <= 0 or bottom <= 0 or rect.x >= viewport.width or rect.y >= viewport.height) return .outside;
    if (rect.x >= 0 and rect.y >= 0 and right <= viewport.width and bottom <= viewport.height) return .inside;
    return .partial;
}

const SortKey = struct {
    depth: i32,
    path: u8,
    emission: u32,
    placed: Placed,
};

fn lessThan(_: void, a: SortKey, b: SortKey) bool {
    if (a.depth != b.depth) return a.depth < b.depth;
    if (a.path != b.path) return a.path < b.path;
    // The ordering-table insert prepends, so equal-tag inserts from one emitter
    // paint in reverse emission order.
    return a.emission > b.emission;
}

fn append(
    keys: *[max_pieces]SortKey,
    count: *usize,
    emission: *u32,
    origin: Origin,
    tag: i32,
    depth: i32,
    world: Rect,
    offset: Point,
    frame: Frame,
    viewport: Viewport,
) !void {
    if (count.* == keys.len) return error.DrawListFull;
    const screen: Rect = .{
        .x = world.x - frame.camera_x + offset.x,
        .y = world.y - frame.camera_y + offset.y,
        .w = world.w,
        .h = world.h,
    };
    const kind: LayerKind = switch (origin) {
        .primary_map => .primary_map,
        .secondary_map => .secondary_map,
        .scenery => .scenery,
        .actor => .actor,
    };
    keys[count.*] = .{
        .depth = depth,
        .path = pathRank(origin),
        .emission = emission.*,
        .placed = .{
            .origin = origin,
            .kind = kind,
            .tag = tag,
            .depth = depth,
            .screen = screen,
            .visibility = visibility(screen, viewport),
            .relation = .no_actors,
            .tie = .sole,
        },
    };
    count.* += 1;
    emission.* += 1;
}

/// Compose one qualified draw list for `room` at `frame` with `players`.
pub fn compose(list: *List, asset: *const Asset, room: *const Room, players: []const Player, frame: Frame) !void {
    if (players.len > max_actors) return error.TooManyActors;
    list.* = .{ .room_id = room.id, .frame = frame };
    var keys: [max_pieces]SortKey = undefined;
    var count: usize = 0;
    var emission: u32 = 0;

    try append(&keys, &count, &emission, .primary_map, room.primary_tag, room.primary_depth, .{ .x = 0, .y = 0, .w = room.pixels_x, .h = room.pixels_y }, .{ .x = room.centering_x, .y = room.centering_y }, frame, asset.viewport);
    if (room.secondary_present) {
        try append(&keys, &count, &emission, .secondary_map, room.secondary_tag, room.secondary_depth, .{ .x = 0, .y = 0, .w = room.secondary_pixels_x, .h = room.secondary_pixels_y }, .{ .x = room.secondary_centering_x, .y = room.secondary_centering_y }, frame, asset.viewport);
    }
    for (room.scenery) |quad| {
        try append(&keys, &count, &emission, .{ .scenery = .{ .object = quad.object, .vertex = quad.vertex } }, quad.tag, quad.depth, .{ .x = quad.x, .y = quad.y, .w = quad.w, .h = quad.h }, .{ .x = frame.offset_x, .y = frame.offset_y }, frame, asset.viewport);
    }
    for (players, 0..) |player, slot| {
        const tag = try actorTag(room, player);
        try append(&keys, &count, &emission, .{ .actor = .{ .slot = @intCast(slot) } }, tag, asset.layer_contract.depth_origin - tag, .{ .x = player.x, .y = player.y, .w = player.w, .h = player.h }, .{ .x = frame.offset_x, .y = frame.offset_y }, frame, asset.viewport);
    }

    std.mem.sort(SortKey, keys[0..count], {}, lessThan);
    for (keys[0..count], 0..) |key, index| {
        var item = key.placed;
        if (index != 0 and keys[index - 1].depth == key.depth) {
            item.tie = if (keys[index - 1].path == key.path) .reverse_emission_same_path else .cross_path_undeclared;
        }
        list.items[index] = item;
    }
    list.length = count;

    // Relation to the actor band, computed on the final order.
    var first_actor: ?usize = null;
    var last_actor: ?usize = null;
    for (list.items[0..count], 0..) |item, index| {
        if (item.kind != .actor) continue;
        if (first_actor == null) first_actor = index;
        last_actor = index;
    }
    if (first_actor) |first| {
        for (list.items[0..count], 0..) |*item, index| {
            item.relation = if (item.kind == .actor)
                .is_actor
            else if (index < first)
                .behind_actors
            else if (index > last_actor.?)
                .in_front_of_actors
            else
                .between_actors;
        }
    }
}

/// Compose and hand every piece to the caller's handler in emitted order.
pub fn emit(asset: *const Asset, room: *const Room, players: []const Player, frame: Frame, sink: Sink) !void {
    var list: List = .{};
    try compose(&list, asset, room, players, frame);
    for (list.items[0..list.length]) |item| sink.piece(item);
}

fn validateCamera(asset: *const Asset) !void {
    if (asset.camera.focus_scale != 8 or asset.camera.floor != 0) return error.InvalidCameraContract;
    var have_rotation = false;
    var have_shake = false;
    var have_lighting = false;
    var have_shadow = false;
    for (asset.camera.unsupported) |token| {
        if (std.mem.eql(u8, token, "rotation")) have_rotation = true;
        if (std.mem.eql(u8, token, "scripted_shake")) have_shake = true;
        if (std.mem.eql(u8, token, "lighting")) have_lighting = true;
        if (std.mem.eql(u8, token, "shadow")) have_shadow = true;
    }
    if (!have_rotation or !have_shake or !have_lighting or !have_shadow) return error.UndeclaredCameraLimit;
}

fn validateLayerContract(asset: *const Asset) !void {
    const contract = asset.layer_contract;
    if (contract.depth_origin != 256 or contract.primary_tag != 0x1FE) return error.InvalidLayerContract;
    if (contract.scenery_order_zero_tags.len != 2) return error.InvalidLayerContract;
    if (!std.mem.eql(u8, contract.tie_cross_path, "undeclared")) return error.InvalidLayerContract;
    if (!std.mem.eql(u8, contract.actor_tag_rule, "low_byte_of_negated_y_cell")) return error.InvalidLayerContract;
}

fn validateRoom(asset: *const Asset, room: *const Room) !void {
    if (!validId(room.id) or !validText(room.role, 48)) return error.InvalidRoom;
    if (!validText(room.source_file, 96) or room.source_size == 0 or !validHash(room.source_sha256)) return error.InvalidRoomSource;
    if (!std.mem.eql(u8, room.secondary_resolution, "own_map") and
        !std.mem.eql(u8, room.secondary_resolution, "own_primary") and
        !std.mem.eql(u8, room.secondary_resolution, "companion_primary")) return error.InvalidRoom;
    if (room.tiles_x <= 0 or room.tiles_y <= 0 or room.tiles_x > 256 or room.tiles_y > 256) return error.InvalidRoom;
    if (room.pixels_x != room.tiles_x * 16 or room.pixels_y != room.tiles_y * 16) return error.InvalidRoom;
    if (room.cells_x != room.tiles_x * 2 or room.cells_y != room.tiles_y * 2) return error.InvalidRoom;
    if (room.primary_depth != asset.layer_contract.depth_origin - room.primary_tag) return error.InvalidRoom;
    if (room.secondary_depth != asset.layer_contract.depth_origin - room.secondary_tag) return error.InvalidRoom;
    if (room.secondary_pixels_x != room.secondary_tiles_x * 16 or room.secondary_pixels_y != room.secondary_tiles_y * 16) return error.InvalidRoom;
    if (room.centering_x != layerOffset(room.pixels_x, asset.viewport.width) or
        room.centering_y != layerOffset(room.pixels_y, asset.viewport.height)) return error.InvalidRoom;
    if (room.secondary_centering_x != layerOffset(room.secondary_pixels_x, asset.viewport.width) or
        room.secondary_centering_y != layerOffset(room.secondary_pixels_y, asset.viewport.height)) return error.InvalidRoom;
    const expected_mode: u32 = if ((room.room_byte7 & 1) != 0) 0x6100 else if ((room.room_byte7 & 2) != 0) 0x7100 else 0x4100;
    if (room.secondary_mode != expected_mode) return error.InvalidRoom;

    var secondary_known = room.secondary_tag == asset.layer_contract.secondary_default_tag;
    for (asset.layer_contract.secondary_cases) |case| {
        if ((@as(u16, room.room_byte8) & case.byte8_mask) != 0 and room.secondary_tag == case.tag) secondary_known = true;
    }
    if (!secondary_known) return error.InvalidRoom;

    for (room.scenery, 0..) |quad, index| {
        if (quad.tag < 0 or quad.tag > 0x1FF) return error.InvalidScenery;
        if (quad.depth != asset.layer_contract.depth_origin - quad.tag) return error.InvalidScenery;
        if (quad.w <= 0 or quad.h <= 0 or quad.w > 255 or quad.h > 255) return error.InvalidScenery;
        if (quad.object > 0x0FFF or quad.vertex > 0x0F) return error.InvalidScenery;
        for (room.scenery[0..index]) |prior| {
            if (prior.object == quad.object and prior.vertex == quad.vertex) return error.DuplicateSceneryVertex;
        }
    }

    for (room.entities, 0..) |entity, index| {
        if (entity.index >= 256) return error.InvalidEntity;
        if (entity.x < 0 or entity.y < 0 or entity.x >= room.pixels_x or entity.y >= room.pixels_y) return error.InvalidEntity;
        if (@mod(entity.x, 8) != 0 or @mod(entity.y, 8) != 0) return error.InvalidEntity;
        if (entity.tag != ((-@divTrunc(entity.y, 8)) & 0xFF)) return error.InvalidEntity;
        if (entity.depth != asset.layer_contract.depth_origin - entity.tag) return error.InvalidEntity;
        for (room.entities[0..index]) |prior| if (prior.index == entity.index) return error.DuplicateEntity;
    }

    for (room.camera_probes) |probe| {
        if (!std.mem.startsWith(u8, probe.id, room.id)) return error.InvalidCameraProbe;
        const focus: Point = .{ .x = probe.focus_x, .y = probe.focus_y };
        const nudge: Point = .{ .x = probe.nudge_x, .y = probe.nudge_y };
        const raw = followCamera(asset.camera, room, asset.viewport, focus, nudge);
        const render = renderCamera(asset.camera, room, asset.viewport, focus, nudge);
        if (raw.x != probe.raw_x or raw.y != probe.raw_y) return error.CameraProbeMismatch;
        if (render.x != probe.render_x or render.y != probe.render_y) return error.CameraProbeMismatch;
    }
}

pub fn validate(asset: *const Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema)) return error.UnsupportedSchema;
    if (!validHash(asset.content_sha256) or !validText(asset.target, 64) or asset.snapshot_base.len != 40) return error.InvalidIdentity;
    if (asset.viewport.width <= 0 or asset.viewport.height <= 0 or
        asset.viewport.width > 2048 or asset.viewport.height > 2048) return error.InvalidViewport;
    try validateCamera(asset);
    try validateLayerContract(asset);
    if (asset.rooms.len == 0 or asset.rooms.len > max_rooms) return error.InvalidRoom;
    if (asset.disclosures.len < 6) return error.UndeclaredLimit;
    var scenery: u32 = 0;
    var entities: u16 = 0;
    for (asset.rooms, 0..) |room, index| {
        for (asset.rooms[0..index]) |prior| if (std.mem.eql(u8, prior.id, room.id)) return error.DuplicateRoom;
        try validateRoom(asset, &room);
        scenery += @intCast(room.scenery.len);
        entities += @intCast(room.entities.len);
    }
    if (@as(usize, asset.counts.rooms) != asset.rooms.len or asset.counts.scenery_quads != scenery or
        asset.counts.projected_entities != entities) return error.CountMismatch;
    const total = asset.counts.scenery_quads + 2 * @as(u32, asset.counts.rooms) + asset.counts.projected_entities;
    if (total > max_pieces) return error.PacketTooLarge;
}

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !Opened {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(&parsed.value);
    return .{ .parsed = parsed };
}
