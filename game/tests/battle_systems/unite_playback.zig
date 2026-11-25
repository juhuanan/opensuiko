const std = @import("std");
const h = @import("helpers.zig");
const allocator = h.allocator;
const hostFixture = h.hostFixture;
const Fixture = h.Fixture;
const battle = h.battle;
const rules = h.rules;
const field = h.field;
const combat_session = h.combat_session;
const unite_mod = h.unite_mod;
const Tape = h.Tape;

test "Unite return poses resolve through the world actor atlas after controller handoff" {
    var fixture = try Fixture.open(null);
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/world_b_party_art.json", allocator, .limited(512 * 1024));
    defer allocator.free(bytes);
    const art = try battle.world_art.load(allocator, bytes);
    defer art.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.active = null;
    combat.content.world_art = art.value;
    for ([_]struct { actor: usize, elapsed: u16, pose: u16 }{
        .{ .actor = 1, .elapsed = 149, .pose = 7 },
        .{ .actor = 2, .elapsed = 154, .pose = 10 },
        .{ .actor = 4, .elapsed = 112, .pose = 8 },
        .{ .actor = 5, .elapsed = 112, .pose = 8 },
    }) |sample| {
        combat.unite_returns[sample.actor] = .{ .owner = sample.actor, .target = 6, .ticks = sample.elapsed, .target_released = true, .handoff_at = 0 };
        const visual = battle.world_art.actorSample(art.value, &combat, sample.actor);
        try std.testing.expectEqual(sample.pose, visual.sample.pose);
        const layout = battle.layout.actorLayout(combat, sample.actor);
        try std.testing.expectEqualDeep(art.value.actors[sample.actor].poses[sample.pose], layout.sprite);
        try std.testing.expect(std.math.isFinite(layout.point.x) and std.math.isFinite(layout.point.y));
    }
    combat.unite_returns = @splat(null);
    combat.active = .{ .actor = 4, .partner = 5, .target = 6, .kind = .unite };
    combat.action_ticks = 62;
    const target = battle.layout.worldPosition(&combat, 6);
    combat.issueUniteCameraRequests(62);
    for (0..21) |_| combat.advanceActorCamera();
    const block = battle.layout.currentCamera(combat);
    try std.testing.expectEqual(@as(i32, @intFromFloat(target.x)), block.focus[0]);
    try std.testing.expectEqual(@as(i32, @intFromFloat(target.y)), block.focus[1]);
    try std.testing.expectEqual(@as(i32, 0), block.focus[2]);
    const scene = battle.layout.sceneArt(combat);
    const center = battle.presentation.project(scene.camera, .{ .x = @floatFromInt(block.focus[0]), .y = @floatFromInt(block.focus[1]), .z = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 320), center.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 240), center.y, 0.01);
}

test "Fisherman releases its pending enemy after reaction while members still return" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    for ([_]usize{ 4, 5 }) |owner| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        var tape = Tape{};
        var draws = tape.init();
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        while (combat.phase == .command) combat.queue(.defend);
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        try combat.tickReplay(.{ .confirm = true }, &draws);
        combat.acted = @splat(true);
        combat.acted[owner] = false;
        var guard: usize = 0;
        while (combat.active == null and guard < 20) : (guard += 1) try combat.tickReplay(.{}, &draws);
        try std.testing.expect(guard < 20 and combat.active.?.kind == .unite);
        const started = combat.camera_ticks - combat.effectTicks();
        while (combat.active != null and guard < 200) : (guard += 1) try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(u32, 92), combat.camera_ticks - started);
        combat.acted[combat.partyCount()] = false;
        while (combat.camera_ticks - started < 104 and guard < 250) : (guard += 1) {
            try std.testing.expect(combat.coordinatorLocked(combat.partyCount()));
            try combat.tickReplay(.{}, &draws);
            try std.testing.expect(combat.active == null);
        }
        try std.testing.expect(guard < 250);
        try std.testing.expect(!combat.coordinatorLocked(combat.partyCount()));
        try std.testing.expect(combat.coordinatorLocked(4) and combat.coordinatorLocked(5));
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(u32, 105), combat.camera_ticks - started);
        try std.testing.expectEqual(combat.partyCount(), combat.active.?.actor);
        try std.testing.expect(combat.hasUniteReturns());
    }
}

test "pair Unite reactions and common impacts survive handoff without consuming random draws" {
    const host = try hostFixture();
    defer host.deinit();
    const packet_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(packet_bytes);
    const packet = try battle.spell_scene.load(allocator, packet_bytes);
    defer packet.deinit();
    const world_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/world_b_party_art.json", allocator, .limited(512 * 1024));
    defer allocator.free(world_bytes);
    const art = try battle.world_art.load(allocator, world_bytes);
    defer art.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    for ([_]usize{ 1, 2, 4, 5 }) |owner| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachSpellScenes(&packet.value);
        var tape = Tape{};
        var draws = tape.init();
        combat.choose(owner);
        combat.queue(.{ .unite = 0 });
        while (combat.phase == .command) combat.queue(.defend);
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        try combat.tickReplay(.{ .confirm = true }, &draws);
        combat.acted = @splat(true);
        combat.acted[owner] = false;
        var guard: usize = 0;
        while (combat.active == null and guard < 20) : (guard += 1) try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active.?.kind == .unite);
        try std.testing.expect(combat.hasSourceEffect());
        const impact = combat.impactTick();
        const started = combat.camera_ticks - combat.effectTicks();
        while (combat.camera_ticks - started < impact and guard < 200) : (guard += 1) try combat.tickReplay(.{}, &draws);
        const target = combat.partyCount();
        try std.testing.expect(combat.unite_reactions[target] != null);
        const origin = combat.unite_reactions[target].?.origin_q12;
        const last: u32 = if (owner < 3) 37 else 21;
        for (0..last + 1) |age| {
            try std.testing.expectEqual(age < last, combat.spellReaction(target) != null);
            const cursor = draws.cursor;
            const frame = combat.spellSceneFrame();
            const expected: usize = if (age < 2) 0 else if (owner >= 4) (if (age < 19) @as(usize, 1) else 0) else @as(usize, if (age < 20) 1 else 0) + @as(usize, if (age >= 6 and age < 26) 1 else 0) + @as(usize, if (age >= 10 and age < 30) 1 else 0);
            try std.testing.expectEqual(expected, frame.count);
            try std.testing.expectEqual(cursor, draws.cursor);
            if (age == 2) {
                const position = combat.uniteActorPosition(target).?;
                try std.testing.expect(position.x < @as(f32, @floatFromInt(origin[0] >> 12)));
                var world = combat;
                world.content.world_art = art.value;
                const scene = battle.layout.sceneArt(world);
                const expected_point = battle.presentation.project(scene.camera, position);
                const actual = battle.layout.actorLayout(world, target);
                try std.testing.expectApproxEqAbs(expected_point.x, actual.point.x, 0.001);
                try std.testing.expectApproxEqAbs(expected_point.y, actual.point.y, 0.001);
                try std.testing.expectApproxEqAbs(scene.sprite_scale, actual.scale, 0.001);
                const entry = packet.value.entries[world.spellReaction(target).?.entry.?];
                try std.testing.expectEqualDeep(battle.Rect{ .x = entry.x, .y = entry.y, .w = entry.w, .h = entry.h }, actual.sprite.rect);
            }
            if (owner >= 4 and age == 10) {
                var overlapping = combat;
                const scene_id = packet.value.indexOf("spell_9").?;
                var local = rules.Draws{ .bios_state = 17 };
                const instance = try battle.spell_scene.Instance.begin(&packet.value, scene_id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &local);
                overlapping.active = .{ .actor = 0, .target = target, .kind = .cast, .scene = instance };
                overlapping.action_ticks = 1;
                const plain = battle.spell_scene.frameAt(&packet.value, &instance, 1);
                try std.testing.expectEqual(plain.count + frame.count, overlapping.spellSceneFrame().count);
            }
            for (frame.commands[0..frame.count]) |command| {
                try std.testing.expect(command.texture != null);
                try std.testing.expectEqual(battle.spell_scene.Blend.@"opaque", command.blend);
                for (command.vertices) |point| try std.testing.expect(std.math.isFinite(point.x) and std.math.isFinite(point.y));
            }
            if (age < last) try combat.tickReplay(.{}, &draws);
        }
        if (owner >= 4) try std.testing.expect(combat.active == null and combat.hasUniteReturns());
        combat.startEncounter();
        try std.testing.expect(combat.unite_reactions[target] == null);
    }
}

test "Blacksmith delayed members and early returns retain all five source clock envelopes" {
    const host = try hostFixture();
    defer host.deinit();
    const packet_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(packet_bytes);
    const packet = try battle.spell_scene.load(allocator, packet_bytes);
    defer packet.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    var profiles: [11]battle.Profile = undefined;
    @memcpy(profiles[0..7], fixture.view.party);
    const ids = [_][]const u8{ "maas", "moose", "meese", "mace", "mose" };
    const cases = [_]struct { record: u8, members: [4]usize }{
        .{ .record = 5, .members = .{ 0, 1, 2, 3 } },
        .{ .record = 21, .members = .{ 0, 1, 2, 4 } },
        .{ .record = 22, .members = .{ 4, 1, 2, 3 } },
        .{ .record = 23, .members = .{ 0, 4, 2, 3 } },
        .{ .record = 24, .members = .{ 0, 1, 4, 3 } },
    };
    for (cases) |case| {
        for (0..5) |i| {
            profiles[i + 6] = fixture.content.value.party[2];
            profiles[i + 6].id = ids[i];
            profiles[i + 6].name = ids[i];
            profiles[i + 6].unite_scenes = &.{};
        }
        var initial: [6][]const u8 = .{ "maas", "moose", "meese", "mace", "yam_koo", "tai_ho" };
        var scenes: [4][1]battle.UniteScene = undefined;
        var frames: [4]battle.Frame = undefined;
        var ends: [4]u16 = undefined;
        for (case.members, 0..) |resource, i| {
            initial[i] = ids[resource];
            // Synthetic poses isolate playback; independent extraction qualifies these clocks.
            var track = fixture.content.value.party[2].uniteTrack(0).?;
            track.camera = &.{};
            track.start_after = @intCast(i * 45);
            track.reaction_on_hit = i < 3;
            track.motion.impact_tick = if (resource == 3) 72 else if (resource == 4) 70 else 71;
            track.motion.ready_tick = if (resource == 3) 76 else 75;
            track.motion.duration = if (resource == 3) 122 else if (resource == 4) 124 else 121;
            track.motion.return_start = track.motion.duration - 20;
            track.motion.stages = &.{};
            frames[i] = track.attack[0];
            frames[i].ticks = track.motion.duration;
            track.attack = frames[i..][0..1];
            track.trail = .{ .start = 13, .stop = 43, .poses = @splat(frames[i].pose) };
            scenes[i][0] = .{ .record = case.record, .track = track };
            profiles[resource + 6].unite_scenes = &scenes[i];
            ends[i] = track.start_after + track.motion.duration;
        }
        for (&profiles) |*profile| profile.item_art = null;
        fixture.view.schema = "suikoden-battle-trial/22";
        fixture.view.unite_graphics = &.{};
        fixture.view.party = &profiles;
        fixture.view.initial_party = &initial;
        try fixture.view.validate();
        const impact: u16 = if (case.record == 21) 206 else 208;
        const handoff: u16 = if (case.record == 21) 211 else 212;
        for (0..4) |owner| {
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
            combat.integration = .{ .host = host };
            try combat.attachSpellScenes(&packet.value);
            combat.base_stats[owner].speed = 999;
            combat.enterRoundMenu();
            combat.choose(owner);
            combat.queue(.{ .unite = 0 });
            var guard: usize = 0;
            while (combat.phase == .command and guard < 12) : (guard += 1) combat.queue(.defend);
            for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
                action.* = .defend;
            };
            var tape = Tape{};
            var draws = tape.init();
            if (case.record == 5 and owner == 0) {
                var missing = combat;
                var missing_members: [6]battle.Member = undefined;
                @memcpy(&missing_members, combat.progress.party);
                missing.progress.party = &missing_members;
                missing.spell_scenes = null;
                var missing_draws = draws;
                var refused = false;
                for (0..1000) |step| {
                    const flags = missing.unite_flags;
                    const hp_before = missing.enemy_hp;
                    const cursor = missing_draws.cursor;
                    missing.tickReplay(.{ .confirm = step == 0 }, &missing_draws) catch |err| {
                        try std.testing.expectEqual(error.UnsupportedCoordinatorAction, err);
                        try std.testing.expectEqualDeep(flags, missing.unite_flags);
                        try std.testing.expectEqualDeep(hp_before, missing.enemy_hp);
                        try std.testing.expectEqual(cursor, missing_draws.cursor);
                        refused = true;
                        break;
                    };
                }
                try std.testing.expect(refused);
            }
            try combat.tickReplay(.{ .confirm = true }, &draws);
            while ((combat.active == null or combat.active.?.kind != .unite) and guard < 1000) : (guard += 1) try combat.tickReplay(.{}, &draws);
            try std.testing.expect(guard < 1000);
            try std.testing.expectEqual(case.record, combat.uniteBoundaryFor(owner).?.record_index);
            try std.testing.expectEqual(impact, combat.impactTick());
            try std.testing.expectEqual(handoff, combat.actionDuration());
            const started = combat.camera_ticks - combat.effectTicks();
            var hp: u16 = 5000;
            var hp_changes: usize = 0;
            var reaction_count: usize = 0;
            var previous_reaction: ?u32 = null;
            var reactions: [4]u16 = undefined;
            for (case.members, 0..) |resource, ordinal| reactions[ordinal] = @as(u16, @intCast(45 * ordinal)) + @as(u16, if (resource == 3) 72 else if (resource == 4) 70 else 71) + 1;
            while (combat.active != null and combat.active.?.kind == .unite and guard < 1500) : (guard += 1) {
                const tick = combat.effectTicks();
                const boundary = combat.uniteBoundaryFor(owner).?;
                for (0..4) |member| {
                    const offset: u16 = @intCast(member * 45);
                    const waiting = tick < offset;
                    const completed = tick >= ends[member];
                    try std.testing.expectEqual(waiting, combat.uniteMemberWaiting(member));
                    try std.testing.expectEqual(tick -| offset, combat.animationTick(member));
                    try std.testing.expectEqual(completed, boundary.finished_members & (@as(u8, 1) << @intCast(member)) != 0);
                    try std.testing.expectEqual(!completed, combat.isActing(member));
                    try std.testing.expectEqual(!completed, combat.coordinatorLocked(member));
                    if (waiting) try std.testing.expectEqualDeep(combat.partyProfile(member).sprite, battle.layout.actorLayout(combat, member).sprite);
                    if (waiting or completed) try std.testing.expectEqualDeep(battle.layout.homePosition(&combat, member), battle.layout.worldPosition(&combat, member));
                }
                if (combat.unite_reactions[6]) |reaction| {
                    if (previous_reaction == null or previous_reaction.? != reaction.started_at) {
                        try std.testing.expect(reaction_count < 4);
                        try std.testing.expectEqual(reactions[reaction_count], tick);
                        try std.testing.expectEqual(case.record, reaction.record);
                        if (reaction_count < 3) try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[0]);
                        reaction_count += 1;
                        previous_reaction = reaction.started_at;
                    }
                    const age = combat.camera_ticks - reaction.started_at;
                    const cursor = draws.cursor;
                    const frame = combat.spellSceneFrame();
                    try std.testing.expectEqual(@as(usize, if (age >= 2 and age < 22) 1 else 0), frame.count);
                    try std.testing.expectEqual(cursor, draws.cursor);
                    if (age == 2) {
                        try std.testing.expect(combat.uniteActorPosition(6).?.x < @as(f32, @floatFromInt(reaction.origin_q12[0] >> 12)));
                        try std.testing.expect(combat.spellReaction(6).?.entry != null);
                    }
                }
                if (combat.enemy_hp[0] != hp) {
                    hp = combat.enemy_hp[0];
                    hp_changes += 1;
                    try std.testing.expectEqual(impact, tick);
                }
                if (case.record == 5 and owner == 0 and tick + 1 == reactions[0]) {
                    var clear_flag = combat;
                    var clear_members: [6]battle.Member = undefined;
                    @memcpy(&clear_members, combat.progress.party);
                    clear_flag.progress.party = &clear_members;
                    clear_flag.unite_flags[0] &= ~unite_mod.rules.hit_flag;
                    var clear_draws = draws;
                    try clear_flag.tickReplay(.{}, &clear_draws);
                    try std.testing.expect(clear_flag.unite_reactions[6] == null);
                    try std.testing.expectEqual(@as(u16, 5000), clear_flag.enemy_hp[0]);
                    try std.testing.expectEqual(draws.cursor, clear_draws.cursor);
                }
                var previous_points: [4]battle.presentation.ScreenPoint = undefined;
                for (&previous_points, 0..) |*point, member| point.* = battle.layout.actorLayout(combat, member).point;
                const cursor = draws.cursor;
                try combat.tickReplay(.{}, &draws);
                for (0..4) |member| {
                    const offset: u16 = @intCast(member * 45);
                    const visible = tick + 1 >= offset + 14 and tick + 1 <= offset + 42;
                    const trail = battle.layout.uniteTrail(combat, member);
                    try std.testing.expectEqual(visible, trail != null);
                    if (trail) |quads| {
                        try std.testing.expectEqualDeep(previous_points[member], quads[7].point);
                        for (quads) |quad| try std.testing.expectEqualDeep(frames[member].pose, quad.sprite);
                    }
                }
                for (ends) |end| if (tick + 1 == end) try std.testing.expectEqual(cursor, draws.cursor);
                for (reactions[0..3]) |at| if (tick + 1 == at) try std.testing.expectEqual(cursor, draws.cursor);
            }
            try std.testing.expect(guard < 1500);
            try std.testing.expectEqual(@as(usize, 1), hp_changes);
            try std.testing.expectEqual(@as(usize, 4), reaction_count);
            for (ends, 0..) |end, member| try std.testing.expectEqual(end > handoff, combat.uniteReturnFor(member) != null);
            try std.testing.expectEqual(handoff, combat.uniteReturnFor(3).?.ticks);
            while (combat.uniteBoundaryFor(owner) != null and guard < 2000) : (guard += 1) try combat.tickReplay(.{}, &draws);
            try std.testing.expect(guard < 2000);
            try std.testing.expectEqual(@as(u32, ends[3]), combat.camera_ticks - started);
            for (0..4) |member| {
                try std.testing.expect(combat.uniteReturnFor(member) == null);
                try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[member]);
            }
        }
    }
}

test "Unite actor content fingerprints retain current checkpoint bindings and reject mismatches" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const packet = try battle.actor_host.loadBundle(allocator, bytes);
    defer packet.deinit();
    var rebound = packet.value;
    var members: [6]battle.Member = undefined;
    var source = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    source.integration = .{ .host = host };
    const old_identity = try combat_session.fingerprint(source);
    try source.attachUniteActors(&packet.value);
    var remapped = packet.value;
    var scenes: [32]battle.actor_host.UniteBinding = undefined;
    @memcpy(&scenes, remapped.unites);
    scenes[0].record = 1;
    scenes[1].record = 0;
    remapped.unites = &scenes;
    try std.testing.expectError(error.InvalidUniteSceneBinding, source.attachUniteActors(&remapped));
    try std.testing.expect(source.unite_actors == &packet.value);
    var identity = try combat_session.fingerprint(source);
    try std.testing.expect(!std.mem.eql(u8, &old_identity, &identity));
    const entry = combat_session.Entry{ .id = "unite-checkpoint", .receipt = "1", .content_id = "fixture", .encounter_id = source.content.encounters[source.encounter].id, .content_fingerprint = &identity };
    var scratch: [6]battle.Member = undefined;
    var draws = rules.Draws{ .bios_state = 17 };
    var session = try combat_session.Session.begin(entry, source, &scratch, draws);
    const checkpoint = try session.capture(draws);
    session.state.unite_actors = &rebound;
    try session.restore(checkpoint, &draws);
    try std.testing.expect(session.state.unite_actors == &rebound);
    session.state.unite_actors = null;
    try std.testing.expectError(error.CombatContentMismatch, session.restore(checkpoint, &draws));
}

test "native Unite dispatch holds selection0 and samples the first actor pass on update1" {
    const host = try hostFixture();
    defer host.deinit();
    var fixture = try Fixture.open(.{ .id = "bonbon", .max_hp = 5000 });
    defer fixture.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const programs = try battle.actor_host.loadBundle(allocator, bytes);
    defer programs.deinit();
    const rebound = try battle.actor_host.loadBundle(allocator, bytes);
    defer rebound.deinit();
    const effects_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effects_bytes);
    const effects = try battle.spell_scene.load(allocator, effects_bytes);
    defer effects.deinit();
    for ([_]usize{ 1, 2, 4, 5, 1 }, 0..) |initiator, variant| {
        const extra: u16 = if (variant == 4) 16 else 0;
        var bundle = programs.value;
        const scripts = try allocator.dupe(battle.actor_program.Program, bundle.programs.programs);
        defer allocator.free(scripts);
        bundle.programs.programs = scripts;
        const gremio = for (scripts, 0..) |script, index| {
            if (std.mem.eql(u8, script.id, "gremio/unite_9")) break index;
        } else return error.MissingUniteProgram;
        const instructions = try allocator.dupe(battle.actor_program.Instruction, scripts[gremio].instructions);
        defer allocator.free(instructions);
        instructions[3].delay += extra;
        scripts[gremio].instructions = instructions;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&bundle);
        try combat.attachSpellScenes(&effects.value);
        combat.enterRoundMenu();
        combat.choose(initiator);
        combat.queue(.{ .unite = 0 });
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        // Enter the production coordinator at its successful dispatch pass.
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.action_ticks = 100;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = initiator, .elapsed = 100 };
        var tape = Tape{};
        var draws = tape.init();
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(u16, 101), combat.action_ticks);
        try std.testing.expectEqual(@as(u16, 101), combat.active.?.started_at);
        try std.testing.expectEqual(@as(u16, 0), combat.effectTicks());
        const selected_at = combat.camera_ticks;
        const participants: [2]usize = if (initiator < 4) .{ 1, 2 } else .{ 4, 5 };
        for (participants) |participant| {
            try std.testing.expect(combat.unite_vm.owns(participant));
            try std.testing.expect(combat.uniteMemberWaiting(participant));
            try std.testing.expectEqualDeep(combat.partyProfile(participant).sprite, battle.layout.actorLayout(combat, participant).sprite);
            try std.testing.expectEqualDeep(battle.layout.homePosition(&combat, participant), battle.layout.worldPosition(&combat, participant));
        }
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(u16, 1), combat.effectTicks());
        for (participants) |participant| {
            try std.testing.expect(combat.unite_vm.members[participant].?.initialized);
            try std.testing.expect(!combat.uniteMemberWaiting(participant));
            // Independent raw F-table check: Pahn advances to pose3; the other three to pose1.
            const pose: u16 = if (participant == 2) 3 else 1;
            const sprite = combat.content.uniteGraphic(combat.partyProfile(participant).id, pose) orelse for (combat.uniteTrack(participant).?.attack) |frame| {
                if (frame.source_pose == pose) break frame.pose;
            } else return error.MissingUnitePose;
            try std.testing.expectEqualDeep(sprite, battle.layout.actorLayout(combat, participant).sprite);
        }
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[0]);
        const impact: u32 = if (initiator == 1) 76 + @as(u32, extra) else if (initiator == 2) 68 else 83;
        var previous_hp: u16 = 5000;
        var hp_changes: usize = 0;
        var age: u32 = 1;
        while (combat.active != null and combat.active.?.kind == .unite and age < 150) {
            age = combat.camera_ticks - selected_at;
            try std.testing.expectEqual(age, combat.effectTicks());
            for (participants) |participant| {
                const ring = combat.unite_trails[participant];
                const live = combat.unite_vm.actors[participant].blue_trail;
                const visible = live != null and live.?.visible;
                try std.testing.expectEqual(visible, ring.visible);
                const quads = battle.layout.uniteTrail(combat, participant);
                try std.testing.expectEqual(visible, quads != null);
                if (quads) |trail| {
                    try std.testing.expectEqual(live.?.next, ring.next);
                    const slot = (@as(usize, live.?.next) + 7) % 8;
                    try std.testing.expectEqual(live.?.points[slot][0], trail[7].point.x);
                    try std.testing.expectEqual(live.?.points[slot][1], trail[7].point.y);
                    try std.testing.expectEqual(live.?.depth, trail[7].point.depth);
                }
            }
            if (age == 40 and variant == 0) {
                var identity = try combat_session.fingerprint(combat);
                const entry = combat_session.Entry{ .id = "live-unite", .receipt = "1", .content_id = "fixture", .encounter_id = combat.content.encounters[combat.encounter].id, .content_fingerprint = &identity };
                var session = combat_session.Session{ .entry = entry, .state = combat, .draws = draws, .integration = host };
                const checkpoint = try session.capture(draws);
                session.state.unite_actors = &rebound.value;
                try session.restore(checkpoint, &draws);
                const member = session.state.unite_vm.members[initiator].?;
                try std.testing.expect(session.state.unite_vm.actors[initiator].machine.?.instructions.ptr == rebound.value.programs.programs[member.program].instructions.ptr);
                var invalid = checkpoint;
                invalid.state.unite_vm.members[initiator].?.resource = 255;
                try std.testing.expectError(error.InvalidActorPlayback, session.restore(invalid, &draws));
                try std.testing.expectEqual(member.resource, session.state.unite_vm.members[initiator].?.resource);
            }
            if (combat.enemy_hp[0] != previous_hp) {
                try std.testing.expectEqual(impact, age);
                hp_changes += 1;
                previous_hp = combat.enemy_hp[0];
            }
            if (initiator >= 4 and age == 62) try std.testing.expectEqual(@as(u16, 20), combat.actor_camera.?.remaining[0]);
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(@as(usize, 1), hp_changes);
        const handoff: u32 = if (extra > 0) 148 else if (initiator < 4) 137 else 92;
        try std.testing.expectEqual(handoff, combat.camera_ticks - selected_at);
        while (combat.hasUniteReturns() and combat.camera_ticks - selected_at < 250) {
            try combat.tickReplay(.{}, &draws);
            if (initiator >= 4 and combat.camera_ticks - selected_at == 104) {
                for (participants) |participant| try std.testing.expect(combat.uniteReturnFor(participant).?.target_released);
            }
        }
        try std.testing.expect(!combat.hasUniteReturns());
        try std.testing.expect(combat.replay_unsupported == null);
        try std.testing.expect(combat.unite_boundaries[initiator] == null);
        for (participants) |participant| {
            try std.testing.expect(!combat.unite_vm.owns(participant));
            try std.testing.expectEqual(@as(u8, if (initiator >= 4) 2 else 0), combat.unbalanced[participant]);
        }
        try std.testing.expectEqual(@as(usize, if (initiator >= 4) 4 else 2), draws.cursor);
    }
}

test "live qualified Unite batches retain source clocks and independent member ownership" {
    const host = try hostFixture();
    defer host.deinit();
    const content_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/blacksmith_battle.json", allocator, .limited(1024 * 1024));
    defer allocator.free(content_bytes);
    const exported = try battle.load(allocator, content_bytes);
    defer exported.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/battle_actor_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    const programs = try battle.actor_host.loadBundle(allocator, bytes);
    defer programs.deinit();
    const effects_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/spell_scene_library.json", allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(effects_bytes);
    const effects = try battle.spell_scene.load(allocator, effects_bytes);
    defer effects.deinit();
    for ([_]u8{ 0, 1, 4, 5, 7, 11, 12, 18, 21, 22, 23, 24, 26, 5 }, 0..) |record, variant| {
        const extra: u16 = if (variant == 13) 7 else 0;
        var bundle = programs.value;
        var bindings: [32]battle.actor_host.UniteBinding = undefined;
        @memcpy(&bindings, bundle.unites);
        bundle.unites = &bindings;
        var scheduled: [4]battle.actor_host.MemberBinding = undefined;
        const count = bindings[record].members.len;
        @memcpy(scheduled[0..count], bindings[record].members);
        scheduled[count - 1].start_after += extra;
        bindings[record].members = scheduled[0..count];
        const binding = bundle.find(record).?;
        const profiles = try allocator.dupe(battle.Profile, exported.value.party);
        defer allocator.free(profiles);
        var initial: [6][]const u8 = .{ "", "", "", "", "hero", "gremio" };
        var scenes: [4][1]battle.UniteScene = undefined;
        var ends: [4]u16 = undefined;
        var hits: [4]u16 = undefined;
        var handoff: u16 = 0;
        for (binding.members, 0..) |member, ordinal| {
            initial[ordinal] = member.id;
            const profile_index = for (profiles, 0..) |profile, index| {
                if (std.mem.eql(u8, profile.id, member.id)) break index;
            } else return error.MissingUniteParticipant;
            var track = profiles[profile_index].uniteTrack(record).?;
            track.reaction_on_hit = false; // The imported binding owns assist dispatch.
            scenes[ordinal][0] = .{ .record = record, .track = track };
            profiles[profile_index].unite_scenes = &scenes[ordinal];
            const clock: [3]u16 = switch (record) {
                0 => if (std.mem.eql(u8, member.id, "pahn")) .{ 67, 136, 189 } else .{ 75, 131, 177 },
                1 => .{ 82, 91, 143 },
                4 => if (std.mem.eql(u8, member.id, "kanak")) .{ 76, 141, 197 } else .{ 88, 142, 188 },
                7 => if (std.mem.eql(u8, member.id, "flik")) .{ 172, 249, 295 } else if (std.mem.eql(u8, member.id, "alen")) .{ 185, 246, 292 } else .{ 201, 246, 292 },
                26 => if (std.mem.eql(u8, member.id, "fu_su_lu")) .{ 136, 197, 243 } else if (std.mem.eql(u8, member.id, "gon")) .{ 98, 153, 199 } else .{ 98, 143, 189 },
                11 => if (std.mem.eql(u8, member.id, "gon")) .{ 98, 153, 199 } else .{ 98, 143, 189 },
                12 => if (std.mem.eql(u8, member.id, "futch")) .{ 96, 96, 145 } else .{ 90, 90, 136 },
                18 => .{ 64, 135, 180 },
                else => if (std.mem.eql(u8, member.id, "mace")) .{ 74, 78, 124 } else if (std.mem.eql(u8, member.id, "mose")) .{ 72, 77, 126 } else .{ 73, 77, 123 },
            };
            hits[ordinal] = member.start_after + binding.dispatch_after.? + clock[0];
            ends[ordinal] = member.start_after + binding.dispatch_after.? + clock[2] - 1;
            handoff = @max(handoff, member.start_after + binding.dispatch_after.? + clock[1]);
        }
        var filled = count;
        for (exported.value.party) |profile| {
            if (filled == initial.len) break;
            var duplicate = false;
            for (initial[0..filled]) |id| duplicate = duplicate or std.mem.eql(u8, id, profile.id);
            if (!duplicate) {
                initial[filled] = profile.id;
                filled += 1;
            }
        }
        var content = exported.value;
        content.party = profiles;
        content.initial_party = &initial;
        for (0..count) |owner| {
            const damage_member: usize = switch (record) {
                4 => 0,
                7 => 2,
                26 => 1,
                else => if (count == 4) count - 1 else owner,
            };
            const Event = struct { at: u16, variant: u8 };
            var expected: [4]Event = undefined;
            var expected_count: usize = 0;
            for (binding.members, 0..) |member, slot| if (member.reaction_on_hit) {
                expected[expected_count] = .{ .at = hits[slot], .variant = member.reaction_variant };
                expected_count += 1;
            };
            expected[expected_count] = .{ .at = hits[damage_member], .variant = 0 };
            expected_count += 1;
            std.mem.sort(Event, expected[0..expected_count], {}, struct {
                fn before(_: void, x: Event, y: Event) bool {
                    return x.at < y.at;
                }
            }.before);
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(content, items.value, &members, 17);
            combat.integration = .{ .host = host };
            try combat.attachUniteActors(&bundle);
            try combat.attachSpellScenes(&effects.value);
            combat.enterRoundMenu();
            combat.choose(owner);
            try std.testing.expect(combat.selectUnite(owner, record));
            combat.queue(.{ .unite = 0 });
            for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
                action.* = .defend;
            };
            combat.phase = .resolving;
            combat.acted = @splat(true);
            combat.action_ticks = 100;
            combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .elapsed = 100 };
            combat.unite_flags[6] = 0x8000;
            var tape = Tape{};
            var draws = tape.init();
            if (record == 5 and extra == 0 and owner == 0) {
                var missing = combat;
                var missing_members: [6]battle.Member = undefined;
                @memcpy(&missing_members, combat.progress.party);
                missing.progress.party = &missing_members;
                missing.spell_scenes = null;
                var missing_draws = draws;
                const flags = missing.unite_flags;
                try std.testing.expectError(error.UnsupportedCoordinatorAction, missing.tickReplay(.{}, &missing_draws));
                try std.testing.expectEqualDeep(flags, missing.unite_flags);
                try std.testing.expectEqual(combat.camera_ticks, missing.camera_ticks);
                try std.testing.expectEqual(draws.cursor, missing_draws.cursor);
            }
            try combat.tickReplay(.{}, &draws);
            const selected_at = combat.camera_ticks;
            try std.testing.expectEqual(@as(u16, 0x8000), combat.unite_flags[6]);
            var previous_hp: u16 = 5000;
            var hp_changes: usize = 0;
            var reaction_count: usize = 0;
            var previous_reaction: ?u32 = null;
            var handed_off = false;
            while (combat.camera_ticks - selected_at < 1000) {
                try combat.tickReplay(.{}, &draws);
                const age = combat.camera_ticks - selected_at;
                if (age == 1) {
                    try std.testing.expectEqual(record == 26, combat.uniteAssistAfterDamage());
                    try std.testing.expectEqual(@as(u16, 0), combat.unite_flags[6]);
                    for (0..count) |actor| {
                        try std.testing.expectEqual(@as(u16, 0), combat.unite_flags[actor]);
                        try std.testing.expectEqual(binding.dispatch_after.? == 1 and scheduled[actor].start_after == 0, combat.unite_vm.members[actor].?.initialized);
                    }
                    const target_pose = for (effects.value.hurt_poses) |pose| {
                        if (std.mem.eql(u8, pose.id, combat.enemy(0).id)) break pose;
                    } else return error.MissingTargetArt;
                    try std.testing.expectEqual(@as(?[2]i16, .{ target_pose.impact_offset.?[0], target_pose.impact_offset.?[1] }), combat.unite_vm.actors[6].external_attachment);
                    combat.unite_flags[6] = 0x4000;
                }
                if (age > 1) try std.testing.expectEqual(@as(u16, 0x4000), combat.unite_flags[6]);
                for (0..count) |actor| {
                    try std.testing.expectEqual(age < ends[actor], combat.unite_vm.owns(actor));
                    if (combat.unite_vm.members[actor]) |member| {
                        const started = combat.camera_ticks >= member.start_at;
                        try std.testing.expectEqual(started, member.initialized);
                        try std.testing.expectEqual(@as(u16, @intCast(age -| (member.start_at - selected_at) + @intFromBool(started))), member.age);
                        const live_trail = combat.unite_vm.actors[actor].blue_trail;
                        try std.testing.expectEqual(live_trail != null and live_trail.?.visible, battle.layout.uniteTrail(combat, actor) != null);
                        if (live_trail) |trail| try std.testing.expectEqual(combat.unite_vm.actors[actor].resource.?.find(5).?.frames[0].pose, trail.pose);
                    }
                }
                if (record == 5 and extra == 0 and owner == 0 and age + 1 == hits[damage_member]) {
                    var exhausted = combat;
                    var exhausted_members: [6]battle.Member = undefined;
                    @memcpy(&exhausted_members, combat.progress.party);
                    exhausted.progress.party = &exhausted_members;
                    var empty_draws = draws;
                    empty_draws.values = empty_draws.values[0..empty_draws.cursor];
                    const before = exhausted.unite_vm;
                    try std.testing.expectError(error.RandomInputExhausted, exhausted.tickReplay(.{}, &empty_draws));
                    try std.testing.expectEqualDeep(before.members, exhausted.unite_vm.members);
                    try std.testing.expectEqualDeep(combat.enemy_hp, exhausted.enemy_hp);
                    try std.testing.expectEqual(combat.camera_ticks, exhausted.camera_ticks);
                    try std.testing.expectEqual(draws.cursor, empty_draws.cursor);
                }
                if (combat.unite_reactions[6]) |reaction| if (previous_reaction == null or previous_reaction.? != reaction.started_at) {
                    try std.testing.expect(reaction_count < expected_count);
                    try std.testing.expectEqual(expected[reaction_count].at, age);
                    try std.testing.expectEqual(expected[reaction_count].variant, reaction.variant);
                    reaction_count += 1;
                    previous_reaction = reaction.started_at;
                };
                if (combat.enemy_hp[0] != previous_hp) {
                    try std.testing.expectEqual(hits[damage_member], age);
                    hp_changes += 1;
                    previous_hp = combat.enemy_hp[0];
                }
                if (age < handoff) try std.testing.expect(combat.hasLiveUniteActors());
                if (!handed_off and combat.active == null) {
                    try std.testing.expectEqual(handoff, age);
                    handed_off = true;
                }
                if (handed_off and !combat.hasUniteReturns()) break;
            }
            try std.testing.expect(handed_off);
            try std.testing.expectEqual(expected_count, reaction_count);
            try std.testing.expectEqual(@as(usize, 1), hp_changes);
            try std.testing.expectEqual(count + @as(usize, if (record == 1) 2 else 0), draws.cursor);
            var last: u16 = 0;
            for (ends[0..count]) |at| last = @max(last, at);
            try std.testing.expectEqual(last, combat.camera_ticks - selected_at);
            try std.testing.expect(combat.unite_boundaries[owner] == null);
        }
    }
}
