const std = @import("std");
const war = @import("war");

fn load() !std.json.Parsed(war.Packet) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/assets/war/scenarios.json", std.testing.allocator, .limited(war.max_json_bytes));
    defer std.testing.allocator.free(bytes);
    return war.load(std.testing.allocator, bytes);
}

fn completeIntro(engine: *war.Engine, scenario: war.Scenario) !void {
    while (engine.phase == .scripted) {
        if (engine.script.?.phase == scenario.lifecycle.wait_phase) {
            try engine.confirmScript();
        } else {
            try engine.tick();
        }
    }
    try std.testing.expect(engine.phase == .player_command);
    try std.testing.expect(engine.script == null);
}

test "all nine source initial forces and attacks validate" {
    const packet = try load();
    defer packet.deinit();
    const player = [_]u8{ 63, 63, 0, 47, 0, 0, 42, 38, 32 };
    const enemy = [_]u8{ 31, 21, 0, 31, 0, 0, 9, 35, 34 };
    const parameters = [_]u32{ 9000, 6000, 12000, 12000, 14000, 14000, 3700, 17000, 20000 };
    const troops_per_record = [_]u16{ 300, 300, 400, 400, 450, 450, 450, 500, 600 };
    for (packet.value.scenarios, 0..) |scenario, index| {
        try std.testing.expectEqual(player[index], scenario.initial.sides[0].total_records);
        try std.testing.expectEqual(enemy[index], scenario.initial.sides[1].total_records);
        try std.testing.expectEqual(parameters[index], scenario.initial.scenario_parameter);
        try std.testing.expectEqual(troops_per_record[index], scenario.troops_per_record);
        try std.testing.expect(scenario.attacks.len >= 3);
        var engine = try war.Engine.init(std.testing.allocator, scenario, .{ .state = 1 });
        defer engine.deinit();
        try engine.tick();
        try std.testing.expect(engine.phase == .scripted);
        try std.testing.expect(engine.updates == 1);
        if (engine.script) |script| try std.testing.expectEqual(@as(u8, 2), script.phase);
    }
}

test "caller RNG is stable and unsupported commands are atomic" {
    const packet = try load();
    defer packet.deinit();
    var engine = try war.Engine.init(std.testing.allocator, packet.value.scenarios[0], .{ .state = 1 });
    defer engine.deinit();
    const before = engine.rng;
    try std.testing.expectError(error.UnsupportedWarSpecial, engine.issue(0, 0, .special, 1, 0));
    try std.testing.expectEqual(before.state, engine.rng.state);
    try std.testing.expectEqual(before.cursor, engine.rng.cursor);
    try std.testing.expectError(error.InvalidWarCommand, engine.issue(2, 0, .move, 1, 0));
    try std.testing.expectEqual(before.state, engine.rng.state);
}

test "all nine scenarios complete through public action paths" {
    const packet = try load();
    defer packet.deinit();
    for (packet.value.scenarios) |scenario| {
        var engine = try war.Engine.init(std.testing.allocator, scenario, .{ .state = 7 });
        defer engine.deinit();
        if (!war.isScripted(scenario)) {
            try completeIntro(&engine, scenario);
            try std.testing.expectEqual(@as(u8, 4), scenario.lifecycle.confirmation_count);
            try std.testing.expectEqual(@as(u64, 1574), engine.updates);
            try engine.tick();
            const before = engine.rng;
            try engine.tick();
            try std.testing.expectEqual(before, engine.rng);
            try std.testing.expectError(error.InvalidWarCommand, engine.issueTeam(1, 0));
            try std.testing.expectError(error.InvalidWarCommand, engine.issueTeam(3, 0));
            try std.testing.expectEqual(before, engine.rng);
            var actions: usize = 0;
            const category: u8 = if (scenario.selector == 3) 2 else 0;
            const team: u8 = if (scenario.selector == 3) 27 else 0;
            while (engine.phase != .result and actions < 100) : (actions += 1) try engine.issueTeam(category, team);
            try std.testing.expect(engine.phase == .result);
            try std.testing.expect(engine.result.?.outcome == .side0_victory or engine.result.?.outcome == .side1_victory);
            try std.testing.expect(engine.result.?.casualties[0] + engine.result.?.casualties[1] > 0);
            try std.testing.expectError(error.WarResultAlreadyResolved, engine.tick());
            continue;
        }
        var iterations: usize = 0;
        while (engine.phase != .result and iterations < 20000) : (iterations += 1) {
            if (engine.phase == .scripted and engine.script.?.phase == scenario.lifecycle.wait_phase) {
                try engine.confirmScript();
            } else {
                try engine.tick();
            }
        }
        try std.testing.expect(engine.phase == .result);
        const result = engine.result.?;
        try std.testing.expect(result.receipt == engine.updates);
        try std.testing.expectEqual(war.Outcome.scripted_completion, result.outcome);
        try std.testing.expectEqual(@as(u64, 1160), result.receipt);
        try std.testing.expectEqual(@as(u8, 2), engine.script.?.confirmations);
        try std.testing.expectEqual(war.ConsequenceKind.scenario_completed, result.consequences[0].kind);
        try std.testing.expectEqual(@as(u32, 0), result.casualties[0] + result.casualties[1]);
        try std.testing.expectError(error.WarResultAlreadyResolved, engine.tick());
    }
}

test "source troop loss and record casualty arithmetic preserves boundaries" {
    try std.testing.expectEqual(@as(u8, 10), war.recordsAfterLoss(10, 0, 300));
    try std.testing.expectEqual(@as(u8, 9), war.recordsAfterLoss(10, 1, 300));
    try std.testing.expectEqual(@as(u8, 9), war.recordsAfterLoss(10, 299, 300));
    try std.testing.expectEqual(@as(u8, 8), war.recordsAfterLoss(10, 300, 300));
    try std.testing.expectEqual(@as(u8, 8), war.recordsAfterLoss(10, 301, 300));
    try std.testing.expectEqual(@as(u8, 8), war.recordsAfterLoss(10, 599, 300));
    try std.testing.expectEqual(@as(u8, 7), war.recordsAfterLoss(10, 600, 300));
    try std.testing.expectEqual(@as(u8, 254), war.recordsAfterLoss(0, 300, 300));
    try std.testing.expectEqual(@as(u8, 9), war.recordsAfterLoss(10, 399, 400));
    try std.testing.expectEqual(@as(u8, 8), war.recordsAfterLoss(10, 400, 400));
    try std.testing.expectEqual(@as(u32, 2700), war.troopsLost(10, 7, 9000));
    try std.testing.expectEqual(@as(u32, 0), war.troopsLost(10, 10, 9000));
    try std.testing.expectEqual(@as(u32, 0), war.troopsLost(10, 11, 9000));
    try std.testing.expectEqual(@as(u32, 9000), war.troopsLost(0, 0, 9000));
}

test "Scarleticia merchants convert troop casualties at the scenario rate" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenario("scarleticia_antidote").?;
    var engine = try war.Engine.init(std.testing.allocator, scenario, .{ .state = 7 });
    defer engine.deinit();
    try completeIntro(&engine, scenario);
    try engine.issueTeam(3, 35);
    try std.testing.expectEqual(@as(u32, 9000), engine.troops[1]);
    try std.testing.expectEqual(@as(u8, 23), engine.sides[1].remaining);
}

test "all 36 team strengths and category filters match source execution" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[1];
    const expected = [_]u8{ 26, 24, 26, 30, 22, 23, 17, 19, 24, 21, 23, 21, 14, 14, 24, 15, 16, 21, 6, 21, 19, 17, 8, 13, 10, 12, 14, 25, 20, 18, 20, 14, 4, 12, 26, 17 };
    const recruited: [108]bool = @splat(true);
    try std.testing.expectEqual(@as(u32, 18710), try war.initialTroops(scenario, &recruited));
    for (expected, 0..) |strength, team| try std.testing.expectEqual(strength, try war.teamStrength(scenario, @intCast(team), &recruited, 0));
    const categories = [_][]const u8{
        &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 23 },
        &.{ 19, 20, 21, 22, 25, 26 },
        &.{ 27, 28, 29, 30, 31 },
        &.{ 24, 32, 33, 34, 35 },
    };
    for (categories, 0..) |teams, category| for (0..36) |team| {
        try std.testing.expectEqual(std.mem.indexOfScalar(u8, teams, @intCast(team)) != null, try war.teamAvailable(scenario, @intCast(team), @intCast(category), &recruited));
    };
    try std.testing.expectEqual(@as(u8, 39), try war.teamStrength(scenario, 0, &recruited, 1));
}

test "all nine ordinary action formulas match source measurements" {
    const packet = try load();
    defer packet.deinit();
    var scenario = packet.value.scenarios[1];
    var attacks: [3]war.Attack = undefined;
    for (&attacks, 0..) |*attack, enemy_type| attack.* = .{ .flags = 0xC00 | @as(u32, @intCast(enemy_type)), .name = "", .parameter0 = 0, .parameter1 = 0 };
    scenario.attacks = &attacks;
    const expected = [3][3][2]i32{
        .{ .{ 1370, 3170 }, .{ 2530, 4130 }, .{ 2400, 0 } },
        .{ .{ 4130, 2530 }, .{ 1230, 2850 }, .{ 0, 3810 } },
        .{ .{ 0, 5200 }, .{ 1650, 0 }, .{ 0, 5200 } },
    };
    const recruited: [108]bool = @splat(true);
    for (0..3) |category| for (0..3) |enemy_type| {
        var rng: war.Random = .{ .state = 0 };
        const result = try war.resolveOrdinary(scenario, .{ .category = @intCast(category), .team = 0, .enemy_attack = @intCast(enemy_type) }, 18710, 6000, &recruited, 0, &rng);
        const draw_counts = [3][3]u8{ .{ 2, 2, 0 }, .{ 2, 2, 1 }, .{ 0, 1, 0 } };
        const player_random: i32 = if (draw_counts[category][enemy_type] == 2) 39 else 0;
        try std.testing.expectEqual(expected[category][enemy_type][0] + player_random, result.remaining_troops[0]);
        try std.testing.expectEqual(expected[category][enemy_type][1], result.remaining_troops[1]);
        try std.testing.expectEqual(([9]u8{ 2, 0, 1, 1, 2, 0, 0, 1, 2 })[category * 3 + enemy_type], result.action_code);
    };
    var rng: war.Random = .{ .state = 1000 };
    const varied = try war.resolveOrdinary(scenario, .{ .category = 0, .team = 0, .enemy_attack = 0 }, 18710, 6000, &recruited, 0, &rng);
    try std.testing.expectEqual(@as(i32, 1384), varied.remaining_troops[0]);
    try std.testing.expectEqual(@as(i32, 3222), varied.remaining_troops[1]);
    try std.testing.expectEqual(@as(u64, 2), rng.cursor);
}

test "enemy attack selection matches the original used-set sequence" {
    const packet = try load();
    defer packet.deinit();
    var state: war.EnemyState = .{};
    var rng: war.Random = .{ .state = 0 };
    const expected = [_]u8{ 0, 3, 1, 2, 4, 0, 1 };
    for (expected) |attack| try std.testing.expectEqual(attack, try war.nextEnemyAttack(packet.value.scenarios[1], &state, &rng));
    try std.testing.expectEqual(@as(u64, 14), rng.cursor);
}

test "special policies preserve source teams, thresholds, boost and merchant loss" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[1];
    const recruited: [108]bool = @splat(true);
    var ninja_rng: war.Random = .{ .state = 0 };
    const ninja = try war.resolveSpecial(scenario, 33, 0, 0, 6000, 6000, &recruited, &ninja_rng);
    try std.testing.expectEqual(war.SpecialKind.ninja, ninja.kind);
    try std.testing.expectEqual(@as(u64, 0), ninja_rng.cursor);
    const strategists = try war.resolveSpecial(scenario, 32, 0, 0, 6000, 6000, &recruited, &ninja_rng);
    try std.testing.expectEqual(@as(u8, 4), strategists.charge_boost);
    var failure_rng: war.Random = .{ .state = 0 };
    const failure = try war.resolveSpecial(scenario, 24, 0, 0, 6000, 6000, &recruited, &failure_rng);
    try std.testing.expectEqual(@as(u32, 0), failure.bits_awarded);
    var success_rng: war.Random = .{ .state = 1000 };
    const success = try war.resolveSpecial(scenario, 24, 0, 999000, 6000, 6000, &recruited, &success_rng);
    try std.testing.expectEqual(@as(u32, 999), success.bits_awarded);
    var merchant_rng: war.Random = .{ .state = 0 };
    const merchant = try war.resolveSpecial(scenario, 35, 0, 0, 6000, 6000, &recruited, &merchant_rng);
    try std.testing.expectEqual(@as(u32, 1500), merchant.enemy_loss);
    const resisted = try war.resolveSpecial(scenario, 35, 3, 0, 6000, 6000, &recruited, &merchant_rng);
    try std.testing.expectEqual(@as(u32, 0), resisted.enemy_loss);
    const dragon_idle = try war.resolveSpecial(scenario, 34, 0, 0, 6000, 6000, &recruited, &merchant_rng);
    try std.testing.expectEqual(@as(u32, 0), dragon_idle.player_loss + dragon_idle.enemy_loss);
    var dragon_rng: war.Random = .{ .state = 1000 };
    const dragon = try war.resolveSpecial(scenario, 34, 0, 0, 6000, 6000, &recruited, &dragon_rng);
    try std.testing.expectEqual(@as(u32, 6750), dragon.player_loss);
    try std.testing.expectEqual(@as(u32, 750), dragon.enemy_loss);
    var quarter_rng: war.Random = .{ .state = 1000 };
    const quarter = try war.resolveSpecial(scenario, 34, 0, 0, 100, 6000, &recruited, &quarter_rng);
    try std.testing.expectEqual(@as(u32, 1600), quarter.player_loss);
    try std.testing.expectEqual(@as(u32, 1500), quarter.enemy_loss);
}
