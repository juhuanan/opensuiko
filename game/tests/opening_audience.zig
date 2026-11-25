const std = @import("std");
const audience = @import("journey").opening.audience;
const allocator = std.testing.allocator;

fn normalizedText(bytes: []const u8, output: []u8) []const u8 {
    var length: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " ");
        @memcpy(output[length..][0..trimmed.len], trimmed);
        length += trimmed.len;
        output[length] = '\n';
        length += 1;
    }
    return std.mem.trimEnd(u8, output[0..length], " \n");
}

test "all22 audience texts match7616 original widget updates including names, pages and fast-forward countdowns" {
    const content = try audience.load(allocator, audience.json);
    defer content.deinit();
    const Checkpoint = struct { tick: u32, visible: []const u8, page_wait: bool, done: bool, countdown: u8, pace: u8, fast: bool };
    const Case = struct { text: []const u8, accelerated: bool, updates: u32, acknowledgements: []const u32, checkpoints: []const Checkpoint };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_text.json"), .{});
    defer cases.deinit();
    try std.testing.expectEqual(@as(usize, 44), cases.value.len);
    for (cases.value) |case| {
        const text = content.value.text(case.text).?;
        var state = audience.TextState.start(text, content.value.default_text_pace);
        var ack: usize = 0;
        var checkpoint: usize = 0;
        for (0..case.updates) |tick| {
            try state.tick(text, "Tir");
            if (ack < case.acknowledgements.len and case.acknowledgements[ack] == tick) {
                state.acknowledge();
                ack += 1;
            }
            if (checkpoint < case.checkpoints.len and case.checkpoints[checkpoint].tick == tick) {
                const expected = case.checkpoints[checkpoint];
                var buffer: [4096]u8 = undefined;
                try std.testing.expectEqualStrings(expected.visible, normalizedText(state.visible(), &buffer));
                try std.testing.expectEqual(expected.page_wait, state.page_wait);
                try std.testing.expectEqual(expected.done, state.done);
                try std.testing.expectEqual(expected.countdown, state.countdown);
                try std.testing.expectEqual(expected.pace, state.pace);
                try std.testing.expectEqual(expected.fast, state.fast);
                checkpoint += 1;
            }
        }
        try std.testing.expect(state.done);
        try std.testing.expectEqual(case.checkpoints.len, checkpoint);
        try std.testing.expectEqual(case.acknowledgements.len, ack);
    }
}

test "audience controller completes both source choice arms with Hero movement and final story write" {
    const content = try audience.load(allocator, audience.json);
    defer content.deinit();
    for (0..2) |choice| {
        var state = try audience.State.start(content.value, .{ .hero = .{ .x = 512, .y = 584 }, .camera = .{ .x = 320, .y = 472 }, .width = 640, .height = 896, .player_name = "Tir" });
        var text_branch_seen = false;
        var complete_events: usize = 0;
        for (0..30000) |_| {
            var input: audience.Input = .{ .confirm = state.elapsed % 2 == 0 };
            if (state.choice_open and state.choice != choice) input = .{ .down = true };
            if (state.cursor < content.value.commands.len) {
                const command = content.value.commands[state.cursor];
                if (command.kind == .text) {
                    if (std.mem.eql(u8, command.text.?, if (choice == 0) "area_text_0_11" else "area_text_0_12")) text_branch_seen = true;
                    try std.testing.expect(!std.mem.eql(u8, command.text.?, if (choice == 0) "area_text_0_12" else "area_text_0_11"));
                }
            }
            const output = try state.tick(content.value, input);
            complete_events += @intFromBool(output.completed);
            if (!state.active) break;
        }
        try std.testing.expect(!state.active);
        try std.testing.expect(text_branch_seen);
        try std.testing.expect(state.audience_complete and state.following_teo);
        try std.testing.expectEqual(@as(usize, 1), complete_events);
        try std.testing.expectEqual(@as(i32, 184), state.actors[state.hero].motion.x);
        try std.testing.expectEqual(@as(i32, 624), state.actors[state.hero].motion.y);
        try std.testing.expect(!state.actors[state.hero].motion.moving());
        try std.testing.expect(!state.actors[state.double].attached);
        try std.testing.expect(!state.tracksBusy());
        try std.testing.expectEqual(@as(u16, 129), state.cue);
        const elapsed = state.elapsed;
        try std.testing.expectEqualDeep(audience.Emission{}, try state.tick(content.value, .{ .confirm = true }));
        try std.testing.expectEqual(elapsed, state.elapsed);
    }
}

test "audience actor motion matches51 original signed interpolation cases" {
    const Case = struct { speed: u8, offset_x: i16, offset_y: i16, next_x: i16, next_y: i16 };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_motion.json"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        var actor: audience.ActorMotion = .{ .x = 40, .y = 80, .speed = case.speed, .offset_x = case.offset_x, .offset_y = case.offset_y };
        actor.tick();
        try std.testing.expectEqual(case.next_x, actor.offset_x);
        try std.testing.expectEqual(case.next_y, actor.offset_y);
    }
    var actor: audience.ActorMotion = .{ .x = 0, .y = 80, .speed = 2 };
    actor.step(.left);
    try std.testing.expectEqual(@as(i32, 2040), actor.x);
    try std.testing.expectEqual(@as(i16, 8), actor.offset_x);
    for (0..4) |_| actor.tick();
    try std.testing.expect(!actor.moving());
}

test "all19 audience actor tracks match344 original queue-consumer updates" {
    const content = try audience.load(allocator, audience.json);
    defer content.deinit();
    const Update = struct { effects: []const audience.Effect, motion: u8, active: bool };
    const Case = struct { track: []const u8, updates: []const Update };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_tracks.json"), .{});
    defer cases.deinit();
    try std.testing.expectEqual(@as(usize, 19), cases.value.len);
    for (cases.value) |case| {
        const track = content.value.track(case.track).?;
        var state = try audience.TrackState.start(track, 7);
        for (case.updates) |update| {
            const effect = try state.tick(track, false);
            try std.testing.expectEqual(update.effects.len, @intFromBool(effect != null));
            if (effect) |actual| {
                try std.testing.expectEqual(update.effects[0].kind, actual.kind);
                try std.testing.expectEqual(update.effects[0].direction, actual.direction);
                try std.testing.expectEqualStrings(update.effects[0].actor, actual.actor);
            }
            try std.testing.expectEqual(update.motion, state.motion);
            try std.testing.expectEqual(update.active, state.active);
        }
        try std.testing.expect(!state.active);
        try std.testing.expectEqual(@as(u8, 7), state.motion);
        try std.testing.expectEqual(@as(?audience.Effect, null), try state.tick(track, false));
    }
    try std.testing.expectEqual(@as(usize, 201), content.value.commands.len);
    try std.testing.expectEqual(@as(usize, 22), content.value.texts.len);
}

test "audience tracks retain their cursor while an actor moves and reject malformed content" {
    const content = try audience.load(allocator, audience.json);
    defer content.deinit();
    const track = content.value.tracks[0];
    var state = try audience.TrackState.start(track, 1);
    const before = state;
    try std.testing.expectEqual(@as(?audience.Effect, null), try state.tick(track, true));
    try std.testing.expectEqualDeep(before, state);
    _ = try state.tick(track, false);
    const started = state;
    try std.testing.expect(state.remaining != 0);
    try std.testing.expectEqual(@as(?audience.Effect, null), try state.tick(track, true));
    try std.testing.expectEqualDeep(started, state);
    var bad = content.value;
    bad.schema = "suikoden-opening-audience/999";
    try std.testing.expectError(error.UnsupportedAudienceSchema, bad.validate());
    bad = content.value;
    bad.nominal_updates_per_second = 30;
    try std.testing.expectError(error.UnsupportedOpeningCadence, bad.validate());
    const invalid = audience.Track{ .id = "bad", .actor = "hero", .commands = &.{ .{ .kind = .advance, .cells = 1 }, .{ .kind = .finish } } };
    try std.testing.expectError(error.InvalidAudienceTrack, audience.TrackState.start(invalid, 1));
}

test "follower position history, signed offsets and orientation match196 original ground-path cases" {
    const content = try audience.load(allocator, audience.json);
    defer content.deinit();
    const Case = struct { flags: u2, x: i32, y: i32, direction: ?u8, next_x: i32, next_y: i32, offset_x: i16, offset_y: i16, next_flags: u2, previous_x: i32, previous_y: i32 };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_follower.json"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        var follower = try audience.Follower.start(content.value, .{ .x = 464, .y = 608, .speed = 2 });
        follower.actor.motion.x = case.x;
        follower.actor.motion.y = case.y;
        follower.actor.orientation_flags = case.flags;
        follower.previous_hero = .{ .x = 456, .y = 608 };
        try follower.beforeHeroStep(content.value, .{ .x = 464, .y = 608, .speed = 2 });
        try std.testing.expectEqual(case.next_x, follower.actor.motion.x);
        try std.testing.expectEqual(case.next_y, follower.actor.motion.y);
        try std.testing.expectEqual(case.offset_x, follower.actor.motion.offset_x);
        try std.testing.expectEqual(case.offset_y, follower.actor.motion.offset_y);
        try std.testing.expectEqual(case.next_flags, follower.actor.orientation_flags);
        try std.testing.expectEqual(case.previous_x, follower.previous_hero.x);
        try std.testing.expectEqual(case.previous_y, follower.previous_hero.y);
        if (case.direction) |direction| try std.testing.expectEqual(direction, follower.actor.variant);
    }
}

test "window opening and closing match336 original outline updates with signed coordinate truncation" {
    const Line = @import("journey").opening.presentation.Line;
    const Update = struct { remaining: u8, open: bool, lines: []const Line };
    const Case = struct { actor_x: i32, actor_y: i32, camera_x: i32, camera_y: i32, origin: audience.Point, states: []const struct { closing: bool, updates: []const Update } };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_windows.json"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        var box: audience.Box = .{ .phase = .opening, .transition = 20, .origin = .{ .x = case.actor_x + 8 - case.camera_x, .y = case.actor_y - 24 - case.camera_y } };
        try std.testing.expectEqualDeep(case.origin, box.origin);
        for (case.states) |phase| {
            if (phase.closing) {
                box.phase = .closing;
                box.transition = 20;
            }
            for (phase.updates) |expected| {
                box.tickTransition();
                try std.testing.expectEqual(expected.remaining, box.transition);
                try std.testing.expectEqual(expected.open, box.phase == .open);
                if (box.outline()) |rect| {
                    try std.testing.expectEqual(@as(usize, 4), expected.lines.len);
                    try std.testing.expectEqualDeep([4]Line{
                        .{ .x1 = rect.x, .y1 = rect.y, .x2 = rect.x + rect.w, .y2 = rect.y },
                        .{ .x1 = rect.x + rect.w, .y1 = rect.y, .x2 = rect.x + rect.w, .y2 = rect.y + rect.h },
                        .{ .x1 = rect.x + rect.w, .y1 = rect.y + rect.h, .x2 = rect.x, .y2 = rect.y + rect.h },
                        .{ .x1 = rect.x, .y1 = rect.y + rect.h, .x2 = rect.x, .y2 = rect.y },
                    }, expected.lines[0..4].*);
                } else try std.testing.expectEqual(@as(usize, 0), expected.lines.len);
            }
        }
    }
}

test "selection highlight matches63 original updates including interrupted motion, additive fill and beveled border" {
    const presentation = @import("journey").opening.presentation;
    const Update = struct { select: ?u1, remaining: u8, moving: bool, y: i32, commands: []const presentation.Piece };
    const cases = try std.json.parseFromSlice([]const Update, allocator, @embedFile("fixtures/opening_selection.json"), .{});
    defer cases.deinit();
    var state: audience.Selection = .{};
    var list: presentation.List = .{};
    for (cases.value) |expected| {
        if (expected.select) |row| state.select(row);
        state.tick();
        try std.testing.expectEqual(expected.remaining, state.remaining);
        try std.testing.expectEqual(expected.moving, state.moving);
        try std.testing.expectEqual(expected.y, state.y);
        list.length = 0;
        try list.selection(state);
        try std.testing.expectEqualDeep(expected.commands, list.pieces[0..list.length]);
    }
}

test "complete ground field passes match2304 original clock, pose and interpolation cases" {
    const parsed = try audience.load(allocator, audience.json);
    defer parsed.deinit();
    const Case = struct {
        role: enum { hero, follower, npc },
        speed: u8,
        hero_speed: u8,
        offset_x: i16,
        offset_y: i16,
        frame: u8,
        auto_animate: bool,
        boost: bool,
        x: i32,
        next_x: i16,
        next_y: i16,
        next_frame: u8,
        remaining: u16,
        sprite_ticks: usize,
        pose: ?struct { x: i32, y: i32, frame: u8 },
    };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_field.json"), .{});
    defer cases.deinit();
    const clip: audience.AnimationClip = .{ .flags = 3, .ticks = &.{ 1, 1, 1, 1 }, .bounds = &@as([4]audience.Bounds, @splat(.{ .width = 32, .height = 64 })) };
    const animation = [_]audience.Animation{.{ .graphic = "hero", .clips = @splat(clip) }};
    var content = parsed.value;
    content.animations = &animation;
    for (cases.value) |case| {
        var actor: audience.Avatar = .{ .id = "actor", .graphic = "hero", .motion = .{ .x = case.x, .y = 360, .offset_x = case.offset_x, .offset_y = case.offset_y, .speed = case.speed }, .variant = 0, .sprite = .{ .frame = case.frame, .remaining = 1, .active = true, .repeating = true }, .attached = true, .auto_animate = case.auto_animate };
        actor.fieldTick(content, case.role != .npc, .{ .camera = .{ .x = 40, .y = 240 }, .hero_speed = case.hero_speed, .allow_player_animation = case.boost });
        try std.testing.expectEqual(case.next_x, actor.motion.offset_x);
        try std.testing.expectEqual(case.next_y, actor.motion.offset_y);
        try std.testing.expectEqual(case.next_frame, actor.sprite.frame);
        try std.testing.expectEqual(case.remaining, actor.sprite.remaining);
        const pose = actor.drawPose();
        try std.testing.expectEqual(case.pose != null, pose.visible);
        if (case.pose) |expected| {
            try std.testing.expectEqual(expected.x, pose.x);
            try std.testing.expectEqual(expected.y, pose.y);
            try std.testing.expectEqual(expected.frame, pose.frame);
        }
    }
}

test "all19 audience queues preserve38 original pre-field animation clock cases" {
    const parsed = try audience.load(allocator, audience.json);
    defer parsed.deinit();
    const Case = struct { track: []const u8, moving: bool, sprite_ticks: usize };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/opening_queue_clocks.json"), .{});
    defer cases.deinit();
    const clip: audience.AnimationClip = .{ .flags = 3, .ticks = &.{ 1, 1, 1, 1 }, .bounds = &@as([4]audience.Bounds, @splat(.{ .width = 32, .height = 64 })) };
    var animations: [32]audience.Animation = undefined;
    for (parsed.value.animations, 0..) |entry, i| animations[i] = .{ .graphic = entry.graphic, .clips = @splat(clip) };
    var content = parsed.value;
    content.animations = animations[0..parsed.value.animations.len];
    for (cases.value) |case| {
        var state = try audience.State.start(content, .{ .hero = .{ .x = 512, .y = 584 }, .camera = .{ .x = 320, .y = 472 }, .width = 640, .height = 896, .player_name = "Tir" });
        const track = content.track(case.track).?;
        var index: u8 = 0;
        for (state.actors[0..state.actor_count], 0..) |actor, i| if (std.mem.eql(u8, actor.id, track.actor)) {
            index = @intCast(i);
        };
        if (index == state.double) state.actors[index].attached = true;
        state.actors[index].motion.speed = 2;
        state.actors[index].motion.offset_x = if (case.moving) 4 else 0;
        state.jobs[0] = .{ .track = track.id, .actor = index, .state = try audience.TrackState.start(track, 7) };
        for (content.commands, 0..) |command, i| if (command.kind == .wait_tracks) {
            state.cursor = @intCast(i);
            break;
        };
        _ = try state.tick(content, .{});
        try std.testing.expectEqual(@as(u8, @intCast(case.sprite_ticks % 4)), state.actors[index].drawPose().frame);
    }
}
