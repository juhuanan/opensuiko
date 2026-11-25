const std = @import("std");
const world = @import("world");
const allocator = std.testing.allocator;

test "scripted crossing consumes decoded route four" {
    const travel = @import("travel_modes");
    const hash: [64]u8 = @splat('0');
    var controller = try travel.Controller.open(.{ .id = "first_crossing", .content_sha256 = &hash, .location = "water_region", .position = .{ .x = 119, .y = 75 }, .heading = .west });
    try controller.startRoute(4);
    for (0..20 * 16) |_| try std.testing.expect(!try controller.tickRoute());
    try std.testing.expectEqual(travel.Point{ .x = 100, .y = 74 }, controller.state.position);
    try std.testing.expect(try controller.tickRoute());
    try std.testing.expect(controller.state.selector == null);
}

test {
    _ = @import("battle_commander.zig");
    _ = @import("battle_enemy_wave.zig");
    _ = @import("battle_holly_fairy.zig");
    _ = @import("battle_enemy_area_magic.zig");
    _ = @import("battle_enemy_regional.zig");
    _ = @import("battle_rabbit.zig");
}
fn content() !std.json.Parsed(world.Content) {
    return world.load(allocator, world.json);
}

test "source world-B data validates named enemies, original holes and village spawn" {
    const data = try content();
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 8), data.value.encounters.len);
    const entry = data.value.encounters[1];
    try std.testing.expectEqualStrings("flying_squirrel", entry.enemies[0].?);
    try std.testing.expect(entry.enemies[1] == null);
    try std.testing.expectEqualStrings("flying_squirrel", entry.enemies[2].?);
    try std.testing.expectEqual(@as(u16, 22), entry.enemy_level_sum);
    var bad = data.value;
    bad.walkable = "1";
    try std.testing.expectError(error.InvalidWorldContent, bad.validate());
    bad = data.value;
    bad.field_exit.x = std.math.maxInt(i32);
    try std.testing.expectError(error.InvalidWorldEntrance, bad.validate());
    bad = data.value;
    bad.schema = "future";
    try std.testing.expectError(error.UnsupportedWorldContent, bad.validate());
}

test "world heading resolution matches256 original resolver cases and requested-axis guards" {
    const Case = struct { mask: u4, heading: u2, requested: u2, accepted: bool, facing: u2 };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/world_resolvers.json"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        var passable: [4]bool = undefined;
        for (&passable, 0..) |*pass, i| pass.* = case.mask & (@as(u4, 1) << @intCast(i)) != 0;
        const decision = world.resolve(@fromBackingInt(case.requested), @fromBackingInt(case.heading), passable);
        try std.testing.expectEqual(case.accepted, decision.accepted);
        try std.testing.expectEqual(case.facing, @backingInt(decision.heading));
    }
    for (0..256) |value| {
        const v: i32 = @intCast(value);
        try std.testing.expectEqual(value > 0, world.requestedAxisAllowed(.{ .x = 60, .y = v }, .north));
        try std.testing.expectEqual(value < 105, world.requestedAxisAllowed(.{ .x = 60, .y = v }, .south));
        try std.testing.expectEqual(value < 140, world.requestedAxisAllowed(.{ .x = v, .y = 60 }, .east));
        try std.testing.expectEqual(value > 0, world.requestedAxisAllowed(.{ .x = v, .y = 60 }, .west));
    }
}

test "world eligibility, biased partition, rune suppression and draw consumption match original gate and picker" {
    const data = try content();
    defer data.deinit();
    const Case = struct { chance: u15, pick: u15, counter: u16, party: u16, rune: bool, enabled: bool, scripted: bool, boat: bool, ready: bool, pending: bool, table: bool, accepted: bool, draws: usize, next_pending: bool, selected: ?u8 };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/world_encounters.json"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        var state: world.State = .{ .camera = .{ .x = 86, .y = 90 }, .heading = .south, .remaining = if (case.ready) 0 else 1, .encounters_enabled = case.enabled, .scripted = case.scripted, .boat = case.boat, .encounter_pending = case.pending, .travel_counter = case.counter };
        const values = [2]u15{ case.chance, case.pick };
        var draws: world.Draws = .{ .values = &values };
        var payload = data.value;
        if (!case.table) payload.encounters = &.{};
        const selected = try state.checkEncounter(payload, &draws, case.party, case.rune);
        try std.testing.expectEqual(case.accepted, selected != null);
        try std.testing.expectEqual(case.draws, draws.cursor);
        try std.testing.expectEqual(case.next_pending, state.encounter_pending);
        if (case.selected) |index| try std.testing.expectEqualStrings(data.value.encounters[index - 1].id, state.selected.?) else try std.testing.expect(state.selected == null);
    }
}

test "world foot walking completes16 updates, arms one source encounter and retains its return position" {
    const data = try content();
    defer data.deinit();
    var state: world.State = .{ .camera = data.value.return_camera, .heading = .south };
    var draws: world.Draws = .{ .values = &.{ 0, 4095 } };
    for (0..5) |step| {
        for (0..16) |frame| {
            const event = try state.tick(data.value, .{ .direction = .south }, &draws, .{ .level_sum = 30 });
            if (step == 4 and frame == 15) {
                try std.testing.expectEqualStrings("world_b_encounter_2", event.battle_requested.id);
            } else try std.testing.expect(event == .none);
            try std.testing.expectEqual(@as(u8, @intCast(15 - frame)), state.remaining);
            try std.testing.expectEqual(@as(i32, 86 * 16), state.originPixels().x);
            try std.testing.expectEqual(@as(i32, 85 * 16 + @as(i32, @intCast(step * 16 + frame + 1))), state.originPixels().y);
        }
    }
    try std.testing.expectEqual(.battle_pending, state.mode);
    const handoff = try state.tick(data.value, .{}, &draws, .{ .level_sum = 30 });
    try std.testing.expectEqualStrings("world_b_encounter_2", handoff.battle.id);
    try std.testing.expectEqual(.battle, state.mode);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    const camera = state.camera;
    try std.testing.expect((try state.tick(data.value, .{ .direction = .south }, &draws, .{ .level_sum = 30 })) == .none);
    try state.finishBattle(.defeated);
    try std.testing.expectEqual(.battle, state.mode);
    try state.finishBattle(.fled);
    try std.testing.expectEqualDeep(camera, state.camera);
    try std.testing.expectEqual(@as(u16, 0), state.travel_counter);
    try std.testing.expect((try state.tick(data.value, .{}, &draws, .{ .level_sum = 30 })) == .none);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
}

test "Stallion foot travel takes eight updates per cell with unchanged step encounter cadence and versioned checkpoints" {
    const data = try content();
    defer data.deinit();
    var state: world.State = .{ .camera = data.value.return_camera, .heading = .south, .speed = .stallion };
    var draws: world.Draws = .{ .values = &.{ 0, 4095 } };
    for (0..40) |frame| {
        const event = try state.tick(data.value, .{ .direction = .south }, &draws, .{ .level_sum = 30 });
        try std.testing.expectEqual(@as(i32, 85 * 16 + @as(i32, @intCast((frame + 1) * 2))), state.originPixels().y);
        try std.testing.expectEqual(@as(u16, @intCast((frame + 1) / 8)), state.travel_counter);
        if (frame == 39) try std.testing.expectEqualStrings("world_b_encounter_2", event.battle_requested.id) else try std.testing.expect(event == .none);
    }
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    const checkpoint = try world.Checkpoint.capture(state, data.value, draws);
    var restored: world.State = .{ .camera = .{ .x = 0, .y = 0 }, .heading = .north };
    try checkpoint.apply(data.value, &restored, &draws);
    try std.testing.expectEqualDeep(state, restored);
    var invalid = checkpoint;
    invalid.schema = "suikoden-world-checkpoint/1";
    try std.testing.expectError(error.UnsupportedWorldCheckpoint, invalid.apply(data.value, &restored, &draws));
    invalid = checkpoint;
    invalid.state.remaining = 8;
    try std.testing.expectError(error.InvalidWorldState, invalid.apply(data.value, &restored, &draws));
    invalid = checkpoint;
    invalid.state.schema = "suikoden-world-state/1";
    try std.testing.expectError(error.UnsupportedWorldState, invalid.apply(data.value, &restored, &draws));
    try std.testing.expectEqualDeep(state, restored);
}

test "village point takes precedence over encounter checks and returns to source world camera" {
    const data = try content();
    defer data.deinit();
    var state: world.State = .{ .camera = data.value.return_camera, .heading = .north, .travel_counter = 20, .encounter_pending = true };
    var draws: world.Draws = .{ .values = &.{} };
    const event = try state.tick(data.value, .{ .direction = .north }, &draws, .{ .level_sum = 30 });
    try std.testing.expectEqualStrings("village", event.entrance_requested.destination.?);
    try std.testing.expectEqual(@as(i32, 264), event.entrance_requested.spawn_x);
    try std.testing.expectEqual(@as(i32, 344), event.entrance_requested.spawn_y);
    try std.testing.expectEqual(@as(u8, 15), state.remaining);
    try std.testing.expectEqual(.field_pending, state.mode);
    const handoff = try state.tick(data.value, .{}, &draws, .{ .level_sum = 30 });
    try std.testing.expectEqualStrings("village", handoff.entrance.destination.?);
    try std.testing.expectEqual(.field, state.mode);
    try state.leaveField(data.value);
    try std.testing.expectEqualDeep(data.value.return_camera, state.camera);
    try std.testing.expectEqual(.world, state.mode);
    // Source preload proximity keeps encounters pending without drawing while outside activation.
    state.travel_counter = 20;
    state.encounter_pending = true;
    try std.testing.expect((try state.tick(data.value, .{}, &draws, .{ .level_sum = 30 })) == .none);
    try std.testing.expect(state.encounter_pending);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "exhausted external random input rolls back atomically and a suppressed arm still consumes both draws" {
    const data = try content();
    defer data.deinit();
    var state: world.State = .{ .camera = .{ .x = 86, .y = 90 }, .heading = .south, .travel_counter = 5, .encounter_pending = true };
    const initial = state;
    var draws: world.Draws = .{ .values = &.{0} };
    try std.testing.expectError(error.RandomInputExhausted, state.tick(data.value, .{}, &draws, .{ .level_sum = 30 }));
    try std.testing.expectEqualDeep(initial, state);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    draws = .{ .values = &.{ 0, 32767 } };
    try std.testing.expect((try state.tick(data.value, .{ .encounter_arm_suppressed = true }, &draws, .{ .level_sum = 30 })) == .none);
    try std.testing.expectEqual(.world, state.mode);
    try std.testing.expectEqualStrings("world_b_encounter_8", state.selected.?);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    try std.testing.expect(!state.encounter_pending);
}

test "world component checkpoints restore stable references and external draw cursor without real saves" {
    const data = try content();
    defer data.deinit();
    for ([_]world.Draws{ .{ .values = &.{ 0, 32767, 200 } }, .{ .bios_state = 17 }, .{ .prng = .init(17) } }) |initial| {
        var state: world.State = .{ .camera = .{ .x = 86, .y = 90 }, .heading = .south, .travel_counter = 5, .encounter_pending = true };
        var draws = initial;
        _ = try state.tick(data.value, .{}, &draws, .{ .level_sum = 30 });
        try std.testing.expect(draws.cursor > initial.cursor);
        const checkpoint = try world.Checkpoint.capture(state, data.value, draws);
        const bytes = try std.json.Stringify.valueAlloc(allocator, checkpoint, .{});
        defer allocator.free(bytes);
        var restored: world.State = .{ .camera = .{ .x = 0, .y = 0 }, .heading = .north };
        var restored_draws = initial;
        const parsed = try std.json.parseFromSlice(world.Checkpoint, allocator, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try parsed.value.apply(data.value, &restored, &restored_draws);
        try std.testing.expectEqualDeep(state, restored);
        try std.testing.expectEqualDeep(draws, restored_draws);
        try std.testing.expectEqual(try draws.next(), try restored_draws.next());

        var invalid = checkpoint;
        if (initial.values.len != 0) {
            invalid.random_cursor = 100;
            try std.testing.expectError(error.InvalidRandomCursor, invalid.apply(data.value, &restored, &restored_draws));
        } else if (initial.prng != null) {
            invalid.schema = "suikoden-world-checkpoint/3";
            try std.testing.expectError(error.InvalidRandomSource, invalid.apply(data.value, &restored, &restored_draws));
        }
        try std.testing.expectEqualDeep(state, restored);
        try std.testing.expectEqualDeep(draws, restored_draws);
    }
}

test "world completion applies shared healing and poison before the encounter draws, preserving party state on return" {
    const data = try content();
    defer data.deinit();
    var members = [_]field.game_state.Member{
        .{ .id = "hero", .name = "Hero", .hp = 80, .max_hp = 100, .status = .poisoned, .rune_charges = @splat(0), .max_rune_charges = @splat(0) },
        .{ .id = "gremio", .name = "Gremio", .hp = 16, .max_hp = 17, .status = .healthy, .rune_charges = @splat(0), .max_rune_charges = @splat(0) },
    };
    var state: world.State = .{ .camera = .{ .x = 86, .y = 90 }, .heading = .south, .remaining = 1, .travel_counter = 4 };
    const initial = state;
    const initial_members = members;
    var draws: world.Draws = .{ .values = &.{255} };
    const party: world.Party = .{ .members = &members, .level_sum = 30, .step_healing_rune = true };
    try std.testing.expectError(error.RandomInputExhausted, state.tick(data.value, .{}, &draws, party));
    try std.testing.expectEqualDeep(initial, state);
    try std.testing.expectEqualDeep(initial_members, members);
    draws = .{ .values = &.{ 255, 0, 4095 } };
    const request = try state.tick(data.value, .{}, &draws, party);
    try std.testing.expectEqualStrings("world_b_encounter_2", request.battle_requested.id);
    try std.testing.expectEqual(@as(u16, 61), members[0].hp);
    try std.testing.expectEqual(@as(u16, 17), members[1].hp);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    _ = try state.tick(data.value, .{}, &draws, party);
    try state.finishBattle(.victory);
    try std.testing.expectEqual(@as(u16, 61), members[0].hp);
    try std.testing.expectEqual(.poisoned, members[0].status);
}

test "source step-healing restores a zero-HP member without an extra poison draw" {
    const data = try content();
    defer data.deinit();
    var members = [_]field.game_state.Member{.{ .id = "hero", .name = "Hero", .hp = 0, .max_hp = 100, .status = .unconscious, .rune_charges = @splat(0), .max_rune_charges = @splat(0) }};
    var state: world.State = .{ .camera = data.value.return_camera, .heading = .south, .remaining = 1 };
    var draws: world.Draws = .{ .values = &.{} };
    _ = try state.tick(data.value, .{}, &draws, .{ .members = &members, .level_sum = 1, .step_healing_rune = true });
    try std.testing.expectEqual(@as(u16, 1), members[0].hp);
    try std.testing.expectEqual(.healthy, members[0].status);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

fn hero() @import("field").game_state.Member {
    return .{ .id = "hero", .name = "Hero", .hp = 17, .max_hp = 17, .status = .healthy, .rune_charges = @splat(0), .max_rune_charges = @splat(0) };
}

test "real village field controller links world entry, walking and source return without the old warning" {
    const data = try content();
    defer data.deinit();
    const package = try field.load(allocator, @embedFile("fixtures/journey_room.json"));
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    var initial_progress: field.game_state.Progress = .{ .money = 1500, .party = &members };
    const initial = field.State.init(package.value, &initial_progress);
    var session = try @import("world_field").Session.open(allocator, data.value, package.value, initial, .north);
    defer session.deinit();
    var draws: world.Draws = .{ .values = &.{} };
    _ = try session.tickWorld(.{ .direction = .north }, &draws, 1, false, false);
    const entry = try session.tickWorld(.{}, &draws, 1, false, false);
    try std.testing.expect(entry == .entrance);
    try std.testing.expectEqualStrings("vb6_village", session.package.rooms[session.field_state.room].id);
    try std.testing.expectEqual(@as(i32, 264), session.field_state.x);
    try std.testing.expectEqual(@as(i32, 344), session.field_state.y);
    var updates: usize = 0;
    while (!(try session.tickField(.{ .direction = .down }, &draws, false))) : (updates += 1) {
        try std.testing.expect(updates < 16);
    }
    try std.testing.expectEqual(@as(usize, 7), updates);
    try std.testing.expectEqual(.world, session.travel.mode);
    try std.testing.expectEqualDeep(data.value.return_camera, session.travel.camera);
    try std.testing.expect(session.field_state.dialogue == null);
    try std.testing.expect(session.field_state.progress.story.village_south_exit_reached);
    try std.testing.expectEqual(@as(u32, 1500), session.field_state.progress.money);
    try std.testing.expectEqual(@as(u16, 17), members[0].hp);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try std.testing.expectEqual(@as(usize, 2), package.value.rooms[session.village].events.len);
    try std.testing.expectEqual(@as(usize, 1), session.package.rooms[session.village].events.len);
}

test "field-to-world party and draw continuity survive a supplied battle result without healing or reseeding" {
    const data = try content();
    defer data.deinit();
    const package = try field.load(allocator, @embedFile("fixtures/journey_room.json"));
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    var initial_progress: field.game_state.Progress = .{ .money = 1500, .party = &members };
    const initial = field.State.init(package.value, &initial_progress);
    var session = try @import("world_field").Session.open(allocator, data.value, package.value, initial, .south);
    defer session.deinit();
    var draws: world.Draws = .{ .values = &.{ 0, 4095, 255, 8 } };
    for (0..5) |_| {
        for (0..16) |_| _ = try session.tickWorld(.{ .direction = .south }, &draws, 1, false, false);
    }
    const packet = try session.tickWorld(.{}, &draws, 1, false, false);
    try std.testing.expectEqualStrings("world_b_encounter_2", packet.battle.id);
    members[0].hp = 16;
    members[0].status = .poisoned;
    try session.finishBattle(.fled, session.field_state.progress.*);
    for (0..16) |_| _ = try session.tickWorld(.{ .direction = .south }, &draws, 1, false, false);
    try std.testing.expectEqual(@as(u16, 13), members[0].hp);
    try std.testing.expectEqual(@as(u32, 1500), session.field_state.progress.money);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
}

const battle = @import("battle");
const world_battle = @import("world_battle");
const field = @import("field");
const world_field = @import("world_field");

test "C region accepts every supported actor overlay schema" {
    const map = try world.load(allocator, world.json_c);
    defer map.deinit();
    const art = try world_view.load(allocator, world_view.json_c);
    defer art.deinit();
    const source = try world_battle.load(allocator, @embedFile("fixtures/world_c_actor_library.json"));
    defer source.deinit();
    var region: @import("world_travel").Region = .{ .map = map.value, .art = art.value, .battles = source.value };
    for ([_][]const u8{ "suikoden-world-battle/28", "suikoden-world-battle/29", "suikoden-world-battle/30", "suikoden-world-battle/31" }) |schema| {
        region.battles.?.schema = schema;
        try region.validate();
    }
    for ([_][]const u8{ "suikoden-world-battle/27", "suikoden-world-battle/32" }) |schema| {
        region.battles.?.schema = schema;
        try std.testing.expectError(error.WorldRegionMismatch, region.validate());
    }
    const other_map = try world.load(allocator, world.json);
    defer other_map.deinit();
    const other_art = try world_view.load(allocator, world_view.json);
    defer other_art.deinit();
    region.map = other_map.value;
    region.art = other_art.value;
    region.battles.?.schema = source.value.schema;
    region.battles.?.presentation = null;
    try std.testing.expectError(error.WorldRegionMismatch, region.validate());
}

test "C actor world binding preserves legacy identities and rejects missing or mismatched art" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    const legacy = try std.json.Stringify.valueAlloc(allocator, fixture.overlay.value, .{});
    defer allocator.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "\"actor_content\"") == null);
    const map = try world.load(allocator, world.json_c);
    defer map.deinit();
    const data = try world_battle.load(allocator, world_battle.json_c);
    defer data.deinit();
    const complete = try world_battle.load(allocator, @embedFile("fixtures/world_c_actor_library.json"));
    defer complete.deinit();
    const source = complete.value.actor_content.?;
    var overlay = data.value;
    const view = try overlay.view(map.value, fixture.base.value);
    var stale = overlay;
    stale.unsupported_enemies = &.{ "kobold_type_3", "strong_arm" };
    try std.testing.expectError(error.InvalidWorldBattleData, stale.view(map.value, fixture.base.value));
    try std.testing.expect(!overlay.supports(view.encounters[1]));
    var members: [6]battle.Member = undefined;
    const combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 1);
    try std.testing.expectError(error.MissingSourceActorPresentation, overlay.bindPresentation(allocator, view, 1, combat.progress.party, combat.formation));
    overlay.actor_content = source;
    try std.testing.expectError(error.InvalidWorldBattleData, overlay.bindPresentation(allocator, view, 1, combat.progress.party, combat.formation));
    overlay.schema = complete.value.schema;
    try std.testing.expect(overlay.supports(view.encounters[1]));
    const bound = try overlay.bindPresentation(allocator, view, 1, combat.progress.party, combat.formation);
    try std.testing.expect(bound.content.presentation_ready and bound.content.world_art == null);
    try std.testing.expectEqualStrings("world_c_encounter_2", bound.content.encounters[bound.encounter].id);
    try std.testing.expectEqual(@as(usize, 3), bound.content.encounters[bound.encounter].enemies.len);
    try std.testing.expect(!overlay.supports(view.encounters[0]));
    overlay.presentation = complete.value.presentation.?;
    try std.testing.expect(overlay.supports(view.encounters[0]));
    const existing = try overlay.bindPresentation(allocator, view, 0, combat.progress.party, combat.formation);
    try std.testing.expect(existing.content.world_art != null and existing.content.presentation_ready);
    try std.testing.expectEqualDeep(source.ground, existing.content.ground);
    var profiles = try allocator.dupe(battle.Profile, source.party);
    defer allocator.free(profiles);
    overlay.actor_content.?.party = profiles;
    profiles[0].stats.attack += 1;
    try std.testing.expectError(error.WorldPartyArtMismatch, overlay.bindPresentation(allocator, view, 1, combat.progress.party, combat.formation));
    profiles[0] = source.party[0];
    var enemies = try allocator.dupe(battle.Profile, source.enemies);
    defer allocator.free(enemies);
    overlay.actor_content.?.enemies = enemies;
    enemies[0].stats.attack += 1;
    try std.testing.expectError(error.InvalidWorldBattleData, overlay.bindPresentation(allocator, view, 1, combat.progress.party, combat.formation));
    try std.testing.expect(overlay.supports(view.encounters[2]));
}

test "C actor world transactions run source melee cover Parry and counters through round and return boundaries" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    const map = try world.load(allocator, world.json_c);
    defer map.deinit();
    const data = try world_battle.load(allocator, @embedFile("fixtures/world_c_actor_library.json"));
    defer data.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const spells = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer spells.deinit();
    const overlay = data.value;
    for (0..4) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 1234);
        for (combat.progress.party) |*member| {
            member.max_hp = 5000;
            member.hp = 5000;
        }
        combat.progress.money = 1500;
        const initial_charges = combat.progress.party[0].rune_charges;
        var session_progress = combat.progress;
        var session = try world_field.Session.open(allocator, map.value, fixture.rooms.value, field.State.init(fixture.rooms.value, &session_progress), .south);
        defer session.deinit();
        session.travel.mode = .battle;
        session.travel.selected = map.value.encounters[1].id;
        var values: [256]u15 = @splat(99);
        var draws: world.Draws = .{ .values = &values };
        var adapter: world_battle.Adapter = .{};
        defer adapter.deinit(allocator);
        var receipt: u64 = 0;
        const before = combat;
        try std.testing.expectError(error.MissingWorldActorLibrary, adapter.beginTransactional(&session, &combat, overlay, draws, receipt));
        try std.testing.expectEqualDeep(before, combat);
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&spells.value);
        try adapter.beginTransactional(&session, &combat, overlay, draws, receipt);
        try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
        for (0..3) |enemy| try std.testing.expectEqual(enemy, combat.enemySourceSlot(enemy));
        if (scenario < 2) {
            _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
            for (0..combat.partyCount()) |member| {
                if (combat.phase != .command or combat.actor != member) std.debug.print("C commands scenario={d} expected_member={d} actor={d} phase={s}\n", .{ scenario, member, combat.actor, @tagName(combat.phase) });
                try std.testing.expect(combat.phase == .command and combat.actor == member);
                if (scenario == 1 and member == 0) {
                    _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
                    _ = try adapter.tickTransactional(&session, &combat, .{ .down = true }, &draws, &receipt);
                    _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
                } else {
                    if (combat.picker.selected != .defend) _ = try adapter.tickTransactional(&session, &combat, .{ .down = true }, &draws, &receipt);
                    _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
                }
            }
            try std.testing.expect(combat.phase == .confirm_round);
            _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
        } else {
            // Retained legal later-round checkpoints isolate lethal Counter and low-HP cover.
            const retained = &adapter.transaction.?.session.state;
            retained.phase = .resolving;
            retained.actions = @splat(.defend);
            retained.acted = @splat(true);
            if (scenario == 2) {
                retained.enemy_hp[0] = 0;
                retained.enemy_hp[1] = 1;
                retained.enemy_hp[2] = 0;
                retained.acted[retained.partyCount() + 1] = false;
            } else {
                retained.progress.party[0].hp = 1;
                retained.acted[retained.partyCount()] = false;
                values[0] = 0;
                values[1] = 99;
                values[2] = 0;
                values[3] = 24;
            }
            combat = retained.*;
        }
        var saw_parry = false;
        var saw_counter = false;
        var saw_melee = false;
        var saw_cover = false;
        var contact_rollback = false;
        for (0..1600) |_| {
            if (!contact_rollback) for (combat.unite_vm.counter_actions) |maybe| if (maybe) |action| {
                if (action.action == null) continue;
                const ready = if (action.kind == .cover) action.action.?.stage == .approach and combat.unite_vm.actors[action.attacker].signals & 2 != 0 else action.action.?.stage == .strike and combat.unite_vm.actors[action.defender].signals & 2 != 0;
                if (!ready) continue;
                const saved = combat;
                var saved_members: [6]battle.Member = undefined;
                @memcpy(&saved_members, combat.progress.party);
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomStreamMismatch, adapter.tickTransactional(&session, &combat, .{}, &draws, &receipt));
                // Retained checkpoint with the same exhausted finite stream on both sides of the owner boundary.
                adapter.transaction.?.session.draws.values = draws.values;
                try std.testing.expectError(error.RandomInputExhausted, adapter.tickTransactional(&session, &combat, .{}, &draws, &receipt));
                try std.testing.expectEqualDeep(saved, combat);
                try std.testing.expectEqualDeep(saved_members, combat.progress.party[0..6].*);
                try std.testing.expectEqual(cursor, draws.cursor);
                try std.testing.expectEqual(@as(u64, 0), receipt);
                draws.values = &values;
                adapter.transaction.?.session.draws.values = &values;
                contact_rollback = true;
            };
            _ = try adapter.tickTransactional(&session, &combat, .{}, &draws, &receipt);
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |action| switch (action.kind) {
                .parry => saw_parry = true,
                .counter => saw_counter = true,
                .ordinary_hit, .ordinary_miss, .ranged_hit, .ranged_miss, .melee_hit, .melee_miss => saw_melee = true,
                .cover => saw_cover = true,
                .special => return error.UnexpectedAntSpecial,
                .ordered => return error.UnexpectedCommanderOrder,
                .projectile => return error.UnexpectedRabbitProjectile,
            };
            if (combat.phase != .resolving) break;
        }
        try std.testing.expectEqualDeep(initial_charges, combat.progress.party[0].rune_charges);
        try std.testing.expect(contact_rollback);
        try std.testing.expect(!combat.unite_vm.hasActors());
        if (scenario != 2) {
            try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
            if (scenario == 0) try std.testing.expect(saw_counter and saw_melee and !saw_parry) else if (scenario == 1) try std.testing.expect(saw_parry) else {
                try std.testing.expect(saw_cover);
                try std.testing.expectEqual(@as(u16, 1), combat.hp(0));
                try std.testing.expect(combat.hp(1) < 5000);
            }
            _ = try adapter.tickTransactional(&session, &combat, .{ .down = true }, &draws, &receipt);
            _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
            for (0..100) |_| {
                if (combat.phase == .escaped) break;
                _ = try adapter.tickTransactional(&session, &combat, .{}, &draws, &receipt);
            }
            try std.testing.expect(combat.phase == .escaped and !combat.released_enemies);
        } else {
            try std.testing.expect(saw_counter and combat.phase == .victory);
            for (0..700) |_| {
                if (combat.rewardReady()) break;
                _ = try adapter.tickTransactional(&session, &combat, .{}, &draws, &receipt);
            }
            try std.testing.expect(combat.rewardReady());
        }
        const remaining_hp = combat.hp(0);
        const cursor = draws.cursor;
        const result = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
        try std.testing.expect(result == .returned and receipt == 1 and session.travel.mode == .world);
        try std.testing.expectEqual(remaining_hp, members[0].hp);
        try std.testing.expectEqualDeep(initial_charges, members[0].rune_charges);
        try std.testing.expectEqual(cursor, draws.cursor);
        try std.testing.expectEqualDeep(fixture.base.value, combat.content);
    }
}

test "C archer knockout and Buddha survive the world battle transaction" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    const map = try world.load(allocator, world.json_c);
    defer map.deinit();
    const data = try world_battle.load(allocator, @embedFile("fixtures/world_c_actor_library.json"));
    defer data.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const spells = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer spells.deinit();
    for ([_]bool{ false, true }) |buddha| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 17);
        for (combat.progress.party, 0..) |*member, index| {
            member.max_hp = 100;
            member.hp = if (index == 1) 50 else 100;
            member.inventory.slots = @splat(null);
        }
        if (buddha) members[1].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&spells.value);
        var session_progress = combat.progress;
        var session = try world_field.Session.open(allocator, map.value, fixture.rooms.value, field.State.init(fixture.rooms.value, &session_progress), .south);
        defer session.deinit();
        session.travel.mode = .battle;
        session.travel.selected = map.value.encounters[3].id;
        var values: [2048]u15 = @splat(51);
        values[0] = 0;
        var draws = world.Draws{ .values = &values };
        var adapter: world_battle.Adapter = .{};
        defer adapter.deinit(allocator);
        var receipt: u64 = 0;
        try adapter.beginTransactional(&session, &combat, data.value, draws, receipt);
        const retained = &adapter.transaction.?.session.state;
        for (retained.progress.party, 0..) |_, index| {
            retained.base_stats[index].defense = 40;
            retained.base_stats[index].skill = 0;
        }
        const owner = retained.partyCount();
        try std.testing.expectEqualStrings("kobold_type_2", retained.enemy(0).id);
        retained.phase = .resolving;
        retained.actions = @splat(.defend);
        retained.acted = @splat(true);
        retained.acted[owner] = false;
        retained.coordinator = .{ .stage = .dispatch, .current_actor = owner, .cached = .{ .actor = owner } };
        combat = retained.*;
        for (0..1000) |_| {
            if (combat.phase != .resolving) break;
            _ = try adapter.tickTransactional(&session, &combat, .{}, &draws, &receipt);
        }
        try std.testing.expect(combat.phase == .battle_menu);
        try std.testing.expectEqual(@as(u16, if (buddha) 50 else 0), combat.hp(1));
        try std.testing.expectEqual(if (buddha) battle.Row.front else battle.Row.back, combat.partyRow(1));
        _ = try adapter.tickTransactional(&session, &combat, .{ .down = true }, &draws, &receipt);
        _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
        for (0..100) |_| {
            if (combat.phase == .escaped) break;
            _ = try adapter.tickTransactional(&session, &combat, .{}, &draws, &receipt);
        }
        try std.testing.expect(combat.phase == .escaped);
        try std.testing.expect(try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt) == .returned);
        try std.testing.expectEqual(@as(u64, 1), receipt);
        try std.testing.expectEqual(@as(u16, if (buddha) 50 else 0), members[1].hp);
        try std.testing.expectEqual(if (buddha) field.game_state.Status.healthy else field.game_state.Status.unconscious, members[1].status);
        try std.testing.expectEqual(if (buddha) battle.Row.front else battle.Row.back, combat.partyRow(1));
        try std.testing.expectEqual(if (buddha) battle.Row.back else battle.Row.front, combat.partyRow(3));
        if (buddha) try std.testing.expectEqual(@as(usize, 0), members[1].inventory.count());
    }
}

test "C actor world transactions retain source archers mages and Strong Arm through two command rounds" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    const map = try world.load(allocator, world.json_c);
    defer map.deinit();
    const data = try world_battle.load(allocator, @embedFile("fixtures/world_c_actor_library.json"));
    defer data.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const legacy = try battle.actor_host.loadBundle(allocator, @embedFile("fixtures/enemy_magic_actor_library.json"));
    defer legacy.deinit();
    const spells = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer spells.deinit();
    const values = try allocator.alloc(u15, 16384);
    defer allocator.free(values);
    @memset(values, 32767);
    for ([_]usize{ 2, 3, 4, 5, 6, 7 }) |encounter| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 1234);
        for (combat.progress.party) |*member| {
            member.max_hp = 5000;
            member.hp = 5000;
        }
        const charges = members[0].rune_charges;
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&spells.value);
        var session_progress = combat.progress;
        var session = try world_field.Session.open(allocator, map.value, fixture.rooms.value, field.State.init(fixture.rooms.value, &session_progress), .south);
        defer session.deinit();
        session.travel.mode = .battle;
        session.travel.selected = map.value.encounters[encounter].id;
        var draws = world.Draws{ .values = values };
        var adapter: world_battle.Adapter = .{};
        defer adapter.deinit(allocator);
        var receipt: u64 = 0;
        if (encounter == 3 or encounter == 7) {
            combat.unite_actors = &legacy.value;
            const before = combat;
            try std.testing.expectError(error.MissingWorldActorLibrary, adapter.beginTransactional(&session, &combat, data.value, draws, receipt));
            try std.testing.expectEqualDeep(before, combat);
            try std.testing.expect(adapter.transaction == null);
            combat.unite_actors = &actors.value;
        }
        try adapter.beginTransactional(&session, &combat, data.value, draws, receipt);
        var expected: u16 = 0;
        var expected_archers: u16 = 0;
        for (0..combat.enemyCount()) |enemy| if (std.mem.eql(u8, combat.enemy(enemy).id, "kobold_type_3")) {
            expected |= @as(u16, 1) << @intCast(combat.partyCount() + enemy);
        };
        for (0..combat.enemyCount()) |enemy| if (std.mem.eql(u8, combat.enemy(enemy).id, "kobold_type_2")) {
            expected_archers |= @as(u16, 1) << @intCast(combat.partyCount() + enemy);
        };
        try std.testing.expect(@popCount(expected) == (if (encounter < 5) @as(u8, 1) else 2));
        for (0..2) |_| {
            _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
            for (0..combat.partyCount()) |member| {
                try std.testing.expect(combat.phase == .command and combat.actor == member);
                if (combat.picker.selected != .defend) _ = try adapter.tickTransactional(&session, &combat, .{ .down = true }, &draws, &receipt);
                _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
            }
            try std.testing.expect(combat.phase == .confirm_round);
            _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
            var seen: u16 = 0;
            var seen_archers: u16 = 0;
            var seen_strong_arm = false;
            for (0..5000) |_| {
                if (combat.phase != .resolving) break;
                _ = try adapter.tickTransactional(&session, &combat, .{}, &draws, &receipt);
                for (combat.unite_vm.enemy_magic_actions, 0..) |action, owner| if (action != null) {
                    seen |= @as(u16, 1) << @intCast(owner);
                };
                for (combat.unite_vm.counter_actions) |action| if (action) |playback| {
                    if (std.mem.eql(u8, combat.enemy(playback.attacker - combat.partyCount()).id, "strong_arm")) seen_strong_arm = true;
                    if (std.mem.eql(u8, combat.enemy(playback.attacker - combat.partyCount()).id, "kobold_type_2")) seen_archers |= @as(u16, 1) << @intCast(playback.attacker);
                };
            }
            try std.testing.expectEqual(expected, seen);
            try std.testing.expectEqual(expected_archers, seen_archers);
            try std.testing.expectEqual(encounter == 4 or encounter == 7, seen_strong_arm);
            try std.testing.expect(combat.phase == .battle_menu and !combat.unite_vm.hasActors() and combat.active == null);
            try std.testing.expectEqualDeep(charges, combat.progress.party[0].rune_charges);
            try std.testing.expect(receipt == 0 and session.travel.mode == .battle and adapter.transaction != null);
        }
        try std.testing.expect(combat.hp(0) > 0 and combat.hp(0) < 5000 and draws.cursor > 0);
        if (encounter == 3 or encounter == 4 or encounter == 6 or encounter == 7) {
            var remaining: [6]u16 = undefined;
            for (combat.progress.party, 0..) |member, index| remaining[index] = member.hp;
            _ = try adapter.tickTransactional(&session, &combat, .{ .down = true }, &draws, &receipt);
            _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
            for (0..100) |_| {
                if (combat.phase == .escaped) break;
                _ = try adapter.tickTransactional(&session, &combat, .{}, &draws, &receipt);
            }
            try std.testing.expect(combat.phase == .escaped);
            const cursor = draws.cursor;
            try std.testing.expect(try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt) == .returned);
            try std.testing.expect(receipt == 1 and session.travel.mode == .world);
            for (members, remaining) |member, hp| try std.testing.expectEqual(hp, member.hp);
            try std.testing.expectEqualDeep(charges, members[0].rune_charges);
            try std.testing.expectEqual(cursor, draws.cursor);
        }
    }
}

const CombatFixture = struct {
    map: std.json.Parsed(world.Content),
    overlay: std.json.Parsed(world_battle.Data),
    base: std.json.Parsed(battle.Content),
    rooms: std.json.Parsed(field.Package),
    items: std.json.Parsed(field.items.Rules),
    fn open() !CombatFixture {
        const map = try content();
        errdefer map.deinit();
        const overlay = try world_battle.load(allocator, world_battle.json);
        errdefer overlay.deinit();
        const base = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
        errdefer base.deinit();
        const rooms = try field.load(allocator, @embedFile("fixtures/journey_room.json"));
        errdefer rooms.deinit();
        const items = try field.items.load(allocator, field.items.json);
        return .{ .map = map, .overlay = overlay, .base = base, .rooms = rooms, .items = items };
    }
    fn deinit(self: CombatFixture) void {
        self.map.deinit();
        self.overlay.deinit();
        self.base.deinit();
        self.rooms.deinit();
        self.items.deinit();
    }
};
fn armBattle(session: *world_field.Session, draws: *world.Draws) !void {
    for (0..5) |_| {
        for (0..16) |_| _ = try session.tickWorld(.{ .direction = .south }, draws, 30, false, false);
    }
    const handoff = try session.tickWorld(.{}, draws, 30, false, false);
    try std.testing.expectEqualStrings("world_b_encounter_2", handoff.battle.id);
}

test "world battle entry carries live roster rune pieces with identity and rollback checks" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    const art = try world_view.load(allocator, world_view.json);
    defer art.deinit();
    for ([_]bool{ false, true }) |transactional| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 1234);
        combat.base_stats[0].attack = 500;
        const field_state = field.State.init(fixture.rooms.value, &combat.progress);
        var state = try @import("world_travel").State.open(allocator, fixture.map.value, art.value, fixture.overlay.value, fixture.rooms.value, &combat, field_state);
        defer state.deinit();
        const progress = state.link.field_state.progress;
        const bits = progress.money;
        const count = progress.party[0].inventory.count();
        const medicine = fixture.items.value.medicine;
        try progress.buyItem(fixture.items.value, .medicine, 0);
        try std.testing.expectEqual(bits - medicine.price, state.progress().money);
        try std.testing.expectEqual(.medicine, state.combat.progress.party[0].inventory.slots[count].?.id);
        state.party_transactions = transactional;
        state.link.travel.mode = .battle_pending;
        state.link.travel.selected = fixture.map.value.encounters[1].id;
        var values: [256]u15 = @splat(255);
        var draws: world.Draws = .{ .values = &values };
        if (transactional) {
            try std.testing.expectError(error.UnsupportedCombatSidecar, state.advance(.{}, &draws));
            try std.testing.expectEqual(.battle_pending, state.link.travel.mode);
            try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        }
        const party = @import("party_session");
        var roster: party.Snapshot = .{ .entry_id = "world", .content_id = "world", .receipt = "1", .baseline_revision = 0 };
        for (0..combat.partyCount()) |i| {
            roster.members[i] = combat.ownedMember(i);
            roster.extras[i] = .{ .member_id = members[i].id };
            roster.active[i] = members[i].id;
            roster.eligible[i] = true;
        }
        std.mem.swap(?battle.OwnedMember, &roster.members[0], &roster.members[5]);
        std.mem.swap(?party.CharacterExtra, &roster.extras[0], &roster.extras[5]);
        roster.extras[5].?.weapon_element = .fire;
        roster.extras[5].?.weapon_fragments[0] = 3;
        try state.attachPartySnapshot(&roster);
        const saved_id = roster.extras[5].?.member_id;
        roster.extras[5].?.member_id = "wrong_member";
        try std.testing.expectError(error.InvalidCharacterExtra, state.advance(.{}, &draws));
        try std.testing.expectEqual(.battle_pending, state.link.travel.mode);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        try std.testing.expect(state.adapter.transaction == null and state.adapter.original == null);
        roster.extras[5].?.member_id = saved_id;
        std.mem.swap(?[]const u8, &roster.active[0], &roster.active[1]);
        try std.testing.expectError(error.WorldPartyMismatch, state.advance(.{}, &draws));
        try std.testing.expectEqual(.battle_pending, state.link.travel.mode);
        std.mem.swap(?[]const u8, &roster.active[0], &roster.active[1]);
        roster.extras[5].?.weapon_fragments[0] = 4;
        try std.testing.expect((try state.advance(.{}, &draws)) == .battle_started);
        try std.testing.expectEqual(battle.systems.WeaponRune.fire, state.combat.weapon_augments[0].rune);
        try std.testing.expectEqual(@as(u8, 4), state.combat.weapon_augments[0].fragments);
        var neutral = state.combat.*;
        neutral.weapon_augments[0] = .{};
        try std.testing.expect(state.combat.resolvePhysicalDamage(0, state.combat.partyCount(), 0, false) > neutral.resolvePhysicalDamage(0, neutral.partyCount(), 0, false));
        try std.testing.expectError(error.WorldBattleNotReady, state.attachPartySnapshot(&roster));
        _ = try state.advance(.{ .combat = .{ .down = true } }, &draws);
        _ = try state.advance(.{ .combat = .{ .confirm = true } }, &draws);
        for (0..200) |_| {
            if (state.combat.phase == .escaped) break;
            _ = try state.advance(.{}, &draws);
        }
        try std.testing.expectEqual(battle.Phase.escaped, state.combat.phase);
        try std.testing.expect((try state.advance(.{ .combat = .{ .confirm = true } }, &draws)) == .battle_returned);
        try std.testing.expect(state.link.field_state.progress == progress);
        try std.testing.expect(state.progress() == progress);
        try std.testing.expectEqual(.medicine, progress.party[0].inventory.slots[count].?.id);
        roster.extras[5].?.weapon_element = .wind;
        roster.extras[5].?.weapon_fragments = .{ 0, 0, 5, 0, 0 };
        state.link.travel.mode = .battle_pending;
        state.link.travel.selected = fixture.map.value.encounters[1].id;
        try std.testing.expect((try state.advance(.{}, &draws)) == .battle_started);
        try std.testing.expectEqual(battle.systems.WeaponRune.wind, state.combat.weapon_augments[0].rune);
        try std.testing.expectEqual(@as(u8, 5), state.combat.weapon_augments[0].fragments);
    }
}

test "Dodge world schema requires owner signals and defender motion while legacy content remains readable" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    var data = fixture.overlay.value;
    const timings = try allocator.dupe(battle.PartyAttackTiming, data.party_attacks);
    defer allocator.free(timings);
    data.party_attacks = timings;
    const original = timings[0];
    timings[0].dodge_start_tick = null;
    try std.testing.expectError(error.MissingPartyDodgeTiming, data.view(fixture.map.value, fixture.base.value));
    data.schema = "suikoden-world-battle/23";
    _ = try data.view(fixture.map.value, fixture.base.value);
    data.schema = "suikoden-world-battle/25";
    timings[0] = original;
    const enemies = try allocator.dupe(battle.Profile, data.enemies);
    defer allocator.free(enemies);
    data.enemies = enemies;
    enemies[0].dodge = null;
    try std.testing.expectError(error.MissingWorldDodge, data.view(fixture.map.value, fixture.base.value));
    data.schema = "suikoden-world-battle/23";
    _ = try data.view(fixture.map.value, fixture.base.value);
}

test "B battle overlay preserves source holes, stats and unsupported policies and cannot render with A assets" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    try std.testing.expectError(error.UnsupportedWorldBattleSchema, world_battle.load(allocator, "{\"schema\":\"suikoden-world-battle/6\"}"));
    try std.testing.expectError(error.UnsupportedWorldBattleSchema, world_battle.load(allocator, "{\"schema\":\"suikoden-world-battle/100\",\"enemies\":[{\"action_policy\":\"future\"}]}"));
    const view = try fixture.overlay.value.view(fixture.map.value, fixture.base.value);
    try std.testing.expectEqual(@as(usize, 4), view.enemies.len);
    const squirrel = view.enemies[view.enemyIndex("flying_squirrel").?];
    try std.testing.expectEqual(@as(u16, 90), squirrel.max_hp);
    try std.testing.expectEqual(@as(u16, 99), squirrel.stats.attack);
    try std.testing.expectEqualStrings("holy_crystal", @tagName(squirrel.drops.?[0].item.?));
    try std.testing.expectEqualStrings("Peeing Boy", view.enemies[view.enemyIndex("killer_rabbit").?].drops.?[2].item.?.name());
    try std.testing.expectEqualStrings("Phero crystal", view.enemies[view.enemyIndex("beast_commander").?].drops.?[1].item.?.name());
    try std.testing.expectEqualSlices(u8, &.{ 0, 2 }, view.encounters[1].source_slots.?);
    try std.testing.expectEqual(@as(f32, -50), view.encounters[1].positions[1].y);
    try std.testing.expect(fixture.overlay.value.supports(view.encounters[1]));
    try std.testing.expect(!fixture.overlay.value.supports(view.encounters[0]));
    for (view.encounters, [_]bool{ false, true, true, true, false, true, false, false }) |entry, supported| try std.testing.expectEqual(supported, fixture.overlay.value.supports(entry));
    try std.testing.expectError(error.SimulationOnlyBattleContent, view.validateAtlas(4096, 4096));
    var bad = fixture.overlay.value;
    bad.unsupported_enemies = &.{};
    try std.testing.expectError(error.InvalidWorldBattleData, bad.view(fixture.map.value, fixture.base.value));
}

test "all eight B rosters allow verified Run and Let go without executing unsupported enemy actions" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    for (0..8) |index| for ([_]bool{ false, true }) |release| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 1234);
        combat.levels = @splat(if (release) 99 else 1);
        members[0].hp -= 7;
        const original = members;
        var session_progress = combat.progress;
        var session = try world_field.Session.open(allocator, fixture.map.value, fixture.rooms.value, field.State.init(fixture.rooms.value, &session_progress), .south);
        defer session.deinit();
        session.travel.mode = .battle;
        session.travel.selected = fixture.map.value.encounters[index].id;
        const camera = session.travel.camera;
        var adapter: world_battle.Adapter = .{};
        try adapter.begin(&session, &combat, fixture.overlay.value);
        try std.testing.expectEqual(index, combat.encounter);
        try std.testing.expectEqual(fixture.overlay.value.encounters[index].enemies.len, combat.enemyCount());
        if (index == 3) try std.testing.expectEqual(@as(usize, 1), combat.enemySourceSlot(0));
        var draws: world.Draws = .{ .values = &.{255} };
        _ = try adapter.tick(&session, &combat, .{ .down = true }, &draws);
        _ = try adapter.tick(&session, &combat, .{ .confirm = true }, &draws);
        for (0..200) |_| {
            if (combat.phase == .escaped) break;
            _ = try adapter.tick(&session, &combat, .{}, &draws);
        }
        try std.testing.expectEqual(.escaped, combat.phase);
        try std.testing.expectEqual(release, combat.released_enemies);
        try std.testing.expect((try adapter.tick(&session, &combat, .{ .confirm = true }, &draws)) == .returned);
        try std.testing.expectEqualDeep(camera, session.travel.camera);
        try std.testing.expectEqualDeep(original, members);
        try std.testing.expectEqual(@as(usize, if (release) 0 else 1), draws.cursor);
    };
}

test "world encounter runs actual combat and rewards then resumes without reseeding, healing or chaining demos" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 1234);
    combat.progress.money = 1500;
    members[0].hp -= 7;
    const hp = members[0].hp;
    const inventory = members[0].inventory;
    var session_progress = combat.progress;
    var session = try world_field.Session.open(allocator, fixture.map.value, fixture.rooms.value, field.State.init(fixture.rooms.value, &session_progress), .south);
    defer session.deinit();
    var values: [4096]u15 = @splat(255);
    values[0] = 0;
    values[1] = 4095;
    var draws: world.Draws = .{ .values = &values };
    try armBattle(&session, &draws);
    const camera = session.travel.camera;
    const random = combat.random;
    var adapter: world_battle.Adapter = .{};
    try adapter.begin(&session, &combat, fixture.overlay.value);
    try std.testing.expectEqual(@as(u16, hp), members[0].hp);
    try std.testing.expectEqual(@as(u32, 1500), combat.progress.money);
    try std.testing.expectEqual(@as(usize, 2), combat.enemyCount());
    try std.testing.expectEqual(@as(usize, 2), combat.enemySourceSlot(1));
    try std.testing.expectEqualStrings("Flying Squirrel", combat.enemy(1).name);
    var reward_rollback_checked = false;
    for (0..10000) |_| {
        if (combat.phase == .victory) break;
        if (!reward_rollback_checked and combat.active != null and combat.enemy_hp[0] == 0 and combat.enemy_hp[1] == 0 and combat.action_ticks + 1 >= combat.actionDuration()) {
            const before_reward = combat;
            const before_members = members;
            const old_cursor = draws.cursor;
            draws.values = values[0..old_cursor];
            try std.testing.expectError(error.RandomInputExhausted, adapter.tick(&session, &combat, .{}, &draws));
            try std.testing.expectEqualDeep(before_reward, combat);
            try std.testing.expectEqualDeep(before_members, members);
            try std.testing.expectEqual(old_cursor, draws.cursor);
            draws.values = &values;
            @memset(values[old_cursor..], 0);
            reward_rollback_checked = true;
        }
        if (combat.phase == .command) {
            const target: usize = if (combat.enemy_hp[1] != 0 and combat.canAttackTarget(combat.actor, 1)) 1 else 0;
            if (combat.canAttackTarget(combat.actor, target)) combat.queue(.{ .attack = target }) else combat.queue(.defend);
        } else _ = try adapter.tick(&session, &combat, .{ .confirm = combat.phase == .battle_menu or combat.phase == .confirm_round }, &draws);
    }
    try std.testing.expectEqual(.victory, combat.phase);
    try std.testing.expect(reward_rollback_checked);
    try std.testing.expectEqual(@as(u32, 200), combat.reward_money);
    try std.testing.expectEqual(@as(u32, 1700), combat.progress.money);
    var living: usize = 0;
    for (members, 0..) |member, index| {
        if (member.hp > 0) {
            living += 1;
            try std.testing.expect(combat.award_exp[index] > 0);
        } else try std.testing.expectEqual(@as(u32, 0), combat.award_exp[index]);
    }
    try std.testing.expect(living > 0);
    var rewarded_inventory = inventory;
    rewarded_inventory.slots[rewarded_inventory.count()] = .{ .id = .holy_crystal, .uses = 0 };
    try std.testing.expectEqualDeep(rewarded_inventory, members[0].inventory);
    try std.testing.expect(combat.drop_received);
    const final_hp = members[0].hp;
    const cursor = draws.cursor;
    try std.testing.expectEqual(.returned, try adapter.tick(&session, &combat, .{ .confirm = true }, &draws));
    try std.testing.expectEqualDeep(camera, session.travel.camera);
    try std.testing.expectEqual(@as(u16, final_hp), session.field_state.progress.party[0].hp);
    try std.testing.expectEqual(@as(u32, 1700), session.field_state.progress.money);
    try std.testing.expectEqual(cursor, draws.cursor);
    try std.testing.expect(cursor > 2);
    try std.testing.expectEqualDeep(random, combat.random);
    try std.testing.expectEqualStrings("bonbon", combat.content.enemies[0].id);
    try std.testing.expectEqual(.world, session.travel.mode);
    try std.testing.expectError(error.WorldBattleNotReady, adapter.tick(&session, &combat, .{ .confirm = true }, &draws));
    try std.testing.expectEqual(@as(u32, 1700), session.field_state.progress.money);
}

test "world battle replay exhaustion preserves owned state and cursors" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 1234);
    var session_progress = combat.progress;
    var session = try world_field.Session.open(allocator, fixture.map.value, fixture.rooms.value, field.State.init(fixture.rooms.value, &session_progress), .south);
    defer session.deinit();
    var draws: world.Draws = .{ .values = &.{ 0, 4095 } };
    try armBattle(&session, &draws);
    var adapter: world_battle.Adapter = .{};
    const before_members = members;
    session.travel.selected = "world_b_encounter_2";
    try adapter.begin(&session, &combat, fixture.overlay.value);
    _ = try adapter.tick(&session, &combat, .{ .confirm = true }, &draws);
    for (0..6) |_| combat.queue(.defend);
    _ = try adapter.tick(&session, &combat, .{ .confirm = true }, &draws);
    const before = combat;
    try std.testing.expectError(error.RandomInputExhausted, adapter.tick(&session, &combat, .{}, &draws));
    try std.testing.expectEqualDeep(before, combat);
    try std.testing.expectEqualDeep(before_members, members);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
}

test "world battle Run and Let go resolve through combat while defeat never heals or restarts" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    for (0..3) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 1234);
        combat.progress.money = 1500;
        if (scenario == 1) combat.levels = @splat(20);
        if (scenario == 2) for (&members) |*member| {
            member.hp = 1;
        };
        var session_progress = combat.progress;
        var session = try world_field.Session.open(allocator, fixture.map.value, fixture.rooms.value, field.State.init(fixture.rooms.value, &session_progress), .south);
        defer session.deinit();
        var values: [4096]u15 = @splat(255);
        values[0] = 0;
        values[1] = 4095;
        var draws: world.Draws = .{ .values = &values };
        try armBattle(&session, &draws);
        const original_encounter = combat.encounter;
        const camera = session.travel.camera;
        var adapter: world_battle.Adapter = .{};
        try adapter.begin(&session, &combat, fixture.overlay.value);
        _ = try adapter.tick(&session, &combat, .{ .cancel = true }, &draws);
        try std.testing.expectEqual(.battle_menu, combat.phase);
        if (scenario < 2) {
            _ = try adapter.tick(&session, &combat, .{ .down = true }, &draws);
            _ = try adapter.tick(&session, &combat, .{ .confirm = true }, &draws);
            for (0..200) |_| {
                if (combat.phase == .escaped) break;
                _ = try adapter.tick(&session, &combat, .{}, &draws);
            }
            try std.testing.expectEqual(.escaped, combat.phase);
            try std.testing.expectEqual(scenario == 1, combat.released_enemies);
            try std.testing.expectEqual(@as(usize, if (scenario == 1) 2 else 3), draws.cursor);
            try std.testing.expectEqual(.returned, try adapter.tick(&session, &combat, .{ .confirm = true }, &draws));
            try std.testing.expectEqual(original_encounter, combat.encounter);
            try std.testing.expectEqualDeep(camera, session.travel.camera);
            try std.testing.expectEqual(@as(u32, 1500), session.field_state.progress.money);
            try std.testing.expectEqual(@as(u16, 0), session.travel.travel_counter);
        } else {
            for (0..10000) |_| {
                if (combat.phase == .defeat) break;
                if (combat.phase == .command) combat.queue(.defend) else _ = try adapter.tick(&session, &combat, .{ .confirm = combat.phase == .battle_menu or combat.phase == .confirm_round }, &draws);
            }
            try std.testing.expectEqual(.defeat, combat.phase);
            const before = members;
            const cursor = draws.cursor;
            try std.testing.expectEqual(.defeated, try adapter.tick(&session, &combat, .{ .confirm = true }, &draws));
            try std.testing.expectEqualDeep(before, members);
            try std.testing.expectEqual(cursor, draws.cursor);
            try std.testing.expectEqual(.battle, session.travel.mode);
            try std.testing.expectEqual(@as(u32, 1500), session.field_state.progress.money);
        }
    }
}

const world_view = @import("world_view");
test "world presentation schema validates terrain, exact world Hero poses and image bounds" {
    const data = try world_view.load(allocator, world_view.json);
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 36), data.value.poses.len);
    try data.value.validateAtlas(256, 368);
    try std.testing.expectError(error.InvalidWorldAtlas, data.value.validateAtlas(255, 368));
    var bad = data.value;
    bad.schema = "future";
    try std.testing.expectError(error.UnsupportedWorldArt, bad.validate());
    bad = data.value;
    bad.hero_y = 120;
    try std.testing.expectError(error.InvalidWorldArt, bad.validate());
    var cells: [19200]u16 = undefined;
    @memcpy(&cells, data.value.cells);
    cells[0] = 320;
    bad = data.value;
    bad.cells = &cells;
    try std.testing.expectError(error.InvalidWorldTile, bad.validate());
}

test "world viewport, idle and start-step double clock, visible water sweep and wrap match155 original frames" {
    const art = try world_view.load(allocator, world_view.json);
    defer art.deinit();
    const map = try content();
    defer map.deinit();
    const Step = struct { key: u16, camera: world.Point, origin: world.Point, heading: u2, remaining: u8, travel_counter: u16, clip: u8, frame: u8, ticks: u16, counter: u32, water: u16, cells_sha256: ?[]const u8, pixels_sha256: ?[]const u8 };
    const Case = struct { name: []const u8, x: i32, y: i32, counter: u32, speed: u8, steps: []const Step };
    const cases = try std.json.parseFromSlice([]const Case, allocator, @embedFile("fixtures/world_visual_steps.json"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        var travel: world.State = .{ .camera = .{ .x = case.x, .y = case.y }, .heading = .east, .encounters_enabled = false, .speed = if (case.speed == 2) .stallion else .normal };
        var visual = world_view.State.init(art.value);
        visual.counter = @bitCast(case.counter);
        var draws: world.Draws = .{ .values = &.{} };
        for (case.steps) |expected| {
            const input: world.Input = .{ .direction = switch (expected.key) {
                0 => null,
                0x1000 => .north,
                0x2000 => .east,
                0x4000 => .south,
                0x8000 => .west,
                else => unreachable,
            } };
            const before = travel;
            _ = try travel.tick(map.value, input, &draws, .{ .level_sum = 0 });
            try visual.step(art.value, before, travel, input);
            try std.testing.expectEqualDeep(expected.camera, travel.camera);
            try std.testing.expectEqualDeep(expected.origin, travel.originPixels());
            try std.testing.expectEqual(expected.heading, @backingInt(travel.heading));
            try std.testing.expectEqual(expected.remaining, travel.remaining);
            try std.testing.expectEqual(expected.travel_counter, travel.travel_counter);
            try std.testing.expectEqual(expected.clip, visual.clip);
            try std.testing.expectEqual(expected.frame, visual.frame);
            try std.testing.expectEqual(expected.ticks, visual.remaining);
            try std.testing.expectEqual(expected.counter, @as(u32, @bitCast(visual.counter)));
            try std.testing.expectEqual(expected.water, visual.water_tile);
            if (expected.cells_sha256) |hash| {
                var bytes: [38400]u8 = undefined;
                for (visual.cells, 0..) |cell, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], cell, .little);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
                try std.testing.expectEqualStrings(hash, &std.fmt.bytesToHex(digest, .lower));
            }
            var list: world_view.List = .{};
            try world_view.compose(art.value, travel, &visual, &list);
            try std.testing.expect(list.length >= 601 and list.length <= 673);
            try std.testing.expectEqual(@as(i32, 160), list.sprites[list.length - 1].x);
            try std.testing.expectEqual(@as(i32, 128), list.sprites[list.length - 1].y);
        }
    }
}

test "world composition draws repeating water first, clips fractional tiles and resets source reload state" {
    const art = try world_view.load(allocator, world_view.json);
    defer art.deinit();
    const map = try content();
    defer map.deinit();
    var visual = world_view.State.init(art.value);
    visual.counter = 29;
    visual.cells[0] = 1;
    visual.cells[1] = 0;
    visual.cells[2] = 11;
    const travel: world.State = .{ .camera = .{ .x = 0, .y = 0 }, .heading = .south };
    try visual.step(art.value, travel, travel, .{});
    try std.testing.expectEqual(@as(u16, 20), visual.water_tile);
    try std.testing.expectEqualSlices(u16, &.{ 11, 0, 1 }, visual.cells[0..3]);
    var list: world_view.List = .{};
    try world_view.compose(art.value, travel, &visual, &list);
    try std.testing.expectEqual(@as(usize, 601), list.length);
    try std.testing.expectEqualDeep(art.value.tiles[20], list.sprites[0].rect);
    try std.testing.expectEqualDeep(art.value.tiles[11], list.sprites[300].rect);
    var partial = travel;
    partial.remaining = 15;
    partial.heading = .east;
    try world_view.compose(art.value, partial, &visual, &list);
    try std.testing.expectEqual(@as(usize, 631), list.length);
    try std.testing.expectEqual(@as(i32, -1), list.sprites[0].x);
    visual.reload(art.value);
    try std.testing.expectEqual(@as(i32, 1), visual.counter);
    try std.testing.expectEqual(@as(u8, 0), visual.clip);
    try std.testing.expectEqual(@as(u16, 20), visual.water_tile);
    try std.testing.expectEqualSlices(u16, art.value.cells, &visual.cells);
    var returning: world.State = .{ .camera = .{ .x = 86, .y = 84 }, .heading = .north, .mode = .field, .pending_entrance = "vb6_village" };
    try returning.leaveField(map.value);
    try std.testing.expectEqual(.east, returning.heading);
    var boat_art = art.value;
    boat_art.schema = "suikoden-crossing-art/1";
    boat_art.anchors = &.{.{ .x = 0, .y = 0 }};
    const boat_clip: [4]world_view.Frame = @splat(.{ .pose = 0, .ticks = 9 });
    boat_art.clips = @splat(&boat_clip);
    var boat_visual = world_view.State.init(boat_art);
    var boat = travel;
    boat.camera = .{ .x = 100, .y = 75 };
    boat.boat = true;
    try boat_visual.step(boat_art, boat, boat, .{});
    try std.testing.expectEqual(@as(u16, 8), boat_visual.remaining);
    var moving_boat = boat;
    moving_boat.remaining = 15;
    try boat_visual.step(boat_art, boat, moving_boat, .{ .direction = .south });
    try std.testing.expectEqual(@as(u16, 6), boat_visual.remaining);
    try world_view.compose(boat_art, moving_boat, &boat_visual, &list);
}

test "transactional Bribe charges the party only after the escape commits" {
    const fixture = try CombatFixture.open();
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.base.value, fixture.items.value, &members, 1234);
    combat.progress.money = 600;
    var session_progress = combat.progress;
    var session = try world_field.Session.open(allocator, fixture.map.value, fixture.rooms.value, field.State.init(fixture.rooms.value, &session_progress), .south);
    defer session.deinit();
    session.travel.mode = .battle;
    session.travel.selected = fixture.map.value.encounters[1].id;
    var values = [_]u15{ 0, 4095, 255, 8, 16, 32, 64, 128 };
    var draws: world.Draws = .{ .values = &values };
    var adapter: world_battle.Adapter = .{};
    defer adapter.deinit(allocator);
    var receipt: u64 = 0;
    try adapter.beginTransactional(&session, &combat, fixture.overlay.value, draws, receipt);
    _ = try adapter.tickTransactional(&session, &combat, .{ .down = true }, &draws, &receipt);
    _ = try adapter.tickTransactional(&session, &combat, .{ .down = true }, &draws, &receipt);
    _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
    try std.testing.expectEqual(battle.Phase.escaped, combat.phase);
    const after_escape = combat.progress.money;
    const before_commit = draws;
    session.field_state.progress.money += 1;
    try std.testing.expectError(error.StaleCombatMoney, adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt));
    try std.testing.expectEqualDeep(before_commit, draws);
    try std.testing.expectEqual(@as(u32, 601), session.field_state.progress.money);
    session.field_state.progress.money -= 1;
    _ = try adapter.tickTransactional(&session, &combat, .{ .confirm = true }, &draws, &receipt);
    try std.testing.expect(after_escape <= 600);
}
