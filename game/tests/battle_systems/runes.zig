//! Focused rune-technique test cases.
//!
//! Pure data/rule tests: no original instruction is executed.  The exported
//! JSON is embedded and independently compared against the Zig tables, so the
//! Python producer and the Zig consumer cannot drift apart silently.

const std = @import("std");
const techniques_mod = @import("battle_systems").techniques;
const runes_data = @import("battle_systems_data").runes;
const physical = techniques_mod.physical;
const passive = techniques_mod.passive;
const carry = techniques_mod.carry;

const runes_json = runes_data.runes_json;
const vectors_json = runes_data.vectors_json;

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    return value.object.get(name) orelse @panic("missing JSON field");
}

test "source bytes and catalogue mapping are exact" {
    try std.testing.expectEqual(@as(usize, 6), physical.technique_count);
    try std.testing.expectEqual(physical.Technique.boar, physical.techniqueForRune(8).?);
    try std.testing.expectEqual(physical.Technique.shrike, physical.techniqueForRune(9).?);
    try std.testing.expectEqual(physical.Technique.falcon, physical.techniqueForRune(10).?);
    try std.testing.expectEqual(physical.Technique.hate, physical.techniqueForRune(11).?);
    try std.testing.expectEqual(physical.Technique.trick, physical.techniqueForRune(12).?);
    try std.testing.expectEqual(physical.Technique.clone, physical.techniqueForRune(13).?);
    for ([_]u8{ 0, 1, 2, 7, 14, 31, 32, 33, 34 }) |byte| {
        if (byte >= 8 and byte <= 13) continue;
        try std.testing.expect(physical.techniqueForRune(byte) == null);
    }
    try std.testing.expectEqual(@as(?u8, 0), physical.catalogueIndex(2));
    try std.testing.expectEqual(@as(?u8, 6), physical.catalogueIndex(8));
    try std.testing.expectEqual(@as(?u8, 30), physical.catalogueIndex(31));
    try std.testing.expectEqual(@as(?u8, 19), physical.catalogueIndex(21));
    try std.testing.expectEqual(@as(?u8, 21), physical.catalogueIndex(22));
    try std.testing.expectEqual(@as(?u8, 20), physical.catalogueIndex(33));
    try std.testing.expectEqual(@as(?u8, null), physical.catalogueIndex(1));
    try std.testing.expectEqual(@as(?u8, null), physical.catalogueIndex(32));
    try std.testing.expectEqual(@as(?u8, 2), physical.runeByteFromCatalogue(0));
    try std.testing.expectEqual(@as(?u8, 33), physical.runeByteFromCatalogue(20));
    try std.testing.expectEqual(@as(?u8, 31), physical.runeByteFromCatalogue(30));
    try std.testing.expectEqual(@as(?u8, null), physical.runeByteFromCatalogue(31));
}

test "physical numerators match the source ori words" {
    const expected = [_]struct { technique: physical.Technique, numerator: u16, site: u32, status: physical.Status }{
        .{ .technique = .boar, .numerator = 20, .site = 0x800F8B2C, .status = .shared },
        .{ .technique = .shrike, .numerator = 20, .site = 0x800F9024, .status = .physical_rune },
        .{ .technique = .falcon, .numerator = 30, .site = 0x800F8CB4, .status = .physical_rune },
        .{ .technique = .hate, .numerator = 30, .site = 0x800F8F70, .status = .unsupported },
        .{ .technique = .trick, .numerator = 15, .site = 0x800F90D4, .status = .physical_rune },
        .{ .technique = .clone, .numerator = 20, .site = 0x800F8BEC, .status = .shared },
    };
    for (expected) |row| {
        const metadata = physical.info(row.technique);
        try std.testing.expectEqual(row.numerator, metadata.numerator);
        try std.testing.expectEqual(@as(u16, 10), metadata.denominator);
        try std.testing.expectEqual(row.site, metadata.multiplier_site);
        try std.testing.expectEqual(row.status, metadata.status);
    }
    try std.testing.expect(physical.info(.hate).auxiliary_stage);
    try std.testing.expect(physical.info(.boar).recovery_proven);
    try std.testing.expect(physical.info(.clone).recovery_proven);
    inline for ([_]physical.Technique{ .shrike, .falcon, .trick }) |technique| {
        try std.testing.expect(!physical.info(technique).recovery_proven);
        try std.testing.expect(physical.info(technique).recovery == null);
    }
}

test "damage applies numerator then truncating division by ten" {
    const cases = [_]struct { numerator: u16, amount: u32, expected: u32 }{
        .{ .numerator = 20, .amount = 1, .expected = 2 },
        .{ .numerator = 20, .amount = 17, .expected = 34 },
        .{ .numerator = 20, .amount = 100, .expected = 200 },
        .{ .numerator = 20, .amount = 9999, .expected = 19998 },
        .{ .numerator = 20, .amount = 9, .expected = 18 },
        .{ .numerator = 30, .amount = 17, .expected = 51 },
        .{ .numerator = 15, .amount = 1, .expected = 1 },
        .{ .numerator = 15, .amount = 9, .expected = 13 },
        .{ .numerator = 15, .amount = 17, .expected = 25 },
        .{ .numerator = 15, .amount = 100, .expected = 150 },
        .{ .numerator = 20, .amount = 999, .expected = 1998 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, physical.damage(case.numerator, case.amount));
    }
}

test "physical plan: supported techniques, cost, recovery and typed refusals" {
    // Retain the retired original-execution gate's Boar/Clone and exact-target cases.
    const rows = [_]struct { byte: u8, numerator: u16 }{
        .{ .byte = 8, .numerator = 20 },
        .{ .byte = 13, .numerator = 20 },
        .{ .byte = 9, .numerator = 20 },
        .{ .byte = 10, .numerator = 30 },
        .{ .byte = 12, .numerator = 15 },
    };
    for (rows) |row| for ([_]usize{ 3, 4 }) |target| {
        const outcome = try physical.plan(.{ .rune_byte = row.byte, .actor_can_act = true, .target = target, .target_live = true });
        switch (outcome) {
            .strike => |strike| {
                try std.testing.expectEqual(row.byte, strike.rune_byte);
                try std.testing.expectEqual(row.numerator, strike.numerator);
                try std.testing.expectEqual(@as(u16, 0), strike.charge_cost);
                try std.testing.expectEqual(target, strike.target);
                try std.testing.expectEqual(physical.Presentation.ordinary_attack, strike.presentation);
                try std.testing.expect(strike.latch.armed);
            },
            .unsupported => return error.TestUnexpectedResult,
        }
    };
    // Hate is an auxiliary family, never a plain strike.
    switch (try physical.plan(.{ .rune_byte = 11, .actor_can_act = true, .target = 1, .target_live = true })) {
        .strike => return error.TestUnexpectedResult,
        .unsupported => |reason| try std.testing.expectEqual(physical.Unsupported.auxiliary_actor_creation, reason),
    }
    // Reserved identities never substitute.
    for ([_]u8{ 1, 32, 33 }) |byte| {
        switch (try physical.plan(.{ .rune_byte = byte, .actor_can_act = true, .target = 1, .target_live = true })) {
            .strike => return error.TestUnexpectedResult,
            .unsupported => |reason| try std.testing.expectEqual(physical.Unsupported.reserved_rune_identity, reason),
        }
    }
    try std.testing.expectError(error.NotPhysicalRune, physical.plan(.{ .rune_byte = 2, .actor_can_act = true, .target = 1, .target_live = true }));
    try std.testing.expectError(error.ActorCannotAct, physical.plan(.{ .rune_byte = 9, .actor_can_act = false, .target = 1, .target_live = true }));
    try std.testing.expectError(error.MissingTarget, physical.plan(.{ .rune_byte = 9, .actor_can_act = true, .target = null, .target_live = true }));
    try std.testing.expectError(error.InvalidTarget, physical.plan(.{ .rune_byte = 9, .actor_can_act = true, .target = 1, .target_live = false }));
}

test "one-shot impact latch" {
    var latch = physical.Latch{};
    try std.testing.expect(!latch.consume());
    latch.arm();
    try std.testing.expect(latch.consume());
    try std.testing.expect(!latch.consume());
}

fn expectGranted(input: passive.Input, grant: passive.Grant) !void {
    switch (passive.decide(input)) {
        .granted => |actual| try std.testing.expectEqual(grant, actual),
        .refused => return error.TestUnexpectedResult,
    }
}

fn expectRefused(input: passive.Input, refusal: passive.Refusal) !void {
    switch (passive.decide(input)) {
        .granted => return error.TestUnexpectedResult,
        .refused => |actual| try std.testing.expectEqual(refusal, actual),
    }
}

test "counter decision follows the source helper order" {
    const base = passive.Input{
        .actor_index = 8,
        .counter_actor_floor = 7,
        .attacker_capability = true,
        .target_persistent_flag = true,
        .target_slot_47 = false,
        .target_rune = 0,
        .roll_low_bit = 0,
    };
    var input = base;
    input.actor_index = 7; // == floor: still party range in the source test
    try expectRefused(input, .actor_in_party_range);
    input = base;
    input.actor_index = 6;
    try expectRefused(input, .actor_in_party_range);
    input = base;
    input.attacker_capability = null;
    try expectRefused(input, .attacker_capability_unavailable);
    input = base;
    input.target_persistent_flag = null;
    try expectRefused(input, .target_persistent_flag_unavailable);
    input = base;
    input.attacker_capability = false;
    try expectRefused(input, .attacker_not_counterable);
    input = base;
    input.target_persistent_flag = false;
    try expectRefused(input, .target_not_marked);
    input = base;
    input.target_slot_47 = true;
    try expectGranted(input, .slot_47);
    input = base;
    input.target_rune = 16;
    try expectGranted(input, .counter_rune);
    input = base;
    input.target_rune = 17;
    try expectRefused(input, .random_low_bit);
    input = base;
    input.target_rune = 17;
    input.roll_low_bit = 1;
    try expectGranted(input, .random_low_bit);
    // The random arm is only reached after the earlier gates; an absent
    // capability never falls through to the coin flip.
    input = base;
    input.attacker_capability = null;
    input.target_slot_47 = true;
    input.target_rune = 16;
    input.roll_low_bit = 1;
    try expectRefused(input, .attacker_capability_unavailable);
}

test "loadout carry preserves lock, fragments and spent charges" {
    const fragments = carry.Fragments{ .active_type = 3, .counts = .{ 0, 0, 4, 0, 0 } };
    const field_loadout = carry.Loadout{
        .member = 42,
        .weapon_level = 7,
        .rune = .{ .byte = 8, .charges = .{ 1, 0, 2, 0 }, .locked = true },
        .fragments = fragments,
    };
    var battle_loadout = field_loadout;
    // A transition must not refill: the live slot already carries the same
    // spent counters and the carry returns them verbatim.
    battle_loadout.rune.charges = .{ 1, 0, 2, 0 };
    const carried = try carry.carry(field_loadout, battle_loadout);
    try std.testing.expectEqual(field_loadout.rune.byte, carried.rune.byte);
    try std.testing.expectEqual(field_loadout.rune.charges, carried.rune.charges);
    try std.testing.expectEqual(field_loadout.rune.locked, carried.rune.locked);
    try std.testing.expect(std.meta.eql(fragments, carried.fragments));
    // The inn is the only full refill.
    try std.testing.expectEqual([4]u16{ 3, 3, 3, 3 }, carry.innRecover(carried.rune, .{ 3, 3, 3, 3 }).charges);
    try std.testing.expectEqual(field_loadout.rune.charges, carried.rune.charges);

    // Substitution, lock flip, fragment drift and member drift are refused.
    var changed = battle_loadout;
    changed.rune.byte = 9;
    try std.testing.expectError(error.RuneChanged, carry.carry(field_loadout, changed));
    var unlock = battle_loadout;
    unlock.rune.locked = false;
    try std.testing.expectError(error.LockedRuneChanged, carry.carry(field_loadout, unlock));
    var fragment_drift = battle_loadout;
    fragment_drift.fragments.counts[2] = 5;
    try std.testing.expectError(error.FragmentChanged, carry.carry(field_loadout, fragment_drift));
    var other_member = battle_loadout;
    other_member.member = 43;
    try std.testing.expectError(error.MemberChanged, carry.carry(field_loadout, other_member));
    var other_weapon = battle_loadout;
    other_weapon.weapon_level = 8;
    try std.testing.expectError(error.LoadoutChanged, carry.carry(field_loadout, other_weapon));
    var unknown = battle_loadout;
    unknown.rune.byte = 34;
    try std.testing.expectError(error.UnknownRuneByte, carry.carry(unknown, unknown));
}

test "charge restore rejects overflow instead of clamping" {
    const persistent = carry.RuneSlot{ .byte = 8, .charges = .{ 4, 0, 0, 0 }, .locked = true };
    const live = carry.RuneSlot{ .byte = 8, .charges = .{ 1, 0, 0, 0 }, .locked = true };
    const restored = try carry.restoreCharges(persistent, live, .{ 4, 0, 0, 0 });
    try std.testing.expectEqual([4]u16{ 4, 0, 0, 0 }, restored.charges);
    try std.testing.expectError(error.ChargesExceeded, carry.restoreCharges(persistent, live, .{ 3, 0, 0, 0 }));
    const wrong_rune = carry.RuneSlot{ .byte = 9, .charges = .{ 0, 0, 0, 0 } };
    try std.testing.expectError(error.RuneChanged, carry.restoreCharges(persistent, wrong_rune, .{ 4, 0, 0, 0 }));
    var unlocked_live = live;
    unlocked_live.locked = false;
    try std.testing.expectError(error.LockedRuneChanged, carry.restoreCharges(persistent, unlocked_live, .{ 4, 0, 0, 0 }));
}

test "locked rune service and fragment commit boundaries" {
    const locked = carry.Loadout{
        .member = 5,
        .rune = .{ .byte = 8, .charges = .{ 2, 0, 0, 0 }, .locked = true },
    };
    try std.testing.expectError(error.LockedRuneChanged, carry.attach(locked, 9, .{ 3, 0, 0, 0 }));
    try std.testing.expectError(error.LockedRuneChanged, carry.attach(locked, 8, .{ 3, 0, 0, 0 }));
    try std.testing.expectError(error.LockedRuneChanged, carry.detach(locked));
    const empty = carry.Loadout{ .member = 5 };
    const attached = try carry.attach(empty, 8, .{ 3, 0, 0, 0 });
    try std.testing.expectEqual([4]u16{ 3, 0, 0, 0 }, attached.rune.charges);
    try std.testing.expect(!attached.rune.locked);
    const unlocked = carry.Loadout{ .member = 5 };
    try std.testing.expectError(error.UnknownRuneByte, carry.attach(unlocked, 34, .{ 1, 0, 0, 0 }));
    const replaceable = carry.Loadout{ .member = 5, .rune = .{ .byte = 8, .charges = .{ 2, 0, 0, 0 } } };
    const detached = try carry.detach(try carry.attach(replaceable, 9, .{ 1, 0, 0, 0 }));
    try std.testing.expectEqual(carry.no_rune, detached.rune.byte);

    const committed = try carry.commitFragment(.{ .active_type = 1, .counts = .{ 9, 9, 9, 9, 9 } }, 3, 4);
    try std.testing.expectEqual(@as(u8, 3), committed.active_type);
    try std.testing.expectEqual([5]u8{ 0, 0, 4, 0, 0 }, committed.counts);
    try std.testing.expectError(error.InvalidFragmentType, carry.commitFragment(.{}, 0, 1));
    try std.testing.expectError(error.InvalidFragmentType, carry.commitFragment(.{}, 6, 1));
}

test "exported JSON agrees with the Zig tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const runes_doc = try std.json.parseFromSlice(std.json.Value, arena.allocator(), runes_json, .{});
    const vectors_doc = try std.json.parseFromSlice(std.json.Value, arena.allocator(), vectors_json, .{});

    try std.testing.expectEqualStrings("suikoden-battle-runes/1", field(runes_doc.value, "schema").string);
    const coverage = field(runes_doc.value, "coverage");
    try std.testing.expectEqual(@as(i64, 33), field(coverage, "total").integer);
    try std.testing.expectEqual(@as(i64, 4), field(coverage, "physical_rune").integer);
    try std.testing.expectEqual(@as(i64, 23), field(coverage, "shared").integer);
    try std.testing.expectEqual(@as(i64, 6), field(coverage, "unsupported").integer);

    const runes = field(runes_doc.value, "runes").array.items;
    try std.testing.expectEqual(@as(usize, 33), runes.len);
    for (runes) |rune| {
        const byte: u8 = @intCast(field(rune, "byte").integer);
        const name = field(rune, "name").string;
        const status = field(rune, "status").string;
        if (physical.techniqueForRune(byte)) |technique| {
            const info = physical.info(technique);
            try std.testing.expectEqual(byte, info.rune_byte);
            try std.testing.expectEqual(info.numerator, @as(u16, @intCast(field(field(runes_doc.value, "techniques").array.items[byte - 8], "multiplier_numerator").integer)));
        }
        switch (byte) {
            9, 10, 12, 16 => try std.testing.expectEqualStrings("physical_rune", status),
            11, 21, 24, 1, 32, 33 => try std.testing.expectEqualStrings("unsupported", status),
            else => try std.testing.expectEqualStrings("shared", status),
        }
        try std.testing.expect(name.len > 0);
    }

    const techniques = field(runes_doc.value, "techniques").array.items;
    try std.testing.expectEqual(@as(usize, 6), techniques.len);
    for (techniques) |entry| {
        const id: u8 = @intCast(field(entry, "technique_id").integer);
        const technique: physical.Technique = @fromBackingInt(@intCast(id));
        const info = physical.info(technique);
        try std.testing.expectEqual(info.rune_byte, @as(u8, @intCast(field(entry, "rune_byte").integer)));
        try std.testing.expectEqual(info.numerator, @as(u16, @intCast(field(entry, "multiplier_numerator").integer)));
        try std.testing.expectEqual(info.callback, @as(u32, @intCast(field(entry, "callback").integer)));
        try std.testing.expectEqual(info.status, std.meta.stringToEnum(physical.Status, field(entry, "status").string).?);
        try std.testing.expectEqual(@as(i64, 0), field(entry, "charge_cost").integer);
    }

    const physical_vectors = field(vectors_doc.value, "physical").array.items;
    try std.testing.expectEqual(@as(usize, 15), physical_vectors.len);
    for (physical_vectors) |vector| {
        const numerator: u16 = @intCast(field(vector, "numerator").integer);
        const amount: u32 = @intCast(field(vector, "damage").integer);
        const expected: u32 = @intCast(field(vector, "expected").integer);
        try std.testing.expectEqual(expected, physical.damage(numerator, amount));
    }

    const counter_vectors = field(vectors_doc.value, "counter").array.items;
    try std.testing.expectEqual(@as(usize, 80), counter_vectors.len);
    for (counter_vectors) |vector| {
        const input = passive.Input{
            .actor_index = 8,
            .counter_actor_floor = 7,
            .attacker_capability = field(vector, "actor_counterable").bool,
            .target_persistent_flag = field(vector, "target_flag").bool,
            .target_slot_47 = field(vector, "slot_47").bool,
            .target_rune = @intCast(field(vector, "rune_byte").integer),
            .roll_low_bit = @intCast(field(vector, "roll").integer),
        };
        const expected = field(vector, "expected").bool;
        const granted = switch (passive.decide(input)) {
            .granted => true,
            .refused => false,
        };
        try std.testing.expectEqual(expected, granted);
    }
}
