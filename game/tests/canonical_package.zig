const std = @import("std");
const field = @import("field");
const merge = @import("opening_package");
const battle = @import("battle");
const journey = @import("journey");
const party_session = @import("party_session");
const party_data = @import("party_data");
const event_runtime = @import("event_runtime");
const pause_menu = @import("pause_menu");
const journey_content = @import("journey_content");
const journey_boot = @import("journey_boot");
const party_content = @import("party_content");

test "packaged optional games admit from field input and settle before returning" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var save_dir = std.testing.tmpDir(.{});
    defer save_dir.cleanup();
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    state.combat.progress.money = 1500;
    state.field_state.progress.money = 1500;
    const action: pause_menu.Input = .{ .field = .{ .action = true } };
    const cancel: pause_menu.Input = .{ .field = .{ .cancel = true } };

    try openSideGame(&state, "va2_room_0", .{ .x = 416, .y = 520 });
    try std.testing.expect(state.dice_host.?.session.? == .coin);
    try std.testing.expectError(error.GameBusy, journey.Snapshot.capture(state));
    _ = try state.tickWithFieldEvents(action, .{});
    for (0..500) |_| {
        if (state.dice_host.?.session.?.coin.phase == .choice and
            state.side_game.?.shuffle_ticks == journey.side_games.shuffle_frames) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expectEqual(.choice, state.dice_host.?.session.?.coin.phase);
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    for (0..500) |_| {
        if (state.dice_host.?.session.?.coin.phase == .acknowledged) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    const coin = state.dice_host.?.session.?.coin;
    try std.testing.expectEqual(.acknowledged, coin.phase);
    try std.testing.expectEqual(if (coin.win) @as(u32, 1500) + coin.stake else 1500 - coin.stake, state.combat.progress.money);
    try std.testing.expectEqual(state.combat.progress.money, state.field_state.progress.money);
    _ = try state.tickWithFieldEvents(cancel, .{});
    try std.testing.expect(state.side_game == null);
    try std.testing.expectEqualStrings("va2_room_0", currentRoomName(&state));

    try openSideGame(&state, "vb5c3_room_0", .{ .x = 360, .y = 312 });
    try std.testing.expect(state.dice_host.?.session.? == .coin);
    _ = try state.tickWithFieldEvents(cancel, .{});
    try openSideGame(&state, "vb5c3_room_0", .{ .x = 440, .y = 248 });
    try std.testing.expect(state.dice_host.?.session.? == .karuta);
    _ = try state.tickWithFieldEvents(action, .{});
    for (0..300) |_| {
        if (state.dice_host.?.session.?.karuta.phase == .play) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expectEqual(.play, state.dice_host.?.session.?.karuta.phase);
    const money = state.combat.progress.money;
    for (0..24) |_| {
        const cards = state.dice_host.?.session.?.karuta;
        if (cards.phase == .proposal) break;
        const pair = findCardPair(cards) orelse return error.NoCardPair;
        for (pair) |index| {
            const columns = cards.rules.columns;
            while (state.dice_host.?.session.?.karuta.cursor_row != index / columns)
                _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
            while (state.dice_host.?.session.?.karuta.cursor_column != index % columns)
                _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
            _ = try state.tickWithFieldEvents(action, .{});
            for (0..300) |_| {
                if (state.dice_host.?.session.?.karuta.boardStable()) break;
                _ = try state.tickWithFieldEvents(.{}, .{});
            }
        }
    }
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(.acknowledged, state.dice_host.?.session.?.karuta.phase);
    try std.testing.expect(state.optional_games.card_records[0] != 0);
    try std.testing.expectEqual(money, state.combat.progress.money);
    _ = try state.tickWithFieldEvents(cancel, .{});
    try std.testing.expect(state.side_game == null);
    try std.testing.expectEqualStrings("vb5c3_room_0", currentRoomName(&state));

    try journey.saveSlot(io, allocator, save_dir.dir, state, 0, state.menu.save_label);
    var restored_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&restored_members);
    _ = try journey.restoreSlotWithSource(io, allocator, save_dir.dir, &restored, 0);
    try std.testing.expectEqualDeep(state.optional_games, restored.optional_games);
    try std.testing.expectEqual(money, restored.combat.progress.money);
}

fn openSideGame(state: *journey.State, room: []const u8, point: field.Point) !void {
    state.field_state.enterRoom(state.package.roomIndex(room).?, point);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
    for (0..16) |_| {
        if (state.side_game != null) return;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    return error.MissingOptionalGame;
}

fn findCardPair(cards: journey.dice.games.contracts.KarutaSession) ?[2]usize {
    for (cards.cells, 0..) |first, i| {
        if (first.state != .face_down) continue;
        for (cards.cells[i + 1 ..], i + 1..) |second, j| {
            if (second.state == .face_down and second.face == first.face) return .{ i, j };
        }
    }
    return null;
}

test "packaged vault opens from its attendant and returns a deposited item" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    state.field_state.enterRoom(state.package.roomIndex("vb5b2_room_0").?, .{ .x = 88, .y = 240 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    const action: pause_menu.Input = .{ .field = .{ .action = true } };
    const cancel: pause_menu.Input = .{ .field = .{ .cancel = true } };
    const bag = &state.combat.progress.party[0].inventory;
    const slot = bag.count();
    try std.testing.expect(try bag.receive(.medicine));
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
    try std.testing.expect(state.field_event != null);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqual(.storage, state.menu.phase);

    _ = try state.tickWithFieldEvents(action, .{});
    for (0..slot) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(@as(usize, 1), state.combat.progress.storage.count());
    try std.testing.expectEqual(slot, bag.count());
    for (0..2) |_| _ = try state.tickWithFieldEvents(cancel, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(@as(usize, 0), state.combat.progress.storage.count());
    try std.testing.expectEqual(slot + 1, bag.count());
    for (0..3) |_| _ = try state.tickWithFieldEvents(cancel, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);
}

test "packaged headquarters tablets browse the live roster and return to the field" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    state.combat.progress.story.scenario.?.recruit_flags = @splat(0);
    state.combat.progress.story.scenario.?.recruit_flags[8] = 1;
    state.combat.progress.story.scenario.?.recruit_flags[26] = 1;
    state.combat.progress.story.scenario.?.recruit_flags[30] = 2;
    const story = state.combat.progress.story;
    const rooms = [_]struct { id: []const u8, positions: [4]field.Point }{
        .{ .id = "vb5a2_room_0", .positions = .{ .{ .x = 296, .y = 152 }, .{ .x = 312, .y = 152 }, .{ .x = 328, .y = 152 }, .{ .x = 312, .y = 168 } } },
        .{ .id = "vb5b3_room_0", .positions = .{ .{ .x = 56, .y = 80 }, .{ .x = 72, .y = 80 }, .{ .x = 88, .y = 80 }, .{ .x = 88, .y = 128 } } },
        .{ .id = "vb5c3_room_0", .positions = .{ .{ .x = 80, .y = 80 }, .{ .x = 96, .y = 80 }, .{ .x = 112, .y = 80 }, .{ .x = 272, .y = 216 } } },
    };
    for (rooms) |room| {
        for (room.positions) |position| {
            errdefer std.debug.print("Tablet caller {s} at ({d}, {d})\n", .{ room.id, position.x, position.y });
            state.field_state.enterRoom(state.package.roomIndex(room.id).?, position);
            _ = try state.tickWithFieldEvents(.{}, .{});
            try interactFacing(&state, .up, &.{});
            try std.testing.expectEqual(.tablet, state.menu.phase);
            try std.testing.expectEqual(@as(u16, 3), state.menu.tablet_view.?.listedCount());
            _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
            try std.testing.expect(state.menu.tablet_view.?.listed(1));
            _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
            try std.testing.expect(state.menu.tablet_view.?.lastReveal() == null);
            _ = try state.tickWithFieldEvents(.{ .left = true }, .{});
            _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
            try std.testing.expectEqual(@as(u8, 8), state.menu.tablet_view.?.lastReveal().?.recruit_index);
            _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
            try std.testing.expectEqual(.closed, state.menu.phase);
            try std.testing.expect(state.menu.tablet_view == null);
            try std.testing.expectEqualDeep(story, state.combat.progress.story);
        }
    }
}

test "packaged library collects books and reopens donated volumes after reload" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var save_dir = std.testing.tmpDir(.{});
    defer save_dir.cleanup();
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const room = state.package.roomIndex("vb5c3_room_0").?;
    var checkpoint: []const u8 = "availability";
    errdefer std.debug.print("Library check {s} in {s} at ({d}, {d}), menu {s}, visit {d}\n", .{
        checkpoint, currentRoomName(&state), state.field_state.x, state.field_state.y, @tagName(state.menu.phase), state.field_state.room_entries,
    });
    state.field_state.enterRoom(room, .{ .x = 72, .y = 448 });
    state.field_state.facing = .up;
    const action: pause_menu.Input = .{ .field = .{ .action = true, .direction = .up } };
    const cancel: pause_menu.Input = .{ .field = .{ .cancel = true } };
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expect(state.field_event == null);
    try std.testing.expectEqual(.closed, state.menu.phase);
    state.combat.progress.story.scenario.?.recruit_flags[93] = 1;
    checkpoint = "empty shelf";
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqual(.library, state.menu.phase);
    try std.testing.expectEqual(@as(u8, 0), state.combat.progress.story.scenario.?.library_books);
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(.library, state.menu.phase);
    _ = try state.tickWithFieldEvents(cancel, .{});

    checkpoint = "donation";
    state.shared_items = try state.bindSharedItems(.{ "old_book_vol_2", "water_crystal", "old_book_vol_8", "old_book_vol_2", null, null, null });
    const bag = &state.combat.progress.party[0].inventory;
    const previous_count = bag.count();
    try std.testing.expect(try bag.receive(.old_book_vol_3));
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqual(@as(u8, 0b10000110), state.combat.progress.story.scenario.?.library_books);
    try std.testing.expectEqual(previous_count, bag.count());
    try std.testing.expectEqualStrings("water_crystal", state.shared_items[0].?);
    try std.testing.expect(state.shared_items[1] == null);
    try std.testing.expectEqual(@as(usize, 1), state.menu.slot);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .up } }, .{});
    try std.testing.expectEqual(@as(usize, 7), state.menu.slot);
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(.library_reading, state.menu.phase);
    _ = try state.tickWithFieldEvents(cancel, .{});
    _ = try state.tickWithFieldEvents(cancel, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);

    checkpoint = "reload";
    try journey.saveSlot(io, allocator, save_dir.dir, state, 0, state.menu.save_label);
    var restored_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&restored_members);
    _ = try journey.restoreSlotWithSource(io, allocator, save_dir.dir, &restored, 0);
    try std.testing.expectEqual(@as(u8, 0b10000110), restored.combat.progress.story.scenario.?.library_books);
    try std.testing.expectEqualDeep(state.shared_items, restored.shared_items);
    _ = try restored.tickWithFieldEvents(action, .{});
    _ = try drainFieldEvent(&restored, &.{});
    try std.testing.expectEqual(.library, restored.menu.phase);
    try std.testing.expectEqual(@as(usize, 1), restored.menu.slot);
    _ = try restored.tickWithFieldEvents(cancel, .{});
    checkpoint = "second caller";
    try walkTo(allocator, &restored, null, 64, 376, &.{});
    try interactFacing(&restored, .up, &.{});
    try std.testing.expectEqual(.library, restored.menu.phase);
    try std.testing.expectEqual(@as(u8, 0b10000110), restored.combat.progress.story.scenario.?.library_books);
}

test "packaged window styles collect sets, skip locked choices, and persist appearance" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    setScenarioBit(&state, 36, 0x80);
    state.field_state.enterRoom(state.package.roomIndex("vb5ca_room_3").?, .{ .x = 56, .y = 144 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    const bag = &state.combat.progress.party[0].inventory;
    const count = bag.count();
    try std.testing.expect(try bag.receive(.window_setting_0));
    state.shared_items = try state.bindSharedItems(.{ "window_setting_2", "water_crystal", null, null, null, null, null });
    try interactFacing(&state, .up, &.{1});
    try std.testing.expectEqual(.closed, state.menu.phase);
    try std.testing.expectEqual(count + 1, bag.count());
    try std.testing.expectEqual(@as(u8, 0x80), state.combat.progress.story.scenario.?.scenario[36]);
    try interactFacing(&state, .up, &.{0});
    try std.testing.expectEqual(.window_style, state.menu.phase);
    try std.testing.expectEqual(count, bag.count());
    try std.testing.expectEqualStrings("water_crystal", state.shared_items[0].?);
    try std.testing.expect(state.shared_items[1] == null);
    try std.testing.expectEqual(@as(u8, 0x85), state.combat.progress.story.scenario.?.scenario[36]);
    const appearance = &state.combat.progress.story.scenario.?.window_appearance;
    const action: pause_menu.Input = .{ .field = .{ .action = true } };
    try std.testing.expect(appearance.isDefault());
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    try std.testing.expectEqual(.rounded, appearance.style);
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    try std.testing.expectEqual(.corners, appearance.style);
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(.window_color, state.menu.phase);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    try std.testing.expectEqual(.plum, appearance.color);
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);

    try journey.saveSlot(io, allocator, directory.dir, state, 0, state.menu.save_label);
    var restored_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&restored_members);
    _ = try journey.restoreSlotWithSource(io, allocator, directory.dir, &restored, 0);
    try std.testing.expectEqualDeep(appearance.*, restored.combat.progress.story.scenario.?.window_appearance);
    try std.testing.expectEqual(@as(u8, 0x85), restored.combat.progress.story.scenario.?.scenario[36]);
    var invalid = try journey.Snapshot.capture(restored);
    invalid.story.scenario.?.window_appearance.style = .inset;
    try std.testing.expectError(error.InvalidSave, invalid.validate(restored));

    _ = try restored.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
    for (0..32) |_| _ = try restored.tickWithFieldEvents(.{}, .{});
    var draw_list: journey.field_dialogue_view.presentation.List = .{};
    try restored.composeFieldBattleDialogue(harness.bundle.ui.?, &draw_list);
    const displayed = for (draw_list.pieces[0..draw_list.length]) |piece| {
        if (piece == .styled_window) break piece.styled_window.appearance;
    } else return error.MissingStyledWindow;
    try std.testing.expectEqualDeep(appearance.*, displayed);
}

test "packaged sound themes admit from both Melodye callers and restore the confirmed theme" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    setScenarioBit(&state, 36, 1);
    state.field_state.enterRoom(state.package.roomIndex("vb5ba_room_3").?, .{ .x = 88, .y = 112 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    const bag = &state.combat.progress.party[0].inventory;
    const count = bag.count();
    try std.testing.expect(try bag.receive(.sound_setting_0));
    state.shared_items = try state.bindSharedItems(.{ "sound_setting_2", "water_crystal", null, null, null, null, null });
    try interactFacing(&state, .up, &.{1});
    try std.testing.expectEqual(.closed, state.menu.phase);
    try std.testing.expectEqual(count + 1, bag.count());
    try interactFacing(&state, .up, &.{0});
    try std.testing.expectEqual(.sound_theme, state.menu.phase);
    try std.testing.expectEqual(count, bag.count());
    try std.testing.expectEqualStrings("water_crystal", state.shared_items[0].?);
    try std.testing.expect(state.shared_items[1] == null);
    try std.testing.expectEqual(@as(u8, 0x51), state.combat.progress.story.scenario.?.scenario[36]);

    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    try std.testing.expectEqual(.chime, state.menu.sound_theme_cursor);
    try std.testing.expectEqual(@as(?u16, 0x502), state.takeFieldSound());
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    try std.testing.expectEqual(.pulse, state.menu.sound_theme_cursor);
    try std.testing.expectEqual(.standard, state.combat.progress.story.scenario.?.sound_theme);
    try std.testing.expectEqual(@as(?u16, 0x502), state.takeFieldSound());
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(.pulse, state.combat.progress.story.scenario.?.sound_theme);
    try std.testing.expectEqual(.sound_theme, state.menu.phase);
    try std.testing.expectEqual(@as(?u16, 0x504), state.takeFieldSound());
    const cancel: pause_menu.Input = .{ .field = .{ .cancel = true } };
    _ = try state.tickWithFieldEvents(cancel, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);
    try std.testing.expectEqual(@as(?u16, 0x503), state.takeFieldSound());
    try std.testing.expect(state.takeFieldSound() == null);

    try journey.saveSlot(io, allocator, directory.dir, state, 0, state.menu.save_label);
    var restored_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&restored_members);
    _ = try journey.restoreSlotWithSource(io, allocator, directory.dir, &restored, 0);
    try std.testing.expectEqual(.pulse, restored.combat.progress.story.scenario.?.sound_theme);
    var invalid = try journey.Snapshot.capture(restored);
    invalid.story.scenario.?.sound_theme = .pluck;
    try std.testing.expectError(error.InvalidSave, invalid.validate(restored));

    restored.field_state.enterRoom(restored.package.roomIndex("vb5ca_room_3").?, .{ .x = 144, .y = 96 });
    _ = try restored.tickWithFieldEvents(.{}, .{});
    try interactFacing(&restored, .up, &.{0});
    try std.testing.expectEqual(.pulse, restored.menu.sound_theme_cursor);
    _ = try restored.tickWithFieldEvents(.{ .left = true }, .{});
    try std.testing.expectEqual(.chime, restored.menu.sound_theme_cursor);
    _ = try restored.tickWithFieldEvents(cancel, .{});
    try std.testing.expectEqual(.closed, restored.menu.phase);
    try std.testing.expectEqual(.pulse, restored.combat.progress.story.scenario.?.sound_theme);
}

test "packaged Kasios offers all 16 tracks and clears playback on exit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    state.field_state.enterRoom(state.package.roomIndex("vb5a1_room_1").?, .{ .x = 232, .y = 192 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    try interactFacing(&state, .up, &.{1});
    try std.testing.expectEqual(.closed, state.menu.phase);
    try interactFacing(&state, .up, &.{0});
    try std.testing.expectEqual(.jukebox, state.menu.phase);
    try std.testing.expect(state.menu.jukeboxTrack() == null);

    const catalogue = state.menu.region_bgm.?;
    try std.testing.expectEqual(16, catalogue.jukebox.len);
    const action: pause_menu.Input = .{ .field = .{ .action = true } };
    const down: pause_menu.Input = .{ .field = .{ .menu_direction = .down } };
    for (catalogue.jukebox, 0..) |track, index| {
        _ = try state.tickWithFieldEvents(action, .{});
        try std.testing.expectEqualStrings(track, state.menu.jukeboxTrack().?);
        try std.testing.expect(catalogue.trackById(track) != null);
        if (index + 1 < catalogue.jukebox.len) _ = try state.tickWithFieldEvents(down, .{});
    }
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expect(state.menu.jukeboxTrack() == null);
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);
    try std.testing.expect(state.menu.jukeboxTrack() == null);

    try journey.saveSlot(io, allocator, directory.dir, state, 0, state.menu.save_label);
    var restored_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&restored_members);
    _ = try journey.restoreSlotWithSource(io, allocator, directory.dir, &restored, 0);
    try std.testing.expectEqual(16, restored.menu.region_bgm.?.jukebox.len);
    restored.mode = .battle;
    restored.combat.phase = .escaped;
    _ = try restored.tickWithFieldEvents(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.field, restored.mode);
    try interactFacing(&restored, .up, &.{0});
    try std.testing.expectEqual(.jukebox, restored.menu.phase);
    try std.testing.expect(restored.menu.jukeboxTrack() == null);
    _ = try restored.tickWithFieldEvents(.{ .right = true }, .{});
    _ = try restored.tickWithFieldEvents(action, .{});
    try std.testing.expectEqualStrings(catalogue.jukebox[8], restored.menu.jukeboxTrack().?);
}

test "packaged teleport has a cancel path and the Blinking Mirror returns to headquarters" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    setScenarioBit(&state, 39, 1);
    state.field_state.enterRoom(state.package.roomIndex("vb5ag_room_2").?, .{ .x = 176, .y = 72 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    const action: pause_menu.Input = .{ .field = .{ .action = true } };
    const talk: pause_menu.Input = .{ .field = .{ .direction = .up, .action = true } };
    _ = try state.tickWithFieldEvents(talk, .{});
    try std.testing.expect(state.field_event != null);
    _ = try drainFieldEvent(&state, &.{1});
    try std.testing.expect(state.teleport_session == null);
    _ = try state.tickWithFieldEvents(talk, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expectEqual(@as(usize, 1), state.teleport_session.?.visibleCount());
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try std.testing.expect(state.teleport_session == null);
    try std.testing.expectEqualStrings("vb5ag_room_2", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(talk, .{});
    _ = try drainFieldEvent(&state, &.{0});
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqualStrings("vb1_room_0", currentRoomName(&state));
    try std.testing.expectEqualStrings("world_b_point_0", state.field_state.worldEntry(state.package).?.id);

    const bag = &state.combat.progress.party[0].inventory;
    const slot = bag.count();
    try std.testing.expect(try bag.receive(.blinking_mirror));
    state.menu.phase = .item_action;
    state.menu.member = 0;
    state.menu.slot = slot;
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expectEqual(.item_notice, state.menu.phase);
    try std.testing.expectEqualStrings("vb1_room_0", currentRoomName(&state));

    const world = state.field_state.worldEntry(state.package).?;
    for ([_][]const u8{ "vb7a_room_2", "vb5ag_room_2" }, 0..) |destination, tier| {
        state.field_state.enterRoom(state.package.roomIndex(world.world_room).?, .{ .x = world.return_x, .y = world.return_y });
        state.field_state.progress.story.scenario.?.castle_tier = @intCast(tier);
        state.combat.progress.story.scenario.?.castle_tier = @intCast(tier);
        state.menu.phase = .item_action;
        _ = try state.tickWithFieldEvents(action, .{});
        try std.testing.expectEqual(.closed, state.menu.phase);
        try std.testing.expectEqualStrings(destination, currentRoomName(&state));
        try std.testing.expect(state.package.rooms[state.field_state.room].canStand(state.field_state.x, state.field_state.y));
        try std.testing.expectEqual(.blinking_mirror, bag.slots[slot].?.id);
    }
}

test "modeled Kaku dice matches plain settlement and RNG through headless acknowledgements" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "../kit/data/reports/dice_presentation.json", allocator, .limited(128 * 1024));
    defer allocator.free(bytes);
    const model = try journey.dice.visual.load(allocator, bytes);
    defer model.deinit();
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    state.dice_model = &model.value;
    state.combat.progress.money = 5000;
    state.field_state.progress.money = 5000;
    state.field_state.enterRoom(state.package.roomIndex("vb2_room_8").?, .{ .x = 176, .y = 120 });
    for (0..20) |_| {
        if (state.dice_game != null) break;
        _ = try state.advanceSimulation(.{});
    }
    try std.testing.expect(state.dice_game != null);
    const entry_music = state.preTickDiceMusic(.{}).?;
    try std.testing.expectEqual(.entry, entry_music);
    const random = state.combat.random;
    _ = try state.advanceSimulation(.{});
    try std.testing.expect(!state.dice_game.?.entry_audio_ready);
    const waiting_tick = state.elapsed_ticks;
    try std.testing.expectError(error.UnexpectedDiceMusicAcknowledgment, state.advanceSimulation(.{ .dice_music_ready = .exit }));
    try std.testing.expectEqual(waiting_tick, state.elapsed_ticks);
    _ = try state.advanceSimulation(.{ .dice_music_ready = entry_music });
    try std.testing.expectEqual(waiting_tick + 1, state.elapsed_ticks);
    try std.testing.expect(state.dice_game.?.entry_audio_ready);
    try std.testing.expect(state.preTickDiceMusic(.{}) == null);
    try std.testing.expectEqual(.allocate, state.dice_game.?.dialogue.phase);
    const step = try state.advanceSimulation(.{});
    try std.testing.expectEqual(.opening, state.dice_game.?.dialogue.phase);
    try std.testing.expect(step.dice_audio.box_opened);
    try std.testing.expectEqualDeep(random, state.combat.random);

    for (0..8000) |_| {
        const active = state.dice_game orelse break;
        if (state.preTickDiceMusic(.{}) != null) break;
        const dice = state.dice_host.?.session.?.dice;
        const aim = if (dice.phase == .player_roll) dice.throw_control else null;
        const pressed: journey.dice.Entry.Buttons = if (active.result != null or dice.phase == .proposal)
            .{ .confirm = true }
        else if (dice.phase == .fixed_prompt)
            .{ .cancel = true }
        else if (aim) |control|
            .{ .up = control.strength < 96, .confirm = control.strength >= 96 and @abs(control.horizontal_pixels - 160) < 5 }
        else
            .{};
        _ = try state.advanceSimulation(.{ .dice = .{ .pressed = pressed } });
    }
    try std.testing.expectEqual(.exit, state.preTickDiceMusic(.{}).?);
    _ = try state.advanceSimulation(.{ .dice_music_ready = .exit });
    try std.testing.expect(state.dice_game.?.exit_ready);
    try std.testing.expectEqual(.restore_area_b, state.preTickDiceMusic(.{}).?);
    try std.testing.expectError(error.UnexpectedDiceMusicAcknowledgment, state.advanceSimulation(.{ .dice_music_ready = .exit }));
    _ = try state.advanceSimulation(.{});
    try std.testing.expect(state.dice_game != null);
    _ = try state.advanceSimulation(.{ .dice_music_ready = .restore_area_b });
    try std.testing.expect(state.dice_game == null);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("vb2_room_6", currentRoomName(&state));
    const money = state.combat.progress.money;
    const won = scenarioBitSet(&state, 12, 1);
    const final_random = state.combat.random;

    var plain_members: [6]battle.Member = undefined;
    var plain = try harness.newState(&plain_members);
    plain.dice_model = null;
    plain.combat.progress.money = 5000;
    plain.field_state.progress.money = 5000;
    plain.field_state.enterRoom(plain.package.roomIndex("vb2_room_8").?, .{ .x = 176, .y = 120 });
    const plain_result = try playFixedDiceWithInput(&plain);
    try std.testing.expectEqual(plain_result.money, money);
    try std.testing.expectEqual(plain_result.won, won);
    try std.testing.expectEqualDeep(plain.combat.random, final_random);
    try std.testing.expectEqualStrings(currentRoomName(&plain), currentRoomName(&state));
}

test "packaged Kaku dice settles the story wager and offers the follow-up game" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    state.combat.progress.money = 5000;
    state.field_state.progress.money = 5000;
    const dice_room = state.package.roomIndex("vb2_room_8").?;
    state.field_state.enterRoom(dice_room, .{ .x = 176, .y = 120 });
    const result = try playFixedDiceWithInput(&state);
    const money = result.money;
    try std.testing.expectEqual(money, state.combat.progress.money);
    try std.testing.expectEqual(result.won, scenarioBitSet(&state, 12, 1));
    try std.testing.expectEqualStrings("vb2_room_6", currentRoomName(&state));

    setScenarioBit(&state, 12, 1);
    state.combat.progress.story.scenario.?.recruit_flags[32] = 1;
    state.field_state.enterRoom(dice_room, .{ .x = 176, .y = 120 });
    for (0..20) |_| {
        if (state.dice_game != null) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expect(state.dice_game != null);
    try std.testing.expectEqual(.profit, state.dice_host.?.session.?.dice.entry.variant);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("vb2_room_6", currentRoomName(&state));
    try std.testing.expectEqual(money, state.combat.progress.money);
}

fn playFixedDiceWithInput(state: *journey.State) !struct { money: u32, won: bool } {
    for (0..20) |_| {
        if (state.dice_game != null) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expect(state.dice_game != null);
    try std.testing.expectEqual(.fixed, state.dice_host.?.session.?.dice.entry.variant);
    const action: pause_menu.Input = .{ .field = .{ .action = true } };
    _ = try state.tickWithFieldEvents(action, .{});
    for (0..3000) |_| {
        const dice = state.dice_host.?.session.?.dice;
        if (dice.phase == .acknowledged) break;
        const aim = if (dice.phase == .player_roll) dice.throw_control else null;
        const raise_strength = if (aim) |control| control.strength < 96 else false;
        const input: pause_menu.Input = .{ .field = .{
            .action = dice.phase == .fixed_prompt or dice.phase == .tie_prompt or
                (aim != null and !raise_strength and @abs(aim.?.horizontal_pixels - 160) < 5),
            .menu_direction = if (raise_strength) .up else null,
        } };
        _ = try state.tickWithFieldEvents(input, .{});
    }
    try std.testing.expectEqual(.acknowledged, state.dice_host.?.session.?.dice.phase);
    const money = state.dice_host.?.wallet.money;
    const won = state.dice_host.?.wallet.dice_flags.fixed_won;
    _ = try state.tickWithFieldEvents(action, .{});
    try std.testing.expect(state.dice_game == null);
    _ = try drainFieldEvent(state, &.{});
    return .{ .money = money, .won = won };
}

test "packaged elevator serves both destinations and the bathhouse returns to the field" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    state.combat.progress.story.scenario.?.recruit_flags[92] = 1;
    const lift = state.package.roomIndex("vb5ag_room_8").?;
    for ([_][]const u8{ "vb5a1_room_0", "vb5a2_room_0" }, 0..) |destination, choice| {
        state.field_state.enterRoom(lift, .{ .x = 176, .y = 160 });
        _ = try state.tickWithFieldEvents(.{}, .{});
        try std.testing.expect(state.field_event != null);
        _ = try drainFieldEvent(&state, &.{@intCast(choice)});
        try std.testing.expectEqualStrings(destination, currentRoomName(&state));
    }
    state.field_state.enterRoom(state.package.roomIndex("vb5b2_room_0").?, .{ .x = 152, .y = 432 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqual(.bathhouse, state.menu.phase);
    const progress = state.combat.progress;
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try drainFieldEvent(&state, &.{});
    _ = try state.tickWithFieldEvents(.{ .left = true, .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(.bath, state.menu.phase);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);
    try std.testing.expectEqualDeep(progress, state.combat.progress);
}

test "packaged floating orb saves and restores field progress" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var save_dir = std.testing.tmpDir(.{});
    defer save_dir.cleanup();
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const room_index = state.package.roomIndex("vc5_room_0").?;
    state.field_state.enterRoom(room_index, .{ .x = 40, .y = 248 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    var effect = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
    for (0..8) |_| {
        if (state.menu.phase != .closed) break;
        effect = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expectEqual(.inspect_saves, effect);
    try std.testing.expectEqual(.save_slots, state.menu.phase);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try std.testing.expectEqual(.closed, state.menu.phase);

    var shared: @TypeOf(state.shared_items) = @splat(null);
    shared[0] = "water_crystal";
    state.shared_items = try state.bindSharedItems(shared);
    setScenarioBit(&state, 1, 16);
    state.field_state.progress.story.scenario.?.recruit_flags[59] = 1;
    state.field_state.progress.money = 4567;
    const inventory = &state.field_state.progress.party[0].inventory;
    const slot = inventory.count();
    try std.testing.expect(try inventory.receive(.medicine));
    try state.field_state.progress.storage.deposit(inventory, slot);

    const action: pause_menu.Input = .{ .field = .{ .action = true } };
    _ = try state.tickWithFieldEvents(action, .{});
    for (0..8) |_| {
        if (state.menu.phase != .closed) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expectEqual(.save_slots, state.menu.phase);
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try state.tickWithFieldEvents(action, .{});
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    try std.testing.expectEqual(.save, try state.tickWithFieldEvents(action, .{}));
    const checkpoint = try journey.Snapshot.capture(state);
    try journey.saveSlot(io, allocator, save_dir.dir, state, state.menu.save_slot, state.menu.save_label);

    var reloaded_members: [6]battle.Member = undefined;
    var reloaded = try harness.newState(&reloaded_members);
    _ = try journey.restoreSlotWithSource(io, allocator, save_dir.dir, &reloaded, state.menu.save_slot);
    try std.testing.expectEqualStrings("vc5_room_0", currentRoomName(&reloaded));
    try std.testing.expectEqual(checkpoint.money, reloaded.field_state.progress.money);
    try std.testing.expectEqualDeep(checkpoint.story, reloaded.field_state.progress.story);
    for (checkpoint.party[0..checkpoint.party_count], reloaded.combat.progress.party) |saved, member| try std.testing.expectEqualDeep(saved, member.record());
    try std.testing.expectEqualDeep(checkpoint.storage.?, reloaded.field_state.progress.storage);
    try std.testing.expectEqualDeep(checkpoint.shared_items.?, reloaded.shared_items);
}

test "packaged floating orb interaction opens save slots at every bound endpoint" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    // The mansion's first visit runs an automatic scene before accepting field actions.
    setScenarioBit(&state, 0, 128);
    var count: usize = 0;
    for (state.room_battles.?.bindings) |binding| {
        for (binding.content.programs) |program| {
            if (program.commands.len != 2) continue;
            const saves = for (program.commands) |command| {
                if (command.kind == .service and command.facility == .save_point) break true;
            } else false;
            if (!saves) continue;
            errdefer std.debug.print("Save orb {s}/{d}\n", .{ binding.room, program.entity });
            const point = binding.interactionPosition(program.entity, null) orelse return error.MissingSaveOrbPosition;
            const room_index = state.package.roomIndex(binding.room).?;
            const room = state.package.rooms[room_index];
            for (std.enums.values(field.Direction)) |direction| {
                const offset = state.package.interaction_offsets[@backingInt(direction)];
                const stand: field.Point = .{ .x = point.x - offset.x, .y = point.y - offset.y };
                if (!room.canStand(stand.x, stand.y)) continue;
                state.field_state.enterRoom(room_index, stand);
                var effect = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = direction } }, .{});
                if (state.field_event) |event| try std.testing.expectEqualStrings(program.id, event.session.instance.?.program_id);
                for (0..8) |_| {
                    if (state.menu.phase != .closed) break;
                    effect = try state.tickWithFieldEvents(.{}, .{});
                }
                try std.testing.expectEqual(.inspect_saves, effect);
                try std.testing.expectEqual(.save_slots, state.menu.phase);
                _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
                try std.testing.expectEqual(.closed, state.menu.phase);
                count += 1;
                break;
            } else return error.UnreachableSaveOrb;
        }
    }
    try std.testing.expectEqual(@as(usize, 16), count);
}

test "packaged field attendants let the party rest, decline, or open save slots" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const offers = [_]struct { room: []const u8, position: field.Point, rest: u8, leave: u8, save: u8 }{
        .{ .room = "vf3_room_1", .position = .{ .x = 304, .y = 144 }, .rest = 0, .leave = 1, .save = 2 },
        .{ .room = "vh1_room_1", .position = .{ .x = 424, .y = 96 }, .rest = 2, .leave = 0, .save = 1 },
    };
    for (offers) |offer| {
        const money = state.combat.progress.money;
        state.combat.progress.party[0].hp = 1;
        state.field_state.enterRoom(state.package.roomIndex(offer.room).?, offer.position);
        _ = try state.tickWithFieldEvents(.{}, .{});
        try interactFacing(&state, .up, &.{offer.leave});
        try std.testing.expectEqual(.closed, state.menu.phase);
        try std.testing.expectEqual(@as(u16, 1), state.combat.progress.party[0].hp);
        try interactFacing(&state, .up, &.{offer.save});
        try std.testing.expectEqual(.save_slots, state.menu.phase);
        _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
        try std.testing.expectEqual(.closed, state.menu.phase);
        try std.testing.expectEqual(@as(u16, 1), state.combat.progress.party[0].hp);
        try interactFacing(&state, .up, &.{offer.rest});
        try std.testing.expectEqual(.closed, state.menu.phase);
        try std.testing.expectEqual(state.combat.progress.party[0].max_hp, state.combat.progress.party[0].hp);
        try std.testing.expectEqual(money, state.combat.progress.money);
    }
}

test "packaged closed inn variants return to the field without opening a service menu" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const variants = [_]struct { room: []const u8, position: field.Point, story9: u8, story10: u8, program: []const u8 }{
        .{ .room = "va3_room_2", .position = .{ .x = 336, .y = 208 }, .story9 = 0, .story10 = 0, .program = "va3_room_2_e10_interaction" },
        .{ .room = "va3_room_2", .position = .{ .x = 288, .y = 256 }, .story9 = 16 | 32, .story10 = 0, .program = "va3_room_2_e26_interaction" },
        .{ .room = "va3_room_2", .position = .{ .x = 336, .y = 208 }, .story9 = 0, .story10 = 2 | 4, .program = "va3_room_2_e27_interaction" },
        .{ .room = "vz3_room_2", .position = .{ .x = 336, .y = 208 }, .story9 = 0, .story10 = 4, .program = "vz3_room_2_e04_interaction" },
    };
    for (variants) |variant| {
        errdefer std.debug.print("Closed inn variant {s}\n", .{variant.program});
        state.combat.progress.story.scenario.?.scenario[9] = variant.story9;
        state.combat.progress.story.scenario.?.scenario[10] = variant.story10;
        state.field_state.enterRoom(state.package.roomIndex(variant.room).?, variant.position);
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
        const event = state.field_event orelse return error.MissingInnResponse;
        try std.testing.expectEqualStrings(variant.program, event.session.instance.?.program_id);
        _ = try drainFieldEvent(&state, &.{});
        try std.testing.expectEqual(.closed, state.menu.phase);
        try std.testing.expect(state.field_state.pending_service == null);
    }
}

test "source scenery models and draw bindings require versioned room data" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    const state = try harness.newState(&members);
    var count: usize = 0;
    for (state.package.rooms) |room| if (room.scenery_model) |model| {
        const initial = try field.scenery.State.init(model);
        try initial.validate(model);
        try std.testing.expectEqual(model.initial_count, initial.count);
        count += 1;
    };
    try std.testing.expectEqual(state.room_battles.?.bindings.len, count);
    const model = state.package.rooms[state.package.roomIndex("va1_room_2").?].scenery_model.?;
    const fixture = try std.json.parseFromSlice(struct { model: field.scenery.Model }, allocator, @embedFile("fixtures/field_scenery.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings(fixture.value.model.terrain, model.terrain);
    try std.testing.expectEqualDeep(fixture.value.model.objects[0..model.initial_count], model.objects[0..model.initial_count]);
    try std.testing.expectEqual(@as(usize, 42), model.objects.len);
    var legacy = state.package;
    legacy.schema = field.Package.world_entry_schema;
    try std.testing.expectError(error.InvalidFieldScenery, legacy.validate());
    legacy.schema = field.Package.scenery_model_schema;
    try std.testing.expectError(error.InvalidFieldSceneryDraw, legacy.validate());
    const rooms = try allocator.dupe(field.Room, state.package.rooms);
    defer allocator.free(rooms);
    const room_index = state.package.roomIndex("va1_room_2").?;
    const draws = try allocator.dupe(field.Draw, rooms[room_index].draws);
    defer allocator.free(draws);
    rooms[room_index].draws = draws;
    var malformed = state.package;
    malformed.rooms = rooms;
    const index = for (draws, 0..) |draw, i| {
        if (draw.scenery_object != null) break i;
    } else unreachable;
    draws[index].scenery_object = @intCast(model.objects.len);
    try std.testing.expectError(error.InvalidFieldSceneryDraw, malformed.validate());
    draws[index].scenery_object = 0;
    draws[index].prop = 0;
    try std.testing.expectError(error.InvalidFieldSceneryDraw, malformed.validate());
}

test "canonical scenery insertions settle on room entry" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const Case = struct {
        room: []const u8,
        flag: usize = 0,
        mask: u8 = 0,
        spawn: ?field.Point = null,
        inserted: []const u16,
        staged: []const u16 = &.{},
    };
    const cases = [_]Case{
        .{ .room = "va1_room_2", .flag = 1, .mask = 16, .inserted = &.{ 40, 41 }, .staged = &.{18} },
        .{ .room = "va1_room_2", .spawn = .{ .x = 80, .y = 288 }, .inserted = &.{ 40, 41 }, .staged = &.{18} },
        .{ .room = "va2_room_0", .flag = 7, .mask = 1, .inserted = &.{ 41, 42, 43, 44 }, .staged = &.{ 39, 40 } },
        .{ .room = "va2_room_0", .flag = 7, .mask = 4, .inserted = &.{ 45, 46, 47, 48 } },
        .{ .room = "vb3_room_14", .inserted = &.{3} },
        .{ .room = "vc1_room_5", .flag = 16, .mask = 64, .inserted = &.{ 2, 3, 4, 5, 6, 7 } },
        .{ .room = "vc3_room_5", .inserted = &.{ 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 } },
        .{ .room = "vc3_room_5", .flag = 16, .mask = 32, .inserted = &.{ 22, 23, 24 } },
        .{ .room = "vc3_room_21", .inserted = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 } },
        .{ .room = "vc3_room_21", .flag = 22, .mask = 4, .inserted = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } },
        .{ .room = "vc6_room_14", .flag = 18, .mask = 32, .inserted = &.{1}, .staged = &.{0} },
    };
    for (cases) |fixture| {
        errdefer std.debug.print("scenery entry in {s} with scenario[{d}] = {d}\n", .{ fixture.room, fixture.flag, fixture.mask });
        const room_index = state.package.roomIndex(fixture.room).?;
        const room = state.package.rooms[room_index];
        const model = room.scenery_model.?;
        const first = std.mem.indexOfScalar(u8, room.walkable, '1').?;
        const spawn: field.Point = fixture.spawn orelse .{
            .x = @intCast((first % model.columns) * 8),
            .y = @intCast((first / model.columns) * 8),
        };
        var story = state.room_battles.?.initial_story;
        story.scenario = @splat(0);
        story.scenario[fixture.flag] = fixture.mask;
        state.field_state.progress.story.scenario = story;
        state.combat.progress.story.scenario = story;
        state.field_state.enterRoom(room_index, spawn);
        try state.initializeRoomVisit();

        const scenery = if (state.field_state.room_scenery) |*value| value else return error.MissingFieldSceneryState;
        try scenery.validate(model);
        const inserted = scenery.instances[model.initial_count..scenery.count];
        try std.testing.expectEqual(fixture.inserted.len, inserted.len);
        for (fixture.inserted, inserted) |object, instance| {
            try std.testing.expectEqualDeep(model.initial(object), instance);
        }
        for (scenery.instances[0..model.initial_count], 0..) |instance, index| {
            const staged = std.mem.indexOfScalar(u16, fixture.staged, @intCast(index)) != null;
            if (staged) {
                try std.testing.expect(!instance.active());
            } else {
                try std.testing.expectEqualDeep(model.initial(index), instance);
            }
        }
        if (std.mem.eql(u8, room.id, "vc1_room_5")) {
            for (scenery.instances[2..6], 2..) |instance, object_id| {
                try std.testing.expectEqual(object_id, instance.object);
                try std.testing.expect(!model.objects[instance.object].collides);
                try std.testing.expect(std.mem.allEqual(u8, model.objects[instance.object].mask, '0'));
            }
        }
    }
}

test "camera push packet admission requires its version and shared motion host" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    const state = try harness.newState(&members);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../kit/work/build/canonical/battle/field_events.json", allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    var document = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer document.deinit();
    const push = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"kind":"camera_push","push":{"dx":-16,"dy":-8,"updates":8,"repeats":256},"wait":{"kind":"camera_push","id":"camera_push"}}
    , .{});
    defer push.deinit();
    const Rooms = @TypeOf(state.room_battles.?.*);
    document.value.object.getPtr("schema").?.* = .{ .string = Rooms.scenery_mutation_schema };
    const rooms = &document.value.object.getPtr("rooms").?.array;
    var stairs = for (rooms.items) |room| {
        if (std.mem.eql(u8, room.object.get("room").?.string, "va4_room_6")) break room;
    } else return error.MissingCameraPushRoom;
    const content = stairs.object.getPtr("content").?;
    content.object.getPtr("schema").?.* = .{ .string = event_runtime.camera_push_schema };
    try content.object.put(document.arena.allocator(), "forward_branches", .{ .bool = true });
    const population = stairs.object.getPtr("population").?;
    population.object.getPtr("schema").?.* = .{ .string = "suikoden-scene-population/3" };
    for (population.object.getPtr("programs").?.array.items) |*reference|
        reference.object.getPtr("namespace").?.* = .{ .string = event_runtime.camera_push_schema };
    for (content.object.getPtr("programs").?.array.items) |*program| {
        if (program.object.get("entity").?.integer == 1)
            try program.object.getPtr("commands").?.array.insert(0, push.value);
    }
    rooms.items[0] = stairs;
    rooms.items.len = 1;
    _ = document.value.object.orderedRemove("opening_battles");
    _ = document.value.object.orderedRemove("opening_world_exits");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const qualified = try std.json.Stringify.valueAlloc(allocator, document.value, .{});
    defer allocator.free(qualified);
    _ = try Rooms.open(arena.allocator(), qualified, state.package);
    document.value.object.getPtr("schema").?.* = .{ .string = "suikoden-battle-field-events/50" };
    const downgraded = try std.json.Stringify.valueAlloc(allocator, document.value, .{});
    defer allocator.free(downgraded);
    try std.testing.expectError(error.UnsupportedBattleFieldCommand, Rooms.open(arena.allocator(), downgraded, state.package));
}

test "source camera pushes intercept held input and retain the decoded endpoint" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    var binding = state.room_battles.?.bindingFor("va4_room_6").?;
    var party_ids: [6]u8 = undefined;
    for (state.field_state.progress.party, 0..) |member, i| party_ids[i] = state.combat.integration.?.host.characterId(member.id).?;
    binding.party = party_ids[0..state.field_state.progress.party.len];
    for ([_]field.Direction{ .left, .right }) |direction| {
        state.field_state.enterRoom(state.package.roomIndex(binding.room).?, .{ .x = 248, .y = 64 });
        try std.testing.expect(state.package.rooms[state.field_state.room].canStand(248, 64));
        var session: @import("field_events").Session = undefined;
        try std.testing.expect(!try session.beginRoomEvent(binding, state.field_state, 1, null, .ordinary, null));
        try std.testing.expect(try session.beginRoomEvent(binding, state.field_state, 1, null, .ordinary, direction));
        const program = binding.content.program(session.instance.?.program_id).?;
        try std.testing.expectEqual(@as(u8, if (direction == .left) 2 else 3), program.entity);
        const push = program.commands[1].push.?;
        // The source stream has no reloop: facing owns the first update.
        _ = try session.tick(binding, &state.field_state, false);
        try std.testing.expect(session.camera_push == null);
        try std.testing.expectEqual(@as(i32, 248), state.field_state.x);
        for (0..8) |_| {
            _ = try session.tick(binding, &state.field_state, false);
            try session.validate(binding);
        }
        _ = try session.tick(binding, &state.field_state, false);
        try std.testing.expect(!session.busy());
        try std.testing.expectEqual(@as(i32, 248) + push.dx, state.field_state.x);
        try std.testing.expectEqual(@as(i32, 64) + push.dy, state.field_state.y);
    }
    state.field_state.enterRoom(state.package.roomIndex(binding.room).?, .{ .x = 248, .y = 64 });
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .left } }, .{});
    try std.testing.expect(state.field_event != null);
    try std.testing.expectEqual(@as(i32, 248), state.field_state.x);
    for (0..9) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expect(state.field_event == null);
    try std.testing.expectEqual(@as(i32, 232), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 56), state.field_state.y);
    const snapshot = try journey.Snapshot.capture(state);
    try snapshot.validate(state);
    state.field_state.enterRoom(state.package.roomIndex(binding.room).?, .{ .x = 232, .y = 56 });
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .left } }, .{});
    for (0..9) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expect(state.field_event == null);
    try std.testing.expectEqualDeep(field.Point{ .x = 216, .y = 48 }, field.Point{ .x = state.field_state.x, .y = state.field_state.y });
    try std.testing.expect(!state.package.rooms[state.field_state.room].canStand(216, 48));
    const pushed_save = try journey.Snapshot.capture(state);
    try pushed_save.validate(state);
    var invalid = pushed_save;
    invalid.x = 216;
    invalid.y = 40;
    try std.testing.expectError(error.InvalidSave, invalid.validate(state));
    var restored_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&restored_members);
    const saved_bytes = try std.json.Stringify.valueAlloc(allocator, pushed_save, .{});
    defer allocator.free(saved_bytes);
    const decoded_save = try journey.decodeSnapshot(allocator, saved_bytes, restored);
    defer decoded_save.deinit();
    try decoded_save.value.apply(&restored);
    try std.testing.expectEqual(@as(i32, 216), restored.field_state.x);
    try std.testing.expectEqual(@as(i32, 48), restored.field_state.y);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .left } }, .{});
    for (0..9) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqualDeep(field.Point{ .x = 200, .y = 40 }, field.Point{ .x = state.field_state.x, .y = state.field_state.y });
    const chained_save = try journey.Snapshot.capture(state);
    try chained_save.validate(state);
    state.field_state.enterRoom(state.package.roomIndex(binding.room).?, .{ .x = 184, .y = 344 });
    try walkTo(allocator, &state, "va4_room_7", 216, 40, &.{});
    try std.testing.expectEqualStrings("va4_room_7", currentRoomName(&state));
    try walkTo(allocator, &state, "va4_room_8", 128, 0, &.{});
    try std.testing.expectEqualStrings("va4_room_8", currentRoomName(&state));
    try walkTo(allocator, &state, "va4_room_9", 128, 0, &.{});
    try std.testing.expectEqualStrings("va4_room_9", currentRoomName(&state));
    try walkTo(allocator, &state, "va4_room_10", 128, 0, &.{});
    try std.testing.expectEqualStrings("va4_room_10", currentRoomName(&state));
}

test "camera push playback preserves its eight update wait and serialized owner" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    var binding = state.room_battles.?.bindingFor("va4_room_6").?;
    var party_ids: [6]u8 = undefined;
    for (state.field_state.progress.party, 0..) |member, i| party_ids[i] = state.combat.integration.?.host.characterId(member.id).?;
    binding.party = party_ids[0..state.field_state.progress.party.len];
    const programs = try allocator.dupe(event_runtime.Program, binding.content.programs);
    defer allocator.free(programs);
    const requests = [_]event_runtime.camera_push.Request{
        .{ .dx = -16, .dy = -8, .updates = 8, .repeats = 2 },
        .{ .dx = 16, .dy = -8, .updates = 8, .repeats = 2 },
        .{ .dx = 16, .dy = 8, .updates = 8, .repeats = 2 },
        .{ .dx = -16, .dy = 8, .updates = 8, .repeats = 2 },
        .{ .dx = -8, .dy = -8, .updates = 8, .repeats = 2 },
        .{ .dx = 8, .dy = -8, .updates = 8, .repeats = 2 },
        .{ .dx = 8, .dy = 8, .updates = 8, .repeats = 2 },
        .{ .dx = -8, .dy = 8, .updates = 8, .repeats = 2 },
    };
    for (requests) |request| {
        const commands = [_]event_runtime.Command{
            .{ .kind = .camera_push, .push = request, .wait = .{ .kind = .camera_push, .id = "camera_push" } },
            .{ .kind = .end_stream },
        };
        for (programs) |*program| if (program.entity == 1) {
            program.commands = &commands;
        };
        binding.content.schema = event_runtime.camera_push_schema;
        binding.content.programs = programs;
        binding.content.forward_branches = true;
        state.field_state.enterRoom(state.package.roomIndex(binding.room).?, .{ .x = 192, .y = 40 });
        var session: @import("field_events").Session = undefined;
        try std.testing.expect(try session.beginRoomEvent(binding, state.field_state, 1, null, .ordinary, null));
        for (0..16) |index| {
            _ = try session.tick(binding, &state.field_state, false);
            try session.validate(binding);
            try std.testing.expect(session.instance.?.execution.active and session.instance.?.execution.wait.?.kind == .camera_push);
            try std.testing.expectEqual(@as(u16, @intCast(index + 1)), session.camera_push.?.model.elapsed);
            if (index == 3 or index == 7) {
                const bytes = try std.json.Stringify.valueAlloc(allocator, session, .{});
                defer allocator.free(bytes);
                const restored = try std.json.parseFromSlice(@import("field_events").Session, allocator, bytes, .{});
                defer restored.deinit();
                try restored.value.validate(binding);
                var missing = restored.value;
                missing.camera_push = null;
                try std.testing.expectError(error.InvalidCameraPushState, missing.validate(binding));
                var forged = restored.value;
                forged.camera_push.?.model.elapsed += 1;
                try std.testing.expectError(error.InvalidCameraPushState, forged.validate(binding));
                // Resume the deserialized owner through the cycle boundary, not just its parser.
                var resumed = restored.value;
                var resumed_state = state.field_state;
                _ = try resumed.tick(binding, &resumed_state, false);
                try resumed.validate(binding);
                var expected = session;
                var expected_state = state.field_state;
                _ = try expected.tick(binding, &expected_state, false);
                try std.testing.expectEqualDeep(expected.camera_push, resumed.camera_push);
                try std.testing.expectEqualDeep(expected.hero, resumed.hero);
            }
        }
        _ = try session.tick(binding, &state.field_state, false);
        try std.testing.expect(!session.instance.?.execution.active and session.camera_push == null);
        try std.testing.expectEqual(@as(i32, 192) + 2 * request.dx, state.field_state.x);
        try std.testing.expectEqual(@as(i32, 40) + 2 * request.dy, state.field_state.y);
    }
}

const FullFixture = struct {
    allocator: std.mem.Allocator,
    package: std.json.Parsed(field.Package),
    content: std.json.Parsed(battle.Content),
    rules: std.json.Parsed(field.items.Rules),
    bound: merge.Merge,
    data: std.json.Parsed(journey.Data),

    fn init(allocator: std.mem.Allocator, io: std.Io) !FullFixture {
        const room_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/journey_room.json", allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(room_bytes);
        const scene_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/opening_scene.json", allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(scene_bytes);
        const battle_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/opening_trial.json", allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(battle_bytes);
        const journey_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/journey.json", allocator, .limited(64 * 1024));
        defer allocator.free(journey_bytes);
        var package = try field.load(allocator, room_bytes);
        errdefer package.deinit();
        var content = try battle.load(allocator, battle_bytes);
        errdefer content.deinit();
        var rules = try field.items.load(allocator, field.items.json);
        errdefer rules.deinit();
        const bound = try merge.bind(allocator, scene_bytes, package.value);
        errdefer {
            var mutable = bound;
            mutable.deinit(allocator);
        }
        const data = try journey.load(allocator, journey_bytes, bound.package, content.value);
        return .{ .allocator = allocator, .package = package, .content = content, .rules = rules, .bound = bound, .data = data };
    }

    fn deinit(self: *FullFixture) void {
        self.data.deinit();
        self.bound.deinit(self.allocator);
        self.rules.deinit();
        self.content.deinit();
        self.package.deinit();
    }

    fn openingState(self: *FullFixture, members: []battle.Member, combat_backing: *battle.State) !journey.State {
        return journey.State.initOpening(self.bound.package, self.data.value, self.content.value, self.rules.value, field.inn.embedded(), members, combat_backing, self.bound.loaded.opening.value.hero, self.bound.loaded.opening.value.money);
    }
};

const BoundFixture = struct {
    allocator: std.mem.Allocator,
    package: std.json.Parsed(field.Package),
    bound: merge.Merge,
    base_rooms: usize,

    fn init(allocator: std.mem.Allocator, io: std.Io) !BoundFixture {
        const room_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/journey_room.json", allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(room_bytes);
        const scene_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/opening_scene.json", allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(scene_bytes);
        var package = try field.load(allocator, room_bytes);
        errdefer package.deinit();
        const bound = try merge.bind(allocator, scene_bytes, package.value);
        return .{ .allocator = allocator, .package = package, .bound = bound, .base_rooms = package.value.rooms.len };
    }

    fn deinit(self: *BoundFixture) void {
        self.bound.deinit(self.allocator);
        self.package.deinit();
    }
};

test "canonical opening rooms become the journey start package" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try BoundFixture.init(allocator, io);
    defer fixture.deinit();
    const bound = &fixture.bound;
    try bound.package.validate();
    try std.testing.expectEqualStrings("vaa_room_2", bound.package.start_room);
    try std.testing.expect(bound.package.roomIndex("vaa_room_1") != null);
    try std.testing.expect(bound.package.roomIndex("va1_room_0") != null);
    const start = bound.package.rooms[bound.package.roomIndex("vaa_room_2").?];
    try std.testing.expect(start.draws.len > 0);
    try std.testing.expect(start.exits.len > 0);
    try std.testing.expectEqualStrings("vaa_room_1", start.exits[0].room);
    try std.testing.expectEqual(fixture.base_rooms + 7, bound.package.rooms.len);
    const room0 = bound.package.rooms[bound.package.roomIndex("vaa_room_0").?];
    const room10 = bound.package.rooms[bound.package.roomIndex("vaa_room_10").?];
    const town = bound.package.rooms[bound.package.roomIndex("va1_room_0").?];
    try std.testing.expectEqual(@as(usize, 2), room0.exits.len);
    try std.testing.expectEqual(@as(usize, 2), room10.exits.len);
    try std.testing.expectEqual(@as(usize, 0), town.npcs.len);
    try std.testing.expectEqual(@as(usize, 2), room0.events.len);
    var rumor_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var rumor = field.State.init(bound.package, &rumor_progress);
    rumor.room = bound.package.roomIndex("vaa_room_0").?;
    rumor.x = 344;
    rumor.y = 392;
    rumor.destination = .{ .x = 344, .y = 392 };
    rumor.tick(bound.package, .{});
    try std.testing.expect(rumor.dialogue != null);
    try std.testing.expect(rumor.progress.story.vaa_dungeon_rumor);
    var greeting_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var greeting = field.State.init(bound.package, &greeting_progress);
    greeting.room = bound.package.roomIndex("vaa_room_0").?;
    greeting.x = 280;
    greeting.y = 624;
    greeting.destination = .{ .x = 280, .y = 624 };
    greeting.tick(bound.package, .{});
    try std.testing.expect(greeting.dialogue != null);
    try std.testing.expect(greeting.progress.story.vaa_dungeon_greeting);
}

test "ordinary movement crosses the sourced palace exit" {
    var fixture = try BoundFixture.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    const bound = &fixture.bound;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(bound.package, &state_progress);
    try std.testing.expectEqualStrings("vaa_room_2", bound.package.rooms[state.room].id);
    state.x = 472;
    state.y = 208;
    state.destination = .{ .x = 472, .y = 208 };
    for (0..8) |_| state.tick(bound.package, .{ .direction = .right });
    try std.testing.expectEqualStrings("vaa_room_1", bound.package.rooms[state.room].id);
    try std.testing.expectEqual(@as(i32, 40), state.x);
    try std.testing.expectEqual(@as(i32, 128), state.y);
}

test "real initialization opens the canonical palace start" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try FullFixture.init(allocator, io);
    defer fixture.deinit();
    const bound = &fixture.bound;
    const data = fixture.data;
    const content = fixture.content;
    const rules = fixture.rules;
    var members: [6]battle.Member = undefined;
    var state_backing: battle.State = undefined;
    var state = try fixture.openingState(members[0..1], &state_backing);
    try std.testing.expectEqual(@as(usize, 1), state.combat.progress.party.len);
    try std.testing.expectEqual(@as(u32, 1500), state.combat.progress.money);
    try std.testing.expectEqual(@as(u16, 17), state.combat.progress.party[0].max_hp);
    try std.testing.expectEqual(@as(u8, 1), state.combat.progress.party[0].level);
    for (0..4) |slot| try std.testing.expect(state.combat.itemEquipped(0, slot));
    try std.testing.expect(!state.combat.itemEquipped(0, 4));
    try std.testing.expectEqual(@as(u16, 26), state.combat.stats(0).defense);
    const party_snapshot = state.buildPartySnapshot();
    try std.testing.expect(party_snapshot.members[0] != null);
    try std.testing.expect(party_snapshot.members[1] == null);
    try std.testing.expect(!party_snapshot.eligible[1]);
    try std.testing.expect(party_snapshot.active[1] == null);
    try std.testing.expectEqualStrings("vaa_room_2", bound.package.rooms[state.field_state.room].id);
    try std.testing.expect(bound.package.rooms[state.field_state.room].draws.len > 0);
    try std.testing.expect(bound.package.rooms[state.field_state.room].exits.len > 0);
    try std.testing.expect(bound.package.rooms[state.field_state.room].npcs.len > 0);
    state.field_state.x = 400;
    state.field_state.y = 288;
    state.field_state.facing = .up;
    state.field_state.destination = .{ .x = 400, .y = 288 };
    state.field_state.tick(bound.package, .{ .action = true });
    try std.testing.expect(state.field_state.dialogue != null);
    state.field_state.dialogue = null;
    const saved = try journey.Snapshot.capture(state);
    try std.testing.expectEqual(@as(u8, 1), saved.party_count);
    var fresh_members: [6]battle.Member = undefined;
    var restored_backing: battle.State = undefined;
    var restored = try journey.State.fromSnapshot(bound.package, data.value, content.value, rules.value, field.inn.embedded(), saved, battle.trial_seed, &fresh_members, &restored_backing);
    try std.testing.expectEqual(@as(usize, 1), restored.combat.progress.party.len);
    try std.testing.expectEqual(state.combat.progress.party[0].loadout, restored.combat.progress.party[0].loadout);
    try std.testing.expect(journey.usesOpeningSeed("vaa_room_2"));
    try std.testing.expect(journey.usesOpeningSeed("vaa_room_1"));
    try std.testing.expect(!journey.usesOpeningSeed("vb6_inn"));
    restored.field_state.room = bound.package.roomIndex("vaa_room_1").?;
    restored.syncRoute();
    try std.testing.expectEqual(.dungeon, restored.route.stage);
    restored.field_state.room = bound.package.roomIndex("vaa_room_0").?;
    restored.syncRoute();
    try std.testing.expectEqual(.palace, restored.route.stage);
    restored.field_state.room = bound.package.roomIndex("va1_room_0").?;
    restored.syncRoute();
    try std.testing.expectEqual(.first_town, restored.route.stage);
    restored.field_state.room = bound.package.roomIndex("world_a").?;
    restored.syncRoute();
    try std.testing.expectEqual(.world, restored.route.stage);
    const world_journal = restored.route.journal;
    restored.syncRoute();
    try std.testing.expectEqual(world_journal, restored.route.journal);
    state.field_state.x = 472;
    state.field_state.y = 208;
    state.field_state.destination = .{ .x = 472, .y = 208 };
    for (0..8) |_| {
        state.field_state.tick(bound.package, .{ .direction = .right });
        if (std.mem.eql(u8, bound.package.rooms[state.field_state.room].id, "vaa_room_1")) break;
    }
    try std.testing.expectEqualStrings("vaa_room_1", bound.package.rooms[state.field_state.room].id);
    const moved = try journey.Snapshot.capture(state);
    var moved_members: [6]battle.Member = undefined;
    var restored_move_backing: battle.State = undefined;
    const restored_move = try journey.State.fromSnapshot(bound.package, data.value, content.value, rules.value, field.inn.embedded(), moved, battle.trial_seed, &moved_members, &restored_move_backing);
    try std.testing.expectEqualStrings("vaa_room_1", bound.package.rooms[restored_move.field_state.room].id);
    try std.testing.expectEqual(@as(i32, 40), restored_move.field_state.x);
    try std.testing.expectEqual(@as(i32, 128), restored_move.field_state.y);
    const catalog = try party_session.catalogue.decode(allocator, party_data.json);
    defer catalog.deinit();
    const binding_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "tests/party_session/ownership_bindings.json", allocator, .limited(64 * 1024));
    defer allocator.free(binding_bytes);
    const bindings = try party_session.catalogue.decodeBindings(allocator, binding_bytes, party_data.json);
    defer bindings.deinit();
    var patrol_data = data.value;
    patrol_data.field_encounters = null;
    var hooked_members: [6]battle.Member = undefined;
    var hooked_backing: battle.State = undefined;
    var hooked = try journey.State.initOpening(bound.package, patrol_data, content.value, rules.value, field.inn.embedded(), &hooked_members, &hooked_backing, bound.loaded.opening.value.hero, bound.loaded.opening.value.money);
    hooked.party_catalog = catalog.value;
    hooked.party_bindings = bindings.value;
    hooked.party_backing = &hooked_members;
    hooked.field_state.room = bound.package.roomIndex("va1_room_2").?;
    _ = hooked.tick(.{}, .{});
    try std.testing.expectEqual(@as(usize, 2), hooked.combat.progress.party.len);
    try std.testing.expectEqualStrings("ted", hooked.combat.progress.party[1].id);
    hooked.field_state.room = bound.package.roomIndex("va1_room_0").?;
    hooked.field_state.x = 184;
    hooked.field_state.y = 352;
    hooked.field_state.destination = .{ .x = 184, .y = 352 };
    hooked.town_home_ticks = 0;
    hooked.derived_scene_cadence = false;
    for (0..40) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqualStrings("va1_room_0", bound.package.rooms[hooked.field_state.room].id);
    hooked.derived_scene_cadence = true;
    hooked.menu.phase = .root;
    for (0..40) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqualStrings("va1_room_0", bound.package.rooms[hooked.field_state.room].id);
    hooked.menu.phase = .closed;
    for (0..30) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqualStrings("va1_room_1", bound.package.rooms[hooked.field_state.room].id);
    try std.testing.expectEqual(@as(i32, 184), hooked.field_state.x);
    try std.testing.expectEqual(@as(i32, 352), hooked.field_state.y);
    try std.testing.expectEqual(@as(usize, 3), hooked.combat.progress.party.len);
    try std.testing.expectEqualStrings("cleo", hooked.combat.progress.party[2].id);
    try std.testing.expect(hooked.route.milestones.initial_party);
    const town_saved = try journey.Snapshot.capture(hooked);
    var town_members: [6]battle.Member = undefined;
    var town_restored_backing: battle.State = undefined;
    const town_restored = try journey.State.fromSnapshot(bound.package, patrol_data, content.value, rules.value, field.inn.embedded(), town_saved, battle.trial_seed, &town_members, &town_restored_backing);
    try std.testing.expectEqualStrings("va1_room_1", bound.package.rooms[town_restored.field_state.room].id);
    try std.testing.expectEqual(@as(u8, 0), town_restored.town_home_ticks);
    try std.testing.expectEqual(@as(u8, 0), town_restored.town_room_ticks);
    for (0..30) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqualStrings("va1_room_2", bound.package.rooms[hooked.field_state.room].id);
    try std.testing.expectEqual(@as(i32, 152), hooked.field_state.x);
    try std.testing.expectEqual(@as(i32, 264), hooked.field_state.y);
    try std.testing.expectEqual(@as(usize, 3), hooked.combat.progress.party.len);
    const route_saved = try journey.Snapshot.capture(hooked);
    var route_members: [6]battle.Member = undefined;
    var route_restored_backing: battle.State = undefined;
    const route_restored = try journey.State.fromSnapshot(bound.package, patrol_data, content.value, rules.value, field.inn.embedded(), route_saved, battle.trial_seed, &route_members, &route_restored_backing);
    try std.testing.expectEqualStrings("va1_room_2", bound.package.rooms[route_restored.field_state.room].id);
    try std.testing.expectEqual(@as(i32, 152), route_restored.field_state.x);
    try std.testing.expectEqual(@as(i32, 264), route_restored.field_state.y);
    try std.testing.expectEqual(@as(usize, 3), route_restored.combat.progress.party.len);
    for (0..30) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqualStrings("world_a", bound.package.rooms[hooked.field_state.room].id);
    try std.testing.expectEqual(@as(i32, 640), hooked.field_state.x);
    try std.testing.expectEqual(@as(i32, 480), hooked.field_state.y);
    const world_room = bound.package.rooms[hooked.field_state.room];
    try std.testing.expect(std.mem.indexOfScalar(u8, world_room.walkable, '0') != null);
    try std.testing.expect(world_room.canStand(640, 480));
    for (0..4) |_| _ = hooked.tick(.{ .field = .{ .direction = .right } }, .{});
    try std.testing.expectEqual(@as(i32, 640), hooked.field_state.x);

    try std.testing.expectEqual(.world, hooked.route.stage);
    try std.testing.expectEqual(@as(u8, 4), hooked.route.completed);
    const world_saved = try journey.Snapshot.capture(hooked);
    var world_members: [6]battle.Member = undefined;
    var world_restored_backing: battle.State = undefined;
    var world_restored = try journey.State.fromSnapshot(bound.package, patrol_data, content.value, rules.value, field.inn.embedded(), world_saved, battle.trial_seed, &world_members, &world_restored_backing);
    try std.testing.expectEqualStrings("world_a", bound.package.rooms[world_restored.field_state.room].id);
    try std.testing.expectEqual(@as(i32, 640), world_restored.field_state.x);
    try std.testing.expectEqual(@as(usize, 3), world_restored.combat.progress.party.len);
    try std.testing.expect(world_restored.route.milestones.initial_party);
    world_restored.menu.phase = .root;
    for (0..30) |_| _ = world_restored.tick(.{}, .{});
    try std.testing.expect(!world_restored.world_battle_started);
    world_restored.menu.phase = .closed;
    _ = world_restored.tick(.{}, .{});
    try std.testing.expect(world_restored.world_battle_started);
    try std.testing.expectEqual(.battle, world_restored.mode);
    hooked.world_battle_enabled = true;
    hooked.world_battle_ticks = 0;
    hooked.world_battle_started = false;
    hooked.field_state.x = 0;
    hooked.field_state.y = 0;
    hooked.field_state.destination = .{ .x = 0, .y = 0 };
    for (0..30) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqual(.field, hooked.mode);
    hooked.field_state.x = 640;
    hooked.field_state.y = 480;
    for (0..20) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqual(.field, hooked.mode);
    hooked.field_state.room = bound.package.roomIndex("vaa_room_2").?;
    for (0..20) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqual(.field, hooked.mode);
    hooked.field_state.room = bound.package.roomIndex("world_a").?;
    hooked.field_state.x = 640;
    hooked.field_state.y = 480;
    for (0..30) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expect(hooked.world_battle_started);
    try std.testing.expectEqual(.battle, hooked.mode);
    const money_before = hooked.combat.progress.money;
    hooked.combat.phase = .victory;
    hooked.combat.dropped_item = null;
    hooked.combat.drop_received = false;
    hooked.combat.loot_declined = false;
    _ = hooked.tick(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.field, hooked.mode);
    try std.testing.expect(hooked.combat.progress.story.world_patrol_won);
    const money_after = hooked.combat.progress.money;
    try std.testing.expect(money_after >= money_before);
    for (0..60) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqual(money_after, hooked.combat.progress.money);
    try std.testing.expectEqual(.field, hooked.mode);
    const patrol_saved = try journey.Snapshot.capture(hooked);
    var patrol_members: [6]battle.Member = undefined;
    var patrol_restored_backing: battle.State = undefined;
    var patrol_restored = try journey.State.fromSnapshot(bound.package, patrol_data, content.value, rules.value, field.inn.embedded(), patrol_saved, battle.trial_seed, &patrol_members, &patrol_restored_backing);
    try std.testing.expect(patrol_restored.combat.progress.story.world_patrol_won);
    try std.testing.expectEqual(money_after, patrol_restored.combat.progress.money);
    for (0..60) |_| _ = patrol_restored.tick(.{}, .{});
    try std.testing.expectEqual(.field, patrol_restored.mode);
    try std.testing.expectEqual(money_after, patrol_restored.combat.progress.money);
    hooked.combat.progress.story.world_patrol_won = false;
    hooked.world_battle_started = false;
    hooked.world_battle_ticks = 0;
    for (0..30) |_| _ = hooked.tick(.{}, .{});
    try std.testing.expectEqual(.battle, hooked.mode);
    hooked.combat.phase = .escaped;
    _ = hooked.tick(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.field, hooked.mode);
    try std.testing.expect(!hooked.combat.progress.story.world_patrol_won);
    const escaped_saved = try journey.Snapshot.capture(hooked);
    var escaped_members: [6]battle.Member = undefined;
    var escaped_restored_backing: battle.State = undefined;
    var escaped_restored = try journey.State.fromSnapshot(bound.package, patrol_data, content.value, rules.value, field.inn.embedded(), escaped_saved, battle.trial_seed, &escaped_members, &escaped_restored_backing);
    try std.testing.expect(!escaped_restored.combat.progress.story.world_patrol_won);
    for (0..30) |_| _ = escaped_restored.tick(.{}, .{});
    try std.testing.expectEqual(.battle, escaped_restored.mode);
    hooked.world_battle_started = false;
    hooked.world_battle_ticks = 0;
    for (0..29) |_| _ = hooked.tick(.{}, .{});
    const patrol_room = hooked.package.rooms[hooked.field_state.room];
    const heading: field.Direction = if (patrol_room.canStand(hooked.field_state.x - 8, hooked.field_state.y)) .left else .right;
    for (1..hooked.package.step_ticks) |_| _ = hooked.tick(.{ .field = .{ .direction = heading } }, .{});
    try std.testing.expectEqual(@as(u16, @intFromBool(hooked.package.step_ticks > 1)), hooked.field_state.remaining);
    hooked.combat.progress.party[0].status = .poisoned;
    hooked.combat.random = std.Random.DefaultPrng.init(17);
    var after_step = hooked.combat.random;
    _ = after_step.random().int(u15);
    _ = hooked.tick(.{ .field = .{ .direction = heading } }, .{});
    try std.testing.expectEqual(.battle, hooked.mode);
    const defeat_checkpoint_money = hooked.combat.progress.money;
    const defeat_checkpoint_random = hooked.combat.random;
    try std.testing.expectEqualDeep(after_step, defeat_checkpoint_random);
    const defeat_checkpoint_member = hooked.combat.progress.party[0];
    hooked.combat.progress.money = 123456;
    for (hooked.combat.progress.party) |*member| {
        member.hp = 0;
        member.status = .unconscious;
    }
    hooked.combat.phase = .resolving;
    hooked.combat.active = .{ .actor = 0, .target = 6, .kind = .defend };
    hooked.combat.action_ticks = hooked.combat.actionDuration() - 1;
    _ = hooked.tick(.{}, .{});
    try std.testing.expectEqual(.defeat, hooked.mode);
    _ = hooked.tick(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.battle, hooked.mode);
    try std.testing.expectEqual(defeat_checkpoint_money, hooked.combat.progress.money);
    try std.testing.expectEqualDeep(defeat_checkpoint_random, hooked.combat.random);
    try std.testing.expectEqualDeep(defeat_checkpoint_member, hooked.combat.progress.party[0]);
    restored.route.stage = .first_town;
    restored.route.completed = 3;
    try restored.joinOnRoomEntry(&fresh_members, catalog.value, bindings.value, "va1_room_2");
    try std.testing.expectEqual(@as(usize, 2), restored.combat.progress.party.len);
    try std.testing.expectEqualStrings("ted", restored.combat.progress.party[1].id);
    try restored.joinOnRoomEntry(&fresh_members, catalog.value, bindings.value, "va1_room_1");
    try std.testing.expectEqual(@as(usize, 3), restored.combat.progress.party.len);
    try std.testing.expectEqualStrings("cleo", restored.combat.progress.party[2].id);
    try restored.joinOnRoomEntry(&fresh_members, catalog.value, bindings.value, "va1_room_2");
    try std.testing.expectEqual(@as(usize, 3), restored.combat.progress.party.len);
    restored.route.stage = .world;
    restored.route.completed = 4;
    try restored.joinOnRoomEntry(&fresh_members, catalog.value, bindings.value, "va1_room_2");
    try std.testing.expectEqual(@as(usize, 3), restored.combat.progress.party.len);
    const reserved = try party_session.catalogue.materializeBound(state.combat.*, catalog.value, "cleo", null);
    state.reserves[0] = reserved.owned;
    state.reserve_extras[0] = reserved.extra;
    try state.joinPartyMember(&members, catalog.value, null, "cleo");
    try std.testing.expect(state.reserves[0] == null);
    try std.testing.expectEqualDeep(reserved.owned, state.combat.ownedMember(1));
    try std.testing.expectEqual(@as(usize, 2), state.combat.progress.party.len);
    try std.testing.expectEqualStrings("cleo", state.combat.progress.party[1].id);
    try std.testing.expectError(error.DuplicateMember, state.joinPartyMember(&members, catalog.value, null, "cleo"));
    try std.testing.expectEqual(@as(usize, 2), state.combat.progress.party.len);
    const joined = try journey.Snapshot.capture(state);
    try std.testing.expectEqual(@as(u8, 2), joined.party_count);
    try std.testing.expectEqualStrings("cleo", joined.party[1].id);
    try std.testing.expectError(error.UnknownCharacter, state.joinPartyMember(&members, catalog.value, null, "not_a_member"));
    try std.testing.expectEqual(@as(usize, 2), state.combat.progress.party.len);
    try state.joinPartyMember(&members, catalog.value, bindings.value, "ted");
    try std.testing.expectEqual(@as(usize, 3), state.combat.progress.party.len);
    try std.testing.expect(state.combat.progress.party[2].inventory.count() > 0);
    try std.testing.expect(state.combat.progress.party[2].rune != null);
    try std.testing.expectError(error.DuplicateMember, state.joinPartyMember(&members, catalog.value, bindings.value, "ted"));
    try std.testing.expectEqual(@as(usize, 3), state.combat.progress.party.len);
    state.extras[1].weapon_element = .fire;
    var bad_extras = try journey.Snapshot.capture(state);
    bad_extras.extras[4].member_id = "ghost";
    try std.testing.expectError(error.InvalidExtras, bad_extras.validate(state));
    var with_joins = try journey.Snapshot.capture(state);
    with_joins.route.?.milestones.initial_party = false;
    var join_members: [6]battle.Member = undefined;
    var restored_joins_backing: battle.State = undefined;
    const restored_joins = try journey.State.fromSnapshot(bound.package, data.value, content.value, rules.value, field.inn.embedded(), with_joins, battle.trial_seed, &join_members, &restored_joins_backing);
    try std.testing.expectEqual(@as(usize, 3), restored_joins.combat.progress.party.len);
    try std.testing.expectEqual(.fire, restored_joins.extras[1].weapon_element);
    try std.testing.expect(restored_joins.route.milestones.initial_party);
    try state.joinPartyMember(&members, catalog.value, null, "pahn");
    try state.joinPartyMember(&members, catalog.value, null, "viktor");
    try state.joinPartyMember(&members, catalog.value, null, "yam_koo");
    try std.testing.expectEqual(@as(usize, 6), state.combat.progress.party.len);
    try std.testing.expectError(error.PartyFull, state.joinPartyMember(&members, catalog.value, null, "maas"));
}

test "ordinary input walks from the opening start to the palace exit" {
    var fixture = try BoundFixture.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    const bound = &fixture.bound;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(bound.package, &state_progress);
    try std.testing.expectEqualStrings("vaa_room_2", bound.package.rooms[state.room].id);
    const path = "DDDLLLLLLLLLLLLUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUURRRRDD";
    for (path) |step| {
        const direction: field.Direction = switch (step) {
            'D' => .down,
            'U' => .up,
            'L' => .left,
            else => .right,
        };
        while (state.remaining > 0) state.tick(bound.package, .{ .direction = direction });
        if (std.mem.eql(u8, bound.package.rooms[state.room].id, "vaa_room_1")) break;
        state.tick(bound.package, .{ .direction = direction });
        if (std.mem.eql(u8, bound.package.rooms[state.room].id, "vaa_room_1")) break;
    }
    while (state.remaining > 0) state.tick(bound.package, .{});
    try std.testing.expectEqualStrings("vaa_room_1", bound.package.rooms[state.room].id);
    try std.testing.expectEqual(@as(i32, 40), state.x);
    try std.testing.expectEqual(@as(i32, 128), state.y);
}

test "ordinary input walks from the palace landing to the dungeon" {
    var fixture = try BoundFixture.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    const bound = &fixture.bound;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(bound.package, &state_progress);
    state.room = bound.package.roomIndex("vaa_room_1").?;
    state.x = 40;
    state.y = 128;
    state.destination = .{ .x = 40, .y = 128 };
    const path = "DDDDDDRRRRRRRRRDDRRRRRRRRRRRRRRRRRRDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD";
    for (path) |step| {
        const direction: field.Direction = switch (step) {
            'D' => .down,
            'U' => .up,
            'L' => .left,
            else => .right,
        };
        while (state.remaining > 0) state.tick(bound.package, .{ .direction = direction });
        if (std.mem.eql(u8, bound.package.rooms[state.room].id, "vaa_room_0")) break;
        state.tick(bound.package, .{ .direction = direction });
        if (std.mem.eql(u8, bound.package.rooms[state.room].id, "vaa_room_0")) break;
    }
    while (state.remaining > 0) state.tick(bound.package, .{});
    try std.testing.expectEqualStrings("vaa_room_0", bound.package.rooms[state.room].id);
    try std.testing.expectEqual(@as(i32, 312), state.x);
    try std.testing.expectEqual(@as(i32, 104), state.y);
}

test "save and restore after walking to the palace landing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try FullFixture.init(allocator, io);
    defer fixture.deinit();
    const bound = &fixture.bound;
    const data = fixture.data;
    const content = fixture.content;
    const rules = fixture.rules;
    var members: [6]battle.Member = undefined;
    var state_backing: battle.State = undefined;
    var state = try fixture.openingState(&members, &state_backing);
    const path = "DDDLLLLLLLLLLLLUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUURRRRDD";
    for (path) |step| {
        const direction: field.Direction = switch (step) {
            'D' => .down,
            'U' => .up,
            'L' => .left,
            else => .right,
        };
        while (state.field_state.remaining > 0) _ = state.tick(.{ .field = .{ .direction = direction } }, .{});
        if (std.mem.eql(u8, bound.package.rooms[state.field_state.room].id, "vaa_room_1")) break;
        _ = state.tick(.{ .field = .{ .direction = direction } }, .{});
        if (std.mem.eql(u8, bound.package.rooms[state.field_state.room].id, "vaa_room_1")) break;
    }
    while (state.field_state.remaining > 0) _ = state.tick(.{}, .{});
    try std.testing.expectEqualStrings("vaa_room_1", bound.package.rooms[state.field_state.room].id);
    const saved = try journey.Snapshot.capture(state);
    var fresh: [6]battle.Member = undefined;
    var restored_backing: battle.State = undefined;
    const restored = try journey.State.fromSnapshot(bound.package, data.value, content.value, rules.value, field.inn.embedded(), saved, battle.trial_seed, &fresh, &restored_backing);
    try std.testing.expectEqualStrings("vaa_room_1", bound.package.rooms[restored.field_state.room].id);
    try std.testing.expectEqual(@as(i32, 40), restored.field_state.x);
    try std.testing.expectEqual(@as(i32, 128), restored.field_state.y);
}

test "ordinary input walks the dungeon and palace exits into the first town" {
    var fixture = try BoundFixture.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    const bound = &fixture.bound;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(bound.package, &state_progress);
    state.room = bound.package.roomIndex("vaa_room_0").?;
    state.x = 312;
    state.y = 104;
    state.destination = .{ .x = 312, .y = 104 };
    for (0..80) |_| {
        while (state.remaining > 0) state.tick(bound.package, .{ .direction = .down });
        if (std.mem.eql(u8, bound.package.rooms[state.room].id, "vaa_room_10")) break;
        state.tick(bound.package, .{ .direction = .down });
        if (std.mem.eql(u8, bound.package.rooms[state.room].id, "vaa_room_10")) break;
    }
    while (state.remaining > 0) state.tick(bound.package, .{});
    try std.testing.expectEqualStrings("vaa_room_10", bound.package.rooms[state.room].id);
    try std.testing.expectEqual(@as(i32, 184), state.x);
    try std.testing.expectEqual(@as(i32, 56), state.y);
    for (0..22) |_| {
        while (state.remaining > 0) state.tick(bound.package, .{ .direction = .down });
        if (std.mem.eql(u8, bound.package.rooms[state.room].id, "va1_room_0")) break;
        state.tick(bound.package, .{ .direction = .down });
        if (std.mem.eql(u8, bound.package.rooms[state.room].id, "va1_room_0")) break;
    }
    while (state.remaining > 0) state.tick(bound.package, .{});
    try std.testing.expectEqualStrings("va1_room_0", bound.package.rooms[state.room].id);
    try std.testing.expectEqual(@as(i32, 808), state.x);
    try std.testing.expectEqual(@as(i32, 56), state.y);
}

test "world collision blocks right movement and allows left movement" {
    var fixture = try BoundFixture.init(std.testing.allocator, std.testing.io);
    defer fixture.deinit();
    const bound = &fixture.bound;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(bound.package, &state_progress);
    state.room = bound.package.roomIndex("world_a").?;
    state.x = 640;
    state.y = 480;
    state.destination = .{ .x = 640, .y = 480 };
    for (0..4) |_| state.tick(bound.package, .{ .direction = .right });
    try std.testing.expectEqual(@as(i32, 640), state.x);
    for (0..8) |_| state.tick(bound.package, .{ .direction = .left });
    try std.testing.expectEqual(@as(i32, 632), state.x);
}

fn walkJourney(state: *journey.State, path: []const u8, target: []const u8) !void {
    for (path) |step| {
        const direction: field.Direction = switch (step) {
            'D' => .down,
            'U' => .up,
            'L' => .left,
            else => .right,
        };
        while (state.field_state.remaining > 0) _ = state.tick(.{ .field = .{ .direction = direction } }, .{});
        if (std.mem.eql(u8, state.package.rooms[state.field_state.room].id, target)) break;
        _ = state.tick(.{ .field = .{ .direction = direction } }, .{});
        if (std.mem.eql(u8, state.package.rooms[state.field_state.room].id, target)) break;
    }
    while (state.field_state.remaining > 0) _ = state.tick(.{}, .{});
}

test "ordinary input reaches the world through the whole first-town route" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try FullFixture.init(allocator, io);
    defer fixture.deinit();
    const bound = &fixture.bound;
    const catalog = try party_session.catalogue.decode(allocator, party_data.json);
    defer catalog.deinit();
    const binding_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "tests/party_session/ownership_bindings.json", allocator, .limited(64 * 1024));
    defer allocator.free(binding_bytes);
    const bindings = try party_session.catalogue.decodeBindings(allocator, binding_bytes, party_data.json);
    defer bindings.deinit();
    var members: [6]battle.Member = undefined;
    var state_backing: battle.State = undefined;
    var state = try fixture.openingState(&members, &state_backing);
    state.party_catalog = catalog.value;
    state.party_bindings = bindings.value;
    try walkJourney(&state, "DDDLLLLLLLLLLLLUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUURRRRDD", "vaa_room_1");
    try std.testing.expectEqualStrings("vaa_room_1", bound.package.rooms[state.field_state.room].id);
    try walkJourney(&state, "DDDDDDRRRRRRRRRDDRRRRRRRRRRRRRRRRRRDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "vaa_room_0");
    try std.testing.expectEqualStrings("vaa_room_0", bound.package.rooms[state.field_state.room].id);
    for (0..82) |_| {
        while (state.field_state.remaining > 0) _ = state.tick(.{ .field = .{ .direction = .down } }, .{});
        if (std.mem.eql(u8, bound.package.rooms[state.field_state.room].id, "vaa_room_10")) break;
        _ = state.tick(.{ .field = .{ .direction = .down } }, .{});
    }
    try std.testing.expectEqualStrings("vaa_room_10", bound.package.rooms[state.field_state.room].id);
    for (0..24) |_| {
        while (state.field_state.remaining > 0) _ = state.tick(.{ .field = .{ .direction = .down } }, .{});
        if (std.mem.eql(u8, bound.package.rooms[state.field_state.room].id, "va1_room_0")) break;
        _ = state.tick(.{ .field = .{ .direction = .down } }, .{});
    }
    try std.testing.expectEqualStrings("va1_room_0", bound.package.rooms[state.field_state.room].id);
    for (0..30) |_| _ = state.tick(.{}, .{});
    try std.testing.expectEqualStrings("va1_room_1", bound.package.rooms[state.field_state.room].id);
    for (0..30) |_| _ = state.tick(.{}, .{});
    try std.testing.expectEqualStrings("va1_room_2", bound.package.rooms[state.field_state.room].id);
    for (0..30) |_| _ = state.tick(.{}, .{});
    try std.testing.expectEqualStrings("world_a", bound.package.rooms[state.field_state.room].id);
    try std.testing.expectEqual(@as(usize, 3), state.combat.progress.party.len);
    try std.testing.expectEqualStrings("cleo", state.combat.progress.party[1].id);
    try std.testing.expectEqualStrings("ted", state.combat.progress.party[2].id);
}

const CanonicalHarness = struct {
    allocator: std.mem.Allocator,
    bundle: journey_content.Bundle,
    party: party_content.Content,
    opening_seed: std.json.Parsed(journey.opening.Content),

    fn load(allocator: std.mem.Allocator, io: std.Io) !CanonicalHarness {
        var dir = try std.Io.Dir.cwd().openDir(io, "../kit/work/build/canonical", .{});
        defer dir.close(io);
        var diag: journey_content.Diagnostic = .{};
        var bundle = journey_content.Bundle.load(allocator, io, dir, &diag) catch |err| {
            std.debug.print("Bundle load failed at {s}: {s}\n", .{ diag.path, @errorName(err) });
            return err;
        };
        errdefer bundle.deinit();
        var pdiag: party_content.Diagnostic = .{};
        var party = (try party_content.load(allocator, io, dir, true, &pdiag)).?;
        errdefer party.deinit();
        const opening_seed = try journey.opening.load(allocator, journey.opening.json);
        return .{ .allocator = allocator, .bundle = bundle, .party = party, .opening_seed = opening_seed };
    }

    fn deinit(self: *CanonicalHarness) void {
        self.opening_seed.deinit();
        self.party.deinit();
        self.bundle.deinit();
    }

    fn newState(self: *CanonicalHarness, members: *[6]battle.Member) !journey.State {
        var boot: journey_boot.Boot = .{
            .allocator = self.allocator,
            .path = @constCast(""),
            .save_path = null,
            .bundle = self.bundle,
            .party = self.party,
            .opening_seed = self.opening_seed,
            .members = members,
            .combat = try self.bundle.arena.allocator().create(battle.State),
            .state = undefined,
        };
        return try boot.newState();
    }
};

fn currentRoomName(state: *const journey.State) []const u8 {
    return state.package.rooms[state.field_state.room].id;
}

fn setScenarioBit(state: *journey.State, byte_index: usize, mask: u8) void {
    state.field_state.progress.story.scenario.?.scenario[byte_index] |= mask;
    state.combat.progress.story.scenario.?.scenario[byte_index] |= mask;
}

fn scenarioBitSet(state: *const journey.State, byte_index: usize, mask: u8) bool {
    return (state.field_state.progress.story.scenario.?.scenario[byte_index] & mask) == mask and
        (state.combat.progress.story.scenario.?.scenario[byte_index] & mask) == mask;
}

fn drainFieldEventCursor(state: *journey.State, choices: []const u8, choice_cursor: *usize) !usize {
    const start_cursor = choice_cursor.*;
    var ticks: usize = 0;
    while (state.field_event != null and state.mode == .field and state.party_selection == null) : (ticks += 1) {
        if (ticks >= 15000) return error.FieldEventTimeout;
        const owner = state.field_event.?;
        if (owner.session.instance) |instance| {
            if (instance.execution.wait) |wait| if (wait.kind == .choice) {
                const slot = instance.choiceBox(owner.binding.content) orelse return error.InvalidFieldChoices;
                const options = instance.choiceOptions(owner.binding.content) orelse return error.InvalidFieldChoices;
                if (owner.session.boxes[slot].phase != .open) {
                    _ = try state.tickWithFieldEvents(.{}, .{});
                    continue;
                }
                const target = if (choice_cursor.* < choices.len) choices[choice_cursor.*] else return error.UnexpectedFieldChoice;
                try std.testing.expect(target < options);
                if (instance.execution.choice != target) {
                    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
                } else {
                    choice_cursor.* += 1;
                    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
                }
                continue;
            };
        }
        _ = try state.tickWithFieldEvents(.{ .field = .{ .action = (ticks & 1) == 0 } }, .{});
    }
    return choice_cursor.* - start_cursor;
}

fn drainFieldEvent(state: *journey.State, choices: []const u8) !usize {
    var cursor: usize = 0;
    const used = try drainFieldEventCursor(state, choices, &cursor);
    try std.testing.expectEqual(choices.len, cursor);
    return used;
}

fn walkStep(state: *journey.State, dir: field.Direction, choices: []const u8, choice_cursor: *usize) !bool {
    const prev_room = state.field_state.room;
    const prev_x = state.field_state.x;
    const prev_y = state.field_state.y;
    var event_ran = false;
    for (0..4) |_| {
        if (state.field_event != null and state.mode == .field) {
            event_ran = true;
            _ = try drainFieldEventCursor(state, choices, choice_cursor);
        }
        if (state.mode != .field or event_ran or state.field_state.room != prev_room or state.field_state.x != prev_x or state.field_state.y != prev_y) return event_ran;
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = dir } }, .{});
        while (state.field_state.remaining > 0 or (state.field_event != null and state.mode == .field)) {
            if (state.field_event != null and state.mode == .field) {
                event_ran = true;
                _ = try drainFieldEventCursor(state, choices, choice_cursor);
            } else {
                _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = dir } }, .{});
            }
            if (state.mode != .field) return event_ran;
        }
        if (event_ran or state.field_state.room != prev_room or state.field_state.x != prev_x or state.field_state.y != prev_y) return event_ran;
    }
    return event_ran;
}

fn walkTo(allocator: std.mem.Allocator, state: *journey.State, target_room: ?[]const u8, target_x: i32, target_y: i32, choices: []const u8) !void {
    errdefer std.debug.print("Navigation from {s} at ({d}, {d}) toward {?s} ({d}, {d})\n", .{
        currentRoomName(state), state.field_state.x, state.field_state.y, target_room, target_x, target_y,
    });
    // Finish an in-flight step and rest fades before planning from the settled cell.
    while (state.mode == .field and (state.field_state.remaining > 0 or state.field_state.rest_ticks > 0)) {
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    var choice_cursor: usize = 0;
    if (target_room) |want| {
        if (std.mem.eql(u8, currentRoomName(state), want) and state.field_state.x == target_x and state.field_state.y == target_y) {
            if (state.field_event != null) {
                choice_cursor += try drainFieldEvent(state, choices[choice_cursor..]);
            }
            try std.testing.expectEqual(choices.len, choice_cursor);
            return;
        }
    }

    const start_room_idx = state.field_state.room;
    const room = state.package.rooms[start_room_idx];
    const route_scripts = if (state.room_battles) |rooms|
        if (rooms.bindingFor(room.id) != null) rooms else null
    else
        null;
    const cols: usize = @intCast(@divTrunc(room.width, 8));
    const rows: usize = @intCast(@divTrunc(room.height, 8));
    const total = cols * rows;
    if (target_x < 0 or target_y < 0) return error.UnreachableTile;
    const goal_tx: usize = @intCast(@divTrunc(target_x, 8));
    const goal_ty: usize = @intCast(@divTrunc(target_y, 8));
    if (goal_tx >= cols or goal_ty >= rows) return error.UnreachableTile;
    const goal_idx = goal_ty * cols + goal_tx;

    const parent = try allocator.alloc(usize, total);
    defer allocator.free(parent);
    const move_dir = try allocator.alloc(u8, total);
    defer allocator.free(move_dir);
    const queue = try allocator.alloc(usize, total);
    defer allocator.free(queue);

    const dx = [_]i32{ 0, 0, -1, 1 };
    const dy = [_]i32{ 1, -1, 0, 0 };
    const dirs = [_]field.Direction{ .down, .up, .left, .right };

    // A source stair route can require more than sixteen separate pushes.
    for (0..@min(total, 256)) |_| {
        const start_tx: usize = @intCast(@divTrunc(state.field_state.x, 8));
        const start_ty: usize = @intCast(@divTrunc(state.field_state.y, 8));
        if (start_tx >= cols or start_ty >= rows) return error.UnreachableTile;
        const start_idx = start_ty * cols + start_tx;
        const boat_story = if (room.boat_rapids != null and state.field_state.progress.story.scenario != null and
            state.field_state.progress.story.scenario.?.world_mode == 1)
            &state.field_state.progress.story.scenario.?
        else
            null;

        @memset(parent, std.math.maxInt(usize));
        var head: usize = 0;
        var tail: usize = 0;
        parent[start_idx] = start_idx;
        queue[tail] = start_idx;
        tail += 1;

        var exit_idx: ?usize = null;
        var exit_direction: field.Direction = .up;
        while (head < tail) {
            const cur = queue[head];
            head += 1;
            if (cur == goal_idx) break;
            const cx: i32 = @intCast(cur % cols);
            const cy: i32 = @intCast(cur / cols);
            for (dx, dy, 0..) |ox, oy, d| {
                var pushed: ?field.Point = null;
                if (route_scripts) |rooms| if (state.field_state.progress.story.scenario) |*story| {
                    pushed = rooms.ordinaryPushAt(room.id, story, @intCast(state.combat.partyCount()), &state.field_state.local_flags.values, state.field_state.progress.money, cx, cy, dirs[d]);
                    if (exit_idx == null and target_room != null) {
                        const destination = rooms.ordinaryTransitionAt(room.id, story, @intCast(state.combat.partyCount()), &state.field_state.local_flags.values, state.field_state.progress.money, cx, cy, if (state.field_state.world_context) |context| state.package.rooms[context.room].id else null, dirs[d]);
                        if (destination != null and std.mem.eql(u8, destination.?, target_room.?)) {
                            exit_idx = cur;
                            exit_direction = dirs[d];
                        }
                    }
                };
                const nx = if (pushed) |point| @divExact(point.x, 8) else cx + ox;
                const ny = if (pushed) |point| @divExact(point.y, 8) else cy + oy;
                if (nx < 0 or ny < 0 or nx >= cols or ny >= rows) continue;
                const nidx: usize = @intCast(@as(usize, @intCast(ny)) * cols + @as(usize, @intCast(nx)));
                const scenery = if (state.field_state.room_scenery) |*value| value else null;
                const cell_walkable = if (boat_story) |story|
                    room.boatPassage(nx * 8, ny * 8, story) == .open
                else
                    room.canStandWithScenery(scenery, nx * 8, ny * 8);
                const boundary_doorway = if (!cell_walkable and pushed == null and target_room != null and
                    (nx * 8 == room.width - 8 or ny * 8 == room.height - 8))
                    if (route_scripts) |rooms|
                        if (state.field_state.progress.story.scenario) |*story| blk: {
                            const retained = if (state.field_state.world_context) |context| state.package.rooms[context.room].id else null;
                            const dest = rooms.ordinaryTransitionAt(room.id, story, @intCast(state.combat.partyCount()), &state.field_state.local_flags.values, state.field_state.progress.money, nx, ny, retained, dirs[d]);
                            break :blk dest != null and std.mem.eql(u8, dest.?, target_room.?);
                        } else false
                    else
                        false
                else
                    false;
                if ((pushed == null and !cell_walkable and !boundary_doorway) or parent[nidx] != std.math.maxInt(usize)) continue;
                if (nidx != goal_idx) {
                    const px = nx * 8;
                    const py = ny * 8;
                    const hits_other_exit = for (room.exits) |ex| {
                        if (px >= ex.x and px < ex.x + ex.w and py >= ex.y and py < ex.y + ex.h) {
                            if (target_room == null or !std.mem.eql(u8, ex.room, target_room.?)) break true;
                        }
                    } else if (route_scripts) |rooms| blk: {
                        const story_ptr = &(state.field_state.progress.story.scenario orelse break :blk false);
                        if (rooms.ordinaryTransitionAt(room.id, story_ptr, @intCast(state.combat.partyCount()), &state.field_state.local_flags.values, state.field_state.progress.money, nx, ny, if (state.field_state.world_context) |context| state.package.rooms[context.room].id else null, dirs[d])) |dest| {
                            if (target_room == null or !std.mem.eql(u8, dest, target_room.?)) break :blk true;
                        }
                        break :blk false;
                    } else false;
                    if (hits_other_exit) continue;
                }
                parent[nidx] = cur;
                move_dir[nidx] = @intCast(d);
                queue[tail] = nidx;
                tail += 1;
            }
        }
        const use_exit = parent[goal_idx] == std.math.maxInt(usize);
        if (use_exit and exit_idx == null) return error.UnreachableTile;

        var steps: std.ArrayListUnmanaged(field.Direction) = .empty;
        defer steps.deinit(allocator);
        var cur = if (use_exit) exit_idx.? else goal_idx;
        while (cur != start_idx) {
            try steps.append(allocator, dirs[move_dir[cur]]);
            cur = parent[cur];
        }
        std.mem.reverse(field.Direction, steps.items);
        if (use_exit) try steps.append(allocator, exit_direction);

        var replan = false;
        for (steps.items, 0..) |dir, step_idx| {
            if (state.field_state.room != start_room_idx or state.mode != .field) break;
            if (target_room == null and state.field_state.x == target_x and state.field_state.y == target_y) break;
            const event_ran = try walkStep(state, dir, choices, &choice_cursor);
            if (target_room) |want| {
                if (std.mem.eql(u8, currentRoomName(state), want) and state.field_event == null) break;
            }
            if (event_ran and state.mode == .field and state.field_state.room == start_room_idx) {
                if (target_room != null or (step_idx + 1 < steps.items.len and !(state.field_state.x == target_x and state.field_state.y == target_y))) {
                    replan = true;
                    break;
                }
            }
        }
        if (!replan) break;
    } else {
        std.debug.print("navigation replans exhausted: {s} at {d},{d} toward {?s} {d},{d}\n", .{ currentRoomName(state), state.field_state.x, state.field_state.y, target_room, target_x, target_y });
        return error.FieldEventTimeout;
    }
    if (target_room != null and state.mode == .field and state.field_state.room == start_room_idx and state.field_state.x == target_x and state.field_state.y == target_y and state.field_event == null) {
        // Reaching a doorway cell does not imply holding its source direction.
        var direction: ?field.Direction = null;
        if (route_scripts) |rooms| if (state.field_state.progress.story.scenario) |*story| {
            for (dirs) |held| {
                const destination = rooms.ordinaryTransitionAt(room.id, story, @intCast(state.combat.partyCount()), &state.field_state.local_flags.values, state.field_state.progress.money, @divTrunc(target_x, 8), @divTrunc(target_y, 8), if (state.field_state.world_context) |context| state.package.rooms[context.room].id else null, held) orelse continue;
                if (std.mem.eql(u8, destination, target_room.?)) {
                    direction = held;
                    break;
                }
            }
        };
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = direction } }, .{});
    }
    if (state.field_event != null and state.mode == .field) {
        _ = try drainFieldEventCursor(state, choices, &choice_cursor);
    }
    if (state.mode == .field and state.party_selection == null) {
        try std.testing.expectEqual(choices.len, choice_cursor);
    }
}

const EncounterResolution = enum { injected, played, prepared, retreat };

fn needsFieldMedicine(member: battle.Member, medicine_id: field.items.Id) bool {
    const threshold: u32 = if (medicine_id == .mega_medicine) 3 else 2;
    return member.hp != 0 and @as(u32, member.hp) * 4 < @as(u32, member.max_hp) * threshold;
}

fn prepareWithCarriedMedicine(state: *journey.State, medicine_id: field.items.Id) !void {
    for (0..12) |_| {
        const wounded = for (state.combat.progress.party) |member| {
            if (needsFieldMedicine(member, medicine_id)) break true;
        } else false;
        if (!wounded) break;
        const owner = for (state.combat.progress.party, 0..) |member, index| {
            const has_medicine = for (member.inventory.slots) |item| {
                if (item != null and item.?.id == medicine_id) break true;
            } else false;
            if (has_medicine) break index;
        } else break;
        try restoreWithOwnedMedicine(state, owner, medicine_id, true, null);
    }
}

fn walkThroughEncounters(allocator: std.mem.Allocator, state: *journey.State, target_room: ?[]const u8, target_x: i32, target_y: i32, choices: []const u8, encounters: EncounterResolution) !void {
    for (0..32) |_| {
        if (encounters == .prepared and state.mode == .field) try prepareWithCarriedMedicine(state, .medicine);
        const room_ok = if (target_room) |want| std.mem.eql(u8, currentRoomName(state), want) else false;
        const pos_ok = target_room == null and state.field_state.x == target_x and state.field_state.y == target_y;
        try walkTo(allocator, state, target_room, target_x, target_y, if (room_ok or pos_ok) choices else &.{});
        if (state.mode == .battle) {
            switch (encounters) {
                .injected => try finishBattleWith(state, .victory),
                .played => try finishBattleWithInput(state, .free_will),
                .prepared => try finishBattleWithInput(state, .travel),
                .retreat => try finishBattleWithInput(state, .retreat),
            }
            continue;
        }
        if (target_room) |want| {
            if (!std.mem.eql(u8, currentRoomName(state), want)) continue;
            if (choices.len > 0 and state.field_event != null) _ = try drainFieldEvent(state, choices);
        } else if (state.field_state.x != target_x or state.field_state.y != target_y) {
            continue;
        }
        return;
    }
    return error.FieldEventTimeout;
}

fn interactFacing(state: *journey.State, facing: field.Direction, choices: []const u8) !void {
    errdefer std.debug.print("Interaction facing {s} in {s} at ({d}, {d})\n", .{
        @tagName(facing), currentRoomName(state), state.field_state.x, state.field_state.y,
    });
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = facing } }, .{});
    try std.testing.expect(state.field_event != null);
    _ = try drainFieldEvent(state, choices);
}

fn expectPartyOrder(state: *const journey.State, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, state.combat.progress.party.len);
    for (expected, 0..) |id, idx| {
        try std.testing.expectEqualStrings(id, state.combat.progress.party[idx].id);
    }
}

fn carriesSharedItem(state: *const journey.State, expected: []const u8) bool {
    for (state.shared_items) |maybe| {
        const item = maybe orelse continue;
        if (std.mem.eql(u8, item, expected)) return true;
    }
    return false;
}

fn finishHeadquartersPartySelection(state: *journey.State, admit: ?[]const u8, forced: ?[]const []const u8) !void {
    errdefer if (state.party_selection) |active| {
        std.debug.print("Headquarters party selector stopped in {s}, action {s}, cursor {d}, party count {d}\n", .{
            @tagName(active.menu.phase), @tagName(active.menu.action), active.menu.cursor, state.combat.partyCount(),
        });
    };
    for (0..2000) |tick| {
        if (state.party_selection != null) break;
        try std.testing.expect(state.field_event != null);
        _ = try state.tickWithFieldEvents(.{ .field = .{ .action = (tick & 1) == 0 } }, .{});
    }
    const initial = state.party_selection orelse return error.MissingFieldPartySelectRequest;
    var view: journey.party_selection.View = .{};
    const roster = try view.read(state);
    if (forced) |expected| {
        try std.testing.expectEqual(expected.len, roster.forced.len);
        for (expected, roster.forced) |id, actual| try std.testing.expectEqualStrings(id, actual);
    }
    var choices: [78][]const u8 = undefined;
    const target = if (admit) |id| target: {
        for (initial.menu.list(roster, &choices), 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, id)) break :target i;
        }
        std.debug.print("Headquarters selector does not offer {s}\n", .{id});
        return error.MissingSelectorCandidate;
    } else null;
    for (0..300) |_| {
        const active = state.party_selection orelse break;
        const controls: journey.party_selection.selector.Controls = switch (active.menu.phase) {
            .main => .{
                .confirm = target != null and state.combat.partyCount() == roster.active.len,
                .cancel = target == null or state.combat.partyCount() > roster.active.len,
            },
            .list => list: {
                const index = target orelse return error.UnexpectedSelectorList;
                if (state.combat.partyCount() > roster.active.len) break :list .{ .cancel = true };
                break :list .{
                    .right = active.menu.cursor / 10 < index / 10,
                    .down = active.menu.cursor / 10 == index / 10 and active.menu.cursor < index,
                    .confirm = active.menu.cursor == index,
                };
            },
            .confirmation, .full => .{ .confirm = true },
            else => .{},
        };
        try state.tickPartySelection(controls);
    }
    try std.testing.expect(state.party_selection == null);
    _ = try drainFieldEvent(state, &.{});
}

fn finishHeadquartersPartySelectionFill(state: *journey.State, required: []const u8, preferred: []const []const u8, max_party: usize) !void {
    for (0..2000) |tick| {
        if (state.party_selection != null) break;
        try std.testing.expect(state.field_event != null);
        _ = try state.tickWithFieldEvents(.{ .field = .{ .action = (tick & 1) == 0 } }, .{});
    }
    var view: journey.party_selection.View = .{};
    var choices: [78][]const u8 = undefined;
    var required_added = false;
    for (0..1200) |_| {
        const active = state.party_selection orelse break;
        const roster = try view.read(state);
        if (!required_added) {
            for (roster.active) |member| {
                if (std.mem.eql(u8, member, required)) {
                    required_added = true;
                    break;
                }
            }
        }
        const candidates = active.menu.list(roster, &choices);
        const target: ?usize = if (state.combat.partyCount() < max_party and candidates.len > 0) target: {
            if (!required_added) {
                for (candidates, 0..) |candidate, i| {
                    if (std.mem.eql(u8, candidate, required)) break :target i;
                }
                return error.MissingSelectorCandidate;
            }
            for (preferred) |wanted| {
                for (candidates, 0..) |candidate, i| {
                    if (std.mem.eql(u8, candidate, wanted)) break :target i;
                }
            }
            break :target 0;
        } else null;
        const controls: journey.party_selection.selector.Controls = switch (active.menu.phase) {
            .main => .{ .confirm = target != null, .cancel = target == null },
            .list => list: {
                const index = target orelse break :list .{ .cancel = true };
                const cur_col = active.menu.cursor / 10;
                const cur_row = active.menu.cursor % 10;
                const tgt_col = index / 10;
                const tgt_row = index % 10;
                if (cur_col < tgt_col) break :list .{ .right = true };
                if (cur_col > tgt_col) break :list .{ .left = true };
                if (cur_row < tgt_row) break :list .{ .down = true };
                if (cur_row > tgt_row) break :list .{ .up = true };
                break :list .{ .confirm = true };
            },
            .confirmation, .full => .{ .confirm = true },
            else => .{},
        };
        try state.tickPartySelection(controls);
    }
    try std.testing.expect(state.party_selection == null);
    try std.testing.expect(required_added);
    _ = try drainFieldEvent(state, &.{});
}

fn makeRoomForRecruit(state: *journey.State, eject: ?[]const u8) !void {
    var view: journey.party_selection.View = .{};
    const roster = try view.read(state);
    errdefer if (state.party_selection) |active| {
        std.debug.print("Party removal stopped in {s} at {s}, action {s}, active {any}, forced {any}\n", .{
            @tagName(active.menu.phase), currentRoomName(state), @tagName(active.menu.action), roster.active, roster.forced,
        });
    };
    const selected = for (roster.active, 0..) |member, index| {
        if (!roster.ejectable(member)) continue;
        if (eject == null or std.mem.eql(u8, member, eject.?)) break index;
    } else return error.MissingSelectorCandidate;
    for (0..300) |_| {
        const active = state.party_selection orelse break;
        const removed = state.combat.partyCount() < roster.active.len;
        if (!roster.reserve_slot and removed and active.menu.phase == .main) return;
        try state.tickPartySelection(switch (active.menu.phase) {
            .main => .{ .down = !roster.reserve_slot and active.menu.action == .admit, .confirm = !roster.reserve_slot and active.menu.action == .eject },
            .list => controls: {
                try std.testing.expectEqual(.eject, active.menu.action);
                if (removed) break :controls .{ .cancel = true };
                break :controls .{ .down = active.menu.cursor < selected, .confirm = active.menu.cursor == selected };
            },
            .confirmation => .{ .confirm = true },
            else => .{},
        });
    }
    if (!roster.reserve_slot or state.party_selection != null) return error.HeadquartersEjectionTimeout;
    _ = try drainFieldEvent(state, &.{});
}

test "canonical O01 live scenes dialogue, 2- and 3-option choices, and inn stays without save" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);

    try std.testing.expectEqualStrings("vaa_room_2", currentRoomName(&state));

    // Emperor Barbarosa audience scene: 2-option choice ("Yes, Your Highness." / "I don't wanna.").
    try walkTo(allocator, &state, null, 464, 632, &.{});
    state.field_state.facing = .up;
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expect(state.field_event != null);
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 0, 64));

    // Step to VAA room 1 (Kraze office), walk to (256, 304) for e48_ordinary, talk to Kraze (168, 304),
    // then step east across x=240 (e52_ordinary) -> auto-cutscene returns Home (va1_room_1).
    try walkTo(allocator, &state, "vaa_room_1", 448, 208, &.{});
    try std.testing.expectEqualStrings("vaa_room_1", currentRoomName(&state));
    try walkTo(allocator, &state, null, 256, 304, &.{});
    try std.testing.expect(scenarioBitSet(&state, 0, 8));

    try walkTo(allocator, &state, null, 168, 304, &.{});
    try interactFacing(&state, .up, &.{});
    try walkTo(allocator, &state, "vaa_room_0", 240, 320, &.{});
    // Drain the return-home multi-room cutscene across vaa_room_0 -> vaa_room_10 -> va1_room_0 -> va1_room_1.
    for (0..12) |_| {
        _ = try drainFieldEvent(&state, &.{});
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (std.mem.eql(u8, currentRoomName(&state), "va1_room_1") and state.field_event == null and scenarioBitSet(&state, 0, 32)) break;
    }
    try std.testing.expectEqualStrings("va1_room_1", currentRoomName(&state));
    try std.testing.expect(scenarioBitSet(&state, 0, 32));

    // Gremio stew scene in va1_room_1: 3-option choice ("Pull his ears." / "Tickle him." / "Leave him alone.").
    try walkTo(allocator, &state, null, 312, 96, &.{});
    try interactFacing(&state, .up, &.{1});

    // Walk upstairs to va1_room_2 (triggers e02 Ted join), trigger e14 -> e20 initialization & dinner scene,
    // complete dinner (e13 -> e22), then Cleo's 3-option choice (e11).
    try walkTo(allocator, &state, "va1_room_2", 136, 272, &.{});
    try std.testing.expectEqualStrings("va1_room_2", currentRoomName(&state));
    _ = try drainFieldEvent(&state, &.{});
    try walkTo(allocator, &state, null, 80, 288, &.{0});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try walkTo(allocator, &state, null, 184, 96, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try walkTo(allocator, &state, null, 120, 144, &.{});
    try interactFacing(&state, .up, &.{2});
    try std.testing.expect(scenarioBitSet(&state, 4, 16));

    // Go downstairs -> va1_room_0 -> Inn (va1_room_3) -> Marie's 2-option prompt has Stay / Don't stay and no Save.
    try walkTo(allocator, &state, "va1_room_1", 152, 280, &.{});
    try std.testing.expectEqualStrings("va1_room_1", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{});
    try std.testing.expectEqualStrings("va1_room_0", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_3", 576, 632, &.{});
    try std.testing.expectEqualStrings("va1_room_3", currentRoomName(&state));
    try walkTo(allocator, &state, null, 192, 256, &.{});
    state.field_state.facing = .up;
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    const inn_inst = state.field_event.?.session.instance.?;
    const inn_prog = state.field_event.?.binding.content.program(inn_inst.program_id).?;
    for (inn_prog.commands) |cmd| {
        if (cmd.kind == .choice) {
            try std.testing.expectEqual(@as(?u8, 2), cmd.options);
        }
    }
    const inn_money = state.combat.progress.money;
    _ = try drainFieldEvent(&state, &.{1});
    try std.testing.expectEqual(inn_money, state.combat.progress.money);
    try std.testing.expectEqual(@as(u16, 0), state.field_state.rest_ticks);
    state.combat.progress.party[0].hp = 0;
    state.combat.progress.party[0].status = .unconscious;
    state.combat.progress.money = 0;
    try interactFacing(&state, .up, &.{0});
    try std.testing.expectEqual(.notice, state.menu.phase);
    try std.testing.expectEqual(@as(u32, 0), state.combat.progress.money);
    try std.testing.expectEqual(@as(u16, 0), state.field_state.rest_ticks);
    try std.testing.expectEqual(.unconscious, state.combat.progress.party[0].status);
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
    state.combat.progress.money = inn_money;
    try interactFacing(&state, .up, &.{0});
    try std.testing.expectEqual(inn_money - state.combat.progress.cost(30), state.combat.progress.money);
    try std.testing.expect(state.field_state.rest_ticks > 0);
    for (state.combat.progress.party) |member| {
        try std.testing.expectEqual(member.max_hp, member.hp);
        try std.testing.expectEqual(.healthy, member.status);
        try std.testing.expectEqual(member.max_rune_charges, member.rune_charges);
    }
    for (0..60) |_| _ = try state.tickWithFieldEvents(.{}, .{});

    // Also verify Kraze's Magician's Island 3-option choice (vaa_room_1_e34_interaction when scenario[1]&64).
    try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{});
    try walkTo(allocator, &state, "va1_room_17", 776, 0, &.{});
    try walkTo(allocator, &state, "vaa_room_0", 168, 0, &.{});
    try walkTo(allocator, &state, "vaa_room_1", 312, 96, &.{});
    try std.testing.expectEqualStrings("vaa_room_1", currentRoomName(&state));
    setScenarioBit(&state, 1, 64);
    try walkTo(allocator, &state, null, 168, 304, &.{});
    try interactFacing(&state, .up, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 1, 128));
}

test "canonical O02 live movement traverses palace, halls, town exits, mansion, inn, va1_room_16/17, world_a, and rockland" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);

    // Main palace exit from start room vaa_room_2 -> 1 -> 0 -> 10 -> va1_room_0 -> va1_room_17 -> vaa_room_0 -> vaa_room_1 -> vaa_room_2.
    const main_out_and_back = [_]struct { want: []const u8, x: i32, y: i32 }{
        .{ .want = "vaa_room_1", .x = 448, .y = 208 },
        .{ .want = "vaa_room_0", .x = 256, .y = 832 },
        .{ .want = "vaa_room_10", .x = 296, .y = 744 },
        .{ .want = "va1_room_0", .x = 144, .y = 232 },
        .{ .want = "va1_room_17", .x = 776, .y = 0 },
        .{ .want = "vaa_room_0", .x = 168, .y = 0 },
        .{ .want = "vaa_room_1", .x = 296, .y = 96 },
        .{ .want = "vaa_room_2", .x = 16, .y = 80 },
    };
    for (main_out_and_back) |hop| {
        try walkTo(allocator, &state, hop.want, hop.x, hop.y, &.{});
        try std.testing.expectEqualStrings(hop.want, currentRoomName(&state));
    }

    // Palace side halls from the vaa_room_3 return landing (584, 80) in vaa_room_2: 2 -> 3..9 -> 8..2 -> 1 -> 0 -> 10 -> va1_room_0.
    state.field_state.x = 584;
    state.field_state.y = 80;
    state.field_state.destination = .{ .x = 584, .y = 80 };
    const side_halls = [_]struct { want: []const u8, x: i32, y: i32 }{
        .{ .want = "vaa_room_3", .x = 560, .y = 0 },
        .{ .want = "vaa_room_4", .x = 256, .y = 0 },
        .{ .want = "vaa_room_5", .x = 368, .y = 0 },
        .{ .want = "vaa_room_6", .x = 48, .y = 0 },
        .{ .want = "vaa_room_7", .x = 16, .y = 0 },
        .{ .want = "vaa_room_8", .x = 704, .y = 0 },
        .{ .want = "vaa_room_9", .x = 176, .y = 0 },
        .{ .want = "vaa_room_8", .x = 128, .y = 1000 },
        .{ .want = "vaa_room_7", .x = 240, .y = 1296 },
        .{ .want = "vaa_room_6", .x = 32, .y = 576 },
        .{ .want = "vaa_room_5", .x = 896, .y = 232 },
        .{ .want = "vaa_room_4", .x = 208, .y = 616 },
        .{ .want = "vaa_room_3", .x = 352, .y = 744 },
        .{ .want = "vaa_room_2", .x = 16, .y = 464 },
        .{ .want = "vaa_room_1", .x = 448, .y = 208 },
        .{ .want = "vaa_room_0", .x = 256, .y = 832 },
        .{ .want = "vaa_room_10", .x = 296, .y = 744 },
        .{ .want = "va1_room_0", .x = 144, .y = 232 },
    };
    for (side_halls) |hop| {
        try walkTo(allocator, &state, hop.want, hop.x, hop.y, &.{});
        try std.testing.expectEqualStrings(hop.want, currentRoomName(&state));
    }

    // Town buildings: va1_room_0 <-> 1 <-> 2 <-> 1 <-> 0 <-> 3 <-> 4 <-> 5 -> 4 -> 3 -> 0.
    try walkTo(allocator, &state, "va1_room_1", 1040, 352, &.{});
    try std.testing.expectEqualStrings("va1_room_1", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_2", 136, 272, &.{});
    try std.testing.expectEqualStrings("va1_room_2", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_1", 152, 280, &.{});
    try std.testing.expectEqualStrings("va1_room_1", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{});
    try std.testing.expectEqualStrings("va1_room_0", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_3", 576, 632, &.{});
    try std.testing.expectEqualStrings("va1_room_3", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_4", 304, 160, &.{});
    try std.testing.expectEqualStrings("va1_room_4", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_5", 24, 264, &.{});
    try std.testing.expectEqualStrings("va1_room_5", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_4", 80, 104, &.{});
    try walkTo(allocator, &state, "va1_room_3", 336, 168, &.{});
    try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{});
    try std.testing.expectEqualStrings("va1_room_0", currentRoomName(&state));

    // Secret basement route: va1_room_1_e24 -> va1_room_16 -> va1_room_1 when scenario[4]&(64|8) set inside mansion.
    // (Setting both bits in va1_room_0 fires va1_room_0_e40 which clears scenario[4]&64 before entering va1_room_1.)
    try walkTo(allocator, &state, "va1_room_1", 1040, 352, &.{});
    setScenarioBit(&state, 4, 64 | 8);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expectEqualStrings("va1_room_16", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("va1_room_1", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("va1_room_1", currentRoomName(&state));
    try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{});

    // World map -> Rockland (va2_room_0 <-> va2_room_3) -> World map -> Gregminster.
    try walkTo(allocator, &state, "world_a", 720, 872, &.{});
    try std.testing.expectEqualStrings("world_a", currentRoomName(&state));
    try walkThroughEncounters(allocator, &state, "va2_room_0", 832, 408, &.{}, .injected);
    try std.testing.expectEqualStrings("va2_room_0", currentRoomName(&state));
    // Front door guards (va2_room_0_e05) block (440, 168) until scenario[2]&64 is set; once open, enter va2_room_3 via e06,
    // drain Grady arrival e11 (sets scenario[3]|=32), and return via front door e00 (608, 496 -> 448, 176).
    try walkTo(allocator, &state, null, 440, 168, &.{});
    var guard_choices: usize = 0;
    _ = try walkStep(&state, .up, &.{}, &guard_choices);
    try std.testing.expectEqualStrings("va2_room_0", currentRoomName(&state));
    try std.testing.expectEqual(@as(i32, 440), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 176), state.field_state.y);
    setScenarioBit(&state, 2, 64);
    try walkTo(allocator, &state, "va2_room_3", 440, 168, &.{});
    try std.testing.expectEqualStrings("va2_room_3", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try walkTo(allocator, &state, "va2_room_0", 608, 496, &.{});
    try std.testing.expectEqualStrings("va2_room_0", currentRoomName(&state));
    try walkTo(allocator, &state, "world_a", 0, 624, &.{});
    try std.testing.expectEqualStrings("world_a", currentRoomName(&state));

    try walkThroughEncounters(allocator, &state, "va3_room_0", 560, 640, &.{}, .injected);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expect(state.field_event == null);
    try walkTo(allocator, &state, null, 360, 240, &.{});
    try stepToCoord(&state, .right);
    try std.testing.expectEqualStrings("va3_room_0", currentRoomName(&state));
    try stepToCoord(&state, .up);
    try std.testing.expectEqualStrings("va3_room_2", currentRoomName(&state));
    try walkTo(allocator, &state, null, 336, 240, &.{});
    const keyaki_money = state.combat.progress.money;
    try interactFacing(&state, .up, &.{0});
    try std.testing.expectEqual(keyaki_money - state.combat.progress.cost(70), state.combat.progress.money);
    try std.testing.expect(!scenarioBitSet(&state, 6, 32));
    for (0..state.field_state.rest_ticks) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    try walkTo(allocator, &state, "va3_room_0", 248, 352, &.{});
    try std.testing.expectEqualStrings("va3_room_0", currentRoomName(&state));
    try walkTo(allocator, &state, "world_a", 608, 640, &.{});
    try std.testing.expect(!scenarioBitSet(&state, 6, 16));

    // Both attempts to return after the escape lead back outside. Lenankamp owns the farewell flag.
    setScenarioBit(&state, 6, 8);
    for (0..2) |_| {
        try walkThroughEncounters(allocator, &state, "va1_room_0", 584, 384, &.{}, .injected);
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        try std.testing.expectEqualStrings("world_a", currentRoomName(&state));
        try std.testing.expect(!scenarioBitSet(&state, 6, 16));
    }
}

fn walkOutToRockland(allocator: std.mem.Allocator, state: *journey.State) !void {
    const hops = [_]struct { want: []const u8, x: i32, y: i32 }{
        .{ .want = "vaa_room_1", .x = 448, .y = 208 },
        .{ .want = "vaa_room_0", .x = 256, .y = 832 },
        .{ .want = "vaa_room_10", .x = 296, .y = 744 },
        .{ .want = "va1_room_0", .x = 144, .y = 232 },
        .{ .want = "world_a", .x = 720, .y = 872 },
        .{ .want = "va2_room_0", .x = 832, .y = 408 },
    };
    for (hops) |hop| {
        try walkThroughEncounters(allocator, state, hop.want, hop.x, hop.y, &.{}, .injected);
        try std.testing.expectEqualStrings(hop.want, currentRoomName(state));
    }
}

fn finishBattleWith(state: *journey.State, phase: battle.Phase) !void {
    state.combat.phase = phase;
    var ticks: usize = 0;
    while (state.mode == .battle or state.mode == .defeat) : (ticks += 1) {
        if (ticks >= 256) return error.BattleFinishTimeout;
        if (state.mode == .battle and phase == .defeat) {
            _ = try state.tickWithFieldEvents(.{}, .{});
            continue;
        }
        if (state.mode == .defeat and state.combat.hasDepartureFlights()) {
            _ = try state.tickWithFieldEvents(.{}, .{});
            continue;
        }
        _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
        if (state.field_event != null and state.mode == .field) break;
    }
}

fn restoreWithMedicine(state: *journey.State, owner: usize, critical_only: bool) !void {
    return restoreWithOwnedMedicine(state, owner, .medicine, critical_only, null);
}

fn restoreWithOwnedMedicine(state: *journey.State, owner: usize, medicine_id: field.items.Id, critical_only: bool, only_target: ?usize) !void {
    const slot = for (state.combat.progress.party[owner].inventory.slots, 0..) |item, index| {
        if (item != null and item.?.id == medicine_id) break index;
    } else return error.MissingMedicine;
    const confirm: pause_menu.Input = .{ .field = .{ .action = true } };
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
    try std.testing.expectEqual(.root, state.menu.phase);
    while (state.menu.selected != .item) _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .up } }, .{});
    _ = try state.tickWithFieldEvents(confirm, .{});
    while (state.menu.member != owner) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    for (0..slot) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    for (state.combat.progress.party, 0..) |*member, target| {
        if (only_target != null and only_target.? != target) continue;
        if (member.hp == 0 or (critical_only and !needsFieldMedicine(member.*, medicine_id))) continue;
        while (member.hp < member.max_hp) {
            const medicine = state.combat.progress.party[owner].inventory.slots[slot] orelse {
                if (critical_only) break;
                return error.MissingMedicine;
            };
            if (medicine.id != medicine_id) {
                if (critical_only) break;
                return error.MissingMedicine;
            }
            const previous_hp = member.hp;
            _ = try state.tickWithFieldEvents(confirm, .{});
            _ = try state.tickWithFieldEvents(confirm, .{});
            try std.testing.expectEqual(.item_target, state.menu.phase);
            const hops = (target + state.combat.partyCount() - owner) % state.combat.partyCount();
            for (0..hops) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
            _ = try state.tickWithFieldEvents(confirm, .{});
            try std.testing.expect(member.hp > previous_hp);
            _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
        }
    }
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
}

fn summitInput(combat: *const battle.State) battle.Input {
    const sydonia = 1;
    switch (combat.phase) {
        .intro, .confirm_round, .victory => return .{ .confirm = true },
        .battle_menu => return if (combat.selection == 0) .{ .confirm = true } else .{ .up = true },
        .command, .item, .item_target => {
            const has_medicine = for (combat.progress.party[combat.actor].inventory.slots, 0..) |entry, slot| {
                if (entry != null and entry.?.id == .medicine and combat.canSelectItem(combat.actor, slot)) break slot;
            } else null;
            var recipient: ?usize = null;
            if (has_medicine != null) for (combat.progress.party, 0..) |member, i| {
                if (!combat.participates(i) or member.hp > 14 or member.max_hp - member.hp < 20) continue;
                const already_covered = for (combat.actions) |prior| {
                    if (prior != null and prior.? == .item and prior.?.item.target == i) break true;
                } else false;
                if (already_covered) continue;
                if (recipient == null or member.hp < combat.progress.party[recipient.?].hp) recipient = i;
            };
            if (combat.phase == .command) {
                const desired: @TypeOf(combat.picker.selected) = if (recipient != null) .item else if (combat.firstAttackTarget(combat.actor) != null) .attack else .defend;
                return if (combat.picker.selected == desired) .{ .confirm = true } else .{ .down = true };
            }
            if (combat.phase == .item) return if (combat.selection == has_medicine.?) .{ .confirm = true } else .{ .down = true };
            return if (combat.selection == recipient.?) .{ .confirm = true } else .{ .right = true };
        },
        .target => return if (combat.selection == sydonia or !combat.canSelectTarget(sydonia)) .{ .confirm = true } else .{ .right = true },
        .loot => return .{ .cancel = true },
        .confirm_leave_loot => return if (combat.yes) .{ .confirm = true } else .{ .right = true },
        else => return .{},
    }
}

fn strongestDamageSpellTier(combat: *const battle.State, include_source_rules: bool) ?usize {
    const rune = combat.rune(combat.actor) orelse return null;
    var tier: usize = rune.spells.len;
    while (tier > 0) {
        tier -= 1;
        const index = rune.spells[tier] orelse continue;
        const spell = combat.content.systems.?.spells[index];
        if (spell.allies or !combat.canSelectSpell(index)) continue;
        if (spell.kind == .damage) return tier;
        if (!include_source_rules) continue;
        const host = combat.integrationHost() orelse continue;
        const rule = combat.spellRuleIndex(host, index) orelse continue;
        for (host.spellRules().spells[rule].steps) |step| {
            if (std.mem.eql(u8, step.op, "damage")) return tier;
        }
    }
    return null;
}

fn forestCombatInput(combat: *const battle.State) battle.Input {
    return switch (combat.phase) {
        .command => blk: {
            const desired: @TypeOf(combat.picker.selected) = if (strongestDamageSpellTier(combat, false) != null)
                .rune
            else if (combat.firstAttackTarget(combat.actor) != null)
                .attack
            else
                .defend;
            break :blk if (combat.picker.selected == desired) .{ .confirm = true } else .{ .down = true };
        },
        .spell => if (strongestDamageSpellTier(combat, false)) |tier|
            if (combat.selection == tier) .{ .confirm = true } else .{ .down = true }
        else
            .{ .cancel = true },
        .target, .spell_target => .{ .confirm = true },
        else => summitInput(combat),
    };
}

fn regionEEncounter(encounter: []const u8) bool {
    return std.mem.startsWith(u8, encounter, "area_e_") or
        std.mem.startsWith(u8, encounter, "ve2_dir_") or std.mem.startsWith(u8, encounter, "ve3_dir_");
}

fn travelCombatInput(combat: *const battle.State) battle.Input {
    const encounter = combat.content.encounters[combat.encounter].id;
    const palace_guards = std.mem.startsWith(u8, encounter, "vad_dir_");
    const golden_hydra = std.mem.eql(u8, encounter, "vzv_dir_194d8_1");
    const neclord = std.mem.eql(u8, encounter, "ve3_dir_8ddac_1");
    const crystal_core = std.mem.eql(u8, encounter, "vf2_dir_5b038_1");
    const moravia = std.mem.startsWith(u8, encounter, "vh1_dir_");
    const fortress = std.mem.startsWith(u8, encounter, "vs1_dir_");
    const region_e = regionEEncounter(encounter);
    const late_encounter = crystal_core or moravia or fortress or palace_guards or
        std.mem.eql(u8, encounter, "vac_dir_66b70_1") or golden_hydra;
    switch (combat.phase) {
        .command, .spell, .item, .item_target, .target, .spell_target => {},
        .battle_menu => return if (combat.selection == 0) .{ .confirm = true } else .{ .up = true },
        else => return summitInput(combat),
    }
    var awake: usize = 0;
    for (0..combat.enemyCount()) |enemy| {
        if (combat.enemy_hp[enemy] > 0 and combat.actor_conditions[combat.partyCount() + enemy].sleep_turns == 0) awake += 1;
    }
    const fire_spear_route = std.mem.startsWith(u8, encounter, "area_g_") or std.mem.startsWith(u8, encounter, "vg2_dir_");
    const prefer_group_damage = palace_guards or ((fire_spear_route or region_e or moravia) and awake > 1) or
        std.mem.eql(u8, encounter, "vb3_wheel_monster") or
        std.mem.eql(u8, encounter, "vb3_dir_67da4_1");
    var group_spell: ?usize = null;
    var spell_tier: ?usize = null;
    if (combat.rune(combat.actor)) |rune| {
        if (prefer_group_damage) for (rune.spells, 0..) |entry, tier| {
            const index = entry orelse continue;
            const spell = combat.content.systems.?.spells[index];
            if (spell.group and !spell.allies and combat.canSelectSpell(index) and
                (spell.kind == .damage or std.mem.eql(u8, spell.name, "Black Shadow") or
                    ((palace_guards or moravia) and std.mem.eql(u8, spell.name, "Hell")))) group_spell = tier;
        };
        for (rune.spells, 0..) |entry, tier| if (entry) |index| {
            if (combat.content.systems.?.spells[index].kind == .sleep and combat.enemyCount() >= 4 and awake >= 3 and combat.canSelectSpell(index)) {
                spell_tier = tier;
                break;
            }
        };
        if (spell_tier == null) spell_tier = strongestDamageSpellTier(combat, late_encounter or region_e);
        if ((!late_encounter or palace_guards or moravia) and spell_tier == null and std.mem.eql(u8, rune.id, "soul_eater")) {
            if (rune.spells[0]) |index| if (combat.canSelectSpell(index)) {
                spell_tier = 0;
            };
        }
        if (group_spell != null) spell_tier = group_spell;
        if (golden_hydra and (std.mem.eql(u8, rune.id, "fire") or std.mem.eql(u8, rune.id, "rage"))) spell_tier = null;
        if (neclord and !std.mem.eql(u8, rune.id, "soul_eater")) spell_tier = null;
    }
    var medicine: ?usize = null;
    for (combat.progress.party[combat.actor].inventory.slots, 0..) |entry, slot| {
        const item = entry orelse continue;
        if (!combat.canSelectItem(combat.actor, slot)) continue;
        if ((late_encounter or region_e) and item.id == .mega_medicine) {
            medicine = slot;
            break;
        }
        if (item.id == .medicine and medicine == null) {
            medicine = slot;
            if (!golden_hydra and !region_e and !crystal_core and !moravia and !fortress) break;
        }
    }
    var recipient: ?usize = null;
    if (medicine != null) for (combat.progress.party, 0..) |member, index| {
        if (!combat.participates(index) or member.max_hp - member.hp < 20 or @as(u32, member.hp) * 4 >= @as(u32, member.max_hp) * 3) continue;
        const covered = for (combat.actions) |action| {
            if (action != null and action.? == .item and action.?.item.target == index) break true;
        } else false;
        if (!covered and (recipient == null or member.hp < combat.progress.party[recipient.?].hp)) recipient = index;
    };
    // Brace against the opening attacks while Odessa puts a large group to sleep.
    const brace = combat.round == 1 and combat.enemyCount() >= 4 and for (combat.progress.party, 0..) |member, index| {
        const rune = combat.rune(index) orelse continue;
        if (combat.participates(index) and combat.actor_conditions[index].sleep_turns == 0 and !combat.actor_conditions[index].rune_blocked and
            std.mem.eql(u8, rune.id, "wind") and member.rune_charges[0] > 0) break true;
    } else false;
    return switch (combat.phase) {
        .battle_menu => if (combat.selection == 0) .{ .confirm = true } else .{ .up = true },
        .command => blk: {
            const casting_control = if (spell_tier) |tier| control: {
                const spell = combat.content.systems.?.spells[combat.rune(combat.actor).?.spells[tier].?];
                break :control spell.kind == .sleep or ((palace_guards or moravia) and std.mem.eql(u8, spell.name, "Deadly Fingertips"));
            } else false;
            const can_attack = combat.firstAttackTarget(combat.actor) != null;
            const ranged_attack = palace_guards and can_attack and combat.weaponRange(combat.actor) == .long;
            const judgment = (golden_hydra or crystal_core or fortress) and spell_tier == 3 and combat.hasRune(combat.actor, "soul_eater");
            const desired: @TypeOf(combat.picker.selected) = if (casting_control or group_spell != null or judgment) .rune else if (recipient != null and !ranged_attack) .item else if (brace) .defend else if (spell_tier != null) .rune else if (can_attack) .attack else .defend;
            break :blk if (combat.picker.selected == desired) .{ .confirm = true } else .{ .down = true };
        },
        .spell => if (spell_tier) |tier| if (combat.selection == tier) .{ .confirm = true } else .{ .down = true } else .{ .cancel = true },
        .item => if (combat.selection == medicine.?) .{ .confirm = true } else .{ .down = true },
        .item_target => if (combat.selection == recipient.?) .{ .confirm = true } else .{ .right = true },
        .target, .spell_target => blk: {
            const deadly_fingertips = combat.phase == .spell_target and
                std.mem.eql(u8, combat.content.systems.?.spells[combat.spell_slot].name, "Deadly Fingertips");
            var target: ?usize = null;
            for (0..combat.enemyCount()) |index| {
                if (!combat.canSelectTarget(index)) continue;
                if (deadly_fingertips and (combat.enemy(index).death_immune orelse false)) continue;
                if (target) |prior| {
                    if (deadly_fingertips) {
                        if (palace_guards and combat.enemyRow(index) != combat.enemyRow(prior)) {
                            if (combat.enemyRow(index) == .back) target = index;
                            continue;
                        }
                        if (combat.enemy(index).stats.attack > combat.enemy(prior).stats.attack) target = index;
                        continue;
                    }
                    const awake_target = combat.actor_conditions[combat.partyCount() + index].sleep_turns == 0;
                    const awake_prior = combat.actor_conditions[combat.partyCount() + prior].sleep_turns == 0;
                    if (awake_target != awake_prior) {
                        if (awake_target) target = index;
                        continue;
                    }
                    // Leave front targets for short and medium weapons when a rear target is reachable.
                    if (combat.enemyRow(index) != combat.enemyRow(prior)) {
                        if (combat.enemyRow(index) == .back) target = index;
                        continue;
                    }
                    if (combat.enemy_hp[index] >= combat.enemy_hp[prior]) continue;
                }
                target = index;
            }
            break :blk if (target == null or combat.selection == target.?) .{ .confirm = true } else .{ .right = true };
        },
        else => summitInput(combat),
    };
}

fn arrangeEarlyBattleParty(state: *journey.State) !void {
    const viktor_in_back = state.combat.partyRow(3) == .back;
    const cleo_in_front = state.combat.partyRow(2) == .front;
    if (!viktor_in_back and !cleo_in_front) return;
    const from = state.combat.formationSlot(if (viktor_in_back) 3 else 2);
    const to = if (viktor_in_back)
        (if (cleo_in_front) state.combat.formationSlot(2) else 1)
    else
        3;
    try swapFieldFormation(state, from, to);
}

fn swapFieldFormation(state: *journey.State, from: usize, to: usize) !void {
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
    try std.testing.expectEqual(.root, state.menu.phase);
    while (state.menu.selected != .formation) _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(.formation, state.menu.phase);
    while (state.menu.member != from) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    while (state.menu.target != to) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
}

fn finishBattleWithInput(state: *journey.State, strategy: enum { free_will, defend, guard_second_round, summit, forest, travel, retreat, scripted_loss }) !void {
    const encounter = state.combat.content.encounters[state.combat.encounter].id;
    var entry_hp: [6]u16 = @splat(0);
    var entry_charges: [6][4]u16 = @splat(@splat(0));
    for (state.combat.progress.party, 0..) |member, slot| {
        entry_hp[slot] = member.hp;
        entry_charges[slot] = member.rune_charges;
    }
    const menu_selection: usize = switch (strategy) {
        .free_will => 3,
        .retreat => 1,
        else => 0,
    };
    const outcome: @TypeOf(state.combat.phase) = switch (strategy) {
        .retreat => .escaped,
        .scripted_loss => .defeat,
        else => .victory,
    };
    for (0..40000) |_| {
        const input: battle.Input = switch (strategy) {
            .summit => summitInput(state.combat),
            .forest => forestCombatInput(state.combat),
            .travel => travelCombatInput(state.combat),
            else => switch (state.combat.phase) {
                .battle_menu => if (state.combat.selection == menu_selection) .{ .confirm = true } else .{ .down = true },
                .command => if (state.combat.picker.selected == .defend) .{ .confirm = true } else .{ .down = true },
                .intro, .confirm_round, .victory, .escaped, .defeat => .{ .confirm = true },
                .loot => .{ .cancel = true },
                .confirm_leave_loot => if (state.combat.yes) .{ .confirm = true } else .{ .right = true },
                .resolving => .{},
                else => break,
            },
        };
        _ = try state.tickWithFieldEvents(.{}, input);
        if (state.mode == .field and state.combat.phase == outcome) return;
        if ((state.mode != .battle and !(strategy == .scripted_loss and state.mode == .defeat)) or
            state.combat.presentation_refusal.len != 0) break;
    }
    std.debug.print("Combat input stopped at {s}, round {d}, phase {s}: {s}\n", .{
        encounter, state.combat.round, @tagName(state.combat.phase), state.combat.presentation_refusal,
    });
    if (state.combat.coordinator) |clock| std.debug.print("  Turn coordinator {s} at update {d}, owner {d}, action {any}\n", .{
        @tagName(clock.stage), clock.elapsed, clock.current_actor, clock.cached,
    });
    if (state.combat.active) |effect| std.debug.print("  Active {s} from {d} to {d}\n", .{
        @tagName(effect.kind), effect.actor, effect.target,
    });
    for (state.combat.progress.party, 0..) |member, slot| {
        std.debug.print("  {s}: level {d}, HP {d}/{d}, {s}; entered with {d} HP and rune charges {any}\n", .{
            member.id, state.combat.progress.party[slot].level, member.hp, member.max_hp, @tagName(member.status), entry_hp[slot], entry_charges[slot],
        });
    }
    for (state.combat.enemy_hp[0..state.combat.enemyCount()], 0..) |hp, slot| {
        if (hp > 0) std.debug.print("  Enemy slot {d}: {d} HP remaining\n", .{ slot, hp });
    }
    return error.UnexpectedBattleOutcome;
}

fn freeRocklandPrisoners(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkTo(allocator, state, "va2_room_0", 8, 232, &.{});
    try std.testing.expectEqualStrings("va2_room_0", currentRoomName(state));
    try walkTo(allocator, state, null, 232, 80, &.{});
    try interactFacing(state, .up, &.{});
    try std.testing.expect(scenarioBitSet(state, 7, 8));
    try walkTo(allocator, state, "va2_room_3", 320, 120, &.{});
    try walkTo(allocator, state, null, 440, 368, &.{});
    try std.testing.expect(scenarioBitSet(state, 7, 16));
    try walkTo(allocator, state, "va2_room_0", 616, 496, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expect(scenarioBitSet(state, 7, 32));
}

fn enterLenankampHideout(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkThroughEncounters(allocator, state, "va3_room_0", 560, 640, &.{}, .retreat);
    try walkTo(allocator, state, null, 360, 240, &.{});
    try stepToCoord(state, .right);
    try stepToCoord(state, .up);
    try std.testing.expectEqualStrings("va3_room_2", currentRoomName(state));
}

fn reachTigerwolfInnApproach(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkTo(allocator, state, "va3_room_2", 296, 48, &.{});
    try walkTo(allocator, state, "va3_room_0", 248, 352, &.{});
    try walkTo(allocator, state, "world_a", 608, 640, &.{});
    try walkThroughEncounters(allocator, state, "va8_room_0", 344, 440, &.{}, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expect(scenarioBitSet(state, 8, 2));
    try finishFieldOrEncountersUntilRoom(allocator, state, &.{
        .{ .want = "va8_room_1", .x = 352, .y = 56 },
        .{ .want = "va8_room_2", .x = 280, .y = 56 },
        .{ .want = "va8_room_3", .x = 488, .y = 56 },
        .{ .want = "va8_room_4", .x = 184, .y = 56 },
        .{ .want = "va8_room_5", .x = 152, .y = 56 },
    }, .retreat);
}

fn exitTigerwolfNorth(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkTo(allocator, state, null, 184, 128, &.{});
    try finishFieldOrEncountersUntilRoom(allocator, state, &.{
        .{ .want = "va8_room_6", .x = 264, .y = 48 },
        .{ .want = "va8_room_7", .x = 280, .y = 56 },
        .{ .want = "va8_room_8", .x = 184, .y = 56 },
        .{ .want = "va8_room_9", .x = 104, .y = 56 },
        .{ .want = "world_a", .x = 152, .y = 56 },
    }, .retreat);
}

fn returnTigerwolfSouth(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkThroughEncounters(allocator, state, "va8_room_9", 272, 280, &.{}, .retreat);
    try finishFieldOrEncountersUntilRoom(allocator, state, &.{
        .{ .want = "va8_room_8", .x = 104, .y = 480 },
        .{ .want = "va8_room_7", .x = 168, .y = 320 },
        .{ .want = "va8_room_6", .x = 392, .y = 480 },
        .{ .want = "va8_room_5", .x = 248, .y = 320 },
        .{ .want = "va8_room_4", .x = 104, .y = 320 },
        .{ .want = "va8_room_3", .x = 392, .y = 320 },
        .{ .want = "va8_room_2", .x = 184, .y = 320 },
        .{ .want = "va8_room_1", .x = 520, .y = 320 },
        .{ .want = "va8_room_0", .x = 16, .y = 280 },
        .{ .want = "world_a", .x = 176, .y = 320 },
    }, .prepared);
}

test "canonical O03 rockland battle triggers e35/e36/e37 enforce escape=false, defeat=game_over, and victory without auto-chaining" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Case 1: e35 choice 1 ("Don't fight") clears without battle and steps outside trigger strip;
    // re-entering e35 with choice 0 ("Fight") enters va2_s0_e11, disables escape, and defeat leads to game_over.
    {
        var harness = try CanonicalHarness.load(allocator, io);
        defer harness.deinit();
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);

        try walkOutToRockland(allocator, &state);
        setScenarioBit(&state, 4, 1);

        // Step into e35 (x=58..62, y=52 -> px 464..496, 416) and select option 1 ("Don't fight").
        try walkTo(allocator, &state, null, 464, 416, &.{1});
        try std.testing.expectEqual(journey.Mode.field, state.mode);
        try std.testing.expect(!scenarioBitSet(&state, 34, 8));
        try std.testing.expectEqual(@as(i32, 464), state.field_state.x);
        try std.testing.expectEqual(@as(i32, 424), state.field_state.y);
        for (0..20) |_| {
            _ = try state.tickWithFieldEvents(.{}, .{});
            try std.testing.expectEqual(journey.Mode.field, state.mode);
            try std.testing.expect(state.field_event == null);
        }

        // Re-step onto e35 and select option 0 ("Fight").
        var cursor: usize = 0;
        _ = try walkStep(&state, .up, &.{0}, &cursor);
        try std.testing.expectEqual(@as(usize, 1), cursor);
        try std.testing.expectEqual(journey.Mode.battle, state.mode);
        const enc = state.combat.content.encounters[state.combat.encounter];
        try std.testing.expectEqualStrings("va2_s0_e11", enc.id);
        try std.testing.expectEqualStrings("va2_s0", enc.battlefield.?);
        try std.testing.expectEqual(@as(usize, 3), enc.enemies.len);
        try std.testing.expect(!state.combat.canLetGo());

        try finishBattleWith(&state, .defeat);
        try std.testing.expectEqual(journey.Mode.game_over, state.mode);
    }

    // Case 2: e36 trigger -> Fight -> victory returns cleanly to va2_room_0 with scenario[34]|=8,
    // does NOT auto-chain into another battle, and e35/e36/e37 do not re-trigger afterwards.
    {
        var harness = try CanonicalHarness.load(allocator, io);
        defer harness.deinit();
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);

        try walkOutToRockland(allocator, &state);
        setScenarioBit(&state, 4, 1);

        try walkTo(allocator, &state, null, 592, 416, &.{0});
        try std.testing.expectEqual(journey.Mode.battle, state.mode);
        try std.testing.expectEqualStrings("va2_s0_e11", state.combat.content.encounters[state.combat.encounter].id);
        try std.testing.expect(!state.combat.canLetGo());

        try finishBattleWith(&state, .victory);
        if (state.field_event != null and state.mode == .field) {
            _ = try drainFieldEvent(&state, &.{});
        }
        try std.testing.expectEqual(journey.Mode.field, state.mode);
        try std.testing.expectEqualStrings("va2_room_0", currentRoomName(&state));
        try std.testing.expect(scenarioBitSet(&state, 34, 8));

        for (0..30) |_| {
            _ = try state.tickWithFieldEvents(.{}, .{});
            try std.testing.expectEqual(journey.Mode.field, state.mode);
            try std.testing.expect(state.field_event == null);
        }

        // Stepping across e35, e36, and e37 trigger coordinates never re-triggers va2_s0_e11 once won.
        try walkTo(allocator, &state, null, 464, 416, &.{});
        try walkTo(allocator, &state, null, 592, 416, &.{});
        try walkTo(allocator, &state, null, 496, 256, &.{});
        try std.testing.expectEqual(journey.Mode.field, state.mode);
    }

    // Case 3: e37 gate trigger also connects directly to va2_s0_e11.
    {
        var harness = try CanonicalHarness.load(allocator, io);
        defer harness.deinit();
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);

        try walkOutToRockland(allocator, &state);
        setScenarioBit(&state, 4, 1);

        try walkTo(allocator, &state, null, 496, 256, &.{0});
        try std.testing.expectEqual(journey.Mode.battle, state.mode);
        try std.testing.expectEqualStrings("va2_s0_e11", state.combat.content.encounters[state.combat.encounter].id);
        try std.testing.expect(!state.combat.canLetGo());
    }
}

test "canonical O04 and B16 party joins/leaves commit in source order and soul eater persists across save and load" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var soul_eater_t0_spell: usize = 0;
    var expected_story_before_save: field.game_state.event_runtime.StoryState = undefined;
    var expected_charges: [4]u16 = undefined;

    {
        var harness = try CanonicalHarness.load(allocator, io);
        defer harness.deinit();
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);

        try expectPartyOrder(&state, &.{"hero"});
        try std.testing.expect(state.combat.progress.party[0].rune == null);

        // Talk to Emperor & Kraze -> home cutscene lands in va1_room_1.
        try walkTo(allocator, &state, null, 464, 632, &.{});
        try interactFacing(&state, .up, &.{0});
        try walkTo(allocator, &state, "vaa_room_1", 448, 208, &.{});
        try walkTo(allocator, &state, null, 256, 304, &.{});
        try walkTo(allocator, &state, null, 168, 304, &.{});
        try interactFacing(&state, .up, &.{});
        try walkTo(allocator, &state, "vaa_room_0", 240, 320, &.{});
        for (0..12) |_| {
            _ = try drainFieldEvent(&state, &.{});
            _ = try state.tickWithFieldEvents(.{}, .{});
            if (std.mem.eql(u8, currentRoomName(&state), "va1_room_1") and state.field_event == null and scenarioBitSet(&state, 0, 32)) break;
        }
        try expectPartyOrder(&state, &.{"hero"});

        // Enter va1_room_2 -> e02 commits Ted join -> [hero, ted].
        try walkTo(allocator, &state, "va1_room_2", 136, 272, &.{});
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        try expectPartyOrder(&state, &.{ "hero", "ted" });

        // Walk past e14 (x=80, y=264 -> choice 0 aligns to 80, 288), then trigger e21 (80, 288) -> Ted leaves -> [hero].
        try walkTo(allocator, &state, null, 80, 288, &.{0});
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        try expectPartyOrder(&state, &.{"hero"});

        // Trigger e13 (184, 96 -> scenario[35]|=16, aligns to 24, 296), then e22 (24, 296) -> Gremio joins -> [hero, gremio].
        try walkTo(allocator, &state, null, 184, 96, &.{});
        try std.testing.expectEqual(@as(i32, 24), state.field_state.x);
        try std.testing.expectEqual(@as(i32, 296), state.field_state.y);
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        try expectPartyOrder(&state, &.{ "hero", "gremio" });

        // Walk down to va1_room_1 -> e22 commits Pahn & Cleo in order -> [hero, gremio, pahn, cleo].
        try walkTo(allocator, &state, "va1_room_1", 152, 280, &.{});
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        try expectPartyOrder(&state, &.{ "hero", "gremio", "pahn", "cleo" });

        // Walk toward the front door (184, 368) -> e20 commits Ted join -> [hero, gremio, pahn, cleo, ted].
        try walkTo(allocator, &state, null, 184, 368, &.{});
        try expectPartyOrder(&state, &.{ "hero", "gremio", "pahn", "cleo", "ted" });

        // Seed the completed Rockland audience and return, then e39 commits Ted leave.
        setScenarioBit(&state, 3, 32);
        setScenarioBit(&state, 4, 2);
        try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{});
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        try expectPartyOrder(&state, &.{ "hero", "gremio", "pahn", "cleo" });

        // Advance Hero 6 levels (matching early campaign growth past magic_thresholds[0][0] == 15)
        // so tier-0 Soul Eater charge slot is ready when Ted passes the rune.
        for (0..6) |_| {
            var rolls: [7]u15 = undefined;
            for (&rolls) |*roll| roll.* = state.combat.roll();
            state.combat.levelUp(0, rolls);
        }

        // Re-enter va1_room_1 under Imperial ambush (scenario[4]|=8, scenario[5]|=1|128 -> e32 places Ted at 72, 200 and sets scenario[5]|=4):
        // va1_room_1_e08_interaction commits Pahn leave and grants Soul Eater to Hero (B16); scenario[5]&128 spawns Viktor.
        setScenarioBit(&state, 4, 8);
        setScenarioBit(&state, 5, 1 | 128);
        try walkTo(allocator, &state, "va1_room_1", 1040, 352, &.{});
        try walkTo(allocator, &state, null, 72, 208, &.{});
        // Refuse first prompt ("No."), then accept both ("What is it, Ted?" + "I'll take it,Ted.Don't worry.").
        try interactFacing(&state, .up, &.{ 1, 0, 0 });
        try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo" });

        const granted_rune = state.combat.rune(0) orelse return error.MissingSoulEater;
        try std.testing.expectEqualStrings("soul_eater", granted_rune.id);
        try std.testing.expectEqual(@as(u8, 1), state.combat.progress.story.scenario.?.soul_eater_spell_slots);
        try std.testing.expectEqual(@as(?usize, null), granted_rune.spells[1]);
        try std.testing.expectEqual(@as(?u8, 1), state.combat.runeByteFor(0));
        soul_eater_t0_spell = granted_rune.spells[0].?;
        try std.testing.expect(state.combat.hasMagic(0));
        try std.testing.expect(state.combat.canCast(0, soul_eater_t0_spell));
        try std.testing.expect(state.menu.isEnabled(.rune));
        expected_charges = state.combat.progress.party[0].rune_charges;

        // Trigger front-hall e33 escape ("All right." choice 1 -> exits to va1_room_0 at 1144, 264) and accept Viktor (e37 choice 1).
        try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{1});
        try walkTo(allocator, &state, null, 504, 200, &.{});
        try interactFacing(&state, .up, &.{1});
        try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor" });
        try std.testing.expectEqual(@as(u8, 7), state.combat.progress.party[3].level);

        // Also verify character stats and Soul Eater persist across room transition into Marie's Inn before saving.
        try walkTo(allocator, &state, "va1_room_3", 576, 632, &.{});
        try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor" });
        try std.testing.expectEqual(@as(u8, 7), state.combat.progress.party[3].level);
        try std.testing.expectEqualStrings("soul_eater", state.combat.rune(0).?.id);

        expected_story_before_save = state.combat.progress.story.scenario.?;
        try journey.save(io, allocator, temp.dir, state);
    }

    // Reload from disk in a fresh CanonicalHarness + Boot and confirm Soul Eater, access, party order, levels, and story persist.
    {
        var reloaded_harness = try CanonicalHarness.load(allocator, io);
        defer reloaded_harness.deinit();
        var members: [6]battle.Member = undefined;
        var reloaded = try reloaded_harness.newState(&members);
        defer reloaded.releaseRestoredSave();

        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();

        try std.testing.expectEqualStrings("va1_room_3", currentRoomName(&reloaded));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor" });
        try std.testing.expectEqual(@as(u8, 7), reloaded.combat.progress.party[3].level);
        try std.testing.expectEqualStrings("soul_eater", reloaded.combat.rune(0).?.id);
        try std.testing.expectEqual(@as(?u8, 1), reloaded.combat.runeByteFor(0));
        try std.testing.expectEqualSlices(u16, &expected_charges, &reloaded.combat.progress.party[0].rune_charges);
        try std.testing.expect(reloaded.combat.hasMagic(0));
        try std.testing.expect(reloaded.combat.canCast(0, soul_eater_t0_spell));
        try std.testing.expect(reloaded.menu.isEnabled(.rune));
        try std.testing.expectEqualSlices(u8, &expected_story_before_save.scenario, &reloaded.combat.progress.story.scenario.?.scenario);

        // Verify Soul Eater stays castable once entering combat on world_a after load (without mutating scenario after restore).
        try walkTo(allocator, &reloaded, "va1_room_0", 176, 384, &.{});
        try walkTo(allocator, &reloaded, "world_a", 720, 872, &.{0});
        for (0..8) |pass| {
            const tx: i32 = if ((pass & 1) == 0) 792 else 480;
            const ty: i32 = if ((pass & 1) == 0) 624 else 320;
            try walkTo(allocator, &reloaded, null, tx, ty, &.{});
            if (reloaded.mode == .battle) break;
        }
        try std.testing.expectEqual(journey.Mode.battle, reloaded.mode);
        try std.testing.expect(reloaded.combat.canCast(0, soul_eater_t0_spell));
        try std.testing.expectEqualStrings("soul_eater", reloaded.combat.rune(0).?.id);
        try finishBattleWithInput(&reloaded, .retreat);

        try walkThroughEncounters(allocator, &reloaded, "va3_room_0", 560, 640, &.{}, .retreat);
        try std.testing.expectEqual(@as(i32, 376), reloaded.field_state.x);
        try std.testing.expectEqual(@as(i32, 728), reloaded.field_state.y);
        try std.testing.expect(!scenarioBitSet(&reloaded, 6, 16));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor" });
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 6, 16));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo" });
        try std.testing.expectEqual(@as(i32, 656), reloaded.field_state.y);

        try walkTo(allocator, &reloaded, "world_a", 376, 736, &.{});
        try std.testing.expectEqual(@as(i32, 560), reloaded.field_state.x);
        try std.testing.expectEqual(@as(i32, 656), reloaded.field_state.y);
        try walkThroughEncounters(allocator, &reloaded, "va3_room_0", 560, 648, &.{}, .retreat);
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        try std.testing.expect(reloaded.field_event == null);

        try walkTo(allocator, &reloaded, null, 360, 240, &.{});
        try stepToCoord(&reloaded, .right);
        try stepToCoord(&reloaded, .up);
        try std.testing.expectEqualStrings("va3_room_2", currentRoomName(&reloaded));
        try walkTo(allocator, &reloaded, null, 448, 80, &.{});
        _ = try reloaded.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
        try std.testing.expect(reloaded.field_event == null);
        try walkTo(allocator, &reloaded, null, 336, 240, &.{});
        const money_before_stay = reloaded.combat.progress.money;
        try interactFacing(&reloaded, .up, &.{1});
        try std.testing.expect(!scenarioBitSet(&reloaded, 6, 32));
        try interactFacing(&reloaded, .up, &.{ 0, 1 });
        try std.testing.expect(scenarioBitSet(&reloaded, 6, 32));
        try std.testing.expectEqual(money_before_stay, reloaded.combat.progress.money);
        try std.testing.expectEqual(@as(i32, 408), reloaded.field_state.x);
        try std.testing.expectEqual(@as(i32, 80), reloaded.field_state.y);

        // Walking away from the clock sends Hero three cells north.
        try walkTo(allocator, &reloaded, null, 440, 160, &.{});
        try stepToCoord(&reloaded, .down);
        try std.testing.expectEqual(@as(i32, 144), reloaded.field_state.y);
        try walkTo(allocator, &reloaded, null, 448, 80, &.{});
        _ = try reloaded.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expectEqualStrings("va3_room_1", currentRoomName(&reloaded));
        try std.testing.expect(scenarioBitSet(&reloaded, 6, 64));
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 6, 128));
        try walkTo(allocator, &reloaded, null, 296, 56, &.{});
        try std.testing.expectEqual(@as(i32, 88), reloaded.field_state.y);
        try walkTo(allocator, &reloaded, null, 240, 288, &.{1});
        try std.testing.expect(scenarioBitSet(&reloaded, 7, 1));
        try walkTo(allocator, &reloaded, null, 296, 80, &.{});
        try interactFacing(&reloaded, .up, &.{ 1, 1, 1, 0 });
        try std.testing.expect(scenarioBitSet(&reloaded, 24, 32));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor" });
        try std.testing.expectEqual(@as(i32, 112), reloaded.field_state.x);
        try std.testing.expectEqual(@as(i32, 96), reloaded.field_state.y);
        try walkTo(allocator, &reloaded, "va3_room_2", 296, 48, &.{});
        try std.testing.expectEqualStrings("va3_room_2", currentRoomName(&reloaded));
        try walkTo(allocator, &reloaded, "va3_room_0", 248, 352, &.{});
        try walkTo(allocator, &reloaded, "world_a", 608, 640, &.{});
        try walkThroughEncounters(allocator, &reloaded, "va2_room_0", 832, 408, &.{}, .retreat);
        try walkTo(allocator, &reloaded, null, 448, 176, &.{});
        try interactFacing(&reloaded, .up, &.{});
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 7, 2));
        try std.testing.expect(scenarioBitSet(&reloaded, 7, 4));
        try walkTo(allocator, &reloaded, "va2_room_3", 440, 168, &.{});
        try std.testing.expectEqualStrings("va2_room_3", currentRoomName(&reloaded));
        try walkTo(allocator, &reloaded, null, 544, 368, &.{});
        try std.testing.expectEqual(journey.Mode.battle, reloaded.mode);
        try std.testing.expectEqualStrings("va2_rescue_pair", reloaded.combat.content.encounters[reloaded.combat.encounter].id);
        try finishBattleWithInput(&reloaded, .free_will);
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 46, 1));
        try walkTo(allocator, &reloaded, null, 408, 208, &.{});
        try std.testing.expectEqual(journey.Mode.battle, reloaded.mode);
        try std.testing.expectEqualStrings("va2_rescue_pair", reloaded.combat.content.encounters[reloaded.combat.encounter].id);
        try finishBattleWithInput(&reloaded, .free_will);
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 46, 2));
        try restoreWithMedicine(&reloaded, 0, false);
        try walkTo(allocator, &reloaded, null, 80, 232, &.{});
        try std.testing.expectEqual(journey.Mode.battle, reloaded.mode);
        try std.testing.expectEqualStrings("va2_rescue_squad", reloaded.combat.content.encounters[reloaded.combat.encounter].id);
        // The continuous New Game test plays the captain battle with the prepared party.
        try finishBattleWith(&reloaded, .victory);
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 46, 4));
        try freeRocklandPrisoners(allocator, &reloaded);
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor" });
        try walkTo(allocator, &reloaded, "world_a", 608, 624, &.{});
        try enterLenankampHideout(allocator, &reloaded);
        try walkTo(allocator, &reloaded, null, 448, 80, &.{});
        _ = try reloaded.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expectEqualStrings("va3_room_1", currentRoomName(&reloaded));
        try walkTo(allocator, &reloaded, null, 144, 288, &.{});
        const before_odessa = try journey.Snapshot.capture(reloaded);
        try interactFacing(&reloaded, .left, &.{0});
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 1));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor", "odessa" });
        try before_odessa.apply(&reloaded);
        reloaded.bind();
        try interactFacing(&reloaded, .left, &.{1});
        try std.testing.expect(scenarioBitSet(&reloaded, 7, 128));
        try std.testing.expect(!scenarioBitSet(&reloaded, 8, 1));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor" });
        try walkTo(allocator, &reloaded, null, 144, 288, &.{});
        try interactFacing(&reloaded, .left, &.{1});
        try std.testing.expect(!scenarioBitSet(&reloaded, 8, 1));
        try walkTo(allocator, &reloaded, null, 144, 288, &.{});
        try interactFacing(&reloaded, .left, &.{0});
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 1));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor", "odessa" });
        const blueprint_found = for (reloaded.shared_items) |entry| {
            if (entry != null and std.mem.eql(u8, entry.?, "blueprint")) break true;
        } else false;
        try std.testing.expect(blueprint_found);
        try std.testing.expectEqual(@as(u8, 6), reloaded.combat.progress.party[4].level);
        try std.testing.expectEqualStrings("wind", reloaded.combat.rune(4).?.id);
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 1));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor", "odessa" });
        try std.testing.expectEqualStrings("Blueprint", reloaded.sharedItemNames()[0].?);
        try reachTigerwolfInnApproach(allocator, &reloaded);
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor", "odessa" });
        try std.testing.expectEqualStrings("Blueprint", reloaded.sharedItemNames()[0].?);
        try std.testing.expect(!scenarioBitSet(&reloaded, 8, 4));
        const before_invitation = try journey.Snapshot.capture(reloaded);
        try walkTo(allocator, &reloaded, "va8_room_10", 136, 200, &.{1});
        try std.testing.expectEqualStrings("va8_room_5", currentRoomName(&reloaded));
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 4));
        try std.testing.expect(!scenarioBitSet(&reloaded, 8, 8));
        try walkTo(allocator, &reloaded, "va8_room_10", 240, 72, &.{});
        try std.testing.expectEqualStrings("va8_room_10", currentRoomName(&reloaded));
        try before_invitation.apply(&reloaded);
        reloaded.bind();
        try walkTo(allocator, &reloaded, "va8_room_10", 136, 200, &.{0});
        try std.testing.expectEqualStrings("va8_room_10", currentRoomName(&reloaded));
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 4));
        try std.testing.expect(!scenarioBitSet(&reloaded, 8, 8));
        const before_tea = try journey.Snapshot.capture(reloaded);
        const tea_choices = [_][]const u8{ &.{1}, &.{ 0, 1 }, &.{ 0, 0, 1 }, &.{ 0, 0, 0, 1 } };
        for (tea_choices) |choices| {
            try before_tea.apply(&reloaded);
            reloaded.bind();
            _ = try reloaded.tickWithFieldEvents(.{}, .{});
            _ = try drainFieldEvent(&reloaded, choices);
            try std.testing.expect(scenarioBitSet(&reloaded, 8, 8));
            try std.testing.expect(!scenarioBitSet(&reloaded, 8, 64));
            try std.testing.expectEqual(@as(i32, 88), reloaded.field_state.x);
            try std.testing.expectEqual(@as(i32, 88), reloaded.field_state.y);
        }
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 8));
        try walkTo(allocator, &reloaded, null, 240, 176, &.{});
        try interactFacing(&reloaded, .right, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 16));
        try std.testing.expect(!scenarioBitSet(&reloaded, 8, 64));
        try walkTo(allocator, &reloaded, null, 296, 176, &.{});
        const before_morning_money = reloaded.field_state.progress.money;
        for (reloaded.combat.progress.party) |*member| {
            member.hp = 1;
            member.status = .poisoned;
            member.balloons = 2;
            @memset(&member.rune_charges, 0);
        }
        try interactFacing(&reloaded, .left, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 32));
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 64));
        try std.testing.expectEqualStrings("va8_room_5", currentRoomName(&reloaded));
        try std.testing.expectEqual(before_morning_money, reloaded.field_state.progress.money);
        for (reloaded.combat.progress.party) |member| {
            try std.testing.expectEqual(member.max_hp, member.hp);
            try std.testing.expectEqual(.healthy, member.status);
            try std.testing.expectEqual(@as(u8, 0), member.balloons);
            try std.testing.expectEqual(member.max_rune_charges, member.rune_charges);
        }
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor", "odessa" });
        try std.testing.expectEqualStrings("Blueprint", reloaded.sharedItemNames()[0].?);
        try exitTigerwolfNorth(allocator, &reloaded);
        try std.testing.expectEqual(@as(i32, 256), reloaded.field_state.x);
        try std.testing.expectEqual(@as(i32, 272), reloaded.field_state.y);
        try walkThroughEncounters(allocator, &reloaded, "va8_room_9", 272, 280, &.{}, .retreat);
        try std.testing.expectEqualStrings("va8_room_9", currentRoomName(&reloaded));
        try walkThroughEncounters(allocator, &reloaded, "world_a", 152, 56, &.{}, .retreat);
        try std.testing.expect(!scenarioBitSet(&reloaded, 8, 128));
        try walkThroughEncounters(allocator, &reloaded, "va5_room_0", 256, 128, &.{}, .retreat);
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expectEqualStrings("va5_room_0", currentRoomName(&reloaded));
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 128));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor", "odessa" });
        try std.testing.expectEqualStrings("Blueprint", reloaded.sharedItemNames()[0].?);
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expect(scenarioBitSet(&reloaded, 8, 128));
        try walkTo(allocator, &reloaded, "world_a", 232, 352, &.{});
        try std.testing.expectEqualStrings("world_a", currentRoomName(&reloaded));
        try std.testing.expectEqual(@as(i32, 256), reloaded.field_state.x);
        try std.testing.expectEqual(@as(i32, 144), reloaded.field_state.y);
        try walkThroughEncounters(allocator, &reloaded, "va5_room_0", 256, 128, &.{}, .retreat);
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        try std.testing.expect(reloaded.field_event == null);
        try std.testing.expectEqual(@as(i32, 232), reloaded.field_state.x);
        try std.testing.expectEqual(@as(i32, 344), reloaded.field_state.y);
        try walkTo(allocator, &reloaded, "va5_room_1", 304, 256, &.{});
        _ = try reloaded.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expectEqualStrings("va5_room_1", currentRoomName(&reloaded));
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 1));
        try walkTo(allocator, &reloaded, null, 96, 112, &.{});
        try interactFacing(&reloaded, .up, &.{1});
        try std.testing.expect(!scenarioBitSet(&reloaded, 9, 2));
        const before_sarady_stay_money = reloaded.field_state.progress.money;
        try interactFacing(&reloaded, .up, &.{0});
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 2));
        try std.testing.expectEqual(before_sarady_stay_money, reloaded.field_state.progress.money);
        try std.testing.expectEqual(@as(i32, 232), reloaded.field_state.x);
        try std.testing.expectEqual(@as(i32, 152), reloaded.field_state.y);
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 2));
        try walkTo(allocator, &reloaded, null, 104, 328, &.{});
        _ = try reloaded.tickWithFieldEvents(.{ .field = .{ .direction = .down } }, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expectEqualStrings("va5_room_1", currentRoomName(&reloaded));
        try std.testing.expectEqual(@as(i32, 328), reloaded.field_state.y);
        try std.testing.expect(!scenarioBitSet(&reloaded, 9, 4));
        try std.testing.expect(!scenarioBitSet(&reloaded, 9, 8));
        try walkTo(allocator, &reloaded, null, 288, 280, &.{});
        const before_odessa_night = try journey.Snapshot.capture(reloaded);
        const night_choices = [_][]const u8{ &.{ 0, 0 }, &.{ 0, 1 }, &.{ 1, 0 }, &.{ 1, 1, 0 }, &.{ 1, 1, 1 } };
        for (night_choices) |choices| {
            try before_odessa_night.apply(&reloaded);
            reloaded.bind();
            try interactFacing(&reloaded, .left, choices);
            try std.testing.expect(scenarioBitSet(&reloaded, 9, 4));
        }
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 8));
        try std.testing.expect(!scenarioBitSet(&reloaded, 9, 16));
        for (reloaded.shared_items) |item| {
            try std.testing.expect(item == null or !std.mem.eql(u8, item.?, "blueprint"));
        }
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 8));
        try walkTo(allocator, &reloaded, null, 232, 152, &.{});
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 16));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor", "odessa" });
        try walkTo(allocator, &reloaded, "va5_room_0", 104, 336, &.{});
        try std.testing.expectEqualStrings("va5_room_0", currentRoomName(&reloaded));
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 16));
        try walkTo(allocator, &reloaded, "va5_room_1", 304, 256, &.{});
        _ = try reloaded.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        try std.testing.expect(reloaded.field_event == null);
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 16));
        try walkTo(allocator, &reloaded, null, 96, 112, &.{});
        const before_regular_inn = try journey.Snapshot.capture(reloaded);
        reloaded.combat.progress.money = 0;
        reloaded.combat.progress.party[0].hp = 0;
        reloaded.combat.progress.party[0].status = .unconscious;
        try interactFacing(&reloaded, .up, &.{0});
        try std.testing.expectEqual(.notice, reloaded.menu.phase);
        try std.testing.expectEqual(.unconscious, reloaded.combat.progress.party[0].status);
        try std.testing.expectEqual(@as(u32, 0), reloaded.combat.progress.money);
        try before_regular_inn.apply(&reloaded);
        reloaded.bind();
        reloaded.combat.progress.money = reloaded.combat.progress.cost(50);
        reloaded.combat.progress.party[0].hp = 0;
        reloaded.combat.progress.party[0].status = .unconscious;
        try interactFacing(&reloaded, .up, &.{0});
        try std.testing.expectEqual(@as(u32, 0), reloaded.combat.progress.money);
        try std.testing.expectEqual(.healthy, reloaded.combat.progress.party[0].status);
        try std.testing.expectEqual(reloaded.combat.progress.party[0].max_hp, reloaded.combat.progress.party[0].hp);
        try before_regular_inn.apply(&reloaded);
        reloaded.bind();
        try walkTo(allocator, &reloaded, "va5_room_0", 104, 336, &.{});
        try arrangeEarlyBattleParty(&reloaded);
        try std.testing.expectEqual(.front, reloaded.combat.partyRow(3));
        try walkTo(allocator, &reloaded, "world_a", 232, 352, &.{});
        try returnTigerwolfSouth(allocator, &reloaded);
        try std.testing.expectEqual(@as(i32, 344), reloaded.field_state.x);
        try std.testing.expectEqual(@as(i32, 456), reloaded.field_state.y);
        const world_room = reloaded.package.rooms[reloaded.field_state.room];
        try std.testing.expect(!world_room.canStand(344, 456));
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expectEqual(@as(i32, 456), reloaded.field_state.y);
        var invalid_arrival = try journey.Snapshot.capture(reloaded);
        invalid_arrival.x = 336;
        try std.testing.expect(!world_room.canStand(336, 456));
        try std.testing.expectError(error.InvalidSave, invalid_arrival.validate(reloaded));
        invalid_arrival.x = world_room.width;
        try std.testing.expectError(error.InvalidSave, invalid_arrival.validate(reloaded));
        try stepToCoord(&reloaded, .down);
        try std.testing.expectEqual(@as(i32, 464), reloaded.field_state.y);
        try stepToCoord(&reloaded, .up);
        try std.testing.expectEqual(@as(i32, 464), reloaded.field_state.y);
        try enterLenankampHideout(allocator, &reloaded);
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 32));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor" });
        try walkTo(allocator, &reloaded, null, 448, 80, &.{});
        _ = try reloaded.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expectEqualStrings("va3_room_1", currentRoomName(&reloaded));
        try std.testing.expect(!scenarioBitSet(&reloaded, 9, 64));
        try std.testing.expect(!scenarioBitSet(&reloaded, 47, 1));
        try walkThroughEncounters(allocator, &reloaded, null, 184, 96, &.{}, .prepared);
        try std.testing.expect(scenarioBitSet(&reloaded, 47, 1));
        try std.testing.expect(!scenarioBitSet(&reloaded, 47, 2));
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try walkThroughEncounters(allocator, &reloaded, null, 240, 272, &.{}, .prepared);
        try std.testing.expect(scenarioBitSet(&reloaded, 47, 2));
        const after_raid_money = reloaded.field_state.progress.money;
        try walkTo(allocator, &reloaded, null, 240, 280, &.{});
        try walkTo(allocator, &reloaded, null, 184, 96, &.{});
        try std.testing.expectEqual(journey.Mode.field, reloaded.mode);
        try std.testing.expectEqual(after_raid_money, reloaded.field_state.progress.money);
        try std.testing.expect(!scenarioBitSet(&reloaded, 10, 1));
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expect(scenarioBitSet(&reloaded, 47, 1));
        try std.testing.expect(scenarioBitSet(&reloaded, 47, 2));
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 32));
        try expectPartyOrder(&reloaded, &.{ "hero", "gremio", "cleo", "viktor" });
        try walkTo(allocator, &reloaded, null, 320, 392, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 9, 128));
        try walkThroughEncounters(allocator, &reloaded, null, 272, 520, &.{}, .prepared);
        try std.testing.expect(scenarioBitSet(&reloaded, 10, 1));
        try std.testing.expect(!scenarioBitSet(&reloaded, 10, 2));
        const before_odessa_death = try journey.Snapshot.capture(reloaded);
        const death_choices = [_][]const u8{ &.{1}, &.{ 0, 1 }, &.{ 0, 0, 1 }, &.{ 0, 0, 0 } };
        for (death_choices) |choices| {
            try before_odessa_death.apply(&reloaded);
            reloaded.bind();
            try walkTo(allocator, &reloaded, null, 80, 512, choices);
            try std.testing.expectEqualStrings("va3_room_2", currentRoomName(&reloaded));
            try std.testing.expect(scenarioBitSet(&reloaded, 10, 2));
            try std.testing.expectEqual(@as(u8, 2), reloaded.combat.progress.story.scenario.?.soul_eater_spell_slots);
            try std.testing.expectEqualStrings("Earrings", reloaded.sharedItemNames()[0].?);
            try std.testing.expect(reloaded.combat.rune(0).?.spells[1] != null);
            try std.testing.expectEqual(@as(?usize, null), reloaded.combat.rune(0).?.spells[2]);
        }
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expect(scenarioBitSet(&reloaded, 10, 4));
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expectEqual(@as(u8, 2), reloaded.combat.progress.story.scenario.?.soul_eater_spell_slots);
        try std.testing.expectEqualStrings("Earrings", reloaded.sharedItemNames()[0].?);
        var invalid_rune = try journey.Snapshot.capture(reloaded);
        invalid_rune.story.scenario.?.soul_eater_spell_slots = 0;
        try std.testing.expectError(error.InvalidSoulEaterProgress, invalid_rune.validate(reloaded));
        invalid_rune.story.scenario.?.soul_eater_spell_slots = 5;
        try std.testing.expectError(error.InvalidSoulEaterProgress, invalid_rune.validate(reloaded));
        invalid_rune.story.scenario.?.soul_eater_spell_slots = 2;
        invalid_rune.schema = "suikoden-journey-save/26";
        try std.testing.expectError(error.InvalidSave, invalid_rune.validate(reloaded));
        try walkTo(allocator, &reloaded, null, 448, 80, &.{});
        _ = try reloaded.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
        _ = try drainFieldEvent(&reloaded, &.{});
        try std.testing.expectEqualStrings("va3_room_1", currentRoomName(&reloaded));
        try walkTo(allocator, &reloaded, null, 80, 512, &.{});
        try std.testing.expectEqual(@as(u8, 2), reloaded.combat.progress.story.scenario.?.soul_eater_spell_slots);
        try std.testing.expectEqualStrings("Earrings", reloaded.sharedItemNames()[0].?);
        try std.testing.expectEqual(@as(?[]const u8, null), reloaded.sharedItemNames()[1]);
        try walkTo(allocator, &reloaded, "va3_room_2", 296, 48, &.{});
        try walkTo(allocator, &reloaded, "va3_room_0", 248, 352, &.{});
        try walkTo(allocator, &reloaded, "world_a", 376, 736, &.{});
        try walkThroughEncounters(allocator, &reloaded, "va6_room_1", 480, 888, &.{}, .retreat);
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{0});
        try std.testing.expect(scenarioBitSet(&reloaded, 10, 8));
        try walkTo(allocator, &reloaded, "va6_room_0", 184, 232, &.{});
        try walkTo(allocator, &reloaded, "va6_room_2", 248, 152, &.{});
        _ = try reloaded.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&reloaded, &.{1});
        try std.testing.expect(scenarioBitSet(&reloaded, 10, 16));
        try walkTo(allocator, &reloaded, "world_b", 24, 232, &.{});
        try std.testing.expectEqualStrings("world_b", currentRoomName(&reloaded));
        try journey.save(io, allocator, temp.dir, reloaded);
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expect(scenarioBitSet(&reloaded, 10, 8));
        try std.testing.expectEqual(@as(u8, 2), reloaded.combat.progress.story.scenario.?.soul_eater_spell_slots);
    }
}

test "canonical Soul Eater spell slots persist without changing charges or the catalogue" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const rules = state.combat.content.systems.?;
    const index = rules.runeIndex("soul_eater").?;
    // Supplied attachment isolates spell visibility from the story grant event.
    state.combat.progress.party[0].rune = index;
    const charges = state.combat.progress.party[0].rune_charges;
    for (1..5) |slots| {
        state.combat.progress.story.scenario.?.soul_eater_spell_slots = @intCast(slots);
        const rune = state.combat.rune(0).?;
        for (0..4) |tier| {
            try std.testing.expectEqual(tier < slots, rune.spells[tier] != null);
            try std.testing.expect(rules.runes[index].spells[tier] != null);
        }
        try std.testing.expectEqual(charges, state.combat.progress.party[0].rune_charges);
        const bytes = try std.json.Stringify.valueAlloc(allocator, state.combat.progress.story.scenario.?, .{});
        defer allocator.free(bytes);
        const restored = try std.json.parseFromSlice(event_runtime.StoryState, allocator, bytes, .{});
        defer restored.deinit();
        try std.testing.expectEqual(slots, restored.value.soul_eater_spell_slots);
    }
    const legacy = try std.json.parseFromSlice(event_runtime.StoryState, allocator, "{}", .{});
    defer legacy.deinit();
    try std.testing.expectEqual(@as(u8, 1), legacy.value.soul_eater_spell_slots);
    state.combat.progress.story.scenario.?.soul_eater_spell_slots = 0;
    try std.testing.expectError(error.InvalidSoulEaterProgress, state.combat.progress.validate());
    state.combat.progress.story.scenario.?.soul_eater_spell_slots = 5;
    try std.testing.expectError(error.InvalidSoulEaterProgress, state.combat.progress.validate());
    const packet_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "../kit/work/build/canonical/battle/field_events.json", allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(packet_bytes);
    const document = try std.json.parseFromSlice(std.json.Value, allocator, packet_bytes, .{});
    defer document.deinit();
    document.value.object.getPtr("schema").?.* = .{ .string = "suikoden-battle-field-events/19" };
    const malformed = try std.json.Stringify.valueAlloc(allocator, document.value, .{});
    defer allocator.free(malformed);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const Rooms = @TypeOf(state.room_battles.?.*);
    try std.testing.expectError(error.UnsupportedBattleFieldCommand, Rooms.open(arena.allocator(), malformed, state.package));
}

test "canonical Odessa scene preserves a full shared inventory and still continues" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    // Supplied raid checkpoint isolates the source append-failure boundary.
    for ([_][]const u8{ "gremio", "cleo", "viktor" }) |id| try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, id);
    state.combat.progress.party[0].rune = state.combat.content.systems.?.runeIndex("soul_eater").?;
    setScenarioBit(&state, 9, 32 | 128);
    setScenarioBit(&state, 10, 1);
    setScenarioBit(&state, 47, 3);
    var count: usize = 0;
    for (state.shared_item_catalogue.?.items) |item| {
        if (item.ownership != .shared_key or std.mem.eql(u8, item.id, "earrings")) continue;
        state.shared_items[count] = item.id;
        count += 1;
        if (count == state.shared_items.len) break;
    }
    try std.testing.expectEqual(state.shared_items.len, count);
    const before = state.shared_items;
    state.field_state.enterRoom(state.package.roomIndex("va3_room_1").?, .{ .x = 96, .y = 512 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    try walkTo(allocator, &state, null, 80, 512, &.{1});
    try std.testing.expectEqualStrings("va3_room_2", currentRoomName(&state));
    try std.testing.expectEqualDeep(before, state.shared_items);
    try std.testing.expect(scenarioBitSet(&state, 10, 2));
    try std.testing.expectEqual(@as(u8, 2), state.combat.progress.story.scenario.?.soul_eater_spell_slots);
}

test "canonical world arrival preserves blocked source return through reload" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    // Supplied exit fixture isolates arrival validation from campaign combat.
    state.field_state.enterRoom(state.package.roomIndex("va8_room_0").?, .{ .x = 176, .y = 320 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("world_a", currentRoomName(&state));
    try std.testing.expectEqual(@as(i32, 344), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 456), state.field_state.y);
    const room = state.package.rooms[state.field_state.room];
    try std.testing.expect(!room.canStand(344, 456));
    try journey.save(io, allocator, temp.dir, state);
    try journey.restore(io, allocator, temp.dir, &state);
    state.bind();
    try std.testing.expectEqual(@as(i32, 456), state.field_state.y);
    var invalid = try journey.Snapshot.capture(state);
    invalid.x = 336;
    try std.testing.expect(!room.canStand(336, 456));
    try std.testing.expectError(error.InvalidSave, invalid.validate(state));
    invalid.x = room.width;
    try std.testing.expectError(error.InvalidSave, invalid.validate(state));
    try stepToCoord(&state, .down);
    try std.testing.expectEqual(@as(i32, 464), state.field_state.y);
    try stepToCoord(&state, .up);
    try std.testing.expectEqual(@as(i32, 464), state.field_state.y);
    const packet_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "../kit/work/build/canonical/battle/field_events.json", allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(packet_bytes);
    const document = try std.json.parseFromSlice(std.json.Value, allocator, packet_bytes, .{});
    defer document.deinit();
    var changed = false;
    for (document.value.object.getPtr("rooms").?.array.items) |*entry| {
        if (!std.mem.eql(u8, entry.object.get("room").?.string, "va8_room_0")) continue;
        for (entry.object.getPtr("content").?.object.getPtr("programs").?.array.items) |*program| {
            if (program.object.get("entity").?.integer != 1) continue;
            const commands = program.object.getPtr("commands").?.array.items;
            commands[commands.len - 1].object.getPtr("x").?.* = .{ .integer = 160 };
            changed = true;
        }
    }
    try std.testing.expect(changed);
    const malformed = try std.json.Stringify.valueAlloc(allocator, document.value, .{});
    defer allocator.free(malformed);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const Rooms = @TypeOf(state.room_battles.?.*);
    try std.testing.expectError(error.InvalidFieldEventTransition, Rooms.open(arena.allocator(), malformed, state.package));
}

fn finishFieldOrEncountersUntilRoom(allocator: std.mem.Allocator, state: *journey.State, hops: []const struct { want: []const u8, x: i32, y: i32 }, encounters: EncounterResolution) !void {
    for (hops) |hop| {
        errdefer std.debug.print("Route stopped in {s} at ({d},{d}) on the way to {s} via ({d},{d})\n", .{ currentRoomName(state), state.field_state.x, state.field_state.y, hop.want, hop.x, hop.y });
        try walkThroughEncounters(allocator, state, hop.want, hop.x, hop.y, &.{}, encounters);
        try std.testing.expectEqualStrings(hop.want, currentRoomName(state));
    }
}

fn walkToScriptedBattle(allocator: std.mem.Allocator, state: *journey.State, approach_x: i32, approach_y: i32, trigger_x: i32, trigger_y: i32, choices: []const u8, battle_id: []const u8) !void {
    try walkThroughEncounters(allocator, state, null, approach_x, approach_y, &.{}, .played);
    try walkTo(allocator, state, null, trigger_x, trigger_y, choices);
    try std.testing.expectEqual(journey.Mode.battle, state.mode);
    try std.testing.expectEqualStrings(battle_id, state.combat.content.encounters[state.combat.encounter].id);
}

fn stepToCoord(state: *journey.State, dir: field.Direction) !void {
    var dummy: usize = 0;
    _ = try walkStep(state, dir, &.{}, &dummy);
}

fn crossKakuToToran(allocator: std.mem.Allocator, state: *journey.State, dock: ?[]const u8) !void {
    errdefer if (state.field_state.progress.story.scenario) |story| {
        var recruited: usize = 0;
        for (story.recruit_flags) |flags| recruited += @intFromBool(flags & 3 != 0);
        std.debug.print("Toran approach at {s}, castle tier {d}, {d} recruits, story {x}/{x}, Garan {x}\n", .{
            currentRoomName(state), story.castle_tier, recruited, story.scenario[15], story.scenario[29], story.scenario[230],
        });
    };
    try walkTo(allocator, state, null, 152, 552, &.{});
    var ferry_choice: usize = 0;
    _ = try walkStep(state, .right, &.{0}, &ferry_choice);
    try std.testing.expectEqual(@as(usize, 1), ferry_choice);
    try std.testing.expectEqualStrings("world_j", currentRoomName(state));
    try std.testing.expect(state.boat_travel != null);
    for (0..340) |_| {
        if (state.field_state.x == 100 * 8) break;
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .left } }, .{});
    }
    try std.testing.expectEqual(@as(i32, 100 * 8), state.field_state.x);
    for (0..32) |_| {
        if (state.boat_travel == null) break;
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
    }
    try std.testing.expect(state.boat_travel == null);
    const docks = [_][]const u8{ "vb5ag_room_0", "vb5bg_room_0", "vb5cg_room_0" };
    const tier = state.field_state.progress.story.scenario.?.castle_tier;
    const destination = dock orelse docks[@min(tier -| 1, 2)];
    const arrival = currentRoomName(state);
    for ([_][]const u8{ "vb5i2_room_0", "vb5i3_room_0", "vb5i4_room_0" }) |upgrade| {
        if (!std.mem.eql(u8, arrival, upgrade)) continue;
        try drainStoryAndEvents(state, destination, &.{});
        break;
    }
    try std.testing.expectEqualStrings(destination, currentRoomName(state));
}

fn walkFromToranDockToCouncil(allocator: std.mem.Allocator, state: *journey.State) !void {
    if (std.mem.eql(u8, currentRoomName(state), "vb5cg_room_0")) {
        try walkContinuousRoute(allocator, state, &.{
            .{ .want = "vb5cg_room_1", .x = 128, .y = 168, .choices = &.{} },
            .{ .want = "vb5cg_room_7", .x = 328, .y = 328, .choices = &.{} },
            .{ .want = "vb5c1_room_0", .x = 248, .y = 224, .choices = &.{} },
            .{ .want = "vb5c1_room_6", .x = 232, .y = 56, .choices = &.{} },
            .{ .want = "vb5c2_room_0", .x = 248, .y = 224, .choices = &.{} },
            .{ .want = "vb5c2_room_4", .x = 312, .y = 56, .choices = &.{} },
            .{ .want = "vb5c3_room_0", .x = 248, .y = 224, .choices = &.{} },
            .{ .want = "vb5c3_room_3", .x = 248, .y = 56, .choices = &.{} },
            .{ .want = "vb5c4_room_0", .x = 248, .y = 224, .choices = &.{} },
        });
        return;
    }
    if (std.mem.eql(u8, currentRoomName(state), "vb5bg_room_0")) {
        try walkTo(allocator, state, null, 128, 168, &.{});
        if (std.mem.eql(u8, currentRoomName(state), "vb5b4_room_3")) {
            try finishFieldOrEncountersUntilRoom(allocator, state, &.{
                .{ .want = "vb5b4_room_1", .x = 360, .y = 272 },
                .{ .want = "vb5b4_room_0", .x = 360, .y = 128 },
                .{ .want = "vb5b4_room_2", .x = 216, .y = 56 },
                .{ .want = "vb5b3_room_0", .x = 136, .y = 224 },
            }, .retreat);
            return;
        }
        try std.testing.expectEqualStrings("vb5bg_room_1", currentRoomName(state));
        try finishFieldOrEncountersUntilRoom(allocator, state, &.{
            .{ .want = "vb5bg_room_7", .x = 328, .y = 328 },
            .{ .want = "vb5b1_room_0", .x = 248, .y = 224 },
            .{ .want = "vb5b1_room_6", .x = 216, .y = 56 },
            .{ .want = "vb5b2_room_0", .x = 248, .y = 224 },
            .{ .want = "vb5b2_room_4", .x = 312, .y = 56 },
            .{ .want = "vb5b3_room_0", .x = 248, .y = 224 },
        }, .retreat);
        return;
    }
    try walkTo(allocator, state, "vb5ag_room_1", 128, 168, &.{});
    try walkTo(allocator, state, "vb5ag_room_7", 328, 328, &.{});
    try walkTo(allocator, state, "vb5a1_room_0", 248, 224, &.{});
    try walkTo(allocator, state, "vb5a1_room_6", 248, 56, &.{});
    try walkTo(allocator, state, "vb5a2_room_0", 248, 224, &.{});
}

fn walkFromRegionDToKaku(allocator: std.mem.Allocator, state: *journey.State) !void {
    try finishFieldOrEncountersUntilRoom(allocator, state, &.{
        .{ .want = "vb4_room_0", .x = 1128, .y = 496 },
        .{ .want = "world_b", .x = 600, .y = 328 },
        .{ .want = "vb2_room_0", .x = 648, .y = 328 },
    }, .retreat);
}

fn crossRegionDToToran(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkFromRegionDToKaku(allocator, state);
    try crossKakuToToran(allocator, state, null);
}

fn restInKaku(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkTo(allocator, state, "vb2_room_3", 464, 128, &.{});
    try walkTo(allocator, state, null, 248, 128, &.{});
    try interactFacing(state, .up, &.{0});
    for (state.combat.progress.party) |member| try std.testing.expectEqual(member.max_hp, member.hp);
    try walkTo(allocator, state, "vb2_room_0", 248, 240, &.{});
}

fn crossToranToRegionD(allocator: std.mem.Allocator, state: *journey.State) !void {
    try crossToranToKaku(allocator, state);
    try restInKaku(allocator, state);
    try finishFieldOrEncountersUntilRoom(allocator, state, &.{
        .{ .want = "world_b", .x = 280, .y = 48 },
        .{ .want = "vb4_room_0", .x = 256, .y = 568 },
        .{ .want = "world_d", .x = 128, .y = 328 },
    }, .retreat);
}

fn crossToranToKaku(allocator: std.mem.Allocator, state: *journey.State) !void {
    const departure = currentRoomName(state);
    if (std.mem.eql(u8, departure, "vb5b3_room_0")) {
        try finishFieldOrEncountersUntilRoom(allocator, state, &.{
            .{ .want = "vb5b3_room_2", .x = 328, .y = 56 },
            .{ .want = "vb5b2_room_0", .x = 136, .y = 224 },
            .{ .want = "vb5b2_room_3", .x = 184, .y = 56 },
            .{ .want = "vb5b1_room_0", .x = 136, .y = 224 },
            .{ .want = "vb5b1_room_7", .x = 344, .y = 56 },
            .{ .want = "vb5bg_room_1", .x = 136, .y = 224 },
            .{ .want = "vb5bg_room_0", .x = 192, .y = 616 },
        }, .retreat);
    } else if (!std.mem.eql(u8, departure, "vb5cg_room_0")) {
        try walkTo(allocator, state, "vb5a2_room_3", 184, 56, &.{});
        try walkTo(allocator, state, "vb5a1_room_0", 136, 224, &.{});
        try walkTo(allocator, state, "vb5a1_room_7", 344, 56, &.{});
        try walkTo(allocator, state, "vb5ag_room_1", 136, 224, &.{});
        try walkTo(allocator, state, "vb5ag_room_0", 192, 616, &.{});
    }
    try walkTo(allocator, state, "world_j", 224, 344, &.{0});
    try sailToKaku(state);
}

fn sailToKaku(state: *journey.State) !void {
    try std.testing.expect(state.boat_travel != null);
    for (0..320) |_| {
        if (state.field_state.x == 118 * 8) break;
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
    }
    try std.testing.expectEqual(@as(i32, 118 * 8), state.field_state.x);
    for (0..32) |_| {
        if (state.boat_travel == null) break;
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
    }
    try std.testing.expectEqualStrings("vb2_room_0", currentRoomName(state));
    try std.testing.expect(state.boat_travel == null);
}

test "canonical Toran boat upgrade requires an active pilot and sails to Region G" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    defer state.deinitActiveModes();
    state.field_state.enterRoom(state.package.roomIndex("vb5bg_room_0").?, .{ .x = 192, .y = 344 });
    state.field_state.setWorldEntry(state.package, "world_j_point_24");
    state.combat.progress.story.scenario.?.castle_tier = 2;
    state.combat.progress.story.recruitment_tier = 2;
    setScenarioBit(&state, 29, 64);
    setScenarioBit(&state, 231, 16);
    state.enterEncounterRoom();
    try walkTo(allocator, &state, null, 144, 344, &.{});
    try interactFacing(&state, .down, &.{0});
    try std.testing.expectEqualStrings("vb5bg_room_0", currentRoomName(&state));
    try std.testing.expect(!scenarioBitSet(&state, 231, 32) and !scenarioBitSet(&state, 199, 1));
    try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, "tai_ho");
    try interactFacing(&state, .down, &.{1});
    try std.testing.expectEqualStrings("vb5bg_room_0", currentRoomName(&state));
    try std.testing.expect(!scenarioBitSet(&state, 231, 32) and !scenarioBitSet(&state, 199, 1));
    try interactFacing(&state, .down, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 231, 32) and scenarioBitSet(&state, 199, 1));
    try std.testing.expect(std.mem.indexOfScalar(u8, &state.field_state.auxiliary_party.?, 32) != null);
    try sailToranToRegionG(allocator, &state);
}

const BoatLeg = struct { direction: field.Direction, cells: u8 };

fn sailBoat(state: *journey.State, legs: []const BoatLeg) !void {
    var sailed: usize = 0;
    errdefer std.debug.print("Upgraded voyage after {d} cells, {s} ({d},{d}), {s}\n", .{
        sailed, currentRoomName(state), state.field_state.x, state.field_state.y, if (state.boat_travel != null) "aboard" else "ashore",
    });
    try std.testing.expect(state.boat_travel.?.session.vessel.?.upgraded);
    for (legs) |leg| for (0..leg.cells) |_| {
        try std.testing.expect(state.boat_travel != null);
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = leg.direction } }, .{});
        while (state.field_state.remaining != 0) _ = try state.tickWithFieldEvents(.{}, .{});
        sailed += 1;
    };
}

fn sailToranToRegionG(allocator: std.mem.Allocator, state: *journey.State) !void {
    try std.testing.expectEqual(@as(i32, 100 * 8), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 75 * 8), state.field_state.y);

    // Each leg uses ordinary directional input, including the two upgrade-only cells.
    try sailBoat(state, &.{
        .{ .direction = .right, .cells = 3 }, .{ .direction = .up, .cells = 1 },
        .{ .direction = .right, .cells = 1 }, .{ .direction = .up, .cells = 15 },
        .{ .direction = .right, .cells = 2 }, .{ .direction = .up, .cells = 1 },
        .{ .direction = .right, .cells = 1 }, .{ .direction = .up, .cells = 1 },
        .{ .direction = .right, .cells = 1 }, .{ .direction = .up, .cells = 28 },
        .{ .direction = .left, .cells = 44 }, .{ .direction = .up, .cells = 1 },
        .{ .direction = .left, .cells = 1 },  .{ .direction = .up, .cells = 1 },
        .{ .direction = .left, .cells = 1 },  .{ .direction = .up, .cells = 2 },
        .{ .direction = .left, .cells = 3 },  .{ .direction = .up, .cells = 1 },
        .{ .direction = .left, .cells = 1 },  .{ .direction = .up, .cells = 1 },
        .{ .direction = .left, .cells = 8 },  .{ .direction = .up, .cells = 1 },
        .{ .direction = .left, .cells = 1 },  .{ .direction = .up, .cells = 1 },
        .{ .direction = .left, .cells = 1 },  .{ .direction = .up, .cells = 9 },
    });
    try std.testing.expectEqualStrings("vg1_room_0", currentRoomName(state));
    try std.testing.expectEqualStrings("world_j_point_2", state.field_state.worldEntry(state.package).?.id);
    try std.testing.expectEqual(@as(u8, 0), state.combat.progress.story.scenario.?.world_mode);
    try std.testing.expect(state.boat_travel == null);
    try (try journey.Snapshot.capture(state.*)).validate(state.*);
    try walkTo(allocator, state, null, 200, 472, &.{});
}

fn restInNorthernSwallowPass(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkTo(allocator, state, "vg1_room_5", 248, 120, &.{});
    try walkTo(allocator, state, null, 48, 192, &.{});
    try interactFacing(state, .up, &.{0});
    for (state.combat.progress.party) |member| try std.testing.expectEqual(member.max_hp, member.hp);
    try walkTo(allocator, state, "vg1_room_0", 184, 336, &.{});
}

fn finishCampaignWar(state: *journey.State, scenario: []const u8, expected: journey.war.Outcome) !void {
    try std.testing.expectEqual(journey.Mode.war, state.mode);
    try std.testing.expectEqualStrings(scenario, state.active_war.?.session.engine.scenario.id);
    const garan = std.mem.eql(u8, scenario, "garan");
    const scarleticia = std.mem.eql(u8, scenario, "scarleticia_antidote");
    var finished = false;
    for (0..20000) |tick| {
        if (state.active_war == null) break;
        const session = &state.active_war.?.session;
        const engine = &session.engine;
        if (engine.result) |result| {
            try std.testing.expectEqual(expected, result.outcome);
            finished = true;
        }
        if (engine.phase == .player_command and (garan or scarleticia)) {
            if (tick % 2 != 0) {
                _ = try state.tickWithFieldEvents(.{}, .{});
                continue;
            }
            const order: [2]u8 = if (scarleticia)
                // Merchants cut enemy strength without exposing the army to Milich's magic.
                .{ 3, 35 }
            else if (engine.scouted_attack) |attack|
                (if (engine.scenario.attacks[attack].flags & 3 == 1) .{ 2, 27 } else .{ 0, 18 })
            else if (engine.team_alive[33])
                .{ 3, 33 }
            else
                .{ 2, 27 };
            const category_selected = order[0] == session.command_index;
            _ = try state.tickWithFieldEvents(.{
                .field = .{ .menu_direction = if (category_selected) null else .down },
                .right = category_selected and order[1] != engine.selected_index,
            }, .{ .confirm = category_selected and order[1] == engine.selected_index });
            continue;
        }
        const confirm = switch (engine.phase) {
            .scripted => engine.script.?.phase == engine.scenario.lifecycle.wait_phase,
            .player_command => tick % 2 == 0,
            .result => true,
            else => false,
        };
        _ = try state.tickWithFieldEvents(.{}, .{ .confirm = confirm });
    }
    try std.testing.expect(finished);
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expect(state.active_war == null and state.scripted_battle == null);
    if (state.field_event != null) _ = try drainFieldEvent(state, &.{});
}

test "island return flight leaves a walkable route to the palace" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    setScenarioBit(&state, 2, 4);
    setScenarioBit(&state, 20, 32);
    state.field_state.enterRoom(state.package.roomIndex("va4_room_0").?, .{ .x = 152, .y = 80 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("vaa_room_0", currentRoomName(&state));
    const arrival: field.Point = .{ .x = state.field_state.x, .y = state.field_state.y };
    try std.testing.expect(!scenarioBitSet(&state, 20, 16));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 20, 16));
    try std.testing.expectEqual(arrival.x, state.field_state.x);
    try std.testing.expectEqual(arrival.y, state.field_state.y);
    try walkTo(allocator, &state, "vaa_room_1", 312, 96, &.{});
    try std.testing.expectEqualStrings("vaa_room_1", currentRoomName(&state));
}

noinline fn dumpCampaignReplayState(state: *const journey.State) void {
    const flags = &state.field_state.progress.story.scenario.?.scenario;
    std.debug.print("Campaign replay stopped in {s} at ({d},{d}), {s}: story flags {d}, {d}, {d}, {d}\n", .{
        currentRoomName(state), state.field_state.x, state.field_state.y, @tagName(state.mode), flags[10], flags[11], flags[12], flags[20],
    });
    std.debug.print("Last encounter {s}, {s}\n", .{ state.combat.content.encounters[state.combat.encounter].id, @tagName(state.combat.phase) });
    if (state.field_event) |*event| {
        if (event.session.instance) |*scene| {
            std.debug.print("Event {s}/{d} wait {any}, blocker {any}, fade {any}\n", .{
                scene.program_id, scene.execution.pc, scene.execution.wait, event.session.blocker, event.session.fade_state,
            });
        }
    }
}

test "canonical continuous New Game story through both Pahn outcomes and partial-roster credits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    defer state.deinitActiveModes();

    try expectPartyOrder(&state, &.{"hero"});

    // Opening palace -> Gregminster -> Mansion -> front door with full opening party [hero, gremio, pahn, cleo, ted].
    try walkTo(allocator, &state, null, 464, 632, &.{});
    try interactFacing(&state, .up, &.{0});
    try walkTo(allocator, &state, "vaa_room_1", 448, 208, &.{});
    try walkTo(allocator, &state, null, 256, 304, &.{});
    try walkTo(allocator, &state, null, 168, 304, &.{});
    try interactFacing(&state, .up, &.{});
    try walkTo(allocator, &state, "vaa_room_0", 240, 320, &.{});
    for (0..12) |_| {
        _ = try drainFieldEvent(&state, &.{});
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (std.mem.eql(u8, currentRoomName(&state), "va1_room_1") and state.field_event == null and scenarioBitSet(&state, 0, 32)) break;
    }
    try walkTo(allocator, &state, "va1_room_2", 136, 272, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try walkTo(allocator, &state, null, 80, 288, &.{0});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try walkTo(allocator, &state, null, 184, 96, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try walkTo(allocator, &state, "va1_room_1", 152, 280, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try walkTo(allocator, &state, null, 184, 368, &.{});
    try expectPartyOrder(&state, &.{ "hero", "gremio", "pahn", "cleo", "ted" });
    try std.testing.expect(scenarioBitSet(&state, 1, 64));

    // Return to Imperial Palace -> Kraze assigns Magician's Island mission (scenario[1]|=128) -> Futch flies to va4_room_0.
    try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{});
    try walkTo(allocator, &state, "va1_room_17", 776, 0, &.{});
    try walkTo(allocator, &state, "vaa_room_0", 168, 0, &.{});
    try walkTo(allocator, &state, "vaa_room_1", 312, 96, &.{});
    try walkTo(allocator, &state, null, 168, 304, &.{});
    try interactFacing(&state, .up, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 1, 128));

    try walkTo(allocator, &state, "vaa_room_0", 280, 832, &.{});
    try std.testing.expectEqualStrings("vaa_room_0", currentRoomName(&state));
    try walkTo(allocator, &state, null, 1048, 216, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expectEqualStrings("va4_room_0", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 20, 16));

    // Traverse VA4 shore -> va4_room_3 (Golem boss) -> spiral tower -> va4_room_10.
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "va4_room_1", .x = 144, .y = 0 },
        .{ .want = "va4_room_12", .x = 224, .y = 0 },
        .{ .want = "va4_room_2", .x = 160, .y = 0 },
        .{ .want = "va4_room_3", .x = 184, .y = 48 },
    }, .played);
    try walkToScriptedBattle(allocator, &state, 160, 248, 160, 240, &.{}, "va4_golem");
    try finishBattleWithInput(&state, .free_will);
    _ = try drainFieldEvent(&state, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 2, 1));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "va4_room_4", .x = 208, .y = 48 },
        .{ .want = "va4_room_5", .x = 208, .y = 48 },
        .{ .want = "va4_room_6", .x = 176, .y = 48 },
        .{ .want = "va4_room_7", .x = 216, .y = 40 },
        .{ .want = "va4_room_8", .x = 128, .y = 0 },
        .{ .want = "va4_room_9", .x = 128, .y = 0 },
        .{ .want = "va4_room_10", .x = 128, .y = 0 },
    }, .played);

    // Leknaat party split -> Astral Conclusions -> Luc rejoin -> Futch flight back to vaa_room_0.
    try walkTo(allocator, &state, null, 72, 184, &.{});
    try interactFacing(&state, .up, &.{});
    try expectPartyOrder(&state, &.{"hero"});
    try std.testing.expect(scenarioBitSet(&state, 2, 2));

    try walkTo(allocator, &state, "va4_room_11", 160, 0, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 2, 4));

    try walkTo(allocator, &state, "va4_room_10", 176, 736, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try expectPartyOrder(&state, &.{ "hero", "gremio", "pahn", "cleo", "ted" });
    try std.testing.expect(scenarioBitSet(&state, 37, 64));
    if (std.mem.eql(u8, currentRoomName(&state), "va4_room_10")) {
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
    }
    if (std.mem.eql(u8, currentRoomName(&state), "va4_room_0")) {
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expectEqualStrings("vaa_room_0", currentRoomName(&state));

    // Report to Kraze in vaa_room_1 (e36..e41 unlock Rockland gate naturally) -> walk to Rockland -> Mt. Seifu (va7).
    try walkTo(allocator, &state, "vaa_room_1", 312, 96, &.{});
    try walkTo(allocator, &state, null, 168, 304, &.{});
    for (0..6) |_| try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 2, 64));
    try std.testing.expect(scenarioBitSet(&state, 3, 8));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vaa_room_0", .x = 280, .y = 832 },
        .{ .want = "vaa_room_10", .x = 296, .y = 744 },
        .{ .want = "va1_room_0", .x = 144, .y = 232 },
    }, .played);
    try walkTo(allocator, &state, "va1_room_8", 1200, 584, &.{});
    try walkTo(allocator, &state, null, 184, 120, &.{});
    try interactService(&state, .up);
    try std.testing.expectEqual(.rune_service, state.menu.phase);
    while (state.menu.member != 3) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    const confirm: pause_menu.Input = .{ .field = .{ .action = true } };
    _ = try state.tickWithFieldEvents(confirm, .{});
    try std.testing.expectEqual(.rune_attach, state.menu.phase);
    for (state.combat.progress.party, 0..) |member, owner| {
        const slot = for (member.inventory.slots, 0..) |item, index| {
            if (item != null and item.?.id == .fire_crystal) break index;
        } else continue;
        while (state.menu.member != owner) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
        while (state.menu.slot != slot) _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        break;
    }
    try std.testing.expect(state.combat.hasRune(3, "fire"));
    _ = try state.tickWithFieldEvents(confirm, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkTo(allocator, &state, "va1_room_0", 184, 240, &.{});
    try walkTo(allocator, &state, "va1_room_3", 576, 632, &.{});
    try walkTo(allocator, &state, null, 192, 256, &.{});
    try interactFacing(&state, .up, &.{0});
    for (0..60) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    for (state.combat.progress.party) |member| try std.testing.expectEqual(member.max_hp, member.hp);
    try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{});
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "world_a", .x = 720, .y = 872 },
        .{ .want = "va2_room_0", .x = 832, .y = 408 },
    }, .played);
    try walkTo(allocator, &state, "va2_room_3", 440, 168, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 3, 32));
    try walkTo(allocator, &state, "va2_room_0", 608, 496, &.{});
    try walkTo(allocator, &state, "world_a", 0, 624, &.{});

    try walkThroughEncounters(allocator, &state, "va7_room_0", 1024, 400, &.{}, .played);
    try walkThroughEncounters(allocator, &state, null, 224, 304, &.{}, .played);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 3, 64));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "va7_room_1", .x = 296, .y = 120 },
        .{ .want = "va7_room_2", .x = 64, .y = 272 },
        .{ .want = "va7_room_5", .x = 160, .y = 80 },
        .{ .want = "va7_room_6", .x = 160, .y = 0 },
        .{ .want = "va7_room_7", .x = 144, .y = 0 },
        .{ .want = "va7_room_8", .x = 160, .y = 160 },
        .{ .want = "va7_room_9", .x = 160, .y = 232 },
    }, .played);

    // Queen Ants -> Ted solo Soul Eater ambush (restores full 5-member order) -> Varkas & Sydonia -> exit to world_a.
    try restoreWithMedicine(&state, 1, false);
    try walkToScriptedBattle(allocator, &state, 336, 168, 336, 176, &.{}, "va7_r9_b0");
    try finishBattleWithInput(&state, .guard_second_round);
    _ = try drainFieldEvent(&state, &.{});
    try walkToScriptedBattle(allocator, &state, 248, 168, 248, 160, &.{0}, "va7_r9_b1");
    try expectPartyOrder(&state, &.{"ted"});
    try finishBattleWithInput(&state, .defend);
    _ = try drainFieldEvent(&state, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try expectPartyOrder(&state, &.{ "hero", "gremio", "pahn", "cleo", "ted" });
    try std.testing.expect(scenarioBitSet(&state, 3, 128));
    try restoreWithMedicine(&state, 3, false);

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "va7_room_10", .x = 256, .y = 0 },
        .{ .want = "va7_room_11", .x = 176, .y = 64 },
        .{ .want = "va7_room_12", .x = 96, .y = 488 },
        .{ .want = "va7_room_13", .x = 96, .y = 0 },
    }, .retreat);
    // Arrival at va7_room_13 (200, 320) lands directly inside va7_room_13_e01_ordinary (x=25, y=40 -> va7_r13_b0).
    if (state.mode == .field and state.field_event == null) _ = try state.tickWithFieldEvents(.{}, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    if (state.mode == .field) try walkToScriptedBattle(allocator, &state, 200, 312, 200, 320, &.{}, "va7_r13_b0");
    try std.testing.expectEqual(journey.Mode.battle, state.mode);
    try std.testing.expectEqualStrings("va7_r13_b0", state.combat.content.encounters[state.combat.encounter].id);
    try finishBattleWithInput(&state, .free_will);
    _ = try drainFieldEvent(&state, &.{});
    if (state.mode == .field and state.field_event == null) _ = try state.tickWithFieldEvents(.{}, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqual(journey.Mode.battle, state.mode);
    try std.testing.expectEqualStrings("va7_r13_b1", state.combat.content.encounters[state.combat.encounter].id);
    const money_before_summit = state.combat.progress.money;
    try finishBattleWithInput(&state, .summit);
    try std.testing.expectEqual(money_before_summit + 700, state.combat.progress.money);
    _ = try drainFieldEvent(&state, &.{});
    if (state.mode == .field and state.field_event == null) _ = try state.tickWithFieldEvents(.{}, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 4, 1));
    try std.testing.expectEqualStrings("va7_room_0", currentRoomName(&state));

    try walkThroughEncounters(allocator, &state, "world_a", 304, 488, &.{}, .retreat);
    try std.testing.expectEqualStrings("world_a", currentRoomName(&state));

    // Report back in Rockland, then return to the mansion with the completed mission.
    try walkThroughEncounters(allocator, &state, "va2_room_0", 832, 408, &.{}, .retreat);
    try walkTo(allocator, &state, "va2_room_3", 440, 168, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 4, 2));
    try std.testing.expectEqualStrings("va2_room_0", currentRoomName(&state));
    try walkTo(allocator, &state, "world_a", 0, 624, &.{});
    try walkThroughEncounters(allocator, &state, "va1_room_0", 584, 384, &.{}, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try expectPartyOrder(&state, &.{ "hero", "gremio", "pahn", "cleo" });
    try walkTo(allocator, &state, "va1_room_1", 1040, 352, &.{});
    try walkTo(allocator, &state, "va1_room_2", 136, 272, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 4, 8));
    try walkTo(allocator, &state, "va1_room_1", 152, 280, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expectEqualStrings("va1_room_16", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("va1_room_1", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 5, 4));

    try walkTo(allocator, &state, null, 72, 208, &.{});
    try interactFacing(&state, .up, &.{ 0, 0 });
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo" });
    try std.testing.expectEqualStrings("soul_eater", (state.combat.rune(0) orelse return error.MissingSoulEater).id);

    // Leave the mansion and follow the inn escape to Lenankamp.
    try walkTo(allocator, &state, "va1_room_0", 176, 384, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 5, 32 | 64));
    try walkTo(allocator, &state, "va1_room_3", 576, 632, &.{});
    if (std.mem.eql(u8, currentRoomName(&state), "va1_room_3")) {
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expectEqualStrings("va1_room_5", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 5, 128));
    try walkTo(allocator, &state, null, 112, 96, &.{});
    try std.testing.expect(scenarioBitSet(&state, 6, 1));
    try walkTo(allocator, &state, "va1_room_4", 80, 104, &.{});
    try walkTo(allocator, &state, "va1_room_3", 336, 168, &.{});
    try walkTo(allocator, &state, "va1_room_0", 184, 328, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 6, 2));
    try walkTo(allocator, &state, null, 504, 200, &.{});
    try interactFacing(&state, .up, &.{1});
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor" });
    try walkTo(allocator, &state, "world_a", 720, 872, &.{0});
    try walkThroughEncounters(allocator, &state, "va3_room_0", 560, 640, &.{}, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 6, 8 | 16));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo" });

    // Enter the hideout and take the rescue assignment.
    try walkTo(allocator, &state, null, 360, 240, &.{});
    try stepToCoord(&state, .right);
    try stepToCoord(&state, .up);
    try std.testing.expectEqualStrings("va3_room_2", currentRoomName(&state));
    try walkTo(allocator, &state, null, 336, 240, &.{});
    try interactFacing(&state, .up, &.{ 0, 1 });
    try walkTo(allocator, &state, null, 448, 80, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expectEqualStrings("va3_room_1", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try walkTo(allocator, &state, null, 240, 288, &.{1});
    try walkTo(allocator, &state, null, 296, 80, &.{});
    try interactFacing(&state, .up, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 24, 32));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor" });

    try walkTo(allocator, &state, "va3_room_2", 296, 48, &.{});
    try walkTo(allocator, &state, "va3_room_0", 248, 352, &.{});
    // Prepare the long-range weapon before fighting a rear-row captain.
    try walkTo(allocator, &state, "va3_room_6", 184, 224, &.{});
    try walkTo(allocator, &state, null, 184, 160, &.{});
    try interactService(&state, .up);
    try std.testing.expectEqual(.blacksmith, state.menu.phase);
    while (state.menu.member != 2) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    while (state.combat.progress.party[2].weapon_level < 4) {
        const price = try state.combat.sharpenPrice(2, state.menu.service_limit);
        if (state.combat.progress.money < price + 500) break;
        const level = state.combat.progress.party[2].weapon_level;
        _ = try state.tickWithFieldEvents(confirm, .{});
        _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        try std.testing.expectEqual(level + 1, state.combat.progress.party[2].weapon_level);
        _ = try state.tickWithFieldEvents(confirm, .{});
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkTo(allocator, &state, "va3_room_0", 184, 240, &.{});
    try walkTo(allocator, &state, "world_a", 608, 640, &.{});
    try walkThroughEncounters(allocator, &state, "va2_room_0", 832, 408, &.{}, .retreat);
    try walkTo(allocator, &state, null, 448, 176, &.{});
    try interactFacing(&state, .up, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 7, 2 | 4));
    try walkTo(allocator, &state, "va2_room_3", 440, 168, &.{});
    for ([_]field.Point{ .{ .x = 544, .y = 368 }, .{ .x = 408, .y = 208 } }) |trigger| {
        try prepareWithCarriedMedicine(&state, .medicine);
        try walkTo(allocator, &state, null, trigger.x, trigger.y, &.{});
        try std.testing.expectEqual(.battle, state.mode);
        try std.testing.expectEqualStrings("va2_rescue_pair", state.combat.content.encounters[state.combat.encounter].id);
        try finishBattleWithInput(&state, .travel);
        _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expect(scenarioBitSet(&state, 46, 3));

    try walkTo(allocator, &state, "va2_room_0", 608, 496, &.{});
    try walkTo(allocator, &state, "va2_room_5", 544, 512, &.{});
    try walkTo(allocator, &state, null, 184, 240, &.{});
    try interactService(&state, .up);
    try std.testing.expectEqual(.medicine, state.menu.shopStock(state.field_state.item_rules.?)[0]);
    for (0..state.combat.partyCount()) |member| {
        try std.testing.expectEqual(.shop, state.menu.phase);
        const money = state.combat.progress.money;
        _ = try state.tickWithFieldEvents(confirm, .{});
        try std.testing.expectEqual(.buy_member, state.menu.phase);
        while (state.menu.member != member) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        try std.testing.expect(state.combat.progress.money < money);
        _ = try state.tickWithFieldEvents(confirm, .{});
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkTo(allocator, &state, "va2_room_0", 184, 368, &.{});
    try walkTo(allocator, &state, "va2_room_4", 288, 544, &.{});
    try walkTo(allocator, &state, null, 112, 272, &.{});
    try interactFacing(&state, .up, &.{0});
    for (0..60) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    for (state.combat.progress.party) |member| try std.testing.expectEqual(member.max_hp, member.hp);
    try arrangeEarlyBattleParty(&state);
    try std.testing.expectEqual(.back, state.combat.partyRow(2));
    try walkTo(allocator, &state, "va2_room_0", 120, 368, &.{});
    try walkTo(allocator, &state, "va2_room_3", 440, 168, &.{});
    try std.testing.expectEqualStrings("va2_room_3", currentRoomName(&state));
    try walkTo(allocator, &state, null, 80, 232, &.{});
    try std.testing.expectEqual(.battle, state.mode);
    try std.testing.expectEqualStrings("va2_rescue_squad", state.combat.content.encounters[state.combat.encounter].id);
    try finishBattleWithInput(&state, .travel);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 46, 7));
    try freeRocklandPrisoners(allocator, &state);
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor" });

    try walkTo(allocator, &state, "world_a", 608, 624, &.{});
    try enterLenankampHideout(allocator, &state);
    try walkTo(allocator, &state, null, 448, 80, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expectEqualStrings("va3_room_1", currentRoomName(&state));
    try walkTo(allocator, &state, null, 144, 288, &.{});
    try interactFacing(&state, .left, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 8, 1));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor", "odessa" });
    try std.testing.expectEqualStrings("Blueprint", state.sharedItemNames()[0].?);

    try reachTigerwolfInnApproach(allocator, &state);
    try walkTo(allocator, &state, "va8_room_10", 136, 200, &.{0});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 8, 8));
    try walkTo(allocator, &state, null, 240, 176, &.{});
    try interactFacing(&state, .right, &.{});
    try std.testing.expect(scenarioBitSet(&state, 8, 16));
    try walkTo(allocator, &state, null, 296, 176, &.{});
    try interactFacing(&state, .left, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 8, 64));

    try exitTigerwolfNorth(allocator, &state);
    try walkThroughEncounters(allocator, &state, "va5_room_0", 256, 128, &.{}, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 8, 128));
    try walkTo(allocator, &state, "va5_room_1", 304, 256, &.{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
    _ = try drainFieldEvent(&state, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 9, 1));
    try walkTo(allocator, &state, null, 96, 112, &.{});
    try interactFacing(&state, .up, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 9, 2));
    try walkTo(allocator, &state, null, 288, 280, &.{});
    try interactFacing(&state, .left, &.{ 0, 0 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 9, 8));
    try walkTo(allocator, &state, null, 232, 152, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 9, 16));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor", "odessa" });

    try walkTo(allocator, &state, "va5_room_0", 104, 336, &.{});
    try arrangeEarlyBattleParty(&state);
    try walkTo(allocator, &state, "world_a", 232, 352, &.{});
    try returnTigerwolfSouth(allocator, &state);
    try stepToCoord(&state, .down);
    try enterLenankampHideout(allocator, &state);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 9, 32));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor" });
    try walkTo(allocator, &state, null, 448, 80, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expectEqualStrings("va3_room_1", currentRoomName(&state));
    try walkThroughEncounters(allocator, &state, null, 184, 96, &.{}, .prepared);
    try walkThroughEncounters(allocator, &state, null, 240, 272, &.{}, .prepared);
    try std.testing.expect(scenarioBitSet(&state, 47, 3));
    try walkTo(allocator, &state, null, 320, 392, &.{});
    try walkThroughEncounters(allocator, &state, null, 272, 520, &.{}, .prepared);
    try std.testing.expect(scenarioBitSet(&state, 10, 1));
    try walkTo(allocator, &state, null, 80, 512, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 10, 2));
    try std.testing.expectEqual(@as(u8, 2), state.combat.progress.story.scenario.?.soul_eater_spell_slots);
    try std.testing.expectEqualStrings("Earrings", state.sharedItemNames()[0].?);
    try std.testing.expect(state.field_state.progress.story.scenario.?.recruit_flags[17] & 1 == 0);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 10, 4));
    try walkTo(allocator, &state, "va3_room_0", 248, 352, &.{});
    try walkTo(allocator, &state, "world_a", 376, 736, &.{});
    try walkThroughEncounters(allocator, &state, "va6_room_1", 480, 888, &.{}, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 10, 8));
    try walkTo(allocator, &state, "va6_room_0", 184, 232, &.{});
    try walkTo(allocator, &state, "va6_room_2", 248, 152, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{1});
    try walkTo(allocator, &state, "world_b", 24, 232, &.{});
    try std.testing.expectEqualStrings("world_b", currentRoomName(&state));

    errdefer dumpCampaignReplayState(&state);
    try walkThroughEncounters(allocator, &state, "vb1_room_0", 768, 160, &.{}, .retreat);
    try walkTo(allocator, &state, "vb1_room_4", 208, 560, &.{});
    try walkTo(allocator, &state, null, 200, 160, &.{});
    try interactFacing(&state, .up, &.{0});
    for (0..60) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    for (state.combat.progress.party) |member| {
        try std.testing.expectEqual(member.max_hp, member.hp);
        try std.testing.expectEqual(member.max_rune_charges, member.rune_charges);
    }
    try walkTo(allocator, &state, "vb1_room_0", 248, 240, &.{});
    try walkTo(allocator, &state, "vb1_room_5", 392, 144, &.{});
    try walkTo(allocator, &state, null, 192, 72, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 20, 8));
    try walkTo(allocator, &state, "vb1_room_0", 208, 448, &.{});
    try walkTo(allocator, &state, null, 336, 320, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 10, 32));
    try walkTo(allocator, &state, "vb1_room_5", 392, 144, &.{});
    try walkTo(allocator, &state, null, 104, 160, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 10, 64));
    try walkTo(allocator, &state, "vb1_room_0", 208, 448, &.{});
    try walkTo(allocator, &state, null, 392, 256, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 10, 128));
    try walkTo(allocator, &state, "vb1_room_5", 392, 152, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = drainFieldEvent(&state, &.{ 0, 0 }) catch |err| {
        std.debug.print("School scene failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expectEqual(.battle, state.mode);
    try std.testing.expectEqualStrings("vb1_school", state.combat.content.encounters[state.combat.encounter].id);
    try finishBattleWithInput(&state, .travel);
    _ = try drainFieldEvent(&state, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 11, 3));
    try walkTo(allocator, &state, null, 104, 160, &.{});
    try interactFacing(&state, .up, &.{ 0, 1 });
    try std.testing.expect(scenarioBitSet(&state, 11, 12));
    try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[27] != 0);

    try walkTo(allocator, &state, "vb1_room_0", 208, 448, &.{});
    try walkTo(allocator, &state, "world_b", 256, 616, &.{});
    try walkThroughEncounters(allocator, &state, "vb2_room_0", 648, 328, &.{}, .retreat);
    try walkTo(allocator, &state, "vb2_room_5", 472, 368, &.{});
    try walkTo(allocator, &state, null, 112, 96, &.{});
    try interactFacing(&state, .up, &.{});
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor", "camille" });
    try walkTo(allocator, &state, "vb2_room_6", 120, 176, &.{});
    try walkTo(allocator, &state, null, 152, 144, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 11, 32));
    for (0..3) |attempt| {
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        try std.testing.expect(scenarioBitSet(&state, 12, 2));
        if (attempt == 0) {
            _ = try state.tickWithFieldEvents(.{}, .{});
            _ = try drainFieldEvent(&state, &.{0});
        } else {
            try walkTo(allocator, &state, null, 152, 144, &.{});
            try interactFacing(&state, .up, &.{0});
        }
        try std.testing.expect(scenarioBitSet(&state, 11, 128));
        // The dice owner takes over when the room transition settles.
        for (0..300) |_| {
            if (std.mem.eql(u8, currentRoomName(&state), "vb2_room_8")) break;
            _ = try state.tickWithFieldEvents(.{}, .{});
        }
        try std.testing.expectEqualStrings("vb2_room_8", currentRoomName(&state));
        const wager = try playFixedDiceWithInput(&state);
        try std.testing.expectEqualStrings("vb2_room_6", currentRoomName(&state));
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        if (wager.won) break;
    } else return error.KakuWagerLost;
    try std.testing.expect(scenarioBitSet(&state, 12, 1));
    try std.testing.expect(scenarioBitSet(&state, 11, 64));
    try walkTo(allocator, &state, "vb2_room_5", 232, 64, &.{});
    try walkTo(allocator, &state, "vb2_room_0", 184, 240, &.{});
    try walkTo(allocator, &state, null, 136, 528, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expectEqualStrings("world_j", currentRoomName(&state));
    try std.testing.expect(state.auto_travel != null);
    for (0..400) |_| {
        if (state.auto_travel == null) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expectEqualStrings("vb5i0_room_0", currentRoomName(&state));
    try std.testing.expectEqual(@as(u8, 0), state.combat.progress.story.scenario.?.world_mode);
    _ = state.tickWithFieldEvents(.{}, .{}) catch |err| {
        std.debug.print("Island entry failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expectEqual(@as(i32, 128), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 344), state.field_state.y);
    for (0..3) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    const hidden_hero = (try state.scriptedFieldHero(.{ .x = 0, .y = 0 })).?;
    try std.testing.expect(hidden_hero.x > @as(f32, @floatFromInt(state.package.rooms[state.field_state.room].width)));
    _ = drainFieldEvent(&state, &.{}) catch |err| {
        std.debug.print("Island scene failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expectEqualStrings("vb5_room_0", currentRoomName(&state));
    try std.testing.expectEqual(@as(?field.Point, null), state.field_state.scene_view.hero);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor", "camille", "tai_ho" });
    try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[32] & 1 != 0);

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb5_room_9", .x = 600, .y = 112 },
        .{ .want = "vb5_room_10", .x = 584, .y = 360 },
        .{ .want = "vb5_room_11", .x = 432, .y = 48 },
        .{ .want = "vb5_room_12", .x = 216, .y = 56 },
        .{ .want = "vb5_room_13", .x = 360, .y = 80 },
        .{ .want = "vb5_room_14", .x = 416, .y = 360 },
        .{ .want = "vb5_room_15", .x = 280, .y = 56 },
        .{ .want = "vb5_room_16", .x = 8, .y = 120 },
        .{ .want = "vb5_room_17", .x = 272, .y = 40 },
        .{ .want = "vb5_room_18", .x = 216, .y = 56 },
        .{ .want = "vb5_room_19", .x = 360, .y = 120 },
        .{ .want = "vb7_room_4", .x = 416, .y = 360 },
        .{ .want = "vb7_room_2", .x = 184, .y = 56 },
        .{ .want = "vb7a_room_0", .x = 136, .y = 224 },
        .{ .want = "vb7a_room_2", .x = 344, .y = 56 },
        .{ .want = "vb5g_room_1", .x = 136, .y = 224 },
    }, .prepared);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqual(.battle, state.mode);
    try std.testing.expectEqualStrings("vb5g_dir_34a18_1", state.combat.content.encounters[state.combat.encounter].id);
    try finishBattleWithInput(&state, .travel);
    _ = try drainFieldEvent(&state, &.{});
    for (0..5) |_| {
        if (std.mem.eql(u8, currentRoomName(&state), "vb5a2_room_0")) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expectEqualStrings("vb5a2_room_0", currentRoomName(&state));
    try std.testing.expect(scenarioBitSet(&state, 12, 64 | 128));
    try std.testing.expect(scenarioBitSet(&state, 38, 8));
    try std.testing.expectEqual(@as(u8, 1), state.combat.progress.story.scenario.?.castle_tier);
    try std.testing.expectEqual(@as(u8, 1), state.combat.progress.story.recruitment_tier);
    try expectPartyOrder(&state, &.{"hero"});
    for ([_][]const u8{ "gremio", "cleo", "viktor", "camille", "tai_ho", "yam_koo", "luc" }) |id| {
        const reserve = for (state.reserves) |entry| {
            const owned = entry orelse break null;
            if (std.mem.eql(u8, owned.id, id)) break owned;
        } else null;
        const member = reserve orelse return error.MissingFoundingReserve;
        try std.testing.expectEqual(member.max_hp, member.hp);
        try std.testing.expectEqual(member.max_rune_charges, member.rune_charges);
    }
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 35, 2));
    try expectPartyOrder(&state, &.{ "hero", "gremio" });

    try walkTo(allocator, &state, null, 544, 288, &.{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
    try finishHeadquartersPartySelection(&state, null, &.{ "gremio", "viktor", "cleo" });
    try std.testing.expect(scenarioBitSet(&state, 35, 4));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "viktor", "cleo" });
    try walkTo(allocator, &state, null, 544, 288, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 44, 2));
    _ = try state.tickWithFieldEvents(.{}, .{});
    try finishHeadquartersPartySelection(&state, "luc", &.{ "gremio", "viktor", "cleo" });
    try std.testing.expect(!scenarioBitSet(&state, 44, 2));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "viktor", "cleo", "luc" });

    try walkTo(allocator, &state, "vb5a2_room_3", 184, 56, &.{});
    try walkTo(allocator, &state, "vb5a1_room_0", 136, 224, &.{});
    try walkTo(allocator, &state, "vb5a1_room_7", 344, 56, &.{});
    try walkTo(allocator, &state, "vb5ag_room_1", 136, 224, &.{});
    try walkTo(allocator, &state, "vb5ag_room_0", 192, 616, &.{});
    try walkTo(allocator, &state, "world_j", 224, 344, &.{0});
    try std.testing.expect(state.boat_travel != null);
    try std.testing.expectEqual(@as(u8, 1), state.combat.progress.story.scenario.?.world_mode);
    for (0..320) |_| {
        if (state.field_state.x == 118 * 8) break;
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
    }
    try std.testing.expectEqual(@as(i32, 118 * 8), state.field_state.x);
    for (0..32) |_| {
        if (state.boat_travel == null) break;
        _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
    }
    try std.testing.expectEqualStrings("vb2_room_0", currentRoomName(&state));
    try std.testing.expect(state.boat_travel == null);
    try std.testing.expectEqual(@as(u8, 0), state.combat.progress.story.scenario.?.world_mode);

    try walkTo(allocator, &state, "world_b", 280, 48, &.{});
    try walkThroughEncounters(allocator, &state, "vb3_room_0", 592, 544, &.{}, .retreat);
    try walkTo(allocator, &state, null, 96, 392, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 13, 1));
    try walkTo(allocator, &state, "vb3_room_2", 368, 512, &.{});
    try walkTo(allocator, &state, null, 192, 160, &.{});
    try interactFacing(&state, .up, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 13, 4));
    try walkTo(allocator, &state, null, 248, 112, &.{});
    try interactFacing(&state, .up, &.{0});
    for (0..60) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    for (state.combat.progress.party) |member| {
        try std.testing.expectEqual(member.max_hp, member.hp);
        try std.testing.expectEqual(member.max_rune_charges, member.rune_charges);
    }
    try walkTo(allocator, &state, "vb3_room_0", 248, 240, &.{});
    try walkTo(allocator, &state, null, 248, 344, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expectEqualStrings("vb3_room_11", currentRoomName(&state));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb3_room_12", .x = 48, .y = 128 },
        .{ .want = "vb3_room_14", .x = 320, .y = 232 },
    }, .prepared);
    try walkThroughEncounters(allocator, &state, null, 112, 64, &.{}, .prepared);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .down } }, .{});
    try std.testing.expect(state.field_event != null);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqual(@as(i32, 144), state.field_state.y);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb3_room_13", .x = 184, .y = 240 },
        .{ .want = "vb3_room_17", .x = 200, .y = 264 },
    }, .prepared);
    try walkThroughEncounters(allocator, &state, null, 168, 224, &.{}, .prepared);
    try walkThroughEncounters(allocator, &state, null, 168, 152, &.{}, .prepared);
    try walkThroughEncounters(allocator, &state, null, 176, 152, &.{}, .prepared);
    try walkThroughEncounters(allocator, &state, null, 176, 120, &.{}, .prepared);
    try walkThroughEncounters(allocator, &state, null, 152, 120, &.{}, .prepared);
    try walkThroughEncounters(allocator, &state, null, 152, 64, &.{}, .prepared);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb3_room_13", .x = 152, .y = 56 },
        .{ .want = "vb3_room_20", .x = 360, .y = 304 },
    }, .prepared);
    try walkThroughEncounters(allocator, &state, null, 168, 224, &.{}, .prepared);
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 13, 8));
    try std.testing.expect(scenarioBitSet(&state, 43, 64));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "viktor", "cleo", "luc" });
    try walkThroughEncounters(allocator, &state, "vb3_room_28", 72, 296, &.{}, .prepared);
    try std.testing.expectEqualStrings("vb3_room_28", currentRoomName(&state));

    for (0..48) |_| {
        try walkThroughEncounters(allocator, &state, null, 168, 312, &.{}, .retreat);
        for (0..32) |_| {
            if (state.field_event != null) break;
            _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
        }
        try std.testing.expect(state.field_event != null);
        _ = try drainFieldEvent(&state, &.{});
        if (state.mode == .battle) {
            try std.testing.expectEqualStrings("vb3_wheel_monster", state.combat.content.encounters[state.combat.encounter].id);
            try finishBattleWithInput(&state, .travel);
            _ = try drainFieldEvent(&state, &.{});
        }
        const wheel = state.field_state.wheel_state orelse return error.MissingWheelState;
        if (wheel.clock.result == .passage) break;
    } else return error.NoWheelPassage;
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb3_room_29", .x = 168, .y = 40 },
        .{ .want = "vb3_room_30", .x = 152, .y = 40 },
    }, .retreat);
    try walkThroughEncounters(allocator, &state, null, 152, 136, &.{}, .retreat);
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 13, 16));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb3_room_29", .x = 152, .y = 240 },
        .{ .want = "vb3_room_28", .x = 152, .y = 232 },
        .{ .want = "vb3_room_20", .x = 168, .y = 496 },
    }, .retreat);
    for (state.sharedItemNames()) |slot| {
        if (slot != null and std.mem.eql(u8, slot.?, "Kirinji")) break;
    } else return error.MissingKirinji;

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb3_room_13", .x = 600, .y = 232 },
        .{ .want = "vb3_room_17", .x = 280, .y = 112 },
        .{ .want = "vb3_room_13", .x = 24, .y = 224 },
        .{ .want = "vb3_room_14", .x = 72, .y = 216 },
    }, .retreat);
    try walkThroughEncounters(allocator, &state, null, 112, 144, &.{}, .retreat);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
    try std.testing.expect(state.field_event != null);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqual(@as(i32, 64), state.field_state.y);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb3_room_12", .x = 112, .y = 16 },
        .{ .want = "vb3_room_11", .x = 32, .y = 48 },
        .{ .want = "vb3_room_0", .x = 288, .y = 128 },
    }, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("vb3_room_2", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{ 1, 1 });
    try std.testing.expect(scenarioBitSet(&state, 13, 32 | 64));
    for (state.sharedItemNames()) |slot| {
        try std.testing.expect(slot == null or !std.mem.eql(u8, slot.?, "Kirinji"));
    }
    try walkTo(allocator, &state, null, 248, 112, &.{});
    try interactFacing(&state, .up, &.{0});
    for (0..60) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    try walkTo(allocator, &state, "vb3_room_0", 248, 240, &.{});
    try walkTo(allocator, &state, null, 376, 232, &.{});
    try std.testing.expect(scenarioBitSet(&state, 13, 128));
    try walkTo(allocator, &state, "vb3_room_5", 400, 160, &.{});
    try walkToScriptedBattle(allocator, &state, 200, 128, 192, 128, &.{}, "vb3_dir_67da4_1");
    try expectPartyOrder(&state, &.{ "hero", "gremio", "viktor", "cleo", "luc", "lepant" });
    try finishBattleWithInput(&state, .travel);
    _ = try drainFieldEvent(&state, &.{});
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb3_room_7", .x = 72, .y = 56 },
        .{ .want = "vb3_room_9", .x = 376, .y = 152 },
    }, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqual(.battle, state.mode);
    try std.testing.expectEqualStrings("vb3_dir_67da4_1", state.combat.content.encounters[state.combat.encounter].id);
    try finishBattleWithInput(&state, .travel);
    _ = try drainFieldEvent(&state, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 14, 4 | 8));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "viktor", "cleo", "luc" });
    try walkTo(allocator, &state, null, 208, 72, &.{});
    try interactFacing(&state, .up, &.{});
    try walkTo(allocator, &state, null, 216, 184, &.{});
    try interactFacing(&state, .up, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 14, 16 | 32));
    for ([_]u8{ 0, 6, 12, 15, 30, 31 }) |id| {
        try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[id] & 1 != 0);
    }
    try expectPartyOrder(&state, &.{ "hero", "gremio", "viktor", "cleo", "luc" });

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb3_room_7", .x = 216, .y = 240 },
        .{ .want = "vb3_room_5", .x = 72, .y = 104 },
        .{ .want = "vb3_room_0", .x = 360, .y = 344 },
        .{ .want = "world_b", .x = 232, .y = 608 },
        .{ .want = "vb2_room_0", .x = 648, .y = 336 },
    }, .retreat);
    try crossKakuToToran(allocator, &state, "vb5ag_room_0");
    try std.testing.expect(scenarioBitSet(&state, 14, 16 | 32));

    try walkTo(allocator, &state, "vb5ag_room_1", 128, 168, &.{});
    try walkTo(allocator, &state, "vb5ag_room_7", 328, 328, &.{});
    try walkTo(allocator, &state, "vb5a1_room_0", 248, 224, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqualStrings("vb5a1_room_0_e15_ordinary", state.field_event.?.session.instance.?.program_id);
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 19, 16));
    try std.testing.expect(!scenarioBitSet(&state, 15, 2));

    walkTo(allocator, &state, null, 344, 96, &.{}) catch |err| {
        std.debug.print("Toran encounter admission failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expectEqual(.battle, state.mode);
    try std.testing.expectEqualStrings("toran_intruder", state.combat.content.encounters[state.combat.encounter].id);
    try expectPartyOrder(&state, &.{"hero"});
    const potch_before_intruder = state.combat.progress.money;
    try finishBattleWithInput(&state, .defend);
    try std.testing.expectEqual(@as(u32, 4), state.combat.round);
    try std.testing.expectEqual(potch_before_intruder, state.combat.progress.money);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 19, 32 | 64));
    try std.testing.expectEqualStrings("vb5a2_room_0", currentRoomName(&state));

    try interactFacing(&state, .up, &.{1});
    try std.testing.expect(!scenarioBitSet(&state, 15, 2));
    try interactFacing(&state, .up, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 15, 2));
    try std.testing.expectEqual(state.combat.progress.party[0].max_hp, state.combat.progress.party[0].hp);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try expectPartyOrder(&state, &.{ "hero", "gremio" });

    try walkTo(allocator, &state, "vb5a2_room_3", 184, 56, &.{});
    try walkTo(allocator, &state, "vb5a1_room_0", 136, 224, &.{});
    try walkTo(allocator, &state, "vb5a1_room_7", 344, 56, &.{});
    try walkTo(allocator, &state, "vb5ag_room_1", 136, 224, &.{});
    try walkTo(allocator, &state, "vb5ag_room_0", 192, 616, &.{});
    try walkTo(allocator, &state, null, 128, 272, &.{});
    try std.testing.expectEqualStrings("vb5a2_room_0", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 15, 4 | 8));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "kirkis" });

    try walkTo(allocator, &state, null, 544, 288, &.{});
    for ([_][]const u8{ "viktor", "cleo", "luc" }) |id| {
        try interactFacing(&state, .up, &.{});
        _ = try state.tickWithFieldEvents(.{}, .{});
        try finishHeadquartersPartySelection(&state, id, null);
    }
    try expectPartyOrder(&state, &.{ "hero", "gremio", "kirkis", "viktor", "cleo", "luc" });

    try crossToranToKaku(allocator, &state);
    try walkTo(allocator, &state, "world_b", 280, 48, &.{});
    try walkThroughEncounters(allocator, &state, "vb6_room_0", 768, 728, &.{}, .retreat);
    try walkTo(allocator, &state, "vb6_room_1", 488, 56, &.{});
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb6_room_2", .x = 488, .y = 208 },
        .{ .want = "vb6_room_3", .x = 360, .y = 32 },
    }, .retreat);
    try walkThroughEncounters(allocator, &state, null, 152, 48, &.{}, .retreat);
    try walkTo(allocator, &state, null, 160, 48, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 160, 4));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb6_room_2", .x = 8, .y = 144 },
        .{ .want = "vb6_room_3", .x = 360, .y = 272 },
        .{ .want = "vb6_room_4", .x = 360, .y = 280 },
        .{ .want = "vb6_room_5", .x = 368, .y = 272 },
        .{ .want = "vb6_room_6", .x = 360, .y = 80 },
    }, .retreat);
    try std.testing.expectEqualStrings("vb6_room_6", currentRoomName(&state));
    for (0..3) |_| {
        if (scenarioBitSet(&state, 16, 1)) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expect(scenarioBitSet(&state, 15, 32 | 64));
    try std.testing.expect(scenarioBitSet(&state, 16, 1));
    try walkTo(allocator, &state, "world_c", 360, 176, &.{});
    try std.testing.expectEqualStrings("world_c", currentRoomName(&state));

    try walkThroughEncounters(allocator, &state, "vc4_room_0", 624, 528, &.{}, .retreat);
    try std.testing.expectEqualStrings("world_c_point_3", state.field_state.worldEntry(state.package).?.id);
    try walkTo(allocator, &state, "vc4_room_1", 184, 144, &.{});
    try std.testing.expectEqualStrings("vc4_room_1", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 17, 32));
    try walkTo(allocator, &state, "vc4_room_9", 248, 104, &.{});
    try std.testing.expectEqualStrings("vc4_room_9", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 17, 64));
    try walkTo(allocator, &state, null, 184, 112, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expectEqualStrings("vc4_room_11", currentRoomName(&state));
    try std.testing.expect(scenarioBitSet(&state, 18, 1));
    try walkTo(allocator, &state, null, 96, 80, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 18, 2));
    try walkTo(allocator, &state, null, 232, 112, &.{});
    var audience_choice: usize = 0;
    try std.testing.expect(try walkStep(&state, .down, &.{0}, &audience_choice));
    try std.testing.expectEqual(@as(usize, 1), audience_choice);
    try std.testing.expectEqual(@as(i32, 160), state.field_state.y);
    try std.testing.expect(scenarioBitSet(&state, 18, 4));

    try walkTo(allocator, &state, "vc4_room_10", 184, 128, &.{});
    try walkTo(allocator, &state, "vc4_room_9", 200, 48, &.{});
    try walkTo(allocator, &state, "vc4_room_1", 184, 240, &.{});
    try walkTo(allocator, &state, "vc4_room_8", 120, 376, &.{});
    try walkTo(allocator, &state, null, 120, 104, &.{});
    try interactFacing(&state, .up, &.{0});
    for (state.combat.progress.party) |member| try std.testing.expectEqual(member.max_hp, member.hp);
    try walkTo(allocator, &state, "vc4_room_1", 120, 240, &.{});
    try walkTo(allocator, &state, "vc4_room_0", 248, 464, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("world_c", currentRoomName(&state));
    try std.testing.expect(scenarioBitSet(&state, 16, 2));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc1_room_0", .x = 896, .y = 472 },
        .{ .want = "vc1_room_1", .x = 400, .y = 48 },
        .{ .want = "vc1_room_2", .x = 144, .y = 48 },
        .{ .want = "vc1_room_4", .x = 280, .y = 48 },
        .{ .want = "vc1_room_5", .x = 264, .y = 120 },
        .{ .want = "vc1_room_6", .x = 248, .y = 48 },
        .{ .want = "vc1_room_7", .x = 296, .y = 40 },
        .{ .want = "vc1_room_8", .x = 120, .y = 48 },
    }, .retreat);
    try walkThroughEncounters(allocator, &state, null, 208, 232, &.{}, .retreat);
    try std.testing.expect(scenarioBitSet(&state, 16, 4));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc1_room_9", .x = 248, .y = 48 },
        .{ .want = "vc1_room_10", .x = 352, .y = 104 },
        .{ .want = "world_c", .x = 184, .y = 48 },
    }, .retreat);
    try prepareWithCarriedMedicine(&state, .medicine);
    try walkThroughEncounters(allocator, &state, "vc2_room_0", 1104, 368, &.{}, .retreat);
    try std.testing.expectEqualStrings("vc2_room_0", currentRoomName(&state));
    try std.testing.expectEqualStrings("world_c_point_1", state.field_state.worldEntry(state.package).?.id);

    try walkTo(allocator, &state, "vc2_room_9", 528, 80, &.{});
    try walkTo(allocator, &state, null, 248, 152, &.{});
    try interactFacing(&state, .up, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 16, 8));
    try walkTo(allocator, &state, "vc2_room_0", 376, 232, &.{});
    try walkTo(allocator, &state, "vc2_room_6", 72, 544, &.{});
    try walkTo(allocator, &state, null, 224, 144, &.{});
    try interactFacing(&state, .right, &.{0});
    for (state.combat.progress.party) |member| try std.testing.expectEqual(member.max_hp, member.hp);
    try walkTo(allocator, &state, "vc2_room_0", 184, 232, &.{});
    try walkTo(allocator, &state, "world_c", 320, 744, &.{});
    try walkThroughEncounters(allocator, &state, "vc3_room_0", 1096, 272, &.{}, .retreat);
    try std.testing.expectEqualStrings("world_c_point_2", state.field_state.worldEntry(state.package).?.id);
    try walkTo(allocator, &state, null, 184, 88, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 16, 16));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc3_room_1", .x = 184, .y = 96 },
        .{ .want = "vc3_room_2", .x = 248, .y = 160 },
        .{ .want = "vc3_room_3", .x = 104, .y = 96 },
        .{ .want = "vc3_room_4", .x = 248, .y = 168 },
        .{ .want = "vc3_room_5", .x = 184, .y = 224 },
    }, .retreat);

    const closed_barrier = state.field_state.room_scenery.?.instances[11];
    try std.testing.expect(closed_barrier.active());
    try walkThroughEncounters(allocator, &state, null, 72, 128, &.{}, .retreat);
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 20, 128));
    try std.testing.expect(!state.field_state.room_scenery.?.instances[11].active());
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(!scenarioBitSet(&state, 20, 128));
    try std.testing.expectEqualDeep(closed_barrier, state.field_state.room_scenery.?.instances[11]);
    try interactFacing(&state, .up, &.{});
    try walkThroughEncounters(allocator, &state, null, 296, 128, &.{}, .retreat);
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 20, 128));
    try std.testing.expect(scenarioBitSet(&state, 21, 2));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc3_room_6", .x = 88, .y = 624 },
        .{ .want = "vc3_room_7", .x = 184, .y = 144 },
        .{ .want = "vc3_room_8", .x = 232, .y = 160 },
        .{ .want = "vc3_room_9", .x = 104, .y = 96 },
        .{ .want = "vc3_room_10", .x = 184, .y = 64 },
        .{ .want = "vc3_room_11", .x = 568, .y = 64 },
        .{ .want = "vc3_room_12", .x = 184, .y = 96 },
        .{ .want = "vc3_room_13", .x = 232, .y = 160 },
        .{ .want = "vc3_room_14", .x = 104, .y = 96 },
        .{ .want = "vc3_room_15", .x = 184, .y = 224 },
    }, .retreat);

    for ([_]struct { x: i32, y: i32, direction: field.Direction, byte: usize, mask: u8 }{
        .{ .x = 152, .y = 136, .direction = .down, .byte = 21, .mask = 8 },
        .{ .x = 168, .y = 296, .direction = .right, .byte = 21, .mask = 32 },
        .{ .x = 296, .y = 232, .direction = .down, .byte = 21, .mask = 16 },
        .{ .x = 264, .y = 408, .direction = .down, .byte = 22, .mask = 1 },
    }) |conveyor| {
        try walkThroughEncounters(allocator, &state, null, conveyor.x, conveyor.y, &.{}, .retreat);
        for (0..2) |_| {
            if (scenarioBitSet(&state, conveyor.byte, conveyor.mask)) break;
            try stepToCoord(&state, conveyor.direction);
            if (state.mode == .battle) try finishBattleWithInput(&state, .retreat);
        }
        try std.testing.expect(scenarioBitSet(&state, conveyor.byte, conveyor.mask));
    }
    try walkThroughEncounters(allocator, &state, "vc3_room_16", 280, 624, &.{}, .retreat);
    try std.testing.expectEqualStrings("vc3_room_16", currentRoomName(&state));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc3_room_17", .x = 184, .y = 144 },
        .{ .want = "vc3_room_18", .x = 232, .y = 160 },
        .{ .want = "vc3_room_19", .x = 104, .y = 104 },
        .{ .want = "vc3_room_20", .x = 184, .y = 64 },
        .{ .want = "vc3_room_21", .x = 584, .y = 48 },
    }, .retreat);
    try std.testing.expect(state.field_state.room_scenery.?.instances[11].active());
    try walkThroughEncounters(allocator, &state, null, 248, 256, &.{}, .retreat);
    try interactFacing(&state, .up, &.{});

    // The second left press resets the partial attempt. The remaining steps follow the plaque.
    for ([_]struct { plate_x: i32, progress: u8 }{
        .{ .plate_x = 192, .progress = 1 },
        .{ .plate_x = 192, .progress = 0 },
        .{ .plate_x = 192, .progress = 1 },
        .{ .plate_x = 304, .progress = 3 },
        .{ .plate_x = 304, .progress = 7 },
        .{ .plate_x = 192, .progress = 15 },
        .{ .plate_x = 304, .progress = 31 },
        .{ .plate_x = 192, .progress = 63 },
        .{ .plate_x = 192, .progress = 127 },
        .{ .plate_x = 304, .progress = 255 },
    }) |press| {
        try walkThroughEncounters(allocator, &state, null, state.field_state.x, 176, &.{}, .retreat);
        try walkThroughEncounters(allocator, &state, null, press.plate_x, 176, &.{}, .retreat);
        try walkThroughEncounters(allocator, &state, null, press.plate_x, 160, &.{}, .retreat);
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
        try std.testing.expectEqual(press.progress, state.field_state.progress.story.scenario.?.scenario[23]);
        if (press.progress != 255) try std.testing.expect(state.field_state.room_scenery.?.instances[11].active());
    }
    _ = try state.tickWithFieldEvents(.{}, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 22, 4));
    try std.testing.expect(!state.field_state.room_scenery.?.instances[11].active());
    try walkThroughEncounters(allocator, &state, "vc3_room_22", 248, 80, &.{}, .retreat);
    try walkThroughEncounters(allocator, &state, "vc3_room_21", 248, 360, &.{}, .retreat);
    try std.testing.expect(scenarioBitSet(&state, 22, 4));
    try std.testing.expectEqual(@as(u16, 11), state.field_state.room_scenery.?.count);
    try walkThroughEncounters(allocator, &state, "vc3_room_22", 248, 80, &.{}, .retreat);
    try prepareWithCarriedMedicine(&state, .medicine);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc3_room_23", .x = 248, .y = 48 },
        .{ .want = "vc3_room_26", .x = 184, .y = 96 },
        .{ .want = "vc3_room_29", .x = 312, .y = 400 },
    }, .retreat);
    try walkThroughEncounters(allocator, &state, null, 328, 216, &.{}, .retreat);
    const vault_boss = "vc3_dir_38650_1";
    for (0..8) |_| {
        try stepToCoord(&state, .up);
        if (state.mode != .battle) continue;
        if (std.mem.eql(u8, vault_boss, state.combat.content.encounters[state.combat.encounter].id)) break;
        try finishBattleWithInput(&state, .retreat);
    }
    try std.testing.expectEqual(journey.Mode.battle, state.mode);
    try std.testing.expectEqualStrings(vault_boss, state.combat.content.encounters[state.combat.encounter].id);
    try finishBattleWithInput(&state, .travel);
    try std.testing.expect(scenarioBitSet(&state, 35, 8));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc3_room_30", .x = 328, .y = 64 },
        .{ .want = "vc3_room_32", .x = 248, .y = 48 },
    }, .retreat);
    try walkThroughEncounters(allocator, &state, null, 184, 144, &.{}, .retreat);
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 16, 32));
    try std.testing.expect(for (state.shared_items) |slot| {
        if (slot) |item| if (std.mem.eql(u8, item, "running_water_root")) break true;
    } else false);

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc3_room_30", .x = 184, .y = 240 },
        .{ .want = "vc3_room_29", .x = 248, .y = 360 },
        .{ .want = "vc3_room_26", .x = 104, .y = 328 },
        .{ .want = "vc3_room_23", .x = 104, .y = 64 },
        .{ .want = "vc3_room_22", .x = 184, .y = 224 },
        .{ .want = "vc3_room_21", .x = 248, .y = 360 },
        .{ .want = "vc3_room_20", .x = 248, .y = 360 },
        .{ .want = "vc3_room_19", .x = 56, .y = 488 },
        .{ .want = "vc3_room_18", .x = 184, .y = 152 },
        .{ .want = "vc3_room_17", .x = 264, .y = 152 },
        .{ .want = "vc3_room_16", .x = 72, .y = 48 },
        .{ .want = "vc3_room_15", .x = 184, .y = 64 },
    }, .retreat);

    for ([_]struct { x: i32, y: i32, direction: field.Direction, byte: usize, mask: u8 }{
        .{ .x = 184, .y = 552, .direction = .up, .byte = 22, .mask = 1 },
        .{ .x = 264, .y = 376, .direction = .up, .byte = 21, .mask = 16 },
        .{ .x = 280, .y = 216, .direction = .left, .byte = 21, .mask = 32 },
        .{ .x = 152, .y = 280, .direction = .up, .byte = 21, .mask = 8 },
    }) |conveyor| {
        try std.testing.expect(scenarioBitSet(&state, conveyor.byte, conveyor.mask));
        try walkThroughEncounters(allocator, &state, null, conveyor.x, conveyor.y, &.{}, .retreat);
        for (0..2) |_| {
            if (!scenarioBitSet(&state, conveyor.byte, conveyor.mask)) break;
            try stepToCoord(&state, conveyor.direction);
            if (state.mode == .battle) try finishBattleWithInput(&state, .retreat);
        }
        try std.testing.expect(!scenarioBitSet(&state, conveyor.byte, conveyor.mask));
    }

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc3_room_14", .x = 152, .y = 64 },
        .{ .want = "vc3_room_13", .x = 184, .y = 104 },
        .{ .want = "vc3_room_12", .x = 264, .y = 152 },
        .{ .want = "vc3_room_11", .x = 72, .y = 48 },
        .{ .want = "vc3_room_10", .x = 184, .y = 224 },
        .{ .want = "vc3_room_9", .x = 120, .y = 496 },
        .{ .want = "vc3_room_8", .x = 184, .y = 152 },
        .{ .want = "vc3_room_7", .x = 264, .y = 152 },
        .{ .want = "vc3_room_6", .x = 72, .y = 48 },
        .{ .want = "vc3_room_5", .x = 184, .y = 64 },
        .{ .want = "vc3_room_4", .x = 264, .y = 64 },
        .{ .want = "vc3_room_3", .x = 184, .y = 104 },
        .{ .want = "vc3_room_2", .x = 72, .y = 48 },
        .{ .want = "vc3_room_1", .x = 264, .y = 152 },
        .{ .want = "vc3_room_0", .x = 72, .y = 48 },
    }, .retreat);
    try walkThroughEncounters(allocator, &state, null, 184, 224, &.{}, .retreat);
    try std.testing.expectEqualStrings("world_c_point_2", state.field_state.worldEntry(state.package).?.id);
    for (0..3) |_| {
        if (std.mem.eql(u8, currentRoomName(&state), "world_c")) break;
        try stepToCoord(&state, .down);
        if (state.mode == .battle) try finishBattleWithInput(&state, .retreat);
    }
    try std.testing.expectEqualStrings("world_c", currentRoomName(&state));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc2_room_0", .x = 1104, .y = 368 },
        .{ .want = "vc2_room_9", .x = 528, .y = 80 },
    }, .retreat);
    try walkTo(allocator, &state, null, 248, 152, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 16, 64));
    for (state.shared_items) |slot| if (slot) |item| {
        try std.testing.expect(!std.mem.eql(u8, item, "running_water_root"));
    };

    try walkTo(allocator, &state, "vc2_room_0", 376, 232, &.{});
    try walkTo(allocator, &state, "vc2_room_6", 72, 544, &.{});
    try walkTo(allocator, &state, null, 224, 144, &.{});
    try interactFacing(&state, .right, &.{0});
    for (state.combat.progress.party) |member| try std.testing.expectEqual(member.max_hp, member.hp);
    try walkTo(allocator, &state, "vc2_room_0", 184, 232, &.{});
    // Prepare for the next duel while the party is already in the Dwarf Village.
    try walkTo(allocator, &state, "vc2_room_10", 80, 304, &.{});
    try walkTo(allocator, &state, null, 384, 160, &.{});
    try interactService(&state, .right);
    try std.testing.expectEqual(.shop, state.menu.phase);
    const duel_gear = [_]struct { item: field.items.Id, slot: battle.systems.EquipmentSlot }{
        .{ .item = .leather_armor, .slot = .body },
        .{ .item = .half_helmet, .slot = .head },
        .{ .item = .fur_cape, .slot = .accessory_one },
    };
    const rules = state.field_state.item_rules.?;
    var sharpening_budget: u32 = 0;
    const upgrade_costs = state.combat.partyProfile(0).weapon.?.upgrade_costs;
    for (upgrade_costs[@min(state.combat.progress.party[0].weapon_level, 8)..8]) |price| sharpening_budget += price;
    for (duel_gear, 0..) |gear, index| {
        const price = rules.offerGood(gear.item).?.price;
        const money = state.combat.progress.money;
        const inventory = state.combat.progress.party[0].inventory;
        if (index != 0 and (money < price + sharpening_budget or inventory.count() == inventory.slots.len)) continue;
        try std.testing.expect(money >= price);
        try buyStockItem(&state, gear.item, 0);
    }
    const hero_inventory = state.combat.progress.party[0].inventory;
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
    try std.testing.expectEqual(.root, state.menu.phase);
    while (state.menu.selected != .equipment) _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(confirm, .{});
    for (duel_gear) |gear| {
        const index = for (hero_inventory.slots, 1..) |slot, item_index| {
            if (slot != null and slot.?.id == gear.item) break item_index;
        } else continue;
        while (state.menu.equipment_slot != gear.slot) _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        for (0..index) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        try std.testing.expectEqual(state.combat.gearIndex(gear.item), state.combat.progress.party[0].loadout.get(gear.slot));
        _ = try state.tickWithFieldEvents(confirm, .{});
    }
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});

    try walkTo(allocator, &state, "vc2_room_0", 120, 232, &.{});
    try walkTo(allocator, &state, "vc2_room_4", 416, 456, &.{});
    try walkTo(allocator, &state, null, 184, 128, &.{});
    try interactService(&state, .up);
    try buyStockItem(&state, .mega_medicine, 1);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkTo(allocator, &state, "vc2_room_0", 184, 232, &.{});
    try walkTo(allocator, &state, "vc2_room_5", 480, 688, &.{});
    try walkTo(allocator, &state, null, 192, 96, &.{});
    try interactService(&state, .up);
    try std.testing.expectEqual(.blacksmith, state.menu.phase);
    while (state.combat.progress.party[0].weapon_level < state.menu.service_limit) {
        const price = try state.combat.sharpenPrice(0, state.menu.service_limit);
        if (state.combat.progress.money < price) break;
        const level = state.combat.progress.party[0].weapon_level;
        _ = try state.tickWithFieldEvents(confirm, .{});
        _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        try std.testing.expectEqual(level + 1, state.combat.progress.party[0].weapon_level);
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkTo(allocator, &state, "vc2_room_0", 184, 232, &.{});
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "world_c", .x = 320, .y = 744 },
        .{ .want = "vc1_room_10", .x = 1016, .y = 464 },
        .{ .want = "vc1_room_9", .x = 8, .y = 424 },
        .{ .want = "vc1_room_8", .x = 72, .y = 232 },
        .{ .want = "vc1_room_7", .x = 328, .y = 328 },
        .{ .want = "vc1_room_6", .x = 72, .y = 328 },
        .{ .want = "vc1_room_5", .x = 120, .y = 232 },
    }, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 17, 1));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vc1_room_4", .x = 160, .y = 304 },
        .{ .want = "vc1_room_2", .x = 424, .y = 360 },
        .{ .want = "vc1_room_1", .x = 152, .y = 360 },
        .{ .want = "vc1_room_0", .x = 160, .y = 360 },
        .{ .want = "world_c", .x = 96, .y = 360 },
        .{ .want = "vc5_room_0", .x = 624, .y = 528 },
    }, .retreat);
    try std.testing.expectEqualStrings("world_c_point_4", state.field_state.worldEntry(state.package).?.id);
    _ = try state.tickWithFieldEvents(.{}, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 17, 2));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "world_c", .x = 184, .y = 328 },
        .{ .want = "vb6_room_6", .x = 552, .y = 360 },
    }, .retreat);
    try std.testing.expectEqualStrings("world_c_point_6", state.field_state.worldEntry(state.package).?.id);
    for (0..8) |_| {
        if (state.mode != .field) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (state.field_event) |event| {
            const instance = event.session.instance orelse continue;
            const choices: []const u8 = if (std.mem.eql(u8, instance.program_id, "vb6_room_6_e10_ordinary")) &.{0} else &.{};
            _ = try drainFieldEvent(&state, choices);
        }
    }
    try std.testing.expect(scenarioBitSet(&state, 17, 4 | 8 | 16));
    const recruits = state.field_state.progress.story.scenario.?.recruit_flags;
    try std.testing.expect(recruits[14] & 1 != 0 and recruits[21] & 1 != 0);
    try finishCampaignWar(&state, "pannu_yakuta", .side0_victory);
    try std.testing.expectEqualStrings("vb6_room_6", currentRoomName(&state));
    try prepareWithCarriedMedicine(&state, .medicine);

    try walkTo(allocator, &state, "world_c", 360, 216, &.{});
    try walkThroughEncounters(allocator, &state, null, 808, 688, &.{}, .prepared);
    try restoreWithOwnedMedicine(&state, 1, .mega_medicine, false, 0);
    try std.testing.expectEqual(state.combat.progress.party[0].max_hp, state.combat.progress.party[0].hp);
    try walkThroughEncounters(allocator, &state, "vc6_room_0", 808, 696, &.{}, .retreat);
    try std.testing.expectEqualStrings("world_c_point_5", state.field_state.worldEntry(state.package).?.id);
    for (0..8) |_| {
        if (state.mode != .field) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expect(scenarioBitSet(&state, 18, 8 | 16 | 32 | 64));
    try std.testing.expectEqualStrings("vc6_room_14", currentRoomName(&state));
    try std.testing.expectEqual(journey.Mode.duel, state.mode);
    try std.testing.expectEqualStrings("shu_kwanda", state.active_duel.?.state.duel.id);
    try std.testing.expectEqual(@as(i32, 280), state.active_duel.?.state.fighters[1].hp);

    var won_kwanda = false;
    for (0..20000) |_| {
        if (state.active_duel == null) break;
        const duel = &state.active_duel.?.state;
        switch (duel.phase) {
            .choosing => {
                const hero, const foe = duel.fighters;
                const outgoing = @max(1, @as(i32, hero.attack) - foe.defense);
                const incoming = @max(1, @as(i32, foe.attack) - hero.defense);
                const counter: @TypeOf(duel.selected) = switch (try visibleDuelCommand(duel)) {
                    .attack => blk: {
                        if (foe.hp <= outgoing and hero.hp > incoming) break :blk .attack;
                        const desperate_damage = @min(2 * outgoing, @divTrunc(foe.hp, 4));
                        if (hero.hp > 3 * incoming and desperate_damage >= incoming) break :blk .desperate_attack;
                        break :blk .defend;
                    },
                    .defend => .attack,
                    .desperate_attack => if (foe.hp <= outgoing) .attack else .defend,
                };
                _ = try state.tickWithFieldEvents(.{}, .{
                    .up = duel.selected != counter and counter == .desperate_attack,
                    .down = duel.selected != counter and counter == .defend,
                    .confirm = duel.selected == counter,
                });
            },
            .finished => {
                if (duel.outcome != .victory) std.debug.print("Kwanda duel ended in round {d}: hero HP {d}/{d}, attack {d}, defense {d}, weapon level {d}, foe HP {d}\n", .{
                    duel.round, duel.fighters[0].hp, duel.fighters[0].maximum_hp, duel.fighters[0].attack, duel.fighters[0].defense, state.combat.progress.party[0].weapon_level, duel.fighters[1].hp,
                });
                try std.testing.expectEqual(.victory, duel.outcome.?);
                won_kwanda = true;
                _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
            },
            else => _ = try state.tickWithFieldEvents(.{}, .{}),
        }
    }
    try std.testing.expect(won_kwanda);
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expect(state.active_duel == null and state.scripted_battle == null);
    for (0..3) |_| {
        if (scenarioBitSet(&state, 19, 4)) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expect(scenarioBitSet(&state, 19, 2 | 4));

    try walkTo(allocator, &state, null, 72, 208, &.{});
    try interactFacing(&state, .down, &.{1});
    try std.testing.expectEqualStrings("vc6_room_0", currentRoomName(&state));
    try std.testing.expect(scenarioBitSet(&state, 19, 8));
    try std.testing.expect(!scenarioBitSet(&state, 33, 2));
    _ = try state.tickWithFieldEvents(.{}, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 19, 1));
    const after_duel = state.field_state.progress.story.scenario.?.recruit_flags;
    for ([_]usize{ 25, 9, 75 }) |member| try std.testing.expect(after_duel[member] & 1 != 0);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "world_c", .x = 248, .y = 488 },
        .{ .want = "vb6_room_6", .x = 552, .y = 360 },
    }, .retreat);
    try walkTo(allocator, &state, "vb6_room_12", 304, 152, &.{});
    try walkTo(allocator, &state, null, 208, 184, &.{});
    try interactFacing(&state, .right, &.{0});
    try std.testing.expectEqual(state.combat.progress.party[0].max_hp, state.combat.progress.party[0].hp);
    try walkTo(allocator, &state, "vb6_room_6", 184, 240, &.{});
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb6_room_5", .x = 8, .y = 216 },
        .{ .want = "vb6_room_4", .x = 8, .y = 160 },
        .{ .want = "vb6_room_3", .x = 8, .y = 288 },
        .{ .want = "vb6_room_2", .x = 8, .y = 304 },
        .{ .want = "vb6_room_3", .x = 360, .y = 176 },
        .{ .want = "vb6_room_2", .x = 8, .y = 48 },
        .{ .want = "vb6_room_1", .x = 8, .y = 224 },
        .{ .want = "vb6_room_0", .x = 8, .y = 280 },
        .{ .want = "world_b", .x = 288, .y = 360 },
        .{ .want = "vb2_room_0", .x = 648, .y = 328 },
    }, .retreat);
    try crossKakuToToran(allocator, &state, null);
    const garan_dock = currentRoomName(&state);
    const expanded_garan = std.mem.eql(u8, garan_dock, "vb5bg_room_0");
    if (expanded_garan) {
        try walkTo(allocator, &state, "vb5b4_room_3", 128, 168, &.{});
        try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
            .{ .want = "vb5b4_room_1", .x = 360, .y = 272 },
            .{ .want = "vb5b4_room_0", .x = 360, .y = 128 },
            .{ .want = "vb5b4_room_2", .x = 216, .y = 56 },
            .{ .want = "vb5b3_room_0", .x = 136, .y = 224 },
        }, .retreat);
    } else try walkTo(allocator, &state, "vb5a2_room_0", 128, 168, &.{});
    try std.testing.expect(scenarioBitSet(&state, 230, 2));
    try walkTo(allocator, &state, null, if (expanded_garan) 480 else 424, if (expanded_garan) 264 else 224, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 230, 4));
    try crossToranToKaku(allocator, &state);
    try walkTo(allocator, &state, "vb2_room_2", 96, 336, &.{});
    try walkTo(allocator, &state, null, 264, 144, &.{});
    try interactFacing(&state, .up, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 230, 2 | 4 | 8));
    try std.testing.expect(state.field_state.progress.story.scenario.?.recruit_flags[17] & 1 != 0);

    try walkTo(allocator, &state, "vb2_room_0", 184, 240, &.{});
    try crossKakuToToran(allocator, &state, null);
    const expanded_assembly = std.mem.eql(u8, currentRoomName(&state), "vb5bg_room_0");
    try walkFromToranDockToCouncil(allocator, &state);
    if (expanded_assembly) {
        try walkTo(allocator, &state, null, 480, 160, &.{});
        try interactFacing(&state, .up, &.{});
        for (0..3) |_| {
            if (state.mode != .field) break;
            _ = try state.tickWithFieldEvents(.{}, .{});
            const owner = state.field_event orelse continue;
            const program = owner.session.instance.?.program_id;
            _ = try drainFieldEvent(&state, if (std.mem.eql(u8, program, "vb5b3_room_0_e22_ordinary")) &.{0} else &.{});
        }
    } else {
        try walkTo(allocator, &state, null, 432, 160, &.{});
        try interactFacing(&state, .up, &.{1});
        try std.testing.expect(scenarioBitSet(&state, 230, 16));
        try std.testing.expectEqual(journey.Mode.field, state.mode);
        try walkTo(allocator, &state, null, 464, 160, &.{});
        try interactFacing(&state, .up, &.{0});
    }
    try finishCampaignWar(&state, "garan", .side0_victory);
    try std.testing.expect(scenarioBitSet(&state, 230, 2 | 4 | 8 | 16 | 32));
    try std.testing.expectEqualStrings(if (expanded_assembly) "vb5b3_room_0" else "vb5a2_room_0", currentRoomName(&state));

    try crossToranToKaku(allocator, &state);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "world_b", .x = 280, .y = 48 },
        .{ .want = "vb4_room_0", .x = 256, .y = 568 },
    }, .retreat);
    try walkTo(allocator, &state, null, 400, 144, &.{});
    try finishCampaignWar(&state, "scarleticia_pollen", .scripted_completion);
    try std.testing.expect(scenarioBitSet(&state, 198, 1 | 4));
    try std.testing.expectEqualStrings("vb4_room_0", currentRoomName(&state));

    try expectPartyOrder(&state, &.{ "hero", "gremio", "kirkis", "viktor", "cleo", "luc" });
    const luc = state.combat.ownedMember(5);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    var scouting_roster: journey.party_selection.View = .{};
    const roster = try scouting_roster.read(&state);
    try std.testing.expect(roster.reserve_slot);
    for ([_][]const u8{ "gremio", "viktor" }) |id| {
        for (roster.forced) |forced| {
            if (std.mem.eql(u8, forced, id)) break;
        } else return error.MissingRequiredScout;
    }
    try std.testing.expect(!scenarioBitSet(&state, 198, 2));
    try makeRoomForRecruit(&state, "luc");
    try expectPartyOrder(&state, &.{ "hero", "gremio", "kirkis", "viktor", "cleo", "flik" });
    for (state.reserves) |reserve| {
        const member = reserve orelse continue;
        if (std.mem.eql(u8, member.id, "luc")) {
            try std.testing.expectEqualDeep(luc, member);
            break;
        }
    } else return error.MissingScoutReserveMember;
    try std.testing.expect(scenarioBitSet(&state, 198, 1 | 2 | 4 | 8));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "world_d", .x = 128, .y = 328 },
        .{ .want = "vd3_room_0", .x = 976, .y = 640 },
    }, .retreat);
    try std.testing.expectEqualStrings("world_d_point_2", state.field_state.worldEntry(state.package).?.id);
    try walkTo(allocator, &state, null, 472, 544, &.{});
    var ferry_choice: usize = 0;
    _ = try walkStep(&state, .right, &.{0}, &ferry_choice);
    try std.testing.expectEqual(@as(usize, 1), ferry_choice);
    try std.testing.expectEqualStrings("world_k", currentRoomName(&state));
    try std.testing.expect(scenarioBitSet(&state, 193, 32));
    try std.testing.expectEqual(@as(u8, 1), state.field_state.progress.story.scenario.?.world_mode);
    const afloat = try journey.Snapshot.capture(state);
    var legacy_departure = afloat;
    legacy_departure.story.scenario.?.world_mode = 0;
    try legacy_departure.validate(state);
    try afloat.apply(&state);

    try walkTo(allocator, &state, null, 544, 720, &.{});
    try stepToCoord(&state, .left);
    try std.testing.expectEqual(@as(i32, 544), state.field_state.x);
    try std.testing.expectEqual(.boat_rapids, std.meta.activeTag(state.field_state.dialogue.?.source));
    try std.testing.expect(scenarioBitSet(&state, 193, 64));
    const river = state.package.rooms[state.field_state.room];
    var upgraded = state.field_state.progress.story.scenario.?;
    try upgraded.apply(river.boat_rapids.?.requires);
    try std.testing.expectEqual(.open, river.boatPassage(536, 720, &upgraded));
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expect(state.field_state.dialogue == null);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{.{ .want = "vd3_room_0", .x = 744, .y = 184 }}, .retreat);
    try std.testing.expectEqualStrings("world_k_point_2", state.field_state.worldEntry(state.package).?.id);
    try std.testing.expectEqual(@as(u8, 0), state.field_state.progress.story.scenario.?.world_mode);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 193, 16));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "world_d", .x = 312, .y = 48 },
        .{ .want = "vd2_room_0", .x = 968, .y = 448 },
        .{ .want = "vd2_room_1", .x = 304, .y = 112 },
    }, .retreat);
    try std.testing.expectEqualStrings("Teien", state.package.rooms[state.field_state.room].title);
    try walkTo(allocator, &state, null, 184, 120, &.{});
    try interactFacing(&state, .up, &.{1});
    try makeRoomForRecruit(&state, "cleo");
    try expectPartyOrder(&state, &.{ "hero", "gremio", "kirkis", "viktor", "flik", "gen" });
    try std.testing.expect(scenarioBitSet(&state, 192, 4));

    try walkTo(allocator, &state, "vd2_room_0", 184, 232, &.{});
    try walkTo(allocator, &state, "vd2_room_2", 432, 104, &.{});
    try walkTo(allocator, &state, null, 184, 152, &.{});
    try interactFacing(&state, .up, &.{});
    try makeRoomForRecruit(&state, "kirkis");
    try expectPartyOrder(&state, &.{ "hero", "gremio", "viktor", "flik", "gen", "kamandol" });
    try std.testing.expect(scenarioBitSet(&state, 192, 4 | 8 | 16 | 32));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vd2_room_0", .x = 184, .y = 232 },
        .{ .want = "world_d", .x = 16, .y = 320 },
        .{ .want = "vd3_room_0", .x = 976, .y = 640 },
    }, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("vd3_room_4", currentRoomName(&state));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "viktor", "flik" });

    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 193, 1 | 2));
    try walkTo(allocator, &state, "vd3_room_3", 288, 72, &.{});
    try walkTo(allocator, &state, "vd3_room_0", 184, 208, &.{});
    try walkTo(allocator, &state, null, 480, 544, &.{});
    try std.testing.expect(scenarioBitSet(&state, 193, 4));
    ferry_choice = 0;
    _ = try walkStep(&state, .right, &.{0}, &ferry_choice);
    try std.testing.expectEqual(@as(usize, 1), ferry_choice);
    try std.testing.expectEqualStrings("world_k", currentRoomName(&state));
    try walkTo(allocator, &state, "vd4_room_0", 488, 728, &.{});
    try std.testing.expectEqualStrings("vd4_room_0", currentRoomName(&state));
    try std.testing.expectEqualStrings("world_k_point_1", state.field_state.worldEntry(state.package).?.id);
    try std.testing.expectEqual(@as(u8, 0), state.field_state.progress.story.scenario.?.world_mode);
    try std.testing.expect(scenarioBitSet(&state, 193, 8));

    try std.testing.expectEqualStrings("Liukan's Hermitage", state.package.rooms[state.field_state.room].title);
    try walkTo(allocator, &state, null, 184, 152, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 194, 1));
    try expectPartyOrder(&state, &.{ "hero", "gremio", "viktor", "flik" });

    try walkTo(allocator, &state, null, 232, 480, &.{});
    ferry_choice = 0;
    _ = try walkStep(&state, .right, &.{0}, &ferry_choice);
    try std.testing.expectEqual(@as(usize, 1), ferry_choice);
    try std.testing.expectEqualStrings("world_k", currentRoomName(&state));
    try std.testing.expectEqual(@as(u8, 1), state.field_state.progress.story.scenario.?.world_mode);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vd3_room_0", .x = 744, .y = 184 },
        .{ .want = "world_d", .x = 312, .y = 48 },
    }, .retreat);
    try crossRegionDToToran(allocator, &state);
    try std.testing.expect(scenarioBitSet(&state, 194, 1));
    try walkFromToranDockToCouncil(allocator, &state);
    const expanded_rescue = std.mem.eql(u8, currentRoomName(&state), "vb5b3_room_0");
    try walkTo(allocator, &state, null, 464, 160, &.{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
    const briefing = state.field_event orelse return error.MissingPrisonBriefing;
    try std.testing.expectEqualStrings(if (expanded_rescue) "vb5b3_room_0_rescue_briefing" else "vb5a2_room_0_rescue_briefing", briefing.session.instance.?.program_id);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(carriesSharedItem(&state, "mathiu_s_letter__source_90"));
    try std.testing.expect(scenarioBitSet(&state, 230, 64));

    try walkTo(allocator, &state, null, if (expanded_rescue) 464 else 544, if (expanded_rescue) 160 else 288, &.{});
    for ([_][]const u8{ "kirkis", "cleo" }) |id| {
        try interactFacing(&state, .up, &.{});
        _ = try state.tickWithFieldEvents(.{}, .{});
        try finishHeadquartersPartySelection(&state, id, null);
    }
    const prison_party: []const []const u8 = &.{ "hero", "gremio", "viktor", "flik", "kirkis", "cleo" };
    try expectPartyOrder(&state, prison_party);
    try crossToranToRegionD(allocator, &state);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vd1_room_0", .x = 608, .y = 400 },
        .{ .want = "vd1_room_1", .x = 632, .y = 272 },
    }, .retreat);
    try std.testing.expectEqualStrings("Antei", state.package.rooms[state.field_state.room].title);
    try walkTo(allocator, &state, null, 184, 112, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(!carriesSharedItem(&state, "mathiu_s_letter__source_90"));
    try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[45] & 1 != 0);
    try expectPartyOrder(&state, prison_party);
    for (state.reserves) |reserve| {
        const member = reserve orelse continue;
        if (std.mem.eql(u8, member.id, "kimberly")) {
            try std.testing.expectEqual(17, member.level);
            break;
        }
    } else return error.MissingKimberlyReserve;
    try walkTo(allocator, &state, "vd1_room_0", 184, 232, &.{});
    try walkTo(allocator, &state, "vd1_room_5", 520, 160, &.{});
    try walkTo(allocator, &state, null, 184, 152, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[34] & 1 != 0);
    try std.testing.expect(scenarioBitSet(&state, 195, 4 | 8));

    try walkTo(allocator, &state, "vd1_room_0", 184, 232, &.{});
    try walkTo(allocator, &state, "vd1_room_6", 544, 432, &.{});
    try walkTo(allocator, &state, null, 128, 112, &.{});
    try interactFacing(&state, .up, &.{0});
    for (state.combat.progress.party) |member| try std.testing.expectEqual(member.max_hp, member.hp);
    try walkTo(allocator, &state, "vd1_room_0", 184, 208, &.{});
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{.{ .want = "world_d", .x = 368, .y = 592 }}, .retreat);
    try crossRegionDToToran(allocator, &state);
    try walkFromToranDockToCouncil(allocator, &state);
    const expanded_orders = std.mem.eql(u8, currentRoomName(&state), "vb5b3_room_0");
    try walkTo(allocator, &state, null, 464, 160, &.{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
    const orders = state.field_event orelse return error.MissingPrisonOrders;
    try std.testing.expectEqualStrings(if (expanded_orders) "vb5b3_room_0_prison_orders" else "vb5a2_room_0_prison_orders", orders.session.instance.?.program_id);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(carriesSharedItem(&state, "fake_orders"));
    try std.testing.expect(scenarioBitSet(&state, 230, 64 | 128));

    try crossToranToRegionD(allocator, &state);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{.{ .want = "vd5_room_0", .x = 648, .y = 720 }}, .retreat);
    try walkTo(allocator, &state, null, 312, 152, &.{});
    if (!scenarioBitSet(&state, 196, 1)) {
        var guard_choices: usize = 0;
        _ = try walkStep(&state, .up, &.{}, &guard_choices);
    }
    try std.testing.expect(scenarioBitSet(&state, 196, 1));
    try walkTo(allocator, &state, "vd5_room_1", 312, 144, &.{});
    try std.testing.expectEqualStrings("vd5_room_1", currentRoomName(&state));
    try std.testing.expectEqualStrings("Soniere Prison", state.package.rooms[state.field_state.room].title);
    try std.testing.expect(scenarioBitSet(&state, 196, 1));

    try walkThroughEncounters(allocator, &state, null, 72, 448, &.{}, .prepared);
    var passage_choices: usize = 0;
    _ = try walkStep(&state, .up, &.{}, &passage_choices);
    try std.testing.expect(scenarioBitSet(&state, 196, 8));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vd5_room_2", .x = 128, .y = 272 },
        .{ .want = "vd5_room_3", .x = 272, .y = 80 },
        .{ .want = "vd5_room_4", .x = 80, .y = 360 },
        .{ .want = "vd5_room_5", .x = 272, .y = 80 },
        .{ .want = "vd5_room_6", .x = 80, .y = 360 },
        .{ .want = "vd5_room_7", .x = 792, .y = 624 },
    }, .prepared);
    for ([_]struct { y: i32, battle_id: []const u8, mask: u8 }{
        .{ .y = 120, .battle_id = "vd5_dir_5b5d4_1", .mask = 1 },
        .{ .y = 344, .battle_id = "vd5_dir_5b5f0_1", .mask = 2 },
    }) |guard| {
        try walkThroughEncounters(allocator, &state, null, 392, guard.y, &.{}, .prepared);
        if (!scenarioBitSet(&state, 196, guard.mask << 4)) {
            var guard_choices: usize = 0;
            _ = try walkStep(&state, .down, &.{}, &guard_choices);
            try std.testing.expectEqual(.battle, state.mode);
            try finishBattleWithInput(&state, .travel);
        }
        try std.testing.expectEqualStrings(guard.battle_id, state.combat.content.encounters[state.combat.encounter].id);
        try std.testing.expectEqual(.victory, state.combat.phase);
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        try std.testing.expect(scenarioBitSet(&state, 222, guard.mask));
    }
    try walkThroughEncounters(allocator, &state, null, 80, 504, &.{}, .prepared);
    try std.testing.expect(scenarioBitSet(&state, 196, 1 | 2));

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vd5_room_6", .x = 368, .y = 40 },
        .{ .want = "vd5_room_5", .x = 112, .y = 40 },
        .{ .want = "vd5_room_4", .x = 272, .y = 384 },
        .{ .want = "vd5_room_3", .x = 80, .y = 40 },
        .{ .want = "vd5_room_2", .x = 272, .y = 384 },
        .{ .want = "vd5_room_1", .x = 80, .y = 40 },
    }, .prepared);
    const soul_eater_slots = state.combat.progress.story.scenario.?.soul_eater_spell_slots;
    const castle_wing = [_][]const u8{ "vb5b4_room_3", "vb5c4_room_3", "vb5c4_room_7" };
    const destination = castle_wing[@min(state.combat.progress.story.scenario.?.castle_tier -| 2, 2)];
    try walkThroughEncounters(allocator, &state, destination, 72, 408, &.{}, .prepared);
    try std.testing.expectEqualStrings(destination, currentRoomName(&state));
    try expectPartyOrder(&state, &.{"hero"});
    try std.testing.expect(scenarioBitSet(&state, 196, 1 | 2 | 4));
    try std.testing.expect(scenarioBitSet(&state, 38, 8));
    const escaped = state.combat.progress.story.scenario.?;
    try std.testing.expectEqual(2, escaped.recruit_flags[2] & 3);
    try std.testing.expectEqual(soul_eater_slots + 1, escaped.soul_eater_spell_slots);

    try std.testing.expectEqualStrings("vb5b4_room_3", currentRoomName(&state));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb5b4_room_1", .x = 360, .y = 272 },
        .{ .want = "vb5b4_room_0", .x = 360, .y = 128 },
        .{ .want = "vb5b4_room_2", .x = 216, .y = 56 },
        .{ .want = "vb5b3_room_0", .x = 136, .y = 224 },
    }, .prepared);
    try walkTo(allocator, &state, null, 480, 264, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 231, 1 | 2));
    try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[7] & 1 != 0);
    try expectPartyOrder(&state, &.{ "hero", "viktor", "flik" });
    try finishCampaignWar(&state, "scarleticia_antidote", .side0_victory);
    try std.testing.expectEqualStrings("vb5b3_room_0", currentRoomName(&state));

    try crossToranToKaku(allocator, &state);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "world_b", .x = 280, .y = 48 },
        .{ .want = "vb4_room_0", .x = 256, .y = 568 },
        .{ .want = "world_d", .x = 128, .y = 328 },
        .{ .want = "vd6_room_0", .x = 392, .y = 472 },
    }, .retreat);
    for (0..2) |_| {
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expect(scenarioBitSet(&state, 197, 4 | 8));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vd6_room_1", .x = 312, .y = 528 },
        .{ .want = "vd6_room_2", .x = 72, .y = 96 },
        .{ .want = "vd6_room_3", .x = 232, .y = 88 },
        .{ .want = "vd6_room_0", .x = 72, .y = 456 },
    }, .retreat);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(@as(usize, 2), try drainFieldEvent(&state, &.{ 1, 1 }));
    try std.testing.expect(scenarioBitSet(&state, 197, 1));
    try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[28] & 1 != 0);
    try expectPartyOrder(&state, &.{ "hero", "viktor", "flik" });
    const milich_recruited = for (state.reserves) |reserve| {
        if (reserve != null and std.mem.eql(u8, reserve.?.id, "milich")) break true;
    } else false;
    try std.testing.expect(milich_recruited);
    for ([_]u8{ 35, 17 }) |character| {
        try std.testing.expect(std.mem.indexOfScalar(u8, &state.field_state.auxiliary_party.?, character) == null);
    }
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vd6_room_3", .x = 192, .y = 312 },
        .{ .want = "vd6_room_2", .x = 232, .y = 208 },
        .{ .want = "vd6_room_1", .x = 72, .y = 448 },
        .{ .want = "vd6_room_0", .x = 232, .y = 416 },
        .{ .want = "world_d", .x = 312, .y = 720 },
    }, .retreat);
    try crossRegionDToToran(allocator, &state);
    try walkFromToranDockToCouncil(allocator, &state);
    try std.testing.expect(scenarioBitSet(&state, 197, 1));
    try verifyPahnWin(allocator, &state);
    try beginPahnDuel(allocator, &state);
    for (0..6000) |_| {
        const active = state.active_duel orelse break;
        _ = try state.tickWithFieldEvents(.{}, .{ .confirm = active.state.phase == .choosing or active.state.phase == .finished });
    }
    try std.testing.expect(state.active_duel == null and state.scripted_battle == null);
    try std.testing.expect(scenarioBitSet(&state, 34, 2));
    for (0..3) |_| {
        if (std.mem.eql(u8, currentRoomName(&state), "vb5b3_room_0")) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expectEqualStrings("vb5b3_room_0", currentRoomName(&state));
    try std.testing.expectEqual(@as(u8, 0), state.field_state.progress.story.scenario.?.recruit_flags[6] & 1);

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb5b3_room_3", .x = 200, .y = 56 },
        .{ .want = "vb5b4_room_0", .x = 248, .y = 224 },
        .{ .want = "vb5b4_room_1", .x = 8, .y = 320 },
        .{ .want = "vb5b4_room_3", .x = 8, .y = 128 },
    }, .prepared);
    try std.testing.expect(!scenarioBitSet(&state, 231, 8));
    try walkTo(allocator, &state, null, 184, 240, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 231, 8));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb5b4_room_1", .x = 360, .y = 272 },
        .{ .want = "vb5b4_room_0", .x = 360, .y = 128 },
        .{ .want = "vb5b4_room_2", .x = 216, .y = 56 },
        .{ .want = "vb5b3_room_0", .x = 136, .y = 224 },
    }, .prepared);
    try std.testing.expect(!scenarioBitSet(&state, 231, 16));
    try walkTo(allocator, &state, null, 520, 168, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 231, 16));

    try walkTo(allocator, &state, "vb5b3_room_3", 200, 56, &.{});
    try walkTo(allocator, &state, "vb5b3_room_0", 136, 224, &.{});
    try walkTo(allocator, &state, null, 544, 424, &.{});
    try interactFacing(&state, .left, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try finishHeadquartersPartySelectionFill(&state, "tai_ho", &.{ "viktor", "cleo", "flik", "kwanda", "stallion", "valeria", "camille" }, 4);
    try std.testing.expectEqual(@as(usize, 4), state.combat.partyCount());
    try std.testing.expectEqualStrings("hero", state.combat.progress.party[0].id);
    try std.testing.expectEqualStrings("tai_ho", state.combat.progress.party[1].id);
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb5b3_room_2", .x = 328, .y = 56 },
        .{ .want = "vb5b2_room_0", .x = 136, .y = 224 },
        .{ .want = "vb5b2_room_3", .x = 184, .y = 56 },
        .{ .want = "vb5b1_room_0", .x = 136, .y = 224 },
        .{ .want = "vb5b1_room_7", .x = 344, .y = 56 },
        .{ .want = "vb5bg_room_1", .x = 136, .y = 224 },
        .{ .want = "vb5bg_room_0", .x = 192, .y = 616 },
    }, .retreat);
    try walkTo(allocator, &state, null, 144, 344, &.{});
    try std.testing.expect(!scenarioBitSet(&state, 231, 32));
    try interactFacing(&state, .down, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 231, 32) and scenarioBitSet(&state, 199, 1));
    try sailToranToRegionG(allocator, &state);
    try restInNorthernSwallowPass(allocator, &state);
    try walkTo(allocator, &state, "vg1_room_3", 56, 184, &.{});
    try walkTo(allocator, &state, null, 168, 104, &.{});
    try interactService(&state, .up);
    for (state.combat.progress.party, 0..) |*member, index| {
        if (member.inventory.count() < member.inventory.slots.len) try buyStockItem(&state, .sacrificial_buddha, index);
        for (0..2) |_| {
            if (member.inventory.count() == member.inventory.slots.len) break;
            try buyStockItem(&state, .medicine, index);
        }
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkTo(allocator, &state, "vg1_room_0", 184, 240, &.{});

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "world_g", .x = 136, .y = 48 },
        .{ .want = "vg2_room_0", .x = 624, .y = 472 },
        .{ .want = "vg2_room_1", .x = 296, .y = 272 },
        .{ .want = "vg2_room_0", .x = 56, .y = 344 },
        .{ .want = "world_g", .x = 168, .y = 40 },
        .{ .want = "vg3_room_0", .x = 624, .y = 248 },
    }, .prepared);
    try walkContinuousHop(allocator, &state, "vg3_room_1", 328, 120, &.{ 0, 0 });
    try std.testing.expect(!carriesSharedItem(&state, "fire_spear"));
    try walkTo(allocator, &state, null, 360, 152, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(carriesSharedItem(&state, "fire_spear"));
    try std.testing.expect(scenarioBitSet(&state, 199, 32));
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vg3_room_0", .x = 184, .y = 240 },
        .{ .want = "world_g", .x = 120, .y = 360 },
        .{ .want = "vg2_room_0", .x = 624, .y = 456 },
        .{ .want = "vg2_room_1", .x = 216, .y = 272 },
        .{ .want = "vg2_room_0", .x = 440, .y = 344 },
        .{ .want = "world_g", .x = 168, .y = 616 },
        .{ .want = "vg1_room_0", .x = 640, .y = 744 },
        .{ .want = "vg1_room_6", .x = 256, .y = 440 },
    }, .prepared);
    try walkTo(allocator, &state, null, 184, 184, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expectEqualStrings("vg1_room_0", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 200, 1 | 2));
    try restInNorthernSwallowPass(allocator, &state);
    try walkTo(allocator, &state, "vg1_room_3", 56, 184, &.{});
    try walkTo(allocator, &state, null, 168, 104, &.{});
    try interactService(&state, .up);
    const hero_pack = &state.combat.progress.party[0].inventory;
    for (0..3) |_| {
        if (hero_pack.count() == hero_pack.slots.len) break;
        try buyStockItem(&state, .sacrificial_buddha, 0);
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkTo(allocator, &state, "vg1_room_0", 184, 240, &.{});

    try walkTo(allocator, &state, null, 208, 528, &.{});
    try walkTo(allocator, &state, null, 208, 544, &.{});
    var harbor_choice: usize = 0;
    _ = try walkStep(&state, .right, &.{1}, &harbor_choice);
    try std.testing.expectEqual(@as(usize, 1), harbor_choice);
    try std.testing.expectEqualStrings("vg1_room_0", currentRoomName(&state));
    try std.testing.expect(state.boat_travel == null);
    harbor_choice = 0;
    _ = try walkStep(&state, .right, &.{0}, &harbor_choice);
    try std.testing.expectEqual(@as(usize, 1), harbor_choice);
    try std.testing.expectEqualStrings("world_j", currentRoomName(&state));
    try std.testing.expectEqual(@as(i32, 47 * 8), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 13 * 8), state.field_state.y);
    try sailBoat(&state, &.{
        .{ .direction = .down, .cells = 5 },  .{ .direction = .right, .cells = 1 },
        .{ .direction = .down, .cells = 3 },  .{ .direction = .right, .cells = 1 },
        .{ .direction = .down, .cells = 7 },  .{ .direction = .right, .cells = 1 },
        .{ .direction = .down, .cells = 20 }, .{ .direction = .right, .cells = 54 },
        .{ .direction = .down, .cells = 1 },  .{ .direction = .right, .cells = 1 },
        .{ .direction = .down, .cells = 1 },  .{ .direction = .right, .cells = 1 },
        .{ .direction = .down, .cells = 4 },  .{ .direction = .right, .cells = 1 },
        .{ .direction = .down, .cells = 1 },  .{ .direction = .right, .cells = 1 },
        .{ .direction = .down, .cells = 20 }, .{ .direction = .left, .cells = 8 },
        .{ .direction = .up, .cells = 1 },
    });
    try std.testing.expectEqualStrings("vb5bg_room_0", currentRoomName(&state));
    try std.testing.expectEqualStrings("world_j_point_24", state.field_state.worldEntry(state.package).?.id);
    try walkFromToranDockToCouncil(allocator, &state);
    try walkTo(allocator, &state, null, 480, 200, &.{});
    try interactFacing(&state, .up, &.{0});
    try std.testing.expectEqual(journey.Mode.war, state.mode);
    try std.testing.expectEqualStrings("teo_fire_spear", state.active_war.?.session.engine.scenario.id);
    try finishContinuousCampaign(allocator, &state);
}

test "canonical recruitment hand-in consumes the opal and recruits Esmeralda" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    defer state.deinitActiveModes();
    state.combat.progress.story.scenario.?.castle_tier = 2;
    setScenarioBit(&state, 161, 1);
    state.field_state.enterRoom(state.package.roomIndex("vd1_room_7").?, .{ .x = 336, .y = 144 });
    state.enterEncounterRoom();

    const interact: pause_menu.Input = .{ .field = .{ .action = true, .direction = .up } };
    _ = try state.tickWithFieldEvents(interact, .{});
    const fallback = state.field_event orelse return error.MissingRecruitmentDialogue;
    try std.testing.expectEqualStrings("vd1_room_7_e01_interaction", fallback.session.instance.?.program_id);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(state.field_state.progress.story.scenario.?.recruit_flags[57] & 1 == 0);

    state.shared_items = try state.bindSharedItems(.{ "opal", null, null, null, null, null, null });
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try state.tickWithFieldEvents(interact, .{});
    const owner = state.field_event orelse return error.MissingRecruitmentHandIn;
    try std.testing.expectEqualStrings("vd1_room_7_e00_interaction", owner.session.instance.?.program_id);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(!carriesSharedItem(&state, "opal"));
    try std.testing.expect(state.field_state.progress.story.scenario.?.recruit_flags[57] & 1 != 0);
}

test "canonical scripted dragon flight lands in both Region F destinations" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    defer state.deinitActiveModes();
    setScenarioBit(&state, 207, 16);
    state.field_state.enterRoom(state.package.roomIndex("vf3_room_0").?, .{ .x = 200, .y = 384 });
    state.field_state.setWorldEntry(state.package, "world_f_point_2");
    state.enterEncounterRoom();

    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try finishDragonFlight(&state, "vf2_room_0");
    try std.testing.expectEqualStrings("world_f_point_1", state.field_state.worldEntry(state.package).?.id);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expect(scenarioBitSet(&state, 209, 1 | 16));
    try std.testing.expectEqual(@as(i32, 80), state.field_state.y);

    try walkTo(allocator, &state, "world_f", 152, 112, &.{});
    try finishDragonFlight(&state, "vf3_room_0");
    try std.testing.expectEqualStrings("world_f_point_2", state.field_state.worldEntry(state.package).?.id);
}

test "canonical dragon ride home reaches the dock for each Toran tier" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    for ([_]u8{ 2, 3, 4 }) |tier| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        defer state.deinitActiveModes();
        state.combat.progress.story.scenario.?.castle_tier = tier;
        state.combat.progress.story.recruitment_tier = tier;
        setScenarioBit(&state, 220, 32);
        state.field_state.enterRoom(state.package.roomIndex("vf3_room_0").?, .{ .x = 248, .y = 256 });
        state.field_state.setWorldEntry(state.package, "world_f_point_2");
        state.enterEncounterRoom();

        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
        try std.testing.expectEqualStrings(if (tier == 2) "vb5bg_room_0" else "vb5cg_room_0", currentRoomName(&state));
        try std.testing.expectEqualStrings(if (tier == 2) "world_b_point_24" else "world_b_point_16", state.field_state.worldEntry(state.package).?.id);
    }
}

test "canonical Pannu Yakuta recruits Valeria at the hero's level plus two advances" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    for ([_]bool{ false, true }) |full| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        defer state.deinitActiveModes();
        if (full) for ([_][]const u8{ "pahn", "cleo", "gremio", "viktor", "camille" }) |member| {
            try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, member);
        };
        const expected_level = state.combat.progress.party[0].level + 3; // Valeria starts at level one.
        setScenarioBit(&state, 18, 4);
        state.field_state.enterRoom(state.package.roomIndex("vc4_room_0").?, .{ .x = 248, .y = 464 });
        state.field_state.setWorldEntry(state.package, "world_c_point_3");
        state.enterEncounterRoom();

        _ = try state.tickWithFieldEvents(.{}, .{});
        const owner = state.field_event orelse return error.MissingValeriaRecruitment;
        try std.testing.expectEqualStrings("vc4_room_0_e05_ordinary", owner.session.instance.?.program_id);
        _ = try drainFieldEvent(&state, &.{});
        try std.testing.expectEqualStrings("world_c", currentRoomName(&state));
        try std.testing.expect(state.field_state.progress.story.scenario.?.recruit_flags[36] & 1 != 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, &state.field_state.auxiliary_party.?, 36) != null);
        if (full) {
            for (state.reserves) |entry| {
                const owned = entry orelse continue;
                if (!std.mem.eql(u8, owned.id, "valeria")) continue;
                try std.testing.expectEqual(expected_level, owned.level);
                break;
            } else return error.MissingValeriaReserve;
        } else {
            try expectPartyOrder(&state, &.{ "hero", "valeria" });
            try std.testing.expectEqual(expected_level, state.combat.progress.party[1].level);
        }
    }
}

test "canonical recruitment counts living recruits for Quincy's offer" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    for ([_]bool{ false, true }) |pahn_alive| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        defer state.deinitActiveModes();
        const story = &state.combat.progress.story.scenario.?;
        story.castle_tier = 2;
        @memset(story.recruit_flags[0..81], 1);
        story.recruit_flags[68] = 0;
        if (!pahn_alive) story.recruit_flags[6] = 2;
        state.field_state.enterRoom(state.package.roomIndex("vb4_room_0").?, .{ .x = 184, .y = 152 });
        state.enterEncounterRoom();

        _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
        const owner = state.field_event orelse return error.MissingRecruitmentDialogue;
        try std.testing.expectEqualStrings(if (pahn_alive) "vb4_room_0_e12_interaction" else "vb4_room_0_e13_interaction", owner.session.instance.?.program_id);
        _ = try drainFieldEvent(&state, &.{0});
        try std.testing.expect((state.field_state.progress.story.scenario.?.recruit_flags[68] & 1 != 0) == pahn_alive);
    }
}

test "canonical dragon audience checks whether Liukan is in the party" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    for ([_]bool{ false, true }) |with_liukan| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        defer state.deinitActiveModes();
        if (with_liukan) try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, "liukan");
        setScenarioBit(&state, 207, 8);
        state.field_state.enterRoom(state.package.roomIndex("vf3_room_2").?, .{ .x = 136, .y = 264 });
        state.field_state.setWorldEntry(state.package, "world_f_point_2");
        state.enterEncounterRoom();

        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{0});
        try std.testing.expect(scenarioBitSet(&state, 208, 8) == with_liukan);
        try std.testing.expectEqualStrings(if (with_liukan) "vf1_room_8" else "vf3_room_2", currentRoomName(&state));
    }
}

test "canonical Pahn duel aftermath returns to the right castle tier" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    const cases = [_]struct { tier: u8, result: u8, active: bool, room: []const u8, point: u8 }{
        .{ .tier = 2, .result = 2, .active = false, .room = "vb5b3_room_0", .point = 27 },
        .{ .tier = 3, .result = 2, .active = true, .room = "vb5c3_room_0", .point = 19 },
        .{ .tier = 4, .result = 1, .active = true, .room = "vb5c3_room_0", .point = 19 },
    };
    for (cases) |case| {
        errdefer std.debug.print("Pahn duel aftermath at castle tier {d}, result {d}\n", .{ case.tier, case.result });
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        defer state.deinitActiveModes();
        if (case.active) try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, "pahn");
        state.combat.progress.story.scenario.?.castle_tier = case.tier;
        state.combat.progress.story.recruitment_tier = case.tier;
        setScenarioBit(&state, 33, 128);
        setScenarioBit(&state, 34, case.result);
        state.field_state.enterRoom(state.package.roomIndex("vb7d_room_0").?, .{ .x = 160, .y = 160 });
        state.field_state.setWorldEntry(state.package, "world_b_point_41");
        state.enterEncounterRoom();

        _ = try state.tickWithFieldEvents(.{}, .{});
        const event = state.field_event orelse return error.MissingDuelAftermath;
        const instance = event.session.instance.?;
        try std.testing.expectEqualStrings(if (case.result == 2) "vb7d_room_0_e05_ordinary" else "vb7d_room_0_e03_ordinary", instance.program_id);
        try std.testing.expect(instance.execution.path != null);
        try std.testing.expectEqual(@as(usize, 0), try drainFieldEvent(&state, &.{}));
        try std.testing.expectEqualStrings(case.room, currentRoomName(&state));
        try std.testing.expectEqual(case.point, state.field_state.worldEntry(state.package).?.point);
        try expectPartyOrder(&state, if (case.result == 2) &.{"hero"} else &.{ "hero", "pahn" });
        try std.testing.expect(scenarioBitSet(&state, 34, case.result));
    }
}

test "canonical Pahn duel outcomes return to Toran through ordinary inputs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    for ([_]bool{ false, true }) |prepared| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        defer state.deinitActiveModes();
        try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, "pahn");
        try expectPartyOrder(&state, &.{ "hero", "pahn" });
        if (prepared) while (state.combat.progress.party[1].level < 75) {
            var rolls: [7]u15 = undefined;
            for (&rolls) |*roll| roll.* = state.combat.roll();
            state.combat.levelUp(1, rolls);
        };
        state.combat.progress.story.scenario.?.markCharacterLoaded(6);
        state.combat.progress.story.scenario.?.castle_tier = 2;
        state.combat.progress.story.recruitment_tier = 2;
        setScenarioBit(&state, 194, 1);
        setScenarioBit(&state, 230, 64);
        setScenarioBit(&state, 232, 1);
        state.field_state.enterRoom(state.package.roomIndex("vb7d_room_0").?, .{ .x = 160, .y = 160 });
        state.field_state.setWorldEntry(state.package, "world_b_point_41");
        state.enterEncounterRoom();

        _ = try state.tickWithFieldEvents(.{}, .{});
        try std.testing.expect(state.field_event != null);
        _ = try drainFieldEvent(&state, &.{1});
        try std.testing.expectEqualStrings("pahn_teo", state.active_duel.?.state.duel.id);
        for (0..6000) |_| {
            const active = state.active_duel orelse break;
            _ = try state.tickWithFieldEvents(.{}, .{
                .confirm = active.state.phase == .choosing or active.state.phase == .finished,
            });
        }
        try std.testing.expect(state.active_duel == null and state.scripted_battle == null);
        try std.testing.expect(scenarioBitSet(&state, 33, 128));
        try std.testing.expectEqual(@as(u8, if (prepared) 1 else 2), state.field_state.progress.story.scenario.?.scenario[34] & 3);
        for (0..3) |_| {
            if (std.mem.eql(u8, currentRoomName(&state), "vb5b3_room_0")) break;
            _ = try state.tickWithFieldEvents(.{}, .{});
            _ = try drainFieldEvent(&state, &.{});
        }
        try std.testing.expectEqual(journey.Mode.field, state.mode);
        try std.testing.expectEqualStrings("vb5b3_room_0", currentRoomName(&state));
        try expectPartyOrder(&state, if (prepared) &.{ "hero", "pahn" } else &.{"hero"});

        const flags: u8 = if (prepared) 1 else 0x42;
        try std.testing.expectEqual(flags, state.field_state.progress.story.scenario.?.recruit_flags[6]);
        try std.testing.expectEqual(flags, state.combat.progress.story.scenario.?.recruit_flags[6]);

        var save_dir = std.testing.tmpDir(.{});
        defer save_dir.cleanup();
        try journey.save(io, allocator, save_dir.dir, state);
        var next_harness = try CanonicalHarness.load(allocator, io);
        defer next_harness.deinit();
        var next_members: [6]battle.Member = undefined;
        var next = try next_harness.newState(&next_members);
        defer next.releaseRestoredSave();
        defer next.deinitActiveModes();
        try journey.restore(io, allocator, save_dir.dir, &next);
        try std.testing.expectEqualStrings("vb5b3_room_0", currentRoomName(&next));
        try std.testing.expectEqualDeep(state.combat.progress.story, next.combat.progress.story);
        try expectPartyOrder(&next, if (prepared) &.{ "hero", "pahn" } else &.{"hero"});

        // Emulate the recruited byte retained by an older save after the loss.
        if (!prepared) {
            next.field_state.progress.story.scenario.?.recruit_flags[6] = 1;
            next.combat.progress.story.scenario.?.recruit_flags[6] = 1;
        }
        try walkTo(allocator, &next, null, 464, 160, &.{});
        try interactFacing(&next, .up, &.{});
        _ = try next.tickWithFieldEvents(.{}, .{});
        var view: journey.party_selection.View = .{};
        const roster = try view.read(&next);
        const pahn = for (roster.characters) |candidate| {
            if (std.mem.eql(u8, candidate.id, "pahn")) break candidate;
        } else return error.MissingPahn;
        try std.testing.expectEqual(prepared, pahn.recruited);
        try finishHeadquartersPartySelection(&next, null, null);

        try next.startEnding(allocator);
        try std.testing.expectEqual(flags, next.active_ending.?.recruit_flags[6]);
        try std.testing.expectEqual(@as(u16, if (prepared) 0 else 1), next.active_ending.?.census.lost_alternate);
    }
}

test "canonical smith recruitment earns the four prerequisite recruits" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    defer state.deinitActiveModes();

    // Stage the relevant chapter and room entries with an empty recruit roster.
    state.combat.progress.story.scenario.?.castle_tier = 2;
    setScenarioBit(&state, 200, 1);
    const recruits = [_]struct { room: []const u8, spawn: field.Point, facing: ?field.Direction, recruit: u8 }{
        .{ .room = "vb6_room_10", .spawn = .{ .x = 184, .y = 120 }, .facing = .up, .recruit = 70 },
        .{ .room = "vc2_room_5", .spawn = .{ .x = 232, .y = 168 }, .facing = .down, .recruit = 69 },
        .{ .room = "vg1_room_0", .spawn = .{ .x = 336, .y = 464 }, .facing = null, .recruit = 5 },
        .{ .room = "ve1_room_4", .spawn = .{ .x = 120, .y = 192 }, .facing = .left, .recruit = 72 },
    };
    for (recruits) |step| {
        try std.testing.expectEqual(@as(u8, 0), state.combat.progress.story.scenario.?.recruit_flags[step.recruit] & 3);
        state.field_state.enterRoom(state.package.roomIndex(step.room).?, step.spawn);
        state.enterEncounterRoom();
        if (step.facing) |facing| {
            try interactFacing(&state, facing, &.{0});
        } else {
            _ = try state.tickWithFieldEvents(.{}, .{});
            _ = try drainFieldEvent(&state, &.{});
        }
        try std.testing.expectEqual(@as(u8, 1), state.combat.progress.story.scenario.?.recruit_flags[step.recruit] & 3);
    }
    try expectPartyOrder(&state, &.{ "hero", "maas", "meese", "mose", "ronnie", "moose" });
    try std.testing.expectEqual(state.combat.progress.story.scenario.?.recruit_flags, state.field_state.progress.story.scenario.?.recruit_flags);
}

test "canonical Gremio revival requires 107 living recruits" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    for ([_]bool{ false, true }) |pahn_survived| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        defer state.deinitActiveModes();
        const story = &state.combat.progress.story.scenario.?;
        // This fixture isolates the revival scene at the roster threshold.
        story.castle_tier = 4;
        story.recruit_flags = @splat(1);
        story.recruit_flags[2] = 2;
        story.recruit_flags[6] = if (pahn_survived) 1 else 0x42;
        story.scenario[34] = if (pahn_survived) 1 else 2;
        setScenarioBit(&state, 32, 16);
        try std.testing.expectEqual(@as(u8, if (pahn_survived) 107 else 106), story.recruitCount());
        state.field_state.enterRoom(state.package.roomIndex("vb5c4_room_8").?, .{ .x = 472, .y = 80 });
        state.enterEncounterRoom();

        _ = try state.tickWithFieldEvents(.{}, .{});
        const owner = state.field_event orelse return error.MissingRevivalScene;
        try std.testing.expectEqualStrings(if (pahn_survived) "vb5c4_room_8_e07_ordinary" else "vb5c4_room_8_e08_ordinary", owner.session.instance.?.program_id);
        _ = try drainFieldEvent(&state, &.{});
        try std.testing.expectEqualStrings("vb5cc_room_3", currentRoomName(&state));
        try std.testing.expect(scenarioBitSet(&state, 32, 32));
        const result = state.combat.progress.story.scenario.?;
        try std.testing.expectEqual(@as(u8, if (pahn_survived) 1 else 2), result.recruit_flags[2]);
        try std.testing.expectEqual(@as(u8, if (pahn_survived) 1 else 0x42), result.recruit_flags[6]);
        try std.testing.expectEqual(@as(u8, if (pahn_survived) 108 else 106), result.recruitCount());
        try std.testing.expectEqual(result.recruit_flags, state.field_state.progress.story.scenario.?.recruit_flags);
    }
}

test "canonical final field event runs the ending with partial and full rosters" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    for ([_]bool{ false, true }) |full_roster| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        defer state.deinitActiveModes();
        state.combat.progress.story.scenario.?.recruit_flags = @splat(if (full_roster) 1 else 0);
        setScenarioBit(&state, 26, 8);
        state.field_state.enterRoom(state.package.roomIndex("vac_room_15").?, .{ .x = 120, .y = 104 });
        state.enterEncounterRoom();

        _ = try state.tickWithFieldEvents(.{}, .{});
        try std.testing.expect(state.field_event != null);
        _ = try drainFieldEvent(&state, &.{});
        try std.testing.expectEqual(journey.Mode.ending, state.mode);
        try std.testing.expectEqualStrings("ending:main", state.scripted_battle.?.request.id);
        const ending = state.active_ending.?;
        try std.testing.expectEqual(@as(u16, if (full_roster) 108 else 1), ending.census.recruited);
        try std.testing.expectEqual(@as(u16, if (full_roster) 0 else 107), ending.census.absent);
        const confirms = ending.parsed.value.bounded_ending.main_ending_phases + 1;
        for (0..confirms) |_| _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });

        try std.testing.expectEqual(journey.Mode.field, state.mode);
        try std.testing.expect(state.active_ending == null);
        try std.testing.expect(state.scripted_battle == null);
        _ = try drainFieldEvent(&state, &.{});
        try std.testing.expect(state.field_event == null);
    }
}

test "canonical Soniere warehouse keeps equipped and capped items with Gremio" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, "gremio");
    try std.testing.expect(try state.combat.progress.party[1].inventory.receive(.needle));
    state.combat.progress.storage.counts.needle = field.game_state.storage.capacity;
    state.combat.progress.story.scenario.?.recruit_flags[2] = 1;
    state.combat.progress.story.scenario.?.soul_eater_spell_slots = 2;
    setScenarioBit(&state, 196, 1 | 2 | 8);
    state.field_state.enterRoom(state.package.roomIndex("vd5_room_1").?, .{ .x = 72, .y = 408 });
    state.enterEncounterRoom();

    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expect(state.field_event != null);
    _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("vb5b4_room_3", currentRoomName(&state));
    try std.testing.expectEqual(1, state.combat.progress.storage.quantity(.medicine));
    try std.testing.expectEqual(field.game_state.storage.capacity, state.combat.progress.storage.quantity(.needle));
    const gremio = for (state.reserves) |entry| {
        const member = entry orelse continue;
        if (std.mem.eql(u8, member.id, "gremio")) break member;
    } else return error.MissingGremioReserve;
    const bag = gremio.inventory;
    try std.testing.expectEqual(3, bag.count());
    try std.testing.expectEqual(.leather_coat, bag.slots[0].?.id);
    try std.testing.expectEqual(.cape, bag.slots[1].?.id);
    try std.testing.expectEqual(.needle, bag.slots[2].?.id);
}

test "canonical harbor briefing resumes an older save before departing for Rikon" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    state.field_state.enterRoom(state.package.roomIndex("vb4_room_0").?, .{ .x = 400, .y = 144 });
    state.enterEncounterRoom();
    setScenarioBit(&state, 198, 1 | 4 | 8);
    const legacy = try journey.Snapshot.capture(state);
    try legacy.apply(&state);

    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expect(state.field_event != null);
    _ = try drainFieldEvent(&state, &.{});
    try expectPartyOrder(&state, &.{ "hero", "viktor", "flik", "gremio" });
    try std.testing.expect(scenarioBitSet(&state, 198, 1 | 2 | 4 | 8));
}

test "canonical Region C entrance selects the later village after the story changes" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    setScenarioBit(&state, 17, 1);
    state.field_state.enterRoom(state.package.roomIndex("world_c").?, .{ .x = 624, .y = 544 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    try stepToCoord(&state, .up);
    try std.testing.expectEqualStrings("vc5_room_0", currentRoomName(&state));
    try std.testing.expectEqualStrings("world_c_point_4", state.field_state.worldEntry(state.package).?.id);
}

test "canonical Kirkis recruitment makes room in a full party" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    for ([_][]const u8{ "gremio", "cleo", "viktor", "pahn", "luc" }) |id| {
        try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, id);
    }
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor", "pahn", "luc" });
    const luc = state.combat.ownedMember(5);
    setScenarioBit(&state, 15, 4);
    state.field_state.enterRoom(state.package.roomIndex("vb5a2_room_0").?, .{ .x = 128, .y = 272 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqualStrings("vb5a2_room_0_e19_ordinary", state.field_event.?.session.instance.?.program_id);
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expect(state.party_selection != null);

    var tried_hero = false;
    var refused = false;
    for (0..300) |_| {
        const active = state.party_selection orelse break;
        const controls: journey.party_selection.selector.Controls = switch (active.menu.phase) {
            .list => if (!tried_hero) protected: {
                tried_hero = true;
                break :protected .{ .confirm = true };
            } else if (active.menu.cursor < 5) .{ .down = true } else .{ .confirm = true },
            .confirmation => if (!refused) decline: {
                refused = true;
                break :decline .{ .cancel = true };
            } else .{ .confirm = true },
            else => .{},
        };
        try state.tickPartySelection(controls);
    }
    try std.testing.expect(state.party_selection == null and refused);
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor", "pahn" });
    _ = try drainFieldEvent(&state, &.{});
    try expectPartyOrder(&state, &.{ "hero", "gremio", "cleo", "viktor", "pahn", "kirkis" });
    try std.testing.expect(scenarioBitSet(&state, 15, 4 | 8));
    for (state.reserves) |entry| {
        const owned = entry orelse continue;
        if (std.mem.eql(u8, owned.id, "luc")) {
            try std.testing.expectEqualDeep(luc, owned);
            break;
        }
    } else return error.MissingSelectorReserve;
}

test "canonical M01-M03 route to VB6 Great Forest, spell barrier, and Kobold Village exit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);

    // Traverse from world_a to Kwaba Fortress (va6_room_1 -> va6_room_0).
    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vaa_room_1", .x = 448, .y = 208 },
        .{ .want = "vaa_room_0", .x = 256, .y = 832 },
        .{ .want = "vaa_room_10", .x = 296, .y = 744 },
        .{ .want = "va1_room_0", .x = 144, .y = 232 },
        .{ .want = "world_a", .x = 720, .y = 872 },
    }, .injected);
    try walkThroughEncounters(allocator, &state, "va6_room_1", 480, 888, &.{}, .injected);
    try walkTo(allocator, &state, "va6_room_0", 184, 232, &.{});

    // Gatekeeper blocks south crossing before Ain Gide grants passage (scenario[10]&8).
    try walkTo(allocator, &state, null, 248, 152, &.{});
    try std.testing.expectEqualStrings("va6_room_0", currentRoomName(&state));
    try std.testing.expectEqual(@as(i32, 136), state.field_state.y);

    // Re-enter va6_room_1 with storyline entry bit (scenario[10]|=4) -> Ain Gide grants pass -> cross into world_b.
    setScenarioBit(&state, 10, 4);
    try walkTo(allocator, &state, "va6_room_1", 248, 48, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try std.testing.expect(scenarioBitSet(&state, 10, 8));

    try walkTo(allocator, &state, "va6_room_0", 184, 232, &.{});
    try walkTo(allocator, &state, "va6_room_2", 248, 152, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 10, 16));

    try walkTo(allocator, &state, "world_b", 24, 232, &.{});
    try std.testing.expectEqualStrings("world_b", currentRoomName(&state));

    // Walk across Region B into Great Forest Village (vb6_room_0 -> vb6_room_1).
    try walkThroughEncounters(allocator, &state, "vb6_room_0", 768, 728, &.{}, .injected);
    try walkTo(allocator, &state, "vb6_room_1", 488, 56, &.{});

    // Without Kirkis/Sylvina/Stallion/Ruby, stepping onto x=480 in vb6_room_1 warps Hero back to (24, 240).
    try walkThroughEncounters(allocator, &state, null, 472, 240, &.{}, .injected);
    if (state.mode == .battle) try finishBattleWith(&state, .victory);
    try stepToCoord(&state, .right);
    try std.testing.expectEqualStrings("vb6_room_1", currentRoomName(&state));
    try std.testing.expectEqual(@as(i32, 24), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 240), state.field_state.y);

    // With Kirkis joined (character index 4), pass x=480 through vb6_room_1..5 to Kobold Village (vb6_room_6).
    try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, "kirkis");

    try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
        .{ .want = "vb6_room_2", .x = 488, .y = 208 },
        .{ .want = "vb6_room_3", .x = 360, .y = 32 },
        .{ .want = "vb6_room_2", .x = 8, .y = 144 },
        .{ .want = "vb6_room_3", .x = 360, .y = 272 },
        .{ .want = "vb6_room_4", .x = 360, .y = 280 },
        .{ .want = "vb6_room_5", .x = 368, .y = 272 },
        .{ .want = "vb6_room_6", .x = 360, .y = 80 },
    }, .injected);
    try std.testing.expectEqualStrings("vb6_room_6", currentRoomName(&state));
}

fn enterVb6ForTest(state: *journey.State, members: *[6]battle.Member) !void {
    setScenarioBit(state, 10, 4 | 8 | 16);
    try state.joinPartyMember(members, state.party_catalog.?, state.party_bindings, "kirkis");
    const target_room = state.package.roomIndex("vb6_room_0").?;
    state.field_state.enterRoom(target_room, .{ .x = 264, .y = 344 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
}

test "canonical B01 B02 B04 VB6 and B20 live encounters, suppression, battlefield selection, and save round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();

    // Static checks for B02 + B04 VB6 metadata before driving movement.
    const configured = harness.bundle.data.field_encounters orelse return error.MissingFieldEncounters;
    try std.testing.expect(configured.clear_suppression_on_world_entry);
    const vb6_bf = harness.bundle.combat.battlefield("vb6_ord") orelse return error.MissingVb6Battlefield;
    try std.testing.expectEqual(@as(u8, 16), vb6_bf.ground.across);
    try std.testing.expectEqual(@as(u8, 16), vb6_bf.ground.down);
    try std.testing.expectEqual(@as(usize, 0), vb6_bf.scenery.len);
    const expected_vb6_ids = [_][]const u8{
        "vb6_ord_1", "vb6_ord_2", "vb6_ord_3", "vb6_ord_4",
        "vb6_ord_5", "vb6_ord_6", "vb6_ord_7", "vb6_ord_8",
    };
    for ([_][]const u8{ "vb6_room_1", "vb6_room_2", "vb6_room_3", "vb6_room_4", "vb6_room_5" }) |rid| {
        const entry = configured.forRoom(rid) orelse return error.MissingVb6RoomEncounters;
        try std.testing.expectEqual(@as(u8, 2), entry.rate);
        try std.testing.expectEqual(@as(u8, 60), entry.counter_threshold);
        try std.testing.expectEqual(expected_vb6_ids.len, entry.candidates.len);
        for (entry.candidates, expected_vb6_ids) |cand, want_id| {
            try std.testing.expectEqualStrings(want_id, cand.id);
        }
    }
    for (expected_vb6_ids) |enc_id| {
        const enc = for (harness.bundle.combat.encounters) |entry| {
            if (std.mem.eql(u8, entry.id, enc_id)) break entry;
        } else return error.UnknownEncounter;
        try std.testing.expectEqualStrings("vb6_ord", enc.battlefield orelse return error.MissingBattlefield);
    }

    // B01: Story suppression sampled at room load; mid-room clear remains suppressed until next room load; world exit clears bit.
    {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        try enterVb6ForTest(&state, &members);

        setScenarioBit(&state, 43, 64);
        try walkTo(allocator, &state, "vb6_room_1", 488, 56, &.{});
        try std.testing.expect(!state.field_encounter_clock.enabled);
        for (0..80) |i| {
            try stepToCoord(&state, if ((i & 1) == 0) .right else .left);
            try std.testing.expectEqual(journey.Mode.field, state.mode);
        }

        // Clear suppression bit mid-room: enabled must stay false inside vb6_room_1.
        var story = state.field_state.progress.story.scenario.?;
        story.scenario[43] &= ~@as(u8, 64);
        state.field_state.progress.story.scenario = story;
        state.combat.progress.story.scenario = story;
        for (0..80) |i| {
            try stepToCoord(&state, if ((i & 1) == 0) .right else .left);
            try std.testing.expect(!state.field_encounter_clock.enabled);
            try std.testing.expectEqual(journey.Mode.field, state.mode);
        }

        // Transition into vb6_room_2 samples clear bit -> encounters re-enable and fire normally.
        try walkTo(allocator, &state, "vb6_room_2", 488, 208, &.{});
        try std.testing.expect(state.field_encounter_clock.enabled);
        var ticks: usize = 0;
        while (state.mode == .field and ticks < 512) : (ticks += 1) {
            try stepToCoord(&state, if ((ticks & 1) == 0) .right else .left);
        }
        try std.testing.expectEqual(journey.Mode.battle, state.mode);
        try finishBattleWith(&state, .victory);

        // Exiting vb6_room_0 to world_b via e01 clears scenario[43]&64 and sets scenario[39]&16.
        setScenarioBit(&state, 43, 64);
        try finishFieldOrEncountersUntilRoom(allocator, &state, &.{
            .{ .want = "vb6_room_1", .x = 8, .y = 288 },
            .{ .want = "vb6_room_0", .x = 8, .y = 240 },
        }, .injected);
        try walkTo(allocator, &state, "world_b", 264, 360, &.{});
        try std.testing.expect(!scenarioBitSet(&state, 43, 64));
        try std.testing.expect(scenarioBitSet(&state, 39, 16));
    }

    // Trigger encounters across all five rooms and verify all eight formations.
    {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        try enterVb6ForTest(&state, &members);

        var seen_mask: u8 = 0;
        const room_hops = [_]struct { want: []const u8, x: i32, y: i32 }{
            .{ .want = "vb6_room_1", .x = 488, .y = 56 },
            .{ .want = "vb6_room_2", .x = 488, .y = 208 },
            .{ .want = "vb6_room_3", .x = 360, .y = 320 },
            .{ .want = "vb6_room_4", .x = 360, .y = 280 },
            .{ .want = "vb6_room_5", .x = 368, .y = 272 },
        };
        for (room_hops, 0..) |hop, room_idx| {
            if (room_idx == 2) {
                // vb6_room_2 spawns NE at (24,288) -> reach vb6_room_3 SW clearing via (360,32)->(8,144)->(360,272).
                try walkThroughEncounters(allocator, &state, "vb6_room_3", 360, 32, &.{}, .injected);
                try walkThroughEncounters(allocator, &state, "vb6_room_2", 8, 144, &.{}, .injected);
                try walkThroughEncounters(allocator, &state, "vb6_room_3", 360, 272, &.{}, .injected);
            } else {
                try walkThroughEncounters(allocator, &state, hop.want, hop.x, hop.y, &.{}, .injected);
            }
            try std.testing.expectEqualStrings(hop.want, currentRoomName(&state));
            var steps: usize = 0;
            while (state.mode == .field and steps < 512) : (steps += 1) {
                try stepToCoord(&state, if ((steps & 1) == 0) .right else .left);
            }
            try std.testing.expectEqual(journey.Mode.battle, state.mode);
            const enc = state.combat.content.encounters[state.combat.encounter];
            try std.testing.expect(std.mem.startsWith(u8, enc.id, "vb6_ord_"));
            try std.testing.expectEqualStrings("vb6_ord", enc.battlefield orelse return error.MissingBattlefield);
            for (expected_vb6_ids, 0..) |want_id, bi| {
                if (std.mem.eql(u8, enc.id, want_id)) seen_mask |= @as(u8, 1) << @intCast(bi);
            }
            try finishBattleWith(&state, .victory);
        }

        // Continue fighting in vb6_room_5 until all 8 vb6_ord_1..8 formations have occurred via movement.
        var round: usize = 0;
        while (seen_mask != 0xFF and round < 200) : (round += 1) {
            var steps: usize = 0;
            while (state.mode == .field and steps < 512) : (steps += 1) {
                try stepToCoord(&state, if ((steps & 1) == 0) .right else .left);
            }
            try std.testing.expectEqual(journey.Mode.battle, state.mode);
            const enc = state.combat.content.encounters[state.combat.encounter];
            try std.testing.expectEqualStrings("vb6_ord", enc.battlefield orelse return error.MissingBattlefield);
            for (expected_vb6_ids, 0..) |want_id, bi| {
                if (std.mem.eql(u8, enc.id, want_id)) seen_mask |= @as(u8, 1) << @intCast(bi);
            }
            try finishBattleWith(&state, .victory);
        }
        try std.testing.expectEqual(@as(u8, 0xFF), seen_mask);

        // Verify the field return position on escape from room 3.
        try walkTo(allocator, &state, "vb6_room_4", 8, 192, &.{});
        try walkTo(allocator, &state, "vb6_room_3", 8, 288, &.{});
        var patrol_steps: usize = 0;
        while (state.mode == .field and patrol_steps < 512) : (patrol_steps += 1) {
            try stepToCoord(&state, if (state.field_state.x >= 352) .left else .right);
        }
        try std.testing.expectEqual(journey.Mode.battle, state.mode);
        const battle_x = state.field_state.x;
        const battle_y = state.field_state.y;
        try std.testing.expect(state.combat.canEscape());
        try finishBattleWith(&state, .escaped);
        try std.testing.expectEqual(journey.Mode.field, state.mode);
        try std.testing.expectEqualStrings("vb6_room_3", currentRoomName(&state));
        try std.testing.expectEqual(battle_x, state.field_state.x);
        try std.testing.expectEqual(battle_y, state.field_state.y);
    }

    // Verify a real victory with the supplied episode roster before saving.
    {
        var members: [6]battle.Member = undefined;
        var boot: journey_boot.Boot = .{
            .allocator = allocator,
            .path = @constCast(""),
            .save_path = null,
            .bundle = harness.bundle,
            .party = harness.party,
            .members = &members,
            .combat = try harness.bundle.arena.allocator().create(battle.State),
            .state = undefined,
        };
        var state = try boot.newState();
        const room = state.package.roomIndex("vb6_room_3").?;
        state.field_state.enterRoom(room, .{ .x = 24, .y = 288 });
        state.enterEncounterRoom();
        try state.initializeRoomVisit();
        for (0..512) |step| {
            if (state.mode != .field) break;
            try stepToCoord(&state, if (step % 2 == 0) .right else .left);
        }
        try std.testing.expectEqual(.battle, state.mode);
        try std.testing.expect(std.mem.startsWith(u8, state.combat.content.encounters[state.combat.encounter].id, "vb6_ord_"));
        const x = state.field_state.x;
        const y = state.field_state.y;
        const money = state.combat.progress.money;
        try finishBattleWithInput(&state, .forest);
        try std.testing.expect(state.combat.rewards_committed);
        try std.testing.expect(state.combat.progress.money > money);
        try std.testing.expectEqual(money + state.combat.reward_received, state.combat.progress.money);
        var earned_experience = false;
        for (state.combat.award_exp) |award| earned_experience = earned_experience or award > 0;
        try std.testing.expect(earned_experience);
        try std.testing.expectEqual(room, state.field_state.room);
        try std.testing.expectEqual(x, state.field_state.x);
        try std.testing.expectEqual(y, state.field_state.y);
        try journey.save(io, allocator, temp.dir, state);

        var reloaded_harness = try CanonicalHarness.load(allocator, io);
        defer reloaded_harness.deinit();
        var reload_members: [6]battle.Member = undefined;
        var reloaded = try reloaded_harness.newState(&reload_members);
        defer reloaded.releaseRestoredSave();
        try journey.restore(io, allocator, temp.dir, &reloaded);
        reloaded.bind();
        try std.testing.expectEqualStrings("vb6_room_3", currentRoomName(&reloaded));
        try std.testing.expectEqual(x, reloaded.field_state.x);
        try std.testing.expectEqual(y, reloaded.field_state.y);
        try std.testing.expectEqualDeep(state.combat.progress.story, reloaded.combat.progress.story);
        try std.testing.expectEqualDeep(state.combat.random, reloaded.combat.random);
        try std.testing.expectEqual(state.combat.progress.money, reloaded.combat.progress.money);
        try std.testing.expectEqual(state.combat.partyCount(), reloaded.combat.partyCount());
        for (0..state.combat.partyCount()) |member| {
            try std.testing.expectEqualDeep(state.combat.ownedMember(member), reloaded.combat.ownedMember(member));
        }
        try std.testing.expect(reloaded.field_encounter_clock.enabled);

        var post_load_steps: usize = 0;
        while (reloaded.mode == .field and post_load_steps < 512) : (post_load_steps += 1) {
            try stepToCoord(&reloaded, if (post_load_steps % 2 == 0) .right else .left);
        }
        try std.testing.expectEqual(journey.Mode.battle, reloaded.mode);
        try std.testing.expect(std.mem.startsWith(u8, reloaded.combat.content.encounters[reloaded.combat.encounter].id, "vb6_ord_"));
    }
}

fn interactService(state: *journey.State, facing: field.Direction) !void {
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = facing } }, .{});
    if (state.field_event != null) _ = try drainFieldEvent(state, &.{});
}

fn buyStockItem(state: *journey.State, item: field.items.Id, member: usize) !void {
    try std.testing.expectEqual(.shop, state.menu.phase);
    const rules = state.field_state.item_rules.?;
    const stock_index = std.mem.indexOfScalar(field.items.Id, state.menu.shopStock(rules), item) orelse return error.MissingShopItem;
    const price = rules.offerGood(item).?.price;
    const money = state.combat.progress.money;
    try std.testing.expect(money >= price);
    const confirm: pause_menu.Input = .{ .field = .{ .action = true } };
    _ = try state.tickWithFieldEvents(confirm, .{});
    while (state.menu.member != member) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    while (state.menu.stock_slot != stock_index) _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(confirm, .{});
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    _ = try state.tickWithFieldEvents(confirm, .{});
    try std.testing.expectEqual(money - price, state.combat.progress.money);
    _ = try state.tickWithFieldEvents(confirm, .{});
    try std.testing.expectEqual(.shop, state.menu.phase);
}

test "canonical Chapter 1 Gregminster shops rune appraisal and optional Sarady crystal detour" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    state.combat.progress.money = 20000;

    // Enter va1_room_0 from vaa_room_10, then visit Gregminster Item & Armor Shops (va1_room_6).
    state.field_state.enterRoom(state.package.roomIndex("va1_room_0").?, .{ .x = 1088, .y = 608 });
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("va1_room_6", currentRoomName(&state));

    // Armor shop counter at (408, 136): open shop -> [bandanna..wing_boots], buy wing_boots (index 6) and leather_coat (index 4).
    try walkTo(allocator, &state, null, 408, 152, &.{});
    try interactService(&state, .up);
    try std.testing.expectEqual(pause_menu.Phase.shop, state.menu.phase);
    const rules = state.field_state.item_rules.?;
    try std.testing.expectEqual(@as(usize, 7), state.menu.shopStock(rules).len);
    try std.testing.expectEqual(field.items.Id.wing_boots, state.menu.shopStock(rules)[6]);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.buy_member, state.menu.phase);
    for (0..6) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.confirm_buy, state.menu.phase);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .up } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.shop_notice, state.menu.phase);
    try std.testing.expectEqual(@as(u32, 9800), state.combat.progress.money);
    try std.testing.expectEqual(field.items.Id.wing_boots, members[0].inventory.slots[members[0].inventory.count() - 1].?.id);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.closed, state.menu.phase);

    // Item shop counter at (88, 136): [medicine, antitoxin]. Buy antitoxin (index 1 -> 200 bits).
    try walkTo(allocator, &state, null, 88, 152, &.{});
    try interactService(&state, .up);
    try std.testing.expectEqual(pause_menu.Phase.shop, state.menu.phase);
    try std.testing.expectEqual(@as(usize, 2), state.menu.shopStock(rules).len);
    try std.testing.expectEqual(field.items.Id.antitoxin, state.menu.shopStock(rules)[1]);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .up } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(@as(u32, 9600), state.combat.progress.money);
    try std.testing.expectEqual(field.items.Id.antitoxin, members[0].inventory.slots[members[0].inventory.count() - 1].?.id);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.closed, state.menu.phase);

    // Rune Shop (va1_room_8) counter at (184, 104).
    state.field_state.enterRoom(state.package.roomIndex("va1_room_8").?, .{ .x = 184, .y = 120 });
    try interactService(&state, .up);
    try std.testing.expectEqual(pause_menu.Phase.rune_service, state.menu.phase);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.closed, state.menu.phase);

    // Appraisal Shop (va1_room_11) counter at (120, 104).
    const urn_slot = members[0].inventory.count();
    members[0].inventory.slots[urn_slot] = .{ .id = .octopus_urn, .uses = 0, .identified = false };
    state.field_state.enterRoom(state.package.roomIndex("va1_room_11").?, .{ .x = 120, .y = 120 });
    try interactService(&state, .up);
    try std.testing.expectEqual(pause_menu.Phase.appraisal, state.menu.phase);
    for (0..urn_slot) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.confirm_appraisal, state.menu.phase);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .up } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.appraisal_notice, state.menu.phase);
    try std.testing.expect(state.combat.progress.party[0].inventory.slots[urn_slot].?.identified);
    try std.testing.expectEqual(@as(u32, 9100), state.combat.progress.money);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.closed, state.menu.phase);

    // Chapter 1 optional Sarady trip: va5_room_0 -> va5_room_2 (Water crystal shop) & va5_room_3 (Fortune crystal).
    state.field_state.enterRoom(state.package.roomIndex("va5_room_0").?, .{ .x = 128, .y = 184 });
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    try walkTo(allocator, &state, null, 128, 184, &.{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("va5_room_2", currentRoomName(&state));
    try walkTo(allocator, &state, null, 112, 120, &.{});
    try interactService(&state, .up);
    try std.testing.expectEqual(pause_menu.Phase.shop, state.menu.phase);
    try std.testing.expectEqual(@as(usize, 2), state.menu.shopStock(rules).len);
    try std.testing.expectEqual(field.items.Id.water_crystal, state.menu.shopStock(rules)[1]);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .up } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    try std.testing.expectEqual(@as(u32, 2100), state.combat.progress.money);
    try std.testing.expectEqual(field.items.Id.water_crystal, members[0].inventory.slots[members[0].inventory.count() - 1].?.id);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try std.testing.expectEqual(pause_menu.Phase.closed, state.menu.phase);

    // Leave shop back to va5_room_0, enter va5_room_3 back room, claim Fortune crystal cleanly.
    state.field_state.enterRoom(state.package.roomIndex("va5_room_0").?, .{ .x = 416, .y = 144 });
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
    if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    try std.testing.expectEqualStrings("va5_room_3", currentRoomName(&state));
    // Verify scenario[0]&128 clear -> Fortune crystal when space exists, refused without setting flag when full.
    var scenario = state.combat.progress.story.scenario.?;
    scenario.scenario[0] &= ~@as(u8, 128);
    scenario.scenario[47] &= ~@as(u8, 32);
    state.combat.progress.story.scenario = scenario;
    state.field_state.progress.story.scenario = scenario;
    const fill_start = @min(members[0].inventory.count(), 8);
    for (fill_start..9) |slot| members[0].inventory.slots[slot] = .{ .id = .medicine, .uses = 6 };
    try walkTo(allocator, &state, null, 192, 112, &.{});
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(!scenarioBitSet(&state, 47, 32));
    for (fill_start..9) |slot| members[0].inventory.slots[slot] = null;
    try interactFacing(&state, .up, &.{});
    try std.testing.expect(scenarioBitSet(&state, 47, 32));
    try std.testing.expectEqual(field.items.Id.fortune_crystal, members[0].inventory.slots[fill_start].?.id);
}

test "placed props start canonical interactions without character actors" {
    var harness = try CanonicalHarness.load(std.testing.allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const room_index = state.package.roomIndex("va1_room_3").?;
    try std.testing.expect(state.package.rooms[room_index].canStand(192, 256));
    state.field_state.enterRoom(room_index, .{ .x = 192, .y = 256 });
    state.field_state.facing = .up;
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    const owner = state.field_event orelse return error.MissingPropInteraction;
    try std.testing.expectEqualStrings("va1_room_3_e04_interaction", owner.session.instance.?.program_id);
    try std.testing.expectEqual(.event, owner.binding.population.entities[4].record_role);
    try std.testing.expect(owner.binding.population.entities[4].source_character_id == null);
    _ = try drainFieldEvent(&state, &.{1});
    try std.testing.expect(state.field_event == null);
}

test "interaction position follows the live actor for own and inherited records" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const binding = state.room_battles.?.bindingFor("vb1_room_0").?;
    const packet = binding.ordinary.?;
    const index = for (packet.actors, 0..) |actor, i| {
        if (actor.entity == 12) break i;
    } else return error.MissingInteractionActor;
    try binding.validateContext();
    var actors = (try binding.constructRoomActors(state.field_state.progress.story.scenario.?)).?;
    const avatar = &actors.slots[index].?.avatar.?;
    avatar.motion.x += 16;
    const point = binding.interactionPosition(12, &actors).?;
    try std.testing.expectEqual(avatar.motion.x, point.x);
    try std.testing.expectEqual(avatar.motion.y, point.y);
    try std.testing.expectEqual(point, binding.interactionPosition(13, &actors).?);
    try std.testing.expect(binding.interactionPosition(13, null) == null);
    const settled = try actors.settle(packet, binding.animations);
    const room_index = state.package.roomIndex(binding.room).?;
    const room = state.package.rooms[room_index];
    const floor = std.mem.indexOfScalar(u8, room.walkable, '1').?;
    const columns: usize = @intCast(@divExact(room.width, 8));
    state.field_state.enterRoom(room_index, .{ .x = @intCast(floor % columns * 8), .y = @intCast(floor / columns * 8) });
    state.room_battles.?.settled_actors = .{ .room = binding.room, .visit = state.field_state.room_entries, .state = settled };
    const saved = try journey.Snapshot.capture(state);
    try std.testing.expect(saved.room_actors != null);
    var fresh_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&fresh_members);
    {
        const bytes = try std.json.Stringify.valueAlloc(allocator, saved, .{});
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(journey.Snapshot, allocator, bytes, .{});
        defer parsed.deinit();
        try parsed.value.apply(&restored);
    }
    const retained = (try restored.room_battles.?.constructActorsForVisit(binding, actors.construction_story, restored.field_state.room_entries)).?;
    try std.testing.expectEqual(point, binding.interactionPosition(13, &retained).?);
    try std.testing.expect(retained.slots[index].?.avatar.?.id.ptr == packet.actors[index].id.ptr);
    var released = retained;
    try released.release(packet, packet.actors[index].id);
    var released_save = saved;
    released_save.room_actors = try released.settle(packet, binding.animations);
    try released_save.apply(&restored);
    const released_construction = (try restored.room_battles.?.constructActorsForVisit(binding, actors.construction_story, restored.field_state.room_entries)).?;
    try std.testing.expectEqual(.released, released_construction.slots[index].?.phase);
    try std.testing.expect(binding.interactionPosition(13, &released_construction) == null);
    var invalid = saved;
    invalid.room_actors.?.settled_positions.?[index].?.x += 8;
    try std.testing.expectError(error.InvalidFieldActorState, invalid.validate(restored));
    invalid = saved;
    invalid.schema = "suikoden-journey-save/40";
    try std.testing.expectError(error.InvalidSave, invalid.validate(restored));
    invalid.room_actors = null;
    try invalid.apply(&restored);
    try std.testing.expect(restored.room_battles.?.settled_actors == null);

    actors.slots[index].?.phase = .released;
    try std.testing.expect(binding.interactionPosition(12, &actors) == null);
    try std.testing.expect(binding.interactionPosition(13, &actors) == null);
    var other_story = actors.construction_story;
    other_story.scenario[10] |= 32;
    const fallback = (try binding.constructRoomActors(other_story)).?;
    try std.testing.expect(binding.interactionPosition(13, &fallback) == null);
    state.field_state.enterRoom(state.package.roomIndex("vb1_room_5").?, .{ .x = 192, .y = 72 });
    state.field_state.facing = .up;
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    for (0..8) |_| {
        if (state.field_event != null and state.field_event.?.session.boxes[0].anchor != null) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    const interaction = state.field_event orelse return error.MissingInheritedInteraction;
    try std.testing.expectEqualStrings("vb1_room_5_e05_interaction", interaction.session.instance.?.program_id);
    try std.testing.expectEqual(.not_applicable, interaction.binding.population.entities[5].position.placement);
    const child = interaction.binding.interactionPosition(5, &interaction.session.ordinary_actors.?).?;
    try std.testing.expectEqual(child.x + 8, interaction.session.boxes[0].anchor.?.x);
    try std.testing.expectEqual(child.y - 24, interaction.session.boxes[0].anchor.?.y);
}

test "source actor initializers place residents on entry and preserve positions through reload" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const binding = state.room_battles.?.bindingFor("va3_room_1").?;
    const packet = binding.ordinary.?;
    const index = for (packet.actors, 0..) |actor, i| {
        if (actor.entity == 4) break i;
    } else return error.MissingInteractionActor;
    try std.testing.expectEqual(@as(i32, 2032), packet.actors[index].x);
    const room_index = state.package.roomIndex(binding.room).?;
    const room = state.package.rooms[room_index];
    const floor = std.mem.indexOfScalar(u8, room.walkable, '1').?;
    const columns: usize = @intCast(@divExact(room.width, 8));
    const spawn: field.Point = .{ .x = @intCast(floor % columns * 8), .y = @intCast(floor / columns * 8) };
    state.field_state.enterRoom(room_index, spawn);
    try state.initializeRoomVisit();
    const inactive = (try state.room_battles.?.constructActorsForVisit(binding, state.field_state.progress.story.scenario.?, state.field_state.room_entries)).?;
    // Initializer22 runs while scenario6 bit128 is clear, before the later setup.
    try std.testing.expectEqual(@as(i32, 296), inactive.slots[index].?.avatar.?.motion.x);
    try std.testing.expectEqual(@as(i32, 112), inactive.slots[index].?.avatar.?.motion.y);
    // A new visit runs the source predicate and one complete placement pump.
    setScenarioBit(&state, 7, 1);
    state.field_state.enterRoom(room_index, spawn);
    try state.initializeRoomVisit();
    const actors = (try state.room_battles.?.constructActorsForVisit(binding, state.field_state.progress.story.scenario.?, state.field_state.room_entries)).?;
    const position = binding.interactionPosition(6, &actors).?;
    try std.testing.expectEqual(field.Point{ .x = 136, .y = 288 }, position);
    try std.testing.expectEqual(@as(u2, 2), actors.slots[index].?.avatar.?.variant);
    const saved = try journey.Snapshot.capture(state);
    try std.testing.expect(saved.room_actors != null);
    var fresh_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&fresh_members);
    {
        const bytes = try std.json.Stringify.valueAlloc(allocator, saved, .{});
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(journey.Snapshot, allocator, bytes, .{});
        defer parsed.deinit();
        try parsed.value.apply(&restored);
    }
    setScenarioBit(&restored, 8, 1);
    try restored.initializeRoomVisit();
    const retained = (try restored.room_battles.?.constructActorsForVisit(binding, restored.field_state.progress.story.scenario.?, restored.field_state.room_entries)).?;
    try std.testing.expectEqual(position, binding.interactionPosition(6, &retained).?);
    var active_binding = binding;
    const party_ids = [_]u8{restored.combat.integration.?.host.characterId(restored.field_state.progress.party[0].id).?};
    active_binding.party = &party_ids;
    var interaction = try @import("field_events").Session.beginInteraction(active_binding, restored.field_state, 1, 14, retained);
    for (0..8) |_| {
        if (interaction.boxes[0].anchor != null) break;
        _ = try interaction.tick(active_binding, &restored.field_state, false);
    }
    try std.testing.expectEqualStrings("va3_room_1_e14_interaction", interaction.instance.?.program_id);
    try std.testing.expectEqual(field.Point{ .x = 96, .y = 288 }, interaction.boxes[0].anchor.?);
    const program = for (binding.content.programs) |program| {
        if (program.entity == 28) break program;
    } else return error.MissingActorInitializer;
    var older = binding.content;
    older.programs = &.{program};
    older.schema = event_runtime.world_entry_schema;
    older.forward_branches = null;
    try std.testing.expectError(error.InvalidEventCommand, older.validate());
}

test "source actor initializers retain constructor motion without changing animation ownership" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    const binding = state.room_battles.?.bindingFor("va1_room_1").?;
    const packet = binding.ordinary.?;
    const room_index = state.package.roomIndex(binding.room).?;
    const room = state.package.rooms[room_index];
    const floor = std.mem.indexOfScalar(u8, room.walkable, '1').?;
    const columns: usize = @intCast(@divExact(room.width, 8));
    state.field_state.enterRoom(room_index, .{ .x = @intCast(floor % columns * 8), .y = @intCast(floor / columns * 8) });
    try state.initializeRoomVisit();
    var actors = (try state.room_battles.?.constructActorsForVisit(binding, state.field_state.progress.story.scenario.?, state.field_state.room_entries)).?;
    for ([_]struct { entity: u8, x: i32, y: i32 }{
        .{ .entity = 5, .x = 312, .y = 88 }, .{ .entity = 9, .x = 96, .y = 64 }, .{ .entity = 6, .x = 216, .y = 88 },
    }) |expected| {
        const definition = for (packet.actors) |actor| {
            if (actor.entity == expected.entity) break actor;
        } else return error.MissingInteractionActor;
        const avatar = try actors.actor(packet, definition.id);
        try std.testing.expectEqual(expected.x, avatar.motion.x);
        try std.testing.expectEqual(expected.y, avatar.motion.y);
        try std.testing.expectEqual(definition.speed, avatar.motion.speed);
        const animated = avatar.auto_animate;
        try actors.restoreMotion(packet, definition.id, definition.speed);
        try std.testing.expectEqual(animated, avatar.auto_animate);
        try std.testing.expectError(error.InvalidFieldActorState, actors.restoreMotion(packet, definition.id, 1));
        avatar.motion.offset_x = 1;
        try std.testing.expectError(error.FieldActorBusy, actors.restoreMotion(packet, definition.id, 0));
        avatar.motion.offset_x = 0;
    }
    _ = try actors.settle(packet, binding.animations);
    const saved = try journey.Snapshot.capture(state);
    var fresh_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&fresh_members);
    try saved.apply(&restored);
    try restored.initializeRoomVisit();
    const retained = (try restored.room_battles.?.constructActorsForVisit(binding, restored.field_state.progress.story.scenario.?, restored.field_state.room_entries)).?;
    try std.testing.expect(std.meta.eql(actors.settled_positions, retained.settled_positions));
}

test "source initializer first pumps keep Hero state and discard unarmed tails" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    for (0..4) |sample| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        const room_id = if (sample == 0) "va3_room_1" else if (sample == 3) "va1_room_1" else "va1_room_2";
        if (sample == 0) setScenarioBit(&state, 9, 32) else if (sample == 1) setScenarioBit(&state, 3, 16) else if (sample == 2) setScenarioBit(&state, 4, 8) else setScenarioBit(&state, 20, 4);
        const room_index = state.package.roomIndex(room_id).?;
        const room = state.package.rooms[room_index];
        const floor = std.mem.indexOfScalar(u8, room.walkable, '1').?;
        const columns: usize = @intCast(@divExact(room.width, 8));
        state.field_state.enterRoom(room_index, .{ .x = @intCast(floor % columns * 8), .y = @intCast(floor / columns * 8) });
        state.field_state.facing = .left;
        try state.initializeRoomVisit();
        const binding = state.room_battles.?.bindingFor(room_id).?;
        var actors = (try state.room_battles.?.constructActorsForVisit(binding, state.field_state.progress.story.scenario.?, state.field_state.room_entries)).?;
        if (sample == 3) {
            const id = for (binding.ordinary.?.actors) |definition| {
                if (definition.entity == 5) break definition.id;
            } else return error.MissingInitializerActor;
            const staged = try actors.actor(binding.ordinary.?, id);
            try std.testing.expectEqual(@as(i32, 2032), staged.motion.x);
            try std.testing.expectEqual(@as(i32, 2032), staged.motion.y);
            try std.testing.expectEqual(@as(u8, 0), staged.motion.speed);
            try actors.place(binding.ordinary.?, id, 312, 88);
            try std.testing.expectEqual(@as(i32, 312), (try actors.actor(binding.ordinary.?, id)).motion.x);
            _ = try actors.settle(binding.ordinary.?, binding.animations);
            continue;
        }
        const id = for (binding.ordinary.?.actors) |definition| {
            if (definition.entity == @as(u8, if (sample == 0) 4 else 10)) break definition.id;
        } else return error.MissingInitializerActor;
        const actor = try actors.actor(binding.ordinary.?, id);
        try std.testing.expectEqual(@as(i32, if (sample == 0) 0 else 120), actor.motion.x);
        try std.testing.expectEqual(@as(i32, if (sample == 0) 560 else 136), actor.motion.y);
        if (sample == 0) {
            try std.testing.expect(!scenarioBitSet(&state, 9, 64));
        } else if (sample == 1) {
            try std.testing.expectEqual(field.Direction.down, state.field_state.facing);
            // Exercise the same host's Hero placement using a controlled valid command.
            var changed = binding;
            const programs = try allocator.dupe(event_runtime.Program, binding.content.programs);
            defer allocator.free(programs);
            changed.content.programs = programs;
            const index = for (programs, 0..) |program, i| {
                if (program.entry == .initialization and program.entity == 15) break i;
            } else return error.MissingInitializerFixture;
            const commands = try allocator.dupe(event_runtime.Command, programs[index].commands);
            defer allocator.free(commands);
            programs[index].commands = commands;
            const target = std.mem.indexOfScalarPos(u8, room.walkable, floor + 1, '1').?;
            const x: i32 = @intCast(target % columns * 8);
            const y: i32 = @intCast(target / columns * 8);
            commands[commands.len - 3] = .{ .kind = .place_hero, .x = x, .y = y };
            var story = state.field_state.progress.story.scenario.?;
            try std.testing.expect(try state.room_battles.?.initializeStory(changed, &state.field_state, &story));
            try std.testing.expectEqual(x, state.field_state.x);
            try std.testing.expectEqual(y, state.field_state.y);
            try std.testing.expectEqualDeep(field.Point{ .x = x, .y = y }, state.field_state.destination);
            // The constructor may also stage the hero outside the walkable room.
            try std.testing.expect(!room.contains(2040, 2040));
            commands[commands.len - 3] = .{ .kind = .place_hero, .x = 2040, .y = 2040 };
            try std.testing.expect(try state.room_battles.?.initializeStory(changed, &state.field_state, &story));
            try std.testing.expectEqualDeep(field.Point{ .x = 2040, .y = 2040 }, state.field_state.destination);
            commands[commands.len - 3].y = 2048;
            try std.testing.expectError(error.InvalidFieldEventTransition, state.room_battles.?.initializeStory(changed, &state.field_state, &story));
        } else try std.testing.expect(scenarioBitSet(&state, 4, 128));
    }
}

test "canonical interactions honor live room flag predicates before dispatch" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    for ([_]struct { room: []const u8, entity: u8, mask: u8 }{
        .{ .room = "va1_room_3", .entity = 12, .mask = 1 },
        .{ .room = "va1_room_7", .entity = 6, .mask = 2 },
    }) |sample| {
        var binding = state.room_battles.?.bindingFor(sample.room).?;
        var party_ids: [6]u8 = undefined;
        for (state.field_state.progress.party, 0..) |member, i| party_ids[i] = state.combat.integration.?.host.characterId(member.id).?;
        binding.party = party_ids[0..state.field_state.progress.party.len];
        const construction = try binding.constructRoomActors(state.field_state.progress.story.scenario.?);
        state.field_state.enterRoom(state.package.roomIndex(sample.room).?, .{ .x = 80, .y = 80 });
        state.field_state.local_flags.values[5] = 0;
        try std.testing.expectError(error.UnavailableFieldInteraction, @import("field_events").Session.beginInteraction(binding, state.field_state, 1, sample.entity, construction));
        state.field_state.local_flags.values[5] = sample.mask ^ 3;
        try std.testing.expectError(error.UnavailableFieldInteraction, @import("field_events").Session.beginInteraction(binding, state.field_state, 1, sample.entity, construction));
        state.field_state.local_flags.values[5] |= sample.mask;
        const interaction = try @import("field_events").Session.beginInteraction(binding, state.field_state, 1, sample.entity, construction);
        try std.testing.expectEqual(sample.entity, binding.content.program(interaction.instance.?.program_id).?.entity);
        const saved = try journey.Snapshot.capture(state);
        // Snapshot validation also requires an actual walkable standing point.
        const room = state.package.rooms[state.field_state.room];
        const floor = std.mem.indexOfScalar(u8, room.walkable, '1').?;
        const columns: usize = @intCast(@divExact(room.width, 8));
        var valid_save = saved;
        valid_save.x = @intCast(floor % columns * 8);
        valid_save.y = @intCast(floor / columns * 8);
        var fresh_members: [6]battle.Member = undefined;
        var restored = try harness.newState(&fresh_members);
        try valid_save.apply(&restored);
        const restored_construction = try binding.constructRoomActors(restored.field_state.progress.story.scenario.?);
        _ = try @import("field_events").Session.beginInteraction(binding, restored.field_state, 1, sample.entity, restored_construction);
        restored.field_state.local_flags.values[5] &= ~sample.mask;
        try std.testing.expectError(error.UnavailableFieldInteraction, @import("field_events").Session.beginInteraction(binding, restored.field_state, 1, sample.entity, restored_construction));
    }
}

test "canonical source eligibility gates use live castle tier and recruitment flags" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    var binding = state.room_battles.?.bindingFor("vb1_room_4").?;
    const party_ids = [_]u8{state.combat.integration.?.host.characterId(state.field_state.progress.party[0].id).?};
    binding.party = &party_ids;
    const room_index = state.package.roomIndex(binding.room).?;
    const room = state.package.rooms[room_index];
    const floor = std.mem.indexOfScalar(u8, room.walkable, '1').?;
    const columns: usize = @intCast(@divExact(room.width, 8));
    state.field_state.enterRoom(room_index, .{ .x = @intCast(floor % columns * 8), .y = @intCast(floor / columns * 8) });
    state.field_state.progress.story.scenario.?.castle_tier = 0;
    var construction = try binding.constructRoomActors(state.field_state.progress.story.scenario.?);
    try std.testing.expectError(error.UnavailableFieldInteraction, @import("field_events").Session.beginInteraction(binding, state.field_state, 1, 1, construction));
    state.field_state.progress.story.scenario.?.castle_tier = 1;
    construction = try binding.constructRoomActors(state.field_state.progress.story.scenario.?);
    _ = try @import("field_events").Session.beginInteraction(binding, state.field_state, 1, 1, construction);
    const saved = try journey.Snapshot.capture(state);
    var fresh_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&fresh_members);
    try saved.apply(&restored);
    _ = try @import("field_events").Session.beginInteraction(binding, restored.field_state, 1, 1, try binding.constructRoomActors(restored.field_state.progress.story.scenario.?));
    state.field_state.progress.story.scenario.?.castle_tier = 2;
    setScenarioBit(&state, 14, 16);
    construction = try binding.constructRoomActors(state.field_state.progress.story.scenario.?);
    try std.testing.expectError(error.UnavailableFieldInteraction, @import("field_events").Session.beginInteraction(binding, state.field_state, 1, 5, construction));
    binding.party = &.{30};
    construction = try binding.constructRoomActors(state.field_state.progress.story.scenario.?);
    _ = try @import("field_events").Session.beginInteraction(binding, state.field_state, 1, 5, construction);
    binding = state.room_battles.?.bindingFor("vb2_room_8").?;
    binding.party = &party_ids;
    state.field_state.enterRoom(state.package.roomIndex(binding.room).?, .{ .x = 176, .y = 120 });
    setScenarioBit(&state, 12, 1);
    construction = try binding.constructRoomActors(state.field_state.progress.story.scenario.?);
    var session: @import("field_events").Session = undefined;
    for ([_]u8{ 0, 1, 3, 5 }) |flags| {
        state.field_state.progress.story.scenario.?.recruit_flags[32] = flags;
        const admitted = try @import("field_events").Session.beginRoomEvent(&session, binding, state.field_state, 1, if (construction) |*actors| actors else null, .ordinary, null);
        try std.testing.expectEqual(flags == 1 or flags == 5, admitted);
        if (admitted) try std.testing.expectEqualStrings("vb2_room_8_e01_ordinary", session.instance.?.program_id);
    }
}

test "canonical money predicates read current field funds before interaction" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    var binding = state.room_battles.?.bindingFor("vb6_room_12").?;
    const party_ids = [_]u8{state.combat.integration.?.host.characterId(state.field_state.progress.party[0].id).?};
    binding.party = &party_ids;
    const room_index = state.package.roomIndex(binding.room).?;
    const room = state.package.rooms[room_index];
    const floor = std.mem.indexOfScalar(u8, room.walkable, '1').?;
    const columns: usize = @intCast(@divExact(room.width, 8));
    state.field_state.enterRoom(room_index, .{ .x = @intCast(floor % columns * 8), .y = @intCast(floor / columns * 8) });
    setScenarioBit(&state, 19, 8);
    state.field_state.progress.story.scenario.?.castle_tier = 2;
    const construction = try binding.constructRoomActors(state.field_state.progress.story.scenario.?);
    for ([_]u32{ 0, 9999, 10000, 999999, 9999 }) |money| {
        state.field_state.progress.money = money;
        if (money < 10000) {
            try std.testing.expectError(error.UnavailableFieldInteraction, @import("field_events").Session.beginInteraction(binding, state.field_state, 1, 3, construction));
        } else {
            const interaction = try @import("field_events").Session.beginInteraction(binding, state.field_state, 1, 3, construction);
            try std.testing.expectEqualStrings("vb6_room_12_e03_interaction", interaction.instance.?.program_id);
        }
    }
    state.field_state.progress.money = 10000;
    const saved = try journey.Snapshot.capture(state);
    var fresh_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&fresh_members);
    try saved.apply(&restored);
    _ = try @import("field_events").Session.beginInteraction(binding, restored.field_state, 1, 3, try binding.constructRoomActors(restored.field_state.progress.story.scenario.?));
}

test "canonical shared conversations use source props and fixed live actor ownership" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    var binding = state.room_battles.?.bindingFor("vb2_room_5").?;
    const party_ids = [_]u8{state.combat.integration.?.host.characterId(state.field_state.progress.party[0].id).?};
    binding.party = &party_ids;
    state.field_state.enterRoom(state.package.roomIndex(binding.room).?, .{ .x = 112, .y = 152 });
    var actors = (try binding.constructRoomActors(state.field_state.progress.story.scenario.?)).?;
    var interaction = try @import("field_events").Session.beginInteraction(binding, state.field_state, 1, 11, actors);
    try std.testing.expectEqualStrings("vb2_room_5_e11_interaction", interaction.instance.?.program_id);
    const point = binding.interactionPosition(11, &actors).?;
    for (0..8) |_| {
        if (interaction.boxes[0].anchor != null) break;
        _ = try interaction.tick(binding, &state.field_state, false);
    }
    try std.testing.expectEqual(field.Point{ .x = point.x + 8, .y = point.y - 24 }, interaction.boxes[0].anchor.?);
    const program = binding.content.program("vb2_room_5_e11_interaction").?;
    try actors.release(binding.ordinary.?, program.owner_actors.?[0]);
    try std.testing.expectError(error.IneligibleFieldInteraction, @import("field_events").Session.beginInteraction(binding, state.field_state, 2, 11, actors));
    state.field_state.progress.story.scenario.?.recruit_flags[92] = 1;
    actors = (try binding.constructRoomActors(state.field_state.progress.story.scenario.?)).?;
    try std.testing.expectError(error.IneligibleFieldInteraction, @import("field_events").Session.beginInteraction(binding, state.field_state, 2, 11, actors));
    const prop = binding.population.entities[9];
    try std.testing.expectEqual(.event, prop.record_role);
    try std.testing.expect(prop.source_character_id == null and !prop.population_candidate);
    const notice = try @import("field_events").Session.beginInteraction(binding, state.field_state, 3, 9, actors);
    try std.testing.expectEqualStrings("vb2_room_5_e09_interaction", notice.instance.?.program_id);
}

test "canonical level predicates use live roster levels and select the source fallback" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    for ([_]u8{ 34, 35 }) |level| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, "kirkis");
        state.combat.progress.party[1].level = level;
        setScenarioBit(&state, 19, 8);
        setScenarioBit(&state, 160, 8);
        state.field_state.progress.story.scenario.?.castle_tier = 2;
        state.field_state.enterRoom(state.package.roomIndex("vb6_room_12").?, .{ .x = 152, .y = 80 });
        try std.testing.expect(state.package.rooms[state.field_state.room].canStand(152, 80));
        _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true, .direction = .up } }, .{});
        const owner = state.field_event orelse return error.MissingLevelInteraction;
        try std.testing.expectEqualStrings(if (level == 34) "vb6_room_12_e06_interaction" else "vb6_room_12_e05_interaction", owner.session.instance.?.program_id);
        try std.testing.expectEqual(level, owner.binding.character_levels.?[4]);
        try std.testing.expectEqual(state.combat.progress.party[0].level, owner.binding.character_levels.?[8]);
        if (level == 35) {
            var missing = owner.binding.*;
            missing.character_levels = null;
            try std.testing.expectError(error.MissingFieldCharacterLevels, @import("field_events").Session.beginInteraction(missing, state.field_state, 99, 5, owner.session.ordinary_actors));
            var invalid = owner.binding.character_levels.?.*;
            invalid[4] = 100;
            missing.character_levels = &invalid;
            try std.testing.expectError(error.InvalidFieldCharacterLevel, missing.validateContext());
        }
    }
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    var seeded = try party_session.catalogue.materializeBound(state.combat.*, state.party_catalog.?, "kirkis", state.party_bindings);
    seeded.owned.level = 37;
    try state.retainReserve(seeded.owned);
    const saved = try journey.Snapshot.capture(state);
    var fresh_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&fresh_members);
    try saved.apply(&restored);
    _ = try restored.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(@as(u8, 37), restored.room_battles.?.character_levels[4]);
    for (restored.party_catalog.?.characters) |character| {
        if (character.source_character_id == 4 or character.source_character_id == 8) continue;
        try std.testing.expectEqual(character.seed.level, restored.room_battles.?.character_levels[character.source_character_id]);
    }
    try std.testing.expectEqual(@as(u8, 0), restored.room_battles.?.character_levels[255]);
}

test "Sarady inn staff are available after the tea scene" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    setScenarioBit(&state, 8, 4);
    const before_tea = state.field_state.progress.story.scenario.?;
    state.field_state.enterRoom(state.package.roomIndex("va8_room_10").?, .{ .x = 312, .y = 224 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqualStrings("va8_room_10_e03_ordinary", state.field_event.?.session.instance.?.program_id);
    _ = try drainFieldEvent(&state, &.{1});
    try std.testing.expect(scenarioBitSet(&state, 8, 8));

    const rooms = state.room_battles.?;
    const binding = rooms.active_binding;
    try std.testing.expectEqualStrings("va8_room_10", binding.room);
    try std.testing.expect(rooms.settledForVisit(binding, state.field_state.room_entries) == null);
    var old_save = try journey.Snapshot.capture(state);
    const old_actors = (try binding.constructRoomActors(before_tea)).?;
    old_save.room_actors = try old_actors.settle(binding.ordinary.?, binding.animations);
    try old_save.apply(&state);
    state.bind();
    try std.testing.expect(rooms.settledForVisit(binding, state.field_state.room_entries) == null);
    try walkTo(allocator, &state, null, 240, 176, &.{});
    try interactFacing(&state, .right, &.{});
    try std.testing.expect(scenarioBitSet(&state, 8, 16));
}

test "canonical source chest preserves acquisition message and retries full bags" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    for (state.combat.progress.party) |*member| member.loadout = .{};
    for (state.combat.progress.party) |*member| for (&member.inventory.slots) |*slot| {
        slot.* = .{ .id = .medicine, .uses = 6 };
    };
    setScenarioBit(&state, 3, 32);
    const room_index = state.package.roomIndex("va2_room_3").?;
    const room = state.package.rooms[room_index];
    try std.testing.expect(room.canStand(512, 296));
    state.field_state.enterRoom(room_index, .{ .x = 512, .y = 296 });
    _ = try state.tickWithFieldEvents(.{}, .{});
    const open_chest: pause_menu.Input = .{ .field = .{ .action = true, .direction = .up } };
    for ([_]bool{ true, false }) |full| {
        if (!full) state.field_state.progress.party[0].inventory.remove(0);
        _ = try state.tickWithFieldEvents(open_chest, .{});
        const owner = state.field_event orelse return error.MissingChestInteraction;
        try std.testing.expectEqualStrings("va2_room_3_e27_interaction", owner.session.instance.?.program_id);
        var anchored = false;
        for (0..2000) |tick| {
            const session = (state.field_event orelse break).session;
            if (!anchored and session.boxes[0].phase == .opening) {
                try std.testing.expectEqual(session.hero.x + 8, session.boxes[0].anchor.?.x);
                try std.testing.expectEqual(session.hero.y - 24, session.boxes[0].anchor.?.y);
                anchored = true;
            }
            _ = try state.tickWithFieldEvents(.{ .field = .{ .action = tick % 2 == 0 } }, .{});
        }
        try std.testing.expect(state.field_event == null and anchored);
        const flag_set = state.field_state.progress.story.scenario.?.scenario[172] & 0x10 != 0;
        try std.testing.expectEqual(!full, flag_set);
        for (state.field_state.progress.party) |member| try std.testing.expectEqual(@as(usize, 9), member.inventory.count());
    }
    _ = try state.tickWithFieldEvents(open_chest, .{});
    try std.testing.expect(state.field_event == null);
}

test "canonical item predicates use active bags and equipped gear" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    for ([_]bool{ false, true }) |equipped| {
        var members: [6]battle.Member = undefined;
        var state = try harness.newState(&members);
        inline for (.{ .head, .body, .shield, .accessory_one, .accessory_two }) |slot| try state.combat.equipSlot(0, slot, null);
        state.combat.progress.party[0].inventory = .{};
        try std.testing.expect(try state.combat.progress.party[0].inventory.receive(.medicine));
        try std.testing.expect(try state.combat.progress.party[0].inventory.receive(.bandanna));
        try state.combat.equipSlot(0, .head, if (equipped) state.combat.gearIndex(.bandanna).? else null);
        var reserve = try party_session.catalogue.materializeBound(state.combat.*, state.party_catalog.?, "kirkis", state.party_bindings);
        reserve.owned.loadout = .{};
        reserve.owned.inventory = .{};
        try std.testing.expect(try reserve.owned.inventory.receive(.antitoxin));
        try state.retainReserve(reserve.owned);
        state.field_state.enterRoom(state.package.roomIndex("vb2_room_5").?, .{ .x = 112, .y = 152 });
        _ = try state.tickWithFieldEvents(.{}, .{});
        var binding = state.room_battles.?.active_binding;
        try std.testing.expectEqualStrings("vb2_room_5", binding.room);
        const presence = binding.item_presence.?;
        try std.testing.expect(std.mem.indexOfScalar(u16, presence.carried, field.items.Id.medicine.sourceId()) != null);
        try std.testing.expect(std.mem.indexOfScalar(u16, presence.carried, field.items.Id.antitoxin.sourceId()) == null);
        try std.testing.expectEqual(equipped, std.mem.indexOfScalar(u16, presence.equipped, field.items.Id.bandanna.sourceId()) != null);
        const entities = try allocator.dupe(@TypeOf(binding.population.entities[0]), binding.population.entities);
        defer allocator.free(entities);
        binding.population.entities = entities;
        const programs = try allocator.dupe(event_runtime.Program, binding.content.programs);
        defer allocator.free(programs);
        binding.content.programs = programs;
        const program_index = for (programs, 0..) |program, index| {
            if (program.entity == 9) break index;
        } else return error.MissingItemQueryFixture;
        const construction = try binding.constructRoomActors(state.field_state.progress.story.scenario.?);
        for ([_]struct { id: field.items.Id, require_equipped: bool, matches: bool }{
            .{ .id = .medicine, .require_equipped = false, .matches = true },
            .{ .id = .medicine, .require_equipped = true, .matches = false },
            .{ .id = .bandanna, .require_equipped = false, .matches = true },
            .{ .id = .bandanna, .require_equipped = true, .matches = equipped },
            .{ .id = .antitoxin, .require_equipped = false, .matches = false },
        }) |query| {
            const selection = [_]event_runtime.Selection{.{ .kind = .has_item, .index = @intCast(query.id.sourceId()), .require_key = query.require_equipped }};
            programs[program_index].selection = &selection;
            const terms = [_]@TypeOf(entities[9].event_selection.terms[0]){ .{ .kind = .interaction }, .{ .kind = .has_item, .item_id = query.id.sourceId(), .require_key = query.require_equipped } };
            entities[9].event_selection.terms = &terms;
            if (query.matches) {
                _ = try @import("field_events").Session.beginInteraction(binding, state.field_state, 1, 9, construction);
                var missing = binding;
                missing.item_presence = null;
                try std.testing.expectError(error.MissingFieldItemPresence, @import("field_events").Session.beginInteraction(missing, state.field_state, 1, 9, construction));
            } else {
                try std.testing.expectError(error.UnavailableFieldInteraction, @import("field_events").Session.beginInteraction(binding, state.field_state, 1, 9, construction));
            }
        }
        for (state.shared_item_catalogue.?.items) |row| if (row.controller.tag) |tag| {
            const id = std.meta.stringToEnum(field.items.Id, tag).?;
            try std.testing.expectEqual(row.source_item_id, id.sourceId());
            try std.testing.expectEqual(row.equipment_slot != null, id.equipment());
        };
    }
}

test "world entry context survives rooms and reload before retained return" {
    const allocator = std.testing.allocator;
    var harness = try CanonicalHarness.load(allocator, std.testing.io);
    defer harness.deinit();
    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    try std.testing.expectEqualStrings("world_a_point_9", state.field_state.worldEntry(state.package).?.id);
    state.field_state.enterRoom(state.package.roomIndex("world_a").?, .{ .x = 584, .y = 392 });
    state.field_state.reconcileWorldEntry(state.package, null);
    for (0..state.package.step_ticks) |_| state.field_state.tick(state.package, .{ .direction = .up });
    try std.testing.expectEqualStrings("va1_room_0", currentRoomName(&state));
    try std.testing.expectEqualStrings("world_a_point_0", state.field_state.worldEntry(state.package).?.id);
    const house_index = state.package.roomIndex("va1_room_1").?;
    const house = state.package.rooms[house_index];
    const floor = std.mem.indexOfScalar(u8, house.walkable, '1').?;
    const columns: usize = @intCast(@divExact(house.width, 8));
    state.field_state.enterRoom(house_index, .{ .x = @intCast(floor % columns * 8), .y = @intCast(floor / columns * 8) });
    state.field_state.reconcileWorldEntry(state.package, null);
    const saved = try journey.Snapshot.capture(state);
    const bytes = try std.json.Stringify.valueAlloc(allocator, saved, .{});
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(journey.Snapshot, allocator, bytes, .{});
    defer parsed.deinit();
    var fresh_members: [6]battle.Member = undefined;
    var restored = try harness.newState(&fresh_members);
    try parsed.value.apply(&restored);
    try std.testing.expectEqualStrings("world_a_point_0", restored.field_state.worldEntry(restored.package).?.id);
    restored.field_state.enterRoom(restored.package.roomIndex("va1_room_0").?, .{ .x = 808, .y = 872 });
    for (0..8) |_| {
        _ = try restored.tickWithFieldEvents(.{}, .{});
        if (std.mem.eql(u8, currentRoomName(&restored), "world_a") and restored.field_event == null) break;
    }
    try std.testing.expectEqualStrings("world_a", currentRoomName(&restored));
    try std.testing.expectEqual(@as(i32, 584), restored.field_state.x);
    try std.testing.expectEqual(@as(i32, 392), restored.field_state.y);
    var invalid = saved;
    invalid.world_context.?.entry = "world_b_point_0";
    try std.testing.expectError(error.InvalidSave, invalid.validate(restored));
    var legacy = saved;
    legacy.schema = "suikoden-journey-save/39";
    legacy.world_context = null;
    try legacy.apply(&restored);
    try std.testing.expectEqualStrings("world_a_point_0", restored.field_state.worldEntry(restored.package).?.id);
    restored.field_state.setWorldEntry(restored.package, "world_a_point_8");
    restored.field_state.enterRoom(restored.package.roomIndex("va8_room_1").?, .{ .x = 144, .y = 160 });
    restored.field_state.reconcileWorldEntry(restored.package, null);
    try std.testing.expectEqualStrings("world_a_point_8", restored.field_state.worldEntry(restored.package).?.id);
    restored.field_state.setWorldEntry(restored.package, "world_a_point_7");
    restored.field_state.enterRoom(restored.package.roomIndex("va8_room_0").?, .{ .x = 176, .y = 320 });
    for (0..8) |_| {
        _ = try restored.tickWithFieldEvents(.{}, .{});
        if (std.mem.eql(u8, currentRoomName(&restored), "world_a") and restored.field_event == null) break;
    }
    try std.testing.expectEqualStrings("world_a", currentRoomName(&restored));
    try std.testing.expectEqual(@as(i32, 344), restored.field_state.x);
    try std.testing.expectEqual(@as(i32, 456), restored.field_state.y);
    const fixed_return = try journey.Snapshot.capture(restored);
    try fixed_return.validate(restored);
    restored.field_state.setWorldEntry(restored.package, "world_b_point_0");
    restored.field_state.enterRoom(restored.package.roomIndex("vb1_room_0").?, .{ .x = 184, .y = 616 });
    for (0..8) |_| {
        _ = try restored.tickWithFieldEvents(.{}, .{});
        if (std.mem.eql(u8, currentRoomName(&restored), "world_b") and restored.field_event == null) break;
    }
    try std.testing.expectEqualStrings("world_b", currentRoomName(&restored));
    try std.testing.expectEqual(@as(i32, 768), restored.field_state.x);
    try std.testing.expectEqual(@as(i32, 176), restored.field_state.y);
    restored.field_state.setWorldEntry(restored.package, "world_a_point_5");
    restored.field_state.enterRoom(restored.package.roomIndex("va6_room_1").?, .{ .x = 184, .y = 56 });
    try std.testing.expect(restored.package.rooms[restored.field_state.room].canStand(184, 56));
    const arrival = try journey.Snapshot.capture(restored);
    try arrival.validate(restored);
}

fn pngDimensions(io: std.Io, allocator: std.mem.Allocator, sub_path: []const u8) ![2]i32 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, sub_path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(bytes);
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, bytes[12..16], "IHDR")) {
        return error.InvalidPngHeader;
    }
    return .{
        @intCast(std.mem.readInt(u32, bytes[16..20], .big)),
        @intCast(std.mem.readInt(u32, bytes[20..24], .big)),
    };
}

fn expectDuelFrameInAtlas(frame: journey_content.duel_presentation.Frame, atlas_w: i32, atlas_h: i32) !void {
    try std.testing.expect(frame.visible);
    try std.testing.expect(frame.rect.w > 0 and frame.rect.h > 0);
    try std.testing.expect(frame.rect.x >= 0 and frame.rect.y >= 0);
    try std.testing.expect(frame.rect.x + frame.rect.w <= atlas_w);
    try std.testing.expect(frame.rect.y + frame.rect.h <= atlas_h);
    try std.testing.expect(frame.x >= 0 and frame.y >= 0);
    try std.testing.expect(frame.x + frame.rect.w <= journey_content.duel_presentation.width);
    try std.testing.expect(frame.y + frame.rect.h <= journey_content.duel_presentation.height);
}

fn visibleDuelCommand(duel: *const journey.duel.State) !journey.duel.Command {
    const cue = duel.cue();
    for (duel.duel.cues) |row| {
        for (row, std.enums.values(journey.duel.Command)) |line, command| {
            if (std.mem.eql(u8, cue, line)) return command;
        }
    }
    return error.UnrecognizedDuelCue;
}

fn chooseDuelCounter(opponent: journey.duel.Command, win: bool) journey.duel.Command {
    return if (win) switch (opponent) {
        .attack => .desperate_attack,
        .defend => .attack,
        .desperate_attack => .defend,
    } else switch (opponent) {
        .attack => .attack,
        .defend => .desperate_attack,
        .desperate_attack => .attack,
    };
}

fn finishActiveDuel(state: *journey.State, duel_id: []const u8, win: bool, choices: []const u8) !void {
    try std.testing.expectEqual(journey.Mode.duel, state.mode);
    try std.testing.expectEqualStrings(duel_id, state.active_duel.?.state.duel.id);
    for (0..4096) |_| {
        if (state.mode != .duel) break;
        const active = &(state.active_duel orelse return error.MissingActiveDuel);
        switch (active.state.phase) {
            .choosing => {
                const cue = try visibleDuelCommand(&active.state);
                const player = active.state.fighters[0];
                const opponent = active.state.fighters[1];
                const attack_damage = @max(@as(i32, player.attack) - @as(i32, opponent.defense), 1);
                const vs_teo = std.mem.eql(u8, duel_id, "pahn_teo") or std.mem.eql(u8, duel_id, "shu_teo");
                const finishing_attack = win and vs_teo and cue == .desperate_attack and attack_damage >= opponent.hp;
                try state.chooseDuelCommand(if (finishing_attack) .attack else chooseDuelCounter(cue, win));
            },
            .finished => {
                const expected_outcome: journey.duel.Outcome = if (win) .victory else .defeat;
                try std.testing.expectEqual(expected_outcome, active.state.outcome.?);
                _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
            },
            else => {
                _ = try state.tickWithFieldEvents(.{}, .{});
            },
        }
    } else return error.DuelTimeout;
    if (state.field_event != null and state.mode == .field) {
        _ = try drainFieldEvent(state, choices);
    }
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expect(state.active_duel == null);
    try std.testing.expect(state.scripted_battle == null);
}

fn finishContinuousBattle(state: *journey.State) !void {
    const encounter = state.combat.content.encounters[state.combat.encounter].id;
    const train = regionEEncounter(encounter) or std.mem.startsWith(u8, encounter, "vh1_dir_");
    try finishBattleWithInput(state, if (state.scripted_battle != null or train) .travel else .retreat);
}

fn drainStoryAndEvents(state: *journey.State, target_room: ?[]const u8, choices: []const u8) !void {
    var cursor: usize = 0;
    for (0..32) |_| {
        if (state.party_selection != null) {
            try finishHeadquartersPartySelection(state, null, null);
            continue;
        }
        if (state.mode == .battle) {
            try finishContinuousBattle(state);
            continue;
        }
        if (state.field_event != null and state.mode == .field) {
            _ = try drainFieldEventCursor(state, choices, &cursor);
            continue;
        }
        if (state.mode != .field) break;
        if (cursor == choices.len) {
            if (target_room == null or std.mem.eql(u8, currentRoomName(state), target_room.?)) break;
        }
        _ = try state.tickWithFieldEvents(.{}, .{});
    }
    try std.testing.expectEqual(choices.len, cursor);
    if (target_room) |want| try std.testing.expectEqualStrings(want, currentRoomName(state));
}

fn walkContinuousHop(allocator: std.mem.Allocator, state: *journey.State, target_room: ?[]const u8, target_x: i32, target_y: i32, choices: []const u8) !void {
    errdefer std.debug.print("Continuous hop failed from {s} ({d},{d}) -> {?s} ({d},{d}) mode={s}\n", .{
        currentRoomName(state), state.field_state.x, state.field_state.y, target_room, target_x, target_y, @tagName(state.mode),
    });
    for (0..64) |_| {
        if (state.party_selection != null) {
            try finishHeadquartersPartySelection(state, null, null);
            continue;
        }
        if (state.mode == .battle) {
            try finishContinuousBattle(state);
            continue;
        }
        if (state.mode == .field and state.field_event == null) {
            const room = currentRoomName(state);
            if (std.mem.startsWith(u8, room, "vf1_room_") or std.mem.startsWith(u8, room, "vf2_room_") or
                std.mem.startsWith(u8, room, "vh1_room_") or std.mem.startsWith(u8, room, "vs1_room_") or
                std.mem.startsWith(u8, room, "vad_room_"))
            {
                try prepareWithCarriedMedicine(state, .mega_medicine);
            }
        }
        if (target_room) |want| {
            if (std.mem.eql(u8, currentRoomName(state), want)) {
                if (state.field_event != null and choices.len == 0) {
                    _ = try drainFieldEvent(state, &.{});
                }
                if (state.field_event == null and state.party_selection == null) return;
            }
        } else if (state.field_state.x == target_x and state.field_state.y == target_y and state.field_event == null and state.party_selection == null) {
            return;
        }
        try walkTo(allocator, state, target_room, target_x, target_y, choices);
        if (state.mode == .battle) continue;
        if (state.party_selection != null) {
            try finishHeadquartersPartySelection(state, null, null);
        }
        if (target_room != null or choices.len > 0) {
            try drainStoryAndEvents(state, target_room, &.{});
            return;
        }
    }
    return error.ContinuousNavigationTimeout;
}

fn walkContinuousRoute(allocator: std.mem.Allocator, state: *journey.State, hops: []const struct { want: ?[]const u8, x: i32, y: i32, choices: []const u8 }) !void {
    for (hops) |hop| {
        try walkContinuousHop(allocator, state, hop.want, hop.x, hop.y, hop.choices);
    }
}

noinline fn preparePahnForTeo(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkTo(allocator, state, null, 344, 432, &.{});
    try interactFacing(state, .up, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{0});
    try finishHeadquartersPartySelection(state, "pahn", null);
    const pahn = for (state.combat.progress.party, 0..) |member, slot| {
        if (std.mem.eql(u8, member.id, "pahn")) break slot;
    } else return error.MissingPahnInParty;
    const level_before = state.combat.progress.party[pahn].level;
    try crossToranToRegionD(allocator, state);
    // Cover the claw upgrade, armor, and the return stay.
    for (0..420) |pass| {
        if (state.combat.progress.party[pahn].level >= 29 and state.combat.progress.money >= 124000) break;
        if (state.combat.progress.party[pahn].hp == 0 or (pass > 0 and pass % 8 == 0)) {
            try walkThroughEncounters(allocator, state, "vd2_room_0", 968, 456, &.{}, .retreat);
            try walkTo(allocator, state, "vd2_room_4", 144, 368, &.{});
            try walkTo(allocator, state, null, 176, 144, &.{});
            try interactFacing(state, .up, &.{0});
            try std.testing.expectEqual(state.combat.progress.party[pahn].max_hp, state.combat.progress.party[pahn].hp);
            try walkTo(allocator, state, "vd2_room_0", 184, 232, &.{});
            try walkTo(allocator, state, "world_d", 16, 128, &.{});
        }
        try walkThroughEncounters(allocator, state, null, if (pass % 2 == 0) 936 else 872, 472, &.{}, .prepared);
    }
    try std.testing.expect(level_before < 29 and state.combat.progress.party[pahn].level >= 29);
    try std.testing.expect(state.combat.progress.money >= 124000);

    try walkThroughEncounters(allocator, state, "vd2_room_0", 968, 456, &.{}, .retreat);
    try walkTo(allocator, state, "vd2_room_3", 416, 360, &.{});
    try walkTo(allocator, state, null, 208, 88, &.{});
    try interactService(state, .up);
    try std.testing.expectEqual(.blacksmith, state.menu.phase);
    while (state.menu.member != pahn) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    const confirm: pause_menu.Input = .{ .field = .{ .action = true } };
    while (state.combat.progress.party[pahn].weapon_level < 11) {
        const price = try state.combat.sharpenPrice(pahn, state.menu.service_limit);
        if (state.combat.progress.money < price + 500) break;
        const level = state.combat.progress.party[pahn].weapon_level;
        _ = try state.tickWithFieldEvents(confirm, .{});
        _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        try std.testing.expectEqual(level + 1, state.combat.progress.party[pahn].weapon_level);
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try std.testing.expectEqual(@as(u8, 11), state.combat.progress.party[pahn].weapon_level);
    try walkTo(allocator, state, "vd2_room_0", 184, 232, &.{});
    try walkTo(allocator, state, "world_d", 16, 128, &.{});
    try walkThroughEncounters(allocator, state, "vd1_room_0", 608, 408, &.{}, .retreat);
    try walkTo(allocator, state, "vd1_room_2", 120, 304, &.{});
    try walkTo(allocator, state, null, 192, 120, &.{});
    try interactFacing(state, .up, &.{1});
    const armor = [_]struct { item: field.items.Id, slot: battle.systems.EquipmentSlot }{
        .{ .item = .head_gear, .slot = .head },
        .{ .item = .ninja_suit, .slot = .body },
        .{ .item = .guard_ring, .slot = .accessory_one },
        .{ .item = .guard_ring, .slot = .accessory_two },
    };
    for (armor) |gear| try buyStockItem(state, gear.item, pahn);
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
    try std.testing.expectEqual(.root, state.menu.phase);
    while (state.menu.selected != .equipment) _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = try state.tickWithFieldEvents(confirm, .{});
    while (state.menu.member != pahn) _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    for (armor) |gear| {
        const index = for (state.combat.progress.party[pahn].inventory.slots, 1..) |slot, item_index| {
            if (slot != null and slot.?.id == gear.item) break item_index;
        } else return error.MissingPahnEquipment;
        while (state.menu.equipment_slot != gear.slot) _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        for (0..index) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .menu_direction = .down } }, .{});
        _ = try state.tickWithFieldEvents(confirm, .{});
        try std.testing.expectEqual(state.combat.gearIndex(gear.item), state.combat.progress.party[pahn].loadout.get(gear.slot));
        _ = try state.tickWithFieldEvents(confirm, .{});
    }
    _ = try state.tickWithFieldEvents(.{ .menu = true }, .{});
    try walkTo(allocator, state, "vd1_room_0", 184, 224, &.{});
    try walkTo(allocator, state, "world_d", 368, 592, &.{});
    try walkFromRegionDToKaku(allocator, state);
    try restInKaku(allocator, state);
    try crossKakuToToran(allocator, state, null);
    try walkFromToranDockToCouncil(allocator, state);
}

fn beginPahnDuel(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkTo(allocator, state, "vb5bg_room_0", 448, 184, &.{});
    try std.testing.expect(scenarioBitSet(state, 231, 64));
    try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[23] & 1 != 0);
    try expectPartyOrder(state, &.{"hero"});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expectEqualStrings("vb5b3_room_0", currentRoomName(state));
    try std.testing.expect(scenarioBitSet(state, 231, 128));
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(@as(usize, 1), try drainFieldEvent(state, &.{0}));
    try finishCampaignWar(state, "teo_before_fire_spear", .scripted_completion);
    try std.testing.expect(scenarioBitSet(state, 232, 1));
    try std.testing.expectEqualStrings("vb7d_room_0", currentRoomName(state));
    try std.testing.expectEqualStrings("world_b_point_41", state.field_state.worldEntry(state.package).?.id);

    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(@as(usize, 1), try drainFieldEvent(state, &.{1}));
    try std.testing.expectEqualStrings("pahn_teo", state.active_duel.?.state.duel.id);
}

noinline fn verifyPahnWin(allocator: std.mem.Allocator, state: *journey.State) !void {
    const before_preparation = try allocator.create(journey.Snapshot);
    defer allocator.destroy(before_preparation);
    before_preparation.* = try journey.Snapshot.capture(state.*);

    try preparePahnForTeo(allocator, state);
    try beginPahnDuel(allocator, state);
    try finishActiveDuel(state, "pahn_teo", true, &.{});
    try std.testing.expectEqual(@as(u8, 1), state.field_state.progress.story.scenario.?.scenario[34] & 3);
    try drainStoryAndEvents(state, "vb5b3_room_0", &.{});
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expect(state.field_state.progress.story.scenario.?.recruit_flags[6] & 1 != 0);

    try before_preparation.apply(state);
}

fn finishContinuousCampaign(allocator: std.mem.Allocator, state: *journey.State) !void {
    try playTeoRematchAndRegionE(allocator, state);
    try playDragonKnightsAndMoravia(allocator, state);
    try playShasarazadeToCredits(allocator, state);
}

noinline fn playTeoRematchAndRegionE(allocator: std.mem.Allocator, state: *journey.State) !void {
    // 1. Teo fire spear war -> Shu/Hero vs Teo duel -> vb5bg_room_0.
    try finishCampaignWar(state, "teo_fire_spear", .scripted_completion);
    try std.testing.expectEqualStrings("vb7d_room_1", currentRoomName(state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{0});
    errdefer if (state.active_duel) |active| std.debug.print("Teo rematch stopped in round {d} with fighters {any}\n", .{ active.state.round, active.state.fighters });
    try finishActiveDuel(state, "shu_teo", true, &.{});
    try drainStoryAndEvents(state, "vb5bg_room_0", &.{});
    try std.testing.expect(scenarioBitSet(state, 34, 4));
    try std.testing.expectEqual(@as(u8, 4), state.combat.progress.story.scenario.?.soul_eater_spell_slots);
    const judgment = state.combat.rune(0).?.spells[3] orelse return error.MissingJudgment;
    try std.testing.expectEqualStrings("Judgment", state.combat.content.systems.?.spells[judgment].name);

    // 2. Toran Council -> Lorimar (ve4) -> Warriors' Village (ve1) -> Qlon/Cave of the Past (ve2/vi1/vi2) -> Neclord (ve6/ve3).
    try walkFromToranDockToCouncil(allocator, state);
    try walkContinuousHop(allocator, state, null, 480, 160, &.{});
    try interactFacing(state, .up, &.{0});
    try std.testing.expectEqualStrings("ve4_room_0", currentRoomName(state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = null, .x = 368, .y = 232, .choices = &.{ 1, 1 } },
        .{ .want = "world_e", .x = 368, .y = 696, .choices = &.{} },
        .{ .want = "ve1_room_0", .x = 576, .y = 320, .choices = &.{} },
        .{ .want = "ve1_room_1", .x = 232, .y = 200, .choices = &.{} },
        .{ .want = null, .x = 160, .y = 176, .choices = &.{} },
    });
    const house_visit = state.field_state.room_entries;
    try interactFacing(state, .up, &.{});
    try std.testing.expectEqual(house_visit + 1, state.field_state.room_entries);
    try std.testing.expect(scenarioBitSet(state, 203, 2));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = null, .x = 248, .y = 264, .choices = &.{} },
        .{ .want = null, .x = 312, .y = 72, .choices = &.{} },
    });
    try interactFacing(state, .up, &.{});
    try std.testing.expect(scenarioBitSet(state, 203, 16));
    try walkContinuousHop(allocator, state, "ve1_room_0", 136, 424, &.{});
    try walkTo(allocator, state, null, 232, 216, &.{});
    if (state.mode == .field) {
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(state, &.{});
    }
    try std.testing.expectEqual(journey.Mode.battle, state.mode);
    try std.testing.expectEqualStrings("ve1_dir_57450_1", state.combat.content.encounters[state.combat.encounter].id);
    try std.testing.expect(state.defeatContinuesScene());
    const village_potch = state.combat.progress.money;
    try finishBattleWithInput(state, .scripted_loss);
    try drainStoryAndEvents(state, "ve1_room_1", &.{});
    try std.testing.expectEqual(village_potch, state.combat.progress.money);
    for (state.combat.progress.party) |member| {
        try std.testing.expectEqual(member.max_hp, member.hp);
        try std.testing.expect(member.status != .unconscious);
    }
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = null, .x = 312, .y = 112, .choices = &.{} },
        .{ .want = "ve1_room_0", .x = 136, .y = 424, .choices = &.{} },
        .{ .want = "world_e", .x = 344, .y = 704, .choices = &.{} },
        .{ .want = "ve2_room_0", .x = 272, .y = 304, .choices = &.{} },
        .{ .want = "ve2_room_1", .x = 384, .y = 432, .choices = &.{} },
        .{ .want = null, .x = 328, .y = 416, .choices = &.{} },
    });
    const cave_party_count = state.combat.partyCount();
    try interactFacing(state, .up, &.{});
    try std.testing.expectEqual(cave_party_count, state.combat.partyCount());
    try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[18] & 1 != 0);
    const fukien_recruited = for (state.reserves) |entry| {
        if (entry) |member| if (std.mem.eql(u8, member.id, "fukien")) break true;
    } else false;
    try std.testing.expect(fukien_recruited);
    try std.testing.expectEqualStrings("ve2_room_0", currentRoomName(state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expect(scenarioBitSet(state, 205, 3));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "ve2_room_3", .x = 560, .y = 80, .choices = &.{} },
        .{ .want = "ve2_room_4", .x = 120, .y = 48, .choices = &.{} },
        .{ .want = "ve2_room_6", .x = 184, .y = 112, .choices = &.{} },
        .{ .want = "ve2_room_8", .x = 648, .y = 504, .choices = &.{} },
        .{ .want = "ve2_room_11", .x = 728, .y = 496, .choices = &.{} },
        .{ .want = "ve2_room_8", .x = 248, .y = 40, .choices = &.{} },
        .{ .want = "ve2_room_12", .x = 568, .y = 232, .choices = &.{} },
        .{ .want = "ve2_room_14", .x = 216, .y = 248, .choices = &.{} },
        .{ .want = "ve2_room_15", .x = 472, .y = 888, .choices = &.{} },
        .{ .want = "ve2_room_17", .x = 552, .y = 168, .choices = &.{} },
        .{ .want = "ve2_room_18", .x = 152, .y = 40, .choices = &.{} },
        .{ .want = "ve2_room_20", .x = 784, .y = 376, .choices = &.{} },
        .{ .want = "ve2_room_21", .x = 248, .y = 48, .choices = &.{} },
        .{ .want = "ve2_room_22", .x = 184, .y = 120, .choices = &.{} },
        .{ .want = "vi1_room_0", .x = 184, .y = 384, .choices = &.{} },
    });
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expect(scenarioBitSet(state, 211, 1));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = null, .x = 280, .y = 304, .choices = &.{} },
        .{ .want = null, .x = 352, .y = 240, .choices = &.{} },
    });
    try std.testing.expect(scenarioBitSet(state, 211, 4));
    try walkContinuousHop(allocator, state, null, 176, 464, &.{});
    const study_visit = state.field_state.room_entries;
    try interactFacing(state, .up, &.{ 0, 0 });
    try std.testing.expectEqual(study_visit + 1, state.field_state.room_entries);
    try walkContinuousHop(allocator, state, null, 368, 256, &.{});
    try interactFacing(state, .up, &.{});
    try std.testing.expect(scenarioBitSet(state, 211, 16));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vi1_room_3", .x = 368, .y = 176, .choices = &.{} },
        .{ .want = null, .x = 152, .y = 264, .choices = &.{} },
    });
    try interactFacing(state, .up, &.{});
    try std.testing.expectEqualStrings("vi1_room_0", currentRoomName(state));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vi1_room_3", .x = 368, .y = 192, .choices = &.{} },
        .{ .want = "vi2_room_0", .x = 96, .y = 88, .choices = &.{} },
    });
    try walkTo(allocator, state, null, 304, 544, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expect(scenarioBitSet(state, 213, 1));
    try std.testing.expectEqual(@as(i32, 352), state.field_state.x);
    try std.testing.expectEqual(@as(i32, 240), state.field_state.y);
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "ve2_room_23", .x = 184, .y = 352, .choices = &.{0} },
        .{ .want = "ve2_room_22", .x = 184, .y = 288, .choices = &.{} },
        .{ .want = "ve2_room_21", .x = 600, .y = 40, .choices = &.{} },
        .{ .want = "ve2_room_20", .x = 216, .y = 240, .choices = &.{} },
        .{ .want = "ve2_room_18", .x = 8, .y = 168, .choices = &.{} },
        .{ .want = "ve2_room_17", .x = 104, .y = 232, .choices = &.{} },
        .{ .want = "ve2_room_15", .x = 216, .y = 40, .choices = &.{} },
        .{ .want = "ve2_room_14", .x = 248, .y = 120, .choices = &.{} },
        .{ .want = "ve2_room_12", .x = 120, .y = 48, .choices = &.{} },
        .{ .want = "ve2_room_8", .x = 216, .y = 32, .choices = &.{} },
        .{ .want = "ve2_room_11", .x = 536, .y = 496, .choices = &.{} },
        .{ .want = "ve2_room_8", .x = 416, .y = 48, .choices = &.{} },
        .{ .want = "ve2_room_6", .x = 56, .y = 48, .choices = &.{} },
        .{ .want = "ve2_room_4", .x = 136, .y = 32, .choices = &.{} },
        .{ .want = "ve2_room_3", .x = 216, .y = 240, .choices = &.{} },
        .{ .want = "ve2_room_0", .x = 88, .y = 480, .choices = &.{} },
        .{ .want = "world_e", .x = 384, .y = 728, .choices = &.{} },
        .{ .want = "ve1_room_0", .x = 576, .y = 320, .choices = &.{} },
        .{ .want = null, .x = 336, .y = 496, .choices = &.{} },
    });
    try interactFacing(state, .up, &.{});
    try std.testing.expect(scenarioBitSet(state, 204, 1));
    try walkContinuousHop(allocator, state, "ve1_room_3", 560, 504, &.{});
    try walkContinuousHop(allocator, state, null, 168, 232, &.{});
    try interactFacing(state, .up, &.{0});
    for (state.combat.progress.party) |member| {
        try std.testing.expectEqual(member.max_hp, member.hp);
        try std.testing.expectEqual(member.max_rune_charges, member.rune_charges);
    }
    try walkContinuousHop(allocator, state, "ve1_room_0", 136, 304, &.{});
    try walkContinuousHop(allocator, state, "ve1_room_5", 152, 536, &.{});
    try walkContinuousHop(allocator, state, null, 184, 216, &.{});
    try interactService(state, .up);
    for (state.combat.progress.party, 0..) |*member, index| {
        for (0..2) |_| {
            if (member.inventory.count() == member.inventory.slots.len) break;
            try buyStockItem(state, .mega_medicine, index);
        }
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkContinuousHop(allocator, state, "ve1_room_0", 184, 304, &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "world_e", .x = 344, .y = 704, .choices = &.{} },
        .{ .want = "ve6_room_0", .x = 424, .y = 624, .choices = &.{} },
        .{ .want = null, .x = 440, .y = 136, .choices = &.{1} },
    });
    try drainStoryAndEvents(state, "ve3_room_1", &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "ve3_room_2", .x = 248, .y = 56, .choices = &.{} },
        .{ .want = "ve3_room_4", .x = 280, .y = 56, .choices = &.{} },
        .{ .want = "ve3_room_3", .x = 184, .y = 184, .choices = &.{} },
        .{ .want = "ve3_room_5", .x = 248, .y = 376, .choices = &.{} },
        .{ .want = null, .x = 192, .y = 120, .choices = &.{} },
    });
    var door_choice: usize = 0;
    _ = try walkStep(state, .up, &.{0}, &door_choice);
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEventCursor(state, &.{0}, &door_choice);
    try std.testing.expectEqual(@as(usize, 1), door_choice);
    try std.testing.expect(scenarioBitSet(state, 206, 8));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "ve3_room_9", .x = 192, .y = 80, .choices = &.{} },
        .{ .want = "ve3_room_10", .x = 152, .y = 80, .choices = &.{} },
        .{ .want = "ve3_room_27", .x = 776, .y = 184, .choices = &.{} },
        .{ .want = "ve3_room_11", .x = 152, .y = 200, .choices = &.{} },
        .{ .want = "ve3_room_14", .x = 208, .y = 312, .choices = &.{} },
        .{ .want = "ve3_room_11", .x = 152, .y = 80, .choices = &.{} },
        .{ .want = "ve3_room_15", .x = 88, .y = 96, .choices = &.{} },
        .{ .want = "ve3_room_20", .x = 744, .y = 72, .choices = &.{} },
        .{ .want = "ve3_room_21", .x = 152, .y = 96, .choices = &.{} },
        .{ .want = "ve3_room_22", .x = 208, .y = 176, .choices = &.{} },
        .{ .want = "ve3_room_15", .x = 152, .y = 192, .choices = &.{} },
        .{ .want = "ve3_room_23", .x = 408, .y = 368, .choices = &.{} },
    });
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expectEqual(journey.Mode.battle, state.mode);
    try std.testing.expectEqualStrings("ve3_dir_8ddac_1", state.combat.content.encounters[state.combat.encounter].id);
    try finishBattleWithInput(state, .travel);
    _ = try drainFieldEvent(state, &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expect(scenarioBitSet(state, 206, 16));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "ve3_room_15", .x = 312, .y = 512, .choices = &.{} },
        .{ .want = "ve3_room_22", .x = 48, .y = 72, .choices = &.{} },
        .{ .want = "ve3_room_21", .x = 152, .y = 96, .choices = &.{} },
        .{ .want = "ve3_room_20", .x = 752, .y = 176, .choices = &.{} },
        .{ .want = "ve3_room_15", .x = 152, .y = 192, .choices = &.{} },
        .{ .want = "ve3_room_11", .x = 416, .y = 136, .choices = &.{} },
        .{ .want = "ve3_room_14", .x = 184, .y = 152, .choices = &.{} },
        .{ .want = "ve3_room_11", .x = 152, .y = 272, .choices = &.{} },
        .{ .want = "ve3_room_27", .x = 424, .y = 184, .choices = &.{} },
        .{ .want = "ve3_room_10", .x = 152, .y = 80, .choices = &.{} },
        .{ .want = "ve3_room_9", .x = 184, .y = 184, .choices = &.{} },
        .{ .want = "ve3_room_5", .x = 152, .y = 224, .choices = &.{} },
        .{ .want = "ve3_room_3", .x = 184, .y = 328, .choices = &.{} },
        .{ .want = "ve3_room_4", .x = 88, .y = 64, .choices = &.{} },
        .{ .want = "ve3_room_2", .x = 776, .y = 184, .choices = &.{} },
        .{ .want = "ve3_room_1", .x = 120, .y = 136, .choices = &.{} },
        .{ .want = "ve6_room_0", .x = 248, .y = 480, .choices = &.{} },
    });
    // The castle exit lands inside Viktor's farewell trigger.
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{1});
    try std.testing.expect(scenarioBitSet(state, 206, 4));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "world_e", .x = 312, .y = 496, .choices = &.{} },
        .{ .want = "ve4_room_0", .x = 648, .y = 192, .choices = &.{} },
        .{ .want = "world_d", .x = 368, .y = 40, .choices = &.{} },
    });
    try crossRegionDToToran(allocator, state);
}

fn finishDragonFlight(state: *journey.State, destination: []const u8) !void {
    const active = state.auto_travel orelse return error.MissingScriptedFlight;
    try std.testing.expect(active.flight);
    for (0..2000) |_| {
        if (state.auto_travel == null) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
    } else return error.ScriptedFlightTimeout;
    try std.testing.expectEqualStrings(destination, currentRoomName(state));
    try std.testing.expectEqual(@as(u8, 0), state.field_state.progress.story.scenario.?.world_mode);
}

noinline fn playDragonKnightsAndMoravia(allocator: std.mem.Allocator, state: *journey.State) !void {
    // 3. Council -> Seekers / Dragon Knights -> Dragons' Den -> Dragon Fortress -> Toran.
    try walkFromToranDockToCouncil(allocator, state);
    try walkContinuousHop(allocator, state, null, 480, 160, &.{});
    try interactFacing(state, .up, &.{});
    try drainStoryAndEvents(state, "vb5b3_room_0", &.{1});
    try std.testing.expect(scenarioBitSet(state, 207, 1));
    try std.testing.expect(scenarioBitSet(state, 232, 4));
    // Reenter the hall after the briefing changes which actors are staged.
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vb5b3_room_2", .x = 328, .y = 56, .choices = &.{} },
        .{ .want = "vb5b3_room_0", .x = 248, .y = 224, .choices = &.{} },
        .{ .want = null, .x = 544, .y = 424, .choices = &.{} },
    });
    try interactFacing(state, .left, &.{});
    try std.testing.expect(scenarioBitSet(state, 44, 2));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{0});
    if (state.combat.partyCount() == 6) try makeRoomForRecruit(state, null);
    try finishHeadquartersPartySelection(state, "liukan", null);
    try std.testing.expectEqualStrings("liukan", state.combat.progress.party[state.combat.partyCount() - 1].id);
    try crossToranToRegionD(allocator, state);
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vf1_room_0", .x = 240, .y = 264, .choices = &.{} },
        .{ .want = null, .x = 160, .y = 168, .choices = &.{} },
    });
    try interactFacing(state, .up, &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "world_d", .x = 184, .y = 312, .choices = &.{} },
        .{ .want = "vd1_room_0", .x = 608, .y = 400, .choices = &.{} },
        .{ .want = null, .x = 376, .y = 464, .choices = &.{} },
    });
    try interactFacing(state, .up, &.{1});
    try drainStoryAndEvents(state, "vd1_room_0", &.{});
    try walkContinuousHop(allocator, state, "vd1_room_6", 544, 448, &.{});
    try walkContinuousHop(allocator, state, null, 128, 120, &.{});
    try interactFacing(state, .up, &.{0});
    for (state.combat.progress.party) |member| {
        try std.testing.expectEqual(member.max_hp, member.hp);
        try std.testing.expectEqual(member.max_rune_charges, member.rune_charges);
    }
    try walkContinuousHop(allocator, state, "vd1_room_0", 184, 224, &.{});
    try walkContinuousHop(allocator, state, "vd1_room_4", 128, 128, &.{});
    try walkContinuousHop(allocator, state, null, 240, 120, &.{});
    try interactService(state, .up);
    for (state.combat.progress.party, 0..) |*member, index| {
        while (member.inventory.count() < member.inventory.slots.len) {
            try buyStockItem(state, .mega_medicine, index);
        }
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkContinuousHop(allocator, state, "vd1_room_0", 184, 224, &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "world_d", .x = 384, .y = 592, .choices = &.{} },
        .{ .want = "vf1_room_0", .x = 240, .y = 264, .choices = &.{} },
        .{ .want = null, .x = 160, .y = 184, .choices = &.{} },
    });
    try interactFacing(state, .up, &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = null, .x = 312, .y = 200, .choices = &.{} },
        .{ .want = "vf1_room_1", .x = 312, .y = 184, .choices = &.{0} },
        .{ .want = "vf1_room_2", .x = 168, .y = 64, .choices = &.{} },
        .{ .want = "vf1_room_3", .x = 96, .y = 64, .choices = &.{} },
        .{ .want = "vf1_room_4", .x = 200, .y = 48, .choices = &.{} },
        .{ .want = "vf1_room_5", .x = 208, .y = 64, .choices = &.{} },
        .{ .want = "vf1_room_6", .x = 136, .y = 104, .choices = &.{} },
        .{ .want = "vf1_room_7", .x = 184, .y = 48, .choices = &.{} },
        .{ .want = "vf1_room_8", .x = 40, .y = 240, .choices = &.{} },
        .{ .want = "vf1_room_9", .x = 8, .y = 360, .choices = &.{} },
        .{ .want = "vf1_room_10", .x = 144, .y = 344, .choices = &.{} },
        .{ .want = "world_f", .x = 176, .y = 240, .choices = &.{} },
        .{ .want = "vf3_room_0", .x = 608, .y = 376, .choices = &.{} },
        .{ .want = "vf3_room_1", .x = 248, .y = 232, .choices = &.{} },
        .{ .want = "vf3_room_2", .x = 40, .y = 264, .choices = &.{} },
        .{ .want = "vf1_room_8", .x = 136, .y = 264, .choices = &.{0} },
        .{ .want = null, .x = 16, .y = 368, .choices = &.{} },
        .{ .want = "vf1_room_9", .x = 8, .y = 360, .choices = &.{} },
        .{ .want = "vf1_room_10", .x = 144, .y = 344, .choices = &.{} },
        .{ .want = "world_f", .x = 176, .y = 240, .choices = &.{} },
        .{ .want = "vf3_room_0", .x = 608, .y = 376, .choices = &.{} },
        .{ .want = "world_f", .x = 200, .y = 384, .choices = &.{} },
    });
    try finishDragonFlight(state, "vf2_room_0");
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vf2_room_1", .x = 344, .y = 104, .choices = &.{} },
        .{ .want = "vf2_room_3", .x = 408, .y = 248, .choices = &.{} },
        .{ .want = "vf2_room_4", .x = 104, .y = 32, .choices = &.{} },
        .{ .want = "vf2_room_8", .x = 160, .y = 32, .choices = &.{} },
        .{ .want = "vf2_room_9", .x = 8, .y = 152, .choices = &.{} },
        .{ .want = null, .x = 304, .y = 128, .choices = &.{} },
        .{ .want = "vf2_room_10", .x = 168, .y = 32, .choices = &.{} },
        .{ .want = "vf4_room_0", .x = 224, .y = 24, .choices = &.{} },
        .{ .want = "vf2_room_10", .x = 240, .y = 352, .choices = &.{ 1, 0 } },
        .{ .want = "vf2_room_9", .x = 104, .y = 344, .choices = &.{} },
        .{ .want = "vf2_room_8", .x = 368, .y = 96, .choices = &.{} },
        .{ .want = "vf2_room_4", .x = 152, .y = 344, .choices = &.{} },
        .{ .want = "vf2_room_3", .x = 224, .y = 312, .choices = &.{} },
        .{ .want = "vf2_room_1", .x = 224, .y = 32, .choices = &.{} },
        .{ .want = "vf2_room_0", .x = 8, .y = 64, .choices = &.{} },
        .{ .want = "world_f", .x = 152, .y = 144, .choices = &.{} },
    });
    try finishDragonFlight(state, "vf3_room_0");
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vf3_room_1", .x = 248, .y = 232, .choices = &.{} },
        .{ .want = "vf3_room_2", .x = 40, .y = 264, .choices = &.{} },
        .{ .want = null, .x = 184, .y = 184, .choices = &.{} },
    });
    try interactFacing(state, .up, &.{});
    try drainStoryAndEvents(state, "va9_room_0", &.{});
    for (0..32) |_| {
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (state.field_event != null) _ = try drainFieldEvent(state, &.{});
        if (scenarioBitSet(state, 210, 2)) break;
    } else return error.TigerwolfArrivalTimeout;
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "va9_room_1", .x = 184, .y = 368, .choices = &.{} },
        .{ .want = null, .x = 280, .y = 184, .choices = &.{} },
    });
    // Step right inside va9_room_1 trigger zone for pressed_mask right (0x2000).
    var va9_cursor: usize = 0;
    try std.testing.expect(try walkStep(state, .right, &.{}, &va9_cursor) or scenarioBitSet(state, 210, 4));
    if (state.field_event != null) _ = try drainFieldEvent(state, &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "va9_room_0", .x = 248, .y = 32, .choices = &.{} },
        .{ .want = "vf3_room_2", .x = 184, .y = 368, .choices = &.{} },
        .{ .want = "vf3_room_1", .x = 184, .y = 120, .choices = &.{} },
        .{ .want = "vf3_room_2", .x = 40, .y = 264, .choices = &.{} },
        .{ .want = null, .x = 184, .y = 176, .choices = &.{} },
    });
    try interactFacing(state, .up, &.{1}); // Walk back through Seek Valley.
    try std.testing.expect(scenarioBitSet(state, 208, 128));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vf3_room_1", .x = 56, .y = 296, .choices = &.{} },
        .{ .want = "vf3_room_0", .x = 184, .y = 384, .choices = &.{} },
        .{ .want = "world_f", .x = 400, .y = 472, .choices = &.{} },
        .{ .want = "vf1_room_10", .x = 752, .y = 408, .choices = &.{} },
        .{ .want = "vf1_room_9", .x = 152, .y = 72, .choices = &.{} },
        .{ .want = "vf1_room_8", .x = 288, .y = 64, .choices = &.{} },
        .{ .want = "vf1_room_7", .x = 192, .y = 48, .choices = &.{} },
        .{ .want = "vf1_room_6", .x = 392, .y = 240, .choices = &.{} },
        .{ .want = "vf1_room_5", .x = 168, .y = 320, .choices = &.{} },
        .{ .want = "vf1_room_4", .x = 72, .y = 360, .choices = &.{} },
        .{ .want = "vf1_room_3", .x = 40, .y = 376, .choices = &.{} },
        .{ .want = "vf1_room_2", .x = 192, .y = 360, .choices = &.{} },
        .{ .want = "vf1_room_1", .x = 88, .y = 360, .choices = &.{} },
        .{ .want = "vf1_room_0", .x = 144, .y = 360, .choices = &.{} },
        .{ .want = "world_d", .x = 184, .y = 312, .choices = &.{} },
    });
    try walkFromRegionDToKaku(allocator, state);
    try restInKaku(allocator, state);
    try crossKakuToToran(allocator, state, null);

    // 4. Found the Founding-hall council -> Kasim/Northern Checkpoint -> Moravia -> Toran.
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vb5bg_room_1", .x = 128, .y = 168, .choices = &.{} },
        .{ .want = "vb5bg_room_7", .x = 328, .y = 328, .choices = &.{} },
        .{ .want = "vb5b1_room_0", .x = 248, .y = 224, .choices = &.{} },
        .{ .want = "vb5b1_room_6", .x = 216, .y = 56, .choices = &.{} },
        .{ .want = "vb5b2_room_0", .x = 248, .y = 224, .choices = &.{} },
        .{ .want = "vb5b2_room_4", .x = 312, .y = 56, .choices = &.{} },
        .{ .want = "vb5b3_room_4", .x = 248, .y = 224, .choices = &.{} },
    });
    try drainStoryAndEvents(state, "vb5b3_room_0", &.{1});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vb5b3_room_3", .x = 200, .y = 56, .choices = &.{} },
        .{ .want = "vb5b4_room_0", .x = 248, .y = 224, .choices = &.{} },
        .{ .want = "vb5b4_room_1", .x = 8, .y = 320, .choices = &.{} },
        .{ .want = "vb5b4_room_3", .x = 8, .y = 128, .choices = &.{} },
        .{ .want = null, .x = 184, .y = 248, .choices = &.{} },
    });
    var briefing_choice: usize = 0;
    try std.testing.expect(try walkStep(state, .up, &.{1}, &briefing_choice));
    try std.testing.expectEqual(@as(usize, 1), briefing_choice);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try drainStoryAndEvents(state, "vb5b4_room_3", &.{});
    try std.testing.expect(scenarioBitSet(state, 29, 2));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vb5b4_room_1", .x = 360, .y = 272, .choices = &.{} },
        .{ .want = "vb5b4_room_0", .x = 360, .y = 128, .choices = &.{} },
        .{ .want = "vb5b4_room_2", .x = 216, .y = 56, .choices = &.{} },
        .{ .want = "vb5b3_room_0", .x = 136, .y = 224, .choices = &.{} },
        .{ .want = null, .x = 544, .y = 424, .choices = &.{} },
    });
    try interactFacing(state, .left, &.{0});
    try std.testing.expectEqualStrings("vh2_room_0", currentRoomName(state));
    try drainStoryAndEvents(state, "vd7_room_0", &.{});
    for (0..32) |_| {
        if (state.mode != .field) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(state, &.{});
    }
    try finishCampaignWar(state, "northern_checkpoint", .side0_victory);
    try drainStoryAndEvents(state, "vb5b4_room_0", &.{0});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vd7_room_0", .x = 264, .y = 160, .choices = &.{} },
        .{ .want = "world_h", .x = 264, .y = 40, .choices = &.{} },
        .{ .want = "vh1_room_0", .x = 712, .y = 600, .choices = &.{} },
        .{ .want = "vh1_room_1", .x = 248, .y = 224, .choices = &.{} },
        .{ .want = "vh1_room_2", .x = 8, .y = 224, .choices = &.{} },
        .{ .want = "vh1_room_3", .x = 120, .y = 40, .choices = &.{} },
        .{ .want = "vh1_room_4", .x = 216, .y = 40, .choices = &.{} },
        .{ .want = "vh1_room_7", .x = 216, .y = 40, .choices = &.{} },
        .{ .want = "vh1_room_8", .x = 120, .y = 224, .choices = &.{} },
        .{ .want = "vh1_room_9", .x = 184, .y = 488, .choices = &.{} },
        .{ .want = "vh1_room_6", .x = 72, .y = 208, .choices = &.{} },
        .{ .want = "vh1_room_15", .x = 344, .y = 568, .choices = &.{} },
        .{ .want = "vh1_room_10", .x = 128, .y = 48, .choices = &.{} },
        .{ .want = "vh1_room_11", .x = 184, .y = 48, .choices = &.{} },
        .{ .want = "vh1_room_6", .x = 72, .y = 208, .choices = &.{} },
        .{ .want = "vh1_room_12", .x = 72, .y = 232, .choices = &.{} },
        .{ .want = "vh1_room_6", .x = 296, .y = 208, .choices = &.{} },
        .{ .want = "vh1_room_13", .x = 328, .y = 216, .choices = &.{} },
    });
    try drainStoryAndEvents(state, "vh1_room_5", &.{});
    try drainStoryAndEvents(state, "world_h", &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vd7_room_0", .x = 768, .y = 792, .choices = &.{} },
        .{ .want = "world_d", .x = 264, .y = 552, .choices = &.{0} },
    });
    for ([_]usize{ 82, 83 }) |index| {
        try std.testing.expect(state.combat.progress.story.scenario.?.recruit_flags[index] & 1 != 0);
    }
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vd1_room_0", .x = 608, .y = 400, .choices = &.{} },
        .{ .want = "vd1_room_4", .x = 128, .y = 128, .choices = &.{} },
        .{ .want = null, .x = 240, .y = 120, .choices = &.{} },
    });
    try interactService(state, .up);
    for ([_]usize{ 1, 2, 5 }) |member| {
        const inventory = &state.combat.progress.party[member].inventory;
        for (0..2) |_| {
            if (inventory.count() == inventory.slots.len) break;
            try buyStockItem(state, .mega_medicine, member);
        }
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vd1_room_0", .x = 184, .y = 224, .choices = &.{} },
        .{ .want = "world_d", .x = 384, .y = 592, .choices = &.{} },
    });
    try walkFromRegionDToKaku(allocator, state);
    try restInKaku(allocator, state);
    try crossKakuToToran(allocator, state, null);
}

fn buyGregminsterSupplies(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkContinuousHop(allocator, state, "vac_room_6", 1008, 608, &.{});
    try walkContinuousHop(allocator, state, null, 88, 152, &.{});
    try interactService(state, .up);
    for (state.combat.progress.party, 0..) |*member, slot| {
        if (member.hp == 0) continue;
        const revival_items: usize = switch (slot) {
            0 => 3,
            4 => 2,
            else => 1,
        };
        for (0..revival_items) |_| {
            if (member.inventory.count() == member.inventory.slots.len) break;
            try buyStockItem(state, .sacrificial_buddha, slot);
        }
        if (slot != 0) while (member.inventory.count() < member.inventory.slots.len) {
            try buyStockItem(state, .mega_medicine, slot);
        };
    }
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try walkContinuousHop(allocator, state, "vac_room_0", 88, 272, &.{});
}

fn restOutsideGregminster(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vad_room_10", .x = 312, .y = 744, .choices = &.{} },
        .{ .want = "vac_room_0", .x = 184, .y = 232, .choices = &.{} },
        .{ .want = "world_z", .x = 808, .y = 872, .choices = &.{} },
        .{ .want = "vz2_room_0", .x = 832, .y = 408, .choices = &.{} },
        .{ .want = "vz2_room_4", .x = 288, .y = 544, .choices = &.{} },
        .{ .want = null, .x = 112, .y = 272, .choices = &.{} },
    });
    try interactFacing(state, .up, &.{0});
    for (state.combat.progress.party) |member| {
        try std.testing.expectEqual(member.max_hp, member.hp);
        try std.testing.expectEqual(member.max_rune_charges, member.rune_charges);
    }
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vz2_room_0", .x = 120, .y = 368, .choices = &.{} },
        .{ .want = "world_z", .x = 248, .y = 624, .choices = &.{} },
        .{ .want = "vac_room_0", .x = 584, .y = 384, .choices = &.{} },
    });
    try buyGregminsterSupplies(allocator, state);
    try walkContinuousHop(allocator, state, "vac_room_17", 808, 48, &.{});
    try walkContinuousHop(allocator, state, "vad_room_0", 184, 48, &.{});
}

fn walkImperialPalaceHall(allocator: std.mem.Allocator, state: *journey.State) !void {
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vad_room_1", .x = 312, .y = 96, .choices = &.{} },
        .{ .want = null, .x = 280, .y = 352, .choices = &.{} },
        .{ .want = "vad_room_2", .x = 40, .y = 88, .choices = &.{} },
        .{ .want = "vad_room_3", .x = 584, .y = 24, .choices = &.{} },
        .{ .want = null, .x = 280, .y = 344, .choices = &.{} },
        .{ .want = null, .x = 280, .y = 200, .choices = &.{} },
        .{ .want = "vad_room_5", .x = 280, .y = 24, .choices = &.{} },
        .{ .want = null, .x = 232, .y = 512, .choices = &.{} },
        .{ .want = null, .x = 232, .y = 320, .choices = &.{} },
        .{ .want = null, .x = 232, .y = 208, .choices = &.{} },
        .{ .want = "vad_room_6", .x = 56, .y = 24, .choices = &.{} },
        .{ .want = null, .x = 920, .y = 224, .choices = &.{} },
        .{ .want = null, .x = 808, .y = 144, .choices = &.{} },
        .{ .want = null, .x = 616, .y = 144, .choices = &.{} },
        .{ .want = null, .x = 424, .y = 144, .choices = &.{} },
        .{ .want = null, .x = 200, .y = 144, .choices = &.{} },
        .{ .want = "vad_room_7", .x = 40, .y = 32, .choices = &.{} },
    });
}

noinline fn playShasarazadeToCredits(allocator: std.mem.Allocator, state: *journey.State) !void {
    // 5. Return Viktor & rescue preparations -> Shasarazade -> Sonya / Fortress -> Gregminster.
    try walkFromToranDockToCouncil(allocator, state);
    try std.testing.expectEqualStrings("vb5c4_room_0", currentRoomName(state));
    try walkContinuousHop(allocator, state, null, 400, 376, &.{});
    try interactFacing(state, .up, &.{1});
    try drainStoryAndEvents(state, "vb5cg_room_2", &.{});
    try drainStoryAndEvents(state, "vb5c4_room_0", &.{});
    try drainStoryAndEvents(state, "vb5cg_room_3", &.{});
    try drainStoryAndEvents(state, "vb9_room_0", &.{});
    try drainStoryAndEvents(state, "vb5c3_room_2", &.{});
    try drainStoryAndEvents(state, "vb5cg_room_2", &.{});
    try drainStoryAndEvents(state, "vb5c3_room_0", &.{});
    try drainStoryAndEvents(state, "vb5c4_room_3", &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    try drainStoryAndEvents(state, "vb5c4_room_3", &.{});
    try std.testing.expect(scenarioBitSet(state, 31, 32));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vb5c4_room_1", .x = 360, .y = 272, .choices = &.{} },
        .{ .want = "vb5c4_room_0", .x = 360, .y = 128, .choices = &.{} },
        .{ .want = "vb5c4_room_2", .x = 184, .y = 56, .choices = &.{} },
        .{ .want = "vb5c3_room_0", .x = 136, .y = 224, .choices = &.{} },
        .{ .want = "vb5c3_room_2", .x = 376, .y = 56, .choices = &.{} },
        .{ .want = "vb5c2_room_0", .x = 136, .y = 224, .choices = &.{} },
        .{ .want = "vb5c2_room_3", .x = 184, .y = 56, .choices = &.{} },
        .{ .want = "vb5c1_room_0", .x = 136, .y = 224, .choices = &.{} },
        .{ .want = "vb5c1_room_7", .x = 344, .y = 56, .choices = &.{} },
        .{ .want = "vb5cg_room_1", .x = 136, .y = 224, .choices = &.{} },
        .{ .want = "vb5cg_room_0", .x = 192, .y = 616, .choices = &.{} },
    });
    try drainStoryAndEvents(state, "vb5c4_room_0", &.{});
    try drainStoryAndEvents(state, null, &.{1});
    try finishCampaignWar(state, "shasarazade", .side0_victory);
    try std.testing.expectEqualStrings("vs2_room_0", currentRoomName(state));
    if (state.combat.partyRow(0) == .front and state.combat.partyRow(3) == .back) {
        try swapFieldFormation(state, state.combat.formationSlot(0), state.combat.formationSlot(3));
        try std.testing.expectEqual(.back, state.combat.partyRow(0));
    }
    try walkContinuousHop(allocator, state, null, 344, 184, &.{});
    try stepToCoord(state, .up);
    try std.testing.expectEqualStrings("vs1_room_1", currentRoomName(state));
    try walkContinuousHop(allocator, state, null, 160, 208, &.{});
    try stepToCoord(state, .left);
    try std.testing.expectEqualStrings("vs1_room_2", currentRoomName(state));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vs1_room_3", .x = 280, .y = 536, .choices = &.{} },
        .{ .want = "vs1_room_4", .x = 8, .y = 256, .choices = &.{} },
        .{ .want = "vs1_room_5", .x = 296, .y = 432, .choices = &.{} },
        .{ .want = "vs1_room_6", .x = 8, .y = 304, .choices = &.{} },
        .{ .want = null, .x = 152, .y = 280, .choices = &.{} },
        .{ .want = null, .x = 152, .y = 320, .choices = &.{} },
        .{ .want = "vs1_room_5", .x = 304, .y = 40, .choices = &.{} },
        .{ .want = "vs1_room_4", .x = 8, .y = 72, .choices = &.{} },
        .{ .want = "vs1_room_3", .x = 304, .y = 80, .choices = &.{} },
        .{ .want = "vs1_room_2", .x = 8, .y = 136, .choices = &.{} },
        .{ .want = null, .x = 208, .y = 208, .choices = &.{} },
    });
    var sonya_choice: usize = 0;
    try std.testing.expect(try walkStep(state, .up, &.{0}, &sonya_choice));
    try std.testing.expectEqual(@as(usize, 1), sonya_choice);
    try std.testing.expectEqual(journey.Mode.battle, state.mode);
    try finishBattleWithInput(state, .travel);
    _ = try drainFieldEvent(state, &.{});
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = null, .x = 208, .y = 208, .choices = &.{} },
        .{ .want = "vs1_room_1", .x = 248, .y = 152, .choices = &.{} },
    });
    try walkContinuousHop(allocator, state, null, 184, 320, &.{});
    try stepToCoord(state, .down);
    try std.testing.expectEqualStrings("vs2_room_0", currentRoomName(state));
    try drainStoryAndEvents(state, "vb5cg_room_0", &.{});
    try crossToranToKaku(allocator, state);
    try restInKaku(allocator, state);
    const rested_hero = state.combat.progress.party[0];
    try std.testing.expectEqual(rested_hero.max_rune_charges, rested_hero.rune_charges);
    try crossKakuToToran(allocator, state, "vb5cg_room_0");

    // 6. Final council -> Gregminster siege war -> Imperial Palace -> Escape -> Both endings.
    try walkFromToranDockToCouncil(allocator, state);
    try std.testing.expectEqualStrings("vb5c4_room_0", currentRoomName(state));
    try walkContinuousHop(allocator, state, null, 400, 376, &.{});
    try interactFacing(state, .up, &.{1});
    try drainStoryAndEvents(state, "vb5c4_room_8", &.{});
    try drainStoryAndEvents(state, "vb5cc_room_3", &.{});
    try drainStoryAndEvents(state, "vb5bg_room_0", &.{});
    try drainStoryAndEvents(state, "vb5c4_room_0", &.{});
    try std.testing.expect(scenarioBitSet(state, 32, 64));
    try walkContinuousHop(allocator, state, null, 400, 376, &.{});
    try interactFacing(state, .up, &.{1});
    try drainStoryAndEvents(state, "vaad_room_1", &.{});
    try drainStoryAndEvents(state, "vaad_room_0", &.{});
    try drainStoryAndEvents(state, "vaad_room_1", &.{});
    try drainStoryAndEvents(state, "vaad_room_0", &.{0});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try finishCampaignWar(state, "gregminster", .side0_victory);
    try drainStoryAndEvents(state, "vac_room_0", &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try expectPartyOrder(state, &.{ "hero", "viktor", "flik" });
    try finishHeadquartersPartySelectionFill(state, "viktor", &.{ "tengaar", "cleo", "ronnie", "futch" }, 6);
    try std.testing.expectEqual(@as(usize, 6), state.combat.partyCount());
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expect(scenarioBitSet(state, 25, 1 | 2));
    try std.testing.expectEqual(@as(i32, 800), state.field_state.y);
    if (state.combat.partyRow(2) == .front and state.combat.partyRow(5) == .back) {
        try swapFieldFormation(state, state.combat.formationSlot(2), state.combat.formationSlot(5));
        try std.testing.expectEqual(.front, state.combat.partyRow(5));
    }
    try buyGregminsterSupplies(allocator, state);
    try walkContinuousHop(allocator, state, "vac_room_17", 808, 48, &.{});
    try drainStoryAndEvents(state, "vad_room_0", &.{});
    try restOutsideGregminster(allocator, state);
    try walkImperialPalaceHall(allocator, state);
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vad_room_6", .x = 56, .y = 576, .choices = &.{} },
        .{ .want = "vad_room_5", .x = 920, .y = 232, .choices = &.{} },
        .{ .want = "vad_room_3", .x = 232, .y = 616, .choices = &.{} },
        .{ .want = "vad_room_2", .x = 32, .y = 472, .choices = &.{} },
        .{ .want = "vad_room_1", .x = 472, .y = 232, .choices = &.{} },
        .{ .want = "vad_room_0", .x = 280, .y = 832, .choices = &.{} },
    });
    try restOutsideGregminster(allocator, state);
    try walkImperialPalaceHall(allocator, state);
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = null, .x = 416, .y = 384, .choices = &.{} },
        .{ .want = "vad_room_8", .x = 728, .y = 24, .choices = &.{} },
        .{ .want = "vad_room_9", .x = 184, .y = 24, .choices = &.{} },
        .{ .want = null, .x = 152, .y = 440, .choices = &.{} },
    });
    try drainStoryAndEvents(state, "vad_room_9", &.{});
    try std.testing.expectEqualStrings("vzv_dir_194d8_1", state.combat.content.encounters[state.combat.encounter].id);
    try std.testing.expectEqual(.victory, state.combat.phase);
    try std.testing.expect(scenarioBitSet(state, 26, 8));
    try walkContinuousRoute(allocator, state, &.{
        .{ .want = "vad_room_8", .x = 152, .y = 1000, .choices = &.{} },
        .{ .want = "vad_room_7", .x = 264, .y = 1296, .choices = &.{} },
        .{ .want = "vad_room_6", .x = 728, .y = 352, .choices = &.{1} },
        .{ .want = "vad_room_5", .x = 920, .y = 232, .choices = &.{} },
    });
    try drainStoryAndEvents(state, "vac_room_16", &.{1});

    try drainStoryAndEvents(state, "vac_room_15", &.{});
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(state, &.{});
    try std.testing.expectEqual(journey.Mode.ending, state.mode);
    try std.testing.expectEqualStrings("ending:main", state.scripted_battle.?.request.id);
    const ending = state.active_ending.?;
    try std.testing.expect(ending.census.recruited < 108);
    try std.testing.expect(ending.census.absent > 0);
    try std.testing.expectEqual(@as(u8, 2), ending.recruit_flags[2] & 3);
    try std.testing.expectEqual(@as(u8, 2), ending.recruit_flags[6] & 3);
    const confirms = ending.parsed.value.bounded_ending.main_ending_phases + 1;
    for (0..confirms) |_| _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expect(state.active_ending == null and state.scripted_battle == null);
}

test "canonical duel art presentation and headless battle duel war transitions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var harness = try CanonicalHarness.load(allocator, io);
    defer harness.deinit();

    const duel_art = harness.bundle.duel_art orelse return error.MissingDuelArt;
    try std.testing.expectEqualStrings(journey_content.duel_presentation.extracted_origin, duel_art.art_origin.?);
    const dims = try pngDimensions(io, allocator, "../kit/work/build/canonical/" ++ journey_content.duel_presentation.atlas_path);
    try duel_art.validateAtlas(dims[0], dims[1]);

    var duel_rules = try journey.duel.load(allocator, journey.duel.content_json);
    defer duel_rules.deinit();
    try duel_art.validate(duel_rules.value);

    for ([_][]const u8{ "pahn_teo", "shu_kwanda", "shu_teo" }) |duel_id| {
        const scene = duel_art.scene(duel_id) orelse return error.MissingDuelScene;
        try std.testing.expect(scene.backdrop == null);
        try std.testing.expect(scene.gauges != null);
        for (scene.gauges.?) |gauge| {
            try std.testing.expectEqual(@as(i32, 128), gauge.w);
            try std.testing.expectEqual(@as(i32, 32), gauge.h);
            try std.testing.expect(gauge.x >= 0 and gauge.y >= 0);
            try std.testing.expect(gauge.x + gauge.w <= dims[0] and gauge.y + gauge.h <= dims[1]);
        }
        var sample = try journey.duel.State.init(&duel_rules.value, duel_id, .{
            .{ .maximum_hp = 240, .hp = 240, .attack = 160, .defense = 80 },
            .{ .maximum_hp = 240, .hp = 240, .attack = 160, .defense = 80 },
        }, .{ .bios_state = 1 });
        for ([_]journey.duel.Side{ .player, .opponent }) |side| {
            try expectDuelFrameInAtlas(scene.frame(sample, side, 0), dims[0], dims[1]);
        }
        try sample.choose(.attack);
        try sample.tick();
        try std.testing.expectEqual(journey.duel.Phase.exchange, sample.phase);
        for ([_]journey.duel.Side{ .player, .opponent }) |side| {
            try expectDuelFrameInAtlas(scene.frame(sample, side, 1), dims[0], dims[1]);
        }
        sample.phase = .finished;
        sample.loser = .opponent;
        sample.outcome = .victory;
        sample.timer = 0;
        for ([_]journey.duel.Side{ .player, .opponent }) |side| {
            try expectDuelFrameInAtlas(scene.frame(sample, side, 100), dims[0], dims[1]);
        }
    }

    var members: [6]battle.Member = undefined;
    var state = try harness.newState(&members);
    defer state.deinitActiveModes();
    const baseline = try journey.Snapshot.capture(state);

    // 1. All 3 duels + Teo fire spear war round-trips back to field.
    for (0..50) |_| state.combat.levelUp(0, .{ 16, 16, 16, 16, 16, 16, 16 });
    state.combat.progress.party[0].hp = state.combat.progress.party[0].max_hp;
    const leveled = try journey.Snapshot.capture(state);

    try leveled.apply(&state);
    setScenarioBit(&state, 18, 64);
    state.field_state.enterRoom(state.package.roomIndex("vc6_room_14").?, .{ .x = 248, .y = 288 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try finishActiveDuel(&state, "shu_kwanda", true, &.{});
    for (0..3) |_| {
        if (scenarioBitSet(&state, 19, 4)) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expect(scenarioBitSet(&state, 19, 2 | 4));

    try baseline.apply(&state);
    try state.joinPartyMember(&members, state.party_catalog.?, state.party_bindings, "pahn");
    while (state.combat.progress.party[1].level < 75) {
        var rolls: [7]u15 = undefined;
        for (&rolls) |*roll| roll.* = state.combat.roll();
        state.combat.levelUp(1, rolls);
    }
    state.combat.progress.story.scenario.?.markCharacterLoaded(6);
    state.combat.progress.story.scenario.?.castle_tier = 2;
    state.combat.progress.story.recruitment_tier = 2;
    setScenarioBit(&state, 194, 1);
    setScenarioBit(&state, 230, 64);
    setScenarioBit(&state, 232, 1);
    state.field_state.enterRoom(state.package.roomIndex("vb7d_room_0").?, .{ .x = 160, .y = 160 });
    state.field_state.setWorldEntry(state.package, "world_b_point_41");
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{1});
    try finishActiveDuel(&state, "pahn_teo", true, &.{});
    for (0..3) |_| {
        if (std.mem.eql(u8, currentRoomName(&state), "vb5b3_room_0")) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expectEqual(@as(u8, 1), state.field_state.progress.story.scenario.?.scenario[34] & 3);
    try std.testing.expectEqualStrings("vb5b3_room_0", currentRoomName(&state));

    try leveled.apply(&state);
    state.combat.progress.story.scenario.?.castle_tier = 2;
    state.combat.progress.story.recruitment_tier = 2;
    const before_rematch_slots = state.combat.progress.story.scenario.?.soul_eater_spell_slots;
    setScenarioBit(&state, 200, 2);
    state.field_state.enterRoom(state.package.roomIndex("vb5b3_room_0").?, .{ .x = 480, .y = 200 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    try interactFacing(&state, .up, &.{0});
    try finishCampaignWar(&state, "teo_fire_spear", .scripted_completion);
    try std.testing.expectEqualStrings("vb7d_room_1", currentRoomName(&state));
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{0});
    try finishActiveDuel(&state, "shu_teo", true, &.{});
    for (0..3) |_| {
        if (std.mem.eql(u8, currentRoomName(&state), "vb5bg_room_0")) break;
        _ = try state.tickWithFieldEvents(.{}, .{});
        if (state.field_event != null) _ = try drainFieldEvent(&state, &.{});
    }
    try std.testing.expectEqualStrings("vb5bg_room_0", currentRoomName(&state));
    try std.testing.expect(scenarioBitSet(&state, 34, 4));
    try std.testing.expectEqual(before_rematch_slots + 1, state.combat.progress.story.scenario.?.soul_eater_spell_slots);

    // 2. Late-game wars: northern_checkpoint, shasarazade, gregminster.
    try baseline.apply(&state);
    setScenarioBit(&state, 29, 4);
    state.field_state.enterRoom(state.package.roomIndex("vd7_room_0").?, .{ .x = 264, .y = 160 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try finishCampaignWar(&state, "northern_checkpoint", .side0_victory);
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expectEqualStrings("vd7_room_0", currentRoomName(&state));
    try std.testing.expect(scenarioBitSet(&state, 29, 8));

    try baseline.apply(&state);
    setScenarioBit(&state, 232, 32);
    state.field_state.enterRoom(state.package.roomIndex("vb5b3_room_0").?, .{ .x = 480, .y = 144 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{1});
    try finishCampaignWar(&state, "shasarazade", .side0_victory);
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expectEqualStrings("vs2_room_0", currentRoomName(&state));

    try baseline.apply(&state);
    setScenarioBit(&state, 33, 8);
    state.field_state.enterRoom(state.package.roomIndex("vaad_room_0").?, .{ .x = 160, .y = 160 });
    state.enterEncounterRoom();
    try state.initializeRoomVisit();
    _ = try state.tickWithFieldEvents(.{}, .{});
    _ = try drainFieldEvent(&state, &.{});
    try finishCampaignWar(&state, "gregminster", .side0_victory);
    try std.testing.expectEqual(journey.Mode.field, state.mode);
    try std.testing.expectEqualStrings("vaad_room_1", currentRoomName(&state));

    // 3. Late-game scripted bosses -> field transitions.
    const boss_probes = [_]struct {
        room: []const u8,
        x: i32,
        y: i32,
        byte: usize,
        mask: u8,
        choices: []const u8,
        encounter: []const u8,
        after_room: []const u8,
    }{
        .{ .room = "ve1_room_0", .x = 232, .y = 216, .byte = 203, .mask = 16, .choices = &.{}, .encounter = "ve1_dir_57450_1", .after_room = "ve1_room_1" },
        .{ .room = "ve3_room_23", .x = 312, .y = 480, .byte = 206, .mask = 1, .choices = &.{}, .encounter = "ve3_dir_8ddac_1", .after_room = "ve3_room_23" },
        .{ .room = "vs1_room_6", .x = 152, .y = 280, .byte = 214, .mask = 2, .choices = &.{}, .encounter = "vs1_dir_69554_1", .after_room = "vs1_room_6" },
        .{ .room = "vs1_room_2", .x = 208, .y = 192, .byte = 214, .mask = 4, .choices = &.{0}, .encounter = "vs1_dir_69570_1", .after_room = "vs1_room_2" },
        .{ .room = "vac_room_17", .x = 184, .y = 208, .byte = 25, .mask = 2, .choices = &.{}, .encounter = "vac_dir_66b70_1", .after_room = "vad_room_0" },
        .{ .room = "vad_room_9", .x = 152, .y = 440, .byte = 25, .mask = 8, .choices = &.{}, .encounter = "vzv_dir_194d8_1", .after_room = "vad_room_9" },
    };
    for (boss_probes) |probe| {
        try baseline.apply(&state);
        setScenarioBit(&state, probe.byte, probe.mask);
        state.field_state.enterRoom(state.package.roomIndex(probe.room).?, .{ .x = probe.x, .y = probe.y });
        state.enterEncounterRoom();
        try state.initializeRoomVisit();
        _ = try state.tickWithFieldEvents(.{}, .{});
        _ = try drainFieldEvent(&state, probe.choices);
        try std.testing.expectEqual(journey.Mode.battle, state.mode);
        try std.testing.expectEqualStrings(probe.encounter, state.combat.content.encounters[state.combat.encounter].id);
        try finishBattleWith(&state, .victory);
        for (0..4) |_| {
            if (state.field_event != null and state.mode == .field) {
                _ = try drainFieldEvent(&state, &.{});
            }
            if (state.field_event == null and std.mem.eql(u8, currentRoomName(&state), probe.after_room)) break;
            _ = try state.tickWithFieldEvents(.{}, .{});
        }
        try std.testing.expectEqual(journey.Mode.field, state.mode);
        try std.testing.expectEqualStrings(probe.after_room, currentRoomName(&state));
    }
}
