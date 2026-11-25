const std = @import("std");
const ui_font = @import("ui_font");

test "selector fixed prompts use their own window and selection width" {
    const journey = @import("journey");
    const selector = journey.party_selection.selector;
    const Art = struct {
        window: []const ui_font.WindowPiece = &.{},
        pub fn glyph(_: @This(), byte: u8) ?ui_font.Glyph {
            return .{ .character = "", .rect = .{ .x = byte, .y = 0, .w = 8, .h = 12 }, .advance = 8 };
        }
    };
    const characters = [_]selector.Candidate{
        .{ .id = "hero", .recruited = true, .blocked = false },
        .{ .id = "gremio", .recruited = true, .blocked = false },
        .{ .id = "cleo", .recruited = true, .blocked = false },
    };
    const roster: selector.Roster = .{ .characters = &characters, .active = &.{ "hero", "gremio", "cleo" }, .forced = &.{"gremio"} };
    const catalogue = try @import("party_session").catalogue.decode(std.testing.allocator, @import("party_data").json);
    defer catalogue.deinit();
    const trial = try @import("battle").load(std.testing.allocator, @embedFile("fixtures/opening_trial.json"));
    defer trial.deinit();
    const names = journey.party_selector_view.Characters{ .characters = catalogue.value.characters, .hero = "Jaster", .profiles = trial.value.party, .portrait = .{ .x = 0, .y = 0, .w = 64, .h = 64 } };
    var windows: selector.Windows = .{};
    var window = try selector.Window.init(.{ .x = -64, .y = -20, .w = 128, .h = 36 });
    window.open();
    window.tick();
    windows.slots[@backingInt(selector.Kind.main)] = window;
    var list: journey.opening.presentation.List = .{};
    try journey.party_selector_view.compose(.{ .phase = .main_opening }, windows, roster, names, Art{}, &list);
    try std.testing.expectEqual(@as(usize, 4), list.length);
    try std.testing.expectEqual(@as(i32, 152), list.pieces[0].line.x1);
    for (0..8) |_| window.tick();
    windows.slots[@backingInt(selector.Kind.main)] = window;
    try journey.party_selector_view.compose(.{ .phase = .main, .action = .eject }, windows, roster, names, Art{}, &list);
    try std.testing.expectEqual(@as(i32, 100), list.pieces[0].sprite.y);
    const selected = list.pieces[list.length - 5].additive_fill.rect;
    try std.testing.expectEqual(@import("field").Rect{ .x = 96, .y = 110, .w = 128, .h = 12 }, selected);
    windows = .{};
    window = try selector.Window.init(.{ .x = -140, .y = -94, .w = 64, .h = 72 });
    window.open();
    for (0..9) |_| window.tick();
    windows.slots[@backingInt(selector.Kind.list)] = window;
    try journey.party_selector_view.compose(.{ .phase = .list, .action = .eject, .cursor = 1 }, windows, roster, names, Art{}, &list);
    try std.testing.expectEqual([3]u8{ 96, 224, 255 }, list.pieces[0].sprite.color);
    try std.testing.expectEqual(@as(i32, 37), list.pieces[6].sprite.y);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, list.pieces[12].sprite.color);
    try std.testing.expectEqual(@as(i32, 94), list.pieces[list.length - 1].sprite.x);
    try std.testing.expectEqual(@as(i32, 120), list.pieces[list.length - 1].sprite.y);
    windows = .{};
    window = try selector.Window.init(.{ .x = 62, .y = 31, .w = 80, .h = 72 });
    window.open();
    for (0..9) |_| window.tick();
    windows.slots[@backingInt(selector.Kind.party)] = window;
    try journey.party_selector_view.compose(.{ .phase = .list }, windows, roster, names, Art{}, &list);
    try std.testing.expectEqual(@as(i32, 294), list.pieces[6].sprite.x);
    windows = .{};
    window = try selector.Window.init(.{ .x = -148, .y = -94, .w = 64, .h = 132 });
    window.open();
    for (0..9) |_| window.tick();
    windows.slots[@backingInt(selector.Kind.list)] = window;
    var admission = roster;
    admission.active = &.{"hero"};
    admission.forced = &.{};
    try journey.party_selector_view.compose(.{ .phase = .list }, windows, admission, names, Art{}, &list);
    const separator = for (list.pieces[0..list.length]) |piece| {
        if (piece == .solid_fill) break piece.solid_fill;
    } else return error.MissingPageSeparator;
    try std.testing.expectEqual(@import("field").Rect{ .x = 57, .y = 147, .w = 1, .h = 1 }, separator.rect);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, separator.color);
    windows = .{};
    window = try selector.Window.init(.{ .x = -58, .y = -94, .w = 200, .h = 108 });
    window.open();
    for (0..9) |_| window.tick();
    windows.slots[@backingInt(selector.Kind.details)] = window;
    var detailed = names;
    detailed.details = .{ .level = 1, .max_hp = 20, .power = 10, .skill = 12, .defense = 13, .speed = 14, .magic = 15, .luck = 16, .attack = 65535, .armour = 13, .charges = .{ 1, 2, 3, 4 }, .range = .medium, .rune = null };
    try journey.party_selector_view.compose(.{ .phase = .list }, windows, admission, detailed, Art{}, &list);
    try std.testing.expectEqual(@as(i32, '5'), list.pieces[8].sprite.rect.x);
}

test "canonical ui.json covers the source glyphs and nine window roles" {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../kit/work/build/canonical/ui.json", std.testing.allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(bytes);
    const parsed = try ui_font.load(std.testing.allocator, bytes);
    defer parsed.deinit();
    try parsed.value.validate(4096, 3572);
    try std.testing.expectEqual(@as(usize, 73), parsed.value.glyphs.len);
    try std.testing.expectEqual(@as(usize, 9), parsed.value.window.len);
    try std.testing.expect(parsed.value.glyph(':') != null);
    try std.testing.expect(parsed.value.glyph('&') != null);
    try std.testing.expect(parsed.value.glyph('a') != null);
    try std.testing.expect(parsed.value.glyph(' ') != null);
    try std.testing.expect(parsed.value.piece(.center) != null);
    try std.testing.expect(parsed.value.piece(.bottom_right) != null);
}
