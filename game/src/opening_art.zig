const std = @import("std");
const field = @import("field");
const audience = @import("opening_audience");
pub const Character = struct { id: []const u8, clips: [4]struct { variant: u8, idle_frame: u8, flags: u8, frames: []const field.Frame } };
pub const Portrait = struct { image: u8, rect: ?field.Rect };
pub const Glyph = struct { character: []const u8, rect: ?field.Rect, advance: i16 };
pub const WindowPiece = struct { role: enum { center, top_left, top_right, bottom_left, bottom_right, top, bottom, left, right }, rect: field.Rect };
pub const SurfaceCell = struct { x: i32, y: i32, height: u8, walkable: bool, support: ?audience.Support };
pub const Room = struct {
    id: []const u8,
    draws: []const field.Draw,
    actors: []const audience.Actor,
    after_audience_actors: []const audience.Actor,
    surfaces: []const SurfaceCell,
    pub fn surfaceAt(self: Room, x: i32, y: i32, height: u8) ?SurfaceCell {
        for (self.surfaces) |cell| if (cell.x == x and cell.y == y and cell.height == height) return cell;
        return null;
    }
    pub fn resolve(self: Room, actor: *audience.Avatar) void {
        const cell = self.surfaceAt(actor.motion.x, actor.motion.y, if (actor.support) |support| support.height else 0) orelse {
            actor.support = null;
            return;
        };
        if (cell.support) |support| {
            actor.support = if (support.height == 0) null else support;
        }
    }
};
pub const Scene = struct {
    schema: []const u8,
    atlas: []const u8,
    rooms: []const Room,
    player_clips: [4]field.Clip,
    characters: []const Character,
    portraits: []const Portrait,
    glyphs: []const Glyph,
    window: []const WindowPiece,

    pub fn roomById(self: Scene, id: []const u8) ?Room {
        for (self.rooms) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }

    pub fn character(self: Scene, id: []const u8) ?Character {
        for (self.characters) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn glyph(self: Scene, character_byte: u8) ?Glyph {
        for (self.glyphs) |entry| if (entry.character[0] == character_byte) return entry;
        return null;
    }
    pub fn validate(self: Scene, rooms: []const field.Room, events: audience.Content) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-opening-scene/3") or !std.mem.eql(u8, self.atlas, "atlas.png")) return error.UnsupportedOpeningScene;
        if (self.rooms.len != rooms.len or self.characters.len > 64 or self.portraits.len > 32 or self.glyphs.len > 128 or self.window.len != 9) return error.InvalidOpeningArt;
        for (self.rooms, 0..) |room, i| {
            const source_room = for (rooms) |candidate| {
                if (std.mem.eql(u8, candidate.id, room.id)) break candidate;
            } else return error.UnknownOpeningRoom;
            if (room.surfaces.len > 2 * source_room.walkable.len) return error.InvalidOpeningSurface;
            for (room.surfaces, 0..) |cell, index| {
                if (cell.height > 1 or cell.x < 0 or cell.y < 0 or cell.x >= source_room.width or cell.y >= source_room.height or @mod(cell.x, 8) != 0 or @mod(cell.y, 8) != 0) return error.InvalidOpeningSurface;
                if (cell.support) |support| if (support.id.len == 0 or support.id.len > 64 or support.height > 1 or support.depth < 1 or support.depth > 256) return error.InvalidOpeningSurface;
                for (room.surfaces[0..index]) |other| if (other.x == cell.x and other.y == cell.y and other.height == cell.height) return error.DuplicateOpeningSurface;
            }
            if (room.draws.len > 4096) return error.InvalidOpeningArt;
            for (self.rooms[0..i]) |other| if (std.mem.eql(u8, other.id, room.id)) return error.DuplicateOpeningRoom;
            for (room.draws) |draw| {
                if (draw.frames.len > 64 or @abs(draw.x) > 4096 or @abs(draw.y) > 4096 or @abs(draw.depth) > 4096) return error.InvalidOpeningArt;
                for (draw.frames) |frame| if (frame.ticks == 0 or frame.ticks > 256) return error.InvalidOpeningArt;
            }
            if (room.actors.len > 64 or room.actors.len != room.after_audience_actors.len) return error.InvalidOpeningArt;
            for (room.actors, room.after_audience_actors) |before, after| if (!std.mem.eql(u8, before.id, after.id)) return error.InvalidOpeningActor;
            for ([_][]const audience.Actor{ room.actors, room.after_audience_actors }) |definitions| for (definitions, 0..) |actor, index| {
                if (self.character(actor.graphic) == null or actor.variant > 3 or actor.motion > 2 or actor.x < 0 or actor.y < 0 or actor.x > 2040 or actor.y > 2040 or @mod(actor.x, 8) != 0 or @mod(actor.y, 8) != 0) return error.InvalidOpeningActor;
                for (definitions[0..index]) |other| if (std.mem.eql(u8, actor.id, other.id)) return error.InvalidOpeningActor;
            };
        }
        for (self.characters, 0..) |entry, i| {
            if (entry.id.len == 0 or entry.id.len > 64) return error.InvalidOpeningArt;
            for (self.characters[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateOpeningCharacter;
            for (entry.clips, 0..) |clip, variant| {
                if (clip.variant != variant or clip.frames.len == 0 or clip.frames.len > 64 or clip.idle_frame >= clip.frames.len) return error.InvalidOpeningArt;
                for (clip.frames) |frame| try validFrame(frame);
            }
        }
        for (self.player_clips, 0..) |clip, variant| {
            if (@backingInt(clip.direction) != variant or clip.frames.len == 0 or clip.frames.len > 64 or clip.idle_frame >= clip.frames.len) return error.InvalidOpeningArt;
            for (clip.frames) |frame| try validFrame(frame);
        }
        for (events.animations) |animation| {
            for (animation.clips, 0..) |clip, variant| {
                const frames = if (std.mem.eql(u8, animation.graphic, "hero")) self.player_clips[variant].frames else (self.character(animation.graphic) orelse return error.MissingOpeningCharacter).clips[variant].frames;
                if (frames.len != clip.ticks.len) return error.OpeningAnimationMismatch;
                for (frames, clip.ticks) |frame, ticks| if (frame.ticks != ticks) return error.OpeningAnimationMismatch;
            }
        }
        for (self.glyphs, 0..) |entry, i| {
            if (entry.character.len != 1 or entry.character[0] < 32 or entry.character[0] > 126 or entry.advance < 1 or entry.advance > 8 or (entry.rect == null) != (entry.character[0] == ' ')) return error.InvalidOpeningGlyph;
            for (self.glyphs[0..i]) |other| if (entry.character[0] == other.character[0]) return error.InvalidOpeningGlyph;
        }
        for (events.texts) |text| for (text.tokens) |token| if (token.text) |bytes| for (bytes) |byte| {
            if (self.glyph(byte) == null) return error.MissingOpeningGlyph;
        };
        for (self.portraits, 0..) |portrait, i| for (self.portraits[0..i]) |other| if (portrait.image == other.image) return error.InvalidOpeningPortrait;
        for (self.window, 0..) |piece, i| for (self.window[0..i]) |other| if (piece.role == other.role) return error.InvalidOpeningWindow;
        try self.validateAtlas(4096, 4096);
    }
    pub fn validateAtlas(self: Scene, width: i32, height: i32) !void {
        if (width <= 0 or height <= 0 or width > 4096 or height > 4096) return error.InvalidOpeningAtlas;
        for (self.rooms) |room| for (room.draws) |draw| {
            try rectangle(draw.rect, width, height);
            for (draw.frames) |frame| try rectangle(frame.rect, width, height);
        };
        for (self.characters) |entry| for (entry.clips) |clip| for (clip.frames) |frame| try rectangle(frame.rect, width, height);
        for (self.player_clips) |clip| for (clip.frames) |frame| try rectangle(frame.rect, width, height);
        for (self.portraits) |portrait| if (portrait.rect) |rect| {
            if (rect.w != 64 or rect.h != 64) return error.InvalidOpeningPortrait;
            try rectangle(rect, width, height);
        };
        for (self.glyphs) |entry| if (entry.rect) |rect| try rectangle(rect, width, height);
        for (self.window) |piece| try rectangle(piece.rect, width, height);
    }
};
fn rectangle(rect: field.Rect, width: i32, height: i32) !void {
    if (rect.x < 0 or rect.y < 0 or rect.w <= 0 or rect.h <= 0 or rect.x >= width or rect.y >= height or rect.w > width - rect.x or rect.h > height - rect.y) return error.InvalidOpeningArtBounds;
}
fn validFrame(frame: field.Frame) !void {
    if (frame.ticks == 0 or frame.ticks > 256 or frame.anchor_x < 0 or frame.anchor_y < 0 or frame.anchor_x > 256 or frame.anchor_y > 256) return error.InvalidOpeningArt;
}
pub fn load(allocator: std.mem.Allocator, bytes: []const u8, rooms: []const field.Room, events: audience.Content) !std.json.Parsed(Scene) {
    if (bytes.len > 4 * 1024 * 1024) return error.OpeningSceneTooLarge;
    const parsed = try std.json.parseFromSlice(Scene, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate(rooms, events);
    return parsed;
}
