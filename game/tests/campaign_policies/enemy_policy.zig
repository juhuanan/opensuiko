//! Focused gate: corrected A-H enemy policy/effect plans and settlement facts,
//! settlement facts through the owned adapter.
//!
//! The expectations in `conformance_vectors.json` are produced by the
//! independent Python reference planner in the extraction pipeline;
//! this gate replays them against the Zig adapter.  Nothing here executes an
//! original instruction or an old test.

const std = @import("std");
const adapter = @import("campaign_policies").enemy_policy;
const systems = @import("battle_rules");
const packet = adapter.policy_data;
const data = @import("campaign_policies_data").enemy_policy;

const allocator = std.testing.allocator;
const vectors_json = data.conformance_vectors_json;

const Vectors = struct {
    schema: []const u8,
    source: Source,
    decisions: []const DecisionCase,
    settlements: []const SettlementCase,
};

const Source = struct {
    packet_schema: []const u8,
    policy_asset_sha256: []const u8,
    note: []const u8,
};

const Expect = struct {
    kind: []const u8,
    target: ?u8 = null,
    target_slot: ?u8 = null,
    eligible_seen: ?bool = null,
    effect_blocked: ?bool = null,
    wait_frames: ?u8 = null,
    blocker: ?packet.Blocker = null,
    draws_used: usize,
};

const DecisionCase = struct {
    name: []const u8,
    record: []const u8,
    own_front: bool,
    own_slot: u8,
    party: []const adapter.PartyRow,
    draws: []const u15,
    expect: ?Expect = null,
    @"error": ?[]const u8 = null,
};

const SettleExpect = struct {
    money_delta: u32,
    balance_after: u32,
    credited: u32,
    overflow: u32,
    item: ?adapter.Grant = null,
    eligible_count: u8,
    draws_used: usize,
};

const SettlementCase = struct {
    name: []const u8,
    records: []const []const u8,
    eligible: []const bool,
    money_runes: []const bool,
    balance: u32,
    draws: []const u15,
    expect: ?SettleExpect = null,
    @"error": ?[]const u8 = null,
};

fn expectErrorName(name: []const u8, result: anytype) !void {
    const expected: anyerror = if (std.mem.eql(u8, name, "RandomInputExhausted"))
        error.RandomInputExhausted
    else if (std.mem.eql(u8, name, "InvalidEnemySlots"))
        error.InvalidEnemySlots
    else if (std.mem.eql(u8, name, "InvalidParty"))
        error.InvalidParty
    else if (std.mem.eql(u8, name, "InvalidFormationSlot"))
        error.InvalidFormationSlot
    else if (std.mem.eql(u8, name, "RewardAlreadyAwarded"))
        error.RewardAlreadyAwarded
    else if (std.mem.eql(u8, name, "UnknownDropItem"))
        error.UnknownDropItem
    else
        return error.UnknownExpectedError;
    try std.testing.expectError(expected, result);
}

fn drawValues(values: []const u15) systems.Draws {
    return .{ .values = values };
}

const PartyFull = [_]adapter.PartyRow{
    .{ .slot = 0, .front = true, .active = true, .locked = false },
    .{ .slot = 1, .front = true, .active = true, .locked = false },
    .{ .slot = 2, .front = true, .active = true, .locked = false },
    .{ .slot = 3, .front = false, .active = true, .locked = false },
    .{ .slot = 4, .front = false, .active = true, .locked = false },
    .{ .slot = 5, .front = false, .active = true, .locked = false },
};

test "packet binds eight areas, 29 records and 77 six-slot formations" {
    const parsed = try adapter.load(allocator);
    defer parsed.deinit();
    const catalogue = &parsed.value;

    try std.testing.expectEqual(@as(usize, 8), catalogue.areas.len);
    var records: usize = 0;
    var formations: usize = 0;
    for (catalogue.areas) |area| {
        try std.testing.expect(area.records.len > 0);
        records += area.records.len;
        formations += area.formations.len;
        for (area.formations) |formation| {
            try std.testing.expectEqual(@as(usize, 6), formation.slots.len);
            var active: u8 = 0;
            for (formation.slots) |slot| {
                if (slot.record) |id| {
                    active += 1;
                    const record = catalogue.record(id) orelse return error.MissingFormationRecord;
                    try std.testing.expect(record.id.len > 0);
                } else try std.testing.expectEqual(@as(u8, 0), slot.roster_id);
            }
            try std.testing.expectEqual(formation.active, active);
        }
    }
    try std.testing.expectEqual(@as(usize, 29), records);
    try std.testing.expectEqual(@as(usize, 77), formations);

    try std.testing.expectEqual(@as(usize, 4), catalogue.bindings.len);
    const expected = [_]struct { profile: []const u8, record: []const u8, name: []const u8 }{
        .{ .profile = "flying_squirrel", .record = "area_b.enemy.02", .name = "Flying Squirrel" },
        .{ .profile = "beast_commander", .record = "area_b.enemy.03", .name = "Beast Commander" },
        .{ .profile = "roc", .record = "area_b.enemy.04", .name = "Roc" },
        .{ .profile = "killer_rabbit", .record = "area_b.enemy.01", .name = "Killer Rabbit" },
    };
    for (expected) |row| {
        const record = catalogue.bind(row.profile) orelse return error.MissingBinding;
        try std.testing.expectEqualStrings(row.record, record.id);
        try std.testing.expectEqualStrings(row.name, record.name);
    }
    try std.testing.expect(catalogue.bind("unsupported_profile") == null);
}

test "blocked policies and unresolved effects stay explicit" {
    const parsed = try adapter.load(allocator);
    defer parsed.deinit();
    const catalogue = &parsed.value;

    var blocked: [2][]const u8 = undefined;
    var blocked_count: usize = 0;
    var unresolved: usize = 0;
    var resolved: usize = 0;
    for (catalogue.areas) |area| for (area.records) |record| {
        if (record.policy.family == .blocked) {
            blocked[blocked_count] = record.id;
            blocked_count += 1;
        } else if (record.policy.special) |special| {
            if (special.effect.kind == .unresolved) unresolved += 1 else resolved += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 2), blocked_count);
    try std.testing.expectEqualStrings("area_b.enemy.01", blocked[0]);
    try std.testing.expectEqualStrings("area_b.enemy.03", blocked[1]);
    try std.testing.expectEqual(@as(usize, 11), unresolved);
    try std.testing.expectEqual(@as(usize, 1), resolved);

    // A blocked policy is refused before any draw, with the typed blocker.
    var values = [_]u15{ 0, 0, 0 };
    var draws = drawValues(&values);
    const killer = catalogue.bind("killer_rabbit").?;
    const decision = try adapter.decide(killer, &PartyFull, .{ .slot = 0, .front = true }, &draws);
    switch (decision) {
        .blocked => |blocker| try std.testing.expectEqual(packet.BlockerCode.pre_scan_special, blocker.code),
        else => return error.ExpectedBlockedPolicy,
    }
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);

    // The resolved effect is the one Ant record; every other special remains
    // explicit and the executor must refuse it.
    const ant = catalogue.record("area_a.enemy.05").?;
    // 26000 scales to 79, above Ant's 77 threshold; the maximum roll 32767
    // wraps to zero and would take the ordinary path.
    var ant_draws = drawValues(&.{ 51, 26000 });
    const ant_decision = try adapter.decide(ant, &PartyFull, .{ .slot = 0, .front = true }, &ant_draws);
    try std.testing.expect(!ant_decision.effectBlocked());
    switch (ant_decision) {
        .special => |action| {
            try std.testing.expectEqual(packet.EffectKind.double_physical_result_once, action.special.effect.kind);
            try std.testing.expectEqual(@as(u8, 20), action.special.wait_frames);
        },
        else => return error.ExpectedAntSpecial,
    }

    const kobold = catalogue.record("area_c.enemy.03").?;
    var kobold_draws = drawValues(&.{ 51, 32767 });
    const blocked_effect = try adapter.decide(kobold, &PartyFull, .{ .slot = 0, .front = true }, &kobold_draws);
    try std.testing.expect(blocked_effect.effectBlocked());
    switch (blocked_effect) {
        .special => |action| {
            try std.testing.expectEqual(packet.BlockerCode.unresolved_special_effect, action.special.effect.blocker.?.code);
        },
        else => return error.ExpectedUnresolvedEffect,
    }
    // Planning still consumed the source draws; the executor rolls the whole
    // update back when it refuses the effect.
    try std.testing.expectEqual(@as(usize, 2), kobold_draws.cursor);
}

test "decision vectors replay the independent reference planner" {
    const parsed_packet = try adapter.load(allocator);
    defer parsed_packet.deinit();
    const catalogue = &parsed_packet.value;
    const parsed_vectors = try std.json.parseFromSlice(Vectors, allocator, vectors_json, .{ .allocate = .alloc_always });
    defer parsed_vectors.deinit();
    const vectors = parsed_vectors.value;
    try std.testing.expectEqualStrings("suikoden-enemy-policy-conformance-vectors/1", vectors.schema);
    try std.testing.expectEqualStrings(packet.schema, vectors.source.packet_schema);
    try std.testing.expectEqual(@as(usize, 64), vectors.source.policy_asset_sha256.len);

    for (vectors.decisions) |case| {
        const record = catalogue.record(case.record) orelse return error.MissingVectorRecord;
        var draws = drawValues(case.draws);
        const own = adapter.OwnSlot{ .slot = case.own_slot, .front = case.own_front };
        if (case.@"error") |name| {
            try expectErrorName(name, adapter.decide(record, case.party, own, &draws));
            continue;
        }
        const decision = try adapter.decide(record, case.party, own, &draws);
        const expect = case.expect orelse return error.MissingVectorExpectation;
        switch (decision) {
            .attack => |attack| {
                try std.testing.expectEqualStrings("attack", expect.kind);
                try std.testing.expectEqual(expect.target.?, attack.target);
                try std.testing.expectEqual(expect.target_slot.?, attack.target_slot);
                try std.testing.expectEqual(expect.draws_used, attack.draws_used);
            },
            .special => |special| {
                try std.testing.expectEqualStrings("special", expect.kind);
                try std.testing.expectEqual(expect.target, special.target);
                try std.testing.expectEqual(expect.target_slot, special.target_slot);
                try std.testing.expectEqual(expect.effect_blocked.?, special.effect_blocked);
                try std.testing.expectEqual(expect.wait_frames.?, special.special.wait_frames);
                try std.testing.expectEqual(expect.draws_used, special.draws_used);
            },
            .pending => |pending| {
                try std.testing.expectEqualStrings("pending", expect.kind);
                try std.testing.expectEqual(expect.eligible_seen.?, pending.eligible_seen);
                try std.testing.expectEqual(expect.draws_used, pending.draws_used);
            },
            .disabled => try std.testing.expectEqualStrings("disabled", expect.kind),
            .blocked => |blocker| {
                try std.testing.expectEqualStrings("blocked", expect.kind);
                try std.testing.expectEqual(expect.blocker.?.code, blocker.code);
            },
        }
        try std.testing.expectEqual(expect.draws_used, draws.cursor);
    }
}

test "six-slot bounds and out-of-domain rows refuse before any draw" {
    const parsed = try adapter.load(allocator);
    defer parsed.deinit();
    const bonbon = parsed.value.record("area_a.enemy.01").?;

    var values = [_]u15{ 51, 51, 51, 51, 51, 51, 51 };
    var draws = drawValues(&values);

    var seven = [_]adapter.PartyRow{
        .{ .slot = 0, .front = true, .active = true, .locked = false },
        .{ .slot = 1, .front = true, .active = true, .locked = false },
        .{ .slot = 2, .front = true, .active = true, .locked = false },
        .{ .slot = 3, .front = false, .active = true, .locked = false },
        .{ .slot = 4, .front = false, .active = true, .locked = false },
        .{ .slot = 5, .front = false, .active = true, .locked = false },
        .{ .slot = 5, .front = false, .active = true, .locked = false },
    };
    try std.testing.expectError(error.InvalidParty, adapter.decide(bonbon, &seven, .{ .slot = 0, .front = true }, &draws));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);

    // A bad sixth slot (index 6) is out of the six-slot domain.
    var member = adapter.PartyRow{ .slot = 6, .front = false, .active = true, .locked = false };
    try std.testing.expectError(error.InvalidFormationSlot, adapter.decide(bonbon, &.{member}, .{ .slot = 0, .front = true }, &draws));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);

    member = .{ .slot = 0, .front = true, .active = true, .locked = false };
    try std.testing.expectError(error.InvalidFormationSlot, adapter.decide(bonbon, &.{member}, .{ .slot = 6, .front = true }, &draws));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "settlement vectors replay the independent reference planner" {
    const parsed_packet = try adapter.load(allocator);
    defer parsed_packet.deinit();
    const catalogue = &parsed_packet.value;
    const parsed_vectors = try std.json.parseFromSlice(Vectors, allocator, vectors_json, .{ .allocate = .alloc_always });
    defer parsed_vectors.deinit();

    for (parsed_vectors.value.settlements, 0..) |case, index| {
        var present: [6]adapter.Present = undefined;
        try std.testing.expect(case.records.len <= 6);
        for (case.records, 0..) |id, i| {
            present[i] = .{ .record = catalogue.record(id) orelse return error.MissingVectorRecord, .eligible = case.eligible[i] };
        }
        var draws = drawValues(case.draws);
        var ledger = adapter.AwardLedger{};
        const token = index + 1;
        if (case.@"error") |name| {
            try expectErrorName(name, adapter.settle(catalogue, present[0..case.records.len], case.money_runes, case.balance, token, &ledger, &draws));
            try std.testing.expectEqual(@as(usize, 0), draws.cursor);
            try std.testing.expectEqual(@as(u8, 0), ledger.len);
            continue;
        }
        const receipt = try adapter.settle(catalogue, present[0..case.records.len], case.money_runes, case.balance, token, &ledger, &draws);
        const expect = case.expect orelse return error.MissingVectorExpectation;
        try std.testing.expectEqual(expect.money_delta, receipt.money_delta);
        try std.testing.expectEqual(expect.balance_after, receipt.balance_after);
        try std.testing.expectEqual(expect.credited, receipt.credited);
        try std.testing.expectEqual(expect.overflow, receipt.overflow);
        try std.testing.expectEqual(expect.eligible_count, receipt.eligible_count);
        try std.testing.expectEqual(expect.draws_used, receipt.draws_used);
        if (expect.item) |expected_item| {
            const item = receipt.item orelse return error.MissingSettledItem;
            try std.testing.expectEqual(expected_item.item, item.item);
            try std.testing.expectEqual(expected_item.uses, item.uses);
        } else try std.testing.expect(receipt.item == null);
        try std.testing.expectEqual(@as(u8, 1), ledger.len);
    }
}

test "a valid result is credited once and every failure rolls back" {
    const parsed = try adapter.load(allocator);
    defer parsed.deinit();
    const catalogue = &parsed.value;
    const ant = catalogue.record("area_a.enemy.05").?;

    var values = [_]u15{ 0, 0 };
    var draws = drawValues(&values);
    var present = [_]adapter.Present{.{ .record = ant, .eligible = true }};
    var ledger = adapter.AwardLedger{};

    const first = try adapter.settle(catalogue, &present, &[_]bool{}, 350, 7, &ledger, &draws);
    try std.testing.expectEqual(@as(u32, 60), first.money_delta);
    try std.testing.expectEqual(@as(u32, 410), first.balance_after);
    try std.testing.expectEqual(@as(u32, 60), first.credited);
    try std.testing.expectEqual(@as(u8, 1), ledger.len);
    const cursor_after = draws.cursor;
    try std.testing.expectEqual(@as(usize, 2), cursor_after);

    // Replaying the same victory token changes neither balance, item, draws
    // nor the ledger.
    try std.testing.expectError(error.RewardAlreadyAwarded, adapter.settle(catalogue, &present, &[_]bool{}, 410, 7, &ledger, &draws));
    try std.testing.expectEqual(cursor_after, draws.cursor);
    try std.testing.expectEqual(@as(u8, 1), ledger.len);

    // A different token is a different valid result and is credited.
    var next_draws = drawValues(&.{ 0, 0 });
    const second = try adapter.settle(catalogue, &present, &[_]bool{}, 410, 8, &ledger, &next_draws);
    try std.testing.expectEqual(@as(u32, 470), second.balance_after);
    try std.testing.expectEqual(@as(usize, 2), next_draws.cursor);

    // Two money-rune members double twice (the adapter takes the reviewed
    // membership predicate, not a raw rune id).
    var double_draws = drawValues(&.{ 0, 0 });
    const doubled = try adapter.settle(catalogue, &present, &[_]bool{ true, true }, 470, 11, &ledger, &double_draws);
    try std.testing.expectEqual(@as(u32, 240), doubled.money_delta);
    try std.testing.expectEqual(@as(u32, 710), doubled.balance_after);

    // Failure after the pair draw restores the whole draw cursor and leaves
    // the ledger unchanged.
    const short = [_]u15{0};
    var failing = drawValues(&short);
    const before_len = ledger.len;
    try std.testing.expectError(error.RandomInputExhausted, adapter.settle(catalogue, &present, &[_]bool{}, 470, 9, &ledger, &failing));
    try std.testing.expectEqual(@as(usize, 0), failing.cursor);
    try std.testing.expectEqual(before_len, ledger.len);

    // Seven source slots are refused before a draw.
    var seven = [_]adapter.Present{
        .{ .record = ant, .eligible = true }, .{ .record = ant, .eligible = true },
        .{ .record = ant, .eligible = true }, .{ .record = ant, .eligible = true },
        .{ .record = ant, .eligible = true }, .{ .record = ant, .eligible = true },
        .{ .record = ant, .eligible = true },
    };
    var more_values = [_]u15{0};
    var more_draws = drawValues(&more_values);
    try std.testing.expectError(error.InvalidEnemySlots, adapter.settle(catalogue, &seven, &[_]bool{}, 470, 10, &ledger, &more_draws));
    try std.testing.expectEqual(@as(usize, 0), more_draws.cursor);

    // Eight results fit the ledger; a ninth is refused before any draw.
    var full = adapter.AwardLedger{};
    for (0..8) |i| {
        var local = drawValues(&more_values);
        _ = try adapter.settle(catalogue, &[_]adapter.Present{.{ .record = ant, .eligible = false }}, &[_]bool{}, 0, i + 1, &full, &local);
    }
    try std.testing.expectEqual(@as(u8, 8), full.len);
    var ninth = drawValues(&more_values);
    try std.testing.expectError(error.AwardLedgerFull, adapter.settle(catalogue, &[_]adapter.Present{.{ .record = ant, .eligible = false }}, &[_]bool{}, 0, 99, &full, &ninth));
    try std.testing.expectEqual(@as(usize, 0), ninth.cursor);
}

test "encoded money, the signed cap, overflow and bribe arithmetic" {
    try std.testing.expectEqual(@as(u32, 70), adapter.decodeMoney(70));
    try std.testing.expectEqual(@as(u32, 700), adapter.decodeMoney(71));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFF6), adapter.decodeMoney(-10));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF9C), adapter.decodeMoney(-15));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFE), adapter.decodeMoney(-2));

    try std.testing.expectEqual(@as(u32, 999999), adapter.rewardBalance(999999, 1));
    try std.testing.expectEqual(@as(u32, 999999), adapter.rewardBalance(999998, 5));
    try std.testing.expectEqual(@as(u32, 420), adapter.rewardBalance(350, 70));
    // Source-faithful wrap: a total whose sign bit is set is not above the cap.
    try std.testing.expectEqual(@as(u32, 0x80000000), adapter.rewardBalance(0, 0x80000000));

    const parsed = try adapter.load(allocator);
    defer parsed.deinit();
    const ant = parsed.value.record("area_a.enemy.05").?;
    const orc = parsed.value.record("area_e.enemy.02").?;

    // Cap overflow is reported, not paid out: 999999 + 60 -> overflow 60.
    var values = [_]u15{ 0, 0 };
    var draws = drawValues(&values);
    var ledger = adapter.AwardLedger{};
    var presentation = [_]adapter.Present{.{ .record = ant, .eligible = true }};
    const capped = try adapter.settle(&parsed.value, &presentation, &[_]bool{}, 999999, 1, &ledger, &draws);
    try std.testing.expectEqual(@as(u32, 999999), capped.balance_after);
    try std.testing.expectEqual(@as(u32, 0), capped.credited);
    try std.testing.expectEqual(@as(u32, 60), capped.overflow);

    // Bribe is 3 * raw signed +0x34, not the decoded reward: 60*3 and 3000*3.
    try std.testing.expectEqual(@as(u32, 180), try adapter.bribePrice(&.{ant}));
    try std.testing.expectEqual(@as(u32, 9000), try adapter.bribePrice(&.{orc}));
    try std.testing.expectEqual(@as(u32, 9180), try adapter.bribePrice(&.{ ant, null, orc }));
    const negative = adapter.Record{
        .id = "synthetic.negative",
        .name = "Synthetic",
        .level = 1,
        .hp = 1,
        .money_encoded = -10,
        .drops = .{ .{ .item = 0, .rate = 0 }, .{ .item = 0, .rate = 0 }, .{ .item = 0, .rate = 0 } },
        .policy = .{ .family = .random_target, .scan = .{ .front_only = true, .draw_kind = .percent_100, .accept_at_least = 51 }, .no_selection = .pending_if_any_eligible },
    };
    try std.testing.expectError(error.NegativeBribePrice, adapter.bribePrice(&.{&negative}));
    var seven = [_]?*const adapter.Record{ ant, ant, ant, ant, ant, ant, ant };
    try std.testing.expectError(error.InvalidEnemySlots, adapter.bribePrice(&seven));
}

test "draw shapes, max-roll wrap and locked candidates agree with the source rules" {
    const percent = adapter.drawValue(.percent_100, 32767);
    try std.testing.expectEqual(@as(u32, 67), percent);
    const scaled = adapter.drawValue(.scale_100_32767, 32767);
    try std.testing.expectEqual(@as(u32, 100), scaled);
    const wrapped = adapter.drawValue(.scale_100_32767_mod_100, 32767);
    try std.testing.expectEqual(@as(u32, 0), wrapped);

    const parsed = try adapter.load(allocator);
    defer parsed.deinit();
    const ant = parsed.value.record("area_a.enemy.05").?;

    // Maximum roll wraps Ant's second draw to zero: ordinary attack.
    var max_values = [_]u15{ 51, 32767 };
    var max_draws = drawValues(&max_values);
    const max_decision = try adapter.decide(ant, &PartyFull, .{ .slot = 0, .front = true }, &max_draws);
    switch (max_decision) {
        .attack => |action| try std.testing.expectEqual(@as(u8, 0), action.target),
        else => return error.ExpectedMaxRollAttack,
    }
    try std.testing.expectEqual(@as(usize, 2), max_draws.cursor);

    // A locked front row is skipped without a draw; a later eligible row is
    // scanned in order.
    const locked_front = [_]adapter.PartyRow{
        .{ .slot = 0, .front = true, .active = true, .locked = true },
        .{ .slot = 1, .front = true, .active = true, .locked = true },
        .{ .slot = 2, .front = true, .active = true, .locked = true },
        .{ .slot = 3, .front = false, .active = true, .locked = false },
    };
    const bonbon = parsed.value.record("area_a.enemy.01").?;
    var locked_values = [_]u15{51};
    var locked_draws = drawValues(&locked_values);
    const pending = try adapter.decide(bonbon, &locked_front, .{ .slot = 0, .front = true }, &locked_draws);
    switch (pending) {
        .pending => |value| try std.testing.expect(value.eligible_seen),
        else => return error.ExpectedPendingScan,
    }
    try std.testing.expectEqual(@as(usize, 0), locked_draws.cursor);

    // Crow scans every living row; the same locked front row therefore yields
    // a back-row target after one draw.
    const crow = parsed.value.record("area_a.enemy.03").?;
    var crow_values = [_]u15{51};
    var crow_draws = drawValues(&crow_values);
    const crow_decision = try adapter.decide(crow, &locked_front, .{ .slot = 0, .front = true }, &crow_draws);
    switch (crow_decision) {
        .attack => |action| {
            try std.testing.expectEqual(@as(u8, 3), action.target);
            try std.testing.expectEqual(@as(u8, 3), action.target_slot);
        },
        else => return error.ExpectedCrowAttack,
    }
    try std.testing.expectEqual(@as(usize, 1), crow_draws.cursor);
}
