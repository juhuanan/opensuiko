const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const host = battle.actor_host;
const counter = battle.counter;

fn library(alloc: std.mem.Allocator) !host.Bundle {
    return (try host.loadBundle(alloc, @embedFile("fixtures/journey_unites_actor_library.json"))).value;
}

fn content(alloc: std.mem.Allocator) !battle.Content {
    var result = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    result.schema = "suikoden-battle-trial/38";
    result.presentation_ready = false;
    // Synthetic mechanics fixture; source stats, art and formations have a separate admission gate.
    const enemy = try alloc.dupe(battle.Profile, result.enemies[0..1]);
    enemy[0].id = "ninja_master";
    enemy[0].name = "Ninja Master";
    enemy[0].action_policy = .source_ninja;
    enemy[0].target_policy = .front_first;
    enemy[0].unavoidable_attack = false;
    enemy[0].dodges_attacks = false;
    result.enemies = enemy;
    const encounter = try alloc.dupe(battle.Encounter, result.encounters[0..1]);
    encounter[0].enemies = &.{"ninja_master"};
    encounter[0].positions = &.{.{ .x = 80, .y = 0, .z = 0 }};
    encounter[0].source_slots = &.{0};
    encounter[0].enemy_rows = &.{.front};
    result.encounters = encounter;
    try result.validate();
    return result;
}

fn scenes(alloc: std.mem.Allocator) !battle.spell_scene.Packet {
    var base = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/spell_scene_library.json"), .{});
    const patch = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/journey_unite_scenes_patch.json"), .{});
    var fields = patch.value.object.iterator();
    while (fields.next()) |entry| try base.value.object.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    return (try battle.spell_scene.load(alloc, try std.json.Stringify.valueAlloc(alloc, base.value, .{}))).value;
}

test "Ninja actor admission refuses missing afterimages and projectile pieces before custody" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const base = try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"));
    const items = try field.items.load(alloc, field.items.json);
    for (0..2) |missing| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(base.value, items.value, &members, 1234);
        const graphics = try alloc.dupe(battle.UniteGraphic, base.value.unite_graphics);
        for (graphics) |*graphic| if (std.mem.eql(u8, graphic.id, "ninja_master")) {
            const poses = try alloc.dupe(battle.UniteGraphicPose, graphic.poses);
            for (poses) |*pose| {
                if (missing == 0) pose.trail = null else pose.pieces = &.{};
            }
            graphic.poses = poses;
        };
        state.content.unite_graphics = graphics;
        try std.testing.expectError(error.MissingPhysicalArt, state.attachUniteActors(&actors));
        try std.testing.expect(state.unite_actors == null and !state.unite_vm.hasActors());
    }
}

test "Ninja actor admission composes both branches and enemy afterimages in all seven new Z formations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const base = try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"));
    const effects = try scenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for ([_][]const u8{ "area_z_1", "area_z_2", "area_z_3", "area_z_4", "area_z_11", "area_z_12", "area_z_13" }) |id| for ([_]bool{ false, true }) |special| {
        var data = base.value;
        const index = for (data.encounters, 0..) |entry, i| {
            if (std.mem.eql(u8, id, entry.id)) break i;
        } else return error.MissingNinjaFormation;
        data.encounters = data.encounters[index..][0..1];
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        for (&members, 0..) |*member, i| {
            member.hp = 9999;
            member.max_hp = 9999;
            state.actions[i] = .defend;
        }
        state.acted = @splat(true);
        state.phase = .resolving;
        const owner = state.partyCount();
        try std.testing.expectEqualStrings("ninja_master", state.enemy(0).id);
        state.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        var values: [128]u15 = @splat(32767);
        values[1] = if (special) 32767 else 0;
        values[2] = 0;
        var draws = battle.systems.Draws{ .values = &values };
        var saw_trail = false;
        var saw_projectile = false;
        for (0..600) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.unite_vm.scripted_actors[owner] != null) try std.testing.expect(state.physicalRunePose(owner) != null);
            if (state.unite_vm.actors[owner].blue_trail) |trail| if (trail.visible) {
                const quads = battle.layout.uniteTrail(state, owner) orelse return error.MissingNinjaTrail;
                try std.testing.expect(quads[0].scale > 0 and std.math.isFinite(quads[0].point.x));
                saw_trail = true;
            };
            for (state.unite_vm.auxiliary, 0..) |maybe, slot| if (maybe) |child| {
                if (child.resource != null and std.mem.eql(u8, child.resource.?.id, "ninja_master") and child.visible) {
                    try std.testing.expect(battle.layout.uniteAuxiliary(state, slot) != null);
                    try std.testing.expect(battle.layout.uniteAuxiliaryPiece(state, slot, 0) != null);
                    saw_projectile = true;
                }
            };
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(special, saw_trail);
        try std.testing.expectEqual(!special, saw_projectile);
        try std.testing.expect(members[0].hp < 9999);
        try std.testing.expect(state.active == null and !state.unite_vm.hasActors());
        try std.testing.expect(battle.layout.uniteTrail(state, owner) == null);
    };
}

test "Ninja actor admission completes all thirteen Z formations through mixed source enemy rounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const base = try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"));
    const effects = try scenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var cases: usize = 0;
    for (base.value.encounters, 0..) |entry, index| {
        if (!std.mem.startsWith(u8, entry.id, "area_z_")) continue;
        for ([_]bool{ false, true }) |mixed| {
            var data = base.value;
            data.encounters = data.encounters[index..][0..1];
            var members: [6]battle.Member = undefined;
            var state = try battle.State.init(data, items.value, &members, 1234);
            try state.attachUniteActors(&actors);
            try state.attachSpellScenes(&effects);
            for (&members, 0..) |*member, i| {
                member.hp = 9999;
                member.max_hp = 9999;
                state.actions[i] = .defend;
            }
            state.acted = @splat(true);
            for (state.partyCount()..state.partyCount() + state.enemyCount()) |actor| state.acted[actor] = false;
            state.phase = .resolving;
            state.coordinator = .{ .stage = .dispatch, .current_actor = state.partyCount() };
            var values: [4096]u15 = @splat(32767);
            if (mixed) {
                values[1] = 0;
                values[2] = 0;
            }
            var draws = battle.systems.Draws{ .values = &values };
            for (0..2400) |update| {
                state.tickReplay(.{}, &draws) catch |err| {
                    std.debug.print("Z formation {s} mixed={} update={}: {s}\n", .{ entry.id, mixed, update, @errorName(err) });
                    return err;
                };
                if (state.round >= 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
            }
            try std.testing.expectEqual(@as(u32, 2), state.round);
            try std.testing.expect(state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
            cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 26), cases);
}

test "Ninja actor admission receives party hits misses criticals KO and dispatches its source parry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    var data = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const index = for (data.encounters, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "area_z_2")) break i;
    } else return error.MissingNinjaFormation;
    data.encounters = data.encounters[index..][0..1];
    const effects = try scenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for (0..5) |scenario| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        state.phase = .battle_menu;
        state.acted = @splat(true);
        members[0].hp = 9999;
        members[0].max_hp = 9999;
        state.enemy_hp[0] = if (scenario == 3) 1 else 9999;
        const initial = state.enemy_hp[0];
        const damage = if (scenario == 2 or scenario == 4) 0 else state.resolvePhysicalDamage(0, state.partyCount(), 0, false) * @as(u32, if (scenario == 1) 3 else 1);
        const parry = state.resolvePhysicalDamage(state.partyCount(), 0, 0, false);
        if (scenario == 4) try state.beginParry(0, state.partyCount()) else try state.beginPartyMelee(0, state.partyCount(), scenario != 2, scenario == 1);
        var draws = battle.systems.Draws{ .values = &.{0} };
        for (0..400) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(state.active == null and !state.unite_vm.hasActors());
        try std.testing.expectEqual(@as(u16, @intCast(@as(u32, initial) -| damage)), state.enemy_hp[0]);
        try std.testing.expectEqual(@as(u16, @intCast(9999 - if (scenario == 4) parry else @as(u32, 0))), members[0].hp);
        try std.testing.expectEqual(@as(usize, if (scenario == 2) 0 else 1), draws.cursor);
    }
}

test "Ninja actor special uses contact damage and its separate return for every party recipient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for (0..6) |target| for (0..6) |mode| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        state.acted = @splat(true);
        state.phase = .battle_menu;
        for (&members) |*member| {
            member.hp = 9999;
            member.max_hp = 9999;
        }
        if (mode == 1) state.actions[target] = .defend;
        if (mode == 2) state.protection[target] = 2;
        if (mode == 3) state.runes[target] = data.systems.?.runeIndex("turtle").?;
        if (mode == 5) {
            members[target].hp = 1;
            members[target].inventory.slots = @splat(null);
        }
        const initial_hp = members[target].hp;
        const owner = state.partyCount();
        const expected = if (mode == 2) 0 else state.resolvePhysicalDamage(owner, target, 0, mode == 1) * 3 / 2;
        try state.beginEnemySpecial(owner, target);
        const values = [_]u15{ 0, if (mode == 4) 9831 else 0 };
        var draws = battle.systems.Draws{ .values = &values };
        var contact: ?u32 = null;
        var returned = false;
        var saw_block = false;
        for (1..500) |update| {
            state.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("Ninja target={} mode={} update={}: {s}\n", .{ target, mode, update, @errorName(err) });
                return err;
            };
            for (state.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.contact_at) |at| {
                    if (contact == null) contact = at;
                    saw_block = saw_block or state.rune_blocked[target];
                    try std.testing.expectEqual(@as(u32, expected), playback.amount);
                    try std.testing.expect(state.unite_vm.actors[owner].signals & 2 == 0);
                }
                if (playback.action != null and playback.action.?.stage == .returning) {
                    returned = true;
                    const returning = actors.programs.find(actors.counterPacket().?.meleeEnemy("ninja_master").?.special.?.return_program.?).?;
                    try std.testing.expect(state.unite_vm.actors[owner].machine.?.instructions.ptr == returning.instructions.ptr);
                }
            };
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(?u32, 57), contact);
        try std.testing.expect(returned);
        try std.testing.expectEqual(@as(u16, @intCast(initial_hp -| expected)), members[target].hp);
        const immune = state.hasRune(target, "turtle");
        try std.testing.expectEqual(@as(usize, if (immune) 1 else 2), draws.cursor);
        try std.testing.expectEqual(!immune and mode != 4, saw_block);
        try std.testing.expectEqual(!immune and mode != 4 and mode != 5, state.rune_blocked[target]);
        if (mode == 5) try std.testing.expect(members[target].status == .unconscious and !state.knockout_pending[target]);
        try std.testing.expect(state.active == null and !state.unite_vm.hasActors());
    };
}

test "Ninja actor AI keeps threshold boundaries and waits without selecting another target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for (0..3) |scenario| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        const owner = state.partyCount();
        state.acted = @splat(true);
        state.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        if (scenario == 2) {
            state.unite_vm.scripted_actors[1] = .{ .family = .counter, .leader = 0, .resource = 0 };
            state.unite_vm.actors[1].highlights = 1;
        }
        var draws = battle.systems.Draws{ .values = &.{ 51, if (scenario == 0) 16711 else 16712, 0 } };
        state.replay_draws = &draws;
        state.sourceEnemyDecision(owner);
        try std.testing.expect(!state.replay_exhausted and state.replay_unsupported == null);
        if (scenario == 0) {
            try std.testing.expectEqual(@as(usize, 3), draws.cursor);
            try std.testing.expectEqual(counter.Kind.ordinary_hit, state.unite_vm.counter_actions[0].?.kind);
        } else if (scenario == 1) {
            try std.testing.expectEqual(@as(usize, 2), draws.cursor);
            try std.testing.expectEqual(counter.Kind.special, state.unite_vm.counter_actions[0].?.kind);
        } else {
            try std.testing.expect(state.active == null and state.pending_enemy_actor == owner and !state.acted[owner]);
            try std.testing.expectEqual(@as(u8, 0), state.enemy_branch_selection.?.recipient);
            for (0..20) |_| {
                state.sourceEnemyDecision(owner);
                try std.testing.expectEqual(@as(usize, 2), draws.cursor);
                try std.testing.expect(state.active == null);
            }
            state.unite_vm.actors[1].highlights = 0;
            state.unite_vm.scripted_actors[1] = null;
            state.sourceEnemyDecision(owner);
            try std.testing.expectEqual(@as(usize, 2), draws.cursor);
            try std.testing.expect(state.enemy_branch_selection == null and state.pending_enemy_actor == null and state.acted[owner]);
            try std.testing.expectEqual(counter.Kind.special, state.unite_vm.counter_actions[0].?.kind);
            try std.testing.expectEqual(@as(u8, 0), state.unite_vm.counter_actions[0].?.defender);
        }
        state.replay_draws = null;
    }
}

test "Ninja actor contact rolls HP and rune block atomically and refuses stale bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    var legacy = actors;
    legacy.schema = "suikoden-unite-actors/34";
    legacy.group_orders = null;
    legacy.enemy_wave = null;
    legacy.enemy_area_magic = null;
    legacy.enemy_regional = null;
    const legacy_reactions = try alloc.dupe(counter.PartyReaction, actors.counter.?.melee.?.party_reactions);
    for (legacy_reactions) |*reaction| reaction.return_program = null;
    legacy.counter.?.melee.?.party_reactions = legacy_reactions;
    var legacy_melee: std.ArrayList(counter.MeleeEnemy) = .empty;
    for (actors.counter.?.melee.?.enemies) |enemy| if (!std.mem.eql(u8, enemy.id, "ninja_master") and (enemy.special == null or enemy.special.?.return_camera == null)) try legacy_melee.append(alloc, enemy);
    legacy.counter.?.melee.?.enemies = legacy_melee.items;
    try std.testing.expectError(error.MissingNinjaBinding, state.attachUniteActors(&legacy));
    try std.testing.expect(state.unite_actors == null);
    try state.attachUniteActors(&actors);
    var older = actors;
    older.schema = "suikoden-unite-actors/34";
    try std.testing.expectError(error.InvalidUniteBindings, older.validate());
    var older_data = data;
    older_data.schema = "suikoden-battle-trial/37";
    try std.testing.expectError(error.UnsupportedEnemyPresentation, older_data.validate());
    const altered = try alloc.dupe(counter.MeleeEnemy, actors.counter.?.melee.?.enemies);
    for (altered) |*enemy| if (std.mem.eql(u8, enemy.id, "ninja_master")) {
        enemy.special.?.damage_denominator = 0;
    };
    var invalid = actors;
    invalid.counter.?.melee.?.enemies = altered;
    try std.testing.expectError(error.InvalidCounterBindings, invalid.validate());
    state.phase = .battle_menu;
    state.acted = @splat(true);
    members[0].hp = 9999;
    members[0].max_hp = 9999;
    const owner = state.partyCount();
    try state.beginEnemySpecial(owner, 0);
    var empty = battle.systems.Draws{};
    for (1..57) |_| try state.tickReplay(.{}, &empty);
    const hp = members[0].hp;
    const clock = state.camera_ticks;
    const pc = state.unite_vm.actors[owner].machine.?.pc;
    for ([_][]const u15{ &.{}, &.{0} }) |values| {
        var missing = battle.systems.Draws{ .values = values };
        try std.testing.expectError(error.RandomInputExhausted, state.tickReplay(.{}, &missing));
        try std.testing.expectEqual(hp, members[0].hp);
        try std.testing.expectEqual(clock, state.camera_ticks);
        try std.testing.expectEqual(pc, state.unite_vm.actors[owner].machine.?.pc);
        try std.testing.expectEqual(@as(usize, 0), missing.cursor);
        try std.testing.expect(!state.rune_blocked[0] and state.unite_vm.counter_actions[0].?.contact_at == null);
    }
    var complete = battle.systems.Draws{ .values = &.{ 0, 0 } };
    try state.tickReplay(.{}, &complete);
    try std.testing.expect(members[0].hp < hp and state.rune_blocked[0]);
    try std.testing.expectEqual(@as(usize, 2), complete.cursor);
}

test "Ninja actor ordinary and special decisions finish complete source-coordinator rounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for ([_]bool{ false, true }) |special| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        for (&members, 0..) |*member, i| {
            member.hp = 9999;
            member.max_hp = 9999;
            state.actions[i] = .defend;
        }
        state.acted = @splat(true);
        state.acted[state.partyCount()] = false;
        state.phase = .resolving;
        state.coordinator = .{ .stage = .dispatch, .current_actor = state.partyCount() };
        var values: [128]u15 = @splat(0);
        values[0] = 51;
        values[1] = if (special) 16712 else 0;
        var draws = battle.systems.Draws{ .values = &values };
        for (0..900) |update| {
            state.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("Ninja full round special={} update={} cursor={}: {s}\n", .{ special, update, draws.cursor, @errorName(err) });
                return err;
            };
            if (state.round >= 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(u32, 2), state.round);
        try std.testing.expect(state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
        try std.testing.expect(members[0].hp < 9999);
        try std.testing.expectEqual(special, state.rune_blocked[0]);
    }
}
