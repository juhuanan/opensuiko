const std = @import("std");
const camera = @import("battle_camera");

test "source state-1 camera reproduces the documented party projection" {
    const positions = [_][3]i32{
        .{ 120, 50, 0 }, .{ 112, 0, 0 },   .{ 120, -50, 0 },
        .{ 192, 75, 0 }, .{ 178, 25, 0 },  .{ 178, -25, 0 },
        .{ -88, 0, 0 },  .{ -88, -50, 0 }, .{ -88, 50, 0 },
        .{ -168, 0, 0 },
    };
    const expected = [_][2]f32{
        .{ 192.5, 170.4 }, .{ 227.1, 154.6 }, .{ 270.2, 144.4 },
        .{ 220.2, 205.4 }, .{ 252.4, 184.6 }, .{ 291.2, 170.5 },
        .{ 112.8, 95.5 },  .{ 148.9, 86.8 },  .{ 75.9, 105.5 },
        .{ 75.6, 76.0 },
    };
    for (positions, expected) |position, want| {
        const got = camera.project(1, position).?;
        try std.testing.expect(@abs(got.x - want[0]) < 0.5);
        try std.testing.expect(@abs(got.y - want[1]) < 0.5);
    }
}

test "battle scale is constant per camera state" {
    try std.testing.expectEqual(@as(i32, 4864), camera.scaleQ12(0));
    try std.testing.expectEqual(@as(i32, 3840), camera.scaleQ12(1));
    try std.testing.expectEqual(@as(i32, 3840), camera.scaleQ12(2));
    try std.testing.expectEqual(@as(f32, 1.1875), camera.actorScale(0));
    try std.testing.expectEqual(@as(f32, 0.9375), camera.actorScale(1));
}

test "battle camera state timeline matches the state-machine timers" {
    try std.testing.expectEqual(@as(usize, 0), camera.Timeline.blockAt(0));
    try std.testing.expectEqual(@as(usize, 0), camera.Timeline.blockAt(63));
    try std.testing.expectEqual(@as(usize, 1), camera.Timeline.blockAt(64));
    try std.testing.expectEqual(@as(usize, 1), camera.Timeline.blockAt(95));
    try std.testing.expectEqual(@as(usize, 1), camera.Timeline.blockAt(96));
    try std.testing.expectEqual(@as(usize, 1), camera.Timeline.blockAt(175));
    try std.testing.expectEqual(@as(usize, 2), camera.Timeline.blockAt(176));
    try std.testing.expectEqual(@as(usize, 2), camera.Timeline.blockAt(235));
    try std.testing.expectEqual(@as(usize, 4), camera.Timeline.stateAt(236));
    try std.testing.expectEqual(@as(usize, 2), camera.Timeline.blockAt(236));
}

test "state 2 exposes the unresolved scroll: party six is outside 320 px" {
    const sixth = [3]i32{ 178, -25, 0 };
    const settled = camera.project(1, sixth).?;
    const held = camera.project(2, sixth).?;
    try std.testing.expect(settled.x >= 0 and settled.x < 320);
    try std.testing.expect(held.x > 320);
}

test "scene scroll is an explicit zero-default input" {
    const point = camera.project(2, .{ 178, -25, 0 }).?;
    const zero = camera.projectWithScroll(2, .{ 178, -25, 0 }, .{}).?;
    const shifted = camera.projectWithScroll(2, .{ 178, -25, 0 }, .{ .x = -34, .y = 2 }).?;
    try std.testing.expectEqual(point.x, zero.x);
    try std.testing.expectEqual(point.y, zero.y);
    try std.testing.expectApproxEqAbs(point.x - 34, shifted.x, 0.001);
    try std.testing.expectApproxEqAbs(point.y + 2, shifted.y, 0.001);
}

test "camera channels integrate their source delta and duration" {
    var channel = camera.Channel{};
    channel.moveTo(.{ 100, 50, -20 }, 4);
    try std.testing.expectEqual(@as(i32, 25), channel.delta[0]);
    channel.tick();
    try std.testing.expectEqual(@as(i32, 25), channel.current[0]);
    channel.tick();
    channel.tick();
    channel.tick();
    try std.testing.expectEqual(@as([3]i32, .{ 100, 50, -20 }), channel.current);
    try std.testing.expectEqual(@as(u16, 0), channel.duration);
}

test "camera channels map to the block fields used by the scripts" {
    // Tai Ho script 9: op 20 mode 2 changes channel C over 20 frames.
    var channels = camera.default_channels;
    channels.c.moveTo(.{ 0, 0, 0 }, 20);
    try std.testing.expectEqual(@as(i32, 0), channels.block().position[0]);
    try std.testing.expectEqual(@as(i32, -768), channels.block().angles[0]);
    try std.testing.expectEqual(@as(i32, 1024), channels.block().c[2]);
    try std.testing.expectEqual(@as(i32, 4096), channels.block().d[0]);

    // Kirkis script 10: op 19 sets D to 3328 and op 17 restores the default angles.
    channels.d.moveTo(.{ 3328 << 12, 3328 << 12, 3328 << 12 }, 20);
    channels.a.moveTo(.{ -768 << 12, 0, 640 << 12 }, 20);
    for (0..20) |_| channels.tick();
    try std.testing.expectEqual(@as(i32, 3328), channels.block().d[0]);
    try std.testing.expectEqual(@as(i32, 640), channels.block().angles[2]);
}

test "all source camera presets are present" {
    try std.testing.expectEqual(@as(usize, 49), camera.presets.len);
    const resolver = camera.preset(0x8016D3DC).?;
    try std.testing.expectEqual(@as(i32, 80), resolver.position[0]);
    try std.testing.expectEqual(@as(i32, -768), resolver.angles[0]);
    try std.testing.expectEqual(@as(i32, 4864), resolver.d[0]);
}

test "character camera scripts drive the channels" {
    var tai = camera.default_channels;
    camera.applyOp(&tai, 20, &.{ 2, 20, 0, 0, 0 }, .{ 120 << 12, 50 << 12, 0 });
    for (0..20) |_| tai.tick();
    try std.testing.expectEqual(@as(i32, 120), tai.block().position[0]);
    try std.testing.expectEqual(@as(i32, 50), tai.block().position[1]);

    var kirkis = camera.default_channels;
    camera.applyOp(&kirkis, 20, &.{ 0, 20, 0, 0, 0 }, .{ 0, 0, 0 });
    camera.applyOp(&kirkis, 19, &.{ 20, 3328, 3328, 3328 }, .{ 0, 0, 0 });
    camera.applyOp(&kirkis, 17, &.{ 20, -768, 0, 640 }, .{ 0, 0, 0 });
    for (0..20) |_| kirkis.tick();
    try std.testing.expectEqual(@as(i32, 3328), kirkis.block().d[0]);
    try std.testing.expectEqual(@as(i32, 640), kirkis.block().angles[2]);
}

test "camera block families cover the source tables" {
    try std.testing.expectEqual(camera.Family.party_close, camera.family(camera.preset(0x8016D3DC).?));
    try std.testing.expectEqual(camera.Family.enemy_close, camera.family(camera.preset(0x8016D4FC).?));
    try std.testing.expectEqual(camera.Family.effect_close, camera.family(camera.preset(0x8016CC1C).?));
}

test "every family has a source preset" {
    const families = [_]camera.Family{ .party_close, .enemy_close, .effect_close, .wide_default, .special_zoom, .enemy_wide, .other };
    for (families) |f| try std.testing.expectEqual(f, camera.family(camera.presetForFamily(f)));
}

test "known spells select their source final camera block" {
    const firestorm = camera.castPreset("Firestorm").?;
    try std.testing.expectEqual(@as(i32, -160), firestorm.position[0]);
    try std.testing.expectEqual(@as(i32, 5120), firestorm.d[0]);
    try std.testing.expectEqual(@as(usize, 28), camera.cast_presets.len);
    try std.testing.expect(camera.castPreset("Unknown Spell") == null);
}

test "actor camera focus keeps Q12 remainders until the update after its timer ends" {
    var initial = camera.state0;
    initial.position = .{ 80, -3, 7 };
    var controller = try camera.ActorController.init(initial);
    const event = camera.ActorRequest{ .at = 61, .updates = 20, .channel = .focus, .binding = .target, .target_q12 = .{ 1, -3, 0 } };
    try controller.request(event, .{ -128 * 4096 + 13, 40 * 4096 - 5, 12345 });
    try std.testing.expectEqualDeep(initial.position, controller.sample().position);
    try std.testing.expectEqualDeep([3]i32{ -524274, 163832, 0 }, controller.target[0]);
    try std.testing.expectEqualDeep([3]i32{ -42597, 8806, -1433 }, controller.velocity[0]);
    controller.advance();
    try std.testing.expectEqualDeep([3]i32{ 285083, -3482, 27239 }, controller.current[0]);
    try std.testing.expectEqualDeep([3]i32{ 69, -1, 6 }, controller.sample().position);
    for (1..20) |_| controller.advance();
    try std.testing.expectEqual(@as(u16, 0), controller.remaining[0]);
    try std.testing.expectEqualDeep([3]i32{ -524260, 163832, 12 }, controller.current[0]);
    controller.advance();
    try std.testing.expectEqualDeep(controller.target[0], controller.current[0]);
}

test "same-update actor focus scale and angle requests keep independent camera channels" {
    var controller = try camera.ActorController.init(camera.state1);
    try controller.request(.{ .at = 1, .updates = 20, .channel = .focus, .binding = .absolute, .target_q12 = .{ 0, 0, 0 } }, .{ 0, 0, 0 });
    try controller.request(.{ .at = 1, .updates = 20, .channel = .scale, .binding = .absolute, .target_q12 = @splat(3328 * 4096) }, .{ 0, 0, 0 });
    try controller.request(.{ .at = 1, .updates = 20, .channel = .angles, .binding = .absolute, .target_q12 = .{ -768 * 4096, 0, 640 * 4096 } }, .{ 0, 0, 0 });
    for (0..20) |_| controller.advance();
    try std.testing.expectEqual(@as(i32, 639), controller.sample().angles[2]);
    try std.testing.expectEqualDeep([3]i32{ 3328, 3328, 3328 }, controller.sample().d);
    try std.testing.expectEqualDeep(camera.state1.c, controller.sample().c);
    controller.advance();
    try std.testing.expectEqualDeep([3]i32{ -768, 0, 640 }, controller.sample().angles);
    try std.testing.expectEqualDeep([3]i32{ 0, 0, 0 }, controller.sample().position);
}

test "actor camera rejects invalid clocks bindings and units before changing its state" {
    const event = camera.ActorRequest{ .at = 1, .updates = 20, .channel = .focus, .binding = .absolute, .target_q12 = .{ 1, -3, 7 } };
    var controller = try camera.ActorController.init(camera.state0);
    const before = controller;
    var bad = event;
    bad.at = 0;
    try std.testing.expectError(error.InvalidActorCamera, controller.request(bad, .{ 0, 0, 0 }));
    bad = event;
    bad.updates = 0;
    try std.testing.expectError(error.InvalidActorCamera, controller.request(bad, .{ 0, 0, 0 }));
    bad = event;
    bad.channel = .angles;
    bad.binding = .actor;
    try std.testing.expectError(error.InvalidActorCamera, controller.request(bad, .{ 0, 0, 0 }));
    bad = event;
    bad.target_q12[0] = 32768;
    try std.testing.expectError(error.InvalidActorCamera, controller.request(bad, .{ 0, 0, 0 }));
    try std.testing.expectEqualDeep(before, controller);
}

test "Critical camera Q12 transition keeps fractional target focus and rejects unsafe input" {
    var controller = try camera.ActorController.init(camera.state2);
    const initial = controller.current;
    const target = camera.Q12Block{ .position = .{ -128 * 4096 + 1024, -50 * 4096 - 512, -20 * 4096 }, .angles = .{ -864 * 4096, 0, 512 * 4096 }, .c = .{ 0, 0, 1024 * 4096 }, .d = @splat(10000 * 4096) };
    try controller.requestQ12(target, 20);
    const before = controller;
    var bad = target;
    bad.d[0] = std.math.maxInt(i32);
    try std.testing.expectError(error.InvalidActorCamera, controller.requestQ12(bad, 20));
    try std.testing.expectError(error.InvalidActorCamera, controller.requestQ12(target, 0));
    try std.testing.expectEqualDeep(before, controller);
    for (1..22) |age| {
        controller.advance();
        for (0..4) |channel| for (0..3) |axis| {
            const wanted = if (age <= 20) initial[channel][axis] + @divTrunc(before.target[channel][axis] - initial[channel][axis], 20) * @as(i32, @intCast(age)) else before.target[channel][axis];
            try std.testing.expectEqual(wanted, controller.current[channel][axis]);
        };
    }
    try std.testing.expectEqualDeep(target.position, controller.current[0]);
}

test "dice source model preserves integer projection and face depth keys" {
    const dice = @import("dice_presentation");
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "kit/data/reports/dice_presentation.json", allocator, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "../kit/data/reports/dice_presentation.json", allocator, .limited(128 * 1024)),
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try dice.load(allocator, bytes);
    defer parsed.deinit();
    var hud_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("BET       1000\nMONEY     2000", try parsed.value.formatHud(&hud_buffer, 1000, 2000));
    try std.testing.expectEqualStrings("BET          1\nMONEY        0", try parsed.value.formatHud(&hud_buffer, 1_000_001, 0));
    try std.testing.expectEqualDeep([4]dice.Cursor{ .{ .x = 117, .y = 120 }, .{ .x = 117, .y = 120 }, .{ .x = 111, .y = 128 }, .{ .x = 123, .y = 128 } }, parsed.value.cursorVertices(.{ .x = 117, .y = 120 }));
    const Entry = @import("journey").dice.Entry;
    var flow: Entry = .{};
    var box: Entry.Dialogue = .{};
    try box.tick(&flow, parsed.value, .{}, 1, "");
    try box.tick(&flow, parsed.value, .{}, 1, "");
    try std.testing.expectEqualDeep(dice.Rectangle{ .x = 155, .y = 114, .width = 17, .height = 3 }, box.outline(parsed.value).?);
    for (0..13) |_| try box.tick(&flow, parsed.value, .{}, 1, "");
    try std.testing.expectEqualDeep(parsed.value.entry_layout.box, box.outline(parsed.value).?);
    try box.tick(&flow, parsed.value, .{}, 1, "");
    try box.tick(&flow, parsed.value, .{}, 1, "");
    try std.testing.expectEqual(@as(u16, 0), box.text.length);
    try box.tick(&flow, parsed.value, .{}, 1, "");
    try std.testing.expectEqualStrings("W", box.text.visible());
    var pose = parsed.value.initial_poses[0];
    const mesh = parsed.value.project(pose);
    try std.testing.expectEqualDeep(dice.Point{ .x = 251, .y = 21, .depth = 191 }, mesh.points[0]);
    try std.testing.expectEqualDeep([6]i16{ 191, 191, 191, 191, 191, 209 }, mesh.depth_keys);
    try std.testing.expectEqualDeep([4]u3{ 4, 0, 6, 2 }, parsed.value.faces[1].vertices);
    const draw_list = parsed.value.drawList(parsed.value.initial_poses);
    const reference = try std.json.parseFromSlice(struct { draw_evidence: struct { initial_order: [18][2]u8 } }, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer reference.deinit();
    for (draw_list, reference.value.draw_evidence.initial_order) |quad, expected| {
        try std.testing.expectEqual(@as(u8, quad.die), expected[0]);
        try std.testing.expectEqual(@as(u8, quad.face), expected[1]);
    }
    try std.testing.expectEqual(@as(u2, 2), draw_list[0].die);
    try std.testing.expectEqual(@as(u3, 5), draw_list[0].face);
    try std.testing.expectEqual(@as(u2, 0), draw_list[17].die);
    try std.testing.expectEqual(@as(u3, 0), draw_list[17].face);
    pose.angles[1] = 1024;
    try std.testing.expectEqual(@as(i16, 209), parsed.value.project(pose).points[0].depth);
    var invalid = parsed.value;
    invalid.faces[0].vertices[1] = invalid.faces[0].vertices[0];
    try std.testing.expectError(error.InvalidDiceFace, invalid.validate());
    var animation = try dice.Animation.init(parsed.value, .{ .poses = parsed.value.initial_poses, .pips = .{ 1, 3, 6 }, .target_x = 160, .target_y = 120, .strength = 32 });
    const first = animation.tick();
    try std.testing.expectEqual(@as(i16, 260), first.poses[0].center_x);
    try std.testing.expectEqual([3]i16{ 64, 32, 0 }, first.poses[0].angles);
    try std.testing.expectEqual(@as(i16, 255), animation.poses()[0].center_x);
    var landings: usize = 0;
    for (0..600) |_| {
        const frame = animation.tick();
        for (frame.landed) |landed| if (landed) {
            landings += 1;
        };
        if (frame.complete) break;
    }
    try std.testing.expect(animation.complete);
    try std.testing.expectEqual(@as(usize, 3), landings);
    for ([_]u8{ 1, 3, 6 }, animation.poses()) |pip, settled| try std.testing.expectEqual(parsed.value.settled_angles[pip - 1], settled.angles);
}
