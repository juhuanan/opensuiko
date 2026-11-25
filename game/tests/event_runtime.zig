const std = @import("std");
const runtime = @import("event_runtime");
const adapter = @import("opening_event_adapter");
const audience = @import("opening_audience");

const allocator = std.testing.allocator;

test "recruitment registration refreshes the castle tier" {
    var story: runtime.StoryState = .{ .castle_tier = 1 };
    @memset(story.recruit_flags[0..24], 1);
    story.toggleRecruit(24, false);
    try std.testing.expectEqual(@as(u8, 1), story.castle_tier);
    story.scenario[15] = 2;
    story.toggleRecruit(25, true);
    try std.testing.expectEqual(@as(u8, 1), story.castle_tier);
    story.toggleRecruit(25, false);
    try std.testing.expectEqual(@as(u8, 2), story.castle_tier);
}

test "camera push IR requires its capability and holds the issuing command" {
    const request: runtime.camera_push.Request = .{ .dx = -16, .dy = -8, .updates = 8, .repeats = 1 };
    var commands = [_]runtime.Command{
        .{ .kind = .camera_push, .push = request, .wait = .{ .kind = .camera_push, .id = "camera_push" } },
        .{ .kind = .end_stream },
    };
    var content: runtime.Content = .{
        .schema = runtime.camera_push_schema,
        .id = "push_control",
        .content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .forward_branches = true,
        .programs = &.{.{ .id = "push", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &commands }},
    };
    try content.validate();
    var story = try runtime.StoryState.init(&.{content});
    var instance = try runtime.start(content, &story, "push");
    const first = try runtime.step(content, &instance, &story, .{});
    try std.testing.expectEqual(.camera_push, first.batch.?.slice()[0].kind);
    try runtime.acknowledge(content, &instance, &story, first.batch.?.id);
    const waiting = try runtime.step(content, &instance, &story, .{});
    try std.testing.expect(waiting.batch == null and instance.execution.pc == 1 and instance.execution.active);
    var malformed = instance;
    malformed.execution.wait.?.id = "other_clock";
    try std.testing.expectError(error.InvalidEventWait, malformed.validate(content));
    const completed = try runtime.step(content, &instance, &story, .{ .completions = &.{"camera_push"} });
    try std.testing.expectEqual(.end_stream, completed.batch.?.slice()[0].kind);
    try runtime.acknowledge(content, &instance, &story, completed.batch.?.id);
    try std.testing.expect(!instance.execution.active);
    content.schema = runtime.actor_owners_schema;
    try std.testing.expectError(error.InvalidEventCommand, content.validate());
    content.schema = runtime.camera_push_schema;
    commands[0].push.?.repeats = 0;
    try std.testing.expectError(error.InvalidEventCommand, content.validate());
    const legacy = try std.json.Stringify.valueAlloc(allocator, runtime.Command{ .kind = .end_stream }, .{});
    defer allocator.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "\"push\"") == null);
}

fn load(comptime T: type, path: []const u8) !std.json.Parsed(T) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(T, allocator, bytes, .{ .allocate = .alloc_always });
}

fn roundTrip(comptime T: type, value: T) !std.json.Parsed(T) {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    return std.json.parseFromSlice(T, allocator, bytes, .{ .allocate = .alloc_always });
}

const VaaFixture = struct {
    schema: []const u8,
    program: []const u8,
    choice: u1,
    entry: std.json.Value,
    expected: struct {
        story_byte_0: u8,
        audience_complete: bool,
        following_teo: bool,
        completed: bool,
    },
    independent_witnesses: []const []const u8,
};

fn checkAudience(path: []const u8) !void {
    const fixture = try load(VaaFixture, path);
    defer fixture.deinit();
    try std.testing.expectEqualStrings("suikoden-event-reference/1", fixture.value.schema);
    try std.testing.expect(fixture.value.independent_witnesses.len >= 4);
    const content = try load(runtime.Content, "game/assets/events/vaa_audience_choice.json");
    defer content.deinit();
    const script = try audience.load(allocator, audience.json);
    defer script.deinit();
    const stage: audience.Stage = .{
        .hero = .{ .x = 64 * 8, .y = 73 * 8 },
        .camera = .{ .x = 0, .y = 0 },
        .width = 640,
        .height = 480,
        .player_name = "Tir",
    };
    var reference = try audience.State.start(script.value, stage);
    var story = try runtime.StoryState.init(&.{content.value});
    var live = try adapter.Adapter.start(content.value, script.value, reference, &story);
    var sent_direction = false;
    var ticks: usize = 0;
    while (ticks < 20000) : (ticks += 1) {
        var input: audience.Input = .{};
        if (reference.choice_open) {
            if (fixture.value.choice == 1 and !sent_direction) {
                input.down = true;
                sent_direction = true;
            } else input.confirm = true;
        } else input.confirm = ticks % 5 == 0;
        const expected = try reference.tick(script.value, input);
        const actual = try live.tick(content.value, script.value, &story, input);
        try std.testing.expectEqual(expected.cue, actual.cue);
        try std.testing.expectEqual(expected.completed, actual.completed);
        if (!std.meta.eql(reference, live.stage)) {
            std.debug.print("first audience divergence tick={} reference_pc={} core_pc={} reference_delay={} core_delay={} reference_wait={} core_wait={?}\n", .{ ticks, reference.cursor, live.instance.execution.pc, reference.delay, live.stage.delay, reference.choice_open, live.instance.execution.wait });
            inline for (@typeInfo(audience.State).@"struct".field_names) |name| {
                if (!std.meta.eql(@field(reference, name), @field(live.stage, name))) std.debug.print("different audience field: {s}\n", .{name});
            }
            return error.AudienceReferenceDivergence;
        }
        if (!reference.active) break;
    }
    try std.testing.expect(ticks < 20000);
    try std.testing.expect(!live.instance.execution.active);
    try std.testing.expectEqual(fixture.value.expected.story_byte_0, story.scenario[0]);
    try std.testing.expectEqual(fixture.value.expected.audience_complete, live.stage.audience_complete);
    try std.testing.expectEqual(fixture.value.expected.following_teo, live.stage.following_teo);
    _ = try runtime.start(content.value, &story, "vaa_room2_init_24");
}

test "VAA choice zero matches every existing reference update through the same core" {
    try checkAudience("game/tests/fixtures/events/vaa_audience_choice.json");
}

test "VAA choice one matches every existing reference update through the same core" {
    try checkAudience("game/tests/fixtures/events/vaa_audience_choice_1.json");
}

const CoreSnapshot = struct { instance: runtime.Instance, story: runtime.StoryState };

test "battle dice and party selection requests remain isolated across a core restart" {
    for ([_]runtime.Command{ .{ .kind = .battle, .battle = "trial" }, .{ .kind = .fixed_dice }, .{ .kind = .party_select } }) |request| {
        const commands: []const runtime.Command = &.{
            .{ .kind = .continue_tick },
            .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 1 } },
            request,
            .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 2 } },
            .{ .kind = .end_stream },
        };
        const content: runtime.Content = .{
            .schema = if (request.kind == .party_select) runtime.party_select_schema else runtime.campaign_schema,
            .id = "battle_test",
            .content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
            .story_values = &.{.{ .id = "scenario_0001", .storage = .scenario, .byte_index = 1, .initial = 0 }},
            .programs = &.{.{ .id = "battle_test", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = commands }},
        };
        if (request.kind == .party_select) {
            var legacy = content;
            legacy.schema = runtime.field_effect_schema;
            try std.testing.expectError(error.InvalidEventCommand, legacy.validate());
        }
        var story = try runtime.StoryState.init(&.{content});
        var instance = try runtime.start(content, &story, "battle_test");
        const prefix = (try runtime.step(content, &instance, &story, .{})).batch.?;
        try std.testing.expectEqual(@as(u16, 1), prefix.effect_count);
        try runtime.acknowledge(content, &instance, &story, prefix.id);
        try std.testing.expect((try runtime.step(content, &instance, &story, .{ .mode_ready = false })).batch == null);
        const battle = (try runtime.step(content, &instance, &story, .{})).batch.?;
        try std.testing.expectEqual(request.kind == .fixed_dice, instance.pendingFixedDice());
        try std.testing.expectEqual(request.kind == .party_select, instance.pendingPartySelect());
        if (request.kind == .battle) try std.testing.expectEqualStrings("trial", instance.pendingBattle().?);
        var restored = try roundTrip(CoreSnapshot, .{ .instance = instance, .story = story });
        defer restored.deinit();
        const saved = &restored.value;
        try std.testing.expectEqual(battle.id, (try runtime.step(content, &saved.instance, &saved.story, .{ .confirm = true })).batch.?.id);
        try std.testing.expectEqual(@as(u8, 1), saved.story.scenario[1]);
        var forged = saved.instance;
        forged.pending.?.batch.effects[0].kind = .end_stream;
        try std.testing.expectError(error.InvalidEventBatch, forged.validate(content));
        try runtime.acknowledge(content, &saved.instance, &saved.story, battle.id);
        const continuation = (try runtime.step(content, &saved.instance, &saved.story, .{})).batch.?;
        try runtime.acknowledge(content, &saved.instance, &saved.story, continuation.id);
        try std.testing.expectEqual(@as(u8, 3), saved.story.scenario[1]);
        try std.testing.expect(!saved.instance.execution.active);
    }
}

test "village world exit commits its story prefix before waiting and resumes once" {
    const parsed = try load(runtime.Content, "game/assets/events/vb6_room0_world_exit.json");
    defer parsed.deinit();
    const content = parsed.value;
    var story = try runtime.StoryState.init(&.{content});
    story.scenario[39] = 0x80;
    var instance = try runtime.start(content, &story, "vb6_room0_world_exit");
    const prefix = (try runtime.step(content, &instance, &story, .{})).batch.?;
    try std.testing.expectEqual(.story_or, prefix.effects[0].kind);
    try std.testing.expectEqual(@as(u8, 0x80), story.scenario[39]);
    var before_ack = try roundTrip(CoreSnapshot, .{ .instance = instance, .story = story });
    defer before_ack.deinit();
    try std.testing.expectError(error.EventBatchIdentityMismatch, runtime.acknowledge(content, &before_ack.value.instance, &before_ack.value.story, prefix.id + 1));
    try runtime.acknowledge(content, &before_ack.value.instance, &before_ack.value.story, prefix.id);
    try std.testing.expectEqual(@as(u8, 0x90), before_ack.value.story.scenario[39]);
    try std.testing.expectError(error.NoPendingEventBatch, runtime.acknowledge(content, &before_ack.value.instance, &before_ack.value.story, prefix.id));
    try std.testing.expectEqual(.waiting, (try runtime.step(content, &before_ack.value.instance, &before_ack.value.story, .{})).status);
    var waiting = try roundTrip(CoreSnapshot, before_ack.value);
    defer waiting.deinit();
    try std.testing.expectEqual(.waiting, (try runtime.step(content, &waiting.value.instance, &waiting.value.story, .{})).status);
    const exit = (try runtime.step(content, &waiting.value.instance, &waiting.value.story, .{ .completions = &.{"dialogue_flags"} })).batch.?;
    try std.testing.expectEqual(.world_transition, exit.effects[0].kind);
    try std.testing.expectEqualStrings("region_b", exit.effects[0].destination.?);
    try std.testing.expectEqual(@as(?i32, 86), exit.effects[0].x);
    try std.testing.expectEqual(@as(?i32, 85), exit.effects[0].y);
    var forged = waiting.value.instance;
    forged.pending.?.batch.effects[0].x = 87;
    try std.testing.expectError(error.InvalidEventBatch, forged.validate(content));
    try std.testing.expectError(error.EventBatchIdentityMismatch, runtime.acknowledge(content, &waiting.value.instance, &waiting.value.story, prefix.id));
    try runtime.acknowledge(content, &waiting.value.instance, &waiting.value.story, exit.id);
    try std.testing.expectEqual(.completed, (try runtime.step(content, &waiting.value.instance, &waiting.value.story, .{})).status);
    try std.testing.expectEqual(@as(u8, 0x90), waiting.value.story.scenario[39]);
}

test "castle tier branches resume at the matching transition" {
    const commands: []const runtime.Command = &.{
        .{ .kind = .branch_castle_tier, .targets = &.{ 1, 3, 5 } },
        .{ .kind = .room_transition, .destination = "lower", .x = 8, .y = 8 },
        .{ .kind = .end_stream },
        .{ .kind = .room_transition, .destination = "middle", .x = 8, .y = 8 },
        .{ .kind = .end_stream },
        .{ .kind = .room_transition, .destination = "upper", .x = 8, .y = 8 },
    };
    const content: runtime.Content = .{
        .schema = runtime.branch_history_schema,
        .id = "castle_entry",
        .content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .programs = &.{.{ .id = "castle_entry", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = commands }},
    };
    for ([_][]const u8{ "lower", "lower", "lower", "middle", "upper" }, 0..) |room, tier| {
        var story = try runtime.StoryState.init(&.{content});
        story.castle_tier = @intCast(tier);
        var instance = try runtime.start(content, &story, "castle_entry");
        _ = try runtime.step(content, &instance, &story, .{});
        const result = try runtime.step(content, &instance, &story, .{ .completions = &.{"dialogue_flags"} });
        const batch = result.batch orelse return error.MissingCastleTransition;
        try std.testing.expectEqual(1, batch.effect_count);
        try std.testing.expectEqualStrings(room, batch.effects[0].destination.?);
        try runtime.acknowledge(content, &instance, &story, batch.id);
        try instance.validate(content);
    }
}

test "inline room transition waits, commits once and exits without a second terminal" {
    const commands = [_]runtime.Command{
        .{ .kind = .continue_tick },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0015", .mask = 0x40 } },
        .{ .kind = .room_transition, .destination = "vb6_kobold_village", .x = 216, .y = 200 },
    };
    const programs = [_]runtime.Program{.{ .id = "transition_test", .entry = .ordinary, .entity = 7, .trigger = .none, .commands = &commands }};
    const values = [_]runtime.StoryValue{.{ .id = "scenario_0015", .storage = .scenario, .byte_index = 15, .initial = 0x28 }};
    const content: runtime.Content = .{ .schema = runtime.schema, .id = "transition_test", .content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000", .story_values = &values, .programs = &programs };
    var story = try runtime.StoryState.init(&.{content});
    var instance = try runtime.start(content, &story, "transition_test");
    const prefix = (try runtime.step(content, &instance, &story, .{})).batch.?;
    try std.testing.expectEqual(@as(u16, 1), prefix.effect_count);
    try std.testing.expectEqual(.story_or, prefix.effects[0].kind);
    try std.testing.expectEqual(@as(u8, 0x28), story.scenario[15]);
    try runtime.acknowledge(content, &instance, &story, prefix.id);
    try std.testing.expectEqual(@as(u8, 0x68), story.scenario[15]);
    try std.testing.expectEqual(@as(u16, 2), instance.execution.pc);
    try std.testing.expectEqual(.waiting, (try runtime.step(content, &instance, &story, .{})).status);
    var waiting = try roundTrip(CoreSnapshot, .{ .instance = instance, .story = story });
    defer waiting.deinit();
    const transition = (try runtime.step(content, &waiting.value.instance, &waiting.value.story, .{ .completions = &.{"dialogue_flags"} })).batch.?;
    try std.testing.expectEqual(@as(u16, 1), transition.effect_count);
    try std.testing.expectEqual(.room_transition, transition.effects[0].kind);
    try std.testing.expectEqualStrings("vb6_kobold_village", transition.effects[0].destination.?);
    try std.testing.expectEqual(@as(u16, 2), transition.effects[0].origin);
    try std.testing.expect(waiting.value.instance.execution.active);
    var pending = try roundTrip(CoreSnapshot, .{ .instance = waiting.value.instance, .story = waiting.value.story });
    defer pending.deinit();
    try std.testing.expectEqual(transition.id, (try runtime.step(content, &pending.value.instance, &pending.value.story, .{})).batch.?.id);
    var tampered = pending.value.instance;
    tampered.pending.?.batch.effects[0].origin = 0;
    try std.testing.expectError(error.InvalidEventBatch, tampered.validate(content));
    tampered = pending.value.instance;
    tampered.pending.?.batch.effects[0].destination = "vb6_village";
    try std.testing.expectError(error.InvalidEventBatch, tampered.validate(content));
    tampered = pending.value.instance;
    tampered.pending.?.batch.effects[0].x = 208;
    try std.testing.expectError(error.InvalidEventBatch, tampered.validate(content));
    tampered = pending.value.instance;
    tampered.pending.?.batch.effects[0].y = 192;
    try std.testing.expectError(error.InvalidEventBatch, tampered.validate(content));
    tampered = pending.value.instance;
    tampered.pending.?.story_write_count = 1;
    tampered.pending.?.story_writes[0] = .{ .flag = .{ .id = "scenario_0015", .mask = 1 } };
    try std.testing.expectError(error.InvalidEventBatch, tampered.validate(content));
    try std.testing.expectError(error.InvalidEventBatch, runtime.acknowledge(content, &tampered, &pending.value.story, transition.id));
    try std.testing.expectEqual(@as(u8, 0x68), pending.value.story.scenario[15]);
    try std.testing.expectError(error.EventBatchIdentityMismatch, runtime.acknowledge(content, &pending.value.instance, &pending.value.story, transition.id + 1));
    try runtime.acknowledge(content, &pending.value.instance, &pending.value.story, transition.id);
    try std.testing.expectEqual(.completed, (try runtime.step(content, &pending.value.instance, &pending.value.story, .{})).status);
    try std.testing.expectError(error.NoPendingEventBatch, runtime.acknowledge(content, &pending.value.instance, &pending.value.story, transition.id));
    try std.testing.expectEqual(@as(u8, 0x68), pending.value.story.scenario[15]);

    const legacy = try std.json.Stringify.valueAlloc(allocator, runtime.Command{ .kind = .end_stream }, .{});
    defer allocator.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "destination") == null);
    const compact = try std.json.Stringify.valueAlloc(allocator, runtime.Command{ .kind = .end_stream }, .{ .emit_null_optional_fields = false });
    defer allocator.free(compact);
    try std.testing.expect(std.mem.indexOf(u8, compact, "actor") == null);

    var together_story = try runtime.StoryState.init(&.{content});
    var together = try runtime.start(content, &together_story, "transition_test");
    const combined = (try runtime.step(content, &together, &together_story, .{ .completions = &.{"dialogue_flags"} })).batch.?;
    try std.testing.expectEqual(@as(u16, 2), combined.effect_count);
    try together.validate(content);
    tampered = together;
    tampered.pending.?.batch.effects[0].flag.?.mask = 1;
    tampered.pending.?.story_writes[0].flag.mask = 1;
    try std.testing.expectError(error.InvalidEventBatch, tampered.validate(content));
    tampered = together;
    tampered.pending.?.next.active = true;
    tampered.pending.?.next.pc = 2;
    try std.testing.expectError(error.InvalidEventBatch, tampered.validate(content));
    try runtime.acknowledge(content, &together, &together_story, combined.id);
    try std.testing.expectEqual(@as(u8, 0x68), together_story.scenario[15]);

    var invalid = commands;
    invalid[2].x = 217;
    var malformed_programs = programs;
    malformed_programs[0].commands = &invalid;
    var malformed_content = content;
    malformed_content.programs = &malformed_programs;
    try std.testing.expectError(error.InvalidEventCommand, malformed_content.validate());
    invalid[2].x = 216;
    invalid[2].destination = null;
    try std.testing.expectError(error.InvalidEventCommand, malformed_content.validate());
    const nonterminal = [_]runtime.Command{ commands[2], .{ .kind = .end_stream } };
    malformed_programs[0].commands = &nonterminal;
    try std.testing.expectError(error.InvalidEventEnd, malformed_content.validate());
}

test "source-derived E7 candidate reaches a single inline transition under supplied completions" {
    const content = try load(runtime.Content, "game/assets/events/vb6_room6_e7.json");
    defer content.deinit();
    var story = try runtime.StoryState.init(&.{content.value});
    try std.testing.expectError(error.EventConditionFalse, runtime.start(content.value, &story, "vb6_r06_entity07_followon"));
    story.scenario[15] = 0x28;
    var instance = try runtime.start(content.value, &story, "vb6_r06_entity07_followon");
    var transitions: usize = 0;
    for (0..100) |_| {
        const result = try runtime.step(content.value, &instance, &story, .{
            .confirm = true,
            .completions = &.{ "dialogue_flags", "tracks", "box_0", "vb6_e7_text_0_6" },
        });
        if (result.batch) |batch| {
            for (batch.slice()) |effect| if (effect.kind == .room_transition) {
                transitions += 1;
                try std.testing.expectEqual(@as(u8, 0x68), story.scenario[15]);
                try std.testing.expectEqualStrings("vb6_kobold_village", effect.destination.?);
                try std.testing.expectEqual(@as(?i32, 216), effect.x);
                try std.testing.expectEqual(@as(?i32, 200), effect.y);
            };
            try runtime.acknowledge(content.value, &instance, &story, batch.id);
        }
        if (!instance.execution.active) break;
    }
    try std.testing.expect(!instance.execution.active);
    try std.testing.expectEqual(@as(usize, 1), transitions);
}

test "source-derived initializer8 is gated and pumps its setup once" {
    const content = try load(runtime.Content, "game/assets/events/vb6_room6_e7.json");
    defer content.deinit();
    var story = try runtime.StoryState.init(&.{content.value});
    try std.testing.expectError(error.EventConditionFalse, runtime.start(content.value, &story, "vb6_r06_init_08"));
    story.scenario[15] = 0x68;
    story.scenario[16] = 1;
    try std.testing.expectError(error.EventConditionFalse, runtime.start(content.value, &story, "vb6_r06_init_08"));
    story.scenario[16] = 0;
    var instance = try runtime.start(content.value, &story, "vb6_r06_init_08");
    const batch = (try runtime.step(content.value, &instance, &story, .{})).batch.?;
    try std.testing.expectEqual(@as(u16, 4), batch.effect_count);
    try std.testing.expectEqual(.actor_x, batch.effects[0].kind);
    try std.testing.expectEqual(@as(?u8, 24), batch.effects[0].value);
    try std.testing.expectEqual(.actor_y, batch.effects[1].kind);
    try std.testing.expectEqual(@as(?u8, 25), batch.effects[1].value);
    try std.testing.expectEqual(.actor_transition, batch.effects[2].kind);
    try std.testing.expectEqual(.actor_transition, batch.effects[3].kind);
    try runtime.acknowledge(content.value, &instance, &story, batch.id);
    try std.testing.expect(instance.execution.active);
    try std.testing.expectEqual(@as(u16, 6), instance.execution.pc);
}

test "village initializer gates and releases the source-selected actor once" {
    const content = try load(runtime.Content, "game/assets/events/vb6_room0_initializer.json");
    defer content.deinit();
    var story = try runtime.StoryState.init(&.{content.value});
    story.scenario[15] = 0;
    try std.testing.expectError(error.EventConditionFalse, runtime.start(content.value, &story, "vb6_r00_init_06"));
    story.scenario[15] = 0x18;
    try std.testing.expectError(error.EventConditionFalse, runtime.start(content.value, &story, "vb6_r00_init_06"));
    story.scenario[15] = 0x08;
    var instance = try runtime.start(content.value, &story, "vb6_r00_init_06");
    const batch = (try runtime.step(content.value, &instance, &story, .{})).batch.?;
    try std.testing.expectEqual(@as(u16, 1), batch.effect_count);
    try std.testing.expectEqual(.release_actor, batch.effects[0].kind);
    try std.testing.expectEqualStrings("vb6_room0_entity_08", batch.effects[0].actor.?);
    try std.testing.expectEqual(batch.id, (try runtime.step(content.value, &instance, &story, .{})).batch.?.id);
    try runtime.acknowledge(content.value, &instance, &story, batch.id);
    try std.testing.expectEqual(@as(u16, 3), instance.execution.pc);
    try std.testing.expectError(error.NoPendingEventBatch, runtime.acknowledge(content.value, &instance, &story, batch.id));
}

test "initialization keeps source order, one pump, story gate and resumable yield batch" {
    const content = try load(runtime.Content, "game/assets/events/vaa_audience_choice.json");
    defer content.deinit();
    const script = try audience.load(allocator, audience.json);
    defer script.deinit();
    const stage = try audience.State.start(script.value, .{
        .hero = .{ .x = 64 * 8, .y = 73 * 8 },
        .camera = .{ .x = 0, .y = 0 },
        .width = 640,
        .height = 480,
        .player_name = "Tir",
    });
    var story = try runtime.StoryState.init(&.{content.value});
    try std.testing.expectError(error.EventConditionFalse, runtime.start(content.value, &story, "vaa_room2_init_24"));
    var initialized_stage = stage;
    const initial = try adapter.initializeRoom(content.value, &initialized_stage, &story);
    try std.testing.expectEqual(@as(u8, 1), initial.count);
    try std.testing.expectEqual(@as(?u16, 129), initial.cues[0]);

    story.scenario[0] = 64;
    var instance = try runtime.start(content.value, &story, "vaa_room2_init_24");
    const yielded = try runtime.step(content.value, &instance, &story, .{});
    try std.testing.expectEqual(@as(u16, 7), yielded.batch.?.effect_count);
    try std.testing.expect(yielded.batch.?.effects[0].actor.?.len != 0);
    try std.testing.expect(!instance.pending.?.next.reloop);
    var restored = try roundTrip(CoreSnapshot, .{ .instance = instance, .story = story });
    defer restored.deinit();
    const repeated = try runtime.step(content.value, &restored.value.instance, &restored.value.story, .{});
    try std.testing.expectEqual(yielded.batch.?.id, repeated.batch.?.id);
    try std.testing.expectEqual(yielded.batch.?.effect_count, repeated.batch.?.effect_count);
    try runtime.acknowledge(content.value, &restored.value.instance, &restored.value.story, yielded.batch.?.id);
    try std.testing.expect(restored.value.instance.pending == null);
    try std.testing.expect(restored.value.instance.execution.active);
    const prop_commands = [_]runtime.Command{ .{ .kind = .continue_tick }, .{ .kind = .show_prop, .prop = 0 }, .{ .kind = .yield_tick }, .{ .kind = .end_stream } };
    var prop_content = reviewContent(&.{.{ .id = "ladder_init", .entry = .initialization, .entity = 5, .trigger = .none, .commands = &prop_commands }});
    prop_content.schema = runtime.prop_schema;
    var prop_story = try runtime.StoryState.init(&.{prop_content});
    var prop_instance = try runtime.start(prop_content, &prop_story, "ladder_init");
    const prop_batch = (try runtime.step(prop_content, &prop_instance, &prop_story, .{})).batch.?;
    try std.testing.expectEqual(@as(u16, 1), prop_batch.effect_count);
    try std.testing.expectEqual(.show_prop, prop_batch.effects[0].kind);
    try runtime.acknowledge(prop_content, &prop_instance, &prop_story, prop_batch.id);
    try std.testing.expect(prop_instance.execution.active);
    try std.testing.expectEqual(@as(u16, 3), prop_instance.execution.pc);
}

const Vb6Fixture = struct {
    schema: []const u8,
    program: []const u8,
    initial_story: struct { byte_15: u8, byte_19: u8 },
    initial_active_party_count: u8,
    initial_party: [6]u8,
    expected: struct {
        story_byte_15: u8,
        party: [6]u8,
        descriptor_0_flags: u8,
        descriptor_1_flags: u8,
        completed: bool,
        placed_character_visibility_count_before: u8,
        placed_character_visibility_count_after_byte_19_mask_8: u8,
    },
    independent_witnesses: []const []const u8,
};

const Host = struct {
    instance: runtime.Instance,
    applied: ?u64 = null,
    party: [6]u8,
    active_party_count: u8 = 6,
    descriptor_flags: [2]u8 = .{ 0xFF, 0 },
    story_effect_applications: u8 = 0,
    effect_count: u8 = 0,
    effects: [64]u16 = @splat(0),

    fn apply(self: *Host, batch: runtime.EventBatch) !void {
        if (self.applied == batch.id) return error.DuplicateHostBatch;
        for (batch.slice()) |effect| {
            if (self.effect_count == self.effects.len) return error.TooManyHostEffects;
            self.effects[self.effect_count] = effect.origin;
            self.effect_count += 1;
            switch (effect.kind) {
                .request_area_party_prefix => {
                    if (self.active_party_count > self.party.len) return error.InvalidFixturePartyCount;
                    var saved = self.party;
                    self.party = @splat(0xFF);
                    var output: usize = 0;
                    for (effect.requested_prefix.?) |id| {
                        self.party[output] = id;
                        output += 1;
                        for (&saved) |*old| if (old.* == id) {
                            old.* = 0xFF;
                        };
                    }
                    for (saved) |id| if (id != 0xFF and output < self.active_party_count) {
                        self.party[output] = id;
                        output += 1;
                    };
                },
                .descriptor_flags => {
                    const index = effect.selector.? - 0x40;
                    if (index > 1) return error.UnsupportedFixtureDescriptor;
                    if (effect.parameter.? == 2)
                        self.descriptor_flags[index] &= effect.mask.?
                    else if (effect.parameter.? == 3)
                        self.descriptor_flags[index] |= effect.mask.?
                    else
                        return error.UnsupportedFixtureDescriptor;
                },
                .story_or => self.story_effect_applications += 1,
                else => {},
            }
        }
        self.applied = batch.id;
    }

    fn acknowledge(self: *Host, content: runtime.Content, story: *runtime.StoryState, batch_id: u64) !void {
        if (self.applied != batch_id) return error.MissingAppliedBatchReceipt;
        try runtime.acknowledge(content, &self.instance, story, batch_id);
    }

    fn pump(self: *Host, content: runtime.Content, story: *runtime.StoryState, input: runtime.Input) !runtime.StepResult {
        const result = try runtime.step(content, &self.instance, story, input);
        if (result.batch) |batch| {
            try self.apply(batch);
            try self.acknowledge(content, story, batch.id);
        }
        return result;
    }

    fn snapshot(self: Host, story: runtime.StoryState) HostSnapshot {
        return .{
            .instance = self.instance,
            .story = story,
            .applied = self.applied,
            .party = self.party,
            .active_party_count = self.active_party_count,
            .descriptor_flags = self.descriptor_flags,
            .story_effect_applications = self.story_effect_applications,
            .effect_count = self.effect_count,
            .effects = self.effects,
        };
    }
};

const HostSnapshot = struct {
    instance: runtime.Instance,
    story: runtime.StoryState,
    applied: ?u64,
    party: [6]u8,
    active_party_count: u8,
    descriptor_flags: [2]u8,
    story_effect_applications: u8,
    effect_count: u8,
    effects: [64]u16,
};

fn hostFromSnapshot(snapshot: HostSnapshot) Host {
    return .{
        .instance = snapshot.instance,
        .applied = snapshot.applied,
        .party = snapshot.party,
        .active_party_count = snapshot.active_party_count,
        .descriptor_flags = snapshot.descriptor_flags,
        .story_effect_applications = snapshot.story_effect_applications,
        .effect_count = snapshot.effect_count,
        .effects = snapshot.effects,
    };
}

fn completions(content: runtime.Content, include_dialogue_flags: bool) [128][]const u8 {
    var result: [128][]const u8 = undefined;
    var count: usize = 0;
    for ([_][]const u8{ "alignment", "delay", "pan", "tracks", "text_queue", "box_0", "box_1" }) |id| {
        result[count] = id;
        count += 1;
    }
    if (include_dialogue_flags) {
        result[count] = "dialogue_flags";
        count += 1;
    }
    for (content.actors) |actor| {
        result[count] = actor.id;
        count += 1;
    }
    for (content.texts) |text| {
        result[count] = text.id;
        count += 1;
    }
    return result;
}

fn visiblePlaced(content: runtime.Content, story: *const runtime.StoryState) u8 {
    var count: u8 = 0;
    for (content.actors) |actor| if (actor.x < 1000 and runtime.actorVisible(story, actor)) {
        count += 1;
    };
    return count;
}

test "VB6 arrival and conditional population use the same core and preserve area party order" {
    const fixture = try load(Vb6Fixture, "game/tests/fixtures/events/vb6_room6_arrival.json");
    defer fixture.deinit();
    const content = try load(runtime.Content, "game/assets/events/vb6_room6_arrival.json");
    defer content.deinit();
    try std.testing.expectEqual(@as(usize, 26), content.value.actors.len);
    const placed = [_]struct { id: []const u8, x: i32, y: i32 }{
        .{ .id = "vb6_r06_e33_char_154", .x = 216, .y = 144 },
        .{ .id = "vb6_r06_e34_char_154", .x = 272, .y = 232 },
        .{ .id = "vb6_r06_e35_char_153", .x = 64, .y = 192 },
    };
    var staged_count: usize = 0;
    for (content.value.actors) |actor| {
        var is_placed = false;
        for (placed) |expected| if (std.mem.eql(u8, actor.id, expected.id)) {
            try std.testing.expectEqual(expected.x, actor.x);
            try std.testing.expectEqual(expected.y, actor.y);
            is_placed = true;
        };
        if (!is_placed) {
            try std.testing.expectEqual(@as(i32, 2032), actor.x);
            try std.testing.expectEqual(@as(i32, 2032), actor.y);
            staged_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 23), staged_count);
    var story = try runtime.StoryState.init(&.{content.value});
    for ([_]u8{ 0, 0x20, 0x28 }) |value| {
        story.scenario[15] = value;
        try std.testing.expectError(error.EventConditionFalse, runtime.start(content.value, &story, fixture.value.program));
    }
    story.scenario[15] = fixture.value.initial_story.byte_15;
    story.scenario[19] = fixture.value.initial_story.byte_19;
    try std.testing.expectEqual(fixture.value.expected.placed_character_visibility_count_before, visiblePlaced(content.value, &story));
    var host: Host = .{
        .instance = try runtime.start(content.value, &story, fixture.value.program),
        .party = fixture.value.initial_party,
        .active_party_count = fixture.value.initial_active_party_count,
    };
    const ids = completions(content.value, false);
    var steps: usize = 0;
    while (steps < 128) : (steps += 1) {
        const result = try host.pump(content.value, &story, .{
            .completions = ids[0 .. 7 + content.value.actors.len + content.value.texts.len],
            .confirm = true,
        });
        if (host.instance.execution.pc == 9 and host.instance.execution.wait != null) {
            try std.testing.expectEqual(runtime.Status.waiting, result.status);
            try std.testing.expectEqual(@as(u8, 8), story.scenario[15]);
            break;
        }
    }
    try std.testing.expectEqual(@as(u16, 9), host.instance.execution.pc);
    const ready = completions(content.value, true);
    while (steps < 128) : (steps += 1) {
        const result = try host.pump(content.value, &story, .{
            .completions = ready[0 .. 8 + content.value.actors.len + content.value.texts.len],
            .confirm = true,
        });
        if (result.status == .completed) break;
    }
    try std.testing.expect(steps < 128);
    try std.testing.expectEqual(fixture.value.expected.story_byte_15, story.scenario[15]);
    try std.testing.expectEqual(fixture.value.expected.party, host.party);
    try std.testing.expectEqual(fixture.value.expected.descriptor_0_flags, host.descriptor_flags[0]);
    try std.testing.expectEqual(fixture.value.expected.descriptor_1_flags, host.descriptor_flags[1]);
    try std.testing.expectEqual(@as(u8, 1), host.story_effect_applications);
    try std.testing.expectError(error.EventConditionFalse, runtime.start(content.value, &story, fixture.value.program));
    story.scenario[19] = 8;
    try std.testing.expectEqual(fixture.value.expected.placed_character_visibility_count_after_byte_19_mask_8, visiblePlaced(content.value, &story));
}

const TransactionFixture = struct {
    schema: []const u8,
    program: []const u8,
    boundary: []const u8,
    before_apply: struct { pending: bool, applied_receipt: bool, story_byte_15: u8 },
    after_apply_before_ack: struct { pending: bool, applied_receipt: bool, story_byte_15: u8 },
    after_ack: struct { pending: bool, applied_receipt: bool, story_byte_15: u8 },
    required_atomic_snapshot: []const []const u8,
    expected_story_effect_applications: u8,
};

test "VB6 snapshots before apply after apply before ack and after ack are exactly once" {
    const fixture = try load(TransactionFixture, "game/tests/fixtures/events/vb6_room6_arrival_1.json");
    defer fixture.deinit();
    try std.testing.expectEqual(@as(usize, 4), fixture.value.required_atomic_snapshot.len);
    const content = try load(runtime.Content, "game/assets/events/vb6_room6_arrival.json");
    defer content.deinit();
    var story = try runtime.StoryState.init(&.{content.value});
    story.scenario[15] = 8;
    var host: Host = .{
        .instance = try runtime.start(content.value, &story, fixture.value.program),
        .party = .{ 6, 35, 38, 32, 70, 0xFF },
    };
    const ready = completions(content.value, true);
    const input: runtime.Input = .{
        .completions = ready[0 .. 8 + content.value.actors.len + content.value.texts.len],
        .confirm = true,
    };
    while (host.instance.execution.pc != 26) _ = try host.pump(content.value, &story, input);
    const pending = try runtime.step(content.value, &host.instance, &story, input);
    const batch = pending.batch.?;
    try std.testing.expectEqual(@as(u16, 26), batch.effects[0].origin);
    try std.testing.expect(host.applied != batch.id);
    try std.testing.expectEqual(fixture.value.before_apply.story_byte_15, story.scenario[15]);

    var before = try roundTrip(HostSnapshot, host.snapshot(story));
    defer before.deinit();
    var before_host = hostFromSnapshot(before.value);
    const repeated_before = try runtime.step(content.value, &before_host.instance, &before.value.story, input);
    try std.testing.expectEqual(batch.id, repeated_before.batch.?.id);
    try std.testing.expectEqual(batch.effects[0].origin, repeated_before.batch.?.effects[0].origin);
    try std.testing.expectEqual(fixture.value.before_apply.story_byte_15, before.value.story.scenario[15]);

    try before_host.apply(batch);
    try std.testing.expectEqual(batch.id, before_host.applied.?);
    try std.testing.expectEqual(fixture.value.after_apply_before_ack.story_byte_15, story.scenario[15]);
    var applied = try roundTrip(HostSnapshot, before_host.snapshot(story));
    defer applied.deinit();
    var applied_host = hostFromSnapshot(applied.value);
    const repeated_applied = try runtime.step(content.value, &applied_host.instance, &applied.value.story, input);
    try std.testing.expectEqual(batch.id, repeated_applied.batch.?.id);
    try std.testing.expectEqual(fixture.value.after_apply_before_ack.story_byte_15, applied.value.story.scenario[15]);

    try applied_host.acknowledge(content.value, &applied.value.story, batch.id);
    try std.testing.expect(applied_host.instance.pending == null);
    try std.testing.expectEqual(fixture.value.after_ack.story_byte_15, applied.value.story.scenario[15]);
    var acknowledged = try roundTrip(HostSnapshot, applied_host.snapshot(applied.value.story));
    defer acknowledged.deinit();
    var finished_host = hostFromSnapshot(acknowledged.value);
    _ = try finished_host.pump(content.value, &acknowledged.value.story, input);
    try std.testing.expect(!finished_host.instance.execution.active);
    try std.testing.expectEqual(fixture.value.expected_story_effect_applications, finished_host.story_effect_applications);
}

test "choice local state and branch target survive content-identical snapshot" {
    const content = try load(runtime.Content, "game/assets/events/vaa_audience_choice.json");
    defer content.deinit();
    var story = try runtime.StoryState.init(&.{content.value});
    var instance = try runtime.start(content.value, &story, "vaa_room2_audience");
    const ready = completions(content.value, true);
    const input: runtime.Input = .{
        .completions = ready[0 .. 8 + content.value.actors.len + content.value.texts.len],
        .confirm = true,
    };
    while (instance.execution.wait == null or instance.execution.wait.?.kind != .choice) {
        const result = try runtime.step(content.value, &instance, &story, input);
        if (result.batch) |batch| try runtime.acknowledge(content.value, &instance, &story, batch.id);
    }
    var saved = try roundTrip(CoreSnapshot, .{ .instance = instance, .story = story });
    defer saved.deinit();
    const result = try runtime.step(content.value, &saved.value.instance, &saved.value.story, .{
        .choice = 1,
        .choice_confirmed = true,
    });
    try std.testing.expectEqual(runtime.Status.running, result.status);
    try std.testing.expectEqual(@as(u1, 1), saved.value.instance.execution.choice);
    var selected = try roundTrip(CoreSnapshot, saved.value);
    defer selected.deinit();
    const program = content.value.program("vaa_room2_audience").?;
    while (program.commands[selected.value.instance.execution.pc].kind != .branch_choice) {
        const next = try runtime.step(content.value, &selected.value.instance, &selected.value.story, input);
        if (next.batch) |batch| try runtime.acknowledge(content.value, &selected.value.instance, &selected.value.story, batch.id);
    }
    const target = program.commands[selected.value.instance.execution.pc].target.?;
    _ = try runtime.step(content.value, &selected.value.instance, &selected.value.story, input);
    try std.testing.expectEqual(target, selected.value.instance.execution.pc);
}

test "identity, missing references and malformed cycles fail without mutation" {
    const content = try load(runtime.Content, "game/assets/events/vaa_audience_choice.json");
    defer content.deinit();
    var story = try runtime.StoryState.init(&.{content.value});
    var instance = try runtime.start(content.value, &story, "vaa_room2_audience");
    const before = instance;
    var changed = content.value;
    changed.content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.EventContentIdentityMismatch, runtime.step(changed, &instance, &story, .{}));
    try std.testing.expect(std.meta.eql(before, instance));

    var missing = content.value;
    var missing_commands = try allocator.dupe(runtime.Command, missing.program("vaa_room2_audience").?.commands);
    defer allocator.free(missing_commands);
    missing_commands[0].text = "missing_text";
    var missing_programs = try allocator.dupe(runtime.Program, missing.programs);
    defer allocator.free(missing_programs);
    missing_programs[0].commands = missing_commands;
    missing.programs = missing_programs;
    try std.testing.expectError(error.UnknownEventText, runtime.validate(missing));
    try std.testing.expect(std.meta.eql(before, instance));

    var cyclic = content.value;
    const cycle_commands = [_]runtime.Command{
        .{ .kind = .continue_tick }, .{ .kind = .jump, .target = 0 }, .{ .kind = .end_stream },
    };
    const cycle_program = [_]runtime.Program{.{
        .id = "cycle",
        .entry = .ordinary,
        .entity = 0,
        .trigger = .none,
        .commands = &cycle_commands,
    }};
    cyclic.programs = &cycle_program;
    var cycle = try runtime.start(cyclic, &story, "cycle");
    const cycle_before = cycle;
    try std.testing.expectError(error.EventCycleBound, runtime.step(cyclic, &cycle, &story, .{}));
    try std.testing.expect(std.meta.eql(cycle_before, cycle));
}

fn reviewContent(programs: []const runtime.Program) runtime.Content {
    return .{
        .schema = runtime.schema,
        .id = "review",
        .content_sha256 = "1111111111111111111111111111111111111111111111111111111111111111",
        .programs = programs,
    };
}

test "wheel music requires its namespace and emits an isolated receipt" {
    const commands = [_]runtime.Command{ .{ .kind = .field_music, .music = .wheel }, .{ .kind = .end_stream } };
    const programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &commands }};
    var content = reviewContent(&programs);
    content.schema = runtime.party_experience_schema;
    try std.testing.expectError(error.InvalidEventCommand, content.validate());
    content.schema = runtime.wheel_music_schema;
    try content.validate();
    var story = try runtime.StoryState.init(&.{content});
    var instance = try runtime.start(content, &story, "p");
    const batch = (try runtime.step(content, &instance, &story, .{})).batch.?;
    try std.testing.expectEqual(@as(u8, 1), batch.effect_count);
    try std.testing.expectEqual(.wheel, batch.effects[0].music.?);
    try runtime.acknowledge(content, &instance, &story, batch.id);
}

test "scene experience requires its namespace and emits an isolated receipt" {
    const commands = [_]runtime.Command{ .{ .kind = .party_gain_experience }, .{ .kind = .party_lose_experience }, .{ .kind = .end_stream } };
    const programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &commands }};
    var content = reviewContent(&programs);
    content.schema = runtime.mansion_music_schema;
    try std.testing.expectError(error.InvalidEventCommand, content.validate());
    content.schema = runtime.party_experience_schema;
    try content.validate();
    var story = try runtime.StoryState.init(&.{content});
    var instance = try runtime.start(content, &story, "p");
    const first = (try runtime.step(content, &instance, &story, .{})).batch.?;
    try std.testing.expectEqual(@as(u8, 1), first.effect_count);
    try std.testing.expectEqual(.party_gain_experience, first.effects[0].kind);
    try runtime.acknowledge(content, &instance, &story, first.id);
    const second = (try runtime.step(content, &instance, &story, .{})).batch.?;
    try std.testing.expectEqual(.party_lose_experience, second.effects[0].kind);
}

test "blocked open emits staged close once and rechecks after acknowledgement" {
    const commands = [_]runtime.Command{
        .{ .kind = .continue_tick },
        .{ .kind = .close_box, .box = 0 },
        .{ .kind = .open_box, .box = 0, .requires = .{ .kind = .box_closed, .id = "box_0" } },
        .{ .kind = .end_stream },
    };
    const programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &commands }};
    const content = reviewContent(&programs);
    var story = try runtime.StoryState.init(&.{content});
    var instance = try runtime.start(content, &story, "p");
    const closed = try runtime.step(content, &instance, &story, .{});
    try std.testing.expectEqual(runtime.Status.running, closed.status);
    try std.testing.expectEqual(@as(u16, 1), closed.batch.?.effect_count);
    try std.testing.expect(closed.batch.?.effects[0].kind == .close_box);
    try std.testing.expectEqual(@as(u16, 1), closed.batch.?.effects[0].origin);
    try std.testing.expectEqual(@as(u16, 0), instance.execution.pc);
    try std.testing.expectEqual(@as(u16, 2), instance.pending.?.next.pc);
    const batch_id = closed.batch.?.id;

    const retry = try runtime.step(content, &instance, &story, .{});
    try std.testing.expectEqual(batch_id, retry.batch.?.id);
    try std.testing.expectEqual(@as(u16, 1), retry.batch.?.effect_count);
    try std.testing.expectError(error.EventBatchIdentityMismatch, runtime.acknowledge(content, &instance, &story, batch_id + 1));
    try std.testing.expectEqual(batch_id, instance.pending.?.batch.id);
    try runtime.acknowledge(content, &instance, &story, batch_id);
    try std.testing.expectEqual(@as(u16, 2), instance.execution.pc);
    try std.testing.expectError(error.NoPendingEventBatch, runtime.acknowledge(content, &instance, &story, batch_id));

    const still_closed = try runtime.step(content, &instance, &story, .{});
    try std.testing.expectEqual(runtime.Status.waiting, still_closed.status);
    try std.testing.expect(still_closed.batch == null);
    try std.testing.expectEqual(@as(u16, 2), instance.execution.pc);
    const opened = try runtime.step(content, &instance, &story, .{ .completions = &.{"box_0"} });
    try std.testing.expectEqual(@as(u16, 2), opened.batch.?.effect_count);
    try std.testing.expect(opened.batch.?.effects[0].kind == .open_box);
    try std.testing.expect(opened.batch.?.effects[1].kind == .end_stream);
    try runtime.acknowledge(content, &instance, &story, opened.batch.?.id);
    try std.testing.expect(!instance.execution.active);
}

test "canonical story identities and adjacent upper bytes validate before mutation" {
    const commands = [_]runtime.Command{
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0239", .mask = 32 } },
        .{ .kind = .end_stream },
    };
    const programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &commands }};
    var content = reviewContent(&programs);
    content.story_values = &.{
        .{ .id = "scenario_0238", .storage = .scenario, .byte_index = 238, .initial = 7 },
        .{ .id = "scenario_0239", .storage = .scenario, .byte_index = 239, .initial = 8 },
    };
    try runtime.validate(content);
    var story = try runtime.StoryState.init(&.{content});
    var instance = try runtime.start(content, &story, "p");
    const result = try runtime.step(content, &instance, &story, .{});
    try runtime.acknowledge(content, &instance, &story, result.batch.?.id);
    try std.testing.expectEqual(@as(u8, 7), story.scenario[238]);
    try std.testing.expectEqual(@as(u8, 40), story.scenario[239]);

    var mismatched = content;
    mismatched.story_values = &.{.{ .id = "scenario_0001", .storage = .scenario, .byte_index = 0, .initial = 8 }};
    try std.testing.expectError(error.InvalidStoryValue, runtime.validate(mismatched));
    try std.testing.expectError(error.InvalidStoryValue, runtime.StoryState.init(&.{mismatched}));
    try std.testing.expectEqual(@as(u8, 7), story.scenario[238]);
    try std.testing.expectEqual(@as(u8, 40), story.scenario[239]);

    var outside = content;
    outside.story_values = &.{.{ .id = "scenario_0240", .storage = .scenario, .byte_index = 0, .initial = 8 }};
    try std.testing.expectError(error.InvalidStoryValue, runtime.validate(outside));
    try std.testing.expectError(error.InvalidStoryValue, runtime.StoryState.init(&.{outside}));
    try std.testing.expect(!story.matches(&.{.{ .kind = .story_mask_set, .flag = .{ .id = "scenario_0240", .mask = 1 } }}));
    try std.testing.expectEqual(@as(u8, 7), story.scenario[238]);
    try std.testing.expectEqual(@as(u8, 40), story.scenario[239]);
}

test "unterminated programs and invalid cursors fail before mutation" {
    const unterminated_commands = [_]runtime.Command{.{ .kind = .label }};
    const unterminated_programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &unterminated_commands }};
    const unterminated = reviewContent(&unterminated_programs);
    try std.testing.expectError(error.InvalidEventProgram, runtime.validate(unterminated));
    var story: runtime.StoryState = .{};
    try std.testing.expectError(error.InvalidEventProgram, runtime.StoryState.init(&.{unterminated}));
    try std.testing.expectError(error.InvalidEventProgram, runtime.start(unterminated, &story, "p"));

    const commands = [_]runtime.Command{ .{ .kind = .label }, .{ .kind = .end_stream } };
    const programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &commands }};
    const content = reviewContent(&programs);
    var instance = try runtime.start(content, &story, "p");
    instance.execution.pc = commands.len;
    const before = instance;
    try std.testing.expectError(error.InvalidEventCursor, runtime.step(content, &instance, &story, .{}));
    try std.testing.expect(std.meta.eql(before, instance));
}

test "area party prefix uses logical active count for exact source cases" {
    const content = try load(runtime.Content, "game/assets/events/vb6_room6_arrival.json");
    defer content.deinit();
    var story = try runtime.StoryState.init(&.{content.value});
    story.scenario[15] = 8;
    for ([_]struct { count: u8, expected: [6]u8 }{
        .{ .count = 3, .expected = .{ 8, 2, 4, 0xFF, 0xFF, 0xFF } },
        .{ .count = 6, .expected = .{ 8, 2, 4, 13, 12, 11 } },
    }) |case| {
        var host: Host = .{
            .instance = try runtime.start(content.value, &story, "vb6_r06_first_arrival"),
            .party = .{ 13, 12, 11, 4, 2, 8 },
            .active_party_count = case.count,
        };
        var batch: runtime.EventBatch = .{ .id = 1, .effect_count = 1 };
        batch.effects[0] = .{ .kind = .request_area_party_prefix, .requested_prefix = &.{ 8, 2, 4 }, .scope = "area_transient" };
        try host.apply(batch);
        try std.testing.expectEqual(case.expected, host.party);
    }
}

test "scene actor lifetime starts absent and preserves creation and release across JSON" {
    const actors = @import("field_actors");
    const hash = "0000000000000000000000000000000000000000000000000000000000000000";
    const animation: audience.Animation = .{ .graphic = "scene_viktor", .clips = @splat(.{ .flags = 3, .ticks = &.{ 8, 8, 8, 8 }, .bounds = &@as([4]audience.Bounds, @splat(.{ .width = 24, .height = 48 })) }) };
    const packet: actors.Packet = .{ .schema = "suikoden-field-ordinary-actors/2", .scene = "kouan", .binding_sha256 = hash, .population_sha256 = hash, .event_sha256 = hash, .content_sha256 = hash, .actors = &.{.{ .id = "scene_viktor", .entity = 12, .slot = 0, .resource = "viktor", .graphic = "scene_viktor", .x = 96, .y = 424, .speed = 2, .variant = 0, .auto_animate = false, .conditions = &.{}, .scene_owned = true }} };
    var state = try actors.State.construct(packet, &.{animation}, .{});
    try std.testing.expectError(error.FieldActorNotConstructed, state.actor(packet, "scene_viktor"));
    try state.spawn(packet, &.{animation}, "scene_viktor");
    try std.testing.expectEqual(@as(i32, 96), (try state.actor(packet, "scene_viktor")).motion.x);
    try std.testing.expectEqual(@as(u8, 2), (try state.actor(packet, "scene_viktor")).motion.speed);
    try std.testing.expectError(error.InvalidFieldActorLifetime, state.spawn(packet, &.{animation}, "scene_viktor"));
    const active = try roundTrip(actors.State, state);
    defer active.deinit();
    var restored = active.value;
    try std.testing.expectError(error.InvalidFieldActorLifetime, restored.validate(packet, &.{animation}));
    try std.testing.expectError(error.UnsupportedSettledFieldActor, restored.settle(packet, &.{animation}));
    try restored.release(packet, "scene_viktor");
    const released = try roundTrip(actors.State, restored);
    defer released.deinit();
    restored = released.value;
    try restored.validate(packet, &.{animation});
    try std.testing.expectError(error.FieldActorReleased, restored.actor(packet, "scene_viktor"));
    const quiet = try restored.settle(packet, &.{animation});
    try std.testing.expectEqual(.absent, quiet.slots[0].?.phase);
    restored.clearSceneActors(packet);
    try restored.validate(packet, &.{animation});
    try std.testing.expectError(error.FieldActorNotConstructed, restored.actor(packet, "scene_viktor"));
    var commands = [_]runtime.Command{
        .{ .kind = .choice, .box = 0, .options = 2 },       .{ .kind = .branch_choice, .target = 3 },
        .{ .kind = .jump, .target = 4 },                    .{ .kind = .end_stream },
        .{ .kind = .spawn_actor, .actor = "scene_viktor" }, .{ .kind = .release_actor, .actor = "scene_viktor" },
        .{ .kind = .end_stream },
    };
    const control: runtime.Content = .{ .schema = runtime.fade_in_schema, .id = "scene_choice", .content_sha256 = hash, .actors = &.{.{ .id = "scene_viktor" }}, .programs = &.{.{ .id = "scene_choice", .entry = .ordinary, .entity = 5, .trigger = .none, .commands = &commands }} };
    try control.validate();
    commands[2].target = 6;
    try std.testing.expectError(error.InvalidEventCommand, control.validate());
}

test "wheel motion branches all seven results under the existing reloop policy" {
    const commands = [_]runtime.Command{
        .{ .kind = .wheel_spin },
        .{ .kind = .branch_wheel, .targets = &.{ 2, 4, 6, 8, 10, 12, 14 } },
        .{ .kind = .cue, .cue = 0 },
        .{ .kind = .end_stream },
        .{ .kind = .cue, .cue = 1 },
        .{ .kind = .end_stream },
        .{ .kind = .cue, .cue = 2 },
        .{ .kind = .end_stream },
        .{ .kind = .cue, .cue = 3 },
        .{ .kind = .end_stream },
        .{ .kind = .cue, .cue = 4 },
        .{ .kind = .end_stream },
        .{ .kind = .cue, .cue = 5 },
        .{ .kind = .end_stream },
        .{ .kind = .cue, .cue = 6 },
        .{ .kind = .end_stream },
    };
    const backward_graph = commands ++ [_]runtime.Command{ .{ .kind = .jump, .target = 0 }, .{ .kind = .end_stream } };
    var programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &commands }};
    var content = reviewContent(&programs);
    content.schema = runtime.wheel_music_schema;
    try std.testing.expectError(error.InvalidEventCommand, content.validate());
    const Case = struct { namespace: []const u8, forward_branches: ?bool, history: bool };
    for ([_]Case{
        .{ .namespace = runtime.wheel_motion_schema, .forward_branches = null, .history = false },
        .{ .namespace = runtime.branch_history_schema, .forward_branches = null, .history = true },
        .{ .namespace = runtime.actor_owners_schema, .forward_branches = true, .history = true },
        .{ .namespace = runtime.actor_owners_schema, .forward_branches = false, .history = false },
    }) |case| {
        content.schema = case.namespace;
        content.forward_branches = case.forward_branches;
        programs[0].commands = if (case.forward_branches == false) &backward_graph else &commands;
        try content.validate();
        for (0..7) |outcome| {
            var story = try runtime.StoryState.init(&.{content});
            var instance = try runtime.start(content, &story, "p");
            instance.execution.reloop = true;
            const spin = (try runtime.step(content, &instance, &story, .{})).batch.?;
            try std.testing.expectEqual(@as(u8, 1), spin.effect_count);
            try std.testing.expectEqual(.wheel_spin, spin.effects[0].kind);
            try runtime.acknowledge(content, &instance, &story, spin.id);
            const before = instance;
            try std.testing.expectError(error.WheelResultNotReady, runtime.step(content, &instance, &story, .{}));
            try std.testing.expectEqualDeep(before, instance);
            const branch = (try runtime.step(content, &instance, &story, .{ .wheel_outcome = @intCast(outcome) })).batch.?;
            try std.testing.expectEqual(@as(u16, @intCast(outcome)), branch.effects[0].cue.?);
            try runtime.acknowledge(content, &instance, &story, branch.id);
            try std.testing.expect(!instance.execution.active);
            const restored = try roundTrip(runtime.Instance, instance);
            defer restored.deinit();
            try restored.value.validate(content);
            try std.testing.expectEqual(case.history, restored.value.execution.path != null);
            if (case.history) {
                var history: runtime.CommandHistory = .{ .commands = &commands, .execution = restored.value.execution };
                const expected = [_]u16{ 0, 1, @intCast(2 + outcome * 2), @intCast(3 + outcome * 2) };
                for (expected) |index| try std.testing.expectEqual(index, history.next().?.index);
                try std.testing.expect(history.next() == null);
                var invalid = restored.value;
                invalid.execution.path.?.edges[0].target = @intCast(2 + ((outcome + 1) % 7) * 2);
                try std.testing.expectError(error.InvalidEventBranchHistory, invalid.validate(content));
            }
        }
    }
}

test "wheel branch paths keep actor cleanup separate and reject a leaking arm" {
    var commands = [_]runtime.Command{
        .{ .kind = .spawn_actor, .actor = "proxy" },
        .{ .kind = .branch_wheel, .targets = &.{ 2, 4, 4, 4, 4, 4, 4 } },
        .{ .kind = .release_actor, .actor = "proxy" },
        .{ .kind = .end_stream },
        .{ .kind = .place_actor, .actor = "proxy", .x = 168, .y = 272 },
        .{ .kind = .release_actor, .actor = "proxy" },
        .{ .kind = .end_stream },
    };
    const programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 2, .trigger = .none, .commands = &commands }};
    var content = reviewContent(&programs);
    content.schema = runtime.branch_history_schema;
    content.actors = &.{.{ .id = "proxy" }};
    try content.validate();
    commands[5] = .{ .kind = .label };
    try std.testing.expectError(error.InvalidEventActorLifetime, content.validate());
}

test "wheel complete source spin and return programs pass native admission" {
    const parsed = try std.json.parseFromSlice(runtime.Content, allocator, @import("wheel_data").event_json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try parsed.value.validate();
    try std.testing.expectEqual(@as(usize, 4), parsed.value.programs.len);
    try std.testing.expectEqual(@as(usize, 141), parsed.value.programs[0].commands.len);
    try std.testing.expectEqual(@as(usize, 20), parsed.value.programs[1].commands.len);
    try std.testing.expectEqual(@as(usize, 141), parsed.value.programs[2].commands.len);
    for (parsed.value.programs[0..3], [_]i32{ 160, 0, 160 }) |program, initial_y| {
        var cameras: usize = 0;
        for (program.commands, 0..) |command, index| {
            if (command.kind != .set_camera) continue;
            try std.testing.expectEqual(@as(?i32, 16), command.x);
            try std.testing.expectEqual(@as(?i32, initial_y), command.y);
            try std.testing.expectEqual(.hide_hero, program.commands[index + 1].kind);
            cameras += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), cameras);
    }
}

test "wheel timed controls preserve zero operand and reject durations above one byte" {
    var commands = [_]runtime.Command{ .{ .kind = .wheel_turn, .updates = 0 }, .{ .kind = .end_stream } };
    const programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &commands }};
    var content = reviewContent(&programs);
    content.schema = runtime.wheel_motion_schema;
    try content.validate();
    commands[0].updates = 255;
    try content.validate();
    commands[0].updates = 256;
    try std.testing.expectError(error.InvalidEventCommand, content.validate());
}

test "Hero visibility follows acknowledged release and restoration across serialization" {
    const commands = [_]runtime.Command{ .{ .kind = .hide_hero }, .{ .kind = .wait_for_accept }, .{ .kind = .place_hero, .x = 168, .y = 328 }, .{ .kind = .end_stream } };
    const programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 3, .trigger = .none, .commands = &commands }};
    var content = reviewContent(&programs);
    content.schema = runtime.item_overload_schema;
    try std.testing.expectError(error.InvalidEventCommand, content.validate());
    content.schema = runtime.hero_visibility_schema;
    var story = try runtime.StoryState.init(&.{content});
    var instance = try runtime.start(content, &story, "p");
    const hidden = (try runtime.step(content, &instance, &story, .{})).batch.?;
    try std.testing.expect(instance.heroVisible(content));
    try runtime.acknowledge(content, &instance, &story, hidden.id);
    try std.testing.expect(!instance.heroVisible(content));
    const restored = try roundTrip(runtime.Instance, instance);
    defer restored.deinit();
    try std.testing.expect(!restored.value.heroVisible(content));
    _ = try runtime.step(content, &instance, &story, .{ .confirm = true });
    const placed = (try runtime.step(content, &instance, &story, .{})).batch.?;
    try std.testing.expect(!instance.heroVisible(content));
    try runtime.acknowledge(content, &instance, &story, placed.id);
    try std.testing.expect(instance.heroVisible(content));
}

test "item overload holds its isolated receipt until the modal closes" {
    const commands = [_]runtime.Command{ .{ .kind = .item_overload, .item_name = "medicine" }, .{ .kind = .end_stream } };
    const programs = [_]runtime.Program{.{ .id = "p", .entry = .ordinary, .entity = 0, .trigger = .none, .commands = &commands }};
    var content = reviewContent(&programs);
    content.schema = runtime.wheel_motion_schema;
    try std.testing.expectError(error.InvalidEventCommand, content.validate());
    content.schema = runtime.item_overload_schema;
    var story = try runtime.StoryState.init(&.{content});
    var instance = try runtime.start(content, &story, "p");
    const request = (try runtime.step(content, &instance, &story, .{})).batch.?;
    try std.testing.expect(instance.pendingItemOverload());
    try std.testing.expectEqual(@as(u8, 1), request.effect_count);
    const repeated = (try runtime.step(content, &instance, &story, .{ .confirm = true })).batch.?;
    try std.testing.expectEqual(request.id, repeated.id);
    try runtime.acknowledge(content, &instance, &story, request.id);
    try std.testing.expect(!instance.pendingItemOverload());
    try std.testing.expectError(error.NoPendingEventBatch, runtime.acknowledge(content, &instance, &story, request.id));
}

test "event_runtime schema_versions parses all 29 versions and classifies commands" {
    const schema_mod = runtime.schema_versions;
    var version_buffer: [32]u8 = undefined;
    for (1..30) |version| {
        const name = try std.fmt.bufPrint(&version_buffer, "suikoden-event-ir/{d}", .{version});
        try std.testing.expectEqual(@as(?u8, @intCast(version)), schema_mod.parseVersion(name));
    }
    try std.testing.expectEqual(@as(?u8, 1), schema_mod.parseVersion(runtime.schema));
    try std.testing.expectEqual(@as(?u8, 2), schema_mod.parseVersion(runtime.campaign_schema));
    try std.testing.expectEqual(@as(?u8, 15), schema_mod.parseVersion(runtime.party_select_schema));
    try std.testing.expectEqual(@as(?u8, 29), schema_mod.parseVersion(runtime.scenery_mutation_schema));
    try std.testing.expectEqual(@as(?u8, null), schema_mod.parseVersion("suikoden-event-ir/0"));
    try std.testing.expectEqual(@as(?u8, null), schema_mod.parseVersion("suikoden-event-ir/01"));
    try std.testing.expectEqual(@as(?u8, null), schema_mod.parseVersion("suikoden-event-ir/30"));
    try std.testing.expectEqual(@as(?u8, null), schema_mod.parseVersion("other/2"));
    try std.testing.expect(!schema_mod.isCampaignNamespace(runtime.schema));
    try std.testing.expect(schema_mod.isCampaignNamespace(runtime.campaign_schema));
    try std.testing.expect(schema_mod.atLeast(runtime.camera_push_schema, 28));
    try std.testing.expect(!schema_mod.atLeast(runtime.actor_owners_schema, 28));

    try std.testing.expectEqual(runtime.Command.Category.control_flow, (runtime.Command{ .kind = .jump }).category());
    try std.testing.expectEqual(runtime.Command.Category.wait, (runtime.Command{ .kind = .wait_for_accept }).category());
    try std.testing.expectEqual(runtime.Command.Category.dialogue, (runtime.Command{ .kind = .open_box }).category());
    try std.testing.expectEqual(runtime.Command.Category.camera_visual, (runtime.Command{ .kind = .camera_push }).category());
    try std.testing.expectEqual(runtime.Command.Category.actor_track, (runtime.Command{ .kind = .queue_track }).category());
    try std.testing.expectEqual(runtime.Command.Category.party_inventory, (runtime.Command{ .kind = .party_join }).category());
    try std.testing.expectEqual(runtime.Command.Category.transition, (runtime.Command{ .kind = .battle }).category());
    try std.testing.expectEqual(runtime.Command.Category.story_flag, (runtime.Command{ .kind = .story_or }).category());
    try std.testing.expectEqual(runtime.Command.Category.service_minigame, (runtime.Command{ .kind = .fixed_dice }).category());
    try std.testing.expectEqual(runtime.Command.Category.source_record, (runtime.Command{ .kind = .source_move_batch }).category());
}

test "event_runtime converts a validated field effect into required execution fields" {
    const valid = runtime.Command{ .kind = .field_effect, .origin = 9, .x = 16, .y = 2040, .effect = .appearance };
    try std.testing.expectEqualDeep(runtime.FieldEffectOperation{ .origin = 9, .x = 16, .y = 2040, .effect = .appearance }, valid.fieldEffectOperation().?);
    var invalid = valid;
    invalid.x = null;
    try std.testing.expect(invalid.fieldEffectOperation() == null);
    invalid.x = 17;
    try std.testing.expect(invalid.fieldEffectOperation() == null);
    invalid = valid;
    invalid.effect = null;
    try std.testing.expect(invalid.fieldEffectOperation() == null);
}

test "event_runtime converts scenery commands into instance and template operations" {
    const commands = try std.json.parseFromSlice([]runtime.Command, std.testing.allocator,
        \\[
        \\  {"kind":"scenery_stage","scenery_object":0},
        \\  {"kind":"scenery_restore","scenery_object":42},
        \\  {"kind":"scenery_append","scenery_object":65535},
        \\  {"kind":"scenery_stage"},
        \\  {"kind":"end_stream","scenery_object":1}
        \\]
    , .{});
    defer commands.deinit();
    try std.testing.expectEqualDeep(runtime.SceneryOperation{ .stage_instance = 0 }, commands.value[0].sceneryOperation().?);
    try std.testing.expectEqualDeep(runtime.SceneryOperation{ .restore_instance = 42 }, commands.value[1].sceneryOperation().?);
    try std.testing.expectEqualDeep(runtime.SceneryOperation{ .append_template = 65535 }, commands.value[2].sceneryOperation().?);
    try std.testing.expect(commands.value[3].sceneryOperation() == null);
    try std.testing.expect(commands.value[4].sceneryOperation() == null);
}

test "event_runtime decodes room and world transition destinations from existing JSON" {
    const parsed = try std.json.parseFromSlice([]runtime.Command, std.testing.allocator,
        \\[
        \\  {"kind":"room_transition","destination":"inside","x":2040,"y":0,"arrival_facing":"left","source_arrival":true,"world_entry":"north_gate"},
        \\  {"kind":"room_transition","destination":"inside","x":0,"y":2040,"world_point":0},
        \\  {"kind":"world_transition","destination":"world_a","x":0,"y":255},
        \\  {"kind":"world_transition","retain_world_region":true,"x":255,"y":0},
        \\  {"kind":"world_transition","return_to_entry":true}
        \\]
    , .{});
    defer parsed.deinit();
    const commands = parsed.value;
    try std.testing.expectEqualDeep(runtime.RoomTransition{
        .origin = 0,
        .destination = "inside",
        .x = 2040,
        .y = 0,
        .facing = .left,
        .source_arrival = true,
        .world_entry = .{ .named = "north_gate" },
    }, commands[0].roomTransition().?);
    try std.testing.expectEqual(@as(u8, 0), commands[1].roomTransition().?.world_entry.point);
    try std.testing.expectEqualDeep(runtime.WorldTransition{ .destination = .{ .room = "world_a", .cell = .{ .x = 0, .y = 255 } } }, commands[2].worldTransition().?);
    try std.testing.expectEqualDeep(runtime.WorldTransition{ .retained_region = .{ .x = 255, .y = 0 } }, commands[3].worldTransition().?);
    try std.testing.expect(commands[4].worldTransition().? == .return_to_entry);

    var invalid = commands[0];
    invalid.x = 7;
    try std.testing.expect(invalid.roomTransition() == null);
    invalid = commands[0];
    invalid.world_point = 0;
    try std.testing.expect(invalid.roomTransition() == null);
    invalid = commands[2];
    invalid.y = 256;
    try std.testing.expect(invalid.worldTransition() == null);
    invalid = commands[3];
    invalid.destination = "world_a";
    try std.testing.expect(invalid.worldTransition() == null);
    invalid = commands[4];
    invalid.y = 0;
    try std.testing.expect(invalid.worldTransition() == null);
}

test "event_runtime distinguishes actor placement, cell movement and source hero facing" {
    const placement = runtime.Command{ .kind = .place_actor, .actor = "guard", .x = 0, .if_actor_constructed = true };
    try std.testing.expectEqualDeep(runtime.ActorPlacement{
        .actor = "guard",
        .x = 0,
        .y = null,
        .if_constructed = true,
    }, placement.actorPlacement().?);
    var invalid = placement;
    invalid.y = 7;
    try std.testing.expect(invalid.actorPlacement() == null);
    invalid = placement;
    invalid.x = null;
    try std.testing.expect(invalid.actorPlacement() == null);

    const move = runtime.Command{ .kind = .actor_y, .actor = "guard", .value = 255, .origin = 2 };
    try std.testing.expectEqualDeep(runtime.ActorAxisMove{ .actor = "guard", .axis = .y, .cell = 255, .origin = 2 }, move.actorAxisMove().?);
    const restore = runtime.Command{ .kind = .actor_motion, .actor = "guard", .value = 0, .if_actor_constructed = true };
    try std.testing.expectEqualDeep(runtime.ActorMotionRestore{ .actor = "guard", .speed = 0, .if_constructed = true }, restore.actorMotionRestore().?);

    for ([_]runtime.ActorFacing.Variant{ .up, .right, .down, .left }, 0..) |expected, code| {
        const turn = runtime.Command{ .kind = .source_hero_transition, .transition = @intCast(code) };
        const facing = turn.actorFacing().?;
        try std.testing.expectEqualStrings("hero", facing.actor);
        try std.testing.expectEqual(expected, facing.variant);
    }
    const turn = runtime.Command{ .kind = .actor_transition, .actor = "guard", .transition = 2 };
    try std.testing.expectEqual(runtime.Direction.left, turn.actorFacing().?.variant.direction());
}
