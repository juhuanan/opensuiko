const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const world = @import("world");
const overlay = @import("world_battle");
const allocator = std.testing.allocator;

fn commanderActors(alloc: std.mem.Allocator) !battle.actor_host.Bundle {
    return (try battle.actor_host.loadBundle(alloc, @embedFile("fixtures/journey_unites_actor_library.json"))).value;
}

test "Commander source admission validates art and plays normal solo and formation orders" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const parsed = try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"));
    const library = try commanderActors(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var scenes = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/spell_scene_library.json"), .{});
    const patch = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/journey_unite_scenes_patch.json"), .{});
    var fields = patch.value.object.iterator();
    while (fields.next()) |entry| try scenes.value.object.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    const scene_bytes = try std.json.Stringify.valueAlloc(alloc, scenes.value, .{});
    const effects = try battle.spell_scene.load(alloc, scene_bytes);
    var content = parsed.value;
    const encounter = for (content.encounters, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id, "area_b_1")) break index;
    } else return error.MissingCommanderFormation;
    content.encounters = content.encounters[encounter..][0..1];
    for ([_]bool{ false, true }) |group| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content, items.value, &members, 1234);
        try state.attachUniteActors(&library);
        try state.attachSpellScenes(&effects.value);
        state.phase = .battle_menu;
        state.acted = @splat(true);
        for (&members) |*member| {
            member.hp = 9999;
            member.max_hp = 9999;
        }
        if (group) for (0..3) |ally| {
            state.acted[state.partyCount() + ally] = false;
        };
        const owner = state.partyCount() + 3;
        try state.beginSourceCommander(owner, if (group) null else 0);
        const values: [32]u15 = @splat(0);
        var draws = battle.systems.Draws{ .values = &values };
        for (1..211) |update| state.tickReplay(.{}, &draws) catch |failure| {
            std.debug.print("Commander admission group={} update={}: {s}\n", .{ group, update, @errorName(failure) });
            return failure;
        };
        try std.testing.expect(!state.unite_vm.hasActors());
        if (group) {
            for (members[0..3]) |member| try std.testing.expect(member.hp < 9999);
        } else {
            try std.testing.expect(state.actor_conditions[0].sleep_turns > 0);
            try std.testing.expectEqual(@as(u16, 9999), members[0].hp);
        }
    }
    var older = content;
    older.schema = "suikoden-battle-trial/35";
    try std.testing.expectError(error.UnsupportedEnemyPresentation, older.validate());
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content, items.value, &members, 1234);
    state.commanderDecision(state.partyCount() + 3);
    try std.testing.expectEqual(.enemy_policy, state.replay_unsupported.?);
    var missing = library;
    missing.schema = "suikoden-unite-actors/31";
    missing.group_orders = null;
    missing.enemy_wave = null;
    missing.enemy_area_magic = null;
    missing.enemy_regional = null;
    const reactions = try alloc.dupe(battle.counter.PartyReaction, library.counter.?.melee.?.party_reactions);
    for (reactions) |*reaction| reaction.return_program = null;
    missing.counter.?.melee.?.party_reactions = reactions;
    missing.commander = null;
    var older_melee: std.ArrayList(battle.counter.MeleeEnemy) = .empty;
    for (library.counter.?.melee.?.enemies) |enemy| if (enemy.projectile == null and (enemy.special == null or enemy.special.?.return_program == null)) try older_melee.append(alloc, enemy);
    missing.counter.?.melee.?.enemies = older_melee.items;
    try std.testing.expectError(error.MissingEnemyOrderBinding, state.attachUniteActors(&missing));
    try std.testing.expect(state.unite_actors == null);
    const graphics = try alloc.dupe(battle.UniteGraphic, content.unite_graphics);
    const child_pose = library.animations.find("beast_commander").?.find(19).?.frames[0].pose;
    for (graphics) |*graphic| if (std.mem.eql(u8, graphic.id, "beast_commander")) {
        const poses = try alloc.dupe(battle.UniteGraphicPose, graphic.poses);
        for (poses) |*pose| if (pose.id == child_pose) {
            pose.id = 65535;
        };
        graphic.poses = poses;
    };
    state.content.unite_graphics = graphics;
    try std.testing.expectError(error.MissingPhysicalArt, state.attachUniteActors(&library));
    try std.testing.expect(state.unite_actors == null and !state.unite_vm.hasActors());
}

test "Commander live bridge completes its original three Squirrel formation through the round coordinator" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_battle.json"));
    const map = try world.load(alloc, world.json);
    const data = try overlay.load(alloc, overlay.json);
    const items = try field.items.load(alloc, field.items.json);
    var content = try data.value.view(map.value, base.value);
    const enemies = try alloc.dupe(battle.Profile, content.enemies);
    content.enemies = enemies;
    for (enemies) |*enemy| if (std.mem.eql(u8, enemy.id, "flying_squirrel")) {
        enemy.action_policy = .source_melee;
        enemy.ordered_attack = null;
    };
    const library = try commanderActors(alloc);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content, items.value, &members, 1234);
    try state.attachUniteActors(&library);
    const owner = state.partyCount() + 3;
    for (&members, 0..) |*member, index| {
        member.hp = 9999;
        member.max_hp = 9999;
        state.progress.party.at(index).base_stats.speed = 1;
        state.actions[index] = .defend;
    }
    state.phase = .resolving;
    state.coordinator = .{ .stage = .dispatch, .current_actor = owner };
    const values: [8192]u15 = @splat(255);
    var draws = battle.systems.Draws{ .values = &values };
    var launched = false;
    for (0..600) |_| {
        try state.tickReplay(.{}, &draws);
        if (state.unite_vm.commander_actions[owner]) |playback| if (playback.ordered_at) |at| {
            try std.testing.expectEqual(@as(u32, 12), at - playback.start_at + 1);
            launched = true;
        };
        if (state.round >= 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
    }
    try std.testing.expect(launched);
    try std.testing.expectEqual(@as(u32, 2), state.round);
    try std.testing.expectEqual(.battle_menu, state.phase);
    try std.testing.expect(!state.unite_vm.hasActors() and state.active == null);
    for (0..3) |index| {
        try std.testing.expect(members[index].hp > 0 and members[index].hp < 9999);
        try std.testing.expect(state.actor_conditions[index].accuracy_reduced);
    }
    for (3..6) |index| try std.testing.expectEqual(@as(u16, 9999), members[index].hp);
    try std.testing.expectEqual(@as(u32, 350), state.progress.money);
}

test "Commander live bridge retains protected defended Turtle and lethal recipient rules" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_battle.json"));
    const map = try world.load(alloc, world.json);
    const data = try overlay.load(alloc, overlay.json);
    const items = try field.items.load(alloc, field.items.json);
    const content = try data.value.view(map.value, base.value);
    const library = try commanderActors(alloc);
    for ([_]bool{ false, true }) |lethal| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content, items.value, &members, 1234);
        try state.attachUniteActors(&library);
        state.phase = .battle_menu;
        state.acted = @splat(true);
        for (0..3) |ally| state.acted[state.partyCount() + ally] = false;
        for (&members) |*member| {
            member.hp = if (lethal) 1 else 9999;
            member.max_hp = 9999;
        }
        state.actor_conditions[0].protection_rounds = 2;
        state.actions[1] = .defend;
        state.progress.party.at(2).rune = state.content.systems.?.runeIndex("turtle").?;
        const damage = state.resolvePhysicalDamage(state.partyCount() + 1, 1, 0, true);
        try state.beginSourceCommander(state.partyCount() + 3, null);
        const values: [8]u15 = @splat(0);
        var draws = battle.systems.Draws{ .values = &values };
        for (1..211) |update| {
            try state.tickReplay(.{}, &draws);
            if (update == 119) {
                try std.testing.expect(state.actor_conditions[0].accuracy_reduced and state.actor_conditions[1].accuracy_reduced);
                try std.testing.expect(!state.actor_conditions[2].accuracy_reduced);
            }
        }
        try std.testing.expectEqual(@as(u16, if (lethal) 1 else 9999), members[0].hp);
        try std.testing.expectEqual(@as(u16, @intCast((if (lethal) @as(u32, 1) else 9999) -| damage)), members[1].hp);
        try std.testing.expectEqual(@as(usize, 5), draws.cursor);
        if (lethal) {
            for (1..3) |target| {
                try std.testing.expectEqual(@as(u16, 0), members[target].hp);
                try std.testing.expectEqual(.unconscious, members[target].status);
                try std.testing.expect(!state.actor_conditions[target].accuracy_reduced and !state.party_knockouts[target].pending);
            }
        }
        try std.testing.expect(!state.unite_vm.hasActors());
    }
}

test "Commander live bridge rolls back all group contacts and status children on exhausted draws" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_battle.json"));
    const map = try world.load(alloc, world.json);
    const data = try overlay.load(alloc, overlay.json);
    const items = try field.items.load(alloc, field.items.json);
    const content = try data.value.view(map.value, base.value);
    const library = try commanderActors(alloc);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content, items.value, &members, 1234);
    try state.attachUniteActors(&library);
    state.phase = .battle_menu;
    state.acted = @splat(true);
    for (0..3) |ally| state.acted[state.partyCount() + ally] = false;
    for (&members) |*member| {
        member.hp = 9999;
        member.max_hp = 9999;
    }
    try state.beginSourceCommander(state.partyCount() + 3, null);
    const values: [8]u15 = @splat(0);
    var draws = battle.systems.Draws{ .values = &values };
    for ([_]u32{ 117, 119 }) |failure_at| {
        while (state.camera_ticks + 1 < failure_at) try state.tickReplay(.{}, &draws);
        const before = state;
        const before_members = members;
        var short = draws;
        short.values = values[0 .. draws.cursor + 1];
        const cursor = short.cursor;
        try std.testing.expectError(error.RandomInputExhausted, state.tickReplay(.{}, &short));
        try std.testing.expectEqual(cursor, short.cursor);
        try std.testing.expectEqual(before.camera_ticks, state.camera_ticks);
        try std.testing.expectEqualDeep(before.unite_vm, state.unite_vm);
        try std.testing.expectEqualDeep(before.active, state.active);
        try std.testing.expectEqualDeep(before.actor_conditions, state.actor_conditions);
        try std.testing.expectEqualDeep(before_members, members);
        try state.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqual(@as(usize, 6), draws.cursor);
}

test "Commander live bridge validates bundle versions and omits absent checkpoint state" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const library = try commanderActors(alloc);
    var invalid = library;
    invalid.schema = "suikoden-unite-actors/31";
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    invalid = library;
    invalid.commander = null;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    invalid = library;
    invalid.commander.?.recipient_program = "missing";
    try std.testing.expectError(error.InvalidEnemyOrderBinding, invalid.validate());
    const empty: battle.unite_playback.State = .{};
    const bytes = try std.json.Stringify.valueAlloc(alloc, empty, .{});
    try std.testing.expect(std.mem.indexOf(u8, bytes, "commander_actions") == null);
    const parsed = try std.json.parseFromSlice(battle.unite_playback.State, alloc, bytes, .{});
    try std.testing.expect(!parsed.value.hasCommander());
    var bad_playback: battle.unite_playback.State = .{};
    bad_playback.commander_actions[9] = .{ .owner = 10, .recipient = 0, .start_at = 0 };
    try std.testing.expectError(error.InvalidActorPlayback, bad_playback.rebind(&library));
}

test "Commander live bridge checkpoints rebind active child and ordered return actors to a new library" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_battle.json"));
    const map = try world.load(alloc, world.json);
    const data = try overlay.load(alloc, overlay.json);
    const items = try field.items.load(alloc, field.items.json);
    const content = try data.value.view(map.value, base.value);
    const first_library = try commanderActors(alloc);
    const other_library = try commanderActors(alloc);
    const session = @import("combat_session");
    for ([_]bool{ false, true }) |group| for ([_]u32{ 24, 84, 100, 120, 150 }) |at| {
        if (!group and at == 150) continue;
        var members: [6]battle.Member = undefined;
        var source = try battle.State.init(content, items.value, &members, 1234);
        try source.attachUniteActors(&first_library);
        const values: [64]u15 = @splat(0);
        var draws = battle.systems.Draws{ .values = &values };
        const fingerprint = try session.fingerprint(source);
        const entry = session.Entry{ .id = "commander", .receipt = "commander-1", .content_id = "source-b", .encounter_id = content.encounters[0].id, .content_fingerprint = &fingerprint };
        var scratch: [6]battle.Member = undefined;
        var original = try session.Session.begin(entry, source, &scratch, draws);
        const owner = source.partyCount() + 3;
        original.state.phase = .battle_menu;
        original.state.acted = @splat(true);
        if (group) for (0..3) |ally| {
            original.state.acted[source.partyCount() + ally] = false;
        };
        try original.state.beginSourceCommander(owner, if (group) null else 0);
        for (0..at) |_| try original.tick(.{}, &draws);
        var checkpoint = try original.capture(draws);
        const bytes = try std.json.Stringify.valueAlloc(alloc, checkpoint.state.unite_vm, .{});
        const decoded = try std.json.parseFromSlice(battle.unite_playback.State, alloc, bytes, .{});
        checkpoint.state.unite_vm = decoded.value;
        var other_source = source;
        other_source.unite_actors = &other_library;
        var other_scratch: [6]battle.Member = undefined;
        var other_draws = battle.systems.Draws{ .values = &values };
        var resumed = try session.Session.begin(entry, other_source, &other_scratch, other_draws);
        try resumed.restore(checkpoint, &other_draws);
        for (resumed.state.unite_vm.scripted_actors, 0..) |binding, actor| if (binding != null and resumed.state.unite_vm.actors[actor].machine != null) {
            try std.testing.expect(resumed.state.unite_vm.actors[actor].machine.?.instructions.ptr != original.state.unite_vm.actors[actor].machine.?.instructions.ptr);
        };
        for (at..211) |_| {
            try original.tick(.{}, &draws);
            try resumed.tick(.{}, &other_draws);
            try std.testing.expectEqual(draws.cursor, other_draws.cursor);
            try std.testing.expectEqualDeep(original.state.unite_vm, resumed.state.unite_vm);
            for (original.state.actor_conditions, resumed.state.actor_conditions) |before, after| {
                try std.testing.expectEqual(before.sleep_turns, after.sleep_turns);
                try std.testing.expectEqual(before.accuracy_reduced, after.accuracy_reduced);
            }
            try std.testing.expectEqualDeep(original.state.progress.party, resumed.state.progress.party);
        }
        try std.testing.expect(!resumed.state.unite_vm.hasActors());
    };
}

test "Commander live bridge completes solo status and releases owner before recipient" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_battle.json"));
    const map = try world.load(alloc, world.json);
    const data = try overlay.load(alloc, overlay.json);
    const items = try field.items.load(alloc, field.items.json);
    const content = try data.value.view(map.value, base.value);
    const library = try commanderActors(alloc);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content, items.value, &members, 1234);
    try state.attachUniteActors(&library);
    const owner = state.partyCount() + 3;
    state.phase = .battle_menu;
    state.acted = @splat(true);
    try state.beginSourceCommander(owner, 0);
    const hp = members[0].hp;
    const values: [8]u15 = @splat(0);
    var draws = battle.systems.Draws{ .values = &values };
    var owner_release: ?u32 = null;
    var recipient_release: ?u32 = null;
    var status: ?u32 = null;
    for (1..132) |update| {
        try state.tickReplay(.{}, &draws);
        if (owner_release == null and !state.unite_vm.ownsActor(owner)) owner_release = state.camera_ticks;
        if (update > 1 and recipient_release == null and !state.unite_vm.ownsActor(0)) recipient_release = state.camera_ticks;
        if (status == null and state.actor_conditions[0].sleep_turns != 0) status = state.camera_ticks;
        if (update < 120) try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        try std.testing.expectEqual(hp, members[0].hp);
    }
    try std.testing.expectEqual(@as(?u32, 101), owner_release);
    try std.testing.expectEqual(@as(?u32, 120), status);
    try std.testing.expectEqual(@as(?u32, 130), recipient_release);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
    try std.testing.expect(!state.unite_vm.hasActors() and state.active == null);
}

test "Commander live bridge dispatches zero through three allies with independent damage and returns" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_battle.json"));
    const map = try world.load(alloc, world.json);
    const data = try overlay.load(alloc, overlay.json);
    const items = try field.items.load(alloc, field.items.json);
    const content = try data.value.view(map.value, base.value);
    const library = try commanderActors(alloc);
    for (0..4) |count| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content, items.value, &members, 1234);
        try state.attachUniteActors(&library);
        const owner = state.partyCount() + 3;
        state.phase = .battle_menu;
        state.acted = @splat(true);
        for (0..count) |ally| state.acted[state.partyCount() + ally] = false;
        for (&members) |*member| {
            member.hp = 9999;
            member.max_hp = 9999;
        }
        state.coordinator = .{ .stage = .await_order, .current_actor = owner };
        try state.beginSourceCommander(owner, null);
        const values: [64]u15 = @splat(0);
        var draws = battle.systems.Draws{ .values = &values };
        var hits: [3]?u32 = @splat(null);
        var statuses: [3]?u32 = @splat(null);
        var released: [3]?u32 = @splat(null);
        var owner_release: ?u32 = null;
        for (1..211) |update| {
            try state.tickReplay(.{}, &draws);
            if (update == 12) {
                try std.testing.expectEqual(@as(i32, 60), state.coordinator.?.remaining);
                state.advanceCoordinator();
                try std.testing.expectEqual(@as(i32, 60), state.coordinator.?.remaining);
            }
            if (update == 13) {
                state.advanceCoordinator();
                try std.testing.expectEqual(@as(i32, 59), state.coordinator.?.remaining);
            }
            for (0..count) |target| {
                if (hits[target] == null and members[target].hp < 9999) hits[target] = state.camera_ticks;
                if (statuses[target] == null and state.actor_conditions[target].accuracy_reduced) statuses[target] = state.camera_ticks;
                if (update > 12 and released[target] == null and !state.unite_vm.ownsActor(state.partyCount() + target)) released[target] = state.camera_ticks;
            }
            if (owner_release == null and !state.unite_vm.ownsActor(owner)) owner_release = state.camera_ticks;
        }
        for (0..count) |target| {
            try std.testing.expectEqual(@as(?u32, 117), hits[target]);
            try std.testing.expectEqual(@as(?u32, 119), statuses[target]);
            try std.testing.expectEqual(@as(?u32, 199), released[target]);
        }
        for (count..state.partyCount()) |target| try std.testing.expectEqual(@as(u16, 9999), members[target].hp);
        try std.testing.expectEqual(@as(?u32, 142), owner_release);
        try std.testing.expectEqual(count * 2, draws.cursor);
        try std.testing.expect(!state.unite_vm.hasActors() and state.active == null);
    }
}

test "Commander decisions skip locked allies and party targets without spending their draws" {
    const base = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer base.deinit();
    const map = try world.load(allocator, world.json);
    defer map.deinit();
    const data = try overlay.load(allocator, overlay.json);
    defer data.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var content = try data.value.view(map.value, base.value);
    var rows = [_]battle.Row{ .front, .front, .front, .back };
    var encounters = [_]battle.Encounter{content.encounters[0]};
    encounters[0].enemy_rows = &rows;
    content.encounters = &encounters;
    var members: [6]battle.Member = undefined;
    const initial = try battle.State.init(content, items.value, &members, 1234);
    const owner = initial.partyCount() + 3;
    var cases: usize = 0;
    for (0..3) |ally| for ([_]bool{ false, true }) |front| for ([_]bool{ false, true }) |ally_locked| {
        rows[3] = if (front) .front else .back;
        for (0..64) |locks| for ([_]u15{ 0, 50, 51, 32767 }) |roll| {
            var state = initial;
            state.acted = @splat(false);
            for (0..3) |index| state.acted[state.partyCount() + index] = index != ally;
            // Scripted actor locks are the native counterpart of source actor byte+5.
            for (0..state.partyCount() + 3) |index| {
                const locked = if (index < state.partyCount()) locks & (@as(usize, 1) << @intCast(index)) != 0 else index == state.partyCount() + ally and ally_locked;
                if (locked) {
                    state.unite_vm.scripted_actors[index] = .{ .family = .counter, .leader = @intCast(index), .resource = 0 };
                    state.unite_vm.actors[index].highlights = 8;
                }
            }
            const values: [6]u15 = @splat(roll);
            var draws = battle.systems.Draws{ .values = &values };
            state.replay_draws = &draws;
            state.commanderDecision(owner);
            if (!front and !ally_locked) {
                try std.testing.expectEqual(@as(usize, 0), draws.cursor);
                if (locks & (@as(usize, 1) << @intCast(ally)) != 0) {
                    try std.testing.expect(state.replay_unsupported != null);
                    try std.testing.expect(state.active == null);
                } else {
                    try std.testing.expect(state.replay_unsupported == null);
                    try std.testing.expectEqual(.group_order, state.active.?.kind);
                    try std.testing.expectEqual(state.partyCount() + ally, state.active.?.ordered.?.actor);
                    try std.testing.expectEqual(ally, state.active.?.target);
                }
            } else {
                var expected: ?usize = null;
                var used: usize = 0;
                for (0..state.partyCount()) |target| {
                    if (locks & (@as(usize, 1) << @intCast(target)) != 0) continue;
                    used += 1;
                    if (roll % 100 >= 51) {
                        expected = target;
                        break;
                    }
                }
                try std.testing.expect(state.replay_unsupported == null and !state.replay_exhausted);
                try std.testing.expectEqual(used, draws.cursor);
                if (expected) |target| {
                    try std.testing.expectEqual(.status_attack, state.active.?.kind);
                    try std.testing.expectEqual(target, state.active.?.target);
                    try std.testing.expect(state.acted[owner]);
                } else {
                    try std.testing.expect(state.active == null);
                    try std.testing.expectEqual(@as(?usize, owner), state.pending_enemy_actor);
                    try std.testing.expect(!state.acted[owner]);
                }
            }
            cases += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 3072), cases);
    for (0..3) |front_ally| {
        const locked_ally = (front_ally + 1) % 3;
        rows = .{ .front, .front, .front, .back };
        rows[locked_ally] = .back;
        var state = initial;
        for (0..3) |index| state.acted[state.partyCount() + index] = index != front_ally and index != locked_ally;
        const locked = state.partyCount() + locked_ally;
        state.unite_vm.scripted_actors[locked] = .{ .family = .counter, .leader = @intCast(locked), .resource = 0 };
        state.unite_vm.actors[locked].highlights = 8;
        var draws = battle.systems.Draws{ .values = &.{} };
        state.replay_draws = &draws;
        state.commanderDecision(owner);
        try std.testing.expect(state.replay_unsupported == null and !state.replay_exhausted);
        try std.testing.expectEqual(.group_order, state.active.?.kind);
        try std.testing.expectEqual(state.partyCount() + front_ally, state.active.?.ordered.?.actor);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        try std.testing.expectEqual(@as(u8, 8), state.unite_vm.actors[locked].highlights);
    }
}
