const std = @import("std");
const field = @import("field");
const saves = @import("save_file");
const pause = @import("pause_menu");
const allocator = std.testing.allocator;
const io = std.testing.io;

fn hero() field.game_state.Member {
    return .{ .id = "hero", .name = "Hero", .hp = 35, .max_hp = 100, .status = .poisoned, .rune_charges = .{ 1, 0, 0, 0 }, .max_rune_charges = .{ 3, 2, 1, 0 } };
}

fn content() !std.json.Parsed(field.Package) {
    return field.load(allocator, @embedFile("fixtures/room.json"));
}

test "save and restart restore semantic party state, scene, facing and usable exits" {
    const package = try content();
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game = field.State.init(package.value, .{ .money = 350, .party = &members });
    try game.progress.stay(100);
    game.x = 48;
    game.y = 40;
    game.destination = .{ .x = 48, .y = 40 };
    for (0..6) |_| game.tick(package.value, .{ .direction = .down });
    try std.testing.expectEqualStrings("village", package.value.rooms[game.room].id);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try saves.write(allocator, io, directory.dir, package.value, game);
    const bytes = try directory.dir.readFileAlloc(io, saves.filename, allocator, .limited(saves.max_bytes));
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"rune_charges\": [") != null);
    var fresh_members = [_]field.game_state.Member{hero()};
    var restarted = field.State.init(package.value, .{ .money = 350, .party = &fresh_members });
    const loaded = try saves.restore(allocator, io, directory.dir, package.value, &restarted);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("village", package.value.rooms[restarted.room].id);
    try std.testing.expectEqual(@as(i32, 8), restarted.x);
    try std.testing.expectEqual(@as(i32, 8), restarted.y);
    try std.testing.expectEqual(field.Direction.down, restarted.facing);
    try std.testing.expectEqual(@as(u32, 250), restarted.progress.money);
    try std.testing.expectEqual(@as(u16, 100), restarted.progress.party[0].hp);
    try std.testing.expectEqual(field.game_state.Status.healthy, restarted.progress.party[0].status);
    try std.testing.expectEqual([_]u16{ 3, 2, 1, 0 }, restarted.progress.party[0].rune_charges);
    for (0..6) |_| restarted.tick(package.value, .{ .direction = .down });
    try std.testing.expectEqualStrings("inn", package.value.rooms[restarted.room].id);
    try saves.write(allocator, io, directory.dir, package.value, restarted);
    const again = try saves.read(allocator, io, directory.dir, package.value);
    defer again.deinit();
    try std.testing.expectEqualStrings("inn", again.value.room);
}

test "a failed flush preserves the prior save and removes its temporary file" {
    const package = try content();
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game = field.State.init(package.value, .{ .money = 350, .party = &members });
    var directory = std.testing.tmpDir(.{ .iterate = true });
    defer directory.cleanup();
    try saves.write(allocator, io, directory.dir, package.value, game);
    game.progress.money = 100;
    var vtable = io.vtable.*;
    vtable.fileSync = struct {
        fn fail(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.NoSpaceLeft;
        }
    }.fail;
    var failing_io = io;
    failing_io.vtable = &vtable;
    try std.testing.expectError(error.NoSpaceLeft, saves.write(allocator, failing_io, directory.dir, package.value, game));
    const previous = try saves.read(allocator, io, directory.dir, package.value);
    defer previous.deinit();
    try std.testing.expectEqual(@as(u32, 350), previous.value.money);
    var iterator = directory.dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "missing, corrupt, oversized and unsupported saves cannot mutate the game" {
    const package = try content();
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game = field.State.init(package.value, .{ .money = 350, .party = &members });
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try std.testing.expectError(error.FileNotFound, saves.restore(allocator, io, directory.dir, package.value, &game));
    try directory.dir.writeFile(io, .{ .sub_path = saves.filename, .data = "{" });
    try std.testing.expectError(error.UnexpectedEndOfInput, saves.restore(allocator, io, directory.dir, package.value, &game));
    try std.testing.expectError(error.MissingField, saves.decode(allocator, "{}", package.value));
    const large = try allocator.alloc(u8, saves.max_bytes + 1);
    defer allocator.free(large);
    @memset(large, ' ');
    try std.testing.expectError(error.SaveTooLarge, saves.decode(allocator, large, package.value));
    try directory.dir.writeFile(io, .{ .sub_path = saves.filename, .data = large });
    try std.testing.expectError(error.StreamTooLong, saves.restore(allocator, io, directory.dir, package.value, &game));
    var snapshot = try saves.Snapshot.capture(game, package.value);
    snapshot.schema = "suikoden-save/999";
    const future = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(future);
    try directory.dir.writeFile(io, .{ .sub_path = saves.filename, .data = future });
    try std.testing.expectError(error.UnsupportedSaveVersion, saves.restore(allocator, io, directory.dir, package.value, &game));
    try std.testing.expectEqual(@as(u32, 350), game.progress.money);
    try std.testing.expectEqual(@as(u16, 35), game.progress.party[0].hp);
    try std.testing.expectEqual(@as(i32, 8), game.x);
    try std.testing.expectEqual(@as(usize, 0), game.room);
}

test "save references, member IDs and statistics validate before apply or write" {
    const package = try content();
    defer package.deinit();
    var members = [_]field.game_state.Member{ hero(), hero() };
    var game = field.State.init(package.value, .{ .money = 350, .party = members[0..1] });
    const original = try saves.Snapshot.capture(game, package.value);
    var bad = original;
    bad.room = "unknown";
    try std.testing.expectError(error.UnknownSaveRoom, bad.apply(package.value, &game));
    bad = original;
    bad.x = 16;
    try std.testing.expectError(error.InvalidSavePosition, bad.apply(package.value, &game));
    bad = original;
    bad.party = &members;
    try std.testing.expectError(error.DuplicateMember, bad.apply(package.value, &game));
    members[1].id = "other";
    members[1].hp = 101;
    try std.testing.expectError(error.InvalidMember, bad.validate(package.value));
    members[1] = hero();
    members[1].id = "other";
    members[1].name = "Bad\nname";
    try std.testing.expectError(error.InvalidMember, bad.validate(package.value));
    members[1] = hero();
    members[1].id = "other";
    members[1].rune_charges[0] = 4;
    try std.testing.expectError(error.InvalidMember, bad.validate(package.value));
    game.remaining = 1;
    try std.testing.expectError(error.GameBusy, saves.Snapshot.capture(game, package.value));
    try std.testing.expectEqual(@as(u32, 350), game.progress.money);
    try std.testing.expectEqual(@as(i32, 8), game.x);
}

test "pause waits for arrival, freezes the field and skips unfinished commands" {
    const package = try content();
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game = field.State.init(package.value, .{ .money = 350, .party = &members });
    var menu = pause.State{};
    _ = menu.tick(package.value, &game, .{ .field = .{ .direction = .up } });
    try std.testing.expectEqual(@as(u16, 5), game.remaining);
    _ = menu.tick(package.value, &game, .{ .menu = true });
    for (0..4) |_| _ = menu.tick(package.value, &game, .{});
    try std.testing.expectEqual(pause.Phase.root, menu.phase);
    try std.testing.expectEqual(@as(i32, 8), game.y);
    try std.testing.expect(!game.walking);
    for (0..20) |_| _ = menu.tick(package.value, &game, .{ .field = .{ .direction = .down } });
    try std.testing.expectEqual(@as(i32, 8), game.y);
    _ = menu.tick(package.value, &game, .{ .field = .{ .menu_direction = .down } });
    try std.testing.expectEqual(pause.Command.setup, menu.selected);
    _ = menu.tick(package.value, &game, .{ .field = .{ .menu_direction = .down } });
    try std.testing.expectEqual(pause.Command.save, menu.selected);
    _ = menu.tick(package.value, &game, .{ .field = .{ .menu_direction = .down } });
    try std.testing.expectEqual(pause.Command.load, menu.selected);
    _ = menu.tick(package.value, &game, .{ .field = .{ .menu_direction = .down } });
    try std.testing.expectEqual(pause.Command.new_game, menu.selected);
    _ = menu.tick(package.value, &game, .{ .field = .{ .menu_direction = .down } });
    try std.testing.expectEqual(pause.Command.back, menu.selected);
    _ = menu.tick(package.value, &game, .{ .field = .{ .menu_direction = .down } });
    try std.testing.expectEqual(pause.Command.item, menu.selected);
    _ = menu.tick(package.value, &game, .{ .field = .{ .cancel = true } });
    try std.testing.expectEqual(pause.Phase.closed, menu.phase);
    _ = menu.tick(package.value, &game, .{ .field = .{ .direction = .down } });
    try std.testing.expect(game.remaining > 0);
}

test "save and load require explicit confirmation and emit only once" {
    const package = try content();
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game = field.State.init(package.value, .{ .money = 350, .party = &members });
    for ([_]pause.Command{ .save, .load }) |command| {
        var menu = pause.State{ .phase = .root, .selected = command };
        const confirm = pause.Input{ .field = .{ .action = true } };
        try std.testing.expectEqual(pause.Effect.none, menu.tick(package.value, &game, confirm));
        try std.testing.expect(!menu.yes);
        try std.testing.expectEqual(pause.Effect.none, menu.tick(package.value, &game, confirm));
        try std.testing.expectEqual(pause.Phase.root, menu.phase);
        _ = menu.tick(package.value, &game, confirm);
        _ = menu.tick(package.value, &game, .{ .field = .{ .menu_direction = .up } });
        try std.testing.expectEqual(if (command == .save) pause.Effect.save else .load, menu.tick(package.value, &game, confirm));
        try std.testing.expectEqual(pause.Phase.notice, menu.phase);
        try std.testing.expectEqual(pause.Effect.none, menu.tick(package.value, &game, confirm));
        menu.phase = .confirm_load;
        menu.yes = true;
        try std.testing.expectEqual(pause.Effect.none, menu.tick(package.value, &game, .{ .field = .{ .action = true, .cancel = true } }));
    }
}

test "new game requires explicit confirmation and emits once" {
    const package = try content();
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game = field.State.init(package.value, .{ .money = 350, .party = &members });
    var menu = pause.State{ .phase = .root, .selected = .new_game };
    const confirm = pause.Input{ .field = .{ .action = true } };
    try std.testing.expectEqual(pause.Effect.none, menu.tick(package.value, &game, confirm));
    try std.testing.expectEqual(pause.Phase.confirm_new_game, menu.phase);
    try std.testing.expect(!menu.yes);
    try std.testing.expectEqual(pause.Effect.none, menu.tick(package.value, &game, confirm));
    try std.testing.expectEqual(pause.Phase.root, menu.phase);
    _ = menu.tick(package.value, &game, confirm);
    _ = menu.tick(package.value, &game, .{ .field = .{ .menu_direction = .up } });
    try std.testing.expectEqual(pause.Effect.new_game, menu.tick(package.value, &game, confirm));
    try std.testing.expectEqual(pause.Phase.closed, menu.phase);
    try std.testing.expectEqual(pause.Effect.none, menu.tick(package.value, &game, confirm));
}

test "menu input during conversation closes dialogue without opening a menu" {
    const package = try content();
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game = field.State.init(package.value, .{ .money = 350, .party = &members });
    game.dialogue = .{ .source = .{ .npc = 0 } };
    var menu = pause.State{};
    _ = menu.tick(package.value, &game, .{ .menu = true, .field = .{ .cancel = true } });
    try std.testing.expectEqual(pause.Phase.closed, menu.phase);
    try std.testing.expectEqual(null, game.dialogue);
    game.rest_ticks = 60;
    _ = menu.tick(package.value, &game, .{ .menu = true });
    try std.testing.expectEqual(pause.Phase.closed, menu.phase);
    try std.testing.expect(!menu.pending);
}

test "six-member saves round-trip and Strength cycles through that party" {
    const package = try content();
    defer package.deinit();
    var members: [6]field.game_state.Member = undefined;
    const ids = [_][]const u8{ "hero", "one", "two", "three", "four", "five" };
    for (&members, ids) |*member, id| {
        member.* = hero();
        member.id = id;
    }
    var game = field.State.init(package.value, .{ .money = 12345, .party = &members });
    const snapshot = try saves.Snapshot.capture(game, package.value);
    const bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(bytes);
    const parsed = try saves.decode(allocator, bytes, package.value);
    defer parsed.deinit();
    try parsed.value.apply(package.value, &game);
    try std.testing.expectEqual(@as(usize, 6), game.progress.party.len);
    try std.testing.expectEqualStrings("five", game.progress.party[5].id);
    var menu = pause.State{ .phase = .strength };
    _ = menu.tick(package.value, &game, .{ .left = true });
    try std.testing.expectEqual(@as(usize, 5), menu.member);
    _ = menu.tick(package.value, &game, .{ .right = true });
    try std.testing.expectEqual(@as(usize, 0), menu.member);
}

test "the save directory is stable outside the checkout and content directory" {
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try std.testing.expectError(error.SaveDirectoryUnavailable, saves.defaultDirectory(allocator, &environment));
    const home = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(home);
    try environment.put("HOME", home);
    try environment.put("LOCALAPPDATA", home);
    const path = try saves.defaultDirectory(allocator, &environment);
    defer allocator.free(path);
    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expect(std.mem.startsWith(u8, path, home));
    try std.testing.expect(std.mem.endsWith(u8, path, "Suikoden Zig"));
}

fn withEvent(base: field.Package, rooms: *[2]field.Room) field.Package {
    rooms.* = base.rooms[0..2].*;
    rooms[0].events = &.{.{ .id = "south_exit", .name = "South exit", .x = 8, .y = 24, .w = 8, .h = 8, .flag = .village_south_exit_reached, .pages = &.{ "Exit reached.", "Travel is not available." } }};
    var package = base;
    package.schema = "suikoden-room/4";
    package.rooms = rooms;
    return package;
}

test "a coordinate event commits once, freezes input and survives save restart and scene changes" {
    const parsed = try content();
    defer parsed.deinit();
    var rooms: [2]field.Room = undefined;
    const package = withEvent(parsed.value, &rooms);
    try package.validate();
    var members = [_]field.game_state.Member{hero()};
    var game = field.State.init(package, .{ .money = 350, .party = &members });
    var menu = pause.State{};
    _ = menu.tick(package, &game, .{ .field = .{ .direction = .down } });
    // Requesting the menu during the final step cannot hide a triggered event.
    _ = menu.tick(package, &game, .{ .menu = true });
    for (0..4) |_| _ = menu.tick(package, &game, .{});
    try std.testing.expectEqual(pause.Phase.closed, menu.phase);
    try std.testing.expect(!menu.pending);
    try std.testing.expect(game.progress.story.village_south_exit_reached);
    try std.testing.expectEqual(@as(usize, 0), game.dialogue.?.source.event);
    try std.testing.expectEqualStrings("South exit", game.dialogue.?.name(rooms[0]));
    try std.testing.expectError(error.GameBusy, saves.Snapshot.capture(game, package));
    game.tick(package, .{ .direction = .right });
    try std.testing.expectEqual(@as(i32, 8), game.x);
    if (game.dialogue) |*dialogue| dialogue.reveal_complete = true;
    game.tick(package, .{ .action = true });
    try std.testing.expectEqual(@as(usize, 1), game.dialogue.?.page);
    game.tick(package, .{ .cancel = true });
    try std.testing.expectEqual(null, game.dialogue);
    for (0..10) |_| game.tick(package, .{});
    try std.testing.expectEqual(null, game.dialogue);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try saves.write(allocator, io, directory.dir, package, game);
    var restarted = field.State.init(package, .{ .money = 1, .party = &members });
    const loaded = try saves.restore(allocator, io, directory.dir, package, &restarted);
    defer loaded.deinit();
    try std.testing.expect(restarted.progress.story.village_south_exit_reached);
    restarted.tick(package, .{});
    try std.testing.expectEqual(null, restarted.dialogue);
    restarted.x = 48;
    restarted.y = 40;
    restarted.destination = .{ .x = 48, .y = 40 };
    for (0..6) |_| restarted.tick(package, .{ .direction = .down });
    try std.testing.expectEqual(@as(usize, 1), restarted.room);
    try std.testing.expect(restarted.progress.story.village_south_exit_reached);
}

test "event contracts reject bad regions, duplicate effects and invalid text" {
    const parsed = try content();
    defer parsed.deinit();
    var rooms: [2]field.Room = undefined;
    var package = withEvent(parsed.value, &rooms);
    var events = [_]field.Event{ rooms[0].events[0], rooms[0].events[0] };
    rooms[0].events = events[0..1];
    package.schema = "suikoden-room/2";
    try std.testing.expectError(error.InvalidEvent, package.validate());
    package.schema = "suikoden-room/4";
    events[0].x = 7;
    try std.testing.expectError(error.InvalidEvent, package.validate());
    events[0].x = 0;
    try std.testing.expectError(error.InvalidEvent, package.validate());
    events[0].x = 8;
    events[0].pages = &.{};
    try std.testing.expectError(error.InvalidEvent, package.validate());
    events[0] = events[1];
    rooms[0].events = &events;
    try std.testing.expectError(error.DuplicateEvent, package.validate());
}

test "existing version-one saves retain progress and acquire clear story state on upgrade" {
    const parsed = try content();
    defer parsed.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game = field.State.init(parsed.value, .{ .money = 250, .party = &members });
    var legacy = try saves.Snapshot.capture(game, parsed.value);
    legacy.schema = "suikoden-save/1";
    legacy.story = null;
    const bytes = try std.json.Stringify.valueAlloc(allocator, legacy, .{ .emit_null_optional_fields = false });
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "story") == null);
    const loaded = try saves.decode(allocator, bytes, parsed.value);
    defer loaded.deinit();
    game.progress.story.village_south_exit_reached = true;
    try loaded.value.apply(parsed.value, &game);
    try std.testing.expectEqual(@as(u32, 250), game.progress.money);
    try std.testing.expect(!game.progress.story.village_south_exit_reached);
    const upgraded = try saves.Snapshot.capture(game, parsed.value);
    try std.testing.expectEqualStrings("suikoden-save/3", upgraded.schema);
    try std.testing.expect(upgraded.story != null);
    legacy.schema = "suikoden-save/2";
    try std.testing.expectError(error.MissingStoryState, legacy.apply(parsed.value, &game));
    try std.testing.expectEqual(@as(u32, 250), game.progress.money);
}
test "title flow labels the authored episode, keeps default No and refuses unusable Continue slots" {
    const title = @import("pause_menu").title;
    try std.testing.expectEqualStrings("Start authored episode", title.start_label);
    try std.testing.expectEqualStrings("Start this authored episode?", title.confirmation_label);
    var state = title.State{};
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .confirm = true }));
    try std.testing.expectEqual(.episode_confirm, state.phase);
    try std.testing.expect(!state.yes);
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .confirm = true }));
    try std.testing.expectEqual(.title, state.phase);
    _ = state.tick(.{ .confirm = true });
    _ = state.tick(.{ .up = true });
    _ = state.tick(.{ .cancel = true });
    try std.testing.expectEqual(.title, state.phase);
    _ = state.tick(.{ .confirm = true });
    try std.testing.expect(!state.yes);
    _ = state.tick(.{ .down = true });
    try std.testing.expectEqual(title.Effect.start_episode, state.tick(.{ .confirm = true }));
    try std.testing.expectEqual(.playing, state.phase);

    state = .{};
    var summaries = @import("pause_menu").save_slots.emptySummaries();
    summaries[1].status = .backup;
    state.ready(summaries);
    try std.testing.expectEqual(@as(usize, 0), state.selection);
    try std.testing.expectEqual(title.Effect.inspect, state.tick(.{ .confirm = true }));
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .confirm = true }));
    try std.testing.expect(state.message.len > 0);
    try std.testing.expectEqual(title.Effect.load, state.tick(.{ .down = true, .confirm = true }));
    try std.testing.expectEqual(@as(usize, 1), state.slot);
    state.summaries[1].status = .future;
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .confirm = true }));
    _ = state.tick(.{ .cancel = true });
    try std.testing.expectEqual(title.Effect.quit, state.tick(.{ .up = true, .confirm = true }));
}

test "title movie sequence covers logo opening attract timing skip and title return" {
    const title = @import("pause_menu").title;
    try std.testing.expectEqualStrings("DEMO/573LOGO.STR", title.movieSpec(.logo).disc_path);
    try std.testing.expectEqual(@as(u32, 114), title.movieSpec(.logo).frames);
    try std.testing.expectEqualStrings("DEMO/SUIKODEN.STR", title.movieSpec(.opening).disc_path);
    try std.testing.expectEqual(@as(u32, 1647), title.movieSpec(.opening).frames);
    try std.testing.expectEqualStrings("OPEN15MX.STR", title.movieSpec(.attract).disc_path);
    try std.testing.expectEqual(@as(u32, 1688), title.movieSpec(.attract).frames);

    var state = title.State.bootWithMovies();
    try std.testing.expectEqual(.movie, state.phase);
    try std.testing.expectEqual(title.MovieStage.logo, state.movie_stage);
    for (0..title.movieSpec(.logo).ticks_60hz) |_| {
        try std.testing.expectEqual(title.Effect.none, state.advanceFrame(.{}));
    }
    try std.testing.expectEqual(.movie, state.phase);
    try std.testing.expectEqual(title.MovieStage.opening, state.movie_stage);

    for (0..title.movieSpec(.opening).ticks_60hz) |_| {
        _ = state.advanceFrame(.{});
    }
    try std.testing.expectEqual(.title, state.phase);

    // Idle on title triggers the attract loop, and any input returns immediately to title.
    state.attract_idle_limit = 5;
    for (0..5) |_| _ = state.advanceFrame(.{});
    try std.testing.expectEqual(.movie, state.phase);
    try std.testing.expectEqual(title.MovieStage.attract, state.movie_stage);
    try std.testing.expectEqual(title.Effect.none, state.advanceFrame(.{ .confirm = true }));
    try std.testing.expectEqual(.title, state.phase);

    // Confirm during logo also skips straight to the title menu.
    state = title.State.bootWithMovies();
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .cancel = true }));
    try std.testing.expectEqual(.title, state.phase);
}

test "title awaiting_start transitions through cloud menu and hero naming screen" {
    const title = @import("pause_menu").title;
    var state: title.State = .{ .opening_context = true, .awaiting_start = true, .phase = .title };
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .down = true }));
    try std.testing.expect(state.awaiting_start);

    // PUSH START dismisses awaiting_start into the Cloud Menu.
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .confirm = true }));
    try std.testing.expect(!state.awaiting_start);
    try std.testing.expectEqual(.title, state.phase);
    try std.testing.expectEqual(@as(usize, 1), state.selection);

    // Selecting "New game" in opening_context enters the Hero Naming screen seeded with "Tir".
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .confirm = true }));
    try std.testing.expectEqual(.hero_name, state.phase);
    try std.testing.expectEqualStrings("Tir", state.heroName());

    // Erase back to empty, confirm grid insert ('A' at 0,0), keyboard typing, and DEL.
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .erase = true }));
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .erase = true }));
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .erase = true }));
    try std.testing.expectEqual(@as(usize, 0), state.hero_name_len);
    try std.testing.expectEqualStrings("Tir", state.heroName());

    _ = state.tick(.{ .down = true }); // row 6 -> row 0 (A..M), col 6 = 'G'
    _ = state.tick(.{ .confirm = true });
    _ = state.tick(.{ .text = "en" });
    try std.testing.expectEqualStrings("Gen", state.heroName());
    _ = state.tick(.{ .erase = true });
    try std.testing.expectEqualStrings("Ge", state.heroName());

    // Jump to DEL (row 6, col 0..5) and erase one char, then START (row 6, col 6) begins New Game.
    state.name_cursor_row = 6;
    state.name_cursor_col = 0;
    try std.testing.expectEqual(title.Effect.none, state.tick(.{ .confirm = true }));
    try std.testing.expectEqualStrings("G", state.heroName());

    _ = state.tick(.{ .right = true }); // moves from DEL to START (col 6)
    try std.testing.expectEqual(title.Effect.start_opening, state.tick(.{ .confirm = true }));
    try std.testing.expectEqual(.playing, state.phase);
    try std.testing.expectEqualStrings("G", state.heroName());
}

test "content paths follow the executable and bundle resources independently of cwd" {
    const paths = @import("pause_menu").content_path;
    const bundle = try paths.fromExecutable(std.testing.allocator, "Private Adventure.app/Contents/MacOS");
    defer std.testing.allocator.free(bundle);
    try std.testing.expect(std.mem.endsWith(u8, bundle, "Private Adventure.app/Contents/Resources/content"));
    const development = try paths.fromExecutable(std.testing.allocator, "game/zig-out/bin");
    defer std.testing.allocator.free(development);
    try std.testing.expect(std.mem.endsWith(u8, development, "kit/work/build/journey"));
}
