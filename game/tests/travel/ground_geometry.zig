//! Focused port check: the exported ground geometry, the single query
//! contract across room dimensions, source query order, edges and levels.
//!
//! The expected probes come from the exporter, but they are cross-checked by a
//! second raw-byte implementation in the ground-geometry exporter (`--check`) before export.  The
//! synthetic rooms below are hand-authored and independent of the exporter.

const std = @import("std");
const ground = @import("travel").ground;
const asset = @import("travel_data").ground_geometry;

fn loadGeometry(allocator: std.mem.Allocator) !*ground.Geometry {
    return ground.Geometry.load(allocator, asset.json);
}

test "exported geometry: every probe agrees with the port query" {
    const allocator = std.testing.allocator;
    const geometry = try loadGeometry(allocator);
    defer geometry.deinit();

    try std.testing.expectEqual(@as(usize, 8), geometry.rooms.len);
    var probes: usize = 0;
    var edges: usize = 0;
    var level1: usize = 0;
    var dimensions = std.StringHashMap([2]u16).init(allocator);
    defer dimensions.deinit();
    for ([_][]const u8{ "vb6_room0", "vb6_room5", "vb6_room6", "vb6_room7", "vb6_room9", "vaa_room2", "vb3_room0", "vd5_room1" }) |id| {
        const room = geometry.roomById(id) orelse return error.MissingRoom;
        try dimensions.put(room.id, .{ room.width_tiles, room.height_tiles });
        try std.testing.expect(room.probes.len >= 10);
        for (room.probes) |probe| {
            probes += 1;
            const result = ground.groundAt(room, probe.x_cell, probe.y_cell, probe.level);
            try std.testing.expectEqual(probe.edge_blocked, result.edge_blocked);
            if (probe.edge_blocked) {
                edges += 1;
                try std.testing.expect(!result.walkable);
                continue;
            }
            if (probe.level == 1) level1 += 1;
            try std.testing.expectEqual(@as(u8, probe.terrain), @as(u8, result.terrain));
            try std.testing.expectEqual(probe.scenery_bits, result.scenery_bits);
            try std.testing.expectEqual(probe.surface_plus_one, result.surface_plus_one);
            try std.testing.expectEqual(probe.contributor, result.contributor);
            try std.testing.expectEqual(@as(u8, probe.solid), @as(u8, result.solid));
            try std.testing.expectEqual(probe.walkable, result.walkable);
            try std.testing.expect(!result.unsupported_level);
        }
    }
    try std.testing.expect(probes >= 150);
    try std.testing.expect(edges > 0);
    try std.testing.expect(level1 > 0);
    // Different dimension classes are data, not constants.
    try std.testing.expectEqual([2]u16{ 24, 16 }, dimensions.get("vb6_room5").?);
    try std.testing.expectEqual([2]u16{ 32, 24 }, dimensions.get("vb6_room0").?);
    try std.testing.expectEqual([2]u16{ 40, 56 }, dimensions.get("vaa_room2").?);
    try std.testing.expectEqual([2]u16{ 54, 49 }, dimensions.get("vd5_room1").?);
}

test "moved positions are queried from geometry, not from a constructor anchor" {
    const allocator = std.testing.allocator;
    const geometry = try loadGeometry(allocator);
    defer geometry.deinit();
    const room = geometry.roomById("vb6_room0") orelse return error.MissingRoom;
    const anchor = ground.groundAt(room, 33, 17, 0);
    const moved = ground.groundAt(room, 33, 18, 0);
    try std.testing.expect(!anchor.walkable);
    try std.testing.expect(moved.walkable);
    try std.testing.expect(anchor.scenery_bits != moved.scenery_bits);

    const raised = geometry.roomById("vaa_room2") orelse return error.MissingRoom;
    var found_raised = false;
    for (raised.probes) |probe| {
        if (!std.mem.eql(u8, probe.kind, "raised") and !std.mem.eql(u8, probe.kind, "raised_level1")) continue;
        const result = ground.groundAt(raised, probe.x_cell, probe.y_cell, probe.level);
        if (result.upper() != 0 and result.surface_plus_one != 0) {
            found_raised = true;
            try std.testing.expect(result.support(raised) != null);
        }
    }
    try std.testing.expect(found_raised);

    // Level 2 is not proven: blocked, never silently borrowed from the nearest surface.
    const blocked = ground.groundAt(raised, 1, 1, 2);
    try std.testing.expect(blocked.unsupported_level);
    try std.testing.expect(!blocked.level_supported);
    try std.testing.expect(!blocked.walkable);
}

const synthetic_codes_2x2: [8]u8 = @splat(0);
const synthetic_collision_2x2 = [_]u8{0x80};
const synthetic_mask_skipped: [4]u8 = @splat(1);
const synthetic_mask_solid: [4]u8 = @splat(1);
const synthetic_mask_upper: [4]u8 = @splat(2);
const synthetic_mask_plane2: [4]u8 = @splat(1);

const synthetic_objects_2x2 = [_]ground.Object{
    .{ .x_cell = 0, .y_cell = 0, .kind = 9, .order = 0, .level = 1, .width_cells = 2, .height_cells = 2, .mask = &synthetic_mask_skipped },
    .{ .x_cell = 0, .y_cell = 0, .kind = 3, .order = 200, .level = 1, .width_cells = 2, .height_cells = 2, .mask = &synthetic_mask_solid },
    .{ .x_cell = 2, .y_cell = 0, .kind = 4, .order = 201, .level = 1, .width_cells = 2, .height_cells = 2, .mask = &synthetic_mask_upper },
    .{ .x_cell = 2, .y_cell = 2, .kind = 5, .order = 202, .level = 2, .width_cells = 2, .height_cells = 2, .mask = &synthetic_mask_plane2 },
};

const synthetic_room_2x2 = ground.Room{
    .id = "synthetic_2x2",
    .width_tiles = 2,
    .height_tiles = 2,
    .width_cells = 4,
    .height_cells = 4,
    .tile_codes = &synthetic_codes_2x2,
    .collision = &synthetic_collision_2x2,
    .objects = &synthetic_objects_2x2,
    .planes = &[_]u8{1},
    .probes = &.{},
};

test "synthetic 2x2: order exclusion, first contributing record and upper surface" {
    const room = &synthetic_room_2x2;
    // order 0 is skipped; the next contributing record owns the footprint.
    const first = ground.groundAt(room, 0, 0, 0);
    try std.testing.expectEqual(@as(?u16, 1), first.contributor);
    try std.testing.expectEqual(@as(u4, 0xF), first.low());
    try std.testing.expectEqual(@as(u16, 0), first.surface_plus_one);
    try std.testing.expect(!first.walkable);

    // Only the upper-surface record overlaps this origin; the terrain below is masked
    // by its coverage, so the raised origin is walkable and attachable.
    const raised = ground.groundAt(room, 2, 0, 0);
    try std.testing.expectEqual(@as(?u16, 2), raised.contributor);
    try std.testing.expectEqual(@as(u4, 0), raised.low());
    try std.testing.expectEqual(@as(u4, 0xF), raised.upper());
    try std.testing.expectEqual(@as(u16, 3), raised.surface_plus_one);
    try std.testing.expect(raised.attachable());
    try std.testing.expect(raised.walkable);
    const support = raised.support(room) orelse return error.MissingSupport;
    try std.testing.expectEqual(@as(u16, 2), support.record);
    try std.testing.expectEqual(@as(u8, 1), support.level);
    try std.testing.expectEqual(@as(u8, 4), support.kind);

    // Plane 2 is excluded at level 0 and included at level 1 (record plane in {L,L+1}).
    const level0 = ground.groundAt(room, 2, 2, 0);
    try std.testing.expectEqual(@as(?u16, null), level0.contributor);
    try std.testing.expectEqual(@as(u16, 0), level0.surface_plus_one);
    const level1 = ground.groundAt(room, 2, 2, 1);
    try std.testing.expectEqual(@as(?u16, 3), level1.contributor);
    try std.testing.expectEqual(@as(u4, 0xF), level1.low());
}

const synthetic_codes_3x2 = [12]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 };
const synthetic_collision_3x2 = [_]u8{0x0A};

const synthetic_room_3x2 = ground.Room{
    .id = "synthetic_3x2",
    .width_tiles = 3,
    .height_tiles = 2,
    .width_cells = 6,
    .height_cells = 4,
    .tile_codes = &synthetic_codes_3x2,
    .collision = &synthetic_collision_3x2,
    .objects = &.{},
    .planes = &[_]u8{1},
    .probes = &.{},
};

test "synthetic 3x2: stride follows the room dimensions and edges block" {
    const room = &synthetic_room_3x2;
    // Code 1 selects the low nibble 0xA: quadrants 1 and 3 are solid.
    try std.testing.expectEqual(@as(u4, 0xA), ground.groundAt(room, 0, 0, 0).terrain);
    try std.testing.expectEqual(@as(u4, 0xA), ground.groundAt(room, 2, 0, 0).terrain);
    try std.testing.expectEqual(@as(u4, 0xA), ground.groundAt(room, 4, 2, 0).terrain);
    // The last cell column/row cannot supply a 2x2 footprint.
    for ([_][2]u16{ .{ 5, 0 }, .{ 0, 3 }, .{ 5, 3 } }) |point| {
        const edge = ground.groundAt(room, point[0], point[1], 0);
        try std.testing.expect(edge.edge_blocked);
        try std.testing.expect(!edge.walkable);
        try std.testing.expectEqual(@as(u4, 0), edge.solid);
    }
}

test "combination: instruction-derived four cases" {
    // level 0, no surface: (low & ~upper) | terrain.
    try std.testing.expectEqual(@as(u4, 0x1), ground.combine(0x1, .{ .bits = 0x0020, .surface_plus_one = 0 }, 0));
    // level 0, surface, upper & ~low: low | (terrain & ~coverage).
    try std.testing.expectEqual(@as(u4, 0x0), ground.combine(0x1, .{ .bits = 0x0120, .surface_plus_one = 1 }, 0));
    // level 0, surface, upper == low (room 6 divergence case): low & ~upper cancels.
    try std.testing.expectEqual(@as(u4, 0x0), ground.combine(0x0, .{ .bits = 0x0088, .surface_plus_one = 0 }, 0));
    // attached level, surface: (low & coverage) | (terrain & ~coverage).
    try std.testing.expectEqual(@as(u4, 0x1), ground.combine(0x0, .{ .bits = 0x0101, .surface_plus_one = 1 }, 1));
    try std.testing.expectEqual(@as(u4, 0x0), ground.combine(0x1, .{ .bits = 0x0102, .surface_plus_one = 1 }, 1));
    // attached level, no surface: low | (terrain & ~coverage).
    try std.testing.expectEqual(@as(u4, 0x1), ground.combine(0x0, .{ .bits = 0x0101, .surface_plus_one = 0 }, 1));
}

const bad_schema =
    \\{"schema":"suikoden-field-ground-geometry/2",
    \\"units":{"cell":{"pixels":8},"tile":{"cells":2,"pixels":16},
    \\"footprint":{"cells":[2,2],"pixels":[16,16]},"level":{"proven":[0,1]}},
    \\"rooms":[]}
;

const bad_hex =
    \\{"schema":"suikoden-field-ground-geometry/1",
    \\"units":{"cell":{"pixels":8},"tile":{"cells":2,"pixels":16},
    \\"footprint":{"cells":[2,2],"pixels":[16,16]},"level":{"proven":[0,1]}},
    \\"rooms":[{"id":"bad","room":0,"section":0,"width_tiles":1,"height_tiles":1,
    \\"width_cells":2,"height_cells":2,"tile_codes_hex":"000","tile_codes_sha256":"00",
    \\"collision_hex":"00","collision_sha256":"00","masks_sha256":"00","planes":[1],
    \\"objects":[],"probes":[]}]}
;

const bad_mask =
    \\{"schema":"suikoden-field-ground-geometry/1",
    \\"units":{"cell":{"pixels":8},"tile":{"cells":2,"pixels":16},
    \\"footprint":{"cells":[2,2],"pixels":[16,16]},"level":{"proven":[0,1]}},
    \\"rooms":[{"id":"bad","room":0,"section":0,"width_tiles":1,"height_tiles":1,
    \\"width_cells":2,"height_cells":2,"tile_codes_hex":"0000",
    \\"tile_codes_sha256":"96a296d224f285c67bee93c30f8a309157f0daa35dc5b87e410b78630a09cfc7",
    \\"collision_hex":"00",
    \\"collision_sha256":"6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
    \\"masks_sha256":"00","planes":[1],
    \\"objects":[{"index":0,"x_cell":0,"y_cell":0,"kind":1,"order":200,"level":1,
    \\"width_cells":1,"height_cells":1,"mask_hex":"04","mask_sha256":"00"}],
    \\"probes":[]}]}
;

const bad_tile_hash =
    \\{"schema":"suikoden-field-ground-geometry/1",
    \\"units":{"cell":{"pixels":8},"tile":{"cells":2,"pixels":16},
    \\"footprint":{"cells":[2,2],"pixels":[16,16]},"level":{"proven":[0,1]}},
    \\"rooms":[{"id":"bad","room":0,"section":0,"width_tiles":1,"height_tiles":1,
    \\"width_cells":2,"height_cells":2,"tile_codes_hex":"0000","tile_codes_sha256":"00",
    \\"collision_hex":"00","collision_sha256":"00","masks_sha256":"00","planes":[1],
    \\"objects":[],"probes":[]}]}
;

test "malformed and unproven assets are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedSchema, ground.Geometry.load(allocator, bad_schema));
    try std.testing.expectError(error.InvalidHex, ground.Geometry.load(allocator, bad_hex));
    try std.testing.expectError(error.InvalidMaskByte, ground.Geometry.load(allocator, bad_mask));
    try std.testing.expectError(error.HashMismatch, ground.Geometry.load(allocator, bad_tile_hash));
}
