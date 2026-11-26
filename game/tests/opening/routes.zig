const characterFields = @import("../character_fields.zig").capture;
const std = @import("std");
const route = @import("route");
const field_events = @import("field_events");
const field = @import("field");
const runtime = @import("event_runtime");
const battle = @import("battle");
const journey = @import("journey");

const route_api = [_][]const u8{
    "beginRoute",
    "tickPad",
    "tickFree",
    "beginConstructedRoute",
    "beginRetainedInteraction",
    "beginHomeStairs",
    "beginHomeRoute",
    "beginRoom2Event",
    "sourceCueRequest",
    "acknowledgeSourceCue",
    "sourceTedAddRequest",
    "acknowledgeTedAdd",
    "proposeRoomTransition",
    "acknowledgeRoomTransition",
};

test "route uses source order and requires battle and party milestones" {
    var controller: route.Controller = .{};
    try std.testing.expectEqual(route.Stage.dungeon, try controller.complete(.opening));
    try std.testing.expectError(error.OutOfOrderStage, controller.complete(.palace));
    try std.testing.expectEqual(route.Stage.palace, try controller.completeDungeon("vaa_room_0"));
    try std.testing.expectEqual(route.Stage.first_town, try controller.complete(.palace));
    try std.testing.expectEqual(route.Stage.world, try controller.completeFirstTown("va1_room_0"));
    try std.testing.expect(!controller.worldReady());
    controller.noteOpeningBattle(.victory_returned);
    try std.testing.expect(!controller.worldReady());
    controller.noteInitialParty(true);
    try std.testing.expect(controller.worldReady());
}

test "the shared field-event Session declares every Opening route method" {
    inline for (route_api) |name| {
        try std.testing.expect(@hasDecl(field_events.Session, name));
    }
    comptime {
        _ = &field_events.Session.beginRoute;
        _ = &field_events.Session.tickPad;
        _ = &field_events.Session.tickFree;
        _ = &field_events.Session.beginConstructedRoute;
        _ = &field_events.Session.beginRetainedInteraction;
        _ = &field_events.Session.beginHomeStairs;
        _ = &field_events.Session.beginHomeRoute;
        _ = &field_events.Session.beginRoom2Event;
        _ = &field_events.Session.sourceCueRequest;
        _ = &field_events.Session.acknowledgeSourceCue;
        _ = &field_events.Session.sourceTedAddRequest;
        _ = &field_events.Session.acknowledgeTedAdd;
        _ = &field_events.Session.proposeRoomTransition;
        _ = &field_events.Session.acknowledgeRoomTransition;
    }
}

test "scripted battle retries defeat and resumes the field event through the Journey frame clock" {
    const allocator = std.testing.allocator;
    const package = try field.load(allocator, @embedFile("../fixtures/journey_room.json"));
    defer package.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_battle.json"));
    defer content.deinit();
    const data = try journey.load(allocator, @embedFile("../fixtures/journey.json"), package.value, content.value);
    defer data.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const inn = try field.inn.load(allocator, field.inn.json);
    defer inn.deinit();
    var party: [battle.Party.roster_capacity]battle.Member = undefined;
    var combat_backing: battle.State = undefined;
    var journey_state = try journey.State.initEpisode(package.value, data.value, content.value, items.value, inn.value, &party, &combat_backing);
    const assets = try field_events.Owned.load(allocator, journey_state.field_state.progress.party.values()[0..journey_state.field_state.progress.party.len]);
    defer assets.deinit();
    var binding = assets.binding();
    const commands: []const runtime.Command = &.{
        .{ .kind = .continue_tick },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 2 } },
        .{ .kind = .battle, .battle = "area_a_1" },
        .{ .kind = .story_or, .flag = .{ .id = "scenario_0001", .mask = 1 } },
        .{ .kind = .end_stream },
    };
    binding.content = .{
        .schema = runtime.schema,
        .id = "battle_test",
        .content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .story_values = &.{.{ .id = "scenario_0001", .storage = .scenario, .byte_index = 1, .initial = 0 }},
        .programs = &.{.{ .id = "battle_test", .entry = .ordinary, .entity = 1, .trigger = .none, .commands = commands }},
    };
    binding.context.event_id = binding.content.id;
    binding.context.event_sha256 = binding.content.content_sha256;
    binding.dispatch = null;
    binding.population.schema = "suikoden-scene-population/2";
    binding.population.story_values = &.{.{ .id = "scenario_0001", .storage = .scenario, .byte_index = 1 }};
    binding.population.programs = &.{.{ .id = "battle_test", .namespace = runtime.schema, .content_id = binding.content.id }};
    binding.population.entities = &.{
        .{
            .id = "blocked_by_story",
            .source_order = 0,
            .record_role = .event,
            .population_candidate = false,
            .source_character_id = null,
            .resource_id = null,
            .resource_domain = null,
            .position = .{ .source_x = 0, .source_y = 0, .x = 0, .y = 0, .placement = .not_applicable },
            .classification = .{ .pointer_state = .null, .terms = &.{} },
            .event_selection = .{ .pointer_state = .present, .terms = &.{
                .{ .kind = .story_mask_set, .flag = .{ .id = "scenario_0001", .mask = 8 } },
                .{ .kind = .unsupported, .semantics = "unknown_legacy_term" },
            } },
            .trigger = .ordinary,
            .initialization_order = null,
            .event = .{ .reference = "blocked_stream", .status = .source_only, .program_id = null },
        },
        .{
            .id = "coordinate_battle",
            .source_order = 1,
            .record_role = .event,
            .population_candidate = false,
            .source_character_id = null,
            .resource_id = null,
            .resource_domain = null,
            .position = .{ .source_x = 0, .source_y = 0, .x = 0, .y = 0, .placement = .not_applicable },
            .classification = .{ .pointer_state = .null, .terms = &.{} },
            .event_selection = .{ .pointer_state = .present, .terms = &.{
                .{ .kind = .story_mask_clear, .flag = .{ .id = "scenario_0001", .mask = 2 } },
                .{ .kind = .coordinate_range, .coordinate = .{ .axis = .x, .first = 27, .last = 28 } },
                .{ .kind = .coordinate_range, .coordinate = .{ .axis = .y, .first = 25, .last = 25 } },
            } },
            .trigger = .ordinary,
            .initialization_order = null,
            .event = .{ .reference = "battle_stream", .status = .resolved, .program_id = "battle_test" },
        },
    };
    const state = &journey_state.field_state;
    state.room = package.value.roomIndex(binding.room).?;
    state.x = 208;
    state.y = 200;
    state.destination = .{ .x = state.x, .y = state.y };
    state.progress.story.scenario = try runtime.StoryState.init(&.{binding.content});
    var session: field_events.Session = undefined;
    try std.testing.expect(!try session.beginOrdinary(binding, state.*, 12, null));
    state.x = 216;
    state.destination.x = state.x;
    try std.testing.expect(try session.beginOrdinary(binding, state.*, 12, null));

    try std.testing.expectEqual(.running, try session.tick(binding, state, false));
    try std.testing.expectEqual(@as(u8, 2), state.progress.story.scenario.?.scenario[1]);
    try std.testing.expect(session.queuedBattle() == null);
    try std.testing.expectEqual(.running, try session.tick(binding, state, false));
    try std.testing.expectEqualStrings("area_a_1", session.pending_battle.?);
    const queued = try field_events.Checkpoint.capture(session, state.*);
    try std.testing.expect(session.takeBattle() != null);
    try std.testing.expectError(error.InvalidFieldBattleReceipt, journey_state.attachFieldEvent(&session, &binding));
    try queued.apply(allocator, binding, &session, state);
    const request = session.queuedBattle().?;
    try std.testing.expectEqualDeep(request, session.queuedGameplayRequest().?.battle);
    journey_state.menu.phase = .root;
    try std.testing.expectError(error.GameBusy, journey_state.beginScriptedBattle(&session, binding));
    try std.testing.expectEqualStrings(request.id, session.queuedBattle().?.id);
    journey_state.menu.phase = .closed;
    state.rest_ticks = 1;
    const combat_progress_before = journey_state.combat.progress;
    try std.testing.expectError(error.GameBusy, journey_state.beginScriptedBattle(&session, binding));
    try std.testing.expectEqualDeep(combat_progress_before, journey_state.combat.progress);
    try std.testing.expectEqualStrings(request.id, session.queuedBattle().?.id);
    state.rest_ticks = 0;
    const money_before = state.progress.money;
    try journey_state.attachFieldEvent(&session, &binding);
    try std.testing.expectError(error.GameBusy, journey_state.attachFieldEvent(&session, &binding));
    try std.testing.expectError(error.GameBusy, journey_state.beginEncounter(0));
    var save_dir = std.testing.tmpDir(.{});
    defer save_dir.cleanup();
    try std.testing.expectError(error.GameBusy, journey.saveSlot(std.testing.io, allocator, save_dir.dir, journey_state, 0, journey_state.save_name));
    _ = try journey_state.tickWithFieldEvents(.{ .menu = true, .field = .{ .direction = .up } }, .{ .confirm = true });
    try std.testing.expectEqual(.battle, journey_state.mode);
    try std.testing.expectEqual(.closed, journey_state.menu.phase);
    try std.testing.expectEqual(@as(i32, 200), state.y);
    try std.testing.expectEqualStrings("area_a_1", journey_state.combat.content.encounters[journey_state.combat.encounter].id);
    try std.testing.expect(journey_state.encounter_trigger == null);
    try std.testing.expectError(error.ScriptedBattleNotReady, journey_state.resumeScriptedBattle(&session, binding));
    const inflight = try field_events.Checkpoint.capture(session, state.*);
    try inflight.apply(allocator, binding, &session, state);
    try std.testing.expect(session.takeBattle() == null);
    try std.testing.expectEqual(.running, try session.tick(binding, state, true));
    try std.testing.expectEqual(@as(u8, 2), state.progress.story.scenario.?.scenario[1]);
    var stale = request;
    stale.receipt.instance += 1;
    try std.testing.expectError(error.InvalidFieldBattleReceipt, session.resumeBattle(binding, state, stale, .victory));

    const before_attempt = journey_state.combat.progress.party.values();
    const random_before = journey_state.combat.random;
    const enemy_hp_before = journey_state.combat.enemy_hp;
    for (journey_state.combat.progress.party.items()) |member| member.hp = 1;
    journey_state.combat.progress.money -= 17;
    for (0..4000) |_| {
        if (journey_state.mode == .defeat) break;
        const input: battle.Input = switch (journey_state.combat.phase) {
            .battle_menu, .confirm_round => .{ .confirm = true },
            .command => if (journey_state.combat.picker.selected == .defend) .{ .confirm = true } else .{ .down = true },
            .victory, .escaped => return error.UnexpectedScriptedOutcome,
            else => .{},
        };
        _ = try journey_state.tickWithFieldEvents(.{}, input);
    } else return error.ScriptedDefeatDidNotFinish;
    try std.testing.expectEqual(.defeat, journey_state.audioScene());
    try std.testing.expectError(error.ScriptedBattleNotReady, journey_state.resumeScriptedBattle(&session, binding));
    try std.testing.expectEqual(@as(u8, 2), state.progress.story.scenario.?.scenario[1]);
    try std.testing.expectEqualDeep(request, journey_state.scripted_battle.?.request);
    _ = try journey_state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.battle, journey_state.mode);
    try std.testing.expectEqual(.battle, journey_state.audioScene());
    try std.testing.expectEqualDeep(before_attempt, journey_state.combat.progress.party.values());
    try std.testing.expectEqualDeep(random_before, journey_state.combat.random);
    try std.testing.expectEqualDeep(enemy_hp_before, journey_state.combat.enemy_hp);
    try std.testing.expectEqual(money_before, journey_state.combat.progress.money);
    try std.testing.expectEqualDeep(request, journey_state.scripted_battle.?.request);
    try std.testing.expect(journey_state.field_event.?.session == &session);
    try std.testing.expect(session.takeBattle() == null);
    try std.testing.expectEqual(.running, try session.tick(binding, state, false));

    for (0..6000) |_| {
        if (journey_state.combat.phase == .victory and journey_state.combat.rewardReady()) break;
        switch (journey_state.combat.phase) {
            .battle_menu => {
                for (0..3) |_| _ = try journey_state.tickWithFieldEvents(.{}, .{ .down = true });
                _ = try journey_state.tickWithFieldEvents(.{}, .{ .confirm = true });
            },
            .victory => _ = try journey_state.tickWithFieldEvents(.{}, .{ .confirm = true }),
            .defeat, .escaped => return error.UnexpectedScriptedOutcome,
            else => _ = try journey_state.tickWithFieldEvents(.{}, .{}),
        }
    } else return error.ScriptedBattleDidNotFinish;
    try std.testing.expectEqual(@as(u8, 2), state.progress.story.scenario.?.scenario[1]);
    const earned = journey_state.combat.reward_received;
    const other = try allocator.create(field_events.Session);
    defer allocator.destroy(other);
    other.* = session;
    _ = journey_state.tick(.{ .field = .{ .action = true } }, .{ .confirm = true, .restart = true });
    try std.testing.expectError(error.ScriptedBattleFieldMismatch, journey_state.resumeScriptedBattle(other, binding));
    try std.testing.expect(state.progress == journey_state.progress());
    try journey_state.resumeScriptedBattle(&session, binding);
    try std.testing.expectEqual(.field, journey_state.mode);
    try std.testing.expect(earned > 0);
    try std.testing.expectEqual(money_before + earned, state.progress.money);
    try std.testing.expect(!state.progress.story.forest_battle_one_won and journey_state.suppressed_trigger == null);
    try std.testing.expectError(error.MissingScriptedBattleRequest, journey_state.resumeScriptedBattle(&session, binding));
    try std.testing.expectEqual(@as(u8, 2), state.progress.story.scenario.?.scenario[1]);
    _ = try journey_state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(@as(u8, 3), state.progress.story.scenario.?.scenario[1]);
    try std.testing.expectEqual(@as(u8, 3), journey_state.combat.progress.story.scenario.?.scenario[1]);
    try std.testing.expect(journey_state.field_event == null);
    try std.testing.expectError(error.InactiveFieldEvent, journey_state.attachFieldEvent(&session, &binding));
    try std.testing.expect(!try session.beginOrdinary(binding, state.*, 13, null));

    state.progress.story.scenario = try runtime.StoryState.init(&.{binding.content});
    try std.testing.expect(try session.beginOrdinary(binding, state.*, 13, null));
    const escape_money = state.progress.money;
    const escape_experience = characterFields("experience", journey_state.combat.progress.party);
    try journey_state.attachFieldEvent(&session, &binding);
    _ = try journey_state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(.field, journey_state.mode);
    try std.testing.expectEqual(@as(u8, 2), journey_state.combat.progress.story.scenario.?.scenario[1]);
    _ = try journey_state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(.battle, journey_state.mode);
    try std.testing.expect(journey_state.combat.canLetGo());
    _ = try journey_state.tickWithFieldEvents(.{}, .{ .down = true });
    _ = try journey_state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try std.testing.expectEqual(.escaped, journey_state.combat.phase);
    try std.testing.expectError(error.ScriptedBattleNotReady, journey_state.resumeScriptedBattle(&session, binding));
    _ = try journey_state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try std.testing.expectEqual(@as(u8, 2), state.progress.story.scenario.?.scenario[1]);
    try std.testing.expectEqual(@as(u32, 0), journey_state.combat.reward_received);
    try std.testing.expectEqual(.field, journey_state.mode);
    try std.testing.expectEqual(escape_money, state.progress.money);
    try std.testing.expectEqual(escape_experience, characterFields("experience", journey_state.combat.progress.party));
    try std.testing.expect(!state.progress.story.forest_battle_one_won);
    try std.testing.expectError(error.MissingScriptedBattleRequest, journey_state.resumeScriptedBattle(&session, binding));
    _ = try journey_state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqual(@as(u8, 3), state.progress.story.scenario.?.scenario[1]);
}

test "the Opening ledger reports required stages integrated and the boundary ready" {
    const ledger = @import("opening_ledger");
    const packet = try ledger.open(std.testing.allocator);
    defer packet.deinit();
    try std.testing.expectEqual(ledger.BoundaryStatus.ready, packet.value.boundary.status);
    try std.testing.expect(packet.value.firstBlockedRequirement() == null);
    try std.testing.expect(packet.value.blockerById("native_review") != null);
}
