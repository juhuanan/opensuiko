const std = @import("std");
const h = @import("helpers.zig");
const battle = h.battle;
const allocator = h.allocator;

test "Strong Arm live branches preserve ally selection protector HP KO Buddha and contact rollback" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const bundle = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer bundle.deinit();
    const rebound = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer rebound.deinit();
    const spells = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer spells.deinit();
    for (0..9) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
            if (std.mem.eql(u8, encounter.id, "world_c_encounter_8")) break index;
        } else return error.MissingStrongArmEncounter;
        combat.startEncounter();
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&spells.value);
        for (combat.progress.party.items()) |member| {
            member.max_hp = 5000;
            member.hp = 5000;
            member.inventory.slots = @splat(null);
        }
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        for (combat.progress.party.items()) |member| member.rune = null;
        const owner = combat.partyCount() + 1;
        const covered = scenario >= 3 and scenario <= 6;
        const victim: usize = if (covered) 1 else 0;
        if (scenario == 1 or scenario == 8) combat.enemy_hp[0] = 0;
        if (scenario == 8) combat.enemy_hp[2] = 0;
        if (scenario == 2) for (0..combat.enemyCount()) |index| {
            if (index != 1) combat.enemy_hp[index] = 0;
        };
        if (covered) combat.progress.party.at(0).hp = 1;
        if (scenario == 4) combat.actor_conditions[victim].protection_rounds = 2;
        if (scenario == 5 or scenario == 6) combat.progress.party.at(victim).hp = 1;
        if (scenario == 6) combat.progress.party.at(victim).inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        if (scenario == 7) try combat.beginMelee(combat.partyCount(), 1, true);
        var values: [128]u15 = @splat(24);
        var draws = h.rules.Draws{ .values = &values };
        if (scenario == 8) {
            values[0] = 99;
            values[1] = 99;
            combat.replay_draws = &draws;
            combat.sourceEnemyDecision(owner);
            combat.replay_draws = null;
            try std.testing.expectEqual(@as(usize, 2), draws.cursor);
            try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
        } else if (covered) try combat.beginCover(owner, 0, victim) else try combat.beginMelee(owner, 0, true);
        const initial_hp = combat.hp(victim);
        var rolled_back = false;
        var contact = false;
        var assistant: ?u8 = null;
        var saw_revival = false;
        for (0..1000) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.attacker != owner) continue;
                if (playback.cooperation.assistant) |slot| assistant = slot;
                if (playback.contact_at != null) contact = true;
                if (!rolled_back and playback.action != null and playback.action.?.stage == .approach and combat.unite_vm.actors[owner].signals & 2 != 0) {
                    const before = combat;
                    const before_members = members;
                    const cursor = draws.cursor;
                    draws.values = values[0..cursor];
                    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                    try std.testing.expectEqualDeep(before_members, members);
                    try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                    try std.testing.expectEqualDeep(before.active, combat.active);
                    try std.testing.expectEqual(cursor, draws.cursor);
                    draws.values = &values;
                    combat.unite_actors = &rebound.value;
                    rolled_back = true;
                }
            };
            try combat.tickReplay(.{}, &draws);
            if (covered) try std.testing.expectEqual(@as(u16, 1), combat.hp(0));
            saw_revival = saw_revival or combat.revivalAge(victim) != null;
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(rolled_back and contact and combat.phase == .battle_menu and !combat.unite_vm.hasActors());
        const ally_index: usize = if (scenario == 1 or scenario == 7) 2 else if (scenario == 8) 3 else 0;
        const expected_assistant: ?u8 = if (scenario == 2) null else @intCast(combat.partyCount() + ally_index);
        try std.testing.expectEqual(expected_assistant, assistant);
        const amount = battle.physicalDamage(combat.stats(owner).attack, combat.stats(victim).defense, 24, true);
        const hp: u16 = if (scenario == 4) initial_hp else if (scenario == 5) 0 else if (scenario == 6) 2500 else initial_hp - @as(u16, @intCast(amount));
        try std.testing.expectEqual(hp, combat.hp(victim));
        try std.testing.expectEqual(scenario == 6, saw_revival);
        try std.testing.expectEqual(@as(usize, if (scenario == 8) 3 else if (scenario == 7) 2 else 1), draws.cursor);
    }
}

test "Strong Arm source formation8 completes two queued rounds without spending the borrowed ally turn" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const bundle = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer bundle.deinit();
    const spells = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer spells.deinit();
    const rules_host = try h.hostFixture();
    defer rules_host.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
    combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
        if (std.mem.eql(u8, encounter.id, "world_c_encounter_8")) break index;
    } else return error.MissingStrongArmEncounter;
    combat.startEncounter();
    combat.integration = .{ .host = rules_host };
    try combat.attachUniteActors(&bundle.value);
    try combat.attachSpellScenes(&spells.value);
    for (combat.progress.party.items()) |member| {
        member.max_hp = 5000;
        member.hp = 5000;
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
        var contacts: [5]u8 = @splat(0);
        var magic: [5]u8 = @splat(0);
        var last_contact: [5]?u32 = @splat(null);
        var last_magic: [5]?u32 = @splat(null);
        var borrowed = false;
        for (0..4000) |_| {
            try combat.tickReplay(.{}, &draws);
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                borrowed = borrowed or playback.cooperation.assistant != null;
                const enemy = playback.attacker - combat.partyCount();
                if (playback.contact_at) |at| if (last_contact[enemy] != at) {
                    contacts[enemy] += 1;
                    last_contact[enemy] = at;
                };
            };
            for (combat.unite_vm.enemy_magic_actions) |maybe| if (maybe) |playback| {
                const enemy = playback.owner - combat.partyCount();
                if (playback.amount != null and last_magic[enemy] != playback.start_at) {
                    magic[enemy] += 1;
                    last_magic[enemy] = playback.start_at;
                }
            };
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(borrowed and combat.phase == .battle_menu and combat.round == round + 2 and !combat.unite_vm.hasActors());
        try std.testing.expectEqualDeep([5]u8{ 1, 1, 1, 0, 0 }, contacts);
        try std.testing.expectEqualDeep([5]u8{ 0, 0, 0, 1, 1 }, magic);
    }
}
