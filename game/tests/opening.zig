const std = @import("std");
const opening = @import("journey").opening;
const events = @import("journey").opening_events;
const allocator = std.testing.allocator;

test "canonical opening bootstrap binds one source Hero, ground and ordered initialization" {
    const content = try opening.load(allocator, opening.json);
    defer content.deinit();
    const event_content = try events.load(allocator, events.json);
    defer event_content.deinit();
    const entry = try opening.State.start(content.value, event_content.value);
    const state = entry.state;
    try std.testing.expectEqual(@as(u32, 1500), state.money);
    try std.testing.expectEqualStrings("hero", state.hero.member.id);
    try std.testing.expectEqual(@as(u16, 17), state.hero.member.hp);
    try std.testing.expectEqual(@as(u8, 1), state.hero.level);
    try std.testing.expectEqual(@as(u16, 0), state.hero.experience);
    try std.testing.expectEqual(@as(usize, 5), state.hero.member.inventory.count());
    try std.testing.expectEqual(.bandanna, state.hero.equipped.head.?);
    try std.testing.expectEqual(.tunic, state.hero.equipped.body.?);
    try std.testing.expectEqual(.gloves, state.hero.equipped.accessory_one.?);
    try std.testing.expectEqual(.boots, state.hero.equipped.accessory_two.?);
    try std.testing.expectEqual(.medicine, state.hero.member.inventory.slots[4].?.id);
    try std.testing.expectEqual(@as(u16, 6), state.hero.member.inventory.slots[4].?.uses);
    try std.testing.expectEqualDeep([4]u16{ 0, 0, 0, 0 }, state.hero.member.rune_charges);
    try std.testing.expect(state.hero.rune == null);
    try std.testing.expectEqualStrings("vaa_room_2", state.room);
    try std.testing.expectEqual(@as(i32, 512), state.position.x);
    try std.testing.expectEqual(@as(i32, 584), state.position.y);
    const room = content.value.roomById(state.room).?;
    try std.testing.expect(room.canStand(state.position.x, state.position.y));
    try std.testing.expectEqual(@as(i32, 320), state.camera.x);
    try std.testing.expectEqual(@as(i32, 472), state.camera.y);
    try std.testing.expectEqualStrings("vaa_room2_init_23", entry.effects.programs[0].?);
    try std.testing.expectEqual(@as(?u16, 129), entry.effects.pumps[0].?.queued_cue);
    try std.testing.expect(entry.effects.programs[1] == null);
    try std.testing.expect(state.events.initialized and !state.events.active and !state.events.flags.story_0006);
    const exit = room.exits[0];
    try std.testing.expectEqualStrings("vaa_room_1", exit.room);
    try std.testing.expect(content.value.roomById(exit.room).?.canStand(exit.spawn_x, exit.spawn_y));
}

test "opening camera matches82 independent original boot/descriptor/camera vectors" {
    const content = try opening.load(allocator, opening.json);
    defer content.deinit();
    const Point = @TypeOf(content.value.position);
    const Case = struct { position: Point, camera: Point };
    const vectors = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_camera.json"), .{});
    defer vectors.deinit();
    try std.testing.expectEqual(@as(usize, 82), vectors.value.len);
    for (vectors.value) |case| try std.testing.expectEqualDeep(case.camera, content.value.cameraFor(content.value.rooms[0], case.position));
    var reordered = [2]@TypeOf(content.value.rooms[0]){ content.value.rooms[1], content.value.rooms[0] };
    var data = content.value;
    data.rooms = &reordered;
    try data.validate();
    try std.testing.expectEqualStrings("vaa_room_2", data.roomById(data.room).?.id);
}

test "opening internal checkpoint owns restored names and refuses invalid data atomically" {
    const content = try opening.load(allocator, opening.json);
    defer content.deinit();
    const event_content = try events.load(allocator, events.json);
    defer event_content.deinit();
    const entry = try opening.State.start(content.value, event_content.value);
    var restored = entry.state;
    {
        const bytes = try std.json.Stringify.valueAlloc(allocator, entry.state, .{});
        defer allocator.free(bytes);
        const checkpoint = try std.json.parseFromSlice(opening.State, allocator, bytes, .{ .allocate = .alloc_always });
        defer checkpoint.deinit();
        try checkpoint.value.apply(content.value, event_content.value, &restored);
    }
    try std.testing.expectEqualDeep(entry.state, restored);
    try std.testing.expectEqualDeep(events.Effects{}, try restored.events.tick(event_content.value, 0));
    try std.testing.expectError(error.RoomAlreadyInitialized, restored.events.initializeRoom(event_content.value));
    var invalid = restored;
    invalid.schema = "suikoden-opening-state/999";
    try std.testing.expectError(error.UnsupportedOpeningState, invalid.apply(content.value, event_content.value, &restored));
    invalid = restored;
    invalid.hero.equipped.head = .headband;
    try std.testing.expectError(error.UnownedOpeningEquipment, invalid.apply(content.value, event_content.value, &restored));
    invalid = restored;
    invalid.events.flags.story_0006 = true;
    try std.testing.expectError(error.UnsupportedOpeningStage, invalid.apply(content.value, event_content.value, &restored));
    invalid = restored;
    invalid.hero.equipped.head = .medicine;
    try std.testing.expectError(error.UnsupportedOpeningStage, invalid.apply(content.value, event_content.value, &restored));
    invalid = restored;
    invalid.hero.member.hp -= 1;
    try std.testing.expectError(error.UnsupportedOpeningStage, invalid.apply(content.value, event_content.value, &restored));
    invalid = restored;
    invalid.events.selected = "vaa_room2_init_24";
    invalid.events.cursor = 9;
    try std.testing.expectError(error.UnsupportedOpeningStage, invalid.apply(content.value, event_content.value, &restored));
    try std.testing.expectEqualDeep(entry.state, restored);
    var rooms = [2]@TypeOf(content.value.rooms[0]){ content.value.rooms[0], content.value.rooms[1] };
    var data = content.value;
    data.rooms = &rooms;
    rooms[1].walkable = "";
    try std.testing.expectError(error.InvalidOpeningRoom, data.validate());
    data = content.value;
    data.schema = "suikoden-opening/999";
    try std.testing.expectError(error.UnsupportedOpeningSchema, data.validate());
}

test "Teo grid interaction matches784 original facing, position and key cases" {
    const Case = struct { facing: u8, x: i32, y: i32, keys: u8, accepted: bool, actor_facing: ?u8 };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_interaction.json"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        const direction: opening.audience.Direction = switch (case.facing) {
            0 => .down,
            1 => .up,
            2 => .left,
            3 => .right,
            else => unreachable,
        };
        const accepted = case.keys & 0x41 != 0 and opening.canInteract(.{ .x = 464, .y = 608 }, direction, .{ .x = case.x, .y = case.y });
        try std.testing.expectEqual(case.accepted, accepted);
        if (accepted) try std.testing.expectEqual(case.actor_facing.?, ([_]u8{ 1, 0, 3, 2 })[case.facing]);
    }
}
