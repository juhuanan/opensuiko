const std = @import("std");
const war = @import("war");
const session = @import("war_session");

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
}

test "midwar snapshots continue deterministically" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var original = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 19 } });
    defer original.deinit();
    try completeIntro(&original.engine, scenario);
    try original.engine.issueTeam(0, 0);
    try original.engine.tick();
    try original.engine.tick();
    const bytes = try original.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var restored = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 19 }, .snapshot = bytes });
    defer restored.deinit();
    for (0..500) |_| {
        try original.engine.tick();
        try restored.engine.tick();
    }
    try std.testing.expectEqual(original.engine.rng, restored.engine.rng);
    try std.testing.expectEqual(original.engine.enemy, restored.engine.enemy);
    try std.testing.expectEqual(original.engine.troops, restored.engine.troops);
    try std.testing.expectEqual(original.engine.updates, restored.engine.updates);
    for (original.engine.sides, restored.engine.sides) |left, right| {
        try std.testing.expectEqual(left.remaining, right.remaining);
        for (left.units, right.units, 0..) |left_unit, right_unit, index| {
            if (!std.meta.eql(left_unit, right_unit)) {
                std.debug.print("unit {d}: left={any} right={any}\n", .{ index, left_unit, right_unit });
                return error.TestUnexpectedResult;
            }
        }
    }
    const original_final = try original.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(original_final);
    const restored_final = try restored.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(restored_final);
    try std.testing.expectEqualStrings(original_final, restored_final);
}

test "war scouting reveals the next attack and preserves it across save and load" {
    const allocator = std.testing.allocator;
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[1];
    var original = try session.Session.init(allocator, .{ .scenario = scenario, .rng = .{ .state = 0 } });
    defer original.deinit();
    try completeIntro(&original.engine, scenario);
    const before = original.engine.troops;
    var enemy = original.engine.enemy;
    var rng = original.engine.rng;
    const attack = try war.nextEnemyAttack(scenario, &enemy, &rng);

    try original.engine.issueTeam(3, 33);
    try std.testing.expectEqual(@as(?u8, attack), original.engine.scouted_attack);
    try std.testing.expectEqual(@as(u8, 1), original.engine.ninja_scouts_used);
    try std.testing.expectEqual(before, original.engine.troops);
    try std.testing.expectEqual(rng, original.engine.rng);
    const bytes = try original.snapshot(allocator);
    defer allocator.free(bytes);
    var restored = try session.Session.init(allocator, .{ .scenario = scenario, .rng = .{ .state = 0 }, .snapshot = bytes });
    defer restored.deinit();
    try std.testing.expectEqual(original.engine.scouted_attack, restored.engine.scouted_attack);
    try std.testing.expectEqual(original.engine.ninja_scouts_used, restored.engine.ninja_scouts_used);
    try std.testing.expectError(error.InvalidWarCommand, restored.engine.issueTeam(3, 33));

    const expected = try war.resolveOrdinary(scenario, .{ .category = 0, .team = 0, .enemy_attack = attack }, before[0], before[1], &restored.engine.recruited, 0, &rng);
    try restored.engine.issueTeam(0, 0);
    try std.testing.expectEqual(@as(?u8, null), restored.engine.scouted_attack);
    try std.testing.expectEqual(enemy, restored.engine.enemy);
    try std.testing.expectEqual(rng, restored.engine.rng);
    try std.testing.expectEqual(expected.action_code, restored.engine.eventSlice()[0].amount);
}

test "stale snapshots and invalid input are rejected" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var original = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 3 } });
    defer original.deinit();
    const bytes = try original.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.StaleWarSnapshot, session.Session.init(std.testing.allocator, .{ .scenario = packet.value.scenarios[1], .rng = .{ .state = 3 }, .snapshot = bytes }));
    const repeated = original.repeat.advance(.{ .down = true });
    try std.testing.expect(repeated.? == .down);
    try std.testing.expect(original.repeat.advance(.{ .down = true }) == null);
}

test "scripted confirmation and mid-phase restore complete deterministically" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[2];
    var original = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 1 } });
    defer original.deinit();
    while (original.engine.script.?.phase != scenario.lifecycle.wait_phase) try original.update(.{});
    try original.update(.{ .confirm = true });
    try std.testing.expectError(error.InvalidWarCommand, original.engine.confirmScript());
    for (0..20) |_| try original.update(.{});
    const bytes = try original.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var restored = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 1 }, .snapshot = bytes });
    defer restored.deinit();
    try std.testing.expectEqual(original.engine.script.?, restored.engine.script.?);
    while (original.engine.phase != .result) {
        const confirming = original.engine.script.?.phase == scenario.lifecycle.wait_phase;
        try original.update(.{ .confirm = confirming });
        try restored.update(.{ .confirm = confirming });
    }
    try std.testing.expectEqual(war.Outcome.scripted_completion, restored.engine.result.?.outcome);
    try std.testing.expectEqual(original.engine.result.?.receipt, restored.engine.result.?.receipt);
    try std.testing.expectEqual(original.engine.rng, restored.engine.rng);
    const result = try restored.consumeResult(restored.engine.result.?.receipt);
    try std.testing.expectEqual(war.ConsequenceKind.scenario_completed, result.consequences[0].kind);
    try std.testing.expectError(error.WarResultAlreadyConsumed, restored.consumeResult(result.receipt));
    const consumed = try restored.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(consumed);
    var final = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 1 }, .snapshot = consumed });
    defer final.deinit();
    try std.testing.expect(final.engine.result.?.consequences[0].scenario_id.ptr == scenario.id.ptr);
    try std.testing.expectError(error.WarResultAlreadyConsumed, final.consumeResult(result.receipt));
    var parsed = try std.json.parseFromSlice(session.Snapshot, std.testing.allocator, consumed, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    parsed.value.result.?.consequences[3].amount += 1;
    const forged = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(forged);
    try std.testing.expectError(error.InvalidWarSnapshot, session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 1 }, .snapshot = forged }));
}

test "generated session RNG fixtures match the caller boundary" {
    const Case = struct {
        scenario_selector: u8,
        initial_rng_state: u32,
        expected_final_rng_state: u32,
        expected_draws: []const u15,
    };
    const Fixture = struct {
        schema: []const u8,
        packet_content_sha256: []const u8,
        cases: []const Case,
    };
    const packet = try load();
    defer packet.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/tests/fixtures/war_sessions.json", std.testing.allocator, .limited(session.max_snapshot_bytes));
    defer std.testing.allocator.free(bytes);
    const fixture = try std.json.parseFromSlice(Fixture, std.testing.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("suikoden-war-session-fixtures/1", fixture.value.schema);
    try std.testing.expectEqualStrings(packet.value.content_sha256, fixture.value.packet_content_sha256);
    for (fixture.value.cases) |case| {
        try std.testing.expectEqual(case.scenario_selector, packet.value.scenarios[case.scenario_selector].selector);
        var random: war.Random = .{ .state = case.initial_rng_state };
        for (case.expected_draws) |expected| try std.testing.expectEqual(expected, random.next());
        try std.testing.expectEqual(case.expected_final_rng_state, random.state);
        try std.testing.expectEqual(case.expected_draws.len, random.cursor);
    }
}

test "impossible and mismatched snapshots fail before mutation" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var original = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 3 } });
    defer original.deinit();
    const bytes = try original.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(session.Snapshot, std.testing.allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    parsed.value.selected_index = parsed.value.sides[0].total;
    const invalid = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(invalid);
    try std.testing.expectError(error.InvalidWarSnapshot, session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 3 }, .snapshot = invalid }));
    try std.testing.expectError(error.WarResultNotReady, original.consumeResult(0));
}

test "entry and restore validate borrowed roster and wallet inputs" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    const recruited: [108]bool = @splat(true);
    var original = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 3 }, .recruited = &recruited, .bits = 42 });
    defer original.deinit();
    try std.testing.expectEqual(@as(u32, 42), original.engine.bits);
    var missing = recruited;
    missing[0] = false;
    try std.testing.expectError(error.MismatchedWarEntry, session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 3 }, .recruited = &missing }));
    const bytes = try original.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.MismatchedWarEntry, session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 3 }, .bits = 41, .snapshot = bytes }));
    var restored = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 3 }, .recruited = &recruited, .bits = 42, .snapshot = bytes });
    defer restored.deinit();
    try std.testing.expectEqual(@as(u32, 42), restored.engine.bits);
    try std.testing.expectError(error.MismatchedWarEntry, session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 3 }, .initial = scenario.initial, .snapshot = bytes }));
}

test "host applies a result once with a stable receipt" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[2];
    var value = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 1 } });
    defer value.deinit();
    while (value.engine.phase != .result) {
        const confirming = value.engine.script.?.phase == scenario.lifecycle.wait_phase;
        try value.update(.{ .confirm = confirming });
    }
    var host: session.Host = .{ .bits = 100 };
    const receipt = value.engine.result.?.receipt;
    try session.applyResult(&host, &value, receipt);
    try std.testing.expectEqual(war.Outcome.scripted_completion, host.outcome);
    try std.testing.expectEqual(@as(u32, 100), host.bits);
    try std.testing.expectEqual(receipt, host.consumed_receipt);
    try std.testing.expectEqualStrings(scenario.content_sha256, &host.scenario_sha256.?);
    try std.testing.expectError(error.WarResultAlreadyConsumed, session.applyResult(&host, &value, receipt));
    var second = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 1 }, .attempt_id = 2 });
    defer second.deinit();
    while (second.engine.phase != .result) {
        const confirming = second.engine.script.?.phase == scenario.lifecycle.wait_phase;
        try second.update(.{ .confirm = confirming });
    }
    try session.applyResult(&host, &second, receipt);
    try std.testing.expectEqual(@as(usize, 2), host.receipt_count);
}

test "thief reward reaches the host exactly once" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[1];
    var value = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 6 }, .bits = 100 });
    defer value.deinit();
    try completeIntro(&value.engine, scenario);
    value.command_index = 3;
    value.engine.selected_index = 24;
    try value.update(.{ .confirm = true });
    try std.testing.expectEqual(@as(u32, 2100), value.engine.bits);
    var actions: usize = 0;
    while (value.engine.phase != .result and actions < 100) : (actions += 1) try value.engine.issueTeam(3, 35);
    var host: session.Host = .{ .bits = 100 };
    try session.applyResult(&host, &value, value.engine.result.?.receipt);
    try std.testing.expectEqual(@as(u32, 2100), host.bits);
    try std.testing.expectError(error.WarResultAlreadyConsumed, session.applyResult(&host, &value, value.engine.result.?.receipt));
}

test "invalid input is atomic and restart preserves the scenario" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var value = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 19 } });
    defer value.deinit();
    value.command_index = 1;
    const before = value.engine.rng;
    try value.update(.{ .confirm = true });
    try std.testing.expectEqual(before, value.engine.rng);
    try std.testing.expectEqual(@as(u64, 0), value.engine.updates);
    try value.update(.{ .restart = true });
    try std.testing.expectEqualStrings(scenario.id, value.engine.scenario.id);
    try std.testing.expectEqual(@as(u64, 0), value.engine.updates);
    try std.testing.expectEqual(@as(u32, 19), value.engine.rng.state);
}

test "snapshot restart uses the original initial RNG" {
    const packet = try load();
    defer packet.deinit();
    const scenario = packet.value.scenarios[0];
    var original = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 19 }, .attempt_id = 7 });
    defer original.deinit();
    const bytes = try original.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var restored = try session.Session.init(std.testing.allocator, .{ .scenario = scenario, .rng = .{ .state = 999 }, .attempt_id = 7, .snapshot = bytes });
    defer restored.deinit();
    try std.testing.expectEqual(@as(u32, 19), restored.initial_rng.state);
    try restored.update(.{ .restart = true });
    try std.testing.expectEqual(@as(u32, 19), restored.engine.rng.state);
    try std.testing.expectEqual(@as(u64, 8), restored.engine.attempt_id);
}
