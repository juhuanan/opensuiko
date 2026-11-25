//! Selector windows, fixed prompts and source-ordered character names.
const std = @import("std");
const field = @import("field");
const party = @import("party_session");
const battle = @import("battle");
const selector = party.selector;
const presentation = @import("opening").presentation;

pub const Characters = struct {
    characters: []const party.catalogue.Character,
    hero: []const u8,
    profiles: []const battle.Profile = &.{},
    details: ?selector.Details = null,
    portrait: ?field.Rect = null,

    fn get(self: Characters, id: []const u8) ![]const u8 {
        if (std.mem.eql(u8, id, "hero")) return if (self.hero.len != 0) self.hero else error.MissingSelectorName;
        for (self.characters) |character| if (std.mem.eql(u8, character.id, id)) {
            if (character.source_character_id >= 108) return error.UnsupportedSelectorName;
            return character.name;
        };
        return error.MissingSelectorName;
    }

    fn range(self: Characters, id: []const u8) ![]const u8 {
        for (self.profiles) |profile| if (std.mem.eql(u8, profile.id, id)) {
            return (profile.weapon_range orelse return error.MissingSelectorWeaponRange).label()[0..1];
        };
        return error.MissingSelectorWeaponRange;
    }
};

pub fn portraitVisible(menu: selector.Selector, roster: selector.Roster) bool {
    if (menu.action == .no_change or (menu.action == .admit and roster.active.len == 6)) return false;
    var buffer: [78][]const u8 = undefined;
    if (menu.list(roster, &buffer).len == 0) return false;
    return switch (menu.phase) {
        .list, .confirmation_opening, .confirmation, .confirmation_closing => true,
        .decision => menu.action == .eject,
        else => false,
    };
}

pub fn portraitRect(bindings: anytype, id: []const u8, action: selector.Action) !field.Rect {
    const expected = for (selector.layout.portraits) |entry| {
        if (std.mem.eql(u8, entry.id, id)) break entry;
    } else return error.MissingSelectorPortrait;
    const plane = switch (action) {
        .admit => expected.admit_plane_sha256,
        .eject => expected.eject_plane_sha256,
        .no_change => return error.MissingSelectorPortrait,
    };
    for (bindings) |binding| for (binding.dialogue.images) |image| {
        if (!std.mem.eql(u8, image.plane_sha256, plane) or !std.mem.eql(u8, image.palette_sha256, expected.palette_sha256)) continue;
        if (image.atlas_rect) |rect| {
            if (rect.w != 64 or rect.h != 64) return error.InvalidSelectorPortrait;
            return rect;
        }
    };
    return error.MissingSelectorPortrait;
}

pub fn compose(menu: selector.Selector, windows: selector.Windows, roster: selector.Roster, names: Characters, art: anytype, list: *presentation.List) !void {
    const origin = field.Point{ .x = selector.layout.origin_x, .y = selector.layout.origin_y };
    list.length = 0;
    inline for (.{ selector.Kind.main, selector.Kind.list, selector.Kind.details, selector.Kind.party, selector.Kind.confirmation, selector.Kind.full }) |kind| {
        if (windows.window(kind)) |window| {
            if (window.outline()) |outline| {
                var rect = outline;
                rect.x += origin.x;
                rect.y += origin.y;
                try list.outlineRect(rect);
            } else if (window.phase == .open) {
                var rect = window.target;
                rect.x += origin.x;
                rect.y += origin.y;
                try presentation.window(list, art, rect);
                switch (kind) {
                    .main => if (menu.phase == .main) try choices(list, art, selector.layout.choices, rect, @intCast(@backingInt(menu.action))),
                    .confirmation => if (menu.phase == .confirmation) try choices(list, art, if (menu.action == .admit) selector.layout.admit_prompt else selector.layout.eject_prompt, rect, @intFromBool(menu.refuse)),
                    .full => if (menu.phase == .full) {
                        try presentation.glyphs(list, art, selector.layout.full_prompt, rect.x, rect.y, null);
                        try presentation.glyphs(list, art, selector.layout.acknowledge_prompt, rect.x + 16, rect.y + 12, null);
                    },
                    .list => {
                        var buffer: [78][]const u8 = undefined;
                        const candidates = menu.list(roster, &buffer);
                        if (candidates.len != 0 and menu.cursor >= candidates.len) return error.StaleSelectorRoster;
                        const start = if (menu.action == .admit and candidates.len != 0) menu.cursor / 10 * 10 else 0;
                        const end = @min(start + 10, candidates.len);
                        for (candidates[start..end], 0..) |id, row| {
                            try nameRow(list, art, try names.get(id), rect, @intCast(row), row == menu.cursor % 10, menu.action == .eject and !roster.ejectable(id));
                        }
                        if (candidates.len != 0) try list.selectionRect(.{ .x = rect.x, .y = rect.y - 2 + @as(i32, @intCast(menu.cursor % 10)) * 12, .w = rect.w, .h = 12 }, false);
                        if (menu.action == .admit) try pageFooter(list, art, rect, menu.cursor / 10 + 1, (candidates.len + 9) / 10);
                    },
                    .party => for (roster.active, 0..) |id, row| {
                        try nameRow(list, art, try names.get(id), rect, @intCast(row), false, false);
                        try presentation.glyphs(list, art, try names.range(id), rect.x + 9 * 8, rect.y + @as(i32, @intCast(row)) * 12, null);
                    },
                    .details => if (names.details) |details| try characterDetails(list, art, rect, details),
                }
            }
        }
    }
    if (portraitVisible(menu, roster)) {
        const image = names.portrait orelse return error.MissingSelectorPortrait;
        const target = selector.layout.portrait_rect;
        if (list.length == list.pieces.len) return error.OpeningDrawListFull;
        list.pieces[list.length] = .{ .sprite = .{ .rect = image, .x = target.x + origin.x, .y = target.y + origin.y, .width = target.w, .height = target.h } };
        list.length += 1;
    }
}

fn pageFooter(list: *presentation.List, art: anytype, rect: field.Rect, page: usize, pages: usize) !void {
    if (page > 8 or pages > 8) return error.InvalidSelectorPage;
    const current = [_]u8{'0' + @as(u8, @intCast(page))};
    const total = [_]u8{ '0' + @as(u8, @intCast(pages)), 'P' };
    const y = rect.y + 10 * 12;
    try presentation.glyphs(list, art, &current, rect.x + 4 * 8, y, null);
    try separator(list, rect.x + 5 * 8, y);
    try presentation.glyphs(list, art, &total, rect.x + 6 * 8, y, null);
}

fn separator(list: *presentation.List, x: i32, y: i32) !void {
    for (selector.layout.page_separator_pixels, 0..) |row, dy| for (row, 0..) |pixel, dx| {
        if (pixel == 0) continue;
        if (list.length == list.pieces.len) return error.OpeningDrawListFull;
        list.pieces[list.length] = .{ .solid_fill = .{
            .rect = .{ .x = x + @as(i32, @intCast(dx)), .y = y + @as(i32, @intCast(dy)), .w = 1, .h = 1 },
            .color = selector.layout.page_separator_colors[pixel],
        } };
        list.length += 1;
    };
}

fn number(list: *presentation.List, art: anytype, value: u16, width: u8, x: i32, y: i32) !void {
    if (width == 0 or width > 4) return error.InvalidSelectorNumberWidth;
    var text: [4]u8 = @splat(' ');
    var remaining = value;
    var column = width;
    while (column != 0) {
        column -= 1;
        text[column] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
        if (remaining == 0) break;
    }
    try presentation.glyphs(list, art, text[0..width], x, y, null);
}

fn characterDetails(list: *presentation.List, art: anytype, rect: field.Rect, details: selector.Details) !void {
    inline for (selector.layout.detail_numbers) |entry| {
        const x = rect.x + @as(i32, entry.column) * 8;
        const y = rect.y + @as(i32, entry.row) * 12;
        try presentation.glyphs(list, art, entry.label, x, y, null);
        try number(list, art, @field(details, @tagName(entry.field)), entry.width, x + @as(i32, @intCast(entry.label.len)) * 8, y);
    }
    try presentation.glyphs(list, art, selector.layout.detail_mp_label, rect.x + 8 * 8, rect.y + 12, null);
    for (details.charges, 0..) |charge, tier| {
        try number(list, art, charge, 1, rect.x + @as(i32, @intCast(11 + tier * 2)) * 8, rect.y + 12);
        if (tier != 3) try separator(list, rect.x + @as(i32, @intCast(12 + tier * 2)) * 8, rect.y + 12);
    }
    try presentation.glyphs(list, art, selector.layout.detail_range_label, rect.x, rect.y + 6 * 12, null);
    try presentation.glyphs(list, art, details.range.label()[0..1], rect.x + 11 * 8, rect.y + 6 * 12, null);
    try presentation.glyphs(list, art, selector.layout.detail_rune_label, rect.x, rect.y + 7 * 12, null);
    if (details.rune) |name| try presentation.glyphs(list, art, name, rect.x + 6 * 8, rect.y + 7 * 12, null);
}

fn nameRow(list: *presentation.List, art: anytype, name: []const u8, rect: field.Rect, row: u8, selected: bool, protected: bool) !void {
    const first = list.length;
    try presentation.glyphs(list, art, name, rect.x, rect.y + @as(i32, row) * 12, if (selected) 0 else null);
    if (protected) for (list.pieces[first..list.length]) |*piece| {
        piece.sprite.color = .{ 96, 224, 255 };
    };
}

fn choices(list: *presentation.List, art: anytype, text: []const u8, rect: field.Rect, row: u8) !void {
    try presentation.glyphs(list, art, text, rect.x, rect.y, row);
    try list.selectionRect(.{ .x = rect.x, .y = rect.y - 2 + @as(i32, row) * 12, .w = rect.w, .h = 12 }, false);
}
