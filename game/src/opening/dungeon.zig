const std = @import("std");
const events = @import("event_runtime");
const data = @import("opening_assets").dungeon;

pub const schema = "suikoden-opening-dungeon/1";

pub const Room = struct {
    id: []const u8,
    source_room: u8,
    source_section: u8,
    width: i32,
    height: i32,
    walkable: []const u8,

    pub fn canStand(self: Room, x: i32, y: i32) bool {
        if (x < 0 or y < 0 or @mod(x, 8) != 0 or @mod(y, 8) != 0) return false;
        const cell_x = @divTrunc(x, 8);
        const cell_y = @divTrunc(y, 8);
        const width_cells = @divTrunc(self.width, 8);
        const height_cells = @divTrunc(self.height, 8);
        if (cell_x >= width_cells or cell_y >= height_cells) return false;
        return self.walkable[@intCast(cell_y * width_cells + cell_x)] == '1';
    }
};
pub const Entry = struct {
    source_file: []const u8,
    source_room: u8,
    source_entity: u8,
    source_stream: u32,
    selector: []const u8,
    area: u8,
    room: u8,
    resolved_file: []const u8,
    loader_descriptor: u32,
    x_half_cells: u8,
    y_half_cells: u8,
    x: i32,
    y: i32,
    status: []const u8,
};
pub const Coverage = struct {
    geometry_rooms: u8,
    valid_entry_spawns: u8,
    decoded_callback_selectors: u8,
    blocked_callback_selectors: u8,
    completed_dungeon_programs: u8,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    rooms: []const Room,
    entry: Entry,
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

pub fn openPrograms(allocator: std.mem.Allocator) !std.json.Parsed(events.Content) {
    const parsed = try std.json.parseFromSlice(events.Content, allocator, data.programs_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub fn startProgram(content: events.Content, story: *events.StoryState, id: []const u8) !events.Instance {
    return events.start(content, story, id);
}

pub fn roomById(asset: Asset, id: []const u8) ?Room {
    for (asset.rooms) |room| {
        if (std.mem.eql(u8, room.id, id)) return room;
    }
    return null;
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64)
        return error.InvalidDungeonSchema;
    if (asset.rooms.len != 1 or asset.coverage.geometry_rooms != 1 or
        asset.coverage.valid_entry_spawns != 1 or asset.coverage.decoded_callback_selectors != 0 or
        asset.coverage.blocked_callback_selectors != 0 or asset.coverage.completed_dungeon_programs != 14)
        return error.InvalidDungeonCoverage;
    const room = roomById(asset, "vaa_room_0") orelse return error.MissingDungeonRoom;
    if (room.width != 1280 or room.height != 768 or room.walkable.len != 160 * 96)
        return error.InvalidDungeonRoom;
    if (asset.entry.x != 312 or asset.entry.y != 736 or
        !std.mem.eql(u8, asset.entry.resolved_file, "DATA/01_AREA.A/VAA.BIN") or
        !std.mem.eql(u8, asset.entry.status, "source_spawn_walkable") or
        !room.canStand(asset.entry.x, asset.entry.y)) return error.InvalidDungeonEntry;
}

pub fn admitEntry(asset: Asset) !void {
    const room = roomById(asset, "vaa_room_0") orelse return error.MissingDungeonRoom;
    if (!room.canStand(asset.entry.x, asset.entry.y)) return error.SpawnOutsideDecodedRoomGrid;
}
