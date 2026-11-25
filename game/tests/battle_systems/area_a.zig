//! Full source A catalogue and status-bearing enemy rounds.
const std = @import("std");
const h = @import("helpers.zig");
const battle = h.battle;
const allocator = std.testing.allocator;

test "all nine Area A formations complete source enemy rounds with poison and Turtle" {
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
    for (content.value.encounters, 0..) |encounter, encounter_index| {
        if (!std.mem.startsWith(u8, encounter.id, "area_a_")) continue;
        var has_mosquito = false;
        for (encounter.enemies) |id| has_mosquito = has_mosquito or std.mem.eql(u8, id, "mosquito");
        for (0..3) |variant| {
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(content.value, items.value, &members, 17);
            combat.encounter = encounter_index;
            combat.startEncounter();
            combat.integration = .{ .host = host };
            try combat.attachUniteActors(&actors.value);
            try combat.attachSpellScenes(&packet);
            for (combat.progress.party, 0..) |*member, index| {
                member.max_hp = 5000;
                member.hp = 5000;
                combat.runes[index] = if (variant == 2) combat.content.systems.?.runeIndex("turtle").? else null;
                combat.actions[index] = .defend;
            }
            combat.phase = .resolving;
            combat.round_start_pending = false;
            combat.acted = @splat(false);
            combat.coordinator = .{ .stage = .select, .current_actor = 0, .completed = true, .remaining = 0 };
            const charges = members;
            var values: [16384]u15 = @splat(if (variant == 1) 6554 else 51);
            var draws = h.rules.Draws{ .values = &values };
            for (0..6000) |_| {
                combat.tickReplay(.{}, &draws) catch |err| {
                    std.debug.print("Area A {s} variant={d} tick={d}: {s}\n", .{ encounter.id, variant, combat.camera_ticks, @errorName(err) });
                    return err;
                };
                if (combat.phase != .resolving) break;
            }
            if (combat.phase != .battle_menu or combat.round != 2) std.debug.print("unfinished Area A {s} variant={d} tick={d}\n", .{ encounter.id, variant, combat.camera_ticks });
            try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
            var poisoned = false;
            for (charges, members) |before, after| {
                poisoned = poisoned or after.status == .poisoned;
                try std.testing.expect(after.hp > 0);
                try std.testing.expectEqualDeep(before.rune_charges, after.rune_charges);
            }
            try std.testing.expectEqual(has_mosquito and variant == 0, poisoned);
            try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasUniteReturns());
            cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 27), cases);
}

test "battle catalogue permits 512 definitions while retaining encounter and combatant bounds" {
    const parsed = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var entries: [513]battle.Encounter = undefined;
    for (&entries, 0..) |*entry, index| {
        entry.* = parsed.value.encounters[0];
        entry.id = try std.fmt.allocPrint(arena.allocator(), "catalogue_{d}", .{index});
    }
    var content = parsed.value;
    content.encounters = entries[0..512];
    try content.validate();
    content.encounters = &entries;
    try std.testing.expectError(error.InvalidBattleContent, content.validate());
    content.encounters = entries[0..1];
    entries[0].enemies = &.{ "bonbon", "bonbon", "bonbon", "bonbon", "bonbon", "bonbon", "bonbon" };
    try std.testing.expectError(error.InvalidEncounter, content.validate());
}
