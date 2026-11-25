const std = @import("std");
const field = @import("field");

test "source camera pushes retain byte wrapping repeat clock and pre-settlement camera" {
    const Checkpoint = struct { update: u16, frame: [9]i32 };
    const Sample = struct { request: field.camera_push.Request, start: field.Point, updates: u16, checkpoints: []const Checkpoint };
    const Fixture = struct { samples: []const Sample };
    const fixture = try std.json.parseFromSlice(Fixture, std.testing.allocator, @embedFile("fixtures/field_camera_push.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    for (fixture.value.samples) |sample| {
        var hero: @import("opening_audience").ActorMotion = .{ .x = sample.start.x, .y = sample.start.y, .speed = 1 };
        var push = try field.camera_push.State.begin(sample.request, &hero);
        var checkpoint: usize = 0;
        for (0..sample.updates) |index| {
            const frame = push.advance(&hero).?;
            hero.tick();
            try push.validate();
            if (checkpoint < sample.checkpoints.len and sample.checkpoints[checkpoint].update == index + 1) {
                try std.testing.expectEqualDeep(sample.checkpoints[checkpoint].frame, [9]i32{
                    frame.camera_target_x, frame.camera_target_y,                 hero.x,                       hero.y, hero.offset_x, hero.offset_y,
                    push.updates_left,     @as(u8, @truncate(push.repeats_left)), frame.forced_animation_steps,
                });
                checkpoint += 1;
            }
        }
        try std.testing.expectEqual(sample.checkpoints.len, checkpoint);
        try std.testing.expect(!push.active() and push.advance(&hero) == null);
        var bad = push;
        bad.updates_left = 1;
        try std.testing.expectError(error.InvalidCameraPushState, bad.validate());
        var invalid = sample.request;
        invalid.repeats = 0;
        const before = hero;
        try std.testing.expectError(error.UnsupportedCameraPush, field.camera_push.State.begin(invalid, &hero));
        try std.testing.expectEqualDeep(before, hero);
        hero.x = -8;
        try std.testing.expectError(error.InvalidCameraPushStart, field.camera_push.State.begin(sample.request, &hero));
        try std.testing.expectEqual(@as(i32, -8), hero.x);
    }
}

test "source scenery instances preserve ordering staging collision and stored state" {
    const Sample = struct { staged: []const u16, appended: []const u16, ground: []const u8, upper: []const u8 };
    const Fixture = struct { model: field.scenery.Model, samples: []const Sample };
    const parsed = try std.json.parseFromSlice(Fixture, std.testing.allocator, @embedFile("fixtures/field_scenery.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const model = parsed.value.model;
    try model.validate();
    const mixed = field.scenery.Query{ .bits = 0x111 };
    try std.testing.expectEqual(@as(u4, 0), mixed.solid(0, 0));
    try std.testing.expectEqual(@as(u4, 1), mixed.solid(1, 0));
    const previous = field.scenery.Support{ .layer = 1, .instance = 3 };
    try std.testing.expectEqualDeep(previous, model.supportAfter(null, previous, .{ .bits = 0x100, .support = 0 }));
    try std.testing.expectEqualDeep(field.scenery.Support{ .instance = 3 }, model.supportAfter(null, previous, .{}));
    try std.testing.expectEqualDeep(field.scenery.Support{ .layer = model.objects[0].layer, .instance = 0 }, model.supportAfter(null, previous, .{ .bits = 0x110, .support = 0 }));
    for (parsed.value.samples) |sample| {
        var state = try field.scenery.State.init(model);
        for (sample.appended, 0..) |object, index| try std.testing.expectEqual(model.initial_count + index, try state.append(model, object));
        for (sample.staged) |index| try state.stage(index);
        try state.validate(model);
        try std.testing.expectEqual(model.initial_count + sample.appended.len, state.count);
        for ([_][]const u8{ sample.ground, sample.upper }, 0..) |grid, layer| {
            for (grid, 0..) |cell, index| {
                const x: i32 = @intCast((index % model.columns) * 8);
                const y: i32 = @intCast((index / model.columns) * 8);
                try std.testing.expectEqual(cell == '1', model.canStand(&state, x, y, @intCast(layer)));
            }
        }
        const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, state, .{});
        defer std.testing.allocator.free(bytes);
        const restored = try std.json.parseFromSlice(field.scenery.State, std.testing.allocator, bytes, .{});
        defer restored.deinit();
        try restored.value.validate(model);
        try std.testing.expectEqualDeep(state, restored.value);
        const before = state;
        try std.testing.expectError(error.UnknownFieldSceneryInstance, state.stage(state.count));
        try std.testing.expectError(error.UnknownFieldSceneryTemplate, state.append(model, 0));
        var changed_model = model;
        changed_model.initial_count -= 1;
        try std.testing.expectError(error.FieldSceneryContentMismatch, state.validate(changed_model));
        try std.testing.expectError(error.FieldSceneryContentMismatch, state.append(changed_model, model.initial_count));
        try std.testing.expectEqualDeep(before, state);
    }
    var full = try field.scenery.State.init(model);
    while (full.count < field.scenery.max_instances) _ = try full.append(model, model.initial_count);
    try full.stage(model.initial_count);
    try std.testing.expectEqualDeep(field.scenery.Support{ .layer = model.objects[full.instances[44].object].layer, .instance = 44 }, model.supportAfter(&full, .{}, .{ .bits = 0x110, .support = 300 }));
    try std.testing.expectError(error.FieldSceneryCapacity, full.append(model, model.initial_count));
    var malformed = model;
    malformed.terrain = "f";
    try std.testing.expectError(error.InvalidFieldScenery, field.scenery.State.init(malformed));
}

test "room scenery draws follow staged and inserted collision instances" {
    const model: field.scenery.Model = .{
        .schema = "suikoden-field-scenery/1",
        .columns = 4,
        .rows = 4,
        .initial_count = 1,
        .terrain = "0000000000000000",
        .objects = &.{
            .{ .x = 0, .y = 0, .width_cells = 1, .height_cells = 1, .layer = 0, .collides = true, .mask = "1" },
            .{ .x = 16, .y = 16, .width_cells = 1, .height_cells = 1, .layer = 0, .collides = true, .mask = "1" },
        },
    };
    const room: field.Room = .{
        .id = "test_room",
        .title = "Test Room",
        .width = 32,
        .height = 32,
        .walkable = "0000000000000000",
        .draws = &.{},
        .npcs = &.{},
        .exits = &.{},
        .scenery_model = model,
    };
    const base: field.Draw = .{ .rect = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .x = 0, .y = 0, .depth = 0 };
    var existing = base;
    existing.scenery_object = 0;
    var template = base;
    template.scenery_object = 1;
    try std.testing.expectEqual(@as(usize, 1), room.sceneryCopies(existing, null));
    try std.testing.expectEqual(@as(usize, 0), room.sceneryCopies(template, null));
    try std.testing.expect(!model.canStand(null, 0, 0, 0));
    try std.testing.expect(model.canStand(null, 16, 16, 0));

    var visit = try field.scenery.State.init(model);
    try visit.stage(0);
    const first = try visit.append(model, 1);
    const second = try visit.append(model, 1);
    try std.testing.expectEqual(@as(usize, 0), room.sceneryCopies(existing, &visit));
    try std.testing.expectEqual(@as(usize, 2), room.sceneryCopies(template, &visit));
    try std.testing.expectEqual(@as(usize, 1), room.sceneryCopies(base, &visit));
    try std.testing.expect(model.canStand(&visit, 0, 0, 0));
    try std.testing.expect(!model.canStand(&visit, 16, 16, 0));
    try std.testing.expectEqualDeep(field.scenery.Query{}, model.query(&visit, 254, 254, 0));

    try visit.stage(first);
    try std.testing.expectEqual(@as(usize, 1), room.sceneryCopies(template, &visit));
    try std.testing.expect(!model.canStand(&visit, 16, 16, 0));
    try visit.stage(second);
    try std.testing.expectEqual(@as(usize, 0), room.sceneryCopies(template, &visit));
    try std.testing.expect(model.canStand(&visit, 16, 16, 0));
}

test "item receive appends source use counts and preserves a full or invalid bag" {
    var bag: field.items.Inventory = .{};
    try std.testing.expect(try bag.receive(.medicine));
    try std.testing.expectEqual(@as(u16, 6), bag.slots[0].?.uses);
    try std.testing.expect(try bag.receive(.dragon_seal_incense));
    try std.testing.expectEqual(@as(u16, 0), bag.slots[1].?.uses);
    try std.testing.expect(try bag.receive(.fortune_rune_piece));
    try std.testing.expectEqual(@as(u16, 1), bag.slots[2].?.uses);
    for (3..9) |_| try std.testing.expect(try bag.receive(.medicine));
    const full = bag;
    try std.testing.expect(!try bag.receive(.medicine));
    try std.testing.expectEqualDeep(full, bag);
    bag.slots[0].?.uses = 0;
    const invalid = bag;
    try std.testing.expectError(error.InvalidInventory, bag.receive(.medicine));
    try std.testing.expectEqualDeep(invalid, bag);
}

fn package() !std.json.Parsed(field.Package) {
    return field.load(std.testing.allocator, @embedFile("fixtures/room.json"));
}

fn step(state: *field.State, content: field.Package, direction: field.Direction) void {
    for (0..content.step_ticks) |_| state.tick(content, .{ .direction = direction });
}

test "content validates IDs, occupancy, spawns, clips and atlas references" {
    const parsed = try package();
    defer parsed.deinit();
    const content = parsed.value;
    var coast = content.rooms[0];
    coast.width = 16;
    coast.height = 8;
    coast.walkable = "10";
    coast.boat_walkable = "01";
    try std.testing.expect(coast.canMoveInMode(0, 0, 0) and !coast.canMoveInMode(8, 0, 0));
    try std.testing.expect(!coast.canMoveInMode(0, 0, 1) and coast.canMoveInMode(8, 0, 1));
    try std.testing.expect(coast.canMoveInMode(0, 0, 2) and coast.canMoveInMode(8, 0, 2));
    try content.validateAtlas(8, 1);
    try std.testing.expectError(error.InvalidRectangle, content.validateAtlas(7, 1));
    var bad = content;
    bad.schema = "suikoden-room/999";
    try std.testing.expectError(error.UnsupportedSchema, bad.validate());
    bad = content;
    bad.atlas = "../private-file";
    try std.testing.expectError(error.InvalidPackage, bad.validate());
    bad = content;
    bad.start_x = 16;
    try std.testing.expectError(error.InvalidSpawn, bad.validate());
    bad = content;
    bad.start_room = "missing";
    try std.testing.expectError(error.UnknownRoom, bad.validate());
    var rooms: [2]field.Room = content.rooms[0..2].*;
    bad = content;
    bad.rooms = &rooms;
    rooms[0].walkable = "1";
    try std.testing.expectError(error.InvalidRoom, bad.validate());
    rooms = content.rooms[0..2].*;
    rooms[1].id = "inn";
    try std.testing.expectError(error.DuplicateId, bad.validate());
    rooms = content.rooms[0..2].*;
    var exits: [1]field.Exit = rooms[0].exits[0..1].*;
    rooms[0].exits = &exits;
    exits[0].room = "missing";
    try std.testing.expectError(error.UnknownRoom, bad.validate());
    exits[0].room = "village";
    exits[0].spawn_x = 0;
    try std.testing.expectError(error.InvalidSpawn, bad.validate());
    try std.testing.expectError(error.UnexpectedEndOfInput, field.load(std.testing.allocator, "{"));
    rooms = content.rooms[0..2].*;
    rooms[0].scenery_atlas = "field/inn.png";
    try std.testing.expectError(error.InvalidSceneryAtlas, bad.validate());
    bad.schema = field.Package.scenery_atlas_schema;
    rooms[0].scenery_atlas = "field/../inn.png";
    try std.testing.expectError(error.InvalidSceneryAtlas, bad.validate());
    rooms[0].scenery_atlas = "field/inn.png";
    rooms[0].draws = &.{.{ .rect = .{ .x = 8, .y = 0, .w = 1, .h = 1 }, .x = 0, .y = 0, .depth = 0 }};
    try bad.validate();
    try bad.validateAtlas(8, 1);
    try std.testing.expectError(error.InvalidRectangle, rooms[0].validateSceneryAtlas(8, 1));
    try rooms[0].validateSceneryAtlas(9, 1);
    rooms[0].draws = &.{.{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .x = 0, .y = 0, .depth = 0, .prop = 63 }};
    try std.testing.expectError(error.InvalidSceneryProp, bad.validate());
    bad.schema = field.Package.prop_schema;
    try bad.validate();
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(bad, &state_progress);
    try std.testing.expect(rooms[0].draws[0].sampleVisible(&state) == null);
    state.shown_props = @as(u64, 1) << 63;
    try std.testing.expect(rooms[0].draws[0].sampleVisible(&state) != null);
    state.enterRoom(1, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(u64, 0), state.shown_props);
}

test "blocked movement changes facing; a walk step takes six fixed ticks" {
    const parsed = try package();
    defer parsed.deinit();
    const content = parsed.value;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(content, &state_progress);
    step(&state, content, .right);
    try std.testing.expectEqual(@as(i32, 8), state.x);
    try std.testing.expectEqual(field.Direction.right, state.facing);
    const start = state.tickWithArrival(content, .{ .direction = .up }, null, .immediate);
    try std.testing.expectEqualDeep(field.Update{ .movement_advanced = true }, start);
    try std.testing.expectEqual(@as(u16, 5), state.remaining);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 - 8.0 / 6.0), state.position(content).y, 0.001);
    for (0..4) |_| state.tick(content, .{});
    const finish = state.tickWithArrival(content, .{}, null, .deferred);
    try std.testing.expectEqualDeep(field.Update{ .movement_advanced = true, .step_completed = true }, finish);
    try std.testing.expect(!state.finishStepArrival(content));
    try std.testing.expectEqual(@as(i32, 8), state.y);
    try std.testing.expectEqual(@as(u16, 0), state.remaining);
    step(&state, content, .up);
    try std.testing.expectEqual(@as(i32, 8), state.y);
    try std.testing.expect(!content.rooms[0].canStand(-8, 8));
    try std.testing.expect(!content.rooms[0].canStand(64, 8));
    try std.testing.expect(!content.rooms[0].canStand(9, 8));
}

test "facing and range gate dialogue, which freezes walking until closed" {
    const parsed = try package();
    defer parsed.deinit();
    const content = parsed.value;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(content, &state_progress);
    state.x = 24;
    state.y = 48;
    state.destination = .{ .x = 24, .y = 48 };
    state.tick(content, .{ .action = true });
    try std.testing.expectEqual(null, state.dialogue);
    state.facing = .up;
    state.tick(content, .{ .action = true });
    try std.testing.expectEqual(@as(usize, 0), state.dialogue.?.page);
    step(&state, content, .left);
    try std.testing.expectEqual(@as(i32, 24), state.x);
    if (state.dialogue) |*dialogue| dialogue.reveal_complete = true;
    state.tick(content, .{ .action = true });
    try std.testing.expectEqual(@as(usize, 1), state.dialogue.?.page);
    if (state.dialogue) |*dialogue| dialogue.reveal_complete = true;
    state.tick(content, .{ .action = true });
    try std.testing.expectEqual(null, state.dialogue);
    state.tick(content, .{});
    try std.testing.expectEqual(null, state.dialogue);
    state.tick(content, .{ .action = true });
    state.tick(content, .{ .cancel = true });
    try std.testing.expectEqual(null, state.dialogue);
    state.x = 8;
    state.tick(content, .{ .action = true });
    try std.testing.expectEqual(null, state.dialogue);
}

test "doorway changes scene and spawn once, then supports the return route" {
    const parsed = try package();
    defer parsed.deinit();
    var content = parsed.value;
    var rooms: [652]field.Room = undefined;
    const destination = rooms.len - 1;
    var names: [650][12]u8 = undefined;
    for (rooms[1..destination], &names, 1..) |*room, *name, i| {
        room.* = .{ .id = try std.fmt.bufPrint(name, "room_{d}", .{i}), .title = "Test room", .width = 16, .height = 16, .walkable = "1111", .draws = &.{}, .npcs = &.{}, .exits = &.{} };
    }
    rooms[0] = content.rooms[0];
    rooms[destination] = content.rooms[1];
    var exits = rooms[0].exits[0..1].*;
    exits[0].conditions = &.{.{ .kind = .story_mask_set, .flag = .{ .id = "scenario_0001", .mask = 4 } }};
    rooms[0].exits = &exits;
    content.rooms = &rooms;
    try std.testing.expectError(error.InvalidExitConditions, content.validate());
    content.schema = field.Package.story_exits_schema;
    exits[0].room_conditions = &.{
        .{ .kind = .room_mask_set, .index = 0, .mask = 2 },
        .{ .kind = .room_mask_clear, .index = 0, .mask = 4 },
    };
    try std.testing.expectError(error.InvalidExitRoomConditions, content.validate());
    content.schema = field.Package.room_conditions_schema;
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, content, .{});
    defer std.testing.allocator.free(encoded);
    const loaded = try field.load(std.testing.allocator, encoded);
    defer loaded.deinit();
    content = loaded.value;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(content, &state_progress);
    state.x = 48;
    state.y = 40;
    state.destination = .{ .x = 48, .y = 40 };
    var locked = state;
    step(&locked, content, .down);
    try std.testing.expectEqual(@as(usize, 0), locked.room);
    state.progress.story.scenario = .{};
    state.progress.story.scenario.?.scenario[1] = 4;
    locked = state;
    step(&locked, content, .down);
    try std.testing.expectEqual(@as(usize, 0), locked.room);
    try state.local_flags.orByte(0, 2);
    locked = state;
    try locked.local_flags.orByte(0, 4);
    step(&locked, content, .down);
    try std.testing.expectEqual(@as(usize, 0), locked.room);
    step(&state, content, .down);
    try std.testing.expectEqual(destination, state.room);
    try std.testing.expectEqual(@as(u8, 0), state.local_flags.values[0]);
    try std.testing.expectEqual(@as(i32, 8), state.x);
    try std.testing.expectEqual(@as(i32, 8), state.y);
    for (0..10) |_| state.tick(content, .{});
    try std.testing.expectEqual(destination, state.room);
    step(&state, content, .down);
    try std.testing.expectEqual(@as(usize, 0), state.room);
    try std.testing.expectEqual(@as(i32, 8), state.y);
}

test "walking cycles exported timed poses and stops on the neutral pose" {
    const parsed = try package();
    defer parsed.deinit();
    const content = parsed.value;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(content, &state_progress);
    state.tick(content, .{ .direction = .down });
    try std.testing.expectEqual(@as(i32, 0), state.frame(content).rect.x);
    state.tick(content, .{});
    try std.testing.expectEqual(@as(i32, 1), state.frame(content).rect.x);
    for (0..4) |_| state.tick(content, .{});
    try std.testing.expectEqual(@as(i32, 1), state.frame(content).rect.x);
}

test "holding a direction never flashes the idle pose at a grid-step boundary" {
    const parsed = try package();
    defer parsed.deinit();
    const content = parsed.value;
    var clips: [4]field.Clip = content.player_clips[0..4].*;
    var frames: [2]field.Frame = clips[0].frames[0..2].*;
    frames[0].ticks = 12;
    frames[1].ticks = 12;
    clips[0].frames = &frames;
    var modified = content;
    modified.player_clips = &clips;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(modified, &state_progress);
    for (1..19) |tick| {
        state.tick(modified, .{ .direction = .down });
        try std.testing.expect(state.walking);
        try std.testing.expectEqual(@as(i32, if (tick < 12) 0 else 1), state.frame(modified).rect.x);
    }
    state.tick(modified, .{});
    try std.testing.expect(!state.walking);
    try std.testing.expectEqual(@as(i32, 1), state.frame(modified).rect.x);
}

test "an interaction pressed during a step is retained until arrival" {
    const parsed = try package();
    defer parsed.deinit();
    const content = parsed.value;
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(content, &state_progress);
    state.x = 24;
    state.y = 48;
    state.destination = .{ .x = 24, .y = 48 };
    state.tick(content, .{ .direction = .up });
    state.tick(content, .{ .action = true });
    try std.testing.expectEqual(null, state.dialogue);
    for (0..5) |_| state.tick(content, .{});
    try std.testing.expect(state.dialogue != null);
    try std.testing.expectEqual(@as(i32, 40), state.y);
}

test "dialogue pages longer than six lines use the smaller font" {
    try std.testing.expectEqual(@as(i32, 16), field.dialogueTextSize("one\ntwo\nthree\nfour\nfive\nsix"));
    try std.testing.expectEqual(@as(i32, 12), field.dialogueTextSize("one\ntwo\nthree\nfour\nfive\nsix\nseven"));
}

test "dialogue reveal advances one character per pace tick" {
    try std.testing.expectEqual(@as(usize, 1), field.revealedCount(10, 0, 3));
    try std.testing.expectEqual(@as(usize, 1), field.revealedCount(10, 2, 3));
    try std.testing.expectEqual(@as(usize, 2), field.revealedCount(10, 3, 3));
    try std.testing.expectEqual(@as(usize, 4), field.revealedCount(10, 9, 3));
    try std.testing.expectEqual(@as(usize, 10), field.revealedCount(10, 100, 3));
}

test "dialogue speed selects source fast/normal/slow pacing" {
    var dialogue = field.Dialogue{ .source = .{ .event = 0 } };
    try std.testing.expectEqual(@as(u8, 3), dialogue.pace());
    dialogue.speed = .fast;
    try std.testing.expectEqual(@as(u8, 1), dialogue.pace());
    dialogue.speed = .slow;
    try std.testing.expectEqual(@as(u8, 5), dialogue.pace());
}

test "wheel ownership resets on room entry instead of event completion" {
    const parsed = try package();
    defer parsed.deinit();
    var state_progress: field.game_state.Progress = .{ .money = 0, .party = &.{} };
    var state = field.State.init(parsed.value, &state_progress);
    state.wheel_state = .{};
    state.wheel_state.?.start(12960);
    state.wheel_state.?.advance();
    try std.testing.expectEqual(@as(i16, 1), state.wheel_state.?.starts);
    try std.testing.expectEqual(@as(u16, 18), state.wheel_state.?.clock.angle);
    state.enterRoom(state.room, .{ .x = state.x, .y = state.y });
    try std.testing.expect(state.wheel_state == null);
}

test "wheel Robot Soldier clip preserves nonrepeating flags and legacy clip encoding" {
    const ordinary_clip: field.Clip = .{ .direction = .down, .idle_frame = 0, .frames = &.{} };
    const old = try std.json.Stringify.valueAlloc(std.testing.allocator, ordinary_clip, .{});
    defer std.testing.allocator.free(old);
    try std.testing.expect(std.mem.indexOf(u8, old, "flags") == null);
    var robot_clip = ordinary_clip;
    robot_clip.flags = 1;
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, robot_clip, .{});
    defer std.testing.allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(field.Clip, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u2, 1), parsed.value.flags);
}

test "wheel map requires versioned stationary map data and source camera bounds" {
    const parsed = try package();
    defer parsed.deinit();
    var content = parsed.value;
    var walkable: [44 * 64]u8 = @splat('1');
    var draws = [_]field.Draw{.{ .rect = .{ .x = 0, .y = 0, .w = 384, .h = 512 }, .x = 0, .y = 0, .depth = -1000 }};
    var rooms = [_]field.Room{.{ .id = "wheel", .title = "Wheel", .width = 352, .height = 512, .walkable = &walkable, .draws = &draws, .wheel_map = 0, .scenery_atlas = "field/wheel.png", .npcs = &.{}, .exits = &.{} }};
    content.schema = field.Package.wheel_map_schema;
    content.start_room = "wheel";
    content.rooms = &rooms;
    try content.validate();
    try std.testing.expect(content.supportsProps());
    content.schema = field.Package.prop_schema;
    try std.testing.expectError(error.InvalidWheelMap, content.validate());
    content.schema = field.Package.wheel_map_schema;
    rooms[0].wheel_map = 1;
    try std.testing.expectError(error.InvalidWheelMap, content.validate());
    rooms[0].wheel_map = 0;
    draws[0].x = 8;
    try std.testing.expectError(error.InvalidWheelMap, content.validate());
    draws[0].x = 0;
    draws[0].rect.w = 383;
    try std.testing.expectError(error.InvalidWheelMap, content.validate());
    try std.testing.expectEqual(field.Point{ .x = 16, .y = 160 }, field.sourceCameraScroll(352, 512, 168, 272));
    try std.testing.expectEqual(field.Point{ .x = 16, .y = 0 }, field.sourceCameraScroll(352, 512, 168, 88));
    try std.testing.expectEqual(field.Point{ .x = 32, .y = 272 }, field.sourceCameraScroll(352, 512, 2040, 2040));
}
