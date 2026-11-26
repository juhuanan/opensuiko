const std = @import("std");
const h = @import("helpers.zig");
const battle = h.battle;
const allocator = h.allocator;

test "Cover integrated source formation resolves relationship and Phero interceptors" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const review = try battle.load(allocator, @embedFile("../fixtures/blacksmith_battle.json"));
    defer review.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const bundle = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    const rules_host = try h.hostFixture();
    defer rules_host.deinit();
    const source_graphics = world.value.actor_content.?.unite_graphics;
    const graphics = try allocator.alloc(battle.UniteGraphic, review.value.unite_graphics.len + source_graphics.len);
    defer allocator.free(graphics);
    var graphics_count: usize = 0;
    for (review.value.unite_graphics) |graphic| {
        const replaced = for (source_graphics) |source| {
            if (std.mem.eql(u8, graphic.id, source.id)) break true;
        } else false;
        if (replaced) continue;
        graphics[graphics_count] = graphic;
        graphics_count += 1;
    }
    for (source_graphics) |graphic| {
        graphics[graphics_count] = graphic;
        graphics_count += 1;
    }
    for (0..2) |scenario| {
        var content = review.value;
        var initial = [_][]const u8{ "hero", "gremio", "pahn", "viktor", "yam_koo", "tai_ho" };
        if (scenario == 1) initial[1] = "valeria";
        content.initial_party = &initial;
        content.enemies = world.value.actor_content.?.enemies;
        content.encounters = world.value.actor_content.?.encounters;
        content.unite_graphics = graphics[0..graphics_count];
        content.round_start = world.value.round_start;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        combat.integration = .{ .host = rules_host };
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        for (combat.progress.party) |*member| member.rune = null;
        for (combat.progress.party) |*member| {
            member.max_hp = 5000;
            member.hp = 5000;
            member.inventory.slots = @splat(null);
        }
        const ward: usize = if (scenario == 0) 0 else 2;
        const guard: usize = 1;
        combat.progress.party[ward].hp = 1;
        if (scenario == 1) combat.progress.party[ward].rune = combat.content.systems.?.runeIndex("phero").?;
        const attacker = combat.partyCount();
        combat.acted[attacker] = false;
        var values: [128]u15 = @splat(12345);
        values[0] = 0;
        for (0..ward) |slot| values[1 + slot] = 0;
        values[1 + ward] = 99;
        values[2 + ward] = 0;
        values[3 + ward] = 24;
        var draws = h.rules.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(usize, 3) + ward, draws.cursor);
        try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
        var contact = false;
        for (0..700) |_| {
            try combat.tickReplay(.{}, &draws);
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                try std.testing.expectEqual(battle.counter.Kind.cover, playback.kind);
                try std.testing.expectEqual(@as(u8, @intCast(guard)), playback.guard.?);
                if (playback.contact_at != null and !contact) {
                    try std.testing.expectEqual(@as(usize, 4) + ward, draws.cursor);
                    contact = true;
                }
            };
            try std.testing.expectEqual(@as(u16, 1), combat.hp(ward));
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(contact and combat.phase == .battle_menu and combat.round == 2 and !combat.unite_vm.hasActors());
        const amount = battle.physicalDamage(combat.stats(attacker).attack, combat.stats(guard).defense, 24, true);
        try std.testing.expectEqual(@as(u16, @intCast(5000 - amount)), combat.hp(guard));
    }
}
