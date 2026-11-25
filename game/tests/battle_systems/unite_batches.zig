const std = @import("std");
const h = @import("helpers.zig");
const allocator = h.allocator;
const hostFixture = h.hostFixture;
const Fixture = h.Fixture;
const battle = h.battle;
const rules = h.rules;
const field = h.field;
const Tape = h.Tape;

test "Fisherman action camera inherits the selected round block for either owner" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try h.journeyScenes(arena.allocator(), effects.value);
    var view = content.value;
    view.initial_party = &.{ "tai_ho", "gremio", "pahn", "viktor", "yam_koo", "hero" };
    const encounter = for (view.encounters, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id, "area_b_3")) break index;
    } else return error.MissingViewportFixture;
    const target = 3;
    try std.testing.expectEqualDeep(battle.Position{ .x = -168, .y = 60, .z = 0 }, view.encounters[encounter].positions[target]);

    const round_scales = [_]i32{ 2816, 4096, 5376 };
    const round_angles = [_][3]i32{ .{ -704, 0, 640 }, .{ -768, 0, 608 }, .{ -864, 0, 800 } };
    for ([_]usize{ 0, 4 }) |owner| for (round_scales, round_angles, 0..) |scale, angles, choice| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.encounter = encounter;
        combat.startEncounter();
        combat.round = 2;
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&packet);
        combat.choose(owner);
        combat.queue(.{ .unite = target });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        while (combat.phase == .command) combat.queue(.defend);
        var tape: Tape = .{};
        var draws = tape.init();
        tape.values[0] = @intCast(choice);
        try combat.tickReplay(.{ .confirm = true }, &draws);
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(?u8, @intCast(choice)), combat.round_camera_choice);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        try std.testing.expectEqual([4]u16{ 29, 29, 29, 29 }, combat.actor_camera.?.remaining);
        combat.acted = @splat(true);
        combat.acted[owner] = false;
        const next_actor = combat.partyCount();
        for (0..180) |_| {
            try combat.tickReplay(.{}, &draws);
            if (!combat.hasLiveUniteActors()) continue;
            if (combat.effectTicks() == 0) combat.acted[next_actor] = false;
            if (combat.effectTicks() == 12) {
                var without_request = combat;
                without_request.actor_camera = null;
                const action_camera = battle.layout.currentCamera(without_request);
                without_request.active = null;
                try std.testing.expectEqual(battle.layout.currentCamera(without_request), action_camera);
            }
            if (combat.effectTicks() == 83) break;
        } else return error.MissingUniteImpact;

        const camera = battle.layout.currentCamera(combat);
        try std.testing.expectEqual([3]i32{ -168, 60, 0 }, camera.focus);
        try std.testing.expectEqual(angles, camera.angles);
        try std.testing.expectEqual([3]i32{ scale, scale, scale }, camera.scale);
        if (choice == 0) for ([_]usize{ 0, 4 }) |member| {
            const layout = battle.layout.actorLayout(combat, member);
            const left = layout.point.x - @as(f32, @floatFromInt(layout.sprite.anchor_x)) * layout.scale;
            const right = left + @as(f32, @floatFromInt(layout.sprite.rect.w)) * layout.scale;
            const top = layout.point.y - @as(f32, @floatFromInt(layout.sprite.anchor_y)) * layout.scale;
            const bottom = top + @as(f32, @floatFromInt(layout.sprite.rect.h)) * layout.scale;
            try std.testing.expect(left >= 8 and right <= 632);
            try std.testing.expect(top >= battle.layout.viewport_top and bottom <= battle.layout.viewport_top + battle.layout.viewport_height);
        };

        for (0..40) |_| {
            try combat.tickReplay(.{}, &draws);
            if (combat.coordinator.?.stage == .check) break;
        } else return error.MissingFollowingAction;
        try std.testing.expectEqual(next_actor, combat.coordinator.?.cached.?.actor);
        try std.testing.expect(combat.active == null and combat.hasUniteReturns());
        try std.testing.expect(combat.coordinator.?.cross_side_pending and combat.coordinator.?.completed);
        const before = combat.actor_camera.?;
        try std.testing.expectEqual([4]u16{ 0, 0, 0, 0 }, before.remaining);
        const round_x = if (choice == 0) @as(i32, -32 * 4096) else 0;
        const cursor = draws.cursor;

        combat.coordinator.?.completed = false;
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(.check, combat.coordinator.?.stage);
        try std.testing.expectEqualDeep(before, combat.actor_camera.?);

        combat.coordinator.?.completed = true;
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(.dispatch, combat.coordinator.?.stage);
        try std.testing.expectEqual(next_actor, combat.coordinator.?.current_actor);
        try std.testing.expect(combat.hasUniteReturns());
        try std.testing.expectEqual(cursor, draws.cursor);
        try std.testing.expectEqual([4]u16{ 19, 19, 19, 19 }, combat.actor_camera.?.remaining);
        try std.testing.expectEqual([3]i32{ round_x, 0, 0 }, combat.actor_camera.?.target[0]);
        try std.testing.expectEqual(before.current[0][0] + @divTrunc(round_x - before.current[0][0], 20), combat.actor_camera.?.current[0][0]);
    };
}

test "Warriors owners play the orbit reaction and source damage clock" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/warriors_battle.json"));
    defer content.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/warriors_actor_library.json"));
    defer library.deinit();
    const journey_content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer journey_content.deinit();
    const journey_library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer journey_library.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const SceneFixture = struct { scene: battle.spell_scene.Spell, reaction: battle.spell_scene.UniteReaction };
    const fixture = try std.json.parseFromSlice(SceneFixture, allocator, @embedFile("../fixtures/unite_warriors_scene.json"), .{});
    defer fixture.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var packet = effects.value;
    const scenes = try allocator.alloc(battle.spell_scene.Spell, packet.unite_scenes.len + 1);
    defer allocator.free(scenes);
    @memcpy(scenes[0..packet.unite_scenes.len], packet.unite_scenes);
    scenes[scenes.len - 1] = fixture.value.scene;
    packet.unite_scenes = scenes;
    const reactions = try allocator.alloc(battle.spell_scene.UniteReaction, packet.unite_reactions.len + 1);
    defer allocator.free(reactions);
    @memcpy(reactions[0..packet.unite_reactions.len], packet.unite_reactions);
    reactions[reactions.len - 1] = fixture.value.reaction;
    packet.unite_reactions = reactions;
    try library.value.validate();
    try packet.validate(4096, 4096);
    const bindings = try allocator.dupe(battle.actor_host.UniteBinding, library.value.unites);
    defer allocator.free(bindings);
    var invalid = library.value;
    invalid.unites = bindings;
    invalid.schema = "suikoden-unite-actors/25";
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    invalid.schema = library.value.schema;
    const original = bindings[15];
    bindings[15].controller.?.orbit.?.divisor = 0;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    bindings[15] = original;
    bindings[15].controller.?.orbit.?.anchor_member = 2;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    bindings[15] = original;
    bindings[15].controller.?.recipient_at = 0;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    bindings[15] = original;
    for (0..8) |case| {
        const owner = case % 2;
        const protected = case % 4 >= 2;
        var view = if (case < 4) content.value else journey_content.value;
        view.initial_party = content.value.initial_party;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(if (case < 4) &library.value else &journey_library.value);
        try combat.attachSpellScenes(&packet);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 15;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        combat.action_ticks = 100;
        const target = combat.partyCount();
        if (protected) combat.actor_conditions[target].protection_rounds = 1;
        const hp = combat.enemy_hp[0];
        var tape = Tape{};
        var draws = tape.init();
        if (case == 0) {
            var refused = combat;
            var missing = packet;
            missing.unite_reactions = reactions[0 .. reactions.len - 1];
            refused.spell_scenes = &missing;
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
        }
        var saw: u8 = 0;
        var previous_x: ?i32 = null;
        var velocity: ?i32 = null;
        for (0..600) |_| {
            const previous_hix = combat.unite_vm.actors[1].position_q12;
            const previous_target = combat.uniteReactionOriginQ12(target);
            const previous_elapsed = if (combat.active) |effect| if (effect.scene) |scene| scene.elapsed else 0 else 0;
            if (case == 0 and previous_elapsed == 64) {
                // A scene can advance independently once its actors return.
                var tail = combat;
                tail.unite_vm.members = @splat(null);
                tail.unite_vm.auxiliary = @splat(null);
                try std.testing.expect(!tail.unite_vm.hasActors());
                tail.camera_ticks +%= 1;
                tail.advanceUniteActors();
                try std.testing.expectEqual(@as(u16, 65), tail.active.?.scene.?.elapsed);
                try std.testing.expectEqualSlices(battle.unite_playback.Sound, &.{.{ .actor = @intCast(owner), .id = 0x524 }}, tail.unite_vm.takeSounds());
                tail.advanceUniteActors();
                try std.testing.expectEqual(@as(usize, 0), tail.unite_vm.takeSounds().len);
            }
            try combat.tickReplay(.{}, &draws);
            if (previous_elapsed == 127 and combat.active == null) {
                if (protected) try std.testing.expectEqual(hp, combat.enemy_hp[0]) else try std.testing.expect(combat.enemy_hp[0] < hp);
                saw |= 8;
            }
            if (combat.unite_scene) |scene| if (scene.started_at != null and combat.active != null) {
                const elapsed = combat.active.?.scene.?.elapsed;
                if (elapsed == 1) {
                    try std.testing.expectEqualDeep([3]i32{ previous_hix[0], previous_hix[1], previous_hix[2] - 60 * 4096 }, scene.orbit_origin_q12);
                    saw |= 1;
                }
                if (elapsed == 64) previous_x = scene.orbit_origin_q12[0];
                if (elapsed == 65) {
                    velocity = @divTrunc(previous_target[0] - previous_x.?, 16);
                    try std.testing.expectEqual(previous_x.? + velocity.?, scene.orbit_origin_q12[0]);
                    try std.testing.expectEqual(@as(i32, -60 * 4096), scene.orbit_origin_q12[2]);
                    saw |= 2;
                }
                if (elapsed >= 65 and elapsed <= 96) {
                    const orbit = library.value.find(15).?.controller.?.orbit.?;
                    const age = elapsed - 65;
                    try std.testing.expectEqual(previous_x.? + velocity.? * (@as(i32, age) + 1), scene.orbit_origin_q12[0]);
                    try std.testing.expectEqual(orbit.base_z_q12 + orbit.heights_q12[age], scene.orbit_origin_q12[2]);
                }
                if (elapsed == 81) {
                    try std.testing.expectEqual(@as(i32, 40 * 4096 - 60 * 4096), scene.orbit_origin_q12[2]);
                    try std.testing.expect(combat.unite_reactions[target] != null);
                    try std.testing.expectEqual(@as(u8, 1), combat.unite_reactions[target].?.variant);
                    saw |= 4;
                }
                if (elapsed < 128) try std.testing.expectEqual(hp, combat.enemy_hp[0]);
                if (elapsed == 128) {
                    if (protected) try std.testing.expectEqual(hp, combat.enemy_hp[0]) else try std.testing.expect(combat.enemy_hp[0] < hp);
                    saw |= 8;
                }
                for ([_]struct { elapsed: u16, sound: u16, bit: u8 }{
                    .{ .elapsed = 1, .sound = 0x81f, .bit = 16 },
                    .{ .elapsed = 65, .sound = 0x524, .bit = 32 },
                    .{ .elapsed = 81, .sound = 0x521, .bit = 64 },
                }) |event| if (elapsed == event.elapsed) {
                    const found = for (combat.unite_vm.sounds[0..combat.unite_vm.sound_count]) |sound| {
                        if (sound.id == event.sound) break true;
                    } else false;
                    try std.testing.expect(found);
                    try std.testing.expectEqual(event.sound, combat.unite_vm.sounds[0].id);
                    saw |= event.bit;
                };
            };
            if (combat.uniteBoundaryFor(owner) == null) break;
        }
        try std.testing.expectEqual(@as(u8, 127), saw);
        try std.testing.expect(combat.uniteBoundaryFor(owner) == null);
    }
}

test "Couple owners play the source handoff palette cycle and target impact" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/couple_battle.json"));
    defer content.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/couple_actor_library.json"));
    defer library.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var packet = effects.value;
    const clips = try allocator.alloc(battle.spell_scene.UniteImpact, packet.unite_impacts.len + 1);
    defer allocator.free(clips);
    @memcpy(clips[0..packet.unite_impacts.len], packet.unite_impacts);
    clips[clips.len - 1] = .{ .id = 6, .frames = &.{ .{ .entry = 15, .ticks = 6 }, .{ .entry = 16, .ticks = 6 }, .{ .entry = 17, .ticks = 8 }, .{ .entry = 18, .ticks = 10 } } };
    packet.unite_impacts = clips;
    packet.schema = "suikoden-spell-scenes/48";
    for (0..2) |owner| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&packet);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 16;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        combat.action_ticks = 100;
        var tape = Tape{};
        var draws = tape.init();
        const hp = combat.enemy_hp[0];
        if (owner == 0) {
            var refused = combat;
            var graphics: [64]battle.UniteGraphic = undefined;
            @memcpy(graphics[0..content.value.unite_graphics.len], content.value.unite_graphics);
            var poses: [256]battle.UniteGraphicPose = undefined;
            for (graphics[0..content.value.unite_graphics.len]) |*graphic| if (std.mem.eql(u8, graphic.id, "lepant")) {
                @memcpy(poses[0..graphic.poses.len], graphic.poses);
                for (poses[0..graphic.poses.len]) |*pose| pose.flash = null;
                graphic.poses = poses[0..graphic.poses.len];
            };
            refused.content.unite_graphics = graphics[0..content.value.unite_graphics.len];
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
            var missing_packet = packet;
            missing_packet.unite_impacts = clips[0 .. clips.len - 1];
            refused = combat;
            refused.spell_scenes = &missing_packet;
            refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
        }
        var saw_transition = false;
        var saw_flash = false;
        var saw_impact = false;
        var frames_seen: u8 = 0;
        var origin: ?[3]i32 = null;
        for (0..400) |_| {
            try combat.tickReplay(.{}, &draws);
            if (combat.unite_vm.members[1]) |member| {
                if (std.mem.eql(u8, library.value.programs.programs[member.program].id, "lepant/unite_10")) saw_transition = true;
                const palette = combat.unite_vm.actors[1].palette;
                if (palette == .shared and palette.shared >= 1 and palette.shared <= 3) {
                    const pose = combat.unite_vm.pose(1).?;
                    try std.testing.expectEqualDeep(content.value.uniteFlashGraphic("lepant", pose, palette.shared).?, combat.uniteVmPose(1).?);
                    saw_flash = true;
                }
            }
            if (combat.active) |effect| if (effect.unite_impact_effect) |impact| {
                if (origin) |expected| try std.testing.expectEqualDeep(expected, impact.origin_q12) else origin = impact.origin_q12;
                if (impact.started_at != null) {
                    try std.testing.expect(combat.enemy_hp[0] < hp);
                    const age = combat.camera_ticks - impact.started_at.?;
                    const expected: u16 = if (age < 5) 15 else if (age < 11) 16 else if (age < 19) 17 else 18;
                    const frame = combat.spellSceneFrame();
                    if (age < 29) {
                        const found = for (frame.commands[0..frame.count]) |command| {
                            if (command.texture == expected) break true;
                        } else false;
                        try std.testing.expect(found);
                        frames_seen |= @as(u8, 1) << @intCast(expected - 15);
                    }
                    saw_impact = true;
                }
            };
            if (combat.uniteBoundaryFor(owner) == null) break;
        }
        try std.testing.expect(saw_transition and saw_flash and saw_impact);
        try std.testing.expectEqual(@as(u8, 15), frames_seen);
        try std.testing.expect(combat.uniteBoundaryFor(owner) == null);
    }
}

test "ordinary journey export runs Flash Master pupil and Couple with its own actor library" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer library.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const flash = try std.json.parseFromSlice(battle.spell_scene.Program, allocator, @embedFile("../fixtures/flash_scene_program.json"), .{});
    defer flash.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var packet = effects.value;
    const scenes = try allocator.alloc(battle.spell_scene.Spell, packet.unite_scenes.len + 1);
    defer allocator.free(scenes);
    @memcpy(scenes[0..packet.unite_scenes.len], packet.unite_scenes);
    scenes[scenes.len - 1] = .{ .id = "flash", .name = "Flash Attack", .program = flash.value };
    packet.unite_scenes = scenes;
    const clips = try allocator.alloc(battle.spell_scene.UniteImpact, packet.unite_impacts.len + 1);
    defer allocator.free(clips);
    @memcpy(clips[0..packet.unite_impacts.len], packet.unite_impacts);
    clips[clips.len - 1] = .{ .id = 6, .frames = &.{ .{ .entry = 15, .ticks = 6 }, .{ .entry = 16, .ticks = 6 }, .{ .entry = 17, .ticks = 8 }, .{ .entry = 18, .ticks = 10 } } };
    packet.unite_impacts = clips;
    packet.schema = "suikoden-spell-scenes/48";
    const parties = [_][6][]const u8{
        .{ "liukan", "fukien", "kai", "hero", "gremio", "pahn" },
        .{ "hero", "kai", "gremio", "pahn", "viktor", "yam_koo" },
        .{ "eileen", "lepant", "hero", "gremio", "pahn", "viktor" },
        .{ "eileen", "lepant", "hero", "gremio", "pahn", "viktor" },
    };
    for (parties, [_]u8{ 10, 31, 16, 16 }, [_]usize{ 0, 0, 0, 1 }) |party, record, owner| {
        var view = content.value;
        view.initial_party = &party;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        combat.encounter = 1;
        combat.startEncounter();
        for (0..combat.enemyCount()) |enemy| combat.enemy_hp[enemy] = 5000;
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&packet);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = record;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        combat.action_ticks = 100;
        var tape = Tape{};
        var draws = tape.init();
        var hit = false;
        for (0..700) |_| {
            try combat.tickReplay(.{}, &draws);
            if (combat.enemy_hp[0] < 5000) hit = true;
            if (combat.uniteBoundaryFor(owner) == null) break;
        }
        try std.testing.expect(hit and combat.uniteBoundaryFor(owner) == null);
    }
}

test "journey Eileen uses source ranged art and projectile on an ordinary attack" {
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer library.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var view = content.value;
    view.initial_party = &.{ "eileen", "lepant", "hero", "gremio", "pahn", "viktor" };
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(view, items.value, &members, 17);
    combat.encounter = for (view.encounters, 0..) |encounter, index| {
        if (std.mem.eql(u8, encounter.id, "area_a_4")) break index;
    } else return error.MissingSourceEncounter;
    combat.startEncounter();
    try combat.attachUniteActors(&library.value);
    try combat.attachSpellScenes(&effects.value);
    var preflight = combat;
    try preflight.beginRanged(0, 6, true, false);
    preflight = combat;
    try preflight.beginRanged(0, 6, false, false);
    try std.testing.expect(combat.canAttackTarget(0, 0));
    preflight = combat;
    preflight.unite_actors = null;
    try std.testing.expect(!preflight.canAttackTarget(0, 0));
    combat.enterRoundMenu();
    combat.choose(0);
    combat.queue(.{ .attack = 0 });
    try std.testing.expect(combat.actions[0] != null and combat.actions[0].? == .attack);
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
    var values: [256]u15 = @splat(99);
    values[0] = 0;
    values[2] = 24;
    var draws = rules.Draws{ .values = &values };
    const hp = combat.enemy_hp[0];
    var projectile = false;
    var selected_packet_pose = false;
    for (0..400) |_| {
        try combat.tickReplay(.{}, &draws);
        if (combat.unite_vm.hasAuxiliary()) projectile = true;
        if (combat.unite_vm.scripted_actors[0] != null) {
            const pose = combat.unite_vm.actors[0].currentFrame().pose;
            if (view.ordinaryActorGraphic("eileen", pose)) |expected| {
                try std.testing.expectEqualDeep(expected, combat.physicalRunePose(0).?);
                selected_packet_pose = true;
            }
        }
        if (combat.enemy_hp[0] < hp and !combat.unite_vm.hasCounter()) break;
    }
    try std.testing.expect(projectile and selected_packet_pose and combat.enemy_hp[0] < hp);
}

test "journey Trick members use source ranged art and projectiles on ordinary attacks" {
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer library.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const Impact = struct { clip: battle.spell_scene.UniteImpact, entries: []const battle.spell_scene.Entry };
    const impact = try std.json.parseFromSlice(Impact, allocator, @embedFile("../fixtures/trick_ranged_impact.json"), .{});
    defer impact.deinit();
    var packet = effects.value;
    packet.schema = "suikoden-spell-scenes/48";
    const entries = try allocator.alloc(battle.spell_scene.Entry, packet.entries.len + impact.value.entries.len);
    defer allocator.free(entries);
    @memcpy(entries[0..packet.entries.len], packet.entries);
    @memcpy(entries[packet.entries.len..], impact.value.entries);
    const frames = try allocator.dupe(@TypeOf(impact.value.clip.frames[0]), impact.value.clip.frames);
    defer allocator.free(frames);
    for (frames) |*frame| frame.entry += @intCast(packet.entries.len);
    const clips = try allocator.alloc(battle.spell_scene.UniteImpact, packet.unite_impacts.len + 1);
    defer allocator.free(clips);
    @memcpy(clips[0..packet.unite_impacts.len], packet.unite_impacts);
    clips[clips.len - 1] = .{ .id = 3, .frames = frames };
    packet.entries = entries;
    packet.unite_impacts = clips;
    for ([_][]const u8{ "meg", "juppo" }) |identifier| {
        var view = content.value;
        view.initial_party = &.{ identifier, "hero", "gremio", "pahn", "viktor", "tai_ho" };
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.encounter = for (view.encounters, 0..) |encounter, index| {
            if (std.mem.eql(u8, encounter.id, "area_a_4")) break index;
        } else return error.MissingSourceEncounter;
        combat.startEncounter();
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&packet);
        var preflight = combat;
        try preflight.beginRanged(0, 6, true, false);
        preflight = combat;
        try preflight.beginRanged(0, 6, false, false);
        try std.testing.expect(combat.canAttackTarget(0, 0));
        preflight = combat;
        preflight.unite_actors = null;
        try std.testing.expect(!preflight.canAttackTarget(0, 0));
        combat.enterRoundMenu();
        combat.choose(0);
        combat.queue(.{ .attack = 0 });
        try std.testing.expect(combat.actions[0] != null and combat.actions[0].? == .attack);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
        var values: [256]u15 = @splat(99);
        values[0] = 0;
        values[2] = 24;
        var draws = rules.Draws{ .values = &values };
        const hp = combat.enemy_hp[0];
        var projectile = false;
        var selected_packet_pose = false;
        for (0..400) |_| {
            try combat.tickReplay(.{}, &draws);
            if (combat.unite_vm.hasAuxiliary()) projectile = true;
            if (combat.unite_vm.scripted_actors[0] != null) {
                const pose = combat.unite_vm.actors[0].currentFrame().pose;
                if (view.uniteGraphic(identifier, pose)) |expected| {
                    try std.testing.expectEqualDeep(expected, combat.physicalRunePose(0).?);
                    selected_packet_pose = true;
                }
            }
            if (combat.enemy_hp[0] < hp and !combat.unite_vm.hasCounter()) break;
        }
        try std.testing.expect(projectile);
        try std.testing.expect(selected_packet_pose);
        try std.testing.expect(combat.enemy_hp[0] < hp);
    }
}

test "Master pupil source programs claim targets and repeat independently" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/master_pupil_battle.json"));
    defer content.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/master_pupil_actor_library.json"));
    defer library.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    try library.value.validate();
    const bindings = try allocator.dupe(battle.actor_host.UniteBinding, library.value.unites);
    defer allocator.free(bindings);
    const member_bindings = try allocator.dupe(battle.actor_host.MemberBinding, bindings[31].members);
    defer allocator.free(member_bindings);
    bindings[31].members = member_bindings;
    var invalid = library.value;
    invalid.unites = bindings;
    member_bindings[0].loop_program = null;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    invalid = library.value;
    invalid.schema = "suikoden-unite-actors/22";
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    for (0..4) |scenario_index| {
        const owner = scenario_index % 2;
        const single_target = scenario_index >= 2;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.integration = .{ .host = host };
        combat.encounter = 1;
        combat.startEncounter();
        try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&effects.value);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 31;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        if (single_target) {
            combat.enemy_hp[1] = 0;
            combat.enemy_hp[2] = 0;
        }
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        var tape = Tape{};
        var draws = tape.init();
        if (scenario_index == 0) {
            var rotated = combat;
            var rotated_members: [6]battle.Member = undefined;
            @memcpy(&rotated_members, combat.progress.party);
            rotated.progress.party = &rotated_members;
            rotated.actor_transforms[0].node_angles[2] = 1;
            var rotated_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, rotated.tickReplay(.{}, &rotated_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, rotated.unite_vm);
            try std.testing.expectEqual(draws.cursor, rotated_draws.cursor);
        }
        try combat.tickReplay(.{}, &draws);
        const selection_tick = combat.camera_ticks;
        try std.testing.expect(combat.hasLiveUniteActors());
        if (scenario_index == 0) {
            var rotated = combat;
            var rotated_members: [6]battle.Member = undefined;
            @memcpy(&rotated_members, combat.progress.party);
            rotated.progress.party = &rotated_members;
            rotated.actor_transforms[1].node_angles[0] = 1;
            var rotated_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, rotated.tickReplay(.{}, &rotated_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, rotated.unite_vm);
            try std.testing.expectEqual(draws.cursor, rotated_draws.cursor);
        }
        if (scenario_index == 0) {
            var empty = combat;
            var copied_members: [6]battle.Member = undefined;
            @memcpy(&copied_members, combat.progress.party);
            empty.progress.party = &copied_members;
            empty.unite_boundaries[owner].?.sequence.?.pending = @splat(false);
            var empty_draws = draws;
            for (0..250) |_| {
                if (empty.active == null) break;
                try empty.tickReplay(.{}, &empty_draws);
            }
            try std.testing.expect(empty.active == null and empty_draws.cursor == 0);
            try std.testing.expectEqualDeep(combat.enemy_hp, empty.enemy_hp);
        }
        if (scenario_index == 0) for (0..2) |scenario| {
            var simultaneous = combat;
            var copied_members: [6]battle.Member = undefined;
            @memcpy(&copied_members, combat.progress.party);
            simultaneous.progress.party = &copied_members;
            var simultaneous_draws = draws;
            for (0..100) |_| {
                const queue = simultaneous.uniteBoundaryFor(owner).?.sequence.?;
                if (queue.targets[0] != null and queue.targets[1] != null) break;
                try simultaneous.tickReplay(.{}, &simultaneous_draws);
            }
            const queue = simultaneous.uniteBoundaryFor(owner).?.sequence.?;
            try std.testing.expect(queue.targets[0] != null and queue.targets[1] != null);
            if (scenario == 1) {
                simultaneous.enemy_hp[1] = 0;
                simultaneous.actor_conditions[simultaneous.partyCount()].protection_rounds = 1;
            }
            for (0..2) |member| {
                simultaneous.unite_flags[member] |= 2;
                simultaneous.unite_vm.actors[member].signals |= 2;
            }
            try simultaneous.tickReplay(.{}, &simultaneous_draws);
            try std.testing.expectEqual(@as(usize, if (scenario == 0) 4 else 2), simultaneous_draws.cursor);
            if (scenario == 0) {
                try std.testing.expect(simultaneous.enemy_hp[0] < 5000 and simultaneous.enemy_hp[1] < 5000);
            } else {
                try std.testing.expectEqual(@as(u16, 5000), simultaneous.enemy_hp[0]);
                try std.testing.expectEqual(@as(u16, 0), simultaneous.enemy_hp[1]);
            }
            for (0..2) |member| try std.testing.expect(simultaneous.unite_flags[member] & 2 == 0);
        };
        const initial_hp = combat.enemy_hp;
        var changed: [3]bool = @splat(false);
        var claim_ticks: [3]u32 = @splat(0);
        var hit_ticks: [3]u32 = @splat(0);
        var changes: usize = 0;
        var saw_return = false;
        var handoff_at: ?u32 = null;
        var checked_rollback = false;
        for (0..700) |_| {
            if (combat.active == null) break;
            if (!checked_rollback and (combat.unite_vm.signalReady(0, 2) or combat.unite_vm.signalReady(1, 2))) {
                const before = try h.stateBytes(combat);
                defer allocator.free(before);
                var empty = rules.Draws{};
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &empty));
                const after = try h.stateBytes(combat);
                defer allocator.free(after);
                try std.testing.expectEqualStrings(before, after);
                checked_rollback = true;
            }
            try combat.tickReplay(.{}, &draws);
            for (0..3) |enemy| if (combat.enemy_hp[enemy] != initial_hp[enemy] and !changed[enemy]) {
                changed[enemy] = true;
                changes += 1;
                try std.testing.expectEqual(changes - 1, enemy);
                hit_ticks[enemy] = combat.camera_ticks - selection_tick;
                try std.testing.expectEqual(changes * 2, draws.cursor);
                try std.testing.expect(combat.unite_reactions[combat.partyCount() + enemy] != null);
            };
            if (combat.active != null) if (combat.uniteBoundaryFor(owner)) |boundary| if (boundary.sequence.?.finish_at) |finish| {
                const queue = boundary.sequence.?;
                try std.testing.expectEqual(@max(queue.return_at[0].?, queue.return_at[1].?) + 40, finish);
                handoff_at = combat.camera_ticks + (finish - combat.effectTicks());
                saw_return = true;
            };
            if (combat.uniteBoundaryFor(owner)) |boundary| for (boundary.sequence.?.targets) |maybe| if (maybe) |enemy| {
                if (claim_ticks[enemy] == 0) claim_ticks[enemy] = combat.camera_ticks - selection_tick;
            };
        }
        try std.testing.expectEqual(@as(usize, if (single_target) 1 else 3), changes);
        try std.testing.expect(saw_return and checked_rollback and combat.active == null);
        try std.testing.expectEqual(handoff_at.?, combat.camera_ticks);
        try std.testing.expectEqualSlices(u32, if (single_target) &.{ 49, 0, 0 } else &.{ 49, 55, 168 }, &claim_ticks);
        try std.testing.expectEqualSlices(u32, if (single_target) &.{ 143, 0, 0 } else &.{ 143, 147, 262 }, &hit_ticks);
        try std.testing.expectEqual(@as(usize, if (single_target) 2 else 6), draws.cursor);
        for (0..100) |_| {
            if (combat.uniteBoundaryFor(owner) == null) break;
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expect(combat.uniteBoundaryFor(owner) == null);
    }
}

test "Flash normal owners run single-target damage and delayed source returns" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/flash_battle.json"));
    defer content.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/flash_actor_library.json"));
    defer library.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const flash = try std.json.parseFromSlice(battle.spell_scene.Program, allocator, @embedFile("../fixtures/flash_scene_program.json"), .{});
    defer flash.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var packet = effects.value;
    const scenes = try allocator.alloc(battle.spell_scene.Spell, packet.unite_scenes.len + 1);
    defer allocator.free(scenes);
    @memcpy(scenes[0..packet.unite_scenes.len], packet.unite_scenes);
    scenes[scenes.len - 1] = .{ .id = "flash", .name = "Flash Attack", .program = flash.value };
    packet.unite_scenes = scenes;
    packet.schema = "suikoden-spell-scenes/47";
    try library.value.validate();
    var invalid = library.value;
    invalid.schema = "suikoden-unite-actors/10";
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    const bindings = try allocator.dupe(battle.actor_host.UniteBinding, library.value.unites);
    defer allocator.free(bindings);
    invalid = library.value;
    invalid.unites = bindings;
    const original = bindings[10];
    bindings[10].controller.?.return_at = 160;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    bindings[10] = original;
    bindings[10].controller.?.recipient_at = 1;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    bindings[10] = original;
    bindings[10].damage_reaction = false;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    for (0..12) |case| {
        const owner = case % 3;
        const protected = case % 6 >= 3;
        const target_index: usize = if (case >= 6) 2 else 0;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.integration = .{ .host = host };
        combat.encounter = 1;
        combat.startEncounter();
        try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&packet);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 10;
        combat.choose(owner);
        combat.queue(.{ .unite = target_index });
        try std.testing.expect(combat.unite_boundaries[owner] != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        const target = combat.partyCount() + target_index;
        if (protected) combat.actor_conditions[target].protection_rounds = 1;
        var tape = Tape{};
        var draws = tape.init();
        if (case == 0) {
            var rotated = combat;
            var rotated_members: [6]battle.Member = undefined;
            @memcpy(&rotated_members, combat.progress.party);
            rotated.progress.party = &rotated_members;
            rotated.actor_transforms[2].node_angles[2] = 1;
            var rotated_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, rotated.tickReplay(.{}, &rotated_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, rotated.unite_vm);
            try std.testing.expectEqual(draws.cursor, rotated_draws.cursor);
        }
        if (owner == 0 and !protected) {
            var refused = combat;
            refused.spell_scenes = null;
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
            const graphics = try allocator.dupe(battle.UniteGraphic, combat.content.unite_graphics);
            defer allocator.free(graphics);
            for (graphics) |*graphic| if (std.mem.eql(u8, graphic.id, "liukan")) {
                graphic.poses = &.{};
                break;
            };
            refused = combat;
            refused.content.unite_graphics = graphics;
            refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
        }
        try combat.tickReplay(.{}, &draws);
        if (case == 0) {
            var rotated = combat;
            var rotated_members: [6]battle.Member = undefined;
            @memcpy(&rotated_members, combat.progress.party);
            rotated.progress.party = &rotated_members;
            rotated.actor_transforms[2].node_angles[0] = 1;
            var rotated_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, rotated.tickReplay(.{}, &rotated_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, rotated.unite_vm);
            try std.testing.expectEqual(draws.cursor, rotated_draws.cursor);
        }
        const selection_tick = combat.camera_ticks;
        const hp = combat.enemy_hp;
        var saw_start = false;
        var saw_damage = false;
        var saw_return = false;
        var saw_rollback = false;
        for (0..500) |_| {
            if (owner == 0 and !saw_rollback) if (combat.unite_scene) |_| if (combat.active.?.scene.?.elapsed == 160) {
                var failed = combat;
                var short = draws;
                short.values = short.values[0 .. short.cursor + 2];
                try std.testing.expectError(error.RandomInputExhausted, failed.tickReplay(.{}, &short));
                try std.testing.expectEqualDeep(combat.unite_scene, failed.unite_scene);
                try std.testing.expectEqualDeep(combat.unite_vm, failed.unite_vm);
                try std.testing.expectEqualDeep(combat.enemy_hp, failed.enemy_hp);
                try std.testing.expectEqual(draws.cursor, short.cursor);
                saw_rollback = true;
            };
            try combat.tickReplay(.{}, &draws);
            if (combat.unite_scene) |scene| if (scene.started_at != null) {
                const age = combat.active.?.scene.?.elapsed;
                if (age == 1) {
                    try std.testing.expectEqual(@as(u32, if (owner == 0) 49 else 50), combat.camera_ticks - selection_tick);
                    saw_start = true;
                    try std.testing.expectEqual(@as(u8, @intCast(owner)), scene.trigger);
                    var paused = combat;
                    paused.unite_flags[owner] &= ~@as(u16, 16);
                    paused.unite_vm.actors[owner].signals &= ~@as(u16, 16);
                    paused.camera_ticks += 1;
                    paused.advanceUniteScene();
                    try std.testing.expectEqual(age, paused.active.?.scene.?.elapsed);
                    paused.unite_flags[owner] |= 16;
                    paused.camera_ticks += 1;
                    paused.advanceUniteScene();
                    try std.testing.expectEqual(age + 1, paused.active.?.scene.?.elapsed);
                    if (owner == 0 and !protected and target_index == 0) {
                        paused.unite_flags[owner] &= ~@as(u16, 16);
                        paused.unite_vm.actors[owner].signals &= ~@as(u16, 16);
                        var paused_draws = draws;
                        for (0..210) |_| try paused.tickReplay(.{}, &paused_draws);
                        try std.testing.expectEqual(age + 1, paused.active.?.scene.?.elapsed);
                        try std.testing.expectEqualDeep(hp, paused.enemy_hp);
                        for (0..3) |member| {
                            try std.testing.expect(paused.unite_vm.signalReady(member, 4));
                            try std.testing.expect(!paused.unite_vm.members[member].?.returning);
                        }
                    }
                }
                if (age < 161) try std.testing.expectEqualDeep(hp, combat.enemy_hp);
                if (age < 192) for (0..3) |member| try std.testing.expect(!combat.unite_vm.members[member].?.returning);
                if (age == 161) {
                    saw_damage = true;
                    try std.testing.expectEqual(@as(u32, if (owner == 0) 209 else 210), combat.camera_ticks - selection_tick);
                    try std.testing.expect(if (protected) combat.enemy_hp[target_index] == hp[target_index] else combat.enemy_hp[target_index] < hp[target_index]);
                    for (0..combat.enemyCount()) |enemy| if (enemy != target_index) try std.testing.expectEqual(hp[enemy], combat.enemy_hp[enemy]);
                    try std.testing.expect(combat.unite_reactions[target] != null);
                }
            };
            if (saw_damage and combat.unite_scene == null) {
                saw_return = true;
                try std.testing.expectEqual(@as(u32, if (owner == 0) 240 else 241), combat.camera_ticks - selection_tick);
                for (0..3) |member| try std.testing.expect(combat.unite_vm.members[member].?.returning);
                try std.testing.expectEqual(@as(u16, 0), combat.unite_flags[owner] & 16);
                break;
            }
        }
        try std.testing.expect(saw_start and saw_damage and saw_return);
        if (owner == 0) try std.testing.expect(saw_rollback);
        for (0..150) |_| {
            if (combat.unite_vm.members[0] == null and combat.unite_vm.members[1] == null and combat.unite_vm.members[2] == null) break;
            try combat.tickReplay(.{}, &draws);
        }
        for (0..3) |member| {
            try std.testing.expect(combat.unite_vm.members[member] == null);
            try std.testing.expect(combat.unbalanced[member] > 0);
        }
    }
}

test "Couple recipient palette refuses an enemy without the source palette images" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
    try combat.attachSpellScenes(&effects.value);
    const target = combat.partyCount();
    try std.testing.expect(combat.hasUniteReactionBinding(16, 0, target));
    const source_pose = combat.uniteReactionPose(target).?;
    combat.unite_reactions[target] = .{ .record = 16, .variant = 0, .started_at = 0, .origin_q12 = .{ 0, 0, 0 }, .home_q12 = .{ 0, 0, 0 } };
    for (0..34) |age| {
        combat.camera_ticks = @intCast(age);
        const sample = combat.spellReaction(target).?;
        const expected = if (age == 0 or age >= 32) source_pose.entry else source_pose.flash_entries.?[(age / 4) % 3];
        try std.testing.expectEqual(expected, sample.entry.?);
    }
    var modified = effects.value;
    const poses = try allocator.dupe(battle.spell_scene.HurtPose, modified.hurt_poses);
    defer allocator.free(poses);
    const target_id = combat.enemy(0).id;
    for (poses) |*pose| if (std.mem.eql(u8, pose.id, target_id)) {
        pose.flash_entries = null;
        break;
    };
    modified.hurt_poses = poses;
    combat.spell_scenes = &modified;
    try std.testing.expect(!combat.hasUniteReactionBinding(16, 0, target));
}

test "Beat recipient uses the source idle colors and refuses missing idle art" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
    try combat.attachSpellScenes(&effects.value);
    const target = combat.partyCount();
    try std.testing.expect(combat.hasUniteReactionBinding(27, 0, target));
    const source_pose = combat.uniteReactionPose(target).?;
    const home = [3]i32{ 200 * 4096, 40 * 4096, -30 * 4096 };
    combat.unite_reactions[target] = .{ .record = 27, .variant = 0, .started_at = 0, .origin_q12 = home, .home_q12 = home };
    combat.camera_ticks = 60;
    const sample = combat.spellReaction(target).?;
    try std.testing.expectEqual(@as(u8, 0), sample.animation);
    try std.testing.expectEqual(source_pose.idle_flash.?.frames[0].entries[(60 / 4) % 3], sample.entry.?);
    const position = combat.uniteActorPosition(target).?;
    try std.testing.expectEqual(@as(f32, -430), position.z);
    combat.camera_ticks = 107;
    try std.testing.expectEqual(source_pose.idle_flash.?.frames[source_pose.idle_flash.?.frames.len - 1].normal, combat.spellReaction(target).?.entry.?);
    combat.camera_ticks = 109;
    try std.testing.expect(combat.spellReaction(target) == null and combat.uniteActorPosition(target) == null);
    var modified = effects.value;
    const poses = try allocator.dupe(battle.spell_scene.HurtPose, modified.hurt_poses);
    defer allocator.free(poses);
    const target_id = combat.enemy(0).id;
    for (poses) |*pose| if (std.mem.eql(u8, pose.id, target_id)) {
        pose.idle_flash = null;
        break;
    };
    modified.hurt_poses = poses;
    combat.spell_scenes = &modified;
    try std.testing.expect(!combat.hasUniteReactionBinding(27, 0, target));
}

test "Lepant Family normal owners run three recipient reactions before signalled damage" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/lepant_family_battle.json"));
    defer content.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/battle_actor_library.json"));
    defer library.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    for (0..6) |case| {
        const owner = case % 3;
        const protected = case >= 3;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.integration = .{ .host = host };
        if (protected) combat.actor_conditions[6].protection_rounds = 3;
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&effects.value);
        combat.selected_unites[owner] = 30;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.acted[owner] = false;
        const values: [128]u15 = @splat(12345);
        var draws = rules.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.hasLiveUniteActors());
        try std.testing.expect(combat.hasSourceEffect());
        var started: [3]?u16 = @splat(null);
        var impact: ?u16 = null;
        const hp = combat.enemy_hp[0];
        errdefer std.debug.print("Family owner={d} protected={} starts={any} impact={any} phase={s}\n", .{ owner, protected, started, impact, @tagName(combat.phase) });
        for (1..701) |age| {
            if (case == 0 and age == 260) {
                var failed = combat;
                var short = draws;
                short.values = short.values[0 .. short.cursor + 1];
                try std.testing.expectError(error.RandomInputExhausted, failed.tickReplay(.{}, &short));
                try std.testing.expectEqualDeep(combat.unite_vm, failed.unite_vm);
                try std.testing.expectEqualDeep(combat.unite_reactions, failed.unite_reactions);
                try std.testing.expectEqualDeep(combat.unite_boundaries, failed.unite_boundaries);
                try std.testing.expectEqualDeep(combat.unite_flags, failed.unite_flags);
                try std.testing.expectEqualDeep(combat.enemy_hp, failed.enemy_hp);
                try std.testing.expectEqual(draws.cursor, short.cursor);
            }
            try combat.tickReplay(.{}, &draws);
            if (combat.unite_reactions[6]) |reaction| if (reaction.record == 30 and reaction.variant >= 1 and reaction.variant <= 3) {
                const index = reaction.variant - 1;
                if (started[index] == null) started[index] = @intCast(age);
            };
            if (combat.unite_vm.impact_at[owner] != null and impact == null) {
                impact = @intCast(age);
                try std.testing.expect(started[1] != null);
                try std.testing.expectEqual(started[1].? + 40, impact.?);
                if (protected) try std.testing.expectEqual(@as(u32, 0), combat.active.?.amounts[6]);
            }
            if (impact == null) try std.testing.expectEqual(hp, combat.enemy_hp[0]);
            if (combat.phase == .battle_menu) break;
        }
        try std.testing.expect(started[0] != null and started[1] != null and started[2] != null and impact != null);
        try std.testing.expectEqualDeep([3]?u16{ 143, 220, 110 }, started);
        try std.testing.expect(started[2].? < started[0].? and started[0].? < started[1].?);
        if (protected) try std.testing.expectEqual(hp, combat.enemy_hp[0]) else try std.testing.expect(combat.enemy_hp[0] < hp);
        try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
    }
}

test "Bandit normal owners retain the first recipient lock through Sydonia and commit one target-signalled hit" {
    const host = try hostFixture();
    defer host.deinit();
    const content_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(content_bytes);
    const content = try battle.load(allocator, content_bytes);
    defer content.deinit();
    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(library_bytes);
    const library = try battle.actor_host.loadBundle(allocator, library_bytes);
    defer library.deinit();
    const effect_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effect_bytes);
    const effects = try battle.spell_scene.load(allocator, effect_bytes);
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    for (0..4) |case| {
        const owner = case % 2;
        const protected = case >= 2;
        var view = content.value;
        const enemies = try allocator.dupe(battle.Profile, content.value.enemies);
        defer allocator.free(enemies);
        for (enemies) |*enemy| enemy.affinities = .{ .fire = .weak };
        view.enemies = enemies;
        view.initial_party = &.{ "varkas", "sydonia", "hero", "pahn", "gremio", "camille" };
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.weapon_augments[0] = .{ .rune = .fire, .fragments = 3 };
        combat.integration = .{ .host = host };
        if (protected) combat.actor_conditions[6].protection_rounds = 3;
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&effects.value);
        combat.selected_unites[owner] = 17;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.acted[owner] = false;
        const values: [128]u15 = @splat(12345);
        var draws = rules.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        const selected_at = combat.camera_ticks;
        try std.testing.expect(combat.hasLiveUniteActors());
        var first: ?u32 = null;
        var second: ?u32 = null;
        var impact: ?u32 = null;
        var held = false;
        var settled: ?battle.Position = null;
        errdefer std.debug.print("Bandit owner={d} first={any} second={any} impact={any} held={} phase={s}\n", .{ owner, first, second, impact, held, @tagName(combat.phase) });
        const hp = combat.enemy_hp[0];
        for (1..501) |age| {
            if (case == 0 and age == 97) {
                var failed = combat;
                var short = draws;
                short.values = short.values[0 .. short.cursor + 1];
                try std.testing.expectError(error.RandomInputExhausted, failed.tickReplay(.{}, &short));
                try std.testing.expectEqualDeep(combat.unite_vm, failed.unite_vm);
                try std.testing.expectEqualDeep(combat.unite_reactions, failed.unite_reactions);
                try std.testing.expectEqualDeep(combat.unite_boundaries, failed.unite_boundaries);
                try std.testing.expectEqualDeep(combat.actor_camera, failed.actor_camera);
                try std.testing.expectEqualDeep(combat.unite_flags, failed.unite_flags);
                try std.testing.expectEqualDeep(combat.enemy_hp, failed.enemy_hp);
                try std.testing.expectEqual(draws.cursor, short.cursor);
            }
            try combat.tickReplay(.{}, &draws);
            errdefer std.debug.print("Bandit owner={d} age={d}\n", .{ owner, age });
            if (age < 38) try std.testing.expect(!combat.unite_vm.members[1].?.initialized);
            if (age == 38) try std.testing.expect(combat.unite_vm.members[1].?.initialized);
            if (combat.unite_reactions[6]) |instance| {
                const reaction = combat.uniteReactionProgram(6).?;
                if (instance.variant == 1) {
                    if (first == null) {
                        first = @intCast(age);
                        try std.testing.expectEqual([3]i32{ -768 * 4096, 0, 448 * 4096 }, combat.actor_camera.?.target[1]);
                        try std.testing.expectEqual([3]i32{ 0, 0, 1024 * 4096 }, combat.actor_camera.?.target[2]);
                        try std.testing.expectEqual(@as([3]i32, @splat(3840 * 4096)), combat.actor_camera.?.target[3]);
                        try std.testing.expectEqual(@as([4]u16, @splat(30)), combat.actor_camera.?.remaining);
                    }
                    if (combat.camera_ticks - instance.started_at >= reaction.duration - 1) {
                        const position = battle.layout.worldPosition(&combat, 6);
                        if (settled) |old| try std.testing.expectEqualDeep(old, position) else settled = position;
                        const current = combat.camera_ticks;
                        combat.camera_ticks += 1;
                        try std.testing.expect(combat.uniteRecipientLocked(6));
                        try std.testing.expectEqualDeep(position, battle.layout.worldPosition(&combat, 6));
                        try std.testing.expect(combat.spellReaction(6) != null);
                        combat.camera_ticks = current;
                        held = true;
                    }
                    if (combat.camera_ticks - instance.started_at >= reaction.duration) {
                        held = true;
                        try std.testing.expect(combat.coordinatorLocked(6));
                        try std.testing.expect(combat.spellReaction(6) != null);
                    }
                } else if (instance.variant == 2 and second == null) second = @intCast(age);
            }
            if (combat.unite_vm.impact_at[owner] != null and impact == null) {
                impact = @intCast(age);
                try std.testing.expect(second != null);
                try std.testing.expectEqual(second.? + 15, impact.?);
                if (protected) try std.testing.expectEqual(@as(u32, 0), combat.active.?.amounts[6]);
            }
            if (impact == null) try std.testing.expectEqual(hp, combat.enemy_hp[0]);
            if (combat.phase == .battle_menu) break;
            try std.testing.expectEqual(selected_at + age, combat.camera_ticks);
        }
        try std.testing.expectEqual(@as(?u32, 50), first);
        try std.testing.expectEqual(@as(?u32, 82), second);
        try std.testing.expectEqual(@as(?u32, 97), impact);
        try std.testing.expect(second != null and impact != null and held);
        const raw = battle.physicalDamage(combat.stats(0).attack, combat.stats(6).defense, 12345, false);
        const weakness = raw + raw / 2;
        const expected = (weakness + (weakness / 20) * 3 + battle.physicalDamage(combat.stats(1).attack, combat.stats(6).defense, 12345, false)) * 25 / 10;
        try std.testing.expectEqual(@as(u16, @intCast(hp - if (protected) 0 else expected)), combat.enemy_hp[0]);
        try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
        try std.testing.expect(!combat.unite_vm.hasActors() and !combat.coordinatorLocked(6));
        try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    }
}

test "live Unite auxiliary sweep retains actual Elf child lifetimes and checkpoint bindings" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try battle.actor_host.loadBundle(allocator, bytes);
    defer parsed.deinit();
    const rebound = try battle.actor_host.loadBundle(allocator, bytes);
    defer rebound.deinit();
    var bundle = parsed.value;
    var bindings: [32]battle.actor_host.UniteBinding = undefined;
    @memcpy(&bindings, bundle.unites);
    bundle.unites = &bindings;
    // Exercise the actor phase alone; Elf scene admission still requires child art.
    bindings[3].dispatch_after = 1;
    combat.unite_actors = &bundle;
    const graphic_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(graphic_bytes);
    const graphic_content = try battle.load(allocator, graphic_bytes);
    defer graphic_content.deinit();
    combat.content.unite_graphics = graphic_content.value.unite_graphics;
    combat.content.schema = graphic_content.value.schema;
    const party = [_][]const u8{ "kirkis", "stallion", "sylvina", "hero", "pahn", "gremio" };
    var homes: [12][3]i32 = @splat(.{ 0, 0, 0 });
    const count = combat.partyCount() + combat.enemyCount();
    homes[6] = .{ 100 * 4096, 200 * 4096, 0 };
    var playback = battle.unite_playback.State{};
    try playback.begin(&bundle, 3, 0, 6, &party, homes[0..count], 0);
    playback.actors[6] = battle.actor_host.Actor.anchor(homes[6], homes[6], .{ -4, 3 });
    try std.testing.expectEqual(19 - count, playback.auxiliary_capacity);
    var born: ?u32 = null;
    var ended: ?u32 = null;
    var checkpoint_checked = false;
    for (1..200) |update| {
        combat.camera_ticks = @intCast(update);
        try playback.update(&combat, battle.layout.currentCamera(combat));
        combat.unite_vm = playback;
        var live: usize = 0;
        for (playback.auxiliary, 0..) |child, index| if (child) |actor| {
            live += 1;
            try std.testing.expect(index >= playback.auxiliary_capacity - 3 and index < playback.auxiliary_capacity);
            try std.testing.expectEqual(@as(?u16, @intCast(playback.auxiliary_capacity - 1 - index)), actor.owner);
            try std.testing.expectEqual([2]i32{ -4, 3 }, actor.offset_destination);
            try std.testing.expect(actor.has_draw_record);
            const quad = battle.layout.uniteAuxiliary(combat, index);
            try std.testing.expectEqual(actor.visible, quad != null);
            if (quad) |draw| for (draw.vertices) |point| {
                try std.testing.expect(std.math.isFinite(point.x) and std.math.isFinite(point.y));
                try std.testing.expectEqual(draw.depth, point.depth);
            };
        };
        if (live > 0 and born == null) {
            born = @intCast(update);
            try std.testing.expectEqual(@as(usize, 3), live);
            const current_camera = battle.layout.currentCamera(combat);
            for (playback.auxiliary) |maybe| if (maybe) |actor| {
                try std.testing.expectEqual([3]i16{ @truncate(current_camera.angles[0]), @truncate(current_camera.angles[1]), @truncate(current_camera.angles[2]) }, actor.draw_angles);
            };
            var aligned = combat;
            const Controller = @TypeOf(combat.actor_camera.?);
            aligned.actor_camera = try Controller.init(.{ .focus = .{ 0, 0, 0 }, .angles = .{ 0, 0, 0 }, .translation = .{ 0, 0, 1024 }, .scale = .{ 4096, 4096, 4096 } });
            const slot = playback.auxiliary_capacity - 1;
            const aligned_child = &aligned.unite_vm.auxiliary[slot].?;
            aligned_child.position_q12 = .{ 0, 0, 0 };
            aligned_child.screen_offset = .{ 0, 0 };
            aligned_child.record_flags = 4;
            aligned_child.draw_angles = .{ 0, 0, 0 };
            const quad = battle.layout.uniteAuxiliary(aligned, slot).?;
            const ax: f32 = @floatFromInt(quad.sprite.anchor_x);
            const ay: f32 = @floatFromInt(quad.sprite.anchor_y);
            try std.testing.expectEqual(320 - 2 * ax, quad.vertices[0].x);
            try std.testing.expectEqual(240 - 2 * ay, quad.vertices[0].y);
            try std.testing.expectEqual(@as(f32, @floatFromInt(quad.sprite.rect.w - 1)) * 2, quad.vertices[1].x - quad.vertices[0].x);
            try std.testing.expectEqual(@as(f32, @floatFromInt(quad.sprite.rect.h - 1)) * 2, quad.vertices[2].y - quad.vertices[0].y);
            aligned_child.draw_angles[2] = 1024;
            const rotated = battle.layout.uniteAuxiliary(aligned, slot).?;
            try std.testing.expectEqual(320 + 2 * ay, rotated.vertices[0].x);
            try std.testing.expectEqual(240 - 2 * ax, rotated.vertices[0].y);
            aligned_child.translucent = true;
            try std.testing.expect(battle.layout.uniteAuxiliary(aligned, slot).?.translucent);
            aligned_child.record_flags = 2;
            try std.testing.expect(battle.layout.uniteAuxiliary(aligned, slot) == null);
            aligned_child.record_flags = 0;
            try std.testing.expect(battle.layout.uniteAuxiliary(aligned, slot).?.vertices[0].x != quad.vertices[0].x);
            aligned_child.visible = false;
            try std.testing.expect(battle.layout.uniteAuxiliary(aligned, slot) == null);
            // Spawn enters the callback immediately; the same outer sweep polls it once.
            for (playback.auxiliary) |child| if (child) |actor| try std.testing.expectEqual(@as(i16, 1), actor.shared_value);
        }
        if (live > 0 and !checkpoint_checked) {
            var restored = playback;
            try restored.rebind(&rebound.value);
            for (restored.auxiliary, restored.auxiliary_bindings) |child, binding| if (child) |actor| {
                const ids = binding.?;
                try std.testing.expect(actor.resource.?.id.ptr == rebound.value.animations.resources[ids.resource].id.ptr);
                try std.testing.expect(actor.machine.?.instructions.ptr == rebound.value.programs.programs[ids.program].instructions.ptr);
            };
            const index = restored.auxiliary_capacity - 1;
            restored.auxiliary_bindings[index].?.resource = 255;
            try std.testing.expectError(error.InvalidActorPlayback, restored.rebind(&bundle));
            try std.testing.expect(restored.actors[0].resource.?.id.ptr == rebound.value.animations.resources[restored.members[0].?.resource].id.ptr);
            restored = playback;
            restored.auxiliary[index].?.owner = 65535;
            try std.testing.expectError(error.InvalidActorPlayback, restored.rebind(&bundle));
            restored = playback;
            restored.auxiliary_capacity -= 1;
            try std.testing.expectError(error.InvalidActorPlayback, restored.rebind(&bundle));
            checkpoint_checked = true;
        }
        if (born != null and live == 0) {
            ended = @intCast(update);
            break;
        }
    }
    try std.testing.expect(checkpoint_checked);
    try std.testing.expectEqual(@as(?u32, 66), born);
    try std.testing.expectEqual(@as(?u32, 113), ended);
    try std.testing.expect(!playback.hasAuxiliary());
    for (playback.auxiliary_bindings) |binding| try std.testing.expect(binding == null);
}

test "Elf Unite runs member and arrow programs without flattened tracks for every owner" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try battle.load(allocator, bytes);
    defer parsed.deinit();
    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(library_bytes);
    const library = try battle.actor_host.loadBundle(allocator, library_bytes);
    defer library.deinit();
    const effects_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effects_bytes);
    const effects = try battle.spell_scene.load(allocator, effects_bytes);
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var content = parsed.value;
    content.initial_party = &.{ "kirkis", "stallion", "sylvina", "hero", "gremio", "pahn" };
    for (0..3) |owner| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&effects.value);
        for (0..3) |member| {
            try std.testing.expect(combat.partyProfile(member).uniteTrack(3) == null);
            try std.testing.expect(!combat.canAttackTarget(member, 0));
        }
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 3;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        var tape = Tape{};
        var draws = tape.init();
        if (owner == 0) {
            var refused = combat;
            var graphics: [64]battle.UniteGraphic = undefined;
            @memcpy(graphics[0..content.unite_graphics.len], content.unite_graphics);
            var poses: [256]battle.UniteGraphicPose = undefined;
            for (graphics[0..content.unite_graphics.len]) |*graphic| if (std.mem.eql(u8, graphic.id, "kirkis")) {
                var count: usize = 0;
                for (graphic.poses) |pose| if (pose.id != 10) {
                    poses[count] = pose;
                    count += 1;
                };
                graphic.poses = poses[0..count];
            };
            refused.content.unite_graphics = graphics[0..content.unite_graphics.len];
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqual(combat.camera_ticks, refused.camera_ticks);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
        }
        try combat.tickReplay(.{}, &draws);
        const selected_at = combat.camera_ticks;
        var changes: usize = 0;
        var previous: u16 = 5000;
        var birth: ?u32 = null;
        var hit: ?u32 = null;
        var child_end: ?u32 = null;
        var handoff: ?u32 = null;
        while (combat.camera_ticks - selected_at < 200) {
            if (owner == 0 and combat.camera_ticks - selected_at == 80) {
                var exhausted = combat;
                var saved_members: [6]battle.Member = undefined;
                @memcpy(&saved_members, combat.progress.party);
                exhausted.progress.party = &saved_members;
                var exhausted_draws = draws;
                exhausted_draws.values = draws.values[0 .. draws.cursor + 2];
                try std.testing.expectError(error.RandomInputExhausted, exhausted.tickReplay(.{}, &exhausted_draws));
                try std.testing.expectEqual(combat.camera_ticks, exhausted.camera_ticks);
                try std.testing.expectEqual(draws.cursor, exhausted_draws.cursor);
                try std.testing.expectEqualDeep(combat.unite_vm, exhausted.unite_vm);
                try std.testing.expectEqual(combat.enemy_hp[0], exhausted.enemy_hp[0]);
            }
            try combat.tickReplay(.{}, &draws);
            const age = combat.camera_ticks - selected_at;
            if (combat.enemy_hp[0] != previous) {
                changes += 1;
                hit = age;
                try std.testing.expect(combat.unite_reactions[6] != null);
                try std.testing.expectEqual(@as(u8, 3), combat.unite_reactions[6].?.record);
            }
            previous = combat.enemy_hp[0];
            var children: usize = 0;
            for (combat.unite_vm.auxiliary, 0..) |child, index| if (child) |actor| {
                children += 1;
                try std.testing.expectEqual(actor.visible, battle.layout.uniteAuxiliary(combat, index) != null);
            };
            if (children > 0 and birth == null) birth = age;
            if (birth != null and children == 0 and child_end == null) child_end = age;
            for (0..3) |member| if (combat.unite_vm.owns(member)) {
                try std.testing.expect(combat.uniteVmPose(member) != null);
                if (combat.unite_vm.actors[member].blue_trail) |trail| if (trail.visible) {
                    try std.testing.expect(battle.layout.uniteTrail(combat, member) != null);
                };
            };
            if (combat.active == null and handoff == null) handoff = age;
            if (age == 173) {
                for (0..3) |member| try std.testing.expect(!combat.unite_vm.owns(member));
                break;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), changes);
        try std.testing.expectEqual(@as(?u32, 66), birth);
        try std.testing.expectEqual(@as(?u32, 81), hit);
        try std.testing.expectEqual(@as(?u32, 113), child_end);
        try std.testing.expectEqual(@as(?u32, 152), handoff);
    }
}

test "Wild Arrow scenes bind source profiles group damage fans and returns for every owner" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try battle.load(allocator, bytes);
    defer parsed.deinit();
    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(library_bytes);
    const library = try battle.actor_host.loadBundle(allocator, library_bytes);
    defer library.deinit();
    const effect_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effect_bytes);
    const effects = try battle.spell_scene.load(allocator, effect_bytes);
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = library.value;
    for ([_]u8{ 2, 19, 20 }) |record| for (0..2) |owner| {
        var content = parsed.value;
        const hit: usize = if (record == 19) 102 else 107;
        content.initial_party = if (record == 2) &.{ "kirkis", "sylvina", "hero", "pahn", "gremio", "stallion" } else if (record == 19) &.{ "kirkis", "rubi", "hero", "pahn", "gremio", "sylvina" } else &.{ "kirkis", "stallion", "hero", "pahn", "gremio", "sylvina" };
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        combat.integration = .{ .host = host };
        for (combat.content.encounters, 0..) |encounter, index| if (encounter.enemies.len == 3) {
            combat.encounter = index;
            combat.startEncounter();
            break;
        };
        try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
        combat.enemy_hp[0] = 2000;
        combat.enemy_hp[1] = 0;
        combat.enemy_hp[2] = 2000;
        try combat.attachUniteActors(&bundle);
        try combat.attachSpellScenes(&effects.value);
        combat.selected_unites[owner] = record;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.unite_boundaries[owner] != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        var tape = Tape{};
        var draws = tape.init();
        if (record == 2 and owner == 0) for ([_]u16{ 4, 10 }) |missing_pose| {
            var refused = combat;
            var graphics: [64]battle.UniteGraphic = undefined;
            @memcpy(graphics[0..content.unite_graphics.len], content.unite_graphics);
            var poses: [256]battle.UniteGraphicPose = undefined;
            for (graphics[0..content.unite_graphics.len]) |*graphic| if (std.mem.eql(u8, graphic.id, "sylvina")) {
                var count: usize = 0;
                for (graphic.poses) |pose| if (pose.id != missing_pose) {
                    poses[count] = pose;
                    count += 1;
                };
                graphic.poses = poses[0..count];
            };
            refused.content.unite_graphics = graphics[0..content.unite_graphics.len];
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(combat.camera_ticks, refused.camera_ticks);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
        };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active.?.kind == .unite);
        const selected_at = combat.camera_ticks;
        for (1..201) |age| {
            const previous_actors = combat.unite_vm.actors;
            if (age == hit and record == 2 and owner == 0) {
                var failed = combat;
                var failed_members: [6]battle.Member = undefined;
                @memcpy(&failed_members, combat.progress.party);
                failed.progress.party = &failed_members;
                var short = draws;
                short.values = short.values[0 .. short.cursor + 3];
                try std.testing.expectError(error.RandomInputExhausted, failed.tickReplay(.{}, &short));
                try std.testing.expectEqualDeep(combat.enemy_hp, failed.enemy_hp);
                try std.testing.expectEqualDeep(combat.unite_reactions, failed.unite_reactions);
                try std.testing.expectEqualDeep(combat.unite_vm.members, failed.unite_vm.members);
                try std.testing.expectEqual(combat.camera_ticks, failed.camera_ticks);
                try std.testing.expectEqual(draws.cursor, short.cursor);
            }
            var prior: [2][3]i32 = undefined;
            if (age == hit and record == 19) for ([_]usize{ 6, 8 }, 0..) |target, index| {
                const old = combat.unite_reactions[target].?;
                const reaction = for (effects.value.unite_reactions) |r| {
                    if (r.record == 19 and r.variant == 0) break r;
                } else unreachable;
                prior[index] = battle.spell_scene.unitePosition(reaction, old.origin_q12, old.home_q12, combat.camera_ticks - old.started_at);
            };
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(@as(u32, @intCast(age)), combat.camera_ticks - selected_at);
            for (0..2) |member| {
                if (age >= (if (record == 19 and member == 1) @as(usize, 186) else 198)) {
                    try std.testing.expect(combat.unite_vm.members[member] == null);
                    continue;
                }
                const fan = combat.unite_vm.members[member].?.fan.?;
                const activated: usize = if (member == 0) 67 else if (record == 19) 82 else 87;
                try std.testing.expectEqual(age >= activated and age <= 177, fan.visible);
                try std.testing.expectEqual(age >= 177, fan.finished);
                const steps = if (age >= activated) @min(age, 177) - activated + 1 else 0;
                try std.testing.expectEqual(-@as(i32, @intCast(steps)) * 49152, fan.local_x_q12);
                if (fan.visible) try std.testing.expectEqualDeep([3]i32{ previous_actors[member].position_q12[0] >> 12, previous_actors[member].position_q12[1] >> 12, -40 }, fan.anchor);
                for (0..5) |arrow| try std.testing.expectEqual(fan.visible, battle.layout.uniteAuxiliary(combat, 19 + member * 5 + arrow) != null);
            }
            try std.testing.expect(!combat.unite_vm.hasAuxiliary());
            if (age >= 177) try std.testing.expect(combat.active == null);
            if (age == hit and record == 19) for ([_]usize{ 6, 8 }, 0..) |target, index| try std.testing.expectEqualDeep(prior[index], combat.unite_reactions[target].?.origin_q12);
            if (age == 87 and record == 19) for ([_]usize{ 6, 8 }) |target| {
                combat.unite_reactions[target].?.origin_q12[0] += 137;
                combat.unite_reactions[target].?.origin_q12[1] += 197;
                combat.unite_reactions[target].?.origin_q12[2] += 271;
            };
            for ([_]usize{ 6, 8 }) |target| {
                if (age >= hit and age < hit + 30) {
                    try std.testing.expectEqual(@as(?u32, combat.active.?.amounts[target]), combat.uniteDamageAmount(target));
                } else try std.testing.expect(combat.uniteDamageAmount(target) == null);
            }
            try std.testing.expect(combat.uniteDamageAmount(7) == null);
            if (age < hit) {
                try std.testing.expectEqual(@as(u16, 2000), combat.enemy_hp[0]);
                try std.testing.expectEqual(@as(u16, 2000), combat.enemy_hp[2]);
            } else {
                try std.testing.expect(combat.enemy_hp[0] < 2000);
                try std.testing.expect(combat.enemy_hp[2] < 2000);
            }
            try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[1]);
            if (age <= 177) try std.testing.expectEqual(@as(usize, if (age < hit) 0 else 4), draws.cursor);
            if (age == 87 or age == hit) {
                for ([_]usize{ 6, 8 }) |target| try std.testing.expectEqual(combat.camera_ticks, combat.unite_reactions[target].?.started_at);
                try std.testing.expect(combat.unite_reactions[7] == null);
                try std.testing.expectEqual(@as(u16, if (age == 87) 0 else (1 << 6) | (1 << 8)), combat.active.?.affected);
                if (age == hit) {
                    try std.testing.expectEqual(combat.active.?.amounts[6] + combat.active.?.amounts[8], combat.active.?.amount);
                    try std.testing.expectEqual(@as(u32, 2000) -| combat.active.?.amounts[6], @as(u32, combat.enemy_hp[0]));
                    try std.testing.expectEqual(@as(u32, 2000) -| combat.active.?.amounts[8], @as(u32, combat.enemy_hp[2]));
                }
            }
            if (age == 87) try std.testing.expectEqual(@as(u16, 0), combat.unite_flags[0] & 2);
            if (age == hit) try std.testing.expectEqual(@as(u16, 0), combat.unite_flags[1] & 2);
            if (age == 88) {
                var rebound = combat.unite_vm;
                try rebound.rebind(&bundle);
                rebound.members[0].?.fan = null;
                try std.testing.expectError(error.InvalidActorPlayback, rebound.rebind(&bundle));
                var cancelled = combat;
                var cancelled_members: [6]battle.Member = undefined;
                @memcpy(&cancelled_members, combat.progress.party);
                cancelled.progress.party = &cancelled_members;
                cancelled.choose(owner);
                for (0..2) |member| {
                    try std.testing.expect(cancelled.unite_vm.members[member] == null);
                    for (0..5) |arrow| try std.testing.expect(battle.layout.uniteAuxiliary(cancelled, 19 + member * 5 + arrow) == null);
                }
                rebound = combat.unite_vm;
                rebound.members[0].?.reaction_group = false;
                try std.testing.expectError(error.InvalidActorPlayback, rebound.rebind(&bundle));
            }
        }
    };
}

test "Ninja full scene binds recipient assist member phases and independent target release" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(library_bytes);
    const library = try battle.actor_host.loadBundle(allocator, library_bytes);
    defer library.deinit();
    const effects_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effects_bytes);
    const effects = try battle.spell_scene.load(allocator, effects_bytes);
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = library.value;
    var view = content.value;
    view.initial_party = &.{ "kasumi", "fuma", "kage", "hero", "pahn", "gremio" };
    for (0..3) |owner| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&bundle);
        try combat.attachSpellScenes(&effects.value);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 28;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        var tape = Tape{};
        var draws = tape.init();
        if (owner == 0) {
            var refused = combat;
            var graphics: [64]battle.UniteGraphic = undefined;
            @memcpy(graphics[0..view.unite_graphics.len], view.unite_graphics);
            var phase_poses: [256]battle.UniteGraphicPose = undefined;
            for (graphics[0..view.unite_graphics.len]) |*graphic| if (std.mem.eql(u8, graphic.id, "fuma")) {
                var count: usize = 0;
                for (graphic.poses) |pose| if (pose.id != 4) {
                    phase_poses[count] = pose;
                    count += 1;
                };
                graphic.poses = phase_poses[0..count];
            };
            refused.content.unite_graphics = graphics[0..view.unite_graphics.len];
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqual(combat.camera_ticks, refused.camera_ticks);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
        }
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active.?.kind == .unite);
        const selected_at = combat.camera_ticks;
        var previous = combat.enemy_hp[0];
        var changes: usize = 0;
        for (1..273) |age| {
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(@as(u32, @intCast(age)), combat.camera_ticks - selected_at);
            if (combat.enemy_hp[0] != previous) {
                changes += 1;
                try std.testing.expectEqual(@as(usize, 199), age);
                try std.testing.expectEqual(@as(u8, 0), combat.unite_reactions[6].?.variant);
            }
            previous = combat.enemy_hp[0];
            if (age == 58) {
                try std.testing.expectEqual(@as(u8, 1), combat.unite_reactions[6].?.variant);
                try std.testing.expectEqual(combat.camera_ticks, combat.unite_reactions[6].?.started_at);
            }
            if (age >= 118 and age < 174) try std.testing.expect(combat.spellReaction(6).?.flip_y);
            if (age == 191 or age == 198) try std.testing.expectEqualDeep(battle.Position{ .x = 0, .y = 0, .z = 0 }, combat.uniteActorPosition(6).?);
            if (owner == 0 and age == 191) {
                var isolated = combat;
                isolated.active = null;
                isolated.unite_returns = @splat(null);
                try std.testing.expect(!isolated.coordinatorLocked(6));
                isolated.unite_reactions[6].?.record = 7;
                isolated.unite_reactions[6].?.started_at = isolated.camera_ticks;
                try std.testing.expect(isolated.coordinatorLocked(6));
                try std.testing.expect(isolated.hasUniteReturns());
            }
            for (0..3) |member| {
                try std.testing.expectEqual(age < (if (member == 0) @as(usize, 192) else 246), combat.unite_vm.owns(member));
                if (combat.unite_vm.owns(member)) {
                    try std.testing.expect(combat.uniteVmPose(member) != null);
                    if (combat.unite_vm.actors[member].blue_trail) |trail| if (trail.visible) try std.testing.expect(battle.layout.uniteTrail(combat, member) != null);
                }
            }
            if (age >= 184 and age <= 198) {
                var children: usize = 0;
                for (combat.unite_vm.auxiliary, 0..) |child, index| if (child != null) {
                    children += 1;
                    try std.testing.expect(battle.layout.uniteAuxiliary(combat, index) != null);
                };
                try std.testing.expectEqual(@as(usize, 2), children);
            }
            if (age < 225) try std.testing.expect(combat.active != null);
            if (age == 225) try std.testing.expect(combat.active == null);
            if (age >= 246 and age < 271) try std.testing.expect(combat.coordinatorLocked(6));
            if (age >= 246 and age < 271) {
                try std.testing.expect(combat.hasUniteReturns());
                try std.testing.expect(combat.coordinator.?.stage == .round_boundary);
                try std.testing.expectEqual(@as(i32, 0), combat.coordinator.?.remaining);
            }
            if (age == 271) {
                try std.testing.expect(!combat.coordinatorLocked(6));
                try std.testing.expect(combat.coordinator.?.stage != .round_boundary);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), changes);
    }
}

test "Ninja actor phases consume Kasumi signal and preserve embedded returns" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    var party_members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &party_members, 17);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try battle.actor_host.loadBundle(allocator, bytes);
    defer parsed.deinit();
    const rebound = try battle.actor_host.loadBundle(allocator, bytes);
    defer rebound.deinit();
    try std.testing.expectEqual(@as(?u16, 1), parsed.value.find(28).?.dispatch_after);
    var bindings: [32]battle.actor_host.UniteBinding = undefined;
    var bundle = parsed.value;
    @memcpy(&bindings, bundle.unites);
    bundle.unites = &bindings;
    // Isolate actor-phase conformance from the complete recipient/coordinator test above.
    bindings[28].dispatch_after = 1;
    try bundle.validate();
    combat.unite_actors = &bundle;
    const party = [_][]const u8{ "kasumi", "fuma", "kage", "hero", "pahn", "gremio" };
    const count = combat.partyCount() + combat.enemyCount();
    var homes: [12][3]i32 = @splat(.{ 0, 0, 0 });
    homes[6] = .{ 100 * 4096, 200 * 4096, 0 };
    for (0..3) |leader| {
        var playback = battle.unite_playback.State{};
        combat.unite_flags = @splat(0);
        try playback.begin(&bundle, 28, @intCast(leader), 6, &party, homes[0..count], 0);
        playback.actors[6] = battle.actor_host.Actor.anchor(homes[6], homes[6], .{ -4, 3 });
        var transitioned: ?u32 = null;
        var born: ?u32 = null;
        var hit: ?u32 = null;
        var ready: ?u32 = null;
        var finished: ?u32 = null;
        const first_program = playback.members[0].?.program;
        for (1..251) |age| {
            combat.camera_ticks = @intCast(age);
            if (playback.allReady(leader) and ready == null) ready = @intCast(age);
            try playback.advanceTransition(&bundle, @intCast(leader), &combat.unite_flags);
            if (playback.members[1].?.pending_dispatch) {
                transitioned = @intCast(age);
                try std.testing.expectEqual(@as(u16, 0), combat.unite_flags[0] & 16);
                try std.testing.expect(playback.actors[1].machine == null);
                var checkpoint = playback;
                try checkpoint.rebind(&rebound.value);
                try std.testing.expect(checkpoint.members[1].?.pending_dispatch);
            }
            try playback.update(&combat, battle.layout.currentCamera(combat));
            if (age == 24) try std.testing.expect(playback.actors[1].machine.?.halted);
            if (age == 159) try std.testing.expect(combat.unite_flags[0] & 16 != 0);
            if (age == 160) {
                try std.testing.expect(playback.members[0].?.returning);
                try std.testing.expectEqual(first_program, playback.members[0].?.program);
                try std.testing.expect(!playback.actors[0].machine.?.halted);
            }
            if (age == 161) {
                var invalid = playback;
                invalid.actors[1].machine.?.actor = 65535;
                try std.testing.expectError(error.InvalidActorPlayback, invalid.rebind(&bundle));
            }
            if (age == 192) {
                try std.testing.expect(playback.actors[0].machine.?.halted);
                try std.testing.expect(playback.actors[0].released);
            }
            if (playback.hasAuxiliary() and born == null) {
                born = @intCast(age);
                const current_camera = battle.layout.currentCamera(combat);
                var checked: usize = 0;
                for (playback.auxiliary) |maybe| if (maybe) |actor| {
                    try std.testing.expectEqual(@as(i16, @truncate(current_camera.angles[0])), actor.draw_angles[0]);
                    try std.testing.expectEqual(@as(i16, @truncate(current_camera.angles[1])), actor.draw_angles[1]);
                    if (actor.projectile.? == .aimed) {
                        try std.testing.expectEqual(@as(i16, @truncate(current_camera.angles[2])), actor.draw_angles[2]);
                    } else try std.testing.expectEqual(@as(i16, 512), actor.draw_angles[2]);
                    checked += 1;
                };
                try std.testing.expectEqual(@as(usize, 2), checked);
            }
            if (playback.hitReady(1) and hit == null) hit = @intCast(age);
            if (playback.actors[1].released and playback.actors[2].released) {
                finished = @intCast(age);
                break;
            }
        }
        try std.testing.expectEqual(@as(?u32, 160), transitioned);
        try std.testing.expectEqual(@as(?u32, 184), born);
        try std.testing.expectEqual(@as(?u32, 198), hit);
        try std.testing.expectEqual(@as(?u32, 225), ready);
        try std.testing.expectEqual(@as(?u32, 246), finished);
    }
}

test "early Unite completion request retains its VM drawing tail until halt" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try battle.actor_host.loadBundle(allocator, bytes);
    defer parsed.deinit();
    const effect_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effect_bytes);
    const effects = try battle.spell_scene.load(allocator, effect_bytes);
    defer effects.deinit();
    var bundle = parsed.value;
    const programs = try allocator.dupe(battle.actor_program.Program, bundle.programs.programs);
    defer allocator.free(programs);
    bundle.programs.programs = programs;
    const index = for (programs, 0..) |program, i| {
        if (std.mem.eql(u8, program.id, "pahn/unite_9")) break i;
    } else return error.MissingUniteProgram;
    const code = try allocator.alloc(battle.actor_program.Instruction, programs[index].instructions.len + 1);
    defer allocator.free(code);
    @memcpy(code[1..], programs[index].instructions);
    // Kasumi proves release-before-halt exists; inject that lifetime pattern in a qualified art fixture.
    code[0] = .{ .command = .{ .release_actor = true } };
    programs[index].instructions = code;
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    try combat.attachUniteActors(&bundle);
    try combat.attachSpellScenes(&effects.value);
    combat.enterRoundMenu();
    combat.choose(2);
    combat.queue(.{ .unite = 0 });
    for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
        action.* = .defend;
    };
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.action_ticks = 100;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 2, .elapsed = 100 };
    var tape = Tape{};
    var draws = tape.init();
    try combat.tickReplay(.{}, &draws);
    for (0..3) |_| try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.unite_vm.actors[2].released);
    try std.testing.expectEqual(@as(u8, 0), combat.uniteBoundaryFor(2).?.finished_members & 1);
    try std.testing.expect(!combat.unite_vm.actors[2].machine.?.halted);
    try std.testing.expect(combat.uniteVmPose(2) != null);
    const age = combat.unite_vm.members[2].?.age;
    combat.phase = .battle_menu;
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(age + 1, combat.unite_vm.members[2].?.age);
    try std.testing.expect(combat.unite_vm.actors[2].released);
    try std.testing.expectEqual(@as(u8, 0), combat.uniteBoundaryFor(2).?.finished_members & 1);
    var invalid = combat.unite_vm;
    invalid.members[2].?.pending_dispatch = true;
    try std.testing.expectError(error.InvalidActorPlayback, invalid.rebind(&bundle));
    combat.choose(2);
    try std.testing.expect(!combat.unite_vm.hasActors());
}

test "Bumpy normal owners bind packet body footprint white palette phases and damage" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(library_bytes);
    const library = try battle.actor_host.loadBundle(allocator, library_bytes);
    defer library.deinit();
    const effect_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effect_bytes);
    const effects = try battle.spell_scene.load(allocator, effect_bytes);
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var view = content.value;
    view.initial_party = &.{ "krin", "humphrey", "hero", "pahn", "gremio", "rubi" };
    for (0..2) |owner| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&effects.value);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 6;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.unite_boundaries[owner] != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        var tape = Tape{};
        var draws = tape.init();
        if (owner == 0) {
            var refused = combat;
            var graphics: [64]battle.UniteGraphic = undefined;
            @memcpy(graphics[0..view.unite_graphics.len], view.unite_graphics);
            var poses: [256]battle.UniteGraphicPose = undefined;
            for (graphics[0..view.unite_graphics.len]) |*graphic| if (std.mem.eql(u8, graphic.id, "krin")) {
                @memcpy(poses[0..graphic.poses.len], graphic.poses);
                for (poses[0..graphic.poses.len]) |*pose| pose.white = null;
                graphic.poses = poses[0..graphic.poses.len];
            };
            refused.content.unite_graphics = graphics[0..view.unite_graphics.len];
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(combat.camera_ticks, refused.camera_ticks);
        }
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active.?.kind == .unite);
        const selected_at = combat.camera_ticks;
        const hp = combat.enemy_hp[0];
        var children: ?usize = null;
        for (1..248) |age| {
            if (age == 165) {
                var failed = combat;
                var short = draws;
                short.values = short.values[0 .. short.cursor + 1];
                try std.testing.expectError(error.RandomInputExhausted, failed.tickReplay(.{}, &short));
                try std.testing.expectEqualDeep(combat.unite_vm, failed.unite_vm);
                try std.testing.expectEqualDeep(combat.enemy_hp, failed.enemy_hp);
                try std.testing.expectEqual(draws.cursor, short.cursor);
            }
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(@as(u32, @intCast(age)), combat.camera_ticks - selected_at);
            if (combat.unite_vm.hasAuxiliary() and children == null) children = age;
            if (age < 165) try std.testing.expectEqual(hp, combat.enemy_hp[0]) else try std.testing.expect(combat.enemy_hp[0] < hp);
            if (age <= 213) try std.testing.expectEqual(@as(usize, if (age < 165) 0 else 2), draws.cursor);
            if (age == 81) try std.testing.expect(combat.unite_vm.members[1].?.initialized);
            if (age >= 144 and age < 164) {
                const pose = combat.unite_vm.pose(0).?;
                try std.testing.expectEqualDeep(view.uniteWhiteGraphic("krin", pose).?, combat.uniteVmPose(0).?);
                try std.testing.expectEqualDeep(combat.uniteVmPose(0).?, battle.layout.actorLayout(combat, 0).sprite);
            }
            if (age == 164) try std.testing.expectEqual(battle.actor_host.Palette{ .resource = {} }, combat.unite_vm.actors[0].palette);
            if (age == 165) {
                try std.testing.expectEqual(combat.camera_ticks, combat.unite_reactions[6].?.started_at);
                try std.testing.expectEqual(@as(u16, 0), combat.unite_flags[0] & 16);
                try std.testing.expectEqual(@as(?u32, hp - combat.enemy_hp[0]), combat.uniteDamageAmount(6));
            }
            if (age >= 213) try std.testing.expect(combat.active == null);
            if (age == 234) try std.testing.expect(combat.unite_vm.members[0] == null);
            if (age == 246) try std.testing.expect(combat.unite_vm.members[1] == null);
        }
        try std.testing.expectEqual(@as(?usize, 55), children);
    }
}

test "Fatal normal owners retain deferred Gen entry separate reactions damage and returns" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(library_bytes);
    const library = try battle.actor_host.loadBundle(allocator, library_bytes);
    defer library.deinit();
    const effect_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effect_bytes);
    const effects = try battle.spell_scene.load(allocator, effect_bytes);
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var view = content.value;
    view.initial_party = &.{ "gen", "kamandol", "hero", "pahn", "gremio", "rubi" };
    for (0..2) |owner| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&effects.value);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 13;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.unite_boundaries[owner] != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        var tape = Tape{};
        var draws = tape.init();
        if (owner == 0) {
            var refused = combat;
            var graphics: [64]battle.UniteGraphic = undefined;
            @memcpy(graphics[0..view.unite_graphics.len], view.unite_graphics);
            for (graphics[0..view.unite_graphics.len]) |*graphic| if (std.mem.eql(u8, graphic.id, "gen")) {
                graphic.id = "missing_gen";
            };
            refused.content.unite_graphics = graphics[0..view.unite_graphics.len];
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(combat.camera_ticks, refused.camera_ticks);
        }
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active.?.kind == .unite);
        const selected_at = combat.camera_ticks;
        const hp = combat.enemy_hp[0];
        var assist_births: usize = 0;
        for (1..319) |age| {
            if (age == 252) {
                var failed = combat;
                var short = draws;
                short.values = short.values[0 .. short.cursor + 1];
                try std.testing.expectError(error.RandomInputExhausted, failed.tickReplay(.{}, &short));
                try std.testing.expectEqualDeep(combat.unite_vm, failed.unite_vm);
                try std.testing.expectEqualDeep(combat.enemy_hp, failed.enemy_hp);
                try std.testing.expectEqualDeep(combat.unite_reactions, failed.unite_reactions);
                try std.testing.expectEqual(draws.cursor, short.cursor);
            }
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(@as(u32, @intCast(age)), combat.camera_ticks - selected_at);
            if (age < 252) try std.testing.expectEqual(hp, combat.enemy_hp[0]) else try std.testing.expect(combat.enemy_hp[0] < hp);
            if (age <= 272) try std.testing.expectEqual(@as(usize, if (age < 252) 0 else 2), draws.cursor);
            if (age < 61) {
                try std.testing.expect(combat.unite_vm.members[0].?.deferred_entry);
                try std.testing.expect(!combat.unite_vm.members[0].?.initialized);
                try std.testing.expectEqual(@as(u16, 0), combat.unite_vm.members[0].?.age);
            }
            if (age == 61) {
                try std.testing.expect(combat.unite_vm.members[0].?.initialized);
                try std.testing.expectEqual(@as(u16, 1), combat.unite_vm.members[0].?.age);
                try std.testing.expectEqual(@as(u16, 0), combat.unite_flags[1] & 16);
            }
            if (age == 125) {
                try std.testing.expectEqual(combat.camera_ticks, combat.unite_reactions[6].?.started_at);
                try std.testing.expectEqual(@as(u8, 1), combat.unite_reactions[6].?.variant);
                assist_births += 1;
            }
            if (age == 252) {
                try std.testing.expectEqual(combat.camera_ticks, combat.unite_reactions[6].?.started_at);
                try std.testing.expectEqual(@as(u8, 0), combat.unite_reactions[6].?.variant);
                try std.testing.expectEqual(@as(?u32, hp - combat.enemy_hp[0]), combat.uniteDamageAmount(6));
            }
            if (age >= 272) try std.testing.expect(combat.active == null);
            if (age == 240) try std.testing.expect(combat.unite_vm.members[0] == null);
            if (age == 317) try std.testing.expect(combat.unite_vm.members[1] == null);
        }
        try std.testing.expectEqual(@as(usize, 1), assist_births);
    }
}

test "Beauty recipient sleep commits once after tint restoration and rolls back a late missing draw" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const effect_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effect_bytes);
    const effects = try battle.spell_scene.load(allocator, effect_bytes);
    defer effects.deinit();
    for ([_]u8{ 9, 25 }) |record| {
        var members: [6]battle.Member = undefined;
        var content = fixture.view;
        const profiles = try allocator.dupe(battle.Profile, content.enemies);
        defer allocator.free(profiles);
        for (profiles) |*profile| profile.death_immune = true;
        content.enemies = profiles;
        var combat = try battle.State.init(content, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        for (combat.content.encounters, 0..) |encounter, index| if (encounter.enemies.len == 3) {
            combat.encounter = index;
            combat.startEncounter();
            break;
        };
        try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
        try combat.attachSpellScenes(&effects.value);
        combat.phase = .resolving;
        combat.round_start_pending = false;
        combat.coordinator = .{ .stage = .await_order, .current_actor = 0 };
        for (combat.partyCount()..combat.partyCount() + 2) |target| {
            combat.unite_reactions[target] = .{ .record = record, .variant = 1, .started_at = 0, .origin_q12 = .{ 0, 0, 0 }, .home_q12 = .{ 0, 0, 0 } };
        }
        const first = combat.partyCount();
        const second = first + 1;
        const values = [_]u15{ 9830, 9831 };
        var draws = rules.Draws{ .values = &values };
        for (1..132) |age| {
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(@as(usize, 0), draws.cursor);
            const sample = combat.spellReaction(first).?;
            try std.testing.expectEqualDeep(@as([3]u8, if (age >= 2 and age < 130) .{ 192, 64, 64 } else .{ 128, 128, 128 }), sample.color);
            try std.testing.expectEqual(@as(u8, 0), combat.actor_conditions[first].sleep_turns);
        }
        var failed = combat;
        var short = rules.Draws{ .values = &.{9831} };
        try std.testing.expectError(error.RandomInputExhausted, failed.tickReplay(.{}, &short));
        try std.testing.expectEqualDeep(combat.actor_conditions, failed.actor_conditions);
        try std.testing.expectEqualDeep(combat.unite_reactions, failed.unite_reactions);
        try std.testing.expectEqual(combat.camera_ticks, failed.camera_ticks);
        try std.testing.expectEqual(@as(usize, 0), short.cursor);
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(usize, 2), draws.cursor);
        try std.testing.expectEqual(@as(u8, 0), combat.actor_conditions[first].sleep_turns);
        try std.testing.expectEqual(@as(u8, 1), combat.actor_conditions[second].sleep_turns);
        for ([_]usize{ first, second }) |target| try std.testing.expectEqual(@as(u8, 1), combat.unite_reactions[target].?.status_applied);
        // A repeated actor pass or checkpoint copy cannot repeat a terminal attempt.
        combat.replay_draws = &draws;
        combat.advanceUniteActors();
        combat.replay_draws = null;
        try std.testing.expectEqual(@as(usize, 2), draws.cursor);
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(usize, 2), draws.cursor);
        try std.testing.expectEqual(@as(u8, 1), combat.actor_conditions[second].sleep_turns);
        var duplicate = combat;
        duplicate.unite_reactions[first] = null;
        duplicate.unite_reactions[second].?.started_at = duplicate.camera_ticks - 132;
        duplicate.unite_reactions[second].?.status_applied = 0;
        var duplicate_draws = rules.Draws{ .values = &.{9831} };
        duplicate.replay_draws = &duplicate_draws;
        duplicate.advanceUniteActors();
        duplicate.replay_draws = null;
        try std.testing.expectEqual(@as(usize, 1), duplicate_draws.cursor);
        try std.testing.expectEqual(@as(u8, 1), duplicate.actor_conditions[second].sleep_turns);
        duplicate.replay_draws = &duplicate_draws;
        duplicate.advanceUniteActors();
        duplicate.replay_draws = null;
        try std.testing.expectEqual(@as(usize, 1), duplicate_draws.cursor);
        var tail = combat;
        tail.phase = .target;
        tail.unite_reactions[first] = null;
        tail.camera_ticks = 131;
        tail.unite_reactions[second].?.started_at = 0;
        tail.unite_reactions[second].?.status_applied = 0;
        var tail_draws = rules.Draws{ .values = &.{9831} };
        try tail.tickReplay(.{}, &tail_draws);
        try std.testing.expectEqual(@as(usize, 1), tail_draws.cursor);
        try std.testing.expectEqual(@as(u8, 1), tail.unite_reactions[second].?.status_applied);
    }
}

test "Beauty normal owners run shared controller particles group sleep damage and forced returns" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(library_bytes);
    const library = try battle.actor_host.loadBundle(allocator, library_bytes);
    defer library.deinit();
    const effect_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effect_bytes);
    const effects = try battle.spell_scene.load(allocator, effect_bytes);
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    for ([_]u8{ 9, 25 }) |record| for (0..3) |owner| {
        var view = content.value;
        view.initial_party = if (record == 9) &.{ "cleo", "eileen", "valeria", "hero", "pahn", "gremio" } else &.{ "cleo", "eileen", "sonya", "hero", "pahn", "gremio" };
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        for (view.encounters, 0..) |encounter, index| if (encounter.enemies.len == 3) {
            combat.encounter = index;
            combat.startEncounter();
            break;
        };
        try std.testing.expectEqual(@as(usize, 3), combat.enemyCount());
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&effects.value);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = record;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.unite_boundaries[owner] != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        var tape = Tape{};
        var draws = tape.init();
        if (owner == 0) {
            var refused = combat;
            refused.spell_scenes = null;
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
        }
        combat.actor_transforms[6].node_angles[1] = 23;
        try combat.tickReplay(.{}, &draws);
        const selected_at = combat.camera_ticks;
        const hp = combat.enemy_hp;
        var respawn_failure_checked = false;
        for (1..521) |age| {
            const late_event = age == 1 or age == 292 or age == 319;
            var respawn = false;
            if (combat.unite_scene) |scene| if (scene.started_at != null and combat.active != null and combat.active.?.scene != null and combat.active.?.scene.?.elapsed < 192 and !respawn_failure_checked) {
                for (combat.active.?.scene.?.particles[0..30]) |particle| respawn = respawn or !particle.active;
            };
            if (owner == 0 and (late_event or respawn)) {
                var failed = combat;
                var short = draws;
                const remaining: usize = if (age == 1) 149 else if (age == 319) 8 else 2;
                short.values = short.values[0 .. short.cursor + remaining];
                try std.testing.expectError(error.RandomInputExhausted, failed.tickReplay(.{}, &short));
                try std.testing.expectEqualDeep(combat.unite_scene, failed.unite_scene);
                try std.testing.expectEqualDeep(combat.active, failed.active);
                try std.testing.expectEqualDeep(combat.unite_vm, failed.unite_vm);
                try std.testing.expectEqualDeep(combat.unite_reactions, failed.unite_reactions);
                try std.testing.expectEqualDeep(combat.actor_transforms, failed.actor_transforms);
                try std.testing.expectEqualDeep(combat.actor_camera, failed.actor_camera);
                try std.testing.expectEqualDeep(combat.enemy_hp, failed.enemy_hp);
                try std.testing.expectEqualDeep(combat.actor_conditions, failed.actor_conditions);
                try std.testing.expectEqual(combat.camera_ticks, failed.camera_ticks);
                try std.testing.expectEqual(draws.cursor, short.cursor);
                if (respawn) respawn_failure_checked = true;
            }
            try combat.tickReplay(.{}, &draws);
            errdefer std.debug.print("Beauty record={d} owner={d} age={d}\n", .{ record, owner, age });
            try std.testing.expectEqual(@as(u32, @intCast(age)), combat.camera_ticks - selected_at);
            if (age < 319) try std.testing.expectEqualDeep(hp, combat.enemy_hp);
            if (age <= 96) try std.testing.expectEqual(@as(usize, 150), draws.cursor);
            if (age < 96) {
                try std.testing.expect(combat.unite_scene.?.started_at == null);
                try std.testing.expectEqual(@as(usize, 0), combat.spellSceneFrame().count);
            }
            if (age == 96) {
                try std.testing.expectEqual(combat.camera_ticks, combat.unite_scene.?.started_at.?);
                try std.testing.expectEqual(@as(u16, 1), combat.active.?.scene.?.elapsed);
                try std.testing.expectEqual(@as(u16, 60), combat.actor_camera.?.remaining[0]);
                try std.testing.expect(combat.spellSceneFrame().count >= 128);
            }
            if (age == 160) for (6..9) |target| {
                try std.testing.expectEqual(combat.camera_ticks, combat.unite_reactions[target].?.started_at);
                try std.testing.expectEqual(@as(u8, 1), combat.unite_reactions[target].?.variant);
            };
            if (age >= 160 and age < 287) for (6..9) |target| try std.testing.expectEqual(@as(i16, 1), combat.actor_transforms[target].node_angles[0]);
            if (age >= 287) for (6..9) |target| try std.testing.expectEqualDeep([3]i16{ 0, if (target == 6) 23 else 0, 0 }, combat.actor_transforms[target].node_angles);
            try std.testing.expectEqual(@as(i16, 23), combat.actor_transforms[6].node_angles[1]);
            if (age == 176) {
                const visual = battle.layout.actorLayout(combat, 6);
                const quad = battle.layout.rotatedActorQuad(combat, 6, visual.sprite, visual.point).?;
                try std.testing.expect(quad.vertices[0].y != quad.vertices[1].y);
                try std.testing.expect(quad.vertices[0].x != quad.vertices[2].x);
            }
            if (age == 292) for (6..9) |target| try std.testing.expectEqual(@as(u8, 1), combat.unite_reactions[target].?.status_applied);
            if (age == 319) {
                for (0..3) |enemy| try std.testing.expect(combat.enemy_hp[enemy] < hp[enemy]);
                for (0..3) |member| try std.testing.expect(combat.unite_vm.members[member].?.returning);
                try std.testing.expect(combat.active == null);
                try std.testing.expectEqual(@as(usize, 0), combat.spellSceneFrame().count);
            }
            if (age >= 320) try std.testing.expect(combat.unite_scene == null);
        }
        if (owner == 0) try std.testing.expect(respawn_failure_checked);
        for (0..3) |member| try std.testing.expect(combat.unite_vm.members[member] == null);
    };
}

test "Pretty Girl normal owners retain Tengaar redispatch airborne recipient and child-owned damage" {
    const host = try hostFixture();
    defer host.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const content = try battle.load(allocator, bytes);
    defer content.deinit();
    const library_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(1024 * 1024));
    defer allocator.free(library_bytes);
    const library = try battle.actor_host.loadBundle(allocator, library_bytes);
    defer library.deinit();
    const effect_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effect_bytes);
    const effects = try battle.spell_scene.load(allocator, effect_bytes);
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var view = content.value;
    view.initial_party = &.{ "camille", "tengaar", "kasumi", "hero", "pahn", "gremio" };
    for (0..3) |owner| for (0..3) |loss| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&library.value);
        try combat.attachSpellScenes(&effects.value);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 8;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.unite_boundaries[owner] != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        var tape = Tape{};
        var draws = tape.init();
        try combat.tickReplay(.{}, &draws);
        const selected_at = combat.camera_ticks;
        const hp = combat.enemy_hp[0];
        var contribution: u32 = 0;
        for (0..3) |slot| contribution += combat.resolvePhysicalDamage(slot, combat.partyCount(), tape.values[slot + 1], false);
        const expected_damage = contribution * 25 / 10;
        var hit_at: ?usize = null;
        var child_at: ?usize = null;
        for (1..281) |age| {
            errdefer std.debug.print("Pretty Girl owner={d} loss={d} age={d}\n", .{ owner, loss, age });
            if (age == 193 and loss != 0) {
                const victim: usize = if (loss == 1) 0 else 2;
                try std.testing.expect(combat.unite_vm.members[victim] == null and !combat.coordinatorLocked(victim));
                combat.progress.party[victim].hp = 0;
                combat.progress.party[victim].inventory.slots = @splat(null);
                combat.markPartyKnockout(victim);
                try std.testing.expect(combat.commitPartyKnockout(victim));
            }
            if (owner == 0 and (age == 192 or age == 205)) {
                const before_members = members;
                var failed = combat;
                var short = draws;
                short.values = short.values[0 .. short.cursor + @as(usize, if (age == 192) 0 else 2)];
                try std.testing.expectError(error.RandomInputExhausted, failed.tickReplay(.{}, &short));
                try std.testing.expectEqualDeep(before_members, members);
                try std.testing.expectEqualDeep(combat.unite_vm, failed.unite_vm);
                try std.testing.expectEqualDeep(combat.unite_boundaries, failed.unite_boundaries);
                try std.testing.expectEqualDeep(combat.unite_reactions, failed.unite_reactions);
                try std.testing.expectEqualDeep(combat.unbalanced, failed.unbalanced);
                try std.testing.expectEqualDeep(combat.enemy_hp, failed.enemy_hp);
                try std.testing.expectEqual(draws.cursor, short.cursor);
            }
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(@as(u32, @intCast(age)), combat.camera_ticks - selected_at);
            if (combat.unite_vm.impact_at[owner] != null and hit_at == null) hit_at = age;
            if (hit_at == null) try std.testing.expectEqual(hp, combat.enemy_hp[0]);
            if (combat.unite_vm.hasAuxiliary() and child_at == null) child_at = age;
            if (age == 59) {
                try std.testing.expectEqual(combat.camera_ticks, combat.unite_reactions[6].?.started_at);
                try std.testing.expectEqual(@as(u8, 1), combat.unite_reactions[6].?.variant);
            }
            if (age >= 119 and age < 175) try std.testing.expect(combat.spellReaction(6).?.flip_y);
            if (age >= 160 and age <= 204) {
                try std.testing.expectEqual(@as(u16, 2), combat.unite_flags[6] & 2);
                try std.testing.expectEqual(combat.unite_flags[6], combat.unite_vm.actors[6].signals);
            }
            if (age == 160) {
                try std.testing.expectEqualStrings("tengaar/unite_12", library.value.programs.programs[combat.unite_vm.members[1].?.program].id);
                try std.testing.expectEqual(@as(u16, 0), combat.unite_flags[2] & 16);
            }
            if (age == 181) try std.testing.expect(combat.unite_vm.members[0] == null);
            if (age == 192) {
                try std.testing.expect(combat.unite_vm.members[2] == null);
                try std.testing.expectEqual(@as(u8, 2), combat.unbalanced[2]);
                try std.testing.expectEqual(@as(usize, 1), draws.cursor);
            }
            if (age == 205) {
                try std.testing.expectEqual(@as(u16, @intCast(@as(u32, hp) -| expected_damage)), combat.enemy_hp[0]);
                try std.testing.expectEqual(@as(u8, 0), combat.unite_reactions[6].?.variant);
                try std.testing.expectEqual(combat.camera_ticks, combat.unite_reactions[6].?.started_at);
                try std.testing.expectEqual(@as(usize, 4), draws.cursor);
            }
            if (age >= 239) try std.testing.expect(combat.active == null);
            if (age == 260) try std.testing.expect(combat.unite_vm.members[1] == null);
        }
        try std.testing.expectEqual(@as(?usize, 190), child_at);
        try std.testing.expectEqual(@as(?usize, 205), hit_at);
        try std.testing.expectEqual(@as(usize, 4), draws.cursor);
        for (0..3) |member| try std.testing.expect(combat.unite_vm.members[member] == null);
    };
}

test "Unite recipient signals publish once preserve other bits and synchronize VM state" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try battle.spell_scene.load(allocator, bytes);
    defer parsed.deinit();
    var packet = parsed.value;
    var reaction = for (packet.unite_reactions) |r| {
        if (r.record == 10) break r;
    } else unreachable;
    const signals = [_]battle.spell_scene.UniteSignal{
        .{ .at = 0, .bits = 4, .set = false },
        .{ .at = 1, .bits = 2, .set = true },
        .{ .at = reaction.duration, .bits = 4, .set = true },
    };
    reaction.signals = &signals;
    packet.unite_reactions = (&reaction)[0..1];
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    try combat.attachSpellScenes(&packet);
    const target = combat.partyCount();
    combat.unite_flags[target] = 20;
    combat.unite_reactions[target] = .{ .record = 10, .started_at = 0, .origin_q12 = .{ 0, 0, 0 }, .home_q12 = .{ 0, 0, 0 } };
    combat.advanceUniteActors();
    try std.testing.expectEqual(@as(u16, 16), combat.unite_flags[target]);
    try std.testing.expectEqual(@as(u8, 1), combat.unite_reactions[target].?.signals_applied);
    combat.unite_flags[target] |= 4;
    combat.advanceUniteActors();
    try std.testing.expectEqual(@as(u16, 20), combat.unite_flags[target]);
    combat.camera_ticks = 1;
    combat.advanceUniteActors();
    try std.testing.expectEqual(@as(u16, 22), combat.unite_flags[target]);
    try std.testing.expectEqual(combat.unite_flags[target], combat.unite_vm.actors[target].signals);
    combat.unite_flags[target] &= ~@as(u16, 2);
    combat.advanceUniteActors();
    try std.testing.expectEqual(@as(u16, 20), combat.unite_flags[target]);
    combat.unite_flags[target] &= ~@as(u16, 4);
    combat.camera_ticks = reaction.duration;
    combat.advanceUniteActors();
    try std.testing.expectEqual(@as(u16, 20), combat.unite_flags[target]);
    try std.testing.expectEqual(@as(u8, 7), combat.unite_reactions[target].?.signals_applied);
}

test "Martial arts battle host retains returned members until delayed group damage and cleanup" {
    const host = try hostFixture();
    defer host.deinit();
    const parsed = try battle.load(allocator, @embedFile("../fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const timing = try std.json.parseFromSlice(battle.unite_queue.Timing, allocator, @embedFile("../fixtures/martial_queue_timing.json"), .{});
    defer timing.deinit();
    // Synthetic stats isolate the real battle HP/lifecycle host from actor-art admission.
    const profiles = try allocator.alloc(battle.Profile, parsed.value.party.len + 2);
    defer allocator.free(profiles);
    @memcpy(profiles[0..parsed.value.party.len], parsed.value.party);
    profiles[profiles.len - 2] = profiles[0];
    profiles[profiles.len - 2].id = "eikei";
    profiles[profiles.len - 1] = profiles[1];
    profiles[profiles.len - 1].id = "morgan";
    const names = [_][]const u8{ "eikei", "pahn", "morgan" };
    var view = parsed.value;
    view.party = profiles;
    const timings = try allocator.alloc(@TypeOf(view.medicine_timings[0]), view.medicine_timings.len + 2);
    defer allocator.free(timings);
    @memcpy(timings[0..view.medicine_timings.len], view.medicine_timings);
    timings[timings.len - 2] = timings[0];
    timings[timings.len - 2].id = "eikei";
    timings[timings.len - 1] = timings[0];
    timings[timings.len - 1].id = "morgan";
    view.medicine_timings = timings;
    view.initial_party = &names;
    view.party_positions = view.party_positions[0..names.len];
    var encounters = [_]battle.Encounter{view.encounters[0]};
    const enemies = [_][]const u8{ "bonbon", "bonbon", "bonbon" };
    const positions = [_]battle.Position{ .{ .x = -128, .y = -80, .z = 0 }, .{ .x = -128, .y = 0, .z = 0 }, .{ .x = -128, .y = 80, .z = 0 } };
    encounters[0].enemies = &enemies;
    encounters[0].positions = &positions;
    encounters[0].enemy_rows = &.{ .front, .front, .front };
    encounters[0].source_slots = &.{ 0, 1, 2 };
    view.encounters = &encounters;
    for (0..3) |owner| {
        var members: [3]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        combat.selected_unites[owner] = 29;
        combat.enterRoundMenu();
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        combat.active = .{ .actor = owner, .target = 3, .kind = .unite, .unite_boundary = true };
        var invalid_timing = timing.value;
        invalid_timing.damage = invalid_timing.recipient_return;
        try std.testing.expectError(error.InvalidUniteQueueTiming, combat.beginMartialQueue(owner, invalid_timing));
        try std.testing.expect(combat.martial_queue == null);
        try combat.beginMartialQueue(owner, timing.value);
        try std.testing.expectError(error.InvalidUniteSceneBinding, combat.beginMartialQueue(owner, timing.value));
        combat.martial_queue.?.queue.returning = 7;
        combat.martial_queue.?.queue.pending = @splat(false);
        combat.unite_flags = @splat(0);
        combat.enemy_hp = .{ 9999, 9999, 9999, 0, 0, 0 };
        combat.actor_conditions[4].protection_rounds = 1;
        for (0..3) |member| combat.finishUniteMember(owner, member);
        try std.testing.expectEqual(@as(u8, 0), combat.uniteBoundaryFor(owner).?.finished_members);
        try std.testing.expect(combat.uniteHandoffTick() == null);
        var tape = Tape{};
        var draws = tape.init();
        combat.replay_draws = &draws;
        const original_hp = combat.enemy_hp;
        var expected_draws = draws;
        var contribution: u32 = 0;
        for (0..3) |member| contribution += combat.resolvePhysicalDamage(member, 3, try expected_draws.next(), false);
        const expected_damage = contribution * 5 / 10;
        for (0..201) |age| {
            combat.camera_ticks = @intCast(age);
            // A target lost during the animation is excluded at the damage callback.
            if (age == 100) combat.enemy_hp[2] = 0;
            combat.resolveUniteImpact();
            const clock = combat.martial_queue.?.queue.finish_age;
            combat.resolveUniteImpact();
            try std.testing.expectEqual(clock, combat.martial_queue.?.queue.finish_age);
            try std.testing.expect(combat.replay_unsupported == null and !combat.replay_exhausted);
            if (age < 140) {
                try std.testing.expectEqual(original_hp[0], combat.enemy_hp[0]);
                try std.testing.expectEqual(@as(usize, 0), draws.cursor);
            } else {
                try std.testing.expectEqual(original_hp[0] - expected_damage, combat.enemy_hp[0]);
                try std.testing.expectEqual(expected_damage, combat.active.?.amounts[3]);
                try std.testing.expectEqual(@as(u32, 0), combat.active.?.amounts[4]);
                try std.testing.expectEqual(original_hp[1], combat.enemy_hp[1]);
                try std.testing.expectEqual(@as(usize, 6), draws.cursor);
                try std.testing.expectEqual(@as(u16, 0b11000), combat.active.?.affected);
            }
            if (age < 200) {
                try std.testing.expect(combat.uniteHandoffTick() == null);
                try std.testing.expectEqual(std.math.maxInt(u16), combat.actionDuration());
            }
        }
        try std.testing.expect(combat.uniteHandoffTick() != null);
        combat.handoffUnite();
        try std.testing.expect(combat.uniteBoundaryFor(owner) == null and combat.martial_queue == null);
        try std.testing.expectEqualDeep([6]u8{ 0, 0, 0, 0, 0, 0 }, combat.unbalanced);
        try std.testing.expectError(error.InvalidUniteSceneBinding, combat.beginMartialQueue(owner, timing.value));
    }
}

test "Martial arts source actors recipient handoff and delayed HP run as one battle action" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/martial_battle.json"));
    defer content.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/martial_actor_library.json"));
    defer actors.deinit();
    const journey_content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer journey_content.deinit();
    const journey_actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer journey_actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const Recipients = struct { programs: []const battle.spell_scene.UniteReaction };
    const recipients = try std.json.parseFromSlice(Recipients, allocator, @embedFile("../fixtures/martial_recipients.json"), .{ .ignore_unknown_fields = true });
    defer recipients.deinit();
    var packet = effects.value;
    packet.schema = "suikoden-spell-scenes/49";
    const reactions = try allocator.alloc(battle.spell_scene.UniteReaction, packet.unite_reactions.len + 2);
    defer allocator.free(reactions);
    @memcpy(reactions[0..packet.unite_reactions.len], packet.unite_reactions);
    @memcpy(reactions[packet.unite_reactions.len..], recipients.value.programs);
    packet.unite_reactions = reactions;
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var encounters = [_]battle.Encounter{content.value.encounters[0]};
    const enemy_ids = [_][]const u8{ "bonbon", "bonbon", "bonbon", "bonbon", "bonbon", "bonbon" };
    const positions = [_]battle.Position{ .{ .x = -128, .y = -80, .z = 0 }, .{ .x = -128, .y = 0, .z = 0 }, .{ .x = -128, .y = 80, .z = 0 }, .{ .x = -192, .y = -80, .z = 0 }, .{ .x = -192, .y = 0, .z = 0 }, .{ .x = -192, .y = 80, .z = 0 } };
    encounters[0].enemies = &enemy_ids;
    encounters[0].positions = &positions;
    encounters[0].enemy_rows = &.{ .front, .front, .front, .back, .back, .back };
    encounters[0].source_slots = &.{ 0, 1, 2, 3, 4, 5 };
    for (0..14) |case| {
        const scenario = case % 7;
        const journey = case >= 7;
        const owner = scenario % 3;
        const protected = scenario >= 3 and scenario < 6;
        var members: [6]battle.Member = undefined;
        var view = if (journey) journey_content.value else content.value;
        view.initial_party = content.value.initial_party;
        if (scenario == 6) view.encounters = &encounters;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(if (journey) &journey_actors.value else &actors.value);
        try combat.attachSpellScenes(&packet);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 29;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        combat.action_ticks = 100;
        const target = combat.partyCount();
        if (protected) combat.actor_conditions[target].protection_rounds = 1;
        const hp = combat.enemy_hp[0];
        var tape = Tape{};
        var draws = tape.init();
        if (scenario == 0) {
            var refused = combat;
            var missing = packet;
            missing.unite_reactions = reactions[0 .. reactions.len - 1];
            refused.spell_scenes = &missing;
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
        }
        var saw: u8 = 0;
        var struck: u3 = 0;
        var reacted: u6 = 0;
        var drawn: u3 = 0;
        var damage_tick: ?u32 = null;
        for (0..1000) |_| {
            const age = if (combat.martial_queue) |queue| if (queue.queue.returning == 7) @as(?u16, queue.queue.finish_age) else null else null;
            try combat.tickReplay(.{}, &draws);
            if (combat.martial_queue != null) saw |= 1;
            for (0..3) |member| if (combat.unite_vm.owns(member)) {
                if (combat.unite_vm.pose(member)) |pose| if (combat.unite_vm.actors[member].palette == .resource) {
                    const expected = combat.content.uniteGraphicPose(combat.progress.party[member].id, pose, 29).?;
                    try std.testing.expectEqualDeep(expected.sprite, combat.uniteVmPose(member).?);
                };
                if (combat.unite_trails[member].visible) {
                    const trail = combat.unite_vm.actors[member].blue_trail.?;
                    const expected = combat.content.uniteGraphicPose(combat.progress.party[member].id, trail.pose, 29).?.trail.?;
                    const quads = battle.layout.uniteTrail(combat, member).?;
                    for (quads, 0..) |quad, index| try std.testing.expectEqualDeep(expected[7 - index], quad.sprite);
                    drawn |= @as(u3, 1) << @as(u2, @intCast(member));
                }
            };
            for (0..3) |member| if (combat.unite_vm.signalReady(member, 2)) {
                struck |= @as(u3, 1) << @as(u2, @intCast(member));
            };
            for (0..combat.enemyCount()) |enemy| if (combat.unite_reactions[target + enemy]) |reaction| {
                if (reaction.record == 29 and reaction.variant == 1) reacted |= @as(u6, 1) << @as(u3, @intCast(enemy));
            };
            if (combat.unite_reactions[target]) |reaction| {
                if (reaction.record == 29 and reaction.variant == 1) saw |= 2;
                if (reaction.record == 29 and reaction.variant == 2) saw |= 4;
            }
            if (age) |counter| {
                if (counter < 140) try std.testing.expectEqual(hp, combat.enemy_hp[0]);
                if (counter == 140) {
                    try std.testing.expect(combat.active != null);
                    damage_tick = combat.camera_ticks;
                    if (protected) try std.testing.expectEqual(hp, combat.enemy_hp[0]) else try std.testing.expect(combat.enemy_hp[0] < hp);
                    const expected_mask = ((@as(u16, 1) << @as(u4, @intCast(combat.enemyCount()))) - 1) << @as(u4, @intCast(target));
                    try std.testing.expectEqual(expected_mask, combat.active.?.affected);
                    for (0..combat.enemyCount()) |enemy| if (!(protected and enemy == 0)) {
                        try std.testing.expect(combat.enemy_hp[enemy] < hp);
                    };
                    saw |= 8;
                }
            }
            if (combat.active == null and !combat.hasUniteReturns() and saw & 1 != 0) {
                try std.testing.expect(damage_tick != null and combat.camera_ticks >= damage_tick.? + 60);
                saw |= 16;
                break;
            }
        }
        try std.testing.expectEqual(@as(u8, 31), saw);
        if (scenario == 6) {
            try std.testing.expectEqual(@as(u3, 7), struck);
            try std.testing.expectEqual(@as(u6, 63), reacted);
        }
        try std.testing.expectEqual(@as(u3, 7), drawn);
        for (0..combat.enemyCount()) |enemy| try std.testing.expect(!combat.uniteRecipientLocked(target + enemy));
        try std.testing.expect(combat.martial_queue == null and combat.uniteBoundaryFor(owner) == null);
        for (0..3) |member| {
            try std.testing.expect(!combat.unite_vm.owns(member));
            try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[member]);
        }
    }
}

test "Added Unite journey members keep ordinary hurt and Clone action graphics" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var view = content.value;
    view.initial_party = &.{ "eikei", "pahn", "morgan", "ronnie", "gremio", "viktor" };
    for ([_]usize{ 0, 2, 3 }) |member| for (0..2) |kind| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.enemy_hp[0] = 5000;
        combat.phase = .resolving;
        combat.acted = @splat(true);
        const hp = combat.hp(member);
        const target = combat.partyCount();
        if (kind == 0) {
            try combat.beginMelee(target, member, true);
        } else {
            combat.runes[member] = for (view.systems.?.runes, 0..) |rune, index| {
                if (std.mem.eql(u8, rune.id, "clone")) break index;
            } else return error.MissingCloneRune;
            try combat.beginSourcePhysicalRune(member, target);
        }
        var tape = Tape{};
        var draws = tape.init();
        var saw_body = false;
        var finished = false;
        for (0..600) |_| {
            try combat.tickReplay(.{}, &draws);
            if (combat.unite_vm.scripted_actors[member] != null) {
                const actor = combat.unite_vm.actors[member];
                const entry = combat.content.uniteGraphicPose(view.initial_party.?[member], actor.currentFrame().pose, null).?;
                const expected = if (actor.palette == .shared and actor.palette.shared == 0) entry.white.? else entry.ordinary orelse entry.sprite;
                try std.testing.expectEqualDeep(expected, combat.physicalRunePose(member).?);
                saw_body = true;
            }
            if (combat.active == null and !combat.unite_vm.hasPhysical() and !combat.unite_vm.hasCounter()) {
                finished = true;
                break;
            }
        }
        try std.testing.expect(saw_body and finished);
        if (kind == 0) try std.testing.expect(combat.hp(member) < hp) else try std.testing.expect(combat.enemy_hp[0] < 5000);
    };
}

test "Beat battle host runs both recipient stages child and source damage through either owner" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/beat_battle.json"));
    defer content.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/beat_actor_library.json"));
    defer actors.deinit();
    const journey_content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer journey_content.deinit();
    const journey_actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer journey_actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const Recipients = struct { programs: []const battle.spell_scene.UniteReaction };
    const recipients = try std.json.parseFromSlice(Recipients, allocator, @embedFile("../fixtures/beat_recipients.json"), .{ .ignore_unknown_fields = true });
    defer recipients.deinit();
    const attachments = try std.json.parseFromSlice([]const struct { id: []const u8, offset: [2]i16 }, allocator, @embedFile("../fixtures/beat_attachments.json"), .{});
    defer attachments.deinit();
    var packet = effects.value;
    packet.schema = "suikoden-spell-scenes/50";
    const poses = try allocator.dupe(battle.spell_scene.HurtPose, packet.hurt_poses);
    defer allocator.free(poses);
    for (poses) |*pose| for (attachments.value) |source| if (std.mem.eql(u8, pose.id, source.id)) {
        pose.source_attachment = source.offset;
    };
    packet.hurt_poses = poses;
    const reactions = try allocator.alloc(battle.spell_scene.UniteReaction, packet.unite_reactions.len + 1);
    defer allocator.free(reactions);
    var count: usize = 0;
    for (packet.unite_reactions) |r| if (r.record != 27) {
        reactions[count] = r;
        count += 1;
    };
    @memcpy(reactions[count..], recipients.value.programs);
    packet.unite_reactions = reactions;
    try packet.validate(4096, 4096);
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    for (0..12) |case| {
        const scenario = case % 6;
        const journey = case >= 6;
        const owner = scenario % 2;
        const protected = scenario >= 2 and scenario < 4;
        var members: [6]battle.Member = undefined;
        var view = if (journey) journey_content.value else content.value;
        view.initial_party = content.value.initial_party;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(if (journey) &journey_actors.value else &actors.value);
        try combat.attachSpellScenes(&packet);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 27;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        combat.action_ticks = 100;
        const target = combat.partyCount();
        if (protected) combat.actor_conditions[target].protection_rounds = 1;
        combat.enemy_hp[0] = if (scenario >= 4) 1 else 5000;
        const hp = combat.enemy_hp[0];
        var tape = Tape{};
        var draws = tape.init();
        if (scenario == 0) for (0..2) |missing_field| {
            var refused = combat;
            var missing = packet;
            const absent_poses = try allocator.dupe(battle.spell_scene.HurtPose, poses);
            defer allocator.free(absent_poses);
            if (missing_field == 0) {
                for (absent_poses) |*pose| pose.source_attachment = null;
                missing.hurt_poses = absent_poses;
            } else missing.unite_reactions = reactions[0..count];
            refused.spell_scenes = &missing;
            var refused_draws = draws;
            try std.testing.expectError(error.UnsupportedCoordinatorAction, refused.tickReplay(.{}, &refused_draws));
            try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
            try std.testing.expectEqual(draws.cursor, refused_draws.cursor);
        };
        var saw: u5 = 0;
        var started: ?u32 = null;
        var damage_at: ?u32 = null;
        for (0..800) |_| {
            try combat.tickReplay(.{}, &draws);
            if (started == null and combat.unite_vm.owns(0) and combat.unite_vm.members[0].?.initialized) started = combat.camera_ticks;
            if (combat.unite_reactions[target]) |reaction| {
                if (reaction.variant == 1) {
                    try std.testing.expectEqual(started.? + 61, reaction.started_at);
                    try std.testing.expect(combat.uniteRecipientLocked(target));
                    saw |= 1;
                }
                if (reaction.variant == 0 and saw & 1 != 0) {
                    try std.testing.expectEqual(started.? + 329, reaction.started_at);
                    damage_at = reaction.started_at;
                    saw |= 2;
                    if (protected) try std.testing.expectEqual(hp, combat.enemy_hp[0]) else try std.testing.expect(combat.enemy_hp[0] < hp);
                }
            }
            if (combat.unite_vm.hasAuxiliary()) {
                saw |= 4;
                const index = combat.unite_vm.auxiliary_capacity - 1;
                const child = combat.unite_vm.auxiliary[index].?;
                try std.testing.expectEqual(@as(?u8, 27), child.graphic_record);
                if (child.visible) {
                    const quad = battle.layout.uniteAuxiliary(combat, index).?;
                    try std.testing.expectEqualDeep(combat.content.uniteGraphicPose("ronnie", child.currentFrame().pose, 27).?.sprite, quad.sprite);
                }
                if (child.blue_trail) |trail| if (trail.visible) {
                    const quads = battle.layout.uniteTrail(combat, combat.unite_vm.actors.len + index).?;
                    const expected = combat.content.uniteGraphicPose("ronnie", trail.pose, 27).?.trail.?;
                    for (quads, 0..) |quad, age| try std.testing.expectEqualDeep(expected[7 - age], quad.sprite);
                    saw |= 8;
                };
            }
            if (started) |start| if (combat.camera_ticks < start + 329) try std.testing.expectEqual(hp, combat.enemy_hp[0]);
            if (scenario >= 4 and combat.enemy_hp[0] == 0 and damage_at == null) {
                try std.testing.expectEqual(started.? + 329, combat.camera_ticks);
                damage_at = combat.camera_ticks;
                saw |= 2;
            }
            if (started != null and combat.active == null and !combat.unite_vm.hasActors() and !combat.hasUniteReturns()) {
                saw |= 16;
                break;
            }
        }
        try std.testing.expectEqual(@as(u5, 31), saw);
        try std.testing.expect(damage_at != null);
        try std.testing.expect(!combat.uniteRecipientLocked(target));
        try std.testing.expect(combat.uniteBoundaryFor(owner) == null);
    }
}

test "Trick battle host crosses each target once then returns both source actors" {
    const host = try hostFixture();
    defer host.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/trick_battle.json"));
    defer content.deinit();
    const library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/trick_actor_library.json"));
    defer library.deinit();
    const journey_content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer journey_content.deinit();
    const journey_library = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer journey_library.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var encounters = [_]battle.Encounter{content.value.encounters[0]};
    encounters[0].enemies = &.{ "bonbon", "bonbon", "bonbon" };
    encounters[0].positions = &.{ .{ .x = -128, .y = -80, .z = 0 }, .{ .x = -128, .y = 0, .z = 0 }, .{ .x = -192, .y = 80, .z = 0 } };
    encounters[0].enemy_rows = &.{ .front, .front, .front };
    encounters[0].source_slots = &.{ 0, 1, 2 };
    const bindings = try allocator.dupe(battle.actor_host.UniteBinding, library.value.unites);
    defer allocator.free(bindings);
    var invalid = library.value;
    invalid.unites = bindings;
    const original = bindings[14];
    invalid.schema = "suikoden-unite-actors/28";
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    invalid.schema = library.value.schema;
    bindings[14].wave_heights = null;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    bindings[14] = original;
    bindings[14].wave_heights.?[0] = 1;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    bindings[14] = original;
    bindings[14].damage_reaction = false;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    bindings[14] = original;
    for (0..16) |scenario| {
        const case = scenario % 8;
        const owner = case % 2;
        const protected = case >= 2 and case < 4;
        var view = if (scenario < 8) content.value else journey_content.value;
        view.initial_party = content.value.initial_party;
        view.encounters = &encounters;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(if (scenario < 8) &library.value else &journey_library.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.enterRoundMenu();
        combat.selected_unites[owner] = 14;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
        combat.action_ticks = 100;
        combat.enemy_hp = @splat(if (case >= 4 and case < 6) @as(u16, 1) else 5000);
        if (protected) for (0..3) |enemy| {
            combat.actor_conditions[combat.partyCount() + enemy].protection_rounds = 1;
        };
        var tape = Tape{};
        var draws = tape.init();
        var started: ?u32 = null;
        var contacts: u6 = 0;
        var rendered = false;
        var cleanup = false;
        var finished = false;
        var checked_rollback = false;
        var wave_sounds: usize = 0;
        for (0..600) |_| {
            var inactive_contact = false;
            if (combat.trick_wave) |wave| if (wave.wave.phase == .sweep and wave.wave.age == 16) {
                if (case == 0) {
                    var refused = combat;
                    const short_values = [_]u15{ 10, 20, 30 };
                    var short = rules.Draws{ .values = &short_values };
                    try std.testing.expectError(error.RandomInputExhausted, refused.tickReplay(.{}, &short));
                    try std.testing.expectEqualDeep(combat.enemy_hp, refused.enemy_hp);
                    try std.testing.expectEqualDeep(combat.trick_wave, refused.trick_wave);
                    try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
                    try std.testing.expectEqual(@as(usize, 0), short.cursor);
                    checked_rollback = true;
                }
                if (case >= 6) {
                    combat.enemy_hp[1] = 0;
                    inactive_contact = true;
                }
            };
            const before_draws = draws.cursor;
            try combat.tickReplay(.{}, &draws);
            for (combat.unite_vm.takeSounds()) |sound| if (sound.id == 0x513 or sound.id == 0x81B) {
                wave_sounds += 1;
            };
            if (inactive_contact) {
                try std.testing.expectEqual(before_draws + 2, draws.cursor);
                try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[1]);
                combat.enemy_hp[1] = 5000;
            }
            if (started == null and combat.unite_vm.owns(0) and combat.unite_vm.members[0].?.initialized) started = combat.camera_ticks;
            if (combat.trick_wave) |wave| {
                if (wave.wave.animation_updates[0] == 1) try std.testing.expectEqual(started.? + 99, combat.camera_ticks);
                const newly = wave.wave.hit & ~contacts;
                for (0..3) |enemy| if (newly & (@as(u6, 1) << @as(u3, @intCast(enemy))) != 0) {
                    try std.testing.expectEqual(started.? + @as(u32, if (enemy < 2) 179 else 187), combat.camera_ticks);
                    if (protected or (case >= 6 and enemy == 1)) try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[enemy]) else try std.testing.expect(combat.enemy_hp[enemy] < (if (case >= 4 and case < 6) @as(u16, 1) else 5000));
                };
                contacts = wave.wave.hit;
                if (wave.wave.enabled == 255 and wave.wave.phase == .rise and wave.wave.age >= 32) {
                    for (0..8) |index| {
                        const quad = battle.layout.uniteAuxiliary(combat, 19 + 6 * 5 + index).?;
                        const clip = library.value.animations.find("juppo").?.find(19).?;
                        var age = wave.wave.animation_updates[index] % 11;
                        const pose = for (clip.frames) |frame| {
                            if (age < frame.updates) break frame.pose;
                            age -= frame.updates;
                        } else unreachable;
                        try std.testing.expectEqualDeep(combat.content.uniteGraphicPose("juppo", pose, 14).?.sprite, quad.sprite);
                    }
                    rendered = true;
                }
                if (wave.wave.finished) {
                    try std.testing.expectEqual(started.? + 276, combat.camera_ticks);
                    try std.testing.expect(combat.hasUniteReturns());
                    cleanup = true;
                }
            }
            if (started != null and combat.active == null and !combat.unite_vm.hasActors() and !combat.hasUniteReturns()) {
                finished = true;
                break;
            }
        }
        try std.testing.expectEqual(@as(u6, 7), contacts);
        try std.testing.expect(rendered and cleanup and finished);
        try std.testing.expectEqual(@as(usize, 5), wave_sounds);
        if (case == 0) try std.testing.expect(checked_rollback);
        if (case >= 6) try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[1]);
        for (0..2) |member| try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[member]);
        for (0..3) |enemy| try std.testing.expect(!combat.uniteRecipientLocked(combat.partyCount() + enemy));
    }
}

test "all normal journey Unite rosters finish every owner mixed rounds and reject pre-start knockouts" {
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const host = try hostFixture();
    defer host.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try h.journeyScenes(arena.allocator(), effects.value);
    const enemies = try arena.allocator().dupe(battle.Profile, content.value.enemies);
    for (enemies) |*enemy| enemy.max_hp = 5000;
    var cases: usize = 0;
    for (actors.value.unites) |binding| for (0..binding.members.len) |owner| for (0..8) |mode| {
        const protected = mode == 1;
        const lethal = mode == 2 or mode == 5;
        const mixed = mode >= 3 and mode <= 5;
        const cancelled = mode >= 6;
        var ids: [6][]const u8 = undefined;
        var count: usize = 0;
        for (binding.members) |member| {
            ids[count] = member.id;
            count += 1;
        }
        for (content.value.initial_party.?) |identifier| {
            var duplicate = false;
            for (ids[0..count]) |id| duplicate = duplicate or std.mem.eql(u8, id, identifier);
            if (duplicate or count == ids.len) continue;
            ids[count] = identifier;
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 6), count);
        var view = content.value;
        view.initial_party = &ids;
        view.enemies = enemies;
        if (mode == 7) {
            const legacy = try arena.allocator().dupe(battle.Profile, enemies);
            for (legacy) |*enemy| enemy.action_policy = .attack;
            view.enemies = legacy;
        }
        const graphics = try arena.allocator().alloc(battle.UniteGraphic, view.unite_graphics.len);
        var graphic_count: usize = 0;
        for (view.unite_graphics) |graphic| {
            var selected = graphic;
            for (binding.members) |member| if (!mixed and member.fan != null and graphic.record == null and std.mem.eql(u8, graphic.id, member.id)) {
                const resource = actors.value.animations.find(member.id).?;
                const fan_pose = resource.find(member.fan.?.animation).?.frames[0].pose;
                const poses = try arena.allocator().alloc(battle.UniteGraphicPose, graphic.poses.len);
                var used: usize = 0;
                for (graphic.poses) |pose| {
                    if (pose.id == fan_pose and pose.id != 0) continue;
                    poses[used] = pose;
                    if (pose.id == fan_pose) poses[used].sprite.rect.y = 0;
                    used += 1;
                }
                selected.poses = poses[0..used];
            };
            graphics[graphic_count] = selected;
            graphic_count += 1;
        }
        view.unite_graphics = graphics[0..graphic_count];
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.encounter = 1;
        combat.startEncounter();
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&packet);
        for (combat.progress.party) |*member| {
            member.max_hp = 5000;
            member.hp = 5000;
        }
        combat.actions = @splat(null);
        combat.selected_unites[owner] = binding.record;
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        if (combat.uniteBoundaryFor(owner) == null) std.debug.print("missing normal Unite {d} {s}\n", .{ binding.record, binding.name });
        try std.testing.expect(combat.uniteBoundaryFor(owner) != null);
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.acted[owner] = false;
        const item_owner = binding.members.len;
        const lost_member = (owner + 1) % binding.members.len;
        if (cancelled) {
            for (0..binding.members.len) |member| combat.acted[member] = false;
            combat.progress.party[lost_member].hp = 0;
            combat.progress.party[lost_member].inventory.slots = @splat(null);
            combat.markPartyKnockout(lost_member);
            try std.testing.expect(combat.commitPartyKnockout(lost_member));
        }
        if (lethal) combat.enemy_hp[0] = 1;
        if (mixed) {
            combat.progress.party[item_owner].inventory.slots = @splat(null);
            combat.progress.party[item_owner].inventory.slots[0] = .{ .id = .medicine, .uses = 6 };
            combat.progress.party[item_owner].hp = 4000;
            combat.actions[item_owner] = .{ .item = .{ .slot = 0, .target = item_owner } };
            combat.acted[item_owner] = false;
            combat.base_stats[if (mode == 4) item_owner else owner].speed = 999;
            for (combat.partyCount()..combat.partyCount() + combat.enemyCount()) |enemy| combat.acted[enemy] = false;
        }
        if (protected) for (combat.partyCount()..combat.partyCount() + combat.enemyCount()) |enemy| {
            combat.actor_conditions[enemy].protection_rounds = 2;
        };
        const charges = members;
        var item_completed = false;
        var values: [8192]u15 = @splat(51);
        var draws = rules.Draws{ .values = &values };
        if (cancelled) {
            const before = combat.acted;
            combat.replay_draws = &draws;
            try std.testing.expect(combat.startUniteAction(owner, 0) == .rejected);
            combat.replay_draws = null;
            try std.testing.expectEqual(@as(usize, 0), draws.cursor);
            try std.testing.expectEqualDeep(before, combat.acted);
            try std.testing.expect(combat.uniteBoundaryFor(owner) != null and combat.active == null and !combat.hasLiveUniteActors());
        }
        var saw_actors = false;
        var saw_fan = false;
        var saw_item = false;
        var first_item: ?bool = null;
        var retried = false;
        var saw_assists_finish = false;
        for (0..4000) |_| {
            var advanced = false;
            if (lethal and saw_actors and !retried) {
                const before = combat;
                const before_members = members;
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                if (combat.tickReplay(.{}, &draws)) |_| {
                    advanced = true;
                } else |err| {
                    try std.testing.expectEqual(error.RandomInputExhausted, err);
                    try std.testing.expectEqualDeep(before_members, members);
                    try std.testing.expectEqualDeep(before, combat);
                    try std.testing.expectEqual(cursor, draws.cursor);
                    retried = true;
                }
                draws.values = &values;
            }
            if (!advanced) combat.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("normal Unite {d} owner={d} mode={d} tick={d}: {s}\n", .{ binding.record, owner, mode, combat.camera_ticks, @errorName(err) });
                return err;
            };
            if (first_item == null and (combat.medicine_action != null or combat.hasLiveUniteActors())) first_item = combat.medicine_action != null;
            saw_item = saw_item or combat.medicine_action != null;
            saw_actors = saw_actors or combat.hasLiveUniteActors();
            for (combat.unite_vm.members, 0..) |maybe, slot| if (maybe) |member| if (member.fan) |fan| if (fan.visible) {
                const quad = battle.layout.uniteAuxiliary(combat, combat.unite_vm.auxiliary.len + slot * 5) orelse return error.MissingScopedFan;
                const resource = actors.value.animations.resources[member.resource];
                const animation = binding.members[slot].fan.?.animation;
                try std.testing.expectEqualDeep(combat.content.uniteGraphicPose(resource.id, resource.find(animation).?.frames[0].pose, binding.record).?.sprite, quad.sprite);
                saw_fan = true;
            };
            if (cancelled and combat.phase == .resolving and combat.uniteBoundaryFor(owner) == null) {
                var finished = true;
                for (0..binding.members.len) |member| finished = finished and combat.acted[member];
                saw_assists_finish = saw_assists_finish or finished;
            }
            if (combat.medicine_action) |item_state| item_completed = item_completed or (item_state.owner_released and item_state.target_released);
            if (combat.phase != .resolving) break;
        }
        if (combat.phase != .battle_menu or combat.round != 2 or saw_actors != !cancelled) std.debug.print("unfinished normal Unite {d} owner={d} mode={d} tick={d}\n", .{ binding.record, owner, mode, combat.camera_ticks });
        try std.testing.expect(combat.phase == .battle_menu and combat.round == 2 and saw_actors == !cancelled);
        var fan_required = false;
        for (binding.members) |member| fan_required = fan_required or member.fan != null;
        try std.testing.expectEqual(fan_required and !cancelled, saw_fan);
        var damaged = false;
        for (combat.enemy_hp[0..combat.enemyCount()]) |hp| {
            damaged = damaged or hp < 5000;
            if (protected) try std.testing.expectEqual(@as(u16, 5000), hp);
        }
        try std.testing.expectEqual(!protected and !cancelled, damaged);
        if (cancelled) {
            try std.testing.expect(saw_assists_finish);
            try std.testing.expect(combat.uniteBoundaryFor(owner) == null);
            try std.testing.expectEqual(@as(u16, 0), combat.progress.party[lost_member].hp);
            for (combat.unbalanced[0..combat.partyCount()]) |recovery| try std.testing.expectEqual(@as(u8, 0), recovery);
        }
        if (lethal) {
            try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
            try std.testing.expect(retried);
        }
        if (mixed) {
            try std.testing.expect(saw_item);
            try std.testing.expectEqual(@as(?bool, mode == 4), first_item);
            try std.testing.expectEqual(@as(u16, 5), combat.progress.party[item_owner].inventory.slots[0].?.uses);
            try std.testing.expect(item_completed);
        }
        for (charges, members) |before, after| try std.testing.expectEqualDeep(before.rune_charges, after.rune_charges);
        const settled = combat.enemy_hp;
        for (0..500) |_| {
            if (!combat.unite_vm.hasActors()) break;
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqualDeep(settled, combat.enemy_hp);
            try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
        }
        try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasUniteReturns());
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 680), cases);
}

test "current Region C catalogue binds all formations and batch Unite rosters" {
    const region = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_unites_actor_library.json"));
    defer region.deinit();
    const travel = try @import("world").load(allocator, @import("world").json_c);
    defer travel.deinit();
    const normal = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer normal.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const host = try hostFixture();
    defer host.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try h.journeyScenes(arena.allocator(), effects.value);
    const original = try region.value.view(travel.value, normal.value);
    try std.testing.expectEqualStrings(normal.value.schema, original.schema);
    try std.testing.expectEqualDeep(normal.value.medicine_timings, original.medicine_timings);
    try std.testing.expectEqual(@as(usize, 8), region.value.actor_content.?.encounters.len);
    try std.testing.expectEqual(@as(usize, 53), original.party.len);
    var cases: usize = 0;
    for (0..actors.value.unites.len + 1) |command| for (original.encounters, 0..) |encounter, encounter_index| {
        var ids: [6][]const u8 = undefined;
        var count: usize = 0;
        if (command != 0) for (actors.value.unites[command - 1].members) |member| {
            ids[count] = member.id;
            count += 1;
        };
        for (normal.value.initial_party.?) |identifier| {
            var duplicate = false;
            for (ids[0..count]) |id| duplicate = duplicate or std.mem.eql(u8, id, identifier);
            if (duplicate or count == ids.len) continue;
            ids[count] = identifier;
            count += 1;
        }
        try std.testing.expectEqual(ids.len, count);
        var base = original;
        base.initial_party = &ids;
        var members: [6]battle.Member = undefined;
        const seed = try battle.State.init(base, items.value, &members, 17);
        try std.testing.expect(region.value.supports(encounter));
        const bound = try region.value.bindPresentation(allocator, base, encounter_index, seed.progress.party, seed.formation);
        var view = bound.content;
        try view.validateAtlas(region.value.presentation.?.atlas_width, region.value.presentation.?.atlas_height);
        const enemies = try arena.allocator().dupe(battle.Profile, view.enemies);
        for (enemies) |*enemy| enemy.max_hp = 5000;
        view.enemies = enemies;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.encounter = bound.encounter;
        combat.startEncounter();
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&packet);
        for (combat.progress.party) |*member| {
            member.max_hp = 5000;
            member.hp = 5000;
        }
        if (command != 0) {
            combat.selected_unites[0] = actors.value.unites[command - 1].record;
            combat.choose(0);
            combat.queue(.{ .unite = 0 });
            try std.testing.expect(combat.uniteBoundaryFor(0) != null);
        }
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        combat.phase = .resolving;
        combat.round_start_pending = false;
        combat.acted = @splat(command != 0);
        combat.acted[0] = false;
        combat.coordinator = if (command == 0) .{ .stage = .select, .current_actor = 0, .completed = true, .remaining = 0 } else .{ .stage = .dispatch, .current_actor = 0 };
        const charges = members;
        var values: [16384]u15 = @splat(51);
        var draws = rules.Draws{ .values = &values };
        var saw_unite = false;
        for (0..4000) |_| {
            combat.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("current C {s} command={d} tick={d}: {s}\n", .{ encounter.id, command, combat.camera_ticks, @errorName(err) });
                return err;
            };
            saw_unite = saw_unite or combat.hasLiveUniteActors();
            if (combat.phase != .resolving) break;
        }
        if (combat.phase != .battle_menu or combat.round != 2) std.debug.print("unfinished current C {s} command={d} tick={d}\n", .{ encounter.id, command, combat.camera_ticks });
        try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
        try std.testing.expectEqual(command != 0, saw_unite);
        if (command != 0) {
            var damaged = false;
            for (combat.enemy_hp[0..combat.enemyCount()]) |hp| damaged = damaged or hp < 5000;
            try std.testing.expect(damaged);
        }
        for (charges, members) |before, after| {
            try std.testing.expectEqualDeep(before.rune_charges, after.rune_charges);
            try std.testing.expect(after.hp > 0);
        }
        for (0..500) |_| {
            if (!combat.unite_vm.hasActors()) break;
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasUniteReturns());
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 264), cases);
}
