const std = @import("std");
const trick = @import("battle").unite_trick;
const allocator = std.testing.allocator;
const Fixture = struct {
    phases: [3]struct { updates: u16, heights: ?trick.Heights = null },
    objects: struct { delays: [8]u16, initial_y_q12: [8]i32, initial_z_q12: i32 },
};
fn fixture() !std.json.Parsed(Fixture) {
    return std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/trick_controller.json"), .{ .ignore_unknown_fields = true });
}

test "Trick wave gates all phases and uses strict once-only target crossings" {
    const parsed = try fixture();
    defer parsed.deinit();
    const source = parsed.value;
    var state = try trick.State.init(source.phases[1].heights.?);
    const targets = [6]?i32{ 0, -8 * 4096, -16 * 4096, -399 * 4096, -400 * 4096, null };
    const expected_hits = [_]u16{ 65, 66, 67, 114 };
    var sounds: usize = 0;
    var hits: u6 = 0;
    for (1..179) |update| {
        if (update == 1 or update == 65 or update == 115) {
            const before = state;
            try std.testing.expectEqualDeep(trick.Events{}, state.advance(false, targets));
            try std.testing.expectEqualDeep(before, state);
        }
        const event = state.advance(true, targets);
        if (event.sound) |sound| {
            if (update == 1) try std.testing.expectEqual(@as(u16, 0x513), sound) else {
                try std.testing.expectEqual(@as(u16, 0x81B), sound);
                try std.testing.expect(update == 65 or update == 81 or update == 97 or update == 113);
            }
            sounds += 1;
        }
        try std.testing.expectEqual(@as(u6, 0), event.hits & hits);
        hits |= event.hits;
        for (expected_hits, 0..) |at, slot| if (event.hits & (@as(u6, 1) << @as(u3, @intCast(slot))) != 0) try std.testing.expectEqual(at, update);
        try std.testing.expectEqual(update == 178, event.returns);
        try std.testing.expectEqual(event.returns, event.cleanup);
        try std.testing.expectEqual(event.returns, event.clear_trigger);
        for (source.objects.delays, 0..) |delay, slot| {
            try std.testing.expectEqual(source.objects.initial_y_q12[slot], state.local_q12[slot][1]);
            const age = update -| delay;
            try std.testing.expectEqual(@as(u16, @intCast(age)), state.animation_updates[slot]);
            try std.testing.expectEqual(@min(@as(i32, 0), source.objects.initial_z_q12 + @as(i32, @intCast(age)) * 76800), state.local_q12[slot][2]);
            const bit = @as(u8, 1) << @as(u3, @intCast(slot));
            try std.testing.expectEqual(age > 0, state.enabled & bit != 0);
            try std.testing.expectEqual(age > 16, state.settled & bit != 0);
        }
        if (update == 64) try std.testing.expectEqualDeep([3]i32{ 0, 0, 0 }, state.translation);
        if (update >= 65 and update <= 114) {
            try std.testing.expectEqual(-8 * @as(i32, @intCast(update - 64)), state.translation[0]);
            try std.testing.expectEqual(source.phases[1].heights.?[update - 65], state.translation[2]);
        }
    }
    try std.testing.expectEqual(@as(usize, 5), sounds);
    try std.testing.expectEqual(@as(u6, 15), hits);
    try std.testing.expectEqualDeep([3]i32{ -400, 0, -325 }, state.translation);
    const final = state;
    try std.testing.expectEqualDeep(trick.Events{}, state.advance(true, targets));
    try std.testing.expectEqualDeep(final, state);
}

test "Trick crossing samples current fractional X and never retries a marked slot" {
    const parsed = try fixture();
    defer parsed.deinit();
    var state = try trick.State.init(parsed.value.phases[1].heights.?);
    var targets: [6]?i32 = @splat(null);
    for (0..64) |_| _ = state.advance(true, targets);
    targets[0] = -8 * 4096 + 1;
    try std.testing.expectEqual(@as(u6, 0), state.advance(true, targets).hits);
    targets[0] = -16 * 4096 + 4095;
    try std.testing.expectEqual(@as(u6, 0), state.advance(true, targets).hits);
    targets[0] = -24 * 4096 - 1;
    try std.testing.expectEqual(@as(u6, 0), state.advance(true, targets).hits);
    targets[0] = -31 * 4096;
    try std.testing.expectEqual(@as(u6, 1), state.advance(true, targets).hits);
    // Availability is handled by the damage host; crossing has already consumed this slot.
    targets[0] = 999 * 4096;
    for (0..46) |_| try std.testing.expectEqual(@as(u6, 0), state.advance(true, targets).hits);
}

test "Trick wave rejects invalid exported height bounds" {
    const parsed = try fixture();
    defer parsed.deinit();
    var heights = parsed.value.phases[1].heights.?;
    heights[0] = 1;
    try std.testing.expectError(error.InvalidTrickHeights, trick.State.init(heights));
    heights[0] = -31;
    try std.testing.expectError(error.InvalidTrickHeights, trick.State.init(heights));
}

test "Trick member programs gate the wave and continue returning after controller cleanup" {
    const battle = @import("battle");
    const parsed = try fixture();
    defer parsed.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer library.deinit();
    const Observer = struct {
        fn command(_: *anyopaque, _: u16, request: battle.actor_program.Command, _: bool) !bool {
            if (request != .sound) return error.UnexpectedTrickCommand;
            return true;
        }
        fn previous(_: *anyopaque, _: u16) !battle.presentation.ScreenPoint {
            return .{ .x = 17, .y = 29, .depth = 1024 };
        }
    };
    for ([_][2]u16{ .{ 0, 1 }, .{ 1, 0 } }) |members| {
        var actors: [2]battle.actor_host.Actor = undefined;
        var observer = Observer{};
        const binding = library.value.unites[14];
        for (binding.members, members, 0..) |member, index, ordinal| actors[index] = try battle.actor_host.Actor.init(library.value.animations.find(member.id).?, .{ 0, @as(i32, @intCast(ordinal)) * 40 * 4096, 0 });
        var runtime = battle.actor_host.Runtime{ .actors = &actors, .auxiliary = &.{}, .library = library.value.library(), .external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previous } };
        for (binding.members, members) |member, index| try runtime.dispatch(index, null, library.value.programs.find(member.programs[0]).?);
        var state = try trick.State.init(parsed.value.phases[1].heights.?);
        var began = false;
        var returned = false;
        for (0..450) |age| {
            runtime.beginUpdate();
            const triggered = actors[members[1]].signals & 16 != 0;
            const events = state.advance(triggered, @splat(null));
            if (!began and triggered) {
                try std.testing.expectEqual(@as(usize, 99), age);
                try std.testing.expectEqual(@as(?u16, 0x513), events.sound);
                began = true;
            }
            if (events.returns) {
                try std.testing.expectEqual(@as(usize, 276), age);
                try std.testing.expect(events.cleanup and events.clear_trigger and state.finished);
                for (members) |member| try runtime.dispatch(member, null, library.value.programs.find("common/unite_return").?);
                actors[members[1]].signals &= ~@as(u16, 16);
                for (members) |member| try std.testing.expect(!actors[member].machine.?.halted);
                returned = true;
            }
            for (0..2) |member| try runtime.stepActor(@intCast(member));
        }
        try std.testing.expect(began and returned);
        for (members) |member| try std.testing.expect(actors[member].released and actors[member].machine.?.halted);
        try std.testing.expectEqual(@as(u16, 0), actors[members[1]].signals & 16);
    }
}
