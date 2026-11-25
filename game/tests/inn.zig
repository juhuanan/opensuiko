const std = @import("std");
const field = @import("field");
const progress = field.game_state;

test "party transactions agree with 30 independent original-instruction vectors" {
    const Row = struct { party_size: usize, money_before: u32, money_after: u32, rested: bool, max_rune_charges: [4]u16 };
    const rows = try std.json.parseFromSlice([]const Row, std.testing.allocator, @embedFile("fixtures/inn_transactions.json"), .{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 30), rows.value.len);
    const rules = try field.inn.load(std.testing.allocator, field.inn.json);
    defer rules.deinit();
    const ids = [_][]const u8{ "one", "two", "three", "four", "five", "six" };
    for (rows.value) |row| {
        var members: [6]progress.Member = undefined;
        for (members[0..row.party_size], 0..) |*member, i| {
            member.* = .{ .id = ids[i], .name = "Test member", .hp = @intCast(10 + i), .max_hp = @intCast(100 + i), .status = .poisoned, .rune_charges = .{ 0, 0, 0, 0 }, .max_rune_charges = row.max_rune_charges };
        }
        var state = progress.Progress{ .money = row.money_before, .party = members[0..row.party_size] };
        if (row.rested) try state.stay(rules.value.price_per_member) else try std.testing.expectError(error.InsufficientFunds, state.stay(rules.value.price_per_member));
        try std.testing.expectEqual(row.money_after, state.money);
        for (state.party, 0..) |member, i| {
            try std.testing.expectEqual(@as(u16, @intCast(if (row.rested) 100 + i else 10 + i)), member.hp);
            try std.testing.expectEqual(if (row.rested) progress.Status.healthy else .poisoned, member.status);
            try std.testing.expectEqual(if (row.rested) row.max_rune_charges else [_]u16{ 0, 0, 0, 0 }, member.rune_charges);
        }
    }
}

fn injuredHero() progress.Member {
    return .{ .id = "hero", .name = "Hero", .hp = 35, .max_hp = 100, .status = .poisoned, .rune_charges = .{ 0, 0, 0, 0 }, .max_rune_charges = .{ 0, 0, 0, 0 } };
}

fn offer(state: *field.State, package: field.Package) void {
    state.x = 24;
    state.y = 48;
    state.destination = .{ .x = 24, .y = 48 };
    state.facing = .up;
    for (0..8) |_| {
        if (state.dialogue) |dialogue| if (dialogue.phase == .choices) return;
        state.tick(package, .{ .action = true });
        if (state.dialogue) |*dialogue| dialogue.reveal_complete = true;
    }
}

test "inn cancel, decline and insufficient money leave all gameplay state intact" {
    const package = try field.load(std.testing.allocator, @embedFile("fixtures/room.json"));
    defer package.deinit();
    const rules = try field.inn.load(std.testing.allocator, field.inn.json);
    defer rules.deinit();
    var scoped = rules.value;
    scoped.room = "inn";
    scoped.npc = "keeper";
    for (0..3) |route| {
        var members = [_]progress.Member{injuredHero()};
        var state = field.State.init(package.value, .{ .money = 99, .party = &members });
        try state.configureInn(package.value, scoped);
        offer(&state, package.value);
        try std.testing.expectEqual(.choices, state.dialogue.?.phase);
        if (route == 0) {
            state.tick(package.value, .{ .cancel = true, .action = true });
        } else if (route == 1) {
            state.tick(package.value, .{ .menu_direction = .down });
            state.tick(package.value, .{ .direction = .down });
            try std.testing.expectEqual(@as(u1, 1), state.dialogue.?.choice);
            state.tick(package.value, .{ .action = true });
        } else {
            state.tick(package.value, .{ .action = true });
            try std.testing.expectEqual(.insufficient_funds, state.dialogue.?.phase);
            state.tick(package.value, .{ .action = true });
        }
        try std.testing.expectEqual(null, state.dialogue);
        try std.testing.expectEqual(@as(u32, 99), state.progress.money);
        try std.testing.expectEqual(@as(u16, 35), members[0].hp);
        try std.testing.expectEqual(progress.Status.poisoned, members[0].status);
        try std.testing.expectEqual(@as(u16, 0), state.rest_ticks);
        try std.testing.expectEqual(@as(i32, 48), state.y);
    }
}

test "confirmation charges once; rest blocks input and returns control after its fade" {
    const package = try field.load(std.testing.allocator, @embedFile("fixtures/room.json"));
    defer package.deinit();
    const rules = try field.inn.load(std.testing.allocator, field.inn.json);
    defer rules.deinit();
    var scoped = rules.value;
    scoped.room = "inn";
    scoped.npc = "keeper";
    var members = [_]progress.Member{injuredHero()};
    var state = field.State.init(package.value, .{ .money = 100, .party = &members });
    try state.configureInn(package.value, scoped);
    offer(&state, package.value);
    state.tick(package.value, .{ .action = true });
    try std.testing.expectEqual(@as(u32, 0), state.progress.money);
    try std.testing.expectEqual(@as(u16, 100), members[0].hp);
    try std.testing.expectEqual(@as(u16, 60), state.rest_ticks);
    try std.testing.expectEqual(@as(f32, 0), state.restOpacity());
    for (0..60) |tick| {
        state.tick(package.value, .{ .action = true, .cancel = true, .direction = .left });
        if (tick == 29) try std.testing.expectEqual(@as(f32, 1), state.restOpacity());
        try std.testing.expectEqual(null, state.dialogue);
        try std.testing.expectEqual(@as(u32, 0), state.progress.money);
        try std.testing.expectEqual(@as(i32, 24), state.x);
    }
    try std.testing.expectEqual(@as(f32, 0), state.restOpacity());
    state.tick(package.value, .{ .direction = .left });
    try std.testing.expect(state.remaining > 0);
}

test "invalid rules, service bindings and party data fail before payment" {
    const package = try field.load(std.testing.allocator, @embedFile("fixtures/room.json"));
    defer package.deinit();
    const parsed = try field.inn.load(std.testing.allocator, field.inn.json);
    defer parsed.deinit();
    var rules = parsed.value;
    rules.schema = "suikoden-inn/999";
    try std.testing.expectError(error.UnsupportedInnSchema, rules.validate());
    rules = parsed.value;
    rules.price_per_member = 0;
    try std.testing.expectError(error.InvalidInn, rules.validate());
    rules = parsed.value;
    rules.choices[0] = "";
    try std.testing.expectError(error.InvalidInn, rules.validate());
    try std.testing.expectError(error.UnexpectedEndOfInput, field.inn.load(std.testing.allocator, "{"));
    var members = [_]progress.Member{injuredHero()};
    var state = field.State.init(package.value, .{ .money = 100, .party = &members });
    try std.testing.expectError(error.UnknownInnRoom, state.configureInn(package.value, parsed.value));
    rules = parsed.value;
    rules.room = "inn";
    try std.testing.expectError(error.UnknownInnNpc, state.configureInn(package.value, rules));
    members[0].hp = 101;
    try std.testing.expectError(error.InvalidMember, state.progress.stay(100));
    try std.testing.expectEqual(@as(u32, 100), state.progress.money);
    state.progress.party = &.{};
    try std.testing.expectError(error.InvalidParty, state.progress.stay(100));
}
