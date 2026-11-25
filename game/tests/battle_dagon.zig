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
    result.schema = "suikoden-battle-trial/39";
    result.presentation_ready = false;
    // Isolated synthetic balance; admission tests below use the source catalogue.
    const enemies = try alloc.dupe(battle.Profile, result.enemies[0..1]);
    enemies[0].id = "dagon";
    enemies[0].name = "Dagon";
    enemies[0].action_policy = .source_dagon;
    enemies[0].target_policy = .front_first;
    enemies[0].dodges_attacks = true;
    enemies[0].unavoidable_attack = false;
    result.enemies = enemies;
    const encounters = try alloc.dupe(battle.Encounter, result.encounters[0..1]);
    encounters[0].enemies = &.{"dagon"};
    encounters[0].positions = &.{.{ .x = 80, .y = 0, .z = 0 }};
    encounters[0].source_slots = &.{0};
    encounters[0].enemy_rows = &.{.front};
    result.encounters = encounters;
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

test "Dagon actor admission refuses missing body art before custody" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    const graphics = try alloc.dupe(battle.UniteGraphic, data.unite_graphics);
    for (graphics) |*graphic| if (std.mem.eql(u8, graphic.id, "dagon")) {
        graphic.poses = &.{};
    };
    state.content.unite_graphics = graphics;
    try std.testing.expectError(error.MissingPhysicalArt, state.attachUniteActors(&actors));
    try std.testing.expect(state.unite_actors == null and !state.unite_vm.hasActors());
}

test "Dagon actor admission completes all six G formations with ordinary and poison branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const base = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const effects = try scenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var cases: usize = 0;
    for (base.encounters, 0..) |entry, index| {
        if (!std.mem.startsWith(u8, entry.id, "area_g_")) continue;
        for ([_]bool{ false, true }) |special| {
            var data = base;
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
            const values: [4096]u15 = @splat(if (special) 76 else 75);
            var draws = battle.systems.Draws{ .values = &values };
            var saw_spin = false;
            for (0..2400) |update| {
                state.tickReplay(.{}, &draws) catch |err| {
                    std.debug.print("G formation {s} special={} update={}: {s}\n", .{ entry.id, special, update, @errorName(err) });
                    return err;
                };
                for (state.partyCount()..state.partyCount() + state.enemyCount()) |actor| {
                    if (state.unite_vm.scripted_actors[actor] != null) try std.testing.expect(state.physicalRunePose(actor) != null);
                }
                saw_spin = saw_spin or state.unite_vm.actors[0].draw_angles[2] != 0;
                if (state.round >= 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
            }
            try std.testing.expectEqual(@as(u32, 2), state.round);
            try std.testing.expect(state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
            try std.testing.expect(members[0].hp < 9999);
            const has_dagon = std.mem.eql(u8, state.enemy(0).id, "dagon");
            try std.testing.expectEqual(special and has_dagon, saw_spin);
            try std.testing.expectEqual(special and has_dagon, members[0].status == .poisoned);
            try std.testing.expectEqual(@as(i16, 0), state.unite_vm.actors[0].draw_angles[2]);
            cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 18), cases);
}

test "Dagon actor admission receives ordinary critical dodged lethal and counter contacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    var data = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const index = for (data.encounters, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "area_g_2")) break i;
    } else return error.MissingDagonFormation;
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
        const target: usize = if (scenario == 4) 1 else 0;
        const enemy = state.partyCount() + target;
        state.enemy_hp[target] = if (scenario == 3) 1 else 9999;
        const initial = state.enemy_hp[target];
        const damage = if (scenario == 2) 0 else state.resolvePhysicalDamage(0, enemy, 0, false) * @as(u32, if (scenario == 1) 3 else 1);
        if (scenario == 4) {
            state.actions[0] = .defend;
            try std.testing.expect(!try state.counterAvailable(state.partyCount(), 0));
            try std.testing.expectError(error.InvalidActorBinding, state.beginCounter(state.partyCount(), 0));
            try std.testing.expect(try state.counterAvailable(enemy, 0));
            try state.beginCounter(enemy, 0);
        } else try state.beginPartyMelee(0, enemy, scenario != 2, scenario == 1);
        var draws = battle.systems.Draws{ .values = &.{0} };
        var saw_dodge = false;
        for (0..600) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.unite_vm.scripted_actors[state.partyCount()] != null) {
                const actor = state.unite_vm.actors[state.partyCount()];
                saw_dodge = saw_dodge or !std.meta.eql(actor.position_q12, actor.home_q12);
            }
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(state.active == null and !state.unite_vm.hasActors());
        try std.testing.expectEqual(@as(u16, @intCast(@as(u32, initial) -| damage)), state.enemy_hp[target]);
        try std.testing.expectEqual(@as(u16, 9999), members[0].hp);
        try std.testing.expectEqual(@as(usize, if (scenario == 2) 0 else 1), draws.cursor);
        if (scenario == 2) try std.testing.expect(saw_dodge);
    }
}

test "Dagon actor special preserves half damage poison spin return and primary-camera request phase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc);
    const items = try field.items.load(alloc, field.items.json);
    const request = actors.counterPacket().?.meleeEnemy("dagon").?.special.?.return_camera.?;
    const desired = [4][3]i32{ request.target.focus, request.target.angles, request.target.translation, request.target.scale };
    for (0..6) |target| for (0..6) |mode| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        state.phase = .battle_menu;
        state.acted = @splat(true);
        for (&members) |*member| {
            member.hp = 9999;
            member.max_hp = 9999;
            member.status = .healthy;
        }
        if (mode == 1) state.actions[target] = .defend;
        if (mode == 2) state.actor_conditions[target].protection_rounds = 2;
        if (mode == 3) state.runes[target] = data.systems.?.runeIndex("turtle").?;
        if (mode == 5) {
            members[target].hp = 1;
            members[target].inventory.slots = @splat(null);
        }
        const initial = members[target].hp;
        const owner = state.partyCount();
        const amount = if (mode == 2) 0 else state.resolvePhysicalDamage(owner, target, 0, mode == 1) / 2;
        try state.beginEnemySpecial(owner, target);
        var draws = battle.systems.Draws{ .values = &.{ 0, if (mode == 4) @as(u15, 9831) else 0 } };
        var contact: ?u32 = null;
        var returned: ?u32 = null;
        var start: [4][3]i32 = undefined;
        var saw_spin = false;
        var saw_poison = false;
        for (0..900) |update| {
            const before_camera = if (state.actor_camera) |camera| camera.current else null;
            state.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("Dagon target={} mode={} update={}: {s}\n", .{ target, mode, update, @errorName(err) });
                return err;
            };
            for (state.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.contact_at) |at| {
                    if (contact == null) contact = at;
                    try std.testing.expectEqual(@as(u32, amount), playback.amount);
                    try std.testing.expect(state.unite_vm.actors[owner].signals & 2 != 0);
                    saw_poison = saw_poison or (state.party_knockouts[target].prior_status orelse members[target].status) == .poisoned;
                }
                if (playback.action != null and playback.action.?.stage == .returning and returned == null) {
                    returned = state.camera_ticks;
                    start = before_camera.?;
                    try std.testing.expectEqualDeep(@as([4]u16, @splat(9)), state.actor_camera.?.remaining);
                }
            };
            saw_spin = saw_spin or state.unite_vm.actors[target].draw_angles[2] != 0;
            if (returned) |at| {
                const age = state.camera_ticks - at + 1;
                for (0..4) |channel| for (0..3) |axis| {
                    const expected = if (age <= 10) start[channel][axis] + @divTrunc(desired[channel][axis] - start[channel][axis], 10) * @as(i32, @intCast(age)) else desired[channel][axis];
                    try std.testing.expectEqual(expected, state.actor_camera.?.current[channel][axis]);
                };
            }
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(?u32, 80), contact);
        try std.testing.expectEqual(@as(?u32, 118), returned);
        try std.testing.expect(saw_spin);
        try std.testing.expectEqual(@as(u16, @intCast(@as(u32, initial) -| amount)), members[target].hp);
        try std.testing.expectEqual(mode != 3 and mode != 4, saw_poison);
        try std.testing.expectEqual(@as(usize, if (mode == 3) 1 else 2), draws.cursor);
        try std.testing.expect(state.active == null and !state.unite_vm.hasActors());
        try std.testing.expectEqual(@as(i16, 0), state.unite_vm.actors[target].draw_angles[2]);
    };
}

test "Dagon actor AI uses modulo thresholds and refuses stale source bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for ([_]u15{ 75, 76, 100, 32767 }) |secondary| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        var legacy = actors;
        legacy.schema = "suikoden-unite-actors/35";
        legacy.group_orders = null;
        legacy.enemy_wave = null;
        legacy.enemy_area_magic = null;
        legacy.enemy_regional = null;
        const legacy_reactions = try alloc.dupe(counter.PartyReaction, actors.counter.?.melee.?.party_reactions);
        for (legacy_reactions) |*reaction| reaction.return_program = null;
        legacy.counter.?.melee.?.party_reactions = legacy_reactions;
        var melee: std.ArrayList(counter.MeleeEnemy) = .empty;
        for (actors.counter.?.melee.?.enemies) |enemy| if (!std.mem.eql(u8, enemy.id, "dagon")) try melee.append(alloc, enemy);
        legacy.counter.?.melee.?.enemies = melee.items;
        try std.testing.expectError(error.MissingDagonBinding, state.attachUniteActors(&legacy));
        try state.attachUniteActors(&actors);
        state.acted = @splat(true);
        state.coordinator = .{ .stage = .dispatch, .current_actor = state.partyCount() };
        var values = [_]u15{ 51, secondary, 0 };
        var draws = battle.systems.Draws{ .values = &values };
        state.replay_draws = &draws;
        state.sourceEnemyDecision(state.partyCount());
        state.replay_draws = null;
        try std.testing.expect(state.replay_unsupported == null and !state.replay_exhausted);
        const special = secondary % 100 >= 76;
        try std.testing.expectEqual(if (special) counter.Kind.special else .ordinary_hit, state.unite_vm.counter_actions[0].?.kind);
        try std.testing.expectEqual(@as(usize, if (special) 2 else 3), draws.cursor);
    }
    var older = actors;
    older.schema = "suikoden-unite-actors/35";
    try std.testing.expectError(error.InvalidUniteBindings, older.validate());
    var older_data = data;
    older_data.schema = "suikoden-battle-trial/38";
    try std.testing.expectError(error.UnsupportedEnemyPresentation, older_data.validate());
}

test "Dagon actor primary HP and yielded recipient poison roll back the complete contact update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    state.phase = .battle_menu;
    state.acted = @splat(true);
    members[0].hp = 9999;
    members[0].max_hp = 9999;
    members[0].status = .healthy;
    try state.beginEnemySpecial(state.partyCount(), 0);
    var empty = battle.systems.Draws{};
    for (1..80) |_| try state.tickReplay(.{}, &empty);
    const machine = state.unite_vm.actors[0].machine;
    const camera = state.actor_camera.?;
    for ([_][]const u15{ &.{}, &.{0} }) |values| {
        var missing = battle.systems.Draws{ .values = values };
        try std.testing.expectError(error.RandomInputExhausted, state.tickReplay(.{}, &missing));
        try std.testing.expectEqual(@as(u32, 79), state.camera_ticks);
        try std.testing.expectEqual(@as(u16, 9999), members[0].hp);
        try std.testing.expectEqualDeep(machine, state.unite_vm.actors[0].machine);
        try std.testing.expectEqualDeep(camera, state.actor_camera.?);
        try std.testing.expect(members[0].status == .healthy);
        try std.testing.expectEqual(@as(usize, 0), missing.cursor);
    }
    var complete = battle.systems.Draws{ .values = &.{ 0, 0 } };
    try state.tickReplay(.{}, &complete);
    try std.testing.expectEqual(@as(u32, 80), state.camera_ticks);
    try std.testing.expect(members[0].hp < 9999);
    try std.testing.expect(members[0].status == .poisoned);
    try std.testing.expectEqual(@as(usize, 2), complete.cursor);
}

test "Dagon actor ordinary and special finish full coordinator rounds" {
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
        values[1] = if (special) 76 else 75;
        var draws = battle.systems.Draws{ .values = &values };
        for (0..900) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(u32, 2), state.round);
        try std.testing.expect(state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
        try std.testing.expect(members[0].hp < 9999);
    }
}
