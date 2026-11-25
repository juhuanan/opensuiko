const std = @import("std");
const rl = @import("raylib");
const ui_font = @import("ui_font");
const WindowAppearance = @import("field").game_state.event_runtime.WindowAppearance;

pub const Context = struct {
    font: ?*const ui_font.Font = null,
    atlas: ?rl.Texture2D = null,
    appearance: WindowAppearance = .{},

    pub fn text(self: Context, bytes: []const u8, x: i32, y: i32, size: i32, color: rl.Color) void {
        textWith(self, bytes, x, y, size, color);
    }

    pub fn numberText(self: Context, comptime format: []const u8, values: anytype, x: i32, y: i32, size: i32, color: rl.Color) void {
        var buffer: [256]u8 = undefined;
        self.text(std.fmt.bufPrint(&buffer, format, values) catch return, x, y, size, color);
    }

    pub fn selectedText(self: Context, bytes: []const u8, x: i32, y: i32, size: i32, color: rl.Color) void {
        self.text(bytes, x, y - 1, size, color);
    }

    pub fn panel(self: Context, x: i32, y: i32, w: i32, h: i32) void {
        _ = self;
        primitivePanel(x, y, w, h);
    }

    pub fn selection(self: Context, x: i32, y: i32, w: i32, h: i32) void {
        _ = self;
        rl.drawRectangle(x, y, w, h, .{ .r = 32, .g = 48, .b = 64, .a = 255 });
        rl.drawRectangleLines(x, y, w, h, .{ .r = 110, .g = 120, .b = 140, .a = 255 });
    }

    pub fn window(self: Context, x: i32, y: i32, w: i32, h: i32) void {
        if (!self.appearance.isDefault()) return drawWindowAppearance(self.appearance, x, y, w, h);
        const font = self.font orelse return self.panel(x, y, w, h);
        const atlas = self.atlas orelse return self.panel(x, y, w, h);
        const corner: i32 = 12;
        drawPiece(atlas, font.piece(.center).?.rect, x + corner, y + corner, w - corner * 2, h - corner * 2);
        drawPiece(atlas, font.piece(.top).?.rect, x + corner, y, w - corner * 2, corner);
        drawPiece(atlas, font.piece(.bottom).?.rect, x + corner, y + h - corner, w - corner * 2, corner);
        drawPiece(atlas, font.piece(.left).?.rect, x, y + corner, corner, h - corner * 2);
        drawPiece(atlas, font.piece(.right).?.rect, x + w - corner, y + corner, corner, h - corner * 2);
        drawPiece(atlas, font.piece(.top_left).?.rect, x, y, corner, corner);
        drawPiece(atlas, font.piece(.top_right).?.rect, x + w - corner, y, corner, corner);
        drawPiece(atlas, font.piece(.bottom_left).?.rect, x, y + h - corner, corner, corner);
        drawPiece(atlas, font.piece(.bottom_right).?.rect, x + w - corner, y + h - corner, corner, corner);
    }
};

var active: Context = .{};

pub fn configure(font: *const ui_font.Font, atlas: rl.Texture2D) void {
    active = .{ .font = font, .atlas = atlas };
}

pub fn context() *const Context {
    return &active;
}

pub fn setWindowAppearance(appearance: WindowAppearance) void {
    active.appearance = appearance;
}

pub fn drawWindowAppearance(appearance: WindowAppearance, x: i32, y: i32, w: i32, h: i32) void {
    const palette = [_]rl.Color{
        .{ .r = 15, .g = 29, .b = 73, .a = 255 }, .{ .r = 35, .g = 48, .b = 72, .a = 255 },
        .{ .r = 24, .g = 61, .b = 42, .a = 255 }, .{ .r = 16, .g = 64, .b = 73, .a = 255 },
        .{ .r = 60, .g = 36, .b = 75, .a = 255 }, .{ .r = 73, .g = 30, .b = 43, .a = 255 },
        .{ .r = 70, .g = 50, .b = 32, .a = 255 }, .{ .r = 43, .g = 44, .b = 49, .a = 255 },
    };
    const background = palette[@backingInt(appearance.color)];
    const border: rl.Color = .{ .r = 203, .g = 212, .b = 225, .a = 255 };
    const secondary: rl.Color = .{ .r = 115, .g = 131, .b = 155, .a = 255 };
    if (appearance.style == .rounded and w > 4 and h > 4) {
        rl.drawRectangleRounded(.{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) }, 0.22, 8, border);
        rl.drawRectangleRounded(.{ .x = @floatFromInt(x + 2), .y = @floatFromInt(y + 2), .width = @floatFromInt(w - 4), .height = @floatFromInt(h - 4) }, 0.22, 8, background);
        return;
    }
    rl.drawRectangle(x, y, w, h, background);
    if (appearance.style == .corners) {
        const length = @min(14, @divTrunc(@min(w, h), 3));
        for ([_]i32{ 0, w - 1 }, [_]i32{ 1, -1 }) |dx, sx| {
            for ([_]i32{ 0, h - 1 }, [_]i32{ 1, -1 }) |dy, sy| {
                rl.drawLine(x + dx, y + dy, x + dx + length * sx, y + dy, border);
                rl.drawLine(x + dx, y + dy, x + dx, y + dy + length * sy, border);
            }
        }
        return;
    }
    rl.drawRectangleLines(x, y, w, h, if (appearance.style == .inset) secondary else border);
    if (w > 8 and h > 8 and (appearance.style == .double or appearance.style == .inset))
        rl.drawRectangleLines(x + 3, y + 3, w - 6, h - 6, if (appearance.style == .inset) border else secondary);
}

pub fn text(bytes: []const u8, x: i32, y: i32, size: i32, color: rl.Color) void {
    active.text(bytes, x, y, size, color);
}

pub fn numberText(comptime format: []const u8, values: anytype, x: i32, y: i32, size: i32, color: rl.Color) void {
    active.numberText(format, values, x, y, size, color);
}

pub fn selection(x: i32, y: i32, w: i32, h: i32) void {
    active.selection(x, y, w, h);
}

pub fn selectedText(bytes: []const u8, x: i32, y: i32, size: i32, color: rl.Color) void {
    active.selectedText(bytes, x, y, size, color);
}

pub fn panel(x: i32, y: i32, w: i32, h: i32) void {
    active.panel(x, y, w, h);
}

pub fn window(x: i32, y: i32, w: i32, h: i32) void {
    active.window(x, y, w, h);
}

fn textWith(ctx: Context, bytes: []const u8, x: i32, y: i32, size: i32, color: rl.Color) void {
    if (ctx.font) |font| if (ctx.atlas) |atlas| {
        drawSourceText(font, atlas, bytes, x, y, size, color);
        return;
    };
    var buffer: [4097]u8 = undefined;
    const length = @min(bytes.len, buffer.len - 1);
    @memcpy(buffer[0..length], bytes[0..length]);
    buffer[length] = 0;
    rl.drawText(buffer[0..length :0], x, y, size, color);
}

fn drawSourceText(font: *const ui_font.Font, atlas: rl.Texture2D, bytes: []const u8, x: i32, y: i32, size: i32, color: rl.Color) void {
    const scale = @as(f32, @floatFromInt(size)) / 12.0;
    const start = @as(f32, @floatFromInt(x));
    var cursor = start;
    var line_y = @as(f32, @floatFromInt(y));
    for (bytes) |byte| {
        if (byte == '\n') {
            cursor = start;
            line_y += @as(f32, @floatFromInt(size));
            continue;
        }
        const glyph = font.glyph(byte) orelse {
            var fallback = [2]u8{ byte, 0 };
            const slice = fallback[0..1 :0];
            rl.drawText(slice, @intFromFloat(cursor), @intFromFloat(line_y), size, color);
            cursor += @floatFromInt(rl.measureText(slice, size));
            continue;
        };
        if (glyph.rect) |rect| {
            rl.drawTexturePro(atlas, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .width = @floatFromInt(rect.w), .height = @floatFromInt(rect.h) }, .{ .x = cursor, .y = line_y, .width = @as(f32, @floatFromInt(rect.w)) * scale, .height = @as(f32, @floatFromInt(rect.h)) * scale }, .{ .x = 0, .y = 0 }, 0, color);
        }
        cursor += @as(f32, @floatFromInt(glyph.advance)) * scale;
    }
}

fn primitivePanel(x: i32, y: i32, w: i32, h: i32) void {
    rl.drawRectangle(x, y, w, h, .{ .r = 12, .g = 26, .b = 87, .a = 255 });
    rl.drawRectangleLines(x, y, w, h, .{ .r = 190, .g = 200, .b = 222, .a = 255 });
    rl.drawRectangleLines(x + 2, y + 2, w - 4, h - 4, .{ .r = 70, .g = 90, .b = 150, .a = 255 });
}

fn drawPiece(atlas: rl.Texture2D, rect: @import("field").Rect, x: i32, y: i32, w: i32, h: i32) void {
    rl.drawTexturePro(atlas, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .width = @floatFromInt(rect.w), .height = @floatFromInt(rect.h) }, .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(w), .height = @floatFromInt(h) }, .{ .x = 0, .y = 0 }, 0, .white);
}
