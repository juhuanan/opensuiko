//! Bind the canonical opening rooms into the playable journey package.
//!
//! The journey bundle is the runtime owner; this module only adds the seven
//! accepted opening rooms and starts the package on the palace room.  It does
//! not create a second runtime session or save path.

const std = @import("std");
const field = @import("field");
const launch = @import("opening_launch");

pub const start_room = "vaa_room_2";
pub const start_x = 512;
pub const start_y = 584;

pub const Merge = struct {
    loaded: launch.Loaded,
    rooms: *launch.Rooms,
    package: field.Package,
    palace: launch.PalaceContent,
    merged: []field.Room,
    exits: []field.Exit,
    pages: []u8,
    dungeon_page: []u8,
    greeting_page: []u8,
    page_refs: [][]const u8,
    event_refs: [][]const u8,
    npcs: []field.Npc,
    events: []field.Event,
    ui: []u8,

    pub fn deinit(self: *Merge, allocator: std.mem.Allocator) void {
        allocator.free(self.exits);
        allocator.free(self.pages);
        allocator.free(self.dungeon_page);
        allocator.free(self.greeting_page);
        allocator.free(self.page_refs);
        allocator.free(self.event_refs);
        allocator.free(self.npcs);
        allocator.free(self.events);
        allocator.free(self.ui);
        allocator.free(self.merged);
        allocator.destroy(self.rooms);
        self.loaded.deinit();
    }
};

pub fn bind(allocator: std.mem.Allocator, scene_bytes: []const u8, base: field.Package) !Merge {
    var loaded = try launch.load(allocator, scene_bytes);
    errdefer loaded.deinit();
    const rooms = try allocator.create(launch.Rooms);
    errdefer allocator.destroy(rooms);
    const palace = try launch.bindPalace(&loaded, rooms);
    const route_specs = [_]struct { room: u8, entity: u8 }{
        .{ .room = 0, .entity = 15 },
        .{ .room = 0, .entity = 16 },
        .{ .room = 1, .entity = 1 },
        .{ .room = 10, .entity = 0 },
        .{ .room = 10, .entity = 1 },
    };
    const exits = try allocator.alloc(field.Exit, route_specs.len);
    errdefer allocator.free(exits);
    for (route_specs, 0..) |spec, i| {
        const route = palace.destination.route(spec.room, spec.entity) orelse return error.MissingPalaceExit;
        const guard = route.qualified_guard orelse return error.MissingPalaceExitGuard;
        exits[i] = .{
            .x = @as(i32, guard.x_min) * 8,
            .y = @as(i32, guard.y_min) * 8,
            .w = @as(i32, guard.x_max - guard.x_min + 1) * 8,
            .h = @as(i32, guard.y_max - guard.y_min + 1) * 8,
            .room = route.destination,
            .spawn_x = route.x,
            .spawn_y = route.y,
        };
    }
    var page: std.ArrayList(u8) = .empty;
    errdefer page.deinit(allocator);
    const text = loaded.script.value.text("room_text_0") orelse return error.MissingOpeningText;
    for (text.tokens) |token| switch (token.kind) {
        .glyph => if (token.text) |glyph| for (glyph) |byte| {
            if (byte < 0x20 or byte > 0x7e) continue;
            try page.append(allocator, byte);
        },
        .newline, .page => try page.append(allocator, '\n'),
        .player_name => try page.appendSlice(allocator, "Hero"),
        .pace, .countdown => {},
    };
    const pages = try page.toOwnedSlice(allocator);
    errdefer allocator.free(pages);
    const dungeon_page = try allocator.dupe(u8, "They say the real reason for General Teo's trip is\nput down the rebels.");
    errdefer allocator.free(dungeon_page);
    const greeting_page = try allocator.dupe(u8, "Master , how are you? Have you gotten used to your new job?");
    errdefer allocator.free(greeting_page);
    const page_refs = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(page_refs);
    page_refs[0] = pages;
    const npcs = try allocator.alloc(field.Npc, 1);
    errdefer allocator.free(npcs);
    npcs[0] = .{ .id = "teo_opening", .name = "Teo", .x = 400, .y = 280, .pages = page_refs[0..1] };
    const event_refs = try allocator.alloc([]const u8, 2);
    errdefer allocator.free(event_refs);
    event_refs[0] = dungeon_page;
    event_refs[1] = greeting_page;
    const events = try allocator.alloc(field.Event, 2);
    errdefer allocator.free(events);
    events[0] = .{ .id = "vaa_r00_e00_ordinary", .name = "Palace rumor", .x = 344, .y = 392, .w = 16, .h = 16, .flag = .vaa_dungeon_rumor, .pages = event_refs[0..1] };
    events[1] = .{ .id = "vaa_r00_e01_ordinary", .name = "Palace greeting", .x = 280, .y = 624, .w = 16, .h = 16, .flag = .vaa_dungeon_greeting, .pages = event_refs[1..2] };
    const RoomBinding = struct {
        id: []const u8,
        exit_start: u8 = 0,
        exit_count: u8 = 0,
        event_start: u8 = 0,
        event_count: u8 = 0,
        npc_start: u8 = 0,
        npc_count: u8 = 0,
    };
    const room_bindings = [_]RoomBinding{
        .{ .id = "vaa_room_0", .exit_start = 0, .exit_count = 2, .event_start = 0, .event_count = 2 },
        .{ .id = "vaa_room_1", .exit_start = 2, .exit_count = 1 },
        .{ .id = "vaa_room_10", .exit_start = 3, .exit_count = 2 },
        .{ .id = "vaa_room_2", .npc_start = 0, .npc_count = 1 },
    };
    for (rooms) |*room| {
        if (loaded.scene.value.roomById(room.id)) |scene_room| room.draws = scene_room.draws;
        for (room_bindings) |binding| {
            if (!std.mem.eql(u8, room.id, binding.id)) continue;
            if (binding.exit_count != 0) room.exits = exits[binding.exit_start..][0..binding.exit_count];
            if (binding.event_count != 0) room.events = events[binding.event_start..][0..binding.event_count];
            if (binding.npc_count != 0) room.npcs = npcs[binding.npc_start..][0..binding.npc_count];
        }
    }
    const merged = try allocator.alloc(field.Room, base.rooms.len + palace.package.rooms.len);
    errdefer allocator.free(merged);
    @memcpy(merged[0..base.rooms.len], base.rooms);
    @memcpy(merged[base.rooms.len..], palace.package.rooms);
    var package = base;
    package.rooms = merged;
    if (package.player_clips.len == 0) package.player_clips = palace.package.player_clips;
    package.start_room = start_room;
    package.start_x = start_x;
    package.start_y = start_y;
    const ui = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "suikoden-ui-font/1",
        .glyphs = loaded.scene.value.glyphs,
        .window = loaded.scene.value.window,
    }, .{});
    errdefer allocator.free(ui);
    return .{ .loaded = loaded, .rooms = rooms, .package = package, .palace = palace, .merged = merged, .exits = exits, .pages = pages, .dungeon_page = dungeon_page, .greeting_page = greeting_page, .page_refs = page_refs, .event_refs = event_refs, .npcs = npcs, .events = events, .ui = ui };
}
