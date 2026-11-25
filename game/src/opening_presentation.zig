const std = @import("std");
const field = @import("field");
const opening = @import("opening.zig");
pub const Sprite = struct { rect: field.Rect, x: i32, y: i32, width: i32, height: i32, mirror: bool = false, color: [3]u8 = .{ 255, 255, 255 } };
pub const Line = struct { x1: i32, y1: i32, x2: i32, y2: i32, red: u8 = 128, green: u8 = 128, blue: u8 = 128 };
pub const AdditiveFill = struct { rect: field.Rect, red: u8, green: u8, blue: u8 };
pub const SolidFill = struct { rect: field.Rect, color: [3]u8 };
const WindowAppearance = field.game_state.event_runtime.WindowAppearance;
pub const Piece = union(enum) { sprite: Sprite, line: Line, additive_fill: AdditiveFill, solid_fill: SolidFill, styled_window: struct { rect: field.Rect, appearance: WindowAppearance } };
pub const List = struct {
    pieces: [8192]Piece = undefined,
    length: usize = 0,
    appearance: WindowAppearance = .{},
    fn add(self: *List, rect: field.Rect, x: i32, y: i32, width: i32, height: i32, mirror: bool) !void {
        if (self.length == self.pieces.len) return error.OpeningDrawListFull;
        if (width <= 0 or height <= 0) return error.InvalidOpeningDraw;
        self.pieces[self.length] = .{ .sprite = .{ .rect = rect, .x = x, .y = y, .width = width, .height = height, .mirror = mirror } };
        self.length += 1;
    }
    fn sprite(self: *List, rect: field.Rect, x: i32, y: i32) !void {
        try self.add(rect, x, y, rect.w, rect.h, false);
    }
    fn line(self: *List, x1: i32, y1: i32, x2: i32, y2: i32) !void {
        if (self.length == self.pieces.len) return error.OpeningDrawListFull;
        self.pieces[self.length] = .{ .line = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 } };
        self.length += 1;
    }
    fn coloredLine(self: *List, x1: i32, y1: i32, x2: i32, y2: i32, color: u8) !void {
        try self.line(x1, y1, x2, y2);
        self.pieces[self.length - 1].line.red = color;
        self.pieces[self.length - 1].line.green = color;
        self.pieces[self.length - 1].line.blue = color;
    }
    pub fn outlineRect(self: *List, rect: field.Rect) !void {
        try self.line(rect.x, rect.y, rect.x + rect.w, rect.y);
        try self.line(rect.x + rect.w, rect.y, rect.x + rect.w, rect.y + rect.h);
        try self.line(rect.x + rect.w, rect.y + rect.h, rect.x, rect.y + rect.h);
        try self.line(rect.x, rect.y + rect.h, rect.x, rect.y);
    }
    pub fn selection(self: *List, state: opening.audience.Selection) !void {
        try self.selectionRect(.{ .x = 36, .y = state.y, .w = 240, .h = 12 }, state.outline_only);
    }
    pub fn selectionRect(self: *List, rect: field.Rect, outline_only: bool) !void {
        if (!outline_only) {
            if (self.length == self.pieces.len) return error.OpeningDrawListFull;
            self.pieces[self.length] = .{ .additive_fill = .{ .rect = rect, .red = 32, .green = 48, .blue = 64 } };
            self.length += 1;
        }
        const light: u8 = if (outline_only) 128 else 255;
        const dark: u8 = if (outline_only) 128 else 32;
        try self.coloredLine(rect.x - 1, rect.y - 1, rect.x + rect.w + 1, rect.y - 1, light);
        try self.coloredLine(rect.x - 1, rect.y + rect.h + 1, rect.x - 1, rect.y - 1, light);
        try self.coloredLine(rect.x + rect.w + 1, rect.y + rect.h + 1, rect.x - 1, rect.y + rect.h + 1, dark);
        try self.coloredLine(rect.x + rect.w + 1, rect.y - 1, rect.x + rect.w + 1, rect.y + rect.h + 1, dark);
    }
};
const Ordered = struct { depth: i32, order: usize, piece: Sprite };
fn less(_: void, a: Ordered, b: Ordered) bool {
    return if (a.depth == b.depth) a.order < b.order else a.depth < b.depth;
}

pub fn glyphs(list: *List, scene: anytype, bytes: []const u8, x: i32, y: i32, selected_row: ?u8) !void {
    var pen_x = x;
    var pen_y = y;
    var advance: i32 = 8;
    var row: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') {
            pen_x = x;
            pen_y += 12;
            row += 1;
            continue;
        }
        const glyph = scene.glyph(byte) orelse return error.MissingOpeningGlyph;
        if (glyph.rect) |rect| {
            try list.sprite(rect, pen_x, pen_y - @as(i32, @intFromBool(selected_row != null and row == selected_row.?)));
            advance = glyph.advance;
        }
        pen_x += advance;
    }
}

pub fn compose(live: *const opening.Live, scene: opening.art.Scene, list: *List) !void {
    list.length = 0;
    list.appearance = .{};
    const room = scene.roomById(live.seed.room) orelse return error.UnknownOpeningRoom;
    var ordered: [4163]Ordered = undefined;
    var length: usize = 0;
    const camera = live.stage.camera;
    for (room.draws, 0..) |draw, i| {
        const sampled = draw.sample(live.elapsed);
        ordered[length] = .{ .depth = draw.depth, .order = i, .piece = .{ .rect = sampled.rect, .x = sampled.x - camera.x, .y = sampled.y - camera.y, .width = sampled.rect.w, .height = sampled.rect.h } };
        length += 1;
    }
    for (0..live.stage.actor_count + @as(usize, @intFromBool(live.stage.follower != null))) |i| {
        const actor = if (i == live.stage.actor_count) live.stage.follower.?.actor else live.stage.actors[i];
        if (!actor.attached or actor.released) continue;
        const pose = actor.drawPose();
        if (!pose.visible) continue;
        const frames = if (std.mem.eql(u8, actor.graphic, "hero")) scene.player_clips[pose.variant].frames else scene.character(actor.graphic).?.clips[pose.variant].frames;
        if (pose.frame >= frames.len) return error.InvalidOpeningAnimationFrame;
        const frame = frames[pose.frame];
        ordered[length] = .{ .depth = if (actor.support) |support| support.depth else @divTrunc(actor.motion.y, 8), .order = room.draws.len + i, .piece = .{ .rect = frame.rect, .x = pose.x - frame.anchor_x - camera.x, .y = pose.y - frame.anchor_y - camera.y, .width = frame.rect.w, .height = frame.rect.h } };
        length += 1;
    }
    std.mem.sort(Ordered, ordered[0..length], {}, less);
    for (ordered[0..length]) |item| try list.add(item.piece.rect, item.piece.x, item.piece.y, item.piece.width, item.piece.height, false);
    for (live.stage.boxes, 0..) |box, slot| {
        const selected: ?u1 = if (slot == 1 and live.stage.choice_open and live.stage.selection != null and !live.stage.selection.?.outline_only) live.stage.choice else null;
        try dialogue(list, scene, box, slot, selected, null, null);
    }
    if (live.stage.choice_open) if (live.stage.selection) |state| try list.selection(state);
}

pub fn dialogue(list: *List, scene: anytype, box: opening.audience.Box, slot: usize, selected: ?u8, portrait_rect: ?field.Rect, fixed: ?field.Rect) !void {
    if (box.phase == .closed) return;
    const outline: ?field.Rect = if (fixed) |rect| blk: {
        if (box.phase != .opening and box.phase != .closing) break :blk null;
        const from = [4]i32{ 0, 0, 0, 0 };
        const to = [4]i32{ rect.x - 160, rect.y - 120, rect.w, rect.h };
        var values: [4]i32 = undefined;
        for (from, to, 0..) |start, end, i| {
            values[i] = @divTrunc((if (box.phase == .opening) start else end) * @as(i32, box.transition) + (if (box.phase == .opening) end else start) * (20 - @as(i32, box.transition)), 20);
        }
        break :blk .{ .x = values[0] + 160, .y = values[1] + 120, .w = values[2], .h = values[3] };
    } else if (box.outline()) |rect| .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h } else null;
    if (outline) |rect| {
        try list.line(rect.x, rect.y, rect.x + rect.w, rect.y);
        try list.line(rect.x + rect.w, rect.y, rect.x + rect.w, rect.y + rect.h);
        try list.line(rect.x + rect.w, rect.y + rect.h, rect.x, rect.y + rect.h);
        try list.line(rect.x, rect.y + rect.h, rect.x, rect.y);
        return;
    }
    const content_rect = fixed orelse field.Rect{ .x = 36, .y = 158, .w = 240, .h = 60 };
    try window(list, scene, content_rect);
    if (portrait_rect) |rect| {
        try list.add(rect, if (slot == 0) 24 else 224, 86, 64, 64, slot == 0);
    } else if (comptime @hasField(@TypeOf(scene), "portraits")) if (box.image) |image| for (scene.portraits) |portrait| {
        if (portrait.image == image) if (portrait.rect) |rect| try list.add(rect, if (slot == 0) 24 else 224, 86, 64, 64, slot == 0);
    };
    if (box.text.page == 0 and box.prefix_visible > 0) try glyphs(list, scene, box.name[0..@min(box.name.len, box.prefix_visible)], content_rect.x, content_rect.y, null);
    try glyphs(list, scene, box.text.visible(), content_rect.x, content_rect.y + @as(i32, if (box.text.page == 0 and box.name.len != 0) 12 else 0), selected);
}

pub fn window(list: *List, scene: anytype, rect: field.Rect) !void {
    if (!list.appearance.isDefault()) {
        if (list.length == list.pieces.len) return error.OpeningDrawListFull;
        list.pieces[list.length] = .{ .styled_window = .{ .rect = .{ .x = rect.x - 8, .y = rect.y - 8, .w = rect.w + 16, .h = rect.h + 16 }, .appearance = list.appearance } };
        list.length += 1;
        return;
    }
    for (scene.window) |piece| {
        const x: i32 = switch (piece.role) {
            .top_right, .bottom_right, .right => rect.x + rect.w - 4,
            .top_left, .bottom_left, .left => rect.x - 8,
            else => rect.x + 4,
        };
        const y: i32 = switch (piece.role) {
            .bottom_left, .bottom_right, .bottom => rect.y + rect.h - 4,
            .top_left, .top_right, .top => rect.y - 8,
            else => rect.y + 4,
        };
        const width: i32 = switch (piece.role) {
            .center, .top, .bottom => rect.w - 8,
            else => 12,
        };
        const height: i32 = switch (piece.role) {
            .center, .left, .right => rect.h - 8,
            else => 12,
        };
        try list.add(piece.rect, x, y, width, height, false);
    }
}
