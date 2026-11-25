//! Focused gate: resolved enemy decision/effect families applied
//! through the base enemy-policy path.
//!
//! Expectations come from the embedded campaign asset, which
//! the independent Python planner in the extraction pipeline generates.
//! Nothing here executes an original instruction or a legacy test.

const std = @import("std");
const root = @import("battle_systems").enemy;
const packet = root.catalogue;
const enemy_policy_mod = @import("campaign_policies").enemy_policy;
const systems = @import("battle_rules");

const allocator = std.testing.allocator;

test "enemy draw conversions retain all source roll endpoints" {
    for (0..32768) |raw| {
        const roll: u15 = @intCast(raw);
        const value: u32 = @intCast(raw);
        const scaled = value * 100 / 32767;
        try std.testing.expectEqual(value % 100, try root.drawValue("percent_100", roll));
        try std.testing.expectEqual(scaled, try root.drawValue("scale_100_32767", roll));
        try std.testing.expectEqual(scaled % 100, try root.drawValue("scale_100_32767_mod_100", roll));
        try std.testing.expectEqual(scaled % 100, enemy_policy_mod.drawValue(.scale_100_32767_mod_100, roll));
    }
    try std.testing.expectError(error.UnknownDrawKind, root.drawValue("unknown", 0));
}

test "enemy source ordered scans preserve rows locks pending and draw counts" {
    const parsed = try enemy_policy_mod.load(allocator);
    defer parsed.deinit();
    for ([_][]const u8{ "area_a.enemy.01", "area_a.enemy.03", "area_b.enemy.02", "area_c.enemy.01" }) |id| {
        const record = parsed.value.record(id).?;
        const front_only = !std.mem.eql(u8, id, "area_a.enemy.03");
        for ([_]bool{ false, true }) |swap_rows| {
            for ([_]u6{ 0, 7, 21, 63 }) |down| {
                for ([_]u6{ 0, 9, 63 }) |locks| {
                    for ([_]u15{ 0, 50, 51, 99, 255 }) |roll| {
                        var rows: [6]enemy_policy_mod.PartyRow = undefined;
                        var expected: ?u8 = null;
                        var eligible = false;
                        var used: usize = 0;
                        for (&rows, 0..) |*row, slot| {
                            const mask = @as(u6, 1) << @as(u3, @intCast(slot));
                            row.* = .{ .slot = @intCast(slot), .front = (slot < 3) != swap_rows, .active = down & mask == 0, .locked = locks & mask != 0 };
                            if (expected != null or !row.active or (front_only and !row.front)) continue;
                            eligible = true;
                            if (row.locked) continue;
                            used += 1;
                            if (roll % 100 >= 51) expected = row.slot;
                        }
                        const values: [6]u15 = @splat(roll);
                        var draws = systems.Draws{ .values = &values };
                        const outcome = try enemy_policy_mod.decide(record, &rows, .{ .slot = 0, .front = true }, &draws);
                        if (expected) |target| {
                            try std.testing.expect(outcome == .attack);
                            try std.testing.expectEqual(target, outcome.attack.target_slot);
                        } else if (eligible) {
                            try std.testing.expect(outcome == .pending and outcome.pending.eligible_seen);
                        } else try std.testing.expect(outcome == .disabled);
                        try std.testing.expectEqual(used, draws.cursor);
                    }
                }
            }
        }
    }
}

test "enemy front scan keeps locked targets pending without drawing or selecting a rear member" {
    const parsed = try enemy_policy_mod.load(allocator);
    defer parsed.deinit();
    const record = parsed.value.record("area_c.enemy.01") orelse return error.MissingEnemyRecord;
    var draws = systems.Draws{};
    const rows = [_]enemy_policy_mod.PartyRow{
        .{ .slot = 0, .front = true, .active = true, .locked = true },
        .{ .slot = 3, .front = false, .active = true, .locked = false },
    };
    const decision = try enemy_policy_mod.decide(record, &rows, .{ .slot = 0, .front = true }, &draws);
    try std.testing.expect(decision == .pending and decision.pending.eligible_seen);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "Rabbit shared planner scales every random slot and keeps locked fronts pending" {
    const parsed = try root.load(allocator);
    defer parsed.deinit();
    const base = try enemy_policy_mod.load(allocator);
    defer base.deinit();
    var rows: [6]enemy_policy_mod.PartyRow = undefined;
    for (&rows, 0..) |*row, slot| row.* = .{ .slot = @intCast(slot), .front = slot < 3, .active = true, .locked = false };
    for (1..7) |count| for (0..32768) |raw| {
        const values = [_]u15{ 20000, @intCast(raw) };
        var draws = systems.Draws{ .values = &values };
        const outcome = try root.decide(&parsed.value, &base.value, "area_b.enemy.01", rows[0..count], .{ .slot = 0, .front = true }, @intCast(count), &draws);
        try std.testing.expect(outcome == .special);
        try std.testing.expectEqual(@as(u8, @intCast((raw * 100 / 32767) % count)), outcome.special.target_slot.?);
        try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    };
    rows[0].locked = true;
    for ([_]bool{ false, true }) |special_attempt| {
        const values: []const u15 = if (special_attempt) &.{ 20000, 0 } else &.{0};
        var draws = systems.Draws{ .values = values };
        const outcome = try root.decide(&parsed.value, &base.value, "area_b.enemy.01", rows[0..1], .{ .slot = 0, .front = true }, 1, &draws);
        try std.testing.expect(outcome == .pending);
        try std.testing.expectEqual(values.len, draws.cursor);
    }
    // A later scan of the same owner can proceed after the target unlocks.
    rows[0].locked = false;
    var retry = systems.Draws{ .values = &.{ 0, 17000 } };
    const resumed = try root.decide(&parsed.value, &base.value, "area_b.enemy.01", rows[0..1], .{ .slot = 0, .front = true }, 1, &retry);
    try std.testing.expect(resumed == .attack and resumed.attack.target_slot == 0 and retry.cursor == 2);
    rows[0].active = false;
    var inactive = systems.Draws{ .values = &.{0} };
    const disabled = try root.decide(&parsed.value, &base.value, "area_b.enemy.01", rows[0..1], .{ .slot = 0, .front = true }, 1, &inactive);
    try std.testing.expect(disabled == .disabled and inactive.cursor == 1);
    for ([_][]const u15{ &.{}, &.{20000} }) |values| {
        var exhausted = systems.Draws{ .values = values };
        try std.testing.expectError(error.RandomInputExhausted, root.decide(&parsed.value, &base.value, "area_b.enemy.01", rows[0..1], .{ .slot = 0, .front = true }, 1, &exhausted));
        try std.testing.expectEqual(@as(usize, 0), exhausted.cursor);
    }
}

const Vectors = struct {
    schema: []const u8,
    source: Source,
    decisions: []const DecisionCase,
    effects: []const EffectCase,
};

const Source = struct {
    packet_schema: []const u8,
    effects_sha256: []const u8,
    note: []const u8,
};

const Party = struct {
    slot: u8,
    front: bool,
    active: bool,
    locked: bool,
};

const Expect = struct {
    kind: []const u8,
    target_slot: ?u8 = null,
    draws_used: usize = 0,
    effect: ?[]const u8 = null,
    blocker: ?[]const u8 = null,
};

const DecisionCase = struct {
    name: []const u8,
    record: []const u8,
    own_front: bool,
    own_slot: u8,
    source_slot_count: u8,
    party: []const Party,
    draws: []const u15,
    expect: ?Expect = null,
    @"error": ?[]const u8 = null,
};

const EffectExpect = struct {
    family: []const u8,
    damage: i32,
    latch_mask: u8,
    target_script: ?[]const u8 = null,
    applied: bool,
};

const EffectCase = struct {
    name: []const u8,
    record: []const u8,
    raw_result: i32,
    expect: ?EffectExpect = null,
    @"error": ?[]const u8 = null,
};

fn expectErrorName(name: []const u8, result: anytype) !void {
    const expected: anyerror = if (std.mem.eql(u8, name, "UnknownEnemyRecord"))
        error.UnknownEnemyRecord
    else if (std.mem.eql(u8, name, "BlockedEnemyEffect"))
        error.BlockedEnemyEffect
    else
        return error.UnknownExpectedError;
    try std.testing.expectError(expected, result);
}

fn partyRows(case: DecisionCase, buffer: []enemy_policy_mod.PartyRow) void {
    for (case.party, 0..) |member, i| {
        buffer[i] = .{
            .slot = member.slot,
            .front = member.front,
            .active = member.active,
            .locked = member.locked,
        };
    }
}

test "packet resolves the campaign catalogue with explicit blockers" {
    const parsed = try root.load(allocator);
    defer parsed.deinit();
    const catalogue = &parsed.value;
    try std.testing.expectEqual(@as(usize, 29), catalogue.records.len);

    var resolved: usize = 0;
    var blocked: usize = 0;
    for (catalogue.records) |record| {
        if (std.mem.eql(u8, record.status, "resolved")) {
            resolved += 1;
            try std.testing.expect(record.decision.admitted);
            try std.testing.expect(packet.knownEffectFamily(record.effect.family));
            try std.testing.expect(!std.mem.eql(u8, record.effect.family, "blocked"));
            if (record.decision.special != null) {
                try std.testing.expect(record.effect.damage != null);
            }
        } else {
            blocked += 1;
            try std.testing.expectEqualStrings("blocked", record.status);
            const blocker = record.decision.blocker orelse record.effect.blocker orelse return error.BlockedRecordWithoutBlocker;
            try std.testing.expect(blocker.code.len > 0);
            try std.testing.expect(blocker.detail.len > 0);
        }
    }
    try std.testing.expectEqual(@as(usize, 20), resolved);
    try std.testing.expectEqual(@as(usize, 9), blocked);

    // The two base enemy-policy blocked records are now classified, and only Beast
    // Commander remains blocked through an exceptional rally/script outcome.
    const killer = catalogue.find("area_b.enemy.01").?;
    try std.testing.expectEqualStrings("pre_scan_special", killer.decision.family);
    try std.testing.expectEqualStrings("physical_result_once", killer.effect.family);
    try std.testing.expectEqual(@as(i32, 1), killer.effect.damage.?.numerator);
    try std.testing.expectEqual(@as(i32, 1), killer.effect.damage.?.denominator);

    const commander = catalogue.find("area_b.enemy.03").?;
    try std.testing.expectEqualStrings("own_front_rally", commander.decision.family);
    try std.testing.expectEqualStrings("script_step_effect_unresolved", commander.effect.blocker.?.code);
    // Its two printf calls are format strings, not a decision dependency.
    try std.testing.expectEqual(@as(usize, 2), commander.decision.debug_formats.len);
    try std.testing.expectEqual(@as(u32, 2), commander.decision.printf_slot_calls);
    try std.testing.expectEqualStrings("target_script_only", commander.decision.ordinary.?.effect.?.family);

    // The library slot identities the analysis relies on are carried and named.
    const expected_names = [_]struct { slot: []const u8, name: []const u8 }{
        .{ .slot = "0x00", .name = "rand" },
        .{ .slot = "0x04", .name = "actor_script_vm" },
        .{ .slot = "0x0C", .name = "physical_result" },
        .{ .slot = "0x10", .name = "hp_apply" },
        .{ .slot = "0x44", .name = "ordinary_hit" },
        .{ .slot = "0x124", .name = "printf" },
    };
    for (expected_names) |row| {
        var found = false;
        for (catalogue.library) |slot| {
            if (std.mem.eql(u8, slot.slot, row.slot) and std.mem.eql(u8, slot.name, row.name))
                found = true;
        }
        try std.testing.expect(found);
    }
}

test "every enemy-policy record is accounted for and families are enumerated" {
    const parsed = try root.load(allocator);
    defer parsed.deinit();
    const catalogue = &parsed.value;

    const base_parsed = try enemy_policy_mod.load(allocator);
    defer base_parsed.deinit();
    var base_count: usize = 0;
    for (base_parsed.value.areas) |area| {
        for (area.records) |record| {
            base_count += 1;
            try std.testing.expect(catalogue.find(record.id) != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 29), base_count);

    const required_families = [_][]const u8{
        "pre_scan_special",
        "own_front_rally",
        "physical_result_once",
        "physical_result_half_once",
        "physical_result_once_latch",
        "physical_result_double_once",
    };
    for (required_families) |family| {
        var found = false;
        for (catalogue.records) |record| {
            if (std.mem.eql(u8, record.decision.family, family) or
                std.mem.eql(u8, record.effect.family, family)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "decision vectors replay through the existing enemy path" {
    const parsed = try root.load(allocator);
    defer parsed.deinit();
    const catalogue = &parsed.value;
    const base_parsed = try enemy_policy_mod.load(allocator);
    defer base_parsed.deinit();

    const vectors = try std.json.parseFromSlice(Vectors, allocator, root.vectors_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer vectors.deinit();
    try std.testing.expectEqual(@as(usize, 10), vectors.value.decisions.len);

    for (vectors.value.decisions) |case| {
        var rows: [6]enemy_policy_mod.PartyRow = undefined;
        partyRows(case, &rows);
        var draws = systems.Draws{ .values = case.draws };
        const result = root.decide(catalogue, &base_parsed.value, case.record, rows[0..case.party.len], .{ .slot = case.own_slot, .front = case.own_front }, case.source_slot_count, &draws);
        if (case.@"error") |name| {
            try expectErrorName(name, result);
            continue;
        }
        const expect = case.expect orelse return error.MissingDecisionExpectation;
        const outcome = try result;
        if (std.mem.eql(u8, expect.kind, "attack")) {
            switch (outcome) {
                .attack => |attack| {
                    try std.testing.expectEqual(expect.target_slot.?, attack.target_slot);
                    try std.testing.expectEqual(expect.draws_used, attack.draws_used);
                },
                else => return error.ExpectedAttack,
            }
        } else if (std.mem.eql(u8, expect.kind, "special")) {
            switch (outcome) {
                .special => |special| {
                    try std.testing.expectEqual(expect.target_slot.?, special.target_slot.?);
                    try std.testing.expectEqual(expect.draws_used, special.draws_used);
                    if (expect.effect) |family|
                        try std.testing.expectEqualStrings(family, special.effect.family);
                },
                else => return error.ExpectedSpecial,
            }
        } else if (std.mem.eql(u8, expect.kind, "pending")) {
            switch (outcome) {
                .pending => |pending| try std.testing.expectEqual(expect.draws_used, pending.draws_used),
                else => return error.ExpectedPending,
            }
        } else if (std.mem.eql(u8, expect.kind, "disabled")) {
            switch (outcome) {
                .disabled => |disabled| try std.testing.expectEqual(expect.draws_used, disabled.draws_used),
                else => return error.ExpectedDisabled,
            }
        } else if (std.mem.eql(u8, expect.kind, "blocked")) {
            switch (outcome) {
                .blocked => |blocker| {
                    try std.testing.expectEqualStrings(expect.blocker.?, blocker.code);
                    // A refused decision consumes no random input.
                    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
                },
                else => return error.ExpectedBlocked,
            }
        } else return error.UnknownExpectationKind;
    }
}

test "effect vectors apply the resolved multiplier, latch and target script" {
    const parsed = try root.load(allocator);
    defer parsed.deinit();
    const catalogue = &parsed.value;

    const vectors = try std.json.parseFromSlice(Vectors, allocator, root.vectors_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer vectors.deinit();
    try std.testing.expectEqual(@as(usize, 8), vectors.value.effects.len);

    for (vectors.value.effects) |case| {
        const record = catalogue.find(case.record) orelse return error.MissingEffectRecord;
        const result = root.applyEffect(&record.effect, case.raw_result);
        if (case.@"error") |name| {
            try expectErrorName(name, result);
            continue;
        }
        const expect = case.expect orelse return error.MissingEffectExpectation;
        const applied = try result;
        try std.testing.expectEqualStrings(expect.family, record.effect.family);
        try std.testing.expectEqual(expect.damage, applied.damage);
        try std.testing.expectEqual(expect.latch_mask, applied.latch_mask);
        if (expect.target_script) |id| {
            try std.testing.expectEqualStrings(id, applied.target_script.?);
        } else {
            try std.testing.expect(applied.target_script == null);
        }
        try std.testing.expect(applied.clears_callback);
    }
}

test "unknown callbacks and records are refused, never defaulted" {
    const parsed = try root.load(allocator);
    defer parsed.deinit();
    const catalogue = &parsed.value;
    const base_parsed = try enemy_policy_mod.load(allocator);
    defer base_parsed.deinit();

    var values = [_]u15{ 1, 2, 3, 4, 5, 6 };
    var draws = systems.Draws{ .values = &values };
    const party = [_]enemy_policy_mod.PartyRow{
        .{ .slot = 0, .front = true, .active = true, .locked = false },
        .{ .slot = 1, .front = true, .active = true, .locked = false },
    };
    try std.testing.expectError(error.UnknownEnemyRecord, root.decide(catalogue, &base_parsed.value, "area_x.enemy.99", &party, .{ .slot = 0, .front = true }, 6, &draws));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);

    // Every blocked record is refused before any draw, with its typed blocker.
    for (catalogue.records) |record| {
        if (!std.mem.eql(u8, record.status, "blocked")) continue;
        var local_values = [_]u15{ 0, 0, 0, 0, 0, 0 };
        var local = systems.Draws{ .values = &local_values };
        const outcome = try root.decide(catalogue, &base_parsed.value, record.id, &party, .{ .slot = 0, .front = true }, 6, &local);
        switch (outcome) {
            .blocked => |blocker| try std.testing.expect(blocker.code.len > 0),
            else => return error.ExpectedBlocked,
        }
        try std.testing.expectEqual(@as(usize, 0), local.cursor);
    }

    // An unknown effect family is an explicit error, not a default multiplier.
    const unknown = packet.Effect{
        .family = "invented_effect",
        .damage = .{ .numerator = 1, .denominator = 1, .rounding = "toward_zero" },
    };
    try std.testing.expectError(error.UnknownEnemyEffectFamily, root.applyEffect(&unknown, 10));

    // A blocked effect plan is refused even if it carries a damage field.
    const blocked_effect = packet.Effect{
        .family = "blocked",
        .damage = .{ .numerator = 1, .denominator = 1, .rounding = "toward_zero" },
        .blocker = .{ .code = "script_step_effect_unresolved", .detail = "test" },
    };
    try std.testing.expectError(error.BlockedEnemyEffect, root.applyEffect(&blocked_effect, 10));
}

test "pre-scan draw order, locks and fallback are explicit" {
    const parsed = try root.load(allocator);
    defer parsed.deinit();
    const catalogue = &parsed.value;
    const base_parsed = try enemy_policy_mod.load(allocator);
    defer base_parsed.deinit();
    const killer = catalogue.find("area_b.enemy.01").?;

    // Locked candidates consume no draw: slot 0 is locked, so the only draw in
    // the scan belongs to slot 1.
    const party = [_]enemy_policy_mod.PartyRow{
        .{ .slot = 0, .front = true, .active = true, .locked = true },
        .{ .slot = 1, .front = true, .active = true, .locked = false },
        .{ .slot = 2, .front = false, .active = true, .locked = false },
    };
    var values = [_]u15{ 0, 17000 };
    var draws = systems.Draws{ .values = &values };
    const outcome = try root.decide(catalogue, &base_parsed.value, killer.id, &party, .{ .slot = 0, .front = true }, 6, &draws);
    switch (outcome) {
        .attack => |attack| {
            try std.testing.expectEqual(@as(u8, 1), attack.target_slot);
            try std.testing.expectEqual(@as(usize, 2), attack.draws_used);
        },
        else => return error.ExpectedAttack,
    }

    // The pre-gate is the first draw, not the first candidate scan.
    var gate_values = [_]u15{ 20000, 328 };
    var gate_draws = systems.Draws{ .values = &gate_values };
    const special = try root.decide(catalogue, &base_parsed.value, killer.id, &party, .{ .slot = 0, .front = true }, 2, &gate_draws);
    switch (special) {
        .special => |action| {
            try std.testing.expectEqual(@as(u8, 1), action.target_slot.?);
            try std.testing.expectEqual(@as(usize, 2), action.draws_used);
            try std.testing.expectEqualStrings("physical_result_once", action.effect.family);
        },
        else => return error.ExpectedSpecial,
    }
}
