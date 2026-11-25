//! Source-qualified later species through the normal battle coordinator.
const std = @import("std");
const h = @import("helpers.zig");
const battle = h.battle;
const allocator = h.allocator;
const names = [_][]const u8{ "flying_squirrel", "roc", "mad_ivy", "ivy", "hell_hound", "grave_master", "grizzly_bear", "rabbit_bird", "simurgh", "orc" };

fn later(id: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, id, name)) return true;
    return false;
}

fn single(content: battle.Content, id: []const u8) !usize {
    for (content.encounters, 0..) |entry, index| if (entry.enemies.len == 1 and std.mem.eql(u8, entry.enemies[0], id)) return index;
    for (content.encounters, 0..) |entry, index| {
        if (entry.enemies.len == 0) continue;
        var same = true;
        for (entry.enemies) |enemy| same = same and std.mem.eql(u8, enemy, id);
        if (same) return index;
    }
    return error.MissingSourceFormation;
}

test "later enemy source formations finish defended rounds including self sleep" {
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
        if (!later(entry.enemies[0])) continue;
        const bird = std.mem.eql(u8, entry.enemies[0], "rabbit_bird");
        const ivy = std.mem.eql(u8, entry.enemies[0], "ivy") or std.mem.eql(u8, entry.enemies[0], "mad_ivy");
        for (0..3) |variant| {
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(content.value, items.value, &members, 17);
            combat.encounter = index;
            combat.startEncounter();
            combat.integration = .{ .host = host };
            try combat.attachUniteActors(&actors.value);
            try combat.attachSpellScenes(&packet);
            for (combat.progress.party, 0..) |*member, slot| {
                member.max_hp = 5000;
                member.hp = 5000;
                combat.runes[slot] = if (variant == 2) combat.content.systems.?.runeIndex("turtle").? else null;
                combat.actions[slot] = .defend;
            }
            combat.phase = .resolving;
            combat.round_start_pending = false;
            combat.acted = @splat(false);
            combat.coordinator = .{ .stage = .select, .current_actor = 0, .completed = true, .remaining = 0 };
            const initial = members;
            var values: [16384]u15 = @splat(if (variant == 0) 51 else 16384);
            var draws = h.rules.Draws{ .values = &values };
            var slept = false;
            var reduced = false;
            var attempted: u8 = 0;
            var rendered: u8 = 0;
            var ivy_mask: u8 = 0;
            for (entry.enemies, 0..) |enemy_id, slot| {
                if (std.mem.eql(u8, enemy_id, "ivy") or std.mem.eql(u8, enemy_id, "mad_ivy")) ivy_mask |= @as(u8, 1) << @as(u3, @intCast(slot));
            }
            for (0..6000) |_| {
                combat.tickReplay(.{}, &draws) catch |err| {
                    std.debug.print("later {s} variant={d} tick={d}: {s}\n", .{ entry.id, variant, combat.camera_ticks, @errorName(err) });
                    return err;
                };
                for (combat.unite_vm.counter_actions) |maybe| if (maybe) |action| {
                    if (action.attacker >= combat.partyCount()) attempted |= @as(u8, 1) << @as(u3, @intCast(action.attacker - combat.partyCount()));
                };
                for (combat.unite_vm.commander_actions) |maybe| if (maybe) |action| {
                    if (action.action != null and action.action.?.launched) attempted |= @as(u8, 1) << @as(u3, @intCast(action.owner - combat.partyCount()));
                };
                for (combat.accuracy_reduced[0..combat.partyCount()]) |value| reduced = reduced or value;
                for (combat.partyCount()..combat.partyCount() + combat.enemyCount()) |actor| slept = slept or combat.asleep[actor] != 0;
                if (ivy) for (combat.partyCount()..combat.partyCount() + combat.enemyCount()) |actor| {
                    const bit = @as(u8, 1) << @as(u3, @intCast(actor - combat.partyCount()));
                    if (rendered & bit != 0 or actor >= combat.unite_vm.actors.len) continue;
                    const vine = combat.unite_vm.actors[actor].ivy_vine orelse continue;
                    if (!vine.visible) continue;
                    var strips: usize = 0;
                    var leaves: usize = 0;
                    for (0..18) |part| if (battle.layout.uniteAuxiliary(combat, battle.layout.ivy_graphic_offset + actor * 18 + part)) |quad| {
                        try std.testing.expect(!quad.effect and !quad.translucent);
                        if (part < 12) strips += 1 else {
                            try std.testing.expectEqual(@as(f32, 0), quad.depth);
                            leaves += 1;
                        }
                        for (quad.vertices) |point| try std.testing.expect(std.math.isFinite(point.x) and std.math.isFinite(point.y));
                    };
                    try std.testing.expect(strips > 0 and leaves == 6);
                    rendered |= bit;
                };
                if (combat.phase != .resolving) break;
            }
            if (combat.phase != .battle_menu or combat.round != 2) std.debug.print("unfinished {s} variant={d} tick={d} phase={s}\n", .{ entry.id, variant, combat.camera_ticks, @tagName(combat.phase) });
            try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
            try std.testing.expectEqual(bird and variant != 0, slept);
            try std.testing.expectEqual(std.mem.eql(u8, entry.enemies[0], "flying_squirrel") and variant == 0, reduced);
            var damaged = false;
            for (initial, members) |before, after| {
                damaged = damaged or after.hp < before.hp;
                try std.testing.expect(after.hp > 0);
                try std.testing.expectEqualDeep(before.rune_charges, after.rune_charges);
            }
            try std.testing.expectEqual((@as(u8, 1) << @as(u3, @intCast(combat.enemyCount()))) - 1, attempted);
            if (ivy) try std.testing.expectEqual(ivy_mask, rendered);
            if (variant == 0) try std.testing.expect(damaged);
            try std.testing.expect(!combat.hasUniteReturns());
            const settled = members;
            const cursor = draws.cursor;
            // Source shared13 children wait for animation completion, then tear down across menus.
            for (0..256) |_| {
                if (!combat.unite_vm.hasActors()) break;
                try combat.tickReplay(.{}, &draws);
            }
            try std.testing.expectEqualDeep(settled, members);
            try std.testing.expectEqual(cursor, draws.cursor);
            try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
            try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasUniteReturns());
            cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 111), cases);
}

test "later enemy source hurt ward knockout and miss routes finish queued party turns" {
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
    for (names) |name| for (0..4) |variant| {
        const profile = content.value.enemies[content.value.enemyIndex(name).?];
        const orc_parry = variant == 3 and std.mem.eql(u8, name, "orc");
        if (variant == 3 and !profile.dodges_attacks and !orc_parry) continue;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.encounter = try single(content.value, name);
        combat.startEncounter();
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&packet);
        for (combat.progress.party) |*member| {
            member.max_hp = 5000;
            member.hp = 5000;
        }
        combat.phase = .resolving;
        combat.round_start_pending = false;
        combat.acted = @splat(true);
        combat.actions[0] = .{ .attack = 0 };
        combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
        if (variant == 1) combat.protection[combat.partyCount()] = 1;
        if (variant == 2) combat.enemy_hp[0] = 1;
        const initial_hp = combat.enemy_hp[0];
        var values: [4096]u15 = @splat(51);
        values[0] = if (variant == 3) 99 else 0;
        var draws = h.rules.Draws{ .values = &values };
        var parried = false;
        for (0..1500) |_| {
            combat.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("later hurt {s} variant={d} tick={d}: {s}\n", .{ name, variant, combat.camera_ticks, @errorName(err) });
                return err;
            };
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |action| {
                parried = parried or action.kind == .parry;
            };
            if (combat.phase != .resolving) break;
        }
        const expected: @TypeOf(combat.phase) = if (variant == 2 and combat.enemyCount() == 1) .victory else .battle_menu;
        try std.testing.expectEqual(expected, combat.phase);
        if (variant == 1 or variant == 3) try std.testing.expectEqual(initial_hp, combat.enemy_hp[0]) else try std.testing.expect(combat.enemy_hp[0] < initial_hp);
        try std.testing.expectEqual(orc_parry, parried);
        if (orc_parry) try std.testing.expect(members[0].hp < 5000);
        const settled_hp = combat.enemy_hp;
        const settled_members = members;
        const cursor = draws.cursor;
        for (0..512) |_| {
            if (!combat.unite_vm.hasActors()) break;
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqualDeep(settled_hp, combat.enemy_hp);
        try std.testing.expectEqualDeep(settled_members, members);
        try std.testing.expectEqual(cursor, draws.cursor);
        try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasUniteReturns());
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 38), cases);
}

test "later enemy counterable species retain first slot refusal and live second slot counters" {
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
    for ([_][]const u8{ "hell_hound", "grizzly_bear", "orc" }) |name| {
        const index = for (content.value.encounters, 0..) |entry, slot| {
            if (entry.enemies.len == 2 and std.mem.eql(u8, entry.enemies[0], name) and std.mem.eql(u8, entry.enemies[1], name)) break slot;
        } else return error.MissingSourceFormation;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.encounter = index;
        combat.startEncounter();
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&packet);
        combat.progress.party[0].max_hp = 5000;
        combat.progress.party[0].hp = 5000;
        combat.enemy_hp = @splat(5000);
        combat.phase = .resolving;
        combat.round_start_pending = false;
        combat.acted = @splat(true);
        combat.actions[0] = .defend;
        const owner = combat.partyCount() + 1;
        combat.coordinator = .{ .stage = .select, .current_actor = owner, .completed = true };
        var values: [1024]u15 = @splat(24);
        values[0] = 99;
        values[1] = 99;
        var draws = h.rules.Draws{ .values = &values };
        combat.replay_draws = &draws;
        try std.testing.expect(!try combat.counterAvailable(combat.partyCount(), 0));
        try std.testing.expect(try combat.counterAvailable(owner, 0));
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        combat.sourceEnemyDecision(owner);
        combat.replay_draws = null;
        var countered = false;
        for (0..1000) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |action| {
                countered = countered or action.kind == .counter;
            };
            try combat.tickReplay(.{}, &draws);
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(countered and combat.phase == .battle_menu and combat.round == 2);
        try std.testing.expectEqual(@as(u16, 5000), members[0].hp);
        try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[0]);
        try std.testing.expect(combat.enemy_hp[1] < 5000);
        try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasUniteReturns());
    }
}

test "later enemy spell recipients bind their source hurt art and spend one charge" {
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
    const fire = for (content.value.systems.?.spells, 0..) |spell, index| {
        if (std.mem.eql(u8, spell.id, "spell_1")) break index;
    } else return error.MissingSpell;
    for (names) |name| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.encounter = try single(content.value, name);
        combat.startEncounter();
        combat.integration = .{ .host = host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&packet);
        combat.phase = .resolving;
        combat.round_start_pending = false;
        combat.acted = @splat(true);
        combat.actions[0] = .{ .spell = .{ .index = fire, .target = 0 } };
        combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
        const hp = combat.enemy_hp[0];
        const charges = members[0].rune_charges[0];
        var draws = h.rules.Draws{ .bios_state = 17 };
        var scene = false;
        for (0..1200) |_| {
            try combat.tickReplay(.{}, &draws);
            if (combat.active) |active| scene = scene or active.scene != null;
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(scene and (combat.phase == .battle_menu or combat.phase == .victory));
        try std.testing.expect(combat.enemy_hp[0] < hp);
        try std.testing.expectEqual(charges - 1, members[0].rune_charges[0]);
        try std.testing.expect(!combat.hasUniteReturns());
    }
}

test "Orc source painting rewards enter inventory without dropping their identity" {
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    for ([_]h.field.items.Id{ .graffiti, .lover_s_garden, .beauties_of_nature }, 0..) |id, slot| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.encounter = try single(content.value, "orc");
        combat.startEncounter();
        combat.levels = @splat(99);
        combat.experience = @splat(0);
        var values: [256]u15 = @splat(0);
        values[0] = @intCast(slot);
        var draws = h.rules.Draws{ .values = &values };
        combat.replay_draws = &draws;
        combat.commitRewards();
        combat.replay_draws = null;
        try std.testing.expect(combat.drop_received and combat.dropped_item.?.id == id and !combat.dropped_item.?.identified);
        const owner = combat.loot_recipient.?;
        const inventory = members[owner].inventory;
        try std.testing.expectEqual(id, inventory.slots[inventory.count() - 1].?.id);
        try std.testing.expectEqualStrings("? painting", inventory.slots[inventory.count() - 1].?.name());
        try combat.progress.validate();
        try combat.progress.appraise(items.value, owner, inventory.count() - 1);
        try std.testing.expectEqual(id, members[owner].inventory.slots[inventory.count() - 1].?.id);
        try std.testing.expect(members[owner].inventory.slots[inventory.count() - 1].?.identified);
    }
}

test "region B source crystal and equipment rewards preserve inventory identity" {
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    for ([_][]const u8{ "flying_squirrel", "roc" }, [_]h.field.items.Id{ .holy_crystal, .feather }) |name, id| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.encounter = try single(content.value, name);
        combat.startEncounter();
        combat.levels = @splat(99);
        combat.experience = @splat(0);
        var values: [256]u15 = @splat(0);
        var draws = h.rules.Draws{ .values = &values };
        combat.replay_draws = &draws;
        combat.commitRewards();
        combat.replay_draws = null;
        try std.testing.expect(combat.drop_received and combat.dropped_item.?.id == id and combat.dropped_item.?.identified);
        const owner = combat.loot_recipient.?;
        const inventory = members[owner].inventory;
        try std.testing.expectEqual(id, inventory.slots[inventory.count() - 1].?.id);
        try combat.progress.validate();
    }
}

test "Ivy source ornament rewards retain unidentified appraisal and sale state" {
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    for ([_]h.field.items.Id{ .hex_doll, .peeing_boy, .knight_statue }, [_]u32{ 120, 32000, 60000 }, 0..) |id, price, slot| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.encounter = try single(content.value, "ivy");
        combat.startEncounter();
        combat.levels = @splat(99);
        combat.experience = @splat(0);
        var values: [256]u15 = @splat(0);
        values[0] = @intCast(slot);
        var draws = h.rules.Draws{ .values = &values };
        combat.replay_draws = &draws;
        combat.commitRewards();
        combat.replay_draws = null;
        try std.testing.expect(combat.drop_received and combat.dropped_item.?.id == id and !combat.dropped_item.?.identified);
        const owner = combat.loot_recipient.?;
        const index = members[owner].inventory.count() - 1;
        try std.testing.expectEqualStrings("? ornament", members[owner].inventory.slots[index].?.name());
        const money = combat.progress.money;
        try std.testing.expectError(error.CannotSell, combat.progress.sellItem(items.value, owner, index));
        try combat.progress.appraise(items.value, owner, index);
        try std.testing.expect(members[owner].inventory.slots[index].?.identified);
        try combat.progress.sellItem(items.value, owner, index);
        try std.testing.expectEqual(money - 500 + price / 2, combat.progress.money);
    }
}

test "Ivy art roles and scene textures refuse invalid bindings before attachment" {
    const actors = try battle.actor_host.loadBundle(allocator, @embedFile("../fixtures/journey_unites_actor_library.json"));
    defer actors.deinit();
    for (0..4) |variant| {
        var bundle = actors.value;
        const enemies = try allocator.dupe(battle.counter.MeleeEnemy, bundle.counter.?.melee.?.enemies);
        defer allocator.free(enemies);
        const reactions = try allocator.dupe(battle.counter.PartyReaction, bundle.counter.?.melee.?.party_reactions);
        defer allocator.free(reactions);
        bundle.counter.?.melee.?.enemies = enemies;
        for (enemies) |*enemy| if (std.mem.eql(u8, enemy.id, "ivy")) {
            switch (variant) {
                0 => {
                    bundle.schema = "suikoden-unite-actors/29";
                    bundle.enemy_regional = null;
                    bundle.enemy_area_magic = null;
                    bundle.enemy_wave = null;
                    bundle.group_orders = null;
                    bundle.commander = null;
                    bundle.counter.?.party_melee = null;
                    for (reactions) |*reaction| reaction.return_program = null;
                    bundle.counter.?.melee.?.party_reactions = reactions;
                    for (enemies) |*other| {
                        other.projectile = null;
                        if (other.special != null and other.special.?.return_program != null) other.special = null;
                    }
                },
                1 => enemy.vine_art = null,
                2 => enemy.vine_art.?.strip = 65535,
                3 => enemy.vine_art.?.leaf_extents[0][0] = 0,
                else => unreachable,
            }
        };
        try std.testing.expectError(if (variant < 2) error.UnsupportedIvyComposition else error.InvalidCounterBindings, bundle.validate());
    }
    const content = try battle.load(allocator, @embedFile("../fixtures/journey_unites_battle.json"));
    defer content.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    for (0..2) |variant| {
        const graphics = try allocator.dupe(battle.UniteGraphic, content.value.unite_graphics);
        defer allocator.free(graphics);
        const selected = for (graphics) |*graphic| {
            if (std.mem.eql(u8, graphic.id, "ivy")) break graphic;
        } else return error.MissingIvyGraphic;
        const poses = try allocator.dupe(battle.UniteGraphicPose, selected.poses);
        defer allocator.free(poses);
        selected.poses = poses;
        for (poses) |*pose| {
            if (variant == 0 and pose.id == 6) pose.id = 500;
            if (variant == 1 and pose.id == 7) pose.sprite.rect.w = 15;
        }
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        combat.content.unite_graphics = graphics;
        try std.testing.expectError(error.InvalidUniteGraphics, combat.attachUniteActors(&actors.value));
        try std.testing.expect(combat.unite_actors == null);
    }
}
