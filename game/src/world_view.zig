const std = @import("std");
const world = @import("world");
const field = @import("field");
pub const json = @import("world_art_data").json;
pub const json_c = @import("world_art_data").json_c;
pub const Frame = struct { pose: u8, ticks: u16 };
pub const crossing_path = "travel/crossing.json";
pub const Data = struct {
    schema: []const u8,
    region: []const u8,
    atlas: []const u8,
    atlas_width: i32,
    atlas_height: i32,
    cells: []const u16,
    tiles: []const field.Rect,
    poses: []const field.Rect,
    clips: [4][]const Frame,
    direction_clips: [4]u8,
    initial_clip: u8,
    initial_water_tile: u16,
    hero_x: i32,
    hero_y: i32,
    anchors: []const field.Point = &.{},
    atlas_sha256: ?[]const u8 = null,

    pub fn isCrossing(self: Data) bool {
        return std.mem.eql(u8, self.schema, "suikoden-crossing-art/1");
    }
    pub fn validate(self: Data) !void {
        const crossing = self.isCrossing();
        if (crossing) {
            if (!std.mem.eql(u8, self.region, "region_j") or !std.mem.eql(u8, self.atlas, "travel/crossing.png") or self.atlas_height != 352 or self.poses.len != 12 or self.anchors.len != 12) return error.InvalidWorldArt;
            const hash = self.atlas_sha256 orelse return error.InvalidWorldArt;
            if (hash.len != 64) return error.InvalidWorldArt;
            for (hash) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return error.InvalidWorldArt;
            for (self.anchors, 0..) |anchor, i| if (anchor.x != @as(i32, if (i < 6) 0 else 4) or anchor.y != 0) return error.InvalidWorldArt;
        } else {
            if (!std.mem.eql(u8, self.schema, "suikoden-world-art/1") or (!std.mem.eql(u8, self.region, "region_b") and !std.mem.eql(u8, self.region, "region_c"))) return error.UnsupportedWorldArt;
            if (!std.mem.eql(u8, self.atlas, "world.png") or self.atlas_height != 368 or self.poses.len != 36) return error.InvalidWorldArt;
        }
        if (self.atlas_width != 256 or self.cells.len != 19200 or self.tiles.len != 320) return error.InvalidWorldArt;
        for (self.cells) |tile| if (tile >= self.tiles.len) return error.InvalidWorldTile;
        for ([_][]const field.Rect{ self.tiles, self.poses }) |rectangles| for (rectangles) |rect| {
            if (rect.x < 0 or rect.y < 0 or (rect.w != 16 and !(crossing and rect.w == 24)) or rect.h != 16 or rect.x > self.atlas_width - rect.w or rect.y > self.atlas_height - 16) return error.InvalidWorldAtlas;
        };
        for (self.tiles) |rect| if (rect.w != 16) return error.InvalidWorldAtlas;
        for (self.clips) |clip| {
            if (clip.len != (if (crossing) @as(usize, 4) else 12)) return error.InvalidWorldClip;
            for (clip) |frame| if (frame.pose >= self.poses.len or frame.ticks == 0 or frame.ticks > 256) return error.InvalidWorldClip;
        }
        if (!std.mem.eql(u8, &self.direction_clips, &.{ 1, 3, 0, 2 }) or self.initial_clip != 0 or self.initial_water_tile != 10 or self.hero_x != 160 or self.hero_y != 128) return error.InvalidWorldArt;
    }
    pub fn validateAtlas(self: Data, width: i32, height: i32) !void {
        if (width != self.atlas_width or height != self.atlas_height) return error.InvalidWorldAtlas;
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Data) {
    if (bytes.len > 256 * 1024) return error.InvalidWorldArt;
    const parsed = try std.json.parseFromSlice(Data, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
pub const State = struct {
    cells: [19200]u16,
    counter: i32 = 1,
    water_tile: u16,
    clip: u8,
    frame: u8 = 0,
    remaining: u16,
    pub fn init(data: Data) State {
        var result: State = .{ .cells = undefined, .water_tile = data.initial_water_tile, .clip = data.initial_clip, .remaining = data.clips[data.initial_clip][0].ticks };
        @memcpy(&result.cells, data.cells);
        return result;
    }
    pub fn reload(self: *State, data: Data) void {
        const water = self.water_tile;
        self.* = init(data);
        self.water_tile = water;
    }
    fn advance(self: *State, data: Data) void {
        self.remaining -= 1;
        if (self.remaining == 0) {
            self.frame = @intCast((@as(usize, self.frame) + 1) % data.clips[self.clip].len);
            self.remaining = data.clips[self.clip][self.frame].ticks;
        }
    }
    pub fn step(self: *State, data: Data, before: world.State, after: world.State, input: world.Input) !void {
        if (before.mode != .world or before.boat != data.isCrossing() or before.scripted) return error.UnsupportedWorldViewMode;
        self.counter +%= 1;
        if (before.ready()) {
            if (input.direction) |direction| if (world.requestedAxisAllowed(before.camera, direction)) {
                const clip = data.direction_clips[@backingInt(after.heading)];
                if (self.clip != clip) {
                    self.clip = clip;
                    self.frame = 0;
                    self.remaining = data.clips[clip][0].ticks;
                }
            };
            self.advance(data);
        }
        if (before.remaining != 0 or after.remaining != 0) self.advance(data);
        self.animateWater(after.camera);
    }
    pub fn stepScripted(self: *State, data: Data, before: world.State, after: world.State) !void {
        if (!data.isCrossing() or before.mode != .world or !before.boat or !before.scripted) return error.InvalidWorldView;
        self.counter +%= 1;
        if (before.ready() and after.remaining != 0) {
            const clip = data.direction_clips[@backingInt(after.heading)];
            if (self.clip != clip) {
                self.clip = clip;
                self.frame = 0;
                self.remaining = data.clips[clip][0].ticks;
            }
        }
        if (before.remaining != 0 or after.remaining != 0) self.advance(data);
        self.animateWater(after.camera);
    }
    fn animateWater(self: *State, camera: world.Point) void {
        if (@rem(self.counter, 30) == 0) {
            self.water_tile = if (self.water_tile == 10) 20 else 10;
            for (0..15) |y| for (0..20) |x| {
                // The source sweep is linear, unlike the wrapped draw lookup.
                const index = (@as(i64, camera.y) + @as(i64, @intCast(y))) * 160 + camera.x + @as(i64, @intCast(x));
                if (index < 0 or index >= self.cells.len) continue;
                const tile = &self.cells[@intCast(index)];
                if (tile.* >= 1 and tile.* <= 10) tile.* += 10 else if (tile.* >= 11 and tile.* <= 20) tile.* -= 10;
            };
        }
    }
};
pub const Sprite = struct { rect: field.Rect, x: i32, y: i32 };
pub const List = struct {
    sprites: [673]Sprite = undefined,
    length: usize = 0,
    fn add(self: *List, rect: field.Rect, x: i32, y: i32) void {
        self.sprites[self.length] = .{ .rect = rect, .x = x, .y = y };
        self.length += 1;
    }
};
pub fn compose(data: Data, travel: world.State, state: *const State, list: *List) !void {
    const crossing = data.isCrossing();
    if ((if (crossing) !travel.boat else (travel.boat or travel.scripted)) or state.clip >= 4 or state.frame >= data.clips[state.clip].len or (state.water_tile != 10 and state.water_tile != 20)) return error.InvalidWorldView;
    list.length = 0;
    const origin = travel.originPixels();
    const offset_x = @mod(origin.x, 16);
    const offset_y = @mod(origin.y, 16);
    const columns: usize = if (offset_x == 0) 20 else 21;
    const rows: usize = if (offset_y == 0) 15 else 16;
    for (0..2) |layer| for (0..rows) |y| for (0..columns) |x| {
        const column = @mod(@divFloor(origin.x, 16) + @as(i32, @intCast(x)), 160);
        const row = @mod(@divFloor(origin.y, 16) + @as(i32, @intCast(y)), 120);
        const tile = if (layer == 0) state.water_tile else state.cells[@intCast(row * 160 + column)];
        list.add(data.tiles[tile], @as(i32, @intCast(x)) * 16 - offset_x, @as(i32, @intCast(y)) * 16 - offset_y);
    };
    const pose = data.clips[state.clip][state.frame].pose;
    const anchor = if (crossing) data.anchors[pose] else field.Point{ .x = 0, .y = 0 };
    list.add(data.poses[pose], data.hero_x - anchor.x, data.hero_y - anchor.y);
}
