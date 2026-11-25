//! Source-derived UI font and 9-slice dialogue window metadata.
const std = @import("std");
const field = @import("field");

pub const Glyph = struct { character: []const u8, rect: ?field.Rect, advance: i16 };
pub const WindowRole = enum { center, top_left, top_right, bottom_left, bottom_right, top, bottom, left, right };
pub const WindowPiece = struct { role: WindowRole, rect: field.Rect };

pub const Font = struct {
    schema: []const u8,
    glyphs: []const Glyph,
    window: []const WindowPiece,

    pub fn glyph(self: Font, byte: u8) ?Glyph {
        for (self.glyphs) |entry| if (entry.character.len == 1 and entry.character[0] == byte) return entry;
        return null;
    }

    pub fn piece(self: Font, role: WindowRole) ?WindowPiece {
        for (self.window) |entry| if (entry.role == role) return entry;
        return null;
    }

    pub fn validate(self: Font, atlas_width: i32, atlas_height: i32) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-ui-font/1") or self.glyphs.len == 0 or self.glyphs.len > 128 or self.window.len != 9) return error.InvalidUiFont;
        for (self.glyphs, 0..) |entry, index| {
            if (entry.character.len != 1 or entry.character[0] < 32 or entry.character[0] > 126 or entry.advance < 1 or entry.advance > 8 or (entry.rect == null) != (entry.character[0] == ' ')) return error.InvalidUiFont;
            if (entry.rect) |rect| if (rect.x < 0 or rect.y < 0 or rect.w <= 0 or rect.h <= 0 or rect.x + rect.w > atlas_width or rect.y + rect.h > atlas_height) return error.InvalidUiFont;
            for (self.glyphs[0..index]) |other| if (entry.character[0] == other.character[0]) return error.InvalidUiFont;
        }
        for (self.window, 0..) |entry, index| {
            const rect = entry.rect;
            if (rect.x < 0 or rect.y < 0 or rect.w <= 0 or rect.h <= 0 or rect.x + rect.w > atlas_width or rect.y + rect.h > atlas_height) return error.InvalidUiFont;
            for (self.window[0..index]) |other| if (entry.role == other.role) return error.InvalidUiFont;
        }
        for (std.enums.values(WindowRole)) |role| if (self.piece(role) == null) return error.InvalidUiFont;
    }
};

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Font) {
    return std.json.parseFromSlice(Font, allocator, bytes, .{ .allocate = .alloc_always });
}
