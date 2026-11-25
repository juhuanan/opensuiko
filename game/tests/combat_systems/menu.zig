//! Focused gate: one menu/input architecture over every admitted list.
//!
//! Every case is port code only.  No original instruction, emulator, window,
//! font frame or media playback is used.  The packet is the checked-in
//! `menu_lists.json`; the roster catalogue and item ids are the same tracked
//! inputs the world suite uses, so the count checks are independent of the
//! packet's own summary.

const std = @import("std");
const menu_mod = @import("combat_systems").menu;
const items = @import("field").items;
const model = menu_mod.model;
const packet = menu_mod.vocabulary;
const adapter = menu_mod.adapter;
const view = menu_mod.view;

const allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Opened = struct {
    value: packet.Opened,

    fn init() !Opened {
        return .{ .value = try menu_mod.loadAsset(allocator) };
    }

    fn deinit(self: *Opened) void {
        self.value.deinit();
    }

    fn data(self: *Opened) *const packet.Packet {
        return self.value.packet();
    }
};

const Capture = struct {
    const Line = struct {
        text: [96]u8 = undefined,
        len: usize = 0,
        x: i32 = 0,
        y: i32 = 0,
        selected: bool = false,
    };
    lines: [64]Line = @splat(.{}),
    count: usize = 0,

    fn reset(self: *Capture) void {
        self.count = 0;
    }

    pub fn text(self: *Capture, x: i32, y: i32, value: []const u8, selected: bool) void {
        if (self.count == self.lines.len) return;
        const line = &self.lines[self.count];
        const length = @min(value.len, line.text.len);
        @memcpy(line.text[0..length], value[0..length]);
        line.len = length;
        line.x = x;
        line.y = y;
        line.selected = selected;
        self.count += 1;
    }

    fn slice(self: *const Capture, index: usize) []const u8 {
        return self.lines[index].text[0..self.lines[index].len];
    }

    fn selectedCount(self: *const Capture) usize {
        var count: usize = 0;
        for (self.lines[0..self.count]) |line| if (line.selected) {
            count += 1;
        };
        return count;
    }
};

fn serviceRows(catalogue: *const packet.Packet, key: []const u8, buffer: []model.Row) ![]model.Row {
    return adapter.serviceRows(catalogue, key, null, buffer);
}

fn commandCount(rows: []const model.Row) usize {
    var count: usize = 0;
    for (rows) |row| if (row.role != .separator) {
        count += 1;
    };
    return count;
}

fn visitAll(menu: *model.Menu, expected_commands: usize) !void {
    try expect(expected_commands > 0);
    var seen: [@max(packet.admitted_items, 128)]bool = @splat(false);
    for (0..expected_commands) |_| {
        const screen = menu.activeScreen();
        try expect(commandCount(screen.rows) == expected_commands);
        try expect(screen.selectedVisible());
        try expect(!seen[screen.cursor]);
        seen[screen.cursor] = true;
        _ = menu.receiveKey(.down);
    }
    for (menu.activeScreen().rows, 0..) |row, index| {
        if (row.role != .separator) try expect(seen[index]);
    }
}

fn rootLabels(catalogue: *const packet.Packet) [6][]const u8 {
    const list = for (catalogue.lists) |value| {
        if (std.mem.eql(u8, value.key, "root")) break value;
    } else unreachable;
    var labels: [6][]const u8 = undefined;
    for (list.rows, 0..) |row, index| labels[index] = row.label;
    return labels;
}

test "packet loads, pins the base snapshot and refuses a forged one" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    try expectEqualStrings(packet.schema, data.schema);
    try expectEqualStrings(packet.base_snapshot, data.base_snapshot);
    try expectEqual(@as(usize, 11), data.lists.len);
    try expectEqual(@as(usize, 6), data.windows.len);
    try expect(data.anchors.len >= 24);
    try expect(data.blocked.len > 0);

    const forged = try allocator.dupe(u8, menu_mod.data.json);
    defer allocator.free(forged);
    const at = std.mem.indexOf(u8, forged, packet.base_snapshot).?;
    @memset(forged[at .. at + packet.base_snapshot.len], '0');
    try std.testing.expectError(error.InvalidBaseSnapshot, packet.load(allocator, forged));
}

test "admitted item ids and labels match the port enum exactly" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    const values = std.enums.values(items.Id);
    try expectEqual(@as(usize, packet.admitted_items), values.len);
    try expectEqual(values.len, data.items.len);
    for (values, 0..) |id, index| {
        try expectEqualStrings(@tagName(id), data.items[index].id);
        try expectEqualStrings(id.name(), data.items[index].label);
        try expect(data.items[index].source_records.len >= 1);
        try expect(data.items[index].source_records[0] >= 1);
        try expect(data.items[index].source_records[0] <= 179);
    }
}

test "admitted roster matches the tracked catalogue in SLUS record order" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    const JsonCatalogue = struct {
        characters: []const struct {
            id: []const u8,
            name: []const u8,
            source_character_id: u32,
        },
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "game/assets/party_session/catalogue.json",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(JsonCatalogue, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try expectEqual(@as(usize, 78), parsed.value.characters.len);
    try expectEqual(parsed.value.characters.len, data.roster.len);
    for (parsed.value.characters, 0..) |character, index| {
        try expectEqualStrings(character.id, data.roster[index].id);
        try expectEqualStrings(character.name, data.roster[index].name);
        try expectEqual(@as(u32, data.roster[index].source_character_id), character.source_character_id);
        try expectEqual(@as(u16, @intCast(index)), data.roster[index].record);
    }
}

test "source list labels and separators come from the packet" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    const root = rootLabels(data);
    const expected = [_][]const u8{ "Item", "Strength", "Rune", "Formation", "Equipment", "Setup" };
    for (expected, root) |want, got| try expectEqualStrings(want, got);

    var buffer: [32]model.Row = undefined;
    const item_actions = try serviceRows(data, "item_action", &buffer);
    try expectEqual(@as(usize, 3), item_actions.len);
    try expectEqualStrings("Use", item_actions[0].label);
    try expectEqualStrings("Hand over", item_actions[1].label);
    try expectEqualStrings("Give up", item_actions[2].label);

    var setup_buffer: [32]model.Row = undefined;
    const setup = try serviceRows(data, "setup", &setup_buffer);
    try expectEqual(@as(usize, 12), setup.len);
    try expectEqual(@as(usize, 2), setup.len - commandCount(setup));
    try expectEqual(model.Role.separator, setup[4].role);
    try expectEqual(model.Role.separator, setup[8].role);
}

test "each ordinary service list is reachable with down events only" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var buffer: [32]model.Row = undefined;
    for ([_][]const u8{ "root", "item_action", "shop", "blacksmith", "rune", "appraiser", "setup", "battle_commands", "pause_commands" }) |key| {
        const rows = try serviceRows(data, key, &buffer);
        var menu = menu_mod.menu();
        menu.open(.root, rows, .{ .window_rows = 4, .columns = 20 });
        try visitAll(&menu, commandCount(rows));
    }
}

test "all 78 roster rows are reachable and every selection stays visible" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var admitted: [78]bool = @splat(true);
    var rows: [78]model.Row = undefined;
    const built = try adapter.rosterRows(data, &admitted, &.{ "hero", "gremio" }, &rows);
    try expectEqual(@as(usize, 78), built.len);
    try expectEqualStrings("Active", built[0].detail.?);
    try expectEqualStrings("Reserve", built[2].detail.?);

    var menu = menu_mod.menu();
    menu.open(.roster, built, .{ .window_rows = 8, .columns = 26 });
    try visitAll(&menu, 78);
}

test "all admitted item rows and 6 targets are reachable" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var ids: [packet.admitted_items][]const u8 = undefined;
    for (data.items, 0..) |item, index| ids[index] = item.id;
    var rows: [packet.admitted_items]model.Row = undefined;
    const built = try adapter.itemRows(data, &ids, &rows);
    try expectEqual(@as(usize, packet.admitted_items), built.len);
    var menu = menu_mod.menu();
    menu.open(.bag, built, .{ .window_rows = 9, .columns = 20 });
    try visitAll(&menu, data.items.len);

    const targets = [_]adapter.Target{
        .{ .id = "hero", .label = "Hero" },
        .{ .id = "gremio", .label = "Gremio" },
        .{ .id = "pahn", .label = "Pahn" },
        .{ .id = "cleo", .label = "Cleo" },
        .{ .id = "ted", .label = "Ted" },
        .{ .id = "viktor", .label = "Viktor", .enabled = false, .detail = "Unavailable" },
    };
    var target_rows: [6]model.Row = undefined;
    const built_targets = try adapter.targetRows(data, &targets, &target_rows);
    var target_menu = menu_mod.menu();
    target_menu.open(.target, built_targets, .{ .window_rows = 4, .columns = 26 });
    try visitAll(&target_menu, 6);
}

test "selection is re-found by identity across reorder and rostering" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var admitted: [78]bool = @splat(true);
    var rows: [78]model.Row = undefined;
    const built = try adapter.rosterRows(data, &admitted, &.{}, &rows);
    var menu = menu_mod.menu();
    menu.open(.roster, built, .{ .window_rows = 8, .columns = 26 });
    try expect(menu.selectIndex(.roster, 70));
    const wanted = menu.activeScreen().selectedId().?;
    try expect(menu.activeScreen().selectedVisible());

    // Reorder: the id must follow its row, not index 70.
    var reversed: [78]model.Row = undefined;
    for (built, 0..) |row, index| reversed[built.len - 1 - index] = row;
    menu.refresh(&reversed);
    try expectEqualStrings(wanted, menu.activeScreen().selectedId().?);
    try expect(menu.activeScreen().selectedVisible());
    try expectEqual(@as(usize, 7), menu.activeScreen().cursor);

    // Roster shrink below the old index: clamp, count the loss, stay visible.
    var fewer: [40]bool = @splat(true);
    var smaller: [40]model.Row = undefined;
    const built_smaller = try adapter.rosterRows(data, &fewer, &.{}, &smaller);
    menu.refresh(built_smaller);
    const screen = menu.activeScreen();
    try expect(screen.cursor < built_smaller.len);
    try expect(screen.selectedVisible());
    try expect(menu.lost >= 1);
}

test "mode switches keep each screen's cursor and reopen by id" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var ids: [packet.admitted_items][]const u8 = undefined;
    for (data.items, 0..) |item, index| ids[index] = item.id;
    var rows: [packet.admitted_items]model.Row = undefined;
    const built = try adapter.itemRows(data, &ids, &rows);
    var menu = menu_mod.menu();
    menu.open(.bag, built, .{ .window_rows = 9, .columns = 20 });
    try expect(menu.selectIndex(.bag, 50));
    const bag_id = menu.activeScreen().selectedId().?;

    var storage_rows: [packet.admitted_items]model.Row = undefined;
    const storage = try adapter.storageRows(data, &ids, &storage_rows);
    menu.open(.storage, storage, .{ .window_rows = 9, .columns = 20 });
    try expect(menu.selectIndex(.storage, 3));
    menu.open(.bag, built, .{ .window_rows = 9, .columns = 20 });
    try expectEqualStrings(bag_id, menu.activeScreen().selectedId().?);
    try expectEqual(@as(usize, 50), menu.activeScreen().cursor);

    menu.open(.storage, storage, .{ .window_rows = 9, .columns = 20 });
    try expectEqual(@as(usize, 3), menu.activeScreen().cursor);
}

test "restore re-finds the remembered id or clamps visibly" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var ids: [packet.admitted_items][]const u8 = undefined;
    for (data.items, 0..) |item, index| ids[index] = item.id;
    var rows: [packet.admitted_items]model.Row = undefined;
    const built = try adapter.itemRows(data, &ids, &rows);
    var menu = menu_mod.menu();
    menu.open(.bag, built, .{ .window_rows = 9, .columns = 20 });
    try expect(menu.selectIndex(.bag, 55));
    const wanted = menu.activeScreen().selectedId().?;
    const saved = menu.snapshot();

    // A restored menu has no rows until the owner reopens it.
    var restored = menu_mod.menu();
    restored.restore(saved);
    try expectEqual(model.Source.bag, restored.active);
    try expect(restored.activeScreen().rows.len == 0);

    var shifted: [packet.admitted_items]model.Row = undefined;
    for (built, 0..) |row, index| shifted[(index + 7) % built.len] = row;
    restored.open(.bag, &shifted, .{ .window_rows = 9, .columns = 20 });
    try expectEqualStrings(wanted, restored.activeScreen().selectedId().?);
    try expect(restored.activeScreen().selectedVisible());

    // Missing id: clamp, count a loss, still visible.
    var smaller: [10]model.Row = undefined;
    for (built[0..10], 0..) |row, index| smaller[index] = row;
    const before = restored.lost;
    restored.refresh(&smaller);
    try expect(restored.activeScreen().cursor < 10);
    try expect(restored.activeScreen().selectedVisible());
    try expect(restored.lost == before + 1);
}

test "a locked or hidden menu cannot replay input" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var buffer: [16]model.Row = undefined;
    const rows = try serviceRows(data, "shop", &buffer);
    var menu = menu_mod.menu();
    menu.open(.shop, rows, .{ .window_rows = 3, .columns = 20 });

    // Disabled row: reachable but confirms nothing.
    var disabled = [_]model.Row{
        .{ .id = "buy", .label = "Buy", .enabled = false },
        .{ .id = "sell", .label = "Sell" },
        .{ .id = "end", .label = "End" },
    };
    menu.refresh(&disabled);
    try expectEqual(@as(usize, 0), menu.activeScreen().cursor);
    try expectEqual(model.Action{ .refused = .row_disabled }, menu.receiveKey(.confirm));
    try expect(menu.takeCommand() == null);

    // A screen lock refuses confirm and invalidates any older queued event.
    const old_epoch = menu.epoch;
    menu.setLocked(true);
    try expectEqual(model.Action{ .refused = .screen_locked }, menu.receiveKey(.confirm));
    menu.setLocked(false);
    try expect(menu.takeCommand() == null);
    try expectEqual(model.Action.stale, menu.receive(.{ .key = .confirm, .epoch = old_epoch }));

    // Hidden input is dropped, not buffered.
    const hidden_epoch = menu.epoch;
    menu.setVisible(false);
    try expectEqual(model.Action.ignored, menu.receive(.{ .key = .confirm, .epoch = hidden_epoch }));
    menu.setVisible(true);
    try expect(menu.takeCommand() == null);
    try expectEqual(@as(u32, 1), menu.stale);
}

test "confirm snapshots a command exactly once" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var buffer: [16]model.Row = undefined;
    const rows = try serviceRows(data, "shop", &buffer);
    var menu = menu_mod.menu();
    menu.open(.shop, rows, .{ .window_rows = 3, .columns = 20 });
    try expectEqual(model.Action.accepted, menu.receiveKey(.confirm));
    // A second confirm before the owner consumes the snapshot cannot duplicate it.
    try expectEqual(model.Action{ .refused = .command_pending }, menu.receiveKey(.confirm));
    const command = menu.takeCommand().?;
    try expectEqual(model.Source.shop, command.source);
    try expectEqual(@as(usize, 0), command.index);
    try expectEqualStrings("buy", command.id);
    try expectEqualStrings("Buy", command.label);
    try expect(menu.takeCommand() == null);

    // Navigation clears the pending snapshot but keeps the explicit command.
    _ = menu.receiveKey(.down);
    try expectEqual(model.Action.accepted, menu.receiveKey(.confirm));
    const second = menu.takeCommand().?;
    try expectEqualStrings("sell", second.id);
    // The confirmed index is visible even after the cursor moves on.
    _ = menu.receiveKey(.down);
    try expectEqual(@as(usize, 1), menu.activeScreen().confirmed.?);
    try expectEqualStrings("sell", menu.activeScreen().confirmed_id);
    try expect(menu.takeCommand() == null);
}

test "cancel belongs to the active screen and cannot reach a hidden parent" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var ids: [packet.admitted_items][]const u8 = undefined;
    for (data.items, 0..) |item, index| ids[index] = item.id;
    var rows: [packet.admitted_items]model.Row = undefined;
    const built = try adapter.itemRows(data, &ids, &rows);
    var menu = menu_mod.menu();
    menu.open(.bag, built, .{ .window_rows = 9, .columns = 20 });
    try expectEqual(model.Action{ .navigate = .item_action }, menu.receiveKey(.cancel));
    try expect(!menu.visible);

    // Suspended: cancel/confirm are ignored, not stored for the next screen.
    try expectEqual(model.Action.ignored, menu.receiveKey(.cancel));
    try expectEqual(model.Action.ignored, menu.receiveKey(.confirm));
    menu.open(.item_action, built[0..3], .{ .window_rows = 3, .columns = 20 });
    try expect(menu.visible);
    try expect(menu.takeCommand() == null);
    try expectEqual(model.Action{ .navigate = .root }, menu.receiveKey(.cancel));

    // Root has no parent: cancel closes.
    menu.open(.root, built[0..6], .{ .window_rows = 6, .columns = 26 });
    try expectEqual(model.Action.close, menu.receiveKey(.cancel));
    try expect(!menu.visible);
}

test "horizontal routing is explicit and a consumed route does not auto-open" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var buffer: [16]model.Row = undefined;
    const rows = try serviceRows(data, "shop", &buffer);
    var menu = menu_mod.menu();
    menu.open(.shop, rows, .{ .window_rows = 3, .columns = 20 });
    const epoch = menu.epoch;
    try expectEqual(model.Action{ .navigate = .shop_confirm }, menu.receiveKey(.right));
    try expect(!menu.visible);
    // The old screen is no longer active: a stale event cannot confirm there.
    try expectEqual(model.Action.ignored, menu.receive(.{ .key = .confirm, .epoch = epoch }));
    try expect(menu.takeCommand() == null);
}

test "long labels keep their full value and clip inside the row budget" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var ids: [packet.admitted_items][]const u8 = undefined;
    for (data.items, 0..) |item, index| ids[index] = item.id;
    var rows: [packet.admitted_items]model.Row = undefined;
    const built = try adapter.itemRows(data, &ids, &rows);
    var clipped: usize = 0;
    for (built, 0..) |row, index| {
        const display = model.fitLabel(row.label, 12);
        try expect(display.text().len <= 12);
        try expect(display.clipped == (row.label.len > 12));
        if (display.clipped) clipped += 1;
        // Full label remains available on the row.
        try expectEqualStrings(row.label, built[index].label);
    }
    try expect(clipped > 0);

    const empty = model.fitLabel("anything", 0);
    try expect(empty.text().len == 0 and empty.clipped);
    const exact = model.fitLabel("123456789012", 12);
    try expectEqualStrings("123456789012", exact.text());
    try expect(!exact.clipped);
    const cut = model.fitLabel("1234567890123", 12);
    try expectEqualStrings("12345678901~", cut.text());
    try expect(cut.clipped);
}

test "logical view draws only the window and exactly one selected row" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var ids: [packet.admitted_items][]const u8 = undefined;
    for (data.items, 0..) |item, index| ids[index] = item.id;
    var rows: [packet.admitted_items]model.Row = undefined;
    const built = try adapter.itemRows(data, &ids, &rows);
    var menu = menu_mod.menu();
    menu.open(.bag, built, .{ .window_rows = 8, .columns = 26 });
    try expect(menu.selectIndex(.bag, 60));

    var capture = Capture{};
    const rendered = view.draw(&menu, .{ .title = "Inventory", .rows = 8, .columns = 14 }, &capture);
    try expectEqual(@as(usize, 8), rendered.rows);
    try expectEqual(@as(usize, 1), capture.selectedCount());
    try expect(capture.count == 8 + 2); // title + page + eight rows
    try expectEqual(@as(usize, 60), rendered.selected.?);
    try expect(rendered.clipped > 0);
    for (capture.lines[2..capture.count]) |line| {
        try expect(line.len <= 14);
    }
    var expected_page_buf: [32]u8 = undefined;
    const expected_page = try std.fmt.bufPrint(&expected_page_buf, "54-61/{d}", .{packet.admitted_items});
    var page_found = false;
    for (capture.lines[0..capture.count]) |line| {
        const value = line.text[0..line.len];
        if (std.mem.indexOf(u8, value, expected_page) != null) page_found = true;
    }
    try expect(page_found);

    // Window larger than the list: no phantom pages and no duplicate selection.
    var small_capture = Capture{};
    menu.open(.shop, built[0..3], .{ .window_rows = 9, .columns = 20 });
    const small = view.draw(&menu, .{ .rows = 9, .columns = 20 }, &small_capture);
    try expectEqual(@as(usize, 3), small.rows);
    try expectEqual(@as(usize, 1), small_capture.selectedCount());
    try expectEqual(@as(usize, 0), small.first);
    try expectEqual(@as(usize, 3), small.last);
}

test "empty, one-row and zero-window lists are bounded" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var buffer: [16]model.Row = undefined;
    const rows = try serviceRows(data, "shop", &buffer);
    var menu = menu_mod.menu();

    menu.open(.shop, rows[0..0], .{ .window_rows = 0, .columns = 20 });
    try expectEqual(model.Action{ .refused = .empty_list }, menu.receiveKey(.confirm));
    try expectEqual(model.Action{ .refused = .empty_list }, menu.receiveKey(.down));
    try expectEqual(model.Action{ .navigate = .root }, menu.receiveKey(.cancel));

    menu.open(.shop, rows[0..1], .{ .window_rows = 0, .columns = 20 });
    _ = menu.receiveKey(.up);
    _ = menu.receiveKey(.down);
    try expectEqual(@as(usize, 0), menu.activeScreen().cursor);
    try expect(menu.activeScreen().selectedVisible());
    try expectEqual(model.Action.accepted, menu.receiveKey(.confirm));
}

test "runtime builders refuse ids the packet does not admit" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var rows: [8]model.Row = undefined;
    try std.testing.expectError(error.UnknownItem, adapter.itemRows(data, &.{"not_an_item"}, &rows));
    try std.testing.expectError(error.UnknownRoster, adapter.targetRows(data, &.{.{ .id = "nobody", .label = "Nobody" }}, &rows));
    try std.testing.expectError(error.UnknownList, serviceRows(data, "not_a_list", &rows));
    try std.testing.expectError(error.BufferTooSmall, adapter.itemRows(data, &.{ "medicine", "needle" }, rows[0..1]));
    try expect(adapter.itemLabel(data, "medicine") != null);
    try expect(adapter.itemLabel(data, "not_an_item") == null);
}

test "port command lists are complete and wrap policy is explicit" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var buffer: [32]model.Row = undefined;
    const battle = try serviceRows(data, "battle_commands", &buffer);
    try expectEqual(@as(usize, 5), battle.len);
    const battle_labels = [_][]const u8{ "Attack", "Defend", "Rune", "Item", "Unite" };
    for (battle_labels, battle) |want, got| try expectEqualStrings(want, got.label);
    var pause_buffer: [32]model.Row = undefined;
    const pause = try serviceRows(data, "pause_commands", &pause_buffer);
    try expectEqual(@as(usize, 11), pause.len);
    try expectEqualStrings("Return", pause[10].label);
    // Only the root wrap is source-proven; every other list keeps its existing
    // port clamp/wrap behaviour and says so in the packet.
    for (data.lists) |list| {
        try expect(std.mem.eql(u8, list.key, "root") == list.wrap);
        try expect(list.wrap_evidence.len > 0);
    }
}

test "window packet pins the six descriptor tables and their bounds" {
    var opened = try Opened.init();
    defer opened.deinit();
    const expected = [_]struct { key: []const u8, count: usize, width: u16, rows: u16 }{
        .{ .key = "root", .count = 17, .width = 26, .rows = 10 },
        .{ .key = "shop", .count = 10, .width = 20, .rows = 9 },
        .{ .key = "blacksmith", .count = 9, .width = 22, .rows = 9 },
        .{ .key = "rune", .count = 8, .width = 22, .rows = 9 },
        .{ .key = "appraiser", .count = 10, .width = 22, .rows = 9 },
        .{ .key = "discard", .count = 3, .width = 20, .rows = 9 },
    };
    for (expected) |want| {
        const window = opened.value.window(want.key) orelse return error.MissingWindow;
        try expectEqual(want.count, window.count);
        try expectEqual(want.count, window.rows.len);
        try expectEqual(want.width, window.window.text_width);
        try expectEqual(want.rows, window.window.visible_rows);
    }
}

test "page labels expose the visible range and boundary markers" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var ids: [packet.admitted_items][]const u8 = undefined;
    for (data.items, 0..) |item, index| ids[index] = item.id;
    var rows: [packet.admitted_items]model.Row = undefined;
    const built = try adapter.itemRows(data, &ids, &rows);
    var menu = menu_mod.menu();
    var buffer: [48]u8 = undefined;
    try expectEqualStrings("0/0", menu.pageLabel(&buffer));
    menu.open(.bag, built, .{ .window_rows = 9, .columns = 20 });
    var expected_buf: [32]u8 = undefined;
    try expectEqualStrings(try std.fmt.bufPrint(&expected_buf, "1-9/{d} v", .{packet.admitted_items}), menu.pageLabel(&buffer));
    _ = menu.receiveKey(.down);
    try expectEqualStrings(try std.fmt.bufPrint(&expected_buf, "1-9/{d} v", .{packet.admitted_items}), menu.pageLabel(&buffer));
    try expect(menu.selectIndex(.bag, 50));
    try expectEqualStrings(try std.fmt.bufPrint(&expected_buf, "43-51/{d} ^ v", .{packet.admitted_items}), menu.pageLabel(&buffer));
    try expect(menu.selectIndex(.bag, packet.admitted_items - 1));
    try expectEqualStrings(try std.fmt.bufPrint(&expected_buf, "{d}-{d}/{d} ^", .{ packet.admitted_items - 8, packet.admitted_items, packet.admitted_items }), menu.pageLabel(&buffer));
}

test "snapshot is an independent value and restore bumps the epoch" {
    var opened = try Opened.init();
    defer opened.deinit();
    const data = opened.data();
    var buffer: [16]model.Row = undefined;
    const rows = try serviceRows(data, "shop", &buffer);
    var menu = menu_mod.menu();
    menu.open(.shop, rows, .{ .window_rows = 3, .columns = 20 });
    try expect(menu.selectIndex(.shop, 1));
    const saved = menu.snapshot();
    const epoch = menu.epoch;
    try expect(menu.selectIndex(.shop, 2));
    try expectEqual(@as(usize, 2), menu.activeScreen().cursor);
    // The snapshot is a value, not a view into the live screen.
    try expectEqual(@as(usize, 1), saved.slots[@backingInt(model.Source.shop)].cursor);
    menu.restore(saved);
    try expect(menu.epoch != epoch);
    try expectEqual(@as(usize, 1), menu.activeScreen().cursor);
    try expect(!menu.activeScreen().opened);
}
