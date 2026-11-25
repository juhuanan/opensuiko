const std = @import("std");
const battle = @import("battle");
const physical = battle.physical;
const host = battle.actor_host;
const vm = battle.actor_program;
const allocator = std.testing.allocator;
const field = @import("field");

test "Battle sound events drain once in source order" {
    var playback: battle.unite_playback.State = .{};
    playback.sounds[0] = .{ .actor = 2, .id = 0x522 };
    playback.sounds[1] = .{ .actor = 6, .id = 0x524 };
    playback.sound_count = 2;
    const sounds = playback.takeSounds();
    try std.testing.expectEqual(@as(usize, 2), sounds.len);
    try std.testing.expectEqual(@as(u16, 0x522), sounds[0].id);
    try std.testing.expectEqual(@as(u16, 0x524), sounds[1].id);
    try std.testing.expectEqual(@as(usize, 0), playback.takeSounds().len);
}

test "Physical rune ordinary auxiliary sprites impacts and frozen trails share native geometry" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(parsed.value, items.value, &members, 17);
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.actor_camera = try @import("battle_camera").ActorController.init(.{ .focus = .{ 0, 0, 0 }, .angles = .{ 0, 0, 0 }, .translation = .{ 0, 0, 1024 }, .scale = @splat(4096) });
    const resource = actors.value.animations.find("ronnie").?;
    const frozen = resource.find(18).?.frames[0].pose;
    const sprite = battle.Pose{ .rect = .{ .x = 2, .y = 4, .w = 10, .h = 20 }, .anchor_x = 3, .anchor_y = 5 };
    var trails: [8]battle.Pose = @splat(sprite);
    for (&trails, 0..) |*pose, age| pose.rect.x += @intCast(age);
    var poses = [_]battle.UniteGraphicPose{.{ .id = frozen, .sprite = sprite, .trail = trails }};
    const graphics = [_]battle.UniteGraphic{.{ .id = "ronnie", .poses = &poses }};
    combat.content.unite_graphics = &graphics;
    var child = try host.Actor.init(resource, .{ 0, 0, 0 });
    child.animation = 18;
    child.has_draw_record = false;
    child.screen_offset = .{ -2, 3 };
    child.record_flags = 2;
    combat.unite_vm.auxiliary[0] = child;
    const quad = battle.layout.uniteAuxiliary(combat, 0).?;
    try std.testing.expect(!quad.effect);
    try std.testing.expectEqual(@as(f32, 310), quad.vertices[0].x);
    try std.testing.expectEqual(@as(f32, 236), quad.vertices[0].y);
    try std.testing.expectEqual(@as(f32, 20), quad.vertices[1].x - quad.vertices[0].x);
    try std.testing.expectEqual(@as(f32, 40), quad.vertices[2].y - quad.vertices[0].y);
    combat.unite_vm.auxiliary[0].?.draw_angles[2] = 1024;
    const rotated = battle.layout.uniteAuxiliary(combat, 0).?;
    try std.testing.expectEqual(@as(f32, 326), rotated.vertices[0].x);
    try std.testing.expectEqual(@as(f32, 240), rotated.vertices[0].y);
    var points: [8][2]f32 = undefined;
    for (&points, 0..) |*point, index| point.* = .{ @floatFromInt(100 + index), @floatFromInt(200 + index) };
    combat.unite_vm.auxiliary[0].?.blue_trail = .{ .points = points, .pose = frozen, .next = 3, .visible = true, .depth = 1200 };
    const ring = battle.layout.uniteTrail(combat, combat.unite_vm.actors.len).?;
    for (ring, 0..) |sample, ordinal| {
        const age = 7 - ordinal;
        const slot = (3 + 7 - age) % 8;
        try std.testing.expectEqual(points[slot][0], sample.point.x);
        try std.testing.expectEqual(points[slot][1], sample.point.y);
        try std.testing.expectEqual(@as(f32, 1200), sample.point.depth);
        try std.testing.expectEqualDeep(trails[age], sample.sprite);
        try std.testing.expectEqual(@as(f32, 2), sample.scale);
    }
    combat.unite_vm.auxiliary[0].?.visible = false;
    try std.testing.expect(battle.layout.uniteAuxiliary(combat, 0) == null);
    try std.testing.expect(battle.layout.uniteTrail(combat, combat.unite_vm.actors.len) != null);
    combat.unite_vm.auxiliary[0].?.retired = true;
    try std.testing.expect(battle.layout.uniteTrail(combat, combat.unite_vm.actors.len) == null);
    var impact = try host.Actor.init(actors.value.animations.find("shared_impacts").?, .{ 0, 0, 0 });
    impact.has_draw_record = false;
    combat.unite_vm.auxiliary[1] = impact;
    const flash = battle.layout.uniteAuxiliary(combat, 1).?;
    try std.testing.expect(flash.effect);
    const clip = for (scenes.value.unite_impacts) |clip| {
        if (clip.id == 0) break clip;
    } else return error.MissingImpact;
    const entry = scenes.value.entries[clip.frames[0].entry];
    try std.testing.expectEqualDeep(battle.Pose{ .rect = .{ .x = entry.x, .y = entry.y, .w = entry.w, .h = entry.h }, .anchor_x = @intCast(-entry.dx), .anchor_y = @intCast(-entry.dy) }, flash.sprite);
    combat.spell_scenes = null;
    try std.testing.expect(battle.layout.uniteAuxiliary(combat, 1) == null);
    try std.testing.expect(battle.layout.uniteTrail(combat, combat.unite_vm.actors.len + combat.unite_vm.auxiliary.len) == null);
    const pieces = [_]battle.Pose{ sprite, .{ .rect = .{ .x = 20, .y = 40, .w = 8, .h = 12 }, .anchor_x = -4, .anchor_y = 7 } };
    poses[0].pieces = &pieces;
    const legacy_profiles = try allocator.dupe(battle.Profile, combat.content.party);
    defer allocator.free(legacy_profiles);
    for (legacy_profiles) |*profile| profile.item_art = null;
    combat.content.party = legacy_profiles;
    combat.content.schema = "suikoden-battle-trial/28";
    try combat.content.validate();
    combat.content.schema = "suikoden-battle-trial/27";
    try std.testing.expectError(error.InvalidUniteGraphics, combat.content.validate());
    const secondary = &combat.unite_vm.auxiliary[0].?;
    secondary.has_draw_record = true;
    secondary.record_flags = 4;
    secondary.visible = true;
    secondary.retired = false;
    secondary.draw_angles = .{ 0, 0, 0 };
    const first = battle.layout.uniteAuxiliaryPiece(combat, 0, 0).?;
    const second = battle.layout.uniteAuxiliaryPiece(combat, 0, 1).?;
    try std.testing.expectEqualDeep(pieces[0], first.sprite);
    try std.testing.expectEqualDeep(pieces[1], second.sprite);
    try std.testing.expectEqual(@as(f32, 324), second.vertices[0].x);
    try std.testing.expectEqual(@as(f32, 232), second.vertices[0].y);
    try std.testing.expectEqual(@as(f32, 14), second.vertices[1].x - second.vertices[0].x);
    try std.testing.expect(battle.layout.uniteAuxiliaryPiece(combat, 0, 2) == null);
}

test "Physical rune combined actor bundle preserves legacy hashes and hashes physical bindings" {
    const legacy = try host.loadBundle(allocator, @embedFile("fixtures/unite_actor_library.json"));
    defer legacy.deinit();
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .schema = legacy.value.schema, .programs = legacy.value.programs, .animations = legacy.value.animations, .unites = legacy.value.unites }, .{});
    defer allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    try std.testing.expectEqualDeep(hash, try legacy.value.digest());
    const combined = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer combined.deinit();
    try std.testing.expectEqual(@as(usize, 105), combined.value.programs.programs.len);
    try std.testing.expectEqual(@as(usize, 92), combined.value.animations.resources.len);
    var changed = combined.value;
    const bindings = try allocator.dupe(physical.Binding, changed.physical.?);
    defer allocator.free(bindings);
    changed.physical = bindings;
    bindings[0].initial_camera.?.scale_q12[0] += 4096;
    try changed.validate();
    try std.testing.expect(!std.mem.eql(u8, &(try combined.value.digest()), &(try changed.digest())));
    changed.schema = "suikoden-unite-actors/10";
    try std.testing.expectError(error.InvalidUniteBindings, changed.validate());
}

test "Physical rune missing presentation art refuses before actor or camera ownership changes" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer actors.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(parsed.value, items.value, &members, 17);
    try combat.attachUniteActors(&actors.value);
    combat.content.unite_graphics = &.{};
    combat.runes[2] = for (combat.content.systems.?.runes, 0..) |rune, index| {
        if (std.mem.eql(u8, rune.id, "boar")) break index;
    } else return error.MissingRune;
    const hp = combat.enemy_hp;
    const random = combat.random;
    try std.testing.expectError(error.MissingPhysicalArt, combat.beginSourcePhysicalRune(2, combat.partyCount()));
    try std.testing.expect(combat.active == null and combat.actor_camera == null and !combat.unite_vm.hasActors());
    try std.testing.expectEqualDeep(hp, combat.enemy_hp);
    try std.testing.expectEqualDeep(random, combat.random);
}

test "Physical rune source controller retargets and does not start without enemies" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(parsed.value, items.value, &members, 17);
    combat.encounter = 1;
    combat.startEncounter();
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.runes[2] = combat.content.systems.?.runeIndex("boar").?;
    combat.enemy_hp[0] = 0;
    combat.enemy_hp[1] = 5000;
    try std.testing.expect(combat.beginRuneAttack(2, 0));
    try std.testing.expectEqual(combat.partyCount() + 1, combat.active.?.target);
    try std.testing.expectEqual(@as(?usize, combat.partyCount()), combat.active.?.retargeted_from);
    try std.testing.expectEqual(@as(u8, @intCast(combat.partyCount() + 1)), combat.unite_vm.physical_actions[2].?.recipient);

    combat.startEncounter();
    combat.enemy_hp = @splat(0);
    try std.testing.expect(!combat.beginRuneAttack(2, 0));
    combat.phase = .resolving;
    combat.actions = @splat(.defend);
    combat.actions[2] = .{ .rune_attack = 0 };
    combat.acted = @splat(true);
    combat.acted[2] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 2 };
    combat.advanceCoordinator();
    try std.testing.expect(combat.acted[2] and combat.coordinator.?.completed);
    try std.testing.expectEqual(.select, combat.coordinator.?.stage);
    try std.testing.expect(!combat.unite_vm.hasPhysical());
}

test "Physical rune camera handoff keeps a one-frame focus pulse out of its transition" {
    const content = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer content.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content.value, items.value, &members, 17);
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.runes[2] = combat.content.systems.?.runeIndex("boar").?;
    combat.phase = .resolving;
    combat.coordinator = .{ .stage = .await_order, .current_actor = 2 };
    try std.testing.expect(combat.beginRuneAttack(2, 0));
    var control = combat;
    var control_members = members;
    control.progress.party = control_members[0..combat.partyCount()];
    combat.enemy_magic_pulse = .{ .issued_at = combat.camera_ticks, .delta_q12 = 5 * 4096 };
    var draws = battle.systems.Draws{ .values = &.{} };

    try combat.tickReplay(.{}, &draws);
    try control.tickReplay(.{}, &draws);
    try std.testing.expect(combat.actor_camera != null and control.actor_camera != null);
    try std.testing.expectEqualDeep(control.actor_camera, combat.actor_camera);
    var visible = battle.layout.currentCamera(control);
    visible.focus[2] += 5;
    try std.testing.expectEqualDeep(visible, battle.layout.currentCamera(combat));

    try combat.tickReplay(.{}, &draws);
    try control.tickReplay(.{}, &draws);
    try std.testing.expectEqualDeep(battle.layout.currentCamera(control), battle.layout.currentCamera(combat));
}

test "Physical rune overlapping source controllers share the current damage numerator" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var content = parsed.value;
    const profiles = try allocator.alloc(battle.Profile, content.party.len + 1);
    defer allocator.free(profiles);
    @memcpy(profiles[0..content.party.len], content.party);
    const original_count = content.party.len;
    content.party = profiles[0..original_count];
    content.schema = "suikoden-battle-trial/28";
    content.medicine_timings = &.{};
    for (profiles[0..original_count]) |*profile| profile.item_art = null;
    // Diagnostic stats; Valeria's actor frames and graphical bindings remain disc-derived.
    profiles[content.party.len] = content.party[0];
    profiles[content.party.len].id = "valeria";
    profiles[content.party.len].weapon = null;
    content.party = profiles;
    var ids: [6][]const u8 = undefined;
    for (&ids, 0..) |*id, index| id.* = parsed.value.initialProfile(index).id;
    ids[0] = "valeria";
    content.initial_party = &ids;
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    combat.encounter = 1;
    combat.enemy_hp = @splat(5000);
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    for ([_]struct { member: usize, rune: []const u8 }{ .{ .member = 2, .rune = "boar" }, .{ .member = 0, .rune = "falcon" } }) |binding| {
        combat.runes[binding.member] = for (content.systems.?.runes, 0..) |rune, index| {
            if (std.mem.eql(u8, rune.id, binding.rune)) break index;
        } else return error.MissingRune;
    }
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.actions = @splat(.defend);
    const values: [8]u15 = @splat(12345);
    var draws = battle.systems.Draws{ .values = &values };
    try std.testing.expect(combat.beginRuneAttack(2, 0));
    for (0..293) |_| try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.active == null and combat.unite_vm.hasPhysical());
    try std.testing.expectEqual(@as(u16, 20), combat.physical_numerator);
    try std.testing.expect(combat.beginRuneAttack(0, 1));
    for (294..324) |tick| {
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(u16, 30), combat.physical_numerator);
        try std.testing.expect(combat.unite_vm.physical_actions[2] != null and combat.unite_vm.physical_actions[0] != null);
        if (tick < 323) try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[0]);
    }
    const base = battle.physicalDamage(combat.stats(2).attack, combat.stats(combat.partyCount()).defense, 12345, false);
    try std.testing.expectEqual(@as(u16, @intCast(5000 - base * 3)), combat.enemy_hp[0]);
    try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[1]);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
}

test "Physical rune live contact exhaustion restores the complete pending hit for retry" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var content = parsed.value;
    content.presentation_ready = false;
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.runes[0] = for (content.systems.?.runes, 0..) |rune, index| {
        if (std.mem.eql(u8, rune.id, "clone")) break index;
    } else return error.MissingRune;
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.actions = @splat(.defend);
    combat.enemy_hp[0] = 5000;
    try std.testing.expect(combat.beginRuneAttack(0, 0));
    var draws = battle.systems.Draws{ .values = &.{} };
    for (0..68) |_| try combat.tickReplay(.{}, &draws);
    const pending = combat.unite_vm.physical_actions;
    const recipient = combat.partyCount();
    const target_flags = combat.unite_vm.actors[recipient].signals;
    const controller = combat.actor_camera;
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    try std.testing.expectEqual(@as(u32, 68), combat.camera_ticks);
    try std.testing.expectEqualDeep(pending, combat.unite_vm.physical_actions);
    try std.testing.expectEqualDeep(controller, combat.actor_camera);
    try std.testing.expectEqual(target_flags, combat.unite_vm.actors[recipient].signals);
    try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[0]);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    draws.values = &.{12345};
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(u32, 69), combat.camera_ticks);
    try std.testing.expect(combat.enemy_hp[0] < 5000);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
    try std.testing.expect(!combat.unite_vm.physical_actions[0].?.action.?.damage_pending);
}

test "Physical rune source coordinator dispatches and closes a complete queued round" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var content = parsed.value;
    content.presentation_ready = false;
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.runes[2] = for (content.systems.?.runes, 0..) |rune, index| {
        if (std.mem.eql(u8, rune.id, "boar")) break index;
    } else return error.MissingRune;
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.acted[2] = false;
    combat.actions = @splat(.defend);
    combat.actions[2] = .{ .rune_attack = 0 };
    combat.enemy_hp[0] = 5000;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = 2 };
    const values: [16]u15 = @splat(12345);
    var draws = battle.systems.Draws{ .values = &values };
    var impact: ?u32 = null;
    var prior: u16 = 5000;
    var hits: u8 = 0;
    var owner_sound = false;
    var recipient_sound = false;
    for (0..500) |_| {
        try combat.tickReplay(.{}, &draws);
        if (combat.unite_vm.hasPhysical()) {
            const sounds = combat.unite_vm.sounds;
            const count = combat.unite_vm.sound_count;
            combat.advancePhysicalRunes();
            try std.testing.expectEqual(count, combat.unite_vm.sound_count);
            try std.testing.expectEqualSlices(battle.unite_playback.Sound, sounds[0..count], combat.unite_vm.sounds[0..count]);
        }
        for (combat.unite_vm.takeSounds()) |sound| {
            if (sound.actor == 2 and sound.id == 0x522) owner_sound = true;
            if (sound.actor == combat.partyCount() and sound.id == 0x518) recipient_sound = true;
        }
        if (combat.enemy_hp[0] != prior) {
            hits += 1;
            prior = combat.enemy_hp[0];
            impact = combat.camera_ticks;
        }
        if (combat.phase == .battle_menu) break;
    }
    try std.testing.expectEqual(@as(u8, 1), hits);
    try std.testing.expect(owner_sound and recipient_sound);
    try std.testing.expectEqual(@as(?u32, 324), impact);
    try std.testing.expectEqual(@as(u32, 2), combat.round);
    try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
    try std.testing.expect(!combat.unite_vm.hasActors());
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
}

test "Queued Unite waits for physical rune locks before source dispatch and both actions finish" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer actors.deinit();
    const rebound = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer rebound.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    const integration = try battle.IntegrationHost.init(allocator);
    defer integration.deinit();
    var content = parsed.value;
    const enemies = try allocator.dupe(battle.Profile, content.enemies);
    defer allocator.free(enemies);
    for (enemies) |*enemy| enemy.max_hp = 5000;
    content.enemies = enemies;
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    combat.encounter = 1;
    combat.enemy_hp = @splat(5000);
    combat.integration = .{ .host = integration };
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.runes[2] = for (content.systems.?.runes, 0..) |rune, index| {
        if (std.mem.eql(u8, rune.id, "boar")) break index;
    } else return error.MissingRune;
    combat.choose(2);
    combat.queue(.{ .rune_attack = 0 });
    combat.choose(4);
    combat.queue(.{ .unite = 1 });
    try std.testing.expect(combat.uniteBoundaryFor(4) != null);
    for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
        action.* = .defend;
    };
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.acted[2] = false;
    const values: [512]u15 = @splat(12345);
    var draws = battle.systems.Draws{ .values = &values };
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.sourcePhysicalRuneOwner(2));
    combat.acted[4] = false;
    var selected: ?u32 = null;
    var waited = false;
    var retried = false;
    var impacts: [3]?u32 = @splat(null);
    var previous: [3]u16 = @splat(5000);
    for (0..900) |_| {
        if (combat.camera_ticks == 323) {
            const pending = combat.unite_vm;
            const camera = combat.actor_camera;
            const active = combat.active;
            const cursor = draws.cursor;
            draws.values = values[0..cursor];
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
            try std.testing.expectEqual(@as(u32, 323), combat.camera_ticks);
            try std.testing.expectEqualDeep(pending, combat.unite_vm);
            try std.testing.expectEqualDeep(camera, combat.actor_camera);
            try std.testing.expectEqualDeep(active, combat.active);
            try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[0]);
            try std.testing.expectEqual(cursor, draws.cursor);
            draws.values = &values;
            retried = true;
        }
        try combat.tickReplay(.{}, &draws);
        if (combat.active) |effect| if (effect.kind == .unite and selected == null) {
            selected = combat.camera_ticks;
            try std.testing.expect(combat.coordinator == null);
            try std.testing.expect(combat.hasLiveUniteActors());
            try combat.unite_vm.rebind(&rebound.value);
            combat.unite_actors = &rebound.value;
            for ([_]usize{ 4, 5 }) |actor| {
                const resource = combat.unite_vm.actors[actor].resource.?;
                try std.testing.expect(resource.id.ptr == rebound.value.animations.find(resource.id).?.id.ptr);
            }
        };
        if (selected == null and combat.pending_party_actor == 4) {
            var locked = false;
            for (0..combat.partyCount() + combat.enemyCount()) |actor| locked = locked or combat.coordinatorLocked(actor);
            if (locked) {
                waited = true;
                const cursor = draws.cursor;
                combat.replay_draws = &draws;
                combat.nextAction();
                combat.replay_draws = null;
                try std.testing.expectEqual(cursor, draws.cursor);
                try std.testing.expect(combat.pending_party_actor == 4 and combat.active == null);
                try std.testing.expect(!combat.acted[4] and combat.uniteBoundaryFor(4) != null);
                try std.testing.expect(!combat.unite_vm.owns(4) and !combat.unite_vm.owns(5));
            }
        }
        for (0..3) |index| if (combat.enemy_hp[index] != previous[index]) {
            try std.testing.expect(impacts[index] == null);
            impacts[index] = combat.camera_ticks;
            previous[index] = combat.enemy_hp[index];
        };
        if (combat.phase == .battle_menu) break;
    }
    try std.testing.expect(selected != null and waited and retried);
    try std.testing.expectEqual(@as(?u32, 324), impacts[0]);
    try std.testing.expectEqual(@as(?u32, selected.? + 83), impacts[1]);
    try std.testing.expect(impacts[2] == null);
    const boar = battle.physicalDamage(combat.stats(2).attack, combat.stats(combat.partyCount()).defense, 12345, false) * 2;
    const fisherman = (battle.physicalDamage(combat.stats(4).attack, combat.stats(combat.partyCount() + 1).defense, 12345, false) + battle.physicalDamage(combat.stats(5).attack, combat.stats(combat.partyCount() + 1).defense, 12345, false)) * 3;
    try std.testing.expectEqual(@as(u16, @intCast(5000 - boar)), combat.enemy_hp[0]);
    try std.testing.expectEqual(@as(u16, @intCast(5000 - fisherman)), combat.enemy_hp[1]);
    try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
    try std.testing.expectEqual(@as(u32, 2), combat.round);
    try std.testing.expect(!combat.unite_vm.hasActors());
}

test "Physical rune live battle uses source owner and recipient clocks without ordinary attack damage" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    for ([_]struct { technique: []const u8, owner: []const u8, member: usize, numerator: u16, impact: u32, recipient_release: u32, release: u32, recovery: u8, decoy_at: ?u32 = null }{
        .{ .technique = "boar", .owner = "pahn", .member = 2, .numerator = 20, .impact = 323, .recipient_release = 323, .release = 345, .recovery = 2 },
        .{ .technique = "shrike", .owner = "kasumi", .member = 0, .numerator = 20, .impact = 160, .recipient_release = 211, .release = 211, .recovery = 0 },
        .{ .technique = "falcon", .owner = "valeria", .member = 0, .numerator = 30, .impact = 159, .recipient_release = 191, .release = 244, .recovery = 0 },
        .{ .technique = "hate", .owner = "ronnie", .member = 0, .numerator = 30, .impact = 61, .recipient_release = 93, .release = 93, .recovery = 0 },
        .{ .technique = "trick", .owner = "juppo", .member = 0, .numerator = 15, .impact = 111, .recipient_release = 137, .release = 137, .recovery = 0, .decoy_at = 94 },
        .{ .technique = "clone", .owner = "hero", .member = 0, .numerator = 20, .impact = 69, .recipient_release = 98, .release = 141, .recovery = 2 },
    }) |case| {
        for (0..3) |mode| {
            var content = parsed.value;
            content.presentation_ready = true;
            const profiles = try allocator.alloc(battle.Profile, content.party.len + 1);
            defer allocator.free(profiles);
            @memcpy(profiles[0..content.party.len], content.party);
            const original_count = content.party.len;
            content.party = profiles[0..original_count];
            content.schema = "suikoden-battle-trial/28";
            content.medicine_timings = &.{};
            for (profiles[0..original_count]) |*profile| profile.item_art = null;
            var ids: [6][]const u8 = undefined;
            for (&ids, 0..) |*id, index| id.* = content.initialProfile(index).id;
            if (content.partyProfile(case.owner) == null) {
                // Deliberate headless stats/rect fixture; actor programs and F records use the real owner.
                profiles[content.party.len] = content.party[0];
                profiles[content.party.len].id = case.owner;
                profiles[content.party.len].name = case.owner;
                profiles[content.party.len].weapon = null;
                content.party = profiles;
                ids[case.member] = case.owner;
                content.initial_party = &ids;
            }
            const enemies = try allocator.dupe(battle.Profile, content.enemies);
            defer allocator.free(enemies);
            for (enemies) |*enemy| {
                enemy.max_hp = 5000;
                if (mode == 0) enemy.affinities = .{ .fire = .weak };
            }
            content.enemies = enemies;
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(content, items.value, &members, 17);
            try combat.attachUniteActors(&actors.value);
            try combat.attachSpellScenes(&scenes.value);
            if (mode == 0) combat.weapon_augments[case.member] = .{ .rune = .fire, .fragments = 3 };
            if (mode == 1) combat.actor_conditions[combat.partyCount()].protection_rounds = 3;
            if (mode == 2) combat.enemy_hp[0] = 1;
            combat.actor_conditions[combat.partyCount()].sleep_turns = 1;
            combat.runes[case.member] = for (content.systems.?.runes, 0..) |rune, index| {
                if (std.mem.eql(u8, rune.id, case.technique)) break index;
            } else return error.MissingRune;
            combat.phase = .resolving;
            combat.acted = @splat(true);
            combat.actions = @splat(.defend);
            const charges = combat.progress.party[case.member].rune_charges;
            try std.testing.expect(combat.beginRuneAttack(case.member, 0));
            const target = combat.partyCount();
            const attack = combat.stats(case.member).attack;
            const defense = combat.stats(target).defense;
            const raw = battle.physicalDamage(attack, defense, 12345, false);
            const weakness = raw + raw / 2;
            const base = if (mode == 0) weakness + (weakness / 20) * 3 else raw;
            const expected = @as(u32, @intCast(@as(u64, base) * case.numerator / 10));
            const draws_values: [8]u15 = @splat(12345);
            var draws = battle.systems.Draws{ .values = &draws_values };
            const ko_duration = if (mode == 2) combat.uniteReactionPose(target).?.knockout.?.duration else 0;
            const finish: u32 = @max(case.release, case.recipient_release + ko_duration);
            var saw_child = false;
            var saw_trail = false;
            for (1..finish + 1) |tick| {
                try combat.tickReplay(.{}, &draws);
                const hp: u16 = if (mode == 2) (if (tick >= case.impact) 0 else 1) else @intCast(5000 - if (mode != 1 and tick >= case.impact) expected else 0);
                try std.testing.expectEqual(hp, combat.enemy_hp[0]);
                if (tick < finish) try std.testing.expect(combat.unite_vm.hasPhysical());
                const consumed: usize = @intFromBool(tick >= case.impact) + @as(usize, if (case.decoy_at) |at| @intFromBool(tick >= at) else 0) + @as(usize, @intFromBool(case.recovery != 0 and tick >= case.release));
                try std.testing.expectEqual(consumed, draws.cursor);
                if (mode != 2) try std.testing.expectEqual(@as(u8, 1), combat.actor_conditions[target].sleep_turns);
                if (mode == 2 and tick >= case.recipient_release and tick < case.recipient_release + ko_duration) {
                    try std.testing.expect(combat.coordinatorLocked(target));
                    try std.testing.expect(combat.physicalRuneReaction(target) != null);
                }
                for (combat.unite_vm.scripted_actors, 0..) |binding, index| if (binding != null) {
                    try std.testing.expect(combat.physicalRunePose(index) != null);
                    const actor = combat.unite_vm.actors[index];
                    if (actor.blue_trail) |trail| if (trail.visible) {
                        saw_trail = true;
                        try std.testing.expect(battle.layout.uniteTrail(combat, index) != null);
                    };
                };
                for (combat.unite_vm.auxiliary, 0..) |maybe, index| if (maybe) |child| {
                    if (child.visible and !child.retired) {
                        saw_child = true;
                        const quad = battle.layout.uniteAuxiliary(combat, index) orelse return error.MissingPhysicalChildGraphic;
                        try std.testing.expectEqual(std.mem.eql(u8, child.resource.?.id, "shared_impacts"), quad.effect);
                        for (quad.vertices) |vertex| try std.testing.expect(std.math.isFinite(vertex.x) and std.math.isFinite(vertex.y));
                    }
                    if (child.blue_trail) |trail| if (trail.visible) {
                        saw_trail = true;
                        try std.testing.expect(battle.layout.uniteTrail(combat, combat.unite_vm.actors.len + index) != null);
                    };
                };
            }
            try std.testing.expect(saw_child);
            if (!std.mem.eql(u8, case.technique, "falcon") and !std.mem.eql(u8, case.technique, "trick")) try std.testing.expect(saw_trail);
            try std.testing.expect(!combat.unite_vm.hasPhysical());
            try std.testing.expectEqual(case.recovery, combat.unbalanced[case.member]);
            try std.testing.expectEqualDeep(charges, combat.progress.party[case.member].rune_charges);
            try std.testing.expect(combat.active == null);
        }
    }
}

const Context = struct {
    contacts: u16 = 0,
    recoveries: u16 = 0,
    recovery_boundaries: u8 = 0,
    fn command(raw: *anyopaque, _: u16, request: vm.Command, _: bool) !bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (request) {
            .sound => {},
            .recovery => |boundaries| {
                self.recoveries += 1;
                self.recovery_boundaries = boundaries;
            },
            else => return error.UnboundPhysicalCommand,
        }
        return true;
    }
    fn decoy(raw: *anyopaque, _: u16, _: u16) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.contacts += 1;
    }
    fn previous(_: *anyopaque, _: u16) !battle.presentation.ScreenPoint {
        return .{ .x = 123, .y = 234, .depth = 1000 };
    }
};

test "Physical rune packet validates all references and rejects changed rule and camera bindings" {
    const parsed = try physical.load(allocator, @embedFile("fixtures/physical_actor_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const bindings = try allocator.dupe(physical.Binding, packet.techniques);
    defer allocator.free(bindings);
    packet.techniques = bindings;
    bindings[0].numerator += 1;
    try std.testing.expectError(error.InvalidPhysicalBindings, packet.validate());
    bindings[0] = parsed.value.techniques[0];
    bindings[0].owner_program = "missing";
    try std.testing.expectError(error.MissingPhysicalProgram, packet.validate());
    bindings[0] = parsed.value.techniques[0];
    bindings[0].initial_camera.?.preserve_translation = false;
    try std.testing.expectError(error.InvalidPhysicalBindings, packet.validate());
    bindings[0] = parsed.value.techniques[0];
    bindings[1].id = bindings[0].id;
    try std.testing.expectError(error.InvalidPhysicalBindings, packet.validate());
}

test "Physical rune Hate retries a full child pool and preserves independent damage acknowledgement" {
    const parsed = try physical.load(allocator, @embedFile("fixtures/physical_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    var actors = [_]host.Actor{ try host.Actor.init(packet.animations.find("ronnie").?, .{ 100, 200, 300 }), try host.Actor.init(packet.animations.find("bonbon").?, .{ 500, 600, 700 }) };
    actors[0].position_q12 = .{ 450123, -990123, 5123 };
    actors[1].position_q12 = .{ -715123, 7715, -3123 };
    var children = [_]?host.Actor{try host.Actor.init(packet.animations.find("hero").?, .{ 0, 0, 0 })};
    var camera = try @import("battle_camera").ActorController.init(@import("battle_camera").standard_battle);
    var context = Context{};
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .camera_controller = &camera, .external = .{ .context = &context, .command = Context.command, .decoy_contact = Context.decoy, .previous_screen_position = Context.previous } };
    var action = try physical.Action.begin(packet, &runtime, .hate, 0, 1);
    actors[0].shared_value = 1;
    try action.advance(packet, &runtime);
    try std.testing.expect(action.stage == .auxiliary);
    try std.testing.expectEqual(@as(i16, 1), actors[0].shared_value);
    try std.testing.expectEqualStrings("hero", children[0].?.resource.?.id);
    children[0] = null;
    try action.advance(packet, &runtime);
    try std.testing.expect(action.stage == .recipient);
    try std.testing.expectEqual(@as(i16, 99), actors[0].shared_value);
    const child = children[0].?;
    try std.testing.expectEqualStrings("ronnie", child.resource.?.id);
    try std.testing.expectEqual(@as(u16, 18), child.animation);
    try std.testing.expectEqual(@as(?u16, 0), child.owner);
    try std.testing.expectEqualDeep(actors[1].position_q12, child.home_q12);
    try std.testing.expectEqualDeep([3]i32{ actors[0].position_q12[0] - 40960, actors[0].position_q12[1], actors[0].position_q12[2] - 81920 }, child.position_q12);
    const attached = try actors[1].attachment();
    try std.testing.expectEqualDeep([2]i32{ attached[0], attached[1] }, child.offset_destination);
    try std.testing.expect(!child.has_draw_record);
    try action.advance(packet, &runtime);
    try std.testing.expectEqualDeep(child.position_q12, children[0].?.position_q12);
    for (0..40) |_| if (children[0] != null) try runtime.stepActor(2);
    try std.testing.expect(children[0] == null);
    actors[0].signals = 2;
    try action.advance(packet, &runtime);
    try runtime.stepActor(1);
    try std.testing.expect(action.damageReady(packet, runtime));
    try std.testing.expect(action.damageReady(packet, runtime));
    actors[1].signals |= 4;
    try action.acknowledgeDamage(packet, &runtime);
    try std.testing.expectEqual(@as(u16, 4), actors[1].signals);
    try std.testing.expectError(error.PhysicalDamageNotReady, action.acknowledgeDamage(packet, &runtime));
    actors[0].signals |= 4;
    try action.advance(packet, &runtime);
    try std.testing.expect(action.stage == .released);
    try std.testing.expect(!actors[1].machine.?.halted and actors[1].palette_cycle_active);
}

test "Physical rune controller matches source clocks for all owner choices and twelve actual enemy resources" {
    const parsed = try physical.load(allocator, @embedFile("fixtures/physical_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    const Reference = struct { cases: []const struct {
        technique: physical.Technique,
        member: []const u8,
        owner_signal: ?u16 = null,
        controller_release: ?u16 = null,
        owner_complete: ?u16 = null,
        recipient_contact: ?u16 = null,
        recipient_release: ?u16 = null,
        auxiliary_birth: ?u16 = null,
        blocked_animation: ?u16 = null,
        blocked_at: ?u16 = null,
    } };
    const reference = try std.json.parseFromSlice(Reference, allocator, @embedFile("fixtures/physical_controller_vectors.json"), .{ .ignore_unknown_fields = true });
    defer reference.deinit();
    for (packet.techniques) |binding| for (binding.members) |owner_id| for ([_][]const u8{ "bonbon", "crow", "wild_boar", "red_soldier_ant", "killer_rabbit", "flying_squirrel", "beast_commander", "roc", "kobold_type_1", "kobold_type_2", "kobold_type_3", "strong_arm" }) |enemy_id| {
        const expected = for (reference.value.cases) |case| {
            if (case.technique == binding.id and std.mem.eql(u8, case.member, owner_id)) break case;
        } else return error.MissingPhysicalReference;
        const owner_home = [3]i32{ 120 * 4096, -17 * 4096, 0 };
        const target_home = [3]i32{ -150 * 4096, 27 * 4096, 0 };
        var actors = [_]host.Actor{ try host.Actor.init(packet.animations.find(owner_id).?, owner_home), try host.Actor.init(packet.animations.find(enemy_id).?, target_home) };
        var children: [17]?host.Actor = @splat(null);
        var camera = try @import("battle_camera").ActorController.init(@import("battle_camera").standard_battle);
        var context = Context{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .camera_controller = &camera, .external = .{ .context = &context, .command = Context.command, .decoy_contact = Context.decoy, .previous_screen_position = Context.previous } };
        var action = try physical.Action.begin(packet, &runtime, binding.id, 0, 1);
        var damage_count: u16 = 0;
        var recipient_at: ?u16 = null;
        var contact_at: ?u16 = null;
        var released_at: ?u16 = null;
        var owner_done_at: ?u16 = null;
        var recipient_done_at: ?u16 = null;
        var completed = false;
        for (1..1501) |tick| {
            try action.advance(packet, &runtime);
            if (action.recipient_started and recipient_at == null) recipient_at = @intCast(tick);
            if (action.stage == .released and released_at == null) released_at = @intCast(tick);
            if (action.damageReady(packet, runtime)) {
                damage_count += 1;
                contact_at = @intCast(tick);
                try action.acknowledgeDamage(packet, &runtime);
            }
            runtime.beginUpdate();
            try runtime.stepActor(0);
            try runtime.stepActor(1);
            for (0..children.len) |index| if (children[index] != null) try runtime.stepActor(@intCast(actors.len + index));
            if (owner_done_at == null and actors[0].machine.?.halted) owner_done_at = @intCast(tick);
            if (recipient_done_at == null and action.recipient_started and actors[1].highlights == 0) recipient_done_at = @intCast(tick);
            var child_present = false;
            for (children) |child| child_present = child_present or child != null;
            if (action.stage == .released and !action.damage_pending and actors[0].machine.?.halted and actors[1].machine != null and actors[1].machine.?.halted and !child_present and actors[0].reaction_callback == null and actors[1].reaction_callback == null and !actors[0].blue_trail_active and !actors[1].palette_cycle_active) {
                completed = true;
                break;
            }
        }
        if (expected.blocked_animation) |animation| {
            try std.testing.expect(!completed);
            try std.testing.expectEqual(animation, actors[0].animation);
            try std.testing.expect(actors[0].animating and actors[0].machine.?.instructions[actors[0].machine.?.pc] == .wait);
            try std.testing.expect(!action.recipient_started and action.stage == .recipient);
            try std.testing.expectEqual(@as(u16, 0), damage_count);
            continue;
        }
        try std.testing.expect(completed);
        try std.testing.expectEqual(@as(u16, 1), damage_count);
        try std.testing.expectEqual(@as(u16, if (binding.id == .trick) 1 else 0), context.contacts);
        try std.testing.expectEqual(@as(u16, if (binding.recovery_boundaries == 0) 0 else 1), context.recoveries);
        try std.testing.expectEqual(binding.recovery_boundaries, context.recovery_boundaries);
        try std.testing.expectEqualDeep(owner_home, actors[0].position_q12);
        try std.testing.expectEqualDeep(target_home, actors[1].position_q12);
        try std.testing.expectEqual(@as(u8, 0), actors[0].highlights & 1);
        try std.testing.expectEqual(@as(u8, 0), actors[1].highlights & 8);
        try std.testing.expect(recipient_at != null and contact_at != null and released_at != null);
        try std.testing.expectEqual(expected.owner_signal.? + 1, recipient_at.?);
        try std.testing.expectEqual(expected.controller_release.?, released_at.?);
        try std.testing.expectEqual(expected.owner_complete.?, owner_done_at.?);
        try std.testing.expectEqual(expected.recipient_contact.?, contact_at.? - recipient_at.?);
        try std.testing.expectEqual(expected.recipient_release.?, recipient_done_at.? - recipient_at.? + 1);
        try std.testing.expect(!action.damageReady(packet, runtime));
    };
}
