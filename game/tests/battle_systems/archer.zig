const std = @import("std");
const h = @import("helpers.zig");
const battle = h.battle;
const allocator = h.allocator;

test "source archer shots overlap without losing target locks or damage" {
    const Source = struct { impact_tick: u32, rows: []const struct { tick: u32, party_hp: []const u16 } };
    const source = try std.json.parseFromSlice(Source, allocator, @embedFile("../fixtures/world_c_archer_pair.json"), .{ .ignore_unknown_fields = true });
    defer source.deinit();
    const second_contact = for (source.value.rows) |row| {
        if (row.party_hp[1] < 100) break row.tick;
    } else return error.MissingSourceSecondContact;
    const source_spacing = second_contact - source.value.impact_tick;
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const spells = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer spells.deinit();
    var content = world.value.actor_content.?;
    try std.testing.expectEqualStrings("suikoden-battle-trial/32", content.schema);
    try std.testing.expect(content.enemies[content.enemyIndex("kobold_type_2").?].action_policy == .source_projectile);
    var encounters = [_]battle.Encounter{world.value.encounters[0]};
    content.encounters = &encounters;
    try content.validate();
    content.schema = "suikoden-battle-trial/31";
    try std.testing.expectError(error.UnsupportedEnemyPresentation, content.validate());
    content.schema = "suikoden-battle-trial/33";
    try content.validate();

    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    combat.startEncounter();
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&spells.value);
    for (combat.progress.party) |*member| {
        member.max_hp = 5000;
        member.hp = 5000;
        member.inventory.slots = @splat(null);
    }
    combat.phase = .resolving;
    combat.actions = @splat(.defend);
    combat.acted = @splat(true);
    const first = combat.partyCount();
    combat.acted[first] = false;
    combat.acted[first + 1] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = first, .cached = .{ .actor = first } };
    var values: [4096]u15 = @splat(51);
    var draws = h.rules.Draws{ .values = &values };
    var starts: [2]?u32 = @splat(null);
    var contacts: [2]?u32 = @splat(null);
    var targets: [2]?u8 = @splat(null);
    var overlapping = false;
    var rolled_back = false;
    for (0..400) |_| {
        if (overlapping and !rolled_back) for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
            if (playback.action == null or playback.action.?.stage != .approach or combat.unite_vm.actors[playback.attacker].signals & 2 == 0) continue;
            const before = combat;
            const before_members = members;
            const cursor = draws.cursor;
            draws.values = values[0..cursor];
            try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
            try std.testing.expectEqualDeep(before_members, members);
            try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
            try std.testing.expectEqualDeep(before.coordinator, combat.coordinator);
            try std.testing.expectEqualDeep(before.active, combat.active);
            try std.testing.expectEqual(cursor, draws.cursor);
            draws.values = &values;
            rolled_back = true;
            break;
        };
        try combat.tickReplay(.{}, &draws);
        if (combat.camera_ticks == 1) {
            try std.testing.expect(combat.coordinator.?.completed and combat.active == null);
            try std.testing.expect(combat.coordinatorLocked(first) and combat.coordinatorLocked(0));
            try std.testing.expectEqual(@as(usize, 2), draws.cursor);
        }
        var count: usize = 0;
        for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
            if (playback.attacker < first or playback.attacker > first + 1) continue;
            const index = playback.attacker - first;
            count += 1;
            if (starts[index] == null) starts[index] = playback.start_at;
            targets[index] = playback.defender;
            if (playback.contact_at) |tick| contacts[index] = tick;
        };
        overlapping = overlapping or count == 2;
        if (combat.phase != .resolving) break;
    }
    if (starts[0] == null or starts[1] == null or contacts[0] == null or contacts[1] == null)
        std.debug.print("archer round starts={any} contacts={any} targets={any} phase={s} draws={d}\n", .{ starts, contacts, targets, @tagName(combat.phase), draws.cursor });
    if (starts[0] != null and starts[1] != null and starts[1].? - starts[0].? != source_spacing)
        std.debug.print("archer spacing starts={any} contacts={any} targets={any}\n", .{ starts, contacts, targets });
    try std.testing.expect(overlapping and rolled_back and starts[0] != null and starts[1] != null and contacts[0] != null and contacts[1] != null);
    try std.testing.expectEqual(source.value.rows[0].tick, starts[0].?);
    try std.testing.expectEqual(source_spacing, starts[1].? - starts[0].?);
    try std.testing.expectEqual(source.value.impact_tick, contacts[0].?);
    try std.testing.expectEqual(second_contact, contacts[1].?);
    try std.testing.expectEqualDeep([2]?u8{ 0, 1 }, targets);
    try std.testing.expect(combat.hp(0) < 5000 and combat.hp(1) < 5000);
}

test "mixed C formations complete queued archer melee and magic rounds" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const spells = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer spells.deinit();
    const rules_host = try h.hostFixture();
    defer rules_host.deinit();
    for ([_][]const u8{ "world_c_encounter_4", "world_c_encounter_5", "world_c_encounter_7" }) |id| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
            if (std.mem.eql(u8, encounter.id, id)) break index;
        } else return error.MissingMixedEncounter;
        combat.startEncounter();
        combat.integration = .{ .host = rules_host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&spells.value);
        for (combat.progress.party) |*member| {
            member.max_hp = 5000;
            member.hp = 5000;
            member.inventory.slots = @splat(null);
        }
        const values = try allocator.alloc(u15, 32768);
        defer allocator.free(values);
        @memset(values, 32767);
        var draws = h.rules.Draws{ .values = values };
        for (0..2) |round| {
            combat.phase = .resolving;
            combat.actions = @splat(.defend);
            combat.acted = @splat(false);
            for (0..combat.partyCount()) |index| combat.acted[index] = true;
            var seen: u16 = 0;
            var overlap = false;
            for (0..5000) |_| {
                try combat.tickReplay(.{}, &draws);
                var ongoing: usize = 0;
                for (combat.unite_vm.counter_actions) |maybe| if (maybe) |action| {
                    seen |= @as(u16, 1) << @intCast(action.attacker - combat.partyCount());
                    ongoing += 1;
                };
                for (combat.unite_vm.enemy_magic_actions) |maybe| if (maybe) |action| {
                    seen |= @as(u16, 1) << @intCast(action.owner - combat.partyCount());
                    ongoing += 1;
                };
                overlap = overlap or ongoing > 1;
                if (combat.phase != .resolving) break;
            }
            if (combat.phase != .battle_menu or seen != (@as(u16, 1) << @intCast(combat.enemyCount())) - 1)
                std.debug.print("mixed {s} round {d}: phase={s}, seen={b}, unsupported={any}\n", .{ id, round, @tagName(combat.phase), seen, combat.replay_unsupported });
            try std.testing.expectEqual((@as(u16, 1) << @intCast(combat.enemyCount())) - 1, seen);
            try std.testing.expect(overlap and combat.phase == .battle_menu and combat.round == round + 2 and !combat.unite_vm.hasActors());
        }
    }
}

test "source archer knockout and Buddha retain reaction ownership through the next round" {
    const Visual = struct { position: battle.Position, offset: [2]i8 };
    const Row = struct { party_visuals: []const Visual };
    const Witness = struct { launch: Row, second: []const Row };
    const source = try std.json.parseFromSlice(Witness, allocator, @embedFile("../fixtures/world_c_archer_gremio_knockout.json"), .{ .ignore_unknown_fields = true });
    defer source.deinit();
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const spells = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer spells.deinit();
    const rules_host = try h.hostFixture();
    defer rules_host.deinit();
    for ([_]bool{ false, true }) |buddha| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
            if (std.mem.eql(u8, encounter.id, "world_c_encounter_4")) break index;
        } else return error.MissingMixedEncounter;
        combat.startEncounter();
        combat.integration = .{ .host = rules_host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&spells.value);
        combat.runes = @splat(null);
        for (combat.progress.party, 0..) |*member, index| {
            member.max_hp = 100;
            member.hp = if (index == 1) 50 else 100;
            member.inventory.slots = @splat(null);
            combat.base_stats[index].defense = 40;
            combat.base_stats[index].skill = 0;
            combat.loadouts[index] = .{};
        }
        if (buddha) members[1].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        combat.phase = .resolving;
        combat.actions = @splat(.defend);
        combat.acted = @splat(true);
        const owner = combat.partyCount();
        combat.acted[owner] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .cached = .{ .actor = owner } };
        var values: [1024]u15 = @splat(51);
        values[0] = 0;
        var draws = h.rules.Draws{ .values = &values };
        var pending = false;
        var revived = false;
        var revival_offset: ?[2]i16 = null;
        for (0..1000) |_| {
            combat.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("archer KO buddha={} time={d} hp={d} pending={} clock={any} draws={d} error={s}\n", .{ buddha, combat.camera_ticks, combat.hp(1), combat.party_knockouts[1].pending, combat.coordinator, draws.cursor, @errorName(err) });
                return err;
            };
            pending = pending or combat.party_knockouts[1].pending;
            revived = revived or combat.revivalAge(1) != null;
            if (combat.party_knockouts[1].revival) |revival| {
                revival_offset = revival.screen_offset;
                const actor = battle.layout.actorLayout(combat, 1);
                const projected = battle.layout.worldPoint(combat, revival.origin);
                try std.testing.expectApproxEqAbs(projected.y + @as(f32, @floatFromInt(revival.screen_offset[1])) * actor.scale, actor.point.y, 0.001);
            }
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(pending and combat.phase == .battle_menu);
        try std.testing.expectEqual(buddha, revived);
        try std.testing.expectEqual(@as(u16, if (buddha) 50 else 0), members[1].hp);
        try std.testing.expectEqual(if (buddha) battle.Row.front else battle.Row.back, combat.partyRow(1));
        try std.testing.expectEqual(if (buddha) battle.Row.back else battle.Row.front, combat.partyRow(3));
        try std.testing.expect(!combat.hasPendingRevival() and !combat.unite_vm.hasActors());
        if (buddha) {
            try std.testing.expectEqual(@as(usize, 0), members[1].inventory.count());
            try std.testing.expectEqualDeep([2]i16{ 0, -2 }, revival_offset.?);
            try std.testing.expectEqualDeep([2]i8{ 0, -2 }, combat.uniteScreenOffset(1));
            combat.phase = .resolving;
            combat.actions = @splat(.defend);
            combat.acted = @splat(true);
            combat.acted[owner] = false;
            combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .cached = .{ .actor = owner } };
            values[draws.cursor] = 0;
            for (0..200) |_| {
                try combat.tickReplay(.{}, &draws);
                if (combat.unite_vm.scripted_actors[1] != null) break;
            }
            try std.testing.expect(combat.unite_vm.scripted_actors[1] != null);
            try std.testing.expectEqualDeep([2]i8{ 0, -2 }, combat.unite_vm.actors[1].screen_offset);
        } else for (1..21) |step| {
            for ([_]usize{ 1, 3 }) |member| {
                const from = combat.content.formation_slots[if (member == 1) @as(usize, 1) else 3];
                const to = combat.content.formation_slots[if (member == 1) @as(usize, 3) else 1];
                const point = battle.layout.worldPosition(&combat, member);
                const t: f32 = @floatFromInt(step);
                const expected = battle.Position{ .x = from.x + @trunc((to.x - from.x) * 4096 / 20) / 4096 * t, .y = from.y + @trunc((to.y - from.y) * 4096 / 20) / 4096 * t, .z = from.z + @trunc((to.z - from.z) * 4096 / 20) / 4096 * t };
                try std.testing.expectEqualDeep(expected, point);
                const shadow = battle.layout.shadowLayout(combat, member);
                const projected = battle.layout.worldPoint(combat, point);
                try std.testing.expectEqual(projected.x, shadow.point.x);
                try std.testing.expectEqual(projected.y, shadow.point.y);
                if (step == 16) try std.testing.expectEqualDeep(source.value.launch.party_visuals[member].offset, combat.uniteScreenOffset(member));
                if (step == 16) {
                    const actor = battle.layout.actorLayout(combat, member);
                    try std.testing.expectApproxEqAbs(projected.y + @as(f32, @floatFromInt(source.value.launch.party_visuals[member].offset[1])) * actor.scale, actor.point.y, 0.001);
                }
                if (step == 16) try std.testing.expectEqualDeep(source.value.launch.party_visuals[member].position, point);
                if (step > 16) try std.testing.expectEqualDeep(source.value.second[step - 17].party_visuals[member].position, point);
            }
            if (step < 20) try combat.tickReplay(.{}, &draws);
        }
        combat.startEncounter();
        try std.testing.expectEqualDeep([2]i8{ 0, 0 }, combat.uniteScreenOffset(1));
    }
}

test "source and legacy archer rounds retain sleep and suppress protected HP loss" {
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    const host = try h.hostFixture();
    defer host.deinit();
    const legacy = try h.world_battle.load(allocator, h.world_battle.json_c);
    defer legacy.deinit();
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const spells = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer spells.deinit();
    for (0..24) |scenario| {
        const modern = scenario >= 6;
        const target = if (modern) (scenario - 6) / 3 else scenario / 3;
        const mode = scenario % 3;
        const sleeping = mode != 1;
        const protected = mode != 0;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(if (modern) world.value.actor_content.? else fixture.view, fixture.items.value, &members, 17);
        if (modern) {
            combat.encounter = 0;
            combat.startEncounter();
            try combat.attachUniteActors(&actors.value);
            try combat.attachSpellScenes(&spells.value);
        } else try h.sourceRoundBoundary(&combat, legacy.value);
        combat.integration = .{ .host = host };
        combat.active = null;
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        combat.runes = @splat(null);
        const owner = combat.partyCount();
        combat.acted[owner] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .cached = .{ .actor = owner } };
        for (combat.progress.party, 0..) |*member, index| {
            member.max_hp = 1000;
            member.hp = if (index != target and (modern or index < 3)) 0 else 1000;
            member.status = if (member.hp == 0) .unconscious else if (index == target and mode == 2) .poisoned else .healthy;
            member.inventory.slots = @splat(null);
        }
        if (modern) combat.promoteRearMembers();
        try std.testing.expectEqual(battle.Row.front, combat.partyRow(target));
        combat.actor_conditions[target].sleep_turns = @intFromBool(sleeping);
        combat.actor_conditions[target].protection_rounds = if (protected) 2 else 0;
        var draws = h.rules.Draws{ .values = &.{ 51, 0, 51 } };
        var contact = false;
        var returned = false;
        var rollback = false;
        for (0..500) |_| {
            if (draws.cursor == 2 and !rollback) {
                const before_members = members;
                var refused = combat;
                var short = draws;
                short.values = short.values[0..short.cursor];
                if (refused.tickReplay(.{}, &short)) |_| {
                    try std.testing.expectEqualDeep(before_members, members);
                } else |err| {
                    try std.testing.expectEqual(error.RandomInputExhausted, err);
                    try std.testing.expectEqualDeep(before_members, members);
                    try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
                    try std.testing.expectEqualDeep(combat.front_projectiles, refused.front_projectiles);
                    try std.testing.expectEqualDeep(combat.front_hurt_at, refused.front_hurt_at);
                    try std.testing.expectEqual(combat.camera_ticks, refused.camera_ticks);
                    try std.testing.expectEqualDeep(combat.actor_conditions, refused.actor_conditions);
                    try std.testing.expectEqual(draws.cursor, short.cursor);
                    rollback = true;
                }
            }
            try combat.tickReplay(.{}, &draws);
            if (!contact and draws.cursor == 3) {
                contact = true;
                if (protected) try std.testing.expectEqual(@as(u16, 1000), combat.hp(target)) else try std.testing.expect(combat.hp(target) < 1000);
            }
            if (contact) try std.testing.expectEqual(@as(u8, @intFromBool(sleeping)), combat.actor_conditions[target].sleep_turns);
            if (combat.phase == .battle_menu) {
                returned = true;
                break;
            }
        }
        if (!(contact and returned and rollback)) std.debug.print("archer status scenario={d} contact={} return={} rollback={} time={d} phase={s} draws={d} clock={any}\n", .{ scenario, contact, returned, rollback, combat.camera_ticks, @tagName(combat.phase), draws.cursor, combat.coordinator });
        try std.testing.expect(contact and returned and rollback);
        try std.testing.expectEqual(@as(usize, 3), draws.cursor);
        try std.testing.expectEqual(@as(u8, if (protected) 1 else 0), combat.actor_conditions[target].protection_rounds);
        if (mode == 2) {
            try std.testing.expectEqual(h.field.game_state.Status.poisoned, members[target].status);
            try std.testing.expectEqual(@as(u16, 1000), members[target].hp);
        }
        try std.testing.expect(!combat.unite_vm.hasActors() and combat.front_projectiles[0] == null);
    }
}
