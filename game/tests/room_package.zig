const std = @import("std");
const field = @import("field");
const saves = @import("save_file");

// Exercise the real exported package without a window, disc or Python runtime.
fn walkTo(state: *field.State, package: field.Package, target_x: i32, target_y: i32) !void {
    const room = package.rooms[state.room];
    const width: usize = @intCast(@divTrunc(room.width, 8));
    const count = room.walkable.len;
    const allocator = std.testing.allocator;
    const previous = try allocator.alloc(?usize, count);
    defer allocator.free(previous);
    @memset(previous, null);
    const queue = try allocator.alloc(usize, count);
    defer allocator.free(queue);
    const start: usize = @intCast(@divTrunc(state.y, 8) * @as(i32, @intCast(width)) + @divTrunc(state.x, 8));
    const target: usize = @intCast(@divTrunc(target_y, 8) * @as(i32, @intCast(width)) + @divTrunc(target_x, 8));
    queue[0] = start;
    previous[start] = start;
    var head: usize = 0;
    var tail: usize = 1;
    while (head < tail and previous[target] == null) : (head += 1) {
        const index = queue[head];
        const x: i32 = @intCast(index % width * 8);
        const y: i32 = @intCast(index / width * 8);
        neighbors: for ([_]field.Point{ .{ .x = x, .y = y - 8 }, .{ .x = x, .y = y + 8 }, .{ .x = x - 8, .y = y }, .{ .x = x + 8, .y = y } }) |point| {
            if (!room.canStand(point.x, point.y)) continue;
            const direction: field.Direction = if (point.x < x) .left else if (point.x > x) .right else if (point.y < y) .up else .down;
            // Avoid taking an unrelated doorway while finding a route to an NPC.
            for (room.exits) |exit| {
                if (exit.direction != null and exit.direction.? != direction) continue;
                if (point.x >= exit.x and point.x < exit.x + exit.w and point.y >= exit.y and point.y < exit.y + exit.h and
                    !(target_x >= exit.x and target_x < exit.x + exit.w and target_y >= exit.y and target_y < exit.y + exit.h)) continue :neighbors;
            }
            const next: usize = @intCast(@divTrunc(point.y, 8) * @as(i32, @intCast(width)) + @divTrunc(point.x, 8));
            if (previous[next] != null) continue;
            previous[next] = index;
            queue[tail] = next;
            tail += 1;
        }
    }
    try std.testing.expect(previous[target] != null);
    var length: usize = 0;
    var cursor = target;
    while (cursor != start) : (cursor = previous[cursor].?) {
        queue[length] = cursor;
        length += 1;
    }
    while (length > 0) {
        length -= 1;
        const next = queue[length];
        const x: i32 = @intCast(next % width * 8);
        const y: i32 = @intCast(next / width * 8);
        const direction: field.Direction = if (x < state.x) .left else if (x > state.x) .right else if (y < state.y) .up else .down;
        for (0..package.step_ticks) |_| state.tick(package, .{ .direction = direction });
        if (state.room != package.roomIndex(room.id).?) {
            for (room.exits) |exit| {
                if (target_x >= exit.x and target_x < exit.x + exit.w and target_y >= exit.y and target_y < exit.y + exit.h and state.room == package.roomIndex(exit.room).?) return;
            }
            return error.UnexpectedSceneChange;
        }
        try std.testing.expectEqual(x, state.x);
        try std.testing.expectEqual(y, state.y);
    }
}

test "real package: walk, talk, close, exit and return" {
    const allocator = std.testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../kit/work/build/first_room/room.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try field.load(allocator, bytes);
    defer parsed.deinit();
    const package = parsed.value;
    var members = [_]field.game_state.Member{.{ .id = "hero", .name = "Hero", .hp = 35, .max_hp = 100, .status = .poisoned, .rune_charges = .{ 0, 0, 0, 0 }, .max_rune_charges = .{ 0, 0, 0, 0 } }};
    var state_progress: field.game_state.Progress = .{ .money = 350, .party = .init(&members) };
    var state = field.State.init(package, &state_progress);
    const inn = try field.inn.load(allocator, field.inn.json);
    defer inn.deinit();
    try state.configureInn(package, inn.value);
    try std.testing.expectEqualStrings("vb6_inn", package.rooms[state.room].id);
    for ([_]i32{ 112, 176 }) |bed_y| for ([_]i32{ 24, 72, 120 }) |bed_x| {
        try walkTo(&state, package, bed_x, bed_y);
        // Hero stays behind the bedding while occupying mattress origins.
        const bed_depth = @divTrunc(bed_y + 32, 8);
        try std.testing.expect(bed_depth > @divTrunc(state.y, 8));
    };
    try walkTo(&state, package, 248, 152);
    state.facing = .up;
    state.tick(package, .{ .action = true });
    try std.testing.expect(state.dialogue != null);
    try std.testing.expectEqualStrings("patron", package.rooms[state.room].npcs[state.dialogue.?.source.npc].id);
    try std.testing.expectEqualStrings("Patron", state.dialogue.?.name(package.rooms[state.room]));
    if (state.dialogue) |*dialogue| dialogue.reveal_complete = true;
    state.tick(package, .{ .action = true });
    try std.testing.expectEqual(null, state.dialogue);
    try walkTo(&state, package, 288, 120);
    state.facing = .up;
    state.tick(package, .{ .action = true });
    try std.testing.expect(state.dialogue != null);
    try std.testing.expectEqualStrings("innkeeper", package.rooms[state.room].npcs[state.dialogue.?.source.npc].id);
    state.tick(package, .{ .direction = .down });
    try std.testing.expectEqual(@as(i32, 120), state.y);
    if (state.dialogue) |*dialogue| dialogue.reveal_complete = true;
    state.tick(package, .{ .action = true });
    try std.testing.expectEqual(.choices, state.dialogue.?.phase);
    state.tick(package, .{ .menu_direction = .down });
    state.tick(package, .{ .action = true });
    try std.testing.expectEqual(null, state.dialogue);
    try std.testing.expectEqual(@as(u32, 350), state.progress.money);
    state.tick(package, .{ .action = true });
    if (state.dialogue) |*dialogue| dialogue.reveal_complete = true;
    state.tick(package, .{ .action = true });
    state.tick(package, .{ .action = true });
    try std.testing.expectEqual(@as(u16, 60), state.rest_ticks);
    for (0..60) |_| state.tick(package, .{});
    try std.testing.expectEqual(@as(u32, 250), state.progress.money);
    try std.testing.expectEqual(@as(u16, 100), members[0].hp);
    try std.testing.expectEqual(field.game_state.Status.healthy, members[0].status);
    try std.testing.expectEqual(null, state.dialogue);
    try walkTo(&state, package, 248, 240);
    try std.testing.expectEqualStrings("vb6_village", package.rooms[state.room].id);
    try std.testing.expectEqual(@as(i32, 400), state.x);
    try std.testing.expectEqual(@as(i32, 264), state.y);
    try walkTo(&state, package, 304, 256);
    for (0..6) |index| {
        const x: i32 = 312 + @as(i32, @intCast(index)) * 8;
        try walkTo(&state, package, x, 256);
        for (0..package.step_ticks * 2) |_| state.tick(package, .{ .direction = .up });
        try std.testing.expectEqual(x, state.x);
        try std.testing.expectEqual(@as(i32, 256), state.y);
        try std.testing.expectEqual(@as(u16, 0), state.remaining);
        try std.testing.expect(!state.walking);
    }
    for ([_]struct { id: []const u8, x: i32, y: i32 }{
        .{ .id = "elf_witness", .x = 280, .y = 248 },
        .{ .id = "forest_villager", .x = 440, .y = 128 },
    }) |npc| {
        try walkTo(&state, package, npc.x, npc.y);
        state.facing = .up;
        state.tick(package, .{ .action = true });
        try std.testing.expectEqualStrings(npc.id, package.rooms[state.room].npcs[state.dialogue.?.source.npc].id);
        if (state.dialogue) |*dialogue| dialogue.reveal_complete = true;
        state.tick(package, .{ .action = true });
        try std.testing.expectEqual(null, state.dialogue);
    }
    try walkTo(&state, package, 288, 360);
    try std.testing.expect(state.progress.story.village_south_exit_reached);
    try std.testing.expectEqualStrings("Village south exit", state.dialogue.?.name(package.rooms[state.room]));
    if (state.dialogue) |*dialogue| dialogue.reveal_complete = true;
    state.tick(package, .{ .action = true });
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try saves.write(allocator, std.testing.io, directory.dir, package, state);
    var restarted_progress: field.game_state.Progress = .{ .money = 350, .party = .init(&members) };
    var restarted = field.State.init(package, &restarted_progress);
    try restarted.configureInn(package, inn.value);
    const loaded = try saves.restore(allocator, std.testing.io, directory.dir, package, &restarted);
    defer loaded.deinit();
    state = restarted;
    try std.testing.expect(state.progress.story.village_south_exit_reached);
    state.tick(package, .{});
    try std.testing.expectEqual(null, state.dialogue);
    try std.testing.expectEqual(@as(u32, 250), state.progress.money);
    try walkTo(&state, package, 400, 264);
    try walkTo(&state, package, 400, 256);
    try std.testing.expectEqualStrings("vb6_inn", package.rooms[state.room].id);
    try std.testing.expectEqual(@as(i32, 248), state.x);
    try std.testing.expectEqual(@as(i32, 208), state.y);
    try std.testing.expectEqual(@as(u32, 250), state.progress.money);
    try std.testing.expectEqual(@as(u16, 100), members[0].hp);
    try std.testing.expect(state.progress.story.village_south_exit_reached);
}

test "three-room shopping loop: buy, use, save, reload and leave the shop" {
    const pause = @import("pause_menu");
    const allocator = std.testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../kit/work/build/first_room/room.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try field.load(allocator, bytes);
    defer parsed.deinit();
    const package = parsed.value;
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members = [_]field.game_state.Member{.{ .id = "hero", .name = "Hero", .hp = 35, .max_hp = 100, .status = .poisoned, .rune_charges = .{ 1, 0, 0, 0 }, .max_rune_charges = .{ 3, 0, 0, 0 } }};
    var game_progress: field.game_state.Progress = .{ .money = 350, .party = .init(&members) };
    var game = field.State.init(package, &game_progress);
    game.item_rules = rules.value;
    try walkTo(&game, package, 248, 240);
    try walkTo(&game, package, 240, 152);
    try walkTo(&game, package, 240, 144);
    try std.testing.expectEqualStrings("vb6_shop", package.rooms[game.room].id);
    try walkTo(&game, package, 184, 136);
    game.facing = .up;
    var menu = pause.State{};
    const action = pause.Input{ .field = .{ .action = true } };
    _ = menu.tick(package, &game, action);
    try std.testing.expectEqualStrings("Welcome.", game.dialogue.?.pages(package.rooms[game.room])[0]);
    if (game.dialogue) |*dialogue| dialogue.reveal_complete = true;
    _ = menu.tick(package, &game, action);
    _ = menu.tick(package, &game, .{});
    try std.testing.expectEqual(.shop, menu.phase);
    _ = menu.tick(package, &game, action);
    _ = menu.tick(package, &game, action);
    _ = menu.tick(package, &game, .{ .right = true });
    _ = menu.tick(package, &game, action);
    try std.testing.expectEqual(@as(u32, 250), game.progress.money);
    _ = menu.tick(package, &game, action);
    _ = menu.tick(package, &game, .{ .field = .{ .cancel = true } });
    _ = menu.tick(package, &game, .{ .menu = true });
    menu.selected = .item;
    _ = menu.tick(package, &game, action);
    _ = menu.tick(package, &game, action);
    _ = menu.tick(package, &game, action);
    try std.testing.expectEqual(@as(u16, 100), members[0].hp);
    try std.testing.expectEqual(@as(u16, 5), members[0].inventory.slots[0].?.uses);
    try std.testing.expectEqual(.poisoned, members[0].status);
    _ = menu.tick(package, &game, .{ .menu = true });
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try saves.write(allocator, std.testing.io, dir.dir, package, game);
    var fresh_progress: field.game_state.Progress = .{ .money = 350, .party = .init(&members) };
    var fresh = field.State.init(package, &fresh_progress);
    fresh.item_rules = rules.value;
    const loaded = try saves.restore(allocator, std.testing.io, dir.dir, package, &fresh);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("vb6_shop", package.rooms[fresh.room].id);
    try std.testing.expectEqual(@as(u16, 5), fresh.progress.party.at(0).inventory.slots[0].?.uses);
    try std.testing.expectEqual(@as(u32, 250), fresh.progress.money);
    try walkTo(&fresh, package, 184, 240);
    try std.testing.expectEqualStrings("vb6_village", package.rooms[fresh.room].id);
    try std.testing.expectEqual(@as(i32, 240), fresh.x);
    try std.testing.expectEqual(@as(i32, 152), fresh.y);
    try walkTo(&fresh, package, 400, 264);
    try walkTo(&fresh, package, 400, 256);
    try std.testing.expectEqualStrings("vb6_inn", package.rooms[fresh.room].id);
    try std.testing.expectEqual(@as(u16, 5), fresh.progress.party.at(0).inventory.slots[0].?.uses);
}

test "field camera follows world coordinates, clamps map edges and retains small-room centering" {
    try std.testing.expectEqualDeep(field.CameraOffset{ .x = 128, .y = 88 }, field.cameraOffset(256, 256, 120, 120));
    try std.testing.expectEqualDeep(field.CameraOffset{ .x = 0, .y = 24 }, field.cameraOffset(1024, 768, 0, 0));
    try std.testing.expectEqualDeep(field.CameraOffset{ .x = -256, .y = -168 }, field.cameraOffset(1024, 768, 512, 384));
    try std.testing.expectEqualDeep(field.CameraOffset{ .x = -512, .y = -360 }, field.cameraOffset(1024, 768, 1024, 768));
    try std.testing.expectEqualDeep(field.CameraOffset{ .x = 128, .y = -168 }, field.cameraOffset(256, 768, 128, 384));
    const allocator = std.testing.allocator;
    const parsed = try field.load(allocator, @embedFile("fixtures/room.json"));
    defer parsed.deinit();
    const grid = try allocator.alloc(u8, 128 * 96);
    defer allocator.free(grid);
    @memset(grid, '1');
    grid[75 * 128 + 101] = '0';
    var npc = [_]field.Npc{.{ .id = "test_far_npc", .name = "Villager", .x = 800, .y = 576, .pages = &.{"Hello across the map."} }};
    var rooms = [_]field.Room{.{ .id = "large_room", .title = "Large test map", .width = 1024, .height = 768, .walkable = grid, .draws = &.{}, .npcs = &npc, .exits = &.{} }};
    var package = parsed.value;
    package.rooms = &rooms;
    package.start_room = "large_room";
    package.start_x = 800;
    package.start_y = 600;
    package.interaction_offsets[@backingInt(field.Direction.up)] = .{ .x = 0, .y = -24 };
    var members = [_]field.game_state.Member{.{ .id = "hero", .name = "Hero", .hp = 100, .max_hp = 100, .status = .healthy, .rune_charges = @splat(0), .max_rune_charges = @splat(0) }};
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = .init(&members) };
    var state = field.State.init(package, &state_progress);
    state.facing = .up;
    state.tick(package, .{ .action = true });
    try std.testing.expect(state.dialogue != null);
    try std.testing.expectEqual(@as(usize, 0), state.dialogue.?.source.npc);
    state.tick(package, .{ .cancel = true });
    state.tick(package, .{ .direction = .right });
    try std.testing.expectEqual(@as(i32, 800), state.x);
    try std.testing.expectEqual(@as(u16, 0), state.remaining);
    state.tick(package, .{ .direction = .down });
    for (0..package.step_ticks) |_| state.tick(package, .{});
    try std.testing.expectEqual(@as(i32, 608), state.y);
    try std.testing.expectEqual(@as(i32, 800), state.x);
}
