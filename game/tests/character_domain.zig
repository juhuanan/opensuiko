const std = @import("std");
const game_state = @import("field").game_state;
const systems = @import("battle_rules");
const party = @import("party_session");

fn profile(id: []const u8, name: []const u8) game_state.CharacterProfile {
    return .{ .id = id, .name = name, .growth = @splat(1), .weapon = null, .weapon_range = null, .rune = null, .rune_locked = false };
}

fn findProfile(context: *const anyopaque, count: usize, id: []const u8) ?game_state.CharacterProfile {
    const profiles: [*]const game_state.CharacterProfile = @ptrCast(@alignCast(context));
    for (profiles[0..count]) |candidate| {
        if (std.mem.eql(u8, candidate.id, id)) return candidate;
    }
    return null;
}

fn levelNineteen(template: game_state.CharacterProfile) game_state.Character {
    return .{
        .id = template.id,
        .name = template.name,
        .hp = 18,
        .max_hp = 20,
        .status = .healthy,
        .rune_charges = @splat(0),
        .max_rune_charges = @splat(0),
        .level = 19,
        .experience = 0,
        .base_stats = .{ .attack = 20, .defense = 10, .skill = 8, .speed = 6, .magic = 4 },
        .weapon_level = 1,
        .loadout = .{},
        .rune = null,
    };
}

test "character domain equips gear, attaches runes and levels without a battle" {
    const profiles = [_]game_state.CharacterProfile{ profile("hero", "Hero"), profile("cleo", "Cleo") };
    var tables: systems.Systems = .{
        .spells = &.{},
        .runes = &.{.{ .id = "fire", .name = "Fire", .crystal = "fire_crystal", .spell_names = @splat(""), .spells = @splat(null), .allowed_members = &.{"hero"} }},
        .equipment = &.{.{ .id = "gloves", .name = "Gloves", .category = .accessory, .bonuses = .{ 0, 0, 0, 0, 2, 0, 0, 0 } }},
        .magic_thresholds = @splat(@splat(255)),
        .stat_growth = @splat(0),
        .hp_growth = @splat(0),
        .experience = @splat(0),
        .unite = .{ .name = "Unite", .members = .{ "hero", "cleo" }, .power = 1 },
    };
    tables.magic_thresholds[0][0] = 5;
    tables.stat_growth[4] = 384;
    tables.hp_growth[4] = 640;

    const rules: game_state.CharacterRules = .{ .tables = tables, .profiles = &profiles, .profile_count = profiles.len, .lookup = findProfile };
    var baseline: party.Snapshot = .{ .entry_id = "party", .content_id = "characters", .receipt = "prepare", .baseline_revision = 1 };
    for (profiles, 0..) |template, index| {
        baseline.members[index] = levelNineteen(template);
        baseline.extras[index] = .{ .member_id = template.id };
        baseline.active[index] = template.id;
        baseline.eligible[index] = true;
    }
    baseline.members[0].?.inventory.slots[0] = .{ .id = .gloves, .uses = 0 };
    baseline.members[1].?.inventory.slots[0] = .{ .id = .fire_crystal, .uses = 0 };

    var session = try party.Session.init(rules, baseline, .{});
    try std.testing.expectError(error.IncompatibleRune, session.execute(.{ .attach_rune = .{ .member = "cleo", .owner = "cleo", .slot = 0 } }));
    try std.testing.expectEqualDeep(baseline, session.current);

    try session.execute(.{ .equip = .{ .member = "hero", .slot = .accessory_one, .equipment = 0 } });
    try std.testing.expectError(error.ItemUnavailable, session.execute(.{ .equip = .{ .member = "hero", .slot = .accessory_two, .equipment = 0 } }));
    try session.execute(.{ .attach_rune = .{ .member = "hero", .owner = "cleo", .slot = 0 } });
    const replayed = try party.replay(rules, baseline, .{}, session.result());
    try std.testing.expectEqualDeep(session.current, replayed.current);
    try std.testing.expectEqual(@as(usize, 0), replayed.current.members[1].?.inventory.count());

    var hero = replayed.current.members[0].?;
    try std.testing.expectEqual(@as(?usize, 0), hero.rune);
    try std.testing.expectEqual(@as(u16, 4), hero.base_stats.magic);
    try std.testing.expectEqual(@as(u16, 1), hero.max_rune_charges[0]);
    try std.testing.expectEqual(@as(u16, 0), hero.rune_charges[0]);

    hero.levelUp(tables, profiles[0].growth, @splat(128));
    try rules.validate(hero);
    try std.testing.expectEqual(@as(u8, 20), hero.level);
    try std.testing.expectEqual(@as(u16, 22), hero.base_stats.attack);
    try std.testing.expectEqual(@as(u16, 21), hero.hp);
    try std.testing.expectEqual(@as(u16, 23), hero.max_hp);
    try std.testing.expectEqual(@as(u16, 0), hero.rune_charges[0]);
}
