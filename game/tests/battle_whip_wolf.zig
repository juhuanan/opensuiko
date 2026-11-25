const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const host = battle.actor_host;
const counter = battle.counter;

fn library(alloc: std.mem.Allocator) !host.Bundle {
    return (try host.loadBundle(alloc, @embedFile("fixtures/journey_unites_actor_library.json"))).value;
}

fn content(alloc: std.mem.Allocator, rear: bool) !battle.Content {
    var result = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const index = for (result.encounters, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "area_e_1")) break i;
    } else return error.MissingWhipWolfFormation;
    const entries = try alloc.dupe(battle.Encounter, result.encounters[index..][0..1]);
    // E1 is rear-row; the explicit front diagnostic exercises the other source branch.
    if (!rear) entries[0].enemy_rows = &.{ .front, .front, .front, .front };
    result.encounters = entries;
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

fn prepare(state: *battle.State, members: []battle.Member) void {
    for (members, 0..) |*member, i| {
        member.hp = 9999;
        member.max_hp = 9999;
        member.status = .healthy;
        state.actions[i] = .defend;
    }
    state.acted = @splat(true);
    state.phase = .battle_menu;
}

test "Whip Wolf actor admission refuses missing body art before library custody" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    const graphics = try alloc.dupe(battle.UniteGraphic, data.unite_graphics);
    for (graphics) |*graphic| if (std.mem.eql(u8, graphic.id, "whip_wolf")) {
        graphic.poses = &.{};
    };
    state.content.unite_graphics = graphics;
    try std.testing.expectError(error.MissingPhysicalArt, state.attachUniteActors(&actors));
    try std.testing.expect(state.unite_actors == null and !state.unite_vm.hasActors());
}

test "Whip Wolf actor admission queues E1 orders through normal enemy priority and finishes the round" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, true);
    const effects = try scenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    try state.attachSpellScenes(&effects);
    prepare(&state, &members);
    for (state.partyCount()..state.partyCount() + state.enemyCount()) |actor| state.acted[actor] = false;
    state.phase = .resolving;
    state.coordinator = .{ .stage = .select, .current_actor = 0, .completed = true };
    const values: [128]u15 = @splat(0);
    var draws = battle.systems.Draws{ .values = &values };
    var ordered = false;
    for (0..900) |_| {
        try state.tickReplay(.{}, &draws);
        if (state.unite_vm.commander_actions[state.partyCount() + 3]) |playback| if (playback.ordered_at != null) {
            ordered = true;
        };
        if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
    }
    try std.testing.expect(ordered);
    try std.testing.expectEqual(@as(u32, 2), state.round);
    try std.testing.expect(state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
    try std.testing.expectEqual(@as(usize, 7), draws.cursor);
    for (members[0..3]) |member| try std.testing.expect(member.hp < 9999);
    for (members[3..]) |member| try std.testing.expectEqual(@as(u16, 9999), member.hp);
}

test "Whip Wolf actor admission receives ranged hits criticals dodges and KO in its original rear slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    var data = try content(alloc, true);
    // Cleo's source long-range attack can reach E1's rear owner.
    const party = try alloc.dupe([]const u8, data.initial_party.?);
    party[0] = "cleo";
    data.initial_party = party;
    const effects = try scenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for (0..4) |mode| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        prepare(&state, &members);
        const target = state.partyCount() + 3;
        try std.testing.expect(state.canAttackTarget(0, 3));
        state.enemy_hp[3] = if (mode == 3) 1 else 9999;
        const initial = state.enemy_hp[3];
        const damage = if (mode == 2) 0 else state.resolvePhysicalDamage(0, target, 0, false) * @as(u32, if (mode == 1) 3 else 1);
        try state.beginRanged(0, target, mode != 2, mode == 1);
        var draws = battle.systems.Draws{ .values = &.{0} };
        var saw_dodge = false;
        for (0..900) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.unite_vm.scripted_actors[target] != null) {
                const actor = state.unite_vm.actors[target];
                try std.testing.expect(state.physicalRunePose(target) != null);
                saw_dodge = saw_dodge or !std.meta.eql(actor.position_q12, actor.home_q12);
            }
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(state.active == null and !state.unite_vm.hasActors());
        try std.testing.expectEqual(@as(u16, @intCast(@as(u32, initial) -| damage)), state.enemy_hp[3]);
        try std.testing.expectEqual(@as(usize, if (mode == 2) 0 else 1), draws.cursor);
        if (mode == 2) try std.testing.expect(saw_dodge);
        try std.testing.expectEqual(@as(u16, 9999), members[0].hp);
    }
}

test "Whip Wolf actor front scan uses scaled draws across both rows and keeps an empty scan pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, false);
    const items = try field.items.load(alloc, field.items.json);
    const effects = try scenes(alloc);
    for ([_]u15{ 51, 16711, 16712, 32767 }) |draw| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        prepare(&state, &members);
        const owner = state.partyCount() + 3;
        var values: [7]u15 = @splat(draw);
        const accepted = @as(u32, draw) * 100 / 32767 >= 51;
        if (accepted) values[1] = 0;
        var draws = battle.systems.Draws{ .values = &values };
        state.replay_draws = &draws;
        state.sourceEnemyDecision(owner);
        state.replay_draws = null;
        try std.testing.expect(state.replay_unsupported == null and !state.replay_exhausted);
        try std.testing.expectEqual(@as(usize, if (accepted) 2 else 6), draws.cursor);
        if (accepted) try std.testing.expectEqual(@as(usize, 0), state.active.?.target) else try std.testing.expectEqual(@as(?usize, owner), state.pending_enemy_actor);
    }
    for ([_]bool{ false, true }) |all_down| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        prepare(&state, &members);
        for (members[0..if (all_down) 6 else 3]) |*member| {
            member.hp = 0;
            member.status = .unconscious;
        }
        const owner = state.partyCount() + 3;
        var draws = battle.systems.Draws{ .values = &.{ 16712, 0 } };
        state.replay_draws = &draws;
        state.sourceEnemyDecision(owner);
        state.replay_draws = null;
        if (all_down) {
            try std.testing.expectEqual(@as(?usize, owner), state.pending_enemy_actor);
            try std.testing.expect(!state.acted[owner]);
        } else try std.testing.expectEqual(@as(usize, 3), state.active.?.target);
        try std.testing.expectEqual(@as(usize, if (all_down) 0 else 2), draws.cursor);
    }
}

test "Whip Wolf actor group orders preserve launch delay eligibility mapping protection and round cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    const effects = try scenes(alloc);
    for (0..8) |mode| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        prepare(&state, &members);
        if (mode == 1) state.protection[0] = 2;
        for (state.partyCount()..state.partyCount() + 3) |ally| state.acted[ally] = mode == 5;
        if (mode == 2) state.acted[state.partyCount()] = true;
        if (mode == 3) state.enemy_hp[0] = 0;
        if (mode == 4) {
            members[0].hp = 0;
            members[0].status = .unconscious;
        }
        if (mode == 6) state.formation = .{ 3, 1, 2, 0, 4, 5 };
        if (mode == 7) {
            for (state.actions[0..state.partyCount()]) |*action| action.* = null;
        }
        const owner = state.partyCount() + 3;
        state.phase = .resolving;
        state.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        var expected: [6]u16 = @splat(9999);
        if (mode == 4) expected[0] = 0;
        var contacts: usize = 0;
        for (0..3) |ally| {
            const target = state.formation[ally];
            if (mode == 5 or (ally == 0 and (mode == 2 or mode == 3 or mode == 4))) continue;
            const amount = if (mode == 1 and target == 0) 0 else state.resolvePhysicalDamage(state.partyCount() + ally, target, 0, mode != 7);
            expected[target] -|= @intCast(amount);
            contacts += 1;
        }
        var values: [128]u15 = @splat(0);
        // The ally skipped for its down recipient retains its own ordinary turn.
        if (mode == 4) @memset(values[2..], 99);
        var draws = battle.systems.Draws{ .values = &values };
        state.replay_draws = &draws;
        state.sourceEnemyDecision(owner);
        state.replay_draws = null;
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        var launched = false;
        for (0..900) |update| {
            state.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("Whip Wolf mode={} update={}: {s}\n", .{ mode, update, @errorName(err) });
                return err;
            };
            if (state.unite_vm.commander_actions[owner]) |playback| if (playback.ordered_at) |at| {
                try std.testing.expectEqualStrings("whip_wolf", playback.id);
                try std.testing.expectEqual(@as(u32, 22), at - playback.start_at + 1);
                launched = true;
            };
            if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(launched);
        try std.testing.expectEqual(@as(u32, 2), state.round);
        try std.testing.expect(state.active == null and !state.unite_vm.hasActors());
        try std.testing.expect(state.phase == .battle_menu);
        try std.testing.expectEqual(contacts + @as(usize, if (mode == 4) 3 else 0), draws.cursor);
        for (members, expected) |member, hp| try std.testing.expectEqual(hp, member.hp);
    }
}

test "Whip Wolf actor front ordinary attacks complete defended and protected rounds for every recipient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, false);
    const items = try field.items.load(alloc, field.items.json);
    const effects = try scenes(alloc);
    for (0..6) |target| for ([_]bool{ false, true }) |protected| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        prepare(&state, &members);
        if (protected) state.protection[target] = 2;
        const owner = state.partyCount() + 3;
        const amount = if (protected) 0 else state.resolvePhysicalDamage(owner, target, 0, true);
        state.phase = .resolving;
        state.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        var values: [128]u15 = @splat(0);
        values[target] = 16712;
        var draws = battle.systems.Draws{ .values = &values };
        for (0..900) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(u32, 2), state.round);
        try std.testing.expect(state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
        try std.testing.expectEqual(@as(u16, @intCast(9999 - amount)), members[target].hp);
        try std.testing.expectEqual(target + 3, draws.cursor);
        for (members, 0..) |member, i| if (i != target) try std.testing.expectEqual(@as(u16, 9999), member.hp);
    };
}

test "Whip Wolf actor ordered contacts roll back all simultaneous damage when draws run out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    const effects = try scenes(alloc);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    try state.attachSpellScenes(&effects);
    prepare(&state, &members);
    for (state.partyCount()..state.partyCount() + 3) |ally| state.acted[ally] = false;
    try state.beginSourceCommander(state.partyCount() + 3, null);
    var empty = battle.systems.Draws{};
    var ready = false;
    for (0..400) |_| {
        for (state.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
            if (playback.action != null and playback.action.?.stage == .approach and state.unite_vm.actors[playback.attacker].signals & 2 != 0) ready = true;
        };
        if (ready) break;
        try state.tickReplay(.{}, &empty);
    }
    try std.testing.expect(ready);
    const clock = state.camera_ticks;
    const vm = state.unite_vm;
    for ([_][]const u15{ &.{}, &.{0}, &.{ 0, 0 } }) |values| {
        var missing = battle.systems.Draws{ .values = values };
        try std.testing.expectError(error.RandomInputExhausted, state.tickReplay(.{}, &missing));
        try std.testing.expectEqual(clock, state.camera_ticks);
        try std.testing.expectEqualDeep(vm, state.unite_vm);
        for (members) |member| try std.testing.expectEqual(@as(u16, 9999), member.hp);
        try std.testing.expectEqual(@as(usize, 0), missing.cursor);
    }
    var complete = battle.systems.Draws{ .values = &.{ 0, 0, 0 } };
    try state.tickReplay(.{}, &complete);
    try std.testing.expectEqual(@as(usize, 3), complete.cursor);
    for (members[0..3]) |member| try std.testing.expect(member.hp < 9999);
}

test "Whip Wolf actor binding versions and independent-library checkpoint retain command identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const other = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    const effects = try scenes(alloc);
    var older = actors;
    older.schema = "suikoden-unite-actors/36";
    try std.testing.expectError(error.InvalidUniteBindings, older.validate());
    var old_data = data;
    old_data.schema = "suikoden-battle-trial/39";
    try std.testing.expectError(error.UnsupportedEnemyPresentation, old_data.validate());
    var prior = actors;
    prior.schema = "suikoden-unite-actors/36";
    prior.group_orders = null;
    prior.enemy_wave = null;
    prior.enemy_area_magic = null;
    prior.enemy_regional = null;
    const prior_reactions = try alloc.dupe(@TypeOf(actors.counter.?.melee.?.party_reactions[0]), actors.counter.?.melee.?.party_reactions);
    for (prior_reactions) |*reaction| reaction.return_program = null;
    prior.counter.?.melee.?.party_reactions = prior_reactions;
    const prior_bytes = try std.json.Stringify.valueAlloc(alloc, prior, .{});
    try std.testing.expect(std.mem.indexOf(u8, prior_bytes, "\"group_orders\"") == null);
    const roundtrip = try host.loadBundle(alloc, try std.json.Stringify.valueAlloc(alloc, actors, .{}));
    try std.testing.expect(roundtrip.value.commanderFor("whip_wolf").?.solo_program == null);
    var invalid = actors;
    const orders = try alloc.dupe(battle.commander.Binding, actors.group_orders.?);
    invalid.group_orders = orders;
    orders[0].selection_delay = 61;
    try std.testing.expectError(error.InvalidEnemyOrderBinding, invalid.validate());
    orders[0] = actors.group_orders.?[0];
    orders[0].recipient_program = orders[0].order_program;
    try std.testing.expectError(error.InvalidEnemyOrderBinding, invalid.validate());
    var members: [6]battle.Member = undefined;
    var missing = try battle.State.init(data, items.value, &members, 1234);
    try std.testing.expectError(error.MissingEnemyOrderBinding, missing.attachUniteActors(&prior));
    try std.testing.expect(missing.unite_actors == null);
    for ([_]u32{ 0, 24, 100 }) |at| {
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        prepare(&state, &members);
        for (state.partyCount()..state.partyCount() + 3) |ally| state.acted[ally] = false;
        const owner = state.partyCount() + 3;
        try std.testing.expectError(error.InvalidActorBinding, state.beginSourceCommander(owner, 0));
        try state.beginSourceCommander(owner, null);
        const values: [128]u15 = @splat(0);
        var draws = battle.systems.Draws{ .values = &values };
        for (0..at) |_| try state.tickReplay(.{}, &draws);
        const bytes = try std.json.Stringify.valueAlloc(alloc, state.unite_vm, .{});
        var decoded = try std.json.parseFromSlice(battle.unite_playback.State, alloc, bytes, .{});
        try decoded.value.rebind(&other);
        state.unite_vm = decoded.value;
        state.unite_actors = &other;
        try std.testing.expectEqualStrings("whip_wolf", state.unite_vm.commander_actions[owner].?.id);
        for (0..600) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(state.active == null and !state.unite_vm.hasActors());
        for (members[0..3]) |member| try std.testing.expect(member.hp < 9999);
    }
}
