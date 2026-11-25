//! Dimension-independent static field ground queries.
//!
//! The data comes from the embedded campaign asset,
//! decoded from the area files by the extraction pipeline.  Coordinates
//! are source field cells (8 pixels); a tile is 2x2 cells.  `level` is the
//! source plane byte from a scenery record (the actor's retained support level),
//! not a pixel height.
//!
//! Query order is the original order:
//!   1. terrain footprint (MAIN 0x8012E08C)
//!   2. scenery record scan (0x8012E308)
//!   3. ground mask combination (0x8012DB9C)
//!
//! No PS1 pointer, LBA or section offset enters this module.  Dynamic surface
//! lifetime, levels above the proven 0/1, entity/trigger collision and
//! surface-attached draw depth are deliberately not modelled; `groundAt` blocks
//! unsupported levels instead of borrowing a nearest anchor.

const std = @import("std");

pub const schema = "suikoden-field-ground-geometry/1";
pub const cell_pixels: u8 = 8;
pub const tile_cells: u16 = 2;
pub const proven_levels = [_]u8{ 0, 1 };

pub const Cell = struct {
    x: u16,
    y: u16,
    level: u8 = 0,
};

pub const Object = struct {
    /// Placement cell of the mask's top-left corner.
    x_cell: u16,
    y_cell: u16,
    /// Source graphics object type (sheet selector); kept for support facts.
    kind: u8,
    /// Scenery order byte; 0 and 1 are excluded by the source query.
    order: u8,
    /// Source plane byte (scenery byte+4); 1 in the exported subset.
    level: u8,
    width_cells: u8,
    height_cells: u8,
    /// Row-major mask: bit0 solid, bit1 upper surface. Values are 0..3.
    mask: []const u8,
};

pub const Scenery = struct {
    /// Bits 0..3 solid, 4..7 upper surface, 8..11 footprint coverage.
    bits: u16 = 0,
    /// Source surface output: 0 = no surface, otherwise record index + 1.
    surface_plus_one: u16 = 0,
    /// First record that contributed a solid or upper bit, or null.
    contributor: ?u16 = null,

    pub fn low(self: Scenery) u4 {
        return @truncate(self.bits & 0xF);
    }

    pub fn upper(self: Scenery) u4 {
        return @truncate((self.bits >> 4) & 0xF);
    }

    pub fn coverage(self: Scenery) u4 {
        return @truncate((self.bits >> 8) & 0xF);
    }
};

pub const Surface = struct {
    record: u16,
    level: u8,
    kind: u8,
};

pub const Ground = struct {
    terrain: u4 = 0,
    scenery_bits: u16 = 0,
    surface_plus_one: u16 = 0,
    contributor: ?u16 = null,
    solid: u4 = 0,
    walkable: bool = false,
    edge_blocked: bool = false,
    level: u8 = 0,
    level_supported: bool = true,
    unsupported_level: bool = false,

    pub fn low(self: Ground) u4 {
        return @truncate(self.scenery_bits & 0xF);
    }

    pub fn upper(self: Ground) u4 {
        return @truncate((self.scenery_bits >> 4) & 0xF);
    }

    pub fn coverage(self: Ground) u4 {
        return @truncate((self.scenery_bits >> 8) & 0xF);
    }

    /// The static supporting surface facts. The actor attachment lifetime
    /// (MAIN 0x8012DF34) is not part of this query.
    pub fn support(self: Ground, room: *const Room) ?Surface {
        if (self.surface_plus_one == 0) return null;
        const index = self.surface_plus_one - 1;
        if (index >= room.objects.len) return null;
        const object = room.objects[index];
        return .{ .record = @intCast(index), .level = object.level, .kind = object.kind };
    }

    /// The source attachment path additionally gates on upper-surface bits.
    pub fn attachable(self: Ground) bool {
        return self.surface_plus_one != 0 and self.upper() != 0;
    }
};

pub const Probe = struct {
    id: []const u8,
    kind: []const u8,
    x_cell: u16,
    y_cell: u16,
    level: u8,
    edge_blocked: bool = false,
    terrain: u8 = 0,
    scenery_bits: u16 = 0,
    surface_plus_one: u16 = 0,
    contributor: ?u16 = null,
    overlap_after: u16 = 0,
    solid: u8 = 0,
    walkable: bool = false,
};

pub const Room = struct {
    id: []const u8,
    width_tiles: u16,
    height_tiles: u16,
    width_cells: u16,
    height_cells: u16,
    /// Little-endian u16 tile codes, width_tiles * height_tiles entries.
    tile_codes: []const u8,
    /// Packed collision nibbles indexed by tile code / 2.
    collision: []const u8,
    objects: []const Object,
    planes: []const u8,
    probes: []const Probe,
};

const JsonUnits = struct {
    cell: struct { pixels: u8 },
    tile: struct { cells: u8, pixels: u8 },
    footprint: struct { cells: [2]u8, pixels: [2]u8 },
    level: struct { proven: []const u8 },
};

const JsonObject = struct {
    index: u16,
    x_cell: u16,
    y_cell: u16,
    kind: u8,
    order: u8,
    level: u8,
    width_cells: u8,
    height_cells: u8,
    mask_hex: []const u8,
    mask_sha256: []const u8,
};

const JsonRoom = struct {
    id: []const u8,
    room: u8,
    section: u16,
    width_tiles: u16,
    height_tiles: u16,
    width_cells: u16,
    height_cells: u16,
    tile_codes_hex: []const u8,
    tile_codes_sha256: []const u8,
    collision_hex: []const u8,
    collision_sha256: []const u8,
    masks_sha256: []const u8,
    planes: []const u8,
    objects: []const JsonObject,
    probes: []const Probe,
};

const JsonAsset = struct {
    schema: []const u8,
    units: JsonUnits,
    rooms: []const JsonRoom,
};

pub const Geometry = struct {
    arena: std.heap.ArenaAllocator,
    rooms: []const Room,

    pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !*Geometry {
        if (bytes.len > 8 * 1024 * 1024) return error.AssetTooLarge;
        const self = try allocator.create(Geometry);
        errdefer allocator.destroy(self);
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();

        const json = try std.json.parseFromSliceLeaky(JsonAsset, arena, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        if (!std.mem.eql(u8, json.schema, schema)) return error.UnsupportedSchema;
        if (json.units.cell.pixels != cell_pixels or
            json.units.tile.cells != tile_cells or
            json.units.tile.pixels != cell_pixels * tile_cells or
            json.units.footprint.cells[0] != 2 or json.units.footprint.cells[1] != 2 or
            json.units.footprint.pixels[0] != 2 * cell_pixels or json.units.footprint.pixels[1] != 2 * cell_pixels or
            json.units.level.proven.len != 2 or json.units.level.proven[0] != 0 or json.units.level.proven[1] != 1)
        {
            return error.InvalidUnits;
        }

        const rooms = try arena.alloc(Room, json.rooms.len);
        for (json.rooms, 0..) |source, room_index| {
            if (source.id.len == 0 or source.id.len > 64) return error.InvalidRoom;
            if (source.width_tiles == 0 or source.height_tiles == 0 or
                source.width_tiles > 256 or source.height_tiles > 256) return error.InvalidRoom;
            if (source.width_cells != source.width_tiles * tile_cells or
                source.height_cells != source.height_tiles * tile_cells) return error.InvalidRoom;
            if (source.planes.len == 0) return error.InvalidRoom;

            const tile_bytes = try decodeHex(arena, source.tile_codes_hex);
            if (tile_bytes.len != 2 * @as(usize, source.width_tiles) * source.height_tiles) {
                return error.InvalidTilemap;
            }
            try expectSha256(tile_bytes, source.tile_codes_sha256);
            const collision = try decodeHex(arena, source.collision_hex);
            try expectSha256(collision, source.collision_sha256);

            var max_code: u16 = 0;
            var code_index: usize = 0;
            while (code_index < tile_bytes.len / 2) : (code_index += 1) {
                const code = readCode(tile_bytes, code_index);
                if (code > max_code) max_code = code;
            }
            if (collision.len < @as(usize, max_code) / 2 + 1) return error.InvalidCollision;

            const objects = try arena.alloc(Object, source.objects.len);
            var masks_digest = std.crypto.hash.sha2.Sha256.init(.{});
            for (source.objects, 0..) |object, object_index| {
                if (object.index != object_index) return error.InvalidObject;
                if (object.width_cells == 0 or object.height_cells == 0) return error.InvalidObject;
                if (object.level != 0 and object.level != 1) return error.UnsupportedPlane;
                const mask = try decodeHex(arena, object.mask_hex);
                if (mask.len != @as(usize, object.width_cells) * object.height_cells) {
                    return error.InvalidMaskLength;
                }
                for (mask) |value| if (value > 3) return error.InvalidMaskByte;
                try expectSha256(mask, object.mask_sha256);
                var index_bytes: [2]u8 = .{ @truncate(object_index), @truncate(object_index >> 8) };
                masks_digest.update(&index_bytes);
                masks_digest.update(mask);
                objects[object_index] = .{
                    .x_cell = object.x_cell,
                    .y_cell = object.y_cell,
                    .kind = object.kind,
                    .order = object.order,
                    .level = object.level,
                    .width_cells = object.width_cells,
                    .height_cells = object.height_cells,
                    .mask = mask,
                };
            }
            var digest: [32]u8 = undefined;
            masks_digest.final(&digest);
            const mask_hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, &mask_hex, source.masks_sha256)) return error.HashMismatch;

            for (source.probes) |probe| {
                if (probe.x_cell >= source.width_cells or probe.y_cell >= source.height_cells) {
                    return error.InvalidProbe;
                }
                if (probe.level > 1 and !probe.edge_blocked) return error.InvalidProbe;
            }
            rooms[room_index] = .{
                .id = source.id,
                .width_tiles = source.width_tiles,
                .height_tiles = source.height_tiles,
                .width_cells = source.width_cells,
                .height_cells = source.height_cells,
                .tile_codes = tile_bytes,
                .collision = collision,
                .objects = objects,
                .planes = source.planes,
                .probes = source.probes,
            };
        }
        self.rooms = rooms;
        return self;
    }

    pub fn deinit(self: *Geometry) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self);
    }

    pub fn roomById(self: *const Geometry, id: []const u8) ?*const Room {
        for (self.rooms, 0..) |room, index| {
            if (std.mem.eql(u8, room.id, id)) return &self.rooms[index];
        }
        return null;
    }
};

fn decodeHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

fn expectSha256(bytes: []const u8, expected: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected)) return error.HashMismatch;
}

fn readCode(tile_codes: []const u8, index: usize) u16 {
    const offset = index * 2;
    return @as(u16, tile_codes[offset]) | (@as(u16, tile_codes[offset + 1]) << 8);
}

const footprints = [4][2]u16{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };

pub fn terrainAt(room: *const Room, x_cell: u16, y_cell: u16) !u4 {
    if (x_cell >= room.width_cells or y_cell >= room.height_cells or
        x_cell + 1 >= room.width_cells or y_cell + 1 >= room.height_cells) return error.OutsideRoom;
    var result: u4 = 0;
    for (footprints, 0..) |offset, bit| {
        const cx = x_cell + offset[0];
        const cy = y_cell + offset[1];
        const index = @as(usize, cy / tile_cells) * room.width_tiles + cx / tile_cells;
        const code = readCode(room.tile_codes, index);
        if (@as(usize, code) / 2 >= room.collision.len) return error.InvalidCollision;
        const byte = room.collision[@as(usize, code) / 2];
        const nibble = (byte >> @as(u3, @intCast(4 * ((code + 1) & 1)))) & 0xF;
        const source_bit: u3 = @intCast((cy & 1) * 2 + (cx & 1));
        if ((nibble >> source_bit) & 1 != 0) {
            result |= @as(u4, 1) << @as(u2, @intCast(bit));
        }
    }
    return result;
}

pub fn sceneryAt(room: *const Room, x_cell: u16, y_cell: u16, level: u8) !Scenery {
    if (x_cell >= room.width_cells or y_cell >= room.height_cells or
        x_cell + 1 >= room.width_cells or y_cell + 1 >= room.height_cells) return error.OutsideRoom;
    var bits: u16 = 0;
    var surface_plus_one: u16 = 0;
    var contributor: ?u16 = null;
    for (room.objects, 0..) |object, index| {
        if (object.order == 0 or object.order == 1) continue;
        const query_level: u16 = level;
        if (object.level != query_level and object.level != query_level + 1) continue;
        if (x_cell + 1 < object.x_cell) continue;
        if (@as(u32, x_cell) >= @as(u32, object.x_cell) + object.width_cells) continue;
        if (y_cell + 1 < object.y_cell) continue;
        if (@as(u32, y_cell) >= @as(u32, object.y_cell) + object.height_cells) continue;
        if (bits & 0xFF != 0) continue;
        var local: u16 = 0;
        for (footprints, 0..) |offset, bit| {
            const ox = x_cell + offset[0];
            const oy = y_cell + offset[1];
            if (ox < object.x_cell or oy < object.y_cell) continue;
            const mx = ox - object.x_cell;
            const my = oy - object.y_cell;
            if (mx >= object.width_cells or my >= object.height_cells) continue;
            local |= @as(u16, 0x100) << @as(u4, @intCast(bit));
            const value = object.mask[@as(usize, my) * object.width_cells + mx];
            if (value & 1 != 0) local |= @as(u16, 1) << @as(u4, @intCast(bit));
            if (value & 2 != 0) local |= @as(u16, 2) << @as(u4, @intCast(3 + bit));
        }
        bits = local;
        if (local & 0xFF != 0) contributor = @intCast(index);
        surface_plus_one = if (local & 0xF != 0) 0 else @intCast(index + 1);
    }
    return .{ .bits = bits, .surface_plus_one = surface_plus_one, .contributor = contributor };
}

/// Pure instruction-derived combination (MAIN 0x8012DB9C).
pub fn combine(terrain: u4, scenery: Scenery, level: u8) u4 {
    const low = scenery.low();
    const upper = scenery.upper();
    const coverage = scenery.coverage();
    const all: u4 = 0xF;
    if (level == 0) {
        if (scenery.surface_plus_one != 0 and (upper & (all ^ low)) != 0) {
            return low | (terrain & (all ^ coverage));
        }
        return (low & (all ^ upper)) | terrain;
    }
    if (scenery.surface_plus_one != 0) {
        return (low & coverage) | (terrain & (all ^ coverage));
    }
    return low | (terrain & (all ^ coverage));
}

/// The single collision/query entry point. `level` is the retained source
/// plane (0 = unattached ground, 1 = attached to a plane-1 surface). Levels > 1
/// are unproven and return a blocked result.
pub fn groundAt(room: *const Room, x_cell: u16, y_cell: u16, level: u8) Ground {
    if (x_cell >= room.width_cells or y_cell >= room.height_cells or
        x_cell + 1 >= room.width_cells or y_cell + 1 >= room.height_cells)
    {
        return .{ .edge_blocked = true, .walkable = false, .level = level };
    }
    if (level > 1) {
        return .{ .unsupported_level = true, .level_supported = false, .walkable = false, .level = level };
    }
    const terrain = terrainAt(room, x_cell, y_cell) catch {
        return .{ .edge_blocked = true, .walkable = false, .level = level };
    };
    const scenery = sceneryAt(room, x_cell, y_cell, level) catch {
        return .{ .edge_blocked = true, .walkable = false, .level = level };
    };
    const solid = combine(terrain, scenery, level);
    return .{
        .terrain = terrain,
        .scenery_bits = scenery.bits,
        .surface_plus_one = scenery.surface_plus_one,
        .contributor = scenery.contributor,
        .solid = solid,
        .walkable = solid == 0,
        .level = level,
    };
}
