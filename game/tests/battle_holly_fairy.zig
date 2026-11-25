const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const host = battle.actor_host;

fn library(alloc: std.mem.Allocator) !host.Bundle {
    return (try host.loadBundle(alloc, @embedFile("fixtures/journey_unites_actor_library.json"))).value;
}

fn content(alloc: std.mem.Allocator, rear: bool) !battle.Content {
    var result = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const ivy = for (result.enemies) |enemy| {
        if (std.mem.eql(u8, enemy.id, "mad_ivy")) break enemy;
    } else return error.MissingIvy;
    // Synthetic diagnostic row and balance, not a newly admitted source formation.
    const enemies = try alloc.alloc(battle.Profile, 2);
    enemies[0] = ivy;
    enemies[1] = ivy;
    enemies[1].id = "holly_fairy";
    enemies[1].name = "Holly Fairy";
    enemies[1].action_policy = .source_holly_fairy;
    enemies[1].target_policy = .front_first;
    result.enemies = enemies;
    const entries = try alloc.dupe(battle.Encounter, result.encounters[0..1]);
    entries[0].enemies = &.{ "mad_ivy", "mad_ivy", "holly_fairy" };
    entries[0].positions = &.{ .{ .x = 60, .y = 0, .z = 0 }, .{ .x = 60, .y = 0, .z = 60 }, .{ .x = 100, .y = 0, .z = 30 } };
    entries[0].source_slots = &.{ 0, 1, 3 };
    entries[0].enemy_rows = if (rear) &.{ .front, .front, .back } else &.{ .front, .front, .front };
    result.encounters = entries;
    result.presentation_ready = false;
    result.schema = "suikoden-battle-trial/41";
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

test "Holly Fairy actor source admission completes healthy protected and Turtle D rounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const base = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const effects = try scenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var cases: usize = 0;
    for (base.encounters, 0..) |entry, index| {
        if (!std.mem.startsWith(u8, entry.id, "area_d_")) continue;
        for (0..3) |mode| {
            var data = base;
            data.encounters = data.encounters[index..][0..1];
            var members: [6]battle.Member = undefined;
            var state = try battle.State.init(data, items.value, &members, 1234);
            try state.attachUniteActors(&actors);
            try state.attachSpellScenes(&effects);
            prepare(&state, &members);
            for (state.partyCount()..state.partyCount() + state.enemyCount()) |actor| state.acted[actor] = false;
            state.coordinator.?.current_actor = state.partyCount();
            if (mode == 1) for (0..state.partyCount()) |actor| {
                state.actor_conditions[actor].protection_rounds = 2;
            };
            if (mode == 2) for (0..state.partyCount()) |actor| {
                state.runes[actor] = data.systems.?.runeIndex("turtle").?;
            };
            const values: [2048]u15 = @splat(51);
            var draws = battle.systems.Draws{ .values = &values };
            var saw_body = false;
            for (0..2400) |_| {
                state.tickReplay(.{}, &draws) catch |err| {
                    std.debug.print("D {s} mode{} at{}: {s}\n", .{ entry.id, mode, state.camera_ticks, @errorName(err) });
                    return err;
                };
                for (state.partyCount()..state.partyCount() + state.enemyCount()) |actor| if (state.unite_vm.scripted_actors[actor] != null) {
                    try std.testing.expect(state.physicalRunePose(actor) != null);
                    saw_body = true;
                };
                if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
            }
            try std.testing.expect(saw_body);
            try std.testing.expect(state.round == 2 and state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
            if (mode == 1) for (members) |member| {
                try std.testing.expectEqual(@as(u16, 9999), member.hp);
            };
            if (mode == 2) for (members) |member| {
                try std.testing.expectEqual(@as(u8, 0), member.balloons);
            };
            cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 36), cases);
}

test "Holly Fairy actor source body receives ordinary critical parry lethal and counter contacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    var data = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const index = for (data.encounters, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "area_d_2")) break i;
    } else return error.MissingHollyFormation;
    data.encounters = data.encounters[index..][0..1];
    const effects = try scenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for (0..5) |mode| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        prepare(&state, &members);
        state.phase = .battle_menu;
        state.coordinator = null;
        const target = state.partyCount() + 1;
        state.enemy_hp[1] = if (mode == 3) 1 else 9999;
        if (mode == 2) {
            try std.testing.expect(try state.parryAvailable(0, target));
            try state.beginParry(0, target);
        } else if (mode == 4) {
            try state.beginCounter(target, 0);
        } else try state.beginPartyMelee(0, target, true, mode == 1);
        const values: [16]u15 = @splat(0);
        var draws = battle.systems.Draws{ .values = &values };
        var saw_body = false;
        for (0..900) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.unite_vm.scripted_actors[target] != null) {
                try std.testing.expect(state.physicalRunePose(target) != null);
                saw_body = true;
            }
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(saw_body and state.active == null and !state.unite_vm.hasActors());
        if (mode == 2) {
            try std.testing.expectEqual(@as(u16, 9999), state.enemy_hp[1]);
            try std.testing.expect(members[0].hp < 9999);
            try std.testing.expectEqual(@as(u8, 1), members[0].balloons);
        } else if (mode == 3) {
            try std.testing.expectEqual(@as(u16, 0), state.enemy_hp[1]);
        } else try std.testing.expect(state.enemy_hp[1] < 9999);
    }
}

test "Holly Fairy actor source admission refuses missing body art before custody" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    const graphics = try alloc.dupe(battle.UniteGraphic, data.unite_graphics);
    for (graphics) |*graphic| if (std.mem.eql(u8, graphic.id, "holly_fairy")) {
        graphic.poses = &.{};
    };
    state.content.unite_graphics = graphics;
    try std.testing.expectError(error.MissingPhysicalArt, state.attachUniteActors(&actors));
    try std.testing.expect(state.unite_actors == null and !state.unite_vm.hasActors());
}

test "Holly Fairy actor source rewards collect and serialize its named unappraisable urn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const index = for (data.encounters, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "area_d_1")) break i;
    } else return error.MissingHollyFormation;
    data.encounters = data.encounters[index..][0..1];
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    const values: [4096]u15 = @splat(0);
    var draws = battle.systems.Draws{ .values = &values };
    state.replay_draws = &draws;
    state.commitRewards();
    state.replay_draws = null;
    try std.testing.expect(!state.replay_exhausted and state.drop_received);
    try std.testing.expectEqual(field.items.Id.nameless_urn, state.dropped_item.?.id);
    try std.testing.expect(state.dropped_item.?.identified);
    try std.testing.expectEqualStrings("Nameless urn", state.dropped_item.?.name());
    try std.testing.expect(!state.dropped_item.?.id.decoration());
    try std.testing.expect(items.value.good(.nameless_urn) == null);
    const owner = state.loot_recipient.?;
    try state.progress.party[owner].inventory.validate();
    const bytes = try std.json.Stringify.valueAlloc(alloc, state.progress.party[owner].inventory, .{});
    const decoded = try std.json.parseFromSlice(field.items.Inventory, alloc, bytes, .{});
    try decoded.value.validate();
    try std.testing.expectEqualDeep(state.progress.party[owner].inventory, decoded.value);
}

test "Holly Fairy actor source wave delegates front Holly allies with their own balloon recipients" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    var data = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const index = for (data.encounters, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "area_d_3")) break i;
    } else return error.MissingHollyFormation;
    const entries = try alloc.dupe(battle.Encounter, data.encounters[index..][0..1]);
    // Source D3 is all front; this row override is an explicit rear-wave diagnostic.
    entries[0].enemy_rows = &.{ .front, .front, .back };
    data.encounters = entries;
    const effects = try scenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    try state.attachSpellScenes(&effects);
    prepare(&state, &members);
    state.acted[state.partyCount()] = false;
    state.acted[state.partyCount() + 1] = false;
    state.sourceEnemyDecision(state.partyCount() + 2);
    const values: [256]u15 = @splat(51);
    var draws = battle.systems.Draws{ .values = &values };
    for (0..1000) |_| {
        try state.tickReplay(.{}, &draws);
        if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
    }
    try std.testing.expect(state.round == 2 and state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
    for (members[0..2]) |member| {
        try std.testing.expect(member.hp < 9999);
        try std.testing.expectEqual(@as(u8, 1), member.balloons);
    }
}

fn prepare(state: *battle.State, members: []battle.Member) void {
    for (members, 0..) |*member, actor| {
        member.hp = 9999;
        member.max_hp = 9999;
        member.status = .healthy;
        state.actions[actor] = .defend;
    }
    state.acted = @splat(true);
    state.phase = .resolving;
    state.coordinator = .{ .stage = .dispatch, .current_actor = state.partyCount() + 2 };
}

test "Holly Fairy live actor front scan consumes rejected and empty scans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, false);
    const items = try field.items.load(alloc, field.items.json);
    for ([_]bool{ false, true }) |empty| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        prepare(&state, &members);
        const owner = state.partyCount() + 2;
        state.acted[owner] = false;
        if (empty) for (0..state.partyCount()) |i| {
            state.departed[i] = true;
        };
        const values: [16]u15 = @splat(0);
        var draws = battle.systems.Draws{ .values = &values };
        state.replay_draws = &draws;
        state.sourceEnemyDecision(owner);
        state.replay_draws = null;
        try std.testing.expect(state.acted[owner] and state.pending_enemy_actor == null and state.active == null);
        try std.testing.expect(state.replay_unsupported == null and !state.replay_exhausted);
        try std.testing.expect(state.coordinator.?.completed and state.coordinator.?.stage == .select);
        try std.testing.expectEqual(@as(usize, if (empty) 0 else 3), draws.cursor);
    }
}

test "Holly Fairy live actor rear wave delegates ordinary AI and completes a source-scheduled round" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    prepare(&state, &members);
    const owner = state.partyCount() + 2;
    state.acted[state.partyCount()] = false;
    state.acted[state.partyCount() + 1] = false;
    state.sourceEnemyDecision(owner);
    try std.testing.expect(state.replay_unsupported == null and state.unite_vm.hasEnemyWave());
    const values: [256]u15 = @splat(51);
    var draws = battle.systems.Draws{ .values = &values };
    var launched: [2]?u32 = @splat(null);
    var saw_completion = false;
    for (0..800) |_| {
        state.tickReplay(.{}, &draws) catch |err| {
            std.debug.print("Holly wave tick{}: {s}\n", .{ state.camera_ticks, @errorName(err) });
            return err;
        };
        for (0..2) |i| if (state.unite_vm.counter_actions[i]) |action| {
            if (launched[i] == null) launched[i] = action.start_at;
        };
        if (state.camera_ticks == 153) {
            saw_completion = true;
            try std.testing.expectEqual(@as(i32, 30), state.coordinator.?.remaining);
            try std.testing.expect(state.coordinator.?.completed and state.coordinator.?.stage == .select);
            try std.testing.expect(state.unite_vm.wave_actions[owner] == null and state.unite_vm.scripted_actors[owner] == null);
        }
        if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
    }
    try std.testing.expectEqual(@as(u32, 31), launched[0].?);
    try std.testing.expectEqual(@as(u32, 32), launched[1].?);
    try std.testing.expect(saw_completion);
    try std.testing.expect(members[0].hp < 9999 and members[1].hp < 9999);
    try std.testing.expectEqual(@as(u32, 2), state.round);
    try std.testing.expect(state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
}

test "Holly Fairy live actor source versions refuse before actor-library custody" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    var older = actors;
    older.schema = "suikoden-unite-actors/37";
    try std.testing.expectError(error.InvalidUniteBindings, older.validate());
    var data = try content(alloc, true);
    data.schema = "suikoden-battle-trial/40";
    try std.testing.expectError(error.UnsupportedEnemyPresentation, data.validate());
    data.schema = "suikoden-battle-trial/41";
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    var missing = actors;
    missing.schema = "suikoden-unite-actors/37";
    missing.enemy_wave = null;
    missing.enemy_area_magic = null;
    missing.enemy_regional = null;
    const missing_reactions = try alloc.dupe(@TypeOf(actors.counter.?.melee.?.party_reactions[0]), actors.counter.?.melee.?.party_reactions);
    for (missing_reactions) |*reaction| reaction.return_program = null;
    missing.counter.?.melee.?.party_reactions = missing_reactions;
    try std.testing.expectError(error.MissingEnemyWaveBinding, state.attachUniteActors(&missing));
    try std.testing.expect(state.unite_actors == null and !state.unite_vm.hasActors());
    missing = actors;
    const programs = try alloc.alloc(battle.actor_program.Program, actors.programs.programs.len - 1);
    var count: usize = 0;
    for (actors.programs.programs) |program| {
        if (std.mem.eql(u8, program.id, "melee/holly_fairy/idle")) continue;
        programs[count] = program;
        count += 1;
    }
    missing.programs.programs = programs;
    try std.testing.expectError(error.MissingEnemyIdleBinding, state.attachUniteActors(&missing));
    try std.testing.expect(state.unite_actors == null and !state.unite_vm.hasActors());
}

test "Holly Fairy live actor front attack runs its source balloon recipient through the round" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, false);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    prepare(&state, &members);
    const owner = state.partyCount() + 2;
    state.acted[owner] = false;
    var values: [128]u15 = @splat(0);
    values[0] = 51;
    var draws = battle.systems.Draws{ .values = &values };
    for (0..800) |_| {
        try state.tickReplay(.{}, &draws);
        if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
    }
    try std.testing.expect(members[0].hp < 9999);
    try std.testing.expectEqual(@as(u8, 1), members[0].balloons);
    try std.testing.expectEqual(@as(u32, 2), state.round);
    try std.testing.expect(state.phase == .battle_menu and state.active == null and !state.unite_vm.hasActors());
}

test "Holly Fairy live actor delegation rolls back complete ticks on exhausted target or accuracy draws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    prepare(&state, &members);
    const owner = state.partyCount() + 2;
    state.acted[state.partyCount()] = false;
    state.acted[state.partyCount() + 1] = false;
    state.sourceEnemyDecision(owner);
    var empty = battle.systems.Draws{ .values = &.{} };
    for (0..30) |_| try state.tickReplay(.{}, &empty);
    const before = state;
    const saved_members = members;
    for ([_][]const u15{ &.{}, &.{51}, &.{ 0, 0, 0, 51 } }) |values| {
        var exhausted = battle.systems.Draws{ .values = values };
        try std.testing.expectError(error.RandomInputExhausted, state.tickReplay(.{}, &exhausted));
        try std.testing.expectEqual(before.camera_ticks, state.camera_ticks);
        try std.testing.expectEqualDeep(before.unite_vm, state.unite_vm);
        try std.testing.expectEqualDeep(before.coordinator, state.coordinator);
        try std.testing.expectEqualDeep(before.acted, state.acted);
        try std.testing.expectEqualDeep(before.random, state.random);
        try std.testing.expectEqualDeep(saved_members, members);
        try std.testing.expectEqual(@as(usize, 0), exhausted.cursor);
    }
    var complete = battle.systems.Draws{ .values = &.{ 51, 0 } };
    try state.tickReplay(.{}, &complete);
    try std.testing.expectEqual(@as(usize, 2), complete.cursor);
    try std.testing.expect(state.acted[state.partyCount()] and !state.acted[state.partyCount() + 1]);
    try std.testing.expectEqual(@as(u32, 31), state.unite_vm.counter_actions[0].?.start_at);
}

test "Holly Fairy live actor wave checkpoints rebind independently owned libraries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const other = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    for ([_]usize{ 0, 30, 31, 152 }) |at| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        prepare(&state, &members);
        const owner = state.partyCount() + 2;
        state.acted[state.partyCount()] = false;
        state.acted[state.partyCount() + 1] = false;
        state.sourceEnemyDecision(owner);
        const values: [256]u15 = @splat(51);
        var draws = battle.systems.Draws{ .values = &values };
        for (0..at) |_| try state.tickReplay(.{}, &draws);
        const bytes = try std.json.Stringify.valueAlloc(alloc, state.unite_vm, .{});
        var decoded = (try std.json.parseFromSlice(battle.unite_playback.State, alloc, bytes, .{})).value;
        try decoded.rebind(&other);
        state.unite_vm = decoded;
        state.unite_actors = &other;
        for (0..800) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(members[0].hp < 9999 and members[1].hp < 9999);
        try std.testing.expect(state.phase == .battle_menu and state.round == 2 and state.active == null and !state.unite_vm.hasActors());
    }
}

test "Holly Fairy live actor refuses unqualified delegated decisions transactionally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    var data = try content(alloc, true);
    const enemies = try alloc.dupe(battle.Profile, data.enemies);
    enemies[0].action_policy = .unsupported;
    data.enemies = enemies;
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    prepare(&state, &members);
    const owner = state.partyCount() + 2;
    state.acted[state.partyCount()] = false;
    state.sourceEnemyDecision(owner);
    var draws = battle.systems.Draws{ .values = &.{} };
    for (0..30) |_| try state.tickReplay(.{}, &draws);
    const before = state.unite_vm;
    try std.testing.expectError(error.UnsupportedCoordinatorAction, state.tickReplay(.{}, &draws));
    try std.testing.expectEqual(@as(u32, 30), state.camera_ticks);
    try std.testing.expectEqualDeep(before, state.unite_vm);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try std.testing.expect(!state.acted[state.partyCount()]);
}

test "Holly Fairy live idle keeps source Q12 bob and renderer clocks without owning rounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    state.phase = .battle_menu;
    const owner = state.partyCount() + 2;
    const origin = state.uniteVmHome(owner);
    const origin_q12: [3]i32 = .{ @intFromFloat(origin.x * 4096), @intFromFloat(origin.y * 4096), @intFromFloat(origin.z * 4096) };
    var draws = battle.systems.Draws{ .values = &.{} };
    for (1..186) |update| {
        try state.tickReplay(.{}, &draws);
        const phase: i32 = @intCast((update - 1) % 61);
        const delta: i32 = if (phase < 30) -1365 * phase else if (phase == 30) -40960 else if (phase < 60) -40960 + 1365 * (phase - 30) else 0;
        const actor = state.unite_vm.actors[owner];
        try std.testing.expectEqual(origin_q12[2] + delta, actor.position_q12[2]);
        try std.testing.expectEqualDeep(origin_q12[0..2], actor.position_q12[0..2]);
        try std.testing.expect(state.uniteVmPose(owner) != null);
        try std.testing.expectEqual(@as(f32, @floatFromInt(actor.position_q12[2] >> 12)), battle.layout.worldPosition(&state, owner).z);
        try std.testing.expect(state.unite_vm.hasIdle() and !state.unite_vm.hasActors() and !state.hasUniteReturns());
        try std.testing.expect(!state.unite_vm.ownsActor(owner) and !state.coordinatorLocked(owner));
        try std.testing.expect(state.active == null and state.phase == .battle_menu);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    }
}

test "Holly Fairy live idle hands pending bob to wave and returns without a round lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    for ([_]usize{ 2, 15, 31, 45, 61 }) |phase| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        state.phase = .battle_menu;
        var draws = battle.systems.Draws{ .values = &.{} };
        for (0..phase) |_| try state.tickReplay(.{}, &draws);
        const owner = state.partyCount() + 2;
        const old = state.unite_vm.actors[owner];
        const pending: u32 = if (old.movement) |move| move.remaining else 0;
        const destination = if (old.movement) |move| move.destination else old.position_q12;
        prepare(&state, &members);
        state.sourceEnemyDecision(owner);
        var completed: ?u32 = null;
        for (1..701) |update| {
            try state.tickReplay(.{}, &draws);
            if (completed == null and state.coordinator != null and state.coordinator.?.completed and state.active == null) {
                completed = @intCast(update);
                try std.testing.expectEqual(@as(u16, 30), state.coordinator.?.remaining);
                // Idle has restarted after the wave's halt; its next leg starts at the retained destination.
                const current = state.unite_vm.actors[owner];
                try std.testing.expect(current.position_q12[2] <= destination[2]);
            }
            if (state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(u32, 153) + pending, completed.?);
        try std.testing.expect(state.round == 2 and state.phase == .battle_menu and !state.unite_vm.hasActors());
        try std.testing.expect(state.unite_vm.idle[owner] != null);
    }
}

test "Holly Fairy live idle checkpoints resume through signed residue and restart boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const replacement = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    for ([_]usize{ 2, 15, 30, 31, 60, 61, 62 }) |at| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        state.phase = .battle_menu;
        var draws = battle.systems.Draws{ .values = &.{} };
        for (0..at) |_| try state.tickReplay(.{}, &draws);
        var restored = state;
        var restored_members = members;
        restored.progress.party = &restored_members;
        const bytes = try std.json.Stringify.valueAlloc(alloc, state.unite_vm, .{});
        restored.unite_vm = (try std.json.parseFromSlice(battle.unite_playback.State, alloc, bytes, .{})).value;
        try restored.unite_vm.rebind(&replacement);
        restored.unite_actors = &replacement;
        for (0..125) |_| {
            try state.tickReplay(.{}, &draws);
            try restored.tickReplay(.{}, &draws);
            const owner = state.partyCount() + 2;
            try std.testing.expectEqualDeep(state.unite_vm.actors[owner], restored.unite_vm.actors[owner]);
            try std.testing.expectEqualDeep(state.unite_vm.idle[owner], restored.unite_vm.idle[owner]);
        }
    }
}

test "Holly Fairy live idle preserves incoming raw motion through hurt counter parry and KO" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const effects = try scenes(alloc);
    var data = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    const index = for (data.encounters, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, "area_d_2")) break i;
    } else return error.MissingHollyFormation;
    data.encounters = data.encounters[index..][0..1];
    const items = try field.items.load(alloc, field.items.json);
    for (0..5) |mode| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(data, items.value, &members, 1234);
        try state.attachUniteActors(&actors);
        try state.attachSpellScenes(&effects);
        prepare(&state, &members);
        state.phase = .battle_menu;
        state.coordinator = null;
        var empty = battle.systems.Draws{ .values = &.{} };
        for (0..15) |_| try state.tickReplay(.{}, &empty);
        const target = state.partyCount() + 1;
        const before = state.unite_vm.actors[target];
        try std.testing.expect(before.movement != null and before.position_q12[2] & 4095 != 0);
        state.enemy_hp[1] = if (mode == 3) 1 else 9999;
        if (mode == 2) {
            try state.beginParry(0, target);
        } else if (mode == 4) {
            try state.beginCounter(target, 0);
        } else try state.beginPartyMelee(0, target, true, mode == 1);
        const values: [64]u15 = @splat(0);
        var draws = battle.systems.Draws{ .values = &values };
        try state.tickReplay(.{}, &draws);
        const after = state.unite_vm.actors[target];
        // Preparation must not round to rendered integer coordinates or discard the pending leg.
        try std.testing.expectEqual(before.position_q12[2] + before.velocity_q12[2], after.position_q12[2]);
        try std.testing.expect(after.movement != null);
        for (0..900) |_| {
            try state.tickReplay(.{}, &draws);
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(state.active == null and !state.unite_vm.hasActors());
        try state.tickReplay(.{}, &draws);
        if (mode == 3) {
            try std.testing.expect(state.enemy_hp[1] == 0 and state.unite_vm.idle[target] == null);
        } else {
            try std.testing.expect(state.unite_vm.idle[target] != null and state.uniteVmPose(target) != null);
            try std.testing.expect(!state.coordinatorLocked(target));
        }
    }
}

test "Holly Fairy live idle checkpoint refuses changed program resource pose and cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    state.phase = .battle_menu;
    var draws = battle.systems.Draws{ .values = &.{} };
    for (0..15) |_| try state.tickReplay(.{}, &draws);
    const owner = state.partyCount() + 2;
    var wrong = state.unite_vm;
    wrong.idle[owner].?.machine.?.actor = 0;
    try std.testing.expectError(error.InvalidActorPlayback, wrong.rebind(&actors));
    wrong = state.unite_vm;
    wrong.idle[owner].?.machine.?.pc = 9999;
    try std.testing.expectError(error.InvalidActorPlayback, wrong.rebind(&actors));
    wrong = state.unite_vm;
    wrong.actors[owner].animation = 9999;
    try std.testing.expectError(error.InvalidActorPlayback, wrong.rebind(&actors));
    wrong = state.unite_vm;
    wrong.actors[owner].resource = null;
    try std.testing.expectError(error.InvalidActorPlayback, wrong.rebind(&actors));
    var missing = actors;
    missing.programs.programs = &.{};
    wrong = state.unite_vm;
    try std.testing.expectError(error.InvalidActorPlayback, wrong.rebind(&missing));
}

test "Holly Fairy live idle renderer yields to explicit spell and Unite motion tracks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const actors = try library(alloc);
    const effects = try scenes(alloc);
    const data = try content(alloc, true);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(data, items.value, &members, 1234);
    try state.attachUniteActors(&actors);
    try state.attachSpellScenes(&effects);
    state.phase = .battle_menu;
    var empty = battle.systems.Draws{ .values = &.{} };
    for (0..15) |_| try state.tickReplay(.{}, &empty);
    const target = state.partyCount() + 2;
    const origin = state.unite_vm.actors[target].position_q12;
    // Diagnostic transform attachment: normal Voice of Earth correctly excludes airborne Holly Fairy.
    const scene = effects.indexOf("spell_22").?;
    var draws = battle.systems.Draws{ .bios_state = 1234 };
    var instance = try battle.spell_scene.Instance.begin(&effects, scene, .{ 0, 0, 0 }, origin, battle.layout.currentCamera(state), &draws);
    instance.target_count = 1;
    instance.targets[0] = .{ .actor = target, .position = origin, .home = origin, .motion_origin = origin, .return_origin = .{ -120 * 4096, 0, 0 } };
    state.active = .{ .actor = 0, .target = target, .kind = .cast, .scene = instance };
    state.action_ticks = 176;
    const spell_position = state.spellActorPosition(target).?;
    try std.testing.expectEqualDeep(spell_position, battle.layout.worldPosition(&state, target));
    state.camera_ticks += 1;
    state.advanceEnemyIdle();
    const spell_transform = (try battle.spell_scene.actorTransform(effects.spells[scene].program.?, instance.targets[0], 176)).?;
    try std.testing.expectEqualDeep(spell_transform.position, state.unite_vm.actors[target].position_q12);
    try std.testing.expect(state.unite_vm.idle[target].?.machine == null and state.unite_vm.actors[target].movement == null);
    state.active = null;
    const reaction = for (effects.unite_reactions) |entry| {
        if (entry.blocker == null and entry.motions.len != 0) break entry;
    } else return error.MissingReactionMotion;
    state.unite_reactions[target] = .{ .record = reaction.record, .variant = reaction.variant, .started_at = state.camera_ticks, .origin_q12 = origin, .home_q12 = origin };
    state.camera_ticks += @max(@as(u32, 1), reaction.motions[0].at);
    const position = battle.spell_scene.unitePosition(reaction, origin, origin, state.camera_ticks - state.unite_reactions[target].?.started_at);
    const expected = battle.Position{ .x = @floatFromInt(position[0] >> 12), .y = @floatFromInt(position[1] >> 12), .z = @floatFromInt(position[2] >> 12) };
    try std.testing.expectEqualDeep(expected, battle.layout.worldPosition(&state, target));
    const previous = battle.spell_scene.unitePosition(reaction, origin, origin, state.camera_ticks - state.unite_reactions[target].?.started_at - 1);
    try std.testing.expectEqualDeep(previous, state.uniteReactionOriginQ12(target));
    state.advanceEnemyIdle();
    try std.testing.expectEqualDeep(position, state.unite_vm.actors[target].position_q12);
    state.camera_ticks = state.unite_reactions[target].?.started_at + reaction.duration;
    state.advanceEnemyIdle();
    const destination = battle.spell_scene.unitePosition(reaction, origin, origin, reaction.duration);
    try std.testing.expectEqualDeep(destination, state.unite_vm.actors[target].position_q12);
    try std.testing.expect(state.unite_vm.idle[target].?.machine != null);
    try std.testing.expectEqualDeep(destination, state.uniteReactionOriginQ12(target));
}
