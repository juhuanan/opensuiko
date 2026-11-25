//! Logical view for the combat-systems menu model.  No raylib, no font, no window: the
//! host supplies a text sink with the existing game font.  Drawing is a pure
//! projection of the visible window, so a selected row can never fall outside
//! the drawn range and a long label is clipped to the row's cell budget instead
//! of overlapping the detail column.

const std = @import("std");
const model = @import("model.zig");

pub const Layout = struct {
    x: i32 = 24,
    y: i32 = 56,
    row_height: i32 = 24,
    columns: usize = 26,
    rows: usize = 9,
    page_x: i32 = 300,
    detail_x: i32 = 370,
    title: []const u8 = "",
};

pub const Rendered = struct {
    rows: usize = 0,
    selected: ?usize = null,
    first: usize = 0,
    last: usize = 0,
    clipped: usize = 0,
    empty: bool = false,
};

/// `sink` must expose `text(x: i32, y: i32, value: []const u8, selected: bool)`.
pub fn draw(menu: *const model.Menu, layout: Layout, sink: anytype) Rendered {
    const screen = menu.activeScreen();
    if (layout.title.len != 0) sink.text(layout.x, layout.y, layout.title, false);
    if (screen.rows.len == 0) {
        sink.text(layout.x, layout.y + layout.row_height, "(empty)", false);
        return .{ .empty = true };
    }
    const columns = @max(@as(usize, 2), layout.columns);
    const window = @max(@as(usize, 1), @min(layout.rows, screen.window_rows));
    const clamped = @min(window, screen.rows.len);
    var first = @min(screen.first, screen.rows.len - clamped);
    if (screen.cursor < first) first = screen.cursor;
    if (screen.cursor >= first + clamped) first = screen.cursor + 1 - clamped;
    if (first + clamped > screen.rows.len) first = screen.rows.len - clamped;

    var page_buffer: [48]u8 = undefined;
    sink.text(layout.page_x, layout.y, menu.pageLabelFor(&page_buffer, clamped), false);

    var result = Rendered{ .first = first, .last = first + clamped };
    for (first..first + clamped) |index| {
        const row = screen.rows[index];
        const selected = index == screen.cursor;
        const display = model.fitLabel(row.label, columns - 2);
        if (display.clipped) result.clipped += 1;
        var line: [model.max_id + 4]u8 = undefined;
        const marker: []const u8 = if (selected) "> " else "  ";
        const text = std.fmt.bufPrint(&line, "{s}{s}", .{ marker, display.text() }) catch display.text();
        sink.text(layout.x, layout.y + @as(i32, @intCast(index - first + 1)) * layout.row_height, text, selected);
        if (row.detail) |detail| {
            sink.text(layout.detail_x, layout.y + @as(i32, @intCast(index - first + 1)) * layout.row_height, detail, false);
        }
        result.rows += 1;
        if (selected) result.selected = index;
    }
    return result;
}
