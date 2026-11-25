const std = @import("std");
const duel = @import("duel");

const allocator = std.testing.allocator;
const profiles = [2]duel.FighterState{
    .{ .maximum_hp = 1000, .hp = 1000, .attack = 160, .defense = 80 },
    .{ .maximum_hp = 1000, .hp = 1000, .attack = 160, .defense = 80 },
};

const DamageVector = struct {
    hp: i32,
    attack: u16,
    defense: u16,
    kind: duel.HitKind,
    roll: u15,
    damage: i32,
};
const ChoiceVector = struct { roll: u15, choice: u8 };
const HitVector = struct {
    tick: u32,
    target: u8,
    kind: duel.HitKind,
    damage: i32,
    hp: [2]i32,
};
const RoundVector = struct {
    duel: []const u8,
    player: duel.Command,
    opponent: duel.Command,
    choice_roll: u15,
    hp: [2]i32,
    events: []const HitVector,
    exchange_updates: u32,
    round_pause: u32,
};
const Vectors = struct {
    schema: []const u8,
    damage: []const DamageVector,
    opponent_choices: []const ChoiceVector,
    rounds: []const RoundVector,
};

fn vectors() !std.json.Parsed(Vectors) {
    return std.json.parseFromSlice(Vectors, allocator, @embedFile("fixtures/duel_vectors.json"), .{});
}

fn load() !std.json.Parsed(duel.Content) {
    return duel.load(allocator, duel.content_json);
}

test "semantic export inventories exactly the three source encounters and nine command pairs" {
    const content = try load();
    defer content.deinit();
    try std.testing.expectEqual(@as(usize, 3), content.value.duels.len);
    const expected = [_][]const u8{ "pahn_teo", "shu_kwanda", "shu_teo" };
    for (expected) |id| {
        const encounter = duel.findDuel(&content.value, id) orelse return error.MissingDuel;
        try std.testing.expectEqual(@as(usize, 9), encounter.exchanges.len);
        try std.testing.expect(encounter.fighters[0].defeat_updates > 0);
        try std.testing.expect(encounter.fighters[1].defeat_updates > 0);
    }
    try std.testing.expect(duel.findDuel(&content.value, "invented_duel") == null);
}

test "damage and opponent RNG match independent original-instruction vectors" {
    const cases = try vectors();
    defer cases.deinit();
    for (cases.value.damage) |row| {
        try std.testing.expectEqual(row.damage, duel.resolveDamage(row.hp, row.attack, row.defense, row.kind, row.roll));
    }
    for (cases.value.opponent_choices) |row| {
        try std.testing.expectEqual(row.choice, @backingInt(duel.opponentChoice(row.roll)));
    }
    var random = duel.Random{ .bios_state = 1 };
    try std.testing.expectEqual(@as(u15, 16838), try random.next());
    try std.testing.expectEqual(@as(u15, 5758), try random.next());
    try std.testing.expectEqual(@as(u32, 2524885223), random.bios_state.?);
    try std.testing.expectEqual(@as(usize, 2), random.cursor);
}

test "all 27 exchanges match independent hit and timing vectors" {
    const content = try load();
    defer content.deinit();
    const cases = try vectors();
    defer cases.deinit();
    var checked: usize = 0;
    for (cases.value.rounds) |row| {
        var rolls: [8]u15 = @splat(0);
        rolls[0] = row.choice_roll;
        var state = try duel.State.init(&content.value, row.duel, profiles, .{ .values = &rolls });
        try std.testing.expectEqual(row.opponent, state.opponent);
        try state.choose(row.player);
        var event_index: usize = 0;
        while (state.phase == .exchange) {
            try state.tick();
            if (state.last_hit) |hit| {
                try std.testing.expect(event_index < row.events.len);
                const expected = row.events[event_index];
                try std.testing.expectEqual(expected.tick, hit.tick);
                try std.testing.expectEqual(expected.target, @backingInt(hit.target));
                try std.testing.expectEqual(expected.kind, hit.kind);
                try std.testing.expectEqual(expected.damage, hit.damage);
                try std.testing.expectEqual(expected.hp[@backingInt(hit.target)], hit.hp_after);
                event_index += 1;
            }
        }
        try std.testing.expectEqual(row.events.len, event_index);
        try std.testing.expectEqual(row.exchange_updates, state.exchange_tick);
        try std.testing.expectEqual(duel.Phase.round_pause, state.phase);
        try std.testing.expectEqual(row.round_pause, state.timer);
        for (0..row.round_pause) |_| try state.tick();
        try std.testing.expectEqual(duel.Phase.choosing, state.phase);
        try std.testing.expectEqual(row.hp, [2]i32{ state.fighters[0].hp, state.fighters[1].hp });
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 27), checked);
}

fn terminalEncounter(duel_id: []const u8, player: duel.Command, opponent_roll: u15, expected_outcome: duel.Outcome, expected_loser: duel.Side) !void {
    const content = try load();
    defer content.deinit();
    const low_hp = [2]duel.FighterState{
        .{ .maximum_hp = 40, .hp = 40, .attack = 160, .defense = 80 },
        .{ .maximum_hp = 40, .hp = 40, .attack = 160, .defense = 80 },
    };
    const rolls = [_]u15{ opponent_roll, 0, 0 };
    var state = try duel.State.init(&content.value, duel_id, low_hp, .{ .values = &rolls });
    try state.choose(player);
    while (state.phase != .defeat_prelude) try state.tick();
    try std.testing.expectEqual(expected_outcome, state.outcome.?);
    try std.testing.expectEqual(expected_loser, state.loser.?);
    try std.testing.expectEqual(@as(u32, 120), state.timer);
    for (0..119) |_| try state.tick();
    try std.testing.expectEqual(duel.Phase.defeat_prelude, state.phase);
    try state.tick();
    try std.testing.expectEqual(duel.Phase.defeat_animation, state.phase);
    const duration = state.timer;
    const encounter = duel.findDuel(&content.value, duel_id).?;
    try std.testing.expectEqual(encounter.fighters[@backingInt(expected_loser)].defeat_updates, duration);
    for (0..duration - 1) |_| try state.tick();
    try std.testing.expectEqual(duel.Phase.defeat_animation, state.phase);
    try state.tick();
    try std.testing.expectEqual(duel.Phase.finished, state.phase);
    try std.testing.expectEqual(expected_outcome, state.outcome.?);
}

test "all source duels are playable through victory and defeat with exact terminal waits" {
    for ([_][]const u8{ "pahn_teo", "shu_kwanda", "shu_teo" }) |id| {
        try terminalEncounter(id, .attack, 12000, .victory, .opponent);
        try terminalEncounter(id, .defend, 0, .defeat, .player);
    }
}

test "simultaneous lethal hits use the source player-first defeat check" {
    try terminalEncounter("shu_kwanda", .attack, 0, .defeat, .player);
}

test "menu wrap, next-round cues, cancel and invalid phases preserve rules" {
    const content = try load();
    defer content.deinit();
    const rolls = [_]u15{ 12000, 24000, 0 };
    var state = try duel.State.init(&content.value, "shu_kwanda", profiles, .{ .values = &rolls });
    try std.testing.expectEqual(duel.Command.defend, state.opponent);
    try state.moveSelection(-1);
    try std.testing.expectEqual(duel.Command.desperate_attack, state.selected);
    try state.moveSelection(1);
    try std.testing.expectEqual(duel.Command.attack, state.selected);
    const before = state;
    try std.testing.expect(!state.cancel());
    try std.testing.expectEqual(before, state);
    try state.choose(.defend);
    try std.testing.expectError(error.InvalidDuelPhase, state.choose(.attack));
    while (state.phase != .choosing) try state.tick();
    try std.testing.expectEqual(@as(u32, 2), state.round);
    try std.testing.expectEqual(duel.Command.defend, state.previous_opponent);
    try std.testing.expectEqual(duel.Command.desperate_attack, state.opponent);
    try std.testing.expectEqual(content.value.duels[1].cues[1][2], state.cue());
    try std.testing.expectEqual(@as(usize, 2), state.random.cursor);
}

test "random exhaustion is atomic and invalid content or fighter snapshots are rejected" {
    const content = try load();
    defer content.deinit();
    try std.testing.expectError(error.RandomInputExhausted, duel.State.init(&content.value, "shu_kwanda", profiles, .{}));
    const one_roll = [_]u15{0};
    var state = try duel.State.init(&content.value, "shu_kwanda", profiles, .{ .values = &one_roll });
    try state.choose(.attack);
    for (0..57) |_| try state.tick();
    const before = state;
    try std.testing.expectError(error.RandomInputExhausted, state.tick());
    try std.testing.expectEqual(before, state);
    const replacement: [3]u15 = @splat(0);
    state.random = .{ .values = &replacement };
    try state.tick();
    try std.testing.expect(state.last_hit != null);
    try std.testing.expectError(error.InvalidFighterState, duel.State.init(&content.value, "shu_kwanda", .{ profiles[0], .{ .maximum_hp = 0, .hp = 0, .attack = 1, .defense = 1 } }, .{ .bios_state = 1 }));
    var invalid = content.value;
    invalid.duels = invalid.duels[0..2];
    try std.testing.expectError(error.InvalidDuelContent, invalid.validate());
}
