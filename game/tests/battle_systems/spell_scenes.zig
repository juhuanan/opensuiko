const std = @import("std");
const h = @import("helpers.zig");
const allocator = h.allocator;
const hostFixture = h.hostFixture;
const Fixture = h.Fixture;
const battle = h.battle;
const rules = h.rules;
const field = h.field;
const world_battle = h.world_battle;
const combat_session = h.combat_session;
const stateBytes = h.stateBytes;
const sourceRoundBoundary = h.sourceRoundBoundary;

test "combat checkpoints rebind imported spell data and refuse a different library" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const scene_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(scene_bytes);
    const packet = try battle.spell_scene.load(allocator, scene_bytes);
    defer packet.deinit();
    var rebound = packet.value;
    var members: [6]battle.Member = undefined;
    var source = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    const old_identity = try combat_session.fingerprint(source);
    try source.attachSpellScenes(&packet.value);
    var identity = try combat_session.fingerprint(source);
    try std.testing.expect(!std.mem.eql(u8, &old_identity, &identity));
    const entry = combat_session.Entry{ .id = "scene-checkpoint", .receipt = "1", .content_id = "fixture", .encounter_id = source.content.encounters[source.encounter].id, .content_fingerprint = &identity };
    var scratch: [6]battle.Member = undefined;
    var draws = rules.Draws{ .prng = .init(17) };
    _ = try draws.next();
    var session = try combat_session.Session.begin(entry, source, &scratch, draws);
    const checkpoint = try session.capture(draws);
    const campaign_member = source.progress.party.at(0).*;
    session.state.progress.party.at(0).experience = (campaign_member.experience + 1) % 1000;
    session.state.progress.party.at(0).weapon_augment = .{ .rune = .fire, .fragments = 2 };
    try std.testing.expectEqualDeep(campaign_member, source.progress.party.at(0).*);
    var other_draws = draws;
    other_draws.prng = .init(18);
    try std.testing.expectError(error.RandomStreamMismatch, session.tick(.{}, &other_draws));
    session.state.spell_scenes = &rebound;
    try session.restore(checkpoint, &draws);
    try std.testing.expectEqualDeep(checkpoint.draws, draws);
    try std.testing.expectEqualDeep(campaign_member, session.state.progress.party.at(0).*);
    try std.testing.expect(session.state.spell_scenes == &rebound);
    session.state.spell_scenes = null;
    try std.testing.expectError(error.CombatContentMismatch, session.restore(checkpoint, &draws));
}

test "imported Firestorm shares the action camera and drives group damage without hitting KO slots" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, index| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = index;
        combat.startEncounter();
        break;
    };
    try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
    try combat.attachSpellScenes(&packet.value);
    combat.enemy_hp[0] = 0;
    combat.progress.party.at(0).rune = fixture.view.systems.?.runeIndex("fire");
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    var firestorm: usize = 0;
    for (fixture.view.systems.?.spells, 0..) |spell, i| if (std.mem.eql(u8, spell.id, "spell_2")) {
        firestorm = i;
    };
    var fallback = combat;
    fallback.spell_scenes = null;
    try fallback.requestRoundCamera(0, 20);
    fallback.advanceActorCamera();
    var continuing = fallback.actor_camera.?;
    try std.testing.expect(fallback.beginSpellAction(0, .{ .index = firestorm, .target = @as(usize, 1) }));
    try std.testing.expectEqualDeep(continuing, fallback.actor_camera.?);
    continuing.advance();
    fallback.advanceActorCamera();
    try std.testing.expectEqualDeep(continuing, fallback.actor_camera.?);
    combat.actions[0] = .{ .spell = .{ .index = firestorm, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    const initial_camera = battle.layout.cameraForTransition(&combat);
    combat.enemy_magic_pulse = .{ .issued_at = combat.camera_ticks -% 1, .delta_q12 = 5 * 4096 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expectEqualDeep(initial_camera, combat.active.?.scene.?.initial_camera);
    try std.testing.expectEqual(initial_camera.focus[2] + 5, battle.layout.currentCamera(combat).focus[2]);
    try std.testing.expectEqual(@as(u8, 2), combat.active.?.scene.?.target_count);
    const program = packet.value.spells[combat.active.?.scene.?.spell].program.?;
    while (combat.active != null) {
        const tick = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        for (1..3) |enemy| try std.testing.expectEqual(@as(u16, if (tick < 369) 5000 else 4636), combat.enemy_hp[enemy]);
        try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
        if (tick == 257) {
            // Accept the next party actor while the spell's focus impulse is due.
            const before = combat.actor_camera.?;
            const cursor = draws.cursor;
            combat.round_camera_choice = 0;
            combat.acted[1] = false;
            combat.coordinator = .{ .stage = .check, .current_actor = 0, .cached = .{ .actor = 1 }, .elapsed = combat.action_ticks };
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(.dispatch, combat.coordinator.?.stage);
            try std.testing.expectEqual(cursor, draws.cursor);
            try std.testing.expectEqual(@as(u16, 258), combat.effectTicks());
            const controller = combat.actor_camera.?;
            const round_x = -32 * 4096;
            try std.testing.expectEqual(@as(u16, 19), controller.remaining[0]);
            try std.testing.expectEqual(before.current[0][0] + @divTrunc(round_x - before.current[0][0], 20), controller.current[0][0]);
            const base = controller.sample();
            try std.testing.expectEqualDeep(base, battle.layout.cameraForTransition(&combat));
            var visible = base;
            visible.focus[0] -= 3;
            visible.focus[2] += 5;
            try std.testing.expectEqualDeep(visible, battle.layout.currentCamera(combat));
            const projected = battle.spell_scene.frameWithCamera(&packet.value, &combat.active.?.scene.?, 258, visible);
            const frame = combat.spellSceneFrame();
            try std.testing.expect(projected.count > 0);
            try std.testing.expectEqualDeep(projected.commands[0..projected.count], frame.commands[0..frame.count]);
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqualDeep(combat.actor_camera.?.sample(), battle.layout.currentCamera(combat));
            continue;
        }
        if (tick == 305) {
            const before = combat.actor_camera.?.current[0][0];
            try std.testing.expectEqual(@as(i32, -32 * 4096), before);
            try combat.tickReplay(.{}, &draws);
            const controller = combat.actor_camera.?;
            const request = program.cameras[2];
            try std.testing.expectEqual(request.at, combat.effectTicks());
            try std.testing.expectEqual(request.updates - 1, controller.remaining[0]);
            try std.testing.expectEqual(before + @divTrunc(request.target.focus[0] * 4096 - before, request.updates), controller.current[0][0]);
            try std.testing.expectEqualDeep(controller.sample(), battle.layout.currentCamera(combat));
            continue;
        }
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 434), combat.action_ticks);
    try std.testing.expectEqual(@as(u8, 8), combat.progress.party.at(0).rune_charges[1]);
    try std.testing.expectEqual(@as(u8, 9), combat.progress.party.at(0).rune_charges[0]);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
}

test "imported Fog retains enemy bonuses and applies its group modifier only on impact" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, index| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = index;
        combat.startEncounter();
        break;
    };
    try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
    try combat.attachSpellScenes(&packet.value);
    combat.enemy_hp[0] = 0;
    const party = combat.partyCount();
    combat.actor_conditions[party].stat_modifiers.skill_bonus = 70;
    combat.actor_conditions[party + 1].stat_modifiers = .{ .skill_bonus = 50, .defense_bonus = 91 };
    combat.actor_conditions[party + 2].stat_modifiers = .{ .skill_bonus = -51, .defense_bonus = -7 };
    combat.progress.party.at(0).rune = fixture.view.systems.?.runeIndex("water");
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    var spell_index: usize = 0;
    for (fixture.view.systems.?.spells, 0..) |spell, i| if (std.mem.eql(u8, spell.id, "spell_10")) {
        spell_index = i;
    };
    var draws = rules.Draws{ .bios_state = 17 };
    for (0..2) |cast| {
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell_index, .target = 0 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.phase = .resolving;
        combat.replay_draws = &draws;
        combat.nextAction();
        combat.replay_draws = null;
        const hp = combat.enemy_hp;
        try std.testing.expectEqual(@as(u8, 2), combat.active.?.scene.?.target_count);
        while (combat.active != null) {
            const tick = combat.effectTicks();
            const expected: i16 = if (cast == 0) (if (tick < 223) 50 else 40) else (if (tick < 223) 40 else 32);
            try std.testing.expectEqual(expected, combat.actor_conditions[party + 1].stat_modifiers.skill_bonus);
            try std.testing.expectEqual(@as(i16, if (cast == 0 and tick < 223) -51 else -expected), combat.actor_conditions[party + 2].stat_modifiers.skill_bonus);
            try std.testing.expectEqual(@as(i16, 70), combat.actor_conditions[party].stat_modifiers.skill_bonus);
            try std.testing.expectEqual(@as(i16, 91), combat.actor_conditions[party + 1].stat_modifiers.defense_bonus);
            try std.testing.expectEqual(@as(i16, -7), combat.actor_conditions[party + 2].stat_modifiers.defense_bonus);
            try std.testing.expectEqualDeep(hp, combat.enemy_hp);
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(@as(u16, 319), combat.action_ticks);
    }
    try std.testing.expectEqual(@as(u8, 7), combat.progress.party.at(0).rune_charges[1]);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
}

test "Spark launches an ordinary source strike and lets remaining allies follow before enemies" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const source = try world_battle.load(allocator, world_battle.json_c);
    defer source.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    try sourceRoundBoundary(&combat, source.value);
    combat.content.party_attacks = source.value.party_attacks;
    combat.progress.party.at(0).rune = fixture.view.systems.?.runeIndex("spark");
    try std.testing.expect(combat.hasRune(0, "spark"));
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .attack = 0 };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.acted[1] = false;
    combat.acted[2] = false;
    for (0..combat.enemyCount()) |i| combat.acted[combat.partyCount() + i] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
    var values: [2048]u15 = @splat(99);
    values[0] = 0;
    var draws = rules.Draws{ .values = &values };
    combat.replay_draws = &draws;
    combat.advanceCoordinator();
    combat.replay_draws = null;
    try std.testing.expect(combat.replay_unsupported == null);
    try std.testing.expect(combat.party_strikes[0] != null);
    try std.testing.expect(combat.spark_pending);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    var saw_first = false;
    var ticks: usize = 0;
    while (combat.spark_pending and ticks < 500) : (ticks += 1) {
        if (combat.acted[1] and !combat.acted[2]) saw_first = true;
        for (0..combat.enemyCount()) |i| try std.testing.expect(!combat.acted[combat.partyCount() + i]);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expect(ticks < 500);
    try std.testing.expect(saw_first);
    try std.testing.expect(combat.acted[1] and combat.acted[2]);
    try std.testing.expect(!combat.spark_pending);
}

test "generated Water heals living allies at246 and binds four orbits per party slot" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    try combat.attachSpellScenes(&packet.value);
    combat.progress.party.at(0).rune = fixture.view.systems.?.runeIndex("water");
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    for (combat.progress.party.items(), 0..) |member, index| {
        member.max_hp = 1000;
        member.hp = if (index == 2) 0 else @intCast(10 + index);
        member.status = if (index == 2) .unconscious else .poisoned;
    }
    combat.actor_conditions[3].protection_rounds = 2;
    combat.actor_conditions[4].rune_blocked = true;
    combat.actor_conditions[4].accuracy_reduced = true;
    const enemy_hp = combat.enemy_hp;
    var spell_index: usize = 0;
    for (fixture.view.systems.?.spells, 0..) |spell, index| if (std.mem.eql(u8, spell.id, "spell_11")) {
        spell_index = index;
    };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell_index, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expectEqual(@as(u8, 6), combat.active.?.scene.?.party_count);
    try std.testing.expectEqual(@as(u8, 5), combat.active.?.scene.?.target_count);
    while (combat.active != null) {
        const tick = combat.effectTicks();
        for (combat.progress.party.items(), 0..) |member, index| {
            const hp: u16 = if (index == 2) 0 else @intCast(10 + index + @as(usize, if (tick >= 246 and index != 3) 300 else 0));
            try std.testing.expectEqual(hp, member.hp);
            if (tick >= 246 and index != 2) try std.testing.expectEqual(.healthy, member.status);
        }
        try std.testing.expectEqualDeep(enemy_hp, combat.enemy_hp);
        try std.testing.expect(combat.spellReaction(2) == null);
        if (tick >= 246) {
            try std.testing.expect(!combat.actor_conditions[4].rune_blocked);
            try std.testing.expect(!combat.actor_conditions[4].accuracy_reduced);
            try std.testing.expectEqual(@as(u8, 0), combat.spellReaction(0).?.animation);
        }
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 307), combat.action_ticks);
    try std.testing.expectEqual(@as(u8, 8), combat.progress.party.at(0).rune_charges[2]);
    try std.testing.expectEqual(@as(usize, 73), draws.cursor);
}

test "all four source consumables dispatch with exact effects and separate owner recovery" {
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const ids = [_]field.items.Id{ .medicine, .mega_medicine, .antitoxin, .needle };
    for (ids) |id| for (0..6) |user| for (0..6) |target| for ([_]bool{ false, true }) |protected| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.content.medicine_timings = source.value.medicine_timings;
        combat.progress.party.at(target).max_hp = 1000;
        combat.progress.party.at(target).hp = 100;
        combat.progress.party.at(target).status = .poisoned;
        combat.progress.party.at(target).balloons = 2;
        combat.actor_conditions[target].rune_blocked = true;
        combat.actor_conditions[target].accuracy_reduced = true;
        combat.unbalanced[target] = 2;
        combat.actor_conditions[target].protection_rounds = if (protected) 3 else 0;
        combat.progress.party.at(user).inventory.slots = @splat(null);
        combat.progress.party.at(user).inventory.slots[0] = .{ .id = id, .uses = 1 };
        combat.progress.party.at(user).inventory.slots[1] = .{ .id = .bandanna, .uses = 0 };
        combat.actions = @splat(.defend);
        combat.actions[user] = .{ .item = .{ .slot = 0, .target = target, .id = id } };
        combat.acted = @splat(true);
        combat.phase = .resolving;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = user, .cached = .round_end };
        var draws = rules.Draws{ .values = &.{} };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(id, combat.medicine_action.?.id);
        try std.testing.expectEqual(field.items.Id.bandanna, combat.progress.party.at(user).inventory.slots[0].?.id);
        const timing = combat.medicine_action.?.timing;
        const impact_delay: u16 = switch (id) {
            .medicine, .mega_medicine => 32,
            .antitoxin => 31,
            .needle => 12,
            else => unreachable,
        };
        const release_delay: u16 = switch (id) {
            .medicine, .mega_medicine => 64,
            .antitoxin => 33,
            .needle => 14,
            else => unreachable,
        };
        try std.testing.expectEqual(timing.target_start + impact_delay, timing.impact_tick);
        try std.testing.expectEqual(timing.target_start + release_delay, timing.target_release);
        const end = if (user == target) timing.target_release else @max(timing.owner_release, timing.target_release);
        while (combat.medicine_action.?.ticks < end) {
            const age = combat.medicine_action.?.ticks;
            const after = age >= timing.impact_tick;
            const amount: u16 = if (!after or protected) 0 else switch (id) {
                .medicine => 100,
                .mega_medicine => 500,
                else => 0,
            };
            try std.testing.expectEqual(@as(u16, 100) + amount, combat.progress.party.at(target).hp);
            try std.testing.expectEqual(if (after and id == .antitoxin) field.game_state.Status.healthy else .poisoned, combat.progress.party.at(target).status);
            try std.testing.expectEqual(@as(u8, if (after and id == .needle) 1 else 2), combat.progress.party.at(target).balloons);
            try std.testing.expectEqual(age >= timing.target_release, combat.medicine_action.?.target_released);
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expect(combat.medicine_action.?.owner_released);
        try std.testing.expect(combat.medicine_action.?.target_released);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        try std.testing.expect(combat.actor_conditions[target].rune_blocked and combat.actor_conditions[target].accuracy_reduced);
        try std.testing.expectEqual(@as(u8, 2), combat.unbalanced[target]);
        try std.testing.expectEqual(@as(u8, if (protected) 3 else 0), combat.actor_conditions[target].protection_rounds);
    };
}

test "no-effect cure self-use spends a use and retains the preparation owner" {
    const source = try world_battle.load(allocator, world_battle.json);
    defer source.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    for ([_]field.items.Id{ .antitoxin, .needle }) |id| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.content.medicine_timings = source.value.medicine_timings;
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .item = .{ .slot = 0, .target = 0, .id = id } };
        combat.progress.party.at(0).inventory.slots[0] = .{ .id = id, .uses = 2 };
        combat.acted = @splat(true);
        combat.phase = .resolving;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = 0, .cached = .round_end };
        var draws = rules.Draws{ .values = &.{} };
        try combat.tickReplay(.{}, &draws);
        const timing = combat.medicine_action.?.timing;
        while (combat.medicine_action.?.ticks < timing.owner_release) {
            if (combat.medicine_action.?.ticks >= timing.target_start) {
                try std.testing.expect(combat.medicine_action.?.target_released);
                try std.testing.expect(combat.medicine_action.?.target_interrupted);
                try std.testing.expect(!combat.medicine_action.?.owner_released);
            }
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expect(combat.medicine_action.?.owner_released);
        try std.testing.expectEqual(@as(u16, 1), combat.progress.party.at(0).inventory.slots[0].?.uses);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    }
}

test "direct Earth buffs preserve ailments and accept a Turtle target in both spell paths" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    for ([_]bool{ false, true }) |integrated| for ([_][]const u8{ "Clay Guardian", "Copper Flesh", "Guardian of Earth" }) |name| {
        if (!integrated and std.mem.eql(u8, name, "Guardian of Earth")) continue;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        if (integrated) combat.integration = .{ .host = host };
        const systems = combat.content.systems.?;
        const spell = for (systems.spells, 0..) |definition, i| {
            if (std.mem.eql(u8, definition.name, name)) break i;
        } else return error.MissingBuff;
        combat.progress.party.at(0).rune = for (systems.runes, 0..) |rune, i| {
            var owns = false;
            for (rune.spells) |maybe| if (maybe == spell) {
                owns = true;
            };
            if (owns) break i;
        } else return error.MissingBuffRune;
        combat.progress.party.at(1).rune = systems.runeIndex("turtle").?;
        combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(1).status = .poisoned;
        combat.progress.party.at(1).balloons = 2;
        combat.actor_conditions[1].sleep_turns = 1;
        combat.unbalanced[1] = 2;
        combat.actor_conditions[1].accuracy_reduced = true;
        combat.actor_conditions[1].rune_blocked = true;
        combat.actor_conditions[1].stat_modifiers = .{ .defense_bonus = -51, .skill_bonus = 73 };
        combat.actor_conditions[2].stat_modifiers.defense_bonus = 50;
        var draws = rules.Draws{ .values = &.{} };
        combat.replay_draws = &draws;
        const before = combat.progress.party.at(1).hp;
        var effect = battle.Effect{ .actor = 0, .target = 1, .kind = .cast, .spell = spell };
        combat.applySpell(&effect);
        combat.replay_draws = null;
        try std.testing.expectEqual(@as(@FieldType(battle.Effect, "kind"), .cast), effect.kind);
        const copper = std.mem.eql(u8, name, "Copper Flesh");
        try std.testing.expectEqual(@as(i16, if (copper) -51 else -76), combat.actor_conditions[1].stat_modifiers.defense_bonus);
        try std.testing.expectEqual(@as(i16, 73), combat.actor_conditions[1].stat_modifiers.skill_bonus);
        try std.testing.expectEqual(@as(u8, if (copper) 3 else 0), combat.actor_conditions[1].protection_rounds);
        try std.testing.expectEqual(@as(i16, if (std.mem.eql(u8, name, "Guardian of Earth")) 75 else 50), combat.actor_conditions[2].stat_modifiers.defense_bonus);
        try std.testing.expectEqual(before, combat.progress.party.at(1).hp);
        try std.testing.expectEqual(field.game_state.Status.poisoned, combat.progress.party.at(1).status);
        try std.testing.expectEqual(@as(u8, 2), combat.progress.party.at(1).balloons);
        try std.testing.expectEqual(@as(u8, 1), combat.actor_conditions[1].sleep_turns);
        try std.testing.expectEqual(@as(u8, 2), combat.unbalanced[1]);
        try std.testing.expect(combat.actor_conditions[1].accuracy_reduced and combat.actor_conditions[1].rune_blocked);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    };
}

test "generated Clay applies one Turtle-compatible buff and rolls back a late particle draw failure" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    for ([_]bool{ true, false }) |exhaust| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachSpellScenes(&packet.value);
        combat.progress.party.at(0).rune = combat.content.systems.?.runeIndex("earth").?;
        combat.progress.party.at(1).rune = combat.content.systems.?.runeIndex("turtle").?;
        combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        combat.actor_conditions[1].stat_modifiers.defense_bonus = -51;
        const spell = for (combat.content.systems.?.spells, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, "Clay Guardian")) break i;
        } else unreachable;
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell, .target = 1 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.phase = .resolving;
        const short_values: [30]u15 = @splat(0);
        var draws = if (exhaust) rules.Draws{ .values = &short_values } else rules.Draws{ .bios_state = 17 };
        combat.replay_draws = &draws;
        combat.nextAction();
        combat.replay_draws = null;
        while (combat.effectTicks() < 176) try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(i16, -51), combat.actor_conditions[1].stat_modifiers.defense_bonus);
        if (exhaust) {
            const before = try stateBytes(combat);
            defer allocator.free(before);
            const cursor = draws.cursor;
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
            const after = try stateBytes(combat);
            defer allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
            try std.testing.expectEqual(cursor, draws.cursor);
            continue;
        }
        const hp = combat.progress.party.at(1).hp;
        var stopped_draws: usize = 0;
        while (combat.active != null) {
            const age = combat.effectTicks();
            if (age == 272) stopped_draws = draws.cursor;
            try std.testing.expectEqual(@as(i16, if (age < 177) -51 else -76), combat.actor_conditions[1].stat_modifiers.defense_bonus);
            try std.testing.expectEqual(hp, combat.progress.party.at(1).hp);
            if (age == 210 or age == 244) try std.testing.expectEqualDeep([3]u8{ 128, 128, 128 }, combat.spellReaction(1).?.color);
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(stopped_draws, draws.cursor);
        try std.testing.expectEqual(@as(u8, 8), combat.progress.party.at(0).rune_charges[0]);
        try std.testing.expectEqual(@as(u16, 337), combat.action_ticks);
    }
}

test "generated Guardian of Earth buffs living allies once at289 and releases353" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, "Guardian of Earth")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = for (systems.runes, 0..) |rune, i| {
        var owns = false;
        for (rune.spells) |maybe| if (maybe == spell) {
            owns = true;
        };
        if (owns) break i;
    } else unreachable;
    combat.progress.party.at(1).rune = systems.runeIndex("turtle").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.actor_conditions[1].stat_modifiers.defense_bonus = -51;
    combat.actor_conditions[2].stat_modifiers.defense_bonus = 50;
    combat.progress.party.at(2).hp = 0;
    combat.progress.party.at(2).status = .unconscious;
    combat.actor_conditions[1].protection_rounds = 2;
    const hp = combat.progress.party.at(1).hp;
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 1 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expectEqual(@as(u8, 5), combat.active.?.scene.?.target_count);
    var stop_draws: usize = 0;
    while (combat.active != null) {
        const age = combat.effectTicks();
        if (age == 320) stop_draws = draws.cursor;
        try std.testing.expectEqual(@as(i16, if (age < 289) -51 else -76), combat.actor_conditions[1].stat_modifiers.defense_bonus);
        try std.testing.expectEqual(@as(i16, 50), combat.actor_conditions[2].stat_modifiers.defense_bonus);
        try std.testing.expectEqual(hp, combat.progress.party.at(1).hp);
        try std.testing.expect(combat.spellReaction(2) == null);
        if (age == 161 or age == 193 or age == 225 or age == 257) try std.testing.expectEqualDeep([3]u8{ 128, 128, 128 }, combat.spellReaction(1).?.color);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(stop_draws, draws.cursor);
    try std.testing.expectEqual(@as(u8, 8), combat.progress.party.at(0).rune_charges[3]);
    try std.testing.expectEqual(@as(u16, 353), combat.action_ticks);
}

test "generated Copper Flesh protects a Turtle target at225 and releases449" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_23")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("earth").?;
    combat.progress.party.at(1).rune = systems.runeIndex("turtle").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(1).status = .poisoned;
    const hp = combat.progress.party.at(1).hp;
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 1 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    const cursor = draws.cursor;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u8, if (age < 225) 0 else 3), combat.actor_conditions[1].protection_rounds);
        try std.testing.expectEqual(hp, combat.progress.party.at(1).hp);
        try std.testing.expectEqual(field.game_state.Status.poisoned, combat.progress.party.at(1).status);
        if (age == 225 or age == 259 or age == 293) try std.testing.expectEqualDeep([3]u8{ 128, 128, 128 }, combat.spellReaction(1).?.color);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(cursor, draws.cursor);
    try std.testing.expectEqual(@as(u8, 8), combat.progress.party.at(0).rune_charges[2]);
    try std.testing.expectEqual(@as(u16, 449), combat.action_ticks);
}

test "generated Mother Ocean binds fallen allies and heals once at366 before release431" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_30")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = for (systems.runes, 0..) |rune, i| {
        var owns = false;
        for (rune.spells) |maybe| if (maybe == spell) {
            owns = true;
        };
        if (owns) break i;
    } else unreachable;
    combat.progress.party.at(1).rune = systems.runeIndex("turtle").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(1).status = .poisoned;
    combat.progress.party.at(1).hp = 1;
    combat.progress.party.at(2).hp = 0;
    combat.progress.party.at(2).status = .unconscious;
    combat.progress.party.at(3).hp = combat.progress.party.at(3).max_hp / 2;
    combat.progress.party.at(3).balloons = 3;
    combat.beginDeparture(3);
    combat.actor_conditions[1].protection_rounds = 2;
    combat.progress.party.at(4).hp = 0;
    combat.progress.party.at(4).status = .unconscious;
    combat.actor_conditions[4].rune_blocked = true;
    combat.actor_conditions[4].protection_rounds = 2;
    var fallback_members = members;
    var fallback = combat;
    fallback.integration = null;
    fallback.progress.party = .init(&fallback_members);
    fallback.party_knockouts[2].pending = true;
    var effect: battle.Effect = .{ .kind = .cast, .actor = 0, .target = 1, .spell = spell };
    fallback.applySpell(&effect);
    try std.testing.expect(!fallback.party_knockouts[2].pending);
    try std.testing.expectEqual(@as(u16, 0), fallback_members[4].hp);
    try std.testing.expectEqual(.unconscious, fallback_members[4].status);
    try std.testing.expect(!fallback.actor_conditions[4].rune_blocked);
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 1 } };
    combat.actions[2] = null;
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.acted[2] = false;
    combat.acted[3] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    const cursor = draws.cursor;
    try std.testing.expectEqual(@as(u8, 6), combat.active.?.scene.?.target_count);
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 1), combat.progress.party.at(1).hp);
        try std.testing.expectEqual(if (age < 366) field.game_state.Status.poisoned else field.game_state.Status.healthy, combat.progress.party.at(1).status);
        try std.testing.expectEqual(@as(u16, if (age < 366) 0 else combat.progress.party.at(2).max_hp), combat.progress.party.at(2).hp);
        try std.testing.expectEqual(if (age < 366) field.game_state.Status.unconscious else field.game_state.Status.healthy, combat.progress.party.at(2).status);
        try std.testing.expectEqual(age >= 366, combat.acted[2]);
        try std.testing.expect(!combat.acted[3]);
        try std.testing.expectEqual(age < 366, combat.departed[3]);
        try std.testing.expectEqual(@as(u16, if (age < 366) combat.progress.party.at(3).max_hp / 2 else combat.progress.party.at(3).max_hp), combat.progress.party.at(3).hp);
        try std.testing.expectEqual(@as(u8, if (age < 366) 3 else 0), combat.progress.party.at(3).balloons);
        try std.testing.expectEqual(@as(u16, 0), combat.progress.party.at(4).hp);
        try std.testing.expectEqual(.unconscious, combat.progress.party.at(4).status);
        try std.testing.expect(!combat.party_knockouts[4].pending);
        try std.testing.expectEqual(age < 366, combat.actor_conditions[4].rune_blocked);
        if (age == 247) try std.testing.expect(combat.spellReaction(2) != null);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(cursor, draws.cursor);
    try std.testing.expectEqual(@as(u8, 8), combat.progress.party.at(0).rune_charges[3]);
    try std.testing.expectEqual(@as(u16, 431), combat.action_ticks);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(usize, 3), combat.active.?.actor);
    try std.testing.expectEqual(.defend, combat.active.?.kind);
}

test "generated Rain of Kindness heals living allies once396 and releases397" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_12")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = for (systems.runes, 0..) |rune, i| {
        var owns = false;
        for (rune.spells) |maybe| if (maybe == spell) {
            owns = true;
        };
        if (owns) break i;
    } else unreachable;
    combat.progress.party.at(1).rune = systems.runeIndex("turtle").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(1).status = .poisoned;
    combat.progress.party.at(1).hp = 1;
    combat.progress.party.at(2).hp = 0;
    combat.progress.party.at(2).status = .unconscious;
    combat.actor_conditions[1].protection_rounds = 2;
    combat.progress.party.at(3).hp = 1;
    combat.progress.party.at(3).status = .poisoned;
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 1 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    var cursor = draws.cursor;
    try std.testing.expectEqual(@as(u8, 5), combat.active.?.scene.?.target_count);
    while (combat.active != null) {
        const age = combat.effectTicks();
        if (age == 336) cursor = draws.cursor;
        try std.testing.expectEqual(@as(u16, 1), combat.progress.party.at(1).hp);
        try std.testing.expectEqual(if (age < 396) field.game_state.Status.poisoned else field.game_state.Status.healthy, combat.progress.party.at(1).status);
        try std.testing.expectEqual(@as(u16, 0), combat.progress.party.at(2).hp);
        try std.testing.expectEqual(@as(u16, if (age < 396) 1 else combat.progress.party.at(3).max_hp), combat.progress.party.at(3).hp);
        try std.testing.expectEqual(field.game_state.Status.unconscious, combat.progress.party.at(2).status);
        if (age == 277) {
            try std.testing.expect(combat.spellReaction(2) == null);
            try std.testing.expect(combat.spellReaction(3) != null);
        }
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(cursor, draws.cursor);
    try std.testing.expectEqual(@as(u8, 8), combat.progress.party.at(0).rune_charges[3]);
    try std.testing.expectEqual(@as(u16, 397), combat.action_ticks);
}

test "generated Angry Blow lands twice reacts189 damages240 and releases305" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "crow", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len > 0 and std.mem.eql(u8, encounter.enemies[0], "crow")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_17")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("lightning").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    const before = draws.cursor;
    try std.testing.expectEqualDeep([2]i32{ -5, -13 }, combat.active.?.scene.?.target_idle_center);
    try std.testing.expectEqualDeep([2]i32{ 3, -9 }, combat.active.?.scene.?.target_center);
    const pose = for (packet.value.hurt_poses) |entry| {
        if (std.mem.eql(u8, entry.id, "crow")) break entry;
    } else unreachable;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, if (age < 240) 5000 else 4818), combat.enemy_hp[0]);
        if (age < 240) try std.testing.expectEqual(before + @as(usize, if (age < 177) 0 else if (age < 189) 2 else if (age < 201) 5 else 6), draws.cursor);
        try std.testing.expectEqual(@as(u8, if (age < 240) 9 else 8), combat.progress.party.at(0).rune_charges[0]);
        const reaction = combat.spellReaction(combat.partyCount());
        if (age < 189 or age >= 223) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 192) try std.testing.expectEqual(pose.shock_entries.?[0], reaction.?.entry.?);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 305), combat.action_ticks);
}

test "generated Rainstorm keeps KO formation gaps reacts289 damages345 and releases409" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
    combat.enemy_hp[0] = 0;
    combat.actor_conditions[combat.partyCount() + 2].protection_rounds = 2;
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_18")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("lightning").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    const before = draws.cursor;
    try std.testing.expectEqual(@as(u8, 2), combat.active.?.scene.?.target_count);
    try std.testing.expectEqual(@as(?u8, 1), combat.active.?.scene.?.targets[0].formation_slot);
    try std.testing.expectEqual(@as(?u8, 2), combat.active.?.scene.?.targets[1].formation_slot);
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, if (age < 345) 5000 else 4868), combat.enemy_hp[1]);
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
        if (age >= 289) try std.testing.expectEqual(before + 30, draws.cursor);
        try std.testing.expectEqual(@as(u8, if (age < 345) 9 else 8), combat.progress.party.at(0).rune_charges[1]);
        try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
        const reaction = combat.spellReaction(combat.partyCount() + 1);
        if (age < 289 or age >= 323) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 288) {
            const short_values: [32]u15 = @splat(0);
            var short_draws = rules.Draws{ .values = short_values[0 .. draws.cursor + 2], .cursor = draws.cursor };
            const state_before = try stateBytes(combat);
            defer allocator.free(state_before);
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
            const state_after = try stateBytes(combat);
            defer allocator.free(state_after);
            try std.testing.expectEqualSlices(u8, state_before, state_after);
            try std.testing.expectEqual(draws.cursor, short_draws.cursor);
        }
        if (age == 289) {
            try std.testing.expect(!combat.active.?.scene.?.particles[0].splash_active);
            try std.testing.expect(combat.active.?.scene.?.particles[1].splash_active);
            try std.testing.expect(combat.active.?.scene.?.particles[2].splash_active);
        }
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 409), combat.action_ticks);
}

test "generated arranged lightning reacts268 damages337 and releases401 without visual draws" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "crow", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len > 0 and std.mem.eql(u8, encounter.enemies[0], "crow")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_19")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("lightning").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    const before = draws.cursor;
    try std.testing.expectEqualDeep([2]i32{ -5, -13 }, combat.active.?.scene.?.target_idle_center);
    try std.testing.expectEqualDeep([2]i32{ 3, -9 }, combat.active.?.scene.?.target_center);
    const pose = for (packet.value.hurt_poses) |entry| {
        if (std.mem.eql(u8, entry.id, "crow")) break entry;
    } else unreachable;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, if (age < 337) 5000 else 4368), combat.enemy_hp[0]);
        try std.testing.expectEqual(before, draws.cursor);
        try std.testing.expectEqual(@as(u8, if (age < 337) 9 else 8), combat.progress.party.at(0).rune_charges[2]);
        const reaction = combat.spellReaction(combat.partyCount());
        if (age < 268 or age >= 302) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 272) try std.testing.expectEqual(pose.shock_entries.?[0], reaction.?.entry.?);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 401), combat.action_ticks);
}

test "generated contracting lightning preserves reaction gaps damages384 and releases385" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "crow", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len > 0 and std.mem.eql(u8, encounter.enemies[0], "crow")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_20")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("lightning").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    const before = draws.cursor;
    try std.testing.expectEqualDeep([2]i32{ -5, -13 }, combat.active.?.scene.?.target_idle_center);
    try std.testing.expectEqualDeep([2]i32{ 3, -9 }, combat.active.?.scene.?.target_center);
    const pose = for (packet.value.hurt_poses) |entry| {
        if (std.mem.eql(u8, entry.id, "crow")) break entry;
    } else unreachable;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, if (age < 384) 5000 else 3968), combat.enemy_hp[0]);
        try std.testing.expectEqual(before, draws.cursor);
        try std.testing.expectEqual(@as(u8, if (age < 384) 9 else 8), combat.progress.party.at(0).rune_charges[3]);
        const reaction = combat.spellReaction(combat.partyCount());
        if (!(age >= 225 and age < 259) and !(age >= 261 and age < 295) and !(age >= 297 and age < 331)) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 264) try std.testing.expectEqual(pose.shock_entries.?[0], reaction.?.entry.?);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 385), combat.action_ticks);
}

test "generated sound scenes revive368 or heal364 and consume only scheduled draws" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    for ([_][]const u8{ "spell_6", "spell_7" }, 0..) |id, variant| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachSpellScenes(&packet.value);
        const systems = combat.content.systems.?;
        const spell = for (systems.spells, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, id)) break i;
        } else unreachable;
        combat.progress.party.at(0).rune = for (systems.runes, 0..) |rune, i| {
            var owns = false;
            for (rune.spells) |maybe| if (maybe == spell) {
                owns = true;
            };
            if (owns) break i;
        } else unreachable;
        combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(1).hp = if (variant == 0) 0 else 1;
        combat.progress.party.at(1).status = if (variant == 0) .unconscious else .poisoned;
        combat.progress.party.at(2).hp = 0;
        combat.progress.party.at(2).status = .unconscious;
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell, .target = 1 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.phase = .resolving;
        var draws = rules.Draws{ .bios_state = 17 };
        combat.replay_draws = &draws;
        combat.nextAction();
        combat.replay_draws = null;
        const cursor = draws.cursor;
        const impact: u16 = if (variant == 0) 368 else 364;
        const healed: u16 = if (variant == 0) combat.progress.party.at(1).max_hp / 3 else @min(combat.progress.party.at(1).max_hp, 301);
        while (combat.active != null) {
            const age = combat.effectTicks();
            try std.testing.expectEqual(if (age < impact) @as(u16, if (variant == 0) 0 else 1) else healed, combat.progress.party.at(1).hp);
            try std.testing.expectEqual(@as(u16, 0), combat.progress.party.at(2).hp);
            if (age >= impact) try std.testing.expectEqual(field.game_state.Status.healthy, combat.progress.party.at(1).status);
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(cursor + @as(usize, if (variant == 0) 33 else 162), draws.cursor);
        try std.testing.expectEqual(impact + 1, combat.action_ticks);
    }
}

test "generated Storm keeps KO formation gaps reacts171 damages224 and releases281" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
    combat.enemy_hp[0] = 0;
    combat.actor_conditions[combat.partyCount() + 2].protection_rounds = 2;
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_16")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("wind").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    const before = draws.cursor;
    try std.testing.expectEqual(@as(u8, 2), combat.active.?.scene.?.target_count);
    try std.testing.expectEqual(@as(?u8, 1), combat.active.?.scene.?.targets[0].formation_slot);
    try std.testing.expectEqual(@as(?u8, 2), combat.active.?.scene.?.targets[1].formation_slot);
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, if (age < 224) 5000 else 4468), combat.enemy_hp[1]);
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
        if (age >= 224) try std.testing.expectEqual(before, draws.cursor);
        try std.testing.expectEqual(@as(u8, if (age < 224) 9 else 8), combat.progress.party.at(0).rune_charges[3]);
        try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
        const reaction = combat.spellReaction(combat.partyCount() + 1);
        if (age < 171 or age >= 186) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 281), combat.action_ticks);
}

test "generated paired wind reacts163 damages208 and releases265 without visual draws" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len > 0 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_14")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("wind").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    const before = draws.cursor;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, if (age < 208) 5000 else 4568), combat.enemy_hp[0]);
        try std.testing.expectEqual(before, draws.cursor);
        try std.testing.expectEqual(@as(u8, if (age < 208) 9 else 8), combat.progress.party.at(0).rune_charges[1]);
        const reaction = combat.spellReaction(combat.partyCount());
        if (age < 163 or age >= 178) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 164) try std.testing.expectEqualDeep([3]u8{ 64, 64, 255 }, reaction.?.color);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 265), combat.action_ticks);
}

test "generated Healing Wind respects HP protection cures288 and releases289 without visual draws" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    for ([_]u8{ 0, 2 }) |protection| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachSpellScenes(&packet.value);
        const systems = combat.content.systems.?;
        const spell = for (systems.spells, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, "spell_15")) break i;
        } else unreachable;
        combat.progress.party.at(0).rune = for (systems.runes, 0..) |rune, i| {
            var owns = false;
            for (rune.spells) |maybe| if (maybe == spell) {
                owns = true;
            };
            if (owns) break i;
        } else unreachable;
        combat.progress.party.at(1).rune = systems.runeIndex("turtle").?;
        combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(1).status = .poisoned;
        combat.progress.party.at(1).hp = 1;
        combat.progress.party.at(2).hp = 0;
        combat.progress.party.at(2).status = .unconscious;
        combat.actor_conditions[1].protection_rounds = protection;
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell, .target = 1 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.phase = .resolving;
        var draws = rules.Draws{ .bios_state = 17 };
        combat.replay_draws = &draws;
        combat.nextAction();
        combat.replay_draws = null;
        const cursor = draws.cursor;
        while (combat.active != null) {
            const age = combat.effectTicks();
            try std.testing.expectEqual(@as(u16, if (age < 288 or protection != 0) 1 else combat.progress.party.at(1).max_hp), combat.progress.party.at(1).hp);
            try std.testing.expectEqual(if (age < 288) field.game_state.Status.poisoned else field.game_state.Status.healthy, combat.progress.party.at(1).status);
            try std.testing.expectEqual(@as(u16, 0), combat.progress.party.at(2).hp);
            try std.testing.expectEqual(field.game_state.Status.unconscious, combat.progress.party.at(2).status);
            try std.testing.expect(combat.spellReaction(2) == null);
            if (age == 193) try std.testing.expectEqual(@as(u8, 0), combat.spellReaction(1).?.animation);
            try std.testing.expectEqual(@as(u8, if (age < 288) 9 else 8), combat.progress.party.at(0).rune_charges[2]);
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(cursor, draws.cursor);
        try std.testing.expectEqual(@as(u8, 8), combat.progress.party.at(0).rune_charges[2]);
        try std.testing.expectEqual(@as(u16, 289), combat.action_ticks);
    }
}

test "generated Wind of Sleep preserves KO gaps wards and HP protection and rolls only361" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    for ([_]bool{ false, true }) |immune| {
        var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
        defer fixture.deinit();
        for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
            profile.death_immune = immune;
        };
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
            combat.encounter = i;
            combat.startEncounter();
            break;
        };
        combat.enemy_hp[0] = 0;
        combat.actor_conditions[combat.partyCount() + 2].protection_rounds = 2;
        try combat.attachSpellScenes(&packet.value);
        const systems = combat.content.systems.?;
        const spell = for (systems.spells, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, "spell_13")) break i;
        } else unreachable;
        combat.progress.party.at(0).rune = systems.runeIndex("wind").?;
        combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.phase = .resolving;
        var draws = rules.Draws{ .bios_state = 17 };
        combat.replay_draws = &draws;
        combat.nextAction();
        combat.replay_draws = null;
        try std.testing.expectEqual(@as(usize, 101), draws.cursor);
        var status_draw: usize = 0;
        var expected_sleep = [2]u8{ 0, 0 };
        while (combat.active != null) {
            const age = combat.effectTicks();
            try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
            try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[1]);
            try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
            try std.testing.expectEqual(@as(u8, 2), combat.actor_conditions[combat.partyCount() + 2].protection_rounds);
            if (age < 361 or immune) {
                try std.testing.expectEqual(@as(u8, 0), combat.actor_conditions[combat.partyCount() + 1].sleep_turns);
                try std.testing.expectEqual(@as(u8, 0), combat.actor_conditions[combat.partyCount() + 2].sleep_turns);
            }
            try std.testing.expectEqual(@as(u8, if (age < 361) 9 else 8), combat.progress.party.at(0).rune_charges[0]);
            try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
            const reaction = combat.spellReaction(combat.partyCount() + 1);
            if (immune or age < 193 or age >= 360) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
            if (age == 360) {
                status_draw = draws.cursor;
                if (!immune) {
                    const values: [8192]u15 = @splat(32767);
                    var short = rules.Draws{ .values = values[0 .. status_draw + 1], .cursor = status_draw };
                    const before = try stateBytes(combat);
                    defer allocator.free(before);
                    const before_members = members;
                    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short));
                    const after = try stateBytes(combat);
                    defer allocator.free(after);
                    try std.testing.expectEqualSlices(u8, before, after);
                    try std.testing.expectEqualDeep(before_members, members);
                    try std.testing.expectEqual(status_draw, short.cursor);

                    var oracle = draws;
                    for (&expected_sleep) |*status| status.* = if ((@as(u32, try oracle.next()) * 100 / 32767) % 100 >= 30) 1 else 0;
                }
            }
            if (age >= 361) try std.testing.expectEqual(status_draw + @as(usize, if (immune) 0 else 2), draws.cursor);
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(@as(u16, 417), combat.action_ticks);
        try std.testing.expectEqual(expected_sleep[0], combat.actor_conditions[combat.partyCount() + 1].sleep_turns);
        try std.testing.expectEqual(expected_sleep[1], combat.actor_conditions[combat.partyCount() + 2].sleep_turns);
    }
}

test "generated Dancing Flames repeats target reactions preserves KO gaps damages493 and releases494" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
        profile.fire_affinity = .neutral;
        profile.affinities = .{};
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    combat.enemy_hp[0] = 0;
    combat.actor_conditions[combat.partyCount() + 2].protection_rounds = 2;
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_3")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("fire").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expectEqual(@as(usize, 31), draws.cursor);
    var stop_draws: usize = 0;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, if (age < 493) 5000 else 4568), combat.enemy_hp[1]);
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
        try std.testing.expectEqual(@as(u8, if (age < 493) 9 else 8), combat.progress.party.at(0).rune_charges[2]);
        try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
        const reaction = combat.spellReaction(combat.partyCount() + 1);
        if (age < 238 or age >= 454) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 237) {
            const short_values: [33]u15 = @splat(0);
            var short_draws = rules.Draws{ .values = &short_values, .cursor = draws.cursor };
            const before = try stateBytes(combat);
            defer allocator.free(before);
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
            const after = try stateBytes(combat);
            defer allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
            try std.testing.expectEqual(draws.cursor, short_draws.cursor);
        }
        if (age == 429) stop_draws = draws.cursor;
        if (age >= 430) try std.testing.expectEqual(stop_draws, draws.cursor);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(usize, 151), draws.cursor);
    try std.testing.expectEqual(@as(u16, 494), combat.action_ticks);
}

test "generated Judgment retargets KO respects protection and ignores death ward damages504 releases505" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    for ([_]bool{ false, true }) |protected| {
        var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
        defer fixture.deinit();
        for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
            profile.death_immune = true;
        };
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
            combat.encounter = i;
            combat.startEncounter();
            break;
        };
        combat.enemy_hp[0] = 0;
        if (protected) combat.actor_conditions[combat.partyCount() + 1].protection_rounds = 2;
        try combat.attachSpellScenes(&packet.value);
        const systems = combat.content.systems.?;
        const spell = for (systems.spells, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, "spell_28")) break i;
        } else unreachable;
        // Soul Eater's story attachment remains separate from this scene fixture.
        const runes = try allocator.alloc(rules.Rune, systems.runes.len + 1);
        defer allocator.free(runes);
        @memcpy(runes[0..systems.runes.len], systems.runes);
        runes[systems.runes.len] = .{ .id = "soul_eater", .name = "Soul Eater", .spell_names = .{ "-", "-", "-", systems.spells[spell].name }, .spells = .{ null, null, null, spell } };
        var view = systems;
        view.runes = runes;
        combat.content.systems = view;
        combat.progress.party.at(0).rune = systems.runes.len;
        combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.phase = .resolving;
        var draws = rules.Draws{ .bios_state = 17 };
        combat.replay_draws = &draws;
        combat.nextAction();
        combat.replay_draws = null;
        try std.testing.expectEqual(combat.partyCount() + 1, combat.active.?.target);
        try std.testing.expectEqual(@as(usize, 31), draws.cursor);
        var mote_spawns: usize = 0;
        for (4..15) |i| mote_spawns += 1 + (95 - combat.active.?.scene.?.draws[2 * i] % 48) / 34;
        while (combat.active != null) {
            const age = combat.effectTicks();
            try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
            try std.testing.expectEqual(@as(u16, if (age < 504 or protected) 5000 else 3468), combat.enemy_hp[1]);
            try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
            try std.testing.expectEqual(@as(u8, if (age < 504) 9 else 8), combat.progress.party.at(0).rune_charges[3]);
            try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
            const reaction = combat.spellReaction(combat.partyCount() + 1);
            if (age < 303 or age >= 425) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
            if (age == 288) {
                const short_values: [32]u15 = @splat(0);
                var short_draws = rules.Draws{ .values = &short_values, .cursor = draws.cursor };
                const before = try stateBytes(combat);
                defer allocator.free(before);
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
                const after = try stateBytes(combat);
                defer allocator.free(after);
                try std.testing.expectEqualSlices(u8, before, after);
                try std.testing.expectEqual(draws.cursor, short_draws.cursor);
            }
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(@as(usize, 31 + 50) + 3 * mote_spawns, draws.cursor);
        try std.testing.expectEqual(@as(u16, 505), combat.action_ticks);
    }
}

test "generated Shining Wind heals cures and damages384 with distinct reactions and releases385" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    for ([_]bool{ false, true }) |protected| {
        var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
        defer fixture.deinit();
        for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
            profile.affinities = .{};
        };
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
            combat.encounter = i;
            combat.startEncounter();
            break;
        };
        combat.enemy_hp[0] = 0;
        if (protected) combat.actor_conditions[combat.partyCount() + 1].protection_rounds = 2;
        for (combat.progress.party.items(), 0..) |member, i| {
            member.max_hp = 1000;
            member.hp = if (i == 2) 0 else @intCast(10 + i);
            member.status = if (i == 2) .unconscious else .poisoned;
        }
        combat.actor_conditions[3].protection_rounds = 2;
        combat.actor_conditions[4].rune_blocked = true;
        combat.actor_conditions[4].accuracy_reduced = true;
        try combat.attachSpellScenes(&packet.value);
        combat.progress.party.at(0).rune = fixture.view.systems.?.runeIndex("cyclone");
        combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        const spell = for (fixture.view.systems.?.spells, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, "spell_31")) break i;
        } else unreachable;
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.phase = .resolving;
        var draws = rules.Draws{ .bios_state = 17 };
        combat.replay_draws = &draws;
        combat.nextAction();
        combat.replay_draws = null;
        try std.testing.expectEqual(@as(usize, 121), draws.cursor);
        while (combat.active != null) {
            const age = combat.effectTicks();
            try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
            try std.testing.expectEqual(@as(u16, if (age < 384 or protected) 5000 else 4468), combat.enemy_hp[1]);
            try std.testing.expectEqual(@as(u16, if (age < 384) 5000 else 4468), combat.enemy_hp[2]);
            if (age == 384) {
                const effect = combat.active.?;
                const first = @as(u16, 1) << @intCast(combat.partyCount() + 1);
                const second = @as(u16, 1) << @intCast(combat.partyCount() + 2);
                try std.testing.expectEqual(second | (if (protected) @as(u16, 0) else first), effect.spell_hp_loss);
                try std.testing.expectEqual(@as(u32, 500), effect.amounts[0]);
                try std.testing.expectEqual(@as(u32, if (protected) 0 else 532), effect.amounts[combat.partyCount() + 1]);
                try std.testing.expectEqual(@as(u32, 532), effect.amounts[combat.partyCount() + 2]);
            }
            for (combat.progress.party.items(), 0..) |member, i| {
                const hp: u16 = if (i == 2) 0 else @intCast(10 + i + @as(usize, if (age >= 384 and i != 3) 500 else 0));
                try std.testing.expectEqual(hp, member.hp);
                try std.testing.expectEqual(if (i == 2) field.game_state.Status.unconscious else if (age < 384) field.game_state.Status.poisoned else field.game_state.Status.healthy, member.status);
                if (i == 2) try std.testing.expect(combat.spellReaction(i) == null);
            }
            const ally = combat.spellReaction(0);
            const enemy = combat.spellReaction(combat.partyCount() + 1);
            if (age == 162) {
                try std.testing.expect(ally != null and enemy != null);
                try std.testing.expectEqualDeep([3]u8{ 255, 255, 64 }, ally.?.color);
            }
            if (age >= 354) try std.testing.expect(ally == null);
            if (age >= 337) try std.testing.expect(enemy == null);
            try std.testing.expectEqual(@as(u8, if (age < 384) 9 else 8), combat.progress.party.at(0).rune_charges[3]);
            if (age == 96) {
                const short_values: [123]u15 = @splat(0);
                var short_draws = rules.Draws{ .values = &short_values, .cursor = draws.cursor };
                const before = try stateBytes(combat);
                defer allocator.free(before);
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
                const after = try stateBytes(combat);
                defer allocator.free(after);
                try std.testing.expectEqualSlices(u8, before, after);
                try std.testing.expectEqual(draws.cursor, short_draws.cursor);
            }
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(@as(u16, 385), combat.action_ticks);
        try std.testing.expect(!combat.actor_conditions[4].rune_blocked and !combat.actor_conditions[4].accuracy_reduced);
    }
}

test "generated Explosion preserves RNG scale KO gaps protection damages448 and releases449" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
        profile.fire_affinity = .neutral;
        profile.affinities = .{};
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    combat.enemy_hp[0] = 0;
    combat.actor_conditions[combat.partyCount() + 2].protection_rounds = 2;
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_4")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("fire").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expectEqual(@as(usize, 71), draws.cursor);
    var first_flame: u16 = 320;
    var first_burst: u16 = 320;
    const initial = combat.active.?.scene.?.draws;
    for (0..15) |i| first_flame = @min(first_flame, 225 + initial[40 + 2 * i] % 96);
    for (0..20) |i| first_burst = @min(first_burst, 225 + initial[2 * i] % 72);
    var stop_draws: usize = 0;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, if (age < 448) 5000 else 4268), combat.enemy_hp[1]);
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
        try std.testing.expectEqual(@as(u8, if (age < 448) 9 else 8), combat.progress.party.at(0).rune_charges[3]);
        try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
        const reaction = combat.spellReaction(combat.partyCount() + 1);
        if (age < 257 or age >= 329) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 96 or age + 1 == @min(first_flame, first_burst)) {
            const short_values: [8192]u15 = @splat(0);
            const available: usize = if (age == 96 or first_flame <= first_burst) 2 else 3;
            var short_draws = rules.Draws{ .values = short_values[0 .. draws.cursor + available], .cursor = draws.cursor };
            const before = try stateBytes(combat);
            defer allocator.free(before);
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
            const after = try stateBytes(combat);
            defer allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
            try std.testing.expectEqual(draws.cursor, short_draws.cursor);
        }
        if (age == 320) stop_draws = draws.cursor;
        if (age >= 321) try std.testing.expectEqual(stop_draws, draws.cursor);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 449), combat.action_ticks);
}

test "generated Earthquake preserves bounce RNG KO gaps protection damages257 and releases321" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
        profile.fire_affinity = .neutral;
        profile.affinities = .{};
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    combat.enemy_hp[0] = 0;
    combat.actor_conditions[combat.partyCount() + 2].protection_rounds = 2;
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_24")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("earth").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expectEqual(@as(usize, 101), draws.cursor);
    var stop_draws: usize = 0;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, if (age < 257) 5000 else 4268), combat.enemy_hp[1]);
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
        try std.testing.expectEqual(@as(u8, if (age < 257) 9 else 8), combat.progress.party.at(0).rune_charges[3]);
        try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
        const reaction = combat.spellReaction(combat.partyCount() + 1);
        if (age < 159 or age >= 191) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 128 or age == 141) {
            const short_values: [8192]u15 = @splat(0);
            const available: usize = 2;
            var short_draws = rules.Draws{ .values = short_values[0 .. draws.cursor + available], .cursor = draws.cursor };
            const before = try stateBytes(combat);
            defer allocator.free(before);
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
            const after = try stateBytes(combat);
            defer allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
            try std.testing.expectEqual(draws.cursor, short_draws.cursor);
        }
        if (age == 256) stop_draws = draws.cursor;
        if (age >= 257) try std.testing.expectEqual(stop_draws, draws.cursor);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 321), combat.action_ticks);
}

test "generated Thunder God keeps radial draws KO gaps protection damage484 and release485" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
        profile.fire_affinity = .neutral;
        profile.affinities = .{};
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    combat.enemy_hp[0] = 0;
    combat.actor_conditions[combat.partyCount() + 2].protection_rounds = 2;
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_32")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("thunder").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expectEqual(@as(usize, 97), draws.cursor);
    var stop_draws: usize = 0;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, if (age < 484) 5000 else 4068), combat.enemy_hp[1]);
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
        try std.testing.expectEqual(@as(u8, if (age < 484) 9 else 8), combat.progress.party.at(0).rune_charges[3]);
        try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
        const reaction = combat.spellReaction(combat.partyCount() + 1);
        if (age < 357 or (age >= 391 and age < 393) or age >= 427) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 176 or age == 356) {
            const short_values: [8192]u15 = @splat(0);
            const available: usize = if (age == 176) 1 else 5;
            var short_draws = rules.Draws{ .values = short_values[0 .. draws.cursor + available], .cursor = draws.cursor };
            const before = try stateBytes(combat);
            defer allocator.free(before);
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
            const after = try stateBytes(combat);
            defer allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
            try std.testing.expectEqual(draws.cursor, short_draws.cursor);
        }
        if (age == 397) stop_draws = draws.cursor;
        if (age >= 398) try std.testing.expectEqual(stop_draws, draws.cursor);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 485), combat.action_ticks);
}

test "generated Final Flame keeps staged draws KO gaps protection damage584 and release586" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
        profile.fire_affinity = .neutral;
        profile.affinities = .{};
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    combat.enemy_hp[0] = 0;
    combat.actor_conditions[combat.partyCount() + 2].protection_rounds = 2;
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_29")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("rage").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expectEqual(@as(usize, 121), draws.cursor);
    var stop_draws: usize = 0;
    var focus_impulses: usize = 0;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, if (age < 584) 5000 else 4068), combat.enemy_hp[1]);
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
        try std.testing.expectEqual(@as(u8, if (age < 584) 9 else 8), combat.progress.party.at(0).rune_charges[3]);
        try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
        const reaction = combat.spellReaction(combat.partyCount() + 1);
        if (age < 229 or age >= 517) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age != 0 and combat.active.?.scene.?.last_landing == age) {
            const instance = &combat.active.?.scene.?;
            const expected = battle.spell_scene.instanceCameraAt(packet.value.spells[instance.spell].program.?, instance, age);
            try std.testing.expectEqualDeep(expected, battle.layout.currentCamera(combat));
            const base = battle.spell_scene.cameraAt(packet.value.spells[instance.spell].program.?, age, instance.initial_camera);
            try std.testing.expectEqual(base.focus[2] + 5, expected.focus[2]);
            try std.testing.expectEqualDeep(base, battle.layout.cameraForTransition(&combat));
            if (focus_impulses == 0) {
                var overlap = combat;
                overlap.enemy_magic_pulse = .{ .issued_at = overlap.camera_ticks -% 1, .delta_q12 = 7 * 4096 };
                var visible = expected;
                visible.focus[2] += 7;
                try std.testing.expectEqualDeep(visible, battle.layout.currentCamera(overlap));
                const frame = overlap.spellSceneFrame();
                const projected = battle.spell_scene.frameWithCamera(&packet.value, instance, age, visible);
                try std.testing.expect(projected.count > 0);
                try std.testing.expectEqualDeep(projected.commands[0..projected.count], frame.commands[0..frame.count]);
                overlap.holdSpellCamera();
                try std.testing.expectEqualDeep(base, overlap.source_camera_hold.?);
                overlap.camera_ticks +%= 1;
                try std.testing.expectEqualDeep(expected, battle.layout.currentCamera(overlap));
            }
            focus_impulses += 1;
        }
        if (age == 64 or age == 372) {
            const short_values: [8192]u15 = @splat(0);
            const available: usize = if (age == 64) 1 else 3;
            var short_draws = rules.Draws{ .values = short_values[0 .. draws.cursor + available], .cursor = draws.cursor };
            const before = try stateBytes(combat);
            defer allocator.free(before);
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
            const after = try stateBytes(combat);
            defer allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
            try std.testing.expectEqual(draws.cursor, short_draws.cursor);
        }
        if (age == 488) stop_draws = draws.cursor;
        if (age >= 489) try std.testing.expectEqual(stop_draws, draws.cursor);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 586), combat.action_ticks);
    try std.testing.expect(focus_impulses > 0);
}

test "generated Charm Arrow keeps erosion draws KO gaps protection damage224 and release225" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
        profile.affinities = .{};
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
        combat.encounter = i;
        combat.startEncounter();
        break;
    };
    combat.enemy_hp[0] = 0;
    combat.actor_conditions[combat.partyCount() + 2].protection_rounds = 2;
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_8")) break i;
    } else unreachable;
    combat.progress.party.at(0).rune = systems.runeIndex("resurrection").?;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
    var stop_draws: usize = 0;
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, if (age < 224) 5000 else 4468), combat.enemy_hp[1]);
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
        try std.testing.expectEqual(@as(u8, if (age < 224) 9 else 8), combat.progress.party.at(0).rune_charges[3]);
        try std.testing.expect(combat.spellReaction(combat.partyCount()) == null);
        const reaction = combat.spellReaction(combat.partyCount() + 1);
        if (age < 176 or age >= 176 + packet.value.spells[7].program.?.reaction.?.offsets.len) try std.testing.expect(reaction == null) else try std.testing.expect(reaction != null);
        if (age == 160 or age == 222) {
            const short_values: [65536]u15 = @splat(0);
            const available: usize = if (age == 160) 1 else 3;
            var short_draws = rules.Draws{ .values = short_values[0 .. draws.cursor + available], .cursor = draws.cursor };
            const before = try stateBytes(combat);
            defer allocator.free(before);
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
            const after = try stateBytes(combat);
            defer allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
            try std.testing.expectEqual(draws.cursor, short_draws.cursor);
        }
        if (age == 224) stop_draws = draws.cursor;
        if (age >= 225) try std.testing.expectEqual(stop_draws, draws.cursor);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 225), combat.action_ticks);
}

test "generated Voice of Earth keeps grounded motion protection airborne immunity damage320 and release322" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    for ([_]bool{ false, true }) |airborne| {
        var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
        defer fixture.deinit();
        for (fixture.profiles.?) |*profile| if (std.mem.eql(u8, profile.id, "bonbon")) {
            profile.affinities = .{};
            profile.airborne = airborne;
        };
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
            combat.encounter = i;
            combat.startEncounter();
            break;
        };
        combat.enemy_hp[0] = 0;
        const living = combat.partyCount() + 1;
        const protected = living + 1;
        combat.actor_conditions[protected].protection_rounds = 2;
        combat.actor_conditions[living].sleep_turns = 1;
        try combat.attachSpellScenes(&packet.value);
        const systems = combat.content.systems.?;
        const spell = for (systems.spells, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, "spell_22")) break i;
        } else unreachable;
        combat.progress.party.at(0).rune = systems.runeIndex("earth").?;
        combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        const casts: usize = if (airborne) 1 else 2;
        for (0..casts) |cast_index| {
            combat.actions = @splat(.defend);
            combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
            combat.acted = @splat(true);
            combat.acted[0] = false;
            combat.phase = .resolving;
            var draws = rules.Draws{ .bios_state = 17 };
            combat.replay_draws = &draws;
            combat.nextAction();
            combat.replay_draws = null;
            try std.testing.expect(combat.active.?.scene != null);
            while (combat.active != null) {
                const age = combat.effectTicks();
                try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
                try std.testing.expectEqual(@as(u16, @intCast(if (airborne) 5000 else 5000 - 332 * (cast_index + @intFromBool(age >= 320)))), combat.enemy_hp[1]);
                try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
                try std.testing.expectEqual(@as(u8, @intCast(9 - cast_index - @intFromBool(age >= 320))), combat.progress.party.at(0).rune_charges[1]);
                try std.testing.expectEqual(age >= 129 and age < 320, combat.hasBackgroundWarp());
                try std.testing.expect(combat.spellReaction(protected) == null);
                if (airborne) {
                    try std.testing.expectEqual(@as(i32, 4096), combat.actor_transforms[living].scale_q12);
                    try std.testing.expect(combat.spellReaction(living) == null);
                    try std.testing.expectEqual(@as(u8, 1), combat.actor_conditions[living].sleep_turns);
                } else {
                    const delta = packet.value.spells[21].program.?.actor_motion.?.size_delta[age];
                    try std.testing.expectEqual(@as(i32, @intCast(4096 + 85 * cast_index)) + delta, combat.actor_transforms[living].scale_q12);
                    if (age == 176) try std.testing.expectEqualDeep(battle.Position{ .x = -120, .y = 0, .z = 0 }, battle.layout.worldPosition(&combat, living));
                    if (age == 304) try std.testing.expectEqualDeep(battle.layout.homePosition(&combat, living), battle.layout.worldPosition(&combat, living));
                    try std.testing.expectEqual(age >= 273 and age < 305, combat.spellReaction(living) != null);
                }
                try combat.tickReplay(.{}, &draws);
            }
            try std.testing.expectEqual(@as(u16, 322), combat.action_ticks);
            try std.testing.expectEqual(@as(usize, 1), draws.cursor);
            try std.testing.expectEqual(@as(i32, if (airborne) 4096 else @intCast(4096 + 85 * (cast_index + 1))), combat.actor_transforms[living].scale_q12);
            try std.testing.expectEqualDeep(battle.Position{ .x = 0, .y = 0, .z = 0 }, combat.actor_transforms[living].world_offset);
        }
        if (airborne) continue;

        combat.enemy_hp[1] = 1;
        combat.enemy_hp[2] = 0;
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.phase = .resolving;
        var draws = rules.Draws{ .bios_state = 17 };
        combat.replay_draws = &draws;
        combat.nextAction();
        combat.replay_draws = null;
        for (0..500) |_| {
            if (combat.phase == .victory) break;
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(.victory, combat.phase);
        try std.testing.expect(combat.action_ticks > 322);
    }
}

test "generated Deadly Fingertips keeps retargeting immunity result306 charge and cleanup367" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    const Case = struct { immune: bool, protected: bool };
    for ([_]Case{ .{ .immune = false, .protected = false }, .{ .immune = true, .protected = false }, .{ .immune = false, .protected = true } }) |case| {
        var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
        defer fixture.deinit();
        for (fixture.profiles.?) |*profile| profile.death_immune = case.immune;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
            combat.encounter = i;
            combat.startEncounter();
            break;
        };
        combat.enemy_hp[0] = 0;
        const target = combat.partyCount() + 1;
        if (case.protected) combat.actor_conditions[target].protection_rounds = 2;
        try combat.attachSpellScenes(&packet.value);
        const systems = combat.content.systems.?;
        const spell = for (systems.spells, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, "spell_25")) break i;
        } else unreachable;
        // Test attachment does not open the campaign's Soul Eater story gate.
        const runes = try allocator.alloc(rules.Rune, systems.runes.len + 1);
        defer allocator.free(runes);
        @memcpy(runes[0..systems.runes.len], systems.runes);
        runes[systems.runes.len] = .{ .id = "soul_eater", .name = "Soul Eater", .spell_names = .{ systems.spells[spell].name, "-", "-", "-" }, .spells = .{ spell, null, null, null } };
        var view = systems;
        view.runes = runes;
        combat.content.systems = view;
        combat.progress.party.at(0).rune = systems.runes.len;
        combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.phase = .resolving;
        var draws = rules.Draws{ .bios_state = 17 };
        combat.replay_draws = &draws;
        combat.nextAction();
        combat.replay_draws = null;
        try std.testing.expectEqual(target, combat.active.?.target);
        try std.testing.expect(combat.active.?.scene != null);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        var stopped: usize = 0;
        while (combat.active != null) {
            const age = combat.effectTicks();
            try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
            try std.testing.expectEqual(@as(u16, if (age < 306 or case.immune) 5000 else 0), combat.enemy_hp[1]);
            try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[2]);
            try std.testing.expectEqual(@as(u8, if (age < 306) 9 else 8), combat.progress.party.at(0).rune_charges[0]);
            try std.testing.expectEqual(age >= 97 and age < 306, combat.hasBackgroundWarp());
            if (age >= 306 and !case.immune) {
                try std.testing.expect(combat.active.?.instant_knockouts & (@as(u16, 1) << @intCast(target)) != 0);
                try std.testing.expect(!combat.spellReaction(target).?.visible);
                try std.testing.expectEqual(@as(u16, 367), combat.actionDuration());
            }
            if (age < 306) try std.testing.expectEqual(age >= 246 and age < 278, combat.spellReaction(target) != null);
            if (age == 96) {
                const short_values: [8192]u15 = @splat(0);
                var short_draws = rules.Draws{ .values = short_values[0 .. draws.cursor + 3], .cursor = draws.cursor };
                const before = try stateBytes(combat);
                defer allocator.free(before);
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short_draws));
                const after = try stateBytes(combat);
                defer allocator.free(after);
                try std.testing.expectEqualSlices(u8, before, after);
                try std.testing.expectEqual(draws.cursor, short_draws.cursor);
            }
            if (age == 305) stopped = draws.cursor;
            if (age >= 306) try std.testing.expectEqual(stopped, draws.cursor);
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(@as(u16, 367), combat.action_ticks);
        try std.testing.expect(draws.cursor > 1);
        try std.testing.expectEqual(@as(usize, 0), (draws.cursor - 1) % 5);
    }
}

test "Scolding replacement uses the normal owner and commits only at source impact" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const packet = try battle.spell_scene.load(allocator, bytes);
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    try combat.attachSpellScenes(&packet.value);
    const systems = combat.content.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "spell_5")) break i;
    } else unreachable;
    // Test-only attachment exercises the source effect without changing the playable rune table.
    const runes = [_]rules.Rune{.{ .id = "fire", .name = "Fire", .spell_names = .{ "Scolding", "-", "-", "-" }, .spells = .{ spell, null, null, null } }};
    var view = systems;
    view.runes = &runes;
    combat.content.systems = view;
    combat.progress.party.at(0).rune = 0;
    combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.phase = .resolving;
    var draws = rules.Draws{ .bios_state = 17 };
    combat.replay_draws = &draws;
    combat.nextAction();
    combat.replay_draws = null;
    try std.testing.expect(combat.active.?.scene != null);
    try std.testing.expect(combat.active.?.scene.?.target_height > 0);
    while (combat.active != null) {
        const age = combat.effectTicks();
        try std.testing.expectEqual(@as(u8, if (age < 256) 9 else 8), combat.progress.party.at(0).rune_charges[0]);
        if (age < 256) try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[0]) else try std.testing.expect(combat.enemy_hp[0] < 5000);
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(u16, 257), combat.action_ticks);
}

test "approved Soul casts use the canonical library and preserve outcomes charges and rollback" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(battle.spell_scene.max_file_size));
    defer allocator.free(bytes);
    const library = try battle.spell_scene.load(allocator, bytes);
    defer library.deinit();
    const packet = &library.value;
    for ([_][]const u8{ "spell_26", "spell_27" }) |id| {
        try std.testing.expect(packet.indexOf(id) != null);
        const hell = std.mem.eql(u8, id, "spell_27");
        const impact: u16 = if (hell) 436 else 310;
        const owner: u16 = if (hell) 497 else 311;
        const tier: usize = if (hell) 2 else 1;
        for ([_]u16{ 5000, 100 }) |hp| for ([_]bool{ false, true }) |immune| {
            var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = hp });
            defer fixture.deinit();
            for (fixture.profiles.?) |*profile| {
                profile.affinities = .{};
                profile.death_immune = immune;
            }
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
            combat.integration = .{ .host = host };
            for (combat.content.encounters, 0..) |encounter, i| if (encounter.enemies.len == 3 and std.mem.eql(u8, encounter.enemies[0], "bonbon")) {
                combat.encounter = i;
                combat.startEncounter();
                break;
            };
            combat.enemy_hp[0] = 0;
            const living = combat.partyCount() + 1;
            const protected = living + 1;
            combat.actor_conditions[protected].protection_rounds = 2;
            try combat.attachSpellScenes(packet);
            const systems = combat.content.systems.?;
            const spell = for (systems.spells, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.id, id)) break i;
            } else unreachable;
            // Test-only rune attachment preserves the campaign Soul Eater story gate.
            const runes = try allocator.alloc(rules.Rune, systems.runes.len + 1);
            defer allocator.free(runes);
            @memcpy(runes[0..systems.runes.len], systems.runes);
            runes[systems.runes.len] = .{ .id = "soul_eater", .name = "Soul Eater", .spell_names = .{ "-", "-", "-", "-" }, .spells = @splat(null) };
            runes[systems.runes.len].spells[tier] = spell;
            runes[systems.runes.len].spell_names[tier] = systems.spells[spell].name;
            var view = systems;
            view.runes = runes;
            combat.content.systems = view;
            combat.progress.party.at(0).rune = systems.runes.len;
            combat.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
            combat.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
            combat.actions = @splat(.defend);
            combat.actions[0] = .{ .spell = .{ .index = spell, .target = 0 } };
            combat.acted = @splat(true);
            combat.acted[0] = false;
            combat.phase = .resolving;
            var draws = rules.Draws{ .bios_state = 17 };
            combat.replay_draws = &draws;
            combat.nextAction();
            combat.replay_draws = null;
            try std.testing.expect(combat.active.?.scene != null);
            try std.testing.expectEqual(@as(usize, 1), draws.cursor);
            while (combat.active != null) {
                const age = combat.effectTicks();
                const ko = if (hell) !immune else hp < 332;
                try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
                try std.testing.expectEqual(if (age < impact) hp else if (hell) (if (immune) hp else 0) else hp -| 332, combat.enemy_hp[1]);
                try std.testing.expectEqual(if (hell and !immune and age >= impact) @as(u16, 0) else hp, combat.enemy_hp[2]);
                for (0..4) |slot| try std.testing.expectEqual(@as(u8, if (slot == tier and age >= impact) 8 else 9), combat.progress.party.at(0).rune_charges[slot]);
                const capture: ?u16 = if (age < 97) null else if (!hell) (if (age < 250) 382 else null) else if (age < 317) 381 else if (age < 436) 8 else null;
                try std.testing.expectEqual(capture, combat.backgroundCaptureMinimum());
                if (age >= impact) {
                    try std.testing.expectEqual(hell and ko, combat.active.?.instant_knockouts & (@as(u16, 1) << @intCast(living)) != 0);
                    try std.testing.expectEqual(@as(u16, if (!hell and ko) 404 else owner), combat.actionDuration());
                    if (hell and ko) try std.testing.expect(!combat.spellReaction(living).?.visible);
                    if (!hell and ko and age == impact) try std.testing.expect(combat.spellReaction(living).?.visible);
                }
                if (age == 96) {
                    const short_values: [8192]u15 = @splat(0);
                    var short = rules.Draws{ .values = short_values[0 .. draws.cursor + 3], .cursor = draws.cursor };
                    const before = try stateBytes(combat);
                    defer allocator.free(before);
                    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short));
                    const after = try stateBytes(combat);
                    defer allocator.free(after);
                    try std.testing.expectEqualSlices(u8, before, after);
                    try std.testing.expectEqual(draws.cursor, short.cursor);
                }
                try combat.tickReplay(.{}, &draws);
            }
            try std.testing.expectEqual(@as(u16, if (!hell and hp < 332) 404 else owner), combat.action_ticks);
        };
    }
}
