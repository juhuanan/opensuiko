//! Ordinary party attacks over the shared source actor host.
const std = @import("std");
const h = @import("helpers.zig");
const battle = h.battle;
const allocator = h.allocator;

fn encounter(content: battle.Content, id: []const u8) !usize {
    for (content.encounters, 0..) |entry, index| if (std.mem.eql(u8, entry.id, id)) return index;
    return error.MissingSourceFormation;
}

test "first round camera launches from Fight Free Will and a refused Bribe" {
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();

    for ([_]usize{ 0, 2, 3 }) |selection| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.encounter = try encounter(content.value, "area_b_1");
        combat.startEncounter();
        try combat.attachUniteActors(&actors.value);
        combat.progress.money = 0;
        combat.selection = selection;
        var values: [13]u15 = @splat(51);
        values[0] = 5;
        var draws = h.rules.Draws{ .values = values[0..1] };
        try combat.tickReplay(.{ .confirm = true }, &draws);
        if (selection == 0) {
            try std.testing.expectEqual(.command, combat.phase);
            while (combat.phase == .command) combat.queue(.defend);
            try std.testing.expectEqual(.confirm_round, combat.phase);
            try combat.tickReplay(.{ .confirm = true }, &draws);
        } else if (selection == 2) {
            try std.testing.expectEqual(.bribe_refused, combat.phase);
            try combat.tickReplay(.{ .confirm = true }, &draws);
        }
        try std.testing.expectEqual(.resolving, combat.phase);
        try std.testing.expectEqual(@as(u32, 1), combat.round);
        try std.testing.expect(combat.round_start_pending and combat.coordinator == null);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);

        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        try std.testing.expectEqual(@as(?u8, 2), combat.round_camera_choice);
        try std.testing.expectEqual([4]u16{ 29, 29, 29, 29 }, combat.actor_camera.?.remaining);
        for (1..30) |_| try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        try std.testing.expectEqual(@as(i32, 1), combat.coordinator.?.remaining);
        try std.testing.expectEqual(.select, combat.coordinator.?.stage);

        const before_selection = combat.actor_camera.?;
        try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
        try std.testing.expectEqual(@as(i32, 1), combat.coordinator.?.remaining);
        try std.testing.expectEqualDeep(before_selection, combat.actor_camera.?);
        draws.values = &values;
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(.check, combat.coordinator.?.stage);
        try std.testing.expect(draws.cursor > 1 and combat.active == null);
    }
}

test "shared party melee and ranged normal critical protection knockout and dodge cover every current owner" {
    const parsed = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try h.journeyScenes(arena.allocator(), effects.value);
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const host = try h.hostFixture();
    defer host.deinit();
    const enemies = try arena.allocator().dupe(battle.Profile, parsed.value.enemies);
    for (enemies) |*enemy| enemy.max_hp = 5000;
    var base_content = parsed.value;
    base_content.enemies = enemies;
    var cases: usize = 0;
    for (base_content.party) |profile| {
        try std.testing.expect(actors.value.counterPacket().?.partyAttacker(profile.id, .melee_hit) != null or actors.value.counterPacket().?.rangedAttacker(profile.id) != null);
        var ids: [6][]const u8 = undefined;
        ids[0] = profile.id;
        var count: usize = 1;
        for (parsed.value.initial_party.?) |id| {
            if (std.mem.eql(u8, id, profile.id) or count == ids.len) continue;
            ids[count] = id;
            count += 1;
        }
        try std.testing.expectEqual(ids.len, count);
        var content = base_content;
        content.initial_party = &ids;
        for ([_][]const u8{ "world_c_encounter_1", "world_c_encounter_2", "world_c_encounter_5" }, [_]usize{ 0, 0, 1 }) |name, target| for (0..5) |variant| {
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(content, items.value, &members, 17);
            combat.encounter = try encounter(content, name);
            combat.startEncounter();
            combat.integration = .{ .host = host };
            try combat.attachUniteActors(&actors.value);
            try combat.attachSpellScenes(&packet);
            for (combat.progress.party.items()) |member| {
                member.max_hp = 5000;
                member.hp = 5000;
            }
            combat.phase = .resolving;
            combat.round_start_pending = false;
            combat.acted = @splat(true);
            combat.actions[0] = .{ .attack = target };
            for (combat.progress.party.items()) |member| member.rune = null;
            combat.progress.party.at(0).base_stats.attack = 300;
            combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
            const actor = combat.partyCount() + target;
            if (variant == 2) combat.actor_conditions[actor].protection_rounds = 1;
            if (variant == 4) combat.enemy_hp[target] = 1;
            const before = combat.enemy_hp[target];
            var values: [4096]u15 = @splat(51);
            values[0] = if (variant == 3) 99 else 0;
            values[1] = if (variant == 1) 0 else 99;
            var draws = h.rules.Draws{ .values = &values };
            var source = false;
            var critical = false;
            for (0..2500) |_| {
                combat.tickReplay(.{}, &draws) catch |err| {
                    std.debug.print("shared melee {s} {s} variant={d} tick={d}: {s}\n", .{ profile.id, name, variant, combat.camera_ticks, @errorName(err) });
                    return err;
                };
                for (combat.unite_vm.counter_actions) |maybe| if (maybe) |action| {
                    source = source or action.attacker == 0;
                    critical = critical or (action.attacker == 0 and action.critical);
                    if (action.attacker == 0 and action.kind.melee()) if (action.contact_at) |at| {
                        const clock: ?u32 = if (std.mem.eql(u8, profile.id, "hero")) 73 else if (std.mem.eql(u8, profile.id, "gremio")) 65 else if (std.mem.eql(u8, profile.id, "pahn")) 57 else if (std.mem.eql(u8, profile.id, "yam_koo") or std.mem.eql(u8, profile.id, "tai_ho")) 74 else null;
                        if (clock) |expected| try std.testing.expectEqual(expected, at - action.start_at + 1);
                    };
                };
                if (combat.phase != .resolving) break;
            }
            try std.testing.expect(source);
            try std.testing.expectEqual(variant == 1, critical);
            try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
            const evades = combat.enemy(target).dodges_attacks or (combat.partyProfile(0).weapon_range.? != .long and actors.value.counterPacket().?.defenderFor(combat.enemy(target).id, .parry) != null);
            if (variant == 2 or (variant == 3 and evades)) try std.testing.expectEqual(before, combat.enemy_hp[target]) else try std.testing.expect(combat.enemy_hp[target] < before);
            const settled_hp = combat.enemy_hp;
            const settled_members = members;
            const settled_cursor = draws.cursor;
            for (0..512) |_| {
                if (!combat.unite_vm.hasActors()) break;
                try combat.tickReplay(.{}, &draws);
            }
            try std.testing.expectEqualDeep(settled_hp, combat.enemy_hp);
            try std.testing.expectEqualDeep(settled_members, members);
            try std.testing.expectEqual(settled_cursor, draws.cursor);
            if (combat.hasUniteReturns() or combat.unite_vm.hasActors()) std.debug.print("retained shared melee {s} {s} variant={d}\n", .{ profile.id, name, variant });
            try std.testing.expect(!combat.hasUniteReturns() and !combat.unite_vm.hasActors());
            try combat.progress.validate();
            cases += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 795), cases);
}

test "shared party melee C formations finish source rounds with magic and cooperation" {
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try h.journeyScenes(arena.allocator(), effects.value);
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const host = try h.hostFixture();
    defer host.deinit();
    var cases: usize = 0;
    for (content.value.encounters, 0..) |entry, index| {
        if (!std.mem.startsWith(u8, entry.id, "world_c_encounter_")) continue;
        for ([_]u15{ 51, 20051, 32767 }) |roll| {
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(content.value, items.value, &members, 17);
            combat.encounter = index;
            combat.startEncounter();
            combat.integration = .{ .host = host };
            try combat.attachUniteActors(&actors.value);
            try combat.attachSpellScenes(&packet);
            for (combat.progress.party.items()) |member| {
                member.max_hp = 5000;
                member.hp = 5000;
            }
            combat.phase = .resolving;
            combat.round_start_pending = false;
            combat.acted = @splat(false);
            combat.actions = @splat(.defend);
            combat.coordinator = .{ .stage = .select, .current_actor = 0, .completed = true, .remaining = 0 };
            var values: [16384]u15 = @splat(roll);
            var draws = h.rules.Draws{ .values = &values };
            for (0..6000) |_| {
                combat.tickReplay(.{}, &draws) catch |err| {
                    std.debug.print("shared melee C {s} roll={d} tick={d}: {s}\n", .{ entry.id, roll, combat.camera_ticks, @errorName(err) });
                    return err;
                };
                if (combat.phase != .resolving) break;
            }
            try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
            try std.testing.expect(!combat.hasUniteReturns() and !combat.unite_vm.hasActors());
            try combat.progress.validate();
            cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 24), cases);
}

test "shared party melee catalogue completes full Free Will encounters" {
    const parsed = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try h.journeyScenes(arena.allocator(), effects.value);
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const host = try h.hostFixture();
    defer host.deinit();
    var content = parsed.value;
    content.initial_party = &.{ "hero", "pahn", "kasumi", "cleo", "tengaar", "kirkis" };
    var cases: usize = 0;
    var tail_handoffs: usize = 0;
    var rear_retargets: usize = 0;
    for (content.encounters, 0..) |entry, index| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        combat.encounter = index;
        combat.startEncounter();
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&packet);
        // Diagnostic survivability/damage isolate scheduling from campaign growth.
        for (combat.progress.party.items(), 0..) |member, owner| {
            member.max_hp = 5000;
            member.hp = 5000;
            combat.progress.party.at(owner).base_stats.attack = 300;
        }
        for (combat.progress.party.items()) |member| member.rune = null;
        var tape: h.Tape = .{};
        var draws = tape.init();
        var rounds: usize = 0;
        for (0..25000) |_| {
            const old_bindings = combat.unite_vm.scripted_actors;
            const old_controllers = combat.unite_vm.counter_actions;
            const old_actions = combat.actions;
            var input: battle.Input = .{};
            if (combat.phase == .battle_menu) {
                try std.testing.expect(combat.canFreeWill());
                combat.selection = 3;
                input.confirm = true;
                rounds += 1;
            }
            combat.tickReplay(input, &draws) catch |err| {
                std.debug.print("full catalogue {s} round={d} tick={d}: {s}\n", .{ entry.id, combat.round, combat.camera_ticks, @errorName(err) });
                std.debug.print("clock={any} actions={any} hp={any}\n", .{ combat.coordinator, combat.actions, combat.enemy_hp });
                return err;
            };
            for (old_bindings, combat.unite_vm.scripted_actors, 0..) |old, current, actor| {
                if (old == null or current == null or old.?.family != .counter or current.?.family != .counter or old.?.leader == current.?.leader) continue;
                const prior = old_controllers[old.?.leader] orelse continue;
                if (!prior.controller_done) continue;
                if (combat.unite_vm.counter_actions[old.?.leader]) |retained| {
                    if (prior.attacker == actor) try std.testing.expect(retained.attacker_done) else if (prior.defender == actor) try std.testing.expect(retained.defender_done) else if (prior.guard != null and prior.guard.? == actor) try std.testing.expect(retained.guard_done) else try std.testing.expect(retained.cooperation.assistant_done);
                }
                tail_handoffs += 1;
            }
            if (combat.phase == .resolving) for (old_actions[0..combat.partyCount()], 0..) |old, actor| {
                const action = combat.actions[actor] orelse continue;
                if (old == null or old.? != .attack or action != .attack or old.?.attack == action.attack) continue;
                if (combat.weaponRange(actor) != .long and combat.enemy_hp[action.attack] > 0 and combat.enemyRow(action.attack) == .back and !combat.canAttackTarget(actor, action.attack)) rear_retargets += 1;
            };
            if (combat.phase == .victory or combat.phase == .defeat) break;
        }
        if (combat.phase != .victory) std.debug.print("full catalogue {s} phase={s} rounds={d} hp={any}\n", .{ entry.id, @tagName(combat.phase), rounds, combat.enemy_hp });
        try std.testing.expectEqual(battle.Phase.victory, combat.phase);
        try std.testing.expect(rounds > 0);
        try std.testing.expect(combat.firstLiving(false) == null);
        try std.testing.expect(!combat.hasUniteReturns() and !combat.unite_vm.hasActors());
        try combat.progress.validate();
        cases += 1;
    }
    try std.testing.expectEqual(@as(usize, 96), cases);
    try std.testing.expect(tail_handoffs > 0);
    try std.testing.expect(rear_retargets > 0);
}

test "shared party melee catalogue completes defended defeats and rear promotion" {
    const parsed = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try h.journeyScenes(arena.allocator(), effects.value);
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const host = try h.hostFixture();
    defer host.deinit();
    const enemies = try arena.allocator().dupe(battle.Profile, parsed.value.enemies);
    for (enemies) |*enemy| {
        enemy.max_hp = 5000;
        enemy.stats.attack = 500;
        enemy.stats.magic = 500;
    }
    var content = parsed.value;
    content.enemies = enemies;
    content.initial_party = &.{ "hero", "pahn", "kasumi", "cleo", "tengaar", "kirkis" };
    var cases: usize = 0;
    var promoted: usize = 0;
    for (content.encounters, 0..) |entry, index| {
        var profiles: [6]battle.Profile = undefined;
        var profile_count: usize = 0;
        for (enemies) |enemy| {
            const present = for (entry.enemies) |id| {
                if (std.mem.eql(u8, id, enemy.id)) break true;
            } else false;
            if (!present) continue;
            profiles[profile_count] = enemy;
            profile_count += 1;
        }
        var scoped = content;
        scoped.enemies = profiles[0..profile_count];
        scoped.encounters = content.encounters[index .. index + 1];
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(scoped, items.value, &members, 17);
        combat.startEncounter();
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&packet);
        // Force lethal contacts without changing source selection or animation programs.
        for (combat.progress.party.items()) |member| {
            member.hp = 1;
            member.inventory = .{};
        }
        for (combat.progress.party.items()) |member| member.rune = null;
        const money = combat.progress.money;
        const formation = combat.formationOrder();
        var tape: h.Tape = .{};
        var draws = tape.init();
        for (0..25000) |_| {
            const before_formation = combat.formationOrder();
            var input: battle.Input = .{};
            if (combat.phase == .battle_menu) combat.choose(combat.firstLiving(true).?);
            if (combat.phase == .command) combat.queue(.defend);
            if (combat.phase == .confirm_round) {
                combat.yes = true;
                input.confirm = true;
            }
            combat.tickReplay(input, &draws) catch |err| {
                std.debug.print("defeat catalogue {s} round={d} tick={d}: {s}\n", .{ entry.id, combat.round, combat.camera_ticks, @errorName(err) });
                return err;
            };
            for (before_formation, 0..) |owner, slot| {
                if (combat.formationSlot(owner) == slot) continue;
                const shift = combat.formation_shifts[owner] orelse {
                    std.debug.print("missing promotion motion {s} owner={d} round={d}\n", .{ entry.id, owner, combat.round });
                    return error.MissingSourcePromotionMotion;
                };
                try std.testing.expectEqual(slot, shift.from_slot);
            }
            for (combat.formation_shifts[0..combat.partyCount()], 0..) |maybe, owner| {
                const shift = maybe orelse continue;
                const age = combat.camera_ticks -% shift.started_at;
                if (age > 20) continue;
                const from = combat.content.formation_slots[shift.from_slot];
                const home = combat.content.formation_slots[combat.formationSlot(owner)];
                const position = battle.layout.worldPosition(&combat, owner);
                inline for (.{ "x", "y", "z" }) |axis| {
                    const start: i32 = @intFromFloat(@round(@field(from, axis) * 4096));
                    const finish: i32 = @intFromFloat(@round(@field(home, axis) * 4096));
                    const q12 = if (age < 20) start + @divTrunc(finish - start, 20) * @as(i32, @intCast(age)) else finish;
                    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(q12)) / 4096, @field(position, axis), 0.0005);
                }
            }
            if (combat.phase == .victory or combat.phase == .defeat) break;
        }
        if (combat.phase != .defeat) std.debug.print("defeat catalogue {s} phase={s} round={d} hp={any}\n", .{ entry.id, @tagName(combat.phase), combat.round, members });
        try std.testing.expectEqual(battle.Phase.defeat, combat.phase);
        try std.testing.expect(combat.firstLiving(true) == null);
        try std.testing.expectEqual(money, combat.progress.money);
        try std.testing.expect(!combat.hasPendingRevival());
        for (members, 0..) |member, owner| {
            try std.testing.expectEqual(@as(u16, 0), member.hp);
            try std.testing.expectEqual(h.field.game_state.Status.unconscious, member.status);
            try std.testing.expect(!combat.party_knockouts[owner].pending);
        }
        const settled = members;
        const cursor = draws.cursor;
        for (0..512) |_| {
            if (!combat.unite_vm.hasActors()) break;
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(battle.Phase.defeat, combat.phase);
        try std.testing.expectEqualDeep(settled, members);
        try std.testing.expectEqual(cursor, draws.cursor);
        try std.testing.expectEqual(money, combat.progress.money);
        try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasUniteReturns());
        if (!std.mem.eql(u8, &formation, &combat.formationOrder())) promoted += 1;
        try combat.progress.validate();
        cases += 1;
    }
    try std.testing.expectEqual(@as(usize, 96), cases);
    try std.testing.expect(promoted > 0);
}

test "shared party melee simultaneous Double Beat owners retain independent followups" {
    const parsed = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try h.journeyScenes(arena.allocator(), effects.value);
    const enemies = try arena.allocator().dupe(battle.Profile, parsed.value.enemies);
    for (enemies) |*enemy| enemy.max_hp = 5000;
    var content = parsed.value;
    content.enemies = enemies;
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const host = try h.hostFixture();
    defer host.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    combat.encounter = try encounter(content, "world_c_encounter_2");
    combat.startEncounter();
    combat.integration = .{ .host = host };
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&packet);
    combat.phase = .resolving;
    combat.round_start_pending = false;
    combat.acted = @splat(true);
    for (combat.partyCount()..combat.partyCount() + combat.enemyCount()) |actor| combat.acted[actor] = false;
    for (combat.progress.party.items()) |member| {
        member.max_hp = 5000;
        member.hp = 5000;
    }
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .attack = 0 };
    combat.actions[2] = .{ .attack = 1 };
    for (combat.progress.party.items()) |member| member.rune = null;
    for ([_]usize{ 0, 2 }) |owner| combat.progress.party.at(owner).rune = combat.content.systems.?.runeIndex("double-beat").?;
    combat.coordinator = .{ .stage = .select, .current_actor = 2, .completed = false, .remaining = 0 };
    var values: [4096]u15 = @splat(51);
    values[0..4].* = .{ 0, 99, 0, 99 };
    var draws = h.rules.Draws{ .values = &values };
    combat.replay_draws = &draws;
    try std.testing.expect(combat.startMeleeStrike(0, 0));
    try std.testing.expect(combat.startMeleeStrike(2, 1));
    combat.replay_draws = null;
    var launches: [2]usize = @splat(0);
    var starts: [2]u32 = @splat(std.math.maxInt(u32));
    var simultaneous = false;
    for (0..2500) |_| {
        try combat.tickReplay(.{}, &draws);
        var live: usize = 0;
        for (combat.unite_vm.counter_actions) |maybe| if (maybe) |action| {
            if (!action.kind.melee() or action.controller_done) continue;
            live += 1;
            const slot: usize = if (action.attacker == 0) 0 else if (action.attacker == 2) 1 else continue;
            if (action.start_at != starts[slot]) {
                starts[slot] = action.start_at;
                launches[slot] += 1;
            }
        };
        simultaneous = simultaneous or live == 2;
        if (combat.phase != .resolving) break;
    }
    try std.testing.expect(simultaneous);
    try std.testing.expectEqualDeep([2]usize{ 2, 2 }, launches);
    try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
    const settled = combat.enemy_hp;
    const cursor = draws.cursor;
    for (0..512) |_| {
        if (!combat.unite_vm.hasActors()) break;
        try combat.tickReplay(.{}, &draws);
    }
    try std.testing.expectEqualDeep(settled, combat.enemy_hp);
    try std.testing.expectEqual(cursor, draws.cursor);
    try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasUniteReturns());
}

test "shared party melee schema and critical art refuse malformed inputs before ownership" {
    const parsed = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    var invalid = actors.value;
    invalid.schema = "suikoden-unite-actors/30";
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    invalid = actors.value;
    invalid.counter.?.party_melee = null;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    invalid = actors.value;
    invalid.counter.?.party_melee.?.critical_camera.?.updates = 0;
    try std.testing.expectError(error.InvalidCounterBindings, invalid.validate());
    const effects = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer effects.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try h.journeyScenes(arena.allocator(), effects.value);
    var legacy = packet;
    legacy.schema = "suikoden-spell-scenes/51";
    try std.testing.expectError(error.InvalidSpellScenes, legacy.validate(4096, 4096));
    var trimmed = packet;
    const clips = try arena.allocator().alloc(@TypeOf(packet.unite_impacts[0]), packet.unite_impacts.len - 1);
    var n: usize = 0;
    for (packet.unite_impacts) |clip| if (clip.id != 17) {
        clips[n] = clip;
        n += 1;
    };
    try std.testing.expectEqual(clips.len, n);
    trimmed.unite_impacts = clips;
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    var content = parsed.value;
    content.initial_party = &.{ "maas", "hero", "gremio", "pahn", "viktor", "tai_ho" };
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    combat.encounter = try encounter(content, "world_c_encounter_1");
    combat.startEncounter();
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&trimmed);
    const before = combat.unite_vm;
    try std.testing.expectError(error.MissingPhysicalArt, combat.beginPartyMelee(0, combat.partyCount(), true, true));
    try std.testing.expectEqualDeep(before, combat.unite_vm);
}

test "shared party melee round boundary owns native statuses without an optional integration host" {
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content.value, items.value, &members, 17);
    combat.startEncounter();
    try combat.attachUniteActors(&actors.value);
    try std.testing.expect(combat.integration == null and combat.sharedPartyMelee());
    for (combat.progress.party.items()) |member| {
        member.max_hp = 200;
        member.hp = 100;
    }
    members[0].status = .poisoned;
    members[1].status = .poisoned;
    combat.actor_conditions[0].protection_rounds = 2;
    combat.actor_conditions[2].sleep_turns = 1;
    combat.actor_conditions[combat.partyCount()].sleep_turns = 1;
    combat.unbalanced[3] = 2;
    combat.unbalanced[4] = 1;
    combat.phase = .resolving;
    combat.round_start_pending = false;
    combat.acted = @splat(true);
    for (combat.progress.party.items()) |member| member.rune = null;
    combat.coordinator = .{ .stage = .round_ready, .current_actor = 0, .completed = true, .remaining = 0 };
    var values: [8]u15 = @splat(0);
    var draws = h.rules.Draws{ .values = &values };
    try combat.tickReplay(.{}, &draws);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
    try std.testing.expectEqual(@as(u16, 100), members[0].hp);
    try std.testing.expectEqual(@as(u16, 90), members[1].hp);
    try std.testing.expectEqual(@as(u8, 1), combat.actor_conditions[0].protection_rounds);
    try std.testing.expectEqual(@as(u8, 1), combat.actor_conditions[2].sleep_turns);
    try std.testing.expectEqual(@as(u8, 0), combat.actor_conditions[combat.partyCount()].sleep_turns);
    try std.testing.expectEqual(@as(u8, 1), combat.unbalanced[3]);
    try std.testing.expectEqual(@as(u8, 0), combat.unbalanced[4]);
    try std.testing.expectEqual(@as(usize, 1), draws.cursor);
}
