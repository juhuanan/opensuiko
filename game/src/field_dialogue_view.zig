const std = @import("std");
const field = @import("field");
const opening = @import("opening");
pub const presentation = opening.presentation;

pub const Art = struct {
    schema: []const u8,
    atlas: []const u8,
    content_sha256: []const u8,
    atlas_sha256: []const u8,
    glyphs: []const opening.art.Glyph,
    window: []const opening.art.WindowPiece,
    portraits: []const struct { image: u8, id: []const u8, rect: ?field.Rect, plane_sha256: []const u8, palette_sha256: []const u8 },
    followers: []const struct { character: u8, id: []const u8, content_sha256: []const u8, clips: [4]field.Clip } = &.{},

    pub fn glyph(self: Art, byte: u8) ?opening.art.Glyph {
        for (self.glyphs) |entry| if (entry.character.len == 1 and entry.character[0] == byte) return entry;
        return null;
    }
    pub fn validate(self: Art, data: anytype, width: i32, height: i32) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-field-dialogue-art/1") or !std.mem.eql(u8, self.atlas, "atlas.png") or !std.mem.eql(u8, self.content_sha256, data.content_sha256)) return error.InvalidFieldDialogueArt;
        if (self.atlas_sha256.len != 64) return error.InvalidFieldDialogueArt;
        if (width <= 0 or height <= 0 or width > 4096 or height > 4096 or self.glyphs.len > 128 or self.window.len != 9 or self.portraits.len != data.images.len) return error.InvalidFieldDialogueArt;
        for (self.glyphs, 0..) |entry, i| {
            if (entry.character.len != 1 or entry.advance <= 0 or entry.advance > 8) return error.InvalidFieldDialogueArt;
            for (self.glyphs[0..i]) |other| if (std.mem.eql(u8, entry.character, other.character)) return error.InvalidFieldDialogueArt;
            if (entry.rect) |rect| {
                if (rect.w != 8 or rect.h != 12) return error.InvalidFieldDialogueArt;
                try bounds(rect, width, height);
            }
        }
        for (self.window, 0..) |piece, i| {
            for (self.window[0..i]) |other| if (piece.role == other.role) return error.InvalidFieldDialogueArt;
            if (piece.rect.w != 12 or piece.rect.h != 12) return error.InvalidFieldDialogueArt;
            try bounds(piece.rect, width, height);
        }
        for (self.portraits, data.images, 0..) |portrait, resource, i| {
            if (portrait.image != i or !std.mem.eql(u8, portrait.id, resource.id) or !std.mem.eql(u8, portrait.plane_sha256, resource.plane_sha256) or !std.mem.eql(u8, portrait.palette_sha256, resource.palette_sha256)) return error.InvalidFieldDialogueArt;
            const rect = portrait.rect orelse return error.InvalidFieldDialogueArt;
            if (rect.w != resource.width or rect.h != resource.height) return error.InvalidFieldDialogueArt;
            try bounds(rect, width, height);
        }
        for (data.texts) |text| for (text.tokens) |token| if (token.text) |bytes| for (bytes) |byte| {
            if (self.glyph(byte) == null) return error.MissingOpeningGlyph;
        };
    }
    pub fn validateFollowers(self: Art, graphics: anytype, width: i32, height: i32) !void {
        if (self.followers.len == 0) return;
        if (graphics == null or self.followers.len != graphics.?.resources.len) return error.InvalidFieldPartyGraphics;
        for (self.followers, 0..) |actor, i| {
            for (self.followers[0..i]) |prior| if (prior.character == actor.character) return error.InvalidFieldPartyGraphics;
            const source = graphics.?.resource(actor.character) orelse return error.InvalidFieldPartyGraphics;
            if (actor.character != source.character or !std.mem.eql(u8, actor.id, source.id) or !std.mem.eql(u8, actor.content_sha256, graphics.?.content_sha256)) return error.InvalidFieldPartyGraphics;
            for (actor.clips, source.clips) |clip, animation| {
                if (clip.frames.len != animation.ticks.len) return error.InvalidFieldPartyGraphics;
                for (clip.frames, animation.ticks, animation.bounds) |frame, ticks, size| {
                    if (frame.ticks != ticks or frame.rect.w != size.width or frame.rect.h != size.height or frame.anchor_x < 0 or frame.anchor_x > 128 or frame.anchor_y < 0 or frame.anchor_y > 128) return error.InvalidFieldPartyGraphics;
                    try bounds(frame.rect, width, height);
                }
            }
        }
    }
};
fn bounds(rect: field.Rect, width: i32, height: i32) !void {
    if (rect.x < 0 or rect.y < 0 or rect.w <= 0 or rect.h <= 0 or rect.x >= width or rect.y >= height or rect.w > width - rect.x or rect.h > height - rect.y) return error.InvalidFieldDialogueArt;
}
pub const FollowerDraw = struct { character: u8, rect: field.Rect, x: f32, y: f32, depth: f32, variant: u2, frame: u8 };
pub fn hero(scene: anytype, package: field.Package, camera: field.CameraOffset) !?FollowerDraw {
    if (!scene.busy()) return null;
    const sprite = scene.hero_sprite orelse return error.InvalidFieldHeroAnimation;
    const clip = package.player_clips[sprite.variant];
    if (sprite.emitted_frame >= clip.frames.len) return error.InvalidFieldHeroAnimation;
    const frame = clip.frames[sprite.emitted_frame];
    return .{ .character = 8, .rect = frame.rect, .x = camera.x + @as(f32, @floatFromInt(sprite.emitted_x - frame.anchor_x)), .y = camera.y + @as(f32, @floatFromInt(sprite.emitted_y - frame.anchor_y)), .depth = @as(f32, @floatFromInt(sprite.emitted_y)) / 8, .variant = sprite.variant, .frame = sprite.emitted_frame };
}
pub const Followers = struct {
    draws: [5]FollowerDraw = undefined,
    length: usize = 0,
    unsupported: [5]u8 = undefined,
    unsupported_count: usize = 0,
};
pub fn followers(scene: anytype, art: ?Art, camera: field.CameraOffset) !Followers {
    var result: Followers = .{};
    const queue = scene.party_queue orelse return result;
    for (queue.followers[0..queue.count]) |slot| {
        const follower = slot.?;
        const sprite = follower.sprite orelse {
            result.unsupported[result.unsupported_count] = follower.character;
            result.unsupported_count += 1;
            continue;
        };
        const resources = art orelse return error.MissingFieldPartyGraphics;
        const actor = for (resources.followers) |resource| {
            if (resource.character == follower.character) break resource;
        } else return error.MissingFieldPartyGraphics;
        const clip = actor.clips[sprite.variant];
        if (sprite.emitted_frame >= clip.frames.len) return error.InvalidFieldPartyGraphics;
        const frame = clip.frames[sprite.emitted_frame];
        result.draws[result.length] = .{ .character = follower.character, .rect = frame.rect, .x = camera.x + @as(f32, @floatFromInt(sprite.emitted_x - frame.anchor_x)), .y = camera.y + @as(f32, @floatFromInt(sprite.emitted_y - frame.anchor_y)), .depth = @as(f32, @floatFromInt(sprite.emitted_y)) / 8, .variant = sprite.variant, .frame = sprite.emitted_frame };
        result.length += 1;
    }
    return result;
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Art) {
    if (bytes.len > 128 * 1024) return error.InvalidFieldDialogueArt;
    return std.json.parseFromSlice(Art, allocator, bytes, .{ .allocate = .alloc_always });
}

// shortcut: project the existing prototype field camera into the source UI viewport; canonical field camera integration is separate.
pub fn compose(art: anytype, scene: anytype, data: anytype, camera: field.CameraOffset, list: *presentation.List, choice_box: ?u8) !void {
    list.length = 0;
    for (scene.boxes, 0..) |source, slot| {
        if (source.phase == .closed) continue;
        const anchor = source.anchor orelse if (source.fixed != null) field.Point{ .x = 0, .y = 0 } else return error.InvalidFieldDialogueArt;
        var box: opening.audience.Box = .{
            .phase = source.phase,
            .transition = source.transition,
            .origin = .{ .x = @divTrunc((anchor.x + @as(i32, @intFromFloat(camera.x))) * 5, 8), .y = @divTrunc((anchor.y + @as(i32, @intFromFloat(camera.y)) - 24) * 5, 8) },
            .image = source.image,
        };
        var name: [4096]u8 = undefined;
        var name_len: usize = 0;
        if (source.speaker) |speaker| {
            if (speaker >= data.texts.len) return error.InvalidFieldDialogueArt;
            for (data.texts[speaker].tokens, 0..) |token, i| {
                if (token.kind == .newline and i + 1 == data.texts[speaker].tokens.len) continue;
                if (token.kind != .glyph or token.text == null) return error.InvalidFieldDialogueArt;
                const bytes = token.text.?;
                if (bytes.len > name.len - name_len) return error.InvalidFieldDialogueArt;
                @memcpy(name[name_len..][0..bytes.len], bytes);
                name_len += bytes.len;
            }
        }
        box.name = name[0..name_len];
        box.prefix_visible = @intCast(name_len);
        if (scene.text_job) |job| if (job.box == slot) {
            switch (job.kind) {
                .prefix => box.prefix_visible = job.state.length,
                .body_staged => {},
                .body, .body_done => box.text = job.state,
            }
        };
        const portrait = if (source.image) |image| blk: {
            if (image >= data.images.len) return error.InvalidFieldDialogueArt;
            break :blk data.images[image].atlas_rect;
        } else null;
        const selected: ?u8 = if (choice_box != null and choice_box.? == slot) scene.instance.?.execution.choice else null;
        try presentation.dialogue(list, art, box, slot, selected, portrait, source.fixed);
        if (selected) |row| {
            // shortcut: settled highlight until the room cursor motion is qualified.
            const y: i32 = (if (box.text.page == 0 and name_len != 0) @as(i32, 168) else 156) + @as(i32, row) * 12;
            try list.selection(.{ .row = row, .y = y, .moving = false, .outline_only = false });
        }
    }
}
