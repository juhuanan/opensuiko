//! Focused gate: source-supported hit, critical, dodge, counter,
//! protection and status interactions.
//!
//! Pure/port-level only: no original instruction is executed, no emulator or
//! walker is started, no window or media is opened.  The generated packet is
//! read from the repository so its identity and the generated Zig tables cannot
//! drift apart.
//!
//! Covered boundaries:
//!   * accuracy clamp 60/99, mask16 halving, Hazy target halving
//!   * critical clamp 3/25, Killer doubling, 3x damage
//!   * forced hit, parry, dodge, the miss-with-no-capability fall-through
//!   * enemy counter predicate, ordinary landing and dodge
//!   * quarter-HP protection, pair order, 46/10 clocks, failure at impact
//!   * nine independent status classes, copper expiry, cure/exit, poison
//!   * exact draw order, one-time effects, simultaneous impacts and restart

const std = @import("std");
const status_mod = @import("battle_systems").status;
const data = @import("battle_systems").status.data;
const battle_rules = @import("battle_rules");
const rules = status_mod.rules;
const status = status_mod.status;
const interaction = status_mod.interaction;
const coordinator = status_mod.coordinator;

const finite = std.Io.Limit.limited(4 * 1024 * 1024);

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, finite);
}

fn partyMember(native_id: u8, slot: u8, hp: u16, defense: u16) interaction.Combatant {
    return .{
        .native_id = native_id,
        .side = .party,
        .source_slot = slot,
        .hp = hp,
        .max_hp = 100,
        .attack = 20,
        .defense = defense,
        .skill = 100,
        .counter_guard = false,
    };
}

fn enemyMember(native_id: u8, slot: u8, hp: u16) interaction.Combatant {
    return .{
        .native_id = native_id,
        .side = .enemy,
        .source_slot = slot,
        .hp = hp,
        .max_hp = hp,
        .attack = 100,
        .defense = 40,
        .skill = 100,
        .counter_guard = false,
    };
}

fn drawSteps(outcome: *const interaction.Outcome, buffer: *[8]rules.DrawStep) []const rules.DrawStep {
    for (outcome.drawSlice(), 0..) |entry, index| buffer[index] = entry.step;
    return buffer[0..outcome.draw_count];
}

test "generated data is in sync with the interactions packet" {
    const bytes = try readFile(std.testing.allocator, "game/assets/battle_systems/interactions.json");
    defer std.testing.allocator.free(bytes);
    var identity: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&identity, "\"content_sha256\": \"{s}\"", .{data.interactions_sha256});
    try std.testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"pair_count\": 15") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"common_hurt_duration\": 46") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"ward_return_duration\": 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"known_mask\": 49199") != null);
}

test "nine masks are independent and the source table is exact" {
    const expected = [9]u16{ 1, 2, 4, 8, 16, 32, 128, 64, 32768 };
    var combined: u16 = 0;
    for (data.status_masks, 0..) |mask, index| {
        try std.testing.expectEqual(expected[index], mask);
        try std.testing.expectEqual(mask, status.maskOf(@fromBackingInt(@intCast(index))));
        try std.testing.expect(data.status_names[index].len != 0);
        try std.testing.expectEqual(@as(u16, 0), combined & mask);
        combined |= mask;
    }
    try std.testing.expectEqual(@as(u16, 0x80FF), combined);
    try std.testing.expectEqual(@as(u16, 0x800F), data.interaction_feature_mask);
    try std.testing.expectEqual(@as(u16, 0xC02F), data.known_feature_mask);
}

test "party hit follows accuracy, critical and variance in that order" {
    const attacker = interaction.Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 100, .defense = 20, .skill = 255, .luck = 255 };
    const defender = enemyMember(3, 8, 100);
    var draws = battle_rules.Draws{ .values = &.{ 0, 0, 0 } };
    var log = rules.DrawLog{};
    const outcome = try interaction.resolvePhysical(attacker, defender, &.{}, 6, &draws, &log);
    try std.testing.expectEqual(interaction.Branch.critical, outcome.branch);
    try std.testing.expect(outcome.critical);
    try std.testing.expectEqual(rules.physicalDamage(100, 40, 0, false) * data.critical_damage_multiplier, outcome.computed_damage);
    var buffer: [8]rules.DrawStep = undefined;
    try std.testing.expectEqualSlices(rules.DrawStep, &.{ .accuracy, .critical, .physical_variance }, drawSteps(&outcome, &buffer));
}

test "a party miss with no defender capability still reaches the ordinary initializer" {
    const attacker = interaction.Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 100, .defense = 20, .skill = 0, .luck = 0 };
    const defender = enemyMember(3, 8, 100);
    var draws = battle_rules.Draws{ .values = &.{ 99, 99, 0 } };
    var log = rules.DrawLog{};
    const outcome = try interaction.resolvePhysical(attacker, defender, &.{}, 6, &draws, &log);
    try std.testing.expectEqual(interaction.Branch.hit, outcome.branch);
    try std.testing.expect(!outcome.critical);
    var buffer: [8]rules.DrawStep = undefined;
    try std.testing.expectEqualSlices(rules.DrawStep, &.{ .accuracy, .critical, .physical_variance }, drawSteps(&outcome, &buffer));
}

test "parry, dodge and forced hit select the source callbacks" {
    const attacker = interaction.Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 100, .defense = 20, .skill = 0, .luck = 0, .can_be_parried = true };
    var defender = enemyMember(3, 8, 100);
    defender.features = data.feature_parry;
    var parry_draws = battle_rules.Draws{ .values = &.{99} };
    var log = rules.DrawLog{};
    const parried = try interaction.resolvePhysical(attacker, defender, &.{}, 6, &parry_draws, &log);
    try std.testing.expectEqual(interaction.Branch.parry, parried.branch);
    try std.testing.expectEqual(@as(u32, 0x800F5DB4), parried.reaction.?.callback);
    try std.testing.expectEqual(@as(usize, 1), parried.draw_count);

    var ranged_attacker = attacker;
    ranged_attacker.can_be_parried = false;
    var ranged_draws = battle_rules.Draws{ .values = &.{ 99, 99, 0 } };
    var ranged_log = rules.DrawLog{};
    const ranged = try interaction.resolvePhysical(ranged_attacker, defender, &.{}, 6, &ranged_draws, &ranged_log);
    try std.testing.expectEqual(interaction.Branch.hit, ranged.branch);
    try std.testing.expectEqual(@as(usize, 3), ranged_draws.cursor);

    defender.features = data.feature_dodge;
    var dodge_draws = battle_rules.Draws{ .values = &.{99} };
    var dodge_log = rules.DrawLog{};
    const dodged = try interaction.resolvePhysical(attacker, defender, &.{}, 6, &dodge_draws, &dodge_log);
    try std.testing.expectEqual(interaction.Branch.dodge, dodged.branch);
    try std.testing.expectEqual(@as(u32, 0x800F5C1C), dodged.reaction.?.callback);

    defender.features = data.feature_forced_hit | data.feature_dodge;
    var forced_draws = battle_rules.Draws{ .values = &.{ 0, 0 } };
    var forced_dodge_log = rules.DrawLog{};
    const forced_dodge = try interaction.resolvePhysical(attacker, defender, &.{}, 6, &forced_draws, &forced_dodge_log);
    try std.testing.expectEqual(interaction.Branch.dodge, forced_dodge.branch);
    try std.testing.expectEqual(@as(usize, 0), forced_dodge_log.countOf(.accuracy));

    defender.features = data.feature_forced_hit;
    var critical_draws = battle_rules.Draws{ .values = &.{ 0, 0 } };
    var forced_log = rules.DrawLog{};
    const forced = try interaction.resolvePhysical(attacker, defender, &.{}, 6, &critical_draws, &forced_log);
    try std.testing.expectEqual(interaction.Branch.critical, forced.branch);
    try std.testing.expectEqual(@as(usize, 0), forced_log.countOf(.accuracy));
}

test "enemy misses select counter, ordinary landing or dodge" {
    const target = partyMember(8, 1, 100, 10);
    var counterer = target;
    counterer.counter_guard = true;
    counterer.defending = false;
    var attacker = enemyMember(3, 8, 100);
    attacker.source_slot = 8;
    attacker.features = data.feature_counter_eligible;

    var draws = battle_rules.Draws{ .values = &.{ 99, 1 } };
    var log = rules.DrawLog{};
    const countered = try interaction.resolvePhysical(attacker, counterer, &.{}, 6, &draws, &log);
    try std.testing.expectEqual(interaction.Branch.counter, countered.branch);
    try std.testing.expectEqual(@as(u32, 0x800F5DB4), countered.reaction.?.callback);
    var buffer: [8]rules.DrawStep = undefined;
    try std.testing.expectEqualSlices(rules.DrawStep, &.{ .accuracy, .counter_availability }, drawSteps(&countered, &buffer));

    var rune_target = counterer;
    rune_target.rune = data.counter_rune;
    var rune_draws = battle_rules.Draws{ .values = &.{99} };
    var rune_log = rules.DrawLog{};
    const guaranteed = try interaction.resolvePhysical(attacker, rune_target, &.{}, 6, &rune_draws, &rune_log);
    try std.testing.expectEqual(interaction.Branch.counter, guaranteed.branch);
    try std.testing.expectEqual(@as(usize, 0), rune_log.countOf(.counter_availability));

    var landing_target = target;
    landing_target.counter_guard = true;
    landing_target.target_record_flags = data.feature_ordinary_landing;
    attacker.features = 0;
    var landing_draws = battle_rules.Draws{ .values = &.{ 99, 0 } };
    var landing_log = rules.DrawLog{};
    const landing = try interaction.resolvePhysical(attacker, landing_target, &.{}, 6, &landing_draws, &landing_log);
    try std.testing.expectEqual(interaction.Branch.hit, landing.branch);

    var dodge_draws = battle_rules.Draws{ .values = &.{99} };
    var dodge_log = rules.DrawLog{};
    const dodged = try interaction.resolvePhysical(attacker, target, &.{}, 6, &dodge_draws, &dodge_log);
    try std.testing.expectEqual(interaction.Branch.dodge, dodged.branch);
}

test "protection triggers strictly below a quarter HP and redirects the strike" {
    const hero = partyMember(8, 1, 24, 10);
    const gremio = partyMember(2, 2, 100, 40);
    var party = [_]interaction.Combatant{ hero, gremio };
    const attacker = enemyMember(9, 8, 100);
    var draws = battle_rules.Draws{ .values = &.{ 0, 0 } };
    var log = rules.DrawLog{};
    const outcome = try interaction.resolvePhysical(attacker, party[0], &party, 2, &draws, &log);
    try std.testing.expectEqual(interaction.Branch.protected, outcome.branch);
    try std.testing.expectEqual(@as(?usize, 1), outcome.protector);
    var buffer: [8]rules.DrawStep = undefined;
    try std.testing.expectEqualSlices(rules.DrawStep, &.{ .accuracy, .physical_variance }, drawSteps(&outcome, &buffer));

    party[0].hp = 25;
    var equal_draws = battle_rules.Draws{ .values = &.{ 0, 0 } };
    var equal_log = rules.DrawLog{};
    const equal = try interaction.resolvePhysical(attacker, party[0], &party, 2, &equal_draws, &equal_log);
    try std.testing.expectEqual(interaction.Branch.hit, equal.branch);
    try std.testing.expectEqual(@as(?usize, null), equal.protector);

    var edge = party[0];
    edge.max_hp = 101;
    edge.hp = 25;
    try std.testing.expect(!interaction.belowQuarter(edge));
    edge.hp = 24;
    try std.testing.expect(interaction.belowQuarter(edge));
}

test "boundary HP, deferred KO and sleeping/unbalanced attackers" {
    var target = partyMember(8, 1, 5, 10);
    target.status.mask |= status.maskOf(.poison) | status.maskOf(.sleep);
    var log = rules.DrawLog{};
    var draws = battle_rules.Draws{ .values = &.{} };
    const overkill = interaction.applyDamage(&target, 9);
    try std.testing.expectEqual(@as(u32, 5), overkill.applied);
    try std.testing.expectEqual(@as(u16, 0), target.hp);
    try std.testing.expect(overkill.knocked_out);
    try std.testing.expect(interaction.commitKnockout(&target));
    try std.testing.expect(!target.active);
    try std.testing.expectEqual(@as(u16, 0), target.status.mask);
    try std.testing.expect(!interaction.commitKnockout(&target));

    const enemy = enemyMember(9, 8, 100);
    var sleeper = partyMember(2, 2, 100, 10);
    sleeper.status.mask |= status.maskOf(.sleep);
    try std.testing.expectError(error.ActorCannotAct, interaction.resolvePhysical(sleeper, enemy, &.{}, 6, &draws, &log));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);

    var unbalanced = partyMember(2, 2, 100, 10);
    unbalanced.status.mask |= status.maskOf(.recovery);
    try std.testing.expectError(error.ActorCannotAct, interaction.resolvePhysical(unbalanced, enemy, &.{}, 6, &draws, &log));

    var ko = partyMember(2, 2, 100, 10);
    ko.active = false;
    try std.testing.expectError(error.ActorCannotAct, interaction.resolvePhysical(ko, enemy, &.{}, 6, &draws, &log));
}

test "class 8 protection blocks every HP delta" {
    var target = partyMember(8, 1, 50, 10);
    target.status.mask |= status.maskOf(.protection);
    const blocked_damage = interaction.applyDamage(&target, 30);
    try std.testing.expect(blocked_damage.blocked);
    try std.testing.expectEqual(@as(u32, 0), blocked_damage.applied);
    try std.testing.expectEqual(@as(u16, 50), target.hp);
    const blocked_heal = interaction.applyHeal(&target, 30);
    try std.testing.expect(blocked_heal.blocked);
    try std.testing.expectEqual(@as(u16, 50), target.hp);
}

test "status classes keep independent ailments, durations and one-time expiry" {
    var target = partyMember(8, 1, 100, 10);
    var draws = battle_rules.Draws{ .values = &.{ 0, 0, 0, 0, 0, 0 } };
    var log = rules.DrawLog{};
    _ = try target.status.apply(.{ .class = .poison }, true, false, false, &draws, &log);
    _ = try target.status.apply(.{ .class = .accuracy_reduced }, true, false, false, &draws, &log);
    _ = try target.status.apply(.{ .class = .sleep, .boundaries = 2 }, true, false, false, &draws, &log);
    _ = try target.status.apply(.{ .class = .recovery, .boundaries = 1 }, true, false, false, &draws, &log);
    _ = try target.status.apply(.{ .class = .protection }, true, false, false, &draws, &log);
    try std.testing.expect(target.status.has(.poison));
    try std.testing.expect(target.status.has(.accuracy_reduced));
    try std.testing.expect(target.status.has(.sleep));
    try std.testing.expect(target.status.has(.recovery));
    try std.testing.expect(target.status.has(.protection));
    try std.testing.expectEqual(@as(usize, 5), log.count);

    target.status.cureGeneral();
    try std.testing.expect(!target.status.has(.poison));
    try std.testing.expect(!target.status.has(.sleep));
    try std.testing.expect(target.status.has(.recovery));
    try std.testing.expect(target.status.has(.protection));
    _ = try target.status.apply(.{ .class = .poison }, true, false, false, &draws, &log);

    var boundary_log = rules.DrawLog{};
    const first = try status.boundary(&target.status, 100, true, &draws, &boundary_log);
    try std.testing.expect(!first.copper_expired);
    try std.testing.expect(first.recovery_expired);
    const second = try status.boundary(&target.status, 100, true, &draws, &boundary_log);
    try std.testing.expect(!second.copper_expired);
    const third = try status.boundary(&target.status, 100, true, &draws, &boundary_log);
    try std.testing.expect(third.copper_expired);
    try std.testing.expectEqual(@as(u16, 100 / data.poison_divisor), third.poison_damage);
}

test "coordinator protects, defers knockout and fires the ward return once" {
    const hero = partyMember(8, 1, 24, 10);
    const gremio = partyMember(2, 2, 40, 40);
    const enemy = enemyMember(9, 8, 100);
    var party = [_]interaction.Combatant{ hero, gremio, enemy };
    var draws = battle_rules.Draws{ .values = &.{} };
    var coordinator_state = coordinator.Coordinator.init(&party, &draws);
    const impact: u16 = 10;
    const protector_release = impact + data.common_hurt_duration - 1;
    const ward_start = protector_release + 1;
    const ward_end = ward_start + data.ward_return_duration;
    _ = try coordinator_state.begin(.{
        .id = 1,
        .owner = 2,
        .target = 0,
        .protector = 1,
        .branch = .protected,
        .impact = impact,
        .target_release = ward_end,
        .owner_release = 90,
        .protector_release = protector_release,
        .ward_return_start = ward_start,
        .ward_return_end = ward_end,
        .amount = 100,
    });
    try coordinator_state.advance(impact);
    try std.testing.expectEqual(@as(u16, 0), party[1].hp);
    try std.testing.expect(party[1].active);
    try std.testing.expectEqual(@as(u16, 24), party[0].hp);
    coordinator_state.clearEvents();
    try coordinator_state.advance(ward_end);
    var ward_returns: usize = 0;
    var protector_releases: usize = 0;
    for (coordinator_state.eventSlice()) |event| {
        if (event.tag == .ward_return) ward_returns += 1;
        if (event.tag == .protector_release) {
            protector_releases += 1;
            try std.testing.expect(event.knocked_out);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), ward_returns);
    try std.testing.expectEqual(@as(usize, 1), protector_releases);
    try std.testing.expect(!party[1].active);
    try std.testing.expectEqual(@as(u16, 0), party[1].status.mask);
    try std.testing.expect(!party[1].locked);
    try std.testing.expect(!party[0].locked);
}

test "protection failure at impact leaves both members and releases intact" {
    const hero = partyMember(8, 1, 24, 10);
    const gremio = partyMember(2, 2, 40, 40);
    const enemy = enemyMember(9, 8, 100);
    var party = [_]interaction.Combatant{ hero, gremio, enemy };
    var draws = battle_rules.Draws{ .values = &.{} };
    var coordinator_state = coordinator.Coordinator.init(&party, &draws);
    const impact: u16 = 5;
    const protector_release = impact + data.common_hurt_duration - 1;
    const ward_start = protector_release + 1;
    const ward_end = ward_start + data.ward_return_duration;
    _ = try coordinator_state.begin(.{
        .id = 1,
        .owner = 2,
        .target = 0,
        .protector = 1,
        .branch = .protected,
        .impact = impact,
        .target_release = ward_end,
        .owner_release = 90,
        .protector_release = protector_release,
        .ward_return_start = ward_start,
        .ward_return_end = ward_end,
        .amount = 100,
    });
    party[1].locked = true; // another action took the protector before impact
    try coordinator_state.advance(impact);
    try std.testing.expectEqual(coordinator.Tag.protection_failed, coordinator_state.eventSlice()[0].tag);
    try std.testing.expectEqual(@as(u16, 24), party[0].hp);
    try std.testing.expectEqual(@as(u16, 40), party[1].hp);
    coordinator_state.clearEvents();
    try coordinator_state.advance(ward_end);
    try std.testing.expect(!party[0].locked);
    try std.testing.expectEqual(@as(usize, 0), coordinator_state.log.count);
}

test "simultaneous impacts preserve begin order and locks" {
    const first = partyMember(8, 1, 100, 10);
    const second = partyMember(2, 2, 100, 10);
    const enemy_one = enemyMember(3, 8, 100);
    const enemy_two = enemyMember(4, 9, 100);
    var party = [_]interaction.Combatant{ first, second, enemy_one, enemy_two };
    var draws = battle_rules.Draws{ .values = &.{} };
    var coordinator_state = coordinator.Coordinator.init(&party, &draws);
    _ = try coordinator_state.begin(.{ .id = 1, .owner = 0, .target = 2, .branch = .hit, .impact = 7, .target_release = 20, .owner_release = 30, .amount = 25 });
    _ = try coordinator_state.begin(.{ .id = 2, .owner = 1, .target = 3, .branch = .hit, .impact = 7, .target_release = 21, .owner_release = 31, .amount = 40 });
    try coordinator_state.advance(7);
    try std.testing.expectEqual(@as(usize, 2), coordinator_state.event_count);
    try std.testing.expectEqual(@as(u8, 1), coordinator_state.eventSlice()[0].frame);
    try std.testing.expectEqual(@as(u32, 25), coordinator_state.eventSlice()[0].amount);
    try std.testing.expectEqual(@as(u32, 40), coordinator_state.eventSlice()[1].amount);
    try std.testing.expectEqual(@as(u16, 75), party[2].hp);
    try std.testing.expectEqual(@as(u16, 60), party[3].hp);
}

test "unknown branches refuse without consuming draws or degrading to an attack" {
    const attacker = interaction.Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 100, .defense = 20, .skill = 100, .luck = 0 };
    var defender = enemyMember(3, 8, 100);
    var draws = battle_rules.Draws{ .values = &.{ 0, 0, 0 } };
    var log = rules.DrawLog{};
    defender.features = 0x0010;
    try std.testing.expectError(error.UnsupportedFeatureMask, interaction.resolvePhysical(attacker, defender, &.{}, 6, &draws, &log));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try std.testing.expectEqual(@as(usize, 0), log.count);

    var parry = defender;
    parry.features = data.feature_parry;
    try std.testing.expectError(error.MissingParryCapability, interaction.resolvePhysical(attacker, parry, &.{}, 6, &draws, &log));

    var phero = partyMember(8, 1, 10, 10);
    phero.rune = 26;
    phero.counter_guard = false;
    const enemy = enemyMember(9, 8, 100);
    try std.testing.expectError(error.MissingProtectionCharacterType, interaction.resolvePhysical(enemy, phero, &.{phero}, 6, &draws, &log));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);

    var target = partyMember(8, 1, 100, 10);
    target.counter_guard = null;
    var target_draws = battle_rules.Draws{ .values = &.{0} };
    var target_log = rules.DrawLog{};
    try std.testing.expectError(error.MissingCounterGuard, interaction.resolvePhysical(enemy, target, &.{}, 6, &target_draws, &target_log));

    target.counter_guard = true;
    try std.testing.expectError(error.MissingDuration, target.status.apply(.{ .class = .recovery }, true, false, false, &target_draws, &target_log));
}

test "snapshot restart replays only the remaining lifetime" {
    const hero = partyMember(8, 1, 80, 10);
    const enemy = enemyMember(9, 8, 100);
    var party = [_]interaction.Combatant{ hero, enemy };
    var draws = battle_rules.Draws{ .values = &.{} };
    var original = coordinator.Coordinator.init(&party, &draws);
    _ = try original.begin(.{ .id = 1, .owner = 1, .target = 0, .branch = .hit, .impact = 9, .target_release = 19, .owner_release = 29, .amount = 15 });
    try original.advance(9);
    const snapshot = original.snapshot();

    var restored_party = [_]interaction.Combatant{ hero, enemy };
    var restored_draws = battle_rules.Draws{ .values = &.{} };
    var restored = coordinator.Coordinator.init(&restored_party, &restored_draws);
    try restored.restore(snapshot);
    original.clearEvents();
    try original.advance(29);
    try restored.advance(29);
    try std.testing.expectEqual(@as(u16, 65), restored_party[0].hp);
    try std.testing.expectEqual(original.event_count, restored.event_count);
    try std.testing.expectEqual(original.eventSlice().len, restored.eventSlice().len);
}

test "Phero selector agrees with the retained 144 source protection witnesses" {
    // Existing oracle metadata is a measuring instrument; no original instructions run here.
    const Case = struct { target: usize, hp: u16, dead_mask: u8, phero: bool, ids: [6][]const u8, protector: ?usize };
    const parsed = try std.json.parseFromSlice([]const Case, std.testing.allocator, @embedFile("../fixtures/world_protection.json"), .{});
    defer parsed.deinit();
    const ids = std.StaticStringMap(u8).initComptime(.{ .{ "hero", 8 }, .{ "gremio", 2 }, .{ "pahn", 6 }, .{ "cleo", 1 }, .{ "viktor", 35 }, .{ "yam_koo", 38 }, .{ "tai_ho", 32 } });
    try std.testing.expectEqual(@as(usize, 144), parsed.value.len);
    for (parsed.value) |row| {
        var party: [6]interaction.Combatant = undefined;
        for (row.ids, 0..) |id, index| {
            party[index] = partyMember(ids.get(id).?, @intCast(index + 1), if (index == row.target) row.hp else 100, 40);
            party[index].character_type = @intFromBool(std.mem.eql(u8, id, "cleo"));
            party[index].active = row.dead_mask & (@as(u8, 1) << @intCast(index)) == 0;
        }
        party[row.target].rune = if (row.phero) 26 else 0;
        try std.testing.expectEqual(row.protector, try interaction.selectProtector(party[row.target], &party));
    }
}

test "Phero wraps before its ward checks live locks and ignores pending HP and sleep" {
    var ward = partyMember(35, 3, 24, 10);
    ward.rune = 26;
    ward.character_type = 0;
    var party = [_]interaction.Combatant{ partyMember(38, 1, 0, 50), partyMember(32, 2, 100, 20), ward };
    party[0].character_type = 1;
    party[0].pending_damage = 100;
    party[0].status.mask = status.maskOf(.sleep) | status.maskOf(.recovery);
    party[1].character_type = 0;
    try std.testing.expectEqual(@as(?usize, 0), try interaction.selectProtector(ward, &party));
    party[0].locked = true;
    try std.testing.expectEqual(@as(?usize, null), try interaction.selectProtector(ward, &party));
    party[0].locked = false;
    party[0].active = false;
    try std.testing.expectEqual(@as(?usize, null), try interaction.selectProtector(ward, &party));
    party[0].active = true;
    party[0].character_type = null;
    try std.testing.expectError(error.MissingProtectionCharacterType, interaction.selectProtector(ward, &party));
    ward.hp = 25;
    try std.testing.expectEqual(@as(?usize, null), try interaction.selectProtector(ward, &party));
    // Relationship selection precedes missing Phero type data.
    ward = partyMember(8, 3, 24, 10);
    ward.rune = 26;
    party[0] = partyMember(2, 1, 100, 40);
    try std.testing.expectEqual(@as(?usize, 0), try interaction.selectProtector(ward, &party));
}

test "Phero missing data restores accuracy draws and valid misses fall back to ordinary damage" {
    var target = partyMember(35, 1, 24, 10);
    target.rune = 26;
    target.counter_guard = false;
    var candidate = partyMember(38, 2, 100, 70);
    var party = [_]interaction.Combatant{ target, candidate };
    const enemy = enemyMember(9, 8, 100);
    var draws = battle_rules.Draws{ .values = &.{ 0, 123 } };
    var log = rules.DrawLog{};
    try std.testing.expectError(error.MissingProtectionCharacterType, interaction.resolvePhysical(enemy, target, &party, 2, &draws, &log));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try std.testing.expectEqual(@as(usize, 0), log.count);
    target.character_type = 0;
    candidate.character_type = 0;
    party = .{ target, candidate };
    const ordinary = try interaction.resolvePhysical(enemy, target, &party, 2, &draws, &log);
    try std.testing.expectEqual(interaction.Branch.hit, ordinary.branch);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    draws.cursor = 0;
    log = .{};
    candidate.character_type = 1;
    candidate.defending = true;
    party[1] = candidate;
    const covered = try interaction.resolvePhysical(enemy, target, &party, 2, &draws, &log);
    try std.testing.expectEqual(interaction.Branch.protected, covered.branch);
    try std.testing.expectEqual(@as(?usize, 1), covered.protector);
    try std.testing.expectEqual(rules.physicalDamage(enemy.attack, candidate.defense, 123, true), covered.computed_damage);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
}
