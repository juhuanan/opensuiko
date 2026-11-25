//! Focused gate -- Unite catalogue and participant lifecycle.
//!
//! The test supplies the coordinator's state explicitly: six party slots, three
//! enemy slots, a `battle_rules.Draws` stream and the existing physical routine
//! as a callback.  It checks the source rules the catalogue records and the
//! port boundary's rollback behaviour; it does not execute original
//! instructions or touch a window/media path.

const std = @import("std");
const unite_mod = @import("battle_systems").unite;
const unite_data = @import("battle_systems_data").unite;
const rng = @import("battle_rules");

const unused_id_base: u8 = 200;

const TestBattle = struct {
    party: [6]unite_mod.Slot = @splat(.{ .character_id = 0 }),
    enemies: [3]unite_mod.Slot = @splat(.{ .character_id = 0 }),
    party_count: usize = 2,
    enemy_count: usize = 3,
    draws: rng.Draws = .{},
    writes: u32 = 0,
    status_writes: u32 = 0,
    flag_writes: u32 = 0,
    damage_calls: u32 = 0,
    damage_targets: [12]i16 = @splat(0),
    damage_target: i16 = 0,
    damage_amount: u32 = 0,
    physical_calls: u32 = 0,
    hit_ready: [6]bool = @splat(true),

    fn init(party_ids: []const u8) TestBattle {
        var battle = TestBattle{};
        for (0..6) |i| battle.party[i] = .{ .character_id = unused_id_base + @as(u8, @intCast(i)) };
        for (party_ids, 0..) |id, i| battle.party[i] = .{ .character_id = id };
        battle.party_count = party_ids.len;
        for (0..3) |i| battle.enemies[i] = .{ .character_id = 100 + @as(u8, @intCast(i)), .hp = 10 };
        return battle;
    }

    fn view(self: *TestBattle) unite_mod.View {
        return .{ .party = self.party[0..self.party_count], .enemies = self.enemies[0..self.enemy_count] };
    }

    fn host(self: *TestBattle) unite_mod.Host {
        return .{
            .context = self,
            .write_slot = writeSlot,
            .write_status = writeStatus,
            .write_flags = writeFlags,
            .apply_damage = applyDamage,
            .physical = physical,
            .hit_ready = hitReady,
        };
    }
};

fn cast(context: *anyopaque) *TestBattle {
    return @ptrCast(@alignCast(context));
}

fn writeSlot(context: *anyopaque, slot: usize, state: unite_mod.CommandWrite) void {
    const battle = cast(context);
    battle.writes += 1;
    battle.party[slot].command = state.command;
    battle.party[slot].unite_ordinal = state.unite_ordinal;
    battle.party[slot].target = state.target;
    battle.party[slot].available = state.available;
}

fn writeStatus(context: *anyopaque, slot: usize, mask: u16, counter: u8) void {
    const battle = cast(context);
    battle.status_writes += 1;
    battle.party[slot].status_mask = mask;
    battle.party[slot].recovery_counter = counter;
}

fn writeFlags(context: *anyopaque, slot: usize, flags: u16) void {
    const battle = cast(context);
    battle.flag_writes += 1;
    battle.party[slot].actor_flags = flags;
}

fn applyDamage(context: *anyopaque, target: i16, amount: u32) void {
    const battle = cast(context);
    battle.damage_targets[battle.damage_calls] = target;
    battle.damage_calls += 1;
    battle.damage_target = target;
    battle.damage_amount = amount;
}

fn physical(context: *anyopaque, slot: usize, target: i16, draws: *rng.Draws) anyerror!u32 {
    const battle = cast(context);
    _ = slot;
    _ = target;
    battle.physical_calls += 1;
    return try draws.next();
}

fn hitReady(context: *anyopaque, slot: usize) bool {
    return cast(context).hit_ready[slot];
}

var values_two = [_]u15{ 2, 4 };
var values_three = [_]u15{ 2, 3, 4 };
var values_four = [_]u15{ 1, 1, 1, 1 };
var values_five = [_]u15{ 5, 6, 7, 8, 9 };

fn catalogue() !unite_mod.Catalogue {
    return unite_mod.load(std.testing.allocator);
}

fn expectRefusal(result: unite_mod.PlanResult, refusal: unite_mod.Refusal) !void {
    switch (result) {
        .boundary => return error.ExpectedRefusal,
        .refusal => |actual| try std.testing.expectEqual(refusal, actual),
    }
}

fn planOk(cat: *const unite_mod.Catalogue, battle: *TestBattle, request: unite_mod.Request) !unite_mod.Boundary {
    const result = unite_mod.plan(cat, battle.view(), request);
    return switch (result) {
        .boundary => |boundary| boundary,
        .refusal => |refusal| {
            std.debug.print("unexpected refusal {s}\n", .{@tagName(refusal)});
            return error.ExpectedBoundary;
        },
    };
}

// ---------------------------------------------------------------------------
// catalogue

test "catalogue is the complete 32-record source table" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 32), cat.count());
    try std.testing.expectEqual(@as(usize, 32), cat.provenCount());
    try std.testing.expectEqual(@as(usize, 0), cat.blockedCount());
    try std.testing.expectEqualStrings("suikoden-unite-catalogue/6", unite_mod.schema);

    const talisman = cat.recordAt(0).?;
    try std.testing.expectEqualStrings("Talisman attack", talisman.name);
    try std.testing.expectEqual(@as(u8, 2), talisman.member_count);
    try std.testing.expectEqualSlices(u8, &.{ 6, 2 }, talisman.membersSlice());
    try std.testing.expectEqual(unite_mod.TargetRule.individual, talisman.target_rule);
    try std.testing.expectEqual(@as(u8, 1), talisman.unite_id);
    try std.testing.expectEqual(@as(u8, 2), talisman.damage_count);
    try std.testing.expectEqual(@as(u8, 20), talisman.multiplier);
    try std.testing.expectEqual(unite_mod.EffectGate.leader_hit_flag, talisman.gate.?);
    try std.testing.expect(talisman.proven());

    const blacksmith = cat.recordAt(5).?;
    try std.testing.expectEqual(@as(u8, 4), blacksmith.member_count);
    try std.testing.expectEqual(@as(u8, 30), blacksmith.multiplier);

    const warriors = cat.recordAt(15).?;
    try std.testing.expect(warriors.proven());
    try std.testing.expectEqual(@as(u8, 20), warriors.multiplier);
    try std.testing.expectEqual(unite_mod.EffectGate.target_active, warriors.gate.?);

    var two: usize = 0;
    var three: usize = 0;
    var four: usize = 0;
    var picker: usize = 0;
    var bypass: usize = 0;
    for (cat.records) |record| {
        switch (record.member_count) {
            2 => two += 1,
            3 => three += 1,
            4 => four += 1,
            else => return error.UnexpectedMemberCount,
        }
        switch (record.target_rule) {
            .individual => picker += 1,
            .bypass => bypass += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 16), two);
    try std.testing.expectEqual(@as(usize, 11), three);
    try std.testing.expectEqual(@as(usize, 5), four);
    try std.testing.expectEqual(@as(usize, 24), picker);
    try std.testing.expectEqual(@as(usize, 8), bypass);
}

test "every record is accounted for and internally consistent" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);

    for (cat.records, 0..) |record, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), record.index);
        try std.testing.expect(record.member_count >= 2 and record.member_count <= 4);
        try std.testing.expect(record.name.len > 0);
        try std.testing.expect(record.handler >= 0x800C0000);
        try std.testing.expect(record.update >= 0x800C0000);
        try std.testing.expect(record.unite_id >= 1 and record.unite_id <= 25);
        for (record.membersSlice(), 0..) |member, m| {
            for (record.membersSlice()[0..m]) |previous| {
                try std.testing.expect(member != previous);
            }
        }
        switch (record.outcome) {
            .proven => {
                try std.testing.expectEqual(unite_mod.Family.combined_physical, record.family);
                try std.testing.expectEqual(record.member_count, record.damage_count);
                try std.testing.expect(record.gate != null);
                try std.testing.expect(record.multiplier > 0);
            },
            .blocked => |reason| {
                try std.testing.expectEqual(unite_mod.Blocker.effect_family_unestablished, reason);
                try std.testing.expectEqual(unite_mod.Family.custom, record.family);
            },
        }
    }
    // The one record whose label carries an undecoded text byte is marked.
    try std.testing.expect(!cat.recordAt(26).?.name_fully_decoded);
}

test "ordinals are one-based and resolve to the same record" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?*const unite_mod.Record, null), cat.recordByOrdinal(0));
    for (cat.records, 0..) |record, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i + 1)), record.ordinal());
        const resolved = cat.recordByOrdinal(record.ordinal()).?;
        try std.testing.expectEqual(@as(u8, @intCast(i)), resolved.index);
    }
    var out: [8]usize = undefined;
    const n = cat.containing(6, &out);
    try std.testing.expect(n >= 2); // Talisman and Beat'em up both name Pahn
    for (out[0..n]) |index| try std.testing.expect(cat.recordAt(@intCast(index)).?.hasMember(6));
}

test "embedded packet digest matches the data module" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(unite_data.unite_catalogue_json, &digest, .{});
    var text: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&text, "{x}", .{&digest}) catch unreachable;
    try std.testing.expectEqualStrings(unite_data.unite_catalogue_file_sha256, hex);
}

// ---------------------------------------------------------------------------
// membership and reservation

test "membership follows record order, not party order" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 2, 90, 6 }); // Gremio first, Pahn last
    battle.draws = .{ .values = &values_two };

    var boundary = try planOk(&cat, &battle, .{ .actor = 2, .record = 0, .target = 4 });
    try std.testing.expectEqualSlices(usize, &.{ 2, 0 }, boundary.participantsSlice());
    try std.testing.expectEqual(@as(i16, 4), boundary.target);
    try boundary.commit(battle.host());

    // The commit writes command 4, the one-based ordinal and the target.
    for (boundary.participantsSlice()) |slot| {
        try std.testing.expectEqual(unite_mod.rules.unite_command, battle.party[slot].command);
        try std.testing.expectEqual(@as(u8, 1), battle.party[slot].unite_ordinal);
        try std.testing.expectEqual(@as(i8, 4), battle.party[slot].target);
        try std.testing.expect(!battle.party[slot].available);
    }
}

test "three participants are reserved and combined" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 4, 75, 9 });
    battle.draws = .{ .values = &values_three };

    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 3, .target = 4 });
    try std.testing.expectEqual(@as(u8, 3), boundary.count);
    try boundary.commit(battle.host());
    switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
        .applied => |amount| try std.testing.expectEqual(@as(u32, 18), amount), // (2+3+4)*20/10
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(u32, 1), battle.damage_calls);
    try std.testing.expectEqual(@as(i16, 4), battle.damage_target);
    try std.testing.expectEqual(@as(u32, 18), battle.damage_amount);
    try std.testing.expectEqual(@as(usize, 3), battle.physical_calls);

    try boundary.finish(battle.view(), battle.host());
    for (boundary.participantsSlice()) |slot| {
        try std.testing.expectEqual(@as(u16, 0), battle.party[slot].status_mask);
        try std.testing.expectEqual(@as(u8, 0), battle.party[slot].recovery_counter);
    }
}

test "four participants are reserved and combined" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 70, 72, 69, 71 });
    battle.draws = .{ .values = &values_four };

    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 5, .target = 5 });
    try std.testing.expectEqual(@as(u8, 4), boundary.count);
    try boundary.commit(battle.host());
    switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
        .applied => |amount| try std.testing.expectEqual(@as(u32, 12), amount), // (1+1+1+1)*30/10
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(usize, 4), battle.physical_calls);
}

test "double booking is refused and writes nothing" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 6, 2 });
    battle.party[1].available = false; // already assigned a command

    try expectRefusal(unite_mod.plan(&cat, battle.view(), .{ .actor = 0, .record = 0, .target = 4 }), .participant_assigned);
    try std.testing.expectEqual(@as(u32, 0), battle.writes);
    try std.testing.expectEqual(@as(u8, 0), battle.party[0].command);
    try std.testing.expectEqual(@as(u8, 0), battle.party[1].command);
}

test "membership and reservation refusals are typed" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);

    var missing = TestBattle.init(&.{ 6, 91 });
    try expectRefusal(unite_mod.plan(&cat, missing.view(), .{ .actor = 0, .record = 0, .target = 4 }), .missing_member);

    var outsider = TestBattle.init(&.{ 6, 2, 91 });
    try expectRefusal(unite_mod.plan(&cat, outsider.view(), .{ .actor = 2, .record = 0, .target = 4 }), .actor_not_member);

    var asleep = TestBattle.init(&.{ 6, 2 });
    asleep.party[1].status_mask = 0x20;
    try expectRefusal(unite_mod.plan(&cat, asleep.view(), .{ .actor = 0, .record = 0, .target = 4 }), .participant_unavailable);

    var down = TestBattle.init(&.{ 6, 2 });
    down.party[1].active = false;
    try expectRefusal(unite_mod.plan(&cat, down.view(), .{ .actor = 0, .record = 0, .target = 4 }), .participant_down);

    try expectRefusal(unite_mod.plan(&cat, missing.view(), .{ .actor = 0, .record = 32, .target = 4 }), .unknown_record);
}

// ---------------------------------------------------------------------------
// target rules

test "an invalid individual target is repaired by the source scan" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 6, 2 });
    battle.enemies[0] = .{ .character_id = 100, .active = false }; // chosen, down
    battle.enemies[1] = .{ .character_id = 101, .hp = 5 };
    battle.enemies[2] = .{ .character_id = 102, .hp = 5 };

    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 0, .target = 3 });
    try std.testing.expectEqual(@as(i16, 4), boundary.target);
    try std.testing.expectEqual(@as(?i16, 3), boundary.retargeted_from);
    try boundary.commit(battle.host());
    try std.testing.expectEqual(@as(i8, 4), battle.party[0].target);
}

test "no repair candidate refuses the boundary" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 6, 2 });
    for (0..3) |i| battle.enemies[i] = .{ .character_id = 100 + @as(u8, @intCast(i)), .active = false };

    try expectRefusal(unite_mod.plan(&cat, battle.view(), .{ .actor = 0, .record = 0, .target = 3 }), .no_replacement);
    try std.testing.expectEqual(@as(u32, 0), battle.writes);
}

test "group bypass records require living enemies and accept a fresh command" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 4, 9 }); // Wild arrow attack, bypass
    battle.party[0].target = 5; // existing B+0x49 (an enemy source index)

    const boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 2, .target = 0 });
    try std.testing.expectEqual(@as(i16, 5), boundary.target);
    try std.testing.expectEqual(@as(?i16, null), boundary.retargeted_from);

    for (0..3) |i| battle.enemies[i].active = false;
    try expectRefusal(unite_mod.plan(&cat, battle.view(), .{ .actor = 0, .record = 2, .target = 0 }), .bypass_without_living_enemy);

    battle.enemies[0].active = true;
    battle.party[0].target = 0; // stale index: the source does not validate it
    const fresh = try planOk(&cat, &battle, .{ .actor = 0, .record = 2, .target = 0 });
    try std.testing.expectEqual(@as(i16, 3), fresh.target);

    battle.enemies[0].active = true;
    battle.party[0].target = 1; // a party index, not an enemy
    _ = try planOk(&cat, &battle, .{ .actor = 0, .record = 2, .target = 0 });
}

test "second-stage Unite callbacks resolve Warriors Couple and both Beauty records" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    for ([_]u8{ 9, 15, 16, 25 }) |index| {
        const record = cat.recordAt(index).?;
        var battle = TestBattle.init(record.membersSlice());
        const values: [12]u15 = @splat(10);
        battle.draws = .{ .values = &values };
        var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = index, .target = @intCast(battle.party_count + 1) });
        try boundary.commit(battle.host());
        switch (boundary.impact(&cat, battle.view(), battle.host(), &battle.draws)) {
            .applied => {},
            else => return error.ExpectedApplied,
        }
        const targets: u32 = if (record.all_enemies) 3 else 1;
        try std.testing.expectEqual(targets, battle.damage_calls);
        try std.testing.expectEqual(@as(u32, record.member_count) * 10 * record.multiplier / 10, battle.damage_amount);
        try boundary.finish(battle.view(), battle.host());
    }
}

test "a group Unite stages all targets before a late draw failure" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    const record = cat.recordAt(9).?;
    var battle = TestBattle.init(record.membersSlice());
    const values: [4]u15 = @splat(10);
    battle.draws = .{ .values = &values };
    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 9, .target = 4 });
    try boundary.commit(battle.host());
    switch (boundary.impact(&cat, battle.view(), battle.host(), &battle.draws)) {
        .failed => {},
        else => return error.ExpectedFailure,
    }
    try std.testing.expectEqual(@as(u32, 0), battle.damage_calls);
    try std.testing.expectEqual(@as(usize, 0), battle.draws.cursor);
}

// ---------------------------------------------------------------------------
// rollback / interruption / RNG

test "partial draw exhaustion rolls back the whole boundary" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 4, 75, 9 }); // needs three contributions
    battle.draws = .{ .values = &values_two }; // only two draws are available

    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 3, .target = 4 });
    try boundary.commit(battle.host());
    switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
        .failed => |failure| try std.testing.expectEqual(error.RandomInputExhausted, failure.random),
        else => return error.ExpectedFailure,
    }
    try std.testing.expectEqual(unite_mod.Stage.rolled_back, boundary.stage);
    try std.testing.expectEqual(@as(u32, 0), battle.damage_calls);
    // The cursor is restored, so the coordinator can retry another action.
    try std.testing.expectEqual(@as(usize, 0), battle.draws.cursor);
    for (boundary.participantsSlice()) |slot| {
        try std.testing.expectEqual(@as(u8, 0), battle.party[slot].command);
        try std.testing.expectEqual(@as(u8, 0), battle.party[slot].unite_ordinal);
        try std.testing.expect(battle.party[slot].available);
    }
}

test "a participant down after initialization remains in the fixed combined damage roster" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 6, 2 });
    battle.draws = .{ .values = &values_five };
    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 0, .target = 4 });
    try boundary.commit(battle.host());
    battle.party[1].active = false;
    battle.party[1].hp = 0;
    switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
        .applied => |amount| try std.testing.expectEqual(@as(u32, 22), amount),
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(u32, 1), battle.damage_calls);
    try std.testing.expectEqual(@as(u32, 2), battle.physical_calls);
    try std.testing.expectEqual(@as(usize, 2), battle.draws.cursor);
    try std.testing.expectEqual(@as(u8, 4), battle.party[0].command);
    try std.testing.expect(!battle.party[1].available);
}

test "cancel and retarget restore the prior command bytes" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 6, 2 });
    battle.party[0] = .{ .character_id = 6, .command = 1, .unite_ordinal = 0, .target = 4, .actor_flags = 0x0002 };
    battle.party[1] = .{ .character_id = 2, .available = true, .command = 3, .target = 0, .actor_flags = 0 };

    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 0, .target = 5 });
    try boundary.commit(battle.host());
    try std.testing.expectEqual(@as(u8, 4), battle.party[0].command);

    unite_mod.undo(&boundary, battle.host());
    try std.testing.expectEqual(@as(u8, 1), battle.party[0].command);
    try std.testing.expectEqual(@as(u8, 3), battle.party[1].command);
    try std.testing.expectEqual(@as(u16, 0x0002), battle.party[0].actor_flags);
    try std.testing.expectEqual(unite_mod.Stage.rolled_back, boundary.stage);

    // Undo is idempotent.
    const writes = battle.writes;
    unite_mod.undo(&boundary, battle.host());
    try std.testing.expectEqual(writes, battle.writes);

    // A fresh plan after the rollback is available again.
    var again = try planOk(&cat, &battle, .{ .actor = 0, .record = 0, .target = 5 });
    try again.commit(battle.host());
    try std.testing.expectEqual(@as(u8, 4), battle.party[0].command);
}

test "damage consumes hit flags without inventing return readiness" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 6, 2 });
    battle.draws = .{ .values = &values_five };
    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 0, .target = 4 });
    try boundary.commit(battle.host());
    battle.party[0].actor_flags = 2;
    battle.party[1].actor_flags = 6;
    switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
        .applied => {},
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(u16, 0), battle.party[0].actor_flags);
    try std.testing.expectEqual(@as(u16, 4), battle.party[1].actor_flags);
}

test "a clear leader hit flag skips damage but the action still completes" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 6, 2 });
    battle.draws = .{ .values = &values_five };
    battle.hit_ready[0] = false;

    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 0, .target = 4 });
    try boundary.commit(battle.host());
    switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
        .skipped => |skip| try std.testing.expectEqual(unite_mod.Skip.leader_hit_flag_clear, skip),
        else => return error.ExpectedSkip,
    }
    try std.testing.expectEqual(@as(u32, 0), battle.damage_calls);
    try std.testing.expectEqual(@as(usize, 0), battle.draws.cursor);
    // Talisman completes without the Fisherman recovery tail.
    try boundary.finish(battle.view(), battle.host());
    try std.testing.expectEqual(@as(u32, 0), battle.status_writes);
}

test "a group Unite skips an inactive enemy and hits the remaining enemies" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 4, 9 });
    battle.party[0].target = 4;
    battle.draws = .{ .values = &values_five };

    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 2, .target = 0 });
    try boundary.commit(battle.host());
    battle.enemies[1].active = false;
    switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
        .applied => {},
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(u32, 2), battle.damage_calls);
    try std.testing.expectEqual(@as(usize, 4), battle.draws.cursor);
}

// ---------------------------------------------------------------------------
// recovery and resume

test "recovery retains one round, then clears, and only item/defend stay available" {
    try std.testing.expect(!unite_mod.allows(.attack));
    try std.testing.expect(!unite_mod.allows(.rune));
    try std.testing.expect(!unite_mod.allows(.unite));
    try std.testing.expect(unite_mod.allows(.item));
    try std.testing.expect(unite_mod.allows(.defend));

    var slot = unite_mod.Slot{ .character_id = 6 };
    try std.testing.expectEqual(unite_mod.RecoveryTick.idle, unite_mod.tickRecovery(&slot));

    slot.status_mask = unite_mod.rules.recovery_mask;
    slot.recovery_counter = 1;
    try std.testing.expectEqual(unite_mod.RecoveryTick.retained, unite_mod.tickRecovery(&slot));
    try std.testing.expectEqual(@as(u16, unite_mod.rules.recovery_mask), slot.status_mask);
    try std.testing.expectEqual(@as(u8, 0), slot.recovery_counter);
    try std.testing.expectEqual(unite_mod.RecoveryTick.cleared, unite_mod.tickRecovery(&slot));
    try std.testing.expectEqual(@as(u16, 0), slot.status_mask);
    try std.testing.expectEqual(unite_mod.RecoveryTick.idle, unite_mod.tickRecovery(&slot));
}

test "round reset clears command, ordinal and target" {
    const state = unite_mod.roundReset();
    try std.testing.expectEqual(@as(u8, 0), state.command);
    try std.testing.expectEqual(@as(u8, 0), state.unite_ordinal);
    try std.testing.expectEqual(@as(i8, 0), state.target);
    try std.testing.expect(state.available);
    try std.testing.expectEqual(@as(u8, 1), unite_mod.memberMark());
}

test "the successful path reports one HP commit and the boundary schema" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 14, 65, 80 }); // Kobold ?1 attack, three members
    battle.draws = .{ .values = &values_three };

    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 26, .target = 4 });
    try boundary.commit(battle.host());
    switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
        .applied => |amount| try std.testing.expectEqual(@as(u32, 27), amount), // (2+3+4)*30/10
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(u32, 1), battle.damage_calls);
    try boundary.finish(battle.view(), battle.host());
    try std.testing.expectEqual(unite_mod.Stage.finished, boundary.stage);
    try std.testing.expectEqualStrings("suikoden-unite-boundary/3", unite_mod.boundary_schema);
    // Every participant's hit flag was consumed.
    try std.testing.expectEqual(@as(u32, 3), battle.flag_writes);
}

test "Unite recovery follows each member script instead of a universal penalty" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    for ([_]u8{ 0, 1, 8, 27 }) |index| {
        const record = cat.recordAt(index).?;
        var battle = TestBattle.init(record.membersSlice());
        var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = index, .target = @intCast(battle.party_count + 1) });
        try boundary.commit(battle.host());
        try boundary.finish(battle.view(), battle.host());
        for (boundary.participantsSlice(), 0..) |slot, member| {
            const expected = switch (index) {
                0 => false,
                1 => true,
                8 => member == 2,
                27 => member == 0,
                else => unreachable,
            };
            try std.testing.expectEqual(@as(u16, if (expected) unite_mod.rules.recovery_mask else 0), battle.party[slot].status_mask);
            try std.testing.expectEqual(@as(u8, if (expected) 1 else 0), battle.party[slot].recovery_counter);
        }
    }
}

test "Master pupil claims each eligible enemy once using two independent member clocks" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 8, 91 });
    const values: [6]u15 = .{ 1, 2, 3, 4, 5, 6 };
    battle.draws = .{ .values = &values };
    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 31, .target = 0 });
    try boundary.commit(battle.host());
    var hit_ticks: [3]u16 = undefined;
    var hits: usize = 0;
    for (0..333) |tick| {
        if (boundary.advanceSequence(&cat, battle.view(), battle.host(), &battle.draws, @intCast(tick))) |result| switch (result) {
            .applied => {
                hit_ticks[hits] = @intCast(tick);
                hits += 1;
            },
            else => return error.ExpectedApplied,
        };
    }
    try std.testing.expectEqual(@as(usize, 3), hits);
    try std.testing.expectEqualSlices(u16, &.{ 142, 146, 261 }, &hit_ticks);
    try std.testing.expectEqualSlices(i16, &.{ 3, 4, 5 }, battle.damage_targets[0..3]);
    try std.testing.expectEqual(@as(usize, 6), battle.draws.cursor);
    try std.testing.expectEqual(@as(u32, 21), boundary.amount);
    try std.testing.expectEqual(@as(?u16, 332), boundary.sequence.?.finish_at);
    try boundary.finish(battle.view(), battle.host());
    try std.testing.expectEqual(@as(u32, 0), battle.status_writes);
}

test "Master pupil excludes initially inactive or hidden enemies and does not retarget a late knockout" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 8, 91 });
    battle.enemies[2].status_byte = 1;
    const values: [2]u15 = .{ 5, 5 };
    battle.draws = .{ .values = &values };
    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 31, .target = 0 });
    try boundary.commit(battle.host());
    for (0..230) |tick| {
        if (tick == 100) battle.enemies[1].active = false;
        if (boundary.advanceSequence(&cat, battle.view(), battle.host(), &battle.draws, @intCast(tick))) |result| switch (result) {
            .applied => {},
            else => return error.ExpectedApplied,
        };
    }
    try std.testing.expectEqual(@as(u32, 1), battle.damage_calls);
    try std.testing.expectEqual(@as(i16, 3), battle.damage_target);
    try std.testing.expectEqual(@as(usize, 2), battle.draws.cursor);
}

test "target reaction waits cover the selected source scripts and reject invalid clocks" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    const expected = [_]?u16{ 38, 22, 21, 21, 36, 22, 38, 22, 73, null, 37, 22, 22, 22, 34, null, 35, null, 54, 21, 21, 22, 22, 22, 22, null, 32, 110, 73, null, null, 37 };
    for (cat.records, expected) |record, updates| try std.testing.expectEqual(updates, record.target_reaction_updates);
    const needle = "\"target_reaction_updates\": 38";
    const offset = std.mem.indexOf(u8, unite_data.unite_catalogue_json, needle).?;
    for ([_]u16{ 0, 1001 }) |updates| {
        const invalid = try std.fmt.allocPrint(std.testing.allocator, "{s}\"target_reaction_updates\": {d}{s}", .{ unite_data.unite_catalogue_json[0..offset], updates, unite_data.unite_catalogue_json[offset + needle.len ..] });
        defer std.testing.allocator.free(invalid);
        try std.testing.expectError(error.InvalidCatalogueEffect, unite_mod.Catalogue.init(std.testing.allocator, invalid));
    }
}

test "individual returns apply recovery once and leave unfinished participants reserved" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    var battle = TestBattle.init(&.{ 32, 38 });
    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 1, .target = 3 });
    try boundary.commit(battle.host());
    try std.testing.expectError(error.NotParticipant, boundary.finishMember(battle.view(), battle.host(), 4));
    battle.party_count = 1;
    try std.testing.expectError(error.NotParticipant, boundary.finishMember(battle.view(), battle.host(), 1));
    battle.party_count = 2;
    try boundary.finishMember(battle.view(), battle.host(), 1);
    try std.testing.expectEqual(unite_mod.Stage.committed, boundary.stage);
    try std.testing.expectEqual(@as(u32, 1), battle.status_writes);
    try std.testing.expectEqual(@as(u16, 0), battle.party[0].status_mask);
    try std.testing.expectEqual(unite_mod.rules.recovery_mask, battle.party[1].status_mask);
    try std.testing.expectError(error.MemberAlreadyFinished, boundary.finishMember(battle.view(), battle.host(), 1));
    try std.testing.expectEqual(@as(u32, 1), battle.status_writes);
    try boundary.finish(battle.view(), battle.host());
    try std.testing.expectEqual(unite_mod.Stage.finished, boundary.stage);
    try std.testing.expectEqual(@as(u32, 2), battle.status_writes);
    try std.testing.expectEqual(@as(u8, 3), boundary.finished_members);
}

test "Unite hit gates select the command owner or the source member ordinal" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    const fixed = [_]struct { record: u8, member: u8 }{
        .{ .record = 4, .member = 0 },  .{ .record = 5, .member = 3 },
        .{ .record = 7, .member = 2 },  .{ .record = 8, .member = 1 },
        .{ .record = 13, .member = 1 }, .{ .record = 21, .member = 3 },
        .{ .record = 22, .member = 3 }, .{ .record = 23, .member = 3 },
        .{ .record = 24, .member = 3 }, .{ .record = 26, .member = 1 },
        .{ .record = 27, .member = 1 }, .{ .record = 28, .member = 1 },
    };
    for (cat.records) |record| {
        var member: ?u8 = null;
        for (fixed) |entry| if (entry.record == record.index) {
            member = entry.member;
        };
        if (member) |ordinal| {
            try std.testing.expectEqual(.member, record.hit_actor.?.kind);
            try std.testing.expectEqual(ordinal, record.hit_actor.?.member.?);
        } else if (record.gate == .leader_hit_flag) {
            try std.testing.expectEqual(.command_owner, record.hit_actor.?.kind);
            try std.testing.expect(record.hit_actor.?.member == null);
        } else try std.testing.expect(record.hit_actor == null);
    }
    // Reversed party slots prove that member ordinals are catalogue order.
    for ([_]u8{ 0, 1, 4, 5, 7, 8, 13, 21, 22, 23, 24, 26, 27, 28 }) |index| {
        const record = cat.recordAt(index).?;
        var ids: [4]u8 = undefined;
        for (record.membersSlice(), 0..) |id, i| ids[record.member_count - i - 1] = id;
        var battle = TestBattle.init(ids[0..record.member_count]);
        battle.draws = .{ .values = &values_five };
        var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = index, .target = @intCast(battle.party_count + 1) });
        try boundary.commit(battle.host());
        const selected: usize = if (record.hit_actor.?.member) |ordinal| record.member_count - ordinal - 1 else 0;
        try std.testing.expectEqual(selected, boundary.hitActor(record).?);
        battle.hit_ready = @splat(true);
        battle.hit_ready[selected] = false;
        switch (boundary.impact(&cat, battle.view(), battle.host(), &battle.draws)) {
            .skipped => {},
            else => return error.ExpectedSkip,
        }
        try std.testing.expectEqual(@as(usize, 0), battle.draws.cursor);
        try std.testing.expectEqual(@as(u32, 0), battle.damage_calls);
        battle.hit_ready = @splat(false);
        battle.hit_ready[selected] = true;
        switch (boundary.impact(&cat, battle.view(), battle.host(), &battle.draws)) {
            .applied => {},
            else => return error.ExpectedApplied,
        }
        try std.testing.expectEqual(@as(u32, 1), battle.damage_calls);
        try std.testing.expectEqual(@as(usize, record.member_count), battle.draws.cursor);
    }
}

test "Unite catalogue rejects missing or malformed hit actor bindings" {
    const needle = "\"hit_actor\": {\n    \"kind\": \"command_owner\",\n    \"member\": null\n   }";
    const offset = std.mem.indexOf(u8, unite_data.unite_catalogue_json, needle).?;
    for ([_][]const u8{
        "\"hit_actor\": null",
        "\"hit_actor\": {\"kind\": \"member\", \"member\": null}",
        "\"hit_actor\": {\"kind\": \"member\", \"member\": 2}",
        "\"hit_actor\": {\"kind\": \"command_owner\", \"member\": 0}",
    }) |replacement| {
        const invalid = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}", .{ unite_data.unite_catalogue_json[0..offset], replacement, unite_data.unite_catalogue_json[offset + needle.len ..] });
        defer std.testing.allocator.free(invalid);
        try std.testing.expectError(error.InvalidCatalogueEffect, unite_mod.Catalogue.init(std.testing.allocator, invalid));
    }
}

test "participant status changes after initialization do not cancel a later combined hit" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    for ([_]u16{ 0, unite_mod.rules.recovery_mask, 0x20, 0x21 }) |mask| {
        var battle = TestBattle.init(&.{ 3, 33, 23 });
        var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 8, .target = 4 });
        try boundary.commit(battle.host());
        try boundary.finishMember(battle.view(), battle.host(), 2);
        try std.testing.expectEqual(unite_mod.rules.recovery_mask, battle.party[2].status_mask);
        battle.party[2].status_mask |= mask;
        var draws = rng.Draws{ .values = &.{ 0, 0, 0 } };
        const result = boundary.impact(&cat, battle.view(), battle.host(), &draws);
        switch (result) {
            .applied => try std.testing.expectEqual(@as(usize, 3), draws.cursor),
            else => return error.ExpectedApplied,
        }
        try std.testing.expectEqual(@as(u32, 3), battle.physical_calls);
    }
    for ([_]bool{ false, true }) |returned| {
        var battle = TestBattle.init(&.{ 3, 33, 23 });
        var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 8, .target = 4 });
        try boundary.commit(battle.host());
        const member: usize = if (returned) 0 else 2;
        if (returned) try boundary.finishMember(battle.view(), battle.host(), member);
        battle.party[member].status_mask = unite_mod.rules.recovery_mask;
        var draws = rng.Draws{ .values = &.{ 0, 0, 0 } };
        switch (boundary.impact(&cat, battle.view(), battle.host(), &draws)) {
            .applied => try std.testing.expectEqual(@as(usize, 3), draws.cursor),
            else => return error.ExpectedApplied,
        }
        try std.testing.expectEqual(@as(u32, 3), battle.physical_calls);
    }
}

test "Trick sequence contacts hit only the selected enemy without clearing participant signals" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    const record = cat.recordAt(14).?;
    var battle = TestBattle.init(record.membersSlice());
    const values = [_]u15{ 10, 20, 30, 40 };
    battle.draws = .{ .values = &values };
    var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = 14, .target = 3 });
    try boundary.commit(battle.host());
    const flags = battle.party[0].actor_flags;
    switch (unite_mod.impactSequenceTarget(&boundary, &cat, battle.view(), battle.host(), &battle.draws, 4)) {
        .applied => |amount| try std.testing.expectEqual(@as(u32, 30), amount),
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(u32, 1), battle.damage_calls);
    try std.testing.expectEqual(@as(i16, 4), battle.damage_target);
    try std.testing.expectEqual(@as(usize, 2), battle.draws.cursor);
    try std.testing.expectEqual(flags, battle.party[0].actor_flags);
    battle.enemies[0].active = false;
    switch (unite_mod.impactSequenceTarget(&boundary, &cat, battle.view(), battle.host(), &battle.draws, 3)) {
        .skipped => {},
        else => return error.ExpectedSkipped,
    }
    battle.enemies[0].active = true;
    battle.enemies[0].status_byte = 1;
    switch (unite_mod.impactSequenceTarget(&boundary, &cat, battle.view(), battle.host(), &battle.draws, 3)) {
        .skipped => {},
        else => return error.ExpectedSkipped,
    }
    try std.testing.expectEqual(@as(usize, 2), battle.draws.cursor);
    try std.testing.expectEqual(@as(u32, 1), battle.damage_calls);
    switch (unite_mod.impactSequenceTarget(&boundary, &cat, battle.view(), battle.host(), &battle.draws, 5)) {
        .applied => |amount| try std.testing.expectEqual(@as(u32, 70), amount),
        else => return error.ExpectedApplied,
    }
    try std.testing.expectEqual(@as(u32, 2), battle.damage_calls);
    try std.testing.expectEqual(@as(i16, 5), battle.damage_target);
    try std.testing.expectEqual(@as(usize, 4), battle.draws.cursor);
}

test "Talisman and Fisherman retain migrated combined-damage vectors and one commit" {
    var cat = try catalogue();
    defer cat.deinit(std.testing.allocator);
    const cases = [_]struct { values: [2]u15, amounts: [2]u32 }{
        .{ .values = .{ 1, 2 }, .amounts = .{ 6, 9 } },
        .{ .values = .{ 9, 17 }, .amounts = .{ 52, 78 } },
        .{ .values = .{ 100, 0 }, .amounts = .{ 200, 300 } },
        .{ .values = .{ 999, 999 }, .amounts = .{ 3996, 5994 } },
    };
    for (0..2) |record_index| for (cases) |case| {
        const record = cat.recordAt(@intCast(record_index)).?;
        var battle = TestBattle.init(record.membersSlice());
        battle.draws = .{ .values = &case.values };
        var boundary = try planOk(&cat, &battle, .{ .actor = 0, .record = @intCast(record_index), .target = 4 });
        try boundary.commit(battle.host());
        battle.party[0].actor_flags = 10;
        battle.party[1].actor_flags = 6;
        switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
            .applied => |amount| try std.testing.expectEqual(case.amounts[record_index], amount),
            else => return error.ExpectedApplied,
        }
        try std.testing.expectEqual(@as(u32, 2), battle.physical_calls);
        try std.testing.expectEqual(@as(u32, 1), battle.damage_calls);
        try std.testing.expectEqual(@as(i16, 4), battle.damage_target);
        try std.testing.expectEqual(case.amounts[record_index], battle.damage_amount);
        try std.testing.expectEqual(@as(u16, 8), battle.party[0].actor_flags);
        try std.testing.expectEqual(@as(u16, 4), battle.party[1].actor_flags);
        switch (unite_mod.impact(&boundary, &cat, battle.view(), battle.host(), &battle.draws)) {
            .failed => |failure| switch (failure) {
                .refusal => |reason| try std.testing.expectEqual(unite_mod.Refusal.not_committed, reason),
                else => return error.ExpectedRefusal,
            },
            else => return error.ExpectedRefusal,
        }
        try std.testing.expectEqual(@as(usize, 2), battle.draws.cursor);
        try std.testing.expectEqual(@as(u32, 2), battle.physical_calls);
        try std.testing.expectEqual(@as(u32, 1), battle.damage_calls);
        try boundary.finish(battle.view(), battle.host());
        for (battle.party[0..2]) |slot| {
            try std.testing.expectEqual(@as(u16, if (record_index == 1) 0x40 else 0), slot.status_mask);
            try std.testing.expectEqual(@as(u8, if (record_index == 1) 1 else 0), slot.recovery_counter);
        }
    };
}
