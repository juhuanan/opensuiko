const std = @import("std");
const events = @import("journey").opening_events;
const allocator = std.testing.allocator;

test "room initialization matches 260 complete original driver cases and preserves its disabled frame pump" {
    const content = try events.load(allocator, events.json);
    defer content.deinit();
    const Case = struct { attached_mask: u8, flag: bool, cached_cue: ?u16, programs: []const []const u8, queued: []const u16, released: []const events.ActorId, selected: []const u8, cursor: u16, active: bool, reloop: bool, cue: u16, actors: [7]events.Actor };
    const vectors = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_initialization.json"), .{});
    defer vectors.deinit();
    for (vectors.value) |case| {
        var state = try events.State.init(content.value);
        state.flags.story_0006 = case.flag;
        state.cached_cue = case.cached_cue;
        for (&state.actors, 0..) |*actor, i| actor.* = .{ .attached = case.attached_mask & (@as(u8, 1) << @intCast(i)) != 0, .state = 9 };
        const result = try state.initializeRoom(content.value);
        var queued: usize = 0;
        var released: usize = 0;
        for (case.programs, 0..) |id, i| {
            try std.testing.expectEqualStrings(id, result.programs[i].?);
            const pump = result.pumps[i].?;
            if (pump.queued_cue) |cue| {
                try std.testing.expectEqual(case.queued[queued], cue);
                queued += 1;
            }
            for (pump.released) |actor| if (actor) |value| {
                try std.testing.expectEqual(case.released[released], value);
                released += 1;
            };
        }
        try std.testing.expectEqual(case.queued.len, queued);
        try std.testing.expectEqual(case.released.len, released);
        for (result.programs[case.programs.len..]) |id| try std.testing.expect(id == null);
        try std.testing.expectEqualStrings(case.selected, state.selected.?);
        try std.testing.expectEqual(case.cursor, state.cursor);
        try std.testing.expectEqual(case.active, state.active);
        try std.testing.expectEqual(case.reloop, state.reloop);
        try std.testing.expectEqual(@as(?u16, case.cue), state.cue);
        try std.testing.expectEqualDeep(case.actors, state.actors);
        const before = state;
        try std.testing.expectEqualDeep(events.Effects{}, try state.tick(content.value, 0));
        try std.testing.expectEqualDeep(before, state);
        const bytes = try std.json.Stringify.valueAlloc(allocator, state, .{});
        defer allocator.free(bytes);
        var restored: events.State = .{};
        {
            const parsed = try std.json.parseFromSlice(events.State, allocator, bytes, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            try parsed.value.apply(content.value, &restored);
        }
        try std.testing.expectEqualDeep(before, restored);
        try std.testing.expectError(error.RoomAlreadyInitialized, restored.initializeRoom(content.value));
        try std.testing.expectEqualDeep(before, restored);
    }
    var reordered = content.value;
    var programs = [_]events.Program{ reordered.programs[1], reordered.programs[0] };
    reordered.programs = &programs;
    var state = try events.State.init(reordered);
    state.flags.story_0006 = true;
    const result = try state.initializeRoom(reordered);
    try std.testing.expectEqualStrings("vaa_room2_init_23", result.programs[0].?);
    try std.testing.expectEqualStrings("vaa_room2_init_24", result.programs[1].?);
}

test "initialization schema migration and invalid order fail before state mutation" {
    const content = try events.load(allocator, events.json);
    defer content.deinit();
    var invalid = content.value;
    invalid.initialization_order = null;
    try std.testing.expectError(error.MissingInitializationOrder, invalid.validate());
    invalid.initialization_order = &.{ "vaa_room2_init_23", "vaa_room2_init_23" };
    try std.testing.expectError(error.InvalidInitializationOrder, invalid.validate());
    invalid.initialization_order = &.{ "vaa_room2_init_23", "unknown" };
    var state = try events.State.init(content.value);
    const before = state;
    try std.testing.expectError(error.UnknownEvent, state.initializeRoom(invalid));
    try std.testing.expectEqualDeep(before, state);
    invalid = content.value;
    invalid.schema = "suikoden-opening-events/1";
    invalid.initialization_order = null;
    try invalid.validate();
    try std.testing.expectError(error.MissingInitializationOrder, state.initializeRoom(invalid));
    try state.select(invalid, "vaa_room2_init_23");
    var legacy = state;
    legacy.schema = "suikoden-opening-event-state/1";
    try legacy.apply(content.value, &state);
    try std.testing.expectEqualStrings("suikoden-opening-event-state/2", state.schema);
    try std.testing.expect(!state.initialized);
    try std.testing.expectError(error.EventBusy, state.initializeRoom(content.value));
}

test "opening selected streams match 524 complete original pumps and resume at every boundary" {
    const content = try events.load(allocator, events.json);
    defer content.deinit();
    const Tick = struct { cursor: u16, active: bool, reloop: bool, cue: ?u16, queued_cue: ?u16, released: []const events.ActorId, actors: [7]events.Actor };
    const Case = struct { program: []const u8, attached_mask: u8, cached_cue: ?u16, busy: [4]u16, ticks: [4]Tick };
    const vectors = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_events.json"), .{});
    defer vectors.deinit();
    try std.testing.expectEqual(@as(usize, 131), vectors.value.len);
    for (vectors.value) |case| {
        var state = try events.State.init(content.value);
        state.flags.story_0006 = true;
        state.cached_cue = case.cached_cue;
        for (&state.actors, 0..) |*actor, i| actor.* = .{ .attached = case.attached_mask & (@as(u8, 1) << @intCast(i)) != 0, .state = 9 };
        try state.select(content.value, case.program);
        for (case.busy, case.ticks) |busy, expected| {
            const bytes = try std.json.Stringify.valueAlloc(allocator, state, .{});
            defer allocator.free(bytes);
            var resumed: events.State = .{};
            {
                const parsed = try std.json.parseFromSlice(events.State, allocator, bytes, .{ .allocate = .alloc_always });
                defer parsed.deinit();
                try parsed.value.apply(content.value, &resumed);
            }
            const effects = try state.tick(content.value, busy);
            try std.testing.expectEqualDeep(effects, try resumed.tick(content.value, busy));
            try std.testing.expectEqualDeep(state, resumed);
            try std.testing.expectEqual(expected.cursor, state.cursor);
            try std.testing.expectEqual(expected.active, state.active);
            try std.testing.expectEqual(expected.reloop, state.reloop);
            try std.testing.expectEqual(expected.cue, state.cue);
            try std.testing.expectEqual(expected.queued_cue, effects.queued_cue);
            try std.testing.expectEqualDeep(expected.actors, state.actors);
            for (expected.released, 0..) |id, i| try std.testing.expectEqual(@as(?events.ActorId, id), effects.released[i]);
            for (effects.released[expected.released.len..]) |id| try std.testing.expect(id == null);
        }
        const before = state;
        try std.testing.expectEqualDeep(events.Effects{}, try state.tick(content.value, 0));
        try std.testing.expectEqualDeep(before, state);
    }
}

test "opening selection, unsupported data and invalid restored cursors leave state unchanged" {
    const content = try events.load(allocator, events.json);
    defer content.deinit();
    var state = try events.State.init(content.value);
    const initial = state;
    try std.testing.expectError(error.EventConditionFalse, state.select(content.value, "vaa_room2_init_24"));
    try std.testing.expectError(error.UnknownEvent, state.select(content.value, "missing"));
    try std.testing.expectEqualDeep(initial, state);
    try state.select(content.value, "vaa_room2_init_23");
    const selected = state;
    try std.testing.expectError(error.EventBusy, state.select(content.value, "vaa_room2_init_23"));
    var bad = selected;
    bad.cursor = 999;
    try std.testing.expectError(error.InvalidEventCursor, bad.apply(content.value, &state));
    bad = selected;
    bad.selected = "unknown";
    try std.testing.expectError(error.UnknownEvent, bad.apply(content.value, &state));
    bad = selected;
    bad.schema = "suikoden-opening-event-state/99";
    try std.testing.expectError(error.UnsupportedEventState, bad.apply(content.value, &state));
    try std.testing.expectEqualDeep(selected, state);
    try std.testing.expectError(error.UnsupportedEventSchema, events.load(allocator, "{\"schema\":\"new\",\"room\":\"vaa_room_2\",\"initial_flags\":{},\"programs\":[]}"));
    var invalid = content.value;
    var programs = [_]events.Program{content.value.programs[0]};
    var commands = [_]events.Command{ .{ .kind = .select_cue, .cue = 20 }, .{ .kind = .end_stream } };
    programs[0].commands = &commands;
    invalid.programs = &programs;
    try std.testing.expectError(error.UnsupportedEventCue, invalid.validate());
    commands[0] = .{ .kind = .release_actor };
    try std.testing.expectError(error.InvalidEventCommand, invalid.validate());
    var too_many: [9]events.Command = @splat(.{ .kind = .release_actor, .actor = .descriptor_0 });
    too_many[8] = .{ .kind = .end_stream };
    programs[0].commands = &too_many;
    try std.testing.expectError(error.TooManyEventEffects, invalid.validate());
}
